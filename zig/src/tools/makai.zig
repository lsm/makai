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
const model_catalog = @import("model_catalog");
const provider_base_url = @import("provider_base_url");
const oap_server = @import("oap_server");
const pre_transform = @import("pre_transform");
const oap_provider_types = @import("oap_provider_types");
const oap_provider_server = @import("oap_provider_server");
const oap_provider_catalog = @import("oap_provider_catalog");
const oap_provider_runtime = @import("oap_provider_runtime");
const oap_provider_grant_channel = @import("oap_provider_grant_channel");
const auth_resolver = @import("auth_resolver");
const oap_types = @import("oap_types");
const oap_bridge = @import("oap_bridge");

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
const SESSION_SWEEP_INTERVAL_MS: i64 = 1_000;
const STDIO_DISCONNECT_TOOL_WAIT_MESSAGE = "client disconnected while the run waited for a distributed tool_result";
const STDIO_EVENT_PUBLICATION_FAILED_MESSAGE = "run event publication failed; event stream truncated before settlement";
const STDIO_RUN_WITHOUT_OUTCOME_MESSAGE = "run ended without a deliverable outcome (terminal lost to allocation failure)";

const TEST_AUTH_POLL_ITERS_SHORT: usize = 20;
const TEST_AUTH_POLL_ITERS_DEFAULT: usize = 600;
const TEST_AUTH_POLL_ITERS_FAILURE: usize = 200;
const TEST_AUTH_POLL_ITERS_POST_CANCEL: usize = 30;
const TEST_AGENT_POLL_ITERS_DEFAULT: usize = 2_000;

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
    input_stream_error,
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
    generation: u64,
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
    request_message_id: AgentProtocolTypes.Ulid,
    generation: u64,

    fn deinit(self: *StdioToolKey, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        self.* = undefined;
    }
};

