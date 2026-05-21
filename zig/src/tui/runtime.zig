const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");
const agent = @import("agent");
const agent_protocol_client = @import("agent_protocol_client");
const agent_envelope = @import("agent_envelope");
const agent_protocol_types = @import("agent_protocol_types");
const agent_protocol_server = @import("agent_protocol_server");
const agent_protocol_runtime = @import("agent_protocol_runtime");
const transport = @import("transport");
const in_process = @import("transports/in_process");
const json_writer = @import("json_writer");
const model_ref = @import("model_ref");
const session = @import("tui_session");
const local_tools = @import("tools/registry");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const TuiSession = session.TuiSession;
pub const TuiEvent = session.TuiEvent;
pub const TuiEventStream = session.TuiEventStream;
pub const TuiEndReason = session.TuiEndReason;
pub const ToolApprovalCallback = session.ToolApprovalCallback;
pub const ToolApprovalDecision = session.ToolApprovalDecision;
pub const ToolApprovalRequest = session.ToolApprovalRequest;

const ApprovalDecisionState = struct {
    tool_call_id: []u8 = &.{},
    decision: ?ToolApprovalDecision = null,
    cancelled: bool = false,
};

const ApprovalContext = struct {
    runtime: *TuiRuntime,
    callback_ctx: ?*anyopaque,
    callback: ?ToolApprovalCallback,
    original_ctx: ?*anyopaque,
    original_callback: ?agent.ToolApprovalFn,
    original_ui_ctx: ?*anyopaque,
    original_ui_callback: ?agent.ToolApprovalUiFn,
    tool_name: []const u8,
};

pub const RemoteReadResult = union(enum) {
    line: []const u8,
    pending,
    disconnected,
};

pub const RemoteLineReceiver = struct {
    ctx: *anyopaque,
    read_line_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]const u8,
    read_result_fn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!RemoteReadResult = null,
    close_fn: ?*const fn (ctx: *anyopaque) void = null,

    pub fn readLine(self: *RemoteLineReceiver, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.read_result_fn) |f| {
            return switch (try f(self.ctx, allocator)) {
                .line => |line| line,
                .pending, .disconnected => null,
            };
        }
        return self.read_line_fn(self.ctx, allocator);
    }

    pub fn read(self: *RemoteLineReceiver, allocator: std.mem.Allocator) !RemoteReadResult {
        if (self.read_result_fn) |f| return f(self.ctx, allocator);
        if (try self.read_line_fn(self.ctx, allocator)) |line| return .{ .line = line };
        return .disconnected;
    }

    pub fn close(self: *RemoteLineReceiver) void {
        if (self.close_fn) |f| f(self.ctx);
    }
};

pub const TuiBackendMode = enum {
    local,
    remote,
};

pub const TuiRemoteTransport = enum {
    stdio,
    sse,
    websocket,
};

pub const TuiRemoteConfig = struct {
    mode: TuiBackendMode = .local,
    transport: TuiRemoteTransport = .stdio,
    endpoint: []const u8 = "",
};

pub const TuiRuntimeOptions = struct {
    backend: TuiBackendMode = .local,
    remote_config: TuiRemoteConfig = .{},
    remote_sender: ?transport.AsyncSender = null,
    remote_receiver: ?RemoteLineReceiver = null,
    remote_session_timeout_ms: u64 = 5_000,
    protocol: ?agent.ProtocolClient = null,
    models: []const ai_types.Model = &.{},
    initial_model_id: ?[]const u8 = null,
    tools: []const agent.AgentTool = &.{},
    tool_approval_ctx: ?*anyopaque = null,
    tool_approval_callback: ?ToolApprovalCallback = null,
    compact_output: bool = false,
    run_async: bool = true,
};

