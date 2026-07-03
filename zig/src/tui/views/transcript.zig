const std = @import("std");
const zz = @import("zigzag");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");

const AppState = tui_state.AppState;
const TranscriptKind = tui_state.TranscriptKind;
const TranscriptEntry = tui_state.TranscriptEntry;
const ProtocolEventEntry = tui_state.ProtocolEventEntry;
const TimestampDisplay = tui_state.TimestampDisplay;

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
        var ready_text: []const u8 = "Makai ready. Type message, /quit exits.";
        if (state.transcript.items.len > 0 and !state.show_thinking) ready_text = "Thinking hidden.";
        const ready_line = try tui_theme.muted().render(allocator, ready_text);
        defer allocator.free(ready_line);
        return padTopToHeight(allocator, ready_line, options.height);
    }

    var all_rows: std.Io.Writer.Allocating = .init(allocator);
    defer all_rows.deinit();
    const all_writer = &all_rows.writer;
    for (visible_entries.items, 0..) |*entry, i| {
        if (i > 0) try all_writer.writeAll("\n\n"); // blank-line spacer between entries
        const row = try renderEntry(allocator, entry, options.width, state.timestamp_display);
        defer allocator.free(row);
        try all_writer.writeAll(row);
    }

    const all_text = all_rows.written();
    const total_lines = tui_text.lineCount(all_text);
    // Reserve one line for scroll indicator when scrolled and enough space exists; use full height otherwise.
    const show_indicator = state.transcript_scroll > 0 and total_lines > options.height and options.height >= 2;
    const view_height = if (show_indicator) options.height - 1 else options.height;
    const windowed = try lineWindow(allocator, all_text, view_height, state.transcript_scroll);
    defer allocator.free(windowed);

    if (!show_indicator) return padTopToHeight(allocator, windowed, options.height);

    // Prepend a scroll indicator line: "↑ SCROLL N%"
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

pub fn renderTranscriptEntry(allocator: std.mem.Allocator, entry: *const TranscriptEntry, width: usize, ts_mode: TimestampDisplay) ![]u8 {
    var display = DisplayEntry{
        .kind = entry.kind,
        .text = entry.text.items,
        .timestamp_ms = entry.timestamp_ms,
        .tool_name = if (entry.kind == .tool) inferredToolName(entry.text.items) else "",
        .title = if (entry.kind == .tool) inferredToolTitle(entry.text.items) else "",
    };
    return renderEntry(allocator, &display, width, ts_mode);
}

fn buildVisibleEntries(allocator: std.mem.Allocator, arena: std.mem.Allocator, state: *const AppState, entries: *std.ArrayList(DisplayEntry)) !void {
    switch (state.transcript_mode) {
        .everything => {
            for (state.protocol_events.items) |*entry| try appendProtocolEvent(allocator, entries, entry);
            for (state.transcript.items) |*entry| try appendOriginal(allocator, entries, entry);
            try appendDebugToolState(allocator, arena, state, entries, true);
            try appendTelemetryState(allocator, arena, state, entries);
        },
        .verbose => {
            for (state.transcript.items) |*entry| {
                if (entry.kind == .thinking and !state.show_thinking) continue;
                if (isLowValueSystem(entry)) continue;
                try appendOriginal(allocator, entries, entry);
            }
            try appendDebugToolState(allocator, arena, state, entries, false);
        },
        .balanced => {
            var tool_index: usize = 0;
            var i: usize = 0;
            while (i < state.transcript.items.len) {
                const entry = &state.transcript.items[i];
                if (entry.kind == .thinking and !state.show_thinking) {
                    i += 1;
                    continue;
                }
                if (isLowValueSystem(entry)) {
                    i += 1;
                    continue;
                }
                if (entry.kind == .tool) {
                    const cluster_start = i;
                    while (i < state.transcript.items.len and state.transcript.items[i].kind == .tool) : (i += 1) {}
                    tool_index = try appendBalancedToolCluster(allocator, arena, entries, state, cluster_start, i, tool_index);
                    continue;
                }
                try appendOriginal(allocator, entries, entry);
                i += 1;
            }
        },
        .chat => try appendConversationEntries(allocator, arena, state, entries),
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
            if (!isRawToolArgs(entry.text.items)) try appendOriginal(allocator, entries, entry);
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
        if (isToolStartSummary(entry.text.items)) count += 1;
    }
    return count;
}

