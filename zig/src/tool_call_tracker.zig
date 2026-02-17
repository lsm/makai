const std = @import("std");
const streaming_json = @import("streaming_json");
const ai_types = @import("ai_types");

/// Tracks tool calls being accumulated during streaming
pub const ToolCallTracker = struct {
    allocator: std.mem.Allocator,
    /// Map from API index (from provider events) to InProgressToolCall
    calls: std.AutoHashMap(usize, InProgressToolCall),

    pub const InProgressToolCall = struct {
        /// Content index in the final message's content array
        content_index: usize,
        /// API-provided index for tracking (varies by provider)
        api_index: usize,
        /// Tool call ID (e.g., "toolu_01..." for Anthropic, "call_..." for OpenAI)
        id: []const u8,
        /// Tool name
        name: []const u8,
        /// Accumulated JSON arguments
        json_accumulator: streaming_json.StreamingJsonAccumulator,
        /// Encrypted reasoning detail for round-trip (OpenAI reasoning_details)
        thought_signature: ?[]const u8 = null,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .calls = std.AutoHashMap(usize, InProgressToolCall).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.calls.iterator();
        while (iter.next()) |entry| {
            var call = entry.value_ptr;
            self.allocator.free(call.id);
            self.allocator.free(call.name);
            if (call.thought_signature) |sig| self.allocator.free(sig);
            call.json_accumulator.deinit();
        }
        self.calls.deinit();
    }

    /// Start tracking a new tool call. Returns the content index.
    /// id and name are copied into the tracker.
    pub fn startCall(self: *Self, api_index: usize, content_index: usize, id: []const u8, name: []const u8) !usize {
        const duped_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(duped_id);

        const duped_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(duped_name);

        const call = InProgressToolCall{
            .content_index = content_index,
            .api_index = api_index,
            .id = duped_id,
            .name = duped_name,
            .json_accumulator = streaming_json.StreamingJsonAccumulator.init(self.allocator),
        };

        try self.calls.put(api_index, call);
        return content_index;
    }

    /// Append a JSON delta to an existing tool call
    pub fn appendDelta(self: *Self, api_index: usize, delta: []const u8) !void {
        if (self.calls.getPtr(api_index)) |call| {
            try call.json_accumulator.append(delta);
        }
    }

    /// Get the current accumulated JSON for a tool call
    pub fn getJsonBuffer(self: Self, api_index: usize) ?[]const u8 {
        if (self.calls.get(api_index)) |call| {
            return call.json_accumulator.getBuffer();
        }
        return null;
    }

    /// Get the content index for a tool call by API index
    pub fn getContentIndex(self: Self, api_index: usize) ?usize {
        if (self.calls.get(api_index)) |call| {
            return call.content_index;
        }
        return null;
    }

    /// Set thought_signature on a tool call by its ID.
    /// Used for OpenAI reasoning_details round-trip.
    pub fn setThoughtSignatureById(self: *Self, tool_call_id: []const u8, signature: []const u8) !void {
        var iter = self.calls.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.id, tool_call_id)) {
                // Free any existing signature
                if (entry.value_ptr.thought_signature) |existing| {
                    self.allocator.free(existing);
                }
                entry.value_ptr.thought_signature = try self.allocator.dupe(u8, signature);
                return;
            }
        }
    }

    /// Complete a tool call and return it. Returns null if not found.
    /// The returned ToolCall owns its strings (id, name, arguments_json, thought_signature are duped).
    pub fn completeCall(self: *Self, api_index: usize, allocator: std.mem.Allocator) ?ai_types.ToolCall {
        if (self.calls.fetchRemove(api_index)) |removed| {
            var call = removed.value;

            // Dupe the strings for the returned ToolCall
            const duped_id = allocator.dupe(u8, call.id) catch {
                // On allocation failure, clean up and return null
                self.allocator.free(call.id);
                self.allocator.free(call.name);
                if (call.thought_signature) |sig| self.allocator.free(sig);
                call.json_accumulator.deinit();
                return null;
            };
            errdefer allocator.free(duped_id);

            const duped_name = allocator.dupe(u8, call.name) catch {
                allocator.free(duped_id);
                self.allocator.free(call.id);
                self.allocator.free(call.name);
                if (call.thought_signature) |sig| self.allocator.free(sig);
                call.json_accumulator.deinit();
                return null;
            };
            errdefer allocator.free(duped_name);

            const json_buf = call.json_accumulator.getBuffer();
            const duped_json = if (json_buf.len > 0)
                allocator.dupe(u8, json_buf) catch {
                    allocator.free(duped_id);
                    allocator.free(duped_name);
                    self.allocator.free(call.id);
                    self.allocator.free(call.name);
                    if (call.thought_signature) |sig| self.allocator.free(sig);
                    call.json_accumulator.deinit();
                    return null;
                }
            else
                "";

            // Dupe thought_signature if present
            const duped_sig = if (call.thought_signature) |sig|
                allocator.dupe(u8, sig) catch {
                    allocator.free(duped_id);
                    allocator.free(duped_name);
                    if (json_buf.len > 0) allocator.free(duped_json);
                    self.allocator.free(call.id);
                    self.allocator.free(call.name);
                    self.allocator.free(sig);
                    call.json_accumulator.deinit();
                    return null;
                }
            else
                null;

            // Free the tracker's copy of the strings
            self.allocator.free(call.id);
            self.allocator.free(call.name);
            if (call.thought_signature) |sig| self.allocator.free(sig);
            call.json_accumulator.deinit();

            return ai_types.ToolCall{
                .id = duped_id,
                .name = duped_name,
                .arguments_json = duped_json,
                .thought_signature = duped_sig,
            };
        }
        return null;
    }

    /// Check if we have a tool call at the given API index
    pub fn hasCall(self: Self, api_index: usize) bool {
        return self.calls.contains(api_index);
    }

    /// Get number of active tool calls
    pub fn count(self: Self) usize {
        return self.calls.count();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ToolCallTracker - start and complete a tool call" {
    const allocator = std.testing.allocator;

    var tracker = ToolCallTracker.init(allocator);
    defer tracker.deinit();

    const content_idx = try tracker.startCall(0, 5, "toolu_01ABC", "bash");
    try std.testing.expectEqual(@as(usize, 5), content_idx);
    try std.testing.expect(tracker.hasCall(0));
    try std.testing.expectEqual(@as(usize, 1), tracker.count());

    const tool_call = tracker.completeCall(0, allocator).?;
    defer {
        allocator.free(tool_call.id);
        allocator.free(tool_call.name);
        allocator.free(tool_call.arguments_json);
    }

    try std.testing.expectEqualStrings("toolu_01ABC", tool_call.id);
    try std.testing.expectEqualStrings("bash", tool_call.name);
    try std.testing.expectEqualStrings("", tool_call.arguments_json);
    try std.testing.expect(!tracker.hasCall(0));
    try std.testing.expectEqual(@as(usize, 0), tracker.count());
}

