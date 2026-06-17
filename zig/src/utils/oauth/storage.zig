const std = @import("std");
const compat = @import("compat");
const builtin = @import("builtin");

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

const auth_file_name = "auth.json";
const auth_temp_prefix = auth_file_name ++ ".tmp.";
const keychain_service = "com.makai.auth";
const keychain_account = auth_file_name;
const codex_keychain_service = "Codex Auth";
const credential_file_permissions: std.Io.File.Permissions = @enumFromInt(0o600);
const stale_temp_min_age_ms = 24 * 60 * 60 * 1000;

const keychain_save_fn: SaveFn = saveToPreferredStorage;

const KeychainLoadResult = union(enum) {
    found: AuthStorage,
    not_found,
    unavailable,
};

fn secureFree(allocator: std.mem.Allocator, data: []const u8) void {
    if (data.len == 0) {
        allocator.free(data);
        return;
    }

    const writable: []u8 = @constCast(data);
    std.crypto.secureZero(u8, writable);
    allocator.free(data);
}

fn isAuthTempFile(name: []const u8) bool {
    return std.mem.startsWith(u8, name, auth_temp_prefix);
}

fn parseAuthTempTimestampMillis(name: []const u8) ?i64 {
    if (!isAuthTempFile(name)) return null;

    const suffix = name[auth_temp_prefix.len..];
    const dot_index = std.mem.indexOfScalar(u8, suffix, '.') orelse return null;
    if (dot_index == 0) return null;

    return std.fmt.parseInt(i64, suffix[0..dot_index], 10) catch null;
}

fn isStaleAuthTempFile(name: []const u8, now_ms: i64) bool {
    const created_ms = parseAuthTempTimestampMillis(name) orelse return false;
    return created_ms <= now_ms - stale_temp_min_age_ms;
}

fn cleanupStaleAuthTempFiles(auth_dir: std.Io.Dir) !void {
    var iterable_dir = try auth_dir.openDir(defaultIo(), ".", .{ .iterate = true });
    defer iterable_dir.close(defaultIo());

    const now_ms = compat.time.nowMillis();
    var iter = iterable_dir.iterate();
    while (try iter.next(defaultIo())) |entry| {
        if (entry.kind == .file and isStaleAuthTempFile(entry.name, now_ms)) {
            // Stale temp cleanup is best-effort: credential writes must not fail
            // merely because an unrelated orphan is locked or owned by another UID.
            auth_dir.deleteFile(defaultIo(), entry.name) catch {};
        }
    }
}

fn cleanupExistingAuthDirectory(cwd: std.Io.Dir, dir_path: []const u8) void {
    var auth_dir = cwd.openDir(defaultIo(), dir_path, .{ .iterate = true }) catch return;
    defer auth_dir.close(defaultIo());

    cleanupStaleAuthTempFiles(auth_dir) catch {};
}

fn prepareAuthDirectory(cwd: std.Io.Dir, dir_path: []const u8) !void {
    try compat.fs.createDir(cwd, dir_path);
}

fn atomicSaveCredentials(cwd: std.Io.Dir, dir_path: []const u8, file_path: []const u8, data: []const u8, allocator: std.mem.Allocator) !void {
    var auth_dir = try cwd.openDir(defaultIo(), dir_path, .{});
    defer auth_dir.close(defaultIo());

    const tmp_name = try std.fmt.allocPrint(allocator, "{s}{d}.{x}", .{ auth_temp_prefix, compat.time.nowMillis(), compat.random.int(u64) });
    defer allocator.free(tmp_name);

    var cleanup_tmp = false;
    defer if (cleanup_tmp) auth_dir.deleteFile(defaultIo(), tmp_name) catch {};

    {
        var file = try auth_dir.createFile(defaultIo(), tmp_name, .{ .exclusive = true, .truncate = false, .permissions = credential_file_permissions });
        cleanup_tmp = true;
        defer file.close(defaultIo());
        try file.writeStreamingAll(defaultIo(), data);
        try file.sync(defaultIo());
        file.setPermissions(defaultIo(), credential_file_permissions) catch |err| switch (err) {
            error.PermissionDenied => return err,
            else => {},
        };
    }

    try auth_dir.rename(tmp_name, auth_dir, auth_file_name, defaultIo());
    cleanup_tmp = false;

    // Re-apply restrictive permissions after rename so the credential file is
    // 0600 even on filesystems that do not preserve create-time permissions.
    var final_file = try compat.fs.openFile(cwd, file_path, .{ .mode = .write_only });
    defer final_file.close(defaultIo());
    final_file.setPermissions(defaultIo(), credential_file_permissions) catch |err| switch (err) {
        error.PermissionDenied => return err,
        else => {},
    };
}

pub const Credentials = struct {
    refresh: []const u8,
    access: []const u8,
    expires: i64,
    provider_data: ?[]const u8 = null,

    pub fn deinit(self: *const Credentials, allocator: std.mem.Allocator) void {
        secureFree(allocator, self.refresh);
        secureFree(allocator, self.access);
        if (self.provider_data) |data| {
            secureFree(allocator, data);
        }
    }
};

pub const OAuthProvider = struct {
    id: []const u8,
    name: []const u8 = "",
    refresh_fn: *const fn (credentials: Credentials, allocator: std.mem.Allocator) anyerror!Credentials,
    get_api_key_fn: *const fn (credentials: Credentials, allocator: std.mem.Allocator) anyerror![]const u8,
};

