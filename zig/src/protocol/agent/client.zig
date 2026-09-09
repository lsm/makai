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

/// Every counter-advancing send (`agent_start`/`agent_message`) for a session
/// whose outcome is still unresolved, so a correlated rejection can roll the
/// per-session counter back to the rejected send's own sequence (§13.1: a
/// rejected request never advances the server's expected counter, so a
/// corrected retry reuses the sequence; #210 gap 7). All outstanding sends are
/// tracked (not just the latest): a reply may name ANY of them, and the
/// rollback takes the minimum — an older unresolved send's floor must never be
/// lost. `kind` matters for probing: only a `message` send's outcome is safe
/// to probe (§6.1/§13.4.1) — a start-only unknown outcome on a caller-supplied
/// id carries no ownership evidence, and the probe's second stop would
/// validate against a foreign owner's freshly started session.
const PendingSendKind = enum { start, message };

const PendingSend = struct {
    msg_id: agent_types.Ulid,
    sequence: u64,
    kind: PendingSendKind,
};

/// An in-flight bounded stop probe (#210 gap 7): after an uncorrelated
/// `agent_message` outcome the cleanup stop first tries the PRE-send counter
/// state; a correlated `invalid_request` rejection naming the probe's first
/// stop triggers exactly one retry at the post-send value. `final` marks the
/// second phase — the retry is in flight and its OWN replies are consumed
/// without any further retry (a session that vanished between the two stops
/// answers `agent_not_found`; both candidates missing answers
/// `invalid_request`) so cleanup mechanics never surface as run errors.
const StopProbe = struct {
    first_msg_id: agent_types.Ulid,
    second_sequence: u64,
    reason: OwnedSlice(u8),
    final: bool = false,
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
    /// Outstanding counter-advancing sends per session (rollback targets for
    /// correlated rejections; #210 gap 7). Well-behaved callers keep at most
    /// one (§13.2.4's one-active-run rule); pipelined sends are all tracked so
    /// a late reply still finds its own rollback floor.
    pending_sends_by_session: std.AutoHashMap(agent_types.SessionId, std.ArrayList(PendingSend)),
    /// Sessions whose `agent_started` this client observed (§6.1 admission
    /// evidence; #210 gap 7) — the stop probe requires it.
    admitted_by_session: std.AutoHashMap(agent_types.SessionId, bool),
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
            .pending_sends_by_session = std.AutoHashMap(agent_types.SessionId, std.ArrayList(PendingSend)).init(allocator),
            .admitted_by_session = std.AutoHashMap(agent_types.SessionId, bool).init(allocator),
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

        var pending_it = self.pending_sends_by_session.iterator();
        while (pending_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.pending_sends_by_session.deinit();
        self.admitted_by_session.deinit();

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

    /// Records a counter-advancing send BEFORE it is written to the wire, so
    /// the post-send bookkeeping is infallible: an allocation failure here
    /// errors out with nothing on the wire, never after the server may have
    /// accepted the send (#210 gap 7).
    fn recordPendingSend(self: *Self, session_id: agent_types.SessionId, msg_id: agent_types.Ulid, sequence: u64, kind: PendingSendKind) !void {
        const gop = try self.pending_sends_by_session.getOrPut(session_id);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(PendingSend).empty;
        try gop.value_ptr.append(self.allocator, .{ .msg_id = msg_id, .sequence = sequence, .kind = kind });
    }

    pub fn sendAgentStart(self: *Self, config_json: []const u8, system_prompt: ?[]const u8) !agent_types.Ulid {
        const sid = agent_types.generateSessionId();
        return self.sendAgentStartWithSession(sid, config_json, system_prompt);
    }

    pub fn sendAgentStartWithSession(self: *Self, sid: agent_types.SessionId, config_json: []const u8, system_prompt: ?[]const u8) !agent_types.Ulid {
        const msg_id = agent_types.generateUlid();
        const seq = try self.advanceSequence(sid);
        try self.recordPendingSend(sid, msg_id, seq, .start);

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
        try self.recordPendingSend(session_id, msg_id, sequence, .message);

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
        try self.sendStopEnvelope(session_id, msg_id, reason, sequence);
        return msg_id;
    }

    fn sendStopEnvelope(self: *Self, session_id: agent_types.SessionId, msg_id: agent_types.Ulid, reason: ?[]const u8, sequence: u64) !void {
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
    }

    /// Bounded two-state stop probe for an UNCORRELATED `agent_message`
    /// outcome (#210 gap 7, §13.4.1): the cleanup stop first tries the
    /// PRE-send counter state (the message may have been rejected with the
    /// counter rolled back), and a correlated `invalid_request` rejection
    /// processed later through `processEnvelope` triggers exactly one retry
    /// at the post-send value (the message may have been accepted with its
    /// output lost or delayed); the retry's own replies are consumed the
    /// same way. Acceptance at either value settles cleanup; no other reply
    /// retries.
    ///
    /// Probing requires OWNERSHIP EVIDENCE (§6.1): a recorded `agent_message`
    /// send AND an observed `agent_started` for this session's registration.
    /// Without the admission observation, a message sent into a caller-
    /// supplied id that a foreign caller's start had just claimed would be
    /// ACCEPTED by that foreign session (advancing its counter), and the
    /// probe's second stop would then validate and destroy it. Without
    /// either piece of evidence this sends NOTHING and returns null: leaking
    /// a session that might be ours is strictly preferable to stopping one
    /// that is not. A caller with positive evidence can still issue
    /// `sendAgentStopWithSequence`.
    pub fn sendAgentStopProbing(self: *Self, session_id: agent_types.SessionId, reason: ?[]const u8) !?agent_types.Ulid {
        if (self.admitted_by_session.get(session_id) != true) return null;
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return null;
        var last_message_sequence: ?u64 = null;
        var i = list.items.len;
        while (i > 0) {
            i -= 1;
            if (list.items[i].kind == .message) {
                last_message_sequence = list.items[i].sequence;
                break;
            }
        }
        const pre_send = last_message_sequence orelse return null;

        // Register the probe BEFORE the stop reaches the wire so the
        // post-send bookkeeping is infallible; a failed write unregisters it.
        const msg_id = agent_types.generateUlid();
        var owned_reason = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, reason orelse ""));
        errdefer owned_reason.deinit(self.allocator);
        if (self.stop_probes_by_session.fetchRemove(session_id)) |entry| {
            var superseded = entry.value;
            superseded.reason.deinit(self.allocator);
        }
        try self.stop_probes_by_session.put(session_id, .{
            .first_msg_id = msg_id,
            .second_sequence = pre_send + 1,
            .reason = owned_reason,
        });
        errdefer {
            if (self.stop_probes_by_session.fetchRemove(session_id)) |entry| {
                var probe = entry.value;
                probe.reason.deinit(self.allocator);
            }
        }
        try self.sendStopEnvelope(session_id, msg_id, reason, pre_send);
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
                // §6.1 admission evidence (#210 gap 7): this registration's
                // start was accepted — the stop probe may reconcile a message
                // send's unknown outcome against the session it created.
                try self.admitted_by_session.put(p.session_id, true);
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
                // Probe-control replies are consumed BEFORE terminal
                // bookkeeping: the probe's intentional first-stop rejection
                // is cleanup mechanics, not a run failure — recording it as
                // the session's last error would surface a false failure to
                // isSessionComplete/getLastErrorForSession callers (#210
                // gap 7).
                if (!try self.handleProbeReply(env.session_id, env.in_reply_to, e.code)) {
                    self.last_error.deinit(self.allocator);
                    self.last_error = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, e.message));
                    try self.setSessionError(env.session_id, e.message);
                    try self.handleCorrelatedRejection(env.session_id, env.in_reply_to, e.code);
                }
            },
            .nack => |n| {
                // A correlated nack is a request rejection like a correlated
                // agent_error (the fixture server and older peers use this
                // shape); probe replies are consumed first, then the rollback
                // applies to any remaining correlated nack.
                if (!try self.handleProbeReply(env.session_id, env.in_reply_to, agentCodeFromNack(n.error_code))) {
                    try self.handleCorrelatedRejection(env.session_id, env.in_reply_to, agentCodeFromNack(n.error_code));
                }
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
        if (self.pending_sends_by_session.fetchRemove(session_id)) |entry| {
            var list = entry.value;
            list.deinit(self.allocator);
        }
        _ = self.admitted_by_session.remove(session_id);
        if (self.stop_probes_by_session.fetchRemove(session_id)) |entry| {
            var probe = entry.value;
            probe.reason.deinit(self.allocator);
        }
    }

    /// Handles a reply correlated to an active stop probe. Returns true when
    /// the envelope IS a probe-control reply and has been fully consumed
    /// (callers must then skip terminal bookkeeping — the probe's replies are
    /// cleanup mechanics, not run failures). In the first phase a correlated
    /// `invalid_request` triggers the one bounded retry at the post-send
    /// value and re-registers the probe in its final phase so the retry's own
    /// replies are consumed too. In any phase, `agent_not_found` drops the
    /// session's sequence state (the session is gone server-side — a
    /// re-registration of the id must start from sequence 1, not the stale
    /// optimistic counter) and marks the session complete: no `agent_stopped`
    /// can ever follow for a nonexistent session.
    fn handleProbeReply(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid, code: ?agent_types.AgentErrorCode) !bool {
        const reply_to = in_reply_to orelse return false;
        const probe = self.stop_probes_by_session.get(session_id) orelse return false;
        if (!std.mem.eql(u8, &reply_to, &probe.first_msg_id)) return false;

        const retry = !probe.final and (if (code) |c| c == .invalid_request else false);
        const session_gone = if (code) |c| c == .agent_not_found else false;
        const second_sequence = probe.second_sequence;
        var reason = probe.reason;
        _ = self.stop_probes_by_session.remove(session_id);
        defer reason.deinit(self.allocator);
        if (retry) {
            const second_msg_id = self.sendAgentStopWithSequence(session_id, reason.slice(), second_sequence) catch {
                // The retry never reached the wire — no reply will name it,
                // so there is nothing to register for consumption.
                return true;
            };
            // Final phase: consume the retry's own replies. The reason is not
            // used for another send, so a borrowed empty slice suffices.
            try self.stop_probes_by_session.put(session_id, .{
                .first_msg_id = second_msg_id,
                .second_sequence = 0,
                .reason = OwnedSlice(u8).initBorrowed(""),
                .final = true,
            });
        } else if (session_gone) {
            _ = self.next_sequence_by_session.remove(session_id);
            self.clearSessionControlState(session_id);
            try self.session_complete_flags.put(session_id, true);
        }
        return true;
    }

    /// Applies #210 gap 7's client sequence-control rules to a correlated
    /// rejection (an `agent_error`/`nack` whose `in_reply_to` names this
    /// client's own send): a rejected counter-advancing send rolls the tracker
    /// back so a corrected retry reuses the same sequence (§13.1 — a rejected
    /// request never advances the server's expected counter). ALL outstanding
    /// sends are matched (a pipelined send's reply may arrive after a later
    /// send was recorded), and the rollback takes the MINIMUM of the tracker
    /// and the rejected send's sequence: an older unresolved send's floor
    /// must never be lost to a younger send's rejection.
    fn handleCorrelatedRejection(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid, code: ?agent_types.AgentErrorCode) !void {
        const reply_to = in_reply_to orelse return;

        const session_gone = if (code) |c| c == .agent_not_found else false;
        if (session_gone) {
            // A correlated agent_not_found — whether it names a
            // counter-advancing send or a plain stop (whose id the client
            // does not track): the session does not exist server-side, so
            // its tracked sequence state is meaningless. Drop it — a
            // re-registration of the id must start at sequence 1, not the
            // stale optimistic counter.
            _ = self.next_sequence_by_session.remove(session_id);
            self.clearSessionControlState(session_id);
            return;
        }

        const list = self.pending_sends_by_session.getPtr(session_id) orelse return;
        for (list.items, 0..) |pending, index| {
            if (!std.mem.eql(u8, &reply_to, &pending.msg_id)) continue;
            const floor = @min(self.peekNextSequence(session_id), pending.sequence);
            try self.next_sequence_by_session.put(session_id, floor);
            _ = list.orderedRemove(index);
            return;
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
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
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
    // Admission evidence (§6.1, #210 gap 7): the probe reconciles a message
    // send only against a registration whose agent_started this observed.
    var started_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = sid } },
    };
    defer started_env.deinit(allocator);
    try client.processEnvelope(started_env);
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
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer rejection.deinit(allocator);
    try client.processEnvelope(rejection);
    // The probe-control rejection is consumed as cleanup mechanics — it must
    // NOT surface as the session's terminal error or completion.
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(!client.isSessionComplete(sid));
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
    try std.testing.expect(!client.pending_sends_by_session.contains(sid));
    try std.testing.expectEqual(@as(usize, 4), harness.writes.items.len);
    // Completion comes from the agent_stopped reply alone, with no error.
    try std.testing.expect(client.isSessionComplete(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
}

test "AgentProtocolClient probing stop accepts the pre-send state without a retry when the counter rolled back (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1
    // Admission evidence (§6.1, #210 gap 7): the probe reconciles a message
    // send only against a registration whose agent_started this observed.
    var started_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = sid } },
    };
    defer started_env.deinit(allocator);
    try client.processEnvelope(started_env);
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
        .payload = .{ .agent_error = .{ .code = .agent_not_found, .message = try allocator.dupe(u8, "session not found") } },
    };
    defer rejection.deinit(allocator);
    try client.processEnvelope(rejection);
    try std.testing.expectEqual(@as(usize, 3), harness.writes.items.len);
    try std.testing.expect(!client.stop_probes_by_session.contains(sid));
    // The stale optimistic counter is dropped with the session: a
    // re-registration of the id must start its next start at sequence 1.
    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));
    try std.testing.expect(!client.pending_sends_by_session.contains(sid));
}

