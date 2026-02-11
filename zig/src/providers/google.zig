const std = @import("std");
const types = @import("types");
const event_stream = @import("event_stream");
const provider = @import("provider");
const config = @import("config");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");
const google_shared = @import("google_shared");

/// Google Generative AI provider config
pub const GoogleConfig = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8, // Or JSON-encoded OAuth token
    model_id: []const u8 = "gemini-2.5-flash",
    base_url: ?[]const u8 = null,
    params: config.RequestParams = .{},
    thinking: ?ThinkingConfig = null,
    custom_headers: ?[]const config.HeaderPair = null,
    retry_config: config.RetryConfig = .{},
    cancel_token: ?config.CancelToken = null,
};

pub const ThinkingConfig = struct {
    enabled: bool,
    budget_tokens: ?i32 = null, // -1 for dynamic, 0 to disable, >0 for fixed
    level: ?ThinkingLevel = null,
};

pub const ThinkingLevel = enum {
    minimal,
    low,
    medium,
    high,

    pub fn toBudget(self: ThinkingLevel) i32 {
        return switch (self) {
            .minimal => 128,
            .low => 2048,
            .medium => 8192,
            .high => 32768,
        };
    }
};

/// Google provider context
pub const GoogleContext = struct {
    config: GoogleConfig,
    allocator: std.mem.Allocator,
};

/// Create a Google Generative AI provider
pub fn createProvider(cfg: GoogleConfig, allocator: std.mem.Allocator) !provider.Provider {
    const ctx = try allocator.create(GoogleContext);
    ctx.* = .{
        .config = cfg,
        .allocator = allocator,
    };

    return provider.Provider{
        .id = "google",
        .name = "Google Generative AI",
        .context = @ptrCast(ctx),
        .stream_fn = googleStreamFn,
        .deinit_fn = googleDeinitFn,
    };
}

/// Stream function implementation
fn googleStreamFn(
    ctx_ptr: *anyopaque,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageStream {
    const ctx: *GoogleContext = @ptrCast(@alignCast(ctx_ptr));

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
fn googleDeinitFn(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const google_ctx: *GoogleContext = @ptrCast(@alignCast(ctx));
    allocator.destroy(google_ctx);
}

/// Thread context for background streaming
pub const StreamThreadContext = struct {
    stream: *event_stream.AssistantMessageStream,
    request_body: []u8,
    config: GoogleConfig,
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
    // Check cancellation
    if (ctx.config.cancel_token) |token| {
        if (token.isCancelled()) {
            ctx.stream.completeWithError("Stream cancelled");
            return;
        }
    }

    var client = std.http.Client{ .allocator = ctx.allocator };
    defer client.deinit();

    // Build endpoint URL
    const base = ctx.config.base_url orelse "https://generativelanguage.googleapis.com";
    const url = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}/v1beta/models/{s}:generateContentStream",
        .{ base, ctx.config.model_id },
    );
    defer ctx.allocator.free(url);

    const uri = try std.Uri.parse(url);

    // Build headers
    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(ctx.allocator);

    // Auth: check if it's a JSON OAuth token or simple API key
    var auth_header_owned: ?[]u8 = null;
    defer if (auth_header_owned) |h| ctx.allocator.free(h);

    if (std.mem.startsWith(u8, ctx.config.api_key, "{")) {
        // OAuth token format: {"token":"...","projectId":"..."}
        const parsed = try std.json.parseFromSlice(
            struct { token: []const u8 },
            ctx.allocator,
            ctx.config.api_key,
            .{},
        );
        defer parsed.deinit();
        auth_header_owned = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{parsed.value.token});
        try headers.append(ctx.allocator, .{ .name = "authorization", .value = auth_header_owned.? });
    } else {
        // Simple API key
        try headers.append(ctx.allocator, .{ .name = "x-goog-api-key", .value = ctx.config.api_key });
    }

    try headers.append(ctx.allocator, .{ .name = "content-type", .value = "application/json" });

    // Custom headers
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
        const err_msg = try std.fmt.allocPrint(
            ctx.allocator,
            "API error {d}: {s}",
            .{ @intFromEnum(response.head.status), error_body },
        );
        defer ctx.allocator.free(err_msg);
        ctx.stream.completeWithError(err_msg);
        return;
    }

    var transfer_buffer: [4096]u8 = undefined;
    try parseResponse(ctx, response.reader(&transfer_buffer));
}

