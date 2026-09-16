const std = @import("std");
const zz = @import("zigzag");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");
const tui_render = @import("tui_render");

pub const Options = struct {
    width: usize = 80,
    anim_tick: u64 = 0,
};

const cursor_blank = " ";
const cursor_cell_width = 1;
const max_draft_rows = 6;
const placeholder_text = "Ask Makai…";

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]const u8 {
    const inner_width = options.width -| 4;
    const input = try renderInput(allocator, state, inner_width);
    defer allocator.free(input);
    const border = borderColor(state, options.anim_tick);
    return tui_theme.panelWith(border).width(@intCast(@min(inner_width, std.math.maxInt(u16)))).render(allocator, input);
}

pub fn borderColor(state: *const tui_state.AppState, anim_tick: u64) zz.Color {
    if (state.mode == .approval) return tui_theme.palette.warning;
    if (state.mode == .login_input) return tui_theme.palette.thinking;
    if (state.status.streaming) return tui_theme.pulseColor(anim_tick);
    if (state.composer.text().len > 0) return tui_theme.palette.accent;
    return tui_theme.palette.panel_border;
}

pub fn hintText(allocator: std.mem.Allocator, state: *const tui_state.AppState) ![]u8 {
    const text = state.composer.text();
    const k = tui_theme.key;
    switch (state.mode) {
        .approval => return allocator.dupe(u8, "y allow · a always · n deny · esc abort"),
        .login_input => return std.fmt.allocPrint(allocator, "{s} submit · esc cancel", .{k.enter}),
        .picker, .session_picker => return std.fmt.allocPrint(allocator, "{s} move · {s} select · esc close", .{ k.up_down, k.enter }),
        .normal => {},
    }
    if (state.status.streaming) {
        const queued = state.queue.total();
        if (queued > 0) return std.fmt.allocPrint(allocator, "{s} steer · queued {d} · esc abort", .{ k.enter, queued });
        return std.fmt.allocPrint(allocator, "{s} steer · esc abort", .{k.enter});
    }
    if (std.mem.startsWith(u8, text, "!")) return std.fmt.allocPrint(allocator, "shell mode · {s} runs the command through the agent", .{k.enter});
    if (std.mem.startsWith(u8, text, "@")) return allocator.dupe(u8, "file picker · type a path or query");
    if (std.mem.startsWith(u8, text, "/")) return std.fmt.allocPrint(allocator, "{s} complete · {s} run · esc clear", .{ k.tab, k.enter });
    if (state.composer.history.items.len > 0) {
        return std.fmt.allocPrint(allocator, "{s} history · {s}{s} newline · / commands", .{ k.up_down, k.shift, k.enter });
    }
    return std.fmt.allocPrint(allocator, "{s} send · {s}{s} newline · / commands · {s}C quit", .{ k.enter, k.shift, k.enter, k.ctrl });
}

fn renderInput(allocator: std.mem.Allocator, state: *const tui_state.AppState, width: usize) ![]u8 {
    const prompt = try tui_theme.composerPrompt().render(allocator, promptFor(state));
    defer allocator.free(prompt);
    const content_width = width -| tui_text.visibleWidth(promptFor(state));
    if (content_width == 0) return prefixFirstLine(allocator, prompt, "");
    if (state.mode == .login_input and state.login_input_secret and state.composer.text().len > 0) {
        const masked = try maskedSecretInput(allocator, state.composer.text());
        defer allocator.free(masked);
        const draft = try renderDraftWithCursor(allocator, masked, masked.len, content_width);
        defer allocator.free(draft);
        return prefixFirstLine(allocator, prompt, draft);
    }
    if (state.composer.text().len == 0) {
        const draft_width = content_width -| cursor_cell_width;
        const placeholder_source = try placeholderFor(allocator, state);
        defer allocator.free(placeholder_source);
        const placeholder = try tui_text.truncateLineToWidth(allocator, placeholder_source, draft_width);
        defer allocator.free(placeholder);
        const styled_placeholder = try tui_theme.composerPlaceholder().render(allocator, placeholder);
        defer allocator.free(styled_placeholder);
        const cursor = try renderCursorCell(allocator, cursor_blank);
        defer allocator.free(cursor);
        const content = try std.fmt.allocPrint(allocator, "{s}{s}", .{ cursor, styled_placeholder });
        defer allocator.free(content);
        return prefixFirstLine(allocator, prompt, content);
    }
    const draft = try renderDraftWithCursor(allocator, state.composer.text(), state.composer.cursor, content_width);
    defer allocator.free(draft);
    return prefixFirstLine(allocator, prompt, draft);
}

