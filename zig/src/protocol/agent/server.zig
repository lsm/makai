const std = @import("std");
const compat = @import("compat");
const agent_types = @import("agent_types");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const SessionState = struct {
    session_id: agent_types.SessionId,
    status: agent_types.AgentStatus,
    model: []const u8,
    config_json: []const u8,
    system_prompt: []const u8,
    message_count: u32,
    created_at: i64,
    updated_at: i64,
    /// Last activity on the monotonic clock (`compat.time.monotonicMillis`
    /// domain) — the TTL idleness clock (§13.2.6), kept separate from the
    /// wall-clock `updated_at` (protocol-visible in `session_info`) so
    /// wall-clock adjustments cannot distort eviction age math.
    last_activity_ms: i64,
    /// Registration generation (§13.4.5, #204): stamped from the server-wide
    /// monotonic counter at registration, so every registration — and in
    /// particular a re-registration of an id whose previous registration was
    /// stopped or evicted mid-run — carries a strictly newer generation. Runs
    /// bind the generation they were admitted under; a mismatch identifies a
    /// stale run whose publications must be discarded.
    generation: u64,
};

pub const PendingAgentMessage = struct {
    session_id: agent_types.SessionId,
    message_json: []const u8,
    options_json: []const u8,
    config_json: []const u8,
    system_prompt: []const u8,

    pub fn deinit(self: *PendingAgentMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.message_json);
        allocator.free(self.options_json);
        allocator.free(self.config_json);
        allocator.free(self.system_prompt);
        self.* = undefined;
    }
};

/// Delegate that resolves a passthrough `models_request` by calling into the
/// canonical provider protocol. Implementations must return a fully-owned
/// `ModelsResponse` (the agent server takes ownership and frees it).
pub const ProviderModelsDelegateFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: agent_types.ModelsRequest,
) anyerror!agent_types.ModelsResponse;

/// Default idle-session TTL (spec §13.2.6 rule 6): 30 minutes. Long enough
/// that an interactive multi-message conversation never sees an eviction on
/// human-paced gaps, short enough that abandoned ids from clients that never
/// send `agent_stop` do not accumulate for the process lifetime (#202).
pub const default_session_idle_ttl_ms: u64 = 30 * 60 * 1_000;

