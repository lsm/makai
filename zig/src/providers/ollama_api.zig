const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
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
            .tool_call => |tc| {
                if (out.items.len > 0) try out.append(allocator, '\n');
                try out.appendSlice(allocator, "[TOOL_CALL: ");
                try out.appendSlice(allocator, tc.name);
                try out.appendSlice(allocator, "(");
                try out.appendSlice(allocator, tc.arguments_json);
                try out.appendSlice(allocator, ")]");
            },
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

fn buildBody(model: ai_types.Model, context: ai_types.Context, options: ai_types.StreamOptions, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    var w = json_writer.JsonWriter.init(&buf, allocator);
    try w.beginObject();

    try w.writeStringField("model", model.id);
    try w.writeBoolField("stream", true);

    try w.writeKey("messages");
    try w.beginArray();

    if (context.system_prompt) |sp| {
        try w.beginObject();
        try w.writeStringField("role", "system");
        try w.writeStringField("content", sp);
        try w.endObject();
    }

    for (context.messages) |m| {
        var text = std.ArrayList(u8){};
        defer text.deinit(allocator);
        try appendMessageText(m, &text, allocator);

        const role: []const u8 = switch (m) {
            .assistant => "assistant",
            .tool_result => "tool",
            else => "user",
        };

        try w.beginObject();
        try w.writeStringField("role", role);
        try w.writeStringField("content", text.items);
        try w.endObject();
    }

    try w.endArray();

    // Add tools if provided (OpenAI-compatible format)
    if (context.tools) |tools| {
        try w.writeKey("tools");
        try w.beginArray();
        for (tools) |tool| {
            try w.beginObject();
            try w.writeStringField("type", "function");
            try w.writeKey("function");
            try w.beginObject();
            try w.writeStringField("name", tool.name);
            try w.writeStringField("description", tool.description);
            try w.writeKey("parameters");
            try w.writeRawJson(tool.parameters_schema_json);
            try w.endObject();
            try w.endObject();
        }
        try w.endArray();
    }

    try w.writeKey("options");
    try w.beginObject();
    if (options.temperature) |t| {
        try w.writeKey("temperature");
        try w.writeFloat(t);
    }
    try w.writeIntField("num_predict", options.max_tokens orelse model.max_tokens);
    try w.endObject();

    try w.endObject();
    return buf.toOwnedSlice(allocator);
}

fn parseLine(line: []const u8, text: *std.ArrayList(u8), usage: *ai_types.Usage, stop_reason: *ai_types.StopReason, allocator: std.mem.Allocator) !void {
    if (line.len == 0) return;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;
    const obj = parsed.value.object;

    if (obj.get("message")) |m| {
        if (m == .object) {
            if (m.object.get("content")) |c| {
                if (c == .string and c.string.len > 0) {
                    try text.appendSlice(allocator, c.string);
                }
            }
        }
    }

    if (obj.get("prompt_eval_count")) |v| {
        if (v == .integer) usage.input = @intCast(v.integer);
    }
    if (obj.get("eval_count")) |v| {
        if (v == .integer) usage.output = @intCast(v.integer);
    }

    if (obj.get("done_reason")) |dr| {
        if (dr == .string) {
            if (std.mem.eql(u8, dr.string, "length")) stop_reason.* = .length else stop_reason.* = .stop;
        }
    }
}

const ThreadCtx = struct {
    allocator: std.mem.Allocator,
    stream: *ai_types.AssistantMessageEventStream,
    model: ai_types.Model,
    base_url: []u8,
    api_key: ?[]u8,
    body: []u8,
};

