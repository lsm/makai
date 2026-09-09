const std = @import("std");
const agent_server = @import("agent_server");
const agent_client = @import("agent_client");
const agent_envelope = @import("agent_envelope");
const in_process = @import("transports/in_process");

const AgentProtocolServer = agent_server.AgentProtocolServer;
const AgentProtocolClient = agent_client.AgentProtocolClient;
const PipeTransport = in_process.SerializedPipe;

pub const AgentProtocolRuntime = struct {
    server: *AgentProtocolServer,
    pipe: *PipeTransport,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn pumpClientMessages(self: *Self) !void {
        var recv = self.pipe.serverReceiver();
        while (try recv.readLine(self.allocator)) |line| {
            defer self.allocator.free(line);

            var env = agent_envelope.deserializeEnvelope(line, self.allocator) catch continue;
            defer env.deinit(self.allocator);

            if (try self.server.handleEnvelope(env)) |response| {
                var out = response;
                defer out.deinit(self.allocator);

                const json = try agent_envelope.serializeEnvelope(out, self.allocator);
                defer self.allocator.free(json);

                var sender = self.pipe.serverSender();
                try sender.write(json);
                try sender.flush();
            }
        }
    }

    pub fn pumpServerOutbox(self: *Self) !usize {
        var count: usize = 0;
        // Transactional delivery (#210 gap 5): peek, serialize, and write a
        // frame BEFORE removing it from the outbox — popping first (the old
        // order) destroyed the already-built envelope on any serialization
        // or write failure, so an `agent_result` lost this way left its
        // completed run settled-nowhere with nothing to retry. Now the
        // failure propagates (surfacing as the host's typed runtime error
        // frame) and the envelope stays queued for the next pump. The
        // pipe's write is all-or-nothing (`SerializedPipe.appendFramed`
        // reserves data + newline before appending), so a retried frame can
        // never land on a partial line.
        while (self.server.peekOutbound()) |env| {
            const json = try agent_envelope.serializeEnvelope(env.*, self.allocator);
            defer self.allocator.free(json);

            var sender = self.pipe.serverSender();
            try sender.write(json);
            try sender.flush();

            var delivered = self.server.popOutbound().?;
            delivered.deinit(self.allocator);
            count += 1;
        }
        return count;
    }

    pub fn pumpServerMessagesIntoClient(self: *Self, client: *AgentProtocolClient) !void {
        var recv = self.pipe.clientReceiver();
        while (try recv.readLine(self.allocator)) |line| {
            defer self.allocator.free(line);

            var env = agent_envelope.deserializeEnvelope(line, self.allocator) catch continue;
            defer env.deinit(self.allocator);
            try client.processEnvelope(env);
        }
    }

    pub fn pumpOnce(self: *Self, client: *AgentProtocolClient) !usize {
        try self.pumpClientMessages();
        const out_count = try self.pumpServerOutbox();
        try self.pumpServerMessagesIntoClient(client);
        return out_count;
    }
};

test "AgentProtocolRuntime supports multi-session routing" {
    const allocator = std.testing.allocator;

    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    var pipe = PipeTransport.init(allocator);
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
    const sid1 = client.session_id.?;

    _ = try client.sendAgentStart("{}", null);
    _ = try runtime.pumpOnce(&client);
    const sid2 = client.session_id.?;

    try std.testing.expect(!std.mem.eql(u8, sid1[0..], sid2[0..]));
    try std.testing.expectEqual(@as(usize, 2), server.sessionCount());

    _ = try client.sendAgentMessage(sid1, "{\"role\":\"user\",\"content\":\"one\"}", null);
    _ = try client.sendAgentMessage(sid2, "{\"role\":\"user\",\"content\":\"two\"}", null);
    _ = try runtime.pumpOnce(&client);

    try server.publishAgentEvent(sid1, "{\"session\":1}");
    try server.publishAgentEvent(sid2, "{\"session\":2}");
    _ = try runtime.pumpOnce(&client);

    var ev1 = client.popEvent().?;
    defer ev1.deinit(allocator);
    var ev2 = client.popEvent().?;
    defer ev2.deinit(allocator);

    const a = ev1.json.slice();
    const b = ev2.json.slice();
    const ok = (std.mem.find(u8, a, "session") != null) and (std.mem.find(u8, b, "session") != null);
    try std.testing.expect(ok);

    try std.testing.expectEqual(@as(usize, 2), server.sessionCount());
}

test "AgentProtocolRuntime pumps full request/response and outbox" {
    const allocator = std.testing.allocator;

    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    var pipe = PipeTransport.init(allocator);
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

    try server.publishAgentEvent(sid, "{\"type\":\"message\"}");
    try server.publishAgentResult(sid, "{\"messages\":[]}");

    _ = try runtime.pumpOnce(&client);

    var ev = client.popEvent().?;
    defer ev.deinit(allocator);
    try std.testing.expectEqualStrings("{\"type\":\"message\"}", ev.json.slice());
    try std.testing.expectEqualStrings("{\"messages\":[]}", client.getLastResultJson().?);
}

// #210 gap 5: an outbox envelope must never be destroyed by its own
// delivery failure — the frame stays queued (peek-before-pop), the failure
// propagates, and the next pump delivers it exactly once. Sweeping
// fail_index covers every allocation of the serialize path.
test "AgentProtocolRuntime outbox delivery is transactional under allocation failure" {
    const allocator = std.testing.allocator;

    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    var pipe = PipeTransport.init(allocator);
    defer pipe.deinit();

    var client = AgentProtocolClient.init(allocator);
    defer client.deinit();
    client.setSender(pipe.clientSender());

    var setup_runtime = AgentProtocolRuntime{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };
    _ = try client.sendAgentStart("{}", null);
    try setup_runtime.pumpClientMessages();
    // Deliver the synchronous agent_started reply into the client (this is
    // what adopts the session id) and consume it, so only the queued
    // agent_result is read at the end of this test.
    try setup_runtime.pumpServerMessagesIntoClient(&client);
    const sid = client.session_id.?;

    try server.publishAgentResult(sid, "{\"messages\":[]}");

    var fail_index: usize = 0;
    while (fail_index <= 6) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var runtime = AgentProtocolRuntime{
            .server = &server,
            .pipe = &pipe,
            .allocator = failing.allocator(),
        };
        if (runtime.pumpServerOutbox()) |_| {
            try std.testing.expect(server.peekOutbound() == null);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            // The frame survived its own failed delivery.
            try std.testing.expect(server.peekOutbound() != null);
        }
    }

    // Whatever the sweep did, the frame was delivered AT MOST once and
    // never lost: after a final recovery pump exactly one agent_result line
    // is readable.
    _ = try setup_runtime.pumpServerOutbox();
    try std.testing.expect(server.peekOutbound() == null);

    var receiver = pipe.clientReceiver();
    var result_lines: usize = 0;
    while (try receiver.readLine(allocator)) |line| {
        defer allocator.free(line);
        if (std.mem.find(u8, line, "agent_result") != null) result_lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), result_lines);
}
