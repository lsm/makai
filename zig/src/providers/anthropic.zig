const std = @import("std");
const types = @import("types");
const event_stream = @import("event_stream");
const provider = @import("provider");
const config = @import("config");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");

/// Anthropic provider context
pub const AnthropicContext = struct {
    config: config.AnthropicConfig,
    allocator: std.mem.Allocator,
};

/// Create an Anthropic provider
pub fn createProvider(
    cfg: config.AnthropicConfig,
    allocator: std.mem.Allocator,
) !provider.Provider {
    const ctx = try allocator.create(AnthropicContext);
    ctx.* = .{
        .config = cfg,
        .allocator = allocator,
    };

    return provider.Provider{
        .id = "anthropic",
        .name = "Anthropic Claude",
        .context = @ptrCast(ctx),
        .stream_fn = anthropicStreamFn,
        .deinit_fn = anthropicDeinitFn,
    };
}

/// Stream function implementation
fn anthropicStreamFn(
    ctx_ptr: *anyopaque,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageStream {
    const ctx: *AnthropicContext = @ptrCast(@alignCast(ctx_ptr));

    const stream = try allocator.create(event_stream.AssistantMessageStream);
    stream.* = event_stream.AssistantMessageStream.init(allocator);

    const request_body = try buildRequestBody(ctx.config, messages, allocator);
    defer allocator.free(request_body);

    const thread_ctx = try allocator.create(StreamThreadContext);
    thread_ctx.* = .{
        .stream = stream,
        .request_body = try allocator.dupe(u8, request_body),
        .config = ctx.config,
        .allocator = allocator,
    };

    const thread = try std.Thread.spawn(.{}, streamThread, .{thread_ctx});
    thread.detach();

    return stream;
}

/// Cleanup function
fn anthropicDeinitFn(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const anthropic_ctx: *AnthropicContext = @ptrCast(@alignCast(ctx));
    allocator.destroy(anthropic_ctx);
}

/// Thread context for background streaming
const StreamThreadContext = struct {
    stream: *event_stream.AssistantMessageStream,
    request_body: []u8,
    config: config.AnthropicConfig,
    allocator: std.mem.Allocator,
};

/// Check if the API key is an OAuth token
fn isOAuthToken(api_key: []const u8) bool {
    return std.mem.indexOf(u8, api_key, "sk-ant-oat") != null;
}

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

    const url = try std.fmt.allocPrint(ctx.allocator, "{s}/v1/messages", .{ctx.config.base_url});
    defer ctx.allocator.free(url);

    const uri = try std.Uri.parse(url);

    // Build headers
    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(ctx.allocator);

    // Allocate auth header outside the if block so it lives until after the request
    var auth_header: ?[]const u8 = null;
    defer if (auth_header) |h| ctx.allocator.free(h);

    // Check if this is an OAuth token
    if (isOAuthToken(ctx.config.auth.api_key)) {
        // OAuth: Bearer auth with Claude Code identity
        auth_header = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{ctx.config.auth.api_key});

        try headers.append(ctx.allocator, .{ .name = "authorization", .value = auth_header.? });
        try headers.append(ctx.allocator, .{ .name = "anthropic-version", .value = ctx.config.api_version });
        try headers.append(ctx.allocator, .{ .name = "anthropic-beta", .value = "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14" });
        try headers.append(ctx.allocator, .{ .name = "user-agent", .value = "claude-cli/2.1.2 (external, cli)" });
        try headers.append(ctx.allocator, .{ .name = "x-app", .value = "cli" });
    } else {
        // API key auth (existing behavior)
        try headers.append(ctx.allocator, .{ .name = "x-api-key", .value = ctx.config.auth.api_key });
        try headers.append(ctx.allocator, .{ .name = "anthropic-version", .value = ctx.config.api_version });
    }
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

    var transfer_buffer: [4096]u8 = undefined;
    var buffer: [4096]u8 = undefined;
    var accumulated_content: std.ArrayList(types.ContentBlock) = .{};
    var content_transferred = false;
    defer {
        // Only clean up strings if they weren't transferred to AssistantMessage
        if (!content_transferred) {
            for (accumulated_content.items) |block| {
                switch (block) {
                    .text => |t| {
                        if (t.text.len > 0) ctx.allocator.free(@constCast(t.text));
                    },
                    .thinking => |th| {
                        if (th.thinking.len > 0) ctx.allocator.free(@constCast(th.thinking));
                    },
                    .tool_use => |tu| {
                        ctx.allocator.free(@constCast(tu.id));
                        ctx.allocator.free(@constCast(tu.name));
                        if (tu.input_json.len > 0) ctx.allocator.free(@constCast(tu.input_json));
                    },
                    else => {},
                }
            }
        }
        accumulated_content.deinit(ctx.allocator);
    }

    var signatures = std.AutoHashMap(usize, std.ArrayList(u8)).init(ctx.allocator);
    defer {
        var it = signatures.valueIterator();
        while (it.next()) |list| {
            list.deinit(ctx.allocator);
        }
        signatures.deinit();
    }

    var usage = types.Usage{};
    var stop_reason: types.StopReason = .stop;
    var model: []const u8 = ctx.config.model;
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |m| ctx.allocator.free(m);

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
            // Check for signature_delta before normal event processing
            if (event.data.len > 0) {
                if (std.mem.indexOf(u8, event.data, "\"signature_delta\"") != null) {
                    // Parse signature delta
                    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, event.data, .{}) catch continue;
                    defer parsed.deinit();
                    const root = parsed.value;

                    if (root == .object) {
                        const delta_obj = root.object.get("delta") orelse continue;
                        if (delta_obj == .object) {
                            const delta_type = delta_obj.object.get("type") orelse continue;
                            if (delta_type == .string and std.mem.eql(u8, delta_type.string, "signature_delta")) {
                                const sig_val = delta_obj.object.get("signature") orelse continue;
                                if (sig_val == .string) {
                                    const index_val = root.object.get("index") orelse continue;
                                    if (index_val == .integer) {
                                        const idx: usize = @intCast(@as(u64, @bitCast(index_val.integer)));
                                        const entry = try signatures.getOrPut(idx);
                                        if (!entry.found_existing) {
                                            entry.value_ptr.* = .{};
                                        }
                                        try entry.value_ptr.appendSlice(ctx.allocator, sig_val.string);
                                    }
                                }
                            }
                        }
                    }
                    continue; // Skip normal event processing for signature events
                }
            }

            const message_event = try mapSSEToMessageEvent(event, ctx.allocator);
            if (message_event) |evt| {
                switch (evt) {
                    .start => |s| {
                        if (model_owned) |m| ctx.allocator.free(m);
                        model_owned = try ctx.allocator.dupe(u8, s.model);
                        model = model_owned.?;
                        usage.input_tokens = s.input_tokens;
                        // Note: s.model is NOT freed here because the event is pushed to the stream,
                        // and the stream (or its consumers) take ownership of the event's memory.
                    },
                    .done => |d| {
                        // Only update output_tokens - input_tokens was already set from message_start
                        // The done event's usage only contains output_tokens, so overwriting the
                        // entire usage struct would lose input_tokens.
                        usage.output_tokens = d.usage.output_tokens;
                        stop_reason = d.stop_reason;
                    },
                    .text_start, .thinking_start, .toolcall_start => {
                        try accumulated_content.append(ctx.allocator, switch (evt) {
                            .text_start => types.ContentBlock{ .text = .{ .text = &[_]u8{} } },
                            .thinking_start => types.ContentBlock{ .thinking = .{ .thinking = &[_]u8{} } },
                            .toolcall_start => |tc| types.ContentBlock{ .tool_use = .{
                                .id = try ctx.allocator.dupe(u8, tc.id),
                                .name = try ctx.allocator.dupe(u8, tc.name),
                                .input_json = &[_]u8{},
                            } },
                            else => unreachable,
                        });
                    },
                    .text_delta, .thinking_delta, .toolcall_delta => |delta| {
                        if (delta.index < accumulated_content.items.len) {
                            const block = &accumulated_content.items[delta.index];
                            switch (block.*) {
                                .text => |*t| {
                                    const old_text = t.text;
                                    t.text = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ old_text, delta.delta });
                                    if (old_text.len > 0) ctx.allocator.free(old_text);
                                },
                                .thinking => |*th| {
                                    const old_thinking = th.thinking;
                                    th.thinking = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ old_thinking, delta.delta });
                                    if (old_thinking.len > 0) ctx.allocator.free(old_thinking);
                                },
                                .tool_use => |*tu| {
                                    const old_json = tu.input_json;
                                    tu.input_json = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ old_json, delta.delta });
                                    if (old_json.len > 0) ctx.allocator.free(old_json);
                                },
                                .image => {},
                            }
                        }
                    },
                    else => {},
                }

                try ctx.stream.push(evt);
            }
        }
    }

    const final_content = try ctx.allocator.alloc(types.ContentBlock, accumulated_content.items.len);
    @memcpy(final_content, accumulated_content.items);

    // Mark content as transferred so defer doesn't free the strings
    content_transferred = true;

    // Attach signatures to content blocks
    for (final_content, 0..) |*block, i| {
        if (signatures.get(i)) |sig_list| {
            const sig = try ctx.allocator.dupe(u8, sig_list.items);
            switch (block.*) {
                .thinking => |*t| t.signature = sig,
                .text => |*t| t.signature = sig,
                .tool_use => |*t| t.thought_signature = sig,
                else => {},
            }
        }
    }

    const result = types.AssistantMessage{
        .content = final_content,
        .usage = usage,
        .stop_reason = stop_reason,
        .model = model_owned orelse try ctx.allocator.dupe(u8, model),
        .timestamp = std.time.timestamp(),
    };

    // Transfer ownership of model_owned to result, so don't free it in defer
    model_owned = null;

    ctx.stream.complete(result);
}