pub const AgentProtocolServer = struct {
    allocator: std.mem.Allocator,
    sessions: std.AutoHashMap(agent_types.SessionId, SessionState),
    expected_sequences: std.AutoHashMap(agent_types.SessionId, u64),
    outgoing_sequences: std.AutoHashMap(agent_types.SessionId, u64),
    outbox: std.ArrayList(agent_types.Envelope),
    pending_messages: std.ArrayList(PendingAgentMessage),
    options: Options,
    /// Monotonic source for `SessionState.generation` (§13.4.5, #204): one
    /// counter serves all registrations — globally unique stamps are strictly
    /// ordered across ids too, so no per-id bookkeeping that outlives session
    /// removal (and would grow with every distinct id for the process
    /// lifetime) is needed to keep generations increasing across a
    /// stop/evict + re-register cycle.
    next_session_generation: u64 = 0,

    const Self = @This();

    pub const Options = struct {
        /// Idle-session TTL in milliseconds (spec §13.2.6 rule 6): a sweep
        /// (`evictIdleSessions`) removes sessions whose last activity —
        /// measured on the monotonic clock — is strictly older than this.
        /// Last activity is inbound (`agent_message` acceptance,
        /// `agent_status` poll) or server-side run publication (`agent_event`,
        /// `agent_result`, `agent_error`); sessions with an in-flight run
        /// (status `.processing`) are never evicted. Defaults to
        /// `default_session_idle_ttl_ms`; `0` disables eviction (sessions live
        /// until `agent_stop` or process exit).
        session_idle_ttl_ms: u64 = default_session_idle_ttl_ms,
        /// Explicit kill-switch for the model catalog feature. When `false`,
        /// `models_request` always returns a `not_implemented` nack regardless of
        /// whether a delegate is configured.
        ///
        /// NOTE: this flag alone does not advertise the capability. A
        /// `models_request` is only answered with a `models_response` when BOTH
        /// `supports_model_catalog == true` AND `provider_models_delegate != null`.
        /// All four combinations resolve as follows:
        ///   * supports=true,  delegate=set  -> delegate is invoked.
        ///   * supports=true,  delegate=null -> `not_implemented` nack (default).
        ///   * supports=false, delegate=set  -> `not_implemented` nack (kill-switch).
        ///   * supports=false, delegate=null -> `not_implemented` nack.
        /// In other words, the default-constructed server is a NO-OP responder
        /// until a delegate is wired; flipping this flag is only meaningful when
        /// callers want to disable an otherwise-configured delegate at runtime.
        supports_model_catalog: bool = true,
        /// Provider-protocol passthrough for model discovery. When null, the agent
        /// server replies with `not_implemented` to advertise capability absence.
        provider_models_delegate: ?ProviderModelsDelegateFn = null,
        /// Opaque context passed to `provider_models_delegate`.
        provider_models_ctx: ?*anyopaque = null,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return initWithOptions(allocator, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, options: Options) Self {
        return .{
            .allocator = allocator,
            .sessions = std.AutoHashMap(agent_types.SessionId, SessionState).init(allocator),
            .expected_sequences = std.AutoHashMap(agent_types.SessionId, u64).init(allocator),
            .outgoing_sequences = std.AutoHashMap(agent_types.SessionId, u64).init(allocator),
            .outbox = std.ArrayList(agent_types.Envelope).empty,
            .pending_messages = std.ArrayList(PendingAgentMessage).empty,
            .options = options,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.model);
            self.allocator.free(entry.value_ptr.config_json);
            self.allocator.free(entry.value_ptr.system_prompt);
        }
        self.sessions.deinit();
        self.expected_sequences.deinit();
        self.outgoing_sequences.deinit();

        for (self.outbox.items) |*env| env.deinit(self.allocator);
        self.outbox.deinit(self.allocator);

        for (self.pending_messages.items) |*pending| pending.deinit(self.allocator);
        self.pending_messages.deinit(self.allocator);

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
            .models_request => |req| return try self.handleModelsRequest(req, env),
            .tool_list => {
                return .{
                    .session_id = env.session_id,
                    .message_id = agent_types.generateUlid(),
                    .sequence = env.sequence,
                    .in_reply_to = env.message_id,
                    .timestamp = compat.time.nowMillis(),
                    .payload = .{ .tool_list_response = .{ .tools = &.{} } },
                };
            },
            .ping => {
                const ping_id = try agent_types.ulidToString(env.message_id, self.allocator);
                return .{
                    .session_id = env.session_id,
                    .message_id = agent_types.generateUlid(),
                    .sequence = env.sequence,
                    .in_reply_to = env.message_id,
                    .timestamp = compat.time.nowMillis(),
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
        // §13.1 (#204): when the payload names a session id, the envelope id
        // MUST agree — a mismatch is rejected before any lookup or mutation.
        // (A start that OMITS the payload id is the sanctioned exception: the
        // envelope id is ignored and the server generates the container id.)
        if (req.session_id) |payload_id| {
            if (!std.mem.eql(u8, &payload_id, &env.session_id)) {
                return try self.makeError(env.session_id, env.message_id, .invalid_request, "envelope and payload session_id disagree");
            }
        }

        if (env.sequence != 1) {
            return try self.makeError(env.session_id, env.message_id, .invalid_request, "agent_start sequence must be 1");
        }

        const session_id = req.session_id orelse agent_types.generateSessionId();
        if (self.sessions.contains(session_id)) {
            return try self.makeError(env.session_id, env.message_id, .agent_busy, "session already exists");
        }

        const model = try self.allocator.dupe(u8, "unknown");
        errdefer self.allocator.free(model);
        const config_json = try self.allocator.dupe(u8, req.config_json);
        errdefer self.allocator.free(config_json);
        const system_prompt = try self.allocator.dupe(u8, req.getSystemPrompt() orelse "");
        errdefer self.allocator.free(system_prompt);

        try self.expected_sequences.put(session_id, 2);
        errdefer _ = self.expected_sequences.remove(session_id);
        try self.outgoing_sequences.put(session_id, 0);
        errdefer _ = self.outgoing_sequences.remove(session_id);

        const now = compat.time.nowMillis();
        self.next_session_generation += 1;
        try self.sessions.put(session_id, .{
            .session_id = session_id,
            .status = .ready,
            .model = model,
            .config_json = config_json,
            .system_prompt = system_prompt,
            .message_count = 0,
            .created_at = now,
            .updated_at = now,
            .last_activity_ms = try compat.time.monotonicMillis(),
            .generation = self.next_session_generation,
        });

        return .{
            .session_id = session_id,
            .message_id = agent_types.generateUlid(),
            .sequence = try self.nextOutgoingSequence(session_id),
            .in_reply_to = env.message_id,
            .timestamp = now,
            .payload = .{ .agent_started = .{ .session_id = session_id } },
        };
    }

    fn handleMessage(self: *Self, req: agent_types.AgentMessageRequest, env: agent_types.Envelope) !?agent_types.Envelope {
        // §13.1 (#204): envelope and payload session ids MUST agree — reject
        // before any session lookup, admission, or mutation.
        if (!std.mem.eql(u8, &req.session_id, &env.session_id)) {
            return try self.makeError(env.session_id, env.message_id, .invalid_request, "envelope and payload session_id disagree");
        }

        const session = self.sessions.getPtr(req.session_id) orelse {
            return try self.makeError(env.session_id, env.message_id, .agent_not_found, "session not found");
        };

        const expected = self.expected_sequences.get(req.session_id) orelse 1;
        if (env.sequence != expected) {
            return try self.makeError(env.session_id, env.message_id, .invalid_request, "invalid sequence");
        }

        if (session.status == .processing) {
            return try self.makeError(env.session_id, env.message_id, .agent_busy, "session already processing a message");
        }

        const message_json = try self.allocator.dupe(u8, req.message_json);
        errdefer self.allocator.free(message_json);
        const options_json = try self.allocator.dupe(u8, req.getOptionsJson() orelse "");
        errdefer self.allocator.free(options_json);
        const config_json = try self.allocator.dupe(u8, session.config_json);
        errdefer self.allocator.free(config_json);
        const system_prompt = try self.allocator.dupe(u8, session.system_prompt);
        errdefer self.allocator.free(system_prompt);

        const pending = PendingAgentMessage{
            .session_id = req.session_id,
            .message_json = message_json,
            .options_json = options_json,
            .config_json = config_json,
            .system_prompt = system_prompt,
        };

        try self.expected_sequences.put(req.session_id, expected + 1);
        errdefer self.expected_sequences.put(req.session_id, expected) catch {};
        try self.pending_messages.append(self.allocator, pending);

        session.status = .processing;
        session.message_count += 1;
        try touchSession(session);

        return null;
    }

    fn handleStop(self: *Self, req: agent_types.AgentStopRequest, env: agent_types.Envelope) !?agent_types.Envelope {
        // §13.1 (#204): envelope and payload session ids MUST agree — reject
        // before any lookup or removal, so a mismatched stop can never tear
        // down a session other than its routing identity.
        if (!std.mem.eql(u8, &req.session_id, &env.session_id)) {
            return try self.makeError(env.session_id, env.message_id, .invalid_request, "envelope and payload session_id disagree");
        }

        if (!self.sessions.contains(req.session_id)) {
            return try self.makeError(env.session_id, env.message_id, .agent_not_found, "session not found");
        }

        const expected = self.expected_sequences.get(req.session_id) orelse 1;
        if (env.sequence != expected) {
            return try self.makeError(env.session_id, env.message_id, .invalid_request, "invalid sequence");
        }

        // Build the reply's owned fields BEFORE removing the session
        // (#210 gap 5): the stop transaction is "remove + reply", and an
        // allocation failure while building the reply must strike while the
        // session is still registered — the alternative removed the id and
        // then failed with no `agent_stopped` at all. The remaining failure
        // window (reply serialization/write, outside this server) is one
        // the stdio host cleans up after (§13.4.4).
        const reason = if (req.getReason()) |r| try self.allocator.dupe(u8, r) else try self.allocator.dupe(u8, "stopped");
        errdefer self.allocator.free(reason);
        const stop_sequence = try self.nextOutgoingSequence(req.session_id);
        if (!self.removeSession(req.session_id)) {
            return try self.makeError(env.session_id, env.message_id, .agent_not_found, "session not found");
        }

        return .{
            .session_id = req.session_id,
            .message_id = agent_types.generateUlid(),
            .sequence = stop_sequence,
            .in_reply_to = env.message_id,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .agent_stopped = .{
                .session_id = req.session_id,
                .reason = OwnedSlice(u8).initOwned(reason),
            } },
        };
    }

    fn handleStatus(self: *Self, req: anytype, env: agent_types.Envelope) !?agent_types.Envelope {
        // §13.1 (#204): envelope and payload session ids MUST agree — reject
        // before any lookup (the idleness clock is not touched either).
        if (!std.mem.eql(u8, &req.session_id, &env.session_id)) {
            return try self.makeError(env.session_id, env.message_id, .invalid_request, "envelope and payload session_id disagree");
        }

        const session = self.sessions.getPtr(req.session_id) orelse {
            return try self.makeError(env.session_id, env.message_id, .agent_not_found, "session not found");
        };

        // A status poll is inbound activity: it refreshes the session's
        // idleness clock ahead of TTL eviction (§13.2.6). The reply therefore
        // reports the poll itself as the latest activity.
        try touchSession(session);

        return .{
            .session_id = req.session_id,
            .message_id = agent_types.generateUlid(),
            .sequence = env.sequence,
            .in_reply_to = env.message_id,
            .timestamp = compat.time.nowMillis(),
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

    /// Passthrough model discovery: forwards `models_request` to the provider
    /// protocol via the configured delegate and emits the same typed
    /// `ModelsResponse` shape on the wire (no raw JSON blob passthrough).
    /// See `docs/v1-sdk-agent-provider-spec.md §6`.
    ///
    /// On success: returns an `ack` envelope synchronously and queues the
    /// `models_response` envelope on the outbox. On capability absence or
    /// delegate failure: returns a `nack` envelope with a typed `error_code`.
    fn handleModelsRequest(
        self: *Self,
        request: agent_types.ModelsRequest,
        env: agent_types.Envelope,
    ) !?agent_types.Envelope {
        if (!self.options.supports_model_catalog or self.options.provider_models_delegate == null) {
            return try self.makeModelsNack(
                env.session_id,
                env.message_id,
                .not_implemented,
                "models catalog is not implemented for this runtime",
            );
        }

        const delegate = self.options.provider_models_delegate.?;
        var response = delegate(self.options.provider_models_ctx, self.allocator, request) catch |err| switch (err) {
            error.NotImplemented => return try self.makeModelsNack(
                env.session_id,
                env.message_id,
                .not_implemented,
                "models catalog is not implemented for this runtime",
            ),
            // Spec §6 step 7: when no models match the request filters the
            // protocol mandates `error_code = invalid_request` (NOT
            // `model_not_found`). The `ErrorCode.model_not_found` variant is
            // reserved for future/SDK-internal use — do not "fix" this to use
            // it without first updating the spec.
            error.ModelNotFound => return try self.makeModelsNack(
                env.session_id,
                env.message_id,
                .invalid_request,
                "model not found",
            ),
            error.AmbiguousModelId => return try self.makeModelsNack(
                env.session_id,
                env.message_id,
                .invalid_request,
                "model_id matches multiple APIs; specify api",
            ),
            error.OutOfMemory => return error.OutOfMemory,
            else => return try self.makeModelsNack(
                env.session_id,
                env.message_id,
                .provider_error,
                "failed to build model catalog response",
            ),
        };
        errdefer response.deinit(self.allocator);

        const ack_seq = try self.nextOutgoingSequence(env.session_id);
        const ack_envelope = agent_types.Envelope{
            .session_id = env.session_id,
            .message_id = agent_types.generateUlid(),
            .sequence = ack_seq,
            .in_reply_to = env.message_id,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .ack = .{ .acknowledged_id = env.message_id } },
        };

        const response_seq = try self.nextOutgoingSequence(env.session_id);
        try self.outbox.append(self.allocator, .{
            .session_id = env.session_id,
            .message_id = agent_types.generateUlid(),
            .sequence = response_seq,
            .in_reply_to = env.message_id,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .models_response = response },
        });

        return ack_envelope;
    }

    fn makeModelsNack(
        self: *Self,
        session_id: agent_types.SessionId,
        in_reply_to: agent_types.Ulid,
        code: agent_types.ErrorCode,
        msg: []const u8,
    ) !agent_types.Envelope {
        const reason = try self.allocator.dupe(u8, msg);
        return .{
            .session_id = session_id,
            .message_id = agent_types.generateUlid(),
            .sequence = try self.nextOutgoingSequence(session_id),
            .in_reply_to = in_reply_to,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .nack = .{
                .rejected_id = in_reply_to,
                .reason = OwnedSlice(u8).initOwned(reason),
                .error_code = code,
            } },
        };
    }

    fn makeError(self: *Self, session_id: agent_types.SessionId, in_reply_to: agent_types.Ulid, code: agent_types.AgentErrorCode, msg: []const u8) !agent_types.Envelope {
        return .{
            .session_id = session_id,
            .message_id = agent_types.generateUlid(),
            .sequence = 0,
            .in_reply_to = in_reply_to,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .agent_error = .{
                .code = code,
                .message = try self.allocator.dupe(u8, msg),
            } },
        };
    }

    /// Advances and persists the session's outgoing sequence counter. The
    /// counter update is part of the publication transaction (#210 gap 5):
    /// swallowing a failed `put` would hand out a sequence number that was
    /// never recorded, so the next publication reuses it and two frames go
    /// out with the same sequence.
    pub fn nextOutgoingSequence(self: *Self, session_id: agent_types.SessionId) !u64 {
        const cur = self.outgoing_sequences.get(session_id) orelse 0;
        const next = cur + 1;
        try self.outgoing_sequences.put(session_id, next);
        return next;
    }

    pub fn publishAgentEvent(self: *Self, session_id: agent_types.SessionId, event_json: []const u8) !void {
        const session = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;
        // Transactional enqueue (#210 gap 5): own the copy before touching
        // the outbox, so an append failure under memory pressure propagates
        // without leaking the copy and leaves the outbox unchanged — the
        // caller's retry re-attempts the whole publication.
        const owned_json = try self.allocator.dupe(u8, event_json);
        errdefer self.allocator.free(owned_json);
        // Run activity (event publication) refreshes the idleness clock
        // ahead of TTL eviction (§13.2.6).
        try touchSession(session);
        try self.outbox.append(self.allocator, .{
            .session_id = session_id,
            .message_id = agent_types.generateUlid(),
            .sequence = try self.nextOutgoingSequence(session_id),
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .agent_event = owned_json },
        });
    }

    pub fn publishAgentResult(self: *Self, session_id: agent_types.SessionId, result_json: []const u8) !void {
        const session = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;
        const owned_json = try self.allocator.dupe(u8, result_json);
        errdefer self.allocator.free(owned_json);
        try touchSession(session);
        try self.outbox.append(self.allocator, .{
            .session_id = session_id,
            .message_id = agent_types.generateUlid(),
            .sequence = try self.nextOutgoingSequence(session_id),
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .agent_result = owned_json },
        });
        // The status follows the COMMITTED frame (#210 gap 5, review):
        // flipping `.ready` before the append admitted a follow-up
        // `agent_message` while the result publication was still pending —
        // the retained run then tripped the one-active-run rule and turned
        // the ACCEPTED message into an `AgentBusy` internal-error
        // settlement. With the flip after the append, a failed publication
        // leaves the session `.processing`: follow-ups are rejected
        // `agent_busy` at admission (clean non-admission) until the retry
        // commits.
        session.status = .ready;
    }

    pub fn publishAgentError(self: *Self, session_id: agent_types.SessionId, code: agent_types.AgentErrorCode, message: []const u8) !void {
        const session = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;
        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);
        try touchSession(session);
        try self.outbox.append(self.allocator, .{
            .session_id = session_id,
            .message_id = agent_types.generateUlid(),
            .sequence = try self.nextOutgoingSequence(session_id),
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .agent_error = .{
                .code = code,
                .message = owned_message,
            } },
        });
        // Same commit-then-flip ordering as `publishAgentResult`: while the
        // settlement envelope's publication is being retried the session
        // stays non-admissible (`.processing`) instead of `.error`.
        session.status = .@"error";
    }

    pub fn enqueueEnvelope(self: *Self, env: agent_types.Envelope) !void {
        try self.outbox.append(self.allocator, env);
    }

    pub fn popOutbound(self: *Self) ?agent_types.Envelope {
        if (self.outbox.items.len == 0) return null;
        return self.outbox.orderedRemove(0);
    }

    /// The head of the outbox WITHOUT removing it — the read side of the
    /// transactional delivery handshake (#210 gap 5): the runtime peeks,
    /// serializes, writes, and only then pops, so a serialization or write
    /// failure leaves the already-built frame queued for the next pump
    /// instead of destroying it (`popOutbound` alone dropped it).
    pub fn peekOutbound(self: *Self) ?*agent_types.Envelope {
        if (self.outbox.items.len == 0) return null;
        return &self.outbox.items[0];
    }

    pub fn popPendingAgentMessage(self: *Self) ?PendingAgentMessage {
        if (self.pending_messages.items.len == 0) return null;
        return self.pending_messages.orderedRemove(0);
    }

    pub fn hasSession(self: *Self, session_id: agent_types.SessionId) bool {
        return self.sessions.contains(session_id);
    }

    /// The registration generation of the currently registered session
    /// (§13.4.5, #204), or null when the id is not registered. A run binds the
    /// value at its start and compares against this to detect staleness: a
    /// null (stopped/evicted id) or a different value (id re-registered)
    /// means the run's remaining publications must be discarded.
    pub fn sessionGeneration(self: *Self, session_id: agent_types.SessionId) ?u64 {
        const session = self.sessions.get(session_id) orelse return null;
        return session.generation;
    }

    pub fn updateSessionModel(self: *Self, session_id: agent_types.SessionId, model: []const u8) !void {
        const session = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;
        const next = try self.allocator.dupe(u8, model);
        self.allocator.free(session.model);
        session.model = next;
        try touchSession(session);
    }

    pub fn markSessionError(self: *Self, session_id: agent_types.SessionId) !void {
        if (self.sessions.getPtr(session_id)) |session| {
            session.status = .@"error";
            try touchSession(session);
        }
    }

    /// Stamps both activity clocks on a session: the wall-clock `updated_at`
    /// (protocol-visible in `session_info`) and the monotonic
    /// `last_activity_ms` (the TTL idleness clock, §13.2.6 — immune to
    /// wall-clock adjustments).
    fn touchSession(session: *SessionState) !void {
        session.updated_at = compat.time.nowMillis();
        session.last_activity_ms = try compat.time.monotonicMillis();
    }

    /// Removes a session together with every piece of bookkeeping tied to it:
    /// the state container (freeing its owned strings), the expected/outgoing
    /// sequence entries, and any still-queued pending messages. `agent_stop`
    /// handling and idle-TTL eviction (§13.2.6) share this removal so an
    /// evicted id is indistinguishable from a stopped one. Returns false when
    /// the id is not registered.
    fn removeSession(self: *Self, session_id: agent_types.SessionId) bool {
        const removed = self.sessions.fetchRemove(session_id) orelse return false;
        self.allocator.free(removed.value.model);
        self.allocator.free(removed.value.config_json);
        self.allocator.free(removed.value.system_prompt);
        _ = self.expected_sequences.remove(session_id);
        _ = self.outgoing_sequences.remove(session_id);
        self.removePendingMessages(session_id);
        return true;
    }

    /// Evicts every session idle longer than the configured TTL, appending
    /// the evicted ids to `evicted_out` and returning how many THIS call
    /// appended (spec §13.2.6 rule 6). Idleness is measured on the monotonic
    /// clock (`now_mono_ms` is a `compat.time.monotonicMillis` reading —
    /// hosts pass a live one, tests pass a synthetic time) from the session's
    /// last activity — inbound (`agent_message` acceptance, `agent_status`
    /// poll) or server-side run publication (`agent_event`, `agent_result`,
    /// `agent_error`) — and only strictly exceeds the TTL. The wall clock is
    /// deliberately not consulted: NTP steps or snapshot restores must not
    /// evict fresh sessions or strand stale ones. Eviction requires no client
    /// participation: the evicted id behaves exactly like a stopped one — the
    /// next `agent_message`/`agent_stop`/`agent_status` fails with
    /// `agent_not_found`, and a fresh `agent_start` registers a new container
    /// (whose output can still be confused with the old registration's
    /// buffered publications — the §13.4.5 id-reuse race, shared with
    /// `agent_stop` and closed for both by #204's generation/tombstone
    /// tokens).
    ///
    /// The admission-vs-eviction race (§13.2.6 rule 6) is closed server-side
    /// by construction in every current host: admission (`handleMessage`)
    /// sets `.processing` synchronously before accepting, admission and this
    /// sweep run serialized on the host's single pump thread, and the stdio
    /// run pump already cancels any run whose session disappeared (the
    /// `agent_stop` path) with post-removal publications surfacing as
    /// swallowed `SessionNotFound` no-ops. A session is therefore either
    /// `.processing` (never selected here — a long-running turn or tool
    /// execution cannot be evicted out from under its run) or removed before
    /// its message arrives (the request fails with `agent_not_found`, no run
    /// admitted). Multi-threaded hosts must preserve this serialization
    /// before sweeping.
    ///
    /// Eligible ids are collected in one traversal and removed afterwards
    /// (removing mid-iteration would invalidate the map iterator, and
    /// rescanning per removal would cost one full pass per expired session
    /// when many expire together — time the single pump thread cannot
    /// spare). Only the ids this call appended are removed, so callers may
    /// reuse the list across sweeps. If collecting exhausts the allocator,
    /// the batch collected so far is STILL evicted before the error
    /// propagates — dropping it would wedge the sweep under the very memory
    /// pressure eviction exists to relieve; the error signals an incomplete
    /// sweep, and the next sweep retries what remains.
    pub fn evictIdleSessions(
        self: *Self,
        now_mono_ms: i64,
        evicted_out: *std.ArrayList(agent_types.SessionId),
    ) !usize {
        if (self.options.session_idle_ttl_ms == 0) return 0;
        const ttl_ms = self.options.session_idle_ttl_ms;

        const first_new = evicted_out.items.len;
        var collect_err: ?anyerror = null;
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr;
            // In-flight runs (admitted or executing) are never idle.
            if (session.status == .processing) continue;
            // A reading older than the stamp (possible only with a synthetic
            // test clock) reads as zero idle time; "idle longer than the
            // TTL" is strict.
            const idle_ms: u64 = if (now_mono_ms > session.last_activity_ms)
                @intCast(now_mono_ms - session.last_activity_ms)
            else
                0;
            if (idle_ms > ttl_ms) {
                evicted_out.append(self.allocator, entry.key_ptr.*) catch |err| {
                    collect_err = err;
                    break;
                };
            }
        }

        for (evicted_out.items[first_new..]) |session_id| {
            _ = self.removeSession(session_id);
        }
        if (collect_err) |err| return err;
        return evicted_out.items.len - first_new;
    }

    fn removePendingMessages(self: *Self, session_id: agent_types.SessionId) void {
        var idx: usize = 0;
        while (idx < self.pending_messages.items.len) {
            if (std.mem.eql(u8, &self.pending_messages.items[idx].session_id, &session_id)) {
                var removed = self.pending_messages.orderedRemove(idx);
                removed.deinit(self.allocator);
                continue;
            }
            idx += 1;
        }
    }
};

