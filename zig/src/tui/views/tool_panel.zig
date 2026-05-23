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
        if (tool.truncated) try writer.writeAll(" truncated · show full");
        if (tool.artifact_refs.len > 0) try writer.print(" · artifact:{s}", .{tool.artifact_refs});
        if (tool.expanded) try writer.writeAll(" · expanded");
        rows += 1;
        if (tool.expanded and rows < options.height) {
            rows = try renderExpandedOutput(allocator, writer, tool, options.width, options.height, rows);
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

fn renderExpandedOutput(allocator: std.mem.Allocator, writer: *std.Io.Writer, tool: tui_state.ToolEntry, width: usize, height: usize, rows: usize) !usize {
    const source = if (tool.output.items.len > 0) tool.output.items else tool.args_json;
    if (source.len == 0) return rows;
    const available_lines = height - rows;
    if (available_lines == 0) return rows;
    const content_width = width -| 8;
    if (content_width == 0) return rows;

    var next_rows = rows;
    var line_iter = std.mem.splitScalar(u8, source, '\n');
    while (line_iter.next()) |logical_line| {
        var remaining = logical_line;
        while (true) {
            if (next_rows >= height) return try renderTruncationMarker(writer, next_rows, height);
            const take = takeDisplayWidth(remaining, content_width);
            const segment = remaining[0..take.bytes];
            try writer.writeByte('\n');
            try writer.writeAll("    │ ");
            const styled = try styleOutputLine(allocator, tool, logical_line, segment);
            defer allocator.free(styled);
            try writer.writeAll(styled);
            next_rows += 1;
            remaining = remaining[take.bytes..];
            if (remaining.len == 0) break;
        }
    }
    return next_rows;
}

const DisplayTake = struct {
    bytes: usize,
    width: usize,
};

fn takeDisplayWidth(line: []const u8, max_width: usize) DisplayTake {
    if (line.len == 0 or max_width == 0) return .{ .bytes = 0, .width = 0 };
    var width: usize = 0;
    var i: usize = 0;
    while (i < line.len and width < max_width) {
        if (line[i] == 0x1b) {
            const start = i;
            skipAnsiSequence(line, &i);
            if (i == start) i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        if (i + len > line.len) break;
        const codepoint = std.unicode.utf8Decode(line[i .. i + len]) catch line[i];
        const cw = @import("zigzag").measure.charWidth(@intCast(codepoint));
        if (width + cw > max_width) {
            if (i == 0) i += len;
            break;
        }
        width += cw;
        i += len;
    }
    return .{ .bytes = i, .width = width };
}

fn skipAnsiSequence(text: []const u8, index: *usize) void {
    if (index.* >= text.len or text[index.*] != 0x1b) return;
    index.* += 1;
    if (index.* >= text.len) return;
    const second = text[index.*];
    index.* += 1;
    if (second == '[') {
        while (index.* < text.len) {
            const c = text[index.*];
            index.* += 1;
            if (c >= 0x40 and c <= 0x7e) return;
        }
        return;
    }
    if (second == ']') {
        while (index.* < text.len) {
            const c = text[index.*];
            index.* += 1;
            if (c == 0x07) return;
            if (c == 0x1b and index.* < text.len and text[index.*] == '\\') {
                index.* += 1;
                return;
            }
        }
    }
}

fn renderTruncationMarker(writer: *std.Io.Writer, rows: usize, height: usize) !usize {
    if (rows == 0 or height == 0) return rows;
    try writer.writeAll("…");
    return rows;
}

fn styleOutputLine(allocator: std.mem.Allocator, tool: tui_state.ToolEntry, logical_line: []const u8, segment: []const u8) ![]const u8 {
    if (tool.status == .@"error") return tui_theme.errorText().render(allocator, segment);
    if (isDiffLike(tool.name, logical_line)) return tui_theme.diffLine(logical_line).render(allocator, segment);
    return tui_theme.muted().render(allocator, segment);
}

fn isDiffLike(tool_name: []const u8, line: []const u8) bool {
    if (!isDiffTool(tool_name)) return false;
    return std.mem.startsWith(u8, line, "+ ") or std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "  anchor ");
}

fn isDiffTool(tool_name: []const u8) bool {
    return std.mem.indexOf(u8, tool_name, "edit") != null or std.mem.indexOf(u8, tool_name, "write") != null;
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

test "tool panel renders tool status and multiline output" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(std.testing.allocator, "call-1", "shell_command", "{\"command\":\"pwd\"}", .running));
    state.tools.items[0].expanded = true;
    try state.tools.items[0].output.appendSlice(std.testing.allocator, "first line\nsecond line");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 5 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "running") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "shell_command") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "first line") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "second line") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "expanded") != null);
}

test "tool panel renders diff and error output" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(std.testing.allocator, "call-1", "hashline_edit", "{}", .done));
    state.tools.items[0].expanded = true;
    try state.tools.items[0].output.appendSlice(std.testing.allocator, "- 2:hash|old\n+ 2|new");
    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(std.testing.allocator, "call-2", "shell_command", "{}", .@"error"));
    state.tools.items[1].expanded = true;
    try state.tools.items[1].output.appendSlice(std.testing.allocator, "boom");

    const text = try render(std.testing.allocator, &state, .{ .width = 100, .height = 8 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "- 2:hash|old") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+ 2|new") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "error") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "boom") != null);
}

test "tool panel preserves spaces and narrows diff detection" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(std.testing.allocator, "call-1", "shell_command", "{}", .done));
    state.tools.items[0].expanded = true;
    try state.tools.items[0].output.appendSlice(std.testing.allocator, "key    value\n--help\n-42");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 6 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "key    value") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--help") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "-42") != null);
}

test "tool panel keeps diff styling across wrapped segments and errors win" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(std.testing.allocator, "call-1", "hashline_edit", "{}", .done));
    state.tools.items[0].expanded = true;
    try state.tools.items[0].output.appendSlice(std.testing.allocator, "+ 2|abcdefghijklmnopqrstuvwxyz");
    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(std.testing.allocator, "call-2", "shell_command", "{}", .@"error"));
    state.tools.items[1].expanded = true;
    try state.tools.items[1].output.appendSlice(std.testing.allocator, "+ cmd failed");

    const text = try render(std.testing.allocator, &state, .{ .width = 20, .height = 8 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "+ 2|abcdefgh") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ijklmnopqr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+ cmd failed") != null);
}

test "tool panel wrapper skips OSC and keeps wide UTF-8 intact" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(std.testing.allocator, "call-1", "shell_command", "{}", .done));
    state.tools.items[0].expanded = true;
    try state.tools.items[0].output.appendSlice(std.testing.allocator, "\x1b]8;;https://example.com\x07link\x1b]8;;\x07\n界abc");

    const text = try render(std.testing.allocator, &state, .{ .width = 40, .height = 6 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b]8;;https://example.com\x07link\x1b]8;;\x07") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "界") != null);
}
