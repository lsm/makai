const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");
const agent = @import("agent");
const agent_types = @import("agent_types");
const agent_protocol_client = @import("agent_protocol_client");
const agent_envelope = @import("agent_envelope");
const agent_protocol_types = @import("agent_protocol_types");
const agent_protocol_server = @import("agent_protocol_server");
const agent_protocol_runtime = @import("agent_protocol_runtime");
const transport = @import("transport");
const in_process = @import("transports/in_process");
const stdio_transport = @import("transports/stdio");
const sse_transport = @import("transports/sse");
const json_writer = @import("json_writer");
const model_ref = @import("model_ref");
const session = @import("tui_session");
const local_tools = @import("tools/registry");
const tool_local_runtime = @import("tool_local_runtime");
const permission = @import("permission");
const OwnedSlice = @import("owned_slice").OwnedSlice;
const tui_config = @import("tui_config");

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

pub const PermissionMode = enum {
    ask,
    bypass,
};

pub const TuiRemoteConfig = struct {
    mode: TuiBackendMode = .local,
    transport: TuiRemoteTransport = .stdio,
    endpoint: []const u8 = "",
    command: []const u8 = "",
    auth_token: []const u8 = "",
    auth_headers: []const ai_types.HeaderPair = &.{},

    pub fn deinit(self: *TuiRemoteConfig, allocator: std.mem.Allocator) void {
        if (self.endpoint.len > 0) allocator.free(self.endpoint);
        if (self.command.len > 0) allocator.free(self.command);
        if (self.auth_token.len > 0) allocator.free(self.auth_token);
        for (self.auth_headers) |header| {
            var h = header;
            h.deinit(allocator);
        }
        if (self.auth_headers.len > 0) allocator.free(self.auth_headers);
        self.* = .{};
    }
};

pub fn parseRemoteTransport(value: []const u8) ?TuiRemoteTransport {
    if (std.mem.eql(u8, value, "stdio")) return .stdio;
    if (std.mem.eql(u8, value, "sse")) return .sse;
    if (std.mem.eql(u8, value, "ws")) return .websocket;
    if (std.mem.eql(u8, value, "websocket")) return .websocket;
    return null;
}

fn hasWhitespaceOrControl(value: []const u8) bool {
    for (value) |ch| {
        if (std.ascii.isWhitespace(ch) or ch < 0x20 or ch == 0x7f) return true;
    }
    return false;
}

fn hasCrLf(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "\r\n") != null;
}

fn isTchar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or switch (ch) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn isValidHeaderName(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| if (!isTchar(ch)) return false;
    return true;
}

fn isValidSavedSseEndpoint(endpoint: []const u8) bool {
    if (endpoint.len == 0) return false;
    if (hasWhitespaceOrControl(endpoint)) return false;
    if (std.mem.indexOfScalar(u8, endpoint, '#') != null) return false;
    if (std.mem.indexOfScalar(u8, endpoint, '@') != null) return false;
    const parsed = sse_transport.parseHttpUrl(endpoint) catch return false;
    return parsed.scheme == .http;
}

pub fn remoteConfigFromConfig(allocator: std.mem.Allocator, cfg: tui_config.Config) !TuiRemoteConfig {
    var result = TuiRemoteConfig{
        .mode = if (cfg.remote.enabled) .remote else .local,
        .transport = .stdio,
        .endpoint = if (cfg.remote.endpoint.len > 0) try allocator.dupe(u8, cfg.remote.endpoint) else &.{},
        .command = if (cfg.remote.command.len > 0) try allocator.dupe(u8, cfg.remote.command) else &.{},
        .auth_token = if (cfg.remote.auth_token.len > 0) try allocator.dupe(u8, cfg.remote.auth_token) else &.{},
        .auth_headers = &.{},
    };
    errdefer result.deinit(allocator);

    const transport_name = if (cfg.remote.transport.len > 0) cfg.remote.transport else "stdio";
    if (parseRemoteTransport(transport_name)) |remote_transport| {
        result.transport = remote_transport;
    } else {
        // Invalid hand-edited transport values must not fall back to stdio while
        // remote remains enabled; that would bind the protocol to the TUI's own
        // stdin/stdout. Fall back to local mode instead.
        result.transport = .stdio;
        result.mode = .local;
    }

    // Stdio subprocess spawning and WebSocket are not wired up yet. If a
    // hand-edited/legacy config enables either transport, gracefully fall back to
    // local mode so the TUI launches instead of binding protocol I/O to the
    // TUI's own stdio or aborting on an unsupported backend.
    if (result.transport == .stdio or result.transport == .websocket) {
        result.mode = .local;
    }
    if (result.transport == .sse and !isValidSavedSseEndpoint(result.endpoint)) {
        result.mode = .local;
    }

    var headers: std.ArrayList(ai_types.HeaderPair) = .empty;
    errdefer {
        for (headers.items) |*header| header.deinit(allocator);
        headers.deinit(allocator);
    }
    if (cfg.remote.auth_token.len > 0 and !hasCrLf(cfg.remote.auth_token)) {
        const value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{cfg.remote.auth_token});
        errdefer allocator.free(value);
        try headers.append(allocator, .{ .name = try allocator.dupe(u8, "Authorization"), .value = value });
    } else if (cfg.remote.auth_header_value.len > 0 and !hasCrLf(cfg.remote.auth_header_value)) {
        const name = if (cfg.remote.auth_header_name.len > 0) cfg.remote.auth_header_name else "Authorization";
        if (isValidHeaderName(name)) {
            try headers.append(allocator, .{ .name = try allocator.dupe(u8, name), .value = try allocator.dupe(u8, cfg.remote.auth_header_value) });
        }
    }
    if (headers.items.len > 0) {
        result.auth_headers = try headers.toOwnedSlice(allocator);
    }
    return result;
}

