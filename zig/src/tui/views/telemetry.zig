const std = @import("std");
const zz = @import("zigzag");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");

pub const Options = struct {
    width: usize = 80,
};

const gauge_thresholds = [_]zz.Gauge.Threshold{
    .{ .value = 70, .color = tui_theme.palette.warning },
    .{ .value = 90, .color = tui_theme.palette.danger },
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    const telemetry = state.telemetry;
    const limit = if (telemetry.context_window > 0) telemetry.context_window else state.status.context_limit;

    const context_label = try tui_theme.statusKey().render(allocator, "Context");
    defer allocator.free(context_label);
    try writer.print("{s} ", .{context_label});
    var gauge = zz.Gauge{
        .value = @floatFromInt(telemetry.estimated_tokens),
        .min = 0,
        .max = if (limit > 0) @floatFromInt(limit) else 100,
        .width = 20,
        .show_value = false,
        .show_percent = false,
        .thresholds = &gauge_thresholds,
        .base_color = tui_theme.palette.success,
        .empty_color = tui_theme.palette.dim,
    };
    var gauge_arena = std.heap.ArenaAllocator.init(allocator);
    defer gauge_arena.deinit();
    const gauge_text = gauge.view(gauge_arena.allocator());
    try writer.writeAll(gauge_text);
    const used_text = try tui_text.compactNumber(allocator, telemetry.estimated_tokens);
    defer allocator.free(used_text);
    if (limit > 0) {
        const limit_text = try tui_text.compactNumber(allocator, limit);
        defer allocator.free(limit_text);
        try writer.print(" {s}/{s} tok", .{ used_text, limit_text });
    } else {
        try writer.print(" {s} tok", .{used_text});
    }
    const bytes_text = try tui_text.compactNumber(allocator, telemetry.total_bytes);
    defer allocator.free(bytes_text);
    try writer.print(" ({s} bytes)", .{bytes_text});

    try writer.writeAll("\n");
    const segments = try tui_theme.statusKey().render(allocator, "Segments");
    defer allocator.free(segments);
    try writer.print("{s} ", .{segments});
    try writeSegment(writer, allocator, "sys", telemetry.system_prompt);
    try writer.writeAll(" • ");
    try writeSegment(writer, allocator, "msg", telemetry.messages);
    try writer.writeAll(" • ");
    try writeSegment(writer, allocator, "tools", telemetry.tool_definitions);

    if (findLatestTruncatedTool(state)) |tool| {
        const raw_text = try tui_text.compactNumber(allocator, tool.raw_total_bytes);
        defer allocator.free(raw_text);
        const returned_text = try tui_text.compactNumber(allocator, tool.returned_total_bytes);
        defer allocator.free(returned_text);
        try writer.print("\nTool output truncated {s}->{s} bytes", .{ raw_text, returned_text });
        if (tool.artifact_refs.len > 0) try writer.print(" • artifact {s}", .{tool.artifact_refs});
    }

    const items = out.written();
    if (tui_text.visibleWidth(items) > options.width * 3) {
        const clipped = try tui_text.truncateLinesToWidth(allocator, items, options.width, 3);
        out.deinit();
        return clipped;
    }
    return out.toOwnedSlice();
}

fn writeSegment(writer: *std.Io.Writer, allocator: std.mem.Allocator, name: []const u8, segment: tui_state.PromptSegmentState) !void {
    const styled_name = try tui_theme.statusKey().render(allocator, name);
    defer allocator.free(styled_name);
    if (!segment.seen) {
        try writer.print("{s}:n/a", .{styled_name});
        return;
    }
    const role: []const u8 = switch (segment.cache_role) {
        .stable => "stable/cacheable",
        .dynamic => "dynamic",
    };
    const bytes = try tui_text.compactNumber(allocator, segment.bytes);
    defer allocator.free(bytes);
    const tokens = try tui_text.compactNumber(allocator, segment.estimated_tokens);
    defer allocator.free(tokens);
    try writer.print("{s}:{s}b/{s}t {s}", .{ styled_name, bytes, tokens, role });
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
    try std.testing.expect(std.mem.indexOf(u8, text, "sys") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "msg") != null);
}

test "telemetry overflow preserves segment line" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.telemetry.estimated_tokens = 100;
    state.telemetry.context_window = 200;
    state.telemetry.total_bytes = 400;
    state.telemetry.system_prompt = .{ .bytes = 40, .estimated_tokens = 10, .item_count = 1, .cache_role = .stable, .seen = true };
    state.telemetry.messages = .{ .bytes = 200, .estimated_tokens = 50, .item_count = 4, .cache_role = .dynamic, .seen = true };
    state.telemetry.tool_definitions = .{ .bytes = 160, .estimated_tokens = 40, .item_count = 2, .cache_role = .stable, .seen = true };

    const text = try render(std.testing.allocator, &state, .{ .width = 12 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Segments") != null);
}
