const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const event_stream = @import("event_stream");
const agent_types = @import("agent_types");
const protocol_server = @import("protocol_server");
const protocol_client = @import("protocol_client");
const protocol_runtime = @import("protocol_runtime");
const in_process = @import("transports/in_process");

const ProtocolServer = protocol_server.ProtocolServer;
const ProtocolClient = protocol_client.ProtocolClient;
const ProviderProtocolRuntime = protocol_runtime.ProviderProtocolRuntime;

pub const InProcessProviderProtocolBridge = struct {
    registry: *api_registry.ApiRegistry,

    pub fn init(registry: *api_registry.ApiRegistry) InProcessProviderProtocolBridge {
        return .{ .registry = registry };
    }

    /// Return an agent-compatible protocol client interface.
    pub fn protocolClient(self: *InProcessProviderProtocolBridge) agent_types.ProtocolClient {
        return .{
            .stream_fn = streamViaProtocol,
            .ctx = self,
        };
    }
};

const StreamThreadContext = struct {
    allocator: std.mem.Allocator,
    out_stream: *event_stream.AssistantMessageEventStream,
    registry: *api_registry.ApiRegistry,
    model: ai_types.Model,
    context: ai_types.Context,
    options: agent_types.ProtocolOptions,
    api_key: ?[]u8,
    session_id: ?[]u8,

    fn deinit(self: *StreamThreadContext) void {
        self.model.deinit(self.allocator);
        self.context.deinit(self.allocator);
        if (self.api_key) |k| self.allocator.free(k);
        if (self.session_id) |sid| self.allocator.free(sid);
        self.allocator.destroy(self);
    }
};

