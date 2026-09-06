const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const register_builtins = @import("register_builtins");
const provider_protocol_server = @import("protocol_server");
const provider_protocol_runtime = @import("protocol_runtime");
const provider_protocol_envelope = @import("protocol_envelope");
const agent_protocol_server = @import("agent_server");
const agent_protocol_runtime = @import("agent_runtime");
const agent_protocol_envelope = @import("agent_envelope");
const auth_protocol_server = @import("auth_server");
const auth_protocol_runtime = @import("auth_runtime");
const auth_protocol_envelope = @import("auth_envelope");
const auth_cli = @import("auth_cli");
const oauth_storage = @import("oauth/storage");
const event_stream = @import("event_stream");
const agent_loop = @import("agent_loop");
const agent_bridge = @import("agent_bridge");
const transport = @import("transport");
const model_ref = @import("model_ref");
const json_writer = @import("json_writer");
const in_process = @import("transports/in_process");
const stdio = @import("stdio");
const tui_app = @import("tui_app");
const tui_model_catalog = @import("tui_model_catalog");

pub const VERSION = "0.0.1";

const ProviderProtocolServer = provider_protocol_server.ProtocolServer;
const ProviderProtocolRuntime = provider_protocol_runtime.ProviderProtocolRuntime;
const ProviderProtocolTypes = provider_protocol_envelope.protocol_types;
const AgentProtocolServer = agent_protocol_server.AgentProtocolServer;
const AgentProtocolRuntime = agent_protocol_runtime.AgentProtocolRuntime;
const AgentProtocolTypes = agent_protocol_envelope.protocol_types;
const AuthProtocolServer = auth_protocol_server.AuthProtocolServer;
const AuthProtocolRuntime = auth_protocol_runtime.AuthProtocolRuntime;
const AuthProtocolTypes = auth_protocol_envelope.protocol_types;
const READY_FRAME = "{\"type\":\"ready\",\"protocol_version\":\"1\"}\n";
const STDIO_PROTOCOL_VERSION = "1";
const STDIO_IDLE_SLEEP_NS = std.time.ns_per_ms;
const STDIO_THREAD_JOIN_TIMEOUT_MS: u64 = 5_000;

const TEST_AUTH_POLL_ITERS_SHORT: usize = 20; // ~20ms with STDIO_IDLE_SLEEP_NS.
const TEST_AUTH_POLL_ITERS_DEFAULT: usize = 600; // ~600ms with STDIO_IDLE_SLEEP_NS.
const TEST_AUTH_POLL_ITERS_FAILURE: usize = 200; // ~200ms with STDIO_IDLE_SLEEP_NS.
const TEST_AUTH_POLL_ITERS_POST_CANCEL: usize = 30; // ~30ms with STDIO_IDLE_SLEEP_NS.
const TEST_AGENT_POLL_ITERS_DEFAULT: usize = 2_000; // ~2s with STDIO_IDLE_SLEEP_NS.

fn normalizeKimiRegion(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "global") or std.ascii.eqlIgnoreCase(trimmed, "moonshot")) return "global";
    if (std.ascii.eqlIgnoreCase(trimmed, "china") or
        std.ascii.eqlIgnoreCase(trimmed, "cn") or
        std.ascii.eqlIgnoreCase(trimmed, "coding"))
    {
        return "china";
    }
    return null;
}

fn kimiRegionFromProviderData(provider_data: []const u8) []const u8 {
    if (std.mem.startsWith(u8, provider_data, "region:")) {
        return normalizeKimiRegion(provider_data["region:".len..]) orelse "china";
    }
    return "china";
}

fn loadStoredKimiRegion(allocator: std.mem.Allocator) ?[]const u8 {
    var storage = oauth_storage.AuthStorage.loadDefaultStoredOnly(allocator) catch return null;
    defer storage.deinit();
    const auth = storage.providers.get("kimi") orelse return null;
    return switch (auth) {
        .api_key => null,
        .oauth => |creds| if (creds.provider_data) |data| kimiRegionFromProviderData(data) else null,
    };
}

fn resolvePrintKimiRegion(allocator: std.mem.Allocator, use_storage_auth: bool) []const u8 {
    const region_env = compat.getEnvVarOwned(allocator, "KIMI_REGION") catch null;
    if (region_env) |env| {
        defer allocator.free(env);
        if (normalizeKimiRegion(env)) |region| return region;
    }
    if (use_storage_auth) {
        if (loadStoredKimiRegion(allocator)) |region| return region;
    }
    return "china";
}

const RuntimeErrorCode = enum {
    dispatch_error,
    unknown_envelope,
    runtime_error,
};

const AgentRunOptions = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    max_iterations: ?u32 = null,
    thinking_level: ai_types.ThinkingLevel = .low,
    has_explicit_thinking_level: bool = false,
    api_key: ?[]u8 = null,

    fn deinit(self: *AgentRunOptions, allocator: std.mem.Allocator) void {
        if (self.api_key) |key| allocator.free(key);
        self.api_key = null;
    }
};

const PreparedAgentRun = struct {
    model: ai_types.Model,
    prompts: []ai_types.Message,
    system_prompt: []u8,
    tools: []agent_loop.AgentTool,
    options: AgentRunOptions,

    fn deinit(self: *PreparedAgentRun, allocator: std.mem.Allocator) void {
        self.model.deinit(allocator);
        for (self.prompts) |*message| {
            message.deinit(allocator);
        }
        allocator.free(self.prompts);
        allocator.free(self.system_prompt);
        deinitAgentTools(allocator, self.tools);
        self.options.deinit(allocator);
        self.* = undefined;
    }

    fn disarm(self: *PreparedAgentRun) void {
        self.model.is_owned = false;
        self.prompts = &.{};
        self.system_prompt = &.{};
        self.tools = &.{};
        self.options.api_key = null;
    }
};

const StdioToolRequest = struct {
    session_id: AgentProtocolTypes.SessionId,
    tool_call_id: []u8,
    tool_name: []u8,
    args_json: []u8,

    fn deinit(self: *StdioToolRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.tool_name);
        allocator.free(self.args_json);
        self.* = undefined;
    }
};

const StdioToolKey = struct {
    session_id: AgentProtocolTypes.SessionId,
    tool_call_id: []u8,

    fn deinit(self: *StdioToolKey, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        self.* = undefined;
    }
};

const StdioToolResult = struct {
    session_id: AgentProtocolTypes.SessionId,
    tool_call_id: []u8,
    result_json: []u8,
    details_json: []u8,
    is_error: bool,

    fn deinit(self: *StdioToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.result_json);
        allocator.free(self.details_json);
        self.* = undefined;
    }
};

const StdioToolBridge = struct {
    mutex: std.atomic.Mutex = .unlocked,
    requests: std.ArrayList(StdioToolRequest) = .empty,
    in_flight: std.ArrayList(StdioToolKey) = .empty,
    results: std.ArrayList(StdioToolResult) = .empty,

    fn deinit(self: *StdioToolBridge, allocator: std.mem.Allocator) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        for (self.requests.items) |*request| request.deinit(allocator);
        self.requests.deinit(allocator);
        for (self.in_flight.items) |*key| key.deinit(allocator);
        self.in_flight.deinit(allocator);
        for (self.results.items) |*result| result.deinit(allocator);
        self.results.deinit(allocator);
        self.mutex.unlock();
        self.* = undefined;
    }

    fn enqueueRequest(
        self: *StdioToolBridge,
        allocator: std.mem.Allocator,
        session_id: AgentProtocolTypes.SessionId,
        tool_call_id: []const u8,
        tool_name: []const u8,
        args_json: []const u8,
    ) !void {
        const owned_tool_call_id = try allocator.dupe(u8, tool_call_id);
        errdefer allocator.free(owned_tool_call_id);
        const owned_tool_name = try allocator.dupe(u8, tool_name);
        errdefer allocator.free(owned_tool_name);
        const owned_args_json = try allocator.dupe(u8, args_json);
        errdefer allocator.free(owned_args_json);

        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        try self.requests.append(allocator, .{
            .session_id = session_id,
            .tool_call_id = owned_tool_call_id,
            .tool_name = owned_tool_name,
            .args_json = owned_args_json,
        });
    }

    fn markInFlight(self: *StdioToolBridge, allocator: std.mem.Allocator, session_id: AgentProtocolTypes.SessionId, tool_call_id: []const u8) !void {
        const owned_tool_call_id = try allocator.dupe(u8, tool_call_id);
        errdefer allocator.free(owned_tool_call_id);
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        try self.in_flight.append(allocator, .{
            .session_id = session_id,
            .tool_call_id = owned_tool_call_id,
        });
    }

    fn enqueueResult(self: *StdioToolBridge, allocator: std.mem.Allocator, result: StdioToolResult) !bool {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (!self.hasInFlightLocked(result.session_id, result.tool_call_id)) return false;
        if (self.hasResultLocked(result.session_id, result.tool_call_id)) return false;
        try self.results.append(allocator, result);
        return true;
    }

    fn popResult(self: *StdioToolBridge, allocator: std.mem.Allocator, session_id: AgentProtocolTypes.SessionId, tool_call_id: []const u8) ?StdioToolResult {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        for (self.results.items, 0..) |result, idx| {
            if (std.mem.eql(u8, &result.session_id, &session_id) and std.mem.eql(u8, result.tool_call_id, tool_call_id)) {
                self.removeInFlightLocked(allocator, session_id, tool_call_id);
                return self.results.orderedRemove(idx);
            }
        }
        return null;
    }

    fn discardInFlight(self: *StdioToolBridge, allocator: std.mem.Allocator, session_id: AgentProtocolTypes.SessionId, tool_call_id: []const u8) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        self.removeInFlightLocked(allocator, session_id, tool_call_id);
    }

    fn discardSession(self: *StdioToolBridge, allocator: std.mem.Allocator, session_id: AgentProtocolTypes.SessionId) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        var request_idx: usize = 0;
        while (request_idx < self.requests.items.len) {
            if (std.mem.eql(u8, &self.requests.items[request_idx].session_id, &session_id)) {
                var removed = self.requests.orderedRemove(request_idx);
                removed.deinit(allocator);
                continue;
            }
            request_idx += 1;
        }
        var in_flight_idx: usize = 0;
        while (in_flight_idx < self.in_flight.items.len) {
            if (std.mem.eql(u8, &self.in_flight.items[in_flight_idx].session_id, &session_id)) {
                var removed = self.in_flight.orderedRemove(in_flight_idx);
                removed.deinit(allocator);
                continue;
            }
            in_flight_idx += 1;
        }
        var result_idx: usize = 0;
        while (result_idx < self.results.items.len) {
            if (std.mem.eql(u8, &self.results.items[result_idx].session_id, &session_id)) {
                var removed = self.results.orderedRemove(result_idx);
                removed.deinit(allocator);
                continue;
            }
            result_idx += 1;
        }
    }

    fn hasInFlightLocked(self: *StdioToolBridge, session_id: AgentProtocolTypes.SessionId, tool_call_id: []const u8) bool {
        for (self.in_flight.items) |key| {
            if (std.mem.eql(u8, &key.session_id, &session_id) and std.mem.eql(u8, key.tool_call_id, tool_call_id)) return true;
        }
        return false;
    }

    fn hasResultLocked(self: *StdioToolBridge, session_id: AgentProtocolTypes.SessionId, tool_call_id: []const u8) bool {
        for (self.results.items) |result| {
            if (std.mem.eql(u8, &result.session_id, &session_id) and std.mem.eql(u8, result.tool_call_id, tool_call_id)) return true;
        }
        return false;
    }

    fn removeInFlightLocked(self: *StdioToolBridge, allocator: std.mem.Allocator, session_id: AgentProtocolTypes.SessionId, tool_call_id: []const u8) void {
        var idx: usize = 0;
        while (idx < self.in_flight.items.len) {
            if (std.mem.eql(u8, &self.in_flight.items[idx].session_id, &session_id) and std.mem.eql(u8, self.in_flight.items[idx].tool_call_id, tool_call_id)) {
                var removed = self.in_flight.orderedRemove(idx);
                removed.deinit(allocator);
                continue;
            }
            idx += 1;
        }
    }
};

const StdioAgentToolExecutor = struct {
    bridge: *StdioToolBridge,
    session_id: AgentProtocolTypes.SessionId,
};

const ActiveAgentRun = struct {
    session_id: AgentProtocolTypes.SessionId,
    stream: *agent_loop.AgentEventStream,
    context: *agent_loop.AgentContext,
    model: ai_types.Model,
    prompts: []ai_types.Message,
    tools: []agent_loop.AgentTool,
    cancel_flag: *std.atomic.Value(bool),
    tool_executor: *StdioAgentToolExecutor,
    terminal_event_json: ?[]u8 = null,

    fn cancel(self: *ActiveAgentRun) void {
        self.cancel_flag.store(true, .release);
    }

    fn deinit(self: *ActiveAgentRun, allocator: std.mem.Allocator) void {
        self.cancel();
        self.stream.deinit();
        allocator.destroy(self.stream);
        self.context.deinit();
        allocator.destroy(self.context);
        self.model.deinit(allocator);
        allocator.free(self.prompts);
        deinitAgentTools(allocator, self.tools);
        allocator.destroy(self.cancel_flag);
        allocator.destroy(self.tool_executor);
        if (self.terminal_event_json) |event_json| allocator.free(event_json);
        self.* = undefined;
    }
};

// NOTE: legacy auth-context globals (`g_auth_ctx`, `AuthContext`, OAuth-callback
// bridges, fixture/anthropic/github login helpers, `saveOAuthCredentials`) were
// removed in M-013 when the CLI auth commands were migrated to thin wrappers
// over the auth protocol runtime. The orchestration now lives in
// `src/tools/auth_cli.zig` (driving `AuthProtocolServer` in-process) and is
// shared with the `--stdio` mode below.

const StdioProtocolLoop = struct {
    allocator: std.mem.Allocator,
    registry: *api_registry.ApiRegistry,
    owns_registry: bool,
    provider_server: ProviderProtocolServer,
    provider_pipe: in_process.SerializedPipe,
    agent_server: AgentProtocolServer,
    agent_pipe: in_process.SerializedPipe,
    provider_bridge: agent_bridge.InProcessProviderProtocolBridge,
    active_agent_runs: std.ArrayList(ActiveAgentRun),
    tool_bridge: StdioToolBridge,
    auth_server: AuthProtocolServer,
    auth_pipe: in_process.SerializedPipe,

    const Self = @This();
    const DispatchTarget = enum { provider, agent, auth };

    fn initWithRegistry(
        allocator: std.mem.Allocator,
        registry: *api_registry.ApiRegistry,
        owns_registry: bool,
        auth_options: AuthProtocolServer.Options,
    ) Self {
        const self = Self{
            .allocator = allocator,
            .registry = registry,
            .owns_registry = owns_registry,
            .provider_server = ProviderProtocolServer.init(allocator, registry, .{}),
            .provider_pipe = in_process.createSerializedPipe(allocator),
            .agent_server = AgentProtocolServer.init(allocator),
            .agent_pipe = in_process.createSerializedPipe(allocator),
            .provider_bridge = agent_bridge.InProcessProviderProtocolBridge.init(registry),
            .active_agent_runs = std.ArrayList(ActiveAgentRun).empty,
            .tool_bridge = .{},
            .auth_server = AuthProtocolServer.init(allocator, auth_options),
            .auth_pipe = in_process.createSerializedPipe(allocator),
        };

        return self;
    }

    pub fn initWithBuiltins(allocator: std.mem.Allocator) !Self {
        const registry = try allocator.create(api_registry.ApiRegistry);
        errdefer allocator.destroy(registry);

        registry.* = api_registry.ApiRegistry.init(allocator);
        errdefer registry.deinit();

        try register_builtins.registerBuiltInApiProviders(registry);
        return initWithRegistry(allocator, registry, true, .{});
    }

    fn initForTesting(allocator: std.mem.Allocator, registry: *api_registry.ApiRegistry) Self {
        return initWithRegistry(allocator, registry, false, .{
            .persist_credentials = false,
            .enable_real_oauth = false,
        });
    }

    pub fn deinit(self: *Self) void {
        for (self.active_agent_runs.items) |*run| run.deinit(self.allocator);
        self.active_agent_runs.deinit(self.allocator);
        self.tool_bridge.deinit(self.allocator);
        self.provider_server.deinit();
        self.provider_pipe.deinit();
        self.agent_server.deinit();
        self.agent_pipe.deinit();
        self.auth_server.deinit();
        self.auth_pipe.deinit();

        if (self.owns_registry) {
            self.registry.deinit();
            self.allocator.destroy(self.registry);
        }

        self.* = undefined;
    }

    pub fn dispatchInboundLine(self: *Self, line: []const u8) !bool {
        const target = self.detectDispatchTarget(line) orelse return false;

        switch (target) {
            .provider => {
                var sender = self.provider_pipe.clientSender();
                try sender.write(line);
                try sender.flush();
                var runtime = ProviderProtocolRuntime{
                    .server = &self.provider_server,
                    .pipe = &self.provider_pipe,
                    .allocator = self.allocator,
                };
                try runtime.pumpClientMessages();
                _ = try runtime.pumpServerOutbox();
            },
            .agent => {
                if (!hasValidAgentEnvelopeShape(line, self.allocator)) return false;
                const tool_result = try parseStdioToolResultFromLine(line, self.allocator);
                if (tool_result) |result| {
                    var owned_result = result;
                    const queued = try self.tool_bridge.enqueueResult(self.allocator, owned_result);
                    if (!queued) owned_result.deinit(self.allocator);
                    return queued;
                }
                const stopped_session = validatedAgentStopSessionFromLine(line, self.allocator);
                const had_stop_session = if (stopped_session) |session_id|
                    self.agent_server.hasSession(session_id)
                else
                    false;
                var sender = self.agent_pipe.clientSender();
                try sender.write(line);
                try sender.flush();
                var runtime = AgentProtocolRuntime{
                    .server = &self.agent_server,
                    .pipe = &self.agent_pipe,
                    .allocator = self.allocator,
                };
                try runtime.pumpClientMessages();
                if (stopped_session) |session_id| {
                    if (had_stop_session and !self.agent_server.hasSession(session_id)) {
                        self.cancelAgentRun(session_id);
                    }
                }
            },
            .auth => {
                var sender = self.auth_pipe.clientSender();
                try sender.write(line);
                try sender.flush();
                var runtime = AuthProtocolRuntime{
                    .server = &self.auth_server,
                    .pipe = &self.auth_pipe,
                    .allocator = self.allocator,
                };
                try runtime.pumpClientMessages();
            },
        }

        return true;
    }

    pub fn pumpBackground(self: *Self) !usize {
        var forwarded: usize = 0;
        var provider_runtime = ProviderProtocolRuntime{
            .server = &self.provider_server,
            .pipe = &self.provider_pipe,
            .allocator = self.allocator,
        };
        forwarded += try provider_runtime.pumpServerOutbox();
        forwarded += try provider_runtime.pumpProviderEvents();
        self.provider_server.cleanupCompletedStreams();

        var agent_runtime = AgentProtocolRuntime{
            .server = &self.agent_server,
            .pipe = &self.agent_pipe,
            .allocator = self.allocator,
        };
        forwarded += try self.startPendingAgentRuns();
        forwarded += try self.pumpAgentRuns();
        forwarded += try self.publishPendingToolRequests();
        forwarded += try agent_runtime.pumpServerOutbox();

        var auth_runtime = AuthProtocolRuntime{
            .server = &self.auth_server,
            .pipe = &self.auth_pipe,
            .allocator = self.allocator,
        };
        forwarded += try auth_runtime.pumpServerOutbox();
        return forwarded;
    }

    pub fn drainOutbound(self: *Self, lines: *std.ArrayList([]const u8)) !usize {
        var drained: usize = 0;
        drained += try self.drainPipeOutbound(&self.provider_pipe, lines);
        drained += try self.drainPipeOutbound(&self.agent_pipe, lines);
        drained += try self.drainPipeOutbound(&self.auth_pipe, lines);
        return drained;
    }

    pub fn hasActiveProviderStreams(self: *Self) bool {
        return self.provider_server.activeStreamCount() > 0;
    }

    pub fn hasActiveAgentRuns(self: *Self) bool {
        return self.active_agent_runs.items.len > 0;
    }

    pub fn hasActiveAuthFlows(self: *Self) bool {
        return self.auth_server.activeFlowCount() > 0;
    }

    fn startPendingAgentRuns(self: *Self) !usize {
        var started: usize = 0;
        while (self.agent_server.popPendingAgentMessage()) |pending| {
            var owned_pending = pending;
            defer owned_pending.deinit(self.allocator);

            self.startAgentRun(owned_pending) catch |err| {
                if (err == error.OutOfMemory) return err;
                try self.publishAgentLoopError(owned_pending.session_id, @errorName(err));
                self.agent_server.markSessionError(owned_pending.session_id);
                continue;
            };
            started += 1;
        }
        return started;
    }

    fn startAgentRun(self: *Self, pending: agent_protocol_server.PendingAgentMessage) !void {
        if (self.findActiveAgentRun(pending.session_id) != null) return error.AgentBusy;

        var prepared = try prepareAgentRun(self.allocator, pending);
        errdefer prepared.deinit(self.allocator);

        self.agent_server.updateSessionModel(pending.session_id, prepared.model.id) catch {};

        const context = try self.allocator.create(agent_loop.AgentContext);
        var context_owned_by_run = false;
        errdefer if (!context_owned_by_run) self.allocator.destroy(context);
        context.* = agent_loop.AgentContext.init(self.allocator);
        errdefer if (!context_owned_by_run) context.deinit();
        context.system_prompt = ai_types.OwnedSlice(u8).initOwned(prepared.system_prompt);
        prepared.system_prompt = &.{};
        context.tools = prepared.tools;

        const cancel_flag = try self.allocator.create(std.atomic.Value(bool));
        var cancel_owned_by_run = false;
        errdefer if (!cancel_owned_by_run) self.allocator.destroy(cancel_flag);
        cancel_flag.* = std.atomic.Value(bool).init(false);

        const tool_executor = try self.allocator.create(StdioAgentToolExecutor);
        var tool_executor_owned_by_run = false;
        errdefer if (!tool_executor_owned_by_run) self.allocator.destroy(tool_executor);
        tool_executor.* = .{
            .bridge = &self.tool_bridge,
            .session_id = pending.session_id,
        };

        const session_id_text = try AgentProtocolTypes.sessionIdToString(pending.session_id, self.allocator);
        defer self.allocator.free(session_id_text);

        const config = agent_loop.AgentLoopConfig{
            .model = prepared.model,
            .protocol = (&self.provider_bridge).protocolClient(),
            .tools = prepared.tools,
            .execute_tool_via_protocol_fn = executeStdioToolViaAgentProtocol,
            .execute_tool_via_protocol_ctx = tool_executor,
            .temperature = prepared.options.temperature,
            .max_tokens = prepared.options.max_tokens,
            .max_iterations = prepared.options.max_iterations,
            .thinking_level = prepared.options.thinking_level,
            .session_id = session_id_text,
            .api_key = prepared.options.api_key,
            .cancel_token = .{ .cancelled = cancel_flag },
        };

        const stream = try agent_loop.agentLoop(self.allocator, prepared.prompts, context, config);
        var stream_owned_by_run = false;
        errdefer if (!stream_owned_by_run) {
            stream.deinit();
            self.allocator.destroy(stream);
        };

        var run = ActiveAgentRun{
            .session_id = pending.session_id,
            .stream = stream,
            .context = context,
            .model = prepared.model,
            .prompts = prepared.prompts,
            .tools = prepared.tools,
            .cancel_flag = cancel_flag,
            .tool_executor = tool_executor,
        };
        prepared.options.deinit(self.allocator);
        context_owned_by_run = true;
        cancel_owned_by_run = true;
        tool_executor_owned_by_run = true;
        stream_owned_by_run = true;
        prepared.disarm();

        var appended = false;
        errdefer if (!appended) run.deinit(self.allocator);
        try self.active_agent_runs.append(self.allocator, run);
        appended = true;
    }

    fn pumpAgentRuns(self: *Self) !usize {
        var forwarded: usize = 0;
        var idx: usize = 0;
        while (idx < self.active_agent_runs.items.len) {
            var run = &self.active_agent_runs.items[idx];

            if (!self.agent_server.hasSession(run.session_id)) {
                run.cancel();
            }

            while (run.stream.poll()) |event| {
                var owned_event = event;
                errdefer deinitSerializedStdioAgentEvent(self.allocator, &owned_event);

                if (std.meta.activeTag(event) == .agent_end) {
                    run.terminal_event_json = try serializeAgentLoopEvent(self.allocator, run.session_id, event);
                    deinitSerializedStdioAgentEvent(self.allocator, &owned_event);
                    continue;
                }

                const event_json = try serializeAgentLoopEvent(self.allocator, run.session_id, event);
                defer self.allocator.free(event_json);
                self.agent_server.publishAgentEvent(run.session_id, event_json) catch {};
                deinitSerializedStdioAgentEvent(self.allocator, &owned_event);
                forwarded += 1;
            }

            if (!run.stream.isDone()) {
                idx += 1;
                continue;
            }

            if (run.stream.getError()) |msg| {
                try self.publishAgentLoopError(run.session_id, msg);
                self.agent_server.markSessionError(run.session_id);
                forwarded += 1;
            } else if (run.stream.getResult()) |result| {
                // The SDK derives its terminal agent_end from this frame, so an
                // agent-level termination (iteration cap) must override the
                // final turn's own stop reason here as well.
                const result_reason: []const u8 = if (result.termination) |termination|
                    @tagName(termination)
                else
                    @tagName(result.final_message.stop_reason);
                const result_json = try transport.serializeResultWithStopReason(result.final_message, result_reason, self.allocator);
                defer self.allocator.free(result_json);
                self.agent_server.publishAgentResult(run.session_id, result_json) catch {};
                forwarded += 1;
            }

            if (run.terminal_event_json) |event_json| {
                self.agent_server.publishAgentEvent(run.session_id, event_json) catch {};
                self.allocator.free(event_json);
                run.terminal_event_json = null;
                forwarded += 1;
            }

            var removed = self.active_agent_runs.orderedRemove(idx);
            removed.deinit(self.allocator);
        }
        return forwarded;
    }

    fn findActiveAgentRun(self: *Self, session_id: AgentProtocolTypes.SessionId) ?usize {
        for (self.active_agent_runs.items, 0..) |run, idx| {
            if (std.mem.eql(u8, run.session_id[0..], session_id[0..])) return idx;
        }
        return null;
    }

    fn cancelAgentRun(self: *Self, session_id: AgentProtocolTypes.SessionId) void {
        if (self.findActiveAgentRun(session_id)) |idx| {
            self.active_agent_runs.items[idx].cancel();
        }
        self.tool_bridge.discardSession(self.allocator, session_id);
    }

    fn publishAgentLoopError(self: *Self, session_id: AgentProtocolTypes.SessionId, message: []const u8) !void {
        const event_json = try serializeAgentErrorEvent(self.allocator, message, "internal_error");
        defer self.allocator.free(event_json);
        self.agent_server.publishAgentEvent(session_id, event_json) catch |err| {
            if (err == error.OutOfMemory) return err;
        };
        self.agent_server.publishAgentError(session_id, .internal_error, message) catch |err| {
            if (err == error.OutOfMemory) return err;
        };
    }

    fn publishPendingToolRequests(self: *Self) !usize {
        var published: usize = 0;
        while (true) {
            while (!self.tool_bridge.mutex.tryLock()) std.atomic.spinLoopHint();
            const maybe_request = if (self.tool_bridge.requests.items.len > 0)
                self.tool_bridge.requests.orderedRemove(0)
            else
                null;
            self.tool_bridge.mutex.unlock();

            var request = maybe_request orelse break;
            defer request.deinit(self.allocator);
            if (!self.agent_server.hasSession(request.session_id)) continue;
            try self.tool_bridge.markInFlight(self.allocator, request.session_id, request.tool_call_id);
            errdefer self.tool_bridge.discardInFlight(self.allocator, request.session_id, request.tool_call_id);

            var env = AgentProtocolTypes.Envelope{
                .session_id = request.session_id,
                .message_id = AgentProtocolTypes.generateUlid(),
                .sequence = self.agent_server.nextOutgoingSequence(request.session_id),
                .timestamp = compat.time.nowMillis(),
                .payload = .{ .tool_execute = .{
                    .tool_call_id = try self.allocator.dupe(u8, request.tool_call_id),
                    .tool_name = try self.allocator.dupe(u8, request.tool_name),
                    .args_json = try self.allocator.dupe(u8, request.args_json),
                } },
            };
            errdefer env.deinit(self.allocator);
            try self.agent_server.enqueueEnvelope(env);
            published += 1;
        }
        return published;
    }

    fn detectDispatchTarget(self: *Self, line: []const u8) ?DispatchTarget {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch return null;
        defer parsed.deinit();

        if (parsed.value != .object) return null;
        const obj = parsed.value.object;

        const envelope_type = if (obj.get("type")) |value|
            if (value == .string) value.string else null
        else
            null;

        const stream_id = obj.get("stream_id");
        const session_id = obj.get("session_id");
        const has_stream_id = stream_id != null and stream_id.? == .string;
        const has_session_id = session_id != null and session_id.? == .string;

        if (has_stream_id and has_session_id) return null;
        if (has_stream_id) {
            // Auth and provider envelopes both use `stream_id`; refine by type first.
            if (envelope_type) |ty| {
                if (isAuthEnvelopeType(ty)) return .auth;
            }
            return .provider;
        }
        if (has_session_id) return .agent;
        return null;
    }

    fn isAuthEnvelopeType(envelope_type: []const u8) bool {
        return std.mem.eql(u8, envelope_type, "auth_providers_request") or
            std.mem.eql(u8, envelope_type, "auth_login_start") or
            std.mem.eql(u8, envelope_type, "auth_prompt_response") or
            std.mem.eql(u8, envelope_type, "auth_cancel");
    }

    fn drainPipeOutbound(
        self: *Self,
        pipe: *in_process.SerializedPipe,
        lines: *std.ArrayList([]const u8),
    ) !usize {
        var drained: usize = 0;
        var receiver = pipe.clientReceiver();
        while (try receiver.readLine(self.allocator)) |line| {
            try lines.append(self.allocator, line);
            drained += 1;
        }
        return drained;
    }
};