fn isToolStartSummary(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "◈ ")) return false;
    const rest = text["◈ ".len..];
    const quote = std.mem.indexOfScalar(u8, rest, '"') orelse return false;
    const ok = std.mem.indexOf(u8, rest, " ok ") orelse rest.len;
    const failed = std.mem.indexOf(u8, rest, " failed ") orelse rest.len;
    return quote < @min(ok, failed);
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

fn appendProtocolEvent(allocator: std.mem.Allocator, entries: *std.ArrayList(DisplayEntry), entry: *const ProtocolEventEntry) !void {
    try entries.append(allocator, .{
        .kind = .system,
        .text = entry.text,
        .timestamp_ms = entry.timestamp_ms,
    });
}

fn isLowValueSystem(entry: *const TranscriptEntry) bool {
    return entry.kind == .system and std.mem.eql(u8, entry.text.items, "agent started");
}

fn appendDebugToolState(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    state: *const AppState,
    entries: *std.ArrayList(DisplayEntry),
    full_output: bool,
) !void {
    if (state.tools.items.len == 0) return;
    for (state.tools.items) |tool| {
        var out: std.Io.Writer.Allocating = .init(arena);
        const writer = &out.writer;
        try writer.print("tool state: {s} [{s}]\nname: {s}\nid: {s}\nargs: {s}", .{ tool.label, @tagName(tool.status), tool.name, tool.id, tool.args_json });
        if (tool.raw_total_bytes > 0 or tool.returned_total_bytes > 0) {
            try writer.print("\nbytes: raw={d} returned={d}", .{ tool.raw_total_bytes, tool.returned_total_bytes });
            if (tool.estimated_returned_tokens > 0) try writer.print(" tokens~{d}", .{tool.estimated_returned_tokens});
        }
        if (tool.artifact_refs.len > 0) try writer.print("\nartifacts: {s}", .{tool.artifact_refs});
        if (tool.output.items.len > 0) {
            if (full_output) {
                try writer.print("\noutput:\n{s}", .{tool.output.items});
            } else {
                try writer.print("\noutput: {d} bytes", .{tool.output.items.len});
                const preview = try truncateForSummary(arena, tool.output.items, 160);
                if (preview.len > 0) try writer.print("\npreview: {s}", .{preview});
            }
        }
        try entries.append(allocator, .{
            .kind = .tool,
            .text = out.written(),
            .timestamp_ms = 0,
            .tool_name = tool.name,
        });
    }
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
    };

    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.writeAll(if (tool.expanded) "\u{25be}" else "\u{25b8}");
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
        try writer.writeAll(", open/view/filter");
    }
    try writer.writeByte(']');
    if (tool.expanded) {
        try writer.print("\n  args: {s}", .{tool.args_json});
        if (tool.display_preview.len > 0) {
            try writer.print("\n  output preview:\n{s}", .{tool.display_preview});
        } else if (tool.output.items.len > 0) {
            try writer.print("\n  output:\n{s}", .{tool.output.items});
        }
        if (tool.artifact_refs.len > 0) try writer.print("\n  artifacts: {s}", .{tool.artifact_refs});
    }

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

fn appendTelemetryState(allocator: std.mem.Allocator, arena: std.mem.Allocator, state: *const AppState, entries: *std.ArrayList(DisplayEntry)) !void {
    if (state.telemetry.total_bytes == 0 and state.telemetry.estimated_tokens == 0 and state.telemetry.message_count == 0 and state.telemetry.tool_count == 0) return;
    const text = try std.fmt.allocPrint(arena, "context usage: system={d}B messages={d}B tools={d}B total={d}B ~{d} tokens messages={d} tools={d}", .{
        state.telemetry.system_prompt_bytes,
        state.telemetry.message_bytes,
        state.telemetry.tool_definition_bytes,
        state.telemetry.total_bytes,
        state.telemetry.estimated_tokens,
        state.telemetry.message_count,
        state.telemetry.tool_count,
    });
    try entries.append(allocator, .{ .kind = .system, .text = text, .timestamp_ms = 0 });
}

