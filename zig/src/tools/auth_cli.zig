//! `makai auth` CLI as a thin wrapper over the auth protocol runtime.
//!
//! This module re-implements the user-facing `makai auth providers` and
//! `makai auth login` commands as wrappers that drive the in-process auth
//! protocol runtime (M-002) instead of duplicating OAuth orchestration in the
//! CLI layer. Output shape matches the legacy CLI behavior so existing
//! scripts/tooling continue to work.
//!
//! Spec: `docs/v1-sdk-agent-provider-spec.md §9` Phase C; integration plan
//! Phase 5.

const std = @import("std");
const compat = @import("compat");
const auth_server_mod = @import("auth_server");
const auth_runtime_mod = @import("auth_runtime");
const auth_envelope_mod = @import("auth_envelope");
const in_process = @import("transports/in_process");
const OwnedSlice = @import("owned_slice").OwnedSlice;

const auth_types = auth_envelope_mod.protocol_types;
pub const AuthProtocolServer = auth_server_mod.AuthProtocolServer;
const AuthProtocolRuntime = auth_runtime_mod.AuthProtocolRuntime;
const SerializedPipe = in_process.SerializedPipe;

/// Idle pump sleep when the auth protocol runtime has no immediate work.
const IDLE_SLEEP_NS = std.time.ns_per_ms;

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

/// Hard upper bound on iterations spent waiting for terminal envelopes.
/// 60_000 iterations × 1ms ≈ 60s per command. Real OAuth flows finish in well
/// under a minute; the bound exists so a stuck flow still yields control.
const MAX_IDLE_ITERATIONS: usize = 60_000;

pub const AuthCliError = error{
    AuthProvidersFailed,
    AuthLoginFailed,
    AuthLoginCancelled,
    AuthProtocolTimeout,
};

/// IO abstraction so the wrapper can be exercised both with real stdio in
/// production and with in-memory buffers from unit tests.
pub const AuthCliIo = struct {
    pub const VTable = struct {
        read_line: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8,
        write_out: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
        write_err: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
    };

    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn readLine(self: AuthCliIo, allocator: std.mem.Allocator) ![]u8 {
        return self.vtable.read_line(self.ctx, allocator);
    }

    pub fn writeOut(self: AuthCliIo, bytes: []const u8) !void {
        return self.vtable.write_out(self.ctx, bytes);
    }

    pub fn writeErr(self: AuthCliIo, bytes: []const u8) !void {
        return self.vtable.write_err(self.ctx, bytes);
    }
};

pub const ProvidersOptions = struct {
    json_mode: bool = false,
};

pub const LoginOptions = struct {
    provider_id: []const u8,
    json_mode: bool = false,
};

/// Run `makai auth providers` end-to-end through the auth protocol runtime.
pub fn runProvidersCommand(
    allocator: std.mem.Allocator,
    io: AuthCliIo,
    server_options: AuthProtocolServer.Options,
    options: ProvidersOptions,
) !void {
    var server = AuthProtocolServer.init(allocator, server_options);
    defer server.deinit();

    var pipe = in_process.createSerializedPipe(allocator);
    defer pipe.deinit();

    const stream_id = auth_types.generateUlid();

    {
        const env = auth_types.Envelope{
            .stream_id = stream_id,
            .message_id = auth_types.generateUlid(),
            .sequence = 1,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .auth_providers_request = .{} },
        };
        const json = try auth_envelope_mod.serializeEnvelope(env, allocator);
        defer allocator.free(json);

        var sender = pipe.clientSender();
        try sender.write(json);
        try sender.flush();
    }

    var runtime = AuthProtocolRuntime{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };

    var iteration: usize = 0;
    while (iteration < MAX_IDLE_ITERATIONS) : (iteration += 1) {
        try runtime.pumpClientMessages();
        _ = try runtime.pumpServerOutbox();

        var receiver = pipe.clientReceiver();
        var did_work = false;
        while (try receiver.readLine(allocator)) |line| {
            defer allocator.free(line);
            did_work = true;

            var env = auth_envelope_mod.deserializeEnvelope(line, allocator) catch continue;
            defer env.deinit(allocator);

            switch (env.payload) {
                .ack => {},
                .nack => |nack| {
                    try emitProvidersError(allocator, io, options.json_mode, nack);
                    return AuthCliError.AuthProvidersFailed;
                },
                .auth_providers_response => |response| {
                    try emitProviders(allocator, io, options.json_mode, response);
                    return;
                },
                else => {},
            }
        }
        if (!did_work) compat.time.sleepNs(IDLE_SLEEP_NS);
    }

    return AuthCliError.AuthProtocolTimeout;
}

