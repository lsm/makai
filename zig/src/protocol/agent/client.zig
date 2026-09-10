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

/// Every tracked request send for a session whose outcome is still
/// unresolved, so a correlated reply can be tied to this client's own
/// request (§13.1: a rejected counter-advancing request never advances the
/// server's expected counter, so a corrected retry reuses the sequence;
/// #210 gap 7, slice 1 of the client sequence-control series).
/// Counter-advancing sends (`agent_start`/`agent_message`) are the rollback
/// targets — all outstanding sends are tracked (not just the latest), and
/// the rollback takes the minimum so an older unresolved send's floor is
/// never lost to a younger send's rejection. Ordinary stops never advance
/// the counter, so their records exist purely so their OWN replies — a
/// session-gone answer discovering the eviction through the stop, or a
/// rejection — reach the handling above instead of being ignored (their
/// rejection rollback is naturally a no-op: a stop carries the tracker's
/// own value).
const PendingSendKind = enum { start, message, stop };

const PendingSend = struct {
    msg_id: agent_types.Ulid,
    sequence: u64,
    kind: PendingSendKind,
    /// The tracker's value BEFORE this send's optimistic mirror: a rejected
    /// send's rollback restores it (rather than min'ing the send's own
    /// optimistic value) when the tracker still holds only this send's
    /// mirror — an explicit resend at an older sequence regresses the
    /// tracker to sequence+1, and min'ing that regression against the
    /// pre-send value would pin the client below the server's counter
    /// forever (#210 gap 7).
    prior_tracker: u64,
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

        self.* = undefined;
    }

    pub fn setSender(self: *Self, sender: transport.AsyncSender) void {
        self.sender = sender;
    }

    /// The next sequence the server is expected to accept for the session: 1
    /// before any send, the sent value + 1 after each counter-advancing send
    /// (optimistic — a correlated rejection rolls it back, §13.1; #210 gap 7).
    pub fn peekNextSequence(self: *Self, session_id: agent_types.SessionId) u64 {
        return self.next_sequence_by_session.get(session_id) orelse 1;
    }

    /// Records a send BEFORE it is written to the wire, so the post-send
    /// bookkeeping is infallible: an allocation failure here errors out with
    /// nothing on the wire, never after the server may have accepted the
    /// send (#210 gap 7).
    fn recordPendingSend(self: *Self, session_id: agent_types.SessionId, msg_id: agent_types.Ulid, sequence: u64, kind: PendingSendKind, prior_tracker: u64) !void {
        const gop = try self.pending_sends_by_session.getOrPut(session_id);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(PendingSend).empty;
        try gop.value_ptr.append(self.allocator, .{ .msg_id = msg_id, .sequence = sequence, .kind = kind, .prior_tracker = prior_tracker });
    }

    pub fn sendAgentStart(self: *Self, config_json: []const u8, system_prompt: ?[]const u8) !agent_types.Ulid {
        const sid = agent_types.generateSessionId();
        return self.sendAgentStartWithSession(sid, config_json, system_prompt);
    }

    pub fn sendAgentStartWithSession(self: *Self, sid: agent_types.SessionId, config_json: []const u8, system_prompt: ?[]const u8) !agent_types.Ulid {
        const msg_id = agent_types.generateUlid();

        // Build the fallible payload BEFORE any tracker mutation (see
        // sendAgentMessage): an allocation failure here leaves the client
        // state untouched, so a retry reuses the same sequence instead of
        // running ahead of the server (#210 gap 7).
        var payload = agent_types.Payload{ .agent_start = .{ .config_json = try self.allocator.dupe(u8, config_json), .session_id = sid } };
        defer payload.deinit(self.allocator);
        if (system_prompt) |sp| {
            payload.agent_start.system_prompt = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, sp));
        }

        const seq = self.peekNextSequence(sid);
        const start_json = try self.serializeEnvelopeForSend(.{
            .session_id = sid,
            .message_id = msg_id,
            .sequence = seq,
            .timestamp = compat.time.nowMillis(),
            .payload = payload,
        });
        defer self.allocator.free(start_json);
        try self.next_sequence_by_session.put(sid, seq + 1);
        self.sequence = seq; // compatibility mirror
        self.recordPendingSend(sid, msg_id, seq, .start, seq) catch |err| {
            // Nothing reached the wire: restore the tracker so a retry of the
            // start reuses `seq` instead of running ahead of the server.
            self.next_sequence_by_session.put(sid, seq) catch {};
            return err;
        };

        try self.writeEnvelopeJson(start_json);

        return msg_id;
    }

    pub fn sendAgentMessage(self: *Self, session_id: agent_types.SessionId, message_json: []const u8, options_json: ?[]const u8) !agent_types.Ulid {
        const seq = self.peekNextSequence(session_id);
        return self.sendAgentMessageWithSequence(session_id, message_json, options_json, seq);
    }

    /// Sends an `agent_message` carrying an EXPLICIT inbound sequence (#210
    /// gap 7): recovery paths that know which counter state the server holds
    /// are not forced to guess. The tracker mirrors the explicit value
    /// optimistically; a correlated rejection rolls it back so a corrected
    /// retry reuses the same sequence (§13.1).
    pub fn sendAgentMessageWithSequence(self: *Self, session_id: agent_types.SessionId, message_json: []const u8, options_json: ?[]const u8, sequence: u64) !agent_types.Ulid {
        // The tracker mirrors sequence + 1 optimistically: an un-advanceable
        // explicit value would overflow it (panicking in safety-checked
        // builds, wrapping to zero otherwise), so it is rejected before any
        // mutation or wire write (#210 gap 7).
        if (sequence == std.math.maxInt(u64)) return error.InvalidSequence;
        const msg_id = agent_types.generateUlid();

        // Build the fallible payload BEFORE any tracker mutation: an
        // allocation failure here leaves the client state untouched, so a
        // retry reuses the same sequence instead of running ahead of the
        // server (#210 gap 7).
        var payload = agent_types.Payload{ .agent_message = .{
            .session_id = session_id,
            .message_json = try self.allocator.dupe(u8, message_json),
        } };
        defer payload.deinit(self.allocator);
        if (options_json) |opts| payload.agent_message.options_json = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, opts));

        const message_json_buf = try self.serializeEnvelopeForSend(.{
            .session_id = session_id,
            .message_id = msg_id,
            .sequence = sequence,
            .timestamp = compat.time.nowMillis(),
            .payload = payload,
        });
        defer self.allocator.free(message_json_buf);
        // The PRE-SEND tracker state, restored when the pending-send record
        // cannot be allocated: an explicit sequence may legitimately differ
        // from it (a recovery path that knows the server's counter), and
        // leaving the caller-supplied value behind on a failure that reached
        // no wire would poison the tracker — a fresh client that tried
        // sequence 7 would send its next ordinary message at an invalid
        // counter (#210 gap 7).
        const prior_sequence = self.peekNextSequence(session_id);
        const prior_mirror = self.sequence;
        try self.next_sequence_by_session.put(session_id, sequence + 1);
        self.sequence = sequence; // compatibility mirror
        self.recordPendingSend(session_id, msg_id, sequence, .message, prior_sequence) catch |err| {
            // Nothing reached the wire: restore the PRE-SEND state so the
            // client is exactly as it was before the failed attempt (#210
            // gap 7).
            self.next_sequence_by_session.put(session_id, prior_sequence) catch {};
            self.sequence = prior_mirror;
            return err;
        };

        try self.writeEnvelopeJson(message_json_buf);
        return msg_id;
    }

    /// Sends an `agent_stop` at the tracker's current expected sequence. A
    /// stop consumes the counter together with the session when accepted and
    /// never advances it when rejected (§13.1), so unlike start/message sends
    /// this does not advance the tracker — a rejected stop leaves the expected
    /// value in place for the retry (#210 gap 7).
    pub fn sendAgentStop(self: *Self, session_id: agent_types.SessionId, reason: ?[]const u8) !agent_types.Ulid {
        const msg_id = agent_types.generateUlid();

        var payload = agent_types.Payload{ .agent_stop = .{ .session_id = session_id } };
        defer payload.deinit(self.allocator);
        if (reason) |r| payload.agent_stop.reason = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, r));

        const sequence = self.peekNextSequence(session_id);
        const json = try self.serializeEnvelopeForSend(.{
            .session_id = session_id,
            .message_id = msg_id,
            .sequence = sequence,
            .timestamp = compat.time.nowMillis(),
            .payload = payload,
        });
        defer self.allocator.free(json);
        // The stop is tracked like any other own request — a stop never
        // advances the counter, so the record exists purely so its OWN
        // replies reach the handling: a session-gone answer naming the stop
        // (an eviction discovered through the teardown) drops the session's
        // counter state, instead of leaving a stale value that a
        // re-registration of the same id would send and have rejected
        // (#210 gap 7). Recorded BEFORE the wire so a record failure leaves
        // nothing sent. The deprecated compatibility mirror reflects the
        // emitted value like the start/message paths, without advancing the
        // per-session tracker.
        self.sequence = sequence; // compatibility mirror
        try self.recordPendingSend(session_id, msg_id, sequence, .stop, self.peekNextSequence(session_id));
        try self.writeEnvelopeJson(json);
        return msg_id;
    }

    /// Serializes an envelope for sending, failing BEFORE anything is
    /// written (no sender configured, serialization allocation) — callers
    /// perform their fallible serialization here, before any tracker
    /// mutation, so a failure leaves the client state untouched (#210
    /// gap 7). The returned buffer is caller-owned.
    fn serializeEnvelopeForSend(self: *Self, env: agent_types.Envelope) ![]u8 {
        if (self.sender == null) return error.NoSender;
        return try envelope.serializeEnvelope(env, self.allocator);
    }

    /// Writes an already-serialized envelope. Failures here are AMBIGUOUS
    /// (the write may have partially delivered), so callers keep their
    /// optimistic tracker state through them (§13.4.6 unknown outcome).
    fn writeEnvelopeJson(self: *Self, json: []const u8) !void {
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
                // The start's outcome resolved (accepted): retire its pending
                // record so long-lived sessions do not accumulate resolved
                // sends (#210 gap 7).
                self.retirePendingSend(p.session_id, env.in_reply_to);
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
                // Reconcile the CONSUMED frame BEFORE the fallible
                // bookkeeping: a settlement resolves the settled run's own
                // message send, so its record retires even when the result
                // copy or the session-scoped diagnostics cannot be allocated
                // — a stale entry would otherwise floor a LATER rejection
                // too low and grow without bound over a long-lived session
                // (#210 gap 7).
                self.retireSettledPendingSends(env.session_id);
                self.last_result_json.deinit(self.allocator);
                self.last_result_json = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, json));
                try self.setSessionResult(env.session_id, json);
            },
            .agent_error => |e| {
                // Roll the tracker back BEFORE the fallible error bookkeeping:
                // the rejection envelope is already consumed, so an allocation
                // failure in the diagnostics must not leave the optimistic
                // counter and pending record in place against a server that
                // rejected them (#210 gap 7).
                try self.handleCorrelatedRejection(env.session_id, env.in_reply_to, e.code);
                self.last_error.deinit(self.allocator);
                self.last_error = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, e.message));
                try self.setSessionError(env.session_id, e.message);
            },
            .agent_stopped => |p| {
                if (self.session_id) |sid| {
                    if (std.mem.eql(u8, sid[0..], p.session_id[0..])) self.session_id = null;
                }
                _ = self.next_sequence_by_session.remove(p.session_id);
                // The session is gone with its counter — the tracked
                // requests (the accepted stop included) are meaningless.
                if (self.pending_sends_by_session.fetchRemove(p.session_id)) |entry| {
                    var list = entry.value;
                    list.deinit(self.allocator);
                }
                try self.session_complete_flags.put(p.session_id, true);
            },
            else => {},
        }
    }

    /// Retires the pending-send record whose request a reply names (e.g. the
    /// `agent_started` replying to an `agent_start`) — its outcome resolved.
    fn retirePendingSend(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid) void {
        const reply_to = in_reply_to orelse return;
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return;
        for (list.items, 0..) |pending, index| {
            if (!std.mem.eql(u8, &reply_to, &pending.msg_id)) continue;
            _ = list.orderedRemove(index);
            return;
        }
    }

    /// Retires the pending-send record a settlement resolves: the settled
    /// run's own message. That message is the OLDEST pending message-kind
    /// send — it was admitted (hence sent) before any later pipelined send
    /// could be attempted against the one-active-run rule (§13.2.4) — so
    /// exactly the oldest message entry retires and every LATER unresolved
    /// send is kept for its own reply. Serial use degenerates to retiring
    /// the sole message, so a long-lived session's records stay bounded by
    /// its unresolved sends, not its history (#210 gap 7).
    fn retireSettledPendingSends(self: *Self, session_id: agent_types.SessionId) void {
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return;
        for (list.items, 0..) |pending, index| {
            if (pending.kind != .message) continue;
            _ = list.orderedRemove(index);
            return;
        }
    }

    /// Applies #210 gap 7's client sequence-control rules to a correlated
    /// rejection (an `agent_error` whose `in_reply_to` names this client's
    /// own send): a rejected counter-advancing send rolls the tracker back so
    /// a corrected retry reuses the same sequence (§13.1 — a rejected request
    /// never advances the server's expected counter). ALL outstanding sends
    /// are matched (a pipelined send's reply may arrive after a later send
    /// was recorded), and the rollback takes the MINIMUM of the tracker and
    /// the rejected send's sequence: an older unresolved send's floor must
    /// never be lost to a younger send's rejection.
    fn handleCorrelatedRejection(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid, code: ?agent_types.AgentErrorCode) !void {
        const reply_to = in_reply_to orelse return;

        const list = self.pending_sends_by_session.getPtr(session_id) orelse return;
        var matched: ?usize = null;
        for (list.items, 0..) |pending, index| {
            if (std.mem.eql(u8, &reply_to, &pending.msg_id)) {
                matched = index;
                break;
            }
        }
        const index = matched orelse return;

        // agent_not_found (or session_expired — the idle-TTL eviction answer)
        // means the session is gone server-side, so its tracked sequence
        // state is meaningless. Drop it — a re-registration of the id must
        // start at sequence 1, not the stale optimistic counter.
        const session_gone = if (code) |c| c == .agent_not_found or c == .session_expired else false;
        if (session_gone) {
            _ = self.next_sequence_by_session.remove(session_id);
            if (self.pending_sends_by_session.fetchRemove(session_id)) |entry| {
                var pending_list = entry.value;
                pending_list.deinit(self.allocator);
            }
            return;
        }

        const rejected = list.items[index];
        _ = list.orderedRemove(index);
        // A correlated `agent_busy` proves the server's counter EQUALS the
        // rejected sequence: the server validates the inbound sequence
        // BEFORE the processing state (handleMessage), so a busy answer
        // means the sequence MATCHED — every lower sequence was consumed —
        // and busy never advances the counter (§13.1). This matters most
        // for an EXPLICIT recovery send: rolling it back to its pre-send
        // tracker (a stale 1 against a server at 7) would have the retry
        // replay the stale value instead of the busy-proven sequence
        // (#210 gap 7).
        const busy = if (code) |c| c == .agent_busy else false;
        if (busy) {
            try self.next_sequence_by_session.put(session_id, rejected.sequence);
            return;
        }
        // The rollback restores the counter the server RETAINED — the
        // record's pre-send tracker — rather than min'ing the send's own
        // optimistic mirror unconditionally: a BACKWARD explicit send
        // regressed the tracker to sequence+1 before the wire, and min'ing
        // that regression against the pre-send value would pin the client
        // below the server's counter forever (a forward explicit send's
        // 999-mirror has the same shape). The CURRENT map value participates
        // as the floor when something OTHER than this send's own mirror
        // produced it (§13.1 — a rejected request never advances the
        // server's expected counter; #210 gap 7). The successor comparison
        // is overflow-safe: an explicit maxInt-1 message leaves the tracker
        // at maxInt and an immediately queued stop can be recorded there,
        // so `sequence + 1` must never be evaluated for the maximum.
        const current = self.peekNextSequence(session_id);
        const mirror_is_own = rejected.sequence != std.math.maxInt(u64) and current == rejected.sequence + 1;
        const base = if (mirror_is_own) rejected.prior_tracker else current;
        const floor = @min(base, rejected.prior_tracker);
        try self.next_sequence_by_session.put(session_id, floor);
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
        if (self.pending_sends_by_session.fetchRemove(session_id)) |entry| {
            var list = entry.value;
            list.deinit(self.allocator);
        }

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

test "AgentProtocolClient correlated agent_not_found drops the counter state for re-registration (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1
    const msg_id = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2, tracker 3

    // A tracked request answered agent_not_found: the session is gone
    // server-side, so its tracked sequence state is meaningless — drop it; a
    // re-registration of the id must start its next start at sequence 1.
    var gone = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = msg_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_not_found, .message = try allocator.dupe(u8, "session not found") } },
    };
    defer gone.deinit(allocator);
    try client.processEnvelope(gone);

    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // re-registration restarts at 1
    var restarted = try harness.envelopeAt(2);
    defer restarted.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), restarted.sequence);
}

