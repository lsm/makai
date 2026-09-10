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
/// `agent_message` outcome the cleanup stop sweeps the REACHABLE server
/// counter states, lowest candidate first — a correlated `invalid_request`
/// rejection naming the probe's current stop advances to `next_sequence`,
/// up to `ceiling` inclusive. Serial use spans exactly two states (the
/// floor and one past it); pipelined sends whose settlements this client
/// has not yet consumed can leave the server at ANY value in between, so
/// the sweep is bounded by the pending-send count, not fixed at two. A
/// session that vanished mid-sweep answers `agent_not_found`; exhausting
/// the ceiling retires the probe — either way the replies are consumed as
/// cleanup mechanics, never surfaced as run errors.
const StopProbe = struct {
    first_msg_id: agent_types.Ulid,
    /// The candidate for the NEXT retry (the current stop carries
    /// `next_sequence - 1` at registration).
    next_sequence: u64,
    /// The last candidate, inclusive — max(tracker, newest pending message
    /// send + 1): every server state the unresolved sends can occupy.
    ceiling: u64,
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

    /// Whether a bounded stop probe is still in flight for the session
    /// (either phase). Teardown paths that started a probe pump incoming
    /// frames until this clears — the post-send retry is emitted from
    /// `processEnvelope` when the first stop's correlated rejection arrives
    /// (#210 gap 7).
    pub fn hasActiveStopProbe(self: *Self, session_id: agent_types.SessionId) bool {
        return self.stop_probes_by_session.contains(session_id);
    }

    /// The next sequence the server is expected to accept for the session: 1
    /// before any send, the sent value + 1 after each counter-advancing send
    /// (optimistic — a correlated rejection rolls it back, §13.1).
    pub fn peekNextSequence(self: *Self, session_id: agent_types.SessionId) u64 {
        return self.next_sequence_by_session.get(session_id) orelse 1;
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

        // Build the fallible payload BEFORE any tracker mutation (see
        // sendAgentMessageWithSequence).
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
        self.recordPendingSend(sid, msg_id, seq, .start) catch |err| {
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
    /// (e.g. after a probe) are not forced to guess. The tracker mirrors the
    /// explicit value optimistically; a correlated rejection rolls it back so
    /// a corrected retry reuses the same sequence (§13.1).
    pub fn sendAgentMessageWithSequence(self: *Self, session_id: agent_types.SessionId, message_json: []const u8, options_json: ?[]const u8, sequence: u64) !agent_types.Ulid {
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
        try self.next_sequence_by_session.put(session_id, sequence + 1);
        self.sequence = sequence; // compatibility mirror
        self.recordPendingSend(session_id, msg_id, sequence, .message) catch |err| {
            // Nothing reached the wire: restore the tracker so a retry of the
            // same message reuses `sequence` instead of running ahead of the
            // server (#210 gap 7).
            self.next_sequence_by_session.put(session_id, sequence) catch {};
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

        const json = try self.serializeEnvelopeForSend(.{
            .session_id = session_id,
            .message_id = msg_id,
            .sequence = sequence,
            .timestamp = compat.time.nowMillis(),
            .payload = payload,
        });
        defer self.allocator.free(json);
        try self.writeEnvelopeJson(json);
    }

    /// Bounded stop-probe sweep for an UNCORRELATED `agent_message` outcome
    /// (#210 gap 7, §13.4.1): the cleanup stop first tries the FLOOR counter
    /// state (the minimum of the oldest unresolved message send's sequence
    /// and the tracker's rolled-back value — the message may have been
    /// rejected with the counter rolled back), and each correlated
    /// `invalid_request` rejection processed through `processEnvelope`
    /// advances the sweep to the next candidate, at most up to the ceiling
    /// (max of the tracker and one past the newest pending send — pipelined
    /// sends whose settlements this client has not yet consumed can leave
    /// the server anywhere in between). The retry's own replies are consumed
    /// the same way; acceptance at any candidate settles cleanup, and no
    /// other reply retries. Serial use spans exactly the classic two states
    /// (floor, floor+1).
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
        // An in-flight probe wins over re-eligibility: a settlement or run
        // output may have retired the pending message the probe is still
        // reconciling, and a second teardown caller must not fall back to a
        // racing plain stop at the same candidate sequence (#210 gap 7).
        if (self.stop_probes_by_session.get(session_id)) |existing| {
            return existing.first_msg_id;
        }
        if (self.admitted_by_session.get(session_id) != true) return null;
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return null;
        // The sweep spans every server state the unresolved sends can still
        // occupy. Its FLOOR is the oldest unresolved message's sequence,
        // capped by the tracker's rolled-back value: when a rejection is
        // processed BEFORE an older send's settlement (sends 2/3/4
        // pipelined, 3 rejected while 2's settlement is in flight, then 2
        // settles and 4's reply is lost), the surviving entry holds its
        // optimistic 4 while the server expects 3 — the floor the rollback
        // already recorded; the entry's naive 4/5 pair would overshoot both.
        // Its CEILING is max(tracker, newest entry + 1): a second message
        // sent after the server settled the first (§13.2.3 returns it to
        // ready) but before this client consumed that settlement can be
        // accepted sequentially, leaving the server at a value BETWEEN the
        // floor and one-past-the-newest — a fixed two-state probe would miss
        // it and leak the session. The sweep adds at most one stop per
        // pending send above the floor (#210 gap 7).
        var oldest_message_sequence: ?u64 = null;
        var newest_message_sequence: u64 = 0;
        for (list.items) |pending| {
            if (pending.kind != .message) continue;
            if (oldest_message_sequence == null) oldest_message_sequence = pending.sequence;
            newest_message_sequence = @max(newest_message_sequence, pending.sequence);
        }
        const entry_sequence = oldest_message_sequence orelse return null;
        const pre_send = @min(entry_sequence, self.peekNextSequence(session_id));
        const ceiling = @max(self.peekNextSequence(session_id), newest_message_sequence + 1);

        // Pre-wire phase — every failure here happens with NOTHING on the
        // wire, so nothing is registered and the caller sees a clean error:
        // build the stop payload and serialize it before touching the probe
        // map. The reason buffer has exactly one owner at every point (the
        // local variable until the map insert succeeds, the entry after).
        const msg_id = agent_types.generateUlid();
        var payload = agent_types.Payload{ .agent_stop = .{ .session_id = session_id } };
        defer payload.deinit(self.allocator);
        if (reason) |r| payload.agent_stop.reason = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, r));
        const stop_json = try self.serializeEnvelopeForSend(.{
            .session_id = session_id,
            .message_id = msg_id,
            .sequence = pre_send,
            .timestamp = compat.time.nowMillis(),
            .payload = payload,
        });
        defer self.allocator.free(stop_json);

        var owned_reason = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, reason orelse ""));
        var reason_owned_by_map = false;
        errdefer if (!reason_owned_by_map) owned_reason.deinit(self.allocator);
        try self.stop_probes_by_session.put(session_id, .{
            .first_msg_id = msg_id,
            .next_sequence = pre_send + 1,
            .ceiling = ceiling,
            .reason = owned_reason,
        });
        reason_owned_by_map = true;

        // Wire phase — a write/flush failure here is AMBIGUOUS (the stop may
        // already have reached the peer), so the probe stays registered: the
        // correlated rejection of a delivered pre-send stop must still
        // trigger the post-send retry, and a teardown driver still sees an
        // active probe to pump. The write error itself is swallowed — the
        // probe's bounded lifecycle owns the outcome now (#210 gap 7).
        self.writeEnvelopeJson(stop_json) catch {};
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
        // Allocate the replacement BEFORE releasing the existing value
        // (mirrors the last_error arms): a failed dupe after the deinit would
        // leave the map slot holding a deinit'd slice that a later update,
        // clear, or deinit would double-free (#210 gap 7). The flag DISARMS
        // the cleanup the moment the map takes ownership, so a later failure
        // in this function (the complete-flags put) cannot free the stored
        // slice.
        var owned = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, msg));
        var owned_by_map = false;
        errdefer if (!owned_by_map) owned.deinit(self.allocator);
        if (self.session_last_errors.getPtr(session_id)) |existing| {
            existing.deinit(self.allocator);
            existing.* = owned;
            owned_by_map = true;
        } else {
            try self.session_last_errors.put(session_id, owned);
            owned_by_map = true;
        }
        try self.session_complete_flags.put(session_id, true);
    }

    fn setSessionResult(self: *Self, session_id: agent_types.SessionId, result_json: []const u8) !void {
        // Same allocate-before-release, disarm-on-transfer ordering as
        // setSessionError.
        var owned = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, result_json));
        var owned_by_map = false;
        errdefer if (!owned_by_map) owned.deinit(self.allocator);
        if (self.session_last_results.getPtr(session_id)) |existing| {
            existing.deinit(self.allocator);
            existing.* = owned;
            owned_by_map = true;
        } else {
            try self.session_last_results.put(session_id, owned);
            owned_by_map = true;
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
                // Deliberately NO pending-send retirement on run output: an
                // event cannot be tied to the run that produced it (a reused
                // id's previous run may still emit its trailing agent_end
                // after the next message was admitted, §13.4.3), so retiring
                // the sole pending send on an event can delete the NEW run's
                // record on a stale frame. The bounded probe — not
                // retirement — reconciles an unknown outcome, and its retry
                // round-trip is the price of that ambiguity (#210 gap 7).
            },
            .agent_result => |json| {
                // Reconcile the CONSUMED frame BEFORE the fallible
                // bookkeeping (the same rule as the agent_error arm): a
                // settlement retires the settled run's own send even when
                // the result copy or the session-scoped diagnostics cannot
                // be allocated — the envelope is already consumed, so a
                // stale pending entry would survive and bracket a LATER
                // lost-output probe from the wrong floor (#210 gap 7).
                self.retireSettledPendingSends(env.session_id);
                // Allocate the replacement BEFORE releasing the previous
                // value (same ordering rule as the error arms): a failed
                // dupe must not leave last_result_json undefined.
                const result_copy = try self.allocator.dupe(u8, json);
                self.last_result_json.deinit(self.allocator);
                self.last_result_json = OwnedSlice(u8).initOwned(result_copy);
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
                    // Roll the tracker back BEFORE the fallible error
                    // bookkeeping: the rejection envelope is already
                    // consumed, so an allocation failure in the diagnostics
                    // must not leave the optimistic counter and pending
                    // record in place against a server that rejected them.
                    try self.handleCorrelatedRejection(env.session_id, env.in_reply_to, e.code);
                    // An UNCORRELATED agent_error no longer retires the
                    // pending send (§13.4.1): it is either the settlement of
                    // an admitted run (§13.4.2) or an admission failure's
                    // unscoped runtime error with the counter rolled back —
                    // wire-identical. Retiring on the admission-failure side
                    // disarms the teardown probe (no unresolved send left),
                    // and the fallback plain stop at the optimistic value is
                    // rejected while the server still expects the pre-send
                    // value, leaking the session. Keeping the send pending
                    // lets the probe bracket both states; a real settlement
                    // pays one extra stop envelope (#210 gap 7).
                    // Allocate the replacement BEFORE releasing the previous
                    // value: a failed dupe must not leave last_error
                    // undefined (a later update or deinit would double-free).
                    const error_copy = try self.allocator.dupe(u8, e.message);
                    self.last_error.deinit(self.allocator);
                    self.last_error = OwnedSlice(u8).initOwned(error_copy);
                    try self.setSessionError(env.session_id, e.message);
                }
            },
            .nack => |n| {
                // A correlated nack is a request rejection like a correlated
                // agent_error (the fixture server and older peers use this
                // shape): probe replies are consumed first, and a nack
                // surfaces through the session-error bookkeeping ONLY when
                // it rejects one of this client's own start/message requests
                // — without it, a peer that rejects an ordinary
                // agent_message by nack would leave the TUI treating the
                // submit as accepted with no settlement ever coming. A nack
                // for a NON-run request (models, tool_list, ping, status —
                // e.g. a not_implemented capability answer) shares the
                // transport and can arrive mid-run: recording it as a
                // terminal session error makes the TUI abort a healthy
                // turn. Unrelated nacks stay request-scoped and are dropped
                // (#210 gap 7).
                if (!try self.handleProbeReply(env.session_id, env.in_reply_to, agentCodeFromNack(n.error_code))) {
                    if (!self.replyNamesPendingSend(env.session_id, env.in_reply_to)) return;
                    // Rollback first, then fallible bookkeeping (see the
                    // agent_error arm).
                    try self.handleCorrelatedRejection(env.session_id, env.in_reply_to, agentCodeFromNack(n.error_code));
                    const reason_copy = try self.allocator.dupe(u8, n.reason.slice());
                    self.last_error.deinit(self.allocator);
                    self.last_error = OwnedSlice(u8).initOwned(reason_copy);
                    try self.setSessionError(env.session_id, n.reason.slice());
                }
            },
            .agent_stopped => |p| {
                // A delayed agent_stopped can reply to an OLDER registration's
                // stop after the reused id has already started a new probe
                // whose own stop is still in flight: a reply correlated to a
                // DIFFERENT request than the active probe's current stop must
                // not tear the session's control state down — clearing the
                // probe would strand the CURRENT registration, whose
                // pre-send stop's rejection would then find no probe to
                // advance the sweep (#210 gap 7). An uncorrelated reply (a
                // lenient peer may omit in_reply_to for the probe's own
                // stop) still completes the probe.
                if (self.stop_probes_by_session.get(p.session_id)) |probe| {
                    if (env.in_reply_to) |reply_to| {
                        if (!std.mem.eql(u8, &reply_to, &probe.first_msg_id)) return;
                    }
                }
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
            // The shared protocol's invalid_sequence is the same wrong-counter
            // rejection the agent surface spells invalid_request — peers may
            // answer a stop either way, so both drive the probe's retry and
            // the tracker's rollback (#210 gap 7).
            .invalid_request, .invalid_sequence => .invalid_request,
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
    /// cleanup mechanics, not run failures). A correlated `invalid_request`
    /// advances the sweep to the next candidate while one remains at or below
    /// the ceiling, re-registering the probe so the new stop's OWN replies
    /// are consumed too. In any phase, `agent_not_found` drops the session's
    /// sequence state (the session is gone server-side — a re-registration of
    /// the id must start from sequence 1, not the stale optimistic counter)
    /// and marks the session complete: no `agent_stopped` can ever follow for
    /// a nonexistent session.
    fn handleProbeReply(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid, code: ?agent_types.AgentErrorCode) !bool {
        const reply_to = in_reply_to orelse return false;
        const probe = self.stop_probes_by_session.get(session_id) orelse return false;
        if (!std.mem.eql(u8, &reply_to, &probe.first_msg_id)) return false;

        const retry = probe.next_sequence <= probe.ceiling and (if (code) |c| c == .invalid_request else false);
        const session_gone = if (code) |c| c == .agent_not_found else false;
        const next_sequence = probe.next_sequence;
        const ceiling = probe.ceiling;
        var reason = probe.reason;
        _ = self.stop_probes_by_session.remove(session_id);
        defer reason.deinit(self.allocator);
        if (retry) {
            // Pre-wire phase for the next candidate (mirrors the first
            // stop): build and serialize BEFORE the re-registration, so a
            // pre-wire failure leaves the probe simply retired — nothing
            // reached the wire.
            const second_msg_id = agent_types.generateUlid();
            var retry_payload = agent_types.Payload{ .agent_stop = .{ .session_id = session_id } };
            defer retry_payload.deinit(self.allocator);
            retry_payload.agent_stop.reason = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, reason.slice()));
            const second_json = try self.serializeEnvelopeForSend(.{
                .session_id = session_id,
                .message_id = second_msg_id,
                .sequence = next_sequence,
                .timestamp = compat.time.nowMillis(),
                .payload = retry_payload,
            });
            defer self.allocator.free(second_json);
            // Consume the new stop's own replies. Registered BEFORE the
            // write so an AMBIGUOUS write failure keeps it — the rejection
            // of a delivered stop must still be consumed as probe control,
            // and teardown drivers keep an active probe to pump.
            try self.stop_probes_by_session.put(session_id, .{
                .first_msg_id = second_msg_id,
                .next_sequence = next_sequence + 1,
                .ceiling = ceiling,
                .reason = OwnedSlice(u8).initBorrowed(""),
            });
            self.writeEnvelopeJson(second_json) catch {};
        } else if (session_gone) {
            _ = self.next_sequence_by_session.remove(session_id);
            self.clearSessionControlState(session_id);
            try self.session_complete_flags.put(session_id, true);
        }
        return true;
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
    /// send is kept. The earliest remaining entry alone brackets the
    /// server's counter only when no rollback floor sits below it (sends
    /// 2/3/4 with 2 settled and 3/4 REJECTED leave an empty list and the
    /// plain tracked stop at the floor 3); when a later send's reply is
    /// merely lost, `sendAgentStopProbing` combines the surviving entry
    /// with the rolled-back floor for its bracket. Serial use degenerates
    /// to retiring the sole message, so the next turn starts from an empty
    /// list and its lost-output probe cannot be bracketed by the settled
    /// record's stale sequence.
    fn retireSettledPendingSends(self: *Self, session_id: agent_types.SessionId) void {
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return;
        for (list.items, 0..) |pending, index| {
            if (pending.kind != .message) continue;
            _ = list.orderedRemove(index);
            return;
        }
    }

    /// Whether `in_reply_to` names one of the session's tracked pending
    /// sends — i.e. the reply belongs to a request of the CURRENT
    /// registration (a start or message this client sent and has not yet
    /// resolved).
    fn replyNamesPendingSend(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid) bool {
        const reply_to = in_reply_to orelse return false;
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return false;
        for (list.items) |pending| {
            if (std.mem.eql(u8, &reply_to, &pending.msg_id)) return true;
        }
        return false;
    }

    /// Applies #210 gap 7's client sequence-control rules to a correlated
    /// rejection (an `agent_error`/`nack` whose `in_reply_to` names this
    /// client's own send): a rejected counter-advancing send rolls the tracker
    /// back so a corrected retry reuses the same sequence (§13.1 — a rejected
    /// request never advances the server's expected counter). ALL outstanding
    /// sends are matched (a pipelined send's reply may arrive after a later
    /// send was recorded), and the rollback takes the MINIMUM of the tracker
    /// and the rejected send's sequence: an older unresolved send's floor
    /// must never be lost to a younger send's rejection. The reply must name
    /// a request tracked for the CURRENT registration: on a quickly reused
    /// id, a delayed correlated `agent_not_found` (or rejection) from an
    /// older registration's message or stop must not clear the new
    /// registration's sequence, pending-send, and admission state — the next
    /// message would start again at sequence 1 against the live server
    /// session (#210 gap 7).
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

        const session_gone = if (code) |c| c == .agent_not_found else false;
        if (session_gone) {
            // A tracked request answered agent_not_found: the session is
            // gone server-side, so its tracked sequence state is meaningless.
            // Drop it — a re-registration of the id must start at sequence
            // 1, not the stale optimistic counter.
            _ = self.next_sequence_by_session.remove(session_id);
            self.clearSessionControlState(session_id);
            return;
        }

        const floor = @min(self.peekNextSequence(session_id), list.items[index].sequence);
        try self.next_sequence_by_session.put(session_id, floor);
        _ = list.orderedRemove(index);
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
    /// When set, the mock sender fails every write — simulating a transport
    /// failure after a send's bookkeeping is in place.
    fail_writes: bool = false,
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
        if (self.fail_writes) return error.WriteFailed;
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