fn deinitSerializedStdioAgentEvent(allocator: std.mem.Allocator, event: *agent_loop.AgentEvent) void {
    event.deinit(allocator);
}

fn prepareAgentRun(
    allocator: std.mem.Allocator,
    pending: agent_protocol_server.PendingAgentMessage,
) !PreparedAgentRun {
    var message_parsed = try std.json.parseFromSlice(std.json.Value, allocator, pending.message_json, .{});
    defer message_parsed.deinit();
    if (message_parsed.value != .object) return error.InvalidAgentMessageJson;
    const message_obj = message_parsed.value.object;

    var config_parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (config_parsed) |*parsed| parsed.deinit();
    var config_obj: ?std.json.ObjectMap = null;
    if (pending.config_json.len > 0) {
        config_parsed = try std.json.parseFromSlice(std.json.Value, allocator, pending.config_json, .{});
        if (config_parsed.?.value == .object) {
            config_obj = config_parsed.?.value.object;
        }
    }

    const model_ref_text = getStringField(message_obj, "model_ref") orelse blk: {
        if (config_obj) |obj| break :blk getStringField(obj, "model_ref");
        break :blk null;
    } orelse return error.MissingModelRef;

    var model = try modelFromCanonicalRef(allocator, model_ref_text);
    errdefer model.deinit(allocator);

    var system_prompt_builder = std.ArrayList(u8).empty;
    defer system_prompt_builder.deinit(allocator);
    if (pending.system_prompt.len > 0) {
        try appendSystemPromptText(&system_prompt_builder, allocator, pending.system_prompt);
    }

    const messages_value = message_obj.get("messages") orelse return error.MissingMessages;
    const prompts = try parseAgentMessages(allocator, messages_value, &system_prompt_builder);
    errdefer {
        for (prompts) |*message| message.deinit(allocator);
        allocator.free(prompts);
    }

    const tools = try parseAgentTools(allocator, message_obj, config_obj);
    errdefer deinitAgentTools(allocator, tools);

    const system_prompt = try allocator.dupe(u8, system_prompt_builder.items);
    errdefer allocator.free(system_prompt);

    var options = try parseAgentRunOptions(allocator, message_obj, config_obj, pending.options_json);
    // GPT-5 Pro only supports the `high` reasoning effort (bundled OpenAI
    // spec, docs/openai/responses.md): normalize every request, not just
    // requests without an explicit level, since other values are rejected
    // by the API.
    if (std.mem.eql(u8, model.provider, "openai") and std.mem.startsWith(u8, model.id, "gpt-5-pro")) {
        options.thinking_level = .high;
    }

    return .{
        .model = model,
        .prompts = prompts,
        .system_prompt = system_prompt,
        .tools = tools,
        .options = options,
    };
}

/// Base URL for canonical refs outside the production catalog (the catalog
/// only covers Codex OAuth + Kimi). Env overrides follow the common
/// <PROVIDER>_BASE_URL conventions so proxies and custom endpoints work;
/// MAKAI_BASE_URL overrides everything.
fn defaultBaseUrlForRef(allocator: std.mem.Allocator, provider_id: []const u8, api: []const u8) ![]const u8 {
    const global = try envOrEmpty(allocator, "MAKAI_BASE_URL");
    defer if (global) |g| allocator.free(g);
    const anthropic = try envOrEmpty(allocator, "ANTHROPIC_BASE_URL");
    defer if (anthropic) |v| allocator.free(v);
    const openai = try envOrEmpty(allocator, "OPENAI_BASE_URL");
    defer if (openai) |v| allocator.free(v);
    const deepseek = try envOrEmpty(allocator, "DEEPSEEK_BASE_URL");
    defer if (deepseek) |v| allocator.free(v);

    return baseUrlWithOverrides(allocator, provider_id, api, .{
        .global = global orelse "",
        .anthropic = anthropic orelse "",
        .openai = openai orelse "",
        .deepseek = deepseek orelse "",
    });
}

/// Explicit URL overrides for baseUrlForRef (empty = use canonical default).
const BaseUrlOverrides = struct {
    global: []const u8 = "",
    anthropic: []const u8 = "",
    openai: []const u8 = "",
    deepseek: []const u8 = "",
};

/// Provider routes append `/v1/...`; accept the common versioned override
/// form without producing a duplicate `/v1/v1/...` path.
fn normalizeVersionedBaseUrl(url: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, url, "/");
    if (std.mem.endsWith(u8, trimmed, "/v1")) return trimmed[0 .. trimmed.len - 3];
    return trimmed;
}

fn usesVersionedRoute(provider_id: []const u8, api: []const u8) bool {
    if (std.mem.eql(u8, provider_id, "github-copilot")) return false;
    return std.mem.eql(u8, api, "anthropic-messages") or
        std.mem.eql(u8, api, "openai-completions") or
        std.mem.eql(u8, api, "openai-responses");
}

fn isReasoningModelRef(provider_id: []const u8, model_id: []const u8) bool {
    if (std.mem.eql(u8, provider_id, "openai")) {
        return std.mem.startsWith(u8, model_id, "o1") or
            std.mem.startsWith(u8, model_id, "o3") or
            std.mem.startsWith(u8, model_id, "o4") or
            (std.mem.startsWith(u8, model_id, "gpt-5") and std.mem.indexOf(u8, model_id, "-chat") == null);
    }
    if (std.mem.eql(u8, provider_id, "deepseek")) {
        return std.mem.startsWith(u8, model_id, "deepseek-reasoner");
    }
    if (std.mem.eql(u8, provider_id, "anthropic")) {
        // Thinking arrived with Claude 3.7 Sonnet; every 4.x+ model has it.
        // Pre-3.7 3.x models (claude-3, claude-3-5-*) and the legacy 1/2/v1/
        // instant families do not; unknown future identifiers default to
        // capable so a selected thinking level is never silently dropped.
        if (!std.mem.startsWith(u8, model_id, "claude-")) return false;
        if (std.mem.startsWith(u8, model_id, "claude-1")) return false;
        if (std.mem.startsWith(u8, model_id, "claude-2")) return false;
        if (std.mem.startsWith(u8, model_id, "claude-v")) return false;
        if (std.mem.startsWith(u8, model_id, "claude-instant")) return false;
        if (std.mem.startsWith(u8, model_id, "claude-3-7")) return true;
        return !std.mem.startsWith(u8, model_id, "claude-3");
    }
    return false;
}

fn isResponsesOnlyModel(model_id: []const u8) bool {
    return std.mem.startsWith(u8, model_id, "o1-pro") or
        std.mem.startsWith(u8, model_id, "o3-pro") or
        std.mem.startsWith(u8, model_id, "gpt-5-pro") or
        std.mem.startsWith(u8, model_id, "gpt-5-codex") or
        std.mem.startsWith(u8, model_id, "gpt-5.1-codex-max") or
        std.mem.indexOf(u8, model_id, "deep-research") != null or
        std.mem.startsWith(u8, model_id, "computer-use-preview");
}

/// Explicit proxy flags for transparentProxyCompat (pure form, testable
/// without mutating the process environment). When `global_base_set` is
/// true the global flag decides; otherwise the provider-specific flag does.
const ProxyCompatFlags = struct {
    global_base_set: bool = false,
    global_proxy: bool = false,
    openai_proxy: bool = false,
    deepseek_proxy: bool = false,
    anthropic_proxy: bool = false,
};

/// A custom base URL is OpenAI-compatible by default. Set
/// `<PROVIDER>_BASE_URL_IS_PROXY=true` (or `MAKAI_BASE_URL_IS_PROXY=true`)
/// only when it transparently preserves the canonical vendor API.
fn transparentProxyCompat(allocator: std.mem.Allocator, provider_id: []const u8) !?ai_types.OpenAICompatOptions {
    const global_base = try envOrEmpty(allocator, "MAKAI_BASE_URL");
    defer if (global_base) |value| allocator.free(value);

    return transparentProxyCompatForFlags(provider_id, .{
        .global_base_set = global_base != null,
        .global_proxy = try envFlag(allocator, "MAKAI_BASE_URL_IS_PROXY"),
        .openai_proxy = try envFlag(allocator, "OPENAI_BASE_URL_IS_PROXY"),
        .deepseek_proxy = try envFlag(allocator, "DEEPSEEK_BASE_URL_IS_PROXY"),
        .anthropic_proxy = try envFlag(allocator, "ANTHROPIC_BASE_URL_IS_PROXY"),
    });
}

fn transparentProxyCompatForFlags(provider_id: []const u8, flags: ProxyCompatFlags) ?ai_types.OpenAICompatOptions {
    if (std.mem.eql(u8, provider_id, "openai") and (if (flags.global_base_set) flags.global_proxy else flags.openai_proxy)) {
        return .{
            .supports_store = true,
            .supports_developer_role = true,
            .supports_reasoning_effort = true,
            .max_tokens_field = .max_completion_tokens,
        };
    }
    if (std.mem.eql(u8, provider_id, "deepseek") and (if (flags.global_base_set) flags.global_proxy else flags.deepseek_proxy)) {
        // A transparent DeepSeek proxy preserves the canonical DeepSeek API:
        // token limits via max_tokens (not OpenAI's max_completion_tokens
        // default inherited by a partial compat value) and no tool strict
        // mode, matching the detected-capability path for api.deepseek.com.
        return .{
            .requires_thinking_as_text = true,
            .max_tokens_field = .max_tokens,
            .supports_strict_mode = false,
        };
    }
    if (std.mem.eql(u8, provider_id, "anthropic") and (if (flags.global_base_set) flags.global_proxy else flags.anthropic_proxy)) {
        return .{ .supports_anthropic_cache_ttl = true };
    }
    return null;
}

/// Pure base-URL resolution: known providers map to their vendor endpoints
/// (overridable); unknown providers get "" — an empty base means "no
/// endpoint" and the request fails before the network, rather than deriving
/// an endpoint from the wire-protocol API type and sending the caller's
/// credentials to an unrelated vendor. Always returns owned memory.
fn baseUrlWithOverrides(allocator: std.mem.Allocator, provider_id: []const u8, api: []const u8, ov: BaseUrlOverrides) ![]const u8 {
    if (ov.global.len > 0) {
        const global = if (usesVersionedRoute(provider_id, api)) normalizeVersionedBaseUrl(ov.global) else std.mem.trimEnd(u8, ov.global, "/");
        return try allocator.dupe(u8, global);
    }

    const by_provider: ?[]const u8 = if (std.mem.eql(u8, provider_id, "anthropic") and std.mem.eql(u8, api, "anthropic-messages"))
        if (ov.anthropic.len > 0) normalizeVersionedBaseUrl(ov.anthropic) else "https://api.anthropic.com"
    else if (std.mem.eql(u8, provider_id, "openai") and (std.mem.eql(u8, api, "openai-completions") or std.mem.eql(u8, api, "openai-responses")))
        if (ov.openai.len > 0) normalizeVersionedBaseUrl(ov.openai) else "https://api.openai.com"
    else if (std.mem.eql(u8, provider_id, "deepseek") and std.mem.eql(u8, api, "openai-completions"))
        if (ov.deepseek.len > 0) normalizeVersionedBaseUrl(ov.deepseek) else "https://api.deepseek.com"
    else
        null;
    if (by_provider) |url| return try allocator.dupe(u8, url);

    return try allocator.dupe(u8, "");
}

/// Owned env value, null when unset or empty (the allocation is freed when
/// the value is empty — callers only own the returned slice).
fn envOrEmpty(allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
    const value = compat.getEnvVarOwned(allocator, key) catch return null;
    if (value.len == 0) {
        allocator.free(value);
        return null;
    }
    return value;
}

