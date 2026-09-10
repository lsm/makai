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
    /// optimistic regression) when the tracker still holds only this send's
    /// mirror — an explicit resend at an older sequence regresses the
    /// tracker to sequence+1, and min'ing that regression against the
    /// pre-send value would pin the client below the server's counter
    /// forever (#210 gap 7).
    prior_tracker: u64,
    /// A 64-bit digest of a MESSAGE send's logical payload (`message_json` +
    /// `options_json`): duplicate-evidence retry matching is sequence AND
    /// payload identity — the same sequence carrying a DIFFERENT payload is
    /// not a retry of the pending original (a `duplicate_sequence` answer
    /// proves only that the EARLIER payload was admitted; the new one was
    /// never executed and must surface instead of retiring silently)
    /// (#210 gap 7). Unused (0) for start/stop records.
    payload_hash: u64 = 0,
    /// Whether another unresolved MESSAGE record with the SAME sequence and
    /// payload digest existed when the send was recorded — the send is a
    /// RETRY of a still-unresolved original, so a later duplicate_sequence
    /// answer to it is duplicate evidence (an earlier copy was admitted;
    /// the server is past the sequence) even if the original settles first
    /// and removes its own record (#210 gap 7).
    resend_of_pending: bool = false,
    /// Sticky: this record's provenance source chain was BROKEN — a
    /// rejection removed the record (or chain) it derived from. A broken
    /// record can no longer serve as a provenance source for later
    /// same-sequence same-payload records: its own admission is unproven
    /// and its source never ran, so deriving from it would silently
    /// suppress duplicate answers for payloads that never executed
    /// (#210 gap 7).
    provenance_broken: bool = false,
};

/// Computes a pending MESSAGE record's payload digest (see
/// `PendingSend.payload_hash`). Each component is tagged, presence-marked,
/// and length-delimited before hashing — plain concatenation would identify
/// distinct payload pairs such as ("1","23") and ("12","3"). An EMPTY
/// `options_json` is canonicalized to absence first: the request surface
/// (`AgentMessageRequest.getOptionsJson`) and the serializer treat "" and
/// null identically on the wire, so the same wire request must digest the
/// same however the caller spells its options (#210 gap 7).
fn messagePayloadHash(message_json: []const u8, options_json: ?[]const u8) u64 {
    const canonical_options: ?[]const u8 = if (options_json) |opts| (if (opts.len == 0) null else opts) else null;
    var hasher = std.hash.Wyhash.init(0);
    payloadDigestField(&hasher, 0xE1, message_json);
    payloadDigestField(&hasher, 0xD1, canonical_options);
    return hasher.final();
}

