const std = @import("std");
const types = @import("types");
const model_mod = @import("model");

const Allocator = std.mem.Allocator;

/// Normalize a tool call ID to fit within provider-specific length constraints.
/// If the ID exceeds max_len, it returns: first 32 chars + "_" + hash(16 hex chars) = 49 chars max.
/// This ensures uniqueness while staying within provider limits.
/// Caller owns returned memory.
pub fn normalizeToolCallId(id: []const u8, max_len: usize, allocator: Allocator) ![]const u8 {
    if (id.len <= max_len) {
        return try allocator.dupe(u8, id);
    }

    // Take first 32 chars + "_" + 16 hex chars = 49 total
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &hash, .{});

    var hex_buf: [16]u8 = undefined;
    const hex_str = std.fmt.bytesToHex(hash[0..8], .lower);
    @memcpy(&hex_buf, &hex_str);

    const prefix_len = @min(32, id.len);
    const result = try allocator.alloc(u8, prefix_len + 1 + 16);
    @memcpy(result[0..prefix_len], id[0..prefix_len]);
    result[prefix_len] = '_';
    @memcpy(result[prefix_len + 1 ..], hex_buf[0..16]);

    return result;
}

/// Compare two models for equality (same provider and model id).
pub fn isSameModel(a: model_mod.Model, b: model_mod.Model) bool {
    return std.mem.eql(u8, a.provider, b.provider) and std.mem.eql(u8, a.id, b.id);
}

/// Get the maximum tool call ID length for a given provider.
fn getMaxToolCallIdLen(provider: []const u8) usize {
    if (std.mem.eql(u8, provider, "mistral")) {
        return 9;
    }
    // Anthropic limit is 64
    return 64;
}