pub const TuiRuntimeOptions = struct {
    backend: TuiBackendMode = .local,
    remote_config: TuiRemoteConfig = .{},
    remote_sender: ?transport.AsyncSender = null,
    remote_receiver: ?RemoteLineReceiver = null,
    remote_session_timeout_ms: u64 = 5_000,
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
    backend: TuiBackendMode,
    protocol: ?agent.ProtocolClient,
    models: []ai_types.Model,
    selected_model_index: ?usize,
    local_agent: ?agent.Agent = null,
    remote_client: ?agent_protocol_client.AgentProtocolClient = null,
    remote_config_sender: ?*stdio_transport.AsyncStdioSender = null,
    remote_config_receiver: ?*stdio_transport.AsyncStdioReceiver = null,
    remote_config_stream_handle: ?*stdio_transport.AsyncStreamHandle = null,
    remote_config_sse_client: ?*sse_transport.SseHttpClient = null,
    remote_config_sse_endpoint: []u8 = &.{},
    remote_config_sse_headers: []ai_types.HeaderPair = &.{},
    remote_sender: ?transport.AsyncSender = null,
    remote_receiver: ?RemoteLineReceiver = null,
    remote_session_id: ?agent_protocol_types.SessionId = null,
    remote_pending_session_id: ?agent_protocol_types.SessionId = null,
    remote_error_emitted: bool = false,
    remote_reconnect_attempted: bool = false,
    remote_session_timeout_ms: u64 = 5_000,
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
    remote_messages: std.ArrayList(ai_types.Message) = .empty,
    remote_steering_queue: std.ArrayList(ai_types.Message) = .empty,
    remote_follow_up_queue: std.ArrayList(ai_types.Message) = .empty,
    remote_auto_resume_pending: bool = false,
    remote_echo_suppression_remaining: usize = 0,
    remote_turn_in_flight: bool = false,
    remote_current_message_role: ?TuiEvent.MessageRole = null,
    last_turn_stop_reason: ?ai_types.StopReason = null,
    compact_output: bool = false,
    run_async: bool = true,
    dropped_event_count: u64 = 0,
    dropped_since_warning: u64 = 0,
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

        const resolved_backend = if (options.remote_config.mode == .remote) .remote else options.backend;
        var remote_config_sender: ?*stdio_transport.AsyncStdioSender = null;
        var remote_config_receiver: ?*stdio_transport.AsyncStdioReceiver = null;
        var remote_config_stream_handle: ?*stdio_transport.AsyncStreamHandle = null;
        var remote_config_sse_client: ?*sse_transport.SseHttpClient = null;
        var remote_config_sse_endpoint: []u8 = &.{};
        var remote_config_sse_headers: []ai_types.HeaderPair = &.{};
        var remote_sender = options.remote_sender;
        var remote_receiver = options.remote_receiver;
        errdefer if (remote_config_stream_handle) |handle| {
            _ = handle.deinit(5_000);
            allocator.destroy(handle);
        };
        errdefer if (remote_config_sender) |sender| allocator.destroy(sender);
        errdefer if (remote_config_receiver) |receiver| allocator.destroy(receiver);
        errdefer if (remote_config_sse_client) |client| {
            client.deinit();
            allocator.destroy(client);
        };
        errdefer if (remote_config_sse_endpoint.len > 0) allocator.free(remote_config_sse_endpoint);
        errdefer {
            for (remote_config_sse_headers) |*header| header.deinit(allocator);
            if (remote_config_sse_headers.len > 0) allocator.free(remote_config_sse_headers);
        }
        if (resolved_backend == .remote and remote_sender == null and remote_receiver == null and options.remote_config.mode == .remote) {
            switch (options.remote_config.transport) {
                .stdio => {
                    if (options.remote_config.endpoint.len != 0) return error.UnsupportedRemoteEndpoint;
                    const sender = try allocator.create(stdio_transport.AsyncStdioSender);
                    sender.* = stdio_transport.AsyncStdioSender.init();
                    remote_config_sender = sender;
                    const receiver = try allocator.create(stdio_transport.AsyncStdioReceiver);
                    receiver.* = stdio_transport.AsyncStdioReceiver.init();
                    var receiver_nonblocking = false;
                    errdefer if (receiver_nonblocking) {
                        receiver.file = compat.stdio.setBlockingFile(receiver.file) catch receiver.file;
                    };
                    receiver.file = try compat.stdio.setNonBlockingFile(receiver.file);
                    receiver_nonblocking = true;
                    remote_config_receiver = receiver;
                    const handle = try allocator.create(stdio_transport.AsyncStreamHandle);
                    errdefer allocator.destroy(handle);
                    handle.* = try receiver.receiveStreamWithHandle(allocator);
                    var handle_initialized = true;
                    errdefer if (handle_initialized) {
                        _ = handle.deinit(5_000);
                    };
                    const fallback_receiver = try allocator.create(stdio_transport.StdioReceiver);
                    fallback_receiver.* = stdio_transport.StdioReceiver.initWithFileAndCancelToken(receiver.file, allocator, handle.cancel_token);
                    handle.fallback_receiver = fallback_receiver;
                    receiver_nonblocking = false;
                    remote_config_stream_handle = handle;
                    handle_initialized = false;
                    remote_sender = sender.sender();
                    remote_receiver = .{ .ctx = handle, .read_line_fn = remoteConfigStdioReadLine, .read_result_fn = remoteConfigStdioReadResult, .close_fn = remoteConfigStdioClose };
                },
                .sse => {
                    if (options.remote_config.endpoint.len == 0) return error.UnsupportedRemoteEndpoint;
                    const client = try allocator.create(sse_transport.SseHttpClient);
                    var client_initialized = false;
                    errdefer if (!client_initialized) allocator.destroy(client);
                    client.* = sse_transport.SseHttpClient.init(allocator);
                    client_initialized = true;
                    var client_moved = false;
                    errdefer if (!client_moved) {
                        client.deinit();
                        allocator.destroy(client);
                    };
                    try client.connect(options.remote_config.endpoint, options.remote_config.auth_headers);
                    remote_config_sse_endpoint = try allocator.dupe(u8, options.remote_config.endpoint);
                    remote_config_sse_headers = try allocator.alloc(ai_types.HeaderPair, options.remote_config.auth_headers.len);
                    for (options.remote_config.auth_headers, 0..) |header, i| remote_config_sse_headers[i] = .{ .name = try allocator.dupe(u8, header.name), .value = try allocator.dupe(u8, header.value) };
                    remote_config_sse_client = client;
                    client_moved = true;
                    remote_sender = client.asyncSender();
                    remote_receiver = .{ .ctx = client, .read_line_fn = remoteConfigSseReadLine, .read_result_fn = remoteConfigSseReadResult, .close_fn = remoteConfigSseClose };
                },
                .websocket => return error.UnsupportedRemoteTransport,
            }
        }

        var tool_protocol = try tool_local_runtime.LocalToolProtocol.init(allocator, original_tools);
        errdefer tool_protocol.deinit();

        var workspace_root = try allocator.dupe(u8, options.workspace_root);
        errdefer allocator.free(workspace_root);

        var runtime = TuiRuntime{
            .allocator = allocator,
            .backend = resolved_backend,
            .protocol = options.protocol,
            .remote_config_sender = remote_config_sender,
            .remote_config_receiver = remote_config_receiver,
            .remote_config_stream_handle = remote_config_stream_handle,
            .remote_config_sse_client = remote_config_sse_client,
            .remote_config_sse_endpoint = remote_config_sse_endpoint,
            .remote_config_sse_headers = remote_config_sse_headers,
            .remote_sender = remote_sender,
            .remote_receiver = remote_receiver,
            .remote_session_timeout_ms = options.remote_session_timeout_ms,
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
        remote_config_sender = null;
        remote_config_receiver = null;
        remote_config_stream_handle = null;
        remote_config_sse_client = null;
        remote_config_sse_endpoint = &.{};
        remote_config_sse_headers = &.{};
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
        self.clearRemoteMessages();
        self.clearRemoteQueues();
        self.remote_messages.deinit(self.allocator);
        self.remote_steering_queue.deinit(self.allocator);
        self.remote_follow_up_queue.deinit(self.allocator);
        self.event_stream.deinit();
        if (self.remote_client) |*client| client.deinit();
        if (self.remote_config_stream_handle) |handle| {
            _ = handle.deinit(5_000);
            self.allocator.destroy(handle);
        }
        if (self.remote_config_receiver) |receiver| self.allocator.destroy(receiver);
        if (self.remote_config_sender) |sender| self.allocator.destroy(sender);
        if (self.remote_config_sse_client) |client| {
            client.deinit();
            self.allocator.destroy(client);
        }
        if (self.remote_config_sse_endpoint.len > 0) self.allocator.free(self.remote_config_sse_endpoint);
        for (self.remote_config_sse_headers) |*header| header.deinit(self.allocator);
        if (self.remote_config_sse_headers.len > 0) self.allocator.free(self.remote_config_sse_headers);
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
        switch (self.backend) {
            .remote => {
                if (self.started) return;
                var client = agent_protocol_client.AgentProtocolClient.init(self.allocator);
                var client_moved = false;
                errdefer if (!client_moved) client.deinit();
                if (self.remote_config_sse_client) |sse_client| {
                    if (!sse_client.connected) try sse_client.connect(self.remote_config_sse_endpoint, self.remote_config_sse_headers);
                }
                const sender = self.remote_sender orelse return error.NoRemoteTransportConfigured;
                _ = self.remote_receiver orelse return error.NoRemoteTransportConfigured;
                client.setSender(sender);
                const config_json = try self.remoteConfigJson();
                defer self.allocator.free(config_json);
                const system_prompt = try self.workspaceSystemPrompt();
                defer self.allocator.free(system_prompt);
                const sid = agent_protocol_types.generateSessionId();
                _ = try client.sendAgentStartWithSession(sid, config_json, system_prompt);
                self.remote_pending_session_id = sid;
                self.remote_client = client;
                client_moved = true;
                self.started = true;
                self.remote_error_emitted = false;
                self.remote_reconnect_attempted = false;
                self.pumpRemoteIncoming() catch |err| {
                    if (self.remote_sender) |remote_sender| remote_sender.close();
                    if (self.remote_config_stream_handle == null) {
                        if (self.remote_receiver) |*remote_receiver| remote_receiver.close();
                    }
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
                self.local_agent = agent.Agent.init(self.allocator, .{
                    .protocol = protocol,
                    .compact_tool_output = self.compact_output,
                    .permission_engine = self.permission_engine,
                    .execute_tool_via_protocol_fn = executeTuiToolProtocol,
                    .execute_tool_via_protocol_ctx = self,
                });
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
            if (self.remote_config_stream_handle == null) {
                if (self.remote_receiver) |*receiver| receiver.close();
            }
            client.deinit();
            self.remote_client = null;
            self.remote_session_id = null;
            self.remote_pending_session_id = null;
            self.remote_error_emitted = false;
            self.remote_reconnect_attempted = false;
        }
        self.started = false;
    }

    pub fn canSteer(self: *const TuiRuntime) bool {
        return self.backend == .local;
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
                .queue_follow_up = sessionQueueFollowUp,
                .clear_queued_messages = sessionClearQueuedMessages,
                .queued_counts = sessionQueuedCounts,
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
        switch (self.backend) {
            .remote => {
                if (!self.started) try self.start();
                if (self.currentModel() == null) return error.NoModelConfigured;
                if (self.stream_active and !self.event_stream.isDone()) return error.AgentAlreadyStreaming;
                if (self.remote_turn_in_flight) return error.AgentAlreadyStreaming;
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
                try self.sendRemoteMessages(self.remote_messages.items, true);
                message_sent = true;
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
                    var msg = try self.makeUserMessage(text);
                    defer msg.deinit(self.allocator);
                    try local.promptAsync(msg);
                } else {
                    const msg = try self.makeUserMessage(text);
                    try local.prompt(msg);
                }
            },
        }
    }

    pub fn steer(self: *TuiRuntime, text: []const u8) !void {
        switch (self.backend) {
            .remote => {
                if (!self.started) return error.RuntimeNotStarted;
                var msg = try makeRemoteUserMessage(self.allocator, text);
                var queued = false;
                errdefer if (!queued) msg.deinit(self.allocator);
                try self.remote_steering_queue.append(self.allocator, msg);
                queued = true;
                try self.resumeQueuedMessagesIfIdle();
            },
            .local => {
                if (!self.started) return error.RuntimeNotStarted;
                const local = &(self.local_agent orelse return error.RuntimeNotStarted);
                var msg = try self.makeUserMessage(text);
                var queued = false;
                errdefer if (!queued) msg.deinit(self.allocator);
                try local.steer(msg);
                queued = true;
                try self.resumeQueuedMessagesIfIdle();
            },
        }
    }

    pub fn queueFollowUp(self: *TuiRuntime, text: []const u8) !void {
        switch (self.backend) {
            .remote => {
                if (!self.started) return error.RuntimeNotStarted;
                var msg = try makeRemoteUserMessage(self.allocator, text);
                var queued = false;
                errdefer if (!queued) msg.deinit(self.allocator);
                try self.remote_follow_up_queue.append(self.allocator, msg);
                queued = true;
                try self.resumeQueuedMessagesIfIdle();
            },
            .local => {
                if (!self.started) return error.RuntimeNotStarted;
                const local = &(self.local_agent orelse return error.RuntimeNotStarted);
                var msg = try self.makeUserMessage(text);
                var queued = false;
                errdefer if (!queued) msg.deinit(self.allocator);
                try local.followUp(msg);
                queued = true;
                try self.resumeQueuedMessagesIfIdle();
            },
        }
    }

    fn resumeQueuedMessagesIfIdle(self: *TuiRuntime) !void {
        switch (self.backend) {
            .remote => {
                if (self.remote_turn_in_flight or self.stream_active) return;
                if (!self.event_stream.isDone() or self.event_stream.hasPending()) return;
                if (self.remote_messages.items.len == 0) return;
                if (self.remote_messages.items[self.remote_messages.items.len - 1] != .assistant) return;
                if (self.remote_steering_queue.items.len == 0 and self.remote_follow_up_queue.items.len == 0) return;
                self.resumeRemoteSession() catch return;
            },
            .local => {
                const local = &(self.local_agent orelse return);
                if (!local.isIdle()) return;
                local.validateContinueFromContext() catch return;
                try self.resumeSession();
            },
        }
    }

    pub fn clearQueuedMessages(self: *TuiRuntime) void {
        switch (self.backend) {
            .remote => self.clearRemoteQueues(),
            .local => {
                const local = &(self.local_agent orelse return);
                local.clearAllQueues();
            },
        }
    }

    pub fn queuedCounts(self: *TuiRuntime) QueuedCounts {
        switch (self.backend) {
            .remote => return .{ .steering = self.remote_steering_queue.items.len, .follow_up = self.remote_follow_up_queue.items.len },
            .local => {
                const local = &(self.local_agent orelse return .{});
                return local.queuedCounts();
            },
        }
    }

    pub fn replaceMessages(self: *TuiRuntime, messages: []const ai_types.Message) !void {
        switch (self.backend) {
            .remote => {
                if (!self.started) try self.start();
                if (self.stream_active and !self.event_stream.isDone()) return error.AgentAlreadyStreaming;
                if (self.remote_turn_in_flight) return error.AgentAlreadyStreaming;
                self.clearRemoteQueues();
                self.clearRemoteMessages();
                self.resetBackpressureState();
                errdefer self.clearRemoteMessages();
                for (messages) |message| try self.remote_messages.append(self.allocator, try ai_types.cloneMessage(self.allocator, message));
            },
            .local => {
                if (!self.started) try self.start();
                const local = &(self.local_agent orelse return error.RuntimeNotStarted);
                if (self.run_async) local.waitForIdle();
                local.clearAllQueues();
                self.resetBackpressureState();
                try local.replaceMessages(messages);
            },
        }
    }

    pub fn compactMessages(self: *TuiRuntime) !CompactMessagesResult {
        switch (self.backend) {
            .remote => {
                if (self.stream_active and !self.event_stream.isDone()) return error.AgentAlreadyStreaming;
                return try ai_types.compactMessageHistory(self.allocator, &self.remote_messages);
            },
            .local => {
                if (!self.started) try self.start();
                const local = &(self.local_agent orelse return error.RuntimeNotStarted);
                if (self.run_async) local.waitForIdle();
                local.clearAllQueues();
                return try local.compactMessages();
            },
        }
    }

    pub fn resumeSession(self: *TuiRuntime) !void {
        switch (self.backend) {
            .remote => return try self.resumeRemoteSession(),
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
                self.remote_auto_resume_pending = false;
                self.remote_turn_in_flight = false;
            }
        }
        while (!self.approval_mutex.tryLock()) std.atomic.spinLoopHint();
        self.pending_approval.cancelled = true;
        self.pending_approval.decision = .reject;
        self.approval_mutex.unlock();
    }

    pub fn streamEvents(self: *TuiRuntime) *TuiEventStream {
        if (self.backend == .remote and self.started) {
            if (!self.event_stream.isDone()) {
                self.pumpRemoteIncoming() catch |err| {
                    self.completeRemoteWithError(@errorName(err)) catch {
                        self.push(.{ .@"error" = .{ .message = self.dupeOwned(@errorName(err)) catch OwnedSlice(u8).initBorrowed("") } });
                    };
                };
            }
            if (self.remote_turn_in_flight and self.event_stream.isDone() and !self.event_stream.hasPending()) {
                self.pumpRemoteIncoming() catch |err| {
                    self.completeRemoteWithError(@errorName(err)) catch {
                        self.push(.{ .@"error" = .{ .message = self.dupeOwned(@errorName(err)) catch OwnedSlice(u8).initBorrowed("") } });
                    };
                };
            }
            const remote_complete = if (self.remote_session_id) |sid| (self.remote_client != null and self.remote_client.?.isSessionComplete(sid)) else false;
            if (self.remote_auto_resume_pending and remote_complete and self.event_stream.isDone() and !self.event_stream.hasPending()) {
                self.remote_auto_resume_pending = false;
                self.resumeRemoteSession() catch |err| {
                    self.completeRemoteWithError(@errorName(err)) catch {
                        self.push(.{ .@"error" = .{ .message = self.dupeOwned(@errorName(err)) catch OwnedSlice(u8).initBorrowed("") } });
                    };
                };
            }
        }
        return &self.event_stream;
    }

    /// Snapshot of backpressure state for UI polling. The UI calls this once
    /// per frame after draining events so the status bar always reflects the
    /// current runtime state without depending on event drain ordering.
    pub fn backpressureState(self: *TuiRuntime) struct { active: bool, dropped_count: u64 } {
        while (!self.backpressure_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.backpressure_mutex.unlock();
        const active = self.backpressure_active.load(.acquire);
        const dropped_count = self.dropped_event_count;
        // Auto-clear the internal flag when the ring has recovered, but return
        // the pre-clear snapshot once so AppState can render the active
        // backpressure frame before settling to drops-only on the next poll.
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
        if (!self.stream_active or self.event_stream.isDone()) {
            self.event_stream.deinit();
            self.event_stream = TuiEventStream.init(self.allocator);
            // The fresh stream belongs to a new turn/session; backpressure
            // counters from the previous stream no longer apply to it.
            self.resetBackpressureState();
        }
        self.stream_active = true;
    }

    fn resetEventStreamAfterFailedSend(self: *TuiRuntime) void {
        self.event_stream.deinit();
        self.event_stream = TuiEventStream.init(self.allocator);
        self.stream_active = false;
        self.completed = true;
        self.remote_turn_in_flight = false;
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
        // Preserve the newest event (mainline TUI behavior) and count the
        // evicted oldest event as the drop. Flush the warning after the real
        // event so a pending warning cannot steal the only free slot.
        self.pushDroppingOldestCounted(event);
        self.flushDroppedWarning();
    }

    fn pushTerminal(self: *TuiRuntime, event: TuiEvent) void {
        // Terminal events must not be dropped just because the projection queue
        // is saturated. After queuing the terminal event, force any warning from
        // terminal-path evictions into the stream too; there may be no later push
        // before the stream completes.
        self.pushDroppingOldestCounted(event);
        self.flushDroppedWarningDroppingOldest();
    }

    fn pushDroppingOldestCounted(self: *TuiRuntime, event: TuiEvent) void {
        while (true) {
            if (self.pushUncounted(event)) return;
            // Stream was full when we attempted to enqueue. The UI consumer does
            // not take backpressure_mutex while draining, so retry after taking
            // the lock before evicting: a consumer may have freed a slot between
            // the failed push and this point.
            while (!self.backpressure_mutex.tryLock()) std.atomic.spinLoopHint();
            if (self.event_stream.push(event)) {
                self.backpressure_mutex.unlock();
                return;
            } else |err| switch (err) {
                error.QueueFull => {},
                error.StreamCompleted => {
                    self.backpressure_mutex.unlock();
                    var mutable = event;
                    mutable.deinit(self.allocator);
                    return;
                },
            }
            // Stream is still full. Evict the oldest pending event to make room
            // for this event, counting only the confirmed eviction as a drop.
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
            error.StreamCompleted => {
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
            self.event_stream.push(.{ .@"error" = .{ .message = self.dupeOwned(@errorName(err)) catch OwnedSlice(u8).initBorrowed("") } }) catch {};
            return;
        };
        const warning = TuiEvent{ .system_warning = .{ .message = OwnedSlice(u8).initOwned(message) } };
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
            const warning = TuiEvent{ .system_warning = .{ .message = OwnedSlice(u8).initOwned(message) } };
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

    fn remoteConfigJson(self: *TuiRuntime) ![]u8 {
        var buffer = std.ArrayList(u8).empty;
        errdefer buffer.deinit(self.allocator);
        var w = json_writer.JsonWriter.init(&buffer, self.allocator);
        try w.beginObject();
        if (self.currentModel()) |model| try w.writeStringField("model", model.id);
        try w.writeBoolField("compact_output", self.compact_output);
        try w.writeStringField("permission_mode", @tagName(self.permission_mode));
        try w.writeStringField("thinking_level", @tagName(self.thinking_level));
        if (self.workspace_root.len > 0) try w.writeStringField("workspace_root", self.workspace_root);
        try w.endObject();
        const out = try self.allocator.dupe(u8, buffer.items);
        buffer.deinit(self.allocator);
        return out;
    }

    fn remoteMessageOptionsJson(self: *TuiRuntime) ![]u8 {
        var buffer = std.ArrayList(u8).empty;
        errdefer buffer.deinit(self.allocator);
        var w = json_writer.JsonWriter.init(&buffer, self.allocator);
        try w.beginObject();
        try w.writeStringField("thinking_level", @tagName(self.thinking_level));
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

        if (self.remote_pending_session_id) |pending_sid| {
            if (!sessionIdsEqual(client_sid, pending_sid)) {
                client.removeSessionState(client_sid);
                client.session_id = null;
                return;
            }
            self.remote_session_id = client_sid;
            self.remote_pending_session_id = null;
            self.remote_reconnect_attempted = false;
            return;
        }

        if (self.remote_session_id) |active_sid| {
            if (!sessionIdsEqual(client_sid, active_sid)) {
                client.removeSessionState(client_sid);
                client.session_id = active_sid;
                return;
            }
            return;
        }

        client.removeSessionState(client_sid);
        client.session_id = null;
    }

    fn sendRemoteMessages(self: *TuiRuntime, messages: []const ai_types.Message, emit_tail_prompt: bool) !void {
        try self.ensureRemoteSession();
        const client = &(self.remote_client orelse return error.RuntimeNotStarted);
        const sid = self.remote_session_id orelse return error.RemoteAgentStartFailed;
        const message_json = try makeRemoteMessageJson(self.allocator, self.currentModel(), messages, self.remoteSerializableTools());
        defer self.allocator.free(message_json);
        self.resetEventStreamForTurn();
        errdefer self.resetEventStreamAfterFailedSend();
        self.cancelled.store(false, .release);
        self.completed = false;
        self.remote_error_emitted = false;
        self.remote_reconnect_attempted = false;
        client.clearSessionTerminalState(sid);
        self.remote_turn_in_flight = true;
        self.last_turn_stop_reason = null;
        const options_json = try self.remoteMessageOptionsJson();
        defer self.allocator.free(options_json);
        self.remote_echo_suppression_remaining = messages.len;
        self.remote_current_message_role = null;
        _ = try client.sendAgentMessage(sid, message_json, options_json);
        if (emit_tail_prompt) try self.pushRemoteTailPromptEvent(messages);
        self.pumpRemoteIncoming() catch |err| {
            try self.completeRemoteWithError(@errorName(err));
        };
        if (client.getLastErrorForSession(sid) != null) {
            if (emit_tail_prompt) self.discardRemoteTailPromptEvent();
            return error.RemoteMessageRejected;
        }
    }

    fn resumeRemoteSession(self: *TuiRuntime) !void {
        if (!self.started) try self.start();
        if (self.currentModel() == null) return error.NoModelConfigured;
        if (self.stream_active and !self.event_stream.isDone()) return error.AgentAlreadyStreaming;
        if (self.remote_turn_in_flight) return error.AgentAlreadyStreaming;
        if (self.remote_messages.items.len == 0) return error.NoMessagesToContinue;
        const last = self.remote_messages.items[self.remote_messages.items.len - 1];
        var consumed_queue: ?*std.ArrayList(ai_types.Message) = null;
        if (last == .assistant) {
            if (self.remote_steering_queue.items.len > 0) {
                try self.appendCloneOfFirstQueuedMessage(&self.remote_steering_queue);
                consumed_queue = &self.remote_steering_queue;
            } else if (self.remote_follow_up_queue.items.len > 0) {
                try self.appendCloneOfFirstQueuedMessage(&self.remote_follow_up_queue);
                consumed_queue = &self.remote_follow_up_queue;
            } else {
                return error.CannotContinueFromAssistant;
            }
        }
        var sent = false;
        errdefer if (!sent and consumed_queue != null) {
            var appended = self.remote_messages.pop().?;
            appended.deinit(self.allocator);
        };
        try self.sendRemoteMessages(self.remote_messages.items, consumed_queue != null);
        sent = true;
        if (consumed_queue) |queue| {
            var removed = queue.orderedRemove(0);
            removed.deinit(self.allocator);
        }
    }

    fn appendCloneOfFirstQueuedMessage(self: *TuiRuntime, queue: *std.ArrayList(ai_types.Message)) !void {
        if (queue.items.len == 0) return;
        var cloned = try ai_types.cloneMessage(self.allocator, queue.items[0]);
        var appended = false;
        errdefer if (!appended) cloned.deinit(self.allocator);
        try self.remote_messages.append(self.allocator, cloned);
        appended = true;
    }

    fn pushRemoteTailPromptEvent(self: *TuiRuntime, messages: []const ai_types.Message) !void {
        if (messages.len == 0) return;
        const event = TuiEvent{ .message_end = try self.messageEndPayload(messages[messages.len - 1]) };
        self.push(event);
    }

    fn discardRemoteTailPromptEvent(self: *TuiRuntime) void {
        var pending = std.ArrayList(TuiEvent).empty;
        defer pending.deinit(self.allocator);
        while (self.event_stream.poll()) |event| pending.append(self.allocator, event) catch |err| {
            var mutable = event;
            mutable.deinit(self.allocator);
            for (pending.items) |*queued| queued.deinit(self.allocator);
            pending.clearRetainingCapacity();
            self.completeRemoteWithError(@errorName(err)) catch {};
            return;
        };
        if (pending.items.len == 0) return;
        var tail = pending.orderedRemove(0);
        tail.deinit(self.allocator);
        while (pending.items.len > 0) {
            const event = pending.orderedRemove(0);
            self.push(event);
        }
    }

    fn handleRemoteAgentEnd(self: *TuiRuntime) anyerror!void {
        const reason: TuiEndReason = if (self.cancelled.load(.acquire)) .cancelled else if (self.last_turn_stop_reason == .@"error") .@"error" else .completed;
        self.completed = true;
        self.pushTerminal(.{ .agent_end = .{ .reason = reason } });
        self.event_stream.complete(.{ .reason = reason });
        self.stream_active = false;
        if (reason == .completed and (self.remote_steering_queue.items.len > 0 or self.remote_follow_up_queue.items.len > 0)) {
            self.remote_auto_resume_pending = true;
        }
    }

    fn ensureRemoteSession(self: *TuiRuntime) !void {
        if (self.remote_session_id != null) return;
        if (self.remote_pending_session_id == null) {
            var client = &(self.remote_client orelse return error.RuntimeNotStarted);
            const config_json = try self.remoteConfigJson();
            defer self.allocator.free(config_json);
            const system_prompt = try self.workspaceSystemPrompt();
            defer self.allocator.free(system_prompt);
            const sid = agent_protocol_types.generateSessionId();
            _ = try client.sendAgentStartWithSession(sid, config_json, system_prompt);
            self.remote_pending_session_id = sid;
        }
        const timeout_ns = self.remote_session_timeout_ms * std.time.ns_per_ms;
        const start_ns = compat.time.monotonicNanos() catch 0;
        while (true) {
            try self.pumpRemoteIncoming();
            if (self.remote_session_id != null) return;
            const now_ns = compat.time.monotonicNanos() catch (start_ns + timeout_ns);
            if (now_ns -| start_ns >= timeout_ns) {
                if (self.remote_pending_session_id) |sid| {
                    if (self.remote_client) |*client| client.removeSessionState(sid);
                    self.remote_pending_session_id = null;
                }
                return error.RemoteAgentStartFailed;
            }
            compat.time.sleepNs(@min(@as(u64, 10 * std.time.ns_per_ms), timeout_ns - (now_ns -| start_ns)));
        }
    }

    fn completeRemoteWithError(self: *TuiRuntime, message: []const u8) !void {
        self.remote_turn_in_flight = false;
        self.remote_auto_resume_pending = false;
        if (self.event_stream.isDone()) return;
        self.completed = true;
        self.push(.{ .@"error" = .{ .message = try self.dupeOwned(message) } });
        self.pushTerminal(.{ .agent_end = .{ .reason = .@"error" } });
        self.event_stream.complete(.{ .reason = .@"error" });
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
            if (self.remote_config_sse_client) |sse_client| {
                try sse_client.connect(self.remote_config_sse_endpoint, self.remote_config_sse_headers);
            }
            if (was_stream_active) {
                try self.completeRemoteWithError("remote connection disconnected");
            } else if (self.remote_turn_in_flight) {
                self.remote_turn_in_flight = false;
                self.remote_auto_resume_pending = false;
            }
            const config_json = try self.remoteConfigJson();
            defer self.allocator.free(config_json);
            const system_prompt = try self.workspaceSystemPrompt();
            defer self.allocator.free(system_prompt);
            const sid = agent_protocol_types.generateSessionId();
            _ = try client.sendAgentStartWithSession(sid, config_json, system_prompt);
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
        const sid = self.remote_session_id orelse self.remote_pending_session_id;
        if (sid) |session_id| {
            if (client.isSessionComplete(session_id)) {
                self.remote_turn_in_flight = false;
                if (client.getLastResultJsonForSession(session_id)) |json| try self.recordRemoteResultJson(json);
            }
            if (!self.remote_error_emitted) {
                if (client.getLastErrorForSession(session_id)) |msg| {
                    self.remote_turn_in_flight = false;
                    self.remote_error_emitted = true;
                    self.remote_pending_session_id = null;
                    try self.completeRemoteWithError(msg);
                }
            }
        }
    }

    fn recordRemoteResultJson(self: *TuiRuntime, json: []const u8) !void {
        if (self.remote_messages.items.len > 0 and self.remote_messages.items[self.remote_messages.items.len - 1] == .assistant) return;
        var decoded = transport.deserialize(json, self.allocator) catch return;
        switch (decoded) {
            .result => |*msg| {
                defer msg.deinit(self.allocator);
                try self.recordRemoteAssistantMessage(msg.*);
            },
            else => |payload| transport.freeMessageOrControlStrings(payload, self.allocator),
        }
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

    fn handleRemoteAgentEventJson(self: *TuiRuntime, json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidRemoteEvent;
        const obj = parsed.value.object;
        const type_name = getJsonString(obj, "type") orelse return error.InvalidRemoteEvent;

        if (std.mem.eql(u8, type_name, "agent_start")) return self.push(.agent_start);
        if (std.mem.eql(u8, type_name, "turn_start")) return self.push(.turn_start);
        if (std.mem.eql(u8, type_name, "message_start")) {
            if (self.remote_echo_suppression_remaining > 0) return;
            const role = parseRemoteMessageRole(getJsonString(obj, "role"));
            self.remote_current_message_role = role;
            return self.push(.{ .message_start = .{ .role = role } });
        }
        if (std.mem.eql(u8, type_name, "message_end")) {
            if (obj.get("message")) |message_value| {
                const message = try deserializeRemoteMessageValue(self.allocator, message_value);
                switch (message) {
                    .result => |msg| {
                        defer {
                            var mutable = msg;
                            mutable.deinit(self.allocator);
                        }
                        try self.recordRemoteAssistantMessage(msg);
                        return self.push(.{ .message_end = try self.messageEndPayload(.{ .assistant = msg }) });
                    },
                    else => return error.InvalidRemoteEvent,
                }
            }
            if (self.remote_echo_suppression_remaining > 0) {
                self.remote_echo_suppression_remaining -= 1;
                return;
            }
            const role = if (getJsonString(obj, "role")) |role_text| parseRemoteMessageRole(role_text) else self.remote_current_message_role orelse .assistant;
            self.remote_current_message_role = null;
            return self.push(.{ .message_end = .{ .role = role } });
        }
        if (std.mem.eql(u8, type_name, "message_update")) {
            const event_value = obj.get("event") orelse return error.InvalidRemoteEvent;
            self.push(.{ .provider_event = .{ .event_json = OwnedSlice(u8).initOwned(try jsonValueToOwnedString(self.allocator, event_value)) } });
            const msg = try deserializeRemoteMessageValue(self.allocator, event_value);
            switch (msg) {
                .event => |ev| {
                    defer {
                        var mutable = ev;
                        ai_types.deinitAssistantMessageEvent(self.allocator, &mutable);
                    }
                    if (ev == .done) {
                        try self.recordRemoteAssistantMessage(ev.done.message);
                        return self.push(.{ .message_end = try self.messageEndPayload(.{ .assistant = ev.done.message }) });
                    }
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
            const content_json = getJsonString(obj, "content_json") orelse result_json;
            const is_error = getJsonBool(obj, "is_error") orelse return error.InvalidRemoteEvent;
            try self.recordRemoteToolResultJson(tool_call_id, tool_name, content_json, getJsonString(obj, "details_json") orelse result_json, is_error);
            return self.push(.{ .tool_execution_end = .{
                .tool_call_id = try self.dupeOwned(tool_call_id),
                .tool_name = try self.dupeOwned(tool_name),
                .result_json = try self.dupeOwned(result_json),
                .is_error = is_error,
                .raw_total_bytes = getJsonU64(obj, "raw_total_bytes") orelse 0,
                .returned_total_bytes = getJsonU64(obj, "returned_total_bytes") orelse 0,
                .estimated_returned_tokens = getJsonU64(obj, "estimated_returned_tokens") orelse 0,
                .artifact_count = getJsonU32(obj, "artifact_count") orelse getJsonArrayLenU32(obj, "artifacts") orelse 0,
                .artifact_refs = try self.remoteArtifactRefs(obj),
            } });
        }
        if (std.mem.eql(u8, type_name, "context_usage")) return self.push(.{ .context_usage = .{
            .system_prompt_bytes = getJsonU64(obj, "system_prompt_bytes") orelse 0,
            .message_bytes = getJsonU64(obj, "message_bytes") orelse 0,
            .tool_definition_bytes = getJsonU64(obj, "tool_definition_bytes") orelse 0,
            .total_bytes = getJsonU64(obj, "total_bytes") orelse 0,
            .estimated_tokens = getJsonU64(obj, "estimated_tokens") orelse 0,
            .message_count = getJsonU32(obj, "message_count") orelse 0,
            .tool_count = getJsonU32(obj, "tool_count") orelse 0,
        } });
        if (std.mem.eql(u8, type_name, "prompt_segment_usage")) return self.push(.{ .prompt_segment_usage = .{
            .segment = parseRemotePromptSegmentKind(getJsonString(obj, "segment")),
            .cache_role = parseRemotePromptSegmentCacheRole(getJsonString(obj, "cache_role")),
            .bytes = getJsonU64(obj, "bytes") orelse 0,
            .estimated_tokens = getJsonU64(obj, "estimated_tokens") orelse 0,
            .item_count = getJsonU32(obj, "item_count") orelse 0,
        } });
        if (std.mem.eql(u8, type_name, "turn_end")) {
            const reason = parseStopReason(getJsonString(obj, "stop_reason") orelse "stop");
            self.last_turn_stop_reason = reason;
            return self.pushTerminal(.{ .turn_end = .{ .stop_reason = reason } });
        }
        if (std.mem.eql(u8, type_name, "agent_end")) {
            try self.handleRemoteAgentEnd();
            return;
        }
        if (std.mem.eql(u8, type_name, "error")) return self.push(.{ .@"error" = .{ .message = try self.dupeOwned(getJsonString(obj, "message") orelse return error.InvalidRemoteEvent) } });
    }

    fn handleAgentEvent(self: *TuiRuntime, event: agent.AgentEvent) !void {
        switch (event) {
            .agent_start => self.push(.agent_start),
            .turn_start => self.push(.turn_start),
            .message_start => |payload| {
                if (self.remote_echo_suppression_remaining == 0) self.push(.{ .message_start = .{ .role = messageRole(payload.message) } });
            },
            .message_update => |payload| {
                try self.pushProviderEvent(payload.event);
                if (self.backend == .remote and payload.event == .done) try self.recordRemoteAssistantMessage(payload.event.done.message);
                try self.pushMessageUpdate(payload.event);
            },
            .message_end => |payload| {
                if (self.remote_echo_suppression_remaining > 0) {
                    self.remote_echo_suppression_remaining -= 1;
                } else {
                    self.push(.{ .message_end = try self.messageEndPayload(payload.message) });
                }
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
            .agent_end => try self.handleRemoteAgentEnd(),
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
        const content = parseRemoteToolResultContentFromJson(self.allocator, result_json) catch |err| switch (err) {
            error.SyntaxError, error.UnexpectedToken => try parseRemoteToolResultText(self.allocator, result_json),
            else => return err,
        };
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

    fn clearRemoteQueues(self: *TuiRuntime) void {
        self.remote_auto_resume_pending = false;
        if (!self.remote_turn_in_flight) {
            self.remote_echo_suppression_remaining = 0;
            self.remote_current_message_role = null;
        }
        for (self.remote_steering_queue.items) |*message| message.deinit(self.allocator);
        self.remote_steering_queue.clearRetainingCapacity();
        for (self.remote_follow_up_queue.items) |*message| message.deinit(self.allocator);
        self.remote_follow_up_queue.clearRetainingCapacity();
    }

    fn remoteArtifactRefs(self: *TuiRuntime, obj: std.json.ObjectMap) !OwnedSlice(u8) {
        if (getJsonString(obj, "artifact_refs")) |refs| return self.dupeOwned(refs);
        const value = obj.get("artifacts") orelse return self.dupeOwned("");
        if (value != .array) return self.dupeOwned("");
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const writer = &out.writer;
        for (value.array.items, 0..) |item, i| {
            if (item != .object) continue;
            const artifact_id = getJsonString(item.object, "artifact_id") orelse continue;
            if (i > 0) try writer.writeAll(", ");
            if (getJsonString(item.object, "uri")) |uri| {
                try writer.writeAll(uri);
            } else {
                try writer.writeAll(artifact_id);
            }
        }
        return OwnedSlice(u8).initOwned(try out.toOwnedSlice());
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

fn remoteConfigStdioReadLine(ctx: *anyopaque, allocator: std.mem.Allocator) !?[]const u8 {
    return switch (try remoteConfigStdioReadResult(ctx, allocator)) {
        .line => |line| line,
        .pending, .disconnected => null,
    };
}

fn remoteConfigStdioReadResult(ctx: *anyopaque, allocator: std.mem.Allocator) !RemoteReadResult {
    const handle: *stdio_transport.AsyncStreamHandle = @ptrCast(@alignCast(ctx));
    if (handle.stream.poll()) |chunk| {
        defer {
            var mutable = chunk;
            mutable.deinit(handle.allocator);
        }
        return .{ .line = try allocator.dupe(u8, chunk.data) };
    }
    if (handle.stream.isDone()) {
        if (handle.fallback_receiver) |receiver| {
            if (try receiver.receiver().read(allocator)) |line| return .{ .line = line };
            return switch (receiver.last_status) {
                .would_block => .pending,
                .pending => .pending,
                .eof, .cancelled, .read_error => .disconnected,
            };
        }
        return .disconnected;
    }
    return .pending;
}

fn remoteConfigStdioClose(ctx: *anyopaque) void {
    const handle: *stdio_transport.AsyncStreamHandle = @ptrCast(@alignCast(ctx));
    handle.cancel();
}

fn remoteConfigSseReadLine(ctx: *anyopaque, allocator: std.mem.Allocator) !?[]const u8 {
    return switch (try remoteConfigSseReadResult(ctx, allocator)) {
        .line => |line| line,
        .pending, .disconnected => null,
    };
}

fn remoteConfigSseReadResult(ctx: *anyopaque, allocator: std.mem.Allocator) !RemoteReadResult {
    const client: *sse_transport.SseHttpClient = @ptrCast(@alignCast(ctx));
    if (try client.readLine(allocator)) |line| return .{ .line = line };
    return if (client.connected) .pending else .disconnected;
}

fn remoteConfigSseClose(ctx: *anyopaque) void {
    const client: *sse_transport.SseHttpClient = @ptrCast(@alignCast(ctx));
    client.close();
}

fn parseStopReason(value: []const u8) ai_types.StopReason {
    return std.meta.stringToEnum(ai_types.StopReason, value) orelse .stop;
}

fn jsonValueToOwnedString(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var writer = json_writer.JsonWriter.init(&buffer, allocator);
    try writeJsonValue(&writer, value, allocator);
    return buffer.toOwnedSlice(allocator);
}

fn writeJsonValue(writer: *json_writer.JsonWriter, value: std.json.Value, allocator: std.mem.Allocator) !void {
    switch (value) {
        .null => try writer.writeNull(),
        .bool => |b| try writer.writeBool(b),
        .integer => |i| try writer.writeInt(i),
        .float => |f| {
            try writer.buffer.print(allocator, "{d}", .{f});
            writer.needs_comma = true;
        },
        .number_string => |s| {
            try writer.buffer.appendSlice(allocator, s);
            writer.needs_comma = true;
        },
        .string => |s| try writer.writeString(s),
        .array => |arr| {
            try writer.beginArray();
            for (arr.items) |item| try writeJsonValue(writer, item, allocator);
            try writer.endArray();
        },
        .object => |obj| {
            try writer.beginObject();
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                try writer.writeKey(entry.key_ptr.*);
                try writeJsonValue(writer, entry.value_ptr.*, allocator);
            }
            try writer.endObject();
        },
    }
}

fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn getJsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn getJsonU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

fn getJsonU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        else => null,
    };
}

fn getJsonArrayLenU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .array => |array| std.math.cast(u32, array.items.len),
        else => null,
    };
}

fn parseRemoteMessageRole(value: ?[]const u8) TuiEvent.MessageRole {
    const role = value orelse return .assistant;
    if (std.mem.eql(u8, role, "user")) return .user;
    if (std.mem.eql(u8, role, "tool") or std.mem.eql(u8, role, "tool_result")) return .tool_result;
    return .assistant;
}

fn parseRemotePromptSegmentKind(value: ?[]const u8) TuiEvent.PromptSegmentKind {
    const segment = value orelse return .message_history;
    if (std.mem.eql(u8, segment, "system_prompt")) return .system_prompt;
    if (std.mem.eql(u8, segment, "tool_definitions")) return .tool_definitions;
    return .message_history;
}

fn parseRemotePromptSegmentCacheRole(value: ?[]const u8) TuiEvent.PromptSegmentCacheRole {
    const role = value orelse return .dynamic;
    if (std.mem.eql(u8, role, "stable")) return .stable;
    return .dynamic;
}

fn sessionIdsEqual(a: agent_protocol_types.SessionId, b: agent_protocol_types.SessionId) bool {
    return std.mem.eql(u8, a[0..], b[0..]);
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
    try w.writeBoolField("requires_approval", tool.approval_fn != null);
    try w.endObject();
}

fn parseRemoteToolResultContentFromJson(allocator: std.mem.Allocator, result_json: []const u8) ![]ai_types.UserContentPart {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer parsed.deinit();
    return parseRemoteToolResultContent(allocator, parsed.value);
}

fn parseRemoteToolResultText(allocator: std.mem.Allocator, text: []const u8) ![]ai_types.UserContentPart {
    const parts = try allocator.alloc(ai_types.UserContentPart, 1);
    errdefer allocator.free(parts);
    parts[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return parts;
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
        const part = parseRemoteUserContentPart(allocator, item) catch |err| switch (err) {
            error.InvalidRemoteEvent => return parseRemoteToolResultJsonText(allocator, value),
            else => return err,
        };
        try parts.append(allocator, part);
    }
    return parts.toOwnedSlice(allocator);
}

fn parseRemoteToolResultJsonText(allocator: std.mem.Allocator, value: std.json.Value) ![]ai_types.UserContentPart {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    return parseRemoteToolResultText(allocator, json);
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

fn sessionQueueFollowUp(ctx: ?*anyopaque, text: []const u8) anyerror!void {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    try self.queueFollowUp(text);
}

fn sessionClearQueuedMessages(ctx: ?*anyopaque) void {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    self.clearQueuedMessages();
}

fn sessionQueuedCounts(ctx: ?*anyopaque) QueuedCounts {
    const self: *TuiRuntime = @ptrCast(@alignCast(ctx.?));
    return self.queuedCounts();
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
    saw_workspace_prompt: bool = false,
    wait_for_cancel: bool = false,
    flood_count: usize = 0,
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
    try std.testing.expectEqual(@as(usize, 0), runtime.remote_messages.items.len);
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

test "runtime queues steering and follow-up messages" {
    var mock = MockProtocolCtx{ .tool_first = true, .wait_after_tool_first = true };
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = true });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("first");
    try tui_session.steer("steer now");
    try tui_session.queueFollowUp("later");

    if (runtime.local_agent) |*local| local.waitForIdle();

    var user_messages: usize = 0;
    while (tui_session.waitEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .message_end => |payload| {
                if (payload.role == .user) user_messages += 1;
            },
            .agent_end => break,
            else => {},
        }
    }
    try std.testing.expect(user_messages >= 2);
    try std.testing.expectEqual(@as(usize, 3), mock.call_count);
    try std.testing.expectEqual(@as(usize, 0), tui_session.queuedCounts().total());
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

test "runtime active follow-up continues after plain assistant stop" {
    var mock = MockProtocolCtx{ .wait_before_text_first = true };
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models, .run_async = true });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.submitTurn("first");
    try tui_session.queueFollowUp("follow after response");

    if (runtime.local_agent) |*local| local.waitForIdle();

    try std.testing.expectEqual(@as(usize, 2), mock.call_count);
    try std.testing.expectEqual(@as(usize, 0), tui_session.queuedCounts().follow_up);

    var saw_follow_up_user = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .message_end => |payload| {
                if (payload.role == .user and std.mem.eql(u8, payload.text.slice(), "follow after response")) {
                    saw_follow_up_user = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_follow_up_user);
}

test "local runtime reports steering available" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    try std.testing.expect(runtime.canSteer());
    try std.testing.expect(runtime.createSession().canSteer());
}

test "remote runtime reports steering unavailable" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver() });
    defer runtime.deinit();
    try std.testing.expect(!runtime.canSteer());
    try std.testing.expect(!runtime.createSession().canSteer());
}

test "remote queue operations retain steering and follow-up messages" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver() });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.steer("now");
    try tui_session.queueFollowUp("later");
    const queued = tui_session.queuedCounts();
    try std.testing.expectEqual(@as(usize, 1), queued.steering);
    try std.testing.expectEqual(@as(usize, 1), queued.follow_up);
    tui_session.clearQueuedMessages();
    try std.testing.expectEqual(@as(usize, 0), tui_session.queuedCounts().total());
}

