const std = @import("std");
const compat = @import("compat");
const agent_types = @import("agent_types");
const envelope = @import("agent_envelope");
const transport = @import("transport");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const QueuedEvent = struct {
    session_id: agent_types.SessionId,
    json: OwnedSlice(u8),

    pub fn deinit(self: *QueuedEvent, allocator: std.mem.Allocator) void {
        self.json.deinit(allocator);
        self.* = undefined;
    }
};

const PendingSendKind = enum { start, message, stop };

const SessionAdmission = struct {
    exclusive_id: bool = false,
    started_observed: bool = false,
};

const PendingSend = struct {
    msg_id: agent_types.Ulid,
    sequence: u64,
    kind: PendingSendKind,
    prior_tracker: u64,
    payload_hash: u64 = 0,
    resend_of_pending: bool = false,
    provenance_broken: bool = false,
    had_same_payload_ancestry: bool = false,
    source_settled: bool = false,
    proven_floor_at_send: u64 = 0,
    send_epoch: u64 = 0,
};

const StopProbe = struct {
    first_msg_id: agent_types.Ulid,
    candidates: []u64,
    next_index: usize,
    reason: OwnedSlice(u8),
};

fn u64Ascending(_: void, a: u64, b: u64) bool {
    return a < b;
}

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
    sequence: u64 = 0,
    session_id: ?agent_types.SessionId = null,
    last_error: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    last_result_json: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    event_queue: std.ArrayList(QueuedEvent),
    next_sequence_by_session: std.AutoHashMap(agent_types.SessionId, u64),
    session_complete_flags: std.AutoHashMap(agent_types.SessionId, bool),
    session_last_errors: std.AutoHashMap(agent_types.SessionId, OwnedSlice(u8)),
    session_last_results: std.AutoHashMap(agent_types.SessionId, OwnedSlice(u8)),
    pending_sends_by_session: std.AutoHashMap(agent_types.SessionId, std.ArrayList(PendingSend)),
    proven_floor_by_session: std.AutoHashMap(agent_types.SessionId, u64),
    stop_revert_bound_by_session: std.AutoHashMap(agent_types.SessionId, u64),
    tracker_epoch_by_session: std.AutoHashMap(agent_types.SessionId, u64),
    admitted_by_session: std.AutoHashMap(agent_types.SessionId, SessionAdmission),
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
            .proven_floor_by_session = std.AutoHashMap(agent_types.SessionId, u64).init(allocator),
            .stop_revert_bound_by_session = std.AutoHashMap(agent_types.SessionId, u64).init(allocator),
            .tracker_epoch_by_session = std.AutoHashMap(agent_types.SessionId, u64).init(allocator),
            .admitted_by_session = std.AutoHashMap(agent_types.SessionId, SessionAdmission).init(allocator),
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
        self.proven_floor_by_session.deinit();
        self.stop_revert_bound_by_session.deinit();
        self.tracker_epoch_by_session.deinit();
        self.admitted_by_session.deinit();

        var probe_it = self.stop_probes_by_session.iterator();
        while (probe_it.next()) |entry| {
            entry.value_ptr.reason.deinit(self.allocator);
            self.allocator.free(entry.value_ptr.candidates);
        }
        self.stop_probes_by_session.deinit();

        self.* = undefined;
    }

    pub fn setSender(self: *Self, sender: transport.AsyncSender) void {
        self.sender = sender;
    }

    pub fn peekNextSequence(self: *Self, session_id: agent_types.SessionId) u64 {
        return self.next_sequence_by_session.get(session_id) orelse 1;
    }

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
        if (has_competing_payload) resend_of_pending = false;
        if (inherits_settled_source) resend_of_pending = true;
        const inherited_floor = if (same_payload_floor == std.math.maxInt(u64)) self.provenFloor(session_id) else @min(self.provenFloor(session_id), same_payload_floor);
        const floor_at_send = if (kind == .message and sequence < 2) @max(inherited_floor, 2) else inherited_floor;
        try gop.value_ptr.append(self.allocator, .{ .msg_id = msg_id, .sequence = sequence, .kind = kind, .prior_tracker = prior_tracker, .payload_hash = payload_hash, .resend_of_pending = resend_of_pending, .had_same_payload_ancestry = had_same_payload_ancestry, .source_settled = inherits_settled_source, .proven_floor_at_send = if (kind == .message) floor_at_send else 0, .send_epoch = self.trackerEpoch(session_id) });
    }

    pub fn sendAgentStart(self: *Self, config_json: []const u8, system_prompt: ?[]const u8) !agent_types.Ulid {
        const sid = agent_types.generateSessionId();
        return self.startSession(sid, config_json, system_prompt, true);
    }

    pub fn sendAgentStartWithSession(self: *Self, sid: agent_types.SessionId, config_json: []const u8, system_prompt: ?[]const u8) !agent_types.Ulid {
        return self.startSession(sid, config_json, system_prompt, false);
    }

    pub fn sendAgentStartWithSessionExclusive(self: *Self, sid: agent_types.SessionId, config_json: []const u8, system_prompt: ?[]const u8) !agent_types.Ulid {
        return self.startSession(sid, config_json, system_prompt, true);
    }

    fn startSession(self: *Self, sid: agent_types.SessionId, config_json: []const u8, system_prompt: ?[]const u8, id_exclusive: bool) !agent_types.Ulid {
        const msg_id = agent_types.generateUlid();

        var payload = agent_types.Payload{ .agent_start = .{ .config_json = try self.allocator.dupe(u8, config_json), .session_id = sid } };
        defer payload.deinit(self.allocator);
        if (system_prompt) |sp| {
            payload.agent_start.system_prompt = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, sp));
        }

        const seq = self.peekNextSequence(sid);
        if (seq == std.math.maxInt(u64)) return error.InvalidSequence;
        const start_json = try self.serializeEnvelopeForSend(.{
            .session_id = sid,
            .message_id = msg_id,
            .sequence = seq,
            .timestamp = compat.time.nowMillis(),
            .payload = payload,
        });
        defer self.allocator.free(start_json);
        const prior_admission = self.admitted_by_session.get(sid);
        const prior_epoch = self.trackerEpoch(sid);
        try self.setTrackerValue(sid, seq + 1);
        self.sequence = seq;
        self.admitted_by_session.put(sid, .{ .exclusive_id = id_exclusive }) catch |err| {
            self.restoreTrackerState(sid, seq, prior_epoch);
            return err;
        };
        self.recordPendingSend(sid, msg_id, seq, .start, seq, 0) catch |err| {
            self.restoreTrackerState(sid, seq, prior_epoch);
            if (prior_admission) |prior_slot| {
                self.admitted_by_session.put(sid, prior_slot) catch {};
            } else {
                _ = self.admitted_by_session.remove(sid);
            }
            return err;
        };

        try self.writeEnvelopeJson(start_json);

        return msg_id;
    }

    pub fn sendAgentMessage(self: *Self, session_id: agent_types.SessionId, message_json: []const u8, options_json: ?[]const u8) !agent_types.Ulid {
        const seq = self.peekNextSequence(session_id);
        return self.sendAgentMessageWithSequence(session_id, message_json, options_json, seq);
    }

    pub fn sendAgentMessageWithSequence(self: *Self, session_id: agent_types.SessionId, message_json: []const u8, options_json: ?[]const u8, sequence: u64) !agent_types.Ulid {
        if (sequence == std.math.maxInt(u64)) return error.InvalidSequence;
        const msg_id = agent_types.generateUlid();

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
        const prior_sequence = self.peekNextSequence(session_id);
        const prior_mirror = self.sequence;
        const prior_epoch = self.trackerEpoch(session_id);
        try self.setTrackerValue(session_id, sequence + 1);
        self.sequence = sequence;
        self.recordPendingSend(session_id, msg_id, sequence, .message, prior_sequence, messagePayloadHash(message_json, options_json)) catch |err| {
            self.restoreTrackerState(session_id, prior_sequence, prior_epoch);
            self.sequence = prior_mirror;
            return err;
        };

        try self.writeEnvelopeJson(message_json_buf);
        return msg_id;
    }

    pub fn sendAgentStop(self: *Self, session_id: agent_types.SessionId, reason: ?[]const u8) !agent_types.Ulid {
        return self.sendAgentStopWithSequence(session_id, reason, self.peekNextSequence(session_id));
    }

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
        const prior = self.peekNextSequence(session_id);
        const prior_mirror = self.sequence;
        const prior_epoch = self.trackerEpoch(session_id);
        self.sequence = sequence;
        if (sequence != prior) {
            self.setTrackerValue(session_id, sequence) catch |err| {
                self.restoreTrackerState(session_id, prior, prior_epoch);
                self.sequence = prior_mirror;
                return err;
            };
        }
        self.recordPendingSend(session_id, msg_id, sequence, .stop, prior, 0) catch |err| {
            if (sequence != prior) self.restoreTrackerState(session_id, prior, prior_epoch);
            self.sequence = prior_mirror;
            return err;
        };
        try self.writeEnvelopeJson(json);
    }

    pub fn hasActiveStopProbe(self: *Self, session_id: agent_types.SessionId) bool {
        return self.stop_probes_by_session.contains(session_id);
    }

    pub fn sendAgentStopProbing(self: *Self, session_id: agent_types.SessionId, reason: ?[]const u8) !?agent_types.Ulid {
        if (self.stop_probes_by_session.get(session_id)) |existing| {
            return existing.first_msg_id;
        }
        if (!self.isSessionAdmitted(session_id)) return null;
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return null;

        const tracker_value = self.peekNextSequence(session_id);
        var floor: u64 = tracker_value;
        var has_message = false;
        for (list.items) |pending| {
            if (pending.kind != .message) continue;
            has_message = true;
            floor = @min(floor, pending.sequence);
            floor = @min(floor, pending.prior_tracker);
        }
        if (!has_message) return null;
        floor = @max(floor, self.provenFloor(session_id));

        var candidates = std.ArrayList(u64).empty;
        errdefer candidates.deinit(self.allocator);
        try candidates.append(self.allocator, floor);
        for (list.items) |pending| {
            if (pending.kind == .message) {
                if (std.math.add(u64, pending.sequence, 1)) |next| {
                    try candidates.append(self.allocator, @max(next, floor));
                } else |_| {}
            }
            try candidates.append(self.allocator, @max(pending.prior_tracker, floor));
        }
        try candidates.append(self.allocator, @max(tracker_value, floor));
        std.mem.sort(u64, candidates.items, {}, u64Ascending);
        var unique_len: usize = 0;
        for (candidates.items) |value| {
            if (unique_len > 0 and candidates.items[unique_len - 1] == value) continue;
            candidates.items[unique_len] = value;
            unique_len += 1;
        }
        candidates.shrinkRetainingCapacity(unique_len);

        const msg_id = agent_types.generateUlid();
        var payload = agent_types.Payload{ .agent_stop = .{ .session_id = session_id } };
        defer payload.deinit(self.allocator);
        if (reason) |r| payload.agent_stop.reason = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, r));
        const stop_json = try self.serializeEnvelopeForSend(.{
            .session_id = session_id,
            .message_id = msg_id,
            .sequence = floor,
            .timestamp = compat.time.nowMillis(),
            .payload = payload,
        });
        defer self.allocator.free(stop_json);

        var owned_reason = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, reason orelse ""));
        var reason_owned_by_map = false;
        errdefer if (!reason_owned_by_map) owned_reason.deinit(self.allocator);
        const owned_candidates = try candidates.toOwnedSlice(self.allocator);
        var candidates_owned_by_map = false;
        errdefer if (!candidates_owned_by_map) self.allocator.free(owned_candidates);
        try self.stop_probes_by_session.put(session_id, .{
            .first_msg_id = msg_id,
            .candidates = owned_candidates,
            .next_index = 1,
            .reason = owned_reason,
        });
        reason_owned_by_map = true;
        candidates_owned_by_map = true;

        self.writeEnvelopeJson(stop_json) catch |err| {
            self.retireStopProbe(session_id);
            return err;
        };
        return msg_id;
    }

    fn serializeEnvelopeForSend(self: *Self, env: agent_types.Envelope) ![]u8 {
        if (self.sender == null) return error.NoSender;
        return try envelope.serializeEnvelope(env, self.allocator);
    }

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
                if (self.pendingSendFor(p.session_id, env.in_reply_to)) |start| {
                    if (start.kind == .start) {
                        if (self.admitted_by_session.getPtr(p.session_id)) |slot| {
                            slot.started_observed = true;
                        }
                        try self.noteProvenFloor(p.session_id, start.sequence + 1);
                        self.invalidateBelowFloorAfterStart(p.session_id);
                    }
                } else {
                    try self.noteProvenFloor(p.session_id, 2);
                    self.invalidateBelowFloorAfterStart(p.session_id);
                }
                if (self.peekNextSequence(p.session_id) < self.provenFloor(p.session_id)) {
                    self.setTrackerValue(p.session_id, self.provenFloor(p.session_id)) catch {};
                }
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
                if (self.pendingSettlementFloor(env.session_id)) |min_candidate_sequence| {
                    try self.noteProvenFloor(env.session_id, min_candidate_sequence + 1);
                    self.retireSettledPendingSends(env.session_id);
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
                if (try self.handleProbeReply(env.session_id, env.in_reply_to, e.code)) return;
                if (env.in_reply_to != null and !self.replyNamesPendingSend(env.session_id, env.in_reply_to)) return;
                const session_gone = try self.handleCorrelatedRejection(env.session_id, env.in_reply_to, e.code);
                const error_copy = try self.allocator.dupe(u8, e.message);
                self.last_error.deinit(self.allocator);
                self.last_error = OwnedSlice(u8).initOwned(error_copy);
                try self.setSessionError(env.session_id, e.message);
                if (session_gone) self.clearGoneSessionIdentity(env.session_id);
            },
            .nack => |n| {
                if (try self.handleProbeReply(env.session_id, env.in_reply_to, agentCodeFromNack(n.error_code))) return;
                if (!self.replyNamesPendingSend(env.session_id, env.in_reply_to)) return;
                const duplicate_admitted = if (n.error_code) |code| code == .duplicate_sequence else false;
                if (duplicate_admitted) {
                    if (self.pendingSendFor(env.session_id, env.in_reply_to)) |entry| {
                        if (entry.kind == .message) {
                            try self.retireDuplicateAdmittedSend(env.session_id, env.in_reply_to, entry);
                            if (entry.resend_of_pending and (entry.source_settled or entry.proven_floor_at_send <= entry.sequence) and !self.hasCompetingPayload(env.session_id, entry.sequence, entry.payload_hash)) return;
                            self.rederiveProvenanceAt(env.session_id, entry.sequence);
                        } else if (entry.kind == .stop) {
                            if (entry.sequence != std.math.maxInt(u64)) try self.noteProvenFloor(env.session_id, entry.sequence + 1);
                        }
                    }
                }
                const session_gone = try self.handleCorrelatedRejection(env.session_id, env.in_reply_to, agentCodeFromNack(n.error_code));
                const reason_copy = try self.allocator.dupe(u8, n.reason.slice());
                self.last_error.deinit(self.allocator);
                self.last_error = OwnedSlice(u8).initOwned(reason_copy);
                try self.setSessionError(env.session_id, n.reason.slice());
                if (session_gone) self.clearGoneSessionIdentity(env.session_id);
            },
            .agent_stopped => |p| {
                if (self.stop_probes_by_session.get(p.session_id)) |probe| {
                    if (env.in_reply_to) |reply_to| {
                        if (!std.mem.eql(u8, &reply_to, &probe.first_msg_id)) return;
                    }
                }
                if (self.session_id) |sid| {
                    if (std.mem.eql(u8, sid[0..], p.session_id[0..])) self.session_id = null;
                }
                _ = self.next_sequence_by_session.remove(p.session_id);
                _ = self.proven_floor_by_session.remove(p.session_id);
                _ = self.stop_revert_bound_by_session.remove(p.session_id);
                _ = self.tracker_epoch_by_session.remove(p.session_id);
                self.clearSessionControlState(p.session_id);
                try self.session_complete_flags.put(p.session_id, true);
            },
            else => {},
        }
    }

    fn clearGoneSessionIdentity(self: *Self, session_id: agent_types.SessionId) void {
        const active = self.session_id orelse return;
        if (!std.mem.eql(u8, active[0..], session_id[0..])) return;
        self.session_id = null;
        self.last_error.deinit(self.allocator);
        self.last_error = OwnedSlice(u8).initBorrowed("");
        self.last_result_json.deinit(self.allocator);
        self.last_result_json = OwnedSlice(u8).initBorrowed("");
    }

    fn clearSessionControlState(self: *Self, session_id: agent_types.SessionId) void {
        if (self.pending_sends_by_session.fetchRemove(session_id)) |entry| {
            var list = entry.value;
            list.deinit(self.allocator);
        }
        _ = self.admitted_by_session.remove(session_id);
        self.retireStopProbe(session_id);
    }

    fn retireStopProbe(self: *Self, session_id: agent_types.SessionId) void {
        if (self.stop_probes_by_session.fetchRemove(session_id)) |entry| {
            var probe = entry.value;
            probe.reason.deinit(self.allocator);
            self.allocator.free(probe.candidates);
        }
    }

    fn handleProbeReply(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid, code: ?agent_types.AgentErrorCode) !bool {
        const reply_to = in_reply_to orelse return false;
        const probe = self.stop_probes_by_session.getPtr(session_id) orelse return false;
        if (!std.mem.eql(u8, &reply_to, &probe.first_msg_id)) return false;

        const retry = probe.next_index < probe.candidates.len and (if (code) |c| c == .invalid_request else false);
        const session_gone = if (code) |c| c == .agent_not_found or c == .session_expired else false;
        if (retry) {
            const next_index = probe.next_index;
            const retry_msg_id = agent_types.generateUlid();
            var retry_payload = agent_types.Payload{ .agent_stop = .{ .session_id = session_id } };
            defer retry_payload.deinit(self.allocator);
            retry_payload.agent_stop.reason = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, probe.reason.slice()));
            const retry_json = try self.serializeEnvelopeForSend(.{
                .session_id = session_id,
                .message_id = retry_msg_id,
                .sequence = probe.candidates[next_index],
                .timestamp = compat.time.nowMillis(),
                .payload = retry_payload,
            });
            defer self.allocator.free(retry_json);
            probe.first_msg_id = retry_msg_id;
            probe.next_index = next_index + 1;
            self.writeEnvelopeJson(retry_json) catch |err| {
                self.retireStopProbe(session_id);
                return err;
            };
        } else if (session_gone) {
            _ = self.next_sequence_by_session.remove(session_id);
            _ = self.proven_floor_by_session.remove(session_id);
            _ = self.stop_revert_bound_by_session.remove(session_id);
            _ = self.tracker_epoch_by_session.remove(session_id);
            self.clearSessionControlState(session_id);
        } else {
            self.retireStopProbe(session_id);
        }
        return true;
    }

    fn retirePendingSend(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid) void {
        const reply_to = in_reply_to orelse return;
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return;
        for (list.items, 0..) |pending, index| {
            if (!std.mem.eql(u8, &reply_to, &pending.msg_id)) continue;
            _ = list.orderedRemove(index);
            return;
        }
    }

    fn retireSettledPendingSends(self: *Self, session_id: agent_types.SessionId) void {
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return;
        var oldest_index: ?usize = null;
        for (list.items, 0..) |pending, index| {
            if (pending.kind != .message) continue;
            if (oldest_index == null) oldest_index = index;
        }
        const index = oldest_index orelse return;
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
    }

    fn pendingSettlementFloor(self: *Self, session_id: agent_types.SessionId) ?u64 {
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return null;
        var min_candidate: u64 = std.math.maxInt(u64);
        for (list.items) |pending| {
            if (pending.kind != .message) continue;
            min_candidate = @min(min_candidate, pending.sequence);
        }
        return if (min_candidate == std.math.maxInt(u64)) null else min_candidate;
    }

    fn replyNamesPendingSend(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid) bool {
        return self.pendingSendFor(session_id, in_reply_to) != null;
    }

    fn pendingSendFor(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid) ?PendingSend {
        const reply_to = in_reply_to orelse return null;
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return null;
        for (list.items) |pending| {
            if (std.mem.eql(u8, &reply_to, &pending.msg_id)) return pending;
        }
        return null;
    }

    fn agentCodeFromNack(code: ?agent_types.ErrorCode) ?agent_types.AgentErrorCode {
        const c = code orelse return null;
        return switch (c) {
            .invalid_request, .invalid_sequence, .duplicate_sequence => .invalid_request,
            else => null,
        };
    }

    fn noteProvenFloor(self: *Self, session_id: agent_types.SessionId, bound: u64) !void {
        const current = self.proven_floor_by_session.get(session_id) orelse 0;
        if (bound > current) try self.proven_floor_by_session.put(session_id, bound);
    }

    fn provenFloor(self: *Self, session_id: agent_types.SessionId) u64 {
        return self.proven_floor_by_session.get(session_id) orelse 0;
    }

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

    fn setTrackerValue(self: *Self, session_id: agent_types.SessionId, value: u64) !void {
        const epoch_gop = try self.tracker_epoch_by_session.getOrPut(session_id);
        if (!epoch_gop.found_existing) epoch_gop.value_ptr.* = 0;
        const tracker_gop = try self.next_sequence_by_session.getOrPut(session_id);
        tracker_gop.value_ptr.* = value;
        epoch_gop.value_ptr.* += 1;
    }

    fn restoreTrackerState(self: *Self, session_id: agent_types.SessionId, value: u64, epoch: u64) void {
        self.next_sequence_by_session.put(session_id, value) catch {};
        self.tracker_epoch_by_session.put(session_id, epoch) catch {};
    }

    fn hasCompetingPayload(self: *Self, session_id: agent_types.SessionId, sequence: u64, payload_hash: u64) bool {
        const list = self.pending_sends_by_session.getPtr(session_id) orelse return false;
        for (list.items) |pending| {
            if (pending.kind != .message or pending.sequence != sequence) continue;
            if (pending.payload_hash != payload_hash) return true;
        }
        return false;
    }

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
            if (viable_source) pending.proven_floor_at_send = @min(pending.proven_floor_at_send, source_floor);
        }
    }

    fn retireDuplicateAdmittedSend(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid, entry: PendingSend) !void {
        const restore = @max(entry.sequence + 1, self.provenFloor(session_id));
        try self.noteProvenFloor(session_id, restore);
        try self.setTrackerValue(session_id, restore);
        self.retirePendingSend(session_id, in_reply_to);
    }

    fn handleCorrelatedRejection(self: *Self, session_id: agent_types.SessionId, in_reply_to: ?agent_types.Ulid, code: ?agent_types.AgentErrorCode) !bool {
        const reply_to = in_reply_to orelse return false;

        const list = self.pending_sends_by_session.getPtr(session_id) orelse return false;
        var matched: ?usize = null;
        for (list.items, 0..) |pending, index| {
            if (std.mem.eql(u8, &reply_to, &pending.msg_id)) {
                matched = index;
                break;
            }
        }
        const index = matched orelse return false;

        const session_gone = if (code) |c| c == .agent_not_found or c == .session_expired else false;
        if (session_gone) {
            _ = self.next_sequence_by_session.remove(session_id);
            _ = self.proven_floor_by_session.remove(session_id);
            _ = self.stop_revert_bound_by_session.remove(session_id);
            _ = self.tracker_epoch_by_session.remove(session_id);
            self.clearSessionControlState(session_id);
            return true;
        }

        const rejected = list.items[index];
        if (rejected.kind == .start) _ = self.admitted_by_session.remove(session_id);
        const stop_resync = rejected.kind == .stop and rejected.prior_tracker != rejected.sequence;
        var rejected_revert_bound: u64 = 0;
        if (stop_resync) {
            const prior_bound = rejected.prior_tracker;
            const existing_revert = self.stop_revert_bound_by_session.get(session_id);
            rejected_revert_bound = if (existing_revert) |e| @min(e, prior_bound) else prior_bound;
            try self.stop_revert_bound_by_session.put(session_id, rejected_revert_bound);
        }
        if (rejected.kind == .stop) {
            if (!stop_resync) {
                _ = list.orderedRemove(index);
                if (self.peekNextSequence(session_id) < self.provenFloor(session_id)) {
                    self.setTrackerValue(session_id, self.provenFloor(session_id)) catch {};
                }
                return false;
            }
            var mirror_owner_pending = false;
            for (list.items) |pending| {
                if (pending.kind == .stop) continue;
                if (pending.send_epoch != self.trackerEpoch(session_id)) continue;
                if (pending.sequence + 1 == self.peekNextSequence(session_id)) mirror_owner_pending = true;
            }
            if (!mirror_owner_pending and self.peekNextSequence(session_id) == rejected.sequence) {
                var pending_floor: u64 = rejected_revert_bound;
                for (list.items) |pending| {
                    if (pending.kind == .message) {
                        pending_floor = @min(pending_floor, @min(pending.sequence, pending.prior_tracker));
                    } else if (pending.kind == .stop) {
                        pending_floor = @min(pending_floor, pending.prior_tracker);
                    }
                }
                var undo = pending_floor;
                undo = @max(undo, self.provenFloor(session_id));
                try self.noteProvenFloor(session_id, undo);
                _ = list.orderedRemove(index);
                try self.setTrackerValue(session_id, undo);
            } else {
                _ = list.orderedRemove(index);
                if (self.peekNextSequence(session_id) < self.provenFloor(session_id)) {
                    self.setTrackerValue(session_id, self.provenFloor(session_id)) catch {};
                }
            }
            return false;
        }
        const busy = if (code) |c| c == .agent_busy else false;
        if (busy) {
            const parity = @max(rejected.sequence, self.provenFloor(session_id));
            try self.noteProvenFloor(session_id, parity);
            _ = list.orderedRemove(index);
            if (rejected.kind == .message) self.rederiveProvenanceAt(session_id, rejected.sequence);
            try self.setTrackerValue(session_id, parity);
            return false;
        }
        const current = self.peekNextSequence(session_id);
        const mirror_is_own = rejected.sequence != std.math.maxInt(u64) and current == rejected.sequence + 1;
        const base = if (mirror_is_own) rejected.prior_tracker else current;
        var floor = @min(base, rejected.prior_tracker);
        for (list.items, 0..) |pending, i| {
            if (i == index) continue;
            if (pending.kind == .message) {
                floor = @min(floor, pending.prior_tracker);
                floor = @min(floor, pending.sequence);
            } else if (pending.kind == .stop) {
                floor = @min(floor, pending.prior_tracker);
            }
        }
        if (self.stop_revert_bound_by_session.get(session_id)) |revert_bound| {
            floor = @min(floor, revert_bound);
        }
        floor = @max(floor, self.provenFloor(session_id));
        try self.noteProvenFloor(session_id, floor);
        _ = list.orderedRemove(index);
        if (rejected.kind == .message) {
            self.rederiveProvenanceAt(session_id, rejected.sequence);
        }
        try self.setTrackerValue(session_id, floor);
        return false;
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

    pub fn isSessionAdmitted(self: *Self, session_id: agent_types.SessionId) bool {
        const slot = self.admitted_by_session.get(session_id) orelse return false;
        return slot.exclusive_id and slot.started_observed;
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

    _ = try client.sendAgentMessage(sid1, "{\"m\":1}", null);
    _ = try client.sendAgentMessage(sid2, "{\"m\":2}", null);
    _ = try client.sendAgentMessage(sid1, "{\"m\":3}", null);

    var stopped_env = agent_types.Envelope{
        .session_id = sid1,
        .message_id = agent_types.generateUlid(),
        .sequence = 10,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_stopped = .{ .session_id = sid1 } },
    };
    defer stopped_env.deinit(allocator);
    try client.processEnvelope(stopped_env);

    _ = try client.sendAgentMessage(sid1, "{\"m\":4}", null);
    _ = try client.sendAgentMessage(sid2, "{\"m\":5}", null);

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
    _ = try client.sendAgentStartWithSession(sid, "{}", null);
    const msg_id = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));

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
    _ = try client.sendAgentStartWithSession(sid, "{}", null);
    const first_id = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    const second_id = try client.sendAgentMessage(sid, "{\"m\":2}", null);

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
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));

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
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));

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
    _ = try client.sendAgentStartWithSession(sid, "{}", null);
    const msg_id = try client.sendAgentMessage(sid, "{\"m\":1}", null);

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
    _ = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);

    _ = try client.sendAgentStop(sid, "completed");
    var stop_env = try harness.envelopeAt(2);
    defer stop_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), stop_env.sequence);
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    try std.testing.expectEqual(@as(u64, 3), client.sequence);

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
    _ = try client.sendAgentStartWithSession(sid, "{}", null);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    const stop_id = try client.sendAgentStop(sid, "teardown");

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
    _ = try client.sendAgentStartWithSession(sid, "{}", null);
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
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);

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

    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);
    var next_env = try harness.envelopeAt(2);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), next_env.sequence);
}

