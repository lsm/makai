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

fn buildBody(model: ai_types.Model, context: ai_types.Context, options: ai_types.StreamOptions, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    var w = json_writer.JsonWriter.init(&buf, allocator);
    try w.beginObject();
    try w.writeStringField("model", model.id);
    try w.writeBoolField("stream", true);
    try w.writeIntField("max_output_tokens", options.max_tokens orelse model.max_tokens);

    try w.writeKey("input");
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
    try w.endObject();
    return buf.toOwnedSlice(allocator);
}

fn parseEvent(data: []const u8, text: *std.ArrayList(u8), usage: *ai_types.Usage, stop_reason: *ai_types.StopReason, allocator: std.mem.Allocator) !void {
    if (std.mem.eql(u8, data, "[DONE]")) return;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;
    const obj = parsed.value.object;

    const t = obj.get("type") orelse return;
    if (t != .string) return;

    if (std.mem.eql(u8, t.string, "response.output_text.delta")) {
        if (obj.get("delta")) |d| {
            if (d == .string) try text.appendSlice(allocator, d.string);
        }
        return;
    }

    if (std.mem.eql(u8, t.string, "response.completed")) {
        const resp = obj.get("response") orelse return;
        if (resp != .object) return;

        if (resp.object.get("status")) |st| {
            if (st == .string and std.mem.eql(u8, st.string, "incomplete")) {
                stop_reason.* = .length;
            }
        }

        if (resp.object.get("usage")) |u| {
            if (u == .object) {
                if (u.object.get("input_tokens")) |v| {
                    if (v == .integer) usage.input = @intCast(v.integer);
                }
                if (u.object.get("output_tokens")) |v| {
                    if (v == .integer) usage.output = @intCast(v.integer);
                }
                usage.total_tokens = usage.input + usage.output;
            }
        }
    }
}

const ThreadCtx = struct {
    allocator: std.mem.Allocator,
    stream: *ai_types.AssistantMessageEventStream,
    model: ai_types.Model,
    api_key: []u8,
    base_url: []u8,
    body: []u8,
};

fn runThread(ctx: *ThreadCtx) void {
    defer {
        ctx.allocator.free(ctx.api_key);
        ctx.allocator.free(ctx.base_url);
        ctx.allocator.free(ctx.body);
        ctx.allocator.destroy(ctx);
    }

    var client = std.http.Client{ .allocator = ctx.allocator };
    defer client.deinit();

    const url = std.fmt.allocPrint(ctx.allocator, "{s}/openai/v1/responses", .{ctx.base_url}) catch {
        ctx.stream.completeWithError("oom url");
        return;
    };
    defer ctx.allocator.free(url);

    const uri = std.Uri.parse(url) catch {
        ctx.stream.completeWithError("invalid URL");
        return;
    };

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(ctx.allocator);
    headers.append(ctx.allocator, .{ .name = "api-key", .value = ctx.api_key }) catch return ctx.stream.completeWithError("oom headers");
    headers.append(ctx.allocator, .{ .name = "content-type", .value = "application/json" }) catch return ctx.stream.completeWithError("oom headers");

    var req = client.request(.POST, uri, .{ .extra_headers = headers.items }) catch {
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
        ctx.stream.completeWithError("azure request failed");
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
    var stop_reason: ai_types.StopReason = .stop;

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
            parseEvent(ev.data, &text, &usage, &stop_reason, ctx.allocator) catch {
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
        .stop_reason = stop_reason,
        .timestamp = std.time.milliTimestamp(),
    };

    ctx.stream.complete(out);
}

pub fn streamAzureOpenAIResponses(model: ai_types.Model, context: ai_types.Context, options: ?ai_types.StreamOptions, allocator: std.mem.Allocator) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.StreamOptions{};

    const api_key: []u8 = blk: {
        if (o.api_key) |k| break :blk try allocator.dupe(u8, k);
        const e = env(allocator, "AZURE_OPENAI_API_KEY");
        if (e) |k| break :blk @constCast(k);
        return error.MissingApiKey;
    };

    const base_url: []u8 = blk: {
        if (model.base_url.len > 0) break :blk try allocator.dupe(u8, model.base_url);
        const e = env(allocator, "AZURE_OPENAI_BASE_URL");
        if (e) |v| break :blk @constCast(v);
        const resource = env(allocator, "AZURE_RESOURCE_NAME") orelse return error.MissingApiKey;
        defer allocator.free(resource);
        break :blk try std.fmt.allocPrint(allocator, "https://{s}.openai.azure.com", .{resource});
    };

    const body = try buildBody(model, context, o, allocator);

    const s = try allocator.create(ai_types.AssistantMessageEventStream);
    s.* = ai_types.AssistantMessageEventStream.init(allocator);

    const ctx = try allocator.create(ThreadCtx);
    ctx.* = .{ .allocator = allocator, .stream = s, .model = model, .api_key = api_key, .base_url = base_url, .body = body };

    const th = try std.Thread.spawn(.{}, runThread, .{ctx});
    th.detach();
    return s;
}

pub fn streamSimpleAzureOpenAIResponses(model: ai_types.Model, context: ai_types.Context, options: ?ai_types.SimpleStreamOptions, allocator: std.mem.Allocator) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.SimpleStreamOptions{};
    return streamAzureOpenAIResponses(model, context, .{
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

pub fn registerAzureOpenAIResponsesApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "azure-openai-responses",
        .stream = streamAzureOpenAIResponses,
        .stream_simple = streamSimpleAzureOpenAIResponses,
    }, null);
}
