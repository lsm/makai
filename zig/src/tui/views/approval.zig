const std = @import("std");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");
const tui_render = @import("tui_render");

pub const Options = struct {
    width: usize = 80,
};

const max_arg_rows: usize = 6;
const max_preview_rows: usize = 8;

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]const u8 {
    if (state.approval.status != .pending) return allocator.dupe(u8, "");
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    defer for (parts.items) |part| allocator.free(part);

    const inner_width = options.width -| 4;
    try parts.append(allocator, try renderToolLine(allocator, state));
    try renderArgs(allocator, &parts, state.approval.args_json, inner_width);
    if (state.approval.scope_hint.len > 0) {
        const scope = try tui_text.truncateToWidth(allocator, state.approval.scope_hint, inner_width -| 14);
        defer allocator.free(scope);
        const label = try tui_theme.dim().render(allocator, "Always scope: ");
        defer allocator.free(label);
        const value = try tui_theme.soft().render(allocator, scope);
        defer allocator.free(value);
        try parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ label, value }));
    }
    if (std.mem.eql(u8, state.approval.tool_name, "hashline_edit") and state.preview.content.len > 0) {
        try parts.append(allocator, try tui_theme.panelTitle().render(allocator, "Preview:"));
        var rows: usize = 0;
        var lines = std.mem.splitScalar(u8, state.preview.content, '\n');
        while (lines.next()) |line| {
            if (rows >= max_preview_rows) break;
            const clipped = try tui_text.truncateToWidth(allocator, line, inner_width);
            defer allocator.free(clipped);
            try parts.append(allocator, try tui_theme.diffLine(line).render(allocator, clipped));
            rows += 1;
        }
    }
    try parts.append(allocator, try allocator.dupe(u8, ""));
    try parts.append(allocator, try renderKeys(allocator));
    const body = try tui_render.joinVertical(allocator, parts.items);
    defer allocator.free(body);
    return tui_theme.titledPanel(allocator, body, .{
        .title = tui_theme.glyph.tool ++ " Approval required",
        .title_style = tui_theme.warningText(),
        .border = tui_theme.palette.warning,
        .width = options.width,
    });
}

fn renderToolLine(allocator: std.mem.Allocator, state: *const tui_state.AppState) ![]u8 {
    const label = try tui_theme.dim().render(allocator, "Tool: ");
    defer allocator.free(label);
    const name = try tui_theme.toolRole(state.approval.tool_name).render(allocator, state.approval.tool_name);
    defer allocator.free(name);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ label, name });
}

fn renderArgs(allocator: std.mem.Allocator, parts: *std.ArrayList([]const u8), args_json: []const u8, inner_width: usize) !void {
    if (args_json.len == 0) return;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch {
        try parts.append(allocator, try renderRawArgs(allocator, args_json, inner_width));
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() == 0) {
        try parts.append(allocator, try renderRawArgs(allocator, args_json, inner_width));
        return;
    }
    var key_width: usize = 0;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| key_width = @max(key_width, tui_text.visibleWidth(entry.key_ptr.*));
    key_width = @min(key_width, 18);

    var rows: usize = 0;
    var walk = parsed.value.object.iterator();
    while (walk.next()) |entry| {
        if (rows >= max_arg_rows) {
            const more = try std.fmt.allocPrint(allocator, "… {d} more", .{parsed.value.object.count() - rows});
            defer allocator.free(more);
            try parts.append(allocator, try tui_theme.dim().render(allocator, more));
            break;
        }
        const value_text = try jsonValueText(allocator, entry.value_ptr.*);
        defer allocator.free(value_text);
        const key_clipped = try tui_text.truncateLineToWidth(allocator, entry.key_ptr.*, key_width);
        defer allocator.free(key_clipped);
        const value_clipped = try tui_text.truncateLineToWidth(allocator, value_text, inner_width -| (key_width + 3));
        defer allocator.free(value_clipped);
        const key_styled = try tui_theme.accentText().render(allocator, key_clipped);
        defer allocator.free(key_styled);
        const value_styled = try tui_theme.base().render(allocator, value_clipped);
        defer allocator.free(value_styled);
        var row: std.Io.Writer.Allocating = .init(allocator);
        errdefer row.deinit();
        try row.writer.writeAll("  ");
        try row.writer.writeAll(key_styled);
        for (0..key_width -| tui_text.visibleWidth(key_clipped) + 1) |_| try row.writer.writeByte(' ');
        try row.writer.writeAll(value_styled);
        try parts.append(allocator, try row.toOwnedSlice());
        rows += 1;
    }
}

fn renderRawArgs(allocator: std.mem.Allocator, args_json: []const u8, inner_width: usize) ![]u8 {
    const args = try tui_text.truncateToWidth(allocator, args_json, inner_width -| 6);
    defer allocator.free(args);
    const label = try tui_theme.dim().render(allocator, "Args: ");
    defer allocator.free(label);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ label, args });
}

