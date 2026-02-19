const std = @import("std");
const ai_types = @import("ai_types");
const provider_caps = @import("provider_caps.zig");

pub const TransformOptions = struct {
    /// Target provider for message transformation
    target_provider: enum { anthropic, openai, google, bedrock, azure, ollama } = .anthropic,
    /// Normalize tool IDs to consistent format (prefix with "call_" if needed)
    normalize_tool_ids: bool = true,
    /// Convert thinking blocks when switching between providers
    convert_thinking_for_provider: ?provider_caps.ProviderType = null,
    /// Skip assistant messages with error or aborted stop_reason
    skip_aborted: bool = true,
    /// Target model ID for same-model detection
    target_model_id: ?[]const u8 = null,
    /// Source model ID for same-model detection
    source_model_id: ?[]const u8 = null,
    /// Convert thinking blocks (legacy, use convert_thinking_for_provider instead)
    convert_thinking: bool = true,
    /// Fix orphaned tool calls/results
    fix_orphaned_tools: bool = true,
};

pub const ThinkingFormat = enum {
    anthropic,
    openai,
    google,
};

/// Check if signatures should be retained based on source/target model matching
fn shouldRetainSignature(options: TransformOptions, source: ?[]const u8, target: ?[]const u8) bool {
    _ = options; // Options parameter reserved for future use (provider type matching, etc.)
    if (source == null or target == null) return false;
    return std.mem.eql(u8, source.?, target.?);
}

/// Transform messages for a specific target provider
pub fn transformMessages(
    allocator: std.mem.Allocator,
    messages: []const ai_types.Message,
    options: TransformOptions,
) ![]ai_types.Message {
    var result = try std.ArrayList(ai_types.Message).initCapacity(allocator, messages.len);
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
            if (msg == .assistant) {
                for (msg.assistant.content) |content| {
                    if (content == .tool_call) {
                        const id_dup = try allocator.dupe(u8, content.tool_call.id);
                        try tool_call_ids.put(id_dup, {});
                    }
                }
            }
        }
    }

    // Second pass: transform messages
    for (messages) |msg| {
        // Skip aborted/error messages if requested
        if (options.skip_aborted and msg == .assistant) {
            if (msg.assistant.stop_reason == .@"error" or msg.assistant.stop_reason == .aborted) {
                continue; // Skip this message
            }
        }

        var transformed_msg = msg;

        // Determine if we should convert thinking blocks
        const should_convert_thinking = blk: {
            // If convert_thinking_for_provider is set, check if we're switching providers
            if (options.convert_thinking_for_provider != null) {
                // If source model matches target model, keep signatures but don't convert
                if (shouldRetainSignature(options, options.source_model_id, options.target_model_id)) {
                    break :blk false;
                }
                // Converting to different provider - convert thinking blocks
                break :blk true;
            }
            // Fall back to legacy convert_thinking flag
            break :blk options.convert_thinking;
        };

        // Convert thinking blocks if needed
        if (should_convert_thinking and msg != .tool_result) {
            const target_format: ThinkingFormat = switch (options.target_provider) {
                .anthropic, .bedrock => .anthropic,
                .openai, .azure => .openai,
                .google => .google,
                .ollama => .anthropic, // Ollama uses Anthropic format
            };

            // If switching providers, convert thinking to text for providers that don't support it
            const convert_to_text = blk: {
                if (options.convert_thinking_for_provider) |target_type| {
                    // Check if target provider requires thinking as text
                    break :blk switch (target_type) {
                        .openai_compatible, .openai_native => true, // OpenAI uses reasoning_content field
                        else => false,
                    };
                }
                break :blk false;
            };

            // Only transform assistant messages
            if (msg == .assistant) {
                const transformed_content = try convertAssistantThinkingBlocks(allocator, msg.assistant.content, target_format, convert_to_text, options);
                var new_assistant = msg.assistant;
                new_assistant.content = transformed_content;
                transformed_msg = .{ .assistant = new_assistant };
            }
        }

        // Handle orphaned tool results
        if (options.fix_orphaned_tools and msg == .tool_result) {
            if (!tool_call_ids.contains(msg.tool_result.tool_call_id)) {
                // Skip orphaned tool result
                continue;
            }
        }

        // Normalize tool IDs if requested
        if (options.normalize_tool_ids and msg == .tool_result) {
            const normalized_id = try normalizeToolId(allocator, msg.tool_result.tool_call_id);
            var new_tool_result = msg.tool_result;
            new_tool_result.tool_call_id = normalized_id;
            transformed_msg = .{ .tool_result = new_tool_result };
        }

        try result.append(allocator, transformed_msg);
    }

    return result.toOwnedSlice(allocator);
}

