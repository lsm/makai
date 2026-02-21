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
        while (self.server.popOutbound()) |outbound| {
            var env = outbound;
            defer env.deinit(self.allocator);

            const json = try agent_envelope.serializeEnvelope(env, self.allocator);
            defer self.allocator.free(json);

            var sender = self.pipe.serverSender();
            try sender.write(json);
            try sender.flush();
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
    try std.testing.expectEqualStrings("{\"type\":\"message\"}", ev.slice());
    try std.testing.expectEqualStrings("{\"messages\":[]}", client.getLastResultJson().?);
}