/// Parse SSE response from Google
pub fn parseResponse(ctx: *StreamThreadContext, reader: anytype) !void {
    var parser = sse_parser.SSEParser.init(ctx.allocator);
    defer parser.deinit();

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

    var thought_signatures = std.AutoHashMap(usize, []u8).init(ctx.allocator);
    defer {
        var it = thought_signatures.valueIterator();
        while (it.next()) |sig| {
            ctx.allocator.free(sig.*);
        }
        thought_signatures.deinit();
    }

    var usage = types.Usage{};
    var stop_reason: types.StopReason = .stop;
    const model_str: []u8 = try ctx.allocator.dupe(u8, ctx.config.model_id);
    defer ctx.allocator.free(model_str);

    while (true) {
        // Check cancellation
        if (ctx.config.cancel_token) |token| {
            if (token.isCancelled()) {
                ctx.stream.completeWithError("Stream cancelled");
                return;
            }
        }

        const bytes_read = try reader.readSliceShort(&buffer);
        if (bytes_read == 0) break;

        const events = try parser.feed(buffer[0..bytes_read]);

        for (events) |event| {
            if (event.data.len == 0) continue;

            const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, event.data, .{}) catch continue;
            defer parsed.deinit();

            const root = parsed.value;
            if (root != .object) continue;

            const candidates = root.object.get("candidates") orelse continue;
            if (candidates != .array or candidates.array.items.len == 0) continue;

            const candidate = candidates.array.items[0];
            if (candidate != .object) continue;

            const content_obj = candidate.object.get("content");
            if (content_obj) |content| {
                if (content != .object) continue;
                const parts = content.object.get("parts") orelse continue;
                if (parts != .array) continue;

                for (parts.array.items) |part_val| {
                    if (part_val != .object) continue;
                    const part = part_val.object;

                    const is_thought = if (part.get("thought")) |t| t == .bool and t.bool else false;

                    if (part.get("text")) |text_val| {
                        if (text_val != .string) continue;
                        const text = text_val.string;

                        if (is_thought) {
                            // Thinking block
                            if (accumulated_content.items.len == 0 or accumulated_content.items[accumulated_content.items.len - 1] != .thinking) {
                                try accumulated_content.append(ctx.allocator, .{ .thinking = .{ .thinking = &[_]u8{} } });
                                try ctx.stream.push(.{ .thinking_start = .{ .index = accumulated_content.items.len - 1 } });
                            }

                            const idx = accumulated_content.items.len - 1;
                            const block = &accumulated_content.items[idx];
                            const old_text = block.thinking.thinking;
                            block.thinking.thinking = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ old_text, text });
                            if (old_text.len > 0) ctx.allocator.free(old_text);

                            try ctx.stream.push(.{ .thinking_delta = .{ .index = idx, .delta = try ctx.allocator.dupe(u8, text) } });
                        } else {
                            // Text block
                            if (accumulated_content.items.len == 0 or accumulated_content.items[accumulated_content.items.len - 1] != .text) {
                                try accumulated_content.append(ctx.allocator, .{ .text = .{ .text = &[_]u8{} } });
                                try ctx.stream.push(.{ .text_start = .{ .index = accumulated_content.items.len - 1 } });
                            }

                            const idx = accumulated_content.items.len - 1;
                            const block = &accumulated_content.items[idx];
                            const old_text = block.text.text;
                            block.text.text = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ old_text, text });
                            if (old_text.len > 0) ctx.allocator.free(old_text);

                            try ctx.stream.push(.{ .text_delta = .{ .index = idx, .delta = try ctx.allocator.dupe(u8, text) } });
                        }
                    } else if (part.get("functionCall")) |fc_val| {
                        if (fc_val != .object) continue;
                        const fc = fc_val.object;

                        const name = if (fc.get("name")) |n| if (n == .string) n.string else "unknown" else "unknown";
                        const args = fc.get("args") orelse continue;
                        const id = if (fc.get("id")) |i| if (i == .string) i.string else null else null;

                        const tool_id = if (id) |i|
                            try ctx.allocator.dupe(u8, i)
                        else
                            try google_shared.generateToolCallId(name, ctx.allocator);

                        try accumulated_content.append(ctx.allocator, .{
                            .tool_use = .{
                                .id = tool_id,
                                .name = try ctx.allocator.dupe(u8, name),
                                .input_json = &[_]u8{},
                            },
                        });

                        const idx = accumulated_content.items.len - 1;
                        try ctx.stream.push(.{ .toolcall_start = .{ .index = idx, .id = tool_id, .name = name } });

                        const args_json = try std.json.Stringify.valueAlloc(ctx.allocator, args, .{});
                        const block = &accumulated_content.items[idx];
                        block.tool_use.input_json = args_json;

                        try ctx.stream.push(.{ .toolcall_delta = .{ .index = idx, .delta = try ctx.allocator.dupe(u8, args_json) } });
                        try ctx.stream.push(.{ .toolcall_end = .{ .index = idx, .input_json = args_json } });
                    } else if (part.get("thoughtSignature")) |sig_val| {
                        if (sig_val == .string) {
                            const sig = try ctx.allocator.dupe(u8, sig_val.string);
                            const idx = if (accumulated_content.items.len > 0) accumulated_content.items.len - 1 else 0;
                            try thought_signatures.put(idx, sig);
                        }
                    }
                }
            }

            // Check for finish reason
            if (candidate.object.get("finishReason")) |fr_val| {
                if (fr_val == .string) {
                    stop_reason = mapFinishReason(fr_val.string);
                }
            }

            // Parse usage metadata
            if (root.object.get("usageMetadata")) |usage_val| {
                if (usage_val == .object) {
                    const usage_obj = usage_val.object;
                    if (usage_obj.get("promptTokenCount")) |input| {
                        if (input == .integer) usage.input_tokens = @intCast(@abs(input.integer));
                    }
                    if (usage_obj.get("candidatesTokenCount")) |output| {
                        if (output == .integer) usage.output_tokens = @intCast(@abs(output.integer));
                    }
                }
            }
        }
    }

    // Finalize content blocks with signatures
    const final_content = try ctx.allocator.alloc(types.ContentBlock, accumulated_content.items.len);
    @memcpy(final_content, accumulated_content.items);

    // Mark content as transferred so defer doesn't free the strings
    content_transferred = true;

    for (final_content, 0..) |*block, i| {
        if (thought_signatures.get(i)) |sig| {
            switch (block.*) {
                .thinking => |*t| t.signature = sig,
                .text => |*t| t.signature = sig,
                .tool_use => |*t| t.thought_signature = sig,
                else => {},
            }
        }
    }

    try ctx.stream.push(.{ .done = .{ .usage = usage, .stop_reason = stop_reason } });

    const result = types.AssistantMessage{
        .content = final_content,
        .usage = usage,
        .stop_reason = stop_reason,
        .model = try ctx.allocator.dupe(u8, model_str),
        .timestamp = std.time.timestamp(),
    };

    ctx.stream.complete(result);
}

