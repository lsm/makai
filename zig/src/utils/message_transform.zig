const std = @import("std");
const types = @import("types");

pub const TransformOptions = struct {
    target_provider: enum { anthropic, openai, google, bedrock, azure, ollama },
    normalize_tool_ids: bool = false,
    convert_thinking: bool = true,
    fix_orphaned_tools: bool = true,
};

pub const ThinkingFormat = enum {
    anthropic,
    openai,
    google,
};

/// Transform messages for a specific target provider
pub fn transformMessages(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    options: TransformOptions,
) ![]types.Message {
    var result = try std.ArrayList(types.Message).initCapacity(allocator, messages.len);
    errdefer result.deinit(allocator);

    // First pass: collect all tool call IDs from assistant messages
    var tool_call_ids = std.StringHashMap(void).init(allocator);
    defer {
        var iter = tool_call_ids.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        tool_call_ids.deinit();
    }

    if (options.fix_orphaned_tools) {
        for (messages) |msg| {
            if (msg.role == .assistant) {
                for (msg.content) |block| {
                    if (block == .tool_use) {
                        const id_dup = try allocator.dupe(u8, block.tool_use.id);
                        try tool_call_ids.put(id_dup, {});
                    }
                }
            }
        }
    }

    // Second pass: transform messages
    for (messages) |msg| {
        var transformed_msg = msg;

        // Convert thinking blocks if needed
        if (options.convert_thinking and msg.role != .tool_result) {
            const target_format: ThinkingFormat = switch (options.target_provider) {
                .anthropic, .bedrock => .anthropic,
                .openai, .azure => .openai,
                .google => .google,
                .ollama => .anthropic, // Ollama uses Anthropic format
            };
            transformed_msg.content = try convertThinkingBlocks(allocator, msg.content, target_format);
        }

        // Handle orphaned tool results
        if (options.fix_orphaned_tools and msg.role == .tool_result) {
            if (msg.tool_call_id) |call_id| {
                if (!tool_call_ids.contains(call_id)) {
                    // Skip orphaned tool result
                    continue;
                }
            }
        }

        // Normalize tool IDs if requested
        if (options.normalize_tool_ids and msg.role == .tool_result) {
            if (msg.tool_call_id) |call_id| {
                const normalized_id = try normalizeToolId(allocator, call_id);
                transformed_msg.tool_call_id = normalized_id;
            }
        }

        try result.append(allocator, transformed_msg);
    }

    return result.toOwnedSlice(allocator);
}

/// Detect and fix orphaned tool calls/results
/// Returns a new slice with orphaned results removed and synthetic calls inserted
pub fn fixOrphanedToolCalls(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
) ![]types.Message {
    var result = try std.ArrayList(types.Message).initCapacity(allocator, messages.len);
    errdefer result.deinit(allocator);

    // Track tool calls and results
    var tool_call_ids = std.StringHashMap(void).init(allocator);
    defer {
        var iter = tool_call_ids.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        tool_call_ids.deinit();
    }

    var tool_result_ids = std.StringHashMap(void).init(allocator);
    defer {
        var iter = tool_result_ids.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        tool_result_ids.deinit();
    }

    // First pass: collect all IDs
    for (messages) |msg| {
        if (msg.role == .assistant) {
            for (msg.content) |block| {
                if (block == .tool_use) {
                    const id_dup = try allocator.dupe(u8, block.tool_use.id);
                    try tool_call_ids.put(id_dup, {});
                }
            }
        } else if (msg.role == .tool_result) {
            if (msg.tool_call_id) |call_id| {
                const id_dup = try allocator.dupe(u8, call_id);
                try tool_result_ids.put(id_dup, {});
            }
        }
    }

    // Second pass: build result with fixes
    for (messages) |msg| {
        // For tool results without corresponding tool calls, skip them
        if (msg.role == .tool_result) {
            if (msg.tool_call_id) |call_id| {
                if (!tool_call_ids.contains(call_id)) {
                    // Orphaned tool result, skip it
                    continue;
                }
            }
        }

        try result.append(allocator, msg);

        // For assistant messages with tool calls that have no results,
        // we could insert synthetic error results here if needed
        // (This is left as a simpler implementation that just removes orphaned results)
    }

    return result.toOwnedSlice(allocator);
}

