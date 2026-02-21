const std = @import("std");

/// Unwrap an allocator-style error union where OutOfMemory is the only error.
///
/// Prefer this helper over `catch unreachable` so OOM-fatal assumptions are
/// explicit and grep-able.
///
/// This intentionally only handles `error.OutOfMemory`; if called with an error
/// set that includes other errors, this will fail to compile due to non-exhaustive
/// switch handling.
pub fn unreachableOnOom(value: anytype) @typeInfo(@TypeOf(value)).error_union.payload {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    if (info != .error_union) {
        @compileError("unreachableOnOom expects an error union");
    }

    return value catch |err| switch (err) {
        error.OutOfMemory => unreachable,
    };
}

test "unreachableOnOom unwraps success" {
    const value: error{OutOfMemory}!u32 = 42;
    try std.testing.expectEqual(@as(u32, 42), unreachableOnOom(value));
}