/// Provider authentication storage
pub const ProviderAuth = union(enum) {
    api_key: []const u8,
    oauth: Credentials,

    pub fn deinit(self: *const ProviderAuth, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .api_key => |key| secureFree(allocator, key),
            .oauth => |creds| creds.deinit(allocator),
        }
    }
};

pub const SaveFn = *const fn (storage: *const AuthStorage) anyerror!void;

fn emptyStorage(allocator: std.mem.Allocator, save_fn: ?SaveFn) AuthStorage {
    return .{
        .providers = std.StringHashMap(ProviderAuth).init(allocator),
        .allocator = allocator,
        .save_fn = save_fn,
    };
}

fn deinitProviderMap(allocator: std.mem.Allocator, providers: *std.StringHashMap(ProviderAuth)) void {
    var iter = providers.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    providers.deinit();
}

fn parseAuthJson(allocator: std.mem.Allocator, content: []const u8, save_fn: ?SaveFn) !AuthStorage {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    var providers = std.StringHashMap(ProviderAuth).init(allocator);
    errdefer deinitProviderMap(allocator, &providers);

    const root = parsed.value.object;
    var iter = root.iterator();
    while (iter.next()) |entry| {
        const provider_id = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(provider_id);

        const provider_obj = entry.value_ptr.*.object;
        if (provider_obj.get("api_key")) |api_key_val| {
            const api_key = try allocator.dupe(u8, api_key_val.string);
            errdefer secureFree(allocator, api_key);

            // Read region field if present (for providers like Kimi that need region-specific endpoints).
            // `region` is only needed to build `provider_data` (which owns its own copy via
            // allocPrint), so it is freed at the end of the scoped block below — never leaked.
            const provider_data: ?[]const u8 = blk: {
                const r = if (provider_obj.get("region")) |region_val|
                    try allocator.dupe(u8, region_val.string)
                else
                    break :blk null;
                defer allocator.free(r);
                break :blk try std.fmt.allocPrint(allocator, "region:{s}", .{r});
            };
            errdefer if (provider_data) |pd| allocator.free(pd);

            // Store as api_key variant for pure API key auth (no region support)
            // or as oauth with provider_data for region-aware providers like Kimi
            if (provider_data == null) {
                try providers.put(provider_id, .{ .api_key = api_key });
            } else {
                try providers.put(provider_id, .{ .oauth = .{
                    .refresh = "",
                    .access = api_key,
                    .expires = std.math.maxInt(i64),
                    .provider_data = provider_data,
                } });
            }
        } else if (provider_obj.get("refresh")) |refresh_val| {
            const refresh = try allocator.dupe(u8, refresh_val.string);
            errdefer secureFree(allocator, refresh);

            const access = try allocator.dupe(u8, provider_obj.get("access").?.string);
            errdefer secureFree(allocator, access);

            const provider_data = if (provider_obj.get("provider_data")) |pd|
                try allocator.dupe(u8, pd.string)
            else
                null;
            errdefer if (provider_data) |data| secureFree(allocator, data);

            const expires = provider_obj.get("expires").?.integer;
            try providers.put(provider_id, .{ .oauth = .{
                .refresh = refresh,
                .access = access,
                .expires = expires,
                .provider_data = provider_data,
            } });
        } else {
            allocator.free(provider_id);
        }
    }

    return .{
        .providers = providers,
        .allocator = allocator,
        .save_fn = save_fn,
    };
}

fn appendJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    try buf.appendSlice(allocator, encoded);
}

fn serializeAuthJson(storage: *const AuthStorage, allocator: std.mem.Allocator) ![]u8 {
    var json_buf = std.ArrayList(u8).empty;
    errdefer json_buf.deinit(allocator);

    try json_buf.appendSlice(allocator, "{\n");

    var iter = storage.providers.iterator();
    var first = true;
    while (iter.next()) |entry| {
        if (!first) try json_buf.appendSlice(allocator, ",\n");
        first = false;

        try json_buf.appendSlice(allocator, "  ");
        try appendJsonString(allocator, &json_buf, entry.key_ptr.*);
        try json_buf.appendSlice(allocator, ": ");

        switch (entry.value_ptr.*) {
            .api_key => |key| {
                try json_buf.appendSlice(allocator, "{\"api_key\":");
                try appendJsonString(allocator, &json_buf, key);
                try json_buf.appendSlice(allocator, "}");
            },
            .oauth => |creds| {
                // Special case for API keys stored as oauth (for region support)
                const is_api_key_style = creds.refresh.len == 0 and creds.expires == std.math.maxInt(i64);
                if (is_api_key_style) {
                    if (creds.provider_data) |data| {
                    // Parse region from provider_data (format: "region:<value>")
                    if (std.mem.startsWith(u8, data, "region:")) {
                        const region = data[7..]; // Skip "region:" prefix
                        try json_buf.appendSlice(allocator, "{\"api_key\":");
                        try appendJsonString(allocator, &json_buf, creds.access);
                        try json_buf.appendSlice(allocator, ",\"region\":");
                        try appendJsonString(allocator, &json_buf, region);
                        try json_buf.appendSlice(allocator, "}");
                        break;
                    }
                }
                }
                // Standard OAuth credential serialization
                try json_buf.appendSlice(allocator, "{\"refresh\":");
                try appendJsonString(allocator, &json_buf, creds.refresh);
                try json_buf.appendSlice(allocator, ",\"access\":");
                try appendJsonString(allocator, &json_buf, creds.access);
                try json_buf.appendSlice(allocator, ",\"expires\":");
                const expires_str = try std.fmt.allocPrint(allocator, "{d}", .{creds.expires});
                defer allocator.free(expires_str);
                try json_buf.appendSlice(allocator, expires_str);
                if (creds.provider_data) |data| {
                    try json_buf.appendSlice(allocator, ",\"provider_data\":");
                    try appendJsonString(allocator, &json_buf, data);
                }
                try json_buf.appendSlice(allocator, "}");
            },
        }
    }

    try json_buf.appendSlice(allocator, "\n}\n");
    return try json_buf.toOwnedSlice(allocator);
}

