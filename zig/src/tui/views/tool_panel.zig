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
