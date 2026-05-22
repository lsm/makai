const std = @import("std");
const zz = @import("zigzag");
const tui_state = @import("tui_state");

pub const palette = struct {
    pub const text = zz.Color.brightWhite;
    pub const muted = zz.Color.gray(12);
    pub const dim = zz.Color.gray(9);
    pub const border = zz.Color.gray(8);
    pub const panel_border = zz.Color.gray(10);
    pub const panel_title = zz.Color.brightCyan;
    pub const user = zz.Color.brightBlue;
    pub const assistant = zz.Color.brightCyan;
    pub const thinking = zz.Color.brightMagenta;
    pub const tool = zz.Color.brightYellow;
    pub const system = zz.Color.gray(13);
    pub const danger = zz.Color.brightRed;
    pub const success = zz.Color.brightGreen;
    pub const warning = zz.Color.brightYellow;
    pub const running = zz.Color.brightCyan;
    pub const accent = zz.Color.fromRgb(122, 162, 247);
    pub const surface = zz.Color.fromRgb(22, 22, 30);
    pub const surface_alt = zz.Color.fromRgb(31, 31, 42);
};

pub fn base() zz.Style {
    return (zz.Style{}).fg(palette.text).inline_style(true);
}

pub fn muted() zz.Style {
    return (zz.Style{}).fg(palette.muted).dim(true).inline_style(true);
}

pub fn dim() zz.Style {
    return (zz.Style{}).fg(palette.dim).dim(true).inline_style(true);
}

pub fn strong() zz.Style {
    return (zz.Style{}).fg(palette.text).bold(true).inline_style(true);
}

pub fn panel() zz.Style {
    return (zz.Style{})
        .borderAll(zz.Border.rounded)
        .borderForeground(palette.panel_border)
        .padding(.{ .top = 0, .right = 1, .bottom = 0, .left = 1 });
}

pub fn panelTitle() zz.Style {
    return (zz.Style{}).fg(palette.panel_title).bold(true).inline_style(true);
}

pub fn role(kind: tui_state.TranscriptKind) zz.Style {
    return switch (kind) {
        .user => (zz.Style{}).fg(palette.user).bold(true).inline_style(true),
        .assistant => (zz.Style{}).fg(palette.assistant).bold(true).inline_style(true),
        .thinking => (zz.Style{}).fg(palette.thinking).dim(true).inline_style(true),
        .tool => (zz.Style{}).fg(palette.tool).bold(true).inline_style(true),
        .system => (zz.Style{}).fg(palette.system).dim(true).inline_style(true),
        .@"error" => (zz.Style{}).fg(palette.danger).bold(true).inline_style(true),
    };
}

pub fn toolStatus(status: tui_state.ToolStatus) zz.Style {
    return switch (status) {
        .pending => (zz.Style{}).fg(palette.warning).bold(true).inline_style(true),
        .running => (zz.Style{}).fg(palette.running).bold(true).inline_style(true),
        .done => (zz.Style{}).fg(palette.success).bold(true).inline_style(true),
        .@"error" => (zz.Style{}).fg(palette.danger).bold(true).inline_style(true),
    };
}

pub fn errorText() zz.Style {
    return (zz.Style{}).fg(palette.danger).bold(true).inline_style(true);
}

pub fn successText() zz.Style {
    return (zz.Style{}).fg(palette.success).inline_style(true);
}

pub fn composerPrompt() zz.Style {
    return (zz.Style{}).fg(palette.accent).bold(true).inline_style(true);
}

pub fn composerPlaceholder() zz.Style {
    return muted();
}

pub fn statusSegment() zz.Style {
    return (zz.Style{}).fg(palette.text).inline_style(true);
}

pub fn statusKey() zz.Style {
    return (zz.Style{}).fg(palette.muted).dim(true).inline_style(true);
}

pub fn diffLine(line: []const u8) zz.Style {
    if (std.mem.startsWith(u8, line, "+")) return (zz.Style{}).fg(palette.success).inline_style(true);
    if (std.mem.startsWith(u8, line, "-")) return (zz.Style{}).fg(palette.danger).inline_style(true);
    return base();
}

test "theme exposes role and panel styles" {
    const styled = try role(.assistant).render(std.testing.allocator, "AI:");
    defer std.testing.allocator.free(styled);
    try std.testing.expect(std.mem.indexOf(u8, styled, "AI:") != null);

    const panel_text = try panel().render(std.testing.allocator, "body");
    defer std.testing.allocator.free(panel_text);
    try std.testing.expect(std.mem.indexOf(u8, panel_text, "body") != null);
}
