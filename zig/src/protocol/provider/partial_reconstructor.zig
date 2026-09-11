const std = @import("std");
const ai_types = @import("ai_types");
const streaming_json = @import("streaming_json");
const content_partial = @import("content_partial");
const owned_slice_mod = @import("owned_slice");

const OwnedSlice = owned_slice_mod.OwnedSlice;

pub const PartialReconstructor = struct {
    allocator: std.mem.Allocator,

    content_blocks: std.AutoHashMap(usize, ReconstructedBlock),

    usage: ai_types.Usage,

    model: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    api: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    provider: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    started: bool = false,

    done_received: bool = false,

    stop_reason: ?ai_types.StopReason = null,

    pub const ReconstructedBlock = union(enum) {
        text: std.ArrayList(u8),
        thinking: std.ArrayList(u8),
        tool_call: struct {
            id: ?[]const u8 = null,
            name: ?[]const u8 = null,
            json_chunks: std.ArrayList(u8),
        },
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .content_blocks = std.AutoHashMap(usize, ReconstructedBlock).init(allocator),
            .usage = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.model.deinit(self.allocator);
        self.api.deinit(self.allocator);
        self.provider.deinit(self.allocator);

        var iter = self.content_blocks.iterator();
        while (iter.next()) |entry| {
            const block = entry.value_ptr;
            switch (block.*) {
                .text => |*list| list.deinit(self.allocator),
                .thinking => |*list| list.deinit(self.allocator),
                .tool_call => |*tc| {
                    if (tc.id) |id| self.allocator.free(id);
                    if (tc.name) |name| self.allocator.free(name);
                    tc.json_chunks.deinit(self.allocator);
                },
            }
        }
        self.content_blocks.deinit();

        self.* = undefined;
    }

    pub fn processEvent(self: *Self, event: ai_types.AssistantMessageEvent) !void {
        switch (event) {
            .start => |s| {
                self.started = true;
                self.model.deinit(self.allocator);
                self.model = if (s.partial.model.len > 0)
                    OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, s.partial.model))
                else
                    OwnedSlice(u8).initBorrowed("");

                self.api.deinit(self.allocator);
                self.api = if (s.partial.api.len > 0)
                    OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, s.partial.api))
                else
                    OwnedSlice(u8).initBorrowed("");

                self.provider.deinit(self.allocator);
                self.provider = if (s.partial.provider.len > 0)
                    OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, s.partial.provider))
                else
                    OwnedSlice(u8).initBorrowed("");
                self.usage.input += s.partial.usage.input;
                self.usage.output += s.partial.usage.output;
                self.usage.cache_read += s.partial.usage.cache_read;
                self.usage.cache_write += s.partial.usage.cache_write;
            },
            .text_start => |ts| {
                const list = std.ArrayList(u8).initCapacity(self.allocator, 64) catch return error.OutOfMemory;
                try self.content_blocks.put(ts.content_index, .{ .text = list });
            },
            .text_delta => |td| {
                if (self.content_blocks.getPtr(td.content_index)) |block| {
                    if (block.* == .text) {
                        try block.text.appendSlice(self.allocator, td.delta);
                    }
                }
                self.usage.input += td.partial.usage.input;
                self.usage.output += td.partial.usage.output;
                self.usage.cache_read += td.partial.usage.cache_read;
                self.usage.cache_write += td.partial.usage.cache_write;
            },
            .text_end => |te| {
                self.usage.input += te.partial.usage.input;
                self.usage.output += te.partial.usage.output;
                self.usage.cache_read += te.partial.usage.cache_read;
                self.usage.cache_write += te.partial.usage.cache_write;
            },
            .thinking_start => |ts| {
                const list = std.ArrayList(u8).initCapacity(self.allocator, 64) catch return error.OutOfMemory;
                try self.content_blocks.put(ts.content_index, .{ .thinking = list });
            },
            .thinking_delta => |td| {
                if (self.content_blocks.getPtr(td.content_index)) |block| {
                    if (block.* == .thinking) {
                        try block.thinking.appendSlice(self.allocator, td.delta);
                    }
                }
                self.usage.input += td.partial.usage.input;
                self.usage.output += td.partial.usage.output;
                self.usage.cache_read += td.partial.usage.cache_read;
                self.usage.cache_write += td.partial.usage.cache_write;
            },
            .thinking_end => |te| {
                self.usage.input += te.partial.usage.input;
                self.usage.output += te.partial.usage.output;
                self.usage.cache_read += te.partial.usage.cache_read;
                self.usage.cache_write += te.partial.usage.cache_write;
            },
            .toolcall_start => |tcs| {
                const json_list = std.ArrayList(u8).initCapacity(self.allocator, 64) catch return error.OutOfMemory;
                const id_duped = if (tcs.id.len > 0) try self.allocator.dupe(u8, tcs.id) else null;
                const name_duped = if (tcs.name.len > 0) try self.allocator.dupe(u8, tcs.name) else null;
                const tc_block = ReconstructedBlock{ .tool_call = .{
                    .id = id_duped,
                    .name = name_duped,
                    .json_chunks = json_list,
                } };
                try self.content_blocks.put(tcs.content_index, tc_block);
            },
            .toolcall_delta => |tcd| {
                if (self.content_blocks.getPtr(tcd.content_index)) |block| {
                    if (block.* == .tool_call) {
                        try block.tool_call.json_chunks.appendSlice(self.allocator, tcd.delta);
                    }
                }
                self.usage.input += tcd.partial.usage.input;
                self.usage.output += tcd.partial.usage.output;
                self.usage.cache_read += tcd.partial.usage.cache_read;
                self.usage.cache_write += tcd.partial.usage.cache_write;
            },
            .toolcall_end => |tce| {
                if (self.content_blocks.getPtr(tce.content_index)) |block| {
                    if (block.* == .tool_call) {
                        if (block.tool_call.id == null and tce.tool_call.id.len > 0) {
                            block.tool_call.id = try self.allocator.dupe(u8, tce.tool_call.id);
                        }
                        if (block.tool_call.name == null and tce.tool_call.name.len > 0) {
                            block.tool_call.name = try self.allocator.dupe(u8, tce.tool_call.name);
                        }
                        if (tce.tool_call.arguments_json.len > 0) {
                            block.tool_call.json_chunks.clearRetainingCapacity();
                            try block.tool_call.json_chunks.appendSlice(self.allocator, tce.tool_call.arguments_json);
                        }
                    }
                }
                self.usage.input += tce.partial.usage.input;
                self.usage.output += tce.partial.usage.output;
                self.usage.cache_read += tce.partial.usage.cache_read;
                self.usage.cache_write += tce.partial.usage.cache_write;
            },
            .done => |d| {
                self.done_received = true;
                self.stop_reason = d.reason;
                self.usage.input = d.message.usage.input;
                self.usage.output = d.message.usage.output;
                self.usage.cache_read = d.message.usage.cache_read;
                self.usage.cache_write = d.message.usage.cache_write;
            },
            .@"error" => |e| {
                self.done_received = true;
                self.stop_reason = e.reason;
            },
            .keepalive => {
            },
        }
    }

    pub fn getPartialState(self: *Self) !content_partial.MessagePartial {
        var partial = content_partial.MessagePartial.init(self.allocator);
        errdefer partial.deinit();

        if (self.model.slice().len > 0) {
            partial.model = self.model.slice();
        }
        if (self.api.slice().len > 0) {
            partial.api = self.api.slice();
        }
        if (self.provider.slice().len > 0) {
            partial.provider = self.provider.slice();
        }

        partial.usage = self.usage;

        var iter = self.content_blocks.iterator();
        while (iter.next()) |entry| {
            const content_index = entry.key_ptr.*;
            const block = entry.value_ptr.*;

            const block_partial: content_partial.ContentBlockPartial = switch (block) {
                .text => |list| .{ .text = .{ .accumulated_len = list.items.len } },
                .thinking => |list| .{ .thinking = .{ .accumulated_len = list.items.len } },
                .tool_call => |tc| blk: {
                    var tcp = content_partial.ToolCallPartial{
                        .json_len = tc.json_chunks.items.len,
                    };
                    if (tc.id) |id| {
                        tcp.id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, id));
                    }
                    if (tc.name) |name| {
                        tcp.name = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, name));
                    }
                    break :blk .{ .tool_call = tcp };
                },
            };
            try partial.updateBlockPartial(content_index, block_partial);
        }

        return partial;
    }

    pub fn buildMessage(self: *Self, stop_reason: ai_types.StopReason, timestamp: i64) !ai_types.AssistantMessage {
        const final_stop_reason = self.stop_reason orelse stop_reason;

        const block_count = self.content_blocks.count();

        var content = try self.allocator.alloc(ai_types.AssistantContent, block_count);
        errdefer self.allocator.free(content);

        var keys = try self.allocator.alloc(usize, block_count);
        defer self.allocator.free(keys);

        var iter = self.content_blocks.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| {
            keys[i] = entry.key_ptr.*;
            i += 1;
        }

        std.mem.sort(usize, keys, {}, comptime std.sort.asc(usize));

        for (keys, 0..) |content_index, idx| {
            const block = self.content_blocks.get(content_index).?;
            content[idx] = switch (block) {
                .text => |list| .{ .text = .{
                    .text = try self.allocator.dupe(u8, list.items),
                } },
                .thinking => |list| .{ .thinking = .{
                    .thinking = try self.allocator.dupe(u8, list.items),
                } },
                .tool_call => |tc| .{ .tool_call = .{
                    .id = if (tc.id) |id| try self.allocator.dupe(u8, id) else try self.allocator.dupe(u8, ""),
                    .name = if (tc.name) |name| try self.allocator.dupe(u8, name) else try self.allocator.dupe(u8, ""),
                    .arguments_json = try self.allocator.dupe(u8, tc.json_chunks.items),
                } },
            };
        }

        const duped_model = try self.allocator.dupe(u8, self.model.slice());
        errdefer self.allocator.free(duped_model);

        const duped_api = try self.allocator.dupe(u8, self.api.slice());
        errdefer self.allocator.free(duped_api);

        const duped_provider = try self.allocator.dupe(u8, self.provider.slice());
        errdefer self.allocator.free(duped_provider);

        return .{
            .content = content,
            .api = duped_api,
            .provider = duped_provider,
            .model = duped_model,
            .usage = self.usage,
            .stop_reason = final_stop_reason,
            .timestamp = timestamp,
            .is_owned = true,
        };
    }

    pub fn reset(self: *Self) void {
        self.model.deinit(self.allocator);
        self.model = OwnedSlice(u8).initBorrowed("");
        self.api.deinit(self.allocator);
        self.api = OwnedSlice(u8).initBorrowed("");
        self.provider.deinit(self.allocator);
        self.provider = OwnedSlice(u8).initBorrowed("");

        var iter = self.content_blocks.iterator();
        while (iter.next()) |entry| {
            var block = entry.value_ptr.*;
            switch (block) {
                .text => |*list| list.deinit(self.allocator),
                .thinking => |*list| list.deinit(self.allocator),
                .tool_call => |*tc| {
                    if (tc.id) |id| self.allocator.free(id);
                    if (tc.name) |name| self.allocator.free(name);
                    tc.json_chunks.deinit(self.allocator);
                },
            }
        }
        self.content_blocks.clearRetainingCapacity();

        self.usage = .{};
        self.started = false;
        self.done_received = false;
        self.stop_reason = null;
    }
};

