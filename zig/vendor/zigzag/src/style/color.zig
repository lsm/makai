
const std = @import("std");
const Writer = std.Io.Writer;
const builtin = @import("builtin");
const ansi = @import("../terminal/ansi.zig");

pub const Color = union(enum) {
    none,

    ansi: AnsiColor,

    ansi256: u8,

    rgb: RGB,

    pub const RGB = struct {
        r: u8,
        g: u8,
        b: u8,
    };

    pub const black: Color = .{ .ansi = .black };
    pub const red: Color = .{ .ansi = .red };
    pub const green: Color = .{ .ansi = .green };
    pub const yellow: Color = .{ .ansi = .yellow };
    pub const blue: Color = .{ .ansi = .blue };
    pub const magenta: Color = .{ .ansi = .magenta };
    pub const cyan: Color = .{ .ansi = .cyan };
    pub const white: Color = .{ .ansi = .white };

    pub const brightBlack: Color = .{ .ansi = .bright_black };
    pub const brightRed: Color = .{ .ansi = .bright_red };
    pub const brightGreen: Color = .{ .ansi = .bright_green };
    pub const brightYellow: Color = .{ .ansi = .bright_yellow };
    pub const brightBlue: Color = .{ .ansi = .bright_blue };
    pub const brightMagenta: Color = .{ .ansi = .bright_magenta };
    pub const brightCyan: Color = .{ .ansi = .bright_cyan };
    pub const brightWhite: Color = .{ .ansi = .bright_white };

    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }

    pub fn hex(str: []const u8) Color {
        const s = if (str.len > 0 and str[0] == '#') str[1..] else str;

        if (s.len != 6) return .none;

        const r = std.fmt.parseInt(u8, s[0..2], 16) catch return .none;
        const g = std.fmt.parseInt(u8, s[2..4], 16) catch return .none;
        const b = std.fmt.parseInt(u8, s[4..6], 16) catch return .none;

        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }

    pub fn color256(n: u8) Color {
        return .{ .ansi256 = n };
    }

    pub fn gray(level: u8) Color {
        if (level > 23) return .{ .ansi256 = 255 };
        return .{ .ansi256 = 232 + level };
    }

    pub fn isNone(self: Color) bool {
        return self == .none;
    }

    pub fn toRgb(self: Color) ?RGB {
        return switch (self) {
            .none => null,
            .rgb => |c| c,
            .ansi => |c| c.toRgb(),
            .ansi256 => |n| ansi256ToRgb(n),
        };
    }

    pub fn writeFg(self: Color, writer: *Writer) !void {
        switch (self) {
            .none => {},
            .ansi => |c| try writer.print(ansi.CSI ++ "{d}m", .{c.fgCode()}),
            .ansi256 => |n| try ansi.fg256(writer, n),
            .rgb => |c| try ansi.fgRgb(writer, c.r, c.g, c.b),
        }
    }

    pub fn writeBg(self: Color, writer: *Writer) !void {
        switch (self) {
            .none => {},
            .ansi => |c| try writer.print(ansi.CSI ++ "{d}m", .{c.bgCode()}),
            .ansi256 => |n| try ansi.bg256(writer, n),
            .rgb => |c| try ansi.bgRgb(writer, c.r, c.g, c.b),
        }
    }

    pub fn contrastRatio(self: Color, other: Color) f32 {
        const rgb1 = self.toRgb() orelse return 1.0;
        const rgb2 = other.toRgb() orelse return 1.0;

        const l1 = relativeLuminance(rgb1);
        const l2 = relativeLuminance(rgb2);

        const lighter = @max(l1, l2);
        const darker = @min(l1, l2);

        return (lighter + 0.05) / (darker + 0.05);
    }

    fn relativeLuminance(c: RGB) f32 {
        const r = gammaCorrect(@as(f32, @floatFromInt(c.r)) / 255.0);
        const g = gammaCorrect(@as(f32, @floatFromInt(c.g)) / 255.0);
        const b = gammaCorrect(@as(f32, @floatFromInt(c.b)) / 255.0);
        return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }

    fn gammaCorrect(v: f32) f32 {
        return if (v <= 0.03928) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
    }
};

