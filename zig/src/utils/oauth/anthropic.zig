const std = @import("std");
const pkce_mod = @import("oauth/pkce");

const client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const redirect_uri = "https://console.anthropic.com/oauth/code/callback";
const scopes = "org:create_api_key%20user:profile%20user:inference";
const auth_url_base = "https://claude.ai/oauth/authorize";
const token_url = "https://console.anthropic.com/v1/oauth/token";

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
        "{s}?code=true&client_id={s}&redirect_uri={s}&scope={s}&response_type=code&code_challenge={s}&code_challenge_method=S256&state={s}",
        .{ auth_url_base, client_id, redirect_uri, scopes, challenge, state },
    );
}

/// Anthropic OAuth login (manual code flow with PKCE)
pub fn login(callbacks: Callbacks, allocator: std.mem.Allocator) !Credentials {
    // 1. Generate PKCE
    const pkce = try pkce_mod.generate(allocator);
    defer pkce.deinit(allocator);

    // 2. Build authorization URL
    const auth_url = try buildAuthUrl(allocator, pkce.challenge, pkce.verifier);
    defer allocator.free(auth_url);

    // 3. Show URL to user
    callbacks.onAuth(.{
        .url = auth_url,
        .instructions = "Paste the code from the URL after '#code=' below:",
    });

    // 4. Get manual code input
    const manual_input = callbacks.onPrompt(.{ .message = "Enter code:" });
    defer allocator.free(manual_input);

    // Parse "code#state" format
    const parsed_auth = try parseAuthFromManualInput(allocator, manual_input);
    defer allocator.free(parsed_auth.code);
    defer allocator.free(parsed_auth.state);

    // 5. Exchange code for tokens.
    // Some UX paths provide only the code, so fall back to our original state value.
    const state_for_exchange = if (parsed_auth.state.len > 0) parsed_auth.state else pkce.verifier;
    const token_response = try exchangeCode(parsed_auth.code, state_for_exchange, pkce.verifier, allocator);
    defer allocator.free(token_response.refresh_token);
    defer allocator.free(token_response.access_token);

    // 6. Return credentials with 5-minute buffer
    const expires = std.time.milliTimestamp() + (token_response.expires_in * 1000) - (5 * 60 * 1000);

    return .{
        .refresh = try allocator.dupe(u8, token_response.refresh_token),
        .access = try allocator.dupe(u8, token_response.access_token),
        .expires = expires,
    };
}

/// Refresh Anthropic OAuth token
pub fn refreshToken(credentials: Credentials, allocator: std.mem.Allocator) !Credentials {
    // Build JSON request body
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .grant_type = "refresh_token",
        .client_id = client_id,
        .refresh_token = credentials.refresh,
    }, .{});
    defer allocator.free(body);

    // Make HTTP request (simplified - real implementation would use http.zig)
    const token_response = try exchangeTokens(body, allocator);
    defer allocator.free(token_response.refresh_token);
    defer allocator.free(token_response.access_token);

    const expires = std.time.milliTimestamp() + (token_response.expires_in * 1000) - (5 * 60 * 1000);

    return .{
        .refresh = try allocator.dupe(u8, token_response.refresh_token),
        .access = try allocator.dupe(u8, token_response.access_token),
        .expires = expires,
    };
}

/// Get API key from credentials (access token IS the API key)
pub fn getApiKey(credentials: Credentials, allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(u8, credentials.access);
}

/// Parsed code and state from manual input
const ParsedAuth = struct {
    code: []const u8,
    state: []const u8,
};

