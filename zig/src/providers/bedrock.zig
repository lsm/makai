const std = @import("std");
const types = @import("types");
const event_stream = @import("event_stream");
const provider = @import("provider");
const config = @import("config");
const json_writer = @import("json_writer");
const aws_sigv4 = @import("aws_sigv4");

/// AWS Bedrock provider configuration
pub const BedrockConfig = struct {
    auth: BedrockAuth,
    model: []const u8,
    region: []const u8 = "us-east-1",
    base_url: ?[]const u8 = null,
    params: config.RequestParams = .{},
    thinking_config: ?BedrockThinkingConfig = null,
    cache_retention: config.CacheRetention = .none,
    custom_headers: ?[]const config.HeaderPair = null,
    retry_config: config.RetryConfig = .{},
    cancel_token: ?config.CancelToken = null,
};

pub const BedrockAuth = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: ?[]const u8 = null,
};

pub const BedrockThinkingConfig = struct {
    mode: ThinkingMode,
    budget_tokens: ?u32 = null, // For token-budget mode
    effort: ?Effort = null, // For adaptive mode
};

pub const ThinkingMode = enum { adaptive, enabled };
pub const Effort = enum { low, medium, high, max };

/// Bedrock provider context
pub const BedrockContext = struct {
    config: BedrockConfig,
    allocator: std.mem.Allocator,
};

/// Create a Bedrock provider
pub fn createProvider(
    cfg: BedrockConfig,
    allocator: std.mem.Allocator,
) !provider.Provider {
    const ctx = try allocator.create(BedrockContext);
    ctx.* = .{
        .config = cfg,
        .allocator = allocator,
    };

    return provider.Provider{
        .id = "bedrock",
        .name = "AWS Bedrock",
        .context = @ptrCast(ctx),
        .stream_fn = bedrockStreamFn,
        .deinit_fn = bedrockDeinitFn,
    };
}

