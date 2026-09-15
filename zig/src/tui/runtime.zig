const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");
const agent = @import("agent");
const agent_types = @import("agent_types");
const transport = @import("transport");
const json_writer = @import("json_writer");
const session = @import("tui_session");
const local_tools = @import("tools/registry");
const tool_local_runtime = @import("tool_local_runtime");
const permission = @import("permission");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const TuiSession = session.TuiSession;
pub const TuiEvent = session.TuiEvent;
pub const TuiEventStream = session.TuiEventStream;
pub const TuiEndReason = session.TuiEndReason;
pub const QueuedCounts = session.QueuedCounts;
pub const CompactMessagesResult = session.CompactMessagesResult;
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

pub const PermissionMode = enum {
    ask,
    bypass,
};

pub const TuiRuntimeOptions = struct {
    protocol: ?agent.ProtocolClient = null,
    models: []const ai_types.Model = &.{},
    initial_model_id: ?[]const u8 = null,
    initial_model: ?InitialModelRef = null,
    tools: []const agent.AgentTool = &.{},
    mcp_config_json: ?[]const u8 = null,
    permission_engine: ?*permission.PermissionEngine = null,
    workspace_root: []const u8 = "",
    tool_approval_ctx: ?*anyopaque = null,
    tool_approval_callback: ?ToolApprovalCallback = null,
    permission_mode: PermissionMode = .bypass,
    thinking_level: ai_types.ThinkingLevel = .low,
    compact_output: bool = false,
    run_async: bool = true,
};

pub const InitialModelRef = struct {
    id: []const u8,
    provider: []const u8 = "",
    api: []const u8 = "",
};

fn normalizeTuiThinkingLevel(level: ai_types.ThinkingLevel) ai_types.ThinkingLevel {
    return switch (level) {
        .minimal => .low,
        else => level,
    };
}

fn cloneModels(allocator: std.mem.Allocator, models: []const ai_types.Model) ![]ai_types.Model {
    const cloned = try allocator.alloc(ai_types.Model, models.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |*model| model.deinit(allocator);
        allocator.free(cloned);
    }
    for (models, 0..) |model, idx| {
        cloned[idx] = try ai_types.cloneModel(allocator, model);
        initialized += 1;
    }
    return cloned;
}

fn deinitModels(allocator: std.mem.Allocator, models: []ai_types.Model) void {
    for (models) |*model| model.deinit(allocator);
    allocator.free(models);
}