fn envFlag(allocator: std.mem.Allocator, key: []const u8) !bool {
    const value = try envOrEmpty(allocator, key) orelse return false;
    defer allocator.free(value);
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

fn modelFromCanonicalRef(allocator: std.mem.Allocator, ref: []const u8) !ai_types.Model {
    var parsed = model_ref.parseModelRef(allocator, ref) catch return error.InvalidModelRef;
    errdefer parsed.deinit(allocator);

    if (try modelFromProductionCatalog(allocator, parsed)) |model| {
        parsed.deinit(allocator);
        return model;
    }

    const name = try allocator.dupe(u8, parsed.model_id);
    errdefer allocator.free(name);

    const base_url = if (std.mem.eql(u8, parsed.provider_id, "openai") and
        std.mem.eql(u8, parsed.api, "openai-completions") and
        isResponsesOnlyModel(parsed.model_id))
        try allocator.dupe(u8, "")
    else
        try defaultBaseUrlForRef(allocator, parsed.provider_id, parsed.api);
    errdefer allocator.free(base_url);

    const input = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(input);

    const compat_options = try transparentProxyCompat(allocator, parsed.provider_id);

    const model = ai_types.Model{
        .id = parsed.model_id,
        .name = name,
        .api = parsed.api,
        .provider = parsed.provider_id,
        .base_url = base_url,
        .reasoning = isReasoningModelRef(parsed.provider_id, parsed.model_id),
        .input = input,
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 200_000,
        .max_tokens = 4_096,
        .compat = compat_options,
        .is_owned = true,
    };
    parsed.provider_id = &.{};
    parsed.api = &.{};
    parsed.model_id = &.{};
    return model;
}

fn modelFromProductionCatalog(
    allocator: std.mem.Allocator,
    parsed: model_ref.ParsedModelRef,
) !?ai_types.Model {
    const models = tui_model_catalog.loadProductionModels(allocator) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    defer tui_model_catalog.deinitModels(allocator, models);

    for (models) |model| {
        if (!std.mem.eql(u8, model.provider, parsed.provider_id)) continue;
        if (!std.mem.eql(u8, model.api, parsed.api)) continue;
        if (!std.mem.eql(u8, model.id, parsed.model_id)) continue;
        return try ai_types.cloneModel(allocator, model);
    }

    return null;
}

fn parseAgentRunOptions(allocator: std.mem.Allocator, message_obj: std.json.ObjectMap, config_obj: ?std.json.ObjectMap, options_json: []const u8) !AgentRunOptions {
    const message_options = if (message_obj.get("options")) |value|
        if (value == .object) value.object else null
    else
        null;

    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |*value| value.deinit();
    var envelope_options: ?std.json.ObjectMap = null;
    if (options_json.len > 0) {
        parsed = try std.json.parseFromSlice(std.json.Value, allocator, options_json, .{});
        if (parsed.?.value == .object) envelope_options = parsed.?.value.object;
    }

    const thinking_level = optionThinkingLevel(envelope_options, message_options, config_obj, "thinking_level");

    return .{
        .temperature = optionF32(envelope_options, message_options, "temperature"),
        .max_tokens = optionU32(envelope_options, message_options, "max_tokens"),
        .max_iterations = optionU32(envelope_options, message_options, "max_iterations"),
        .thinking_level = thinking_level orelse .low,
        .has_explicit_thinking_level = thinking_level != null,
        .api_key = if (optionString(envelope_options, message_options, "api_key")) |key| try allocator.dupe(u8, key) else null,
    };
}

fn optionValue(primary: ?std.json.ObjectMap, fallback: ?std.json.ObjectMap, key: []const u8) ?std.json.Value {
    if (primary) |obj| {
        if (obj.get(key)) |value| return value;
    }
    if (fallback) |obj| {
        if (obj.get(key)) |value| return value;
    }
    return null;
}

fn optionF32(primary: ?std.json.ObjectMap, fallback: ?std.json.ObjectMap, key: []const u8) ?f32 {
    return if (optionValue(primary, fallback, key)) |value| valueAsF32(value) else null;
}

fn optionU32(primary: ?std.json.ObjectMap, fallback: ?std.json.ObjectMap, key: []const u8) ?u32 {
    return if (optionValue(primary, fallback, key)) |value| valueAsU32(value) else null;
}

fn optionString(primary: ?std.json.ObjectMap, fallback: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return if (optionValue(primary, fallback, key)) |value| if (value == .string) value.string else null else null;
}

fn optionThinkingLevel(primary: ?std.json.ObjectMap, fallback: ?std.json.ObjectMap, config: ?std.json.ObjectMap, key: []const u8) ?ai_types.ThinkingLevel {
    if (optionString(primary, fallback, key)) |value| {
        if (std.meta.stringToEnum(ai_types.ThinkingLevel, value)) |level| return normalizeStdioThinkingLevel(level);
    }
    if (config) |obj| {
        if (getStringField(obj, key)) |value| {
            if (std.meta.stringToEnum(ai_types.ThinkingLevel, value)) |level| return normalizeStdioThinkingLevel(level);
        }
    }
    return null;
}

fn normalizeStdioThinkingLevel(level: ai_types.ThinkingLevel) ai_types.ThinkingLevel {
    return switch (level) {
        .minimal => .low,
        else => level,
    };
}

fn parseAgentTools(
    allocator: std.mem.Allocator,
    message_obj: std.json.ObjectMap,
    config_obj: ?std.json.ObjectMap,
) ![]agent_loop.AgentTool {
    const tools_value = message_obj.get("tools") orelse blk: {
        if (config_obj) |obj| break :blk obj.get("tools");
        break :blk null;
    } orelse return try allocator.alloc(agent_loop.AgentTool, 0);

    if (tools_value != .array) return error.InvalidTools;

    var tools = std.ArrayList(agent_loop.AgentTool).empty;
    errdefer {
        for (tools.items) |*tool| deinitAgentToolFields(allocator, tool);
        tools.deinit(allocator);
    }

    for (tools_value.array.items) |item| {
        try tools.append(allocator, try parseAgentTool(allocator, item));
    }

    return tools.toOwnedSlice(allocator);
}

fn parseAgentTool(allocator: std.mem.Allocator, value: std.json.Value) !agent_loop.AgentTool {
    if (value != .object) return error.InvalidToolDefinition;

    const outer_obj = value.object;
    const tool_obj = if (std.mem.eql(u8, getStringField(outer_obj, "type") orelse "", "function")) blk: {
        const function_value = outer_obj.get("function") orelse return error.InvalidToolDefinition;
        if (function_value != .object) return error.InvalidToolDefinition;
        break :blk function_value.object;
    } else outer_obj;

    const name_text = getStringField(tool_obj, "name") orelse return error.InvalidToolDefinition;
    const description_text = getStringField(tool_obj, "description") orelse "";
    const short_description_text = getStringField(tool_obj, "short_description") orelse getStringField(outer_obj, "short_description");
    const label_text = getStringField(tool_obj, "label") orelse getStringField(outer_obj, "label") orelse name_text;

    const label = try allocator.dupe(u8, label_text);
    errdefer allocator.free(label);
    const name = try allocator.dupe(u8, name_text);
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, description_text);
    errdefer allocator.free(description);
    const short_description = if (short_description_text) |text| try allocator.dupe(u8, text) else null;
    errdefer if (short_description) |text| allocator.free(text);
    const parameters_schema_json = try parseToolSchemaJson(allocator, tool_obj);
    errdefer allocator.free(parameters_schema_json);

    const requires_approval = getBoolField(tool_obj, "requires_approval") orelse getBoolField(outer_obj, "requires_approval") orelse false;
    return .{
        .label = label,
        .name = name,
        .description = description,
        .short_description = short_description,
        .parameters_schema_json = parameters_schema_json,
        .execute = if (requires_approval) remoteApprovalRequiredExecute else unavailableAgentToolExecute,
        .approval_fn = if (requires_approval) remoteApprovalRequiredDecision else null,
    };
}

fn remoteApprovalRequiredDecision(ctx: ?*anyopaque, request: agent_bridge.ToolApprovalRequest) agent_bridge.ToolApprovalDecision {
    _ = ctx;
    _ = request;
    return .reject;
}

fn remoteApprovalRequiredExecute(
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?*const fn (?*anyopaque, []const u8, []const u8, []const u8) void,
    allocator: std.mem.Allocator,
) anyerror!agent_loop.AgentToolResult {
    _ = tool_call_id;
    _ = args_json;
    _ = cancel_token;
    _ = on_update_ctx;
    _ = on_update;
    _ = allocator;
    return error.RemoteToolApprovalRequired;
}

fn parseToolSchemaJson(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
    if (getStringField(obj, "parameters_schema_json")) |schema| return try allocator.dupe(u8, schema);
    if (getStringField(obj, "input_schema_json")) |schema| return try allocator.dupe(u8, schema);
    if (getStringField(obj, "schema_json")) |schema| return try allocator.dupe(u8, schema);

    const schema_value = obj.get("parameters_schema") orelse
        obj.get("input_schema") orelse
        obj.get("parameters") orelse
        obj.get("schema");

    if (schema_value) |schema| {
        return try std.json.Stringify.valueAlloc(allocator, schema, .{});
    }

    return try allocator.dupe(u8, "{}");
}

fn deinitAgentTools(allocator: std.mem.Allocator, tools: []agent_loop.AgentTool) void {
    for (tools) |*tool| deinitAgentToolFields(allocator, tool);
    allocator.free(tools);
}

fn deinitAgentToolFields(allocator: std.mem.Allocator, tool: *agent_loop.AgentTool) void {
    allocator.free(tool.label);
    allocator.free(tool.name);
    allocator.free(tool.description);
    if (tool.short_description) |short| allocator.free(short);
    allocator.free(tool.parameters_schema_json);
}

fn unavailableAgentToolExecute(
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?*const fn (?*anyopaque, []const u8, []const u8, []const u8) void,
    allocator: std.mem.Allocator,
) anyerror!agent_loop.AgentToolResult {
    _ = tool_call_id;
    _ = args_json;
    _ = cancel_token;
    _ = on_update_ctx;
    _ = on_update;
    _ = allocator;
    return error.ToolExecutionUnavailable;
}

fn executeStdioToolViaAgentProtocol(
    ctx: ?*anyopaque,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?*const fn (?*anyopaque, []const u8, []const u8, []const u8) void,
    allocator: std.mem.Allocator,
) anyerror!agent_loop.AgentToolResult {
    _ = on_update_ctx;
    _ = on_update;
    const executor: *StdioAgentToolExecutor = @ptrCast(@alignCast(ctx.?));
    try executor.bridge.enqueueRequest(allocator, executor.session_id, tool_call_id, tool_name, args_json);

    while (true) {
        if (cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }
        if (executor.bridge.popResult(allocator, executor.session_id, tool_call_id)) |result| {
            var owned_result = result;
            defer owned_result.deinit(allocator);
            const content = try parseToolResultContentPartsJson(allocator, owned_result.result_json);
            errdefer deinitUserContentParts(allocator, content);
            const details_json = try allocator.dupe(u8, owned_result.details_json);
            errdefer allocator.free(details_json);
            return .{
                .content = ai_types.OwnedSlice(ai_types.UserContentPart).initOwned(content),
                .details_json = ai_types.OwnedSlice(u8).initOwned(details_json),
                .is_error = owned_result.is_error,
            };
        }
        compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
    }
}

fn parseAgentMessages(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    system_prompt_builder: *std.ArrayList(u8),
) ![]ai_types.Message {
    if (value != .array) return error.InvalidMessages;

    var messages = std.ArrayList(ai_types.Message).empty;
    errdefer {
        for (messages.items) |*message| message.deinit(allocator);
        messages.deinit(allocator);
    }

    for (value.array.items) |item| {
        if (item != .object) return error.InvalidMessage;
        const obj = item.object;
        const role = getStringField(obj, "role") orelse return error.MissingRole;

        if (std.mem.eql(u8, role, "system") or std.mem.eql(u8, role, "developer")) {
            if (obj.get("content")) |content| {
                try appendContentTextToSystemPrompt(system_prompt_builder, allocator, content);
            }
            continue;
        }

        const message = if (std.mem.eql(u8, role, "user"))
            try parseUserMessage(allocator, obj)
        else if (std.mem.eql(u8, role, "assistant"))
            try parseAssistantHistoryMessage(allocator, obj)
        else if (std.mem.eql(u8, role, "tool") or std.mem.eql(u8, role, "tool_result"))
            try parseToolResultHistoryMessage(allocator, obj)
        else
            return error.UnsupportedMessageRole;

        try messages.append(allocator, message);
    }

    return messages.toOwnedSlice(allocator);
}

fn parseUserMessage(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ai_types.Message {
    const content_value = obj.get("content") orelse return error.MissingContent;
    const content = try parseUserContent(allocator, content_value);
    errdefer {
        var mutable = content;
        mutable.deinit(allocator);
    }

    return .{ .user = .{
        .content = content,
        .timestamp = parseTimestamp(obj),
    } };
}

fn parseAssistantHistoryMessage(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ai_types.Message {
    const content = if (obj.get("content")) |value|
        try parseAssistantContentBlocks(allocator, value)
    else
        try allocator.alloc(ai_types.AssistantContent, 0);
    errdefer ai_types.deinitAssistantContent(allocator, content);

    const api = try allocator.dupe(u8, getStringField(obj, "api") orelse "");
    errdefer allocator.free(api);
    const provider = try allocator.dupe(u8, getStringField(obj, "provider_id") orelse getStringField(obj, "provider") orelse "");
    errdefer allocator.free(provider);
    const model = try allocator.dupe(u8, getStringField(obj, "model_id") orelse getStringField(obj, "model") orelse "");
    errdefer allocator.free(model);

    return .{ .assistant = .{
        .content = content,
        .api = api,
        .provider = provider,
        .model = model,
        .usage = .{},
        .stop_reason = if (getStringField(obj, "stop_reason")) |reason| parseStopReason(reason) else .stop,
        .timestamp = parseTimestamp(obj),
        .is_owned = true,
    } };
}

fn parseToolResultHistoryMessage(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ai_types.Message {
    const content_value = obj.get("content");
    const tool_call_id = try allocator.dupe(u8, getStringField(obj, "tool_call_id") orelse getStringField(obj, "id") orelse firstToolResultStringField(content_value, "tool_call_id") orelse firstToolResultStringField(content_value, "tool_use_id") orelse "");
    errdefer allocator.free(tool_call_id);
    const tool_name = try allocator.dupe(u8, getStringField(obj, "tool_name") orelse getStringField(obj, "name") orelse firstToolResultStringField(content_value, "tool_name") orelse "");
    errdefer allocator.free(tool_name);

    const content = if (content_value) |value|
        try parseToolResultContentParts(allocator, value)
    else
        try allocator.alloc(ai_types.UserContentPart, 0);
    errdefer {
        for (content) |*part| part.deinit(allocator);
        allocator.free(content);
    }

    var details_json = if (getStringField(obj, "details_json")) |details|
        ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, details))
    else if (firstToolResultStringField(content_value, "details_json")) |details|
        ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, details))
    else
        ai_types.OwnedSlice(u8).initBorrowed("");
    errdefer details_json.deinit(allocator);

    return .{ .tool_result = .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = content,
        .details_json = details_json,
        .is_error = if (obj.get("is_error")) |value| value == .bool and value.bool else firstToolResultBoolField(content_value, "is_error") orelse false,
        .timestamp = parseTimestamp(obj),
    } };
}

fn parseUserContent(allocator: std.mem.Allocator, value: std.json.Value) !ai_types.UserContent {
    switch (value) {
        .string => |text| return .{ .text = try allocator.dupe(u8, text) },
        .array => |array| {
            var parts = std.ArrayList(ai_types.UserContentPart).empty;
            errdefer {
                for (parts.items) |*part| part.deinit(allocator);
                parts.deinit(allocator);
            }
            for (array.items) |item| {
                if (try parseUserContentPart(allocator, item)) |part| {
                    try parts.append(allocator, part);
                }
            }
            if (parts.items.len == 0) return .{ .text = try allocator.dupe(u8, "") };
            return .{ .parts = try parts.toOwnedSlice(allocator) };
        },
        else => return error.InvalidContent,
    }
}

fn parseToolResultContentParts(allocator: std.mem.Allocator, value: std.json.Value) ![]ai_types.UserContentPart {
    var parts = std.ArrayList(ai_types.UserContentPart).empty;
    errdefer {
        for (parts.items) |*part| part.deinit(allocator);
        parts.deinit(allocator);
    }

    try appendToolResultContentParts(allocator, &parts, value);
    if (parts.items.len == 0) try appendTextContentPart(allocator, &parts, "");
    return parts.toOwnedSlice(allocator);
}

fn parseToolResultContentPartsJson(allocator: std.mem.Allocator, result_json: []const u8) ![]ai_types.UserContentPart {
    if (result_json.len == 0) {
        const content = try allocator.alloc(ai_types.UserContentPart, 0);
        return content;
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer parsed.deinit();
    return parseToolResultContentParts(allocator, parsed.value);
}

fn deinitUserContentParts(allocator: std.mem.Allocator, parts: []ai_types.UserContentPart) void {
    for (parts) |*part| part.deinit(allocator);
    allocator.free(parts);
}

fn firstToolResultStringField(value: ?std.json.Value, key: []const u8) ?[]const u8 {
    const actual = value orelse return null;
    switch (actual) {
        .array => |array| {
            for (array.items) |item| {
                if (firstToolResultStringField(item, key)) |found| return found;
            }
        },
        .object => |obj| {
            if (std.mem.eql(u8, getStringField(obj, "type") orelse "", "tool_result")) {
                if (getStringField(obj, key)) |found| return found;
            }
            if (obj.get("content")) |content| return firstToolResultStringField(content, key);
        },
        else => {},
    }
    return null;
}

fn firstToolResultBoolField(value: ?std.json.Value, key: []const u8) ?bool {
    const actual = value orelse return null;
    switch (actual) {
        .array => |array| {
            for (array.items) |item| {
                if (firstToolResultBoolField(item, key)) |found| return found;
            }
        },
        .object => |obj| {
            if (std.mem.eql(u8, getStringField(obj, "type") orelse "", "tool_result")) {
                if (obj.get(key)) |found| {
                    if (found == .bool) return found.bool;
                }
            }
            if (obj.get("content")) |content| return firstToolResultBoolField(content, key);
        },
        else => {},
    }
    return null;
}

fn appendToolResultContentParts(
    allocator: std.mem.Allocator,
    parts: *std.ArrayList(ai_types.UserContentPart),
    value: std.json.Value,
) !void {
    switch (value) {
        .string => |text| try appendTextContentPart(allocator, parts, text),
        .array => |array| {
            for (array.items) |item| {
                try appendToolResultContentParts(allocator, parts, item);
            }
        },
        .object => |obj| {
            if (std.mem.eql(u8, getStringField(obj, "type") orelse "", "tool_result")) {
                if (obj.get("content")) |content| {
                    try appendToolResultContentParts(allocator, parts, content);
                }
                return;
            }

            if (try parseUserContentPart(allocator, value)) |part| {
                parts.append(allocator, part) catch |err| {
                    var owned = part;
                    owned.deinit(allocator);
                    return err;
                };
            }
        },
        else => {},
    }
}

fn appendTextContentPart(
    allocator: std.mem.Allocator,
    parts: *std.ArrayList(ai_types.UserContentPart),
    text: []const u8,
) !void {
    const owned = try allocator.dupe(u8, text);
    errdefer allocator.free(owned);
    try parts.append(allocator, .{ .text = .{ .text = owned } });
}

fn parseUserContentPart(allocator: std.mem.Allocator, value: std.json.Value) !?ai_types.UserContentPart {
    if (value != .object) return null;
    const obj = value.object;
    const ty = getStringField(obj, "type") orelse return null;
    if (std.mem.eql(u8, ty, "text")) {
        return .{ .text = .{
            .text = try allocator.dupe(u8, getStringField(obj, "text") orelse ""),
        } };
    }
    if (std.mem.eql(u8, ty, "image")) {
        const data = try allocator.dupe(u8, getStringField(obj, "data") orelse "");
        errdefer allocator.free(data);
        const mime_type = try allocator.dupe(u8, getStringField(obj, "mime_type") orelse "application/octet-stream");
        errdefer allocator.free(mime_type);
        return .{ .image = .{
            .data = data,
            .mime_type = mime_type,
        } };
    }
    return null;
}

fn parseAssistantContentBlocks(allocator: std.mem.Allocator, value: std.json.Value) ![]ai_types.AssistantContent {
    switch (value) {
        .string => |text| {
            const blocks = try allocator.alloc(ai_types.AssistantContent, 1);
            errdefer allocator.free(blocks);
            blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
            return blocks;
        },
        .array => |array| {
            var blocks = std.ArrayList(ai_types.AssistantContent).empty;
            errdefer {
                for (blocks.items) |*block| deinitAssistantContentBlock(allocator, block);
                blocks.deinit(allocator);
            }
            for (array.items) |item| {
                if (try parseAssistantContentBlock(allocator, item)) |block| {
                    try blocks.append(allocator, block);
                }
            }
            return blocks.toOwnedSlice(allocator);
        },
        else => return error.InvalidContent,
    }
}

fn parseAssistantContentBlock(allocator: std.mem.Allocator, value: std.json.Value) !?ai_types.AssistantContent {
    if (value != .object) return null;
    const obj = value.object;
    const ty = getStringField(obj, "type") orelse return null;
    if (std.mem.eql(u8, ty, "text")) {
        return .{ .text = .{ .text = try allocator.dupe(u8, getStringField(obj, "text") orelse "") } };
    }
    if (std.mem.eql(u8, ty, "thinking")) {
        return .{ .thinking = .{ .thinking = try allocator.dupe(u8, getStringField(obj, "thinking") orelse "") } };
    }
    if (std.mem.eql(u8, ty, "image")) {
        const data = try allocator.dupe(u8, getStringField(obj, "data") orelse "");
        errdefer allocator.free(data);
        const mime_type = try allocator.dupe(u8, getStringField(obj, "mime_type") orelse "application/octet-stream");
        errdefer allocator.free(mime_type);
        return .{ .image = .{
            .data = data,
            .mime_type = mime_type,
        } };
    }
    if (std.mem.eql(u8, ty, "tool_call") or std.mem.eql(u8, ty, "tool_use")) {
        const args_json = if (getStringField(obj, "arguments_json")) |args|
            try allocator.dupe(u8, args)
        else if (obj.get("arguments")) |args_value|
            try std.json.Stringify.valueAlloc(allocator, args_value, .{})
        else
            try allocator.dupe(u8, "{}");
        errdefer allocator.free(args_json);
        const id = try allocator.dupe(u8, getStringField(obj, "id") orelse getStringField(obj, "tool_call_id") orelse "");
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, getStringField(obj, "name") orelse "");
        errdefer allocator.free(name);
        return .{ .tool_call = .{
            .id = id,
            .name = name,
            .arguments_json = args_json,
        } };
    }
    return null;
}

fn deinitAssistantContentBlock(allocator: std.mem.Allocator, block: *ai_types.AssistantContent) void {
    switch (block.*) {
        .text => |text| {
            allocator.free(text.text);
            if (text.text_signature) |signature| allocator.free(signature);
        },
        .thinking => |thinking| {
            allocator.free(thinking.thinking);
            if (thinking.thinking_signature) |signature| allocator.free(signature);
        },
        .tool_call => |tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            allocator.free(tool_call.arguments_json);
            if (tool_call.thought_signature) |signature| allocator.free(signature);
        },
        .image => |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        },
    }
}

fn appendContentTextToSystemPrompt(builder: *std.ArrayList(u8), allocator: std.mem.Allocator, value: std.json.Value) !void {
    switch (value) {
        .string => |text| try appendSystemPromptText(builder, allocator, text),
        .array => |array| {
            for (array.items) |item| {
                if (item != .object) continue;
                const obj = item.object;
                if (std.mem.eql(u8, getStringField(obj, "type") orelse "", "text")) {
                    try appendSystemPromptText(builder, allocator, getStringField(obj, "text") orelse "");
                }
            }
        },
        else => {},
    }
}

fn appendSystemPromptText(builder: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    if (text.len == 0) return;
    if (builder.items.len > 0) try builder.append(allocator, '\n');
    try builder.appendSlice(allocator, text);
}

