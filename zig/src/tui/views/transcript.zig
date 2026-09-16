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
    anim_tick: u64 = 0,
};

pub const EntryOptions = struct {
    live: bool = false,
    anim_tick: u64 = 0,
    awaiting_approval: bool = false,
};

const DisplayEntry = struct {
    kind: TranscriptKind,
    text: []const u8,
    timestamp_ms: i64,
    tool_name: []const u8 = "",
    title: []const u8 = "",
    tool_summary: bool = false,
    tool_status: ?ToolRowStatus = null,
    live: bool = false,
    anim_tick: u64 = 0,
    awaiting_approval: bool = false,
};

const gutter_left: usize = 1;
const body_indent: usize = 3;
const chat_max_column: usize = 108;
const max_result_rows: usize = 8;
const max_thinking_rows: usize = 10;
const max_live_thinking_rows: usize = 6;
const summary_prefix = "\u{25c8} ";

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
            const attached = displayEntriesAttached(&visible_entries.items[i - 1], entry);
            try all_writer.writeAll(if (attached) "\n" else "\n\n");
            if (!attached) current_line += 1;
        }
        entry.anim_tick = options.anim_tick;
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
    return renderTranscriptEntryWith(allocator, entry, width, .{});
}

pub fn renderTranscriptEntryWith(allocator: std.mem.Allocator, entry: *const TranscriptEntry, width: usize, options: EntryOptions) ![]u8 {
    var display = DisplayEntry{
        .kind = entry.kind,
        .text = entry.text.items,
        .timestamp_ms = entry.timestamp_ms,
        .tool_name = if (entry.kind == .tool) inferredToolName(entry.text.items) else "",
        .title = if (entry.kind == .tool) inferredToolTitle(entry.text.items) else "",
        .tool_summary = entry.tool_summary or parseToolSummary(entry.text.items) != null,
        .live = options.live,
        .anim_tick = options.anim_tick,
        .awaiting_approval = options.awaiting_approval,
    };
    return renderEntry(allocator, &display, width);
}

pub fn entriesAttached(previous: *const TranscriptEntry, next: *const TranscriptEntry) bool {
    return previous.kind == .tool and next.kind == .tool;
}

pub fn renderWaitingLine(allocator: std.mem.Allocator, model: []const u8, anim_tick: u64, elapsed_ms: u64) ![]u8 {
    const glyph = try tui_theme.role(.assistant).render(allocator, tui_theme.glyph.assistant ++ " Makai");
    defer allocator.free(glyph);
    const spinner = try tui_theme.runningText().render(allocator, tui_theme.spinnerFrame(anim_tick));
    defer allocator.free(spinner);
    const label = if (elapsed_ms >= 1000)
        try std.fmt.allocPrint(allocator, "waiting for {s} · {d}s", .{ if (model.len > 0) model else "the model", elapsed_ms / 1000 })
    else
        try std.fmt.allocPrint(allocator, "waiting for {s}…", .{if (model.len > 0) model else "the model"});
    defer allocator.free(label);
    const styled_label = try tui_theme.muted().render(allocator, label);
    defer allocator.free(styled_label);
    return std.fmt.allocPrint(allocator, " {s} {s} {s}", .{ glyph, spinner, styled_label });
}

fn displayEntriesAttached(previous: *const DisplayEntry, next: *const DisplayEntry) bool {
    return previous.kind == .tool and next.kind == .tool;
}

fn buildVisibleEntries(allocator: std.mem.Allocator, arena: std.mem.Allocator, state: *const AppState, entries: *std.ArrayList(DisplayEntry)) !void {
    var tool_index = std.StringHashMap(*const tui_state.ToolEntry).init(arena);
    for (state.tools.items) |*tool| {
        try tool_index.put(tool.id, tool);
    }
    var i: usize = 0;
    while (i < state.transcript.items.len) {
        const entry = &state.transcript.items[i];
        if (entry.kind == .tool) {
            const cluster_start = i;
            while (i < state.transcript.items.len and state.transcript.items[i].kind == .tool) : (i += 1) {}
            try appendToolClusterRows(allocator, arena, entries, state, &tool_index, cluster_start, i);
            continue;
        }
        try appendOriginal(allocator, entries, entry, null);
        i += 1;
    }
}

fn appendToolClusterRows(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    entries: *std.ArrayList(DisplayEntry),
    state: *const AppState,
    tool_index: *std.StringHashMap(*const tui_state.ToolEntry),
    start: usize,
    end: usize,
) !void {
    for (state.transcript.items[start..end]) |*entry| {
        const tool = if (entry.tool_call_id.len > 0) tool_index.get(entry.tool_call_id) else null;
        if (entry.tool_summary) {
            if (tool) |found| {
                try appendToolSummary(allocator, arena, entries, found.*);
                continue;
            }
            try appendOriginal(allocator, entries, entry, null);
            continue;
        }
        if (tool) |found| {
            if (found.status == .done) continue;
            if (found.status == .@"error" and found.error_detail_readable) continue;
            try appendOriginal(allocator, entries, entry, found.*);
            continue;
        }
        try appendOriginal(allocator, entries, entry, null);
    }
}

fn appendOriginal(allocator: std.mem.Allocator, entries: *std.ArrayList(DisplayEntry), entry: *const TranscriptEntry, tool: ?tui_state.ToolEntry) !void {
    try entries.append(allocator, .{
        .kind = entry.kind,
        .text = entry.text.items,
        .timestamp_ms = entry.timestamp_ms,
        .tool_name = if (entry.kind == .tool) (if (tool) |found| found.name else inferredToolName(entry.text.items)) else "",
        .title = if (entry.kind == .tool) (if (tool) |found| found.label else inferredToolTitle(entry.text.items)) else "",
        .tool_summary = entry.tool_summary or (entry.kind == .tool and parseToolSummary(entry.text.items) != null),
        .tool_status = if (tool) |found| toolRowStatus(found.status) else null,
    });
}

fn toolRowStatus(status: tui_state.ToolStatus) ToolRowStatus {
    return switch (status) {
        .pending, .running => .running,
        .done => .ok,
        .@"error" => .failed,
        .interrupted => .interrupted,
    };
}

