const std = @import("std");
const zz = @import("zigzag");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");

const AppState = tui_state.AppState;
const TranscriptKind = tui_state.TranscriptKind;
const TranscriptEntry = tui_state.TranscriptEntry;

pub const Options = struct {
    width: usize = 80,
    height: usize = 20,
};

const DisplayEntry = struct {
    kind: TranscriptKind,
    text: []const u8,
    timestamp_ms: i64,
    tool_name: []const u8 = "",
    title: []const u8 = "",
};

pub fn render(allocator: std.mem.Allocator, state: *const AppState, options: Options) ![]const u8 {
    if (options.height == 0) return allocator.dupe(u8, "");

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var visible_entries = std.ArrayList(DisplayEntry).empty;
    defer visible_entries.deinit(allocator);
    try buildVisibleEntries(allocator, arena, state, &visible_entries);

    if (visible_entries.items.len == 0) {
        const ready_line = try tui_theme.muted().render(allocator, "Makai ready. Type message, /quit exits.");
        defer allocator.free(ready_line);
        return padTopToHeight(allocator, ready_line, options.height);
    }

    var all_rows: std.Io.Writer.Allocating = .init(allocator);
    defer all_rows.deinit();
    const all_writer = &all_rows.writer;
    var current_line: usize = 0;
    for (visible_entries.items, 0..) |*entry, i| {
        if (i > 0) {
            try all_writer.writeAll("\n\n");
            current_line += 1;
        }
        const row = try renderEntry(allocator, entry, options.width);
        defer allocator.free(row);
        try all_writer.writeAll(row);
        current_line += tui_text.lineCount(row);
    }

    const all_text = all_rows.written();
    const total_lines = current_line;

    const show_indicator = state.transcript_scroll > 0 and total_lines > options.height and options.height >= 2;
    const view_height = if (show_indicator) options.height - 1 else options.height;
    const windowed = try lineWindow(allocator, all_text, view_height, state.transcript_scroll);
    defer allocator.free(windowed);

    if (!show_indicator) return padTopToHeight(allocator, windowed, options.height);

    const pct = scrollPercent(total_lines, view_height, state.transcript_scroll);
    const raw_indicator = try std.fmt.allocPrint(allocator, "\u{2191} SCROLL {d}%", .{pct});
    defer allocator.free(raw_indicator);
    const indicator = try tui_theme.muted().render(allocator, raw_indicator);
    defer allocator.free(indicator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(indicator);
    try writer.writeByte('\n');
    try writer.writeAll(windowed);
    const composed = try out.toOwnedSlice();
    defer allocator.free(composed);
    return padTopToHeight(allocator, composed, options.height);
}

pub fn renderTranscriptEntry(allocator: std.mem.Allocator, entry: *const TranscriptEntry, width: usize) ![]u8 {
    var display = DisplayEntry{
        .kind = entry.kind,
        .text = entry.text.items,
        .timestamp_ms = entry.timestamp_ms,
        .tool_name = if (entry.kind == .tool) inferredToolName(entry.text.items) else "",
        .title = if (entry.kind == .tool) inferredToolTitle(entry.text.items) else "",
    };
    return renderEntry(allocator, &display, width);
}

fn buildVisibleEntries(allocator: std.mem.Allocator, arena: std.mem.Allocator, state: *const AppState, entries: *std.ArrayList(DisplayEntry)) !void {
    var tool_index: usize = 0;
    var i: usize = 0;
    while (i < state.transcript.items.len) {
        const entry = &state.transcript.items[i];
        if (entry.kind == .tool) {
            const cluster_start = i;
            while (i < state.transcript.items.len and state.transcript.items[i].kind == .tool) : (i += 1) {}
            tool_index = try appendBalancedToolCluster(allocator, arena, entries, state, cluster_start, i, tool_index);
            continue;
        }
        try appendOriginal(allocator, entries, entry);
        i += 1;
    }
}

fn appendBalancedToolCluster(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    entries: *std.ArrayList(DisplayEntry),
    state: *const AppState,
    start: usize,
    end: usize,
    initial_tool_index: usize,
) !usize {
    var tool_index = initial_tool_index;
    if (state.tools.items.len == 0 or tool_index >= state.tools.items.len) {
        for (state.transcript.items[start..end]) |*entry| {
            try appendOriginal(allocator, entries, entry);
        }
        return tool_index;
    }

    const calls_in_cluster = @max(countToolStarts(state.transcript.items[start..end]), 1);
    var emitted: usize = 0;
    while (emitted < calls_in_cluster and tool_index < state.tools.items.len) : ({
        emitted += 1;
        tool_index += 1;
    }) {
        try appendToolSummary(allocator, arena, entries, state.tools.items[tool_index]);
    }
    return tool_index;
}

fn countToolStarts(entries: []const TranscriptEntry) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (entry.tool_summary) count += 1;
    }
    return count;
}

fn appendOriginal(allocator: std.mem.Allocator, entries: *std.ArrayList(DisplayEntry), entry: *const TranscriptEntry) !void {
    try entries.append(allocator, .{
        .kind = entry.kind,
        .text = entry.text.items,
        .timestamp_ms = entry.timestamp_ms,
        .tool_name = if (entry.kind == .tool) inferredToolName(entry.text.items) else "",
        .title = if (entry.kind == .tool) inferredToolTitle(entry.text.items) else "",
    });
}

