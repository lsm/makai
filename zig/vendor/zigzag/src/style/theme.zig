
const std = @import("std");
const Color = @import("color.zig").Color;
const style_mod = @import("style.zig");

pub const Palette = struct {
    primary: Color,
    secondary: Color,
    accent: Color,

    background: Color,
    surface: Color,
    overlay: Color,

    foreground: Color,
    muted: Color,
    subtle: Color,

    success: Color,
    warning: Color,
    danger: Color,
    info: Color,

    border_color: Color,
    border_focus: Color,

    highlight: Color,
    highlight_text: Color,

    pub const default_dark = Palette{
        .primary = .cyan,
        .secondary = .magenta,
        .accent = .yellow,
        .background = .fromRgb(24, 24, 32),
        .surface = .fromRgb(32, 32, 42),
        .overlay = .fromRgb(40, 40, 52),
        .foreground = .white,
        .muted = .gray(14),
        .subtle = .gray(10),
        .success = .green,
        .warning = .yellow,
        .danger = .red,
        .info = .cyan,
        .border_color = .gray(12),
        .border_focus = .cyan,
        .highlight = .fromRgb(60, 60, 80),
        .highlight_text = .white,
    };

    pub const default_light = Palette{
        .primary = .fromRgb(0, 120, 180),
        .secondary = .fromRgb(140, 60, 160),
        .accent = .fromRgb(180, 120, 0),
        .background = .fromRgb(250, 250, 250),
        .surface = .fromRgb(240, 240, 240),
        .overlay = .fromRgb(230, 230, 230),
        .foreground = .fromRgb(30, 30, 30),
        .muted = .fromRgb(100, 100, 100),
        .subtle = .fromRgb(160, 160, 160),
        .success = .fromRgb(40, 160, 40),
        .warning = .fromRgb(200, 150, 0),
        .danger = .fromRgb(200, 40, 40),
        .info = .fromRgb(0, 120, 180),
        .border_color = .fromRgb(180, 180, 180),
        .border_focus = .fromRgb(0, 120, 180),
        .highlight = .fromRgb(200, 220, 240),
        .highlight_text = .fromRgb(30, 30, 30),
    };

    pub const catppuccin_mocha = Palette{
        .primary = .fromRgb(137, 180, 250),
        .secondary = .fromRgb(203, 166, 247),
        .accent = .fromRgb(249, 226, 175),
        .background = .fromRgb(30, 30, 46),
        .surface = .fromRgb(49, 50, 68),
        .overlay = .fromRgb(69, 71, 90),
        .foreground = .fromRgb(205, 214, 244),
        .muted = .fromRgb(166, 173, 200),
        .subtle = .fromRgb(127, 132, 156),
        .success = .fromRgb(166, 227, 161),
        .warning = .fromRgb(249, 226, 175),
        .danger = .fromRgb(243, 139, 168),
        .info = .fromRgb(137, 180, 250),
        .border_color = .fromRgb(88, 91, 112),
        .border_focus = .fromRgb(137, 180, 250),
        .highlight = .fromRgb(49, 50, 68),
        .highlight_text = .fromRgb(205, 214, 244),
    };

    pub const catppuccin_latte = Palette{
        .primary = .fromRgb(30, 102, 245),
        .secondary = .fromRgb(136, 57, 239),
        .accent = .fromRgb(223, 142, 29),
        .background = .fromRgb(239, 241, 245),
        .surface = .fromRgb(204, 208, 218),
        .overlay = .fromRgb(188, 192, 204),
        .foreground = .fromRgb(76, 79, 105),
        .muted = .fromRgb(108, 111, 133),
        .subtle = .fromRgb(140, 143, 161),
        .success = .fromRgb(64, 160, 43),
        .warning = .fromRgb(223, 142, 29),
        .danger = .fromRgb(210, 15, 57),
        .info = .fromRgb(30, 102, 245),
        .border_color = .fromRgb(156, 160, 176),
        .border_focus = .fromRgb(30, 102, 245),
        .highlight = .fromRgb(204, 208, 218),
        .highlight_text = .fromRgb(76, 79, 105),
    };

    pub const dracula = Palette{
        .primary = .fromRgb(189, 147, 249),
        .secondary = .fromRgb(255, 121, 198),
        .accent = .fromRgb(241, 250, 140),
        .background = .fromRgb(40, 42, 54),
        .surface = .fromRgb(68, 71, 90),
        .overlay = .fromRgb(68, 71, 90),
        .foreground = .fromRgb(248, 248, 242),
        .muted = .fromRgb(98, 114, 164),
        .subtle = .fromRgb(98, 114, 164),
        .success = .fromRgb(80, 250, 123),
        .warning = .fromRgb(255, 184, 108),
        .danger = .fromRgb(255, 85, 85),
        .info = .fromRgb(139, 233, 253),
        .border_color = .fromRgb(98, 114, 164),
        .border_focus = .fromRgb(189, 147, 249),
        .highlight = .fromRgb(68, 71, 90),
        .highlight_text = .fromRgb(248, 248, 242),
    };

    pub const nord = Palette{
        .primary = .fromRgb(136, 192, 208),
        .secondary = .fromRgb(129, 161, 193),
        .accent = .fromRgb(235, 203, 139),
        .background = .fromRgb(46, 52, 64),
        .surface = .fromRgb(59, 66, 82),
        .overlay = .fromRgb(67, 76, 94),
        .foreground = .fromRgb(236, 239, 244),
        .muted = .fromRgb(216, 222, 233),
        .subtle = .fromRgb(76, 86, 106),
        .success = .fromRgb(163, 190, 140),
        .warning = .fromRgb(235, 203, 139),
        .danger = .fromRgb(191, 97, 106),
        .info = .fromRgb(136, 192, 208),
        .border_color = .fromRgb(76, 86, 106),
        .border_focus = .fromRgb(136, 192, 208),
        .highlight = .fromRgb(59, 66, 82),
        .highlight_text = .fromRgb(236, 239, 244),
    };

    pub const high_contrast = Palette{
        .primary = .fromRgb(0, 200, 255),
        .secondary = .fromRgb(255, 100, 255),
        .accent = .fromRgb(255, 255, 0),
        .background = .fromRgb(0, 0, 0),
        .surface = .fromRgb(20, 20, 20),
        .overlay = .fromRgb(40, 40, 40),
        .foreground = .fromRgb(255, 255, 255),
        .muted = .fromRgb(200, 200, 200),
        .subtle = .fromRgb(150, 150, 150),
        .success = .fromRgb(0, 255, 0),
        .warning = .fromRgb(255, 255, 0),
        .danger = .fromRgb(255, 0, 0),
        .info = .fromRgb(0, 200, 255),
        .border_color = .fromRgb(200, 200, 200),
        .border_focus = .fromRgb(0, 200, 255),
        .highlight = .fromRgb(0, 80, 120),
        .highlight_text = .fromRgb(255, 255, 255),
    };

    pub const tokyo_night = Palette{
        .primary = .fromRgb(122, 162, 247),
        .secondary = .fromRgb(187, 154, 247),
        .accent = .fromRgb(224, 175, 104),
        .background = .fromRgb(26, 27, 38),
        .surface = .fromRgb(36, 40, 59),
        .overlay = .fromRgb(41, 46, 66),
        .foreground = .fromRgb(192, 202, 245),
        .muted = .fromRgb(144, 153, 191),
        .subtle = .fromRgb(86, 95, 137),
        .success = .fromRgb(158, 206, 106),
        .warning = .fromRgb(224, 175, 104),
        .danger = .fromRgb(247, 118, 142),
        .info = .fromRgb(125, 207, 255),
        .border_color = .fromRgb(41, 46, 66),
        .border_focus = .fromRgb(122, 162, 247),
        .highlight = .fromRgb(41, 46, 66),
        .highlight_text = .fromRgb(192, 202, 245),
    };

    pub const gruvbox_dark = Palette{
        .primary = .fromRgb(131, 165, 152),
        .secondary = .fromRgb(211, 134, 155),
        .accent = .fromRgb(250, 189, 47),
        .background = .fromRgb(40, 40, 40),
        .surface = .fromRgb(60, 56, 54),
        .overlay = .fromRgb(80, 73, 69),
        .foreground = .fromRgb(235, 219, 178),
        .muted = .fromRgb(168, 153, 132),
        .subtle = .fromRgb(124, 111, 100),
        .success = .fromRgb(184, 187, 38),
        .warning = .fromRgb(250, 189, 47),
        .danger = .fromRgb(251, 73, 52),
        .info = .fromRgb(131, 165, 152),
        .border_color = .fromRgb(80, 73, 69),
        .border_focus = .fromRgb(131, 165, 152),
        .highlight = .fromRgb(80, 73, 69),
        .highlight_text = .fromRgb(235, 219, 178),
    };

    pub const solarized_dark = Palette{
        .primary = .fromRgb(38, 139, 210),
        .secondary = .fromRgb(108, 113, 196),
        .accent = .fromRgb(181, 137, 0),
        .background = .fromRgb(0, 43, 54),
        .surface = .fromRgb(7, 54, 66),
        .overlay = .fromRgb(88, 110, 117),
        .foreground = .fromRgb(131, 148, 150),
        .muted = .fromRgb(101, 123, 131),
        .subtle = .fromRgb(88, 110, 117),
        .success = .fromRgb(133, 153, 0),
        .warning = .fromRgb(181, 137, 0),
        .danger = .fromRgb(220, 50, 47),
        .info = .fromRgb(42, 161, 152),
        .border_color = .fromRgb(88, 110, 117),
        .border_focus = .fromRgb(38, 139, 210),
        .highlight = .fromRgb(7, 54, 66),
        .highlight_text = .fromRgb(147, 161, 161),
    };

    pub const solarized_light = Palette{
        .primary = .fromRgb(38, 139, 210),
        .secondary = .fromRgb(108, 113, 196),
        .accent = .fromRgb(181, 137, 0),
        .background = .fromRgb(253, 246, 227),
        .surface = .fromRgb(238, 232, 213),
        .overlay = .fromRgb(147, 161, 161),
        .foreground = .fromRgb(101, 123, 131),
        .muted = .fromRgb(131, 148, 150),
        .subtle = .fromRgb(147, 161, 161),
        .success = .fromRgb(133, 153, 0),
        .warning = .fromRgb(181, 137, 0),
        .danger = .fromRgb(220, 50, 47),
        .info = .fromRgb(42, 161, 152),
        .border_color = .fromRgb(147, 161, 161),
        .border_focus = .fromRgb(38, 139, 210),
        .highlight = .fromRgb(238, 232, 213),
        .highlight_text = .fromRgb(88, 110, 117),
    };

    pub const builtins = [_]struct { name: []const u8, palette: Palette }{
        .{ .name = "Default Dark", .palette = default_dark },
        .{ .name = "Default Light", .palette = default_light },
        .{ .name = "Catppuccin Mocha", .palette = catppuccin_mocha },
        .{ .name = "Catppuccin Latte", .palette = catppuccin_latte },
        .{ .name = "Dracula", .palette = dracula },
        .{ .name = "Nord", .palette = nord },
        .{ .name = "Tokyo Night", .palette = tokyo_night },
        .{ .name = "Gruvbox Dark", .palette = gruvbox_dark },
        .{ .name = "Solarized Dark", .palette = solarized_dark },
        .{ .name = "Solarized Light", .palette = solarized_light },
        .{ .name = "High Contrast", .palette = high_contrast },
    };
};