pub const TuiRuntime = struct {
    allocator: std.mem.Allocator,
    backend: TuiBackendMode,
    protocol: ?agent.ProtocolClient,
    models: []ai_types.Model,
    selected_model_index: ?usize,
    local_agent: ?agent.Agent = null,
    remote_client: ?agent_protocol_client.AgentProtocolClient = null,
    remote_sender: ?transport.AsyncSender = null,
    remote_receiver: ?RemoteLineReceiver = null,
    remote_session_id: ?agent_protocol_types.SessionId = null,
    remote_pending_session_id: ?agent_protocol_types.SessionId = null,
    remote_error_emitted: bool = false,
    remote_reconnect_attempted: bool = false,
    remote_session_timeout_ms: u64 = 5_000,
    event_stream: TuiEventStream,
    tool_registry: local_tools.ToolRegistry,
    original_tools: []agent.AgentTool,
    wrapped_tools: []agent.AgentTool,
    approval_contexts: []ApprovalContext,
    pending_approval: ApprovalDecisionState = .{},
    approval_mutex: std.atomic.Mutex = .unlocked,
    tool_approval_ctx: ?*anyopaque,
    tool_approval_callback: ?ToolApprovalCallback,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    completed: bool = false,
    started: bool = false,
    stream_active: bool = false,
    remote_messages: std.ArrayList(ai_types.Message) = .empty,
    last_turn_stop_reason: ?ai_types.StopReason = null,
    compact_output: bool = false,
    run_async: bool = true,

    pub fn init(allocator: std.mem.Allocator, options: TuiRuntimeOptions) !TuiRuntime {
        const models = try allocator.dupe(ai_types.Model, options.models);
        errdefer allocator.free(models);

        var tool_registry = local_tools.ToolRegistry.init();
        errdefer tool_registry.deinit(allocator);
        try tool_registry.registerDefaults(allocator);
        for (options.tools) |tool| try tool_registry.replaceOrRegister(allocator, tool);

        const original_tools = try allocator.dupe(agent.AgentTool, tool_registry.list());
        errdefer allocator.free(original_tools);

        const wrapped_tools = try allocator.alloc(agent.AgentTool, original_tools.len);
        errdefer allocator.free(wrapped_tools);

        const approval_contexts = try allocator.alloc(ApprovalContext, original_tools.len);
        errdefer allocator.free(approval_contexts);

        var selected: ?usize = null;
        if (models.len > 0) {
            selected = 0;
            if (options.initial_model_id) |id| {
                for (models, 0..) |model, i| {
                    if (std.mem.eql(u8, model.id, id)) {
                        selected = i;
                        break;
                    }
                }
            }
        }

        const runtime = TuiRuntime{
            .allocator = allocator,
            .backend = options.backend,
            .protocol = options.protocol,
            .remote_sender = options.remote_sender,
            .remote_receiver = options.remote_receiver,
            .remote_session_timeout_ms = options.remote_session_timeout_ms,
            .models = models,
            .selected_model_index = selected,
            .event_stream = TuiEventStream.init(allocator),
            .tool_registry = tool_registry,
            .original_tools = original_tools,
            .wrapped_tools = wrapped_tools,
            .approval_contexts = approval_contexts,
            .tool_approval_ctx = options.tool_approval_ctx,
            .tool_approval_callback = options.tool_approval_callback,
            .compact_output = options.compact_output,
            .run_async = options.run_async,
        };
        return runtime;
    }

    pub fn deinit(self: *TuiRuntime) void {
        self.stop();
        self.clearRemoteMessages();
        self.remote_messages.deinit(self.allocator);
        self.event_stream.deinit();
        if (self.remote_client) |*client| client.deinit();
        self.clearPendingApproval();
        self.allocator.free(self.approval_contexts);
        self.allocator.free(self.wrapped_tools);
        self.allocator.free(self.original_tools);
        self.tool_registry.deinit(self.allocator);
        self.allocator.free(self.models);
        self.* = undefined;
    }

    pub fn start(self: *TuiRuntime) !void {
        switch (self.backend) {
            .remote => {
                if (self.started) return;
                var client = agent_protocol_client.AgentProtocolClient.init(self.allocator);
                var client_moved = false;
                errdefer if (!client_moved) client.deinit();
                const sender = self.remote_sender orelse return error.NoRemoteTransportConfigured;
                _ = self.remote_receiver orelse return error.NoRemoteTransportConfigured;
                client.setSender(sender);
                const config_json = try self.remoteConfigJson();
                defer self.allocator.free(config_json);
                const sid = agent_protocol_types.generateSessionId();
                _ = try client.sendAgentStartWithSession(sid, config_json, null);
                self.remote_pending_session_id = sid;
                self.remote_client = client;
                client_moved = true;
                self.started = true;
                self.remote_error_emitted = false;
                self.remote_reconnect_attempted = false;
                self.pumpRemoteIncoming() catch |err| {
                    if (self.remote_sender) |remote_sender| remote_sender.close();
                    if (self.remote_receiver) |*remote_receiver| remote_receiver.close();
                    if (self.remote_client) |*remote_client| remote_client.deinit();
                    self.remote_client = null;
                    self.remote_session_id = null;
                    self.remote_pending_session_id = null;
                    self.started = false;
                    return err;
                };
                self.remote_session_id = self.remote_client.?.session_id;
            },
            .local => {
                if (self.started) return;
                const protocol = self.protocol orelse return error.NoProtocolConfigured;
                self.rebuildWrappedTools();
                self.local_agent = agent.Agent.init(self.allocator, .{ .protocol = protocol, .compact_tool_output = self.compact_output });
                self.local_agent.?.subscribeWithContext(self, onAgentEvent);
                self.local_agent.?.setCompactToolOutput(self.compact_output);
                if (self.selected_model_index) |idx| self.local_agent.?.setModel(self.models[idx]);
                self.local_agent.?.setTools(self.wrapped_tools);
                self.started = true;
            },
        }
    }

    pub fn stop(self: *TuiRuntime) void {
        if (self.local_agent) |*local| {
            if (!local.isIdle()) {
                local.abort();
                local.waitForIdle();
            }
            local.unsubscribeWithContext(self, onAgentEvent);
            local.deinit();
            self.local_agent = null;
        }
        if (self.remote_client) |*client| {
            const stop_sid = self.remote_session_id orelse self.remote_pending_session_id;
            if (stop_sid) |sid| {
                _ = client.sendAgentStop(sid, "client disconnect") catch {};
                client.removeSessionState(sid);
            }
            if (self.remote_sender) |sender| sender.close();
            if (self.remote_receiver) |*receiver| receiver.close();
            client.deinit();
            self.remote_client = null;
            self.remote_session_id = null;
            self.remote_pending_session_id = null;
            self.remote_error_emitted = false;
            self.remote_reconnect_attempted = false;
        }
        self.started = false;
    }

    pub fn createSession(self: *TuiRuntime) TuiSession {
        return .{
            .ctx = self,
            .ops = .{
                .start = sessionStart,
                .resume_session = sessionResume,
                .cancel = sessionCancel,
                .submit_turn = sessionSubmitTurn,
                .switch_model = sessionSwitchModel,
                .current_model = sessionCurrentModel,
                .decide_tool_approval = sessionDecideToolApproval,
                .stream_events = sessionStreamEvents,
            },
        };
    }

    pub fn availableModels(self: *TuiRuntime) []const ai_types.Model {
        return self.models;
    }

    pub fn currentModel(self: *TuiRuntime) ?ai_types.Model {
        if (self.selected_model_index) |idx| return self.models[idx];
        return null;
    }

    pub fn switchModel(self: *TuiRuntime, model_id: []const u8) !void {
        if (self.local_agent) |*local| {
            if (!local.isIdle()) return error.AgentAlreadyStreaming;
        }

        for (self.models, 0..) |model, i| {
            if (std.mem.eql(u8, model.id, model_id)) {
                self.selected_model_index = i;
                if (self.local_agent) |*local| local.setModel(model);
                return;
            }
        }
        return error.ModelNotFound;
    }

    pub fn submitTurn(self: *TuiRuntime, text: []const u8) !void {
        switch (self.backend) {
            .remote => {
                if (!self.started) try self.start();
                if (self.currentModel() == null) return error.NoModelConfigured;
                if (self.stream_active and !self.event_stream.isDone()) return error.AgentAlreadyStreaming;
                try self.ensureRemoteSession();
                const client = &(self.remote_client orelse return error.RuntimeNotStarted);
                const sid = self.remote_session_id orelse return error.RemoteAgentStartFailed;
                const user_message = try makeRemoteUserMessage(self.allocator, text);
                var message_appended = false;
                errdefer if (!message_appended) {
                    var mutable = user_message;
                    mutable.deinit(self.allocator);
                };
                try self.remote_messages.append(self.allocator, user_message);
                message_appended = true;
                var message_sent = false;
                errdefer if (!message_sent) {
                    var mutable = self.remote_messages.pop().?;
                    mutable.deinit(self.allocator);
                };
                self.resetEventStreamForTurn();
                self.cancelled.store(false, .release);
                self.completed = false;
                self.remote_error_emitted = false;
                self.remote_reconnect_attempted = false;
                client.clearSessionTerminalState(sid);
                self.last_turn_stop_reason = null;
                const message_json = try makeRemoteMessageJson(self.allocator, self.currentModel(), self.remote_messages.items, self.remoteSerializableTools());
                defer self.allocator.free(message_json);
                _ = try client.sendAgentMessage(sid, message_json, null);
                message_sent = true;
                self.pumpRemoteIncoming() catch |err| {
                    try self.completeRemoteWithError(@errorName(err));
                };
            },
            .local => {
                if (!self.started) try self.start();
                const local = &(self.local_agent orelse return error.RuntimeNotStarted);
                if (self.currentModel() == null) return error.NoModelConfigured;
                if (self.run_async) local.waitForIdle();
                self.resetEventStreamForTurn();
                self.cancelled.store(false, .release);
                self.completed = false;
                self.last_turn_stop_reason = null;
                if (self.run_async) {
                    const owned_text = try self.allocator.dupe(u8, text);
                    errdefer self.allocator.free(owned_text);
                    const msg = ai_types.Message{ .user = .{
                        .content = .{ .text = owned_text },
                        .timestamp = compat.time.nowMillis(),
                    } };
                    try local.promptAsync(msg);
                    self.allocator.free(owned_text);
                } else {
                    const owned_text = try self.allocator.dupe(u8, text);
                    const msg = ai_types.Message{ .user = .{
                        .content = .{ .text = owned_text },
                        .timestamp = compat.time.nowMillis(),
                    } };
                    try local.prompt(msg);
                }
            },
        }
    }

    pub fn resumeSession(self: *TuiRuntime) !void {
        switch (self.backend) {
            .remote => return error.RemoteResumeNotSupported,
            .local => {
                if (!self.started) try self.start();
                const local = &(self.local_agent orelse return error.RuntimeNotStarted);
                if (self.run_async) local.waitForIdle();
                try local.validateContinueFromContext();
                self.resetEventStreamForTurn();
                self.cancelled.store(false, .release);
                self.completed = false;
                self.last_turn_stop_reason = null;
                if (self.run_async) {
                    try local.continueFromContextAsync();
                } else {
                    try local.continueFromContext();
                }
            },
        }
    }

    pub fn cancel(self: *TuiRuntime) void {
        self.cancelled.store(true, .release);
        if (self.local_agent) |*local| local.abort();
        if (self.remote_client) |*client| {
            if (self.remote_session_id orelse self.remote_pending_session_id) |sid| {
                _ = client.sendAgentStop(sid, "cancelled") catch {};
                self.pumpRemoteIncoming() catch {};
                if (client.isSessionComplete(sid) or self.stream_active) self.completeRemoteCancelled();
                client.removeSessionState(sid);
                self.remote_session_id = null;
                self.remote_pending_session_id = null;
                self.remote_error_emitted = false;
                self.remote_reconnect_attempted = false;
            }
        }
        while (!self.approval_mutex.tryLock()) std.atomic.spinLoopHint();
        self.pending_approval.cancelled = true;
        self.pending_approval.decision = .reject;
        self.approval_mutex.unlock();
    }

    pub fn streamEvents(self: *TuiRuntime) *TuiEventStream {
        if (self.backend == .remote and self.started and !self.event_stream.isDone()) {
            self.pumpRemoteIncoming() catch |err| {
                self.completeRemoteWithError(@errorName(err)) catch {
                    self.push(.{ .@"error" = .{ .message = self.dupeOwned(@errorName(err)) catch OwnedSlice(u8).initBorrowed("") } });
                };
            };
        }
        return &self.event_stream;
    }

    pub fn decideToolApproval(self: *TuiRuntime, tool_call_id: []const u8, decision: ToolApprovalDecision) !void {
        while (!self.approval_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.approval_mutex.unlock();
        if (self.pending_approval.tool_call_id.len > 0 and !std.mem.eql(u8, self.pending_approval.tool_call_id, tool_call_id)) return error.ToolApprovalNotPending;
        if (self.pending_approval.tool_call_id.len == 0) {
            self.pending_approval.tool_call_id = try self.allocator.dupe(u8, tool_call_id);
        }
        self.pending_approval.decision = decision;
        self.pending_approval.cancelled = false;
    }

    fn clearPendingApproval(self: *TuiRuntime) void {
        while (!self.approval_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.approval_mutex.unlock();
        if (self.pending_approval.tool_call_id.len > 0) self.allocator.free(self.pending_approval.tool_call_id);
        self.pending_approval = .{};
    }

    fn waitForToolApproval(self: *TuiRuntime, request: ToolApprovalRequest) ToolApprovalDecision {
        while (!self.approval_mutex.tryLock()) std.atomic.spinLoopHint();
        if (self.pending_approval.tool_call_id.len > 0) self.allocator.free(self.pending_approval.tool_call_id);
        self.pending_approval = .{ .tool_call_id = self.allocator.dupe(u8, request.tool_call_id) catch {
            self.approval_mutex.unlock();
            return .approve;
        } };
        self.approval_mutex.unlock();
        while (!self.cancelled.load(.acquire)) {
            while (!self.approval_mutex.tryLock()) std.atomic.spinLoopHint();
            const decision = self.pending_approval.decision;
            const approval_cancelled = self.pending_approval.cancelled;
            self.approval_mutex.unlock();
            if (decision) |value| return value;
            if (approval_cancelled) return .reject;
            compat.time.sleepNs(1 * std.time.ns_per_ms);
        }
        return .reject;
    }

    fn resetEventStreamForTurn(self: *TuiRuntime) void {
        if (!self.stream_active or self.event_stream.isDone()) {
            self.event_stream.deinit();
            self.event_stream = TuiEventStream.init(self.allocator);
        }
        self.stream_active = true;
    }

    fn rebuildWrappedTools(self: *TuiRuntime) void {
        for (self.original_tools, 0..) |tool, i| {
            self.approval_contexts[i] = .{
                .runtime = self,
                .callback_ctx = self.tool_approval_ctx,
                .callback = self.tool_approval_callback,
                .original_ctx = tool.approval_ctx,
                .original_callback = tool.approval_fn,
                .original_ui_ctx = tool.approval_ui_ctx,
                .original_ui_callback = tool.approval_ui_fn,
                .tool_name = tool.name,
            };
            self.wrapped_tools[i] = .{
                .label = tool.label,
                .name = tool.name,
                .description = tool.description,
                .short_description = tool.short_description,
                .parameters_schema_json = tool.parameters_schema_json,
                .execute = tool.execute,
                .approval_ctx = &self.approval_contexts[i],
                .approval_fn = approveTool,
                .approval_ui_ctx = &self.approval_contexts[i],
                .approval_ui_fn = notifyToolApproval,
            };
        }
    }

    fn push(self: *TuiRuntime, event: TuiEvent) void {
        self.event_stream.push(event) catch {
            var mutable = event;
            mutable.deinit(self.allocator);
        };
    }

    fn pushTerminal(self: *TuiRuntime, event: TuiEvent) void {
        while (true) {
            self.event_stream.push(event) catch |err| switch (err) {
                error.QueueFull => {
                    if (self.event_stream.poll()) |dropped| {
                        var mutable = dropped;
                        mutable.deinit(self.allocator);
                    } else {
                        std.Thread.yield() catch {};
                    }
                    continue;
                },
            };
            return;
        }
    }

    fn dupeOwned(self: *TuiRuntime, value: []const u8) !OwnedSlice(u8) {
        return OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, value));
    }

    fn remoteConfigJson(self: *TuiRuntime) ![]u8 {
        var buffer = std.ArrayList(u8).empty;
        errdefer buffer.deinit(self.allocator);
        var w = json_writer.JsonWriter.init(&buffer, self.allocator);
        try w.beginObject();
        if (self.currentModel()) |model| try w.writeStringField("model", model.id);
        try w.writeBoolField("compact_output", self.compact_output);
        try w.endObject();
        const out = try self.allocator.dupe(u8, buffer.items);
        buffer.deinit(self.allocator);
        return out;
    }

    fn pumpRemoteIncoming(self: *TuiRuntime) !void {
        var receiver = &(self.remote_receiver orelse return error.NoRemoteTransportConfigured);
        const client = &(self.remote_client orelse return error.RuntimeNotStarted);
        while (true) {
            switch (try receiver.read(self.allocator)) {
                .line => |line| {
                    defer self.allocator.free(line);
                    var env = agent_envelope.deserializeEnvelope(line, self.allocator) catch |err| switch (err) {
                        error.InvalidPayloadType, error.InvalidSessionId, error.InvalidUlid, error.InvalidEnumValue => return error.ProtocolVersionMismatch,
                        else => return err,
                    };
                    defer env.deinit(self.allocator);
                    if (env.version != 1) return error.ProtocolVersionMismatch;
                    try client.processEnvelope(env);
                    try self.syncRemoteSessionFromClient(client);
                    try self.drainRemoteClientEvents(client);
                },
                .pending => return,
                .disconnected => {
                    try self.handleRemoteDisconnect();
                    return;
                },
            }
        }
    }

    fn syncRemoteSessionFromClient(self: *TuiRuntime, client: *agent_protocol_client.AgentProtocolClient) !void {
        const client_sid = client.session_id orelse {
            if (self.remote_session_id) |sid| {
                client.removeSessionState(sid);
                self.remote_session_id = null;
            }
            return;
        };

        if (self.remote_pending_session_id == null and self.remote_session_id == null) {
            client.removeSessionState(client_sid);
            return;
        }

        self.remote_session_id = client_sid;
        self.remote_pending_session_id = null;
        self.remote_reconnect_attempted = false;
    }

    fn ensureRemoteSession(self: *TuiRuntime) !void {
        if (self.remote_session_id != null) return;
        if (self.remote_pending_session_id == null) {
            var client = &(self.remote_client orelse return error.RuntimeNotStarted);
            const config_json = try self.remoteConfigJson();
            defer self.allocator.free(config_json);
            const sid = agent_protocol_types.generateSessionId();
            _ = try client.sendAgentStartWithSession(sid, config_json, null);
            self.remote_pending_session_id = sid;
        }
        const timeout_ns = self.remote_session_timeout_ms * std.time.ns_per_ms;
        const start_ns = compat.time.monotonicNanos() catch 0;
        while (true) {
            try self.pumpRemoteIncoming();
            if (self.remote_session_id != null) return;
            const now_ns = compat.time.monotonicNanos() catch (start_ns + timeout_ns);
            if (now_ns -| start_ns >= timeout_ns) return error.RemoteAgentStartFailed;
            compat.time.sleepNs(@min(@as(u64, 10 * std.time.ns_per_ms), timeout_ns - (now_ns -| start_ns)));
        }
    }

    fn completeRemoteWithError(self: *TuiRuntime, message: []const u8) !void {
        if (self.event_stream.isDone()) return;
        self.completed = true;
        self.push(.{ .@"error" = .{ .message = try self.dupeOwned(message) } });
        self.pushTerminal(.{ .agent_end = .{ .reason = .@"error" } });
        self.event_stream.complete(.{ .reason = .@"error" });
        self.stream_active = false;
    }

    fn completeRemoteCancelled(self: *TuiRuntime) void {
        if (self.event_stream.isDone()) return;
        self.completed = true;
        self.pushTerminal(.{ .agent_end = .{ .reason = .cancelled } });
        self.event_stream.complete(.{ .reason = .cancelled });
        self.stream_active = false;
    }

    fn handleRemoteDisconnect(self: *TuiRuntime) !void {
        if (!self.started) return error.ConnectionRefused;
        if (!self.remote_reconnect_attempted) {
            const was_stream_active = self.stream_active and !self.event_stream.isDone();
            self.remote_reconnect_attempted = true;
            var client = &(self.remote_client orelse return error.RuntimeNotStarted);
            if (self.remote_session_id) |sid| client.removeSessionState(sid);
            self.remote_session_id = null;
            if (was_stream_active) try self.completeRemoteWithError("remote connection disconnected");
            const config_json = try self.remoteConfigJson();
            defer self.allocator.free(config_json);
            const sid = agent_protocol_types.generateSessionId();
            _ = try client.sendAgentStartWithSession(sid, config_json, null);
            self.remote_pending_session_id = sid;
            return;
        }
        try self.completeRemoteWithError("remote connection disconnected");
        self.remote_session_id = null;
        self.remote_pending_session_id = null;
    }

    fn drainRemoteClientEvents(self: *TuiRuntime, client: *agent_protocol_client.AgentProtocolClient) !void {
        while (client.popEvent()) |owned_json| {
            var json = owned_json;
            defer json.deinit(self.allocator);
            try self.handleRemoteAgentEventJson(json.slice());
        }
        if (self.remote_session_id) |sid| {
            if (!self.remote_error_emitted) {
                if (client.getLastErrorForSession(sid)) |msg| {
                    self.remote_error_emitted = true;
                    try self.completeRemoteWithError(msg);
                }
            }
        }
    }

    fn messageRole(message: ai_types.Message) TuiEvent.MessageRole {
        return switch (message) {
            .user => .user,
            .assistant => .assistant,
            .tool_result => .tool_result,
        };
    }

    fn onAgentEvent(ctx: ?*anyopaque, event: agent.AgentEvent) void {
        const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
        self.handleAgentEvent(event) catch |err| {
            self.push(.{ .@"error" = .{ .message = self.dupeOwned(@errorName(err)) catch OwnedSlice(u8).initBorrowed("") } });
        };
    }

    fn handleRemoteAgentEventJson(self: *TuiRuntime, json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidRemoteEvent;
        const obj = parsed.value.object;
        const type_name = getJsonString(obj, "type") orelse return error.InvalidRemoteEvent;

        if (std.mem.eql(u8, type_name, "agent_start")) return self.push(.agent_start);
        if (std.mem.eql(u8, type_name, "turn_start")) return self.push(.turn_start);
        if (std.mem.eql(u8, type_name, "message_start")) return self.push(.{ .message_start = .{ .role = parseRemoteMessageRole(getJsonString(obj, "role")) } });
        if (std.mem.eql(u8, type_name, "message_end")) return self.push(.{ .message_end = .{ .role = parseRemoteMessageRole(getJsonString(obj, "role")) } });
        if (std.mem.eql(u8, type_name, "message_update")) {
            const event_value = obj.get("event") orelse return error.InvalidRemoteEvent;
            const msg = try deserializeRemoteMessageValue(self.allocator, event_value);
            switch (msg) {
                .event => |ev| {
                    defer {
                        var mutable = ev;
                        ai_types.deinitAssistantMessageEvent(self.allocator, &mutable);
                    }
                    if (ev == .done) try self.recordRemoteAssistantMessage(ev.done.message);
                    return try self.pushMessageUpdate(ev);
                },
                else => return error.InvalidRemoteEvent,
            }
        }
        if (std.mem.eql(u8, type_name, "tool_execution_start")) return self.push(.{ .tool_execution_start = .{
            .tool_call_id = try self.dupeOwned(getJsonString(obj, "tool_call_id") orelse return error.InvalidRemoteEvent),
            .tool_name = try self.dupeOwned(getJsonString(obj, "tool_name") orelse return error.InvalidRemoteEvent),
            .args_json = try self.dupeOwned(getJsonString(obj, "args_json") orelse ""),
        } });
        if (std.mem.eql(u8, type_name, "tool_execution_update")) return self.push(.{ .tool_execution_update = .{
            .tool_call_id = try self.dupeOwned(getJsonString(obj, "tool_call_id") orelse return error.InvalidRemoteEvent),
            .tool_name = try self.dupeOwned(getJsonString(obj, "tool_name") orelse return error.InvalidRemoteEvent),
            .args_json = try self.dupeOwned(getJsonString(obj, "args_json") orelse ""),
            .partial_result_json = try self.dupeOwned(getJsonString(obj, "partial_result_json") orelse return error.InvalidRemoteEvent),
        } });
        if (std.mem.eql(u8, type_name, "tool_execution_end")) {
            const tool_call_id = getJsonString(obj, "tool_call_id") orelse return error.InvalidRemoteEvent;
            const tool_name = getJsonString(obj, "tool_name") orelse return error.InvalidRemoteEvent;
            const result_json = getJsonString(obj, "result_json") orelse return error.InvalidRemoteEvent;
            const is_error = getJsonBool(obj, "is_error") orelse return error.InvalidRemoteEvent;
            try self.recordRemoteToolResultJson(tool_call_id, tool_name, result_json, getJsonString(obj, "details_json"), is_error);
            return self.push(.{ .tool_execution_end = .{
                .tool_call_id = try self.dupeOwned(tool_call_id),
                .tool_name = try self.dupeOwned(tool_name),
                .result_json = try self.dupeOwned(result_json),
                .is_error = is_error,
            } });
        }
        if (std.mem.eql(u8, type_name, "turn_end")) {
            const reason = parseStopReason(getJsonString(obj, "stop_reason") orelse "stop");
            self.last_turn_stop_reason = reason;
            return self.pushTerminal(.{ .turn_end = .{ .stop_reason = reason } });
        }
        if (std.mem.eql(u8, type_name, "agent_end")) {
            const reason: TuiEndReason = if (self.cancelled.load(.acquire)) .cancelled else if (self.last_turn_stop_reason == .@"error") .@"error" else .completed;
            self.completed = true;
            self.pushTerminal(.{ .agent_end = .{ .reason = reason } });
            self.event_stream.complete(.{ .reason = reason });
            self.stream_active = false;
            return;
        }
        if (std.mem.eql(u8, type_name, "error")) return self.push(.{ .@"error" = .{ .message = try self.dupeOwned(getJsonString(obj, "message") orelse return error.InvalidRemoteEvent) } });
    }

    fn handleAgentEvent(self: *TuiRuntime, event: agent.AgentEvent) !void {
        switch (event) {
            .agent_start => self.push(.agent_start),
            .turn_start => self.push(.turn_start),
            .message_start => |payload| self.push(.{ .message_start = .{ .role = messageRole(payload.message) } }),
            .message_update => |payload| {
                if (self.backend == .remote and payload.event == .done) try self.recordRemoteAssistantMessage(payload.event.done.message);
                try self.pushMessageUpdate(payload.event);
            },
            .message_end => |payload| self.push(.{ .message_end = .{ .role = messageRole(payload.message) } }),
            .tool_execution_start => |payload| self.push(.{ .tool_execution_start = .{
                .tool_call_id = try self.dupeOwned(payload.tool_call_id),
                .tool_name = try self.dupeOwned(payload.tool_name),
                .args_json = try self.dupeOwned(payload.args_json),
            } }),
            .tool_execution_update => |payload| self.push(.{ .tool_execution_update = .{
                .tool_call_id = try self.dupeOwned(payload.tool_call_id),
                .tool_name = try self.dupeOwned(payload.tool_name),
                .args_json = try self.dupeOwned(payload.args_json),
                .partial_result_json = try self.dupeOwned(payload.partial_result_json),
            } }),
            .tool_execution_end => |payload| self.push(.{ .tool_execution_end = .{
                .tool_call_id = try self.dupeOwned(payload.tool_call_id),
                .tool_name = try self.dupeOwned(payload.tool_name),
                .result_json = try self.dupeOwned(payload.result_json),
                .is_error = payload.is_error,
            } }),
            .turn_end => |payload| {
                self.last_turn_stop_reason = payload.message.stop_reason;
                self.pushTerminal(.{ .turn_end = .{ .stop_reason = payload.message.stop_reason } });
            },
            .agent_end => {
                const reason: TuiEndReason = if (self.cancelled.load(.acquire)) .cancelled else if (self.last_turn_stop_reason == .@"error") .@"error" else .completed;
                self.completed = true;
                self.pushTerminal(.{ .agent_end = .{ .reason = reason } });
                self.event_stream.complete(.{ .reason = reason });
                self.stream_active = false;
            },
            .context_usage, .prompt_segment_usage => {},
        }
    }

    fn recordRemoteAssistantMessage(self: *TuiRuntime, message: ai_types.AssistantMessage) !void {
        try self.remote_messages.append(self.allocator, try ai_types.cloneMessage(self.allocator, .{ .assistant = message }));
    }

    fn recordRemoteToolResultJson(
        self: *TuiRuntime,
        tool_call_id: []const u8,
        tool_name: []const u8,
        result_json: []const u8,
        details_json: ?[]const u8,
        is_error: bool,
    ) !void {
        if (self.backend != .remote) return;
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{});
        defer parsed.deinit();
        const content = try parseRemoteToolResultContent(self.allocator, parsed.value);
        errdefer deinitRemoteUserContentParts(self.allocator, content);
        const id = try self.allocator.dupe(u8, tool_call_id);
        errdefer self.allocator.free(id);
        const name = try self.allocator.dupe(u8, tool_name);
        errdefer self.allocator.free(name);
        var details = if (details_json) |value|
            OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, value))
        else
            OwnedSlice(u8).initBorrowed("");
        errdefer details.deinit(self.allocator);
        try self.remote_messages.append(self.allocator, .{ .tool_result = .{
            .tool_call_id = id,
            .tool_name = name,
            .content = content,
            .details_json = details,
            .is_error = is_error,
            .timestamp = compat.time.nowMillis(),
        } });
    }

    fn remoteSerializableTools(self: *TuiRuntime) []const agent.AgentTool {
        return self.original_tools;
    }

    fn clearRemoteMessages(self: *TuiRuntime) void {
        for (self.remote_messages.items) |*message| message.deinit(self.allocator);
        self.remote_messages.clearRetainingCapacity();
    }

    fn pushMessageUpdate(self: *TuiRuntime, event: ai_types.AssistantMessageEvent) !void {
        switch (event) {
            .text_delta => |payload| self.push(.{ .text_delta = .{
                .content_index = payload.content_index,
                .delta = try self.dupeOwned(payload.delta),
            } }),
            .thinking_delta => |payload| self.push(.{ .thinking_delta = .{
                .content_index = payload.content_index,
                .delta = try self.dupeOwned(payload.delta),
            } }),
            .toolcall_delta => |payload| self.push(.{ .tool_call_delta = .{
                .content_index = payload.content_index,
                .delta = try self.dupeOwned(payload.delta),
            } }),
            else => {},
        }
    }
};

