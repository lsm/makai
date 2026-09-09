const std = @import("std");
const compat = @import("compat");
const agent_types = @import("agent_types");
const envelope = @import("agent_envelope");
const transport = @import("transport");
const OwnedSlice = @import("owned_slice").OwnedSlice;

/// A remote agent_event waiting to be normalized into a TuiEvent, tagged with
/// the session that produced it so the consumer can discard late events from a
/// previous remote session.
pub const QueuedEvent = struct {
    session_id: agent_types.SessionId,
    json: OwnedSlice(u8),

    pub fn deinit(self: *QueuedEvent, allocator: std.mem.Allocator) void {
        self.json.deinit(allocator);
        self.* = undefined;
    }
};

/// The most recent counter-advancing send (`agent_start`/`agent_message`) for
/// a session, so a correlated rejection can roll the per-session counter back
/// to the rejected send's own sequence (§13.1: a rejected request never
/// advances the server's expected counter, so a corrected retry reuses the
/// sequence; #210 gap 7).
const PendingSend = struct {
    msg_id: agent_types.Ulid,
    sequence: u64,
};

/// An in-flight bounded stop probe (#210 gap 7): after an uncorrelated outcome
/// the cleanup stop first tries the PRE-send counter state; a correlated
/// `invalid_request` rejection naming the probe's first stop triggers exactly
/// one retry at the post-send value. Any other reply — or removal of the
/// session — retires the probe without a retry.
const StopProbe = struct {
    first_msg_id: agent_types.Ulid,
    second_sequence: u64,
    reason: OwnedSlice(u8),
};

