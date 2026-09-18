const std = @import("std");
const compat = @import("compat");
const protocol_types = @import("protocol_types");
const oap_types = @import("oap_types");
const oap_envelope = @import("oap_envelope");
const json_writer = @import("json_writer");
const model_ref = @import("model_ref");

pub const ENDPOINT_ID = "makai.agent-control";
pub const ENDPOINT_NAME = "Makai";
pub const CAPABILITY_REVISION = "makai-oap-core-v1";
pub const DELIVERY_RESOLUTION_IDLE = "session_idle";

pub const AdvertisedFeature = struct {
    key: []const u8,
    level: oap_types.SupportLevel,
    mode: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

pub const advertised_features = [_]AdvertisedFeature{
    .{ .key = "protocol.initialize", .level = .native },
    .{ .key = "capabilities", .level = .native },
    .{ .key = "session.open", .level = .native },
    .{ .key = "session.state", .level = .native },
    .{ .key = "session.message.submit", .level = .native },
    .{ .key = "session.message.delivery.auto", .level = .native },
    .{ .key = "run.streaming", .level = .native },
    .{ .key = "run.status", .level = .native },
    .{
        .key = "run.cancel",
        .level = .degraded,
        .reason = "cancellation is session scoped teardown; the session closes with the run",
    },
    .{ .key = "content.reasoning", .level = .native },
    .{ .key = "run.model_selection", .level = .native, .mode = "per_run" },
};

pub const advertised_degradation = [_]oap_types.Degradation{
    .{
        .feature = "run.cancel",
        .from = .native,
        .to = .degraded,
        .reason = "makai has no run targeted cancel; the native agent_stop tears the whole session down, so a cancelled run also closes its session",
    },
    .{
        .feature = "session.state",
        .from = .native,
        .to = .degraded,
        .reason = "makai sessions are not resumable and session_id is a correlation key, so reconnect cannot restore a run and no transcript replay is offered",
    },
};

pub const PendingSubmission = struct {
    session_id: []const u8,
    run_id: []const u8,
    submission_id: []const u8,
    model_id: []const u8,
    messages: []oap_types.Message,
    instructions: ?[]const u8,

    pub fn deinit(self: *PendingSubmission, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.run_id);
        allocator.free(self.submission_id);
        allocator.free(self.model_id);
        for (self.messages) |*message| message.deinit(allocator);
        allocator.free(self.messages);
        if (self.instructions) |value| allocator.free(value);
    }
};

pub const PendingCancel = struct {
    session_id: []const u8,
    run_id: []const u8,
    reason: ?[]const u8,

    pub fn deinit(self: *PendingCancel, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.run_id);
        if (self.reason) |value| allocator.free(value);
    }
};

const RunState = struct {
    run_id: []const u8,
    submission_id: []const u8,
    model_id: []const u8,
    message_id: ?[]const u8,
    sequence: u64,
    status: oap_types.RunStatus,
    settled: bool,
    cancel_requested: bool,
    started_emitted: bool,
    started_at_ms: i64,
    usage: oap_types.Usage,

    fn deinit(self: *RunState, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.submission_id);
        allocator.free(self.model_id);
        if (self.message_id) |value| allocator.free(value);
    }
};

const SessionEntry = struct {
    session_id: []const u8,
    status: oap_types.SessionStatus,
    sequence: u64,
    current_model_id: ?[]const u8,
    updated_at_ms: i64,
    run: ?RunState,

    fn deinit(self: *SessionEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        if (self.current_model_id) |value| allocator.free(value);
        if (self.run) |*run| run.deinit(allocator);
    }
};

