
const std = @import("std");
const Writer = std.Io.Writer;

pub const ESC = "\x1b";
pub const CSI = ESC ++ "[";
pub const OSC = ESC ++ "]";
pub const DCS = ESC ++ "P";
pub const APC = ESC ++ "_";
pub const ST = ESC ++ "\\";

pub const OscTerminator = enum {
    bel,
    st,
};

pub const Osc52Passthrough = enum {
    none,
    tmux,
    dcs,
};

pub const cursor_hide = CSI ++ "?25l";
pub const cursor_show = CSI ++ "?25h";
pub const cursor_save = CSI ++ "s";
pub const cursor_restore = CSI ++ "u";
pub const cursor_home = CSI ++ "H";

pub const screen_clear = CSI ++ "2J";
pub const screen_clear_below = CSI ++ "J";
pub const screen_clear_above = CSI ++ "1J";
pub const line_clear = CSI ++ "2K";
pub const line_clear_right = CSI ++ "K";
pub const line_clear_left = CSI ++ "1K";

pub const alt_screen_enter = CSI ++ "?1049h";
pub const alt_screen_exit = CSI ++ "?1049l";

pub const reset = CSI ++ "0m";

pub const bracketed_paste_enable = CSI ++ "?2004h";
pub const bracketed_paste_disable = CSI ++ "?2004l";

pub const sync_start = CSI ++ "?2026h";
pub const sync_end = CSI ++ "?2026l";

pub const unicode_width_mode_query = CSI ++ "?2027$p";
pub const unicode_width_mode_enable = CSI ++ "?2027h";
pub const unicode_width_mode_disable = CSI ++ "?2027l";

pub const kitty_keyboard_enable = CSI ++ ">1u";
pub const kitty_keyboard_disable = CSI ++ "<u";
pub const kitty_keyboard_disable_all = CSI ++ "<10u";
pub const kitty_keyboard_reset = CSI ++ "=0u";

pub fn cursorTo(writer: *Writer, row: u16, col: u16) !void {
    try writer.print(CSI ++ "{d};{d}H", .{ row, col });
}

pub fn cursorTo0(writer: *Writer, row: u16, col: u16) !void {
    try writer.print(CSI ++ "{d};{d}H", .{ row + 1, col + 1 });
}

pub fn cursorUp(writer: *Writer, n: u16) !void {
    if (n > 0) try writer.print(CSI ++ "{d}A", .{n});
}

pub fn cursorDown(writer: *Writer, n: u16) !void {
    if (n > 0) try writer.print(CSI ++ "{d}B", .{n});
}

pub fn cursorForward(writer: *Writer, n: u16) !void {
    if (n > 0) try writer.print(CSI ++ "{d}C", .{n});
}

pub fn cursorBack(writer: *Writer, n: u16) !void {
    if (n > 0) try writer.print(CSI ++ "{d}D", .{n});
}

pub fn cursorToCol(writer: *Writer, col: u16) !void {
    try writer.print(CSI ++ "{d}G", .{col});
}

pub fn cursorToCol0(writer: *Writer, col: u16) !void {
    try writer.print(CSI ++ "{d}G", .{col + 1});
}

pub fn requestCursorPos(writer: *Writer) !void {
    try writer.writeAll(CSI ++ "6n");
}

pub fn setScrollRegion(writer: *Writer, top: u16, bottom: u16) !void {
    try writer.print(CSI ++ "{d};{d}r", .{ top, bottom });
}

pub fn resetScrollRegion(writer: *Writer) !void {
    try writer.writeAll(CSI ++ "r");
}

pub fn scrollUp(writer: *Writer, n: u16) !void {
    if (n > 0) try writer.print(CSI ++ "{d}S", .{n});
}

pub fn scrollDown(writer: *Writer, n: u16) !void {
    if (n > 0) try writer.print(CSI ++ "{d}T", .{n});
}

pub fn eraseChars(writer: *Writer, n: u16) !void {
    try writer.print(CSI ++ "{d}X", .{n});
}