pub const AgentProtocolClient = struct {
    allocator: std.mem.Allocator,
    sender: ?transport.AsyncSender = null,
    /// Deprecated compatibility field; sequence is now tracked per session.
    sequence: u64 = 0,
    session_id: ?agent_types.SessionId = null,
    last_error: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    last_result_json: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    event_queue: std.ArrayList(QueuedEvent),
    next_sequence_by_session: std.AutoHashMap(agent_types.SessionId, u64),
    session_complete_flags: std.AutoHashMap(agent_types.SessionId, bool),
    session_last_errors: std.AutoHashMap(agent_types.SessionId, OwnedSlice(u8)),
    session_last_results: std.AutoHashMap(agent_types.SessionId, OwnedSlice(u8)),
    /// Last counter-advancing send per session (rollback target for correlated
    /// rejections; #210 gap 7).
    last_send_by_session: std.AutoHashMap(agent_types.SessionId, PendingSend),
    /// In-flight bounded stop probes per session (#210 gap 7).
    stop_probes_by_session: std.AutoHashMap(agent_types.SessionId, StopProbe),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .event_queue = std.ArrayList(QueuedEvent).empty,
            .next_sequence_by_session = std.AutoHashMap(agent_types.SessionId, u64).init(allocator),
            .session_complete_flags = std.AutoHashMap(agent_types.SessionId, bool).init(allocator),
            .session_last_errors = std.AutoHashMap(agent_types.SessionId, OwnedSlice(u8)).init(allocator),
            .session_last_results = std.AutoHashMap(agent_types.SessionId, OwnedSlice(u8)).init(allocator),
            .last_send_by_session = std.AutoHashMap(agent_types.SessionId, PendingSend).init(allocator),
            .stop_probes_by_session = std.AutoHashMap(agent_types.SessionId, StopProbe).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.last_error.deinit(self.allocator);
        self.last_result_json.deinit(self.allocator);
        for (self.event_queue.items) |*e| e.deinit(self.allocator);
        self.event_queue.deinit(self.allocator);
        self.next_sequence_by_session.deinit();

        var err_it = self.session_last_errors.iterator();
        while (err_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.session_last_errors.deinit();

        var result_it = self.session_last_results.iterator();
        while (result_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.session_last_results.deinit();
        self.session_complete_flags.deinit();
        self.last_send_by_session.deinit();

        var probe_it = self.stop_probes_by_session.iterator();
        while (probe_it.next()) |entry| {
            entry.value_ptr.reason.deinit(self.allocator);
        }
        self.stop_probes_by_session.deinit();

        self.* = undefined;
    }

    pub fn setSender(self: *Self, sender: transport.AsyncSender) void {
        self.sender = sender;
    }

    /// The next sequence the server is expected to accept for the session: 1
    /// before any send, the sent value + 1 after each counter-advancing send
    /// (optimistic — a correlated rejection rolls it back, §13.1).
    pub fn peekNextSequence(self: *Self, session_id: agent_types.SessionId) u64 {
        return self.next_sequence_by_session.get(session_id) orelse 1;
    }

    /// Allocates the next sequence for a counter-advancing send. Callers
    /// record the send via `recordPendingSend` once it is actually on the wire.
    fn advanceSequence(self: *Self, session_id: agent_types.SessionId) !u64 {
        const next = self.peekNextSequence(session_id);
        try self.next_sequence_by_session.put(session_id, next + 1);
        self.sequence = next; // compatibility mirror
        return next;
    }

    fn recordPendingSend(self: *Self, session_id: agent_types.SessionId, msg_id: agent_types.Ulid, sequence: u64) !void {
        try self.last_send_by_session.put(session_id, .{ .msg_id = msg_id, .sequence = sequence });
    }

    pub fn sendAgentStart(self: *Self, config_json: []const u8, system_prompt: ?[]const u8) !agent_types.Ulid {
        const sid = agent_types.generateSessionId();
        return self.sendAgentStartWithSession(sid, config_json, system_prompt);
    }

    pub fn sendAgentStartWithSession(self: *Self, sid: agent_types.SessionId, config_json: []const u8, system_prompt: ?[]const u8) !agent_types.Ulid {
        const msg_id = agent_types.generateUlid();
        const seq = try self.advanceSequence(sid);

        var payload = agent_types.Payload{ .agent_start = .{ .config_json = try self.allocator.dupe(u8, config_json), .session_id = sid } };
        defer payload.deinit(self.allocator);
        if (system_prompt) |sp| {
            payload.agent_start.system_prompt = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, sp));
        }

        try self.sendEnvelope(.{
            .session_id = sid,
            .message_id = msg_id,
            .sequence = seq,
            .timestamp = compat.time.nowMillis(),
            .payload = payload,
        });
        try self.recordPendingSend(sid, msg_id, seq);

        return msg_id;
    }

    pub fn sendAgentMessage(self: *Self, session_id: agent_types.SessionId, message_json: []const u8, options_json: ?[]const u8) !agent_types.Ulid {
        const seq = self.peekNextSequence(session_id);
        return self.sendAgentMessageWithSequence(session_id, message_json, options_json, seq);
    }

    /// Sends an `agent_message` carrying an EXPLICIT inbound sequence (#210
    /// gap 7): recovery paths that know which counter state the server holds
    /// (e.g. after a probe) are not forced to guess. The tracker mirrors the
    /// explicit value optimistically; a correlated rejection rolls it back so
    /// a corrected retry reuses the same sequence (§13.1).
    pub fn sendAgentMessageWithSequence(self: *Self, session_id: agent_types.SessionId, message_json: []const u8, options_json: ?[]const u8, sequence: u64) !agent_types.Ulid {
        const msg_id = agent_types.generateUlid();
        try self.next_sequence_by_session.put(session_id, sequence + 1);
        self.sequence = sequence; // compatibility mirror

        var payload = agent_types.Payload{ .agent_message = .{
            .session_id = session_id,
            .message_json = try self.allocator.dupe(u8, message_json),
        } };
        defer payload.deinit(self.allocator);
        if (options_json) |opts| payload.agent_message.options_json = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, opts));

        try self.sendEnvelope(.{
            .session_id = session_id,
            .message_id = msg_id,
            .sequence = sequence,
            .timestamp = compat.time.nowMillis(),
            .payload = payload,
        });
        try self.recordPendingSend(session_id, msg_id, sequence);
        return msg_id;
    }

    /// Sends an `agent_stop` at the tracker's current expected sequence. A
    /// stop consumes the counter together with the session when accepted and
    /// never advances it when rejected (§13.1), so unlike start/message sends
    /// this does not advance the tracker — a rejected stop leaves the expected
    /// value in place for the retry (#210 gap 7).
    pub fn sendAgentStop(self: *Self, session_id: agent_types.SessionId, reason: ?[]const u8) !agent_types.Ulid {
        return self.sendAgentStopWithSequence(session_id, reason, self.peekNextSequence(session_id));
    }

    /// Sends an `agent_stop` carrying an EXPLICIT inbound sequence (#210
    /// gap 7). Like `sendAgentStop`, the tracker is not advanced.
    pub fn sendAgentStopWithSequence(self: *Self, session_id: agent_types.SessionId, reason: ?[]const u8, sequence: u64) !agent_types.Ulid {
        const msg_id = agent_types.generateUlid();

        var payload = agent_types.Payload{ .agent_stop = .{ .session_id = session_id } };
        defer payload.deinit(self.allocator);
        if (reason) |r| payload.agent_stop.reason = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, r));

        try self.sendEnvelope(.{
            .session_id = session_id,
            .message_id = msg_id,
            .sequence = sequence,
            .timestamp = compat.time.nowMillis(),
            .payload = payload,
        });
        return msg_id;
    }

    /// Bounded two-state stop probe for an UNCORRELATED send outcome (#210
    /// gap 7, §13.4.1): the cleanup stop first tries the PRE-send counter
    /// state (the session's last counter-advancing send's own sequence — the
    /// message may have been rejected with the counter rolled back), and a
    /// correlated `invalid_request` rejection processed later through
    /// `processEnvelope` triggers exactly one retry at the post-send value
    /// (the message may have been accepted with its output lost or delayed).
    /// Acceptance at either value settles cleanup; no other reply retries.
    pub fn sendAgentStopProbing(self: *Self, session_id: agent_types.SessionId, reason: ?[]const u8) !agent_types.Ulid {
        const last = self.last_send_by_session.get(session_id) orelse {
            // No counter-advancing send recorded for the session: there is no
            // pre/post pair to probe — fall back to a plain tracked stop.
            return self.sendAgentStop(session_id, reason);
        };
        const msg_id = try self.sendAgentStopWithSequence(session_id, reason, last.sequence);
        const owned_reason = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, reason orelse ""));
        errdefer owned_reason.deinit(self.allocator);
        if (self.stop_probes_by_session.fetchRemove(session_id)) |entry| {
            var superseded = entry.value;
            superseded.reason.deinit(self.allocator);
        }
        try self.stop_probes_by_session.put(session_id, .{
            .first_msg_id = msg_id,
            .second_sequence = last.sequence + 1,
            .reason = owned_reason,
        });
        return msg_id;
    }

    fn sendEnvelope(self: *Self, env: agent_types.Envelope) !void {
        if (self.sender == null) return error.NoSender;
        const json = try envelope.serializeEnvelope(env, self.allocator);
        defer self.allocator.free(json);
        try self.sender.?.write(json);
        try self.sender.?.flush();
    }

    fn setSessionError(self: *Self, session_id: agent_types.SessionId, msg: []const u8) !void {
        if (self.session_last_errors.getPtr(session_id)) |existing| {
            existing.deinit(self.allocator);
            existing.* = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, msg));
        } else {
            try self.session_last_errors.put(session_id, OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, msg)));
        }
        try self.session_complete_flags.put(session_id, true);
    }

    fn setSessionResult(self: *Self, session_id: agent_types.SessionId, result_json: []const u8) !void {
        if (self.session_last_results.getPtr(session_id)) |existing| {
            existing.deinit(self.allocator);
            existing.* = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, result_json));
        } else {
            try self.session_last_results.put(session_id, OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, result_json)));
        }
        try self.session_complete_flags.put(session_id, true);
    }

    pub fn clearSessionTerminalState(self: *Self, session_id: agent_types.SessionId) void {
        self.session_complete_flags.put(session_id, false) catch {};
        if (self.session_last_errors.fetchRemove(session_id)) |entry| {
            var err = entry.value;
            err.deinit(self.allocator);
        }
        if (self.session_last_results.fetchRemove(session_id)) |entry| {
            var result = entry.value;
            result.deinit(self.allocator);
        }
    }

    pub fn processEnvelope(self: *Self, env: agent_types.Envelope) !void {
        switch (env.payload) {
            .agent_started => |p| {
                self.session_id = p.session_id;
                self.clearSessionTerminalState(p.session_id);
                try self.session_complete_flags.put(p.session_id, false);
            },
            .agent_event => |json| {
                var owned_json = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, json));
                errdefer owned_json.deinit(self.allocator);
                try self.event_queue.append(self.allocator, .{
                    .session_id = env.session_id,
                    .json = owned_json,
                });
            },
            .agent_result => |json| {
                self.last_result_json.deinit(self.allocator);
                self.last_result_json = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, json));
                try self.setSessionResult(env.session_id, json);
            },
            .agent_error => |e| {
                self.last_error.deinit(self.allocator);
                self.last_error = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, e.message));
                try self.setSessionError(env.session_id, e.message);
                try self.handleCorrelatedRejection(env.session_id, env.in_reply_to, e.code);
            },
            .nack => |n| {
                // A correlated nack is a request rejection like a correlated
                // agent_error (the fixture server and older peers use this
                // shape); only the invalid_request classification matters
                // here — the rollback below applies to any correlated nack.
                try self.handleCorrelatedRejection(env.session_id, env.in_reply_to, agentCodeFromNack(n.error_code));
            },
            .agent_stopped => |p| {
                if (self.session_id) |sid| {
                    if (std.mem.eql(u8, sid[0..], p.session_id[0..])) self.session_id = null;
                }
                _ = self.next_sequence_by_session.remove(p.session_id);
                self.clearSessionControlState(p.session_id);
                try self.session_complete_flags.put(p.session_id, true);
            },
            else => {},
        }
    }

    fn agentCodeFromNack(code: ?agent_types.ErrorCode) ?agent_types.AgentErrorCode {
        const c = code orelse return null;
        return switch (c) {
            .invalid_request => .invalid_request,
            else => null,
        };
    }

    fn clearSessionControlState(self: *Self, session_id: agent_types.SessionId) void {
        _ = self.last_send_by_session.remove(session_id);
        if (self.stop_probes_by_session.fetchRemove(session_id)) |entry| {
            var probe = entry.value;
            probe.reason.deinit(self.allocator);
        }
    }

    /// Applies #210 gap 7's client sequence-control rules to a correlated
    /// rejection (an `agent_error`/`nack` whose `in_reply_to` names this
    /// client's own send): the probed stop retries once on `invalid_request`,
    /// and a rejected counter-advancing send rolls the tracker back so a
    /// corrected retry reuses the same sequence (§13.1 — a rejected request
    /// never advances the server's expected counter).
    fn handleCorrelatedRejection(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid, code: ?agent_types.AgentErrorCode) !void {
        const reply_to = in_reply_to orelse return;

        if (self.stop_probes_by_session.get(session_id)) |probe| {
            if (std.mem.eql(u8, &reply_to, &probe.first_msg_id)) {
                // The probe's first stop was answered. Retire the probe; a
                // correlated invalid_request (wrong counter state) triggers
                // the one bounded retry at the post-send value.
                const retry = if (code) |c| c == .invalid_request else false;
                const second_sequence = probe.second_sequence;
                var reason = probe.reason;
                _ = self.stop_probes_by_session.remove(session_id);
                defer reason.deinit(self.allocator);
                if (retry) {
                    self.sendAgentStopWithSequence(session_id, reason.slice(), second_sequence) catch {};
                }
                return;
            }
        }

        if (self.last_send_by_session.get(session_id)) |pending| {
            if (!std.mem.eql(u8, &reply_to, &pending.msg_id)) return;
            const session_gone = if (code) |c| c == .agent_not_found else false;
            if (session_gone) {
                // The session is gone server-side; its counter state is
                // meaningless — drop it rather than rolling back.
                _ = self.next_sequence_by_session.remove(session_id);
                _ = self.last_send_by_session.remove(session_id);
                return;
            }
            // Roll the tracker back to the rejected send's own sequence: the
            // server did not advance, so a corrected retry MUST reuse it.
            try self.next_sequence_by_session.put(session_id, pending.sequence);
        }
    }

    pub fn popEvent(self: *Self) ?QueuedEvent {
        if (self.event_queue.items.len == 0) return null;
        return self.event_queue.orderedRemove(0);
    }

    pub fn getLastError(self: *Self) ?[]const u8 {
        const err = self.last_error.slice();
        return if (err.len == 0) null else err;
    }

    pub fn getLastResultJson(self: *Self) ?[]const u8 {
        const json = self.last_result_json.slice();
        return if (json.len == 0) null else json;
    }

    pub fn isSessionComplete(self: *Self, session_id: agent_types.SessionId) bool {
        return self.session_complete_flags.get(session_id) orelse false;
    }

    pub fn getLastErrorForSession(self: *Self, session_id: agent_types.SessionId) ?[]const u8 {
        if (self.session_last_errors.get(session_id)) |err| {
            const msg = err.slice();
            if (msg.len > 0) return msg;
        }
        return null;
    }

    pub fn getLastResultJsonForSession(self: *Self, session_id: agent_types.SessionId) ?[]const u8 {
        if (self.session_last_results.get(session_id)) |result| {
            const json = result.slice();
            if (json.len > 0) return json;
        }
        return null;
    }

    pub fn removeSessionState(self: *Self, session_id: agent_types.SessionId) void {
        _ = self.next_sequence_by_session.remove(session_id);
        _ = self.session_complete_flags.remove(session_id);
        self.clearSessionControlState(session_id);

        if (self.session_last_errors.fetchRemove(session_id)) |entry| {
            var err = entry.value;
            err.deinit(self.allocator);
        }
        if (self.session_last_results.fetchRemove(session_id)) |entry| {
            var result = entry.value;
            result.deinit(self.allocator);
        }

        if (self.session_id) |sid| {
            if (std.mem.eql(u8, sid[0..], session_id[0..])) {
                self.session_id = null;
                self.last_error.deinit(self.allocator);
                self.last_error = OwnedSlice(u8).initBorrowed("");
                self.last_result_json.deinit(self.allocator);
                self.last_result_json = OwnedSlice(u8).initBorrowed("");
            }
        }
    }
};

