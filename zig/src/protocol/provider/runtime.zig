const std = @import("std");
const compat = @import("compat");
const protocol_server = @import("protocol_server");
const protocol_client = @import("protocol_client");
const envelope = @import("protocol_envelope");
const api_registry = @import("api_registry");
const fields = @import("envelope_fields");
const in_process = @import("transports/in_process");

const ProtocolServer = protocol_server.ProtocolServer;
const ProtocolClient = protocol_client.ProtocolClient;
const protocol_types = envelope.protocol_types;
const PipeTransport = in_process.SerializedPipe;

fn ulidFieldOrZero(obj: std.json.ObjectMap, field: []const u8) protocol_types.Ulid {
    const value = fields.optionalString(obj, field) catch return std.mem.zeroes(protocol_types.Ulid);
    const text = value orelse return std.mem.zeroes(protocol_types.Ulid);
    return protocol_types.parseUlid(text) orelse std.mem.zeroes(protocol_types.Ulid);
}

pub const ProviderProtocolRuntime = struct {
    server: *ProtocolServer,
    pipe: *PipeTransport,
    allocator: std.mem.Allocator,
    next_stream_offset: usize = 0,

    const Self = @This();

    pub fn pumpProviderEvents(self: *Self) !usize {
        return self.pumpProviderEventsLimited(std.math.maxInt(usize), null);
    }

    fn pumpProviderEventsLimited(self: *Self, max_events: usize, client: ?*ProtocolClient) !usize {
        if (max_events == 0) return 0;
        var events_forwarded: usize = 0;
        const active_stream_count = self.server.activeStreamCount();
        if (active_stream_count == 0) return 0;
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

    pub fn pumpClientMessages(self: *Self) !void {
        var receiver = self.pipe.serverReceiver();
        while (try receiver.readLine(self.allocator)) |line| {
            defer self.allocator.free(line);

            var env = envelope.deserializeEnvelope(line, self.allocator) catch |err| {
                if (fields.shouldAnswerDecodeError(err)) self.sendNackForRejectedInput(line, fields.rejectionReason(err)) catch {};

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

    fn sendNackForRejectedInput(self: *Self, raw_json: []const u8, reason: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw_json, .{}) catch return;
        defer parsed.deinit();

        const obj = fields.rootObject(parsed.value) catch return;

        const stream_id = ulidFieldOrZero(obj, "stream_id");
        const message_id = ulidFieldOrZero(obj, "message_id");

        const dummy_envelope = protocol_types.Envelope{
            .stream_id = stream_id,
            .message_id = message_id,
            .sequence = 0,
            .timestamp = compat.time.nowMillis(),
            .payload = .ping,
        };

        const nack = try envelope.createNack(
            dummy_envelope,
            reason,
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

    pub fn pumpServerMessagesIntoClient(self: *Self, client: *ProtocolClient) !void {
        var receiver = self.pipe.clientReceiver();
        while (client.eventDeliveryCapacity() > 0) {
            const line = try receiver.readLine(self.allocator) orelse break;
            defer self.allocator.free(line);

            var env = envelope.deserializeEnvelope(line, self.allocator) catch continue;
            defer env.deinit(self.allocator);

            try client.processEnvelope(env);
        }
    }

    pub fn pumpOnce(self: *Self, client: *ProtocolClient) !usize {
        try self.pumpClientMessages();
        var forwarded = try self.pumpServerOutbox();
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

fn readServerReply(pipe: *PipeTransport, allocator: std.mem.Allocator) !?[]const u8 {
    var receiver = pipe.clientReceiver();
    return receiver.readLine(allocator);
}

test "provider runtime nacks malformed inbound envelopes instead of dropping them" {
    const allocator = std.testing.allocator;
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(allocator, &registry, .{});
    defer server.deinit();

    var pipe = in_process.createSerializedPipe(allocator);
    defer pipe.deinit();

    const malformed = [_][]const u8{
        \\{"type":"complete_request","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"version":1,"payload":{"model":{"base_url":"","id":"m","provider":"anthropic","api":"anthropic-messages","name":"m"},"context":{"messages":[{"role":"user","content":"hi"}]}}}
        ,
        \\{"type":"complete_request","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"context":{"messages":[]}}}
        ,
        \\{"type":"complete_request","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":"1","timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","stream_id":"not-a-ulid","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
    };

    for (malformed) |line| {
        var client_sender = pipe.clientSender();
        try client_sender.write(line);
        try client_sender.flush();

        var runtime = ProviderProtocolRuntime{
            .server = &server,
            .pipe = &pipe,
            .allocator = allocator,
        };
        try runtime.pumpClientMessages();

        const reply = (try readServerReply(&pipe, allocator)) orelse return error.NoNackEmitted;
        defer allocator.free(reply);

        var parsed = try envelope.deserializeEnvelope(reply, allocator);
        defer parsed.deinit(allocator);
        try std.testing.expect(parsed.payload == .nack);
        try std.testing.expectEqual(protocol_types.ErrorCode.invalid_request, parsed.payload.nack.error_code.?);
        try std.testing.expect(parsed.payload.nack.reason.slice().len > 0);
    }

    try std.testing.expectEqual(@as(usize, 0), server.active_streams.count());
}

test "provider runtime keeps serving well-formed envelopes after a malformed one" {
    const allocator = std.testing.allocator;
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(allocator, &registry, .{});
    defer server.deinit();

    var pipe = in_process.createSerializedPipe(allocator);
    defer pipe.deinit();

    const bad =
        \\{"type":"complete_request","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"version":1,"payload":{}}
    ;
    const good_ping =
        \\{"type":"ping","stream_id":"01M2MYK69FX2M3DY769FEHK3M2","message_id":"01M2MYK69FX2M3DY769FEHK3M3","sequence":1,"timestamp":1,"version":1,"payload":{}}
    ;

    var client_sender = pipe.clientSender();
    try client_sender.write(bad);
    try client_sender.write(good_ping);
    try client_sender.flush();

    var runtime = ProviderProtocolRuntime{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };
    try runtime.pumpClientMessages();

    const first = (try readServerReply(&pipe, allocator)) orelse return error.NoNackEmitted;
    defer allocator.free(first);
    var nack = try envelope.deserializeEnvelope(first, allocator);
    defer nack.deinit(allocator);
    try std.testing.expect(nack.payload == .nack);

    const second = (try readServerReply(&pipe, allocator)) orelse return error.NoPongEmitted;
    defer allocator.free(second);
    var pong = try envelope.deserializeEnvelope(second, allocator);
    defer pong.deinit(allocator);
    try std.testing.expect(pong.payload == .pong);
}

test "provider runtime stays silent on a well-formed envelope with an unrecognized type" {
    const allocator = std.testing.allocator;
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(allocator, &registry, .{});
    defer server.deinit();

    var pipe = in_process.createSerializedPipe(allocator);
    defer pipe.deinit();

    const unknown_type =
        \\{"type":"definitely_not_a_real_envelope","stream_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
    ;

    var client_sender = pipe.clientSender();
    try client_sender.write(unknown_type);
    try client_sender.flush();

    var runtime = ProviderProtocolRuntime{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };
    try runtime.pumpClientMessages();

    const reply = try readServerReply(&pipe, allocator);
    if (reply) |line| {
        defer allocator.free(line);
        return error.UnexpectedReplyToUnknownType;
    }
}
