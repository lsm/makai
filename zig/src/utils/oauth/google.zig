const std = @import("std");
const pkce_mod = @import("oauth/pkce");
const callback_server = @import("oauth/callback_server");

const client_id_gemini = "534761656150-8dc8f1ih2f0bjpvpu7he6tq0lqr6jq2r.apps.googleusercontent.com";
const auth_url_base = "https://accounts.google.com/o/oauth2/v2/auth";
const token_url = "https://oauth2.googleapis.com/token";
const scopes = "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile";

pub const Credentials = struct {
    refresh: []const u8,
    access: []const u8,
    expires: i64,
    provider_data: ?[]const u8 = null,
};

pub const Callbacks = struct {
    onAuth: *const fn (info: AuthInfo) void,
    onPrompt: *const fn (prompt: Prompt) []const u8,
    onManualCodeInput: ?*const fn () []const u8 = null,
};

pub const AuthInfo = struct {
    url: []const u8,
    instructions: ?[]const u8 = null,
};

pub const Prompt = struct {
    message: []const u8,
    allow_empty: bool = false,
};

/// Google OAuth login for Gemini CLI (callback server + project discovery)
pub fn loginGeminiCLI(callbacks: Callbacks, allocator: std.mem.Allocator) !Credentials {
    return try login(callbacks, allocator, 8085, client_id_gemini);
}

/// Google OAuth login (shared for Gemini CLI and Vertex)
pub fn login(callbacks: Callbacks, allocator: std.mem.Allocator, port: u16, client_id: []const u8) !Credentials {
    // 1. Start local callback server
    var server = try callback_server.CallbackServer.start(allocator, port);
    defer server.stop();

    // 2. Generate PKCE
    const pkce = try pkce_mod.generate(allocator);
    defer pkce.deinit(allocator);

    // 3. Build authorization URL
    const redirect_uri = try std.fmt.allocPrint(allocator, "http://localhost:{d}/auth/callback", .{port});
    defer allocator.free(redirect_uri);

    const auth_url = try std.fmt.allocPrint(allocator,
        "{s}?client_id={s}&redirect_uri={s}&response_type=code&scope={s}&access_type=offline&code_challenge={s}&code_challenge_method=S256&state={s}",
        .{ auth_url_base, client_id, redirect_uri, scopes, pkce.challenge, pkce.verifier },
    );
    defer allocator.free(auth_url);

    callbacks.onAuth(.{ .url = auth_url });

    // 4. Wait for callback or manual input
    const code = if (callbacks.onManualCodeInput) |manual_fn| blk: {
        // Try callback first with short timeout
        const callback_result = try server.waitForCode(30_000); // 30s
        if (callback_result) |c| break :blk c;

        // Fallback to manual input
        const manual_result = manual_fn();
        break :blk try parseCodeFromUrl(allocator, manual_result);
    } else blk: {
        break :blk try server.waitForCode(300_000) orelse return error.NoCodeReceived; // 5min
    };
    defer allocator.free(code);

    // 5. Exchange code for tokens
    const token_response = try exchangeCode(code, pkce.verifier, redirect_uri, client_id, allocator);
    defer allocator.free(token_response.refresh_token);
    defer allocator.free(token_response.access_token);

    // 6. Discover/provision Cloud Code Assist project
    const project_id = try discoverProject(token_response.access_token, allocator);
    defer allocator.free(project_id);

    // 7. Get user email
    const email = try getUserEmail(token_response.access_token, allocator);
    defer allocator.free(email);

    // 8. Build provider data JSON
    const provider_data = try std.fmt.allocPrint(allocator,
        "{{\"projectId\":\"{s}\",\"email\":\"{s}\"}}",
        .{ project_id, email },
    );

    const expires = std.time.milliTimestamp() + (token_response.expires_in * 1000) - (5 * 60 * 1000);

    return .{
        .refresh = try allocator.dupe(u8, token_response.refresh_token),
        .access = try allocator.dupe(u8, token_response.access_token),
        .expires = expires,
        .provider_data = provider_data,
    };
}