test "remote clear queued messages preserves active turn state" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .remote_session_timeout_ms = 1_000, .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = runtime.remote_pending_session_id.?,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = runtime.remote_pending_session_id.? } },
    });
    var history = try makeRemoteUserMessage(std.testing.allocator, "history");
    defer history.deinit(std.testing.allocator);
    try runtime.remote_messages.append(std.testing.allocator, try ai_types.cloneMessage(std.testing.allocator, history));
    try tui_session.submitTurn("current");
    try std.testing.expect(runtime.remote_turn_in_flight);
    try std.testing.expectEqual(@as(usize, 2), runtime.remote_echo_suppression_remaining);

    try tui_session.queueFollowUp("later");
    tui_session.clearQueuedMessages();
    try std.testing.expect(runtime.remote_turn_in_flight);
    try std.testing.expectEqual(@as(usize, 2), runtime.remote_echo_suppression_remaining);
    try std.testing.expectEqual(@as(usize, 0), tui_session.queuedCounts().total());
}

test "runtime clears queued messages before replacing messages" {
    var mock = MockProtocolCtx{};
    const models = [_]ai_types.Model{test_model_a};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .protocol = makeProtocol(&mock), .models = &models });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try tui_session.steer("steer now");
    try tui_session.queueFollowUp("later");
    try std.testing.expectEqual(@as(usize, 2), tui_session.queuedCounts().total());

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
        runtime.push(.turn_start);
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

    var runtime = try TuiRuntime.init(std.testing.allocator, .{
        .backend = .remote,
        .remote_sender = mock.sender(),
        .remote_receiver = mock.receiver(),
        .workspace_root = "/tmp/makai-workspace",
    });
    defer runtime.deinit();

    var tui_session = runtime.createSession();
    try tui_session.start();
    try std.testing.expectEqual(@as(usize, 1), mock.writes.items.len);

    var env = try agent_envelope.deserializeEnvelope(mock.writes.items[0], std.testing.allocator);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.payload == .agent_start);
    try std.testing.expect(std.mem.indexOf(u8, env.payload.agent_start.config_json, "\"workspace_root\":\"/tmp/makai-workspace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, env.payload.agent_start.system_prompt.slice(), "Default workspace root: /tmp/makai-workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, env.payload.agent_start.system_prompt.slice(), "`workspace_root`") != null);
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
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const sid = runtime.remote_pending_session_id.?;
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });

    var event_env = agent_protocol_types.Envelope{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = 0,
        .payload = .{ .agent_event = try std.testing.allocator.dupe(u8, "{\"type\":\"turn_start\"}") },
    };
    defer event_env.deinit(std.testing.allocator);
    try tui_session.submitTurn("hi");

    try mock.queueEnvelope(std.testing.allocator, event_env);
    _ = tui_session.streamEvents();

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

