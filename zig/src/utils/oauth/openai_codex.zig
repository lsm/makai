//! OpenAI Codex OAuth (Authorization Code flow with PKCE, manual paste UX).
//!
//! Mirrors the callback shape of `oauth/anthropic.zig` so the TUI login bridge
//! can drive all providers uniformly: the flow shows an authorization URL via
//! `onAuth`, blocks on `onPrompt` for the pasted redirect URL/code, then
//! exchanges the code for tokens.

const std = @import("std");
const compat = @import("compat");
const http = compat.http;
const pkce_mod = @import("oauth/pkce");

const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const redirect_uri = "http://localhost:1455/auth/callback";
const scopes = "openid%20profile%20email%20offline_access";
const auth_url_base = "https://auth.openai.com/oauth/authorize";
const token_url = "https://auth.openai.com/oauth/token";

pub const Credentials = struct {
    refresh: []const u8,
    access: []const u8,
    expires: i64,
};

pub const Callbacks = struct {
    onAuth: *const fn (info: AuthInfo) void,
    onPrompt: *const fn (prompt: Prompt) []const u8,
};

pub const AuthInfo = struct {
    url: []const u8,
    instructions: ?[]const u8 = null,
};

pub const Prompt = struct {
    message: []const u8,
    allow_empty: bool = false,
};

fn buildAuthUrl(allocator: std.mem.Allocator, challenge: []const u8, state: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        "{s}?client_id={s}&redirect_uri={s}&response_type=code&scope={s}&code_challenge={s}&code_challenge_method=S256&state={s}&audience=https://api.openai.com/v1",
        .{ auth_url_base, client_id, redirect_uri, scopes, challenge, state },
    );
}

/// OpenAI Codex OAuth login (manual code flow with PKCE).
pub fn login(callbacks: Callbacks, allocator: std.mem.Allocator) !Credentials {
    const pkce = try pkce_mod.generate(allocator);
    defer pkce.deinit(allocator);

    const auth_url = try buildAuthUrl(allocator, pkce.challenge, pkce.verifier);
    defer allocator.free(auth_url);

    callbacks.onAuth(.{
        .url = auth_url,
        .instructions = "Authorize, then paste the full redirect URL (or just the code) below:",
    });

    const manual_input = callbacks.onPrompt(.{ .message = "Enter code:" });
    defer allocator.free(manual_input);

    const parsed_auth = try parseAuthFromManualInput(allocator, manual_input);
    defer allocator.free(parsed_auth.code);
    defer allocator.free(parsed_auth.state);

    const token_response = try exchangeCode(parsed_auth.code, pkce.verifier, allocator);
    defer allocator.free(token_response.refresh_token);
    defer allocator.free(token_response.access_token);

    const expires = compat.time.nowMillis() + (token_response.expires_in * 1000) - (5 * 60 * 1000);

    return .{
        .refresh = try allocator.dupe(u8, token_response.refresh_token),
        .access = try allocator.dupe(u8, token_response.access_token),
        .expires = expires,
    };
}

/// Refresh OpenAI Codex OAuth token.
pub fn refreshToken(credentials: Credentials, allocator: std.mem.Allocator) !Credentials {
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .grant_type = "refresh_token",
        .client_id = client_id,
        .refresh_token = credentials.refresh,
        .scope = "openid profile email offline_access",
    }, .{});
    defer allocator.free(body);

    const token_response = try exchangeTokens(body, allocator);
    defer allocator.free(token_response.refresh_token);
    defer allocator.free(token_response.access_token);

    const expires = compat.time.nowMillis() + (token_response.expires_in * 1000) - (5 * 60 * 1000);

    return .{
        .refresh = try allocator.dupe(u8, token_response.refresh_token),
        .access = try allocator.dupe(u8, token_response.access_token),
        .expires = expires,
    };
}

/// Get API key from credentials (access token IS the API key).
pub fn getApiKey(credentials: Credentials, allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(u8, credentials.access);
}

const ParsedAuth = struct {
    code: []const u8,
    state: []const u8,
};

