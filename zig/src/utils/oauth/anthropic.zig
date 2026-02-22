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

/// Anthropic OAuth login (manual code flow with PKCE)
pub fn login(callbacks: Callbacks, allocator: std.mem.Allocator) !Credentials {
    // 1. Generate PKCE
    const pkce = try pkce_mod.generate(allocator);
    defer pkce.deinit(allocator);

    // 2. Build authorization URL
    const auth_url = try std.fmt.allocPrint(allocator,
        "{s}?client_id={s}&redirect_uri={s}&scope={s}&response_type=code&code_challenge={s}&code_challenge_method=S256&state={s}",
        .{ auth_url_base, client_id, redirect_uri, scopes, pkce.challenge, pkce.verifier },
    );
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

    // 5. Exchange code for tokens
    const token_response = try exchangeCode(parsed_auth.code, parsed_auth.state, pkce.verifier, allocator);
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
    try headers.append(allocator, .{ .name = "accept-encoding", .value = "identity" });

    var request = try client.request(.POST, uri, .{
        .extra_headers = headers.items,
    });
    defer request.deinit();

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

    // First check for error response
    if (std.json.parseFromSlice(
        struct {
            @"error": ?[]const u8 = null,
            error_description: ?[]const u8 = null,
        },
        allocator,
        response_body,
        .{ .ignore_unknown_fields = true },
    )) |error_parsed| {
        defer error_parsed.deinit();
        if (error_parsed.value.@"error") |err| {
            std.debug.print("OAuth error: {s}", .{err});
            if (error_parsed.value.error_description) |desc| {
                std.debug.print(" - {s}", .{desc});
            }
            std.debug.print("\n", .{});
            return error.OAuthFailed;
        }
    } else |_| {}

    // Parse JSON response
    const parsed = std.json.parseFromSlice(
        struct {
            access_token: []const u8,
            refresh_token: []const u8,
            expires_in: i64,
        },
        allocator,
        response_body,
        .{ .ignore_unknown_fields = true },
    ) catch {
        std.debug.print("Failed to parse JSON response: {s}\n", .{response_body});
        return error.ParseError;
    };
    defer parsed.deinit();

    return .{
        .access_token = try allocator.dupe(u8, parsed.value.access_token),
        .refresh_token = try allocator.dupe(u8, parsed.value.refresh_token),
        .expires_in = parsed.value.expires_in,
    };
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