test "AgentProtocolServer rejects invalid start sequence" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    var start = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_start = .{ .config_json = try allocator.dupe(u8, "{}") } },
    };
    defer start.deinit(allocator);

    var resp = (try server.handleEnvelope(start)).?;
    defer resp.deinit(allocator);

    try std.testing.expect(resp.payload == .agent_error);
    try std.testing.expectEqual(agent_types.AgentErrorCode.invalid_request, resp.payload.agent_error.code);
}

test "AgentProtocolServer rejects unknown session message" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    const sid = agent_types.generateSessionId();
    var msg = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_message = .{
            .session_id = sid,
            .message_json = try allocator.dupe(u8, "{\"role\":\"user\"}"),
        } },
    };
    defer msg.deinit(allocator);

    var resp = (try server.handleEnvelope(msg)).?;
    defer resp.deinit(allocator);

    try std.testing.expect(resp.payload == .agent_error);
    try std.testing.expectEqual(agent_types.AgentErrorCode.agent_not_found, resp.payload.agent_error.code);
}

fn registerTestSession(server: *AgentProtocolServer, allocator: std.mem.Allocator) !agent_types.SessionId {
    var start = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_start = .{ .config_json = try allocator.dupe(u8, "{}") } },
    };
    defer start.deinit(allocator);

    var resp = (try server.handleEnvelope(start)).?;
    defer resp.deinit(allocator);
    try std.testing.expect(resp.payload == .agent_started);
    return resp.payload.agent_started.session_id;
}

