const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");
const github_copilot = @import("github_copilot");

fn envApiKey(allocator: std.mem.Allocator) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, "OPENAI_API_KEY") catch null;
}

fn appendTextContent(msg: ai_types.Message, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    switch (msg) {
        .user => |u| switch (u.content) {
            .text => |t| try out.appendSlice(allocator, t),
            .parts => |parts| {
                for (parts) |p| {
                    switch (p) {
                        .text => |t| {
                            if (out.items.len > 0) try out.append(allocator, '\n');
                            try out.appendSlice(allocator, t.text);
                        },
                        .image => {},
                    }
                }
            },
        },
        .assistant => |a| {
            for (a.content) |c| {
                switch (c) {
                    .text => |t| {
                        if (out.items.len > 0) try out.append(allocator, '\n');
                        try out.appendSlice(allocator, t.text);
                    },
                    .thinking => |t| {
                        if (out.items.len > 0) try out.append(allocator, '\n');
                        try out.appendSlice(allocator, t.thinking);
                    },
                    .tool_call => {},
                }
            }
        },
        .tool_result => |tr| {
            for (tr.content) |c| {
                switch (c) {
                    .text => |t| {
                        if (out.items.len > 0) try out.append(allocator, '\n');
                        try out.appendSlice(allocator, t.text);
                    },
                    .image => {},
                }
            }
        },
    }
}

fn writeMessagesArray(
    writer: *json_writer.JsonWriter,
    context: ai_types.Context,
    allocator: std.mem.Allocator,
) !void {
    try writer.writeKey("messages");
    try writer.beginArray();

    if (context.system_prompt) |sp| {
        try writer.beginObject();
        try writer.writeStringField("role", "system");
        try writer.writeStringField("content", sp);
        try writer.endObject();
    }

    for (context.messages) |msg| {
        var text_buf = std.ArrayList(u8){};
        defer text_buf.deinit(allocator);
        try appendTextContent(msg, &text_buf, allocator);

        const role: []const u8 = switch (msg) {
            .user => "user",
            .assistant => "assistant",
            .tool_result => "tool",
        };

        try writer.beginObject();
        try writer.writeStringField("role", role);
        switch (msg) {
            .tool_result => |tr| try writer.writeStringField("tool_call_id", tr.tool_call_id),
            else => {},
        }
        try writer.writeStringField("content", text_buf.items);
        try writer.endObject();
    }

    try writer.endArray();
}

fn buildRequestBody(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    var w = json_writer.JsonWriter.init(&buf, allocator);
    try w.beginObject();
    try w.writeStringField("model", model.id);
    try writeMessagesArray(&w, context, allocator);
    try w.writeBoolField("stream", true);
    try w.writeIntField("max_tokens", options.max_tokens orelse model.max_tokens);
    if (options.temperature) |t| {
        try w.writeKey("temperature");
        try w.writeFloat(t);
    }
    // Add reasoning_effort for OpenAI-compatible endpoints that support it
    if (options.reasoning_effort) |effort| {
        if (model.reasoning) {
            try w.writeStringField("reasoning_effort", effort);
        }
    }
    try w.endObject();

    return buf.toOwnedSlice(allocator);
}

const ThreadCtx = struct {
    allocator: std.mem.Allocator,
    stream: *ai_types.AssistantMessageEventStream,
    model: ai_types.Model,
    api_key: []const u8,
    request_body: []u8,
    context: ai_types.Context,
};

/// Current block type being parsed
const BlockType = enum {
    none,
    text,
    thinking,
};

/// Reasoning field names to check (in priority order)
const reasoning_fields: []const []const u8 = &.{ "reasoning_content", "reasoning", "reasoning_text" };

/// Find the first non-empty reasoning field in a delta object
fn findReasoningField(delta: std.json.ObjectMap) ?struct { field: []const u8, value: []const u8 } {
    for (reasoning_fields) |field| {
        if (delta.get(field)) |val| {
            if (val == .string and val.string.len > 0) {
                return .{ .field = field, .value = val.string };
            }
        }
    }
    return null;
}

