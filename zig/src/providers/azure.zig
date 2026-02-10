const std = @import("std");
const types = @import("types");
const event_stream = @import("event_stream");
const provider = @import("provider");
const config = @import("config");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");

/// Azure OpenAI provider context
pub const AzureContext = struct {
    config: config.AzureConfig,
    allocator: std.mem.Allocator,
};

/// Create an Azure OpenAI provider
pub fn createProvider(
    cfg: config.AzureConfig,
    allocator: std.mem.Allocator,
) !provider.Provider {
    const ctx = try allocator.create(AzureContext);
    ctx.* = .{
        .config = cfg,
        .allocator = allocator,
    };

    return provider.Provider{
        .id = "azure",
        .name = "Azure OpenAI",
        .context = @ptrCast(ctx),
        .stream_fn = azureStreamFn,
        .deinit_fn = azureDeinitFn,
    };
}

/// Stream function implementation
fn azureStreamFn(
    ctx_ptr: *anyopaque,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageStream {
    const ctx: *AzureContext = @ptrCast(@alignCast(ctx_ptr));

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
fn azureDeinitFn(ctx_ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx: *AzureContext = @ptrCast(@alignCast(ctx_ptr));
    allocator.destroy(ctx);
}

/// Thread context for background streaming
const StreamThreadContext = struct {
    stream: *event_stream.AssistantMessageStream,
    request_body: []u8,
    config: config.AzureConfig,
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

    const url = try buildEndpoint(ctx.config, ctx.allocator);
    defer ctx.allocator.free(url);

    const uri = try std.Uri.parse(url);

    // Build headers
    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(ctx.allocator);
    try headers.append(ctx.allocator, .{ .name = "api-key", .value = ctx.config.api_key });
    try headers.append(ctx.allocator, .{ .name = "content-type", .value = "application/json" });

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

    var state = AzureStreamState.init(ctx.allocator);
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

    while (true) {
        // Check cancellation between chunks
        if (ctx.config.cancel_token) |token| {
            if (token.isCancelled()) {
                ctx.stream.completeWithError("Stream cancelled");
                return;
            }
        }

        const bytes_read = try response.reader(&transfer_buffer).*.readSliceShort(&buffer);
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
            .stop
        ) else .stop,
        .model = if (state.model) |m| try ctx.allocator.dupe(u8, m) else try ctx.allocator.dupe(u8, ctx.config.model),
        .timestamp = std.time.timestamp(),
    };

    ctx.stream.complete(result);
}

/// Build Azure endpoint URL
pub fn buildEndpoint(cfg: config.AzureConfig, allocator: std.mem.Allocator) ![]u8 {
    // If base_url provided, use directly
    if (cfg.base_url) |base| {
        return try allocator.dupe(u8, base);
    }

    // Build from resource_name
    const deployment = cfg.deployment_name orelse cfg.model;

    return try std.fmt.allocPrint(
        allocator,
        "https://{s}.openai.azure.com/openai/deployments/{s}/chat/completions?api-version={s}",
        .{ cfg.resource_name, deployment, cfg.api_version },
    );
}

/// Build request body for Azure OpenAI API (OpenAI Responses API format)
pub fn buildRequestBody(
    cfg: config.AzureConfig,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);

    var writer = json_writer.JsonWriter.init(&buffer, allocator);

    try writer.beginObject();
    try writer.writeBoolField("stream", true);

    // Stream options for usage tracking
    if (cfg.include_usage) {
        try writer.writeKey("stream_options");
        try writer.beginObject();
        try writer.writeBoolField("include_usage", true);
        try writer.endObject();
    }

    // Write messages array as "input" (Responses API format)
    try writer.writeKey("input");
    try writer.beginArray();

    // Prepend system/developer message if system_prompt is provided
    if (cfg.params.system_prompt) |system| {
        try writer.beginObject();
        // GPT-5 quirk: inject developer message to disable auto-reasoning
        const is_gpt5 = std.mem.startsWith(u8, cfg.model, "gpt-5");
        const needs_juice_injection = is_gpt5 and cfg.reasoning_effort == null;

        if (needs_juice_injection) {
            // Inject developer message with juice directive
            const juice_system = try std.fmt.allocPrint(allocator, "{s}\n\n# Juice: 0 !important", .{system});
            defer allocator.free(juice_system);
            try writer.writeStringField("role", "developer");
            try writer.writeStringField("content", juice_system);
        } else {
            // Use "developer" role for reasoning models (o1/o3/o4), "system" for others
            const system_role = if (std.mem.startsWith(u8, cfg.model, "o1") or
                std.mem.startsWith(u8, cfg.model, "o3") or
                std.mem.startsWith(u8, cfg.model, "o4"))
                "developer"
            else
                "system";
            try writer.writeStringField("role", system_role);
            try writer.writeStringField("content", system);
        }
        try writer.endObject();
    } else {
        // No system prompt, but need juice injection for GPT-5
        const is_gpt5 = std.mem.startsWith(u8, cfg.model, "gpt-5");
        const needs_juice_injection = is_gpt5 and cfg.reasoning_effort == null;

        if (needs_juice_injection) {
            try writer.beginObject();
            try writer.writeStringField("role", "developer");
            try writer.writeStringField("content", "# Juice: 0 !important");
            try writer.endObject();
        }
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
                try writer.buffer.appendSlice(writer.allocator, schema);
                writer.needs_comma = true;
            },
        }
        try writer.endObject();
    }

    // Session ID for prompt caching
    if (cfg.session_id) |session_id| {
        try writer.writeStringField("prompt_cache_key", session_id);
    }

    try writer.endObject();

    return buffer.toOwnedSlice(allocator);
}