fn payloadDigestField(hasher: *std.hash.Wyhash, tag: u8, value: ?[]const u8) void {
    hasher.update(&.{tag});
    if (value) |bytes| {
        hasher.update(&.{1});
        const len: u64 = bytes.len;
        hasher.update(std.mem.asBytes(&len));
        hasher.update(bytes);
    } else hasher.update(&.{0});
}

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
    /// Monotone memory of every sound lower bound established for a
    /// session's counter (#210 gap 7) — see `noteProvenFloor`.
    proven_floor_by_session: std.AutoHashMap(agent_types.SessionId, u64),

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
            .proven_floor_by_session = std.AutoHashMap(agent_types.SessionId, u64).init(allocator),
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
        self.proven_floor_by_session.deinit();

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
    fn recordPendingSend(self: *Self, session_id: agent_types.SessionId, msg_id: agent_types.Ulid, sequence: u64, kind: PendingSendKind, prior_tracker: u64, payload_hash: u64) !void {
        const gop = try self.pending_sends_by_session.getOrPut(session_id);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(PendingSend).empty;
        var resend_of_pending = false;
        for (gop.value_ptr.items) |pending| {
            if (pending.kind == .message and pending.sequence == sequence and pending.payload_hash == payload_hash and !pending.provenance_broken) resend_of_pending = true;
        }
        try gop.value_ptr.append(self.allocator, .{ .msg_id = msg_id, .sequence = sequence, .kind = kind, .prior_tracker = prior_tracker, .payload_hash = payload_hash, .resend_of_pending = resend_of_pending });
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
        self.recordPendingSend(sid, msg_id, seq, .start, seq, 0) catch |err| {
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
        self.recordPendingSend(session_id, msg_id, sequence, .message, prior_sequence, messagePayloadHash(message_json, options_json)) catch |err| {
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
        return self.sendAgentStopWithSequence(session_id, reason, self.peekNextSequence(session_id));
    }

    /// Sends an `agent_stop` carrying an EXPLICIT inbound sequence (#210
    /// gap 7) — a caller with positive ownership evidence for an
    /// unknown-outcome start may stop explicitly at the counter state it
    /// knows (§13.2.6). Like `sendAgentStop`, the tracker is not advanced
    /// past the given value; `maxInt(u64)` is rejected before any mutation
    /// (the resync below would install it, and a later start's `seq + 1`
    /// would overflow the tracker).
    pub fn sendAgentStopWithSequence(self: *Self, session_id: agent_types.SessionId, reason: ?[]const u8, sequence: u64) !agent_types.Ulid {
        if (sequence == std.math.maxInt(u64)) return error.InvalidSequence;
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
        // The stop is tracked like any other own request — a stop never
        // advances the counter, so the record exists purely so its OWN
        // replies reach the handling: a session-gone answer naming the stop
        // (an eviction discovered through the teardown) drops the session's
        // counter state, instead of leaving a stale value that a
        // re-registration of the same id would send and have rejected
        // (#210 gap 7). Recorded BEFORE the wire so a record failure leaves
        // nothing sent.
        //
        // An EXPLICIT stop RESYNCS the tracker to the caller-supplied
        // sequence without advancing past it: the caller used this variant
        // precisely because it knows the counter state (recovery after a
        // probe or a lost-reply rollback), and an ambiguous write failure
        // must not leave the stale pre-resync value behind for the next
        // ordinary send. The pre-resync value is the record's prior_tracker
        // — undone by the stop's own correlated rejection (see
        // handleCorrelatedRejection). For an ordinary stop the resync is a
        // no-op: it carries the tracker's own value.
        const prior = self.peekNextSequence(session_id);
        const prior_mirror = self.sequence;
        self.sequence = sequence; // compatibility mirror
        self.next_sequence_by_session.put(session_id, sequence) catch |err| {
            self.sequence = prior_mirror;
            return err;
        };
        self.recordPendingSend(session_id, msg_id, sequence, .stop, prior, 0) catch |err| {
            // Nothing reached the wire: restore the pre-send state, the
            // compatibility mirror included (#210 gap 7).
            self.next_sequence_by_session.put(session_id, prior) catch {};
            self.sequence = prior_mirror;
            return err;
        };
        try self.writeEnvelopeJson(json);
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
                // (#210 gap 7). The retirement also RESTORES progress a
                // stale rewind had pulled below it: the settlement proves
                // the counter advanced past the retired record's sequence,
                // so a tracker below sequence + 1 (a DELAYED busy answer's
                // parity floor for a retry that was actually accepted, or a
                // rejection's all-rejected floor) is raised — best-effort,
                // since duplicate evidence lifts a tracker left low by an
                // allocation failure here.
                if (self.retireSettledPendingSends(env.session_id)) |min_candidate_sequence| {
                    self.noteProvenFloor(env.session_id, min_candidate_sequence + 1);
                    const target = self.provenFloor(env.session_id);
                    if (self.peekNextSequence(env.session_id) < target) {
                        self.next_sequence_by_session.put(env.session_id, target) catch {};
                    }
                }
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
                // Allocate the replacement BEFORE releasing the previous
                // value: a failed dupe must not leave last_error undefined
                // (a later update or deinit would double-free).
                const error_copy = try self.allocator.dupe(u8, e.message);
                self.last_error.deinit(self.allocator);
                self.last_error = OwnedSlice(u8).initOwned(error_copy);
                try self.setSessionError(env.session_id, e.message);
            },
            .nack => |n| {
                // A correlated nack is a request rejection like a correlated
                // agent_error (the fixture server and older peers use this
                // shape): a nack surfaces through the session-error
                // bookkeeping ONLY when it rejects one of this client's own
                // start/message requests — without it, a peer that rejects an
                // ordinary agent_message by nack would leave the TUI treating
                // the submit as accepted with no settlement ever coming. A
                // nack for a NON-run request (models, tool_list, ping,
                // status — e.g. a not_implemented capability answer) shares
                // the transport and can arrive mid-run: recording it as a
                // terminal session error makes the TUI abort a healthy turn.
                // Unrelated nacks stay request-scoped and are dropped (#210
                // gap 7).
                if (!self.replyNamesPendingSend(env.session_id, env.in_reply_to)) return;
                // A duplicate_sequence answer is the one wrong-counter code
                // that PROVES the server's counter is past the sent sequence
                // (the provider surface answers it only when received <
                // expected — an earlier copy of this sequence was already
                // admitted). The ordinary §13.1 rollback to the rejected
                // send's own sequence would pin every later send on an
                // already-consumed counter, so instead the outcome is treated
                // as KNOWN — no new admission from this send: the pending
                // record retires, the tracker keeps its optimistic value, and
                // no session error is recorded (the admitted copy's run may
                // still be live) (#210 gap 7).
                const duplicate_admitted = if (n.error_code) |code| code == .duplicate_sequence else false;
                if (duplicate_admitted) {
                    // Only for a MESSAGE send, and only when it is a RETRY of
                    // a still-unresolved original (resend_of_pending): an
                    // earlier copy of the sequence was admitted, the code
                    // proves the server is past it, and the ORIGINAL's run
                    // may still settle — so the record retires with only the
                    // PROVEN step and no session error. A duplicate
                    // answer on a NON-retry send admits nothing of this
                    // caller's own state: no run of the envelope will produce
                    // a settlement, so the high-water is preserved but the
                    // rejection SURFACES through the error bookkeeping below.
                    // A START answered duplicate_sequence — accepted with its
                    // started reply lost, then retransmitted — likewise falls
                    // through to the ordinary rejection path so the caller
                    // sees the failure and re-registers, leaking the accepted
                    // session only until the idle TTL (§13.2.6's conservative
                    // stop-ownership stance — claiming the accepted
                    // registration on duplicate evidence alone would also
                    // claim a FOREIGN caller's registration on a reused
                    // caller-supplied id).
                    if (self.pendingSendFor(env.session_id, env.in_reply_to)) |entry| {
                        if (entry.kind == .message) {
                            try self.retireDuplicateAdmittedSend(env.session_id, env.in_reply_to, entry);
                            if (entry.resend_of_pending) return;
                            // The high-water is already preserved; skip the
                            // rollback (the entry is retired, so the
                            // correlated rejection below finds no match) and
                            // fall through to record the failure.
                        }
                    }
                }
                // Rollback first, then fallible bookkeeping (see the
                // agent_error arm).
                try self.handleCorrelatedRejection(env.session_id, env.in_reply_to, agentCodeFromNack(n.error_code));
                // Allocate the replacement BEFORE releasing the previous
                // value (same ordering rule as the agent_error arm).
                const reason_copy = try self.allocator.dupe(u8, n.reason.slice());
                self.last_error.deinit(self.allocator);
                self.last_error = OwnedSlice(u8).initOwned(reason_copy);
                try self.setSessionError(env.session_id, n.reason.slice());
            },
            .agent_stopped => |p| {
                if (self.session_id) |sid| {
                    if (std.mem.eql(u8, sid[0..], p.session_id[0..])) self.session_id = null;
                }
                _ = self.next_sequence_by_session.remove(p.session_id);
                _ = self.proven_floor_by_session.remove(p.session_id);
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
    ///
    /// KNOWN RESIDUAL: a settlement frame carries no run identity on the
    /// wire (`agent_result` has no `in_reply_to`, §13.3.2), so the
    /// insertion-order attribution is a heuristic, not a proof. Explicit
    /// recovery sends can leave records whose send order differs from their
    /// admission order — an ambiguously-failed stale send's record may be
    /// retired by a later ACCEPTED send's settlement, leaving the accepted
    /// record to linger one extra turn (flooring a later rejection below
    /// the true counter, which duplicate evidence then lifts). The
    /// mis-attribution self-corrects as settlements retire one record each,
    /// and the list stays bounded by unresolved sends; the full fix needs
    /// run identity on the settlement frame, which the wire cannot observe
    /// today (#210 gap 7 — documented series residual, see #213).
    ///
    /// Returns the MINIMUM sequence among the pending message records that
    /// existed before the retirement: the settlement proves the run was
    /// admitted and completed, and the run is only KNOWN to be one of those
    /// records — its sequence is at least the minimum, so the counter is
    /// proven past min + 1. The heuristically retired record's OWN sequence
    /// proves nothing (the FIFO residual above may have picked a stale
    /// forward explicit send whose sequence is far above the settled run's)
    /// (#210 gap 7).
    fn retireSettledPendingSends(self: *Self, session_id: agent_types.SessionId) ?u64 {
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return null;
        var min_candidate: u64 = std.math.maxInt(u64);
        var oldest_index: ?usize = null;
        for (list.items, 0..) |pending, index| {
            if (pending.kind != .message) continue;
            min_candidate = @min(min_candidate, pending.sequence);
            if (oldest_index == null) oldest_index = index;
        }
        const index = oldest_index orelse return null;
        _ = list.orderedRemove(index);
        return min_candidate;
    }

    /// Whether `in_reply_to` names one of the session's tracked pending
    /// sends — i.e. the reply belongs to a request of the CURRENT
    /// registration (a start, message, or stop this client sent and has not
    /// yet resolved).
    fn replyNamesPendingSend(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid) bool {
        return self.pendingSendKindFor(session_id, in_reply_to) != null;
    }

    /// The kind of the pending send a reply names, or null when the reply
    /// matches no tracked send for the session.
    fn pendingSendKindFor(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid) ?PendingSendKind {
        const entry = self.pendingSendFor(session_id, in_reply_to) orelse return null;
        return entry.kind;
    }

    /// A copy of the pending send a reply names, or null when the reply
    /// matches no tracked send for the session.
    fn pendingSendFor(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid) ?PendingSend {
        const reply_to = in_reply_to orelse return null;
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return null;
        for (list.items) |pending| {
            if (std.mem.eql(u8, &reply_to, &pending.msg_id)) return pending;
        }
        return null;
    }

    /// Maps a protocol nack error code onto the agent error code carrying
    /// the same evidence for the sequence rules. The shared protocol's
    /// wrong-counter rejections — invalid_sequence, and duplicate_sequence
    /// (a candidate the server has already consumed, so its expected counter
    /// is HIGHER) — are the same evidence the agent surface spells
    /// invalid_request: peers may answer a request any of these ways, and
    /// all of them drive the tracker's rollback (#210 gap 7).
    /// sequence_gap is the opposite condition — the candidate is already too
    /// HIGH for the server's counter — and stays a distinct terminal
    /// rejection.
    fn agentCodeFromNack(code: ?agent_types.ErrorCode) ?agent_types.AgentErrorCode {
        const c = code orelse return null;
        return switch (c) {
            .invalid_request, .invalid_sequence, .duplicate_sequence => .invalid_request,
            else => null,
        };
    }

    /// Records a sound lower bound on the session's counter (#210 gap 7):
    /// every reconciliation that establishes one — a busy answer's exact
    /// parity, an all-rejected floor, a duplicate answer's proven step, a
    /// settlement's minimum candidate, a stop-undo's capped restore — MAXES
    /// this monotone memory, and every later floor or restore MAXES with
    /// it. The counter never moves backward, so a bound once proven stays
    /// proven: optimistic regressions (a backward explicit send's mirror)
    /// can never erase it, and stale snapshots (a pending record's prior,
    /// possibly contaminated by mirrors of sends that have since resolved
    /// as rejected) can never exceed it. Send-time mirrors are NOT proven
    /// (their sends are unresolved) and never touch it.
    fn noteProvenFloor(self: *Self, session_id: agent_types.SessionId, bound: u64) void {
        const current = self.proven_floor_by_session.get(session_id) orelse 0;
        if (bound > current) self.proven_floor_by_session.put(session_id, bound) catch {};
    }

    fn provenFloor(self: *Self, session_id: agent_types.SessionId) u64 {
        return self.proven_floor_by_session.get(session_id) orelse 0;
    }

    /// Retires a send proven duplicate-admitted by a `duplicate_sequence`
    /// answer and restores the tracker to `entry.sequence + 1` MAX the
    /// session's proven floor (#210 gap 7). The answer proves exactly one
    /// step — the counter is past the sent sequence — and every prior
    /// reconciliation's sound bound is remembered; nothing else
    /// participates: optimistic mirrors (the entry's own pre-send tracker,
    /// a remaining record's prior, an interleaved send's) are unproven and
    /// restoring any of them can jump the tracker past the server, making
    /// the next ordinary send a gap rejection. If the counter is higher
    /// than the restore, the next send at the restored value is answered
    /// `duplicate_sequence` in turn — and as a same-payload retry of a
    /// still-pending message it retires silently, advancing one PROVEN step
    /// per round trip.
    fn retireDuplicateAdmittedSend(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid, entry: PendingSend) !void {
        const restore = @max(entry.sequence + 1, self.provenFloor(session_id));
        self.retirePendingSend(session_id, in_reply_to);
        self.noteProvenFloor(session_id, restore);
        try self.next_sequence_by_session.put(session_id, restore);
    }

    /// Applies #210 gap 7's client sequence-control rules to a correlated
    /// rejection (an `agent_error`/`nack` whose `in_reply_to` names this
    /// client's own send): a rejected counter-advancing send rolls the tracker
    /// back so a corrected retry reuses the same sequence (§13.1 — a rejected
    /// request never advances the server's expected counter). ALL outstanding
    /// sends are matched (a pipelined send's reply may arrive after a later
    /// send was recorded), and the rollback takes the MINIMUM so an older
    /// unresolved send's floor is never lost to a younger send's rejection.
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
            _ = self.proven_floor_by_session.remove(session_id);
            if (self.pending_sends_by_session.fetchRemove(session_id)) |entry| {
                var pending_list = entry.value;
                pending_list.deinit(self.allocator);
            }
            return;
        }

        const rejected = list.items[index];
        _ = list.orderedRemove(index);
        // A rejected MESSAGE may have been the SOURCE of other records'
        // retry provenance (`resend_of_pending` was recorded when the
        // rejected send was still pending): with the source now PROVEN
        // never-admitted, a remaining same-sequence record is no longer a
        // retry of an unresolved original — its duplicate answer must
        // surface, not retire silently as though the rejected payload had
        // run (#210 gap 7). Provenance is DIRECTIONAL and TRANSITIVE: a
        // record derives only from an earlier same-sequence same-payload
        // record whose own source chain is intact (`provenance_broken`
        // marks records whose source died), so rejecting a source clears
        // the whole chain below it — without the direction, two retries of
        // a rejected payload would treat each other as unresolved sources
        // and keep suppressing their duplicate answers.
        if (rejected.kind == .message) {
            for (list.items, 0..) |*pending, i| {
                if (pending.kind != .message or pending.sequence != rejected.sequence) continue;
                var viable_source = false;
                for (list.items[0..i]) |earlier| {
                    if (earlier.kind != .message or earlier.sequence != rejected.sequence) continue;
                    if (earlier.payload_hash != pending.payload_hash) continue;
                    if (earlier.provenance_broken) continue;
                    viable_source = true;
                }
                if (pending.resend_of_pending and !viable_source) pending.provenance_broken = true;
                pending.resend_of_pending = viable_source;
            }
        }
        // A rejected STOP never floors the tracker below proven bounds —
        // stops never advance the counter (§13.1), so the rejection itself
        // carries no counter evidence. But an EXPLICIT stop RESYNCED the
        // tracker to its caller-supplied sequence at send time, and that
        // resync is exactly what the rejection refutes, so it is undone —
        // only when the tracker still holds the stop's own value (later
        // sends may have moved it, and the rejection says nothing about
        // them) — to the pre-resync prior CAPPED by the still-pending
        // messages' all-rejected floor (the prior snapshot may itself be
        // contaminated by an unresolved send's optimistic mirror) and
        // MAXED with the session's proven floor (#210 gap 7). An ordinary
        // stop's resync was a no-op (it carried the tracker's own value),
        // so nothing changes for it beyond proven-floor retention.
        if (rejected.kind == .stop) {
            if (self.peekNextSequence(session_id) == rejected.sequence) {
                var pending_floor: u64 = std.math.maxInt(u64);
                for (list.items) |pending| {
                    if (pending.kind != .message) continue;
                    pending_floor = @min(pending_floor, @min(pending.sequence, pending.prior_tracker));
                }
                var undo = @min(rejected.prior_tracker, pending_floor);
                undo = @max(undo, self.provenFloor(session_id));
                self.noteProvenFloor(session_id, undo);
                try self.next_sequence_by_session.put(session_id, undo);
            }
            return;
        }
        // A correlated `agent_busy` proves the server's counter EQUALS
        // the rejected sequence: the server validates the inbound
        // sequence BEFORE the processing state (handleMessage), so a
        // busy answer means the sequence MATCHED — every lower sequence
        // was already consumed — and busy never advances the counter
        // (§13.1). The all-rejected floor below would replay an
        // already-consumed sequence and be rejected again (#210 gap 7).
        const busy = if (code) |c| c == .agent_busy else false;
        if (busy) {
            const parity = @max(rejected.sequence, self.provenFloor(session_id));
            self.noteProvenFloor(session_id, parity);
            try self.next_sequence_by_session.put(session_id, parity);
            return;
        }
        const current = self.peekNextSequence(session_id);
        const base = if (current == rejected.sequence + 1) rejected.prior_tracker else current;
        var floor = @min(base, rejected.prior_tracker);
        // The STILL-UNRESOLVED MESSAGE records keep their own floors: a
        // message whose admission failed through an UNCORRELATED error
        // stays pending (§13.4.1 — its outcome is unknown), and its
        // pre-send tracker and sequence are the counter the server holds
        // when every unresolved admission failed. A rollback that
        // ignores them pins the tracker above the server forever (#210
        // gap 7). START records are excluded: reaching here means the
        // rejection was NOT session-gone, so the session exists and the
        // counter is provably PAST the start's sequence (a stop or
        // eviction clears the records entirely) — the start's own floor
        // is refuted by the very evidence triggering this rollback, and
        // honoring it would drag every rejection on an unresolved start
        // down to the start's sequence (#210 gap 7).
        for (list.items) |pending| {
            if (pending.kind != .message) continue;
            floor = @min(floor, pending.prior_tracker);
            floor = @min(floor, pending.sequence);
        }
        // The all-rejected floor and every previously proven bound are
        // both sound lower bounds on the counter — the sound floor is
        // their MAX. Without this, a generic backward rejection
        // (invalid_request collapses both directions, server.zig) would
        // pin the tracker at the all-rejected world even though
        // settlements had proven more, and subsequent ordinary sends
        // would replay consumed sequences (#210 gap 7).
        floor = @max(floor, self.provenFloor(session_id));
        self.noteProvenFloor(session_id, floor);
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
        _ = self.proven_floor_by_session.remove(session_id);
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
    // ITS pending send even though a later send was recorded. A busy answer
    // proves the server's counter EQUALS the rejected sequence (the server
    // validates the sequence before the processing state), so the tracker
    // floors to exactly 2.
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
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid)); // busy proves the counter is 2

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

