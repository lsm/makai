const std = @import("std");
const zz = @import("zigzag");
const tui_state = @import("tui_state");

pub const palette = struct {
    pub const text = zz.Color.brightWhite;
    pub const soft = zz.Color.gray(18);
    pub const muted = zz.Color.gray(12);
    pub const dim = zz.Color.gray(9);
    pub const faint = zz.Color.gray(6);
    pub const border = zz.Color.gray(8);
    pub const panel_border = zz.Color.gray(10);
    pub const panel_title = zz.Color.brightCyan;
    pub const user = zz.Color.brightBlue;
    pub const assistant = zz.Color.brightCyan;
    pub const thinking = zz.Color.brightMagenta;
    pub const tool = zz.Color.brightYellow;
    pub const tool_shell = zz.Color.brightCyan;
    pub const tool_read = zz.Color.brightGreen;
    pub const tool_write = zz.Color.brightMagenta;
    pub const tool_search = zz.Color.fromRgb(122, 162, 247);
    pub const tool_workspace = zz.Color.brightBlue;
    pub const tool_sync = zz.Color.fromRgb(255, 160, 80);
    pub const tool_auth = zz.Color.fromRgb(187, 154, 247);
    pub const system = zz.Color.gray(18);
    pub const danger = zz.Color.brightRed;
    pub const success = zz.Color.brightGreen;
    pub const warning = zz.Color.brightYellow;
    pub const running = zz.Color.brightCyan;
    pub const accent = zz.Color.fromRgb(122, 162, 247);
    pub const accent_dim = zz.Color.fromRgb(84, 110, 170);
    pub const accent_bright = zz.Color.fromRgb(170, 198, 255);
    pub const surface = zz.Color.fromRgb(22, 22, 30);
    pub const surface_alt = zz.Color.fromRgb(31, 31, 42);
    pub const user_bg = zz.Color.fromRgb(34, 40, 58);
    pub const user_fg = zz.Color.fromRgb(224, 230, 246);
    pub const code_bg = zz.Color.fromRgb(27, 29, 39);
    pub const code_fg = zz.Color.gray(17);
    pub const code_inline = zz.Color.fromRgb(255, 199, 119);
    pub const selection_bg = zz.Color.fromRgb(40, 46, 70);
    pub const heading = zz.Color.fromRgb(170, 198, 255);
};

pub const ToolVisualKind = enum {
    shell,
    read,
    write,
    search,
    workspace,
    sync,
    auth,
    other,
};

pub const glyph = struct {
    pub const user = "\u{276f}";
    pub const assistant = "\u{2726}";
    pub const thinking = "\u{273b}";
    pub const tool = "\u{25c6}";
    pub const system = "\u{2022}";
    pub const err = "\u{2718}";
    pub const welcome = "\u{2726}";
    pub const sep = "\u{2502}";
    pub const dot = "\u{00b7}";
    pub const scroll_up = "\u{2191}";
    pub const prompt = "\u{276f}";
    pub const caret = "\u{258d}";
    pub const result = "\u{23bf}";
    pub const bullet = "\u{2022}";
    pub const check = "\u{2713}";
    pub const cross = "\u{2717}";
    pub const stop = "\u{25a0}";
    pub const pending = "\u{25cc}";
    pub const select = "\u{276f}";
    pub const gauge_on = "\u{25b0}";
    pub const gauge_off = "\u{25b1}";
    pub const quote_bar = "\u{258e}";
    pub const spinner = [_][]const u8{
        "\u{280b}", "\u{2819}", "\u{2839}", "\u{2838}",
        "\u{283c}", "\u{2834}", "\u{2826}", "\u{2827}",
        "\u{2807}", "\u{280f}",
    };
    pub const pulse = [_][]const u8{ "\u{25cf}", "\u{25d0}", "\u{25cb}", "\u{25d1}" };
};