/// Build request body JSON
pub fn buildRequestBody(
    cfg: config.AnthropicConfig,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);

    var writer = json_writer.JsonWriter.init(&buffer, allocator);

    try writer.beginObject();

    try writer.writeStringField("model", cfg.model);
    try writer.writeIntField("max_tokens", cfg.params.max_tokens);
    try writer.writeBoolField("stream", true);

    if (cfg.params.temperature != 1.0) {
        try writer.writeKey("temperature");
        try writer.writeFloat(cfg.params.temperature);
    }

    if (cfg.params.top_p) |top_p| {
        try writer.writeKey("top_p");
        try writer.writeFloat(top_p);
    }

    if (cfg.params.top_k) |top_k| {
        try writer.writeIntField("top_k", top_k);
    }

    if (cfg.params.stop_sequences) |stop_seqs| {
        try writer.writeKey("stop_sequences");
        try writer.beginArray();
        for (stop_seqs) |seq| {
            try writer.writeString(seq);
        }
        try writer.endArray();
    }

    if (cfg.params.system_prompt) |system| {
        // For OAuth tokens, we need to override the system prompt with Claude Code identity
        if (isOAuthToken(cfg.auth.api_key)) {
            try writer.writeKey("system");
            try writer.beginArray();
            // First block: Claude Code identity (required for OAuth to work)
            try writer.beginObject();
            try writer.writeStringField("type", "text");
            try writer.writeStringField("text", "You are Claude Code, Anthropic's official CLI for Claude.");
            try writer.endObject();
            // Second block: User's original system prompt
            try writer.beginObject();
            try writer.writeStringField("type", "text");
            try writer.writeStringField("text", system);
            try writer.endObject();
            try writer.endArray();
        } else {
            try writer.writeStringField("system", system);
        }
    }

    if (cfg.params.tools) |tools| {
        try writer.writeKey("tools");
        try writer.beginArray();
        for (tools) |tool| {
            try writer.beginObject();
            try writer.writeStringField("name", tool.name);
            if (tool.description) |desc| {
                try writer.writeStringField("description", desc);
            }
            try writer.writeKey("input_schema");
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
        }
        try writer.endArray();
    }

    if (cfg.params.tool_choice) |tool_choice| {
        try writer.writeKey("tool_choice");
        switch (tool_choice) {
            .auto, .none, .any => {
                try writer.beginObject();
                const type_str = switch (tool_choice) {
                    .auto => "auto",
                    .none => "none",
                    .any => "any",
                    else => unreachable,
                };
                try writer.writeStringField("type", type_str);
                try writer.endObject();
            },
            .specific => |name| {
                try writer.beginObject();
                try writer.writeStringField("type", "tool");
                try writer.writeStringField("name", name);
                try writer.endObject();
            },
        }
    }

    try writer.writeKey("messages");
    try writer.beginArray();
    for (messages) |message| {
        try writer.beginObject();

        const role_str = switch (message.role) {
            .user => "user",
            .assistant => "assistant",
            .tool_result => "user",
        };
        try writer.writeStringField("role", role_str);

        if (message.role == .tool_result) {
            // Tool results require special serialization with tool_use_id and is_error
            try writer.writeKey("content");
            try writer.beginArray();
            try writer.beginObject();
            try writer.writeStringField("type", "tool_result");
            if (message.tool_call_id) |tool_id| {
                try writer.writeStringField("tool_use_id", tool_id);
            }
            if (message.is_error) {
                try writer.writeBoolField("is_error", true);
            }
            // Serialize the content as the content field
            if (message.content.len == 1) {
                switch (message.content[0]) {
                    .text => |text| {
                        try writer.writeStringField("content", text.text);
                    },
                    else => {
                        try writer.writeKey("content");
                        try writeContentBlocks(&writer, message.content);
                    },
                }
            } else {
                try writer.writeKey("content");
                try writeContentBlocks(&writer, message.content);
            }
            try writer.endObject();
            try writer.endArray();
        } else {
            if (message.content.len == 1) {
                switch (message.content[0]) {
                    .text => |text| {
                        try writer.writeStringField("content", text.text);
                    },
                    else => {
                        try writer.writeKey("content");
                        try writeContentBlocks(&writer, message.content);
                    },
                }
            } else {
                try writer.writeKey("content");
                try writeContentBlocks(&writer, message.content);
            }
        }

        try writer.endObject();
    }
    try writer.endArray();

    if (cfg.thinking_level) |level| {
        try writer.writeKey("thinking");
        try writer.beginObject();
        const level_str = switch (level) {
            .minimal => "minimal",
            .low => "low",
            .medium => "medium",
            .high => "high",
            .xhigh => "xhigh",
        };
        try writer.writeStringField("type", level_str);
        if (cfg.thinking_budget) |budget| {
            try writer.writeIntField("budget_tokens", budget);
        }
        try writer.endObject();
    }

    if (cfg.params.seed) |seed| {
        try writer.writeIntField("seed", seed);
    }

    if (cfg.params.user) |user| {
        try writer.writeStringField("user", user);
    }

    if (cfg.params.frequency_penalty) |freq_penalty| {
        try writer.writeKey("frequency_penalty");
        try writer.writeFloat(freq_penalty);
    }

    if (cfg.params.presence_penalty) |pres_penalty| {
        try writer.writeKey("presence_penalty");
        try writer.writeFloat(pres_penalty);
    }

    if (cfg.metadata_user_id) |user_id| {
        try writer.writeKey("metadata");
        try writer.beginObject();
        try writer.writeStringField("user_id", user_id);
        try writer.endObject();
    }

    try writer.endObject();

    return buffer.toOwnedSlice(allocator);
}