pub const TuiRuntime = struct {
    allocator: std.mem.Allocator,
    protocol: ?agent.ProtocolClient,
    models: []ai_types.Model,
    selected_model_index: ?usize,
    local_agent: ?agent.Agent = null,
    event_stream: TuiEventStream,
    tool_registry: local_tools.ToolRegistry,
    mcp_bridge: ?*local_tools.mcp_bridge.McpBridge = null,
    original_tools: []agent.AgentTool,
    wrapped_tools: []agent.AgentTool,
    approval_contexts: []ApprovalContext,
    tool_protocol: tool_local_runtime.LocalToolProtocol,
    workspace_root: []u8,
    tool_protocol_override_fn: ?agent_types.ToolProtocolExecuteFn = null,
    tool_protocol_override_ctx: ?*anyopaque = null,
    pending_approval: ApprovalDecisionState = .{},
    approval_mutex: std.atomic.Mutex = .unlocked,
    tool_approval_ctx: ?*anyopaque,
    tool_approval_callback: ?ToolApprovalCallback,
    permission_engine: ?*permission.PermissionEngine,
    permission_mode: PermissionMode = .bypass,
    thinking_level: ai_types.ThinkingLevel = .low,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    completed: bool = false,
    started: bool = false,
    stream_active: bool = false,
    last_turn_stop_reason: ?ai_types.StopReason = null,
    compact_output: bool = false,
    run_async: bool = true,
    dropped_event_count: u64 = 0,
    dropped_since_warning: u64 = 0,
    steering_tagged_count: u64 = 0,
    current_generation: u32 = 0,
    backpressure_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    backpressure_status_active_emitted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    backpressure_mutex: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator, options: TuiRuntimeOptions) !TuiRuntime {
        var models = try cloneModels(allocator, options.models);
        errdefer deinitModels(allocator, models);

        var tool_registry = local_tools.ToolRegistry.init();
        errdefer tool_registry.deinit(allocator);
        try tool_registry.registerDefaults(allocator);

        for (options.tools) |tool| try tool_registry.replaceOrRegister(allocator, tool);

        var original_tools = try allocator.dupe(agent.AgentTool, tool_registry.list());
        errdefer allocator.free(original_tools);

        var wrapped_tools = try allocator.alloc(agent.AgentTool, original_tools.len);
        errdefer allocator.free(wrapped_tools);

        var approval_contexts = try allocator.alloc(ApprovalContext, original_tools.len);
        errdefer allocator.free(approval_contexts);

        var selected: ?usize = null;
        if (models.len > 0) {
            selected = 0;
            if (options.initial_model) |initial| {
                for (models, 0..) |model, i| {
                    if (modelMatchesInitial(model, initial)) {
                        selected = i;
                        break;
                    }
                }
            } else if (options.initial_model_id) |id| {
                for (models, 0..) |model, i| {
                    if (std.mem.eql(u8, model.id, id)) {
                        selected = i;
                        break;
                    }
                }
            }
        }

        var tool_protocol = try tool_local_runtime.LocalToolProtocol.init(allocator, original_tools);
        errdefer tool_protocol.deinit();

        var workspace_root = try allocator.dupe(u8, options.workspace_root);
        errdefer allocator.free(workspace_root);

        var runtime = TuiRuntime{
            .allocator = allocator,
            .protocol = options.protocol,
            .models = models,
            .selected_model_index = selected,
            .event_stream = TuiEventStream.init(allocator),
            .tool_registry = tool_registry,
            .mcp_bridge = null,
            .original_tools = original_tools,
            .wrapped_tools = wrapped_tools,
            .approval_contexts = approval_contexts,
            .tool_protocol = tool_protocol,
            .workspace_root = workspace_root,
            .tool_approval_ctx = options.tool_approval_ctx,
            .tool_approval_callback = options.tool_approval_callback,
            .permission_engine = options.permission_engine,
            .permission_mode = options.permission_mode,
            .thinking_level = normalizeTuiThinkingLevel(options.thinking_level),
            .compact_output = options.compact_output,
            .run_async = options.run_async,
        };
        original_tools = &.{};
        wrapped_tools = &.{};
        models = &.{};
        tool_protocol = undefined;
        workspace_root = &.{};
        tool_registry = local_tools.ToolRegistry.init();
        approval_contexts = &.{};
        errdefer runtime.deinit();
        if (options.mcp_config_json) |config_json| {
            const bridge = try allocator.create(local_tools.mcp_bridge.McpBridge);
            bridge.* = local_tools.mcp_bridge.McpBridge.init(allocator);
            bridge.bind();
            runtime.mcp_bridge = bridge;
            try bridge.loadConfigJson(config_json);
            try bridge.discover();
            try runtime.tool_registry.registerMcpBridge(allocator, bridge);
            const next_original_tools = try allocator.dupe(agent.AgentTool, runtime.tool_registry.list());
            errdefer allocator.free(next_original_tools);
            const next_wrapped_tools = try allocator.alloc(agent.AgentTool, next_original_tools.len);
            errdefer allocator.free(next_wrapped_tools);
            const next_approval_contexts = try allocator.alloc(ApprovalContext, next_original_tools.len);
            errdefer allocator.free(next_approval_contexts);

            allocator.free(runtime.approval_contexts);
            allocator.free(runtime.wrapped_tools);
            allocator.free(runtime.original_tools);
            runtime.original_tools = next_original_tools;
            runtime.wrapped_tools = next_wrapped_tools;
            runtime.approval_contexts = next_approval_contexts;
        }
        if (runtime.permission_engine) |engine| engine.setBypassAll(runtime.permission_mode == .bypass);
        runtime.rebuildWrappedTools();
        return runtime;
    }

    fn modelMatchesInitial(model: ai_types.Model, initial: InitialModelRef) bool {
        if (!std.mem.eql(u8, model.id, initial.id)) return false;
        if (initial.provider.len > 0 and !std.mem.eql(u8, model.provider, initial.provider)) return false;
        if (initial.api.len > 0 and !std.mem.eql(u8, model.api, initial.api)) return false;
        return true;
    }

    pub fn deinit(self: *TuiRuntime) void {
        self.stop();
        self.event_stream.deinit();
        self.clearPendingApproval();
        self.tool_protocol.deinit();
        self.allocator.free(self.workspace_root);
        self.allocator.free(self.approval_contexts);
        self.allocator.free(self.wrapped_tools);
        self.allocator.free(self.original_tools);
        if (self.mcp_bridge) |bridge| {
            bridge.deinit();
            self.allocator.destroy(bridge);
        }
        self.tool_registry.deinit(self.allocator);
        deinitModels(self.allocator, self.models);
        self.* = undefined;
    }

    pub fn start(self: *TuiRuntime) !void {
        if (self.started) return;
        const protocol = self.protocol orelse return error.NoProtocolConfigured;
        self.rebuildWrappedTools();
        self.local_agent = agent.Agent.init(self.allocator, .{
            .protocol = protocol,
            .compact_tool_output = self.compact_output,
            .permission_engine = self.permission_engine,
            .execute_tool_via_protocol_fn = executeTuiToolProtocol,
            .execute_tool_via_protocol_ctx = self,
        });
        self.steering_tagged_count = 0;
        self.local_agent.?.subscribeWithContext(self, onAgentEvent);
        self.local_agent.?.setCompactToolOutput(self.compact_output);
        const system_prompt = try self.workspaceSystemPrompt();
        defer self.allocator.free(system_prompt);
        try self.local_agent.?.setSystemPrompt(system_prompt);
        if (self.selected_model_index) |idx| self.local_agent.?.setModel(self.models[idx]);
        self.local_agent.?.setThinkingLevel(self.thinking_level);
        self.tool_protocol.server.tools.clearRetainingCapacity();
        try self.tool_protocol.server.registerTools(self.wrapped_tools);
        self.local_agent.?.setTools(self.wrapped_tools);
        self.started = true;
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
        self.started = false;
    }

    pub fn canSteer(_: *const TuiRuntime) bool {
        return true;
    }

    pub fn createSession(self: *TuiRuntime) TuiSession {
        return .{
            .ctx = self,
            .ops = .{
                .start = sessionStart,
                .resume_session = sessionResume,
                .compact_messages = sessionCompactMessages,
                .cancel = sessionCancel,
                .submit_turn = sessionSubmitTurn,
                .steer = sessionSteer,
                .clear_queued_messages = sessionClearQueuedMessages,
                .queued_counts = sessionQueuedCounts,
                .steers_consumed = sessionSteersConsumed,
                .can_steer = sessionCanSteer,
                .switch_model = sessionSwitchModel,
                .switch_model_exact = sessionSwitchModelExact,
                .current_model = sessionCurrentModel,
                .decide_tool_approval = sessionDecideToolApproval,
                .stream_events = sessionStreamEvents,
            },
        };
    }

    pub fn availableModels(self: *TuiRuntime) []const ai_types.Model {
        return self.models;
    }

    pub fn replaceModels(self: *TuiRuntime, next_models: []const ai_types.Model, preferred_model: ?ai_types.Model) !void {
        if (self.local_agent) |*local| {
            if (!local.isIdle()) return error.AgentAlreadyStreaming;
        }

        var owned_next = try cloneModels(self.allocator, next_models);
        errdefer deinitModels(self.allocator, owned_next);

        const active_model = preferred_model orelse if (self.selected_model_index) |idx| self.models[idx] else null;

        var next_selected: ?usize = if (owned_next.len > 0) 0 else null;
        if (active_model) |active| {
            for (owned_next, 0..) |model, idx| {
                if (std.mem.eql(u8, model.id, active.id) and
                    std.mem.eql(u8, model.provider, active.provider) and
                    std.mem.eql(u8, model.api, active.api))
                {
                    next_selected = idx;
                    break;
                }
            }
        }

        deinitModels(self.allocator, self.models);
        self.models = owned_next;
        owned_next = &.{};
        self.selected_model_index = next_selected;

        if (self.local_agent) |*local| {
            if (next_selected) |idx| local.setModel(self.models[idx]);
        }
    }

    pub fn currentModel(self: *TuiRuntime) ?ai_types.Model {
        if (self.selected_model_index) |idx| return self.models[idx];
        return null;
    }

    pub fn availableTools(self: *TuiRuntime) []const agent.AgentTool {
        return self.original_tools;
    }

    pub fn permissionMode(self: *const TuiRuntime) PermissionMode {
        return self.permission_mode;
    }

    pub fn thinkingLevel(self: *const TuiRuntime) ai_types.ThinkingLevel {
        return self.thinking_level;
    }

    pub fn setThinkingLevel(self: *TuiRuntime, level: ai_types.ThinkingLevel) void {
        const normalized = normalizeTuiThinkingLevel(level);
        self.thinking_level = normalized;
        if (self.local_agent) |*local| local.setThinkingLevel(normalized);
    }

    pub fn setPermissionMode(self: *TuiRuntime, mode: PermissionMode) !void {
        self.permission_mode = mode;
        if (self.permission_engine) |engine| engine.setBypassAll(mode == .bypass);
        self.rebuildWrappedTools();
        if (self.local_agent) |*local| {
            local.setPermissionEngine(self.permission_engine);
            local.setTools(self.wrapped_tools);
        }
        self.tool_protocol.server.tools.clearRetainingCapacity();
        try self.tool_protocol.server.registerTools(self.wrapped_tools);
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

    pub fn switchModelExact(self: *TuiRuntime, selected: ai_types.Model) !void {
        if (self.local_agent) |*local| {
            if (!local.isIdle()) return error.AgentAlreadyStreaming;
        }

        for (self.models, 0..) |model, i| {
            if (std.mem.eql(u8, model.id, selected.id) and
                std.mem.eql(u8, model.provider, selected.provider) and
                std.mem.eql(u8, model.api, selected.api))
            {
                self.selected_model_index = i;
                if (self.local_agent) |*local| local.setModel(model);
                return;
            }
        }
        return error.ModelNotFound;
    }

    fn makeUserMessage(self: *TuiRuntime, text: []const u8) !ai_types.Message {
        const owned_text = try self.allocator.dupe(u8, text);
        return .{ .user = .{
            .content = .{ .text = owned_text },
            .timestamp = compat.time.nowMillis(),
        } };
    }

    pub fn submitTurn(self: *TuiRuntime, text: []const u8) !void {
        if (!self.started) try self.start();
        const local = &(self.local_agent orelse return error.RuntimeNotStarted);
        if (self.currentModel() == null) return error.NoModelConfigured;
        if (self.run_async) local.waitForIdle();
        self.resetEventStreamForTurn();
        self.cancelled.store(false, .release);
        self.completed = false;
        self.last_turn_stop_reason = null;
        if (self.run_async) {
            var msg = try self.makeUserMessage(text);
            defer msg.deinit(self.allocator);
            try local.promptAsync(msg);
        } else {
            const msg = try self.makeUserMessage(text);
            try local.prompt(msg);
        }
    }

    pub fn steer(self: *TuiRuntime, text: []const u8) !void {
        if (!self.started) return error.RuntimeNotStarted;
        const local = &(self.local_agent orelse return error.RuntimeNotStarted);
        var msg = try self.makeUserMessage(text);
        var queued = false;
        errdefer if (!queued) msg.deinit(self.allocator);
        try local.steer(msg);
        queued = true;
        try self.resumeQueuedMessagesIfIdle();
    }

    fn resumeQueuedMessagesIfIdle(self: *TuiRuntime) !void {
        const local = &(self.local_agent orelse return);
        if (!local.isIdle()) return;
        local.validateContinueFromContext() catch return;
        try self.resumeSession();
    }

    pub fn clearQueuedMessages(self: *TuiRuntime) void {
        const local = &(self.local_agent orelse return);
        local.clearAllQueues();
    }

    pub fn queuedCounts(self: *TuiRuntime) QueuedCounts {
        const local = &(self.local_agent orelse return .{});
        return local.queuedCounts();
    }

    pub fn steersConsumedCount(self: *TuiRuntime) u64 {
        const local = &(self.local_agent orelse return 0);
        return local.steeringConsumedCount();
    }

    pub fn replaceMessages(self: *TuiRuntime, messages: []const ai_types.Message) !void {
        if (!self.started) try self.start();
        const local = &(self.local_agent orelse return error.RuntimeNotStarted);
        if (self.run_async) local.waitForIdle();
        local.clearAllQueues();
        self.resetBackpressureState();
        try local.replaceMessages(messages);
    }

    pub fn compactMessages(self: *TuiRuntime) !CompactMessagesResult {
        if (!self.started) try self.start();
        const local = &(self.local_agent orelse return error.RuntimeNotStarted);
        if (self.run_async) local.waitForIdle();
        local.clearAllQueues();
        return try local.compactMessages();
    }

    pub fn resumeSession(self: *TuiRuntime) !void {
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
    }

    pub fn cancel(self: *TuiRuntime) void {
        self.cancelled.store(true, .release);
        if (self.local_agent) |*local| local.abort();
        while (!self.approval_mutex.tryLock()) std.atomic.spinLoopHint();
        self.pending_approval.cancelled = true;
        self.pending_approval.decision = .reject;
        self.approval_mutex.unlock();
    }

    pub fn streamEvents(self: *TuiRuntime) *TuiEventStream {
        return &self.event_stream;
    }

    pub fn backpressureState(self: *TuiRuntime) struct { active: bool, dropped_count: u64 } {
        while (!self.backpressure_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.backpressure_mutex.unlock();
        const active = self.backpressure_active.load(.acquire);
        const dropped_count = self.dropped_event_count;
        if (active and !self.event_stream.isFull()) {
            self.backpressure_active.store(false, .release);
            self.backpressure_status_active_emitted.store(false, .release);
        }
        return .{
            .active = active,
            .dropped_count = dropped_count,
        };
    }

    fn resetBackpressureState(self: *TuiRuntime) void {
        while (!self.backpressure_mutex.tryLock()) std.atomic.spinLoopHint();
        self.dropped_event_count = 0;
        self.dropped_since_warning = 0;
        self.backpressure_active.store(false, .release);
        self.backpressure_status_active_emitted.store(false, .release);
        self.backpressure_mutex.unlock();
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
        self.current_generation +%= 1;
        if (!self.stream_active or self.event_stream.isDone()) {
            self.event_stream.deinit();
            self.event_stream = TuiEventStream.init(self.allocator);
            self.resetBackpressureState();
        }
        self.stream_active = true;
    }

    fn rebuildWrappedTools(self: *TuiRuntime) void {
        for (self.original_tools, 0..) |tool, i| {
            const bypass = self.permission_mode == .bypass;
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
                .runtime_ctx = tool.runtime_ctx,
                .runtime_execute = tool.runtime_execute,
                .approval_ctx = if (bypass) null else &self.approval_contexts[i],
                .approval_fn = if (bypass) null else approveTool,
                .approval_ui_ctx = if (bypass) null else &self.approval_contexts[i],
                .approval_ui_fn = if (bypass) null else notifyToolApproval,
            };
        }
    }

    fn push(self: *TuiRuntime, event: TuiEvent) void {
        var mutable = event;
        mutable.setGeneration(self.current_generation);
        self.pushDroppingOldestCounted(mutable);
        self.flushDroppedWarning();
    }

    fn pushTerminal(self: *TuiRuntime, event: TuiEvent) void {
        var mutable = event;
        mutable.setGeneration(self.current_generation);
        self.pushDroppingOldestCounted(mutable);
        self.flushDroppedWarningDroppingOldest();
    }

    fn pushDroppingOldestCounted(self: *TuiRuntime, event: TuiEvent) void {
        while (true) {
            if (self.pushUncounted(event)) return;
            while (!self.backpressure_mutex.tryLock()) std.atomic.spinLoopHint();
            if (self.event_stream.push(event)) {
                self.backpressure_mutex.unlock();
                return;
            } else |err| switch (err) {
                error.QueueFull => {},
                error.StreamCompleted, error.OutOfMemory => {
                    self.backpressure_mutex.unlock();
                    var mutable = event;
                    mutable.deinit(self.allocator);
                    return;
                },
            }
            if (self.event_stream.poll()) |dropped| {
                self.dropped_event_count += 1;
                self.dropped_since_warning += 1;
                self.backpressure_active.store(true, .release);
                var mutable = dropped;
                mutable.deinit(self.allocator);
            } else {
                std.Thread.yield() catch {};
            }
            self.backpressure_mutex.unlock();
        }
    }

    fn pushUncounted(self: *TuiRuntime, event: TuiEvent) bool {
        while (!self.backpressure_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.backpressure_mutex.unlock();
        self.event_stream.push(event) catch |err| switch (err) {
            error.QueueFull => return false,
            error.StreamCompleted, error.OutOfMemory => {
                var mutable = event;
                mutable.deinit(self.allocator);
                return true;
            },
        };
        return true;
    }

    fn flushDroppedWarning(self: *TuiRuntime) void {
        while (!self.backpressure_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.backpressure_mutex.unlock();
        if (self.dropped_since_warning == 0) return;
        const message = std.fmt.allocPrint(self.allocator, "Warning: {d} event{s} dropped due to backpressure", .{
            self.dropped_since_warning,
            if (self.dropped_since_warning == 1) "" else "s",
        }) catch |err| {
            var err_event = TuiEvent{ .@"error" = .{ .message = self.dupeOwned(@errorName(err)) catch OwnedSlice(u8).initBorrowed("") } };
            err_event.setGeneration(self.current_generation);
            self.event_stream.push(err_event) catch {
                var mutable = err_event;
                mutable.deinit(self.allocator);
            };
            return;
        };
        var warning = TuiEvent{ .system_warning = .{ .message = OwnedSlice(u8).initOwned(message) } };
        warning.setGeneration(self.current_generation);
        self.event_stream.push(warning) catch {
            var mutable = warning;
            mutable.deinit(self.allocator);
            return;
        };
        self.dropped_since_warning = 0;
    }

    fn flushDroppedWarningDroppingOldest(self: *TuiRuntime) void {
        while (true) {
            while (!self.backpressure_mutex.tryLock()) std.atomic.spinLoopHint();
            const count = self.dropped_since_warning;
            self.backpressure_mutex.unlock();
            if (count == 0) return;

            const message = std.fmt.allocPrint(self.allocator, "Warning: {d} event{s} dropped due to backpressure", .{
                count,
                if (count == 1) "" else "s",
            }) catch return;
            var warning = TuiEvent{ .system_warning = .{ .message = OwnedSlice(u8).initOwned(message) } };
            warning.setGeneration(self.current_generation);
            if (self.pushUncounted(warning)) {
                while (!self.backpressure_mutex.tryLock()) std.atomic.spinLoopHint();
                self.dropped_since_warning -|= count;
                self.backpressure_mutex.unlock();
                return;
            }
            var mutable = warning;
            mutable.deinit(self.allocator);

            while (!self.backpressure_mutex.tryLock()) std.atomic.spinLoopHint();
            if (self.event_stream.poll()) |dropped| {
                self.dropped_event_count += 1;
                self.dropped_since_warning += 1;
                self.backpressure_active.store(true, .release);
                var dropped_mutable = dropped;
                dropped_mutable.deinit(self.allocator);
            } else {
                std.Thread.yield() catch {};
            }
            self.backpressure_mutex.unlock();
        }
    }

    fn dupeOwned(self: *TuiRuntime, value: []const u8) !OwnedSlice(u8) {
        return OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, value));
    }

    fn handleAgentEndEvent(self: *TuiRuntime) anyerror!void {
        const reason: TuiEndReason = if (self.cancelled.load(.acquire)) .cancelled else if (self.last_turn_stop_reason == .@"error") .@"error" else .completed;
        self.completed = true;
        self.pushTerminal(.{ .agent_end = .{ .reason = reason } });
        self.event_stream.complete(.{ .reason = reason });
        self.stream_active = false;
    }

    fn workspaceSystemPrompt(self: *TuiRuntime) ![]u8 {
        if (self.workspace_root.len == 0) return self.allocator.dupe(u8, "");
        return std.fmt.allocPrint(self.allocator,
            \\Current working directory: {s}
            \\Default workspace root: {s}
            \\Use this absolute path as the `workspace_root` argument for shell, file, search, edit, and workspace tools unless the user explicitly asks for a different path.
        , .{ self.workspace_root, self.workspace_root });
    }

    fn messageRole(message: ai_types.Message) TuiEvent.MessageRole {
        return switch (message) {
            .user => .user,
            .assistant => .assistant,
            .tool_result => .tool_result,
        };
    }

    fn messageEndPayload(self: *TuiRuntime, message: ai_types.Message) !@TypeOf(@as(TuiEvent, undefined).message_end) {
        var payload: @TypeOf(@as(TuiEvent, undefined).message_end) = .{ .role = messageRole(message) };
        switch (message) {
            .user => |m| {
                payload.text = try self.dupeOwned(firstUserContentText(m.content));
                const content_json = try serializeUserContent(self.allocator, m.content);
                defer self.allocator.free(content_json);
                payload.content_json = try self.dupeOwned(content_json);
            },
            .assistant => |m| {
                payload.text = try self.dupeOwned(assistantText(m.content));
                const content_json = try serializeAssistantContent(self.allocator, m.content);
                defer self.allocator.free(content_json);
                const tool_calls_json = try serializeToolCalls(self.allocator, m.content);
                defer self.allocator.free(tool_calls_json);
                payload.content_json = try self.dupeOwned(content_json);
                payload.tool_calls_json = try self.dupeOwned(tool_calls_json);
                payload.stop_reason = m.stop_reason;
            },
            .tool_result => |m| {
                payload.tool_call_id = try self.dupeOwned(m.tool_call_id);
                payload.tool_name = try self.dupeOwned(m.tool_name);
                payload.text = try self.dupeOwned(firstUserPartText(m.content));
                const content_json = try serializeUserParts(self.allocator, m.content);
                defer self.allocator.free(content_json);
                const artifacts_json = try serializeArtifacts(self.allocator, m.artifacts.slice());
                defer self.allocator.free(artifacts_json);
                payload.content_json = try self.dupeOwned(content_json);
                payload.details_json = try self.dupeOwned(m.details_json.slice());
                payload.artifacts_json = try self.dupeOwned(artifacts_json);
                payload.is_error = m.is_error;
            },
        }
        return payload;
    }

    fn firstUserContentText(content: ai_types.UserContent) []const u8 {
        return switch (content) {
            .text => |text| text,
            .parts => |parts| firstUserPartText(parts),
        };
    }

    fn firstUserPartText(parts: []const ai_types.UserContentPart) []const u8 {
        for (parts) |part| switch (part) {
            .text => |text| return text.text,
            else => {},
        };
        return "";
    }

    fn assistantText(content: []const ai_types.AssistantContent) []const u8 {
        for (content) |block| switch (block) {
            .text => |text| return text.text,
            else => {},
        };
        return "";
    }

    fn serializeUserContent(allocator: std.mem.Allocator, content: ai_types.UserContent) ![]u8 {
        return switch (content) {
            .text => |text| blk: {
                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(allocator);
                var w = json_writer.JsonWriter.init(&buf, allocator);
                try w.beginArray();
                try writeUserTextPart(&w, text, null);
                try w.endArray();
                break :blk try buf.toOwnedSlice(allocator);
            },
            .parts => |parts| serializeUserParts(allocator, parts),
        };
    }

    fn serializeUserParts(allocator: std.mem.Allocator, parts: []const ai_types.UserContentPart) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        var w = json_writer.JsonWriter.init(&buf, allocator);
        try w.beginArray();
        for (parts) |part| switch (part) {
            .text => |text| try writeUserTextPart(&w, text.text, text.text_signature),
            .image => |image| try writeImagePart(&w, image),
        };
        try w.endArray();
        return buf.toOwnedSlice(allocator);
    }

    fn serializeAssistantContent(allocator: std.mem.Allocator, content: []const ai_types.AssistantContent) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        var w = json_writer.JsonWriter.init(&buf, allocator);
        try w.beginArray();
        for (content) |block| switch (block) {
            .text => |text| try writeAssistantTextPart(&w, text),
            .thinking => |thinking| try writeThinkingPart(&w, thinking),
            .tool_call => |tool| try writeToolCallPart(&w, tool),
            .image => |image| try writeImagePart(&w, image),
        };
        try w.endArray();
        return buf.toOwnedSlice(allocator);
    }

    fn serializeToolCalls(allocator: std.mem.Allocator, content: []const ai_types.AssistantContent) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        var w = json_writer.JsonWriter.init(&buf, allocator);
        try w.beginArray();
        for (content) |block| switch (block) {
            .tool_call => |tool| try writeToolCallPart(&w, tool),
            else => {},
        };
        try w.endArray();
        return buf.toOwnedSlice(allocator);
    }

    fn serializeArtifacts(allocator: std.mem.Allocator, artifacts: []const ai_types.ArtifactReference) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        var w = json_writer.JsonWriter.init(&buf, allocator);
        try w.beginArray();
        for (artifacts) |artifact| {
            try w.beginObject();
            try w.writeStringField("artifact_id", artifact.artifact_id);
            try w.writeStringField("uri", artifact.uri.slice());
            try w.writeStringField("mime_type", artifact.mime_type.slice());
            if (artifact.byte_size) |size| try w.writeIntField("byte_size", size);
            try w.writeStringField("sha256", artifact.sha256.slice());
            try w.writeStringField("description", artifact.description.slice());
            try w.endObject();
        }
        try w.endArray();
        return buf.toOwnedSlice(allocator);
    }

    fn writeUserTextPart(w: *json_writer.JsonWriter, text: []const u8, signature: ?[]const u8) !void {
        try w.beginObject();
        try w.writeStringField("type", "text");
        try w.writeStringField("text", text);
        if (signature) |sig| try w.writeStringField("text_signature", sig);
        try w.endObject();
    }

    fn writeAssistantTextPart(w: *json_writer.JsonWriter, text: ai_types.TextContent) !void {
        try w.beginObject();
        try w.writeStringField("type", "text");
        try w.writeStringField("text", text.text);
        if (text.text_signature) |sig| try w.writeStringField("text_signature", sig);
        try w.endObject();
    }

    fn writeThinkingPart(w: *json_writer.JsonWriter, thinking: ai_types.ThinkingContent) !void {
        try w.beginObject();
        try w.writeStringField("type", "thinking");
        try w.writeStringField("thinking", thinking.thinking);
        if (thinking.thinking_signature) |sig| try w.writeStringField("thinking_signature", sig);
        try w.endObject();
    }

    fn writeToolCallPart(w: *json_writer.JsonWriter, tool: ai_types.ToolCall) !void {
        try w.beginObject();
        try w.writeStringField("type", "tool_call");
        try w.writeStringField("id", tool.id);
        try w.writeStringField("name", tool.name);
        try w.writeStringField("arguments_json", tool.arguments_json);
        if (tool.thought_signature) |sig| try w.writeStringField("thought_signature", sig);
        try w.endObject();
    }

    fn writeImagePart(w: *json_writer.JsonWriter, image: ai_types.ImageContent) !void {
        try w.beginObject();
        try w.writeStringField("type", "image");
        try w.writeStringField("data", image.data);
        try w.writeStringField("mime_type", image.mime_type);
        try w.endObject();
    }

    fn onAgentEvent(ctx: ?*anyopaque, event: agent.AgentEvent) void {
        const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
        self.handleAgentEvent(event) catch |err| {
            self.push(.{ .@"error" = .{ .message = self.dupeOwned(@errorName(err)) catch OwnedSlice(u8).initBorrowed("") } });
        };
    }

    fn handleAgentEvent(self: *TuiRuntime, event: agent.AgentEvent) !void {
        switch (event) {
            .agent_start => self.push(.{ .agent_start = .{} }),
            .turn_start => self.push(.{ .turn_start = .{} }),
            .message_start => |payload| {
                self.push(.{ .message_start = .{ .role = messageRole(payload.message) } });
            },
            .message_update => |payload| {
                try self.pushProviderEvent(payload.event);
                try self.pushMessageUpdate(payload.event);
            },
            .message_end => |payload| {
                var message_payload = try self.messageEndPayload(payload.message);
                if (message_payload.role == .user) {
                    if (self.local_agent) |*local| {
                        if (local.steeringConsumedCount() > self.steering_tagged_count) {
                            message_payload.steering = true;
                            self.steering_tagged_count += 1;
                        }
                    }
                }
                self.push(.{ .message_end = message_payload });
            },
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
                .raw_total_bytes = payload.raw_total_bytes,
                .returned_total_bytes = payload.returned_total_bytes,
                .estimated_returned_tokens = payload.estimated_returned_tokens,
                .artifact_count = payload.artifact_count,
                .artifact_refs = try self.formatArtifactRefs(payload.artifacts),
            } }),
            .turn_end => |payload| {
                self.last_turn_stop_reason = payload.message.stop_reason;
                if (payload.message.stop_reason == .@"error") {
                    if (payload.message.getErrorMessage()) |message| {
                        self.push(.{ .@"error" = .{ .message = try self.dupeOwned(message) } });
                    }
                }
                self.pushTerminal(.{ .turn_end = .{ .stop_reason = payload.message.stop_reason } });
            },
            .agent_end => try self.handleAgentEndEvent(),
            .context_usage => |payload| self.push(.{ .context_usage = .{
                .system_prompt_bytes = payload.system_prompt_bytes,
                .message_bytes = payload.message_bytes,
                .tool_definition_bytes = payload.tool_definition_bytes,
                .total_bytes = payload.total_bytes,
                .estimated_tokens = payload.estimated_tokens,
                .message_count = payload.message_count,
                .tool_count = payload.tool_count,
            } }),
            .prompt_segment_usage => |payload| self.push(.{ .prompt_segment_usage = .{
                .segment = switch (payload.segment) {
                    .system_prompt => .system_prompt,
                    .message_history => .message_history,
                    .tool_definitions => .tool_definitions,
                },
                .cache_role = switch (payload.cache_role) {
                    .stable => .stable,
                    .dynamic => .dynamic,
                },
                .bytes = payload.bytes,
                .estimated_tokens = payload.estimated_tokens,
                .item_count = payload.item_count,
            } }),
        }
    }

    fn formatArtifactRefs(self: *TuiRuntime, artifacts: []const ai_types.ArtifactReference) !OwnedSlice(u8) {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const writer = &out.writer;
        for (artifacts, 0..) |artifact, i| {
            if (i > 0) try writer.writeAll(", ");
            if (artifact.getUri()) |uri| {
                try writer.writeAll(uri);
            } else {
                try writer.writeAll(artifact.artifact_id);
            }
        }
        return OwnedSlice(u8).initOwned(try out.toOwnedSlice());
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

    fn pushProviderEvent(self: *TuiRuntime, event: ai_types.AssistantMessageEvent) !void {
        const event_json = try transport.serializeEvent(event, self.allocator);
        self.push(.{ .provider_event = .{ .event_json = OwnedSlice(u8).initOwned(event_json) } });
    }
};

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

