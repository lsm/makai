
const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const StringBuilder = @import("string_builder").StringBuilder;

pub const TransformConfig = struct {
    target_api: []const u8 = "",
    target_provider: []const u8 = "",
    target_model_id: []const u8 = "",
    max_tool_id_len: usize = 0,
    mistral_tool_ids: bool = false,
    insert_synthetic_results: bool = true,
    tools: ?[]const ai_types.Tool = null,
    is_oauth: bool = false,
};

fn isSameModel(msg: ai_types.AssistantMessage, config: TransformConfig) bool {
    if (config.target_api.len == 0 or config.target_provider.len == 0 or config.target_model_id.len == 0)
        return false;
    return std.mem.eql(u8, msg.api, config.target_api) and
        std.mem.eql(u8, msg.provider, config.target_provider) and
        std.mem.eql(u8, msg.model, config.target_model_id);
}

pub fn normalizeToolId(allocator: std.mem.Allocator, id: []const u8, max_len: usize) ![]const u8 {
    var effective_id = id;
    if (std.mem.find(u8, id, "|")) |pipe_pos| {
        effective_id = id[0..pipe_pos];
    }

    const limit = if (max_len > 0) max_len else effective_id.len;
    const final_len = @min(effective_id.len, limit);

    var sb = StringBuilder{};
    sb.count(effective_id[0..final_len]);

    try sb.allocate(allocator);
    errdefer sb.deinit(allocator);

    for (effective_id[0..final_len]) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            var ch = [1]u8{c};
            _ = sb.append(&ch);
        } else {
            _ = sb.append("_");
        }
    }

    std.debug.assert(sb.len == sb.cap);
    const out = sb.ptr.?[0..sb.cap];
    sb.ptr = null;
    sb.cap = 0;
    sb.len = 0;
    return out;
}

pub fn mistralToolId(allocator: std.mem.Allocator, source_id: []const u8) ![]const u8 {
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var hash: u64 = 0;
    for (source_id) |c| {
        hash = hash *% 31 +% c;
    }

    const result = try allocator.alloc(u8, 9);
    for (result, 0..) |*r, i| {
        const idx = @as(usize, @intCast((hash >> @intCast(i * 6)) & 0x3F)) % chars.len;
        r.* = chars[idx];
    }
    return result;
}