const StdioToolResult = struct {
    session_id: AgentProtocolTypes.SessionId,
    tool_call_id: []u8,
    in_reply_to: ?AgentProtocolTypes.Ulid,
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
    disconnected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn markDisconnected(self: *StdioToolBridge) void {
        self.disconnected.store(true, .release);
    }

    fn isDisconnected(self: *StdioToolBridge) bool {
        return self.disconnected.load(.acquire);
    }

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
        generation: u64,
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
            .generation = generation,
            .tool_call_id = owned_tool_call_id,
            .tool_name = owned_tool_name,
            .args_json = owned_args_json,
        });
    }

    fn peekFrontRequest(self: *StdioToolBridge) ?StdioToolRequest {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.requests.items.len == 0) return null;
        return self.requests.items[0];
    }

    fn popFrontRequest(self: *StdioToolBridge, allocator: std.mem.Allocator) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.requests.items.len == 0) return;
        var removed = self.requests.orderedRemove(0);
        removed.deinit(allocator);
    }

    fn markInFlight(self: *StdioToolBridge, allocator: std.mem.Allocator, session_id: AgentProtocolTypes.SessionId, tool_call_id: []const u8, request_message_id: AgentProtocolTypes.Ulid, generation: u64) !void {
        const owned_tool_call_id = try allocator.dupe(u8, tool_call_id);
        errdefer allocator.free(owned_tool_call_id);
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        self.removeInFlightLocked(allocator, session_id, tool_call_id);
        self.removeResultsLocked(allocator, session_id, tool_call_id);
        try self.in_flight.append(allocator, .{
            .session_id = session_id,
            .tool_call_id = owned_tool_call_id,
            .request_message_id = request_message_id,
            .generation = generation,
        });
    }

    fn enqueueResult(self: *StdioToolBridge, allocator: std.mem.Allocator, result: StdioToolResult) !bool {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        const in_flight_key = self.findInFlightLocked(result.session_id, result.tool_call_id) orelse return false;
        const reply_to = result.in_reply_to orelse return false;
        if (!std.mem.eql(u8, &reply_to, &in_flight_key.request_message_id)) return false;
        if (self.hasResultLocked(result.session_id, result.tool_call_id)) return false;
        try self.results.append(allocator, result);
        return true;
    }

    fn popResult(self: *StdioToolBridge, allocator: std.mem.Allocator, session_id: AgentProtocolTypes.SessionId, tool_call_id: []const u8, generation: u64) ?StdioToolResult {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        const key_idx = self.findInFlightIndexForGenerationLocked(session_id, tool_call_id, generation) orelse return null;
        const key = self.in_flight.items[key_idx];
        for (self.results.items, 0..) |result, idx| {
            if (std.mem.eql(u8, &result.session_id, &session_id) and std.mem.eql(u8, result.tool_call_id, tool_call_id)) {
                const reply_to = result.in_reply_to orelse continue;
                if (!std.mem.eql(u8, &reply_to, &key.request_message_id)) continue;
                var removed_key = self.in_flight.orderedRemove(key_idx);
                removed_key.deinit(allocator);
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

    fn findInFlightLocked(self: *StdioToolBridge, session_id: AgentProtocolTypes.SessionId, tool_call_id: []const u8) ?StdioToolKey {
        for (self.in_flight.items) |key| {
            if (std.mem.eql(u8, &key.session_id, &session_id) and std.mem.eql(u8, key.tool_call_id, tool_call_id)) return key;
        }
        return null;
    }

    fn findInFlightIndexForGenerationLocked(self: *StdioToolBridge, session_id: AgentProtocolTypes.SessionId, tool_call_id: []const u8, generation: u64) ?usize {
        for (self.in_flight.items, 0..) |key, idx| {
            if (key.generation == generation and std.mem.eql(u8, &key.session_id, &session_id) and std.mem.eql(u8, key.tool_call_id, tool_call_id)) return idx;
        }
        return null;
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

    fn removeResultsLocked(self: *StdioToolBridge, allocator: std.mem.Allocator, session_id: AgentProtocolTypes.SessionId, tool_call_id: []const u8) void {
        var idx: usize = 0;
        while (idx < self.results.items.len) {
            if (std.mem.eql(u8, &self.results.items[idx].session_id, &session_id) and std.mem.eql(u8, self.results.items[idx].tool_call_id, tool_call_id)) {
                var removed = self.results.orderedRemove(idx);
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
    generation: u64,
    disconnect_failed: *std.atomic.Value(bool),
};

const ActiveAgentRun = struct {
    session_id: AgentProtocolTypes.SessionId,
    generation: u64,
    stream: *agent_loop.AgentEventStream,
    context: *agent_loop.AgentContext,
    model: ai_types.Model,
    prompts: []ai_types.Message,
    tools: []agent_loop.AgentTool,
    cancel_flag: *std.atomic.Value(bool),
    disconnect_failed: *std.atomic.Value(bool),
    tool_executor: *StdioAgentToolExecutor,
    terminal_event_json: ?[]u8 = null,
    settlement_frame_published: bool = false,
    failure_event_published: bool = false,
    event_publication_failed: bool = false,

    fn cancel(self: *ActiveAgentRun) void {
        self.cancel_flag.store(true, .release);
    }

    fn deinit(self: *ActiveAgentRun, allocator: std.mem.Allocator) void {
        self.cancel();
        if (!self.stream.deinitAndDestroy()) return;
        self.context.deinit();
        allocator.destroy(self.context);
        self.model.deinit(allocator);
        allocator.free(self.prompts);
        deinitAgentTools(allocator, self.tools);
        allocator.destroy(self.cancel_flag);
        allocator.destroy(self.disconnect_failed);
        allocator.destroy(self.tool_executor);
        if (self.terminal_event_json) |event_json| allocator.free(event_json);
        self.* = undefined;
    }
};

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
    last_session_sweep_mono_ms: i64 = 0,

    const Self = @This();
    const DispatchTarget = enum { provider, agent, auth };

    fn initWithRegistry(
        allocator: std.mem.Allocator,
        registry: *api_registry.ApiRegistry,
        owns_registry: bool,
        auth_options: AuthProtocolServer.Options,
        agent_options: AgentProtocolServer.Options,
    ) Self {
        const self = Self{
            .allocator = allocator,
            .registry = registry,
            .owns_registry = owns_registry,
            .provider_server = ProviderProtocolServer.init(allocator, registry, .{}),
            .provider_pipe = in_process.createSerializedPipe(allocator),
            .agent_server = AgentProtocolServer.initWithOptions(allocator, agent_options),
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
        return initWithRegistry(allocator, registry, true, .{}, agentServerOptionsFromEnv(allocator));
    }

    fn initForTesting(allocator: std.mem.Allocator, registry: *api_registry.ApiRegistry) Self {
        return initWithRegistry(allocator, registry, false, .{
            .persist_credentials = false,
            .enable_real_oauth = false,
        }, .{});
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
                runtime.pumpClientMessages() catch |err| {
                    self.finishAgentStopCancellation(stopped_session, had_stop_session);
                    return err;
                };
                self.finishAgentStopCancellation(stopped_session, had_stop_session);
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
        try self.sweepIdleAgentSessions();

        var auth_runtime = AuthProtocolRuntime{
            .server = &self.auth_server,
            .pipe = &self.auth_pipe,
            .allocator = self.allocator,
        };
        forwarded += try auth_runtime.pumpServerOutbox();
        return forwarded;
    }

    fn sweepIdleAgentSessions(self: *Self) !void {
        const now_mono_ms = try compat.time.monotonicMillis();
        if (now_mono_ms - self.last_session_sweep_mono_ms < SESSION_SWEEP_INTERVAL_MS) return;
        self.last_session_sweep_mono_ms = now_mono_ms;

        var evicted = std.ArrayList(AgentProtocolTypes.SessionId).empty;
        defer evicted.deinit(self.allocator);
        const sweep_result = self.agent_server.evictIdleSessions(now_mono_ms, &evicted);
        for (evicted.items) |session_id| {
            self.tool_bridge.discardSession(self.allocator, session_id);
        }
        _ = try sweep_result;
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

    pub fn markStdinDisconnected(self: *Self) void {
        self.tool_bridge.markDisconnected();
    }

    fn startPendingAgentRuns(self: *Self) !usize {
        var started: usize = 0;
        while (self.agent_server.popPendingAgentMessage()) |pending| {
            var owned_pending = pending;
            defer owned_pending.deinit(self.allocator);

            self.startAgentRun(owned_pending) catch |err| {
                if (err == error.OutOfMemory) return err;
                self.agent_server.markSessionError(owned_pending.session_id) catch {};
                try self.publishAgentLoopError(owned_pending.session_id, .internal_error, @errorName(err));
                continue;
            };
            started += 1;
        }
        return started;
    }

    fn startAgentRun(self: *Self, pending: agent_protocol_server.PendingAgentMessage) !void {
        const generation = self.agent_server.sessionGeneration(pending.session_id) orelse {
            return error.SessionNotFound;
        };
        if (self.hasActiveRunForGeneration(pending.session_id, generation)) return error.AgentBusy;

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

        const disconnect_failed = try self.allocator.create(std.atomic.Value(bool));
        var disconnect_owned_by_run = false;
        errdefer if (!disconnect_owned_by_run) self.allocator.destroy(disconnect_failed);
        disconnect_failed.* = std.atomic.Value(bool).init(false);

        const tool_executor = try self.allocator.create(StdioAgentToolExecutor);
        var tool_executor_owned_by_run = false;
        errdefer if (!tool_executor_owned_by_run) self.allocator.destroy(tool_executor);
        tool_executor.* = .{
            .bridge = &self.tool_bridge,
            .session_id = pending.session_id,
            .generation = generation,
            .disconnect_failed = disconnect_failed,
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
            _ = stream.deinitAndDestroy();
        };

        var run = ActiveAgentRun{
            .session_id = pending.session_id,
            .generation = generation,
            .stream = stream,
            .context = context,
            .model = prepared.model,
            .prompts = prepared.prompts,
            .tools = prepared.tools,
            .cancel_flag = cancel_flag,
            .disconnect_failed = disconnect_failed,
            .tool_executor = tool_executor,
        };
        prepared.options.deinit(self.allocator);
        context_owned_by_run = true;
        cancel_owned_by_run = true;
        disconnect_owned_by_run = true;
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

            const registration_current = blk: {
                const generation = self.agent_server.sessionGeneration(run.session_id);
                break :blk generation != null and generation.? == run.generation;
            };
            if (!registration_current) run.cancel();

            while (run.stream.poll()) |event| {
                var owned_event = event;
                errdefer deinitSerializedStdioAgentEvent(self.allocator, &owned_event);

                if (!registration_current) {
                    deinitSerializedStdioAgentEvent(self.allocator, &owned_event);
                    continue;
                }

                if (std.meta.activeTag(event) == .agent_end) {
                    run.terminal_event_json = serializeAgentLoopEvent(self.allocator, run.session_id, event) catch |err| {
                        run.event_publication_failed = true;
                        return err;
                    };
                    deinitSerializedStdioAgentEvent(self.allocator, &owned_event);
                    continue;
                }

                const event_json = serializeAgentLoopEvent(self.allocator, run.session_id, event) catch |err| {
                    run.event_publication_failed = true;
                    return err;
                };
                defer self.allocator.free(event_json);
                self.agent_server.publishAgentEvent(run.session_id, event_json) catch |err| {
                    run.event_publication_failed = true;
                    if (err == error.OutOfMemory) return err;
                };
                deinitSerializedStdioAgentEvent(self.allocator, &owned_event);
                forwarded += 1;
            }

            if (!run.stream.isDone()) {
                idx += 1;
                continue;
            }

            if (registration_current) {
                if (!run.settlement_frame_published) {
                    if (run.disconnect_failed.load(.acquire)) {
                        self.dropTerminalProjection(run);
                        try self.publishRunFailurePair(run, .tool_execution_error, STDIO_DISCONNECT_TOOL_WAIT_MESSAGE);
                        forwarded += 1;
                    } else if (run.stream.getError()) |msg| {
                        self.dropTerminalProjection(run);
                        try self.publishRunFailurePair(run, .internal_error, msg);
                        forwarded += 1;
                    } else if (run.event_publication_failed) {
                        self.dropTerminalProjection(run);
                        try self.publishRunFailurePair(run, .internal_error, STDIO_EVENT_PUBLICATION_FAILED_MESSAGE);
                        forwarded += 1;
                    } else if (run.stream.getResult()) |result| {
                        const result_reason: []const u8 = if (result.termination) |termination|
                            @tagName(termination)
                        else
                            @tagName(result.final_message.stop_reason);
                        const result_json = try transport.serializeResultWithStopReason(result.final_message, result_reason, self.allocator);
                        defer self.allocator.free(result_json);
                        self.agent_server.publishAgentResult(run.session_id, result_json) catch |err| switch (err) {
                            error.OutOfMemory => return err,
                            else => {},
                        };
                        run.settlement_frame_published = true;
                        forwarded += 1;
                    } else {
                        self.dropTerminalProjection(run);
                        try self.publishRunFailurePair(run, .internal_error, STDIO_RUN_WITHOUT_OUTCOME_MESSAGE);
                        forwarded += 1;
                    }
                }

                if (run.settlement_frame_published) {
                    if (run.terminal_event_json) |event_json| {
                        self.agent_server.publishAgentEvent(run.session_id, event_json) catch |err| switch (err) {
                            error.OutOfMemory => return err,
                            else => {},
                        };
                        self.allocator.free(event_json);
                        run.terminal_event_json = null;
                        forwarded += 1;
                    }
                    var removed = self.active_agent_runs.orderedRemove(idx);
                    removed.deinit(self.allocator);
                    continue;
                }
            } else {
                var removed = self.active_agent_runs.orderedRemove(idx);
                removed.deinit(self.allocator);
                continue;
            }

            idx += 1;
        }
        return forwarded;
    }

    fn publishRunFailurePair(
        self: *Self,
        run: *ActiveAgentRun,
        code: AgentProtocolTypes.AgentErrorCode,
        message: []const u8,
    ) !void {
        if (!run.failure_event_published) {
            const event_json = try serializeAgentErrorEvent(self.allocator, message, @tagName(code));
            defer self.allocator.free(event_json);
            self.agent_server.publishAgentEvent(run.session_id, event_json) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {},
            };
            run.failure_event_published = true;
        }
        self.agent_server.publishAgentError(run.session_id, code, message) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {},
        };
        run.settlement_frame_published = true;
    }

    fn dropTerminalProjection(self: *Self, run: *ActiveAgentRun) void {
        if (run.terminal_event_json) |event_json| self.allocator.free(event_json);
        run.terminal_event_json = null;
    }

    fn hasActiveRunForGeneration(self: *Self, session_id: AgentProtocolTypes.SessionId, generation: u64) bool {
        for (self.active_agent_runs.items) |run| {
            if (run.settlement_frame_published) continue;
            if (run.generation == generation and std.mem.eql(u8, run.session_id[0..], session_id[0..])) return true;
        }
        return false;
    }

    fn finishAgentStopCancellation(
        self: *Self,
        stopped_session: ?AgentProtocolTypes.SessionId,
        had_stop_session: bool,
    ) void {
        if (stopped_session) |session_id| {
            if (had_stop_session and !self.agent_server.hasSession(session_id)) {
                self.cancelAgentRun(session_id);
            }
        }
    }

    fn cancelAgentRun(self: *Self, session_id: AgentProtocolTypes.SessionId) void {
        for (self.active_agent_runs.items) |*run| {
            if (std.mem.eql(u8, run.session_id[0..], session_id[0..])) run.cancel();
        }
        self.tool_bridge.discardSession(self.allocator, session_id);
    }

    fn publishAgentLoopError(self: *Self, session_id: AgentProtocolTypes.SessionId, code: AgentProtocolTypes.AgentErrorCode, message: []const u8) !void {
        const event_json = try serializeAgentErrorEvent(self.allocator, message, @tagName(code));
        defer self.allocator.free(event_json);
        self.agent_server.publishAgentEvent(session_id, event_json) catch |err| {
            if (err == error.OutOfMemory) return err;
        };
        self.agent_server.publishAgentError(session_id, code, message) catch |err| {
            if (err == error.OutOfMemory) return err;
        };
    }

    fn publishPendingToolRequests(self: *Self) !usize {
        var published: usize = 0;
        while (true) {
            const request = self.tool_bridge.peekFrontRequest() orelse break;

            const registration_current = blk: {
                const current = self.agent_server.sessionGeneration(request.session_id);
                break :blk current != null and current.? == request.generation;
            };
            if (!registration_current) {
                self.tool_bridge.popFrontRequest(self.allocator);
                continue;
            }
            if (self.tool_bridge.isDisconnected()) {
                self.tool_bridge.popFrontRequest(self.allocator);
                continue;
            }

            var payload_owned_by_env = false;
            const owned_tool_call_id = try self.allocator.dupe(u8, request.tool_call_id);
            errdefer if (!payload_owned_by_env) self.allocator.free(owned_tool_call_id);
            const owned_tool_name = try self.allocator.dupe(u8, request.tool_name);
            errdefer if (!payload_owned_by_env) self.allocator.free(owned_tool_name);
            const owned_args_json = try self.allocator.dupe(u8, request.args_json);
            errdefer if (!payload_owned_by_env) self.allocator.free(owned_args_json);

            var env = AgentProtocolTypes.Envelope{
                .session_id = request.session_id,
                .message_id = AgentProtocolTypes.generateUlid(),
                .sequence = try self.agent_server.nextOutgoingSequence(request.session_id),
                .timestamp = compat.time.nowMillis(),
                .payload = .{ .tool_execute = .{
                    .tool_call_id = owned_tool_call_id,
                    .tool_name = owned_tool_name,
                    .args_json = owned_args_json,
                } },
            };
            errdefer env.deinit(self.allocator);
            payload_owned_by_env = true;

            try self.tool_bridge.markInFlight(self.allocator, request.session_id, request.tool_call_id, env.message_id, request.generation);
            errdefer self.tool_bridge.discardInFlight(self.allocator, request.session_id, request.tool_call_id);
            try self.agent_server.enqueueEnvelope(env);
            self.tool_bridge.popFrontRequest(self.allocator);
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
        while (true) {
            if (receiver.read_pos_ptr.* >= receiver.buffer.items.len) break;
            try lines.ensureUnusedCapacity(self.allocator, 1);
            const line = (try receiver.readLine(self.allocator)) orelse break;
            lines.appendAssumeCapacity(line);
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

const defaultBaseUrlForRef = provider_base_url.defaultBaseUrlForRef;
const envOrEmpty = provider_base_url.envOwnedOrNull;
const isReasoningModelRef = provider_base_url.isReasoningModelRef;

fn isResponsesOnlyModel(model_id: []const u8) bool {
    return std.mem.startsWith(u8, model_id, "o1-pro") or
        std.mem.startsWith(u8, model_id, "o3-pro") or
        std.mem.startsWith(u8, model_id, "gpt-5-pro") or
        std.mem.startsWith(u8, model_id, "gpt-5-codex") or
        std.mem.startsWith(u8, model_id, "gpt-5.1-codex-max") or
        std.mem.indexOf(u8, model_id, "deep-research") != null or
        std.mem.startsWith(u8, model_id, "computer-use-preview");
}

const transparentProxyCompat = provider_base_url.transparentProxyCompat;

fn envFlag(allocator: std.mem.Allocator, key: []const u8) !bool {
    const value = try envOrEmpty(allocator, key) orelse return false;
    defer allocator.free(value);
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

fn sessionIdleTtlFromEnvValue(raw: ?[]const u8) ?u64 {
    const value = raw orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}

fn agentServerOptionsFromEnv(allocator: std.mem.Allocator) AgentProtocolServer.Options {
    const raw = compat.getEnvVarOwned(allocator, "MAKAI_AGENT_SESSION_IDLE_TTL_MS") catch return .{};
    defer allocator.free(raw);
    const ttl_ms = sessionIdleTtlFromEnvValue(raw) orelse return .{};
    return .{ .session_idle_ttl_ms = ttl_ms };
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
    const models = model_catalog.loadProductionModels(allocator) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    defer model_catalog.deinitModels(allocator, models);

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
    try executor.bridge.enqueueRequest(allocator, executor.session_id, executor.generation, tool_call_id, tool_name, args_json);

    const popAndBuild = struct {
        fn run(
            bridge: *StdioToolBridge,
            alloc: std.mem.Allocator,
            pop_session_id: AgentProtocolTypes.SessionId,
            pop_tool_call_id: []const u8,
            pop_generation: u64,
        ) !?agent_loop.AgentToolResult {
            const result = bridge.popResult(alloc, pop_session_id, pop_tool_call_id, pop_generation) orelse return null;
            var owned_result = result;
            defer owned_result.deinit(alloc);
            const content = try parseToolResultContentPartsJson(alloc, owned_result.result_json);
            errdefer deinitUserContentParts(alloc, content);
            const details_json = try alloc.dupe(u8, owned_result.details_json);
            errdefer alloc.free(details_json);
            return .{
                .content = ai_types.OwnedSlice(ai_types.UserContentPart).initOwned(content),
                .details_json = ai_types.OwnedSlice(u8).initOwned(details_json),
                .is_error = owned_result.is_error,
            };
        }
    }.run;

    while (true) {
        if (cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }
        if (try popAndBuild(executor.bridge, allocator, executor.session_id, tool_call_id, executor.generation)) |tool_result| return tool_result;
        if (executor.bridge.isDisconnected()) {
            if (try popAndBuild(executor.bridge, allocator, executor.session_id, tool_call_id, executor.generation)) |tool_result| return tool_result;
            executor.disconnect_failed.store(true, .release);
            if (cancel_token) |token| token.cancelled.store(true, .release);
            return error.ClientDisconnected;
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
        .in_reply_to = env.in_reply_to,
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
    const envelope_id = AgentProtocolTypes.parseSessionId(top_session) orelse return null;
    const message_id = getStringField(root, "message_id") orelse return null;
    if (AgentProtocolTypes.parseUlid(message_id) == null) return null;
    if (!hasIntegerField(root, "sequence")) return null;
    if (!hasIntegerField(root, "timestamp")) return null;
    if (!hasIntegerField(root, "version")) return null;

    const payload = root.get("payload") orelse return null;
    if (payload != .object) return null;
    const payload_session = getStringField(payload.object, "session_id") orelse return null;
    const payload_id = AgentProtocolTypes.parseSessionId(payload_session) orelse return null;

    if (!std.mem.eql(u8, &envelope_id, &payload_id)) return null;

    return payload_id;
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
    var reported_input_stream_error = false;
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

        if (stdin_stream.isDone() and !stdin_stream.hasPending()) stdio_loop.markStdinDisconnected();

        if (!reported_input_stream_error) {
            if (stdin_stream.getError()) |input_error| {
                reported_input_stream_error = true;
                try emitRuntimeError(stdout, allocator, .input_stream_error, input_error);
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
            if (outbound_lines.items.len > 0) {
                try writeOwnedLinesAndClear(stdout, allocator, &outbound_lines);
                did_work = true;
            }
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
    if (!reported_input_stream_error) {
        if (stdin_stream.getError()) |input_error| {
            reported_input_stream_error = true;
            try emitRuntimeError(stdout, allocator, .input_stream_error, input_error);
        }
    }
    _ = stdio_loop.pumpBackground() catch |err| blk: {
        try emitRuntimeError(stdout, allocator, .runtime_error, @errorName(err));
        break :blk 0;
    };
    const drained = stdio_loop.drainOutbound(&outbound_lines) catch |err| blk: {
        try emitRuntimeError(stdout, allocator, .runtime_error, @errorName(err));
        if (outbound_lines.items.len > 0) {
            try writeOwnedLinesAndClear(stdout, allocator, &outbound_lines);
        }
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
        \\  makai --oap [--model <model-ref>]
        \\  makai --oap-provider [--specimens]
        \\  makai --tui
        \\  makai -p [--agent] [--storage] [--model <id>] "<prompt>"
        \\  makai auth providers [--json]
        \\  makai auth login --provider <id> [--json]
        \\
        \\Commands:
        \\  --version        Print binary version
        \\  --stdio          Start stdio mode
        \\  --oap            Start native Open Agent Protocol mode, agent control (JSONL over stdio)
        \\  --oap-provider   Start native Open Agent Protocol mode, model provider (JSONL over stdio)
        \\  --tui            Start terminal UI shell
        \\  -p               Non-interactive print mode: stream a prompt using
        \\                   stored credentials and print every event to stdout.
        \\                   Useful for debugging provider streaming.
        \\                   Options may appear before or after the prompt.
        \\                   Use --agent to run through the full agent loop.
        \\                   Use --storage to resolve credentials like the TUI.
        \\                   Use --model <id> to pick the model
        \\                   (default kimi-k2.7-code).
        \\  auth providers   List oauth-capable providers
        \\  auth login       Run OAuth flow and persist credentials
        \\
    );
}

fn runTui(allocator: std.mem.Allocator, io: std.Io) !void {
    try tui_app.run(allocator, io);
}

const DEFAULT_PRINT_MODEL_ID = "kimi-k2.7-code";

const PrintModeOptions = struct {
    prompt: []const u8,
    model_id: []const u8 = DEFAULT_PRINT_MODEL_ID,
    use_agent_loop: bool = false,
    use_storage_auth: bool = false,
};

const PrintModeInvocation = union(enum) {
    print: PrintModeOptions,
    tui_runtime: []const u8,
};

const PrintModeArgError = union(enum) {
    missing_prompt,
    missing_option_value: []const u8,
    misplaced_option: []const u8,
    unsupported_option: []const u8,
    unexpected_argument: []const u8,
};

fn takePrintModeOptionValue(args: []const []const u8, index: *usize) ?[]const u8 {
    const value_index = index.* + 1;
    if (value_index >= args.len) return null;
    const value = args[value_index];
    if (std.mem.startsWith(u8, value, "--")) return null;
    index.* = value_index;
    return value;
}

fn parsePrintModeArgs(
    args: []const []const u8,
    err_out: *PrintModeArgError,
) error{InvalidArgument}!PrintModeInvocation {
    var prompt: ?[]const u8 = null;
    var model_id: []const u8 = DEFAULT_PRINT_MODEL_ID;
    var use_agent_loop = false;
    var use_storage_auth = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!std.mem.startsWith(u8, arg, "--")) {
            if (prompt != null) {
                err_out.* = .{ .unexpected_argument = arg };
                return error.InvalidArgument;
            }
            prompt = arg;
            continue;
        }
        if (std.mem.eql(u8, arg, "--agent")) {
            use_agent_loop = true;
        } else if (std.mem.eql(u8, arg, "--storage")) {
            use_storage_auth = true;
        } else if (std.mem.eql(u8, arg, "--tui-runtime")) {
            if (prompt != null) {
                err_out.* = .{ .misplaced_option = arg };
                return error.InvalidArgument;
            }
            const tui_prompt = takePrintModeOptionValue(args, &index) orelse {
                err_out.* = .{ .missing_option_value = arg };
                return error.InvalidArgument;
            };
            return .{ .tui_runtime = tui_prompt };
        } else if (std.mem.eql(u8, arg, "--model")) {
            model_id = takePrintModeOptionValue(args, &index) orelse {
                err_out.* = .{ .missing_option_value = arg };
                return error.InvalidArgument;
            };
        } else {
            err_out.* = .{ .unsupported_option = arg };
            return error.InvalidArgument;
        }
    }

    const resolved_prompt = prompt orelse {
        err_out.* = .missing_prompt;
        return error.InvalidArgument;
    };
    return .{ .print = .{
        .prompt = resolved_prompt,
        .model_id = model_id,
        .use_agent_loop = use_agent_loop,
        .use_storage_auth = use_storage_auth,
    } };
}

fn reportPrintModeArgError(err: PrintModeArgError) void {
    switch (err) {
        .missing_prompt => perr("error: -p requires a prompt argument\n"),
        .missing_option_value => |flag| perrf("error: {s} requires a value\n", .{flag}),
        .misplaced_option => |flag| perrf("error: {s} must appear before the prompt\n", .{flag}),
        .unsupported_option => |flag| perrf("error: unsupported -p option: {s}\n", .{flag}),
        .unexpected_argument => |arg| perrf("error: unexpected -p argument: {s}\n", .{arg}),
    }
}

fn runPrintMode(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var arg_error: PrintModeArgError = .missing_prompt;
    const invocation = parsePrintModeArgs(args, &arg_error) catch |err| {
        reportPrintModeArgError(arg_error);
        return err;
    };
    const options = switch (invocation) {
        .tui_runtime => |tui_prompt| return runPrintTuiRuntime(allocator, tui_prompt),
        .print => |parsed| parsed,
    };
    const prompt = options.prompt;
    const model_id = options.model_id;
    const use_agent_loop = options.use_agent_loop;
    const use_storage_auth = options.use_storage_auth;

    perr("[print] building kimi model from env...\n");

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

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    const provider = registry.getApiProvider(model.api) orelse {
        perrf("error: no provider registered for api '{s}'\n", .{model.api});
        return error.NoProvider;
    };
    _ = provider;

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

    var bridge = agent_bridge.InProcessProviderProtocolBridge.init(&registry);
    const protocol = bridge.protocolClient();

    const stream = try protocol.stream(model, context, .{
        .api_key = api_key_copy,
    }, allocator);
    defer _ = stream.deinitAndDestroy();

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
    defer _ = stream.deinitAndDestroy();

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

fn perr(msg: []const u8) void {
    std.debug.print("{s}", .{msg});
}

fn perrf(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

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

fn fixtureDistributedToolStream(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = context;
    _ = options;

    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    errdefer allocator.destroy(s);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);
    s.owns_events = true;
    s.clone_event_fn = ai_types.cloneAssistantMessageEvent;

    const owned_id = try allocator.dupe(u8, "dist-call-1");
    errdefer allocator.free(owned_id);
    const owned_name = try allocator.dupe(u8, "lookup");
    errdefer allocator.free(owned_name);
    const owned_args = try allocator.dupe(u8, "{}");
    errdefer allocator.free(owned_args);
    const content = try allocator.alloc(ai_types.AssistantContent, 1);
    errdefer allocator.free(content);
    content[0] = .{ .tool_call = .{
        .id = owned_id,
        .name = owned_name,
        .arguments_json = owned_args,
    } };

    s.complete(.{
        .content = content,
        .api = "fixture-dist-api",
        .provider = "fixture",
        .model = "fixture-model",
        .usage = .{},
        .stop_reason = .tool_use,
        .timestamp = compat.time.nowMillis(),
    });
    s.markThreadDone();
    return s;
}

fn fixtureDistributedToolStreamSimple(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = options;
    return fixtureDistributedToolStream(model, context, null, allocator);
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

fn makeAgentStopEnvelopeJson(
    allocator: std.mem.Allocator,
    session_id: AgentProtocolTypes.SessionId,
    sequence: u64,
) ![]u8 {
    var env = AgentProtocolTypes.Envelope{
        .session_id = session_id,
        .message_id = AgentProtocolTypes.generateUlid(),
        .sequence = sequence,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_stop = .{ .session_id = session_id } },
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

fn makeToolResultEnvelopeJson(
    allocator: std.mem.Allocator,
    session_id: AgentProtocolTypes.SessionId,
    tool_call_id: []const u8,
    in_reply_to: ?AgentProtocolTypes.Ulid,
    text: []const u8,
) ![]u8 {
    const result_json = try std.fmt.allocPrint(allocator, "[{{\"type\":\"text\",\"text\":\"{s}\"}}]", .{text});
    defer allocator.free(result_json);
    var env = AgentProtocolTypes.Envelope{
        .session_id = session_id,
        .message_id = AgentProtocolTypes.generateUlid(),
        .in_reply_to = in_reply_to,
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .tool_result = .{
            .tool_call_id = try allocator.dupe(u8, tool_call_id),
            .result_json = try allocator.dupe(u8, result_json),
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

test "MAKAI_AGENT_SESSION_IDLE_TTL_MS value parsing" {
    try std.testing.expect(sessionIdleTtlFromEnvValue(null) == null);
    try std.testing.expect(sessionIdleTtlFromEnvValue("") == null);
    try std.testing.expect(sessionIdleTtlFromEnvValue("   ") == null);
    try std.testing.expect(sessionIdleTtlFromEnvValue("soon") == null);
    try std.testing.expect(sessionIdleTtlFromEnvValue("-1") == null);

    try std.testing.expectEqual(@as(?u64, 0), sessionIdleTtlFromEnvValue("0"));
    try std.testing.expectEqual(@as(?u64, 1234), sessionIdleTtlFromEnvValue("1234"));
    try std.testing.expectEqual(@as(?u64, 42), sessionIdleTtlFromEnvValue(" 42 \r\n"));
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
    const disconnect_flag = try allocator.create(std.atomic.Value(bool));
    disconnect_flag.* = std.atomic.Value(bool).init(false);
    const tool_executor = try allocator.create(StdioAgentToolExecutor);
    tool_executor.* = .{ .bridge = &stdio_loop.tool_bridge, .session_id = session_id, .generation = 0, .disconnect_failed = disconnect_flag };

    try stdio_loop.active_agent_runs.append(allocator, .{
        .session_id = session_id,
        .generation = 0,
        .stream = stream,
        .context = context,
        .model = try modelFromCanonicalRef(allocator, "fixture/fixture-ok-api@fixture-model"),
        .prompts = prompts,
        .tools = try allocator.alloc(agent_loop.AgentTool, 0),
        .cancel_flag = cancel_flag,
        .disconnect_failed = disconnect_flag,
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

    try stdio_loop.tool_bridge.enqueueRequest(allocator, session_id, stdio_loop.agent_server.sessionGeneration(session_id).?, "call-1", "lookup", "{\"query\":\"zig\"}");
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

    var mismatched_env = AgentProtocolTypes.Envelope{
        .session_id = session_id,
        .message_id = AgentProtocolTypes.generateUlid(),
        .in_reply_to = AgentProtocolTypes.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .tool_result = .{
            .tool_call_id = try allocator.dupe(u8, "call-1"),
            .result_json = try allocator.dupe(u8, "[{\"type\":\"text\",\"text\":\"wrong correlation\"}]"),
        } },
    };
    defer mismatched_env.deinit(allocator);
    const mismatched_json = try agent_protocol_envelope.serializeEnvelope(mismatched_env, allocator);
    defer allocator.free(mismatched_json);
    try std.testing.expect(!(try stdio_loop.dispatchInboundLine(mismatched_json)));
    try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.results.items.len);

    var tool_execute_env = try agent_protocol_envelope.deserializeEnvelope(outbound.items[0], allocator);
    defer tool_execute_env.deinit(allocator);
    try std.testing.expect(tool_execute_env.payload == .tool_execute);

    var result_env = AgentProtocolTypes.Envelope{
        .session_id = session_id,
        .message_id = AgentProtocolTypes.generateUlid(),
        .in_reply_to = tool_execute_env.message_id,
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
    var result = stdio_loop.tool_bridge.popResult(allocator, session_id, "call-1", stdio_loop.agent_server.sessionGeneration(session_id).?).?;
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

    try stdio_loop.tool_bridge.enqueueRequest(allocator, session_id, stdio_loop.agent_server.sessionGeneration(session_id).?, "queued-call", "lookup", "{}");
    try stdio_loop.tool_bridge.markInFlight(allocator, session_id, "running-call", AgentProtocolTypes.generateUlid(), 0);
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
    try stdio_loop.tool_bridge.enqueueRequest(allocator, session_id, 0, "call-1", "lookup", "{}");
    try std.testing.expectEqual(@as(usize, 0), try stdio_loop.publishPendingToolRequests());
    try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.requests.items.len);
    try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.in_flight.items.len);
}

test "publishPendingToolRequests drops stale-generation requests after id re-registration" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    const session_id = AgentProtocolTypes.generateSessionId();
    const start_req = try makeAgentStartEnvelopeJson(allocator, session_id, "fixture/fixture-ok-api@fixture-model");
    defer allocator.free(start_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(start_req));
    const first_generation = stdio_loop.agent_server.sessionGeneration(session_id).?;

    const stop_req = try makeAgentStopEnvelopeJson(allocator, session_id, 2);
    defer allocator.free(stop_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(stop_req));

    const restart_req = try makeAgentStartEnvelopeJson(allocator, session_id, "fixture/fixture-ok-api@fixture-model");
    defer allocator.free(restart_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(restart_req));
    const second_generation = stdio_loop.agent_server.sessionGeneration(session_id).?;
    try std.testing.expect(second_generation > first_generation);

    try stdio_loop.tool_bridge.enqueueRequest(allocator, session_id, first_generation, "stale-call", "lookup", "{}");
    try std.testing.expectEqual(@as(usize, 0), try stdio_loop.publishPendingToolRequests());
    try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.requests.items.len);
    try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.in_flight.items.len);

    try stdio_loop.tool_bridge.enqueueRequest(allocator, session_id, second_generation, "fresh-call", "lookup", "{}");
    try std.testing.expectEqual(@as(usize, 1), try stdio_loop.publishPendingToolRequests());
}

test "stale tool_result for a reused tool_call_id is rejected by in_reply_to correlation" {
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

    try stdio_loop.tool_bridge.enqueueRequest(allocator, session_id, stdio_loop.agent_server.sessionGeneration(session_id).?, "dup-call", "lookup", "{}");
    try std.testing.expectEqual(@as(usize, 1), try stdio_loop.publishPendingToolRequests());
    try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
    var first_env = try agent_protocol_envelope.deserializeEnvelope(outbound.items[0], allocator);
    defer first_env.deinit(allocator);
    const first_result_json = try makeToolResultEnvelopeJson(allocator, session_id, "dup-call", first_env.message_id, "first");
    defer allocator.free(first_result_json);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(first_result_json));
    var consumed = stdio_loop.tool_bridge.popResult(allocator, session_id, "dup-call", stdio_loop.agent_server.sessionGeneration(session_id).?).?;
    consumed.deinit(allocator);

    try stdio_loop.tool_bridge.enqueueRequest(allocator, session_id, stdio_loop.agent_server.sessionGeneration(session_id).?, "dup-call", "lookup", "{}");
    try std.testing.expectEqual(@as(usize, 1), try stdio_loop.publishPendingToolRequests());
    try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
    var second_env = try agent_protocol_envelope.deserializeEnvelope(outbound.items[1], allocator);
    defer second_env.deinit(allocator);
    try std.testing.expect(!std.mem.eql(u8, &first_env.message_id, &second_env.message_id));

    try std.testing.expect(!(try stdio_loop.dispatchInboundLine(first_result_json)));
    const bare_result_json = try makeToolResultEnvelopeJson(allocator, session_id, "dup-call", null, "bare");
    defer allocator.free(bare_result_json);
    try std.testing.expect(!(try stdio_loop.dispatchInboundLine(bare_result_json)));
    try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.results.items.len);

    const second_result_json = try makeToolResultEnvelopeJson(allocator, session_id, "dup-call", second_env.message_id, "second");
    defer allocator.free(second_result_json);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(second_result_json));
    try std.testing.expectEqual(@as(usize, 1), stdio_loop.tool_bridge.results.items.len);
    var final_result = stdio_loop.tool_bridge.popResult(allocator, session_id, "dup-call", stdio_loop.agent_server.sessionGeneration(session_id).?).?;
    defer final_result.deinit(allocator);
    try std.testing.expect(std.mem.find(u8, final_result.result_json, "second") != null);
}

test "distributed tool wait fails promptly on the disconnect latch" {
    const allocator = std.testing.allocator;

    var bridge = StdioToolBridge{};
    defer bridge.deinit(allocator);

    const session_id = AgentProtocolTypes.generateSessionId();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var disconnect_flag = std.atomic.Value(bool).init(false);
    var executor = StdioAgentToolExecutor{
        .bridge = &bridge,
        .session_id = session_id,
        .generation = 0,
        .disconnect_failed = &disconnect_flag,
    };

    bridge.markDisconnected();
    try std.testing.expectError(
        error.ClientDisconnected,
        executeStdioToolViaAgentProtocol(@ptrCast(&executor), "call-1", "lookup", "{}", .{ .cancelled = &cancel_flag }, null, null, allocator),
    );
    try std.testing.expect(disconnect_flag.load(.acquire));
    try std.testing.expect(cancel_flag.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), bridge.requests.items.len);
}

test "tool result delivered before the disconnect latch settles its wait" {
    const allocator = std.testing.allocator;

    var bridge = StdioToolBridge{};
    defer bridge.deinit(allocator);

    const session_id = AgentProtocolTypes.generateSessionId();
    const request_id = AgentProtocolTypes.generateUlid();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var disconnect_flag = std.atomic.Value(bool).init(false);
    var executor = StdioAgentToolExecutor{
        .bridge = &bridge,
        .session_id = session_id,
        .generation = 0,
        .disconnect_failed = &disconnect_flag,
    };

    try bridge.markInFlight(allocator, session_id, "call-1", request_id, 0);
    const delivered = StdioToolResult{
        .session_id = session_id,
        .tool_call_id = try allocator.dupe(u8, "call-1"),
        .in_reply_to = request_id,
        .result_json = try allocator.dupe(u8, "[{\"type\":\"text\",\"text\":\"delivered\"}]"),
        .details_json = try allocator.dupe(u8, ""),
        .is_error = false,
    };
    try std.testing.expect(try bridge.enqueueResult(allocator, delivered));

    bridge.markDisconnected();
    var tool_result = try executeStdioToolViaAgentProtocol(@ptrCast(&executor), "call-1", "lookup", "{}", .{ .cancelled = &cancel_flag }, null, null, allocator);
    defer tool_result.deinit(allocator);
    try std.testing.expect(!tool_result.is_error);
    try std.testing.expectEqual(@as(usize, 1), tool_result.content.slice().len);
    try std.testing.expect(!disconnect_flag.load(.acquire));
    try std.testing.expect(!cancel_flag.load(.acquire));
}

test "tool result enqueued after the disconnect latch still wins the wait" {
    const allocator = std.testing.allocator;

    var bridge = StdioToolBridge{};
    defer bridge.deinit(allocator);

    const session_id = AgentProtocolTypes.generateSessionId();
    const request_id = AgentProtocolTypes.generateUlid();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var disconnect_flag = std.atomic.Value(bool).init(false);
    var executor = StdioAgentToolExecutor{
        .bridge = &bridge,
        .session_id = session_id,
        .generation = 0,
        .disconnect_failed = &disconnect_flag,
    };

    bridge.markDisconnected();
    try bridge.markInFlight(allocator, session_id, "call-1", request_id, 0);
    const delivered = StdioToolResult{
        .session_id = session_id,
        .tool_call_id = try allocator.dupe(u8, "call-1"),
        .in_reply_to = request_id,
        .result_json = try allocator.dupe(u8, "[{\"type\":\"text\",\"text\":\"late-visible\"}]"),
        .details_json = try allocator.dupe(u8, ""),
        .is_error = false,
    };
    try std.testing.expect(try bridge.enqueueResult(allocator, delivered));

    var tool_result = try executeStdioToolViaAgentProtocol(@ptrCast(&executor), "call-1", "lookup", "{}", .{ .cancelled = &cancel_flag }, null, null, allocator);
    defer tool_result.deinit(allocator);
    try std.testing.expect(!tool_result.is_error);
    try std.testing.expectEqual(@as(usize, 1), tool_result.content.slice().len);
    try std.testing.expect(!disconnect_flag.load(.acquire));
    try std.testing.expect(!cancel_flag.load(.acquire));
}

test "a new execution supersedes a leaked in-flight key for the same tool_call_id" {
    const allocator = std.testing.allocator;

    var bridge = StdioToolBridge{};
    defer bridge.deinit(allocator);

    const session_id = AgentProtocolTypes.generateSessionId();
    const stale_request_id = AgentProtocolTypes.generateUlid();
    const current_request_id = AgentProtocolTypes.generateUlid();

    try bridge.markInFlight(allocator, session_id, "dup-call", stale_request_id, 1);
    const stale_queued_result = StdioToolResult{
        .session_id = session_id,
        .tool_call_id = try allocator.dupe(u8, "dup-call"),
        .in_reply_to = stale_request_id,
        .result_json = try allocator.dupe(u8, "[{\"type\":\"text\",\"text\":\"stale queued\"}]"),
        .details_json = try allocator.dupe(u8, ""),
        .is_error = false,
    };
    try std.testing.expect(try bridge.enqueueResult(allocator, stale_queued_result));
    try std.testing.expectEqual(@as(usize, 1), bridge.results.items.len);

    try bridge.markInFlight(allocator, session_id, "dup-call", current_request_id, 1);
    try std.testing.expectEqual(@as(usize, 1), bridge.in_flight.items.len);
    try std.testing.expectEqual(@as(usize, 0), bridge.results.items.len);

    var stale_result = StdioToolResult{
        .session_id = session_id,
        .tool_call_id = try allocator.dupe(u8, "dup-call"),
        .in_reply_to = stale_request_id,
        .result_json = try allocator.dupe(u8, "[{\"type\":\"text\",\"text\":\"stale\"}]"),
        .details_json = try allocator.dupe(u8, ""),
        .is_error = false,
    };
    const queued_stale = try bridge.enqueueResult(allocator, stale_result);
    if (!queued_stale) stale_result.deinit(allocator);
    try std.testing.expect(!queued_stale);

    const current_result = StdioToolResult{
        .session_id = session_id,
        .tool_call_id = try allocator.dupe(u8, "dup-call"),
        .in_reply_to = current_request_id,
        .result_json = try allocator.dupe(u8, "[{\"type\":\"text\",\"text\":\"current\"}]"),
        .details_json = try allocator.dupe(u8, ""),
        .is_error = false,
    };
    try std.testing.expect(try bridge.enqueueResult(allocator, current_result));
    var popped = bridge.popResult(allocator, session_id, "dup-call", 1).?;
    defer popped.deinit(allocator);
    try std.testing.expect(std.mem.find(u8, popped.result_json, "current") != null);
}

test "result consumption is generation-bound: a stale wait cannot steal the new run's result" {
    const allocator = std.testing.allocator;

    var bridge = StdioToolBridge{};
    defer bridge.deinit(allocator);

    const session_id = AgentProtocolTypes.generateSessionId();
    const new_request_id = AgentProtocolTypes.generateUlid();

    try bridge.markInFlight(allocator, session_id, "dup-call", new_request_id, 2);
    const new_result = StdioToolResult{
        .session_id = session_id,
        .tool_call_id = try allocator.dupe(u8, "dup-call"),
        .in_reply_to = new_request_id,
        .result_json = try allocator.dupe(u8, "[{\"type\":\"text\",\"text\":\"new run\"}]"),
        .details_json = try allocator.dupe(u8, ""),
        .is_error = false,
    };
    try std.testing.expect(try bridge.enqueueResult(allocator, new_result));

    try std.testing.expect(bridge.popResult(allocator, session_id, "dup-call", 1) == null);
    try std.testing.expectEqual(@as(usize, 1), bridge.results.items.len);
    try std.testing.expectEqual(@as(usize, 1), bridge.in_flight.items.len);

    var owned = bridge.popResult(allocator, session_id, "dup-call", 2).?;
    defer owned.deinit(allocator);
    try std.testing.expect(std.mem.find(u8, owned.result_json, "new run") != null);
    try std.testing.expectEqual(@as(usize, 0), bridge.results.items.len);
    try std.testing.expectEqual(@as(usize, 0), bridge.in_flight.items.len);
}

test "stdin EOF settles a distributed-tool-waiting run with a typed failure" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerApiProvider(.{
        .api = "fixture-dist-api",
        .stream = fixtureDistributedToolStream,
        .stream_simple = fixtureDistributedToolStreamSimple,
    }, "test-fixtures");

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    const session_id = AgentProtocolTypes.generateSessionId();
    const model_ref_text = "fixture/fixture-dist-api@fixture-model";
    const start_req = try makeAgentStartEnvelopeJson(allocator, session_id, model_ref_text);
    defer allocator.free(start_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(start_req));

    const tools_json =
        \\[{"name":"lookup","description":"Lookup","parameters_schema":{"type":"object"}}]
    ;
    const message_json = try std.fmt.allocPrint(
        allocator,
        "{{\"model_ref\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"hello\"}}],\"tools\":{s},\"options\":{{\"max_iterations\":3}}}}",
        .{ model_ref_text, tools_json },
    );
    var message_env = AgentProtocolTypes.Envelope{
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
    defer message_env.deinit(allocator);
    const message_req = try agent_protocol_envelope.serializeEnvelope(message_env, allocator);
    defer allocator.free(message_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(message_req));

    var saw_tool_execute = false;
    for (0..TEST_AGENT_POLL_ITERS_DEFAULT) |_| {
        try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
        for (outbound.items) |line| {
            if (std.mem.find(u8, line, "\"type\":\"tool_execute\"") != null) saw_tool_execute = true;
        }
        if (saw_tool_execute) break;
        compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
    }
    try std.testing.expect(saw_tool_execute);

    stdio_loop.markStdinDisconnected();
    for (0..TEST_AGENT_POLL_ITERS_DEFAULT) |_| {
        try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
        if (!stdio_loop.hasActiveAgentRuns()) break;
        compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
    }
    try std.testing.expect(!stdio_loop.hasActiveAgentRuns());

    var saw_disconnect_settlement = false;
    for (outbound.items) |line| {
        try std.testing.expect(std.mem.find(u8, line, "\"type\":\"agent_result\"") == null);
        try std.testing.expect(std.mem.find(u8, line, "\"agent_end\"") == null);
        if (std.mem.find(u8, line, "\"type\":\"agent_error\"") != null and
            std.mem.find(u8, line, STDIO_DISCONNECT_TOOL_WAIT_MESSAGE) != null)
        {
            saw_disconnect_settlement = true;
        }
    }
    try std.testing.expect(saw_disconnect_settlement);

    try std.testing.expectEqual(
        AgentProtocolTypes.AgentStatus.@"error",
        stdio_loop.agent_server.sessions.get(session_id).?.status,
    );
    try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.requests.items.len);
}

fn appendManualAgentRun(
    loop: *StdioProtocolLoop,
    session_id: AgentProtocolTypes.SessionId,
    generation: u64,
) !*ActiveAgentRun {
    const allocator = loop.allocator;
    const stream = try allocator.create(agent_loop.AgentEventStream);
    stream.* = agent_loop.AgentEventStream.init(allocator);
    const context = try allocator.create(agent_loop.AgentContext);
    context.* = agent_loop.AgentContext.init(allocator);
    const cancel_flag = try allocator.create(std.atomic.Value(bool));
    cancel_flag.* = std.atomic.Value(bool).init(false);
    const disconnect_failed = try allocator.create(std.atomic.Value(bool));
    disconnect_failed.* = std.atomic.Value(bool).init(false);
    const tool_executor = try allocator.create(StdioAgentToolExecutor);
    tool_executor.* = .{
        .bridge = &loop.tool_bridge,
        .session_id = session_id,
        .generation = generation,
        .disconnect_failed = disconnect_failed,
    };
    try loop.active_agent_runs.append(allocator, .{
        .session_id = session_id,
        .generation = generation,
        .stream = stream,
        .context = context,
        .model = .{
            .id = "fixture-model",
            .name = "fixture-model",
            .api = "fixture-api",
            .provider = "fixture",
            .base_url = "",
            .reasoning = false,
            .input = &.{},
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
            .context_window = 1024,
            .max_tokens = 128,
        },
        .prompts = try allocator.alloc(ai_types.Message, 0),
        .tools = try allocator.alloc(agent_loop.AgentTool, 0),
        .cancel_flag = cancel_flag,
        .disconnect_failed = disconnect_failed,
        .tool_executor = tool_executor,
    });
    return &loop.active_agent_runs.items[loop.active_agent_runs.items.len - 1];
}

fn completeManualRunWithResult(run: *ActiveAgentRun) void {
    run.stream.complete(.{
        .messages = ai_types.OwnedSlice(ai_types.Message).initBorrowed(&[_]ai_types.Message{}),
        .final_message = .{
            .content = &.{},
            .api = "fixture-api",
            .provider = "fixture",
            .model = "fixture-model",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 0,
        },
        .iterations = 1,
        .termination = null,
    });
}

test "result settlement is transactional under allocation failure: no false success, exactly once" {
    const allocator = std.testing.allocator;

    var k: usize = 0;
    while (k <= 16) : (k += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var registry = api_registry.ApiRegistry.init(allocator);
        defer registry.deinit();
        var stdio_loop = StdioProtocolLoop.initForTesting(failing.allocator(), &registry);
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
        const generation = stdio_loop.agent_server.sessionGeneration(session_id).?;

        const run = try appendManualAgentRun(&stdio_loop, session_id, generation);
        try run.stream.push(.{ .agent_end = .{} });
        completeManualRunWithResult(run);

        failing.fail_index = failing.alloc_index + k;
        if (stdio_loop.pumpBackground()) |_| {} else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        failing.fail_index = std.math.maxInt(usize);
        _ = try stdio_loop.drainOutbound(&outbound);

        var mid_result_count: usize = 0;
        var mid_end_count: usize = 0;
        for (outbound.items) |line| {
            if (std.mem.find(u8, line, "\"type\":\"agent_result\"") != null) mid_result_count += 1;
            if (std.mem.find(u8, line, "agent_end") != null) mid_end_count += 1;
        }
        try std.testing.expect(mid_end_count <= mid_result_count);

        _ = try stdio_loop.pumpBackground();
        _ = try stdio_loop.drainOutbound(&outbound);

        var result_count: usize = 0;
        var end_count: usize = 0;
        var result_index: ?usize = null;
        var end_index: ?usize = null;
        var truncated = false;
        for (outbound.items, 0..) |line, index| {
            if (std.mem.find(u8, line, "\"type\":\"agent_result\"") != null) {
                result_count += 1;
                result_index = index;
            }
            if (std.mem.find(u8, line, "agent_end") != null) {
                end_count += 1;
                end_index = index;
            }
            if (std.mem.find(u8, line, STDIO_EVENT_PUBLICATION_FAILED_MESSAGE) != null) truncated = true;
        }
        if (truncated) {
            try std.testing.expectEqual(@as(usize, 0), result_count);
            try std.testing.expectEqual(@as(usize, 0), end_count);
            try std.testing.expectEqual(
                AgentProtocolTypes.AgentStatus.@"error",
                stdio_loop.agent_server.sessions.get(session_id).?.status,
            );
        } else {
            try std.testing.expectEqual(@as(usize, 1), result_count);
            try std.testing.expectEqual(@as(usize, 1), end_count);
            try std.testing.expect(result_index.? < end_index.?);
            try std.testing.expectEqual(
                AgentProtocolTypes.AgentStatus.ready,
                stdio_loop.agent_server.sessions.get(session_id).?.status,
            );
        }
        try std.testing.expect(!stdio_loop.hasActiveAgentRuns());
    }
}

test "failure-pair settlement is transactional under allocation failure: single settlement, no re-emitted projection" {
    const allocator = std.testing.allocator;

    var k: usize = 0;
    while (k <= 14) : (k += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var registry = api_registry.ApiRegistry.init(allocator);
        defer registry.deinit();
        var stdio_loop = StdioProtocolLoop.initForTesting(failing.allocator(), &registry);
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
        const generation = stdio_loop.agent_server.sessionGeneration(session_id).?;

        const run = try appendManualAgentRun(&stdio_loop, session_id, generation);
        run.stream.completeWithError("fixture stream failure");

        failing.fail_index = failing.alloc_index + k;
        if (stdio_loop.pumpBackground()) |_| {} else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        failing.fail_index = std.math.maxInt(usize);
        _ = try stdio_loop.drainOutbound(&outbound);

        var mid_error_events: usize = 0;
        for (outbound.items) |line| {
            if (std.mem.find(u8, line, "\"type\":\"agent_event\"") != null and
                std.mem.find(u8, line, "fixture stream failure") != null) mid_error_events += 1;
        }
        try std.testing.expect(mid_error_events <= 1);

        _ = try stdio_loop.pumpBackground();
        _ = try stdio_loop.drainOutbound(&outbound);

        var error_events: usize = 0;
        var error_envelopes: usize = 0;
        for (outbound.items) |line| {
            if (std.mem.find(u8, line, "\"type\":\"agent_event\"") != null and
                std.mem.find(u8, line, "fixture stream failure") != null) error_events += 1;
            if (std.mem.find(u8, line, "\"type\":\"agent_error\"") != null) error_envelopes += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), error_events);
        try std.testing.expectEqual(@as(usize, 1), error_envelopes);
        try std.testing.expect(!stdio_loop.hasActiveAgentRuns());
        try std.testing.expectEqual(
            AgentProtocolTypes.AgentStatus.@"error",
            stdio_loop.agent_server.sessions.get(session_id).?.status,
        );
    }
}

test "a run with a dropped agent_event never settles successfully" {
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
    const generation = stdio_loop.agent_server.sessionGeneration(session_id).?;

    const run = try appendManualAgentRun(&stdio_loop, session_id, generation);
    try run.stream.push(.{ .agent_end = .{} });
    completeManualRunWithResult(run);
    run.event_publication_failed = true;

    _ = try stdio_loop.pumpBackground();
    _ = try stdio_loop.drainOutbound(&outbound);

    var saw_truncation_settlement = false;
    for (outbound.items) |line| {
        try std.testing.expect(std.mem.find(u8, line, "\"type\":\"agent_result\"") == null);
        try std.testing.expect(std.mem.find(u8, line, "agent_end") == null);
        if (std.mem.find(u8, line, "\"type\":\"agent_error\"") != null and
            std.mem.find(u8, line, STDIO_EVENT_PUBLICATION_FAILED_MESSAGE) != null)
        {
            saw_truncation_settlement = true;
        }
    }
    try std.testing.expect(saw_truncation_settlement);
    try std.testing.expect(!stdio_loop.hasActiveAgentRuns());
    try std.testing.expectEqual(
        AgentProtocolTypes.AgentStatus.@"error",
        stdio_loop.agent_server.sessions.get(session_id).?.status,
    );
}

test "event publication failure marks the stream truncated and converts the settlement" {
    const allocator = std.testing.allocator;

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    var stdio_loop = StdioProtocolLoop.initForTesting(failing.allocator(), &registry);
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
    const generation = stdio_loop.agent_server.sessionGeneration(session_id).?;

    const run = try appendManualAgentRun(&stdio_loop, session_id, generation);
    try run.stream.push(.{ .turn_start = {} });
    completeManualRunWithResult(run);

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, stdio_loop.pumpAgentRuns());
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(usize, 1), stdio_loop.active_agent_runs.items.len);
    try std.testing.expect(stdio_loop.active_agent_runs.items[0].event_publication_failed);

    _ = try stdio_loop.pumpBackground();
    _ = try stdio_loop.drainOutbound(&outbound);

    var saw_truncation_settlement = false;
    for (outbound.items) |line| {
        try std.testing.expect(std.mem.find(u8, line, "\"type\":\"agent_result\"") == null);
        if (std.mem.find(u8, line, "\"type\":\"agent_error\"") != null and
            std.mem.find(u8, line, STDIO_EVENT_PUBLICATION_FAILED_MESSAGE) != null)
        {
            saw_truncation_settlement = true;
        }
    }
    try std.testing.expect(saw_truncation_settlement);
    try std.testing.expect(!stdio_loop.hasActiveAgentRuns());
}

test "tool-request publication failure keeps the request queued and retries exactly once" {
    const allocator = std.testing.allocator;

    var k: usize = 0;
    while (k <= 6) : (k += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var registry = api_registry.ApiRegistry.init(allocator);
        defer registry.deinit();
        var stdio_loop = StdioProtocolLoop.initForTesting(failing.allocator(), &registry);
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
        const generation = stdio_loop.agent_server.sessionGeneration(session_id).?;

        try stdio_loop.tool_bridge.enqueueRequest(allocator, session_id, generation, "call-1", "lookup", "{}");

        failing.fail_index = failing.alloc_index + k;
        if (stdio_loop.publishPendingToolRequests()) |_| {} else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 1), stdio_loop.tool_bridge.requests.items.len);
            try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.in_flight.items.len);
        }

        failing.fail_index = std.math.maxInt(usize);
        _ = try stdio_loop.publishPendingToolRequests();
        try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.requests.items.len);
        try std.testing.expectEqual(@as(usize, 1), stdio_loop.tool_bridge.in_flight.items.len);
        _ = try stdio_loop.pumpBackground();
        _ = try stdio_loop.drainOutbound(&outbound);
        var tool_execute_count: usize = 0;
        for (outbound.items) |line| {
            if (std.mem.find(u8, line, "\"type\":\"tool_execute\"") != null) tool_execute_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), tool_execute_count);
    }
}

