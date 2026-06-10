//! Worker-thread driver for interactive `/login` OAuth flows.
//!
//! The OAuth `login()` functions are blocking and use context-free function
//! pointer callbacks, which are incompatible with the zigzag event loop. This
//! module runs a provider's `login()` on a worker thread and bridges its
//! callbacks through a module-level global (only one login may run at a time).
//! The main thread drives the UI by calling `poll()` each tick: it surfaces the
//! authorization URL, switches to an input prompt when the worker blocks on
//! `onPrompt`, and collects the result when the flow completes.

const std = @import("std");
const compat = @import("compat");
const storage = @import("oauth/storage");
const anthropic = @import("oauth/anthropic");
const github = @import("oauth/github_copilot");
const codex = @import("oauth/openai_codex");

pub const Provider = enum {
    anthropic,
    github_copilot,
    openai_codex,
};

/// Storage key under which credentials are persisted in `~/.makai/auth.json`.
/// Must match the provider IDs consumers expect (see protocol/auth/server.zig).
pub fn providerStorageKey(provider: Provider) []const u8 {
    return switch (provider) {
        .anthropic => "anthropic",
        .github_copilot => "github-copilot",
        .openai_codex => "openai-codex",
    };
}

const Phase = enum { running, done, failed };

pub const PollResult = union(enum) {
    none,
    /// The flow produced an authorization URL the user must open. Borrowed,
    /// valid until the next `poll()`/`deinit()`.
    show_auth: struct { url: []const u8, instructions: ?[]const u8 },
    /// The worker is blocked waiting for pasted input. Borrowed message.
    request_input: struct { message: []const u8 },
    /// Login finished; ownership of the credentials transfers to the caller.
    done: storage.Credentials,
    /// Login failed; borrowed error name, valid until `deinit()`.
    failed: []const u8,
};

/// Only one login may be active at a time. The OAuth callbacks take no context
/// pointer, so they reach the active session through this global.
var g_active: ?*LoginSession = null;

