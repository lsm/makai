const std = @import("std");
const ai_types = @import("ai_types");
const OwnedSlice = @import("owned_slice").OwnedSlice;

/// Partial state for a text content block
pub const TextPartial = struct {
    /// Length of accumulated text
    accumulated_len: usize = 0,
};

/// Partial state for a thinking content block
pub const ThinkingPartial = struct {
    /// Length of accumulated thinking
    accumulated_len: usize = 0,
};

/// Partial state for a tool call content block
pub const ToolCallPartial = struct {
    /// Tool call ID (from toolcall_start)
    id: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    /// Tool name (from toolcall_start)
    name: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    /// Length of accumulated JSON arguments
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

/// Partial state for a content block
pub const ContentBlockPartial = union(enum) {
    text: TextPartial,
    thinking: ThinkingPartial,
    tool_call: ToolCallPartial,
    /// Block exists but not actively tracked
    inactive: void,

    pub fn deinit(self: *ContentBlockPartial, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tool_call => |*tc| tc.deinit(allocator),
            .text, .thinking, .inactive => {},
        }
    }
};

/// Full partial state for a streaming message
pub const MessagePartial = struct {
    allocator: std.mem.Allocator,

    /// Block partials indexed by content_index
    blocks: std.AutoHashMap(usize, ContentBlockPartial),

    /// Running usage totals
    usage: ai_types.Usage,

    /// Metadata (constant during stream)
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

    /// Get partial for a specific block
    pub fn getBlockPartial(self: *MessagePartial, content_index: usize) ?ContentBlockPartial {
        return self.blocks.get(content_index);
    }

    /// Update partial for a specific block
    pub fn updateBlockPartial(self: *MessagePartial, content_index: usize, partial: ContentBlockPartial) !void {
        // If there's an existing entry, deinit it first to free owned strings
        if (self.blocks.fetchRemove(content_index)) |old| {
            var old_partial = old.value;
            old_partial.deinit(self.allocator);
        }
        try self.blocks.put(content_index, partial);
    }

    /// Ensure a block exists (creates inactive if not)
    pub fn ensureBlock(self: *MessagePartial, content_index: usize) !void {
        if (!self.blocks.contains(content_index)) {
            try self.blocks.put(content_index, .{ .inactive = {} });
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

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
    // No leak - General Purpose Allocator will catch if we fail to free
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

    // Missing block should be null
    try std.testing.expect(partial.getBlockPartial(1) == null);
}

test "ensureBlock creates inactive block if missing" {
    var partial = MessagePartial.init(std.testing.allocator);
    defer partial.deinit();

    // Block doesn't exist initially
    try std.testing.expect(partial.getBlockPartial(0) == null);

    // ensureBlock should create an inactive entry
    try partial.ensureBlock(0);

    const block = partial.getBlockPartial(0);
    try std.testing.expect(block != null);
    if (block) |b| {
        try std.testing.expectEqual(@as(@TypeOf(b), .{ .inactive = {} }), b);
    }

    // Calling ensureBlock again should not change an existing block
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

    // Insert a tool_call with allocated strings
    const id1 = try std.testing.allocator.dupe(u8, "tool-old");
    const name1 = try std.testing.allocator.dupe(u8, "old-tool");

    try partial.updateBlockPartial(0, .{
        .tool_call = .{
            .id = OwnedSlice(u8).initOwned(id1),
            .name = OwnedSlice(u8).initOwned(name1),
            .json_len = 5,
        },
    });

    // Replace with a new tool_call - old strings should be freed
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

    // Simulate usage updates
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
