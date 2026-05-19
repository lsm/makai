const std = @import("std");
const vaxis = @import("vaxis");

pub const Role = enum {
    system,
    user,
    assistant,
    tool,
};

pub const Message = struct {
    role: Role,
    text: []const u8,
};

pub const Transcript = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message),
    scroll_bottom: bool = true,

    pub fn init(allocator: std.mem.Allocator) Transcript {
        return .{
            .allocator = allocator,
            .messages = .empty,
        };
    }

    pub fn deinit(self: *Transcript) void {
        for (self.messages.items) |message| {
            self.allocator.free(message.text);
        }
        self.messages.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Transcript, role: Role, text: []const u8) !void {
        try self.messages.append(self.allocator, .{
            .role = role,
            .text = try self.allocator.dupe(u8, text),
        });
        self.scroll_bottom = true;
    }

    pub fn draw(self: Transcript, win: vaxis.Window) void {
        win.clear();

        const title_style: vaxis.Style = .{ .fg = .{ .index = 81 }, .bold = true };
        _ = win.printSegment(.{ .text = "Transcript", .style = title_style }, .{ .row_offset = 0, .wrap = .none });

        if (win.height <= 1) return;

        const body = win.child(.{ .y_off = 1, .height = win.height - 1 });
        const visible_rows = body.height;
        const start_index = if (self.messages.items.len > visible_rows)
            self.messages.items.len - visible_rows
        else
            0;

        var row: u16 = 0;
        for (self.messages.items[start_index..]) |message| {
            if (row >= body.height) break;
            const role_text = roleLabel(message.role);
            const role_style = roleStyle(message.role);
            const text_style: vaxis.Style = .{ .fg = .{ .index = 252 } };
            _ = body.print(&.{
                .{ .text = role_text, .style = role_style },
                .{ .text = message.text, .style = text_style },
            }, .{ .row_offset = row, .wrap = .none });
            row += 1;
        }
    }
};

fn roleLabel(role: Role) []const u8 {
    return switch (role) {
        .system => "system    ",
        .user => "user      ",
        .assistant => "assistant ",
        .tool => "tool      ",
    };
}

fn roleStyle(role: Role) vaxis.Style {
    return switch (role) {
        .system => .{ .fg = .{ .index = 245 }, .bold = true },
        .user => .{ .fg = .{ .index = 214 }, .bold = true },
        .assistant => .{ .fg = .{ .index = 83 }, .bold = true },
        .tool => .{ .fg = .{ .index = 141 }, .bold = true },
    };
}