// #210 gap 5: a publication that fails partway (dupe succeeds, outbox
// append hits OOM) must leave the outbox UNCHANGED, leak nothing, and leave
// the session status untouched — the status flips only after the frame
// commits, so a failed publication keeps the session non-admissible
// (`.processing`) until the retry succeeds. Sweeping fail_index covers
// every allocation of each publish path; the std.testing.allocator's leak
// check guards the copies.
test "AgentProtocolServer publish paths are transactional under allocation failure" {
    const allocator = std.testing.allocator;

    inline for (.{
        .{ .publish = publishAgentEventCase, .success_status = agent_types.AgentStatus.processing },
        .{ .publish = publishAgentResultCase, .success_status = agent_types.AgentStatus.ready },
        .{ .publish = publishAgentErrorCase, .success_status = agent_types.AgentStatus.@"error" },
    }) |case| {
        var fail_index: usize = 0;
        while (fail_index <= 6) : (fail_index += 1) {
            var server = AgentProtocolServer.init(allocator);
            defer server.deinit();
            const sid = try registerTestSession(&server, allocator);
            server.sessions.getPtr(sid).?.status = .processing;

            var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
            // Re-point the server's allocator at the failing wrapper: the
            // session map itself is already populated, so only the
            // publication's allocations can fail.
            server.allocator = failing.allocator();
            if (case.publish(&server, sid)) |_| {
                var popped = server.popOutbound().?;
                popped.deinit(allocator);
                try std.testing.expect(server.popOutbound() == null);
                try std.testing.expectEqual(case.success_status, server.sessions.getPtr(sid).?.status);
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                // The append failed atomically: no half-queued frame, no
                // status flip.
                try std.testing.expect(server.popOutbound() == null);
                try std.testing.expectEqual(agent_types.AgentStatus.processing, server.sessions.getPtr(sid).?.status);
            }
        }
    }
}