test "AgentProtocolClient rolls the tracker back on a correlated nack rejection too (#210 gap 7)" {
    // A correlated nack rejects a request exactly like a correlated
    // agent_error (the fixture server and older peers use this shape), so
    // the same §13.1 rollback must run.
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

test "AgentProtocolClient unrelated nack does not fail the live session (#210 gap 7)" {
    // Non-run requests (models, tool_list, ping, status) share the transport
    // and can be nacked mid-run — e.g. a not_implemented capability answer.
    // The nack is request-scoped: only a nack rejecting one of this client's
    // own tracked requests may surface as a terminal session error.
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
    // The rollback restores the counter the server RETAINED — the record's
    // pre-send tracker (1 for a fresh session), not the rejected send's own
    // 7: the server never advanced past 1, and replaying 7 would repeat the
    // invalid counter forever.
    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));

    // Explicit stop sends likewise carry the given value; the tracker
    // RESYNCS to the caller-known sequence without advancing past it (the
    // caller used the explicit variant because it knows the counter state).
    _ = try client.sendAgentStopWithSequence(sid, "recovered", 7);
    var explicit_stop = try harness.envelopeAt(1);
    defer explicit_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 7), explicit_stop.sequence);
    try std.testing.expectEqual(@as(u64, 7), client.peekNextSequence(sid)); // resynced, not advanced to 8
}

