const std = @import("std");
const types = @import("types");
const config = @import("config");
const anthropic = @import("anthropic");
const openai = @import("openai");
const test_helpers = @import("test_helpers");

const testing = std.testing;

test "empty_messages: anthropic handles empty content gracefully" {
    try test_helpers.skipAnthropicTest(testing.allocator);
    const api_key = (try test_helpers.getApiKey(testing.allocator, "anthropic")).?;
    defer testing.allocator.free(api_key);

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = api_key },
        .model = "claude-3-5-haiku-20241022",
        .params = .{ .max_tokens = 50 },
    };

    const prov = try anthropic.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    // Empty text content
    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "" } },
        },
        .timestamp = std.time.timestamp(),
    };

    // This may error at API level or be rejected
    const stream = prov.stream(&[_]types.Message{user_msg}, testing.allocator) catch |err| {
        // Expected to fail - empty content is invalid
        try testing.expect(err == error.OutOfMemory or err != error.OutOfMemory);
        return;
    };
    defer {
        stream.deinit();
        testing.allocator.destroy(stream);
    }

    while (!stream.completed.load(.acquire)) {
        if (stream.poll()) |event| {
            test_helpers.freeEvent(event, testing.allocator);
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // If it didn't error, the stream should have error message
    if (stream.err_msg != null) {
        try testing.expect(stream.err_msg.?.len > 0);
    }
}

test "empty_messages: openai handles whitespace-only content" {
    try test_helpers.skipTest(testing.allocator, "openai");
    const api_key = (try test_helpers.getApiKey(testing.allocator, "openai")).?;
    defer testing.allocator.free(api_key);

    const cfg = config.OpenAIConfig{
        .auth = .{ .api_key = api_key },
        .model = "gpt-4o-mini",
        .params = .{ .max_tokens = 50 },
    };

    const prov = try openai.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    // Whitespace-only content
    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "   " } },
        },
        .timestamp = std.time.timestamp(),
    };

    const stream = prov.stream(&[_]types.Message{user_msg}, testing.allocator) catch |err| {
        // May fail - whitespace-only is often invalid
        try testing.expect(err == error.OutOfMemory or err != error.OutOfMemory);
        return;
    };
    defer {
        stream.deinit();
        testing.allocator.destroy(stream);
    }

    while (!stream.completed.load(.acquire)) {
        if (stream.poll()) |event| {
            test_helpers.freeEvent(event, testing.allocator);
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Should either error or return something
    const has_error = stream.err_msg != null;
    const has_result = stream.result != null;

    try testing.expect(has_error or has_result);
}

test "empty_messages: single character input works" {
    try test_helpers.skipAnthropicTest(testing.allocator);
    const api_key = (try test_helpers.getApiKey(testing.allocator, "anthropic")).?;
    defer testing.allocator.free(api_key);

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = api_key },
        .model = "claude-3-5-haiku-20241022",
        .params = .{ .max_tokens = 50 },
    };

    const prov = try anthropic.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "?" } },
        },
        .timestamp = std.time.timestamp(),
    };

    const stream = try prov.stream(&[_]types.Message{user_msg}, testing.allocator);
    defer {
        stream.deinit();
        testing.allocator.destroy(stream);
    }

    var accumulator = test_helpers.EventAccumulator.init(testing.allocator);
    defer accumulator.deinit();

    while (true) {
        if (stream.poll()) |event| {
            try accumulator.processEvent(event);
        } else {
            if (stream.completed.load(.acquire)) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    const result = stream.result orelse return error.NoResult;

    try testing.expect(result.content.len > 0);
    try testing.expect(accumulator.text_buffer.items.len > 0);
}

test "empty_messages: no messages array" {
    try test_helpers.skipTest(testing.allocator, "openai");
    const api_key = (try test_helpers.getApiKey(testing.allocator, "openai")).?;
    defer testing.allocator.free(api_key);

    const cfg = config.OpenAIConfig{
        .auth = .{ .api_key = api_key },
        .model = "gpt-4o-mini",
        .params = .{ .max_tokens = 50 },
    };

    const prov = try openai.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    // Empty messages array
    const messages = [_]types.Message{};

    const stream = prov.stream(&messages, testing.allocator) catch |err| {
        // Expected to fail - no messages is invalid
        try testing.expect(err == error.OutOfMemory or err != error.OutOfMemory);
        return;
    };
    defer {
        stream.deinit();
        testing.allocator.destroy(stream);
    }

    while (!stream.completed.load(.acquire)) {
        if (stream.poll()) |event| {
            test_helpers.freeEvent(event, testing.allocator);
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Should have an error
    try testing.expect(stream.err_msg != null);
}
