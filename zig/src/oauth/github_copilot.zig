const std = @import("std");
const compat = @import("compat");
const http = compat.http;
const oauth = @import("mod.zig");

const CLIENT_ID = "Iv1.b507a08c87ecfe98";

const COPILOT_HEADERS = [_]std.http.Header{
    .{ .name = "editor-version", .value = "Neovim/0.9.0" },
    .{ .name = "editor-plugin-version", .value = "copilot.vim/1.0.0" },
    .{ .name = "user-agent", .value = "GithubCopilot/1.0.0" },
};

pub const DeviceFlowInfo = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    expires_in: u32,
    interval: u32,

    pub fn deinit(self: *DeviceFlowInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.device_code);
        allocator.free(self.user_code);
        allocator.free(self.verification_uri);
    }
};

pub const CopilotToken = struct {
    token: []const u8,
    expires_at: i64,
    base_url: ?[]const u8,

    pub fn deinit(self: *CopilotToken, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        if (self.base_url) |url| allocator.free(url);
    }
};

pub const CopilotError = error{
    DeviceFlowFailed,
    AuthorizationPending,
    SlowDown,
    ExpiredToken,
    AccessDenied,
    InvalidResponse,
    TokenExchangeFailed,
    HttpError,
    OutOfMemory,
};