fn bedrockStreamFn(
    ctx_ptr: *anyopaque,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageStream {
    const ctx: *BedrockContext = @ptrCast(@alignCast(ctx_ptr));

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

fn bedrockDeinitFn(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const bedrock_ctx: *BedrockContext = @ptrCast(@alignCast(ctx));
    allocator.destroy(bedrock_ctx);
}

const StreamThreadContext = struct {
    stream: *event_stream.AssistantMessageStream,
    request_body: []u8,
    config: BedrockConfig,
    allocator: std.mem.Allocator,
};

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

fn streamImpl(ctx: *StreamThreadContext) !void {
    if (ctx.config.cancel_token) |token| {
        if (token.isCancelled()) {
            ctx.stream.completeWithError("Stream cancelled");
            return;
        }
    }

    var client = std.http.Client{ .allocator = ctx.allocator };
    defer client.deinit();

    const base_url = ctx.config.base_url orelse
        try std.fmt.allocPrint(ctx.allocator, "https://bedrock-runtime.{s}.amazonaws.com", .{ctx.config.region});
    defer if (ctx.config.base_url == null) ctx.allocator.free(base_url);

    const url = try std.fmt.allocPrint(ctx.allocator, "{s}/model/{s}/converse-stream", .{ base_url, ctx.config.model });
    defer ctx.allocator.free(url);

    const uri = try std.Uri.parse(url);
    const host = switch (uri.host.?) {
        .raw => |h| h,
        .percent_encoded => |h| h,
    };

    // Build headers for signing
    var headers = std.StringHashMap([]const u8).init(ctx.allocator);
    defer headers.deinit();

    try headers.put("host", host);
    try headers.put("content-type", "application/json");

    // Sign request
    const path = switch (uri.path) {
        .raw => |p| p,
        .percent_encoded => |p| p,
    };

    const signed = try aws_sigv4.signRequest(
        "POST",
        path,
        "",
        headers,
        ctx.request_body,
        ctx.config.region,
        "bedrock",
        ctx.config.auth.access_key_id,
        ctx.config.auth.secret_access_key,
        ctx.config.auth.session_token,
        ctx.allocator,
    );
    defer ctx.allocator.free(signed.authorization);
    defer ctx.allocator.free(signed.x_amz_date);
    defer if (signed.x_amz_security_token) |token| ctx.allocator.free(token);

    // Build headers for HTTP request
    var http_headers: std.ArrayList(std.http.Header) = .{};
    defer http_headers.deinit(ctx.allocator);
    try http_headers.append(ctx.allocator, .{ .name = "host", .value = host });
    try http_headers.append(ctx.allocator, .{ .name = "content-type", .value = "application/json" });
    try http_headers.append(ctx.allocator, .{ .name = "authorization", .value = signed.authorization });
    try http_headers.append(ctx.allocator, .{ .name = "x-amz-date", .value = signed.x_amz_date });
    if (signed.x_amz_security_token) |token| {
        try http_headers.append(ctx.allocator, .{ .name = "x-amz-security-token", .value = token });
    }

    // Apply custom headers
    if (ctx.config.custom_headers) |custom| {
        for (custom) |h| {
            http_headers.append(ctx.allocator, .{ .name = h.name, .value = h.value }) catch {};
        }
    }

    var request = try client.request(.POST, uri, .{
        .extra_headers = http_headers.items,
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

    var transfer_buffer: [4096]u8 = undefined;
    try parseBedrockEventStream(response.reader(&transfer_buffer), ctx);
}

/// Parse Bedrock event stream (custom format, not SSE)
fn parseBedrockEventStream(reader: anytype, ctx: *StreamThreadContext) !void {
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
    const model: []const u8 = ctx.config.model;
    const model_owned: ?[]u8 = null;
    defer if (model_owned) |m| ctx.allocator.free(m);

    var current_block_index: usize = 0;
    var current_tool_id: []const u8 = "";
    var current_tool_name: []const u8 = "";
    var partial_tool_json: std.ArrayList(u8) = .{};
    defer partial_tool_json.deinit(ctx.allocator);

    var buffer: [8192]u8 = undefined;

    while (true) {
        if (ctx.config.cancel_token) |token| {
            if (token.isCancelled()) {
                ctx.stream.completeWithError("Stream cancelled");
                return;
            }
        }

        const bytes_read = reader.readSliceShort(&buffer) catch break;
        if (bytes_read == 0) break;

        const chunk = buffer[0..bytes_read];

        // Parse event stream format (headers + JSON payload)
        var i: usize = 0;
        while (i < chunk.len) {
            // Skip to next event marker
            if (chunk[i] != ':') {
                i += 1;
                continue;
            }

            // Parse event headers
            var event_type: ?[]const u8 = null;
            var payload_start: usize = i;

            while (i < chunk.len) {
                if (chunk[i] == '\n') {
                    if (i + 1 < chunk.len and chunk[i + 1] == '\n') {
                        payload_start = i + 2;
                        break;
                    }
                }

                // Extract event type from header
                if (std.mem.indexOf(u8, chunk[i..], ":message-type ")) |offset| {
                    const start = i + offset + 14;
                    if (std.mem.indexOf(u8, chunk[start..], "\n")) |end| {
                        const event_json = chunk[start .. start + end];
                        const parsed = std.json.parseFromSlice(
                            struct { event: []const u8 },
                            ctx.allocator,
                            event_json,
                            .{ .ignore_unknown_fields = true },
                        ) catch {
                            i += 1;
                            continue;
                        };
                        defer parsed.deinit();
                        event_type = parsed.value.event;
                    }
                }

                i += 1;
            }

            if (event_type == null or payload_start >= chunk.len) {
                continue;
            }

            // Find payload end
            const payload_end = std.mem.indexOf(u8, chunk[payload_start..], "\n\n") orelse chunk.len;
            const payload = chunk[payload_start .. payload_start + payload_end];

            try handleBedrockEvent(
                event_type.?,
                payload,
                &accumulated_content,
                &signatures,
                &usage,
                &stop_reason,
                &current_block_index,
                &current_tool_id,
                &current_tool_name,
                &partial_tool_json,
                ctx,
            );

            i = payload_start + payload_end;
        }
    }

    const final_content = try ctx.allocator.alloc(types.ContentBlock, accumulated_content.items.len);
    @memcpy(final_content, accumulated_content.items);

    // Mark content as transferred so defer doesn't free the strings
    content_transferred = true;

    // Attach signatures
    for (final_content, 0..) |*block, idx| {
        if (signatures.get(idx)) |sig_list| {
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

    ctx.stream.complete(result);
}

fn handleBedrockEvent(
    event_type: []const u8,
    payload: []const u8,
    accumulated_content: *std.ArrayList(types.ContentBlock),
    signatures: *std.AutoHashMap(usize, std.ArrayList(u8)),
    usage: *types.Usage,
    stop_reason: *types.StopReason,
    current_block_index: *usize,
    current_tool_id: *[]const u8,
    current_tool_name: *[]const u8,
    partial_tool_json: *std.ArrayList(u8),
    ctx: *StreamThreadContext,
) !void {
    if (std.mem.eql(u8, event_type, "messageStart")) {
        try ctx.stream.push(.{ .start = .{ .model = ctx.config.model } });
    } else if (std.mem.eql(u8, event_type, "contentBlockStart")) {
        const parsed = std.json.parseFromSlice(
            struct { start: ?struct { toolUse: ?struct { toolUseId: []const u8, name: []const u8 } = null } = null },
            ctx.allocator,
            payload,
            .{ .ignore_unknown_fields = true },
        ) catch return;
        defer parsed.deinit();

        if (parsed.value.start) |start| {
            if (start.toolUse) |tool| {
                const id = try ctx.allocator.dupe(u8, tool.toolUseId);
                const name = try ctx.allocator.dupe(u8, tool.name);
                current_tool_id.* = id;
                current_tool_name.* = name;
                partial_tool_json.clearRetainingCapacity();

                try accumulated_content.append(ctx.allocator, types.ContentBlock{ .tool_use = .{
                    .id = id,
                    .name = name,
                    .input_json = &[_]u8{},
                } });
                try ctx.stream.push(.{ .toolcall_start = .{
                    .index = accumulated_content.items.len - 1,
                    .id = try ctx.allocator.dupe(u8, id),
                    .name = try ctx.allocator.dupe(u8, name),
                } });
            } else {
                // Text block
                try accumulated_content.append(ctx.allocator, types.ContentBlock{ .text = .{ .text = &[_]u8{} } });
                try ctx.stream.push(.{ .text_start = .{ .index = accumulated_content.items.len - 1 } });
            }
            current_block_index.* = accumulated_content.items.len - 1;
        }
    } else if (std.mem.eql(u8, event_type, "contentBlockDelta")) {
        const parsed = std.json.parseFromSlice(
            struct {
                delta: ?struct {
                    text: ?[]const u8 = null,
                    toolUse: ?struct { input: []const u8 } = null,
                    reasoningContent: ?struct {
                        reasoningText: ?struct { text: []const u8, signature: ?[]const u8 = null } = null,
                    } = null,
                } = null,
            },
            ctx.allocator,
            payload,
            .{ .ignore_unknown_fields = true },
        ) catch return;
        defer parsed.deinit();

        if (parsed.value.delta) |delta| {
            if (delta.text) |text| {
                if (current_block_index.* < accumulated_content.items.len) {
                    const block = &accumulated_content.items[current_block_index.*];
                    if (block.* == .text) {
                        const old = block.text.text;
                        block.text.text = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ old, text });
                        if (old.len > 0) ctx.allocator.free(old);
                        try ctx.stream.push(.{ .text_delta = .{ .index = current_block_index.*, .delta = text } });
                    }
                }
            } else if (delta.toolUse) |tool| {
                try partial_tool_json.appendSlice(ctx.allocator, tool.input);
                if (current_block_index.* < accumulated_content.items.len) {
                    const block = &accumulated_content.items[current_block_index.*];
                    if (block.* == .tool_use) {
                        const old = block.tool_use.input_json;
                        block.tool_use.input_json = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ old, tool.input });
                        if (old.len > 0) ctx.allocator.free(old);
                        try ctx.stream.push(.{ .toolcall_delta = .{ .index = current_block_index.*, .delta = tool.input } });
                    }
                }
            } else if (delta.reasoningContent) |reasoning| {
                if (reasoning.reasoningText) |reason_text| {
                    // Check if thinking block exists
                    var thinking_index = current_block_index.*;
                    if (thinking_index >= accumulated_content.items.len or accumulated_content.items[thinking_index] != .thinking) {
                        try accumulated_content.append(ctx.allocator, types.ContentBlock{ .thinking = .{ .thinking = &[_]u8{} } });
                        thinking_index = accumulated_content.items.len - 1;
                        current_block_index.* = thinking_index;
                        try ctx.stream.push(.{ .thinking_start = .{ .index = thinking_index } });
                    }

                    const block = &accumulated_content.items[thinking_index];
                    if (block.* == .thinking) {
                        const old = block.thinking.thinking;
                        block.thinking.thinking = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ old, reason_text.text });
                        if (old.len > 0) ctx.allocator.free(old);
                        try ctx.stream.push(.{ .thinking_delta = .{ .index = thinking_index, .delta = reason_text.text } });

                        if (reason_text.signature) |sig| {
                            const entry = try signatures.getOrPut(thinking_index);
                            if (!entry.found_existing) {
                                entry.value_ptr.* = .{};
                            }
                            try entry.value_ptr.appendSlice(ctx.allocator, sig);
                        }
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, event_type, "contentBlockStop")) {
        if (current_block_index.* < accumulated_content.items.len) {
            const block = &accumulated_content.items[current_block_index.*];
            switch (block.*) {
                .text => try ctx.stream.push(.{ .text_end = .{ .index = current_block_index.* } }),
                .thinking => try ctx.stream.push(.{ .thinking_end = .{ .index = current_block_index.* } }),
                .tool_use => {
                    const input_json = try ctx.allocator.dupe(u8, partial_tool_json.items);
                    try ctx.stream.push(.{ .toolcall_end = .{
                        .index = current_block_index.*,
                        .input_json = input_json,
                    } });
                },
                else => {},
            }
        }
    } else if (std.mem.eql(u8, event_type, "messageStop")) {
        const parsed = std.json.parseFromSlice(
            struct { stopReason: ?[]const u8 = null },
            ctx.allocator,
            payload,
            .{ .ignore_unknown_fields = true },
        ) catch return;
        defer parsed.deinit();

        if (parsed.value.stopReason) |reason| {
            stop_reason.* = mapStopReason(reason);
        }
    } else if (std.mem.eql(u8, event_type, "metadata")) {
        const parsed = std.json.parseFromSlice(
            struct {
                usage: ?struct {
                    inputTokens: ?u64 = null,
                    outputTokens: ?u64 = null,
                    cacheReadInputTokens: ?u64 = null,
                    cacheWriteInputTokens: ?u64 = null,
                } = null,
            },
            ctx.allocator,
            payload,
            .{ .ignore_unknown_fields = true },
        ) catch return;
        defer parsed.deinit();

        if (parsed.value.usage) |u| {
            usage.input_tokens = u.inputTokens orelse 0;
            usage.output_tokens = u.outputTokens orelse 0;
            usage.cache_read_tokens = u.cacheReadInputTokens orelse 0;
            usage.cache_write_tokens = u.cacheWriteInputTokens orelse 0;
        }

        try ctx.stream.push(.{ .done = .{
            .usage = usage.*,
            .stop_reason = stop_reason.*,
        } });
    }
}

fn mapStopReason(reason: []const u8) types.StopReason {
    if (std.mem.eql(u8, reason, "end_turn")) return .stop;
    if (std.mem.eql(u8, reason, "stop_sequence")) return .stop;
    if (std.mem.eql(u8, reason, "max_tokens")) return .length;
    if (std.mem.eql(u8, reason, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, reason, "content_filter")) return .content_filter;
    return .@"error";
}

/// Build Bedrock Converse API request body
pub fn buildRequestBody(
    cfg: BedrockConfig,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);

    var writer = json_writer.JsonWriter.init(&buffer, allocator);

    try writer.beginObject();

    // Messages (with tool result batching)
    try writer.writeKey("messages");
    try writer.beginArray();

    var i: usize = 0;
    while (i < messages.len) {
        const msg = messages[i];

        if (msg.role == .tool_result) {
            // Batch consecutive tool results
            try writer.beginObject();
            try writer.writeStringField("role", "user");
            try writer.writeKey("content");
            try writer.beginArray();

            while (i < messages.len and messages[i].role == .tool_result) {
                const tool_msg = messages[i];
                try writer.beginObject();
                try writer.writeStringField("toolResult", "");
                if (tool_msg.tool_call_id) |id| {
                    try writer.writeStringField("toolUseId", id);
                }
                try writer.writeKey("content");
                try writeContentBlocks(&writer, tool_msg.content);
                if (tool_msg.is_error) {
                    try writer.writeStringField("status", "error");
                } else {
                    try writer.writeStringField("status", "success");
                }
                try writer.endObject();
                i += 1;
            }

            try writer.endArray();
            try writer.endObject();
        } else {
            try writer.beginObject();

            const role_str = switch (msg.role) {
                .user => "user",
                .assistant => "assistant",
                else => "user",
            };
            try writer.writeStringField("role", role_str);

            try writer.writeKey("content");
            try writeContentBlocks(&writer, msg.content);

            try writer.endObject();
            i += 1;
        }
    }

    try writer.endArray();

    // System prompt
    if (cfg.params.system_prompt) |system| {
        try writer.writeKey("system");
        try writer.beginArray();
        try writer.beginObject();
        try writer.writeStringField("text", system);
        try writer.endObject();

        // Cache point for system prompt
        if (cfg.cache_retention != .none and supportsPromptCaching(cfg.model)) {
            try writer.beginObject();
            try writer.writeKey("cachePoint");
            try writer.beginObject();
            try writer.writeStringField("type", "default");
            if (cfg.cache_retention == .long) {
                try writer.writeStringField("ttl", "ONE_HOUR");
            }
            try writer.endObject();
            try writer.endObject();
        }

        try writer.endArray();
    }

    // Inference config
    try writer.writeKey("inferenceConfig");
    try writer.beginObject();
    try writer.writeIntField("maxTokens", cfg.params.max_tokens);
    if (cfg.params.temperature != 1.0) {
        try writer.writeKey("temperature");
        try writer.writeFloat(cfg.params.temperature);
    }
    if (cfg.params.top_p) |top_p| {
        try writer.writeKey("topP");
        try writer.writeFloat(top_p);
    }
    try writer.endObject();

    // Tool config
    if (cfg.params.tools) |tools| {
        try writer.writeKey("toolConfig");
        try writer.beginObject();

        try writer.writeKey("tools");
        try writer.beginArray();
        for (tools) |tool| {
            try writer.beginObject();

            try writer.writeKey("toolSpec");
            try writer.beginObject();
            try writer.writeStringField("name", tool.name);
            if (tool.description) |desc| {
                try writer.writeStringField("description", desc);
            }

            try writer.writeKey("inputSchema");
            try writer.beginObject();
            try writer.writeKey("json");
            try writeToolParameters(&writer, tool.parameters);
            try writer.endObject();

            try writer.endObject();
            try writer.endObject();
        }
        try writer.endArray();

        // Tool choice
        if (cfg.params.tool_choice) |choice| {
            try writer.writeKey("toolChoice");
            switch (choice) {
                .auto => {
                    try writer.beginObject();
                    try writer.writeKey("auto");
                    try writer.beginObject();
                    try writer.endObject();
                    try writer.endObject();
                },
                .any => {
                    try writer.beginObject();
                    try writer.writeKey("any");
                    try writer.beginObject();
                    try writer.endObject();
                    try writer.endObject();
                },
                .specific => |name| {
                    try writer.beginObject();
                    try writer.writeKey("tool");
                    try writer.beginObject();
                    try writer.writeStringField("name", name);
                    try writer.endObject();
                    try writer.endObject();
                },
                else => {},
            }
        }

        try writer.endObject();
    }

    // Additional model request fields (thinking)
    if (cfg.thinking_config) |thinking| {
        if (supportsThinking(cfg.model)) {
            try writer.writeKey("additionalModelRequestFields");
            try writer.beginObject();

            try writer.writeKey("thinking");
            try writer.beginObject();

            switch (thinking.mode) {
                .adaptive => {
                    try writer.writeStringField("type", "adaptive");
                    if (thinking.effort) |effort| {
                        try writer.writeKey("output_config");
                        try writer.beginObject();
                        const effort_str = switch (effort) {
                            .low => "low",
                            .medium => "medium",
                            .high => "high",
                            .max => "max",
                        };
                        try writer.writeStringField("effort", effort_str);
                        try writer.endObject();
                    }
                },
                .enabled => {
                    try writer.writeStringField("type", "enabled");
                    if (thinking.budget_tokens) |budget| {
                        try writer.writeIntField("budget_tokens", budget);
                    }
                },
            }

            try writer.endObject();
            try writer.endObject();
        }
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
                try writer.writeKey("text");
                try writer.writeString(text.text);
            },
            .tool_use => |tool_use| {
                try writer.writeKey("toolUse");
                try writer.beginObject();
                try writer.writeStringField("toolUseId", tool_use.id);
                try writer.writeStringField("name", tool_use.name);
                try writer.writeKey("input");
                try writer.buffer.appendSlice(writer.allocator, tool_use.input_json);
                writer.needs_comma = true;
                try writer.endObject();
            },
            .thinking => |thinking| {
                try writer.writeKey("reasoningContent");
                try writer.beginObject();
                try writer.writeKey("reasoningText");
                try writer.beginObject();
                try writer.writeStringField("text", thinking.thinking);
                if (thinking.signature) |sig| {
                    try writer.writeStringField("signature", sig);
                }
                try writer.endObject();
                try writer.endObject();
            },
            .image => |img| {
                try writer.writeKey("image");
                try writer.beginObject();
                try writer.writeKey("source");
                try writer.beginObject();
                try writer.writeStringField("bytes", img.data);
                try writer.endObject();
                try writer.writeStringField("format", if (std.mem.eql(u8, img.media_type, "image/jpeg"))
                    "jpeg"
                else if (std.mem.eql(u8, img.media_type, "image/png"))
                    "png"
                else if (std.mem.eql(u8, img.media_type, "image/gif"))
                    "gif"
                else if (std.mem.eql(u8, img.media_type, "image/webp"))
                    "webp"
                else
                    "png");
                try writer.endObject();
            },
        }
        try writer.endObject();
    }
    try writer.endArray();
}