test "stop-reply publication failure still cancels runs and discards tool-bridge state" {
    const allocator = std.testing.allocator;

    var probe = std.testing.FailingAllocator.init(allocator, .{});
    const probe_allocations = blk: {
        var registry = api_registry.ApiRegistry.init(allocator);
        defer registry.deinit();
        var probe_loop = StdioProtocolLoop.initForTesting(probe.allocator(), &registry);
        defer probe_loop.deinit();

        const session_id = AgentProtocolTypes.generateSessionId();
        const start_req = try makeAgentStartEnvelopeJson(allocator, session_id, "fixture/fixture-ok-api@fixture-model");
        defer allocator.free(start_req);
        try std.testing.expect(try probe_loop.dispatchInboundLine(start_req));

        const stop_req = try makeAgentStopEnvelopeJson(allocator, session_id, 2);
        defer allocator.free(stop_req);
        const before = probe.alloc_index;
        try std.testing.expect(try probe_loop.dispatchInboundLine(stop_req));
        break :blk probe.alloc_index - before;
    };

    var saw_failed_reply_with_session_removed = false;
    var j: usize = 1;
    while (j <= 8) : (j += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var registry = api_registry.ApiRegistry.init(allocator);
        defer registry.deinit();
        var stdio_loop = StdioProtocolLoop.initForTesting(failing.allocator(), &registry);
        defer stdio_loop.deinit();

        const session_id = AgentProtocolTypes.generateSessionId();
        const start_req = try makeAgentStartEnvelopeJson(allocator, session_id, "fixture/fixture-ok-api@fixture-model");
        defer allocator.free(start_req);
        try std.testing.expect(try stdio_loop.dispatchInboundLine(start_req));
        const generation = stdio_loop.agent_server.sessionGeneration(session_id).?;

        _ = try appendManualAgentRun(&stdio_loop, session_id, generation);
        try stdio_loop.tool_bridge.enqueueRequest(allocator, session_id, generation, "call-1", "lookup", "{}");
        try stdio_loop.tool_bridge.markInFlight(allocator, session_id, "call-1", AgentProtocolTypes.generateUlid(), generation);

        const stop_req = try makeAgentStopEnvelopeJson(allocator, session_id, 2);
        defer allocator.free(stop_req);
        const dispatch_tail = failing.alloc_index + probe_allocations;
        failing.fail_index = if (dispatch_tail > j) dispatch_tail - j else failing.alloc_index;
        var dispatch_errored = false;
        if (stdio_loop.dispatchInboundLine(stop_req)) |_| {} else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            dispatch_errored = true;
        }
        failing.fail_index = std.math.maxInt(usize);

        if (!stdio_loop.agent_server.hasSession(session_id)) {
            try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.requests.items.len);
            try std.testing.expectEqual(@as(usize, 0), stdio_loop.tool_bridge.in_flight.items.len);
            for (stdio_loop.active_agent_runs.items) |*listed| {
                try std.testing.expect(listed.cancel_flag.load(.acquire));
            }
            if (dispatch_errored) saw_failed_reply_with_session_removed = true;
        }
    }
    try std.testing.expect(saw_failed_reply_with_session_removed);
}