fn appendToolSummary(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    entries: *std.ArrayList(DisplayEntry),
    tool: tui_state.ToolEntry,
) !void {
    const intent = try invocationDescription(arena, tool.args_json);
    const status = switch (tool.status) {
        .pending => "pending",
        .running => "running",
        .done => "ok",
        .@"error" => "failed",
        .interrupted => "interrupted",
    };

    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.writeAll("\u{25b8}");
    if (intent) |value| if (value.len > 0) try writer.print(" {s}", .{value});
    try writer.print(" [{s}", .{status});
    if (tool.raw_total_bytes > 0 or tool.returned_total_bytes > 0) {
        try writer.print(", {d}B", .{tool.returned_total_bytes});
    } else if (tool.output.items.len > 0) {
        try writer.print(", {d}B", .{tool.output.items.len});
    }
    if (tool.estimated_returned_tokens > 0) try writer.print(", ~{d} tok", .{tool.estimated_returned_tokens});
    if (tool.artifact_count > 0) {
        if (tool.raw_total_bytes > 0) {
            try writer.print(", {d}KB artifact", .{(tool.raw_total_bytes + 1023) / 1024});
        } else {
            try writer.print(", {d} artifact{s}", .{ tool.artifact_count, if (tool.artifact_count == 1) "" else "s" });
        }
        try writer.writeAll(", filter via artifact_retrieve");
    }
    try writer.writeByte(']');

    try entries.append(allocator, .{
        .kind = .tool,
        .text = out.written(),
        .timestamp_ms = 0,
        .tool_name = tool.name,
        .title = tool.label,
    });
}

fn invocationDescription(allocator: std.mem.Allocator, args_json: []const u8) !?[]const u8 {
    if (args_json.len == 0) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get("description") orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return try sanitizeAndClipToolDescription(allocator, value.string);
}

fn sanitizeAndClipToolDescription(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len and width < 96) {
        const c = text[i];
        switch (c) {
            '\n', '\r', '\t' => {
                try writer.writeByte(' ');
                width += 1;
                i += 1;
                continue;
            },
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
                i += 1;
                continue;
            },
            else => {},
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
        if (codepoint < 0x20 or codepoint == 0x7f or (codepoint >= 0x80 and codepoint <= 0x9f)) {
            i += len;
            continue;
        }
        try writer.writeAll(text[i .. i + len]);
        width += 1;
        i += len;
    }
    if (i < text.len) try writer.writeAll("...");
    return out.toOwnedSlice();
}

fn padTopToHeight(allocator: std.mem.Allocator, text: []const u8, height: usize) ![]const u8 {
    if (height == 0) return allocator.dupe(u8, "");
    const lines = tui_text.lineCount(text);
    if (lines >= height) return allocator.dupe(u8, text);
    const pad = height - lines;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    for (0..pad) |_| try writer.writeByte('\n');
    try writer.writeAll(text);
    return out.toOwnedSlice();
}

fn scrollPercent(total_lines: usize, view_height: usize, scroll: usize) usize {
    if (total_lines <= view_height) return 0;
    const max_scroll = total_lines - view_height;
    const clamped = @min(scroll, max_scroll);
    return clamped * 100 / max_scroll;
}

const user_bg = zz.Color.color256(111);
const user_fg = zz.Color.color256(235);
const assistant_bg = zz.Color.fromRgb(42, 44, 52);
const assistant_fg = zz.Color.fromRgb(238, 241, 247);

const chat_max_column: usize = 108;

const EntryLayout = struct {
    left: usize,
    width: usize,
};

fn renderEntry(allocator: std.mem.Allocator, entry: *const DisplayEntry, width: usize) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const align_right = entry.kind == .user;
    const header_layout = entryHeaderLayout(entry.kind, width);
    const body_layout = entryBodyLayout(entry.kind, width);
    const header_inner = try renderHeader(arena, entry.kind, entry.tool_name, entry.title, entry.timestamp_ms, align_right, header_layout.width);
    const header = try indentBlock(arena, header_inner, header_layout.left);

    const body_inner: []const u8 = switch (entry.kind) {
        .user => blk: {
            const budget = @max(body_layout.width -| 2, 8);
            const wrapped = try tui_text.wrapTextWithAnsi(arena, entry.text, budget);
            const open = try openSgr(arena, user_fg, user_bg);
            break :blk try renderBubble(arena, wrapped, open, true, body_layout.width);
        },
        .assistant => blk: {
            const budget = @max(body_layout.width -| 2, 8);
            const rendered = try renderAssistantPlain(arena, entry.text, budget);
            const open = try openSgr(arena, assistant_fg, assistant_bg);
            break :blk try renderBubble(arena, rendered, open, false, body_layout.width);
        },
        .tool => try renderToolRow(arena, entry.tool_name, entry.text, body_layout.width),
        else => try renderCard(arena, entry.kind, entry.tool_name, entry.text, body_layout.width),
    };
    const body = try indentBlock(arena, body_inner, body_layout.left);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(header);
    if (body.len > 0) {
        try writer.writeByte('\n');
        try writer.writeAll(body);
    }
    return out.toOwnedSlice();
}

fn entryHeaderLayout(kind: TranscriptKind, width: usize) EntryLayout {
    if (width <= 24) return .{ .left = 0, .width = width };

    const gutter: usize = 1;
    const available = width -| (gutter * 2);
    const left = if (kind == .user) width -| gutter -| available else gutter;
    return .{ .left = left, .width = available };
}