fn writeToolParameters(writer: *json_writer.JsonWriter, params: []const types.ToolParameter) !void {
    try writer.beginObject();
    try writer.writeStringField("type", "object");

    try writer.writeKey("properties");
    try writer.beginObject();
    for (params) |param| {
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
    for (params) |param| {
        if (param.required) {
            try writer.writeString(param.name);
        }
    }
    try writer.endArray();

    try writer.endObject();
}

fn supportsPromptCaching(model_id: []const u8) bool {
    // Claude 3.5+, Claude 4.x support caching on Bedrock
    return std.mem.indexOf(u8, model_id, "claude") != null and
        (std.mem.indexOf(u8, model_id, "3-5") != null or
        std.mem.indexOf(u8, model_id, "3.5") != null or
        std.mem.indexOf(u8, model_id, "-4-") != null or
        std.mem.indexOf(u8, model_id, "-4.") != null);
}

fn supportsThinking(model_id: []const u8) bool {
    // Only Claude models support thinking on Bedrock
    return std.mem.indexOf(u8, model_id, "anthropic.claude") != null;
}

// Tests

test "buildRequestBody basic" {
    const allocator = std.testing.allocator;

    const cfg = BedrockConfig{
        .auth = .{
            .access_key_id = "test-key",
            .secret_access_key = "test-secret",
        },
        .model = "anthropic.claude-3-5-sonnet-20240620-v1:0",
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

    try std.testing.expect(std.mem.indexOf(u8, body, "\"messages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"Hello!\"") != null);
}

test "mapStopReason" {
    try std.testing.expectEqual(types.StopReason.stop, mapStopReason("end_turn"));
    try std.testing.expectEqual(types.StopReason.stop, mapStopReason("stop_sequence"));
    try std.testing.expectEqual(types.StopReason.length, mapStopReason("max_tokens"));
    try std.testing.expectEqual(types.StopReason.tool_use, mapStopReason("tool_use"));
    try std.testing.expectEqual(types.StopReason.content_filter, mapStopReason("content_filter"));
}

test "supportsPromptCaching" {
    try std.testing.expect(supportsPromptCaching("anthropic.claude-3-5-sonnet-20240620-v1:0"));
    try std.testing.expect(supportsPromptCaching("anthropic.claude-opus-4-20250514-v1:0"));
    try std.testing.expect(!supportsPromptCaching("anthropic.claude-3-haiku-20240307-v1:0"));
}

test "supportsThinking" {
    try std.testing.expect(supportsThinking("anthropic.claude-3-5-sonnet-20240620-v1:0"));
    try std.testing.expect(!supportsThinking("meta.llama3-70b-instruct-v1:0"));
}

test "buildRequestBody with thinking adaptive" {
    const allocator = std.testing.allocator;

    const cfg = BedrockConfig{
        .auth = .{
            .access_key_id = "test-key",
            .secret_access_key = "test-secret",
        },
        .model = "anthropic.claude-opus-4-20250514-v1:0",
        .thinking_config = .{
            .mode = .adaptive,
            .effort = .medium,
        },
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Think" } },
            },
            .timestamp = 0,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"additionalModelRequestFields\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"adaptive\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"effort\":\"medium\"") != null);
}

