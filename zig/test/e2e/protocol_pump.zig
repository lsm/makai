
const std = @import("std");
const compat = @import("compat");
const protocol_server = @import("protocol_server");
const envelope = @import("envelope");
const in_process = @import("transports/in_process");

const ProtocolServer = protocol_server.ProtocolServer;
const protocol_types = envelope.protocol_types;
const PipeTransport = in_process.SerializedPipe;

pub const ProtocolPump = struct {
    server: *ProtocolServer,
    pipe: *PipeTransport,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn pumpEvents(self: *Self) !usize {
        var events_forwarded: usize = 0;

        var iter = self.server.activeStreamIterator();
        while (iter.next()) |entry| {
            const active_stream = entry.stream;
            const stream_id = entry.stream_id;

            while (active_stream.event_stream.poll()) |event| {
                const seq = self.server.getNextSequence(stream_id);
                const env = protocol_types.Envelope{
                    .stream_id = stream_id,
                    .message_id = protocol_types.generateUlid(),
                    .sequence = seq,
                    .timestamp = compat.time.nowMillis(),
                    .payload = .{ .event = event },
                };

                const json = try envelope.serializeEnvelope(env, self.allocator);
                defer self.allocator.free(json);

                var sender = self.pipe.serverSender();
                try sender.write(json);
                try sender.flush();

                events_forwarded += 1;
            }

            if (active_stream.event_stream.isDone()) {
                if (active_stream.event_stream.getResult()) |result| {
                    const seq = self.server.getNextSequence(stream_id);
                    const env = protocol_types.Envelope{
                        .stream_id = stream_id,
                        .message_id = protocol_types.generateUlid(),
                        .sequence = seq,
                        .timestamp = compat.time.nowMillis(),
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
                        .message_id = protocol_types.generateUlid(),
                        .sequence = seq,
                        .timestamp = compat.time.nowMillis(),
                        .payload = .{ .stream_error = .{
                            .code = .provider_error,
                            .message = protocol_types.OwnedSlice(u8).initOwned(err_copy),
                        } },
                    };

                    const json = try envelope.serializeEnvelope(env, self.allocator);
                    defer self.allocator.free(json);

                    var sender = self.pipe.serverSender();
                    try sender.write(json);
                    try sender.flush();

                    env.deinit(self.allocator);
                }
            }
        }

        return events_forwarded;
    }

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
};

pub fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return compat.getEnvVarOwned(allocator, name) catch null;
}