fn serializeAgentLoopEvent(
    allocator: std.mem.Allocator,
    session_id: AgentProtocolTypes.SessionId,
    event: agent_loop.AgentEvent,
) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);

    try w.beginObject();
    switch (event) {
        .agent_start => {
            const session_text = try AgentProtocolTypes.sessionIdToString(session_id, allocator);
            defer allocator.free(session_text);
            try w.writeStringField("type", "agent_start");
            try w.writeStringField("session_id", session_text);
        },
        .agent_end => |payload| {
            try w.writeStringField("type", "agent_end");
            // Terminal identity and outcome come from the run's final message
            // (loop-emitted events carry it explicitly, including the
            // synthesized placeholder when no turn ran); fall back to the
            // last assistant message for hand-built events. History must not
            // supply the identity — it can end with an older turn's message
            // from a different model.
            var terminal: ?ai_types.AssistantMessage = payload.final_message;
            if (terminal == null) {
                const messages = payload.messages.slice();
                var idx = messages.len;
                while (idx > 0) {
                    idx -= 1;
                    if (messages[idx] == .assistant) {
                        terminal = messages[idx].assistant;
                        break;
                    }
                }
            }
            // Agent-level termination (e.g. max turns, cancellation) overrides
            // the final turn's reason so raw agent-protocol consumers see the
            // failure detail without the preceding agent_result frame.
            const agent_stop_reason: ?[]const u8 = if (payload.termination) |termination|
                @tagName(termination)
            else if (terminal) |message|
                @tagName(message.stop_reason)
            else
                null;
            if (agent_stop_reason) |reason| {
                try w.writeStringField("stop_reason", reason);
            }
            if (terminal) |message| {
                // Event-only peers have no agent_result frame; the resolved
                // provider/api keep SDK auth retry targetable for opaque refs
                // and let clients scope provider-specific error semantics.
                if (message.provider.len > 0) {
                    try w.writeStringField("provider_id", message.provider);
                }
                if (message.api.len > 0) {
                    try w.writeStringField("api", message.api);
                }
                if (message.error_message.slice().len > 0) {
                    try w.writeStringField("error_message", message.error_message.slice());
                }
            }
        },
        .turn_start => {
            try w.writeStringField("type", "turn_start");
        },
        .turn_end => |payload| {
            try w.writeStringField("type", "turn_end");
            try w.writeStringField("stop_reason", @tagName(payload.message.stop_reason));
            if (payload.message.error_message.slice().len > 0) {
                try w.writeStringField("error_message", payload.message.error_message.slice());
            }
        },
        .message_start => |payload| {
            try w.writeStringField("type", "message_start");
            writeMessageMetadata(&w, payload.message) catch {};
        },
        .message_update => |payload| {
            const provider_event_json = try transport.serializeEvent(payload.event, allocator);
            defer allocator.free(provider_event_json);
            try w.writeStringField("type", "message_update");
            try w.writeKey("event");
            try w.writeRawJson(provider_event_json);
        },
        .message_end => |payload| {
            try w.writeStringField("type", "message_end");
            if (payload.message == .assistant) {
                try w.writeStringField("stop_reason", @tagName(payload.message.assistant.stop_reason));
                if (payload.message.assistant.error_message.slice().len > 0) {
                    try w.writeStringField("error_message", payload.message.assistant.error_message.slice());
                }
                try writeUsageField(&w, payload.message.assistant.usage);
            }
        },
        .context_usage => |payload| {
            try w.writeStringField("type", "context_usage");
            try w.writeIntField("system_prompt_bytes", payload.system_prompt_bytes);
            try w.writeIntField("message_bytes", payload.message_bytes);
            try w.writeIntField("tool_definition_bytes", payload.tool_definition_bytes);
            try w.writeIntField("total_bytes", payload.total_bytes);
            try w.writeIntField("estimated_tokens", payload.estimated_tokens);
            try w.writeIntField("message_count", payload.message_count);
            try w.writeIntField("tool_count", payload.tool_count);
        },
        .prompt_segment_usage => |payload| {
            try w.writeStringField("type", "prompt_segment_usage");
            try w.writeStringField("segment", @tagName(payload.segment));
            try w.writeStringField("cache_role", @tagName(payload.cache_role));
            try w.writeIntField("bytes", payload.bytes);
            try w.writeIntField("estimated_tokens", payload.estimated_tokens);
            try w.writeIntField("item_count", payload.item_count);
        },
        .tool_execution_start => |payload| {
            try w.writeStringField("type", "tool_execution_start");
            try w.writeStringField("tool_call_id", payload.tool_call_id);
            try w.writeStringField("tool_name", payload.tool_name);
            try w.writeStringField("args_json", payload.args_json);
        },
        .tool_execution_update => |payload| {
            try w.writeStringField("type", "tool_execution_update");
            try w.writeStringField("tool_call_id", payload.tool_call_id);
            try w.writeStringField("tool_name", payload.tool_name);
            try w.writeStringField("partial_result_json", payload.partial_result_json);
        },
        .tool_execution_end => |payload| {
            try w.writeStringField("type", "tool_execution_end");
            try w.writeStringField("tool_call_id", payload.tool_call_id);
            try w.writeStringField("tool_name", payload.tool_name);
            try w.writeStringField("result_json", payload.result_json);
            if (payload.content_json.len > 0) try w.writeStringField("content_json", payload.content_json);
            try w.writeBoolField("is_error", payload.is_error);
            try w.writeIntField("args_bytes", payload.args_bytes);
            try w.writeIntField("raw_result_bytes", payload.raw_result_bytes);
            try w.writeIntField("returned_result_bytes", payload.returned_result_bytes);
            try w.writeIntField("raw_details_bytes", payload.raw_details_bytes);
            try w.writeIntField("returned_details_bytes", payload.returned_details_bytes);
            try w.writeIntField("raw_total_bytes", payload.raw_total_bytes);
            try w.writeIntField("returned_total_bytes", payload.returned_total_bytes);
            try w.writeIntField("estimated_returned_tokens", payload.estimated_returned_tokens);
            try w.writeIntField("artifact_count", payload.artifact_count);
            try writeArtifactReferences(&w, payload.artifacts);
        },
    }
    try w.endObject();

    const out = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return out;
}

fn writeArtifactReferences(w: *json_writer.JsonWriter, artifacts: []const ai_types.ArtifactReference) !void {
    if (artifacts.len == 0) return;
    try w.writeKey("artifacts");
    try w.beginArray();
    for (artifacts) |artifact| {
        try w.beginObject();
        try w.writeStringField("artifact_id", artifact.artifact_id);
        if (artifact.getUri()) |uri| try w.writeStringField("uri", uri);
        if (artifact.getMimeType()) |mime_type| try w.writeStringField("mime_type", mime_type);
        if (artifact.byte_size) |byte_size| try w.writeIntField("byte_size", byte_size);
        if (artifact.getSha256()) |sha256| try w.writeStringField("sha256", sha256);
        if (artifact.getDescription()) |description| try w.writeStringField("description", description);
        try w.endObject();
    }
    try w.endArray();
}

fn serializeAgentErrorEvent(allocator: std.mem.Allocator, message: []const u8, code: []const u8) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);
    try w.beginObject();
    try w.writeStringField("type", "error");
    try w.writeStringField("message", message);
    try w.writeStringField("code", code);
    try w.endObject();
    const out = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return out;
}

fn writeMessageMetadata(w: *json_writer.JsonWriter, message: ai_types.Message) !void {
    if (message != .assistant) return;
    try w.writeStringField("api", message.assistant.api);
    try w.writeStringField("provider", message.assistant.provider);
    try w.writeStringField("model", message.assistant.model);
}

fn writeUsageField(w: *json_writer.JsonWriter, usage: ai_types.Usage) !void {
    try w.writeKey("usage");
    try w.beginObject();
    try w.writeIntField("input", usage.input);
    try w.writeIntField("output", usage.output);
    try w.writeIntField("cache_read", usage.cache_read);
    try w.writeIntField("cache_write", usage.cache_write);
    try w.endObject();
}

fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn getBoolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn parseTimestamp(obj: std.json.ObjectMap) i64 {
    if (obj.get("timestamp")) |value| {
        if (value == .integer) return value.integer;
    }
    return compat.time.nowMillis();
}

fn parseStopReason(reason: []const u8) ai_types.StopReason {
    return std.meta.stringToEnum(ai_types.StopReason, reason) orelse .stop;
}

fn valueAsU32(value: std.json.Value) ?u32 {
    return switch (value) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        .float => |f| if (f >= 0 and f <= @as(f64, @floatFromInt(std.math.maxInt(u32)))) @intFromFloat(f) else null,
        else => null,
    };
}

fn valueAsF32(value: std.json.Value) ?f32 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => null,
    };
}

fn parseStdioToolResultFromLine(line: []const u8, allocator: std.mem.Allocator) !?StdioToolResult {
    var env = agent_protocol_envelope.deserializeEnvelope(line, allocator) catch return null;
    defer env.deinit(allocator);
    if (env.payload != .tool_result) return null;

    const result = env.payload.tool_result;
    const owned_tool_call_id = try allocator.dupe(u8, result.tool_call_id);
    errdefer allocator.free(owned_tool_call_id);
    const owned_result_json = try allocator.dupe(u8, result.result_json);
    errdefer allocator.free(owned_result_json);
    const details = result.details_json.slice();
    const owned_details_json = try allocator.dupe(u8, details);
    errdefer allocator.free(owned_details_json);

    return .{
        .session_id = env.session_id,
        .tool_call_id = owned_tool_call_id,
        .result_json = owned_result_json,
        .details_json = owned_details_json,
        .is_error = result.is_error,
    };
}

fn validatedAgentStopSessionFromLine(line: []const u8, allocator: std.mem.Allocator) ?AgentProtocolTypes.SessionId {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const root = parsed.value.object;
    if (!std.mem.eql(u8, getStringField(root, "type") orelse "", "agent_stop")) return null;

    const top_session = getStringField(root, "session_id") orelse return null;
    if (AgentProtocolTypes.parseSessionId(top_session) == null) return null;
    const message_id = getStringField(root, "message_id") orelse return null;
    if (AgentProtocolTypes.parseUlid(message_id) == null) return null;
    if (!hasIntegerField(root, "sequence")) return null;
    if (!hasIntegerField(root, "timestamp")) return null;
    if (!hasIntegerField(root, "version")) return null;

    const payload = root.get("payload") orelse return null;
    if (payload != .object) return null;
    const payload_session = getStringField(payload.object, "session_id") orelse return null;
    return AgentProtocolTypes.parseSessionId(payload_session);
}

fn hasValidAgentEnvelopeShape(line: []const u8, allocator: std.mem.Allocator) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
    defer parsed.deinit();

    if (parsed.value != .object) return false;
    const root = parsed.value.object;
    const ty = getStringField(root, "type") orelse return false;
    const session_id = getStringField(root, "session_id") orelse return false;
    if (AgentProtocolTypes.parseSessionId(session_id) == null) return false;
    const message_id = getStringField(root, "message_id") orelse return false;
    if (AgentProtocolTypes.parseUlid(message_id) == null) return false;
    if (!hasIntegerField(root, "sequence")) return false;
    if (!hasIntegerField(root, "timestamp")) return false;
    if (!hasIntegerField(root, "version")) return false;

    const payload = root.get("payload") orelse return false;
    if (payload != .object) return false;
    return hasValidAgentPayloadShape(ty, payload.object);
}

fn hasValidAgentPayloadShape(ty: []const u8, payload: std.json.ObjectMap) bool {
    if (std.mem.eql(u8, ty, "agent_start")) return hasStringField(payload, "config_json");
    if (std.mem.eql(u8, ty, "agent_message")) {
        const session_id = getStringField(payload, "session_id") orelse return false;
        return AgentProtocolTypes.parseSessionId(session_id) != null and hasStringField(payload, "message_json");
    }
    if (std.mem.eql(u8, ty, "agent_stop")) {
        const session_id = getStringField(payload, "session_id") orelse return false;
        return AgentProtocolTypes.parseSessionId(session_id) != null;
    }
    if (std.mem.eql(u8, ty, "agent_status")) {
        const session_id = getStringField(payload, "session_id") orelse return false;
        return AgentProtocolTypes.parseSessionId(session_id) != null;
    }
    if (std.mem.eql(u8, ty, "tool_result")) {
        return hasStringField(payload, "tool_call_id") and hasStringField(payload, "result_json");
    }
    if (std.mem.eql(u8, ty, "models_request")) return true;
    if (std.mem.eql(u8, ty, "tool_list")) return true;
    if (std.mem.eql(u8, ty, "ping")) return true;
    if (std.mem.eql(u8, ty, "goodbye")) return true;
    return false;
}

fn hasIntegerField(obj: std.json.ObjectMap, key: []const u8) bool {
    const value = obj.get(key) orelse return false;
    return value == .integer;
}

fn hasStringField(obj: std.json.ObjectMap, key: []const u8) bool {
    const value = obj.get(key) orelse return false;
    return value == .string;
}

fn clearOwnedLines(allocator: std.mem.Allocator, lines: *std.ArrayList([]const u8)) void {
    for (lines.items) |line| allocator.free(line);
    lines.clearRetainingCapacity();
}

fn writeOwnedLinesAndClear(
    file: std.Io.File,
    allocator: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
) !void {
    defer clearOwnedLines(allocator, lines);

    for (lines.items) |line| {
        try compat.stdio.writeLine(file, line);
    }
}

fn emitRuntimeError(
    file: std.Io.File,
    allocator: std.mem.Allocator,
    code: RuntimeErrorCode,
    message: []const u8,
) !void {
    const payload = try std.json.Stringify.valueAlloc(allocator, .{
        .type = "error",
        .code = @tagName(code),
        .protocol_version = STDIO_PROTOCOL_VERSION,
        .message = message,
    }, .{});
    defer allocator.free(payload);
    try compat.stdio.writeLine(file, payload);
}

fn runStdioMode(allocator: std.mem.Allocator, stdin: std.Io.File, stdout: std.Io.File) !void {
    var stdio_loop = try StdioProtocolLoop.initWithBuiltins(allocator);
    defer stdio_loop.deinit();

    try compat.stdio.writeAll(stdout, READY_FRAME);

    var async_receiver = stdio.AsyncStdioReceiver.initWithFile(stdin);
    var stdin_handle = try async_receiver.receiveStreamWithHandle(allocator);
    defer _ = stdin_handle.deinit(STDIO_THREAD_JOIN_TIMEOUT_MS);

    const stdin_stream = stdin_handle.getStream();
    var outbound_lines = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound_lines);
        outbound_lines.deinit(allocator);
    }

    while (true) {
        var did_work = false;

        while (stdin_stream.poll()) |chunk| {
            var mutable_chunk = chunk;
            defer mutable_chunk.deinit(allocator);

            const line = std.mem.trim(u8, mutable_chunk.data, " \t\r\n");
            if (line.len == 0) continue;

            const dispatched = stdio_loop.dispatchInboundLine(line) catch |err| {
                try emitRuntimeError(stdout, allocator, .dispatch_error, @errorName(err));
                did_work = true;
                continue;
            };
            if (dispatched) {
                did_work = true;
            } else {
                try emitRuntimeError(stdout, allocator, .unknown_envelope, "unrecognized or ambiguous stdio envelope");
                did_work = true;
            }
        }

        const forwarded = stdio_loop.pumpBackground() catch |err| blk: {
            try emitRuntimeError(stdout, allocator, .runtime_error, @errorName(err));
            break :blk 0;
        };
        if (forwarded > 0) did_work = true;

        const drained = stdio_loop.drainOutbound(&outbound_lines) catch |err| blk: {
            try emitRuntimeError(stdout, allocator, .runtime_error, @errorName(err));
            break :blk 0;
        };
        if (drained > 0) {
            try writeOwnedLinesAndClear(stdout, allocator, &outbound_lines);
            did_work = true;
        }

        if (stdin_stream.isDone() and !did_work and !stdio_loop.hasActiveProviderStreams() and !stdio_loop.hasActiveAgentRuns() and !stdio_loop.hasActiveAuthFlows()) {
            break;
        }

        if (!did_work) {
            compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
        }
    }

    // Drain any final buffered input/output before shutdown.
    while (stdin_stream.poll()) |chunk| {
        var mutable_chunk = chunk;
        defer mutable_chunk.deinit(allocator);

        const line = std.mem.trim(u8, mutable_chunk.data, " \t\r\n");
        if (line.len == 0) continue;
        const dispatched = stdio_loop.dispatchInboundLine(line) catch |err| {
            try emitRuntimeError(stdout, allocator, .dispatch_error, @errorName(err));
            continue;
        };
        if (!dispatched) {
            try emitRuntimeError(stdout, allocator, .unknown_envelope, "unrecognized or ambiguous stdio envelope");
        }
    }
    _ = stdio_loop.pumpBackground() catch |err| blk: {
        try emitRuntimeError(stdout, allocator, .runtime_error, @errorName(err));
        break :blk 0;
    };
    const drained = stdio_loop.drainOutbound(&outbound_lines) catch |err| blk: {
        try emitRuntimeError(stdout, allocator, .runtime_error, @errorName(err));
        break :blk 0;
    };
    if (drained > 0) {
        try writeOwnedLinesAndClear(stdout, allocator, &outbound_lines);
    }
}

fn printUsage(file: std.Io.File) !void {
    try compat.stdio.writeAll(file,
        \\Usage:
        \\  makai --version
        \\  makai --stdio
        \\  makai --tui
        \\  makai -p [--agent] [--storage] "<prompt>" [--model <id>]
        \\  makai auth providers [--json]
        \\  makai auth login --provider <id> [--json]
        \\
        \\Commands:
        \\  --version        Print binary version
        \\  --stdio          Start stdio mode
        \\  --tui            Start terminal UI shell
        \\  -p               Non-interactive print mode: stream a prompt using
        \\                   stored credentials and print every event to stdout.
        \\                   Useful for debugging provider streaming.
        \\                   Use --agent to run through the full agent loop.
        \\                   Use --storage to resolve credentials like the TUI.
        \\  auth providers   List oauth-capable providers
        \\  auth login       Run OAuth flow and persist credentials
        \\
    );
}

fn runTui(allocator: std.mem.Allocator, io: std.Io) !void {
    try tui_app.run(allocator, io);
}

/// Non-interactive print mode: stream a single prompt against a model resolved
/// from the production catalog (using stored credentials) and print every event.
/// Mirrors the exact provider code path the TUI uses, so it reproduces (and
/// exposes) streaming bugs without needing a real terminal.
fn runPrintMode(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        perr("error: -p requires a prompt argument\n");
        return error.InvalidArgument;
    }

    var prompt_index: usize = 0;
    var use_agent_loop = false;
    var use_storage_auth = false;
    var model_id: []const u8 = "kimi-k2.7-code";
    while (prompt_index < args.len and std.mem.startsWith(u8, args[prompt_index], "--")) : (prompt_index += 1) {
        if (std.mem.eql(u8, args[prompt_index], "--agent")) {
            use_agent_loop = true;
        } else if (std.mem.eql(u8, args[prompt_index], "--storage")) {
            use_storage_auth = true;
        } else if (std.mem.eql(u8, args[prompt_index], "--tui-runtime")) {
            prompt_index += 1;
            if (prompt_index >= args.len) {
                perr("error: --tui-runtime requires a prompt\n");
                return error.InvalidArgument;
            }
            return runPrintTuiRuntime(allocator, args[prompt_index]);
        } else if (std.mem.eql(u8, args[prompt_index], "--model")) {
            prompt_index += 1;
            if (prompt_index >= args.len) {
                perr("error: --model requires a value\n");
                return error.InvalidArgument;
            }
            model_id = args[prompt_index];
        } else {
            perrf("error: unsupported -p option: {s}\n", .{args[prompt_index]});
            return error.InvalidArgument;
        }
    }
    if (prompt_index >= args.len) {
        perr("error: -p requires a prompt argument\n");
        return error.InvalidArgument;
    }
    const prompt = args[prompt_index];

    perr("[print] building kimi model from env...\n");

    // Read the API key from KIMI_API_KEY unless explicitly asked to use saved
    // credentials. Region follows KIMI_REGION first, then the stored Kimi
    // provider_data when --storage is used, then China as the default.
    const api_key_copy: ?[]u8 = if (use_storage_auth) null else blk: {
        const api_key_env = compat.getEnvVarOwned(allocator, "KIMI_API_KEY") catch |err| {
            perrf("error: set KIMI_API_KEY to use -p, or pass --storage to use saved credentials: {s}\n", .{@errorName(err)});
            return error.NoCredentials;
        };
        break :blk api_key_env;
    };
    defer if (api_key_copy) |key| allocator.free(key);

    const region = resolvePrintKimiRegion(allocator, use_storage_auth);
    const is_global_kimi = std.mem.eql(u8, region, "global");
    const base_url = if (is_global_kimi)
        "https://api.moonshot.ai"
    else
        "https://api.kimi.com/coding";

    // Build the Kimi model inline (same shape as model_catalog.kimiModel).
    const model = ai_types.Model{
        .id = model_id,
        .name = model_id,
        .api = "openai-completions",
        .provider = "kimi",
        .base_url = base_url,
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 262_144,
        .max_tokens = 16_384,
    };

    // Register built-in API providers so we can resolve the stream fn.
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    const provider = registry.getApiProvider(model.api) orelse {
        perrf("error: no provider registered for api '{s}'\n", .{model.api});
        return error.NoProvider;
    };
    _ = provider;

    // Build a single-turn context from the prompt.
    const messages = try allocator.alloc(ai_types.Message, 1);
    defer allocator.free(messages);
    messages[0] = .{ .user = .{ .content = .{ .text = prompt }, .timestamp = compat.time.nowSeconds() } };
    const context = ai_types.Context{ .messages = messages };

    perrf("[print] model={s} api={s} provider={s} base_url={s}\n", .{ model.id, model.api, model.provider, model.base_url });
    if (api_key_copy) |key| {
        perrf("[print] api_key_len={d} reasoning={any}\n", .{ key.len, model.reasoning });
    } else {
        perrf("[print] api_key=storage reasoning={any}\n", .{model.reasoning});
    }
    if (use_agent_loop) {
        return runPrintAgentLoop(allocator, model, prompt, api_key_copy);
    }

    perr("[print] starting stream via protocol bridge...\n");

    // Use the in-process protocol bridge — the EXACT path the TUI's agent loop
    // uses (streamViaProtocol → runStreamThread → ProtocolServer/Client). This
    // reproduces TUI streaming bugs that the direct stream_simple path misses.
    var bridge = agent_bridge.InProcessProviderProtocolBridge.init(&registry);
    const protocol = bridge.protocolClient();

    const stream = try protocol.stream(model, context, .{
        .api_key = api_key_copy,
    }, allocator);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    perr("[print] stream created, polling events...\n");

    var event_count: usize = 0;
    while (stream.wait()) |ev| {
        event_count += 1;
        var owned_event = ev;
        defer if (stream.owns_events) ai_types.deinitAssistantMessageEvent(allocator, &owned_event);
        switch (ev) {
            .text_delta => |td| {
                perrf("[text] ({d}b) {s}\n", .{ td.delta.len, td.delta });
            },
            .thinking_delta => |td| {
                perrf("[think] ({d}b) {s}\n", .{ td.delta.len, td.delta });
            },
            .toolcall_delta => |td| {
                perrf("[tool_delta] {s}\n", .{td.delta});
            },
            .done => |d| {
                perrf("[done] stop_reason={s} events={d}\n", .{ @tagName(d.message.stop_reason), event_count });
                break;
            },
            .@"error" => |e| {
                perrf("[error] reason={s} events={d}\n", .{ @tagName(e.reason), event_count });
                break;
            },
            else => {
                perrf("[event#{d}] {s}\n", .{ event_count, @tagName(ev) });
            },
        }
    }

    // Direct provider path signals completion via complete()+getResult(), not a
    // pushed .done event, so a null return here can be normal — check the result.
    if (stream.getError()) |e| {
        perrf("[print] stream error: {s}\n", .{e});
    } else if (stream.getResult()) |result| {
        perrf("[print] COMPLETE stop={s} events={d} content_blocks={d}\n", .{ @tagName(result.stop_reason), event_count, result.content.len });
    } else {
        perrf("[print] NoFinalMessage after {d} events\n", .{event_count});
    }
}