test "ToolCallTracker - append multiple deltas and get final result" {
    const allocator = std.testing.allocator;

    var tracker = ToolCallTracker.init(allocator);
    defer tracker.deinit();

    _ = try tracker.startCall(0, 0, "call_123", "read_file");

    try tracker.appendDelta(0, "{\"pa");
    try std.testing.expectEqualStrings("{\"pa", tracker.getJsonBuffer(0).?);

    try tracker.appendDelta(0, "th\": \"/et");
    try std.testing.expectEqualStrings("{\"path\": \"/et", tracker.getJsonBuffer(0).?);

    try tracker.appendDelta(0, "c/hosts\"}");

    const tool_call = tracker.completeCall(0, allocator).?;
    defer {
        allocator.free(tool_call.id);
        allocator.free(tool_call.name);
        allocator.free(tool_call.arguments_json);
    }

    try std.testing.expectEqualStrings("call_123", tool_call.id);
    try std.testing.expectEqualStrings("read_file", tool_call.name);
    try std.testing.expectEqualStrings("{\"path\": \"/etc/hosts\"}", tool_call.arguments_json);
}

test "ToolCallTracker - multiple concurrent tool calls" {
    const allocator = std.testing.allocator;

    var tracker = ToolCallTracker.init(allocator);
    defer tracker.deinit();

    // Start two tool calls with different API indices
    _ = try tracker.startCall(0, 0, "tool_0", "bash");
    _ = try tracker.startCall(1, 1, "tool_1", "read");

    try std.testing.expectEqual(@as(usize, 2), tracker.count());
    try std.testing.expect(tracker.hasCall(0));
    try std.testing.expect(tracker.hasCall(1));

    // Append deltas to each independently
    try tracker.appendDelta(0, "{\"cmd\":");
    try tracker.appendDelta(1, "{\"file\":");

    try tracker.appendDelta(0, " \"ls\"}");
    try tracker.appendDelta(1, " \"/tmp\"}");

    // Complete first call
    const tc0 = tracker.completeCall(0, allocator).?;
    defer {
        allocator.free(tc0.id);
        allocator.free(tc0.name);
        allocator.free(tc0.arguments_json);
    }
    try std.testing.expectEqualStrings("tool_0", tc0.id);
    try std.testing.expectEqualStrings("bash", tc0.name);
    try std.testing.expectEqualStrings("{\"cmd\": \"ls\"}", tc0.arguments_json);

    try std.testing.expectEqual(@as(usize, 1), tracker.count());
    try std.testing.expect(!tracker.hasCall(0));
    try std.testing.expect(tracker.hasCall(1));

    // Complete second call
    const tc1 = tracker.completeCall(1, allocator).?;
    defer {
        allocator.free(tc1.id);
        allocator.free(tc1.name);
        allocator.free(tc1.arguments_json);
    }
    try std.testing.expectEqualStrings("tool_1", tc1.id);
    try std.testing.expectEqualStrings("read", tc1.name);
    try std.testing.expectEqualStrings("{\"file\": \"/tmp\"}", tc1.arguments_json);

    try std.testing.expectEqual(@as(usize, 0), tracker.count());
}