pub fn insertLines(writer: *Writer, n: u16) !void {
    if (n > 0) try writer.print(CSI ++ "{d}L", .{n});
}

pub fn deleteLines(writer: *Writer, n: u16) !void {
    if (n > 0) try writer.print(CSI ++ "{d}M", .{n});
}

pub fn setTitle(writer: *Writer, title: []const u8) !void {
    try writer.print(OSC ++ "0;{s}\x07", .{title});
}

fn writeOscTerminator(writer: *Writer, terminator: OscTerminator) !void {
    switch (terminator) {
        .bel => try writer.writeAll("\x07"),
        .st => try writer.writeAll(ST),
    }
}

fn writeEscapedForDcs(writer: *Writer, bytes: []const u8) !void {
    var start: usize = 0;
    for (bytes, 0..) |byte, idx| {
        if (byte != 0x1b) continue;

        if (idx > start) {
            try writer.writeAll(bytes[start..idx]);
        }
        try writer.writeAll(ESC ++ ESC);
        start = idx + 1;
    }

    if (start < bytes.len) {
        try writer.writeAll(bytes[start..]);
    }
}

pub fn osc52Start(
    writer: *Writer,
    target: []const u8,
    passthrough: Osc52Passthrough,
) !void {
    switch (passthrough) {
        .none => {
            try writer.writeAll(OSC ++ "52;");
            try writer.writeAll(target);
            try writer.writeAll(";");
        },
        .tmux => {
            try writer.writeAll(DCS ++ "tmux;");
            try writeEscapedForDcs(writer, OSC ++ "52;");
            try writeEscapedForDcs(writer, target);
            try writeEscapedForDcs(writer, ";");
        },
        .dcs => {
            try writer.writeAll(DCS);
            try writeEscapedForDcs(writer, OSC ++ "52;");
            try writeEscapedForDcs(writer, target);
            try writeEscapedForDcs(writer, ";");
        },
    }
}

pub fn osc52End(writer: *Writer, terminator: OscTerminator, passthrough: Osc52Passthrough) !void {
    switch (passthrough) {
        .none => try writeOscTerminator(writer, terminator),
        .tmux, .dcs => {
            switch (terminator) {
                .bel => try writer.writeAll("\x07"),
                .st => try writer.writeAll(ESC ++ ESC ++ "\\"),
            }
            try writer.writeAll(ST);
        },
    }
}

pub fn osc52Encoded(
    writer: *Writer,
    target: []const u8,
    payload_b64: []const u8,
    terminator: OscTerminator,
    passthrough: Osc52Passthrough,
) !void {
    try osc52Start(writer, target, passthrough);
    try writer.writeAll(payload_b64);
    try osc52End(writer, terminator, passthrough);
}

pub const SGR = struct {
    pub const reset = 0;
    pub const bold = 1;
    pub const dim = 2;
    pub const italic = 3;
    pub const underline = 4;
    pub const blink = 5;
    pub const blink_rapid = 6;
    pub const reverse = 7;
    pub const hidden = 8;
    pub const strikethrough = 9;

    pub const no_bold = 22;
    pub const no_italic = 23;
    pub const no_underline = 24;
    pub const no_blink = 25;
    pub const no_reverse = 27;
    pub const no_hidden = 28;
    pub const no_strikethrough = 29;

    pub const fg_black = 30;
    pub const fg_red = 31;
    pub const fg_green = 32;
    pub const fg_yellow = 33;
    pub const fg_blue = 34;
    pub const fg_magenta = 35;
    pub const fg_cyan = 36;
    pub const fg_white = 37;
    pub const fg_default = 39;

    pub const bg_black = 40;
    pub const bg_red = 41;
    pub const bg_green = 42;
    pub const bg_yellow = 43;
    pub const bg_blue = 44;
    pub const bg_magenta = 45;
    pub const bg_cyan = 46;
    pub const bg_white = 47;
    pub const bg_default = 49;

    pub const fg_bright_black = 90;
    pub const fg_bright_red = 91;
    pub const fg_bright_green = 92;
    pub const fg_bright_yellow = 93;
    pub const fg_bright_blue = 94;
    pub const fg_bright_magenta = 95;
    pub const fg_bright_cyan = 96;
    pub const fg_bright_white = 97;

    pub const bg_bright_black = 100;
    pub const bg_bright_red = 101;
    pub const bg_bright_green = 102;
    pub const bg_bright_yellow = 103;
    pub const bg_bright_blue = 104;
    pub const bg_bright_magenta = 105;
    pub const bg_bright_cyan = 106;
    pub const bg_bright_white = 107;
};

