const std = @import("std");
const ai_types = @import("ai_types");

// GitHub OAuth configuration
pub const client_id = "Iv1.b507a08c87ecfe98";
pub const device_code_url = "https://github.com/login/device/code";
pub const token_url = "https://github.com/login/oauth/access_token";
pub const copilot_token_url = "https://api.github.com/copilot_internal/v2/token";

/// Known GitHub Copilot models (from pi-mono/models.dev)
pub const KNOWN_COPILOT_MODELS = [_][]const u8{
    // GPT models
    "gpt-4o",
    "gpt-4.1",
    "gpt-5",
    "gpt-5-mini",
    "gpt-5.1",
    "gpt-5.1-codex",
    "gpt-5.1-codex-max",
    "gpt-5.1-codex-mini",
    "gpt-5.2",
    "gpt-5.2-codex",
    // Claude models
    "claude-haiku-4.5",
    "claude-opus-4.5",
    "claude-opus-4.6",
    "claude-sonnet-4",
    "claude-sonnet-4.5",
    // Gemini models
    "gemini-2.5-pro",
    "gemini-3-flash-preview",
    "gemini-3-pro-preview",
    // Grok models
    "grok-code-fast-1",
    // Add more as needed
};

/// Copilot-specific headers required for API requests
pub const COPILOT_HEADERS = struct {
    pub const user_agent = "GitHubCopilotChat/0.35.0";
    pub const editor_version = "vscode/1.107.0";
    pub const editor_plugin_version = "copilot-chat/0.35.0";
    pub const copilot_integration_id = "vscode-chat";
};

pub const Credentials = struct {
    refresh: []const u8, // GitHub access token (for refresh)
    access: []const u8, // Copilot token
    expires: i64, // Expiration timestamp (ms)
    provider_data: ?[]const u8 = null, // JSON with enterpriseUrl if applicable
    enabled_models: ?[][]const u8 = null, // Models successfully enabled
    base_url: ?[]const u8 = null, // API base URL from token
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

/// Parse proxy-ep from Copilot token and convert to API base URL
/// Token format: tid=...;exp=...;proxy-ep=proxy.individual.githubcopilot.com;...
/// Returns: https://api.individual.githubcopilot.com
pub fn getBaseUrlFromToken(token: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    // Find "proxy-ep=" in token
    const prefix = "proxy-ep=";
    const start_idx = std.mem.indexOf(u8, token, prefix) orelse return null;
    const value_start = start_idx + prefix.len;

    // Find end of value (semicolon or end of string)
    const remaining = token[value_start..];
    const end_idx = std.mem.indexOf(u8, remaining, ";") orelse remaining.len;
    const proxy_host = remaining[0..end_idx];

    // Convert "proxy.xxx" to "api.xxx"
    if (std.mem.startsWith(u8, proxy_host, "proxy.")) {
        const api_host = proxy_host[6..]; // Skip "proxy."
        return std.fmt.allocPrint(allocator, "https://api.{s}", .{api_host}) catch null;
    }

    // Fallback: just prepend https://
    return std.fmt.allocPrint(allocator, "https://{s}", .{proxy_host}) catch null;
}

/// Get default base URL for GitHub Copilot
pub fn getDefaultBaseUrl(allocator: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(allocator, "https://api.individual.githubcopilot.com", .{}) catch "https://api.individual.githubcopilot.com";
}

/// Enable a model via policy endpoint
/// Returns true if successful, false otherwise
pub fn enableModel(
    allocator: std.mem.Allocator,
    token: []const u8,
    model_id: []const u8,
    base_url: []const u8,
) !bool {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build URL
    const url = try std.fmt.allocPrint(allocator, "{s}/models/{s}/policy", .{ base_url, model_id });
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);

    // Build auth header
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    var body_buffer = "{\"state\": \"enabled\"}".*;
    const body = body_buffer[0..];

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "authorization", .value = auth_header });
    try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });
    try headers.append(allocator, .{ .name = "openai-intent", .value = "chat-policy" });
    try headers.append(allocator, .{ .name = "x-interaction-type", .value = "chat-policy" });

    var request = try client.request(.POST, uri, .{
        .extra_headers = headers.items,
    });
    defer request.deinit();

    request.transfer_encoding = .{ .content_length = body.len };
    try request.sendBodyComplete(body);

    var header_buffer: [4096]u8 = undefined;
    const response = try request.receiveHead(&header_buffer);

    // Return true if status is 200, false otherwise
    return response.head.status == .ok;
}

