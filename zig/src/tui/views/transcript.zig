const std = @import("std");
const zz = @import("zigzag");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");

const AppState = tui_state.AppState;
const TranscriptKind = tui_state.TranscriptKind;
const TranscriptEntry = tui_state.TranscriptEntry;

pub const Options = struct {
    width: usize = 80,
    height: usize = 20,
};

pub fn render(allocator: std.mem.Allocator, state: *const AppState, options: Options) ![]const u8 {
    if (options.height == 0) return allocator.dupe(u8, "");

    var visible_entries = std.ArrayList(*const TranscriptEntry).empty;
    defer visible_entries.deinit(allocator);
    for (state.transcript.items) |*entry| {
        if (entry.kind == .thinking and !state.show_thinking) continue;
        try visible_entries.append(allocator, entry);
    }

    if (visible_entries.items.len == 0) {
        var ready_text: []const u8 = "Makai ready. Type message, /quit exits.";
        if (state.transcript.items.len > 0 and !state.show_thinking) ready_text = "Thinking hidden. Ctrl+R shows reasoning.";
        return tui_theme.muted().render(allocator, ready_text);
    }

    var all_rows: std.Io.Writer.Allocating = .init(allocator);
    defer all_rows.deinit();
    const all_writer = &all_rows.writer;
    for (visible_entries.items, 0..) |entry, i| {
        if (i > 0) try all_writer.writeByte('\n');
        const row = try renderEntry(allocator, entry, options.width);
        defer allocator.free(row);
        try all_writer.writeAll(row);
    }

    const all_text = all_rows.written();
    const total_lines = tui_text.lineCount(all_text);
    // Reserve one line for scroll indicator when scrolled; use full height otherwise.
    const view_height = if (state.transcript_scroll > 0 and total_lines > options.height)
        options.height -| 1
    else
        options.height;
    const windowed = try lineWindow(allocator, all_text, view_height, state.transcript_scroll);
    defer allocator.free(windowed);

    if (state.transcript_scroll == 0 or total_lines <= options.height) {
        return allocator.dupe(u8, windowed);
    }

    // Prepend a scroll indicator line: "↑ SCROLL N%"
    const pct = scrollPercent(total_lines, view_height, state.transcript_scroll);
    const raw_indicator = try std.fmt.allocPrint(allocator, "\u{2191} SCROLL {d}%", .{pct});
    defer allocator.free(raw_indicator);
    const indicator = try tui_theme.muted().render(allocator, raw_indicator);
    defer allocator.free(indicator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(indicator);
    try writer.writeByte('\n');
    try writer.writeAll(windowed);
    return out.toOwnedSlice();
}

/// Return scroll percentage: 100 = at top, 0 = at bottom.
fn scrollPercent(total_lines: usize, view_height: usize, scroll: usize) usize {
    if (total_lines <= view_height) return 0;
    const max_scroll = total_lines - view_height;
    const clamped = @min(scroll, max_scroll);
    return clamped * 100 / max_scroll;
}

fn renderEntry(allocator: std.mem.Allocator, entry: *const TranscriptEntry, width: usize) ![]u8 {
    const raw_label = label(entry.kind);
    const styled_label = try tui_theme.role(entry.kind).render(allocator, raw_label);
    defer allocator.free(styled_label);
    const label_width = tui_text.visibleWidth(raw_label);
    const body_width = width -| label_width -| 1;
    const rendered_body = try renderEntryText(allocator, entry.kind, entry.text.items, @max(body_width, 8));
    defer allocator.free(rendered_body);
    return indentBody(allocator, styled_label, label_width, rendered_body);
}

fn renderEntryText(allocator: std.mem.Allocator, kind: TranscriptKind, text: []const u8, width: usize) ![]const u8 {
    if (kind == .assistant) {
        var markdown = zz.Markdown.init();
        markdown.width = @intCast(@min(width, std.math.maxInt(u16)));
        return markdown.render(allocator, text);
    }
    const styled = switch (kind) {
        .@"error" => try tui_theme.errorText().render(allocator, text),
        .thinking => try tui_theme.role(.thinking).render(allocator, text),
        .system => try tui_theme.muted().render(allocator, text),
        else => try allocator.dupe(u8, text),
    };
    defer allocator.free(styled);
    return tui_text.truncateLinesToWidth(allocator, styled, @max(width, 1), std.math.maxInt(usize));
}

fn indentBody(allocator: std.mem.Allocator, styled_label: []const u8, label_width: usize, body: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(styled_label);
    try writer.writeByte(' ');
    const indent_width = label_width + 1;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) {
            try writer.writeByte('\n');
            try writeSpaces(writer, indent_width);
        }
        first = false;
        try writer.writeAll(line);
    }
    return out.toOwnedSlice();
}

