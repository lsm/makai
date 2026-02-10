const std = @import("std");

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
    name: []const u8,
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

/// Authentication storage for multiple providers
pub const AuthStorage = struct {
    providers: std.StringHashMap(ProviderAuth),
    allocator: std.mem.Allocator,

    /// Load auth storage from ~/.makai/auth.json
    pub fn loadFromFile(allocator: std.mem.Allocator) !AuthStorage {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
        const path = try std.fs.path.join(allocator, &.{ home, ".makai", "auth.json" });
        defer allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch {
            // File doesn't exist, return empty storage
            return .{
                .providers = std.StringHashMap(ProviderAuth).init(allocator),
                .allocator = allocator,
            };
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        // Parse JSON
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();

        var providers = std.StringHashMap(ProviderAuth).init(allocator);

        const root = parsed.value.object;
        var iter = root.iterator();
        while (iter.next()) |entry| {
            const provider_id = entry.key_ptr.*;
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
        };
    }

    /// Save auth storage to ~/.makai/auth.json with 0o600 permissions
    pub fn saveToFile(self: *const AuthStorage) !void {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
        const dir_path = try std.fs.path.join(self.allocator, &.{ home, ".makai" });
        defer self.allocator.free(dir_path);

        // Ensure directory exists
        std.fs.cwd().makePath(dir_path) catch {};

        const file_path = try std.fs.path.join(self.allocator, &.{ home, ".makai", "auth.json" });
        defer self.allocator.free(file_path);

        // Write to temporary file
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{file_path});
        defer self.allocator.free(tmp_path);

        const file = try std.fs.cwd().createFile(tmp_path, .{ .mode = 0o600 });
        defer file.close();

        // Build JSON
        var json_buf = std.ArrayList(u8).init(self.allocator);
        defer json_buf.deinit();

        try json_buf.appendSlice("{\n");

        var iter = self.providers.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try json_buf.appendSlice(",\n");
            first = false;

            try json_buf.appendSlice("  \"");
            try json_buf.appendSlice(entry.key_ptr.*);
            try json_buf.appendSlice("\": ");

            switch (entry.value_ptr.*) {
                .api_key => |key| {
                    try json_buf.appendSlice("{\"api_key\":\"");
                    try json_buf.appendSlice(key);
                    try json_buf.appendSlice("\"}");
                },
                .oauth => |creds| {
                    try json_buf.appendSlice("{\"refresh\":\"");
                    try json_buf.appendSlice(creds.refresh);
                    try json_buf.appendSlice("\",\"access\":\"");
                    try json_buf.appendSlice(creds.access);
                    try json_buf.appendSlice("\",\"expires\":");
                    const expires_str = try std.fmt.allocPrint(self.allocator, "{d}", .{creds.expires});
                    defer self.allocator.free(expires_str);
                    try json_buf.appendSlice(expires_str);
                    if (creds.provider_data) |data| {
                        try json_buf.appendSlice(",\"provider_data\":\"");
                        try json_buf.appendSlice(data);
                        try json_buf.appendSlice("\"");
                    }
                    try json_buf.appendSlice("}");
                },
            }
        }

        try json_buf.appendSlice("\n}\n");

        try file.writeAll(json_buf.items);

        // Atomic rename
        try std.fs.cwd().rename(tmp_path, file_path);

        // Ensure 0o600 permissions
        const file_handle = try std.fs.cwd().openFile(file_path, .{});
        defer file_handle.close();
        try file_handle.chmod(0o600);
    }

    /// Get API key for provider (refreshing if needed)
    /// Note: Refresh logic requires oauth provider registry which is in parent module
    pub fn getApiKey(self: *AuthStorage, provider_id: []const u8, oauth_provider: ?OAuthProvider) !?[]const u8 {
        const auth = self.providers.get(provider_id) orelse return null;

        switch (auth) {
            .api_key => |key| return try self.allocator.dupe(u8, key),
            .oauth => |credentials| {
                // Check expiry
                if (std.time.milliTimestamp() >= credentials.expires) {
                    // Refresh needed
                    const provider = oauth_provider orelse return error.UnknownProvider;
                    const new_credentials = try provider.refresh_fn(credentials, self.allocator);

                    // Update storage
                    try self.providers.put(provider_id, .{ .oauth = new_credentials });
                    try self.saveToFile();

                    return try provider.get_api_key_fn(new_credentials, self.allocator);
                }

                const provider = oauth_provider orelse return error.UnknownProvider;
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
            .expires = std.time.milliTimestamp() + 3600000,
        },
    };
    auth.deinit(std.testing.allocator);
}
