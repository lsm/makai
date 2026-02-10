const std = @import("std");
const anthropic_mod = @import("oauth/anthropic");
const github_copilot_mod = @import("oauth/github_copilot");
const google_mod = @import("oauth/google");

pub const pkce = @import("oauth/pkce");
pub const callback_server = @import("oauth/callback_server");
pub const storage = @import("oauth/storage");

/// OAuth credentials with refresh token, access token, and expiry
pub const Credentials = struct {
    refresh: []const u8,
    access: []const u8,
    expires: i64, // Unix timestamp (ms)
    provider_data: ?[]const u8 = null, // JSON blob for provider-specific fields

    pub fn deinit(self: *const Credentials, allocator: std.mem.Allocator) void {
        allocator.free(self.refresh);
        allocator.free(self.access);
        if (self.provider_data) |data| {
            allocator.free(data);
        }
    }
};

/// OAuth callback functions for user interaction
pub const Callbacks = struct {
    onAuth: *const fn (info: AuthInfo) void,
    onPrompt: *const fn (prompt: Prompt) []const u8,
    onProgress: ?*const fn (message: []const u8) void = null,
    onManualCodeInput: ?*const fn () []const u8 = null,
};

/// Authentication info shown to user
pub const AuthInfo = struct {
    url: []const u8,
    instructions: ?[]const u8 = null,
};

/// User prompt configuration
pub const Prompt = struct {
    message: []const u8,
    placeholder: ?[]const u8 = null,
    allow_empty: bool = false,
};

/// OAuth provider interface
pub const OAuthProvider = struct {
    id: []const u8,
    name: []const u8,
    login_fn: *const fn (callbacks: Callbacks, allocator: std.mem.Allocator) anyerror!Credentials,
    refresh_fn: *const fn (credentials: Credentials, allocator: std.mem.Allocator) anyerror!Credentials,
    get_api_key_fn: *const fn (credentials: Credentials, allocator: std.mem.Allocator) anyerror![]const u8,
};

// Adapter functions for Anthropic
fn anthropicLogin(callbacks: Callbacks, allocator: std.mem.Allocator) anyerror!Credentials {
    const anthro_callbacks = anthropic_mod.Callbacks{
        .onAuth = @ptrCast(callbacks.onAuth),
        .onPrompt = @ptrCast(callbacks.onPrompt),
    };
    const creds = try anthropic_mod.login(anthro_callbacks, allocator);
    return Credentials{
        .refresh = creds.refresh,
        .access = creds.access,
        .expires = creds.expires,
    };
}

fn anthropicRefresh(credentials: Credentials, allocator: std.mem.Allocator) anyerror!Credentials {
    const anthro_creds = anthropic_mod.Credentials{
        .refresh = credentials.refresh,
        .access = credentials.access,
        .expires = credentials.expires,
    };
    const creds = try anthropic_mod.refreshToken(anthro_creds, allocator);
    return Credentials{
        .refresh = creds.refresh,
        .access = creds.access,
        .expires = creds.expires,
    };
}

fn anthropicGetApiKey(credentials: Credentials, allocator: std.mem.Allocator) anyerror![]const u8 {
    const anthro_creds = anthropic_mod.Credentials{
        .refresh = credentials.refresh,
        .access = credentials.access,
        .expires = credentials.expires,
    };
    return try anthropic_mod.getApiKey(anthro_creds, allocator);
}

// Adapter functions for GitHub Copilot
fn githubCopilotLogin(callbacks: Callbacks, allocator: std.mem.Allocator) anyerror!Credentials {
    const gh_callbacks = github_copilot_mod.Callbacks{
        .onAuth = @ptrCast(callbacks.onAuth),
        .onPrompt = @ptrCast(callbacks.onPrompt),
    };
    const creds = try github_copilot_mod.login(gh_callbacks, allocator);
    return Credentials{
        .refresh = creds.refresh,
        .access = creds.access,
        .expires = creds.expires,
        .provider_data = creds.provider_data,
    };
}