test "AgentProtocolClient stop sends never advance the tracker (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1
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
    // advances it when rejected — the stop carries the tracker's current
    // expected value and the tracker is unchanged by the send. The
    // deprecated compatibility mirror reflects the emitted value.
    _ = try client.sendAgentStop(sid, "completed");
    var stop_env = try harness.envelopeAt(2);
    defer stop_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), stop_env.sequence);
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    try std.testing.expectEqual(@as(u64, 3), client.sequence);

    // The accepted stop consumes the tracked requests with the session.
    var stopped_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 4,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_stopped = .{ .session_id = sid } },
    };
    defer stopped_env.deinit(allocator);
    try client.processEnvelope(stopped_env);
    try std.testing.expect(!client.pending_sends_by_session.contains(sid));
}

test "AgentProtocolClient session-gone answer to a stop drops the counter for re-registration (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2, tracker 3
    const stop_id = try client.sendAgentStop(sid, "teardown"); // stop@3, tracked

    // An idle-TTL eviction discovered through the stop: the correlated
    // agent_not_found names the client's own stop, and the session-gone
    // handling must run — without tracking the stop, the stale counter would
    // survive and a re-registration of the same id would send it and be
    // rejected by the fresh session.
    var gone = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_not_found, .message = try allocator.dupe(u8, "session not found") } },
    };
    defer gone.deinit(allocator);
    try client.processEnvelope(gone);

    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // re-registration restarts at 1
    var restarted = try harness.envelopeAt(3);
    defer restarted.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), restarted.sequence);
}