test "AgentProtocolClient probing stop is idempotent while in flight (#210 gap 7)" {
    // Two teardown paths probing the same session before any reply arrives:
    // the second returns the in-flight stop's id instead of superseding it —
    // two stops at the same candidate sequence would race server-side and
    // the orphaned rejection would surface as a false session failure.
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
    defer started_env.deinit(std.testing.allocator);
    try client.processEnvelope(started_env);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2, tracker 3

    const first = try client.sendAgentStopProbing(sid, "timeout");
    const second = try client.sendAgentStopProbing(sid, "timeout");
    try std.testing.expect(first != null);
    try std.testing.expect(second != null);
    try std.testing.expectEqual(first.?, second.?);
    try std.testing.expectEqual(@as(usize, 3), harness.writes.items.len); // start, message, ONE stop
}

test "AgentProtocolClient settlements retire resolved pending sends (#210 gap 7)" {
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
        // The real agent_started is request-correlated — that is what retires
        // the start's own pending record here.
        .in_reply_to = start_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = sid } },
    };
    defer started_env.deinit(allocator);
    try client.processEnvelope(started_env);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2, tracker 3

    // The run settles with ONE pending send — the settled run's own message
    // (serial use): it resolved and is retired, so the next turn starts from
    // an empty list (no stale record can bracket a later lost-output probe).
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

    const remaining_serial = if (client.pending_sends_by_session.getPtr(sid)) |l| l.items.len else 0;
    try std.testing.expectEqual(@as(usize, 0), remaining_serial);

    // Two or more pending sends at settlement: the newest postdates the
    // settled run (recorded after the server committed, before this client
    // processed it) — its unknown outcome is retained for a later probe.
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null); // seq 2 again (serial retry)
    _ = try client.sendAgentMessage(sid, "{\"m\":3}", null); // seq 3, concurrently in flight
    var second_result = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 4,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer second_result.deinit(allocator);
    try client.processEnvelope(second_result);

    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len); // only the newest — possibly unresolved — send retained
}