fn appendToolSummary(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    entries: *std.ArrayList(DisplayEntry),
    tool: tui_state.ToolEntry,
) !void {
    const intent = try invocationDescription(arena, tool.args_json);
    const status: []const u8 = switch (tool.status) {
        .pending, .running => "",
        .done => " ok",
        .@"error" => " failed",
        .interrupted => " interrupted",
    };

    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.writeAll(summary_prefix);
    try writer.writeAll(tool.label);
    if (intent) |value| if (value.len > 0) try writer.print(" \"{s}\"", .{value});
    try writer.writeAll(status);
    if (tool.status == .done or tool.status == .@"error") {
        if (tool.raw_total_bytes > 0 or tool.returned_total_bytes > 0) {
            try writer.print(" raw={d}B returned={d}B", .{ tool.raw_total_bytes, tool.returned_total_bytes });
        } else if (tool.output.items.len > 0) {
            try writer.print(" output={d}B", .{tool.output.items.len});
        }
        if (tool.estimated_returned_tokens > 0) try writer.print(" ~{d} tok", .{tool.estimated_returned_tokens});
        if (tool.artifact_count > 0) try writer.print(" artifacts={d} on disk", .{tool.artifact_count});
        if (tool.raw_total_bytes > tool.returned_total_bytes or tool.artifact_count > 0) try writer.writeAll(" preview-capped");
    }

    try entries.append(allocator, .{
        .kind = .tool,
        .text = out.written(),
        .timestamp_ms = 0,
        .tool_name = tool.name,
        .title = tool.label,
        .tool_summary = true,
        .tool_status = toolRowStatus(tool.status),
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

pub fn scrollPercent(total_lines: usize, view_height: usize, scroll: usize) usize {
    if (total_lines <= view_height) return 0;
    const max_scroll = total_lines - view_height;
    const clamped = @min(scroll, max_scroll);
    return clamped * 100 / max_scroll;
}

fn bodyWidth(width: usize) usize {
    if (width <= 24) return width;
    return @min(width -| (body_indent + 1), chat_max_column);
}

fn bodyIndent(width: usize) usize {
    return if (width <= 24) 0 else body_indent;
}

fn gutterFor(width: usize) usize {
    return if (width <= 24) 0 else gutter_left;
}

fn renderEntry(allocator: std.mem.Allocator, entry: *const DisplayEntry, width: usize) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body_w = bodyWidth(width);
    const indent = bodyIndent(width);

    const rendered: []const u8 = switch (entry.kind) {
        .welcome => try renderWelcome(arena, entry.text, width),
        .tool => if (entry.tool_summary)
            try renderToolSummaryRow(arena, entry, width)
        else
            try indentBlock(arena, try renderToolResult(arena, entry.text, body_w), indent),
        .system => if (std.mem.indexOfScalar(u8, entry.text, '\n') == null and tui_text.visibleWidth(entry.text) <= systemLineBudget(width))
            try renderSystemLine(arena, entry.text, width)
        else
            try renderHeaderedBody(arena, entry, width, try renderSystemBody(arena, entry.text, body_w)),
        .@"error" => try renderHeaderedBody(arena, entry, width, try renderWrappedLines(arena, tui_theme.errorBody(), entry.text, body_w)),
        .thinking => try renderHeaderedBody(arena, entry, width, try renderThinkingBody(arena, entry, body_w)),
        .user => try renderHeaderedBody(arena, entry, width, try renderUserBlock(arena, entry.text, body_w)),
        .assistant => try renderHeaderedBody(arena, entry, width, try renderAssistantBody(arena, entry, body_w)),
    };
    return allocator.dupe(u8, rendered);
}

fn renderHeaderedBody(allocator: std.mem.Allocator, entry: *const DisplayEntry, width: usize, body_inner: []const u8) ![]u8 {
    const header = try renderHeader(allocator, entry, width);
    const body = try indentBlock(allocator, body_inner, bodyIndent(width));
    if (body.len == 0) return header;
    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ header, body });
}

fn renderHeader(allocator: std.mem.Allocator, entry: *const DisplayEntry, width: usize) ![]u8 {
    const name = roleName(entry.kind);
    const label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ tui_theme.roleGlyph(entry.kind), name });
    const styled_label = try tui_theme.role(entry.kind).render(allocator, label);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    for (0..gutterFor(width)) |_| try writer.writeByte(' ');
    try writer.writeAll(styled_label);
    if (entry.live and (entry.kind == .assistant or entry.kind == .thinking)) {
        const spinner = try tui_theme.runningText().render(allocator, tui_theme.spinnerFrame(entry.anim_tick));
        try writer.writeByte(' ');
        try writer.writeAll(spinner);
        return out.toOwnedSlice();
    }
    const clock = try formatTimestamp(allocator, entry.timestamp_ms);
    if (clock.len > 0) {
        const time = try std.fmt.allocPrint(allocator, " {s} {s}", .{ tui_theme.glyph.dot, clock });
        const styled_time = try tui_theme.dim().render(allocator, time);
        try writer.writeAll(styled_time);
    }
    return out.toOwnedSlice();
}

fn systemLineBudget(width: usize) usize {
    return width -| (gutterFor(width) + 2);
}

fn renderSystemLine(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    const clipped = try tui_text.truncateLineToWidth(allocator, text, systemLineBudget(width));
    const glyph = try tui_theme.dim().render(allocator, tui_theme.glyph.system);
    const styled = try tui_theme.systemText().render(allocator, clipped);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (0..gutterFor(width)) |_| try out.writer.writeByte(' ');
    try out.writer.writeAll(glyph);
    try out.writer.writeByte(' ');
    try out.writer.writeAll(styled);
    return out.toOwnedSlice();
}

fn renderSystemBody(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    const max_width = @max(width, 8);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var first = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!first) try out.writer.writeByte('\n');
        first = false;
        try writeWrappedSystemLine(allocator, &out.writer, line, max_width);
    }
    return out.toOwnedSlice();
}

fn writeWrappedSystemLine(allocator: std.mem.Allocator, writer: *std.Io.Writer, line: []const u8, max_width: usize) !void {
    var row_width: usize = 0;
    var words = std.mem.tokenizeAny(u8, line, " \t\r");
    while (words.next()) |word| {
        const url: ?[]const u8 = if (isUrl(word)) word else null;
        var remaining = word;
        while (remaining.len > 0) {
            const sep: usize = if (row_width > 0) 1 else 0;
            var available = max_width -| (row_width + sep);
            if (row_width > 0 and tui_text.visibleWidth(remaining) > available) {
                try writer.writeByte('\n');
                row_width = 0;
                available = max_width;
            }
            const take = prefixByWidth(remaining, available);
            const chunk = remaining[0..take];
            if (row_width > 0) {
                try writer.writeByte(' ');
                row_width += 1;
            }
            try writeSystemSegment(allocator, writer, chunk, url);
            row_width += tui_text.visibleWidth(chunk);
            remaining = remaining[take..];
        }
    }
}

fn writeSystemSegment(allocator: std.mem.Allocator, writer: *std.Io.Writer, chunk: []const u8, url: ?[]const u8) !void {
    if (url) |target| {
        const styled = try tui_theme.link().render(allocator, chunk);
        defer allocator.free(styled);
        try writer.print("\x1b]8;id=makai-{x};{s}\x1b\\{s}\x1b]8;;\x1b\\", .{ std.hash.Wyhash.hash(0, target), target, styled });
        return;
    }
    const styled = try tui_theme.systemText().render(allocator, chunk);
    defer allocator.free(styled);
    try writer.writeAll(styled);
}

fn isUrl(word: []const u8) bool {
    inline for (.{ "https://", "http://" }) |scheme| {
        if (word.len > scheme.len and std.ascii.startsWithIgnoreCase(word, scheme)) return true;
    }
    return false;
}

fn prefixByWidth(text: []const u8, max_width: usize) usize {
    var i: usize = 0;
    var used: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(text.len, i + len);
        const codepoint: u21 = std.unicode.utf8Decode(text[i..end]) catch text[i];
        const cell_width = zz.measure.charWidth(@intCast(codepoint));
        if (i > 0 and used + cell_width > max_width) break;
        used += cell_width;
        i = end;
    }
    return i;
}

fn renderWrappedLines(allocator: std.mem.Allocator, style: zz.Style, text: []const u8, width: usize) ![]u8 {
    const plain = try renderAssistantPlain(allocator, text, @max(width, 8));
    return styleEachLine(allocator, style, plain);
}