test "AgentProtocolClient explicit-sequence send failure restores the PRE-SEND tracker state (#210 gap 7)" {
    // A recovery path may send an explicit sequence far from the tracker's
    // value; when the pre-wire bookkeeping cannot be allocated, nothing
    // reached the wire, so the client must end up exactly as before the
    // attempt. Storing the CALLER-SUPPLIED value instead (the old rollback)
    // left a fresh client's tracker at 7 while the server still expected 1 —
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

test "AgentProtocolClient rejected stop never rolls the tracker below proven progress (#210 gap 7)" {
    // A stop never advances the counter, so its rejection carries no
    // counter evidence: a stale explicit stop sequence (2 against a server
    // proven at 4 by settlements) must not drag the tracker down — the
    // refuted resync is undone to the capped prior, MAX the proven floor.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — settled below
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null); // seq 3 — settled below, tracker 4
    for (0..2) |_| {
        var settled = agent_types.Envelope{
            .session_id = sid,
            .message_id = agent_types.generateUlid(),
            .sequence = 4,
            .in_reply_to = null,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
        };
        defer settled.deinit(allocator);
        try client.processEnvelope(settled);
    }
    const stop_id = try client.sendAgentStopWithSequence(sid, "stale", 2);
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid)); // resynced to the caller-supplied 2

    var rejected = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer rejected.deinit(allocator);
    try client.processEnvelope(rejected);

    try std.testing.expectEqual(@as(u64, 4), client.peekNextSequence(sid)); // the refuted resync undone — proven progress kept
    _ = try client.sendAgentMessage(sid, "{\"m\":3}", null);
    var next_env = try harness.envelopeAt(4); // start, m1, m2, stop, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 4), next_env.sequence);
}

test "AgentProtocolClient rejected backward explicit send restores the high-water (#210 gap 7)" {
    // A settled session at 4; an explicit stale send at 2 regresses the
    // tracker to 3 before the wire. Its rejection must restore the
    // pre-send high-water: min'ing the send's own optimistic regression
    // against the prior would pin the tracker at 3 while the server sits
    // at 4, and every subsequent rejection would keep it there.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null); // seq 3, tracker 4
    var first_settled = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 4,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer first_settled.deinit(allocator);
    try client.processEnvelope(first_settled);
    var second_settled = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 5,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer second_settled.deinit(allocator);
    try client.processEnvelope(second_settled);
    const stale_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":stale}", null, 2); // prior 4, tracker 3

    var rejected = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stale_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer rejected.deinit(allocator);
    try client.processEnvelope(rejected);

    try std.testing.expectEqual(@as(u64, 4), client.peekNextSequence(sid)); // high-water restored, not the regression
    _ = try client.sendAgentMessage(sid, "{\"m\":3}", null);
    var next_env = try harness.envelopeAt(4); // start, m1, m2, stale, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 4), next_env.sequence);
}