test "AgentProtocolClient probing stop derives its candidates from the OLDEST unresolved message (#210 gap 7)" {
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null); // seq 3
    _ = try client.sendAgentMessage(sid, "{\"m\":3}", null); // seq 4 — all outcomes lost

    // The server accepted message 2 (counter 3) and rejected 3 and 4. The
    // oldest unresolved message (2) brackets the counter: stop(2) is
    // rejected, stop(3) is accepted — the NEWEST send's pair (4, 5) would
    // have missed both and leaked the session.
    const probe_result = try client.sendAgentStopProbing(sid, "timeout");
    const probe_stop_id = probe_result.?;
    var first_stop = try harness.envelopeAt(4);
    defer first_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), first_stop.sequence); // OLDEST message's sequence

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
    var second_stop = try harness.envelopeAt(5);
    defer second_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), second_stop.sequence); // oldest + 1 — accepted
}

test "AgentProtocolClient probing stop honors the rolled-back floor when a rejection precedes an older settlement (#210 gap 7)" {
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
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null); // seq 2
    const msg3 = try client.sendAgentMessage(sid, "{\"m\":3}", null); // seq 3
    _ = try client.sendAgentMessage(sid, "{\"m\":4}", null); // seq 4 — reply lost

    // The server accepted 2 (expected 3) and rejected 3 on its payload (no
    // advance). The client processes 3's rejection BEFORE 2's settlement:
    // the rollback floors the tracker at 3, and the settlement then retires
    // the OLDEST message (2), leaving only the optimistic entry 4 — whose
    // naive {4, 5} pair would overshoot the server's expected 3 entirely.
    var rejection3 = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = msg3,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "payload rejected") } },
    };
    defer rejection3.deinit(allocator);
    try client.processEnvelope(rejection3);
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));

    var settled2 = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 9,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer settled2.deinit(allocator);
    try client.processEnvelope(settled2);

    // The probe's first stop must carry the rolled-back FLOOR — min(entry 4,
    // tracker 3) — so the two candidates bracket {3, 4}, the states the wire
    // can still occupy; the pre-fix entry pair {4, 5} missed 3 and the
    // session leaked.
    const probe_result = try client.sendAgentStopProbing(sid, "timeout");
    const probe_stop_id = probe_result.?;
    var first_stop = try harness.envelopeAt(4);
    defer first_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), first_stop.sequence);

    // The floor stop's correlated rejection (the entry-4-accepted case still
    // live) retries at exactly one past the floor.
    var stop_rejection = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = probe_stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer stop_rejection.deinit(allocator);
    try client.processEnvelope(stop_rejection);
    var second_stop = try harness.envelopeAt(5);
    defer second_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 4), second_stop.sequence); // floor + 1
}