fn entryBodyLayout(kind: TranscriptKind, width: usize) EntryLayout {
    if (width <= 24) return .{ .left = 0, .width = width };

    const user_gutter: usize = if (width >= 100) 4 else 2;
    const label_text_left: usize = 3;
    const left_edge_right_gutter: usize = 1;
    const user_available = width -| (user_gutter * 2);
    const left_available = width -| label_text_left -| left_edge_right_gutter;
    const column = switch (kind) {
        .user => @min(user_available, chat_max_column),
        .assistant => @min(left_available, chat_max_column),
        else => left_available,
    };
    const left = switch (kind) {
        .user => width -| user_gutter -| column,
        .@"error" => label_text_left -| 2,
        else => label_text_left,
    };
    const adjusted_column = if (kind == .@"error") column + (label_text_left -| left) else column;
    return .{ .left = left, .width = adjusted_column };
}

fn indentBlock(allocator: std.mem.Allocator, text: []const u8, spaces: usize) ![]const u8 {
    if (spaces == 0) return allocator.dupe(u8, text);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try writer.writeByte('\n');
        first = false;
        try writeSpaces(writer, spaces);
        try writer.writeAll(line);
    }
    return out.toOwnedSlice();
}

fn renderToolRow(allocator: std.mem.Allocator, tool_name: []const u8, text: []const u8, width: usize) ![]const u8 {
    const content_width = @max(width, 8);
    const truncated = try tui_text.truncateLinesToWidth(allocator, text, content_width, std.math.maxInt(usize));
    const styled = try styleEachLine(allocator, tui_theme.toolBody(tool_name), truncated);
    return styled;
}

fn renderAssistantPlain(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    const code_width = width -| 2;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var in_fence = false;
    var fence_char: u8 = 0;
    var fence_len: usize = 0;
    var first_line = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!in_fence) {
            if (fenceMarker(line)) |marker| {
                in_fence = true;
                fence_char = marker.char;
                fence_len = marker.len;
                continue;
            }
        } else if (isFenceClose(line, fence_char, fence_len)) {
            in_fence = false;
            continue;
        }
        if (!first_line) try writer.writeByte('\n');
        first_line = false;
        if (!in_fence) {
            try wrapPlainLine(allocator, writer, line, width);
            continue;
        }
        const cleaned = try stripControls(allocator, line);
        defer allocator.free(cleaned);
        const expanded = try expandTabs(allocator, cleaned);
        defer allocator.free(expanded);
        const clipped = try tui_text.truncateLineToWidth(allocator, expanded, code_width);
        defer allocator.free(clipped);
        if (clipped.len == 0) continue;
        try writer.writeAll("  ");
        const styled = try tui_theme.dim().render(allocator, clipped);
        defer allocator.free(styled);
        try writer.writeAll(styled);
    }
    return out.toOwnedSlice();
}

const FenceMarker = struct { char: u8, len: usize };

const LineIndent = struct { width: usize, start: usize };

fn lineIndent(line: []const u8) LineIndent {
    var width: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == ' ') {
            width += 1;
        } else if (c == '\t') {
            width = (width / 4 + 1) * 4;
        } else if (c != '\r') {
            break;
        }
    }
    return .{ .width = width, .start = i };
}

fn fenceMarker(line: []const u8) ?FenceMarker {
    const ind = lineIndent(line);
    if (ind.width > 3) return null;
    const rest = line[ind.start..];
    if (rest.len < 3 or (rest[0] != '`' and rest[0] != '~')) return null;
    var n: usize = 0;
    while (n < rest.len and rest[n] == rest[0]) n += 1;
    if (n < 3) return null;
    if (rest[0] == '`' and std.mem.indexOfScalar(u8, rest[n..], '`') != null) return null;
    return .{ .char = rest[0], .len = n };
}

fn isFenceClose(line: []const u8, open_char: u8, open_len: usize) bool {
    const ind = lineIndent(line);
    if (ind.width > 3) return false;
    const trimmed = std.mem.trim(u8, line[ind.start..], " \t\r");
    if (trimmed.len < open_len or trimmed[0] != open_char) return false;
    var n: usize = 0;
    while (n < trimmed.len and trimmed[n] == open_char) n += 1;
    return n == trimmed.len;
}

fn flushWrapRow(writer: *std.Io.Writer, buf: *std.ArrayList(u8), col: *usize, pending_newline: *bool, pad_from: *?usize) !void {
    var split = std.mem.lastIndexOfScalar(u8, buf.items, ' ') orelse lastCharStart(buf.items);
    if (pad_from.*) |pf| {
        if (split >= pf) split = lastCharStart(buf.items);
    }
    if (std.mem.trim(u8, buf.items[0..split], " ").len == 0) split = lastCharStart(buf.items);
    if (pending_newline.*) {
        try writer.writeByte('\n');
        pending_newline.* = false;
    }
    try writer.writeAll(buf.items[0..split]);
    const tail_start = if (buf.items[split] == ' ') split + 1 else split;
    const tail_len = buf.items.len - tail_start;
    std.mem.copyForwards(u8, buf.items[0..tail_len], buf.items[tail_start..]);
    buf.shrinkRetainingCapacity(tail_len);
    col.* = tui_text.visibleWidth(buf.items);
    if (tail_len > 0) {
        try writer.writeByte('\n');
    } else {
        pending_newline.* = true;
    }
    pad_from.* = null;
}