test "PartialReconstructor init and deinit" {
    var recon = PartialReconstructor.init(std.testing.allocator);
    defer recon.deinit();

    try std.testing.expect(!recon.started);
    try std.testing.expect(!recon.done_received);
    try std.testing.expectEqual(@as(usize, 0), recon.model.slice().len);
    try std.testing.expectEqual(@as(usize, 0), recon.api.slice().len);
    try std.testing.expectEqual(@as(usize, 0), recon.provider.slice().len);
}

test "processEvent accumulates text deltas" {
    var recon = PartialReconstructor.init(std.testing.allocator);
    defer recon.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try recon.processEvent(.{ .start = .{ .partial = partial } });
    try std.testing.expect(recon.started);

    try recon.processEvent(.{ .text_start = .{ .content_index = 0, .partial = partial } });

    try recon.processEvent(.{ .text_delta = .{ .content_index = 0, .delta = "Hello", .partial = partial } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 0, .delta = " ", .partial = partial } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 0, .delta = "world", .partial = partial } });

    const block = recon.content_blocks.get(0).?;
    try std.testing.expect(block == .text);
    try std.testing.expectEqualStrings("Hello world", block.text.items);
}

test "processEvent accumulates thinking deltas" {
    var recon = PartialReconstructor.init(std.testing.allocator);
    defer recon.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try recon.processEvent(.{ .start = .{ .partial = partial } });

    try recon.processEvent(.{ .thinking_start = .{ .content_index = 0, .partial = partial } });

    try recon.processEvent(.{ .thinking_delta = .{ .content_index = 0, .delta = "Let me think...", .partial = partial } });
    try recon.processEvent(.{ .thinking_delta = .{ .content_index = 0, .delta = " about this.", .partial = partial } });

    const block = recon.content_blocks.get(0).?;
    try std.testing.expect(block == .thinking);
    try std.testing.expectEqualStrings("Let me think... about this.", block.thinking.items);
}

