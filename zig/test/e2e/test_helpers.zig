const std = @import("std");
const types = @import("types");

/// Print a test start message (cyan color for visibility)
pub fn testStart(test_name: []const u8) void {
    std.debug.print("\n\x1b[36m[TEST START]\x1b[0m {s}\n", .{test_name});
}

/// Print a test success message (green color)
pub fn testSuccess(test_name: []const u8) void {
    std.debug.print("\x1b[32m[TEST PASS]\x1b[0m {s}\n", .{test_name});
}

/// Print a test step/progress message (dim color)
pub fn testStep(comptime format: []const u8, args: anytype) void {
    std.debug.print("  \x1b[2m" ++ format ++ "\x1b[0m\n", args);
}

/// Print a skip message to stderr and return SkipZigTest error if credentials are missing.
/// Returns successfully (void) if credentials exist, allowing the test to proceed.
/// This makes skipped tests clearly visible in CI output.
pub fn skipTest(allocator: std.mem.Allocator, provider_name: []const u8) error{SkipZigTest}!void {
    // Check if we should skip (i.e., no credentials available)
    const should_skip: bool = if (std.ascii.eqlIgnoreCase(provider_name, "anthropic"))
        shouldSkipAnthropic(allocator)
    else if (std.ascii.eqlIgnoreCase(provider_name, "github_copilot"))
        shouldSkipGitHubCopilot(allocator)
    else
        shouldSkipProvider(allocator, provider_name);

    // If credentials exist, don't skip - let the test proceed
    if (!should_skip) return;

    // Print a clear skip message using std.debug.print (prints to stderr)
    // Include the expected env var name for common providers
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

/// Print a skip message for Anthropic tests (unified credential check)
pub fn skipAnthropicTest(allocator: std.mem.Allocator) error{SkipZigTest}!void {
    if (!shouldSkipAnthropic(allocator)) return;
    std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for 'anthropic' - no credentials available (set ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY)\n", .{});
    return error.SkipZigTest;
}

/// Print a skip message for GitHub Copilot tests
pub fn skipGitHubCopilotTest(allocator: std.mem.Allocator) error{SkipZigTest}!void {
    if (!shouldSkipGitHubCopilot(allocator)) return;
    std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for 'github_copilot' - no credentials available (set COPILOT_TOKEN)\n", .{});
    return error.SkipZigTest;
}

/// Print a skip message for Azure tests (requires both API key and resource name)
pub fn skipAzureTest(allocator: std.mem.Allocator) error{SkipZigTest}!void {
    // Check for AZURE_OPENAI_API_KEY
    if (!shouldSkipProvider(allocator, "azure")) {
        // Has API key, check for AZURE_RESOURCE_NAME or AZURE_OPENAI_ENDPOINT
        if (std.process.getEnvVarOwned(allocator, "AZURE_OPENAI_ENDPOINT")) |_| {
            return; // Has both credentials, don't skip
        } else |_| {}
        if (std.process.getEnvVarOwned(allocator, "AZURE_RESOURCE_NAME")) |_| {
            return; // Has both credentials, don't skip
        } else |_| {}
    }
    std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for 'azure' - no credentials available (set AZURE_OPENAI_API_KEY and AZURE_OPENAI_ENDPOINT/AZURE_RESOURCE_NAME)\n", .{});
    return error.SkipZigTest;
}

/// Print a skip message for Google tests
pub fn skipGoogleTest(allocator: std.mem.Allocator) error{SkipZigTest}!void {
    if (!shouldSkipProvider(allocator, "google")) return;
    std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for 'google' - no credentials available (set GOOGLE_API_KEY)\n", .{});
    return error.SkipZigTest;
}

/// Print a skip message for Google Vertex tests
pub fn skipGoogleVertexTest(allocator: std.mem.Allocator) error{SkipZigTest}!void {
    // Check for GOOGLE_APPLICATION_CREDENTIALS
    if (!shouldSkipProvider(allocator, "google_vertex")) {
        // Has credentials, check for GOOGLE_VERTEX_PROJECT_ID
        if (std.process.getEnvVarOwned(allocator, "GOOGLE_VERTEX_PROJECT_ID")) |_| {
            return; // Has both credentials, don't skip
        } else |_| {}
    }
    std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for 'google_vertex' - no credentials available (set GOOGLE_VERTEX_PROJECT_ID and GOOGLE_APPLICATION_CREDENTIALS)\n", .{});
    return error.SkipZigTest;
}

/// Print a skip message for Bedrock tests
pub fn skipBedrockTest(allocator: std.mem.Allocator) error{SkipZigTest}!void {
    if (std.process.getEnvVarOwned(allocator, "AWS_ACCESS_KEY_ID")) |_| {
        return; // Has credentials, don't skip
    } else |_| {}
    std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for 'bedrock' - no credentials available (set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION)\n", .{});
    return error.SkipZigTest;
}

/// Print a skip message for Ollama tests
pub fn skipOllamaTest(allocator: std.mem.Allocator) error{SkipZigTest}!void {
    // Ollama doesn't require credentials, check if server is running
    // by attempting to connect to the default Ollama endpoint
    _ = allocator;
    const OllamaChecker = struct {
        fn isServerRunning() bool {
            // Try to connect to Ollama's default endpoint
            const socket = std.posix.socket(
                std.posix.AF.INET,
                std.posix.SOCK.STREAM,
                0
            ) catch return false;
            defer std.posix.close(socket);

            const addr = std.net.Address.parseIp("127.0.0.1", 11434) catch return false;
            std.posix.connect(socket, &addr.any, addr.getOsSockLen()) catch return false;
            return true;
        }
    };

    if (OllamaChecker.isServerRunning()) return;
    std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for 'ollama' - Ollama server not available (start with: ollama serve)\n", .{});
    return error.SkipZigTest;
}

/// Print a skip message for Anthropic OAuth tests
pub fn skipAnthropicOAuthTest(allocator: std.mem.Allocator) error{SkipZigTest}!void {
    if (!shouldSkipAnthropicOAuth(allocator)) return;
    std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: E2E test for 'anthropic_oauth' - no OAuth credentials available (set ANTHROPIC_AUTH_TOKEN)\n", .{});
    return error.SkipZigTest;
}

/// Unified Anthropic credential type
/// OAuth token (from ANTHROPIC_AUTH_TOKEN) is preferred over API key (from ANTHROPIC_API_KEY)
pub const AnthropicCredential = struct {
    token: []const u8,
    is_oauth: bool,

    pub fn deinit(self: *AnthropicCredential, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
    }
};

/// Get the best available Anthropic credential with precedence:
/// 1. ANTHROPIC_AUTH_TOKEN (OAuth token)
/// 2. ANTHROPIC_API_KEY (API key)
/// 3. ~/.makai/auth.json (fallback)
pub fn getAnthropicCredential(allocator: std.mem.Allocator) !?AnthropicCredential {
    // 1. Try ANTHROPIC_AUTH_TOKEN first (OAuth token)
    if (std.process.getEnvVarOwned(allocator, "ANTHROPIC_AUTH_TOKEN")) |token| {
        // OAuth token format: "refresh_token:access_token" or just "access_token"
        if (std.mem.indexOfScalar(u8, token, ':')) |colon_pos| {
            const access_token = try allocator.dupe(u8, token[colon_pos + 1 ..]);
            allocator.free(token);
            return AnthropicCredential{
                .token = access_token,
                .is_oauth = true,
            };
        } else {
            // Single token format - use as OAuth token
            return AnthropicCredential{
                .token = token,
                .is_oauth = true,
            };
        }
    } else |_| {}

    // 2. Try ANTHROPIC_API_KEY
    if (std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY")) |key| {
        return AnthropicCredential{
            .token = key,
            .is_oauth = false,
        };
    } else |_| {}

    // 3. Fall back to auth.json
    return getAnthropicCredentialFromAuthFile(allocator);
}

/// Read Anthropic credential from ~/.makai/auth.json
/// Checks for oauth_token first, then api_key
fn getAnthropicCredentialFromAuthFile(allocator: std.mem.Allocator) !?AnthropicCredential {
    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home_dir);

    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".makai", "auth.json" });
    defer allocator.free(auth_path);

    const file = std.fs.openFileAbsolute(auth_path, .{}) catch return null;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const providers = root.object.get("providers") orelse return null;
    if (providers != .object) return null;

    const provider_obj = providers.object.get("anthropic") orelse return null;
    if (provider_obj != .object) return null;

    // Check for oauth_token first (higher precedence)
    if (provider_obj.object.get("oauth_token")) |oauth_val| {
        if (oauth_val == .string) {
            return AnthropicCredential{
                .token = try allocator.dupe(u8, oauth_val.string),
                .is_oauth = true,
            };
        }
    }

    // Fall back to api_key
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