test "buildRequestBody with thinking enabled" {
    const allocator = std.testing.allocator;

    const cfg = BedrockConfig{
        .auth = .{
            .access_key_id = "test-key",
            .secret_access_key = "test-secret",
        },
        .model = "anthropic.claude-3-5-sonnet-20240620-v1:0",
        .thinking_config = .{
            .mode = .enabled,
            .budget_tokens = 2048,
        },
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Think" } },
            },
            .timestamp = 0,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"enabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":2048") != null);
}

test "buildRequestBody tool result batching" {
    const allocator = std.testing.allocator;

    const cfg = BedrockConfig{
        .auth = .{
            .access_key_id = "test-key",
            .secret_access_key = "test-secret",
        },
        .model = "anthropic.claude-3-5-sonnet-20240620-v1:0",
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Use tools" } },
            },
            .timestamp = 0,
        },
        .{
            .role = .tool_result,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Result 1" } },
            },
            .tool_call_id = "call_1",
            .timestamp = 1,
        },
        .{
            .role = .tool_result,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Result 2" } },
            },
            .tool_call_id = "call_2",
            .timestamp = 2,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    // Should batch tool results into single user message
    const user_count = std.mem.count(u8, body, "\"role\":\"user\"");
    try std.testing.expectEqual(@as(usize, 2), user_count); // Original user + batched tool results
    try std.testing.expect(std.mem.indexOf(u8, body, "\"toolUseId\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"toolUseId\":\"call_2\"") != null);
}

test "BedrockThinkingConfig modes" {
    const adaptive = BedrockThinkingConfig{
        .mode = .adaptive,
        .effort = .high,
    };
    try std.testing.expect(adaptive.mode == .adaptive);
    try std.testing.expect(adaptive.effort.? == .high);

    const enabled = BedrockThinkingConfig{
        .mode = .enabled,
        .budget_tokens = 4096,
    };
    try std.testing.expect(enabled.mode == .enabled);
    try std.testing.expectEqual(@as(u32, 4096), enabled.budget_tokens.?);
}

test "BedrockAuth with session token" {
    const auth = BedrockAuth{
        .access_key_id = "AKIAIOSFODNN7EXAMPLE",
        .secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        .session_token = "session-token-123",
    };
    try std.testing.expectEqualStrings("AKIAIOSFODNN7EXAMPLE", auth.access_key_id);
    try std.testing.expectEqualStrings("session-token-123", auth.session_token.?);
}