test "processEvent accumulates tool call deltas" {
    var recon = PartialReconstructor.init(std.testing.allocator);
    defer recon.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try recon.processEvent(.{ .start = .{ .partial = partial } });

    try recon.processEvent(.{ .toolcall_start = .{ .content_index = 0, .id = "tool-123", .name = "bash", .partial = partial } });

    try recon.processEvent(.{ .toolcall_delta = .{ .content_index = 0, .delta = "{\"com", .partial = partial } });
    try recon.processEvent(.{ .toolcall_delta = .{ .content_index = 0, .delta = "mand\": \"ls\"}", .partial = partial } });

    const tool_call = ai_types.ToolCall{
        .id = "tool-123",
        .name = "bash",
        .arguments_json = "{\"command\": \"ls\"}",
    };
    try recon.processEvent(.{ .toolcall_end = .{ .content_index = 0, .tool_call = tool_call, .partial = partial } });

    const block = recon.content_blocks.get(0).?;
    try std.testing.expect(block == .tool_call);
    try std.testing.expectEqualStrings("tool-123", block.tool_call.id.?);
    try std.testing.expectEqualStrings("bash", block.tool_call.name.?);
    try std.testing.expectEqualStrings("{\"command\": \"ls\"}", block.tool_call.json_chunks.items);
}