/// Parse code and state from manual input (a redirect URL, "code#state", or
/// just "code").
fn parseAuthFromManualInput(allocator: std.mem.Allocator, input: []const u8) !ParsedAuth {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");

    // An empty paste means the user dismissed the prompt: treat it as a
    // cancellation rather than attempting a doomed exchange with a blank code.
    if (trimmed.len == 0) return error.OAuthCancelled;

    if (std.mem.find(u8, trimmed, "?code=") orelse std.mem.find(u8, trimmed, "&code=")) |idx| {
        const code_start = idx + 6;
        var code_end = trimmed.len;
        if (std.mem.findAny(u8, trimmed[code_start..], "#&")) |end| {
            code_end = code_start + end;
        }
        const code = try allocator.dupe(u8, trimmed[code_start..code_end]);
        errdefer allocator.free(code);

        var state: []const u8 = "";
        if (std.mem.find(u8, trimmed, "state=")) |state_idx| {
            const state_start = state_idx + 6;
            var state_end = trimmed.len;
            if (std.mem.findAny(u8, trimmed[state_start..], "#&")) |end| {
                state_end = state_start + end;
            }
            state = trimmed[state_start..state_end];
        }
        return .{ .code = code, .state = try allocator.dupe(u8, state) };
    }

    if (std.mem.find(u8, trimmed, "#")) |hash_idx| {
        const code = try allocator.dupe(u8, trimmed[0..hash_idx]);
        errdefer allocator.free(code);
        return .{ .code = code, .state = try allocator.dupe(u8, trimmed[hash_idx + 1 ..]) };
    }

    return .{
        .code = try allocator.dupe(u8, trimmed),
        .state = try allocator.dupe(u8, ""),
    };
}

const TokenResponse = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    expires_in: i64,
};

fn getObjectStringField(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |value| {
        if (value == .string) return value.string;
    }
    return null;
}

fn getObjectI64Field(obj: *const std.json.ObjectMap, key: []const u8) ?i64 {
    if (obj.get(key)) |value| {
        return switch (value) {
            .integer => value.integer,
            .float => @intFromFloat(value.float),
            else => null,
        };
    }
    return null;
}

fn parseTokenResponse(response_body: []const u8, allocator: std.mem.Allocator) !TokenResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch {
        std.debug.print("Failed to parse Codex token response JSON: {s}\n", .{response_body});
        return error.ParseError;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.ParseError;

    const obj = &parsed.value.object;
    if (getObjectStringField(obj, "error")) |err| {
        std.debug.print("Codex OAuth error: {s}", .{err});
        if (getObjectStringField(obj, "error_description")) |desc| {
            std.debug.print(" - {s}", .{desc});
        }
        std.debug.print("\n", .{});
        return error.OAuthFailed;
    }

    const access_token = getObjectStringField(obj, "access_token") orelse {
        std.debug.print("Codex token response missing access_token: {s}\n", .{response_body});
        return error.ParseError;
    };
    const refresh_token = getObjectStringField(obj, "refresh_token") orelse access_token;

    var expires_in = getObjectI64Field(obj, "expires_in") orelse 3600;
    if (expires_in <= 0) expires_in = 3600;

    return .{
        .access_token = try allocator.dupe(u8, access_token),
        .refresh_token = try allocator.dupe(u8, refresh_token),
        .expires_in = expires_in,
    };
}

fn exchangeCode(code: []const u8, verifier: []const u8, allocator: std.mem.Allocator) !TokenResponse {
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .grant_type = "authorization_code",
        .client_id = client_id,
        .code = code,
        .redirect_uri = redirect_uri,
        .code_verifier = verifier,
    }, .{});
    defer allocator.free(body);

    return try exchangeTokens(body, allocator);
}

