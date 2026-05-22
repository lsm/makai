const std = @import("std");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");

pub const Options = struct {
    height: usize = 12,
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    const title = try tui_theme.panelTitle().render(allocator, "Sessions");
    defer allocator.free(title);
    try writer.writeAll(title);
    if (state.sessions.items.len == 0) {
        const none = try tui_theme.muted().render(allocator, "  no saved sessions");
        defer allocator.free(none);
        try writer.writeByte('\n');
        try writer.writeAll(none);
        const body = try out.toOwnedSlice();
        defer allocator.free(body);
        return tui_theme.panel().render(allocator, body);
    }
    for (state.sessions.items, 0..) |session, i| {
        if (i >= options.height) break;
        try writer.writeByte('\n');
        const marker = if (i == state.session_index) ">" else " ";
        const row = try std.fmt.allocPrint(allocator, "{s} {s} ({s})", .{ marker, session.label, session.id });
        defer allocator.free(row);
        const styled = if (i == state.session_index) try tui_theme.successText().render(allocator, row) else try tui_theme.muted().render(allocator, row);
        defer allocator.free(styled);
        try writer.writeAll(styled);
    }
    const body = try out.toOwnedSlice();
    defer allocator.free(body);
    return tui_theme.panel().render(allocator, body);
}

test "session picker renders selected session" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.addSession("s1", "First");
    try state.addSession("s2", "Second");
    state.session_index = 1;

    const text = try render(std.testing.allocator, &state, .{ .height = 4 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "First (s1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "> Second (s2)") != null);
    try std.testing.expect(tui_text.visibleWidth(text) > 0);
}