test "buildMessage creates valid AssistantMessage" {
    var recon = PartialReconstructor.init(std.testing.allocator);
    defer recon.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4o",
        .usage = .{ .input = 100, .output = 50 },
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try recon.processEvent(.{ .start = .{ .partial = partial } });

    try recon.processEvent(.{ .text_start = .{ .content_index = 0, .partial = partial } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 0, .delta = "Hello", .partial = partial } });

    const done_msg = ai_types.AssistantMessage{
        .content = &.{},
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4o",
        .usage = .{ .input = 100, .output = 50 },
        .stop_reason = .stop,
        .timestamp = 0,
    };
    try recon.processEvent(.{ .done = .{ .reason = .stop, .message = done_msg } });

    var msg = try recon.buildMessage(.stop, 12345);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), msg.content.len);
    try std.testing.expect(msg.content[0] == .text);
    try std.testing.expectEqualStrings("Hello", msg.content[0].text.text);
    try std.testing.expectEqualStrings("openai-completions", msg.api);
    try std.testing.expectEqualStrings("openai", msg.provider);
    try std.testing.expectEqualStrings("gpt-4o", msg.model);
    try std.testing.expectEqual(ai_types.StopReason.stop, msg.stop_reason);
    try std.testing.expectEqual(@as(i64, 12345), msg.timestamp);
    try std.testing.expect(msg.is_owned);
}

