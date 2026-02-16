const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");

fn env(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

fn appendMessageText(msg: ai_types.Message, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    switch (msg) {
        .user => |u| switch (u.content) {
            .text => |t| try out.appendSlice(allocator, t),
            .parts => |parts| for (parts) |p| switch (p) {
                .text => |t| {
                    if (out.items.len > 0) try out.append(allocator, '\n');
                    try out.appendSlice(allocator, t.text);
                },
                .image => {},
            },
        },
        .assistant => |a| for (a.content) |c| switch (c) {
            .text => |t| {
                if (out.items.len > 0) try out.append(allocator, '\n');
                try out.appendSlice(allocator, t.text);
            },
            .thinking => |t| {
                if (out.items.len > 0) try out.append(allocator, '\n');
                try out.appendSlice(allocator, t.thinking);
            },
            .tool_call => {},
        },
        .tool_result => |tr| for (tr.content) |c| switch (c) {
            .text => |t| {
                if (out.items.len > 0) try out.append(allocator, '\n');
                try out.appendSlice(allocator, t.text);
            },
            .image => {},
        },
    }
}

fn buildBody(context: ai_types.Context, options: ai_types.StreamOptions, model: ai_types.Model, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    var w = json_writer.JsonWriter.init(&buf, allocator);
    try w.beginObject();

    try w.writeKey("contents");
    try w.beginArray();
    for (context.messages) |m| {
        var text = std.ArrayList(u8){};
        defer text.deinit(allocator);
        try appendMessageText(m, &text, allocator);

        const role: []const u8 = switch (m) {
            .assistant => "model",
            else => "user",
        };

        try w.beginObject();
        try w.writeStringField("role", role);
        try w.writeKey("parts");
        try w.beginArray();
        try w.beginObject();
        try w.writeStringField("text", text.items);
        try w.endObject();
        try w.endArray();
        try w.endObject();
    }
    try w.endArray();

    if (context.system_prompt) |sp| {
        try w.writeKey("systemInstruction");
        try w.beginObject();
        try w.writeKey("parts");
        try w.beginArray();
        try w.beginObject();
        try w.writeStringField("text", sp);
        try w.endObject();
        try w.endArray();
        try w.endObject();
    }

    try w.writeKey("generationConfig");
    try w.beginObject();
    try w.writeIntField("maxOutputTokens", options.max_tokens orelse model.max_tokens);
    if (options.temperature) |t| {
        try w.writeKey("temperature");
        try w.writeFloat(t);
    }
    try w.endObject();

    try w.endObject();
    return buf.toOwnedSlice(allocator);
}

fn parseGoogleEvent(data: []const u8, text: *std.ArrayList(u8), usage: *ai_types.Usage, allocator: std.mem.Allocator) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;
    const obj = parsed.value.object;

    if (obj.get("candidates")) |cands| {
        if (cands == .array and cands.array.items.len > 0) {
            const c = cands.array.items[0];
            if (c == .object) {
                if (c.object.get("content")) |content| {
                    if (content == .object) {
                        if (content.object.get("parts")) |parts| {
                            if (parts == .array) {
                                for (parts.array.items) |p| {
                                    if (p == .object) {
                                        if (p.object.get("text")) |t| {
                                            if (t == .string) try text.appendSlice(allocator, t.string);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (obj.get("usageMetadata")) |u| {
        if (u == .object) {
            if (u.object.get("promptTokenCount")) |v| {
                if (v == .integer) usage.input = @intCast(v.integer);
            }
            if (u.object.get("candidatesTokenCount")) |v| {
                if (v == .integer) usage.output = @intCast(v.integer);
            }
            if (u.object.get("totalTokenCount")) |v| {
                if (v == .integer) usage.total_tokens = @intCast(v.integer);
            }
        }
    }
}

const ThreadCtx = struct {
    allocator: std.mem.Allocator,
    stream: *ai_types.AssistantMessageEventStream,
    model: ai_types.Model,
    api_key: []u8,
    body: []u8,
    base_url: []u8,
};

fn runThread(ctx: *ThreadCtx) void {
    defer {
        ctx.allocator.free(ctx.api_key);
        ctx.allocator.free(ctx.body);
        ctx.allocator.free(ctx.base_url);
        ctx.allocator.destroy(ctx);
    }

    var client = std.http.Client{ .allocator = ctx.allocator };
    defer client.deinit();

    const url = std.fmt.allocPrint(
        ctx.allocator,
        "{s}/v1beta/models/{s}:streamGenerateContent?alt=sse&key={s}",
        .{ ctx.base_url, ctx.model.id, ctx.api_key },
    ) catch {
        ctx.stream.completeWithError("oom url");
        return;
    };
    defer ctx.allocator.free(url);

    const uri = std.Uri.parse(url) catch {
        ctx.stream.completeWithError("invalid URL");
        return;
    };

    const headers = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};

    var req = client.request(.POST, uri, .{ .extra_headers = &headers }) catch {
        ctx.stream.completeWithError("request failed");
        return;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = ctx.body.len };
    req.sendBodyComplete(ctx.body) catch {
        ctx.stream.completeWithError("send failed");
        return;
    };

    var head_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch {
        ctx.stream.completeWithError("receive failed");
        return;
    };

    if (response.head.status != .ok) {
        ctx.stream.completeWithError("google request failed");
        return;
    }

    var parser = sse_parser.SSEParser.init(ctx.allocator);
    defer parser.deinit();

    var transfer_buf: [4096]u8 = undefined;
    var read_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    var text = std.ArrayList(u8){};
    defer text.deinit(ctx.allocator);
    var usage = ai_types.Usage{};

    while (true) {
        const n = reader.*.readSliceShort(&read_buf) catch {
            ctx.stream.completeWithError("read failed");
            return;
        };
        if (n == 0) break;

        const events = parser.feed(read_buf[0..n]) catch {
            ctx.stream.completeWithError("parse failed");
            return;
        };

        for (events) |ev| {
            parseGoogleEvent(ev.data, &text, &usage, ctx.allocator) catch {
                ctx.stream.completeWithError("event parse failed");
                return;
            };
        }
    }

    if (usage.total_tokens == 0) usage.total_tokens = usage.input + usage.output;

    var content = ctx.allocator.alloc(ai_types.AssistantContent, 1) catch {
        ctx.stream.completeWithError("oom result");
        return;
    };
    content[0] = .{ .text = .{ .text = ctx.allocator.dupe(u8, text.items) catch {
        ctx.allocator.free(content);
        ctx.stream.completeWithError("oom text");
        return;
    } } };

    const out = ai_types.AssistantMessage{
        .content = content,
        .api = ctx.allocator.dupe(u8, ctx.model.api) catch return ctx.stream.completeWithError("oom"),
        .provider = ctx.allocator.dupe(u8, ctx.model.provider) catch return ctx.stream.completeWithError("oom"),
        .model = ctx.allocator.dupe(u8, ctx.model.id) catch return ctx.stream.completeWithError("oom"),
        .usage = usage,
        .stop_reason = .stop,
        .timestamp = std.time.milliTimestamp(),
    };

    ctx.stream.complete(out);
}

pub fn streamGoogleGenerativeAI(model: ai_types.Model, context: ai_types.Context, options: ?ai_types.StreamOptions, allocator: std.mem.Allocator) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.StreamOptions{};

    const api_key: []u8 = blk: {
        if (o.api_key) |k| break :blk try allocator.dupe(u8, k);
        const e = env(allocator, "GOOGLE_API_KEY");
        if (e) |k| break :blk @constCast(k);
        return error.MissingApiKey;
    };
    errdefer allocator.free(api_key);

    const base_url: []u8 = blk: {
        if (model.base_url.len > 0) break :blk try allocator.dupe(u8, model.base_url);
        const e = env(allocator, "GOOGLE_BASE_URL");
        if (e) |v| break :blk @constCast(v);
        break :blk try allocator.dupe(u8, "https://generativelanguage.googleapis.com");
    };
    errdefer allocator.free(base_url);

    const body = try buildBody(context, o, model, allocator);
    errdefer allocator.free(body);

    const s = try allocator.create(ai_types.AssistantMessageEventStream);
    errdefer allocator.destroy(s);
    s.* = ai_types.AssistantMessageEventStream.init(allocator);

    const ctx = try allocator.create(ThreadCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{ .allocator = allocator, .stream = s, .model = model, .api_key = api_key, .body = body, .base_url = base_url };

    const th = try std.Thread.spawn(.{}, runThread, .{ctx});
    th.detach();
    return s;
}

pub fn streamSimpleGoogleGenerativeAI(model: ai_types.Model, context: ai_types.Context, options: ?ai_types.SimpleStreamOptions, allocator: std.mem.Allocator) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.SimpleStreamOptions{};
    return streamGoogleGenerativeAI(model, context, .{
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

pub fn registerGoogleGenerativeApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "google-generative-ai",
        .stream = streamGoogleGenerativeAI,
        .stream_simple = streamSimpleGoogleGenerativeAI,
    }, null);
}

pub fn registerGoogleGeminiCliApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "google-gemini-cli",
        .stream = streamGoogleGenerativeAI,
        .stream_simple = streamSimpleGoogleGenerativeAI,
    }, null);
}
