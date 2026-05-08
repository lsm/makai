const std = @import("std");

/// Return the process stdin file handle.
///
/// Zig 0.16 mapping: this will borrow stdin from the Makai default I/O context
/// or test context, preserving public APIs that avoid raw `std.Io`.
pub fn stdin() std.fs.File {
    return std.fs.File.stdin();
}

/// Return the process stdout file handle.
///
/// Zig 0.16 mapping: this will borrow stdout from the Makai default I/O context
/// or test context, preserving public APIs that avoid raw `std.Io`.
pub fn stdout() std.fs.File {
    return std.fs.File.stdout();
}

test "compat stdio helpers construct file handles" {
    const in = stdin();
    const out = stdout();
    _ = in;
    _ = out;
}