fn executeTuiToolProtocol(
    ctx: ?*anyopaque,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?agent.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!agent.AgentToolResult {
    const runtime: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    return runtime.tool_protocol.executeWithOverride(
        tool_call_id,
        tool_name,
        args_json,
        cancel_token,
        on_update_ctx,
        on_update,
        runtime.tool_protocol_override_ctx,
        runtime.tool_protocol_override_fn,
        allocator,
    );
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

fn sessionCompactMessages(ctx: ?*anyopaque) anyerror!CompactMessagesResult {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    return try self.compactMessages();
}

fn sessionCancel(ctx: ?*anyopaque) void {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    self.cancel();
}

fn sessionSubmitTurn(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    try self.submitTurn(text);
}

fn sessionSteer(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    try self.steer(text);
}

fn sessionClearQueuedMessages(ctx: ?*anyopaque) void {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    self.clearQueuedMessages();
}

fn sessionQueuedCounts(ctx: ?*anyopaque) QueuedCounts {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    return self.queuedCounts();
}

fn sessionSteersConsumed(ctx: ?*anyopaque) u64 {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    return self.steersConsumedCount();
}

fn sessionCanSteer(ctx: ?*anyopaque) bool {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    return self.canSteer();
}

fn sessionSwitchModel(ctx: ?*anyopaque, model_id: []const u8) anyerror!void {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    try self.switchModel(model_id);
}

fn sessionSwitchModelExact(ctx: ?*anyopaque, model: ai_types.Model) anyerror!void {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    try self.switchModelExact(model);
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
    last_thinking_level: ai_types.ThinkingLevel = .off,
    last_message_count: usize = 0,
    saw_workspace_prompt: bool = false,
    wait_for_cancel: bool = false,
    flood_count: usize = 0,
    deliver_flood_second: usize = 0,
    tool_first: bool = false,
    wait_after_tool_first: bool = false,
    wait_before_text_first: bool = false,
    tool_name: []const u8 = "demo_tool",
    force_error: bool = false,
    provider_error_message: []const u8 = "",
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
    const mock: *MockProtocolCtx = @ptrCast(@alignCast(ctx.?));
    mock.call_count += 1;
    mock.last_model_id = model.id;
    mock.last_thinking_level = options.thinking_level;
    mock.last_message_count = context.messages.len;
    const system_prompt = context.system_prompt.slice();
    mock.saw_workspace_prompt = std.mem.indexOf(u8, system_prompt, "Default workspace root: /tmp/makai-workspace") != null and
        std.mem.indexOf(u8, system_prompt, "`workspace_root`") != null;

    const stream = try allocator.create(event_stream.AssistantMessageEventStream);
    stream.* = event_stream.AssistantMessageEventStream.init(allocator);

    if (mock.force_error) {
        stream.completeWithError("forced provider error");
        return stream;
    }

    if (mock.provider_error_message.len > 0) {
        var event_message = emptyAssistantMessage(model, .@"error");
        event_message.error_message = OwnedSlice(u8).initBorrowed(mock.provider_error_message);
        var result_message = emptyAssistantMessage(model, .@"error");
        result_message.error_message = OwnedSlice(u8).initBorrowed(mock.provider_error_message);
        try stream.push(.{ .@"error" = .{ .reason = .@"error", .err = event_message } });
        stream.complete(result_message);
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

    if (mock.deliver_flood_second > 0 and mock.call_count == 2) {
        const partial = emptyAssistantMessage(model, .stop);
        try stream.push(.{ .start = .{ .partial = partial } });
        var i: usize = 0;
        while (i < mock.deliver_flood_second) : (i += 1) {
            try stream.push(.{ .text_delta = .{ .content_index = 0, .delta = "x", .partial = partial } });
        }
        const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "done" } }};
        try pushDoneAndComplete(stream, allocator, model, &content, .stop);
        return stream;
    }

    if (mock.tool_first and mock.call_count == 1) {
        if (mock.wait_after_tool_first) {
            var waits: usize = 0;
            while (waits < 50) : (waits += 1) {
                std.testing.io.sleep(.fromNanoseconds(1 * std.time.ns_per_ms), .boot) catch {};
            }
        }
        const content = [_]ai_types.AssistantContent{.{ .tool_call = .{ .id = "call-1", .name = mock.tool_name, .arguments_json = "{}" } }};
        try stream.push(.{ .start = .{ .partial = emptyAssistantMessage(model, .tool_use) } });
        try pushDoneAndComplete(stream, allocator, model, &content, .tool_use);
        return stream;
    }

    if (mock.wait_before_text_first and mock.call_count == 1) {
        var waits: usize = 0;
        while (waits < 50) : (waits += 1) {
            std.testing.io.sleep(.fromNanoseconds(1 * std.time.ns_per_ms), .boot) catch {};
        }
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

test "local runtime includes startup cwd as default workspace root in provider prompt" {
    var mock = MockProtocolCtx{};
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{
        .protocol = makeProtocol(&mock),
        .models = &models,
        .workspace_root = "/tmp/makai-workspace",
        .run_async = false,
    });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("pwd");
    if (runtime.local_agent) |*local| local.waitForIdle();

    try std.testing.expect(mock.saw_workspace_prompt);
}

test "local runtime surfaces provider error message details" {
    var mock = MockProtocolCtx{ .provider_error_message = "provider rejected request: missing workspace_root" };
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = false });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try std.testing.expectError(error.AgentLoopFailed, tui_session.submitTurn("hi"));
    if (runtime.local_agent) |*local| local.waitForIdle();

    var saw_detail = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        if (ev == .@"error" and std.mem.eql(u8, ev.@"error".message.slice(), "provider rejected request: missing workspace_root")) {
            saw_detail = true;
        }
    }
    try std.testing.expect(saw_detail);
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