pub const Server = struct {
    pub const Options = struct {
        endpoint_version: []const u8 = "dev",
        default_model_id: ?[]const u8 = null,
        session_idle_ttl_ms: u64 = DEFAULT_SESSION_IDLE_TTL_MS,
    };

    pub const DEFAULT_SESSION_IDLE_TTL_MS: u64 = 30 * 60 * 1000;

    allocator: std.mem.Allocator,
    endpoint_version: []const u8,
    default_model_id: ?[]const u8,
    initialized: bool = false,
    session_idle_ttl_ms: u64,
    sessions: std.StringHashMap(SessionEntry),
    evicted: std.ArrayList([]const u8),
    outbound: std.ArrayList([]const u8),
    pending_submissions: std.ArrayList(PendingSubmission),
    pending_cancels: std.ArrayList(PendingCancel),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, options: Options) !Self {
        const endpoint_version = try allocator.dupe(u8, options.endpoint_version);
        errdefer allocator.free(endpoint_version);
        const default_model_id = if (options.default_model_id) |value|
            try allocator.dupe(u8, value)
        else
            null;
        return .{
            .allocator = allocator,
            .endpoint_version = endpoint_version,
            .default_model_id = default_model_id,
            .session_idle_ttl_ms = options.session_idle_ttl_ms,
            .sessions = std.StringHashMap(SessionEntry).init(allocator),
            .evicted = std.ArrayList([]const u8).empty,
            .outbound = std.ArrayList([]const u8).empty,
            .pending_submissions = std.ArrayList(PendingSubmission).empty,
            .pending_cancels = std.ArrayList(PendingCancel).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.sessions.deinit();

        for (self.evicted.items) |id| self.allocator.free(id);
        self.evicted.deinit(self.allocator);

        for (self.outbound.items) |line| self.allocator.free(line);
        self.outbound.deinit(self.allocator);

        for (self.pending_submissions.items) |*item| item.deinit(self.allocator);
        self.pending_submissions.deinit(self.allocator);

        for (self.pending_cancels.items) |*item| item.deinit(self.allocator);
        self.pending_cancels.deinit(self.allocator);

        self.allocator.free(self.endpoint_version);
        if (self.default_model_id) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn popEvictedSession(self: *Self) ?[]const u8 {
        if (self.evicted.items.len == 0) return null;
        return self.evicted.orderedRemove(0);
    }

    fn sweepIdleSessions(self: *Self) !void {
        if (self.session_idle_ttl_ms == 0) return;
        if (self.sessions.count() == 0) return;

        const now = compat.time.nowMillis();
        const ttl: i64 = @intCast(@min(self.session_idle_ttl_ms, @as(u64, std.math.maxInt(i64))));

        var stale = std.ArrayList([]const u8).empty;
        defer stale.deinit(self.allocator);

        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.run) |run| {
                if (!run.settled) continue;
            }
            if (now -| entry.value_ptr.updated_at_ms < ttl) continue;
            try stale.append(self.allocator, entry.key_ptr.*);
        }

        for (stale.items) |key| {
            try self.evicted.ensureUnusedCapacity(self.allocator, 1);
            const kv = self.sessions.fetchRemove(key) orelse continue;
            var value = kv.value;
            value.deinit(self.allocator);
            self.evicted.appendAssumeCapacity(kv.key);
        }
    }

    pub fn popOutbound(self: *Self) ?[]const u8 {
        if (self.outbound.items.len == 0) return null;
        return self.outbound.orderedRemove(0);
    }

    pub fn popPendingSubmission(self: *Self) ?PendingSubmission {
        if (self.pending_submissions.items.len == 0) return null;
        return self.pending_submissions.orderedRemove(0);
    }

    pub fn popPendingCancel(self: *Self) ?PendingCancel {
        if (self.pending_cancels.items.len == 0) return null;
        return self.pending_cancels.orderedRemove(0);
    }

    pub fn hasActiveRun(self: *Self) bool {
        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.run) |run| {
                if (!run.settled) return true;
            }
        }
        return false;
    }

    pub fn appendActiveRunSessionIds(
        self: *Self,
        allocator: std.mem.Allocator,
        out: *std.ArrayList([]const u8),
    ) !void {
        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            const run = entry.value_ptr.run orelse continue;
            if (run.settled) continue;
            try out.append(allocator, entry.key_ptr.*);
        }
    }

    pub fn activeRunId(self: *Self, session_id: []const u8) ?[]const u8 {
        const entry = self.sessions.getPtr(session_id) orelse return null;
        const run = entry.run orelse return null;
        if (run.settled) return null;
        return run.run_id;
    }

    fn pushEnvelope(self: *Self, env: oap_types.Envelope) !void {
        const line = try oap_envelope.serializeEnvelope(env, self.allocator);
        errdefer self.allocator.free(line);
        try self.outbound.append(self.allocator, line);
        var owned = env;
        owned.deinit(self.allocator);
    }

    fn newUlidString(self: *Self) ![]const u8 {
        const ulid = protocol_types.generateUlid();
        return protocol_types.ulidToString(ulid, self.allocator);
    }

    pub fn handleLine(self: *Self, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch |err| {
            if (err == error.OutOfMemory) return err;
            return error.MalformedLine;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.MalformedLine;

        if (parsed.value.object.get("protocol") == null) {
            const control = parsed.value.object.get("control") orelse return error.MalformedLine;
            if (control != .string) return error.MalformedLine;
            const id = blk: {
                const value = parsed.value.object.get("id") orelse break :blk null;
                if (value != .string) break :blk null;
                break :blk value.string;
            };
            try self.pushUnsupportedControl(control.string, id);
            return;
        }

        const declared_id = blk: {
            const value = parsed.value.object.get("id") orelse break :blk null;
            if (value != .string) break :blk null;
            if (value.string.len == 0) break :blk null;
            break :blk value.string;
        } orelse return error.UnaddressableEnvelope;

        var env = oap_envelope.deserializeEnvelope(line, self.allocator) catch |err| {
            try self.emitDecodeError(err, declared_id);
            return;
        };
        defer env.deinit(self.allocator);
        try self.handleEnvelope(env);
    }

    fn pushUnsupportedControl(self: *Self, control: []const u8, id: ?[]const u8) !void {
        const name = try std.fmt.allocPrint(self.allocator, "{s}.error", .{control});
        defer self.allocator.free(name);

        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.allocator);
        var w = json_writer.JsonWriter.init(&buffer, self.allocator);
        try w.beginObject();
        try w.writeStringField("control", name);
        if (id) |value| try w.writeStringField("id", value);
        try w.writeStringField("code", "unsupported_control");
        try w.writeStringField("message", "this endpoint implements no transport controls");
        try w.endObject();

        const line = try self.allocator.dupe(u8, buffer.items);
        errdefer self.allocator.free(line);
        try self.outbound.append(self.allocator, line);
    }

    fn emitDecodeError(self: *Self, err: anyerror, in_reply_to: ?[]const u8) !void {
        const message = switch (err) {
            oap_envelope.DecodeError.ProtocolMismatch => "envelope protocol is not open-agent-protocol",
            oap_envelope.DecodeError.VersionMismatch => "envelope version is not 0.1",
            oap_envelope.DecodeError.ProfileMismatch => "envelope profile is not the agent-control core",
            oap_envelope.DecodeError.UnknownEnvelopeType => "envelope type is outside the agent-control core",
            oap_envelope.DecodeError.MissingField => "envelope is missing a required field",
            oap_envelope.DecodeError.InvalidField => "envelope carries an invalid field",
            else => "envelope is not a well formed agent-control core frame",
        };
        const code: oap_types.ErrorCode = switch (err) {
            oap_envelope.DecodeError.UnknownEnvelopeType => .unsupported_feature,
            else => .invalid_request,
        };
        try self.pushError(in_reply_to, null, null, code, message, &.{});
    }

    pub fn handleEnvelope(self: *Self, env: oap_types.Envelope) !void {
        switch (env.payload) {
            .initialize_request => |payload| return self.handleInitialize(env, payload),
            .capabilities_request => return self.handleCapabilities(env),
            else => {},
        }

        if (try self.rejectStaleRevision(env)) return;

        try self.sweepIdleSessions();

        switch (env.payload) {
            .session_open_request => |payload| try self.handleSessionOpen(env, payload),
            .session_state_request => |payload| try self.handleSessionState(env, payload),
            .message_submit_request => |payload| try self.handleSubmit(env, payload),
            .run_cancel_request => |payload| try self.handleCancel(env, payload),
            else => try self.pushError(
                env.id,
                env.session_id,
                null,
                .unsupported_feature,
                "this endpoint answers agent-control core requests only",
                &.{
                    .{ .key = "feature", .value = env.payload.typeName() },
                    .{ .key = "reason", .value = "unadvertised" },
                },
            ),
        }
    }

    fn rejectStaleRevision(self: *Self, env: oap_types.Envelope) !bool {
        const supplied = env.capability_revision orelse return false;
        if (std.mem.eql(u8, supplied, CAPABILITY_REVISION)) return false;
        try self.pushError(
            env.id,
            env.session_id,
            null,
            .stale_capabilities,
            "request pinned a capability revision this endpoint no longer serves",
            &.{
                .{ .key = "expected_revision", .value = supplied },
                .{ .key = "current_revision", .value = CAPABILITY_REVISION },
            },
        );
        return true;
    }

    fn handleInitialize(self: *Self, env: oap_types.Envelope, payload: oap_types.InitializeRequest) !void {
        if (!containsString(payload.protocol_versions, oap_types.VERSION) or
            !containsString(payload.profiles, oap_types.PROFILE))
        {
            try self.pushError(
                env.id,
                null,
                null,
                .unsupported_feature,
                "this endpoint serves open-agent-protocol 0.1 agent-control-core only",
                &.{
                    .{ .key = "feature", .value = "protocol.initialize" },
                    .{ .key = "reason", .value = "unsatisfiable" },
                },
            );
            return;
        }

        self.initialized = true;

        const id = try self.newUlidString();
        errdefer self.allocator.free(id);
        const in_reply_to = try self.allocator.dupe(u8, env.id);
        errdefer self.allocator.free(in_reply_to);
        const revision = try self.allocator.dupe(u8, CAPABILITY_REVISION);
        errdefer self.allocator.free(revision);
        const protocol_version = try self.allocator.dupe(u8, oap_types.VERSION);
        errdefer self.allocator.free(protocol_version);
        const profile = try self.allocator.dupe(u8, oap_types.PROFILE);
        errdefer self.allocator.free(profile);
        const endpoint_id = try self.allocator.dupe(u8, ENDPOINT_ID);
        errdefer self.allocator.free(endpoint_id);
        const endpoint_name = try self.allocator.dupe(u8, ENDPOINT_NAME);
        errdefer self.allocator.free(endpoint_name);
        const endpoint_version = try self.allocator.dupe(u8, self.endpoint_version);
        errdefer self.allocator.free(endpoint_version);

        try self.pushEnvelope(.{
            .id = id,
            .in_reply_to = in_reply_to,
            .capability_revision = revision,
            .timestamp_ms = compat.time.nowMillis(),
            .payload = .{ .initialize_response = .{
                .protocol_version = protocol_version,
                .profile = profile,
                .endpoint = .{
                    .id = endpoint_id,
                    .name = endpoint_name,
                    .version = endpoint_version,
                },
            } },
        });
    }

    fn handleCapabilities(self: *Self, env: oap_types.Envelope) !void {
        const id = try self.newUlidString();
        errdefer self.allocator.free(id);
        const in_reply_to = try self.allocator.dupe(u8, env.id);
        errdefer self.allocator.free(in_reply_to);
        const revision = try self.allocator.dupe(u8, CAPABILITY_REVISION);
        errdefer self.allocator.free(revision);

        var capabilities = try self.buildCapabilities();
        errdefer capabilities.deinit(self.allocator);

        try self.pushEnvelope(.{
            .id = id,
            .in_reply_to = in_reply_to,
            .capability_revision = revision,
            .timestamp_ms = compat.time.nowMillis(),
            .payload = .{ .capabilities_response = capabilities },
        });
    }

    fn handleSessionOpen(self: *Self, env: oap_types.Envelope, payload: oap_types.SessionOpenRequest) !void {
        if (payload.session_id) |requested| {
            if (env.session_id) |scoped| {
                if (!std.mem.eql(u8, requested, scoped)) {
                    try self.pushError(
                        env.id,
                        env.session_id,
                        null,
                        .invalid_request,
                        "envelope and payload session_id disagree",
                        &.{},
                    );
                    return;
                }
            }
            if (self.sessions.getPtr(requested)) |existing| {
                try self.emitSessionState(env.id, existing, .open);
                return;
            }
        }

        const entry = try self.openSession(payload.session_id);
        try self.emitSessionState(env.id, entry, .open);
    }

    fn openSession(self: *Self, requested: ?[]const u8) !*SessionEntry {
        const generated = protocol_types.generateSessionId();
        const session_id = if (requested) |value|
            try self.allocator.dupe(u8, value)
        else
            try self.allocator.dupe(u8, generated[0..]);
        errdefer self.allocator.free(session_id);

        const current_model_id = if (self.default_model_id) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (current_model_id) |value| self.allocator.free(value);

        const key = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(key);

        try self.sessions.put(key, .{
            .session_id = session_id,
            .status = .idle,
            .sequence = 0,
            .current_model_id = current_model_id,
            .updated_at_ms = compat.time.nowMillis(),
            .run = null,
        });

        return self.sessions.getPtr(key).?;
    }

    fn refuseScopeDisagreement(
        self: *Self,
        env: oap_types.Envelope,
        session_id: []const u8,
        run_id: ?[]const u8,
    ) !bool {
        if (env.session_id) |scoped| {
            if (!std.mem.eql(u8, scoped, session_id)) {
                try self.pushError(
                    env.id,
                    env.session_id,
                    env.run_id,
                    .invalid_request,
                    "envelope and payload session_id disagree",
                    &.{},
                );
                return true;
            }
        }
        if (run_id) |payload_run| {
            if (env.run_id) |scoped| {
                if (!std.mem.eql(u8, scoped, payload_run)) {
                    try self.pushError(
                        env.id,
                        env.session_id,
                        env.run_id,
                        .invalid_request,
                        "envelope and payload run_id disagree",
                        &.{},
                    );
                    return true;
                }
            }
        }
        return false;
    }

    fn handleSessionState(self: *Self, env: oap_types.Envelope, payload: oap_types.SessionStateRequest) !void {
        if (try self.refuseScopeDisagreement(env, payload.session_id, null)) return;
        const entry = self.sessions.getPtr(payload.session_id) orelse {
            try self.pushError(
                env.id,
                env.session_id,
                null,
                .session_not_found,
                "session is not open on this endpoint",
                &.{},
            );
            return;
        };
        try self.emitSessionState(env.id, entry, .state);
    }

    const StateKind = enum { open, state };

    fn emitSessionState(self: *Self, request_id: []const u8, entry: *SessionEntry, kind: StateKind) !void {
        const id = try self.newUlidString();
        errdefer self.allocator.free(id);
        const in_reply_to = try self.allocator.dupe(u8, request_id);
        errdefer self.allocator.free(in_reply_to);
        const scope_id = try self.allocator.dupe(u8, entry.session_id);
        errdefer self.allocator.free(scope_id);
        const revision = try self.allocator.dupe(u8, CAPABILITY_REVISION);
        errdefer self.allocator.free(revision);

        const payload_session = try self.allocator.dupe(u8, entry.session_id);
        errdefer self.allocator.free(payload_session);
        const active_run_id = try self.dupeActiveRunId(entry);
        errdefer if (active_run_id) |value| self.allocator.free(value);
        const current_model_id = if (entry.current_model_id) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (current_model_id) |value| self.allocator.free(value);

        const state = oap_types.SessionState{
            .session_id = payload_session,
            .status = entry.status,
            .active_run_id = active_run_id,
            .current_model_id = current_model_id,
            .updated_at_ms = entry.updated_at_ms,
        };

        try self.pushEnvelope(.{
            .id = id,
            .in_reply_to = in_reply_to,
            .session_id = scope_id,
            .capability_revision = revision,
            .timestamp_ms = compat.time.nowMillis(),
            .payload = switch (kind) {
                .open => .{ .session_open_response = state },
                .state => .{ .session_state_response = state },
            },
        });
    }

    fn dupeActiveRunId(self: *Self, entry: *SessionEntry) !?[]const u8 {
        const run = entry.run orelse return null;
        if (run.settled) return null;
        return try self.allocator.dupe(u8, run.run_id);
    }

    fn publishSessionState(self: *Self, entry: *SessionEntry) !void {
        const sequence = entry.sequence + 1;

        const id = try self.newUlidString();
        errdefer self.allocator.free(id);
        const scope_id = try self.allocator.dupe(u8, entry.session_id);
        errdefer self.allocator.free(scope_id);
        const payload_session = try self.allocator.dupe(u8, entry.session_id);
        errdefer self.allocator.free(payload_session);
        const active_run_id = try self.dupeActiveRunId(entry);
        errdefer if (active_run_id) |value| self.allocator.free(value);
        const current_model_id = if (entry.current_model_id) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (current_model_id) |value| self.allocator.free(value);

        try self.pushEnvelope(.{
            .id = id,
            .session_id = scope_id,
            .sequence = sequence,
            .timestamp_ms = compat.time.nowMillis(),
            .payload = .{ .session_state_updated = .{
                .session_id = payload_session,
                .status = entry.status,
                .active_run_id = active_run_id,
                .current_model_id = current_model_id,
                .updated_at_ms = entry.updated_at_ms,
            } },
        });

        entry.sequence = sequence;
    }

    fn handleSubmit(self: *Self, env: oap_types.Envelope, payload: oap_types.MessageSubmitRequest) !void {
        if (try self.refuseScopeDisagreement(env, payload.session_id, null)) return;

        if (try self.refuseRunControls(env, payload)) return;
        if (try self.refuseUnsupportedContent(env, payload)) return;

        if (payload.delivery != .auto) {
            const key = switch (payload.delivery) {
                .queue => "session.message.delivery.queue",
                .steer => "session.message.delivery.steer",
                .btw => "session.message.delivery.btw",
                .auto => unreachable,
            };
            try self.pushError(
                env.id,
                env.session_id,
                null,
                .unsupported_feature,
                "this endpoint resolves auto delivery only",
                &.{
                    .{ .key = "feature", .value = key },
                    .{ .key = "reason", .value = "unadvertised" },
                },
            );
            return;
        }

        const entry = self.sessions.getPtr(payload.session_id) orelse {
            try self.pushError(
                env.id,
                env.session_id,
                null,
                .session_not_found,
                "session is not open on this endpoint",
                &.{},
            );
            return;
        };

        if (entry.status == .closed) {
            try self.pushError(
                env.id,
                env.session_id,
                null,
                .session_not_found,
                "the session closed with a cancelled run and cannot admit further work",
                &.{},
            );
            return;
        }

        if (entry.run) |run| {
            if (!run.settled) {
                try self.pushError(
                    env.id,
                    env.session_id,
                    null,
                    .session_busy,
                    "this endpoint admits one foreground run per session",
                    &.{},
                );
                return;
            }
        }

        const effective_model = blk: {
            if (payload.model_id) |requested| break :blk requested;
            break :blk entry.current_model_id;
        };
        if (effective_model == null) {
            try self.pushError(
                env.id,
                env.session_id,
                null,
                .model_not_found,
                "no model is configured for this session and the submission named none",
                &.{.{ .key = "model_id", .value = "" }},
            );
            return;
        }

        if (model_ref.parseModelRef(self.allocator, effective_model.?)) |parsed| {
            var owned = parsed;
            owned.deinit(self.allocator);
        } else |err| {
            if (err == error.OutOfMemory) return err;
            try self.pushError(
                env.id,
                env.session_id,
                null,
                .model_not_found,
                "the selected model reference is not a valid provider_id/api@model_id",
                &.{.{ .key = "model_id", .value = effective_model.? }},
            );
            return;
        }

        try self.admitSubmission(entry, env.id, effective_model.?, payload);
        try self.emitRunStarted(entry);
        try self.publishSessionState(entry);
    }

    fn admitSubmission(
        self: *Self,
        entry: *SessionEntry,
        request_id: []const u8,
        model_id: []const u8,
        payload: oap_types.MessageSubmitRequest,
    ) !void {
        var run = try self.allocateRun(model_id);
        errdefer run.deinit(self.allocator);

        var pending = try self.buildPendingSubmission(entry.session_id, &run, payload);
        errdefer pending.deinit(self.allocator);

        try self.pending_submissions.ensureUnusedCapacity(self.allocator, 1);
        try self.emitAdmission(request_id, entry.session_id, &run);

        self.pending_submissions.appendAssumeCapacity(pending);
        if (entry.run) |*previous| previous.deinit(self.allocator);
        entry.run = run;
        entry.status = .running;
        entry.updated_at_ms = compat.time.nowMillis();
    }

    fn refuseUnsupportedContent(
        self: *Self,
        env: oap_types.Envelope,
        payload: oap_types.MessageSubmitRequest,
    ) !bool {
        for (payload.messages) |message| {
            const parts = switch (message.content) {
                .text => continue,
                .parts => |items| items,
            };
            for (parts) |part| {
                const key = switch (part) {
                    .text => continue,
                    .reasoning => "session.message.content.reasoning",
                    .tool_call => "session.message.content.tool_call",
                    .tool_result => "session.message.content.tool_result",
                };
                try self.pushError(
                    env.id,
                    env.session_id,
                    null,
                    .unsupported_feature,
                    "this endpoint forwards text content only",
                    &.{
                        .{ .key = "feature", .value = key },
                        .{ .key = "reason", .value = "unadvertised" },
                    },
                );
                return true;
            }
        }
        return false;
    }

    fn refuseRunControls(self: *Self, env: oap_types.Envelope, payload: oap_types.MessageSubmitRequest) !bool {
        const ordered = [_]oap_types.RunControl{ .model_id, .instructions, .tool_choice, .output_schema };
        for (ordered) |control| {
            const supplied = payload.control(control) orelse continue;
            const key = control.capabilityKey();
            const feature = findFeature(key);
            if (feature == null or feature.?.level == .unavailable) {
                try self.pushError(
                    env.id,
                    env.session_id,
                    null,
                    .unsupported_feature,
                    "this endpoint has not advertised that run control",
                    &.{
                        .{ .key = "feature", .value = key },
                        .{ .key = "reason", .value = "unadvertised" },
                    },
                );
                return true;
            }
            if (feature.?.level == .degraded and !payload.allowsDegraded(key)) {
                try self.pushError(
                    env.id,
                    env.session_id,
                    null,
                    .capability_degraded,
                    "that run control is degraded and the submission did not opt in",
                    &.{.{ .key = "feature", .value = key }},
                );
                return true;
            }
            if (control == .model_id and supplied.len == 0) {
                try self.pushError(
                    env.id,
                    env.session_id,
                    null,
                    .model_not_found,
                    "the empty model id is not servable",
                    &.{.{ .key = "model_id", .value = "" }},
                );
                return true;
            }
        }
        return false;
    }

    fn allocateRun(self: *Self, model_id: []const u8) !RunState {
        const run_id = try self.newUlidString();
        errdefer self.allocator.free(run_id);
        const submission_id = try self.newUlidString();
        errdefer self.allocator.free(submission_id);
        const owned_model = try self.allocator.dupe(u8, model_id);
        return .{
            .run_id = run_id,
            .submission_id = submission_id,
            .model_id = owned_model,
            .message_id = null,
            .sequence = 0,
            .status = .running,
            .settled = false,
            .cancel_requested = false,
            .started_emitted = false,
            .started_at_ms = compat.time.nowMillis(),
            .usage = .{},
        };
    }

    fn buildPendingSubmission(
        self: *Self,
        session_id: []const u8,
        run: *const RunState,
        payload: oap_types.MessageSubmitRequest,
    ) !PendingSubmission {
        const owned_session = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(owned_session);
        const owned_run = try self.allocator.dupe(u8, run.run_id);
        errdefer self.allocator.free(owned_run);
        const owned_submission = try self.allocator.dupe(u8, run.submission_id);
        errdefer self.allocator.free(owned_submission);
        const owned_model = try self.allocator.dupe(u8, run.model_id);
        errdefer self.allocator.free(owned_model);
        const messages = try cloneMessages(self.allocator, payload.messages);
        errdefer {
            for (messages) |*message| message.deinit(self.allocator);
            self.allocator.free(messages);
        }
        const instructions = if (payload.instructions) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        return .{
            .session_id = owned_session,
            .run_id = owned_run,
            .submission_id = owned_submission,
            .model_id = owned_model,
            .messages = messages,
            .instructions = instructions,
        };
    }

    fn emitAdmission(self: *Self, request_id: []const u8, session_id: []const u8, run: *const RunState) !void {
        const id = try self.newUlidString();
        errdefer self.allocator.free(id);
        const in_reply_to = try self.allocator.dupe(u8, request_id);
        errdefer self.allocator.free(in_reply_to);
        const scope_id = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(scope_id);
        const revision = try self.allocator.dupe(u8, CAPABILITY_REVISION);
        errdefer self.allocator.free(revision);
        const payload_session = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(payload_session);
        const submission_id = try self.allocator.dupe(u8, run.submission_id);
        errdefer self.allocator.free(submission_id);
        const run_id = try self.allocator.dupe(u8, run.run_id);
        errdefer self.allocator.free(run_id);
        const model_id = try self.allocator.dupe(u8, run.model_id);
        errdefer self.allocator.free(model_id);
        const resolution = try self.allocator.dupe(u8, DELIVERY_RESOLUTION_IDLE);
        errdefer self.allocator.free(resolution);

        try self.pushEnvelope(.{
            .id = id,
            .in_reply_to = in_reply_to,
            .session_id = scope_id,
            .capability_revision = revision,
            .timestamp_ms = compat.time.nowMillis(),
            .payload = .{ .message_submit_response = .{
                .session_id = payload_session,
                .accepted = true,
                .submission_id = submission_id,
                .requested_delivery = .auto,
                .effective_delivery = .start,
                .delivery_resolution = resolution,
                .admission = .started,
                .run_id = run_id,
                .status = .running,
                .model_id = model_id,
            } },
        });
    }

    fn emitRunStarted(self: *Self, entry: *SessionEntry) !void {
        const run = &entry.run.?;
        if (run.started_emitted) return;
        const sequence = run.sequence + 1;

        const id = try self.newUlidString();
        errdefer self.allocator.free(id);
        const scope_session = try self.allocator.dupe(u8, entry.session_id);
        errdefer self.allocator.free(scope_session);
        const scope_run = try self.allocator.dupe(u8, run.run_id);
        errdefer self.allocator.free(scope_run);
        const payload_session = try self.allocator.dupe(u8, entry.session_id);
        errdefer self.allocator.free(payload_session);
        const payload_run = try self.allocator.dupe(u8, run.run_id);
        errdefer self.allocator.free(payload_run);
        const model_id = try self.allocator.dupe(u8, run.model_id);
        errdefer self.allocator.free(model_id);

        try self.pushEnvelope(.{
            .id = id,
            .session_id = scope_session,
            .run_id = scope_run,
            .sequence = sequence,
            .timestamp_ms = compat.time.nowMillis(),
            .payload = .{ .run_started = .{
                .session_id = payload_session,
                .run_id = payload_run,
                .model_id = model_id,
                .started_at_ms = run.started_at_ms,
            } },
        });

        run.sequence = sequence;
        run.started_emitted = true;
    }

    fn handleCancel(self: *Self, env: oap_types.Envelope, payload: oap_types.RunCancelRequest) !void {
        if (try self.refuseScopeDisagreement(env, payload.session_id, payload.run_id)) return;

        const entry = self.sessions.getPtr(payload.session_id) orelse {
            try self.pushError(
                env.id,
                env.session_id,
                env.run_id,
                .session_not_found,
                "session is not open on this endpoint",
                &.{},
            );
            return;
        };

        const run = if (entry.run) |*candidate| candidate else {
            try self.pushError(
                env.id,
                env.session_id,
                env.run_id,
                .run_not_found,
                "no run with that id is known to this session",
                &.{},
            );
            return;
        };

        if (!std.mem.eql(u8, run.run_id, payload.run_id)) {
            try self.pushError(
                env.id,
                env.session_id,
                env.run_id,
                .run_not_found,
                "no run with that id is known to this session",
                &.{},
            );
            return;
        }

        if (run.settled) {
            try self.pushError(
                env.id,
                env.session_id,
                env.run_id,
                .run_already_terminal,
                "the run already reached a terminal state",
                &.{},
            );
            return;
        }

        const already_cancelling = run.cancel_requested;
        if (!already_cancelling) {
            const pending = try self.buildPendingCancel(entry.session_id, run.run_id, payload.reason);
            errdefer {
                var owned = pending;
                owned.deinit(self.allocator);
            }
            try self.pending_cancels.ensureUnusedCapacity(self.allocator, 1);
            try self.emitCancelAccepted(env.id, entry.session_id, run.run_id);
            self.pending_cancels.appendAssumeCapacity(pending);
        } else {
            try self.emitCancelAccepted(env.id, entry.session_id, run.run_id);
        }

        run.cancel_requested = true;
        run.status = .cancelling;
        if (!already_cancelling) try self.emitRunStatus(entry, .cancelling);
    }

    fn buildPendingCancel(self: *Self, session_id: []const u8, run_id: []const u8, reason: ?[]const u8) !PendingCancel {
        const owned_session = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(owned_session);
        const owned_run = try self.allocator.dupe(u8, run_id);
        errdefer self.allocator.free(owned_run);
        const owned_reason = if (reason) |value| try self.allocator.dupe(u8, value) else null;
        return .{ .session_id = owned_session, .run_id = owned_run, .reason = owned_reason };
    }

    fn emitCancelAccepted(self: *Self, request_id: []const u8, session_id: []const u8, run_id: []const u8) !void {
        const id = try self.newUlidString();
        errdefer self.allocator.free(id);
        const in_reply_to = try self.allocator.dupe(u8, request_id);
        errdefer self.allocator.free(in_reply_to);
        const scope_session = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(scope_session);
        const scope_run = try self.allocator.dupe(u8, run_id);
        errdefer self.allocator.free(scope_run);
        const revision = try self.allocator.dupe(u8, CAPABILITY_REVISION);
        errdefer self.allocator.free(revision);
        const payload_session = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(payload_session);
        const payload_run = try self.allocator.dupe(u8, run_id);
        errdefer self.allocator.free(payload_run);

        try self.pushEnvelope(.{
            .id = id,
            .in_reply_to = in_reply_to,
            .session_id = scope_session,
            .run_id = scope_run,
            .capability_revision = revision,
            .timestamp_ms = compat.time.nowMillis(),
            .payload = .{ .run_cancel_response = .{
                .session_id = payload_session,
                .run_id = payload_run,
                .accepted = true,
                .status = .cancelling,
            } },
        });
    }

    fn emitRunStatus(self: *Self, entry: *SessionEntry, status: oap_types.RunStatus) !void {
        const run = &entry.run.?;
        if (run.settled or !run.started_emitted) return;
        const sequence = run.sequence + 1;

        const id = try self.newUlidString();
        errdefer self.allocator.free(id);
        const scope_session = try self.allocator.dupe(u8, entry.session_id);
        errdefer self.allocator.free(scope_session);
        const scope_run = try self.allocator.dupe(u8, run.run_id);
        errdefer self.allocator.free(scope_run);
        const payload_session = try self.allocator.dupe(u8, entry.session_id);
        errdefer self.allocator.free(payload_session);
        const payload_run = try self.allocator.dupe(u8, run.run_id);
        errdefer self.allocator.free(payload_run);

        try self.pushEnvelope(.{
            .id = id,
            .session_id = scope_session,
            .run_id = scope_run,
            .sequence = sequence,
            .timestamp_ms = compat.time.nowMillis(),
            .payload = .{ .run_status_updated = .{
                .session_id = payload_session,
                .run_id = payload_run,
                .status = status,
                .updated_at_ms = compat.time.nowMillis(),
            } },
        });

        run.sequence = sequence;
    }

    pub fn noteContent(self: *Self, session_id: []const u8, part: oap_types.ContentPart) !void {
        const entry = self.sessions.getPtr(session_id) orelse return;
        const run = if (entry.run) |*candidate| candidate else return;
        if (run.settled or !run.started_emitted) return;

        if (run.message_id == null) run.message_id = try self.newUlidString();
        const sequence = run.sequence + 1;

        const id = try self.newUlidString();
        errdefer self.allocator.free(id);
        const scope_session = try self.allocator.dupe(u8, entry.session_id);
        errdefer self.allocator.free(scope_session);
        const scope_run = try self.allocator.dupe(u8, run.run_id);
        errdefer self.allocator.free(scope_run);
        const payload_session = try self.allocator.dupe(u8, entry.session_id);
        errdefer self.allocator.free(payload_session);
        const payload_run = try self.allocator.dupe(u8, run.run_id);
        errdefer self.allocator.free(payload_run);
        const message_id = try self.allocator.dupe(u8, run.message_id.?);
        errdefer self.allocator.free(message_id);
        const owned_part = try clonePart(self.allocator, part);
        errdefer {
            var mutable = owned_part;
            mutable.deinit(self.allocator);
        }

        try self.pushEnvelope(.{
            .id = id,
            .session_id = scope_session,
            .run_id = scope_run,
            .sequence = sequence,
            .timestamp_ms = compat.time.nowMillis(),
            .payload = .{ .content_delta = .{
                .session_id = payload_session,
                .run_id = payload_run,
                .message_id = message_id,
                .part = owned_part,
            } },
        });

        run.sequence = sequence;
    }

    pub fn noteUsage(self: *Self, session_id: []const u8, usage: oap_types.Usage) void {
        const entry = self.sessions.getPtr(session_id) orelse return;
        const run = if (entry.run) |*candidate| candidate else return;
        if (run.settled) return;
        run.usage = usage;
    }

    pub fn noteMessageBoundary(self: *Self, session_id: []const u8) void {
        const entry = self.sessions.getPtr(session_id) orelse return;
        const run = if (entry.run) |*candidate| candidate else return;
        if (run.settled) return;
        if (run.message_id) |value| self.allocator.free(value);
        run.message_id = null;
    }

    pub fn settleCompleted(
        self: *Self,
        session_id: []const u8,
        final_text: []const u8,
        stop_reason: []const u8,
    ) !void {
        const entry = self.sessions.getPtr(session_id) orelse return;
        const run = if (entry.run) |*candidate| candidate else return;
        if (run.settled) return;
        if (!run.started_emitted) {
            try self.settleFailed(session_id, .internal_error, "the run completed before it was observed to start");
            return;
        }
        const sequence = run.sequence + 1;

        {
            const id = try self.newUlidString();
            errdefer self.allocator.free(id);
            const scope_session = try self.allocator.dupe(u8, entry.session_id);
            errdefer self.allocator.free(scope_session);
            const scope_run = try self.allocator.dupe(u8, run.run_id);
            errdefer self.allocator.free(scope_run);
            const payload_session = try self.allocator.dupe(u8, entry.session_id);
            errdefer self.allocator.free(payload_session);
            const payload_run = try self.allocator.dupe(u8, run.run_id);
            errdefer self.allocator.free(payload_run);
            const owned_text = try self.allocator.dupe(u8, final_text);
            errdefer self.allocator.free(owned_text);
            const owned_reason = try self.allocator.dupe(u8, stop_reason);
            errdefer self.allocator.free(owned_reason);
            const model_id = try self.allocator.dupe(u8, run.model_id);
            errdefer self.allocator.free(model_id);

            try self.pushEnvelope(.{
                .id = id,
                .session_id = scope_session,
                .run_id = scope_run,
                .sequence = sequence,
                .timestamp_ms = compat.time.nowMillis(),
                .payload = .{ .run_completed = .{
                    .session_id = payload_session,
                    .run_id = payload_run,
                    .final_response = .{ .role = .assistant, .content = .{ .text = owned_text } },
                    .stop_reason = owned_reason,
                    .model_id = model_id,
                    .usage = run.usage,
                    .duration_ms = elapsedMs(run.started_at_ms),
                } },
            });
        }

        try self.commitTerminal(entry, sequence, .completed);
    }

    pub fn settleFailed(
        self: *Self,
        session_id: []const u8,
        code: oap_types.ErrorCode,
        message: []const u8,
    ) !void {
        const entry = self.sessions.getPtr(session_id) orelse return;
        const run = if (entry.run) |*candidate| candidate else return;
        if (run.settled) return;
        const sequence = run.sequence + 1;

        {
            const id = try self.newUlidString();
            errdefer self.allocator.free(id);
            const scope_session = try self.allocator.dupe(u8, entry.session_id);
            errdefer self.allocator.free(scope_session);
            const scope_run = try self.allocator.dupe(u8, run.run_id);
            errdefer self.allocator.free(scope_run);
            const payload_session = try self.allocator.dupe(u8, entry.session_id);
            errdefer self.allocator.free(payload_session);
            const payload_run = try self.allocator.dupe(u8, run.run_id);
            errdefer self.allocator.free(payload_run);
            const owned_message = try self.allocator.dupe(u8, message);
            errdefer self.allocator.free(owned_message);

            try self.pushEnvelope(.{
                .id = id,
                .session_id = scope_session,
                .run_id = scope_run,
                .sequence = sequence,
                .timestamp_ms = compat.time.nowMillis(),
                .payload = .{ .run_failed = .{
                    .session_id = payload_session,
                    .run_id = payload_run,
                    .err = .{ .code = code, .message = owned_message, .retriable = false },
                    .usage = run.usage,
                    .duration_ms = elapsedMs(run.started_at_ms),
                } },
            });
        }

        try self.commitTerminal(entry, sequence, .failed);
    }

    pub fn settleCancelled(self: *Self, session_id: []const u8, reason: ?[]const u8) !void {
        const entry = self.sessions.getPtr(session_id) orelse return;
        const run = if (entry.run) |*candidate| candidate else return;
        if (run.settled) return;
        if (!run.cancel_requested) {
            try self.settleFailed(session_id, .internal_error, "the run stopped without an accepted cancellation");
            return;
        }
        const sequence = run.sequence + 1;

        {
            const id = try self.newUlidString();
            errdefer self.allocator.free(id);
            const scope_session = try self.allocator.dupe(u8, entry.session_id);
            errdefer self.allocator.free(scope_session);
            const scope_run = try self.allocator.dupe(u8, run.run_id);
            errdefer self.allocator.free(scope_run);
            const payload_session = try self.allocator.dupe(u8, entry.session_id);
            errdefer self.allocator.free(payload_session);
            const payload_run = try self.allocator.dupe(u8, run.run_id);
            errdefer self.allocator.free(payload_run);
            const owned_reason = if (reason) |value| try self.allocator.dupe(u8, value) else null;
            errdefer if (owned_reason) |value| self.allocator.free(value);

            try self.pushEnvelope(.{
                .id = id,
                .session_id = scope_session,
                .run_id = scope_run,
                .sequence = sequence,
                .timestamp_ms = compat.time.nowMillis(),
                .payload = .{ .run_cancelled = .{
                    .session_id = payload_session,
                    .run_id = payload_run,
                    .reason = owned_reason,
                    .usage = run.usage,
                    .duration_ms = elapsedMs(run.started_at_ms),
                } },
            });
        }

        try self.commitTerminal(entry, sequence, .cancelled);
    }

    fn commitTerminal(self: *Self, entry: *SessionEntry, sequence: u64, status: oap_types.RunStatus) !void {
        const run = &entry.run.?;
        run.sequence = sequence;
        run.settled = true;
        run.status = status;
        entry.status = if (status == .cancelled) .closed else .idle;
        entry.updated_at_ms = compat.time.nowMillis();
        try self.publishSessionState(entry);
    }

    fn pushError(
        self: *Self,
        in_reply_to: ?[]const u8,
        session_id: ?[]const u8,
        run_id: ?[]const u8,
        code: oap_types.ErrorCode,
        message: []const u8,
        details: []const oap_types.DetailEntry,
    ) !void {
        const id = try self.newUlidString();
        errdefer self.allocator.free(id);
        const owned_reply = if (in_reply_to) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_reply) |value| self.allocator.free(value);
        const owned_session = if (session_id) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_session) |value| self.allocator.free(value);
        const owned_run = if (run_id) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_run) |value| self.allocator.free(value);
        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);
        const owned_details = try cloneDetails(self.allocator, details);
        errdefer freeDetails(self.allocator, owned_details);

        try self.pushEnvelope(.{
            .id = id,
            .in_reply_to = owned_reply,
            .session_id = owned_session,
            .run_id = owned_run,
            .timestamp_ms = compat.time.nowMillis(),
            .payload = .{ .error_response = .{
                .code = code,
                .message = owned_message,
                .retriable = false,
                .details = owned_details,
            } },
        });
    }

    pub fn buildCapabilities(self: *Self) !oap_types.CapabilitiesResponse {
        var result = oap_types.CapabilitiesResponse{ .endpoint = try self.buildEndpoint() };
        errdefer result.deinit(self.allocator);

        const versions = [_][]const u8{oap_types.VERSION};
        const profiles = [_][]const u8{oap_types.PROFILE};
        result.protocol_versions = try oap_types.dupeStringList(self.allocator, &versions);
        result.profiles = try oap_types.dupeStringList(self.allocator, &profiles);
        result.bindings = try self.buildBindings();
        result.features = try self.buildFeatures();

        const requested = try self.allocator.alloc(oap_types.RequestedDelivery, 1);
        requested[0] = .auto;
        result.requested_delivery_modes = requested;
        const effective = try self.allocator.alloc(oap_types.EffectiveDelivery, 1);
        effective[0] = .start;
        result.effective_delivery_modes = effective;

        result.degradation = try self.buildDegradation();

        return result;
    }

    fn buildEndpoint(self: *Self) !oap_types.Endpoint {
        const id = try self.allocator.dupe(u8, ENDPOINT_ID);
        errdefer self.allocator.free(id);
        const name = try self.allocator.dupe(u8, ENDPOINT_NAME);
        errdefer self.allocator.free(name);
        const version = try self.allocator.dupe(u8, self.endpoint_version);
        return .{ .id = id, .name = name, .version = version };
    }

    fn buildBindings(self: *Self) ![]oap_types.Binding {
        const bindings = try self.allocator.alloc(oap_types.Binding, 1);
        var filled: usize = 0;
        errdefer {
            for (bindings[0..filled]) |*binding| binding.deinit(self.allocator);
            self.allocator.free(bindings);
        }

        const kind = try self.allocator.dupe(u8, "stdio");
        errdefer self.allocator.free(kind);
        const serialization = try self.allocator.dupe(u8, "jsonl");
        bindings[0] = .{ .kind = kind, .serialization = serialization };
        filled = 1;

        return bindings;
    }

    fn buildFeatures(self: *Self) ![]oap_types.Feature {
        const features = try self.allocator.alloc(oap_types.Feature, advertised_features.len);
        var filled: usize = 0;
        errdefer {
            for (features[0..filled]) |*entry| entry.deinit(self.allocator);
            self.allocator.free(features);
        }

        for (advertised_features, 0..) |source, index| {
            const key = try self.allocator.dupe(u8, source.key);
            errdefer self.allocator.free(key);
            const mode = if (source.mode) |value| try self.allocator.dupe(u8, value) else null;
            errdefer if (mode) |value| self.allocator.free(value);
            const reason = if (source.reason) |value| try self.allocator.dupe(u8, value) else null;
            features[index] = .{ .key = key, .level = source.level, .mode = mode, .reason = reason };
            filled = index + 1;
        }

        return features;
    }

    fn buildDegradation(self: *Self) ![]oap_types.Degradation {
        const degradation = try self.allocator.alloc(oap_types.Degradation, advertised_degradation.len);
        var filled: usize = 0;
        errdefer {
            for (degradation[0..filled]) |*record| record.deinit(self.allocator);
            self.allocator.free(degradation);
        }

        for (advertised_degradation, 0..) |source, index| {
            const feature = try self.allocator.dupe(u8, source.feature);
            errdefer self.allocator.free(feature);
            const reason = try self.allocator.dupe(u8, source.reason);
            degradation[index] = .{
                .feature = feature,
                .from = source.from,
                .to = source.to,
                .reason = reason,
            };
            filled = index + 1;
        }

        return degradation;
    }
};

