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
    /// Whether a same-sequence same-payload record was already pending
    /// when this send was recorded — the send HAS same-payload ancestry,
    /// even when a competing payload masked its retry bit to false. The
    /// ancestry marker lets a later re-derivation mark the chain BROKEN
    /// when that ancestry dies (a rejected or duplicate-retired earlier
    /// copy), instead of mistaking the masked record for a fresh intact
    /// source once the competitor is gone (#210 gap 7).
    had_same_payload_ancestry: bool = false,
    /// Sticky: a same-sequence same-payload source SETTLED — a completed
    /// run demonstrably executed this payload at this sequence, the
    /// strongest silent-path justification there is. Granted only when
    /// UNAMBIGUOUS (every pending message record shares the retired
    /// record's sequence and payload — whichever record the run belonged
    /// to, it ran THIS payload at THIS sequence), inherited by later
    /// same-payload records at record time while a settled-flagged record
    /// remains pending, and immune to re-derivation: the settled source's
    /// own record is retired by the settlement, so a scan of the pending
    /// records alone would find no earlier source and falsely break the
    /// chain (#210 gap 7).
    source_settled: bool = false,
    /// The session's proven floor when this send was recorded, MIN-INHERITED
    /// from its unbroken same-payload ancestry: the silent duplicate path's
    /// justification is the SOURCE's admissibility (it could have been
    /// admitted and run), not the retry's — a retry recorded after the
    /// floor rose past the sequence keeps the silent path while its source
    /// predates the floor. Only when the ancestry itself was sent below an
    /// already-proven floor (no same-payload send was ever admissible, so
    /// nothing could have run or settled) is the silent path disqualified
    /// (#210 gap 7).
    proven_floor_at_send: u64 = 0,
    /// The session's tracker epoch when this send was recorded: EVERY
    /// later tracker write — another send's optimistic mirror or resync,
    /// a reconciliation's floor or restore — bumps the epoch, superseding
    /// this record's optimistic mirror. A pending record's mirror owns
    /// the current tracker value only while its own write was the LAST
    /// (its send epoch still equals the session's), so a later
    /// value-equal write — another send regressing onto the same number,
    /// or a stop resynced onto a superseded mirror's value — is not
    /// mistaken for the mirror's ownership (#210 gap 7).
    send_epoch: u64 = 0,
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
    /// The MINIMUM pre-resync prior over a session's REJECTED explicit
    /// stops (#210 gap 7): a rejected stop's resync is refuted, so any
    /// snapshot taken while it was live reverts to at most its prior —
    /// including snapshots of LATER stops resynced on top of it, whose own
    /// rejections arrive after this stop's record is gone.
    stop_revert_bound_by_session: std.AutoHashMap(agent_types.SessionId, u64),
    /// Bumped on EVERY write to a session's tracker — a send's optimistic
    /// mirror or resync, a reconciliation's floor or restore. Compared
    /// against a pending record's `send_epoch`, it tells a LIVE mirror
    /// (its own write was the last) from one a later write — of any
    /// kind — has superseded (#210 gap 7).
    tracker_epoch_by_session: std.AutoHashMap(agent_types.SessionId, u64),

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
            .stop_revert_bound_by_session = std.AutoHashMap(agent_types.SessionId, u64).init(allocator),
            .tracker_epoch_by_session = std.AutoHashMap(agent_types.SessionId, u64).init(allocator),
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
        self.stop_revert_bound_by_session.deinit();
        self.tracker_epoch_by_session.deinit();

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
        var has_competing_payload = false;
        var had_same_payload_ancestry = false;
        var inherits_settled_source = false;
        var same_payload_floor: u64 = std.math.maxInt(u64);
        for (gop.value_ptr.items) |pending| {
            if (pending.kind != .message or pending.sequence != sequence) continue;
            if (pending.payload_hash == payload_hash) {
                had_same_payload_ancestry = true;
                if (!pending.provenance_broken) {
                    resend_of_pending = true;
                    same_payload_floor = @min(same_payload_floor, pending.proven_floor_at_send);
                }
                if (pending.source_settled) inherits_settled_source = true;
            } else {
                has_competing_payload = true;
            }
        }
        // A COMPETING different-payload record at the same sequence
        // disqualifies the silent path: a later duplicate_sequence answer
        // proves only that SOMEONE consumed the sequence — the competing
        // payload explains it without this send's source ever having run
        // (an ambiguously-failed send's record may linger while another
        // payload was admitted at the sequence), so the rejection must
        // surface instead of retiring silently (#210 gap 7). The mask is
        // recorded at SEND time on purpose: the competitor may resolve
        // (settle, retire) before the duplicate answer arrives, and a scan
        // of the then-current records alone would no longer see it. A
        // BROKEN same-payload record is no ancestry either — its source
        // never ran, so it cannot justify this send's silent retirement
        // (the ancestry marker is still recorded for the re-derivation;
        // see `had_same_payload_ancestry`).
        if (has_competing_payload) resend_of_pending = false;
        // Settled provenance outranks the competitor mask: a completed run
        // demonstrably executed this payload at this sequence, so the
        // send's duplicate answer is silently justified however the
        // pending set reads now — the fact must survive the mask, or a
        // later re-derivation (which never touches settled records) would
        // leave a settled record pinned at a masked-false bit forever
        // (#210 gap 7). The answer-time competing check still gates while
        // the competitor remains.
        if (inherits_settled_source) resend_of_pending = true;
        // The floor snapshot MIN-INHERITS the unbroken same-payload
        // ancestry's own snapshots (see `proven_floor_at_send`): the
        // silent path is judged by whether the SOURCE could have been
        // admitted, never by the retry's newer floor (#210 gap 7).
        const floor_at_send = if (same_payload_floor == std.math.maxInt(u64)) self.provenFloor(session_id) else @min(self.provenFloor(session_id), same_payload_floor);
        try gop.value_ptr.append(self.allocator, .{ .msg_id = msg_id, .sequence = sequence, .kind = kind, .prior_tracker = prior_tracker, .payload_hash = payload_hash, .resend_of_pending = resend_of_pending, .had_same_payload_ancestry = had_same_payload_ancestry, .source_settled = inherits_settled_source, .proven_floor_at_send = if (kind == .message) floor_at_send else 0, .send_epoch = self.trackerEpoch(session_id) });
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
        // The tracker mirrors seq + 1 optimistically: a start attempted while
        // the tracker sits at maxInt(u64) (left by an explicit maxInt-1
        // message against this session) is un-advanceable — evaluating the
        // mirror would trap in safety-checked builds — so it is rejected
        // before any mutation or wire write (#210 gap 7).
        if (seq == std.math.maxInt(u64)) return error.InvalidSequence;
        const start_json = try self.serializeEnvelopeForSend(.{
            .session_id = sid,
            .message_id = msg_id,
            .sequence = seq,
            .timestamp = compat.time.nowMillis(),
            .payload = payload,
        });
        defer self.allocator.free(start_json);
        try self.setTrackerValue(sid, seq + 1);
        self.sequence = seq; // compatibility mirror
        self.recordPendingSend(sid, msg_id, seq, .start, seq, 0) catch |err| {
            // Nothing reached the wire: restore the tracker so a retry of the
            // start reuses `seq` instead of running ahead of the server.
            self.setTrackerValue(sid, seq) catch {};
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
        try self.setTrackerValue(session_id, sequence + 1);
        self.sequence = sequence; // compatibility mirror
        self.recordPendingSend(session_id, msg_id, sequence, .message, prior_sequence, messagePayloadHash(message_json, options_json)) catch |err| {
            // Nothing reached the wire: restore the PRE-SEND state so the
            // client is exactly as it was before the failed attempt (#210
            // gap 7).
            self.setTrackerValue(session_id, prior_sequence) catch {};
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
    /// past the given value. Unlike a message or start, a stop never
    /// computes `sequence + 1` — an accepted stop consumes the counter
    /// WITH the session (clearing the tracker) and a rejected one leaves
    /// the value in place — so `maxInt(u64)` itself is a legal stop
    /// sequence (the teardown of a session whose counter reached the
    /// ceiling); a later START against a tracker at the maximum is
    /// rejected there instead.
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
        self.setTrackerValue(session_id, sequence) catch |err| {
            self.sequence = prior_mirror;
            return err;
        };
        self.recordPendingSend(session_id, msg_id, sequence, .stop, prior, 0) catch |err| {
            // Nothing reached the wire: restore the pre-send state, the
            // compatibility mirror included (#210 gap 7).
            self.setTrackerValue(session_id, prior) catch {};
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
                // The start's acceptance PROVES the server's counter
                // advanced past the start's sequence (an accepted start
                // consumes it, §13.1): seed the proven floor, so a later
                // all-rejected floor (stale sequence-1 message records
                // rejected with the collapsed generic invalid_request)
                // cannot pin the tracker below it and wedge every
                // subsequent ordinary send (#210 gap 7).
                if (self.pendingSendFor(p.session_id, env.in_reply_to)) |start| {
                    if (start.kind == .start) {
                        try self.noteProvenFloor(p.session_id, start.sequence + 1);
                        self.invalidateBelowFloorAfterStart(p.session_id);
                    }
                } else {
                    // An ADOPTED start (uncorrelated — a generated-id
                    // response or a restored client receiving the reply)
                    // still proves the registration consumed sequence 1.
                    try self.noteProvenFloor(p.session_id, 2);
                    self.invalidateBelowFloorAfterStart(p.session_id);
                }
                // The adopted-start world may hold the live tracker at its
                // fresh value while the server already expects 2: raise the
                // tracker to the proven floor so the first ordinary message
                // is not rejected on a consumed sequence (#210 gap 7). The
                // raise itself stays best-effort — the floor NOTE above is
                // the durable evidence (a dropped raise self-heals through
                // duplicate evidence; a dropped floor does not).
                if (self.peekNextSequence(p.session_id) < self.provenFloor(p.session_id)) {
                    self.setTrackerValue(p.session_id, self.provenFloor(p.session_id)) catch {};
                }
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
                // the counter advanced past the minimum pending-message
                // sequence, so a tracker below that (a DELAYED busy answer's
                // parity floor for a retry that was actually accepted, or a
                // rejection's all-rejected floor) is raised — best-effort,
                // since duplicate evidence lifts a tracker left low by an
                // allocation failure here.
                if (self.retireSettledPendingSends(env.session_id)) |min_candidate_sequence| {
                    try self.noteProvenFloor(env.session_id, min_candidate_sequence + 1);
                    const target = self.provenFloor(env.session_id);
                    if (self.peekNextSequence(env.session_id) < target) {
                        self.setTrackerValue(env.session_id, target) catch {};
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
                // tracked requests — without it, a peer that rejects an
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
                // record retires, the tracker takes the one PROVEN step
                // (sequence + 1), and no session error is recorded (the
                // admitted copy's run may still be live) (#210 gap 7).
                const duplicate_admitted = if (n.error_code) |code| code == .duplicate_sequence else false;
                if (duplicate_admitted) {
                    // Only for a MESSAGE send, and only when it is a RETRY of
                    // a still-unresolved original (resend_of_pending): an
                    // earlier copy of the sequence was admitted, the code
                    // proves the server is past it, and the ORIGINAL's run
                    // may still settle — so the record retires with only the
                    // PROVEN step and no session error. A duplicate answer
                    // on a NON-retry send admits nothing of this caller's
                    // own state: no run of the envelope will produce a
                    // settlement, so the proven step is kept but the
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
                            // The silent path requires no COMPETING payload
                            // at the sequence NOW — a competitor recorded
                            // after this send makes the duplicate answer
                            // ambiguous even though the recorded bit predates
                            // it — AND an ancestry that was ever admissible:
                            // the record's floor snapshot is min-inherited
                            // from its unbroken same-payload sources, so a
                            // snapshot above the sequence means no
                            // same-payload send was ever admissible (every
                            // copy was sent below an already-proven floor),
                            // nothing could have run or settled, and the
                            // duplicate must surface. A SETTLED source is
                            // exempt: the settlement demonstrably ran this
                            // payload at this sequence, directly
                            // contradicting the rule's nothing-could-have-run
                            // premise — the settled fact outranks the floor
                            // heuristic exactly as it outranks the
                            // competitor mask (#210 gap 7).
                            if (entry.resend_of_pending and (entry.source_settled or entry.proven_floor_at_send <= entry.sequence) and !self.hasCompetingPayload(env.session_id, entry.sequence, entry.payload_hash)) return;
                            // The retired record was itself
                            // rejected-as-duplicate — it never ran — so its
                            // same-payload descendants' silent justification
                            // dies with it, AND its removal can re-qualify
                            // other payloads' retries for the silent path
                            // (their recorded bit was false only because
                            // this competitor existed). Re-derive everything
                            // at the sequence against the current records
                            // (#210 gap 7).
                            self.rederiveProvenanceAt(env.session_id, entry.sequence);
                            // Not a qualifying retry: the proven step is
                            // already taken, so fall through and surface the
                            // failure.
                        } else if (entry.kind == .stop) {
                            // A duplicate_sequence answer for a STOP proves
                            // the counter is past the stop's sequence too
                            // (older peers answer stops this way): record
                            // the proven step — the ordinary stop-rejection
                            // path below still resolves the record (undoing
                            // any resync, max the floor) and surfaces the
                            // failure (#210 gap 7). The step is
                            // overflow-safe: a stop may carry maxInt(u64)
                            // (the ceiling teardown), and no counter can be
                            // past the maximum, so there is no step to note.
                            if (entry.sequence != std.math.maxInt(u64)) try self.noteProvenFloor(env.session_id, entry.sequence + 1);
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
                _ = self.stop_revert_bound_by_session.remove(p.session_id);
                _ = self.tracker_epoch_by_session.remove(p.session_id);
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
    /// The settlement also reconciles the sequence's provenance, in two
    /// asymmetric moves (the attribution above is a heuristic — agent_result
    /// carries no run identity, §13.3.2 — so the two moves differ in how
    /// much of it they trust):
    ///
    /// GRANT (settled justification), only when UNAMBIGUOUS — every
    /// pending message record shares the retired record's sequence and
    /// payload: whichever record the run belonged to, it demonstrably ran
    /// THIS payload at THIS sequence, so the remaining same-pair records'
    /// retry bits are set TRUE and made immune to re-derivation (the
    /// settled source's own record retires here, and a pending-only scan
    /// would later find no earlier source and falsely break the chain).
    /// Granting on the attribution alone would bless the wrong payload
    /// when the oldest record is a rejected send whose reply was lost —
    /// a false SILENT, the unrecoverable direction.
    ///
    /// BREAK (negative evidence), attribution-trusting: the remaining
    /// DIFFERENT-payload records at the retired record's sequence are
    /// marked broken — the settled run consumed that sequence, so those
    /// payloads never ran there and cannot requalify for the silent path
    /// through a later re-derivation. If the attribution was wrong (the
    /// oldest record was a stale rejected send), the break is a false
    /// SURFACE — the payload actually ran, its settlement already
    /// delivered the outcome, and the surfaced duplicate self-corrects —
    /// the safe direction (#210 gap 7).
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
        const pending = list.items[index];
        var unambiguous = true;
        for (list.items) |candidate| {
            if (candidate.kind != .message) continue;
            if (candidate.sequence != pending.sequence or candidate.payload_hash != pending.payload_hash) unambiguous = false;
        }
        for (list.items) |*other| {
            if (other.kind != .message or other.sequence != pending.sequence) continue;
            if (other.payload_hash == pending.payload_hash) {
                if (!unambiguous) continue;
                other.source_settled = true;
                other.provenance_broken = false;
                other.resend_of_pending = true;
            } else {
                other.provenance_broken = true;
                other.resend_of_pending = false;
            }
        }
        _ = list.orderedRemove(index);
        return min_candidate;
    }

    /// Whether `in_reply_to` names one of the session's tracked pending
    /// sends — i.e. the reply belongs to a request of the CURRENT
    /// registration (a start, message, or stop this client sent and has not
    /// yet resolved).
    fn replyNamesPendingSend(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid) bool {
        return self.pendingSendFor(session_id, in_reply_to) != null;
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
    /// (their sends are unresolved) and never touch it. An allocation
    /// failure PROPAGATES rather than dropping the evidence: callers were
    /// told their envelope was processed, and a silently forgotten bound
    /// can wedge the tracker on a consumed sequence (#210 gap 7).
    fn noteProvenFloor(self: *Self, session_id: agent_types.SessionId, bound: u64) !void {
        const current = self.proven_floor_by_session.get(session_id) orelse 0;
        if (bound > current) try self.proven_floor_by_session.put(session_id, bound);
    }

    fn provenFloor(self: *Self, session_id: agent_types.SessionId) u64 {
        return self.proven_floor_by_session.get(session_id) orelse 0;
    }

    /// An accepted start consumed EVERY sequence below the proven floor it
    /// seeds: a pending MESSAGE record at a sequence below that floor (in
    /// send order around the start) could never have been admitted, so
    /// neither it nor any same-payload source could run or settle — its
    /// silent duplicate justification dies here, at the causal evidence
    /// rather than at the record's earlier send-time snapshot (a record
    /// sent before the started reply was processed snapshots the old
    /// floor and would otherwise stay eligible). Settled records are
    /// exempt: their run demonstrably executed the payload (#210 gap 7).
    fn invalidateBelowFloorAfterStart(self: *Self, session_id: agent_types.SessionId) void {
        const floor = self.provenFloor(session_id);
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return;
        for (list.items) |*pending| {
            if (pending.kind != .message) continue;
            if (pending.source_settled) continue;
            if (pending.sequence >= floor) continue;
            pending.provenance_broken = true;
            pending.resend_of_pending = false;
        }
    }

    fn trackerEpoch(self: *Self, session_id: agent_types.SessionId) u64 {
        return self.tracker_epoch_by_session.get(session_id) orelse 0;
    }

    /// Supersedes the optimistic mirrors of every earlier still-pending
    /// send: only the LAST tracker write owns the value (#210 gap 7).
    ///
    /// Writes the session's tracker value. EVERY write — a send's
    /// optimistic mirror or resync, a reconciliation's floor or restore —
    /// bumps the session's tracker epoch, so a pending record's mirror
    /// owns the current value only while its own write was the last
    /// (#210 gap 7). The epoch entry is reserved FIRST: a spurious zero
    /// epoch left by a failed write is indistinguishable from an absent
    /// one, so a failure between the two reservations leaves no
    /// observable partial state — while a half-applied write (the value
    /// stored, the epoch not bumped) would move the tracker with no
    /// ownership supersession and let the next send skip the server's
    /// expected sequence.
    fn setTrackerValue(self: *Self, session_id: agent_types.SessionId, value: u64) !void {
        const epoch_gop = try self.tracker_epoch_by_session.getOrPut(session_id);
        const tracker_gop = try self.next_sequence_by_session.getOrPut(session_id);
        if (!epoch_gop.found_existing) epoch_gop.value_ptr.* = 0;
        tracker_gop.value_ptr.* = value;
        epoch_gop.value_ptr.* += 1;
    }

    /// Whether a DIFFERENT-payload message record is still pending at the
    /// sequence — a competing payload explains a duplicate answer without
    /// the same-payload source having run, disqualifying the silent path
    /// (#210 gap 7).
    fn hasCompetingPayload(self: *Self, session_id: agent_types.SessionId, sequence: u64, payload_hash: u64) bool {
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return false;
        for (list.items) |pending| {
            if (pending.kind != .message or pending.sequence != sequence) continue;
            if (pending.payload_hash != payload_hash) return true;
        }
        return false;
    }

    /// Re-derives the retry provenance of every same-sequence message
    /// record against the CURRENT record set (#210 gap 7). Used after a
    /// rejection removes a record AND after a NON-RETRY duplicate retires
    /// one: a duplicate answer means the retired record was itself
    /// rejected-as-duplicate — the sequence was consumed by an EARLIER
    /// envelope, so the retired record never ran and its same-payload
    /// descendants' silent justification dies with it (only a SETTLED
    /// source, whose run completed, leaves its descendants' recorded bits
    /// standing — and sets them). Provenance stays DIRECTIONAL (an earlier
    /// intact source), COMPETING-PAYLOAD-GATED, and TRANSITIVE (a bit that
    /// loses its source marks the chain broken, so later records cannot
    /// re-derive through it — the one-pass scan propagates a break through
    /// a whole chain of retries). Records with a settled source are
    /// skipped: their justification is settled fact, not pending state.
    fn rederiveProvenanceAt(self: *Self, session_id: agent_types.SessionId, sequence: u64) void {
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return;
        for (list.items, 0..) |*pending, i| {
            if (pending.kind != .message or pending.sequence != sequence) continue;
            if (pending.source_settled) continue;
            var viable_source = false;
            var has_competing_payload = false;
            var source_floor: u64 = std.math.maxInt(u64);
            for (list.items) |other| {
                if (other.kind != .message or other.sequence != sequence) continue;
                if (other.payload_hash != pending.payload_hash) has_competing_payload = true;
            }
            if (!has_competing_payload) {
                for (list.items[0..i]) |earlier| {
                    if (earlier.kind != .message or earlier.sequence != sequence) continue;
                    if (earlier.payload_hash != pending.payload_hash) continue;
                    if (earlier.provenance_broken) continue;
                    viable_source = true;
                    source_floor = @min(source_floor, earlier.proven_floor_at_send);
                }
            }
            if ((pending.resend_of_pending or pending.had_same_payload_ancestry) and !viable_source) pending.provenance_broken = true;
            pending.resend_of_pending = viable_source;
            // A re-derived retry is judged by its (newly found) source's
            // admissibility too — the snapshot MIN-INHERITS the source's
            // (see `proven_floor_at_send`) (#210 gap 7).
            if (viable_source) pending.proven_floor_at_send = @min(pending.proven_floor_at_send, source_floor);
        }
    }

    /// Retires a send proven duplicate-admitted by a `duplicate_sequence`
    /// answer and restores the tracker to `entry.sequence + 1` MAX the
    /// session's proven floor (#210 gap 7). The answer proves exactly ONE
    /// step — the counter is past the sent sequence — and every prior
    /// reconciliation's sound bound is remembered; nothing else
    /// participates: optimistic mirrors (the entry's own pre-send tracker,
    /// a remaining record's prior, an interleaved send's) are unproven and
    /// restoring any of them can jump the tracker past the server, making
    /// the next ordinary send a gap rejection. If the counter is higher
    /// than the restore, the next send at the restored value is answered
    /// `duplicate_sequence` in turn — and as a same-payload retry of a
    /// still-pending message it retires silently, advancing one PROVEN step
    /// per round trip. The successor is overflow-safe: a recorded send's
    /// sequence is always below maxInt(u64) (the send paths reject the
    /// maximum before any mutation).
    fn retireDuplicateAdmittedSend(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid, entry: PendingSend) !void {
        const restore = @max(entry.sequence + 1, self.provenFloor(session_id));
        self.retirePendingSend(session_id, in_reply_to);
        try self.noteProvenFloor(session_id, restore);
        try self.setTrackerValue(session_id, restore);
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
            _ = self.proven_floor_by_session.remove(session_id);
            _ = self.stop_revert_bound_by_session.remove(session_id);
            _ = self.tracker_epoch_by_session.remove(session_id);
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
        // never-admitted, the chain below it must re-derive — see
        // `rederiveProvenanceAt` for the directional, transitive, and
        // competing-payload-gated rules (#210 gap 7).
        if (rejected.kind == .message) {
            self.rederiveProvenanceAt(session_id, rejected.sequence);
        }
        // A rejected STOP never floors the tracker below proven bounds —
        // stops never advance the counter (§13.1), so the rejection itself
        // carries no counter evidence. The undo below applies ONLY to a
        // stop that actually RESYNCED the tracker (its caller-supplied
        // sequence differed from the prior): an ordinary stop — or an
        // explicit one resynced onto the current value — made no tracker
        // move, so there is nothing to undo and its rejection only lifts
        // the tracker to the proven floor. A resync's undo — only when the
        // tracker still holds the stop's own value (later sends may have
        // moved it, and the rejection says nothing about them) — restores
        // the pre-resync prior CAPPED by the still-pending messages'
        // all-rejected floor (the prior snapshot may itself be contaminated
        // by an unresolved send's optimistic mirror) and MAXED with the
        // session's proven floor (#210 gap 7).
        if (rejected.kind == .stop) {
            if (rejected.prior_tracker == rejected.sequence) {
                // No resync happened — retain the current value, subject
                // to the proven floor (a stop's own duplicate_sequence
                // step included) (#210 gap 7).
                if (self.peekNextSequence(session_id) < self.provenFloor(session_id)) {
                    self.setTrackerValue(session_id, self.provenFloor(session_id)) catch {};
                }
                return;
            }
            // The pre-resync prior is the world-if-this-stop-rejected: any
            // snapshot taken while this resync was live — including a LATER
            // stop's own prior, resynced on top of it — reverts to at most
            // it. It joins the session's revert bound even when the live
            // undo below is skipped (a newer resync moved the tracker);
            // without that, the newer stop's rejection would restore a
            // value this stop's refuted resync had contaminated (#210
            // gap 7).
            const prior_bound = rejected.prior_tracker;
            const existing_revert = self.stop_revert_bound_by_session.get(session_id);
            const revert_bound = if (existing_revert) |e| @min(e, prior_bound) else prior_bound;
            // Stored under `try`: a dropped bound would let a LATER stop's
            // rejection restore a prior this refuted resync had
            // contaminated — the failure must surface, not vanish (#210
            // gap 7).
            try self.stop_revert_bound_by_session.put(session_id, revert_bound);
            // The undo guard is OWNERSHIP, not value equality: a later
            // send's optimistic mirror can coincidentally equal the stop's
            // resync value (a message accepted at 6 mirrors the tracker to
            // 7 just like a stop resynced to 7), and rewinding on the
            // stop's rejection would destroy the accepted send's mirror.
            // A mirror owns the current value only while it is still
            // LIVE — its send epoch must equal the session's current
            // tracker epoch, so its own write was the last: ANY later
            // tracker write (another send's mirror or resync, a
            // reconciliation) superseded it, and a later value-equal
            // write does not resurrect it (#210 gap 7).
            var mirror_owner_pending = false;
            for (list.items) |pending| {
                if (pending.kind == .stop) continue;
                if (pending.send_epoch != self.trackerEpoch(session_id)) continue;
                if (pending.sequence + 1 == self.peekNextSequence(session_id)) mirror_owner_pending = true;
            }
            if (!mirror_owner_pending and self.peekNextSequence(session_id) == rejected.sequence) {
                var pending_floor: u64 = revert_bound;
                for (list.items) |pending| {
                    if (pending.kind == .message) {
                        pending_floor = @min(pending_floor, @min(pending.sequence, pending.prior_tracker));
                    } else if (pending.kind == .stop) {
                        // Another unresolved stop's resync is caller-asserted
                        // (see the floor loop below) — only its pre-resync
                        // prior bounds the counter (#210 gap 7).
                        pending_floor = @min(pending_floor, pending.prior_tracker);
                    }
                }
                var undo = pending_floor;
                undo = @max(undo, self.provenFloor(session_id));
                try self.noteProvenFloor(session_id, undo);
                try self.setTrackerValue(session_id, undo);
            } else if (self.peekNextSequence(session_id) < self.provenFloor(session_id)) {
                // The undo can be skipped for good reason — a live mirror
                // owns the current value, or a later write moved the
                // tracker — but the proven floor is monotone evidence: a
                // tracker sitting below it (e.g. below the step the stop's
                // own duplicate_sequence answer just proved) is stale
                // wherever it came from, and a pending mirror can only
                // explain values ABOVE the floor. Raise it (#210 gap 7).
                self.setTrackerValue(session_id, self.provenFloor(session_id)) catch {};
            }
            return;
        }
        // A correlated `agent_busy` proves the server's counter EQUALS the
        // rejected sequence: the server validates the inbound sequence
        // BEFORE the processing state (handleMessage), so a busy answer
        // means the sequence MATCHED — every lower sequence was consumed —
        // and busy never advances the counter (§13.1). This matters most
        // for an EXPLICIT recovery send: rolling it back to its pre-send
        // tracker (a stale 1 against a server at 7) would have the retry
        // replay the stale value instead of the busy-proven sequence. The
        // all-rejected floor below would replay an already-consumed
        // sequence and be rejected again (#210 gap 7).
        const busy = if (code) |c| c == .agent_busy else false;
        if (busy) {
            const parity = @max(rejected.sequence, self.provenFloor(session_id));
            try self.noteProvenFloor(session_id, parity);
            try self.setTrackerValue(session_id, parity);
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
            if (pending.kind == .message) {
                floor = @min(floor, pending.prior_tracker);
                floor = @min(floor, pending.sequence);
            } else if (pending.kind == .stop) {
                // An unresolved stop's RESYNC is caller-asserted, not
                // evidence: if the stop is rejected the tracker reverts to
                // its pre-resync prior (and if accepted the session is
                // gone, all state cleared), so a snapshot taken during the
                // resync proves at most that prior. Without this term a
                // message snapshotted on top of the resync launders the
                // caller-supplied value into its own prior_tracker, and
                // this rejection would promote it into the proven floor —
                // permanently, since the stop's later rejection can only
                // MAX with the floor (#210 gap 7).
                floor = @min(floor, pending.prior_tracker);
            }
        }
        // A REJECTED stop's pre-resync prior bounds the same world — its
        // record is gone, but snapshots taken during its refuted resync
        // still revert to at most that prior (#210 gap 7).
        if (self.stop_revert_bound_by_session.get(session_id)) |revert_bound| {
            floor = @min(floor, revert_bound);
        }
        // The all-rejected floor and every previously proven bound are
        // both sound lower bounds on the counter — the sound floor is
        // their MAX. Without this, a generic backward rejection
        // (invalid_request collapses both directions, server.zig) would
        // pin the tracker at the all-rejected world even though
        // settlements had proven more, and subsequent ordinary sends
        // would replay consumed sequences (#210 gap 7).
        floor = @max(floor, self.provenFloor(session_id));
        try self.noteProvenFloor(session_id, floor);
        try self.setTrackerValue(session_id, floor);
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
        _ = self.proven_floor_by_session.remove(session_id);
        _ = self.stop_revert_bound_by_session.remove(session_id);
        _ = self.tracker_epoch_by_session.remove(session_id);
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

test "AgentProtocolClient rejects a start against a tracker at the sequence maximum (#210 gap 7)" {
    // An explicit maxInt-1 message leaves the tracker at maxInt(u64); a
    // start against that session is un-advanceable (its seq + 1 mirror
    // would trap in safety-checked builds), so it is rejected before any
    // mutation or wire write — the caller recovers instead of crashing.
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":edge}", null, std.math.maxInt(u64) - 1); // tracker maxInt
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), client.peekNextSequence(sid));

    try std.testing.expectError(error.InvalidSequence, client.sendAgentStartWithSession(sid, "{}", null));
    try std.testing.expectEqual(@as(usize, 1), harness.writes.items.len); // the message only — nothing sent
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), client.peekNextSequence(sid)); // untouched
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

test "AgentProtocolClient tracked-send duplicate_sequence nack retires the record without a rollback (#210 gap 7)" {
    // Sequence 2 was admitted with its reply lost; the recovery resends
    // sequence 2 explicitly and the peer answers duplicate_sequence — proof
    // the server's counter is PAST 2. The ordinary §13.1 rollback would pin
    // every later send on the consumed counter; instead the resend's record
    // retires (its outcome is known — no new admission) and the tracker
    // takes the one proven step (3).
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
    // An EMPTY options_json digests identically to absence — the wire
    // treats them the same, so the same request spelled either way is a
    // retry, not a fresh payload.
    try std.testing.expectEqual(messagePayloadHash("{\"m\":1}", null), messagePayloadHash("{\"m\":1}", ""));
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

    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid)); // the proven step kept
    try std.testing.expect(client.getLastErrorForSession(sid) == null); // no false failure
    const remaining = if (client.pending_sends_by_session.getPtr(sid)) |l| l.items.len else 0;
    try std.testing.expectEqual(@as(usize, 0), remaining); // both records resolved
}

test "AgentProtocolClient a competing payload at the sequence disqualifies the silent retry (#210 gap 7)" {
    // Payload A at 2 fails ambiguously (its record lingers); payload B at
    // 2 is admitted; the A-retry is recorded while BOTH are pending. Its
    // duplicate_sequence proves only that SOMEONE consumed 2 — B explains
    // it without A ever having run — so the rejection surfaces instead of
    // retiring silently as though A had executed.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":A}", null); // seq 2 — ambiguous write, outcome unknown
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":B}", null, 2); // admitted at the same sequence
    const retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2); // the A-retry

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

    // The competing B explains the duplicate without A having run: the
    // rejection SURFACES, and both original records remain pending.
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid)); // past the consumed 2
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 2), pending.items.len); // A and B remain
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