test "AgentProtocolClient tracked-send duplicate_sequence nack retires the record without a rollback (#210 gap 7)" {
    // Sequence 2 was admitted with its reply lost; the recovery resends
    // sequence 2 explicitly and the peer answers duplicate_sequence — proof
    // the server's counter is PAST 2. The ordinary §13.1 rollback would pin
    // every later send on the consumed counter; instead the resend's record
    // retires (its outcome is known — no new admission) and the tracker
    // keeps the optimistic value.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — reply lost
    const resend_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2); // recovery resend

    var duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = resend_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = resend_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer duplicate.deinit(allocator);
    try client.processEnvelope(duplicate);

    // No rollback to the consumed 2, no false session failure, and the
    // resend's record retired while the original's stays for a later probe.
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(!client.isSessionComplete(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);

    // The next ordinary send continues PAST the consumed sequence instead of
    // replaying it as a duplicate.
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);
    var next_env = try harness.envelopeAt(3); // start, m1, resend, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), next_env.sequence);
}

test "AgentProtocolClient duplicate_sequence nack on a start falls through to the rejection path (#210 gap 7)" {
    // A start accepted with its started reply lost, then retransmitted and
    // answered duplicate_sequence: the send's outcome cannot be resolved as
    // admitted (claiming it would also claim a foreign registration on a
    // reused id), so the ordinary rejection path runs — the caller sees the
    // failure and re-registers, leaking the accepted session only until the
    // idle TTL.
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1, tracker 2, pending start

    var duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = start_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = start_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer duplicate.deinit(allocator);
    try client.processEnvelope(duplicate);

    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid)); // rolled back
    try std.testing.expect(client.getLastErrorForSession(sid) != null); // surfaced, not swallowed
    try std.testing.expect(client.isSessionComplete(sid));
    // The ordinary rejection path retires the entry from the list (the empty
    // list itself stays mapped until the session's control state clears).
    const remaining = if (client.pending_sends_by_session.getPtr(sid)) |l| l.items.len else 0;
    try std.testing.expectEqual(@as(usize, 0), remaining);
}

test "AgentProtocolClient duplicate_sequence nack restores only the PROVEN step — the optimistic bound waits for its own evidence (#210 gap 7)" {
    // Sends at 2 and 3 were accepted with their replies outstanding
    // (tracker 4; the server is at 4 in this world); a recovery resend at
    // the older 2 regresses the tracker to 3, and its duplicate_sequence
    // answer proves exactly ONE step — the server is past 2 — never that
    // it reached the optimistic 4 (in the world where 3 was busy-rejected
    // with the reply lost, the server still expects 3, and restoring 4
    // would make the next ordinary send a terminal mismatch). The restore
    // is the proven 3; each further duplicate answer for a matching retry
    // of a still-pending message advances one more proven step, silently.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — accepted, reply outstanding
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null); // seq 3 — accepted, reply outstanding, tracker 4
    const resend_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2); // same payload — the retry
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));

    var duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = resend_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = resend_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer duplicate.deinit(allocator);
    try client.processEnvelope(duplicate);

    // Only the PROVEN step (past 2), never the optimistic 4; no false
    // failure; the resend's record retired while the originals stay.
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 2), pending.items.len); // m1 and m2 remain; the resend retired

    // The server is past 3 as well (this world): the next ordinary send at
    // the restored 3 is m2's retry (same sequence AND payload), so its
    // duplicate answer retires SILENTLY and advances one more proven step.
    const ladder_id = try client.sendAgentMessage(sid, "{\"m\":2}", null); // @3, retry of pending m2
    var ladder_duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = ladder_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = ladder_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer ladder_duplicate.deinit(allocator);
    try client.processEnvelope(ladder_duplicate);
    try std.testing.expectEqual(@as(u64, 4), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) == null);

    // The next NEW message continues past the consumed sequences.
    _ = try client.sendAgentMessage(sid, "{\"m\":3}", null);
    var next_env = try harness.envelopeAt(5); // start, m1, m2, resend, ladder, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 4), next_env.sequence);
}

test "AgentProtocolClient duplicate_sequence nack ignores chain-regressed resend priors (#210 gap 7)" {
    // Overlapping explicit resends chain-regress their prior snapshots:
    // with the client and server at 4, a resend at 2 records prior 4 and
    // lowers the tracker to 3; a second resend then records the
    // ALREADY-lowered 3 as its prior. Its duplicate answer proves only one
    // step (past 2): the restore is 3 — neither the second resend's
    // regressed prior nor the first resend's prior 4 is evidence, and
    // restoring an unproven value would jump the tracker past the server.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — accepted
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null); // seq 3 — accepted, tracker 4
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2); // prior 4, tracker 3
    const second_resend_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2); // prior 3 (regressed)

    var duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = second_resend_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = second_resend_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer duplicate.deinit(allocator);
    try client.processEnvelope(duplicate);

    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid)); // the PROVEN step, not any unproven prior
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 3), pending.items.len); // m1, m2, and the first resend remain

    _ = try client.sendAgentMessage(sid, "{\"m\":3}", null);
    var next_env = try harness.envelopeAt(5); // start, m1, m2, resend, resend2, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), next_env.sequence);
}

test "AgentProtocolClient agent_busy rejection floors to the rejected sequence — every lower one was consumed (#210 gap 7)" {
    // Sequence 2 was accepted with its reply outstanding; sequence 3 is
    // sent while that run is still processing and answered agent_busy. The
    // server validates the inbound sequence BEFORE the processing state,
    // so the busy answer PROVES the server expects exactly 3 — the
    // all-rejected floor (the still-pending sequence-2 record's 2) would
    // replay the consumed 2 and be rejected again.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — accepted, reply outstanding
    const second_id = try client.sendAgentMessage(sid, "{\"m\":2}", null); // seq 3, tracker 4

    var busy = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = second_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_busy, .message = try allocator.dupe(u8, "session already processing a message") } },
    };
    defer busy.deinit(allocator);
    try client.processEnvelope(busy);

    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid)); // NOT the pending m1's 2

    // The corrected retry carries the busy-proven sequence 3.
    _ = try client.sendAgentMessage(sid, "{\"m\":2-retry}", null);
    var retried = try harness.envelopeAt(3); // start, m1, m2, retry
    defer retried.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), retried.sequence);
}