/// Enable all models and return list of successfully enabled ones
/// Models that fail enablement are excluded from the returned list
pub fn enableAllModels(
    allocator: std.mem.Allocator,
    token: []const u8,
    base_url: []const u8,
    on_progress: ?*const fn (model: []const u8, success: bool) void,
) ![][]const u8 {
    var enabled = try std.ArrayList([]const u8).initCapacity(allocator, KNOWN_COPILOT_MODELS.len);
    errdefer {
        for (enabled.items) |m| allocator.free(m);
        enabled.deinit(allocator);
    }

    for (KNOWN_COPILOT_MODELS) |model| {
        const success = enableModel(allocator, token, model, base_url) catch false;
        if (on_progress) |cb| cb(model, success);

        if (success) {
            try enabled.append(allocator, try allocator.dupe(u8, model));
        }
    }

    return enabled.toOwnedSlice(allocator);
}

/// GitHub Copilot OAuth login (device code flow)
pub fn login(callbacks: Callbacks, allocator: std.mem.Allocator) !Credentials {
    // 1. Prompt for enterprise domain (optional)
    const domain_input = callbacks.onPrompt(.{
        .message = "GitHub domain (press Enter for github.com):",
        .allow_empty = true,
    });
    const github_domain = if (domain_input.len == 0) "github.com" else domain_input;
    defer if (domain_input.len > 0) allocator.free(domain_input);

    // 2. Start device code flow
    const device_response = try startDeviceFlow(github_domain, allocator);
    defer allocator.free(device_response.device_code);
    defer allocator.free(device_response.user_code);
    defer allocator.free(device_response.verification_uri);

    // 3. Show verification URI and user code
    const instructions = try std.fmt.allocPrint(allocator, "Enter code: {s}", .{device_response.user_code});
    defer allocator.free(instructions);

    callbacks.onAuth(.{
        .url = device_response.verification_uri,
        .instructions = instructions,
    });

    // 4. Poll for token
    var interval_ms: u64 = device_response.interval * 1000;
    const deadline = std.time.milliTimestamp() + (@as(i64, device_response.expires_in) * 1000);

    while (std.time.milliTimestamp() < deadline) {
        const poll_result = try pollForToken(github_domain, device_response.device_code, allocator);
        defer if (poll_result.access_token) |t| allocator.free(t);
        defer if (poll_result.error_msg) |msg| allocator.free(msg);

        if (poll_result.access_token) |github_token| {
            // 5. Exchange GitHub token for Copilot token
            const copilot_token = try getCopilotToken(github_domain, github_token, allocator);

            // 6. Parse base URL from token
            const base_url = getBaseUrlFromToken(copilot_token, allocator);

            // 7. Parse enterprise URL if needed
            const enterprise_url = if (!std.mem.eql(u8, github_domain, "github.com"))
                try std.fmt.allocPrint(allocator, "https://{s}", .{github_domain})
            else
                null;

            const provider_data = if (enterprise_url) |url| blk: {
                defer allocator.free(url);
                break :blk try std.fmt.allocPrint(allocator, "{{\"enterpriseUrl\":\"{s}\"}}", .{url});
            } else null;

            // 8. Enable all models
            const resolved_base_url = base_url orelse getDefaultBaseUrl(allocator);
            const enabled_models = try enableAllModels(allocator, copilot_token, resolved_base_url, null);

            // Free base_url if we allocated it
            if (base_url) |bu| allocator.free(bu);

            return .{
                .refresh = try allocator.dupe(u8, github_token),
                .access = copilot_token,
                .expires = std.time.milliTimestamp() + (3600 * 1000), // 1 hour
                .provider_data = provider_data,
                .enabled_models = enabled_models,
                .base_url = if (base_url) |bu| try allocator.dupe(u8, bu) else null,
            };
        }

        if (poll_result.error_msg) |err_msg| {
            if (std.mem.eql(u8, err_msg, "authorization_pending")) {
                std.Thread.sleep(interval_ms * std.time.ns_per_ms);
                continue;
            } else if (std.mem.eql(u8, err_msg, "slow_down")) {
                interval_ms += 5000;
                std.Thread.sleep(interval_ms * std.time.ns_per_ms);
                continue;
            } else {
                return error.OAuthFailed;
            }
        }
    }

    return error.OAuthTimeout;
}