fn runPrintAgentLoop(
    allocator: std.mem.Allocator,
    model: ai_types.Model,
    prompt: []const u8,
    api_key: ?[]const u8,
) !void {
    perr("[print-agent] starting full agent loop via protocol bridge...\n");

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    var bridge = agent_bridge.InProcessProviderProtocolBridge.init(&registry);
    const protocol = bridge.protocolClient();

    var context = agent_loop.AgentContext.init(allocator);
    defer context.deinit();
    context.system_prompt = ai_types.OwnedSlice(u8).initBorrowed("You are Makai running a Kimi debug print request. Reply concisely.");

    const messages = try allocator.alloc(ai_types.Message, 1);
    defer allocator.free(messages);
    messages[0] = .{ .user = .{ .content = .{ .text = try allocator.dupe(u8, prompt) }, .timestamp = compat.time.nowSeconds() } };

    const stream = try agent_loop.agentLoop(allocator, messages, &context, .{
        .model = model,
        .protocol = protocol,
        .tools = &.{},
        .api_key = api_key,
        .max_tokens = model.max_tokens,
        .thinking_level = .low,
        .max_iterations = 1,
    });
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    var event_count: usize = 0;
    while (stream.wait()) |event| {
        event_count += 1;
        var owned_event = event;
        defer owned_event.deinit(allocator);

        switch (owned_event) {
            .message_update => |update| {
                switch (update.event) {
                    .text_delta => |td| perrf("[agent-text] ({d}b) {s}\n", .{ td.delta.len, td.delta }),
                    .thinking_delta => |td| perrf("[agent-think] ({d}b) {s}\n", .{ td.delta.len, td.delta }),
                    else => perrf("[agent-provider-event#{d}] {s}\n", .{ event_count, @tagName(update.event) }),
                }
            },
            .message_end => |payload| {
                if (payload.message == .assistant) {
                    const msg = payload.message.assistant;
                    perrf("[agent-message-end] stop={s} content_blocks={d}\n", .{ @tagName(msg.stop_reason), msg.content.len });
                } else {
                    perrf("[agent-message-end] {s}\n", .{@tagName(payload.message)});
                }
            },
            .turn_end => |payload| {
                perrf("[agent-turn-end] stop={s} content_blocks={d}\n", .{ @tagName(payload.message.stop_reason), payload.message.content.len });
                if (payload.message.error_message.slice().len > 0) {
                    perrf("[agent-turn-end] error={s}\n", .{payload.message.error_message.slice()});
                }
            },
            .agent_end => |payload| {
                perrf("[agent-end] messages={d}\n", .{payload.messages.slice().len});
            },
            else => perrf("[agent-event#{d}] {s}\n", .{ event_count, @tagName(owned_event) }),
        }
    }

    if (stream.getError()) |e| {
        perrf("[print-agent] stream error: {s}\n", .{e});
    } else if (stream.getResult()) |result| {
        perrf("[print-agent] COMPLETE iterations={d} stop={s} events={d} content_blocks={d}\n", .{
            result.iterations,
            @tagName(result.final_message.stop_reason),
            event_count,
            result.final_message.content.len,
        });
        if (result.final_message.error_message.slice().len > 0) {
            perrf("[print-agent] final error={s}\n", .{result.final_message.error_message.slice()});
        }
    } else {
        perrf("[print-agent] NoFinalMessage after {d} events\n", .{event_count});
    }
}

fn runPrintTuiRuntime(allocator: std.mem.Allocator, prompt: []const u8) !void {
    perr("[print-tui] starting TUI runtime path with production tool registry...\n");

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    var bridge = agent_bridge.InProcessProviderProtocolBridge.init(&registry);

    const models = [_]ai_types.Model{.{
        .id = "kimi-k2.7-code",
        .name = "Kimi K2.7 Code",
        .api = "openai-completions",
        .provider = "kimi",
        .base_url = "https://api.kimi.com/coding",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 262_144,
        .max_tokens = 16_384,
    }};

    const options = tui_app.TuiRuntimeOptions{
        .protocol = (&bridge).protocolClient(),
        .models = &models,
        .initial_model_id = "kimi-k2.7-code",
        .run_async = false,
        .compact_output = true,
    };

    var runtime = try tui_app.TuiRuntime.init(allocator, options);
    defer runtime.deinit();

    if (runtime.currentModel()) |model| {
        perrf("[print-tui] initial model={s} api={s} provider={s} base_url={s}\n", .{ model.id, model.api, model.provider, model.base_url });
    } else {
        perr("[print-tui] no initial model\n");
    }

    runtime.switchModel("kimi-k2.7-code") catch |err| {
        perrf("[print-tui] switchModel(kimi-k2.7-code) failed: {s}\n", .{@errorName(err)});
        return err;
    };
    if (runtime.currentModel()) |model| {
        perrf("[print-tui] active model={s} api={s} provider={s} base_url={s} tools={d}\n", .{
            model.id,
            model.api,
            model.provider,
            model.base_url,
            runtime.availableTools().len,
        });
    }

    try runtime.submitTurn(prompt);

    var event_count: usize = 0;
    while (true) {
        const stream = runtime.streamEvents();
        if (stream.wait()) |event| {
            event_count += 1;
            var owned_event = event;
            defer owned_event.deinit(allocator);
            switch (owned_event) {
                .text_delta => |td| perrf("[print-tui-text] ({d}b) {s}\n", .{ td.delta.slice().len, td.delta.slice() }),
                .thinking_delta => |td| perrf("[print-tui-think] ({d}b) {s}\n", .{ td.delta.slice().len, td.delta.slice() }),
                .message_end => |payload| perrf("[print-tui-message-end] role={s} stop={s} is_error={any} text={s}\n", .{
                    @tagName(payload.role),
                    @tagName(payload.stop_reason),
                    payload.is_error,
                    payload.text.slice(),
                }),
                .turn_end => |payload| perrf("[print-tui-turn-end] stop={s}\n", .{@tagName(payload.stop_reason)}),
                .agent_end => |payload| {
                    perrf("[print-tui-agent-end] reason={s} events={d}\n", .{ @tagName(payload.reason), event_count });
                    break;
                },
                .@"error" => |payload| perrf("[print-tui-error] {s}\n", .{payload.message.slice()}),
                else => perrf("[print-tui-event#{d}] {s}\n", .{ event_count, @tagName(owned_event) }),
            }
            continue;
        }

        if (stream.getError()) |err_msg| {
            perrf("[print-tui] stream error: {s}\n", .{err_msg});
            break;
        }
        if (stream.getResult()) |result| {
            perrf("[print-tui] COMPLETE reason={s} events={d}\n", .{ @tagName(result.reason), event_count });
            break;
        }
        break;
    }
}

/// Write directly to stderr — `std.debug.print` is unbuffered (lock-protected
/// direct writer) so diagnostics survive even if the process is killed mid-hang.
fn perr(msg: []const u8) void {
    std.debug.print("{s}", .{msg});
}

/// Formatted variant of `perr`.
fn perrf(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// Production auth-server options for the CLI wrapper. Real OAuth flows are
/// enabled and credentials are persisted to ~/.makai/auth.json by the runtime.
const PRODUCTION_AUTH_SERVER_OPTIONS = auth_protocol_server.AuthProtocolServer.Options{
    .persist_credentials = true,
    .enable_real_oauth = true,
};

fn handleAuth(
    args: []const []const u8,
    allocator: std.mem.Allocator,
    stdin: std.Io.File,
    stdout: std.Io.File,
    stderr: std.Io.File,
) !void {
    return handleAuthWithOptions(args, allocator, stdin, stdout, stderr, PRODUCTION_AUTH_SERVER_OPTIONS);
}

/// Drive the auth protocol runtime in-process to service `makai auth providers`
/// and `makai auth login`. Output shape matches the pre-M-013 CLI so existing
/// scripts/tooling continue to work unchanged. Tests inject options that
/// disable real OAuth and credential persistence.
fn handleAuthWithOptions(
    args: []const []const u8,
    allocator: std.mem.Allocator,
    stdin: std.Io.File,
    stdout: std.Io.File,
    stderr: std.Io.File,
    server_options: auth_protocol_server.AuthProtocolServer.Options,
) !void {
    if (args.len == 0) {
        return error.InvalidArgument;
    }

    var file_io = auth_cli.FileIo.init(allocator, stdin, stdout, stderr);
    defer file_io.deinit();
    const io = file_io.io();

    if (std.mem.eql(u8, args[0], "providers")) {
        var json_mode = false;
        if (args.len > 1) {
            if (args.len == 2 and std.mem.eql(u8, args[1], "--json")) {
                json_mode = true;
            } else {
                return error.InvalidArgument;
            }
        }
        try auth_cli.runProvidersCommand(allocator, io, server_options, .{ .json_mode = json_mode });
        return;
    }

    if (std.mem.eql(u8, args[0], "login")) {
        var provider_id: ?[]const u8 = null;
        var json_mode = false;

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--provider")) {
                i += 1;
                if (i >= args.len) return error.InvalidArgument;
                provider_id = args[i];
                continue;
            }
            if (std.mem.eql(u8, args[i], "--json")) {
                json_mode = true;
                continue;
            }
            return error.InvalidArgument;
        }

        const provider = provider_id orelse return error.InvalidArgument;
        try auth_cli.runLoginCommand(allocator, io, server_options, .{
            .provider_id = provider,
            .json_mode = json_mode,
        });
        return;
    }

    return error.InvalidArgument;
}

fn fixtureModel(api: []const u8) ai_types.Model {
    return .{
        .id = "fixture-model",
        .name = "Fixture Model",
        .api = api,
        .provider = "fixture",
        .base_url = "https://fixture.invalid",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 16_384,
        .max_tokens = 2_048,
    };
}

fn makeFixtureStream(
    allocator: std.mem.Allocator,
    fail_with_error: bool,
) !*event_stream.AssistantMessageEventStream {
    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);
    s.owns_events = true;
    s.clone_event_fn = ai_types.cloneAssistantMessageEvent;

    if (fail_with_error) {
        s.completeWithError("fixture stream failure");
        s.markThreadDone();
        return s;
    }

    try s.push(.keepalive);
    s.complete(.{
        .content = &.{},
        .api = "fixture-api",
        .provider = "fixture-provider",
        .model = "fixture-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = compat.time.nowMillis(),
    });
    s.markThreadDone();
    return s;
}

fn fixtureOkStream(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = context;
    _ = options;
    return makeFixtureStream(allocator, false);
}

fn fixtureOkStreamSimple(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = context;
    _ = options;
    return makeFixtureStream(allocator, false);
}

fn fixtureErrorStream(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = context;
    _ = options;
    return makeFixtureStream(allocator, true);
}

fn fixtureErrorStreamSimple(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = context;
    _ = options;
    return makeFixtureStream(allocator, true);
}

fn fixtureToolUseStream(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = context;
    _ = options;

    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);
    s.owns_events = true;
    s.clone_event_fn = ai_types.cloneAssistantMessageEvent;
    // Every turn requests tools without emitting any calls, so the loop
    // exhausts the iteration cap immediately.
    s.complete(.{
        .content = &.{},
        .api = "fixture-tooluse-api",
        .provider = "fixture",
        .model = "fixture-model",
        .usage = .{},
        .stop_reason = .tool_use,
        .timestamp = compat.time.nowMillis(),
    });
    s.markThreadDone();
    return s;
}

fn fixtureToolUseStreamSimple(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = options;
    return fixtureToolUseStream(model, context, null, allocator);
}

fn makeProviderPingEnvelopeJson(allocator: std.mem.Allocator) ![]u8 {
    const env = ProviderProtocolTypes.Envelope{
        .stream_id = ProviderProtocolTypes.generateUlid(),
        .message_id = ProviderProtocolTypes.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .ping,
    };
    return provider_protocol_envelope.serializeEnvelope(env, allocator);
}

fn makeAgentPingEnvelopeJson(allocator: std.mem.Allocator) ![]u8 {
    const env = AgentProtocolTypes.Envelope{
        .session_id = AgentProtocolTypes.generateSessionId(),
        .message_id = AgentProtocolTypes.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .ping,
    };
    return agent_protocol_envelope.serializeEnvelope(env, allocator);
}

fn makeAgentStartEnvelopeJson(
    allocator: std.mem.Allocator,
    session_id: AgentProtocolTypes.SessionId,
    model_ref_text: []const u8,
) ![]u8 {
    const config_json = try std.fmt.allocPrint(allocator, "{{\"model_ref\":\"{s}\",\"tools\":[]}}", .{model_ref_text});
    var env = AgentProtocolTypes.Envelope{
        .session_id = session_id,
        .message_id = AgentProtocolTypes.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_start = .{
            .config_json = config_json,
            .session_id = session_id,
        } },
    };
    defer env.deinit(allocator);
    return agent_protocol_envelope.serializeEnvelope(env, allocator);
}

fn makeAgentMessageEnvelopeJson(
    allocator: std.mem.Allocator,
    session_id: AgentProtocolTypes.SessionId,
    model_ref_text: []const u8,
) ![]u8 {
    const message_json = try std.fmt.allocPrint(
        allocator,
        "{{\"model_ref\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"hello\"}}],\"tools\":[]}}",
        .{model_ref_text},
    );
    var env = AgentProtocolTypes.Envelope{
        .session_id = session_id,
        .message_id = AgentProtocolTypes.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_message = .{
            .session_id = session_id,
            .message_json = message_json,
            .options_json = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "{\"api_key\":\"test-key\"}")),
        } },
    };
    defer env.deinit(allocator);
    return agent_protocol_envelope.serializeEnvelope(env, allocator);
}

fn makeAgentMessageEnvelopeJsonWithOptions(
    allocator: std.mem.Allocator,
    session_id: AgentProtocolTypes.SessionId,
    model_ref_text: []const u8,
    options_json: []const u8,
) ![]u8 {
    const message_json = try std.fmt.allocPrint(
        allocator,
        "{{\"model_ref\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"hello\"}}],\"tools\":[],\"options\":{s}}}",
        .{ model_ref_text, options_json },
    );
    var env = AgentProtocolTypes.Envelope{
        .session_id = session_id,
        .message_id = AgentProtocolTypes.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_message = .{
            .session_id = session_id,
            .message_json = message_json,
            .options_json = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "{\"api_key\":\"test-key\"}")),
        } },
    };
    defer env.deinit(allocator);
    return agent_protocol_envelope.serializeEnvelope(env, allocator);
}

fn makeAuthProvidersRequestEnvelopeJson(allocator: std.mem.Allocator, flow_id: AuthProtocolTypes.Ulid, sequence: u64) ![]u8 {
    const env = AuthProtocolTypes.Envelope{
        .stream_id = flow_id,
        .message_id = AuthProtocolTypes.generateUlid(),
        .sequence = sequence,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .auth_providers_request = .{} },
    };
    return auth_protocol_envelope.serializeEnvelope(env, allocator);
}

fn makeAuthLoginStartEnvelopeJson(
    allocator: std.mem.Allocator,
    flow_id: AuthProtocolTypes.Ulid,
    sequence: u64,
    provider_id: []const u8,
) ![]u8 {
    var env = AuthProtocolTypes.Envelope{
        .stream_id = flow_id,
        .message_id = AuthProtocolTypes.generateUlid(),
        .sequence = sequence,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .auth_login_start = .{
            .provider_id = AuthProtocolTypes.OwnedSlice(u8).initOwned(try allocator.dupe(u8, provider_id)),
        } },
    };
    defer env.deinit(allocator);
    return auth_protocol_envelope.serializeEnvelope(env, allocator);
}

fn makeAuthPromptResponseEnvelopeJson(
    allocator: std.mem.Allocator,
    flow_id: AuthProtocolTypes.Ulid,
    sequence: u64,
    prompt_id: []const u8,
    answer: []const u8,
) ![]u8 {
    var env = AuthProtocolTypes.Envelope{
        .stream_id = flow_id,
        .message_id = AuthProtocolTypes.generateUlid(),
        .sequence = sequence,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .auth_prompt_response = .{
            .flow_id = flow_id,
            .prompt_id = AuthProtocolTypes.OwnedSlice(u8).initOwned(try allocator.dupe(u8, prompt_id)),
            .answer = AuthProtocolTypes.OwnedSlice(u8).initOwned(try allocator.dupe(u8, answer)),
        } },
    };
    defer env.deinit(allocator);
    return auth_protocol_envelope.serializeEnvelope(env, allocator);
}

fn makeAuthCancelEnvelopeJson(
    allocator: std.mem.Allocator,
    flow_id: AuthProtocolTypes.Ulid,
    sequence: u64,
) ![]u8 {
    const env = AuthProtocolTypes.Envelope{
        .stream_id = flow_id,
        .message_id = AuthProtocolTypes.generateUlid(),
        .sequence = sequence,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .auth_cancel = .{
            .flow_id = flow_id,
        } },
    };
    return auth_protocol_envelope.serializeEnvelope(env, allocator);
}

fn makeProviderStreamRequestEnvelopeJson(
    allocator: std.mem.Allocator,
    api: []const u8,
) ![]u8 {
    var env = ProviderProtocolTypes.Envelope{
        .stream_id = ProviderProtocolTypes.generateUlid(),
        .message_id = ProviderProtocolTypes.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{
            .stream_request = .{
                .model = fixtureModel(api),
                .context = .{ .messages = &.{} },
                // Provide an explicit api_key so the binary's credential resolver
                // (M-006) does not reject the request with `auth_required`. The
                // fixture providers do not validate the key value.
                .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-fixture-key") },
            },
        },
    };
    defer env.deinit(allocator);
    return provider_protocol_envelope.serializeEnvelope(env, allocator);
}

fn pumpAndDrainStdioLoop(
    stdio_loop: *StdioProtocolLoop,
    outbound: *std.ArrayList([]const u8),
) !void {
    _ = try stdio_loop.pumpBackground();
    _ = try stdio_loop.drainOutbound(outbound);
}

test "stdio protocol loop decodes and dispatches provider and agent envelopes" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    const provider_ping = try makeProviderPingEnvelopeJson(allocator);
    defer allocator.free(provider_ping);

    try std.testing.expect(try stdio_loop.dispatchInboundLine(provider_ping));
    _ = try stdio_loop.pumpBackground();
    _ = try stdio_loop.drainOutbound(&outbound);
    try std.testing.expectEqual(@as(usize, 1), outbound.items.len);
    {
        var env = try provider_protocol_envelope.deserializeEnvelope(outbound.items[0], allocator);
        defer env.deinit(allocator);
        try std.testing.expect(env.payload == .pong);
    }
    clearOwnedLines(allocator, &outbound);

    const agent_ping = try makeAgentPingEnvelopeJson(allocator);
    defer allocator.free(agent_ping);

    try std.testing.expect(try stdio_loop.dispatchInboundLine(agent_ping));
    _ = try stdio_loop.pumpBackground();
    _ = try stdio_loop.drainOutbound(&outbound);
    try std.testing.expectEqual(@as(usize, 1), outbound.items.len);
    {
        var env = try agent_protocol_envelope.deserializeEnvelope(outbound.items[0], allocator);
        defer env.deinit(allocator);
        try std.testing.expect(env.payload == .pong);
    }
}

test "stdio protocol loop decodes and dispatches auth providers request and emits ack then response" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    const flow_id = AuthProtocolTypes.generateUlid();
    const request = try makeAuthProvidersRequestEnvelopeJson(allocator, flow_id, 1);
    defer allocator.free(request);

    try std.testing.expect(try stdio_loop.dispatchInboundLine(request));

    for (0..TEST_AUTH_POLL_ITERS_SHORT) |_| {
        try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
        if (outbound.items.len >= 2) break;
        compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
    }

    try std.testing.expectEqual(@as(usize, 2), outbound.items.len);

    var ack_env = try auth_protocol_envelope.deserializeEnvelope(outbound.items[0], allocator);
    defer ack_env.deinit(allocator);
    try std.testing.expect(ack_env.payload == .ack);

    var response_env = try auth_protocol_envelope.deserializeEnvelope(outbound.items[1], allocator);
    defer response_env.deinit(allocator);
    try std.testing.expect(response_env.payload == .auth_providers_response);
    try std.testing.expect(response_env.payload.auth_providers_response.providers.slice().len >= 1);
}

