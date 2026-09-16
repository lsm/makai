const std = @import("std");
const auth_server = @import("auth_server");
const auth_envelope = @import("auth_envelope");
const auth_types = @import("auth_types");
const compat = @import("compat");
const OwnedSlice = @import("owned_slice").OwnedSlice;
const in_process = @import("transports/in_process");

const AuthProtocolServer = auth_server.AuthProtocolServer;
const PipeTransport = in_process.SerializedPipe;

pub const AuthProtocolRuntime = struct {
    server: *AuthProtocolServer,
    pipe: *PipeTransport,
    allocator: std.mem.Allocator,

    const Self = @This();

    fn sendNackForUndecodableInput(self: *Self, raw_json: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw_json, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value != .object) return;
        const obj = parsed.value.object;

        const stream_value = obj.get("stream_id") orelse return;
        if (stream_value != .string) return;
        const stream_id = auth_types.parseUlid(stream_value.string) orelse return;

        const message_value = obj.get("message_id") orelse return;
        if (message_value != .string) return;
        const message_id = auth_types.parseUlid(message_value.string) orelse return;

        var env = auth_types.Envelope{
            .stream_id = stream_id,
            .message_id = auth_types.generateUlid(),
            .sequence = 0,
            .in_reply_to = message_id,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .nack = .{
                .rejected_id = message_id,
                .reason = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, "envelope could not be decoded")),
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

    pub fn pumpClientMessages(self: *Self) !void {
        var receiver = self.pipe.serverReceiver();
        while (try receiver.readLine(self.allocator)) |line| {
            defer self.allocator.free(line);

            var env = auth_envelope.deserializeEnvelope(line, self.allocator) catch {
                self.sendNackForUndecodableInput(line) catch {};
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