test "stdio drain never drops a delivered frame on failure" {
    const allocator = std.testing.allocator;

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    var stdio_loop = StdioProtocolLoop.initForTesting(failing.allocator(), &registry);
    defer stdio_loop.deinit();

    var outbound = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    var server_sender = stdio_loop.agent_pipe.serverSender();
    try server_sender.write("{\"type\":\"agent_result\"}");
    try server_sender.flush();

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, stdio_loop.drainOutbound(&outbound));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(usize, 0), outbound.items.len);

    try std.testing.expectEqual(@as(usize, 1), try stdio_loop.drainOutbound(&outbound));
    try std.testing.expect(std.mem.find(u8, outbound.items[0], "agent_result") != null);

    clearOwnedLines(allocator, &outbound);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectEqual(@as(usize, 0), try stdio_loop.drainOutbound(&outbound));
    failing.fail_index = std.math.maxInt(usize);
}

test "a settled run retrying its trailing projection does not make the session busy" {
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
    const generation = stdio_loop.agent_server.sessionGeneration(session_id).?;

    const run = try appendManualAgentRun(&stdio_loop, session_id, generation);
    completeManualRunWithResult(run);
    run.terminal_event_json = try serializeAgentLoopEvent(allocator, session_id, .{ .agent_end = .{} });
    run.settlement_frame_published = true;

    const message_req = try makeAgentMessageEnvelopeJson(allocator, session_id, model_ref_text);
    defer allocator.free(message_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(message_req));

    for (0..TEST_AGENT_POLL_ITERS_DEFAULT) |_| {
        try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
        if (!stdio_loop.hasActiveAgentRuns()) break;
        compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
    }
    try std.testing.expect(!stdio_loop.hasActiveAgentRuns());
    for (outbound.items) |line| {
        try std.testing.expect(std.mem.find(u8, line, "AgentBusy") == null);
    }
}

test "a pending result publication keeps the session non-admissible until the retry commits" {
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
    const generation = stdio_loop.agent_server.sessionGeneration(session_id).?;

    const run = try appendManualAgentRun(&stdio_loop, session_id, generation);
    completeManualRunWithResult(run);
    stdio_loop.agent_server.sessions.getPtr(session_id).?.status = .processing;

    const message_req = try makeAgentMessageEnvelopeJson(allocator, session_id, model_ref_text);
    defer allocator.free(message_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(message_req));
    _ = try stdio_loop.drainOutbound(&outbound);

    var saw_busy_rejection = false;
    for (outbound.items) |line| {
        try std.testing.expect(std.mem.find(u8, line, "AgentBusy") == null);
        if (std.mem.find(u8, line, "\"type\":\"agent_error\"") != null and
            std.mem.find(u8, line, "agent_busy") != null)
        {
            saw_busy_rejection = true;
        }
    }
    try std.testing.expect(saw_busy_rejection);

    _ = try stdio_loop.pumpBackground();
    _ = try stdio_loop.drainOutbound(&outbound);
    try std.testing.expect(!stdio_loop.hasActiveAgentRuns());
    try std.testing.expectEqual(
        AgentProtocolTypes.AgentStatus.ready,
        stdio_loop.agent_server.sessions.get(session_id).?.status,
    );
    try std.testing.expect(try stdio_loop.dispatchInboundLine(message_req));
    try std.testing.expectEqual(
        AgentProtocolTypes.AgentStatus.processing,
        stdio_loop.agent_server.sessions.get(session_id).?.status,
    );
    for (0..TEST_AGENT_POLL_ITERS_DEFAULT) |_| {
        try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
        if (!stdio_loop.hasActiveAgentRuns()) break;
        compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
    }
    try std.testing.expect(!stdio_loop.hasActiveAgentRuns());
}

test "a stream completed without an outcome settles with a typed failure instead of hanging" {
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
    const generation = stdio_loop.agent_server.sessionGeneration(session_id).?;

    const run = try appendManualAgentRun(&stdio_loop, session_id, generation);
    run.stream.completeWithoutOutcomeForTesting();
    try std.testing.expect(run.stream.isDone());
    try std.testing.expect(run.stream.getError() == null);
    try std.testing.expect(run.stream.getResult() == null);

    _ = try stdio_loop.pumpBackground();
    _ = try stdio_loop.drainOutbound(&outbound);

    try std.testing.expect(!stdio_loop.hasActiveAgentRuns());
    var saw_outcome_settlement = false;
    for (outbound.items) |line| {
        try std.testing.expect(std.mem.find(u8, line, "\"type\":\"agent_result\"") == null);
        if (std.mem.find(u8, line, "\"type\":\"agent_error\"") != null and
            std.mem.find(u8, line, STDIO_RUN_WITHOUT_OUTCOME_MESSAGE) != null)
        {
            saw_outcome_settlement = true;
        }
    }
    try std.testing.expect(saw_outcome_settlement);
    try std.testing.expectEqual(
        AgentProtocolTypes.AgentStatus.@"error",
        stdio_loop.agent_server.sessions.get(session_id).?.status,
    );
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
    const disconnect_flag = try allocator.create(std.atomic.Value(bool));
    disconnect_flag.* = std.atomic.Value(bool).init(false);
    const tool_executor = try allocator.create(StdioAgentToolExecutor);
    tool_executor.* = .{ .bridge = &stdio_loop.tool_bridge, .session_id = session_id, .generation = stdio_loop.agent_server.sessionGeneration(session_id).?, .disconnect_failed = disconnect_flag };

    try stdio_loop.active_agent_runs.append(allocator, .{
        .session_id = session_id,
        .generation = stdio_loop.agent_server.sessionGeneration(session_id).?,
        .stream = stream,
        .context = context,
        .model = try modelFromCanonicalRef(allocator, "fixture/fixture-ok-api@fixture-model"),
        .prompts = try allocator.alloc(ai_types.Message, 0),
        .tools = try allocator.alloc(agent_loop.AgentTool, 0),
        .cancel_flag = cancel_flag,
        .disconnect_failed = disconnect_flag,
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

test "stopped session's late run publications are discarded after id re-registration" {
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
    const first_generation = stdio_loop.agent_server.sessionGeneration(session_id).?;

    const stream = try allocator.create(agent_loop.AgentEventStream);
    stream.* = agent_loop.AgentEventStream.init(allocator);
    try stream.push(.{ .agent_start = {} });
    stream.completeWithError("late stale failure");

    const context = try allocator.create(agent_loop.AgentContext);
    context.* = agent_loop.AgentContext.init(allocator);

    const cancel_flag = try allocator.create(std.atomic.Value(bool));
    cancel_flag.* = std.atomic.Value(bool).init(false);
    const disconnect_flag = try allocator.create(std.atomic.Value(bool));
    disconnect_flag.* = std.atomic.Value(bool).init(false);
    const tool_executor = try allocator.create(StdioAgentToolExecutor);
    tool_executor.* = .{ .bridge = &stdio_loop.tool_bridge, .session_id = session_id, .generation = first_generation, .disconnect_failed = disconnect_flag };

    try stdio_loop.active_agent_runs.append(allocator, .{
        .session_id = session_id,
        .generation = first_generation,
        .stream = stream,
        .context = context,
        .model = try modelFromCanonicalRef(allocator, "fixture/fixture-ok-api@fixture-model"),
        .prompts = try allocator.alloc(ai_types.Message, 0),
        .tools = try allocator.alloc(agent_loop.AgentTool, 0),
        .cancel_flag = cancel_flag,
        .disconnect_failed = disconnect_flag,
        .tool_executor = tool_executor,
    });

    const stop_req = try makeAgentStopEnvelopeJson(allocator, session_id, 2);
    defer allocator.free(stop_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(stop_req));
    try std.testing.expect(cancel_flag.load(.acquire));

    const restart_req = try makeAgentStartEnvelopeJson(allocator, session_id, "fixture/fixture-ok-api@fixture-model");
    defer allocator.free(restart_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(restart_req));
    const second_generation = stdio_loop.agent_server.sessionGeneration(session_id).?;
    try std.testing.expect(second_generation > first_generation);

    try pumpAndDrainStdioLoop(&stdio_loop, &outbound);

    try std.testing.expect(!stdio_loop.hasActiveAgentRuns());

    for (outbound.items) |line| {
        try std.testing.expect(std.mem.find(u8, line, "late stale failure") == null);
        var env = try agent_protocol_envelope.deserializeEnvelope(line, allocator);
        defer env.deinit(allocator);
        try std.testing.expect(env.payload != .agent_error);
        try std.testing.expect(env.payload != .agent_event);
    }
    try std.testing.expectEqual(
        AgentProtocolTypes.AgentStatus.ready,
        stdio_loop.agent_server.sessions.get(session_id).?.status,
    );
}

test "re-created session's admitted run is not failed by the stopped registration's run" {
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
    const first_generation = stdio_loop.agent_server.sessionGeneration(session_id).?;

    const stream = try allocator.create(agent_loop.AgentEventStream);
    stream.* = agent_loop.AgentEventStream.init(allocator);

    const context = try allocator.create(agent_loop.AgentContext);
    context.* = agent_loop.AgentContext.init(allocator);

    const cancel_flag = try allocator.create(std.atomic.Value(bool));
    cancel_flag.* = std.atomic.Value(bool).init(false);
    const disconnect_flag = try allocator.create(std.atomic.Value(bool));
    disconnect_flag.* = std.atomic.Value(bool).init(false);
    const tool_executor = try allocator.create(StdioAgentToolExecutor);
    tool_executor.* = .{ .bridge = &stdio_loop.tool_bridge, .session_id = session_id, .generation = first_generation, .disconnect_failed = disconnect_flag };

    try stdio_loop.active_agent_runs.append(allocator, .{
        .session_id = session_id,
        .generation = first_generation,
        .stream = stream,
        .context = context,
        .model = try modelFromCanonicalRef(allocator, model_ref_text),
        .prompts = try allocator.alloc(ai_types.Message, 0),
        .tools = try allocator.alloc(agent_loop.AgentTool, 0),
        .cancel_flag = cancel_flag,
        .disconnect_failed = disconnect_flag,
        .tool_executor = tool_executor,
    });

    const stop_req = try makeAgentStopEnvelopeJson(allocator, session_id, 2);
    defer allocator.free(stop_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(stop_req));
    try std.testing.expect(cancel_flag.load(.acquire));

    const restart_req = try makeAgentStartEnvelopeJson(allocator, session_id, model_ref_text);
    defer allocator.free(restart_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(restart_req));

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

    for (outbound.items) |line| {
        try std.testing.expect(std.mem.find(u8, line, "AgentBusy") == null);
        var env = try agent_protocol_envelope.deserializeEnvelope(line, allocator);
        defer env.deinit(allocator);
        try std.testing.expect(env.payload != .agent_error);
    }

    try std.testing.expectEqual(
        AgentProtocolTypes.AgentStatus.ready,
        stdio_loop.agent_server.sessions.get(session_id).?.status,
    );
    try std.testing.expect(stdio_loop.hasActiveAgentRuns());
}

test "agent_stop cancels every listed run for the id, including the current registration's" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    const session_id = AgentProtocolTypes.generateSessionId();

    const start_req = try makeAgentStartEnvelopeJson(allocator, session_id, "fixture/fixture-ok-api@fixture-model");
    defer allocator.free(start_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(start_req));
    const first_generation = stdio_loop.agent_server.sessionGeneration(session_id).?;

    const stale_flag = try allocator.create(std.atomic.Value(bool));
    stale_flag.* = std.atomic.Value(bool).init(false);
    const stale_disconnect_flag = try allocator.create(std.atomic.Value(bool));
    stale_disconnect_flag.* = std.atomic.Value(bool).init(false);
    {
        const stream = try allocator.create(agent_loop.AgentEventStream);
        stream.* = agent_loop.AgentEventStream.init(allocator);
        const context = try allocator.create(agent_loop.AgentContext);
        context.* = agent_loop.AgentContext.init(allocator);
        const tool_executor = try allocator.create(StdioAgentToolExecutor);
        tool_executor.* = .{ .bridge = &stdio_loop.tool_bridge, .session_id = session_id, .generation = first_generation, .disconnect_failed = stale_disconnect_flag };
        try stdio_loop.active_agent_runs.append(allocator, .{
            .session_id = session_id,
            .generation = first_generation,
            .stream = stream,
            .context = context,
            .model = try modelFromCanonicalRef(allocator, "fixture/fixture-ok-api@fixture-model"),
            .prompts = try allocator.alloc(ai_types.Message, 0),
            .tools = try allocator.alloc(agent_loop.AgentTool, 0),
            .cancel_flag = stale_flag,
            .disconnect_failed = stale_disconnect_flag,
            .tool_executor = tool_executor,
        });
    }

    const first_stop = try makeAgentStopEnvelopeJson(allocator, session_id, 2);
    defer allocator.free(first_stop);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(first_stop));
    try std.testing.expect(stale_flag.load(.acquire));

    const restart_req = try makeAgentStartEnvelopeJson(allocator, session_id, "fixture/fixture-ok-api@fixture-model");
    defer allocator.free(restart_req);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(restart_req));
    const second_generation = stdio_loop.agent_server.sessionGeneration(session_id).?;

    const current_flag = try allocator.create(std.atomic.Value(bool));
    current_flag.* = std.atomic.Value(bool).init(false);
    const current_disconnect_flag = try allocator.create(std.atomic.Value(bool));
    current_disconnect_flag.* = std.atomic.Value(bool).init(false);
    {
        const stream = try allocator.create(agent_loop.AgentEventStream);
        stream.* = agent_loop.AgentEventStream.init(allocator);
        const context = try allocator.create(agent_loop.AgentContext);
        context.* = agent_loop.AgentContext.init(allocator);
        const tool_executor = try allocator.create(StdioAgentToolExecutor);
        tool_executor.* = .{ .bridge = &stdio_loop.tool_bridge, .session_id = session_id, .generation = second_generation, .disconnect_failed = current_disconnect_flag };
        try stdio_loop.active_agent_runs.append(allocator, .{
            .session_id = session_id,
            .generation = second_generation,
            .stream = stream,
            .context = context,
            .model = try modelFromCanonicalRef(allocator, "fixture/fixture-ok-api@fixture-model"),
            .prompts = try allocator.alloc(ai_types.Message, 0),
            .tools = try allocator.alloc(agent_loop.AgentTool, 0),
            .cancel_flag = current_flag,
            .disconnect_failed = current_disconnect_flag,
            .tool_executor = tool_executor,
        });
    }

    const second_stop = try makeAgentStopEnvelopeJson(allocator, session_id, 2);
    defer allocator.free(second_stop);
    try std.testing.expect(try stdio_loop.dispatchInboundLine(second_stop));
    try std.testing.expect(stale_flag.load(.acquire));
    try std.testing.expect(current_flag.load(.acquire));
    try std.testing.expect(!stdio_loop.agent_server.hasSession(session_id));
    try std.testing.expectEqual(@as(usize, 2), stdio_loop.active_agent_runs.items.len);
}