test "AgentProtocolClient settlement retires the pending send even when the result bookkeeping allocation fails (#210 gap 7)" {
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
    try client.processEnvelope(started_env);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — accepted, settles

    // The settlement's result-copy allocation fails: the envelope is already
    // consumed, but the tracker must still retire the settled send — the
    // stale entry would bracket a LATER lost-output probe from the wrong
    // floor (2/3 while the server expects 4 after the next acceptance).
    var result_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer result_env.deinit(allocator);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    client.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, client.processEnvelope(result_env));
    client.allocator = allocator;
    try std.testing.expectEqual(@as(usize, 0), client.pending_sends_by_session.getPtr(sid).?.items.len);

    // The next message is accepted (server now expects 4) and its output is
    // lost: the probe brackets from the CURRENT entry's pair, not the stale
    // settled one.
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null); // tracker 3
    const probe_result = try client.sendAgentStopProbing(sid, "timeout");
    try std.testing.expect(probe_result != null);
    var first_stop = try harness.envelopeAt(3); // start, m1, m2, stop
    defer first_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), first_stop.sequence);
}

test "AgentProtocolClient probing stop sweeps every reachable counter state across sequentially accepted sends (#210 gap 7)" {
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

    // m1@2 is accepted and settled SERVER-side, but this client has not
    // consumed the settlement when it sends m2@3 — §13.2.3 already returned
    // the server to ready, so m2 is accepted too and the server expects 4.
    // A fixed two-state probe (2/3) would miss 4 and leak the session; the
    // sweep spans floor 2 to ceiling max(tracker 4, newest+1 4) = 4.
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null); // seq 3
    try std.testing.expectEqual(@as(u64, 4), client.peekNextSequence(sid));

    const probe_result = try client.sendAgentStopProbing(sid, "timeout");
    const probe_stop_id = probe_result.?;
    var stop1 = try harness.envelopeAt(3); // start, m1, m2, floor stop
    defer stop1.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), stop1.sequence);

    // Each correlated invalid_request advances the sweep: 2 → 3 → 4, where
    // the server actually sits.
    var rejection1 = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = probe_stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer rejection1.deinit(allocator);
    try client.processEnvelope(rejection1);
    var stop2 = try harness.envelopeAt(4);
    defer stop2.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), stop2.sequence);

    var rejection2 = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stop2.message_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer rejection2.deinit(allocator);
    try client.processEnvelope(rejection2);
    var stop3 = try harness.envelopeAt(5);
    defer stop3.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 4), stop3.sequence);

    // The ceiling bounds the sweep: stop3 carries the ceiling value, so its
    // rejection retires the probe — no fourth stop is written.
    var rejection3 = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stop3.message_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer rejection3.deinit(allocator);
    try client.processEnvelope(rejection3);
    try std.testing.expectEqual(@as(usize, 6), harness.writes.items.len);
    try std.testing.expect(!client.stop_probes_by_session.contains(sid));
}