test "AgentProtocolClient a retired competing duplicate requalifies other payloads' retries (#210 gap 7)" {
    // Payload A and competing payload B are pending at 2; the A-retry is
    // correctly non-silent while B remains. BOTH are answered
    // duplicate_sequence with B's reply processed FIRST: B retires (and
    // legitimately surfaces), which removes the only competitor — the
    // A-retry's later duplicate now legitimately confirms the
    // still-pending A original and retires SILENTLY instead of raising a
    // false terminal error.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":A}", null); // seq 2 — the original, outcome unknown
    const competing_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":B}", null, 2); // the competitor
    const retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2); // non-silent while B remains

    var competing_duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = competing_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = competing_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer competing_duplicate.deinit(allocator);
    try client.processEnvelope(competing_duplicate);
    try std.testing.expect(client.getLastErrorForSession(sid) != null); // B's rejection surfaces
    client.clearSessionTerminalState(sid); // the caller consumes B's legitimate failure

    var retry_duplicate = agent_types.Envelope{
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
    defer retry_duplicate.deinit(allocator);
    try client.processEnvelope(retry_duplicate);

    // With the competitor proven consumed and gone, the A-retry's
    // duplicate confirms the pending A original: silent, no false error.
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(!client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len); // the A original remains for its own settlement
}