fn writeContentBlocks(writer: *json_writer.JsonWriter, blocks: []const types.ContentBlock) !void {
    try writer.beginArray();
    for (blocks) |block| {
        try writer.beginObject();
        switch (block) {
            .text => |text| {
                try writer.writeStringField("type", "text");
                try writer.writeStringField("text", text.text);
            },
            .tool_use => |tool_use| {
                try writer.writeStringField("type", "tool_use");
                try writer.writeStringField("id", tool_use.id);
                try writer.writeStringField("name", tool_use.name);
                try writer.writeKey("input");
                try writer.buffer.appendSlice(writer.allocator, tool_use.input_json);
                writer.needs_comma = true;
            },
            .thinking => |thinking| {
                try writer.writeStringField("type", "thinking");
                try writer.writeStringField("thinking", thinking.thinking);
            },
            .image => |image| {
                try writer.writeStringField("type", "image");
                try writer.writeKey("source");
                try writer.beginObject();
                try writer.writeStringField("type", "base64");
                try writer.writeStringField("media_type", image.media_type);
                try writer.writeStringField("data", image.data);
                try writer.endObject();
            },
        }
        try writer.endObject();
    }
    try writer.endArray();
}

/// Map Anthropic SSE event to MessageEvent
pub fn mapSSEToMessageEvent(
    event: sse_parser.SSEEvent,
    allocator: std.mem.Allocator,
) !?types.MessageEvent {
    const event_type = event.event_type orelse return null;

    if (std.mem.eql(u8, event_type, "ping")) {
        return types.MessageEvent{ .ping = {} };
    }

    if (std.mem.eql(u8, event_type, "error")) {
        const parsed = try std.json.parseFromSlice(
            struct { @"error": struct { message: []const u8 } },
            allocator,
            event.data,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        const msg = try allocator.dupe(u8, parsed.value.@"error".message);
        return types.MessageEvent{ .@"error" = .{ .message = msg } };
    }

    if (std.mem.eql(u8, event_type, "message_start")) {
        const parsed = try std.json.parseFromSlice(
            struct {
                message: struct {
                    model: []const u8,
                    usage: struct {
                        input_tokens: u64 = 0,
                    },
                },
            },
            allocator,
            event.data,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        const model = try allocator.dupe(u8, parsed.value.message.model);
        return types.MessageEvent{ .start = .{
            .model = model,
            .input_tokens = parsed.value.message.usage.input_tokens,
        } };
    }

    if (std.mem.eql(u8, event_type, "content_block_start")) {
        const parsed = try std.json.parseFromSlice(
            struct {
                index: usize,
                content_block: struct {
                    type: []const u8,
                    id: ?[]const u8 = null,
                    name: ?[]const u8 = null,
                },
            },
            allocator,
            event.data,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        const block_type = parsed.value.content_block.type;
        const index = parsed.value.index;

        if (std.mem.eql(u8, block_type, "text")) {
            return types.MessageEvent{ .text_start = .{ .index = index } };
        } else if (std.mem.eql(u8, block_type, "thinking")) {
            return types.MessageEvent{ .thinking_start = .{ .index = index } };
        } else if (std.mem.eql(u8, block_type, "tool_use")) {
            const id = try allocator.dupe(u8, parsed.value.content_block.id.?);
            const name = try allocator.dupe(u8, parsed.value.content_block.name.?);
            return types.MessageEvent{ .toolcall_start = .{
                .index = index,
                .id = id,
                .name = name,
            } };
        }
    }

    if (std.mem.eql(u8, event_type, "content_block_delta")) {
        const parsed = try std.json.parseFromSlice(
            struct {
                index: usize,
                delta: struct {
                    type: []const u8,
                    text: ?[]const u8 = null,
                    thinking: ?[]const u8 = null,
                    partial_json: ?[]const u8 = null,
                },
            },
            allocator,
            event.data,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        const delta_type = parsed.value.delta.type;
        const index = parsed.value.index;

        if (std.mem.eql(u8, delta_type, "text_delta")) {
            const text = try allocator.dupe(u8, parsed.value.delta.text.?);
            return types.MessageEvent{ .text_delta = .{ .index = index, .delta = text } };
        } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
            const thinking = try allocator.dupe(u8, parsed.value.delta.thinking.?);
            return types.MessageEvent{ .thinking_delta = .{ .index = index, .delta = thinking } };
        } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
            const json = try allocator.dupe(u8, parsed.value.delta.partial_json.?);
            return types.MessageEvent{ .toolcall_delta = .{ .index = index, .delta = json } };
        }
    }

    if (std.mem.eql(u8, event_type, "content_block_stop")) {
        const parsed = try std.json.parseFromSlice(
            struct { index: usize },
            allocator,
            event.data,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        return types.MessageEvent{ .text_end = .{ .index = parsed.value.index } };
    }

    if (std.mem.eql(u8, event_type, "message_delta")) {
        const parsed = try std.json.parseFromSlice(
            struct {
                delta: struct { stop_reason: ?[]const u8 = null },
                usage: struct {
                    output_tokens: u64,
                },
            },
            allocator,
            event.data,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        const stop_reason: types.StopReason = if (parsed.value.delta.stop_reason) |sr| blk: {
            if (std.mem.eql(u8, sr, "end_turn")) break :blk .stop;
            if (std.mem.eql(u8, sr, "max_tokens")) break :blk .length;
            if (std.mem.eql(u8, sr, "tool_use")) break :blk .tool_use;
            if (std.mem.eql(u8, sr, "stop_sequence")) break :blk .stop;
            break :blk .stop;
        } else .stop;

        return types.MessageEvent{ .done = .{
            .usage = .{ .output_tokens = parsed.value.usage.output_tokens },
            .stop_reason = stop_reason,
        } };
    }

    if (std.mem.eql(u8, event_type, "message_stop")) {
        return null;
    }

    return null;
}

// Tests
test "buildRequestBody basic" {
    const allocator = std.testing.allocator;

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = "test-key" },
        .model = "claude-sonnet-4-20250514",
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Hello, Claude!" } },
            },
            .timestamp = 0,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"claude-sonnet-4-20250514\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Hello, Claude!\"") != null);
}