fn elapsedMs(started_at_ms: i64) u64 {
    const now = compat.time.nowMillis();
    if (now <= started_at_ms) return 0;
    return @intCast(now - started_at_ms);
}

fn containsString(list: []const []const u8, needle: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, needle)) return true;
    }
    return false;
}

pub fn findFeature(key: []const u8) ?AdvertisedFeature {
    for (advertised_features) |feature| {
        if (std.mem.eql(u8, feature.key, key)) return feature;
    }
    return null;
}

fn freeDetails(allocator: std.mem.Allocator, details: []const oap_types.DetailEntry) void {
    for (details) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.value);
    }
    allocator.free(details);
}

fn cloneDetails(allocator: std.mem.Allocator, details: []const oap_types.DetailEntry) ![]const oap_types.DetailEntry {
    const out = try allocator.alloc(oap_types.DetailEntry, details.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        allocator.free(out);
    }
    for (details, 0..) |entry, index| {
        const key = try allocator.dupe(u8, entry.key);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, entry.value);
        out[index] = .{ .key = key, .value = value };
        filled = index + 1;
    }
    return out;
}

pub fn clonePart(allocator: std.mem.Allocator, part: oap_types.ContentPart) !oap_types.ContentPart {
    switch (part) {
        .text => |value| return .{ .text = try allocator.dupe(u8, value) },
        .reasoning => |value| {
            const text = try allocator.dupe(u8, value.text);
            errdefer allocator.free(text);
            const carry = if (value.carry) |raw| try allocator.dupe(u8, raw) else null;
            return .{ .reasoning = .{ .text = text, .carry = carry } };
        },
        .tool_call => |value| {
            const tool_call_id = try allocator.dupe(u8, value.tool_call_id);
            errdefer allocator.free(tool_call_id);
            const name = try allocator.dupe(u8, value.name);
            errdefer allocator.free(name);
            const arguments_json = try allocator.dupe(u8, value.arguments_json);
            errdefer allocator.free(arguments_json);
            const carry = if (value.carry) |raw| try allocator.dupe(u8, raw) else null;
            return .{ .tool_call = .{
                .tool_call_id = tool_call_id,
                .name = name,
                .arguments_json = arguments_json,
                .carry = carry,
            } };
        },
        .tool_result => |value| {
            const tool_call_id = try allocator.dupe(u8, value.tool_call_id);
            errdefer allocator.free(tool_call_id);
            const result_json = try allocator.dupe(u8, value.result_json);
            return .{ .tool_result = .{
                .tool_call_id = tool_call_id,
                .result_json = result_json,
                .is_error = value.is_error,
            } };
        },
    }
}

