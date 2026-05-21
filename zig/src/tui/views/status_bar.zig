const std = @import("std");
const tui_state = @import("tui_state");

pub const Options = struct {
    width: usize = 80,
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    const model = if (state.status.model.len > 0) state.status.model else "no-model";
    const provider = if (state.status.provider.len > 0) state.status.provider else "no-provider";
    const session = if (state.status.session_id.len > 0) state.status.session_id else "local";
    const stream = if (state.status.streaming) "streaming" else "idle";
    try writer.print(" {s}/{s} • session:{s} • turns:{d} • {s}", .{ provider, model, session, state.status.turn_count, stream });
    if (state.status.context_limit > 0) {
        try writer.print(" • ctx:{d}/{d}", .{ state.status.context_used, state.status.context_limit });
    }
    if (state.status.last_error.len > 0) {
        try writer.print(" • error:{s}", .{state.status.last_error});
    }
    const items = out.written();
    if (items.len > options.width) {
        const clipped = try allocator.dupe(u8, items[0..options.width]);
        out.deinit();
        return clipped;
    }
    return out.toOwnedSlice();
}

test "status bar renders model and clips width" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.status.setModel(std.testing.allocator, "claude", "anthropic");
    state.status.streaming = true;

    const text = try render(std.testing.allocator, &state, .{ .width = 24 });
    defer std.testing.allocator.free(text);

    try std.testing.expectEqual(@as(usize, 24), text.len);
    try std.testing.expect(std.mem.indexOf(u8, text, "anthropic") != null);
}