fn renderUserBlock(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    const budget = @max(width -| 2, 8);
    const wrapped = try renderAssistantPlain(allocator, text, budget);
    if (wrapped.len == 0) return allocator.dupe(u8, "");
    var block_w: usize = 0;
    {
        var lines = std.mem.splitScalar(u8, wrapped, '\n');
        while (lines.next()) |line| block_w = @max(block_w, tui_text.visibleWidth(line));
    }
    block_w = @min(block_w, budget);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var lines = std.mem.splitScalar(u8, wrapped, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try writer.writeByte('\n');
        first = false;
        const padded = try std.fmt.allocPrint(allocator, " {s}{s} ", .{ line, try spaces(allocator, block_w -| tui_text.visibleWidth(line)) });
        const styled = try tui_theme.userBlock().render(allocator, padded);
        try writer.writeAll(styled);
    }
    return out.toOwnedSlice();
}

fn spaces(allocator: std.mem.Allocator, count: usize) ![]u8 {
    const buf = try allocator.alloc(u8, count);
    @memset(buf, ' ');
    return buf;
}

fn renderThinkingBody(allocator: std.mem.Allocator, entry: *const DisplayEntry, width: usize) ![]u8 {
    const plain = try renderAssistantPlain(allocator, entry.text, @max(width, 8));
    const cap: usize = if (entry.live) max_live_thinking_rows else max_thinking_rows;
    const clipped = if (entry.live) try tailRows(allocator, plain, cap) else try headRows(allocator, plain, cap);
    return styleEachLine(allocator, tui_theme.bodyStyle(.thinking), clipped);
}

fn renderAssistantBody(allocator: std.mem.Allocator, entry: *const DisplayEntry, width: usize) ![]u8 {
    const body = try renderAssistantStyled(allocator, entry.text, @max(width, 8));
    if (!entry.live) return body;
    const caret = try tui_theme.caret().render(allocator, tui_theme.glyph.caret);
    if (body.len == 0) return allocator.dupe(u8, caret);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ body, caret });
}

fn tailRows(allocator: std.mem.Allocator, text: []const u8, max_rows: usize) ![]u8 {
    const total = tui_text.lineCount(text);
    if (total <= max_rows) return allocator.dupe(u8, text);
    var skip = total - max_rows;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const marker = try std.fmt.allocPrint(allocator, "… {d} earlier lines", .{skip});
    try out.writer.writeAll(marker);
    while (lines.next()) |line| {
        if (skip > 0) {
            skip -= 1;
            continue;
        }
        try out.writer.writeByte('\n');
        try out.writer.writeAll(line);
    }
    return out.toOwnedSlice();
}

