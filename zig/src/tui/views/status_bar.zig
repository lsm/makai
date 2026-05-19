const std = @import("std");
const vaxis = @import("vaxis");

const Segment = vaxis.Cell.Segment;

pub const Status = struct {
    provider: []const u8 = "anthropic",
    model: []const u8 = "claude-sonnet-4-5",
    state: []const u8 = "streaming mock events",
};

pub fn draw(win: vaxis.Window, status: Status) void {
    const bg: vaxis.Style = .{
        .fg = .{ .index = 15 },
        .bg = .{ .index = 24 },
        .bold = true,
    };
    win.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = bg });

    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, " {s}/{s} | {s} | Ctrl+C or /quit exits ", .{
        status.provider,
        status.model,
        status.state,
    }) catch " Makai TUI | status overflow ";

    _ = win.printSegment(.{ .text = line, .style = bg }, .{ .wrap = .none });
}
