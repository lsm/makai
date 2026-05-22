const std = @import("std");
const zz = @import("zigzag");

pub fn joinVertical(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return zz.joinVertical(allocator, parts);
}

pub fn withSynchronizedOutput(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ zz.ansi.sync_start, body, zz.ansi.sync_end });
}

test "joinVertical stacks blocks" {
    const text = try joinVertical(std.testing.allocator, &.{ "A", "B" });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("A\nB", text);
}

test "withSynchronizedOutput wraps CSI 2026 markers" {
    const text = try withSynchronizedOutput(std.testing.allocator, "body");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, zz.ansi.sync_start));
    try std.testing.expect(std.mem.endsWith(u8, text, zz.ansi.sync_end));
    try std.testing.expect(std.mem.indexOf(u8, text, "body") != null);
}
