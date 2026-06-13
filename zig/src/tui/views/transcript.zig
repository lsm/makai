const std = @import("std");
const zz = @import("zigzag");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");

const AppState = tui_state.AppState;
const TranscriptKind = tui_state.TranscriptKind;
const TranscriptEntry = tui_state.TranscriptEntry;
const ProtocolEventEntry = tui_state.ProtocolEventEntry;

pub const Options = struct {
    width: usize = 80,
    height: usize = 20,
};

const DisplayEntry = struct {
    kind: TranscriptKind,
    text: []const u8,
    timestamp_ms: i64,
    tool_name: []const u8 = "",
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
        const row = try renderEntry(allocator, entry, options.width);
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
            for (state.transcript.items) |*entry| {
                if (entry.kind == .thinking and !state.show_thinking) continue;
                if (isLowValueSystem(entry)) continue;
                try appendOriginal(allocator, entries, entry);
            }
        },
        .chat => try appendConversationEntries(allocator, arena, state, entries),
    }
}

fn appendOriginal(allocator: std.mem.Allocator, entries: *std.ArrayList(DisplayEntry), entry: *const TranscriptEntry) !void {
    try entries.append(allocator, .{
        .kind = entry.kind,
        .text = entry.text.items,
        .timestamp_ms = entry.timestamp_ms,
        .tool_name = if (entry.kind == .tool) inferredToolName(entry.text.items) else "",
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
        try writer.print("tool state: {s} [{s}]\nid: {s}\nargs: {s}", .{ tool.name, @tagName(tool.status), tool.id, tool.args_json });
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
// text (like an outgoing iMessage); assistant replies in a neutral grey
// bubble. System/tool/thinking/error are framed as bordered cards in their
// role color rather than filled bubbles, so status output stays scannable.
const user_bg = zz.Color.color256(111); // soft periwinkle blue
const user_fg = zz.Color.color256(235); // near-black ink for contrast
const assistant_bg = zz.Color.color256(238); // graphite
const assistant_fg = zz.Color.color256(253); // bright grey ink

/// Render one transcript entry as a header line (role + time) followed by a
/// bubble (user/assistant) or a bordered card (everything else).
fn renderEntry(allocator: std.mem.Allocator, entry: *const DisplayEntry, width: usize) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const align_right = entry.kind == .user;
    const header = try renderHeader(arena, entry.kind, entry.tool_name, entry.timestamp_ms, align_right, width);

    const body: []const u8 = switch (entry.kind) {
        .user => blk: {
            const budget = @max(width -| 2, 8);
            const wrapped = try tui_text.wrapTextWithAnsi(arena, entry.text, budget);
            const open = try openSgr(arena, user_fg, user_bg);
            break :blk try renderBubble(arena, wrapped, open, true, width);
        },
        .assistant => blk: {
            const budget = @max(width -| 2, 8);
            var markdown = zz.Markdown.init();
            markdown.width = @intCast(@min(budget, std.math.maxInt(u16)));
            const md = try markdown.render(arena, entry.text);
            const wrapped = try tui_text.wrapTextPreservingPrefix(arena, md, budget);
            const open = try openSgr(arena, assistant_fg, assistant_bg);
            break :blk try renderBubble(arena, wrapped, open, false, width);
        },
        else => try renderCard(arena, entry.kind, entry.tool_name, entry.text, width),
    };

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

/// "❯ You · 14:32" — role glyph + name in the role color, dim timestamp.
/// Right-aligned for the user so it sits above their right-side bubble.
fn renderHeader(allocator: std.mem.Allocator, kind: TranscriptKind, tool_name: []const u8, ts_ms: i64, align_right: bool, width: usize) ![]u8 {
    const raw_label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ tui_theme.roleGlyph(kind), roleName(kind) });
    const role_style = if (kind == .tool and tool_name.len > 0) tui_theme.toolRole(tool_name) else tui_theme.role(kind);
    const styled_label = try role_style.render(allocator, raw_label);
    const clock = try formatClock(allocator, ts_ms);

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

/// Format an epoch-millisecond timestamp as "HH:MM" (UTC). Returns an empty
/// string for unset (zero) timestamps so legacy entries render without a time.
fn formatClock(allocator: std.mem.Allocator, ts_ms: i64) ![]u8 {
    if (ts_ms <= 0) return allocator.dupe(u8, "");
    const secs: u64 = @intCast(@divFloor(ts_ms, 1000));
    const day_secs = (std.time.epoch.EpochSeconds{ .secs = secs }).getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}", .{ day_secs.getHoursIntoDay(), day_secs.getMinutesIntoHour() });
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
    try std.testing.expect(!std.mem.startsWith(u8, assistant_line, " "));

    const user_line = renderedLineContaining(text, "user reply").?;
    try std.testing.expect(std.mem.startsWith(u8, user_line, "          "));
    try std.testing.expectEqual(@as(usize, 48), tui_text.visibleWidth(user_line));
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