test "AgentProtocolClient processes events and results" {
    const allocator = std.testing.allocator;
    var client = AgentProtocolClient.init(allocator);
    defer client.deinit();

    const sid = agent_types.generateSessionId();

    try client.processEnvelope(.{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });

    var event_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_event = try allocator.dupe(u8, "{\"type\":\"turn_start\"}") },
    };
    defer event_env.deinit(allocator);
    try client.processEnvelope(event_env);

    var result_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer result_env.deinit(allocator);
    try client.processEnvelope(result_env);

    var ev = client.popEvent().?;
    defer ev.deinit(allocator);
    try std.testing.expectEqualStrings("{\"type\":\"turn_start\"}", ev.json.slice());
    try std.testing.expectEqualStrings("{\"ok\":true}", client.getLastResultJson().?);
    try std.testing.expect(client.isSessionComplete(sid));
    try std.testing.expectEqualStrings("{\"ok\":true}", client.getLastResultJsonForSession(sid).?);
}

test "AgentProtocolClient removeSessionState clears per-session and legacy current state" {
    const allocator = std.testing.allocator;
    var client = AgentProtocolClient.init(allocator);
    defer client.deinit();

    const sid = agent_types.generateSessionId();
    client.session_id = sid;
    try client.session_complete_flags.put(sid, true);
    try client.session_last_errors.put(sid, OwnedSlice(u8).initOwned(try allocator.dupe(u8, "session err")));
    try client.session_last_results.put(sid, OwnedSlice(u8).initOwned(try allocator.dupe(u8, "{\"ok\":false}")));
    try client.next_sequence_by_session.put(sid, 4);
    client.last_error = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "legacy err"));
    client.last_result_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "{\"legacy\":true}"));

    client.removeSessionState(sid);

    try std.testing.expect(!client.next_sequence_by_session.contains(sid));
    try std.testing.expect(!client.session_complete_flags.contains(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(client.getLastResultJsonForSession(sid) == null);
    try std.testing.expect(client.session_id == null);
    try std.testing.expect(client.getLastError() == null);
    try std.testing.expect(client.getLastResultJson() == null);
}

test "AgentProtocolClient maintains per-session sequence continuity across stop and restart" {
    const allocator = std.testing.allocator;

    var writes = std.ArrayList([]u8).empty;
    defer {
        for (writes.items) |line| allocator.free(line);
        writes.deinit(allocator);
    }

    const MockSender = struct {
        writes: *std.ArrayList([]u8),

        fn writeFn(ctx: *anyopaque, data: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.writes.append(std.testing.allocator, try std.testing.allocator.dupe(u8, data));
        }

        fn flushFn(_: *anyopaque) !void {}
    };

    var mock = MockSender{ .writes = &writes };
    const sender = transport.AsyncSender{
        .context = @ptrCast(&mock),
        .write_fn = MockSender.writeFn,
        .flush_fn = MockSender.flushFn,
    };

    var client = AgentProtocolClient.init(allocator);
    defer client.deinit();
    client.setSender(sender);

    const sid1 = agent_types.generateSessionId();
    const sid2 = agent_types.generateSessionId();

    _ = try client.sendAgentMessage(sid1, "{\"m\":1}", null); // sid1 seq 1
    _ = try client.sendAgentMessage(sid2, "{\"m\":2}", null); // sid2 seq 1
    _ = try client.sendAgentMessage(sid1, "{\"m\":3}", null); // sid1 seq 2

    var stopped_env = agent_types.Envelope{
        .session_id = sid1,
        .message_id = agent_types.generateUlid(),
        .sequence = 10,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_stopped = .{ .session_id = sid1 } },
    };
    defer stopped_env.deinit(allocator);
    try client.processEnvelope(stopped_env);

    _ = try client.sendAgentMessage(sid1, "{\"m\":4}", null); // sid1 restart seq 1
    _ = try client.sendAgentMessage(sid2, "{\"m\":5}", null); // sid2 stays seq 2

    try std.testing.expectEqual(@as(usize, 5), writes.items.len);

    var e1 = try envelope.deserializeEnvelope(writes.items[0], allocator);
    defer e1.deinit(allocator);
    var e2 = try envelope.deserializeEnvelope(writes.items[1], allocator);
    defer e2.deinit(allocator);
    var e3 = try envelope.deserializeEnvelope(writes.items[2], allocator);
    defer e3.deinit(allocator);
    var e4 = try envelope.deserializeEnvelope(writes.items[3], allocator);
    defer e4.deinit(allocator);
    var e5 = try envelope.deserializeEnvelope(writes.items[4], allocator);
    defer e5.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 1), e1.sequence);
    try std.testing.expectEqual(@as(u64, 1), e2.sequence);
    try std.testing.expectEqual(@as(u64, 2), e3.sequence);
    try std.testing.expectEqual(@as(u64, 1), e4.sequence);
    try std.testing.expectEqual(@as(u64, 2), e5.sequence);
    try std.testing.expectEqualSlices(u8, sid1[0..], e4.session_id[0..]);
    try std.testing.expectEqualSlices(u8, sid2[0..], e5.session_id[0..]);
}