fn parseStopReason(value: []const u8) ai_types.StopReason {
    return std.meta.stringToEnum(ai_types.StopReason, value) orelse .stop;
}

fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn getJsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn parseRemoteMessageRole(value: ?[]const u8) TuiEvent.MessageRole {
    const role = value orelse return .assistant;
    if (std.mem.eql(u8, role, "user")) return .user;
    if (std.mem.eql(u8, role, "tool") or std.mem.eql(u8, role, "tool_result")) return .tool_result;
    return .assistant;
}

fn deserializeRemoteMessageValue(allocator: std.mem.Allocator, value: std.json.Value) !transport.MessageOrControl {
    if (value != .object) return error.InvalidRemoteEvent;
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    return transport.deserialize(json, allocator) catch return error.InvalidRemoteEvent;
}

fn makeRemoteUserMessage(allocator: std.mem.Allocator, text: []const u8) !ai_types.Message {
    return .{ .user = .{
        .content = .{ .text = try allocator.dupe(u8, text) },
        .timestamp = compat.time.nowMillis(),
    } };
}

fn makeRemoteMessageJson(allocator: std.mem.Allocator, model: ?ai_types.Model, messages: []const ai_types.Message, tools: []const agent.AgentTool) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);
    try w.beginObject();
    if (model) |m| {
        const formatted_model_ref = try model_ref.formatModelRef(allocator, m.provider, m.api, m.id);
        defer allocator.free(formatted_model_ref);
        try w.writeStringField("model_ref", formatted_model_ref);
    }
    try w.writeKey("messages");
    try w.beginArray();
    for (messages) |message| try writeRemoteMessage(&w, message);
    try w.endArray();
    try w.writeKey("tools");
    try w.beginArray();
    for (tools) |tool| try writeRemoteTool(&w, tool);
    try w.endArray();
    try w.endObject();
    const out = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return out;
}

