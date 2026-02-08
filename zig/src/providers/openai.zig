const std = @import("std");
const types = @import("types");
const event_stream = @import("event_stream");
const provider = @import("provider");
const config = @import("config");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");

/// OpenAI provider context
pub const OpenAIContext = struct {
    config: config.OpenAIConfig,
    allocator: std.mem.Allocator,
};

/// Create an OpenAI provider
pub fn createProvider(
    cfg: config.OpenAIConfig,
    allocator: std.mem.Allocator,
) !provider.ProviderV2 {
    const ctx = try allocator.create(OpenAIContext);
    ctx.* = .{
        .config = cfg,
        .allocator = allocator,
    };

    return provider.ProviderV2{
        .id = "openai",
        .name = "OpenAI GPT",
        .context = @ptrCast(ctx),
        .stream_fn = openaiStreamFn,
        .deinit_fn = openaiDeinitFn,
    };
}

/// Stream function implementation
fn openaiStreamFn(
    ctx_ptr: *anyopaque,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageStream {
    const ctx: *OpenAIContext = @ptrCast(@alignCast(ctx_ptr));

    // Create the stream
    const stream = try allocator.create(event_stream.AssistantMessageStream);
    stream.* = event_stream.AssistantMessageStream.init(allocator);

    // Build request body
    const body = try buildRequestBody(ctx.config, messages, allocator);
    defer allocator.free(body);

    // For now, complete immediately with a placeholder
    // In a real implementation, this would spawn a thread to make HTTP request
    stream.complete(.{
        .content = &[_]types.ContentBlock{},
        .usage = .{},
        .stop_reason = .stop,
        .model = ctx.config.model,
        .timestamp = std.time.timestamp(),
    });

    return stream;
}

/// Cleanup function
fn openaiDeinitFn(ctx_ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx: *OpenAIContext = @ptrCast(@alignCast(ctx_ptr));
    allocator.destroy(ctx);
}

fn deinitProvider(ptr: *anyopaque) void {
    const ctx: *OpenAIContext = @ptrCast(@alignCast(ptr));
    ctx.allocator.destroy(ctx);
}

/// Build request body for OpenAI API
pub fn buildRequestBody(
    cfg: config.OpenAIConfig,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);

    var writer = json_writer.JsonWriter.init(&buffer, allocator);

    try writer.beginObject();
    try writer.writeStringField("model", cfg.model);
    try writer.writeBoolField("stream", true);

    // Write messages array
    try writer.writeKey("messages");
    try writer.beginArray();

    // Prepend system message if system_prompt is provided
    if (cfg.params.system_prompt) |system| {
        try writer.beginObject();
        try writer.writeStringField("role", "system");
        try writer.writeStringField("content", system);
        try writer.endObject();
    }

    for (messages) |msg| {
        try writer.beginObject();
        try writer.writeStringField("role", @tagName(msg.role));

        // Write content - handle both single text and multiple blocks
        if (msg.content.len == 1 and msg.content[0] == .text) {
            // Simple text content
            try writer.writeStringField("content", msg.content[0].text.text);
        } else {
            // Multiple content blocks
            try writer.writeKey("content");
            try writer.beginArray();
            for (msg.content) |block| {
                try writer.beginObject();
                switch (block) {
                    .text => |text| {
                        try writer.writeStringField("type", "text");
                        try writer.writeStringField("text", text.text);
                    },
                    .tool_use => |tool| {
                        // OpenAI represents tool use differently in messages
                        try writer.writeStringField("type", "tool_use");
                        try writer.writeStringField("id", tool.id);
                        try writer.writeStringField("name", tool.name);
                    },
                    .thinking => |thinking| {
                        try writer.writeStringField("type", "thinking");
                        try writer.writeStringField("text", thinking.thinking);
                    },
                    .image => |image| {
                        try writer.writeStringField("type", "image_url");
                        try writer.writeKey("image_url");
                        try writer.beginObject();
                        // OpenAI uses data URL format
                        const url = try std.fmt.allocPrint(writer.allocator, "data:{s};base64,{s}", .{ image.media_type, image.data });
                        defer writer.allocator.free(url);
                        try writer.writeStringField("url", url);
                        try writer.endObject();
                    },
                }
                try writer.endObject();
            }
            try writer.endArray();
        }

        try writer.endObject();
    }

    try writer.endArray();

    // Write optional parameters
    try writer.writeIntField("max_tokens", cfg.params.max_tokens);
    try writer.writeKey("temperature");
    try writer.writeFloat(cfg.params.temperature);
    if (cfg.params.top_p) |top_p| {
        try writer.writeKey("top_p");
        try writer.writeFloat(top_p);
    }

    // OpenAI tools support
    if (cfg.params.tools) |tools| {
        try writer.writeKey("tools");
        try writer.beginArray();
        for (tools) |tool| {
            try writer.beginObject();
            try writer.writeStringField("type", "function");
            try writer.writeKey("function");
            try writer.beginObject();
            try writer.writeStringField("name", tool.name);
            if (tool.description) |desc| {
                try writer.writeStringField("description", desc);
            }
            try writer.writeKey("parameters");
            try writer.beginObject();
            try writer.writeStringField("type", "object");
            try writer.writeKey("properties");
            try writer.beginObject();
            for (tool.parameters) |param| {
                try writer.writeKey(param.name);
                try writer.beginObject();
                try writer.writeStringField("type", param.param_type);
                if (param.description) |desc| {
                    try writer.writeStringField("description", desc);
                }
                try writer.endObject();
            }
            try writer.endObject();
            try writer.writeKey("required");
            try writer.beginArray();
            for (tool.parameters) |param| {
                if (param.required) {
                    try writer.writeString(param.name);
                }
            }
            try writer.endArray();
            try writer.endObject();
            try writer.endObject();
            try writer.endObject();
        }
        try writer.endArray();
    }

    if (cfg.params.tool_choice) |tool_choice| {
        try writer.writeKey("tool_choice");
        switch (tool_choice) {
            .auto => try writer.writeString("auto"),
            .none => try writer.writeString("none"),
            .any => try writer.writeString("required"),
            .specific => |name| {
                try writer.beginObject();
                try writer.writeStringField("type", "function");
                try writer.writeKey("function");
                try writer.beginObject();
                try writer.writeStringField("name", name);
                try writer.endObject();
                try writer.endObject();
            },
        }
    }

    // Reasoning effort for o1/o3 models
    if (cfg.reasoning_effort) |effort| {
        const effort_str = switch (effort) {
            .minimal => "minimal",
            .low => "low",
            .medium => "medium",
            .high => "high",
            .xhigh => "xhigh",
        };
        try writer.writeStringField("reasoning_effort", effort_str);
    }

    // Frequency penalty
    if (cfg.frequency_penalty) |frequency_penalty| {
        try writer.writeKey("frequency_penalty");
        try writer.writeFloat(frequency_penalty);
    }

    // Presence penalty
    if (cfg.presence_penalty) |presence_penalty| {
        try writer.writeKey("presence_penalty");
        try writer.writeFloat(presence_penalty);
    }

    // Max reasoning tokens (for reasoning models, use max_completion_tokens)
    if (cfg.max_reasoning_tokens) |max_reasoning_tokens| {
        try writer.writeIntField("max_completion_tokens", max_reasoning_tokens);
    }

    // Parallel tool calls
    if (cfg.parallel_tool_calls) |parallel_tool_calls| {
        try writer.writeBoolField("parallel_tool_calls", parallel_tool_calls);
    }

    // Seed
    if (cfg.seed) |seed| {
        try writer.writeIntField("seed", seed);
    }

    // User
    if (cfg.user) |user| {
        try writer.writeStringField("user", user);
    }

    // Response format
    if (cfg.response_format) |response_format| {
        try writer.writeKey("response_format");
        try writer.beginObject();
        switch (response_format) {
            .text => {
                try writer.writeStringField("type", "text");
            },
            .json_object => {
                try writer.writeStringField("type", "json_object");
            },
            .json_schema => |schema| {
                try writer.writeStringField("type", "json_schema");
                try writer.writeKey("json_schema");
                // Write raw JSON by appending directly to buffer
                try writer.buffer.appendSlice(writer.allocator, schema);
                writer.needs_comma = true;
            },
        }
        try writer.endObject();
    }

    try writer.endObject();

    return buffer.toOwnedSlice(allocator);
}