test "buildRequestBody with thinking" {
    const allocator = std.testing.allocator;

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = "test-key" },
        .thinking_level = .medium,
        .thinking_budget = 5000,
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Think about this" } },
            },
            .timestamp = 0,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"medium\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":5000") != null);
}

test "buildRequestBody with custom parameters" {
    const allocator = std.testing.allocator;

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = "test-key" },
        .params = .{
            .max_tokens = 2048,
            .temperature = 0.7,
            .top_p = 0.9,
        },
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Test" } },
            },
            .timestamp = 0,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":2048") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.7") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"top_p\":0.9") != null);
}

test "mapSSEToMessageEvent message_start" {
    const allocator = std.testing.allocator;

    const event = sse_parser.SSEEvent{
        .event_type = "message_start",
        .data = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_123\",\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":123,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}",
    };

    const message_event = try mapSSEToMessageEvent(event, allocator);
    defer if (message_event) |evt| {
        switch (evt) {
            .start => |s| allocator.free(s.model),
            else => {},
        }
    };

    try std.testing.expect(message_event != null);
    try std.testing.expect(std.meta.activeTag(message_event.?) == .start);
    try std.testing.expectEqualStrings("claude-3-5-sonnet-20241022", message_event.?.start.model);
    try std.testing.expectEqual(@as(u64, 123), message_event.?.start.input_tokens);
}