fn streamViaProtocol(
    ctx: ?*anyopaque,
    model: ai_types.Model,
    context: ai_types.Context,
    options: agent_types.ProtocolOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageEventStream {
    const bridge: *InProcessProviderProtocolBridge = @ptrCast(@alignCast(ctx));

    const out_stream = try allocator.create(event_stream.AssistantMessageEventStream);
    out_stream.* = event_stream.AssistantMessageEventStream.init(allocator);
    out_stream.owns_events = true;
    out_stream.clone_event_fn = ai_types.cloneAssistantMessageEvent;
    out_stream.wait_for_thread_on_deinit = true;

    const thread_ctx = try allocator.create(StreamThreadContext);
    errdefer allocator.destroy(thread_ctx);

    thread_ctx.* = .{
        .allocator = allocator,
        .out_stream = out_stream,
        .registry = bridge.registry,
        .model = try ai_types.cloneModel(allocator, model),
        .context = try ai_types.cloneContext(allocator, context),
        .options = options,
        .api_key = if (options.api_key) |k| try allocator.dupe(u8, k) else null,
        .session_id = if (options.session_id) |sid| try allocator.dupe(u8, sid) else null,
    };

    const thread = try std.Thread.spawn(.{}, runStreamThread, .{thread_ctx});
    thread.detach();

    return out_stream;
}

fn pushEventBlocking(stream: *event_stream.AssistantMessageEventStream, ev: ai_types.AssistantMessageEvent) !void {
    while (true) {
        stream.push(ev) catch |err| switch (err) {
            error.QueueFull => {
                compat.time.sleepNs(1 * std.time.ns_per_ms);
                continue;
            },
            error.StreamCompleted => return error.StreamCompleted,
            error.OutOfMemory => return error.OutOfMemory,
        };
        return;
    }
}

fn drainClientEvents(client: *ProtocolClient, out_stream: *event_stream.AssistantMessageEventStream, allocator: std.mem.Allocator) !void {
    while (client.getEventStream().poll()) |ev| {
        var owned_ev = ev;
        defer ai_types.deinitAssistantMessageEvent(allocator, &owned_ev);
        try pushEventBlocking(out_stream, ev);
    }
}

fn reasoningEffort(level: ai_types.ThinkingLevel, model_id: []const u8) []const u8 {
    return switch (level) {
        .off => if (std.mem.startsWith(u8, model_id, "gpt-5.1")) "none" else "low",
        .minimal => "low",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn thinkingEffort(level: ai_types.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "",
        .minimal => "low",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "max",
    };
}

fn thinkingBudget(level: ai_types.ThinkingLevel, budgets: ?ai_types.ThinkingBudgets) ?u32 {
    if (level == .off) return null;
    if (budgets) |b| {
        return switch (level) {
            .off => null,
            .minimal => b.minimal orelse 256,
            .low => b.low orelse 512,
            .medium => b.medium orelse 1024,
            .high => b.high orelse 2048,
            .xhigh => b.xhigh orelse 4096,
        };
    }
    return switch (level) {
        .off => null,
        .minimal => 256,
        .low => 512,
        .medium => 1024,
        .high => 2048,
        .xhigh => 4096,
    };
}

fn streamOptionsFromProtocolOptions(options: agent_types.ProtocolOptions, model_id: []const u8, api_key: ?[]const u8, session_id: ?[]const u8) ai_types.StreamOptions {
    const reason_effort = reasoningEffort(options.thinking_level, model_id);
    const think_effort = thinkingEffort(options.thinking_level);
    return .{
        .api_key = if (api_key) |k| ai_types.OwnedSlice(u8).initBorrowed(k) else ai_types.OwnedSlice(u8).initBorrowed(""),
        .session_id = if (session_id) |sid| ai_types.OwnedSlice(u8).initBorrowed(sid) else ai_types.OwnedSlice(u8).initBorrowed(""),
        .cancel_token = options.cancel_token,
        .temperature = options.temperature,
        .max_tokens = options.max_tokens,
        .thinking_enabled = options.thinking_level != .off,
        .thinking_budget_tokens = thinkingBudget(options.thinking_level, options.thinking_budgets),
        .thinking_effort = ai_types.OwnedSlice(u8).initBorrowed(think_effort),
        .reasoning_effort = ai_types.OwnedSlice(u8).initBorrowed(reason_effort),
        .reasoning_enabled = options.thinking_level != .off,
    };
}

fn runStreamThread(ctx: *StreamThreadContext) void {
    defer {
        const out_stream = ctx.out_stream;
        ctx.deinit();
        out_stream.markThreadDone();
    }

    var pipe = in_process.createSerializedPipe(ctx.allocator);
    defer pipe.deinit();

    var server = ProtocolServer.init(ctx.allocator, ctx.registry, .{});
    defer server.deinit();

    var client = ProtocolClient.init(ctx.allocator, .{});
    defer client.deinit();
    client.setSender(pipe.clientSender());

    var runtime = ProviderProtocolRuntime{
        .server = &server,
        .pipe = &pipe,
        .allocator = ctx.allocator,
    };

    const stream_options = streamOptionsFromProtocolOptions(ctx.options, ctx.model.id, ctx.api_key, ctx.session_id);

    // Request envelope deinit frees owned payload fields; send borrowed views of thread-owned state.
    var request_model = ctx.model;
    request_model.is_owned = false;
    var request_context = ctx.context;
    request_context.is_owned = false;
    request_context.system_prompt = ai_types.OwnedSlice(u8).initBorrowed(ctx.context.system_prompt.slice());

    _ = client.sendStreamRequest(request_model, request_context, stream_options) catch |err| {
        ctx.out_stream.completeWithError(@errorName(err));
        return;
    };

    const start_ms = compat.time.nowMillis();
    const timeout_ms: i64 = 120_000;

    while (!client.isComplete()) {
        _ = runtime.pumpOnce(&client) catch |err| {
            ctx.out_stream.completeWithError(@errorName(err));
            return;
        };

        drainClientEvents(&client, ctx.out_stream, ctx.allocator) catch |err| {
            ctx.out_stream.completeWithError(@errorName(err));
            return;
        };

        if (compat.time.nowMillis() - start_ms > timeout_ms) {
            ctx.out_stream.completeWithError("Provider protocol stream timed out");
            return;
        }

        compat.time.sleepNs(1 * std.time.ns_per_ms);
    }

    // Final drain after completion.
    _ = runtime.pumpOnce(&client) catch {};
    drainClientEvents(&client, ctx.out_stream, ctx.allocator) catch |err| {
        ctx.out_stream.completeWithError(@errorName(err));
        return;
    };

    const final_result = client.waitResult(1) catch {
        if (client.getLastError()) |last_err| {
            ctx.out_stream.completeWithError(last_err);
        } else {
            ctx.out_stream.completeWithError("Provider protocol stream failed");
        }
        return;
    };

    if (final_result) |result| {
        const cloned = ai_types.cloneAssistantMessage(ctx.allocator, result) catch |err| {
            ctx.out_stream.completeWithError(@errorName(err));
            return;
        };
        ctx.out_stream.complete(cloned);
        return;
    }

    if (client.getLastError()) |last_err| {
        ctx.out_stream.completeWithError(last_err);
    } else {
        ctx.out_stream.completeWithError("Provider protocol completed without result");
    }
}

test "InProcessProviderProtocolBridge smoke test" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    const Mock = struct {
        fn stream(
            model: ai_types.Model,
            context: ai_types.Context,
            options: ?ai_types.StreamOptions,
            a: std.mem.Allocator,
        ) anyerror!*event_stream.AssistantMessageEventStream {
            _ = model;
            _ = context;

            const s = try a.create(event_stream.AssistantMessageEventStream);
            s.* = event_stream.AssistantMessageEventStream.init(a);
            if (options) |o| {
                if (o.requires_owned_stream_events) {
                    s.owns_events = true;
                    s.clone_event_fn = ai_types.cloneAssistantMessageEvent;
                }
            }

            s.push(.{ .start = .{ .partial = .{
                .content = &.{},
                .api = "mock-api",
                .provider = "mock",
                .model = "mock-model",
                .usage = .{},
                .stop_reason = .stop,
                .timestamp = compat.time.nowMillis(),
                .is_owned = false,
            } } }) catch {};

            s.complete(try ai_types.cloneAssistantMessage(a, .{
                .content = &.{.{ .text = .{ .text = "ok" } }},
                .api = "mock-api",
                .provider = "mock",
                .model = "mock-model",
                .usage = .{},
                .stop_reason = .stop,
                .timestamp = compat.time.nowMillis(),
                .is_owned = false,
            }));
            s.markThreadDone();
            return s;
        }

        fn streamSimple(
            model: ai_types.Model,
            context: ai_types.Context,
            options: ?ai_types.SimpleStreamOptions,
            a: std.mem.Allocator,
        ) anyerror!*event_stream.AssistantMessageEventStream {
            _ = options;
            return stream(model, context, null, a);
        }
    };

    try registry.registerApiProvider(.{
        .api = "mock-api",
        .stream = Mock.stream,
        .stream_simple = Mock.streamSimple,
    }, null);

    var bridge = InProcessProviderProtocolBridge.init(&registry);
    const protocol = bridge.protocolClient();

    const model = ai_types.Model{
        .id = "mock-model",
        .name = "Mock",
        .api = "mock-api",
        .provider = "mock",
        .base_url = "",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 256,
    };

    const user = ai_types.Message{ .user = .{
        .content = .{ .text = "hi" },
        .timestamp = compat.time.nowMillis(),
    } };

    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user} };

    // Provide an explicit api_key so the binary-side credential resolver
    // (M-006) does not reject the request with `auth_required`. The mock
    // provider does not validate the key value.
    const stream = try protocol.stream(model, ctx, .{ .api_key = "test-key" }, allocator);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    var saw_start = false;
    while (stream.wait()) |ev| {
        var owned_ev = ev;
        defer ai_types.deinitAssistantMessageEvent(allocator, &owned_ev);
        if (ev == .start) saw_start = true;
    }

    const result = stream.getResult().?;
    var owned_result = result;
    owned_result.deinit(allocator);
    // We already freed the result contents above. Null the reference so
    // stream.deinit() doesn't attempt a double-free.
    stream.result = null;

    try std.testing.expect(saw_start);
}

