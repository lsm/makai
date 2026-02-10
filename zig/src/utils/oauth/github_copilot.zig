const std = @import("std");

const client_id = "Iv1.b507a08c87ecfe98";
const device_code_url = "https://github.com/login/device/code";
const token_url = "https://github.com/login/oauth/access_token";

pub const Credentials = struct {
    refresh: []const u8,
    access: []const u8,
    expires: i64,
    provider_data: ?[]const u8 = null,
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
    const deadline = std.time.milliTimestamp() + (device_response.expires_in * 1000);

    while (std.time.milliTimestamp() < deadline) {
        const poll_result = try pollForToken(github_domain, device_response.device_code, allocator);
        defer if (poll_result.access_token) |token| allocator.free(token);
        defer if (poll_result.error_msg) |msg| allocator.free(msg);

        if (poll_result.access_token) |github_token| {
            // 5. Exchange GitHub token for Copilot token
            const copilot_token = try getCopilotToken(github_domain, github_token, allocator);

            // 6. Parse enterprise URL if needed
            const enterprise_url = if (!std.mem.eql(u8, github_domain, "github.com"))
                try std.fmt.allocPrint(allocator, "https://{s}", .{github_domain})
            else
                null;

            const provider_data = if (enterprise_url) |url| blk: {
                defer allocator.free(url);
                break :blk try std.fmt.allocPrint(allocator, "{{\"enterpriseUrl\":\"{s}\"}}", .{url});
            } else null;

            return .{
                .refresh = try allocator.dupe(u8, github_token),
                .access = copilot_token,
                .expires = std.time.milliTimestamp() + (3600 * 1000), // 1 hour
                .provider_data = provider_data,
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
            // Extract domain from JSON (simplified)
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

    return .{
        .refresh = try allocator.dupe(u8, credentials.refresh),
        .access = copilot_token,
        .expires = std.time.milliTimestamp() + (3600 * 1000),
        .provider_data = if (credentials.provider_data) |data| try allocator.dupe(u8, data) else null,
    };
}

/// Get API key from credentials (access token IS the API key)
pub fn getApiKey(credentials: Credentials, allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(u8, credentials.access);
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
    _ = domain;
    // Real implementation would make HTTP POST
    // For now, return mock data for testing
    return .{
        .device_code = try allocator.dupe(u8, "mock_device_code"),
        .user_code = try allocator.dupe(u8, "ABCD-1234"),
        .verification_uri = try allocator.dupe(u8, "https://github.com/login/device"),
        .expires_in = 900, // 15 minutes
        .interval = 5, // 5 seconds
    };
}

const PollResult = struct {
    access_token: ?[]const u8 = null,
    error_msg: ?[]const u8 = null,
};

/// Poll for GitHub access token
fn pollForToken(domain: []const u8, device_code: []const u8, allocator: std.mem.Allocator) !PollResult {
    _ = domain;
    _ = device_code;
    // Real implementation would make HTTP POST
    // For now, return pending for testing
    return .{
        .error_msg = try allocator.dupe(u8, "authorization_pending"),
    };
}

/// Get Copilot token from GitHub token
fn getCopilotToken(domain: []const u8, github_token: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    _ = domain;
    _ = github_token;
    // Real implementation would make HTTP POST to Copilot API
    return try allocator.dupe(u8, "mock_copilot_token");
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

test "startDeviceFlow - returns valid response" {
    const response = try startDeviceFlow("github.com", std.testing.allocator);
    defer std.testing.allocator.free(response.device_code);
    defer std.testing.allocator.free(response.user_code);
    defer std.testing.allocator.free(response.verification_uri);

    try std.testing.expect(response.device_code.len > 0);
    try std.testing.expect(response.user_code.len > 0);
    try std.testing.expect(response.expires_in > 0);
    try std.testing.expect(response.interval > 0);
}
