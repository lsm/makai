const std = @import("std");

/// Return the process stdin file handle.
///
/// Zig 0.16 mapping: this will borrow stdin from the Makai default I/O context
/// or test context, preserving public APIs that avoid raw `std.Io`.
pub fn getStdinReader() std.fs.File {
    return std.fs.File.stdin();
}

/// Return the process stdout file handle.
///
/// Zig 0.16 mapping: this will borrow stdout from the Makai default I/O context
/// or test context, preserving public APIs that avoid raw `std.Io`.
pub fn getStdoutWriter() std.fs.File {
    return std.fs.File.stdout();
}

test "compat stdio helpers construct file handles" {
    const stdin = getStdinReader();
    const stdout = getStdoutWriter();
    _ = stdin;
    _ = stdout;
}
