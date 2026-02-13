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

/// GitHub Copilot credentials (requires both copilot_token and github_token)
pub const GitHubCopilotCredentials = struct {
    copilot_token: []const u8,
    github_token: []const u8,

    pub fn deinit(self: *GitHubCopilotCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.copilot_token);
        allocator.free(self.github_token);
    }
};

/// Get GitHub Copilot credentials from environment variable or ~/.makai/auth.json
pub fn getGitHubCopilotCredentials(allocator: std.mem.Allocator) !?GitHubCopilotCredentials {
    // Try environment variable first (COPILOT_TOKEN for CI)
    if (std.process.getEnvVarOwned(allocator, "COPILOT_TOKEN")) |token| {
        // Check for combined format: "github_token:copilot_token"
        // Split on the first colon - copilot_token may contain colons (semicolons in the token)
        if (std.mem.indexOfScalar(u8, token, ':')) |colon_pos| {
            const github_token = token[0..colon_pos];
            const copilot_token = token[colon_pos + 1 ..];
            const result = GitHubCopilotCredentials{
                .copilot_token = try allocator.dupe(u8, copilot_token),
                .github_token = try allocator.dupe(u8, github_token),
            };
            allocator.free(token);
            return result;
        } else {
            // Single token format - use as both
            // In this case, we pass ownership of token to copilot_token
            // and dupe for github_token
            return GitHubCopilotCredentials{
                .copilot_token = token,
                .github_token = try allocator.dupe(u8, token),
            };
        }
    } else |_| {
        // Fall back to auth.json
        return getGitHubCopilotCredentialsFromAuthFile(allocator);
    }
}

/// Read GitHub Copilot credentials from ~/.makai/auth.json
fn getGitHubCopilotCredentialsFromAuthFile(allocator: std.mem.Allocator) !?GitHubCopilotCredentials {
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

    const provider_val = providers.object.get("github_copilot") orelse return null;

    // Support combined format: if the value is a string, parse as "github_token:copilot_token"
    if (provider_val == .string) {
        const combined = provider_val.string;
        // Split on the first colon - copilot_token may contain colons
        if (std.mem.indexOfScalar(u8, combined, ':')) |colon_pos| {
            const github_token = combined[0..colon_pos];
            const copilot_token = combined[colon_pos + 1 ..];
            return GitHubCopilotCredentials{
                .copilot_token = try allocator.dupe(u8, copilot_token),
                .github_token = try allocator.dupe(u8, github_token),
            };
        }
        return null;
    }

    // Traditional format: object with separate copilot_token and github_token fields
    if (provider_val != .object) return null;

    const copilot_token_val = provider_val.object.get("copilot_token") orelse return null;
    if (copilot_token_val != .string) return null;

    const github_token_val = provider_val.object.get("github_token") orelse return null;
    if (github_token_val != .string) return null;

    return GitHubCopilotCredentials{
        .copilot_token = try allocator.dupe(u8, copilot_token_val.string),
        .github_token = try allocator.dupe(u8, github_token_val.string),
    };
}

/// Check if GitHub Copilot provider should be skipped (no credentials)
pub fn shouldSkipGitHubCopilot(allocator: std.mem.Allocator) bool {
    const creds = getGitHubCopilotCredentials(allocator) catch return true;
    if (creds) |c| {
        var mutable_creds = c;
        mutable_creds.deinit(allocator);
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

    // Events MUST have heap-allocated strings because processEvent() calls freeEvent()
    const model_str = try std.testing.allocator.dupe(u8, "test-model");
    const event = types.MessageEvent{ .start = .{ .model = model_str } };
    try accumulator.processEvent(event);

    try std.testing.expectEqual(@as(usize, 1), accumulator.events_seen);
    try std.testing.expectEqualStrings("test-model", accumulator.last_model.?);
}

test "EventAccumulator process text delta" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    // Events MUST have heap-allocated strings because processEvent() calls freeEvent()
    const delta1 = try std.testing.allocator.dupe(u8, "Hello");
    const delta2 = try std.testing.allocator.dupe(u8, " world");

    const event1 = types.MessageEvent{ .text_delta = .{ .index = 0, .delta = delta1 } };
    const event2 = types.MessageEvent{ .text_delta = .{ .index = 0, .delta = delta2 } };

    try accumulator.processEvent(event1);
    try accumulator.processEvent(event2);

    try std.testing.expectEqual(@as(usize, 2), accumulator.events_seen);
    try std.testing.expectEqualStrings("Hello world", accumulator.text_buffer.items);
}

test "EventAccumulator process thinking delta" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    // Events MUST have heap-allocated strings because processEvent() calls freeEvent()
    const delta = try std.testing.allocator.dupe(u8, "reasoning...");
    const event = types.MessageEvent{ .thinking_delta = .{ .index = 0, .delta = delta } };
    try accumulator.processEvent(event);

    try std.testing.expectEqualStrings("reasoning...", accumulator.thinking_buffer.items);
}

test "EventAccumulator process tool call" {
    var accumulator = EventAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    // Events MUST have heap-allocated strings because processEvent() calls freeEvent()
    const id = try std.testing.allocator.dupe(u8, "call_1");
    const name = try std.testing.allocator.dupe(u8, "test_tool");
    const input_json = try std.testing.allocator.dupe(u8, "{\"arg\":\"value\"}");

    const start_event = types.MessageEvent{ .toolcall_start = .{ .index = 0, .id = id, .name = name } };
    const end_event = types.MessageEvent{ .toolcall_end = .{ .index = 0, .input_json = input_json } };

    try accumulator.processEvent(start_event);
    try accumulator.processEvent(end_event);

    try std.testing.expectEqual(@as(usize, 1), accumulator.tool_calls.items.len);
    try std.testing.expectEqualStrings("call_1", accumulator.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("test_tool", accumulator.tool_calls.items[0].name);
    try std.testing.expectEqualStrings("{\"arg\":\"value\"}", accumulator.tool_calls.items[0].input_json);
}
