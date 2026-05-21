const std = @import("std");
const tui_state = @import("tui_state");

pub const Options = struct {
    width: usize = 80,
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]u8 {
    _ = options;
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    if (state.approval.status != .pending) return out.toOwnedSlice();
    try writer.writeAll("Approval required\n");
    try writer.print("Tool: {s}\n", .{state.approval.tool_name});
    try writer.print("Args: {s}\n", .{state.approval.args_json});
    try writer.writeAll("[a] allow  [d] deny  [A] always allow");
    return out.toOwnedSlice();
}