test "provider protocol bridge maps thinking level to stream options" {
    const opts = streamOptionsFromProtocolOptions(.{
        .api_key = "key",
        .session_id = "sid",
        .thinking_level = .xhigh,
        .thinking_budgets = .{ .xhigh = 8192 },
    }, "gpt-5.1", "key", "sid");

    try std.testing.expect(opts.thinking_enabled);
    try std.testing.expect(opts.reasoning_enabled);
    try std.testing.expectEqual(@as(?u32, 8192), opts.thinking_budget_tokens);
    try std.testing.expectEqualStrings("max", opts.getThinkingEffort().?);
    try std.testing.expectEqualStrings("xhigh", opts.getReasoningEffort().?);

    const off = streamOptionsFromProtocolOptions(.{ .thinking_level = .off }, "gpt-5.1", null, null);
    try std.testing.expect(!off.thinking_enabled);
    try std.testing.expect(!off.reasoning_enabled);
    try std.testing.expect(off.getThinkingEffort() == null);
    try std.testing.expectEqualStrings("none", off.getReasoningEffort().?);

    const minimal = streamOptionsFromProtocolOptions(.{ .thinking_level = .minimal }, null, null);
    try std.testing.expectEqualStrings("low", minimal.getReasoningEffort().?);
}

test "InProcessProviderProtocolBridge preserves streamed tool call terminal result" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    const Mock = struct {
        fn partial(model: ai_types.Model) ai_types.AssistantMessage {
            return .{
                .content = &.{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = .{},
                .stop_reason = .stop,
                .timestamp = compat.time.nowMillis(),
                .is_owned = false,
            };
        }

        fn stream(
            model: ai_types.Model,
            context: ai_types.Context,
            options: ?ai_types.StreamOptions,
            a: std.mem.Allocator,
        ) anyerror!*event_stream.AssistantMessageEventStream {
            _ = context;
            const o = options orelse ai_types.StreamOptions{};

            const s = try a.create(event_stream.AssistantMessageEventStream);
            s.* = event_stream.AssistantMessageEventStream.init(a);
            if (o.requires_owned_stream_events) {
                s.owns_events = true;
                s.clone_event_fn = ai_types.cloneAssistantMessageEvent;
            }
            const p = partial(model);

            s.push(.{ .start = .{ .partial = p } }) catch {};
            s.push(.{ .toolcall_start = .{
                .content_index = 0,
                .id = "call_shell",
                .name = "shell_execute",
                .partial = p,
            } }) catch {};
            s.push(.{ .toolcall_delta = .{
                .content_index = 0,
                .delta = "{\"command\":\"ls -al\"}",
                .partial = p,
            } }) catch {};
            s.push(.{ .toolcall_end = .{
                .content_index = 0,
                .tool_call = .{ .id = "call_shell", .name = "shell_execute", .arguments_json = "{\"command\":\"ls -al\"}" },
                .partial = p,
            } }) catch {};

            // Match OpenAI Responses behavior: terminal result can omit streamed
            // function-call content and report a generic stop reason.
            s.complete(try ai_types.cloneAssistantMessage(a, .{
                .content = &.{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = .{},
                .stop_reason = .stop,
                .timestamp = compat.time.nowMillis(),
                .is_owned = false,
            }));
            s.markThreadDone();
            return s;
        }

        fn streamSimple(
            model: ai_types.Model,
            context: ai_types.Context,
            options: ?ai_types.SimpleStreamOptions,
            a: std.mem.Allocator,
        ) anyerror!*event_stream.AssistantMessageEventStream {
            _ = options;
            return stream(model, context, null, a);
        }
    };

    try registry.registerApiProvider(.{
        .api = "mock-tool-api",
        .stream = Mock.stream,
        .stream_simple = Mock.streamSimple,
    }, null);

    var bridge = InProcessProviderProtocolBridge.init(&registry);
    const protocol = bridge.protocolClient();
    const model = ai_types.Model{
        .id = "mock-tool-model",
        .name = "Mock Tool",
        .api = "mock-tool-api",
        .provider = "mock",
        .base_url = "",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 256,
    };
    const user = ai_types.Message{ .user = .{
        .content = .{ .text = "run ls -al" },
        .timestamp = compat.time.nowMillis(),
    } };
    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user} };

    const stream = try protocol.stream(model, ctx, .{ .api_key = "test-key" }, allocator);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    var saw_tool_end = false;
    while (stream.wait()) |ev| {
        var owned_ev = ev;
        defer ai_types.deinitAssistantMessageEvent(allocator, &owned_ev);
        if (ev == .toolcall_end) saw_tool_end = true;
    }

    const result = stream.getResult().?;
    try std.testing.expectEqual(ai_types.StopReason.tool_use, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(result.content[0] == .tool_call);
    try std.testing.expectEqualStrings("shell_execute", result.content[0].tool_call.name);

    var owned_result = result;
    owned_result.deinit(allocator);
    stream.result = null;
    try std.testing.expect(saw_tool_end);
}
