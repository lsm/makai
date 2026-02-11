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
        defer if (err_msg.len > 0 and !std.mem.eql(u8, err_msg, "Unknown stream error")) ctx.allocator.free(err_msg);
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
        defer ctx.allocator.free(err_msg);
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
    defer accumulated_content.deinit(ctx.allocator);

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
                    .thinking_start => {
                        try accumulated_content.append(ctx.allocator, types.ContentBlock{ .thinking = .{ .thinking = &[_]u8{} } });
                    },
                    .thinking_delta => |delta| {
                        if (accumulated_content.items.len > 0) {
                            const last_idx = accumulated_content.items.len - 1;
                            const block = &accumulated_content.items[last_idx];
                            switch (block.*) {
                                .thinking => |*th| {
                                    const old_thinking = th.thinking;
                                    th.thinking = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ old_thinking, delta.delta });
                                    if (old_thinking.len > 0) ctx.allocator.free(@constCast(old_thinking));
                                },
                                else => {},
                            }
                        }
                    },
                    .text_start => {
                        try accumulated_content.append(ctx.allocator, types.ContentBlock{ .text = .{ .text = &[_]u8{} } });
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
                            .input_json = &[_]u8{},
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
            state.stop_reason
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

/// Track state across Azure streaming events (Responses API format)
pub const AzureStreamState = struct {
    current_item_type: ?ItemType = null,
    current_item_index: ?usize = null,
    model: ?[]const u8 = null,
    has_emitted_done: bool = false,
    stop_reason: types.StopReason = .stop,
    usage: types.Usage = .{},
    allocator: std.mem.Allocator,

    const ItemType = enum {
        reasoning,
        message,
        function_call,
    };

    pub fn init(allocator: std.mem.Allocator) AzureStreamState {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AzureStreamState) void {
        if (self.model) |m| self.allocator.free(m);
    }
};

/// Map Azure SSE data to MessageEvent (Responses API format)
pub fn mapSSEToMessageEvent(
    event: sse_parser.SSEEvent,
    state: *AzureStreamState,
    allocator: std.mem.Allocator,
) !?types.MessageEvent {
    // Azure Responses API sends typed events like OpenAI
    const event_type = event.event_type orelse return null;
    const data = event.data;

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

    // Handle different event types
    if (std.mem.eql(u8, event_type, "response.output_item.added")) {
        const item = root.object.get("item") orelse return null;
        if (item != .object) return null;

        const item_type = item.object.get("type") orelse return null;
        if (item_type != .string) return null;

        const output_index = root.object.get("output_index");
        const index: usize = if (output_index) |oi| (if (oi == .integer) @as(usize, @intCast(oi.integer)) else 0) else 0;

        if (std.mem.eql(u8, item_type.string, "reasoning")) {
            state.current_item_type = .reasoning;
            state.current_item_index = index;
            return types.MessageEvent{
                .thinking_start = .{ .index = index },
            };
        } else if (std.mem.eql(u8, item_type.string, "message")) {
            state.current_item_type = .message;
            state.current_item_index = index;
            return types.MessageEvent{
                .text_start = .{ .index = index },
            };
        } else if (std.mem.eql(u8, item_type.string, "function_call")) {
            const call_id = item.object.get("call_id");
            const name = item.object.get("name");

            const call_id_str = if (call_id) |c| (if (c == .string) c.string else "unknown") else "unknown";
            const name_str = if (name) |n| (if (n == .string) n.string else "unknown") else "unknown";

            state.current_item_type = .function_call;
            state.current_item_index = index;

            return types.MessageEvent{
                .toolcall_start = .{
                    .index = index,
                    .id = try allocator.dupe(u8, call_id_str),
                    .name = try allocator.dupe(u8, name_str),
                },
            };
        }
    } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta")) {
        const delta = root.object.get("delta");
        if (delta == null or delta.? != .string) return null;

        const output_index = root.object.get("output_index");
        const index: usize = if (output_index) |oi| (if (oi == .integer) @as(usize, @intCast(oi.integer)) else 0) else 0;

        return types.MessageEvent{
            .thinking_delta = .{
                .index = index,
                .delta = try allocator.dupe(u8, delta.?.string),
            },
        };
    } else if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
        const delta = root.object.get("delta");
        if (delta == null or delta.? != .string) return null;

        const output_index = root.object.get("output_index");
        const index: usize = if (output_index) |oi| (if (oi == .integer) @as(usize, @intCast(oi.integer)) else 0) else 0;

        return types.MessageEvent{
            .text_delta = .{
                .index = index,
                .delta = try allocator.dupe(u8, delta.?.string),
            },
        };
    } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
        const delta = root.object.get("delta");
        if (delta == null or delta.? != .string) return null;

        const output_index = root.object.get("output_index");
        const index: usize = if (output_index) |oi| (if (oi == .integer) @as(usize, @intCast(oi.integer)) else 0) else 0;

        return types.MessageEvent{
            .toolcall_delta = .{
                .index = index,
                .delta = try allocator.dupe(u8, delta.?.string),
            },
        };
    } else if (std.mem.eql(u8, event_type, "response.output_item.done")) {
        const item = root.object.get("item") orelse return null;
        if (item != .object) return null;

        const item_type = item.object.get("type") orelse return null;
        if (item_type != .string) return null;

        const output_index = root.object.get("output_index");
        const index: usize = if (output_index) |oi| (if (oi == .integer) @as(usize, @intCast(oi.integer)) else 0) else 0;

        if (std.mem.eql(u8, item_type.string, "reasoning")) {
            return types.MessageEvent{
                .thinking_end = .{ .index = index },
            };
        } else if (std.mem.eql(u8, item_type.string, "message")) {
            return types.MessageEvent{
                .text_end = .{ .index = index },
            };
        } else if (std.mem.eql(u8, item_type.string, "function_call")) {
            const arguments = item.object.get("arguments");
            const args_str = if (arguments) |a| (if (a == .string) a.string else "{}") else "{}";

            return types.MessageEvent{
                .toolcall_end = .{
                    .index = index,
                    .input_json = try allocator.dupe(u8, args_str),
                },
            };
        }
    } else if (std.mem.eql(u8, event_type, "response.completed")) {
        const response = root.object.get("response");
        if (response) |resp| {
            if (resp == .object) {
                // Extract usage
                if (resp.object.get("usage")) |usage_val| {
                    if (usage_val != .null) {
                        if (usage_val.object.get("input_tokens")) |it| {
                            if (it == .integer) state.usage.input_tokens = @intCast(@as(u64, @bitCast(it.integer)));
                        }
                        if (usage_val.object.get("output_tokens")) |ot| {
                            if (ot == .integer) state.usage.output_tokens = @intCast(@as(u64, @bitCast(ot.integer)));
                        }
                        // Handle cached tokens from input_tokens_details
                        if (usage_val.object.get("input_tokens_details")) |details| {
                            if (details == .object) {
                                if (details.object.get("cached_tokens")) |ct| {
                                    if (ct == .integer) {
                                        const cached = @as(u64, @intCast(@as(u64, @bitCast(ct.integer))));
                                        state.usage.cache_read_tokens = cached;
                                        // Subtract cached from input tokens
                                        if (state.usage.input_tokens >= cached) {
                                            state.usage.input_tokens -= cached;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Extract status and map to stop reason
                if (resp.object.get("status")) |status_val| {
                    if (status_val == .string) {
                        if (std.mem.eql(u8, status_val.string, "completed")) {
                            state.stop_reason = .stop;
                        } else if (std.mem.eql(u8, status_val.string, "incomplete")) {
                            state.stop_reason = .length;
                        } else if (std.mem.eql(u8, status_val.string, "failed") or std.mem.eql(u8, status_val.string, "cancelled")) {
                            state.stop_reason = .@"error";
                        }
                    }
                }
            }
        }

        state.has_emitted_done = true;
        return types.MessageEvent{
            .done = .{
                .usage = state.usage,
                .stop_reason = state.stop_reason,
            },
        };
    } else if (std.mem.eql(u8, event_type, "error") or std.mem.eql(u8, event_type, "response.failed")) {
        const message = root.object.get("message");
        const msg_str = if (message) |m| (if (m == .string) m.string else "Unknown error") else "Unknown error";

        return types.MessageEvent{
            .@"error" = .{
                .message = try allocator.dupe(u8, msg_str),
            },
        };
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

test "mapSSEToMessageEvent - text events" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = AzureStreamState.init(allocator);
    defer state.deinit();

    // message item added (text_start)
    const event0 = sse_parser.SSEEvent{
        .event_type = "response.output_item.added",
        .data = "{\"item\":{\"type\":\"message\",\"id\":\"msg_123\"},\"output_index\":0}",
    };

    const result0 = try mapSSEToMessageEvent(event0, &state, allocator);
    try testing.expect(result0 != null);
    try testing.expect(result0.? == .text_start);

    // text delta
    const event1 = sse_parser.SSEEvent{
        .event_type = "response.output_text.delta",
        .data = "{\"delta\":\"Hello\",\"output_index\":0}",
    };

    const result1 = try mapSSEToMessageEvent(event1, &state, allocator);
    defer if (result1) |r| {
        if (r == .text_delta) allocator.free(r.text_delta.delta);
    };

    try testing.expect(result1 != null);
    try testing.expect(result1.? == .text_delta);
    try testing.expectEqualStrings("Hello", result1.?.text_delta.delta);
}

test "mapSSEToMessageEvent - reasoning events" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = AzureStreamState.init(allocator);
    defer state.deinit();

    // reasoning item added
    const event1 = sse_parser.SSEEvent{
        .event_type = "response.output_item.added",
        .data = "{\"item\":{\"type\":\"reasoning\",\"id\":\"rs_123\"},\"output_index\":0}",
    };

    const result1 = try mapSSEToMessageEvent(event1, &state, allocator);
    try testing.expect(result1 != null);
    try testing.expect(result1.? == .thinking_start);

    // reasoning delta
    const event2 = sse_parser.SSEEvent{
        .event_type = "response.reasoning_summary_text.delta",
        .data = "{\"delta\":\"thinking...\",\"item_id\":\"rs_123\",\"output_index\":0}",
    };

    const result2 = try mapSSEToMessageEvent(event2, &state, allocator);
    defer if (result2) |r| {
        if (r == .thinking_delta) allocator.free(r.thinking_delta.delta);
    };

    try testing.expect(result2 != null);
    try testing.expect(result2.? == .thinking_delta);
    try testing.expectEqualStrings("thinking...", result2.?.thinking_delta.delta);

    // reasoning done
    const event3 = sse_parser.SSEEvent{
        .event_type = "response.output_item.done",
        .data = "{\"item\":{\"type\":\"reasoning\",\"id\":\"rs_123\"},\"output_index\":0}",
    };

    const result3 = try mapSSEToMessageEvent(event3, &state, allocator);
    try testing.expect(result3 != null);
    try testing.expect(result3.? == .thinking_end);
}

test "mapSSEToMessageEvent - response completed" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = AzureStreamState.init(allocator);
    defer state.deinit();

    const event = sse_parser.SSEEvent{
        .event_type = "response.completed",
        .data = "{\"response\":{\"id\":\"resp_123\",\"status\":\"completed\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50,\"input_tokens_details\":{\"cached_tokens\":20}}}}",
    };

    const result = try mapSSEToMessageEvent(event, &state, allocator);
    try testing.expect(result != null);
    try testing.expect(result.? == .done);
    try testing.expectEqual(@as(u64, 80), state.usage.input_tokens); // 100 - 20 cached
    try testing.expectEqual(@as(u64, 50), state.usage.output_tokens);
    try testing.expectEqual(@as(u64, 20), state.usage.cache_read_tokens);
    try testing.expect(result.?.done.stop_reason == .stop);
}

test "mapSSEToMessageEvent - tool call events" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = AzureStreamState.init(allocator);
    defer state.deinit();

    // function_call added
    const event1 = sse_parser.SSEEvent{
        .event_type = "response.output_item.added",
        .data = "{\"item\":{\"type\":\"function_call\",\"id\":\"fc_123\",\"call_id\":\"call_abc\",\"name\":\"get_weather\"},\"output_index\":1}",
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
    try testing.expectEqualStrings("call_abc", result1.?.toolcall_start.id);
    try testing.expectEqualStrings("get_weather", result1.?.toolcall_start.name);

    // arguments delta
    const event2 = sse_parser.SSEEvent{
        .event_type = "response.function_call_arguments.delta",
        .data = "{\"delta\":\"{\\\\\\\"location\\\\\\\":\",\"output_index\":1}",
    };

    const result2 = try mapSSEToMessageEvent(event2, &state, allocator);
    defer if (result2) |r| {
        if (r == .toolcall_delta) allocator.free(r.toolcall_delta.delta);
    };

    try testing.expect(result2 != null);
    try testing.expect(result2.? == .toolcall_delta);
    try testing.expectEqualStrings("{\\\"location\\\":", result2.?.toolcall_delta.delta);

    // function_call done
    const event3 = sse_parser.SSEEvent{
        .event_type = "response.output_item.done",
        .data = "{\"item\":{\"type\":\"function_call\",\"id\":\"fc_123\",\"call_id\":\"call_abc\",\"name\":\"get_weather\",\"arguments\":\"{\\\\\\\"location\\\\\\\":\\\\\\\"NYC\\\\\\\"}\"},\"output_index\":1}",
    };

    const result3 = try mapSSEToMessageEvent(event3, &state, allocator);
    defer if (result3) |r| {
        if (r == .toolcall_end) allocator.free(r.toolcall_end.input_json);
    };

    try testing.expect(result3 != null);
    try testing.expect(result3.? == .toolcall_end);
    try testing.expectEqualStrings("{\\\"location\\\":\\\"NYC\\\"}", result3.?.toolcall_end.input_json);
}