/// Check if Anthropic provider should be skipped (no credentials)
/// Uses the unified credential precedence
pub fn shouldSkipAnthropic(allocator: std.mem.Allocator) bool {
    const cred = getAnthropicCredential(allocator) catch return true;
    if (cred) |c| {
        var mutable_cred = c;
        mutable_cred.deinit(allocator);
        return false;
    }
    return true;
}

/// Get API key from environment variable or ~/.makai/auth.json
pub fn getApiKey(allocator: std.mem.Allocator, provider_name: []const u8) !?[]const u8 {
    // Construct environment variable name (e.g., ANTHROPIC_API_KEY)
    var env_var_name: std.ArrayList(u8) = .{};
    defer env_var_name.deinit(allocator);

    try env_var_name.appendSlice(allocator, provider_name);
    try env_var_name.appendSlice(allocator, "_API_KEY");

    // Convert to uppercase
    for (env_var_name.items) |*c| {
        c.* = std.ascii.toUpper(c.*);
    }

    // Try environment variable first
    if (std.process.getEnvVarOwned(allocator, env_var_name.items)) |key| {
        return key;
    } else |_| {
        // Fall back to auth.json
        return getApiKeyFromAuthFile(allocator, provider_name);
    }
}

/// Read API key from ~/.makai/auth.json
fn getApiKeyFromAuthFile(allocator: std.mem.Allocator, provider_name: []const u8) !?[]const u8 {
    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home_dir);

    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".makai", "auth.json" });
    defer allocator.free(auth_path);

    const file = std.fs.openFileAbsolute(auth_path, .{}) catch return null;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
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

