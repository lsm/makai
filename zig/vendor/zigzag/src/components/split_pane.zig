
const std = @import("std");
const keys = @import("../input/keys.zig");
const style_mod = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;
const join = @import("../layout/join.zig");
const measure = @import("../layout/measure.zig");

pub const Orientation = enum {
    horizontal,
    vertical,
};

pub const Dims = struct {
    a_width: u16,
    a_height: u16,
    b_width: u16,
    b_height: u16,
};

pub const SplitPane = struct {
    orientation: Orientation,
    width: u16,
    height: u16,
    ratio: f32,
    min_size: u16,
    resize_step: u16,

    divider_style: style_mod.Style,
    divider_char_vertical: []const u8,
    divider_char_horizontal: []const u8,

    pub fn init(orientation: Orientation) SplitPane {
        var ds = style_mod.Style{};
        ds = ds.fg(.gray(6));
        ds = ds.inline_style(true);
        return .{
            .orientation = orientation,
            .width = 80,
            .height = 24,
            .ratio = 0.5,
            .min_size = 3,
            .resize_step = 1,
            .divider_style = ds,
            .divider_char_vertical = "│",
            .divider_char_horizontal = "─",
        };
    }

    pub fn setSize(self: *SplitPane, w: u16, h: u16) void {
        self.width = w;
        self.height = h;
    }

    pub fn setRatio(self: *SplitPane, r: f32) void {
        self.ratio = std.math.clamp(r, 0.0, 1.0);
    }

    pub fn dims(self: *const SplitPane) Dims {
        return switch (self.orientation) {
            .horizontal => self.horizontalDims(),
            .vertical => self.verticalDims(),
        };
    }

    fn horizontalDims(self: *const SplitPane) Dims {
        const total = self.width;
        const available: u16 = if (total > 1) total - 1 else total;
        const a_raw: u16 = @intFromFloat(@as(f32, @floatFromInt(available)) * self.ratio);
        const min = @min(self.min_size, available / 2);
        const a = std.math.clamp(a_raw, min, available -| min);
        const b = available -| a;
        return .{
            .a_width = a,
            .a_height = self.height,
            .b_width = b,
            .b_height = self.height,
        };
    }

    fn verticalDims(self: *const SplitPane) Dims {
        const total = self.height;
        const available: u16 = if (total > 1) total - 1 else total;
        const a_raw: u16 = @intFromFloat(@as(f32, @floatFromInt(available)) * self.ratio);
        const min = @min(self.min_size, available / 2);
        const a = std.math.clamp(a_raw, min, available -| min);
        const b = available -| a;
        return .{
            .a_width = self.width,
            .a_height = a,
            .b_width = self.width,
            .b_height = b,
        };
    }

    pub fn growA(self: *SplitPane) void {
        self.adjust(@as(i32, self.resize_step));
    }

    pub fn growB(self: *SplitPane) void {
        self.adjust(-@as(i32, self.resize_step));
    }

    fn adjust(self: *SplitPane, delta_cells: i32) void {
        const total: u16 = switch (self.orientation) {
            .horizontal => if (self.width > 1) self.width - 1 else self.width,
            .vertical => if (self.height > 1) self.height - 1 else self.height,
        };
        if (total == 0) return;

        const current_cells: i32 = @intFromFloat(@as(f32, @floatFromInt(total)) * self.ratio);
        var next = current_cells + delta_cells;
        const min: i32 = @intCast(@min(self.min_size, total / 2));
        const max: i32 = @as(i32, total) - min;
        if (min > max) return;
        next = std.math.clamp(next, min, max);
        self.ratio = @as(f32, @floatFromInt(next)) / @as(f32, @floatFromInt(total));
    }

    pub fn handleResize(self: *SplitPane, key: keys.KeyEvent) bool {
        switch (self.orientation) {
            .horizontal => switch (key.key) {
                .left => {
                    self.growB();
                    return true;
                },
                .right => {
                    self.growA();
                    return true;
                },
                else => return false,
            },
            .vertical => switch (key.key) {
                .up => {
                    self.growB();
                    return true;
                },
                .down => {
                    self.growA();
                    return true;
                },
                else => return false,
            },
        }
    }

    pub fn compose(self: *const SplitPane, allocator: std.mem.Allocator, pane_a: []const u8, pane_b: []const u8) ![]const u8 {
        return switch (self.orientation) {
            .horizontal => self.composeHorizontal(allocator, pane_a, pane_b),
            .vertical => self.composeVertical(allocator, pane_a, pane_b),
        };
    }

    fn composeHorizontal(self: *const SplitPane, allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
        const rows: usize = @max(self.height, 1);
        var divider_lines = std.array_list.Managed(u8).init(allocator);
        defer divider_lines.deinit();
        for (0..rows) |i| {
            if (i > 0) try divider_lines.append('\n');
            const ch = try self.divider_style.render(allocator, self.divider_char_vertical);
            defer allocator.free(ch);
            try divider_lines.appendSlice(ch);
        }
        return join.horizontal(allocator, .top, &.{ a, divider_lines.items, b });
    }

    fn composeVertical(self: *const SplitPane, allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
        const cols: usize = @max(self.width, 1);
        var divider = std.array_list.Managed(u8).init(allocator);
        defer divider.deinit();
        for (0..cols) |_| try divider.appendSlice(self.divider_char_horizontal);
        const styled = try self.divider_style.render(allocator, divider.items);
        defer allocator.free(styled);
        return join.vertical(allocator, .left, &.{ a, styled, b });
    }
};

test "horizontal split divides width minus divider" {
    var s = SplitPane.init(.horizontal);
    s.setSize(21, 10);
    s.setRatio(0.5);
    const d = s.dims();
    try std.testing.expectEqual(@as(u16, 10), d.a_width);
    try std.testing.expectEqual(@as(u16, 10), d.b_width);
    try std.testing.expectEqual(@as(u16, 10), d.a_height);
}

test "ratio clamped to min size" {
    var s = SplitPane.init(.horizontal);
    s.setSize(20, 10);
    s.min_size = 5;
    s.setRatio(0.0);
    const d = s.dims();
    try std.testing.expect(d.a_width >= 5);
}

test "growA increases ratio" {
    var s = SplitPane.init(.horizontal);
    s.setSize(40, 10);
    s.setRatio(0.5);
    const before = s.dims().a_width;
    s.growA();
    const after = s.dims().a_width;
    try std.testing.expect(after > before);
}

test "vertical split divides height minus divider" {
    var s = SplitPane.init(.vertical);
    s.setSize(40, 11);
    s.setRatio(0.5);
    const d = s.dims();
    try std.testing.expectEqual(@as(u16, 5), d.a_height);
    try std.testing.expectEqual(@as(u16, 5), d.b_height);
}

test "compose keeps output non-empty" {
    const allocator = std.testing.allocator;
    var s = SplitPane.init(.horizontal);
    s.setSize(10, 2);
    const out = try s.compose(allocator, "ab\ncd", "xy\nzw");
    defer allocator.free(out);
    try std.testing.expect(out.len > 0);
}