test "AgentProtocolClient a non-retry duplicate retirement invalidates same-payload retries (#210 gap 7)" {
    // Sequence 2 was consumed by an earlier, SETTLED payload; a fresh
    // payload A at 2 and its retry both receive duplicate_sequence.
    // A's answer retires A and surfaces (A never executed), but the
    // retry's recorded bit — derived from A while A was pending — must be
    // re-derived: the duplicate proves only that SOME EARLIER envelope
    // consumed 2, never that A ran, so the retry's answer SURFACES too
    // instead of silently confirming a payload that never executed.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":settled}", null); // seq 2 — settles below
    var settled = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer settled.deinit(allocator);
    try client.processEnvelope(settled); // sequence 2 consumed by the settled payload

    const stale_a_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2); // non-retry at the consumed sequence
    const retry_a_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2); // retry of the pending A

    var stale_duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stale_a_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = stale_a_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer stale_duplicate.deinit(allocator);
    try client.processEnvelope(stale_duplicate);
    try std.testing.expect(client.getLastErrorForSession(sid) != null); // A never executed — surfaced
    client.clearSessionTerminalState(sid);

    var retry_duplicate = agent_types.Envelope{
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
    defer retry_duplicate.deinit(allocator);
    try client.processEnvelope(retry_duplicate);

    // The retry's silent justification died with A: its duplicate
    // SURFACES instead of confirming a payload that never ran.
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    const remaining = if (client.pending_sends_by_session.getPtr(sid)) |l| l.items.len else 0;
    try std.testing.expectEqual(@as(usize, 0), remaining); // both resolved
}

