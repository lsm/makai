const std = @import("std");
const vaxis = @import("vaxis");

const Segment = vaxis.Cell.Segment;

pub const Composer = struct {
    allocator: std.mem.Allocator,
    input: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Composer {
        return .{
            .allocator = allocator,
            .input = .empty,
        };
    }

    pub fn deinit(self: *Composer) void {
        self.input.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn handleKey(self: *Composer, key: vaxis.Key) !?[]const u8 {
        if (key.matches(vaxis.Key.enter, .{})) {
            const submitted = try self.allocator.dupe(u8, self.input.items);
            self.input.clearRetainingCapacity();
            return submitted;
        }

        if (key.matches(vaxis.Key.backspace, .{})) {
            _ = self.input.pop();
            return null;
        }

        if (key.mods.ctrl or key.mods.alt or key.mods.super) return null;
        if (key.text) |text| {
            try self.input.appendSlice(self.allocator, text);
        }
        return null;
    }

    pub fn isQuitCommand(self: Composer) bool {
        return std.mem.eql(u8, std.mem.trim(u8, self.input.items, " \t\r\n"), "/quit");
    }

    pub fn draw(self: Composer, win: vaxis.Window) void {
        const border_style: vaxis.Style = .{ .fg = .{ .index = 67 } };
        const input_style: vaxis.Style = .{ .fg = .{ .index = 15 } };
        const hint_style: vaxis.Style = .{ .fg = .{ .index = 245 } };

        const inner = win.child(.{
            .border = .{ .where = .all, .style = border_style },
        });
        inner.clear();

        const prompt = Segment{ .text = "> ", .style = border_style };
        const text = Segment{ .text = self.input.items, .style = input_style };
        _ = inner.print(&.{ prompt, text }, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });

        if (self.input.items.len == 0 and inner.width > 2) {
            _ = inner.printSegment(.{ .text = "type message, Enter submits", .style = hint_style }, .{
                .row_offset = 0,
                .col_offset = 2,
                .wrap = .none,
            });
        }

        const max_col = inner.width -| 1;
        const wanted_col: u16 = @intCast(@min(self.input.items.len + 2, std.math.maxInt(u16)));
        inner.showCursor(@min(max_col, wanted_col), 0);
        inner.setCursorShape(.beam);
    }
};
