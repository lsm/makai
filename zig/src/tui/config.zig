const std = @import("std");
const compat = @import("compat");
const json_writer = @import("json/writer");

fn tmpBase(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "makai" });
    errdefer allocator.free(base);
    try compat.fs.createDir(compat.fs.getCwd(), base);
    return base;
}

pub const ToolPermission = struct {
    tool_name: []u8,
    mode: Mode = .ask,

    pub const Mode = enum { ask, allow, deny };

    pub fn deinit(self: *ToolPermission, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        self.* = undefined;
    }
};

pub const ModeSettings = struct {
    compact_output: bool = true,
};

const borrowed_empty_theme: []u8 = &.{};

pub const UiSettings = struct {
    theme: []u8 = borrowed_empty_theme,
    show_tool_panel: bool = true,

    pub fn deinit(self: *UiSettings, allocator: std.mem.Allocator) void {
        if (self.theme.ptr != borrowed_empty_theme.ptr) allocator.free(self.theme);
        self.* = .{};
    }
};

pub const Config = struct {
    model: []u8,
    provider: []u8,
    api: []u8,
    workspace: []u8,
    permissions: std.ArrayList(ToolPermission) = .empty,
    mode: ModeSettings = .{},
    ui: UiSettings = .{},

    pub fn defaults(allocator: std.mem.Allocator) !Config {
        return .{
            .model = try allocator.dupe(u8, "claude-sonnet-4-5"),
            .provider = try allocator.dupe(u8, "anthropic"),
            .api = try allocator.dupe(u8, "anthropic-messages"),
            .workspace = try allocator.dupe(u8, "."),
            .ui = .{ .theme = try allocator.dupe(u8, "default") },
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.model);
        allocator.free(self.provider);
        allocator.free(self.api);
        allocator.free(self.workspace);
        for (self.permissions.items) |*permission| permission.deinit(allocator);
        self.permissions.deinit(allocator);
        self.ui.deinit(allocator);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    base_dir: []u8,

    pub fn init(allocator: std.mem.Allocator, base_dir: []const u8) !Store {
        return .{ .allocator = allocator, .base_dir = try allocator.dupe(u8, base_dir) };
    }

    pub fn initDefault(allocator: std.mem.Allocator) !Store {
        const home = compat.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
            error.EnvironmentVariableMissing => return error.HomeNotFound,
            else => return err,
        };
        defer allocator.free(home);
        const base = try std.fs.path.join(allocator, &.{ home, ".makai" });
        defer allocator.free(base);
        return init(allocator, base);
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.base_dir);
        self.* = undefined;
    }

    pub fn load(self: Store) !Config {
        try compat.fs.createDir(compat.fs.getCwd(), self.base_dir);
        const path = try std.fs.path.join(self.allocator, &.{ self.base_dir, "config.json" });
        defer self.allocator.free(path);
        const data = compat.fs.readFileAlloc(self.allocator, compat.fs.getCwd(), path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => {
                var cfg = try Config.defaults(self.allocator);
                errdefer cfg.deinit(self.allocator);
                try self.save(cfg);
                return cfg;
            },
            else => return err,
        };
        defer self.allocator.free(data);
        return parseConfig(self.allocator, data);
    }

    pub fn loadIfExists(self: Store) !?Config {
        const path = try std.fs.path.join(self.allocator, &.{ self.base_dir, "config.json" });
        defer self.allocator.free(path);
        const data = compat.fs.readFileAlloc(self.allocator, compat.fs.getCwd(), path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer self.allocator.free(data);
        return try parseConfig(self.allocator, data);
    }

    pub fn save(self: Store, cfg: Config) !void {
        try compat.fs.createDir(compat.fs.getCwd(), self.base_dir);
        const path = try std.fs.path.join(self.allocator, &.{ self.base_dir, "config.json" });
        defer self.allocator.free(path);
        const tmp = try std.fs.path.join(self.allocator, &.{ self.base_dir, "config.json.tmp" });
        defer self.allocator.free(tmp);
        const data = try serializeConfig(self.allocator, cfg);
        defer self.allocator.free(data);
        try compat.fs.atomicReplace(compat.fs.getCwd(), path, tmp, data);
    }
};