pub const AdaptivePalette = struct {
    light: Palette,
    dark: Palette,

    pub fn resolve(self: AdaptivePalette, is_dark: bool) Palette {
        return if (is_dark) self.dark else self.light;
    }

    pub const catppuccin = AdaptivePalette{
        .light = .catppuccin_latte,
        .dark = .catppuccin_mocha,
    };

    pub const default = AdaptivePalette{
        .light = .default_light,
        .dark = .default_dark,
    };

    pub const solarized = AdaptivePalette{
        .light = .solarized_light,
        .dark = .solarized_dark,
    };
};

pub const ThemeManager = struct {
    current: Theme,
    is_dark: bool,
    palette_index: usize,

    pub fn init(is_dark: bool) ThemeManager {
        const palette = AdaptivePalette.default.resolve(is_dark);
        return .{
            .current = .fromPalette(palette),
            .is_dark = is_dark,
            .palette_index = 0,
        };
    }

    pub fn initWithPalette(is_dark: bool, palette: Palette) ThemeManager {
        return .{
            .current = .fromPalette(palette),
            .is_dark = is_dark,
            .palette_index = 0,
        };
    }

    pub fn setPalette(self: *ThemeManager, palette: Palette) void {
        self.current = .fromPalette(palette);
    }

    pub fn setBuiltinByIndex(self: *ThemeManager, index: usize) void {
        if (index < Palette.builtins.len) {
            self.palette_index = index;
            self.current = .fromPalette(Palette.builtins[index].palette);
        }
    }

    pub fn nextBuiltin(self: *ThemeManager) void {
        self.palette_index = (self.palette_index + 1) % Palette.builtins.len;
        self.current = .fromPalette(Palette.builtins[self.palette_index].palette);
    }

    pub fn prevBuiltin(self: *ThemeManager) void {
        self.palette_index = if (self.palette_index == 0) Palette.builtins.len - 1 else self.palette_index - 1;
        self.current = .fromPalette(Palette.builtins[self.palette_index].palette);
    }

    pub fn currentName(self: *const ThemeManager) []const u8 {
        return Palette.builtins[self.palette_index].name;
    }

    pub fn builtinCount() usize {
        return Palette.builtins.len;
    }
};