test "AgentProtocolClient delayed agent_stopped replying to an older stop preserves an active probe (#210 gap 7)" {
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — reply lost

    const probe_result = try client.sendAgentStopProbing(sid, "timeout");
    const probe_stop_id = probe_result.?;
    var stop1 = try harness.envelopeAt(2); // start, message, floor stop
    defer stop1.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), stop1.sequence);

    // A delayed agent_stopped replying to an OLDER registration's stop (a
    // message id the probe does not own) arrives while the probe is in
    // flight: it must not tear the session's control state down — the
    // current probe would be cleared and the CURRENT registration stranded
    // when its own stop's rejection finds no sweep to advance.
    var stale_stopped = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = agent_types.generateUlid(),
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_stopped = .{ .session_id = sid } },
    };
    defer stale_stopped.deinit(allocator);
    try client.processEnvelope(stale_stopped);
    try std.testing.expect(client.stop_probes_by_session.contains(sid));
    try std.testing.expect(!client.isSessionComplete(sid));

    // The probe's own rejection still advances the sweep.
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
    var stop2 = try harness.envelopeAt(3);
    defer stop2.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), stop2.sequence);
    try std.testing.expect(client.stop_probes_by_session.contains(sid));
}

test "AgentProtocolClient session terminal-state updates keep the previous value when the replacement allocation fails (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    const client = &harness.client;
    const sid = agent_types.generateSessionId();

    try client.setSessionError(sid, "first failure");
    try client.setSessionResult(sid, "{\"first\":true}");
    try std.testing.expectEqualStrings("first failure", client.getLastErrorForSession(sid).?);
    try std.testing.expectEqualStrings("{\"first\":true}", client.getLastResultJsonForSession(sid).?);

    // Fail the NEXT allocation (the replacement dupe): the update errors, but
    // the map slots must still hold their previous values — a slot the failed
    // path had left holding a deinit'd slice would double-free on the next
    // update or at deinit.
    {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        client.allocator = failing.allocator();
        defer client.allocator = allocator;
        try std.testing.expectError(error.OutOfMemory, client.setSessionError(sid, "second failure"));
    }
    {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        client.allocator = failing.allocator();
        defer client.allocator = allocator;
        try std.testing.expectError(error.OutOfMemory, client.setSessionResult(sid, "{\"second\":true}"));
    }
    try std.testing.expectEqualStrings("first failure", client.getLastErrorForSession(sid).?);
    try std.testing.expectEqualStrings("{\"first\":true}", client.getLastResultJsonForSession(sid).?);

    // The SURVIVING values are then replaced cleanly — this deinit path
    // double-frees if the failed update left the slot undefined.
    try client.setSessionError(sid, "third failure");
    try client.setSessionResult(sid, "{\"third\":true}");
    try std.testing.expectEqualStrings("third failure", client.getLastErrorForSession(sid).?);
    try std.testing.expectEqualStrings("{\"third\":true}", client.getLastResultJsonForSession(sid).?);
}

