const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");
const agent = @import("agent");
const agent_protocol_client = @import("agent_protocol_client");
const agent_envelope = @import("agent_envelope");
const agent_protocol_types = @import("agent_protocol_types");
const transport = @import("transport");
const json_writer = @import("json_writer");
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

pub const RemoteLineReceiver = struct {
    ctx: *anyopaque,
    read_line_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]const u8,
    close_fn: ?*const fn (ctx: *anyopaque) void = null,

    pub fn readLine(self: *RemoteLineReceiver, allocator: std.mem.Allocator) !?[]const u8 {
        return self.read_line_fn(self.ctx, allocator);
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
                errdefer client.deinit();
                const sender = self.remote_sender orelse return error.NoRemoteTransportConfigured;
                client.setSender(sender);
                const config_json = try self.remoteConfigJson();
                defer self.allocator.free(config_json);
                _ = try client.sendAgentStart(config_json, null);
                try self.pumpRemoteIncomingInto(&client);
                const sid = client.session_id orelse return error.RemoteAgentStartFailed;
                self.remote_session_id = sid;
                self.remote_client = client;
                self.started = true;
                self.push(.agent_start);
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
            if (self.remote_session_id) |sid| {
                _ = client.sendAgentStop(sid, "client disconnect") catch {};
            }
            if (self.remote_sender) |sender| sender.close();
            if (self.remote_receiver) |*receiver| receiver.close();
            client.deinit();
            self.remote_client = null;
            self.remote_session_id = null;
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
                const client = &(self.remote_client orelse return error.RuntimeNotStarted);
                const sid = self.remote_session_id orelse return error.RemoteAgentStartFailed;
                self.resetEventStreamForTurn();
                self.cancelled.store(false, .release);
                self.completed = false;
                self.last_turn_stop_reason = null;
                const message_json = try makeRemoteMessageJson(self.allocator, self.currentModel(), text);
                defer self.allocator.free(message_json);
                _ = try client.sendAgentMessage(sid, message_json, null);
                try self.pumpRemoteIncoming();
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
            if (self.remote_session_id) |sid| {
                _ = client.sendAgentStop(sid, "cancelled") catch {};
                self.pumpRemoteIncoming() catch {};
            }
        }
        while (!self.approval_mutex.tryLock()) std.atomic.spinLoopHint();
        self.pending_approval.cancelled = true;
        self.pending_approval.decision = .reject;
        self.approval_mutex.unlock();
    }

    pub fn streamEvents(self: *TuiRuntime) *TuiEventStream {
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

    fn pumpRemoteIncomingInto(self: *TuiRuntime, client: *agent_protocol_client.AgentProtocolClient) !void {
        var receiver = &(self.remote_receiver orelse return error.NoRemoteTransportConfigured);
        var read_any = false;
        while (try receiver.readLine(self.allocator)) |line| {
            read_any = true;
            defer self.allocator.free(line);
            var env = agent_envelope.deserializeEnvelope(line, self.allocator) catch |err| switch (err) {
                error.InvalidPayloadType, error.InvalidSessionId, error.InvalidUlid, error.InvalidEnumValue => return error.ProtocolVersionMismatch,
                else => return err,
            };
            defer env.deinit(self.allocator);
            if (env.version != 1) return error.ProtocolVersionMismatch;
            try client.processEnvelope(env);
            try self.drainRemoteClientEvents(client);
        }
        if (!read_any and !self.started) return error.ConnectionRefused;
    }

    fn pumpRemoteIncoming(self: *TuiRuntime) !void {
        const client = &(self.remote_client orelse return error.RuntimeNotStarted);
        try self.pumpRemoteIncomingInto(client);
    }

    fn drainRemoteClientEvents(self: *TuiRuntime, client: *agent_protocol_client.AgentProtocolClient) !void {
        while (client.popEvent()) |owned_json| {
            var json = owned_json;
            defer json.deinit(self.allocator);
            try self.handleRemoteAgentEventJson(json.slice());
        }
        if (self.remote_session_id) |sid| {
            if (client.getLastErrorForSession(sid)) |msg| {
                self.push(.{ .@"error" = .{ .message = try self.dupeOwned(msg) } });
                self.pushTerminal(.{ .agent_end = .{ .reason = .@"error" } });
                self.event_stream.complete(.{ .reason = .@"error" });
                self.stream_active = false;
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
        const obj = parsed.value.object;
        const event_type = obj.get("type") orelse return error.InvalidRemoteEvent;
        const type_name = event_type.string;

        if (std.mem.eql(u8, type_name, "agent_start")) return self.push(.agent_start);
        if (std.mem.eql(u8, type_name, "turn_start")) return self.push(.turn_start);
        if (std.mem.eql(u8, type_name, "message_start")) return self.push(.{ .message_start = .{ .role = .assistant } });
        if (std.mem.eql(u8, type_name, "message_end")) return self.push(.{ .message_end = .{ .role = .assistant } });
        if (std.mem.eql(u8, type_name, "message_update")) {
            const event_json = try extractObjectJson(self.allocator, json, "event");
            defer self.allocator.free(event_json);
            const msg = try transport.deserialize(event_json, self.allocator);
            switch (msg) {
                .event => |ev| {
                    defer {
                        var mutable = ev;
                        ai_types.deinitAssistantMessageEvent(self.allocator, &mutable);
                    }
                    return try self.pushMessageUpdate(ev);
                },
                else => return error.InvalidRemoteEvent,
            }
        }
        if (std.mem.eql(u8, type_name, "tool_execution_start")) return self.push(.{ .tool_execution_start = .{
            .tool_call_id = try self.dupeOwned(obj.get("tool_call_id").?.string),
            .tool_name = try self.dupeOwned(obj.get("tool_name").?.string),
            .args_json = try self.dupeOwned(if (obj.get("args_json")) |v| v.string else ""),
        } });
        if (std.mem.eql(u8, type_name, "tool_execution_update")) return self.push(.{ .tool_execution_update = .{
            .tool_call_id = try self.dupeOwned(obj.get("tool_call_id").?.string),
            .tool_name = try self.dupeOwned(obj.get("tool_name").?.string),
            .args_json = try self.dupeOwned(if (obj.get("args_json")) |v| v.string else ""),
            .partial_result_json = try self.dupeOwned(obj.get("partial_result_json").?.string),
        } });
        if (std.mem.eql(u8, type_name, "tool_execution_end")) return self.push(.{ .tool_execution_end = .{
            .tool_call_id = try self.dupeOwned(obj.get("tool_call_id").?.string),
            .tool_name = try self.dupeOwned(obj.get("tool_name").?.string),
            .result_json = try self.dupeOwned(obj.get("result_json").?.string),
            .is_error = obj.get("is_error").?.bool,
        } });
        if (std.mem.eql(u8, type_name, "turn_end")) {
            const reason = parseStopReason(if (obj.get("stop_reason")) |v| v.string else "stop");
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
        if (std.mem.eql(u8, type_name, "error")) return self.push(.{ .@"error" = .{ .message = try self.dupeOwned(obj.get("message").?.string) } });
    }

    fn handleAgentEvent(self: *TuiRuntime, event: agent.AgentEvent) !void {
        switch (event) {
            .agent_start => self.push(.agent_start),
            .turn_start => self.push(.turn_start),
            .message_start => |payload| self.push(.{ .message_start = .{ .role = messageRole(payload.message) } }),
            .message_update => |payload| try self.pushMessageUpdate(payload.event),
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

fn extractObjectJson(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ![]u8 {
    const needle = try std.fmt.allocPrint(allocator, "\"{s}\":", .{key});
    defer allocator.free(needle);
    const key_pos = std.mem.indexOf(u8, json, needle) orelse return error.InvalidRemoteEvent;
    var idx = key_pos + needle.len;
    while (idx < json.len and std.ascii.isWhitespace(json[idx])) : (idx += 1) {}
    if (idx >= json.len or json[idx] != '{') return error.InvalidRemoteEvent;
    const start = idx;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    while (idx < json.len) : (idx += 1) {
        const c = json[idx];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) return try allocator.dupe(u8, json[start .. idx + 1]);
        }
    }
    return error.InvalidRemoteEvent;
}

fn makeRemoteMessageJson(allocator: std.mem.Allocator, model: ?ai_types.Model, text: []const u8) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);
    try w.beginObject();
    if (model) |m| try w.writeStringField("model_ref", m.id);
    try w.writeKey("messages");
    try w.beginArray();
    try w.beginObject();
    try w.writeStringField("role", "user");
    try w.writeStringField("content", text);
    try w.endObject();
    try w.endArray();
    try w.writeKey("tools");
    try w.beginArray();
    try w.endArray();
    try w.endObject();
    const out = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return out;
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
        return .{ .context = self, .write_fn = writeFn, .flush_fn = flushFn };
    }

    fn receiver(self: *RemoteMock) RemoteLineReceiver {
        return .{ .ctx = self, .read_line_fn = readLineFn };
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) !void {
        const self: *RemoteMock = @ptrCast(@alignCast(ctx));
        try self.writes.append(std.testing.allocator, try std.testing.allocator.dupe(u8, data));
    }

    fn flushFn(_: *anyopaque) !void {}

    fn readLineFn(ctx: *anyopaque, allocator: std.mem.Allocator) !?[]const u8 {
        const self: *RemoteMock = @ptrCast(@alignCast(ctx));
        if (self.reads.items.len == 0) return null;
        const line = self.reads.orderedRemove(0);
        if (allocator.ptr == std.testing.allocator.ptr) return line;
        defer std.testing.allocator.free(line);
        return try allocator.dupe(u8, line);
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
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver() });
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