fn writeRemoteMessage(w: *json_writer.JsonWriter, message: ai_types.Message) !void {
    try w.beginObject();
    switch (message) {
        .user => |user| {
            try w.writeStringField("role", "user");
            try w.writeKey("content");
            try writeRemoteUserContent(w, user.content);
            try w.writeIntField("timestamp", user.timestamp);
        },
        .assistant => |assistant| {
            try w.writeStringField("role", "assistant");
            try w.writeKey("content");
            try writeRemoteAssistantContent(w, assistant.content);
            try w.writeStringField("api", assistant.api);
            try w.writeStringField("provider", assistant.provider);
            try w.writeStringField("model", assistant.model);
            try w.writeStringField("stop_reason", @tagName(assistant.stop_reason));
            try w.writeIntField("timestamp", assistant.timestamp);
        },
        .tool_result => |tool_result| {
            try w.writeStringField("role", "tool");
            try w.writeStringField("tool_call_id", tool_result.tool_call_id);
            try w.writeStringField("tool_name", tool_result.tool_name);
            try w.writeBoolField("is_error", tool_result.is_error);
            if (tool_result.getDetailsJson()) |details| try w.writeStringField("details_json", details);
            try w.writeKey("content");
            try writeRemoteUserContentParts(w, tool_result.content);
            try w.writeIntField("timestamp", tool_result.timestamp);
        },
    }
    try w.endObject();
}

fn writeRemoteUserContent(w: *json_writer.JsonWriter, content: ai_types.UserContent) !void {
    switch (content) {
        .text => |text| try w.writeString(text),
        .parts => |parts| try writeRemoteUserContentParts(w, parts),
    }
}

fn writeRemoteUserContentParts(w: *json_writer.JsonWriter, parts: []const ai_types.UserContentPart) !void {
    try w.beginArray();
    for (parts) |part| {
        try w.beginObject();
        switch (part) {
            .text => |text| {
                try w.writeStringField("type", "text");
                try w.writeStringField("text", text.text);
                if (text.text_signature) |signature| try w.writeStringField("text_signature", signature);
            },
            .image => |image| {
                try w.writeStringField("type", "image");
                try w.writeStringField("data", image.data);
                try w.writeStringField("mime_type", image.mime_type);
            },
        }
        try w.endObject();
    }
    try w.endArray();
}

fn writeRemoteAssistantContent(w: *json_writer.JsonWriter, content: []const ai_types.AssistantContent) !void {
    try w.beginArray();
    for (content) |block| {
        try w.beginObject();
        switch (block) {
            .text => |text| {
                try w.writeStringField("type", "text");
                try w.writeStringField("text", text.text);
                if (text.text_signature) |signature| try w.writeStringField("text_signature", signature);
            },
            .thinking => |thinking| {
                try w.writeStringField("type", "thinking");
                try w.writeStringField("thinking", thinking.thinking);
                if (thinking.thinking_signature) |signature| try w.writeStringField("thinking_signature", signature);
            },
            .tool_call => |tool_call| {
                try w.writeStringField("type", "tool_call");
                try w.writeStringField("id", tool_call.id);
                try w.writeStringField("name", tool_call.name);
                try w.writeStringField("arguments_json", tool_call.arguments_json);
                if (tool_call.thought_signature) |signature| try w.writeStringField("thought_signature", signature);
            },
            .image => |image| {
                try w.writeStringField("type", "image");
                try w.writeStringField("data", image.data);
                try w.writeStringField("mime_type", image.mime_type);
            },
        }
        try w.endObject();
    }
    try w.endArray();
}

fn writeRemoteTool(w: *json_writer.JsonWriter, tool: agent.AgentTool) !void {
    try w.beginObject();
    try w.writeStringField("name", tool.name);
    try w.writeStringField("description", tool.description);
    if (tool.short_description) |short| try w.writeStringField("short_description", short);
    try w.writeStringField("label", tool.label);
    try w.writeStringField("parameters_schema_json", tool.parameters_schema_json);
    try w.writeBoolField("requires_approval", tool.approval_fn != null or tool.approval_ui_fn != null);
    try w.endObject();
}

fn parseRemoteToolResultContent(allocator: std.mem.Allocator, value: std.json.Value) ![]ai_types.UserContentPart {
    if (value != .array) {
        const parts = try allocator.alloc(ai_types.UserContentPart, 1);
        errdefer allocator.free(parts);
        parts[0] = try parseRemoteToolResultScalar(allocator, value);
        return parts;
    }

    var parts = std.ArrayList(ai_types.UserContentPart).empty;
    errdefer {
        for (parts.items) |*part| part.deinit(allocator);
        parts.deinit(allocator);
    }
    for (value.array.items) |item| {
        try parts.append(allocator, try parseRemoteUserContentPart(allocator, item));
    }
    return parts.toOwnedSlice(allocator);
}

fn parseRemoteToolResultScalar(allocator: std.mem.Allocator, value: std.json.Value) !ai_types.UserContentPart {
    if (value == .string) return .{ .text = .{ .text = try allocator.dupe(u8, value.string) } };
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    errdefer allocator.free(json);
    return .{ .text = .{ .text = json } };
}

fn parseRemoteUserContentPart(allocator: std.mem.Allocator, value: std.json.Value) !ai_types.UserContentPart {
    if (value == .string) return .{ .text = .{ .text = try allocator.dupe(u8, value.string) } };
    if (value != .object) return error.InvalidRemoteEvent;
    const obj = value.object;
    const type_name = getJsonString(obj, "type") orelse return error.InvalidRemoteEvent;
    if (std.mem.eql(u8, type_name, "text")) {
        return .{ .text = .{ .text = try allocator.dupe(u8, getJsonString(obj, "text") orelse "") } };
    }
    if (std.mem.eql(u8, type_name, "image")) {
        const data = try allocator.dupe(u8, getJsonString(obj, "data") orelse return error.InvalidRemoteEvent);
        errdefer allocator.free(data);
        const mime_type = try allocator.dupe(u8, getJsonString(obj, "mime_type") orelse return error.InvalidRemoteEvent);
        errdefer allocator.free(mime_type);
        return .{ .image = .{ .data = data, .mime_type = mime_type } };
    }
    return error.InvalidRemoteEvent;
}