test "buildMessage includes all content blocks" {
    var recon = PartialReconstructor.init(std.testing.allocator);
    defer recon.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try recon.processEvent(.{ .start = .{ .partial = partial } });

    try recon.processEvent(.{ .thinking_start = .{ .content_index = 0, .partial = partial } });
    try recon.processEvent(.{ .thinking_delta = .{ .content_index = 0, .delta = "Thinking...", .partial = partial } });

    try recon.processEvent(.{ .text_start = .{ .content_index = 1, .partial = partial } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 1, .delta = "Response", .partial = partial } });

    try recon.processEvent(.{ .toolcall_start = .{ .content_index = 2, .id = "tc-1", .name = "bash", .partial = partial } });
    try recon.processEvent(.{ .toolcall_delta = .{ .content_index = 2, .delta = "{\"cmd\": \"ls\"}", .partial = partial } });
    const tool_call = ai_types.ToolCall{
        .id = "tc-1",
        .name = "bash",
        .arguments_json = "{\"cmd\": \"ls\"}",
    };
    try recon.processEvent(.{ .toolcall_end = .{ .content_index = 2, .tool_call = tool_call, .partial = partial } });

    try recon.processEvent(.{ .done = .{ .reason = .tool_use, .message = partial } });

    var msg = try recon.buildMessage(.tool_use, 0);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), msg.content.len);

    try std.testing.expect(msg.content[0] == .thinking);
    try std.testing.expectEqualStrings("Thinking...", msg.content[0].thinking.thinking);

    try std.testing.expect(msg.content[1] == .text);
    try std.testing.expectEqualStrings("Response", msg.content[1].text.text);

    try std.testing.expect(msg.content[2] == .tool_call);
    try std.testing.expectEqualStrings("tc-1", msg.content[2].tool_call.id);
    try std.testing.expectEqualStrings("bash", msg.content[2].tool_call.name);
    try std.testing.expectEqualStrings("{\"cmd\": \"ls\"}", msg.content[2].tool_call.arguments_json);
}

test "getPartialState returns current state" {
    var recon = PartialReconstructor.init(std.testing.allocator);
    defer recon.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try recon.processEvent(.{ .start = .{ .partial = partial } });
    try recon.processEvent(.{ .text_start = .{ .content_index = 0, .partial = partial } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 0, .delta = "Hello world", .partial = partial } });

    var state = try recon.getPartialState();
    defer state.deinit();

    try std.testing.expectEqualStrings("test-api", state.api);
    try std.testing.expectEqualStrings("test-provider", state.provider);
    try std.testing.expectEqualStrings("test-model", state.model);

    const block = state.getBlockPartial(0);
    try std.testing.expect(block != null);
    if (block) |b| {
        try std.testing.expect(b == .text);
        try std.testing.expectEqual(@as(usize, 11), b.text.accumulated_len);
    }
}

test "reset clears all state" {
    var recon = PartialReconstructor.init(std.testing.allocator);
    defer recon.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{ .input = 100, .output = 50 },
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try recon.processEvent(.{ .start = .{ .partial = partial } });
    try recon.processEvent(.{ .text_start = .{ .content_index = 0, .partial = partial } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 0, .delta = "Test", .partial = partial } });
    try recon.processEvent(.{ .done = .{ .reason = .stop, .message = partial } });

    try std.testing.expect(recon.started);
    try std.testing.expect(recon.done_received);
    try std.testing.expect(recon.model.slice().len > 0);
    try std.testing.expectEqual(@as(usize, 1), recon.content_blocks.count());

    recon.reset();

    try std.testing.expect(!recon.started);
    try std.testing.expect(!recon.done_received);
    try std.testing.expectEqual(@as(usize, 0), recon.model.slice().len);
    try std.testing.expectEqual(@as(usize, 0), recon.api.slice().len);
    try std.testing.expectEqual(@as(usize, 0), recon.provider.slice().len);
    try std.testing.expectEqual(@as(usize, 0), recon.content_blocks.count());
    try std.testing.expectEqual(@as(u64, 0), recon.usage.input);
    try std.testing.expectEqual(@as(u64, 0), recon.usage.output);
}

test "processEvent handles multiple content blocks with different indices" {
    var recon = PartialReconstructor.init(std.testing.allocator);
    defer recon.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try recon.processEvent(.{ .start = .{ .partial = partial } });

    try recon.processEvent(.{ .text_start = .{ .content_index = 5, .partial = partial } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 5, .delta = "Fifth", .partial = partial } });

    try recon.processEvent(.{ .text_start = .{ .content_index = 2, .partial = partial } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 2, .delta = "Second", .partial = partial } });

    try std.testing.expectEqual(@as(usize, 2), recon.content_blocks.count());

    const block5 = recon.content_blocks.get(5).?;
    try std.testing.expectEqualStrings("Fifth", block5.text.items);

    const block2 = recon.content_blocks.get(2).?;
    try std.testing.expectEqualStrings("Second", block2.text.items);

    try recon.processEvent(.{ .done = .{ .reason = .stop, .message = partial } });

    var msg = try recon.buildMessage(.stop, 0);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), msg.content.len);
    try std.testing.expectEqualStrings("Second", msg.content[0].text.text);
    try std.testing.expectEqualStrings("Fifth", msg.content[1].text.text);
}