pub fn cloneMessages(allocator: std.mem.Allocator, messages: []const oap_types.Message) ![]oap_types.Message {
    const out = try allocator.alloc(oap_types.Message, messages.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |*message| message.deinit(allocator);
        allocator.free(out);
    }
    for (messages, 0..) |message, index| {
        const id = if (message.id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (id) |value| allocator.free(value);
        const content = try cloneContent(allocator, message.content);
        out[index] = .{ .id = id, .role = message.role, .content = content };
        filled = index + 1;
    }
    return out;
}

fn cloneContent(allocator: std.mem.Allocator, content: oap_types.Content) !oap_types.Content {
    switch (content) {
        .text => |value| return .{ .text = try allocator.dupe(u8, value) },
        .parts => |parts| {
            const out = try allocator.alloc(oap_types.ContentPart, parts.len);
            var filled: usize = 0;
            errdefer {
                for (out[0..filled]) |*part| part.deinit(allocator);
                allocator.free(out);
            }
            for (parts, 0..) |part, index| {
                out[index] = try clonePart(allocator, part);
                filled = index + 1;
            }
            return .{ .parts = out };
        },
    }
}

fn nextEnvelope(server: *Server, allocator: std.mem.Allocator) !oap_types.Envelope {
    const line = server.popOutbound() orelse return error.NoOutboundFrame;
    defer allocator.free(line);
    return oap_envelope.deserializeEnvelope(line, allocator);
}

fn drainOutbound(server: *Server, allocator: std.mem.Allocator) void {
    while (server.popOutbound()) |line| allocator.free(line);
}

fn openTestSession(server: *Server, allocator: std.mem.Allocator, session_id: []const u8) !void {
    try server.handleEnvelope(.{
        .id = "open-req",
        .payload = .{ .session_open_request = .{ .session_id = session_id } },
    });
    drainOutbound(server, allocator);
}

fn submitTestMessage(server: *Server, request_id: []const u8, session_id: []const u8) !void {
    var parts = [_]oap_types.ContentPart{.{ .text = "go" }};
    var messages = [_]oap_types.Message{.{ .role = .user, .content = .{ .parts = &parts } }};
    try server.handleEnvelope(.{
        .id = request_id,
        .session_id = session_id,
        .payload = .{ .message_submit_request = .{
            .session_id = session_id,
            .messages = &messages,
            .delivery = .auto,
        } },
    });
}

fn discardPending(server: *Server, allocator: std.mem.Allocator) void {
    while (server.popPendingSubmission()) |item| {
        var owned = item;
        owned.deinit(allocator);
    }
    while (server.popPendingCancel()) |item| {
        var owned = item;
        owned.deinit(allocator);
    }
}

test "initialize negotiates the core profile and pins the capability revision" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .endpoint_version = "test" });
    defer server.deinit();

    const versions = [_][]const u8{oap_types.VERSION};
    const profiles = [_][]const u8{oap_types.PROFILE};
    try server.handleEnvelope(.{
        .id = "init-1",
        .payload = .{ .initialize_request = .{
            .protocol_versions = &versions,
            .profiles = &profiles,
        } },
    });

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);

    try std.testing.expectEqualStrings("init-1", reply.in_reply_to.?);
    try std.testing.expectEqualStrings(CAPABILITY_REVISION, reply.capability_revision.?);
    const payload = reply.payload.initialize_response;
    try std.testing.expectEqualStrings(oap_types.VERSION, payload.protocol_version);
    try std.testing.expectEqualStrings(oap_types.PROFILE, payload.profile);
    try std.testing.expectEqualStrings(ENDPOINT_ID, payload.endpoint.id);
    try std.testing.expect(server.initialized);
}

