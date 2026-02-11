const std = @import("std");
const types = @import("types");

/// Get API key from environment variable or ~/.makai/auth.json
pub fn getApiKey(allocator: std.mem.Allocator, provider_name: []const u8) !?[]const u8 {
    // Construct environment variable name (e.g., ANTHROPIC_API_KEY)
    var env_var_name: std.ArrayList(u8) = .{};
    defer env_var_name.deinit(allocator);

    try env_var_name.appendSlice(allocator, provider_name);
    try env_var_name.appendSlice(allocator, "_API_KEY");

    // Convert to uppercase
    for (env_var_name.items) |*c| {
        c.* = std.ascii.toUpper(c.*);
    }

    // Try environment variable first
    if (std.process.getEnvVarOwned(allocator, env_var_name.items)) |key| {
        return key;
    } else |_| {
        // Fall back to auth.json
        return getApiKeyFromAuthFile(allocator, provider_name);
    }
}

/// Read API key from ~/.makai/auth.json
fn getApiKeyFromAuthFile(allocator: std.mem.Allocator, provider_name: []const u8) !?[]const u8 {
    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home_dir);

    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".makai", "auth.json" });
    defer allocator.free(auth_path);

    const file = std.fs.openFileAbsolute(auth_path, .{}) catch return null;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const providers = root.object.get("providers") orelse return null;
    if (providers != .object) return null;

    const provider_obj = providers.object.get(provider_name) orelse return null;
    if (provider_obj != .object) return null;

    const api_key = provider_obj.object.get("api_key") orelse return null;
    if (api_key != .string) return null;

    return try allocator.dupe(u8, api_key.string);
}

/// Check if a provider should be skipped (no credentials)
pub fn shouldSkipProvider(allocator: std.mem.Allocator, provider_name: []const u8) bool {
    const api_key = getApiKey(allocator, provider_name) catch return true;
    if (api_key) |key| {
        allocator.free(key);
        return false;
    }
    return true;
}

/// Free allocated strings in a MessageEvent
pub fn freeEvent(event: types.MessageEvent, allocator: std.mem.Allocator) void {
    switch (event) {
        .start => |s| allocator.free(s.model),
        .text_delta => |d| allocator.free(d.delta),
        .thinking_delta => |d| allocator.free(d.delta),
        .toolcall_start => |tc| {
            allocator.free(tc.id);
            allocator.free(tc.name);
        },
        .toolcall_delta => |d| allocator.free(d.delta),
        .toolcall_end => |e| allocator.free(e.input_json),
        .@"error" => |e| allocator.free(e.message),
        else => {},
    }
}

