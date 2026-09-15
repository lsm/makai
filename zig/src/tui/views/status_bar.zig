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

    try pushOwnedValue(&segments, allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider, model }), tui_theme.statusSegment());
    try writeContext(&segments, allocator, state);
    try pushOwnedValue(&segments, allocator, try estimatedCost(allocator, state), tui_theme.statusSegment());
    try writeState(&segments, allocator, state);
    if (state.queue.total() > 0) {
        try pushOwnedSegment(&segments, allocator, "queue", try std.fmt.allocPrint(allocator, "{d}", .{state.queue.total()}));
    }
    if (state.backpressure_active or state.dropped_event_count > 0) {
        const label: []const u8 = if (state.backpressure_active) "backpressure" else "drops";
        const value = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ label, state.dropped_event_count });
        if (state.backpressure_active) {
            try pushOwnedValue(&segments, allocator, value, tui_theme.warningText());
        } else {
            try pushOwnedSegment(&segments, allocator, "drops", value);
        }
    }
    if (state.mode == .approval) {
        try pushStyledValue(&segments, allocator, "perm", "pending", tui_theme.warningText());
    } else if (state.permission_mode == .bypass) {
        try pushStyledValue(&segments, allocator, "perm", "bypass", tui_theme.warningText());
    } else {
        try pushSegment(&segments, allocator, "perm", @tagName(state.permission_mode));
    }
    try pushSegment(&segments, allocator, "think", @tagName(state.thinking_level));
    try pushOwnedSegment(&segments, allocator, "turns", try std.fmt.allocPrint(allocator, "{d}", .{state.status.turn_count}));

    return layoutSegments(allocator, segments.items, options.width);
}

fn layoutSegments(allocator: std.mem.Allocator, segments: []const Segment, width: usize) ![]u8 {
    if (segments.len == 0) return allocator.dupe(u8, "");
    const sep = try tui_theme.dim().render(allocator, " " ++ tui_theme.glyph.sep ++ " ");
    defer allocator.free(sep);
    const sep_width = tui_text.visibleWidth(sep);

    var total: usize = 0;
    for (segments) |seg| total += seg.width;
    total += sep_width * (segments.len - 1);

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
        if (kept == 0) return tui_text.truncateToWidth(allocator, segments[0].styled, width);
    }

    const ellipsis = try tui_theme.dim().render(allocator, "…");
    defer allocator.free(ellipsis);
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

fn writeContext(list: *SegmentList, allocator: std.mem.Allocator, state: *const tui_state.AppState) !void {
    const used: u64 = if (state.telemetry.estimated_tokens > 0) state.telemetry.estimated_tokens else state.status.context_used;
    const limit: u64 = if (state.telemetry.context_window > 0) state.telemetry.context_window else state.status.context_limit;
    const pct: u64 = if (limit > 0) (used * 100) / limit else 0;
    var gauge = zz.Gauge{
        .value = @floatFromInt(pct),
        .min = 0,
        .max = 100,
        .width = 8,
        .show_value = false,
        .show_percent = false,
        .thresholds = &gauge_thresholds,
        .base_color = tui_theme.palette.success,
        .empty_color = tui_theme.palette.dim,
    };
    var gauge_arena = std.heap.ArenaAllocator.init(allocator);
    defer gauge_arena.deinit();
    const gauge_text = gauge.view(gauge_arena.allocator());
    const used_text = try tui_text.compactNumber(allocator, used);
    defer allocator.free(used_text);
    if (limit > 0) {
        const limit_text = try tui_text.compactNumber(allocator, limit);
        defer allocator.free(limit_text);
        try pushOwnedSegment(list, allocator, "ctx", try std.fmt.allocPrint(allocator, "{s} {d}% {s}/{s}", .{ gauge_text, pct, used_text, limit_text }));
    } else {
        try pushOwnedSegment(list, allocator, "ctx", try std.fmt.allocPrint(allocator, "{s} {s}", .{ gauge_text, used_text }));
    }
}

fn writeState(list: *SegmentList, allocator: std.mem.Allocator, state: *const tui_state.AppState) !void {
    if (state.status.streaming) {
        const value = try std.fmt.allocPrint(allocator, "{s} streaming", .{tui_theme.spinnerFrame(state.anim_tick)});
        defer allocator.free(value);
        try pushValue(list, allocator, value, tui_theme.runningText());
    } else {
        try pushValue(list, allocator, tui_theme.glyph.system ++ " idle", tui_theme.muted());
    }
}

fn estimatedCost(allocator: std.mem.Allocator, state: *const tui_state.AppState) ![]u8 {
    const tokens: f64 = @floatFromInt(if (state.telemetry.estimated_tokens > 0) state.telemetry.estimated_tokens else state.status.context_used);
    const dollars = (tokens / 1_000_000.0) * 3.0;
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
    errdefer allocator.free(styled);
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

    const text = try render(std.testing.allocator, &state, .{ .width = 160 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "ctx") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "$") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "perm") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "think") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "low") != null);
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
    state.status.turn_count = 3;

    const full = try render(std.testing.allocator, &state, .{ .width = 200 });
    defer std.testing.allocator.free(full);
    try std.testing.expect(tui_text.visibleWidth(full) > 100);

    const text = try render(std.testing.allocator, &state, .{ .width = 100 });
    defer std.testing.allocator.free(text);
    try std.testing.expect(tui_text.visibleWidth(text) <= 100);
    try std.testing.expect(std.mem.indexOf(u8, text, "anthropic/claude-sonnet-4-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "…") != null);
    if (std.mem.indexOf(u8, text, "think") != null) {
        try std.testing.expect(std.mem.indexOf(u8, text, "think:medium") != null);
    }
    if (std.mem.indexOf(u8, text, "turns") != null) {
        try std.testing.expect(std.mem.indexOf(u8, text, "turns:3") != null);
    }
}

test "status bar keeps whole segments monotonically as width grows" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.status.setModelWithContext(std.testing.allocator, "claude-sonnet-4-5", "anthropic", 200_000);
    state.thinking_level = .medium;
    state.status.turn_count = 3;

    var had_think = false;
    var had_turns = false;
    for ([_]usize{ 30, 60, 80, 100, 120, 160, 200 }) |width| {
        const text = try render(std.testing.allocator, &state, .{ .width = width });
        defer std.testing.allocator.free(text);
        try std.testing.expect(tui_text.visibleWidth(text) <= width);
        const has_think = std.mem.indexOf(u8, text, "think:medium") != null;
        const has_turns = std.mem.indexOf(u8, text, "turns:3") != null;
        if (std.mem.indexOf(u8, text, "think") != null) {
            try std.testing.expect(has_think);
        }
        if (std.mem.indexOf(u8, text, "turns") != null) {
            try std.testing.expect(has_turns);
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
