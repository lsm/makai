const std = @import("std");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");
const tui_render = @import("tui_render");

pub const Options = struct {
    width: usize = 80,
    streaming_shortcuts_supported: bool = true,
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]const u8 {
    const inner_width = options.width -| 4;
    const input = try renderInput(allocator, state, inner_width);
    defer allocator.free(input);
    const hint = try renderHint(allocator, state, options.streaming_shortcuts_supported);
    defer allocator.free(hint);
    const body = try tui_render.joinVertical(allocator, &.{ input, hint });
    defer allocator.free(body);
    return tui_theme.panel().width(@intCast(@min(options.width, std.math.maxInt(u16)))).render(allocator, body);
}

fn renderInput(allocator: std.mem.Allocator, state: *const tui_state.AppState, width: usize) ![]u8 {
    const prompt = try tui_theme.composerPrompt().render(allocator, promptFor(state));
    defer allocator.free(prompt);
    const content_width = width -| tui_text.visibleWidth(promptFor(state));
    if (state.composer.text().len == 0) {
        const placeholder = try tui_text.truncateLineToWidth(allocator, "Ask Makai…", content_width);
        defer allocator.free(placeholder);
        const content = try tui_theme.composerPlaceholder().render(allocator, placeholder);
        defer allocator.free(content);
        return prefixFirstLine(allocator, prompt, content);
    }
    const content = try tui_text.truncateLinesToWidth(allocator, state.composer.text(), content_width, 4);
    defer allocator.free(content);
    return prefixFirstLine(allocator, prompt, content);
}

fn renderHint(allocator: std.mem.Allocator, state: *const tui_state.AppState, streaming_shortcuts_supported: bool) ![]const u8 {
    const text = state.composer.text();
    if (state.status.streaming and streaming_shortcuts_supported) {
        const queued = state.queue.total();
        const hint = if (queued > 0)
            try std.fmt.allocPrint(allocator, "Enter steer • Alt+Enter queue follow-up • queued {d}", .{queued})
        else
            try allocator.dupe(u8, "Enter steer • Alt+Enter queue follow-up");
        defer allocator.free(hint);
        return tui_theme.muted().render(allocator, hint);
    }
    if (std.mem.startsWith(u8, text, "!"))
        return tui_theme.muted().render(allocator, "shell mode • Enter runs command through agent");
    if (std.mem.startsWith(u8, text, "@"))
        return tui_theme.muted().render(allocator, "file picker • type path or query");
    if (state.composer.history.items.len > 0) {
        const hint = try std.fmt.allocPrint(allocator, "↑/↓ history • {d} saved • Shift+Enter newline • Ctrl+R thinking", .{state.composer.history.items.len});
        defer allocator.free(hint);
        return tui_theme.muted().render(allocator, hint);
    }
    return tui_theme.muted().render(allocator, "Enter submit • Shift+Enter newline • Ctrl+R thinking • Ctrl+C quit");
}

fn promptFor(state: *const tui_state.AppState) []const u8 {
    const text = state.composer.text();
    if (std.mem.startsWith(u8, text, "!")) return "! ";
    if (std.mem.startsWith(u8, text, "@")) return "@ ";
    return "> ";
}

fn prefixFirstLine(allocator: std.mem.Allocator, prompt: []const u8, content: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(prompt);
    var lines = std.mem.splitScalar(u8, content, '\n');
    if (lines.next()) |first| try writer.writeAll(first);
    while (lines.next()) |line| {
        try writer.writeByte('\n');
        try writer.writeAll("  ");
        try writer.writeAll(line);
    }
    return out.toOwnedSlice();
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

test "composer renders multiline draft content" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.composer.buffer.appendSlice(std.testing.allocator, "first line\nsecond line");

    const text = try render(std.testing.allocator, &state, .{ .width = 40 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "first line") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "second line") != null);
}

test "composer renders queued hint while streaming shortcuts are supported" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.status.streaming = true;
    state.queue.follow_up = 2;

    const text = try render(std.testing.allocator, &state, .{ .width = 80 });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Alt+Enter") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "queued 2") != null);
}

test "composer hides streaming shortcut hint when unsupported" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.status.streaming = true;
    state.queue.follow_up = 2;

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .streaming_shortcuts_supported = false });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Alt+Enter") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "queued 2") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Enter submit") != null);
}

test "composer renders shell and file hints" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.composer.buffer.appendSlice(std.testing.allocator, "!ls");
    const shell = try render(std.testing.allocator, &state, .{ .width = 50 });
    defer std.testing.allocator.free(shell);
    try std.testing.expect(std.mem.indexOf(u8, shell, "shell mode") != null);

    state.composer.buffer.clearRetainingCapacity();
    try state.composer.buffer.appendSlice(std.testing.allocator, "@src");
    const file = try render(std.testing.allocator, &state, .{ .width = 50 });
    defer std.testing.allocator.free(file);
    try std.testing.expect(std.mem.indexOf(u8, file, "file picker") != null);
}

test "composer accounts for prompt width when truncating text" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.composer.buffer.appendSlice(std.testing.allocator, "1234567890");

    const input = try renderInput(std.testing.allocator, &state, 8);
    defer std.testing.allocator.free(input);

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(tui_text.visibleWidth(line) <= 8);
    }
}