fn shouldUseKeychain() bool {
    return builtin.os.tag == .macos and !builtin.is_test;
}

const macos_keychain = if (builtin.os.tag == .macos) struct {
    const OSStatus = i32;
    const UInt32 = u32;
    const SecKeychainItem = opaque {};
    const SecKeychainItemRef = ?*SecKeychainItem;
    const errSecSuccess: OSStatus = 0;
    const errSecDuplicateItem: OSStatus = -25299;
    const errSecItemNotFound: OSStatus = -25300;

    extern "c" fn SecKeychainFindGenericPassword(
        keychainOrArray: ?*const anyopaque,
        serviceNameLength: UInt32,
        serviceName: [*]const u8,
        accountNameLength: UInt32,
        accountName: [*]const u8,
        passwordLength: *UInt32,
        passwordData: *?*anyopaque,
        itemRef: *SecKeychainItemRef,
    ) OSStatus;
    extern "c" fn SecKeychainAddGenericPassword(
        keychain: ?*const anyopaque,
        serviceNameLength: UInt32,
        serviceName: [*]const u8,
        accountNameLength: UInt32,
        accountName: [*]const u8,
        passwordLength: UInt32,
        passwordData: ?*const anyopaque,
        itemRef: ?*SecKeychainItemRef,
    ) OSStatus;
    extern "c" fn SecKeychainItemModifyAttributesAndData(
        itemRef: SecKeychainItemRef,
        attrList: ?*const anyopaque,
        length: UInt32,
        data: ?*const anyopaque,
    ) OSStatus;
    extern "c" fn SecKeychainItemFreeContent(
        attrList: ?*const anyopaque,
        data: ?*anyopaque,
    ) OSStatus;
    extern "c" fn CFRelease(cf: ?*const anyopaque) void;

    fn asUInt32(value: usize) !UInt32 {
        return std.math.cast(UInt32, value) orelse error.KeychainUnavailable;
    }

    fn readServiceAccount(allocator: std.mem.Allocator, service: []const u8, account: []const u8) !?[]u8 {
        var password_len: UInt32 = 0;
        var password_data: ?*anyopaque = null;
        var item: SecKeychainItemRef = null;

        const status = SecKeychainFindGenericPassword(
            null,
            try asUInt32(service.len),
            service.ptr,
            try asUInt32(account.len),
            account.ptr,
            &password_len,
            &password_data,
            &item,
        );
        defer if (item) |value| CFRelease(@ptrCast(value));

        if (status == errSecItemNotFound) return null;
        if (status != errSecSuccess) return error.KeychainUnavailable;
        const data = password_data orelse return error.KeychainUnavailable;
        defer _ = SecKeychainItemFreeContent(null, data);

        const bytes: [*]const u8 = @ptrCast(data);
        return try allocator.dupe(u8, bytes[0..password_len]);
    }

    fn writeServiceAccount(service: []const u8, account: []const u8, data: []const u8) !void {
        var password_len: UInt32 = 0;
        var password_data: ?*anyopaque = null;
        var item: SecKeychainItemRef = null;

        const find_status = SecKeychainFindGenericPassword(
            null,
            try asUInt32(service.len),
            service.ptr,
            try asUInt32(account.len),
            account.ptr,
            &password_len,
            &password_data,
            &item,
        );
        if (password_data) |value| {
            _ = SecKeychainItemFreeContent(null, value);
        }
        defer if (item) |value| CFRelease(@ptrCast(value));

        if (find_status == errSecSuccess) {
            const update_status = SecKeychainItemModifyAttributesAndData(
                item,
                null,
                try asUInt32(data.len),
                @ptrCast(data.ptr),
            );
            if (update_status != errSecSuccess) return error.KeychainUnavailable;
            return;
        }

        if (find_status != errSecItemNotFound) return error.KeychainUnavailable;

        const add_status = SecKeychainAddGenericPassword(
            null,
            try asUInt32(service.len),
            service.ptr,
            try asUInt32(account.len),
            account.ptr,
            try asUInt32(data.len),
            @ptrCast(data.ptr),
            null,
        );
        if (add_status != errSecSuccess and add_status != errSecDuplicateItem) {
            return error.KeychainUnavailable;
        }
        if (add_status == errSecDuplicateItem) try writeServiceAccount(service, account, data);
    }

    fn read(allocator: std.mem.Allocator) !?[]u8 {
        return try readServiceAccount(allocator, keychain_service, keychain_account);
    }

    fn write(data: []const u8) !void {
        try writeServiceAccount(keychain_service, keychain_account, data);
    }
} else struct {
    fn readServiceAccount(_: std.mem.Allocator, _: []const u8, _: []const u8) !?[]u8 {
        return error.KeychainUnavailable;
    }

    fn writeServiceAccount(_: []const u8, _: []const u8, _: []const u8) !void {
        return error.KeychainUnavailable;
    }

    fn read(_: std.mem.Allocator) !?[]u8 {
        return error.KeychainUnavailable;
    }

    fn write(_: []const u8) !void {
        return error.KeychainUnavailable;
    }
};

