const std = @import("std");
const zz = @import("zigzag");

pub fn joinVertical(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return zz.joinVertical(allocator, parts);
}

test "joinVertical stacks blocks" {
    const text = try joinVertical(std.testing.allocator, &.{ "A", "B" });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("A\nB", text);
}
