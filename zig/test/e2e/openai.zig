const std = @import("std");
const types = @import("types");
const config = @import("config");
const openai = @import("openai");
const test_helpers = @import("test_helpers");

const testing = std.testing;

test "openai: basic text generation" {
    test_helpers.testStart("openai: basic text generation");
    defer test_helpers.testSuccess("openai: basic text generation");

    try test_helpers.skipTest(testing.allocator, "openai");
    const api_key = (try test_helpers.getApiKey(testing.allocator, "openai")).?;
    defer testing.allocator.free(api_key);

    test_helpers.testStep("Creating provider with gpt-4o-mini...", .{});

    const cfg = config.OpenAIConfig{
        .auth = .{ .api_key = api_key },
        .model = "gpt-4o-mini",
        .params = .{
            .max_tokens = 100,
            .temperature = 1.0,
        },
    };

    const prov = try openai.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "Say 'Hello from Zig!' in a friendly way." } },
        },
        .timestamp = std.time.timestamp(),
    };

    const stream = try prov.stream(&[_]types.Message{user_msg}, testing.allocator);
    defer {
        stream.deinit();
        testing.allocator.destroy(stream);
    }

    try test_helpers.basicTextGeneration(testing.allocator, stream, 5);
}

test "openai: streaming events sequence" {
    test_helpers.testStart("openai: streaming events sequence");
    defer test_helpers.testSuccess("openai: streaming events sequence");

    try test_helpers.skipTest(testing.allocator, "openai");
    const api_key = (try test_helpers.getApiKey(testing.allocator, "openai")).?;
    defer testing.allocator.free(api_key);

    test_helpers.testStep("Testing event sequence (start, text_delta, done)...", .{});

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
            .{ .text = .{ .text = "Count to 3." } },
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

    var saw_start = false;
    var saw_text_delta = false;
    var saw_done = false;

    while (true) {
        if (stream.poll()) |event| {
            try accumulator.processEvent(event);

            switch (event) {
                .start => saw_start = true,
                .text_delta => saw_text_delta = true,
                .done => saw_done = true,
                else => {},
            }
        } else {
            if (stream.completed.load(.acquire)) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    try testing.expect(saw_start);
    try testing.expect(saw_text_delta);
    try testing.expect(saw_done);
    try testing.expect(accumulator.text_buffer.items.len > 0);
    test_helpers.testStep("All expected events received, {} chars of text", .{accumulator.text_buffer.items.len});
}

test "openai: reasoning mode" {
    test_helpers.testStart("openai: reasoning mode");
    // OpenAI's reasoning models (o1, o3, o4) don't emit thinking events in the stream.
    // The extended thinking happens server-side and only the final answer is returned.
    // This is unlike Anthropic Claude which emits thinking_start/thinking_delta events.
    // Skip this test since it will never pass with OpenAI's API.
    std.debug.print("\n\x1b[33mSKIPPED\x1b[0m: openai: reasoning mode - OpenAI doesn't emit thinking events\n", .{});
    return error.SkipZigTest;
}

test "openai: tool calling" {
    test_helpers.testStart("openai: tool calling");
    // Non-deterministic: Models may choose to respond with text instead of calling tools.
    // The tool calling implementation is verified by unit tests in openai.zig
    // that mock SSE events with tool_calls data.
    std.debug.print("\n\x1b[33mSKIPPED\x1b[0m: openai: tool calling - non-deterministic test\n", .{});
    return error.SkipZigTest;
}

test "openai: abort mid-stream" {
    test_helpers.testStart("openai: abort mid-stream");
    defer test_helpers.testSuccess("openai: abort mid-stream");

    try test_helpers.skipTest(testing.allocator, "openai");
    const api_key = (try test_helpers.getApiKey(testing.allocator, "openai")).?;
    defer testing.allocator.free(api_key);

    test_helpers.testStep("Testing stream cancellation after 5 events...", .{});

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
            .{ .text = .{ .text = "Write a long story about a dragon." } },
        },
        .timestamp = std.time.timestamp(),
    };

    const stream = try prov.stream(&[_]types.Message{user_msg}, testing.allocator);
    defer {
        stream.deinit();
        testing.allocator.destroy(stream);
    }

    var event_count: usize = 0;
    const max_events = 5;

    while (true) {
        if (stream.poll()) |event| {
            test_helpers.freeEvent(event, testing.allocator);
            event_count += 1;
            if (event_count >= max_events) {
                cancel_token.cancel();
                break;
            }
        } else {
            if (stream.completed.load(.acquire)) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    std.Thread.sleep(500 * std.time.ns_per_ms);

    try testing.expect(event_count >= max_events);
    try testing.expect(cancel_token.isCancelled());
    test_helpers.testStep("Cancelled after {} events", .{event_count});
}

test "openai: usage tracking" {
    test_helpers.testStart("openai: usage tracking");
    defer test_helpers.testSuccess("openai: usage tracking");

    try test_helpers.skipTest(testing.allocator, "openai");
    const api_key = (try test_helpers.getApiKey(testing.allocator, "openai")).?;
    defer testing.allocator.free(api_key);

    test_helpers.testStep("Testing token usage tracking...", .{});

    const cfg = config.OpenAIConfig{
        .auth = .{ .api_key = api_key },
        .model = "gpt-4o-mini",
        .params = .{ .max_tokens = 100 },
    };

    const prov = try openai.createProvider(cfg, testing.allocator);
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

    while (!stream.completed.load(.acquire)) {
        if (stream.poll()) |event| {
            test_helpers.freeEvent(event, testing.allocator);
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    const result = stream.result orelse return error.NoResult;

    try testing.expect(result.usage.input_tokens > 0);
    try testing.expect(result.usage.output_tokens > 0);
    try testing.expect(result.usage.total() > 0);
    test_helpers.testStep("Usage: input={}, output={}, total={}", .{
        result.usage.input_tokens,
        result.usage.output_tokens,
        result.usage.total(),
    });
}