fn deinitRemoteUserContentParts(allocator: std.mem.Allocator, parts: []ai_types.UserContentPart) void {
    for (parts) |*part| part.deinit(allocator);
    allocator.free(parts);
}

fn notifyToolApproval(ctx: ?*anyopaque, request: agent.ToolApprovalRequest, allocator: std.mem.Allocator) void {
    const approval_ctx: *ApprovalContext = @ptrCast(@alignCast(ctx.?));
    if (approval_ctx.original_ui_callback) |callback| {
        callback(approval_ctx.original_ui_ctx, request, allocator);
    }

    const runtime = approval_ctx.runtime;
    runtime.push(.{ .tool_approval_requested = .{
        .tool_call_id = runtime.dupeOwned(request.tool_call_id) catch OwnedSlice(u8).initBorrowed(""),
        .tool_name = runtime.dupeOwned(request.tool_name) catch OwnedSlice(u8).initBorrowed(""),
        .args_json = runtime.dupeOwned(request.args_json) catch OwnedSlice(u8).initBorrowed(""),
    } });
}

fn approveTool(ctx: ?*anyopaque, request: agent.ToolApprovalRequest) agent.ToolApprovalDecision {
    const approval_ctx: *ApprovalContext = @ptrCast(@alignCast(ctx.?));
    if (approval_ctx.original_callback) |callback| {
        switch (callback(approval_ctx.original_ctx, request)) {
            .approve, .approve_always => {},
            .reject, .reject_always => return .reject,
        }
    }
    const approval_request = ToolApprovalRequest{
        .tool_call_id = request.tool_call_id,
        .tool_name = request.tool_name,
        .args_json = request.args_json,
    };
    if (approval_ctx.callback) |callback| {
        return switch (callback(approval_ctx.callback_ctx, approval_request)) {
            .approve => .approve,
            .reject => .reject,
            .approve_always => .approve_always,
            .reject_always => .reject_always,
        };
    }
    return .approve;
}

fn sessionStart(ctx: ?*anyopaque) anyerror!void {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    try self.start();
}

fn sessionResume(ctx: ?*anyopaque) anyerror!void {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    try self.resumeSession();
}

fn sessionCancel(ctx: ?*anyopaque) void {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    self.cancel();
}

fn sessionSubmitTurn(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    try self.submitTurn(text);
}

fn sessionSwitchModel(ctx: ?*anyopaque, model_id: []const u8) anyerror!void {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    try self.switchModel(model_id);
}

fn sessionCurrentModel(ctx: ?*anyopaque) ?ai_types.Model {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    return self.currentModel();
}

fn sessionDecideToolApproval(ctx: ?*anyopaque, tool_call_id: []const u8, decision: ToolApprovalDecision) anyerror!void {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    try self.decideToolApproval(tool_call_id, decision);
}

fn sessionStreamEvents(ctx: ?*anyopaque) *TuiEventStream {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    return self.streamEvents();
}

const test_model_a = ai_types.Model{
    .id = "model-a",
    .name = "Model A",
    .api = "test-api",
    .provider = "test-provider",
    .base_url = "https://example.invalid",
    .reasoning = false,
    .input = &.{"text"},
    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
    .context_window = 8192,
    .max_tokens = 1024,
};

const test_model_b = ai_types.Model{
    .id = "model-b",
    .name = "Model B",
    .api = "test-api",
    .provider = "test-provider",
    .base_url = "https://example.invalid",
    .reasoning = false,
    .input = &.{"text"},
    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
    .context_window = 8192,
    .max_tokens = 1024,
};

const MockProtocolCtx = struct {
    call_count: usize = 0,
    last_model_id: []const u8 = "",
    wait_for_cancel: bool = false,
    flood_count: usize = 0,
    tool_first: bool = false,
    force_error: bool = false,
};

fn makeAssistantMessage(allocator: std.mem.Allocator, model: ai_types.Model, content: []const ai_types.AssistantContent, stop_reason: ai_types.StopReason) !ai_types.AssistantMessage {
    const blocks = try allocator.alloc(ai_types.AssistantContent, content.len);
    var initialized: usize = 0;
    errdefer ai_types.deinitAssistantContent(allocator, blocks[0..initialized]);

    for (content, 0..) |block, i| {
        blocks[i] = switch (block) {
            .text => |t| .{ .text = .{
                .text = try allocator.dupe(u8, t.text),
                .text_signature = if (t.text_signature) |s| try allocator.dupe(u8, s) else null,
            } },
            .thinking => |t| .{ .thinking = .{
                .thinking = try allocator.dupe(u8, t.thinking),
                .thinking_signature = if (t.thinking_signature) |s| try allocator.dupe(u8, s) else null,
            } },
            .tool_call => |tc| .{ .tool_call = .{
                .id = try allocator.dupe(u8, tc.id),
                .name = try allocator.dupe(u8, tc.name),
                .arguments_json = try allocator.dupe(u8, tc.arguments_json),
                .thought_signature = if (tc.thought_signature) |s| try allocator.dupe(u8, s) else null,
            } },
            .image => |img| .{ .image = .{
                .data = try allocator.dupe(u8, img.data),
                .mime_type = try allocator.dupe(u8, img.mime_type),
            } },
        };
        initialized += 1;
    }

    return .{
        .content = blocks,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = .{},
        .stop_reason = stop_reason,
        .timestamp = 0,
    };
}

fn emptyAssistantMessage(model: ai_types.Model, stop_reason: ai_types.StopReason) ai_types.AssistantMessage {
    return .{
        .content = &.{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = .{},
        .stop_reason = stop_reason,
        .timestamp = 0,
    };
}

fn pushDoneAndComplete(stream: *event_stream.AssistantMessageEventStream, allocator: std.mem.Allocator, model: ai_types.Model, content: []const ai_types.AssistantContent, reason: ai_types.StopReason) !void {
    const event_message = try makeAssistantMessage(allocator, model, content, reason);
    errdefer {
        var msg = event_message;
        msg.deinit(allocator);
    }
    const result_message = try makeAssistantMessage(allocator, model, content, reason);
    errdefer {
        var msg = result_message;
        msg.deinit(allocator);
    }
    if (reason == .@"error") {
        try stream.push(.{ .@"error" = .{ .reason = reason, .err = event_message } });
    } else {
        try stream.push(.{ .done = .{ .reason = reason, .message = event_message } });
    }
    stream.complete(result_message);
}

fn pushTextResponse(stream: *event_stream.AssistantMessageEventStream, allocator: std.mem.Allocator, model: ai_types.Model, text: []const u8) !void {
    const partial = emptyAssistantMessage(model, .stop);
    try stream.push(.{ .start = .{ .partial = partial } });
    try stream.push(.{ .text_delta = .{ .content_index = 0, .delta = text, .partial = partial } });

    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = text } }};
    try pushDoneAndComplete(stream, allocator, model, &content, .stop);
}

fn mockStream(
    ctx: ?*anyopaque,
    model: ai_types.Model,
    context: ai_types.Context,
    options: agent.ProtocolOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageEventStream {
    _ = context;
    const mock: *MockProtocolCtx = @ptrCast(@alignCast(ctx.?));
    mock.call_count += 1;
    mock.last_model_id = model.id;

    const stream = try allocator.create(event_stream.AssistantMessageEventStream);
    stream.* = event_stream.AssistantMessageEventStream.init(allocator);

    if (mock.force_error) {
        stream.completeWithError("forced provider error");
        return stream;
    }

    if (mock.wait_for_cancel) {
        if (options.cancel_token) |token| {
            var waits: usize = 0;
            while (!token.isCancelled() and waits < 100) : (waits += 1) {
                std.testing.io.sleep(.fromNanoseconds(1 * std.time.ns_per_ms), .boot) catch {};
            }
        }
        try stream.push(.{ .done = .{ .reason = .aborted, .message = emptyAssistantMessage(model, .aborted) } });
        stream.complete(emptyAssistantMessage(model, .aborted));
        return stream;
    }

    if (mock.flood_count > 0) {
        const partial = emptyAssistantMessage(model, .stop);
        try stream.push(.{ .start = .{ .partial = partial } });
        var i: usize = 0;
        while (i < mock.flood_count) : (i += 1) {
            try stream.push(.{ .text_delta = .{ .content_index = 0, .delta = "x", .partial = partial } });
            if (stream.poll()) |_| {}
        }
        const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "done" } }};
        try pushDoneAndComplete(stream, allocator, model, &content, .stop);
        return stream;
    }

    if (mock.tool_first and mock.call_count == 1) {
        const content = [_]ai_types.AssistantContent{.{ .tool_call = .{ .id = "call-1", .name = "demo_tool", .arguments_json = "{}" } }};
        try stream.push(.{ .start = .{ .partial = emptyAssistantMessage(model, .tool_use) } });
        try pushDoneAndComplete(stream, allocator, model, &content, .tool_use);
        return stream;
    }

    try pushTextResponse(stream, allocator, model, "hello");
    return stream;
}

fn makeProtocol(ctx: *MockProtocolCtx) agent.ProtocolClient {
    return .{ .stream_fn = mockStream, .ctx = ctx };
}

fn collectUntilEnd(tui_session: *TuiSession, saw_turn_start: *bool, saw_message_start: *bool, saw_text_delta: *bool, saw_message_end: *bool, saw_turn_end: *bool) void {
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .turn_start => saw_turn_start.* = true,
            .message_start => |payload| {
                if (payload.role == .assistant) saw_message_start.* = true;
            },
            .text_delta => saw_text_delta.* = true,
            .message_end => |payload| {
                if (payload.role == .assistant) saw_message_end.* = true;
            },
            .turn_end => saw_turn_end.* = true,
            .agent_end => break,
            else => {},
        }
    }
}

test "runtime registers default local tools and allows overrides" {
    var mock = MockProtocolCtx{};
    const replacement = agent.AgentTool{ .label = "Wrapped Shell", .name = "shell_execute", .description = "Wrapped shell tool", .parameters_schema_json = "{}", .execute = demoTool };
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .tools = &.{replacement}, .run_async = false });
    defer runtime.deinit();
    try std.testing.expect(runtime.tool_registry.resolve("shell_execute") != null);
    try std.testing.expect(runtime.tool_registry.resolve("file_read") != null);
    try std.testing.expectEqualStrings("Wrapped Shell", runtime.tool_registry.resolve("shell_execute").?.label);
    try std.testing.expect(runtime.original_tools.len >= 9);
}