/// Refresh Google OAuth token
pub fn refreshToken(credentials: Credentials, allocator: std.mem.Allocator) !Credentials {
    const body = try std.fmt.allocPrint(allocator,
        "grant_type=refresh_token&refresh_token={s}&client_id={s}",
        .{ credentials.refresh, client_id_gemini },
    );
    defer allocator.free(body);

    const token_response = try exchangeTokens(body, allocator);
    defer allocator.free(token_response.refresh_token);
    defer allocator.free(token_response.access_token);

    const expires = std.time.milliTimestamp() + (token_response.expires_in * 1000) - (5 * 60 * 1000);

    return .{
        .refresh = try allocator.dupe(u8, token_response.refresh_token),
        .access = try allocator.dupe(u8, token_response.access_token),
        .expires = expires,
        .provider_data = if (credentials.provider_data) |data| try allocator.dupe(u8, data) else null,
    };
}

/// Get API key from credentials (access token IS the API key)
pub fn getApiKey(credentials: Credentials, allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(u8, credentials.access);
}

/// Parse code from URL
fn parseCodeFromUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, url, "code=")) |idx| {
        const code_start = idx + 5;
        const code_end = std.mem.indexOfAny(u8, url[code_start..], "&# ") orelse url.len - code_start;
        return try allocator.dupe(u8, url[code_start .. code_start + code_end]);
    }
    return error.NoCodeInUrl;
}

const TokenResponse = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    expires_in: i64,
};

/// Exchange authorization code for tokens
fn exchangeCode(code: []const u8, verifier: []const u8, redirect_uri: []const u8, client_id: []const u8, allocator: std.mem.Allocator) !TokenResponse {
    const body = try std.fmt.allocPrint(allocator,
        "grant_type=authorization_code&code={s}&redirect_uri={s}&code_verifier={s}&client_id={s}",
        .{ code, redirect_uri, verifier, client_id },
    );
    defer allocator.free(body);

    return try exchangeTokens(body, allocator);
}

/// Exchange tokens with Google API (mock implementation for testing)
fn exchangeTokens(body: []const u8, allocator: std.mem.Allocator) !TokenResponse {
    _ = body;
    return .{
        .access_token = try allocator.dupe(u8, "mock_access_token"),
        .refresh_token = try allocator.dupe(u8, "mock_refresh_token"),
        .expires_in = 3600,
    };
}

/// Discover or provision Google Cloud Code Assist project
fn discoverProject(access_token: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    _ = access_token;
    // Real implementation would make HTTP requests to Cloud Code Assist API
    return try allocator.dupe(u8, "mock_project_id");
}

/// Get user email from Google API
fn getUserEmail(access_token: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    _ = access_token;
    // Real implementation would make HTTP GET to userinfo API
    return try allocator.dupe(u8, "user@example.com");
}

test "parseCodeFromUrl - query parameter" {
    const url = "http://localhost:8085/auth/callback?code=abc123&state=xyz";
    const code = try parseCodeFromUrl(std.testing.allocator, url);
    defer std.testing.allocator.free(code);

    try std.testing.expectEqualStrings("abc123", code);
}

test "parseCodeFromUrl - no code" {
    const url = "http://localhost:8085/auth/callback?error=access_denied";
    const result = parseCodeFromUrl(std.testing.allocator, url);

    try std.testing.expectError(error.NoCodeInUrl, result);
}

test "getApiKey - returns access token" {
    const credentials = Credentials{
        .refresh = "refresh_token",
        .access = "access_token",
        .expires = std.time.milliTimestamp() + 3600000,
        .provider_data = "{\"projectId\":\"test\",\"email\":\"test@example.com\"}",
    };

    const api_key = try getApiKey(credentials, std.testing.allocator);
    defer std.testing.allocator.free(api_key);

    try std.testing.expectEqualStrings("access_token", api_key);
}
