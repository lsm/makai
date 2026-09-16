const std = @import("std");
const zz = @import("zigzag");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");

pub const Options = struct {
    width: usize = 80,
    hint: []const u8 = "",
};

const gauge_cells: usize = 8;
const hint_gap: usize = 3;

const Segment = struct {
    styled: []const u8,
    width: usize,
};

const SegmentList = std.ArrayList(Segment);

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]const u8 {
    var segments: SegmentList = .empty;
    defer {
        for (segments.items) |seg| allocator.free(seg.styled);
        segments.deinit(allocator);
    }

    const model = if (state.status.model.len > 0) state.status.model else "no-model";
    const provider = if (state.status.provider.len > 0) state.status.provider else "local";

    try pushOwnedValue(&segments, allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider, model }), tui_theme.statusModel());
    try writeContext(&segments, allocator, state);
    try writeState(&segments, allocator, state);
    if (state.queue.total() > 0) {
        try pushOwnedSegment(&segments, allocator, "queue", try std.fmt.allocPrint(allocator, "{d}", .{state.queue.total()}));
    }
    if (state.mode == .approval) {
        try pushStyledValue(&segments, allocator, "perm", "pending", tui_theme.warningText());
    } else if (state.permission_mode == .bypass) {
        try pushStyledValue(&segments, allocator, "perm", "bypass", tui_theme.warningText());
    } else {
        try pushStyledValue(&segments, allocator, "perm", @tagName(state.permission_mode), tui_theme.successText());
    }
    if (contextTokens(state) > 0 and state.telemetry.input_cost_per_million > 0) try pushOwnedValue(&segments, allocator, try estimatedCost(allocator, state), tui_theme.statusSegment());
    if (state.backpressure_active or state.dropped_event_count > 0) {
        const label: []const u8 = if (state.backpressure_active) "backpressure" else "drops";
        const value = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ label, state.dropped_event_count });
        if (state.backpressure_active) {
            try pushOwnedValue(&segments, allocator, value, tui_theme.warningText());
        } else {
            try pushOwnedSegment(&segments, allocator, "drops", value);
        }
    }
    try pushSegment(&segments, allocator, "think", @tagName(state.thinking_level));
    try pushOwnedSegment(&segments, allocator, "turns", try std.fmt.allocPrint(allocator, "{d}", .{state.status.turn_count}));

    if (options.hint.len == 0) return layoutSegments(allocator, segments.items, options.width);

    const hint_width = tui_text.visibleWidth(options.hint);
    var keep = segments.items.len;
    while (keep > min_segments_with_hint) : (keep -= 1) {
        const candidate = try layoutSegments(allocator, segments.items[0..keep], options.width);
        if (tui_text.visibleWidth(candidate) + hint_gap + hint_width <= options.width) {
            defer allocator.free(candidate);
            return appendHint(allocator, candidate, options.hint, options.width);
        }
        allocator.free(candidate);
    }
    const minimal = try layoutSegments(allocator, segments.items[0..keep], options.width);
    if (tui_text.visibleWidth(minimal) + hint_gap + hint_width <= options.width) {
        defer allocator.free(minimal);
        return appendHint(allocator, minimal, options.hint, options.width);
    }
    allocator.free(minimal);
    return layoutSegments(allocator, segments.items, options.width);
}

const min_segments_with_hint: usize = 3;

fn contextTokens(state: *const tui_state.AppState) u64 {
    return if (state.telemetry.estimated_tokens > 0) state.telemetry.estimated_tokens else state.status.context_used;
}

fn appendHint(allocator: std.mem.Allocator, left: []const u8, hint: []const u8, width: usize) ![]u8 {
    const left_width = tui_text.visibleWidth(left);
    const hint_width = tui_text.visibleWidth(hint);
    if (left_width + hint_gap + hint_width > width) return allocator.dupe(u8, left);
    const styled = try tui_theme.keyHint().render(allocator, hint);
    defer allocator.free(styled);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(left);
    const pad = width - left_width - hint_width;
    for (0..pad) |_| try out.writer.writeByte(' ');
    try out.writer.writeAll(styled);
    return out.toOwnedSlice();
}

