
const std = @import("std");
const Writer = std.Io.Writer;
const measure = @import("measure.zig");

pub const Layer = struct {
    content: []const u8,
    x: u16 = 0,
    y: u16 = 0,
    z: i16 = 0,
    transparent: bool = true,
};

pub const LayerStack = struct {
    allocator: std.mem.Allocator,
    layers: std.array_list.Managed(Layer),
    width: u16 = 80,
    height: u16 = 24,
    background: u8 = ' ',

    pub fn init(allocator: std.mem.Allocator) LayerStack {
        return .{
            .allocator = allocator,
            .layers = std.array_list.Managed(Layer).init(allocator),
        };
    }

    pub fn deinit(self: *LayerStack) void {
        self.layers.deinit();
    }

    pub fn setSize(self: *LayerStack, w: u16, h: u16) void {
        self.width = w;
        self.height = h;
    }

    pub fn push(self: *LayerStack, layer: Layer) !void {
        try self.layers.append(layer);
    }

    pub fn clear(self: *LayerStack) void {
        self.layers.clearRetainingCapacity();
    }

    pub fn render(self: *const LayerStack, allocator: std.mem.Allocator) []const u8 {
        const w: usize = self.width;
        const h: usize = self.height;

        const grid = allocator.alloc(Cell, w * h) catch return "";

        for (grid) |*cell| {
            cell.* = .{ .char = self.background, .ansi_prefix = "" };
        }

        const sorted = allocator.alloc(Layer, self.layers.items.len) catch return "";
        @memcpy(sorted, self.layers.items);
        std.mem.sort(Layer, sorted, {}, struct {
            fn lessThan(_: void, a: Layer, b: Layer) bool {
                return a.z < b.z;
            }
        }.lessThan);

        for (sorted) |layer| {
            self.paintLayer(grid, w, h, layer);
        }

        var result: Writer.Allocating = .init(allocator);
        const writer = &result.writer;

        for (0..h) |row| {
            if (row > 0) writer.writeByte('\n') catch {};
            for (0..w) |col| {
                const cell = grid[row * w + col];
                if (cell.ansi_prefix.len > 0) {
                    writer.writeAll(cell.ansi_prefix) catch {};
                    writer.writeByte(cell.char) catch {};
                    writer.writeAll("\x1b[0m") catch {};
                } else {
                    writer.writeByte(cell.char) catch {};
                }
            }
        }

        return result.toArrayList().items;
    }

    fn paintLayer(self: *const LayerStack, grid: []Cell, w: usize, h: usize, layer: Layer) void {
        _ = self;
        const content = layer.content;
        var row: usize = layer.y;
        var col: usize = layer.x;
        var i: usize = 0;
        var current_ansi: []const u8 = "";

        while (i < content.len and row < h) {
            if (content[i] == '\n') {
                row += 1;
                col = layer.x;
                i += 1;
                continue;
            }

            if (content[i] == 0x1b and i + 1 < content.len and content[i + 1] == '[') {
                const seq_start = i;
                i += 2;
                while (i < content.len and content[i] != 'm' and content[i] != 'H' and content[i] != 'J' and content[i] != 'K') : (i += 1) {}
                if (i < content.len) {
                    i += 1;
                    if (content[seq_start + 2 .. i - 1].len == 1 and content[seq_start + 2] == '0') {
                        current_ansi = "";
                    } else {
                        current_ansi = content[seq_start..i];
                    }
                }
                continue;
            }

            if (col < w) {
                const is_transparent = layer.transparent and content[i] == ' ' and current_ansi.len == 0;
                if (!is_transparent) {
                    grid[row * w + col] = .{
                        .char = content[i],
                        .ansi_prefix = current_ansi,
                    };
                }
                col += 1;
            }
            i += 1;
        }
    }
};

const Cell = struct {
    char: u8 = ' ',
    ansi_prefix: []const u8 = "",
};