test "processEvent handles usage accumulation" {
    var recon = PartialReconstructor.init(std.testing.allocator);
    defer recon.deinit();

    const partial1 = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{ .input = 100, .output = 10 },
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const partial2 = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{ .input = 0, .output = 20 },
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try recon.processEvent(.{ .start = .{ .partial = partial1 } });
    try std.testing.expectEqual(@as(u64, 100), recon.usage.input);
    try std.testing.expectEqual(@as(u64, 10), recon.usage.output);

    try recon.processEvent(.{ .text_start = .{ .content_index = 0, .partial = partial1 } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 0, .delta = "Test", .partial = partial2 } });

    try std.testing.expectEqual(@as(u64, 100), recon.usage.input);
    try std.testing.expectEqual(@as(u64, 30), recon.usage.output);
}

test "buildMessage with tool_use stop reason" {
    var recon = PartialReconstructor.init(std.testing.allocator);
    defer recon.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try recon.processEvent(.{ .start = .{ .partial = partial } });
    try recon.processEvent(.{ .toolcall_start = .{ .content_index = 0, .id = "tc-1", .name = "read_file", .partial = partial } });

    const tool_call = ai_types.ToolCall{
        .id = "tc-1",
        .name = "read_file",
        .arguments_json = "{\"path\": \"/etc/hosts\"}",
    };
    try recon.processEvent(.{ .toolcall_end = .{ .content_index = 0, .tool_call = tool_call, .partial = partial } });
    try recon.processEvent(.{ .done = .{ .reason = .tool_use, .message = partial } });

    var msg = try recon.buildMessage(.tool_use, 0);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expectEqual(ai_types.StopReason.tool_use, msg.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), msg.content.len);
    try std.testing.expect(msg.content[0] == .tool_call);
}

test "processEvent ignores deltas without corresponding start blocks" {
    var recon = PartialReconstructor.init(std.testing.allocator);
    defer recon.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{ .input = 1, .output = 2 },
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try recon.processEvent(.{ .text_delta = .{
        .content_index = 9,
        .delta = "orphan",
        .partial = partial,
    } });
    try recon.processEvent(.{ .toolcall_delta = .{
        .content_index = 10,
        .delta = "{\"k\":1}",
        .partial = partial,
    } });

    try std.testing.expectEqual(@as(usize, 0), recon.content_blocks.count());
    try std.testing.expectEqual(@as(u64, 2), recon.usage.input);
    try std.testing.expectEqual(@as(u64, 4), recon.usage.output);
}

test "PartialReconstructor reuse after reset" {
    var recon = PartialReconstructor.init(std.testing.allocator);
    defer recon.deinit();

    const partial1 = ai_types.AssistantMessage{
        .content = &.{},
        .api = "api1",
        .provider = "provider1",
        .model = "model1",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try recon.processEvent(.{ .start = .{ .partial = partial1 } });
    try recon.processEvent(.{ .text_start = .{ .content_index = 0, .partial = partial1 } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 0, .delta = "First", .partial = partial1 } });
    try recon.processEvent(.{ .done = .{ .reason = .stop, .message = partial1 } });

    var msg1 = try recon.buildMessage(.stop, 1000);
    defer msg1.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("First", msg1.content[0].text.text);

    recon.reset();

    const partial2 = ai_types.AssistantMessage{
        .content = &.{},
        .api = "api2",
        .provider = "provider2",
        .model = "model2",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try recon.processEvent(.{ .start = .{ .partial = partial2 } });
    try recon.processEvent(.{ .text_start = .{ .content_index = 0, .partial = partial2 } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 0, .delta = "Second", .partial = partial2 } });
    try recon.processEvent(.{ .done = .{ .reason = .stop, .message = partial2 } });

    var msg2 = try recon.buildMessage(.stop, 2000);
    defer msg2.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Second", msg2.content[0].text.text);
    try std.testing.expectEqualStrings("api2", msg2.api);
    try std.testing.expectEqualStrings("provider2", msg2.provider);
    try std.testing.expectEqualStrings("model2", msg2.model);
}
