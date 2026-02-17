const std = @import("std");
const types = @import("types");
const config = @import("config");
const anthropic = @import("anthropic");
const openai = @import("openai");
const test_helpers = @import("test_helpers");

const testing = std.testing;

test "abort: anthropic cancellation" {
    try test_helpers.skipAnthropicTest(testing.allocator);
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

    // Let some events flow with timeout
    var count: usize = 0;
    const poll_deadline = test_helpers.createDeadline(test_helpers.DEFAULT_E2E_TIMEOUT_MS);
    while (count < 3) {
        if (test_helpers.isDeadlineExceeded(poll_deadline)) {
            return error.TimeoutExceeded;
        }
        if (stream.poll()) |event| {
            test_helpers.freeEvent(event, testing.allocator);
            count += 1;
        } else {
            if (stream.completed.load(.acquire)) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Cancel and verify with timeout
    cancel_token.cancel();
    try test_helpers.waitForStreamCompletion(stream, 5000);

    try testing.expect(cancel_token.isCancelled());
}

test "abort: openai cancellation" {
    try test_helpers.skipTest(testing.allocator, "openai");
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

    // Let some events flow with timeout
    var count: usize = 0;
    const poll_deadline = test_helpers.createDeadline(test_helpers.DEFAULT_E2E_TIMEOUT_MS);
    while (count < 3) {
        if (test_helpers.isDeadlineExceeded(poll_deadline)) {
            return error.TimeoutExceeded;
        }
        if (stream.poll()) |event| {
            test_helpers.freeEvent(event, testing.allocator);
            count += 1;
        } else {
            if (stream.completed.load(.acquire)) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Cancel and verify with timeout
    cancel_token.cancel();
    try test_helpers.waitForStreamCompletion(stream, 5000);

    try testing.expect(cancel_token.isCancelled());
}

test "abort: immediate cancellation" {
    try test_helpers.skipAnthropicTest(testing.allocator);
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

    // Wait for the stream to realize it's cancelled with timeout
    try test_helpers.waitForStreamCompletion(stream, 5000);

    // Should complete quickly due to pre-cancellation
    try testing.expect(cancel_token.isCancelled());
}

test "abort: multiple cancellation calls" {
    try test_helpers.skipTest(testing.allocator, "openai");
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

    // Let some events flow with timeout
    var count: usize = 0;
    const poll_deadline = test_helpers.createDeadline(test_helpers.DEFAULT_E2E_TIMEOUT_MS);
    while (count < 2) {
        if (test_helpers.isDeadlineExceeded(poll_deadline)) {
            return error.TimeoutExceeded;
        }
        if (stream.poll()) |event| {
            test_helpers.freeEvent(event, testing.allocator);
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

    try test_helpers.waitForStreamCompletion(stream, 5000);

    try testing.expect(cancel_token.isCancelled());
}

test "abort: follow-up request after cancellation" {
    try test_helpers.skipTest(testing.allocator, "openai");
    const api_key = (try test_helpers.getApiKey(testing.allocator, "openai")).?;
    defer testing.allocator.free(api_key);

    // First request: abort mid-stream
    {
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
                .{ .text = .{ .text = "Write a story about a dragon." } },
            },
            .timestamp = std.time.timestamp(),
        };

        const stream = try prov.stream(&[_]types.Message{user_msg}, testing.allocator);
        defer {
            stream.deinit();
            testing.allocator.destroy(stream);
        }

        // Read a few events then cancel
        var count: usize = 0;
        const deadline = test_helpers.createDeadline(10000);
        while (std.time.milliTimestamp() < deadline) {
            if (stream.poll()) |event| {
                test_helpers.freeEvent(event, testing.allocator);
                count += 1;
                if (count >= 3) {
                    cancel_token.cancel();
                    break;
                }
            } else {
                if (stream.completed.load(.acquire)) break;
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }

        // Wait for stream to complete with timeout
        try test_helpers.waitForStreamCompletion(stream, 5000);
    }

    // Second request: should work normally (no resource leaks)
    {
        const cfg = config.OpenAIConfig{
            .auth = .{ .api_key = api_key },
            .model = "gpt-4o-mini",
            .params = .{ .max_tokens = 50 },
        };

        const prov = try openai.createProvider(cfg, testing.allocator);
        defer prov.deinit(testing.allocator);

        const user_msg = types.Message{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Say 'test ok'" } },
            },
            .timestamp = std.time.timestamp(),
        };

        const stream = try prov.stream(&[_]types.Message{user_msg}, testing.allocator);
        defer {
            stream.deinit();
            testing.allocator.destroy(stream);
        }

        try test_helpers.basicTextGeneration(testing.allocator, stream, 1);
    }
}