/// Run `makai auth login --provider <id>` end-to-end through the auth protocol
/// runtime. Drives interactive prompts via the supplied IO interface.
pub fn runLoginCommand(
    allocator: std.mem.Allocator,
    io: AuthCliIo,
    server_options: AuthProtocolServer.Options,
    options: LoginOptions,
) !void {
    var server = AuthProtocolServer.init(allocator, server_options);
    defer server.deinit();

    var pipe = in_process.createSerializedPipe(allocator);
    defer pipe.deinit();

    const flow_id = auth_types.generateUlid();
    var next_client_seq: u64 = 1;

    try sendLoginStart(allocator, &pipe, flow_id, options.provider_id, next_client_seq);
    next_client_seq += 1;

    var runtime = AuthProtocolRuntime{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };

    var saw_terminal = false;
    var login_status: auth_types.AuthLoginStatus = .failed;
    var captured_error_code: ?[]u8 = null;
    var captured_error_message: ?[]u8 = null;
    defer if (captured_error_code) |c| allocator.free(c);
    defer if (captured_error_message) |m| allocator.free(m);

    var iteration: usize = 0;
    while (!saw_terminal and iteration < MAX_IDLE_ITERATIONS) : (iteration += 1) {
        try runtime.pumpClientMessages();
        _ = try runtime.pumpServerOutbox();

        var receiver = pipe.clientReceiver();
        var did_work = false;
        while (try receiver.readLine(allocator)) |line| {
            defer allocator.free(line);
            did_work = true;

            var env = auth_envelope_mod.deserializeEnvelope(line, allocator) catch continue;
            defer env.deinit(allocator);

            switch (env.payload) {
                .ack => {},
                .nack => |nack| {
                    if (captured_error_code == null) {
                        captured_error_code = try allocator.dupe(
                            u8,
                            if (nack.error_code) |code| @tagName(code) else "nack",
                        );
                    }
                    if (captured_error_message == null) {
                        captured_error_message = try allocator.dupe(u8, nack.reason.slice());
                    }
                    saw_terminal = true;
                    login_status = .failed;
                },
                .auth_event => |event| try handleAuthEvent(
                    allocator,
                    io,
                    options,
                    event,
                    &pipe,
                    flow_id,
                    &next_client_seq,
                    &captured_error_code,
                    &captured_error_message,
                ),
                .auth_login_result => |result| {
                    saw_terminal = true;
                    login_status = result.status;
                },
                else => {},
            }
        }
        if (!did_work) compat.time.sleepNs(IDLE_SLEEP_NS);
    }

    if (!saw_terminal) return AuthCliError.AuthProtocolTimeout;

    return emitLoginTerminal(
        allocator,
        io,
        options,
        login_status,
        captured_error_code,
        captured_error_message,
    );
}

fn sendLoginStart(
    allocator: std.mem.Allocator,
    pipe: *SerializedPipe,
    flow_id: auth_types.Ulid,
    provider_id: []const u8,
    sequence: u64,
) !void {
    var env = auth_types.Envelope{
        .stream_id = flow_id,
        .message_id = auth_types.generateUlid(),
        .sequence = sequence,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .auth_login_start = .{
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, provider_id)),
        } },
    };
    defer env.deinit(allocator);

    const json = try auth_envelope_mod.serializeEnvelope(env, allocator);
    defer allocator.free(json);

    var sender = pipe.clientSender();
    try sender.write(json);
    try sender.flush();
}

fn sendPromptResponse(
    allocator: std.mem.Allocator,
    pipe: *SerializedPipe,
    flow_id: auth_types.Ulid,
    sequence: u64,
    prompt_id: []const u8,
    answer: []const u8,
) !void {
    var env = auth_types.Envelope{
        .stream_id = flow_id,
        .message_id = auth_types.generateUlid(),
        .sequence = sequence,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .auth_prompt_response = .{
            .flow_id = flow_id,
            .prompt_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, prompt_id)),
            .answer = OwnedSlice(u8).initOwned(try allocator.dupe(u8, answer)),
        } },
    };
    defer env.deinit(allocator);

    const json = try auth_envelope_mod.serializeEnvelope(env, allocator);
    defer allocator.free(json);

    var sender = pipe.clientSender();
    try sender.write(json);
    try sender.flush();
}