fn jsonValueText(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .string => |text| sanitizeOneLine(allocator, text),
        .null => allocator.dupe(u8, "null"),
        .bool => |b| allocator.dupe(u8, if (b) "true" else "false"),
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
        .number_string => |n| allocator.dupe(u8, n),
        .array, .object => blk: {
            var out: std.Io.Writer.Allocating = .init(allocator);
            errdefer out.deinit();
            try std.json.Stringify.value(value, .{}, &out.writer);
            const raw = try out.toOwnedSlice();
            defer allocator.free(raw);
            break :blk try sanitizeOneLine(allocator, raw);
        },
    };
}

fn sanitizeOneLine(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\n' or c == '\r' or c == '\t') {
            try writer.writeByte(' ');
            i += 1;
            continue;
        }
        if (c < 0x20 or c == 0x7f) {
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += 1;
            continue;
        };
        if (codepoint >= 0x80 and codepoint <= 0x9f) {
            i += len;
            continue;
        }
        try writer.writeAll(text[i .. i + len]);
        i += len;
    }
    return out.toOwnedSlice();
}

fn renderKeys(allocator: std.mem.Allocator) ![]u8 {
    const caps = [_][2][]const u8{
        .{ "y", "allow once" },
        .{ "a", "allow always" },
        .{ "n", "deny" },
        .{ "esc", "abort" },
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    for (caps, 0..) |cap, i| {
        if (i > 0) {
            const sep = try tui_theme.faint().render(allocator, "  " ++ tui_theme.glyph.dot ++ "  ");
            defer allocator.free(sep);
            try writer.writeAll(sep);
        }
        const key = try tui_theme.keyCap().render(allocator, cap[0]);
        defer allocator.free(key);
        const label = try tui_theme.keyHint().render(allocator, cap[1]);
        defer allocator.free(label);
        try writer.writeAll(key);
        try writer.writeByte(' ');
        try writer.writeAll(label);
    }
    return out.toOwnedSlice();
}

test "approval renders pending request" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.approval.setPending(std.testing.allocator, "call-1", "edit_file", "edit_file", "{\"path\":\"README.md\"}");

    const text = try render(std.testing.allocator, &state, .{ .width = 80 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Approval required") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "edit_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "path") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "allow once") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "allow always") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "abort") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "edit_file path README.md") != null);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try std.testing.expectEqual(@as(usize, 80), tui_text.visibleWidth(line));
}

test "approval renders command scope hint" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.approval.setPending(std.testing.allocator, "call-shell", "shell_execute", "shell_execute", "{\"command\":\"zig build test\"}");

    const text = try render(std.testing.allocator, &state, .{ .width = 100 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "shell_execute command zig build test") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "command") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "{\"command\"") == null);
}

test "approval scope hint strips terminal controls" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.approval.setPending(std.testing.allocator, "call-escape", "edit_file", "edit_file", "{\"path\":\"src/\\u001b[2Jsecret.zig\"}");

    const text = try render(std.testing.allocator, &state, .{ .width = 100 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOfScalar(u8, state.approval.scope_hint, 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "secret.zig") != null);
}

test "approval scope hint strips C1 control characters" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.approval.setPending(std.testing.allocator, "call-c1", "edit_file", "edit_file", "{\"path\":\"src/\xC2\x9Bclear.zig\"}");

    const text = try render(std.testing.allocator, &state, .{ .width = 100 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, state.approval.scope_hint, "\xC2\x9B") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\xC2\x9B") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "clear.zig") != null);
}

test "approval renders hashline preview" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.approval.setPending(std.testing.allocator, "call-2", "hashline_edit", "hashline_edit", "{\"path\":\"src/main.zig\"}");
    try state.preview.set(std.testing.allocator, "hashline edit preview\nrange: 2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n+ 2|new");

    const text = try render(std.testing.allocator, &state, .{ .width = 120 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Preview:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hashline edit preview") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+ 2|new") != null);
}

test "approval hides stale preview for non hashline request" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.preview.set(std.testing.allocator, "hashline edit preview\n+ 2|stale");
    try state.approval.setPending(std.testing.allocator, "call-3", "edit_file", "edit_file", "{\"path\":\"README.md\"}");

    const text = try render(std.testing.allocator, &state, .{ .width = 120 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Preview:") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "stale") == null);
}

test "approval falls back to raw args when the payload is not an object" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.approval.setPending(std.testing.allocator, "call-4", "shell_execute", "shell_execute", "[1,2,3]");

    const text = try render(std.testing.allocator, &state, .{ .width = 80 });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Args: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[1,2,3]") != null);
}
