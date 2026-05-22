const std = @import("std");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");

pub const Options = struct {
    width: usize = 80,
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    const model = if (state.status.model.len > 0) state.status.model else "no-model";
    const provider = if (state.status.provider.len > 0) state.status.provider else "no-provider";
    const session = if (state.status.session_id.len > 0) state.status.session_id else "local";
    const stream = if (state.status.streaming) "streaming" else "idle";

    try writeOwnedSegment(writer, allocator, "model", try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider, model }));
    try writer.writeAll(" • ");
    try writeSegment(writer, allocator, "session", session);
    try writer.writeAll(" • ");
    try writeOwnedSegment(writer, allocator, "turns", try std.fmt.allocPrint(allocator, "{d}", .{state.status.turn_count}));
    try writer.writeAll(" • ");
    const stream_style = if (state.status.streaming) tui_theme.successText() else tui_theme.muted();
    const styled_stream = try stream_style.render(allocator, stream);
    defer allocator.free(styled_stream);
    try writer.writeAll(styled_stream);

    if (state.status.context_limit > 0) {
        const pct = (state.status.context_used * 100) / state.status.context_limit;
        try writer.writeAll(" • ");
        const ctx = try std.fmt.allocPrint(allocator, "{d}% {d}/{d}", .{ pct, state.status.context_used, state.status.context_limit });
        try writeOwnedSegment(writer, allocator, "ctx", ctx);
    } else if (state.status.context_used > 0) {
        try writer.writeAll(" • ");
        const ctx = try std.fmt.allocPrint(allocator, "{d}tok", .{state.status.context_used});
        try writeOwnedSegment(writer, allocator, "ctx", ctx);
    }
    if (state.status.last_error.len > 0) {
        try writer.writeAll(" • ");
        const err = try tui_theme.errorText().render(allocator, state.status.last_error);
        defer allocator.free(err);
        try writer.writeAll(err);
    }
    const items = out.written();
    if (tui_text.visibleWidth(items) > options.width) {
        const clipped = try tui_text.truncateToWidth(allocator, items, options.width);
        out.deinit();
        return clipped;
    }
    return out.toOwnedSlice();
}

fn writeSegment(writer: *std.Io.Writer, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const styled_key = try tui_theme.statusKey().render(allocator, key);
    defer allocator.free(styled_key);
    const styled_value = try tui_theme.statusSegment().render(allocator, value);
    defer allocator.free(styled_value);
    try writer.print("{s}:{s}", .{ styled_key, styled_value });
}

fn writeOwnedSegment(writer: *std.Io.Writer, allocator: std.mem.Allocator, key: []const u8, value: []u8) !void {
    defer allocator.free(value);
    try writeSegment(writer, allocator, key, value);
}

test "status bar renders model and clips width" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.status.setModel(std.testing.allocator, "claude", "anthropic");
    state.status.streaming = true;

    const text = try render(std.testing.allocator, &state, .{ .width = 24 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(tui_text.visibleWidth(text) <= 24);
    try std.testing.expect(std.mem.indexOf(u8, text, "anthropic") != null);
}