/// Check if a provider should be skipped (no credentials)
/// For Anthropic, uses unified credential precedence (OAuth token > API key)
pub fn shouldSkipProvider(allocator: std.mem.Allocator, provider_name: []const u8) bool {
    // Special handling for Anthropic - check for OAuth token first
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

/// GitHub Copilot credentials (requires both copilot_token and github_token)
pub const GitHubCopilotCredentials = struct {
    copilot_token: []const u8,
    github_token: []const u8,

    pub fn deinit(self: *GitHubCopilotCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.copilot_token);
        allocator.free(self.github_token);
    }
};

/// Get GitHub Copilot credentials from environment variable or ~/.makai/auth.json
pub fn getGitHubCopilotCredentials(allocator: std.mem.Allocator) !?GitHubCopilotCredentials {
    // Try environment variable first (COPILOT_TOKEN for CI)
    if (std.process.getEnvVarOwned(allocator, "COPILOT_TOKEN")) |token| {
        // Check for combined format: "github_token:copilot_token"
        // Split on the first colon - copilot_token may contain colons (semicolons in the token)
        if (std.mem.indexOfScalar(u8, token, ':')) |colon_pos| {
            const github_token = token[0..colon_pos];
            const copilot_token = token[colon_pos + 1 ..];
            const result = GitHubCopilotCredentials{
                .copilot_token = try allocator.dupe(u8, copilot_token),
                .github_token = try allocator.dupe(u8, github_token),
            };
            allocator.free(token);
            return result;
        } else {
            // Single token format - use as both
            // In this case, we pass ownership of token to copilot_token
            // and dupe for github_token
            return GitHubCopilotCredentials{
                .copilot_token = token,
                .github_token = try allocator.dupe(u8, token),
            };
        }
    } else |_| {
        // Fall back to auth.json
        return getGitHubCopilotCredentialsFromAuthFile(allocator);
    }
}

/// Read GitHub Copilot credentials from ~/.makai/auth.json
fn getGitHubCopilotCredentialsFromAuthFile(allocator: std.mem.Allocator) !?GitHubCopilotCredentials {
    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home_dir);

    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".makai", "auth.json" });
    defer allocator.free(auth_path);

    const file = std.fs.openFileAbsolute(auth_path, .{}) catch return null;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const providers = root.object.get("providers") orelse return null;
    if (providers != .object) return null;

    const provider_val = providers.object.get("github_copilot") orelse return null;

    // Support combined format: if the value is a string, parse as "github_token:copilot_token"
    if (provider_val == .string) {
        const combined = provider_val.string;
        // Split on the first colon - copilot_token may contain colons
        if (std.mem.indexOfScalar(u8, combined, ':')) |colon_pos| {
            const github_token = combined[0..colon_pos];
            const copilot_token = combined[colon_pos + 1 ..];
            return GitHubCopilotCredentials{
                .copilot_token = try allocator.dupe(u8, copilot_token),
                .github_token = try allocator.dupe(u8, github_token),
            };
        }
        return null;
    }

    // Traditional format: object with separate copilot_token and github_token fields
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

