const std = @import("std");
const compat = @import("compat");
const http = compat.http;
const ai_types = @import("ai_types");

pub const client_id = "Iv1.b507a08c87ecfe98";
pub const device_code_url = "https://github.com/login/device/code";
pub const token_url = "https://github.com/login/oauth/access_token";
pub const copilot_token_url = "https://api.github.com/copilot_internal/v2/token";

pub const KNOWN_COPILOT_MODELS = [_][]const u8{
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
    "claude-haiku-4.5",
    "claude-opus-4.5",
    "claude-opus-4.6",
    "claude-sonnet-4",
    "claude-sonnet-4.5",
    "gemini-2.5-pro",
    "gemini-3-flash-preview",
    "gemini-3-pro-preview",
    "grok-code-fast-1",
};

pub const COPILOT_HEADERS = struct {
    pub const user_agent = "GitHubCopilotChat/0.35.0";
    pub const editor_version = "vscode/1.107.0";
    pub const editor_plugin_version = "copilot-chat/0.35.0";
    pub const copilot_integration_id = "vscode-chat";
};

pub const Credentials = struct {
    refresh: []const u8,
    access: []const u8,
    expires: i64,
    provider_data: ?[]const u8 = null,
    enabled_models: ?[][]const u8 = null,
    base_url: ?[]const u8 = null,
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

pub fn getBaseUrlFromToken(token: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    const prefix = "proxy-ep=";
    const start_idx = std.mem.find(u8, token, prefix) orelse return null;
    const value_start = start_idx + prefix.len;

    const remaining = token[value_start..];
    const end_idx = std.mem.find(u8, remaining, ";") orelse remaining.len;
    const proxy_host = remaining[0..end_idx];

    if (std.mem.startsWith(u8, proxy_host, "proxy.")) {
        const api_host = proxy_host[6..];
        return std.fmt.allocPrint(allocator, "https://api.{s}", .{api_host}) catch null;
    }

    return std.fmt.allocPrint(allocator, "https://{s}", .{proxy_host}) catch null;
}

pub fn isSafeProviderDataValue(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (c == '"' or c == '\\' or c < 0x20) return false;
    }
    return true;
}

pub fn buildProviderData(
    allocator: std.mem.Allocator,
    enterprise_url: ?[]const u8,
    base_url: ?[]const u8,
    models: ?[]const []const u8,
) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var wrote_any = false;

    if (enterprise_url) |url| {
        if (isSafeProviderDataValue(url)) {
            try out.appendSlice(allocator, "\"enterpriseUrl\":\"");
            try out.appendSlice(allocator, url);
            try out.append(allocator, '"');
            wrote_any = true;
        }
    }

    if (base_url) |url| {
        if (isSafeProviderDataValue(url)) {
            if (wrote_any) try out.append(allocator, ',');
            try out.appendSlice(allocator, "\"baseUrl\":\"");
            try out.appendSlice(allocator, url);
            try out.append(allocator, '"');
            wrote_any = true;
        }
    }

    if (models) |list| {
        var written: usize = 0;
        for (list) |id| {
            if (!isSafeProviderDataValue(id)) continue;
            if (written == 0) {
                if (wrote_any) try out.append(allocator, ',');
                try out.appendSlice(allocator, "\"models\":[");
            } else {
                try out.append(allocator, ',');
            }
            try out.append(allocator, '"');
            try out.appendSlice(allocator, id);
            try out.append(allocator, '"');
            written += 1;
        }
        if (written > 0) {
            try out.append(allocator, ']');
            wrote_any = true;
        }
    }

    if (!wrote_any) {
        out.deinit(allocator);
        return null;
    }
    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

pub const oauth_request_timeout_ms: u64 = 30_000;

pub const DEFAULT_BASE_URL = "https://api.individual.githubcopilot.com";

pub fn getDefaultBaseUrl(allocator: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(allocator, DEFAULT_BASE_URL, .{}) catch DEFAULT_BASE_URL;
}

