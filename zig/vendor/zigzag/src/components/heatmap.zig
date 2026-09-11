
const std = @import("std");
const Writer = std.Io.Writer;
const style_mod = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;

pub const Heatmap = struct {
    allocator: std.mem.Allocator,
    data: []const f64 = &.{},
    rows: usize = 0,
    cols: usize = 0,
    row_labels: []const []const u8 = &.{},
    col_labels: []const []const u8 = &.{},
    color_scale: ColorScale = .green_scale,
    cell_width: u8 = 2,
    min_val: ?f64 = null,
    max_val: ?f64 = null,
    show_legend: bool = true,
    show_values: bool = false,
    title: []const u8 = "",
    cell_height: u8 = 1,
    title_style: style_mod.Style = blk: {
        var s = style_mod.Style{};
        s = s.bold(true);
        s = s.inline_style(true);
        break :blk s;
    },
    row_label_style: style_mod.Style = blk: {
        var s = style_mod.Style{};
        s = s.inline_style(true);
        break :blk s;
    },
    col_label_style: style_mod.Style = blk: {
        var s = style_mod.Style{};
        s = s.inline_style(true);
        break :blk s;
    },
    legend_style: style_mod.Style = blk: {
        var s = style_mod.Style{};
        s = s.inline_style(true);
        break :blk s;
    },
    legend_steps: usize = 10,
    empty_char: []const u8 = " ",

    pub const ColorScale = enum {
        green_scale,
        cool_to_hot,
        grayscale,
        blue_red,
    };

    pub fn init(allocator: std.mem.Allocator) Heatmap {
        return .{ .allocator = allocator };
    }

    pub fn setData(self: *Heatmap, r: usize, c: usize, d: []const f64) void {
        self.rows = r;
        self.cols = c;
        self.data = d;
    }

    fn getMinMax(self: *const Heatmap) struct { min: f64, max: f64 } {
        const mn = self.min_val orelse blk: {
            var m: f64 = std.math.inf(f64);
            for (self.data) |v| m = @min(m, v);
            break :blk m;
        };
        const mx = self.max_val orelse blk: {
            var m: f64 = -std.math.inf(f64);
            for (self.data) |v| m = @max(m, v);
            break :blk m;
        };
        return .{ .min = mn, .max = mx };
    }

    fn normalize(val: f64, mn: f64, mx: f64) f64 {
        if (mx <= mn) return 0;
        return @max(0, @min(1, (val - mn) / (mx - mn)));
    }

    fn scaleColor(self: *const Heatmap, t: f64) Color {
        return switch (self.color_scale) {
            .green_scale => {
                if (t < 0.01) return .gray(2);
                const g: u8 = @intFromFloat(80 + 175 * t);
                return .fromRgb(0, g, 0);
            },
            .cool_to_hot => {
                if (t < 0.25) {
                    const lt = t * 4;
                    return .fromRgb(0, @intFromFloat(lt * 255), 255);
                } else if (t < 0.5) {
                    const lt = (t - 0.25) * 4;
                    return .fromRgb(0, 255, @intFromFloat(255 - lt * 255));
                } else if (t < 0.75) {
                    const lt = (t - 0.5) * 4;
                    return .fromRgb(@intFromFloat(lt * 255), 255, 0);
                } else {
                    const lt = (t - 0.75) * 4;
                    return .fromRgb(255, @intFromFloat(255 - lt * 255), 0);
                }
            },
            .grayscale => {
                const v: u8 = @intFromFloat(t * 255);
                return .fromRgb(v, v, v);
            },
            .blue_red => {
                const r: u8 = @intFromFloat(t * 255);
                const b: u8 = @intFromFloat((1 - t) * 255);
                return .fromRgb(r, 0, b);
            },
        };
    }

    pub fn view(self: *const Heatmap, allocator: std.mem.Allocator) []const u8 {
        if (self.rows == 0 or self.cols == 0) return "";

        const mm = self.getMinMax();
        var result: Writer.Allocating = .init(allocator);
        const writer = &result.writer;

        if (self.title.len > 0) {
            writer.writeAll(self.title_style.render(allocator, self.title) catch self.title) catch {};
            writer.writeByte('\n') catch {};
        }

        if (self.col_labels.len > 0) {
            const label_pad: usize = if (self.row_labels.len > 0) maxLabelWidth(self.row_labels) + 1 else 0;
            for (0..label_pad) |_| writer.writeByte(' ') catch {};

            for (self.col_labels, 0..) |label, ci| {
                if (ci >= self.cols) break;
                const cw = self.cell_width;
                if (label.len >= cw) {
                    writer.writeAll(label[0..cw]) catch {};
                } else {
                    writer.writeAll(label) catch {};
                    for (0..cw - label.len) |_| writer.writeByte(' ') catch {};
                }
            }
            writer.writeByte('\n') catch {};
        }

        for (0..self.rows) |r| {
            if (r < self.row_labels.len) {
                const max_lw = maxLabelWidth(self.row_labels);
                const label = self.row_labels[r];
                if (label.len < max_lw) {
                    for (0..max_lw - label.len) |_| writer.writeByte(' ') catch {};
                }
                writer.writeAll(label) catch {};
                writer.writeByte(' ') catch {};
            }

            for (0..self.cols) |c| {
                const idx = r * self.cols + c;
                const val = if (idx < self.data.len) self.data[idx] else 0;
                const t = normalize(val, mm.min, mm.max);
                const bg_color = self.scaleColor(t);

                var cs = style_mod.Style{};
                cs = cs.bg(bg_color);
                cs = cs.inline_style(true);

                if (self.show_values and self.cell_width >= 3) {
                    const val_str = std.fmt.allocPrint(allocator, "{d:.0}", .{val}) catch " ";
                    const padded = padCenter(allocator, val_str, self.cell_width);
                    cs = cs.fg(if (t > 0.5) .black else .white);
                    writer.writeAll(cs.render(allocator, padded) catch padded) catch {};
                } else {
                    var cell_buf: [8]u8 = undefined;
                    const cw = @min(self.cell_width, 8);
                    for (0..cw) |i| cell_buf[i] = ' ';
                    writer.writeAll(cs.render(allocator, cell_buf[0..cw]) catch cell_buf[0..cw]) catch {};
                }
            }
            if (r < self.rows - 1) writer.writeByte('\n') catch {};
        }

        if (self.show_legend) {
            writer.writeAll("\n\n") catch {};
            const steps: usize = 10;
            for (0..steps) |s| {
                const t = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps - 1));
                const c = self.scaleColor(t);
                var ls = style_mod.Style{};
                ls = ls.bg(c);
                ls = ls.inline_style(true);
                writer.writeAll(ls.render(allocator, "  ") catch "  ") catch {};
            }
            const min_str = std.fmt.allocPrint(allocator, " {d:.0}", .{mm.min}) catch "";
            const max_str = std.fmt.allocPrint(allocator, " - {d:.0}", .{mm.max}) catch "";
            writer.writeAll(min_str) catch {};
            writer.writeAll(max_str) catch {};
        }

        return result.toArrayList().items;
    }

    fn maxLabelWidth(labels: []const []const u8) usize {
        var max: usize = 0;
        for (labels) |l| max = @max(max, l.len);
        return max;
    }

    fn padCenter(allocator: std.mem.Allocator, text: []const u8, target_width: u8) []const u8 {
        if (text.len >= target_width) return text[0..target_width];
        const total_pad = target_width - text.len;
        const left_pad = total_pad / 2;
        const right_pad = total_pad - left_pad;
        var buf = std.array_list.Managed(u8).init(allocator);
        for (0..left_pad) |_| buf.append(' ') catch {};
        buf.appendSlice(text) catch {};
        for (0..right_pad) |_| buf.append(' ') catch {};
        return buf.items;
    }
};