fn exchangeTokens(body: []const u8, allocator: std.mem.Allocator) !TokenResponse {
    var client = http.HttpClient.init(allocator);
    defer client.deinit();

    var environ_map = compat.createEnvMap(allocator) catch null;
    defer if (environ_map) |*map| map.deinit();
    if (environ_map) |*map| {
        client.initDefaultProxies(allocator, map) catch |err| blk: {
            std.debug.print("Warning: Failed to initialize HTTP proxy: {}\n", .{err});
            break :blk;
        };
    }

    const uri = try std.Uri.parse(token_url);

    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });

    var request = try client.openRequest(.POST, uri, .{
        .extra_headers = headers.items,
        .accept_encoding = "identity",
    });
    defer request.deinit();

    request.headers.accept_encoding = .omit;

    try http.sendRequest(&request, body);

    var header_buffer: [4096]u8 = undefined;
    var response = try http.receiveResponse(&request, &header_buffer);

    if (response.head.status != .ok) {
        var buffer: [4096]u8 = undefined;
        const reader = http.responseReader(&response, &buffer);
        const error_body = try http.allocRemainingResponse(allocator, reader, 8192);
        defer allocator.free(error_body);
        std.debug.print("Codex token exchange error {d}: {s}\n", .{ @intFromEnum(response.head.status), error_body });
        return error.OAuthFailed;
    }

    var response_buffer: [8192]u8 = undefined;
    const reader = http.responseReader(&response, &response_buffer);
    const response_body = try http.allocRemainingResponse(allocator, reader, 8192);
    defer allocator.free(response_body);

    return try parseTokenResponse(response_body, allocator);
}

test "buildAuthUrl includes client_id and PKCE challenge" {
    const url = try buildAuthUrl(std.testing.allocator, "challenge-value", "state-value");
    defer std.testing.allocator.free(url);

    try std.testing.expect(std.mem.find(u8, url, "client_id=app_") != null);
    try std.testing.expect(std.mem.find(u8, url, "code_challenge=challenge-value") != null);
    try std.testing.expect(std.mem.find(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.find(u8, url, "state=state-value") != null);
}

test "parseAuthFromManualInput - redirect url with code and state" {
    const input = "http://localhost:1455/auth/callback?code=abc123&state=xyz";
    const auth = try parseAuthFromManualInput(std.testing.allocator, input);
    defer std.testing.allocator.free(auth.code);
    defer std.testing.allocator.free(auth.state);

    try std.testing.expectEqualStrings("abc123", auth.code);
    try std.testing.expectEqualStrings("xyz", auth.state);
}

test "parseAuthFromManualInput - raw code only" {
    const input = "just-a-code";
    const auth = try parseAuthFromManualInput(std.testing.allocator, input);
    defer std.testing.allocator.free(auth.code);
    defer std.testing.allocator.free(auth.state);

    try std.testing.expectEqualStrings("just-a-code", auth.code);
    try std.testing.expectEqualStrings("", auth.state);
}

test "parseAuthFromManualInput - trims surrounding whitespace" {
    const input = "  code123\n";
    const auth = try parseAuthFromManualInput(std.testing.allocator, input);
    defer std.testing.allocator.free(auth.code);
    defer std.testing.allocator.free(auth.state);

    try std.testing.expectEqualStrings("code123", auth.code);
}

test "getApiKey - returns access token" {
    const credentials = Credentials{
        .refresh = "refresh_token",
        .access = "access_token",
        .expires = compat.time.nowMillis() + 3600000,
    };

    const api_key = try getApiKey(credentials, std.testing.allocator);
    defer std.testing.allocator.free(api_key);

    try std.testing.expectEqualStrings("access_token", api_key);
}

test "parseTokenResponse extracts tokens" {
    const payload =
        \\{"access_token":"acc","refresh_token":"ref","expires_in":1800}
    ;
    const response = try parseTokenResponse(payload, std.testing.allocator);
    defer std.testing.allocator.free(response.access_token);
    defer std.testing.allocator.free(response.refresh_token);

    try std.testing.expectEqualStrings("acc", response.access_token);
    try std.testing.expectEqualStrings("ref", response.refresh_token);
    try std.testing.expectEqual(@as(i64, 1800), response.expires_in);
}

test "parseTokenResponse falls back to access_token when refresh missing" {
    const payload =
        \\{"access_token":"acc"}
    ;
    const response = try parseTokenResponse(payload, std.testing.allocator);
    defer std.testing.allocator.free(response.access_token);
    defer std.testing.allocator.free(response.refresh_token);

    try std.testing.expectEqualStrings("acc", response.access_token);
    try std.testing.expectEqualStrings("acc", response.refresh_token);
    try std.testing.expect(response.expires_in > 0);
}

test "parseTokenResponse maps oauth error payload to OAuthFailed" {
    const payload =
        \\{"error":"invalid_grant","error_description":"bad code"}
    ;
    try std.testing.expectError(error.OAuthFailed, parseTokenResponse(payload, std.testing.allocator));
}