/// Track state across OpenAI streaming events
pub const OpenAIStreamState = struct {
    text_started: bool = false,
    current_tool_index: ?usize = null,
    accumulated_content: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OpenAIStreamState {
        return .{
            .text_started = false,
            .current_tool_index = null,
            .accumulated_content = std.ArrayList(u8){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OpenAIStreamState) void {
        self.accumulated_content.deinit(self.allocator);
    }
};

/// Map OpenAI SSE data to MessageEvent
pub fn mapSSEToMessageEvent(
    event: sse_parser.SSEEvent,
    state: *OpenAIStreamState,
    allocator: std.mem.Allocator,
) !?types.MessageEvent {
    // OpenAI sends data lines without event type
    const data = event.data;

    // Check for [DONE] marker
    if (std.mem.eql(u8, data, "[DONE]")) {
        return types.MessageEvent{
            .done = .{
                .usage = .{},
                .stop_reason = .stop,
            },
        };
    }

    // Parse JSON data
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        data,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        std.debug.print("Failed to parse OpenAI SSE data: {}\n", .{err});
        return null;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const choices = root.object.get("choices") orelse return null;
    if (choices.array.items.len == 0) return null;

    const choice = choices.array.items[0];
    const delta = choice.object.get("delta") orelse return null;

    // Handle content delta
    if (delta.object.get("content")) |content| {
        const text = content.string;

        if (!state.text_started) {
            state.text_started = true;
            return types.MessageEvent{
                .text_start = .{ .index = 0 },
            };
        }

        const text_copy = try allocator.dupe(u8, text);
        return types.MessageEvent{
            .text_delta = .{
                .index = 0,
                .delta = text_copy,
            },
        };
    }

    // Handle tool calls
    if (delta.object.get("tool_calls")) |tool_calls| {
        const tool_call = tool_calls.array.items[0];

        if (tool_call.object.get("function")) |function| {
            const name = function.object.get("name");
            const arguments = function.object.get("arguments");

            if (name) |n| {
                // New tool call starting
                const id = tool_call.object.get("id");
                const id_str = if (id) |i| i.string else "unknown";

                return types.MessageEvent{
                    .toolcall_start = .{
                        .index = 0,
                        .id = try allocator.dupe(u8, id_str),
                        .name = try allocator.dupe(u8, n.string),
                    },
                };
            } else if (arguments) |args| {
                // Tool arguments delta
                const args_str = args.string;
                return types.MessageEvent{
                    .toolcall_delta = .{
                        .index = 0,
                        .delta = try allocator.dupe(u8, args_str),
                    },
                };
            }
        }
    }

    // Handle finish_reason
    if (choice.object.get("finish_reason")) |finish_reason| {
        if (finish_reason != .null) {
            const reason = finish_reason.string;
            const stop_reason: types.StopReason = if (std.mem.eql(u8, reason, "stop"))
                .stop
            else if (std.mem.eql(u8, reason, "length"))
                .length
            else if (std.mem.eql(u8, reason, "tool_calls"))
                .tool_use
            else
                .stop;

            return types.MessageEvent{
                .done = .{
                    .usage = .{},
                    .stop_reason = stop_reason,
                },
            };
        }
    }

    return null;
}

// Tests
test "buildRequestBody - basic message" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg = config.OpenAIConfig{
        .auth = .{ .api_key = "test-key" },
        .model = "gpt-4",
        .base_url = "https://api.openai.com",
        .params = .{
            .max_tokens = 1000,
            .temperature = 0.7,
        },
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Hello" } },
            },
            .timestamp = 0,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-4\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":1000") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.7") != null);
}