fn runThread(ctx: *ThreadCtx) void {
    // Save values from ctx that we need after freeing ctx
    const allocator = ctx.allocator;
    const stream = ctx.stream;
    const model = ctx.model;
    const base_url = ctx.base_url;
    const api_key = ctx.api_key;
    const body = ctx.body;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const url = std.fmt.allocPrint(allocator, "{s}/api/chat", .{base_url}) catch {
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("oom url");
        return;
    };
    defer allocator.free(url);

    const uri = std.Uri.parse(url) catch {
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("invalid URL");
        return;
    };

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(allocator);
    headers.append(allocator, .{ .name = "content-type", .value = "application/json" }) catch {
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("oom headers");
        return;
    };

    var auth_value: ?[]u8 = null;
    defer if (auth_value) |v| allocator.free(v);

    if (api_key) |k| {
        auth_value = std.fmt.allocPrint(allocator, "Bearer {s}", .{k}) catch {
            allocator.free(base_url);
            allocator.free(k);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("oom auth header");
            return;
        };
        headers.append(allocator, .{ .name = "authorization", .value = auth_value.? }) catch {
            allocator.free(base_url);
            allocator.free(k);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("oom headers");
            return;
        };
    }

    var req = client.request(.POST, uri, .{ .extra_headers = headers.items }) catch {
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("request failed");
        return;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    req.sendBodyComplete(body) catch {
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("send failed");
        return;
    };

    var head_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch {
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("receive failed");
        return;
    };

    if (response.head.status != .ok) {
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("ollama request failed");
        return;
    }

    var transfer_buf: [4096]u8 = undefined;
    var read_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    var line = std.ArrayList(u8){};
    defer line.deinit(allocator);

    var text = std.ArrayList(u8){};
    defer text.deinit(allocator);

    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;

    while (true) {
        const n = reader.*.readSliceShort(&read_buf) catch {
            allocator.free(base_url);
            if (api_key) |k| allocator.free(k);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("read failed");
            return;
        };
        if (n == 0) break;

        for (read_buf[0..n]) |ch| {
            if (ch == '\n') {
                parseLine(line.items, &text, &usage, &stop_reason, allocator) catch {
                    allocator.free(base_url);
                    if (api_key) |k| allocator.free(k);
                    allocator.free(body);
                    allocator.destroy(ctx);
                    stream.completeWithError("parse failed");
                    return;
                };
                line.clearRetainingCapacity();
            } else {
                line.append(allocator, ch) catch {
                    allocator.free(base_url);
                    if (api_key) |k| allocator.free(k);
                    allocator.free(body);
                    allocator.destroy(ctx);
                    stream.completeWithError("oom line");
                    return;
                };
            }
        }
    }

    if (line.items.len > 0) {
        parseLine(line.items, &text, &usage, &stop_reason, allocator) catch {
            allocator.free(base_url);
            if (api_key) |k| allocator.free(k);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("parse failed");
            return;
        };
    }

    if (usage.total_tokens == 0) usage.total_tokens = usage.input + usage.output;

    var content = allocator.alloc(ai_types.AssistantContent, 1) catch {
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("oom result");
        return;
    };
    // Use static empty string for empty content to avoid allocation
    const text_owned = if (text.items.len == 0) "" else allocator.dupe(u8, text.items) catch {
        allocator.free(content);
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("oom text");
        return;
    };
    content[0] = .{ .text = .{ .text = text_owned } };

    const out = ai_types.AssistantMessage{
        .content = content,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = usage,
        .stop_reason = stop_reason,
        .timestamp = std.time.milliTimestamp(),
    };

    // Free ctx allocations before completing
    allocator.free(base_url);
    if (api_key) |k| allocator.free(k);
    allocator.free(body);
    allocator.destroy(ctx);

    stream.complete(out);
}

pub fn streamOllama(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.StreamOptions{};

    // Ollama supports two modes:
    // 1. Local server (localhost:11434) - default, no auth required
    // 2. Cloud API (ollama.com) - requires OLLAMA_API_KEY via Authorization header
    const api_key: ?[]u8 = blk: {
        if (o.api_key) |k| break :blk try allocator.dupe(u8, k);
        if (env(allocator, "OLLAMA_API_KEY")) |k| break :blk @constCast(k);
        break :blk null;
    };
    errdefer if (api_key) |k| allocator.free(k);

    const base_url = blk: {
        if (model.base_url.len > 0) break :blk try allocator.dupe(u8, model.base_url);
        if (env(allocator, "OLLAMA_BASE_URL")) |v| break :blk @constCast(v);
        // When API key is present, use cloud endpoint (https://ollama.com)
        if (api_key != null) break :blk try allocator.dupe(u8, "https://ollama.com");
        // Otherwise use local server
        break :blk try allocator.dupe(u8, "http://127.0.0.1:11434");
    };
    errdefer allocator.free(base_url);

    const body = try buildBody(model, context, o, allocator);
    errdefer allocator.free(body);

    const s = try allocator.create(ai_types.AssistantMessageEventStream);
    errdefer allocator.destroy(s);
    s.* = ai_types.AssistantMessageEventStream.init(allocator);

    const ctx = try allocator.create(ThreadCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .stream = s,
        .model = model,
        .base_url = base_url,
        .api_key = api_key,
        .body = body,
    };

    const th = try std.Thread.spawn(.{}, runThread, .{ctx});
    th.detach();
    return s;
}

pub fn streamSimpleOllama(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.SimpleStreamOptions{};
    return streamOllama(model, context, .{
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

pub fn registerOllamaApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "ollama",
        .stream = streamOllama,
        .stream_simple = streamSimpleOllama,
    }, null);
}

test "buildBody includes model stream options and messages" {
    const model = ai_types.Model{
        .id = "llama3.2:1b",
        .name = "Llama 3.2 1B",
        .api = "ollama",
        .provider = "ollama",
        .base_url = "",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 131_072,
        .max_tokens = 64,
    };

    const msg = ai_types.Message{ .user = .{
        .content = .{ .text = "hello" },
        .timestamp = 1,
    } };

    const ctx = ai_types.Context{ .system_prompt = "be concise", .messages = &[_]ai_types.Message{msg} };

    const body = try buildBody(model, ctx, .{ .temperature = 0.2, .max_tokens = 12 }, std.testing.allocator);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"llama3.2:1b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"num_predict\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"hello\"") != null);
}

test "parseLine accumulates text usage and stop reason" {
    var text = std.ArrayList(u8){};
    defer text.deinit(std.testing.allocator);

    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;

    const line1 = "{\"message\":{\"role\":\"assistant\",\"content\":\"Hello\"},\"done\":false}";
    const line2 = "{\"message\":{\"role\":\"assistant\",\"content\":\" world\"},\"done\":true,\"prompt_eval_count\":3,\"eval_count\":2,\"done_reason\":\"length\"}";

    try parseLine(line1, &text, &usage, &stop_reason, std.testing.allocator);
    try parseLine(line2, &text, &usage, &stop_reason, std.testing.allocator);

    try std.testing.expectEqualStrings("Hello world", text.items);
    try std.testing.expectEqual(@as(u64, 3), usage.input);
    try std.testing.expectEqual(@as(u64, 2), usage.output);
    try std.testing.expectEqual(ai_types.StopReason.length, stop_reason);
}
