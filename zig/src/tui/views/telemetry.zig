const std = @import("std");
const tui_state = @import("tui_state");

pub const Options = struct {
    width: usize = 80,
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    const telemetry = state.telemetry;
    const limit = if (telemetry.context_window > 0) telemetry.context_window else state.status.context_limit;

    try writer.writeAll("Context ");
    try writeContextBar(writer, telemetry.estimated_tokens, limit, 20);
    if (limit > 0) {
        try writer.print(" {d}/{d} tok", .{ telemetry.estimated_tokens, limit });
    } else {
        try writer.print(" {d} tok", .{telemetry.estimated_tokens});
    }
    try writer.print(" ({d} bytes)", .{telemetry.total_bytes});

    try writer.writeAll("\nSegments ");
    try writeSegment(writer, "system_prompt", telemetry.system_prompt);
    try writer.writeAll(" • ");
    try writeSegment(writer, "messages", telemetry.messages);
    try writer.writeAll(" • ");
    try writeSegment(writer, "tools", telemetry.tool_definitions);

    if (findLatestTruncatedTool(state)) |tool| {
        try writer.print("\nTool output truncated {d}->{d} bytes", .{ tool.returned_total_bytes, tool.raw_total_bytes });
        if (tool.artifact_refs.len > 0) try writer.print(" • artifact {s}", .{tool.artifact_refs});
    }

    const items = out.written();
    if (items.len > options.width * 3) {
        const clipped = try allocator.dupe(u8, items[0 .. options.width * 3]);
        out.deinit();
        return clipped;
    }
    return out.toOwnedSlice();
}

fn writeContextBar(writer: *std.Io.Writer, used: u64, limit: u64, width: usize) !void {
    try writer.writeByte('[');
    const filled = if (limit > 0) @min(width, @as(usize, @intCast((used * width) / limit))) else 0;
    for (0..width) |i| try writer.writeByte(if (i < filled) '#' else '-');
    try writer.writeByte(']');
}

fn writeSegment(writer: *std.Io.Writer, name: []const u8, segment: tui_state.PromptSegmentState) !void {
    if (!segment.seen) {
        try writer.print("{s}:n/a", .{name});
        return;
    }
    const role: []const u8 = switch (segment.cache_role) {
        .stable => "stable/cacheable",
        .dynamic => "dynamic",
    };
    try writer.print("{s}:{d}b/{d}t {s}", .{ name, segment.bytes, segment.estimated_tokens, role });
}

fn findLatestTruncatedTool(state: *const tui_state.AppState) ?*const tui_state.ToolEntry {
    var i = state.tools.items.len;
    while (i > 0) {
        i -= 1;
        if (state.tools.items[i].truncated) return &state.tools.items[i];
    }
    return null;
}

test "telemetry view renders context and segments" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.telemetry.estimated_tokens = 100;
    state.telemetry.context_window = 200;
    state.telemetry.total_bytes = 400;
    state.telemetry.system_prompt = .{ .bytes = 40, .estimated_tokens = 10, .item_count = 1, .cache_role = .stable, .seen = true };
    state.telemetry.messages = .{ .bytes = 200, .estimated_tokens = 50, .item_count = 4, .cache_role = .dynamic, .seen = true };
    state.telemetry.tool_definitions = .{ .bytes = 160, .estimated_tokens = 40, .item_count = 2, .cache_role = .stable, .seen = true };

    const text = try render(std.testing.allocator, &state, .{ .width = 120 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "100/200 tok") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "system_prompt:40b/10t stable/cacheable") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "messages:200b/50t dynamic") != null);
}
