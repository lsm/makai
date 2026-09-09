const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const event_stream = @import("event_stream");
const agent_types = @import("agent_types");
const agent_loop = @import("agent_loop");
const agent_bridge = @import("agent_bridge");
const protocol_agent_server = @import("protocol_agent_server");
const protocol_agent_client = @import("protocol_agent_client");
const protocol_agent_runtime = @import("protocol_agent_runtime");
const agent_envelope = @import("agent_envelope");
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

    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);
    if (options) |o| {
        if (o.requires_owned_stream_events) {
            s.owns_events = true;
            s.clone_event_fn = ai_types.cloneAssistantMessageEvent;
        }
    }

    const final = ai_types.AssistantMessage{
        .content = &.{},
        .api = "mock-api",
        .provider = "mock",
        .model = "mock-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = compat.time.nowMillis(),
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

    const prompt_text = try allocator.dupe(u8, "hello");
    const prompt = ai_types.Message{ .user = .{
        .content = .{ .text = prompt_text },
        .timestamp = compat.time.nowMillis(),
    } };

    const loop_stream = try agent_loop.agentLoop(allocator, &.{prompt}, &ctx, .{
        .model = model,
        .protocol = bridge.protocolClient(),
        // M-006: provide an explicit api_key so the binary's credential
        // resolver does not reject the upstream stream_request with
        // `auth_required`. The mock provider does not validate the key value.
        .api_key = "test-key",
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
    try std.testing.expectEqualStrings("{\"type\":\"turn_end\"}", ev.json.slice());
    try std.testing.expectEqualStrings("{\"ok\":true}", client.getLastResultJson().?);
}

test "agent_start dual-key parse binds the session under either payload key (#198)" {
    // Wire-level: the payload id travels under the canonical `session_id`
    // key (new clients) or the legacy `resume_session_id` alias (older
    // clients); the server binds the session container to that id in both
    // cases, and the §13.1 envelope-agreement check applies to whichever
    // key carried it.
    const allocator = std.testing.allocator;

    const keys = [_][]const u8{ "session_id", "resume_session_id" };
    for (keys) |key| {
        var server = AgentProtocolServer.init(allocator);
        defer server.deinit();

        // The chain test's `agent_types` import is the agent-LAYER types
        // module, which has no id parsers; the protocol agent types (and
        // their parseSessionId) are re-exported by the envelope module.
        const sid = agent_envelope.protocol_types.parseSessionId("aaaaaaaaaaaaaaaaaaaaa").?;
        const mid = "00000000000000000000000002";
        const json = try std.fmt.allocPrint(
            allocator,
            "{{\"type\":\"agent_start\",\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{\"config_json\":\"{{}}\",\"{s}\":\"{s}\"}}}}",
            .{ &sid, mid, key, &sid },
        );
        defer allocator.free(json);

        var env = try agent_envelope.deserializeEnvelope(json, allocator);
        defer env.deinit(allocator);
        try std.testing.expectEqual(sid, env.payload.agent_start.session_id.?);

        var resp = (try server.handleEnvelope(env)).?;
        defer resp.deinit(allocator);

        // The container is bound to the payload id (not a server-generated
        // one) and the reply travels under the same id.
        try std.testing.expect(resp.payload == .agent_started);
        try std.testing.expectEqual(sid, resp.payload.agent_started.session_id);
        try std.testing.expectEqual(sid, resp.session_id);
        try std.testing.expect(server.hasSession(sid));
    }
}
