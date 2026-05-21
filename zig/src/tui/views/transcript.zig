const std = @import("std");
const tui_state = @import("tui_state");

const AppState = tui_state.AppState;
const TranscriptKind = tui_state.TranscriptKind;

pub const Options = struct {
    width: usize = 80,
    height: usize = 20,
};

pub fn render(allocator: std.mem.Allocator, state: *const AppState, options: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;

    const total = state.transcript.items.len;
    const visible = @min(options.height, total);
    const max_start = total - visible;
    const start = max_start -| state.transcript_scroll;

    if (total == 0) {
        try writer.writeAll("Makai ready. Type message, /quit exits.");
        return out.toOwnedSlice();
    }

    for (state.transcript.items[start..], 0..) |entry, i| {
        if (i >= visible) break;
        if (i > 0) try writer.writeByte('\n');
        try writer.print("{s} ", .{label(entry.kind)});
        try writeClipped(writer, entry.text.items, options.width -| label(entry.kind).len -| 1);
        if (entry.kind == .tool and std.mem.indexOf(u8, entry.text.items, "[truncated") != null) try writer.writeAll(" (show full)");
    }

    return out.toOwnedSlice();
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

fn writeClipped(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    if (width == 0) return;
    var line_len: usize = 0;
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        if (line_len > 0) try writer.writeAll(" / ");
        const take = @min(width, line.len);
        try writer.writeAll(line[0..take]);
        line_len += take;
        if (take < line.len) {
            try writer.writeAll("…");
            break;
        }
    }
}

test "transcript renders labels" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendUserMessage("hello");
    try state.appendTranscript(.assistant, "world");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "You: hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "AI: world") != null);
}