pub fn enableModel(
    allocator: std.mem.Allocator,
    token: []const u8,
    model_id: []const u8,
    base_url: []const u8,
) !bool {
    const url = try std.fmt.allocPrint(allocator, "{s}/models/{s}/policy", .{ base_url, model_id });
    defer allocator.free(url);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "authorization", .value = auth_header });
    try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });
    try headers.append(allocator, .{ .name = "openai-intent", .value = "chat-policy" });
    try headers.append(allocator, .{ .name = "x-interaction-type", .value = "chat-policy" });

    var fetched = http.fetch(allocator, url, .{
        .method = .POST,
        .extra_headers = headers.items,
        .body = "{\"state\": \"enabled\"}",
        .max_response_bytes = 8192,
        .timeout_ms = oauth_request_timeout_ms,
    }) catch return false;
    defer fetched.deinit(allocator);

    return fetched.status == 200;
}

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

pub fn login(callbacks: Callbacks, allocator: std.mem.Allocator) !Credentials {
    const domain_input = callbacks.onPrompt(.{
        .message = "GitHub domain (press Enter for github.com):",
        .allow_empty = true,
    });
    const github_domain = if (domain_input.len == 0) "github.com" else domain_input;
    defer if (domain_input.len > 0) allocator.free(domain_input);

    const device_response = try startDeviceFlow(github_domain, allocator);
    defer allocator.free(device_response.device_code);
    defer allocator.free(device_response.user_code);
    defer allocator.free(device_response.verification_uri);

    const instructions = try std.fmt.allocPrint(allocator, "Enter code: {s}", .{device_response.user_code});
    defer allocator.free(instructions);

    callbacks.onAuth(.{
        .url = device_response.verification_uri,
        .instructions = instructions,
    });

    var interval_ms: u64 = device_response.interval * 1000;
    const deadline = compat.time.nowMillis() + (@as(i64, device_response.expires_in) * 1000);

    while (compat.time.nowMillis() < deadline) {
        const poll_result = try pollForToken(github_domain, device_response.device_code, allocator);
        defer if (poll_result.access_token) |t| allocator.free(t);
        defer if (poll_result.error_msg) |msg| allocator.free(msg);

        if (poll_result.access_token) |github_token| {
            const copilot_token = try getCopilotToken(github_domain, github_token, allocator);

            const base_url = getBaseUrlFromToken(copilot_token, allocator);

            const enterprise_url = if (!std.mem.eql(u8, github_domain, "github.com"))
                try std.fmt.allocPrint(allocator, "https://{s}", .{github_domain})
            else
                null;

            defer if (enterprise_url) |url| allocator.free(url);

            const resolved_base_url = base_url orelse DEFAULT_BASE_URL;
            const enabled_models = try enableAllModels(allocator, copilot_token, resolved_base_url, null);

            const provider_data = try buildProviderData(allocator, enterprise_url, resolved_base_url, enabled_models);

            const result_base_url = if (base_url) |bu| try allocator.dupe(u8, bu) else null;
            errdefer if (result_base_url) |value| allocator.free(value);

            if (base_url) |bu| allocator.free(bu);

            return .{
                .refresh = try allocator.dupe(u8, github_token),
                .access = copilot_token,
                .expires = compat.time.nowMillis() + (3600 * 1000),
                .provider_data = provider_data,
                .enabled_models = enabled_models,
                .base_url = result_base_url,
            };
        }

        if (poll_result.error_msg) |err_msg| {
            if (std.mem.eql(u8, err_msg, "authorization_pending")) {
                compat.time.sleepNs(interval_ms * std.time.ns_per_ms);
                continue;
            } else if (std.mem.eql(u8, err_msg, "slow_down")) {
                interval_ms += 5000;
                compat.time.sleepNs(interval_ms * std.time.ns_per_ms);
                continue;
            } else {
                return error.OAuthFailed;
            }
        }
    }

    return error.OAuthTimeout;
}

