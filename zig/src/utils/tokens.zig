//! Token estimation utilities for predicting API usage.
//!
//! Provides heuristic-based token counting to help users validate
//! context limits before making API calls.

const std = @import("std");
const types = @import("types");

/// Estimates token count for a list of messages using simple heuristic.
///
/// Approximation rules:
/// - ~4 characters per token (English text)
/// - ~5 tokens overhead per message (role, formatting)
/// - ~850 tokens per image
/// - JSON overhead for tool calls
///
/// For accurate counts, use provider-specific tokenization APIs.
/// This is intentionally conservative to avoid underestimating.
pub fn estimateTokens(messages: []const types.Message) usize {
    var total: usize = 0;

    for (messages) |msg| {
        // Role overhead (~5 tokens per message)
        total += 5;

        for (msg.content) |block| {
            switch (block) {
                .text => |t| {
                    total += t.text.len / 4; // ~4 chars/token
                },
                .tool_use => |tc| {
                    total += tc.input_json.len / 4 + 50; // JSON overhead
                    total += tc.name.len / 4;
                    total += tc.id.len / 4;
                },
                .thinking => |th| {
                    total += th.thinking.len / 4;
                },
                .image => {
                    total += 850; // Approximate for image tokens
                },
            }
        }

        // Tool call metadata
        if (msg.tool_call_id) |id| total += id.len / 4;
        if (msg.tool_name) |name| total += name.len / 4;
    }

    return total;
}

test "token estimation - simple message" {
    const msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "Hello, world!" } }, // ~3 tokens
        },
        .timestamp = 1000,
    };

    const estimated = estimateTokens(&[_]types.Message{msg});
    // 5 role overhead + ~3 content = ~8 tokens
    try std.testing.expect(estimated > 5 and estimated < 15);
}

test "token estimation - multiple content blocks" {
    const msg = types.Message{
        .role = .assistant,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "First block of text here." } },
            .{ .tool_use = .{
                .id = "call_123",
                .name = "get_weather",
                .input_json = "{\"location\": \"San Francisco\"}",
            } },
        },
        .timestamp = 1000,
    };

    const estimated = estimateTokens(&[_]types.Message{msg});
    // Should account for text + tool call + JSON overhead
    try std.testing.expect(estimated > 20);
}

test "token estimation - image" {
    const msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .image = .{
                .media_type = "image/png",
                .data = "base64data",
            } },
        },
        .timestamp = 1000,
    };

    const estimated = estimateTokens(&[_]types.Message{msg});
    // 5 role + 850 image = 855
    try std.testing.expect(estimated > 850 and estimated < 900);
}

test "token estimation - conversation" {
    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "What's the weather?" } },
            },
            .timestamp = 1000,
        },
        .{
            .role = .assistant,
            .content = &[_]types.ContentBlock{
                .{ .tool_use = .{
                    .id = "call_1",
                    .name = "get_weather",
                    .input_json = "{\"location\": \"SF\"}",
                } },
            },
            .timestamp = 1001,
        },
        .{
            .role = .tool_result,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "72°F, sunny" } },
            },
            .tool_call_id = "call_1",
            .timestamp = 1002,
        },
    };

    const estimated = estimateTokens(&messages);
    // 3 messages * 5 overhead + content = should be > 30
    try std.testing.expect(estimated > 30);
}