test "AgentProtocolClient settlement retires the settled run's own message record (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1
    var started_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .in_reply_to = start_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = sid } },
    };
    defer started_env.deinit(allocator);
    try client.processEnvelope(started_env); // retires the start's record
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2, tracker 3

    // The run settles: the settled run's own message retires, so a
    // long-lived session's records stay bounded by its unresolved sends —
    // without retirement every completed turn would leave a record behind.
    var result_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer result_env.deinit(allocator);
    try client.processEnvelope(result_env);

    const remaining = if (client.pending_sends_by_session.getPtr(sid)) |l| l.items.len else 0;
    try std.testing.expectEqual(@as(usize, 0), remaining);

    // The tracker itself is untouched by the settlement.
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);
    var next_env = try harness.envelopeAt(2); // start, m1, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), next_env.sequence);
}

test "AgentProtocolClient explicit-sequence sends carry the given value and roll back on rejection (#210 gap 7)" {
    // Recovery paths that know the server's counter state are not forced to
    // guess: the explicit sequence is carried verbatim (the SERVER still
    // rejects true duplicates — the client sends exactly what it is told),
    // and a correlated rejection restores the counter the server RETAINED —
    // the record's pre-send tracker, not the rejected send's own value.
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
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
    // The pre-send tracker (1 for a fresh session) — the server never
    // advanced past 1, and replaying 7 would repeat the invalid counter.
    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));
}