test "runtime submit turn emits normalized events" {
    var mock = MockProtocolCtx{};
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = false });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("hi");
    if (runtime.local_agent) |*local| local.waitForIdle();

    var saw_turn_start = false;
    var saw_message_start = false;
    var saw_text_delta = false;
    var saw_message_end = false;
    var saw_turn_end = false;
    collectUntilEnd(&tui_session, &saw_turn_start, &saw_message_start, &saw_text_delta, &saw_message_end, &saw_turn_end);

    try std.testing.expect(saw_turn_start);
    try std.testing.expect(saw_message_start);
    try std.testing.expect(saw_text_delta);
    try std.testing.expect(saw_message_end);
    try std.testing.expect(saw_turn_end);
    try std.testing.expectEqual(@as(usize, 0), runtime.remote_messages.items.len);
}

test "runtime cancel emits cancelled agent_end" {
    var mock = MockProtocolCtx{ .wait_for_cancel = true };
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = true });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("hi");
    tui_session.cancel();
    if (runtime.local_agent) |*local| local.waitForIdle();

    var saw_cancelled = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        if (ev == .agent_end) {
            saw_cancelled = ev.agent_end.reason == .cancelled;
            break;
        }
    }
    try std.testing.expect(saw_cancelled);
}

const ApprovalCtx = struct { decision: ToolApprovalDecision, calls: usize = 0 };
const OriginalApprovalCtx = struct { decision: agent.ToolApprovalDecision, calls: usize = 0 };
const OriginalApprovalUiCtx = struct { calls: usize = 0 };

fn approvalCallback(ctx: ?*anyopaque, request: ToolApprovalRequest) ToolApprovalDecision {
    _ = request;
    const approval: *ApprovalCtx = @ptrCast(@alignCast(ctx.?));
    approval.calls += 1;
    return approval.decision;
}

fn originalApprovalCallback(ctx: ?*anyopaque, request: agent.ToolApprovalRequest) agent.ToolApprovalDecision {
    _ = request;
    const approval: *OriginalApprovalCtx = @ptrCast(@alignCast(ctx.?));
    approval.calls += 1;
    return approval.decision;
}

fn originalApprovalUiCallback(ctx: ?*anyopaque, request: agent.ToolApprovalRequest, allocator: std.mem.Allocator) void {
    _ = request;
    _ = allocator;
    const approval: *OriginalApprovalUiCtx = @ptrCast(@alignCast(ctx.?));
    approval.calls += 1;
}

fn demoTool(
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?agent.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!agent.AgentToolResult {
    _ = tool_call_id;
    _ = args_json;
    _ = cancel_token;
    _ = on_update_ctx;
    _ = on_update;
    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "tool ok") } };
    return .{ .content = OwnedSlice(ai_types.UserContentPart).initOwned(content) };
}

test "tool approval approve and reject paths emit tool events" {
    const tools = [_]agent.AgentTool{.{
        .label = "Demo",
        .name = "demo_tool",
        .description = "Demo tool",
        .parameters_schema_json = "{}",
        .execute = demoTool,
    }};
    const models = [_]ai_types.Model{test_model_a};

    var approve_mock = MockProtocolCtx{ .tool_first = true };
    var approve_ctx = ApprovalCtx{ .decision = .approve };
    var approve_runtime = try TuiRuntime.init(std.testing.allocator, .{
        .protocol = makeProtocol(&approve_mock),
        .models = &models,
        .tools = &tools,
        .tool_approval_ctx = &approve_ctx,
        .tool_approval_callback = approvalCallback,
        .run_async = false,
    });
    defer approve_runtime.deinit();
    var approve_session = approve_runtime.createSession();
    try approve_session.start();
    try approve_session.submitTurn("use tool");
    if (approve_runtime.local_agent) |*local| local.waitForIdle();

    var approve_saw_approval = false;
    var approve_saw_tool_end = false;
    while (approve_session.waitEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .tool_approval_requested => approve_saw_approval = true,
            .tool_execution_end => approve_saw_tool_end = !ev.tool_execution_end.is_error,
            .agent_end => break,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), approve_ctx.calls);
    try std.testing.expect(approve_saw_approval);
    try std.testing.expect(approve_saw_tool_end);

    var reject_mock = MockProtocolCtx{ .tool_first = true };
    var reject_ctx = ApprovalCtx{ .decision = .reject };
    var reject_runtime = try TuiRuntime.init(std.testing.allocator, .{
        .protocol = makeProtocol(&reject_mock),
        .models = &models,
        .tools = &tools,
        .tool_approval_ctx = &reject_ctx,
        .tool_approval_callback = approvalCallback,
        .run_async = false,
    });
    defer reject_runtime.deinit();
    var reject_session = reject_runtime.createSession();
    try reject_session.start();
    try reject_session.submitTurn("use tool");
    if (reject_runtime.local_agent) |*local| local.waitForIdle();

    var reject_saw_error_tool = false;
    while (reject_session.waitEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .tool_execution_end => reject_saw_error_tool = ev.tool_execution_end.is_error,
            .agent_end => break,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), reject_ctx.calls);
    try std.testing.expect(reject_saw_error_tool);
}

test "event stream resets between turns" {
    var mock = MockProtocolCtx{};
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = true });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("first");

    var saw_turn_start = false;
    var saw_message_start = false;
    var saw_text_delta = false;
    var saw_message_end = false;
    var saw_turn_end = false;
    collectUntilEnd(&tui_session, &saw_turn_start, &saw_message_start, &saw_text_delta, &saw_message_end, &saw_turn_end);

    try tui_session.submitTurn("second");
    if (runtime.local_agent) |*local| local.waitForIdle();

    saw_turn_start = false;
    saw_message_start = false;
    saw_text_delta = false;
    saw_message_end = false;
    saw_turn_end = false;
    collectUntilEnd(&tui_session, &saw_turn_start, &saw_message_start, &saw_text_delta, &saw_message_end, &saw_turn_end);

    try std.testing.expectEqual(@as(usize, 2), mock.call_count);
    try std.testing.expect(saw_turn_start);
    try std.testing.expect(saw_message_start);
    try std.testing.expect(saw_text_delta);
    try std.testing.expect(saw_message_end);
    try std.testing.expect(saw_turn_end);
}

test "terminal events survive full TUI queue" {
    var mock = MockProtocolCtx{ .flood_count = 300 };
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = false });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("flood");

    var saw_turn_end = false;
    var saw_agent_end = false;
    while (tui_session.waitEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .turn_end => saw_turn_end = true,
            .agent_end => {
                saw_agent_end = true;
                break;
            },
            else => {},
        }
    }

    try std.testing.expect(saw_turn_end);
    try std.testing.expect(saw_agent_end);
}

test "preserves original tool approval when wrapping" {
    var original_ctx = OriginalApprovalCtx{ .decision = .reject_always };
    const tools = [_]agent.AgentTool{.{
        .label = "Demo",
        .name = "demo_tool",
        .description = "Demo tool",
        .parameters_schema_json = "{}",
        .execute = demoTool,
        .approval_ctx = &original_ctx,
        .approval_fn = originalApprovalCallback,
    }};
    const models = [_]ai_types.Model{test_model_a};
    var mock = MockProtocolCtx{ .tool_first = true };
    var runtime = try TuiRuntime.init(std.testing.allocator, .{
        .protocol = makeProtocol(&mock),
        .models = &models,
        .tools = &tools,
        .run_async = false,
    });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("use tool");
    if (runtime.local_agent) |*local| local.waitForIdle();

    var saw_rejected_tool = false;
    while (tui_session.waitEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .tool_execution_end => saw_rejected_tool = ev.tool_execution_end.is_error,
            .agent_end => break,
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 1), original_ctx.calls);
    try std.testing.expect(saw_rejected_tool);
}

test "preserves original tool approval UI when wrapping" {
    var original_ctx = OriginalApprovalUiCtx{};
    var approval_ctx = ApprovalCtx{ .decision = .approve };
    const tools = [_]agent.AgentTool{.{
        .label = "Demo",
        .name = "demo_tool",
        .description = "Demo tool",
        .parameters_schema_json = "{}",
        .execute = demoTool,
        .approval_ui_ctx = &original_ctx,
        .approval_ui_fn = originalApprovalUiCallback,
    }};
    const models = [_]ai_types.Model{test_model_a};
    var mock = MockProtocolCtx{ .tool_first = true };
    var runtime = try TuiRuntime.init(std.testing.allocator, .{
        .protocol = makeProtocol(&mock),
        .models = &models,
        .tools = &tools,
        .tool_approval_ctx = &approval_ctx,
        .tool_approval_callback = approvalCallback,
        .run_async = false,
    });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("use tool");
    if (runtime.local_agent) |*local| local.waitForIdle();

    var saw_tui_approval = false;
    while (tui_session.waitEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .tool_approval_requested => saw_tui_approval = true,
            .agent_end => break,
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 1), original_ctx.calls);
    try std.testing.expect(saw_tui_approval);
}

test "model switch affects next turn" {
    var mock = MockProtocolCtx{};
    const models = [_]ai_types.Model{ test_model_a, test_model_b };
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = false });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.switchModel("model-b");
    try tui_session.submitTurn("hi");
    if (runtime.local_agent) |*local| local.waitForIdle();

    var saw_turn_start = false;
    var saw_message_start = false;
    var saw_text_delta = false;
    var saw_message_end = false;
    var saw_turn_end = false;
    collectUntilEnd(&tui_session, &saw_turn_start, &saw_message_start, &saw_text_delta, &saw_message_end, &saw_turn_end);

    try std.testing.expectEqualStrings("model-b", mock.last_model_id);
}

test "model switch is rejected while async turn is running" {
    var mock = MockProtocolCtx{ .wait_for_cancel = true };
    const models = [_]ai_types.Model{ test_model_a, test_model_b };
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = true });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("hi");
    try std.testing.expectError(error.AgentAlreadyStreaming, tui_session.switchModel("model-b"));
    tui_session.cancel();
    if (runtime.local_agent) |*local| local.waitForIdle();
    try tui_session.switchModel("model-b");
    try std.testing.expectEqualStrings("model-b", runtime.currentModel().?.id);
}

test "failed resume does not reset event stream" {
    var mock = MockProtocolCtx{};
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = true });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try std.testing.expectError(error.NoMessagesToContinue, tui_session.resumeSession());
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);
    try std.testing.expect(!runtime.stream_active);
    try std.testing.expect(tui_session.popEvent() == null);
}

test "async submit without selected model fails before stream reset" {
    var mock = MockProtocolCtx{};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .run_async = true });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try std.testing.expectError(error.NoModelConfigured, tui_session.submitTurn("hi"));
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);
    try std.testing.expect(!runtime.stream_active);
    try std.testing.expect(tui_session.popEvent() == null);
}

test "failed turns emit error end reason" {
    var mock = MockProtocolCtx{ .force_error = true };
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = false });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try std.testing.expectError(error.AgentLoopFailed, tui_session.submitTurn("fail"));
    if (runtime.local_agent) |*local| local.waitForIdle();

    var saw_error_end = false;
    while (tui_session.waitEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .agent_end => {
                saw_error_end = ev.agent_end.reason == .@"error";
                break;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_error_end);
}

