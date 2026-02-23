const std = @import("std");
const auth_types = @import("auth_types");
const anthropic_oauth = @import("oauth/anthropic");
const github_oauth = @import("oauth/github_copilot");
const oauth_storage = @import("oauth/storage");
const OwnedSlice = @import("owned_slice").OwnedSlice;

const FlowState = struct {
    flow_id: auth_types.Uuid,
    provider_id: []u8,
    cancelled: bool = false,
    terminal_emitted: bool = false,
    worker_done: bool = false,
    prompt_counter: u64 = 0,
    waiting_prompt_id: ?[]u8 = null,
    pending_answer: ?[]u8 = null,
    thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    fn init(allocator: std.mem.Allocator, flow_id: auth_types.Uuid, provider_id: []const u8) !FlowState {
        return .{
            .flow_id = flow_id,
            .provider_id = try allocator.dupe(u8, provider_id),
        };
    }

    fn deinit(self: *FlowState, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        if (self.waiting_prompt_id) |prompt_id| {
            allocator.free(prompt_id);
            self.waiting_prompt_id = null;
        }
        if (self.pending_answer) |answer| {
            allocator.free(answer);
            self.pending_answer = null;
        }
        self.* = undefined;
    }
};

pub const AuthProtocolServer = struct {
    allocator: std.mem.Allocator,
    expected_sequences: std.AutoHashMap(auth_types.Uuid, u64),
    outgoing_sequences: std.AutoHashMap(auth_types.Uuid, u64),
    flows: std.AutoHashMap(auth_types.Uuid, *FlowState),
    outbox: std.ArrayList(auth_types.Envelope),
    mutex: std.Thread.Mutex = .{},
    options: Options,

    const Self = @This();
    const ScopeKind = enum { query, flow };

    pub const Options = struct {
        persist_credentials: bool = true,
        enable_real_oauth: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) Self {
        return .{
            .allocator = allocator,
            .expected_sequences = std.AutoHashMap(auth_types.Uuid, u64).init(allocator),
            .outgoing_sequences = std.AutoHashMap(auth_types.Uuid, u64).init(allocator),
            .flows = std.AutoHashMap(auth_types.Uuid, *FlowState).init(allocator),
            .outbox = std.ArrayList(auth_types.Envelope){},
            .options = options,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();

        var flow_iter = self.flows.iterator();
        while (flow_iter.next()) |entry| {
            const flow = entry.value_ptr.*;
            flow.mutex.lock();
            flow.cancelled = true;
            flow.cond.broadcast();
            flow.mutex.unlock();
        }

        var join_list = std.ArrayList(*FlowState){};
        defer join_list.deinit(self.allocator);

        flow_iter = self.flows.iterator();
        while (flow_iter.next()) |entry| {
            join_list.append(self.allocator, entry.value_ptr.*) catch {};
        }

        self.mutex.unlock();

        for (join_list.items) |flow| {
            if (flow.thread) |thread| {
                thread.join();
                flow.thread = null;
            }
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        flow_iter = self.flows.iterator();
        while (flow_iter.next()) |entry| {
            const flow = entry.value_ptr.*;
            flow.deinit(self.allocator);
            self.allocator.destroy(flow);
        }

        self.flows.deinit();
        self.expected_sequences.deinit();
        self.outgoing_sequences.deinit();

        for (self.outbox.items) |*env| {
            env.deinit(self.allocator);
        }
        self.outbox.deinit(self.allocator);
    }

    pub fn handleEnvelope(self: *Self, env: auth_types.Envelope) !?auth_types.Envelope {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cleanupCompletedFlowsLocked();

        if (env.version != auth_types.PROTOCOL_VERSION) {
            return try self.makeNackLocked(
                env.stream_id,
                env.message_id,
                .version_mismatch,
                "unsupported auth protocol version",
            );
        }

        switch (env.payload) {
            .auth_providers_request => return try self.handleProvidersRequestLocked(env),
            .auth_login_start => |request| return try self.handleLoginStartLocked(env, request),
            .auth_prompt_response => |response| return try self.handlePromptResponseLocked(env, response),
            .auth_cancel => |request| return try self.handleCancelLocked(env, request),
            .ping => {
                const ping_id = try auth_types.uuidToString(env.message_id, self.allocator);
                return .{
                    .stream_id = env.stream_id,
                    .message_id = auth_types.generateUuid(),
                    .sequence = self.nextOutgoingSequenceLocked(env.stream_id),
                    .in_reply_to = env.message_id,
                    .timestamp = std.time.milliTimestamp(),
                    .payload = .{ .pong = .{
                        .ping_id = OwnedSlice(u8).initOwned(ping_id),
                    } },
                };
            },
            .ack, .nack, .auth_providers_response, .auth_event, .auth_login_result, .pong, .goodbye => {
                return null;
            },
        }
    }

    pub fn popOutbound(self: *Self) ?auth_types.Envelope {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cleanupCompletedFlowsLocked();

        if (self.outbox.items.len == 0) return null;
        return self.outbox.orderedRemove(0);
    }

    pub fn activeFlowCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cleanupCompletedFlowsLocked();

        var count: usize = 0;
        var iter = self.flows.iterator();
        while (iter.next()) |entry| {
            const flow = entry.value_ptr.*;
            flow.mutex.lock();
            const active = !flow.terminal_emitted;
            flow.mutex.unlock();
            if (active) count += 1;
        }

        return count;
    }

    fn handleProvidersRequestLocked(self: *Self, env: auth_types.Envelope) !?auth_types.Envelope {
        self.validateAndUpdateSequenceLocked(.query, env.stream_id, env.sequence) catch |err| {
            return try self.sequenceNackLocked(env.stream_id, env.message_id, err);
        };

        const ack = self.makeAckLocked(env.stream_id, env.message_id);

        const providers = try self.buildProvidersResponse();
        const response = auth_types.Envelope{
            .stream_id = env.stream_id,
            .message_id = auth_types.generateUuid(),
            .sequence = self.nextOutgoingSequenceLocked(env.stream_id),
            .in_reply_to = env.message_id,
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .auth_providers_response = providers },
        };
        try self.outbox.append(self.allocator, response);

        return ack;
    }

    fn handleLoginStartLocked(self: *Self, env: auth_types.Envelope, request: auth_types.AuthLoginStartRequest) !?auth_types.Envelope {
        self.validateAndUpdateSequenceLocked(.flow, env.stream_id, env.sequence) catch |err| {
            return try self.sequenceNackLocked(env.stream_id, env.message_id, err);
        };

        if (self.flows.contains(env.stream_id)) {
            return try self.makeNackLocked(
                env.stream_id,
                env.message_id,
                .invalid_request,
                "auth flow already exists",
            );
        }

        const flow = try self.allocator.create(FlowState);
        errdefer self.allocator.destroy(flow);
        flow.* = try FlowState.init(self.allocator, env.stream_id, request.provider_id.slice());
        errdefer flow.deinit(self.allocator);

        const ack = self.makeAckLocked(env.stream_id, env.message_id);

        try self.flows.put(env.stream_id, flow);

        const thread = std.Thread.spawn(.{}, loginWorkerMain, .{ self, flow }) catch |spawn_err| {
            _ = self.flows.remove(env.stream_id);
            flow.deinit(self.allocator);
            self.allocator.destroy(flow);
            return try self.makeNackLocked(
                env.stream_id,
                env.message_id,
                .internal_error,
                @errorName(spawn_err),
            );
        };
        flow.thread = thread;

        return ack;
    }

    fn handlePromptResponseLocked(self: *Self, env: auth_types.Envelope, response: auth_types.AuthPromptResponse) !?auth_types.Envelope {
        const ack = self.makeAckLocked(env.stream_id, env.message_id);
        const flow = self.flows.get(response.flow_id) orelse return ack;

        flow.mutex.lock();
        const terminal = flow.terminal_emitted;
        const cancelled = flow.cancelled;
        flow.mutex.unlock();
        if (terminal or cancelled) return ack;

        self.validateAndUpdateSequenceLocked(.flow, response.flow_id, env.sequence) catch |err| {
            return try self.sequenceNackLocked(env.stream_id, env.message_id, err);
        };

        flow.mutex.lock();
        defer flow.mutex.unlock();

        if (flow.waiting_prompt_id) |pending_prompt_id| {
            if (std.mem.eql(u8, pending_prompt_id, response.prompt_id.slice()) and flow.pending_answer == null and !flow.cancelled and !flow.terminal_emitted) {
                flow.pending_answer = self.allocator.dupe(u8, response.answer.slice()) catch null;
                self.allocator.free(pending_prompt_id);
                flow.waiting_prompt_id = null;
                flow.cond.broadcast();
            }
        }

        return ack;
    }

    fn handleCancelLocked(self: *Self, env: auth_types.Envelope, request: auth_types.AuthCancelRequest) !?auth_types.Envelope {
        const ack = self.makeAckLocked(env.stream_id, env.message_id);
        const flow = self.flows.get(request.flow_id) orelse return ack;

        flow.mutex.lock();
        const terminal = flow.terminal_emitted;
        const cancelled = flow.cancelled;
        flow.mutex.unlock();
        if (!terminal and !cancelled) {
            self.validateAndUpdateSequenceLocked(.flow, request.flow_id, env.sequence) catch |err| {
                return try self.sequenceNackLocked(env.stream_id, env.message_id, err);
            };
        }

        flow.mutex.lock();
        flow.cancelled = true;

        var should_emit_cancel_result = false;
        if (!flow.terminal_emitted) {
            flow.terminal_emitted = true;
            should_emit_cancel_result = true;
        }

        if (flow.waiting_prompt_id) |prompt_id| {
            self.allocator.free(prompt_id);
            flow.waiting_prompt_id = null;
        }
        if (flow.pending_answer) |answer| {
            self.allocator.free(answer);
            flow.pending_answer = null;
        }
        flow.cond.broadcast();
        flow.mutex.unlock();

        if (should_emit_cancel_result) {
            try self.outbox.append(self.allocator, auth_types.Envelope{
                .stream_id = request.flow_id,
                .message_id = auth_types.generateUuid(),
                .sequence = self.nextOutgoingSequenceLocked(request.flow_id),
                .timestamp = std.time.milliTimestamp(),
                .payload = .{ .auth_login_result = .{
                    .flow_id = request.flow_id,
                    .provider_id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, flow.provider_id)),
                    .status = .cancelled,
                } },
            });
        }

        return ack;
    }

    fn cleanupCompletedFlowsLocked(self: *Self) void {
        var completed = std.ArrayList(auth_types.Uuid){};
        defer completed.deinit(self.allocator);

        var iter = self.flows.iterator();
        while (iter.next()) |entry| {
            const flow = entry.value_ptr.*;
            flow.mutex.lock();
            const should_remove = flow.worker_done and flow.terminal_emitted;
            flow.mutex.unlock();
            if (!should_remove) continue;
            completed.append(self.allocator, entry.key_ptr.*) catch return;
        }

        for (completed.items) |flow_id| {
            if (self.flows.fetchRemove(flow_id)) |removed| {
                const flow = removed.value;
                if (flow.thread) |thread| {
                    thread.join();
                    flow.thread = null;
                }
                flow.deinit(self.allocator);
                self.allocator.destroy(flow);
            }
            _ = self.expected_sequences.remove(flow_id);
            _ = self.outgoing_sequences.remove(flow_id);
        }
    }

    fn buildProvidersResponse(self: *Self) !auth_types.AuthProvidersResponse {
        const ProviderDefinition = struct {
            id: []const u8,
            name: []const u8,
        };
        const definitions = [_]ProviderDefinition{
            .{ .id = "anthropic", .name = "Anthropic" },
            .{ .id = "github-copilot", .name = "GitHub Copilot" },
            .{ .id = "test-fixture", .name = "Test Fixture (CI)" },
        };

        const providers = try self.allocator.alloc(auth_types.AuthProviderInfo, definitions.len);
        errdefer {
            for (providers) |*provider| provider.deinit(self.allocator);
            self.allocator.free(providers);
        }

        var storage = oauth_storage.AuthStorage.loadFromFile(self.allocator) catch null;
        defer if (storage) |*auth_storage| auth_storage.deinit();

        const now_ms = std.time.milliTimestamp();

        for (definitions, 0..) |definition, index| {
            var status: auth_types.AuthStatus = .login_required;
            if (storage) |*auth_storage| {
                if (auth_storage.providers.get(definition.id)) |provider_auth| {
                    switch (provider_auth) {
                        .api_key => status = .authenticated,
                        .oauth => |credentials| {
                            status = if (now_ms >= credentials.expires) .expired else .authenticated;
                        },
                    }
                }
            }

            providers[index] = .{
                .id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, definition.id)),
                .name = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, definition.name)),
                .auth_status = status,
            };
        }

        return .{
            .providers = OwnedSlice(auth_types.AuthProviderInfo).initOwned(providers),
        };
    }

    fn validateAndUpdateSequenceLocked(self: *Self, _: ScopeKind, scope_id: auth_types.Uuid, received: u64) !void {
        if (received == 0) return error.InvalidSequence;
        const expected = self.expected_sequences.get(scope_id) orelse 1;
        if (received < expected) return error.DuplicateSequence;
        if (received > expected) return error.SequenceGap;
        try self.expected_sequences.put(scope_id, received + 1);
    }

    fn nextOutgoingSequenceLocked(self: *Self, scope_id: auth_types.Uuid) u64 {
        const current = self.outgoing_sequences.get(scope_id) orelse 0;
        const next = current + 1;
        self.outgoing_sequences.put(scope_id, next) catch {};
        return next;
    }

    fn makeAckLocked(self: *Self, scope_id: auth_types.Uuid, in_reply_to: auth_types.Uuid) auth_types.Envelope {
        return .{
            .stream_id = scope_id,
            .message_id = auth_types.generateUuid(),
            .sequence = self.nextOutgoingSequenceLocked(scope_id),
            .in_reply_to = in_reply_to,
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .ack = .{
                .acknowledged_id = in_reply_to,
            } },
        };
    }

    fn sequenceNackLocked(self: *Self, scope_id: auth_types.Uuid, in_reply_to: auth_types.Uuid, err: anyerror) !auth_types.Envelope {
        return switch (err) {
            error.InvalidSequence => try self.makeNackLocked(scope_id, in_reply_to, .invalid_sequence, "invalid sequence"),
            error.DuplicateSequence => try self.makeNackLocked(scope_id, in_reply_to, .duplicate_sequence, "duplicate sequence"),
            error.SequenceGap => try self.makeNackLocked(scope_id, in_reply_to, .sequence_gap, "sequence gap"),
            else => try self.makeNackLocked(scope_id, in_reply_to, .internal_error, @errorName(err)),
        };
    }

    fn makeNackLocked(
        self: *Self,
        scope_id: auth_types.Uuid,
        in_reply_to: auth_types.Uuid,
        error_code: auth_types.ErrorCode,
        reason: []const u8,
    ) !auth_types.Envelope {
        return .{
            .stream_id = scope_id,
            .message_id = auth_types.generateUuid(),
            .sequence = self.nextOutgoingSequenceLocked(scope_id),
            .in_reply_to = in_reply_to,
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .nack = .{
                .rejected_id = in_reply_to,
                .reason = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, reason)),
                .error_code = error_code,
            } },
        };
    }

    fn loginWorkerMain(server: *Self, flow: *FlowState) void {
        defer {
            flow.mutex.lock();
            flow.worker_done = true;
            flow.cond.broadcast();
            flow.mutex.unlock();
        }

        server.runLoginFlow(flow) catch {};
    }

    fn runLoginFlow(self: *Self, flow: *FlowState) !void {
        try self.emitProgress(flow, "Auth flow started.");

        var credentials = self.executeProviderLogin(flow) catch |err| {
            if (err == error.AuthFlowCancelled) {
                try self.emitCancelledIfNeeded(flow);
                return;
            }
            try self.emitFailureIfNeeded(flow, @errorName(err), "auth login failed");
            return;
        };
        var credentials_consumed = false;
        defer if (!credentials_consumed) credentials.deinit(self.allocator);

        flow.mutex.lock();
        const cancelled = flow.cancelled;
        flow.mutex.unlock();
        if (cancelled) {
            try self.emitCancelledIfNeeded(flow);
            return;
        }

        if (self.options.persist_credentials) {
            saveOAuthCredentials(flow.provider_id, credentials, self.allocator) catch |err| {
                try self.emitFailureIfNeeded(flow, @errorName(err), "failed to persist credentials");
                return;
            };
            credentials_consumed = true;
        }

        try self.emitSuccessIfNeeded(flow);
    }

    fn executeProviderLogin(self: *Self, flow: *FlowState) !oauth_storage.Credentials {
        if (std.mem.eql(u8, flow.provider_id, "test-fixture")) {
            return try self.loginTestFixture(flow);
        }

        if (!self.options.enable_real_oauth) {
            return error.UnknownProvider;
        }

        if (std.mem.eql(u8, flow.provider_id, "anthropic")) {
            return try self.loginAnthropic(flow);
        }

        if (std.mem.eql(u8, flow.provider_id, "github-copilot")) {
            return try self.loginGitHubCopilot(flow);
        }

        return error.UnknownProvider;
    }

    fn loginTestFixture(self: *Self, flow: *FlowState) !oauth_storage.Credentials {
        try self.emitAuthUrl(
            flow,
            "https://example.invalid/makai-test-fixture-login",
            "Enter code 'ok' to complete fixture login.",
        );

        while (true) {
            const answer = try self.promptForAnswer(flow, "Enter fixture code:", false);
            defer self.allocator.free(answer);
            if (std.mem.eql(u8, answer, "ok")) break;
            try self.emitProgress(flow, "Invalid fixture code, try again.");
        }

        return .{
            .refresh = try self.allocator.dupe(u8, "fixture-refresh-token"),
            .access = try self.allocator.dupe(u8, "fixture-access-token"),
            .expires = std.time.milliTimestamp() + (60 * 60 * 1000),
            .provider_data = try self.allocator.dupe(u8, "{\"provider\":\"test-fixture\"}"),
        };
    }

    fn loginAnthropic(self: *Self, flow: *FlowState) !oauth_storage.Credentials {
        var context = OAuthThreadContext{
            .server = self,
            .flow = flow,
        };
        g_oauth_thread_context = &context;
        defer g_oauth_thread_context = null;

        const credentials = try anthropic_oauth.login(.{
            .onAuth = anthropicOnAuth,
            .onPrompt = anthropicOnPrompt,
        }, self.allocator);

        return .{
            .refresh = credentials.refresh,
            .access = credentials.access,
            .expires = credentials.expires,
        };
    }

    fn loginGitHubCopilot(self: *Self, flow: *FlowState) !oauth_storage.Credentials {
        var context = OAuthThreadContext{
            .server = self,
            .flow = flow,
        };
        g_oauth_thread_context = &context;
        defer g_oauth_thread_context = null;

        const credentials = try github_oauth.login(.{
            .onAuth = githubOnAuth,
            .onPrompt = githubOnPrompt,
        }, self.allocator);

        if (credentials.enabled_models) |models| {
            for (models) |model| self.allocator.free(model);
            self.allocator.free(models);
        }
        if (credentials.base_url) |base_url| {
            self.allocator.free(base_url);
        }

        return .{
            .refresh = credentials.refresh,
            .access = credentials.access,
            .expires = credentials.expires,
            .provider_data = credentials.provider_data,
        };
    }

    fn promptForAnswer(self: *Self, flow: *FlowState, message: []const u8, allow_empty: bool) ![]u8 {
        while (true) {
            try self.queuePrompt(flow, message, allow_empty);

            flow.mutex.lock();
            defer flow.mutex.unlock();

            while (true) {
                if (flow.cancelled or flow.terminal_emitted) {
                    if (flow.waiting_prompt_id) |prompt_id| {
                        self.allocator.free(prompt_id);
                        flow.waiting_prompt_id = null;
                    }
                    if (flow.pending_answer) |answer| {
                        self.allocator.free(answer);
                        flow.pending_answer = null;
                    }
                    return error.AuthFlowCancelled;
                }

                if (flow.pending_answer) |answer| {
                    flow.pending_answer = null;
                    if (allow_empty or answer.len > 0) {
                        return answer;
                    }

                    self.allocator.free(answer);
                    break;
                }

                flow.cond.wait(&flow.mutex);
            }
        }
    }

    fn queuePrompt(self: *Self, flow: *FlowState, message: []const u8, allow_empty: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        flow.mutex.lock();
        defer flow.mutex.unlock();

        if (flow.cancelled or flow.terminal_emitted) {
            return error.AuthFlowCancelled;
        }

        flow.prompt_counter += 1;
        const prompt_id = try std.fmt.allocPrint(self.allocator, "prompt-{d}", .{flow.prompt_counter});
        errdefer self.allocator.free(prompt_id);

        if (flow.waiting_prompt_id) |existing| {
            self.allocator.free(existing);
        }
        flow.waiting_prompt_id = prompt_id;

        const env = auth_types.Envelope{
            .stream_id = flow.flow_id,
            .message_id = auth_types.generateUuid(),
            .sequence = self.nextOutgoingSequenceLocked(flow.flow_id),
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .auth_event = .{ .prompt = .{
                .flow_id = flow.flow_id,
                .prompt_id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, prompt_id)),
                .provider_id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, flow.provider_id)),
                .message = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, message)),
                .allow_empty = allow_empty,
            } } },
        };
        try self.outbox.append(self.allocator, env);
    }

    fn emitProgress(self: *Self, flow: *FlowState, message: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        flow.mutex.lock();
        defer flow.mutex.unlock();
        if (flow.cancelled or flow.terminal_emitted) return;

        try self.outbox.append(self.allocator, auth_types.Envelope{
            .stream_id = flow.flow_id,
            .message_id = auth_types.generateUuid(),
            .sequence = self.nextOutgoingSequenceLocked(flow.flow_id),
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .auth_event = .{ .progress = .{
                .flow_id = flow.flow_id,
                .provider_id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, flow.provider_id)),
                .message = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, message)),
            } } },
        });
    }

    fn emitAuthUrl(self: *Self, flow: *FlowState, url: []const u8, instructions: ?[]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        flow.mutex.lock();
        defer flow.mutex.unlock();
        if (flow.cancelled or flow.terminal_emitted) return;

        var event = auth_types.AuthEvent{ .auth_url = .{
            .flow_id = flow.flow_id,
            .provider_id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, flow.provider_id)),
            .url = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, url)),
        } };
        if (instructions) |value| {
            event.auth_url.instructions = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, value));
        }

        try self.outbox.append(self.allocator, auth_types.Envelope{
            .stream_id = flow.flow_id,
            .message_id = auth_types.generateUuid(),
            .sequence = self.nextOutgoingSequenceLocked(flow.flow_id),
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .auth_event = event },
        });
    }

    fn tryBeginTerminal(flow: *FlowState) bool {
        flow.mutex.lock();
        defer flow.mutex.unlock();

        if (flow.terminal_emitted) return false;
        flow.terminal_emitted = true;
        return true;
    }

    fn emitSuccessIfNeeded(self: *Self, flow: *FlowState) !void {
        if (!tryBeginTerminal(flow)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.outbox.append(self.allocator, auth_types.Envelope{
            .stream_id = flow.flow_id,
            .message_id = auth_types.generateUuid(),
            .sequence = self.nextOutgoingSequenceLocked(flow.flow_id),
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .auth_event = .{ .success = .{
                .flow_id = flow.flow_id,
                .provider_id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, flow.provider_id)),
            } } },
        });

        try self.outbox.append(self.allocator, auth_types.Envelope{
            .stream_id = flow.flow_id,
            .message_id = auth_types.generateUuid(),
            .sequence = self.nextOutgoingSequenceLocked(flow.flow_id),
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .auth_login_result = .{
                .flow_id = flow.flow_id,
                .provider_id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, flow.provider_id)),
                .status = .success,
            } },
        });
    }

    fn emitFailureIfNeeded(self: *Self, flow: *FlowState, code: []const u8, message: []const u8) !void {
        if (!tryBeginTerminal(flow)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.outbox.append(self.allocator, auth_types.Envelope{
            .stream_id = flow.flow_id,
            .message_id = auth_types.generateUuid(),
            .sequence = self.nextOutgoingSequenceLocked(flow.flow_id),
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .auth_event = .{ .@"error" = .{
                .flow_id = flow.flow_id,
                .provider_id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, flow.provider_id)),
                .code = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, code)),
                .message = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, message)),
            } } },
        });

        try self.outbox.append(self.allocator, auth_types.Envelope{
            .stream_id = flow.flow_id,
            .message_id = auth_types.generateUuid(),
            .sequence = self.nextOutgoingSequenceLocked(flow.flow_id),
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .auth_login_result = .{
                .flow_id = flow.flow_id,
                .provider_id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, flow.provider_id)),
                .status = .failed,
            } },
        });
    }

    fn emitCancelledIfNeeded(self: *Self, flow: *FlowState) !void {
        if (!tryBeginTerminal(flow)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.outbox.append(self.allocator, auth_types.Envelope{
            .stream_id = flow.flow_id,
            .message_id = auth_types.generateUuid(),
            .sequence = self.nextOutgoingSequenceLocked(flow.flow_id),
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .auth_login_result = .{
                .flow_id = flow.flow_id,
                .provider_id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, flow.provider_id)),
                .status = .cancelled,
            } },
        });
    }
};