/// Build request body JSON
fn buildRequestBody(
    cfg: GoogleConfig,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) ![]u8 {
    var buffer: std.ArrayList(u8) = .{};
    errdefer buffer.deinit(allocator);

    var writer = json_writer.JsonWriter.init(&buffer, allocator);

    try writer.beginObject();

    // Convert messages to Google format
    var contents = try google_shared.convertMessages(messages, allocator);
    defer {
        for (contents.items) |content| {
            allocator.free(content.parts);
        }
        contents.deinit(allocator);
    }

    // System instruction (from params.system_prompt)
    if (cfg.params.system_prompt) |system| {
        try writer.writeKey("systemInstruction");
        try writer.beginObject();
        try writer.writeKey("parts");
        try writer.beginArray();
        try writer.beginObject();
        try writer.writeStringField("text", system);
        try writer.endObject();
        try writer.endArray();
        try writer.endObject();
    }

    // Contents
    try writer.writeKey("contents");
    try google_shared.writeContents(&writer, contents.items);

    // Generation config
    try writer.writeKey("generationConfig");
    try writer.beginObject();

    if (cfg.params.temperature != 1.0) {
        try writer.writeKey("temperature");
        try writer.writeFloat(cfg.params.temperature);
    }

    if (cfg.params.top_p) |top_p| {
        try writer.writeKey("topP");
        try writer.writeFloat(top_p);
    }

    if (cfg.params.top_k) |top_k| {
        try writer.writeIntField("topK", top_k);
    }

    try writer.writeIntField("maxOutputTokens", cfg.params.max_tokens);

    if (cfg.params.stop_sequences) |stop_seqs| {
        try writer.writeKey("stopSequences");
        try writer.beginArray();
        for (stop_seqs) |seq| {
            try writer.writeString(seq);
        }
        try writer.endArray();
    }

    try writer.endObject();

    // Tools
    if (cfg.params.tools) |tools| {
        var declarations = try google_shared.convertTools(tools, allocator);
        defer declarations.deinit(allocator);

        try writer.writeKey("tools");
        try writer.beginArray();
        try writer.beginObject();
        try writer.writeKey("functionDeclarations");
        try google_shared.writeFunctionDeclarations(&writer, declarations.items);
        try writer.endObject();
        try writer.endArray();

        // Tool config
        if (cfg.params.tool_choice) |tc| {
            try writer.writeKey("toolConfig");
            try writer.beginObject();
            try writer.writeKey("functionCallingConfig");
            try writer.beginObject();
            const mode = switch (tc) {
                .auto => "AUTO",
                .none => "NONE",
                .any => "ANY",
                .specific => "AUTO", // Google doesn't have specific, use AUTO
            };
            try writer.writeStringField("mode", mode);
            try writer.endObject();
            try writer.endObject();
        }
    }

    // Thinking config
    if (cfg.thinking) |thinking_cfg| {
        if (thinking_cfg.enabled) {
            try writer.writeKey("thinkingConfig");
            try writer.beginObject();

            if (thinking_cfg.level) |level| {
                // Gemini 3: use thinkingLevel
                const level_str = switch (level) {
                    .minimal => "MINIMAL",
                    .low => "LOW",
                    .medium => "MEDIUM",
                    .high => "HIGH",
                };
                try writer.writeStringField("thinkingLevel", level_str);
            } else if (thinking_cfg.budget_tokens) |budget| {
                // Gemini 2.5: use thinkingBudget
                try writer.writeIntField("thinkingBudget", budget);
            }

            try writer.endObject();
        }
    }

    try writer.endObject();

    return buffer.toOwnedSlice(allocator);
}