pub const GitHubCopilotOAuth = struct {
    allocator: std.mem.Allocator,
    enterprise_domain: ?[]const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, enterprise_domain: ?[]const u8) Self {
        return .{
            .allocator = allocator,
            .enterprise_domain = if (enterprise_domain) |d| allocator.dupe(u8, d) catch null else null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.enterprise_domain) |d| self.allocator.free(d);
    }

    fn getDomain(self: *const Self) []const u8 {
        return self.enterprise_domain orelse "github.com";
    }

    fn getDeviceCodeUrl(self: *const Self, buffer: []u8) ![]u8 {
        const domain = self.getDomain();
        return std.fmt.bufPrint(buffer, "https://{s}/login/device/code", .{domain});
    }

    fn getAccessTokenUrl(self: *const Self, buffer: []u8) ![]u8 {
        const domain = self.getDomain();
        return std.fmt.bufPrint(buffer, "https://{s}/login/oauth/access_token", .{domain});
    }

    fn getCopilotTokenUrl(self: *const Self, buffer: []u8) ![]u8 {
        const domain = self.getDomain();
        return std.fmt.bufPrint(buffer, "https://api.{s}/copilot_internal/v2/token", .{domain});
    }

    pub fn startDeviceFlow(self: *Self) CopilotError!DeviceFlowInfo {
        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        var url_buf: [256]u8 = undefined;
        const url = try self.getDeviceCodeUrl(&url_buf);
        const uri = std.Uri.parse(url) catch return CopilotError.InvalidResponse;

        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "client_id={s}&scope=read:user", .{CLIENT_ID}) catch return CopilotError.OutOfMemory;

        var headers = std.ArrayList(std.http.Header).initCapacity(self.allocator, 4) catch return CopilotError.OutOfMemory;
        defer headers.deinit(self.allocator);
        headers.appendAssumeCapacity(.{ .name = "accept", .value = "application/json" });
        headers.appendAssumeCapacity(.{ .name = "content-type", .value = "application/x-www-form-urlencoded" });
        headers.appendAssumeCapacity(.{ .name = "user-agent", .value = "GitHubCopilot/1.0.0" });

        var req = client.openRequest(.POST, uri, .{ .extra_headers = headers.items }) catch return CopilotError.HttpError;
        defer req.deinit();

        http.sendRequest(&req, body) catch return CopilotError.HttpError;

        var head_buf: [4096]u8 = undefined;
        var response = http.receiveResponse(&req, &head_buf) catch return CopilotError.HttpError;

        if (response.head.status != .ok) return CopilotError.DeviceFlowFailed;

        var transfer_buf: [4096]u8 = undefined;
        const reader = http.responseReader(&response, &transfer_buf);
        const response_body = http.allocRemainingResponse(self.allocator, reader, 8192) catch return CopilotError.HttpError;
        defer self.allocator.free(response_body);

        return self.parseDeviceCodeResponse(response_body);
    }

    fn parseDeviceCodeResponse(self: *Self, body: []const u8) CopilotError!DeviceFlowInfo {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return CopilotError.InvalidResponse;
        defer parsed.deinit();

        if (parsed.value != .object) return CopilotError.InvalidResponse;
        const obj = parsed.value.object;

        if (obj.get("error")) |err_val| {
            if (err_val == .string) {
                _ = err_val.string;
            }
            return CopilotError.DeviceFlowFailed;
        }

        const device_code = obj.get("device_code") orelse return CopilotError.InvalidResponse;
        const user_code = obj.get("user_code") orelse return CopilotError.InvalidResponse;
        const verification_uri = obj.get("verification_uri") orelse return CopilotError.InvalidResponse;
        const interval = obj.get("interval") orelse return CopilotError.InvalidResponse;
        const expires_in = obj.get("expires_in") orelse return CopilotError.InvalidResponse;

        if (device_code != .string or user_code != .string or verification_uri != .string) {
            return CopilotError.InvalidResponse;
        }

        const interval_int: u32 = if (interval == .integer) @intCast(interval.integer) else 5;
        const expires_int: u32 = if (expires_in == .integer) @intCast(expires_in.integer) else 900;

        return DeviceFlowInfo{
            .device_code = self.allocator.dupe(u8, device_code.string) catch return CopilotError.OutOfMemory,
            .user_code = self.allocator.dupe(u8, user_code.string) catch return CopilotError.OutOfMemory,
            .verification_uri = self.allocator.dupe(u8, verification_uri.string) catch return CopilotError.OutOfMemory,
            .interval = interval_int,
            .expires_in = expires_int,
        };
    }

    pub fn pollForAccessToken(self: *Self, device_code: []const u8) CopilotError!?oauth.OAuthCredentials {
        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        var url_buf: [256]u8 = undefined;
        const url = try self.getAccessTokenUrl(&url_buf);
        const uri = std.Uri.parse(url) catch return CopilotError.InvalidResponse;

        var body_buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "client_id={s}&device_code={s}&grant_type=urn:ietf:params:oauth:grant-type:device_code",
            .{ CLIENT_ID, device_code },
        ) catch return CopilotError.OutOfMemory;

        var headers = std.ArrayList(std.http.Header).initCapacity(self.allocator, 4) catch return CopilotError.OutOfMemory;
        defer headers.deinit(self.allocator);
        headers.appendAssumeCapacity(.{ .name = "accept", .value = "application/json" });
        headers.appendAssumeCapacity(.{ .name = "content-type", .value = "application/x-www-form-urlencoded" });
        headers.appendAssumeCapacity(.{ .name = "user-agent", .value = "GitHubCopilot/1.0.0" });

        var req = client.openRequest(.POST, uri, .{ .extra_headers = headers.items }) catch return CopilotError.HttpError;
        defer req.deinit();

        http.sendRequest(&req, body) catch return CopilotError.HttpError;

        var head_buf: [4096]u8 = undefined;
        var response = http.receiveResponse(&req, &head_buf) catch return CopilotError.HttpError;

        if (response.head.status != .ok) return CopilotError.HttpError;

        var transfer_buf: [4096]u8 = undefined;
        const reader = http.responseReader(&response, &transfer_buf);
        const response_body = http.allocRemainingResponse(self.allocator, reader, 8192) catch return CopilotError.HttpError;
        defer self.allocator.free(response_body);

        return self.parseAccessTokenResponse(response_body);
    }

    fn parseAccessTokenResponse(self: *Self, body: []const u8) CopilotError!?oauth.OAuthCredentials {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return CopilotError.InvalidResponse;
        defer parsed.deinit();

        if (parsed.value != .object) return CopilotError.InvalidResponse;
        const obj = parsed.value.object;

        if (obj.get("error")) |err_val| {
            if (err_val == .string) {
                const err_str = err_val.string;
                if (std.mem.eql(u8, err_str, "authorization_pending")) {
                    return CopilotError.AuthorizationPending;
                }
                if (std.mem.eql(u8, err_str, "slow_down")) {
                    return CopilotError.SlowDown;
                }
                if (std.mem.eql(u8, err_str, "expired_token")) {
                    return CopilotError.ExpiredToken;
                }
                if (std.mem.eql(u8, err_str, "access_denied")) {
                    return CopilotError.AccessDenied;
                }
            }
            return CopilotError.DeviceFlowFailed;
        }

        const access_token = obj.get("access_token") orelse return null;
        if (access_token != .string) return CopilotError.InvalidResponse;

        const token = self.allocator.dupe(u8, access_token.string) catch return CopilotError.OutOfMemory;
        errdefer self.allocator.free(token);

        const refresh_token = self.allocator.dupe(u8, access_token.string) catch {
            self.allocator.free(token);
            return CopilotError.OutOfMemory;
        };

        return oauth.OAuthCredentials{
            .access = token,
            .refresh = refresh_token,
            .expires = accessTokenExpiresMillis(compat.time.nowSeconds()),
        };
    }

    pub fn exchangeForCopilotToken(self: *Self, access_token: []const u8) CopilotError!CopilotToken {
        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        var url_buf: [256]u8 = undefined;
        const url = try self.getCopilotTokenUrl(&url_buf);
        const uri = std.Uri.parse(url) catch return CopilotError.InvalidResponse;

        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{access_token}) catch return CopilotError.OutOfMemory;

        var headers = std.ArrayList(std.http.Header).initCapacity(self.allocator, COPILOT_HEADERS.len + 2) catch return CopilotError.OutOfMemory;
        defer headers.deinit(self.allocator);
        headers.appendAssumeCapacity(.{ .name = "authorization", .value = auth_header });
        headers.appendAssumeCapacity(.{ .name = "accept", .value = "application/json" });
        for (COPILOT_HEADERS) |h| {
            headers.appendAssumeCapacity(h);
        }

        var req = client.openRequest(.GET, uri, .{ .extra_headers = headers.items }) catch return CopilotError.HttpError;
        defer req.deinit();

        http.sendBodilessRequest(&req) catch return CopilotError.HttpError;

        var head_buf: [4096]u8 = undefined;
        var response = http.receiveResponse(&req, &head_buf) catch return CopilotError.HttpError;

        if (response.head.status != .ok) return CopilotError.TokenExchangeFailed;

        var transfer_buf: [4096]u8 = undefined;
        const reader = http.responseReader(&response, &transfer_buf);
        const response_body = http.allocRemainingResponse(self.allocator, reader, 8192) catch return CopilotError.HttpError;
        defer self.allocator.free(response_body);

        return self.parseCopilotTokenResponse(response_body);
    }

    fn parseCopilotTokenResponse(self: *Self, body: []const u8) CopilotError!CopilotToken {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return CopilotError.InvalidResponse;
        defer parsed.deinit();

        if (parsed.value != .object) return CopilotError.InvalidResponse;
        const obj = parsed.value.object;

        const token_val = obj.get("token") orelse return CopilotError.InvalidResponse;
        const expires_at_val = obj.get("expires_at") orelse return CopilotError.InvalidResponse;

        if (token_val != .string) return CopilotError.InvalidResponse;
        const expires_at: i64 = if (expires_at_val == .integer) expires_at_val.integer else compat.time.nowSeconds() + 3600;

        const token = self.allocator.dupe(u8, token_val.string) catch return CopilotError.OutOfMemory;
        errdefer self.allocator.free(token);

        const base_url = extractBaseUrlFromToken(token_val.string);
        const base_url_duped = if (base_url) |url| self.allocator.dupe(u8, url) catch null else null;

        return CopilotToken{
            .token = token,
            .expires_at = expires_at,
            .base_url = base_url_duped,
        };
    }

    pub fn login(
        self: *Self,
        onAuth: *const fn (verification_uri: []const u8, user_code: []const u8) void,
    ) CopilotError!oauth.OAuthCredentials {
        var device_info = try self.startDeviceFlow();
        defer device_info.deinit(self.allocator);

        onAuth(device_info.verification_uri, device_info.user_code);

        var interval_ms: u64 = @as(u64, device_info.interval) * 1000;
        const deadline = compat.time.nowSeconds() + device_info.expires_in;

        while (compat.time.nowSeconds() < deadline) {
            compat.time.sleepMs(interval_ms);

            const result = self.pollForAccessToken(device_info.device_code) catch |err| {
                switch (err) {
                    CopilotError.AuthorizationPending => continue,
                    CopilotError.SlowDown => {
                        interval_ms += 5000;
                        continue;
                    },
                    else => return err,
                }
            };

            if (result) |creds| {
                return creds;
            }
        }

        return CopilotError.ExpiredToken;
    }

    pub fn refreshToken(self: *Self, refresh_token: []const u8) CopilotError!oauth.OAuthCredentials {
        const copilot_token = try self.exchangeForCopilotToken(refresh_token);

        return oauth.OAuthCredentials{
            .access = self.allocator.dupe(u8, copilot_token.token) catch return CopilotError.OutOfMemory,
            .refresh = self.allocator.dupe(u8, refresh_token) catch return CopilotError.OutOfMemory,
            .expires = copilotTokenRefreshExpiresMillis(copilot_token.expires_at),
        };
    }

    pub fn enableModel(self: *Self, token: []const u8, model_id: []const u8) !bool {
        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        const base_url = if (self.enterprise_domain) |domain|
            try std.fmt.allocPrint(self.allocator, "https://copilot-api.{s}", .{domain})
        else
            try self.allocator.dupe(u8, "https://api.individual.githubcopilot.com");
        defer self.allocator.free(base_url);

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/models/{s}/policy", .{ base_url, model_id }) catch return false;
        const uri = std.Uri.parse(url) catch return false;

        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return false;

        var headers = std.ArrayList(std.http.Header).initCapacity(self.allocator, COPILOT_HEADERS.len + 4) catch return false;
        defer headers.deinit(self.allocator);
        headers.appendAssumeCapacity(.{ .name = "authorization", .value = auth_header });
        headers.appendAssumeCapacity(.{ .name = "content-type", .value = "application/json" });
        headers.appendAssumeCapacity(.{ .name = "openai-intent", .value = "chat-policy" });
        headers.appendAssumeCapacity(.{ .name = "x-interaction-type", .value = "chat-policy" });
        for (COPILOT_HEADERS) |h| {
            headers.appendAssumeCapacity(h);
        }

        var req = client.openRequest(.POST, uri, .{ .extra_headers = headers.items }) catch return false;
        defer req.deinit();

        const body = "{\"state\":\"enabled\"}";
        http.sendRequest(&req, body) catch return false;

        var head_buf: [4096]u8 = undefined;
        const response = http.receiveResponse(&req, &head_buf) catch return false;

        return response.head.status == .ok or response.head.status == .created or response.head.status == .no_content;
    }
};