/// Check if GitHub Copilot provider should be skipped (no credentials)
pub fn shouldSkipGitHubCopilot(allocator: std.mem.Allocator) bool {
    const creds = getGitHubCopilotCredentials(allocator) catch return true;
    if (creds) |c| {
        var mutable_creds = c;
        mutable_creds.deinit(allocator);
        return false;
    }
    return true;
}

/// Anthropic OAuth credentials (refresh_token:access_token format)
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

/// Get Anthropic OAuth credentials from environment variable or ~/.makai/auth.json
pub fn getAnthropicOAuthCredentials(allocator: std.mem.Allocator) !?AnthropicOAuthCredentials {
    // Try environment variable first (ANTHROPIC_AUTH_TOKEN for OAuth)
    // Format: "refresh_token:access_token"
    if (std.process.getEnvVarOwned(allocator, "ANTHROPIC_AUTH_TOKEN")) |token| {
        // Split on the first colon
        if (std.mem.indexOfScalar(u8, token, ':')) |colon_pos| {
            const refresh_token = token[0..colon_pos];
            const access_token = token[colon_pos + 1 ..];
            const result = AnthropicOAuthCredentials{
                .refresh_token = try allocator.dupe(u8, refresh_token),
                .access_token = try allocator.dupe(u8, access_token),
            };
            allocator.free(token);
            return result;
        } else {
            // Single token format - use as access token only (no refresh token)
            // This is for backwards compatibility
            const result = AnthropicOAuthCredentials{
                .refresh_token = &[_]u8{},
                .access_token = token,
            };
            return result;
        }
    } else |_| {
        // Fall back to auth.json
        return getAnthropicOAuthCredentialsFromAuthFile(allocator);
    }
}

/// Read Anthropic OAuth credentials from ~/.makai/auth.json
fn getAnthropicOAuthCredentialsFromAuthFile(allocator: std.mem.Allocator) !?AnthropicOAuthCredentials {
    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home_dir);

    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".makai", "auth.json" });
    defer allocator.free(auth_path);

    const file = std.fs.openFileAbsolute(auth_path, .{}) catch return null;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const providers = root.object.get("providers") orelse return null;
    if (providers != .object) return null;

    const provider_val = providers.object.get("anthropic") orelse return null;

    // Support combined format: if the value is a string, parse as "refresh_token:access_token"
    if (provider_val == .string) {
        const combined = provider_val.string;
        if (std.mem.indexOfScalar(u8, combined, ':')) |colon_pos| {
            const refresh_token = combined[0..colon_pos];
            const access_token = combined[colon_pos + 1 ..];
            return AnthropicOAuthCredentials{
                .refresh_token = try allocator.dupe(u8, refresh_token),
                .access_token = try allocator.dupe(u8, access_token),
            };
        }
        return null;
    }

    // Traditional format: object with oauth_token field containing access token
    if (provider_val != .object) return null;

    const oauth_token_val = provider_val.object.get("oauth_token") orelse return null;
    if (oauth_token_val != .string) return null;

    // Optional refresh token
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

/// Check if Anthropic OAuth provider should be skipped (no credentials)
pub fn shouldSkipAnthropicOAuth(allocator: std.mem.Allocator) bool {
    const creds = getAnthropicOAuthCredentials(allocator) catch return true;
    if (creds) |c| {
        var mutable_creds = c;
        mutable_creds.deinit(allocator);
        return false;
    }
    return true;
}

/// Anthropic OAuth credentials with fresh access token
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