test "AgentProtocolClient probing stop retries on a nack invalid_sequence rejection (#210 gap 7)" {
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

    const probe_result = try client.sendAgentStopProbing(sid, "timeout");
    const probe_stop_id = probe_result.?;

    // A compatible peer rejects the pre-send stop with the shared protocol's
    // invalid_sequence code — the same wrong-counter evidence, driving the
    // same post-send retry.
    var nack_rejection = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = probe_stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = probe_stop_id,
            .reason = OwnedSlice(u8).initBorrowed("invalid sequence"),
            .error_code = .invalid_sequence,
        } },
    };
    defer nack_rejection.deinit(allocator);
    try client.processEnvelope(nack_rejection);

    try std.testing.expectEqual(@as(usize, 4), harness.writes.items.len); // start, message, stop(2), stop(3)
    var second_stop = try harness.envelopeAt(3);
    defer second_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), second_stop.sequence);
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

test "AgentProtocolClient correlated agent_not_found clears state only for a request of the current registration (#210 gap 7)" {
    // The rejection must name a request this client tracks for the CURRENT
    // registration. A tracked send's not_found clears the stale counter (a
    // re-registration of the id must start at sequence 1); a DELAYED
    // not_found from an older registration's stop — whose id the client
    // never tracked, arriving after the reused id's new agent_started —
    // must leave the new registration's state alone, or its next message
    // would start at sequence 1 against the live server session.
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1, tracker 2
    const msg_id = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2, tracker 3

    // Tracked request answered agent_not_found: the session is gone, drop
    // the sequence and control state.
    var tracked_rejection = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = msg_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_not_found, .message = try allocator.dupe(u8, "session not found") } },
    };
    defer tracked_rejection.deinit(allocator);
    try client.processEnvelope(tracked_rejection);

    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));
    try std.testing.expect(!client.pending_sends_by_session.contains(sid));

    // The id is re-registered (start + started + message): the CURRENT
    // registration's state is live again...
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1, tracker 2
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
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null); // seq 2, tracker 3

    // ...so a delayed not_found replying to the OLD registration's
    // untracked stop id must NOT wipe it.
    const stale_stop_id = agent_types.generateUlid();
    var stale_rejection = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stale_stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_not_found, .message = try allocator.dupe(u8, "session not found") } },
    };
    defer stale_rejection.deinit(allocator);
    try client.processEnvelope(stale_rejection);

    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    try std.testing.expect(client.pending_sends_by_session.contains(sid));
}