test "initialize refuses a version or profile this endpoint does not serve" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{});
    defer server.deinit();

    const versions = [_][]const u8{"0.9"};
    const profiles = [_][]const u8{oap_types.PROFILE};
    try server.handleEnvelope(.{
        .id = "init-bad",
        .payload = .{ .initialize_request = .{
            .protocol_versions = &versions,
            .profiles = &profiles,
        } },
    });

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);

    try std.testing.expectEqualStrings("init-bad", reply.in_reply_to.?);
    try std.testing.expectEqual(oap_types.ErrorCode.unsupported_feature, reply.payload.error_response.code);
    try std.testing.expectEqualStrings("unsatisfiable", reply.payload.error_response.detail("reason").?);
    try std.testing.expect(!server.initialized);
}

test "capabilities answers a revisioned descriptor with degradation records" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .endpoint_version = "test" });
    defer server.deinit();

    try server.handleEnvelope(.{ .id = "cap-1", .payload = .{ .capabilities_request = {} } });

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);

    try std.testing.expectEqualStrings("cap-1", reply.in_reply_to.?);
    try std.testing.expectEqualStrings(CAPABILITY_REVISION, reply.capability_revision.?);
    const capabilities = reply.payload.capabilities_response;
    try std.testing.expectEqual(oap_types.SupportLevel.native, capabilities.feature("session.message.delivery.auto").?.level);
    try std.testing.expectEqual(oap_types.SupportLevel.degraded, capabilities.feature("run.cancel").?.level);
    try std.testing.expectEqualStrings("per_run", capabilities.feature("run.model_selection").?.mode.?);
    try std.testing.expect(capabilities.feature("action.tools.list") == null);
    try std.testing.expect(capabilities.feature("session.message.delivery.queue") == null);
    try std.testing.expectEqual(@as(usize, advertised_degradation.len), capabilities.degradation.len);
    try std.testing.expectEqualStrings("stdio", capabilities.bindings[0].kind);
    try std.testing.expectEqualStrings("jsonl", capabilities.bindings[0].serialization.?);
}