/// Event accumulator for tracking streaming events
pub const EventAccumulator = struct {
    events_seen: usize = 0,
    text_buffer: std.ArrayList(u8),
    thinking_buffer: std.ArrayList(u8),
    tool_calls: std.ArrayList(ToolCall),
    last_model: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub const ToolCall = struct {
        id: []const u8,
        name: []const u8,
        input_json: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) EventAccumulator {
        return .{
            .text_buffer = .{},
            .thinking_buffer = .{},
            .tool_calls = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EventAccumulator) void {
        self.text_buffer.deinit(self.allocator);
        self.thinking_buffer.deinit(self.allocator);
        for (self.tool_calls.items) |tc| {
            self.allocator.free(tc.id);
            self.allocator.free(tc.name);
            self.allocator.free(tc.input_json);
        }
        self.tool_calls.deinit(self.allocator);
        if (self.last_model) |m| {
            self.allocator.free(m);
        }
    }

    pub fn processEvent(self: *EventAccumulator, event: types.MessageEvent) !void {
        self.events_seen += 1;

        switch (event) {
            .start => |s| {
                if (self.last_model) |m| {
                    self.allocator.free(m);
                }
                self.last_model = try self.allocator.dupe(u8, s.model);
            },
            .text_delta => |delta| {
                try self.text_buffer.appendSlice(self.allocator, delta.delta);
            },
            .thinking_delta => |delta| {
                try self.thinking_buffer.appendSlice(self.allocator, delta.delta);
            },
            .toolcall_start => |tc| {
                const tool_call = ToolCall{
                    .id = try self.allocator.dupe(u8, tc.id),
                    .name = try self.allocator.dupe(u8, tc.name),
                    .input_json = &[_]u8{},
                };
                try self.tool_calls.append(self.allocator, tool_call);
            },
            .toolcall_end => |tc| {
                if (self.tool_calls.items.len > 0) {
                    const last_idx = self.tool_calls.items.len - 1;
                    self.allocator.free(self.tool_calls.items[last_idx].input_json);
                    self.tool_calls.items[last_idx].input_json = try self.allocator.dupe(u8, tc.input_json);
                }
            },
            else => {},
        }

        // Free the event's allocated strings after processing
        freeEvent(event, self.allocator);
    }
};

/// Basic text generation test helper
pub fn basicTextGeneration(
    allocator: std.mem.Allocator,
    stream: anytype,
    expected_min_text_length: usize,
) !void {
    var accumulator = EventAccumulator.init(allocator);
    defer accumulator.deinit();

    // Poll events
    while (true) {
        if (stream.poll()) |event| {
            try accumulator.processEvent(event);
        } else {
            if (stream.completed.load(.acquire)) {
                break;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Check for error
    if (stream.err_msg != null) {
        std.debug.print("Stream error: {s}\n", .{stream.err_msg.?});
        return error.StreamError;
    }

    // Validate result
    const result = stream.result orelse return error.NoResult;

    try std.testing.expect(accumulator.events_seen > 0);
    try std.testing.expect(accumulator.text_buffer.items.len >= expected_min_text_length);
    try std.testing.expect(result.content.len > 0);
    try std.testing.expect(result.usage.output_tokens > 0);
}

// Unit tests
test "EventAccumulator init and deinit" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    try std.testing.expectEqual(@as(usize, 0), accumulator.events_seen);
    try std.testing.expectEqual(@as(usize, 0), accumulator.text_buffer.items.len);
}

test "EventAccumulator process start event" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    const event = types.MessageEvent{ .start = .{ .model = "test-model" } };
    try accumulator.processEvent(event);

    try std.testing.expectEqual(@as(usize, 1), accumulator.events_seen);
    try std.testing.expectEqualStrings("test-model", accumulator.last_model.?);
}

test "EventAccumulator process text delta" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    const event1 = types.MessageEvent{ .text_delta = .{ .index = 0, .delta = "Hello" } };
    const event2 = types.MessageEvent{ .text_delta = .{ .index = 0, .delta = " world" } };

    try accumulator.processEvent(event1);
    try accumulator.processEvent(event2);

    try std.testing.expectEqual(@as(usize, 2), accumulator.events_seen);
    try std.testing.expectEqualStrings("Hello world", accumulator.text_buffer.items);
}

test "EventAccumulator process thinking delta" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    const event = types.MessageEvent{ .thinking_delta = .{ .index = 0, .delta = "reasoning..." } };
    try accumulator.processEvent(event);

    try std.testing.expectEqualStrings("reasoning...", accumulator.thinking_buffer.items);
}

test "EventAccumulator process tool call" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    const start_event = types.MessageEvent{ .toolcall_start = .{ .index = 0, .id = "call_1", .name = "test_tool" } };
    const end_event = types.MessageEvent{ .toolcall_end = .{ .index = 0, .input_json = "{\"arg\":\"value\"}" } };

    try accumulator.processEvent(start_event);
    try accumulator.processEvent(end_event);

    try std.testing.expectEqual(@as(usize, 1), accumulator.tool_calls.items.len);
    try std.testing.expectEqualStrings("call_1", accumulator.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("test_tool", accumulator.tool_calls.items[0].name);
    try std.testing.expectEqualStrings("{\"arg\":\"value\"}", accumulator.tool_calls.items[0].input_json);
}