test "AgentProtocolClient explicit-sequence sends carry the given value and roll back on rejection (#210 gap 7)" {
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
    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));
}

test "AgentProtocolClient explicit-sequence send failure restores the PRE-SEND tracker state (#210 gap 7)" {
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
        try std.testing.expectEqual(@as(usize, 0), harness.writes.items.len);
        try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));
    }
    try std.testing.expect(exercised_failure);
}

test "AgentProtocolClient rejects an un-advanceable explicit sequence before any mutation (#210 gap 7)" {
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));
    try std.testing.expectEqual(@as(usize, 1), harness.writes.items.len);
}

test "AgentProtocolClient agent_busy rejection of an explicit send preserves the busy-proven sequence (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const msg_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 7);

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
    try std.testing.expectEqual(@as(u64, 7), client.peekNextSequence(sid));

    _ = try client.sendAgentMessage(sid, "{\"m\":1-retry}", null);
    var retried = try harness.envelopeAt(1);
    defer retried.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 7), retried.sequence);
}

test "AgentProtocolClient rejects a start against a tracker at the sequence maximum (#210 gap 7)" {
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":edge}", null, std.math.maxInt(u64) - 1);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), client.peekNextSequence(sid));

    try std.testing.expectError(error.InvalidSequence, client.sendAgentStartWithSession(sid, "{}", null));
    try std.testing.expectEqual(@as(usize, 1), harness.writes.items.len);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), client.peekNextSequence(sid));
}