fn wrapPlainLine(allocator: std.mem.Allocator, writer: *std.Io.Writer, line: []const u8, max_width: usize) !void {
    if (max_width == 0 or line.len == 0) {
        try writer.writeAll(line);
        return;
    }
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var col: usize = 0;
    var pending_newline = false;
    var pad_from: ?usize = null;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == 0x1b) {
            skipAnsiSequence(line, &i);
            continue;
        }
        if ((c < 0x20 and c != '\t') or c == 0x7f) {
            i += 1;
            continue;
        }
        if (c == '\t') {
            i += 1;
            pad_from = buf.items.len;
            var pad = tab_width - (col % tab_width);
            while (pad > 0) {
                if (col >= max_width) {
                    if (pending_newline) {
                        try writer.writeByte('\n');
                        pending_newline = false;
                    }
                    try writer.writeAll(buf.items);
                    try writer.writeByte('\n');
                    buf.clearRetainingCapacity();
                    col = 0;
                    pad_from = 0;
                }
                const avail = max_width - col;
                if (pad <= avail) {
                    try buf.appendNTimes(allocator, ' ', pad);
                    col += pad;
                    pad = 0;
                } else {
                    try buf.appendNTimes(allocator, ' ', avail);
                    col += avail;
                    pad -= avail;
                }
            }
            continue;
        }
        if (c == ' ') {
            try buf.append(allocator, ' ');
            col += 1;
            i += 1;
            pad_from = null;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            if (i + len > line.len) break;
            const codepoint = std.unicode.utf8Decode(line[i .. i + len]) catch {
                i += 1;
                continue;
            };
            if (codepoint >= 0x80 and codepoint <= 0x9f) {
                i += len;
                continue;
            }
            try buf.appendSlice(allocator, line[i .. i + len]);
            col += zz.measure.charWidth(@intCast(codepoint));
            i += len;
        }
        if (col > max_width) try flushWrapRow(writer, &buf, &col, &pending_newline, &pad_from);
    }
    if (pending_newline) {
        if (std.mem.trim(u8, buf.items, " ").len > 0) {
            try writer.writeByte('\n');
            try writer.writeAll(buf.items);
        }
    } else {
        try writer.writeAll(buf.items);
    }
}

fn lastCharStart(buf: []const u8) usize {
    var i = buf.len;
    while (i > 0) {
        i -= 1;
        if ((buf[i] & 0xc0) != 0x80) return i;
    }
    return 0;
}

fn stripControls(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == 0x1b) {
            skipAnsiSequence(line, &i);
            continue;
        }
        if (c == '\t') {
            try writer.writeByte(c);
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
        if (i + len > line.len) break;
        const codepoint = std.unicode.utf8Decode(line[i .. i + len]) catch {
            i += 1;
            continue;
        };
        if (codepoint >= 0x80 and codepoint <= 0x9f) {
            i += len;
            continue;
        }
        try writer.writeAll(line[i .. i + len]);
        i += len;
    }
    return out.toOwnedSlice();
}

const tab_width: usize = 8;

fn expandTabs(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, line, '\t') == null) return allocator.dupe(u8, line);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var col: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '\t') {
            const pad = tab_width - (col % tab_width);
            try writeSpaces(writer, pad);
            col += pad;
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const take = @min(len, line.len - i);
        const codepoint = std.unicode.utf8Decode(line[i .. i + take]) catch c;
        try writer.writeAll(line[i .. i + take]);
        col += zz.measure.charWidth(@intCast(codepoint));
        i += take;
    }
    return out.toOwnedSlice();
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
        return;
    }
    if (second >= '(' and second <= '+') {
        if (index.* < text.len) index.* += 1;
        return;
    }
    if (second == 'P') {
        while (index.* < text.len) {
            const c = text[index.*];
            index.* += 1;
            if (c == 0x07) return;
            if (c == 0x1b and index.* < text.len and text[index.*] == '\\') {
                index.* += 1;
                return;
            }
        }
        return;
    }
}

fn renderHeader(allocator: std.mem.Allocator, kind: TranscriptKind, tool_name: []const u8, title: []const u8, ts_ms: i64, align_right: bool, width: usize) ![]u8 {
    const name = if (kind == .tool and title.len > 0) title else roleName(kind);
    const raw_label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ tui_theme.roleGlyph(kind), name });
    const role_style = if (kind == .tool and tool_name.len > 0) tui_theme.toolRole(tool_name) else tui_theme.role(kind);
    const styled_label = try role_style.render(allocator, raw_label);
    const clock = try formatTimestamp(allocator, ts_ms);

    var time_raw: []const u8 = "";
    var styled_time: []const u8 = "";
    if (clock.len > 0) {
        time_raw = try std.fmt.allocPrint(allocator, " \u{00b7} {s}", .{clock});
        styled_time = try tui_theme.muted().render(allocator, time_raw);
    }

    const visible = tui_text.visibleWidth(raw_label) + tui_text.visibleWidth(time_raw);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    if (align_right) try writeSpaces(writer, width -| visible);
    try writer.writeAll(styled_label);
    try writer.writeAll(styled_time);
    return out.toOwnedSlice();
}

