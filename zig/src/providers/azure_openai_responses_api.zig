const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");
const api_registry = @import("api_registry");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");

fn env(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return compat.getEnvVarOwned(allocator, name) catch null;
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
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    var w = json_writer.JsonWriter.init(&buf, allocator);
    try w.beginObject();
    try w.writeStringField("model", model.id);

    // Add tools if present
    if (context.tools) |tools| {
        if (tools.len > 0) {
            try w.writeKey("tools");
            try w.beginArray();
            for (tools) |tool| {
                try w.beginObject();
                try w.writeStringField("type", "function");
                try w.writeStringField("name", tool.name);
                try w.writeStringField("description", tool.description);
                try w.writeBoolField("strict", true);
                try w.writeKey("parameters");
                try w.writeRawJson(tool.parameters_schema_json);
                try w.endObject();
            }
            try w.endArray();
        }
    }

    try w.writeBoolField("stream", true);
    try w.writeIntField("max_output_tokens", options.max_tokens orelse model.max_tokens);

    try w.writeKey("input");
    try w.beginArray();
    if (context.getSystemPrompt()) |sp| {
        try w.beginObject();
        try w.writeStringField("role", "system");
        try w.writeStringField("content", sp);
        try w.endObject();
    }

    for (context.messages) |m| {
        switch (m) {
            .user => |u| {
                try w.beginObject();
                try w.writeStringField("type", "message");
                try w.writeStringField("role", "user");

                // Handle content
                switch (u.content) {
                    .text => |t| {
                        try w.writeStringField("content", t);
                    },
                    .parts => |parts| {
                        try w.writeKey("content");
                        try w.beginArray();
                        for (parts) |p| {
                            switch (p) {
                                .text => |t| {
                                    try w.beginObject();
                                    try w.writeStringField("type", "input_text");
                                    try w.writeStringField("text", t.text);
                                    try w.endObject();
                                },
                                .image => |img| {
                                    try w.beginObject();
                                    try w.writeStringField("type", "input_image");
                                    try w.writeStringField("image_url", img.data);
                                    try w.endObject();
                                },
                            }
                        }
                        try w.endArray();
                    },
                }
                try w.endObject();
            },
            .assistant => |a| {
                // Output each content item as appropriate type
                for (a.content) |c| {
                    switch (c) {
                        .text => |t| {
                            try w.beginObject();
                            try w.writeStringField("type", "message");
                            try w.writeStringField("role", "assistant");
                            try w.writeStringField("content", t.text);
                            try w.endObject();
                        },
                        .thinking => |t| {
                            // Thinking content - skip or handle as needed
                            _ = t;
                        },
                        .tool_call => |tc| {
                            // Output as function_call item
                            try w.beginObject();
                            try w.writeStringField("type", "function_call");
                            try w.writeStringField("call_id", tc.id);
                            try w.writeStringField("name", tc.name);
                            try w.writeStringField("arguments", tc.arguments_json);
                            try w.endObject();
                        },
                        .image => {},
                    }
                }
            },
            .tool_result => |tr| {
                // Output as function_call_output
                var result_text = std.ArrayList(u8).empty;
                defer result_text.deinit(allocator);
                for (tr.content) |c| {
                    switch (c) {
                        .text => |t| {
                            if (result_text.items.len > 0) try result_text.append(allocator, '\n');
                            try result_text.appendSlice(allocator, t.text);
                        },
                        .image => {},
                    }
                }
                try w.beginObject();
                try w.writeStringField("type", "function_call_output");
                try w.writeStringField("call_id", tr.tool_call_id);
                try w.writeStringField("output", result_text.items);
                try w.endObject();
            },
        }
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
    stream: *event_stream.AssistantMessageEventStream,
    model: ai_types.Model,
    context: ai_types.Context,
    api_key: []u8,
    base_url: []u8,
    body: []u8,
    cancel_token: ?ai_types.CancelToken = null,
    ping_interval_ms: ?u64 = null,

    /// Clean up all owned resources (model, context, api_key, base_url, body, self).
    fn deinit(self: *ThreadCtx) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.base_url);
        self.allocator.free(self.body);
        var mut_context = self.context;
        mut_context.deinit(self.allocator);
        var mut_model = self.model;
        mut_model.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

fn runThread(ctx: *ThreadCtx) void {
    defer ctx.deinit();

    if (ctx.cancel_token) |ct| {
        if (ct.isCancelled()) {
            ctx.stream.markThreadDone();
            ctx.stream.completeWithError("request cancelled");
            return;
        }
    }

    var client = compat.http.HttpClient.init(ctx.allocator);
    defer client.deinit();

    const url = std.fmt.allocPrint(ctx.allocator, "{s}/openai/v1/responses", .{ctx.base_url}) catch {
        ctx.stream.markThreadDone();
        ctx.stream.completeWithError("oom url");
        return;
    };
    defer ctx.allocator.free(url);

    const uri = std.Uri.parse(url) catch {
        ctx.stream.markThreadDone();
        ctx.stream.completeWithError("invalid URL");
        return;
    };

    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(ctx.allocator);
    headers.append(ctx.allocator, .{ .name = "api-key", .value = ctx.api_key }) catch {
        ctx.stream.markThreadDone();
        return ctx.stream.completeWithError("oom headers");
    };
    headers.append(ctx.allocator, .{ .name = "content-type", .value = "application/json" }) catch {
        ctx.stream.markThreadDone();
        return ctx.stream.completeWithError("oom headers");
    };

    var req = client.openRequest(.POST, uri, .{ .extra_headers = headers.items }) catch {
        ctx.stream.markThreadDone();
        ctx.stream.completeWithError("request failed");
        return;
    };
    defer req.deinit();

    compat.http.sendRequest(&req, ctx.body) catch {
        ctx.stream.markThreadDone();
        ctx.stream.completeWithError("send failed");
        return;
    };

    var head_buf: [4096]u8 = undefined;
    var response = compat.http.receiveResponse(&req, &head_buf) catch {
        ctx.stream.markThreadDone();
        ctx.stream.completeWithError("receive failed");
        return;
    };

    if (response.head.status != .ok) {
        // Read error body for debugging
        var error_buf: [4096]u8 = undefined;
        const error_reader = compat.http.responseReader(&response, &error_buf);
        const error_body = compat.http.allocRemainingResponse(ctx.allocator, error_reader, 8192) catch null;
        defer if (error_body) |eb| ctx.allocator.free(eb);

        std.debug.print("Azure OpenAI Responses API error: status={d}, model={s}\n", .{ @intFromEnum(response.head.status), ctx.model.name });
        if (error_body) |eb| {
            std.debug.print("Error body: {s}\n", .{eb});
        }

        ctx.stream.markThreadDone();
        ctx.stream.completeWithError("azure request failed");
        return;
    }

    var parser = sse_parser.SSEParser.init(ctx.allocator);
    defer parser.deinit();

    var transfer_buf: [4096]u8 = undefined;
    var read_buf: [8192]u8 = undefined;
    const reader = compat.http.responseReader(&response, &transfer_buf);

    var text = std.ArrayList(u8).empty;
    defer text.deinit(ctx.allocator);
    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;

    // Ping tracking
    var last_ping_time: i64 = 0;
    const ping_interval = ctx.ping_interval_ms orelse 0;

    while (true) {
        // Emit ping if interval is configured
        if (ping_interval > 0) {
            const now = compat.time.nowMillis();
            if (now - last_ping_time >= ping_interval) {
                ctx.stream.push(.{ .keepalive = {} }) catch {};
                last_ping_time = now;
            }
        }

        const n = compat.http.readResponse(reader, &read_buf) catch {
            ctx.stream.markThreadDone();
            ctx.stream.completeWithError("read failed");
            return;
        };
        if (n == 0) break;

        const events = parser.feed(read_buf[0..n]) catch |err| {
            ctx.stream.markThreadDone();
            ctx.stream.completeWithError(sse_parser.errorMessage(err));
            return;
        };

        for (events) |ev| {
            parseEvent(ev.data, &text, &usage, &stop_reason, ctx.allocator) catch {
                ctx.stream.markThreadDone();
                ctx.stream.completeWithError("event parse failed");
                return;
            };
        }
    }

    if (usage.total_tokens == 0) usage.total_tokens = usage.input + usage.output;

    var content = ctx.allocator.alloc(ai_types.AssistantContent, 1) catch {
        ctx.stream.markThreadDone();
        ctx.stream.completeWithError("oom result");
        return;
    };
    content[0] = .{ .text = .{ .text = ctx.allocator.dupe(u8, text.items) catch {
        ctx.allocator.free(content);
        ctx.stream.markThreadDone();
        ctx.stream.completeWithError("oom text");
        return;
    } } };

    const out = ai_types.AssistantMessage{
        .content = content,
        .api = ctx.allocator.dupe(u8, ctx.model.api) catch {
            ctx.stream.markThreadDone();
            return ctx.stream.completeWithError("oom");
        },
        .provider = ctx.allocator.dupe(u8, ctx.model.provider) catch {
            ctx.stream.markThreadDone();
            return ctx.stream.completeWithError("oom");
        },
        .model = ctx.allocator.dupe(u8, ctx.model.id) catch {
            ctx.stream.markThreadDone();
            return ctx.stream.completeWithError("oom");
        },
        .usage = usage,
        .stop_reason = stop_reason,
        .timestamp = compat.time.nowMillis(),
        .is_owned = true, // Strings were duped above
    };

    ctx.stream.markThreadDone();
    ctx.stream.complete(out);
}

pub fn streamAzureOpenAIResponses(model: ai_types.Model, context: ai_types.Context, options: ?ai_types.StreamOptions, allocator: std.mem.Allocator) !*event_stream.AssistantMessageEventStream {
    const o = options orelse ai_types.StreamOptions{};

    const api_key: []u8 = blk: {
        if (o.getApiKey()) |k| break :blk try allocator.dupe(u8, k);
        const e = env(allocator, "AZURE_OPENAI_API_KEY");
        if (e) |k| break :blk @constCast(k);
        return error.MissingApiKey;
    };
    errdefer allocator.free(api_key);

    const base_url: []u8 = blk: {
        if (model.base_url.len > 0) break :blk try allocator.dupe(u8, model.base_url);
        const e = env(allocator, "AZURE_OPENAI_BASE_URL");
        if (e) |v| break :blk @constCast(v);
        const resource = env(allocator, "AZURE_RESOURCE_NAME") orelse return error.MissingApiKey;
        defer allocator.free(resource);
        break :blk try std.fmt.allocPrint(allocator, "https://{s}.openai.azure.com", .{resource});
    };
    errdefer allocator.free(base_url);

    // Clone model to own the memory (background thread outlives caller's memory)
    const owned_model = try ai_types.cloneModel(allocator, model);
    errdefer {
        var mut_m = owned_model;
        mut_m.deinit(allocator);
    }

    // Clone context to own the memory (background thread outlives caller's memory)
    const owned_context = try ai_types.cloneContext(allocator, context);
    errdefer {
        var mut_ctx = owned_context;
        mut_ctx.deinit(allocator);
    }

    const body = try buildBody(owned_model, owned_context, o, allocator);
    errdefer allocator.free(body);

    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    errdefer allocator.destroy(s);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);
    s.wait_for_thread_on_deinit = true;
    if (o.requires_owned_stream_events) {
        s.owns_events = true;
        s.clone_event_fn = ai_types.cloneAssistantMessageEvent;
    }

    const ctx = try allocator.create(ThreadCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{ .allocator = allocator, .stream = s, .model = owned_model, .context = owned_context, .api_key = api_key, .base_url = base_url, .body = body, .cancel_token = o.cancel_token, .ping_interval_ms = o.ping_interval_ms };

    const th = try std.Thread.spawn(.{}, runThread, .{ctx});
    th.detach();
    return s;
}

pub fn streamSimpleAzureOpenAIResponses(model: ai_types.Model, context: ai_types.Context, options: ?ai_types.SimpleStreamOptions, allocator: std.mem.Allocator) !*event_stream.AssistantMessageEventStream {
    const o = options orelse ai_types.SimpleStreamOptions{};
    return streamAzureOpenAIResponses(model, context, .{
        .temperature = o.temperature,
        .max_tokens = o.max_tokens,
        .api_key = if (o.api_key) |k| ai_types.OwnedSlice(u8).initBorrowed(k) else ai_types.OwnedSlice(u8).initBorrowed(""),
        .cache_retention = o.cache_retention,
        .session_id = if (o.session_id) |sid| ai_types.OwnedSlice(u8).initBorrowed(sid) else ai_types.OwnedSlice(u8).initBorrowed(""),
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

test "parseEvent appends output_text delta" {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(std.testing.allocator);

    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;

    const payload =
        \\{"type":"response.output_text.delta","delta":"hello"}
    ;
    try parseEvent(payload, &text, &usage, &stop_reason, std.testing.allocator);

    try std.testing.expectEqualStrings("hello", text.items);
    try std.testing.expectEqual(ai_types.StopReason.stop, stop_reason);
}

test "parseEvent extracts incomplete stop reason and usage from response.completed" {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(std.testing.allocator);

    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;

    const payload =
        \\{"type":"response.completed","response":{"status":"incomplete","usage":{"input_tokens":12,"output_tokens":34}}}
    ;
    try parseEvent(payload, &text, &usage, &stop_reason, std.testing.allocator);

    try std.testing.expectEqual(ai_types.StopReason.length, stop_reason);
    try std.testing.expectEqual(@as(u64, 12), usage.input);
    try std.testing.expectEqual(@as(u64, 34), usage.output);
    try std.testing.expectEqual(@as(u64, 46), usage.total_tokens);
}

test "parseEvent ignores done sentinel" {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(std.testing.allocator);

    var usage = ai_types.Usage{ .input = 1, .output = 2, .total_tokens = 3 };
    var stop_reason: ai_types.StopReason = .stop;

    try parseEvent("[DONE]", &text, &usage, &stop_reason, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), text.items.len);
    try std.testing.expectEqual(@as(u64, 3), usage.total_tokens);
    try std.testing.expectEqual(ai_types.StopReason.stop, stop_reason);
}


fn regressionModel(api_name: []const u8, provider_name: []const u8, base_url: []const u8) ai_types.Model {
    return .{
        .id = "regression-model",
        .name = "regression-model",
        .api = api_name,
        .provider = provider_name,
        .base_url = base_url,
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 16,
    };
}

fn regressionContext() ai_types.Context {
    const messages = struct {
        const items = [_]ai_types.Message{.{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } }};
    }.items[0..];
    return .{ .messages = messages };
}

fn expectCancelledStream(stream: *event_stream.AssistantMessageEventStream, allocator: std.mem.Allocator) !void {
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    const deadline = compat.time.nowMillis() + 5_000;
    while (!stream.isDone()) {
        if (compat.time.nowMillis() >= deadline) return error.TestUnexpectedResult;
        compat.time.sleepNs(std.time.ns_per_ms);
    }

    try std.testing.expect(stream.waitForThread(5_000));
    try std.testing.expect(stream.getError() != null);
    try std.testing.expectEqualStrings("request cancelled", stream.getError().?);
}


test "provider_cancellation_azure_cancel_before_request" {
    var cancelled = std.atomic.Value(bool).init(true);
    const cancel_token = ai_types.CancelToken{ .cancelled = &cancelled };
    const stream = try streamSimpleAzureOpenAIResponses(
        regressionModel("azure-openai-responses", "azure", "https://example.openai.azure.com"),
        regressionContext(),
        .{ .api_key = "test-key", .cancel_token = cancel_token },
        std.testing.allocator,
    );
    try expectCancelledStream(stream, std.testing.allocator);
}