/// Transform messages for cross-provider compatibility.
/// Returns a new array of transformed messages. Caller owns returned memory and all strings within.
pub fn transformMessages(
    messages: []const types.Message,
    source_model: model_mod.Model,
    target_model: model_mod.Model,
    allocator: Allocator,
) ![]types.Message {
    const same_model = isSameModel(source_model, target_model);
    const same_provider = std.mem.eql(u8, source_model.provider, target_model.provider);
    const max_id_len = getMaxToolCallIdLen(target_model.provider);

    var result_list: std.ArrayList(types.Message) = .{};
    errdefer result_list.deinit(allocator);

    // Track pending tool calls to detect orphaned ones
    var pending_tool_calls = std.StringHashMap(void).init(allocator);
    defer pending_tool_calls.deinit();

    for (messages) |msg| {
        // Skip empty assistant messages (equivalent to error/aborted)
        if (msg.role == .assistant and msg.content.len == 0) {
            continue;
        }

        // Check for orphaned tool calls before processing non-tool-result messages
        if (msg.role != .tool_result and pending_tool_calls.count() > 0) {
            // Insert synthetic error results for all pending calls
            var it = pending_tool_calls.keyIterator();
            while (it.next()) |tool_id| {
                const error_text = try allocator.dupe(u8, "No result provided");
                const error_block = types.ContentBlock{
                    .text = types.TextBlock{ .text = error_text },
                };
                const error_content = try allocator.alloc(types.ContentBlock, 1);
                error_content[0] = error_block;

                const error_msg = types.Message{
                    .role = .tool_result,
                    .content = error_content,
                    .tool_call_id = try allocator.dupe(u8, tool_id.*),
                    .is_error = true,
                    .timestamp = msg.timestamp,
                };
                try result_list.append(allocator, error_msg);
            }
            pending_tool_calls.clearRetainingCapacity();
        }

        // Process content blocks
        var new_content: std.ArrayList(types.ContentBlock) = .{};
        errdefer new_content.deinit(allocator);

        for (msg.content) |block| {
            switch (block) {
                .text => |text_block| {
                    if (same_provider) {
                        // Keep signature
                        const new_text = try allocator.dupe(u8, text_block.text);
                        const new_sig = if (text_block.signature) |sig|
                            try allocator.dupe(u8, sig)
                        else
                            null;
                        try new_content.append(allocator, .{
                            .text = .{ .text = new_text, .signature = new_sig },
                        });
                    } else {
                        // Strip signature when crossing providers
                        const new_text = try allocator.dupe(u8, text_block.text);
                        try new_content.append(allocator, .{
                            .text = .{ .text = new_text, .signature = null },
                        });
                    }
                },
                .thinking => |thinking_block| {
                    // Skip empty thinking blocks
                    if (thinking_block.thinking.len == 0) {
                        continue;
                    }

                    if (same_model) {
                        // Keep as thinking with signature
                        const new_thinking = try allocator.dupe(u8, thinking_block.thinking);
                        const new_sig = if (thinking_block.signature) |sig|
                            try allocator.dupe(u8, sig)
                        else
                            null;
                        try new_content.append(allocator, .{
                            .thinking = .{ .thinking = new_thinking, .signature = new_sig },
                        });
                    } else {
                        // Convert to text block, strip signature
                        const new_text = try allocator.dupe(u8, thinking_block.thinking);
                        try new_content.append(allocator, .{
                            .text = .{ .text = new_text, .signature = null },
                        });
                    }
                },
                .tool_use => |tool_block| {
                    // Normalize tool call ID
                    const new_id = try normalizeToolCallId(tool_block.id, max_id_len, allocator);
                    const new_name = try allocator.dupe(u8, tool_block.name);
                    const new_input = try allocator.dupe(u8, tool_block.input_json);

                    if (same_provider) {
                        // Keep thought_signature
                        const new_sig = if (tool_block.thought_signature) |sig|
                            try allocator.dupe(u8, sig)
                        else
                            null;
                        try new_content.append(allocator, .{
                            .tool_use = .{
                                .id = new_id,
                                .name = new_name,
                                .input_json = new_input,
                                .thought_signature = new_sig,
                            },
                        });
                    } else {
                        // Strip thought_signature when crossing providers
                        try new_content.append(allocator, .{
                            .tool_use = .{
                                .id = new_id,
                                .name = new_name,
                                .input_json = new_input,
                                .thought_signature = null,
                            },
                        });
                    }

                    // Track this tool call as pending (if assistant message)
                    if (msg.role == .assistant) {
                        try pending_tool_calls.put(new_id, {});
                    }
                },
                .image => |image_block| {
                    // Copy image blocks as-is
                    const new_media = try allocator.dupe(u8, image_block.media_type);
                    const new_data = try allocator.dupe(u8, image_block.data);
                    try new_content.append(allocator, .{
                        .image = .{ .media_type = new_media, .data = new_data },
                    });
                },
            }
        }

        // If this is a tool_result message, remove it from pending
        if (msg.role == .tool_result) {
            if (msg.tool_call_id) |tool_id| {
                _ = pending_tool_calls.remove(tool_id);
            }
        }

        // Create the new message
        const new_tool_call_id = if (msg.tool_call_id) |tid|
            try allocator.dupe(u8, tid)
        else
            null;
        const new_tool_name = if (msg.tool_name) |tn|
            try allocator.dupe(u8, tn)
        else
            null;

        const new_msg = types.Message{
            .role = msg.role,
            .content = try new_content.toOwnedSlice(allocator),
            .tool_call_id = new_tool_call_id,
            .tool_name = new_tool_name,
            .is_error = msg.is_error,
            .timestamp = msg.timestamp,
        };

        try result_list.append(allocator, new_msg);
    }

    // Insert synthetic results for any remaining pending tool calls
    if (pending_tool_calls.count() > 0) {
        var it = pending_tool_calls.keyIterator();
        const last_timestamp = if (messages.len > 0) messages[messages.len - 1].timestamp else 0;
        while (it.next()) |tool_id| {
            const error_text = try allocator.dupe(u8, "No result provided");
            const error_block = types.ContentBlock{
                .text = types.TextBlock{ .text = error_text },
            };
            const error_content = try allocator.alloc(types.ContentBlock, 1);
            error_content[0] = error_block;

            const error_msg = types.Message{
                .role = .tool_result,
                .content = error_content,
                .tool_call_id = try allocator.dupe(u8, tool_id.*),
                .is_error = true,
                .timestamp = last_timestamp,
            };
            try result_list.append(allocator, error_msg);
        }
    }

    return try result_list.toOwnedSlice(allocator);
}

// Tests

