
const std = @import("std");
const compat = @import("compat");
const storage_mod = @import("oauth/storage");

pub const AuthStorage = storage_mod.AuthStorage;
pub const ProviderAuth = storage_mod.ProviderAuth;

pub const AuthResolveError = error{
    AuthRequired,
} || std.mem.Allocator.Error;

pub const ResolvedKey = struct {
    api_key: []u8,

    pub fn deinit(self: *ResolvedKey, allocator: std.mem.Allocator) void {
        allocator.free(self.api_key);
        self.* = undefined;
    }
};

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
            const dup = try allocator.dupe(u8, creds.access);
            return .{ .api_key = dup };
        },
    }
}

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
        .expires = compat.time.nowMillis() + 3_600_000,
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