fn layoutSegments(allocator: std.mem.Allocator, segments: []const Segment, width: usize) ![]u8 {
    if (segments.len == 0) return allocator.dupe(u8, "");
    const sep = try tui_theme.faint().render(allocator, " " ++ tui_theme.glyph.sep ++ " ");
    defer allocator.free(sep);
    const sep_width = tui_text.visibleWidth(sep);

    var total: usize = 0;
    for (segments) |seg| total += seg.width;
    total += sep_width * (segments.len - 1);

    const ellipsis = try tui_theme.dim().render(allocator, "…");
    defer allocator.free(ellipsis);

    var kept: usize = segments.len;
    if (total > width) {
        const cut_tail = sep_width + 1;
        kept = 0;
        var used: usize = 0;
        for (segments, 0..) |seg, i| {
            const lead: usize = if (i == 0) 0 else sep_width;
            if (used + lead + seg.width + cut_tail > width) break;
            used += lead + seg.width;
            kept = i + 1;
        }
        if (kept == 0) {
            const first = segments[0];
            if (first.width > width) return tui_text.truncateToWidth(allocator, first.styled, width);
            if (first.width == width) return tui_text.truncateToWidth(allocator, first.styled, width -| 1);
            var solo: std.Io.Writer.Allocating = .init(allocator);
            errdefer solo.deinit();
            try solo.writer.writeAll(first.styled);
            try solo.writer.writeAll(ellipsis);
            return solo.toOwnedSlice();
        }
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (segments[0..kept], 0..) |seg, i| {
        if (i > 0) try out.writer.writeAll(sep);
        try out.writer.writeAll(seg.styled);
    }
    if (kept < segments.len) {
        try out.writer.writeAll(sep);
        try out.writer.writeAll(ellipsis);
    }
    return out.toOwnedSlice();
}

fn gaugeColor(pct: u64) zz.Color {
    if (pct >= 90) return tui_theme.palette.danger;
    if (pct >= 70) return tui_theme.palette.warning;
    return tui_theme.palette.success;
}

fn renderGauge(allocator: std.mem.Allocator, pct: u64) ![]u8 {
    const filled: usize = @intCast(@min(gauge_cells, (pct * gauge_cells + 50) / 100));
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try gaugeColor(pct).writeFg(writer);
    for (0..filled) |_| try writer.writeAll(tui_theme.glyph.gauge_on);
    try zz.ansi.sgr(writer, "0");
    try tui_theme.palette.faint.writeFg(writer);
    for (filled..gauge_cells) |_| try writer.writeAll(tui_theme.glyph.gauge_off);
    try writer.writeAll(zz.ansi.reset);
    return out.toOwnedSlice();
}

fn writeContext(list: *SegmentList, allocator: std.mem.Allocator, state: *const tui_state.AppState) !void {
    const used: u64 = if (state.telemetry.estimated_tokens > 0) state.telemetry.estimated_tokens else state.status.context_used;
    const limit: u64 = if (state.telemetry.context_window > 0) state.telemetry.context_window else state.status.context_limit;
    const pct: u64 = if (limit > 0) @min(100, (used * 100) / limit) else 0;
    const gauge_text = try renderGauge(allocator, pct);
    defer allocator.free(gauge_text);
    const used_text = try tui_text.compactNumber(allocator, used);
    defer allocator.free(used_text);
    if (limit > 0) {
        const limit_text = try tui_text.compactNumber(allocator, limit);
        defer allocator.free(limit_text);
        try pushOwnedValue(list, allocator, try std.fmt.allocPrint(allocator, "{s} {d}% {s}/{s}", .{ gauge_text, pct, used_text, limit_text }), tui_theme.statusSegment());
    } else {
        try pushOwnedValue(list, allocator, try std.fmt.allocPrint(allocator, "{s} {s} ctx", .{ gauge_text, used_text }), tui_theme.statusSegment());
    }
}

fn writeState(list: *SegmentList, allocator: std.mem.Allocator, state: *const tui_state.AppState) !void {
    if (state.status.streaming) {
        const elapsed = state.status.streaming_elapsed_ms;
        var elapsed_buf: [12]u8 = undefined;
        const value = if (elapsed > 0)
            try std.fmt.allocPrint(allocator, "{s} streaming {s}", .{ tui_theme.spinnerFrame(state.anim_tick), formatElapsed(&elapsed_buf, elapsed) })
        else
            try std.fmt.allocPrint(allocator, "{s} streaming", .{tui_theme.spinnerFrame(state.anim_tick)});
        defer allocator.free(value);
        try pushValue(list, allocator, value, tui_theme.runningText());
    } else {
        try pushValue(list, allocator, "idle", tui_theme.muted());
    }
}

fn formatElapsed(buf: *[12]u8, ms: u64) []const u8 {
    const secs = ms / 1000;
    if (secs < 60) {
        return std.fmt.bufPrint(buf, "{d}.{d}s", .{ secs, (ms % 1000) / 100 }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ secs / 60, secs % 60 }) catch "";
}

fn estimatedCost(allocator: std.mem.Allocator, state: *const tui_state.AppState) ![]u8 {
    const tokens: f64 = @floatFromInt(if (state.telemetry.estimated_tokens > 0) state.telemetry.estimated_tokens else state.status.context_used);
    const rate: f64 = state.telemetry.input_cost_per_million;
    const dollars = (tokens / 1_000_000.0) * rate;
    return std.fmt.allocPrint(allocator, "${d:.4}", .{dollars});
}

fn pushSegment(list: *SegmentList, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try pushStyledValue(list, allocator, key, value, tui_theme.statusSegment());
}

fn pushOwnedSegment(list: *SegmentList, allocator: std.mem.Allocator, key: []const u8, value: []u8) !void {
    defer allocator.free(value);
    try pushSegment(list, allocator, key, value);
}

fn pushStyledValue(list: *SegmentList, allocator: std.mem.Allocator, key: []const u8, value: []const u8, value_style: zz.Style) !void {
    const styled_key = try tui_theme.statusKey().render(allocator, key);
    defer allocator.free(styled_key);
    const styled_value = try value_style.render(allocator, value);
    defer allocator.free(styled_value);
    const styled = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ styled_key, styled_value });
    try pushOwned(list, allocator, styled);
}