test "remote config initializes stdio transport hooks" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .remote_config = .{ .mode = .remote, .transport = .stdio } });
    defer runtime.deinit();
    try std.testing.expectEqual(TuiBackendMode.remote, runtime.backend);
    try std.testing.expect(runtime.remote_config_sender != null);
    try std.testing.expect(runtime.remote_config_receiver != null);
    try std.testing.expect(runtime.remote_config_stream_handle != null);
    try std.testing.expect(runtime.remote_sender != null);
    try std.testing.expect(runtime.remote_receiver != null);
    try std.testing.expectEqual(RemoteReadResult.pending, try runtime.remote_receiver.?.read(std.testing.allocator));
    try runtime.remote_config_stream_handle.?.stream.push(.{ .data = try std.testing.allocator.dupe(u8, "{\"type\":\"agent_started\"}"), .owned = true });
    const result = try runtime.remote_receiver.?.read(std.testing.allocator);
    switch (result) {
        .line => |line| {
            defer std.testing.allocator.free(line);
            try std.testing.expectEqualStrings("{\"type\":\"agent_started\"}", line);
        },
        else => return error.ExpectedRemoteLine,
    }
}

test "remote config stdio stop keeps handle reusable" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .remote_config = .{ .mode = .remote, .transport = .stdio } });
    defer runtime.deinit();
    runtime.remote_client = agent_protocol_client.AgentProtocolClient.init(std.testing.allocator);
    runtime.started = true;
    runtime.stop();
    try std.testing.expect(runtime.remote_config_stream_handle != null);
    try std.testing.expect(!runtime.remote_config_stream_handle.?.isCancelled());
}

