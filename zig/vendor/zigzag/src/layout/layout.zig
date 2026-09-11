
pub const measure = @import("measure.zig");
pub const join = @import("join.zig");
pub const place = @import("place.zig");
pub const layer = @import("layer.zig");
pub const flex = @import("flex.zig");

pub const VAlign = join.VAlign;
pub const HAlign = join.HAlign;
pub const HPosition = place.HPosition;
pub const VPosition = place.VPosition;

pub fn width(str: []const u8) usize {
    return measure.width(str);
}

pub fn height(str: []const u8) usize {
    return measure.height(str);
}

pub fn joinHorizontal(allocator: @import("std").mem.Allocator, parts: []const []const u8) ![]const u8 {
    return join.horizontal(allocator, .top, parts);
}

pub fn joinVertical(allocator: @import("std").mem.Allocator, parts: []const []const u8) ![]const u8 {
    return join.vertical(allocator, .left, parts);
}

pub fn placeCenter(allocator: @import("std").mem.Allocator, w: usize, h: usize, content: []const u8) ![]const u8 {
    return place.place(allocator, w, h, .center, .middle, content);
}
