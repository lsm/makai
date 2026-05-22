const std = @import("std");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");

pub const Options = struct {
    width: usize = 80,
    height: usize = 8,
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    const title = try std.fmt.allocPrint(allocator, "Tools ({d} registered)", .{state.registered_tools.items.len});
    defer allocator.free(title);
    const styled_title = try tui_theme.panelTitle().render(allocator, title);
    defer allocator.free(styled_title);
    try writer.writeAll(styled_title);
    if (state.tools.items.len == 0) {
        if (state.registered_tools.items.len == 0) {
            const none = try tui_theme.muted().render(allocator, "  none");
            defer allocator.free(none);
            try writer.writeByte('\n');
            try writer.writeAll(none);
            const body = try out.toOwnedSlice();
            defer allocator.free(body);
            return tui_theme.panel().width(@intCast(@min(options.width, std.math.maxInt(u16)))).render(allocator, body);
        }
        var rows: usize = 1;
        for (state.registered_tools.items) |tool| {
            if (rows >= options.height) break;
            try writer.writeByte('\n');
            try writer.print("  {s}", .{tool.name});
            if (tool.short_description.len > 0) {
                try writer.writeAll(" ");
                const desc = try tui_text.truncateToWidth(allocator, tool.short_description, options.width -| tool.name.len -| 6);
                defer allocator.free(desc);
                const styled_desc = try tui_theme.muted().render(allocator, desc);
                defer allocator.free(styled_desc);
                try writer.writeAll(styled_desc);
            }
            rows += 1;
        }
        const body = try out.toOwnedSlice();
        defer allocator.free(body);
        return tui_theme.panel().width(@intCast(@min(options.width, std.math.maxInt(u16)))).render(allocator, body);
    }

    var rows: usize = 1;
    for (state.tools.items) |tool| {
        if (rows >= options.height) break;
        try writer.writeByte('\n');
        try writer.writeAll("  ");
        const status = try tui_theme.toolStatus(tool.status).render(allocator, statusText(tool.status));
        defer allocator.free(status);
        try writer.print("[{s}] {s}", .{ status, tool.name });
        if (tool.raw_total_bytes > 0 or tool.returned_total_bytes > 0) {
            try writer.print(" ({d}->{d} bytes", .{ tool.raw_total_bytes, tool.returned_total_bytes });
            if (tool.estimated_returned_tokens > 0) try writer.print(", ~{d} tok", .{tool.estimated_returned_tokens});
            try writer.writeByte(')');
        }
        if (tool.truncated) try writer.writeAll(" truncated/show full");
        if (tool.artifact_refs.len > 0) try writer.print(" artifact:{s}", .{tool.artifact_refs});
        rows += 1;
        if (tool.expanded and rows < options.height) {
            try writer.writeByte('\n');
            try writer.writeAll("    ");
            const one = try oneLine(allocator, if (tool.output.items.len > 0) tool.output.items else tool.args_json, options.width -| 6);
            defer allocator.free(one);
            const styled = try tui_theme.muted().render(allocator, one);
            defer allocator.free(styled);
            try writer.writeAll(styled);
            rows += 1;
        }
    }
    const body = try out.toOwnedSlice();
    defer allocator.free(body);
    return tui_theme.panel().width(@intCast(@min(options.width, std.math.maxInt(u16)))).render(allocator, body);
}

fn statusText(status: tui_state.ToolStatus) []const u8 {
    return switch (status) {
        .pending => "pending",
        .running => "running",
        .done => "done",
        .@"error" => "error",
    };
}

fn oneLine(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = text[0..nl];
    const clipped = try tui_text.truncateToWidth(allocator, line, width);
    if (nl < text.len and tui_text.visibleWidth(clipped) < width) {
        const with_ellipsis = try std.fmt.allocPrint(allocator, "{s}…", .{clipped});
        allocator.free(clipped);
        return with_ellipsis;
    }
    return clipped;
}

test "tool panel renders registered tools when idle" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    const tools = [_]@import("agent").AgentTool{.{
        .label = "Shell Execute",
        .name = "shell_execute",
        .description = "Run shell commands",
        .short_description = "Run shell commands",
        .parameters_schema_json = "{}",
        .execute = tui_state.noopToolForTest,
    }};
    try state.setRegisteredTools(&tools);

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 4 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Tools (1 registered)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "shell_execute") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Run shell commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "none") == null);
}

test "tool panel renders tool status and output" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(std.testing.allocator, "call-1", "shell_command", "{\"command\":\"pwd\"}", .running));
    state.tools.items[0].expanded = true;
    try state.tools.items[0].output.appendSlice(std.testing.allocator, "ok");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 4 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "running") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "shell_command") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ok") != null);
}