test "remote config rejects unsupported endpoint" {
    try std.testing.expectError(error.UnsupportedRemoteEndpoint, TuiRuntime.init(std.testing.allocator, .{ .remote_config = .{ .mode = .remote, .transport = .stdio, .endpoint = "remote" } }));
}

test "remote config rejects unsupported transport" {
    try std.testing.expectError(error.UnsupportedRemoteTransport, TuiRuntime.init(std.testing.allocator, .{ .remote_config = .{ .mode = .remote, .transport = .websocket, .endpoint = "ws://localhost:1" } }));
}

test "remoteConfigFromConfig falls back to local for saved stdio" {
    var cfg = try tui_config.Config.defaults(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    cfg.remote.enabled = true;

    var rc = try remoteConfigFromConfig(std.testing.allocator, cfg);
    defer rc.deinit(std.testing.allocator);
    try std.testing.expectEqual(TuiRemoteTransport.stdio, rc.transport);
    try std.testing.expectEqual(TuiBackendMode.local, rc.mode);
}

test "remoteConfigFromConfig falls back to local for websocket" {
    var cfg = try tui_config.Config.defaults(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    cfg.remote.deinit(std.testing.allocator);
    cfg.remote.enabled = true;
    cfg.remote.transport = try std.testing.allocator.dupe(u8, "websocket");
    cfg.remote.endpoint = try std.testing.allocator.dupe(u8, "ws://localhost:1");

    var rc = try remoteConfigFromConfig(std.testing.allocator, cfg);
    defer rc.deinit(std.testing.allocator);
    try std.testing.expectEqual(TuiRemoteTransport.websocket, rc.transport);
    try std.testing.expectEqual(TuiBackendMode.local, rc.mode);
}

test "remoteConfigFromConfig falls back to local for invalid transport" {
    var cfg = try tui_config.Config.defaults(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    cfg.remote.deinit(std.testing.allocator);
    cfg.remote.enabled = true;
    cfg.remote.transport = try std.testing.allocator.dupe(u8, "stido");

    var rc = try remoteConfigFromConfig(std.testing.allocator, cfg);
    defer rc.deinit(std.testing.allocator);
    try std.testing.expectEqual(TuiRemoteTransport.stdio, rc.transport);
    try std.testing.expectEqual(TuiBackendMode.local, rc.mode);
}

test "remoteConfigFromConfig keeps valid saved sse remote" {
    var cfg = try tui_config.Config.defaults(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    cfg.remote.deinit(std.testing.allocator);
    cfg.remote.enabled = true;
    cfg.remote.transport = try std.testing.allocator.dupe(u8, "sse");
    cfg.remote.endpoint = try std.testing.allocator.dupe(u8, "http://localhost:8080/events");

    var rc = try remoteConfigFromConfig(std.testing.allocator, cfg);
    defer rc.deinit(std.testing.allocator);
    try std.testing.expectEqual(TuiRemoteTransport.sse, rc.transport);
    try std.testing.expectEqual(TuiBackendMode.remote, rc.mode);
}

test "remoteConfigFromConfig falls back to local for saved sse without endpoint" {
    var cfg = try tui_config.Config.defaults(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    cfg.remote.deinit(std.testing.allocator);
    cfg.remote.enabled = true;
    cfg.remote.transport = try std.testing.allocator.dupe(u8, "sse");

    var rc = try remoteConfigFromConfig(std.testing.allocator, cfg);
    defer rc.deinit(std.testing.allocator);
    try std.testing.expectEqual(TuiRemoteTransport.sse, rc.transport);
    try std.testing.expectEqual(TuiBackendMode.local, rc.mode);
}

test "remoteConfigFromConfig falls back to local for invalid saved sse endpoint" {
    var cfg = try tui_config.Config.defaults(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    cfg.remote.deinit(std.testing.allocator);
    cfg.remote.enabled = true;
    cfg.remote.transport = try std.testing.allocator.dupe(u8, "sse");
    cfg.remote.endpoint = try std.testing.allocator.dupe(u8, "http://localhost/events extra");

    var rc = try remoteConfigFromConfig(std.testing.allocator, cfg);
    defer rc.deinit(std.testing.allocator);
    try std.testing.expectEqual(TuiRemoteTransport.sse, rc.transport);
    try std.testing.expectEqual(TuiBackendMode.local, rc.mode);
}

test "remoteConfigFromConfig drops saved auth token with CRLF" {
    var cfg = try tui_config.Config.defaults(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    cfg.remote.deinit(std.testing.allocator);
    cfg.remote.enabled = true;
    cfg.remote.transport = try std.testing.allocator.dupe(u8, "sse");
    cfg.remote.endpoint = try std.testing.allocator.dupe(u8, "http://localhost:8080/events");
    cfg.remote.auth_token = try std.testing.allocator.dupe(u8, "secret\r\nInjected: yes");

    var rc = try remoteConfigFromConfig(std.testing.allocator, cfg);
    defer rc.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), rc.auth_headers.len);
}

test "remoteConfigFromConfig drops invalid saved custom auth header" {
    var cfg = try tui_config.Config.defaults(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    cfg.remote.deinit(std.testing.allocator);
    cfg.remote.enabled = true;
    cfg.remote.transport = try std.testing.allocator.dupe(u8, "sse");
    cfg.remote.endpoint = try std.testing.allocator.dupe(u8, "http://localhost:8080/events");
    cfg.remote.auth_header_name = try std.testing.allocator.dupe(u8, "Bad:Name");
    cfg.remote.auth_header_value = try std.testing.allocator.dupe(u8, "value");

    var rc = try remoteConfigFromConfig(std.testing.allocator, cfg);
    defer rc.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), rc.auth_headers.len);
}

test "remoteConfigFromConfig drops saved custom auth header with CRLF" {
    var cfg = try tui_config.Config.defaults(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    cfg.remote.deinit(std.testing.allocator);
    cfg.remote.enabled = true;
    cfg.remote.transport = try std.testing.allocator.dupe(u8, "sse");
    cfg.remote.endpoint = try std.testing.allocator.dupe(u8, "http://localhost:8080/events");
    cfg.remote.auth_header_name = try std.testing.allocator.dupe(u8, "X-Api-Key");
    cfg.remote.auth_header_value = try std.testing.allocator.dupe(u8, "value\r\nInjected: yes");

    var rc = try remoteConfigFromConfig(std.testing.allocator, cfg);
    defer rc.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), rc.auth_headers.len);
}

test "remoteConfigFromConfig skips empty allocations" {
    var cfg = try tui_config.Config.defaults(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);

    var rc = try remoteConfigFromConfig(std.testing.allocator, cfg);
    defer rc.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", rc.endpoint);
    try std.testing.expectEqualStrings("", rc.command);
    try std.testing.expectEqualStrings("", rc.auth_token);
    try std.testing.expectEqual(@as(usize, 0), rc.auth_headers.len);
}

test "default TuiRemoteConfig deinit is safe" {
    var rc: TuiRemoteConfig = .{};
    rc.deinit(std.testing.allocator);
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
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .remote_session_timeout_ms = 1_000, .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const sid = runtime.remote_pending_session_id.?;
    try mock.queuePending(3);
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    try tui_session.submitTurn("hi");
    try std.testing.expectEqualSlices(u8, sid[0..], runtime.remote_session_id.?[0..]);
    try std.testing.expect(mock.writes.items.len >= 2);
}

test "remote submit sends current thinking level in message options" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .remote_session_timeout_ms = 1_000, .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const sid = runtime.remote_pending_session_id.?;
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });

    runtime.setThinkingLevel(.high);
    try tui_session.submitTurn("hi");
    try std.testing.expect(mock.writes.items.len >= 2);

    var env = try agent_envelope.deserializeEnvelope(mock.writes.items[1], std.testing.allocator);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.payload == .agent_message);
    try std.testing.expect(std.mem.indexOf(u8, env.payload.agent_message.options_json.slice(), "\"thinking_level\":\"high\"") != null);
}