pub const key = struct {
    pub const enter = "\u{23ce}";
    pub const shift = "\u{21e7}";
    pub const tab = "\u{21e5}";
    pub const esc = "esc";
    pub const ctrl = "^";
    pub const up_down = "\u{2191}\u{2193}";
};

pub fn roleGlyph(kind: tui_state.TranscriptKind) []const u8 {
    return switch (kind) {
        .user => glyph.user,
        .assistant => glyph.assistant,
        .thinking => glyph.thinking,
        .tool => glyph.tool,
        .system => glyph.system,
        .welcome => glyph.welcome,
        .@"error" => glyph.err,
    };
}

pub fn spinnerFrame(anim_tick: u64) []const u8 {
    return glyph.spinner[@intCast(anim_tick % glyph.spinner.len)];
}

pub fn pulseFrame(anim_tick: u64) []const u8 {
    return glyph.pulse[@intCast((anim_tick / 4) % glyph.pulse.len)];
}

pub fn pulseColor(anim_tick: u64) zz.Color {
    return switch ((anim_tick / 5) % 4) {
        0 => palette.accent_dim,
        1 => palette.accent,
        2 => palette.accent_bright,
        else => palette.accent,
    };
}

pub fn base() zz.Style {
    return (zz.Style{}).fg(palette.text).inline_style(true);
}

pub fn soft() zz.Style {
    return (zz.Style{}).fg(palette.soft).inline_style(true);
}

pub fn muted() zz.Style {
    return (zz.Style{}).fg(palette.muted).dim(true).inline_style(true);
}

pub fn dim() zz.Style {
    return (zz.Style{}).fg(palette.dim).dim(true).inline_style(true);
}

pub fn faint() zz.Style {
    return (zz.Style{}).fg(palette.faint).inline_style(true);
}

pub fn strong() zz.Style {
    return (zz.Style{}).fg(palette.text).bold(true).inline_style(true);
}

pub fn accentText() zz.Style {
    return (zz.Style{}).fg(palette.accent).inline_style(true);
}

pub fn accentStrong() zz.Style {
    return (zz.Style{}).fg(palette.accent).bold(true).inline_style(true);
}

pub fn heading() zz.Style {
    return (zz.Style{}).fg(palette.heading).bold(true).inline_style(true);
}

pub fn emphasis() zz.Style {
    return (zz.Style{}).fg(palette.text).italic(true).inline_style(true);
}

pub fn inlineCode() zz.Style {
    return (zz.Style{}).fg(palette.code_inline).inline_style(true);
}

pub fn codeBlock() zz.Style {
    return (zz.Style{}).fg(palette.code_fg).bg(palette.code_bg).inline_style(true);
}

pub fn codeTag() zz.Style {
    return (zz.Style{}).fg(palette.dim).bg(palette.code_bg).italic(true).inline_style(true);
}

pub fn quote() zz.Style {
    return (zz.Style{}).fg(palette.muted).italic(true).inline_style(true);
}

pub fn userBlock() zz.Style {
    return (zz.Style{}).fg(palette.user_fg).bg(palette.user_bg).inline_style(true);
}

pub fn caret() zz.Style {
    return (zz.Style{}).fg(palette.accent_bright).inline_style(true);
}

pub fn keyHint() zz.Style {
    return (zz.Style{}).fg(palette.muted).inline_style(true);
}

pub fn keyCap() zz.Style {
    return (zz.Style{}).fg(palette.soft).bold(true).inline_style(true);
}

pub fn selectionRow() zz.Style {
    return (zz.Style{}).fg(palette.text).bg(palette.selection_bg).bold(true).inline_style(true);
}

pub fn panel() zz.Style {
    return (zz.Style{})
        .borderAll(zz.Border.rounded)
        .borderForeground(palette.panel_border)
        .padding(.{ .top = 0, .right = 1, .bottom = 0, .left = 1 });
}

pub fn panelWith(color: zz.Color) zz.Style {
    return panel().borderForeground(color);
}

