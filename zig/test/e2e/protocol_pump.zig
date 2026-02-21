//! Protocol Pump - Helper for protocol fullstack E2E tests
//!
//! This module provides the ProtocolPump helper that forwards events from
//! provider streams to clients via the protocol layer in test environments.

const std = @import("std");
const protocol_server = @import("protocol_server");
const envelope = @import("envelope");
const in_process = @import("transports/in_process");

const ProtocolServer = protocol_server.ProtocolServer;
const protocol_types = envelope.protocol_types;
const PipeTransport = in_process.SerializedPipe;

/// Protocol pump that forwards events from provider stream to client via protocol layer
pub const ProtocolPump = struct {
    server: *ProtocolServer,
    pipe: *PipeTransport,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Forward events from all active streams to the client
    /// Returns number of events forwarded
    pub fn pumpEvents(self: *Self) !usize {
        var events_forwarded: usize = 0;

        // Get the server's active streams using the public iterator
        var iter = self.server.activeStreamIterator();
        while (iter.next()) |entry| {
            const active_stream = entry.stream;
            const stream_id = entry.stream_id;

            // Poll ALL available events from the provider's event stream
            // before checking if the stream is done
            while (active_stream.event_stream.poll()) |event| {
                const seq = self.server.getNextSequence(stream_id);
                const env = protocol_types.Envelope{
                    .stream_id = stream_id,
                    .message_id = protocol_types.generateUuid(),
                    .sequence = seq,
                    .timestamp = std.time.milliTimestamp(),
                    .payload = .{ .event = event },
                };
                // NOTE: Do NOT call env.deinit() - event payloads have borrowed strings
                // from the provider's internal buffer that will be freed when the stream deinit

                // Serialize and send to client
                const json = try envelope.serializeEnvelope(env, self.allocator);
                defer self.allocator.free(json);

                var sender = self.pipe.serverSender();
                try sender.write(json);
                try sender.flush();

                events_forwarded += 1;
            }

            // Check if stream is done (only after polling all events)
            if (active_stream.event_stream.isDone()) {
                // Send result or error to client
                if (active_stream.event_stream.getResult()) |result| {
                    const seq = self.server.getNextSequence(stream_id);
                    const env = protocol_types.Envelope{
                        .stream_id = stream_id,
                        .message_id = protocol_types.generateUuid(),
                        .sequence = seq,
                        .timestamp = std.time.milliTimestamp(),
                        .payload = .{ .result = result },
                    };
                    // NOTE: Do NOT call env.deinit() - result payloads have borrowed strings
                    // from the provider's internal buffer that will be freed when the stream deinit

                    const json = try envelope.serializeEnvelope(env, self.allocator);
                    defer self.allocator.free(json);

                    var sender = self.pipe.serverSender();
                    try sender.write(json);
                    try sender.flush();
                } else if (active_stream.event_stream.getError()) |err_msg| {
                    // Stream completed with error - send stream_error to client
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

                    const json = try envelope.serializeEnvelope(env, self.allocator);
                    defer self.allocator.free(json);

                    var sender = self.pipe.serverSender();
                    try sender.write(json);
                    try sender.flush();

                    // Free the error envelope's allocated memory
                    env.deinit(self.allocator);
                }
            }
        }

        return events_forwarded;
    }

    /// Process any pending messages from client to server
    pub fn pumpClientMessages(self: *Self) !void {
        var receiver = self.pipe.serverReceiver();
        while (try receiver.readLine(self.allocator)) |line| {
            defer self.allocator.free(line);

            var env = envelope.deserializeEnvelope(line, self.allocator) catch continue;
            defer env.deinit(self.allocator);

            // Process through server
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

/// Helper to get env var or return null
pub fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}
