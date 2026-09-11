const std = @import("std");

pub const File = std.Io.File;
pub const Pipe = [2]File;

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

fn fileFromPipeHandle(handle: File.Handle) File {
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

fn nonblockingFileFromHandle(handle: File.Handle) File {
    return .{ .handle = handle, .flags = .{ .nonblocking = true } };
}

fn blockingFileFromHandle(handle: File.Handle) File {
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

pub fn stdin() File {
    return File.stdin();
}

pub fn stdout() File {
    return File.stdout();
}

pub fn stderr() File {
    return File.stderr();
}

pub fn writeAll(file: File, data: []const u8) !void {
    try file.writeStreamingAll(defaultIo(), data);
}

pub fn writeLine(file: File, data: []const u8) !void {
    try writeAll(file, data);
    try writeAll(file, "\n");
}

pub fn read(file: File, buffer: []u8) !usize {
    return file.readStreaming(defaultIo(), &.{buffer});
}

pub fn nonblocking(file: File) File {
    return nonblockingFileFromHandle(file.handle);
}

pub fn blocking(file: File) File {
    return blockingFileFromHandle(file.handle);
}

fn setNonBlockingMode(file: File, enabled: bool) !void {
    if (@import("builtin").os.tag == .windows) return;
    var flags = std.posix.system.fcntl(file.handle, std.posix.F.GETFL, @as(usize, 0));
    switch (std.posix.errno(flags)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    const nonblocking_flag: @TypeOf(flags) = 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    if (enabled) {
        flags |= nonblocking_flag;
    } else {
        flags &= std.math.maxInt(@TypeOf(flags)) ^ nonblocking_flag;
    }
    switch (std.posix.errno(std.posix.system.fcntl(file.handle, std.posix.F.SETFL, flags))) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

pub fn setNonBlocking(file: File) !void {
    try setNonBlockingMode(file, true);
}

pub fn setNonBlockingFile(file: File) !File {
    try setNonBlocking(file);
    return nonblocking(file);
}

pub fn setBlocking(file: File) !void {
    try setNonBlockingMode(file, false);
}

pub fn setBlockingFile(file: File) !File {
    try setBlocking(file);
    return blocking(file);
}

pub fn close(file: File) void {
    file.close(defaultIo());
}

pub fn pipe() !Pipe {
    const handles = try std.Io.Threaded.pipe2(.{});
    return .{ fileFromPipeHandle(handles[0]), fileFromPipeHandle(handles[1]) };
}

test "compat stdio helpers construct file handles" {
    const in = stdin();
    const out = stdout();
    const err = stderr();
    _ = in;
    _ = out;
    _ = err;
}

test "compat stdio helpers round trip through pipe" {
    const p = try pipe();
    const read_file = p[0];
    const write_file = p[1];
    defer close(read_file);

    try writeLine(write_file, "hello");
    close(write_file);

    var buf: [16]u8 = undefined;
    const n = try read(read_file, &buf);
    try std.testing.expectEqualStrings("hello\n", buf[0..n]);
}