pub const LoginSession = struct {
    allocator: std.mem.Allocator,
    provider: Provider,
    provider_id: []const u8,
    mutex: std.atomic.Mutex = .unlocked,
    thread: ?std.Thread = null,
    phase: Phase = .running,
    shutting_down: bool = false,

    auth_pending: bool = false,
    auth_url: []u8 = &.{},
    auth_instructions: []u8 = &.{},

    prompt_pending: bool = false,
    prompt_message: []u8 = &.{},

    input_ready: bool = false,
    input_value: []u8 = &.{},

    result: ?storage.Credentials = null,
    error_name: []u8 = &.{},

    /// Spawn the worker thread for `provider`. Caller owns the returned pointer
    /// and must call `deinit()`.
    pub fn start(allocator: std.mem.Allocator, provider: Provider) !*LoginSession {
        if (g_active != null) return error.LoginInProgress;

        const self = try allocator.create(LoginSession);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .provider = provider,
            .provider_id = providerStorageKey(provider),
        };

        g_active = self;
        errdefer g_active = null;

        self.thread = switch (provider) {
            .anthropic => try std.Thread.spawn(.{}, runAnthropic, .{self}),
            .github_copilot => try std.Thread.spawn(.{}, runGithub, .{self}),
            .openai_codex => try std.Thread.spawn(.{}, runCodex, .{self}),
        };
        return self;
    }

    /// Spin until the mutex is acquired (std.atomic.Mutex has no blocking lock).
    fn lock(self: *LoginSession) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    /// Signal the worker to stop, join it, and free everything.
    pub fn deinit(self: *LoginSession) void {
        {
            self.lock();
            defer self.mutex.unlock();
            self.shutting_down = true;
        }
        if (self.thread) |thread| thread.join();
        const allocator = self.allocator;
        if (self.auth_url.len > 0) allocator.free(self.auth_url);
        if (self.auth_instructions.len > 0) allocator.free(self.auth_instructions);
        if (self.prompt_message.len > 0) allocator.free(self.prompt_message);
        if (self.input_value.len > 0) allocator.free(self.input_value);
        if (self.error_name.len > 0) allocator.free(self.error_name);
        if (self.result) |creds| creds.deinit(allocator);
        g_active = null;
        allocator.destroy(self);
    }

    /// Main-thread step. Performs at most one transition per call.
    pub fn poll(self: *LoginSession) PollResult {
        self.lock();
        defer self.mutex.unlock();

        if (self.auth_pending) {
            self.auth_pending = false;
            return .{ .show_auth = .{
                .url = self.auth_url,
                .instructions = if (self.auth_instructions.len > 0) self.auth_instructions else null,
            } };
        }
        if (self.prompt_pending) {
            self.prompt_pending = false;
            return .{ .request_input = .{ .message = self.prompt_message } };
        }
        if (self.phase == .done) {
            if (self.result) |creds| {
                self.result = null;
                return .{ .done = creds };
            }
            return .none;
        }
        if (self.phase == .failed) {
            return .{ .failed = if (self.error_name.len > 0) self.error_name else "login failed" };
        }
        return .none;
    }

    /// Provide the input the worker is blocked on. Empty text is allowed for
    /// optional prompts (e.g. the GitHub enterprise domain).
    pub fn provideInput(self: *LoginSession, text: []const u8) !void {
        const dup = try self.allocator.dupe(u8, text);
        self.lock();
        defer self.mutex.unlock();
        if (self.input_value.len > 0) self.allocator.free(self.input_value);
        self.input_value = dup;
        self.input_ready = true;
    }

    // --- worker-side helpers (run on the worker thread) ---

    fn recordAuth(self: *LoginSession, url: []const u8, instructions: ?[]const u8) void {
        self.lock();
        defer self.mutex.unlock();
        if (self.auth_url.len > 0) self.allocator.free(self.auth_url);
        self.auth_url = self.allocator.dupe(u8, url) catch &.{};
        if (self.auth_instructions.len > 0) self.allocator.free(self.auth_instructions);
        self.auth_instructions = if (instructions) |ins| (self.allocator.dupe(u8, ins) catch &.{}) else &.{};
        self.auth_pending = true;
    }

    /// Block until the main thread supplies input, then hand ownership of the
    /// allocated slice to the caller when non-empty input is required. Optional
    /// prompts keep empty input as a non-owned literal so provider flows that
    /// interpret empty as "use default" do not try to free it.
    fn waitForInput(self: *LoginSession, message: []const u8, allow_empty: bool) []const u8 {
        self.lock();
        if (self.prompt_message.len > 0) self.allocator.free(self.prompt_message);
        self.prompt_message = self.allocator.dupe(u8, message) catch &.{};
        self.prompt_pending = true;
        self.input_ready = false;
        self.mutex.unlock();

        while (true) {
            self.lock();
            const ready = self.input_ready;
            const shutting = self.shutting_down;
            if (ready) {
                const value = self.input_value;
                self.input_value = &.{};
                self.input_ready = false;
                self.mutex.unlock();
                if (value.len == 0) {
                    if (allow_empty) {
                        self.allocator.free(value);
                        return "";
                    }
                    return value;
                }
                return value;
            }
            self.mutex.unlock();
            if (shutting) {
                if (allow_empty) return "";
                return self.allocator.alloc(u8, 0) catch @panic("OOM");
            }
            compat.time.sleepNs(5 * std.time.ns_per_ms);
        }
    }

    fn finishSuccess(self: *LoginSession, refresh: []const u8, access: []const u8, expires: i64, provider_data: ?[]const u8) void {
        self.lock();
        defer self.mutex.unlock();
        const refresh_copy = self.allocator.dupe(u8, refresh) catch return self.setFailedLocked("OutOfMemory");
        const access_copy = self.allocator.dupe(u8, access) catch {
            self.allocator.free(refresh_copy);
            return self.setFailedLocked("OutOfMemory");
        };
        const pd_copy: ?[]const u8 = if (provider_data) |pd| (self.allocator.dupe(u8, pd) catch {
            self.allocator.free(refresh_copy);
            self.allocator.free(access_copy);
            return self.setFailedLocked("OutOfMemory");
        }) else null;
        self.result = .{
            .refresh = refresh_copy,
            .access = access_copy,
            .expires = expires,
            .provider_data = pd_copy,
        };
        self.phase = .done;
    }

    fn finishError(self: *LoginSession, name: []const u8) void {
        self.lock();
        defer self.mutex.unlock();
        self.setFailedLocked(name);
    }

    fn setFailedLocked(self: *LoginSession, name: []const u8) void {
        if (self.error_name.len > 0) self.allocator.free(self.error_name);
        self.error_name = self.allocator.dupe(u8, name) catch &.{};
        self.phase = .failed;
    }
};

// --- callback bridges (one shim per provider; all funnel into the active session) ---

fn anthropicOnAuth(info: anthropic.AuthInfo) void {
    if (g_active) |s| s.recordAuth(info.url, info.instructions);
}
fn anthropicOnPrompt(prompt: anthropic.Prompt) []const u8 {
    const s = g_active orelse return "";
    return s.waitForInput(prompt.message, prompt.allow_empty);
}

