const std = @import("std");
const ai_types = @import("ai_types");
const agent = @import("agent");
const compat = @import("compat");

pub const max_file_bytes: usize = 16 * 1024 * 1024;
pub const process_output_bytes: usize = 16 * 1024 * 1024;
pub const process_poll_ms: u64 = 100;
pub const max_results: usize = 200;

pub fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

pub fn nowMs() i64 {
    return compat.time.nowMillis();
}

pub fn durationMs(start_ms: i64) u64 {
    const elapsed = nowMs() - start_ms;
    return if (elapsed <= 0) 0 else @intCast(elapsed);
}

pub fn isCancelled(cancel_token: ?ai_types.CancelToken) bool {
    if (cancel_token) |token| return token.isCancelled();
    return false;
}

pub fn parseArgs(allocator: std.mem.Allocator, args_json: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch return error.InvalidArgumentsJson;
    if (parsed.value != .object) {
        var mutable = parsed;
        mutable.deinit();
        return error.InvalidArgumentsJson;
    }
    return parsed;
}

pub fn requiredString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = obj.get(key) orelse return error.MissingRequiredArgument;
    if (value != .string) return error.InvalidArgumentType;
    return value.string;
}

pub fn optionalString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

pub fn optionalBool(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const value = obj.get(key) orelse return default;
    if (value != .bool) return default;
    return value.bool;
}

pub fn optionalU64(obj: std.json.ObjectMap, key: []const u8, default: u64) u64 {
    const value = obj.get(key) orelse return default;
    return switch (value) {
        .integer => |i| if (i < 0) default else @intCast(i),
        .float => |f| floatToU64(f) orelse default,
        .number_string => |s| std.fmt.parseUnsigned(u64, s, 10) catch default,
        else => default,
    };
}

pub fn optionalUsize(obj: std.json.ObjectMap, key: []const u8, default: usize) usize {
    const value = optionalU64(obj, key, default);
    if (value > std.math.maxInt(usize)) return default;
    return @intCast(value);
}

fn floatToU64(value: f64) ?u64 {
    if (!std.math.isFinite(value) or value < 0 or value >= 18446744073709551616.0) return null;
    return @intFromFloat(value);
}

test "optional numeric helpers reject overflow floats" {
    var parsed = try parseArgs(std.testing.allocator, "{\"timeout_ms\":1e30,\"ok\":42}");
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(u64, 30_000), optionalU64(obj, "timeout_ms", 30_000));
    try std.testing.expectEqual(@as(usize, 42), optionalUsize(obj, "ok", 0));
}

