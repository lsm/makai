const std = @import("std");
const oauth = @import("mod.zig");
const pkce = @import("pkce.zig");
const compat = @import("compat");

const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";

const AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize";
const TOKEN_URL = "https://auth.openai.com/oauth/token";

const REDIRECT_PORT: u16 = 1455;
const REDIRECT_URI = "http://localhost:1455/auth/callback";

const SCOPES = "openid profile email offline_access";

pub const AuthInfo = struct {
    auth_url: []const u8,
    pkce_pair: pkce.PKCEPair,
    state: [32]u8,

    pub fn deinit(self: *AuthInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.auth_url);
    }
};

pub const CodexError = error{
    NotImplemented,
    OutOfMemory,
    HttpError,
    InvalidResponse,
    AuthorizationFailed,
    TokenExchangeFailed,
    CallbackServerFailed,
    InvalidJwtToken,
};

pub const OpenAICodexOAuth = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    fn generateState() [32]u8 {
        var state: [32]u8 = undefined;
        compat.random.fillSecureBytes(&state);
        var hex_state: [32]u8 = undefined;
        for (state[0..16], 0..) |byte, i| {
            const hi = byte >> 4;
            const lo = byte & 0x0F;
            hex_state[i * 2] = if (hi < 10) '0' + hi else 'a' + (hi - 10);
            hex_state[i * 2 + 1] = if (lo < 10) '0' + lo else 'a' + (lo - 10);
        }
        return hex_state;
    }

    pub fn getAccountId(access_token: []const u8) ?[]const u8 {

        const first_dot = std.mem.find(u8, access_token, ".") orelse return null;
        const second_dot = std.mem.findPos(u8, access_token, first_dot + 1, ".") orelse return null;

        const payload_b64 = access_token[first_dot + 1 .. second_dot];

        _ = payload_b64;
        return null;
    }

    pub fn startAuth(self: *Self) CodexError!AuthInfo {
        const pkce_pair = pkce.generatePKCE();
        const state = generateState();

        var url_buf: [2048]u8 = undefined;
        const auth_url = std.fmt.bufPrint(
            &url_buf,
            "{s}?client_id={s}&redirect_uri={s}&response_type=code&scope={s}&code_challenge={s}&code_challenge_method=S256&state={s}&audience=https://api.openai.com/v1",
            .{ AUTHORIZE_URL, CLIENT_ID, REDIRECT_URI, SCOPES, pkce_pair.challenge, state },
        ) catch return CodexError.OutOfMemory;

        const owned_url = self.allocator.dupe(u8, auth_url) catch return CodexError.OutOfMemory;

        return AuthInfo{
            .auth_url = owned_url,
            .pkce_pair = pkce_pair,
            .state = state,
        };
    }

    pub fn exchangeCode(self: *Self, code: []const u8, pkce_pair: pkce.PKCEPair) CodexError!oauth.OAuthCredentials {
        _ = self;
        _ = code;
        _ = pkce_pair;
        return CodexError.NotImplemented;
    }

    pub fn login(self: *Self) CodexError!oauth.OAuthCredentials {
        _ = self;
        return CodexError.NotImplemented;
    }

    pub fn refreshToken(self: *Self, refresh_token: []const u8) CodexError!oauth.OAuthCredentials {
        _ = self;
        _ = refresh_token;
        return CodexError.NotImplemented;
    }
};

test "OpenAICodexOAuth init and deinit" {
    const allocator = std.testing.allocator;

    var oauth_provider = OpenAICodexOAuth.init(allocator);
    defer oauth_provider.deinit();

    try std.testing.expectEqual(allocator, oauth_provider.allocator);
}

test "OpenAICodexOAuth startAuth returns valid AuthInfo" {
    const allocator = std.testing.allocator;

    var oauth_provider = OpenAICodexOAuth.init(allocator);
    defer oauth_provider.deinit();

    var auth_info = try oauth_provider.startAuth();
    defer auth_info.deinit(allocator);

    try std.testing.expect(auth_info.auth_url.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, auth_info.auth_url, "https://auth.openai.com"));
    try std.testing.expect(std.mem.find(u8, auth_info.auth_url, "1455") != null);
    try std.testing.expect(std.mem.find(u8, auth_info.auth_url, "code_challenge") != null);
}

test "OpenAICodexOAuth login returns NotImplemented" {
    const allocator = std.testing.allocator;

    var oauth_provider = OpenAICodexOAuth.init(allocator);
    defer oauth_provider.deinit();

    const result = oauth_provider.login();
    try std.testing.expectError(CodexError.NotImplemented, result);
}

test "OpenAICodexOAuth refreshToken returns NotImplemented" {
    const allocator = std.testing.allocator;

    var oauth_provider = OpenAICodexOAuth.init(allocator);
    defer oauth_provider.deinit();

    const result = oauth_provider.refreshToken("test_refresh_token");
    try std.testing.expectError(CodexError.NotImplemented, result);
}

test "OpenAICodexOAuth getAccountId returns null for invalid JWT" {
    try std.testing.expect(OpenAICodexOAuth.getAccountId("invalid") == null);
    try std.testing.expect(OpenAICodexOAuth.getAccountId("") == null);
    try std.testing.expect(OpenAICodexOAuth.getAccountId("no.dots") == null);
}

test "OpenAICodexOAuth getAccountId returns null for non-JWT format" {
    try std.testing.expect(OpenAICodexOAuth.getAccountId("header.payload.signature") == null);
}