pub fn panelTitle() zz.Style {
    return (zz.Style{}).fg(palette.panel_title).bold(true).inline_style(true);
}

pub const TitledPanelOptions = struct {
    title: []const u8 = "",
    title_style: ?zz.Style = null,
    border: zz.Color = palette.panel_border,
    width: usize = 80,
};

pub fn titledPanel(allocator: std.mem.Allocator, body: []const u8, options: TitledPanelOptions) ![]const u8 {
    const inner: usize = @min(options.width -| 4, std.math.maxInt(u16));
    const boxed = try panelWith(options.border).width(@intCast(inner)).render(allocator, body);
    if (options.title.len == 0) return boxed;
    defer allocator.free(boxed);

    const first_break = std.mem.indexOfScalar(u8, boxed, '\n') orelse boxed.len;
    const rest = boxed[first_break..];
    const title_style = options.title_style orelse panelTitle();
    const styled_title = try title_style.render(allocator, options.title);
    defer allocator.free(styled_title);
    const title_width = zz.width(options.title);
    const line_width = inner + 2;
    const rule_len = line_width -| (title_width + 2);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try options.border.writeFg(writer);
    try writer.writeAll(zz.Border.rounded.top_left);
    try writer.writeAll(zz.Border.rounded.horizontal);
    try writer.writeAll(zz.ansi.reset);
    try writer.writeByte(' ');
    try writer.writeAll(styled_title);
    try writer.writeByte(' ');
    try options.border.writeFg(writer);
    var i: usize = 0;
    while (i + 1 < rule_len) : (i += 1) try writer.writeAll(zz.Border.rounded.horizontal);
    try writer.writeAll(zz.Border.rounded.top_right);
    try writer.writeAll(zz.ansi.reset);
    try writer.writeAll(rest);
    return out.toOwnedSlice();
}

pub fn role(kind: tui_state.TranscriptKind) zz.Style {
    return switch (kind) {
        .user => (zz.Style{}).fg(palette.user).bold(true).inline_style(true),
        .assistant => (zz.Style{}).fg(palette.assistant).bold(true).inline_style(true),
        .thinking => (zz.Style{}).fg(palette.thinking).inline_style(true),
        .tool => (zz.Style{}).fg(palette.tool).bold(true).inline_style(true),
        .system => (zz.Style{}).fg(palette.system).inline_style(true),
        .welcome => accentStrong(),
        .@"error" => (zz.Style{}).fg(palette.danger).bold(true).inline_style(true),
    };
}

pub fn bodyStyle(kind: tui_state.TranscriptKind) zz.Style {
    return switch (kind) {
        .user => userBlock(),
        .assistant => base(),
        .thinking => (zz.Style{}).fg(palette.muted).italic(true).inline_style(true),
        .tool => (zz.Style{}).fg(palette.tool).inline_style(true),
        .system => systemText(),
        .welcome => soft(),
        .@"error" => errorBody(),
    };
}

pub fn toolKindForName(name: []const u8) ToolVisualKind {
    if (toolNameMatches(name, &.{ "workspace", "git" })) return .workspace;
    if (toolNameMatches(name, &.{ "sync", "pull", "push", "fetch", "download", "upload" })) return .sync;
    if (toolNameMatches(name, &.{ "auth", "login", "oauth", "token" })) return .auth;
    if (toolNameMatches(name, &.{ "shell", "bash", "exec", "execute", "command", "run" })) return .shell;
    if (toolNameMatches(name, &.{ "write", "edit", "patch", "delete", "insert", "replace", "hashline_edit" })) return .write;
    if (toolNameMatches(name, &.{ "read", "stat", "cat", "hashline_read", "view" })) return .read;
    if (toolNameMatches(name, &.{ "search", "grep", "find", "rg", "list" })) return .search;
    return .other;
}