test "writeOwnedLinesAndClear clears owned lines on write failure" {
    const allocator = std.testing.allocator;
    const pipe = try compat.stdio.pipe();
    const read_file = pipe[0];
    const write_file = pipe[1];
    defer compat.stdio.close(read_file);

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

test "stdio mode exits promptly on stdin EOF with a registered session" {
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
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            runStdioMode(self.allocator, self.stdin_file, self.stdout_file) catch |err| {
                self.err = err;
            };
            self.done.store(true, .release);
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

    const session_id = AgentProtocolTypes.generateSessionId();
    const start_req = try makeAgentStartEnvelopeJson(allocator, session_id, "fixture/fixture-ok-api@fixture-model");
    defer allocator.free(start_req);
    try compat.stdio.writeLine(stdin_write, start_req);

    const started_line = (try receiver.read(allocator)).?;
    defer allocator.free(started_line);
    try std.testing.expect(std.mem.find(u8, started_line, "\"type\":\"agent_started\"") != null);

    compat.stdio.close(stdin_write);
    stdin_write_closed = true;

    var exited = false;
    for (0..TEST_AGENT_POLL_ITERS_DEFAULT) |_| {
        if (runner.done.load(.acquire)) {
            exited = true;
            break;
        }
        compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
    }
    try std.testing.expect(exited);
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

const TEST_AUTH_SERVER_OPTIONS = auth_protocol_server.AuthProtocolServer.Options{
    .persist_credentials = false,
    .enable_real_oauth = false,
};

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
        runStdioMode(allocator, stdin, stdout) catch |err| switch (err) {
            error.BrokenPipe => return,
            else => return err,
        };
        return;
    }

    if (std.mem.eql(u8, args[1], "--oap")) {
        runOapMode(allocator, args[2..], stdin, stdout, stderr) catch |err| {
            if (err == error.MalformedLine or err == error.UnaddressableEnvelope) std.process.exit(1);
            return err;
        };
        return;
    }

    if (std.mem.eql(u8, args[1], "--oap-provider")) {
        var answers_specimens = false;
        if (args.len > 2) {
            if (args.len == 3 and std.mem.eql(u8, args[2], "--specimens")) {
                answers_specimens = true;
            } else {
                var buf: [256]u8 = undefined;
                const msg = try std.fmt.bufPrint(
                    &buf,
                    "--oap-provider takes only --specimens: {s}\n\n",
                    .{args[2]},
                );
                try compat.stdio.writeAll(stderr, msg);
                try printUsage(stderr);
                return error.UnknownOapProviderArgument;
            }
        }
        try runOapProviderMode(allocator, stdin, stdout, stderr, answers_specimens);
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

test "modelFromCanonicalRef applies default base URL for non-catalog refs" {
    const allocator = std.testing.allocator;
    var model = try modelFromCanonicalRef(allocator, "anthropic/anthropic-messages@claude-test-model");
    defer model.deinit(allocator);
    try std.testing.expect(model.base_url.len > 0);

    var reasoning = try modelFromCanonicalRef(allocator, "openai/openai-responses@o3-custom");
    defer reasoning.deinit(allocator);
    try std.testing.expect(reasoning.reasoning);

    var chat = try modelFromCanonicalRef(allocator, "openai/openai-responses@gpt-5-chat-latest");
    defer chat.deinit(allocator);
    try std.testing.expect(!chat.reasoning);

    var claude = try modelFromCanonicalRef(allocator, "anthropic/anthropic-messages@claude-test-model");
    defer claude.deinit(allocator);
    try std.testing.expect(claude.reasoning);

    var legacy = try modelFromCanonicalRef(allocator, "anthropic/anthropic-messages@claude-3-5-sonnet");
    defer legacy.deinit(allocator);
    try std.testing.expect(!legacy.reasoning);

    var sonnet37 = try modelFromCanonicalRef(allocator, "anthropic/anthropic-messages@claude-3-7-sonnet-latest");
    defer sonnet37.deinit(allocator);
    try std.testing.expect(sonnet37.reasoning);

    for ([_][]const u8{ "claude-2.0", "claude-1.2", "claude-v1", "claude-instant" }) |legacy_id| {
        const ref = try std.fmt.allocPrint(allocator, "anthropic/anthropic-messages@{s}", .{legacy_id});
        defer allocator.free(ref);
        var legacy_model = try modelFromCanonicalRef(allocator, ref);
        defer legacy_model.deinit(allocator);
        try std.testing.expect(!legacy_model.reasoning);
    }
}

test "print mode parses options that follow the prompt" {
    var arg_error: PrintModeArgError = .missing_prompt;
    const invocation = try parsePrintModeArgs(
        &[_][]const u8{ "write a haiku", "--model", "claude-sonnet-4-5" },
        &arg_error,
    );
    try std.testing.expect(std.meta.activeTag(invocation) == .print);
    try std.testing.expectEqualStrings("write a haiku", invocation.print.prompt);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", invocation.print.model_id);
    try std.testing.expect(!invocation.print.use_agent_loop);
    try std.testing.expect(!invocation.print.use_storage_auth);
}

test "print mode parses options that precede the prompt" {
    var arg_error: PrintModeArgError = .missing_prompt;
    const invocation = try parsePrintModeArgs(
        &[_][]const u8{ "--agent", "--storage", "--model", "claude-sonnet-4-5", "write a haiku" },
        &arg_error,
    );
    try std.testing.expectEqualStrings("write a haiku", invocation.print.prompt);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", invocation.print.model_id);
    try std.testing.expect(invocation.print.use_agent_loop);
    try std.testing.expect(invocation.print.use_storage_auth);
}

test "print mode parses options split around the prompt" {
    var arg_error: PrintModeArgError = .missing_prompt;
    const invocation = try parsePrintModeArgs(
        &[_][]const u8{ "--agent", "write a haiku", "--storage", "--model", "claude-sonnet-4-5" },
        &arg_error,
    );
    try std.testing.expectEqualStrings("write a haiku", invocation.print.prompt);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", invocation.print.model_id);
    try std.testing.expect(invocation.print.use_agent_loop);
    try std.testing.expect(invocation.print.use_storage_auth);
}

test "print mode keeps the default model when --model is absent" {
    var arg_error: PrintModeArgError = .missing_prompt;
    const invocation = try parsePrintModeArgs(&[_][]const u8{"write a haiku"}, &arg_error);
    try std.testing.expectEqualStrings(DEFAULT_PRINT_MODEL_ID, invocation.print.model_id);
}

test "print mode takes the last --model when repeated on both sides" {
    var arg_error: PrintModeArgError = .missing_prompt;
    const invocation = try parsePrintModeArgs(
        &[_][]const u8{ "--model", "first", "write a haiku", "--model", "second" },
        &arg_error,
    );
    try std.testing.expectEqualStrings("second", invocation.print.model_id);
}

test "print mode rejects a trailing --model without a value" {
    var arg_error: PrintModeArgError = .missing_prompt;
    try std.testing.expectError(
        error.InvalidArgument,
        parsePrintModeArgs(&[_][]const u8{ "write a haiku", "--model" }, &arg_error),
    );
    try std.testing.expect(std.meta.activeTag(arg_error) == .missing_option_value);
    try std.testing.expectEqualStrings("--model", arg_error.missing_option_value);
}

test "print mode rejects an unsupported option after the prompt" {
    var arg_error: PrintModeArgError = .missing_prompt;
    try std.testing.expectError(
        error.InvalidArgument,
        parsePrintModeArgs(&[_][]const u8{ "write a haiku", "--bogus" }, &arg_error),
    );
    try std.testing.expect(std.meta.activeTag(arg_error) == .unsupported_option);
    try std.testing.expectEqualStrings("--bogus", arg_error.unsupported_option);
}

test "print mode rejects a second positional argument" {
    var arg_error: PrintModeArgError = .missing_prompt;
    try std.testing.expectError(
        error.InvalidArgument,
        parsePrintModeArgs(&[_][]const u8{ "write a haiku", "and a limerick" }, &arg_error),
    );
    try std.testing.expect(std.meta.activeTag(arg_error) == .unexpected_argument);
    try std.testing.expectEqualStrings("and a limerick", arg_error.unexpected_argument);
}

test "print mode rejects options without a prompt" {
    var arg_error: PrintModeArgError = .{ .unsupported_option = "--sentinel" };
    try std.testing.expectError(
        error.InvalidArgument,
        parsePrintModeArgs(&[_][]const u8{ "--agent", "--model", "claude-sonnet-4-5" }, &arg_error),
    );
    try std.testing.expect(std.meta.activeTag(arg_error) == .missing_prompt);

    var empty_error: PrintModeArgError = .{ .unsupported_option = "--sentinel" };
    try std.testing.expectError(
        error.InvalidArgument,
        parsePrintModeArgs(&[_][]const u8{}, &empty_error),
    );
    try std.testing.expect(std.meta.activeTag(empty_error) == .missing_prompt);
}

test "print mode rejects an option token as a --model value" {
    var arg_error: PrintModeArgError = .missing_prompt;
    try std.testing.expectError(
        error.InvalidArgument,
        parsePrintModeArgs(&[_][]const u8{ "write a haiku", "--model", "--storage" }, &arg_error),
    );
    try std.testing.expect(std.meta.activeTag(arg_error) == .missing_option_value);
    try std.testing.expectEqualStrings("--model", arg_error.missing_option_value);

    var leading_error: PrintModeArgError = .missing_prompt;
    try std.testing.expectError(
        error.InvalidArgument,
        parsePrintModeArgs(&[_][]const u8{ "--model", "--agent", "write a haiku" }, &leading_error),
    );
    try std.testing.expect(std.meta.activeTag(leading_error) == .missing_option_value);
    try std.testing.expectEqualStrings("--model", leading_error.missing_option_value);
}

test "print mode rejects --tui-runtime once a prompt is set" {
    var arg_error: PrintModeArgError = .missing_prompt;
    try std.testing.expectError(
        error.InvalidArgument,
        parsePrintModeArgs(&[_][]const u8{ "first", "--tui-runtime", "second" }, &arg_error),
    );
    try std.testing.expect(std.meta.activeTag(arg_error) == .misplaced_option);
    try std.testing.expectEqualStrings("--tui-runtime", arg_error.misplaced_option);
}

test "print mode rejects an option token as a --tui-runtime prompt" {
    var arg_error: PrintModeArgError = .missing_prompt;
    try std.testing.expectError(
        error.InvalidArgument,
        parsePrintModeArgs(&[_][]const u8{ "--tui-runtime", "--model", "some-model" }, &arg_error),
    );
    try std.testing.expect(std.meta.activeTag(arg_error) == .missing_option_value);
    try std.testing.expectEqualStrings("--tui-runtime", arg_error.missing_option_value);
}

test "print mode short-circuits on --tui-runtime with its prompt" {
    var arg_error: PrintModeArgError = .missing_prompt;
    const invocation = try parsePrintModeArgs(
        &[_][]const u8{ "--tui-runtime", "write a haiku", "--model", "ignored" },
        &arg_error,
    );
    try std.testing.expect(std.meta.activeTag(invocation) == .tui_runtime);
    try std.testing.expectEqualStrings("write a haiku", invocation.tui_runtime);

    var missing_error: PrintModeArgError = .missing_prompt;
    try std.testing.expectError(
        error.InvalidArgument,
        parsePrintModeArgs(&[_][]const u8{"--tui-runtime"}, &missing_error),
    );
    try std.testing.expect(std.meta.activeTag(missing_error) == .missing_option_value);
    try std.testing.expectEqualStrings("--tui-runtime", missing_error.missing_option_value);
}
const OapModeArgs = struct {
    default_model_id: ?[]const u8 = null,
};

const OapArgError = struct {
    unknown_option: ?[]const u8 = null,
    missing_option_value: ?[]const u8 = null,
    unexpected_positional: ?[]const u8 = null,
};

fn parseOapModeArgs(args: []const []const u8, arg_error: *OapArgError) !OapModeArgs {
    var parsed = OapModeArgs{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--model")) {
            if (index + 1 >= args.len or std.mem.startsWith(u8, args[index + 1], "--")) {
                arg_error.missing_option_value = "--model";
                return error.InvalidArgument;
            }
            index += 1;
            parsed.default_model_id = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            arg_error.unknown_option = arg;
            return error.InvalidArgument;
        }
        arg_error.unexpected_positional = arg;
        return error.InvalidArgument;
    }
    return parsed;
}

const OAP_PROVIDER_PROFILE_REVISION = "ea5e5b9b29dc27a3e84eb6fe6a0f5055fb437988";

const OAP_PROVIDER_EXHAUSTED_MESSAGE = "makai --oap-provider: out of memory decoding a line on stdin; the endpoint is stopping rather than continuing in an unknown state\n";

test "the only failure that escapes handleLine is the one the stderr message names" {
    const E = @typeInfo(@typeInfo(@TypeOf(oap_provider_server.Server.handleLine)).@"fn".return_type.?).error_union.error_set;
    const escaping = @typeInfo(E).error_set.?;
    try std.testing.expectEqual(@as(usize, 1), escaping.len);
    try std.testing.expectEqualStrings("OutOfMemory", escaping[0].name);
}

fn oapProviderCompatibility(
    provider_id: []const u8,
    flags: provider_base_url.ProxyCompatFlags,
) oap_provider_types.CompatibilityFacts {
    return oap_provider_runtime.mapCompatibility(
        provider_base_url.transparentProxyCompatForFlags(provider_id, flags),
    ).facts;
}

fn oapModelCapabilities(
    allocator: std.mem.Allocator,
    builtin: oap_provider_catalog.BuiltInProvider,
) ![]const oap_provider_types.ModelCapability {
    var list = std.ArrayList(oap_provider_types.ModelCapability).empty;
    errdefer list.deinit(allocator);
    try list.append(allocator, .chat);
    try list.append(allocator, .streaming);
    if (builtin.supports_tools) try list.append(allocator, .tools);
    if (builtin.supports_reasoning) try list.append(allocator, .reasoning);
    return list.toOwnedSlice(allocator);
}

fn populateOapProviderCatalog(allocator: std.mem.Allocator, server: *oap_provider_server.Server) !void {
    const proxy_flags = try provider_base_url.proxyCompatFlagsFromEnv(allocator);
    for (oap_provider_catalog.BUILT_IN_PROVIDERS) |builtin| {
        const mapping = oap_provider_catalog.mapApiToWire(builtin.api) orelse continue;

        var provider_transferred = false;
        const id = try allocator.dupe(u8, builtin.id);
        errdefer if (!provider_transferred) allocator.free(id);
        const endpoint = try allocator.dupe(u8, builtin.endpoint);
        errdefer if (!provider_transferred) allocator.free(endpoint);

        const policies = try allocator.dupe(
            oap_provider_types.SnapshotPolicy,
            oap_provider_server.IMPLEMENTED_SNAPSHOT_POLICIES,
        );
        errdefer if (!provider_transferred) allocator.free(policies);

        const wire_id = if (mapping.wire_id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (!provider_transferred) {
            if (wire_id) |value| allocator.free(value);
        };

        const grant_kinds = if (oap_provider_grant_channel.GrantChannel.supported)
            try allocator.dupe(oap_provider_types.GrantKind, &.{.static})
        else
            try allocator.dupe(oap_provider_types.GrantKind, &.{});
        errdefer if (!provider_transferred) allocator.free(grant_kinds);

        try server.addProvider(.{
            .id = id,
            .wire = mapping.wire,
            .wire_id = wire_id,
            .framing = mapping.framing,
            .endpoint = endpoint,
            .allows_anonymous = builtin.allows_anonymous,
            .snapshot_policies = policies,
            .answers_sync = oap_provider_server.IMPLEMENTS_SYNC,
            .compatibility = oapProviderCompatibility(builtin.id, proxy_flags),
            .credential_grant = if (oap_provider_grant_channel.GrantChannel.supported) .out_of_band else .none,
            .grant_kinds = grant_kinds,
            .context_window = builtin.context_window,
            .max_output_tokens = builtin.max_output_tokens,
            .round_trips_carry = builtin.round_trips_carry,
        });
        provider_transferred = true;

        var model_transferred = false;
        const built_model_ref = try oap_provider_catalog.buildModelRef(
            allocator,
            builtin.id,
            mapping.wire,
            mapping.wire_id,
            builtin.model_id,
        );
        errdefer if (!model_transferred) allocator.free(built_model_ref);
        const model_id = try allocator.dupe(u8, builtin.model_id);
        errdefer if (!model_transferred) allocator.free(model_id);
        const display_name = try allocator.dupe(u8, builtin.display_name);
        errdefer if (!model_transferred) allocator.free(display_name);
        const provider_id = try allocator.dupe(u8, builtin.id);
        errdefer if (!model_transferred) allocator.free(provider_id);
        const capabilities = try oapModelCapabilities(allocator, builtin);
        errdefer if (!model_transferred) allocator.free(capabilities);

        try server.addModel(.{
            .model_ref = built_model_ref,
            .model_id = model_id,
            .display_name = display_name,
            .provider_id = provider_id,
            .wire = mapping.wire,
            .capabilities = capabilities,
            .context_window = builtin.context_window,
            .max_output_tokens = builtin.max_output_tokens,
            .source = .fallback,
            .auth_status = if (builtin.allows_anonymous) .authenticated else .unknown,
        });
        model_transferred = true;
    }
}

const OAP_PROVIDER_STREAM_IDLE_TTL_DEFAULT_MS: i64 = 120_000;

fn oapProviderStreamIdleTtlMs(allocator: std.mem.Allocator) i64 {
    const raw = provider_base_url.envOwnedOrNull(allocator, "MAKAI_OAP_PROVIDER_STREAM_IDLE_TTL_MS") catch
        return OAP_PROVIDER_STREAM_IDLE_TTL_DEFAULT_MS;
    const value = raw orelse return OAP_PROVIDER_STREAM_IDLE_TTL_DEFAULT_MS;
    defer allocator.free(value);
    const parsed = std.fmt.parseInt(i64, std.mem.trim(u8, value, " \t\r\n"), 10) catch
        return OAP_PROVIDER_STREAM_IDLE_TTL_DEFAULT_MS;
    if (parsed < 0) return OAP_PROVIDER_STREAM_IDLE_TTL_DEFAULT_MS;
    return parsed;
}

const OapGrantChannel = struct {
    nonce: []const u8,
    channel: oap_provider_grant_channel.GrantChannel,

    fn deinit(self: *OapGrantChannel, allocator: std.mem.Allocator) void {
        self.channel.deinit();
        allocator.free(self.nonce);
        self.* = undefined;
    }
};

const OapGrantedValue = struct {
    reference: []const u8,
    value: []const u8,

    fn deinit(self: *OapGrantedValue, allocator: std.mem.Allocator) void {
        allocator.free(self.reference);
        allocator.free(self.value);
        self.* = undefined;
    }
};

fn announceOapGrants(
    allocator: std.mem.Allocator,
    server: *oap_provider_server.Server,
    channels: *std.ArrayList(OapGrantChannel),
    ordinal: *u64,
) !bool {
    var did_work = false;
    while (server.nextUnannouncedGrant()) |grant| {
        const nonce = try allocator.dupe(u8, grant.nonce);
        errdefer allocator.free(nonce);

        var channel = oap_provider_grant_channel.GrantChannel.open(allocator, ordinal.*) catch {
            try server.refuseGrant(nonce, "the endpoint could not open a credential channel");
            allocator.free(nonce);
            did_work = true;
            continue;
        };
        ordinal.* += 1;
        errdefer channel.deinit();

        try channels.ensureUnusedCapacity(allocator, 1);
        try server.announceChannel(nonce, channel.path());
        channels.appendAssumeCapacity(.{ .nonce = nonce, .channel = channel });
        did_work = true;
    }
    return did_work;
}

fn pumpOapGrants(
    allocator: std.mem.Allocator,
    server: *oap_provider_server.Server,
    channels: *std.ArrayList(OapGrantChannel),
    granted: *std.ArrayList(OapGrantedValue),
    now_ms: i64,
) !bool {
    var did_work = false;
    var index: usize = 0;
    while (index < channels.items.len) {
        var entry = &channels.items[index];
        var settled = false;

        switch (try entry.channel.poll(entry.nonce)) {
            .pending => {},
            .rejected => {
                try server.refuseGrant(entry.nonce, "the credential channel closed without a value");
                settled = true;
            },
            .value => |value| {
                var owned_value = value;
                errdefer allocator.free(owned_value);
                const reference = try server.completeGrant(entry.nonce);
                try granted.ensureUnusedCapacity(allocator, 1);
                granted.appendAssumeCapacity(.{ .reference = reference, .value = owned_value });
                owned_value = &.{};
                settled = true;
            },
        }

        if (!settled and server.expiredGrantNonce(now_ms) != null) {
            try server.refuseGrant(entry.nonce, "no credential arrived before the deadline");
            settled = true;
        }

        if (!settled) {
            index += 1;
            continue;
        }

        var removed = channels.orderedRemove(index);
        removed.deinit(allocator);
        did_work = true;
    }

    server.burnExpiredGrants(now_ms);
    index = 0;
    while (index < granted.items.len) {
        if (server.holdsGrant(granted.items[index].reference)) {
            index += 1;
            continue;
        }
        var dropped = granted.orderedRemove(index);
        dropped.deinit(allocator);
        did_work = true;
    }
    return did_work;
}

fn grantedValueFor(granted: []const OapGrantedValue, reference: []const u8) ?[]const u8 {
    for (granted) |entry| {
        if (std.mem.eql(u8, entry.reference, reference)) return entry.value;
    }
    return null;
}

const RunningOapInference = struct {
    inference_id: []const u8,
    stream: *event_stream.AssistantMessageStream,
    context: ai_types.Context,
    model: ai_types.Model,
    cancelled: *std.atomic.Value(bool),
    last_progress_ms: i64,

    fn deinit(self: *RunningOapInference, allocator: std.mem.Allocator) void {
        self.cancelled.store(true, .release);
        _ = self.stream.deinitAndDestroy();
        if (self.inference_id.len > 0) allocator.free(self.inference_id);
        self.context.deinit(allocator);
        self.model.deinit(allocator);
        allocator.destroy(self.cancelled);
    }
};

fn builtInForProvider(provider_id: []const u8) ?oap_provider_catalog.BuiltInProvider {
    for (oap_provider_catalog.BUILT_IN_PROVIDERS) |builtin| {
        if (std.mem.eql(u8, builtin.id, provider_id)) return builtin;
    }
    return null;
}

fn failOapInference(
    server: *oap_provider_server.Server,
    inference_id: []const u8,
    code: oap_provider_types.ErrorCode,
    message: []const u8,
) !void {
    try server.settleFailed(inference_id, code, message, null);
    server.releaseInference(inference_id);
}

fn resolveOapStoredCredential(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
) ?auth_resolver.ResolvedKey {
    var storage = oauth_storage.AuthStorage.loadDefaultStoredOnly(allocator) catch return null;
    defer storage.deinit();
    const resolved = auth_resolver.resolveApiKey(allocator, &storage, provider_id, null) catch return null;
    if (resolved.api_key.len == 0) {
        var owned = resolved;
        owned.deinit(allocator);
        return null;
    }
    return resolved;
}

fn startOapInference(
    allocator: std.mem.Allocator,
    registry: *api_registry.ApiRegistry,
    server: *oap_provider_server.Server,
    running: *std.ArrayList(RunningOapInference),
    inference_id: []const u8,
    granted: []const OapGrantedValue,
) !void {
    const inference = server.findInference(inference_id) orelse return;

    const parsed = oap_provider_server.Server.parseModelRef(inference.model_ref) orelse {
        try failOapInference(server, inference_id, .invalid_request, "model_ref is not parseable");
        return;
    };
    const provider_id = parsed.provider_id;
    const model_id = parsed.model_id;

    const builtin = builtInForProvider(provider_id) orelse {
        try failOapInference(server, inference_id, .model_not_found, "no such provider");
        return;
    };

    const provider = registry.getApiProvider(builtin.api) orelse {
        try failOapInference(server, inference_id, .provider_unavailable, "the api is not registered");
        return;
    };

    var model = try buildOapInferenceModel(allocator, builtin, model_id);
    errdefer model.deinit(allocator);
    var context = try buildOapInferenceContext(allocator, inference.messages, .{
        .provider = model.provider,
        .api = model.api,
        .model_id = model.id,
    });
    errdefer context.deinit(allocator);
    context.tools = try buildOapInferenceTools(allocator, inference.tools);

    const cancelled = try allocator.create(std.atomic.Value(bool));
    errdefer allocator.destroy(cancelled);
    cancelled.* = std.atomic.Value(bool).init(false);

    var options: ai_types.StreamOptions = .{};
    options.requires_owned_stream_events = true;
    var resolved_credential: ?auth_resolver.ResolvedKey = null;
    defer if (resolved_credential) |*key| key.deinit(allocator);

    if (inference.credential_ref) |reference| {
        if (grantedValueFor(granted, reference)) |value| options.api_key = @TypeOf(options.api_key).initBorrowed(value);
    }
    if (options.getApiKey() == null or options.getApiKey().?.len == 0) {
        resolved_credential = resolveOapStoredCredential(allocator, builtin.id);
        if (resolved_credential) |key| options.api_key = @TypeOf(options.api_key).initBorrowed(key.api_key);
    }
    options.cancel_token = .{ .cancelled = cancelled };
    if (inference.max_output_tokens) |max| options.max_tokens = max;
    if (inference.temperature) |value| options.temperature = value;
    if (inference.tool_choice) |choice| options.tool_choice = switch (choice) {
        .auto => ai_types.ToolChoice{ .auto = {} },
        .none => ai_types.ToolChoice{ .none = {} },
        .required => ai_types.ToolChoice{ .required = {} },
        .function => |name| ai_types.ToolChoice{ .function = name },
    };
    applyOapReasoning(&options, inference.reasoning);

    const stream = provider.stream(model, context, options, allocator) catch |err| {
        const code: oap_provider_types.ErrorCode = switch (err) {
            error.MissingApiKey, error.AuthRequired => .credential_missing,
            error.AuthRefreshFailed => .credential_expired,
            else => .provider_unavailable,
        };
        const message = switch (err) {
            error.MissingApiKey, error.AuthRequired => "this provider needs a credential and none resolved",
            error.AuthRefreshFailed => "the stored credential could not be refreshed",
            else => "the provider refused the request",
        };
        model.deinit(allocator);
        context.deinit(allocator);
        allocator.destroy(cancelled);
        try failOapInference(server, inference_id, code, message);
        return;
    };
    errdefer {
        cancelled.store(true, .release);
        _ = stream.deinitAndDestroy();
    }

    const owned_id = try allocator.dupe(u8, inference_id);
    errdefer allocator.free(owned_id);
    try running.ensureUnusedCapacity(allocator, 1);

    running.appendAssumeCapacity(.{
        .inference_id = owned_id,
        .stream = stream,
        .context = context,
        .model = model,
        .cancelled = cancelled,
        .last_progress_ms = compat.time.nowMillis(),
    });
}

fn pumpOapInferences(
    allocator: std.mem.Allocator,
    server: *oap_provider_server.Server,
    running: *std.ArrayList(RunningOapInference),
    idle_ttl_ms: i64,
) !bool {
    var did_work = false;
    var index: usize = 0;
    while (index < running.items.len) {
        const entry = &running.items[index];
        var settled = false;

        if (server.findInference(entry.inference_id)) |inference| {
            if (inference.cancel_requested) entry.cancelled.store(true, .release);
        }

        if (idle_ttl_ms > 0 and compat.time.nowMillis() - entry.last_progress_ms > idle_ttl_ms) {
            entry.cancelled.store(true, .release);
        }

        while (entry.stream.poll()) |event| {
            did_work = true;
            entry.last_progress_ms = compat.time.nowMillis();
            defer entry.stream.releaseEvent(event);
            const terminal = event == .done or event == .@"error";
            oap_provider_runtime.pumpEvent(server, entry.inference_id, event) catch {
                if (terminal) {
                    server.abandonOpenPart(entry.inference_id);
                    server.settleFailed(
                        entry.inference_id,
                        .endpoint_error,
                        "the endpoint could not deliver the terminal for this inference",
                        null,
                    ) catch {};
                }
            };
            if (terminal) settled = true;
        }

        if (!settled and entry.stream.isDone()) {
            settleOapInference(server, entry) catch {
                server.abandonOpenPart(entry.inference_id);
                server.settleFailed(
                    entry.inference_id,
                    .endpoint_error,
                    "the endpoint could not assemble a terminal for this inference",
                    null,
                ) catch {};
            };
            settled = true;
            did_work = true;
        }

        if (!settled) {
            index += 1;
            continue;
        }

        var removed = running.orderedRemove(index);
        server.releaseInference(removed.inference_id);
        removed.deinit(allocator);
    }
    return did_work;
}

fn settleOapInference(
    server: *oap_provider_server.Server,
    entry: *const RunningOapInference,
) !void {
    if (entry.stream.getError()) |message| {
        const cancelled_by_caller = if (server.findInference(entry.inference_id)) |inference|
            inference.cancel_requested
        else
            false;
        if (cancelled_by_caller) {
            try server.settleFailed(
                entry.inference_id,
                .aborted,
                "the caller cancelled this inference",
                null,
            );
        } else {
            try server.settleFailed(entry.inference_id, .provider_unavailable, message, null);
        }
        return;
    }

    const result = entry.stream.getResult() orelse {
        try server.settleFailed(
            entry.inference_id,
            .provider_unavailable,
            "the provider stream ended with no result",
            null,
        );
        return;
    };

    const usage = oap_types.Usage{
        .input_tokens = result.usage.input,
        .output_tokens = result.usage.output,
        .total_tokens = if (result.usage.total_tokens > 0)
            result.usage.total_tokens
        else
            result.usage.input + result.usage.output,
    };

    if (result.stop_reason == .@"error") {
        try server.settleFailed(
            entry.inference_id,
            .provider_unavailable,
            result.getErrorMessage() orelse "the provider reported a failure",
            usage,
        );
        return;
    }

    try server.settleCompletedFromResult(
        entry.inference_id,
        oap_provider_runtime.mapStopReason(result.stop_reason),
        usage,
        result.content,
    );
}

fn buildOapInferenceModel(
    allocator: std.mem.Allocator,
    builtin: oap_provider_catalog.BuiltInProvider,
    model_id: []const u8,
) !ai_types.Model {
    const id = try allocator.dupe(u8, model_id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, model_id);
    errdefer allocator.free(name);
    const api = try allocator.dupe(u8, builtin.api);
    errdefer allocator.free(api);
    const provider = try allocator.dupe(u8, builtin.id);
    errdefer allocator.free(provider);
    const base_url = provider_base_url.defaultBaseUrlForRef(allocator, builtin.id, builtin.api) catch
        try allocator.dupe(u8, builtin.endpoint);
    errdefer allocator.free(base_url);
    const input = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(input);
    input[0] = try allocator.dupe(u8, "text");

    return ai_types.Model{
        .id = id,
        .name = name,
        .api = api,
        .provider = provider,
        .base_url = base_url,
        .reasoning = builtin.supports_reasoning,
        .input = input,
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = builtin.context_window,
        .max_tokens = builtin.max_output_tokens,
        .allows_anonymous = builtin.allows_anonymous,
        .is_owned = true,
    };
}

fn oapRoleIsSystem(role: oap_types.Role) bool {
    return role == .system or role == .developer;
}

fn oapMessageText(allocator: std.mem.Allocator, message: oap_types.Message) ![]const u8 {
    return switch (message.content) {
        .text => |value| try allocator.dupe(u8, value),
        .parts => |parts| blk: {
            var buffer = std.ArrayList(u8).empty;
            errdefer buffer.deinit(allocator);
            for (parts) |part| {
                switch (part) {
                    .text => |value| try buffer.appendSlice(allocator, value),
                    else => {},
                }
            }
            break :blk try buffer.toOwnedSlice(allocator);
        },
    };
}

fn buildOapInferenceTools(
    allocator: std.mem.Allocator,
    source: []const oap_provider_types.ToolDefinition,
) !?[]const ai_types.Tool {
    if (source.len == 0) return null;
    const out = try allocator.alloc(ai_types.Tool, source.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*tool| tool.deinit(allocator);
        allocator.free(out);
    }
    for (source, 0..) |tool, index| {
        const name = try allocator.dupe(u8, tool.name);
        errdefer allocator.free(name);
        const description = try allocator.dupe(u8, tool.description orelse "");
        errdefer allocator.free(description);
        const schema = try allocator.dupe(u8, tool.input_schema_json orelse "{\"type\":\"object\"}");
        out[index] = .{ .name = name, .description = description, .parameters_schema_json = schema };
        built += 1;
    }
    return out;
}

fn applyOapReasoning(options: *ai_types.StreamOptions, reasoning: ?oap_provider_types.ReasoningOptions) void {
    const source = reasoning orelse return;
    if (source.enabled) |enabled| {
        options.thinking_enabled = enabled;
        options.reasoning_enabled = enabled;
    }
    if (source.budget_tokens) |budget| options.thinking_budget_tokens = budget;
    if (source.effort) |effort| {
        options.thinking_effort = @TypeOf(options.thinking_effort).initBorrowed(effort);
        options.reasoning_effort = @TypeOf(options.reasoning_effort).initBorrowed(effort);
    }
}

const OapModelIdentity = struct {
    provider: []const u8,
    api: []const u8,
    model_id: []const u8,
};

fn buildOapInferenceContext(
    allocator: std.mem.Allocator,
    source: []const oap_types.Message,
    identity: OapModelIdentity,
) !ai_types.Context {
    var system = std.ArrayList(u8).empty;
    errdefer system.deinit(allocator);

    var built_messages = std.ArrayList(ai_types.Message).empty;
    errdefer {
        for (built_messages.items) |*message| message.deinit(allocator);
        built_messages.deinit(allocator);
    }

    for (source) |message| {
        if (message.role == .assistant) {
            const content = try oapAssistantContent(allocator, message);
            const assistant = try buildOapAssistantMessage(allocator, content, identity);
            var assistant_transferred = false;
            errdefer if (!assistant_transferred) {
                var owned = assistant;
                owned.deinit(allocator);
            };
            try built_messages.ensureUnusedCapacity(allocator, 1);
            built_messages.appendAssumeCapacity(.{ .assistant = assistant });
            assistant_transferred = true;
            continue;
        }

        if (oapMessageToolResults(message)) |parts| {
            for (parts) |part| {
                if (part != .tool_result) continue;
                const result = try buildOapToolResult(allocator, part.tool_result, source);
                var result_transferred = false;
                errdefer if (!result_transferred) {
                    var owned = result;
                    owned.deinit(allocator);
                };
                try built_messages.ensureUnusedCapacity(allocator, 1);
                built_messages.appendAssumeCapacity(.{ .tool_result = result });
                result_transferred = true;
            }

            const spoken = try oapMessageText(allocator, message);
            errdefer allocator.free(spoken);
            if (spoken.len == 0) {
                allocator.free(spoken);
                continue;
            }
            try built_messages.ensureUnusedCapacity(allocator, 1);
            built_messages.appendAssumeCapacity(.{
                .user = .{ .content = .{ .text = spoken }, .timestamp = compat.time.nowMillis() },
            });
            continue;
        }

        const text = try oapMessageText(allocator, message);
        if (oapRoleIsSystem(message.role)) {
            defer allocator.free(text);
            if (system.items.len > 0) try system.appendSlice(allocator, "\n\n");
            try system.appendSlice(allocator, text);
            continue;
        }
        errdefer allocator.free(text);
        try built_messages.ensureUnusedCapacity(allocator, 1);
        built_messages.appendAssumeCapacity(.{ .user = .{ .content = .{ .text = text }, .timestamp = compat.time.nowMillis() } });
    }

    const messages = try built_messages.toOwnedSlice(allocator);
    errdefer {
        for (messages) |*message| message.deinit(allocator);
        allocator.free(messages);
    }

    const system_prompt = try system.toOwnedSlice(allocator);
    errdefer allocator.free(system_prompt);

    return ai_types.Context{
        .system_prompt = ai_types.OwnedSlice(u8).initOwned(system_prompt),
        .messages = messages,
        .is_owned = true,
    };
}

fn oapMessageToolResults(message: oap_types.Message) ?[]const oap_types.ContentPart {
    const parts = switch (message.content) {
        .parts => |value| value,
        else => return null,
    };
    for (parts) |part| {
        if (part == .tool_result) return parts;
    }
    return null;
}

fn oapToolNameForCall(source: []const oap_types.Message, tool_call_id: []const u8) []const u8 {
    for (source) |message| {
        const parts = switch (message.content) {
            .parts => |value| value,
            else => continue,
        };
        for (parts) |part| {
            if (part != .tool_call) continue;
            if (std.mem.eql(u8, part.tool_call.tool_call_id, tool_call_id)) return part.tool_call.name;
        }
    }
    return "";
}

fn buildOapToolResult(
    allocator: std.mem.Allocator,
    part: oap_types.ToolResultPart,
    source: []const oap_types.Message,
) !ai_types.ToolResultMessage {
    const id = try allocator.dupe(u8, part.tool_call_id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, oapToolNameForCall(source, part.tool_call_id));
    errdefer allocator.free(name);
    const body = try allocator.dupe(u8, part.result_json);
    errdefer allocator.free(body);
    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    content[0] = .{ .text = .{ .text = body } };

    return ai_types.ToolResultMessage{
        .tool_call_id = id,
        .tool_name = name,
        .content = content,
        .is_error = part.is_error orelse false,
        .timestamp = compat.time.nowMillis(),
    };
}

fn oapAssistantContent(
    allocator: std.mem.Allocator,
    message: oap_types.Message,
) ![]ai_types.AssistantContent {
    var blocks = std.ArrayList(ai_types.AssistantContent).empty;
    errdefer {
        ai_types.deinitAssistantContentElements(allocator, blocks.items);
        blocks.deinit(allocator);
    }

    switch (message.content) {
        .text => |value| {
            const owned = try allocator.dupe(u8, value);
            errdefer allocator.free(owned);
            try blocks.append(allocator, .{ .text = .{ .text = owned } });
        },
        .parts => |parts| {
            for (parts) |part| switch (part) {
                .text => |value| {
                    const owned = try allocator.dupe(u8, value);
                    errdefer allocator.free(owned);
                    try blocks.append(allocator, .{ .text = .{ .text = owned } });
                },
                .reasoning => |value| {
                    const owned = try allocator.dupe(u8, value.text);
                    errdefer allocator.free(owned);
                    const signature = if (value.carry) |carry| try allocator.dupe(u8, carry) else null;
                    errdefer if (signature) |owned_carry| allocator.free(owned_carry);
                    try blocks.append(allocator, .{ .thinking = .{
                        .thinking = owned,
                        .thinking_signature = signature,
                    } });
                },
                .tool_call => |value| {
                    const id = try allocator.dupe(u8, value.tool_call_id);
                    errdefer allocator.free(id);
                    const name = try allocator.dupe(u8, value.name);
                    errdefer allocator.free(name);
                    const arguments = try allocator.dupe(u8, value.arguments_json);
                    errdefer allocator.free(arguments);
                    const signature = if (value.carry) |carry| try allocator.dupe(u8, carry) else null;
                    errdefer if (signature) |owned_carry| allocator.free(owned_carry);
                    try blocks.append(allocator, .{ .tool_call = .{
                        .id = id,
                        .name = name,
                        .arguments_json = arguments,
                        .thought_signature = signature,
                    } });
                },
                else => {},
            };
        },
    }

    return blocks.toOwnedSlice(allocator);
}

fn buildOapAssistantMessage(
    allocator: std.mem.Allocator,
    content: []ai_types.AssistantContent,
    identity: OapModelIdentity,
) !ai_types.AssistantMessage {
    errdefer ai_types.deinitAssistantContent(allocator, content);
    const api = try allocator.dupe(u8, identity.api);
    errdefer allocator.free(api);
    const provider = try allocator.dupe(u8, identity.provider);
    errdefer allocator.free(provider);
    const model = try allocator.dupe(u8, identity.model_id);

    return ai_types.AssistantMessage{
        .content = content,
        .api = api,
        .provider = provider,
        .model = model,
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = compat.time.nowMillis(),
        .is_owned = true,
    };
}

fn oapSpecimenRequestId(line: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    if (std.mem.indexOf(u8, line, "\"control\"") == null) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const control = parsed.value.object.get("control") orelse return null;
    if (control != .string) return null;
    if (!std.mem.eql(u8, control.string, "specimen")) return null;
    const id = parsed.value.object.get("id") orelse return try allocator.dupe(u8, "");
    if (id != .string) return try allocator.dupe(u8, "");
    return try allocator.dupe(u8, id.string);
}

fn runOapProviderMode(
    allocator: std.mem.Allocator,
    stdin: std.Io.File,
    stdout: std.Io.File,
    stderr: std.Io.File,
    answers_specimens: bool,
) !void {
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    var server = oap_provider_server.Server.init(allocator, .{
        .capability_revision = VERSION,
        .grant_channel = if (oap_provider_grant_channel.GrantChannel.supported) .out_of_band else .unsupported,
        .accepts_inference = true,
        .resolves_own_credentials = true,
        .profile_revision = OAP_PROVIDER_PROFILE_REVISION,
    });
    defer server.deinit();

    var grant_channels = std.ArrayList(OapGrantChannel).empty;
    defer {
        for (grant_channels.items) |*entry| entry.deinit(allocator);
        grant_channels.deinit(allocator);
    }
    var granted_values = std.ArrayList(OapGrantedValue).empty;
    defer {
        for (granted_values.items) |*entry| entry.deinit(allocator);
        granted_values.deinit(allocator);
    }
    var grant_ordinal: u64 = 0;

    const idle_ttl_ms = oapProviderStreamIdleTtlMs(allocator);

    var running = std.ArrayList(RunningOapInference).empty;
    defer {
        for (running.items) |*entry| entry.deinit(allocator);
        running.deinit(allocator);
    }

    try populateOapProviderCatalog(allocator, &server);

    var async_receiver = stdio.AsyncStdioReceiver.initWithFile(stdin);
    var stdin_handle = try async_receiver.receiveStreamWithHandle(allocator);
    defer _ = stdin_handle.deinit(STDIO_THREAD_JOIN_TIMEOUT_MS);
    const stdin_stream = stdin_handle.getStream();

    while (true) {
        var did_work = false;

        while (stdin_stream.poll()) |chunk| {
            var mutable_chunk = chunk;
            defer mutable_chunk.deinit(allocator);

            const line = std.mem.trim(u8, mutable_chunk.data, " \t\r\n");
            if (line.len == 0) continue;

            if (try oapSpecimenRequestId(line, allocator)) |request_id| {
                defer allocator.free(request_id);
                if (answers_specimens) {
                    try server.emitSpecimens(request_id);
                } else {
                    try server.emitSpecimenError(
                        request_id,
                        "this endpoint was not started with --specimens",
                    );
                }
                did_work = true;
                continue;
            }

            server.handleLine(line) catch |err| {
                _ = try drainOapProviderOutbound(stdout, allocator, &server);
                try compat.stdio.writeAll(stderr, OAP_PROVIDER_EXHAUSTED_MESSAGE);
                return err;
            };
            did_work = true;
        }

        if (try announceOapGrants(allocator, &server, &grant_channels, &grant_ordinal)) did_work = true;
        if (try pumpOapGrants(allocator, &server, &grant_channels, &granted_values, compat.time.nowMillis())) did_work = true;

        while (server.popPendingStart()) |inference_id| {
            defer allocator.free(inference_id);
            try startOapInference(allocator, &registry, &server, &running, inference_id, granted_values.items);
            did_work = true;
        }

        if (try pumpOapInferences(allocator, &server, &running, idle_ttl_ms)) did_work = true;

        if (try drainOapProviderOutbound(stdout, allocator, &server)) did_work = true;

        if (stdin_stream.isDone() and !stdin_stream.hasPending() and running.items.len == 0 and !did_work) break;
        if (!did_work) compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
    }

    _ = try drainOapProviderOutbound(stdout, allocator, &server);
}

fn drainOapProviderOutbound(
    stdout: std.Io.File,
    allocator: std.mem.Allocator,
    server: *oap_provider_server.Server,
) !bool {
    var wrote = false;
    while (server.popOutbound()) |line| {
        defer allocator.free(line);
        try compat.stdio.writeAll(stdout, line);
        try compat.stdio.writeAll(stdout, "\n");
        wrote = true;
    }
    return wrote;
}

fn runOapMode(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdin: std.Io.File,
    stdout: std.Io.File,
    stderr: std.Io.File,
) !void {
    var arg_error = OapArgError{};
    const parsed = parseOapModeArgs(args, &arg_error) catch |err| {
        if (arg_error.unknown_option) |option| {
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "unknown --oap option: {s}\n\n", .{option});
            try compat.stdio.writeAll(stderr, msg);
        } else if (arg_error.missing_option_value) |option| {
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "{s} requires a value\n\n", .{option});
            try compat.stdio.writeAll(stderr, msg);
        } else if (arg_error.unexpected_positional) |value| {
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "--oap takes no positional argument: {s}\n\n", .{value});
            try compat.stdio.writeAll(stderr, msg);
        }
        try printUsage(stderr);
        return err;
    };

    const env_model = try provider_base_url.envOwnedOrNull(allocator, "MAKAI_OAP_MODEL");
    defer if (env_model) |value| allocator.free(value);
    const default_model_id: ?[]const u8 = parsed.default_model_id orelse env_model;

    var stdio_loop = try StdioProtocolLoop.initWithBuiltins(allocator);
    defer stdio_loop.deinit();

    var oap = try oap_server.Server.init(allocator, .{
        .endpoint_version = VERSION,
        .default_model_id = default_model_id,
    });
    defer oap.deinit();

    var bridge = oap_bridge.Bridge.init(allocator);
    defer bridge.deinit();

    var async_receiver = stdio.AsyncStdioReceiver.initWithFile(stdin);
    var stdin_handle = try async_receiver.receiveStreamWithHandle(allocator);
    defer _ = stdin_handle.deinit(STDIO_THREAD_JOIN_TIMEOUT_MS);
    const stdin_stream = stdin_handle.getStream();

    var native_lines = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &native_lines);
        native_lines.deinit(allocator);
    }
    var submission_lines = std.ArrayList([]const u8).empty;
    defer {
        clearOwnedLines(allocator, &submission_lines);
        submission_lines.deinit(allocator);
    }

    while (true) {
        var did_work = false;

        while (stdin_stream.poll()) |chunk| {
            var mutable_chunk = chunk;
            defer mutable_chunk.deinit(allocator);

            const line = std.mem.trim(u8, mutable_chunk.data, " \t\r\n");
            if (line.len == 0) continue;
            oap.handleLine(line) catch |err| switch (err) {
                error.MalformedLine, error.UnaddressableEnvelope => {
                    _ = try writeOapOutbound(stdout, allocator, &oap);
                    const message = if (err == error.MalformedLine)
                        OAP_MALFORMED_LINE_MESSAGE
                    else
                        OAP_UNADDRESSABLE_ENVELOPE_MESSAGE;
                    try compat.stdio.writeAll(stderr, message);
                    return err;
                },
                else => return err,
            };
            did_work = true;
        }

        while (oap.popEvictedSession()) |evicted| {
            defer allocator.free(evicted);
            bridge.forgetSession(evicted);
            did_work = true;
        }

        if (try pumpOapIntents(allocator, &oap, &bridge, &stdio_loop, &submission_lines)) did_work = true;

        if (stdin_stream.isDone() and !stdin_stream.hasPending()) {
            stdio_loop.markStdinDisconnected();
            if (oap.hasActiveRun()) {
                if (try bridge.failUnmappedActiveRuns(&oap, OAP_EOF_MESSAGE)) did_work = true;
            }
        }

        const forwarded = stdio_loop.pumpBackground() catch |err| blk: {
            try emitOapRuntimeFailure(&oap, &bridge, @errorName(err));
            break :blk 0;
        };
        if (forwarded > 0) did_work = true;

        const drained = stdio_loop.drainOutbound(&native_lines) catch |err| blk: {
            try emitOapRuntimeFailure(&oap, &bridge, @errorName(err));
            break :blk 0;
        };
        if (drained > 0 or native_lines.items.len > 0) {
            for (native_lines.items) |native_line| {
                try bridge.applyNativeLine(&oap, native_line);
            }
            clearOwnedLines(allocator, &native_lines);
            did_work = true;
        }

        if (try writeOapOutbound(stdout, allocator, &oap)) did_work = true;

        if (stdin_stream.isDone() and !did_work and !stdio_loop.hasActiveProviderStreams() and
            !stdio_loop.hasActiveAgentRuns() and !stdio_loop.hasActiveAuthFlows())
        {
            break;
        }

        if (!did_work) compat.time.sleepNs(STDIO_IDLE_SLEEP_NS);
    }

    _ = try writeOapOutbound(stdout, allocator, &oap);
}