fn githubCopilotRefresh(credentials: Credentials, allocator: std.mem.Allocator) anyerror!Credentials {
    const gh_creds = github_copilot_mod.Credentials{
        .refresh = credentials.refresh,
        .access = credentials.access,
        .expires = credentials.expires,
        .provider_data = credentials.provider_data,
    };
    const creds = try github_copilot_mod.refreshToken(gh_creds, allocator);
    return Credentials{
        .refresh = creds.refresh,
        .access = creds.access,
        .expires = creds.expires,
        .provider_data = creds.provider_data,
    };
}

fn githubCopilotGetApiKey(credentials: Credentials, allocator: std.mem.Allocator) anyerror![]const u8 {
    const gh_creds = github_copilot_mod.Credentials{
        .refresh = credentials.refresh,
        .access = credentials.access,
        .expires = credentials.expires,
        .provider_data = credentials.provider_data,
    };
    return try github_copilot_mod.getApiKey(gh_creds, allocator);
}

// Adapter functions for Google
fn googleLogin(callbacks: Callbacks, allocator: std.mem.Allocator) anyerror!Credentials {
    const g_callbacks = google_mod.Callbacks{
        .onAuth = @ptrCast(callbacks.onAuth),
        .onPrompt = @ptrCast(callbacks.onPrompt),
        .onManualCodeInput = if (callbacks.onManualCodeInput) |f| @as(?*const fn () []const u8, @ptrCast(f)) else null,
    };
    const creds = try google_mod.loginGeminiCLI(g_callbacks, allocator);
    return Credentials{
        .refresh = creds.refresh,
        .access = creds.access,
        .expires = creds.expires,
        .provider_data = creds.provider_data,
    };
}

fn googleRefresh(credentials: Credentials, allocator: std.mem.Allocator) anyerror!Credentials {
    const g_creds = google_mod.Credentials{
        .refresh = credentials.refresh,
        .access = credentials.access,
        .expires = credentials.expires,
        .provider_data = credentials.provider_data,
    };
    const creds = try google_mod.refreshToken(g_creds, allocator);
    return Credentials{
        .refresh = creds.refresh,
        .access = creds.access,
        .expires = creds.expires,
        .provider_data = creds.provider_data,
    };
}

fn googleGetApiKey(credentials: Credentials, allocator: std.mem.Allocator) anyerror![]const u8 {
    const g_creds = google_mod.Credentials{
        .refresh = credentials.refresh,
        .access = credentials.access,
        .expires = credentials.expires,
        .provider_data = credentials.provider_data,
    };
    return try google_mod.getApiKey(g_creds, allocator);
}

const anthropic_provider = OAuthProvider{
    .id = "anthropic",
    .name = "Anthropic",
    .login_fn = anthropicLogin,
    .refresh_fn = anthropicRefresh,
    .get_api_key_fn = anthropicGetApiKey,
};

const github_copilot_provider = OAuthProvider{
    .id = "github-copilot",
    .name = "GitHub Copilot",
    .login_fn = githubCopilotLogin,
    .refresh_fn = githubCopilotRefresh,
    .get_api_key_fn = githubCopilotGetApiKey,
};

const google_gemini_provider = OAuthProvider{
    .id = "google-gemini-cli",
    .name = "Google Gemini CLI",
    .login_fn = googleLogin,
    .refresh_fn = googleRefresh,
    .get_api_key_fn = googleGetApiKey,
};

/// Registry of OAuth providers
pub const registry = std.StaticStringMap(OAuthProvider).initComptime(.{
    .{ "anthropic", anthropic_provider },
    .{ "github-copilot", github_copilot_provider },
    .{ "google-gemini-cli", google_gemini_provider },
});

/// Get OAuth provider by ID
pub fn getProvider(id: []const u8) ?OAuthProvider {
    return registry.get(id);
}

test "getProvider - returns provider for valid ID" {
    const provider = getProvider("anthropic");
    try std.testing.expect(provider != null);
    try std.testing.expectEqualStrings("Anthropic", provider.?.name);
}

test "getProvider - returns null for invalid ID" {
    const provider = getProvider("invalid");
    try std.testing.expect(provider == null);
}

test "registry - contains all providers" {
    try std.testing.expect(registry.has("anthropic"));
    try std.testing.expect(registry.has("github-copilot"));
    try std.testing.expect(registry.has("google-gemini-cli"));
    try std.testing.expectEqual(@as(usize, 3), registry.kvs.len);
}