test "AgentProtocolClient rolls the tracker back on a correlated nack rejection too (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null);
    const msg_id = try client.sendAgentMessage(sid, "{\"m\":1}", null);

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
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null);
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
    const msg_id = try client.sendAgentMessage(sid, "{\"m\":1}", null);

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
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    const resend_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2);

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

    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(!client.isSessionComplete(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);

    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);
    var next_env = try harness.envelopeAt(3);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), next_env.sequence);
}

test "AgentProtocolClient duplicate_sequence nack on a start falls through to the rejection path (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);

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

    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    const remaining = if (client.pending_sends_by_session.getPtr(sid)) |l| l.items.len else 0;
    try std.testing.expectEqual(@as(usize, 0), remaining);
}

test "AgentProtocolClient duplicate_sequence nack restores only the PROVEN step — the optimistic bound waits for its own evidence (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);
    const resend_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2);
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

    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 2), pending.items.len);

    const ladder_id = try client.sendAgentMessage(sid, "{\"m\":2}", null);
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

    _ = try client.sendAgentMessage(sid, "{\"m\":3}", null);
    var next_env = try harness.envelopeAt(5);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 4), next_env.sequence);
}

test "AgentProtocolClient duplicate_sequence nack ignores optimistic sends interleaved before the reply (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);
    const resend_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2);
    _ = try client.sendAgentMessage(sid, "{\"m\":3}", null);

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

    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 3), pending.items.len);

    _ = try client.sendAgentMessage(sid, "{\"m\":4}", null);
    var next_env = try harness.envelopeAt(5);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), next_env.sequence);
}