fn accessTokenExpiresMillis(now_seconds: i64) i64 {
    return (now_seconds + 3600 - 300) * std.time.ms_per_s;
}

fn copilotTokenRefreshExpiresMillis(expires_at_seconds: i64) i64 {
    return expires_at_seconds * std.time.ms_per_s - 5 * std.time.s_per_min * std.time.ms_per_s;
}

pub fn extractBaseUrlFromToken(token: []const u8) ?[]const u8 {
    const prefix = "proxy-ep=";
    const start_idx = std.mem.find(u8, token, prefix) orelse return null;
    const value_start = start_idx + prefix.len;

    const remaining = token[value_start..];
    const end_idx = std.mem.find(u8, remaining, ";") orelse remaining.len;

    const proxy_host = remaining[0..end_idx];
    if (proxy_host.len == 0) return null;

    if (!std.mem.startsWith(u8, proxy_host, "proxy.")) return null;

    const api_host = proxy_host["proxy".len..];

    return api_host;
}

pub fn getCopilotBaseUrl(token: ?[]const u8, enterprise_domain: ?[]const u8, buffer: []u8) ?[]u8 {
    if (token) |t| {
        if (extractBaseUrlFromToken(t)) |api_host| {
            return std.fmt.bufPrint(buffer, "https://api{s}", .{api_host}) catch null;
        }
    }

    if (enterprise_domain) |domain| {
        return std.fmt.bufPrint(buffer, "https://copilot-api.{s}", .{domain}) catch null;
    }

    return std.fmt.bufPrint(buffer, "https://api.individual.githubcopilot.com", .{}) catch null;
}