test "AgentProtocolClient masked same-payload ancestry breaks with its source (#210 gap 7)" {
    // At an already-consumed sequence: A, then competitor B, then two more
    // A copies. A's duplicate retires A and surfaces; the A copies' retry
    // bits were FALSE (the competitor masked them), so a re-derivation
    // keyed on the bits alone would not mark them broken — and after B's
    // duplicate retires the competitor, the first remaining copy would
    // look like a fresh intact source for the second. The recorded
    // ANCESTRY marker breaks both copies when A's duplicate proves the
    // chain dead: the second copy's duplicate SURFACES — no A copy ever
    // ran.
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
    const first_a_id = try client.sendAgentMessage(sid, "{\"m\":A}", null); // seq 2 — consumed sequence
    const competing_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":B}", null, 2); // the competitor
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2); // A copy 2 — masked
    const third_a_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2); // A copy 3 — masked

    var first_duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = first_a_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = first_a_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer first_duplicate.deinit(allocator);
    try client.processEnvelope(first_duplicate);
    try std.testing.expect(client.getLastErrorForSession(sid) != null); // A never executed
    client.clearSessionTerminalState(sid);

    var competing_duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = competing_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = competing_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer competing_duplicate.deinit(allocator);
    try client.processEnvelope(competing_duplicate);
    try std.testing.expect(client.getLastErrorForSession(sid) != null); // B never executed either
    client.clearSessionTerminalState(sid);

    var third_duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = third_a_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = third_a_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer third_duplicate.deinit(allocator);
    try client.processEnvelope(third_duplicate);

    // No A copy ever ran — the third copy's duplicate SURFACES instead of
    // silently confirming a masked "source" whose ancestry is dead.
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len); // only A copy 2 remains
}

