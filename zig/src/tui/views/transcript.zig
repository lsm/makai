const std = @import("std");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");

const AppState = tui_state.AppState;
const TranscriptKind = tui_state.TranscriptKind;

pub const Options = struct {
    width: usize = 80,
    height: usize = 20,
};

pub fn render(allocator: std.mem.Allocator, state: *const AppState, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;

    const total = state.transcript.items.len;
    const visible = @min(options.height, total);
    const max_start = total - visible;
    const start = max_start -| state.transcript_scroll;

    if (total == 0) {
        const ready = try tui_theme.muted().render(allocator, "Makai ready. Type message, /quit exits.");
        defer allocator.free(ready);
        try writer.writeAll(ready);
        return out.toOwnedSlice();
    }

    for (state.transcript.items[start..], 0..) |entry, i| {
        if (i >= visible) break;
        if (i > 0) try writer.writeByte('\n');
        const raw_label = label(entry.kind);
        const styled_label = try tui_theme.role(entry.kind).render(allocator, raw_label);
        defer allocator.free(styled_label);
        try writer.writeAll(styled_label);
        try writer.writeByte(' ');
        const max_text_width = options.width -| tui_text.visibleWidth(raw_label) -| 1;
        const rendered = try renderEntryText(allocator, entry.kind, entry.text.items, max_text_width);
        defer allocator.free(rendered);
        try writer.writeAll(rendered);
    }

    return out.toOwnedSlice();
}

fn renderEntryText(allocator: std.mem.Allocator, kind: TranscriptKind, text: []const u8, width: usize) ![]const u8 {
    const clipped = try tui_text.truncateToWidth(allocator, text, width);
    errdefer allocator.free(clipped);
    if (kind == .@"error") {
        const styled = try tui_theme.errorText().render(allocator, clipped);
        allocator.free(clipped);
        return styled;
    }
    return clipped;
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