const ConversationStats = struct {
    thinking_blocks: usize = 0,
    tool_blocks: usize = 0,
    system_blocks: usize = 0,
    last_timestamp_ms: i64 = 0,

    fn any(self: ConversationStats) bool {
        return self.thinking_blocks > 0 or self.tool_blocks > 0;
    }

    fn add(self: *ConversationStats, entry: *const TranscriptEntry) void {
        switch (entry.kind) {
            .thinking => self.thinking_blocks += 1,
            .tool => self.tool_blocks += 1,
            .system => self.system_blocks += 1,
            else => {},
        }
        if (entry.timestamp_ms > 0) self.last_timestamp_ms = entry.timestamp_ms;
    }

    fn reset(self: *ConversationStats) void {
        self.* = .{};
    }
};

fn appendConversationEntries(allocator: std.mem.Allocator, arena: std.mem.Allocator, state: *const AppState, entries: *std.ArrayList(DisplayEntry)) !void {
    var stats: ConversationStats = .{};
    for (state.transcript.items) |*entry| {
        switch (entry.kind) {
            .user, .assistant => {
                try flushConversationStats(allocator, arena, entries, &stats);
                try appendOriginal(allocator, entries, entry);
            },
            .@"error" => {
                try flushConversationStats(allocator, arena, entries, &stats);
                try appendOriginal(allocator, entries, entry);
            },
            .thinking, .tool, .system => stats.add(entry),
        }
    }
    try flushConversationStats(allocator, arena, entries, &stats);
}

fn flushConversationStats(allocator: std.mem.Allocator, arena: std.mem.Allocator, entries: *std.ArrayList(DisplayEntry), stats: *ConversationStats) !void {
    if (!stats.any()) return;
    const text = try formatConversationActivity(arena, stats.*);
    try entries.append(allocator, .{
        .kind = .system,
        .text = text,
        .timestamp_ms = stats.last_timestamp_ms,
    });
    stats.reset();
}

fn formatConversationActivity(allocator: std.mem.Allocator, stats: ConversationStats) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    try writer.writeAll("Background:");
    var wrote = false;
    if (stats.tool_blocks > 0) {
        try writer.print(" {d} tool{s}", .{ stats.tool_blocks, if (stats.tool_blocks == 1) "" else "s" });
        wrote = true;
    }
    if (stats.thinking_blocks > 0) {
        if (wrote) try writer.writeAll(",");
        try writer.print(" {d} reasoning step{s}", .{ stats.thinking_blocks, if (stats.thinking_blocks == 1) "" else "s" });
    }
    return out.toOwnedSlice();
}

fn truncateForSummary(allocator: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]const u8 {
    if (text.len <= max_bytes) return allocator.dupe(u8, text);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(text[0..max_bytes]);
    try out.writer.writeAll("...");
    return out.toOwnedSlice();
}

/// Bottom-anchor content inside the transcript area: if content has fewer
/// lines than `height`, prepend blank lines so the latest line sits at the
/// bottom edge (right above the composer). This is how chat TUIs are
/// expected to behave — the welcome message hovering at the top of an
/// otherwise empty pane reads as broken layout.
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

/// Return scroll percentage: 100 = at top, 0 = at bottom.
fn scrollPercent(total_lines: usize, view_height: usize, scroll: usize) usize {
    if (total_lines <= view_height) return 0;
    const max_scroll = total_lines - view_height;
    const clamped = @min(scroll, max_scroll);
    return clamped * 100 / max_scroll;
}

// Chat-bubble palette. User messages sit in a light-blue bubble with dark
// text (like an outgoing iMessage); assistant replies use a dark neutral
// surface so markdown accents and command highlights pop without tinting the
// whole answer. System, thinking, and error entries remain role-colored cards.
// Tool entries are rendered as plain rows so copying transcript text does not
// include box drawing around command metadata.
const user_bg = zz.Color.color256(111); // soft periwinkle blue
const user_fg = zz.Color.color256(235); // near-black ink for contrast
const assistant_bg = zz.Color.fromRgb(42, 44, 52); // dark graphite
const assistant_fg = zz.Color.fromRgb(238, 241, 247); // high-contrast cool white
const assistant_code_bg = zz.Color.fromRgb(28, 30, 36);

