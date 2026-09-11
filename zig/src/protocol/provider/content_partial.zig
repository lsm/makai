const std = @import("std");
const ai_types = @import("ai_types");
pub const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const TextPartial = struct {
    accumulated_len: usize = 0,
};

pub const ThinkingPartial = struct {
    accumulated_len: usize = 0,
};

pub const ToolCallPartial = struct {
    id: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    name: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    json_len: usize = 0,

    pub fn getId(self: *const ToolCallPartial) ?[]const u8 {
        const id = self.id.slice();
        return if (id.len > 0) id else null;
    }

    pub fn getName(self: *const ToolCallPartial) ?[]const u8 {
        const name = self.name.slice();
        return if (name.len > 0) name else null;
    }

    pub fn deinit(self: *ToolCallPartial, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.name.deinit(allocator);
    }
};

pub const ContentBlockPartial = union(enum) {
    text: TextPartial,
    thinking: ThinkingPartial,
    tool_call: ToolCallPartial,
    inactive: void,

    pub fn deinit(self: *ContentBlockPartial, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tool_call => |*tc| tc.deinit(allocator),
            .text, .thinking, .inactive => {},
        }
    }
};

pub const MessagePartial = struct {
    allocator: std.mem.Allocator,

    blocks: std.AutoHashMap(usize, ContentBlockPartial),

    usage: ai_types.Usage,

    model: []const u8 = "",
    api: []const u8 = "",
    provider: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) MessagePartial {
        return .{
            .allocator = allocator,
            .blocks = std.AutoHashMap(usize, ContentBlockPartial).init(allocator),
            .usage = .{},
        };
    }

    pub fn deinit(self: *MessagePartial) void {
        var iter = self.blocks.iterator();
        while (iter.next()) |entry| {
            var partial = entry.value_ptr.*;
            partial.deinit(self.allocator);
        }
        self.blocks.deinit();
    }

    pub fn getBlockPartial(self: *MessagePartial, content_index: usize) ?ContentBlockPartial {
        return self.blocks.get(content_index);
    }

    pub fn updateBlockPartial(self: *MessagePartial, content_index: usize, partial: ContentBlockPartial) !void {
        if (self.blocks.fetchRemove(content_index)) |old| {
            var old_partial = old.value;
            old_partial.deinit(self.allocator);
        }
        try self.blocks.put(content_index, partial);
    }

    pub fn ensureBlock(self: *MessagePartial, content_index: usize) !void {
        if (!self.blocks.contains(content_index)) {
            try self.blocks.put(content_index, .{ .inactive = {} });
        }
    }
};

test "MessagePartial init and deinit" {
    var partial = MessagePartial.init(std.testing.allocator);
    defer partial.deinit();

    try std.testing.expect(partial.blocks.count() == 0);
    try std.testing.expect(partial.usage.input == 0);
    try std.testing.expect(partial.usage.output == 0);
}

test "ContentBlockPartial deinit frees owned strings" {
    const id = try std.testing.allocator.dupe(u8, "tool-123");
    const name = try std.testing.allocator.dupe(u8, "bash");

    var partial: ContentBlockPartial = .{
        .tool_call = .{
            .id = OwnedSlice(u8).initOwned(id),
            .name = OwnedSlice(u8).initOwned(name),
            .json_len = 10,
        },
    };

    partial.deinit(std.testing.allocator);
}

test "getBlockPartial returns null for missing block" {
    var partial = MessagePartial.init(std.testing.allocator);
    defer partial.deinit();

    try std.testing.expect(partial.getBlockPartial(0) == null);
    try std.testing.expect(partial.getBlockPartial(42) == null);
}

