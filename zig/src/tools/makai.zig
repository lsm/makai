const std = @import("std");
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
const event_stream = @import("event_stream");
const in_process = @import("transports/in_process");
const stdio = @import("stdio");

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

const RuntimeErrorCode = enum {
    dispatch_error,
    unknown_envelope,
    runtime_error,
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
                var sender = self.agent_pipe.clientSender();
                try sender.write(line);
                try sender.flush();
                var runtime = AgentProtocolRuntime{
                    .server = &self.agent_server,
                    .pipe = &self.agent_pipe,
                    .allocator = self.allocator,
                };
                try runtime.pumpClientMessages();
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

    pub fn hasActiveAuthFlows(self: *Self) bool {
        return self.auth_server.activeFlowCount() > 0;
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

fn clearOwnedLines(allocator: std.mem.Allocator, lines: *std.ArrayList([]const u8)) void {
    for (lines.items) |line| allocator.free(line);
    lines.clearRetainingCapacity();
}

fn writeOwnedLinesAndClear(
    file: std.fs.File,
    allocator: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
) !void {
    defer clearOwnedLines(allocator, lines);

    for (lines.items) |line| {
        try file.writeAll(line);
        try file.writeAll("\n");
    }
}

fn emitRuntimeError(
    file: std.fs.File,
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
    try file.writeAll(payload);
    try file.writeAll("\n");
}

fn runStdioMode(allocator: std.mem.Allocator, stdin: std.fs.File, stdout: std.fs.File) !void {
    var stdio_loop = try StdioProtocolLoop.initWithBuiltins(allocator);
    defer stdio_loop.deinit();

    try stdout.writeAll(READY_FRAME);

    var async_receiver = stdio.AsyncStdioReceiver.initWithFile(stdin);
    var stdin_handle = try async_receiver.receiveStreamWithHandle(allocator);
    defer _ = stdin_handle.deinit(STDIO_THREAD_JOIN_TIMEOUT_MS);

    const stdin_stream = stdin_handle.getStream();
    var outbound_lines = std.ArrayList([]const u8){};
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

        if (stdin_stream.isDone() and !did_work and !stdio_loop.hasActiveProviderStreams() and !stdio_loop.hasActiveAuthFlows()) {
            break;
        }

        if (!did_work) {
            std.Thread.sleep(STDIO_IDLE_SLEEP_NS);
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

fn printUsage(file: std.fs.File) !void {
    try file.writeAll(
        \\Usage:
        \\  makai --version
        \\  makai --stdio
        \\  makai auth providers [--json]
        \\  makai auth login --provider <id> [--json]
        \\
        \\Commands:
        \\  --version        Print binary version
        \\  --stdio          Start stdio mode
        \\  auth providers   List oauth-capable providers
        \\  auth login       Run OAuth flow and persist credentials
        \\
    );
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
    stdin: std.fs.File,
    stdout: std.fs.File,
    stderr: std.fs.File,
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
    stdin: std.fs.File,
    stdout: std.fs.File,
    stderr: std.fs.File,
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
        .timestamp = std.time.milliTimestamp(),
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

fn makeProviderPingEnvelopeJson(allocator: std.mem.Allocator) ![]u8 {
    const env = ProviderProtocolTypes.Envelope{
        .stream_id = ProviderProtocolTypes.generateUuid(),
        .message_id = ProviderProtocolTypes.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .ping,
    };
    return provider_protocol_envelope.serializeEnvelope(env, allocator);
}

fn makeAgentPingEnvelopeJson(allocator: std.mem.Allocator) ![]u8 {
    const env = AgentProtocolTypes.Envelope{
        .session_id = AgentProtocolTypes.generateSessionId(),
        .message_id = AgentProtocolTypes.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .ping,
    };
    return agent_protocol_envelope.serializeEnvelope(env, allocator);
}

fn makeAuthProvidersRequestEnvelopeJson(allocator: std.mem.Allocator, flow_id: AuthProtocolTypes.Uuid, sequence: u64) ![]u8 {
    const env = AuthProtocolTypes.Envelope{
        .stream_id = flow_id,
        .message_id = AuthProtocolTypes.generateUuid(),
        .sequence = sequence,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .auth_providers_request = .{} },
    };
    return auth_protocol_envelope.serializeEnvelope(env, allocator);
}

fn makeAuthLoginStartEnvelopeJson(
    allocator: std.mem.Allocator,
    flow_id: AuthProtocolTypes.Uuid,
    sequence: u64,
    provider_id: []const u8,
) ![]u8 {
    var env = AuthProtocolTypes.Envelope{
        .stream_id = flow_id,
        .message_id = AuthProtocolTypes.generateUuid(),
        .sequence = sequence,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .auth_login_start = .{
            .provider_id = AuthProtocolTypes.OwnedSlice(u8).initOwned(try allocator.dupe(u8, provider_id)),
        } },
    };
    defer env.deinit(allocator);
    return auth_protocol_envelope.serializeEnvelope(env, allocator);
}

fn makeAuthPromptResponseEnvelopeJson(
    allocator: std.mem.Allocator,
    flow_id: AuthProtocolTypes.Uuid,
    sequence: u64,
    prompt_id: []const u8,
    answer: []const u8,
) ![]u8 {
    var env = AuthProtocolTypes.Envelope{
        .stream_id = flow_id,
        .message_id = AuthProtocolTypes.generateUuid(),
        .sequence = sequence,
        .timestamp = std.time.milliTimestamp(),
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
    flow_id: AuthProtocolTypes.Uuid,
    sequence: u64,
) ![]u8 {
    const env = AuthProtocolTypes.Envelope{
        .stream_id = flow_id,
        .message_id = AuthProtocolTypes.generateUuid(),
        .sequence = sequence,
        .timestamp = std.time.milliTimestamp(),
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
        .stream_id = ProviderProtocolTypes.generateUuid(),
        .message_id = ProviderProtocolTypes.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = fixtureModel(api),
            .context = .{ .messages = &.{} },
            // Provide an explicit api_key so the binary's credential resolver
            // (M-006) does not reject the request with `auth_required`. The
            // fixture providers do not validate the key value.
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-fixture-key") },
        } },
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

    var outbound = std.ArrayList([]const u8){};
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

    var outbound = std.ArrayList([]const u8){};
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    const flow_id = AuthProtocolTypes.generateUuid();
    const request = try makeAuthProvidersRequestEnvelopeJson(allocator, flow_id, 1);
    defer allocator.free(request);

    try std.testing.expect(try stdio_loop.dispatchInboundLine(request));

    for (0..TEST_AUTH_POLL_ITERS_SHORT) |_| {
        try pumpAndDrainStdioLoop(&stdio_loop, &outbound);
        if (outbound.items.len >= 2) break;
        std.Thread.sleep(STDIO_IDLE_SLEEP_NS);
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

    var outbound = std.ArrayList([]const u8){};
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    const flow_id = AuthProtocolTypes.generateUuid();
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
            std.Thread.sleep(STDIO_IDLE_SLEEP_NS);
            continue;
        }

        for (outbound.items) |line| {
            if (std.mem.indexOf(u8, line, "fixture-refresh-token") != null or
                std.mem.indexOf(u8, line, "fixture-access-token") != null)
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
        std.Thread.sleep(STDIO_IDLE_SLEEP_NS);
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

    var outbound = std.ArrayList([]const u8){};
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    const flow_id = AuthProtocolTypes.generateUuid();
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
            std.Thread.sleep(STDIO_IDLE_SLEEP_NS);
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
        std.Thread.sleep(STDIO_IDLE_SLEEP_NS);
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
        std.Thread.sleep(STDIO_IDLE_SLEEP_NS);
    }

    try std.testing.expectEqual(@as(usize, 0), late_terminal_messages);
}

test "stdio auth login failure emits auth_event.error before auth_login_result" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    var stdio_loop = StdioProtocolLoop.initForTesting(allocator, &registry);
    defer stdio_loop.deinit();

    var outbound = std.ArrayList([]const u8){};
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }

    const flow_id = AuthProtocolTypes.generateUuid();
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
        std.Thread.sleep(STDIO_IDLE_SLEEP_NS);
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
        \\{"type":"ping","stream_id":"11111111-1111-1111-1111-111111111111","session_id":"22222222-2222-2222-2222-222222222222","message_id":"33333333-3333-3333-3333-333333333333","sequence":1,"timestamp":1760000000000,"version":1,"payload":{}}
    ;

    try std.testing.expect(!(try stdio_loop.dispatchInboundLine(ambiguous)));

    var outbound = std.ArrayList([]const u8){};
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

    var outbound = std.ArrayList([]const u8){};
    defer {
        clearOwnedLines(allocator, &outbound);
        outbound.deinit(allocator);
    }
    _ = try stdio_loop.drainOutbound(&outbound);
    try std.testing.expectEqual(@as(usize, 0), outbound.items.len);
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

    var outbound = std.ArrayList([]const u8){};
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

test "writeOwnedLinesAndClear clears owned lines on write failure" {
    const allocator = std.testing.allocator;
    const pipe = try std.posix.pipe();
    const read_file = std.fs.File{ .handle = pipe[0] };
    const write_file = std.fs.File{ .handle = pipe[1] };
    defer read_file.close();

    // Force write error path.
    write_file.close();

    var lines = std.ArrayList([]const u8){};
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

    const stdin_pipe = try std.posix.pipe();
    const stdout_pipe = try std.posix.pipe();

    var stdin_read = std.fs.File{ .handle = stdin_pipe[0] };
    var stdin_write = std.fs.File{ .handle = stdin_pipe[1] };
    var stdout_read = std.fs.File{ .handle = stdout_pipe[0] };
    var stdout_write = std.fs.File{ .handle = stdout_pipe[1] };
    errdefer {
        stdin_read.close();
        stdin_write.close();
        stdout_read.close();
        stdout_write.close();
    }

    const Runner = struct {
        allocator: std.mem.Allocator,
        stdin_file: std.fs.File,
        stdout_file: std.fs.File,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            runStdioMode(self.allocator, self.stdin_file, self.stdout_file) catch |err| {
                self.err = err;
            };
            self.stdin_file.close();
            self.stdout_file.close();
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
    defer if (!stdin_write_closed) stdin_write.close();

    var out_receiver = stdio.StdioReceiver.initWithFile(stdout_read, allocator);
    defer out_receiver.deinit();
    defer stdout_read.close();

    var receiver = out_receiver.receiver();

    const ready_line = (try receiver.read(allocator)).?;
    defer allocator.free(ready_line);
    try std.testing.expectEqualStrings("{\"type\":\"ready\",\"protocol_version\":\"1\"}", ready_line);

    const ping = try makeProviderPingEnvelopeJson(allocator);
    defer allocator.free(ping);
    try stdin_write.writeAll(ping);
    try stdin_write.writeAll("\n");

    const response_line = (try receiver.read(allocator)).?;
    defer allocator.free(response_line);
    var pong = try provider_protocol_envelope.deserializeEnvelope(response_line, allocator);
    defer pong.deinit(allocator);
    try std.testing.expect(pong.payload == .pong);

    stdin_write.close();
    stdin_write_closed = true;
    try std.testing.expect(runner.err == null);
}

test "stdio mode emits unknown_envelope error and continues processing" {
    const allocator = std.testing.allocator;

    const stdin_pipe = try std.posix.pipe();
    const stdout_pipe = try std.posix.pipe();

    var stdin_read = std.fs.File{ .handle = stdin_pipe[0] };
    var stdin_write = std.fs.File{ .handle = stdin_pipe[1] };
    var stdout_read = std.fs.File{ .handle = stdout_pipe[0] };
    var stdout_write = std.fs.File{ .handle = stdout_pipe[1] };
    errdefer {
        stdin_read.close();
        stdin_write.close();
        stdout_read.close();
        stdout_write.close();
    }

    const Runner = struct {
        allocator: std.mem.Allocator,
        stdin_file: std.fs.File,
        stdout_file: std.fs.File,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            runStdioMode(self.allocator, self.stdin_file, self.stdout_file) catch |err| {
                self.err = err;
            };
            self.stdin_file.close();
            self.stdout_file.close();
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
    defer if (!stdin_write_closed) stdin_write.close();

    var out_receiver = stdio.StdioReceiver.initWithFile(stdout_read, allocator);
    defer out_receiver.deinit();
    defer stdout_read.close();

    var receiver = out_receiver.receiver();

    const ready_line = (try receiver.read(allocator)).?;
    defer allocator.free(ready_line);
    try std.testing.expectEqualStrings("{\"type\":\"ready\",\"protocol_version\":\"1\"}", ready_line);

    try stdin_write.writeAll("{\"type\":\"unknown\",\"payload\":{}}\n");

    const ping = try makeProviderPingEnvelopeJson(allocator);
    defer allocator.free(ping);
    try stdin_write.writeAll(ping);
    try stdin_write.writeAll("\n");

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

    stdin_write.close();
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

    stdin_read: std.fs.File,
    stdin_write: std.fs.File,
    stdout_read: std.fs.File,
    stdout_write: std.fs.File,
    stderr_read: std.fs.File,
    stderr_write: std.fs.File,

    err: ?anyerror = null,

    fn init(allocator: std.mem.Allocator, args: []const []const u8) !AuthCliHarness {
        const stdin_pipe = try std.posix.pipe();
        const stdout_pipe = try std.posix.pipe();
        const stderr_pipe = try std.posix.pipe();

        return .{
            .allocator = allocator,
            .args = args,
            .stdin_read = std.fs.File{ .handle = stdin_pipe[0] },
            .stdin_write = std.fs.File{ .handle = stdin_pipe[1] },
            .stdout_read = std.fs.File{ .handle = stdout_pipe[0] },
            .stdout_write = std.fs.File{ .handle = stdout_pipe[1] },
            .stderr_read = std.fs.File{ .handle = stderr_pipe[0] },
            .stderr_write = std.fs.File{ .handle = stderr_pipe[1] },
        };
    }

    fn run(self: *AuthCliHarness) void {
        defer {
            // The wrapper does not own these fds; closing them here lets the
            // reader side observe EOF after the command finishes.
            self.stdout_write.close();
            self.stderr_write.close();
            self.stdin_read.close();
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

    fn readAll(file: std.fs.File, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(allocator);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = file.read(&chunk) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
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
    harness.stdin_write.close();

    const stdout_bytes = try AuthCliHarness.readAll(harness.stdout_read, allocator);
    defer allocator.free(stdout_bytes);
    const stderr_bytes = try AuthCliHarness.readAll(harness.stderr_read, allocator);
    defer allocator.free(stderr_bytes);

    thread.join();
    harness.stdout_read.close();
    harness.stderr_read.close();

    try std.testing.expect(harness.err == null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_bytes, "anthropic\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_bytes, "github-copilot\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_bytes, "test-fixture\n") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr_bytes.len);
}

test "handleAuth providers --json end-to-end emits backward-compatible shape" {
    const allocator = std.testing.allocator;

    var harness = try AuthCliHarness.init(allocator, &.{ "providers", "--json" });
    const thread = try std.Thread.spawn(.{}, AuthCliHarness.run, .{&harness});

    harness.stdin_write.close();

    const stdout_bytes = try AuthCliHarness.readAll(harness.stdout_read, allocator);
    defer allocator.free(stdout_bytes);
    const stderr_bytes = try AuthCliHarness.readAll(harness.stderr_read, allocator);
    defer allocator.free(stderr_bytes);

    thread.join();
    harness.stdout_read.close();
    harness.stderr_read.close();

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
    try harness.stdin_write.writeAll("not-the-answer\nok\n");
    harness.stdin_write.close();

    const stdout_bytes = try AuthCliHarness.readAll(harness.stdout_read, allocator);
    defer allocator.free(stdout_bytes);
    const stderr_bytes = try AuthCliHarness.readAll(harness.stderr_read, allocator);
    defer allocator.free(stderr_bytes);

    thread.join();
    harness.stdout_read.close();
    harness.stderr_read.close();

    try std.testing.expect(harness.err == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        stdout_bytes,
        "https://example.invalid/makai-test-fixture-login",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_bytes, "Login successful.") != null);

    // Tokens must never appear in CLI-visible streams.
    try std.testing.expect(std.mem.indexOf(u8, stdout_bytes, "fixture-refresh-token") == null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_bytes, "fixture-access-token") == null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_bytes, "fixture-refresh-token") == null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_bytes, "fixture-access-token") == null);
}

test "handleAuth login surfaces typed error for unknown provider via CLI wrapper" {
    const allocator = std.testing.allocator;

    var harness = try AuthCliHarness.init(allocator, &.{ "login", "--provider", "no-such-provider" });
    const thread = try std.Thread.spawn(.{}, AuthCliHarness.run, .{&harness});

    harness.stdin_write.close();

    const stdout_bytes = try AuthCliHarness.readAll(harness.stdout_read, allocator);
    defer allocator.free(stdout_bytes);
    const stderr_bytes = try AuthCliHarness.readAll(harness.stderr_read, allocator);
    defer allocator.free(stderr_bytes);

    thread.join();
    harness.stdout_read.close();
    harness.stderr_read.close();

    try std.testing.expectEqual(auth_cli.AuthCliError.AuthLoginFailed, harness.err.?);
    try std.testing.expect(std.mem.indexOf(u8, stderr_bytes, "auth login failed") != null);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();
    const stdin = std.fs.File.stdin();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len <= 1) {
        try printUsage(stdout);
        return;
    }

    if (std.mem.eql(u8, args[1], "--version")) {
        try stdout.writeAll(VERSION ++ "\n");
        return;
    }

    if (std.mem.eql(u8, args[1], "--stdio")) {
        try runStdioMode(allocator, stdin, stdout);
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
    try stderr.writeAll(msg);
    try printUsage(stderr);
    return error.InvalidArgument;
}