fn parseChunk(
    data: []const u8,
    text: *std.ArrayList(u8),
    thinking: *std.ArrayList(u8),
    usage: *ai_types.Usage,
    stop_reason: *ai_types.StopReason,
    current_block: *BlockType,
    reasoning_signature: *?[]const u8,
    allocator: std.mem.Allocator,
) !void {
    if (std.mem.eql(u8, data, "[DONE]")) return;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;

    // Parse usage including reasoning tokens
    if (root.object.get("usage")) |u| {
        if (u == .object) {
            if (u.object.get("prompt_tokens")) |v| {
                if (v == .integer) usage.input = @intCast(v.integer);
            }
            // Check for cached tokens in prompt_tokens_details
            if (u.object.get("prompt_tokens_details")) |details| {
                if (details == .object) {
                    if (details.object.get("cached_tokens")) |cached| {
                        if (cached == .integer) {
                            const cached_tokens: u64 = @intCast(cached.integer);
                            usage.cache_read = cached_tokens;
                            // Subtract cached from input since OpenAI includes them in prompt_tokens
                            if (usage.input > cached_tokens) {
                                usage.input -= cached_tokens;
                            }
                        }
                    }
                }
            }
            // Get base completion tokens
            var completion_tokens: u64 = 0;
            if (u.object.get("completion_tokens")) |v| {
                if (v == .integer) completion_tokens = @intCast(v.integer);
            }
            // Check for reasoning tokens in completion_tokens_details
            var reasoning_tokens: u64 = 0;
            if (u.object.get("completion_tokens_details")) |details| {
                if (details == .object) {
                    if (details.object.get("reasoning_tokens")) |rt| {
                        if (rt == .integer) reasoning_tokens = @intCast(rt.integer);
                    }
                }
            }
            // Output includes both regular completion and reasoning tokens
            usage.output = completion_tokens + reasoning_tokens;
            if (u.object.get("total_tokens")) |v| {
                if (v == .integer) usage.total_tokens = @intCast(v.integer);
            }
        }
    }

    if (root.object.get("choices")) |choices| {
        if (choices != .array or choices.array.items.len == 0) return;
        const ch = choices.array.items[0];
        if (ch != .object) return;

        if (ch.object.get("finish_reason")) |fr| {
            if (fr == .string) {
                if (std.mem.eql(u8, fr.string, "length")) stop_reason.* = .length
                else if (std.mem.eql(u8, fr.string, "tool_calls")) stop_reason.* = .tool_use
                else if (std.mem.eql(u8, fr.string, "content_filter")) stop_reason.* = .@"error"
                else stop_reason.* = .stop;
            }
        }

        if (ch.object.get("delta")) |d| {
            if (d == .object) {
                // Check for reasoning content first (priority over text)
                if (findReasoningField(d.object)) |reasoning| {
                    // Track which field reasoning came from (for round-trip)
                    if (reasoning_signature.* == null) {
                        reasoning_signature.* = try allocator.dupe(u8, reasoning.field);
                    }
                    current_block.* = .thinking;
                    try thinking.appendSlice(allocator, reasoning.value);
                } else if (d.object.get("content")) |c| {
                    // Regular text content
                    if (c == .string and c.string.len > 0) {
                        current_block.* = .text;
                        try text.appendSlice(allocator, c.string);
                    }
                }
            }
        }
    }
}