/// Test scaffolding shared by the gap-7 sequence-control tests: a client
/// wired to a capturing mock sender. Call `wire()` once the harness is placed
/// in its final location — the mock sender's context points back at it.
const Gap7Harness = struct {
    writes: std.ArrayList([]u8) = std.ArrayList([]u8).empty,
    client: AgentProtocolClient,

    fn init() Gap7Harness {
        return .{ .client = AgentProtocolClient.init(std.testing.allocator) };
    }

    fn wire(self: *Gap7Harness) void {
        const sender = transport.AsyncSender{
            .context = @ptrCast(self),
            .write_fn = writeFn,
            .flush_fn = flushFn,
        };
        self.client.setSender(sender);
    }

    fn deinit(self: *Gap7Harness) void {
        for (self.writes.items) |line| std.testing.allocator.free(line);
        self.writes.deinit(std.testing.allocator);
        self.client.deinit();
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) !void {
        const self: *Gap7Harness = @ptrCast(@alignCast(ctx));
        try self.writes.append(std.testing.allocator, try std.testing.allocator.dupe(u8, data));
    }

    fn flushFn(_: *anyopaque) !void {}

    /// Deserializes the i-th captured write as an envelope (caller owns the
    /// returned envelope's deinit).
    fn envelopeAt(self: *Gap7Harness, i: usize) !agent_types.Envelope {
        return try envelope.deserializeEnvelope(self.writes.items[i], std.testing.allocator);
    }
};

