const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const retry = @import("retry");

pub const DEFAULT_E2E_TIMEOUT_MS: u64 = 60_000;

pub fn createDeadline(timeout_ms: u64) i64 {
    return compat.time.nowMillis() + @as(i64, @intCast(timeout_ms));
}

pub fn isDeadlineExceeded(deadline: i64) bool {
    return compat.time.nowMillis() > deadline;
}

pub fn waitForStreamCompletion(stream: anytype, timeout_ms: u64) !void {
    const deadline = createDeadline(timeout_ms);
    while (!stream.completed.load(.acquire)) {
        if (isDeadlineExceeded(deadline)) {
            return error.TimeoutExceeded;
        }
        compat.time.sleepNs(10 * std.time.ns_per_ms);
    }
}

pub const RetryTestConfig = struct {
    max_retries: u32 = 3,
    base_delay_ms: u64 = 1000,
};

pub fn runWithRetries(
    comptime test_fn: fn (std.mem.Allocator) anyerror!void,
    allocator: std.mem.Allocator,
    config: RetryTestConfig,
) !void {
    const retryable_errors = [_]anyerror{
        error.TimeoutExceeded,
        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.StreamError,
    };

    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        test_fn(allocator) catch |err| {
            const is_retryable = blk: {
                for (retryable_errors) |re| {
                    if (err == re) break :blk true;
                }
                break :blk false;
            };

            if (is_retryable and attempt < config.max_retries) {
                const shift: u6 = @intCast(@min(attempt, 10));
                const delay: u64 = config.base_delay_ms * (@as(u64, 1) << shift);
                const capped_delay = @min(delay, 30000);
                std.debug.print("\n  Retry {}/{} after {}ms (error: {})\n", .{
                    attempt + 1, config.max_retries, capped_delay, err
                });
                compat.time.sleepNs(capped_delay * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        return;
    }
}

pub fn testStart(test_name: []const u8) void {
    std.debug.print("\n\x1b[36m[TEST START]\x1b[0m {s}\n", .{test_name});
}

pub fn testSuccess(test_name: []const u8) void {
    std.debug.print("\x1b[32m[TEST PASS]\x1b[0m {s}\n", .{test_name});
}

pub fn testStep(comptime format: []const u8, args: anytype) void {
    std.debug.print("  \x1b[2m" ++ format ++ "\x1b[0m\n", args);
}

pub fn skipTest(allocator: std.mem.Allocator, provider_name: []const u8) error{SkipZigTest}!void {
    const should_skip: bool = if (std.ascii.eqlIgnoreCase(provider_name, "anthropic"))
        shouldSkipAnthropic(allocator)
    else if (std.ascii.eqlIgnoreCase(provider_name, "github_copilot"))
        shouldSkipGitHubCopilot(allocator)
    else
        shouldSkipProvider(allocator, provider_name);

    if (!should_skip) return;

    if (std.ascii.eqlIgnoreCase(provider_name, "openai")) {
        std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for '{s}' - no credentials available (set OPENAI_API_KEY)\n", .{provider_name});
    } else if (std.ascii.eqlIgnoreCase(provider_name, "google")) {
        std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for '{s}' - no credentials available (set GOOGLE_API_KEY)\n", .{provider_name});
    } else if (std.ascii.eqlIgnoreCase(provider_name, "anthropic")) {
        std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for '{s}' - no credentials available (set ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY)\n", .{provider_name});
    } else {
        std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for '{s}' - no credentials available\n", .{provider_name});
    }
    return error.SkipZigTest;
}

pub fn skipAnthropicTest(allocator: std.mem.Allocator) error{SkipZigTest}!void {
    if (!shouldSkipAnthropic(allocator)) return;
    std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for 'anthropic' - no credentials available (set ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY)\n", .{});
    return error.SkipZigTest;
}

pub fn skipGitHubCopilotTest(allocator: std.mem.Allocator) error{SkipZigTest}!void {
    if (!shouldSkipGitHubCopilot(allocator)) return;
    std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for 'github_copilot' - no credentials available (set GH_COPILOT_REFRESH/GH_COPILOT_ACCESS or COPILOT_TOKEN)\n", .{});
    return error.SkipZigTest;
}

pub fn skipAzureTest(allocator: std.mem.Allocator) error{SkipZigTest}!void {
    if (!shouldSkipProvider(allocator, "azure")) {
        if (compat.getEnvVarOwned(allocator, "AZURE_OPENAI_ENDPOINT")) |_| {
            return;
        } else |_| {}
        if (compat.getEnvVarOwned(allocator, "AZURE_RESOURCE_NAME")) |_| {
            return;
        } else |_| {}
    }
    std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for 'azure' - no credentials available (set AZURE_OPENAI_API_KEY and AZURE_OPENAI_ENDPOINT/AZURE_RESOURCE_NAME)\n", .{});
    return error.SkipZigTest;
}

pub fn skipGoogleTest(allocator: std.mem.Allocator) error{SkipZigTest}!void {
    if (!shouldSkipProvider(allocator, "google")) return;
    std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for 'google' - no credentials available (set GOOGLE_API_KEY)\n", .{});
    return error.SkipZigTest;
}

pub fn skipGoogleVertexTest(allocator: std.mem.Allocator) error{SkipZigTest}!void {
    if (!shouldSkipProvider(allocator, "google_vertex")) {
        if (compat.getEnvVarOwned(allocator, "GOOGLE_VERTEX_PROJECT_ID")) |_| {
            return;
        } else |_| {}
    }
    std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for 'google_vertex' - no credentials available (set GOOGLE_VERTEX_PROJECT_ID and GOOGLE_APPLICATION_CREDENTIALS)\n", .{});
    return error.SkipZigTest;
}

pub fn skipBedrockTest(allocator: std.mem.Allocator) error{SkipZigTest}!void {
    if (compat.getEnvVarOwned(allocator, "AWS_ACCESS_KEY_ID")) |_| {
        return;
    } else |_| {}
    std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for 'bedrock' - no credentials available (set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION)\n", .{});
    return error.SkipZigTest;
}

pub fn skipOllamaTest(allocator: std.mem.Allocator) error{SkipZigTest}!void {
    if (compat.getEnvVarOwned(allocator, "OLLAMA_API_KEY")) |key| {
        allocator.free(key);
        return;
    } else |_| {}
    std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for 'ollama' - OLLAMA_API_KEY not set\n", .{});
    return error.SkipZigTest;
}

pub const OllamaCredentials = struct {
    api_key: []const u8,
    base_url: []const u8,

    pub fn deinit(self: *OllamaCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.api_key);
        allocator.free(self.base_url);
    }
};

pub fn getOllamaCredentials(allocator: std.mem.Allocator) !?OllamaCredentials {
    const api_key = compat.getEnvVarOwned(allocator, "OLLAMA_API_KEY") catch return null;

    const base_url = if (compat.getEnvVarOwned(allocator, "OLLAMA_BASE_URL")) |url|
        url
    else |_|
        try allocator.dupe(u8, "https://api.ollama.ai");

    return OllamaCredentials{
        .api_key = api_key,
        .base_url = base_url,
    };
}

pub fn skipAnthropicOAuthTest(allocator: std.mem.Allocator) error{SkipZigTest}!void {
    if (!shouldSkipAnthropicOAuth(allocator)) return;
    std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for 'anthropic_oauth' - no OAuth credentials available (set ANTHROPIC_AUTH_TOKEN)\n", .{});
    return error.SkipZigTest;
}

pub const AnthropicCredential = struct {
    token: []const u8,
    is_oauth: bool,

    pub fn deinit(self: *AnthropicCredential, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
    }
};

pub fn getAnthropicCredential(allocator: std.mem.Allocator) !?AnthropicCredential {
    if (compat.getEnvVarOwned(allocator, "ANTHROPIC_AUTH_TOKEN")) |token| {
        if (std.mem.findScalar(u8, token, ':')) |colon_pos| {
            const access_token = try allocator.dupe(u8, token[colon_pos + 1 ..]);
            allocator.free(token);
            return AnthropicCredential{
                .token = access_token,
                .is_oauth = true,
            };
        } else {
            return AnthropicCredential{
                .token = token,
                .is_oauth = true,
            };
        }
    } else |_| {}

    if (compat.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY")) |key| {
        return AnthropicCredential{
            .token = key,
            .is_oauth = false,
        };
    } else |_| {}

    return getAnthropicCredentialFromAuthFile(allocator);
}

fn getAnthropicCredentialFromAuthFile(allocator: std.mem.Allocator) !?AnthropicCredential {
    const home_dir = compat.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home_dir);

    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".makai", "auth.json" });
    defer allocator.free(auth_path);

    const file = std.Io.Dir.openFileAbsolute(std.testing.io, auth_path, .{}) catch return null;
    defer file.close(std.testing.io);

    const stat = try file.stat(std.testing.io);
    if (stat.size > 1024 * 1024) return null;
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buffer);
    const content = try reader.interface.readAlloc(allocator, @intCast(stat.size));
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const providers = root.object.get("providers") orelse return null;
    if (providers != .object) return null;

    const provider_obj = providers.object.get("anthropic") orelse return null;
    if (provider_obj != .object) return null;

    if (provider_obj.object.get("oauth_token")) |oauth_val| {
        if (oauth_val == .string) {
            return AnthropicCredential{
                .token = try allocator.dupe(u8, oauth_val.string),
                .is_oauth = true,
            };
        }
    }

    if (provider_obj.object.get("api_key")) |api_key_val| {
        if (api_key_val == .string) {
            return AnthropicCredential{
                .token = try allocator.dupe(u8, api_key_val.string),
                .is_oauth = false,
            };
        }
    }

    return null;
}

