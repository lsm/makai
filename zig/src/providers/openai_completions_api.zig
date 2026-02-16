const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");

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
    try w.endObject();

    return buf.toOwnedSlice(allocator);
}

const ThreadCtx = struct {
    allocator: std.mem.Allocator,
    stream: *ai_types.AssistantMessageEventStream,
    model: ai_types.Model,
    api_key: []const u8,
    request_body: []u8,
};

fn parseChunk(data: []const u8, text: *std.ArrayList(u8), usage: *ai_types.Usage, stop_reason: *ai_types.StopReason, allocator: std.mem.Allocator) !void {
    if (std.mem.eql(u8, data, "[DONE]")) return;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;

    if (root.object.get("usage")) |u| {
        if (u == .object) {
            if (u.object.get("prompt_tokens")) |v| {
                if (v == .integer) usage.input = @intCast(v.integer);
            }
            if (u.object.get("completion_tokens")) |v| {
                if (v == .integer) usage.output = @intCast(v.integer);
            }
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
                if (d.object.get("content")) |c| {
                    if (c == .string) try text.appendSlice(allocator, c.string);
                }
            }
        }
    }
}

fn runThread(ctx: *ThreadCtx) void {
    defer {
        ctx.allocator.free(ctx.request_body);
        ctx.allocator.free(ctx.api_key);
        ctx.allocator.destroy(ctx);
    }

    var client = std.http.Client{ .allocator = ctx.allocator };
    defer client.deinit();

    const url = std.fmt.allocPrint(ctx.allocator, "{s}/v1/chat/completions", .{ctx.model.base_url}) catch {
        ctx.stream.completeWithError("oom building url");
        return;
    };
    defer ctx.allocator.free(url);

    const auth = std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{ctx.api_key}) catch {
        ctx.stream.completeWithError("oom building auth header");
        return;
    };
    defer ctx.allocator.free(auth);

    const uri = std.Uri.parse(url) catch {
        ctx.stream.completeWithError("invalid provider URL");
        return;
    };

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(ctx.allocator);
    headers.append(ctx.allocator, .{ .name = "authorization", .value = auth }) catch {
        ctx.stream.completeWithError("oom headers");
        return;
    };
    headers.append(ctx.allocator, .{ .name = "content-type", .value = "application/json" }) catch {
        ctx.stream.completeWithError("oom headers");
        return;
    };
    headers.append(ctx.allocator, .{ .name = "accept", .value = "text/event-stream" }) catch {
        ctx.stream.completeWithError("oom headers");
        return;
    };

    var req = client.request(.POST, uri, .{ .extra_headers = headers.items }) catch {
        ctx.stream.completeWithError("failed to open request");
        return;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = ctx.request_body.len };

    req.sendBodyComplete(ctx.request_body) catch {
        ctx.stream.completeWithError("failed to send request");
        return;
    };

    var head_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch {
        ctx.stream.completeWithError("failed to receive response");
        return;
    };

    if (response.head.status != .ok) {
        ctx.stream.completeWithError("openai request failed");
        return;
    }

    var parser = sse_parser.SSEParser.init(ctx.allocator);
    defer parser.deinit();

    var text = std.ArrayList(u8){};
    defer text.deinit(ctx.allocator);
    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;

    var transfer_buf: [4096]u8 = undefined;
    var read_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    while (true) {
        const n = reader.*.readSliceShort(&read_buf) catch {
            ctx.stream.completeWithError("read error");
            return;
        };
        if (n == 0) break;

        const events = parser.feed(read_buf[0..n]) catch {
            ctx.stream.completeWithError("sse parse error");
            return;
        };

        for (events) |ev| {
            parseChunk(ev.data, &text, &usage, &stop_reason, ctx.allocator) catch {
                ctx.stream.completeWithError("json parse error");
                return;
            };
        }
    }

    if (usage.total_tokens == 0) usage.total_tokens = usage.input + usage.output + usage.cache_read + usage.cache_write;

    var content = ctx.allocator.alloc(ai_types.AssistantContent, 1) catch {
        ctx.stream.completeWithError("oom building result");
        return;
    };
    content[0] = .{ .text = .{ .text = ctx.allocator.dupe(u8, text.items) catch {
        ctx.allocator.free(content);
        ctx.stream.completeWithError("oom building text");
        return;
    } } };

    const out = ai_types.AssistantMessage{
        .content = content,
        .api = ctx.allocator.dupe(u8, ctx.model.api) catch {
            ctx.stream.completeWithError("oom");
            return;
        },
        .provider = ctx.allocator.dupe(u8, ctx.model.provider) catch {
            ctx.stream.completeWithError("oom");
            return;
        },
        .model = ctx.allocator.dupe(u8, ctx.model.id) catch {
            ctx.stream.completeWithError("oom");
            return;
        },
        .usage = usage,
        .stop_reason = stop_reason,
        .timestamp = std.time.milliTimestamp(),
    };

    ctx.stream.complete(out);
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

    const req_body = try buildRequestBody(model, context, resolved, allocator);

    const s = try allocator.create(ai_types.AssistantMessageEventStream);
    s.* = ai_types.AssistantMessageEventStream.init(allocator);

    const ctx = try allocator.create(ThreadCtx);
    ctx.* = .{
        .allocator = allocator,
        .stream = s,
        .model = model,
        .api_key = @constCast(api_key),
        .request_body = req_body,
    };

    const th = try std.Thread.spawn(.{}, runThread, .{ctx});
    th.detach();
    return s;
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
    }, allocator);
}

pub fn registerOpenAICompletionsApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "openai-completions",
        .stream = streamOpenAICompletions,
        .stream_simple = streamSimpleOpenAICompletions,
    }, null);
}
