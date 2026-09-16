const std = @import("std");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");
const tui_render = @import("tui_render");

pub const Item = struct {
    label: []const u8,
    detail: ?[]const u8 = null,
    badge: ?[]const u8 = null,
};

pub const Options = struct {
    title: []const u8,
    subtitle: ?[]const u8 = null,
    footer: ?[]const u8 = null,
    items: []const Item,
    selected: usize = 0,
    width: usize = 80,
    height: usize = 12,
    offset: usize = 0,
    empty_message: []const u8 = "  (nothing to select)",
};

const marker_width: usize = 2;
const detail_gap: usize = 2;

pub fn render(allocator: std.mem.Allocator, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    const inner_width = options.width -| 4;
    var first = true;

    if (options.subtitle) |subtitle| {
        const styled = try tui_theme.muted().render(allocator, subtitle);
        defer allocator.free(styled);
        try writer.writeAll(styled);
        first = false;
    }
    if (options.items.len == 0) {
        const none = try tui_theme.muted().render(allocator, options.empty_message);
        defer allocator.free(none);
        if (!first) try writer.writeByte('\n');
        try writer.writeAll(none);
        first = false;
    } else {
        const end = @min(options.items.len, options.offset + @max(options.height, 1));
        const label_col = labelColumn(options.items[options.offset..end], inner_width);
        for (options.items[options.offset..end], options.offset..) |item, i| {
            if (!first) try writer.writeByte('\n');
            first = false;
            const row = try renderRow(allocator, item, i == options.selected, label_col, inner_width);
            defer allocator.free(row);
            try writer.writeAll(row);
        }
        if (options.items.len > end - options.offset) {
            const position = try std.fmt.allocPrint(allocator, "{d}–{d} of {d}", .{ options.offset + 1, end, options.items.len });
            defer allocator.free(position);
            const styled = try tui_theme.dim().render(allocator, position);
            defer allocator.free(styled);
            try writer.writeByte('\n');
            try writeSpaces(writer, inner_width -| tui_text.visibleWidth(position));
            try writer.writeAll(styled);
        }
    }
    if (options.footer) |footer| {
        const styled = try tui_theme.keyHint().render(allocator, footer);
        defer allocator.free(styled);
        try writer.writeByte('\n');
        try writer.writeAll(styled);
    }
    const body = try out.toOwnedSlice();
    defer allocator.free(body);
    return tui_theme.titledPanel(allocator, body, .{ .title = options.title, .width = options.width, .border = tui_theme.palette.accent_dim });
}

fn labelColumn(items: []const Item, inner_width: usize) usize {
    var widest: usize = 0;
    for (items) |item| widest = @max(widest, tui_text.visibleWidth(item.label));
    return @min(widest + marker_width + detail_gap, inner_width / 2 + marker_width);
}

fn renderRow(allocator: std.mem.Allocator, item: Item, selected: bool, label_col: usize, inner_width: usize) ![]const u8 {
    var plain: std.Io.Writer.Allocating = .init(allocator);
    defer plain.deinit();
    const pw = &plain.writer;
    try pw.writeAll(if (selected) tui_theme.glyph.select ++ " " else "  ");
    const label = try tui_text.truncateLineToWidth(allocator, item.label, inner_width -| marker_width);
    defer allocator.free(label);
    try pw.writeAll(label);
    var used = marker_width + tui_text.visibleWidth(label);
    if (item.detail) |detail| {
        if (detail.len > 0 and used + detail_gap < inner_width) {
            const target = @max(label_col, used + detail_gap);
            try writeSpaces(pw, target - used);
            used = target;
            const clipped = try tui_text.truncateLineToWidth(allocator, detail, inner_width -| used);
            defer allocator.free(clipped);
            try pw.writeAll(clipped);
            used += tui_text.visibleWidth(clipped);
        }
    }
    if (item.badge) |badge| {
        const badge_width = tui_text.visibleWidth(badge);
        if (used + 2 + badge_width <= inner_width) {
            try writeSpaces(pw, inner_width - used - badge_width);
            try pw.writeAll(badge);
            used = inner_width;
        }
    }
    try writeSpaces(pw, inner_width -| used);

    const text = plain.written();
    if (selected) return try tui_theme.selectionRow().render(allocator, text);

    var styled: std.Io.Writer.Allocating = .init(allocator);
    errdefer styled.deinit();
    const detail_start = marker_width + tui_text.visibleWidth(label);
    const head = try tui_theme.soft().render(allocator, text[0..@min(text.len, byteIndexForWidth(text, detail_start))]);
    defer allocator.free(head);
    const tail = try tui_theme.dim().render(allocator, text[@min(text.len, byteIndexForWidth(text, detail_start))..]);
    defer allocator.free(tail);
    try styled.writer.writeAll(head);
    try styled.writer.writeAll(tail);
    return styled.toOwnedSlice();
}

fn byteIndexForWidth(text: []const u8, width: usize) usize {
    var i: usize = 0;
    var used: usize = 0;
    while (i < text.len and used < width) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const take = @min(len, text.len - i);
        used += tui_text.visibleWidth(text[i .. i + take]);
        i += take;
    }
    return i;
}

fn writeSpaces(writer: *std.Io.Writer, count: usize) !void {
    for (0..count) |_| try writer.writeByte(' ');
}

test "menu picker marks the selected row" {
    const items = [_]Item{
        .{ .label = "claude-opus", .detail = "anthropic" },
        .{ .label = "gpt-4o", .detail = "openai" },
    };
    const text = try render(std.testing.allocator, .{ .title = "Select model", .items = &items, .selected = 1, .width = 60 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "claude-opus") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "anthropic") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, tui_theme.glyph.select ++ " gpt-4o") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, tui_theme.glyph.select ++ " claude-opus") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Select model") != null);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try std.testing.expectEqual(@as(usize, 60), tui_text.visibleWidth(line));
}

test "menu picker renders items without detail" {
    const items = [_]Item{
        .{ .label = "anthropic" },
        .{ .label = "google" },
    };
    const text = try render(std.testing.allocator, .{ .title = "Login provider", .items = &items, .selected = 0 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, tui_theme.glyph.select ++ " anthropic") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "google") != null);
}

test "menu picker shows empty message" {
    const text = try render(std.testing.allocator, .{ .title = "Select model", .items = &.{}, .empty_message = "  no models" });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "no models") != null);
}

test "menu picker honors offset for scrolling and shows position" {
    const items = [_]Item{
        .{ .label = "a" },
        .{ .label = "b" },
        .{ .label = "c" },
    };
    const text = try render(std.testing.allocator, .{ .title = "x", .items = &items, .selected = 2, .height = 2, .offset = 1 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "  a") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  b") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, tui_theme.glyph.select ++ " c") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2–3 of 3") != null);
}

test "menu picker renders subtitle footer and badge" {
    const items = [_]Item{.{ .label = "Copy", .detail = "copy detail", .badge = "current" }};
    const text = try render(std.testing.allocator, .{
        .title = "Export conversation",
        .subtitle = "Select export method",
        .footer = "Esc to cancel",
        .items = &items,
    });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Export conversation") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Select export method") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Esc to cancel") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "current") != null);
}
