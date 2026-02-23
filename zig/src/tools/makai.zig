const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const anthropic_oauth = @import("oauth/anthropic");
const github_oauth = @import("oauth/github_copilot");
const oauth_storage = @import("oauth/storage");
const register_builtins = @import("register_builtins");
const provider_protocol_server = @import("protocol_server");
const provider_protocol_runtime = @import("protocol_runtime");
const provider_protocol_envelope = @import("protocol_envelope");
const agent_protocol_server = @import("agent_server");
const agent_protocol_runtime = @import("agent_runtime");
const agent_protocol_envelope = @import("agent_envelope");
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
const READY_FRAME = "{\"type\":\"ready\",\"protocol_version\":\"1\"}\n";
const STDIO_PROTOCOL_VERSION = "1";
const STDIO_IDLE_SLEEP_NS = std.time.ns_per_ms;
const STDIO_THREAD_JOIN_TIMEOUT_MS: u64 = 5_000;

const RuntimeErrorCode = enum {
    dispatch_error,
    unknown_envelope,
    runtime_error,
};

const AuthContext = struct {
    allocator: std.mem.Allocator,
    stdin: std.fs.File,
    stdout: std.fs.File,
    provider_id: []const u8,
    json_mode: bool,

    fn emitJson(self: *const AuthContext, value: anytype) !void {
        const payload = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(payload);
        try self.stdout.writeAll(payload);
        try self.stdout.writeAll("\n");
    }

    fn emitProgress(self: *const AuthContext, message: []const u8) !void {
        if (self.json_mode) {
            try self.emitJson(.{
                .type = "progress",
                .provider = self.provider_id,
                .message = message,
            });
            return;
        }
        try self.stdout.writeAll(message);
        try self.stdout.writeAll("\n");
    }

    fn emitAuthInfo(self: *const AuthContext, url: []const u8, instructions: ?[]const u8) !void {
        if (self.json_mode) {
            try self.emitJson(.{
                .type = "auth_url",
                .provider = self.provider_id,
                .url = url,
                .instructions = instructions,
            });
            return;
        }
        try self.stdout.writeAll(url);
        try self.stdout.writeAll("\n");
        if (instructions) |msg| {
            try self.stdout.writeAll(msg);
            try self.stdout.writeAll("\n");
        }
    }

    fn emitPrompt(self: *const AuthContext, message: []const u8, allow_empty: bool) !void {
        if (self.json_mode) {
            try self.emitJson(.{
                .type = "prompt",
                .provider = self.provider_id,
                .message = message,
                .allow_empty = allow_empty,
            });
            return;
        }
        try self.stdout.writeAll(message);
        try self.stdout.writeAll(" ");
    }
};

var g_auth_ctx: ?*AuthContext = null;
var g_stdin_buf: [4096]u8 = undefined;