/// Parse code and state from manual input (format: "code#state" or just "code")
fn parseAuthFromManualInput(allocator: std.mem.Allocator, input: []const u8) !ParsedAuth {
    // Try to find #code= in URL
    if (std.mem.indexOf(u8, input, "#code=")) |idx| {
        const code_start = idx + 6;
        var code_end = input.len;
        var state: []const u8 = "";

        // Look for & or # after code
        if (std.mem.indexOfAny(u8, input[code_start..], "#&")) |end| {
            code_end = code_start + end;
        }

        const code = try allocator.dupe(u8, input[code_start..code_end]);

        // Look for state parameter
        if (std.mem.indexOf(u8, input, "&state=")) |state_idx| {
            const state_start = state_idx + 7;
            var state_end = input.len;
            if (std.mem.indexOf(u8, input[state_start..], "&")) |end| {
                state_end = state_start + end;
            }
            state = try allocator.dupe(u8, input[state_start..state_end]);
        } else if (std.mem.indexOf(u8, input, "#state=")) |state_idx| {
            const state_start = state_idx + 7;
            var state_end = input.len;
            if (std.mem.indexOf(u8, input[state_start..], "&")) |end| {
                state_end = state_start + end;
            }
            state = try allocator.dupe(u8, input[state_start..state_end]);
        }

        return .{ .code = code, .state = state };
    }

    // Try to find ?code= in URL
    if (std.mem.indexOf(u8, input, "?code=")) |idx| {
        const code_start = idx + 6;
        var code_end = input.len;
        var state: []const u8 = "";

        // Look for & or # after code
        if (std.mem.indexOfAny(u8, input[code_start..], "#&")) |end| {
            code_end = code_start + end;
        }

        const code = try allocator.dupe(u8, input[code_start..code_end]);

        // Look for state parameter
        if (std.mem.indexOf(u8, input, "&state=")) |state_idx| {
            const state_start = state_idx + 7;
            var state_end = input.len;
            if (std.mem.indexOf(u8, input[state_start..], "&")) |end| {
                state_end = state_start + end;
            }
            state = try allocator.dupe(u8, input[state_start..state_end]);
        }

        return .{ .code = code, .state = state };
    }

    // Assume raw "code#state" format
    if (std.mem.indexOf(u8, input, "#")) |hash_idx| {
        const code = try allocator.dupe(u8, input[0..hash_idx]);
        const state = try allocator.dupe(u8, input[hash_idx + 1 ..]);
        return .{ .code = code, .state = state };
    }

    // Just code, no state
    return .{
        .code = try allocator.dupe(u8, input),
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
        std.debug.print("Failed to parse token response JSON: {s}\n", .{response_body});
        return error.ParseError;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        std.debug.print("Token response is not an object: {s}\n", .{response_body});
        return error.ParseError;
    }

    const obj = &parsed.value.object;
    if (getObjectStringField(obj, "error")) |err| {
        std.debug.print("OAuth error: {s}", .{err});
        if (getObjectStringField(obj, "error_description")) |desc| {
            std.debug.print(" - {s}", .{desc});
        }
        std.debug.print("\n", .{});
        return error.OAuthFailed;
    }

    const access_token = getObjectStringField(obj, "access_token") orelse
        getObjectStringField(obj, "accessToken") orelse {
        std.debug.print("Token response missing access_token: {s}\n", .{response_body});
        return error.ParseError;
    };
    const refresh_token = getObjectStringField(obj, "refresh_token") orelse
        getObjectStringField(obj, "refreshToken") orelse access_token;

    var expires_in = getObjectI64Field(obj, "expires_in") orelse
        getObjectI64Field(obj, "expiresIn") orelse 3600;
    if (expires_in <= 0) {
        if (getObjectI64Field(obj, "expires_at")) |expires_at| {
            const now_seconds = std.time.timestamp();
            if (expires_at > now_seconds) expires_in = expires_at - now_seconds else expires_in = 3600;
        } else {
            expires_in = 3600;
        }
    }

    return .{
        .access_token = try allocator.dupe(u8, access_token),
        .refresh_token = try allocator.dupe(u8, refresh_token),
        .expires_in = expires_in,
    };
}

/// Exchange authorization code for tokens
fn exchangeCode(code: []const u8, state: []const u8, verifier: []const u8, allocator: std.mem.Allocator) !TokenResponse {
    // Build JSON body
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .grant_type = "authorization_code",
        .client_id = client_id,
        .code = code,
        .state = state,
        .redirect_uri = redirect_uri,
        .code_verifier = verifier,
    }, .{});
    defer allocator.free(body);

    return try exchangeTokens(body, allocator);
}

/// Exchange tokens with Anthropic API
fn exchangeTokens(body: []const u8, allocator: std.mem.Allocator) !TokenResponse {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Initialize proxy from environment variables (HTTP_PROXY, HTTPS_PROXY, ALL_PROXY)
    client.initDefaultProxies(allocator) catch |err| blk: {
        std.debug.print("Warning: Failed to initialize HTTP proxy: {}\n", .{err});
        break :blk;
    };

    const uri = try std.Uri.parse(token_url);

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });

    var request = try client.request(.POST, uri, .{
        .extra_headers = headers.items,
    });
    defer request.deinit();

    // Avoid compressed response bodies for stable token JSON parsing.
    request.headers.accept_encoding = .omit;

    request.transfer_encoding = .{ .content_length = body.len };
    try request.sendBodyComplete(@constCast(body));

    var header_buffer: [4096]u8 = undefined;
    var response = try request.receiveHead(&header_buffer);

    if (response.head.status != .ok) {
        var buffer: [4096]u8 = undefined;
        const error_body = try response.reader(&buffer).*.allocRemaining(allocator, std.io.Limit.limited(8192));
        defer allocator.free(error_body);
        std.debug.print("Token exchange error {d}: {s}\n", .{ @intFromEnum(response.head.status), error_body });
        return error.OAuthFailed;
    }

    var response_buffer: [8192]u8 = undefined;
    const response_body = try response.reader(&response_buffer).*.allocRemaining(allocator, std.io.Limit.limited(8192));
    defer allocator.free(response_body);

    return try parseTokenResponse(response_body, allocator);
}