pub fn sgr(writer: *Writer, codes: []const u8) !void {
    try writer.writeAll(CSI);
    for (codes, 0..) |code, i| {
        if (i > 0) try writer.writeByte(';');
        try writer.print("{d}", .{code});
    }
    try writer.writeByte('m');
}

pub fn fg256(writer: *Writer, color: u8) !void {
    try writer.print(CSI ++ "38;5;{d}m", .{color});
}

pub fn bg256(writer: *Writer, color: u8) !void {
    try writer.print(CSI ++ "48;5;{d}m", .{color});
}

pub fn fgRgb(writer: *Writer, r: u8, g: u8, b: u8) !void {
    try writer.print(CSI ++ "38;2;{d};{d};{d}m", .{ r, g, b });
}

pub fn bgRgb(writer: *Writer, r: u8, g: u8, b: u8) !void {
    try writer.print(CSI ++ "48;2;{d};{d};{d}m", .{ r, g, b });
}

pub fn hyperlink(writer: *Writer, url: []const u8, text: []const u8) !void {
    try writer.print(OSC ++ "8;;{s}\x07{s}" ++ OSC ++ "8;;\x07", .{ url, text });
}

pub fn kittyGraphics(writer: *Writer, params: []const u8, payload: []const u8) !void {
    try writer.writeAll(APC ++ "G");
    try writer.writeAll(params);
    try writer.writeAll(";");
    try writer.writeAll(payload);
    try writer.writeAll(ST);
}

pub fn iterm2InlineImage(writer: *Writer, params: []const u8, payload: []const u8) !void {
    try writer.writeAll(OSC ++ "1337;File=");
    try writer.writeAll(params);
    try writer.writeAll(":");
    try writer.writeAll(payload);
    try writer.writeAll("\x07");
}

test "osc52Encoded direct BEL" {
    var buf: [128]u8 = undefined;
    var writer: Writer = .fixed(&buf);
    try osc52Encoded(&writer, "c", "YQ==", .bel, .none);
    try std.testing.expectEqualStrings("\x1b]52;c;YQ==\x07", writer.buffered());
}

test "osc52Encoded direct ST" {
    var buf: [128]u8 = undefined;
    var writer: Writer = .fixed(&buf);
    try osc52Encoded(&writer, "c", "YQ==", .st, .none);
    try std.testing.expectEqualStrings("\x1b]52;c;YQ==\x1b\\", writer.buffered());
}

test "osc52Encoded tmux passthrough BEL" {
    var buf: [256]u8 = undefined;
    var writer: Writer = .fixed(&buf);
    try osc52Encoded(&writer, "c", "YQ==", .bel, .tmux);
    try std.testing.expectEqualStrings("\x1bPtmux;\x1b\x1b]52;c;YQ==\x07\x1b\\", writer.buffered());
}

test "osc52Encoded tmux passthrough ST" {
    var buf: [256]u8 = undefined;
    var writer: Writer = .fixed(&buf);
    try osc52Encoded(&writer, "c", "YQ==", .st, .tmux);
    try std.testing.expectEqualStrings("\x1bPtmux;\x1b\x1b]52;c;YQ==\x1b\x1b\\\x1b\\", writer.buffered());
}
