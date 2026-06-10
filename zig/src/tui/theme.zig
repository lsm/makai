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
    pub const system = zz.Color.gray(18);
    pub const danger = zz.Color.brightRed;
    pub const success = zz.Color.brightGreen;
    pub const warning = zz.Color.brightYellow;
    pub const running = zz.Color.brightCyan;
    pub const accent = zz.Color.fromRgb(122, 162, 247);
    pub const surface = zz.Color.fromRgb(22, 22, 30);
    pub const surface_alt = zz.Color.fromRgb(31, 31, 42);
};

/// Single-width Unicode glyphs chosen for broad terminal/font support (no
/// variation selectors, no emoji that reflow to width 2). They give the UI a
/// richer, more colorful identity than bare `Role:` text labels.
pub const glyph = struct {
    pub const user = "\u{276f}"; // ❯ heavy right chevron
    pub const assistant = "\u{2726}"; // ✦ four-pointed star
    pub const thinking = "\u{273b}"; // ✻ teardrop-spoked asterisk
    pub const tool = "\u{25c6}"; // ◆ filled diamond
    pub const system = "\u{2022}"; // • bullet
    pub const err = "\u{2718}"; // ✘ heavy ballot X
    pub const sep = "\u{2502}"; // │ light vertical (status separator)
    pub const scroll_up = "\u{2191}"; // ↑
    pub const prompt = "\u{276f}"; // ❯ composer prompt chevron
    /// Braille spinner frames; smooth and monospace-safe.
    pub const spinner = [_][]const u8{
        "\u{280b}", "\u{2819}", "\u{2839}", "\u{2838}",
        "\u{283c}", "\u{2834}", "\u{2826}", "\u{2827}",
        "\u{2807}", "\u{280f}",
    };
};

/// Glyph + short name for a transcript role, e.g. "❯ You".
pub fn roleGlyph(kind: tui_state.TranscriptKind) []const u8 {
    return switch (kind) {
        .user => glyph.user,
        .assistant => glyph.assistant,
        .thinking => glyph.thinking,
        .tool => glyph.tool,
        .system => glyph.system,
        .@"error" => glyph.err,
    };
}

/// Current braille spinner frame for the given animation tick.
pub fn spinnerFrame(anim_tick: u64) []const u8 {
    return glyph.spinner[@intCast(anim_tick % glyph.spinner.len)];
}

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
        .system => (zz.Style{}).fg(palette.system).inline_style(true),
        .@"error" => (zz.Style{}).fg(palette.danger).bold(true).inline_style(true),
    };
}

/// Style for the *body* text of a transcript entry (the message content, not
/// the role label). Coloring the content itself — user input in blue, tool
/// activity in amber, errors in red — lets the eye triage the transcript at a
/// glance. Assistant text is excluded here: it renders through the markdown
/// engine, which supplies its own syntax colors.
pub fn bodyStyle(kind: tui_state.TranscriptKind) zz.Style {
    return switch (kind) {
        .user => (zz.Style{}).fg(palette.user).inline_style(true),
        .assistant => base(),
        .thinking => (zz.Style{}).fg(palette.thinking).dim(true).inline_style(true),
        .tool => (zz.Style{}).fg(palette.tool).inline_style(true),
        .system => systemText(),
        .@"error" => errorText(),
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

pub fn runningText() zz.Style {
    return (zz.Style{}).fg(palette.running).bold(true).inline_style(true);
}

pub fn warningText() zz.Style {
    return (zz.Style{}).fg(palette.warning).bold(true).inline_style(true);
}

/// Legible secondary text for system notices and command output (`/help`,
/// `/tools`, …). A readable light grey — distinct from bright-white assistant
/// text, but NOT dimmed, so it stays easy to read.
pub fn systemText() zz.Style {
    return (zz.Style{}).fg(palette.system).inline_style(true);
}

pub fn composerPrompt() zz.Style {
    return (zz.Style{}).fg(palette.accent).bold(true).inline_style(true);
}

pub fn composerPlaceholder() zz.Style {
    return muted();
}

pub fn composerCursor() zz.Style {
    return (zz.Style{}).fg(palette.surface).bg(palette.text).bold(true).inline_style(true);
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