/// Track state across Azure streaming events (same as OpenAI)
pub const AzureStreamState = struct {
    text_started: bool = false,
    current_tool_index: ?usize = null,
    accumulated_content: std.ArrayList(u8),
    model: ?[]const u8 = null,
    has_emitted_done: bool = false,
    usage: types.Usage = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AzureStreamState {
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

    pub fn deinit(self: *AzureStreamState) void {
        self.accumulated_content.deinit(self.allocator);
        if (self.model) |m| self.allocator.free(m);
    }
};

/// Map Azure SSE data to MessageEvent (reuses OpenAI format)
pub fn mapSSEToMessageEvent(
    event: sse_parser.SSEEvent,
    state: *AzureStreamState,
    allocator: std.mem.Allocator,
) !?types.MessageEvent {
    const data = event.data;

    // Check for [DONE] marker
    if (std.mem.eql(u8, data, "[DONE]")) {
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

    // Extract model from first chunk
    if (state.model == null) {
        if (root.object.get("model")) |model_val| {
            if (model_val == .string) {
                state.model = try allocator.dupe(u8, model_val.string);
                return types.MessageEvent{
                    .start = .{ .model = try allocator.dupe(u8, model_val.string) },
                };
            }
        }
    }

    // Parse usage from streaming chunks
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

    // Handle finish_reason
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

    // Handle tool calls
    if (delta.object.get("tool_calls")) |tool_calls| {
        if (tool_calls == .array and tool_calls.array.items.len > 0) {
            const tool_call = tool_calls.array.items[0];
            if (tool_call != .object) return null;

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

test "buildEndpoint - from resource_name" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg = config.AzureConfig{
        .api_key = "test-key",
        .resource_name = "myresource",
        .model = "gpt-4o",
    };

    const endpoint = try buildEndpoint(cfg, allocator);
    defer allocator.free(endpoint);

    try testing.expectEqualStrings(
        "https://myresource.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-10-01-preview",
        endpoint,
    );
}

test "buildEndpoint - with deployment_name override" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg = config.AzureConfig{
        .api_key = "test-key",
        .resource_name = "myresource",
        .model = "gpt-4o",
        .deployment_name = "my-gpt4o-deployment",
    };

    const endpoint = try buildEndpoint(cfg, allocator);
    defer allocator.free(endpoint);

    try testing.expectEqualStrings(
        "https://myresource.openai.azure.com/openai/deployments/my-gpt4o-deployment/chat/completions?api-version=2024-10-01-preview",
        endpoint,
    );
}

test "buildEndpoint - with custom api_version" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg = config.AzureConfig{
        .api_key = "test-key",
        .resource_name = "myresource",
        .model = "gpt-4o",
        .api_version = "2023-05-15",
    };

    const endpoint = try buildEndpoint(cfg, allocator);
    defer allocator.free(endpoint);

    try testing.expect(std.mem.indexOf(u8, endpoint, "api-version=2023-05-15") != null);
}

test "buildEndpoint - with base_url override" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg = config.AzureConfig{
        .api_key = "test-key",
        .resource_name = "myresource",
        .model = "gpt-4o",
        .base_url = "https://custom.endpoint.com/api",
    };

    const endpoint = try buildEndpoint(cfg, allocator);
    defer allocator.free(endpoint);

    try testing.expectEqualStrings("https://custom.endpoint.com/api", endpoint);
}

test "buildRequestBody - basic message with input format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg = config.AzureConfig{
        .api_key = "test-key",
        .resource_name = "myresource",
        .model = "gpt-4o",
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

    // Verify Responses API format uses "input" instead of "messages"
    try testing.expect(std.mem.indexOf(u8, body, "\"input\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Hello\"") != null);
}