fn mapFinishReason(reason: []const u8) types.StopReason {
    if (std.mem.eql(u8, reason, "STOP")) return .stop;
    if (std.mem.eql(u8, reason, "MAX_TOKENS")) return .length;
    if (std.mem.eql(u8, reason, "SAFETY")) return .content_filter;
    if (std.mem.eql(u8, reason, "RECITATION")) return .content_filter;
    return .stop;
}

// Tests
test "buildRequestBody basic" {
    const allocator = std.testing.allocator;

    const cfg = GoogleConfig{
        .allocator = allocator,
        .api_key = "test-key",
        .model_id = "gemini-2.5-flash",
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

    try std.testing.expect(std.mem.indexOf(u8, body, "\"contents\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"generationConfig\"") != null);
}

test "buildRequestBody with thinking config" {
    const allocator = std.testing.allocator;

    const cfg = GoogleConfig{
        .allocator = allocator,
        .api_key = "test-key",
        .thinking = .{
            .enabled = true,
            .budget_tokens = 2048,
        },
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Think!" } },
            },
            .timestamp = 0,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinkingConfig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinkingBudget\":2048") != null);
}

test "ThinkingLevel toBudget" {
    try std.testing.expectEqual(@as(i32, 128), ThinkingLevel.minimal.toBudget());
    try std.testing.expectEqual(@as(i32, 2048), ThinkingLevel.low.toBudget());
    try std.testing.expectEqual(@as(i32, 8192), ThinkingLevel.medium.toBudget());
    try std.testing.expectEqual(@as(i32, 32768), ThinkingLevel.high.toBudget());
}

test "mapFinishReason" {
    try std.testing.expect(mapFinishReason("STOP") == .stop);
    try std.testing.expect(mapFinishReason("MAX_TOKENS") == .length);
    try std.testing.expect(mapFinishReason("SAFETY") == .content_filter);
    try std.testing.expect(mapFinishReason("RECITATION") == .content_filter);
    try std.testing.expect(mapFinishReason("UNKNOWN") == .stop);
}