test "AgentProtocolClient rolls the tracker back on a correlated rejection so a retry reuses the sequence (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1
    const msg_id = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2, tracker 3
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));

    // Server rejects the message (correlated agent_error, §13.1 id-agreement
    // failure): the expected counter did NOT advance — roll the tracker back.
    var rejection = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = msg_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = "invalid sequence" } },
    };
    defer rejection.deinit(allocator);
    try client.processEnvelope(rejection);
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));

    // The corrected retry reuses the rejected send's sequence.
    _ = try client.sendAgentMessage(sid, "{\"m\":1-fixed}", null);
    var retried = try harness.envelopeAt(2);
    defer retried.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), retried.sequence);
    try std.testing.expectEqualStrings("{\"m\":1-fixed}", retried.payload.agent_message.message_json);
}

test "AgentProtocolClient rolls the tracker back on a correlated nack rejection too (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1
    const msg_id = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2, tracker 3

    var nack_rejection = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = msg_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = msg_id,
            .reason = OwnedSlice(u8).initBorrowed("invalid sequence"),
            .error_code = .invalid_sequence,
        } },
    };
    defer nack_rejection.deinit(allocator);
    try client.processEnvelope(nack_rejection);
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));
}

test "AgentProtocolClient probing stop tries pre-send first, then post-send on correlated invalid_request (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2, tracker 3

    // Outcome uncorrelated (timeout / lost output): the message may have been
    // accepted (server counter advanced) or rejected (rolled back) — probe.
    const probe_stop_id = try client.sendAgentStopProbing(sid, "timeout");
    var first_stop = try harness.envelopeAt(2);
    defer first_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), first_stop.sequence); // PRE-send state first

    // The server holds the post-send state: correlated invalid_request names
    // the probe's first stop, so the client retries once with sequence 3.
    var rejection = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = probe_stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = "invalid sequence" } },
    };
    defer rejection.deinit(allocator);
    try client.processEnvelope(rejection);
    try std.testing.expectEqual(@as(usize, 4), harness.writes.items.len);
    var second_stop = try harness.envelopeAt(3);
    defer second_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), second_stop.sequence); // post-send value
    try std.testing.expect(std.meta.activeTag(second_stop.payload) == .agent_stop);

    // Acceptance settles cleanup: agent_stopped clears the counter and the
    // probe never fires again (bounded).
    var stopped = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 4,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_stopped = .{ .session_id = sid } },
    };
    defer stopped.deinit(allocator);
    try client.processEnvelope(stopped);
    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));
    try std.testing.expect(!client.stop_probes_by_session.contains(sid));
    try std.testing.expect(!client.last_send_by_session.contains(sid));
    try std.testing.expectEqual(@as(usize, 4), harness.writes.items.len);
}