/// Refresh GitHub Copilot token
pub fn refreshToken(credentials: Credentials, allocator: std.mem.Allocator) !Credentials {
    // Parse enterprise URL from provider_data
    const github_domain = if (credentials.provider_data) |data| blk: {
        if (std.mem.indexOf(u8, data, "enterpriseUrl")) |_| {
            if (std.mem.indexOf(u8, data, "https://")) |idx| {
                const start = idx + 8;
                const end = std.mem.indexOfScalar(u8, data[start..], '"') orelse data.len - start;
                break :blk data[start .. start + end];
            }
        }
        break :blk "github.com";
    } else "github.com";

    // Use refresh token (GitHub token) to get new Copilot token
    const copilot_token = try getCopilotToken(github_domain, credentials.refresh, allocator);

    // Parse base URL from new token
    const base_url = getBaseUrlFromToken(copilot_token, allocator);

    // Re-enable models with new token
    const resolved_base_url = base_url orelse getDefaultBaseUrl(allocator);
    const enabled_models = try enableAllModels(allocator, copilot_token, resolved_base_url, null);

    // Dupe base_url BEFORE freeing the original
    const result_base_url = if (base_url) |bu| try allocator.dupe(u8, bu) else null;

    if (base_url) |bu| allocator.free(bu);

    return .{
        .refresh = try allocator.dupe(u8, credentials.refresh),
        .access = copilot_token,
        .expires = std.time.milliTimestamp() + (3600 * 1000),
        .provider_data = if (credentials.provider_data) |data| try allocator.dupe(u8, data) else null,
        .enabled_models = enabled_models,
        .base_url = result_base_url,
    };
}

/// Get API key from credentials (access token IS the API key)
pub fn getApiKey(credentials: Credentials, allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(u8, credentials.access);
}

/// Infer the X-Initiator header value based on the last message role.
/// Copilot expects "agent" when the last message is from the assistant (follow-up),
/// and "user" otherwise.
pub fn inferCopilotInitiator(messages: []const ai_types.Message) []const u8 {
    if (messages.len == 0) return "user";
    const last = messages[messages.len - 1];
    return switch (last) {
        .assistant => "agent",
        else => "user",
    };
}

