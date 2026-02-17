//! Token estimation utilities for predicting API usage.
//!
//! Provides heuristic-based token counting to help users validate
//! context limits before making API calls.

const std = @import("std");
const ai_types = @import("ai_types");

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
pub fn estimateTokens(messages: []const ai_types.Message) usize {
    var total: usize = 0;

    for (messages) |msg| {
        // Role overhead (~5 tokens per message)
        total += 5;

        switch (msg) {
            .user => |user_msg| {
                switch (user_msg.content) {
                    .text => |t| {
                        total += t.len / 4;
                    },
                    .parts => |parts| {
                        for (parts) |part| {
                            switch (part) {
                                .text => |t| {
                                    total += t.text.len / 4;
                                },
                                .image => {
                                    total += 850; // Approximate for image tokens
                                },
                            }
                        }
                    },
                }
            },
            .assistant => |assistant_msg| {
                for (assistant_msg.content) |content| {
                    switch (content) {
                        .text => |t| {
                            total += t.text.len / 4;
                        },
                        .tool_call => |tc| {
                            total += tc.arguments_json.len / 4 + 50; // JSON overhead
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
            },
            .tool_result => |tool_result_msg| {
                for (tool_result_msg.content) |part| {
                    switch (part) {
                        .text => |t| {
                            total += t.text.len / 4;
                        },
                        .image => {
                            total += 850;
                        },
                    }
                }
                // Tool call metadata
                total += tool_result_msg.tool_call_id.len / 4;
                total += tool_result_msg.tool_name.len / 4;
            },
        }
    }

    return total;
}

test "token estimation - user message with text" {
    const msg = ai_types.Message{ .user = .{
        .content = .{ .text = "Hello, world!" },
        .timestamp = 1000,
    } };

    const estimated = estimateTokens(&[_]ai_types.Message{msg});
    // 5 role overhead + ~3 content = ~8 tokens
    try std.testing.expect(estimated > 5 and estimated < 15);
}

test "token estimation - assistant message with multiple content blocks" {
    const content = [_]ai_types.AssistantContent{
        .{ .text = .{ .text = "First block of text here." } },
        .{ .tool_call = .{
            .id = "call_123",
            .name = "get_weather",
            .arguments_json = "{\"location\": \"San Francisco\"}",
        } },
    };
    const msg = ai_types.Message{ .assistant = .{
        .content = &content,
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 1000,
    } };

    const estimated = estimateTokens(&[_]ai_types.Message{msg});
    // Should account for text + tool call + JSON overhead
    try std.testing.expect(estimated > 20);
}

test "token estimation - user message with image" {
    const parts = [_]ai_types.UserContentPart{
        .{ .image = .{ .data = "base64data", .mime_type = "image/png" } },
    };
    const msg = ai_types.Message{ .user = .{
        .content = .{ .parts = &parts },
        .timestamp = 1000,
    } };

    const estimated = estimateTokens(&[_]ai_types.Message{msg});
    // 5 role + 850 image = 855
    try std.testing.expect(estimated > 850 and estimated < 900);
}

test "token estimation - conversation with tool result" {
    const assistant_content = [_]ai_types.AssistantContent{
        .{ .tool_call = .{
            .id = "call_1",
            .name = "get_weather",
            .arguments_json = "{\"location\": \"SF\"}",
        } },
    };
    const tool_result_content = [_]ai_types.UserContentPart{
        .{ .text = .{ .text = "72°F, sunny" } },
    };
    const messages = [_]ai_types.Message{
        .{ .user = .{
            .content = .{ .text = "What's the weather?" },
            .timestamp = 1000,
        } },
        .{ .assistant = .{
            .content = &assistant_content,
            .api = "test-api",
            .provider = "test-provider",
            .model = "test-model",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 1001,
        } },
        .{ .tool_result = .{
            .tool_call_id = "call_1",
            .tool_name = "get_weather",
            .content = &tool_result_content,
            .is_error = false,
            .timestamp = 1002,
        } },
    };

    const estimated = estimateTokens(&messages);
    // 3 messages * 5 overhead + content = should be > 30
    try std.testing.expect(estimated > 30);
}