test "AgentProtocolClient explicit-sequence send failure restores the PRE-SEND tracker state (#210 gap 7)" {
    // A recovery path may send an explicit sequence far from the tracker's
    // value; when the pre-wire bookkeeping cannot be allocated, nothing
    // reached the wire, so the client must end up exactly as before the
    // attempt. Storing the CALLER-SUPPLIED value instead would leave a
    // fresh client's tracker at 7 while the server still expected 1 —
    // every later ordinary send carried an invalid counter. Sweep every
    // pre-wire allocation failure: each must leave the tracker at its
    // pre-send state.
    const allocator = std.testing.allocator;
    const sid = agent_types.generateSessionId();
    var exercised_failure = false;
    for (0..8) |fail_index| {
        var harness = Gap7Harness.init();
        defer harness.deinit();
        harness.wire();
        const client = &harness.client;
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        client.allocator = failing.allocator();
        const sent = client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 7);
        client.allocator = allocator;
        const failed = if (sent) |_| false else |_| true;
        if (!failed) continue;
        exercised_failure = true;
        try std.testing.expectEqual(@as(usize, 0), harness.writes.items.len); // nothing on the wire
        try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid)); // the PRE-send state
    }
    try std.testing.expect(exercised_failure); // the sweep actually hit the failure paths
}