fn publishAgentEventCase(server: *AgentProtocolServer, sid: agent_types.SessionId) !void {
    try server.publishAgentEvent(sid, "{\"type\":\"message_update\"}");
}

fn publishAgentResultCase(server: *AgentProtocolServer, sid: agent_types.SessionId) !void {
    try server.publishAgentResult(sid, "{\"messages\":[]}");
}

fn publishAgentErrorCase(server: *AgentProtocolServer, sid: agent_types.SessionId) !void {
    try server.publishAgentError(sid, .internal_error, "fixture failure");
}

// #210 gap 5: the outgoing-sequence counter update must not be swallowed —
// a failed counter write returning a number anyway would hand the SAME
// sequence to the next frame.
test "AgentProtocolServer nextOutgoingSequence propagates counter-write failure" {
    const allocator = std.testing.allocator;

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var server = AgentProtocolServer.init(failing.allocator());
    defer server.deinit();

    const sid = agent_types.generateSessionId();
    try std.testing.expectError(error.OutOfMemory, server.nextOutgoingSequence(sid));
}

// ============================================================================
// Models passthrough test fixtures (M-005)
// ============================================================================

const ModelsTestCtx = struct {
    response_models: []const struct {
        model_ref: []const u8,
        model_id: []const u8,
        display_name: []const u8,
        provider_id: []const u8,
        api: []const u8,
        source: agent_types.ModelSource,
    },
    fetched_at_ms: i64,
    cache_max_age_ms: u64,
    saw_provider_id: ?[]const u8 = null,
    error_to_return: ?anyerror = null,
    call_count: usize = 0,
};

fn modelsTestDelegate(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: agent_types.ModelsRequest,
) anyerror!agent_types.ModelsResponse {
    const test_ctx = @as(*ModelsTestCtx, @ptrCast(@alignCast(ctx.?)));
    test_ctx.call_count += 1;
    test_ctx.saw_provider_id = request.getProviderId();

    if (test_ctx.error_to_return) |err| {
        return err;
    }

    const descriptors = try allocator.alloc(agent_types.ModelDescriptor, test_ctx.response_models.len);
    var allocated_count: usize = 0;
    errdefer {
        for (descriptors[0..allocated_count]) |*d| d.deinit(allocator);
        allocator.free(descriptors);
    }

    for (test_ctx.response_models, 0..) |model, idx| {
        const capabilities = try allocator.alloc(agent_types.ModelCapability, 1);
        capabilities[0] = .chat;

        descriptors[idx] = .{
            .model_ref = OwnedSlice(u8).initOwned(try allocator.dupe(u8, model.model_ref)),
            .model_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, model.model_id)),
            .display_name = OwnedSlice(u8).initOwned(try allocator.dupe(u8, model.display_name)),
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, model.provider_id)),
            .api = OwnedSlice(u8).initOwned(try allocator.dupe(u8, model.api)),
            .auth_status = .authenticated,
            .lifecycle = .stable,
            .capabilities = OwnedSlice(agent_types.ModelCapability).initOwned(capabilities),
            .source = model.source,
        };
        allocated_count += 1;
    }

    return .{
        .models = OwnedSlice(agent_types.ModelDescriptor).initOwned(descriptors),
        .fetched_at_ms = test_ctx.fetched_at_ms,
        .cache_max_age_ms = test_ctx.cache_max_age_ms,
    };
}

test "handleModelsRequest emits ack then models_response with same shape as provider protocol" {
    const allocator = std.testing.allocator;

    var ctx = ModelsTestCtx{
        .response_models = &.{
            .{
                .model_ref = "anthropic/anthropic-messages@claude-sonnet-4-5",
                .model_id = "claude-sonnet-4-5",
                .display_name = "Claude Sonnet 4.5",
                .provider_id = "anthropic",
                .api = "anthropic-messages",
                .source = .dynamic,
            },
        },
        .fetched_at_ms = 1_700_000_000_000,
        .cache_max_age_ms = 300_000,
    };

    var server = AgentProtocolServer.initWithOptions(allocator, .{
        .supports_model_catalog = true,
        .provider_models_delegate = modelsTestDelegate,
        .provider_models_ctx = @ptrCast(&ctx),
    });
    defer server.deinit();

    var request = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_request = .{
            .provider_id = OwnedSlice(u8).initBorrowed("anthropic"),
        } },
    };
    defer request.deinit(allocator);

    const maybe_ack = try server.handleEnvelope(request);
    try std.testing.expect(maybe_ack != null);
    var ack = maybe_ack.?;
    defer ack.deinit(allocator);

    try std.testing.expect(ack.payload == .ack);
    try std.testing.expectEqual(@as(u64, 1), ack.sequence);
    try std.testing.expectEqualSlices(u8, &request.message_id, &ack.payload.ack.acknowledged_id);
    try std.testing.expectEqualSlices(u8, &request.message_id, &ack.in_reply_to.?);

    const maybe_response = server.popOutbound();
    try std.testing.expect(maybe_response != null);
    var response = maybe_response.?;
    defer response.deinit(allocator);

    try std.testing.expect(response.payload == .models_response);
    try std.testing.expectEqual(@as(u64, 2), response.sequence);
    try std.testing.expectEqualSlices(u8, &request.message_id, &response.in_reply_to.?);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), response.payload.models_response.fetched_at_ms);
    try std.testing.expectEqual(@as(u64, 300_000), response.payload.models_response.cache_max_age_ms);

    const models = response.payload.models_response.models.slice();
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", models[0].model_id.slice());
    try std.testing.expectEqualStrings("anthropic", models[0].provider_id.slice());
    try std.testing.expectEqualStrings("anthropic-messages", models[0].api.slice());
    try std.testing.expectEqual(agent_types.ModelSource.dynamic, models[0].source);

    try std.testing.expectEqual(@as(usize, 1), ctx.call_count);
    try std.testing.expectEqualStrings("anthropic", ctx.saw_provider_id.?);

    // Outbox should now be empty
    try std.testing.expect(server.popOutbound() == null);
}

test "handleModelsRequest returns not_implemented nack when unsupported" {
    const allocator = std.testing.allocator;

    var server = AgentProtocolServer.initWithOptions(allocator, .{
        .supports_model_catalog = false,
    });
    defer server.deinit();

    var request = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_request = .{} },
    };
    defer request.deinit(allocator);

    const maybe_response = try server.handleEnvelope(request);
    try std.testing.expect(maybe_response != null);
    var response = maybe_response.?;
    defer response.deinit(allocator);

    try std.testing.expect(response.payload == .nack);
    try std.testing.expectEqual(agent_types.ErrorCode.not_implemented, response.payload.nack.error_code.?);
    try std.testing.expectEqualSlices(u8, &request.message_id, &response.payload.nack.rejected_id);
    try std.testing.expect(server.popOutbound() == null);
}

