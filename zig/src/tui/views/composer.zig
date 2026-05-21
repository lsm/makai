const std = @import("std");
const tui_state = @import("tui_state");

pub const Options = struct {
    width: usize = 80,
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    const text = state.composer.text();
    try writer.writeAll("> ");
    if (text.len == 0) {
        try writer.writeAll("Ask Makai…");
    } else {
        const max = options.width -| 2;
        try writer.writeAll(text[0..@min(max, text.len)]);
        if (text.len > max) try writer.writeAll("…");
    }
    try writer.writeAll("\nEnter submit • Shift+Enter newline • Ctrl+C quit • /quit quit");
    return out.toOwnedSlice();
}

test "composer renders placeholder and text" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    const placeholder = try render(std.testing.allocator, &state, .{ .width = 20 });
    defer std.testing.allocator.free(placeholder);
    try std.testing.expect(std.mem.indexOf(u8, placeholder, "Ask Makai") != null);

    try state.composer.buffer.appendSlice(std.testing.allocator, "hello world");
    const text = try render(std.testing.allocator, &state, .{ .width = 20 });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "> hello world") != null);
}