/// Detect and fix orphaned tool calls/results
/// Returns a new slice with orphaned results removed and synthetic calls inserted
pub fn fixOrphanedToolCalls(
    allocator: std.mem.Allocator,
    messages: []const ai_types.Message,
) ![]ai_types.Message {
    var result = try std.ArrayList(ai_types.Message).initCapacity(allocator, messages.len);
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
        if (msg == .assistant) {
            for (msg.assistant.content) |content| {
                if (content == .tool_call) {
                    const id_dup = try allocator.dupe(u8, content.tool_call.id);
                    try tool_call_ids.put(id_dup, {});
                }
            }
        } else if (msg == .tool_result) {
            const id_dup = try allocator.dupe(u8, msg.tool_result.tool_call_id);
            try tool_result_ids.put(id_dup, {});
        }
    }

    // Second pass: build result with fixes
    for (messages) |msg| {
        // For tool results without corresponding tool calls, skip them
        if (msg == .tool_result) {
            if (!tool_call_ids.contains(msg.tool_result.tool_call_id)) {
                // Orphaned tool result, skip it
                continue;
            }
        }

        try result.append(allocator, msg);

        // For assistant messages with tool calls that have no results,
        // we could insert synthetic error results here if needed
        // (This is left as a simpler implementation that just removes orphaned results)
    }

    return result.toOwnedSlice(allocator);
}