test "AgentProtocolClient payload identity delimits message and options components (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "1", "23");

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

    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);

    try std.testing.expect(messagePayloadHash("1", "23") != messagePayloadHash("12", "3"));
    try std.testing.expectEqual(messagePayloadHash("{\"m\":1}", null), messagePayloadHash("{\"m\":1}", ""));
}

test "AgentProtocolClient duplicate_sequence nack on a mismatched payload at a pending sequence is not a retry (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    const other_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":OTHER}", null, 2);

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

    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
}

test "AgentProtocolClient duplicate restore ignores a forward pending explicit send's optimistic mirror (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":forward}", null, 7);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2);
    const retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2);

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

    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 2), pending.items.len);

    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);
    var next_env = try harness.envelopeAt(4);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), next_env.sequence);
}

test "AgentProtocolClient resend provenance survives the original's settlement (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    const resend_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2);

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

    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    const remaining = if (client.pending_sends_by_session.getPtr(sid)) |l| l.items.len else 0;
    try std.testing.expectEqual(@as(usize, 0), remaining);
}

test "AgentProtocolClient a competing payload at the sequence disqualifies the silent retry (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":A}", null);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":B}", null, 2);
    const retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2);

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

    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 2), pending.items.len);
}

test "AgentProtocolClient rejected source clears stale retry provenance (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    const first_a_id = try client.sendAgentMessage(sid, "{\"m\":A}", null);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":B}", null, 2);
    const retry_a_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2);

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

    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
}

