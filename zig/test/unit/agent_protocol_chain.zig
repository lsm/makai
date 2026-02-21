const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const event_stream = @import("event_stream");
const agent_types = @import("agent_types");
const agent_loop = @import("agent_loop");
const agent_bridge = @import("agent_bridge");
const protocol_agent_server = @import("protocol_agent_server");
const protocol_agent_client = @import("protocol_agent_client");
const protocol_agent_runtime = @import("protocol_agent_runtime");
const in_process = @import("transports/in_process");

const InProcessProviderProtocolBridge = agent_bridge.InProcessProviderProtocolBridge;
const AgentProtocolServer = protocol_agent_server.AgentProtocolServer;
const AgentProtocolClient = protocol_agent_client.AgentProtocolClient;
const AgentProtocolRuntime = protocol_agent_runtime.AgentProtocolRuntime;

fn mockProviderStream(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = context;
    _ = options;

    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);

    const final = ai_types.AssistantMessage{
        .content = &.{},
        .api = "mock-api",
        .provider = "mock",
        .model = "mock-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = std.time.milliTimestamp(),
    };

    try s.push(.{ .done = .{ .reason = .stop, .message = final } });
    s.complete(final);
    s.markThreadDone();
    return s;
}

fn mockProviderStreamSimple(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = options;
    return mockProviderStream(model, context, null, allocator);
}

test "distributed chain: protocol/agent -> agent_loop -> protocol/provider" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerApiProvider(.{
        .api = "mock-api",
        .stream = mockProviderStream,
        .stream_simple = mockProviderStreamSimple,
    }, null);

    var bridge = InProcessProviderProtocolBridge.init(&registry);

    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    var pipe = in_process.SerializedPipe.init(allocator);
    defer pipe.deinit();

    var client = AgentProtocolClient.init(allocator);
    defer client.deinit();
    client.setSender(pipe.clientSender());

    var runtime = AgentProtocolRuntime{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };

    _ = try client.sendAgentStart("{}", null);
    _ = try runtime.pumpOnce(&client);

    const sid = client.session_id.?;

    _ = try client.sendAgentMessage(sid, "{\"role\":\"user\",\"content\":\"hello\"}", null);
    _ = try runtime.pumpOnce(&client);

    var ctx = agent_types.AgentContext.init(allocator);
    defer ctx.deinit();

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

    const prompt = ai_types.Message{ .user = .{
        .content = .{ .text = "hello" },
        .timestamp = std.time.milliTimestamp(),
    } };

    const loop_stream = try agent_loop.agentLoop(allocator, &.{prompt}, &ctx, .{
        .model = model,
        .protocol = bridge.protocolClient(),
    });
    defer {
        loop_stream.deinit();
        allocator.destroy(loop_stream);
    }

    while (loop_stream.wait()) |_| {}
    const loop_result = loop_stream.getResult().?;
    try std.testing.expect(loop_result.final_message.stop_reason == .stop);

    try server.publishAgentEvent(sid, "{\"type\":\"turn_end\"}");
    try server.publishAgentResult(sid, "{\"ok\":true}");

    _ = try runtime.pumpOnce(&client);

    var ev = client.popEvent().?;
    defer ev.deinit(allocator);
    try std.testing.expectEqualStrings("{\"type\":\"turn_end\"}", ev.slice());
    try std.testing.expectEqualStrings("{\"ok\":true}", client.getLastResultJson().?);
}