/// Check if any message contains image content for Copilot-Vision-Request header.
pub fn hasCopilotVisionInput(messages: []const ai_types.Message) bool {
    for (messages) |msg| {
        switch (msg) {
            .user => |u| switch (u.content) {
                .parts => |parts| {
                    for (parts) |p| {
                        if (p == .image) return true;
                    }
                },
                else => {},
            },
            .tool_result => |tr| {
                for (tr.content) |c| {
                    if (c == .image) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

/// Build dynamic Copilot headers based on messages and image presence.
/// Caller owns the returned slice and must free it with allocator.free().
pub fn buildCopilotDynamicHeaders(
    messages: []const ai_types.Message,
    has_images: bool,
    allocator: std.mem.Allocator,
) ![]std.http.Header {
    var headers = try std.ArrayList(std.http.Header).initCapacity(allocator, 3);
    errdefer headers.deinit(allocator);

    try headers.append(allocator, .{
        .name = "X-Initiator",
        .value = inferCopilotInitiator(messages),
    });
    try headers.append(allocator, .{
        .name = "Openai-Intent",
        .value = "conversation-edits",
    });

    if (has_images) {
        try headers.append(allocator, .{
            .name = "Copilot-Vision-Request",
            .value = "true",
        });
    }

    return headers.toOwnedSlice(allocator);
}

const DeviceCodeResponse = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    expires_in: i64,
    interval: u64,
};

/// Start GitHub device code flow
fn startDeviceFlow(domain: []const u8, allocator: std.mem.Allocator) !DeviceCodeResponse {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build URL (support enterprise domains)
    const url = if (std.mem.eql(u8, domain, "github.com"))
        device_code_url
    else
        try std.fmt.allocPrint(allocator, "https://{s}/login/device/code", .{domain});
    defer if (!std.mem.eql(u8, domain, "github.com")) allocator.free(@constCast(url));

    const uri = try std.Uri.parse(url);

    // Build request body
    const body = try std.fmt.allocPrint(allocator, "client_id={s}&scope=user:email", .{client_id});
    defer allocator.free(body);

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "content-type", .value = "application/x-www-form-urlencoded" });

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
        const err_msg = try std.fmt.allocPrint(allocator, "Device flow error {d}: {s}", .{ @intFromEnum(response.head.status), error_body });
        defer allocator.free(err_msg);
        return error.OAuthFailed;
    }

    var response_buffer: [8192]u8 = undefined;
    const response_body = try response.reader(&response_buffer).*.allocRemaining(allocator, std.io.Limit.limited(8192));
    defer allocator.free(response_body);

    // Parse JSON response
    const parsed = try std.json.parseFromSlice(
        struct {
            device_code: []const u8,
            user_code: []const u8,
            verification_uri: []const u8,
            expires_in: i64,
            interval: ?u64,
        },
        allocator,
        response_body,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    return .{
        .device_code = try allocator.dupe(u8, parsed.value.device_code),
        .user_code = try allocator.dupe(u8, parsed.value.user_code),
        .verification_uri = try allocator.dupe(u8, parsed.value.verification_uri),
        .expires_in = parsed.value.expires_in,
        .interval = parsed.value.interval orelse 5,
    };
}

const PollResult = struct {
    access_token: ?[]const u8 = null,
    error_msg: ?[]const u8 = null,
};

/// Poll for GitHub access token
fn pollForToken(domain: []const u8, device_code: []const u8, allocator: std.mem.Allocator) !PollResult {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build URL (support enterprise domains)
    const url = if (std.mem.eql(u8, domain, "github.com"))
        token_url
    else
        try std.fmt.allocPrint(allocator, "https://{s}/login/oauth/access_token", .{domain});
    defer if (!std.mem.eql(u8, domain, "github.com")) allocator.free(@constCast(url));

    const uri = try std.Uri.parse(url);

    // Build request body
    const body = try std.fmt.allocPrint(
        allocator,
        "client_id={s}&device_code={s}&grant_type=urn:ietf:params:oauth:grant-type:device_code",
        .{ client_id, device_code },
    );
    defer allocator.free(body);

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "content-type", .value = "application/x-www-form-urlencoded" });

    var request = try client.request(.POST, uri, .{
        .extra_headers = headers.items,
    });
    defer request.deinit();

    request.transfer_encoding = .{ .content_length = body.len };
    try request.sendBodyComplete(@constCast(body));

    var header_buffer: [4096]u8 = undefined;
    var response = try request.receiveHead(&header_buffer);

    if (response.head.status != .ok) {
        return .{
            .error_msg = try allocator.dupe(u8, "http_error"),
        };
    }

    var response_buffer: [8192]u8 = undefined;
    const response_body = try response.reader(&response_buffer).*.allocRemaining(allocator, std.io.Limit.limited(8192));
    defer allocator.free(response_body);

    // Parse JSON response (can be success or error)
    const parsed = try std.json.parseFromSlice(
        struct {
            access_token: ?[]const u8 = null,
            token_type: ?[]const u8 = null,
            scope: ?[]const u8 = null,
            @"error": ?[]const u8 = null,
            error_description: ?[]const u8 = null,
        },
        allocator,
        response_body,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    if (parsed.value.access_token) |token| {
        return .{
            .access_token = try allocator.dupe(u8, token),
        };
    } else if (parsed.value.@"error") |err| {
        return .{
            .error_msg = try allocator.dupe(u8, err),
        };
    } else {
        return .{
            .error_msg = try allocator.dupe(u8, "unknown_error"),
        };
    }
}

/// Get Copilot token from GitHub token
fn getCopilotToken(domain: []const u8, github_token: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build URL (support enterprise domains)
    const url = if (std.mem.eql(u8, domain, "github.com"))
        copilot_token_url
    else
        try std.fmt.allocPrint(allocator, "https://{s}/copilot_internal/v2/token", .{domain});
    defer if (!std.mem.eql(u8, domain, "github.com")) allocator.free(@constCast(url));

    const uri = try std.Uri.parse(url);

    // Build auth header
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{github_token});
    defer allocator.free(auth_header);

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "authorization", .value = auth_header });
    try headers.append(allocator, .{ .name = "accept", .value = "application/json" });
    // Copilot-specific headers required for token endpoint
    try headers.append(allocator, .{ .name = "editor-version", .value = COPILOT_HEADERS.editor_version });
    try headers.append(allocator, .{ .name = "editor-plugin-version", .value = COPILOT_HEADERS.editor_plugin_version });
    try headers.append(allocator, .{ .name = "user-agent", .value = COPILOT_HEADERS.user_agent });

    var request = try client.request(.GET, uri, .{
        .extra_headers = headers.items,
    });
    defer request.deinit();

    // Avoid compressed response bodies for simpler token JSON parsing
    request.headers.accept_encoding = .omit;

    try request.sendBodiless();

    var header_buffer: [4096]u8 = undefined;
    var response = try request.receiveHead(&header_buffer);

    if (response.head.status != .ok) {
        var buffer: [4096]u8 = undefined;
        const error_body = try response.reader(&buffer).*.allocRemaining(allocator, std.io.Limit.limited(8192));
        defer allocator.free(error_body);
        const err_msg = try std.fmt.allocPrint(allocator, "Copilot token error {d}: {s}", .{ @intFromEnum(response.head.status), error_body });
        defer allocator.free(err_msg);
        return error.CopilotTokenFailed;
    }

    var response_buffer: [8192]u8 = undefined;
    const response_body = try response.reader(&response_buffer).*.allocRemaining(allocator, std.io.Limit.limited(8192));
    defer allocator.free(response_body);

    // Parse JSON response (expected format: {"token": "..."})
    const parsed = std.json.parseFromSlice(
        struct {
            token: []const u8,
        },
        allocator,
        response_body,
        .{ .ignore_unknown_fields = true },
    ) catch {
        // Some endpoints may return the raw token string directly instead of JSON.
        // Accept token-like payloads as a fallback.
        const trimmed = std.mem.trim(u8, response_body, " \r\n\t\"");
        if (std.mem.indexOf(u8, trimmed, "tid=") != null or
            std.mem.indexOf(u8, trimmed, "proxy-ep=") != null)
        {
            return try allocator.dupe(u8, trimmed);
        }
        return error.CopilotTokenFailed;
    };
    defer parsed.deinit();

    return try allocator.dupe(u8, parsed.value.token);
}