test "AgentProtocolClient duplicate_sequence nack ignores optimistic sends interleaved before the reply (#210 gap 7)" {
    // A matching retry at sequence 2 is followed by ANOTHER optimistic
    // send at 3 before the duplicate reply arrives (its own rejection —
    // busy with the reply lost — never reached the client): peek is 4,
    // but only past-2 is PROVEN. The restore is exactly the proven step
    // (3); max'ing with the live tracker would preserve the interleaved
    // send's unproven mirror and the next ordinary send would be rejected
    // for a gap.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — accepted, reply outstanding
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null); // seq 3 — busy-rejected, reply lost (server expects 3)
    const resend_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2); // the retry, tracker 3
    _ = try client.sendAgentMessage(sid, "{\"m\":3}", null); // interleaved optimistic send @3, tracker 4

    var duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = resend_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = resend_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer duplicate.deinit(allocator);
    try client.processEnvelope(duplicate);

    // Exactly the proven step — NOT the interleaved send's optimistic 4.
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) == null); // the retry's duplicate retires silently
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 3), pending.items.len); // m1, m2, and the interleaved send remain

    // The next ordinary send carries the proven 3.
    _ = try client.sendAgentMessage(sid, "{\"m\":4}", null);
    var next_env = try harness.envelopeAt(5); // start, m1, m2, resend, interleaved, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), next_env.sequence);
}

test "AgentProtocolClient payload identity delimits message and options components (#210 gap 7)" {
    // The retry digest must respect the component boundary: ("1","23")
    // and ("12","3") are DIFFERENT logical payloads — concatenating the
    // slices without delimiters would identify them, marking the second a
    // retry of the first and swallowing its duplicate answer for a payload
    // that never ran.
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
    _ = try client.sendAgentMessage(sid, "1", "23"); // seq 2 — accepted, reply outstanding

    // Same concatenation, different boundary: NOT a retry of the pending
    // original, so its duplicate answer must surface.
    const shifted_id = try client.sendAgentMessageWithSequence(sid, "12", "3", 2);

    var duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = shifted_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = shifted_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer duplicate.deinit(allocator);
    try client.processEnvelope(duplicate);

    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid)); // the proven step
    try std.testing.expect(client.getLastErrorForSession(sid) != null); // surfaced — the shifted payload never ran
    try std.testing.expect(client.isSessionComplete(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len); // the ORIGINAL ("1","23") remains

    // The digest itself distinguishes the boundary.
    try std.testing.expect(messagePayloadHash("1", "23") != messagePayloadHash("12", "3"));
}

test "AgentProtocolClient duplicate_sequence on a non-retry send retains independently proven progress (#210 gap 7)" {
    // Completed turns established the server at 5; a stale explicit send
    // at 2 (not a retry — nothing is pending) regresses the tracker to 3
    // before the wire. Its duplicate answer proves past 2, but the SETTLED
    // progress to 5 is independently proven and must survive: restoring
    // the bare step (3) would have the next ordinary sends rejected at 3
    // and 4 — each surfacing a false terminal error. The restore combines
    // the duplicate's step with the resolved-outcome progress, capped at
    // the lowest still-pending message sequence (none here).
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — settled below
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null); // seq 3 — settled below
    _ = try client.sendAgentMessage(sid, "{\"m\":3}", null); // seq 4 — settled below
    for (0..3) |_| {
        var settled = agent_types.Envelope{
            .session_id = sid,
            .message_id = agent_types.generateUlid(),
            .sequence = 5,
            .in_reply_to = null,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
        };
        defer settled.deinit(allocator);
        try client.processEnvelope(settled);
    }
    try std.testing.expectEqual(@as(usize, 0), client.pending_sends_by_session.getPtr(sid).?.items.len);
    try std.testing.expectEqual(@as(u64, 5), client.peekNextSequence(sid));

    const stale_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":stale}", null, 2); // prior 5, tracker 3
    var duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stale_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = stale_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer duplicate.deinit(allocator);
    try client.processEnvelope(duplicate);

    // The settled 5 survives (the stale payload's failure still SURFACES —
    // it never ran); the next ordinary send continues at the proven 5
    // instead of replaying 3 and 4 as surfaced rejections.
    try std.testing.expectEqual(@as(u64, 5), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    const remaining = if (client.pending_sends_by_session.getPtr(sid)) |l| l.items.len else 0;
    try std.testing.expectEqual(@as(usize, 0), remaining);
    _ = try client.sendAgentMessage(sid, "{\"m\":4}", null);
    var next_env = try harness.envelopeAt(5); // start, m1, m2, m3, stale, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 5), next_env.sequence);
}

test "AgentProtocolClient duplicate_sequence nack on a mismatched payload at a pending sequence is not a retry (#210 gap 7)" {
    // The retry match is sequence AND payload identity: a DIFFERENT
    // payload sent at a still-pending sequence is a new logical request.
    // A duplicate_sequence answer for it proves only that the EARLIER
    // payload was admitted — the new one was never executed, nothing will
    // settle it, so the rejection surfaces instead of retiring silently.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — accepted, reply outstanding
    const other_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":OTHER}", null, 2); // DIFFERENT payload at the pending sequence

    var duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = other_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = other_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer duplicate.deinit(allocator);
    try client.processEnvelope(duplicate);

    // The proven step is kept (the server is past 2) but the failure
    // SURFACES — the other payload was never run.
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len); // the ORIGINAL m1 remains; the mismatched send retired
}

test "AgentProtocolClient settlement restores progress a delayed busy answer rewound (#210 gap 7)" {
    // An attempt at sequence 2 is answered agent_busy with the reply
    // DELAYED; an explicit retry at 2 is accepted (the server advances to
    // 3). When the delayed busy finally arrives, its parity floor rewinds
    // the tracker to 2 — correct as of the ANSWER, stale as of NOW. The
    // retry's settlement then proves the counter advanced past 2 and
    // restores 3, so the next ordinary send does not replay the consumed
    // sequence.
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
    const first_id = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — busy, reply delayed
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2); // the retry — ACCEPTED, tracker 3

    var delayed_busy = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = first_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_busy, .message = try allocator.dupe(u8, "session already processing a message") } },
    };
    defer delayed_busy.deinit(allocator);
    try client.processEnvelope(delayed_busy);
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid)); // the stale parity floor

    var settled = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer settled.deinit(allocator);
    try client.processEnvelope(settled);
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid)); // the settlement's proof restored

    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);
    var next_env = try harness.envelopeAt(3); // start, first, retry, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), next_env.sequence);
}

test "AgentProtocolClient duplicate restore retains clean priors of backward pending sends (#210 gap 7)" {
    // Settled turns establish the server at 5; backward explicit sends at
    // 3 (prior 5 — clean, nothing was pending when it was recorded) and
    // then 2 (prior 4 — regressed). When the sequence-2 duplicate arrives
    // FIRST, a universal cap at the lowest pending sequence (3) would
    // restore only 3; but the sequence-3 record's own prior is proven up
    // to ITS contaminators (none), so the settled 5 survives. With the
    // sequence-3 reply lost, the next ordinary send continues at 5 instead
    // of replaying consumed sequences as surfaced rejections.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — settled below
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null); // seq 3 — settled below
    _ = try client.sendAgentMessage(sid, "{\"m\":3}", null); // seq 4 — settled below
    for (0..3) |_| {
        var settled = agent_types.Envelope{
            .session_id = sid,
            .message_id = agent_types.generateUlid(),
            .sequence = 5,
            .in_reply_to = null,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
        };
        defer settled.deinit(allocator);
        try client.processEnvelope(settled);
    }
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":back-3}", null, 3); // prior 5, clean
    const back_two_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":back-2}", null, 2); // prior 4, regressed

    var duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = back_two_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = back_two_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer duplicate.deinit(allocator);
    try client.processEnvelope(duplicate);

    // The sequence-3 record's clean prior 5 survives the restore.
    try std.testing.expectEqual(@as(u64, 5), client.peekNextSequence(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len); // the backward-3 record remains for its own reply
    _ = try client.sendAgentMessage(sid, "{\"m\":4}", null);
    var next_env = try harness.envelopeAt(6); // start, m1..m3, back-3, back-2, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 5), next_env.sequence);
}

