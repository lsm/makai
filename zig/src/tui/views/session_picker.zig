const std = @import("std");
const tui_state = @import("tui_state");

pub const Options = struct {
    height: usize = 12,
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    try writer.writeAll("Sessions\n");
    if (state.sessions.items.len == 0) {
        try writer.writeAll("  no saved sessions");
        return out.toOwnedSlice();
    }
    for (state.sessions.items, 0..) |session, i| {
        if (i >= options.height) break;
        try writer.print("{s} {s} ({s})", .{ if (i == state.session_index) ">" else " ", session.label, session.id });
        if (i + 1 < state.sessions.items.len and i + 1 < options.height) try writer.writeByte('\n');
    }
    return out.toOwnedSlice();
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
}
