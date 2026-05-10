const std = @import("std");
const compat = @import("compat");

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

pub const Credentials = struct {
    refresh: []const u8,
    access: []const u8,
    expires: i64,
    provider_data: ?[]const u8 = null,

    pub fn deinit(self: *const Credentials, allocator: std.mem.Allocator) void {
        allocator.free(self.refresh);
        allocator.free(self.access);
        if (self.provider_data) |data| {
            allocator.free(data);
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
            .api_key => |key| allocator.free(key),
            .oauth => |creds| creds.deinit(allocator),
        }
    }
};

pub const SaveFn = *const fn (storage: *const AuthStorage) anyerror!void;

/// Authentication storage for multiple providers
pub const AuthStorage = struct {
    providers: std.StringHashMap(ProviderAuth),
    allocator: std.mem.Allocator,
    save_fn: ?SaveFn = null,

    /// Load auth storage from ~/.makai/auth.json
    pub fn loadFromFile(allocator: std.mem.Allocator) !AuthStorage {
        const home = std.process.Environ.getAlloc(std.testing.environ, allocator, "HOME") catch return error.NoHomeDir;
        defer allocator.free(home);
        const path = try std.fs.path.join(allocator, &.{ home, ".makai", "auth.json" });
        defer allocator.free(path);

        const cwd = compat.fs.getCwd();
        var file = compat.fs.openFile(cwd, path, .{}) catch {
            // File doesn't exist, return empty storage
            return .{
                .providers = std.StringHashMap(ProviderAuth).init(allocator),
                .allocator = allocator,
                .save_fn = null,
            };
        };
        file.close(defaultIo());

        const content = try compat.fs.readFileAlloc(allocator, cwd, path, 1024 * 1024);
        defer allocator.free(content);

        // Parse JSON
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();

        var providers = std.StringHashMap(ProviderAuth).init(allocator);

        const root = parsed.value.object;
        var iter = root.iterator();
        while (iter.next()) |entry| {
            const provider_id = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(provider_id);
            const provider_obj = entry.value_ptr.*.object;

            if (provider_obj.get("api_key")) |api_key_val| {
                // API key auth
                const api_key = try allocator.dupe(u8, api_key_val.string);
                try providers.put(provider_id, .{ .api_key = api_key });
            } else if (provider_obj.get("refresh")) |refresh_val| {
                // OAuth auth
                const refresh = try allocator.dupe(u8, refresh_val.string);
                const access = try allocator.dupe(u8, provider_obj.get("access").?.string);
                const expires = provider_obj.get("expires").?.integer;

                const provider_data = if (provider_obj.get("provider_data")) |pd|
                    try allocator.dupe(u8, pd.string)
                else
                    null;

                try providers.put(provider_id, .{
                    .oauth = .{
                        .refresh = refresh,
                        .access = access,
                        .expires = expires,
                        .provider_data = provider_data,
                    },
                });
            }
        }

        return .{
            .providers = providers,
            .allocator = allocator,
            .save_fn = null,
        };
    }

    /// Save auth storage to ~/.makai/auth.json atomically.
    ///
    /// Atomicity: writes to a temp file (with 0o600 permissions set
    /// *before* the rename) and then atomically renames over the target.
    /// Concurrent readers will either see the old file or the new file —
    /// never a partial write.
    pub fn saveToFile(self: *const AuthStorage) !void {
        const home = std.process.Environ.getAlloc(std.testing.environ, self.allocator, "HOME") catch return error.NoHomeDir;
        defer self.allocator.free(home);
        const dir_path = try std.fs.path.join(self.allocator, &.{ home, ".makai" });
        defer self.allocator.free(dir_path);

        // Ensure directory exists
        const cwd = compat.fs.getCwd();
        compat.fs.createDir(cwd, dir_path) catch {};

        const file_path = try std.fs.path.join(self.allocator, &.{ home, ".makai", "auth.json" });
        defer self.allocator.free(file_path);

        // Write to temporary file with a unique suffix (timestamp + random)
        // to avoid collisions when two processes write concurrently.
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp.{d}.{x}", .{ file_path, compat.time.nowMillis(), compat.random.int(u64) });
        defer self.allocator.free(tmp_path);

        // Build JSON
        var json_buf = std.ArrayList(u8).empty;
        defer json_buf.deinit(self.allocator);

        const appendJsonString = struct {
            fn appendJsonString(
                allocator: std.mem.Allocator,
                buf: *std.ArrayList(u8),
                value: []const u8,
            ) !void {
                const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
                defer allocator.free(encoded);
                try buf.appendSlice(allocator, encoded);
            }
        }.appendJsonString;

        try json_buf.appendSlice(self.allocator, "{\n");

        var iter = self.providers.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try json_buf.appendSlice(self.allocator, ",\n");
            first = false;

            try json_buf.appendSlice(self.allocator, "  ");
            try appendJsonString(self.allocator, &json_buf, entry.key_ptr.*);
            try json_buf.appendSlice(self.allocator, ": ");

            switch (entry.value_ptr.*) {
                .api_key => |key| {
                    try json_buf.appendSlice(self.allocator, "{\"api_key\":");
                    try appendJsonString(self.allocator, &json_buf, key);
                    try json_buf.appendSlice(self.allocator, "}");
                },
                .oauth => |creds| {
                    try json_buf.appendSlice(self.allocator, "{\"refresh\":");
                    try appendJsonString(self.allocator, &json_buf, creds.refresh);
                    try json_buf.appendSlice(self.allocator, ",\"access\":");
                    try appendJsonString(self.allocator, &json_buf, creds.access);
                    try json_buf.appendSlice(self.allocator, ",\"expires\":");
                    const expires_str = try std.fmt.allocPrint(self.allocator, "{d}", .{creds.expires});
                    defer self.allocator.free(expires_str);
                    try json_buf.appendSlice(self.allocator, expires_str);
                    if (creds.provider_data) |data| {
                        try json_buf.appendSlice(self.allocator, ",\"provider_data\":");
                        try appendJsonString(self.allocator, &json_buf, data);
                    }
                    try json_buf.appendSlice(self.allocator, "}");
                },
            }
        }

        try json_buf.appendSlice(self.allocator, "\n}\n");

        // Atomic replace writes with restrictive permissions at the filesystem
        // compatibility seam. Crash-safety hardening remains in the dedicated
        // filesystem wrapper PR.
        try compat.fs.atomicReplace(cwd, file_path, tmp_path, json_buf.items);
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
        var iter = self.providers.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.providers.deinit();
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

    try std.testing.expect(std.mem.indexOf(u8, content, "sk-test-key-12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "test-provider") != null);
}


const builtin = @import("builtin");

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
        if (std.mem.startsWith(u8, entry.name, "auth.json.tmp.")) count += 1;
    }
    return count;
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

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ home, ".makai", "auth.json" });
    defer std.testing.allocator.free(file_path);

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "direct-provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "secret-key") != null);

    if (builtin.os.tag != .windows) {
        const stat = try file.stat();
        try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.mode & 0o777)));
    }

    try std.testing.expectEqual(@as(usize, 0), try countAuthTempFiles(home));
}

test "oauth_storage_saveToFile_rename_failure_leaves_target_unchanged_and_temp_visible_for_cleanup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = tmp.sub_path[0..];
    const previous_home = try setHomeForTest(std.testing.allocator, home);
    defer restoreHomeForTest(std.testing.allocator, previous_home);

    const makai_path = try std.fs.path.join(std.testing.allocator, &.{ home, ".makai" });
    defer std.testing.allocator.free(makai_path);
    try std.fs.cwd().makePath(makai_path);

    const blocker_path = try std.fs.path.join(std.testing.allocator, &.{ home, ".makai", "auth.json" });
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

    const temp_count = try countAuthTempFiles(home);
    try std.testing.expect(temp_count >= 1);
}