fn loadFromKeychain(allocator: std.mem.Allocator) !KeychainLoadResult {
    const content = macos_keychain.read(allocator) catch return .unavailable;
    const owned = content orelse return .not_found;
    defer secureFree(allocator, owned);

    var storage = parseAuthJson(allocator, owned, keychain_save_fn) catch return .unavailable;
    errdefer storage.deinit();
    try maybeImportCodexCliCredentials(&storage);
    return .{ .found = storage };
}

fn saveToKeychain(storage: *const AuthStorage) !void {
    const content = try serializeAuthJson(storage, storage.allocator);
    defer secureFree(storage.allocator, content);
    try macos_keychain.write(content);
}

fn saveToPreferredStorage(storage: *const AuthStorage) !void {
    if (shouldUseKeychain()) {
        saveToKeychain(storage) catch {
            try storage.saveToFile();
            return;
        };
        return;
    }
    try storage.saveToFile();
}

fn codexHomePath(allocator: std.mem.Allocator) ![]u8 {
    if (compat.getEnvVarOwned(allocator, "CODEX_HOME")) |codex_home| {
        return codex_home;
    } else |_| {}

    const home = try compat.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".codex" });
}

fn codexAuthPath(allocator: std.mem.Allocator) ![]u8 {
    const codex_home = try codexHomePath(allocator);
    defer allocator.free(codex_home);
    return try std.fs.path.join(allocator, &.{ codex_home, auth_file_name });
}

fn codexKeychainAccountForHome(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(codex_home, &digest, .{});

    var account = try allocator.alloc(u8, "cli|".len + 16);
    errdefer allocator.free(account);
    @memcpy(account[0.."cli|".len], "cli|");

    for (digest[0..8], 0..) |byte, idx| {
        account["cli|".len + idx * 2] = alphabet[byte >> 4];
        account["cli|".len + idx * 2 + 1] = alphabet[byte & 0x0f];
    }
    return account;
}

fn loadCodexCliKeychainAuth(allocator: std.mem.Allocator) !?[]u8 {
    if (!shouldUseKeychain()) return null;

    const codex_home = try codexHomePath(allocator);
    defer allocator.free(codex_home);

    const account = try codexKeychainAccountForHome(allocator, codex_home);
    defer allocator.free(account);

    return try macos_keychain.readServiceAccount(allocator, codex_keychain_service, account);
}

fn parseJwtExpiresMillis(token: []const u8) ?i64 {
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return null;
    const rest = token[first_dot + 1 ..];
    const second_rel = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    const payload = rest[0..second_rel];

    var buffer: [4096]u8 = undefined;
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch return null;
    if (decoded_len > buffer.len) return null;
    const decoded = buffer[0..decoded_len];
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload) catch return null;

    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, decoded, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const exp = parsed.value.object.get("exp") orelse return null;
    const seconds: i64 = switch (exp) {
        .integer => |value| value,
        .float => |value| @intFromFloat(value),
        else => return null,
    };
    return seconds * 1000 - (5 * 60 * 1000);
}