pub fn shouldSkipAnthropic(allocator: std.mem.Allocator) bool {
    const cred = getAnthropicCredential(allocator) catch return true;
    if (cred) |c| {
        var mutable_cred = c;
        mutable_cred.deinit(allocator);
        return false;
    }
    return true;
}

pub fn getApiKey(allocator: std.mem.Allocator, provider_name: []const u8) !?[]const u8 {
    var env_var_name: std.ArrayList(u8) = .{};
    defer env_var_name.deinit(allocator);

    try env_var_name.appendSlice(allocator, provider_name);
    try env_var_name.appendSlice(allocator, "_API_KEY");

    for (env_var_name.items) |*c| {
        c.* = std.ascii.toUpper(c.*);
    }

    if (compat.getEnvVarOwned(allocator, env_var_name.items)) |key| {
        return key;
    } else |_| {
        return getApiKeyFromAuthFile(allocator, provider_name);
    }
}

fn getApiKeyFromAuthFile(allocator: std.mem.Allocator, provider_name: []const u8) !?[]const u8 {
    const home_dir = compat.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home_dir);

    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".makai", "auth.json" });
    defer allocator.free(auth_path);

    const file = std.Io.Dir.openFileAbsolute(std.testing.io, auth_path, .{}) catch return null;
    defer file.close(std.testing.io);

    const stat = try file.stat(std.testing.io);
    if (stat.size > 1024 * 1024) return null;
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buffer);
    const content = try reader.interface.readAlloc(allocator, @intCast(stat.size));
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const providers = root.object.get("providers") orelse return null;
    if (providers != .object) return null;

    const provider_obj = providers.object.get(provider_name) orelse return null;
    if (provider_obj != .object) return null;

    const api_key = provider_obj.object.get("api_key") orelse return null;
    if (api_key != .string) return null;

    return try allocator.dupe(u8, api_key.string);
}