test "ToolCallTracker - complete non-existent call returns null" {
    const allocator = std.testing.allocator;

    var tracker = ToolCallTracker.init(allocator);
    defer tracker.deinit();

    _ = try tracker.startCall(0, 0, "tool_0", "bash");

    const result = tracker.completeCall(99, allocator);
    try std.testing.expect(result == null);

    // Original call should still be present
    try std.testing.expect(tracker.hasCall(0));
}

test "ToolCallTracker - memory cleanup in deinit for incomplete calls" {
    const allocator = std.testing.allocator;

    var tracker = ToolCallTracker.init(allocator);

    // Start multiple calls but don't complete them
    _ = try tracker.startCall(0, 0, "tool_0", "bash");
    try tracker.appendDelta(0, "{\"cmd\": \"ls\"}");

    _ = try tracker.startCall(1, 1, "tool_1", "read");
    try tracker.appendDelta(1, "{\"path\": \"/etc\"}");

    _ = try tracker.startCall(2, 2, "tool_2", "write");

    // deinit should clean up all allocated memory without leaks
    tracker.deinit();
}

test "ToolCallTracker - getContentIndex returns correct index" {
    const allocator = std.testing.allocator;

    var tracker = ToolCallTracker.init(allocator);
    defer tracker.deinit();

    _ = try tracker.startCall(0, 5, "tool_0", "bash");
    _ = try tracker.startCall(1, 10, "tool_1", "read");

    try std.testing.expectEqual(@as(usize, 5), tracker.getContentIndex(0).?);
    try std.testing.expectEqual(@as(usize, 10), tracker.getContentIndex(1).?);
    try std.testing.expect(tracker.getContentIndex(99) == null);
}

test "ToolCallTracker - getJsonBuffer returns null for non-existent call" {
    const allocator = std.testing.allocator;

    var tracker = ToolCallTracker.init(allocator);
    defer tracker.deinit();

    try std.testing.expect(tracker.getJsonBuffer(0) == null);
}

test "ToolCallTracker - setThoughtSignatureById sets signature on matching tool call" {
    const allocator = std.testing.allocator;

    var tracker = ToolCallTracker.init(allocator);
    defer tracker.deinit();

    _ = try tracker.startCall(0, 0, "call_abc123", "bash");

    // Set thought_signature by tool call ID
    try tracker.setThoughtSignatureById("call_abc123", "{\"type\":\"reasoning.encrypted\",\"id\":\"call_abc123\",\"data\":\"test\"}");

    // Complete and verify thought_signature is preserved
    const tc = tracker.completeCall(0, allocator).?;
    defer {
        allocator.free(tc.id);
        allocator.free(tc.name);
        allocator.free(tc.arguments_json);
        if (tc.thought_signature) |sig| allocator.free(sig);
    }

    try std.testing.expect(tc.thought_signature != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.thought_signature.?, "reasoning.encrypted") != null);
}

test "ToolCallTracker - setThoughtSignatureById does nothing for non-existent ID" {
    const allocator = std.testing.allocator;

    var tracker = ToolCallTracker.init(allocator);
    defer tracker.deinit();

    _ = try tracker.startCall(0, 0, "call_abc123", "bash");

    // Try to set signature on non-existent tool call ID
    try tracker.setThoughtSignatureById("nonexistent_id", "{\"type\":\"reasoning.encrypted\"}");

    // Complete and verify thought_signature is still null
    const tc = tracker.completeCall(0, allocator).?;
    defer {
        allocator.free(tc.id);
        allocator.free(tc.name);
        allocator.free(tc.arguments_json);
        if (tc.thought_signature) |sig| allocator.free(sig);
    }

    try std.testing.expect(tc.thought_signature == null);
}

test "ToolCallTracker - thought_signature is freed in deinit for incomplete calls" {
    const allocator = std.testing.allocator;

    var tracker = ToolCallTracker.init(allocator);

    _ = try tracker.startCall(0, 0, "call_abc123", "bash");
    try tracker.setThoughtSignatureById("call_abc123", "{\"type\":\"reasoning.encrypted\"}");

    // deinit should clean up thought_signature memory without leaks
    tracker.deinit();
}