fn handleAuthEvent(
    allocator: std.mem.Allocator,
    io: AuthCliIo,
    options: LoginOptions,
    event: auth_types.AuthEvent,
    pipe: *SerializedPipe,
    flow_id: auth_types.Ulid,
    next_client_seq: *u64,
    captured_error_code: *?[]u8,
    captured_error_message: *?[]u8,
) !void {
    switch (event) {
        .auth_url => |payload| try emitAuthUrl(allocator, io, options, payload),
        .progress => |payload| try emitProgress(allocator, io, options, payload),
        .prompt => |payload| {
            try emitPrompt(allocator, io, options, payload);
            const answer = try io.readLine(allocator);
            defer allocator.free(answer);
            try sendPromptResponse(allocator, pipe, flow_id, next_client_seq.*, payload.prompt_id.slice(), answer);
            next_client_seq.* += 1;
        },
        .success => {
            // Terminal status communicated via auth_login_result; success
            // event is informational only.
        },
        .@"error" => |payload| {
            if (captured_error_code.* == null) {
                captured_error_code.* = try allocator.dupe(u8, payload.code.slice());
            }
            if (captured_error_message.* == null) {
                captured_error_message.* = try allocator.dupe(u8, payload.message.slice());
            }
        },
    }
}

fn emitAuthUrl(
    allocator: std.mem.Allocator,
    io: AuthCliIo,
    options: LoginOptions,
    payload: anytype,
) !void {
    if (options.json_mode) {
        const instructions: ?[]const u8 = if (payload.instructions.slice().len > 0) payload.instructions.slice() else null;
        const value = .{
            .type = "auth_url",
            .provider = options.provider_id,
            .url = payload.url.slice(),
            .instructions = instructions,
        };
        try writeJsonLine(allocator, io, value);
        return;
    }

    try io.writeOut(payload.url.slice());
    try io.writeOut("\n");
    if (payload.instructions.slice().len > 0) {
        try io.writeOut(payload.instructions.slice());
        try io.writeOut("\n");
    }
}

fn emitProgress(
    allocator: std.mem.Allocator,
    io: AuthCliIo,
    options: LoginOptions,
    payload: anytype,
) !void {
    if (options.json_mode) {
        const value = .{
            .type = "progress",
            .provider = options.provider_id,
            .message = payload.message.slice(),
        };
        try writeJsonLine(allocator, io, value);
        return;
    }

    try io.writeOut(payload.message.slice());
    try io.writeOut("\n");
}

fn emitPrompt(
    allocator: std.mem.Allocator,
    io: AuthCliIo,
    options: LoginOptions,
    payload: anytype,
) !void {
    if (options.json_mode) {
        const value = .{
            .type = "prompt",
            .provider = options.provider_id,
            .message = payload.message.slice(),
            .allow_empty = payload.allow_empty,
        };
        try writeJsonLine(allocator, io, value);
        return;
    }

    try io.writeOut(payload.message.slice());
    try io.writeOut(" ");
}

fn emitLoginTerminal(
    allocator: std.mem.Allocator,
    io: AuthCliIo,
    options: LoginOptions,
    status: auth_types.AuthLoginStatus,
    captured_error_code: ?[]u8,
    captured_error_message: ?[]u8,
) !void {
    switch (status) {
        .success => {
            if (options.json_mode) {
                const value = .{
                    .type = "success",
                    .provider = options.provider_id,
                };
                try writeJsonLine(allocator, io, value);
            } else {
                try io.writeOut("Login successful.\n");
            }
        },
        .failed => {
            const code = captured_error_code orelse "auth_login_failed";
            const message = captured_error_message orelse "auth login failed";
            if (options.json_mode) {
                const value = .{
                    .type = "error",
                    .provider = options.provider_id,
                    .code = code,
                    .message = message,
                };
                try writeJsonLine(allocator, io, value);
            } else {
                try io.writeErr("auth login failed: ");
                try io.writeErr(code);
                try io.writeErr("\n");
            }
            return AuthCliError.AuthLoginFailed;
        },
        .cancelled => {
            if (options.json_mode) {
                const value = .{
                    .type = "error",
                    .provider = options.provider_id,
                    .code = "cancelled",
                    .message = "auth flow cancelled",
                };
                try writeJsonLine(allocator, io, value);
            } else {
                try io.writeErr("auth login cancelled\n");
            }
            return AuthCliError.AuthLoginCancelled;
        },
    }
}