test "AgentProtocolClient unrelated nack does not fail the live session (#210 gap 7)" {
    // Non-run requests (models, tool_list, ping, status) share the transport
    // and can be nacked mid-run — e.g. a not_implemented capability answer.
    // The nack is request-scoped: only a nack rejecting one of this client's
    // own start/message requests may surface as a terminal session error.
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
    const msg_id = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2, unresolved

    // An unrelated capability nack: the session's turn state survives.
    var models_nack = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = agent_types.generateUlid(),
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{ .rejected_id = agent_types.generateUlid(), .error_code = .not_implemented, .reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "not implemented")) } },
    };
    defer models_nack.deinit(allocator);
    try client.processEnvelope(models_nack);
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(!client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));

    // A nack rejecting the PENDING message still fails the session.
    var message_nack = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = msg_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{ .rejected_id = msg_id, .error_code = .invalid_sequence, .reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "invalid sequence")) } },
    };
    defer message_nack.deinit(allocator);
    try client.processEnvelope(message_nack);
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
}

test "AgentProtocolClient uncorrelated agent_error keeps the pending send for the teardown probe (#210 gap 7)" {
    // §13.4.1: an uncorrelated runtime agent_error may be an admission
    // failure — the server rolled the counter back and admitted nothing —
    // or the §13.4.2 settlement of an admitted run; the two are
    // wire-identical. Retiring the pending send on it would disarm the
    // teardown probe (the fallback plain stop at the optimistic value is
    // rejected in the rolled-back case and the session leaks), so the send
    // stays unresolved and the probe brackets both states.
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
    try client.processEnvelope(started_env);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2, unresolved

    var uncorrelated = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .internal_error, .message = try allocator.dupe(u8, "admission allocation failure") } },
    };
    defer uncorrelated.deinit(allocator);
    try client.processEnvelope(uncorrelated);

    // The send is retained: the teardown probe is eligible and brackets the
    // pre-send state (2) — in the admission-failure world the server still
    // expects it, and the probe's FIRST stop succeeds.
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
    const probe_result = try client.sendAgentStopProbing(sid, "timeout");
    try std.testing.expect(probe_result != null);
    var first_stop = try harness.envelopeAt(2); // start(0), message(1), floor stop(2)
    defer first_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), first_stop.sequence);
}