test "AgentProtocolClient a settled source preserves same-payload retry provenance (#210 gap 7)" {
    // Payload A is ACCEPTED at 2 with its retry recorded while A is the
    // only same-sequence record. A's result arrives: every pending message
    // is the same payload at the same sequence, so the settling run is
    // UNAMBIGUOUSLY an A-at-2 run — the retry's justification is marked
    // SETTLED. When a later competitor's rejection runs the re-derivation
    // (which finds no earlier record — the settled source's own record
    // retired with the settlement), the retry's bit STANDS, and its
    // duplicate answer silently confirms the settled A instead of
    // surfacing a false terminal error for a payload that demonstrably
    // ran.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":A}", null); // seq 2 — ACCEPTED, result below
    const retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2); // retry of the pending A

    var settled = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer settled.deinit(allocator);
    try client.processEnvelope(settled); // A's run completed — unambiguous, so the retry's justification is settled fact

    // A competitor recorded AFTER the settlement, rejected before the
    // retry's answer: its removal is the re-derivation trigger that would
    // break an unprotected chain.
    const competing_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":B}", null, 2);
    var competing_rejected = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = competing_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer competing_rejected.deinit(allocator);
    try client.processEnvelope(competing_rejected);
    try std.testing.expect(client.getLastErrorForSession(sid) != null); // B's rejection surfaces
    client.clearSessionTerminalState(sid); // the caller consumes B's legitimate failure

    var retry_duplicate = agent_types.Envelope{
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
    defer retry_duplicate.deinit(allocator);
    try client.processEnvelope(retry_duplicate);

    // The settled source outranks the missing pending record: silent, no
    // false failure, and the retry's record is gone with its answer.
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(!client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid)); // past the consumed 2
    const remaining = if (client.pending_sends_by_session.getPtr(sid)) |l| l.items.len else 0;
    try std.testing.expectEqual(@as(usize, 0), remaining); // all records resolved
}