pub fn fromClaudeCodeName(name: []const u8, tools: ?[]const ai_types.Tool) []const u8 {
    const t = tools orelse return name;
    for (t) |tool| {
        if (eqlIgnoreCase(name, tool.name)) {
            return tool.name;
        }
    }
    return name;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

pub const TransformResult = struct {
    messages: []ai_types.Message,
    owned_content: std.ArrayList([]const ai_types.AssistantContent),
    owned_tool_ids: std.ArrayList([]const u8),
    owned_synthetic: std.ArrayList(SyntheticToolResult),
    allocator: std.mem.Allocator,

    const SyntheticToolResult = struct {
        tool_call_id: []const u8,
        tool_name: []const u8,
        content: []const ai_types.UserContentPart,
        message: ai_types.ToolResultMessage,
    };

    pub fn deinit(self: *TransformResult) void {
        for (self.owned_content.items) |content| {
            for (content) |block| {
                switch (block) {
                    .text => |t| {
                        self.allocator.free(t.text);
                        if (t.text_signature) |s| self.allocator.free(s);
                    },
                    .thinking => |t| {
                        self.allocator.free(t.thinking);
                        if (t.thinking_signature) |s| self.allocator.free(s);
                    },
                    .tool_call => |tc| {
                        self.allocator.free(tc.id);
                        self.allocator.free(tc.name);
                        if (tc.arguments_json.len > 0) self.allocator.free(tc.arguments_json);
                        if (tc.thought_signature) |s| self.allocator.free(s);
                    },
                    .image => |img| {
                        self.allocator.free(img.data);
                        self.allocator.free(img.mime_type);
                    },
                }
            }
            self.allocator.free(content);
        }
        self.owned_content.deinit(self.allocator);

        for (self.owned_tool_ids.items) |id| {
            self.allocator.free(id);
        }
        self.owned_tool_ids.deinit(self.allocator);

        for (self.owned_synthetic.items) |s| {
            self.allocator.free(s.tool_call_id);
            self.allocator.free(s.tool_name);
            self.allocator.free(s.content);
        }
        self.owned_synthetic.deinit(self.allocator);

        self.allocator.free(self.messages);
    }
};

pub fn preTransform(
    allocator: std.mem.Allocator,
    messages: []const ai_types.Message,
    config: TransformConfig,
) !TransformResult {
    var result_messages = std.ArrayList(ai_types.Message).empty;
    errdefer result_messages.deinit(allocator);

    var owned_content = std.ArrayList([]const ai_types.AssistantContent).empty;
    errdefer owned_content.deinit(allocator);

    var owned_tool_ids = std.ArrayList([]const u8).empty;
    errdefer owned_tool_ids.deinit(allocator);

    var owned_synthetic = std.ArrayList(TransformResult.SyntheticToolResult).empty;
    errdefer owned_synthetic.deinit(allocator);

    var tool_id_map = std.StringHashMap([]const u8).init(allocator);
    defer {
        tool_id_map.deinit();
    }

    var all_tool_call_ids = std.ArrayList(struct { id: []const u8, name: []const u8 }).empty;
    defer all_tool_call_ids.deinit(allocator);

    var existing_result_ids = std.StringHashMap(void).init(allocator);
    defer existing_result_ids.deinit();

    for (messages) |msg| {
        switch (msg) {
            .assistant => |a| {
                for (a.content) |c| {
                    if (c == .tool_call) {
                        try all_tool_call_ids.append(allocator, .{ .id = c.tool_call.id, .name = c.tool_call.name });

                        if (config.max_tool_id_len > 0 or config.mistral_tool_ids or
                            std.mem.find(u8, c.tool_call.id, "|") != null)
                        {
                            const normalized = if (config.mistral_tool_ids)
                                try mistralToolId(allocator, c.tool_call.id)
                            else
                                try normalizeToolId(allocator, c.tool_call.id, config.max_tool_id_len);
                            try owned_tool_ids.append(allocator, normalized);
                            try tool_id_map.put(c.tool_call.id, normalized);
                        }
                    }
                }
            },
            .tool_result => |tr| {
                try existing_result_ids.put(tr.tool_call_id, {});
            },
            else => {},
        }
    }

    var pending_tool_calls = std.ArrayList(struct { id: []const u8, name: []const u8 }).empty;
    defer pending_tool_calls.deinit(allocator);
    var pending_result_ids = std.StringHashMap(void).init(allocator);
    defer pending_result_ids.deinit();

    for (messages) |msg| {
        switch (msg) {
            .assistant => |a| {
                if (config.insert_synthetic_results and pending_tool_calls.items.len > 0) {
                    for (pending_tool_calls.items) |tc| {
                        if (!pending_result_ids.contains(tc.id)) {
                            const syn = try createSyntheticResult(allocator, tc.id, tc.name, &tool_id_map);
                            try owned_synthetic.append(allocator, syn);
                            const idx = owned_synthetic.items.len - 1;
                            try result_messages.append(allocator, .{
                                .tool_result = owned_synthetic.items[idx].message,
                            });
                        }
                    }
                    pending_tool_calls.clearRetainingCapacity();
                    pending_result_ids.clearRetainingCapacity();
                }

                if (a.stop_reason == .aborted or a.stop_reason == .@"error") continue;

                const same_model = isSameModel(a, config);

                var new_content = std.ArrayList(ai_types.AssistantContent).empty;
                errdefer new_content.deinit(allocator);

                for (a.content) |block| {
                    switch (block) {
                        .thinking => |t| {
                            if (same_model) {
                                if (t.thinking_signature) |sig| {
                                    try new_content.append(allocator, .{ .thinking = .{
                                        .thinking = try allocator.dupe(u8, t.thinking),
                                        .thinking_signature = try allocator.dupe(u8, sig),
                                    } });
                                    continue;
                                }
                                if (t.thinking.len == 0 or std.mem.trim(u8, t.thinking, " \t\r\n").len == 0) continue;
                                try new_content.append(allocator, .{ .thinking = .{
                                    .thinking = try allocator.dupe(u8, t.thinking),
                                    .thinking_signature = if (t.thinking_signature) |s| try allocator.dupe(u8, s) else null,
                                } });
                            } else {
                                if (t.thinking.len == 0 or std.mem.trim(u8, t.thinking, " \t\r\n").len == 0) continue;
                                try new_content.append(allocator, .{ .text = .{
                                    .text = try allocator.dupe(u8, t.thinking),
                                } });
                            }
                        },
                        .text => |t| {
                            if (same_model) {
                                try new_content.append(allocator, .{ .text = .{
                                    .text = try allocator.dupe(u8, t.text),
                                    .text_signature = if (t.text_signature) |s| try allocator.dupe(u8, s) else null,
                                } });
                            } else {
                                try new_content.append(allocator, .{ .text = .{
                                    .text = try allocator.dupe(u8, t.text),
                                } });
                            }
                        },
                        .tool_call => |tc| {
                            const normalized_id = if (tool_id_map.get(tc.id)) |nid|
                                try allocator.dupe(u8, nid)
                            else
                                try allocator.dupe(u8, tc.id);

                            const normalized_name = if (config.is_oauth)
                                try allocator.dupe(u8, fromClaudeCodeName(tc.name, config.tools))
                            else
                                try allocator.dupe(u8, tc.name);

                            const sig = if (same_model and tc.thought_signature != null)
                                try allocator.dupe(u8, tc.thought_signature.?)
                            else
                                null;

                            try new_content.append(allocator, .{ .tool_call = .{
                                .id = normalized_id,
                                .name = normalized_name,
                                .arguments_json = if (tc.arguments_json.len > 0) try allocator.dupe(u8, tc.arguments_json) else "",
                                .thought_signature = sig,
                            } });

                            try pending_tool_calls.append(allocator, .{ .id = normalized_id, .name = normalized_name });
                        },
                        .image => |img| {
                            try new_content.append(allocator, .{ .image = .{
                                .data = try allocator.dupe(u8, img.data),
                                .mime_type = try allocator.dupe(u8, img.mime_type),
                            } });
                        },
                    }
                }

                const new_slice = try new_content.toOwnedSlice(allocator);
                try owned_content.append(allocator, new_slice);

                var new_msg = a;
                new_msg.content = new_slice;
                try result_messages.append(allocator, .{ .assistant = new_msg });
            },
            .tool_result => |tr| {
                try pending_result_ids.put(tr.tool_call_id, {});

                if (tool_id_map.get(tr.tool_call_id)) |normalized_id| {
                    var new_tr = tr;
                    new_tr.tool_call_id = normalized_id;
                    try result_messages.append(allocator, .{ .tool_result = new_tr });
                } else {
                    try result_messages.append(allocator, msg);
                }
            },
            .user => {
                if (config.insert_synthetic_results and pending_tool_calls.items.len > 0) {
                    for (pending_tool_calls.items) |tc| {
                        if (!pending_result_ids.contains(tc.id)) {
                            const syn = try createSyntheticResult(allocator, tc.id, tc.name, &tool_id_map);
                            try owned_synthetic.append(allocator, syn);
                            const idx = owned_synthetic.items.len - 1;
                            try result_messages.append(allocator, .{
                                .tool_result = owned_synthetic.items[idx].message,
                            });
                        }
                    }
                    pending_tool_calls.clearRetainingCapacity();
                    pending_result_ids.clearRetainingCapacity();
                }

                try result_messages.append(allocator, msg);
            },
        }
    }

    if (config.insert_synthetic_results and pending_tool_calls.items.len > 0) {
        for (pending_tool_calls.items) |tc| {
            if (!pending_result_ids.contains(tc.id)) {
                const syn = try createSyntheticResult(allocator, tc.id, tc.name, &tool_id_map);
                try owned_synthetic.append(allocator, syn);
                const idx = owned_synthetic.items.len - 1;
                try result_messages.append(allocator, .{
                    .tool_result = owned_synthetic.items[idx].message,
                });
            }
        }
    }

    return .{
        .messages = try result_messages.toOwnedSlice(allocator),
        .owned_content = owned_content,
        .owned_tool_ids = owned_tool_ids,
        .owned_synthetic = owned_synthetic,
        .allocator = allocator,
    };
}

fn createSyntheticResult(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    tool_name: []const u8,
    tool_id_map: *const std.StringHashMap([]const u8),
) !TransformResult.SyntheticToolResult {
    const effective_id = if (tool_id_map.get(tool_call_id)) |nid| nid else tool_call_id;
    const id_dup = try allocator.dupe(u8, effective_id);
    errdefer allocator.free(id_dup);
    const name_dup = try allocator.dupe(u8, tool_name);
    errdefer allocator.free(name_dup);

    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    content[0] = .{ .text = .{ .text = "No result provided" } };

    return .{
        .tool_call_id = id_dup,
        .tool_name = name_dup,
        .content = content,
        .message = .{
            .tool_call_id = id_dup,
            .tool_name = name_dup,
            .content = content,
            .is_error = true,
            .timestamp = compat.time.nowMillis(),
        },
    };
}

test "normalizeToolId strips pipe suffix" {
    const allocator = std.testing.allocator;
    const result = try normalizeToolId(allocator, "call_123|very_long_id_suffix", 40);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("call_123", result);
}

test "normalizeToolId truncates to max_len" {
    const allocator = std.testing.allocator;
    const result = try normalizeToolId(allocator, "abcdefghijklmnopqrstuvwxyz1234567890ABCDEFGHIJ", 40);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 40), result.len);
}