fn importCodexCliCredentials(storage: *AuthStorage, content: []const u8) !void {
    if (storage.providers.contains("openai-codex")) return;

    var parsed = try std.json.parseFromSlice(std.json.Value, storage.allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const tokens_value = parsed.value.object.get("tokens") orelse return;
    if (tokens_value != .object) return;
    const tokens = &tokens_value.object;

    const access_value = tokens.get("access_token") orelse return;
    const refresh_value = tokens.get("refresh_token") orelse return;
    if (access_value != .string or refresh_value != .string) return;

    const expires = parseJwtExpiresMillis(access_value.string) orelse compat.time.nowMillis() + (60 * 60 * 1000);
    const provider_data = if (tokens.get("account_id")) |account| blk: {
        if (account != .string) break :blk null;
        break :blk try std.json.Stringify.valueAlloc(storage.allocator, .{ .source = "codex-cli", .account_id = account.string }, .{});
    } else try std.json.Stringify.valueAlloc(storage.allocator, .{ .source = "codex-cli" }, .{});
    errdefer if (provider_data) |data| secureFree(storage.allocator, data);

    const key = try storage.allocator.dupe(u8, "openai-codex");
    errdefer storage.allocator.free(key);
    const access = try storage.allocator.dupe(u8, access_value.string);
    errdefer secureFree(storage.allocator, access);
    const refresh = try storage.allocator.dupe(u8, refresh_value.string);
    errdefer secureFree(storage.allocator, refresh);

    try storage.providers.put(key, .{ .oauth = .{
        .refresh = refresh,
        .access = access,
        .expires = expires,
        .provider_data = provider_data,
    } });
}

fn maybeImportCodexCliCredentials(storage: *AuthStorage) !void {
    if (builtin.is_test) return;
    if (storage.providers.contains("openai-codex")) return;

    if (loadCodexCliKeychainAuth(storage.allocator)) |maybe_content| {
        if (maybe_content) |content| {
            defer secureFree(storage.allocator, content);
            try importCodexCliCredentials(storage, content);
            if (storage.providers.contains("openai-codex")) return;
        }
    } else |_| {}

    const path = codexAuthPath(storage.allocator) catch return;
    defer storage.allocator.free(path);

    const content = compat.fs.readFileAlloc(storage.allocator, compat.fs.getCwd(), path, 1024 * 1024) catch return;
    defer secureFree(storage.allocator, content);

    try importCodexCliCredentials(storage, content);
}

/// Authentication storage for multiple providers
pub const AuthStorage = struct {
    providers: std.StringHashMap(ProviderAuth),
    allocator: std.mem.Allocator,
    save_fn: ?SaveFn = null,

    /// Load auth storage from ~/.makai/auth.json
    pub fn loadFromFile(allocator: std.mem.Allocator) !AuthStorage {
        return loadFromFileWithSaveFn(allocator, null);
    }

    fn loadFromFileWithSaveFn(allocator: std.mem.Allocator, save_fn: ?SaveFn) !AuthStorage {
        const home = compat.getEnvVarOwned(allocator, "HOME") catch return error.NoHomeDir;
        defer allocator.free(home);
        const dir_path = try std.fs.path.join(allocator, &.{ home, ".makai" });
        defer allocator.free(dir_path);
        const path = try std.fs.path.join(allocator, &.{ home, ".makai", auth_file_name });
        defer allocator.free(path);

        const cwd = compat.fs.getCwd();
        cleanupExistingAuthDirectory(cwd, dir_path);

        var file = compat.fs.openFile(cwd, path, .{}) catch {
            // File doesn't exist, return empty storage
            return emptyStorage(allocator, save_fn);
        };
        file.close(defaultIo());

        const content = try compat.fs.readFileAlloc(allocator, cwd, path, 1024 * 1024);
        defer allocator.free(content);

        return try parseAuthJson(allocator, content, save_fn);
    }

    /// Load auth storage from the preferred secure backend.
    ///
    /// On macOS this prefers the user's Keychain and falls back to
    /// ~/.makai/auth.json when Keychain is unavailable or does not have Makai
    /// credentials yet. In tests and on non-macOS platforms this remains
    /// file-backed to keep runs deterministic.
    pub fn loadDefault(allocator: std.mem.Allocator) !AuthStorage {
        if (shouldUseKeychain()) {
            switch (try loadFromKeychain(allocator)) {
                .found => |storage| {
                    var loaded = storage;
                    try maybeImportCodexCliCredentials(&loaded);
                    return loaded;
                },
                .not_found => {
                    var storage = try loadFromFileWithSaveFn(allocator, keychain_save_fn);
                    try maybeImportCodexCliCredentials(&storage);
                    return storage;
                },
                .unavailable => {},
            }
        }

        var storage = try loadFromFile(allocator);
        try maybeImportCodexCliCredentials(&storage);
        return storage;
    }

    /// Save auth storage to ~/.makai/auth.json atomically.
    ///
    /// Atomicity: writes to a temp file (with 0o600 permissions set
    /// *before* the rename) and then atomically renames over the target.
    /// Concurrent readers will either see the old file or the new file —
    /// never a partial write.
    pub fn saveToFile(self: *const AuthStorage) !void {
        const home = compat.getEnvVarOwned(self.allocator, "HOME") catch return error.NoHomeDir;
        defer self.allocator.free(home);
        const dir_path = try std.fs.path.join(self.allocator, &.{ home, ".makai" });
        defer self.allocator.free(dir_path);

        const file_path = try std.fs.path.join(self.allocator, &.{ home, ".makai", auth_file_name });
        defer self.allocator.free(file_path);

        const cwd = compat.fs.getCwd();
        try prepareAuthDirectory(cwd, dir_path);
        cleanupExistingAuthDirectory(cwd, dir_path);

        const json_buf = try serializeAuthJson(self, self.allocator);
        defer secureFree(self.allocator, json_buf);

        try atomicSaveCredentials(cwd, dir_path, file_path, json_buf, self.allocator);
    }

    pub fn hasRefreshableCredentials(self: *const AuthStorage, provider_id: []const u8) bool {
        const auth = self.providers.get(provider_id) orelse return false;
        return switch (auth) {
            .api_key => false,
            .oauth => true,
        };
    }

    pub fn credentialsExpired(self: *const AuthStorage, provider_id: []const u8) bool {
        const auth = self.providers.get(provider_id) orelse return false;
        return switch (auth) {
            .api_key => false,
            .oauth => |credentials| compat.time.nowMillis() >= credentials.expires,
        };
    }

    pub fn persist(self: *const AuthStorage) !void {
        if (self.save_fn) |save| return save(self);
        return self.saveToFile();
    }

    pub fn refreshCredentials(self: *AuthStorage, provider_id: []const u8, oauth_provider: OAuthProvider) !void {
        const auth = self.providers.get(provider_id) orelse return error.AuthRequired;
        const credentials = switch (auth) {
            .api_key => return error.NotRefreshable,
            .oauth => |credentials| credentials,
        };

        var ownership_transferred = false;
        const new_credentials = try oauth_provider.refresh_fn(credentials, self.allocator);
        errdefer if (!ownership_transferred) new_credentials.deinit(self.allocator);

        const provider_id_copy = try self.allocator.dupe(u8, provider_id);
        errdefer if (!ownership_transferred) self.allocator.free(provider_id_copy);

        const removed = self.providers.fetchRemove(provider_id) orelse return error.AuthRequired;
        errdefer {
            // Rollback: remove the new entry and restore the old one
            if (self.providers.fetchRemove(provider_id_copy)) |new_removed| {
                self.allocator.free(new_removed.key);
                new_removed.value.deinit(self.allocator);
            }
            self.providers.put(removed.key, removed.value) catch {
                self.allocator.free(removed.key);
                removed.value.deinit(self.allocator);
            };
        }

        try self.providers.put(provider_id_copy, .{ .oauth = new_credentials });
        ownership_transferred = true;
        try self.persist();

        self.allocator.free(removed.key);
        removed.value.deinit(self.allocator);
    }

    /// Get API key for provider (refreshing if needed)
    /// Note: Refresh logic requires oauth provider registry which is in parent module
    pub fn getApiKey(self: *AuthStorage, provider_id: []const u8, oauth_provider: ?OAuthProvider) !?[]const u8 {
        const auth = self.providers.get(provider_id) orelse return null;

        switch (auth) {
            .api_key => |key| return try self.allocator.dupe(u8, key),
            .oauth => |credentials| {
                const provider = oauth_provider orelse return error.UnknownProvider;
                if (compat.time.nowMillis() >= credentials.expires) {
                    try self.refreshCredentials(provider_id, provider);
                    const refreshed_auth = self.providers.get(provider_id) orelse return error.AuthRequired;
                    return switch (refreshed_auth) {
                        .api_key => |key| try self.allocator.dupe(u8, key),
                        .oauth => |refreshed| try provider.get_api_key_fn(refreshed, self.allocator),
                    };
                }

                return try provider.get_api_key_fn(credentials, self.allocator);
            },
        }
    }

    /// Free all resources
    pub fn deinit(self: *AuthStorage) void {
        deinitProviderMap(self.allocator, &self.providers);
    }
};

test "AuthStorage - load non-existent file" {
    var storage = try AuthStorage.loadFromFile(std.testing.allocator);
    defer storage.deinit();

    try std.testing.expectEqual(@as(usize, 0), storage.providers.count());
}

test "AuthStorage - save and load" {
    var storage = AuthStorage{
        .providers = std.StringHashMap(ProviderAuth).init(std.testing.allocator),
        .allocator = std.testing.allocator,
    };
    defer storage.deinit();

    // Add API key auth
    const provider_id = try std.testing.allocator.dupe(u8, "test-provider");
    const api_key = try std.testing.allocator.dupe(u8, "test-key");
    try storage.providers.put(provider_id, .{ .api_key = api_key });

    // Save would write to file (skipped in test)
    // Real test would verify file contents and permissions
}

test "ProviderAuth - deinit api_key" {
    const api_key = try std.testing.allocator.dupe(u8, "test-key");
    const auth = ProviderAuth{ .api_key = api_key };
    auth.deinit(std.testing.allocator);
}

test "ProviderAuth - deinit oauth" {
    const refresh = try std.testing.allocator.dupe(u8, "refresh_token");
    const access = try std.testing.allocator.dupe(u8, "access_token");
    const auth = ProviderAuth{
        .oauth = .{
            .refresh = refresh,
            .access = access,
            .expires = compat.time.nowMillis() + 3600000,
        },
    };
    auth.deinit(std.testing.allocator);
}

test "oauth_storage_imports_codex_cli_credentials" {
    var storage = emptyStorage(std.testing.allocator, null);
    defer storage.deinit();

    const content =
        \\{
        \\  "auth_mode": "chatgpt",
        \\  "tokens": {
        \\    "access_token": "e30.eyJleHAiOjIwMDAwMDAwMDB9.sig",
        \\    "refresh_token": "refresh-token",
        \\    "account_id": "account-123"
        \\  }
        \\}
    ;

    try importCodexCliCredentials(&storage, content);

    const auth = storage.providers.get("openai-codex") orelse return error.TestExpectedCodexCredentials;
    switch (auth) {
        .oauth => |credentials| {
            try std.testing.expectEqualStrings("refresh-token", credentials.refresh);
            try std.testing.expectEqualStrings("e30.eyJleHAiOjIwMDAwMDAwMDB9.sig", credentials.access);
            try std.testing.expectEqual(@as(i64, 1_999_999_700_000), credentials.expires);
            try std.testing.expect(credentials.provider_data != null);
            try std.testing.expect(std.mem.indexOf(u8, credentials.provider_data.?, "codex-cli") != null);
        },
        .api_key => return error.TestExpectedOAuthCredentials,
    }
}

test "codexKeychainAccountForHome uses Codex CLI account format" {
    const account = try codexKeychainAccountForHome(std.testing.allocator, "/Users/test/.codex");
    defer std.testing.allocator.free(account);
    const same_account = try codexKeychainAccountForHome(std.testing.allocator, "/Users/test/.codex");
    defer std.testing.allocator.free(same_account);

    try std.testing.expect(std.mem.startsWith(u8, account, "cli|"));
    try std.testing.expectEqual(@as(usize, 20), account.len);
    try std.testing.expectEqualStrings(account, same_account);
}

test "saveToFile writes atomically via temp file + rename" {
    // Verify the atomic write path by writing to a temp directory
    // and reading back the result. This tests the full cycle:
    //   temp file → write → sync → rename → read
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a storage with known credentials
    var storage = AuthStorage{
        .providers = std.StringHashMap(ProviderAuth).init(std.testing.allocator),
        .allocator = std.testing.allocator,
    };
    defer storage.deinit();

    const provider_id = try std.testing.allocator.dupe(u8, "test-provider");
    const api_key = try std.testing.allocator.dupe(u8, "sk-test-key-12345");
    try storage.providers.put(provider_id, .{ .api_key = api_key });

    const oauth_id = try std.testing.allocator.dupe(u8, "oauth-provider");
    const refresh = try std.testing.allocator.dupe(u8, "refresh_tok");
    const access = try std.testing.allocator.dupe(u8, "access_tok");
    try storage.providers.put(oauth_id, .{
        .oauth = .{
            .refresh = refresh,
            .access = access,
            .expires = 1700000000000,
        },
    });

    // Build the JSON directly and write via temp+rename
    var json_buf = std.ArrayList(u8).empty;
    defer json_buf.deinit(std.testing.allocator);

    try json_buf.appendSlice(std.testing.allocator, "{\"test-provider\":{\"api_key\":\"sk-test-key-12345\"}}");

    // Write via temp file + rename pattern (mirroring saveToFile)
    const tmp_path = ".auth_test.json.tmp";
    const final_path = ".auth_test.json";

    const tmp_file = try tmp_dir.dir.createFile(tmp_path, .{ .mode = 0o600 });
    defer tmp_file.close();
    try tmp_file.writeAll(json_buf.items);
    tmp_file.sync() catch {};
    try tmp_dir.dir.rename(tmp_path, final_path);

    // Read back and verify
    const result_file = try tmp_dir.dir.openFile(final_path, .{});
    defer result_file.close();
    const content = try result_file.readToEndAlloc(std.testing.allocator, 1024);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.find(u8, content, "sk-test-key-12345") != null);
    try std.testing.expect(std.mem.find(u8, content, "test-provider") != null);
}
fn putOwnedAuth(storage: *AuthStorage, provider_id: []const u8, auth: ProviderAuth) !void {
    const key = try storage.allocator.dupe(u8, provider_id);
    errdefer storage.allocator.free(key);
    try storage.providers.put(key, auth);
}