test "capabilities and initialize ignore a stale capability revision" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{});
    defer server.deinit();

    try server.handleEnvelope(.{
        .id = "cap-stale",
        .capability_revision = "someone-elses-revision",
        .payload = .{ .capabilities_request = {} },
    });

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);
    try std.testing.expectEqual(oap_types.Payload.capabilities_response, std.meta.activeTag(reply.payload));
}

test "a pinned stale revision is rejected on every other request" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{});
    defer server.deinit();

    try server.handleEnvelope(.{
        .id = "open-stale",
        .capability_revision = "older-revision",
        .payload = .{ .session_open_request = .{} },
    });

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);

    const err = reply.payload.error_response;
    try std.testing.expectEqual(oap_types.ErrorCode.stale_capabilities, err.code);
    try std.testing.expectEqualStrings("older-revision", err.detail("expected_revision").?);
    try std.testing.expectEqualStrings(CAPABILITY_REVISION, err.detail("current_revision").?);
    try std.testing.expectEqual(@as(u32, 0), server.sessions.count());
}

test "session open allocates an idle session and reopening it is idempotent" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@claude" });
    defer server.deinit();

    try server.handleEnvelope(.{ .id = "open-1", .payload = .{ .session_open_request = .{} } });

    var first = try nextEnvelope(&server, allocator);
    defer first.deinit(allocator);
    const state = first.payload.session_open_response;
    try std.testing.expectEqual(oap_types.SessionStatus.idle, state.status);
    try std.testing.expect(state.active_run_id == null);
    try std.testing.expectEqualStrings("anthropic/anthropic-messages@claude", state.current_model_id.?);
    try std.testing.expectEqual(@as(usize, 21), state.session_id.len);
    try std.testing.expectEqualStrings(state.session_id, first.session_id.?);

    try server.handleEnvelope(.{
        .id = "open-2",
        .payload = .{ .session_open_request = .{ .session_id = state.session_id } },
    });
    var second = try nextEnvelope(&server, allocator);
    defer second.deinit(allocator);
    try std.testing.expectEqualStrings(state.session_id, second.payload.session_open_response.session_id);
    try std.testing.expectEqual(@as(u32, 1), server.sessions.count());
}

test "session state for an unopened session is a typed error" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{});
    defer server.deinit();

    try server.handleEnvelope(.{
        .id = "state-1",
        .payload = .{ .session_state_request = .{ .session_id = "nope" } },
    });

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);
    try std.testing.expectEqualStrings("state-1", reply.in_reply_to.?);
    try std.testing.expectEqual(oap_types.ErrorCode.session_not_found, reply.payload.error_response.code);
}

test "a complete run emits admission, contiguous run events, and one terminal" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");
    try submitTestMessage(&server, "req-1", "sess-1");

    var admission = try nextEnvelope(&server, allocator);
    defer admission.deinit(allocator);
    const submit = admission.payload.message_submit_response;
    try std.testing.expectEqualStrings("req-1", admission.in_reply_to.?);
    try std.testing.expect(submit.accepted);
    try std.testing.expectEqual(oap_types.RequestedDelivery.auto, submit.requested_delivery);
    try std.testing.expectEqual(oap_types.EffectiveDelivery.start, submit.effective_delivery);
    try std.testing.expectEqual(oap_types.Admission.started, submit.admission);
    try std.testing.expectEqual(oap_types.RunStatus.running, submit.status.?);
    try std.testing.expectEqualStrings(DELIVERY_RESOLUTION_IDLE, submit.delivery_resolution.?);
    try std.testing.expectEqualStrings("anthropic/anthropic-messages@m", submit.model_id.?);
    try std.testing.expect(admission.sequence == null);
    const run_id = try allocator.dupe(u8, submit.run_id.?);
    defer allocator.free(run_id);

    var started = try nextEnvelope(&server, allocator);
    defer started.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), started.sequence.?);
    try std.testing.expectEqualStrings(run_id, started.run_id.?);
    try std.testing.expectEqualStrings("anthropic/anthropic-messages@m", started.payload.run_started.model_id.?);

    var state_event = try nextEnvelope(&server, allocator);
    defer state_event.deinit(allocator);
    try std.testing.expectEqual(oap_types.SessionStatus.running, state_event.payload.session_state_updated.status);
    try std.testing.expectEqualStrings(run_id, state_event.payload.session_state_updated.active_run_id.?);
    try std.testing.expect(state_event.run_id == null);

    try server.noteContent("sess-1", .{ .text = "he" });
    try server.noteContent("sess-1", .{ .text = "llo" });
    server.noteUsage("sess-1", .{ .input_tokens = 4, .output_tokens = 2, .total_tokens = 6 });
    try server.settleCompleted("sess-1", "hello", "end_turn");

    var delta_one = try nextEnvelope(&server, allocator);
    defer delta_one.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), delta_one.sequence.?);
    try std.testing.expectEqualStrings("he", delta_one.payload.content_delta.part.text);

    var delta_two = try nextEnvelope(&server, allocator);
    defer delta_two.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), delta_two.sequence.?);
    try std.testing.expectEqualStrings(
        delta_one.payload.content_delta.message_id.?,
        delta_two.payload.content_delta.message_id.?,
    );

    var completed = try nextEnvelope(&server, allocator);
    defer completed.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 4), completed.sequence.?);
    const terminal = completed.payload.run_completed;
    try std.testing.expectEqualStrings("hello", terminal.final_response.content.text);
    try std.testing.expectEqualStrings("end_turn", terminal.stop_reason);
    try std.testing.expectEqual(@as(u64, 6), terminal.usage.total_tokens.?);

    var idle = try nextEnvelope(&server, allocator);
    defer idle.deinit(allocator);
    try std.testing.expectEqual(oap_types.SessionStatus.idle, idle.payload.session_state_updated.status);
    try std.testing.expect(idle.payload.session_state_updated.active_run_id == null);
    try std.testing.expectEqual(@as(u64, 2), idle.sequence.?);

    try std.testing.expect(server.popOutbound() == null);
    try std.testing.expect(!server.hasActiveRun());
}

test "a submission hands the host exactly one pending native run" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();

    try openTestSession(&server, allocator, "sess-1");
    try submitTestMessage(&server, "req-1", "sess-1");
    drainOutbound(&server, allocator);

    var pending = server.popPendingSubmission().?;
    defer pending.deinit(allocator);
    try std.testing.expectEqualStrings("sess-1", pending.session_id);
    try std.testing.expectEqualStrings("anthropic/anthropic-messages@m", pending.model_id);
    try std.testing.expectEqual(@as(usize, 1), pending.messages.len);
    try std.testing.expectEqualStrings("go", pending.messages[0].content.parts[0].text);
    try std.testing.expect(server.popPendingSubmission() == null);
}

test "a second submission is refused while a run is nonterminal" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");
    try submitTestMessage(&server, "req-1", "sess-1");
    drainOutbound(&server, allocator);
    discardPending(&server, allocator);

    try submitTestMessage(&server, "req-2", "sess-1");
    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);
    try std.testing.expectEqual(oap_types.ErrorCode.session_busy, reply.payload.error_response.code);
    try std.testing.expectEqualStrings("req-2", reply.in_reply_to.?);
    try std.testing.expect(server.popPendingSubmission() == null);

    try server.settleCompleted("sess-1", "done", "end_turn");
    drainOutbound(&server, allocator);
    try submitTestMessage(&server, "req-3", "sess-1");
    var admitted = try nextEnvelope(&server, allocator);
    defer admitted.deinit(allocator);
    try std.testing.expect(admitted.payload.message_submit_response.accepted);
}

test "cancellation acknowledges intent and only settlement emits the terminal" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");
    try submitTestMessage(&server, "req-1", "sess-1");
    const run_id = try allocator.dupe(u8, server.activeRunId("sess-1").?);
    defer allocator.free(run_id);
    drainOutbound(&server, allocator);

    try server.handleEnvelope(.{
        .id = "cancel-1",
        .session_id = "sess-1",
        .run_id = run_id,
        .payload = .{ .run_cancel_request = .{
            .session_id = "sess-1",
            .run_id = run_id,
            .reason = "user stopped",
        } },
    });

    var ack = try nextEnvelope(&server, allocator);
    defer ack.deinit(allocator);
    try std.testing.expectEqualStrings("cancel-1", ack.in_reply_to.?);
    try std.testing.expect(ack.payload.run_cancel_response.accepted);
    try std.testing.expectEqual(oap_types.RunStatus.cancelling, ack.payload.run_cancel_response.status);
    try std.testing.expect(ack.sequence == null);

    var status = try nextEnvelope(&server, allocator);
    defer status.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), status.sequence.?);
    try std.testing.expectEqual(oap_types.RunStatus.cancelling, status.payload.run_status_updated.status);

    var pending = server.popPendingCancel().?;
    defer pending.deinit(allocator);
    try std.testing.expectEqualStrings(run_id, pending.run_id);

    try server.settleCancelled("sess-1", "user stopped");
    var cancelled = try nextEnvelope(&server, allocator);
    defer cancelled.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), cancelled.sequence.?);
    try std.testing.expectEqualStrings("user stopped", cancelled.payload.run_cancelled.reason.?);

    var closed = try nextEnvelope(&server, allocator);
    defer closed.deinit(allocator);
    try std.testing.expectEqual(oap_types.SessionStatus.closed, closed.payload.session_state_updated.status);
}

test "repeated cancellation is idempotent and queues one native teardown" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");
    try submitTestMessage(&server, "req-1", "sess-1");
    const run_id = try allocator.dupe(u8, server.activeRunId("sess-1").?);
    defer allocator.free(run_id);
    drainOutbound(&server, allocator);

    const cancel = oap_types.Envelope{
        .id = "cancel-1",
        .session_id = "sess-1",
        .run_id = run_id,
        .payload = .{ .run_cancel_request = .{ .session_id = "sess-1", .run_id = run_id } },
    };
    try server.handleEnvelope(cancel);
    try server.handleEnvelope(cancel);

    var first = try nextEnvelope(&server, allocator);
    defer first.deinit(allocator);
    try std.testing.expect(first.payload.run_cancel_response.accepted);
    var status = try nextEnvelope(&server, allocator);
    defer status.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), status.sequence.?);
    var second = try nextEnvelope(&server, allocator);
    defer second.deinit(allocator);
    try std.testing.expect(second.payload.run_cancel_response.accepted);
    try std.testing.expect(server.popOutbound() == null);

    var pending = server.popPendingCancel().?;
    defer pending.deinit(allocator);
    try std.testing.expect(server.popPendingCancel() == null);
}