test "normalizeToolId sanitizes special chars" {
    const allocator = std.testing.allocator;
    const result = try normalizeToolId(allocator, "call+123/abc=def", 0);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("call_123_abc_def", result);
}

test "normalizeToolId no-op for clean short IDs" {
    const allocator = std.testing.allocator;
    const result = try normalizeToolId(allocator, "call_abc123", 40);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("call_abc123", result);
}

test "mistralToolId generates 9 chars" {
    const allocator = std.testing.allocator;
    const result = try mistralToolId(allocator, "call_123456");
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 9), result.len);
    for (result) |c| {
        try std.testing.expect(std.ascii.isAlphanumeric(c));
    }
}

test "mistralToolId is deterministic" {
    const allocator = std.testing.allocator;
    const r1 = try mistralToolId(allocator, "call_123456");
    defer allocator.free(r1);
    const r2 = try mistralToolId(allocator, "call_123456");
    defer allocator.free(r2);
    try std.testing.expectEqualStrings(r1, r2);
}

test "fromClaudeCodeName case-insensitive match" {
    const tools = [_]ai_types.Tool{
        .{ .name = "Bash", .description = "Run bash", .parameters_schema_json = "{}" },
        .{ .name = "Read", .description = "Read file", .parameters_schema_json = "{}" },
    };
    try std.testing.expectEqualStrings("Bash", fromClaudeCodeName("bash", &tools));
    try std.testing.expectEqualStrings("Read", fromClaudeCodeName("READ", &tools));
    try std.testing.expectEqualStrings("unknown", fromClaudeCodeName("unknown", &tools));
}