test "updateBlockPartial stores partial correctly" {
    var partial = MessagePartial.init(std.testing.allocator);
    defer partial.deinit();

    try partial.updateBlockPartial(0, .{ .text = .{ .accumulated_len = 100 } });
    try partial.updateBlockPartial(2, .{ .thinking = .{ .accumulated_len = 50 } });

    const text_block = partial.getBlockPartial(0);
    try std.testing.expect(text_block != null);
    if (text_block) |b| {
        try std.testing.expectEqual(@as(@TypeOf(b), .{ .text = .{ .accumulated_len = 100 } }), b);
    }

    const thinking_block = partial.getBlockPartial(2);
    try std.testing.expect(thinking_block != null);
    if (thinking_block) |b| {
        try std.testing.expectEqual(@as(@TypeOf(b), .{ .thinking = .{ .accumulated_len = 50 } }), b);
    }

    try std.testing.expect(partial.getBlockPartial(1) == null);
}

test "ensureBlock creates inactive block if missing" {
    var partial = MessagePartial.init(std.testing.allocator);
    defer partial.deinit();

    try std.testing.expect(partial.getBlockPartial(0) == null);

    try partial.ensureBlock(0);

    const block = partial.getBlockPartial(0);
    try std.testing.expect(block != null);
    if (block) |b| {
        try std.testing.expectEqual(@as(@TypeOf(b), .{ .inactive = {} }), b);
    }

    try partial.updateBlockPartial(0, .{ .text = .{ .accumulated_len = 10 } });
    try partial.ensureBlock(0);

    const existing = partial.getBlockPartial(0);
    try std.testing.expect(existing != null);
    if (existing) |b| {
        try std.testing.expectEqual(@as(@TypeOf(b), .{ .text = .{ .accumulated_len = 10 } }), b);
    }
}

test "updateBlockPartial replaces and frees old partial" {
    var partial = MessagePartial.init(std.testing.allocator);
    defer partial.deinit();

    const id1 = try std.testing.allocator.dupe(u8, "tool-old");
    const name1 = try std.testing.allocator.dupe(u8, "old-tool");

    try partial.updateBlockPartial(0, .{
        .tool_call = .{
            .id = OwnedSlice(u8).initOwned(id1),
            .name = OwnedSlice(u8).initOwned(name1),
            .json_len = 5,
        },
    });

    const id2 = try std.testing.allocator.dupe(u8, "tool-new");
    const name2 = try std.testing.allocator.dupe(u8, "new-tool");

    try partial.updateBlockPartial(0, .{
        .tool_call = .{
            .id = OwnedSlice(u8).initOwned(id2),
            .name = OwnedSlice(u8).initOwned(name2),
            .json_len = 10,
        },
    });

    const block = partial.getBlockPartial(0);
    try std.testing.expect(block != null);
    if (block) |b| {
        try std.testing.expectEqualStrings("tool-new", b.tool_call.getId().?);
        try std.testing.expectEqualStrings("new-tool", b.tool_call.getName().?);
        try std.testing.expectEqual(@as(usize, 10), b.tool_call.json_len);
    }
}

test "MessagePartial usage tracking" {
    var partial = MessagePartial.init(std.testing.allocator);
    defer partial.deinit();

    partial.usage.input = 100;
    partial.usage.output = 50;
    partial.usage.cache_read = 20;
    partial.usage.cache_write = 10;

    try std.testing.expectEqual(@as(u64, 100), partial.usage.input);
    try std.testing.expectEqual(@as(u64, 50), partial.usage.output);
    try std.testing.expectEqual(@as(u64, 20), partial.usage.cache_read);
    try std.testing.expectEqual(@as(u64, 10), partial.usage.cache_write);
}

test "TextPartial default values" {
    const text_partial = TextPartial{};
    try std.testing.expectEqual(@as(usize, 0), text_partial.accumulated_len);
}

test "ThinkingPartial default values" {
    const thinking_partial = ThinkingPartial{};
    try std.testing.expectEqual(@as(usize, 0), thinking_partial.accumulated_len);
}

test "ToolCallPartial default values" {
    const tc_partial = ToolCallPartial{};
    try std.testing.expect(tc_partial.getId() == null);
    try std.testing.expect(tc_partial.getName() == null);
    try std.testing.expectEqual(@as(usize, 0), tc_partial.json_len);
}