test "AgentProtocolClient rejected source clears stale retry provenance (#210 gap 7)" {
    // While sequence 2 is busy: payload A is sent at 2, then payload B at
    // 2 after the server goes idle (B is ADMITTED), then a retry of A at
    // 2. A's delayed agent_busy finally arrives — A never ran. The retry's
    // recorded provenance (A was pending when it was recorded) is now
    // stale: re-derived against the REMAINING records, it is not a retry
    // of any unresolved same-payload original, so its duplicate answer
    // SURFACES instead of retiring silently as though A had executed.
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
    const first_a_id = try client.sendAgentMessage(sid, "{\"m\":A}", null); // seq 2 — busy, reply delayed
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":B}", null, 2); // ADMITTED after the run went idle
    const retry_a_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2); // retry of the pending A

    var delayed_busy = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = first_a_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_busy, .message = try allocator.dupe(u8, "session already processing a message") } },
    };
    defer delayed_busy.deinit(allocator);
    try client.processEnvelope(delayed_busy);

    var duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = retry_a_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = retry_a_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer duplicate.deinit(allocator);
    try client.processEnvelope(duplicate);

    // Only B ran; the A-retry never executed — its duplicate answer
    // surfaces, and B's record remains pending for its own settlement.
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid)); // past the consumed 2
}

test "AgentProtocolClient rejects an un-advanceable explicit stop sequence (#210 gap 7)" {
    // maxInt(u64) would be installed into the tracker by the explicit
    // stop's resync, and a later start's seq + 1 would overflow (trap in
    // safety-checked builds) — rejected before any mutation, like the
    // message variant.
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1, tracker 2

    try std.testing.expectError(error.InvalidSequence, client.sendAgentStopWithSequence(sid, "never", std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid)); // untouched
    try std.testing.expectEqual(@as(usize, 1), harness.writes.items.len); // the start only
}

test "AgentProtocolClient retry identity canonicalizes empty options to absence (#210 gap 7)" {
    // The request surface and the serializer treat options_json = "" and
    // null identically on the wire; the retry digest must too, or the same
    // wire request spelled the other way is misclassified as a non-retry
    // and its duplicate answer becomes a false terminal error.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — reply lost
    const retried_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", "", 2); // same wire request, empty-spelled options

    var duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = retried_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = retried_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer duplicate.deinit(allocator);
    try client.processEnvelope(duplicate);

    // Same wire request → retry → silent retire, no false failure.
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(!client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));

    // The digest itself canonicalizes.
    try std.testing.expectEqual(messagePayloadHash("{\"m\":1}", null), messagePayloadHash("{\"m\":1}", ""));
}

test "AgentProtocolClient duplicate restore ignores a forward pending explicit send's optimistic mirror (#210 gap 7)" {
    // The server expects 2; a forward explicit send at 7 is gap-rejected
    // with its reply delayed, leaving a pending record and an optimistic
    // tracker of 8; an accepted message at 2 and a matching retry at 2
    // follow. The retry's duplicate answer proves past 2 — and NOTHING
    // more: the 8 lives only in unresolved sends' mirrors (the send at 7
    // may have been gap-rejected), so the restore is 3, never 7 or 8, and
    // the next ordinary send continues at 3 instead of being gap-rejected.
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
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":forward}", null, 7); // gap-rejected, reply delayed, tracker 8
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2); // accepted, tracker 3
    const retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2); // the retry

    var duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = retry_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = retry_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer duplicate.deinit(allocator);
    try client.processEnvelope(duplicate);

    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid)); // the proven step, never the mirror 8
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 2), pending.items.len); // the forward send and the accepted original remain

    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);
    var next_env = try harness.envelopeAt(4); // start, forward, original, retry, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), next_env.sequence);
}

test "AgentProtocolClient two retries of a rejected payload cannot vouch for each other (#210 gap 7)" {
    // The original payload A is rejected (busy, delayed); retries r1 and
    // r2 of A remain. Directionless provenance would let each retry treat
    // the other as an unresolved same-payload source and keep suppressing
    // their duplicate answers after A's rejection — but only some OTHER
    // payload can have consumed the sequence. Provenance is directional
    // and transitive: rejecting A breaks the chain, both retries surface.
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
    const original_id = try client.sendAgentMessage(sid, "{\"m\":A}", null); // seq 2 — busy, reply delayed
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2); // retry 1
    const second_retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2); // retry 2

    var delayed_busy = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = original_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_busy, .message = try allocator.dupe(u8, "session already processing a message") } },
    };
    defer delayed_busy.deinit(allocator);
    try client.processEnvelope(delayed_busy);

    var duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = second_retry_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = second_retry_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer duplicate.deinit(allocator);
    try client.processEnvelope(duplicate);

    // A never ran; the consumed sequence was another payload's — the
    // retry's duplicate answer SURFACES instead of retiring silently.
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid)); // past the consumed 2
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len); // retry 1 remains for its own reply
}

test "AgentProtocolClient generic backward rejections never floor below proven progress (#210 gap 7)" {
    // Settled turns establish the server at 5; explicit backward sends at
    // 3 and then 2 are both rejected (invalid_request collapses backward
    // and forward, server.zig). The sequence-2 rejection is processed
    // first: its all-rejected floor would pin the tracker at 3 (the still
    // pending sequence-3 record) — but the settled 5 is PROVEN and the
    // counter never moves backward, so the floor retains it; the later
    // sequence-3 rejection keeps it, and the next ordinary send continues
    // at 5 instead of replaying consumed sequences.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — settled below
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null); // seq 3 — settled below
    _ = try client.sendAgentMessage(sid, "{\"m\":3}", null); // seq 4 — settled below
    for (0..3) |_| {
        var settled = agent_types.Envelope{
            .session_id = sid,
            .message_id = agent_types.generateUlid(),
            .sequence = 5,
            .in_reply_to = null,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
        };
        defer settled.deinit(allocator);
        try client.processEnvelope(settled);
    }
    const back_three_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":back-3}", null, 3); // prior 5
    const back_two_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":back-2}", null, 2); // prior 4, tracker 3

    var first_rejected = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = back_two_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer first_rejected.deinit(allocator);
    try client.processEnvelope(first_rejected);
    try std.testing.expectEqual(@as(u64, 5), client.peekNextSequence(sid)); // the proven 5 survives the floor

    var second_rejected = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = back_three_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer second_rejected.deinit(allocator);
    try client.processEnvelope(second_rejected);
    try std.testing.expectEqual(@as(u64, 5), client.peekNextSequence(sid));

    _ = try client.sendAgentMessage(sid, "{\"m\":4}", null);
    var next_env = try harness.envelopeAt(6); // start, m1..m3, back-3, back-2, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 5), next_env.sequence);
}