const OAP_EOF_MESSAGE = "the makai host reached end of input before the run settled";
const OAP_MALFORMED_LINE_MESSAGE = "makai --oap: stdin carried a line that is not an OAP envelope or control frame; the stream's framing is in doubt and the endpoint will not resynchronise\n";
const OAP_UNADDRESSABLE_ENVELOPE_MESSAGE = "makai --oap: stdin carried an envelope with no id; every response this binding defines is correlated by in_reply_to, so no refusal could be addressed to it\n";

fn pumpOapIntents(
    allocator: std.mem.Allocator,
    oap: *oap_server.Server,
    bridge: *oap_bridge.Bridge,
    stdio_loop: *StdioProtocolLoop,
    submission_lines: *std.ArrayList([]const u8),
) !bool {
    var did_work = false;

    while (oap.popPendingSubmission()) |item| {
        var pending = item;
        defer pending.deinit(allocator);

        bridge.appendSubmissionLines(pending, submission_lines) catch |err| {
            clearOwnedLines(allocator, submission_lines);
            try oap.settleFailed(pending.session_id, .internal_error, @errorName(err));
            did_work = true;
            continue;
        };
        for (submission_lines.items) |line| {
            const dispatched = stdio_loop.dispatchInboundLine(line) catch |err| {
                try oap.settleFailed(pending.session_id, .internal_error, @errorName(err));
                break;
            };
            if (!dispatched) {
                try oap.settleFailed(
                    pending.session_id,
                    .internal_error,
                    "the native agent host rejected the translated submission",
                );
                break;
            }
        }
        clearOwnedLines(allocator, submission_lines);
        did_work = true;
    }

    while (oap.popPendingCancel()) |item| {
        var pending = item;
        defer pending.deinit(allocator);

        const maybe_line = bridge.cancelLine(pending) catch null;
        const line = maybe_line orelse continue;
        defer allocator.free(line);
        _ = stdio_loop.dispatchInboundLine(line) catch {};
        did_work = true;
    }

    return did_work;
}