pub fn normalizeDomain(input: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    if (trimmed.len == 0) return null;

    if (std.mem.find(u8, trimmed, "://")) |idx| {
        const after_scheme = trimmed[idx + 3 ..];
        if (std.mem.find(u8, after_scheme, "/")) |slash_idx| {
            return after_scheme[0..slash_idx];
        }
        return after_scheme;
    }

    if (std.mem.find(u8, trimmed, "/")) |slash_idx| {
        return trimmed[0..slash_idx];
    }

    return trimmed;
}

test "OAuth token expiry arithmetic preserves second-to-millisecond behavior" {
    const cases = [_]struct { now_seconds: i64, expected_expires_ms: i64 }{
        .{ .now_seconds = 0, .expected_expires_ms = 3_300_000 },
        .{ .now_seconds = 1, .expected_expires_ms = 3_301_000 },
        .{ .now_seconds = 1_609_459_200, .expected_expires_ms = 1_609_462_500_000 },
        .{ .now_seconds = 4_102_444_800, .expected_expires_ms = 4_102_448_100_000 },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected_expires_ms, accessTokenExpiresMillis(case.now_seconds));
    }
}

test "Copilot token refresh expiry keeps five minute buffer" {
    const cases = [_]struct { expires_at_seconds: i64, expected_refresh_ms: i64 }{
        .{ .expires_at_seconds = 300, .expected_refresh_ms = 0 },
        .{ .expires_at_seconds = 301, .expected_refresh_ms = 1_000 },
        .{ .expires_at_seconds = 1_609_459_200, .expected_refresh_ms = 1_609_458_900_000 },
        .{ .expires_at_seconds = 4_102_444_800, .expected_refresh_ms = 4_102_444_500_000 },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected_refresh_ms, copilotTokenRefreshExpiresMillis(case.expires_at_seconds));
    }
}

