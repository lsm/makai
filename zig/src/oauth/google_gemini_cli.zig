const std = @import("std");
const oauth = @import("mod.zig");
const pkce = @import("pkce.zig");

/// Client ID for Google Gemini CLI OAuth
/// (base64 decoded: same as displayed)
const CLIENT_ID = "681255809391-oo8ft2oprdrbp9e3aqf6av3hmdib135j.apps.googleusercontent.com";

/// Client secret for Google Gemini CLI OAuth
const CLIENT_SECRET = "GOCSpx-4uHgMPm-1o7Sk-geV6Cu5clXFsxl";

/// OAuth endpoints
const AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL = "https://oauth2.googleapis.com/token";

/// Local callback server configuration
const REDIRECT_PORT: u16 = 8085;
const REDIRECT_URI = "http://localhost:8085/callback";

/// OAuth scopes for Google Gemini
const SCOPES = "https://www.googleapis.com/auth/cloud-platform";

/// Default GCP project for Gemini API
const DEFAULT_PROJECT_ID = "rising-fact-p41fc";

/// Information returned from startAuth for the authorization flow
pub const AuthInfo = struct {
    auth_url: []const u8,
    pkce_pair: pkce.PKCEPair,
    state: [32]u8,

    pub fn deinit(self: *AuthInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.auth_url);
    }
};

/// Errors specific to Google Gemini CLI OAuth
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

/// Google Gemini CLI OAuth implementation using Authorization Code Flow with PKCE
/// Local callback server on port 8085
pub const GoogleGeminiCliOAuth = struct {
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

    /// Start authorization flow - returns URL and PKCE pair
    /// Opens local callback server on port 8085
    pub fn startAuth(self: *Self) GeminiCliError!AuthInfo {
        const pkce_pair = pkce.generatePKCE();
        const state = generateState();

        // Build authorization URL
        // TODO: Implement proper URL building with query parameters
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

    /// Exchange authorization code for tokens
    /// TODO: Implement full HTTP request to TOKEN_URL
    pub fn exchangeCode(self: *Self, code: []const u8, pkce_pair: pkce.PKCEPair) GeminiCliError!oauth.OAuthCredentials {
        _ = self;
        _ = code;
        _ = pkce_pair;
        return GeminiCliError.NotImplemented;
    }

    /// Discover or provision GCP project for the user
    /// TODO: Implement project discovery via GCP API
    pub fn discoverProject(self: *Self, access_token: []const u8) GeminiCliError![]const u8 {
        _ = access_token;
        // For now, return the default project
        return self.allocator.dupe(u8, DEFAULT_PROJECT_ID) catch GeminiCliError.OutOfMemory;
    }

    /// Full login flow with local callback server
    /// TODO: Implement complete flow:
    /// 1. Start local HTTP server on port 8085
    /// 2. Generate auth URL and open browser
    /// 3. Wait for callback with auth code
    /// 4. Exchange code for tokens
    /// 5. Discover/provision GCP project
    pub fn login(self: *Self) GeminiCliError!oauth.OAuthCredentials {
        _ = self;
        return GeminiCliError.NotImplemented;
    }

    /// Refresh expired tokens using refresh_token
    /// TODO: Implement token refresh via TOKEN_URL
    pub fn refreshToken(self: *Self, refresh_token: []const u8) GeminiCliError!oauth.OAuthCredentials {
        _ = self;
        _ = refresh_token;
        return GeminiCliError.NotImplemented;
    }
};

// Tests
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
    try std.testing.expect(std.mem.indexOf(u8, auth_info.auth_url, "code_challenge") != null);
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
