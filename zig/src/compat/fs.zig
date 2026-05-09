const std = @import("std");

pub const OpenFlags = std.fs.File.OpenFlags;
pub const CreateFlags = std.fs.File.CreateFlags;
pub const File = std.fs.File;
pub const Dir = std.fs.Dir;

pub const default_file_mode: std.fs.File.Mode = 0o600;
const max_file_bytes = 1024 * 1024;

/// Return the process current working directory handle.
///
/// Zig 0.16 mapping: this remains the stable wrapper for cwd access. Internal
/// implementation may borrow the Makai default I/O context, but public callers
/// should not receive or pass raw `std.Io` handles.
pub fn getCwd() Dir {
    return std.fs.cwd();
}

/// Open a file from the process current working directory.
///
/// Zig 0.16 mapping: preserve this project-level seam while rerouting the
/// implementation through the selected Makai filesystem context. The public
/// signature intentionally exposes `std.fs.File`, not raw `std.Io`.
pub fn openFile(path: []const u8, flags: OpenFlags) !File {
    return getCwd().openFile(path, flags);
}

/// Read a file from the process current working directory into caller-owned
/// memory. The returned slice is owned by `allocator`.
///
/// Zig 0.16 mapping: keep allocation ownership and error behavior stable while
/// moving the internals to the future filesystem/I/O context.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_file_bytes);
}

/// Write `data` to `path` from the process current working directory.
///
/// Files are created with restrictive permissions because this wrapper will be
/// used by credential storage in a later PR. Existing files are truncated through
/// the same `std.fs` semantics used today by call sites that directly create
/// files.
pub fn writeFile(path: []const u8, data: []const u8) !void {
    var file = try getCwd().createFile(path, .{ .truncate = true, .mode = default_file_mode });
    defer file.close();
    try file.writeAll(data);
}

/// Create a directory at an absolute path.
///
/// Zig 0.16 mapping: this wraps the current absolute-directory creation API so
/// later I/O-context plumbing can be localized here.
pub fn createDir(path: []const u8) !void {
    try std.fs.makeDirAbsolute(path);
}

fn dirnameOrDot(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

fn tempPath(allocator: std.mem.Allocator, target_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}.tmp.{d}.{x}",
        .{ target_path, std.time.milliTimestamp(), std.crypto.random.int(u64) },
    );
}

fn chmodPath(path: []const u8, mode: std.fs.File.Mode) !void {
    var file = try getCwd().openFile(path, .{ .mode = .write_only });
    defer file.close();
    try file.chmod(mode);
}

fn writeFileFailAfter(path: []const u8, data: []const u8, fail_after: ?usize) !void {
    var file = try getCwd().createFile(path, .{ .truncate = true, .mode = default_file_mode });
    defer file.close();

    if (fail_after) |limit| {
        const bytes_to_write = @min(limit, data.len);
        if (bytes_to_write > 0) try file.writeAll(data[0..bytes_to_write]);
        return error.InjectedPartialWriteFailure;
    }

    try file.writeAll(data);
    try file.sync();
}

fn atomicReplaceWithInjectedFailure(allocator: std.mem.Allocator, path: []const u8, data: []const u8, fail_after: ?usize) !void {
    const tmp_path = try tempPath(allocator, path);
    defer allocator.free(tmp_path);

    if (std.mem.eql(u8, path, tmp_path)) return error.InvalidAtomicReplacePaths;

    var cleanup_tmp = true;
    defer if (cleanup_tmp) getCwd().deleteFile(tmp_path) catch {};

    try writeFileFailAfter(tmp_path, data, fail_after);
    try chmodPath(tmp_path, default_file_mode);
    try getCwd().rename(tmp_path, path);
    cleanup_tmp = false;
}

/// Atomically replace `path` with `data`.
///
/// The temporary file is created next to the target so `rename` stays on the
/// same filesystem. The target is not opened or truncated before the rename, so
/// readers see either the old file or the new complete file. The replacement file
/// is committed with `0o600` permissions, matching credential-file safety
/// requirements. Failed writes clean up the temporary file where possible.
///
/// Zig 0.16 mapping: keep this same-directory temp-file boundary and public
/// signature; only the internals should change when std.fs/std.Io APIs move.
pub fn atomicReplace(path: []const u8, data: []const u8) !void {
    try atomicReplaceWithInjectedFailure(std.heap.page_allocator, path, data, null);
}

fn makeTmpPath(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir, relative_path: []const u8) ![]u8 {
    const real = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(real);
    return std.fs.path.join(allocator, &.{ real, relative_path });
}

fn fileExists(path: []const u8) bool {
    var file = getCwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

test "compat filesystem wrappers read write round trip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try makeTmpPath(allocator, tmp, "compat.txt");
    defer allocator.free(path);

    try writeFile(path, "one");
    const content = try readFileAlloc(allocator, path);
    defer allocator.free(content);

    try std.testing.expectEqualStrings("one", content);
}

test "compat filesystem wrappers report missing file errors" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try makeTmpPath(allocator, tmp, "missing.txt");
    defer allocator.free(path);

    try std.testing.expectError(error.FileNotFound, openFile(path, .{}));
    try std.testing.expectError(error.FileNotFound, readFileAlloc(allocator, path));
}

test "compat filesystem wrappers create directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try makeTmpPath(allocator, tmp, "nested");
    defer allocator.free(dir_path);
    const file_path = try makeTmpPath(allocator, tmp, "nested/file.txt");
    defer allocator.free(file_path);

    try createDir(dir_path);
    try writeFile(file_path, "data");

    const content = try readFileAlloc(allocator, file_path);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("data", content);
}

test "compat atomic replace commits complete data with mode 0600" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try makeTmpPath(allocator, tmp, "atomic.txt");
    defer allocator.free(path);

    try writeFile(path, "old");
    try chmodPath(path, 0o644);
    try atomicReplace(path, "new credential contents");

    const content = try readFileAlloc(allocator, path);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("new credential contents", content);

    const stat = try getCwd().statFile(path);
    try std.testing.expectEqual(@as(std.fs.File.Mode, default_file_mode), stat.mode & 0o777);
}

test "compat atomic replace cleans temp after partial write failure" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try makeTmpPath(allocator, tmp, "partial.txt");
    defer allocator.free(path);

    try writeFile(path, "old stable contents");
    try std.testing.expectError(
        error.InjectedPartialWriteFailure,
        atomicReplaceWithInjectedFailure(allocator, path, "new contents", 3),
    );

    const content = try readFileAlloc(allocator, path);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("old stable contents", content);

    const leaked_tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(leaked_tmp);
    try std.testing.expect(!fileExists(leaked_tmp));

    var target_dir = try getCwd().openDir(dirnameOrDot(path), .{ .iterate = true });
    defer target_dir.close();
    var iter = target_dir.iterate();
    const prefix = try std.fmt.allocPrint(allocator, "{s}.tmp.", .{basename(path)});
    defer allocator.free(prefix);
    while (try iter.next()) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, prefix));
    }
}

test "compat atomic replace leaves existing file untouched before successful rename" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try makeTmpPath(allocator, tmp, "unchanged.txt");
    defer allocator.free(path);

    try writeFile(path, "do not truncate");
    try std.testing.expectError(
        error.InjectedPartialWriteFailure,
        atomicReplaceWithInjectedFailure(allocator, path, "replacement", 0),
    );

    const content = try readFileAlloc(allocator, path);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("do not truncate", content);
}

test "compat getCwd returns a directory handle" {
    const cwd = getCwd();
    _ = cwd;
}