test "AgentProtocolClient two retries of a rejected payload cannot vouch for each other (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    const original_id = try client.sendAgentMessage(sid, "{\"m\":A}", null);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2);
    const second_retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2);

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

    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
}

test "AgentProtocolClient a retired competing duplicate requalifies other payloads' retries (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":A}", null);
    const competing_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":B}", null, 2);
    const retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2);

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
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    client.clearSessionTerminalState(sid);

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

    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(!client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
}

test "AgentProtocolClient a non-retry duplicate retirement invalidates same-payload retries (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":settled}", null);
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

    const stale_a_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2);
    const retry_a_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2);

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
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
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

    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    const remaining = if (client.pending_sends_by_session.getPtr(sid)) |l| l.items.len else 0;
    try std.testing.expectEqual(@as(usize, 0), remaining);
}

test "AgentProtocolClient masked same-payload ancestry breaks with its source (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    const first_a_id = try client.sendAgentMessage(sid, "{\"m\":A}", null);
    const competing_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":B}", null, 2);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2);
    const third_a_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2);

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
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
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
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
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

    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
}

test "AgentProtocolClient a settled source preserves same-payload retry provenance (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":A}", null);
    const retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2);

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
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    client.clearSessionTerminalState(sid);

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

    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(!client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    const remaining = if (client.pending_sends_by_session.getPtr(sid)) |l| l.items.len else 0;
    try std.testing.expectEqual(@as(usize, 0), remaining);
}

test "AgentProtocolClient a settled source does not bless the payload of a stale oldest record (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":A}", null);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":B}", null, 2);
    const retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2);

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

    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
}

test "AgentProtocolClient a settlement breaks different-payload chains at the sequence (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":A}", null);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":B}", null, 2);
    const b_retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":B}", null, 2);
    const other_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":C}", null, 2);

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

    var other_rejected = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = other_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer other_rejected.deinit(allocator);
    try client.processEnvelope(other_rejected);
    client.clearSessionTerminalState(sid);

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

    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
}

test "AgentProtocolClient settled provenance propagates to retries recorded after the settlement (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":A}", null);
    const first_retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2);

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

    const second_retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2);
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
    try client.processEnvelope(first_duplicate);

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
    client.clearSessionTerminalState(sid);

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

    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(!client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    const remaining = if (client.pending_sends_by_session.getPtr(sid)) |l| l.items.len else 0;
    try std.testing.expectEqual(@as(usize, 0), remaining);
}

test "AgentProtocolClient an accepted start seeds the proven floor (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));

    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    var next_env = try harness.envelopeAt(3);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), next_env.sequence);
}

test "AgentProtocolClient an adopted uncorrelated start raises the live tracker to the proven floor (#210 gap 7)" {
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
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));

    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    var first = try harness.envelopeAt(0);
    defer first.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), first.sequence);
}

test "AgentProtocolClient settlement raise uses the minimum candidate, not the retired record (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":forward}", null, 7);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2);

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

    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);
    var next_env = try harness.envelopeAt(3);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), next_env.sequence);
}

test "AgentProtocolClient settlement restores progress a delayed busy answer rewound (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    const first_id = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2);

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
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));

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
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));

    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);
    var next_env = try harness.envelopeAt(3);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), next_env.sequence);
}

test "AgentProtocolClient generic backward rejections never floor below proven progress (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);
    _ = try client.sendAgentMessage(sid, "{\"m\":3}", null);
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
    const back_three_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":back-3}", null, 3);
    const back_two_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":back-2}", null, 2);

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
    try std.testing.expectEqual(@as(u64, 5), client.peekNextSequence(sid));

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
    var next_env = try harness.envelopeAt(6);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 5), next_env.sequence);
}

test "AgentProtocolClient generic invalid_request on a resend stays ambiguous — floors to the original's sequence (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    const resend_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 2);

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

    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
}

test "AgentProtocolClient duplicate restore retains clean priors of backward pending sends (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);
    _ = try client.sendAgentMessage(sid, "{\"m\":3}", null);
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
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":back-3}", null, 3);
    const back_two_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":back-2}", null, 2);

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

    try std.testing.expectEqual(@as(u64, 5), client.peekNextSequence(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
    _ = try client.sendAgentMessage(sid, "{\"m\":4}", null);
    var next_env = try harness.envelopeAt(6);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 5), next_env.sequence);
}

test "AgentProtocolClient retries at a sequence below the proven floor surface (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":settled}", null);
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

    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2);
    const retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2);

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

    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
}

test "AgentProtocolClient stops at the sequence maximum are the ceiling teardown (#210 gap 7)" {
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null);

    _ = try client.sendAgentStopWithSequence(sid, "teardown", std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), client.peekNextSequence(sid));
    try std.testing.expectEqual(@as(usize, 2), harness.writes.items.len);
    try std.testing.expectError(error.InvalidSequence, client.sendAgentStartWithSession(sid, "{}", null));
}

test "AgentProtocolClient stop setup failure restores the compatibility mirror (#210 gap 7)" {
    const allocator = std.testing.allocator;
    const sid = agent_types.generateSessionId();
    var exercised_failure = false;
    for (0..6) |fail_index| {
        var harness = Gap7Harness.init();
        defer harness.deinit();
        harness.wire();
        const client = &harness.client;
        _ = try client.sendAgentStartWithSession(sid, "{}", null);
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        client.allocator = failing.allocator();
        const sent = client.sendAgentStopWithSequence(sid, "teardown", 5);
        client.allocator = allocator;
        const failed = if (sent) |_| false else |_| true;
        if (!failed) continue;
        exercised_failure = true;
        try std.testing.expectEqual(@as(usize, 1), harness.writes.items.len);
        try std.testing.expectEqual(@as(u64, 1), client.sequence);
        try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));
    }
    try std.testing.expect(exercised_failure);
}

test "AgentProtocolClient rejected stop undo caps a contaminated pre-resync tracker (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":forward}", null, 7);
    const stop_id = try client.sendAgentStopWithSequence(sid, "stale", 1);

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

    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    var next_env = try harness.envelopeAt(3);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), next_env.sequence);
}

test "AgentProtocolClient a rejected stop does not undo a later accepted send's equal-valued mirror (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
        _ = try client.sendAgentMessage(sid, "{\"m\":fill}", null);
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
    try std.testing.expectEqual(@as(u64, 6), client.peekNextSequence(sid));

    const stop_id = try client.sendAgentStopWithSequence(sid, "stale", 7);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":at-six}", null, 6);

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

    try std.testing.expectEqual(@as(u64, 7), client.peekNextSequence(sid));

    _ = try client.sendAgentMessage(sid, "{\"m\":next}", null);
    var next_env = try harness.envelopeAt(7);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 7), next_env.sequence);
}

test "AgentProtocolClient a message snapshotted on an unresolved stop resync cannot launder it into the floor (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentStopWithSequence(sid, "caller-known", 7);
    const message_id = try client.sendAgentMessage(sid, "{\"m\":1}", null);

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
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));

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
    var next_env = try harness.envelopeAt(3);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), next_env.sequence);
}

test "AgentProtocolClient duplicate_sequence for a stop records the proven step (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null);
    const first_stale_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":stale-1}", null, 1);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":stale-2}", null, 1);

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

    const stop_id = try client.sendAgentStopWithSequence(sid, "teardown", 1);
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

    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    var next_env = try harness.envelopeAt(4);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), next_env.sequence);
}

test "AgentProtocolClient a rejected stop does not honor a mirror a reconciliation superseded (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":forward}", null, 6);
    const later_id = try client.sendAgentMessage(sid, "{\"m\":later}", null);
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
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));

    const stop_id = try client.sendAgentStopWithSequence(sid, "stale", 7);
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

    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));
    _ = try client.sendAgentMessage(sid, "{\"m\":next}", null);
    var next_env = try harness.envelopeAt(4);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), next_env.sequence);
}