const ContextToolCtx = struct { calls: usize = 0 };

fn contextOnlyTool(
    ctx: ?*anyopaque,
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
    const state: *ContextToolCtx = @ptrCast(@alignCast(ctx.?));
    state.calls += 1;
    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "context tool ok") } };
    return .{ .content = OwnedSlice(ai_types.UserContentPart).initOwned(content) };
}

test "runtime wrapper preserves context-aware tool execution" {
    var context = ContextToolCtx{};
    const tools = [_]agent.AgentTool{.{
        .label = "Context",
        .name = "context_tool",
        .description = "Context tool",
        .parameters_schema_json = "{}",
        .execute = demoTool,
        .runtime_ctx = &context,
        .runtime_execute = contextOnlyTool,
    }};
    const models = [_]ai_types.Model{test_model_a};
    var mock = MockProtocolCtx{ .tool_first = true, .tool_name = "context_tool" };
    var runtime = try TuiRuntime.init(std.testing.allocator, .{
        .protocol = makeProtocol(&mock),
        .models = &models,
        .tools = &tools,
        .run_async = false,
    });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("use context tool");
    if (runtime.local_agent) |*local| local.waitForIdle();

    var saw_tool_end = false;
    while (tui_session.waitEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .tool_execution_end => saw_tool_end = !ev.tool_execution_end.is_error,
            .agent_end => break,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expect(saw_tool_end);
}

test "MCP bridge exec context address remains stable in TUI runtime" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const script = "python3 -u -c 'import json,sys\n" ++
        "for line in sys.stdin:\n" ++
        " msg=json.loads(line); method=msg.get(\"method\")\n" ++
        " if method==\"initialize\": print(json.dumps({\"jsonrpc\":\"2.0\",\"id\":msg[\"id\"],\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}), flush=True)\n" ++
        " elif method==\"tools/list\": print(json.dumps({\"jsonrpc\":\"2.0\",\"id\":msg[\"id\"],\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo\",\"inputSchema\":{\"type\":\"object\"}}]}}), flush=True)'";
    const script_json = try std.json.Stringify.valueAlloc(std.testing.allocator, script, .{});
    defer std.testing.allocator.free(script_json);
    const config_json = try std.fmt.allocPrint(std.testing.allocator, "[{{\"name\":\"mock\",\"command\":\"/bin/sh\",\"args\":[\"-c\",{s}]}}]", .{script_json});
    defer std.testing.allocator.free(config_json);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .mcp_config_json = config_json });
    defer runtime.deinit();
    const bridge = runtime.mcp_bridge orelse return error.MissingBridge;
    for (bridge.tools.items) |record| {
        try std.testing.expect(record.exec_ctx.bridge.* == bridge);
    }
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
        .permission_mode = .ask,
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
        .permission_mode = .ask,
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

