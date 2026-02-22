const std = @import("std");
const anthropic_oauth = @import("oauth/anthropic");
const github_oauth = @import("oauth/github_copilot");
const oauth_storage = @import("oauth/storage");

pub const VERSION = "0.0.1";

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
        try stdout.writeAll("{\"type\":\"ready\",\"protocol_version\":\"1\"}\n");
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = try stdin.read(&buffer);
            if (n == 0) break;
        }
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