test "mapSSEToMessageEvent text_delta" {
    const allocator = std.testing.allocator;

    const event = sse_parser.SSEEvent{
        .event_type = "content_block_delta",
        .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}",
    };

    const message_event = try mapSSEToMessageEvent(event, allocator);
    defer if (message_event) |evt| {
        switch (evt) {
            .text_delta => |d| allocator.free(d.delta),
            else => {},
        }
    };

    try std.testing.expect(message_event != null);
    try std.testing.expect(std.meta.activeTag(message_event.?) == .text_delta);
    try std.testing.expectEqual(@as(usize, 0), message_event.?.text_delta.index);
    try std.testing.expectEqualStrings("Hello", message_event.?.text_delta.delta);
}

test "mapSSEToMessageEvent thinking_delta" {
    const allocator = std.testing.allocator;

    const event = sse_parser.SSEEvent{
        .event_type = "content_block_delta",
        .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Let me think...\"}}",
    };

    const message_event = try mapSSEToMessageEvent(event, allocator);
    defer if (message_event) |evt| {
        switch (evt) {
            .thinking_delta => |d| allocator.free(d.delta),
            else => {},
        }
    };

    try std.testing.expect(message_event != null);
    try std.testing.expect(std.meta.activeTag(message_event.?) == .thinking_delta);
    try std.testing.expectEqualStrings("Let me think...", message_event.?.thinking_delta.delta);
}