test "AgentProtocolClient probing stop requires a message send: a start-only outcome sends NOTHING (#210 gap 7)" {
    // §6.1 via #210 gap 7: a start-only unknown outcome on a caller-supplied
    // id carries no ownership evidence — even a single plain stop at the
    // tracker's value (sequence 2) would validate against a foreign owner's
    // freshly started session and destroy it. With no agent_message recorded,
    // sendAgentStopProbing must send nothing and register no probe: leaking a
    // session that might be ours is strictly preferable to stopping one that
    // is not.
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1, tracker 2

    const result = try client.sendAgentStopProbing(sid, "timeout");
    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(usize, 1), harness.writes.items.len); // the start only — no stop
    try std.testing.expect(!client.stop_probes_by_session.contains(sid));

    // Same no-send rule with no recorded send at all.
    const other = agent_types.generateSessionId();
    const other_result = try client.sendAgentStopProbing(other, "timeout");
    try std.testing.expect(other_result == null);
    try std.testing.expectEqual(@as(usize, 1), harness.writes.items.len);
}

test "AgentProtocolClient probing stop requires admission evidence: an unobserved agent_started means no send (#210 gap 7)" {
    // §6.1: a message sent into a caller-supplied id whose start reply was
    // lost may have been ACCEPTED by a foreign caller's fresh session — the
    // client's tracker matches it, but the registration was never admitted to
    // THIS client. Without an observed agent_started, probing could stop and
    // destroy that foreign session, so it sends nothing.
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — admission never observed

    const result = try client.sendAgentStopProbing(sid, "timeout");
    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(usize, 2), harness.writes.items.len); // start + message only — no stop
    try std.testing.expect(!client.stop_probes_by_session.contains(sid));
}

