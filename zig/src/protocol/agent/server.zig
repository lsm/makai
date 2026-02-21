const std = @import("std");
const agent_types = @import("agent_types");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const SessionState = struct {
    session_id: agent_types.Uuid,
    status: agent_types.AgentStatus,
    model: []const u8,
    message_count: u32,
    created_at: i64,
    updated_at: i64,
};

pub const AgentProtocolServer = struct {
    allocator: std.mem.Allocator,
    sessions: std.AutoHashMap(agent_types.Uuid, SessionState),
    expected_sequences: std.AutoHashMap(agent_types.Uuid, u64),
    outgoing_sequences: std.AutoHashMap(agent_types.Uuid, u64),
    outbox: std.ArrayList(agent_types.Envelope),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .sessions = std.AutoHashMap(agent_types.Uuid, SessionState).init(allocator),
            .expected_sequences = std.AutoHashMap(agent_types.Uuid, u64).init(allocator),
            .outgoing_sequences = std.AutoHashMap(agent_types.Uuid, u64).init(allocator),
            .outbox = std.ArrayList(agent_types.Envelope){},
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.model);
        }
        self.sessions.deinit();
        self.expected_sequences.deinit();
        self.outgoing_sequences.deinit();

        for (self.outbox.items) |*env| env.deinit(self.allocator);
        self.outbox.deinit(self.allocator);

        self.* = undefined;
    }

    pub fn sessionCount(self: *Self) usize {
        return self.sessions.count();
    }

    pub fn handleEnvelope(self: *Self, env: agent_types.Envelope) !?agent_types.Envelope {
        switch (env.payload) {
            .agent_start => |req| return try self.handleStart(req, env),
            .agent_message => |req| return try self.handleMessage(req, env),
            .agent_stop => |req| return try self.handleStop(req, env),
            .agent_status => |req| return try self.handleStatus(req, env),
            .tool_list => |_| {
                return .{
                    .session_id = env.session_id,
                    .message_id = agent_types.generateUuid(),
                    .sequence = env.sequence,
                    .in_reply_to = env.message_id,
                    .timestamp = std.time.milliTimestamp(),
                    .payload = .{ .tool_list_response = .{ .tools = &.{} } },
                };
            },
            .ping => {
                const ping_id = try agent_types.uuidToString(env.message_id, self.allocator);
                return .{
                    .session_id = env.session_id,
                    .message_id = agent_types.generateUuid(),
                    .sequence = env.sequence,
                    .in_reply_to = env.message_id,
                    .timestamp = std.time.milliTimestamp(),
                    .payload = .{ .pong = .{ .ping_id = OwnedSlice(u8).initOwned(ping_id) } },
                };
            },
            .goodbye => return null,
            else => {
                return try self.makeError(env.session_id, env.message_id, .invalid_request, "invalid payload for server");
            },
        }
    }

    fn handleStart(self: *Self, req: agent_types.AgentStartRequest, env: agent_types.Envelope) !?agent_types.Envelope {
        if (env.sequence != 1) {
            return try self.makeError(env.session_id, env.message_id, .invalid_request, "agent_start sequence must be 1");
        }

        const session_id = req.session_id orelse agent_types.generateUuid();
        if (self.sessions.contains(session_id)) {
            return try self.makeError(env.session_id, env.message_id, .agent_busy, "session already exists");
        }

        const now = std.time.milliTimestamp();
        try self.sessions.put(session_id, .{
            .session_id = session_id,
            .status = .ready,
            .model = try self.allocator.dupe(u8, "unknown"),
            .message_count = 0,
            .created_at = now,
            .updated_at = now,
        });
        try self.expected_sequences.put(session_id, 2);
        try self.outgoing_sequences.put(session_id, 0);

        return .{
            .session_id = session_id,
            .message_id = agent_types.generateUuid(),
            .sequence = self.nextOutgoingSequence(session_id),
            .in_reply_to = env.message_id,
            .timestamp = now,
            .payload = .{ .agent_started = .{ .session_id = session_id } },
        };
    }

    fn handleMessage(self: *Self, req: agent_types.AgentMessageRequest, env: agent_types.Envelope) !?agent_types.Envelope {
        const session = self.sessions.getPtr(req.session_id) orelse {
            return try self.makeError(env.session_id, env.message_id, .agent_not_found, "session not found");
        };

        const expected = self.expected_sequences.get(req.session_id) orelse 1;
        if (env.sequence != expected) {
            return try self.makeError(env.session_id, env.message_id, .invalid_request, "invalid sequence");
        }
        try self.expected_sequences.put(req.session_id, expected + 1);

        session.status = .processing;
        session.message_count += 1;
        session.updated_at = std.time.milliTimestamp();

        return null;
    }

    fn handleStop(self: *Self, req: agent_types.AgentStopRequest, env: agent_types.Envelope) !?agent_types.Envelope {
        const removed = self.sessions.fetchRemove(req.session_id) orelse {
            return try self.makeError(env.session_id, env.message_id, .agent_not_found, "session not found");
        };
        self.allocator.free(removed.value.model);
        _ = self.expected_sequences.remove(req.session_id);
        _ = self.outgoing_sequences.remove(req.session_id);

        const reason = if (req.getReason()) |r| try self.allocator.dupe(u8, r) else try self.allocator.dupe(u8, "stopped");
        return .{
            .session_id = req.session_id,
            .message_id = agent_types.generateUuid(),
            .sequence = env.sequence,
            .in_reply_to = env.message_id,
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .agent_stopped = .{
                .session_id = req.session_id,
                .reason = OwnedSlice(u8).initOwned(reason),
            } },
        };
    }

    fn handleStatus(self: *Self, req: anytype, env: agent_types.Envelope) !?agent_types.Envelope {
        const session = self.sessions.get(req.session_id) orelse {
            return try self.makeError(env.session_id, env.message_id, .agent_not_found, "session not found");
        };

        return .{
            .session_id = req.session_id,
            .message_id = agent_types.generateUuid(),
            .sequence = env.sequence,
            .in_reply_to = env.message_id,
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .session_info = .{
                .session_id = session.session_id,
                .status = session.status,
                .model = try self.allocator.dupe(u8, session.model),
                .message_count = session.message_count,
                .created_at = session.created_at,
                .updated_at = session.updated_at,
            } },
        };
    }

    fn makeError(self: *Self, session_id: agent_types.Uuid, in_reply_to: agent_types.Uuid, code: agent_types.AgentErrorCode, msg: []const u8) !agent_types.Envelope {
        return .{
            .session_id = session_id,
            .message_id = agent_types.generateUuid(),
            .sequence = 0,
            .in_reply_to = in_reply_to,
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .agent_error = .{
                .code = code,
                .message = try self.allocator.dupe(u8, msg),
            } },
        };
    }

    fn nextOutgoingSequence(self: *Self, session_id: agent_types.Uuid) u64 {
        const cur = self.outgoing_sequences.get(session_id) orelse 0;
        const next = cur + 1;
        self.outgoing_sequences.put(session_id, next) catch {};
        return next;
    }

    pub fn publishAgentEvent(self: *Self, session_id: agent_types.Uuid, event_json: []const u8) !void {
        if (!self.sessions.contains(session_id)) return error.SessionNotFound;
        try self.outbox.append(self.allocator, .{
            .session_id = session_id,
            .message_id = agent_types.generateUuid(),
            .sequence = self.nextOutgoingSequence(session_id),
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .agent_event = try self.allocator.dupe(u8, event_json) },
        });
    }

    pub fn publishAgentResult(self: *Self, session_id: agent_types.Uuid, result_json: []const u8) !void {
        if (!self.sessions.contains(session_id)) return error.SessionNotFound;
        try self.outbox.append(self.allocator, .{
            .session_id = session_id,
            .message_id = agent_types.generateUuid(),
            .sequence = self.nextOutgoingSequence(session_id),
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .agent_result = try self.allocator.dupe(u8, result_json) },
        });
    }

    pub fn popOutbound(self: *Self) ?agent_types.Envelope {
        if (self.outbox.items.len == 0) return null;
        return self.outbox.orderedRemove(0);
    }
};