fn placeholderFor(allocator: std.mem.Allocator, state: *const tui_state.AppState) ![]u8 {
    if (state.mode == .login_input) return allocator.dupe(u8, if (state.login_input_secret) "paste the secret and press Enter" else "type your answer and press Enter");
    if (state.mode == .approval) {
        const queued = state.queue.total();
        if (queued > 0) return std.fmt.allocPrint(allocator, "{d} queued · y / a / n to decide", .{queued});
        return allocator.dupe(u8, "y / a / n to decide, or type /abort");
    }
    if (state.status.streaming) {
        const queued = state.queue.total();
        if (queued > 0) return std.fmt.allocPrint(allocator, "{d} queued · type to steer more…", .{queued});
        return allocator.dupe(u8, "type to steer the running turn…");
    }
    return allocator.dupe(u8, placeholder_text);
}

fn maskedSecretInput(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) return allocator.dupe(u8, "");
    const mask = try allocator.alloc(u8, text.len);
    @memset(mask, '*');
    return mask;
}

fn renderDraftWithCursor(allocator: std.mem.Allocator, text: []const u8, cursor: usize, width: usize) ![]u8 {
    if (width == 0) return allocator.dupe(u8, "");
    const normalized_cursor = utf8BoundaryAtOrBefore(text, @min(cursor, text.len));
    const before = text[0..normalized_cursor];
    const after = text[normalized_cursor..];
    const plain = try appendCursorBlock(allocator, before, after);
    defer allocator.free(plain);
    if (tui_text.lineCount(plain) <= max_draft_rows and maxLineWidth(plain) <= width) return allocator.dupe(u8, plain);

    const visible_after_budget = @min(width / 3, width -| cursor_cell_width);
    const after_preview = try takeLeadingWidth(allocator, after, visible_after_budget);
    defer allocator.free(after_preview);
    const before_budget = width -| cursor_cell_width -| tui_text.visibleWidth(after_preview);
    const before_preview = try takeTrailingWidth(allocator, before, before_budget);
    defer allocator.free(before_preview);
    const windowed = try appendCursorBlock(allocator, before_preview, after_preview);
    defer allocator.free(windowed);
    return tui_text.truncateLinesToWidth(allocator, windowed, width, max_draft_rows);
}

fn maxLineWidth(text: []const u8) usize {
    var widest: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| widest = @max(widest, tui_text.visibleWidth(line));
    return widest;
}

fn appendCursorBlock(allocator: std.mem.Allocator, before: []const u8, after: []const u8) ![]u8 {
    const cell_end = if (after.len == 0) 0 else nextCodepointEnd(after, 0);
    const cursor_cell = if (cell_end == 0 or after[0] == '\n') cursor_blank else after[0..cell_end];
    const cursor = try renderCursorCell(allocator, cursor_cell);
    defer allocator.free(cursor);
    const rest = if (cell_end == 0 or after[0] == '\n') after else after[cell_end..];
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ before, cursor, rest });
}

fn renderCursorCell(allocator: std.mem.Allocator, cell: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "\x1b[7m{s}\x1b[27m", .{cell});
}

fn takeLeadingWidth(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    if (width == 0 or text.len == 0) return allocator.dupe(u8, "");
    return tui_text.truncateLineToWidth(allocator, text, width);
}

fn takeTrailingWidth(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    if (width == 0 or text.len == 0) return allocator.dupe(u8, "");
    if (tui_text.visibleWidth(text) <= width and std.mem.indexOfScalar(u8, text, '\n') == null) return allocator.dupe(u8, text);
    var start = text.len;
    var visible: usize = 0;
    while (start > 0 and visible < width -| 1) {
        const cp_start = previousCodepointStart(text, start);
        const cp = text[cp_start..start];
        if (cp.len == 1 and cp[0] == '\n') break;
        visible += tui_text.visibleWidth(cp);
        if (visible > width -| 1) break;
        start = cp_start;
    }
    return std.fmt.allocPrint(allocator, "…{s}", .{text[start..]});
}