test "AgentProtocolClient a settled source does not bless the payload of a stale oldest record (#210 gap 7)" {
    // The oldest pending record can be a REJECTED send whose reply was
    // lost, while a later different-payload send at the same sequence was
    // admitted and settles: the FIFO attribution retires the stale record,
    // but the mixed pending set makes the settling run's payload
    // AMBIGUOUS — a settled grant here would bless the rejected payload's
    // retries and silently suppress their duplicate answers for a payload
    // that never executed. No grant is given, and the retry's duplicate
    // SURFACES.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":A}", null); // seq 2 — REJECTED with the reply lost, record lingers as the oldest
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":B}", null, 2); // ADMITTED at 2 — its run settles below
    const retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2); // masked retry of the stale A

    var settled = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer settled.deinit(allocator);
    try client.processEnvelope(settled); // attributed to the stale A record; the run was B's

    var retry_duplicate = agent_types.Envelope{
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
    defer retry_duplicate.deinit(allocator);
    try client.processEnvelope(retry_duplicate);

    // A never ran — its retry's duplicate SURFACES instead of being
    // silently swallowed by a grant the attribution cannot justify.
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid)); // past the consumed 2
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len); // B's record remains for its own resolution
}

test "AgentProtocolClient a settlement breaks different-payload chains at the sequence (#210 gap 7)" {
    // Payload A settles at 2 while competing payloads B, B-retry, and C
    // remain pending there. A's settlement proves the sequence was
    // consumed by A's payload — no other payload at 2 ever ran — so their
    // chains are marked BROKEN: C's later removal re-derives sequence 2,
    // and without the break it would treat B as an intact source and
    // re-qualify the B-retry for the silent path — silently confirming a
    // payload the settlement excluded. The B-retry's duplicate SURFACES.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":A}", null); // seq 2 — settles below
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":B}", null, 2); // the excluded competitor
    const b_retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":B}", null, 2); // its retry (bit derived from B)
    const other_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":C}", null, 2); // a third payload whose removal triggers re-derivation

    var settled = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer settled.deinit(allocator);
    try client.processEnvelope(settled); // A's run consumed 2 — every other payload at 2 is proven never-admitted

    var other_rejected = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = other_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer other_rejected.deinit(allocator);
    try client.processEnvelope(other_rejected); // C's removal re-derives sequence 2 — B's chain must stay broken
    client.clearSessionTerminalState(sid); // the caller consumes C's legitimate failure

    var b_retry_duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = b_retry_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = b_retry_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer b_retry_duplicate.deinit(allocator);
    try client.processEnvelope(b_retry_duplicate);

    // A's settlement excluded B: the B-retry's duplicate SURFACES instead
    // of silently treating B as an intact source.
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid)); // past the consumed 2
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len); // only B's own record remains
}

test "AgentProtocolClient settled provenance propagates to retries recorded after the settlement (#210 gap 7)" {
    // A retry recorded while a SETTLED-flagged same-payload record is
    // pending inherits the settled justification: the flag survives the
    // intermediary's own silent retirement and a later re-derivation
    // (triggered by a competitor's rejection), so the new retry's
    // duplicate retires silently too — the payload demonstrably ran. An
    // inheritance limited to the retry bit would lose the fact with the
    // intermediary's record and surface a false terminal error.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":A}", null); // seq 2 — ACCEPTED
    const first_retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2); // retry while A is pending

    var settled = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer settled.deinit(allocator);
    try client.processEnvelope(settled); // unambiguous (A and the retry, same payload at 2) — the retry's justification is settled

    const second_retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2); // recorded AFTER the settlement — inherits it
    var first_duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = first_retry_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = first_retry_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer first_duplicate.deinit(allocator);
    try client.processEnvelope(first_duplicate); // the settled intermediary retires silently

    const competing_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":B}", null, 2);
    var competing_rejected = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = competing_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer competing_rejected.deinit(allocator);
    try client.processEnvelope(competing_rejected); // the re-derivation trigger — the inherited flag must survive it
    client.clearSessionTerminalState(sid); // the caller consumes B's legitimate failure

    var second_duplicate = agent_types.Envelope{
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
    defer second_duplicate.deinit(allocator);
    try client.processEnvelope(second_duplicate);

    // The settled fact propagated: silent, no false failure.
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(!client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid)); // past the consumed 2
    const remaining = if (client.pending_sends_by_session.getPtr(sid)) |l| l.items.len else 0;
    try std.testing.expectEqual(@as(usize, 0), remaining); // all records resolved
}

test "AgentProtocolClient an accepted start seeds the proven floor (#210 gap 7)" {
    // The started reply proves the server's counter advanced past the
    // start's sequence. Without seeding the floor, two explicit stale
    // sends at sequence 1 (the collapsed generic invalid_request rejects
    // them) floor the tracker to 1 through the still-pending stale
    // record — wedging every subsequent ordinary send on the sequence
    // the start already consumed.
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
    try client.processEnvelope(started_env); // seeds the floor: counter > 1

    const first_stale_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":stale-1}", null, 1);
    const second_stale_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":stale-2}", null, 1);

    for ([_]agent_types.Ulid{ first_stale_id, second_stale_id }) |stale_id| {
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
    }
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid)); // never pinned to the consumed 1

    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    var next_env = try harness.envelopeAt(3); // start, stale-1, stale-2, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), next_env.sequence);
}