test "runtime idle steering resumes immediately" {
    var mock = MockProtocolCtx{};
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = false });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("first");

    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        if (ev == .agent_end) break;
    }
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);

    try tui_session.steer("steer after idle");
    try std.testing.expectEqual(@as(usize, 2), mock.call_count);
    try std.testing.expectEqual(@as(usize, 0), tui_session.queuedCounts().steering);

    var saw_steering_user = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .message_end => |payload| {
                if (payload.role == .user and std.mem.eql(u8, payload.text.slice(), "steer after idle")) {
                    saw_steering_user = true;
                }
            },
            .agent_end => break,
            else => {},
        }
    }
    try std.testing.expect(saw_steering_user);
}

test "runtime tags auto-resumed steer prompt with steering provenance" {
    var mock = MockProtocolCtx{};
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = false });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("first");
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        if (ev == .agent_end) break;
    }

    try tui_session.steer("steer after idle");

    var tagged_user_message_end = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .message_end => |payload| {
                if (payload.role == .user and payload.steering) tagged_user_message_end = true;
            },
            .agent_end => break,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(u64, 1), runtime.steersConsumedCount());
    try std.testing.expect(tagged_user_message_end);
}

test "runtime tags async auto-resumed steer prompt with steering provenance" {
    var mock = MockProtocolCtx{};
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = true });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("first");
    if (runtime.local_agent) |*local| local.waitForIdle();
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        if (ev == .agent_end) break;
    }

    try tui_session.steer("steer after idle");
    if (runtime.local_agent) |*local| local.waitForIdle();

    var tagged_user_message_end = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .message_end => |payload| {
                if (payload.role == .user and payload.steering) tagged_user_message_end = true;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(u64, 1), runtime.steersConsumedCount());
    try std.testing.expect(tagged_user_message_end);
}

