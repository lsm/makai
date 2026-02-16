const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");

fn envApiKey(allocator: std.mem.Allocator) ?[]const u8 {
    // Check ANTHROPIC_AUTH_TOKEN first (new standard), then ANTHROPIC_API_KEY (legacy)
    if (std.process.getEnvVarOwned(allocator, "ANTHROPIC_AUTH_TOKEN")) |token| {
        return token;
    } else |_| {}
    return std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch null;
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

fn buildRequestBody(model: ai_types.Model, context: ai_types.Context, options: ai_types.StreamOptions, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    var w = json_writer.JsonWriter.init(&buf, allocator);
    try w.beginObject();
    try w.writeStringField("model", model.id);
    try w.writeIntField("max_tokens", options.max_tokens orelse model.max_tokens);
    try w.writeBoolField("stream", true);

    if (options.temperature) |t| {
        try w.writeKey("temperature");
        try w.writeFloat(t);
    }

    if (context.system_prompt) |sp| {
        try w.writeStringField("system", sp);
    }

    try w.writeKey("messages");
    try w.beginArray();
    for (context.messages) |m| {
        var text = std.ArrayList(u8){};
        defer text.deinit(allocator);
        try appendMessageText(m, &text, allocator);

        const role: []const u8 = switch (m) {
            .assistant => "assistant",
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

fn parseAnthropicEvent(data: []const u8, text: *std.ArrayList(u8), usage: *ai_types.Usage, stop_reason: *ai_types.StopReason, allocator: std.mem.Allocator) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;
    const obj = parsed.value.object;

    const type_val = obj.get("type") orelse return;
    if (type_val != .string) return;

    if (std.mem.eql(u8, type_val.string, "message_start")) {
        const msg_val = obj.get("message") orelse return;
        if (msg_val != .object) return;
        const usage_val = msg_val.object.get("usage") orelse return;
        if (usage_val != .object) return;

        if (usage_val.object.get("input_tokens")) |v| {
            if (v == .integer) usage.input = @intCast(v.integer);
        }
        if (usage_val.object.get("output_tokens")) |v| {
            if (v == .integer) usage.output = @intCast(v.integer);
        }
        return;
    }

    if (std.mem.eql(u8, type_val.string, "content_block_delta")) {
        const delta_val = obj.get("delta") orelse return;
        if (delta_val != .object) return;
        if (delta_val.object.get("text")) |v| {
            if (v == .string) try text.appendSlice(allocator, v.string);
        }
        return;
    }

    if (std.mem.eql(u8, type_val.string, "message_delta")) {
        if (obj.get("delta")) |delta_val| {
            if (delta_val == .object) {
                if (delta_val.object.get("stop_reason")) |sr| {
                    if (sr == .string) {
                        if (std.mem.eql(u8, sr.string, "max_tokens")) stop_reason.* = .length
                        else if (std.mem.eql(u8, sr.string, "tool_use")) stop_reason.* = .tool_use
                        else stop_reason.* = .stop;
                    }
                }
            }
        }

        if (obj.get("usage")) |usage_val| {
            if (usage_val == .object) {
                if (usage_val.object.get("output_tokens")) |v| {
                    if (v == .integer) usage.output = @intCast(v.integer);
                }
            }
        }
    }
}

const ThreadCtx = struct {
    allocator: std.mem.Allocator,
    stream: *ai_types.AssistantMessageEventStream,
    model: ai_types.Model,
    api_key: []u8,
    request_body: []u8,
};

fn runThread(ctx: *ThreadCtx) void {
    defer {
        ctx.allocator.free(ctx.request_body);
        ctx.allocator.free(ctx.api_key);
        ctx.allocator.destroy(ctx);
    }

    var client = std.http.Client{ .allocator = ctx.allocator };
    defer client.deinit();

    const url = std.fmt.allocPrint(ctx.allocator, "{s}/v1/messages", .{ctx.model.base_url}) catch {
        ctx.stream.completeWithError("oom building url");
        return;
    };
    defer ctx.allocator.free(url);

    const auth = std.fmt.allocPrint(ctx.allocator, "{s}", .{ctx.api_key}) catch {
        ctx.stream.completeWithError("oom auth");
        return;
    };
    defer ctx.allocator.free(auth);

    const uri = std.Uri.parse(url) catch {
        ctx.stream.completeWithError("invalid anthropic URL");
        return;
    };

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(ctx.allocator);
    headers.append(ctx.allocator, .{ .name = "x-api-key", .value = auth }) catch {
        ctx.stream.completeWithError("oom headers");
        return;
    };
    headers.append(ctx.allocator, .{ .name = "anthropic-version", .value = "2023-06-01" }) catch {
        ctx.stream.completeWithError("oom headers");
        return;
    };
    headers.append(ctx.allocator, .{ .name = "content-type", .value = "application/json" }) catch {
        ctx.stream.completeWithError("oom headers");
        return;
    };

    var req = client.request(.POST, uri, .{ .extra_headers = headers.items }) catch {
        ctx.stream.completeWithError("request open failed");
        return;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = ctx.request_body.len };
    req.sendBodyComplete(ctx.request_body) catch {
        ctx.stream.completeWithError("request send failed");
        return;
    };

    var head_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch {
        ctx.stream.completeWithError("response failed");
        return;
    };

    if (response.head.status != .ok) {
        const status_code = @intFromEnum(response.head.status);
        const err = std.fmt.allocPrint(ctx.allocator, "anthropic request failed: HTTP {d}{s}", .{
            status_code,
            if (status_code == 401) " (check ANTHROPIC_AUTH_TOKEN/ANTHROPIC_API_KEY is valid)" else "",
        }) catch {
            ctx.stream.completeWithError("anthropic request failed");
            return;
        };
        defer ctx.allocator.free(err);
        ctx.stream.completeWithError(err);
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
            ctx.stream.completeWithError("read error");
            return;
        };
        if (n == 0) break;

        const events = parser.feed(read_buf[0..n]) catch {
            ctx.stream.completeWithError("sse parse error");
            return;
        };

        for (events) |ev| {
            parseAnthropicEvent(ev.data, &text, &usage, &stop_reason, ctx.allocator) catch {
                ctx.stream.completeWithError("event parse error");
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

pub fn streamAnthropicMessages(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.StreamOptions{};

    const api_key: []u8 = blk: {
        if (o.api_key) |k| break :blk try allocator.dupe(u8, k);
        const env = envApiKey(allocator);
        if (env) |k| break :blk @constCast(k);
        return error.MissingApiKey;
    };
    errdefer allocator.free(api_key);

    const body = try buildRequestBody(model, context, o, allocator);
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
        .api_key = api_key,
        .request_body = body,
    };

    const th = try std.Thread.spawn(.{}, runThread, .{ctx});
    th.detach();
    return s;
}

pub fn streamSimpleAnthropicMessages(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.SimpleStreamOptions{};
    return streamAnthropicMessages(model, context, .{
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

pub fn registerAnthropicMessagesApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "anthropic-messages",
        .stream = streamAnthropicMessages,
        .stream_simple = streamSimpleAnthropicMessages,
    }, null);
}
