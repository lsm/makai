const std = @import("std");

pub const OpenFlags = std.fs.File.OpenFlags;
pub const CreateFlags = std.fs.File.CreateFlags;
pub const File = std.fs.File;

/// Return the process current working directory handle.
///
/// Zig 0.16 mapping: this remains the stable wrapper for cwd access. Internal
/// implementation may borrow the Makai default I/O context, but public callers
/// should not receive or pass raw `std.Io` handles.
pub fn getCwd() std.fs.Dir {
    return std.fs.cwd();
}

/// Open a file relative to `dir`.
///
/// Parameter order follows the migration convention: I/O handle (`dir`) first
/// for handle-scoped operations, then operation-specific parameters.
pub fn openFile(dir: std.fs.Dir, path: []const u8, flags: OpenFlags) !File {
    return dir.openFile(path, flags);
}

/// Read a file relative to `dir` into an allocated buffer.
///
/// Zig 0.16 mapping: preserve allocation ownership and error behavior while
/// routing file reads through the Makai filesystem wrapper internals.
pub fn readFileAlloc(allocator: std.mem.Allocator, dir: std.fs.Dir, path: []const u8, max_bytes: usize) ![]u8 {
    return dir.readFileAlloc(allocator, path, max_bytes);
}

/// Write a file relative to `dir`, replacing existing contents.
pub fn writeFile(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    var file = try dir.createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

/// Atomically replace `target_path` by writing `data` to `tmp_path` in `dir` and
/// renaming it over the target.
///
/// Zig 0.16 mapping: keep the same-directory temporary-file boundary so later
/// OAuth storage work can preserve same-filesystem rename guarantees and file
/// mode expectations. This skeleton is intentionally thin; crash-safety policy
/// hardening belongs to the dedicated filesystem wrapper PR.
pub fn atomicReplace(dir: std.fs.Dir, target_path: []const u8, tmp_path: []const u8, data: []const u8) !void {
    var cleanup_tmp = true;
    defer if (cleanup_tmp) dir.deleteFile(tmp_path) catch {};

    try writeFile(dir, tmp_path, data);
    try dir.rename(tmp_path, target_path);
    cleanup_tmp = false;
}

/// Create a directory and any missing parents relative to `dir`.
pub fn createDir(dir: std.fs.Dir, path: []const u8) !void {
    try dir.makePath(path);
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

    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("compat.txt.tmp", .{}));
}

test "compat filesystem wrappers create directories and open files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createDir(tmp.dir, "nested/path");
    try writeFile(tmp.dir, "nested/path/file.txt", "data");

    var file = try openFile(tmp.dir, "nested/path/file.txt", .{});
    defer file.close();

    var buf: [4]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings("data", buf[0..n]);
}

test "compat getCwd returns a directory handle" {
    const cwd = getCwd();
    _ = cwd;
}