pub fn shouldSkipProvider(allocator: std.mem.Allocator, provider_name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(provider_name, "anthropic")) {
        return shouldSkipAnthropic(allocator);
    }

    const api_key = getApiKey(allocator, provider_name) catch return true;
    if (api_key) |key| {
        allocator.free(key);
        return false;
    }
    return true;
}

pub const GitHubCopilotCredentials = struct {
    copilot_token: []const u8,
    github_token: []const u8,

    pub fn deinit(self: *GitHubCopilotCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.copilot_token);
        allocator.free(self.github_token);
    }
};

pub fn getGitHubCopilotCredentials(allocator: std.mem.Allocator) !?GitHubCopilotCredentials {
    const refresh_result = compat.getEnvVarOwned(allocator, "GH_COPILOT_REFRESH");
    const access_result = compat.getEnvVarOwned(allocator, "GH_COPILOT_ACCESS");

    if (refresh_result) |refresh_token| {
        if (access_result) |access_token| {
            return GitHubCopilotCredentials{
                .github_token = refresh_token,
                .copilot_token = access_token,
            };
        } else |_| {
            return GitHubCopilotCredentials{
                .github_token = refresh_token,
                .copilot_token = try allocator.dupe(u8, refresh_token),
            };
        }
    } else |_| {
        if (access_result) |access_token| {
            allocator.free(access_token);
        } else |_| {}
    }

    if (compat.getEnvVarOwned(allocator, "COPILOT_TOKEN")) |token| {
        if (std.mem.findScalar(u8, token, ':')) |colon_pos| {
            const github_token = token[0..colon_pos];
            const copilot_token = token[colon_pos + 1 ..];
            const result = GitHubCopilotCredentials{
                .copilot_token = try allocator.dupe(u8, copilot_token),
                .github_token = try allocator.dupe(u8, github_token),
            };
            allocator.free(token);
            return result;
        } else {
            return GitHubCopilotCredentials{
                .copilot_token = token,
                .github_token = try allocator.dupe(u8, token),
            };
        }
    } else |_| {
        return getGitHubCopilotCredentialsFromAuthFile(allocator);
    }
}

