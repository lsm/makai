const std = @import("std");
const tui_state = @import("tui_state");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");

pub const Options = struct {
    width: usize = 80,
    height: usize = 12,
    offset: usize = 0,
};

pub fn render(allocator: std.mem.Allocator, state: *const tui_state.AppState, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    const title = try tui_theme.panelTitle().render(allocator, "Sessions");
    defer allocator.free(title);
    try writer.writeAll(title);

    const query = state.sessionFilterText();
    const search_line = try std.fmt.allocPrint(allocator, "  Search: {s}", .{if (query.len > 0) query else "(type to filter)"});
    defer allocator.free(search_line);
    const styled_search = try tui_theme.muted().render(allocator, search_line);
    defer allocator.free(styled_search);
    try writer.writeByte('\n');
    try writer.writeAll(styled_search);

    if (state.sessions.items.len == 0) {
        const none = try tui_theme.muted().render(allocator, "  no saved sessions");
        defer allocator.free(none);
        try writer.writeByte('\n');
        try writer.writeAll(none);
        return renderPanel(allocator, &out, options.width);
    }

    const filtered_count = state.filteredSessionCount();
    if (filtered_count == 0) {
        const empty = try std.fmt.allocPrint(allocator, "  No sessions match '{s}'", .{query});
        defer allocator.free(empty);
        const styled = try tui_theme.muted().render(allocator, empty);
        defer allocator.free(styled);
        try writer.writeByte('\n');
        try writer.writeAll(styled);
        return renderPanel(allocator, &out, options.width);
    }

    const end = @min(filtered_count, options.offset + options.height);
    var i = options.offset;
    while (i < end) : (i += 1) {
        const session = state.sessionAtFilteredIndex(i) orelse continue;
        try writer.writeByte('\n');
        const marker = if (i == state.session_index) ">" else " ";
        const row = try std.fmt.allocPrint(allocator, "{s} {s} ({s})", .{ marker, session.label, session.id });
        defer allocator.free(row);
        const styled = if (i == state.session_index) try tui_theme.successText().render(allocator, row) else try tui_theme.muted().render(allocator, row);
        defer allocator.free(styled);
        try writer.writeAll(styled);
    }
    return renderPanel(allocator, &out, options.width);
}

fn renderPanel(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating, width: usize) ![]const u8 {
    const body = try out.toOwnedSlice();
    defer allocator.free(body);
    return tui_theme.panel().width(@intCast(@min(width -| 4, std.math.maxInt(u16)))).render(allocator, body);
}

test "session picker renders selected session" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.addSession("s1", "First");
    try state.addSession("s2", "Second");
    state.session_index = 1;

    const text = try render(std.testing.allocator, &state, .{ .height = 4 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "First (s1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "> Second (s2)") != null);
    try std.testing.expect(tui_text.visibleWidth(text) > 0);
}

test "session picker renders from offset" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.addSession("s1", "First");
    try state.addSession("s2", "Second");
    try state.addSession("s3", "Third");
    state.session_index = 2;
    state.session_scroll = 1;

    const text = try render(std.testing.allocator, &state, .{ .height = 2, .offset = state.session_scroll });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "First (s1)") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Second (s2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "> Third (s3)") != null);
}

fn setFilter(state: *tui_state.AppState, text: []const u8) !void {
    state.session_filter.clear();
    try state.session_filter.insertSlice(std.testing.allocator, text);
    state.clampSessionSelectionToFilter();
}

test "session picker filters by title and id" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.addSessionWithDetails("session-alpha", "Alpha project", "claude-sonnet", "anthropic");
    try state.addSessionWithDetails("session-beta", "Beta project", "gpt-4o", "openai");

    try setFilter(&state, "beta");
    const by_title = try render(std.testing.allocator, &state, .{ .height = 4 });
    defer std.testing.allocator.free(by_title);
    try std.testing.expect(std.mem.indexOf(u8, by_title, "Beta project (session-beta)") != null);
    try std.testing.expect(std.mem.indexOf(u8, by_title, "Alpha project") == null);

    try setFilter(&state, "alpha");
    const by_id = try render(std.testing.allocator, &state, .{ .height = 4 });
    defer std.testing.allocator.free(by_id);
    try std.testing.expect(std.mem.indexOf(u8, by_id, "Alpha project (session-alpha)") != null);
    try std.testing.expect(std.mem.indexOf(u8, by_id, "Beta project") == null);
}

test "session picker filters by model and provider" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.addSessionWithDetails("s1", "First", "claude-sonnet", "anthropic");
    try state.addSessionWithDetails("s2", "Second", "gpt-4o", "openai");
    try state.addSessionWithDetails("s3", "Third", "gemini", "google");

    try setFilter(&state, "gpt");
    const by_model = try render(std.testing.allocator, &state, .{ .height = 4 });
    defer std.testing.allocator.free(by_model);
    try std.testing.expect(std.mem.indexOf(u8, by_model, "Second (s2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, by_model, "First (s1)") == null);

    try setFilter(&state, "google");
    const by_provider = try render(std.testing.allocator, &state, .{ .height = 4 });
    defer std.testing.allocator.free(by_provider);
    try std.testing.expect(std.mem.indexOf(u8, by_provider, "Third (s3)") != null);
    try std.testing.expect(std.mem.indexOf(u8, by_provider, "Second (s2)") == null);
}

test "session picker empty filter shows all sessions" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.addSession("s1", "First");
    try state.addSession("s2", "Second");

    const text = try render(std.testing.allocator, &state, .{ .height = 4 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "First (s1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Second (s2)") != null);
}

test "session picker empty result state names query" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.addSession("s1", "First");
    try setFilter(&state, "missing");

    const text = try render(std.testing.allocator, &state, .{ .height = 4 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "No sessions match 'missing'") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "First (s1)") == null);
}

test "session picker clamps selection after filter changes" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.addSessionWithDetails("s1", "First", "claude", "anthropic");
    try state.addSessionWithDetails("s2", "Second", "gpt", "openai");
    try state.addSessionWithDetails("s3", "Third", "gemini", "google");
    state.session_index = 2;
    state.session_scroll = 2;

    try setFilter(&state, "openai");

    try std.testing.expectEqual(@as(usize, 1), state.filteredSessionCount());
    try std.testing.expectEqual(@as(usize, 0), state.session_index);
    try std.testing.expectEqual(@as(usize, 0), state.session_scroll);
    try std.testing.expectEqual(@as(usize, 1), state.sessionRawIndexAtFilteredIndex(state.session_index).?);
}
