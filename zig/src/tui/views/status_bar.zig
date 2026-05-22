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
    errdefer out.deinit();
    const writer = &out.writer;
    const model = if (state.status.model.len > 0) state.status.model else "no-model";
    const provider = if (state.status.provider.len > 0) state.status.provider else "local";
    const stream = if (state.status.streaming) "streaming" else "idle";
    const perm = if (state.mode == .approval) "pending" else "ask";

    try writeOwnedSegment(writer, allocator, "model", try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider, model }));
    try writer.writeAll(" • ");
    try writeContext(writer, allocator, state);
    try writer.writeAll(" • ");
    try writeOwnedSegment(writer, allocator, "cost", try estimatedCost(allocator, state));
    try writer.writeAll(" • ");
    try writeStyledValue(writer, allocator, "state", stream, if (state.status.streaming) tui_theme.successText() else tui_theme.muted());
    try writer.writeAll(" • ");
    try writeSegment(writer, allocator, "perm", perm);
    try writer.writeAll(" • ");
    try writeOwnedSegment(writer, allocator, "turns", try std.fmt.allocPrint(allocator, "{d}", .{state.status.turn_count}));
    if (state.status.last_error.len > 0) {
        try writer.writeAll(" • ");
        const err = try tui_theme.errorText().render(allocator, state.status.last_error);
        defer allocator.free(err);
        try writer.writeAll(err);
    }

    const items = out.written();
    if (tui_text.visibleWidth(items) > options.width) {
        const clipped = try tui_text.truncateToWidth(allocator, items, options.width);
        out.deinit();
        return clipped;
    }
    return out.toOwnedSlice();
}

fn writeContext(writer: *std.Io.Writer, allocator: std.mem.Allocator, state: *const tui_state.AppState) !void {
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
    const used_text = try compactNumber(allocator, used);
    defer allocator.free(used_text);
    if (limit > 0) {
        const limit_text = try compactNumber(allocator, limit);
        defer allocator.free(limit_text);
        try writeOwnedSegment(writer, allocator, "ctx", try std.fmt.allocPrint(allocator, "{s} {d}% {s}/{s}", .{ gauge_text, pct, used_text, limit_text }));
    } else {
        try writeOwnedSegment(writer, allocator, "ctx", try std.fmt.allocPrint(allocator, "{s} {s}", .{ gauge_text, used_text }));
    }
}

fn estimatedCost(allocator: std.mem.Allocator, state: *const tui_state.AppState) ![]u8 {
    const tokens: f64 = @floatFromInt(if (state.telemetry.estimated_tokens > 0) state.telemetry.estimated_tokens else state.status.context_used);
    const dollars = (tokens / 1_000_000.0) * 3.0;
    return std.fmt.allocPrint(allocator, "${d:.4}", .{dollars});
}

fn compactNumber(allocator: std.mem.Allocator, value: u64) ![]u8 {
    if (value >= 1_000_000) return std.fmt.allocPrint(allocator, "{d}M", .{value / 1_000_000});
    if (value >= 1_000) return std.fmt.allocPrint(allocator, "{d}k", .{value / 1_000});
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

fn writeSegment(writer: *std.Io.Writer, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try writeStyledValue(writer, allocator, key, value, tui_theme.statusSegment());
}

fn writeStyledValue(writer: *std.Io.Writer, allocator: std.mem.Allocator, key: []const u8, value: []const u8, value_style: zz.Style) !void {
    const styled_key = try tui_theme.statusKey().render(allocator, key);
    defer allocator.free(styled_key);
    const styled_value = try value_style.render(allocator, value);
    defer allocator.free(styled_value);
    try writer.print("{s}:{s}", .{ styled_key, styled_value });
}

fn writeOwnedSegment(writer: *std.Io.Writer, allocator: std.mem.Allocator, key: []const u8, value: []u8) !void {
    defer allocator.free(value);
    try writeSegment(writer, allocator, key, value);
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

test "status bar renders context gauge cost and permission" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.status.setModelWithContext(std.testing.allocator, "claude", "anthropic", 200_000);
    state.telemetry.estimated_tokens = 10_000;
    state.telemetry.context_window = 200_000;

    const text = try render(std.testing.allocator, &state, .{ .width = 160 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "ctx") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cost") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "perm") != null);
}