fn previousCodepointStart(text: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var idx = @min(cursor, text.len) - 1;
    while (idx > 0 and (text[idx] & 0b1100_0000) == 0b1000_0000) idx -= 1;
    return idx;
}

fn nextCodepointEnd(text: []const u8, cursor: usize) usize {
    const idx = utf8BoundaryAtOrBefore(text, @min(cursor, text.len));
    if (idx >= text.len) return text.len;
    const len = std.unicode.utf8ByteSequenceLength(text[idx]) catch 1;
    return @min(text.len, idx + len);
}

fn utf8BoundaryAtOrBefore(text: []const u8, index: usize) usize {
    var idx = @min(index, text.len);
    while (idx > 0 and idx < text.len and (text[idx] & 0b1100_0000) == 0b1000_0000) idx -= 1;
    return idx;
}

fn promptFor(state: *const tui_state.AppState) []const u8 {
    const text = state.composer.text();
    if (std.mem.startsWith(u8, text, "!")) return "! ";
    if (std.mem.startsWith(u8, text, "@")) return "@ ";
    return tui_theme.glyph.prompt ++ " ";
}

fn prefixFirstLine(allocator: std.mem.Allocator, prompt: []const u8, content: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(prompt);
    var lines = std.mem.splitScalar(u8, content, '\n');
    if (lines.next()) |first| try writer.writeAll(first);
    while (lines.next()) |line| {
        try writer.writeByte('\n');
        try writer.writeAll("  ");
        try writer.writeAll(line);
    }
    return out.toOwnedSlice();
}

test "composer renders placeholder and text" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    const placeholder = try render(std.testing.allocator, &state, .{ .width = 80 });
    defer std.testing.allocator.free(placeholder);
    try std.testing.expect(std.mem.indexOf(u8, placeholder, "Ask Makai") != null);
    try std.testing.expect(std.mem.indexOf(u8, placeholder, cursor_blank) != null);
    try std.testing.expect(std.mem.indexOf(u8, placeholder, "\u{2588}") == null);
    try std.testing.expect(std.mem.indexOf(u8, placeholder, "╭") != null);
    try std.testing.expect((std.mem.indexOf(u8, placeholder, "\x1b[7m") orelse return error.MissingCursor) < (std.mem.indexOf(u8, placeholder, "Ask Makai") orelse return error.MissingPlaceholder));
    var lines = std.mem.splitScalar(u8, placeholder, '\n');
    while (lines.next()) |line| try std.testing.expectEqual(@as(usize, 80), tui_text.visibleWidth(line));

    try state.composer.buffer.appendSlice(std.testing.allocator, "hello world");
    state.composer.cursor = state.composer.buffer.items.len;
    const text = try render(std.testing.allocator, &state, .{ .width = 30 });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, tui_theme.glyph.prompt) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{2588}") == null);
}