fn lineWindow(allocator: std.mem.Allocator, text: []const u8, height: usize, scroll: usize) ![]u8 {
    const total = tui_text.lineCount(text);
    if (total <= height and scroll == 0) return allocator.dupe(u8, text);
    const visible = @min(height, total);
    const max_start = total - visible;
    const start_line = max_start -| scroll;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_index: usize = 0;
    var written: usize = 0;
    while (lines.next()) |line| : (line_index += 1) {
        if (line_index < start_line) continue;
        if (written >= visible) break;
        if (written > 0) try writer.writeByte('\n');
        try writer.writeAll(line);
        written += 1;
    }
    return out.toOwnedSlice();
}

fn writeSpaces(writer: *std.Io.Writer, count: usize) !void {
    for (0..count) |_| try writer.writeByte(' ');
}

fn label(kind: TranscriptKind) []const u8 {
    return switch (kind) {
        .user => "You:",
        .assistant => "AI:",
        .thinking => "Think:",
        .tool => "Tool:",
        .system => "Sys:",
        .@"error" => "Err:",
    };
}

test "transcript renders labels" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendUserMessage("hello");
    try state.appendTranscript(.assistant, "world");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "You:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "AI:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "world") != null);
}

test "transcript preserves multiline entries" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "alpha\nbeta");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "alpha\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "beta") != null);
}

test "transcript hides thinking when toggled off" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.thinking, "secret plan");
    try state.appendTranscript(.assistant, "visible answer");
    state.show_thinking = false;

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "secret plan") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "visible answer") != null);
}

test "transcript renders markdown syntax" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "# Heading\n- item");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Heading") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "item") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "# Heading") == null);
}

test "transcript keeps assistant code indentation" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "```zig\n    const x = 1;\n```\n");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "    const x") != null);
}

test "transcript caps rendered lines to height" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "one\ntwo\nthree\nfour");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 2 });
    defer std.testing.allocator.free(text);

    try std.testing.expectEqual(@as(usize, 2), tui_text.lineCount(text));
    try std.testing.expect(std.mem.indexOf(u8, text, "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "four") != null);
}

test "transcript preserves non-assistant whitespace" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.tool, "  alpha   beta\n    gamma");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "  alpha   beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    gamma") != null);
}

test "transcript shows scroll indicator when scrolled up" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    // Add more lines than fit in the viewport
    for (0..20) |i| {
        const msg = try std.fmt.allocPrint(std.testing.allocator, "line {d}", .{i});
        defer std.testing.allocator.free(msg);
        try state.appendTranscript(.assistant, msg);
    }
    state.transcript_scroll = 5; // scrolled up

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 5 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "SCROLL") != null);
}

test "transcript hides scroll indicator when at bottom" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    for (0..10) |i| {
        const msg = try std.fmt.allocPrint(std.testing.allocator, "line {d}", .{i});
        defer std.testing.allocator.free(msg);
        try state.appendTranscript(.assistant, msg);
    }
    state.transcript_scroll = 0; // at bottom

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 5 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "SCROLL") == null);
}