fn getGitHubCopilotCredentialsFromAuthFile(allocator: std.mem.Allocator) !?GitHubCopilotCredentials {
    const home_dir = compat.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home_dir);

    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".makai", "auth.json" });
    defer allocator.free(auth_path);

    const file = std.Io.Dir.openFileAbsolute(std.testing.io, auth_path, .{}) catch return null;
    defer file.close(std.testing.io);

    const stat = try file.stat(std.testing.io);
    if (stat.size > 1024 * 1024) return null;
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buffer);
    const content = try reader.interface.readAlloc(allocator, @intCast(stat.size));
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const providers = root.object.get("providers") orelse return null;
    if (providers != .object) return null;

    const provider_val = providers.object.get("github_copilot") orelse return null;

    if (provider_val == .string) {
        const combined = provider_val.string;
        if (std.mem.findScalar(u8, combined, ':')) |colon_pos| {
            const github_token = combined[0..colon_pos];
            const copilot_token = combined[colon_pos + 1 ..];
            return GitHubCopilotCredentials{
                .copilot_token = try allocator.dupe(u8, copilot_token),
                .github_token = try allocator.dupe(u8, github_token),
            };
        }
        return null;
    }

    if (provider_val != .object) return null;

    const copilot_token_val = provider_val.object.get("copilot_token") orelse return null;
    if (copilot_token_val != .string) return null;

    const github_token_val = provider_val.object.get("github_token") orelse return null;
    if (github_token_val != .string) return null;

    return GitHubCopilotCredentials{
        .copilot_token = try allocator.dupe(u8, copilot_token_val.string),
        .github_token = try allocator.dupe(u8, github_token_val.string),
    };
}

pub fn shouldSkipGitHubCopilot(allocator: std.mem.Allocator) bool {
    if (compat.getEnvVarOwned(allocator, "GH_COPILOT_REFRESH")) |token| {
        allocator.free(token);
        return false;
    } else |_| {}

    if (compat.getEnvVarOwned(allocator, "COPILOT_TOKEN")) |token| {
        allocator.free(token);
        return false;
    } else |_| {}

    const creds = getGitHubCopilotCredentials(allocator) catch return true;
    if (creds) |c| {
        var mutable_creds = c;
        mutable_creds.deinit(allocator);
        return false;
    }
    return true;
}

pub const AnthropicOAuthCredentials = struct {
    refresh_token: []const u8,
    access_token: []const u8,

    pub fn deinit(self: *AnthropicOAuthCredentials, allocator: std.mem.Allocator) void {
        if (self.refresh_token.len > 0) {
            allocator.free(self.refresh_token);
        }
        allocator.free(self.access_token);
    }
};

