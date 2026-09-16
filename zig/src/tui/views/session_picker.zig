const std = @import("std");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");

pub const Options = struct {
    width: usize = 80,
    height: usize = 12,
    offset: usize = 0,
};

const marker_width: usize = 2;

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    const inner_width = options.width -| 4;

    if (state.sessions.items.len == 0) {
        const none = try tui_theme.muted().render(allocator, "  no saved sessions");
        defer allocator.free(none);
        try writer.writeAll(none);
    } else {
        const end = @min(state.sessions.items.len, options.offset + @max(options.height, 1));
        var i = options.offset;
        while (i < end) : (i += 1) {
            const session = &state.sessions.items[i];
            if (i > options.offset) try writer.writeByte('\n');
            const row = try renderRow(allocator, session, i == state.session_index, inner_width);
            defer allocator.free(row);
            try writer.writeAll(row);
        }
        if (state.sessions.items.len > end - options.offset) {
            const position = try std.fmt.allocPrint(allocator, "{d}–{d} of {d}", .{ options.offset + 1, end, state.sessions.items.len });
            defer allocator.free(position);
            const styled = try tui_theme.dim().render(allocator, position);
            defer allocator.free(styled);
            try writer.writeByte('\n');
            for (0..inner_width -| tui_text.visibleWidth(position)) |_| try writer.writeByte(' ');
            try writer.writeAll(styled);
        }
    }
    const footer = try tui_theme.keyHint().render(allocator, tui_theme.key.up_down ++ " move · " ++ tui_theme.key.enter ++ " resume · esc close");
    defer allocator.free(footer);
    try writer.writeByte('\n');
    try writer.writeAll(footer);

    const body = try out.toOwnedSlice();
    defer allocator.free(body);
    return tui_theme.titledPanel(allocator, body, .{ .title = "Sessions", .width = options.width, .border = tui_theme.palette.accent_dim });
}

fn renderRow(allocator: std.mem.Allocator, session: *const tui_state.SessionEntry, selected: bool, inner_width: usize) ![]const u8 {
    var plain: std.Io.Writer.Allocating = .init(allocator);
    defer plain.deinit();
    const pw = &plain.writer;
    try pw.writeAll(if (selected) tui_theme.glyph.select ++ " " else "  ");
    const label = try tui_text.truncateLineToWidth(allocator, session.label, inner_width -| marker_width);
    defer allocator.free(label);
    try pw.writeAll(label);
    var used = marker_width + tui_text.visibleWidth(label);
    const id_width = tui_text.visibleWidth(session.id);
    if (used + 2 + id_width <= inner_width) {
        for (0..inner_width - used - id_width) |_| try pw.writeByte(' ');
        try pw.writeAll(session.id);
        used = inner_width;
    }
    for (0..inner_width -| used) |_| try pw.writeByte(' ');

    const text = plain.written();
    if (selected) return try tui_theme.selectionRow().render(allocator, text);
    const label_end = @min(text.len, marker_width + label.len);
    const head = try tui_theme.soft().render(allocator, text[0..label_end]);
    defer allocator.free(head);
    const tail = try tui_theme.dim().render(allocator, text[label_end..]);
    defer allocator.free(tail);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ head, tail });
}

test "session picker renders selected session" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.addSession("s1", "First");
    try state.addSession("s2", "Second");
    state.session_index = 1;

    const text = try render(std.testing.allocator, &state, .{ .height = 4 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "  First") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "s1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, tui_theme.glyph.select ++ " Second") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Sessions") != null);
    try std.testing.expect(tui_text.visibleWidth(text) > 0);
}

test "session picker renders from offset" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.addSession("s1", "First");
    try state.addSession("s2", "Second");
    try state.addSession("s3", "Third");
    state.session_index = 2;
    state.session_scroll = 1;

    const text = try render(std.testing.allocator, &state, .{ .height = 2, .offset = state.session_scroll });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "First") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Second") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, tui_theme.glyph.select ++ " Third") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2–3 of 3") != null);
}

test "session picker renders empty state" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    const text = try render(std.testing.allocator, &state, .{ .height = 4 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "no saved sessions") != null);
}