test "remote submit uses configurable startup timeout" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .remote_session_timeout_ms = 1, .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try std.testing.expectError(error.RemoteAgentStartFailed, tui_session.submitTurn("hi"));
    try std.testing.expect(runtime.remote_pending_session_id == null);
    const writes_after_first_timeout = mock.writes.items.len;
    try std.testing.expectError(error.RemoteAgentStartFailed, tui_session.submitTurn("retry"));
    try std.testing.expect(mock.writes.items.len > writes_after_first_timeout);
}

test "remote startup error for pending session emits terminal error" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .remote_session_timeout_ms = 1_000, .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const sid = runtime.remote_pending_session_id.?;
    var err_env = agent_protocol_types.Envelope{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_error = .{ .code = .internal_error, .message = try std.testing.allocator.dupe(u8, "startup failed") } },
    };
    defer err_env.deinit(std.testing.allocator);
    try mock.queueEnvelope(std.testing.allocator, err_env);
    try std.testing.expectError(error.RemoteAgentStartFailed, tui_session.submitTurn("hi"));
    try std.testing.expect(runtime.event_stream.isDone());
    var saw_error = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        if (ev == .@"error" and std.mem.eql(u8, ev.@"error".message.slice(), "startup failed")) saw_error = true;
    }
    try std.testing.expect(saw_error);
}

test "remote submit rejects missing model before send" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver() });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const sid = runtime.remote_pending_session_id.?;
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    const writes_before = mock.writes.items.len;
    try std.testing.expectError(error.NoModelConfigured, tui_session.submitTurn("hi"));
    try std.testing.expectEqual(writes_before, mock.writes.items.len);
}

test "remote submit failure rolls back appended user once" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const sid = runtime.remote_pending_session_id.?;
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    runtime.remote_client.?.sender = null;
    try std.testing.expectError(error.NoSender, tui_session.submitTurn("hi"));
    try std.testing.expectEqual(@as(usize, 0), runtime.remote_messages.items.len);
    try std.testing.expect(!runtime.stream_active);
    try std.testing.expect(!runtime.remote_turn_in_flight);
    try runtime.replaceMessages(&.{});
    try std.testing.expectError(error.NoSender, tui_session.submitTurn("retry"));
}

test "remote replaceMessages replaces serialized remote context" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();

    var messages = [_]ai_types.Message{try makeRemoteUserMessage(std.testing.allocator, "kept")};
    defer messages[0].deinit(std.testing.allocator);
    try runtime.replaceMessages(&messages);
    const sid = runtime.remote_pending_session_id.?;
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    try tui_session.submitTurn("next");

    var env = try agent_envelope.deserializeEnvelope(mock.writes.items[mock.writes.items.len - 1], std.testing.allocator);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.payload == .agent_message);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, env.payload.agent_message.message_json, .{});
    defer parsed.deinit();
    const sent = parsed.value.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 2), sent.items.len);
    try std.testing.expectEqualStrings("kept", sent.items[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("next", sent.items[1].object.get("content").?.string);
}

test "remote resume sends existing context when last message is user" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();

    var messages = [_]ai_types.Message{try makeRemoteUserMessage(std.testing.allocator, "retry me")};
    defer messages[0].deinit(std.testing.allocator);
    try runtime.replaceMessages(&messages);
    const sid = runtime.remote_pending_session_id.?;
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    try runtime.resumeSession();

    var env = try agent_envelope.deserializeEnvelope(mock.writes.items[mock.writes.items.len - 1], std.testing.allocator);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.payload == .agent_message);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, env.payload.agent_message.message_json, .{});
    defer parsed.deinit();
    const sent = parsed.value.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 1), sent.items.len);
    try std.testing.expectEqualStrings("retry me", sent.items[0].object.get("content").?.string);
}

test "remote resume rejects assistant tail without queued work" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();

    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "answer" } }};
    var assistant_msg = try makeAssistantMessage(std.testing.allocator, test_model_a, &content, .stop);
    defer assistant_msg.deinit(std.testing.allocator);
    var messages = [_]ai_types.Message{.{ .assistant = assistant_msg }};
    try runtime.replaceMessages(&messages);
    try std.testing.expectError(error.CannotContinueFromAssistant, runtime.resumeSession());
}

test "remote resume drains one steering before follow-up after assistant" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();

    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "answer" } }};
    var assistant_msg = try makeAssistantMessage(std.testing.allocator, test_model_a, &content, .stop);
    defer assistant_msg.deinit(std.testing.allocator);
    var messages = [_]ai_types.Message{.{ .assistant = assistant_msg }};
    try runtime.replaceMessages(&messages);
    const sid = runtime.remote_pending_session_id.?;
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    try tui_session.steer("steer now");
    try tui_session.steer("steer after");
    try tui_session.queueFollowUp("later");
    try runtime.resumeSession();

    var env = try agent_envelope.deserializeEnvelope(mock.writes.items[mock.writes.items.len - 1], std.testing.allocator);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.payload == .agent_message);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, env.payload.agent_message.message_json, .{});
    defer parsed.deinit();
    const sent = parsed.value.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 2), sent.items.len);
    try std.testing.expectEqualStrings("assistant", sent.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("steer now", sent.items[1].object.get("content").?.string);
    const queued = tui_session.queuedCounts();
    try std.testing.expectEqual(@as(usize, 1), queued.steering);
    try std.testing.expectEqual(@as(usize, 1), queued.follow_up);
}

