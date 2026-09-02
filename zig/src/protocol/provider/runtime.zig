const std = @import("std");
const compat = @import("compat");
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
    next_stream_offset: usize = 0,

    const Self = @This();

    /// Forward events from all active provider streams to the client.
    /// Returns number of envelopes sent.
    pub fn pumpProviderEvents(self: *Self) !usize {
        return self.pumpProviderEventsLimited(std.math.maxInt(usize), null);
    }

    fn pumpProviderEventsLimited(self: *Self, max_events: usize, client: ?*ProtocolClient) !usize {
        if (max_events == 0) return 0;
        var events_forwarded: usize = 0;
        const active_stream_count = self.server.activeStreamCount();
        if (active_stream_count == 0) return 0;
        // Reserve a share for every active stream so one hot producer cannot
        // monopolize the downstream queue on every pump iteration.
        const per_stream_limit = @max(@as(usize, 1), max_events / active_stream_count);

        const start_offset = self.next_stream_offset % active_stream_count;
        var iter = self.server.activeStreamIterator();
        for (0..start_offset) |_| _ = iter.next();
        var streams_visited: usize = 0;

        while (streams_visited < active_stream_count) {
            const entry = iter.next() orelse blk: {
                iter = self.server.activeStreamIterator();
                break :blk iter.next() orelse break;
            };
            streams_visited += 1;
            const stream_capacity = if (client) |destination|
                destination.eventDeliveryCapacityFor(entry.stream_id)
            else
                max_events - events_forwarded;
            events_forwarded += try self.forwardStreamShare(entry, per_stream_limit, @min(max_events - events_forwarded, stream_capacity), true);
            if (client) |destination| try self.pumpServerMessagesIntoClient(destination);
            if (events_forwarded == max_events) break;
        }

        self.next_stream_offset = (start_offset + streams_visited) % active_stream_count;

        // The first pass guarantees every stream its fair share. Revisit the
        // streams afterward so busy producers can use capacity left behind by
        // idle streams instead of waiting for another pump iteration.
        if (events_forwarded < max_events) {
            iter = self.server.activeStreamIterator();
            for (0..start_offset) |_| _ = iter.next();
            streams_visited = 0;
            while (streams_visited < active_stream_count) {
                const entry = iter.next() orelse blk: {
                    iter = self.server.activeStreamIterator();
                    break :blk iter.next() orelse break;
                };
                streams_visited += 1;
                const stream_capacity = if (client) |destination|
                    destination.eventDeliveryCapacityFor(entry.stream_id)
                else
                    max_events - events_forwarded;
                events_forwarded += try self.forwardStreamShare(
                    entry,
                    max_events - events_forwarded,
                    @min(max_events - events_forwarded, stream_capacity),
                    false,
                );
                if (client) |destination| try self.pumpServerMessagesIntoClient(destination);
                if (events_forwarded == max_events) break;
            }
        }

        return events_forwarded;
    }

    fn forwardStreamShare(
        self: *Self,
        entry: anytype,
        per_stream_limit: usize,
        remaining_events: usize,
        allow_terminal: bool,
    ) !usize {
        const active_stream = entry.stream;
        const stream_id = entry.stream_id;
        const event_limit = @min(per_stream_limit, remaining_events);
        var stream_events_forwarded: usize = 0;

        // Forward pending stream events first.
        while (stream_events_forwarded < event_limit) {
            const event = active_stream.event_stream.poll() orelse break;
            var event_cleanup = event;
            defer if (active_stream.event_stream.owns_events) {
                protocol_types.deinitEvent(self.allocator, &event_cleanup);
            };

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

            stream_events_forwarded += 1;
        }

        // If stream finished, forward terminal result/error envelope.
        if (allow_terminal and
            stream_events_forwarded < remaining_events and
            !active_stream.event_stream.hasPending() and
            active_stream.event_stream.isDone())
        {
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
                stream_events_forwarded += 1;
            } else if (active_stream.event_stream.getError()) |err_msg| {
                const seq = self.server.getNextSequence(stream_id);
                const err_copy = try self.allocator.dupe(u8, err_msg);
                var env = protocol_types.Envelope{
                    .stream_id = stream_id,
                    .message_id = protocol_types.generateUlid(),
                    .sequence = seq,
                    .timestamp = compat.time.nowMillis(),
                    .payload = .{ .stream_error = .{
                        .code = protocol_server.streamErrorCode(err_msg),
                        .message = protocol_types.OwnedSlice(u8).initOwned(err_copy),
                    } },
                };
                defer env.deinit(self.allocator);

                const json = try envelope.serializeEnvelope(env, self.allocator);
                defer self.allocator.free(json);

                var sender = self.pipe.serverSender();
                try sender.write(json);
                try sender.flush();
                stream_events_forwarded += 1;
            }
        }

        return stream_events_forwarded;
    }

    /// Process pending client->server envelopes and write server replies.
    pub fn pumpClientMessages(self: *Self) !void {
        var receiver = self.pipe.serverReceiver();
        while (try receiver.readLine(self.allocator)) |line| {
            defer self.allocator.free(line);

            var env = envelope.deserializeEnvelope(line, self.allocator) catch |err| {
                if (err == error.InputTooLong) {
                    self.sendNackForOversizedInput(line) catch {};
                }
                continue;
            };
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

    /// Attempt to send a NACK for an oversized envelope that failed deserialization.
    /// Best-effort: extracts stream_id/message_id from raw JSON to construct the NACK.
    /// If parsing fails, silently skips — the client will time out regardless.
    fn sendNackForOversizedInput(self: *Self, raw_json: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw_json, .{}) catch return;
        defer parsed.deinit();

        const obj = parsed.value.object;

        const stream_id_str = obj.get("stream_id") orelse return;
        if (stream_id_str != .string) return;
        const stream_id = protocol_types.parseUlid(stream_id_str.string) orelse return;

        const message_id_str = obj.get("message_id") orelse return;
        if (message_id_str != .string) return;
        const message_id = protocol_types.parseUlid(message_id_str.string) orelse return;

        // Construct a minimal envelope for the NACK
        const dummy_envelope = protocol_types.Envelope{
            .stream_id = stream_id,
            .message_id = message_id,
            .sequence = 0,
            .timestamp = compat.time.nowMillis(),
            .payload = .ping,
        };

        const nack = try envelope.createNack(
            dummy_envelope,
            "input field exceeds maximum allowed length",
            .invalid_request,
            self.allocator,
        );
        var mut_nack = nack;
        defer mut_nack.deinit(self.allocator);

        const json = try envelope.serializeEnvelope(mut_nack, self.allocator);
        defer self.allocator.free(json);

        var sender = self.pipe.serverSender();
        try sender.write(json);
        try sender.flush();
    }

    pub fn pumpServerOutbox(self: *Self) !usize {
        var count: usize = 0;
        while (self.server.popOutbound()) |outbound| {
            var env = outbound;
            defer env.deinit(self.allocator);

            const json = try envelope.serializeEnvelope(env, self.allocator);
            defer self.allocator.free(json);

            var sender = self.pipe.serverSender();
            try sender.write(json);
            try sender.flush();
            count += 1;
        }
        return count;
    }

    /// Process pending server->client envelopes through ProtocolClient.
    pub fn pumpServerMessagesIntoClient(self: *Self, client: *ProtocolClient) !void {
        var receiver = self.pipe.clientReceiver();
        // Stop before the destination queue fills so the caller can drain it and
        // resume pumping. Reading the entire buffered burst here would otherwise
        // turn normal consumer backpressure into EventStream.QueueFull.
        while (client.eventDeliveryCapacity() > 0) {
            const line = try receiver.readLine(self.allocator) orelse break;
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
        var forwarded = try self.pumpServerOutbox();
        // Consume existing serialized messages before forwarding more provider
        // events, then limit forwarding to what the selected client queue(s)
        // can accept. This carries backpressure across the serialization layer.
        try self.pumpServerMessagesIntoClient(client);
        forwarded += try self.pumpProviderEventsLimited(client.eventDeliveryCapacity(), client);
        try self.pumpServerMessagesIntoClient(client);
        return forwarded;
    }
};

test "ProviderProtocolRuntime type is available" {
    _ = ProviderProtocolRuntime;
}

test "server message pump backpressures global and per-stream delivery" {
    const allocator = std.testing.allocator;
    const stream_id = protocol_types.generateUlid();

    for ([_]ProtocolClient.Options.EventDelivery{ .global, .per_stream }) |delivery| {
        var pipe = in_process.createSerializedPipe(allocator);
        defer pipe.deinit();

        var client = ProtocolClient.init(allocator, .{ .event_delivery = delivery });
        defer client.deinit();

        var sender = pipe.serverSender();
        const stream_capacity = @TypeOf(client.getEventStream().*).usable_capacity;
        const event_count = stream_capacity + 1;
        for (0..event_count) |index| {
            const env = protocol_types.Envelope{
                .stream_id = stream_id,
                .message_id = protocol_types.generateUlid(),
                .sequence = index + 1,
                .timestamp = 0,
                .payload = .{ .event = .{ .keepalive = {} } },
            };
            const json = try envelope.serializeEnvelope(env, allocator);
            defer allocator.free(json);
            try sender.write(json);
        }

        var runtime = ProviderProtocolRuntime{
            .server = undefined,
            .pipe = &pipe,
            .allocator = allocator,
        };

        try runtime.pumpServerMessagesIntoClient(&client);
        try std.testing.expectEqual(@as(usize, 0), client.eventDeliveryCapacity());
        try std.testing.expect(pipe.to_client_read_pos < pipe.to_client.items.len);

        const destination = if (delivery == .global)
            client.getEventStream()
        else
            client.getEventStreamFor(stream_id).?;
        var drained: usize = 0;
        while (destination.poll()) |event_value| : (drained += 1) {
            try std.testing.expect(event_value == .keepalive);
        }
        try std.testing.expectEqual(stream_capacity, drained);

        try runtime.pumpServerMessagesIntoClient(&client);
        try std.testing.expectEqual(pipe.to_client.items.len, pipe.to_client_read_pos);
        const final_event = destination.poll().?;
        try std.testing.expect(final_event == .keepalive);
    }
}