fn headRows(allocator: std.mem.Allocator, text: []const u8, max_rows: usize) ![]u8 {
    const total = tui_text.lineCount(text);
    if (total <= max_rows) return allocator.dupe(u8, text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var written: usize = 0;
    while (lines.next()) |line| {
        if (written >= max_rows) break;
        if (written > 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(line);
        written += 1;
    }
    const marker = try std.fmt.allocPrint(allocator, "\n… +{d} more lines", .{total - max_rows});
    try out.writer.writeAll(marker);
    return out.toOwnedSlice();
}

fn renderToolResult(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    const content_width = @max(width -| 2, 8);
    const capped = try headRows(allocator, text, max_result_rows);
    const truncated = try tui_text.truncateLinesToWidth(allocator, capped, content_width, std.math.maxInt(usize));
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var lines = std.mem.splitScalar(u8, truncated, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try writer.writeByte('\n');
        const prefix = if (first) tui_theme.glyph.result ++ " " else "  ";
        first = false;
        const styled_prefix = try tui_theme.faint().render(allocator, prefix);
        try writer.writeAll(styled_prefix);
        if (line.len == 0) continue;
        const styled = try tui_theme.muted().render(allocator, line);
        try writer.writeAll(styled);
    }
    return out.toOwnedSlice();
}

const ToolRowStatus = enum { running, ok, failed, interrupted };

const ToolSummary = struct {
    label: []const u8,
    arg: []const u8,
    status: ToolRowStatus,
    stats: []const u8,
};

fn parseToolSummary(text: []const u8) ?ToolSummary {
    return parseToolSummaryAfterLabel(text, "");
}

fn parseToolSummaryAfterLabel(text: []const u8, label: []const u8) ?ToolSummary {
    if (!std.mem.startsWith(u8, text, summary_prefix)) return null;
    const rest = text[summary_prefix.len..];
    if (rest.len == 0) return null;
    const words = [_]struct { word: []const u8, status: ToolRowStatus }{
        .{ .word = "ok", .status = .ok },
        .{ .word = "failed", .status = .failed },
        .{ .word = "interrupted", .status = .interrupted },
    };
    const anchored = label.len > 0 and std.mem.startsWith(u8, rest, label);
    const search_start: usize = if (anchored) label.len else 0;
    var best: ?usize = null;
    var best_status: ToolRowStatus = .running;
    var best_len: usize = 0;
    for (words) |candidate| {
        var search: usize = search_start;
        while (std.mem.indexOfPos(u8, rest, search, candidate.word)) |pos| {
            search = pos + 1;
            if (pos == 0 or rest[pos - 1] != ' ') continue;
            const end = pos + candidate.word.len;
            if (end < rest.len and rest[end] != ' ') continue;
            const head = rest[0 .. pos - 1];
            const quoted = std.mem.indexOfScalar(u8, head, '"') != null;
            if (quoted and (head.len == 0 or head[head.len - 1] != '"')) continue;
            if (best == null or pos < best.?) {
                best = pos;
                best_status = candidate.status;
                best_len = candidate.word.len;
            }
            break;
        }
    }
    var summary = ToolSummary{ .label = rest, .arg = "", .status = .running, .stats = "" };
    var head = rest;
    if (best) |pos| {
        head = rest[0 .. pos - 1];
        summary.status = best_status;
        summary.stats = std.mem.trim(u8, rest[pos + best_len ..], " ");
    }
    if (std.mem.indexOf(u8, head, " \"")) |quote| {
        summary.label = head[0..quote];
        var arg = head[quote + 2 ..];
        if (arg.len > 0 and arg[arg.len - 1] == '"') arg = arg[0 .. arg.len - 1];
        summary.arg = arg;
    } else {
        summary.label = std.mem.trim(u8, head, " ");
    }
    return summary;
}

const ToolStats = struct {
    bytes: ?u64 = null,
    tokens: ?u64 = null,
    artifacts: ?u64 = null,
    capped: bool = false,
    detail: []const u8 = "",
};

fn parseToolStats(stats: []const u8) ToolStats {
    var parsed = ToolStats{};
    if (stats.len == 0) return parsed;
    if (numberAfter(stats, "returned=")) |n| {
        parsed.bytes = n;
    } else if (numberAfter(stats, "output=")) |n| {
        parsed.bytes = n;
    }
    parsed.tokens = numberAfter(stats, "~");
    parsed.artifacts = numberAfter(stats, "artifacts=");
    parsed.capped = std.mem.indexOf(u8, stats, "preview-capped") != null;
    if (std.mem.indexOfScalar(u8, stats, '"')) |open| {
        var detail = stats[open + 1 ..];
        if (detail.len > 0 and detail[detail.len - 1] == '"') detail = detail[0 .. detail.len - 1];
        parsed.detail = detail;
    }
    return parsed;
}

fn numberAfter(text: []const u8, marker: []const u8) ?u64 {
    const pos = std.mem.indexOf(u8, text, marker) orelse return null;
    var i = pos + marker.len;
    var value: u64 = 0;
    var digits: usize = 0;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        value = value *% 10 +% (text[i] - '0');
        digits += 1;
    }
    return if (digits == 0) null else value;
}

fn formatBytes(allocator: std.mem.Allocator, bytes: u64) ![]u8 {
    if (bytes >= 1024 * 1024) return std.fmt.allocPrint(allocator, "{d}.{d}MB", .{ bytes / (1024 * 1024), (bytes % (1024 * 1024)) * 10 / (1024 * 1024) });
    if (bytes >= 1024) return std.fmt.allocPrint(allocator, "{d}.{d}KB", .{ bytes / 1024, (bytes % 1024) * 10 / 1024 });
    return std.fmt.allocPrint(allocator, "{d}B", .{bytes});
}

fn renderToolStatus(allocator: std.mem.Allocator, summary: ToolSummary, anim_tick: u64, awaiting_approval: bool) ![]const u8 {
    if (awaiting_approval and summary.status == .running) {
        return tui_theme.warningText().render(allocator, tui_theme.glyph.pending ++ " awaiting approval");
    }
    const stats = parseToolStats(summary.stats);
    var plain: std.Io.Writer.Allocating = .init(allocator);
    const pw = &plain.writer;
    const glyph: []const u8 = switch (summary.status) {
        .running => tui_theme.spinnerFrame(anim_tick),
        .ok => tui_theme.glyph.check,
        .failed => tui_theme.glyph.cross,
        .interrupted => tui_theme.glyph.stop,
    };
    try pw.writeAll(glyph);
    switch (summary.status) {
        .running => try pw.writeAll(" running"),
        .ok => {},
        .failed => try pw.writeAll(" failed"),
        .interrupted => try pw.writeAll(" interrupted"),
    }
    var parts: usize = 0;
    if (stats.bytes) |bytes| {
        const formatted = try formatBytes(allocator, bytes);
        try pw.print(" {s}", .{formatted});
        parts += 1;
    }
    if (stats.tokens) |tokens| {
        try pw.print("{s}~{d} tok", .{ if (parts > 0) " " ++ tui_theme.glyph.dot ++ " " else " ", tokens });
        parts += 1;
    }
    if (stats.artifacts) |count| {
        try pw.print("{s}{d} artifact{s}", .{ if (parts > 0) " " ++ tui_theme.glyph.dot ++ " " else " ", count, if (count == 1) "" else "s" });
        parts += 1;
    } else if (stats.capped) {
        try pw.print("{s}capped", .{if (parts > 0) " " ++ tui_theme.glyph.dot ++ " " else " "});
        parts += 1;
    }
    const style = switch (summary.status) {
        .running => tui_theme.runningText(),
        .ok => tui_theme.successText(),
        .failed => tui_theme.errorText(),
        .interrupted => tui_theme.warningText(),
    };
    return style.render(allocator, plain.written());
}

fn renderToolSummaryRow(allocator: std.mem.Allocator, entry: *const DisplayEntry, width: usize) ![]u8 {
    var summary = parseToolSummaryAfterLabel(entry.text, entry.title) orelse ToolSummary{ .label = entry.text, .arg = "", .status = .running, .stats = "" };
    if (entry.tool_status) |status| summary.status = status;
    const tool_name = if (entry.tool_name.len > 0) entry.tool_name else summary.label;
    const label_text = if (entry.title.len > 0) entry.title else summary.label;

    const status = try renderToolStatus(allocator, summary, entry.anim_tick, entry.awaiting_approval);
    const status_width = tui_text.visibleWidth(status);
    const glyph = try tui_theme.toolRole(tool_name).render(allocator, tui_theme.glyph.tool);
    const gutter = gutterFor(width);
    const label_budget = width -| (gutter + 2 + 2 + status_width);
    const fitted_label = if (tui_text.visibleWidth(label_text) > label_budget) try tui_text.truncateLineToWidth(allocator, label_text, label_budget) else label_text;
    const label = try tui_theme.toolRole(tool_name).render(allocator, fitted_label);
    const label_width = tui_text.visibleWidth(fitted_label);

    const available = width -| (gutter + 2 + label_width + 2 + status_width + 2);
    var arg_text: []const u8 = "";
    if (summary.arg.len > 0 and available >= 4) {
        arg_text = try tui_text.truncateLineToWidth(allocator, summary.arg, available);
    }
    const styled_arg = try tui_theme.soft().render(allocator, arg_text);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    for (0..gutter) |_| try writer.writeByte(' ');
    try writer.writeAll(glyph);
    try writer.writeByte(' ');
    try writer.writeAll(label);
    var used = gutter + 2 + label_width;
    if (arg_text.len > 0) {
        try writer.writeAll("  ");
        try writer.writeAll(styled_arg);
        used += 2 + tui_text.visibleWidth(arg_text);
    }
    if (used + 2 + status_width <= width) {
        const pad = width - used - status_width - 1;
        for (0..pad) |_| try writer.writeByte(' ');
        try writer.writeAll(status);
    } else {
        try writer.writeAll("  ");
        try writer.writeAll(status);
    }
    return out.toOwnedSlice();
}

fn renderWelcome(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    const box_width = @min(width -| gutter_left, chat_max_column + 4);
    const inner_width = box_width -| 4;
    var body: std.Io.Writer.Allocating = .init(allocator);
    const writer = &body.writer;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    var title_seen = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, " \r");
        if (line.len == 0) continue;
        if (!first) try writer.writeByte('\n');
        first = false;
        if (!title_seen) {
            title_seen = true;
            const title = try std.fmt.allocPrint(allocator, "{s} {s}", .{ tui_theme.glyph.welcome, line });
            try writer.writeAll(try tui_theme.accentStrong().render(allocator, title));
            continue;
        }
        if (std.mem.indexOf(u8, line, ": ")) |colon| {
            const key = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 2 ..], " ");
            if (std.mem.eql(u8, key, "tips")) {
                try writer.writeByte('\n');
                const clipped = try tui_text.truncateLineToWidth(allocator, value, inner_width);
                try writer.writeAll(try tui_theme.keyHint().render(allocator, clipped));
                continue;
            }
            const padded_key = try std.fmt.allocPrint(allocator, "{s: <7}", .{key});
            const clipped = try tui_text.truncateLineToWidth(allocator, value, inner_width -| 8);
            try writer.writeAll(try tui_theme.dim().render(allocator, padded_key));
            try writer.writeByte(' ');
            try writer.writeAll(try tui_theme.soft().render(allocator, clipped));
            continue;
        }
        const clipped = try tui_text.truncateLineToWidth(allocator, line, inner_width);
        try writer.writeAll(try tui_theme.soft().render(allocator, clipped));
    }
    const boxed = try tui_theme.titledPanel(allocator, body.written(), .{ .width = box_width, .border = tui_theme.palette.accent_dim });
    return indentBlock(allocator, boxed, gutter_left);
}

fn indentBlock(allocator: std.mem.Allocator, text: []const u8, count: usize) ![]u8 {
    if (count == 0 or text.len == 0) return allocator.dupe(u8, text);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try writer.writeByte('\n');
        first = false;
        if (line.len == 0) continue;
        try writeSpaces(writer, count);
        try writer.writeAll(line);
    }
    return out.toOwnedSlice();
}

pub fn renderAssistantPlain(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    return renderAssistantText(allocator, text, width, false);
}

fn renderAssistantStyled(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    return renderAssistantText(allocator, text, width, true);
}

const BlockKind = enum { plain, heading, bullet, numbered, quote };

const BlockPrefix = struct {
    kind: BlockKind = .plain,
    content_start: usize = 0,
    marker: []const u8 = "",
    indent: usize = 0,
};

