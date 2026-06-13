const std = @import("std");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");
const tui_render = @import("tui_render");

pub const Options = struct {
    width: usize = 80,
    streaming_shortcuts_supported: bool = true,
};

const cursor_blank = " ";
const cursor_cell_width = 1;

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]const u8 {
    const inner_width = options.width -| 4;
    const input = try renderInput(allocator, state, inner_width);
    defer allocator.free(input);
    const hint = try renderHint(allocator, state, options.streaming_shortcuts_supported, inner_width);
    defer allocator.free(hint);
    const body = try tui_render.joinVertical(allocator, &.{ input, hint });
    defer allocator.free(body);
    return tui_theme.panel().width(@intCast(@min(options.width -| 4, std.math.maxInt(u16)))).render(allocator, body);
}

fn renderInput(allocator: std.mem.Allocator, state: *const tui_state.AppState, width: usize) ![]u8 {
    const prompt = try tui_theme.composerPrompt().render(allocator, promptFor(state));
    defer allocator.free(prompt);
    const content_width = width -| tui_text.visibleWidth(promptFor(state));
    if (content_width == 0) return prefixFirstLine(allocator, prompt, "");
    if (state.composer.text().len == 0) {
        const draft_width = content_width -| cursor_cell_width;
        const placeholder = try tui_text.truncateLineToWidth(allocator, "Ask Makai…", draft_width);
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

fn renderDraftWithCursor(allocator: std.mem.Allocator, text: []const u8, cursor: usize, width: usize) ![]u8 {
    if (width == 0) return allocator.dupe(u8, "");
    const normalized_cursor = utf8BoundaryAtOrBefore(text, @min(cursor, text.len));
    const before = text[0..normalized_cursor];
    const after = text[normalized_cursor..];
    const plain = try appendCursorBlock(allocator, before, after);
    defer allocator.free(plain);
    if (tui_text.lineCount(plain) <= 4 and tui_text.visibleWidth(plain) <= width) return allocator.dupe(u8, plain);

    const visible_after_budget = @min(width / 3, width -| cursor_cell_width);
    const after_preview = try takeLeadingWidth(allocator, after, visible_after_budget);
    defer allocator.free(after_preview);
    const before_budget = width -| cursor_cell_width -| tui_text.visibleWidth(after_preview);
    const before_preview = try takeTrailingWidth(allocator, before, before_budget);
    defer allocator.free(before_preview);
    const windowed = try appendCursorBlock(allocator, before_preview, after_preview);
    defer allocator.free(windowed);
    return tui_text.truncateLinesToWidth(allocator, windowed, width, 4);
}

fn appendCursorBlock(allocator: std.mem.Allocator, before: []const u8, after: []const u8) ![]u8 {
    const cell_end = if (after.len == 0) 0 else nextCodepointEnd(after, 0);
    const cursor_cell = if (cell_end == 0) cursor_blank else after[0..cell_end];
    const cursor = try renderCursorCell(allocator, cursor_cell);
    defer allocator.free(cursor);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ before, cursor, after[cell_end..] });
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
    if (tui_text.visibleWidth(text) <= width) return allocator.dupe(u8, text);
    var start = text.len;
    var visible: usize = 0;
    while (start > 0 and visible < width -| 1) {
        const cp_start = previousCodepointStart(text, start);
        const cp = text[cp_start..start];
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

fn renderHint(allocator: std.mem.Allocator, state: *const tui_state.AppState, streaming_shortcuts_supported: bool, max_width: usize) ![]const u8 {
    const text = state.composer.text();
    if (state.status.streaming) {
        if (streaming_shortcuts_supported) {
            const queued = state.queue.total();
            const hint = if (queued > 0)
                try std.fmt.allocPrint(allocator, "Enter steer • Alt+Enter queue follow-up • queued {d}", .{queued})
            else
                try allocator.dupe(u8, "Enter steer • Alt+Enter queue follow-up");
            defer allocator.free(hint);
            const truncated = try tui_text.truncateToWidth(allocator, hint, max_width);
            defer allocator.free(truncated);
            return tui_theme.muted().render(allocator, truncated);
        }
        const truncated = try tui_text.truncateToWidth(allocator, "steering not available in remote mode", max_width);
        defer allocator.free(truncated);
        return tui_theme.muted().render(allocator, truncated);
    }
    if (std.mem.startsWith(u8, text, "!")) {
        const truncated = try tui_text.truncateToWidth(allocator, "shell mode • Enter runs command through agent", max_width);
        defer allocator.free(truncated);
        return tui_theme.muted().render(allocator, truncated);
    }
    if (std.mem.startsWith(u8, text, "@")) {
        const truncated = try tui_text.truncateToWidth(allocator, "file picker • type path or query", max_width);
        defer allocator.free(truncated);
        return tui_theme.muted().render(allocator, truncated);
    }
    if (state.composer.history.items.len > 0) {
        const hint = try std.fmt.allocPrint(allocator, "↑/↓ history • {d} saved • Shift+Enter newline • Shift+Tab thinking level", .{state.composer.history.items.len});
        defer allocator.free(hint);
        const truncated = try tui_text.truncateToWidth(allocator, hint, max_width);
        defer allocator.free(truncated);
        return tui_theme.muted().render(allocator, truncated);
    }
    const truncated = try tui_text.truncateToWidth(allocator, "Enter submit • Shift+Enter newline • Shift+Tab thinking level • Ctrl+C quit", max_width);
    defer allocator.free(truncated);
    return tui_theme.muted().render(allocator, truncated);
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
    try std.testing.expect(std.mem.indexOf(u8, placeholder, "Shift+Tab") != null);
    try std.testing.expect(std.mem.indexOf(u8, placeholder, "Ctrl+R") == null);
    try std.testing.expect(std.mem.indexOf(u8, placeholder, cursor_blank) != null);
    try std.testing.expect(std.mem.indexOf(u8, placeholder, "|") == null);
    try std.testing.expect(std.mem.indexOf(u8, placeholder, "\u{2588}") == null);
    try std.testing.expect(std.mem.indexOf(u8, placeholder, "╭") != null);
    try std.testing.expect((std.mem.indexOf(u8, placeholder, "\x1b[7m") orelse return error.MissingCursor) < (std.mem.indexOf(u8, placeholder, "Ask Makai") orelse return error.MissingPlaceholder));

    try state.composer.buffer.appendSlice(std.testing.allocator, "hello world");
    state.composer.cursor = state.composer.buffer.items.len;
    const text = try render(std.testing.allocator, &state, .{ .width = 30 });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, tui_theme.glyph.prompt) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{2588}") == null);
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
}

test "composer renders queued hint while streaming shortcuts are supported" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.status.streaming = true;
    state.queue.follow_up = 2;

    const text = try render(std.testing.allocator, &state, .{ .width = 80 });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Alt+Enter") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "queued 2") != null);
}

test "composer shows unavailable steering hint when streaming shortcuts are unsupported" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.status.streaming = true;
    state.queue.follow_up = 2;

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .streaming_shortcuts_supported = false });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Alt+Enter") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "queued 2") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "steering not available in remote mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Enter submit") == null);
}

test "composer renders shell and file hints" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.composer.buffer.appendSlice(std.testing.allocator, "!ls");
    const shell = try render(std.testing.allocator, &state, .{ .width = 50 });
    defer std.testing.allocator.free(shell);
    try std.testing.expect(std.mem.indexOf(u8, shell, "shell mode") != null);

    state.composer.buffer.clearRetainingCapacity();
    try state.composer.buffer.appendSlice(std.testing.allocator, "@src");
    const file = try render(std.testing.allocator, &state, .{ .width = 50 });
    defer std.testing.allocator.free(file);
    try std.testing.expect(std.mem.indexOf(u8, file, "file picker") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, input, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, input, "b") != null);
    try std.testing.expect(std.mem.indexOf(u8, input, "c") != null);
    try std.testing.expect(std.mem.indexOf(u8, input, "\u{2588}") == null);
}