pub fn getAnthropicOAuthCredentials(allocator: std.mem.Allocator) !?AnthropicOAuthCredentials {
    if (compat.getEnvVarOwned(allocator, "ANTHROPIC_AUTH_TOKEN")) |token| {
        if (std.mem.findScalar(u8, token, ':')) |colon_pos| {
            const refresh_token = token[0..colon_pos];
            const access_token = token[colon_pos + 1 ..];
            const result = AnthropicOAuthCredentials{
                .refresh_token = try allocator.dupe(u8, refresh_token),
                .access_token = try allocator.dupe(u8, access_token),
            };
            allocator.free(token);
            return result;
        } else {
            const result = AnthropicOAuthCredentials{
                .refresh_token = &[_]u8{},
                .access_token = token,
            };
            return result;
        }
    } else |_| {
        return getAnthropicOAuthCredentialsFromAuthFile(allocator);
    }
}

fn getAnthropicOAuthCredentialsFromAuthFile(allocator: std.mem.Allocator) !?AnthropicOAuthCredentials {
    const home_dir = compat.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home_dir);

    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".makai", "auth.json" });
    defer allocator.free(auth_path);

    const file = std.Io.Dir.openFileAbsolute(std.testing.io, auth_path, .{}) catch return null;
    defer file.close(std.testing.io);

    const stat = try file.stat(std.testing.io);
    if (stat.size > 1024 * 1024) return null;
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buffer);
    const content = try reader.interface.readAlloc(allocator, @intCast(stat.size));
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const providers = root.object.get("providers") orelse return null;
    if (providers != .object) return null;

    const provider_val = providers.object.get("anthropic") orelse return null;

    if (provider_val == .string) {
        const combined = provider_val.string;
        if (std.mem.findScalar(u8, combined, ':')) |colon_pos| {
            const refresh_token = combined[0..colon_pos];
            const access_token = combined[colon_pos + 1 ..];
            return AnthropicOAuthCredentials{
                .refresh_token = try allocator.dupe(u8, refresh_token),
                .access_token = try allocator.dupe(u8, access_token),
            };
        }
        return null;
    }

    if (provider_val != .object) return null;

    const oauth_token_val = provider_val.object.get("oauth_token") orelse return null;
    if (oauth_token_val != .string) return null;

    const refresh_token_val = provider_val.object.get("refresh_token");
    const refresh_token = if (refresh_token_val) |rv|
        if (rv == .string) try allocator.dupe(u8, rv.string) else &[_]u8{}
    else
        &[_]u8{};

    return AnthropicOAuthCredentials{
        .refresh_token = refresh_token,
        .access_token = try allocator.dupe(u8, oauth_token_val.string),
    };
}

pub fn shouldSkipAnthropicOAuth(allocator: std.mem.Allocator) bool {
    if (compat.getEnvVarOwned(allocator, "ANTHROPIC_AUTH_TOKEN")) |token| {
        allocator.free(token);
        return false;
    } else |_| {}

    const creds = getAnthropicOAuthCredentials(allocator) catch return true;
    if (creds) |c| {
        var mutable_creds = c;
        mutable_creds.deinit(allocator);
        return false;
    }
    return true;
}

pub const FreshAnthropicCredentials = struct {
    access_token: []const u8,
    refresh_token: []const u8,

    pub fn deinit(self: *FreshAnthropicCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        if (self.refresh_token.len > 0) {
            allocator.free(self.refresh_token);
        }
    }
};

pub fn getFreshAnthropicOAuthCredentials(allocator: std.mem.Allocator) !?FreshAnthropicCredentials {
    const oauth_anthropic = @import("oauth/anthropic");

    const creds = (try getAnthropicOAuthCredentials(allocator)) orelse return null;
    var mutable_creds = creds;
    defer mutable_creds.deinit(allocator);

    if (creds.refresh_token.len > 0) {
        const fresh_creds = try oauth_anthropic.refreshToken(.{
            .refresh = creds.refresh_token,
            .access = creds.access_token,
            .expires = 0,
        }, allocator);

        return FreshAnthropicCredentials{
            .access_token = fresh_creds.access,
            .refresh_token = fresh_creds.refresh,
        };
    }

    return FreshAnthropicCredentials{
        .access_token = try allocator.dupe(u8, creds.access_token),
        .refresh_token = try allocator.dupe(u8, creds.refresh_token),
    };
}