/// Get Anthropic OAuth credentials with a fresh access token
/// Uses the refresh token to obtain a fresh access token before running tests
pub fn getFreshAnthropicOAuthCredentials(allocator: std.mem.Allocator) !?FreshAnthropicCredentials {
    const oauth_anthropic = @import("oauth/anthropic");

    const creds = (try getAnthropicOAuthCredentials(allocator)) orelse return null;
    var mutable_creds = creds;
    defer mutable_creds.deinit(allocator);

    // If we have a refresh token, use it to get a fresh access token
    if (creds.refresh_token.len > 0) {
        const fresh_creds = try oauth_anthropic.refreshToken(.{
            .refresh = creds.refresh_token,
            .access = creds.access_token,
            .expires = 0, // Will be set by refresh
        }, allocator);

        return FreshAnthropicCredentials{
            .access_token = fresh_creds.access,
            .refresh_token = fresh_creds.refresh,
        };
    }

    // No refresh token available, use the existing access token
    return FreshAnthropicCredentials{
        .access_token = try allocator.dupe(u8, creds.access_token),
        .refresh_token = try allocator.dupe(u8, creds.refresh_token),
    };
}

/// GitHub Copilot credentials with fresh Copilot token
pub const FreshGitHubCopilotCredentials = struct {
    copilot_token: []const u8,
    github_token: []const u8,

    pub fn deinit(self: *FreshGitHubCopilotCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.copilot_token);
        allocator.free(self.github_token);
    }
};

/// Get GitHub Copilot credentials with a fresh Copilot token
/// Uses the GitHub token (refresh token) to obtain a fresh Copilot token before running tests
pub fn getFreshGitHubCopilotCredentials(allocator: std.mem.Allocator) !?FreshGitHubCopilotCredentials {
    const oauth_github_copilot = @import("oauth/github_copilot");

    const creds = (try getGitHubCopilotCredentials(allocator)) orelse return null;
    var mutable_creds = creds;
    defer mutable_creds.deinit(allocator);

    // Use GitHub token to get a fresh Copilot token
    const fresh_creds = try oauth_github_copilot.refreshToken(.{
        .refresh = creds.github_token, // GitHub access token (long-lived)
        .access = creds.copilot_token, // Copilot token (may be expired)
        .expires = 0, // Will be set by refresh
    }, allocator);
    defer {
        allocator.free(fresh_creds.refresh);
        allocator.free(fresh_creds.access);
        if (fresh_creds.provider_data) |pd| allocator.free(pd);
        if (fresh_creds.enabled_models) |models| {
            for (models) |m| allocator.free(m);
            allocator.free(models);
        }
        if (fresh_creds.base_url) |url| allocator.free(url);
    }

    return FreshGitHubCopilotCredentials{
        .copilot_token = try allocator.dupe(u8, fresh_creds.access),
        .github_token = try allocator.dupe(u8, fresh_creds.refresh),
    };
}

/// Free allocated strings in a MessageEvent
pub fn freeEvent(event: types.MessageEvent, allocator: std.mem.Allocator) void {
    switch (event) {
        .start => |s| allocator.free(s.model),
        .text_delta => |d| allocator.free(d.delta),
        .thinking_delta => |d| allocator.free(d.delta),
        .toolcall_start => |tc| {
            allocator.free(tc.id);
            allocator.free(tc.name);
        },
        .toolcall_delta => |d| allocator.free(d.delta),
        .toolcall_end => |e| allocator.free(e.input_json),
        .@"error" => |e| allocator.free(e.message),
        else => {},
    }
}

/// Event accumulator for tracking streaming events
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
        input_json: []const u8,
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
            self.allocator.free(tc.input_json);
        }
        self.tool_calls.deinit(self.allocator);
        if (self.last_model) |m| {
            self.allocator.free(m);
        }
    }

    pub fn processEvent(self: *EventAccumulator, event: types.MessageEvent) !void {
        self.events_seen += 1;

        switch (event) {
            .start => |s| {
                if (self.last_model) |m| {
                    self.allocator.free(m);
                }
                self.last_model = try self.allocator.dupe(u8, s.model);
            },
            .text_delta => |delta| {
                try self.text_buffer.appendSlice(self.allocator, delta.delta);
            },
            .thinking_delta => |delta| {
                try self.thinking_buffer.appendSlice(self.allocator, delta.delta);
            },
            .toolcall_start => |tc| {
                const tool_call = ToolCall{
                    .id = try self.allocator.dupe(u8, tc.id),
                    .name = try self.allocator.dupe(u8, tc.name),
                    .input_json = &[_]u8{},
                };
                try self.tool_calls.append(self.allocator, tool_call);
            },
            .toolcall_end => |tc| {
                if (self.tool_calls.items.len > 0) {
                    const last_idx = self.tool_calls.items.len - 1;
                    self.allocator.free(self.tool_calls.items[last_idx].input_json);
                    self.tool_calls.items[last_idx].input_json = try self.allocator.dupe(u8, tc.input_json);
                }
            },
            else => {},
        }

        // Free the event's allocated strings after processing
        freeEvent(event, self.allocator);
    }
};