const RemoteMock = struct {
    writes: std.ArrayList([]u8),
    reads: std.ArrayList([]u8),
    disconnected: bool = false,
    sender_closed: bool = false,
    receiver_closed: bool = false,

    fn init() RemoteMock {
        return .{ .writes = std.ArrayList([]u8).empty, .reads = std.ArrayList([]u8).empty };
    }

    fn deinit(self: *RemoteMock, allocator: std.mem.Allocator) void {
        for (self.writes.items) |item| allocator.free(item);
        for (self.reads.items) |item| allocator.free(item);
        self.writes.deinit(allocator);
        self.reads.deinit(allocator);
    }

    fn sender(self: *RemoteMock) transport.AsyncSender {
        return .{ .context = self, .write_fn = writeFn, .flush_fn = flushFn, .close_fn = closeSenderFn };
    }

    fn receiver(self: *RemoteMock) RemoteLineReceiver {
        return .{ .ctx = self, .read_line_fn = readLineFn, .read_result_fn = readResultFn, .close_fn = closeReceiverFn };
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) !void {
        const self: *RemoteMock = @ptrCast(@alignCast(ctx));
        try self.writes.append(std.testing.allocator, try std.testing.allocator.dupe(u8, data));
    }

    fn flushFn(_: *anyopaque) !void {}

    fn closeSenderFn(ctx: *anyopaque) void {
        const self: *RemoteMock = @ptrCast(@alignCast(ctx));
        self.sender_closed = true;
    }

    fn closeReceiverFn(ctx: *anyopaque) void {
        const self: *RemoteMock = @ptrCast(@alignCast(ctx));
        self.receiver_closed = true;
    }

    fn readLineFn(ctx: *anyopaque, allocator: std.mem.Allocator) !?[]const u8 {
        return switch (try readResultFn(ctx, allocator)) {
            .line => |line| line,
            .pending, .disconnected => null,
        };
    }

    fn queuePending(self: *RemoteMock, count: usize) !void {
        var i: usize = 0;
        while (i < count) : (i += 1) try self.reads.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "__pending__"));
    }

    fn queueInvalid(self: *RemoteMock) !void {
        try self.reads.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "{bad"));
    }

    fn readResultFn(ctx: *anyopaque, allocator: std.mem.Allocator) !RemoteReadResult {
        const self: *RemoteMock = @ptrCast(@alignCast(ctx));
        if (self.disconnected) return .disconnected;
        if (self.reads.items.len == 0) return .pending;
        const line = self.reads.orderedRemove(0);
        if (std.mem.eql(u8, line, "__pending__")) {
            std.testing.allocator.free(line);
            return .pending;
        }
        if (allocator.ptr == std.testing.allocator.ptr) return .{ .line = line };
        defer std.testing.allocator.free(line);
        return .{ .line = try allocator.dupe(u8, line) };
    }

    fn queueEnvelope(self: *RemoteMock, allocator: std.mem.Allocator, env: agent_protocol_types.Envelope) !void {
        const json = try agent_envelope.serializeEnvelope(env, allocator);
        try self.reads.append(allocator, json);
    }
};

test "remote mode sends agent_start envelope via mock transport" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    const sid = agent_protocol_types.generateSessionId();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });

    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver() });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try std.testing.expectEqual(@as(usize, 1), mock.writes.items.len);

    var env = try agent_envelope.deserializeEnvelope(mock.writes.items[0], std.testing.allocator);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.payload == .agent_start);
}

test "remote stop sends agent_stop before agent_started arrives" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);

    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver() });
    var tui_session = runtime.createSession();
    try tui_session.start();
    try std.testing.expectEqual(@as(usize, 1), mock.writes.items.len);
    try std.testing.expect(runtime.remote_session_id == null);
    try std.testing.expect(runtime.remote_pending_session_id != null);
    const pending_sid = runtime.remote_pending_session_id.?;

    runtime.deinit();
    try std.testing.expectEqual(@as(usize, 2), mock.writes.items.len);
    var env = try agent_envelope.deserializeEnvelope(mock.writes.items[1], std.testing.allocator);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.payload == .agent_stop);
    try std.testing.expectEqualSlices(u8, pending_sid[0..], env.session_id[0..]);
    try std.testing.expect(mock.sender_closed);
    try std.testing.expect(mock.receiver_closed);
}

test "remote mode normalizes agent_event into TUI event" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    const sid = agent_protocol_types.generateSessionId();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();

    var event_env = agent_protocol_types.Envelope{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = 0,
        .payload = .{ .agent_event = try std.testing.allocator.dupe(u8, "{\"type\":\"turn_start\"}") },
    };
    defer event_env.deinit(std.testing.allocator);
    try mock.queueEnvelope(std.testing.allocator, event_env);

    try tui_session.submitTurn("hi");

    var saw_turn_start = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        if (ev == .turn_start) saw_turn_start = true;
    }
    try std.testing.expect(saw_turn_start);
}

test "remote mode serializes encoded canonical model_ref and tools" {
    const model = ai_types.Model{
        .id = "llama3.2:1b",
        .name = "Llama",
        .api = "test-api",
        .provider = "test-provider",
        .base_url = "https://example.invalid",
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 8192,
        .max_tokens = 1024,
    };
    const messages = [_]ai_types.Message{try makeRemoteUserMessage(std.testing.allocator, "hi")};
    defer {
        var mutable = messages[0];
        mutable.deinit(std.testing.allocator);
    }
    const tools = [_]agent.AgentTool{.{
        .label = "Lookup",
        .name = "lookup",
        .description = "Lookup tool",
        .short_description = "Lookup",
        .parameters_schema_json = "{\"type\":\"object\"}",
        .execute = demoTool,
    }};
    const json = try makeRemoteMessageJson(std.testing.allocator, model, &messages, &tools);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"model_ref\":\"test-provider/test-api@llama3.2%3A1b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"lookup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requires_approval\":false") != null);
}

test "remote mode serializes prior conversation messages" {
    const assistant_content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "hello" } }};
    const tool_content = [_]ai_types.UserContentPart{.{ .text = .{ .text = "tool output" } }};
    const messages = [_]ai_types.Message{
        try makeRemoteUserMessage(std.testing.allocator, "first"),
        .{ .assistant = .{
            .content = &assistant_content,
            .api = "test-api",
            .provider = "test-provider",
            .model = "model-a",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 1,
        } },
        .{ .tool_result = .{
            .tool_call_id = "call-1",
            .tool_name = "lookup",
            .content = &tool_content,
            .details_json = OwnedSlice(u8).initBorrowed("{\"ok\":true}"),
            .is_error = false,
            .timestamp = 2,
        } },
        try makeRemoteUserMessage(std.testing.allocator, "second"),
    };
    defer {
        var first = messages[0];
        first.deinit(std.testing.allocator);
        var second = messages[3];
        second.deinit(std.testing.allocator);
    }
    const json = try makeRemoteMessageJson(std.testing.allocator, test_model_a, &messages, &.{});
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"content\":\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "tool output") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"content\":\"second\"") != null);
}

test "remote start tolerates empty initial read" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver() });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try std.testing.expect(runtime.started);
    try std.testing.expect(runtime.remote_session_id == null);
}

test "legacy remote line receiver treats null read as disconnect" {
    const LegacyReader = struct {
        fn readLine(_: *anyopaque, _: std.mem.Allocator) !?[]const u8 {
            return null;
        }
    };
    var ctx: u8 = 0;
    var receiver = RemoteLineReceiver{ .ctx = &ctx, .read_line_fn = LegacyReader.readLine };
    try std.testing.expectEqual(RemoteReadResult.disconnected, try receiver.read(std.testing.allocator));
}

test "remote start validates receiver before sending" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender() });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try std.testing.expectError(error.NoRemoteTransportConfigured, tui_session.start());
    try std.testing.expectEqual(@as(usize, 0), mock.writes.items.len);
}

test "remote start resets state after pump error" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    try mock.queueInvalid();
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver() });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try std.testing.expectError(error.SyntaxError, tui_session.start());
    try std.testing.expect(!runtime.started);
    try std.testing.expect(runtime.remote_client == null);
    try std.testing.expect(mock.sender_closed);
    try std.testing.expect(mock.receiver_closed);
}

test "remote submit waits through pending startup polls" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    try mock.queuePending(3);
    const sid = agent_protocol_types.generateSessionId();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .remote_session_timeout_ms = 1_000, .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("hi");
    try std.testing.expectEqual(sid, runtime.remote_session_id.?);
    try std.testing.expect(mock.writes.items.len >= 2);
}

test "remote submit uses configurable startup timeout" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .remote_session_timeout_ms = 1, .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try std.testing.expectError(error.RemoteAgentStartFailed, tui_session.submitTurn("hi"));
}

test "remote submit rejects missing model before send" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    const sid = agent_protocol_types.generateSessionId();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver() });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const writes_before = mock.writes.items.len;
    try std.testing.expectError(error.NoModelConfigured, tui_session.submitTurn("hi"));
    try std.testing.expectEqual(writes_before, mock.writes.items.len);
}

test "remote submit failure rolls back appended user once" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    const sid = agent_protocol_types.generateSessionId();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    runtime.remote_client.?.sender = null;
    try std.testing.expectError(error.NoSender, tui_session.submitTurn("hi"));
    try std.testing.expectEqual(@as(usize, 0), runtime.remote_messages.items.len);
}

test "remote stream_events keeps pumping pending events" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    const sid = agent_protocol_types.generateSessionId();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("hi");

    var event_env = agent_protocol_types.Envelope{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = 0,
        .payload = .{ .agent_event = try std.testing.allocator.dupe(u8, "{\"type\":\"turn_start\"}") },
    };
    defer event_env.deinit(std.testing.allocator);
    try mock.queueEnvelope(std.testing.allocator, event_env);

    const ev = tui_session.popEvent() orelse return error.NoRemoteEvent;
    var mutable = ev;
    defer mutable.deinit(std.testing.allocator);
    try std.testing.expect(mutable == .turn_start);
}

