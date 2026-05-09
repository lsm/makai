const std = @import("std");
const compat_random = @import("random.zig");
const compat_time = @import("time.zig");

pub const OpenFlags = std.fs.File.OpenFlags;
pub const CreateFlags = std.fs.File.CreateFlags;
pub const File = std.fs.File;
pub const Dir = std.fs.Dir;

pub const default_file_mode: std.fs.File.Mode = 0o600;
pub const default_max_file_bytes = 1024 * 1024;

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
/// `max_bytes` preserves the caller-controlled limit from the initial wrapper
/// skeleton and mirrors `std.fs.File.readToEndAlloc` error behavior.
///
/// Zig 0.16 mapping: keep allocation ownership and error behavior stable while
/// moving the internals to the future filesystem/I/O context.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

/// Read a file using the credential/config-sized default cap.
pub fn readFileAllocDefault(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return readFileAlloc(allocator, path, default_max_file_bytes);
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

/// Create a directory path relative to cwd or at an absolute path.
///
/// This is recursive and idempotent, matching `std.fs.Dir.makePath` behavior so
/// first-run setup can safely create nested config/cache directories repeatedly.
///
/// Zig 0.16 mapping: route through the future filesystem/I/O context while
/// preserving relative-path support and recursive semantics.
pub fn createDir(path: []const u8) !void {
    try getCwd().makePath(path);
}

/// Explicit alias documenting the recursive semantics expected by later OAuth
/// storage migration work.
pub fn createDirAll(path: []const u8) !void {
    try createDir(path);
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
        .{ target_path, compat_time.nowMillis(), compat_random.randomIntRangeLessThan(u64, std.math.maxInt(u64)) },
    );
}

fn chmodFile(file: File, mode: std.fs.File.Mode) !void {
    try file.chmod(mode);
}

fn writeFileFailAfter(dir: Dir, path: []const u8, data: []const u8, mode: std.fs.File.Mode, fail_after: ?usize) !void {
    var file = try dir.createFile(path, .{ .truncate = true, .mode = mode });
    defer file.close();

    if (fail_after) |limit| {
        const bytes_to_write = @min(limit, data.len);
        if (bytes_to_write > 0) try file.writeAll(data[0..bytes_to_write]);
        return error.InjectedPartialWriteFailure;
    }

    try file.writeAll(data);
    try chmodFile(file, mode);
    try file.sync();
}

fn atomicReplaceWithInjectedFailure(allocator: std.mem.Allocator, path: []const u8, data: []const u8, fail_after: ?usize) !void {
    const tmp_path = try tempPath(allocator, path);
    defer allocator.free(tmp_path);

    if (std.mem.eql(u8, path, tmp_path)) return error.InvalidAtomicReplacePaths;

    const target_dir_path = dirnameOrDot(path);
    const target_name = basename(path);
    const tmp_name = basename(tmp_path);

    var dir = try getCwd().openDir(target_dir_path, .{ .iterate = true });
    defer dir.close();

    const final_mode = if (dir.statFile(target_name)) |stat| stat.mode & 0o777 else |err| switch (err) {
        error.FileNotFound => default_file_mode,
        else => return err,
    };

    var cleanup_tmp = true;
    defer if (cleanup_tmp) dir.deleteFile(tmp_name) catch {};

    try writeFileFailAfter(dir, tmp_name, data, final_mode, fail_after);
    try dir.rename(tmp_name, target_name);
    cleanup_tmp = false;
}

/// Atomically replace `path` with `data`.
///
/// The temporary file is created next to the target so `rename` stays on the
/// same filesystem. The target is not opened or truncated before the rename, so
/// readers see either the old file or the new complete file. Existing target
/// permissions are preserved; new targets use `0o600`, matching credential-file
/// safety requirements. Failed writes clean up the temporary file where possible.
///
/// Zig 0.16 mapping: keep this same-directory temp-file boundary and public
/// signature; only the internals should change when std.fs/std.Io APIs move.
pub fn atomicReplace(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    try atomicReplaceWithInjectedFailure(allocator, path, data, null);
}

fn makeTmpPath(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir, relative_path: []const u8) ![]u8 {
    const real = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(real);
    return std.fs.path.join(allocator, &.{ real, relative_path });
}

test "compat filesystem wrappers read write round trip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try makeTmpPath(allocator, tmp, "compat.txt");
    defer allocator.free(path);

    try writeFile(path, "one");
    const content = try readFileAlloc(allocator, path, default_max_file_bytes);
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
    try std.testing.expectError(error.FileNotFound, readFileAlloc(allocator, path, default_max_file_bytes));
}

test "compat filesystem wrappers preserve caller controlled read limits" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try makeTmpPath(allocator, tmp, "limited.txt");
    defer allocator.free(path);

    try writeFile(path, "abcdef");
    try std.testing.expectError(error.FileTooBig, readFileAlloc(allocator, path, 3));

    const content = try readFileAlloc(allocator, path, 6);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("abcdef", content);
}

test "compat filesystem wrappers create nested directories idempotently" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try makeTmpPath(allocator, tmp, "nested/path");
    defer allocator.free(dir_path);
    const file_path = try makeTmpPath(allocator, tmp, "nested/path/file.txt");
    defer allocator.free(file_path);

    try createDir(dir_path);
    try createDir(dir_path);
    try createDirAll(dir_path);
    try writeFile(file_path, "data");

    const content = try readFileAlloc(allocator, file_path, default_max_file_bytes);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("data", content);
}


test "compat atomic replace commits complete data for new file with mode 0600" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try makeTmpPath(allocator, tmp, "atomic.txt");
    defer allocator.free(path);

    try atomicReplace(allocator, path, "new credential contents");

    const content = try readFileAlloc(allocator, path, default_max_file_bytes);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("new credential contents", content);

    const stat = try getCwd().statFile(path);
    try std.testing.expectEqual(@as(std.fs.File.Mode, default_file_mode), stat.mode & 0o777);
}

test "compat atomic replace preserves existing target mode" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try makeTmpPath(allocator, tmp, "mode.txt");
    defer allocator.free(path);

    try writeFile(path, "old");
    var file = try openFile(path, .{ .mode = .write_only });
    defer file.close();
    try file.chmod(0o644);

    try atomicReplace(allocator, path, "new contents");

    const stat = try getCwd().statFile(path);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o644), stat.mode & 0o777);
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

    const content = try readFileAlloc(allocator, path, default_max_file_bytes);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("old stable contents", content);

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

    const content = try readFileAlloc(allocator, path, default_max_file_bytes);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("do not truncate", content);
}

test "compat getCwd returns a directory handle" {
    const cwd = getCwd();
    _ = cwd;
}