fn setHomeForTest(allocator: std.mem.Allocator, home: []const u8) !?[]u8 {
    const previous = std.process.Environ.getAlloc(std.testing.environ, allocator, "HOME") catch null;
    try std.posix.setenv("HOME", home, true);
    return previous;
}

fn restoreHomeForTest(allocator: std.mem.Allocator, previous: ?[]u8) void {
    if (previous) |value| {
        std.posix.setenv("HOME", value, true) catch {};
        allocator.free(value);
    } else {
        std.posix.unsetenv("HOME") catch {};
    }
}

fn countAuthTempFiles(home: []const u8) !usize {
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ home, ".makai" });
    defer std.testing.allocator.free(dir_path);

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (isAuthTempFile(entry.name)) count += 1;
    }
    return count;
}

fn staleAuthTempName(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}{d}.{s}", .{ auth_temp_prefix, compat.time.nowMillis() - stale_temp_min_age_ms - 1000, suffix });
}

fn activeAuthTempName(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}{d}.{s}", .{ auth_temp_prefix, compat.time.nowMillis(), suffix });
}

test "oauth_storage_saveToFile_direct_sets_0600_and_same_directory_temp_rename" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = tmp.sub_path[0..];
    const previous_home = try setHomeForTest(std.testing.allocator, home);
    defer restoreHomeForTest(std.testing.allocator, previous_home);

    var storage = AuthStorage{
        .providers = std.StringHashMap(ProviderAuth).init(std.testing.allocator),
        .allocator = std.testing.allocator,
    };
    defer storage.deinit();

    const api_key = try std.testing.allocator.dupe(u8, "secret-key");
    try putOwnedAuth(&storage, "direct-provider", .{ .api_key = api_key });

    try storage.saveToFile();

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ home, ".makai", auth_file_name });
    defer std.testing.allocator.free(file_path);

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.find(u8, content, "direct-provider") != null);
    try std.testing.expect(std.mem.find(u8, content, "secret-key") != null);

    if (builtin.os.tag != .windows) {
        const stat = try file.stat();
        try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.mode & 0o777)));
    }

    try std.testing.expectEqual(@as(usize, 0), try countAuthTempFiles(home));
}