pub fn refreshToken(credentials: Credentials, allocator: std.mem.Allocator) !Credentials {
    const github_domain = if (credentials.provider_data) |data| blk: {
        if (std.mem.find(u8, data, "enterpriseUrl")) |_| {
            if (std.mem.find(u8, data, "https://")) |idx| {
                const start = idx + 8;
                const end = std.mem.findScalar(u8, data[start..], '"') orelse data.len - start;
                break :blk data[start .. start + end];
            }
        }
        break :blk "github.com";
    } else "github.com";

    const copilot_token = try getCopilotToken(github_domain, credentials.refresh, allocator);

    const base_url = getBaseUrlFromToken(copilot_token, allocator);

    const resolved_base_url = base_url orelse DEFAULT_BASE_URL;
    const enabled_models = try enableAllModels(allocator, copilot_token, resolved_base_url, null);

    const enterprise_url = if (std.mem.eql(u8, github_domain, "github.com"))
        null
    else
        try std.fmt.allocPrint(allocator, "https://{s}", .{github_domain});
    defer if (enterprise_url) |url| allocator.free(url);

    const provider_data = try buildProviderData(allocator, enterprise_url, resolved_base_url, enabled_models);

    const result_base_url = if (base_url) |bu| try allocator.dupe(u8, bu) else null;

    if (base_url) |bu| allocator.free(bu);

    return .{
        .refresh = try allocator.dupe(u8, credentials.refresh),
        .access = copilot_token,
        .expires = compat.time.nowMillis() + (3600 * 1000),
        .provider_data = provider_data,
        .enabled_models = enabled_models,
        .base_url = result_base_url,
    };
}

pub fn getApiKey(credentials: Credentials, allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(u8, credentials.access);
}

pub fn inferCopilotInitiator(messages: []const ai_types.Message) []const u8 {
    if (messages.len == 0) return "user";
    const last = messages[messages.len - 1];
    return switch (last) {
        .assistant => "agent",
        else => "user",
    };
}

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

fn startDeviceFlow(domain: []const u8, allocator: std.mem.Allocator) !DeviceCodeResponse {
    const url = if (std.mem.eql(u8, domain, "github.com"))
        device_code_url
    else
        try std.fmt.allocPrint(allocator, "https://{s}/login/device/code", .{domain});
    defer if (!std.mem.eql(u8, domain, "github.com")) allocator.free(@constCast(url));

    const body = try std.fmt.allocPrint(allocator, "client_id={s}&scope=user:email", .{client_id});
    defer allocator.free(body);

    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "content-type", .value = "application/x-www-form-urlencoded" });

    var fetched = http.fetch(allocator, url, .{
        .method = .POST,
        .extra_headers = headers.items,
        .body = body,
        .max_response_bytes = 8192,
        .timeout_ms = oauth_request_timeout_ms,
    }) catch return error.OAuthFailed;
    defer fetched.deinit(allocator);

    if (fetched.status != 200) return error.OAuthFailed;
    const response_body = fetched.body;

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

fn pollForToken(domain: []const u8, device_code: []const u8, allocator: std.mem.Allocator) !PollResult {
    const url = if (std.mem.eql(u8, domain, "github.com"))
        token_url
    else
        try std.fmt.allocPrint(allocator, "https://{s}/login/oauth/access_token", .{domain});
    defer if (!std.mem.eql(u8, domain, "github.com")) allocator.free(@constCast(url));

    const body = try std.fmt.allocPrint(
        allocator,
        "client_id={s}&device_code={s}&grant_type=urn:ietf:params:oauth:grant-type:device_code",
        .{ client_id, device_code },
    );
    defer allocator.free(body);

    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "content-type", .value = "application/x-www-form-urlencoded" });

    var fetched = http.fetch(allocator, url, .{
        .method = .POST,
        .extra_headers = headers.items,
        .body = body,
        .max_response_bytes = 8192,
        .timeout_ms = oauth_request_timeout_ms,
    }) catch {
        return .{ .error_msg = try allocator.dupe(u8, "http_error") };
    };
    defer fetched.deinit(allocator);

    if (fetched.status != 200) {
        return .{
            .error_msg = try allocator.dupe(u8, "http_error"),
        };
    }

    const response_body = fetched.body;

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