test "AgentProtocolClient probing stop accepts the pre-send state without a retry when the counter rolled back (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2

    const probe_stop_id = try client.sendAgentStopProbing(sid, "timeout");
    var first_stop = try harness.envelopeAt(2);
    defer first_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), first_stop.sequence);

    // The server held the pre-send state all along: the stop is ACCEPTED and
    // its agent_stopped reply retires the probe — no second stop is sent.
    var stopped = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = probe_stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_stopped = .{ .session_id = sid } },
    };
    defer stopped.deinit(allocator);
    try client.processEnvelope(stopped);
    try std.testing.expectEqual(@as(usize, 3), harness.writes.items.len);
    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));
}

test "AgentProtocolClient probing stop is bounded: no retry on a non-invalid_request rejection (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);

    const probe_stop_id = try client.sendAgentStopProbing(sid, "timeout");

    // agent_not_found: the session is already gone — nothing to probe.
    var rejection = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = probe_stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_not_found, .message = "session not found" } },
    };
    defer rejection.deinit(allocator);
    try client.processEnvelope(rejection);
    try std.testing.expectEqual(@as(usize, 3), harness.writes.items.len);
    try std.testing.expect(!client.stop_probes_by_session.contains(sid));
}

test "AgentProtocolClient stop sends never advance the tracker (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2, tracker 3

    // A stop consumes the counter with the session when accepted and never
    // advances it when rejected — a rejected stop leaves the expected value
    // in place for the retry.
    const stop_id = try client.sendAgentStop(sid, "completed");
    var stop_env = try harness.envelopeAt(2);
    defer stop_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), stop_env.sequence);
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));

    var rejection = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = "invalid sequence" } },
    };
    defer rejection.deinit(allocator);
    try client.processEnvelope(rejection);
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));

    // The stop retry reuses the same sequence.
    _ = try client.sendAgentStop(sid, "completed");
    var stop_retry = try harness.envelopeAt(3);
    defer stop_retry.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), stop_retry.sequence);
}

test "AgentProtocolClient explicit-sequence sends carry the given value and roll back on rejection (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();

    // Recovery paths that know the server's counter state are not forced to
    // guess: the explicit sequence is carried verbatim (the SERVER still
    // rejects true duplicates — the client sends exactly what it is told).
    const msg_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 7);
    var explicit = try harness.envelopeAt(0);
    defer explicit.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 7), explicit.sequence);
    try std.testing.expectEqual(@as(u64, 8), client.peekNextSequence(sid));

    var rejection = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = msg_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = "invalid sequence" } },
    };
    defer rejection.deinit(allocator);
    try client.processEnvelope(rejection);
    try std.testing.expectEqual(@as(u64, 7), client.peekNextSequence(sid));

    // Explicit stop sends likewise carry the given value without advancing.
    _ = try client.sendAgentStopWithSequence(sid, "recovered", 7);
    var explicit_stop = try harness.envelopeAt(1);
    defer explicit_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 7), explicit_stop.sequence);
    try std.testing.expectEqual(@as(u64, 7), client.peekNextSequence(sid));
}