test "AgentProtocolServer start message status stop" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    var start = agent_types.Envelope{
        .session_id = agent_types.generateUuid(),
        .message_id = agent_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .agent_start = .{ .config_json = try allocator.dupe(u8, "{}") } },
    };
    defer start.deinit(allocator);

    var start_resp = (try server.handleEnvelope(start)).?;
    defer start_resp.deinit(allocator);
    try std.testing.expect(start_resp.payload == .agent_started);

    const sid = start_resp.payload.agent_started.session_id;

    var msg = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .agent_message = .{
            .session_id = sid,
            .message_json = try allocator.dupe(u8, "{\"role\":\"user\"}"),
        } },
    };
    defer msg.deinit(allocator);
    try std.testing.expect((try server.handleEnvelope(msg)) == null);

    var status = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUuid(),
        .sequence = 3,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .agent_status = .{ .session_id = sid } },
    };
    defer status.deinit(allocator);

    var status_resp = (try server.handleEnvelope(status)).?;
    defer status_resp.deinit(allocator);
    try std.testing.expect(status_resp.payload == .session_info);
    try std.testing.expectEqual(@as(u32, 1), status_resp.payload.session_info.message_count);

    var stop = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUuid(),
        .sequence = 4,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .agent_stop = .{ .session_id = sid } },
    };
    defer stop.deinit(allocator);

    var stop_resp = (try server.handleEnvelope(stop)).?;
    defer stop_resp.deinit(allocator);
    try std.testing.expect(stop_resp.payload == .agent_stopped);
}
