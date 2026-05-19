const std = @import("std");
const ai_types = @import("ai_types");
const agent = @import("agent");
const compat = @import("compat");

pub const max_file_bytes: usize = 16 * 1024 * 1024;
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
        .float => |f| if (f < 0) default else @intFromFloat(f),
        .number_string => |s| std.fmt.parseUnsigned(u64, s, 10) catch default,
        else => default,
    };
}

pub fn optionalUsize(obj: std.json.ObjectMap, key: []const u8, default: usize) usize {
    return @intCast(optionalU64(obj, key, default));
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

pub fn resolveRelativePath(allocator: std.mem.Allocator, path_value: []const u8) ![]u8 {
    if (std.Io.Dir.path.isAbsolute(path_value)) return try allocator.dupe(u8, path_value);
    if (hasParentTraversal(path_value)) return error.PathEscapesWorkspace;
    return try allocator.dupe(u8, path_value);
}

pub fn readWorkspaceFile(allocator: std.mem.Allocator, workspace_root: []const u8, path_value: []const u8, max_bytes: usize) ![]u8 {
    if (std.Io.Dir.path.isAbsolute(path_value)) {
        return std.Io.Dir.cwd().readFileAlloc(defaultIo(), path_value, allocator, .limited(max_bytes));
    }
    if (hasParentTraversal(path_value)) return error.PathEscapesWorkspace;
    var dir = try openWorkspace(workspace_root, false);
    defer dir.close(defaultIo());
    return dir.readFileAlloc(defaultIo(), path_value, allocator, .limited(max_bytes));
}

pub fn writeWorkspaceFile(workspace_root: []const u8, path_value: []const u8, data: []const u8) !void {
    if (std.Io.Dir.path.isAbsolute(path_value)) {
        var file = try std.Io.Dir.cwd().createFile(defaultIo(), path_value, .{ .truncate = true, .permissions = compat.fs.default_file_mode });
        defer file.close(defaultIo());
        try file.writeStreamingAll(defaultIo(), data);
        return;
    }
    if (hasParentTraversal(path_value)) return error.PathEscapesWorkspace;
    var dir = try openWorkspace(workspace_root, false);
    defer dir.close(defaultIo());
    var file = try dir.createFile(defaultIo(), path_value, .{ .truncate = true, .permissions = compat.fs.default_file_mode });
    defer file.close(defaultIo());
    try file.writeStreamingAll(defaultIo(), data);
}

pub fn statWorkspaceFile(workspace_root: []const u8, path_value: []const u8) !std.Io.File.Stat {
    if (std.Io.Dir.path.isAbsolute(path_value)) {
        return std.Io.Dir.cwd().statFile(defaultIo(), path_value, .{});
    }
    if (hasParentTraversal(path_value)) return error.PathEscapesWorkspace;
    var dir = try openWorkspace(workspace_root, false);
    defer dir.close(defaultIo());
    return dir.statFile(defaultIo(), path_value, .{});
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
