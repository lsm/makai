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
) !provider.Provider {
    const ctx = try allocator.create(OpenAIContext);
    ctx.* = .{
        .config = cfg,
        .allocator = allocator,
    };

    return provider.Provider{
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

    const stream = try allocator.create(event_stream.AssistantMessageStream);
    stream.* = event_stream.AssistantMessageStream.init(allocator);

    const request_body = try buildRequestBody(ctx.config, messages, allocator);

    const thread_ctx = try allocator.create(StreamThreadContext);
    thread_ctx.* = .{
        .stream = stream,
        .request_body = try allocator.dupe(u8, request_body),
        .config = ctx.config,
        .allocator = allocator,
    };
    allocator.free(request_body);

    const thread = try std.Thread.spawn(.{}, streamThread, .{thread_ctx});
    thread.detach();

    return stream;
}

/// Cleanup function
fn openaiDeinitFn(ctx_ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx: *OpenAIContext = @ptrCast(@alignCast(ctx_ptr));
    allocator.destroy(ctx);
}

/// Thread context for background streaming
const StreamThreadContext = struct {
    stream: *event_stream.AssistantMessageStream,
    request_body: []u8,
    config: config.OpenAIConfig,
    allocator: std.mem.Allocator,
};

/// Background thread function
fn streamThread(ctx: *StreamThreadContext) void {
    defer {
        ctx.allocator.free(ctx.request_body);
        ctx.allocator.destroy(ctx);
    }

    streamImpl(ctx) catch |err| {
        const err_msg = std.fmt.allocPrint(ctx.allocator, "Stream error: {}", .{err}) catch "Unknown stream error";
        ctx.stream.completeWithError(err_msg);
    };
}

/// Main streaming implementation
fn streamImpl(ctx: *StreamThreadContext) !void {
    // Check cancellation before starting
    if (ctx.config.cancel_token) |token| {
        if (token.isCancelled()) {
            ctx.stream.completeWithError("Stream cancelled");
            return;
        }
    }

    var client = std.http.Client{ .allocator = ctx.allocator };
    defer client.deinit();

    const url = try std.fmt.allocPrint(ctx.allocator, "{s}/v1/chat/completions", .{ctx.config.base_url});
    defer ctx.allocator.free(url);

    const uri = try std.Uri.parse(url);

    // Build headers
    const auth_header = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{ctx.config.auth.api_key});
    defer ctx.allocator.free(auth_header);

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(ctx.allocator);
    try headers.append(ctx.allocator, .{ .name = "authorization", .value = auth_header });
    try headers.append(ctx.allocator, .{ .name = "content-type", .value = "application/json" });

    // Optional organization header
    if (ctx.config.auth.org_id) |org_id| {
        try headers.append(ctx.allocator, .{ .name = "openai-organization", .value = org_id });
    }

    // Apply custom headers
    if (ctx.config.custom_headers) |custom| {
        for (custom) |h| {
            headers.append(ctx.allocator, .{ .name = h.name, .value = h.value }) catch {};
        }
    }

    var request = try client.request(.POST, uri, .{
        .extra_headers = headers.items,
    });
    defer request.deinit();

    request.transfer_encoding = .{ .content_length = ctx.request_body.len };

    try request.sendBodyComplete(ctx.request_body);

    var header_buffer: [4096]u8 = undefined;
    var response = try request.receiveHead(&header_buffer);

    if (response.head.status != .ok) {
        var buffer: [4096]u8 = undefined;
        const error_body = try response.reader(&buffer).*.allocRemaining(ctx.allocator, std.io.Limit.limited(8192));
        defer ctx.allocator.free(error_body);
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "API error {d}: {s}", .{ @intFromEnum(response.head.status), error_body });
        ctx.stream.completeWithError(err_msg);
        return;
    }

    var parser = sse_parser.SSEParser.init(ctx.allocator);
    defer parser.deinit();

    var state = OpenAIStreamState.init(ctx.allocator);
    defer state.deinit();

    var transfer_buffer: [4096]u8 = undefined;
    var buffer: [4096]u8 = undefined;
    var accumulated_content: std.ArrayList(types.ContentBlock) = .{};
    defer {
        for (accumulated_content.items) |block| {
            switch (block) {
                .text => |t| if (t.text.len > 0) ctx.allocator.free(@constCast(t.text)),
                .tool_use => |tu| {
                    ctx.allocator.free(tu.id);
                    ctx.allocator.free(tu.name);
                    if (tu.input_json.len > 0) ctx.allocator.free(@constCast(tu.input_json));
                },
                .thinking => |th| if (th.thinking.len > 0) ctx.allocator.free(@constCast(th.thinking)),
                .image => |img| {
                    ctx.allocator.free(img.media_type);
                    ctx.allocator.free(img.data);
                },
            }
        }
        accumulated_content.deinit(ctx.allocator);
    }

    // Get the reader once before the loop
    const reader = response.reader(&transfer_buffer);

    while (true) {
        // Check cancellation between chunks
        if (ctx.config.cancel_token) |token| {
            if (token.isCancelled()) {
                ctx.stream.completeWithError("Stream cancelled");
                return;
            }
        }

        const bytes_read = try reader.*.readSliceShort(&buffer);
        if (bytes_read == 0) break;

        const events = try parser.feed(buffer[0..bytes_read]);

        for (events) |event| {
            const message_event = try mapSSEToMessageEvent(event, &state, ctx.allocator);
            if (message_event) |evt| {
                // Accumulate content for final AssistantMessage
                switch (evt) {
                    .text_start => {
                        try accumulated_content.append(ctx.allocator, types.ContentBlock{ .text = .{ .text = "" } });
                    },
                    .text_delta => |delta| {
                        if (accumulated_content.items.len > 0) {
                            const last_idx = accumulated_content.items.len - 1;
                            const block = &accumulated_content.items[last_idx];
                            switch (block.*) {
                                .text => |*t| {
                                    const old_text = t.text;
                                    t.text = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ old_text, delta.delta });
                                    if (old_text.len > 0) ctx.allocator.free(@constCast(old_text));
                                },
                                else => {},
                            }
                        }
                    },
                    .toolcall_start => |tc| {
                        try accumulated_content.append(ctx.allocator, types.ContentBlock{ .tool_use = .{
                            .id = try ctx.allocator.dupe(u8, tc.id),
                            .name = try ctx.allocator.dupe(u8, tc.name),
                            .input_json = "",
                        } });
                    },
                    .toolcall_delta => |delta| {
                        // Find the right tool call block by index
                        if (delta.index < accumulated_content.items.len) {
                            const block = &accumulated_content.items[delta.index];
                            switch (block.*) {
                                .tool_use => |*tu| {
                                    const old_json = tu.input_json;
                                    tu.input_json = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ old_json, delta.delta });
                                    if (old_json.len > 0) ctx.allocator.free(@constCast(old_json));
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }

                try ctx.stream.push(evt);
            }
        }
    }

    // Build final result
    const final_content = try ctx.allocator.alloc(types.ContentBlock, accumulated_content.items.len);
    @memcpy(final_content, accumulated_content.items);

    const result = types.AssistantMessage{
        .content = final_content,
        .usage = state.usage,
        .stop_reason = if (state.has_emitted_done) (
            // Use the stop reason from the done event - retrieve from the last pushed event
            .stop
        ) else .stop,
        .model = if (state.model) |m| try ctx.allocator.dupe(u8, m) else try ctx.allocator.dupe(u8, ctx.config.model),
        .timestamp = std.time.timestamp(),
    };

    ctx.stream.complete(result);
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

    // Stream options for usage tracking
    if (cfg.include_usage) {
        try writer.writeKey("stream_options");
        try writer.beginObject();
        try writer.writeBoolField("include_usage", true);
        try writer.endObject();
    }

    // Write messages array
    try writer.writeKey("messages");
    try writer.beginArray();

    // Prepend system/developer message if system_prompt is provided
    if (cfg.params.system_prompt) |system| {
        try writer.beginObject();
        // Use "developer" role for reasoning models (o1/o3/o4), "system" for others
        const system_role = if (std.mem.startsWith(u8, cfg.model, "o1") or
            std.mem.startsWith(u8, cfg.model, "o3") or
            std.mem.startsWith(u8, cfg.model, "o4"))
            "developer"
        else
            "system";
        try writer.writeStringField("role", system_role);
        try writer.writeStringField("content", system);
        try writer.endObject();
    }

    for (messages) |msg| {
        try writer.beginObject();

        // Map roles to OpenAI format
        const role_str = switch (msg.role) {
            .user => "user",
            .assistant => "assistant",
            .tool_result => "tool",
        };
        try writer.writeStringField("role", role_str);

        // Tool result messages need tool_call_id
        if (msg.role == .tool_result) {
            if (msg.tool_call_id) |tool_call_id| {
                try writer.writeStringField("tool_call_id", tool_call_id);
            }
        }

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

    // Write max_completion_tokens: explicit config > max_reasoning_tokens > params.max_tokens
    if (cfg.max_completion_tokens) |mct| {
        try writer.writeIntField("max_completion_tokens", mct);
    } else if (cfg.max_reasoning_tokens) |mrt| {
        try writer.writeIntField("max_completion_tokens", mrt);
    } else {
        try writer.writeIntField("max_completion_tokens", cfg.params.max_tokens);
    }
    try writer.writeKey("temperature");
    try writer.writeFloat(cfg.params.temperature);
    if (cfg.params.top_p) |top_p| {
        try writer.writeKey("top_p");
        try writer.writeFloat(top_p);
    }

    // Stop sequences
    if (cfg.params.stop_sequences) |stop_seqs| {
        try writer.writeKey("stop");
        if (stop_seqs.len == 1) {
            try writer.writeString(stop_seqs[0]);
        } else {
            try writer.beginArray();
            for (stop_seqs) |seq| {
                try writer.writeString(seq);
            }
            try writer.endArray();
        }
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
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
        try writer.writeStringField("reasoning_effort", effort_str);
    }

    // Frequency penalty
    if (cfg.params.frequency_penalty) |frequency_penalty| {
        try writer.writeKey("frequency_penalty");
        try writer.writeFloat(frequency_penalty);
    }

    // Presence penalty
    if (cfg.params.presence_penalty) |presence_penalty| {
        try writer.writeKey("presence_penalty");
        try writer.writeFloat(presence_penalty);
    }

    // Parallel tool calls
    if (cfg.parallel_tool_calls) |parallel_tool_calls| {
        try writer.writeBoolField("parallel_tool_calls", parallel_tool_calls);
    }

    // Seed
    if (cfg.params.seed) |seed| {
        try writer.writeIntField("seed", seed);
    }

    // User
    if (cfg.params.user) |user| {
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
    model: ?[]const u8 = null,
    has_emitted_done: bool = false,
    usage: types.Usage = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OpenAIStreamState {
        return .{
            .text_started = false,
            .current_tool_index = null,
            .accumulated_content = std.ArrayList(u8){},
            .model = null,
            .has_emitted_done = false,
            .usage = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OpenAIStreamState) void {
        self.accumulated_content.deinit(self.allocator);
        if (self.model) |m| self.allocator.free(m);
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
        // If we already emitted a done event from finish_reason, don't emit another
        if (state.has_emitted_done) return null;
        return types.MessageEvent{
            .done = .{
                .usage = state.usage,
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
    ) catch {
        return null;
    };
    defer parsed.deinit();

    const root = parsed.value;

    // Extract model from first chunk for start event
    if (state.model == null) {
        if (root.object.get("model")) |model_val| {
            if (model_val == .string) {
                state.model = try allocator.dupe(u8, model_val.string);
                // Emit start event with model name
                return types.MessageEvent{
                    .start = .{ .model = try allocator.dupe(u8, model_val.string) },
                };
            }
        }
    }

    // Parse usage from streaming chunks (when stream_options.include_usage is true)
    // The final chunk has usage data and empty choices
    if (root.object.get("usage")) |usage_val| {
        if (usage_val != .null) {
            if (usage_val.object.get("prompt_tokens")) |pt| {
                if (pt == .integer) state.usage.input_tokens = @intCast(@as(u64, @bitCast(pt.integer)));
            }
            if (usage_val.object.get("completion_tokens")) |ct| {
                if (ct == .integer) state.usage.output_tokens = @intCast(@as(u64, @bitCast(ct.integer)));
            }
        }
    }

    const choices = root.object.get("choices") orelse return null;
    if (choices != .array) return null;
    if (choices.array.items.len == 0) return null;

    const choice = choices.array.items[0];
    if (choice != .object) return null;

    // Handle finish_reason first (it can come with or without delta)
    if (choice.object.get("finish_reason")) |finish_reason| {
        if (finish_reason == .string) {
            const reason = finish_reason.string;
            const stop_reason: types.StopReason = if (std.mem.eql(u8, reason, "stop"))
                .stop
            else if (std.mem.eql(u8, reason, "length"))
                .length
            else if (std.mem.eql(u8, reason, "tool_calls"))
                .tool_use
            else if (std.mem.eql(u8, reason, "content_filter"))
                .content_filter
            else
                .stop;

            state.has_emitted_done = true;
            return types.MessageEvent{
                .done = .{
                    .usage = state.usage,
                    .stop_reason = stop_reason,
                },
            };
        }
    }

    const delta = choice.object.get("delta") orelse return null;
    if (delta != .object) return null;

    // Handle content delta
    if (delta.object.get("content")) |content| {
        if (content == .string) {
            const text = content.string;

            if (!state.text_started) {
                state.text_started = true;
                // Return text_start, but we also need to emit the first delta
                // OpenAI combines the first content with the first delta,
                // so emit text_start here and the caller will get the delta on next call
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
    }

    // Handle tool calls with proper index tracking
    if (delta.object.get("tool_calls")) |tool_calls| {
        if (tool_calls == .array and tool_calls.array.items.len > 0) {
            const tool_call = tool_calls.array.items[0];
            if (tool_call != .object) return null;

            // Get the tool call index from the JSON (OpenAI provides this)
            const tc_index: usize = if (tool_call.object.get("index")) |idx|
                (if (idx == .integer) @as(usize, @intCast(idx.integer)) else 0)
            else
                0;

            if (tool_call.object.get("function")) |function| {
                if (function != .object) return null;
                const name = function.object.get("name");
                const arguments = function.object.get("arguments");

                if (name) |n| {
                    if (n == .string) {
                        // New tool call starting
                        const id = tool_call.object.get("id");
                        const id_str = if (id) |i| (if (i == .string) i.string else "unknown") else "unknown";

                        state.current_tool_index = tc_index;
                        return types.MessageEvent{
                            .toolcall_start = .{
                                .index = tc_index,
                                .id = try allocator.dupe(u8, id_str),
                                .name = try allocator.dupe(u8, n.string),
                            },
                        };
                    }
                }
                if (arguments) |args| {
                    if (args == .string) {
                        return types.MessageEvent{
                            .toolcall_delta = .{
                                .index = tc_index,
                                .delta = try allocator.dupe(u8, args.string),
                            },
                        };
                    }
                }
            }
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
    try testing.expect(std.mem.indexOf(u8, body, "\"max_completion_tokens\":1000") != null);
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

    // First chunk should emit start event (model extraction)
    const event0 = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"model\":\"gpt-4\",\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}",
    };

    const result0 = try mapSSEToMessageEvent(event0, &state, allocator);
    try testing.expect(result0 != null);
    try testing.expect(result0.? == .start);
    allocator.free(result0.?.start.model);

    // First content delta should emit text_start
    const event1 = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"model\":\"gpt-4\",\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}",
    };

    const result1 = try mapSSEToMessageEvent(event1, &state, allocator);
    try testing.expect(result1 != null);
    try testing.expect(result1.? == .text_start);

    // Second content delta should emit text_delta
    const event2 = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"model\":\"gpt-4\",\"choices\":[{\"delta\":{\"content\":\" world\"},\"finish_reason\":null}]}",
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
    // Pre-seed model so first chunk doesn't emit start event
    state.model = try allocator.dupe(u8, "gpt-4");

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
    // Pre-seed model so first chunk doesn't emit start event
    state.model = try allocator.dupe(u8, "gpt-4");

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
    // Pre-seed model so first chunk doesn't emit start event
    state.model = try allocator.dupe(u8, "gpt-4");

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

test "buildRequestBody - stream_options included by default" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg = config.OpenAIConfig{
        .auth = .{ .api_key = "test-key" },
        .model = "gpt-4",
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

    try testing.expect(std.mem.indexOf(u8, body, "\"stream_options\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"include_usage\":true") != null);
}

test "buildRequestBody - stop sequences" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const stop_seqs = [_][]const u8{ "STOP", "END" };
    const cfg = config.OpenAIConfig{
        .auth = .{ .api_key = "test-key" },
        .model = "gpt-4",
        .params = .{
            .stop_sequences = &stop_seqs,
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

    try testing.expect(std.mem.indexOf(u8, body, "\"stop\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"STOP\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"END\"") != null);
}

test "buildRequestBody - tool result message" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg = config.OpenAIConfig{
        .auth = .{ .api_key = "test-key" },
        .model = "gpt-4",
    };

    const messages = [_]types.Message{
        .{
            .role = .tool_result,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "The weather is sunny" } },
            },
            .tool_call_id = "call_abc123",
            .timestamp = 0,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"tool\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"call_abc123\"") != null);
}

test "buildRequestBody - developer role for reasoning models" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg = config.OpenAIConfig{
        .auth = .{ .api_key = "test-key" },
        .model = "o3-mini",
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

    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"developer\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") == null);
}

test "buildRequestBody - max_completion_tokens override" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg = config.OpenAIConfig{
        .auth = .{ .api_key = "test-key" },
        .model = "gpt-4",
        .max_completion_tokens = 8192,
        .params = .{
            .max_tokens = 1000,
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

    try testing.expect(std.mem.indexOf(u8, body, "\"max_completion_tokens\":8192") != null);
    // Should NOT contain the fallback value
    try testing.expect(std.mem.indexOf(u8, body, "\"max_completion_tokens\":1000") == null);
}

test "mapSSEToMessageEvent - content_filter finish reason" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = OpenAIStreamState.init(allocator);
    defer state.deinit();
    state.model = try allocator.dupe(u8, "gpt-4");

    const event = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"model\":\"gpt-4\",\"choices\":[{\"delta\":{},\"finish_reason\":\"content_filter\"}]}",
    };

    const result = try mapSSEToMessageEvent(event, &state, allocator);
    try testing.expect(result != null);
    try testing.expect(result.? == .done);
    try testing.expect(result.?.done.stop_reason == .content_filter);
}

test "mapSSEToMessageEvent - usage from streaming chunk" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = OpenAIStreamState.init(allocator);
    defer state.deinit();
    state.model = try allocator.dupe(u8, "gpt-4");

    // Final usage chunk (empty choices, usage populated)
    const event = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"model\":\"gpt-4\",\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":20,\"total_tokens\":30}}",
    };

    const result = try mapSSEToMessageEvent(event, &state, allocator);
    // Empty choices returns null, but usage should be accumulated in state
    try testing.expect(result == null);
    try testing.expectEqual(@as(u64, 10), state.usage.input_tokens);
    try testing.expectEqual(@as(u64, 20), state.usage.output_tokens);
}

