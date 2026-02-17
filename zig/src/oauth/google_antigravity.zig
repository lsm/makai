const std = @import("std");
const oauth = @import("mod.zig");
const pkce = @import("pkce.zig");

/// Client ID for Google Antigravity OAuth (internal Google service)
const CLIENT_ID = "1071006060591-tmhssin2h21lcre235vtolojg4g403ep.apps.googleusercontent.com";

/// Client secret for Google Antigravity OAuth
const CLIENT_SECRET = "GOCSpx-K58FWR486LdLJ1mLB8sXC4z6qDAf";

/// OAuth endpoints (same as Gemini CLI)
const AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL = "https://oauth2.googleapis.com/token";

/// Local callback server configuration - uses different port than Gemini CLI
const REDIRECT_PORT: u16 = 51121;
const REDIRECT_URI = "http://localhost:51121/oauth-callback";

/// OAuth scopes for Google Antigravity
const SCOPES = "https://www.googleapis.com/auth/cloud-platform";

/// Default GCP project for Antigravity service
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

/// Errors specific to Google Antigravity OAuth
pub const AntigravityError = error{
    NotImplemented,
    OutOfMemory,
    HttpError,
    InvalidResponse,
    AuthorizationFailed,
    TokenExchangeFailed,
    ProjectDiscoveryFailed,
    CallbackServerFailed,
};

/// Google Antigravity OAuth implementation (internal Google service)
/// Similar to Gemini CLI but uses different credentials and port
/// - CLIENT_ID: 1071006060591-tmhssin2h21lcre235vtolojg4g403ep.apps.googleusercontent.com
/// - CLIENT_SECRET: GOCSpx-K58FWR486LdLJ1mLB8sXC4z6qDAf
/// - REDIRECT_URI: http://localhost:51121/oauth-callback
/// - DEFAULT_PROJECT_ID: rising-fact-p41fc
pub const GoogleAntigravityOAuth = struct {
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
    /// Opens local callback server on port 51121
    pub fn startAuth(self: *Self) AntigravityError!AuthInfo {
        const pkce_pair = pkce.generatePKCE();
        const state = generateState();

        // Build authorization URL
        var url_buf: [2048]u8 = undefined;
        const auth_url = std.fmt.bufPrint(
            &url_buf,
            "{s}?client_id={s}&redirect_uri={s}&response_type=code&scope={s}&code_challenge={s}&code_challenge_method=S256&state={s}",
            .{ AUTHORIZE_URL, CLIENT_ID, REDIRECT_URI, SCOPES, pkce_pair.challenge, state },
        ) catch return AntigravityError.OutOfMemory;

        const owned_url = self.allocator.dupe(u8, auth_url) catch return AntigravityError.OutOfMemory;

        return AuthInfo{
            .auth_url = owned_url,
            .pkce_pair = pkce_pair,
            .state = state,
        };
    }

    /// Exchange authorization code for tokens
    /// TODO: Implement full HTTP request to TOKEN_URL
    pub fn exchangeCode(self: *Self, code: []const u8, pkce_pair: pkce.PKCEPair) AntigravityError!oauth.OAuthCredentials {
        _ = self;
        _ = code;
        _ = pkce_pair;
        return AntigravityError.NotImplemented;
    }

    /// Discover or provision GCP project for the user
    /// TODO: Implement project discovery via GCP API
    pub fn discoverProject(self: *Self, access_token: []const u8) AntigravityError![]const u8 {
        _ = access_token;
        // For now, return the default project
        return self.allocator.dupe(u8, DEFAULT_PROJECT_ID) catch AntigravityError.OutOfMemory;
    }

    /// Full login flow with local callback server
    /// TODO: Implement complete flow:
    /// 1. Start local HTTP server on port 51121
    /// 2. Generate auth URL and open browser
    /// 3. Wait for callback with auth code
    /// 4. Exchange code for tokens
    /// 5. Discover/provision GCP project
    pub fn login(self: *Self) AntigravityError!oauth.OAuthCredentials {
        _ = self;
        return AntigravityError.NotImplemented;
    }

    /// Refresh expired tokens using refresh_token
    /// TODO: Implement token refresh via TOKEN_URL
    pub fn refreshToken(self: *Self, refresh_token: []const u8) AntigravityError!oauth.OAuthCredentials {
        _ = self;
        _ = refresh_token;
        return AntigravityError.NotImplemented;
    }
};

// Tests
test "GoogleAntigravityOAuth init and deinit" {
    const allocator = std.testing.allocator;

    var oauth_provider = GoogleAntigravityOAuth.init(allocator);
    defer oauth_provider.deinit();

    try std.testing.expectEqual(allocator, oauth_provider.allocator);
}

test "GoogleAntigravityOAuth startAuth returns valid AuthInfo with correct port" {
    const allocator = std.testing.allocator;

    var oauth_provider = GoogleAntigravityOAuth.init(allocator);
    defer oauth_provider.deinit();

    var auth_info = try oauth_provider.startAuth();
    defer auth_info.deinit(allocator);

    try std.testing.expect(auth_info.auth_url.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, auth_info.auth_url, "https://accounts.google.com"));
    // Verify it uses port 51121
    try std.testing.expect(std.mem.indexOf(u8, auth_info.auth_url, "51121") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth_info.auth_url, "code_challenge") != null);
}

test "GoogleAntigravityOAuth login returns NotImplemented" {
    const allocator = std.testing.allocator;

    var oauth_provider = GoogleAntigravityOAuth.init(allocator);
    defer oauth_provider.deinit();

    const result = oauth_provider.login();
    try std.testing.expectError(AntigravityError.NotImplemented, result);
}

test "GoogleAntigravityOAuth refreshToken returns NotImplemented" {
    const allocator = std.testing.allocator;

    var oauth_provider = GoogleAntigravityOAuth.init(allocator);
    defer oauth_provider.deinit();

    const result = oauth_provider.refreshToken("test_refresh_token");
    try std.testing.expectError(AntigravityError.NotImplemented, result);
}

test "GoogleAntigravityOAuth discoverProject returns default project" {
    const allocator = std.testing.allocator;

    var oauth_provider = GoogleAntigravityOAuth.init(allocator);
    defer oauth_provider.deinit();

    const project = try oauth_provider.discoverProject("test_token");
    defer allocator.free(project);

    try std.testing.expectEqualStrings(DEFAULT_PROJECT_ID, project);
}