test "AgentProtocolClient pipelined sends roll back monotonically to the oldest rejection floor (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1
    const first_id = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2
    const second_id = try client.sendAgentMessage(sid, "{\"m\":2}", null); // seq 3, tracker 4

    // The first message is rejected busy (no advance): the reply still finds
    // ITS pending send even though a later send was recorded.
    var busy = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = first_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_busy, .message = try allocator.dupe(u8, "session already processing a message") } },
    };
    defer busy.deinit(allocator);
    try client.processEnvelope(busy);
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid)); // min(4, 2)

    // The second is rejected invalid_sequence (the server still expects 2):
    // the rollback may not raise the floor the older rejection established.
    var invalid = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = second_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer invalid.deinit(allocator);
    try client.processEnvelope(invalid);
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid)); // min(2, 3) = 2

    // The corrected retry reuses the floor sequence.
    _ = try client.sendAgentMessage(sid, "{\"m\":1-fixed}", null);
    var retried = try harness.envelopeAt(3);
    defer retried.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), retried.sequence);
}

test "AgentProtocolClient probing stop consumes the retry's own rejection and marks a vanished session complete (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1
    // Admission evidence (§6.1, #210 gap 7): the probe reconciles a message
    // send only against a registration whose agent_started this observed.
    var started_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = sid } },
    };
    defer started_env.deinit(allocator);
    try client.processEnvelope(started_env);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2

    const probe_stop_id = try client.sendAgentStopProbing(sid, "timeout");
    // First stop rejected invalid_request → the retry (sequence 3) goes out
    // and the probe re-registers in its final phase.
    var first_rejection = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = probe_stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer first_rejection.deinit(allocator);
    try client.processEnvelope(first_rejection);
    try std.testing.expectEqual(@as(usize, 4), harness.writes.items.len); // start, message, stop(2), stop(3)
    try std.testing.expect(client.stop_probes_by_session.contains(sid)); // final-phase entry awaits the retry's reply

    // The session vanished between the two stops: the retry answers
    // correlated agent_not_found. The reply must be CONSUMED (no false run
    // error), clear the sequence state, and mark the session complete — no
    // agent_stopped can ever follow.
    const second_stop_id = blk: {
        var env = try harness.envelopeAt(3);
        defer env.deinit(allocator);
        break :blk env.message_id;
    };
    var second_rejection = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = second_stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_not_found, .message = try allocator.dupe(u8, "session not found") } },
    };
    defer second_rejection.deinit(allocator);
    try client.processEnvelope(second_rejection);
    try std.testing.expectEqual(@as(usize, 4), harness.writes.items.len); // bounded: no third stop
    try std.testing.expect(!client.stop_probes_by_session.contains(sid));
    try std.testing.expect(client.isSessionComplete(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));
}

test "AgentProtocolClient correlated agent_not_found on a plain stop clears the tracked sequence state (#210 gap 7)" {
    // The reply names the STOP's message id, which the client does not track
    // in its pending sends — the not-found cleanup must not depend on
    // matching a counter-advancing send, or the stale counter would make a
    // re-registration of the id start at sequence 2/3 and fail its start.
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1, tracker 2
    const stop_id = try client.sendAgentStop(sid, "completed"); // sequence 2

    var rejection = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_not_found, .message = try allocator.dupe(u8, "session not found") } },
    };
    defer rejection.deinit(allocator);
    try client.processEnvelope(rejection);

    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));
    try std.testing.expect(!client.pending_sends_by_session.contains(sid));
}

test "AgentProtocolClient stop sends never advance the tracker (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1
    // Admission evidence (§6.1, #210 gap 7): the probe reconciles a message
    // send only against a registration whose agent_started this observed.
    var started_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = sid } },
    };
    defer started_env.deinit(allocator);
    try client.processEnvelope(started_env);
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
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
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
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
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