test "parseAuthFromManualInput - hash fragment with state" {
    const input = "https://console.anthropic.com/oauth/code/callback#code=abc123&state=xyz";
    const auth = try parseAuthFromManualInput(std.testing.allocator, input);
    defer std.testing.allocator.free(auth.code);
    defer std.testing.allocator.free(auth.state);

    try std.testing.expectEqualStrings("abc123", auth.code);
    try std.testing.expectEqualStrings("xyz", auth.state);
}

test "parseAuthFromManualInput - query parameter with state" {
    const input = "https://console.anthropic.com/oauth/code/callback?code=def456&state=xyz";
    const auth = try parseAuthFromManualInput(std.testing.allocator, input);
    defer std.testing.allocator.free(auth.code);
    defer std.testing.allocator.free(auth.state);

    try std.testing.expectEqualStrings("def456", auth.code);
    try std.testing.expectEqualStrings("xyz", auth.state);
}

test "parseAuthFromManualInput - raw code#state format" {
    const input = "ghi789#mystate";
    const auth = try parseAuthFromManualInput(std.testing.allocator, input);
    defer std.testing.allocator.free(auth.code);
    defer std.testing.allocator.free(auth.state);

    try std.testing.expectEqualStrings("ghi789", auth.code);
    try std.testing.expectEqualStrings("mystate", auth.state);
}

test "parseAuthFromManualInput - raw code only" {
    const input = "ghi789";
    const auth = try parseAuthFromManualInput(std.testing.allocator, input);
    defer std.testing.allocator.free(auth.code);
    defer std.testing.allocator.free(auth.state);

    try std.testing.expectEqualStrings("ghi789", auth.code);
    try std.testing.expectEqualStrings("", auth.state);
}

test "getApiKey - returns access token" {
    const credentials = Credentials{
        .refresh = "refresh_token",
        .access = "access_token",
        .expires = std.time.milliTimestamp() + 3600000,
    };

    const api_key = try getApiKey(credentials, std.testing.allocator);
    defer std.testing.allocator.free(api_key);

    try std.testing.expectEqualStrings("access_token", api_key);
}

test "parseTokenResponse handles missing refresh and expires" {
    const payload =
        \\{"access_token":"a-token"}
    ;
    const response = try parseTokenResponse(payload, std.testing.allocator);
    defer std.testing.allocator.free(response.access_token);
    defer std.testing.allocator.free(response.refresh_token);

    try std.testing.expectEqualStrings("a-token", response.access_token);
    try std.testing.expectEqualStrings("a-token", response.refresh_token);
    try std.testing.expect(response.expires_in > 0);
}

test "buildAuthUrl includes code=true" {
    const url = try buildAuthUrl(std.testing.allocator, "challenge-value", "state-value");
    defer std.testing.allocator.free(url);

    try std.testing.expect(std.mem.indexOf(u8, url, "code=true") != null);
}

test "parseTokenResponse handles camelCase token fields" {
    const payload =
        \\{"accessToken":"camel-access","refreshToken":"camel-refresh","expiresIn":1800}
    ;
    const response = try parseTokenResponse(payload, std.testing.allocator);
    defer std.testing.allocator.free(response.access_token);
    defer std.testing.allocator.free(response.refresh_token);

    try std.testing.expectEqualStrings("camel-access", response.access_token);
    try std.testing.expectEqualStrings("camel-refresh", response.refresh_token);
    try std.testing.expectEqual(@as(i64, 1800), response.expires_in);
}

test "parseTokenResponse maps oauth error payload to OAuthFailed" {
    const payload =
        \\{"error":"invalid_grant","error_description":"Invalid 'code' in request."}
    ;
    try std.testing.expectError(error.OAuthFailed, parseTokenResponse(payload, std.testing.allocator));
}