fn getCopilotToken(domain: []const u8, github_token: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const url = if (std.mem.eql(u8, domain, "github.com"))
        copilot_token_url
    else
        try std.fmt.allocPrint(allocator, "https://{s}/copilot_internal/v2/token", .{domain});
    defer if (!std.mem.eql(u8, domain, "github.com")) allocator.free(@constCast(url));

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{github_token});
    defer allocator.free(auth_header);

    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "authorization", .value = auth_header });
    try headers.append(allocator, .{ .name = "accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "editor-version", .value = COPILOT_HEADERS.editor_version });
    try headers.append(allocator, .{ .name = "editor-plugin-version", .value = COPILOT_HEADERS.editor_plugin_version });
    try headers.append(allocator, .{ .name = "user-agent", .value = COPILOT_HEADERS.user_agent });
    try headers.append(allocator, .{ .name = "copilot-integration-id", .value = COPILOT_HEADERS.copilot_integration_id });

    var fetched = http.fetch(allocator, url, .{
        .method = .GET,
        .extra_headers = headers.items,
        .max_response_bytes = 8192,
        .timeout_ms = oauth_request_timeout_ms,
    }) catch return error.CopilotTokenFailed;
    defer fetched.deinit(allocator);

    if (fetched.status != 200) return error.CopilotTokenFailed;

    const response_body = fetched.body;

    const parsed = std.json.parseFromSlice(
        struct {
            token: []const u8,
        },
        allocator,
        response_body,
        .{ .ignore_unknown_fields = true },
    ) catch {
        const trimmed = std.mem.trim(u8, response_body, " \r\n\t\"");
        if (std.mem.find(u8, trimmed, "tid=") != null or
            std.mem.find(u8, trimmed, "proxy-ep=") != null)
        {
            return try allocator.dupe(u8, trimmed);
        }
        return error.CopilotTokenFailed;
    };
    defer parsed.deinit();

    return try allocator.dupe(u8, parsed.value.token);
}

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
        .expires = compat.time.nowMillis() + 3600000,
    };

    const api_key = try getApiKey(credentials, std.testing.allocator);
    defer std.testing.allocator.free(api_key);

    try std.testing.expectEqualStrings("copilot_token", api_key);
}

test "KNOWN_COPILOT_MODELS - contains expected models" {
    const testing = std.testing;

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
    const response = startDeviceFlow("github.com", std.testing.allocator) catch |err| {
        if (err == error.OAuthFailed or err == error.ConnectionRefused or
            err == error.NetworkUnreachable or err == error.SyntaxError or
            err == error.UnexpectedToken)
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

test "buildProviderData emits enterprise url, base url and models in a stable order" {
    const testing = std.testing;
    const models = [_][]const u8{ "gpt-5", "claude-sonnet-4" };
    const data = (try buildProviderData(testing.allocator, "https://gh.acme.com", "https://api.acme.githubcopilot.com", &models)).?;
    defer testing.allocator.free(data);
    try testing.expectEqualStrings(
        "{\"enterpriseUrl\":\"https://gh.acme.com\",\"baseUrl\":\"https://api.acme.githubcopilot.com\",\"models\":[\"gpt-5\",\"claude-sonnet-4\"]}",
        data,
    );

    const domain = if (std.mem.find(u8, data, "enterpriseUrl")) |_| blk: {
        const idx = std.mem.find(u8, data, "https://").?;
        const start = idx + 8;
        const end = std.mem.findScalar(u8, data[start..], '"').?;
        break :blk data[start .. start + end];
    } else "github.com";
    try testing.expectEqualStrings("gh.acme.com", domain);
}

test "buildProviderData omits absent parts and returns null when nothing is left" {
    const testing = std.testing;
    const models = [_][]const u8{"gpt-5"};
    const only_models = (try buildProviderData(testing.allocator, null, null, &models)).?;
    defer testing.allocator.free(only_models);
    try testing.expectEqualStrings("{\"models\":[\"gpt-5\"]}", only_models);

    try testing.expect(try buildProviderData(testing.allocator, null, null, null) == null);
    try testing.expect(try buildProviderData(testing.allocator, null, null, &[_][]const u8{}) == null);
}

test "buildProviderData drops values that would break the json" {
    const testing = std.testing;
    const models = [_][]const u8{ "ok-model", "bad\"quote", "bad\\slash" };
    const data = (try buildProviderData(testing.allocator, null, null, &models)).?;
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("{\"models\":[\"ok-model\"]}", data);

    try testing.expect(!isSafeProviderDataValue("has\"quote"));
    try testing.expect(!isSafeProviderDataValue(""));
    try testing.expect(isSafeProviderDataValue("gpt-5.1-codex-max"));
}