test "natural completion wins a race with an accepted cancellation" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");
    try submitTestMessage(&server, "req-1", "sess-1");
    const run_id = try allocator.dupe(u8, server.activeRunId("sess-1").?);
    defer allocator.free(run_id);
    drainOutbound(&server, allocator);

    try server.handleEnvelope(.{
        .id = "cancel-1",
        .session_id = "sess-1",
        .run_id = run_id,
        .payload = .{ .run_cancel_request = .{ .session_id = "sess-1", .run_id = run_id } },
    });
    drainOutbound(&server, allocator);

    try server.settleCompleted("sess-1", "finished first", "end_turn");
    try server.settleCancelled("sess-1", "too late");

    var completed = try nextEnvelope(&server, allocator);
    defer completed.deinit(allocator);
    try std.testing.expectEqual(oap_types.Payload.run_completed, std.meta.activeTag(completed.payload));
    try std.testing.expectEqual(@as(u64, 3), completed.sequence.?);

    var state_event = try nextEnvelope(&server, allocator);
    defer state_event.deinit(allocator);
    try std.testing.expectEqual(oap_types.Payload.session_state_updated, std.meta.activeTag(state_event.payload));
    try std.testing.expect(server.popOutbound() == null);
}

test "a duplicate native terminal never produces a second portable terminal" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");
    try submitTestMessage(&server, "req-1", "sess-1");
    drainOutbound(&server, allocator);

    try server.settleCompleted("sess-1", "once", "end_turn");
    drainOutbound(&server, allocator);

    try server.settleCompleted("sess-1", "twice", "end_turn");
    try server.settleFailed("sess-1", .provider_error, "late failure");
    try server.noteContent("sess-1", .{ .text = "late text" });
    try std.testing.expect(server.popOutbound() == null);
}

test "cancelling a settled run reports run_already_terminal" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");
    try submitTestMessage(&server, "req-1", "sess-1");
    const run_id = try allocator.dupe(u8, server.activeRunId("sess-1").?);
    defer allocator.free(run_id);
    try server.settleCompleted("sess-1", "done", "end_turn");
    drainOutbound(&server, allocator);

    try server.handleEnvelope(.{
        .id = "cancel-late",
        .session_id = "sess-1",
        .run_id = run_id,
        .payload = .{ .run_cancel_request = .{ .session_id = "sess-1", .run_id = run_id } },
    });

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);
    try std.testing.expectEqual(oap_types.ErrorCode.run_already_terminal, reply.payload.error_response.code);
}

test "a stale cancellation never targets a replacement run" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");
    try submitTestMessage(&server, "req-1", "sess-1");
    const first_run = try allocator.dupe(u8, server.activeRunId("sess-1").?);
    defer allocator.free(first_run);
    try server.settleCompleted("sess-1", "done", "end_turn");
    try submitTestMessage(&server, "req-2", "sess-1");
    drainOutbound(&server, allocator);

    try server.handleEnvelope(.{
        .id = "cancel-stale",
        .session_id = "sess-1",
        .run_id = first_run,
        .payload = .{ .run_cancel_request = .{ .session_id = "sess-1", .run_id = first_run } },
    });

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);
    try std.testing.expectEqual(oap_types.ErrorCode.run_not_found, reply.payload.error_response.code);
    try std.testing.expect(server.popPendingCancel() == null);
}

test "a native stop without an accepted cancellation settles as a failure" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");
    try submitTestMessage(&server, "req-1", "sess-1");
    drainOutbound(&server, allocator);

    try server.settleCancelled("sess-1", "session evicted");
    var terminal = try nextEnvelope(&server, allocator);
    defer terminal.deinit(allocator);
    try std.testing.expectEqual(oap_types.Payload.run_failed, std.meta.activeTag(terminal.payload));
    try std.testing.expectEqual(oap_types.ErrorCode.internal_error, terminal.payload.run_failed.err.code);
}

test "a cancelled session refuses further submissions" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");
    try submitTestMessage(&server, "req-1", "sess-1");
    const run_id = try allocator.dupe(u8, server.activeRunId("sess-1").?);
    defer allocator.free(run_id);
    try server.handleEnvelope(.{
        .id = "cancel-1",
        .session_id = "sess-1",
        .run_id = run_id,
        .payload = .{ .run_cancel_request = .{ .session_id = "sess-1", .run_id = run_id } },
    });
    try server.settleCancelled("sess-1", null);
    drainOutbound(&server, allocator);

    try submitTestMessage(&server, "req-2", "sess-1");
    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);
    try std.testing.expectEqual(oap_types.ErrorCode.session_not_found, reply.payload.error_response.code);
}

test "an unadvertised run control is refused before any identity is allocated" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");

    var parts = [_]oap_types.ContentPart{.{ .text = "go" }};
    var messages = [_]oap_types.Message{.{ .role = .user, .content = .{ .parts = &parts } }};
    try server.handleEnvelope(.{
        .id = "req-instr",
        .session_id = "sess-1",
        .payload = .{ .message_submit_request = .{
            .session_id = "sess-1",
            .messages = &messages,
            .delivery = .auto,
            .instructions = "be terse",
        } },
    });

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);
    const err = reply.payload.error_response;
    try std.testing.expectEqual(oap_types.ErrorCode.unsupported_feature, err.code);
    try std.testing.expectEqualStrings("run.instructions", err.detail("feature").?);
    try std.testing.expectEqualStrings("unadvertised", err.detail("reason").?);
    try std.testing.expect(server.popPendingSubmission() == null);
    try std.testing.expect(!server.hasActiveRun());
    try std.testing.expect(server.popOutbound() == null);
}

test "run control refusal follows the declared control order" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");

    var parts = [_]oap_types.ContentPart{.{ .text = "go" }};
    var messages = [_]oap_types.Message{.{ .role = .user, .content = .{ .parts = &parts } }};
    try server.handleEnvelope(.{
        .id = "req-multi",
        .session_id = "sess-1",
        .payload = .{ .message_submit_request = .{
            .session_id = "sess-1",
            .messages = &messages,
            .delivery = .auto,
            .model_id = "",
            .instructions = "be terse",
            .tool_choice_json = "{\"mode\":\"auto\"}",
            .output_schema_json = "{}",
        } },
    });

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);
    const err = reply.payload.error_response;
    try std.testing.expectEqual(oap_types.ErrorCode.model_not_found, err.code);
    try std.testing.expectEqualStrings("", err.detail("model_id").?);
    try std.testing.expect(server.popOutbound() == null);
}

test "an advertised run control admits and is reported on the run" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@session-default" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");

    var parts = [_]oap_types.ContentPart{.{ .text = "go" }};
    var messages = [_]oap_types.Message{.{ .role = .user, .content = .{ .parts = &parts } }};
    try server.handleEnvelope(.{
        .id = "req-model",
        .session_id = "sess-1",
        .payload = .{ .message_submit_request = .{
            .session_id = "sess-1",
            .messages = &messages,
            .delivery = .auto,
            .model_id = "anthropic/anthropic-messages@per-run",
        } },
    });

    var admission = try nextEnvelope(&server, allocator);
    defer admission.deinit(allocator);
    try std.testing.expectEqualStrings("anthropic/anthropic-messages@per-run", admission.payload.message_submit_response.model_id.?);

    var started = try nextEnvelope(&server, allocator);
    defer started.deinit(allocator);
    try std.testing.expectEqualStrings("anthropic/anthropic-messages@per-run", started.payload.run_started.model_id.?);

    var state_event = try nextEnvelope(&server, allocator);
    defer state_event.deinit(allocator);
    try std.testing.expectEqualStrings(
        "anthropic/anthropic-messages@session-default",
        state_event.payload.session_state_updated.current_model_id.?,
    );
}

fn buildCapabilitiesProbe(allocator: std.mem.Allocator) !void {
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();

    var capabilities = try server.buildCapabilities();
    capabilities.deinit(allocator);
}

test "buildCapabilities survives an allocation failure at every step" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildCapabilitiesProbe, .{});
}

fn cloneDetailsProbe(allocator: std.mem.Allocator) !void {
    const entries = [_]oap_types.DetailEntry{
        .{ .key = "reason", .value = "stale_capabilities" },
        .{ .key = "control", .value = "unadvertised" },
    };
    const cloned = try cloneDetails(allocator, &entries);
    freeDetails(allocator, cloned);
}

test "cloneDetails survives an allocation failure at every step" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cloneDetailsProbe, .{});
}

fn settleTerminalProbe(allocator: std.mem.Allocator) !void {
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");
    try submitTestMessage(&server, "req-1", "sess-1");
    drainOutbound(&server, allocator);
    discardPending(&server, allocator);

    try server.settleCompleted("sess-1", "done", "end_turn");
    drainOutbound(&server, allocator);

    try submitTestMessage(&server, "req-2", "sess-1");
    drainOutbound(&server, allocator);
    discardPending(&server, allocator);
    try server.settleFailed("sess-1", .provider_error, "upstream refused");
    drainOutbound(&server, allocator);

    try submitTestMessage(&server, "req-3", "sess-1");
    drainOutbound(&server, allocator);
    discardPending(&server, allocator);
    const run_id = try allocator.dupe(u8, server.activeRunId("sess-1").?);
    defer allocator.free(run_id);
    try server.handleEnvelope(.{
        .id = "cancel-req",
        .session_id = "sess-1",
        .run_id = run_id,
        .payload = .{ .run_cancel_request = .{ .session_id = "sess-1", .run_id = run_id } },
    });
    drainOutbound(&server, allocator);
    discardPending(&server, allocator);
    try server.settleCancelled("sess-1", "user stopped");
    drainOutbound(&server, allocator);
}

test "every terminal settle survives an allocation failure at every step" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, settleTerminalProbe, .{});
}

test "a syntactically invalid model selection is refused before admission" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");

    var parts = [_]oap_types.ContentPart{.{ .text = "go" }};
    var messages = [_]oap_types.Message{.{ .role = .user, .content = .{ .parts = &parts } }};
    try server.handleEnvelope(.{
        .id = "req-bad-model",
        .session_id = "sess-1",
        .payload = .{ .message_submit_request = .{
            .session_id = "sess-1",
            .messages = &messages,
            .delivery = .auto,
            .model_id = "claude-sonnet-4-5",
        } },
    });

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);
    const err = reply.payload.error_response;
    try std.testing.expectEqual(oap_types.ErrorCode.model_not_found, err.code);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", err.detail("model_id").?);
    try std.testing.expect(server.popOutbound() == null);
    try std.testing.expect(server.popPendingSubmission() == null);
}

test "non-text content is refused on submit, so a carry never reaches a session that would ignore it" {
    const allocator = std.testing.allocator;

    const cases = [_]struct { part: oap_types.ContentPart, feature: []const u8 }{
        .{
            .part = .{ .reasoning = .{ .text = "because", .carry = "REASON-SIG" } },
            .feature = "session.message.content.reasoning",
        },
        .{
            .part = .{ .tool_call = .{
                .tool_call_id = "c1",
                .name = "grep",
                .arguments_json = "{}",
                .carry = "TOOL-SIG",
            } },
            .feature = "session.message.content.tool_call",
        },
        .{
            .part = .{ .tool_result = .{ .tool_call_id = "c1", .result_json = "{}" } },
            .feature = "session.message.content.tool_result",
        },
    };

    for (cases) |case| {
        var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
        defer server.deinit();
        defer discardPending(&server, allocator);

        try openTestSession(&server, allocator, "sess-1");

        var parts = [_]oap_types.ContentPart{ .{ .text = "go" }, case.part };
        var messages = [_]oap_types.Message{.{ .role = .user, .content = .{ .parts = &parts } }};
        try server.handleEnvelope(.{
            .id = "req-parts",
            .session_id = "sess-1",
            .payload = .{ .message_submit_request = .{
                .session_id = "sess-1",
                .messages = &messages,
                .delivery = .auto,
            } },
        });

        var reply = try nextEnvelope(&server, allocator);
        defer reply.deinit(allocator);
        const err = reply.payload.error_response;
        try std.testing.expectEqual(oap_types.ErrorCode.unsupported_feature, err.code);
        try std.testing.expectEqualStrings(case.feature, err.detail("feature").?);
        try std.testing.expect(server.popOutbound() == null);
        try std.testing.expect(server.popPendingSubmission() == null);
    }
}

