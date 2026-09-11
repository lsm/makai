
const std = @import("std");
const terminal_mod = @import("../terminal/terminal.zig");
const Terminal = terminal_mod.Terminal;
const ImageCapabilities = terminal_mod.ImageCapabilities;
const color_mod = @import("../style/color.zig");
const unicode_mod = @import("../unicode.zig");
const Logger = @import("log.zig").Logger;
const theme_mod = @import("../style/theme.zig");
const Environment = @import("environment.zig").Environment;

pub const Context = struct {
    allocator: std.mem.Allocator,

    persistent_allocator: std.mem.Allocator,

    home_dir: []const u8,

    io: std.Io,

    width: u16,

    height: u16,

    frame: u64,

    elapsed: u64,

    delta: u64,

    true_color: bool,

    color_256: bool,

    color_profile: color_mod.ColorProfile,

    is_dark_background: bool,

    unicode_width_strategy: unicode_mod.WidthStrategy,

    terminal_mode_2027: bool,

    kitty_text_sizing: bool,

    theme: theme_mod.Theme = theme_mod.Theme.fromPalette(theme_mod.Palette.default_dark),

    _terminal: ?*Terminal,

    _logger: ?*Logger = null,

    pub fn log(self: *const Context, comptime fmt: []const u8, args: anytype) void {
        if (self._logger) |logger| {
            logger.log(fmt, args);
        }
    }

    pub fn init(
        allocator: std.mem.Allocator,
        persistent_allocator: std.mem.Allocator,
        io: std.Io,
        environment: *const Environment,
    ) Context {
        const profile = environment.color_profile;
        return .{
            .allocator = allocator,
            .persistent_allocator = persistent_allocator,
            .io = io,
            .home_dir = environment.home_dir,
            .width = 80,
            .height = 24,
            .frame = 0,
            .elapsed = 0,
            .delta = 0,
            .true_color = profile.supportsTrueColor(),
            .color_256 = profile.supports256(),
            .color_profile = profile,
            .is_dark_background = environment.is_dark_background,
            .unicode_width_strategy = unicode_mod.getWidthStrategy(),
            .terminal_mode_2027 = false,
            .kitty_text_sizing = false,
            ._terminal = null,
        };
    }

    pub fn setTheme(self: *Context, p: theme_mod.Palette) void {
        self.theme = theme_mod.Theme.fromPalette(p);
    }

    pub fn getPalette(self: *const Context) theme_mod.Palette {
        return self.theme.palette;
    }

    pub fn aspectRatio(self: *const Context) f32 {
        if (self.height == 0) return 1.0;
        return @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height));
    }

    pub fn center(self: *const Context) struct { x: u16, y: u16 } {
        return .{
            .x = self.width / 2,
            .y = self.height / 2,
        };
    }

    pub fn inBounds(self: *const Context, x: u16, y: u16) bool {
        return x < self.width and y < self.height;
    }

    pub fn elapsedSec(self: *const Context) f64 {
        return @as(f64, @floatFromInt(self.elapsed)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    }

    pub fn deltaSec(self: *const Context) f64 {
        return @as(f64, @floatFromInt(self.delta)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    }

    pub fn fps(self: *const Context) f64 {
        if (self.delta == 0) return 0.0;
        return @as(f64, @floatFromInt(std.time.ns_per_s)) / @as(f64, @floatFromInt(self.delta));
    }

    pub fn clampX(self: *const Context, x: i32) u16 {
        if (x < 0) return 0;
        if (x >= self.width) return self.width -| 1;
        return @intCast(x);
    }

    pub fn clampY(self: *const Context, y: i32) u16 {
        if (y < 0) return 0;
        if (y >= self.height) return self.height -| 1;
        return @intCast(y);
    }

    pub fn supportsKittyGraphics(self: *const Context) bool {
        if (self._terminal) |term| {
            return term.supportsKittyGraphics();
        }
        return false;
    }

    pub fn supportsIterm2InlineImages(self: *const Context) bool {
        if (self._terminal) |term| {
            return term.supportsIterm2InlineImages();
        }
        return false;
    }

    pub fn supportsSixel(self: *const Context) bool {
        if (self._terminal) |term| {
            return term.supportsSixel();
        }
        return false;
    }

    pub fn supportsImages(self: *const Context) bool {
        if (self._terminal) |term| {
            return term.supportsImages();
        }
        return false;
    }

    pub fn setClipboard(self: *Context, bytes: []const u8) !bool {
        if (self._terminal) |term| {
            return term.setClipboard(bytes);
        }
        return false;
    }

    pub fn setClipboardWithOptions(self: *Context, bytes: []const u8, options: terminal_mod.Osc52WriteOptions) !bool {
        if (self._terminal) |term| {
            return term.setClipboardWithOptions(bytes, options);
        }
        return false;
    }

    pub fn getClipboard(self: *Context, allocator: std.mem.Allocator) !?[]u8 {
        if (self._terminal) |term| {
            return term.getClipboard(allocator);
        }
        return null;
    }

    pub fn getClipboardWithOptions(self: *Context, allocator: std.mem.Allocator, options: terminal_mod.Osc52ReadOptions) !?[]u8 {
        if (self._terminal) |term| {
            return term.getClipboardWithOptions(allocator, options);
        }
        return null;
    }

    pub fn drawKittyImageFromFile(self: *Context, path: []const u8, options: Terminal.KittyImageFileOptions) !bool {
        if (self._terminal) |term| {
            return term.drawKittyImageFromFile(path, options);
        }
        return false;
    }

    pub fn drawKittyImage(self: *Context, data: []const u8, options: Terminal.KittyImageOptions) !bool {
        if (self._terminal) |term| {
            return term.drawKittyImage(data, options);
        }
        return false;
    }

    pub fn transmitKittyImage(self: *Context, payload: []const u8, options: Terminal.KittyTransmitOptions) !bool {
        if (self._terminal) |term| {
            return term.transmitKittyImage(payload, options);
        }
        return false;
    }

    pub fn transmitKittyImageFromFile(self: *Context, path: []const u8, options: Terminal.KittyTransmitOptions) !bool {
        if (self._terminal) |term| {
            return term.transmitKittyImageFromFile(path, options);
        }
        return false;
    }

    pub fn placeKittyImage(self: *Context, options: Terminal.KittyPlaceOptions) !bool {
        if (self._terminal) |term| {
            return term.placeKittyImage(options);
        }
        return false;
    }

    pub fn deleteKittyImage(self: *Context, target: Terminal.KittyDeleteTarget) !bool {
        if (self._terminal) |term| {
            return term.deleteKittyImage(target);
        }
        return false;
    }

    pub fn drawSixelFromFile(self: *Context, path: []const u8, options: Terminal.SixelImageFileOptions) !bool {
        if (self._terminal) |term| {
            return term.drawSixelFromFile(path, options);
        }
        return false;
    }

    pub fn drawImageFromFile(self: *Context, path: []const u8, options: Terminal.ImageFileOptions) !bool {
        if (self._terminal) |term| {
            return term.drawImageFromFile(path, options);
        }
        return false;
    }

    pub fn drawImageFromFileWithProtocol(self: *Context, path: []const u8, options: Terminal.ImageFileOptions, protocol: Terminal.ImageProtocol) !bool {
        if (self._terminal) |term| {
            return term.drawImageFromFileWithProtocol(path, options, protocol);
        }
        return false;
    }

    pub fn drawImageData(self: *Context, data: []const u8, options: Terminal.ImageDataOptions) !bool {
        if (self._terminal) |term| {
            return term.drawImageData(data, options);
        }
        return false;
    }

    pub fn drawImageDataWithProtocol(self: *Context, data: []const u8, options: Terminal.ImageDataOptions, protocol: Terminal.ImageProtocol) !bool {
        if (self._terminal) |term| {
            return term.drawImageDataWithProtocol(data, options, protocol);
        }
        return false;
    }

    pub fn drawIterm2ImageData(self: *Context, data: []const u8, options: Terminal.Iterm2ImageDataOptions) !bool {
        if (self._terminal) |term| {
            return term.drawIterm2ImageData(data, options);
        }
        return false;
    }

    pub fn getImageCapabilities(self: *const Context) ImageCapabilities {
        if (self._terminal) |term| {
            return term.getImageCapabilities();
        }
        return .{};
    }
};

pub const Options = struct {
    fps: u32 = 60,

    mouse: bool = false,

    alternate_scroll: bool = false,

    cursor: bool = false,

    alt_screen: bool = true,

    inline_bottom_viewport: bool = false,

    bracketed_paste: bool = true,

    title: ?[]const u8 = null,

    input: ?std.Io.File = null,

    output: ?std.Io.File = null,

    log_file: ?[]const u8 = null,

    kitty_keyboard: bool = false,

    osc52: terminal_mod.Osc52Config = .{},

    unicode_width_strategy: ?unicode_mod.WidthStrategy = null,

    suspend_enabled: bool = true,
};