fn pushValue(list: *SegmentList, allocator: std.mem.Allocator, value: []const u8, value_style: zz.Style) !void {
    try pushOwned(list, allocator, try value_style.render(allocator, value));
}

fn pushOwnedValue(list: *SegmentList, allocator: std.mem.Allocator, value: []u8, value_style: zz.Style) !void {
    defer allocator.free(value);
    try pushValue(list, allocator, value, value_style);
}

fn pushOwned(list: *SegmentList, allocator: std.mem.Allocator, styled: []const u8) !void {
    errdefer allocator.free(styled);
    try list.append(allocator, .{ .styled = styled, .width = tui_text.visibleWidth(styled) });
}

test "status bar renders model and clips width" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.status.setModel(std.testing.allocator, "claude", "anthropic");
    state.status.streaming = true;

    const text = try render(std.testing.allocator, &state, .{ .width = 24 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(tui_text.visibleWidth(text) <= 24);
    try std.testing.expect(std.mem.indexOf(u8, text, "anthropic") != null);
}

test "status bar renders queue count when queued" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.queue.steering = 1;
    state.queue.follow_up = 2;

    const text = try render(std.testing.allocator, &state, .{ .width = 160 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "queue") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "3") != null);
}

test "status bar renders context gauge cost and permission" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.status.setModelWithContext(std.testing.allocator, "claude", "anthropic", 200_000);
    state.telemetry.estimated_tokens = 10_000;
    state.telemetry.context_window = 200_000;
    state.telemetry.input_cost_per_million = 3.0;

    const text = try render(std.testing.allocator, &state, .{ .width = 160 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "10k/200k") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, tui_theme.glyph.gauge_off) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "5%") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "$") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "perm") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "think") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "low") != null);
}

