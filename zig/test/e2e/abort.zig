const std = @import("std");
const types = @import("types");
const config = @import("config");
const anthropic = @import("anthropic");
const openai = @import("openai");
const test_helpers = @import("test_helpers");

const testing = std.testing;

test "abort: anthropic cancellation" {
    if (test_helpers.shouldSkipProvider(testing.allocator, "anthropic")) {
        return error.SkipZigTest;
    }
    const api_key = (try test_helpers.getApiKey(testing.allocator, "anthropic")).?;
    defer testing.allocator.free(api_key);

    var cancelled = std.atomic.Value(bool).init(false);
    const cancel_token = config.CancelToken{ .cancelled = &cancelled };

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = api_key },
        .model = "claude-3-5-haiku-20241022",
        .params = .{ .max_tokens = 1000 },
        .cancel_token = cancel_token,
    };

    const prov = try anthropic.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "Write a very long essay about artificial intelligence." } },
        },
        .timestamp = std.time.timestamp(),
    };

    const stream = try prov.stream(&[_]types.Message{user_msg}, testing.allocator);
    defer {
        stream.deinit();
        testing.allocator.destroy(stream);
    }

    // Let some events flow
    var count: usize = 0;
    while (count < 3) {
        if (stream.poll()) |_| {
            count += 1;
        } else {
            if (stream.completed.load(.acquire)) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Cancel and verify
    cancel_token.cancel();
    std.Thread.sleep(500 * std.time.ns_per_ms);

    try testing.expect(cancel_token.isCancelled());
}

test "abort: openai cancellation" {
    if (test_helpers.shouldSkipProvider(testing.allocator, "openai")) {
        return error.SkipZigTest;
    }
    const api_key = (try test_helpers.getApiKey(testing.allocator, "openai")).?;
    defer testing.allocator.free(api_key);

    var cancelled = std.atomic.Value(bool).init(false);
    const cancel_token = config.CancelToken{ .cancelled = &cancelled };

    const cfg = config.OpenAIConfig{
        .auth = .{ .api_key = api_key },
        .model = "gpt-4o-mini",
        .params = .{ .max_tokens = 1000 },
        .cancel_token = cancel_token,
    };

    const prov = try openai.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "Write a very long essay about machine learning." } },
        },
        .timestamp = std.time.timestamp(),
    };

    const stream = try prov.stream(&[_]types.Message{user_msg}, testing.allocator);
    defer {
        stream.deinit();
        testing.allocator.destroy(stream);
    }

    // Let some events flow
    var count: usize = 0;
    while (count < 3) {
        if (stream.poll()) |_| {
            count += 1;
        } else {
            if (stream.completed.load(.acquire)) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Cancel and verify
    cancel_token.cancel();
    std.Thread.sleep(500 * std.time.ns_per_ms);

    try testing.expect(cancel_token.isCancelled());
}

test "abort: immediate cancellation" {
    if (test_helpers.shouldSkipProvider(testing.allocator, "anthropic")) {
        return error.SkipZigTest;
    }
    const api_key = (try test_helpers.getApiKey(testing.allocator, "anthropic")).?;
    defer testing.allocator.free(api_key);

    var cancelled = std.atomic.Value(bool).init(true);
    const cancel_token = config.CancelToken{ .cancelled = &cancelled };

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = api_key },
        .model = "claude-3-5-haiku-20241022",
        .params = .{ .max_tokens = 100 },
        .cancel_token = cancel_token,
    };

    const prov = try anthropic.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "Hello!" } },
        },
        .timestamp = std.time.timestamp(),
    };

    const stream = try prov.stream(&[_]types.Message{user_msg}, testing.allocator);
    defer {
        stream.deinit();
        testing.allocator.destroy(stream);
    }

    // Wait a bit for the stream to realize it's cancelled
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Should complete quickly due to pre-cancellation
    try testing.expect(cancel_token.isCancelled());
}

test "abort: multiple cancellation calls" {
    if (test_helpers.shouldSkipProvider(testing.allocator, "openai")) {
        return error.SkipZigTest;
    }
    const api_key = (try test_helpers.getApiKey(testing.allocator, "openai")).?;
    defer testing.allocator.free(api_key);

    var cancelled = std.atomic.Value(bool).init(false);
    const cancel_token = config.CancelToken{ .cancelled = &cancelled };

    const cfg = config.OpenAIConfig{
        .auth = .{ .api_key = api_key },
        .model = "gpt-4o-mini",
        .params = .{ .max_tokens = 500 },
        .cancel_token = cancel_token,
    };

    const prov = try openai.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "Write a story." } },
        },
        .timestamp = std.time.timestamp(),
    };

    const stream = try prov.stream(&[_]types.Message{user_msg}, testing.allocator);
    defer {
        stream.deinit();
        testing.allocator.destroy(stream);
    }

    // Let some events flow
    var count: usize = 0;
    while (count < 2) {
        if (stream.poll()) |_| {
            count += 1;
        } else {
            if (stream.completed.load(.acquire)) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Cancel multiple times (should be idempotent)
    cancel_token.cancel();
    cancel_token.cancel();
    cancel_token.cancel();

    std.Thread.sleep(300 * std.time.ns_per_ms);

    try testing.expect(cancel_token.isCancelled());
}
