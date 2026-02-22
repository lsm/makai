const std = @import("std");
const ai_types = @import("ai_types");
const streaming_json = @import("streaming_json");
const content_partial = @import("content_partial");
const owned_slice_mod = @import("owned_slice");

const OwnedSlice = owned_slice_mod.OwnedSlice;

/// Client-side reconstructor for building AssistantMessage from events
pub const PartialReconstructor = struct {
    allocator: std.mem.Allocator,

    /// Accumulated content blocks indexed by content_index
    content_blocks: std.AutoHashMap(usize, ReconstructedBlock),

    /// Running usage
    usage: ai_types.Usage,

    /// Metadata from start event (owned or borrowed)
    model: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    api: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    provider: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    /// Track if we've seen start
    started: bool = false,

    /// Track if done event was received
    done_received: bool = false,

    /// Stop reason from done event
    stop_reason: ?ai_types.StopReason = null,

    pub const ReconstructedBlock = union(enum) {
        text: std.ArrayList(u8),
        thinking: std.ArrayList(u8),
        tool_call: struct {
            id: ?[]const u8 = null,
            name: ?[]const u8 = null,
            json_chunks: std.ArrayList(u8), // Accumulated JSON deltas
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
        // Free metadata strings
        self.model.deinit(self.allocator);
        self.api.deinit(self.allocator);
        self.provider.deinit(self.allocator);

        // Free content blocks
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

        // Poison freed memory to catch use-after-free in debug builds
        self.* = undefined;
    }

    /// Process an event, updating internal state
    /// Call this for each event received from the stream
    pub fn processEvent(self: *Self, event: ai_types.AssistantMessageEvent) !void {
        switch (event) {
            .start => |s| {
                self.started = true;
                // Dupe metadata strings into owned wrappers
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
                // Accumulate initial usage
                self.usage.input += s.partial.usage.input;
                self.usage.output += s.partial.usage.output;
                self.usage.cache_read += s.partial.usage.cache_read;
                self.usage.cache_write += s.partial.usage.cache_write;
            },
            .text_start => |ts| {
                // Create text ArrayList for this content_index
                const list = std.ArrayList(u8).initCapacity(self.allocator, 64) catch return error.OutOfMemory;
                try self.content_blocks.put(ts.content_index, .{ .text = list });
            },
            .text_delta => |td| {
                // Append delta to text ArrayList
                if (self.content_blocks.getPtr(td.content_index)) |block| {
                    if (block.* == .text) {
                        try block.text.appendSlice(self.allocator, td.delta);
                    }
                }
                // Accumulate usage
                self.usage.input += td.partial.usage.input;
                self.usage.output += td.partial.usage.output;
                self.usage.cache_read += td.partial.usage.cache_read;
                self.usage.cache_write += td.partial.usage.cache_write;
            },
            .text_end => |te| {
                // Text is complete, usage may be updated
                self.usage.input += te.partial.usage.input;
                self.usage.output += te.partial.usage.output;
                self.usage.cache_read += te.partial.usage.cache_read;
                self.usage.cache_write += te.partial.usage.cache_write;
            },
            .thinking_start => |ts| {
                // Create thinking ArrayList for this content_index
                const list = std.ArrayList(u8).initCapacity(self.allocator, 64) catch return error.OutOfMemory;
                try self.content_blocks.put(ts.content_index, .{ .thinking = list });
            },
            .thinking_delta => |td| {
                // Append delta to thinking ArrayList
                if (self.content_blocks.getPtr(td.content_index)) |block| {
                    if (block.* == .thinking) {
                        try block.thinking.appendSlice(self.allocator, td.delta);
                    }
                }
                // Accumulate usage
                self.usage.input += td.partial.usage.input;
                self.usage.output += td.partial.usage.output;
                self.usage.cache_read += td.partial.usage.cache_read;
                self.usage.cache_write += td.partial.usage.cache_write;
            },
            .thinking_end => |te| {
                // Thinking is complete, usage may be updated
                self.usage.input += te.partial.usage.input;
                self.usage.output += te.partial.usage.output;
                self.usage.cache_read += te.partial.usage.cache_read;
                self.usage.cache_write += te.partial.usage.cache_write;
            },
            .toolcall_start => |tcs| {
                // Create tool_call block with id/name from the event
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
                // Append JSON delta
                if (self.content_blocks.getPtr(tcd.content_index)) |block| {
                    if (block.* == .tool_call) {
                        try block.tool_call.json_chunks.appendSlice(self.allocator, tcd.delta);
                    }
                }
                // Accumulate usage
                self.usage.input += tcd.partial.usage.input;
                self.usage.output += tcd.partial.usage.output;
                self.usage.cache_read += tcd.partial.usage.cache_read;
                self.usage.cache_write += tcd.partial.usage.cache_write;
            },
            .toolcall_end => |tce| {
                // Finalize tool call with id/name from the event (only if not already set)
                if (self.content_blocks.getPtr(tce.content_index)) |block| {
                    if (block.* == .tool_call) {
                        // Only dupe id and name if they weren't set in toolcall_start
                        if (block.tool_call.id == null and tce.tool_call.id.len > 0) {
                            block.tool_call.id = try self.allocator.dupe(u8, tce.tool_call.id);
                        }
                        if (block.tool_call.name == null and tce.tool_call.name.len > 0) {
                            block.tool_call.name = try self.allocator.dupe(u8, tce.tool_call.name);
                        }
                        // Also append any final JSON from arguments_json if present
                        if (tce.tool_call.arguments_json.len > 0) {
                            // Replace accumulated JSON with the final version
                            block.tool_call.json_chunks.clearRetainingCapacity();
                            try block.tool_call.json_chunks.appendSlice(self.allocator, tce.tool_call.arguments_json);
                        }
                    }
                }
                // Accumulate usage
                self.usage.input += tce.partial.usage.input;
                self.usage.output += tce.partial.usage.output;
                self.usage.cache_read += tce.partial.usage.cache_read;
                self.usage.cache_write += tce.partial.usage.cache_write;
            },
            .done => |d| {
                self.done_received = true;
                self.stop_reason = d.reason;
                // Final usage from done event
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
                // No state change for keepalive
            },
        }
    }

    /// Get current partial state (for progress tracking)
    /// Note: The returned MessagePartial uses borrowed references for metadata strings
    /// (model, api, provider) - do not free them separately.
    pub fn getPartialState(self: *Self) !content_partial.MessagePartial {
        var partial = content_partial.MessagePartial.init(self.allocator);
        errdefer partial.deinit();

        // Set metadata (borrowed references - do not dupe)
        if (self.model.slice().len > 0) {
            partial.model = self.model.slice();
        }
        if (self.api.slice().len > 0) {
            partial.api = self.api.slice();
        }
        if (self.provider.slice().len > 0) {
            partial.provider = self.provider.slice();
        }

        // Copy usage
        partial.usage = self.usage;

        // Add block partials
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

    /// Build final AssistantMessage from accumulated state
    /// Must be called after done event
    pub fn buildMessage(self: *Self, stop_reason: ai_types.StopReason, timestamp: i64) !ai_types.AssistantMessage {
        // Use provided stop_reason, or the one from done event if available
        const final_stop_reason = self.stop_reason orelse stop_reason;

        // Count content blocks and find max index for sorting
        const block_count = self.content_blocks.count();

        // Allocate content array
        var content = try self.allocator.alloc(ai_types.AssistantContent, block_count);
        errdefer self.allocator.free(content);

        // We need to get keys sorted to maintain order
        var keys = try self.allocator.alloc(usize, block_count);
        defer self.allocator.free(keys);

        var iter = self.content_blocks.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| {
            keys[i] = entry.key_ptr.*;
            i += 1;
        }

        // Sort keys by content_index
        std.mem.sort(usize, keys, {}, comptime std.sort.asc(usize));

        // Build content array in order
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

        // Dupe metadata strings for the message
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

    /// Reset for reuse with new stream
    pub fn reset(self: *Self) void {
        // Free metadata strings
        self.model.deinit(self.allocator);
        self.model = OwnedSlice(u8).initBorrowed("");
        self.api.deinit(self.allocator);
        self.api = OwnedSlice(u8).initBorrowed("");
        self.provider.deinit(self.allocator);
        self.provider = OwnedSlice(u8).initBorrowed("");

        // Free content blocks
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

        // Reset state
        self.usage = .{};
        self.started = false;
        self.done_received = false;
        self.stop_reason = null;
    }
};

// =============================================================================
// Tests
// =============================================================================

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

    // Create start event
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

    // Text start
    try recon.processEvent(.{ .text_start = .{ .content_index = 0, .partial = partial } });

    // Text deltas
    try recon.processEvent(.{ .text_delta = .{ .content_index = 0, .delta = "Hello", .partial = partial } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 0, .delta = " ", .partial = partial } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 0, .delta = "world", .partial = partial } });

    // Check accumulated text
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

    // Thinking start
    try recon.processEvent(.{ .thinking_start = .{ .content_index = 0, .partial = partial } });

    // Thinking deltas
    try recon.processEvent(.{ .thinking_delta = .{ .content_index = 0, .delta = "Let me think...", .partial = partial } });
    try recon.processEvent(.{ .thinking_delta = .{ .content_index = 0, .delta = " about this.", .partial = partial } });

    // Check accumulated thinking
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

    // Tool call start
    try recon.processEvent(.{ .toolcall_start = .{ .content_index = 0, .id = "tool-123", .name = "bash", .partial = partial } });

    // Tool call deltas (JSON fragments)
    try recon.processEvent(.{ .toolcall_delta = .{ .content_index = 0, .delta = "{\"com", .partial = partial } });
    try recon.processEvent(.{ .toolcall_delta = .{ .content_index = 0, .delta = "mand\": \"ls\"}", .partial = partial } });

    // Tool call end
    const tool_call = ai_types.ToolCall{
        .id = "tool-123",
        .name = "bash",
        .arguments_json = "{\"command\": \"ls\"}",
    };
    try recon.processEvent(.{ .toolcall_end = .{ .content_index = 0, .tool_call = tool_call, .partial = partial } });

    // Check accumulated tool call
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

    // Start event
    try recon.processEvent(.{ .start = .{ .partial = partial } });

    // Text content
    try recon.processEvent(.{ .text_start = .{ .content_index = 0, .partial = partial } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 0, .delta = "Hello", .partial = partial } });

    // Done event
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

    // Build message
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

    // Thinking block (index 0)
    try recon.processEvent(.{ .thinking_start = .{ .content_index = 0, .partial = partial } });
    try recon.processEvent(.{ .thinking_delta = .{ .content_index = 0, .delta = "Thinking...", .partial = partial } });

    // Text block (index 1)
    try recon.processEvent(.{ .text_start = .{ .content_index = 1, .partial = partial } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 1, .delta = "Response", .partial = partial } });

    // Tool call block (index 2)
    try recon.processEvent(.{ .toolcall_start = .{ .content_index = 2, .id = "tc-1", .name = "bash", .partial = partial } });
    try recon.processEvent(.{ .toolcall_delta = .{ .content_index = 2, .delta = "{\"cmd\": \"ls\"}", .partial = partial } });
    const tool_call = ai_types.ToolCall{
        .id = "tc-1",
        .name = "bash",
        .arguments_json = "{\"cmd\": \"ls\"}",
    };
    try recon.processEvent(.{ .toolcall_end = .{ .content_index = 2, .tool_call = tool_call, .partial = partial } });

    // Done
    try recon.processEvent(.{ .done = .{ .reason = .tool_use, .message = partial } });

    var msg = try recon.buildMessage(.tool_use, 0);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), msg.content.len);

    // Check order is preserved
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

    // Build up some state
    try recon.processEvent(.{ .start = .{ .partial = partial } });
    try recon.processEvent(.{ .text_start = .{ .content_index = 0, .partial = partial } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 0, .delta = "Test", .partial = partial } });
    try recon.processEvent(.{ .done = .{ .reason = .stop, .message = partial } });

    // Verify state exists
    try std.testing.expect(recon.started);
    try std.testing.expect(recon.done_received);
    try std.testing.expect(recon.model.slice().len > 0);
    try std.testing.expectEqual(@as(usize, 1), recon.content_blocks.count());

    // Reset
    recon.reset();

    // Verify state is cleared
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

    // Create blocks out of order (index 5, then index 2)
    try recon.processEvent(.{ .text_start = .{ .content_index = 5, .partial = partial } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 5, .delta = "Fifth", .partial = partial } });

    try recon.processEvent(.{ .text_start = .{ .content_index = 2, .partial = partial } });
    try recon.processEvent(.{ .text_delta = .{ .content_index = 2, .delta = "Second", .partial = partial } });

    // Verify both blocks exist
    try std.testing.expectEqual(@as(usize, 2), recon.content_blocks.count());

    const block5 = recon.content_blocks.get(5).?;
    try std.testing.expectEqualStrings("Fifth", block5.text.items);

    const block2 = recon.content_blocks.get(2).?;
    try std.testing.expectEqualStrings("Second", block2.text.items);

    // Build message and verify order
    try recon.processEvent(.{ .done = .{ .reason = .stop, .message = partial } });

    var msg = try recon.buildMessage(.stop, 0);
    defer msg.deinit(std.testing.allocator);

    // Should be in index order (2, then 5)
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

    // Usage should accumulate: start (10) + text_delta (20) = 30
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

    // First stream
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

    // Reset and reuse
    recon.reset();

    // Second stream with different content
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
