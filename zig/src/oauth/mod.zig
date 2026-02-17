const std = @import("std");

pub const pkce = @import("pkce.zig");

// Re-export types for convenience
pub const PKCEPair = pkce.PKCEPair;
pub const generatePKCE = pkce.generatePKCE;

/// OAuth credentials returned from a successful login
pub const OAuthCredentials = struct {
    refresh: []const u8,
    access: []const u8,
    expires: i64, // Unix timestamp in milliseconds
    // Provider-specific fields can be added via extension patterns

    pub fn deinit(self: *OAuthCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.refresh);
        allocator.free(self.access);
    }

    pub fn isExpired(self: *const OAuthCredentials) bool {
        const now = std.time.milliTimestamp();
        return now >= self.expires;
    }

    pub fn expiresInSeconds(self: *const OAuthCredentials) i64 {
        const now = std.time.milliTimestamp();
        const remaining = self.expires - now;
        return @max(0, remaining / 1000);
    }
};

/// OAuth provider interface (simplified for Zig)
pub const OAuthProviderId = enum {
    github_copilot,
    google_gemini_cli,
    google_antigravity,
    openai_codex,
};

/// Information displayed to user during login
pub const OAuthAuthInfo = struct {
    verification_uri: ?[]const u8 = null,
    user_code: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

/// Prompt shown to user requesting input
pub const OAuthPrompt = struct {
    message: []const u8,
    default_value: ?[]const u8 = null,
};

// Provider modules are imported separately as needed:
// pub const github_copilot = @import("github_copilot.zig");
// pub const google_gemini_cli = @import("google_gemini_cli.zig");
// pub const google_antigravity = @import("google_antigravity.zig");
// pub const openai_codex = @import("openai_codex.zig");