fn renderBubble(allocator: std.mem.Allocator, content: []const u8, open: []const u8, align_right: bool, width: usize) ![]u8 {
    if (content.len == 0) return allocator.dupe(u8, "");

    const needle = "\x1b[0m";
    const repl = try std.fmt.allocPrint(allocator, "{s}{s}", .{ needle, open });
    const reasserted = try std.mem.replaceOwned(u8, allocator, content, needle, repl);

    const max_content = width -| 2;
    var content_w: usize = 0;
    {
        var lines = std.mem.splitScalar(u8, reasserted, '\n');
        while (lines.next()) |line| content_w = @max(content_w, tui_text.visibleWidth(line));
    }
    content_w = @min(content_w, max_content);
    const left_margin = if (align_right) width -| (content_w + 2) else 0;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var lines = std.mem.splitScalar(u8, reasserted, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try writer.writeByte('\n');
        first = false;
        try writeSpaces(writer, left_margin);
        try writer.writeAll(open);
        try writer.writeByte(' ');
        try writer.writeAll(line);
        try writer.writeAll(open);
        const pad = content_w -| tui_text.visibleWidth(line);
        try writeSpaces(writer, pad);
        try writer.writeByte(' ');
        try writer.writeAll(zz.ansi.reset);
    }
    return out.toOwnedSlice();
}

fn renderCard(allocator: std.mem.Allocator, kind: TranscriptKind, tool_name: []const u8, text: []const u8, width: usize) ![]const u8 {
    const content_width = @max(width -| 4, 8);
    const truncated = try tui_text.truncateLinesToWidth(allocator, text, content_width, std.math.maxInt(usize));
    const body_style = if (kind == .tool and tool_name.len > 0) tui_theme.toolBody(tool_name) else tui_theme.bodyStyle(kind);
    const styled = try styleEachLine(allocator, body_style, truncated);
    const card = tui_theme.panel()
        .borderForeground(roleColor(kind, tool_name))
        .width(@intCast(@min(content_width, std.math.maxInt(u16))));
    return card.render(allocator, styled);
}

fn styleEachLine(allocator: std.mem.Allocator, style: zz.Style, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try writer.writeByte('\n');
        first = false;
        if (line.len == 0) continue;
        const styled = try style.render(allocator, line);
        defer allocator.free(styled);
        try writer.writeAll(styled);
    }
    return out.toOwnedSlice();
}

fn openSgr(allocator: std.mem.Allocator, fg: zz.Color, bg: zz.Color) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try fg.writeFg(&out.writer);
    try bg.writeBg(&out.writer);
    return out.toOwnedSlice();
}

fn formatTimestamp(allocator: std.mem.Allocator, ts_ms: i64) ![]u8 {
    if (ts_ms <= 0) return allocator.dupe(u8, "");
    const secs: u64 = @intCast(@divFloor(ts_ms, 1000));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const day_secs = epoch_seconds.getDaySeconds();
    const hh = day_secs.getHoursIntoDay();
    const mm = day_secs.getMinutesIntoHour();
    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}", .{ hh, mm });
}

fn roleName(kind: TranscriptKind) []const u8 {
    return switch (kind) {
        .user => "You",
        .assistant => "Makai",
        .thinking => "Thinking",
        .tool => "Tool",
        .system => "System",
        .@"error" => "Error",
    };
}

fn roleColor(kind: TranscriptKind, tool_name: []const u8) zz.Color {
    return switch (kind) {
        .user => tui_theme.palette.user,
        .assistant => tui_theme.palette.assistant,
        .thinking => tui_theme.palette.thinking,
        .tool => if (tool_name.len > 0) tui_theme.toolColorForName(tool_name) else tui_theme.palette.tool,
        .system => tui_theme.palette.panel_border,
        .@"error" => tui_theme.palette.danger,
    };
}

fn inferredToolName(text: []const u8) []const u8 {
    if (std.mem.startsWith(u8, text, "◈ ")) return firstToolNameToken(text["◈ ".len..]);
    return firstToolNameToken(text);
}

fn inferredToolTitle(text: []const u8) []const u8 {
    if (std.mem.startsWith(u8, text, "◈ ")) {
        const rest = text["◈ ".len..];
        const quote = std.mem.indexOfScalar(u8, rest, '"') orelse rest.len;
        const status = std.mem.indexOf(u8, rest, " ok ") orelse std.mem.indexOf(u8, rest, " failed ") orelse quote;
        const end = @min(quote, status);
        return std.mem.trim(u8, rest[0..end], " \t\r\n");
    }
    return "";
}

fn firstToolNameToken(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and std.ascii.isWhitespace(text[start])) start += 1;
    var end = start;
    while (end < text.len) : (end += 1) {
        const c = text[end];
        if (std.ascii.isWhitespace(c) or c == '"' or c == '[' or c == '{' or c == '(') break;
    }
    return text[start..end];
}

fn lineWindow(allocator: std.mem.Allocator, text: []const u8, height: usize, scroll: usize) ![]u8 {
    const total = tui_text.lineCount(text);
    if (total <= height and scroll == 0) return allocator.dupe(u8, text);
    const visible = @min(height, total);
    const max_start = total - visible;
    const start_line = max_start -| scroll;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_index: usize = 0;
    var written: usize = 0;
    while (lines.next()) |line| : (line_index += 1) {
        if (line_index < start_line) continue;
        if (written >= visible) break;
        if (written > 0) try writer.writeByte('\n');
        try writer.writeAll(line);
        written += 1;
    }
    return out.toOwnedSlice();
}