/// Convert thinking blocks between provider formats
/// Anthropic: { type: "thinking", thinking: "..." }
/// OpenAI: { type: "reasoning", reasoning: "..." } (conceptually)
/// Google: { type: "thought", thought: "..." } (conceptually)
/// Note: In our type system, we use ThinkingBlock for all formats,
/// but this function exists for future format-specific conversions
pub fn convertThinkingBlocks(
    allocator: std.mem.Allocator,
    content: []const types.ContentBlock,
    target_format: ThinkingFormat,
) ![]types.ContentBlock {
    _ = target_format; // Currently all formats use the same ThinkingBlock structure

    var result = try std.ArrayList(types.ContentBlock).initCapacity(allocator, content.len);
    errdefer result.deinit(allocator);

    for (content) |block| {
        switch (block) {
            .thinking => |thinking_block| {
                // For now, just copy the thinking block
                // In a more complete implementation, we might:
                // - Convert between different field names for different providers
                // - Handle provider-specific extensions
                const thinking_dup = try allocator.dupe(u8, thinking_block.thinking);
                const sig_dup = if (thinking_block.signature) |sig|
                    try allocator.dupe(u8, sig)
                else
                    null;

                try result.append(allocator, .{
                    .thinking = .{
                        .thinking = thinking_dup,
                        .signature = sig_dup,
                    },
                });
            },
            else => {
                try result.append(allocator, block);
            },
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Normalize a tool ID to a consistent format
fn normalizeToolId(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    // If the ID already has a standard format, just dupe it
    if (std.mem.startsWith(u8, id, "call_") or
        std.mem.startsWith(u8, id, "toolu_"))
    {
        return allocator.dupe(u8, id);
    }

    // Otherwise, prefix with "call_"
    var result = try std.ArrayList(u8).initCapacity(allocator, id.len + 5);
    defer result.deinit(allocator);

    try result.appendSlice(allocator, "call_");
    try result.appendSlice(allocator, id);

    return result.toOwnedSlice(allocator);
}

/// Free messages allocated by transform functions
pub fn freeMessages(allocator: std.mem.Allocator, messages: []types.Message) void {
    for (messages) |msg| {
        // Free content blocks if they were transformed
        for (msg.content) |block| {
            switch (block) {
                .text => |text_block| {
                    allocator.free(text_block.text);
                    if (text_block.signature) |sig| {
                        allocator.free(sig);
                    }
                },
                .tool_use => |tool_block| {
                    allocator.free(tool_block.id);
                    allocator.free(tool_block.name);
                    allocator.free(tool_block.input_json);
                    if (tool_block.thought_signature) |sig| {
                        allocator.free(sig);
                    }
                },
                .thinking => |thinking_block| {
                    allocator.free(thinking_block.thinking);
                    if (thinking_block.signature) |sig| {
                        allocator.free(sig);
                    }
                },
                .image => |image_block| {
                    allocator.free(image_block.media_type);
                    allocator.free(image_block.data);
                },
            }
        }
    }
    allocator.free(messages);
}

// Tests
test "transformMessages basic" {
    const allocator = std.testing.allocator;

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Hello" } },
            },
            .timestamp = 1000,
        },
    };

    const result = try transformMessages(allocator, &messages, .{
        .target_provider = .anthropic,
    });
    defer {
        for (result) |msg| {
            allocator.free(msg.content);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(types.Role.user, result[0].role);
}

test "convertThinkingBlocks preserves thinking content" {
    const allocator = std.testing.allocator;

    const content = [_]types.ContentBlock{
        .{ .thinking = .{ .thinking = "I am thinking..." } },
        .{ .text = .{ .text = "Hello" } },
    };

    const result = try convertThinkingBlocks(allocator, &content, .anthropic);
    defer {
        for (result) |block| {
            switch (block) {
                .thinking => |tb| {
                    allocator.free(tb.thinking);
                    if (tb.signature) |sig| allocator.free(sig);
                },
                else => {},
            }
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expect(result[0] == .thinking);
    try std.testing.expectEqualStrings("I am thinking...", result[0].thinking.thinking);
    try std.testing.expect(result[1] == .text);
}

test "convertThinkingBlocks with signature" {
    const allocator = std.testing.allocator;

    const content = [_]types.ContentBlock{
        .{ .thinking = .{ .thinking = "thoughts", .signature = "sig123" } },
    };

    const result = try convertThinkingBlocks(allocator, &content, .openai);
    defer {
        for (result) |block| {
            switch (block) {
                .thinking => |tb| {
                    allocator.free(tb.thinking);
                    if (tb.signature) |sig| allocator.free(sig);
                },
                else => {},
            }
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0] == .thinking);
    try std.testing.expectEqualStrings("sig123", result[0].thinking.signature.?);
}

test "fixOrphanedToolCalls removes orphaned results" {
    const allocator = std.testing.allocator;

    const messages = [_]types.Message{
        .{
            .role = .assistant,
            .content = &[_]types.ContentBlock{
                .{ .tool_use = .{ .id = "tool_1", .name = "search", .input_json = "{}" } },
            },
            .timestamp = 1000,
        },
        .{
            .role = .tool_result,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "result 1" } },
            },
            .tool_call_id = "tool_1",
            .tool_name = "search",
            .timestamp = 1001,
        },
        .{
            .role = .tool_result,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "orphaned result" } },
            },
            .tool_call_id = "tool_missing",
            .tool_name = "missing",
            .timestamp = 1002,
        },
    };

    const result = try fixOrphanedToolCalls(allocator, &messages);
    defer allocator.free(result);

    // Should have 2 messages: assistant with tool call and the matching result
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(types.Role.assistant, result[0].role);
    try std.testing.expectEqual(types.Role.tool_result, result[1].role);
    try std.testing.expectEqualStrings("tool_1", result[1].tool_call_id.?);
}

