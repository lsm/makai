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

pub const Options = struct {
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

pub const AgentProtocolServer = struct {
    allocator: std.mem.Allocator,
    sessions: std.AutoHashMap(agent_types.SessionId, SessionState),
    expected_sequences: std.AutoHashMap(agent_types.SessionId, u64),
    outgoing_sequences: std.AutoHashMap(agent_types.SessionId, u64),
    outbox: std.ArrayList(agent_types.Envelope),
    pending_messages: std.ArrayList(PendingAgentMessage),
    options: Options,

    const Self = @This();

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
        try self.sessions.put(session_id, .{
            .session_id = session_id,
            .status = .ready,
            .model = model,
            .config_json = config_json,
            .system_prompt = system_prompt,
            .message_count = 0,
            .created_at = now,
            .updated_at = now,
        });

        return .{
            .session_id = session_id,
            .message_id = agent_types.generateUlid(),
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
        session.updated_at = compat.time.nowMillis();

        return null;
    }

    fn handleStop(self: *Self, req: agent_types.AgentStopRequest, env: agent_types.Envelope) !?agent_types.Envelope {
        if (!self.sessions.contains(req.session_id)) {
            return try self.makeError(env.session_id, env.message_id, .agent_not_found, "session not found");
        }

        const expected = self.expected_sequences.get(req.session_id) orelse 1;
        if (env.sequence != expected) {
            return try self.makeError(env.session_id, env.message_id, .invalid_request, "invalid sequence");
        }

        const stop_sequence = self.nextOutgoingSequence(req.session_id);
        const removed = self.sessions.fetchRemove(req.session_id) orelse {
            return try self.makeError(env.session_id, env.message_id, .agent_not_found, "session not found");
        };
        self.allocator.free(removed.value.model);
        self.allocator.free(removed.value.config_json);
        self.allocator.free(removed.value.system_prompt);
        _ = self.expected_sequences.remove(req.session_id);
        _ = self.outgoing_sequences.remove(req.session_id);
        self.removePendingMessages(req.session_id);

        const reason = if (req.getReason()) |r| try self.allocator.dupe(u8, r) else try self.allocator.dupe(u8, "stopped");
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
        const session = self.sessions.get(req.session_id) orelse {
            return try self.makeError(env.session_id, env.message_id, .agent_not_found, "session not found");
        };

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

        const ack_seq = self.nextOutgoingSequence(env.session_id);
        const ack_envelope = agent_types.Envelope{
            .session_id = env.session_id,
            .message_id = agent_types.generateUlid(),
            .sequence = ack_seq,
            .in_reply_to = env.message_id,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .ack = .{ .acknowledged_id = env.message_id } },
        };

        const response_seq = self.nextOutgoingSequence(env.session_id);
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
            .sequence = self.nextOutgoingSequence(session_id),
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

    pub fn nextOutgoingSequence(self: *Self, session_id: agent_types.SessionId) u64 {
        const cur = self.outgoing_sequences.get(session_id) orelse 0;
        const next = cur + 1;
        self.outgoing_sequences.put(session_id, next) catch {};
        return next;
    }

    pub fn publishAgentEvent(self: *Self, session_id: agent_types.SessionId, event_json: []const u8) !void {
        if (!self.sessions.contains(session_id)) return error.SessionNotFound;
        try self.outbox.append(self.allocator, .{
            .session_id = session_id,
            .message_id = agent_types.generateUlid(),
            .sequence = self.nextOutgoingSequence(session_id),
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .agent_event = try self.allocator.dupe(u8, event_json) },
        });
    }

    pub fn publishAgentResult(self: *Self, session_id: agent_types.SessionId, result_json: []const u8) !void {
        const session = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;
        session.status = .ready;
        session.updated_at = compat.time.nowMillis();
        try self.outbox.append(self.allocator, .{
            .session_id = session_id,
            .message_id = agent_types.generateUlid(),
            .sequence = self.nextOutgoingSequence(session_id),
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .agent_result = try self.allocator.dupe(u8, result_json) },
        });
    }

    pub fn publishAgentError(self: *Self, session_id: agent_types.SessionId, code: agent_types.AgentErrorCode, message: []const u8) !void {
        const session = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;
        session.status = .@"error";
        session.updated_at = compat.time.nowMillis();
        try self.outbox.append(self.allocator, .{
            .session_id = session_id,
            .message_id = agent_types.generateUlid(),
            .sequence = self.nextOutgoingSequence(session_id),
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .agent_error = .{
                .code = code,
                .message = try self.allocator.dupe(u8, message),
            } },
        });
    }

    pub fn enqueueEnvelope(self: *Self, env: agent_types.Envelope) !void {
        try self.outbox.append(self.allocator, env);
    }

    pub fn popOutbound(self: *Self) ?agent_types.Envelope {
        if (self.outbox.items.len == 0) return null;
        return self.outbox.orderedRemove(0);
    }

    pub fn popPendingAgentMessage(self: *Self) ?PendingAgentMessage {
        if (self.pending_messages.items.len == 0) return null;
        return self.pending_messages.orderedRemove(0);
    }

    pub fn hasSession(self: *Self, session_id: agent_types.SessionId) bool {
        return self.sessions.contains(session_id);
    }

    pub fn updateSessionModel(self: *Self, session_id: agent_types.SessionId, model: []const u8) !void {
        const session = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;
        const next = try self.allocator.dupe(u8, model);
        self.allocator.free(session.model);
        session.model = next;
        session.updated_at = compat.time.nowMillis();
    }

    pub fn markSessionError(self: *Self, session_id: agent_types.SessionId) void {
        if (self.sessions.getPtr(session_id)) |session| {
            session.status = .@"error";
            session.updated_at = compat.time.nowMillis();
        }
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
