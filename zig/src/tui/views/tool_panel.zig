const std = @import("std");
const tui_state = @import("tui_state");

pub const Options = struct {
    width: usize = 80,
    height: usize = 8,
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    try writer.writeAll("Tools");
    if (state.tools.items.len == 0) {
        try writer.writeAll("\n  none");
        return out.toOwnedSlice();
    }

    var rows: usize = 1;
    for (state.tools.items) |tool| {
        if (rows >= options.height) break;
        try writer.print("\n  [{s}] {s}", .{ statusText(tool.status), tool.name });
        if (tool.raw_total_bytes > 0 or tool.returned_total_bytes > 0) {
            try writer.print(" ({d}->{d} bytes", .{ tool.raw_total_bytes, tool.returned_total_bytes });
            if (tool.estimated_returned_tokens > 0) try writer.print(", ~{d} tok", .{tool.estimated_returned_tokens});
            try writer.writeByte(')');
        }
        if (tool.truncated) try writer.writeAll(" truncated/show full");
        if (tool.artifact_refs.len > 0) try writer.print(" artifact:{s}", .{tool.artifact_refs});
        rows += 1;
        if (tool.expanded and rows < options.height) {
            try writer.writeAll(" ");
            try writeOneLine(writer, if (tool.output.items.len > 0) tool.output.items else tool.args_json, options.width -| 4);
            rows += 1;
        }
    }
    return out.toOwnedSlice();
}

fn statusText(status: tui_state.ToolStatus) []const u8 {
    return switch (status) {
        .pending => "pending",
        .running => "running",
        .done => "done",
        .@"error" => "error",
    };
}

fn writeOneLine(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    if (width == 0) return;
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = text[0..nl];
    try writer.writeAll(line[0..@min(width, line.len)]);
    if (line.len > width or nl < text.len) try writer.writeAll("…");
}

test "tool panel renders tool status and output" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(std.testing.allocator, "call-1", "shell_command", "{\"command\":\"pwd\"}", .running));
    state.tools.items[0].expanded = true;
    try state.tools.items[0].output.appendSlice(std.testing.allocator, "ok");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 4 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "[running] shell_command") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ok") != null);
}