pub fn toolColorForName(name: []const u8) zz.Color {
    return switch (toolKindForName(name)) {
        .shell => palette.tool_shell,
        .read => palette.tool_read,
        .write => palette.tool_write,
        .search => palette.tool_search,
        .workspace => palette.tool_workspace,
        .sync => palette.tool_sync,
        .auth => palette.tool_auth,
        .other => palette.tool,
    };
}

pub fn toolRole(name: []const u8) zz.Style {
    return (zz.Style{}).fg(toolColorForName(name)).bold(true).inline_style(true);
}

pub fn toolBody(name: []const u8) zz.Style {
    return (zz.Style{}).fg(toolColorForName(name)).inline_style(true);
}

fn toolNameMatches(name: []const u8, tokens: []const []const u8) bool {
    for (tokens) |token| {
        if (std.mem.eql(u8, name, token)) return true;
    }
    var parts = std.mem.tokenizeAny(u8, name, "_-:./ ");
    while (parts.next()) |part| {
        for (tokens) |token| {
            if (std.mem.eql(u8, part, token)) return true;
        }
    }
    return false;
}

pub fn toolStatus(status: tui_state.ToolStatus) zz.Style {
    return switch (status) {
        .pending => (zz.Style{}).fg(palette.warning).bold(true).inline_style(true),
        .running => (zz.Style{}).fg(palette.running).bold(true).inline_style(true),
        .done => (zz.Style{}).fg(palette.success).bold(true).inline_style(true),
        .interrupted => (zz.Style{}).fg(palette.warning).bold(true).inline_style(true),
        .@"error" => (zz.Style{}).fg(palette.danger).bold(true).inline_style(true),
    };
}

pub fn errorText() zz.Style {
    return (zz.Style{}).fg(palette.danger).bold(true).inline_style(true);
}

pub fn errorBody() zz.Style {
    return (zz.Style{}).fg(palette.danger).inline_style(true);
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

pub fn systemText() zz.Style {
    return (zz.Style{}).fg(palette.system).inline_style(true);
}

pub fn link() zz.Style {
    return (zz.Style{}).fg(palette.accent).underline(true).inline_style(true);
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

pub fn statusModel() zz.Style {
    return (zz.Style{}).fg(palette.accent).bold(true).inline_style(true);
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

test "theme classifies tool colors by operation" {
    try std.testing.expectEqual(ToolVisualKind.shell, toolKindForName("shell_execute"));
    try std.testing.expectEqual(ToolVisualKind.read, toolKindForName("file_read"));
    try std.testing.expectEqual(ToolVisualKind.write, toolKindForName("hashline_edit"));
    try std.testing.expectEqual(ToolVisualKind.search, toolKindForName("search_text"));
    try std.testing.expectEqual(ToolVisualKind.workspace, toolKindForName("workspace_git_status"));
    try std.testing.expectEqual(ToolVisualKind.auth, toolKindForName("openai_login"));
}

test "titled panel embeds the title in the top border at the requested width" {
    const text = try titledPanel(std.testing.allocator, "body", .{ .title = "Select model", .width = 40 });
    defer std.testing.allocator.free(text);

    var lines = std.mem.splitScalar(u8, text, '\n');
    const top = lines.next().?;
    try std.testing.expect(std.mem.indexOf(u8, top, "Select model") != null);
    try std.testing.expectEqual(@as(usize, 40), zz.width(top));
    const body_line = lines.next().?;
    try std.testing.expect(std.mem.indexOf(u8, body_line, "body") != null);
    try std.testing.expectEqual(@as(usize, 40), zz.width(body_line));
    const bottom = lines.next().?;
    try std.testing.expectEqual(@as(usize, 40), zz.width(bottom));
}

test "spinner and pulse frames cycle without leaving the table" {
    var tick: u64 = 0;
    while (tick < 64) : (tick += 1) {
        try std.testing.expect(spinnerFrame(tick).len > 0);
        try std.testing.expect(pulseFrame(tick).len > 0);
        _ = pulseColor(tick);
    }
}