fn runThread(ctx: *ThreadCtx) void {
    // Save values from ctx that we need after freeing ctx
    const allocator = ctx.allocator;
    const stream = ctx.stream;
    const model = ctx.model;
    const api_key = ctx.api_key;
    const request_body = ctx.request_body;
    const context = ctx.context;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const url = std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{model.base_url}) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("oom building url");
        return;
    };
    defer allocator.free(url);

    const auth = std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("oom building auth header");
        return;
    };
    defer allocator.free(auth);

    const uri = std.Uri.parse(url) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("invalid provider URL");
        return;
    };

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(allocator);
    headers.append(allocator, .{ .name = "authorization", .value = auth }) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("oom headers");
        return;
    };
    headers.append(allocator, .{ .name = "content-type", .value = "application/json" }) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("oom headers");
        return;
    };
    headers.append(allocator, .{ .name = "accept", .value = "text/event-stream" }) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("oom headers");
        return;
    };

    // Add GitHub Copilot dynamic headers if provider is github-copilot
    if (std.mem.eql(u8, model.provider, "github-copilot")) {
        const has_images = github_copilot.hasCopilotVisionInput(context.messages);
        const copilot_headers = github_copilot.buildCopilotDynamicHeaders(
            context.messages,
            has_images,
            allocator,
        ) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom copilot headers");
            return;
        };
        defer allocator.free(copilot_headers);

        for (copilot_headers) |h| {
            headers.append(allocator, h) catch {
                allocator.free(api_key);
                allocator.free(request_body);
                allocator.destroy(ctx);
                stream.completeWithError("oom headers");
                return;
            };
        }
    }

    var req = client.request(.POST, uri, .{ .extra_headers = headers.items }) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("failed to open request");
        return;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = request_body.len };

    req.sendBodyComplete(request_body) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("failed to send request");
        return;
    };

    var head_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("failed to receive response");
        return;
    };

    if (response.head.status != .ok) {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("openai request failed");
        return;
    }

    var parser = sse_parser.SSEParser.init(allocator);
    defer parser.deinit();

    var text = std.ArrayList(u8){};
    defer text.deinit(allocator);
    var thinking = std.ArrayList(u8){};
    defer thinking.deinit(allocator);
    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;
    var current_block: BlockType = .none;
    var reasoning_signature: ?[]const u8 = null;
    defer if (reasoning_signature) |sig| allocator.free(sig);

    var transfer_buf: [4096]u8 = undefined;
    var read_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    while (true) {
        const n = reader.*.readSliceShort(&read_buf) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("read error");
            return;
        };
        if (n == 0) break;

        const events = parser.feed(read_buf[0..n]) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("sse parse error");
            return;
        };

        for (events) |ev| {
            parseChunk(ev.data, &text, &thinking, &usage, &stop_reason, &current_block, &reasoning_signature, allocator) catch {
                allocator.free(api_key);
                allocator.free(request_body);
                allocator.destroy(ctx);
                stream.completeWithError("json parse error");
                return;
            };
        }
    }

    if (usage.total_tokens == 0) usage.total_tokens = usage.input + usage.output + usage.cache_read + usage.cache_write;

    // Build content blocks - thinking first if present, then text
    const has_thinking = thinking.items.len > 0;
    const has_text = text.items.len > 0;
    const content_count: usize = if (has_thinking) 1 else 0;
    const content_count_final = content_count + if (has_text) @as(usize, 1) else @as(usize, 0);

    if (content_count_final == 0) {
        // No content - create empty text block with borrowed empty string reference
        // Using a static empty string avoids an unnecessary allocation for the empty case
        var content = allocator.alloc(ai_types.AssistantContent, 1) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom building result");
            return;
        };
        content[0] = .{ .text = .{ .text = "" } };
        const out = ai_types.AssistantMessage{
            .content = content,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = usage,
            .stop_reason = stop_reason,
            .timestamp = std.time.milliTimestamp(),
        };
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.complete(out);
        return;
    }

    var content = allocator.alloc(ai_types.AssistantContent, content_count_final) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("oom building result");
        return;
    };
    var idx: usize = 0;

    if (has_thinking) {
        content[idx] = .{ .thinking = .{
            .thinking = allocator.dupe(u8, thinking.items) catch {
                allocator.free(content);
                allocator.free(api_key);
                allocator.free(request_body);
                allocator.destroy(ctx);
                stream.completeWithError("oom building thinking");
                return;
            },
            .thinking_signature = if (reasoning_signature) |sig| allocator.dupe(u8, sig) catch {
                // Free previously allocated content
                for (content[0..idx]) |*block| {
                    switch (block.*) {
                        .thinking => |t| allocator.free(t.thinking),
                        else => {},
                    }
                }
                allocator.free(content);
                allocator.free(api_key);
                allocator.free(request_body);
                allocator.destroy(ctx);
                stream.completeWithError("oom building signature");
                return;
            } else null,
        } };
        idx += 1;
    }

    if (has_text) {
        content[idx] = .{ .text = .{ .text = allocator.dupe(u8, text.items) catch {
            // Free previously allocated content
            for (content[0..idx]) |*block| {
                switch (block.*) {
                    .thinking => |t| {
                        allocator.free(t.thinking);
                        if (t.thinking_signature) |sig| allocator.free(sig);
                    },
                    else => {},
                }
            }
            allocator.free(content);
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom building text");
            return;
        } } };
    }

    const out = ai_types.AssistantMessage{
        .content = content,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = usage,
        .stop_reason = stop_reason,
        .timestamp = std.time.milliTimestamp(),
    };

    allocator.free(api_key);
    allocator.free(request_body);
    allocator.destroy(ctx);
    stream.complete(out);
}

pub fn streamOpenAICompletions(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*ai_types.AssistantMessageEventStream {
    const resolved = options orelse ai_types.StreamOptions{};

    var key_owned: ?[]const u8 = null;
    const api_key = blk: {
        if (resolved.api_key) |k| break :blk try allocator.dupe(u8, k);
        key_owned = envApiKey(allocator);
        if (key_owned) |k| break :blk k;
        return error.MissingApiKey;
    };
    errdefer allocator.free(api_key);

    const req_body = try buildRequestBody(model, context, resolved, allocator);
    errdefer allocator.free(req_body);

    const s = try allocator.create(ai_types.AssistantMessageEventStream);
    errdefer allocator.destroy(s);
    s.* = ai_types.AssistantMessageEventStream.init(allocator);

    const ctx = try allocator.create(ThreadCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .stream = s,
        .model = model,
        .api_key = @constCast(api_key),
        .request_body = req_body,
        .context = context,
    };

    const th = try std.Thread.spawn(.{}, runThread, .{ctx});
    th.detach();
    return s;
}

/// Convert ThinkingLevel enum to reasoning_effort string
fn thinkingLevelToString(level: ai_types.ThinkingLevel) []const u8 {
    return switch (level) {
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

pub fn streamSimpleOpenAICompletions(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.SimpleStreamOptions{};
    return streamOpenAICompletions(model, context, .{
        .temperature = o.temperature,
        .max_tokens = o.max_tokens,
        .api_key = o.api_key,
        .cache_retention = o.cache_retention,
        .session_id = o.session_id,
        .headers = o.headers,
        .retry = o.retry,
        .cancel_token = o.cancel_token,
        .on_payload_fn = o.on_payload_fn,
        .on_payload_ctx = o.on_payload_ctx,
        .reasoning_effort = if (o.reasoning) |r| thinkingLevelToString(r) else null,
    }, allocator);
}

pub fn registerOpenAICompletionsApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "openai-completions",
        .stream = streamOpenAICompletions,
        .stream_simple = streamSimpleOpenAICompletions,
    }, null);
}