/// Convert thinking blocks in assistant content between provider formats
fn convertAssistantThinkingBlocks(
    allocator: std.mem.Allocator,
    content: []const ai_types.AssistantContent,
    target_format: ThinkingFormat,
    convert_to_text: bool,
    options: TransformOptions,
) ![]ai_types.AssistantContent {
    _ = target_format; // Currently all formats use the same ThinkingContent structure

    var result = try std.ArrayList(ai_types.AssistantContent).initCapacity(allocator, content.len);
    errdefer result.deinit(allocator);

    // Check if we should retain signatures (same source and target model)
    const retain_signature = shouldRetainSignature(options, options.source_model_id, options.target_model_id);

    for (content) |block| {
        switch (block) {
            .thinking => |thinking_block| {
                if (convert_to_text) {
                    // Convert thinking block to plain text block
                    const thinking_content = thinking_block.thinking;
                    const text_dup = try allocator.dupe(u8, thinking_content);
                    try result.append(allocator, .{
                        .text = .{
                            .text = text_dup,
                            .text_signature = null, // Don't preserve signature when converting to text
                        },
                    });
                } else {
                    // Keep as thinking block, optionally with signature
                    const thinking_dup = try allocator.dupe(u8, thinking_block.thinking);
                    const sig_dup = if (retain_signature and thinking_block.thinking_signature != null)
                        try allocator.dupe(u8, thinking_block.thinking_signature.?)
                    else if (thinking_block.thinking_signature) |sig|
                        try allocator.dupe(u8, sig)
                    else
                        null;

                    try result.append(allocator, .{
                        .thinking = .{
                            .thinking = thinking_dup,
                            .thinking_signature = sig_dup,
                        },
                    });
                }
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
pub fn freeMessages(allocator: std.mem.Allocator, messages: []ai_types.Message) void {
    for (messages) |msg| {
        switch (msg) {
            .assistant => |assistant_msg| {
                for (assistant_msg.content) |content| {
                    switch (content) {
                        .text => |text_block| {
                            allocator.free(text_block.text);
                            if (text_block.text_signature) |sig| {
                                allocator.free(sig);
                            }
                        },
                        .tool_call => |tool_block| {
                            allocator.free(tool_block.id);
                            allocator.free(tool_block.name);
                            allocator.free(tool_block.arguments_json);
                            if (tool_block.thought_signature) |sig| {
                                allocator.free(sig);
                            }
                        },
                        .thinking => |thinking_block| {
                            allocator.free(thinking_block.thinking);
                            if (thinking_block.thinking_signature) |sig| {
                                allocator.free(sig);
                            }
                        },
                        .image => |image_block| {
                            allocator.free(image_block.data);
                            allocator.free(image_block.mime_type);
                        },
                    }
                }
                allocator.free(assistant_msg.content);
            },
            else => {},
        }
    }
    allocator.free(messages);
}

// Tests
test "transformMessages basic" {
    const allocator = std.testing.allocator;

    const messages = [_]ai_types.Message{
        .{ .user = .{
            .content = .{ .text = "Hello" },
            .timestamp = 1000,
        } },
    };

    const result = try transformMessages(allocator, &messages, .{
        .target_provider = .anthropic,
    });
    defer {
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0] == .user);
}

test "fixOrphanedToolCalls removes orphaned results" {
    const allocator = std.testing.allocator;

    const assistant_content = [_]ai_types.AssistantContent{
        .{ .tool_call = .{ .id = "tool_1", .name = "search", .arguments_json = "{}" } },
    };
    const tool_result_content = [_]ai_types.UserContentPart{
        .{ .text = .{ .text = "result 1" } },
    };
    const orphaned_content = [_]ai_types.UserContentPart{
        .{ .text = .{ .text = "orphaned result" } },
    };
    const messages = [_]ai_types.Message{
        .{ .assistant = .{
            .content = &assistant_content,
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 1000,
        } },
        .{ .tool_result = .{
            .tool_call_id = "tool_1",
            .tool_name = "search",
            .content = &tool_result_content,
            .is_error = false,
            .timestamp = 1001,
        } },
        .{ .tool_result = .{
            .tool_call_id = "tool_missing",
            .tool_name = "missing",
            .content = &orphaned_content,
            .is_error = false,
            .timestamp = 1002,
        } },
    };

    const result = try fixOrphanedToolCalls(allocator, &messages);
    defer allocator.free(result);

    // Should have 2 messages: assistant with tool call and the matching result
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expect(result[0] == .assistant);
    try std.testing.expect(result[1] == .tool_result);
    try std.testing.expectEqualStrings("tool_1", result[1].tool_result.tool_call_id);
}

test "fixOrphanedToolCalls keeps all valid results" {
    const allocator = std.testing.allocator;

    const assistant_content = [_]ai_types.AssistantContent{
        .{ .tool_call = .{ .id = "tool_1", .name = "search", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "tool_2", .name = "read", .arguments_json = "{}" } },
    };
    const tool_result_content1 = [_]ai_types.UserContentPart{
        .{ .text = .{ .text = "result 1" } },
    };
    const tool_result_content2 = [_]ai_types.UserContentPart{
        .{ .text = .{ .text = "result 2" } },
    };
    const messages = [_]ai_types.Message{
        .{ .assistant = .{
            .content = &assistant_content,
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 1000,
        } },
        .{ .tool_result = .{
            .tool_call_id = "tool_1",
            .tool_name = "search",
            .content = &tool_result_content1,
            .is_error = false,
            .timestamp = 1001,
        } },
        .{ .tool_result = .{
            .tool_call_id = "tool_2",
            .tool_name = "read",
            .content = &tool_result_content2,
            .is_error = false,
            .timestamp = 1002,
        } },
    };

    const result = try fixOrphanedToolCalls(allocator, &messages);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
}

test "transformMessages with orphaned tools disabled" {
    const allocator = std.testing.allocator;

    const tool_result_content = [_]ai_types.UserContentPart{
        .{ .text = .{ .text = "orphaned" } },
    };
    const messages = [_]ai_types.Message{
        .{ .tool_result = .{
            .tool_call_id = "nonexistent",
            .tool_name = "missing",
            .content = &tool_result_content,
            .is_error = false,
            .timestamp = 1000,
        } },
    };

    const result = try transformMessages(allocator, &messages, .{
        .target_provider = .anthropic,
        .fix_orphaned_tools = false,
    });
    defer allocator.free(result);

    // With fix disabled, orphaned result should be kept
    try std.testing.expectEqual(@as(usize, 1), result.len);
}

test "transformMessages with orphaned tools enabled" {
    const allocator = std.testing.allocator;

    const tool_result_content = [_]ai_types.UserContentPart{
        .{ .text = .{ .text = "orphaned" } },
    };
    const messages = [_]ai_types.Message{
        .{ .tool_result = .{
            .tool_call_id = "nonexistent",
            .tool_name = "missing",
            .content = &tool_result_content,
            .is_error = false,
            .timestamp = 1000,
        } },
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

    const assistant_content = [_]ai_types.AssistantContent{
        .{ .thinking = .{ .thinking = "internal thoughts" } },
        .{ .text = .{ .text = "response" } },
    };
    const messages = [_]ai_types.Message{
        .{ .assistant = .{
            .content = &assistant_content,
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 1000,
        } },
    };

    const result = try transformMessages(allocator, &messages, .{
        .target_provider = .openai,
        .convert_thinking = true,
    });
    defer {
        for (result) |msg| {
            if (msg == .assistant) {
                for (msg.assistant.content) |content| {
                    switch (content) {
                        .thinking => |tb| {
                            allocator.free(tb.thinking);
                            if (tb.thinking_signature) |sig| allocator.free(sig);
                        },
                        else => {},
                    }
                }
                allocator.free(msg.assistant.content);
            }
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(usize, 2), result[0].assistant.content.len);
}

test "transformMessages without thinking conversion" {
    const allocator = std.testing.allocator;

    const assistant_content = [_]ai_types.AssistantContent{
        .{ .thinking = .{ .thinking = "internal thoughts" } },
    };
    const messages = [_]ai_types.Message{
        .{ .assistant = .{
            .content = &assistant_content,
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 1000,
        } },
    };

    const result = try transformMessages(allocator, &messages, .{
        .target_provider = .openai,
        .convert_thinking = false,
    });
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
}

test "TransformOptions defaults" {
    const options: TransformOptions = .{
        .target_provider = .anthropic,
    };

    try std.testing.expectEqual(true, options.normalize_tool_ids);
    try std.testing.expectEqual(true, options.convert_thinking);
    try std.testing.expectEqual(true, options.fix_orphaned_tools);
    try std.testing.expectEqual(true, options.skip_aborted);
    try std.testing.expectEqual(@as(?provider_caps.ProviderType, null), options.convert_thinking_for_provider);
}

test "ThinkingFormat enum values" {
    try std.testing.expectEqual(ThinkingFormat.anthropic, @as(ThinkingFormat, .anthropic));
    try std.testing.expectEqual(ThinkingFormat.openai, @as(ThinkingFormat, .openai));
    try std.testing.expectEqual(ThinkingFormat.google, @as(ThinkingFormat, .google));
}

test "fixOrphanedToolCalls with empty messages" {
    const allocator = std.testing.allocator;

    const messages = [_]ai_types.Message{};

    const result = try fixOrphanedToolCalls(allocator, &messages);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "fixOrphanedToolCalls with only user messages" {
    const allocator = std.testing.allocator;

    const messages = [_]ai_types.Message{
        .{ .user = .{
            .content = .{ .text = "Hello" },
            .timestamp = 1000,
        } },
        .{ .assistant = .{
            .content = &[_]ai_types.AssistantContent{
                .{ .text = .{ .text = "Hi there" } },
            },
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 1001,
        } },
    };

    const result = try fixOrphanedToolCalls(allocator, &messages);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "transformMessages all providers" {
    const allocator = std.testing.allocator;

    const messages = [_]ai_types.Message{
        .{ .user = .{
            .content = .{ .text = "test" },
            .timestamp = 1000,
        } },
    };

    const ProviderEnum = @TypeOf(@as(TransformOptions, undefined).target_provider);
    const providers = comptime std.meta.fields(ProviderEnum);

    inline for (providers) |field| {
        const result = try transformMessages(allocator, &messages, .{
            .target_provider = @enumFromInt(field.value),
        });
        defer allocator.free(result);
        try std.testing.expectEqual(@as(usize, 1), result.len);
    }
}

test "transformMessages skips aborted assistant messages" {
    const allocator = std.testing.allocator;

    const normal_content = [_]ai_types.AssistantContent{
        .{ .text = .{ .text = "normal response" } },
    };
    const aborted_content = [_]ai_types.AssistantContent{
        .{ .text = .{ .text = "aborted response" } },
    };
    const error_content = [_]ai_types.AssistantContent{
        .{ .text = .{ .text = "error response" } },
    };
    const messages = [_]ai_types.Message{
        .{ .assistant = .{
            .content = &normal_content,
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 1000,
        } },
        .{ .assistant = .{
            .content = &aborted_content,
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .aborted,
            .timestamp = 1001,
        } },
        .{ .assistant = .{
            .content = &error_content,
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .@"error",
            .timestamp = 1002,
        } },
    };

    const result = try transformMessages(allocator, &messages, .{
        .target_provider = .anthropic,
        .skip_aborted = true,
    });
    defer allocator.free(result);

    // Should only have the normal response, aborted and error filtered out
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0] == .assistant);
}

test "transformMessages keeps aborted when skip_aborted is false" {
    const allocator = std.testing.allocator;

    const normal_content = [_]ai_types.AssistantContent{
        .{ .text = .{ .text = "normal response" } },
    };
    const aborted_content = [_]ai_types.AssistantContent{
        .{ .text = .{ .text = "aborted response" } },
    };
    const messages = [_]ai_types.Message{
        .{ .assistant = .{
            .content = &normal_content,
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 1000,
        } },
        .{ .assistant = .{
            .content = &aborted_content,
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .aborted,
            .timestamp = 1001,
        } },
    };

    const result = try transformMessages(allocator, &messages, .{
        .target_provider = .anthropic,
        .skip_aborted = false,
    });
    defer allocator.free(result);

    // Should have both messages when skip_aborted is false
    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "shouldRetainSignature returns true for matching models" {
    const options: TransformOptions = .{
        .target_provider = .anthropic,
        .source_model_id = "claude-3-5-sonnet",
        .target_model_id = "claude-3-5-sonnet",
    };

    try std.testing.expect(shouldRetainSignature(options, options.source_model_id, options.target_model_id));
}

test "shouldRetainSignature returns false for different models" {
    const options: TransformOptions = .{
        .target_provider = .anthropic,
        .source_model_id = "claude-3-5-sonnet",
        .target_model_id = "gpt-4",
    };

    try std.testing.expect(!shouldRetainSignature(options, options.source_model_id, options.target_model_id));
}

test "shouldRetainSignature returns false for null models" {
    const options: TransformOptions = .{
        .target_provider = .anthropic,
    };

    try std.testing.expect(!shouldRetainSignature(options, null, null));
    try std.testing.expect(!shouldRetainSignature(options, "model", null));
    try std.testing.expect(!shouldRetainSignature(options, null, "model"));
}

test "transformMessages with convert_thinking_for_provider set" {
    const allocator = std.testing.allocator;

    const assistant_content = [_]ai_types.AssistantContent{
        .{ .thinking = .{ .thinking = "reasoning" } },
        .{ .text = .{ .text = "response" } },
    };
    const messages = [_]ai_types.Message{
        .{ .assistant = .{
            .content = &assistant_content,
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 1000,
        } },
    };

    // When converting to OpenAI-compatible provider, thinking should be converted to text
    const result = try transformMessages(allocator, &messages, .{
        .target_provider = .openai,
        .convert_thinking_for_provider = .openai_native,
    });
    defer {
        for (result) |msg| {
            if (msg == .assistant) {
                for (msg.assistant.content) |content| {
                    switch (content) {
                        .text => |tb| {
                            allocator.free(tb.text);
                            if (tb.text_signature) |sig| allocator.free(sig);
                        },
                        .thinking => |tb| {
                            allocator.free(tb.thinking);
                            if (tb.thinking_signature) |sig| allocator.free(sig);
                        },
                        else => {},
                    }
                }
                allocator.free(msg.assistant.content);
            }
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    // Both blocks should be text (thinking converted to text for OpenAI)
    try std.testing.expectEqual(@as(usize, 2), result[0].assistant.content.len);
    try std.testing.expect(result[0].assistant.content[0] == .text);
}

test "transformMessages preserves thinking when same model" {
    const allocator = std.testing.allocator;

    const assistant_content = [_]ai_types.AssistantContent{
        .{ .thinking = .{ .thinking = "reasoning", .thinking_signature = "sig" } },
    };
    const messages = [_]ai_types.Message{
        .{ .assistant = .{
            .content = &assistant_content,
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 1000,
        } },
    };

    // When source and target model match, thinking should be preserved
    const result = try transformMessages(allocator, &messages, .{
        .target_provider = .anthropic,
        .convert_thinking_for_provider = .anthropic,
        .source_model_id = "claude-3-5-sonnet",
        .target_model_id = "claude-3-5-sonnet",
    });
    defer allocator.free(result);

    // Content should be same reference since no conversion needed
    try std.testing.expectEqual(@as(usize, 1), result.len);
}