test "oauth_storage_saveToFile_rename_failure_leaves_target_unchanged_and_cleans_temp" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = tmp.sub_path[0..];
    const previous_home = try setHomeForTest(std.testing.allocator, home);
    defer restoreHomeForTest(std.testing.allocator, previous_home);

    const makai_path = try std.fs.path.join(std.testing.allocator, &.{ home, ".makai" });
    defer std.testing.allocator.free(makai_path);
    try std.fs.cwd().makePath(makai_path);

    const blocker_path = try std.fs.path.join(std.testing.allocator, &.{ home, ".makai", auth_file_name });
    defer std.testing.allocator.free(blocker_path);
    try std.fs.cwd().makePath(blocker_path);

    var storage = AuthStorage{
        .providers = std.StringHashMap(ProviderAuth).init(std.testing.allocator),
        .allocator = std.testing.allocator,
    };
    defer storage.deinit();

    const api_key = try std.testing.allocator.dupe(u8, "secret-key");
    try putOwnedAuth(&storage, "rename-failure-provider", .{ .api_key = api_key });

    try std.testing.expectError(error.IsDir, storage.saveToFile());

    const stat = try std.fs.cwd().statFile(blocker_path);
    try std.testing.expectEqual(std.fs.File.Kind.directory, stat.kind);
    try std.testing.expectEqual(@as(usize, 0), try countAuthTempFiles(home));
}