test "an idle settled session is evicted and reported to the host" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{
        .default_model_id = "anthropic/anthropic-messages@m",
        .session_idle_ttl_ms = 1,
    });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");
    try std.testing.expectEqual(@as(u32, 1), server.sessions.count());

    compat.time.sleepNs(5 * std.time.ns_per_ms);

    try server.handleEnvelope(.{
        .id = "req-state",
        .session_id = "sess-1",
        .payload = .{ .session_state_request = .{ .session_id = "sess-1" } },
    });

    try std.testing.expectEqual(@as(u32, 0), server.sessions.count());

    const evicted = server.popEvictedSession() orelse return error.TestExpectedEviction;
    defer allocator.free(evicted);
    try std.testing.expectEqualStrings("sess-1", evicted);

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);
    try std.testing.expectEqual(oap_types.ErrorCode.session_not_found, reply.payload.error_response.code);
}

test "a zero idle ttl disables session eviction" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{
        .default_model_id = "anthropic/anthropic-messages@m",
        .session_idle_ttl_ms = 0,
    });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");
    compat.time.sleepNs(5 * std.time.ns_per_ms);

    try server.handleEnvelope(.{
        .id = "req-state",
        .session_id = "sess-1",
        .payload = .{ .session_state_request = .{ .session_id = "sess-1" } },
    });

    try std.testing.expectEqual(@as(u32, 1), server.sessions.count());
    try std.testing.expect(server.popEvictedSession() == null);
    drainOutbound(&server, allocator);
}

test "a cancel whose envelope scope disagrees with its payload is refused" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");

    try server.handleEnvelope(.{
        .id = "req-cancel",
        .session_id = "sess-other",
        .payload = .{ .run_cancel_request = .{
            .session_id = "sess-1",
            .run_id = "run-1",
        } },
    });

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);
    const err = reply.payload.error_response;
    try std.testing.expectEqual(oap_types.ErrorCode.invalid_request, err.code);
    try std.testing.expect(server.popOutbound() == null);
}

test "a cancel whose envelope run_id disagrees with its payload is refused" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");

    try server.handleEnvelope(.{
        .id = "req-cancel",
        .session_id = "sess-1",
        .run_id = "run-other",
        .payload = .{ .run_cancel_request = .{
            .session_id = "sess-1",
            .run_id = "run-1",
        } },
    });

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);
    const err = reply.payload.error_response;
    try std.testing.expectEqual(oap_types.ErrorCode.invalid_request, err.code);
    try std.testing.expect(server.popOutbound() == null);
}

test "an explicit unsupported delivery mode is refused with a typed error" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");

    var parts = [_]oap_types.ContentPart{.{ .text = "go" }};
    var messages = [_]oap_types.Message{.{ .role = .user, .content = .{ .parts = &parts } }};
    try server.handleEnvelope(.{
        .id = "req-steer",
        .session_id = "sess-1",
        .payload = .{ .message_submit_request = .{
            .session_id = "sess-1",
            .messages = &messages,
            .delivery = .steer,
        } },
    });

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);
    const err = reply.payload.error_response;
    try std.testing.expectEqual(oap_types.ErrorCode.unsupported_feature, err.code);
    try std.testing.expectEqualStrings("session.message.delivery.steer", err.detail("feature").?);
    try std.testing.expect(server.popPendingSubmission() == null);
}

test "a submission with no model anywhere is refused" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{});
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");
    try submitTestMessage(&server, "req-1", "sess-1");

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);
    try std.testing.expectEqual(oap_types.ErrorCode.model_not_found, reply.payload.error_response.code);
    try std.testing.expect(server.popPendingSubmission() == null);
}

test "envelope and payload session_id must agree" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");

    var parts = [_]oap_types.ContentPart{.{ .text = "go" }};
    var messages = [_]oap_types.Message{.{ .role = .user, .content = .{ .parts = &parts } }};
    try server.handleEnvelope(.{
        .id = "req-mismatch",
        .session_id = "sess-1",
        .payload = .{ .message_submit_request = .{
            .session_id = "sess-2",
            .messages = &messages,
            .delivery = .auto,
        } },
    });

    var reply = try nextEnvelope(&server, allocator);
    defer reply.deinit(allocator);
    try std.testing.expectEqual(oap_types.ErrorCode.invalid_request, reply.payload.error_response.code);
}

test "an undecodable envelope answers with a typed error rather than crashing" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{});
    defer server.deinit();

    try std.testing.expectError(error.MalformedLine, server.handleLine("{not json"));
    try std.testing.expect(server.popOutbound() == null);

    try server.handleLine(
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ oap_types.PROFILE ++
            "\",\"type\":\"session.checkpoint.request\",\"id\":\"a\",\"payload\":{}}",
    );
    var second = try nextEnvelope(&server, allocator);
    defer second.deinit(allocator);
    try std.testing.expectEqual(oap_types.ErrorCode.unsupported_feature, second.payload.error_response.code);
}

test "a full conversation drives the endpoint end to end over lines" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try server.handleLine(
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ oap_types.PROFILE ++
            "\",\"type\":\"protocol.initialize.request\",\"id\":\"i1\",\"payload\":" ++
            "{\"protocol_versions\":[\"0.1\"],\"profiles\":[\"" ++ oap_types.PROFILE ++ "\"]}}",
    );
    var init_reply = try nextEnvelope(&server, allocator);
    defer init_reply.deinit(allocator);
    try std.testing.expectEqual(oap_types.Payload.initialize_response, std.meta.activeTag(init_reply.payload));

    try server.handleLine(
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ oap_types.PROFILE ++
            "\",\"type\":\"session.open.request\",\"id\":\"o1\",\"payload\":{\"session_id\":\"sess-line\"}}",
    );
    var open_reply = try nextEnvelope(&server, allocator);
    defer open_reply.deinit(allocator);
    try std.testing.expectEqualStrings("sess-line", open_reply.payload.session_open_response.session_id);

    try server.handleLine(
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ oap_types.PROFILE ++
            "\",\"type\":\"session.message.submit.request\",\"id\":\"s1\",\"session_id\":\"sess-line\"," ++
            "\"capability_revision\":\"" ++ CAPABILITY_REVISION ++ "\"," ++
            "\"payload\":{\"session_id\":\"sess-line\",\"delivery\":\"auto\"," ++
            "\"messages\":[{\"role\":\"user\",\"content\":\"go\"}]}}",
    );
    var admission = try nextEnvelope(&server, allocator);
    defer admission.deinit(allocator);
    try std.testing.expect(admission.payload.message_submit_response.accepted);
    try std.testing.expectEqualStrings(CAPABILITY_REVISION, admission.capability_revision.?);

    drainOutbound(&server, allocator);
    try server.noteContent("sess-line", .{ .reasoning = .{ .text = "weighing options" } });
    try server.settleCompleted("sess-line", "answer", "end_turn");

    var reasoning = try nextEnvelope(&server, allocator);
    defer reasoning.deinit(allocator);
    try std.testing.expectEqualStrings("weighing options", reasoning.payload.content_delta.part.reasoning.text);

    var completed = try nextEnvelope(&server, allocator);
    defer completed.deinit(allocator);
    try std.testing.expectEqualStrings("answer", completed.payload.run_completed.final_response.content.text);
}

test "a message boundary starts a new portable assistant message id" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@m" });
    defer server.deinit();
    defer discardPending(&server, allocator);

    try openTestSession(&server, allocator, "sess-1");
    try submitTestMessage(&server, "req-1", "sess-1");
    drainOutbound(&server, allocator);

    try server.noteContent("sess-1", .{ .text = "first" });
    server.noteMessageBoundary("sess-1");
    try server.noteContent("sess-1", .{ .text = "second" });

    var first = try nextEnvelope(&server, allocator);
    defer first.deinit(allocator);
    var second = try nextEnvelope(&server, allocator);
    defer second.deinit(allocator);

    try std.testing.expect(!std.mem.eql(
        u8,
        first.payload.content_delta.message_id.?,
        second.payload.content_delta.message_id.?,
    ));
    try std.testing.expectEqual(@as(u64, 2), first.sequence.?);
    try std.testing.expectEqual(@as(u64, 3), second.sequence.?);
}

test "an unrecognised control frame is answered rather than ignored" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .endpoint_version = "test" });
    defer server.deinit();

    try server.handleLine("{\"control\":\"replay\",\"id\":\"r1\",\"session_id\":\"s1\",\"after\":0}");

    const line = server.popOutbound() orelse return error.TestExpectedControlAnswer;
    defer allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "\"control\":\"replay.error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"id\":\"r1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"code\":\"unsupported_control\"") != null);
}

test "a control frame without an id is still answered" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .endpoint_version = "test" });
    defer server.deinit();

    try server.handleLine("{\"control\":\"rewind\"}");

    const line = server.popOutbound() orelse return error.TestExpectedControlAnswer;
    defer allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "\"control\":\"rewind.error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"id\"") == null);
}

fn unsupportedControlProbe(allocator: std.mem.Allocator) !void {
    var server = try Server.init(allocator, .{ .endpoint_version = "test" });
    defer server.deinit();

    try server.handleLine("{\"control\":\"replay\",\"id\":\"r1\"}");
    drainOutbound(&server, allocator);
}

test "an unsupported control answer survives an allocation failure at every step" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, unsupportedControlProbe, .{});
}

test "a line that is not json is a framing defect rather than an error response" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .endpoint_version = "test" });
    defer server.deinit();

    try std.testing.expectError(error.MalformedLine, server.handleLine("this is not an envelope"));
    try std.testing.expect(server.popOutbound() == null);
}

test "a json object that is neither envelope nor control is a framing defect" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .endpoint_version = "test" });
    defer server.deinit();

    try std.testing.expectError(error.MalformedLine, server.handleLine("{\"hello\":\"world\"}"));
    try std.testing.expect(server.popOutbound() == null);
}

test "a declared envelope that fails to decode answers a correlated error response" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .endpoint_version = "test" });
    defer server.deinit();

    try server.handleLine("{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"id\":\"req-7\"}");

    const line = server.popOutbound() orelse return error.TestExpectedErrorResponse;
    defer allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "error.response") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"in_reply_to\":\"req-7\"") != null);
}

test "a declared envelope carrying no id is fatal because nothing could address a refusal" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .endpoint_version = "test" });
    defer server.deinit();

    try std.testing.expectError(
        error.UnaddressableEnvelope,
        server.handleLine("{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\"}"),
    );
    try std.testing.expect(server.popOutbound() == null);
}
