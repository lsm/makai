const std = @import("std");
const zz = @import("zigzag");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");
const tui_render = @import("tui_render");

pub const Options = struct {
    width: usize = 80,
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]const u8 {
    const inner_width = options.width -| 4;
    const input = try renderInput(allocator, state, inner_width);
    defer allocator.free(input);
    const help = try tui_theme.muted().render(allocator, "Enter submit • Shift+Enter newline • Ctrl+C quit • /quit quit");
    defer allocator.free(help);
    const body = try tui_render.joinVertical(allocator, &.{ input, help });
    defer allocator.free(body);
    return tui_theme.panel().width(@intCast(@min(options.width, std.math.maxInt(u16)))).render(allocator, body);
}

fn renderInput(allocator: std.mem.Allocator, state: *const tui_state.AppState, width: usize) ![]u8 {
    const text = state.composer.text();
    const prompt = try tui_theme.composerPrompt().render(allocator, "> ");
    defer allocator.free(prompt);
    const remaining = width -| tui_text.visibleWidth(prompt);
    const content = if (text.len == 0)
        try tui_theme.composerPlaceholder().render(allocator, "Ask Makai…")
    else
        try tui_text.truncateToWidth(allocator, text, remaining);
    defer allocator.free(content);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prompt, content });
}

test "composer renders placeholder and text" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    const placeholder = try render(std.testing.allocator, &state, .{ .width = 30 });
    defer std.testing.allocator.free(placeholder);
    try std.testing.expect(std.mem.indexOf(u8, placeholder, "Ask Makai") != null);
    try std.testing.expect(std.mem.indexOf(u8, placeholder, "╭") != null);

    try state.composer.buffer.appendSlice(std.testing.allocator, "hello world");
    const text = try render(std.testing.allocator, &state, .{ .width = 30 });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, ">") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hello world") != null);
}