test "remote cancel completes stream and creates fresh session next turn" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    const sid1 = agent_protocol_types.generateSessionId();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid1,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid1 } },
    });
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    runtime.resetEventStreamForTurn();

    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid1,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = 0,
        .payload = .{ .agent_stopped = .{ .session_id = sid1 } },
    });
    tui_session.cancel();
    try std.testing.expect(runtime.remote_session_id == null);
    try std.testing.expect(runtime.event_stream.isDone());

    var saw_cancelled = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        if (ev == .agent_end and ev.agent_end.reason == .cancelled) saw_cancelled = true;
    }
    try std.testing.expect(saw_cancelled);

    try std.testing.expectError(error.RemoteAgentStartFailed, tui_session.submitTurn("after cancel"));
    const sid2 = runtime.remote_pending_session_id.?;
    try std.testing.expect(!std.mem.eql(u8, sid1[0..], sid2[0..]));
    try std.testing.expectEqual(@as(usize, 3), mock.writes.items.len);
    var restart_env = try agent_envelope.deserializeEnvelope(mock.writes.items[2], std.testing.allocator);
    defer restart_env.deinit(std.testing.allocator);
    try std.testing.expect(restart_env.payload == .agent_start);
    try std.testing.expectEqualSlices(u8, sid2[0..], restart_env.session_id[0..]);
}

test "remote ignores late agent_started after cancel" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const canceled_sid = runtime.remote_pending_session_id.?;
    tui_session.cancel();

    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = canceled_sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = canceled_sid } },
    });
    _ = tui_session.streamEvents();
    try std.testing.expect(runtime.remote_session_id == null);
    try std.testing.expect(runtime.remote_pending_session_id == null);

    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = canceled_sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = 0,
        .payload = .{ .agent_stopped = .{ .session_id = canceled_sid } },
    });
    _ = tui_session.streamEvents();
    try std.testing.expect(runtime.remote_session_id == null);
}

test "remote error emits terminal event once" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    const sid = agent_protocol_types.generateSessionId();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver() });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    runtime.remote_session_id = sid;

    var err_env = agent_protocol_types.Envelope{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = 0,
        .payload = .{ .agent_error = .{ .code = .internal_error, .message = try std.testing.allocator.dupe(u8, "boom") } },
    };
    defer err_env.deinit(std.testing.allocator);
    try mock.queueEnvelope(std.testing.allocator, err_env);

    _ = tui_session.streamEvents();
    _ = tui_session.streamEvents();

    var terminal_count: usize = 0;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        if (ev == .agent_end) terminal_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), terminal_count);
    try std.testing.expectEqual(sid, runtime.remote_session_id.?);
}

test "remote submit rejects while previous turn active" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    const sid = agent_protocol_types.generateSessionId();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("first");
    const writes_before = mock.writes.items.len;
    try std.testing.expectError(error.AgentAlreadyStreaming, tui_session.submitTurn("second"));
    try std.testing.expectEqual(writes_before, mock.writes.items.len);
}

test "remote done event records assistant history for next turn" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote });
    defer runtime.deinit();
    try runtime.handleRemoteAgentEventJson("{\"type\":\"message_update\",\"event\":{\"type\":\"done\",\"reason\":\"stop\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"answer\"}],\"api\":\"test-api\",\"provider\":\"test-provider\",\"model\":\"model-a\",\"usage\":{},\"stop_reason\":\"stop\",\"timestamp\":1}}}");
    try std.testing.expectEqual(@as(usize, 1), runtime.remote_messages.items.len);
    try std.testing.expect(runtime.remote_messages.items[0] == .assistant);
    try std.testing.expectEqualStrings("answer", runtime.remote_messages.items[0].assistant.content[0].text.text);
}

test "remote tool execution end records tool result history" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote });
    defer runtime.deinit();
    try runtime.handleRemoteAgentEventJson("{\"type\":\"tool_execution_end\",\"tool_call_id\":\"call-1\",\"tool_name\":\"lookup\",\"result_json\":\"[{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"found\\\"}]\",\"details_json\":\"{\\\"ok\\\":true}\",\"is_error\":false}");
    try std.testing.expectEqual(@as(usize, 1), runtime.remote_messages.items.len);
    try std.testing.expect(runtime.remote_messages.items[0] == .tool_result);
    try std.testing.expectEqualStrings("call-1", runtime.remote_messages.items[0].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("lookup", runtime.remote_messages.items[0].tool_result.tool_name);
    try std.testing.expectEqualStrings("found", runtime.remote_messages.items[0].tool_result.content[0].text.text);
}

test "remote tool execution end records scalar tool result history" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote });
    defer runtime.deinit();
    try runtime.handleRemoteAgentEventJson("{\"type\":\"tool_execution_end\",\"tool_call_id\":\"call-1\",\"tool_name\":\"lookup\",\"result_json\":\"\\\"skipped\\\"\",\"is_error\":true}");
    try std.testing.expectEqual(@as(usize, 1), runtime.remote_messages.items.len);
    try std.testing.expect(runtime.remote_messages.items[0] == .tool_result);
    try std.testing.expectEqualStrings("skipped", runtime.remote_messages.items[0].tool_result.content[0].text.text);
    try std.testing.expect(runtime.remote_messages.items[0].tool_result.is_error);
}

test "remote submit preserves approval marker in serialized tools" {
    var original_ctx = OriginalApprovalCtx{ .decision = .approve };
    const tools = [_]agent.AgentTool{.{
        .label = "Shell",
        .name = "shell_execute",
        .description = "Run shell",
        .parameters_schema_json = "{}",
        .execute = demoTool,
        .approval_ctx = &original_ctx,
        .approval_fn = originalApprovalCallback,
    }};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{
        .backend = .remote,
        .tools = &tools,
    });
    defer runtime.deinit();
    const json = try makeRemoteMessageJson(std.testing.allocator, test_model_a, &.{}, runtime.remoteSerializableTools());
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requires_approval\":true") != null);
}

test "remote event parser rejects invalid field types" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote });
    defer runtime.deinit();
    try std.testing.expectError(error.InvalidRemoteEvent, runtime.handleRemoteAgentEventJson("{\"type\":1}"));
    try std.testing.expectError(error.InvalidRemoteEvent, runtime.handleRemoteAgentEventJson("{\"type\":\"tool_execution_end\",\"is_error\":\"false\"}"));
    try std.testing.expectError(error.InvalidRemoteEvent, runtime.handleRemoteAgentEventJson("{\"type\":\"tool_execution_start\",\"tool_name\":\"demo\"}"));
}

test "remote message update extracts parsed event object" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote });
    defer runtime.deinit();
    try runtime.handleRemoteAgentEventJson("{\"type\":\"message_update\",\"note\":\"contains \\\"event\\\": inside string\",\"event\":{\"type\":\"text_delta\",\"content_index\":0,\"delta\":\"hi\"}} ");
    const ev = runtime.event_stream.poll() orelse return error.NoRemoteEvent;
    var mutable = ev;
    defer mutable.deinit(std.testing.allocator);
    try std.testing.expect(mutable == .text_delta);
    try std.testing.expectEqualStrings("hi", mutable.text_delta.delta.slice());
}

test "remote message role is parsed when supplied" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote });
    defer runtime.deinit();
    try runtime.handleRemoteAgentEventJson("{\"type\":\"message_start\",\"role\":\"user\"}");
    const user_ev = runtime.event_stream.poll() orelse return error.NoRemoteEvent;
    try std.testing.expect(user_ev == .message_start);
    try std.testing.expectEqual(TuiEvent.MessageRole.user, user_ev.message_start.role);

    try runtime.handleRemoteAgentEventJson("{\"type\":\"message_end\",\"role\":\"tool\"}");
    const tool_ev = runtime.event_stream.poll() orelse return error.NoRemoteEvent;
    try std.testing.expect(tool_ev == .message_end);
    try std.testing.expectEqual(TuiEvent.MessageRole.tool_result, tool_ev.message_end.role);
}

test "remote disconnect attempts reconnect then emits terminal error" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    const sid = agent_protocol_types.generateSessionId();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const initial_writes = mock.writes.items.len;

    mock.disconnected = true;
    _ = tui_session.streamEvents();
    try std.testing.expect(runtime.remote_reconnect_attempted);
    try std.testing.expect(runtime.remote_session_id == null);
    try std.testing.expect(!runtime.remote_client.?.session_complete_flags.contains(sid));
    try std.testing.expect(mock.writes.items.len > initial_writes);
    try std.testing.expectError(error.RemoteAgentStartFailed, tui_session.submitTurn("after disconnect"));

    _ = tui_session.streamEvents();
    var saw_error_end = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        if (ev == .agent_end and ev.agent_end.reason == .@"error") saw_error_end = true;
    }
    try std.testing.expect(saw_error_end);
}

test "remote submit pump failure completes stream" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    const sid = agent_protocol_types.generateSessionId();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try mock.queueInvalid();
    try tui_session.submitTurn("hi");
    try std.testing.expect(runtime.event_stream.isDone());

    var saw_error_end = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        if (ev == .agent_end and ev.agent_end.reason == .@"error") saw_error_end = true;
    }
    try std.testing.expect(saw_error_end);
}

test "remote poll pump failure completes stream" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    const sid = agent_protocol_types.generateSessionId();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("hi");
    try mock.queueInvalid();
    _ = tui_session.streamEvents();
    try std.testing.expect(runtime.event_stream.isDone());
}

test "remote runtime integrates with in-process agent protocol server" {
    var server = agent_protocol_server.AgentProtocolServer.init(std.testing.allocator);
    defer server.deinit();
    var pipe = in_process.SerializedPipe.init(std.testing.allocator);
    defer pipe.deinit();
    var protocol_runtime = agent_protocol_runtime.AgentProtocolRuntime{
        .server = &server,
        .pipe = &pipe,
        .allocator = std.testing.allocator,
    };

    var runtime = try TuiRuntime.init(std.testing.allocator, .{
        .backend = .remote,
        .remote_sender = pipe.clientSender(),
        .remote_receiver = .{ .ctx = &pipe, .read_line_fn = remotePipeReadLine, .read_result_fn = remotePipeReadResult },
        .models = &[_]ai_types.Model{test_model_a},
    });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try protocol_runtime.pumpClientMessages();
    _ = try protocol_runtime.pumpServerOutbox();
    _ = tui_session.streamEvents();
    try std.testing.expect(runtime.remote_session_id != null);

    try tui_session.submitTurn("hi");
    try protocol_runtime.pumpClientMessages();
    const sid = runtime.remote_session_id.?;
    try server.publishAgentEvent(sid, "{\"type\":\"turn_start\"}");
    _ = try protocol_runtime.pumpServerOutbox();
    _ = tui_session.streamEvents();

    const ev = tui_session.popEvent() orelse return error.NoRemoteEvent;
    try std.testing.expect(ev == .turn_start);
}

fn remotePipeReadLine(ctx: *anyopaque, allocator: std.mem.Allocator) !?[]const u8 {
    const pipe: *in_process.SerializedPipe = @ptrCast(@alignCast(ctx));
    var recv = pipe.clientReceiver();
    return recv.readLine(allocator);
}

fn remotePipeReadResult(ctx: *anyopaque, allocator: std.mem.Allocator) !RemoteReadResult {
    return if (try remotePipeReadLine(ctx, allocator)) |line| .{ .line = line } else .pending;
}
