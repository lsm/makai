const std = @import("std");
const oauth = @import("mod.zig");
const pkce = @import("pkce.zig");

/// Client ID for OpenAI Codex OAuth
const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";

/// OAuth endpoints for OpenAI
const AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize";
const TOKEN_URL = "https://auth.openai.com/oauth/token";

/// Local callback server configuration
const REDIRECT_PORT: u16 = 1455;
const REDIRECT_URI = "http://localhost:1455/auth/callback";

/// OAuth scopes for OpenAI Codex
const SCOPES = "openid profile email offline_access";

/// Information returned from startAuth for the authorization flow
pub const AuthInfo = struct {
    auth_url: []const u8,
    pkce_pair: pkce.PKCEPair,
    state: [32]u8,

    pub fn deinit(self: *AuthInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.auth_url);
    }
};

/// Errors specific to OpenAI Codex OAuth
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

/// OpenAI Codex OAuth implementation using Authorization Code Flow with PKCE
/// Local callback on port 1455
pub const OpenAICodexOAuth = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize the OAuth provider
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Generate a random state string for CSRF protection
    fn generateState() [32]u8 {
        var state: [32]u8 = undefined;
        std.crypto.random.bytes(&state);
        // Encode as hex for URL safety
        var hex_state: [32]u8 = undefined;
        for (state[0..16], 0..) |byte, i| {
            const hi = byte >> 4;
            const lo = byte & 0x0F;
            hex_state[i * 2] = if (hi < 10) '0' + hi else 'a' + (hi - 10);
            hex_state[i * 2 + 1] = if (lo < 10) '0' + lo else 'a' + (lo - 10);
        }
        return hex_state;
    }

    /// Extract account ID from JWT access token
    /// OpenAI JWTs contain the account ID in the "sub" claim
    /// Returns null if the token is invalid or doesn't contain the claim
    pub fn getAccountId(access_token: []const u8) ?[]const u8 {
        // JWT format: header.payload.signature (base64url encoded)
        // We need to decode the payload and extract the "sub" claim

        // Find the first dot (end of header)
        const first_dot = std.mem.indexOf(u8, access_token, ".") orelse return null;
        // Find the second dot (end of payload)
        const second_dot = std.mem.indexOfPos(u8, access_token, first_dot + 1, ".") orelse return null;

        // Extract payload
        const payload_b64 = access_token[first_dot + 1 .. second_dot];

        // TODO: Implement base64url decoding and JSON parsing
        // For now, this is a stub that returns null
        _ = payload_b64;
        return null;
    }

    /// Start authorization flow - returns URL and PKCE pair
    /// Opens local callback server on port 1455
    pub fn startAuth(self: *Self) CodexError!AuthInfo {
        const pkce_pair = pkce.generatePKCE();
        const state = generateState();

        // Build authorization URL
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

    /// Exchange authorization code for tokens
    /// TODO: Implement full HTTP request to TOKEN_URL
    pub fn exchangeCode(self: *Self, code: []const u8, pkce_pair: pkce.PKCEPair) CodexError!oauth.OAuthCredentials {
        _ = self;
        _ = code;
        _ = pkce_pair;
        return CodexError.NotImplemented;
    }

    /// Full login flow with local callback server
    /// TODO: Implement complete flow:
    /// 1. Start local HTTP server on port 1455
    /// 2. Generate auth URL and open browser
    /// 3. Wait for callback with auth code
    /// 4. Exchange code for tokens
    pub fn login(self: *Self) CodexError!oauth.OAuthCredentials {
        _ = self;
        return CodexError.NotImplemented;
    }

    /// Refresh expired tokens using refresh_token
    /// TODO: Implement token refresh via TOKEN_URL
    pub fn refreshToken(self: *Self, refresh_token: []const u8) CodexError!oauth.OAuthCredentials {
        _ = self;
        _ = refresh_token;
        return CodexError.NotImplemented;
    }
};

// Tests
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
    // Verify it uses port 1455
    try std.testing.expect(std.mem.indexOf(u8, auth_info.auth_url, "1455") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth_info.auth_url, "code_challenge") != null);
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
    // Valid JWT format but we don't decode it yet
    try std.testing.expect(OpenAICodexOAuth.getAccountId("header.payload.signature") == null);
}
