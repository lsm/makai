const std = @import("std");
const compat = @import("compat");

pub const pkce = @import("pkce.zig");

pub const PKCEPair = pkce.PKCEPair;
pub const generatePKCE = pkce.generatePKCE;

pub const OAuthCredentials = struct {
    refresh: []const u8,
    access: []const u8,
    expires: i64,

    pub fn deinit(self: *OAuthCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.refresh);
        allocator.free(self.access);
    }

    pub fn isExpired(self: *const OAuthCredentials) bool {
        const now = compat.time.nowMillis();
        return now >= self.expires;
    }

    pub fn expiresInSeconds(self: *const OAuthCredentials) i64 {
        const now = compat.time.nowMillis();
        const remaining = self.expires - now;
        return @max(0, remaining / 1000);
    }
};

pub const OAuthProviderId = enum {
    github_copilot,
    google_gemini_cli,
    google_antigravity,
    openai_codex,
};

pub const OAuthAuthInfo = struct {
    verification_uri: ?[]const u8 = null,
    user_code: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const OAuthPrompt = struct {
    message: []const u8,
    default_value: ?[]const u8 = null,
};