test "AgentProtocolClient an adopted uncorrelated start raises the live tracker to the proven floor (#210 gap 7)" {
    // A generated-id response (or a restored client) delivers the started
    // reply without correlation: the registration consumed sequence 1, so
    // the floor is 2 — and the LIVE tracker must follow it, or the first
    // ordinary message would carry the consumed 1 and be rejected.
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
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
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid)); // tracker follows the proof

    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    var first = try harness.envelopeAt(0);
    defer first.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), first.sequence);
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


test "AgentProtocolClient retries at a sequence below the proven floor surface (#210 gap 7)" {
    // Sequence 2 settled and established floor 3; payload A is then sent
    // at 2 TWICE — both sends were provably never-admissible (the counter
    // was already past 2). When the FIRST duplicate reply is lost and the
    // retry's duplicate arrives, the recorded retry bit must not suppress
    // it: no A send could execute, nothing will settle, and the caller
    // must see the failure instead of waiting forever.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":settled}", null); // seq 2 — settles below
    var settled = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer settled.deinit(allocator);
    try client.processEnvelope(settled); // floor 3: sequence 2 proven consumed

    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2); // its duplicate reply is LOST
    const retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2); // recorded below the floor

    var retry_duplicate = agent_types.Envelope{
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
    defer retry_duplicate.deinit(allocator);
    try client.processEnvelope(retry_duplicate);

    // Neither A send could have executed — the duplicate SURFACES.
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len); // the first A send remains unresolved
}

test "AgentProtocolClient stops at the sequence maximum are the ceiling teardown (#210 gap 7)" {
    // A stop never computes sequence + 1 — an accepted stop consumes the
    // counter WITH the session and clears the tracker — so maxInt(u64)
    // is a legal stop sequence (the teardown of a session whose counter
    // reached the ceiling), unlike a message or start whose optimistic
    // mirror would overflow. The stop sends, and a later start against
    // the resynced maximum still rejects there.
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1, tracker 2

    _ = try client.sendAgentStopWithSequence(sid, "teardown", std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), client.peekNextSequence(sid)); // resynced to the ceiling
    // The stop is on the wire. (Its sequence is NOT deserialized back
    // here: a u64 above the JSON integer ceiling round-trips as a number
    // string the envelope reader does not accept — the same pre-existing
    // wire limitation the landed maxInt-1 explicit-message test carries;
    // sequences that extreme cannot occur in any real session.)
    try std.testing.expectEqual(@as(usize, 2), harness.writes.items.len); // start, stop
    try std.testing.expectError(error.InvalidSequence, client.sendAgentStartWithSession(sid, "{}", null)); // the start still rejects the ceiling
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


test "AgentProtocolClient a rejected stop does not undo a later accepted send's equal-valued mirror (#210 gap 7)" {
    // The server expects 6; an explicit stop resyncs the tracker to 7,
    // then an explicit message AT THE CORRECT SEQUENCE 6 is accepted and
    // mirrors the tracker to 7 — the same VALUE by a different owner.
    // The stop's later gap rejection must not mistake that 7 for its own
    // resync and rewind past the accepted send's mirror.
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
    for (0..4) |_| {
        _ = try client.sendAgentMessage(sid, "{\"m\":fill}", null); // seqs 2..5
        var settled = agent_types.Envelope{
            .session_id = sid,
            .message_id = agent_types.generateUlid(),
            .sequence = 6,
            .in_reply_to = null,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
        };
        defer settled.deinit(allocator);
        try client.processEnvelope(settled);
    }
    try std.testing.expectEqual(@as(u64, 6), client.peekNextSequence(sid)); // server expects 6

    const stop_id = try client.sendAgentStopWithSequence(sid, "stale", 7); // resync: tracker 7, prior 6
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":at-six}", null, 6); // ACCEPTED, mirror 7

    var stop_rejected = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer stop_rejected.deinit(allocator);
    try client.processEnvelope(stop_rejected);

    // The pending accepted message's mirror owns the 7 — no rewind.
    try std.testing.expectEqual(@as(u64, 7), client.peekNextSequence(sid));

    _ = try client.sendAgentMessage(sid, "{\"m\":next}", null);
    var next_env = try harness.envelopeAt(7); // start, 4 fills, stop, at-six, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 7), next_env.sequence);
}


test "AgentProtocolClient a message snapshotted on an unresolved stop resync cannot launder it into the floor (#210 gap 7)" {
    // The server expects 2; an explicit stop at 7 resyncs the tracker to
    // 7 (caller-asserted); an ordinary message sent before the stop
    // resolves records prior_tracker 7. Rejecting the MESSAGE first
    // would promote that prior into the proven floor — permanently,
    // since the stop's own rejection can only MAX with the floor —
    // wedging the tracker at 7 while the server sits at 2. The
    // unresolved stop's PRE-RESEND prior floors the message's rejection,
    // so the caller's 7 never becomes proven.
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
    _ = try client.sendAgentStopWithSequence(sid, "caller-known", 7); // resync: tracker 7, stop prior 2
    const message_id = try client.sendAgentMessage(sid, "{\"m\":1}", null); // seq 7, prior 7, tracker 8

    var message_rejected = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = message_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer message_rejected.deinit(allocator);
    try client.processEnvelope(message_rejected);
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid)); // the stop's prior floored it — never 7

    // The stop's own rejection finds the tracker already below its
    // resync; nothing raises it back toward the caller's stale 7.
    const stop_record = client.pending_sends_by_session.getPtr(sid).?.items[0];
    var stop_rejected = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stop_record.msg_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer stop_rejected.deinit(allocator);
    try client.processEnvelope(stop_rejected);
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));

    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);
    var next_env = try harness.envelopeAt(3); // start, stop, message, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), next_env.sequence);
}


test "AgentProtocolClient duplicate_sequence for a stop records the proven step (#210 gap 7)" {
    // Older peers answer a tracked explicit stop with duplicate_sequence:
    // the answer proves the counter is PAST the stop's sequence. Without
    // recording the step, a locally stale tracker (floored to 1 by
    // rejected stale sends) stays at 1 through the stop's rejection and
    // every subsequent ordinary send replays the consumed sequence.
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1 — its started reply is NOT processed, so nothing seeds the floor
    const first_stale_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":stale-1}", null, 1); // below the server
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":stale-2}", null, 1); // still pending below

    // The first stale send's generic rejection floors the tracker to 1
    // (the still-pending second stale record's sequence).
    var stale_rejected = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = first_stale_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer stale_rejected.deinit(allocator);
    try client.processEnvelope(stale_rejected);
    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));

    // The explicit stop at the consumed 1 is answered duplicate_sequence
    // (the server expects 2): the proven step (2) is recorded, and the
    // ordinary stop-rejection path surfaces the failure while restoring
    // the tracker to the proven bound — not the stale 1.
    const stop_id = try client.sendAgentStopWithSequence(sid, "teardown", 1); // resync to 1 (no-op), prior 1
    var stop_duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = stop_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer stop_duplicate.deinit(allocator);
    try client.processEnvelope(stop_duplicate);

    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid)); // the proven step, never the stale 1
    try std.testing.expect(client.getLastErrorForSession(sid) != null); // the stop rejection still surfaces
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    var next_env = try harness.envelopeAt(4); // start, stale-1, stale-2, stop, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), next_env.sequence);
}