test "mapSSEToMessageEvent toolcall_start" {
    const allocator = std.testing.allocator;

    const event = sse_parser.SSEEvent{
        .event_type = "content_block_start",
        .data = "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_123\",\"name\":\"search\"}}",
    };

    const message_event = try mapSSEToMessageEvent(event, allocator);
    defer if (message_event) |evt| {
        switch (evt) {
            .toolcall_start => |tc| {
                allocator.free(tc.id);
                allocator.free(tc.name);
            },
            else => {},
        }
    };

    try std.testing.expect(message_event != null);
    try std.testing.expect(std.meta.activeTag(message_event.?) == .toolcall_start);
    try std.testing.expectEqual(@as(usize, 1), message_event.?.toolcall_start.index);
    try std.testing.expectEqualStrings("toolu_123", message_event.?.toolcall_start.id);
    try std.testing.expectEqualStrings("search", message_event.?.toolcall_start.name);
}

test "mapSSEToMessageEvent done" {
    const allocator = std.testing.allocator;

    const event = sse_parser.SSEEvent{
        .event_type = "message_delta",
        .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":150}}",
    };

    const message_event = try mapSSEToMessageEvent(event, allocator);

    try std.testing.expect(message_event != null);
    try std.testing.expect(std.meta.activeTag(message_event.?) == .done);
    try std.testing.expectEqual(@as(u64, 150), message_event.?.done.usage.output_tokens);
    try std.testing.expect(message_event.?.done.stop_reason == .stop);
}