test "handleModelsRequest returns not_implemented nack when delegate is missing" {
    const allocator = std.testing.allocator;

    // supports_model_catalog defaults to true, but no delegate is configured
    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    var request = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_request = .{} },
    };
    defer request.deinit(allocator);

    const maybe_response = try server.handleEnvelope(request);
    try std.testing.expect(maybe_response != null);
    var response = maybe_response.?;
    defer response.deinit(allocator);

    try std.testing.expect(response.payload == .nack);
    try std.testing.expectEqual(agent_types.ErrorCode.not_implemented, response.payload.nack.error_code.?);
    try std.testing.expect(server.popOutbound() == null);
}

test "handleModelsRequest maps delegate NotImplemented error to not_implemented nack" {
    const allocator = std.testing.allocator;

    var ctx = ModelsTestCtx{
        .response_models = &.{},
        .fetched_at_ms = 0,
        .cache_max_age_ms = 0,
        .error_to_return = error.NotImplemented,
    };

    var server = AgentProtocolServer.initWithOptions(allocator, .{
        .provider_models_delegate = modelsTestDelegate,
        .provider_models_ctx = @ptrCast(&ctx),
    });
    defer server.deinit();

    var request = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_request = .{} },
    };
    defer request.deinit(allocator);

    const maybe_response = try server.handleEnvelope(request);
    try std.testing.expect(maybe_response != null);
    var response = maybe_response.?;
    defer response.deinit(allocator);

    try std.testing.expect(response.payload == .nack);
    try std.testing.expectEqual(agent_types.ErrorCode.not_implemented, response.payload.nack.error_code.?);
    try std.testing.expect(server.popOutbound() == null);
}

test "AgentProtocolServer start message status stop" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    var start = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_start = .{ .config_json = try allocator.dupe(u8, "{}") } },
    };
    defer start.deinit(allocator);

    var start_resp = (try server.handleEnvelope(start)).?;
    defer start_resp.deinit(allocator);
    try std.testing.expect(start_resp.payload == .agent_started);

    const sid = start_resp.payload.agent_started.session_id;

    var msg = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_message = .{
            .session_id = sid,
            .message_json = try allocator.dupe(u8, "{\"role\":\"user\"}"),
        } },
    };
    defer msg.deinit(allocator);
    try std.testing.expect((try server.handleEnvelope(msg)) == null);

    var status = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_status = .{ .session_id = sid } },
    };
    defer status.deinit(allocator);

    var status_resp = (try server.handleEnvelope(status)).?;
    defer status_resp.deinit(allocator);
    try std.testing.expect(status_resp.payload == .session_info);
    try std.testing.expectEqual(@as(u32, 1), status_resp.payload.session_info.message_count);

    var stop = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 3,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_stop = .{ .session_id = sid } },
    };
    defer stop.deinit(allocator);

    var stop_resp = (try server.handleEnvelope(stop)).?;
    defer stop_resp.deinit(allocator);
    try std.testing.expect(stop_resp.payload == .agent_stopped);
}

test "AgentProtocolServer uses outgoing sequence for stop after published events" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    const sid = agent_types.generateSessionId();
    var start = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_start = .{
            .session_id = sid,
            .config_json = try allocator.dupe(u8, "{}"),
        } },
    };
    defer start.deinit(allocator);

    var start_resp = (try server.handleEnvelope(start)).?;
    defer start_resp.deinit(allocator);
    try std.testing.expect(start_resp.payload == .agent_started);
    try std.testing.expectEqual(@as(u64, 1), start_resp.sequence);

    try server.publishAgentEvent(sid, "{}");
    var event = server.popOutbound().?;
    defer event.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), event.sequence);

    var stop = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_stop = .{ .session_id = sid } },
    };
    defer stop.deinit(allocator);

    var stop_resp = (try server.handleEnvelope(stop)).?;
    defer stop_resp.deinit(allocator);
    try std.testing.expect(stop_resp.payload == .agent_stopped);
    try std.testing.expectEqual(@as(u64, 3), stop_resp.sequence);
}

test "AgentProtocolServer rejects out-of-order stop without removing session" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    const sid = agent_types.generateSessionId();
    var start = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_start = .{
            .session_id = sid,
            .config_json = try allocator.dupe(u8, "{}"),
        } },
    };
    defer start.deinit(allocator);

    var start_resp = (try server.handleEnvelope(start)).?;
    defer start_resp.deinit(allocator);
    try std.testing.expect(start_resp.payload == .agent_started);

    const stale_stop = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_stop = .{ .session_id = sid } },
    };

    var stop_resp = (try server.handleEnvelope(stale_stop)).?;
    defer stop_resp.deinit(allocator);
    try std.testing.expect(stop_resp.payload == .agent_error);
    try std.testing.expectEqual(agent_types.AgentErrorCode.invalid_request, stop_resp.payload.agent_error.code);
    try std.testing.expectEqual(@as(usize, 1), server.sessionCount());
    try std.testing.expect(server.hasSession(sid));
}

// ============================================================================
// Envelope/payload session-id agreement (spec §13.1, #204 gap 1)
// ============================================================================

/// Registers a session under an explicit caller-supplied id (envelope and
/// payload ids agreeing, as §13.1 requires of clients).
fn startTestSessionWithId(server: *AgentProtocolServer, allocator: std.mem.Allocator, session_id: agent_types.SessionId) !void {
    var start = agent_types.Envelope{
        .session_id = session_id,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_start = .{
            .session_id = session_id,
            .config_json = try allocator.dupe(u8, "{}"),
        } },
    };
    defer start.deinit(allocator);

    var resp = (try server.handleEnvelope(start)).?;
    defer resp.deinit(allocator);
    try std.testing.expect(resp.payload == .agent_started);
}

test "AgentProtocolServer rejects agent_start whose envelope and payload session ids disagree" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    var start = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_start = .{
            .session_id = agent_types.generateSessionId(),
            .config_json = try allocator.dupe(u8, "{}"),
        } },
    };
    defer start.deinit(allocator);

    var resp = (try server.handleEnvelope(start)).?;
    defer resp.deinit(allocator);

    try std.testing.expect(resp.payload == .agent_error);
    try std.testing.expectEqual(agent_types.AgentErrorCode.invalid_request, resp.payload.agent_error.code);
    // Rejected before any mutation: neither the envelope id nor the payload
    // id owns a session afterwards.
    try std.testing.expectEqual(@as(usize, 0), server.sessionCount());
}

test "AgentProtocolServer rejects agent_message id mismatch without mutating the session" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    const sid = agent_types.generateSessionId();
    try startTestSessionWithId(&server, allocator, sid);

    var msg = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_message = .{
            .session_id = sid,
            .message_json = try allocator.dupe(u8, "{\"role\":\"user\"}"),
        } },
    };
    defer msg.deinit(allocator);

    var resp = (try server.handleEnvelope(msg)).?;
    defer resp.deinit(allocator);
    try std.testing.expect(resp.payload == .agent_error);
    try std.testing.expectEqual(agent_types.AgentErrorCode.invalid_request, resp.payload.agent_error.code);

    // No mutation occurred: the expected inbound sequence was not consumed,
    // so the next well-formed message (ids agreeing) is accepted at the same
    // value.
    var valid = try makeTestAgentMessage(sid, 2, allocator);
    defer valid.deinit(allocator);
    try std.testing.expect((try server.handleEnvelope(valid)) == null);
    try std.testing.expectEqual(agent_types.AgentStatus.processing, server.sessions.get(sid).?.status);
}