fn writeSpaces(writer: *std.Io.Writer, count: usize) !void {
    for (0..count) |_| try writer.writeByte(' ');
}

fn renderedLineContaining(text: []const u8, needle: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) return line;
    }
    return null;
}

fn colorFg(allocator: std.mem.Allocator, color: zz.Color) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try color.writeFg(&out.writer);
    return out.toOwnedSlice();
}

test "transcript renders labels" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendUserMessage("hello");
    try state.appendTranscript(.assistant, "world");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "You") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Makai") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "world") != null);
}

test "transcript renders chat-style alignment and cards" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.system, "system notice");
    try state.appendTranscript(.assistant, "assistant reply");
    try state.appendUserMessage("user reply");
    for (state.transcript.items) |*entry| entry.timestamp_ms = 3_720_000;

    const text = try render(std.testing.allocator, &state, .{ .width = 48, .height = 14 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "System") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Makai") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "You") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "01:02") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{256d}") != null);

    const assistant_line = renderedLineContaining(text, "assistant reply").?;
    try std.testing.expect(std.mem.startsWith(u8, assistant_line, "   "));

    const user_line = renderedLineContaining(text, "user reply").?;
    try std.testing.expect(std.mem.startsWith(u8, user_line, "          "));
    try std.testing.expectEqual(@as(usize, 46), tui_text.visibleWidth(user_line));
}

test "transcript aligns error card content with role label text" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.@"error", "ProviderStreamError");
    state.transcript.items[0].timestamp_ms = 3_720_000;

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 8 });
    defer std.testing.allocator.free(text);

    const header_line = renderedLineContaining(text, "Error").?;
    const error_line = renderedLineContaining(text, "ProviderStreamError").?;
    const label_col = tui_text.visibleWidth(header_line[0..std.mem.indexOf(u8, header_line, "Error").?]);
    const text_col = tui_text.visibleWidth(error_line[0..std.mem.indexOf(u8, error_line, "ProviderStreamError").?]);
    try std.testing.expectEqual(label_col, text_col);
}

test "transcript renders clock timestamp" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendUserMessage("hi");
    for (state.transcript.items) |*entry| entry.timestamp_ms = 1779978720 * 1000;

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 8 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "14:32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2026") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "05-28") == null);
}

test "single entry helper renders clock timestamp" {
    var entry = try TranscriptEntry.init(std.testing.allocator, .assistant, "hello");
    defer entry.deinit(std.testing.allocator);
    entry.timestamp_ms = 1779978720 * 1000;

    const rendered = try renderTranscriptEntry(std.testing.allocator, &entry, 80);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "14:32") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "2026") == null);
}

test "transcript preserves multiline entries" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "alpha\nbeta");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "beta") != null);
}

test "transcript renders backpressure warning" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.@"error", "Warning: 2 events dropped due to backpressure");

    const text = try render(std.testing.allocator, &state, .{ .width = 100, .height = 20 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Warning: 2 events dropped due to backpressure") != null);
}

test "transcript collapses tool events into intent row without card" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(
        std.testing.allocator,
        "call-1",
        "shell_execute",
        "Shell Execute",
        "{\"description\":\"Run pwd to show current working directory\",\"command\":\"pwd\",\"workspace_root\":\"/tmp\"}",
        .done,
    ));
    state.tools.items[0].returned_total_bytes = 342;
    state.tools.items[0].raw_total_bytes = 342;
    state.tools.items[0].estimated_returned_tokens = 87;

    try state.appendToolSummaryTranscript("◈ Shell Execute \"Run pwd to show current working directory\" ok raw=342B returned=342B ~87 tok");
    try state.appendTranscript(.tool, "◈ not-a-summary tool output row");
    try state.appendTranscript(.tool, "ok stdout=43 stderr=0");

    const text = try render(std.testing.allocator, &state, .{ .width = 120, .height = 20 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Shell Execute") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Tool") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{25b8} Run pwd to show current working directory [ok, 342B, ~87 tok]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "{\"command\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "not-a-summary") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ok stdout=43 stderr=0") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{256d}") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{2570}") == null);
}

test "transcript balanced mode sanitizes tool descriptions" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(
        std.testing.allocator,
        "call-1",
        "shell_execute",
        "Shell Execute",
        "{\"description\":\"before\\u001b[2Jafter\\u0007\",\"command\":\"pwd\"}",
        .done,
    ));
    try state.appendToolSummaryTranscript("◈ Shell Execute \"before\"");

    const text = try render(std.testing.allocator, &state, .{ .width = 120, .height = 20 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0x07) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "before[2Jafter") != null);
}