test "runtime tags post-tool consumed steer and feeds it to the model" {
    var mock = MockProtocolCtx{ .tool_first = true, .wait_after_tool_first = true };
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = true });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("first");
    try tui_session.steer("steer mid tool");

    if (runtime.local_agent) |*local| local.waitForIdle();

    try std.testing.expectEqual(@as(usize, 2), mock.call_count);
    try std.testing.expectEqual(@as(u64, 1), runtime.steersConsumedCount());
    try std.testing.expectEqual(@as(usize, 4), mock.last_message_count);

    var tagged_user_message_end = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .message_end => |payload| {
                if (payload.role == .user and std.mem.eql(u8, payload.text.slice(), "steer mid tool")) {
                    tagged_user_message_end = payload.steering;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(tagged_user_message_end);
}

test "runtime active steering continues after plain assistant stop" {
    var mock = MockProtocolCtx{ .wait_before_text_first = true };
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = true });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("first");
    try tui_session.steer("steer during response");

    if (runtime.local_agent) |*local| local.waitForIdle();

    try std.testing.expectEqual(@as(usize, 2), mock.call_count);
    try std.testing.expectEqual(@as(usize, 0), tui_session.queuedCounts().steering);

    var saw_steering_user = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .message_end => |payload| {
                if (payload.role == .user and std.mem.eql(u8, payload.text.slice(), "steer during response")) {
                    saw_steering_user = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_steering_user);
}

