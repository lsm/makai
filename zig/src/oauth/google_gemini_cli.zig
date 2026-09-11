const std = @import("std");
const oauth = @import("mod.zig");
const pkce = @import("pkce.zig");
const compat = @import("compat");

const CLIENT_ID = "681255809391-oo8ft2oprdrbp9e3aqf6av3hmdib135j.apps.googleusercontent.com";

const CLIENT_SECRET = "GOCSpx-4uHgMPm-1o7Sk-geV6Cu5clXFsxl";

const AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL = "https://oauth2.googleapis.com/token";

const REDIRECT_PORT: u16 = 8085;
const REDIRECT_URI = "http://localhost:8085/callback";

const SCOPES = "https://www.googleapis.com/auth/cloud-platform";

const DEFAULT_PROJECT_ID = "rising-fact-p41fc";

pub const AuthInfo = struct {
    auth_url: []const u8,
    pkce_pair: pkce.PKCEPair,
    state: [32]u8,

    pub fn deinit(self: *AuthInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.auth_url);
    }
};

pub const GeminiCliError = error{
    NotImplemented,
    OutOfMemory,
    HttpError,
    InvalidResponse,
    AuthorizationFailed,
    TokenExchangeFailed,
    ProjectDiscoveryFailed,
    CallbackServerFailed,
};

pub const GoogleGeminiCliOAuth = struct {
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

    pub fn startAuth(self: *Self) GeminiCliError!AuthInfo {
        const pkce_pair = pkce.generatePKCE();
        const state = generateState();

        var url_buf: [2048]u8 = undefined;
        const auth_url = std.fmt.bufPrint(
            &url_buf,
            "{s}?client_id={s}&redirect_uri={s}&response_type=code&scope={s}&code_challenge={s}&code_challenge_method=S256&state={s}",
            .{ AUTHORIZE_URL, CLIENT_ID, REDIRECT_URI, SCOPES, pkce_pair.challenge, state },
        ) catch return GeminiCliError.OutOfMemory;

        const owned_url = self.allocator.dupe(u8, auth_url) catch return GeminiCliError.OutOfMemory;

        return AuthInfo{
            .auth_url = owned_url,
            .pkce_pair = pkce_pair,
            .state = state,
        };
    }

    pub fn exchangeCode(self: *Self, code: []const u8, pkce_pair: pkce.PKCEPair) GeminiCliError!oauth.OAuthCredentials {
        _ = self;
        _ = code;
        _ = pkce_pair;
        return GeminiCliError.NotImplemented;
    }

    pub fn discoverProject(self: *Self, access_token: []const u8) GeminiCliError![]const u8 {
        _ = access_token;
        return self.allocator.dupe(u8, DEFAULT_PROJECT_ID) catch GeminiCliError.OutOfMemory;
    }

    pub fn login(self: *Self) GeminiCliError!oauth.OAuthCredentials {
        _ = self;
        return GeminiCliError.NotImplemented;
    }

    pub fn refreshToken(self: *Self, refresh_token: []const u8) GeminiCliError!oauth.OAuthCredentials {
        _ = self;
        _ = refresh_token;
        return GeminiCliError.NotImplemented;
    }
};

test "GoogleGeminiCliOAuth init and deinit" {
    const allocator = std.testing.allocator;

    var oauth_provider = GoogleGeminiCliOAuth.init(allocator);
    defer oauth_provider.deinit();

    try std.testing.expectEqual(allocator, oauth_provider.allocator);
}

test "GoogleGeminiCliOAuth startAuth returns valid AuthInfo" {
    const allocator = std.testing.allocator;

    var oauth_provider = GoogleGeminiCliOAuth.init(allocator);
    defer oauth_provider.deinit();

    var auth_info = try oauth_provider.startAuth();
    defer auth_info.deinit(allocator);

    try std.testing.expect(auth_info.auth_url.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, auth_info.auth_url, "https://accounts.google.com"));
    try std.testing.expect(std.mem.find(u8, auth_info.auth_url, "code_challenge") != null);
}

test "GoogleGeminiCliOAuth login returns NotImplemented" {
    const allocator = std.testing.allocator;

    var oauth_provider = GoogleGeminiCliOAuth.init(allocator);
    defer oauth_provider.deinit();

    const result = oauth_provider.login();
    try std.testing.expectError(GeminiCliError.NotImplemented, result);
}

test "GoogleGeminiCliOAuth refreshToken returns NotImplemented" {
    const allocator = std.testing.allocator;

    var oauth_provider = GoogleGeminiCliOAuth.init(allocator);
    defer oauth_provider.deinit();

    const result = oauth_provider.refreshToken("test_refresh_token");
    try std.testing.expectError(GeminiCliError.NotImplemented, result);
}

test "GoogleGeminiCliOAuth discoverProject returns default project" {
    const allocator = std.testing.allocator;

    var oauth_provider = GoogleGeminiCliOAuth.init(allocator);
    defer oauth_provider.deinit();

    const project = try oauth_provider.discoverProject("test_token");
    defer allocator.free(project);

    try std.testing.expectEqualStrings(DEFAULT_PROJECT_ID, project);
}