test "buildRequestBody - multiple messages" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg = config.OpenAIConfig{
        .auth = .{ .api_key = "test-key" },
        .model = "gpt-4",
        .base_url = "https://api.openai.com",
        .params = .{},
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Hello" } },
            },
            .timestamp = 0,
        },
        .{
            .role = .assistant,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Hi there!" } },
            },
            .timestamp = 0,
        },
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "How are you?" } },
            },
            .timestamp = 0,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"assistant\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Hi there!\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"How are you?\"") != null);
}

test "mapSSEToMessageEvent - text_start and text_delta" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = OpenAIStreamState.init(allocator);
    defer state.deinit();

    // First content delta should emit text_start
    const event1 = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}",
    };

    const result1 = try mapSSEToMessageEvent(event1, &state, allocator);
    try testing.expect(result1 != null);
    try testing.expect(result1.? == .text_start);

    // Second content delta should emit text_delta
    const event2 = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"delta\":{\"content\":\" world\"},\"finish_reason\":null}]}",
    };

    const result2 = try mapSSEToMessageEvent(event2, &state, allocator);
    defer if (result2) |r| {
        if (r == .text_delta) allocator.free(r.text_delta.delta);
    };

    try testing.expect(result2 != null);
    try testing.expect(result2.? == .text_delta);
    try testing.expectEqualStrings(" world", result2.?.text_delta.delta);
}