test "stdio auth login flow supports prompt loop terminal ordering and no secret leakage" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    const flow_id = AuthProtocolTypes.generateUlid();
    const login_start = try makeAuthLoginStartEnvelopeJson(allocator, flow_id, 1, "test-fixture");
    defer allocator.free(login_start);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(login_start));

    var next_client_sequence: u64 = 2;
    var prompt_count: usize = 0;
    var saw_auth_url = false;
    var saw_progress = false;
    var saw_success = false;
    var saw_secret_leak = false;
    var success_index: ?usize = null;
    var result_index: ?usize = null;
    var result_status: ?AuthProtocolTypes.AuthLoginStatus = null;
    var order_counter: usize = 0;

    for (0..TEST_AUTH_POLL_ITERS_DEFAULT) |_| {
        try pumpAndDrainStdioLoop(&stdio_loop, &outbound);

        if (outbound.items.len == 0) {
            compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
            continue;
        }

        for (outbound.items) |line| {
            if (std.mem.find(u8, line, "fixture-refresh-token") != null or
                std.mem.find(u8, line, "fixture-access-token") != null)
            {
                saw_secret_leak = true;
            }

            var env = auth_protocol_envelope.deserializeEnvelope(line, allocator) catch continue;
            defer env.deinit(allocator);

            switch (env.payload) {
                .auth_event => |event| {
                    switch (event) {
                        .auth_url => saw_auth_url = true,
                        .progress => saw_progress = true,
                        .prompt => |prompt| {
                            const answer = if (prompt_count == 0) "bad-code" else "ok";
                            const prompt_response = try makeAuthPromptResponseEnvelopeJson(
                                allocator,
                                flow_id,
                                next_client_sequence,
                                prompt.prompt_id.slice(),
                                answer,
                            );
                            defer allocator.free(prompt_response);
                            try std.testing.expect(try stdio_loop.dispatchInboundLine(prompt_response));
                            next_client_sequence += 1;
                            prompt_count += 1;
                        },
                        .success => {
                            saw_success = true;
                            if (success_index == null) {
                                success_index = order_counter;
                                order_counter += 1;
                            }
                        },
                        .@"error" => {
                            if (success_index == null) {
                                success_index = order_counter;
                                order_counter += 1;
                            }
                        },
                    }
                },
                .auth_login_result => |result| {
                    result_status = result.status;
                    if (result_index == null) {
                        result_index = order_counter;
                        order_counter += 1;
                    }
                },
                else => {},
            }
        }

        clearOwnedLines(allocator, &outbound);

        if (result_index != null) break;
        compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
    }

    try std.testing.expect(!saw_secret_leak);
    try std.testing.expect(saw_auth_url);
    try std.testing.expect(saw_progress);
    try std.testing.expect(prompt_count >= 2);
    try std.testing.expect(saw_success);
    try std.testing.expect(result_status != null);
    try std.testing.expectEqual(AuthProtocolTypes.AuthLoginStatus.success, result_status.?);
    try std.testing.expect(success_index != null);
    try std.testing.expect(result_index != null);
    try std.testing.expect(success_index.? < result_index.?);
}

test "stdio auth login flow cancellation emits cancelled result and ignores late prompt responses" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    const flow_id = AuthProtocolTypes.generateUlid();
    const login_start = try makeAuthLoginStartEnvelopeJson(allocator, flow_id, 1, "test-fixture");
    defer allocator.free(login_start);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(login_start));

    var next_client_sequence: u64 = 2;
    var cancel_sent = false;
    var saved_prompt_id: ?[]u8 = null;
    defer if (saved_prompt_id) |prompt_id| allocator.free(prompt_id);
    var saw_cancelled_result = false;

    for (0..TEST_AUTH_POLL_ITERS_DEFAULT) |_| {
        try pumpAndDrainStdioLoop(&stdio_loop, &outbound);

        if (outbound.items.len == 0) {
            compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
            continue;
        }

        for (outbound.items) |line| {
            var env = auth_protocol_envelope.deserializeEnvelope(line, allocator) catch continue;
            defer env.deinit(allocator);

            switch (env.payload) {
                .auth_event => |event| {
                    switch (event) {
                        .prompt => |prompt| {
                            if (!cancel_sent) {
                                if (saved_prompt_id == null) {
                                    saved_prompt_id = try allocator.dupe(u8, prompt.prompt_id.slice());
                                }
                                const cancel = try makeAuthCancelEnvelopeJson(allocator, flow_id, next_client_sequence);
                                defer allocator.free(cancel);
                                try std.testing.expect(try stdio_loop.dispatchInboundLine(cancel));
                                next_client_sequence += 1;
                                cancel_sent = true;
                            }
                        },
                        else => {},
                    }
                },
                .auth_login_result => |result| {
                    if (result.status == .cancelled) {
                        saw_cancelled_result = true;
                    }
                },
                else => {},
            }
        }

        clearOwnedLines(allocator, &outbound);

        if (saw_cancelled_result) break;
        compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
    }

    try std.testing.expect(cancel_sent);
    try std.testing.expect(saw_cancelled_result);
    try std.testing.expect(saved_prompt_id != null);

    const late_prompt_response = try makeAuthPromptResponseEnvelopeJson(
        allocator,
        flow_id,
        next_client_sequence,
        saved_prompt_id.?,
        "late-answer",
    );
    defer allocator.free(late_prompt_response);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(late_prompt_response));

    var late_terminal_messages: usize = 0;
    for (0..TEST_AUTH_POLL_ITERS_POST_CANCEL) |_| {
        try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
        for (outbound.items) |line| {
            var env = auth_protocol_envelope.deserializeEnvelope(line, allocator) catch continue;
            defer env.deinit(allocator);

            switch (env.payload) {
                .auth_event, .auth_login_result => late_terminal_messages += 1,
                else => {},
            }
        }
        clearOwnedLines(allocator, &outbound);
        compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
    }

    try std.testing.expectEqual(@as(usize, 0), late_terminal_messages);
}

test "stdio auth login failure emits auth_event.error before auth_login_result" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    const flow_id = AuthProtocolTypes.generateUlid();
    const login_start = try makeAuthLoginStartEnvelopeJson(allocator, flow_id, 1, "unknown-provider");
    defer allocator.free(login_start);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(login_start));

    var error_index: ?usize = null;
    var result_index: ?usize = null;
    var result_status: ?AuthProtocolTypes.AuthLoginStatus = null;
    var order_counter: usize = 0;

    for (0..TEST_AUTH_POLL_ITERS_FAILURE) |_| {
        try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
        for (outbound.items) |line| {
            var env = auth_protocol_envelope.deserializeEnvelope(line, allocator) catch continue;
            defer env.deinit(allocator);

            switch (env.payload) {
                .auth_event => |event| {
                    if (event == .@"error" and error_index == null) {
                        error_index = order_counter;
                        order_counter += 1;
                    }
                },
                .auth_login_result => |result| {
                    result_status = result.status;
                    if (result_index == null) {
                        result_index = order_counter;
                        order_counter += 1;
                    }
                },
                else => {},
            }
        }
        clearOwnedLines(allocator, &outbound);
        if (result_index != null) break;
        compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
    }

    try std.testing.expect(error_index != null);
    try std.testing.expect(result_index != null);
    try std.testing.expect(error_index.? < result_index.?);
    try std.testing.expect(result_status != null);
    try std.testing.expectEqual(AuthProtocolTypes.AuthLoginStatus.failed, result_status.?);
}

test "stdio protocol loop rejects ambiguous dispatch envelope with both ids" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    const ambiguous =
        \\{"type":"ping","stream_id":"0H248H248H248H248H248H248H","session_id":"test-session","message_id":"1K6CSK6CSK6CSK6CSK6CSK6CSK","sequence":1,"timestamp":1760000000000,"version":1,"payload":{}}
    ;

    try std.testing.expect(!(try stdio_loop.dispatchInboundLine(ambiguous)));

    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }
    _ = try stdio_loop.drainOutbound(&outbound);
    try std.testing.expectEqual(@as(usize, 0), outbound.items.len);
}

test "stdio protocol loop rejects malformed json dispatch line" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    try std.testing.expect(!(try stdio_loop.dispatchInboundLine("{not-json")));

    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }
    _ = try stdio_loop.drainOutbound(&outbound);
    try std.testing.expectEqual(@as(usize, 0), outbound.items.len);
}

test "stdio protocol loop ignores malformed agent_stop for cancellation" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    const session_id = AgentProtocolTypes.generateSessionId();

    const stream = try allocator.create(agent_loop.AgentEventStream);
    stream.* = agent_loop.AgentEventStream.init(allocator);

    const context = try allocator.create(agent_loop.AgentContext);
    context.* = agent_loop.AgentContext.init(allocator);

    const prompts = try allocator.alloc(ai_types.Message, 0);
    const cancel_flag = try allocator.create(std.atomic.Value(bool));
    cancel_flag.* = std.atomic.Value(bool).init(false);
    const tool_executor = try allocator.create(StdioAgentToolExecutor);
    tool_executor.* = .{ .bridge = &stdio_loop.tool_bridge, .session_id = session_id };

    try stdio_loop.active_agent_runs.append(allocator, .{
        .session_id = session_id,
        .stream = stream,
        .context = context,
        .model = try modelFromCanonicalRef(allocator, "fixture/fixture-ok-api@fixture-model"),
        .prompts = prompts,
        .tools = try allocator.alloc(agent_loop.AgentTool, 0),
        .cancel_flag = cancel_flag,
        .tool_executor = tool_executor,
    });

    const session_text = try AgentProtocolTypes.sessionIdToString(session_id, allocator);
    defer allocator.free(session_text);
    const malformed_stop = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"agent_stop\",\"session_id\":\"{s}\"}}",
        .{session_text},
    );
    defer allocator.free(malformed_stop);

    try std.testing.expect(!(try stdio_loop.dispatchInboundLine(malformed_stop)));
    try std.testing.expect(!cancel_flag.load(.acquire));
}

test "prepareAgentRun preserves requested tools" {
    const allocator = std.testing.allocator;
    const session_id = AgentProtocolTypes.generateSessionId();

    var pending = agent_protocol_server.PendingAgentMessage{
        .session_id = session_id,
        .message_json = try allocator.dupe(u8,
            \\{"model_ref":"fixture/fixture-ok-api@fixture-model","messages":[{"role":"user","content":"hello"}],"tools":[{"name":"read_file","description":"Read a file","parameters_schema":{"type":"object","properties":{"path":{"type":"string"}}}}]}
        ),
        .options_json = try allocator.dupe(u8, ""),
        .config_json = try allocator.dupe(u8, "{}"),
        .system_prompt = try allocator.dupe(u8, ""),
    };
    defer pending.deinit(allocator);

    var prepared = try prepareAgentRun(allocator, pending);
    defer prepared.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), prepared.tools.len);
    try std.testing.expectEqualStrings("read_file", prepared.tools[0].name);
    try std.testing.expectEqualStrings("Read a file", prepared.tools[0].description);
    try std.testing.expect(std.mem.find(u8, prepared.tools[0].parameters_schema_json, "\"path\"") != null);
}

test "prepareAgentRun preserves remote tool approval requirement" {
    const allocator = std.testing.allocator;
    const session_id = AgentProtocolTypes.generateSessionId();

    var pending = agent_protocol_server.PendingAgentMessage{
        .session_id = session_id,
        .message_json = try allocator.dupe(u8,
            \\{"model_ref":"fixture/fixture-ok-api@fixture-model","messages":[{"role":"user","content":"hello"}],"tools":[{"name":"shell_execute","description":"Run shell","parameters_schema_json":"{}","requires_approval":true}]}
        ),
        .options_json = try allocator.dupe(u8, ""),
        .config_json = try allocator.dupe(u8, "{}"),
        .system_prompt = try allocator.dupe(u8, ""),
    };
    defer pending.deinit(allocator);

    var prepared = try prepareAgentRun(allocator, pending);
    defer prepared.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), prepared.tools.len);
    try std.testing.expect(prepared.tools[0].approval_fn != null);
    try std.testing.expectEqual(agent_bridge.ToolApprovalDecision.reject, prepared.tools[0].approval_fn.?(prepared.tools[0].approval_ctx, .{
        .tool_call_id = "call-1",
        .tool_name = "shell_execute",
        .args_json = "{}",
    }));
    try std.testing.expectError(error.RemoteToolApprovalRequired, prepared.tools[0].execute("call-1", "{}", null, null, null, allocator));
}

test "prepareAgentRun parses SDK-style request options from message json" {
    const allocator = std.testing.allocator;
    const session_id = AgentProtocolTypes.generateSessionId();

    var pending = agent_protocol_server.PendingAgentMessage{
        .session_id = session_id,
        .message_json = try allocator.dupe(u8,
            \\{"model_ref":"fixture/fixture-ok-api@fixture-model","messages":[{"role":"user","content":"hello"}],"options":{"temperature":0.25,"max_tokens":64,"max_iterations":7}}
        ),
        .options_json = try allocator.dupe(u8, ""),
        .config_json = try allocator.dupe(u8, "{}"),
        .system_prompt = try allocator.dupe(u8, ""),
    };
    defer pending.deinit(allocator);

    var prepared = try prepareAgentRun(allocator, pending);
    defer prepared.deinit(allocator);

    try std.testing.expectEqual(@as(?f32, 0.25), prepared.options.temperature);
    try std.testing.expectEqual(@as(?u32, 64), prepared.options.max_tokens);
    try std.testing.expectEqual(@as(?u32, 7), prepared.options.max_iterations);
}

test "prepareAgentRun reads thinking level from stdio config and allows message override" {
    const allocator = std.testing.allocator;
    const session_id = AgentProtocolTypes.generateSessionId();

    var from_config = agent_protocol_server.PendingAgentMessage{
        .session_id = session_id,
        .message_json = try allocator.dupe(u8,
            \\{"model_ref":"fixture/fixture-ok-api@fixture-model","messages":[{"role":"user","content":"hello"}]}
        ),
        .options_json = try allocator.dupe(u8, ""),
        .config_json = try allocator.dupe(u8, "{\"thinking_level\":\"high\"}"),
        .system_prompt = try allocator.dupe(u8, ""),
    };
    defer from_config.deinit(allocator);

    var prepared_config = try prepareAgentRun(allocator, from_config);
    defer prepared_config.deinit(allocator);
    try std.testing.expectEqual(ai_types.ThinkingLevel.high, prepared_config.options.thinking_level);

    var from_message = agent_protocol_server.PendingAgentMessage{
        .session_id = session_id,
        .message_json = try allocator.dupe(u8,
            \\{"model_ref":"fixture/fixture-ok-api@fixture-model","messages":[{"role":"user","content":"hello"}],"options":{"thinking_level":"off"}}
        ),
        .options_json = try allocator.dupe(u8, ""),
        .config_json = try allocator.dupe(u8, "{\"thinking_level\":\"high\"}"),
        .system_prompt = try allocator.dupe(u8, ""),
    };
    defer from_message.deinit(allocator);

    var prepared_message = try prepareAgentRun(allocator, from_message);
    defer prepared_message.deinit(allocator);
    try std.testing.expectEqual(ai_types.ThinkingLevel.off, prepared_message.options.thinking_level);

    var from_legacy_minimal = agent_protocol_server.PendingAgentMessage{
        .session_id = session_id,
        .message_json = try allocator.dupe(u8,
            \\{"model_ref":"fixture/fixture-ok-api@fixture-model","messages":[{"role":"user","content":"hello"}]}
        ),
        .options_json = try allocator.dupe(u8, ""),
        .config_json = try allocator.dupe(u8, "{\"thinking_level\":\"minimal\"}"),
        .system_prompt = try allocator.dupe(u8, ""),
    };
    defer from_legacy_minimal.deinit(allocator);

    var prepared_minimal = try prepareAgentRun(allocator, from_legacy_minimal);
    defer prepared_minimal.deinit(allocator);
    try std.testing.expectEqual(ai_types.ThinkingLevel.low, prepared_minimal.options.thinking_level);

    var from_xhigh = agent_protocol_server.PendingAgentMessage{
        .session_id = session_id,
        .message_json = try allocator.dupe(u8,
            \\{"model_ref":"fixture/fixture-ok-api@fixture-model","messages":[{"role":"user","content":"hello"}],"options":{"thinking_level":"xhigh"}}
        ),
        .options_json = try allocator.dupe(u8, ""),
        .config_json = try allocator.dupe(u8, "{}"),
        .system_prompt = try allocator.dupe(u8, ""),
    };
    defer from_xhigh.deinit(allocator);

    var prepared_xhigh = try prepareAgentRun(allocator, from_xhigh);
    defer prepared_xhigh.deinit(allocator);
    try std.testing.expectEqual(ai_types.ThinkingLevel.xhigh, prepared_xhigh.options.thinking_level);
}

test "prepareAgentRun normalizes gpt-5-pro thinking level to high" {
    const allocator = std.testing.allocator;
    const session_id = AgentProtocolTypes.generateSessionId();

    var explicit_low = agent_protocol_server.PendingAgentMessage{
        .session_id = session_id,
        .message_json = try allocator.dupe(u8,
            \\{"model_ref":"openai/openai-responses@gpt-5-pro","messages":[{"role":"user","content":"hello"}],"options":{"thinking_level":"low"}}
        ),
        .options_json = try allocator.dupe(u8, ""),
        .config_json = try allocator.dupe(u8, "{}"),
        .system_prompt = try allocator.dupe(u8, ""),
    };
    defer explicit_low.deinit(allocator);

    var prepared_low = try prepareAgentRun(allocator, explicit_low);
    defer prepared_low.deinit(allocator);
    // GPT-5 Pro only supports the high effort; lower explicit values are
    // normalized instead of forwarded for the API to reject.
    try std.testing.expectEqual(ai_types.ThinkingLevel.high, prepared_low.options.thinking_level);

    var unset = agent_protocol_server.PendingAgentMessage{
        .session_id = session_id,
        .message_json = try allocator.dupe(u8,
            \\{"model_ref":"openai/openai-responses@gpt-5-pro","messages":[{"role":"user","content":"hello"}]}
        ),
        .options_json = try allocator.dupe(u8, ""),
        .config_json = try allocator.dupe(u8, "{}"),
        .system_prompt = try allocator.dupe(u8, ""),
    };
    defer unset.deinit(allocator);

    var prepared_unset = try prepareAgentRun(allocator, unset);
    defer prepared_unset.deinit(allocator);
    try std.testing.expectEqual(ai_types.ThinkingLevel.high, prepared_unset.options.thinking_level);
}

test "parseToolResultHistoryMessage preserves structured tool_result content" {
    const allocator = std.testing.allocator;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"role":"tool","content":[{"type":"tool_result","tool_call_id":"call-1","tool_name":"lookup","content":"found item","details_json":"{\"ok\":true}","is_error":true}]}
    , .{});
    defer parsed.deinit();

    var message = try parseToolResultHistoryMessage(allocator, parsed.value.object);
    defer message.deinit(allocator);

    try std.testing.expect(message == .tool_result);
    try std.testing.expectEqualStrings("call-1", message.tool_result.tool_call_id);
    try std.testing.expectEqualStrings("lookup", message.tool_result.tool_name);
    try std.testing.expectEqual(true, message.tool_result.is_error);
    try std.testing.expectEqualStrings("{\"ok\":true}", message.tool_result.details_json.slice());
    try std.testing.expectEqual(@as(usize, 1), message.tool_result.content.len);
    try std.testing.expect(message.tool_result.content[0] == .text);
    try std.testing.expectEqualStrings("found item", message.tool_result.content[0].text.text);
}

test "parseAssistantHistoryMessage preserves image content blocks" {
    const allocator = std.testing.allocator;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"role":"assistant","content":[{"type":"image","data":"aW1hZ2U=","mime_type":"image/png"}]}
    , .{});
    defer parsed.deinit();

    var message = try parseAssistantHistoryMessage(allocator, parsed.value.object);
    defer message.deinit(allocator);

    try std.testing.expect(message == .assistant);
    try std.testing.expectEqual(@as(usize, 1), message.assistant.content.len);
    try std.testing.expect(message.assistant.content[0] == .image);
    try std.testing.expectEqualStrings("aW1hZ2U=", message.assistant.content[0].image.data);
    try std.testing.expectEqualStrings("image/png", message.assistant.content[0].image.mime_type);
}

test "stdio tool bridge publishes tool requests and consumes tool results" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    const session_id = AgentProtocolTypes.generateSessionId();
    const start_req = try makeAgentStartEnvelopeJson(allocator, session_id, "fixture/fixture-ok-api@fixture-model");
    defer allocator.free(start_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(start_req));
    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }
    try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
    clearOwnedLines(allocator, &outbound);

    try stdio_loop.tool_bridge.enqueueRequest(allocator, session_id, "call-1", "lookup", "{\"query\":\"zig\"}");
    try std.testing.expectEqual(@as(usize, 1), try stdio_loop.publishPendingToolRequests());
    _ = try stdio_loop.pumpBackground();
    _ = try stdio_loop.drainOutbound(&outbound);
    try std.testing.expectEqual(@as(usize, 1), outbound.items.len);
    try std.testing.expect(std.mem.find(u8, outbound.items[0], "\"type\":\"tool_execute\"") != null);
    try std.testing.expect(std.mem.find(u8, outbound.items[0], "\"sequence\":0") == null);

    var unsolicited_env = AgentProtocolTypes.Envelope{
        .session_id = session_id,
        .message_id = AgentProtocolTypes.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .tool_result = .{
            .tool_call_id = try allocator.dupe(u8, "unknown-call"),
            .result_json = try allocator.dupe(u8, "[{\"type\":\"text\",\"text\":\"ignored\"}]"),
        } },
    };
    defer unsolicited_env.deinit(allocator);
    const unsolicited_json = try agent_protocol_envelope.serializeEnvelope(unsolicited_env, allocator);
    defer allocator.free(unsolicited_json);
    try std.testing.expect(!(try stdio_loop.dispatchInboundLine(unsolicited_json)));
    try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.results.items.len);

    var wrong_session_env = AgentProtocolTypes.Envelope{
        .session_id = AgentProtocolTypes.generateSessionId(),
        .message_id = AgentProtocolTypes.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .tool_result = .{
            .tool_call_id = try allocator.dupe(u8, "call-1"),
            .result_json = try allocator.dupe(u8, "[{\"type\":\"text\",\"text\":\"wrong\"}]"),
        } },
    };
    defer wrong_session_env.deinit(allocator);
    const wrong_session_json = try agent_protocol_envelope.serializeEnvelope(wrong_session_env, allocator);
    defer allocator.free(wrong_session_json);
    try std.testing.expect(!(try stdio_loop.dispatchInboundLine(wrong_session_json)));
    try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.results.items.len);

    var result_env = AgentProtocolTypes.Envelope{
        .session_id = session_id,
        .message_id = AgentProtocolTypes.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .tool_result = .{
            .tool_call_id = try allocator.dupe(u8, "call-1"),
            .result_json = try allocator.dupe(u8, "[{\"type\":\"text\",\"text\":\"done\"}]"),
        } },
    };
    defer result_env.deinit(allocator);
    const result_json = try agent_protocol_envelope.serializeEnvelope(result_env, allocator);
    defer allocator.free(result_json);

    try std.testing.expect(try stdio_loop.dispatchInboundLine(result_json));
    try std.testing.expect(!(try stdio_loop.dispatchInboundLine(result_json)));
    try std.testing.expectEqual(@as(usize, 1), stdio_loop.tool_bridge.results.items.len);
    var result = stdio_loop.tool_bridge.popResult(allocator, session_id, "call-1").?;
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("[{\"type\":\"text\",\"text\":\"done\"}]", result.result_json);
    try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.results.items.len);
    try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.in_flight.items.len);
}

