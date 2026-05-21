const std = @import("std");
const tui_state = @import("tui_state");

pub const Options = struct {
    width: usize = 80,
    height: usize = 20,
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    if (state.preview.content.len == 0) {
        try writer.writeAll("No preview");
        return out.toOwnedSlice();
    }
    try writer.print("{s}: {s}\n", .{ kindText(state.preview.kind), state.preview.title });
    var row: usize = 1;
    var skipped: usize = 0;
    var lines = std.mem.splitScalar(u8, state.preview.content, '\n');
    while (lines.next()) |line| {
        if (skipped < state.preview.scroll) {
            skipped += 1;
            continue;
        }
        if (row >= options.height) break;
        if (row > 1) try writer.writeByte('\n');
        try writer.writeAll(line[0..@min(options.width, line.len)]);
        row += 1;
    }
    return out.toOwnedSlice();
}

fn kindText(kind: tui_state.PreviewKind) []const u8 {
    return switch (kind) {
        .diff => "Diff",
        .file => "File",
        .artifact => "Artifact",
    };
}