test "mapSSEToMessageEvent - DONE marker" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = OpenAIStreamState.init(allocator);
    defer state.deinit();

    const event = sse_parser.SSEEvent{
        .event_type = null,
        .data = "[DONE]",
    };

    const result = try mapSSEToMessageEvent(event, &state, allocator);
    try testing.expect(result != null);
    try testing.expect(result.? == .done);
    try testing.expect(result.?.done.stop_reason == .stop);
}

test "mapSSEToMessageEvent - finish_reason mapping" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = OpenAIStreamState.init(allocator);
    defer state.deinit();

    // Test stop reason
    const event1 = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}",
    };

    const result1 = try mapSSEToMessageEvent(event1, &state, allocator);
    try testing.expect(result1 != null);
    try testing.expect(result1.? == .done);
    try testing.expect(result1.?.done.stop_reason == .stop);

    // Test max_tokens reason
    state.text_started = false;
    const event2 = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}",
    };

    const result2 = try mapSSEToMessageEvent(event2, &state, allocator);
    try testing.expect(result2 != null);
    try testing.expect(result2.? == .done);
    try testing.expect(result2.?.done.stop_reason == .length);

    // Test tool_calls reason
    state.text_started = false;
    const event3 = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}",
    };

    const result3 = try mapSSEToMessageEvent(event3, &state, allocator);
    try testing.expect(result3 != null);
    try testing.expect(result3.? == .done);
    try testing.expect(result3.?.done.stop_reason == .tool_use);
}

test "mapSSEToMessageEvent - tool calls" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = OpenAIStreamState.init(allocator);
    defer state.deinit();

    // Tool call start
    const event1 = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_123\",\"function\":{\"name\":\"get_weather\"}}]},\"finish_reason\":null}]}",
    };

    const result1 = try mapSSEToMessageEvent(event1, &state, allocator);
    defer if (result1) |r| {
        if (r == .toolcall_start) {
            allocator.free(r.toolcall_start.id);
            allocator.free(r.toolcall_start.name);
        }
    };

    try testing.expect(result1 != null);
    try testing.expect(result1.? == .toolcall_start);
    try testing.expectEqualStrings("call_123", result1.?.toolcall_start.id);
    try testing.expectEqualStrings("get_weather", result1.?.toolcall_start.name);

    // Tool arguments delta
    const event2 = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"arguments\":\"{\\\"location\\\":\\\"\"}}]},\"finish_reason\":null}]}",
    };

    const result2 = try mapSSEToMessageEvent(event2, &state, allocator);
    defer if (result2) |r| {
        if (r == .toolcall_delta) allocator.free(r.toolcall_delta.delta);
    };

    try testing.expect(result2 != null);
    try testing.expect(result2.? == .toolcall_delta);
    try testing.expectEqualStrings("{\"location\":\"", result2.?.toolcall_delta.delta);
}

test "buildRequestBody - with system prompt" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg = config.OpenAIConfig{
        .auth = .{ .api_key = "test-key" },
        .model = "gpt-4",
        .params = .{
            .system_prompt = "You are a helpful assistant.",
        },
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Hello!" } },
            },
            .timestamp = 0,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"You are a helpful assistant.\"") != null);
}