test "buildRequestBody - GPT-5 quirk without reasoning" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg = config.AzureConfig{
        .api_key = "test-key",
        .resource_name = "myresource",
        .model = "gpt-5-preview",
        .params = .{
            .system_prompt = "You are helpful.",
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

    // Should inject juice directive
    try testing.expect(std.mem.indexOf(u8, body, "# Juice: 0 !important") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"developer\"") != null);
}

test "buildRequestBody - GPT-5 quirk with reasoning enabled" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg = config.AzureConfig{
        .api_key = "test-key",
        .resource_name = "myresource",
        .model = "gpt-5-preview",
        .reasoning_effort = .medium,
        .params = .{
            .system_prompt = "You are helpful.",
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

    // Should NOT inject juice directive when reasoning is configured
    try testing.expect(std.mem.indexOf(u8, body, "# Juice: 0 !important") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"medium\"") != null);
}

test "buildRequestBody - session_id for prompt caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg = config.AzureConfig{
        .api_key = "test-key",
        .resource_name = "myresource",
        .model = "gpt-4o",
        .session_id = "session-123",
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

    try testing.expect(std.mem.indexOf(u8, body, "\"prompt_cache_key\":\"session-123\"") != null);
}

test "mapSSEToMessageEvent - text delta" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = AzureStreamState.init(allocator);
    defer state.deinit();

    // First chunk with model
    const event0 = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"model\":\"gpt-4o\",\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}",
    };

    const result0 = try mapSSEToMessageEvent(event0, &state, allocator);
    try testing.expect(result0 != null);
    try testing.expect(result0.? == .start);
    allocator.free(result0.?.start.model);

    // First content delta
    const event1 = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"model\":\"gpt-4o\",\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}",
    };

    const result1 = try mapSSEToMessageEvent(event1, &state, allocator);
    try testing.expect(result1 != null);
    try testing.expect(result1.? == .text_start);
}

test "mapSSEToMessageEvent - finish_reason mapping" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = AzureStreamState.init(allocator);
    defer state.deinit();
    state.model = try allocator.dupe(u8, "gpt-4o");

    const event = sse_parser.SSEEvent{
        .event_type = null,
        .data = "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}",
    };

    const result = try mapSSEToMessageEvent(event, &state, allocator);
    try testing.expect(result != null);
    try testing.expect(result.? == .done);
    try testing.expect(result.?.done.stop_reason == .stop);
}