test "runtime tags consumed steer message_end with steering provenance" {
    var mock = MockProtocolCtx{ .wait_before_text_first = true };
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = true });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("first");
    try tui_session.steer("steer during response");

    if (runtime.local_agent) |*local| local.waitForIdle();

    try std.testing.expectEqual(@as(u64, 1), runtime.steersConsumedCount());
    try std.testing.expectEqual(@as(u64, 1), tui_session.steersConsumedCount());

    var steer_message_end_tagged = false;
    var prompt_message_end_untagged = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .message_end => |payload| {
                if (payload.role == .user) {
                    if (std.mem.eql(u8, payload.text.slice(), "steer during response")) {
                        steer_message_end_tagged = payload.steering;
                    } else if (std.mem.eql(u8, payload.text.slice(), "first")) {
                        prompt_message_end_untagged = !payload.steering;
                    }
                }
            },
            else => {},
        }
    }
    try std.testing.expect(steer_message_end_tagged);
    try std.testing.expect(prompt_message_end_untagged);
}

test "steer consumption count survives backpressure eviction of consumption events" {
    var mock = MockProtocolCtx{ .wait_before_text_first = true, .deliver_flood_second = TuiEventStream.usable_capacity - 2 };
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = true });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("first");
    try tui_session.steer("steer during response");

    if (runtime.local_agent) |*local| local.waitForIdle();
    try std.testing.expectEqual(@as(u64, 1), runtime.steersConsumedCount());
    try std.testing.expect(runtime.dropped_event_count > 0);

    var saw_user_message_end = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        if (ev == .message_end and ev.message_end.role == .user) saw_user_message_end = true;
    }
    try std.testing.expect(!saw_user_message_end);
    try std.testing.expectEqual(@as(u64, 1), runtime.steersConsumedCount());
}

test "local runtime reports steering available" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    try std.testing.expect(runtime.canSteer());
    try std.testing.expect(runtime.createSession().canSteer());
}

test "runtime clears queued messages before replacing messages" {
    var mock = MockProtocolCtx{};
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.steer("steer now");
    try std.testing.expectEqual(@as(usize, 1), tui_session.queuedCounts().total());

    try runtime.replaceMessages(&.{});

    try std.testing.expectEqual(@as(usize, 0), tui_session.queuedCounts().total());
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
    var mock = MockProtocolCtx{ .flood_count = TuiEventStream.usable_capacity + 45 };
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
            .agent_end => saw_agent_end = true,
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
        .permission_mode = .ask,
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

test "permission bypass disables policy engine and approval wrappers" {
    var engine = try permission.PermissionEngine.initEmpty(std.testing.allocator, .{
        .workspace_root = "/workspace",
        .persistence_path = "zig-cache/test-tui-permission-bypass.json",
    });
    defer engine.deinit();

    var original_ctx = OriginalApprovalCtx{ .decision = .reject };
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
    var mock = MockProtocolCtx{};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{
        .protocol = makeProtocol(&mock),
        .models = &models,
        .tools = &tools,
        .permission_engine = &engine,
        .run_async = false,
    });
    defer runtime.deinit();

    try std.testing.expectEqual(PermissionMode.bypass, runtime.permissionMode());
    try std.testing.expect(engine.evaluate("shell", "{\"command\":\"rm -rf /\"}") == .allow);
    for (runtime.wrapped_tools) |tool| {
        try std.testing.expect(tool.approval_fn == null);
        try std.testing.expect(tool.approval_ui_fn == null);
    }

    try runtime.setPermissionMode(.ask);
    try std.testing.expectEqual(PermissionMode.ask, runtime.permissionMode());
    try std.testing.expect(engine.evaluate("shell", "{\"command\":\"rm -rf /\"}") == .deny);
    var found_demo = false;
    for (runtime.wrapped_tools) |tool| {
        if (std.mem.eql(u8, tool.name, "demo_tool")) {
            found_demo = true;
            try std.testing.expect(tool.approval_fn != null);
            try std.testing.expect(tool.approval_ui_fn != null);
        }
    }
    try std.testing.expect(found_demo);
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
        .permission_mode = .ask,
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

test "exact model switch distinguishes duplicate ids" {
    const first = ai_types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o Completions",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://example.invalid",
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 8192,
        .max_tokens = 1024,
    };
    const second = ai_types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o Responses",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://example.invalid",
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 8192,
        .max_tokens = 1024,
    };
    const models = [_]ai_types.Model{ first, second };
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .models = &models });
    defer runtime.deinit();

    try runtime.switchModelExact(second);

    try std.testing.expectEqualStrings("gpt-4o", runtime.currentModel().?.id);
    try std.testing.expectEqualStrings("openai-responses", runtime.currentModel().?.api);
}

