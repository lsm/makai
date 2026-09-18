const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const storage_mod = @import("oauth/storage");
const custom_providers = @import("custom_providers");

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

pub const CredentialKind = enum {
    any,
    api_key_only,
};

pub fn resolveApiKey(
    allocator: std.mem.Allocator,
    auth_storage: ?*AuthStorage,
    provider_id: []const u8,
    provided_api_key: ?[]const u8,
) AuthResolveError!ResolvedKey {
    return resolveApiKeyOfKind(allocator, auth_storage, provider_id, provided_api_key, .any);
}

pub fn resolveApiKeyOfKind(
    allocator: std.mem.Allocator,
    auth_storage: ?*AuthStorage,
    provider_id: []const u8,
    provided_api_key: ?[]const u8,
    kind: CredentialKind,
) AuthResolveError!ResolvedKey {
    if (provided_api_key) |k| {
        if (k.len > 0) {
            const dup = try allocator.dupe(u8, k);
            return .{ .api_key = dup };
        }
    }

    if (auth_storage) |storage| {
        if (storage.resolvedCredential(provider_id)) |auth| {
            switch (auth) {
                .api_key => |key| {
                    const dup = try allocator.dupe(u8, key);
                    return .{ .api_key = dup };
                },
                .oauth => |creds| {
                    if (kind == .any) {
                        const dup = try allocator.dupe(u8, creds.access);
                        return .{ .api_key = dup };
                    }
                },
            }
        }
    }

    if (try customProviderEnvKey(allocator, provider_id)) |key| return .{ .api_key = key };
    return error.AuthRequired;
}

fn customProviderEnvKey(allocator: std.mem.Allocator, provider_id: []const u8) std.mem.Allocator.Error!?[]u8 {
    if (builtin.is_test) return null;
    const providers = custom_providers.load(allocator, custom_providers.max_config_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer custom_providers.deinitProviders(allocator, providers);
    return envKeyForProvider(allocator, providers, provider_id);
}

pub fn envKeyForProvider(
    allocator: std.mem.Allocator,
    providers: []const custom_providers.CustomProvider,
    provider_id: []const u8,
) std.mem.Allocator.Error!?[]u8 {
    for (providers) |provider| {
        if (!std.mem.eql(u8, provider.id, provider_id)) continue;
        const env_name = provider.env_key orelse return null;
        const value = compat.getEnvVarOwned(allocator, env_name) catch return null;
        if (value.len == 0) {
            allocator.free(value);
            return null;
        }
        return value;
    }
    return null;
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

test "resolveApiKeyOfKind - api_key_only refuses a stored oauth token" {
    var storage = makeStorage(testing.allocator);
    defer storage.deinit();

    const provider_id = try testing.allocator.dupe(u8, "openai-codex");
    const refresh = try testing.allocator.dupe(u8, "refresh-token");
    const access = try testing.allocator.dupe(u8, "oauth-access");
    try storage.providers.put(provider_id, .{ .oauth = .{
        .refresh = refresh,
        .access = access,
        .expires = compat.time.nowMillis() + 3_600_000,
    } });

    try testing.expectError(
        error.AuthRequired,
        resolveApiKeyOfKind(testing.allocator, &storage, "openai-codex", null, .api_key_only),
    );

    var any = try resolveApiKeyOfKind(testing.allocator, &storage, "openai-codex", null, .any);
    defer any.deinit(testing.allocator);
    try testing.expectEqualStrings("oauth-access", any.api_key);
}

test "resolveApiKeyOfKind - api_key_only still returns a stored api key" {
    var storage = makeStorage(testing.allocator);
    defer storage.deinit();

    const provider_id = try testing.allocator.dupe(u8, "gateway");
    const stored = try testing.allocator.dupe(u8, "gateway-key");
    try storage.providers.put(provider_id, .{ .api_key = stored });

    var resolved = try resolveApiKeyOfKind(testing.allocator, &storage, "gateway", null, .api_key_only);
    defer resolved.deinit(testing.allocator);
    try testing.expectEqualStrings("gateway-key", resolved.api_key);
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

test "envKeyForProvider reads the declared variable and ignores other providers" {
    const providers = [_]custom_providers.CustomProvider{
        .{ .id = "gateway", .name = "Gateway", .api = "openai-completions", .base_url = "https://gw.test", .env_key = "MAKAI_TEST_GATEWAY_KEY" },
        .{ .id = "keyless", .name = "Keyless", .api = "openai-completions", .base_url = "http://localhost:8000" },
    };

    try testing.expect(try envKeyForProvider(testing.allocator, &providers, "absent") == null);
    try testing.expect(try envKeyForProvider(testing.allocator, &providers, "keyless") == null);

    const unset = try envKeyForProvider(testing.allocator, &providers, "gateway");
    if (unset) |value| testing.allocator.free(value);
}

test "a granted credential outranks a configured one on the resolution path" {
    const allocator = std.testing.allocator;

    var storage = AuthStorage{
        .providers = std.StringHashMap(storage_mod.ProviderAuth).init(allocator),
        .allocator = allocator,
    };
    defer storage.deinit();

    try storage.providers.put(
        try allocator.dupe(u8, "tenant"),
        .{ .api_key = try allocator.dupe(u8, "sk-configured") },
    );

    var configured = try resolveApiKeyOfKind(allocator, &storage, "tenant", null, .any);
    defer configured.deinit(allocator);
    try std.testing.expectEqualStrings("sk-configured", configured.api_key);

    try storage.putEphemeral("tenant", .{ .api_key = try allocator.dupe(u8, "sk-granted") });

    var granted = try resolveApiKeyOfKind(allocator, &storage, "tenant", null, .any);
    defer granted.deinit(allocator);
    try std.testing.expectEqualStrings("sk-granted", granted.api_key);

    storage.releaseEphemeral();

    var restored = try resolveApiKeyOfKind(allocator, &storage, "tenant", null, .any);
    defer restored.deinit(allocator);
    try std.testing.expectEqualStrings("sk-configured", restored.api_key);
}
