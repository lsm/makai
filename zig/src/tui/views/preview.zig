const std = @import("std");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");

pub const Options = struct {
    width: usize = 80,
    height: usize = 20,
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    if (state.preview.content.len == 0) {
        const empty = try tui_theme.muted().render(allocator, "No preview");
        defer allocator.free(empty);
        try writer.writeAll(empty);
        const body = try out.toOwnedSlice();
        defer allocator.free(body);
        return tui_theme.panel().width(@intCast(@min(options.width -| 4, std.math.maxInt(u16)))).render(allocator, body);
    }
    const title = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ kindText(state.preview.kind), state.preview.title });
    defer allocator.free(title);
    const styled_title = try tui_theme.panelTitle().render(allocator, title);
    defer allocator.free(styled_title);
    try writer.writeAll(styled_title);
    var row: usize = 1;
    var skipped: usize = 0;
    var lines = std.mem.splitScalar(u8, state.preview.content, '\n');
    while (lines.next()) |line| {
        if (skipped < state.preview.scroll) {
            skipped += 1;
            continue;
        }
        if (row >= options.height) break;
        try writer.writeByte('\n');
        const clipped = try tui_text.truncateToWidth(allocator, line, options.width -| 4);
        defer allocator.free(clipped);
        const styled = try tui_theme.diffLine(line).render(allocator, clipped);
        defer allocator.free(styled);
        try writer.writeAll(styled);
        row += 1;
    }
    const body = try out.toOwnedSlice();
    defer allocator.free(body);
    return tui_theme.panel().width(@intCast(@min(options.width -| 4, std.math.maxInt(u16)))).render(allocator, body);
}

fn kindText(kind: tui_state.PreviewKind) []const u8 {
    return switch (kind) {
        .diff => "Diff",
        .file => "File",
        .artifact => "Artifact",
    };
}

test "preview renders title and content" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPreview(.diff, "patch.diff", "+hello\n-world");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 4 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Diff: patch.diff") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+hello") != null);
}

test "preview renders hashline diff anchors" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPreview(.diff, "src/main.zig", "hashline edit preview\nrange: 2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa..2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n- 2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|old\n+ 2|new");

    const text = try render(std.testing.allocator, &state, .{ .width = 120, .height = 6 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Diff: src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+ 2|new") != null);
}

test "preview preserves adjacent diff pair text with styling" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPreview(.diff, "patch.diff", "- value = old\n+ value = new");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 4 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "- value = old") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+ value = new") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[") != null);
}