pub fn hasParentTraversal(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

pub fn openWorkspace(workspace_root: []const u8, iterate: bool) !std.Io.Dir {
    if (!std.Io.Dir.path.isAbsolute(workspace_root)) return error.WorkspaceRootMustBeAbsolute;
    return std.Io.Dir.openDirAbsolute(defaultIo(), workspace_root, .{ .iterate = iterate });
}

pub fn resolveWorkspacePath(allocator: std.mem.Allocator, workspace_root: []const u8, path_value: []const u8) ![]u8 {
    if (std.Io.Dir.path.isAbsolute(path_value)) {
        const normalized_root = try std.Io.Dir.path.resolve(allocator, &.{workspace_root});
        defer allocator.free(normalized_root);
        const normalized_path = try std.Io.Dir.path.resolve(allocator, &.{path_value});
        defer allocator.free(normalized_path);
        if (std.mem.eql(u8, normalized_path, normalized_root)) return try allocator.dupe(u8, "");
        if (isFilesystemRoot(normalized_root)) {
            if (!std.mem.startsWith(u8, normalized_path, normalized_root)) return error.PathEscapesWorkspace;
            const offset: usize = if (std.mem.endsWith(u8, normalized_root, &.{std.Io.Dir.path.sep})) normalized_root.len else normalized_root.len + 1;
            if (normalized_path.len < offset) return try allocator.dupe(u8, "");
            return try allocator.dupe(u8, normalized_path[offset..]);
        }
        if (!std.mem.startsWith(u8, normalized_path, normalized_root)) return error.PathEscapesWorkspace;
        if (normalized_path.len <= normalized_root.len) return error.PathEscapesWorkspace;
        const sep = normalized_path[normalized_root.len];
        if (sep != std.Io.Dir.path.sep) return error.PathEscapesWorkspace;
        return try allocator.dupe(u8, normalized_path[normalized_root.len + 1 ..]);
    }
    if (hasParentTraversal(path_value)) return error.PathEscapesWorkspace;
    return try allocator.dupe(u8, path_value);
}

fn isFilesystemRoot(path: []const u8) bool {
    if (std.mem.eql(u8, path, &.{std.Io.Dir.path.sep})) return true;
    if (@import("builtin").os.tag == .windows) {
        return path.len == 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
    }
    return false;
}

pub fn readWorkspaceFile(allocator: std.mem.Allocator, workspace_root: []const u8, path_value: []const u8, max_bytes: usize) ![]u8 {
    var file = try openWorkspaceFile(allocator, workspace_root, path_value);
    defer file.close(defaultIo());
    var file_reader = file.reader(defaultIo(), &.{});
    return file_reader.interface.allocRemaining(allocator, .limited(max_bytes)) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

pub fn writeWorkspaceFile(allocator: std.mem.Allocator, workspace_root: []const u8, path_value: []const u8, data: []const u8) !void {
    const relative_path = try resolveWorkspacePath(allocator, workspace_root, path_value);
    defer allocator.free(relative_path);
    var dir = try openWorkspace(workspace_root, false);
    defer dir.close(defaultIo());
    try ensureNoSymlinkComponents(allocator, dir, relative_path);
    var file = try dir.createFile(defaultIo(), relative_path, .{ .truncate = true, .permissions = compat.fs.default_file_mode, .resolve_beneath = true });
    defer file.close(defaultIo());
    try file.writeStreamingAll(defaultIo(), data);
}

pub fn statWorkspaceFile(allocator: std.mem.Allocator, workspace_root: []const u8, path_value: []const u8) !std.Io.File.Stat {
    const relative_path = try resolveWorkspacePath(allocator, workspace_root, path_value);
    defer allocator.free(relative_path);
    var dir = try openWorkspace(workspace_root, false);
    defer dir.close(defaultIo());
    try ensureNoSymlinkComponents(allocator, dir, relative_path);
    return dir.statFile(defaultIo(), relative_path, .{ .follow_symlinks = false });
}

pub fn openWorkspaceFile(allocator: std.mem.Allocator, workspace_root: []const u8, path_value: []const u8) !std.Io.File {
    const relative_path = try resolveWorkspacePath(allocator, workspace_root, path_value);
    defer allocator.free(relative_path);
    var dir = try openWorkspace(workspace_root, false);
    defer dir.close(defaultIo());
    try ensureNoSymlinkComponents(allocator, dir, relative_path);
    return dir.openFile(defaultIo(), relative_path, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
}

fn ensureNoSymlinkComponents(allocator: std.mem.Allocator, dir: std.Io.Dir, relative_path: []const u8) !void {
    if (relative_path.len == 0) return error.InvalidFilePath;
    var prefix = std.ArrayList(u8).empty;
    defer prefix.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, relative_path, "/\\");
    while (it.next()) |part| {
        if (prefix.items.len != 0) try prefix.append(allocator, std.Io.Dir.path.sep);
        try prefix.appendSlice(allocator, part);
        dir.access(defaultIo(), prefix.items, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const st = try dir.statFile(defaultIo(), prefix.items, .{ .follow_symlinks = false });
        if (st.kind == .sym_link) return error.PathEscapesWorkspace;
    }
}

pub fn isBinary(data: []const u8) bool {
    const limit = @min(data.len, 4096);
    return std.mem.indexOfScalar(u8, data[0..limit], 0) != null;
}

pub fn makeTextResult(allocator: std.mem.Allocator, text: []const u8, details_json: []const u8) !agent.AgentToolResult {
    const parts = try allocator.alloc(ai_types.UserContentPart, 1);
    errdefer allocator.free(parts);
    parts[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    errdefer parts[0].deinit(allocator);
    return .{
        .content = ai_types.OwnedSlice(ai_types.UserContentPart).initOwned(parts),
        .details_json = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, details_json)),
    };
}

pub fn makeTextResultOwned(allocator: std.mem.Allocator, text: []u8, details_json: []u8) !agent.AgentToolResult {
    const parts = try allocator.alloc(ai_types.UserContentPart, 1);
    errdefer allocator.free(parts);
    parts[0] = .{ .text = .{ .text = text } };
    return .{
        .content = ai_types.OwnedSlice(ai_types.UserContentPart).initOwned(parts),
        .details_json = ai_types.OwnedSlice(u8).initOwned(details_json),
    };
}

pub fn jsonString(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

test "common path and binary helpers" {
    const cwd = try std.process.currentPathAlloc(defaultIo(), std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const root = try std.Io.Dir.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", "common-test-root" });
    defer std.testing.allocator.free(root);
    const inside_abs = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "dir", "file.txt" });
    defer std.testing.allocator.free(inside_abs);
    const inside_rel = try resolveWorkspacePath(std.testing.allocator, root, inside_abs);
    defer std.testing.allocator.free(inside_rel);
    try std.testing.expectEqualStrings("dir/file.txt", inside_rel);
    const root_rel = try resolveWorkspacePath(std.testing.allocator, root, root);
    defer std.testing.allocator.free(root_rel);
    try std.testing.expectEqualStrings("", root_rel);
    if (@import("builtin").os.tag != .windows) {
        const root_child = try resolveWorkspacePath(std.testing.allocator, "/", "/tmp/root-child.txt");
        defer std.testing.allocator.free(root_child);
        try std.testing.expectEqualStrings("tmp/root-child.txt", root_child);
    } else {
        try std.testing.expect(isFilesystemRoot("C:\\"));
    }
    const outside = try std.Io.Dir.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "outside.txt" });
    defer std.testing.allocator.free(outside);
    try std.testing.expectError(error.PathEscapesWorkspace, resolveWorkspacePath(std.testing.allocator, root, outside));
    const traversal = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "..", "outside.txt" });
    defer std.testing.allocator.free(traversal);
    try std.testing.expectError(error.PathEscapesWorkspace, resolveWorkspacePath(std.testing.allocator, root, traversal));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try std.Io.Dir.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(tmp_root);
    try tmp.dir.symLink(defaultIo(), "/", "link", .{ .is_directory = true });
    try std.testing.expectError(error.PathEscapesWorkspace, readWorkspaceFile(std.testing.allocator, tmp_root, "link/passwd", 1024));
    try std.testing.expect(hasParentTraversal("a/../b"));
    try std.testing.expect(hasParentTraversal("a\\..\\b"));
    try std.testing.expect(!hasParentTraversal("a/..b/c"));
    try std.testing.expect(!isBinary(""));
    try std.testing.expect(!isBinary("abc"));
    try std.testing.expect(isBinary("a\x00b"));
    var boundary = [_]u8{'a'} ** 4097;
    boundary[4095] = 0;
    try std.testing.expect(isBinary(&boundary));
    boundary[4095] = 'a';
    boundary[4096] = 0;
    try std.testing.expect(!isBinary(&boundary));
}