test "status bar hides the cost when the model price is unknown" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.status.setModelWithContext(std.testing.allocator, "claude-opus-5", "anthropic", 200_000);
    state.telemetry.estimated_tokens = 10_000;
    state.telemetry.context_window = 200_000;
    state.telemetry.input_cost_per_million = 0;

    const text = try render(std.testing.allocator, &state, .{ .width = 160 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "10k/200k") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "$") == null);
}

test "status bar prices context with the active model rate" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.telemetry.estimated_tokens = 1_000_000;
    state.telemetry.input_cost_per_million = 15.0;

    const text = try render(std.testing.allocator, &state, .{ .width = 200 });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "$15.0000") != null);
}

test "status bar shows streaming elapsed time" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.status.streaming = true;
    state.status.streaming_elapsed_ms = 4_200;

    const text = try render(std.testing.allocator, &state, .{ .width = 200 });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "streaming 4.2s") != null);

    state.status.streaming_elapsed_ms = 75_000;
    const long = try render(std.testing.allocator, &state, .{ .width = 200 });
    defer std.testing.allocator.free(long);
    try std.testing.expect(std.mem.indexOf(u8, long, "streaming 1m15s") != null);
}

test "status bar appends the hint right-aligned and drops tail segments to fit it" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.status.setModelWithContext(std.testing.allocator, "claude-sonnet-4-5", "anthropic", 200_000);
    state.status.turn_count = 4;

    const text = try render(std.testing.allocator, &state, .{ .width = 160, .hint = "⏎ send · esc clear" });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 160), tui_text.visibleWidth(text));
    try std.testing.expect(std.mem.endsWith(u8, text, "esc clear" ++ zz.ansi.reset));
    try std.testing.expect(std.mem.indexOf(u8, text, "turns") != null);

    const mid = try render(std.testing.allocator, &state, .{ .width = 90, .hint = "⏎ send · esc clear" });
    defer std.testing.allocator.free(mid);
    try std.testing.expectEqual(@as(usize, 90), tui_text.visibleWidth(mid));
    try std.testing.expect(std.mem.indexOf(u8, mid, "esc clear") != null);
    try std.testing.expect(std.mem.indexOf(u8, mid, "anthropic/claude-sonnet-4-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, mid, "turns") == null);

    const narrow = try render(std.testing.allocator, &state, .{ .width = 40, .hint = "⏎ send · esc clear" });
    defer std.testing.allocator.free(narrow);
    try std.testing.expect(tui_text.visibleWidth(narrow) <= 40);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "esc clear") == null);

    const full = try render(std.testing.allocator, &state, .{ .width = 200 });
    defer std.testing.allocator.free(full);
    const crowded = try render(std.testing.allocator, &state, .{ .width = 62, .hint = "a very long hint that can never fit beside the segments at all" });
    defer std.testing.allocator.free(crowded);
    try std.testing.expect(std.mem.indexOf(u8, crowded, "never fit") == null);
    try std.testing.expect(std.mem.indexOf(u8, crowded, "idle") != null);
}

test "status bar hides the cost until context tokens are known" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    const idle = try render(std.testing.allocator, &state, .{ .width = 200 });
    defer std.testing.allocator.free(idle);
    try std.testing.expect(std.mem.indexOf(u8, idle, "$") == null);
    state.telemetry.estimated_tokens = 500;
    state.telemetry.input_cost_per_million = 3.0;
    const priced = try render(std.testing.allocator, &state, .{ .width = 200 });
    defer std.testing.allocator.free(priced);
    try std.testing.expect(std.mem.indexOf(u8, priced, "$0.0015") != null);
}

test "status bar renders bypass permission mode" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.permission_mode = .bypass;

    const text = try render(std.testing.allocator, &state, .{ .width = 160 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "perm") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bypass") != null);
}

test "status bar renders backpressure indicator when active" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.backpressure_active = true;
    state.dropped_event_count = 5;

    const text = try render(std.testing.allocator, &state, .{ .width = 160 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "backpressure") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ":5") != null);
}

test "status bar renders drop count after backpressure clears" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.dropped_event_count = 12;

    const text = try render(std.testing.allocator, &state, .{ .width = 160 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "drops") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "backpressure") == null);
}