fn emitOapRuntimeFailure(
    oap: *oap_server.Server,
    bridge: *oap_bridge.Bridge,
    reason: []const u8,
) !void {
    if (!oap.hasActiveRun()) return;
    try bridge.failActiveRuns(oap, reason);
}

fn writeOapOutbound(
    stdout: std.Io.File,
    allocator: std.mem.Allocator,
    oap: *oap_server.Server,
) !bool {
    var wrote = false;
    while (oap.popOutbound()) |line| {
        defer allocator.free(line);
        try compat.stdio.writeLine(stdout, line);
        wrote = true;
    }
    return wrote;
}

test "oap mode arguments accept a default model" {
    var arg_error = OapArgError{};
    const parsed = try parseOapModeArgs(&[_][]const u8{ "--model", "anthropic/anthropic-messages@claude" }, &arg_error);
    try std.testing.expectEqualStrings("anthropic/anthropic-messages@claude", parsed.default_model_id.?);
}

test "oap mode arguments default to no configured model" {
    var arg_error = OapArgError{};
    const parsed = try parseOapModeArgs(&[_][]const u8{}, &arg_error);
    try std.testing.expect(parsed.default_model_id == null);
}

test "oap mode rejects unknown options, missing values, and positionals" {
    var unknown = OapArgError{};
    try std.testing.expectError(
        error.InvalidArgument,
        parseOapModeArgs(&[_][]const u8{"--stdio"}, &unknown),
    );
    try std.testing.expectEqualStrings("--stdio", unknown.unknown_option.?);

    var missing = OapArgError{};
    try std.testing.expectError(
        error.InvalidArgument,
        parseOapModeArgs(&[_][]const u8{"--model"}, &missing),
    );
    try std.testing.expectEqualStrings("--model", missing.missing_option_value.?);

    var followed = OapArgError{};
    try std.testing.expectError(
        error.InvalidArgument,
        parseOapModeArgs(&[_][]const u8{ "--model", "--other" }, &followed),
    );
    try std.testing.expectEqualStrings("--model", followed.missing_option_value.?);

    var positional = OapArgError{};
    try std.testing.expectError(
        error.InvalidArgument,
        parseOapModeArgs(&[_][]const u8{"write a haiku"}, &positional),
    );
    try std.testing.expectEqualStrings("write a haiku", positional.unexpected_positional.?);
}

test "every provider the oap endpoint advertises accepts an inference" {
    const allocator = std.testing.allocator;

    var server = oap_provider_server.Server.init(allocator, .{
        .capability_revision = VERSION,
        .grant_channel = .unsupported,
        .accepts_inference = true,
        .resolves_own_credentials = true,
    });
    defer server.deinit();

    try populateOapProviderCatalog(allocator, &server);
    try std.testing.expect(server.providers.items.len > 0);
    try std.testing.expectEqual(server.providers.items.len, server.models.items.len);

    for (server.models.items, 0..) |entry, index| {
        const payload = try std.fmt.allocPrint(
            allocator,
            "{{\"model_ref\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"hi\"}}]}}",
            .{entry.model_ref},
        );
        defer allocator.free(payload);

        const line = try std.fmt.allocPrint(
            allocator,
            "{{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"{s}\",\"type\":\"inference.create.request\",\"id\":\"q{d}\",\"payload\":{s}}}",
            .{ oap_provider_types.PROFILE, index, payload },
        );
        defer allocator.free(line);
        try server.handleLine(line);

        const outbound = server.popOutbound() orelse return error.TestExpectedOutbound;
        defer allocator.free(outbound);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, outbound, .{});
        defer parsed.deinit();

        const response_payload = parsed.value.object.get("payload").?.object;
        const accepted = response_payload.get("accepted").?.bool;
        if (!accepted) {
            const message = response_payload.get("error").?.object.get("message").?.string;
            std.debug.print("\n{s} refused at create: {s}\n", .{ entry.model_ref, message });
        }
        try std.testing.expect(accepted);
    }
}

test "a failed start releases the inference it could not run" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var server = oap_provider_server.Server.init(allocator, .{
        .capability_revision = VERSION,
        .grant_channel = .unsupported,
        .accepts_inference = true,
        .resolves_own_credentials = true,
    });
    defer server.deinit();

    try populateOapProviderCatalog(allocator, &server);

    var running = std.ArrayList(RunningOapInference).empty;
    defer running.deinit(allocator);

    const entry = server.models.items[0];
    const line = try std.fmt.allocPrint(
        allocator,
        "{{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"{s}\",\"type\":\"inference.create.request\",\"id\":\"q1\",\"payload\":{{\"model_ref\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"hi\"}}]}}}}",
        .{ oap_provider_types.PROFILE, entry.model_ref },
    );
    defer allocator.free(line);
    try server.handleLine(line);
    while (server.popOutbound()) |out| allocator.free(out);

    try std.testing.expectEqual(@as(usize, 1), server.active.items.len);
    const inference_id = try allocator.dupe(u8, server.active.items[0].id);
    defer allocator.free(inference_id);

    try startOapInference(allocator, &registry, &server, &running, inference_id, &.{});

    try std.testing.expectEqual(@as(usize, 0), running.items.len);
    if (server.active.items.len != 0) {
        std.debug.print(
            "\na failed start left {d} inference(s) in server.active\n",
            .{server.active.items.len},
        );
        return error.FailedStartLeakedInference;
    }
    while (server.popOutbound()) |out| allocator.free(out);
}