const OAuthThreadContext = struct {
    server: *AuthProtocolServer,
    flow: *FlowState,
};

threadlocal var g_oauth_thread_context: ?*OAuthThreadContext = null;

fn anthropicOnAuth(info: anthropic_oauth.AuthInfo) void {
    const context = g_oauth_thread_context orelse return;
    context.server.emitAuthUrl(context.flow, info.url, info.instructions) catch {};
}

fn anthropicOnPrompt(prompt: anthropic_oauth.Prompt) []const u8 {
    const context = g_oauth_thread_context orelse @panic("missing oauth context");
    return context.server.promptForAnswer(context.flow, prompt.message, prompt.allow_empty) catch context.server.allocator.alloc(u8, 0) catch @panic("OOM");
}

fn githubOnAuth(info: github_oauth.AuthInfo) void {
    const context = g_oauth_thread_context orelse return;
    context.server.emitAuthUrl(context.flow, info.url, info.instructions) catch {};
}

fn githubOnPrompt(prompt: github_oauth.Prompt) []const u8 {
    const context = g_oauth_thread_context orelse @panic("missing oauth context");
    return context.server.promptForAnswer(context.flow, prompt.message, prompt.allow_empty) catch context.server.allocator.alloc(u8, 0) catch @panic("OOM");
}

fn saveOAuthCredentials(provider_id: []const u8, credentials: oauth_storage.Credentials, allocator: std.mem.Allocator) !void {
    var storage = try oauth_storage.AuthStorage.loadFromFile(allocator);
    defer storage.deinit();

    if (storage.providers.fetchRemove(provider_id)) |existing| {
        allocator.free(existing.key);
        existing.value.deinit(allocator);
    }

    const key = try allocator.dupe(u8, provider_id);
    try storage.providers.put(key, .{
        .oauth = .{
            .refresh = credentials.refresh,
            .access = credentials.access,
            .expires = credentials.expires,
            .provider_data = credentials.provider_data,
        },
    });
    try storage.saveToFile();
}

test "AuthProtocolServer type is available" {
    _ = AuthProtocolServer;
}