pub const AnsiColor = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
    bright_black = 8,
    bright_red = 9,
    bright_green = 10,
    bright_yellow = 11,
    bright_blue = 12,
    bright_magenta = 13,
    bright_cyan = 14,
    bright_white = 15,

    pub fn fgCode(self: AnsiColor) u8 {
        const base: u8 = @intFromEnum(self);
        return if (base < 8) 30 + base else 90 + base - 8;
    }

    pub fn bgCode(self: AnsiColor) u8 {
        const base: u8 = @intFromEnum(self);
        return if (base < 8) 40 + base else 100 + base - 8;
    }

    pub fn toRgb(self: AnsiColor) Color.RGB {
        return switch (self) {
            .black => .{ .r = 0, .g = 0, .b = 0 },
            .red => .{ .r = 128, .g = 0, .b = 0 },
            .green => .{ .r = 0, .g = 128, .b = 0 },
            .yellow => .{ .r = 128, .g = 128, .b = 0 },
            .blue => .{ .r = 0, .g = 0, .b = 128 },
            .magenta => .{ .r = 128, .g = 0, .b = 128 },
            .cyan => .{ .r = 0, .g = 128, .b = 128 },
            .white => .{ .r = 192, .g = 192, .b = 192 },
            .bright_black => .{ .r = 128, .g = 128, .b = 128 },
            .bright_red => .{ .r = 255, .g = 0, .b = 0 },
            .bright_green => .{ .r = 0, .g = 255, .b = 0 },
            .bright_yellow => .{ .r = 255, .g = 255, .b = 0 },
            .bright_blue => .{ .r = 0, .g = 0, .b = 255 },
            .bright_magenta => .{ .r = 255, .g = 0, .b = 255 },
            .bright_cyan => .{ .r = 0, .g = 255, .b = 255 },
            .bright_white => .{ .r = 255, .g = 255, .b = 255 },
        };
    }
};

fn ansi256ToRgb(n: u8) Color.RGB {
    if (n < 16) {
        return @as(AnsiColor, @enumFromInt(n)).toRgb();
    } else if (n < 232) {
        const idx = n - 16;
        const r: u8 = @intCast((idx / 36) % 6);
        const g: u8 = @intCast((idx / 6) % 6);
        const b: u8 = @intCast(idx % 6);
        return .{
            .r = if (r == 0) 0 else r * 40 + 55,
            .g = if (g == 0) 0 else g * 40 + 55,
            .b = if (b == 0) 0 else b * 40 + 55,
        };
    } else {
        const gray: u8 = (n - 232) * 10 + 8;
        return .{ .r = gray, .g = gray, .b = gray };
    }
}

pub const AdaptiveColor = struct {
    true_color: Color,
    color_256: Color,
    ansi: Color,

    pub fn resolve(self: AdaptiveColor, supports_true_color: bool, supports_256: bool) Color {
        if (supports_true_color) return self.true_color;
        if (supports_256) return self.color_256;
        return self.ansi;
    }
};

pub const CompleteColor = struct {
    fg: Color = .none,
    bg: Color = .none,
};

pub const CompleteAdaptiveColor = struct {
    light: CompleteColor,
    dark: CompleteColor,

    pub fn resolve(self: CompleteAdaptiveColor, is_dark: bool) CompleteColor {
        return if (is_dark) self.dark else self.light;
    }
};

pub const ColorProfile = enum {
    ascii,
    ansi,
    ansi256,
    true_color,

    pub const DetectionHints = struct {
        no_color: bool = false,
        color_term: []const u8 = "",
        term: []const u8 = "",
    };

    pub fn detect(hints: DetectionHints) ColorProfile {
        if (comptime builtin.os.tag == .windows) {
            return .true_color;
        }

        if (hints.no_color) {
            return .ascii;
        }

        if (std.mem.eql(u8, hints.color_term, "truecolor") or
            std.mem.eql(u8, hints.color_term, "24bit"))
        {
            return .true_color;
        }

        if (std.mem.indexOf(u8, hints.term, "256color") != null) {
            return .ansi256;
        }

        return .ansi;
    }

    pub fn supportsTrueColor(self: ColorProfile) bool {
        return self == .true_color;
    }

    pub fn supports256(self: ColorProfile) bool {
        return self == .true_color or self == .ansi256;
    }

    pub fn supportsColor(self: ColorProfile) bool {
        return self != .ascii;
    }
};

pub fn hasDarkBackground(color_fg_bg: []const u8) bool {
    if (comptime builtin.os.tag == .windows) {
        return true;
    }

    if (color_fg_bg.len > 0) {
        if (std.mem.lastIndexOfScalar(u8, color_fg_bg, ';')) |idx| {
            const bg_str = color_fg_bg[idx + 1 ..];
            const bg_num = std.fmt.parseInt(u8, bg_str, 10) catch return true;
            return bg_num < 8;
        }
    }
    return true;
}