test "AgentProtocolClient settlement raise uses the minimum candidate, not the retired record (#210 gap 7)" {
    // A forward explicit send at 7 fails ambiguously (gap-rejected, reply
    // lost) while a later explicit send at the CORRECT sequence 2 is
    // accepted; its settlement retires the OLDEST pending message — the
    // stale send at 7 (the FIFO residual). The raise must use the MINIMUM
    // candidate sequence (2 + 1 = 3): the heuristically retired record's
    // own sequence (7 + 1 = 8) proves nothing and would gap-reject every
    // later ordinary send.
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
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":forward}", null, 7); // gap-rejected, reply lost
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2); // the accepted one, tracker 3

    var settled = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer settled.deinit(allocator);
    try client.processEnvelope(settled);

    // The stale forward record retired (oldest), the tracker stayed at 3 —
    // never raised to the retired record's 8.
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len); // the accepted record remains
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);
    var next_env = try harness.envelopeAt(3); // start, forward, original, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), next_env.sequence);
}

test "AgentProtocolClient rejected stop undo caps a contaminated pre-resync tracker (#210 gap 7)" {
    // The server expects 2; a forward explicit message at 7 leaves a
    // pending record and an optimistic tracker of 8; an explicit stop at 1
    // resyncs the tracker to 1. Its correlated rejection undoes the
    // resync — but the pre-resync value (8) came solely from the
    // unresolved send's mirror: the undo restores the prior CAPPED by the
    // pending messages' floor (2), so the next ordinary send carries 2,
    // not 8.
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1, server expects 2
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
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":forward}", null, 7); // pending, tracker 8
    const stop_id = try client.sendAgentStopWithSequence(sid, "stale", 1); // resync, prior 8, tracker 1

    var rejected = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer rejected.deinit(allocator);
    try client.processEnvelope(rejected);

    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid)); // capped undo, never the mirror 8
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    var next_env = try harness.envelopeAt(3); // start, forward, stop, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), next_env.sequence);
}

test "AgentProtocolClient stop setup failure restores the compatibility mirror (#210 gap 7)" {
    // Nothing reaches the wire on a pre-wire allocation failure, so the
    // deprecated mirror must not keep the attempted value — callers
    // observing it would see a phantom send. Sweep every pre-wire
    // allocation failure of the explicit stop path.
    const allocator = std.testing.allocator;
    const sid = agent_types.generateSessionId();
    var exercised_failure = false;
    for (0..6) |fail_index| {
        var harness = Gap7Harness.init();
        defer harness.deinit();
        harness.wire();
        const client = &harness.client;
        _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1, tracker 2, mirror 1
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        client.allocator = failing.allocator();
        const sent = client.sendAgentStopWithSequence(sid, "teardown", 5);
        client.allocator = allocator;
        const failed = if (sent) |_| false else |_| true;
        if (!failed) continue;
        exercised_failure = true;
        try std.testing.expectEqual(@as(usize, 1), harness.writes.items.len); // the start only — nothing sent
        try std.testing.expectEqual(@as(u64, 1), client.sequence); // the mirror restored
        try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid)); // the tracker restored
    }
    try std.testing.expect(exercised_failure); // the sweep actually hit the failure paths
}

test "AgentProtocolClient duplicate_sequence nack on a non-retry send preserves the high-water and surfaces (#210 gap 7)" {
    // Sequence 2 settled; the peer expects 3; a FRESH explicit send at 2
    // (not a retry of any unresolved original) is answered
    // duplicate_sequence. The code still proves the server past 2, so the
    // high-water is preserved — but no run of this envelope will ever
    // settle, so the rejection surfaces instead of being swallowed.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — accepted
    var settled = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer settled.deinit(allocator);
    try client.processEnvelope(settled);
    const stale_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2); // fresh send at the consumed sequence

    var duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stale_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = stale_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer duplicate.deinit(allocator);
    try client.processEnvelope(duplicate);

    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid)); // high-water preserved, never the rollback
    try std.testing.expect(client.getLastErrorForSession(sid) != null); // surfaced: nothing will settle this envelope
    try std.testing.expect(client.isSessionComplete(sid));
    const remaining = if (client.pending_sends_by_session.getPtr(sid)) |l| l.items.len else 0;
    try std.testing.expectEqual(@as(usize, 0), remaining);
}

test "AgentProtocolClient resend provenance survives the original's settlement (#210 gap 7)" {
    // The duplicate evidence for a resend is recorded ON THE RESEND
    // (another unresolved message already carried the sequence when it was
    // sent), so the original's settlement processing — which retires the
    // original's record — does not erase it: the delayed duplicate answer
    // still resolves as duplicate-admitted instead of rolling the tracker
    // back to the consumed sequence with a false terminal error.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — accepted, output lost
    const resend_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2); // retry of the pending original

    // The original settles FIRST (its result arrives before the resend's
    // delayed duplicate answer), retiring the oldest message record.
    var settled = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer settled.deinit(allocator);
    try client.processEnvelope(settled);

    var mismatch = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = resend_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = resend_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer mismatch.deinit(allocator);
    try client.processEnvelope(mismatch);

    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid)); // high-water kept
    try std.testing.expect(client.getLastErrorForSession(sid) == null); // no false failure
    // (The session's complete flag is TRUE here — the settlement that
    // retired the original set it, which is its legitimate effect.)
    const remaining = if (client.pending_sends_by_session.getPtr(sid)) |l| l.items.len else 0;
    try std.testing.expectEqual(@as(usize, 0), remaining); // both records resolved
}

test "AgentProtocolClient generic invalid_request on a resend stays ambiguous — floors to the original's sequence (#210 gap 7)" {
    // The agent surface collapses already-consumed and never-accepted
    // mismatches into one code, and another pending record with the same
    // sequence proves only that the original's outcome is UNRESOLVED — not
    // that it was admitted. The rejection therefore takes the ordinary
    // path with the still-unresolved records' floors: the tracker rolls to
    // the original's own sequence — the counter the server holds in the
    // all-rejected world — and the failure surfaces. A too-low floor
    // self-heals through duplicate evidence (the next send at the
    // original's sequence is answered duplicate_sequence and the
    // high-water restores); a tracker pinned ABOVE the server's true
    // counter would never recover.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 2 — outcome unresolved
    const resend_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2); // retry of the pending original

    var mismatch = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = resend_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer mismatch.deinit(allocator);
    try client.processEnvelope(mismatch);

    // The rollback floors to the still-pending ORIGINAL's own sequence (2)
    // — the counter the server holds when every unresolved admission
    // failed — while the failed send's record retires.
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) != null); // surfaced, not suppressed
    try std.testing.expect(client.isSessionComplete(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len); // the resend retired, the original remains
}
