const std = @import("std");
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
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        return;
    }
}

fn drainClientEvents(client: *ProtocolClient, out_stream: *event_stream.AssistantMessageEventStream) !void {
    while (client.getEventStream().poll()) |ev| {
        try pushEventBlocking(out_stream, ev);
    }
}

fn runStreamThread(ctx: *StreamThreadContext) void {
    defer {
        ctx.out_stream.markThreadDone();
        ctx.deinit();
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

    const stream_options = ai_types.StreamOptions{
        .api_key = if (ctx.api_key) |k| ai_types.OwnedSlice(u8).initBorrowed(k) else ai_types.OwnedSlice(u8).initBorrowed(""),
        .session_id = if (ctx.session_id) |sid| ai_types.OwnedSlice(u8).initBorrowed(sid) else ai_types.OwnedSlice(u8).initBorrowed(""),
        .cancel_token = ctx.options.cancel_token,
        .temperature = ctx.options.temperature,
        .max_tokens = ctx.options.max_tokens,
    };

    _ = client.sendStreamRequest(ctx.model, ctx.context, stream_options) catch |err| {
        ctx.out_stream.completeWithError(@errorName(err));
        return;
    };

    const start_ms = std.time.milliTimestamp();
    const timeout_ms: i64 = 120_000;

    while (!client.isComplete()) {
        _ = runtime.pumpOnce(&client) catch |err| {
            ctx.out_stream.completeWithError(@errorName(err));
            return;
        };

        drainClientEvents(&client, ctx.out_stream) catch |err| {
            ctx.out_stream.completeWithError(@errorName(err));
            return;
        };

        if (std.time.milliTimestamp() - start_ms > timeout_ms) {
            ctx.out_stream.completeWithError("Provider protocol stream timed out");
            return;
        }

        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    // Final drain after completion.
    _ = runtime.pumpOnce(&client) catch {};
    drainClientEvents(&client, ctx.out_stream) catch |err| {
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
            _ = options;

            const s = try a.create(event_stream.AssistantMessageEventStream);
            s.* = event_stream.AssistantMessageEventStream.init(a);

            const content = try a.alloc(ai_types.AssistantContent, 1);
            content[0] = .{ .text = .{ .text = try a.dupe(u8, "ok") } };

            s.push(.{ .start = .{ .partial = .{
                .content = content,
                .api = "mock-api",
                .provider = "mock",
                .model = "mock-model",
                .usage = .{},
                .stop_reason = .stop,
                .timestamp = std.time.milliTimestamp(),
                .is_owned = false,
            } } }) catch {};

            s.complete(.{
                .content = content,
                .api = "mock-api",
                .provider = "mock",
                .model = "mock-model",
                .usage = .{},
                .stop_reason = .stop,
                .timestamp = std.time.milliTimestamp(),
                .is_owned = false,
            });
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
        .timestamp = std.time.milliTimestamp(),
    } };

    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user} };

    const stream = try protocol.stream(model, ctx, .{}, allocator);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    var saw_start = false;
    while (stream.wait()) |ev| {
        if (ev == .start) saw_start = true;
    }

    try std.testing.expect(saw_start);
    try std.testing.expect(stream.getResult() != null);
}