test "AgentProtocolClient a rejected stop does not honor a mirror a reconciliation superseded (#210 gap 7)" {
    // A pending explicit message at 6 mirrors the tracker to 7; a later
    // send's rejection restores the tracker to 2 (the still-pending
    // record's own floor terms) — the message's mirror is superseded. An
    // explicit stop at 7 then resyncs the tracker back onto 7, and its
    // rejection must not mistake the stale value-equal mirror for the
    // current value's owner: the resync is undone toward the restored 2,
    // so the next ordinary send carries 2, not the refuted 7.
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
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":forward}", null, 6); // pending, prior 2, mirror 7
    const later_id = try client.sendAgentMessage(sid, "{\"m\":later}", null); // seq 7, tracker 8
    var later_rejected = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = later_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer later_rejected.deinit(allocator);
    try client.processEnvelope(later_rejected);
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid)); // restored — the forward mirror is dead

    const stop_id = try client.sendAgentStopWithSequence(sid, "stale", 7); // resync onto the dead mirror's value, prior 2
    var stop_rejected = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer stop_rejected.deinit(allocator);
    try client.processEnvelope(stop_rejected);

    // The superseded mirror does not own the 7 — the resync is undone to 2.
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));
    _ = try client.sendAgentMessage(sid, "{\"m\":next}", null);
    var next_env = try harness.envelopeAt(4); // start, forward, later, stop, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), next_env.sequence);
}

test "AgentProtocolClient a skipped stop-undo still raises the tracker to the proven floor (#210 gap 7)" {
    // A LIVE mirror blocks the undo: an explicit stop at 4 resyncs the
    // tracker, then a message at 3 is sent (its mirror 4 is the last
    // write) and the stop is answered duplicate_sequence — proof the
    // server is already past 4. The stop's ordinary rejection correctly
    // skips the undo (the mirror owns the 4), but the proven step (5)
    // must still lift the tracker: the floor is monotone evidence and a
    // mirror can only explain values above it, so the next ordinary send
    // carries 5 instead of replaying the consumed 4.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":settled}", null); // seq 2 — settles below
    var settled = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer settled.deinit(allocator);
    try client.processEnvelope(settled); // floor 3: sequence 2 proven consumed
    const stop_id = try client.sendAgentStopWithSequence(sid, "teardown", 4); // resync: tracker 4, prior 3
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":at-three}", null, 3); // LIVE mirror 4 — the last write

    var stop_duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = stop_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer stop_duplicate.deinit(allocator);
    try client.processEnvelope(stop_duplicate); // proven step 5 recorded; the stop rejection surfaces

    // The live mirror's 4 survives the skipped undo, but the proven floor 5 wins.
    try std.testing.expectEqual(@as(u64, 5), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) != null); // the stop rejection still surfaces
    _ = try client.sendAgentMessage(sid, "{\"m\":next}", null);
    var next_env = try harness.envelopeAt(4); // start, settled, stop, at-three, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 5), next_env.sequence);
}
test "AgentProtocolClient a later send's tracker write supersedes an older mirror's ownership (#210 gap 7)" {
    // An unresolved explicit message at 6 mirrors the tracker to 7; a
    // LATER explicit message at 2 rewrites the tracker to 3 — no
    // reconciliation is involved, but the older mirror's value is dead
    // the moment the later write lands. An explicit stop at 7 then
    // resyncs onto the dead mirror's value, and its rejection must not
    // mistake that mirror for the current value's owner: the resync is
    // undone toward the all-rejected world, so the next ordinary send
    // carries 2 instead of the refuted 7.
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
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":forward}", null, 6); // pending, prior 2, mirror 7
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":rewrites}", null, 2); // tracker 3 — the last write
    const stop_id = try client.sendAgentStopWithSequence(sid, "stale", 7); // resync onto the dead mirror's value, prior 3

    var stop_rejected = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer stop_rejected.deinit(allocator);
    try client.processEnvelope(stop_rejected);

    // Neither mirror is live — the resync is undone to the all-rejected floor.
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));
    _ = try client.sendAgentMessage(sid, "{\"m\":next}", null);
    var next_env = try harness.envelopeAt(4); // start, forward, rewrites, stop, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), next_env.sequence);
}

test "AgentProtocolClient a retry of a source recorded before the floor keeps the silent path (#210 gap 7)" {
    // Message A is sent at sequence 2 and remains pending (its run is
    // live); a sequence-3 send is answered agent_busy, proving the
    // counter at 3; an explicit retry of A at sequence 2 then snapshots
    // floor 3 — ABOVE its own sequence. The silent duplicate path is
    // justified by the SOURCE's admissibility (A at 2 was sent while the
    // sequence was admissible and is exactly what consumed it), so the
    // retry's duplicate retires silently instead of surfacing a false
    // terminal error: the below-floor rule must judge the ancestry, not
    // the retry's newer snapshot.
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
    _ = try client.sendAgentMessage(sid, "{\"m\":A}", null); // seq 2 — ACCEPTED, run live, record pending
    const busy_id = try client.sendAgentMessage(sid, "{\"m\":busy-me}", null); // seq 3 — busy below
    var busy = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = busy_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_busy, .message = try allocator.dupe(u8, "session already processing a message") } },
    };
    defer busy.deinit(allocator);
    try client.processEnvelope(busy); // parity 3: the floor rises past the retry's sequence
    client.clearSessionTerminalState(sid); // the caller consumes the busy failure

    const retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2); // retry — inherits the source's admissibility
    var retry_duplicate = agent_types.Envelope{
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
    defer retry_duplicate.deinit(allocator);
    try client.processEnvelope(retry_duplicate);

    // Silent: the source predates the floor, so the retry retires without a false failure.
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(!client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid)); // the proven step
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len); // A's own record remains for its settlement
    _ = try client.sendAgentMessage(sid, "{\"m\":next}", null);
    var next_env = try harness.envelopeAt(4); // start, A, busy-me, retry, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), next_env.sequence);
}
test "AgentProtocolClient an accepted start invalidates pre-reply sequence-1 message ancestry (#210 gap 7)" {
    // A start at sequence 1 is sent; two explicit same-payload messages
    // at sequence 1 are recorded BEFORE the started reply is processed
    // (both snapshot floor 0, the second deriving from the first). The
    // start's acceptance then proves the START consumed sequence 1 —
    // neither message could ever have been admitted, so the second's
    // duplicate_sequence answer must SURFACE instead of silently
    // swallowing a failure whose settlement can never arrive.
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null); // seq 1 — its reply is NOT yet processed
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 1); // first A — its duplicate reply is lost
    const second_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 1); // the retry, snapshot floor 0

    var started_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .in_reply_to = start_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = sid } },
    };
    defer started_env.deinit(allocator);
    try client.processEnvelope(started_env); // the START consumed 1 — both A records' justification dies

    var second_duplicate = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = second_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = second_id,
            .reason = OwnedSlice(u8).initBorrowed("duplicate sequence"),
            .error_code = .duplicate_sequence,
        } },
    };
    defer second_duplicate.deinit(allocator);
    try client.processEnvelope(second_duplicate);

    // Neither A send could have executed — the duplicate SURFACES.
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid)); // past the start's consumed 1
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len); // the first A remains (broken, awaiting its own reply)
    _ = try client.sendAgentMessage(sid, "{\"m\":next}", null);
    var next_env = try harness.envelopeAt(3); // start, A, retry, next
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), next_env.sequence);
}