test "AgentProtocolClient rejects an un-advanceable explicit sequence before any mutation (#210 gap 7)" {
    // The tracker mirrors sequence + 1 optimistically: maxInt(u64) would
    // overflow it (panic in safety-checked builds, wrap to zero otherwise).
    // The send is rejected before any mutation or wire write.
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1, tracker 2
    var started_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .in_reply_to = start_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = sid } },
    };
    defer started_env.deinit(std.testing.allocator);
    try client.processEnvelope(started_env);

    try std.testing.expectError(error.InvalidSequence, client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid)); // untouched
    try std.testing.expectEqual(@as(usize, 1), harness.writes.items.len); // the start only — nothing sent
}

test "AgentProtocolClient agent_busy rejection of an explicit send preserves the busy-proven sequence (#210 gap 7)" {
    // A busy answer proves the sequence MATCHED the server's counter (the
    // server validates the sequence before the processing state), so an
    // explicit recovery send answered busy must leave the tracker AT that
    // sequence: rolling it back to the (stale) pre-send tracker would have
    // the retry replay the stale value instead of the busy-proven one.
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const msg_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 7); // stale local tracker 1, server at 7

    var busy = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = msg_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_busy, .message = try allocator.dupe(u8, "session already processing a message") } },
    };
    defer busy.deinit(allocator);
    try client.processEnvelope(busy);
    try std.testing.expectEqual(@as(u64, 7), client.peekNextSequence(sid)); // the busy-proven sequence, not the stale prior 1

    // The retry carries the busy-proven sequence.
    _ = try client.sendAgentMessage(sid, "{\"m\":1-retry}", null);
    var retried = try harness.envelopeAt(1);
    defer retried.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 7), retried.sequence);
}