const chat_max_column: usize = 108;

const EntryLayout = struct {
    left: usize,
    width: usize,
};

/// Render one transcript entry as a header line (role + time) followed by a
/// bubble, plain tool row, or bordered card.
fn renderEntry(allocator: std.mem.Allocator, entry: *const DisplayEntry, width: usize, ts_mode: TimestampDisplay) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const align_right = entry.kind == .user;
    const header_layout = entryHeaderLayout(entry.kind, width);
    const body_layout = entryBodyLayout(entry.kind, width);
    const header_inner = try renderHeader(arena, entry.kind, entry.tool_name, entry.title, entry.timestamp_ms, align_right, header_layout.width, ts_mode);
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
            var markdown = zz.Markdown.init();
            markdown.width = @intCast(@min(budget, std.math.maxInt(u16)));
            markdown.text_style = (zz.Style{}).fg(assistant_fg).inline_style(true);
            markdown.code_style = (zz.Style{}).fg(zz.Color.fromRgb(255, 229, 120)).bg(assistant_code_bg).inline_style(true);
            markdown.code_block_style = (zz.Style{}).fg(zz.Color.fromRgb(96, 245, 150)).bg(assistant_code_bg).inline_style(true);
            markdown.code_block_border = (zz.Style{}).fg(zz.Color.fromRgb(124, 139, 160)).bg(assistant_code_bg).inline_style(true);
            const md = try markdown.render(arena, entry.text);
            const wrapped = try tui_text.wrapTextPreservingPrefix(arena, md, budget);
            const open = try openSgr(arena, assistant_fg, assistant_bg);
            break :blk try renderBubble(arena, wrapped, open, false, body_layout.width);
        },
        .tool => try renderToolRow(arena, entry.tool_name, entry.text, body_layout.width),
        else => try renderCard(arena, entry.kind, entry.tool_name, entry.text, body_layout.width),
    };
    const body = try indentBlock(arena, body_inner, body_layout.left);

    // Compose header + body, then hand a single owned copy back to the caller.
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
    const label_text_left: usize = 3; // edge gutter + role glyph + following space
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

/// "❯ You · 14:32" — role glyph + name in the role color, dim timestamp.
/// Right-aligned for the user so it sits above their right-side bubble.
fn renderHeader(allocator: std.mem.Allocator, kind: TranscriptKind, tool_name: []const u8, title: []const u8, ts_ms: i64, align_right: bool, width: usize, ts_mode: TimestampDisplay) ![]u8 {
    const name = if (kind == .tool and title.len > 0) title else roleName(kind);
    const raw_label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ tui_theme.roleGlyph(kind), name });
    const role_style = if (kind == .tool and tool_name.len > 0) tui_theme.toolRole(tool_name) else tui_theme.role(kind);
    const styled_label = try role_style.render(allocator, raw_label);
    const clock = try formatTimestamp(allocator, ts_ms, ts_mode, width);

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

/// Render filled-bubble body lines. `content` may carry inline ANSI (markdown);
/// any embedded SGR reset would punch a hole in the background, so we re-assert
/// the bubble's fg/bg right after each reset. Bubbles hug their content width
/// and are right-aligned for the user.
fn renderBubble(allocator: std.mem.Allocator, content: []const u8, open: []const u8, align_right: bool, width: usize) ![]u8 {
    if (content.len == 0) return allocator.dupe(u8, "");

    // Keep the bubble's background intact across inline resets.
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
        try writer.writeAll(open); // re-assert before padding so trailing fill stays colored
        const pad = content_w -| tui_text.visibleWidth(line);
        try writeSpaces(writer, pad);
        try writer.writeByte(' ');
        try writer.writeAll(zz.ansi.reset);
    }
    return out.toOwnedSlice();
}