fn readInput(allocator: std.mem.Allocator, stdin: std.fs.File) ![]const u8 {
    var reader = stdin.reader(&g_stdin_buf);
    const line = (try reader.interface.takeDelimiter('\n')) orelse "";
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

fn readPromptInput(message: []const u8, allow_empty: bool) []const u8 {
    const ctx = g_auth_ctx orelse unreachable;
    const empty = struct {
        fn make(allocator: std.mem.Allocator) []const u8 {
            return allocator.alloc(u8, 0) catch @panic("OOM");
        }
    }.make;
    while (true) {
        ctx.emitPrompt(message, allow_empty) catch return empty(ctx.allocator);
        const value = readInput(ctx.allocator, ctx.stdin) catch return empty(ctx.allocator);
        if (allow_empty or value.len > 0) {
            return value;
        }
        ctx.allocator.free(value);
        ctx.emitProgress("Input cannot be empty.") catch {};
    }
}

fn anthropicOnAuth(info: anthropic_oauth.AuthInfo) void {
    if (g_auth_ctx) |ctx| {
        ctx.emitAuthInfo(info.url, info.instructions) catch {};
    }
}

fn anthropicOnPrompt(prompt: anthropic_oauth.Prompt) []const u8 {
    return readPromptInput(prompt.message, prompt.allow_empty);
}

fn githubOnAuth(info: github_oauth.AuthInfo) void {
    if (g_auth_ctx) |ctx| {
        ctx.emitAuthInfo(info.url, info.instructions) catch {};
    }
}

fn githubOnPrompt(prompt: github_oauth.Prompt) []const u8 {
    return readPromptInput(prompt.message, prompt.allow_empty);
}

const StdioProtocolLoop = struct {
    allocator: std.mem.Allocator,
    registry: *api_registry.ApiRegistry,
    owns_registry: bool,
    provider_server: ProviderProtocolServer,
    provider_pipe: in_process.SerializedPipe,
    agent_server: AgentProtocolServer,
    agent_pipe: in_process.SerializedPipe,

    const Self = @This();
    const DispatchTarget = enum { provider, agent };

    fn initWithRegistry(
        allocator: std.mem.Allocator,
        registry: *api_registry.ApiRegistry,
        owns_registry: bool,
    ) Self {
        const self = Self{
            .allocator = allocator,
            .registry = registry,
            .owns_registry = owns_registry,
            .provider_server = ProviderProtocolServer.init(allocator, registry, .{}),
            .provider_pipe = in_process.createSerializedPipe(allocator),
            .agent_server = AgentProtocolServer.init(allocator),
            .agent_pipe = in_process.createSerializedPipe(allocator),
        };

        return self;
    }

    pub fn initWithBuiltins(allocator: std.mem.Allocator) !Self {
        const registry = try allocator.create(api_registry.ApiRegistry);
        errdefer allocator.destroy(registry);

        registry.* = api_registry.ApiRegistry.init(allocator);
        errdefer registry.deinit();

        try register_builtins.registerBuiltInApiProviders(registry);
        return initWithRegistry(allocator, registry, true);
    }

    fn initForTesting(allocator: std.mem.Allocator, registry: *api_registry.ApiRegistry) Self {
        return initWithRegistry(allocator, registry, false);
    }

    pub fn deinit(self: *Self) void {
        self.provider_server.deinit();
        self.provider_pipe.deinit();
        self.agent_server.deinit();
        self.agent_pipe.deinit();

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
        forwarded += try provider_runtime.pumpProviderEvents();
        self.provider_server.cleanupCompletedStreams();

        var agent_runtime = AgentProtocolRuntime{
            .server = &self.agent_server,
            .pipe = &self.agent_pipe,
            .allocator = self.allocator,
        };
        forwarded += try agent_runtime.pumpServerOutbox();
        return forwarded;
    }

    pub fn drainOutbound(self: *Self, lines: *std.ArrayList([]const u8)) !usize {
        var drained: usize = 0;
        drained += try self.drainPipeOutbound(&self.provider_pipe, lines);
        drained += try self.drainPipeOutbound(&self.agent_pipe, lines);
        return drained;
    }

    pub fn hasActiveProviderStreams(self: *Self) bool {
        return self.provider_server.activeStreamCount() > 0;
    }

    fn detectDispatchTarget(self: *Self, line: []const u8) ?DispatchTarget {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch return null;
        defer parsed.deinit();

        if (parsed.value != .object) return null;
        const obj = parsed.value.object;

        const stream_id = obj.get("stream_id");
        const session_id = obj.get("session_id");
        const has_stream_id = stream_id != null and stream_id.? == .string;
        const has_session_id = session_id != null and session_id.? == .string;

        if (has_stream_id and has_session_id) return null;
        if (has_stream_id) return .provider;
        if (has_session_id) return .agent;
        return null;
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

        if (stdin_stream.isDone() and !did_work and !stdio_loop.hasActiveProviderStreams()) {
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

fn listAuthProviders(file: std.fs.File, allocator: std.mem.Allocator, json_mode: bool) !void {
    if (json_mode) {
        const providers = .{
            .type = "providers",
            .providers = [_]struct { id: []const u8, name: []const u8 }{
                .{ .id = "anthropic", .name = "Anthropic" },
                .{ .id = "github-copilot", .name = "GitHub Copilot" },
                .{ .id = "test-fixture", .name = "Test Fixture (CI)" },
            },
        };
        const payload = try std.json.Stringify.valueAlloc(allocator, providers, .{});
        defer allocator.free(payload);
        try file.writeAll(payload);
        try file.writeAll("\n");
        return;
    }

    try file.writeAll("anthropic\n");
    try file.writeAll("github-copilot\n");
    try file.writeAll("test-fixture\n");
}

fn runTestFixtureLogin(allocator: std.mem.Allocator) !oauth_storage.Credentials {
    const ctx = g_auth_ctx orelse unreachable;
    try ctx.emitAuthInfo(
        "https://example.invalid/makai-test-fixture-login",
        "Enter code 'ok' to complete fixture login.",
    );
    const code = readPromptInput("Enter fixture code:", false);
    defer allocator.free(code);

    if (!std.mem.eql(u8, code, "ok")) {
        return error.InvalidAuthCode;
    }

    return .{
        .refresh = try allocator.dupe(u8, "fixture-refresh-token"),
        .access = try allocator.dupe(u8, "fixture-access-token"),
        .expires = std.time.milliTimestamp() + (60 * 60 * 1000),
        .provider_data = try allocator.dupe(u8, "{\"provider\":\"test-fixture\"}"),
    };
}

fn loginAnthropic(allocator: std.mem.Allocator) !oauth_storage.Credentials {
    const credentials = try anthropic_oauth.login(.{
        .onAuth = anthropicOnAuth,
        .onPrompt = anthropicOnPrompt,
    }, allocator);
    return .{
        .refresh = credentials.refresh,
        .access = credentials.access,
        .expires = credentials.expires,
    };
}

fn loginGitHubCopilot(allocator: std.mem.Allocator) !oauth_storage.Credentials {
    const credentials = try github_oauth.login(.{
        .onAuth = githubOnAuth,
        .onPrompt = githubOnPrompt,
    }, allocator);

    if (credentials.enabled_models) |models| {
        for (models) |m| allocator.free(m);
        allocator.free(models);
    }
    if (credentials.base_url) |url| allocator.free(url);

    return .{
        .refresh = credentials.refresh,
        .access = credentials.access,
        .expires = credentials.expires,
        .provider_data = credentials.provider_data,
    };
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

fn loginAuthProvider(args: []const []const u8, allocator: std.mem.Allocator, stdin: std.fs.File, stdout: std.fs.File, stderr: std.fs.File) !void {
    var provider_id: ?[]const u8 = null;
    var json_mode = false;

    var i: usize = 0;
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
    var ctx = AuthContext{
        .allocator = allocator,
        .stdin = stdin,
        .stdout = stdout,
        .provider_id = provider,
        .json_mode = json_mode,
    };

    g_auth_ctx = &ctx;
    defer g_auth_ctx = null;

    var credentials = (if (std.mem.eql(u8, provider, "test-fixture"))
        runTestFixtureLogin(allocator)
    else if (std.mem.eql(u8, provider, "anthropic"))
        loginAnthropic(allocator)
    else if (std.mem.eql(u8, provider, "github-copilot"))
        loginGitHubCopilot(allocator)
    else
        error.UnknownProvider) catch |err| {
        if (json_mode) {
            try ctx.emitJson(.{
                .type = "error",
                .provider = provider,
                .code = @errorName(err),
                .message = "auth login failed",
            });
        } else {
            try stderr.writeAll("auth login failed: ");
            try stderr.writeAll(@errorName(err));
            try stderr.writeAll("\n");
        }
        return err;
    };
    var credentials_consumed = false;
    defer if (!credentials_consumed) credentials.deinit(allocator);

    try saveOAuthCredentials(provider, credentials, allocator);
    credentials_consumed = true;

    if (json_mode) {
        try ctx.emitJson(.{
            .type = "success",
            .provider = provider,
        });
    } else {
        try stdout.writeAll("Login successful.\n");
    }
}

fn handleAuth(args: []const []const u8, allocator: std.mem.Allocator, stdin: std.fs.File, stdout: std.fs.File, stderr: std.fs.File) !void {
    if (args.len == 0) {
        return error.InvalidArgument;
    }

    if (std.mem.eql(u8, args[0], "providers")) {
        var json_mode = false;
        if (args.len > 1) {
            if (args.len == 2 and std.mem.eql(u8, args[1], "--json")) {
                json_mode = true;
            } else {
                return error.InvalidArgument;
            }
        }
        try listAuthProviders(stdout, allocator, json_mode);
        return;
    }

    if (std.mem.eql(u8, args[0], "login")) {
        try loginAuthProvider(args[1..], allocator, stdin, stdout, stderr);
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
        .session_id = AgentProtocolTypes.generateUuid(),
        .message_id = AgentProtocolTypes.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .ping,
    };
    return agent_protocol_envelope.serializeEnvelope(env, allocator);
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
        } },
    };
    defer env.deinit(allocator);
    return provider_protocol_envelope.serializeEnvelope(env, allocator);
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
