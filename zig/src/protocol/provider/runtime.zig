const std = @import("std");
const protocol_server = @import("protocol_server");
const protocol_client = @import("protocol_client");
const envelope = @import("protocol_envelope");
const in_process = @import("transports/in_process");

const ProtocolServer = protocol_server.ProtocolServer;
const ProtocolClient = protocol_client.ProtocolClient;
const protocol_types = envelope.protocol_types;
const PipeTransport = in_process.SerializedPipe;

/// Runtime pump for provider protocol client/server message forwarding.
///
/// This is the production counterpart of the old test-only protocol pump helper.
pub const ProviderProtocolRuntime = struct {
    server: *ProtocolServer,
    pipe: *PipeTransport,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Forward events from all active provider streams to the client.
    /// Returns number of envelopes sent.
    pub fn pumpProviderEvents(self: *Self) !usize {
        var events_forwarded: usize = 0;

        var iter = self.server.activeStreamIterator();
        while (iter.next()) |entry| {
            const active_stream = entry.stream;
            const stream_id = entry.stream_id;

            // Forward all pending stream events first.
            while (active_stream.event_stream.poll()) |event| {
                const seq = self.server.getNextSequence(stream_id);
                const env = protocol_types.Envelope{
                    .stream_id = stream_id,
                    .message_id = protocol_types.generateUuid(),
                    .sequence = seq,
                    .timestamp = std.time.milliTimestamp(),
                    .payload = .{ .event = event },
                };

                const json = try envelope.serializeEnvelope(env, self.allocator);
                defer self.allocator.free(json);

                var sender = self.pipe.serverSender();
                try sender.write(json);
                try sender.flush();

                events_forwarded += 1;
            }

            // If stream finished, forward terminal result/error envelope.
            if (active_stream.event_stream.isDone()) {
                if (active_stream.event_stream.getResult()) |result| {
                    const seq = self.server.getNextSequence(stream_id);
                    const env = protocol_types.Envelope{
                        .stream_id = stream_id,
                        .message_id = protocol_types.generateUuid(),
                        .sequence = seq,
                        .timestamp = std.time.milliTimestamp(),
                        .payload = .{ .result = result },
                    };

                    const json = try envelope.serializeEnvelope(env, self.allocator);
                    defer self.allocator.free(json);

                    var sender = self.pipe.serverSender();
                    try sender.write(json);
                    try sender.flush();
                } else if (active_stream.event_stream.getError()) |err_msg| {
                    const seq = self.server.getNextSequence(stream_id);
                    const err_copy = try self.allocator.dupe(u8, err_msg);
                    var env = protocol_types.Envelope{
                        .stream_id = stream_id,
                        .message_id = protocol_types.generateUuid(),
                        .sequence = seq,
                        .timestamp = std.time.milliTimestamp(),
                        .payload = .{ .stream_error = .{
                            .code = .provider_error,
                            .message = protocol_types.OwnedSlice(u8).initOwned(err_copy),
                        } },
                    };
                    defer env.deinit(self.allocator);

                    const json = try envelope.serializeEnvelope(env, self.allocator);
                    defer self.allocator.free(json);

                    var sender = self.pipe.serverSender();
                    try sender.write(json);
                    try sender.flush();
                }
            }
        }

        return events_forwarded;
    }

    /// Process pending client->server envelopes and write server replies.
    pub fn pumpClientMessages(self: *Self) !void {
        var receiver = self.pipe.serverReceiver();
        while (try receiver.readLine(self.allocator)) |line| {
            defer self.allocator.free(line);

            var env = envelope.deserializeEnvelope(line, self.allocator) catch continue;
            defer env.deinit(self.allocator);

            if (try self.server.handleEnvelope(env)) |response| {
                var mut_response = response;
                defer mut_response.deinit(self.allocator);

                const json = try envelope.serializeEnvelope(mut_response, self.allocator);
                defer self.allocator.free(json);

                var sender = self.pipe.serverSender();
                try sender.write(json);
                try sender.flush();
            }
        }
    }

    /// Process pending server->client envelopes through ProtocolClient.
    pub fn pumpServerMessagesIntoClient(self: *Self, client: *ProtocolClient) !void {
        var receiver = self.pipe.clientReceiver();
        while (try receiver.readLine(self.allocator)) |line| {
            defer self.allocator.free(line);

            var env = envelope.deserializeEnvelope(line, self.allocator) catch continue;
            defer env.deinit(self.allocator);

            try client.processEnvelope(env);
        }
    }

    /// Run one full pump iteration:
    /// client->server, provider events->client, server->client processing.
    pub fn pumpOnce(self: *Self, client: *ProtocolClient) !usize {
        try self.pumpClientMessages();
        const forwarded = try self.pumpProviderEvents();
        try self.pumpServerMessagesIntoClient(client);
        return forwarded;
    }
};

test "ProviderProtocolRuntime type is available" {
    _ = ProviderProtocolRuntime;
}
