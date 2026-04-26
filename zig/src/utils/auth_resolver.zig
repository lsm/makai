//! Credential resolution for the Zig binary's protocol request path.
//!
//! Per `docs/ts-sdk-chat-integration-plan.md` Phase 2a, the binary owns all
//! auth resolution. TypeScript clients never read token files or handle
//! refresh tokens directly; they may only pass an explicit API key on the
//! request. When no key is provided, the binary loads stored credentials by
//! `provider_id`.
//!
//! Resolution order:
//!   1. If the request supplies a non-empty `api_key`, use it as-is.
//!   2. Otherwise, look up `provider_id` in `AuthStorage`.
//!      - For `api_key` entries, return the stored key.
//!      - For `oauth` entries, return the stored access token.
//!   3. If neither is available, return `error.AuthRequired`. The protocol
//!      layer maps this to a `nack` with `error_code = auth_required`.
//!
//! NOTE: M-006 is the load path only. M-007 layers refresh-on-expiry and
//! retry-on-upstream-auth-failure on top of this resolver. Provider-specific
//! token exchange (e.g. GitHub Copilot's bearer-token swap) is also handled
//! by M-007's refresh path, since it shares the same OAuth provider plumbing.

const std = @import("std");
const storage_mod = @import("oauth/storage");

pub const AuthStorage = storage_mod.AuthStorage;
pub const ProviderAuth = storage_mod.ProviderAuth;

pub const AuthResolveError = error{
    /// No explicit API key was provided and no stored credentials exist for
    /// `provider_id`. Surfaced to clients as `error_code = auth_required`.
    AuthRequired,
} || std.mem.Allocator.Error;

/// A resolved API key. The slice is always heap-allocated by `resolveApiKey`
/// so the caller can free it uniformly without tracking ownership.
pub const ResolvedKey = struct {
    api_key: []u8,

    pub fn deinit(self: *ResolvedKey, allocator: std.mem.Allocator) void {
        allocator.free(self.api_key);
        self.* = undefined;
    }
};

/// Resolve the API key to use for an upstream provider call.
///
/// `auth_storage` may be null when the runtime has not loaded an auth file
/// yet — in that case only the explicit `provided_api_key` path can succeed.
///
/// The returned `ResolvedKey.api_key` is owned by `allocator`; callers must
/// call `deinit` once they are done injecting it into request options.
pub fn resolveApiKey(
    allocator: std.mem.Allocator,
    auth_storage: ?*AuthStorage,
    provider_id: []const u8,
    provided_api_key: ?[]const u8,
) AuthResolveError!ResolvedKey {
    if (provided_api_key) |k| {
        if (k.len > 0) {
            const dup = try allocator.dupe(u8, k);
            return .{ .api_key = dup };
        }
    }

    const storage = auth_storage orelse return error.AuthRequired;
    const auth = storage.providers.get(provider_id) orelse return error.AuthRequired;

    switch (auth) {
        .api_key => |key| {
            const dup = try allocator.dupe(u8, key);
            return .{ .api_key = dup };
        },
        .oauth => |creds| {
            // M-006: load access token directly. M-007 will add refresh on
            // expiry plus provider-specific token exchange.
            const dup = try allocator.dupe(u8, creds.access);
            return .{ .api_key = dup };
        },
    }
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

fn makeStorage(allocator: std.mem.Allocator) AuthStorage {
    return .{
        .providers = std.StringHashMap(ProviderAuth).init(allocator),
        .allocator = allocator,
    };
}

test "resolveApiKey - explicit api key wins, no storage lookup" {
    var storage = makeStorage(testing.allocator);
    defer storage.deinit();

    // Storage has a different key for the same provider — must NOT be used.
    const provider_id = try testing.allocator.dupe(u8, "anthropic");
    const stored = try testing.allocator.dupe(u8, "stored-key");
    try storage.providers.put(provider_id, .{ .api_key = stored });

    var resolved = try resolveApiKey(testing.allocator, &storage, "anthropic", "explicit-key");
    defer resolved.deinit(testing.allocator);

    try testing.expectEqualStrings("explicit-key", resolved.api_key);
}

test "resolveApiKey - empty explicit key falls through to storage" {
    var storage = makeStorage(testing.allocator);
    defer storage.deinit();

    const provider_id = try testing.allocator.dupe(u8, "anthropic");
    const stored = try testing.allocator.dupe(u8, "stored-key");
    try storage.providers.put(provider_id, .{ .api_key = stored });

    var resolved = try resolveApiKey(testing.allocator, &storage, "anthropic", "");
    defer resolved.deinit(testing.allocator);

    try testing.expectEqualStrings("stored-key", resolved.api_key);
}

test "resolveApiKey - loads api_key from storage by provider_id" {
    var storage = makeStorage(testing.allocator);
    defer storage.deinit();

    const provider_id = try testing.allocator.dupe(u8, "openai");
    const stored = try testing.allocator.dupe(u8, "sk-test");
    try storage.providers.put(provider_id, .{ .api_key = stored });

    var resolved = try resolveApiKey(testing.allocator, &storage, "openai", null);
    defer resolved.deinit(testing.allocator);

    try testing.expectEqualStrings("sk-test", resolved.api_key);
}

test "resolveApiKey - loads oauth access token from storage by provider_id" {
    var storage = makeStorage(testing.allocator);
    defer storage.deinit();

    const provider_id = try testing.allocator.dupe(u8, "anthropic");
    const refresh = try testing.allocator.dupe(u8, "refresh-token");
    const access = try testing.allocator.dupe(u8, "oauth-access");
    try storage.providers.put(provider_id, .{ .oauth = .{
        .refresh = refresh,
        .access = access,
        .expires = std.time.milliTimestamp() + 3_600_000,
    } });

    var resolved = try resolveApiKey(testing.allocator, &storage, "anthropic", null);
    defer resolved.deinit(testing.allocator);

    try testing.expectEqualStrings("oauth-access", resolved.api_key);
}

test "resolveApiKey - missing storage and no key returns AuthRequired" {
    try testing.expectError(
        error.AuthRequired,
        resolveApiKey(testing.allocator, null, "anthropic", null),
    );
}

test "resolveApiKey - empty storage returns AuthRequired" {
    var storage = makeStorage(testing.allocator);
    defer storage.deinit();

    try testing.expectError(
        error.AuthRequired,
        resolveApiKey(testing.allocator, &storage, "anthropic", null),
    );
}

test "resolveApiKey - provider not in storage returns AuthRequired" {
    var storage = makeStorage(testing.allocator);
    defer storage.deinit();

    const provider_id = try testing.allocator.dupe(u8, "openai");
    const stored = try testing.allocator.dupe(u8, "sk-test");
    try storage.providers.put(provider_id, .{ .api_key = stored });

    try testing.expectError(
        error.AuthRequired,
        resolveApiKey(testing.allocator, &storage, "anthropic", null),
    );
}

test "resolveApiKey - empty key with no storage returns AuthRequired" {
    try testing.expectError(
        error.AuthRequired,
        resolveApiKey(testing.allocator, null, "anthropic", ""),
    );
}
