const std = @import("std");
const tui_state = @import("tui_state");

pub const Options = struct {
    width: usize = 80,
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    if (state.approval.status != .pending) return out.toOwnedSlice();
    try writer.writeAll("Approval required\n");
    try writer.print("Tool: {s}\n", .{state.approval.tool_name});
    try writer.print("Args: {s}\n", .{state.approval.args_json});
    if (std.mem.eql(u8, state.approval.tool_name, "hashline_edit") and state.preview.content.len > 0) {
        try writer.writeAll("\nPreview:\n");
        var rows: usize = 4;
        var lines = std.mem.splitScalar(u8, state.preview.content, '\n');
        while (lines.next()) |line| {
            if (rows >= 12) break;
            try writer.writeAll(line[0..@min(options.width, line.len)]);
            try writer.writeByte('\n');
            rows += 1;
        }
    }
    try writer.writeAll("[a] allow  [d] deny  [A] always allow");
    return out.toOwnedSlice();
}

test "approval renders pending request" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.approval.setPending(std.testing.allocator, "call-1", "edit_file", "{\"path\":\"README.md\"}");

    const text = try render(std.testing.allocator, &state, .{ .width = 80 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Approval required") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "edit_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "always allow") != null);
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