test "AgentProtocolClient settlement retires the settled run's own send, keeping later unresolved ones (#210 gap 7)" {
    // Sends 2/3/4 pipelined; the server accepts 2 (it settles) and rejects
    // 3 and 4 while processing, leaving its counter at 3. The settlement
    // retires ONLY the settled run's own send (the oldest message), so the
    // probe's candidates come from the oldest UNRESOLVED message — 3 — not
    // 4/5, which could not stop the session.
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
    try client.processEnvelope(started_env);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — accepted, settles
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null); // seq 3 — rejected busy
    _ = try client.sendAgentMessage(sid, "{\"m\":3}", null); // seq 4 — rejected invalid

    var result_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 5,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer result_env.deinit(allocator);
    try client.processEnvelope(result_env);

    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 2), pending.items.len); // 3 and 4 remain unresolved

    const probe_result = try client.sendAgentStopProbing(sid, "timeout");
    try std.testing.expect(probe_result != null);
    var first_stop = try harness.envelopeAt(4);
    defer first_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), first_stop.sequence); // the oldest UNRESOLVED message's pair — [3, 4]
}

test "AgentProtocolClient probing stop survives an ambiguous write failure (#210 gap 7)" {
    // A write/flush failure after the probe's stop may have reached the peer
    // is ambiguous: the probe must stay registered so a delivered pre-send
    // stop's correlated rejection still triggers the post-send retry, and a
    // teardown driver still sees an active probe to pump.
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

    harness.fail_writes = true;
    const probe_result = try client.sendAgentStopProbing(sid, "timeout");
    try std.testing.expect(probe_result != null);
    try std.testing.expect(client.hasActiveStopProbe(sid)); // the probe outlives the ambiguous write failure
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