fn emitProviders(
    allocator: std.mem.Allocator,
    io: AuthCliIo,
    json_mode: bool,
    response: auth_types.AuthProvidersResponse,
) !void {
    if (json_mode) {
        // Backward-compatible shape: `{ "type": "providers", "providers":
        // [{ "id", "name" }] }`. Auth status from the runtime is intentionally
        // omitted from the wrapper output to avoid altering the output schema
        // existing scripts depend on.
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"type\":\"providers\",\"providers\":[");
        for (response.providers.slice(), 0..) |provider, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '{');
            try appendJsonStringField(allocator, &buf, "id", provider.id.slice());
            try buf.append(allocator, ',');
            try appendJsonStringField(allocator, &buf, "name", provider.name.slice());
            try buf.append(allocator, '}');
        }
        try buf.appendSlice(allocator, "]}\n");
        try io.writeOut(buf.items);
        return;
    }

    for (response.providers.slice()) |provider| {
        try io.writeOut(provider.id.slice());
        try io.writeOut("\n");
    }
}

fn emitProvidersError(
    allocator: std.mem.Allocator,
    io: AuthCliIo,
    json_mode: bool,
    nack: auth_types.Nack,
) !void {
    const code = if (nack.error_code) |c| @tagName(c) else "nack";
    if (json_mode) {
        const value = .{
            .type = "error",
            .code = code,
            .message = nack.reason.slice(),
        };
        try writeJsonLine(allocator, io, value);
        return;
    }

    try io.writeErr("auth providers failed: ");
    try io.writeErr(nack.reason.slice());
    try io.writeErr("\n");
}

fn writeJsonLine(allocator: std.mem.Allocator, io: AuthCliIo, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    try io.writeOut(json);
    try io.writeOut("\n");
}

fn appendJsonStringField(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    name: []const u8,
    value: []const u8,
) !void {
    const encoded_name = try std.json.Stringify.valueAlloc(allocator, name, .{});
    defer allocator.free(encoded_name);
    const encoded_value = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded_value);

    try buf.appendSlice(allocator, encoded_name);
    try buf.append(allocator, ':');
    try buf.appendSlice(allocator, encoded_value);
}

// =============================================================================
// File-backed IO (production CLI path)
// =============================================================================

pub const FileIo = struct {
    stdin: std.Io.File,
    stdout: std.Io.File,
    stderr: std.Io.File,
    allocator: std.mem.Allocator,
    leftover: std.ArrayList(u8) = std.ArrayList(u8).empty,
    read_buf: [4096]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, stdin: std.Io.File, stdout: std.Io.File, stderr: std.Io.File) FileIo {
        return .{
            .stdin = stdin,
            .stdout = stdout,
            .stderr = stderr,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FileIo) void {
        self.leftover.deinit(self.allocator);
    }

    pub fn io(self: *FileIo) AuthCliIo {
        return .{ .ctx = @ptrCast(self), .vtable = &file_io_vtable };
    }

    fn readLine(self: *FileIo, allocator: std.mem.Allocator) ![]u8 {
        while (true) {
            if (std.mem.findScalar(u8, self.leftover.items, '\n')) |nl_pos| {
                const raw = self.leftover.items[0..nl_pos];
                const trimmed = std.mem.trim(u8, raw, " \t\r");
                const dup = try allocator.dupe(u8, trimmed);

                const remaining = self.leftover.items[nl_pos + 1 ..];
                std.mem.copyForwards(u8, self.leftover.items[0..remaining.len], remaining);
                self.leftover.shrinkRetainingCapacity(remaining.len);
                return dup;
            }

            const bytes_read = self.stdin.readStreaming(defaultIo(), &.{&self.read_buf}) catch |err| return err;
            if (bytes_read == 0) {
                if (self.leftover.items.len == 0) return error.EndOfStream;
                const raw = self.leftover.items;
                const trimmed = std.mem.trim(u8, raw, " \t\r");
                const dup = try allocator.dupe(u8, trimmed);
                self.leftover.clearRetainingCapacity();
                return dup;
            }
            try self.leftover.appendSlice(self.allocator, self.read_buf[0..bytes_read]);
        }
    }

    fn readLineFn(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *FileIo = @ptrCast(@alignCast(ctx));
        return self.readLine(allocator);
    }

    fn writeOutFn(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *FileIo = @ptrCast(@alignCast(ctx));
        try self.stdout.writeStreamingAll(defaultIo(), bytes);
    }

    fn writeErrFn(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *FileIo = @ptrCast(@alignCast(ctx));
        try self.stderr.writeStreamingAll(defaultIo(), bytes);
    }
};