// Tests
test "getBaseUrlFromToken - extracts and converts proxy-ep" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const token = "tid=abc123;exp=9999999999;proxy-ep=proxy.individual.githubcopilot.com;other=data";
    const base_url = getBaseUrlFromToken(token, allocator) orelse @panic("Failed to parse");
    defer allocator.free(base_url);

    try testing.expectEqualStrings("https://api.individual.githubcopilot.com", base_url);
}

test "getBaseUrlFromToken - returns null if no proxy-ep" {
    const testing = std.testing;

    const token = "tid=abc123;exp=9999999999;other=data";
    const base_url = getBaseUrlFromToken(token, testing.allocator);

    try testing.expect(base_url == null);
}

test "getApiKey - returns access token" {
    const credentials = Credentials{
        .refresh = "github_token",
        .access = "copilot_token",
        .expires = std.time.milliTimestamp() + 3600000,
    };

    const api_key = try getApiKey(credentials, std.testing.allocator);
    defer std.testing.allocator.free(api_key);

    try std.testing.expectEqualStrings("copilot_token", api_key);
}

test "KNOWN_COPILOT_MODELS - contains expected models" {
    const testing = std.testing;

    // Check that key models are present
    var has_gpt4o = false;
    var has_claude = false;
    var has_gemini = false;

    for (KNOWN_COPILOT_MODELS) |model| {
        if (std.mem.eql(u8, model, "gpt-4o")) has_gpt4o = true;
        if (std.mem.startsWith(u8, model, "claude-")) has_claude = true;
        if (std.mem.startsWith(u8, model, "gemini-")) has_gemini = true;
    }

    try testing.expect(has_gpt4o);
    try testing.expect(has_claude);
    try testing.expect(has_gemini);
}

