const std = @import("std");

pub const OpenFlags = std.Io.Dir.OpenFileOptions;
pub const CreateFlags = std.Io.Dir.CreateFileOptions;
pub const File = std.Io.File;
pub const Dir = std.Io.Dir;

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

pub fn getCwd() Dir {
    return Dir.cwd();
}

pub fn openFile(dir: Dir, path: []const u8, flags: OpenFlags) !File {
    return dir.openFile(defaultIo(), path, flags);
}

pub fn readFileAlloc(allocator: std.mem.Allocator, dir: Dir, path: []const u8, max_bytes: usize) ![]u8 {
    return dir.readFileAlloc(defaultIo(), path, allocator, .limited(max_bytes));
}

pub const default_file_mode: std.Io.File.Permissions = @enumFromInt(0o600);

pub fn writeFile(dir: Dir, path: []const u8, data: []const u8) !void {
    var file = try dir.createFile(defaultIo(), path, .{ .truncate = true, .permissions = default_file_mode });
    defer file.close(defaultIo());
    try file.writeStreamingAll(defaultIo(), data);
}

pub fn atomicReplace(dir: Dir, target_path: []const u8, tmp_path: []const u8, data: []const u8) !void {
    if (std.mem.eql(u8, target_path, tmp_path)) return error.InvalidAtomicReplacePaths;

    dir.deleteFile(defaultIo(), tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    var cleanup_tmp = false;
    defer if (cleanup_tmp) dir.deleteFile(defaultIo(), tmp_path) catch {};

    {
        var file = try dir.createFile(defaultIo(), tmp_path, .{ .truncate = false, .exclusive = true, .permissions = default_file_mode });
        cleanup_tmp = true;
        defer file.close(defaultIo());
        try file.writeStreamingAll(defaultIo(), data);
    }

    try dir.rename(tmp_path, dir, target_path, defaultIo());
    cleanup_tmp = false;
}

pub fn createDir(dir: Dir, path: []const u8) !void {
    try dir.createDirPath(defaultIo(), path);
}

test "compat filesystem wrappers read write and atomically replace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "compat.txt", "one");
    const initial = try readFileAlloc(std.testing.allocator, tmp.dir, "compat.txt", 1024);
    defer std.testing.allocator.free(initial);
    try std.testing.expectEqualStrings("one", initial);

    try atomicReplace(tmp.dir, "compat.txt", "compat.txt.tmp", "two");
    const replaced = try readFileAlloc(std.testing.allocator, tmp.dir, "compat.txt", 1024);
    defer std.testing.allocator.free(replaced);
    try std.testing.expectEqualStrings("two", replaced);

    try std.testing.expectError(error.FileNotFound, openFile(tmp.dir, "compat.txt.tmp", .{}));
}

test "compat atomic replace re-hardens existing target mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "mode.txt", "one");
    {
        var file = try openFile(tmp.dir, "mode.txt", .{ .mode = .write_only });
        defer file.close(defaultIo());
        try file.setPermissions(defaultIo(), @enumFromInt(0o640));
    }

    try atomicReplace(tmp.dir, "mode.txt", "mode.txt.tmp", "two");

    const stat = try tmp.dir.statFile(defaultIo(), "mode.txt", .{});
    try std.testing.expectEqual(default_file_mode, @as(std.Io.File.Permissions, @enumFromInt(@intFromEnum(stat.permissions) & 0o777)));
}

test "compat atomic replace recovers from a stale temporary path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "target.txt", "target");
    try writeFile(tmp.dir, "target.txt.tmp", "stale");

    try atomicReplace(tmp.dir, "target.txt", "target.txt.tmp", "new");

    const target = try readFileAlloc(std.testing.allocator, tmp.dir, "target.txt", 1024);
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("new", target);

    try std.testing.expectError(error.FileNotFound, openFile(tmp.dir, "target.txt.tmp", .{}));
}

test "compat filesystem wrappers create directories and open files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createDir(tmp.dir, "nested/path");
    try writeFile(tmp.dir, "nested/path/file.txt", "data");

    var file = try openFile(tmp.dir, "nested/path/file.txt", .{});
    defer file.close(defaultIo());

    var buf: [4]u8 = undefined;
    const n = try file.readStreaming(defaultIo(), &.{&buf});
    try std.testing.expectEqualStrings("data", buf[0..n]);
}

test "compat getCwd returns a directory handle" {
    const cwd = getCwd();
    _ = cwd;
}