test "stdio tool bridge clears queued and in-flight calls when cancelling session" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    const session_id = AgentProtocolTypes.generateSessionId();
    const start_req = try makeAgentStartEnvelopeJson(allocator, session_id, "fixture/fixture-ok-api@fixture-model");
    defer allocator.free(start_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(start_req));
    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }
    try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
    clearOwnedLines(allocator, &outbound);

    try stdio_loop.tool_bridge.enqueueRequest(allocator, session_id, "queued-call", "lookup", "{}");
    try stdio_loop.tool_bridge.markInFlight(allocator, session_id, "running-call");
    try std.testing.expectEqual(@as(usize, 1), stdio_loop.tool_bridge.requests.items.len);
    try std.testing.expectEqual(@as(usize, 1), stdio_loop.tool_bridge.in_flight.items.len);

    stdio_loop.cancelAgentRun(session_id);
    try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.requests.items.len);
    try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.in_flight.items.len);

    var late_env = AgentProtocolTypes.Envelope{
        .session_id = session_id,
        .message_id = AgentProtocolTypes.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .tool_result = .{
            .tool_call_id = try allocator.dupe(u8, "running-call"),
            .result_json = try allocator.dupe(u8, "[{\"type\":\"text\",\"text\":\"late\"}]"),
        } },
    };
    defer late_env.deinit(allocator);
    const late_json = try agent_protocol_envelope.serializeEnvelope(late_env, allocator);
    defer allocator.free(late_json);
    try std.testing.expect(!(try stdio_loop.dispatchInboundLine(late_json)));
    try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.results.items.len);
}

test "stdio tool bridge drops queued requests for stopped sessions" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    const session_id = AgentProtocolTypes.generateSessionId();
    try stdio_loop.tool_bridge.enqueueRequest(allocator, session_id, "call-1", "lookup", "{}");
    try std.testing.expectEqual(@as(usize, 0), try stdio_loop.publishPendingToolRequests());
    try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.requests.items.len);
    try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.in_flight.items.len);
}

test "stdio protocol loop forwards provider event result and error envelopes" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerApiProvider(.{
        .api = "fixture-ok-api",
        .stream = fixtureOkStream,
        .stream_simple = fixtureOkStreamSimple,
    }, "test-fixtures");
    try registry.registerApiProvider(.{
        .api = "fixture-error-api",
        .stream = fixtureErrorStream,
        .stream_simple = fixtureErrorStreamSimple,
    }, "test-fixtures");

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    const ok_req = try makeProviderStreamRequestEnvelopeJson(allocator, "fixture-ok-api");
    defer allocator.free(ok_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(ok_req));
    _ = try stdio_loop.pumpBackground();
    _ = try stdio_loop.drainOutbound(&outbound);

    const err_req = try makeProviderStreamRequestEnvelopeJson(allocator, "fixture-error-api");
    defer allocator.free(err_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(err_req));
    _ = try stdio_loop.pumpBackground();
    _ = try stdio_loop.drainOutbound(&outbound);

    var ack_count: usize = 0;
    var saw_event = false;
    var saw_result = false;
    var saw_stream_error = false;

    for (outbound.items) |line| {
        var env = try provider_protocol_envelope.deserializeEnvelope(line, allocator);
        defer env.deinit(allocator);

        switch (env.payload) {
            .ack => ack_count += 1,
            .event => saw_event = true,
            .result => saw_result = true,
            .stream_error => saw_stream_error = true,
            else => {},
        }
    }

    try std.testing.expect(ack_count >= 2);
    try std.testing.expect(saw_event);
    try std.testing.expect(saw_result);
    try std.testing.expect(saw_stream_error);
}

test "stdio protocol loop executes agent messages through real agent loop" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerApiProvider(.{
        .api = "fixture-ok-api",
        .stream = fixtureOkStream,
        .stream_simple = fixtureOkStreamSimple,
    }, "test-fixtures");

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    const session_id = AgentProtocolTypes.generateSessionId();
    const model_ref_text = "fixture/fixture-ok-api@fixture-model";

    const start_req = try makeAgentStartEnvelopeJson(allocator, session_id, model_ref_text);
    defer allocator.free(start_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(start_req));
    try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
    try std.testing.expectEqual(@as(usize, 1), outbound.items.len);
    {
        var env = try agent_protocol_envelope.deserializeEnvelope(outbound.items[0], allocator);
        defer env.deinit(allocator);
        try std.testing.expect(env.payload == .agent_started);
    }
    clearOwnedLines(allocator, &outbound);

    const message_req = try makeAgentMessageEnvelopeJson(allocator, session_id, model_ref_text);
    defer allocator.free(message_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(message_req));

    var saw_result_line = false;
    for (0..TEST_AGENT_POLL_ITERS_DEFAULT) |_| {
        try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
        for (outbound.items) |line| {
            if (std.mem.find(u8, line, "\"type\":\"agent_result\"") != null) {
                saw_result_line = true;
                break;
            }
        }
        if (saw_result_line) break;
        compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
    }

    var agent_end_index: ?usize = null;
    var agent_result_index: ?usize = null;
    var saw_agent_result = false;
    for (outbound.items, 0..) |line, index| {
        var env = try agent_protocol_envelope.deserializeEnvelope(line, allocator);
        defer env.deinit(allocator);
        switch (env.payload) {
            .agent_event => {
                if (std.mem.find(u8, env.payload.agent_event, "\"type\":\"agent_end\"") != null) agent_end_index = index;
            },
            .agent_result => {
                agent_result_index = index;
                saw_agent_result = true;
                try std.testing.expect(std.mem.find(u8, env.payload.agent_result, "\"type\":\"result\"") != null);
                try std.testing.expect(std.mem.find(u8, env.payload.agent_result, "\"model\":\"fixture-model\"") != null);
            },
            else => {},
        }
    }

    try std.testing.expect(agent_end_index != null);
    try std.testing.expect(saw_agent_result);
    try std.testing.expect(agent_result_index.? < agent_end_index.?);
    try std.testing.expect(!stdio_loop.hasActiveAgentRuns());
}

test "stdio protocol loop surfaces provider error details in agent events" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerApiProvider(.{
        .api = "fixture-error-api",
        .stream = fixtureErrorStream,
        .stream_simple = fixtureErrorStreamSimple,
    }, "test-fixtures");

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    const session_id = AgentProtocolTypes.generateSessionId();
    const model_ref_text = "fixture/fixture-error-api@fixture-model";

    const start_req = try makeAgentStartEnvelopeJson(allocator, session_id, model_ref_text);
    defer allocator.free(start_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(start_req));
    try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
    try std.testing.expectEqual(@as(usize, 1), outbound.items.len);
    clearOwnedLines(allocator, &outbound);

    const message_req = try makeAgentMessageEnvelopeJson(allocator, session_id, model_ref_text);
    defer allocator.free(message_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(message_req));

    var saw_result_line = false;
    for (0..TEST_AGENT_POLL_ITERS_DEFAULT) |_| {
        try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
        for (outbound.items) |line| {
            if (std.mem.find(u8, line, "\"type\":\"agent_result\"") != null) {
                saw_result_line = true;
                break;
            }
        }
        if (saw_result_line) break;
        compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
    }
    try std.testing.expect(saw_result_line);

    var saw_error_turn_end = false;
    var saw_error_agent_end = false;
    var saw_result_error = false;
    for (outbound.items) |line| {
        var env = try agent_protocol_envelope.deserializeEnvelope(line, allocator);
        defer env.deinit(allocator);
        switch (env.payload) {
            .agent_event => |event_json| {
                if (std.mem.find(u8, event_json, "\"type\":\"turn_end\"") != null) {
                    saw_error_turn_end = std.mem.find(u8, event_json, "\"stop_reason\":\"error\"") != null and
                        std.mem.find(u8, event_json, "\"error_message\":\"fixture stream failure\"") != null;
                }
                if (std.mem.find(u8, event_json, "\"type\":\"agent_end\"") != null) {
                    saw_error_agent_end = std.mem.find(u8, event_json, "\"stop_reason\":\"error\"") != null and
                        std.mem.find(u8, event_json, "\"error_message\":\"fixture stream failure\"") != null;
                }
            },
            .agent_result => |result_json| {
                saw_result_error = std.mem.find(u8, result_json, "\"stop_reason\":\"error\"") != null and
                    std.mem.find(u8, result_json, "\"error_message\":\"fixture stream failure\"") != null;
            },
            else => {},
        }
    }

    try std.testing.expect(saw_error_turn_end);
    try std.testing.expect(saw_error_agent_end);
    try std.testing.expect(saw_result_error);
    try std.testing.expect(!stdio_loop.hasActiveAgentRuns());
}

test "serializeAgentLoopEvent emits error details on turn_end and message_end" {
    const allocator = std.testing.allocator;
    const session_id = AgentProtocolTypes.generateSessionId();

    {
        const event = agent_loop.AgentEvent{ .turn_end = .{
            .message = .{
                .content = &.{},
                .api = "fixture-error-api",
                .provider = "fixture",
                .model = "fixture-model",
                .usage = .{},
                .stop_reason = .@"error",
                .error_message = ai_types.OwnedSlice(u8).initBorrowed("fixture stream failure"),
                .timestamp = 0,
            },
            .tool_results = ai_types.OwnedSlice(ai_types.ToolResultMessage).initBorrowed(&.{}),
        } };
        const json = try serializeAgentLoopEvent(allocator, session_id, event);
        defer allocator.free(json);
        try std.testing.expect(std.mem.find(u8, json, "\"type\":\"turn_end\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"stop_reason\":\"error\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"error_message\":\"fixture stream failure\"") != null);
    }

    {
        const event = agent_loop.AgentEvent{ .message_end = .{
            .message = .{ .assistant = .{
                .content = &.{},
                .api = "fixture-error-api",
                .provider = "fixture",
                .model = "fixture-model",
                .usage = .{},
                .stop_reason = .@"error",
                .error_message = ai_types.OwnedSlice(u8).initBorrowed("invalid anthropic URL"),
                .timestamp = 0,
            } },
        } };
        const json = try serializeAgentLoopEvent(allocator, session_id, event);
        defer allocator.free(json);
        try std.testing.expect(std.mem.find(u8, json, "\"type\":\"message_end\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"stop_reason\":\"error\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"error_message\":\"invalid anthropic URL\"") != null);
    }

    // Successful turns must not carry an empty error_message field.
    {
        const event = agent_loop.AgentEvent{ .turn_end = .{
            .message = .{
                .content = &.{},
                .api = "fixture-ok-api",
                .provider = "fixture",
                .model = "fixture-model",
                .usage = .{},
                .stop_reason = .stop,
                .timestamp = 0,
            },
            .tool_results = ai_types.OwnedSlice(ai_types.ToolResultMessage).initBorrowed(&.{}),
        } };
        const json = try serializeAgentLoopEvent(allocator, session_id, event);
        defer allocator.free(json);
        try std.testing.expect(std.mem.find(u8, json, "\"error_message\"") == null);
    }

    // agent_end derives its outcome from the last assistant message.
    {
        const messages = [_]ai_types.Message{
            .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } },
            .{ .assistant = .{
                .content = &.{},
                .api = "fixture-error-api",
                .provider = "fixture",
                .model = "fixture-model",
                .usage = .{},
                .stop_reason = .@"error",
                .error_message = ai_types.OwnedSlice(u8).initBorrowed("fixture stream failure"),
                .timestamp = 0,
            } },
        };
        const event = agent_loop.AgentEvent{ .agent_end = .{
            .messages = ai_types.OwnedSlice(ai_types.Message).initBorrowed(&messages),
        } };
        const json = try serializeAgentLoopEvent(allocator, session_id, event);
        defer allocator.free(json);
        try std.testing.expect(std.mem.find(u8, json, "\"type\":\"agent_end\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"stop_reason\":\"error\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"error_message\":\"fixture stream failure\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"provider_id\":\"fixture\"") != null);
    }

    // agent_end without an assistant message stays minimal.
    {
        const prompts = [_]ai_types.Message{
            .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } },
        };
        const event = agent_loop.AgentEvent{ .agent_end = .{
            .messages = ai_types.OwnedSlice(ai_types.Message).initBorrowed(&prompts),
        } };
        const json = try serializeAgentLoopEvent(allocator, session_id, event);
        defer allocator.free(json);
        try std.testing.expect(std.mem.find(u8, json, "\"type\":\"agent_end\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"stop_reason\"") == null);
        try std.testing.expect(std.mem.find(u8, json, "\"error_message\"") == null);
    }

    // Iteration-cap termination reports the agent-level reason instead of the
    // final turn's tool_use.
    {
        const messages = [_]ai_types.Message{
            .{ .assistant = .{
                .content = &.{},
                .api = "fixture-ok-api",
                .provider = "fixture",
                .model = "fixture-model",
                .usage = .{},
                .stop_reason = .tool_use,
                .timestamp = 0,
            } },
        };
        const event = agent_loop.AgentEvent{ .agent_end = .{
            .messages = ai_types.OwnedSlice(ai_types.Message).initBorrowed(&messages),
            .termination = .max_turns,
        } };
        const json = try serializeAgentLoopEvent(allocator, session_id, event);
        defer allocator.free(json);
        try std.testing.expect(std.mem.find(u8, json, "\"type\":\"agent_end\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"stop_reason\":\"max_turns\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"stop_reason\":\"tool_use\"") == null);
    }

    // Zero-iteration runs still report the max-turns termination.
    {
        const prompts = [_]ai_types.Message{
            .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } },
        };
        const event = agent_loop.AgentEvent{ .agent_end = .{
            .messages = ai_types.OwnedSlice(ai_types.Message).initBorrowed(&prompts),
            .termination = .max_turns,
        } };
        const json = try serializeAgentLoopEvent(allocator, session_id, event);
        defer allocator.free(json);
        try std.testing.expect(std.mem.find(u8, json, "\"type\":\"agent_end\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"stop_reason\":\"max_turns\"") != null);
    }

    // Cancellation overrides any historical assistant reason and keeps the
    // resolved api alongside the provider for downstream scoping.
    {
        const messages = [_]ai_types.Message{
            .{ .assistant = .{
                .content = &.{},
                .api = "fixture-ok-api",
                .provider = "fixture",
                .model = "fixture-model",
                .usage = .{},
                .stop_reason = .stop,
                .timestamp = 0,
            } },
        };
        const event = agent_loop.AgentEvent{ .agent_end = .{
            .messages = ai_types.OwnedSlice(ai_types.Message).initBorrowed(&messages),
            .termination = .cancelled,
        } };
        const json = try serializeAgentLoopEvent(allocator, session_id, event);
        defer allocator.free(json);
        try std.testing.expect(std.mem.find(u8, json, "\"type\":\"agent_end\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"stop_reason\":\"cancelled\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"stop_reason\":\"stop\"") == null);
        try std.testing.expect(std.mem.find(u8, json, "\"provider_id\":\"fixture\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"api\":\"fixture-ok-api\"") != null);
    }

    // No-turn runs take their identity from the run's final message, never
    // from an older assistant turn lingering in the history.
    {
        const messages = [_]ai_types.Message{
            .{ .assistant = .{
                .content = &.{},
                .api = "historical-api",
                .provider = "historical-provider",
                .model = "older-model",
                .usage = .{},
                .stop_reason = .stop,
                .timestamp = 0,
            } },
        };
        const event = agent_loop.AgentEvent{ .agent_end = .{
            .messages = ai_types.OwnedSlice(ai_types.Message).initBorrowed(&messages),
            .termination = .max_turns,
            .final_message = .{
                .content = &.{},
                .api = "fixture-error-api",
                .provider = "fixture",
                .model = "fixture-model",
                .usage = .{},
                .stop_reason = .stop,
                .timestamp = 0,
            },
        } };
        const json = try serializeAgentLoopEvent(allocator, session_id, event);
        defer allocator.free(json);
        try std.testing.expect(std.mem.find(u8, json, "\"stop_reason\":\"max_turns\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"provider_id\":\"fixture\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"provider_id\":\"historical-provider\"") == null);
        try std.testing.expect(std.mem.find(u8, json, "\"api\":\"fixture-error-api\"") != null);
        try std.testing.expect(std.mem.find(u8, json, "\"api\":\"historical-api\"") == null);
    }
}

test "stdio protocol loop reports max_turns through agent_result and agent_end" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerApiProvider(.{
        .api = "fixture-tooluse-api",
        .stream = fixtureToolUseStream,
        .stream_simple = fixtureToolUseStreamSimple,
    }, "test-fixtures");

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    const session_id = AgentProtocolTypes.generateSessionId();
    const model_ref_text = "fixture/fixture-tooluse-api@fixture-model";

    const start_req = try makeAgentStartEnvelopeJson(allocator, session_id, model_ref_text);
    defer allocator.free(start_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(start_req));
    try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
    try std.testing.expectEqual(@as(usize, 1), outbound.items.len);
    clearOwnedLines(allocator, &outbound);

    const message_req = try makeAgentMessageEnvelopeJsonWithOptions(allocator, session_id, model_ref_text, "{\"max_iterations\":1}");
    defer allocator.free(message_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(message_req));

    var saw_result_line = false;
    for (0..TEST_AGENT_POLL_ITERS_DEFAULT) |_| {
        try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
        for (outbound.items) |line| {
            if (std.mem.find(u8, line, "\"type\":\"agent_result\"") != null) {
                saw_result_line = true;
                break;
            }
        }
        if (saw_result_line) break;
        compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
    }
    try std.testing.expect(saw_result_line);

    var saw_result_max_turns = false;
    var saw_agent_end_max_turns = false;
    for (outbound.items) |line| {
        var env = try agent_protocol_envelope.deserializeEnvelope(line, allocator);
        defer env.deinit(allocator);
        switch (env.payload) {
            .agent_event => |event_json| {
                if (std.mem.find(u8, event_json, "\"type\":\"agent_end\"") != null) {
                    saw_agent_end_max_turns = std.mem.find(u8, event_json, "\"stop_reason\":\"max_turns\"") != null;
                }
            },
            .agent_result => |result_json| {
                saw_result_max_turns = std.mem.find(u8, result_json, "\"stop_reason\":\"max_turns\"") != null and
                    std.mem.find(u8, result_json, "\"stop_reason\":\"tool_use\"") == null;
            },
            else => {},
        }
    }

    try std.testing.expect(saw_result_max_turns);
    try std.testing.expect(saw_agent_end_max_turns);
    try std.testing.expect(!stdio_loop.hasActiveAgentRuns());
}

test "stdio protocol loop emits terminal agent_error when agent startup fails" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    const session_id = AgentProtocolTypes.generateSessionId();
    const start_req = try makeAgentStartEnvelopeJson(allocator, session_id, "fixture/fixture-ok-api@fixture-model");
    defer allocator.free(start_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(start_req));
    try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
    clearOwnedLines(allocator, &outbound);

    const message_req = try makeAgentMessageEnvelopeJson(allocator, session_id, "invalid-model-ref");
    defer allocator.free(message_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(message_req));
    try pumpAndDrainStdioLoop(&stdio_loop, &outbound);

    var saw_error_event = false;
    var saw_terminal_error = false;
    for (outbound.items) |line| {
        var env = try agent_protocol_envelope.deserializeEnvelope(line, allocator);
        defer env.deinit(allocator);
        switch (env.payload) {
            .agent_event => saw_error_event = std.mem.find(u8, env.payload.agent_event, "\"type\":\"error\"") != null,
            .agent_error => saw_terminal_error = true,
            else => {},
        }
    }

    try std.testing.expect(saw_error_event);
    try std.testing.expect(saw_terminal_error);
}

test "stdio protocol loop emits terminal agent_error when active run fails" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    const session_id = AgentProtocolTypes.generateSessionId();
    const start_req = try makeAgentStartEnvelopeJson(allocator, session_id, "fixture/fixture-ok-api@fixture-model");
    defer allocator.free(start_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(start_req));
    try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
    clearOwnedLines(allocator, &outbound);

    const stream = try allocator.create(agent_loop.AgentEventStream);
    stream.* = agent_loop.AgentEventStream.init(allocator);
    stream.completeWithError("agent loop failed");

    const context = try allocator.create(agent_loop.AgentContext);
    context.* = agent_loop.AgentContext.init(allocator);

    const cancel_flag = try allocator.create(std.atomic.Value(bool));
    cancel_flag.* = std.atomic.Value(bool).init(false);
    const tool_executor = try allocator.create(StdioAgentToolExecutor);
    tool_executor.* = .{ .bridge = &stdio_loop.tool_bridge, .session_id = session_id };

    try stdio_loop.active_agent_runs.append(allocator, .{
        .session_id = session_id,
        .stream = stream,
        .context = context,
        .model = try modelFromCanonicalRef(allocator, "fixture/fixture-ok-api@fixture-model"),
        .prompts = try allocator.alloc(ai_types.Message, 0),
        .tools = try allocator.alloc(agent_loop.AgentTool, 0),
        .cancel_flag = cancel_flag,
        .tool_executor = tool_executor,
    });

    try pumpAndDrainStdioLoop(&stdio_loop, &outbound);

    var saw_error_event = false;
    var saw_terminal_error = false;
    for (outbound.items) |line| {
        var env = try agent_protocol_envelope.deserializeEnvelope(line, allocator);
        defer env.deinit(allocator);
        switch (env.payload) {
            .agent_event => saw_error_event = std.mem.find(u8, env.payload.agent_event, "\"type\":\"error\"") != null,
            .agent_error => saw_terminal_error = true,
            else => {},
        }
    }

    try std.testing.expect(saw_error_event);
    try std.testing.expect(saw_terminal_error);
    try std.testing.expect(!stdio_loop.hasActiveAgentRuns());
}