fn parseConfig(allocator: std.mem.Allocator, data: []const u8) !Config {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };

    var cfg = Config{
        .model = try dupStringField(allocator, obj, "model", "claude-sonnet-4-5"),
        .provider = try dupStringField(allocator, obj, "provider", "anthropic"),
        .api = try dupStringField(allocator, obj, "api", ""),
        .workspace = try dupStringField(allocator, obj, "workspace", ""),
        .ui = .{ .theme = try allocator.dupe(u8, "default") },
    };
    errdefer cfg.deinit(allocator);

    if (cfg.workspace.len == 0) {
        allocator.free(cfg.workspace);
        cfg.workspace = try allocator.dupe(u8, ".");
    }

    if (obj.get("permissions")) |value| switch (value) {
        .array => |arr| for (arr.items) |item| {
            const perm_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const tool = stringField(perm_obj, "tool_name") orelse continue;
            const mode_text = stringField(perm_obj, "mode") orelse "ask";
            try cfg.permissions.append(allocator, .{
                .tool_name = try allocator.dupe(u8, tool),
                .mode = parsePermissionMode(mode_text),
            });
        },
        else => {},
    };

    if (obj.get("mode")) |value| switch (value) {
        .object => |mode_obj| {
            cfg.mode.compact_output = boolField(mode_obj, "compact_output", cfg.mode.compact_output);
        },
        else => {},
    };

    if (obj.get("ui")) |value| switch (value) {
        .object => |ui_obj| {
            if (stringField(ui_obj, "theme")) |theme| {
                if (cfg.ui.theme.len > 0) allocator.free(cfg.ui.theme);
                cfg.ui.theme = try allocator.dupe(u8, theme);
            }
            cfg.ui.show_tool_panel = boolField(ui_obj, "show_tool_panel", cfg.ui.show_tool_panel);
        },
        else => {},
    };

    return cfg;
}

fn serializeConfig(allocator: std.mem.Allocator, cfg: Config) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buf, allocator);
    try w.beginObject();
    try w.writeStringField("model", cfg.model);
    try w.writeStringField("provider", cfg.provider);
    try w.writeStringField("api", cfg.api);
    try w.writeStringField("workspace", cfg.workspace);
    try w.writeKey("permissions");
    try w.beginArray();
    for (cfg.permissions.items) |permission| {
        try w.beginObject();
        try w.writeStringField("tool_name", permission.tool_name);
        try w.writeStringField("mode", @tagName(permission.mode));
        try w.endObject();
    }
    try w.endArray();
    try w.writeKey("mode");
    try w.beginObject();
    try w.writeBoolField("compact_output", cfg.mode.compact_output);
    try w.endObject();
    try w.writeKey("ui");
    try w.beginObject();
    try w.writeStringField("theme", cfg.ui.theme);
    try w.writeBoolField("show_tool_panel", cfg.ui.show_tool_panel);
    try w.endObject();
    try w.endObject();
    try buf.append(allocator, '\n');
    return buf.toOwnedSlice(allocator);
}

fn dupStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, default: []const u8) ![]u8 {
    return try allocator.dupe(u8, stringField(obj, key) orelse default);
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn boolField(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const value = obj.get(key) orelse return default;
    return switch (value) {
        .bool => |b| b,
        else => default,
    };
}

fn parsePermissionMode(value: []const u8) ToolPermission.Mode {
    if (std.mem.eql(u8, value, "allow")) return .allow;
    if (std.mem.eql(u8, value, "deny")) return .deny;
    return .ask;
}

test "save config reload preserves model provider and api" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);

    var store = try Store.init(std.testing.allocator, base);
    defer store.deinit();

    var cfg = try Config.defaults(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    std.testing.allocator.free(cfg.model);
    cfg.model = try std.testing.allocator.dupe(u8, "model-b");
    std.testing.allocator.free(cfg.provider);
    cfg.provider = try std.testing.allocator.dupe(u8, "openai");
    std.testing.allocator.free(cfg.api);
    cfg.api = try std.testing.allocator.dupe(u8, "openai-responses");
    try cfg.permissions.append(std.testing.allocator, .{ .tool_name = try std.testing.allocator.dupe(u8, "shell_execute"), .mode = .deny });
    try store.save(cfg);

    var loaded = try store.load();
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("model-b", loaded.model);
    try std.testing.expectEqualStrings("openai", loaded.provider);
    try std.testing.expectEqualStrings("openai-responses", loaded.api);
    try std.testing.expectEqual(@as(usize, 1), loaded.permissions.items.len);
    try std.testing.expectEqual(ToolPermission.Mode.deny, loaded.permissions.items[0].mode);
}

test "missing config creates defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);

    var store = try Store.init(std.testing.allocator, base);
    defer store.deinit();
    var cfg = try store.load();
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", cfg.model);

    const path = try std.fs.path.join(std.testing.allocator, &.{ base, "config.json" });
    defer std.testing.allocator.free(path);
    const data = try compat.fs.readFileAlloc(std.testing.allocator, compat.fs.getCwd(), path, 1024);
    defer std.testing.allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "claude-sonnet-4-5") != null);
}

test "loadIfExists returns null without creating defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);

    var store = try Store.init(std.testing.allocator, base);
    defer store.deinit();

    const missing = try store.loadIfExists();
    try std.testing.expect(missing == null);

    const path = try std.fs.path.join(std.testing.allocator, &.{ base, "config.json" });
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.FileNotFound, compat.fs.readFileAlloc(std.testing.allocator, compat.fs.getCwd(), path, 1024));
}