fn githubOnAuth(info: github.AuthInfo) void {
    if (g_active) |s| s.recordAuth(info.url, info.instructions);
}
fn githubOnPrompt(prompt: github.Prompt) []const u8 {
    const s = g_active orelse return "";
    return s.waitForInput(prompt.message, prompt.allow_empty);
}

fn codexOnAuth(info: codex.AuthInfo) void {
    if (g_active) |s| s.recordAuth(info.url, info.instructions);
}
fn codexOnPrompt(prompt: codex.Prompt) []const u8 {
    const s = g_active orelse return "";
    return s.waitForInput(prompt.message, prompt.allow_empty);
}

// --- worker entry points ---

fn runAnthropic(self: *LoginSession) void {
    const creds = anthropic.login(.{ .onAuth = anthropicOnAuth, .onPrompt = anthropicOnPrompt }, self.allocator) catch |err| {
        self.finishError(@errorName(err));
        return;
    };
    defer {
        self.allocator.free(creds.refresh);
        self.allocator.free(creds.access);
    }
    self.finishSuccess(creds.refresh, creds.access, creds.expires, null);
}

fn runGithub(self: *LoginSession) void {
    const creds = github.login(.{ .onAuth = githubOnAuth, .onPrompt = githubOnPrompt }, self.allocator) catch |err| {
        self.finishError(@errorName(err));
        return;
    };
    defer freeGithubCredentials(self.allocator, creds);
    self.finishSuccess(creds.refresh, creds.access, creds.expires, creds.provider_data);
}

fn runCodex(self: *LoginSession) void {
    const creds = codex.login(.{ .onAuth = codexOnAuth, .onPrompt = codexOnPrompt }, self.allocator) catch |err| {
        self.finishError(@errorName(err));
        return;
    };
    defer {
        self.allocator.free(creds.refresh);
        self.allocator.free(creds.access);
        if (creds.provider_data) |pd| self.allocator.free(pd);
    }
    self.finishSuccess(creds.refresh, creds.access, creds.expires, creds.provider_data);
}

fn freeGithubCredentials(allocator: std.mem.Allocator, creds: github.Credentials) void {
    allocator.free(creds.refresh);
    allocator.free(creds.access);
    if (creds.provider_data) |pd| allocator.free(pd);
    if (creds.base_url) |bu| allocator.free(bu);
    if (creds.enabled_models) |models| {
        for (models) |m| allocator.free(m);
        allocator.free(models);
    }
}

test "providerStorageKey maps to expected ids" {
    try std.testing.expectEqualStrings("anthropic", providerStorageKey(.anthropic));
    try std.testing.expectEqualStrings("github-copilot", providerStorageKey(.github_copilot));
    try std.testing.expectEqualStrings("openai-codex", providerStorageKey(.openai_codex));
}

test "LoginSession start rejects a second concurrent login" {
    // Manually occupy the global without spawning a worker.
    var placeholder: LoginSession = .{
        .allocator = std.testing.allocator,
        .provider = .anthropic,
        .provider_id = providerStorageKey(.anthropic),
    };
    g_active = &placeholder;
    defer g_active = null;

    try std.testing.expectError(error.LoginInProgress, LoginSession.start(std.testing.allocator, .anthropic));
}

test "LoginSession bridges prompt input through the worker" {
    const Helper = struct {
        fn worker(session: *LoginSession) void {
            const input = session.waitForInput("Enter code:", false);
            defer if (input.len > 0) session.allocator.free(input);
            session.finishSuccess("refresh-tok", input, 1234, null);
        }
    };

    const session = try std.testing.allocator.create(LoginSession);
    session.* = .{
        .allocator = std.testing.allocator,
        .provider = .anthropic,
        .provider_id = providerStorageKey(.anthropic),
    };
    g_active = session;
    session.thread = try std.Thread.spawn(.{}, Helper.worker, .{session});
    defer session.deinit();

    // Wait for the worker to request input.
    var requested = false;
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        switch (session.poll()) {
            .request_input => {
                requested = true;
                break;
            },
            else => {},
        }
        compat.time.sleepNs(2 * std.time.ns_per_ms);
    }
    try std.testing.expect(requested);

    try session.provideInput("my-code");

    var creds: ?storage.Credentials = null;
    attempts = 0;
    while (attempts < 200) : (attempts += 1) {
        switch (session.poll()) {
            .done => |c| {
                creds = c;
                break;
            },
            else => {},
        }
        compat.time.sleepNs(2 * std.time.ns_per_ms);
    }
    try std.testing.expect(creds != null);
    defer creds.?.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("my-code", creds.?.access);
    try std.testing.expectEqualStrings("refresh-tok", creds.?.refresh);
}