test "AgentProtocolServer rejects agent_stop id mismatch without removing the session" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    const sid = agent_types.generateSessionId();
    try startTestSessionWithId(&server, allocator, sid);

    var stop = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_stop = .{ .session_id = sid } },
    };
    defer stop.deinit(allocator);

    var resp = (try server.handleEnvelope(stop)).?;
    defer resp.deinit(allocator);
    try std.testing.expect(resp.payload == .agent_error);
    try std.testing.expectEqual(agent_types.AgentErrorCode.invalid_request, resp.payload.agent_error.code);
    try std.testing.expect(server.hasSession(sid));

    // The payload-id session survived; a valid stop still tears it down at
    // the same expected sequence.
    var valid = makeTestAgentStop(sid, 2);
    defer valid.deinit(allocator);
    var valid_resp = (try server.handleEnvelope(valid)).?;
    defer valid_resp.deinit(allocator);
    try std.testing.expect(valid_resp.payload == .agent_stopped);
    try std.testing.expect(!server.hasSession(sid));
}

test "AgentProtocolServer rejects agent_status id mismatch" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    const sid = agent_types.generateSessionId();
    try startTestSessionWithId(&server, allocator, sid);

    var status = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 5,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_status = .{ .session_id = sid } },
    };
    defer status.deinit(allocator);

    var resp = (try server.handleEnvelope(status)).?;
    defer resp.deinit(allocator);
    try std.testing.expect(resp.payload == .agent_error);
    try std.testing.expectEqual(agent_types.AgentErrorCode.invalid_request, resp.payload.agent_error.code);
    try std.testing.expect(server.hasSession(sid));
    try std.testing.expectEqual(agent_types.AgentStatus.ready, server.sessions.get(sid).?.status);
}

// ============================================================================
// Registration generations (spec §13.4.5, #204 gap 3)
// ============================================================================

test "AgentProtocolServer registration generations are strictly increasing across re-registration" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    const sid_a = agent_types.generateSessionId();
    const sid_b = agent_types.generateSessionId();
    try startTestSessionWithId(&server, allocator, sid_a);
    const gen_a1 = server.sessionGeneration(sid_a).?;
    try std.testing.expectEqual(@as(u64, 1), gen_a1);

    // Stamps are unique across ids, not just per id.
    try startTestSessionWithId(&server, allocator, sid_b);
    const gen_b = server.sessionGeneration(sid_b).?;
    try std.testing.expect(gen_b > gen_a1);

    // Stop + re-register the same id: the new registration out-generates the
    // old one, so a run still draining for the old registration is stale.
    var stop = makeTestAgentStop(sid_a, 2);
    defer stop.deinit(allocator);
    var stop_resp = (try server.handleEnvelope(stop)).?;
    defer stop_resp.deinit(allocator);
    try std.testing.expect(stop_resp.payload == .agent_stopped);
    try std.testing.expect(server.sessionGeneration(sid_a) == null);

    try startTestSessionWithId(&server, allocator, sid_a);
    const gen_a2 = server.sessionGeneration(sid_a).?;
    try std.testing.expect(gen_a2 > gen_b);
    try std.testing.expect(gen_a2 > gen_a1);
}

// ============================================================================
// Echo-reply sequencing (spec §13.1, #204 gap 2 — decision (b): keep + ledger)
// ============================================================================

test "AgentProtocolServer echo replies copy the inbound sequence without consuming the outbound counter" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    const sid = agent_types.generateSessionId();

    // Allocated frame: agent_started draws the per-session outbound counter.
    var start = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_start = .{
            .session_id = sid,
            .config_json = try allocator.dupe(u8, "{}"),
        } },
    };
    defer start.deinit(allocator);
    var start_resp = (try server.handleEnvelope(start)).?;
    defer start_resp.deinit(allocator);
    try std.testing.expect(start_resp.payload == .agent_started);
    try std.testing.expectEqual(@as(u64, 1), start_resp.sequence);

    // Echo frame: session_info copies the request's inbound sequence
    // verbatim (a correlation echo, not an ordering allocation) — here 7,
    // deliberately out of band from every allocated value.
    var status = makeTestAgentStatus(sid, 7);
    defer status.deinit(allocator);
    var status_resp = (try server.handleEnvelope(status)).?;
    defer status_resp.deinit(allocator);
    try std.testing.expect(status_resp.payload == .session_info);
    try std.testing.expectEqual(@as(u64, 7), status_resp.sequence);

    // The echo consumed no allocation: the next allocated frame still gets
    // the counter's next value.
    try server.publishAgentEvent(sid, "{}");
    var event = server.popOutbound().?;
    defer event.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), event.sequence);
}

// ============================================================================
// Idle-session TTL eviction (spec §13.2.6 rule 6, #202)
// ============================================================================

fn startTestSession(server: *AgentProtocolServer, allocator: std.mem.Allocator) !agent_types.SessionId {
    var start = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_start = .{ .config_json = try allocator.dupe(u8, "{}") } },
    };
    defer start.deinit(allocator);

    var resp = (try server.handleEnvelope(start)).?;
    defer resp.deinit(allocator);
    try std.testing.expect(resp.payload == .agent_started);
    return resp.payload.agent_started.session_id;
}

fn makeTestAgentMessage(session_id: agent_types.SessionId, sequence: u64, allocator: std.mem.Allocator) !agent_types.Envelope {
    return .{
        .session_id = session_id,
        .message_id = agent_types.generateUlid(),
        .sequence = sequence,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_message = .{
            .session_id = session_id,
            .message_json = try allocator.dupe(u8, "{\"role\":\"user\"}"),
        } },
    };
}

fn makeTestAgentStatus(session_id: agent_types.SessionId, sequence: u64) agent_types.Envelope {
    return .{
        .session_id = session_id,
        .message_id = agent_types.generateUlid(),
        .sequence = sequence,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_status = .{ .session_id = session_id } },
    };
}

fn makeTestAgentStop(session_id: agent_types.SessionId, sequence: u64) agent_types.Envelope {
    return .{
        .session_id = session_id,
        .message_id = agent_types.generateUlid(),
        .sequence = sequence,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_stop = .{ .session_id = session_id } },
    };
}

test "AgentProtocolServer evicts idle sessions past the TTL with agent_not_found after" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    const sid = try startTestSession(&server, allocator);
    const idle_since = server.sessions.get(sid).?.last_activity_ms;
    const default_ttl: i64 = @intCast(default_session_idle_ttl_ms);
    var evicted = std.ArrayList(agent_types.SessionId).empty;
    defer evicted.deinit(allocator);

    // "Idle longer than the TTL" is strict: at exactly the TTL the session
    // survives, one millisecond past it the sweep removes it.
    try std.testing.expectEqual(@as(usize, 0), try server.evictIdleSessions(idle_since + default_ttl, &evicted));
    try std.testing.expect(server.hasSession(sid));
    try std.testing.expectEqual(@as(usize, 1), try server.evictIdleSessions(idle_since + default_ttl + 1, &evicted));
    try std.testing.expectEqual(@as(usize, 1), evicted.items.len);
    try std.testing.expectEqualSlices(u8, sid[0..], evicted.items[0][0..]);
    try std.testing.expect(!server.hasSession(sid));
    try std.testing.expectEqual(@as(usize, 0), server.sessionCount());

    // An evicted id is indistinguishable from a stopped one: the next
    // session-scoped request fails with agent_not_found...
    var msg = try makeTestAgentMessage(sid, 2, allocator);
    defer msg.deinit(allocator);
    var msg_resp = (try server.handleEnvelope(msg)).?;
    defer msg_resp.deinit(allocator);
    try std.testing.expect(msg_resp.payload == .agent_error);
    try std.testing.expectEqual(agent_types.AgentErrorCode.agent_not_found, msg_resp.payload.agent_error.code);

    // ...and a fresh agent_start on the id registers a new container.
    var restart = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_start = .{
            .session_id = sid,
            .config_json = try allocator.dupe(u8, "{}"),
        } },
    };
    defer restart.deinit(allocator);
    var restart_resp = (try server.handleEnvelope(restart)).?;
    defer restart_resp.deinit(allocator);
    try std.testing.expect(restart_resp.payload == .agent_started);
    try std.testing.expectEqual(@as(usize, 1), server.sessionCount());
}