fn detectBlock(line: []const u8) BlockPrefix {
    const ind = lineIndent(line);
    if (ind.width > 3) return .{};
    const rest = line[ind.start..];
    if (rest.len >= 2 and rest[0] == '#') {
        var hashes: usize = 0;
        while (hashes < rest.len and rest[hashes] == '#') hashes += 1;
        if (hashes <= 6 and hashes < rest.len and rest[hashes] == ' ') {
            return .{ .kind = .heading, .content_start = ind.start + hashes + 1, .indent = ind.width };
        }
    }
    if (rest.len >= 2 and (rest[0] == '-' or rest[0] == '*' or rest[0] == '+') and rest[1] == ' ') {
        return .{ .kind = .bullet, .content_start = ind.start + 2, .marker = tui_theme.glyph.bullet, .indent = ind.width };
    }
    if (rest.len >= 2 and rest[0] == '>' and (rest[1] == ' ' or rest.len == 1)) {
        return .{ .kind = .quote, .content_start = ind.start + 2, .marker = tui_theme.glyph.quote_bar, .indent = ind.width };
    }
    var digits: usize = 0;
    while (digits < rest.len and digits < 4 and std.ascii.isDigit(rest[digits])) digits += 1;
    if (digits > 0 and digits + 1 < rest.len and (rest[digits] == '.' or rest[digits] == ')') and rest[digits + 1] == ' ') {
        return .{ .kind = .numbered, .content_start = ind.start + digits + 2, .marker = rest[0 .. digits + 1], .indent = ind.width };
    }
    return .{};
}

fn renderAssistantText(allocator: std.mem.Allocator, text: []const u8, width: usize, styled: bool) ![]u8 {
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
                if (styled and marker.info.len > 0) {
                    if (!first_line) try writer.writeByte('\n');
                    first_line = false;
                    try writeCodeTag(allocator, writer, marker.info, code_width);
                }
                continue;
            }
        } else if (isFenceClose(line, fence_char, fence_len)) {
            in_fence = false;
            continue;
        }
        if (!first_line) try writer.writeByte('\n');
        first_line = false;
        if (!in_fence) {
            if (styled) {
                try writeStyledProseLine(allocator, writer, line, width);
            } else {
                try wrapPlainLine(allocator, writer, line, width);
            }
            continue;
        }
        const cleaned = try stripControls(allocator, line);
        defer allocator.free(cleaned);
        const expanded = try expandTabs(allocator, cleaned);
        defer allocator.free(expanded);
        const clipped = try tui_text.truncateLineToWidth(allocator, expanded, code_width);
        defer allocator.free(clipped);
        if (!styled) {
            if (clipped.len == 0) continue;
            try writer.writeAll("  ");
            const dimmed = try tui_theme.dim().render(allocator, clipped);
            defer allocator.free(dimmed);
            try writer.writeAll(dimmed);
            continue;
        }
        try writer.writeAll("  ");
        const padded = try std.fmt.allocPrint(allocator, "{s}{s}", .{ clipped, try spaces(allocator, code_width -| tui_text.visibleWidth(clipped)) });
        defer allocator.free(padded);
        const block = try tui_theme.codeBlock().render(allocator, padded);
        defer allocator.free(block);
        try writer.writeAll(block);
    }
    return out.toOwnedSlice();
}

fn writeCodeTag(allocator: std.mem.Allocator, writer: *std.Io.Writer, info: []const u8, code_width: usize) !void {
    const clipped = try tui_text.truncateLineToWidth(allocator, info, code_width -| 2);
    defer allocator.free(clipped);
    const padded = try std.fmt.allocPrint(allocator, " {s}{s} ", .{ clipped, try spaces(allocator, code_width -| (tui_text.visibleWidth(clipped) + 2)) });
    defer allocator.free(padded);
    const tag = try tui_theme.codeTag().render(allocator, padded);
    defer allocator.free(tag);
    try writer.writeAll("  ");
    try writer.writeAll(tag);
}

fn writeStyledProseLine(allocator: std.mem.Allocator, writer: *std.Io.Writer, line: []const u8, width: usize) !void {
    const block = detectBlock(line);
    const content = line[block.content_start..];
    const marker_width = if (block.marker.len > 0) tui_text.visibleWidth(block.marker) + 1 else 0;
    const hang = block.indent + marker_width;
    const wrap_width = @max(width -| hang, 8);

    var wrapped: std.Io.Writer.Allocating = .init(allocator);
    defer wrapped.deinit();
    try wrapPlainLine(allocator, &wrapped.writer, content, wrap_width);

    const row_style = switch (block.kind) {
        .heading => tui_theme.heading(),
        .quote => tui_theme.quote(),
        else => tui_theme.base(),
    };
    var rows = std.mem.splitScalar(u8, wrapped.written(), '\n');
    var first = true;
    while (rows.next()) |row| {
        if (!first) try writer.writeByte('\n');
        if (block.indent > 0) try writeSpaces(writer, block.indent);
        if (block.marker.len > 0) {
            if (first) {
                const marker_style = if (block.kind == .quote) tui_theme.dim() else tui_theme.accentText();
                const marker = try marker_style.render(allocator, block.marker);
                defer allocator.free(marker);
                try writer.writeAll(marker);
                try writer.writeByte(' ');
            } else {
                try writeSpaces(writer, marker_width);
            }
        }
        first = false;
        try writeInlineStyled(allocator, writer, row, row_style);
    }
}

fn writeInlineStyled(allocator: std.mem.Allocator, writer: *std.Io.Writer, row: []const u8, base_style: zz.Style) !void {
    var literal_start: usize = 0;
    var i: usize = 0;
    while (i < row.len) {
        if (row[i] == '`') {
            var run: usize = 0;
            while (i + run < row.len and row[i + run] == '`') run += 1;
            if (findCodeClose(row, i + run, run)) |close| {
                try flushLiteral(allocator, writer, row[literal_start..i], base_style);
                const inner = std.mem.trim(u8, row[i + run .. close], " ");
                if (inner.len > 0) {
                    const styled = try tui_theme.inlineCode().render(allocator, inner);
                    defer allocator.free(styled);
                    try writer.writeAll(styled);
                }
                i = close + run;
                literal_start = i;
                continue;
            }
            i += run;
            continue;
        }
        if (matchEmphasis(row, i)) |span| {
            try flushLiteral(allocator, writer, row[literal_start..i], base_style);
            const inner = row[i + span.marker_len .. span.close];
            const style = if (span.strong) base_style.bold(true) else base_style.italic(true);
            var inner_out: std.Io.Writer.Allocating = .init(allocator);
            defer inner_out.deinit();
            try writeInlineStyled(allocator, &inner_out.writer, inner, style);
            try writer.writeAll(inner_out.written());
            i = span.close + span.marker_len;
            literal_start = i;
            continue;
        }
        i += 1;
    }
    try flushLiteral(allocator, writer, row[literal_start..], base_style);
}

fn flushLiteral(allocator: std.mem.Allocator, writer: *std.Io.Writer, text: []const u8, style: zz.Style) !void {
    if (text.len == 0) return;
    const styled = try style.render(allocator, text);
    defer allocator.free(styled);
    try writer.writeAll(styled);
}

fn findCodeClose(row: []const u8, from: usize, run: usize) ?usize {
    var i = from;
    while (i < row.len) {
        if (row[i] != '`') {
            i += 1;
            continue;
        }
        var count: usize = 0;
        while (i + count < row.len and row[i + count] == '`') count += 1;
        if (count == run) return i;
        i += count;
    }
    return null;
}