pub const FreshGitHubCopilotCredentials = struct {
    copilot_token: []const u8,
    github_token: []const u8,
    base_url: ?[]const u8 = null,

    pub fn deinit(self: *FreshGitHubCopilotCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.copilot_token);
        allocator.free(self.github_token);
        if (self.base_url) |url| allocator.free(url);
    }
};

pub fn getFreshGitHubCopilotCredentials(allocator: std.mem.Allocator) !?FreshGitHubCopilotCredentials {
    const oauth_github_copilot = @import("oauth/github_copilot");

    const creds = (try getGitHubCopilotCredentials(allocator)) orelse return null;
    var mutable_creds = creds;
    defer mutable_creds.deinit(allocator);

    const fresh_creds = try oauth_github_copilot.refreshToken(.{
        .refresh = creds.github_token,
        .access = creds.copilot_token,
        .expires = 0,
    }, allocator);

    const copilot_token = try allocator.dupe(u8, fresh_creds.access);
    const github_token = try allocator.dupe(u8, fresh_creds.refresh);
    const base_url = if (fresh_creds.base_url) |url| try allocator.dupe(u8, url) else null;

    allocator.free(fresh_creds.refresh);
    allocator.free(fresh_creds.access);
    if (fresh_creds.provider_data) |pd| allocator.free(pd);
    if (fresh_creds.enabled_models) |models| {
        for (models) |m| allocator.free(m);
        allocator.free(models);
    }
    if (fresh_creds.base_url) |url| allocator.free(url);

    return FreshGitHubCopilotCredentials{
        .copilot_token = copilot_token,
        .github_token = github_token,
        .base_url = base_url,
    };
}

pub fn freeEvent(event: ai_types.AssistantMessageEvent, allocator: std.mem.Allocator) void {
    switch (event) {
        .text_delta => |d| allocator.free(d.delta),
        .thinking_delta => |d| allocator.free(d.delta),
        .toolcall_delta => |d| allocator.free(d.delta),
        .toolcall_end => |e| {
            allocator.free(e.tool_call.id);
            allocator.free(e.tool_call.name);
            allocator.free(e.tool_call.arguments_json);
            if (e.tool_call.thought_signature) |sig| {
                allocator.free(sig);
            }
        },
        else => {},
    }
}