fn settleTestInference(
    allocator: std.mem.Allocator,
    server: *oap_provider_server.Server,
    cancel_first: bool,
) !oap_provider_types.ErrorCode {
    const line =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ oap_provider_types.PROFILE ++
        "\",\"type\":\"inference.create.request\",\"id\":\"q1\",\"payload\":{\"model_ref\":\"ollama/other:ollama-chat@llama3\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}}";
    try server.handleLine(line);
    while (server.popOutbound()) |out| allocator.free(out);

    const inference_id = try allocator.dupe(u8, server.active.items[0].id);
    defer allocator.free(inference_id);

    if (cancel_first) server.active.items[0].cancel_requested = true;

    const stream = try allocator.create(event_stream.AssistantMessageStream);
    stream.* = event_stream.AssistantMessageStream.init(allocator);
    stream.completeWithError("request cancelled");

    const cancelled = try allocator.create(std.atomic.Value(bool));
    cancelled.* = std.atomic.Value(bool).init(true);

    var entry = RunningOapInference{
        .inference_id = inference_id,
        .stream = stream,
        .context = .{ .messages = &.{} },
        .model = .{
            .id = "m", .name = "m", .api = "ollama", .provider = "ollama", .base_url = "",
            .reasoning = false, .input = &.{},
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
            .context_window = 1, .max_tokens = 1,
        },
        .cancelled = cancelled,
        .last_progress_ms = 0,
    };
    defer {
        _ = stream.deinitAndDestroy();
        allocator.destroy(cancelled);
    }

    try settleOapInference(server, &entry);
    const out = server.popOutbound() orelse return error.TestExpectedOutbound;
    defer allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const code = parsed.value.object.get("payload").?.object.get("error").?.object.get("code").?.string;
    return oap_provider_types.ErrorCode.parse(code).?;
}

test "a cancelled inference settles as aborted and a failed one does not" {
    const allocator = std.testing.allocator;

    var cancelled_server = oap_provider_server.Server.init(allocator, .{ .accepts_inference = true, .resolves_own_credentials = true });
    defer cancelled_server.deinit();
    try populateOapProviderCatalog(allocator, &cancelled_server);
    const cancelled_code = try settleTestInference(allocator, &cancelled_server, true);
    try std.testing.expectEqual(oap_provider_types.ErrorCode.aborted, cancelled_code);
    try std.testing.expectEqual(oap_provider_types.ErrorAction.accept, cancelled_code.action());

    var failed_server = oap_provider_server.Server.init(allocator, .{ .accepts_inference = true, .resolves_own_credentials = true });
    defer failed_server.deinit();
    try populateOapProviderCatalog(allocator, &failed_server);
    const failed_code = try settleTestInference(allocator, &failed_server, false);
    try std.testing.expectEqual(oap_provider_types.ErrorCode.provider_unavailable, failed_code);
    try std.testing.expectEqual(oap_provider_types.ErrorAction.retry, failed_code.action());
}

test "the host drops a granted secret when the grant passes its expiry" {
    const allocator = std.testing.allocator;

    var server = oap_provider_server.Server.init(allocator, .{
        .capability_revision = VERSION,
        .grant_channel = .out_of_band,
        .accepts_inference = true,
        .resolves_own_credentials = false,
        .profile_revision = OAP_PROVIDER_PROFILE_REVISION,
        .default_grant_ttl_ms = 1_000,
    });
    defer server.deinit();
    try populateOapProviderCatalog(allocator, &server);

    var channels = std.ArrayList(OapGrantChannel).empty;
    defer {
        for (channels.items) |*entry| entry.deinit(allocator);
        channels.deinit(allocator);
    }
    var granted = std.ArrayList(OapGrantedValue).empty;
    defer {
        for (granted.items) |*entry| entry.deinit(allocator);
        granted.deinit(allocator);
    }
    var ordinal: u64 = 78000;

    const request =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ oap_provider_types.PROFILE ++
        "\",\"type\":\"provider.credential.grant.request\",\"id\":\"g1\",\"payload\":{\"provider_id\":\"anthropic\",\"nonce\":\"n-exp\"}}";
    try server.handleLine(request);

    try std.testing.expect(try announceOapGrants(allocator, &server, &channels, &ordinal));
    const announced = server.popOutbound() orelse return error.TestExpectedOutbound;
    defer allocator.free(announced);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, announced, .{});
    defer parsed.deinit();
    const channel_path = parsed.value.object.get("payload").?.object.get("channel").?.string;

    try oap_provider_grant_channel.connectAndWrite(channel_path, "n-exp\nsk-expiring-secret");

    var rounds: usize = 0;
    while (rounds < 200 and granted.items.len == 0) : (rounds += 1) {
        _ = try pumpOapGrants(allocator, &server, &channels, &granted, compat.time.nowMillis());
    }
    try std.testing.expectEqual(@as(usize, 1), granted.items.len);
    try std.testing.expectEqualStrings("sk-expiring-secret", granted.items[0].value);
    try std.testing.expect(server.holdsGrant(granted.items[0].reference));

    _ = try pumpOapGrants(allocator, &server, &channels, &granted, compat.time.nowMillis() + 60_000);

    try std.testing.expectEqual(@as(usize, 0), granted.items.len);
    try std.testing.expectEqual(@as(usize, 0), server.grants.items.len);
}

test "a granted credential crosses the side channel and reaches the inference" {
    const allocator = std.testing.allocator;

    var server = oap_provider_server.Server.init(allocator, .{
        .capability_revision = VERSION,
        .grant_channel = .out_of_band,
        .accepts_inference = true,
        .resolves_own_credentials = false,
        .profile_revision = OAP_PROVIDER_PROFILE_REVISION,
    });
    defer server.deinit();
    try populateOapProviderCatalog(allocator, &server);

    var channels = std.ArrayList(OapGrantChannel).empty;
    defer {
        for (channels.items) |*entry| entry.deinit(allocator);
        channels.deinit(allocator);
    }
    var granted = std.ArrayList(OapGrantedValue).empty;
    defer {
        for (granted.items) |*entry| entry.deinit(allocator);
        granted.deinit(allocator);
    }
    var ordinal: u64 = 77000;

    const request =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ oap_provider_types.PROFILE ++
        "\",\"type\":\"provider.credential.grant.request\",\"id\":\"g1\",\"payload\":{\"provider_id\":\"anthropic\",\"nonce\":\"n-123\"}}";
    try server.handleLine(request);

    try std.testing.expect(try announceOapGrants(allocator, &server, &channels, &ordinal));
    try std.testing.expectEqual(@as(usize, 1), channels.items.len);

    const announced = server.popOutbound() orelse return error.TestExpectedOutbound;
    defer allocator.free(announced);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, announced, .{});
    defer parsed.deinit();
    const channel_path = parsed.value.object.get("payload").?.object.get("channel").?.string;

    try oap_provider_grant_channel.connectAndWrite(channel_path, "n-123\nsk-granted-secret");

    var rounds: usize = 0;
    while (rounds < 200 and granted.items.len == 0) : (rounds += 1) {
        _ = try pumpOapGrants(allocator, &server, &channels, &granted, compat.time.nowMillis());
    }

    try std.testing.expectEqual(@as(usize, 1), granted.items.len);
    try std.testing.expectEqualStrings("sk-granted-secret", granted.items[0].value);
    try std.testing.expectEqual(@as(usize, 0), channels.items.len);

    const reference = granted.items[0].reference;
    try std.testing.expectEqualStrings("sk-granted-secret", grantedValueFor(granted.items, reference) orelse "");
    try std.testing.expect(grantedValueFor(granted.items, "grant:nobody:0") == null);

    const create = try std.fmt.allocPrint(
        allocator,
        "{{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"{s}\",\"type\":\"inference.create.request\",\"id\":\"q1\",\"payload\":{{\"model_ref\":\"anthropic/anthropic-messages@claude-sonnet-4-5\",\"messages\":[{{\"role\":\"user\",\"content\":\"hi\"}}],\"credential_ref\":\"{s}\"}}}}",
        .{ oap_provider_types.PROFILE, reference },
    );
    defer allocator.free(create);
    try server.handleLine(create);

    const response = server.popOutbound() orelse return error.TestExpectedOutbound;
    defer allocator.free(response);
    var decoded = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer decoded.deinit();
    try std.testing.expect(decoded.value.object.get("payload").?.object.get("accepted").?.bool);

    const inference_id = server.active.items[0].id;
    try std.testing.expectEqualStrings(reference, server.active.items[0].credential_ref.?);
    _ = inference_id;
}

test "a descriptor claims the carry round trip only where the provider declares reasoning" {
    const allocator = std.testing.allocator;

    var server = oap_provider_server.Server.init(allocator, .{
        .capability_revision = VERSION,
        .grant_channel = .unsupported,
        .accepts_inference = true,
        .resolves_own_credentials = true,
    });
    defer server.deinit();

    try populateOapProviderCatalog(allocator, &server);
    try std.testing.expect(server.providers.items.len > 0);

    var claimed: usize = 0;
    for (server.providers.items) |descriptor| {
        if (!descriptor.round_trips_carry) continue;
        claimed += 1;
        var declares_reasoning = false;
        for (oap_provider_catalog.BUILT_IN_PROVIDERS) |builtin| {
            if (!std.mem.eql(u8, builtin.id, descriptor.id)) continue;
            declares_reasoning = builtin.supports_reasoning;
        }
        if (!declares_reasoning) {
            std.debug.print(
                "\n{s} claims a carry round trip without declaring reasoning\n",
                .{descriptor.id},
            );
            return error.CarryRoundTripOverClaimed;
        }
    }
    try std.testing.expect(claimed > 0);
}

test "the signature lookup finds a carry only on the block that carries one" {
    const content = [_]ai_types.AssistantContent{
        .{ .text = .{ .text = "answer" } },
        .{ .thinking = .{ .thinking = "weighing", .thinking_signature = "sig-abc" } },
    };
    const partial = ai_types.AssistantMessage{
        .content = &content,
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "m",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try std.testing.expect(oap_provider_runtime.thinkingSignature(partial, 0) == null);
    const signature = oap_provider_runtime.thinkingSignature(partial, 1) orelse return error.TestExpectedSignature;
    try std.testing.expectEqualStrings("sig-abc", signature);
    try std.testing.expect(oap_provider_runtime.thinkingSignature(partial, 7) == null);
}

fn buildContextUnderFailure(allocator: std.mem.Allocator, source: []const oap_types.Message) !void {
    var context = try buildOapInferenceContext(allocator, source, .{
        .provider = "anthropic",
        .api = "anthropic-messages",
        .model_id = "claude-sonnet-4-5",
    });
    context.deinit(allocator);
}

test "building an inference context leaks nothing and frees nothing twice under allocation failure" {
    var parts = [_]oap_types.ContentPart{
        .{ .reasoning = .{ .text = "prior thinking", .carry = "SIG-MARKER" } },
        .{ .text = "spoken" },
        .{ .tool_call = .{
            .tool_call_id = "c1",
            .name = "search",
            .arguments_json = "{}",
            .carry = "TOOL-SIG",
        } },
    };
    const source = [_]oap_types.Message{
        .{ .role = .system, .content = .{ .text = "be brief" } },
        .{ .role = .user, .content = .{ .text = "first question" } },
        .{ .role = .assistant, .content = .{ .parts = parts[0..] } },
        .{ .role = .user, .content = .{ .text = "second question" } },
    };

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        buildContextUnderFailure,
        .{source[0..]},
    );
}

test "a replayed carry survives the transform that feeds the provider" {
    const allocator = std.testing.allocator;

    var parts = [_]oap_types.ContentPart{
        .{ .reasoning = .{ .text = "prior thinking", .carry = "SIG-MARKER" } },
        .{ .text = "prior answer" },
    };
    const source = [_]oap_types.Message{
        .{ .role = .assistant, .content = .{ .parts = parts[0..] } },
    };

    var context = try buildOapInferenceContext(allocator, source[0..], .{
        .provider = "anthropic",
        .api = "anthropic-messages",
        .model_id = "claude-sonnet-4-5",
    });
    defer context.deinit(allocator);

    var transformed = try pre_transform.preTransform(allocator, context.messages, .{
        .target_api = "anthropic-messages",
        .target_provider = "anthropic",
        .target_model_id = "claude-sonnet-4-5",
        .max_tool_id_len = 64,
        .insert_synthetic_results = true,
        .tools = null,
        .is_oauth = false,
    });
    defer transformed.deinit();

    const content = transformed.messages[0].assistant.content;
    try std.testing.expect(content[0] == .thinking);
    try std.testing.expectEqualStrings("SIG-MARKER", content[0].thinking.thinking_signature orelse "");
}

test "the inbound half puts a replayed carry back on the block it belongs to" {
    const allocator = std.testing.allocator;

    var parts = [_]oap_types.ContentPart{
        .{ .reasoning = .{ .text = "first", .carry = "sig-one" } },
        .{ .text = "spoken" },
        .{ .reasoning = .{ .text = "second", .carry = "sig-two" } },
    };
    const messages = [_]oap_types.Message{
        .{ .role = .assistant, .content = .{ .parts = parts[0..] } },
    };

    var context = try buildOapInferenceContext(allocator, messages[0..], .{
        .provider = "anthropic",
        .api = "anthropic-messages",
        .model_id = "m",
    });
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), context.messages.len);
    const content = context.messages[0].assistant.content;
    try std.testing.expectEqual(@as(usize, 3), content.len);

    try std.testing.expectEqualStrings("sig-one", content[0].thinking.thinking_signature orelse "");
    try std.testing.expectEqualStrings("first", content[0].thinking.thinking);
    try std.testing.expect(content[1] == .text);
    try std.testing.expectEqualStrings("sig-two", content[2].thinking.thinking_signature orelse "");
    try std.testing.expectEqualStrings("second", content[2].thinking.thinking);
}

test "reasoning options reach the stream options and the model declares reasoning" {
    const allocator = std.testing.allocator;

    var options: ai_types.StreamOptions = .{};
    applyOapReasoning(&options, .{ .enabled = true, .budget_tokens = 2048, .effort = null });
    try std.testing.expect(options.thinking_enabled);
    try std.testing.expectEqual(@as(?u32, 2048), options.thinking_budget_tokens);

    const builtin = builtInForProvider("anthropic").?;
    try std.testing.expect(builtin.supports_reasoning);

    var model = try buildOapInferenceModel(allocator, builtin, "claude-sonnet-4-5");
    defer model.deinit(allocator);
    try std.testing.expect(model.reasoning);
}

test "describe names a draft revision that identifies a state rather than a stream" {
    const allocator = std.testing.allocator;

    const streams = [_][]const u8{ "main", "master", "HEAD", "head", "latest", "trunk", "drafts/main" };
    for (streams) |stream| {
        if (std.ascii.eqlIgnoreCase(OAP_PROVIDER_PROFILE_REVISION, stream)) {
            std.debug.print(
                "\nprofile_revision is \"{s}\", which names a stream and not a state\n",
                .{OAP_PROVIDER_PROFILE_REVISION},
            );
            return error.ProfileRevisionNamesAStream;
        }
    }
    try std.testing.expect(OAP_PROVIDER_PROFILE_REVISION.len > 0);

    var server = oap_provider_server.Server.init(allocator, .{
        .capability_revision = VERSION,
        .grant_channel = .unsupported,
        .accepts_inference = true,
        .resolves_own_credentials = true,
        .profile_revision = OAP_PROVIDER_PROFILE_REVISION,
    });
    defer server.deinit();

    const line =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ oap_provider_types.PROFILE ++
        "\",\"type\":\"provider.describe.request\",\"id\":\"q1\",\"payload\":{}}";
    try server.handleLine(line);

    const outbound = server.popOutbound() orelse return error.TestExpectedOutbound;
    defer allocator.free(outbound);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, outbound, .{});
    defer parsed.deinit();

    const published = parsed.value.object.get("payload").?.object.get("profile_revision").?.string;
    try std.testing.expectEqualStrings(OAP_PROVIDER_PROFILE_REVISION, published);
}

fn populateCatalogUnderFailure(allocator: std.mem.Allocator) !void {
    var server = oap_provider_server.Server.init(allocator, .{
        .capability_revision = VERSION,
        .grant_channel = .unsupported,
        .accepts_inference = true,
        .resolves_own_credentials = true,
    });
    defer server.deinit();
    try populateOapProviderCatalog(allocator, &server);
}

test "populating the oap catalogue leaks nothing when an allocation fails" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        populateCatalogUnderFailure,
        .{},
    );
}

test "every capability the oap endpoint implements is advertised and honoured" {
    const allocator = std.testing.allocator;

    inline for (@typeInfo(oap_provider_types.SnapshotPolicy).@"enum".fields) |field| {
        const policy = @field(oap_provider_types.SnapshotPolicy, field.name);
        var implemented = false;
        for (oap_provider_server.IMPLEMENTED_SNAPSHOT_POLICIES) |candidate| {
            if (candidate == policy) implemented = true;
        }
        try std.testing.expect(implemented);
    }

    var server = oap_provider_server.Server.init(allocator, .{
        .capability_revision = VERSION,
        .grant_channel = .unsupported,
        .accepts_inference = true,
        .resolves_own_credentials = true,
    });
    defer server.deinit();

    try populateOapProviderCatalog(allocator, &server);
    try std.testing.expect(server.providers.items.len > 0);

    for (server.providers.items) |descriptor| {
        try std.testing.expectEqual(oap_provider_server.IMPLEMENTS_SYNC, descriptor.answers_sync);
        try std.testing.expectEqual(
            oap_provider_server.IMPLEMENTED_SNAPSHOT_POLICIES.len,
            descriptor.snapshot_policies.len,
        );
    }

    var counter: usize = 0;
    for (server.models.items) |entry| {
        for (oap_provider_server.IMPLEMENTED_SNAPSHOT_POLICIES) |policy| {
            counter += 1;
            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"model_ref\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"hi\"}}],\"include_snapshot\":\"{s}\"}}",
                .{ entry.model_ref, @tagName(policy) },
            );
            defer allocator.free(payload);

            const line = try std.fmt.allocPrint(
                allocator,
                "{{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"{s}\",\"type\":\"inference.create.request\",\"id\":\"s{d}\",\"payload\":{s}}}",
                .{ oap_provider_types.PROFILE, counter, payload },
            );
            defer allocator.free(line);
            try server.handleLine(line);

            const outbound = server.popOutbound() orelse return error.TestExpectedOutbound;
            defer allocator.free(outbound);

            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, outbound, .{});
            defer parsed.deinit();

            const response_payload = parsed.value.object.get("payload").?.object;
            if (!response_payload.get("accepted").?.bool) {
                const message = response_payload.get("error").?.object.get("message").?.string;
                std.debug.print(
                    "\n{s} refused include_snapshot={s}: {s}\n",
                    .{ entry.model_ref, @tagName(policy), message },
                );
                return error.AdvertisedPolicyRefused;
            }

            const honoured = response_payload.get("honoured").?.object.get("include_snapshot").?.string;
            if (!std.mem.eql(u8, honoured, @tagName(policy))) {
                std.debug.print(
                    "\n{s} downgraded include_snapshot={s} to {s}\n",
                    .{ entry.model_ref, @tagName(policy), honoured },
                );
                return error.AdvertisedPolicyDowngraded;
            }
        }
    }
}

test "the oap descriptors state compatibility facts only where makai asserts them" {
    const silent = oapProviderCompatibility("openai", .{});
    try std.testing.expect(silent.isEmpty());

    const asserted = oapProviderCompatibility("openai", .{ .openai_proxy = true });
    try std.testing.expect(!asserted.isEmpty());
    try std.testing.expectEqual(@as(?bool, true), asserted.supports_store);
    try std.testing.expectEqual(@as(?bool, true), asserted.supports_developer_role);
    try std.testing.expectEqual(@as(?bool, true), asserted.supports_reasoning_effort);
    try std.testing.expect(asserted.max_tokens_field.? == .max_completion_tokens);

    const anthropic = oapProviderCompatibility("anthropic", .{ .anthropic_proxy = true });
    try std.testing.expectEqual(@as(?bool, true), anthropic.cache_ttl_control);

    const unasserted_anthropic = oapProviderCompatibility("anthropic", .{ .openai_proxy = true });
    try std.testing.expect(unasserted_anthropic.isEmpty());
}