test "extractBaseUrlFromToken extracts proxy endpoint" {
    const token = "tid=abc123;exp=1234567890;proxy-ep=proxy.individual.githubcopilot.com;other=stuff";
    const result = extractBaseUrlFromToken(token);
    try std.testing.expect(result != null);
    if (result) |r| {
        try std.testing.expectEqualStrings(".individual.githubcopilot.com", r);
    }
}

test "extractBaseUrlFromToken returns null for invalid token" {
    try std.testing.expect(extractBaseUrlFromToken("invalid") == null);
    try std.testing.expect(extractBaseUrlFromToken("tid=abc;exp=123") == null);
    try std.testing.expect(extractBaseUrlFromToken("") == null);
}

test "getCopilotBaseUrl builds correct URL from token" {
    var buf: [256]u8 = undefined;
    const token = "tid=abc;proxy-ep=proxy.individual.githubcopilot.com;";
    const result = getCopilotBaseUrl(token, null, &buf);
    try std.testing.expect(result != null);
    if (result) |r| {
        try std.testing.expectEqualStrings("https://api.individual.githubcopilot.com", r);
    }
}

test "getCopilotBaseUrl falls back to enterprise domain" {
    var buf: [256]u8 = undefined;
    const result = getCopilotBaseUrl(null, "github.example.com", &buf);
    try std.testing.expect(result != null);
    if (result) |r| {
        try std.testing.expectEqualStrings("https://copilot-api.github.example.com", r);
    }
}

test "getCopilotBaseUrl uses default for null inputs" {
    var buf: [256]u8 = undefined;
    const result = getCopilotBaseUrl(null, null, &buf);
    try std.testing.expect(result != null);
    if (result) |r| {
        try std.testing.expectEqualStrings("https://api.individual.githubcopilot.com", r);
    }
}

test "normalizeDomain extracts hostname from URL" {
    try std.testing.expectEqualStrings("github.com", normalizeDomain("https://github.com/path").?);
    try std.testing.expectEqualStrings("github.com", normalizeDomain("http://github.com").?);
    try std.testing.expectEqualStrings("github.com", normalizeDomain("github.com/path").?);
    try std.testing.expectEqualStrings("github.com", normalizeDomain("github.com").?);
    try std.testing.expect(normalizeDomain("") == null);
    try std.testing.expect(normalizeDomain("   ") == null);
}

test "GitHubCopilotOAuth init and deinit" {
    const allocator = std.testing.allocator;

    var oauth_provider = GitHubCopilotOAuth.init(allocator, "github.example.com");
    defer oauth_provider.deinit();

    try std.testing.expect(oauth_provider.enterprise_domain != null);
    try std.testing.expectEqualStrings("github.example.com", oauth_provider.enterprise_domain.?);
}

test "GitHubCopilotOAuth uses github.com by default" {
    const allocator = std.testing.allocator;

    var oauth_provider = GitHubCopilotOAuth.init(allocator, null);
    defer oauth_provider.deinit();

    try std.testing.expect(oauth_provider.enterprise_domain == null);
    try std.testing.expectEqualStrings("github.com", oauth_provider.getDomain());
}