/// Render system/tool/thinking/error entries as a rounded card framed in the
/// role color. Body lines are truncated (not word-wrapped) so command output
/// and tool args keep their original whitespace and indentation.
fn renderCard(allocator: std.mem.Allocator, kind: TranscriptKind, tool_name: []const u8, text: []const u8, width: usize) ![]const u8 {
    const content_width = @max(width -| 4, 8); // 2 border + 2 padding
    const truncated = try tui_text.truncateLinesToWidth(allocator, text, content_width, std.math.maxInt(usize));
    const body_style = if (kind == .tool and tool_name.len > 0) tui_theme.toolBody(tool_name) else tui_theme.bodyStyle(kind);
    const styled = try styleEachLine(allocator, body_style, truncated);
    const card = tui_theme.panel()
        .borderForeground(roleColor(kind, tool_name))
        .width(@intCast(@min(content_width, std.math.maxInt(u16))));
    return card.render(allocator, styled);
}

/// Apply an inline style to each newline-separated line individually, then
/// rejoin with `\n`. Necessary because zigzag's inline_style mode drops
/// the inter-line newlines when given multi-line input.
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

/// Concatenated foreground + background SGR for a bubble fill.
fn openSgr(allocator: std.mem.Allocator, fg: zz.Color, bg: zz.Color) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try fg.writeFg(&out.writer);
    try bg.writeBg(&out.writer);
    return out.toOwnedSlice();
}

/// Format an epoch-millisecond timestamp for the transcript header. Returns
/// an empty string when timestamps are disabled or the entry has no clock.
/// `width` lets `.full` mode shed the date on narrow terminals so the role
/// label and clock fit on a single line.
fn formatTimestamp(allocator: std.mem.Allocator, ts_ms: i64, mode: TimestampDisplay, width: usize) ![]u8 {
    if (ts_ms <= 0) return allocator.dupe(u8, "");
    const secs: u64 = @intCast(@divFloor(ts_ms, 1000));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const day_secs = epoch_seconds.getDaySeconds();
    const hh = day_secs.getHoursIntoDay();
    const mm = day_secs.getMinutesIntoHour();
    const ss = day_secs.getSecondsIntoMinute();
    return switch (mode) {
        .off => allocator.dupe(u8, ""),
        .clock => std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}", .{ hh, mm }),
        // Wide terminals get the full `YYYY-MM-DD HH:MM:SS`; medium terminals
        // drop the year (`MM-DD HH:MM`); very narrow terminals fall back to
        // the clock-only form so the timestamp never wraps or shoves the role
        // label off-screen.
        .full => blk: {
            if (width < 28) {
                break :blk try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}", .{ hh, mm });
            }
            const epoch_day = epoch_seconds.getEpochDay();
            const year_day = epoch_day.calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            const month: u4 = @intFromEnum(month_day.month);
            const day: u5 = month_day.day_index;
            if (width >= 40) {
                break :blk try std.fmt.allocPrint(allocator, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
                    year_day.year, month, day + 1, hh, mm, ss,
                });
            }
            break :blk try std.fmt.allocPrint(allocator, "{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ month, day + 1, hh, mm });
        },
    };
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
    if (std.mem.startsWith(u8, text, "tool state: ")) return firstToolNameToken(text["tool state: ".len..]);
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
    if (std.mem.startsWith(u8, text, "tool state: ")) {
        const rest = text["tool state: ".len..];
        const bracket = std.mem.indexOfScalar(u8, rest, '[') orelse rest.len;
        return std.mem.trim(u8, rest[0..bracket], " \t\r\n");
    }
    return "";
}

fn isRawToolArgs(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "{") or std.mem.startsWith(u8, trimmed, "[");
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
    for (state.transcript.items) |*entry| entry.timestamp_ms = 3_720_000; // 01:02

    const text = try render(std.testing.allocator, &state, .{ .width = 48, .height = 14 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "System") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Makai") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "You") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "01:02") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{256d}") != null); // rounded card top-left

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

test "transcript renders date and time in full timestamp mode" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    state.timestamp_display = .full;
    try state.appendUserMessage("hello");
    // 2026-05-28 14:32:00 UTC → epoch seconds 1779978720.
    for (state.transcript.items) |*entry| entry.timestamp_ms = 1779978720 * 1000;

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 8 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "2026-05-28 14:32:00") != null);
}