test "writeOwnedLinesAndClear clears owned lines on write failure" {
    const allocator = std.testing.allocator;
    const pipe = try compat.stdio.pipe();
    const read_file = pipe[0];
    const write_file = pipe[1];
    defer compat.stdio.close(read_file);

    // Force write error path.
    compat.stdio.close(write_file);

    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    try lines.append(allocator, try allocator.dupe(u8, "line-1"));
    try lines.append(allocator, try allocator.dupe(u8, "line-2"));

    var saw_error = false;
    writeOwnedLinesAndClear(write_file, allocator, &lines) catch {
        saw_error = true;
    };

    try std.testing.expect(saw_error);
    try std.testing.expectEqual(@as(usize, 0), lines.items.len);
}

test "stdio mode preserves ready handshake compatibility" {
    const allocator = std.testing.allocator;

    const stdin_pipe = try compat.stdio.pipe();
    const stdout_pipe = try compat.stdio.pipe();

    const stdin_read = stdin_pipe[0];
    const stdin_write = stdin_pipe[1];
    const stdout_read = stdout_pipe[0];
    const stdout_write = stdout_pipe[1];
    errdefer {
        compat.stdio.close(stdin_read);
        compat.stdio.close(stdin_write);
        compat.stdio.close(stdout_read);
        compat.stdio.close(stdout_write);
    }

    const Runner = struct {
        allocator: std.mem.Allocator,
        stdin_file: std.Io.File,
        stdout_file: std.Io.File,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            runStdioMode(self.allocator, self.stdin_file, self.stdout_file) catch |err| {
                self.err = err;
            };
            compat.stdio.close(self.stdin_file);
            compat.stdio.close(self.stdout_file);
        }
    };

    var runner = Runner{
        .allocator = allocator,
        .stdin_file = stdin_read,
        .stdout_file = stdout_write,
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    defer thread.join();

    var stdin_write_closed = false;
    defer if (!stdin_write_closed) compat.stdio.close(stdin_write);

    var out_receiver = stdio.StdioReceiver.initWithFile(stdout_read, allocator);
    defer out_receiver.deinit();
    defer compat.stdio.close(stdout_read);

    var receiver = out_receiver.receiver();

    const ready_line = (try receiver.read(allocator)).?;
    defer allocator.free(ready_line);
    try std.testing.expectEqualStrings("{\"type\":\"ready\",\"protocol_version\":\"1\"}", ready_line);

    const ping = try makeProviderPingEnvelopeJson(allocator);
    defer allocator.free(ping);
    try compat.stdio.writeLine(stdin_write, ping);

    const response_line = (try receiver.read(allocator)).?;
    defer allocator.free(response_line);
    var pong = try provider_protocol_envelope.deserializeEnvelope(response_line, allocator);
    defer pong.deinit(allocator);
    try std.testing.expect(pong.payload == .pong);

    compat.stdio.close(stdin_write);
    stdin_write_closed = true;
    try std.testing.expect(runner.err == null);
}

test "stdio mode emits unknown_envelope error and continues processing" {
    const allocator = std.testing.allocator;

    const stdin_pipe = try compat.stdio.pipe();
    const stdout_pipe = try compat.stdio.pipe();

    const stdin_read = stdin_pipe[0];
    const stdin_write = stdin_pipe[1];
    const stdout_read = stdout_pipe[0];
    const stdout_write = stdout_pipe[1];
    errdefer {
        compat.stdio.close(stdin_read);
        compat.stdio.close(stdin_write);
        compat.stdio.close(stdout_read);
        compat.stdio.close(stdout_write);
    }

    const Runner = struct {
        allocator: std.mem.Allocator,
        stdin_file: std.Io.File,
        stdout_file: std.Io.File,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            runStdioMode(self.allocator, self.stdin_file, self.stdout_file) catch |err| {
                self.err = err;
            };
            compat.stdio.close(self.stdin_file);
            compat.stdio.close(self.stdout_file);
        }
    };

    var runner = Runner{
        .allocator = allocator,
        .stdin_file = stdin_read,
        .stdout_file = stdout_write,
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    defer thread.join();

    var stdin_write_closed = false;
    defer if (!stdin_write_closed) compat.stdio.close(stdin_write);

    var out_receiver = stdio.StdioReceiver.initWithFile(stdout_read, allocator);
    defer out_receiver.deinit();
    defer compat.stdio.close(stdout_read);

    var receiver = out_receiver.receiver();

    const ready_line = (try receiver.read(allocator)).?;
    defer allocator.free(ready_line);
    try std.testing.expectEqualStrings("{\"type\":\"ready\",\"protocol_version\":\"1\"}", ready_line);

    try compat.stdio.writeAll(stdin_write, "{\"type\":\"unknown\",\"payload\":{}}\n");

    const ping = try makeProviderPingEnvelopeJson(allocator);
    defer allocator.free(ping);
    try compat.stdio.writeLine(stdin_write, ping);

    const error_line = (try receiver.read(allocator)).?;
    defer allocator.free(error_line);
    const error_parsed = try std.json.parseFromSlice(std.json.Value, allocator, error_line, .{});
    defer error_parsed.deinit();
    try std.testing.expect(error_parsed.value == .object);
    const obj = error_parsed.value.object;
    try std.testing.expectEqualStrings("error", obj.get("type").?.string);
    try std.testing.expectEqualStrings("unknown_envelope", obj.get("code").?.string);
    try std.testing.expectEqualStrings("1", obj.get("protocol_version").?.string);

    const pong_line = (try receiver.read(allocator)).?;
    defer allocator.free(pong_line);
    var pong = try provider_protocol_envelope.deserializeEnvelope(pong_line, allocator);
    defer pong.deinit(allocator);
    try std.testing.expect(pong.payload == .pong);

    compat.stdio.close(stdin_write);
    stdin_write_closed = true;
    try std.testing.expect(runner.err == null);
}

// =============================================================================
// CLI wrapper integration tests (end-to-end via handleAuthWithOptions)
//
// These tests exercise the full `makai auth ...` CLI wrapper path: argv
// parsing, in-process auth protocol runtime, and pipe-backed stdio. They
// inject server options that disable real OAuth + credential persistence so
// the wrapper never touches `~/.makai/auth.json` or external services.
// =============================================================================

const TEST_AUTH_SERVER_OPTIONS = auth_protocol_server.AuthProtocolServer.Options{
    .persist_credentials = false,
    .enable_real_oauth = false,
};

/// Spawn `handleAuthWithOptions` on a worker thread fed by pipe-backed stdio
/// so tests can stream input and read output without touching real fds.
const AuthCliHarness = struct {
    allocator: std.mem.Allocator,
    args: []const []const u8,

    stdin_read: std.Io.File,
    stdin_write: std.Io.File,
    stdout_read: std.Io.File,
    stdout_write: std.Io.File,
    stderr_read: std.Io.File,
    stderr_write: std.Io.File,

    err: ?anyerror = null,

    fn init(allocator: std.mem.Allocator, args: []const []const u8) !AuthCliHarness {
        const stdin_pipe = try compat.stdio.pipe();
        const stdout_pipe = try compat.stdio.pipe();
        const stderr_pipe = try compat.stdio.pipe();

        return .{
            .allocator = allocator,
            .args = args,
            .stdin_read = stdin_pipe[0],
            .stdin_write = stdin_pipe[1],
            .stdout_read = stdout_pipe[0],
            .stdout_write = stdout_pipe[1],
            .stderr_read = stderr_pipe[0],
            .stderr_write = stderr_pipe[1],
        };
    }

    fn run(self: *AuthCliHarness) void {
        defer {
            // The wrapper does not own these fds; closing them here lets the
            // reader side observe EOF after the command finishes.
            compat.stdio.close(self.stdout_write);
            compat.stdio.close(self.stderr_write);
            compat.stdio.close(self.stdin_read);
        }

        handleAuthWithOptions(
            self.args,
            self.allocator,
            self.stdin_read,
            self.stdout_write,
            self.stderr_write,
            TEST_AUTH_SERVER_OPTIONS,
        ) catch |err| {
            self.err = err;
        };
    }

    fn readAll(file: std.Io.File, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = compat.stdio.read(file, &chunk) catch break;
            if (n == 0) break;
            try buf.appendSlice(allocator, chunk[0..n]);
        }
        return try allocator.dupe(u8, buf.items);
    }
};

test "handleAuth providers end-to-end through CLI wrapper emits provider ids" {
    const allocator = std.testing.allocator;

    var harness = try AuthCliHarness.init(allocator, &.{"providers"});
    const thread = try std.Thread.spawn(.{}, AuthCliHarness.run, .{&harness});

    // No stdin needed; close immediately so the worker doesn't block on read.
    compat.stdio.close(harness.stdin_write);

    const stdout_bytes = try AuthCliHarness.readAll(harness.stdout_read, allocator);
    defer allocator.free(stdout_bytes);
    const stderr_bytes = try AuthCliHarness.readAll(harness.stderr_read, allocator);
    defer allocator.free(stderr_bytes);

    thread.join();
    compat.stdio.close(harness.stdout_read);
    compat.stdio.close(harness.stderr_read);

    try std.testing.expect(harness.err == null);
    try std.testing.expect(std.mem.find(u8, stdout_bytes, "anthropic\n") != null);
    try std.testing.expect(std.mem.find(u8, stdout_bytes, "github-copilot\n") != null);
    try std.testing.expect(std.mem.find(u8, stdout_bytes, "test-fixture\n") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr_bytes.len);
}

test "handleAuth providers --json end-to-end emits backward-compatible shape" {
    const allocator = std.testing.allocator;

    var harness = try AuthCliHarness.init(allocator, &.{ "providers", "--json" });
    const thread = try std.Thread.spawn(.{}, AuthCliHarness.run, .{&harness});

    compat.stdio.close(harness.stdin_write);

    const stdout_bytes = try AuthCliHarness.readAll(harness.stdout_read, allocator);
    defer allocator.free(stdout_bytes);
    const stderr_bytes = try AuthCliHarness.readAll(harness.stderr_read, allocator);
    defer allocator.free(stderr_bytes);

    thread.join();
    compat.stdio.close(harness.stdout_read);
    compat.stdio.close(harness.stderr_read);

    try std.testing.expect(harness.err == null);

    const trimmed = std.mem.trim(u8, stdout_bytes, " \t\r\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("providers", root.get("type").?.string);
    const providers = root.get("providers").?.array;
    try std.testing.expect(providers.items.len >= 3);
    try std.testing.expectEqual(@as(usize, 0), stderr_bytes.len);
}

test "handleAuth login end-to-end drives prompt loop through CLI wrapper" {
    const allocator = std.testing.allocator;

    var harness = try AuthCliHarness.init(allocator, &.{ "login", "--provider", "test-fixture" });
    const thread = try std.Thread.spawn(.{}, AuthCliHarness.run, .{&harness});

    // Reject first attempt to force the prompt loop to iterate, then accept.
    try compat.stdio.writeAll(harness.stdin_write, "not-the-answer\nok\n");
    compat.stdio.close(harness.stdin_write);

    const stdout_bytes = try AuthCliHarness.readAll(harness.stdout_read, allocator);
    defer allocator.free(stdout_bytes);
    const stderr_bytes = try AuthCliHarness.readAll(harness.stderr_read, allocator);
    defer allocator.free(stderr_bytes);

    thread.join();
    compat.stdio.close(harness.stdout_read);
    compat.stdio.close(harness.stderr_read);

    try std.testing.expect(harness.err == null);
    try std.testing.expect(std.mem.find(
        u8,
        stdout_bytes,
        "https://example.invalid/makai-test-fixture-login",
    ) != null);
    try std.testing.expect(std.mem.find(u8, stdout_bytes, "Login successful.") != null);

    // Tokens must never appear in CLI-visible streams.
    try std.testing.expect(std.mem.find(u8, stdout_bytes, "fixture-refresh-token") == null);
    try std.testing.expect(std.mem.find(u8, stdout_bytes, "fixture-access-token") == null);
    try std.testing.expect(std.mem.find(u8, stderr_bytes, "fixture-refresh-token") == null);
    try std.testing.expect(std.mem.find(u8, stderr_bytes, "fixture-access-token") == null);
}

test "handleAuth login surfaces typed error for unknown provider via CLI wrapper" {
    const allocator = std.testing.allocator;

    var harness = try AuthCliHarness.init(allocator, &.{ "login", "--provider", "no-such-provider" });
    const thread = try std.Thread.spawn(.{}, AuthCliHarness.run, .{&harness});

    compat.stdio.close(harness.stdin_write);

    const stdout_bytes = try AuthCliHarness.readAll(harness.stdout_read, allocator);
    defer allocator.free(stdout_bytes);
    const stderr_bytes = try AuthCliHarness.readAll(harness.stderr_read, allocator);
    defer allocator.free(stderr_bytes);

    thread.join();
    compat.stdio.close(harness.stdout_read);
    compat.stdio.close(harness.stderr_read);

    try std.testing.expectEqual(auth_cli.AuthCliError.AuthLoginFailed, harness.err.?);
    try std.testing.expect(std.mem.find(u8, stderr_bytes, "auth login failed") != null);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const stdout = compat.stdio.stdout();
    const stderr = compat.stdio.stderr();
    const stdin = compat.stdio.stdin();

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    if (args.len <= 1) {
        try printUsage(stdout);
        return;
    }

    if (std.mem.eql(u8, args[1], "--version")) {
        try compat.stdio.writeAll(stdout, VERSION ++ "\n");
        return;
    }

    if (std.mem.eql(u8, args[1], "--stdio")) {
        try runStdioMode(allocator, stdin, stdout);
        return;
    }

    if (std.mem.eql(u8, args[1], "--tui")) {
        try runTui(allocator, init.io);
        return;
    }

    if (std.mem.eql(u8, args[1], "-p")) {
        try runPrintMode(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, args[1], "auth")) {
        handleAuth(args[2..], allocator, stdin, stdout, stderr) catch |err| {
            if (err == error.InvalidArgument) {
                try printUsage(stderr);
            }
            return err;
        };
        return;
    }

    var msg_buf: [512]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "unknown argument: {s}\n\n", .{args[1]});
    try compat.stdio.writeAll(stderr, msg);
    try printUsage(stderr);
    return error.InvalidArgument;
}

test "baseUrlWithOverrides resolves canonical provider defaults" {
    const allocator = std.testing.allocator;

    const anthropic = try baseUrlWithOverrides(allocator, "anthropic", "anthropic-messages", .{});
    defer allocator.free(anthropic);
    try std.testing.expectEqualStrings("https://api.anthropic.com", anthropic);

    const openai = try baseUrlWithOverrides(allocator, "openai", "openai-completions", .{});
    defer allocator.free(openai);
    // Providers append /v1/chat/completions themselves — the base must NOT
    // include /v1 or requests would target /v1/v1/...
    try std.testing.expectEqualStrings("https://api.openai.com", openai);

    const deepseek = try baseUrlWithOverrides(allocator, "deepseek", "openai-completions", .{});
    defer allocator.free(deepseek);
    try std.testing.expectEqualStrings("https://api.deepseek.com", deepseek);
}

test "baseUrlWithOverrides prefers env overrides and global override" {
    const allocator = std.testing.allocator;

    const proxied = try baseUrlWithOverrides(allocator, "anthropic", "anthropic-messages", .{
        .anthropic = "https://proxy.example.com",
    });
    defer allocator.free(proxied);
    try std.testing.expectEqualStrings("https://proxy.example.com", proxied);

    const versioned_anthropic = try baseUrlWithOverrides(allocator, "anthropic", "anthropic-messages", .{
        .anthropic = "https://proxy.example.com/anthropic/v1/",
    });
    defer allocator.free(versioned_anthropic);
    try std.testing.expectEqualStrings("https://proxy.example.com/anthropic", versioned_anthropic);

    const versioned_openai = try baseUrlWithOverrides(allocator, "openai", "openai-completions", .{
        .openai = "https://proxy.example.com/openai/v1/",
    });
    defer allocator.free(versioned_openai);
    try std.testing.expectEqualStrings("https://proxy.example.com/openai", versioned_openai);

    const global = try baseUrlWithOverrides(allocator, "kimi", "openai-completions", .{
        .global = "https://everywhere.example.com",
    });
    defer allocator.free(global);
    try std.testing.expectEqualStrings("https://everywhere.example.com", global);

    const versioned_global = try baseUrlWithOverrides(allocator, "openai", "openai-completions", .{
        .global = "https://proxy.example.com/v1",
    });
    defer allocator.free(versioned_global);
    try std.testing.expectEqualStrings("https://proxy.example.com", versioned_global);

    const copilot_global = try baseUrlWithOverrides(allocator, "github-copilot", "openai-completions", .{
        .global = "https://proxy.example.com/v1",
    });
    defer allocator.free(copilot_global);
    try std.testing.expectEqualStrings("https://proxy.example.com/v1", copilot_global);

    const versioned_deepseek = try baseUrlWithOverrides(allocator, "deepseek", "openai-completions", .{
        .deepseek = "https://proxy.example.com/v1/",
    });
    defer allocator.free(versioned_deepseek);
    try std.testing.expectEqualStrings("https://proxy.example.com", versioned_deepseek);
}

test "transparent proxy compat preserves vendor token-limit fields" {
    // A declared transparent DeepSeek proxy keeps the canonical DeepSeek
    // max_tokens field; the partial compat value must not inherit OpenAI's
    // max_completion_tokens default.
    const deepseek = transparentProxyCompatForFlags("deepseek", .{ .deepseek_proxy = true });
    try std.testing.expect(deepseek != null);
    try std.testing.expectEqual(@as(?bool, true), deepseek.?.requires_thinking_as_text);
    try std.testing.expectEqual(@as(@TypeOf(deepseek.?.max_tokens_field), .max_tokens), deepseek.?.max_tokens_field);
    try std.testing.expectEqual(@as(?bool, false), deepseek.?.supports_strict_mode);

    // The global proxy flag governs when MAKAI_BASE_URL supplies the endpoint.
    const deepseek_global = transparentProxyCompatForFlags("deepseek", .{
        .global_base_set = true,
        .global_proxy = true,
        .deepseek_proxy = false,
    });
    try std.testing.expect(deepseek_global != null);
    try std.testing.expectEqual(@as(@TypeOf(deepseek_global.?.max_tokens_field), .max_tokens), deepseek_global.?.max_tokens_field);

    // Without any proxy declaration there is no compat override.
    try std.testing.expect(transparentProxyCompatForFlags("deepseek", .{}) == null);

    // OpenAI transparent proxies keep the native field name.
    const openai = transparentProxyCompatForFlags("openai", .{ .openai_proxy = true });
    try std.testing.expect(openai != null);
    try std.testing.expectEqual(@as(@TypeOf(openai.?.max_tokens_field), .max_completion_tokens), openai.?.max_tokens_field);
}

test "baseUrlWithOverrides requires explicit endpoint for unknown providers" {
    const allocator = std.testing.allocator;

    // No endpoint derived from the API type: an unknown provider without an
    // override must fail before the network rather than send credentials to
    // the API vendor's endpoint.
    const unknown = try baseUrlWithOverrides(allocator, "openrouter", "openai-completions", .{});
    defer allocator.free(unknown);
    try std.testing.expectEqualStrings("", unknown);

    const explicit = try baseUrlWithOverrides(allocator, "openrouter", "openai-completions", .{
        .global = "https://openrouter.example.com/api",
    });
    defer allocator.free(explicit);
    try std.testing.expectEqualStrings("https://openrouter.example.com/api", explicit);
}

test "baseUrlWithOverrides rejects provider/API mismatches" {
    const allocator = std.testing.allocator;

    const anthropic_openai = try baseUrlWithOverrides(allocator, "anthropic", "openai-completions", .{});
    defer allocator.free(anthropic_openai);
    try std.testing.expectEqualStrings("", anthropic_openai);

    const openai_anthropic = try baseUrlWithOverrides(allocator, "openai", "anthropic-messages", .{});
    defer allocator.free(openai_anthropic);
    try std.testing.expectEqualStrings("", openai_anthropic);

    const openai_codex_responses = try baseUrlWithOverrides(allocator, "openai", "openai-codex-responses", .{});
    defer allocator.free(openai_codex_responses);
    try std.testing.expectEqualStrings("", openai_codex_responses);

    const deepseek_responses = try baseUrlWithOverrides(allocator, "deepseek", "openai-responses", .{});
    defer allocator.free(deepseek_responses);
    try std.testing.expectEqualStrings("", deepseek_responses);
}

test "modelFromCanonicalRef applies default base URL for non-catalog refs" {
    const allocator = std.testing.allocator;
    var model = try modelFromCanonicalRef(allocator, "anthropic/anthropic-messages@claude-test-model");
    defer model.deinit(allocator);
    // Env ANTHROPIC_BASE_URL may override in the test environment; either way
    // the base URL must no longer be empty.
    try std.testing.expect(model.base_url.len > 0);

    var reasoning = try modelFromCanonicalRef(allocator, "openai/openai-responses@o3-custom");
    defer reasoning.deinit(allocator);
    try std.testing.expect(reasoning.reasoning);

    var chat = try modelFromCanonicalRef(allocator, "openai/openai-responses@gpt-5-chat-latest");
    defer chat.deinit(allocator);
    try std.testing.expect(!chat.reasoning);

    // Non-catalog Anthropic refs must carry reasoning so a selected thinking
    // level is not silently dropped by the adapter's thinking gate.
    var claude = try modelFromCanonicalRef(allocator, "anthropic/anthropic-messages@claude-test-model");
    defer claude.deinit(allocator);
    try std.testing.expect(claude.reasoning);

    var legacy = try modelFromCanonicalRef(allocator, "anthropic/anthropic-messages@claude-3-5-sonnet");
    defer legacy.deinit(allocator);
    try std.testing.expect(!legacy.reasoning);

    var sonnet37 = try modelFromCanonicalRef(allocator, "anthropic/anthropic-messages@claude-3-7-sonnet-latest");
    defer sonnet37.deinit(allocator);
    try std.testing.expect(sonnet37.reasoning);

    // Legacy families never support thinking; the adapter must not emit a
    // thinking object for them.
    for ([_][]const u8{ "claude-2.0", "claude-1.2", "claude-v1", "claude-instant" }) |legacy_id| {
        const ref = try std.fmt.allocPrint(allocator, "anthropic/anthropic-messages@{s}", .{legacy_id});
        defer allocator.free(ref);
        var legacy_model = try modelFromCanonicalRef(allocator, ref);
        defer legacy_model.deinit(allocator);
        try std.testing.expect(!legacy_model.reasoning);
    }
}