test "AgentProtocolClient a skipped stop-undo still raises the tracker to the proven floor (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":settled}", null);
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
    const stop_id = try client.sendAgentStopWithSequence(sid, "teardown", 4);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":at-three}", null, 3);

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

    try std.testing.expectEqual(@as(u64, 5), client.peekNextSequence(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    _ = try client.sendAgentMessage(sid, "{\"m\":next}", null);
    var next_env = try harness.envelopeAt(4);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 5), next_env.sequence);
}
test "AgentProtocolClient a later send's tracker write supersedes an older mirror's ownership (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":forward}", null, 6);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":rewrites}", null, 2);
    const stop_id = try client.sendAgentStopWithSequence(sid, "stale", 7);

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

    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));
    _ = try client.sendAgentMessage(sid, "{\"m\":next}", null);
    var next_env = try harness.envelopeAt(4);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), next_env.sequence);
}

test "AgentProtocolClient a retry of a source recorded before the floor keeps the silent path (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":A}", null);
    const busy_id = try client.sendAgentMessage(sid, "{\"m\":busy-me}", null);
    var busy = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = busy_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_busy, .message = try allocator.dupe(u8, "session already processing a message") } },
    };
    defer busy.deinit(allocator);
    try client.processEnvelope(busy);
    client.clearSessionTerminalState(sid);

    const retry_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 2);
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

    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(!client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
    _ = try client.sendAgentMessage(sid, "{\"m\":next}", null);
    var next_env = try harness.envelopeAt(4);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), next_env.sequence);
}
test "AgentProtocolClient an accepted start invalidates pre-reply sequence-1 message ancestry (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 1);
    const second_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 1);

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

    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
    _ = try client.sendAgentMessage(sid, "{\"m\":next}", null);
    var next_env = try harness.envelopeAt(3);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), next_env.sequence);
}
test "AgentProtocolClient a pre-wire send failure preserves a live mirror's ownership (#210 gap 7)" {
    const allocator = std.testing.allocator;
    const sid = agent_types.generateSessionId();
    var exercised_failure = false;
    for (0..8) |fail_index| {
        var harness = Gap7Harness.init();
        defer harness.deinit();
        harness.wire();
        const client = &harness.client;
        const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
        _ = try client.sendAgentStopWithSequence(sid, "caller-known", 7);
        _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":at-six}", null, 6);

        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        client.allocator = failing.allocator();
        const sent = client.sendAgentMessageWithSequence(sid, "{\"m\":doomed}", null, 7);
        client.allocator = allocator;
        const failed = if (sent) |_| false else |_| true;
        if (!failed) continue;
        exercised_failure = true;
        try std.testing.expectEqual(@as(u64, 7), client.peekNextSequence(sid));
        const pending = client.pending_sends_by_session.getPtr(sid).?;
        const owner = pending.items[1];
        try std.testing.expectEqual(client.trackerEpoch(sid), owner.send_epoch);

        const stop_record = pending.items[0];
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
        try std.testing.expectEqual(@as(u64, 7), client.peekNextSequence(sid));
    }
    try std.testing.expect(exercised_failure);
}
test "AgentProtocolClient a message at sequence 1 is inherently below the start's floor (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 1);
    const second_id = try client.sendAgentMessageWithSequence(sid, "{\"m\":A}", null, 1);

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

    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 2), client.peekNextSequence(sid));
    const pending = client.pending_sends_by_session.getPtr(sid).?;
    try std.testing.expectEqual(@as(usize, 2), pending.items.len);
}

test "AgentProtocolClient a no-op stop does not supersede a pending mirror's ownership (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    const stop_id = try client.sendAgentStopWithSequence(sid, "stale", 7);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":at-six}", null, 6);
    _ = try client.sendAgentStop(sid, "teardown");

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

    try std.testing.expectEqual(@as(u64, 7), client.peekNextSequence(sid));
    _ = try client.sendAgentMessage(sid, "{\"m\":next}", null);
    var next_env = try harness.envelopeAt(4);
    defer next_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 7), next_env.sequence);
}

test "AgentProtocolClient admission evidence requires an exclusive id's own correlated agent_started (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid1 = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid1, "{}", null);
    try std.testing.expect(!client.isSessionAdmitted(sid1));
    var uncorrelated = agent_types.Envelope{
        .session_id = sid1,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = sid1 } },
    };
    defer uncorrelated.deinit(allocator);
    try client.processEnvelope(uncorrelated);
    try std.testing.expect(!client.isSessionAdmitted(sid1));
    try std.testing.expect(!(client.admitted_by_session.get(sid1) orelse SessionAdmission{}).started_observed);

    const sid2 = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid2, "{}", null);
    var foreign = agent_types.Envelope{
        .session_id = sid2,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .in_reply_to = agent_types.generateUlid(),
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = sid2 } },
    };
    defer foreign.deinit(allocator);
    try client.processEnvelope(foreign);
    try std.testing.expect(!client.isSessionAdmitted(sid2));
    try std.testing.expect(!(client.admitted_by_session.get(sid2) orelse SessionAdmission{}).started_observed);

    const sid3 = agent_types.generateSessionId();
    const supplied_start_id = try client.sendAgentStartWithSession(sid3, "{}", null);
    var supplied_started = agent_types.Envelope{
        .session_id = sid3,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .in_reply_to = supplied_start_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = sid3 } },
    };
    defer supplied_started.deinit(allocator);
    try client.processEnvelope(supplied_started);
    try std.testing.expect((client.admitted_by_session.get(sid3) orelse SessionAdmission{}).started_observed);
    try std.testing.expect(!client.isSessionAdmitted(sid3));

    const start_id = try client.sendAgentStart("{}", null);
    var generated_start_env = try harness.envelopeAt(3);
    defer generated_start_env.deinit(allocator);
    const sid4 = generated_start_env.session_id;
    var started_env = agent_types.Envelope{
        .session_id = sid4,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .in_reply_to = start_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = sid4 } },
    };
    defer started_env.deinit(allocator);
    try client.processEnvelope(started_env);
    try std.testing.expect(client.isSessionAdmitted(sid4));

    const stop_id = try client.sendAgentStop(sid4, "done");
    var stopped_env = agent_types.Envelope{
        .session_id = sid4,
        .message_id = agent_types.generateUlid(),
        .sequence = 2,
        .in_reply_to = stop_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_stopped = .{ .session_id = sid4, .reason = OwnedSlice(u8).initBorrowed("done") } },
    };
    defer stopped_env.deinit(allocator);
    try client.processEnvelope(stopped_env);
    try std.testing.expect(!client.isSessionAdmitted(sid4));
}

test "AgentProtocolClient rejected start retires its admission reservation (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
    try std.testing.expect(client.admitted_by_session.get(sid) != null);

    var busy = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = start_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_busy, .message = try allocator.dupe(u8, "session already exists") } },
    };
    defer busy.deinit(allocator);
    try client.processEnvelope(busy);

    try std.testing.expect(client.admitted_by_session.get(sid) == null);
    try std.testing.expect(!client.isSessionAdmitted(sid));
    if (client.pending_sends_by_session.get(sid)) |pending| {
        try std.testing.expectEqual(@as(usize, 0), pending.items.len);
    }
}

test "AgentProtocolClient stale correlated agent_error does not fail the live session (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null);
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
    const msg_id = try client.sendAgentMessage(sid, "{\"m\":1}", null);

    var stale = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = agent_types.generateUlid(),
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "stale rejection") } },
    };
    defer stale.deinit(allocator);
    try client.processEnvelope(stale);
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(!client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
    try std.testing.expect(client.session_id != null);

    var ours = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = msg_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer ours.deinit(allocator);
    try client.processEnvelope(ours);
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.isSessionComplete(sid));
}

test "AgentProtocolClient correlated agent_not_found clears state only for a request of the current registration (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(sid, "{}", null);
    var first_started_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .in_reply_to = null,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = sid } },
    };
    defer first_started_env.deinit(allocator);
    try client.processEnvelope(first_started_env);
    try std.testing.expect(client.session_id != null);
    const msg_id = try client.sendAgentMessage(sid, "{\"m\":1}", null);

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
    try std.testing.expect(client.session_id == null);

    _ = try client.sendAgentStartWithSession(sid, "{}", null);
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
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);

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
    try std.testing.expect(client.session_id != null);
    try std.testing.expect(!client.isSessionComplete(sid));
}