test "mapSSEToMessageEvent - tool call with index" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = OpenAIStreamState.init(allocator);
    defer state.deinit();
    state.model = try allocator.dupe(u8, "gpt-4");

    // Tool call with index=1 (second parallel tool call)
    const event = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"model\":\"gpt-4\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"call_456\",\"function\":{\"name\":\"search\"}}]},\"finish_reason\":null}]}",
    };

    const result = try mapSSEToMessageEvent(event, &state, allocator);
    defer if (result) |r| {
        if (r == .toolcall_start) {
            allocator.free(r.toolcall_start.id);
            allocator.free(r.toolcall_start.name);
        }
    };

    try testing.expect(result != null);
    try testing.expect(result.? == .toolcall_start);
    try testing.expectEqual(@as(usize, 1), result.?.toolcall_start.index);
    try testing.expectEqualStrings("call_456", result.?.toolcall_start.id);
    try testing.expectEqualStrings("search", result.?.toolcall_start.name);
}

test "mapSSEToMessageEvent - model extraction from first chunk" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = OpenAIStreamState.init(allocator);
    defer state.deinit();

    const event = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"id\":\"chatcmpl-123\",\"model\":\"gpt-4o-2024-08-06\",\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}",
    };

    const result = try mapSSEToMessageEvent(event, &state, allocator);
    try testing.expect(result != null);
    try testing.expect(result.? == .start);

    // The start event should have the model name
    try testing.expectEqualStrings("gpt-4o-2024-08-06", result.?.start.model);
    allocator.free(result.?.start.model);

    // State should also have the model captured
    try testing.expectEqualStrings("gpt-4o-2024-08-06", state.model.?);
}

test "mapSSEToMessageEvent - done not duplicated after finish_reason" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = OpenAIStreamState.init(allocator);
    defer state.deinit();
    state.model = try allocator.dupe(u8, "gpt-4");

    // finish_reason chunk
    const event1 = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"model\":\"gpt-4\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}",
    };

    const result1 = try mapSSEToMessageEvent(event1, &state, allocator);
    try testing.expect(result1 != null);
    try testing.expect(result1.? == .done);

    // [DONE] should NOT emit another done event
    const event2 = sse_parser.SSEEvent{
        .event_type = null,
        .data = "[DONE]",
    };

    const result2 = try mapSSEToMessageEvent(event2, &state, allocator);
    try testing.expect(result2 == null);
}