const EmphasisSpan = struct {
    marker_len: usize,
    close: usize,
    strong: bool,
};

fn matchEmphasis(row: []const u8, i: usize) ?EmphasisSpan {
    const c = row[i];
    if (c != '*' and c != '_') return null;
    const strong = i + 1 < row.len and row[i + 1] == c;
    const marker_len: usize = if (strong) 2 else 1;
    const content_start = i + marker_len;
    if (content_start >= row.len or row[content_start] == ' ' or row[content_start] == c) return null;
    if (i > 0 and isWordChar(row[i - 1])) return null;
    var j = content_start;
    while (j < row.len) : (j += 1) {
        if (row[j] != c) continue;
        if (strong and (j + 1 >= row.len or row[j + 1] != c)) continue;
        if (row[j - 1] == ' ') continue;
        const after = j + marker_len;
        if (after < row.len and isWordChar(row[after])) continue;
        if (j == content_start) return null;
        return .{ .marker_len = marker_len, .close = j, .strong = strong };
    }
    return null;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

const FenceMarker = struct { char: u8, len: usize, info: []const u8 = "" };

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
    return .{ .char = rest[0], .len = n, .info = std.mem.trim(u8, rest[n..], " \t\r") };
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

fn styleEachLine(allocator: std.mem.Allocator, style: zz.Style, text: []const u8) ![]u8 {
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
        .welcome => "Makai",
        .@"error" => "Error",
    };
}

fn inferredToolName(text: []const u8) []const u8 {
    if (parseToolSummary(text)) |summary| return firstToolNameToken(summary.label);
    return firstToolNameToken(text);
}

fn inferredToolTitle(text: []const u8) []const u8 {
    if (parseToolSummary(text)) |summary| return std.mem.trim(u8, summary.label, " \t\r\n");
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

pub fn lineWindow(allocator: std.mem.Allocator, text: []const u8, height: usize, scroll: usize) ![]u8 {
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

test "tool summary parser splits label argument status and stats" {
    const running = parseToolSummary("◈ Shell Execute \"ls -la\"").?;
    try std.testing.expectEqualStrings("Shell Execute", running.label);
    try std.testing.expectEqualStrings("ls -la", running.arg);
    try std.testing.expectEqual(ToolRowStatus.running, running.status);

    const done = parseToolSummary("◈ Shell Execute \"echo \"ok\" now\" ok raw=342B returned=342B ~87 tok").?;
    try std.testing.expectEqualStrings("Shell Execute", done.label);
    try std.testing.expectEqualStrings("echo \"ok\" now", done.arg);
    try std.testing.expectEqual(ToolRowStatus.ok, done.status);
    const stats = parseToolStats(done.stats);
    try std.testing.expectEqual(@as(?u64, 342), stats.bytes);
    try std.testing.expectEqual(@as(?u64, 87), stats.tokens);

    const failed = parseToolSummary("◈ workspace_list failed output=17B \"FileNotFound\"").?;
    try std.testing.expectEqualStrings("workspace_list", failed.label);
    try std.testing.expectEqualStrings("", failed.arg);
    try std.testing.expectEqual(ToolRowStatus.failed, failed.status);
    try std.testing.expectEqualStrings("FileNotFound", parseToolStats(failed.stats).detail);

    const interrupted = parseToolSummary("◈ Shell Execute \"Inspect pwd now\" interrupted").?;
    try std.testing.expectEqual(ToolRowStatus.interrupted, interrupted.status);
    try std.testing.expect(parseToolSummary("plain output row") == null);
}

test "tool summary row keeps status right-aligned within the width" {
    var entry = try TranscriptEntry.init(std.testing.allocator, .tool, "◈ Shell Execute \"Run the whole build and every unit test group twice\" ok output=4096B ~120 tok");
    defer entry.deinit(std.testing.allocator);
    entry.tool_summary = true;

    const rendered = try renderTranscriptEntry(std.testing.allocator, &entry, 60);
    defer std.testing.allocator.free(rendered);

    var lines = std.mem.splitScalar(u8, rendered, '\n');
    const row = lines.next().?;
    try std.testing.expect(tui_text.visibleWidth(row) <= 60);
    try std.testing.expect(std.mem.indexOf(u8, row, "Shell Execute") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, tui_theme.glyph.check) != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "4.0KB") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "…") != null);
}

test "failed tool summary row stays on one line and marks the failure" {
    var entry = try TranscriptEntry.init(std.testing.allocator, .tool, "◈ workspace_list \"src\" failed output=17B \"FileNotFound\"");
    defer entry.deinit(std.testing.allocator);
    entry.tool_summary = true;

    const rendered = try renderTranscriptEntry(std.testing.allocator, &entry, 80);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqual(@as(usize, 1), tui_text.lineCount(rendered));
    try std.testing.expect(std.mem.indexOf(u8, rendered, tui_theme.glyph.cross ++ " failed") != null);

    const awaiting = try renderTranscriptEntryWith(std.testing.allocator, &entry, 80, .{ .awaiting_approval = true });
    defer std.testing.allocator.free(awaiting);
    try std.testing.expect(std.mem.indexOf(u8, awaiting, "awaiting approval") == null);

    var pending = try TranscriptEntry.init(std.testing.allocator, .tool, "◈ Shell Execute \"pwd\"");
    defer pending.deinit(std.testing.allocator);
    const waiting = try renderTranscriptEntryWith(std.testing.allocator, &pending, 80, .{ .awaiting_approval = true });
    defer std.testing.allocator.free(waiting);
    try std.testing.expect(std.mem.indexOf(u8, waiting, "awaiting approval") != null);
}

test "live assistant entry shows spinner header and caret" {
    var entry = try TranscriptEntry.init(std.testing.allocator, .assistant, "partial answer");
    defer entry.deinit(std.testing.allocator);
    entry.timestamp_ms = 1779978720 * 1000;

    const live = try renderTranscriptEntryWith(std.testing.allocator, &entry, 80, .{ .live = true, .anim_tick = 3 });
    defer std.testing.allocator.free(live);
    try std.testing.expect(std.mem.indexOf(u8, live, tui_theme.spinnerFrame(3)) != null);
    try std.testing.expect(std.mem.indexOf(u8, live, tui_theme.glyph.caret) != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "14:32") == null);

    const settled = try renderTranscriptEntry(std.testing.allocator, &entry, 80);
    defer std.testing.allocator.free(settled);
    try std.testing.expect(std.mem.indexOf(u8, settled, tui_theme.glyph.caret) == null);
    try std.testing.expect(std.mem.indexOf(u8, settled, "14:32") != null);
}

test "inline emphasis and code spans are styled without their markers" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeStyledProseLine(std.testing.allocator, &out.writer, "use `zig build` with **care** and *speed* but a*b stays", 80);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "`") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "**") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "zig build") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[3m") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "a*b") != null);
}

test "unbalanced emphasis markers render literally" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeStyledProseLine(std.testing.allocator, &out.writer, "2 * 3 = 6 and **open", 80);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "2 * 3 = 6") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "**open") != null);
}

