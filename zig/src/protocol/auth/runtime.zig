const std = @import("std");
const auth_server = @import("auth_server");
const auth_envelope = @import("auth_envelope");
const in_process = @import("transports/in_process");
const compat = @import("compat");
const fields = @import("envelope_fields");

const AuthProtocolServer = auth_server.AuthProtocolServer;
const PipeTransport = in_process.SerializedPipe;
const auth_types = auth_envelope.protocol_types;

fn ulidFieldOrZero(obj: std.json.ObjectMap, field: []const u8) auth_types.Ulid {
    const value = fields.optionalString(obj, field) catch return std.mem.zeroes(auth_types.Ulid);
    const text = value orelse return std.mem.zeroes(auth_types.Ulid);
    return auth_types.parseUlid(text) orelse std.mem.zeroes(auth_types.Ulid);
}

pub const AuthProtocolRuntime = struct {
    server: *AuthProtocolServer,
    pipe: *PipeTransport,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn pumpClientMessages(self: *Self) !void {
        var receiver = self.pipe.serverReceiver();
        while (try receiver.readLine(self.allocator)) |line| {
            defer self.allocator.free(line);

            var env = auth_envelope.deserializeEnvelope(line, self.allocator) catch |err| {
                if (fields.shouldAnswerDecodeError(err)) self.sendNackForRejectedInput(line, fields.rejectionReason(err)) catch {};

                continue;
            };
            defer env.deinit(self.allocator);

            if (try self.server.handleEnvelope(env)) |response| {
                var out = response;
                defer out.deinit(self.allocator);

                const json = try auth_envelope.serializeEnvelope(out, self.allocator);
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
        const rejected_id = ulidFieldOrZero(obj, "message_id");

        var env = auth_types.Envelope{
            .stream_id = stream_id,
            .message_id = auth_types.generateUlid(),
            .sequence = 0,
            .in_reply_to = rejected_id,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .nack = .{
                .rejected_id = rejected_id,
                .reason = auth_types.OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, reason)),
                .error_code = .invalid_request,
            } },
        };
        defer env.deinit(self.allocator);

        const json = try auth_envelope.serializeEnvelope(env, self.allocator);
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

            const json = try auth_envelope.serializeEnvelope(env, self.allocator);
            defer self.allocator.free(json);

            var sender = self.pipe.serverSender();
            try sender.write(json);
            try sender.flush();
            count += 1;
        }
        return count;
    }
};

test "AuthProtocolRuntime type is available" {
    _ = AuthProtocolRuntime;
}

test "AuthProtocolRuntime answers malformed inbound envelopes with a nack" {
    const allocator = std.testing.allocator;

    var server = AuthProtocolServer.init(allocator, .{});
    defer server.deinit();

    var pipe = PipeTransport.init(allocator);
    defer pipe.deinit();

    const malformed = [_][]const u8{
        \\{"type":"auth_login_start","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"version":1,"payload":{"provider_id":"anthropic"}}
        ,
        \\{"type":"auth_login_start","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"auth_login_start","stream_id":"not-a-ulid","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"provider_id":"anthropic"}}
        ,
    };

    for (malformed) |line| {
        var sender = pipe.clientSender();
        try sender.write(line);
        try sender.flush();

        var runtime = AuthProtocolRuntime{
            .server = &server,
            .pipe = &pipe,
            .allocator = allocator,
        };
        try runtime.pumpClientMessages();

        var recv = pipe.clientReceiver();
        const reply = (try recv.readLine(allocator)) orelse return error.NoNackEmitted;
        defer allocator.free(reply);

        var parsed = try auth_envelope.deserializeEnvelope(reply, allocator);
        defer parsed.deinit(allocator);
        try std.testing.expect(parsed.payload == .nack);
        try std.testing.expect(parsed.payload.nack.reason.slice().len > 0);
    }
}
