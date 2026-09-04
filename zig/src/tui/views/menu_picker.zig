const std = @import("std");
const tui_theme = @import("tui_theme");

pub const Item = struct {
    label: []const u8,
    detail: ?[]const u8 = null,
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

/// Render a bordered single-column selection menu: a title, then one row per
/// item with a ">" marker on the selected row. Shared by the /model and /login
/// pickers, which differ only in title and item source.
pub fn render(allocator: std.mem.Allocator, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    const title = try tui_theme.panelTitle().render(allocator, options.title);
    defer allocator.free(title);
    try writer.writeAll(title);
    if (options.subtitle) |subtitle| {
        const styled = try tui_theme.muted().render(allocator, subtitle);
        defer allocator.free(styled);
        try writer.writeByte('\n');
        try writer.writeAll(styled);
    }
    if (options.items.len == 0) {
        const none = try tui_theme.muted().render(allocator, options.empty_message);
        defer allocator.free(none);
        try writer.writeByte('\n');
        try writer.writeAll(none);
    } else {
        const end = @min(options.items.len, options.offset + options.height);
        for (options.items[options.offset..end], options.offset..) |item, i| {
            try writer.writeByte('\n');
            const marker = if (i == options.selected) ">" else " ";
            const row = if (item.detail) |detail|
                try std.fmt.allocPrint(allocator, "{s} {s} ({s})", .{ marker, item.label, detail })
            else
                try std.fmt.allocPrint(allocator, "{s} {s}", .{ marker, item.label });
            defer allocator.free(row);
            const styled = if (i == options.selected)
                try tui_theme.successText().render(allocator, row)
            else
                try tui_theme.muted().render(allocator, row);
            defer allocator.free(styled);
            try writer.writeAll(styled);
        }
    }
    if (options.footer) |footer| {
        const styled = try tui_theme.muted().render(allocator, footer);
        defer allocator.free(styled);
        try writer.writeByte('\n');
        try writer.writeByte('\n');
        try writer.writeAll(styled);
    }
    const body = try out.toOwnedSlice();
    defer allocator.free(body);
    return tui_theme.panel().width(@intCast(@min(options.width -| 4, std.math.maxInt(u16)))).render(allocator, body);
}

test "menu picker marks the selected row" {
    const items = [_]Item{
        .{ .label = "claude-opus", .detail = "anthropic" },
        .{ .label = "gpt-4o", .detail = "openai" },
    };
    const text = try render(std.testing.allocator, .{ .title = "Select model", .items = &items, .selected = 1 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "claude-opus (anthropic)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "> gpt-4o (openai)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Select model") != null);
}

test "menu picker renders items without detail" {
    const items = [_]Item{
        .{ .label = "anthropic" },
        .{ .label = "google" },
    };
    const text = try render(std.testing.allocator, .{ .title = "Login provider", .items = &items, .selected = 0 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "> anthropic") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "google") != null);
}

test "menu picker shows empty message" {
    const text = try render(std.testing.allocator, .{ .title = "Select model", .items = &.{}, .empty_message = "  no models" });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "no models") != null);
}

test "menu picker honors offset for scrolling" {
    const items = [_]Item{
        .{ .label = "a" },
        .{ .label = "b" },
        .{ .label = "c" },
    };
    const text = try render(std.testing.allocator, .{ .title = "x", .items = &items, .selected = 2, .height = 2, .offset = 1 });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, " a") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, " b") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "> c") != null);
}

test "menu picker renders subtitle and footer" {
    const items = [_]Item{.{ .label = "Copy", .detail = "copy detail" }};
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
}