test "AgentProtocolClient correlated session_expired clears state like agent_not_found (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
    try std.testing.expect((client.admitted_by_session.get(sid) orelse SessionAdmission{}).started_observed);
    try std.testing.expect(!client.isSessionAdmitted(sid));
    const msg_id = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    try std.testing.expect(client.session_id != null);

    var expired = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = msg_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .session_expired, .message = try allocator.dupe(u8, "session expired") } },
    };
    defer expired.deinit(allocator);
    try client.processEnvelope(expired);

    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));
    try std.testing.expect(!client.pending_sends_by_session.contains(sid));
    try std.testing.expect(client.session_id == null);
    try std.testing.expect(client.admitted_by_session.get(sid) == null);
    try std.testing.expect(!client.isSessionAdmitted(sid));
}

test "AgentProtocolClient session-gone clears the legacy mirror but keeps the session error (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = try admitExclusiveSession(&harness);
    const msg_id = try client.sendAgentMessage(sid, "{\"m\":1}", null);
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

    try std.testing.expect(client.session_id == null);
    try std.testing.expect(client.getLastErrorForSession(sid) != null);
    try std.testing.expect(client.getLastError() == null);

    _ = try client.sendAgentStartWithSession(sid, "{}", null);
    try std.testing.expect(client.getLastError() == null);
    try std.testing.expect(client.getLastResultJson() == null);
}

test "AgentProtocolClient plain stop replies reach the session-gone and rejection handling (#210 gap 7)" {
    const allocator = std.testing.allocator;

    {
        var harness = Gap7Harness.init();
        defer harness.deinit();
        harness.wire();
        const client = &harness.client;

        const sid = agent_types.generateSessionId();
        const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
        _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
        const stop_id = try client.sendAgentStop(sid, "done");

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
        try std.testing.expect(!client.pending_sends_by_session.contains(sid));
        try std.testing.expect(client.session_id == null);
    }

    {
        var harness = Gap7Harness.init();
        defer harness.deinit();
        harness.wire();
        const client = &harness.client;

        const sid = agent_types.generateSessionId();
        const start_id = try client.sendAgentStartWithSession(sid, "{}", null);
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
        _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
        const stop_id = try client.sendAgentStop(sid, "done");

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

        try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
        try std.testing.expect(client.getLastErrorForSession(sid) != null);
        try std.testing.expect(client.isSessionComplete(sid));
    }
}

fn admitExclusiveSession(harness: *Gap7Harness) !agent_types.SessionId {
    const start_id = try harness.client.sendAgentStart("{}", null);
    var start_env = try harness.envelopeAt(harness.writes.items.len - 1);
    defer start_env.deinit(std.testing.allocator);
    const sid = start_env.session_id;
    var started_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .in_reply_to = start_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = sid } },
    };
    defer started_env.deinit(std.testing.allocator);
    try harness.client.processEnvelope(started_env);
    return sid;
}

fn rejectCorrelatedWithInvalidRequest(allocator: std.mem.Allocator, client: *AgentProtocolClient, sid: agent_types.SessionId, in_reply_to: agent_types.Ulid) !void {
    var rejection = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = in_reply_to,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer rejection.deinit(allocator);
    try client.processEnvelope(rejection);
}

test "AgentProtocolClient stop probe retries the post-send state carrying the caller's reason (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = try admitExclusiveSession(&harness);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);

    const probe_id = (try client.sendAgentStopProbing(sid, "timeout")).?;
    try std.testing.expectEqual(@as(usize, 3), harness.writes.items.len);
    var first_stop = try harness.envelopeAt(2);
    defer first_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), first_stop.sequence);
    try std.testing.expectEqualStrings("timeout", first_stop.payload.agent_stop.getReason().?);

    try rejectCorrelatedWithInvalidRequest(allocator, client, sid, probe_id);

    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(!client.isSessionComplete(sid));
    try std.testing.expectEqual(@as(usize, 4), harness.writes.items.len);
    var retry_stop = try harness.envelopeAt(3);
    defer retry_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), retry_stop.sequence);
    try std.testing.expect(std.meta.activeTag(retry_stop.payload) == .agent_stop);
    try std.testing.expectEqualStrings("timeout", retry_stop.payload.agent_stop.getReason().?);
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
}

test "AgentProtocolClient stop probe settles without a retry when the pre-send stop is accepted (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = try admitExclusiveSession(&harness);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    const probe_id = (try client.sendAgentStopProbing(sid, "timeout")).?;
    try std.testing.expectEqual(@as(usize, 3), harness.writes.items.len);

    var stopped = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = probe_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_stopped = .{ .session_id = sid } },
    };
    defer stopped.deinit(allocator);
    try client.processEnvelope(stopped);

    try std.testing.expectEqual(@as(usize, 3), harness.writes.items.len);
    try std.testing.expect(!client.hasActiveStopProbe(sid));
    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));
    try std.testing.expect(client.isSessionComplete(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
}

test "AgentProtocolClient stop probe is bounded: exhausting the candidate set retires it (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = try admitExclusiveSession(&harness);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);

    const first_id = (try client.sendAgentStopProbing(sid, "timeout")).?;
    try rejectCorrelatedWithInvalidRequest(allocator, client, sid, first_id);
    var retry_stop = try harness.envelopeAt(3);
    defer retry_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), retry_stop.sequence);

    try rejectCorrelatedWithInvalidRequest(allocator, client, sid, retry_stop.message_id);

    try std.testing.expectEqual(@as(usize, 4), harness.writes.items.len);
    try std.testing.expect(!client.hasActiveStopProbe(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
    try std.testing.expect(!client.isSessionComplete(sid));
}

test "AgentProtocolClient stop probe is bounded: a non-sequence rejection does not retry (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = try admitExclusiveSession(&harness);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    const probe_id = (try client.sendAgentStopProbing(sid, "timeout")).?;

    var busy = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = probe_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_busy, .message = try allocator.dupe(u8, "session already processing a message") } },
    };
    defer busy.deinit(allocator);
    try client.processEnvelope(busy);

    try std.testing.expectEqual(@as(usize, 3), harness.writes.items.len);
    try std.testing.expect(!client.hasActiveStopProbe(sid));
    try std.testing.expect(client.getLastErrorForSession(sid) == null);
}

test "AgentProtocolClient stop probe requires an exclusive registration's correlated agent_started (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const unobserved = agent_types.generateSessionId();
    _ = try client.sendAgentStartWithSession(unobserved, "{}", null);
    _ = try client.sendAgentMessage(unobserved, "{\"m\":1}", null);
    const unobserved_writes = harness.writes.items.len;
    try std.testing.expect((try client.sendAgentStopProbing(unobserved, "timeout")) == null);
    try std.testing.expectEqual(unobserved_writes, harness.writes.items.len);
    try std.testing.expect(!client.hasActiveStopProbe(unobserved));

    const supplied = agent_types.generateSessionId();
    const supplied_start_id = try client.sendAgentStartWithSession(supplied, "{}", null);
    var supplied_started = agent_types.Envelope{
        .session_id = supplied,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .in_reply_to = supplied_start_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = supplied } },
    };
    defer supplied_started.deinit(allocator);
    try client.processEnvelope(supplied_started);
    _ = try client.sendAgentMessage(supplied, "{\"m\":1}", null);
    const supplied_writes = harness.writes.items.len;
    try std.testing.expect((try client.sendAgentStopProbing(supplied, "timeout")) == null);
    try std.testing.expectEqual(supplied_writes, harness.writes.items.len);

    const generated = try admitExclusiveSession(&harness);
    _ = try client.sendAgentMessage(generated, "{\"m\":1}", null);
    try std.testing.expect((try client.sendAgentStopProbing(generated, "timeout")) != null);
}

test "AgentProtocolClient exclusive caller-supplied start admits the session (#210 gap 7)" {
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = agent_types.generateSessionId();
    const start_id = try client.sendAgentStartWithSessionExclusive(sid, "{}", null);
    var started = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .in_reply_to = start_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_started = .{ .session_id = sid } },
    };
    defer started.deinit(std.testing.allocator);
    try client.processEnvelope(started);
    try std.testing.expect(client.isSessionAdmitted(sid));

    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    try std.testing.expect((try client.sendAgentStopProbing(sid, "timeout")) != null);
}