test "transcript timestamp hidden in off mode" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    state.timestamp_display = .off;
    try state.appendUserMessage("hello");
    for (state.transcript.items) |*entry| entry.timestamp_ms = 3_720_000; // 01:02

    const text = try render(std.testing.allocator, &state, .{ .width = 60, .height = 8 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "01:02") == null);
}

test "single entry helper honors timestamp display mode" {
    var entry = try TranscriptEntry.init(std.testing.allocator, .assistant, "hello");
    defer entry.deinit(std.testing.allocator);
    entry.timestamp_ms = 1779978720 * 1000;

    const full = try renderTranscriptEntry(std.testing.allocator, &entry, 80, .full);
    defer std.testing.allocator.free(full);
    try std.testing.expect(std.mem.indexOf(u8, full, "2026-05-28 14:32:00") != null);

    const off = try renderTranscriptEntry(std.testing.allocator, &entry, 80, .off);
    defer std.testing.allocator.free(off);
    try std.testing.expect(std.mem.indexOf(u8, off, "14:32") == null);
}

test "transcript full timestamp drops year on narrow terminals" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    state.timestamp_display = .full;
    try state.appendUserMessage("hi");
    for (state.transcript.items) |*entry| entry.timestamp_ms = 1779978720 * 1000;

    const text = try render(std.testing.allocator, &state, .{ .width = 32, .height = 8 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "05-28 14:32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2026") == null);
}

test "transcript full timestamp falls back to clock on very narrow terminals" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    state.timestamp_display = .full;
    try state.appendUserMessage("hi");
    for (state.transcript.items) |*entry| entry.timestamp_ms = 1779978720 * 1000;

    const text = try render(std.testing.allocator, &state, .{ .width = 18, .height = 8 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "14:32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "05-28") == null);
}

test "transcript clock mode renders only time" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    state.timestamp_display = .clock;
    try state.appendUserMessage("hi");
    for (state.transcript.items) |*entry| entry.timestamp_ms = 1779978720 * 1000;

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 8 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "14:32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2026") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "05-28") == null);
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

test "transcript hides thinking when toggled off" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.thinking, "secret plan");
    try state.appendTranscript(.assistant, "visible answer");
    state.show_thinking = false;

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "secret plan") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "visible answer") != null);
}

test "transcript empty visible state does not advertise removed Ctrl R shortcut" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.thinking, "secret plan");
    state.show_thinking = false;

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Thinking hidden.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Ctrl+R") == null);
}

test "transcript chat mode consolidates thinking and tool details" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    state.transcript_mode = .chat;
    try state.appendUserMessage("question");
    try state.appendTranscript(.thinking, "private plan");
    try state.appendTranscript(.tool, "shell_execute {\"command\":\"pwd\"}");
    try state.appendTranscript(.assistant, "answer");

    const text = try render(std.testing.allocator, &state, .{ .width = 100, .height = 20 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "question") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Background: 1 tool, 1 reasoning step") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hidden=") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "system=") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "private plan") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "shell_execute") == null);
}

test "transcript chat mode renders backpressure warning" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    state.transcript_mode = .chat;
    try state.appendTranscript(.@"error", "Warning: 2 events dropped due to backpressure");

    const text = try render(std.testing.allocator, &state, .{ .width = 100, .height = 20 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Warning: 2 events dropped due to backpressure") != null);
}

test "transcript balanced mode collapses tool events into intent row without card" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    state.transcript_mode = .balanced;

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

    try state.appendTranscript(.tool, "{\"command\":\"pwd\",\"description\":\"Run pwd to show current working directory\",\"workspace_root\":\"/tmp\"}");
    try state.appendTranscript(.tool, "◈ Shell Execute \"Run pwd to show current working directory\"");
    try state.appendTranscript(.tool, "◈ Shell Execute ok raw=342B returned=342B ~87 tok");
    try state.appendTranscript(.tool, "ok stdout=43 stderr=0");

    const text = try render(std.testing.allocator, &state, .{ .width = 120, .height = 20 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Shell Execute") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Tool") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{25b8} Run pwd to show current working directory [ok, 342B, ~87 tok]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "{\"command\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ok stdout=43 stderr=0") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{256d}") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{2570}") == null);
}