test "remote agent_end auto-dispatches one queued follow-up" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const sid = runtime.remote_pending_session_id.?;
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    try tui_session.submitTurn("first");
    try tui_session.queueFollowUp("next");
    try tui_session.queueFollowUp("after");

    const done_json = try std.testing.allocator.dupe(u8, "{\"type\":\"message_update\",\"event\":{\"type\":\"done\",\"reason\":\"stop\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"answer\"}],\"api\":\"test-api\",\"provider\":\"test-provider\",\"model\":\"model-a\",\"usage\":{},\"stop_reason\":\"stop\",\"timestamp\":1}}}");
    defer std.testing.allocator.free(done_json);
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = 0,
        .payload = .{ .agent_event = done_json },
    });
    const turn_end_json = try std.testing.allocator.dupe(u8, "{\"type\":\"turn_end\",\"stop_reason\":\"stop\"}");
    defer std.testing.allocator.free(turn_end_json);
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 3,
        .timestamp = 0,
        .payload = .{ .agent_event = turn_end_json },
    });
    const agent_end_json = try std.testing.allocator.dupe(u8, "{\"type\":\"agent_end\"}");
    defer std.testing.allocator.free(agent_end_json);
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 4,
        .timestamp = 0,
        .payload = .{ .agent_event = agent_end_json },
    });

    _ = tui_session.streamEvents();
    var saw_agent_end = false;
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        if (ev == .agent_end) saw_agent_end = true;
    }
    try std.testing.expect(saw_agent_end);
    try std.testing.expectEqual(@as(usize, 2), mock.writes.items.len);
    const result_json = try std.testing.allocator.dupe(u8, "{\"ok\":true}");
    defer std.testing.allocator.free(result_json);
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 5,
        .timestamp = 0,
        .payload = .{ .agent_result = result_json },
    });
    _ = tui_session.streamEvents();
    var env = try agent_envelope.deserializeEnvelope(mock.writes.items[mock.writes.items.len - 1], std.testing.allocator);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.payload == .agent_message);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, env.payload.agent_message.message_json, .{});
    defer parsed.deinit();
    const sent = parsed.value.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 3), sent.items.len);
    try std.testing.expectEqualStrings("first", sent.items[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("assistant", sent.items[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("next", sent.items[2].object.get("content").?.string);
    const queued_after = tui_session.queuedCounts();
    try std.testing.expectEqual(@as(usize, 0), queued_after.steering);
    try std.testing.expectEqual(@as(usize, 1), queued_after.follow_up);
}

test "remote stream_events keeps pumping pending events" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const sid = runtime.remote_pending_session_id.?;
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
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

    while (tui_session.popEvent()) |event| {
        var mutable = event;
        defer mutable.deinit(std.testing.allocator);
        if (mutable == .turn_start) return;
    }
    return error.NoRemoteEvent;
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
    try std.testing.expect(runtime.remote_pending_session_id == null);
    try std.testing.expectEqual(@as(usize, 3), mock.writes.items.len);
    var restart_env = try agent_envelope.deserializeEnvelope(mock.writes.items[2], std.testing.allocator);
    defer restart_env.deinit(std.testing.allocator);
    try std.testing.expect(restart_env.payload == .agent_start);
    try std.testing.expect(!std.mem.eql(u8, sid1[0..], restart_env.session_id[0..]));
}

test "remote cancel clears in-flight turn before replaceMessages" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .remote_session_timeout_ms = 1_000, .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = runtime.remote_pending_session_id.?,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = runtime.remote_pending_session_id.? } },
    });
    try tui_session.submitTurn("running");
    try std.testing.expect(runtime.remote_turn_in_flight);

    tui_session.cancel();
    try std.testing.expect(!runtime.remote_turn_in_flight);
    try runtime.replaceMessages(&.{});
}

test "remote manual submit waits for terminal result after agent_end" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .remote_session_timeout_ms = 1_000, .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = runtime.remote_pending_session_id.?,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = runtime.remote_pending_session_id.? } },
    });
    try tui_session.submitTurn("running");

    const sid = runtime.remote_session_id.?;
    const agent_end_json = try std.testing.allocator.dupe(u8, "{\"type\":\"agent_end\"}");
    defer std.testing.allocator.free(agent_end_json);
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = 0,
        .payload = .{ .agent_event = agent_end_json },
    });
    _ = tui_session.streamEvents();
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
    }
    try std.testing.expect(runtime.event_stream.isDone());
    try std.testing.expect(runtime.remote_turn_in_flight);
    try std.testing.expectError(error.AgentAlreadyStreaming, tui_session.submitTurn("too soon"));
    try std.testing.expectEqual(@as(usize, 1), runtime.remote_messages.items.len);

    const result_json = try std.testing.allocator.dupe(u8, "{\"type\":\"result\",\"content\":[],\"usage\":{},\"stop_reason\":\"stop\",\"model\":\"model-a\",\"api\":\"test-api\",\"provider\":\"test-provider\",\"timestamp\":0}");
    defer std.testing.allocator.free(result_json);
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 3,
        .timestamp = 0,
        .payload = .{ .agent_result = result_json },
    });
    _ = tui_session.streamEvents();
    try std.testing.expect(!runtime.remote_turn_in_flight);
}

test "remote pumps terminal result without queued work" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .remote_session_timeout_ms = 1_000, .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = runtime.remote_pending_session_id.?,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = runtime.remote_pending_session_id.? } },
    });
    try tui_session.submitTurn("running");

    const sid = runtime.remote_session_id.?;
    const agent_end_json = try std.testing.allocator.dupe(u8, "{\"type\":\"agent_end\"}");
    defer std.testing.allocator.free(agent_end_json);
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = 0,
        .payload = .{ .agent_event = agent_end_json },
    });
    _ = tui_session.streamEvents();
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
    }
    try std.testing.expect(runtime.remote_turn_in_flight);

    const result_json = try std.testing.allocator.dupe(u8, "{\"type\":\"result\",\"content\":[],\"usage\":{},\"stop_reason\":\"stop\",\"model\":\"model-a\",\"api\":\"test-api\",\"provider\":\"test-provider\",\"timestamp\":0}");
    defer std.testing.allocator.free(result_json);
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 3,
        .timestamp = 0,
        .payload = .{ .agent_result = result_json },
    });
    _ = tui_session.streamEvents();
    try std.testing.expect(!runtime.remote_turn_in_flight);
    try runtime.replaceMessages(&.{});
}

test "remote ignores non-result agent_result payloads" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .remote_session_timeout_ms = 1_000, .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = runtime.remote_pending_session_id.?,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = runtime.remote_pending_session_id.? } },
    });
    try tui_session.submitTurn("running");

    const result_json = try std.testing.allocator.dupe(u8, "{\"type\":\"ack\",\"acknowledged_id\":\"msg\"}");
    defer std.testing.allocator.free(result_json);
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = runtime.remote_session_id.?,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = 0,
        .payload = .{ .agent_result = result_json },
    });
    _ = tui_session.streamEvents();
    try std.testing.expect(!runtime.remote_turn_in_flight);
    try std.testing.expectEqual(@as(usize, 1), runtime.remote_messages.items.len);
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

test "remote ignores unexpected agent_started while new session pending" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a}, .remote_session_timeout_ms = 1 });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const first_sid = runtime.remote_pending_session_id.?;
    tui_session.cancel();
    try std.testing.expectError(error.RemoteAgentStartFailed, tui_session.submitTurn("after cancel"));
    const second_start = try agent_envelope.deserializeEnvelope(mock.writes.items[2], std.testing.allocator);
    const second_sid = second_start.session_id;
    var second_start_mut = second_start;
    defer second_start_mut.deinit(std.testing.allocator);

    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = first_sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = first_sid } },
    });
    _ = tui_session.streamEvents();
    try std.testing.expect(runtime.remote_session_id == null);
    try std.testing.expect(runtime.remote_pending_session_id == null);
    try std.testing.expect(runtime.remote_client.?.session_id == null);

    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = second_sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = second_sid } },
    });
    _ = tui_session.streamEvents();
    try std.testing.expect(runtime.remote_session_id == null);
}

test "remote error emits terminal event once" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver() });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const sid = runtime.remote_pending_session_id.?;
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    try runtime.ensureRemoteSession();

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
    try std.testing.expectEqualSlices(u8, sid[0..], runtime.remote_session_id.?[0..]);
}

test "remote submit rejects while previous turn active" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const sid = runtime.remote_pending_session_id.?;
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    try tui_session.submitTurn("first");
    const writes_before = mock.writes.items.len;
    try std.testing.expectError(error.AgentAlreadyStreaming, tui_session.submitTurn("second"));
    try std.testing.expectEqual(writes_before, mock.writes.items.len);
}

test "remote submit persists tail prompt while suppressing prompt echoes" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .remote_session_timeout_ms = 1_000, .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = runtime.remote_pending_session_id.?,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = runtime.remote_pending_session_id.? } },
    });
    var history = try makeRemoteUserMessage(std.testing.allocator, "history");
    defer history.deinit(std.testing.allocator);
    try runtime.remote_messages.append(std.testing.allocator, try ai_types.cloneMessage(std.testing.allocator, history));

    try tui_session.submitTurn("current");
    const persisted = tui_session.popEvent() orelse return error.NoRemoteEvent;
    var ev = persisted;
    defer ev.deinit(std.testing.allocator);
    try std.testing.expect(ev == .message_end);
    try std.testing.expectEqual(TuiEvent.MessageRole.user, ev.message_end.role);
    try std.testing.expectEqualStrings("current", ev.message_end.text.slice());
    try std.testing.expectEqual(@as(usize, 2), runtime.remote_echo_suppression_remaining);

    try runtime.handleRemoteAgentEventJson("{\"type\":\"message_end\"}");
    try runtime.handleRemoteAgentEventJson("{\"type\":\"message_end\"}");
    try std.testing.expectEqual(@as(usize, 0), runtime.remote_echo_suppression_remaining);
    try std.testing.expect(tui_session.popEvent() == null);
}

test "remote submit persists first prompt while suppressing echo" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .remote_session_timeout_ms = 1_000, .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = runtime.remote_pending_session_id.?,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = runtime.remote_pending_session_id.? } },
    });

    try tui_session.submitTurn("first");
    const persisted = tui_session.popEvent() orelse return error.NoRemoteEvent;
    var ev = persisted;
    defer ev.deinit(std.testing.allocator);
    try std.testing.expect(ev == .message_end);
    try std.testing.expectEqual(TuiEvent.MessageRole.user, ev.message_end.role);
    try std.testing.expectEqualStrings("first", ev.message_end.text.slice());
    try std.testing.expectEqual(@as(usize, 1), runtime.remote_echo_suppression_remaining);

    try runtime.handleRemoteAgentEventJson("{\"type\":\"message_end\"}");
    try std.testing.expectEqual(@as(usize, 0), runtime.remote_echo_suppression_remaining);
    try std.testing.expect(tui_session.popEvent() == null);
}

test "remote resume does not re-emit saved user tail" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .remote_session_timeout_ms = 1_000, .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = runtime.remote_pending_session_id.?,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = runtime.remote_pending_session_id.? } },
    });
    var history = try makeRemoteUserMessage(std.testing.allocator, "history");
    defer history.deinit(std.testing.allocator);
    var tail = try makeRemoteUserMessage(std.testing.allocator, "tail");
    defer tail.deinit(std.testing.allocator);
    try runtime.remote_messages.append(std.testing.allocator, try ai_types.cloneMessage(std.testing.allocator, history));
    try runtime.remote_messages.append(std.testing.allocator, try ai_types.cloneMessage(std.testing.allocator, tail));

    try tui_session.resumeSession();
    try std.testing.expect(tui_session.popEvent() == null);
}

test "remote rejected submit does not emit tail prompt" {
    var mock = RemoteMock.init();
    defer mock.deinit(std.testing.allocator);
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .remote_session_timeout_ms = 1_000, .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const pending_sid = runtime.remote_pending_session_id.?;
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = pending_sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = pending_sid } },
    });
    try runtime.ensureRemoteSession();
    const sid = runtime.remote_session_id.?;
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = 0,
        .payload = .{ .agent_error = .{ .code = .agent_busy, .message = "busy" } },
    });

    try std.testing.expectError(error.RemoteMessageRejected, tui_session.submitTurn("rejected"));
    try std.testing.expectEqual(@as(usize, 0), runtime.remote_messages.items.len);
    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        try std.testing.expect(ev != .message_end);
    }
}

test "remote done event records assistant history for next turn" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote });
    defer runtime.deinit();
    try runtime.handleRemoteAgentEventJson("{\"type\":\"message_update\",\"event\":{\"type\":\"done\",\"reason\":\"stop\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"answer\"}],\"api\":\"test-api\",\"provider\":\"test-provider\",\"model\":\"model-a\",\"usage\":{},\"stop_reason\":\"stop\",\"timestamp\":1}}}");
    try std.testing.expectEqual(@as(usize, 1), runtime.remote_messages.items.len);
    try std.testing.expect(runtime.remote_messages.items[0] == .assistant);
    try std.testing.expectEqualStrings("answer", runtime.remote_messages.items[0].assistant.content[0].text.text);
    const provider_ev = runtime.event_stream.poll() orelse return error.NoRemoteEvent;
    var mutable_provider = provider_ev;
    defer mutable_provider.deinit(std.testing.allocator);
    try std.testing.expect(mutable_provider == .provider_event);
    try std.testing.expect(std.mem.indexOf(u8, mutable_provider.provider_event.event_json.slice(), "\"type\":\"done\"") != null);
    const ev = runtime.event_stream.poll() orelse return error.NoRemoteEvent;
    var mutable = ev;
    defer mutable.deinit(std.testing.allocator);
    try std.testing.expect(mutable == .message_end);
    try std.testing.expectEqualStrings("answer", mutable.message_end.text.slice());
    try std.testing.expectEqualStrings("[{\"type\":\"text\",\"text\":\"answer\"}]", mutable.message_end.content_json.slice());
}