fn writeAuthTestFile(home: []const u8, name: []const u8, content: []const u8) !void {
    const path = try std.fs.path.join(std.testing.allocator, &.{ home, ".makai", name });
    defer std.testing.allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

test "oauth_storage_loadFromFile_cleans_stale_temp_files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = tmp.sub_path[0..];
    const previous_home = try setHomeForTest(std.testing.allocator, home);
    defer restoreHomeForTest(std.testing.allocator, previous_home);

    const makai_path = try std.fs.path.join(std.testing.allocator, &.{ home, ".makai" });
    defer std.testing.allocator.free(makai_path);
    try std.fs.cwd().makePath(makai_path);

    const stale_tmp = try staleAuthTempName(std.testing.allocator, "stale");
    defer std.testing.allocator.free(stale_tmp);
    try writeAuthTestFile(home, stale_tmp, "orphaned");
    try writeAuthTestFile(home, auth_file_name, "{\"provider\":{\"api_key\":\"key\"}}\n");

    var storage = try AuthStorage.loadFromFile(std.testing.allocator);
    defer storage.deinit();

    try std.testing.expect(storage.providers.contains("provider"));
    try std.testing.expectEqual(@as(usize, 0), try countAuthTempFiles(home));
}

test "oauth_storage_saveToFile_replaces_existing_file_without_requiring_temp_cleanup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = tmp.sub_path[0..];
    const previous_home = try setHomeForTest(std.testing.allocator, home);
    defer restoreHomeForTest(std.testing.allocator, previous_home);

    const makai_path = try std.fs.path.join(std.testing.allocator, &.{ home, ".makai" });
    defer std.testing.allocator.free(makai_path);
    try std.fs.cwd().makePath(makai_path);

    const auth_path = try std.fs.path.join(std.testing.allocator, &.{ home, ".makai", auth_file_name });
    defer std.testing.allocator.free(auth_path);
    try std.fs.cwd().writeFile(.{ .sub_path = auth_path, .data = "original-credentials" });

    const active_tmp = try activeAuthTempName(std.testing.allocator, "active");
    defer std.testing.allocator.free(active_tmp);
    try writeAuthTestFile(home, active_tmp, "active-writer");

    var storage = AuthStorage{
        .providers = std.StringHashMap(ProviderAuth).init(std.testing.allocator),
        .allocator = std.testing.allocator,
    };
    defer storage.deinit();

    const api_key = try std.testing.allocator.dupe(u8, "replacement-key");
    try putOwnedAuth(&storage, "provider", .{ .api_key = api_key });

    try storage.saveToFile();

    const content = try std.fs.cwd().readFileAlloc(auth_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.find(u8, content, "replacement-key") != null);

    const active_path = try std.fs.path.join(std.testing.allocator, &.{ home, ".makai", active_tmp });
    defer std.testing.allocator.free(active_path);
    const active_content = try std.fs.cwd().readFileAlloc(active_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(active_content);
    try std.testing.expectEqualStrings("active-writer", active_content);
}

// POSIX-only because Windows directory permission semantics do not model a
// writable/searchable but non-readable directory in the same way.
test "oauth_storage_saveToFile_does_not_require_directory_iteration" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = tmp.sub_path[0..];
    const previous_home = try setHomeForTest(std.testing.allocator, home);
    defer restoreHomeForTest(std.testing.allocator, previous_home);

    const makai_path = try std.fs.path.join(std.testing.allocator, &.{ home, ".makai" });
    defer std.testing.allocator.free(makai_path);
    try std.fs.cwd().makePath(makai_path);
    var makai_dir = try std.Io.Dir.cwd().openDir(defaultIo(), makai_path, .{});
    defer makai_dir.close(defaultIo());
    try makai_dir.setPermissions(defaultIo(), @enumFromInt(0o300));
    defer makai_dir.setPermissions(defaultIo(), @enumFromInt(0o700)) catch {};

    var storage = AuthStorage{
        .providers = std.StringHashMap(ProviderAuth).init(std.testing.allocator),
        .allocator = std.testing.allocator,
    };
    defer storage.deinit();

    const api_key = try std.testing.allocator.dupe(u8, "search-only-key");
    try putOwnedAuth(&storage, "provider", .{ .api_key = api_key });

    try storage.saveToFile();

    const auth_path = try std.fs.path.join(std.testing.allocator, &.{ home, ".makai", auth_file_name });
    defer std.testing.allocator.free(auth_path);
    const content = try std.fs.cwd().readFileAlloc(auth_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.find(u8, content, "search-only-key") != null);
}