test "bullets numbered lists and headings get block styling with hanging indent" {
    const styled = try renderAssistantStyled(std.testing.allocator, "# Title\n- alpha beta gamma delta\n2. second\n> quoted", 16);
    defer std.testing.allocator.free(styled);
    try std.testing.expect(std.mem.indexOf(u8, styled, "# Title") == null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, tui_theme.glyph.bullet) != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "- alpha") == null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "2.") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, tui_theme.glyph.quote_bar) != null);
    var lines = std.mem.splitScalar(u8, styled, '\n');
    var saw_hanging = false;
    while (lines.next()) |line| {
        try std.testing.expect(tui_text.visibleWidth(line) <= 16);
        if (std.mem.startsWith(u8, line, "  ") and std.mem.indexOf(u8, line, "gamma") != null) saw_hanging = true;
    }
    try std.testing.expect(saw_hanging);
}

test "welcome entry renders as a banner with the marker and key hints" {
    var entry = try TranscriptEntry.init(std.testing.allocator, .welcome, "Makai TUI\nmodel: anthropic/claude\ncwd: /tmp/work\ntips: Enter send");
    defer entry.deinit(std.testing.allocator);

    const rendered = try renderTranscriptEntry(std.testing.allocator, &entry, 60);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Makai TUI") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "anthropic/claude") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "/tmp/work") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Enter send") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\u{256d}") != null);
    var lines = std.mem.splitScalar(u8, rendered, '\n');
    while (lines.next()) |line| try std.testing.expect(tui_text.visibleWidth(line) <= 60);
}

test "single line system entries render as one muted row" {
    var entry = try TranscriptEntry.init(std.testing.allocator, .system, "model switched to claude (anthropic)");
    defer entry.deinit(std.testing.allocator);
    const rendered = try renderTranscriptEntry(std.testing.allocator, &entry, 80);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqual(@as(usize, 1), tui_text.lineCount(rendered));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "System") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "model switched") != null);
}

test "tool rows take their status from the linked tool entry rather than status words in the label" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(
        std.testing.allocator,
        "call-label",
        "mcp__ci__deployment_failed_checks",
        "Deployment failed checks",
        "{\"description\":\"push build\"}",
        .running,
    ));
    try state.appendToolSummaryTranscript("◈ Deployment failed checks \"push build\"", "call-label");

    const running = try render(std.testing.allocator, &state, .{ .width = 100, .height = 10 });
    defer std.testing.allocator.free(running);
    try std.testing.expect(std.mem.indexOf(u8, running, "Deployment failed checks") != null);
    try std.testing.expect(std.mem.indexOf(u8, running, "push build") != null);
    try std.testing.expect(std.mem.indexOf(u8, running, " running") != null);
    try std.testing.expect(std.mem.indexOf(u8, running, tui_theme.glyph.cross) == null);

    state.tools.items[0].status = .done;
    const done = try render(std.testing.allocator, &state, .{ .width = 100, .height = 10 });
    defer std.testing.allocator.free(done);
    try std.testing.expect(std.mem.indexOf(u8, done, "Deployment failed checks") != null);
    try std.testing.expect(std.mem.indexOf(u8, done, tui_theme.glyph.check) != null);
    try std.testing.expect(std.mem.indexOf(u8, done, tui_theme.glyph.cross) == null);

    const anchored = parseToolSummaryAfterLabel("◈ Deployment failed checks \"push build\" ok output=3B", "Deployment failed checks").?;
    try std.testing.expectEqualStrings("Deployment failed checks", anchored.label);
    try std.testing.expectEqualStrings("push build", anchored.arg);
    try std.testing.expectEqual(ToolRowStatus.ok, anchored.status);
    try std.testing.expectEqualStrings("output=3B", anchored.stats);
}

test "tool rows keep their status visible on narrow terminals" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    _ = try state.resolveToolOccurrenceForTest("call-narrow", "mcp__very_long_server_name__some_extremely_long_tool_identifier", "{\"path\":\"/tmp/x\"}", .live_intent, .running);
    try state.appendToolSummaryTranscript("◈ Some Extremely Long Tool Identifier From An MCP Server \"/tmp/x\" running", "call-narrow");
    const entry = &state.transcript.items[0];
    const rendered = try renderTranscriptEntry(std.testing.allocator, entry, 30);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqual(@as(usize, 1), tui_text.lineCount(rendered));
    try std.testing.expect(tui_text.visibleWidth(rendered) <= 30);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "running") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "…") != null);
}

test "system entries wrap long URLs across rows and hyperlink every fragment" {
    const url = "https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile";
    const text = "open this URL to authorize:\n" ++ url ++ "\nPaste the code from the URL after '#code=' below:";
    var entry = try TranscriptEntry.init(std.testing.allocator, .system, text);
    defer entry.deinit(std.testing.allocator);
    const rendered = try renderTranscriptEntry(std.testing.allocator, &entry, 60);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "…") == null);
    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(std.testing.allocator);
    var fragments: usize = 0;
    var rows = std.mem.splitScalar(u8, rendered, '\n');
    while (rows.next()) |row| {
        try std.testing.expect(tui_text.visibleWidth(row) <= 60);
        const plain = try stripEscapesForTest(std.testing.allocator, row);
        defer std.testing.allocator.free(plain);
        for (plain) |c| if (c != ' ') try joined.append(std.testing.allocator, c);
        fragments += std.mem.count(u8, row, "\x1b]8;id=makai-");
    }
    try std.testing.expect(std.mem.indexOf(u8, joined.items, url) != null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "Pastethecode") != null);
    try std.testing.expect(fragments >= 3);
    try std.testing.expectEqual(fragments, std.mem.count(u8, rendered, ";" ++ url ++ "\x1b\\"));
    try std.testing.expectEqual(fragments, std.mem.count(u8, rendered, "\x1b]8;;\x1b\\"));
}

test "single line system entries wider than the screen wrap instead of truncating" {
    var entry = try TranscriptEntry.init(std.testing.allocator, .system, "the session was restored from disk and every pending steer was reconciled against the runtime");
    defer entry.deinit(std.testing.allocator);
    const rendered = try renderTranscriptEntry(std.testing.allocator, &entry, 40);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(tui_text.lineCount(rendered) > 2);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "…") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "System") != null);
    var rows = std.mem.splitScalar(u8, rendered, '\n');
    while (rows.next()) |row| try std.testing.expect(tui_text.visibleWidth(row) <= 40);
}

fn stripEscapesForTest(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != 0x1b) {
            try out.append(allocator, text[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= text.len) break;
        if (text[i] == '[') {
            i += 1;
            while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) i += 1;
            i += 1;
        } else if (text[i] == ']') {
            i += 1;
            while (i < text.len and text[i] != 0x07 and !(text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\')) i += 1;
            i += if (i < text.len and text[i] == 0x07) 1 else 2;
        } else {
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

test "tool result rows are capped with a remainder marker" {
    var entry = try TranscriptEntry.init(std.testing.allocator, .tool, "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11");
    defer entry.deinit(std.testing.allocator);
    const rendered = try renderTranscriptEntry(std.testing.allocator, &entry, 80);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, tui_theme.glyph.result) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "l8") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "l9") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "+3 more lines") != null);
}