const file_io_vtable = AuthCliIo.VTable{
    .read_line = FileIo.readLineFn,
    .write_out = FileIo.writeOutFn,
    .write_err = FileIo.writeErrFn,
};

// =============================================================================
// Tests
// =============================================================================

const TestIo = struct {
    inputs: std.ArrayList([]const u8),
    input_index: usize = 0,
    out: std.ArrayList(u8) = std.ArrayList(u8).empty,
    err: std.ArrayList(u8) = std.ArrayList(u8).empty,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) TestIo {
        return .{
            .inputs = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(self: *TestIo) void {
        for (self.inputs.items) |input| self.allocator.free(input);
        self.inputs.deinit(self.allocator);
        self.out.deinit(self.allocator);
        self.err.deinit(self.allocator);
    }

    fn pushInput(self: *TestIo, value: []const u8) !void {
        const dup = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(dup);
        try self.inputs.append(self.allocator, dup);
    }

    fn io(self: *TestIo) AuthCliIo {
        return .{ .ctx = @ptrCast(self), .vtable = &test_io_vtable };
    }

    fn readLineFn(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *TestIo = @ptrCast(@alignCast(ctx));
        if (self.input_index >= self.inputs.items.len) return error.EndOfStream;
        const next = self.inputs.items[self.input_index];
        self.input_index += 1;
        return try allocator.dupe(u8, next);
    }

    fn writeOutFn(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *TestIo = @ptrCast(@alignCast(ctx));
        try self.out.appendSlice(self.allocator, bytes);
    }

    fn writeErrFn(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *TestIo = @ptrCast(@alignCast(ctx));
        try self.err.appendSlice(self.allocator, bytes);
    }
};

const test_io_vtable = AuthCliIo.VTable{
    .read_line = TestIo.readLineFn,
    .write_out = TestIo.writeOutFn,
    .write_err = TestIo.writeErrFn,
};

const test_server_options = AuthProtocolServer.Options{
    .persist_credentials = false,
    .enable_real_oauth = false,
};

test "runProvidersCommand plain mode emits provider ids one per line" {
    const allocator = std.testing.allocator;
    var test_io = TestIo.init(allocator);
    defer test_io.deinit();

    try runProvidersCommand(allocator, test_io.io(), test_server_options, .{ .json_mode = false });

    // Expect at least the built-in provider ids on their own lines.
    try std.testing.expect(std.mem.find(u8, test_io.out.items, "anthropic\n") != null);
    try std.testing.expect(std.mem.find(u8, test_io.out.items, "github-copilot\n") != null);
    try std.testing.expect(std.mem.find(u8, test_io.out.items, "test-fixture\n") != null);
    try std.testing.expectEqual(@as(usize, 0), test_io.err.items.len);
}

test "runProvidersCommand json mode emits backward-compatible provider list shape" {
    const allocator = std.testing.allocator;
    var test_io = TestIo.init(allocator);
    defer test_io.deinit();

    try runProvidersCommand(allocator, test_io.io(), test_server_options, .{ .json_mode = true });

    const trimmed = std.mem.trim(u8, test_io.out.items, " \t\r\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("providers", root.get("type").?.string);

    const providers = root.get("providers").?.array;
    try std.testing.expect(providers.items.len >= 3);
    var saw_anthropic = false;
    for (providers.items) |item| {
        const obj = item.object;
        // Only the historical (id, name) fields must appear; auth-status is
        // intentionally not part of the wrapper output to preserve existing
        // script consumers.
        try std.testing.expect(obj.contains("id"));
        try std.testing.expect(obj.contains("name"));
        if (std.mem.eql(u8, obj.get("id").?.string, "anthropic")) saw_anthropic = true;
    }
    try std.testing.expect(saw_anthropic);
}

test "runLoginCommand routes through protocol runtime and completes test-fixture flow" {
    const allocator = std.testing.allocator;
    var test_io = TestIo.init(allocator);
    defer test_io.deinit();

    // Test fixture rejects the first answer to exercise the prompt loop, then
    // accepts the canonical "ok" response.
    try test_io.pushInput("bad-code");
    try test_io.pushInput("ok");

    try runLoginCommand(allocator, test_io.io(), test_server_options, .{
        .provider_id = "test-fixture",
        .json_mode = false,
    });

    try std.testing.expect(std.mem.find(u8, test_io.out.items, "https://example.invalid/makai-test-fixture-login") != null);
    try std.testing.expect(std.mem.find(u8, test_io.out.items, "Enter code 'ok' to complete fixture login.") != null);
    // Two prompts must have been issued (one for the rejected code, one for "ok").
    var prompt_count: usize = 0;
    var idx: usize = 0;
    while (std.mem.findPos(u8, test_io.out.items, idx, "Enter fixture code:")) |found| {
        prompt_count += 1;
        idx = found + 1;
    }
    try std.testing.expect(prompt_count >= 2);
    try std.testing.expect(std.mem.find(u8, test_io.out.items, "Login successful.") != null);
    // Tokens must never appear in the wrapper-visible output.
    try std.testing.expect(std.mem.find(u8, test_io.out.items, "fixture-refresh-token") == null);
    try std.testing.expect(std.mem.find(u8, test_io.out.items, "fixture-access-token") == null);
    try std.testing.expect(std.mem.find(u8, test_io.err.items, "fixture-refresh-token") == null);
    try std.testing.expect(std.mem.find(u8, test_io.err.items, "fixture-access-token") == null);
}

test "runLoginCommand json mode emits per-event envelopes followed by terminal success" {
    const allocator = std.testing.allocator;
    var test_io = TestIo.init(allocator);
    defer test_io.deinit();

    try test_io.pushInput("ok");

    try runLoginCommand(allocator, test_io.io(), test_server_options, .{
        .provider_id = "test-fixture",
        .json_mode = true,
    });

    var saw_auth_url = false;
    var saw_prompt = false;
    var saw_success = false;
    var saw_token_leak = false;

    var line_iter = std.mem.splitScalar(u8, test_io.out.items, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.find(u8, line, "fixture-refresh-token") != null) saw_token_leak = true;
        if (std.mem.find(u8, line, "fixture-access-token") != null) saw_token_leak = true;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();

        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const ty = if (obj.get("type")) |t| t.string else continue;
        if (std.mem.eql(u8, ty, "auth_url")) {
            try std.testing.expectEqualStrings("test-fixture", obj.get("provider").?.string);
            saw_auth_url = true;
        } else if (std.mem.eql(u8, ty, "prompt")) {
            try std.testing.expectEqualStrings("test-fixture", obj.get("provider").?.string);
            saw_prompt = true;
        } else if (std.mem.eql(u8, ty, "success")) {
            try std.testing.expectEqualStrings("test-fixture", obj.get("provider").?.string);
            saw_success = true;
        }
    }

    try std.testing.expect(saw_auth_url);
    try std.testing.expect(saw_prompt);
    try std.testing.expect(saw_success);
    try std.testing.expect(!saw_token_leak);
}

test "runLoginCommand surfaces typed error for unknown provider" {
    const allocator = std.testing.allocator;
    var test_io = TestIo.init(allocator);
    defer test_io.deinit();

    const result = runLoginCommand(allocator, test_io.io(), test_server_options, .{
        .provider_id = "unknown-provider",
        .json_mode = false,
    });

    try std.testing.expectError(AuthCliError.AuthLoginFailed, result);
    try std.testing.expect(std.mem.find(u8, test_io.err.items, "auth login failed") != null);
}
