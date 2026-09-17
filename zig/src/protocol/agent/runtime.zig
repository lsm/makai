const std = @import("std");
const agent_server = @import("agent_server");
const agent_client = @import("agent_client");
const agent_envelope = @import("agent_envelope");
const in_process = @import("transports/in_process");
const compat = @import("compat");
const fields = @import("envelope_fields");

const AgentProtocolServer = agent_server.AgentProtocolServer;
const AgentProtocolClient = agent_client.AgentProtocolClient;
const PipeTransport = in_process.SerializedPipe;
const agent_types = agent_envelope.protocol_types;

pub const AgentProtocolRuntime = struct {
    server: *AgentProtocolServer,
    pipe: *PipeTransport,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn pumpClientMessages(self: *Self) !void {
        var recv = self.pipe.serverReceiver();
        while (try recv.readLine(self.allocator)) |line| {
            defer self.allocator.free(line);

            var env = agent_envelope.deserializeEnvelope(line, self.allocator) catch |err| {
                if (fields.shouldAnswerDecodeError(err)) self.sendErrorForRejectedInput(line, fields.rejectionReason(err)) catch {};

                continue;
            };
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

    fn sendErrorForRejectedInput(self: *Self, raw_json: []const u8, reason: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw_json, .{}) catch return;
        defer parsed.deinit();

        const obj = fields.rootObject(parsed.value) catch return;

        const session_id = blk: {
            const text = (fields.optionalString(obj, "session_id") catch break :blk null) orelse break :blk null;
            break :blk agent_types.parseSessionId(text);
        } orelse agent_types.PLACEHOLDER_SESSION_ID;

        const in_reply_to = blk: {
            const text = (fields.optionalString(obj, "message_id") catch break :blk null) orelse break :blk null;
            break :blk agent_types.parseUlid(text);
        } orelse std.mem.zeroes(agent_types.Ulid);

        var env = agent_types.Envelope{
            .session_id = session_id,
            .message_id = agent_types.generateUlid(),
            .sequence = 0,
            .in_reply_to = in_reply_to,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .agent_error = .{
                .code = .invalid_request,
                .message = try self.allocator.dupe(u8, reason),
            } },
        };
        defer env.deinit(self.allocator);

        const json = try agent_envelope.serializeEnvelope(env, self.allocator);
        defer self.allocator.free(json);

        var sender = self.pipe.serverSender();
        try sender.write(json);
        try sender.flush();
    }

    pub fn pumpServerOutbox(self: *Self) !usize {
        var count: usize = 0;
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
            try std.testing.expect(server.peekOutbound() != null);
        }
    }

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

test "AgentProtocolRuntime answers malformed inbound envelopes with agent_error" {
    const allocator = std.testing.allocator;

    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    var pipe = PipeTransport.init(allocator);
    defer pipe.deinit();

    const malformed = [_][]const u8{
        \\{"type":"agent_message","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"version":1,"payload":{}}
        ,
        \\{"type":"agent_message","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":"1","timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"agent_start","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":[]}
        ,
        \\{"type":"agent_message","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"agent_message","session_id":"not a session id","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"agent_message","session_id":7,"message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
    };

    for (malformed) |line| {
        var sender = pipe.clientSender();
        try sender.write(line);
        try sender.flush();

        var runtime = AgentProtocolRuntime{
            .server = &server,
            .pipe = &pipe,
            .allocator = allocator,
        };
        try runtime.pumpClientMessages();

        var recv = pipe.clientReceiver();
        const reply = (try recv.readLine(allocator)) orelse return error.NoAgentErrorEmitted;
        defer allocator.free(reply);

        var parsed = try agent_envelope.deserializeEnvelope(reply, allocator);
        defer parsed.deinit(allocator);
        try std.testing.expect(parsed.payload == .agent_error);
        try std.testing.expectEqual(agent_types.AgentErrorCode.invalid_request, parsed.payload.agent_error.code);
        try std.testing.expectEqual(@as(u64, 0), parsed.sequence);
        try std.testing.expect(agent_types.parseSessionId(&parsed.session_id) != null);
    }

    try std.testing.expectEqual(@as(usize, 0), server.sessionCount());
}