test "waiting line names the model and spins" {
    const line = try renderWaitingLine(std.testing.allocator, "claude", 2, 3500);
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "waiting for claude") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "3s") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, tui_theme.spinnerFrame(2)) != null);
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

    try std.testing.expect(std.mem.indexOf(u8, text, "system notice") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Makai") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "You") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "01:02") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{256d}") == null);

    const assistant_line = renderedLineContaining(text, "assistant reply").?;
    try std.testing.expect(std.mem.startsWith(u8, assistant_line, "   "));

    const user_line = renderedLineContaining(text, "user reply").?;
    try std.testing.expect(std.mem.startsWith(u8, user_line, "   "));
    try std.testing.expect(tui_text.visibleWidth(user_line) <= 48);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try std.testing.expect(tui_text.visibleWidth(line) <= 48);
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

    try state.appendToolSummaryTranscript("◈ Shell Execute \"Run pwd to show current working directory\" ok raw=342B returned=342B ~87 tok", "call-1");
    try state.appendTranscript(.tool, "◈ not-a-summary tool output row");
    state.transcript.items[1].tool_call_id = try std.testing.allocator.dupe(u8, "call-1");
    try state.appendTranscript(.tool, "ok stdout=43 stderr=0");
    state.transcript.items[2].tool_call_id = try std.testing.allocator.dupe(u8, "call-1");

    const text = try render(std.testing.allocator, &state, .{ .width = 120, .height = 20 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Shell Execute") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Tool") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Run pwd to show current working directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, tui_theme.glyph.check) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "342B") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "~87 tok") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "{\"command\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "not-a-summary") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ok stdout=43 stderr=0") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{256d}") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{2570}") == null);
}

test "transcript renders reused tool call ids as distinct occurrences" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(
        std.testing.allocator,
        "call-x",
        "shell_execute",
        "Shell Execute",
        "{\"description\":\"List files\",\"command\":\"ls\"}",
        .done,
    ));
    var second = try tui_state.ToolEntry.init(
        std.testing.allocator,
        "call-x\x1f2",
        "shell_execute",
        "Shell Execute",
        "{\"description\":\"Read config\",\"command\":\"cat cfg\"}",
        .@"error",
    );
    second.error_detail_readable = false;
    try state.tools.append(std.testing.allocator, second);

    try state.appendToolSummaryTranscript("◈ Shell Execute \"List files\" ok", "call-x");
    try state.appendTranscript(.tool, "ok stdout=3 stderr=0");
    state.transcript.items[1].tool_call_id = try std.testing.allocator.dupe(u8, "call-x");
    try state.appendToolSummaryTranscript("◈ Shell Execute \"Read config\" failed", "call-x\x1f2");
    try state.appendTranscript(.tool, "Tool execution rejected by user");
    state.transcript.items[3].tool_call_id = try std.testing.allocator.dupe(u8, "call-x\x1f2");

    const text = try render(std.testing.allocator, &state, .{ .width = 120, .height = 20 });
    defer std.testing.allocator.free(text);

    const first_row = std.mem.indexOf(u8, text, "List files") orelse return error.TestUnexpectedResult;
    const second_row = std.mem.indexOf(u8, text, "Read config") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_row < second_row);
    try std.testing.expect(std.mem.indexOf(u8, text[first_row..second_row], tui_theme.glyph.check) != null);
    try std.testing.expect(std.mem.indexOf(u8, text[second_row..], tui_theme.glyph.cross) != null);
    try std.testing.expect(std.mem.indexOf(u8, text[second_row..], "failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Tool execution rejected by user") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{25b8}") == null);
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
    try state.appendToolSummaryTranscript("◈ Shell Execute \"before\"", "call-1");

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
    try state.appendToolSummaryTranscript("◈ Shell Execute \"Inspect pwd now\" ok output=10B", "call-1");
    try state.appendTranscript(.assistant, "PWD done");
    try state.appendUserMessage("second request");
    try state.appendToolSummaryTranscript("◈ Shell Execute \"Inspect uname now\" ok output=20B", "call-2");
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

test "transcript keeps rejected result text without consuming later calls" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var rejected = try tui_state.ToolEntry.init(
        std.testing.allocator,
        "call-r",
        "shell_execute",
        "Shell Execute",
        "{\"description\":\"Read config\",\"command\":\"cat cfg\"}",
        .@"error",
    );
    rejected.error_detail_readable = false;
    try state.tools.append(std.testing.allocator, rejected);
    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(
        std.testing.allocator,
        "call-l",
        "shell_execute",
        "Shell Execute",
        "{\"description\":\"List files\",\"command\":\"ls\"}",
        .done,
    ));

    try state.appendToolSummaryTranscript("◈ Shell Execute \"Read config\" failed output=17B", "call-r");
    try state.appendTranscript(.@"error", "Shell Execute failed: {\"rejected\":true}");
    try state.appendTranscript(.tool, "Tool execution rejected by user");
    state.transcript.items[2].tool_call_id = try std.testing.allocator.dupe(u8, "call-r");
    try state.appendTranscript(.assistant, "trying something else");
    try state.appendToolSummaryTranscript("◈ Shell Execute \"List files\" ok output=4B", "call-l");

    const text = try render(std.testing.allocator, &state, .{ .width = 140, .height = 30 });
    defer std.testing.allocator.free(text);

    const rejected_row = std.mem.indexOf(u8, text, "Tool execution rejected by user") orelse return error.MissingRejectedText;
    const rejected_summary = std.mem.indexOf(u8, text, "Read config") orelse return error.MissingRejectedSummary;
    const later = std.mem.indexOf(u8, text, "List files") orelse return error.MissingLaterCall;
    const occurrences = std.mem.count(u8, text, "List files");

    try std.testing.expectEqual(@as(usize, 1), occurrences);
    try std.testing.expect(rejected_summary < rejected_row);
    try std.testing.expect(rejected_row < later);
}

test "transcript renders interrupted balanced summaries from linked tools" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(
        std.testing.allocator,
        "call-i",
        "shell_execute",
        "Shell Execute",
        "{\"description\":\"Inspect pwd now\",\"command\":\"pwd\"}",
        .interrupted,
    ));
    try state.appendToolSummaryTranscript("◈ Shell Execute \"Inspect pwd now\" interrupted", "call-i");

    const text = try render(std.testing.allocator, &state, .{ .width = 120, .height = 20 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Inspect pwd now") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, tui_theme.glyph.stop ++ " interrupted") != null);
}

test "transcript renders unlinked tool rows as original text" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(
        std.testing.allocator,
        "call-1",
        "shell_execute",
        "Shell Execute",
        "{\"description\":\"Run pwd now\",\"command\":\"pwd\"}",
        .done,
    ));
    try state.appendToolSummaryTranscript("◈ Shell Execute \"Run pwd now\" ok", "call-1");
    try state.appendTranscript(.tool, "orphan output row");

    const text = try render(std.testing.allocator, &state, .{ .width = 120, .height = 20 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Run pwd now") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, tui_theme.glyph.check) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "orphan output row") != null);
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

test "transcript styles assistant headings and bullets" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "# Heading\n- item");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "# Heading") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Heading") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- item") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, tui_theme.glyph.bullet) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "item") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, text, "- first") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "second") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "third") != null);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(tui_text.visibleWidth(line) <= 15);
    }
}

test "transcript styles inline code spans without backticks" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "use `code` here");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "`code`") == null);
    const probe = try tui_theme.inlineCode().render(std.testing.allocator, "code");
    defer std.testing.allocator.free(probe);
    try std.testing.expect(std.mem.indexOf(u8, text, probe) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "here") != null);
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

    const code_probe = try tui_theme.codeBlock().render(std.testing.allocator, "x");
    defer std.testing.allocator.free(code_probe);
    const x_index = std.mem.indexOf(u8, code_probe, "x").?;
    try std.testing.expect(std.mem.indexOf(u8, code_line, code_probe[0..x_index]) != null);
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

    try std.testing.expect(std.mem.indexOf(u8, text, "code") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "then text") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "plain") != null);
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