test "usage tracking preserves input_tokens from message_start" {
    // This test verifies that input_tokens from message_start is preserved
    // when the done event is processed.
    //
    // The flow is:
    // 1. message_start sets usage.input_tokens = 123
    // 2. message_delta creates a done event with ONLY output_tokens set
    // 3. The done handler should only update output_tokens, NOT overwrite the entire usage struct

    const start_event = sse_parser.SSEEvent{
        .event_type = "message_start",
        .data = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_123\",\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":123}}}",
    };

    const delta_event = sse_parser.SSEEvent{
        .event_type = "message_delta",
        .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":150}}",
    };

    // Parse message_start - this should capture input_tokens
    const start_msg = try mapSSEToMessageEvent(start_event, std.testing.allocator);
    defer if (start_msg) |evt| {
        switch (evt) {
            .start => |s| std.testing.allocator.free(s.model),
            else => {},
        }
    };

    try std.testing.expect(start_msg != null);
    try std.testing.expect(std.meta.activeTag(start_msg.?) == .start);
    try std.testing.expectEqual(@as(u64, 123), start_msg.?.start.input_tokens);

    // Parse message_delta - this should have output_tokens
    const delta_msg = try mapSSEToMessageEvent(delta_event, std.testing.allocator);

    try std.testing.expect(delta_msg != null);
    try std.testing.expect(std.meta.activeTag(delta_msg.?) == .done);
    try std.testing.expectEqual(@as(u64, 150), delta_msg.?.done.usage.output_tokens);

    // Note: The done event's usage struct only contains output_tokens.
    // The input_tokens is 0 in the done event because it wasn't included in message_delta.
    // This is expected - the fix is in streamImpl() which now only updates output_tokens
    // instead of overwriting the entire usage struct.

    // Simulate the streamImpl usage tracking logic:
    var usage = types.Usage{};
    usage.input_tokens = start_msg.?.start.input_tokens; // From message_start
    usage.output_tokens = delta_msg.?.done.usage.output_tokens; // From message_delta

    // After both events, usage should have both values
    try std.testing.expectEqual(@as(u64, 123), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 150), usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 273), usage.total());
}

test "mapSSEToMessageEvent error" {
    const allocator = std.testing.allocator;

    const event = sse_parser.SSEEvent{
        .event_type = "error",
        .data = "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"Invalid API key\"}}",
    };

    const message_event = try mapSSEToMessageEvent(event, allocator);
    defer if (message_event) |evt| {
        switch (evt) {
            .@"error" => |e| allocator.free(e.message),
            else => {},
        }
    };

    try std.testing.expect(message_event != null);
    try std.testing.expect(std.meta.activeTag(message_event.?) == .@"error");
    try std.testing.expectEqualStrings("Invalid API key", message_event.?.@"error".message);
}

test "mapSSEToMessageEvent ping" {
    const allocator = std.testing.allocator;

    const event = sse_parser.SSEEvent{
        .event_type = "ping",
        .data = "{}",
    };

    const message_event = try mapSSEToMessageEvent(event, allocator);

    try std.testing.expect(message_event != null);
    try std.testing.expect(std.meta.activeTag(message_event.?) == .ping);
}