pub const EventAccumulator = struct {
    events_seen: usize = 0,
    text_buffer: std.ArrayList(u8),
    thinking_buffer: std.ArrayList(u8),
    tool_calls: std.ArrayList(ToolCall),
    last_model: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub const ToolCall = struct {
        id: []const u8,
        name: []const u8,
        arguments_json: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) EventAccumulator {
        return .{
            .text_buffer = .{},
            .thinking_buffer = .{},
            .tool_calls = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EventAccumulator) void {
        self.text_buffer.deinit(self.allocator);
        self.thinking_buffer.deinit(self.allocator);
        for (self.tool_calls.items) |tc| {
            self.allocator.free(tc.id);
            self.allocator.free(tc.name);
            self.allocator.free(tc.arguments_json);
        }
        self.tool_calls.deinit(self.allocator);
        if (self.last_model) |m| {
            self.allocator.free(m);
        }
    }

    pub fn processEvent(self: *EventAccumulator, event: ai_types.AssistantMessageEvent) !void {
        self.events_seen += 1;

        switch (event) {
            .start => |s| {
                if (self.last_model) |m| {
                    self.allocator.free(m);
                }
                self.last_model = try self.allocator.dupe(u8, s.partial.model);
            },
            .text_delta => |delta| {
                try self.text_buffer.appendSlice(self.allocator, delta.delta);
            },
            .thinking_delta => |delta| {
                try self.thinking_buffer.appendSlice(self.allocator, delta.delta);
            },
            .toolcall_end => |tc| {
                const tool_call = ToolCall{
                    .id = try self.allocator.dupe(u8, tc.tool_call.id),
                    .name = try self.allocator.dupe(u8, tc.tool_call.name),
                    .arguments_json = try self.allocator.dupe(u8, tc.tool_call.arguments_json),
                };
                try self.tool_calls.append(self.allocator, tool_call);
            },
            else => {},
        }

        freeEvent(event, self.allocator);
    }
};

pub fn basicTextGeneration(
    allocator: std.mem.Allocator,
    stream: anytype,
    expected_min_text_length: usize,
) !void {
    var accumulator = EventAccumulator.init(allocator);
    defer accumulator.deinit();

    const deadline = createDeadline(DEFAULT_E2E_TIMEOUT_MS);
    while (true) {
        if (stream.poll()) |event| {
            try accumulator.processEvent(event);
        } else {
            if (stream.completed.load(.acquire)) {
                break;
            }
            if (isDeadlineExceeded(deadline)) {
                return error.TimeoutExceeded;
            }
            compat.time.sleepNs(10 * std.time.ns_per_ms);
        }
    }

    if (stream.err_msg != null) {
        std.debug.print("Stream error: {s}\n", .{stream.err_msg.?});
        return error.StreamError;
    }

    const result = stream.result orelse return error.NoResult;

    try std.testing.expect(accumulator.events_seen > 0);
    try std.testing.expect(accumulator.text_buffer.items.len >= expected_min_text_length);
    try std.testing.expect(result.content.len > 0);
    try std.testing.expect(result.usage.output > 0);
}

test "EventAccumulator init and deinit" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    try std.testing.expectEqual(@as(usize, 0), accumulator.events_seen);
    try std.testing.expectEqual(@as(usize, 0), accumulator.text_buffer.items.len);
}

test "EventAccumulator process start event" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const event = ai_types.AssistantMessageEvent{ .start = .{ .partial = partial } };
    try accumulator.processEvent(event);

    try std.testing.expectEqual(@as(usize, 1), accumulator.events_seen);
    try std.testing.expectEqualStrings("test-model", accumulator.last_model.?);
}

test "EventAccumulator process text delta" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const delta1 = try std.testing.allocator.dupe(u8, "Hello");
    const delta2 = try std.testing.allocator.dupe(u8, " world");

    const event1 = ai_types.AssistantMessageEvent{ .text_delta = .{ .content_index = 0, .delta = delta1, .partial = partial } };
    const event2 = ai_types.AssistantMessageEvent{ .text_delta = .{ .content_index = 0, .delta = delta2, .partial = partial } };

    try accumulator.processEvent(event1);
    try accumulator.processEvent(event2);

    try std.testing.expectEqual(@as(usize, 2), accumulator.events_seen);
    try std.testing.expectEqualStrings("Hello world", accumulator.text_buffer.items);
}

test "EventAccumulator process thinking delta" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const delta = try std.testing.allocator.dupe(u8, "reasoning...");
    const event = ai_types.AssistantMessageEvent{ .thinking_delta = .{ .content_index = 0, .delta = delta, .partial = partial } };
    try accumulator.processEvent(event);

    try std.testing.expectEqualStrings("reasoning...", accumulator.thinking_buffer.items);
}

test "EventAccumulator process tool call" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const id = try std.testing.allocator.dupe(u8, "call_1");
    const name = try std.testing.allocator.dupe(u8, "test_tool");
    const arguments_json = try std.testing.allocator.dupe(u8, "{\"arg\":\"value\"}");

    const end_event = ai_types.AssistantMessageEvent{ .toolcall_end = .{
        .content_index = 0,
        .tool_call = .{
            .id = id,
            .name = name,
            .arguments_json = arguments_json,
        },
        .partial = partial,
    } };

    try accumulator.processEvent(end_event);

    try std.testing.expectEqual(@as(usize, 1), accumulator.tool_calls.items.len);
    try std.testing.expectEqualStrings("call_1", accumulator.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("test_tool", accumulator.tool_calls.items[0].name);
    try std.testing.expectEqualStrings("{\"arg\":\"value\"}", accumulator.tool_calls.items[0].arguments_json);
}