test "normalizeToolCallId short id" {
    const id = "short123";
    const result = try normalizeToolCallId(id, 64, std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(id, result);
}

test "normalizeToolCallId long id" {
    const id = "this_is_a_very_long_tool_call_id_that_exceeds_the_maximum_length_allowed_by_the_provider";
    const result = try normalizeToolCallId(id, 64, std.testing.allocator);
    defer std.testing.allocator.free(result);

    // Should be 32 chars + "_" + 16 hex chars = 49 chars
    try std.testing.expectEqual(@as(usize, 49), result.len);
    try std.testing.expectEqualStrings("this_is_a_very_long_tool_call_i", result[0..31]);
    try std.testing.expectEqual('d', result[31]);
    try std.testing.expectEqual('_', result[32]);
}

test "normalizeToolCallId preserves uniqueness" {
    const id1 = "this_is_a_very_long_tool_call_id_that_exceeds_the_maximum_length_allowed_1";
    const id2 = "this_is_a_very_long_tool_call_id_that_exceeds_the_maximum_length_allowed_2";

    const result1 = try normalizeToolCallId(id1, 64, std.testing.allocator);
    defer std.testing.allocator.free(result1);

    const result2 = try normalizeToolCallId(id2, 64, std.testing.allocator);
    defer std.testing.allocator.free(result2);

    // The hashes should differ
    try std.testing.expect(!std.mem.eql(u8, result1, result2));
}

test "transformMessages skips error messages" {
    const source_model = model_mod.Model{
        .id = "model-1",
        .name = "Model 1",
        .api_type = .anthropic,
        .provider = "anthropic",
    };
    const target_model = source_model;

    const empty_content: []const types.ContentBlock = &[_]types.ContentBlock{};

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
            .content = empty_content,
            .timestamp = 2000,
        },
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "World" } },
            },
            .timestamp = 3000,
        },
    };

    const result = try transformMessages(&messages, source_model, target_model, std.testing.allocator);
    defer {
        for (result) |msg| {
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| std.testing.allocator.free(t.text),
                    else => {},
                }
            }
            std.testing.allocator.free(msg.content);
        }
        std.testing.allocator.free(result);
    }

    // Should skip the empty assistant message
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(types.Role.user, result[0].role);
    try std.testing.expectEqual(types.Role.user, result[1].role);
}

test "transformMessages same model keeps signatures" {
    const source_model = model_mod.Model{
        .id = "claude-sonnet-4",
        .name = "Claude Sonnet 4",
        .api_type = .anthropic,
        .provider = "anthropic",
    };
    const target_model = source_model;

    const messages = [_]types.Message{
        .{
            .role = .assistant,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Hello", .signature = "sig123" } },
                .{ .thinking = .{ .thinking = "Let me think", .signature = "think_sig" } },
            },
            .timestamp = 1000,
        },
    };

    const result = try transformMessages(&messages, source_model, target_model, std.testing.allocator);
    defer {
        for (result) |msg| {
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| {
                        std.testing.allocator.free(t.text);
                        if (t.signature) |s| std.testing.allocator.free(s);
                    },
                    .thinking => |t| {
                        std.testing.allocator.free(t.thinking);
                        if (t.signature) |s| std.testing.allocator.free(s);
                    },
                    else => {},
                }
            }
            std.testing.allocator.free(msg.content);
        }
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(usize, 2), result[0].content.len);

    // Text block should keep signature
    try std.testing.expectEqualStrings("sig123", result[0].content[0].text.signature.?);

    // Thinking block should keep signature and type
    try std.testing.expect(std.meta.activeTag(result[0].content[1]) == .thinking);
    try std.testing.expectEqualStrings("think_sig", result[0].content[1].thinking.signature.?);
}

test "transformMessages cross provider strips signatures" {
    const source_model = model_mod.Model{
        .id = "claude-sonnet-4",
        .name = "Claude Sonnet 4",
        .api_type = .anthropic,
        .provider = "anthropic",
    };
    const target_model = model_mod.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api_type = .openai,
        .provider = "openai",
    };

    const messages = [_]types.Message{
        .{
            .role = .assistant,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Hello", .signature = "sig123" } },
                .{
                    .tool_use = .{
                        .id = "tool1",
                        .name = "search",
                        .input_json = "{}",
                        .thought_signature = "thought_sig",
                    },
                },
            },
            .timestamp = 1000,
        },
    };

    const result = try transformMessages(&messages, source_model, target_model, std.testing.allocator);
    defer {
        for (result) |msg| {
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| std.testing.allocator.free(t.text),
                    .tool_use => |tu| {
                        std.testing.allocator.free(tu.id);
                        std.testing.allocator.free(tu.name);
                        std.testing.allocator.free(tu.input_json);
                    },
                    else => {},
                }
            }
            std.testing.allocator.free(msg.content);
            if (msg.tool_call_id) |tid| std.testing.allocator.free(tid);
            if (msg.tool_name) |tn| std.testing.allocator.free(tn);
        }
        std.testing.allocator.free(result);
    }

    // Should have: assistant + synthetic tool_result (due to orphaned tool call)
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(usize, 2), result[0].content.len);

    // Text signature should be stripped
    try std.testing.expect(result[0].content[0].text.signature == null);

    // Tool thought_signature should be stripped
    try std.testing.expect(result[0].content[1].tool_use.thought_signature == null);
}