test "composer hint follows the interaction state" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    const idle = try hintText(std.testing.allocator, &state);
    defer std.testing.allocator.free(idle);
    try std.testing.expect(std.mem.indexOf(u8, idle, "send") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "newline") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Ctrl+R") == null);

    try state.recordComposerHistory("earlier");
    const recall = try hintText(std.testing.allocator, &state);
    defer std.testing.allocator.free(recall);
    try std.testing.expect(std.mem.indexOf(u8, recall, "history") != null);

    state.status.streaming = true;
    state.queue.steering = 2;
    const streaming = try hintText(std.testing.allocator, &state);
    defer std.testing.allocator.free(streaming);
    try std.testing.expect(std.mem.indexOf(u8, streaming, "steer") != null);
    try std.testing.expect(std.mem.indexOf(u8, streaming, "queued 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, streaming, "Alt+Enter") == null);
    state.status.streaming = false;
    state.queue.steering = 0;

    try state.replaceComposerBuffer("!ls");
    const shell = try hintText(std.testing.allocator, &state);
    defer std.testing.allocator.free(shell);
    try std.testing.expect(std.mem.indexOf(u8, shell, "shell mode") != null);

    try state.replaceComposerBuffer("@src");
    const file = try hintText(std.testing.allocator, &state);
    defer std.testing.allocator.free(file);
    try std.testing.expect(std.mem.indexOf(u8, file, "file picker") != null);

    try state.replaceComposerBuffer("/mo");
    const slash = try hintText(std.testing.allocator, &state);
    defer std.testing.allocator.free(slash);
    try std.testing.expect(std.mem.indexOf(u8, slash, "complete") != null);

    state.mode = .approval;
    const approval = try hintText(std.testing.allocator, &state);
    defer std.testing.allocator.free(approval);
    try std.testing.expect(std.mem.indexOf(u8, approval, "allow") != null);
    try std.testing.expect(std.mem.indexOf(u8, approval, "deny") != null);
}

test "streaming placeholder carries the queued count at any width" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    state.status.streaming = true;
    const steering = try placeholderFor(std.testing.allocator, &state);
    defer std.testing.allocator.free(steering);
    try std.testing.expectEqualStrings("type to steer the running turn…", steering);

    state.queue.steering = 1;
    const queued = try placeholderFor(std.testing.allocator, &state);
    defer std.testing.allocator.free(queued);
    try std.testing.expect(std.mem.indexOf(u8, queued, "1 queued") != null);
    try std.testing.expect(std.mem.indexOf(u8, queued, "steer more") != null);

    const rendered = try render(std.testing.allocator, &state, .{ .width = 30 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "1 queued") != null);

    state.mode = .approval;
    const approval = try placeholderFor(std.testing.allocator, &state);
    defer std.testing.allocator.free(approval);
    try std.testing.expect(std.mem.indexOf(u8, approval, "y / a / n to decide") != null);
    try std.testing.expect(std.mem.indexOf(u8, approval, "1 queued") != null);

    const approval_rendered = try render(std.testing.allocator, &state, .{ .width = 30 });
    defer std.testing.allocator.free(approval_rendered);
    try std.testing.expect(std.mem.indexOf(u8, approval_rendered, "1 queued") != null);
}

test "composer border reflects mode and streaming state" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expect(std.meta.eql(borderColor(&state, 0), tui_theme.palette.panel_border));
    try state.replaceComposerBuffer("draft");
    try std.testing.expect(std.meta.eql(borderColor(&state, 0), tui_theme.palette.accent));
    state.mode = .approval;
    try std.testing.expect(std.meta.eql(borderColor(&state, 0), tui_theme.palette.warning));
    state.mode = .normal;
    state.status.streaming = true;
    try std.testing.expect(std.meta.eql(borderColor(&state, 0), tui_theme.pulseColor(0)));
}

test "composer renders multiline draft content" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.composer.buffer.appendSlice(std.testing.allocator, "first line\nsecond line");
    state.composer.cursor = state.composer.buffer.items.len;

    const text = try render(std.testing.allocator, &state, .{ .width = 40 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "first line") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "second line") != null);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try std.testing.expectEqual(@as(usize, 40), tui_text.visibleWidth(line));
}

test "composer keeps a block cursor on a newline boundary" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.composer.buffer.appendSlice(std.testing.allocator, "first\nsecond");
    state.composer.cursor = 5;

    const input = try renderInput(std.testing.allocator, &state, 30);
    defer std.testing.allocator.free(input);
    try std.testing.expect(std.mem.indexOf(u8, input, "first\x1b[7m \x1b[27m\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, input, "second") != null);
}

test "composer masks secret login input" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .login_input;
    state.login_input_secret = true;
    try state.composer.buffer.appendSlice(std.testing.allocator, "sk-secret-value");
    state.composer.cursor = state.composer.buffer.items.len;

    const text = try render(std.testing.allocator, &state, .{ .width = 80 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "sk-secret-value") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "***************") != null);
}

test "composer accounts for prompt width when truncating text" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.composer.buffer.appendSlice(std.testing.allocator, "1234567890");
    state.composer.cursor = state.composer.buffer.items.len;

    const input = try renderInput(std.testing.allocator, &state, 8);
    defer std.testing.allocator.free(input);

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(tui_text.visibleWidth(line) <= 8);
    }
}

test "composer renders block cursor at current position" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.replaceComposerBuffer("abc");
    state.composer.cursor = 1;

    const input = try renderInput(std.testing.allocator, &state, 20);
    defer std.testing.allocator.free(input);

    try std.testing.expect(std.mem.indexOf(u8, input, "a\x1b[7mb\x1b[27mc") != null);
    try std.testing.expect(std.mem.indexOf(u8, input, "\u{2588}") == null);
}