/// Basic text generation test helper
pub fn basicTextGeneration(
    allocator: std.mem.Allocator,
    stream: anytype,
    expected_min_text_length: usize,
) !void {
    var accumulator = EventAccumulator.init(allocator);
    defer accumulator.deinit();

    // Poll events
    while (true) {
        if (stream.poll()) |event| {
            try accumulator.processEvent(event);
        } else {
            if (stream.completed.load(.acquire)) {
                break;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Check for error
    if (stream.err_msg != null) {
        std.debug.print("Stream error: {s}\n", .{stream.err_msg.?});
        return error.StreamError;
    }

    // Validate result
    const result = stream.result orelse return error.NoResult;

    try std.testing.expect(accumulator.events_seen > 0);
    try std.testing.expect(accumulator.text_buffer.items.len >= expected_min_text_length);
    try std.testing.expect(result.content.len > 0);
    try std.testing.expect(result.usage.output_tokens > 0);
}

// Unit tests
test "EventAccumulator init and deinit" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    try std.testing.expectEqual(@as(usize, 0), accumulator.events_seen);
    try std.testing.expectEqual(@as(usize, 0), accumulator.text_buffer.items.len);
}

test "EventAccumulator process start event" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    // Events MUST have heap-allocated strings because processEvent() calls freeEvent()
    const model_str = try std.testing.allocator.dupe(u8, "test-model");
    const event = types.MessageEvent{ .start = .{ .model = model_str } };
    try accumulator.processEvent(event);

    try std.testing.expectEqual(@as(usize, 1), accumulator.events_seen);
    try std.testing.expectEqualStrings("test-model", accumulator.last_model.?);
}

test "EventAccumulator process text delta" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    // Events MUST have heap-allocated strings because processEvent() calls freeEvent()
    const delta1 = try std.testing.allocator.dupe(u8, "Hello");
    const delta2 = try std.testing.allocator.dupe(u8, " world");

    const event1 = types.MessageEvent{ .text_delta = .{ .index = 0, .delta = delta1 } };
    const event2 = types.MessageEvent{ .text_delta = .{ .index = 0, .delta = delta2 } };

    try accumulator.processEvent(event1);
    try accumulator.processEvent(event2);

    try std.testing.expectEqual(@as(usize, 2), accumulator.events_seen);
    try std.testing.expectEqualStrings("Hello world", accumulator.text_buffer.items);
}

test "EventAccumulator process thinking delta" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    // Events MUST have heap-allocated strings because processEvent() calls freeEvent()
    const delta = try std.testing.allocator.dupe(u8, "reasoning...");
    const event = types.MessageEvent{ .thinking_delta = .{ .index = 0, .delta = delta } };
    try accumulator.processEvent(event);

    try std.testing.expectEqualStrings("reasoning...", accumulator.thinking_buffer.items);
}

test "EventAccumulator process tool call" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    // Events MUST have heap-allocated strings because processEvent() calls freeEvent()
    const id = try std.testing.allocator.dupe(u8, "call_1");
    const name = try std.testing.allocator.dupe(u8, "test_tool");
    const input_json = try std.testing.allocator.dupe(u8, "{\"arg\":\"value\"}");

    const start_event = types.MessageEvent{ .toolcall_start = .{ .index = 0, .id = id, .name = name } };
    const end_event = types.MessageEvent{ .toolcall_end = .{ .index = 0, .input_json = input_json } };

    try accumulator.processEvent(start_event);
    try accumulator.processEvent(end_event);

    try std.testing.expectEqual(@as(usize, 1), accumulator.tool_calls.items.len);
    try std.testing.expectEqualStrings("call_1", accumulator.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("test_tool", accumulator.tool_calls.items[0].name);
    try std.testing.expectEqualStrings("{\"arg\":\"value\"}", accumulator.tool_calls.items[0].input_json);
}