test "transcript balanced mode sanitizes tool descriptions" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    state.transcript_mode = .balanced;

    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(
        std.testing.allocator,
        "call-1",
        "shell_execute",
        "Shell Execute",
        "{\"description\":\"before\\u001b[2Jafter\\u0007\",\"command\":\"pwd\"}",
        .done,
    ));
    try state.appendTranscript(.tool, "◈ Shell Execute \"before\"");

    const text = try render(std.testing.allocator, &state, .{ .width = 120, .height = 20 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0x07) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "before[2Jafter") != null);
}

test "transcript balanced mode expands latest tool details" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    state.transcript_mode = .balanced;

    try state.tools.append(std.testing.allocator, try tui_state.ToolEntry.init(
        std.testing.allocator,
        "call-1",
        "shell_execute",
        "Shell Execute",
        "{\"description\":\"Inspect current directory\",\"command\":\"pwd\"}",
        .done,
    ));
    try state.tools.items[0].output.appendSlice(std.testing.allocator, "stdout:\n/tmp\nstderr:\n");
    state.toggleLatestToolExpanded();
    try state.appendTranscript(.tool, "◈ Shell Execute \"Inspect current directory\"");

    const text = try render(std.testing.allocator, &state, .{ .width = 100, .height = 20 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "\u{25be} Inspect current directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "args: {\"description\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "stdout:") != null);
}

test "transcript balanced mode preserves tool call order across turns" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    state.transcript_mode = .balanced;

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
    try state.appendTranscript(.tool, "◈ Shell Execute \"Inspect pwd now\"");
    try state.appendTranscript(.tool, "◈ Shell Execute ok output=10B");
    try state.appendTranscript(.assistant, "PWD done");
    try state.appendUserMessage("second request");
    try state.appendTranscript(.tool, "◈ Shell Execute \"Inspect uname now\"");
    try state.appendTranscript(.tool, "◈ Shell Execute ok output=20B");
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

test "transcript everything mode includes low value system and full tool state" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    state.transcript_mode = .everything;
    try state.applyEvent(.agent_start);
    const tool = try state.upsertToolForTest("call-1", "shell_execute", "{\"command\":\"ls\"}", .done);
    try tool.output.appendSlice(std.testing.allocator, "full output line");
    state.telemetry.total_bytes = 42;
    state.telemetry.estimated_tokens = 10;

    const text = try render(std.testing.allocator, &state, .{ .width = 100, .height = 40 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "agent started") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "protocol event: agent_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tool state: shell_execute") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "full output line") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "context usage") != null);
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

test "transcript renders markdown syntax" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "# Heading\n- item");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Heading") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "item") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "# Heading") == null);
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
    // Add more lines than fit in the viewport
    for (0..20) |i| {
        const msg = try std.fmt.allocPrint(std.testing.allocator, "line {d}", .{i});
        defer std.testing.allocator.free(msg);
        try state.appendTranscript(.assistant, msg);
    }
    state.transcript_scroll = 5; // scrolled up

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
    state.transcript_scroll = 0; // at bottom

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

test "transcript renders heading bold without markdown marker" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "# Heading");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Heading") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "# Heading") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[") != null);
}

test "transcript renders list with indented continuation" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "- first second third");

    const text = try render(std.testing.allocator, &state, .{ .width = 15, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "•") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "second") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- first") == null);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(tui_text.visibleWidth(line) <= 15);
    }
}

test "transcript renders inline code without backticks" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "use `code` here");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "code") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "`code`") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[") != null);
}

test "transcript renders fenced code block with border" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendTranscript(.assistant, "```zig\n    const x = 1;\n```\n");

    const text = try render(std.testing.allocator, &state, .{ .width = 80, .height = 10 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "const x") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "```zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "└") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "│") != null);

    const border_line = renderedLineContaining(text, "┌").?;
    try std.testing.expect(tui_text.visibleWidth(border_line) > 45);
    try std.testing.expect(tui_text.visibleWidth(border_line) <= 80);
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