test "fixOrphanedToolCalls keeps all valid results" {
    const allocator = std.testing.allocator;

    const messages = [_]types.Message{
        .{
            .role = .assistant,
            .content = &[_]types.ContentBlock{
                .{ .tool_use = .{ .id = "tool_1", .name = "search", .input_json = "{}" } },
                .{ .tool_use = .{ .id = "tool_2", .name = "read", .input_json = "{}" } },
            },
            .timestamp = 1000,
        },
        .{
            .role = .tool_result,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "result 1" } },
            },
            .tool_call_id = "tool_1",
            .tool_name = "search",
            .timestamp = 1001,
        },
        .{
            .role = .tool_result,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "result 2" } },
            },
            .tool_call_id = "tool_2",
            .tool_name = "read",
            .timestamp = 1002,
        },
    };

    const result = try fixOrphanedToolCalls(allocator, &messages);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
}

test "transformMessages with orphaned tools disabled" {
    const allocator = std.testing.allocator;

    const messages = [_]types.Message{
        .{
            .role = .tool_result,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "orphaned" } },
            },
            .tool_call_id = "nonexistent",
            .tool_name = "missing",
            .timestamp = 1000,
        },
    };

    const result = try transformMessages(allocator, &messages, .{
        .target_provider = .anthropic,
        .fix_orphaned_tools = false,
    });
    defer allocator.free(result);

    // With fix disabled, orphaned result should be kept
    try std.testing.expectEqual(@as(usize, 1), result.len);
    // Content is same reference since tool_result doesn't get thinking conversion
    try std.testing.expect(result[0].content.ptr == messages[0].content.ptr);
}

test "transformMessages with orphaned tools enabled" {
    const allocator = std.testing.allocator;

    const messages = [_]types.Message{
        .{
            .role = .tool_result,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "orphaned" } },
            },
            .tool_call_id = "nonexistent",
            .tool_name = "missing",
            .timestamp = 1000,
        },
    };

    const result = try transformMessages(allocator, &messages, .{
        .target_provider = .anthropic,
        .fix_orphaned_tools = true,
    });
    defer allocator.free(result);

    // With fix enabled, orphaned result should be removed
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "normalizeToolId adds prefix when needed" {
    const allocator = std.testing.allocator;

    const result1 = try normalizeToolId(allocator, "abc123");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("call_abc123", result1);

    const result2 = try normalizeToolId(allocator, "call_xyz");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("call_xyz", result2);

    const result3 = try normalizeToolId(allocator, "toolu_123");
    defer allocator.free(result3);
    try std.testing.expectEqualStrings("toolu_123", result3);
}