test "status bar does not render last error" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.status.setError(std.testing.allocator, "agent error");
    state.status.turn_count = 7;

    const text = try render(std.testing.allocator, &state, .{ .width = 160 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "turns") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "7") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "agent error") == null);
}

test "status bar truncates on whole segment boundaries at narrow width" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.status.setModelWithContext(std.testing.allocator, "claude-sonnet-4-5", "anthropic", 200_000);
    state.thinking_level = .medium;
    state.status.turn_count = 13;

    const full = try render(std.testing.allocator, &state, .{ .width = 200 });
    defer std.testing.allocator.free(full);
    try std.testing.expect(tui_text.visibleWidth(full) > 80);

    const text = try render(std.testing.allocator, &state, .{ .width = 80 });
    defer std.testing.allocator.free(text);
    try std.testing.expect(tui_text.visibleWidth(text) <= 80);
    try std.testing.expect(std.mem.indexOf(u8, text, "anthropic/claude-sonnet-4-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "…") != null);
    if (std.mem.indexOf(u8, text, "think") != null) {
        try std.testing.expect(std.mem.indexOf(u8, text, "medium") != null);
    }
    if (std.mem.indexOf(u8, text, "turns") != null) {
        try std.testing.expect(std.mem.indexOf(u8, text, "13") != null);
    }
}

test "status bar keeps whole segments monotonically as width grows" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.status.setModelWithContext(std.testing.allocator, "claude-sonnet-4-5", "anthropic", 200_000);
    state.thinking_level = .medium;
    state.status.turn_count = 13;

    var had_think = false;
    var had_turns = false;
    for ([_]usize{ 30, 60, 80, 100, 120, 160, 200 }) |width| {
        const text = try render(std.testing.allocator, &state, .{ .width = width });
        defer std.testing.allocator.free(text);
        try std.testing.expect(tui_text.visibleWidth(text) <= width);
        const has_think = std.mem.indexOf(u8, text, "think") != null and std.mem.indexOf(u8, text, "medium") != null;
        const has_turns = std.mem.indexOf(u8, text, "turns") != null and std.mem.indexOf(u8, text, "13") != null;
        if (std.mem.indexOf(u8, text, "think") != null) {
            try std.testing.expect(std.mem.indexOf(u8, text, "medium") != null);
        }
        if (std.mem.indexOf(u8, text, "medium") != null) {
            try std.testing.expect(std.mem.indexOf(u8, text, "think") != null);
        }
        if (std.mem.indexOf(u8, text, "turns") != null) {
            try std.testing.expect(std.mem.indexOf(u8, text, "13") != null);
        }
        if (std.mem.indexOf(u8, text, "13") != null) {
            try std.testing.expect(std.mem.indexOf(u8, text, "turns") != null);
        }
        try std.testing.expect(has_think or !had_think);
        try std.testing.expect(has_turns or !had_turns);
        had_think = has_think;
        had_turns = has_turns;
    }
    try std.testing.expect(had_think);
    try std.testing.expect(had_turns);
}

test "status bar clips model segment alone when nothing else fits" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.status.setModel(std.testing.allocator, "claude-opus-4-6-with-a-very-long-name", "anthropic");

    const text = try render(std.testing.allocator, &state, .{ .width = 20 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(tui_text.visibleWidth(text) <= 20);
    try std.testing.expect(std.mem.indexOf(u8, text, "…") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "think") == null);
}

test "status bar marks the cut when the first segment leaves no separator room" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.status.setModel(std.testing.allocator, "claude-opus", "claude");

    const text = try render(std.testing.allocator, &state, .{ .width = 20 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(tui_text.visibleWidth(text) <= 20);
    try std.testing.expect(std.mem.indexOf(u8, text, "claude/claude-opus") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "…") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "think") == null);
}

test "status bar marks the cut when the first segment exactly fills the width" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.status.setModel(std.testing.allocator, "claude-opus-4-6-x", "aa");

    const text = try render(std.testing.allocator, &state, .{ .width = 20 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(tui_text.visibleWidth(text) <= 20);
    try std.testing.expect(std.mem.indexOf(u8, text, "…") != null);
}
