const std = @import("std");
const tool_envelope = @import("tool_envelope");
const in_process = @import("transports/in_process");

const protocol_types = tool_envelope.protocol_types;
const PipeTransport = in_process.SerializedPipe;

pub const HandleClientEnvelopeFn = *const fn (
    ctx: ?*anyopaque,
    env: protocol_types.Envelope,
    allocator: std.mem.Allocator,
) anyerror!?protocol_types.Envelope;

pub const PopServerOutboundFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
) anyerror!?protocol_types.Envelope;

pub const ProcessServerEnvelopeFn = *const fn (
    ctx: ?*anyopaque,
    env: protocol_types.Envelope,
    allocator: std.mem.Allocator,
) anyerror!void;

pub const ToolProtocolRuntime = struct {
    pipe: *PipeTransport,
    allocator: std.mem.Allocator,
    server_ctx: ?*anyopaque,
    client_ctx: ?*anyopaque,
    handle_client_envelope_fn: HandleClientEnvelopeFn,
    process_server_envelope_fn: ProcessServerEnvelopeFn,
    pop_server_outbound_fn: ?PopServerOutboundFn = null,

    const Self = @This();

    pub fn pumpClientMessages(self: *Self) !void {
        var recv = self.pipe.serverReceiver();
        while (try recv.readLine(self.allocator)) |line| {
            defer self.allocator.free(line);

            var env = tool_envelope.deserializeEnvelope(line, self.allocator) catch continue;
            defer env.deinit(self.allocator);

            if (try self.handle_client_envelope_fn(self.server_ctx, env, self.allocator)) |response| {
                var out = response;
                defer out.deinit(self.allocator);

                const json = try tool_envelope.serializeEnvelope(out, self.allocator);
                defer self.allocator.free(json);

                var sender = self.pipe.serverSender();
                try sender.write(json);
                try sender.flush();
            }
        }
    }

    pub fn pumpServerOutbox(self: *Self) !usize {
        const pop = self.pop_server_outbound_fn orelse return 0;
        var count: usize = 0;

        while (try pop(self.server_ctx, self.allocator)) |outbound| {
            var env = outbound;
            defer env.deinit(self.allocator);

            const json = try tool_envelope.serializeEnvelope(env, self.allocator);
            defer self.allocator.free(json);

            var sender = self.pipe.serverSender();
            try sender.write(json);
            try sender.flush();
            count += 1;
        }

        return count;
    }

    pub fn pumpServerMessagesIntoClient(self: *Self) !void {
        var recv = self.pipe.clientReceiver();
        while (try recv.readLine(self.allocator)) |line| {
            defer self.allocator.free(line);

            var env = tool_envelope.deserializeEnvelope(line, self.allocator) catch continue;
            defer env.deinit(self.allocator);
            try self.process_server_envelope_fn(self.client_ctx, env, self.allocator);
        }
    }

    pub fn pumpOnce(self: *Self) !usize {
        try self.pumpClientMessages();
        const out_count = try self.pumpServerOutbox();
        try self.pumpServerMessagesIntoClient();
        return out_count;
    }
};

test "ToolProtocolRuntime pumps request, response, and outbox" {
    const allocator = std.testing.allocator;

    const MockServer = struct {
        responded: usize = 0,
        outbox_sent: bool = false,
    };

    const MockClient = struct {
        status_responses: usize = 0,
        stream_updates: usize = 0,
    };

    const callbacks = struct {
        fn handleClientEnvelope(ctx: ?*anyopaque, env: protocol_types.Envelope, test_allocator: std.mem.Allocator) !?protocol_types.Envelope {
            const server: *MockServer = @ptrCast(@alignCast(ctx.?));
            if (env.payload != .tool_status) return null;
            server.responded += 1;

            return protocol_types.Envelope{
                .server_id = env.server_id,
                .message_id = protocol_types.generateUuid(),
                .sequence = env.sequence + 1,
                .in_reply_to = env.message_id,
                .timestamp = std.time.milliTimestamp(),
                .payload = .{ .tool_status_response = .{
                    .execution_id = env.payload.tool_status.execution_id,
                    .tool_name = try test_allocator.dupe(u8, "grep"),
                    .status = .running,
                    .started_at = std.time.milliTimestamp(),
                    .completed_at = null,
                } },
            };
        }

        fn popServerOutbound(ctx: ?*anyopaque, test_allocator: std.mem.Allocator) !?protocol_types.Envelope {
            const server: *MockServer = @ptrCast(@alignCast(ctx.?));
            if (server.outbox_sent) return null;
            server.outbox_sent = true;

            return protocol_types.Envelope{
                .server_id = protocol_types.generateUuid(),
                .message_id = protocol_types.generateUuid(),
                .sequence = 99,
                .timestamp = std.time.milliTimestamp(),
                .payload = .{ .tool_stream = .{
                    .execution_id = protocol_types.generateUuid(),
                    .tool_call_id = try test_allocator.dupe(u8, "call_1"),
                    .partial_result_json = try test_allocator.dupe(u8, "{\"progress\":50}"),
                    .progress = 50,
                } },
            };
        }

        fn processServerEnvelope(ctx: ?*anyopaque, env: protocol_types.Envelope, test_allocator: std.mem.Allocator) !void {
            _ = test_allocator;
            const client: *MockClient = @ptrCast(@alignCast(ctx.?));
            switch (env.payload) {
                .tool_status_response => client.status_responses += 1,
                .tool_stream => client.stream_updates += 1,
                else => {},
            }
        }
    };

    var pipe = PipeTransport.init(allocator);
    defer pipe.deinit();

    var server = MockServer{};
    var client = MockClient{};

    var runtime = ToolProtocolRuntime{
        .pipe = &pipe,
        .allocator = allocator,
        .server_ctx = &server,
        .client_ctx = &client,
        .handle_client_envelope_fn = callbacks.handleClientEnvelope,
        .process_server_envelope_fn = callbacks.processServerEnvelope,
        .pop_server_outbound_fn = callbacks.popServerOutbound,
    };

    const request = protocol_types.Envelope{
        .server_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .tool_status = .{
            .execution_id = protocol_types.generateUuid(),
        } },
    };
    const request_json = try tool_envelope.serializeEnvelope(request, allocator);
    defer allocator.free(request_json);

    var sender = pipe.clientSender();
    try sender.write(request_json);
    try sender.flush();

    const out_count = try runtime.pumpOnce();
    try std.testing.expectEqual(@as(usize, 1), out_count);
    try std.testing.expectEqual(@as(usize, 1), server.responded);
    try std.testing.expectEqual(@as(usize, 1), client.status_responses);
    try std.testing.expectEqual(@as(usize, 1), client.stream_updates);
}