test "transcript balanced mode preserves tool call order across turns" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(
        std.testing.allocator,
        "call-1",
        "shell_execute",
        "Shell Execute",
        "{\"description\":\"Inspect pwd now\",\"command\":\"pwd\"}",
        .done,
    ));
    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(
        std.testing.allocator,
        "call-2",
        "shell_execute",
        "Shell Execute",
        "{\"description\":\"Inspect uname now\",\"command\":\"uname -a\"}",
        .done,
    ));

    try state.appendUserMessage("first request");
    try state.appendToolSummaryTranscript("◈ Shell Execute \"Inspect pwd now\" ok output=10B");
    try state.appendTranscript(.assistant, "PWD done");
    try state.appendUserMessage("second request");
    try state.appendToolSummaryTranscript("◈ Shell Execute \"Inspect uname now\" ok output=20B");
    try state.appendTranscript(.assistant, "UNAME done");

    const text = try render(std.testing.allocator, &state, .{ .width = 140, .height = 30 });
    defer std.testing.allocator.free(text);

    const first_user = std.mem.indexOf(u8, text, "first request") orelse return error.MissingFirstUser;
    const first_tool = std.mem.indexOf(u8, text, "Inspect pwd now") orelse return error.MissingFirstTool;
    const first_answer = std.mem.indexOf(u8, text, "PWD done") orelse return error.MissingFirstAnswer;
    const second_user = std.mem.indexOf(u8, text, "second request") orelse return error.MissingSecondUser;
    const second_tool = std.mem.indexOf(u8, text, "Inspect uname now") orelse return error.MissingSecondTool;
    const second_answer = std.mem.indexOf(u8, text, "UNAME done") orelse return error.MissingSecondAnswer;

    try std.testing.expect(first_user < first_tool);
    try std.testing.expect(first_tool < first_answer);
    try std.testing.expect(first_answer < second_user);
    try std.testing.expect(second_user < second_tool);
    try std.testing.expect(second_tool < second_answer);
}


test "transcript colors tool cards by inferred operation" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.tool, "◈ shell_execute \"ls\"");
    try state.appendTranscript(.tool, "◈ file_read \"src/main.zig\"");

    const text = try render(std.testing.allocator, &state, .{ .width = 100, .height = 20 });
    defer std.testing.allocator.free(text);

    const shell_open = try colorFg(std.testing.allocator, tui_theme.toolColorForName("shell_execute"));
    defer std.testing.allocator.free(shell_open);
    const read_open = try colorFg(std.testing.allocator, tui_theme.toolColorForName("file_read"));
    defer std.testing.allocator.free(read_open);

    try std.testing.expect(std.mem.indexOf(u8, text, shell_open) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, read_open) != null);
    try std.testing.expect(!std.mem.eql(u8, shell_open, read_open));
}

test "transcript renders assistant markdown syntax literally" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "# Heading\n- item");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "# Heading") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- item") != null);
}

test "transcript keeps assistant code indentation" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "```zig\n    const x = 1;\n```\n");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "    const x") != null);
}

test "transcript caps rendered lines to height" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "one\ntwo\nthree\nfour");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 2 });
    defer std.testing.allocator.free(text);

    try std.testing.expectEqual(@as(usize, 2), tui_text.lineCount(text));
    try std.testing.expect(std.mem.indexOf(u8, text, "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "four") != null);
}

test "transcript preserves non-assistant whitespace" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.tool, "  alpha   beta\n    gamma");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "  alpha   beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    gamma") != null);
}

test "transcript shows scroll indicator when scrolled up" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    for (0..20) |i| {
        const msg = try std.fmt.allocPrint(std.testing.allocator, "line {d}", .{i});
        defer std.testing.allocator.free(msg);
        try state.appendTranscript(.assistant, msg);
    }
    state.transcript_scroll = 5;

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 5 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "SCROLL") != null);
}

test "transcript hides scroll indicator when at bottom" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    for (0..10) |i| {
        const msg = try std.fmt.allocPrint(std.testing.allocator, "line {d}", .{i});
        defer std.testing.allocator.free(msg);
        try state.appendTranscript(.assistant, msg);
    }
    state.transcript_scroll = 0;

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 5 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "SCROLL") == null);
}

test "transcript keeps one-line viewport within height when scrolled" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "one\ntwo\nthree");
    state.transcript_scroll = 1;

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 1 });
    defer std.testing.allocator.free(text);

    try std.testing.expectEqual(@as(usize, 1), tui_text.lineCount(text));
    try std.testing.expect(std.mem.indexOf(u8, text, "SCROLL") == null);
}

test "transcript wraps assistant list text plainly" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "- first second third");

    const text = try render(std.testing.allocator, &state, .{ .width = 15, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "- first") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "second") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "third") != null);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(tui_text.visibleWidth(line) <= 15);
    }
}

test "transcript renders inline code markers literally" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "use `code` here");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "`code`") != null);
}

