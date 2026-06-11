const std = @import("std");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");
const tui_render = @import("tui_render");

pub const Options = struct {
    width: usize = 80,
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]const u8 {
    if (state.approval.status != .pending) return allocator.dupe(u8, "");
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    defer for (parts.items) |part| allocator.free(part);

    try parts.append(allocator, try tui_theme.warningText().render(allocator, tui_theme.glyph.tool ++ " Approval required"));
    try parts.append(allocator, try std.fmt.allocPrint(allocator, "Tool: {s}", .{state.approval.tool_name}));
    const args = try tui_text.truncateToWidth(allocator, state.approval.args_json, options.width -| 10);
    defer allocator.free(args);
    try parts.append(allocator, try std.fmt.allocPrint(allocator, "Args: {s}", .{args}));
    if (state.approval.scope_hint.len > 0) {
        const scope = try tui_text.truncateToWidth(allocator, state.approval.scope_hint, options.width -| 18);
        defer allocator.free(scope);
        try parts.append(allocator, try std.fmt.allocPrint(allocator, "Always scope: {s}", .{scope}));
    }
    if (std.mem.eql(u8, state.approval.tool_name, "hashline_edit") and state.preview.content.len > 0) {
        try parts.append(allocator, try tui_theme.panelTitle().render(allocator, "Preview:"));
        var rows: usize = 0;
        var lines = std.mem.splitScalar(u8, state.preview.content, '\n');
        while (lines.next()) |line| {
            if (rows >= 8) break;
            const clipped = try tui_text.truncateToWidth(allocator, line, options.width -| 4);
            defer allocator.free(clipped);
            try parts.append(allocator, try tui_theme.diffLine(line).render(allocator, clipped));
            rows += 1;
        }
    }
    try parts.append(allocator, try tui_theme.muted().render(allocator, "(y) allow once  (a) allow always  (n) deny  Esc abort"));
    const body = try tui_render.joinVertical(allocator, parts.items);
    defer allocator.free(body);
    return tui_theme.panel().borderForeground(tui_theme.palette.warning).width(@intCast(@min(options.width -| 4, std.math.maxInt(u16)))).render(allocator, body);
}

test "approval renders pending request" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.approval.setPending(std.testing.allocator, "call-1", "edit_file", "{\"path\":\"README.md\"}");

    const text = try render(std.testing.allocator, &state, .{ .width = 80 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Approval required") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "edit_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "(y) allow once") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "(a) allow always") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "(n) deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Always scope: edit_file path README.md") != null);
}

test "approval renders command scope hint" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.approval.setPending(std.testing.allocator, "call-shell", "shell_execute", "{\"command\":\"zig build test\"}");

    const text = try render(std.testing.allocator, &state, .{ .width = 100 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Always scope: shell_execute command zig build test") != null);
}

test "approval scope hint strips terminal controls" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.approval.setPending(std.testing.allocator, "call-escape", "edit_file", "{\"path\":\"src/\\u001b[2Jsecret.zig\"}");

    const text = try render(std.testing.allocator, &state, .{ .width = 100 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOfScalar(u8, state.approval.scope_hint, 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "secret.zig") != null);
}

test "approval scope hint strips C1 control characters" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    // U+009B (CSI) encodes as C2 9B in UTF-8
    try state.approval.setPending(std.testing.allocator, "call-c1", "edit_file", "{\"path\":\"src/\xC2\x9Bclear.zig\"}");

    const text = try render(std.testing.allocator, &state, .{ .width = 100 });
    defer std.testing.allocator.free(text);

    // C2 9B (U+009B CSI) should be stripped from scope hint
    try std.testing.expect(std.mem.indexOf(u8, state.approval.scope_hint, "\xC2\x9B") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "clear.zig") != null);
}

test "approval renders hashline preview" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.approval.setPending(std.testing.allocator, "call-2", "hashline_edit", "{\"path\":\"src/main.zig\"}");
    try state.preview.set(std.testing.allocator, .diff, "src/main.zig", "hashline edit preview\nrange: 2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n+ 2|new");

    const text = try render(std.testing.allocator, &state, .{ .width = 120 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Preview:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hashline edit preview") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+ 2|new") != null);
}

test "approval hides stale preview for non hashline request" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.preview.set(std.testing.allocator, .diff, "src/main.zig", "hashline edit preview\n+ 2|stale");
    try state.approval.setPending(std.testing.allocator, "call-3", "edit_file", "{\"path\":\"README.md\"}");

    const text = try render(std.testing.allocator, &state, .{ .width = 120 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Preview:") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "stale") == null);
}