test "buildRequestBody with system prompt" {
    const allocator = std.testing.allocator;

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = "test-key" },
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

    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":\"You are a helpful assistant.\"") != null);
}

test "buildRequestBody with new parameters" {
    const allocator = std.testing.allocator;

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = "test-key" },
        .params = .{
            .seed = 42,
            .user = "user-123",
            .frequency_penalty = 0.5,
            .presence_penalty = 0.3,
        },
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Test" } },
            },
            .timestamp = 0,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"seed\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"user\":\"user-123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"frequency_penalty\":0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"presence_penalty\":0.3") != null);
}

test "buildRequestBody with metadata_user_id" {
    const allocator = std.testing.allocator;

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = "test-key" },
        .metadata_user_id = "user-456",
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Test" } },
            },
            .timestamp = 0,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"metadata\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"user_id\":\"user-456\"") != null);
}

test "buildRequestBody includes is_error for tool results" {
    const allocator = std.testing.allocator;

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = "test-key" },
        .model = "claude-sonnet-4-20250514",
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Use the tool" } },
            },
            .timestamp = 0,
        },
        .{
            .role = .tool_result,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Tool execution failed" } },
            },
            .tool_call_id = "toolu_123",
            .tool_name = "test_tool",
            .is_error = true,
            .timestamp = 1,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_use_id\":\"toolu_123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"is_error\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Tool execution failed\"") != null);
}

test "buildRequestBody tool result without error" {
    const allocator = std.testing.allocator;

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = "test-key" },
        .model = "claude-sonnet-4-20250514",
    };

    const messages = [_]types.Message{
        .{
            .role = .tool_result,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Success" } },
            },
            .tool_call_id = "toolu_456",
            .is_error = false,
            .timestamp = 1,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_use_id\":\"toolu_456\"") != null);
    // Should not include is_error if false
    try std.testing.expect(std.mem.indexOf(u8, body, "\"is_error\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Success\"") != null);
}

test "isOAuthToken detection" {
    // OAuth tokens contain sk-ant-oat
    try std.testing.expect(isOAuthToken("sk-ant-oat-abc123"));
    try std.testing.expect(isOAuthToken("prefix-sk-ant-oat-xyz"));
    try std.testing.expect(isOAuthToken("sk-ant-oat"));

    // Regular API keys should not be detected as OAuth
    try std.testing.expect(!isOAuthToken("sk-ant-api03-abc123"));
    try std.testing.expect(!isOAuthToken("sk-ant-123456"));
    try std.testing.expect(!isOAuthToken("regular-api-key"));
    try std.testing.expect(!isOAuthToken(""));
}

test "buildRequestBody with system prompt uses array format for OAuth tokens" {
    const allocator = std.testing.allocator;

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = "sk-ant-oat-test-token" },
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

    // Should use array format for system prompt
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":[") != null);
    // Should include Claude Code identity
    try std.testing.expect(std.mem.indexOf(u8, body, "You are Claude Code, Anthropic's official CLI for Claude.") != null);
    // Should include user's system prompt as second text block
    try std.testing.expect(std.mem.indexOf(u8, body, "You are a helpful assistant.") != null);
    // Should have two text blocks
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"text\",\"text\":\"You are Claude Code, Anthropic's official CLI for Claude.\"},{\"type\":\"text\",\"text\":\"You are a helpful assistant.\"}") != null);
}

test "buildRequestBody with system prompt uses string format for regular API keys" {
    const allocator = std.testing.allocator;

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = "sk-ant-api03-test-key" },
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

    // Should use string format for system prompt (not array)
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":\"You are a helpful assistant.\"") != null);
    // Should NOT include Claude Code identity for regular API keys
    try std.testing.expect(std.mem.indexOf(u8, body, "Claude Code") == null);
}

test "buildRequestBody without system prompt does not add Claude Code identity" {
    const allocator = std.testing.allocator;

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = "sk-ant-oat-test-token" },
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

    // Should not include system prompt at all
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\"") == null);
}