test "AgentProtocolClient stop probe requires a recorded message send (#210 gap 7)" {
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = try admitExclusiveSession(&harness);
    const writes_before = harness.writes.items.len;
    try std.testing.expect((try client.sendAgentStopProbing(sid, "timeout")) == null);
    try std.testing.expectEqual(writes_before, harness.writes.items.len);
    try std.testing.expect(!client.hasActiveStopProbe(sid));
}

test "AgentProtocolClient stop probe drops control state but defers completion on a gone session (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = try admitExclusiveSession(&harness);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    const probe_id = (try client.sendAgentStopProbing(sid, "timeout")).?;

    var gone = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = probe_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .agent_not_found, .message = try allocator.dupe(u8, "session not found") } },
    };
    defer gone.deinit(allocator);
    try client.processEnvelope(gone);

    try std.testing.expectEqual(@as(usize, 3), harness.writes.items.len);
    try std.testing.expect(!client.hasActiveStopProbe(sid));
    try std.testing.expect(!client.pending_sends_by_session.contains(sid));
    try std.testing.expect(!client.isSessionAdmitted(sid));
    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));
    try std.testing.expect(!client.isSessionComplete(sid));
}

test "AgentProtocolClient stop probe floor rides above the proven floor (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = try admitExclusiveSession(&harness);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 3);

    var settlement = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 4,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer settlement.deinit(allocator);
    try client.processEnvelope(settlement);

    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":2}", null, 2);

    const probe_id = (try client.sendAgentStopProbing(sid, "timeout")).?;
    var first_stop = try harness.envelopeAt(harness.writes.items.len - 1);
    defer first_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 4), first_stop.sequence);

    try rejectCorrelatedWithInvalidRequest(allocator, client, sid, probe_id);
    try std.testing.expect(!client.hasActiveStopProbe(sid));
    try std.testing.expectEqual(@as(usize, 4), harness.writes.items.len);
}

test "AgentProtocolClient delayed agent_stopped for another request preserves the active probe (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = try admitExclusiveSession(&harness);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    const probe_id = (try client.sendAgentStopProbing(sid, "timeout")).?;

    var stale = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 9,
        .in_reply_to = agent_types.generateUlid(),
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_stopped = .{ .session_id = sid } },
    };
    defer stale.deinit(allocator);
    try client.processEnvelope(stale);

    try std.testing.expect(client.hasActiveStopProbe(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));

    var own = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .in_reply_to = probe_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_stopped = .{ .session_id = sid } },
    };
    defer own.deinit(allocator);
    try client.processEnvelope(own);

    try std.testing.expect(!client.hasActiveStopProbe(sid));
    try std.testing.expectEqual(@as(u64, 1), client.peekNextSequence(sid));
}

test "AgentProtocolClient a second probe request reuses the in-flight probe (#210 gap 7)" {
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = try admitExclusiveSession(&harness);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    const first = (try client.sendAgentStopProbing(sid, "timeout")).?;
    const writes_before = harness.writes.items.len;
    const second = (try client.sendAgentStopProbing(sid, "timeout")).?;
    try std.testing.expectEqualSlices(u8, &first, &second);
    try std.testing.expectEqual(writes_before, harness.writes.items.len);
}

test "AgentProtocolClient stop probe floor includes the minimum pre-send tracker (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = try admitExclusiveSession(&harness);
    _ = try client.sendAgentMessageWithSequence(sid, "{\"m\":1}", null, 999);

    const first_id = (try client.sendAgentStopProbing(sid, "timeout")).?;
    var first_stop = try harness.envelopeAt(harness.writes.items.len - 1);
    defer first_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), first_stop.sequence);

    try rejectCorrelatedWithInvalidRequest(allocator, client, sid, first_id);
    var retry_stop = try harness.envelopeAt(harness.writes.items.len - 1);
    defer retry_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1000), retry_stop.sequence);

    try rejectCorrelatedWithInvalidRequest(allocator, client, sid, retry_stop.message_id);
    try std.testing.expect(!client.hasActiveStopProbe(sid));
    try std.testing.expectEqual(@as(usize, 4), harness.writes.items.len);
}

test "AgentProtocolClient stop probe sweeps one-past each unresolved message (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = try admitExclusiveSession(&harness);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    _ = try client.sendAgentMessage(sid, "{\"m\":2}", null);

    const first_id = (try client.sendAgentStopProbing(sid, "timeout")).?;
    var first_stop = try harness.envelopeAt(3);
    defer first_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), first_stop.sequence);

    try rejectCorrelatedWithInvalidRequest(allocator, client, sid, first_id);
    var second_stop = try harness.envelopeAt(4);
    defer second_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), second_stop.sequence);

    try rejectCorrelatedWithInvalidRequest(allocator, client, sid, second_stop.message_id);
    var third_stop = try harness.envelopeAt(5);
    defer third_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 4), third_stop.sequence);

    try rejectCorrelatedWithInvalidRequest(allocator, client, sid, third_stop.message_id);
    try std.testing.expectEqual(@as(usize, 6), harness.writes.items.len);
    try std.testing.expect(!client.hasActiveStopProbe(sid));
}

const FailingWriteSender = struct {
    attempts: usize = 0,

    fn writeFn(ctx: *anyopaque, _: []const u8) !void {
        const self: *FailingWriteSender = @ptrCast(@alignCast(ctx));
        self.attempts += 1;
        return error.WriteFailed;
    }

    fn flushFn(_: *anyopaque) !void {}
};

fn failingSender(state: *FailingWriteSender) transport.AsyncSender {
    return .{
        .context = @ptrCast(state),
        .write_fn = FailingWriteSender.writeFn,
        .flush_fn = FailingWriteSender.flushFn,
    };
}

test "AgentProtocolClient stop probe write failure retires the probe and stays retryable (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = try admitExclusiveSession(&harness);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    const writes_before = harness.writes.items.len;

    var failing = FailingWriteSender{};
    client.setSender(failingSender(&failing));
    try std.testing.expectError(error.WriteFailed, client.sendAgentStopProbing(sid, "timeout"));
    try std.testing.expectEqual(@as(usize, 1), failing.attempts);
    try std.testing.expect(!client.hasActiveStopProbe(sid));
    try std.testing.expectEqual(writes_before, harness.writes.items.len);

    harness.wire();
    _ = (try client.sendAgentStopProbing(sid, "timeout")).?;
    try std.testing.expect(client.hasActiveStopProbe(sid));
    try std.testing.expectEqual(writes_before + 1, harness.writes.items.len);
    var stop_env = try harness.envelopeAt(harness.writes.items.len - 1);
    defer stop_env.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), stop_env.sequence);
}

test "AgentProtocolClient rejected probe retry keeps the probe when the retry cannot be serialized (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = try admitExclusiveSession(&harness);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    const probe_id = (try client.sendAgentStopProbing(sid, "timeout")).?;
    const writes_before = harness.writes.items.len;

    var rejection = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = probe_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer rejection.deinit(allocator);

    client.sender = null;
    try std.testing.expectError(error.NoSender, client.processEnvelope(rejection));
    try std.testing.expect(client.hasActiveStopProbe(sid));
    try std.testing.expectEqual(writes_before, harness.writes.items.len);

    harness.wire();
    try client.processEnvelope(rejection);
    try std.testing.expectEqual(writes_before + 1, harness.writes.items.len);
    var retry_stop = try harness.envelopeAt(harness.writes.items.len - 1);
    defer retry_stop.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), retry_stop.sequence);
}

test "AgentProtocolClient stop probe retry write failure retires the probe and surfaces the error (#210 gap 7)" {
    const allocator = std.testing.allocator;
    var harness = Gap7Harness.init();
    defer harness.deinit();
    harness.wire();
    const client = &harness.client;

    const sid = try admitExclusiveSession(&harness);
    _ = try client.sendAgentMessage(sid, "{\"m\":1}", null);
    const probe_id = (try client.sendAgentStopProbing(sid, "timeout")).?;

    var failing = FailingWriteSender{};
    client.setSender(failingSender(&failing));

    var rejection = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 0,
        .in_reply_to = probe_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_error = .{ .code = .invalid_request, .message = try allocator.dupe(u8, "invalid sequence") } },
    };
    defer rejection.deinit(allocator);
    try std.testing.expectError(error.WriteFailed, client.processEnvelope(rejection));
    try std.testing.expectEqual(@as(usize, 1), failing.attempts);
    try std.testing.expect(!client.hasActiveStopProbe(sid));
    try std.testing.expectEqual(@as(u64, 3), client.peekNextSequence(sid));
}