test "startDeviceFlow - returns valid response (integration test, requires network)" {
    // This test makes a real HTTP request to GitHub's device flow endpoint
    // It may fail without network access or if GitHub's API is unavailable
    const response = startDeviceFlow("github.com", std.testing.allocator) catch |err| {
        // If we get a network or parsing error, skip the test rather than fail
        if (err == error.ConnectionRefused or err == error.NetworkUnreachable or
            err == error.SyntaxError or err == error.UnexpectedToken)
        {
            return error.SkipZigTest;
        }
        return err;
    };
    defer std.testing.allocator.free(response.device_code);
    defer std.testing.allocator.free(response.user_code);
    defer std.testing.allocator.free(response.verification_uri);

    try std.testing.expect(response.device_code.len > 0);
    try std.testing.expect(response.user_code.len > 0);
    try std.testing.expect(response.expires_in > 0);
    try std.testing.expect(response.interval > 0);
}

test "inferCopilotInitiator - returns user for empty messages" {
    const testing = std.testing;
    const messages: []const ai_types.Message = &[_]ai_types.Message{};
    try testing.expectEqualStrings("user", inferCopilotInitiator(messages));
}

test "inferCopilotInitiator - returns user when last message is user" {
    const testing = std.testing;
    const messages = [_]ai_types.Message{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } },
    };
    try testing.expectEqualStrings("user", inferCopilotInitiator(&messages));
}

test "inferCopilotInitiator - returns agent when last message is assistant" {
    const testing = std.testing;
    const messages = [_]ai_types.Message{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } },
        .{ .assistant = .{
            .content = &[_]ai_types.AssistantContent{.{ .text = .{ .text = "hi" } }},
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 0,
        } },
    };
    try testing.expectEqualStrings("agent", inferCopilotInitiator(&messages));
}

test "inferCopilotInitiator - returns user when last message is tool_result" {
    const testing = std.testing;
    const messages = [_]ai_types.Message{
        .{ .tool_result = .{
            .tool_call_id = "1",
            .tool_name = "test",
            .content = &[_]ai_types.UserContentPart{.{ .text = .{ .text = "result" } }},
            .is_error = false,
            .timestamp = 0,
        } },
    };
    try testing.expectEqualStrings("user", inferCopilotInitiator(&messages));
}

test "hasCopilotVisionInput - returns false for text-only user message" {
    const testing = std.testing;
    const messages = [_]ai_types.Message{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } },
    };
    try testing.expect(!hasCopilotVisionInput(&messages));
}

test "hasCopilotVisionInput - returns true for user message with image" {
    const testing = std.testing;
    const messages = [_]ai_types.Message{
        .{ .user = .{ .content = .{ .parts = &[_]ai_types.UserContentPart{
            .{ .text = .{ .text = "look at this" } },
            .{ .image = .{ .data = "base64data", .mime_type = "image/png" } },
        } }, .timestamp = 0 } },
    };
    try testing.expect(hasCopilotVisionInput(&messages));
}

test "hasCopilotVisionInput - returns true for tool_result with image" {
    const testing = std.testing;
    const messages = [_]ai_types.Message{
        .{ .tool_result = .{
            .tool_call_id = "1",
            .tool_name = "test",
            .content = &[_]ai_types.UserContentPart{
                .{ .image = .{ .data = "base64data", .mime_type = "image/png" } },
            },
            .is_error = false,
            .timestamp = 0,
        } },
    };
    try testing.expect(hasCopilotVisionInput(&messages));
}

test "buildCopilotDynamicHeaders - includes X-Initiator and Openai-Intent" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const messages = [_]ai_types.Message{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } },
    };

    const headers = try buildCopilotDynamicHeaders(&messages, false, allocator);
    defer allocator.free(headers);

    try testing.expectEqual(@as(usize, 2), headers.len);
    try testing.expectEqualStrings("X-Initiator", headers[0].name);
    try testing.expectEqualStrings("user", headers[0].value);
    try testing.expectEqualStrings("Openai-Intent", headers[1].name);
    try testing.expectEqualStrings("conversation-edits", headers[1].value);
}

test "buildCopilotDynamicHeaders - includes Copilot-Vision-Request when has_images" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const messages = [_]ai_types.Message{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } },
    };

    const headers = try buildCopilotDynamicHeaders(&messages, true, allocator);
    defer allocator.free(headers);

    try testing.expectEqual(@as(usize, 3), headers.len);
    try testing.expectEqualStrings("Copilot-Vision-Request", headers[2].name);
    try testing.expectEqualStrings("true", headers[2].value);
}