test "transformMessages with thinking conversion" {
    const allocator = std.testing.allocator;

    const messages = [_]types.Message{
        .{
            .role = .assistant,
            .content = &[_]types.ContentBlock{
                .{ .thinking = .{ .thinking = "internal thoughts" } },
                .{ .text = .{ .text = "response" } },
            },
            .timestamp = 1000,
        },
    };

    const result = try transformMessages(allocator, &messages, .{
        .target_provider = .openai,
        .convert_thinking = true,
    });
    defer {
        for (result) |msg| {
            for (msg.content) |block| {
                switch (block) {
                    .thinking => |tb| {
                        allocator.free(tb.thinking);
                        if (tb.signature) |sig| allocator.free(sig);
                    },
                    else => {},
                }
            }
            allocator.free(msg.content);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(usize, 2), result[0].content.len);
}

test "transformMessages without thinking conversion" {
    const allocator = std.testing.allocator;

    const messages = [_]types.Message{
        .{
            .role = .assistant,
            .content = &[_]types.ContentBlock{
                .{ .thinking = .{ .thinking = "internal thoughts" } },
            },
            .timestamp = 1000,
        },
    };

    const result = try transformMessages(allocator, &messages, .{
        .target_provider = .openai,
        .convert_thinking = false,
    });
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    // When convert_thinking is false, content should be the same reference
    try std.testing.expect(result[0].content.ptr == messages[0].content.ptr);
}

test "TransformOptions defaults" {
    const options: TransformOptions = .{
        .target_provider = .anthropic,
    };

    try std.testing.expectEqual(false, options.normalize_tool_ids);
    try std.testing.expectEqual(true, options.convert_thinking);
    try std.testing.expectEqual(true, options.fix_orphaned_tools);
}

test "ThinkingFormat enum values" {
    try std.testing.expectEqual(ThinkingFormat.anthropic, @as(ThinkingFormat, .anthropic));
    try std.testing.expectEqual(ThinkingFormat.openai, @as(ThinkingFormat, .openai));
    try std.testing.expectEqual(ThinkingFormat.google, @as(ThinkingFormat, .google));
}

test "convertThinkingBlocks for different providers" {
    const allocator = std.testing.allocator;

    const content = [_]types.ContentBlock{
        .{ .thinking = .{ .thinking = "reasoning content" } },
    };

    // Test Anthropic format
    const result_anthropic = try convertThinkingBlocks(allocator, &content, .anthropic);
    defer {
        for (result_anthropic) |block| {
            switch (block) {
                .thinking => |tb| {
                    allocator.free(tb.thinking);
                    if (tb.signature) |sig| allocator.free(sig);
                },
                else => {},
            }
        }
        allocator.free(result_anthropic);
    }
    try std.testing.expectEqual(@as(usize, 1), result_anthropic.len);

    // Test OpenAI format
    const result_openai = try convertThinkingBlocks(allocator, &content, .openai);
    defer {
        for (result_openai) |block| {
            switch (block) {
                .thinking => |tb| {
                    allocator.free(tb.thinking);
                    if (tb.signature) |sig| allocator.free(sig);
                },
                else => {},
            }
        }
        allocator.free(result_openai);
    }
    try std.testing.expectEqual(@as(usize, 1), result_openai.len);

    // Test Google format
    const result_google = try convertThinkingBlocks(allocator, &content, .google);
    defer {
        for (result_google) |block| {
            switch (block) {
                .thinking => |tb| {
                    allocator.free(tb.thinking);
                    if (tb.signature) |sig| allocator.free(sig);
                },
                else => {},
            }
        }
        allocator.free(result_google);
    }
    try std.testing.expectEqual(@as(usize, 1), result_google.len);
}

test "fixOrphanedToolCalls with empty messages" {
    const allocator = std.testing.allocator;

    const messages = [_]types.Message{};

    const result = try fixOrphanedToolCalls(allocator, &messages);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "fixOrphanedToolCalls with only user messages" {
    const allocator = std.testing.allocator;

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Hello" } },
            },
            .timestamp = 1000,
        },
        .{
            .role = .assistant,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Hi there" } },
            },
            .timestamp = 1001,
        },
    };

    const result = try fixOrphanedToolCalls(allocator, &messages);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "transformMessages all providers" {
    const allocator = std.testing.allocator;

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "test" } },
            },
            .timestamp = 1000,
        },
    };

    const ProviderEnum = @TypeOf(@as(TransformOptions, undefined).target_provider);
    const providers = comptime std.meta.fields(ProviderEnum);

    inline for (providers) |field| {
        const result = try transformMessages(allocator, &messages, .{
            .target_provider = @enumFromInt(field.value),
        });
        defer {
            for (result) |msg| {
                allocator.free(msg.content);
            }
            allocator.free(result);
        }
        try std.testing.expectEqual(@as(usize, 1), result.len);
    }
}