test "transcript dims and indents fenced code block" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "```zig\n    const x = 1;\n```\n");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    const code_line = renderedLineContaining(text, "const x = 1;").?;
    try std.testing.expect(std.mem.indexOf(u8, text, "```zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "```") == null);
    try std.testing.expect(std.mem.indexOf(u8, code_line, "const x = 1;") != null);

    const dim_probe = try tui_theme.dim().render(std.testing.allocator, "x");
    defer std.testing.allocator.free(dim_probe);
    const x_index = std.mem.indexOf(u8, dim_probe, "x").?;
    try std.testing.expect(std.mem.indexOf(u8, code_line, dim_probe[0..x_index]) != null);
}

test "transcript wraps assistant text within viewport width" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "alpha beta gamma delta epsilon zeta eta theta");

    const text = try render(std.testing.allocator, &state, .{ .width = 30, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(tui_text.lineCount(text) > 1);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(tui_text.visibleWidth(line) <= 30);
    }
}

test "transcript hard-splits overlong assistant words" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "see https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaa/path");

    const text = try render(std.testing.allocator, &state, .{ .width = 30, .height = 12 });
    defer std.testing.allocator.free(text);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(tui_text.visibleWidth(line) <= 30);
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "aaaa") != null);
}

test "transcript preserves whitespace in plain assistant text" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "  indented  double");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "  indented  double") != null);
}

test "transcript expands tabs to column stops in plain assistant text" {
    const out = try renderAssistantPlain(std.testing.allocator, "a:\tvalue", 40);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "a:      value") != null);
}

test "transcript drops the empty wrap row after trailing hard-break spaces" {
    const out = try renderAssistantPlain(std.testing.allocator, "exactfill  ", 9);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("exactfill", out);

    const wrapped = try renderAssistantPlain(std.testing.allocator, "exactfill abc", 9);
    defer std.testing.allocator.free(wrapped);
    try std.testing.expectEqualStrings("exactfill\nabc", wrapped);
}

test "transcript clears the deferred newline after emitting it" {
    const out = try renderAssistantPlain(std.testing.allocator, "exactfill abcdefghij", 9);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("exactfill\nabcdefghi\nj", out);
}

test "transcript hard-splits leading-space words without a blank row" {
    const out = try renderAssistantPlain(std.testing.allocator, " abcdefghij", 9);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(" abcdefgh\nij", out);
}

test "transcript hard-splits indented words without whitespace rows" {
    const out = try renderAssistantPlain(std.testing.allocator, "    abcdefghij", 9);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("    abcde\nfghij", out);
}

test "transcript allows tildes in tilde-fence info strings" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "~~~lang~variant\ninside\n~~~\nafter");

    const text = try render(std.testing.allocator, &state, .{ .width = 40, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "inside") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "~~~") == null);
}

test "transcript drops malformed multibyte leads without passing controls" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try wrapPlainLine(std.testing.allocator, &out.writer, "a\xC2\x1B[2Jb", 40);

    try std.testing.expectEqualStrings("ab", out.written());
}

test "transcript keeps expanded tabs within the wrap width" {
    const out = try renderAssistantPlain(std.testing.allocator, "12345678\tX", 8);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("12345678\n        \nX", out);

    const wrapped = try renderAssistantPlain(std.testing.allocator, "abc\tdef", 8);
    defer std.testing.allocator.free(wrapped);
    try std.testing.expectEqualStrings("abc     \ndef", wrapped);
}

test "transcript matches closing fence to opener length" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "````\nline ``` inside\nmore\n````\nafter");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 14 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "line ``` inside") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "more") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "````") == null);
}

test "transcript closes code fence on CRLF endings" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "```zig\r\nconst x = 1;\r\n```\r\nafter");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 12 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "const x = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "```") == null);
}

test "transcript detects tilde code fences" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "~~~text\ninside\n~~~\nafter");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 12 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "inside") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "~~~") == null);
}

test "transcript does not open a fence from inline code spans" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "```code``` then text\nplain");

    const text = try render(std.testing.allocator, &state, .{ .width = 40, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "```code```") != null);
}

test "transcript caps fence opener indent at three spaces" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "    ```\nplain line");

    const text = try render(std.testing.allocator, &state, .{ .width = 40, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "```") != null);
}

test "transcript does not close a fence from a four-space closer" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "```\ninside\n    ```\nafter");

    const text = try render(std.testing.allocator, &state, .{ .width = 40, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "```") != null);
}

test "transcript strips escape sequences from plain assistant text" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "before\x1b[2Jafter");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "after") != null);
}

test "transcript renders math markers literally" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "energy is $E = mc^2$ here");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "$E = mc^2$") != null);
}

test "transcript renders fenced block contents without the fence markers" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "Diagram:\n\n```mermaid\nflowchart TD\n  A --> B\n```\n\nend");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 14 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Diagram:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "flowchart TD") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "A --> B") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "end") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "```") == null);
}

test "expandTabs pads to the next eight-column stop" {
    const out = try expandTabs(std.testing.allocator, "a:\tvalue\tend");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a:      value   end", out);
}

test "expandTabs measures wide codepoints by display width" {
    const out = try expandTabs(std.testing.allocator, "中文\tx");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("中文    x", out);
    try std.testing.expectEqual(@as(usize, 8), tui_text.visibleWidth(out[0 .. out.len - 1]));
}

test "stripControls drops C1 control codepoints" {
    const out = try stripControls(std.testing.allocator, "a\u{009b}b\u{0085}c");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("abc", out);
}

test "stripControls drops raw C1 bytes" {
    const out = try stripControls(std.testing.allocator, "a\x9bb\x85c");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("abc", out);
}

test "stripControls keeps multibyte text outside C1" {
    const out = try stripControls(std.testing.allocator, "héllo→世界");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("héllo→世界", out);
}

test "transcript strips C1 controls from plain assistant text" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "before\u{009b}after");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "\u{009b}") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "beforeafter") != null);
}

test "transcript expands fenced tabs before rendering" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "```\na:\tvalue\n```");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    const code_line = renderedLineContaining(text, "value").?;
    try std.testing.expect(std.mem.indexOfScalar(u8, code_line, '\t') == null);
    try std.testing.expect(std.mem.indexOf(u8, code_line, "a:      value") != null);
}

test "transcript expands fenced tabs and clips to bubble width" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "```\n\t" ++ ("x" ** 60) ++ "\n```");

    const text = try render(std.testing.allocator, &state, .{ .width = 40, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOfScalar(u8, text, '\t') == null);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(tui_text.visibleWidth(line) <= 40);
    }
}