test "AgentProtocolServer never evicts sessions with in-flight runs or recent activity" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    const sid = try startTestSession(&server, allocator);
    var evicted = std.ArrayList(agent_types.SessionId).empty;
    defer evicted.deinit(allocator);

    // A session with an in-flight run (admitted message, status
    // `.processing`) is never idle: even a sweep far past the TTL leaves it
    // alone, so a long-running turn cannot be evicted mid-run.
    var msg = try makeTestAgentMessage(sid, 2, allocator);
    defer msg.deinit(allocator);
    try std.testing.expect((try server.handleEnvelope(msg)) == null);
    try std.testing.expectEqual(@as(usize, 0), try server.evictIdleSessions((try compat.time.monotonicMillis()) + 100 * 365 * 24 * 60 * 60 * 1_000, &evicted));
    try std.testing.expect(server.hasSession(sid));

    // Settlement returns the session to `.ready` and resets the idle clock:
    // at exactly one TTL after the settlement it still survives.
    try server.publishAgentResult(sid, "{\"messages\":[]}");
    const settled_at = server.sessions.get(sid).?.last_activity_ms;
    const default_ttl: i64 = @intCast(default_session_idle_ttl_ms);
    try std.testing.expectEqual(@as(usize, 0), try server.evictIdleSessions(settled_at + default_ttl, &evicted));
    try std.testing.expect(server.hasSession(sid));

    // The multi-message conversation continues on the same session.
    var msg2 = try makeTestAgentMessage(sid, 3, allocator);
    defer msg2.deinit(allocator);
    try std.testing.expect((try server.handleEnvelope(msg2)) == null);
    try std.testing.expectEqual(@as(usize, 1), server.sessionCount());

    // A status poll is inbound activity and refreshes the idleness clock.
    const before_poll = try compat.time.monotonicMillis();
    var status = makeTestAgentStatus(sid, 4);
    defer status.deinit(allocator);
    var status_resp = (try server.handleEnvelope(status)).?;
    defer status_resp.deinit(allocator);
    try std.testing.expect(status_resp.payload == .session_info);
    try std.testing.expect(server.sessions.get(sid).?.last_activity_ms >= before_poll);
}

test "AgentProtocolServer session TTL is configurable and can be disabled" {
    const allocator = std.testing.allocator;

    {
        var server = AgentProtocolServer.initWithOptions(allocator, .{ .session_idle_ttl_ms = 100 });
        defer server.deinit();

        const sid = try startTestSession(&server, allocator);
        const idle_since = server.sessions.get(sid).?.last_activity_ms;
        var evicted = std.ArrayList(agent_types.SessionId).empty;
        defer evicted.deinit(allocator);

        try std.testing.expectEqual(@as(usize, 0), try server.evictIdleSessions(idle_since + 100, &evicted));
        try std.testing.expect(server.hasSession(sid));
        try std.testing.expectEqual(@as(usize, 1), try server.evictIdleSessions(idle_since + 101, &evicted));
        try std.testing.expect(!server.hasSession(sid));
    }

    {
        var server = AgentProtocolServer.initWithOptions(allocator, .{ .session_idle_ttl_ms = 0 });
        defer server.deinit();

        const sid = try startTestSession(&server, allocator);
        const idle_since = server.sessions.get(sid).?.last_activity_ms;
        var evicted = std.ArrayList(agent_types.SessionId).empty;
        defer evicted.deinit(allocator);

        // TTL 0 disables eviction: even a year of idleness keeps the session.
        const one_year_ms: i64 = 365 * 24 * 60 * 60 * 1_000;
        try std.testing.expectEqual(@as(usize, 0), try server.evictIdleSessions(idle_since + one_year_ms, &evicted));
        try std.testing.expect(server.hasSession(sid));
    }
}

test "AgentProtocolServer eviction removes sequence and pending-message bookkeeping" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.initWithOptions(allocator, .{ .session_idle_ttl_ms = 100 });
    defer server.deinit();

    const sid = try startTestSession(&server, allocator);

    // An accepted-but-unconsumed pending message plus the session's sequence
    // entries are exactly the bookkeeping eviction must take with it.
    var msg = try makeTestAgentMessage(sid, 2, allocator);
    defer msg.deinit(allocator);
    try std.testing.expect((try server.handleEnvelope(msg)) == null);
    try server.publishAgentResult(sid, "{\"messages\":[]}");
    try std.testing.expectEqual(@as(usize, 1), server.pending_messages.items.len);

    const idle_since = server.sessions.get(sid).?.last_activity_ms;
    var evicted = std.ArrayList(agent_types.SessionId).empty;
    defer evicted.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), try server.evictIdleSessions(idle_since + 101, &evicted));

    try std.testing.expectEqual(@as(usize, 0), server.sessionCount());
    try std.testing.expect(!server.expected_sequences.contains(sid));
    try std.testing.expect(!server.outgoing_sequences.contains(sid));
    try std.testing.expectEqual(@as(usize, 0), server.pending_messages.items.len);
}

test "AgentProtocolServer stop after eviction returns agent_not_found" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.init(allocator);
    defer server.deinit();

    const sid = try startTestSession(&server, allocator);
    const idle_since = server.sessions.get(sid).?.last_activity_ms;
    const default_ttl: i64 = @intCast(default_session_idle_ttl_ms);
    var evicted = std.ArrayList(agent_types.SessionId).empty;
    defer evicted.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), try server.evictIdleSessions(idle_since + default_ttl + 1, &evicted));

    var stop = makeTestAgentStop(sid, 2);
    defer stop.deinit(allocator);
    var stop_resp = (try server.handleEnvelope(stop)).?;
    defer stop_resp.deinit(allocator);
    try std.testing.expect(stop_resp.payload == .agent_error);
    try std.testing.expectEqual(agent_types.AgentErrorCode.agent_not_found, stop_resp.payload.agent_error.code);
    try std.testing.expectEqual(@as(usize, 0), server.sessionCount());
}

test "AgentProtocolServer idleness ignores wall-clock adjustments" {
    const allocator = std.testing.allocator;
    var server = AgentProtocolServer.initWithOptions(allocator, .{ .session_idle_ttl_ms = 100 });
    defer server.deinit();

    const sid = try startTestSession(&server, allocator);
    var evicted = std.ArrayList(agent_types.SessionId).empty;
    defer evicted.deinit(allocator);

    // Wall-clock jumps (NTP steps, snapshot restores) distort `updated_at`
    // but must not affect eviction: idleness rides the monotonic clock only.
    const session = server.sessions.getPtr(sid).?;
    const anchor = session.last_activity_ms;

    session.updated_at -= 100 * 365 * 24 * 60 * 60 * 1_000; // far in the past
    try std.testing.expectEqual(@as(usize, 0), try server.evictIdleSessions(anchor + 100, &evicted));
    try std.testing.expect(server.hasSession(sid));

    session.updated_at += 200 * 365 * 24 * 60 * 60 * 1_000; // far in the future
    try std.testing.expectEqual(@as(usize, 1), try server.evictIdleSessions(anchor + 101, &evicted));
    try std.testing.expect(!server.hasSession(sid));
}