pub const Theme = struct {
    palette: Palette,

    text: TextTheme,
    list: ListTheme,
    progress: ProgressTheme,
    modal: ModalTheme,
    notification: NotificationTheme,
    tab: TabTheme,

    pub const TextTheme = struct {
        text_fg: Color,
        placeholder_fg: Color,
        prompt_fg: Color,
        border_fg: Color,
        border_focus_fg: Color,
    };

    pub const ListTheme = struct {
        item_fg: Color,
        selected_fg: Color,
        cursor_fg: Color,
        filter_fg: Color,
    };

    pub const ProgressTheme = struct {
        filled_fg: Color,
        empty_fg: Color,
        percent_fg: Color,
    };

    pub const ModalTheme = struct {
        border_fg: Color,
        title_fg: Color,
        body_fg: Color,
        button_fg: Color,
        button_active_bg: Color,
    };

    pub const NotificationTheme = struct {
        info_fg: Color,
        success_fg: Color,
        warning_fg: Color,
        err_fg: Color,
    };

    pub const TabTheme = struct {
        bar_fg: Color,
        active_fg: Color,
        active_bg: Color,
        inactive_fg: Color,
    };

    pub fn fromPalette(p: Palette) Theme {
        return .{
            .palette = p,
            .text = .{
                .text_fg = p.foreground,
                .placeholder_fg = p.subtle,
                .prompt_fg = p.primary,
                .border_fg = p.border_color,
                .border_focus_fg = p.border_focus,
            },
            .list = .{
                .item_fg = p.foreground,
                .selected_fg = p.primary,
                .cursor_fg = p.secondary,
                .filter_fg = p.accent,
            },
            .progress = .{
                .filled_fg = p.primary,
                .empty_fg = p.subtle,
                .percent_fg = p.foreground,
            },
            .modal = .{
                .border_fg = p.border_color,
                .title_fg = p.foreground,
                .body_fg = p.muted,
                .button_fg = p.foreground,
                .button_active_bg = p.primary,
            },
            .notification = .{
                .info_fg = p.info,
                .success_fg = p.success,
                .warning_fg = p.warning,
                .err_fg = p.danger,
            },
            .tab = .{
                .bar_fg = p.muted,
                .active_fg = p.foreground,
                .active_bg = p.primary,
                .inactive_fg = p.subtle,
            },
        };
    }

    pub fn styleWith(fg: Color) style_mod.Style {
        var s = style_mod.Style{};
        s = s.fg(fg);
        s = s.inline_style(true);
        return s;
    }

    pub fn boldStyleWith(fg: Color) style_mod.Style {
        var s = style_mod.Style{};
        s = s.fg(fg);
        s = s.bold(true);
        s = s.inline_style(true);
        return s;
    }
};