test "initial model id selects matching model" {
    var mock = MockProtocolCtx{};
    const models = [_]ai_types.Model{ test_model_a, test_model_b };
    var runtime = try TuiRuntime.init(std.testing.allocator, .{
        .protocol = makeProtocol(&mock),
        .models = &models,
        .initial_model_id = "model-b",
        .run_async = false,
    });
    defer runtime.deinit();

    try std.testing.expectEqualStrings("model-b", runtime.currentModel().?.id);
}

test "initial model ref selects exact duplicate id provider api tuple" {
    const first = ai_types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o Completions",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://example.invalid",
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 8192,
        .max_tokens = 1024,
    };
    const second = ai_types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o Responses",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://example.invalid",
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 8192,
        .max_tokens = 1024,
    };
    const models = [_]ai_types.Model{ first, second };
    var runtime = try TuiRuntime.init(std.testing.allocator, .{
        .models = &models,
        .initial_model = .{ .id = "gpt-4o", .provider = "openai", .api = "openai-responses" },
    });
    defer runtime.deinit();

    try std.testing.expectEqualStrings("openai-responses", runtime.currentModel().?.api);
}

test "replaceModels preserves selected model when still available" {
    const initial = [_]ai_types.Model{ test_model_a, test_model_b };
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .models = &initial, .initial_model_id = "model-b" });
    defer runtime.deinit();

    const replacement = [_]ai_types.Model{test_model_b};
    try runtime.replaceModels(&replacement, null);

    try std.testing.expectEqual(@as(usize, 1), runtime.availableModels().len);
    try std.testing.expectEqualStrings("model-b", runtime.currentModel().?.id);
}

test "thinking level affects next local turn" {
    var mock = MockProtocolCtx{};
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = false });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    runtime.setThinkingLevel(.high);
    try tui_session.submitTurn("hi");
    if (runtime.local_agent) |*local| local.waitForIdle();

    var saw_turn_start = false;
    var saw_message_start = false;
    var saw_text_delta = false;
    var saw_message_end = false;
    var saw_turn_end = false;
    collectUntilEnd(&tui_session, &saw_turn_start, &saw_message_start, &saw_text_delta, &saw_message_end, &saw_turn_end);

    try std.testing.expectEqual(ai_types.ThinkingLevel.high, mock.last_thinking_level);
}

test "TUI runtime normalizes hidden minimal thinking level" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .thinking_level = .minimal });
    defer runtime.deinit();

    try std.testing.expectEqual(ai_types.ThinkingLevel.low, runtime.thinkingLevel());
    runtime.setThinkingLevel(.minimal);
    try std.testing.expectEqual(ai_types.ThinkingLevel.low, runtime.thinkingLevel());
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

    var saw_error_detail = false;
    var saw_error_end = false;
    while (tui_session.waitEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .@"error" => {
                if (std.mem.eql(u8, ev.@"error".message.slice(), "forced provider error")) saw_error_detail = true;
            },
            .agent_end => {
                saw_error_end = ev.agent_end.reason == .@"error";
                break;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_error_detail);
    try std.testing.expect(saw_error_end);
}

test "runtime push preserves newest event when event stream is full" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .models = &[_]ai_types.Model{test_model_a}, .run_async = false });
    defer runtime.deinit();

    for (0..TuiEventStream.usable_capacity) |_| {
        runtime.push(.{ .turn_start = .{} });
    }
    runtime.push(.{ .@"error" = .{ .message = try runtime.dupeOwned("latest error") } });

    var saw_latest_error = false;
    while (runtime.event_stream.poll()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        if (ev == .@"error" and std.mem.eql(u8, ev.@"error".message.slice(), "latest error")) {
            saw_latest_error = true;
        }
    }
    try std.testing.expect(saw_latest_error);
}

test "TuiRuntime terminal event emits warning after terminal eviction" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .models = &[_]ai_types.Model{test_model_a}, .run_async = false });
    defer runtime.deinit();

    for (0..TuiEventStream.usable_capacity) |_| {
        runtime.push(.{ .turn_start = .{} });
    }
    try std.testing.expect(runtime.event_stream.isFull());

    runtime.pushTerminal(.{ .agent_end = .{ .reason = .completed } });

    var saw_agent_end = false;
    var saw_warning = false;
    while (runtime.event_stream.poll()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .agent_end => saw_agent_end = true,
            .system_warning => saw_warning = true,
            else => {},
        }
    }
    try std.testing.expect(saw_agent_end);
    try std.testing.expect(saw_warning);
}

test "TuiRuntime counts dropped events and emits warning" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();

    var i: usize = 0;
    while (i < TuiEventStream.usable_capacity) : (i += 1) {
        runtime.push(.{ .text_delta = .{ .content_index = i, .delta = OwnedSlice(u8).initBorrowed("x") } });
    }
    try std.testing.expect(runtime.event_stream.isFull());

    runtime.push(.{ .text_delta = .{ .content_index = TuiEventStream.usable_capacity, .delta = OwnedSlice(u8).initBorrowed("after-full") } });
    try std.testing.expectEqual(@as(u64, 1), runtime.dropped_event_count);
    try std.testing.expect(runtime.backpressure_active.load(.acquire));

    const bp_active = runtime.backpressureState();
    try std.testing.expect(bp_active.active);
    try std.testing.expectEqual(@as(u64, 1), bp_active.dropped_count);

    for (0..2) |_| {
        var ev = runtime.event_stream.poll().?;
        defer ev.deinit(std.testing.allocator);
    }
    runtime.push(.{ .text_delta = .{ .content_index = 256, .delta = OwnedSlice(u8).initBorrowed("after") } });

    var saw_warning = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        if (ev == .system_warning) {
            saw_warning = true;
            try std.testing.expect(std.mem.indexOf(u8, ev.system_warning.message.slice(), "1 event dropped due to backpressure") != null);
        }
    }
    try std.testing.expect(saw_warning);

    const bp_recovered = runtime.backpressureState();
    try std.testing.expect(bp_recovered.active);
    try std.testing.expectEqual(@as(u64, 1), bp_recovered.dropped_count);
    const bp_cleared = runtime.backpressureState();
    try std.testing.expect(!bp_cleared.active);
    try std.testing.expectEqual(@as(u64, 1), bp_cleared.dropped_count);
}

test "TuiRuntime replaceMessages clears stale backpressure counters" {
    var mock = MockProtocolCtx{};
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = false });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();

    runtime.dropped_event_count = 9;
    runtime.dropped_since_warning = 2;
    runtime.backpressure_active.store(true, .release);

    try runtime.replaceMessages(&.{});

    const bp = runtime.backpressureState();
    try std.testing.expect(!bp.active);
    try std.testing.expectEqual(@as(u64, 0), bp.dropped_count);
}