test "transformMessages converts thinking to text cross provider" {
    const source_model = model_mod.Model{
        .id = "claude-sonnet-4",
        .name = "Claude Sonnet 4",
        .api_type = .anthropic,
        .provider = "anthropic",
    };
    const target_model = model_mod.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api_type = .openai,
        .provider = "openai",
    };

    const messages = [_]types.Message{
        .{
            .role = .assistant,
            .content = &[_]types.ContentBlock{
                .{ .thinking = .{ .thinking = "Let me think about this", .signature = "think_sig" } },
            },
            .timestamp = 1000,
        },
    };

    const result = try transformMessages(&messages, source_model, target_model, std.testing.allocator);
    defer {
        for (result) |msg| {
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| std.testing.allocator.free(t.text),
                    else => {},
                }
            }
            std.testing.allocator.free(msg.content);
        }
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(usize, 1), result[0].content.len);

    // Should be converted to text block
    try std.testing.expect(std.meta.activeTag(result[0].content[0]) == .text);
    try std.testing.expectEqualStrings("Let me think about this", result[0].content[0].text.text);
    try std.testing.expect(result[0].content[0].text.signature == null);
}

test "transformMessages inserts synthetic tool results" {
    const source_model = model_mod.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api_type = .openai,
        .provider = "openai",
    };
    const target_model = source_model;

    const messages = [_]types.Message{
        .{
            .role = .assistant,
            .content = &[_]types.ContentBlock{
                .{ .tool_use = .{ .id = "tool1", .name = "search", .input_json = "{}" } },
            },
            .timestamp = 1000,
        },
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Next question" } },
            },
            .timestamp = 2000,
        },
    };

    const result = try transformMessages(&messages, source_model, target_model, std.testing.allocator);
    defer {
        for (result) |msg| {
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| std.testing.allocator.free(t.text),
                    .tool_use => |tu| {
                        std.testing.allocator.free(tu.id);
                        std.testing.allocator.free(tu.name);
                        std.testing.allocator.free(tu.input_json);
                    },
                    else => {},
                }
            }
            std.testing.allocator.free(msg.content);
            if (msg.tool_call_id) |tid| std.testing.allocator.free(tid);
        }
        std.testing.allocator.free(result);
    }

    // Should have: assistant + synthetic tool_result + user
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(types.Role.assistant, result[0].role);
    try std.testing.expectEqual(types.Role.tool_result, result[1].role);
    try std.testing.expectEqual(types.Role.user, result[2].role);

    // Synthetic result should be an error
    try std.testing.expect(result[1].is_error);
    try std.testing.expectEqualStrings("tool1", result[1].tool_call_id.?);
    try std.testing.expectEqualStrings("No result provided", result[1].content[0].text.text);
}

test "transformMessages removes empty thinking blocks" {
    const source_model = model_mod.Model{
        .id = "claude-sonnet-4",
        .name = "Claude Sonnet 4",
        .api_type = .anthropic,
        .provider = "anthropic",
    };
    const target_model = source_model;

    const messages = [_]types.Message{
        .{
            .role = .assistant,
            .content = &[_]types.ContentBlock{
                .{ .thinking = .{ .thinking = "" } },
                .{ .text = .{ .text = "Hello" } },
            },
            .timestamp = 1000,
        },
    };

    const result = try transformMessages(&messages, source_model, target_model, std.testing.allocator);
    defer {
        for (result) |msg| {
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| std.testing.allocator.free(t.text),
                    else => {},
                }
            }
            std.testing.allocator.free(msg.content);
        }
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    // Empty thinking block should be removed, leaving only text
    try std.testing.expectEqual(@as(usize, 1), result[0].content.len);
    try std.testing.expect(std.meta.activeTag(result[0].content[0]) == .text);
}

test "isSameModel" {
    const model1 = model_mod.Model{
        .id = "claude-sonnet-4",
        .name = "Claude Sonnet 4",
        .api_type = .anthropic,
        .provider = "anthropic",
    };
    const model2 = model_mod.Model{
        .id = "claude-sonnet-4",
        .name = "Claude Sonnet 4",
        .api_type = .anthropic,
        .provider = "anthropic",
    };
    const model3 = model_mod.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api_type = .openai,
        .provider = "openai",
    };
    const model4 = model_mod.Model{
        .id = "claude-sonnet-4",
        .name = "Claude Sonnet 4",
        .api_type = .anthropic,
        .provider = "different-provider",
    };

    try std.testing.expect(isSameModel(model1, model2));
    try std.testing.expect(!isSameModel(model1, model3));
    try std.testing.expect(!isSameModel(model1, model4));
}
