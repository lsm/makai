const std = @import("std");

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