test "preTransform skips aborted messages" {
    const allocator = std.testing.allocator;
    const messages = [_]ai_types.Message{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } },
        .{ .assistant = .{
            .content = &.{.{ .text = .{ .text = "response" } }},
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .aborted,
            .timestamp = 0,
        } },
        .{ .user = .{ .content = .{ .text = "retry" }, .timestamp = 0 } },
    };

    var result = try preTransform(allocator, &messages, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.messages.len);
    try std.testing.expect(result.messages[0] == .user);
    try std.testing.expect(result.messages[1] == .user);
}

test "preTransform converts thinking to text for cross-model" {
    const allocator = std.testing.allocator;
    const messages = [_]ai_types.Message{
        .{ .assistant = .{
            .content = &.{
                .{ .thinking = .{ .thinking = "internal reasoning", .thinking_signature = "sig123" } },
                .{ .text = .{ .text = "response" } },
            },
            .api = "anthropic",
            .provider = "anthropic",
            .model = "claude-3",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 0,
        } },
    };

    var result = try preTransform(allocator, &messages, .{
        .target_api = "openai",
        .target_provider = "openai",
        .target_model_id = "gpt-4",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.messages.len);
    const a = result.messages[0].assistant;
    try std.testing.expectEqual(@as(usize, 2), a.content.len);
    try std.testing.expect(a.content[0] == .text);
    try std.testing.expectEqualStrings("internal reasoning", a.content[0].text.text);
    try std.testing.expect(a.content[0].text.text_signature == null);
    try std.testing.expect(a.content[1] == .text);
    try std.testing.expectEqualStrings("response", a.content[1].text.text);
}

test "preTransform keeps thinking for same model" {
    const allocator = std.testing.allocator;
    const messages = [_]ai_types.Message{
        .{ .assistant = .{
            .content = &.{
                .{ .thinking = .{ .thinking = "reasoning", .thinking_signature = "sig" } },
                .{ .text = .{ .text = "response" } },
            },
            .api = "anthropic",
            .provider = "anthropic",
            .model = "claude-3",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 0,
        } },
    };

    var result = try preTransform(allocator, &messages, .{
        .target_api = "anthropic",
        .target_provider = "anthropic",
        .target_model_id = "claude-3",
    });
    defer result.deinit();

    const a = result.messages[0].assistant;
    try std.testing.expect(a.content[0] == .thinking);
    try std.testing.expectEqualStrings("reasoning", a.content[0].thinking.thinking);
    try std.testing.expectEqualStrings("sig", a.content[0].thinking.thinking_signature.?);
}

test "preTransform inserts synthetic tool results" {
    const allocator = std.testing.allocator;
    const messages = [_]ai_types.Message{
        .{ .assistant = .{
            .content = &.{
                .{ .tool_call = .{ .id = "tc_1", .name = "bash", .arguments_json = "{}" } },
                .{ .tool_call = .{ .id = "tc_2", .name = "read", .arguments_json = "{}" } },
            },
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .tool_use,
            .timestamp = 0,
        } },
        .{ .tool_result = .{ .tool_call_id = "tc_1", .tool_name = "bash", .content = &.{.{ .text = .{ .text = "ok" } }}, .is_error = false, .timestamp = 0 } },
        .{ .user = .{ .content = .{ .text = "next" }, .timestamp = 0 } },
    };

    var result = try preTransform(allocator, &messages, .{
        .target_api = "test",
        .target_provider = "test",
        .target_model_id = "test",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.messages.len);
    try std.testing.expect(result.messages[0] == .assistant);
    try std.testing.expect(result.messages[1] == .tool_result);
    try std.testing.expectEqualStrings("tc_1", result.messages[1].tool_result.tool_call_id);
    try std.testing.expect(result.messages[2] == .tool_result);
    try std.testing.expectEqualStrings("tc_2", result.messages[2].tool_result.tool_call_id);
    try std.testing.expect(result.messages[2].tool_result.is_error);
    try std.testing.expect(result.messages[3] == .user);
}

test "preTransform normalizes tool IDs with pipe" {
    const allocator = std.testing.allocator;
    const messages = [_]ai_types.Message{
        .{ .assistant = .{
            .content = &.{
                .{ .tool_call = .{ .id = "call_123|very_long_suffix_that_should_be_stripped", .name = "bash", .arguments_json = "{}" } },
            },
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .tool_use,
            .timestamp = 0,
        } },
        .{ .tool_result = .{
            .tool_call_id = "call_123|very_long_suffix_that_should_be_stripped",
            .tool_name = "bash",
            .content = &.{.{ .text = .{ .text = "ok" } }},
            .is_error = false,
            .timestamp = 0,
        } },
    };

    var result = try preTransform(allocator, &messages, .{
        .max_tool_id_len = 40,
        .target_api = "test",
        .target_provider = "test",
        .target_model_id = "test",
    });
    defer result.deinit();

    const tc = result.messages[0].assistant.content[0].tool_call;
    try std.testing.expectEqualStrings("call_123", tc.id);
    try std.testing.expectEqualStrings("call_123", result.messages[1].tool_result.tool_call_id);
}

test "preTransform strips thought_signature for cross-model tool calls" {
    const allocator = std.testing.allocator;
    const messages = [_]ai_types.Message{
        .{ .assistant = .{
            .content = &.{
                .{ .tool_call = .{ .id = "tc_1", .name = "bash", .arguments_json = "{}", .thought_signature = "encrypted_sig" } },
            },
            .api = "openai",
            .provider = "openai",
            .model = "gpt-4",
            .usage = .{},
            .stop_reason = .tool_use,
            .timestamp = 0,
        } },
    };

    var result = try preTransform(allocator, &messages, .{
        .target_api = "anthropic",
        .target_provider = "anthropic",
        .target_model_id = "claude-3",
    });
    defer result.deinit();

    const tc = result.messages[0].assistant.content[0].tool_call;
    try std.testing.expect(tc.thought_signature == null);
}