test "remote inline message_end records assistant history for next turn" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote });
    defer runtime.deinit();
    try runtime.handleRemoteAgentEventJson("{\"type\":\"message_end\",\"message\":{\"type\":\"result\",\"content\":[{\"type\":\"text\",\"text\":\"answer\"}],\"api\":\"test-api\",\"provider\":\"test-provider\",\"model\":\"model-a\",\"input\":0,\"output\":0,\"cache_read\":0,\"cache_write\":0,\"stop_reason\":\"stop\",\"timestamp\":1}}");
    try std.testing.expectEqual(@as(usize, 1), runtime.remote_messages.items.len);
    try std.testing.expect(runtime.remote_messages.items[0] == .assistant);
    try std.testing.expectEqualStrings("answer", runtime.remote_messages.items[0].assistant.content[0].text.text);
    const ev = runtime.event_stream.poll() orelse return error.NoRemoteEvent;
    var mutable = ev;
    defer mutable.deinit(std.testing.allocator);
    try std.testing.expect(mutable == .message_end);
    try std.testing.expectEqualStrings("answer", mutable.message_end.text.slice());
    try std.testing.expectEqualStrings("[{\"type\":\"text\",\"text\":\"answer\"}]", mutable.message_end.content_json.slice());
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

test "remote tool execution end records content_json over details result" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote });
    defer runtime.deinit();
    try runtime.handleRemoteAgentEventJson("{\"type\":\"tool_execution_end\",\"tool_call_id\":\"call-1\",\"tool_name\":\"lookup\",\"result_json\":\"{\\\"ok\\\":true}\",\"content_json\":\"[{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"actual output\\\"}]\",\"is_error\":false}");
    try std.testing.expectEqual(@as(usize, 1), runtime.remote_messages.items.len);
    try std.testing.expect(runtime.remote_messages.items[0] == .tool_result);
    try std.testing.expectEqualStrings("actual output", runtime.remote_messages.items[0].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("{\"ok\":true}", runtime.remote_messages.items[0].tool_result.details_json.slice());
}

test "remote tool execution end accepts arbitrary JSON array history" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote });
    defer runtime.deinit();
    try runtime.handleRemoteAgentEventJson("{\"type\":\"tool_execution_end\",\"tool_call_id\":\"call-1\",\"tool_name\":\"lookup\",\"result_json\":\"[{\\\"id\\\":1,\\\"name\\\":\\\"a\\\"}]\",\"is_error\":false}");
    try std.testing.expectEqual(@as(usize, 1), runtime.remote_messages.items.len);
    try std.testing.expect(runtime.remote_messages.items[0] == .tool_result);
    try std.testing.expectEqualStrings("[{\"id\":1,\"name\":\"a\"}]", runtime.remote_messages.items[0].tool_result.content[0].text.text);
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

test "remote tool execution end records plain text result history" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote });
    defer runtime.deinit();
    try runtime.handleRemoteAgentEventJson("{\"type\":\"tool_execution_end\",\"tool_call_id\":\"call-1\",\"tool_name\":\"lookup\",\"result_json\":\"Tool skipped by policy\",\"is_error\":true}");
    try std.testing.expectEqual(@as(usize, 1), runtime.remote_messages.items.len);
    try std.testing.expect(runtime.remote_messages.items[0] == .tool_result);
    try std.testing.expectEqualStrings("Tool skipped by policy", runtime.remote_messages.items[0].tool_result.content[0].text.text);
    try std.testing.expect(runtime.remote_messages.items[0].tool_result.is_error);
}

test "remote tool execution end preserves telemetry fields" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote });
    defer runtime.deinit();
    try runtime.handleRemoteAgentEventJson("{\"type\":\"tool_execution_end\",\"tool_call_id\":\"call-1\",\"tool_name\":\"lookup\",\"result_json\":\"[]\",\"is_error\":false,\"raw_total_bytes\":4096,\"returned_total_bytes\":128,\"estimated_returned_tokens\":32,\"artifact_count\":2,\"artifacts\":[{\"artifact_id\":\"a1\",\"uri\":\"artifact://one\"},{\"artifact_id\":\"a2\"}]}");
    const ev = runtime.event_stream.poll() orelse return error.NoRemoteEvent;
    var mutable = ev;
    defer mutable.deinit(std.testing.allocator);
    try std.testing.expect(mutable == .tool_execution_end);
    try std.testing.expectEqual(@as(u64, 4096), mutable.tool_execution_end.raw_total_bytes);
    try std.testing.expectEqual(@as(u64, 128), mutable.tool_execution_end.returned_total_bytes);
    try std.testing.expectEqual(@as(u64, 32), mutable.tool_execution_end.estimated_returned_tokens);
    try std.testing.expectEqual(@as(u32, 2), mutable.tool_execution_end.artifact_count);
    try std.testing.expectEqualStrings("artifact://one, a2", mutable.tool_execution_end.artifact_refs.slice());
}

test "remote usage events map into TUI stream" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote });
    defer runtime.deinit();
    try runtime.handleRemoteAgentEventJson("{\"type\":\"context_usage\",\"system_prompt_bytes\":10,\"message_bytes\":20,\"tool_definition_bytes\":30,\"total_bytes\":60,\"estimated_tokens\":15,\"message_count\":2,\"tool_count\":1}");
    try runtime.handleRemoteAgentEventJson("{\"type\":\"prompt_segment_usage\",\"segment\":\"tool_definitions\",\"cache_role\":\"stable\",\"bytes\":30,\"estimated_tokens\":8,\"item_count\":1}");
    const usage_ev = runtime.event_stream.poll() orelse return error.NoRemoteEvent;
    try std.testing.expect(usage_ev == .context_usage);
    try std.testing.expectEqual(@as(u64, 60), usage_ev.context_usage.total_bytes);
    const segment_ev = runtime.event_stream.poll() orelse return error.NoRemoteEvent;
    try std.testing.expect(segment_ev == .prompt_segment_usage);
    try std.testing.expectEqual(TuiEvent.PromptSegmentKind.tool_definitions, segment_ev.prompt_segment_usage.segment);
    try std.testing.expectEqual(TuiEvent.PromptSegmentCacheRole.stable, segment_ev.prompt_segment_usage.cache_role);
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
        .permission_mode = .ask,
    });
    defer runtime.deinit();
    const json = try makeRemoteMessageJson(std.testing.allocator, test_model_a, &.{}, runtime.remoteSerializableTools());
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requires_approval\":true") != null);
}

test "remote submit ignores approval UI marker in serialized tools" {
    var original_ctx = OriginalApprovalUiCtx{};
    const tools = [_]agent.AgentTool{.{
        .label = "Notify",
        .name = "notify_only",
        .description = "Notify only",
        .parameters_schema_json = "{}",
        .execute = demoTool,
        .approval_ui_ctx = &original_ctx,
        .approval_ui_fn = originalApprovalUiCallback,
    }};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{
        .backend = .remote,
        .tools = &tools,
    });
    defer runtime.deinit();
    const json = try makeRemoteMessageJson(std.testing.allocator, test_model_a, &.{}, runtime.remoteSerializableTools());
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requires_approval\":false") != null);
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
    const provider_ev = runtime.event_stream.poll() orelse return error.NoRemoteEvent;
    var mutable_provider = provider_ev;
    defer mutable_provider.deinit(std.testing.allocator);
    try std.testing.expect(mutable_provider == .provider_event);
    try std.testing.expect(std.mem.indexOf(u8, mutable_provider.provider_event.event_json.slice(), "\"type\":\"text_delta\"") != null);
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
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const sid = runtime.remote_pending_session_id.?;
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    try runtime.ensureRemoteSession();
    runtime.remote_turn_in_flight = true;
    const initial_writes = mock.writes.items.len;

    mock.disconnected = true;
    _ = tui_session.streamEvents();
    try std.testing.expect(runtime.remote_reconnect_attempted);
    try std.testing.expect(!runtime.remote_turn_in_flight);
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
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const sid = runtime.remote_pending_session_id.?;
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
    try tui_session.submitTurn("hi");
    try mock.queueInvalid();
    _ = tui_session.streamEvents();
    try std.testing.expect(runtime.event_stream.isDone());
    try std.testing.expect(!runtime.remote_turn_in_flight);
    try runtime.replaceMessages(&.{});

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
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .remote_sender = mock.sender(), .remote_receiver = mock.receiver(), .models = &[_]ai_types.Model{test_model_a} });
    defer runtime.deinit();
    var tui_session = runtime.createSession();
    try tui_session.start();
    const sid = runtime.remote_pending_session_id.?;
    try mock.queueEnvelope(std.testing.allocator, .{
        .session_id = sid,
        .message_id = agent_protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });
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

    while (tui_session.popEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        if (ev == .turn_start) return;
    }
    return error.NoRemoteEvent;
}

test "TuiRuntime terminal event emits warning after terminal eviction" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .models = &[_]ai_types.Model{test_model_a}, .run_async = false });
    defer runtime.deinit();

    for (0..TuiEventStream.usable_capacity) |_| {
        runtime.push(.turn_start);
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

    // Fill the ring buffer to capacity.
    var i: usize = 0;
    while (i < TuiEventStream.usable_capacity) : (i += 1) {
        runtime.push(.{ .text_delta = .{ .content_index = i, .delta = OwnedSlice(u8).initBorrowed("x") } });
    }
    try std.testing.expect(runtime.event_stream.isFull());

    // The next push must evict one queued event and count that eviction.
    runtime.push(.{ .text_delta = .{ .content_index = TuiEventStream.usable_capacity, .delta = OwnedSlice(u8).initBorrowed("after-full") } });
    try std.testing.expectEqual(@as(u64, 1), runtime.dropped_event_count);
    try std.testing.expect(runtime.backpressure_active.load(.acquire));

    // While backpressure is active, polling backpressureState reports active=true.
    const bp_active = runtime.backpressureState();
    try std.testing.expect(bp_active.active);
    try std.testing.expectEqual(@as(u64, 1), bp_active.dropped_count);

    // Make room so the warning and a subsequent event can both be emitted.
    for (0..2) |_| {
        var ev = runtime.event_stream.poll().?;
        defer ev.deinit(std.testing.allocator);
    }
    runtime.push(.{ .text_delta = .{ .content_index = 256, .delta = OwnedSlice(u8).initBorrowed("after") } });

    // Drain events via the session to consume the warning.
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

    // The status bar reads state via backpressureState(), which returns one
    // active frame after recovery before clearing the runtime flag.
    const bp_recovered = runtime.backpressureState();
    try std.testing.expect(bp_recovered.active);
    try std.testing.expectEqual(@as(u64, 1), bp_recovered.dropped_count);
    const bp_cleared = runtime.backpressureState();
    try std.testing.expect(!bp_cleared.active);
    try std.testing.expectEqual(@as(u64, 1), bp_cleared.dropped_count);
}

test "TuiRuntime replaceMessages clears stale backpressure counters" {
    var runtime = try TuiRuntime.init(std.testing.allocator, .{ .backend = .remote, .models = &[_]ai_types.Model{test_model_a}, .run_async = false });
    defer runtime.deinit();
    runtime.started = true;

    runtime.dropped_event_count = 9;
    runtime.dropped_since_warning = 2;
    runtime.backpressure_active.store(true, .release);

    try runtime.replaceMessages(&.{});

    const bp = runtime.backpressureState();
    try std.testing.expect(!bp.active);
    try std.testing.expectEqual(@as(u64, 0), bp.dropped_count);
}

fn remotePipeReadLine(ctx: *anyopaque, allocator: std.mem.Allocator) !?[]const u8 {
    const pipe: *in_process.SerializedPipe = @ptrCast(@alignCast(ctx));
    var recv = pipe.clientReceiver();
    return recv.readLine(allocator);
}

fn remotePipeReadResult(ctx: *anyopaque, allocator: std.mem.Allocator) !RemoteReadResult {
    return if (try remotePipeReadLine(ctx, allocator)) |line| .{ .line = line } else .pending;
}
