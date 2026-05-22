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
    var visible_entries = std.ArrayList(*const TranscriptEntry).empty;
    defer visible_entries.deinit(allocator);
    for (state.transcript.items) |*entry| {
        if (entry.kind == .thinking and !state.show_thinking) continue;
        try visible_entries.append(allocator, entry);
    }

    const total = visible_entries.items.len;
    if (total == 0) {
        var ready_text: []const u8 = "Makai ready. Type message, /quit exits.";
        if (state.transcript.items.len > 0 and !state.show_thinking) ready_text = "Thinking hidden. Ctrl+R shows reasoning.";
        return tui_theme.muted().render(allocator, ready_text);
    }

    const visible = @min(options.height, total);
    const max_start = total - visible;
    const start = max_start -| state.transcript_scroll;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    for (visible_entries.items[start..], 0..) |entry, i| {
        if (i >= visible) break;
        if (i > 0) try writer.writeByte('\n');
        const row = try renderEntry(allocator, entry, options.width);
        defer allocator.free(row);
        try writer.writeAll(row);
    }
    return out.toOwnedSlice();
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
    return tui_text.wrapTextWithAnsi(allocator, styled, @max(width, 1));
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
