const std = @import("std");
const types = @import("types");
const config = @import("config");
const anthropic = @import("anthropic");
const test_helpers = @import("test_helpers");

const testing = std.testing;

test "anthropic_oauth: basic text generation" {
    try test_helpers.skipAnthropicOAuthTest(testing.allocator);
    var creds = (try test_helpers.getAnthropicOAuthCredentials(testing.allocator)).?;
    defer creds.deinit(testing.allocator);

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = creds.access_token },
        .model = "claude-3-5-haiku-20241022",
        .params = .{
            .max_tokens = 100,
            .temperature = 1.0,
        },
    };

    const prov = try anthropic.createProvider(cfg, testing.allocator);
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

test "anthropic_oauth: streaming events sequence" {
    try test_helpers.skipAnthropicOAuthTest(testing.allocator);
    var creds = (try test_helpers.getAnthropicOAuthCredentials(testing.allocator)).?;
    defer creds.deinit(testing.allocator);

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = creds.access_token },
        .model = "claude-3-5-haiku-20241022",
        .params = .{ .max_tokens = 50 },
    };

    const prov = try anthropic.createProvider(cfg, testing.allocator);
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
    var saw_text_start = false;
    var saw_text_delta = false;
    var saw_done = false;

    while (true) {
        if (stream.poll()) |event| {
            try accumulator.processEvent(event);

            switch (event) {
                .start => saw_start = true,
                .text_start => saw_text_start = true,
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
    try testing.expect(saw_text_start);
    try testing.expect(saw_text_delta);
    try testing.expect(saw_done);
    try testing.expect(accumulator.text_buffer.items.len > 0);
}

test "anthropic_oauth: usage tracking" {
    try test_helpers.skipAnthropicOAuthTest(testing.allocator);
    var creds = (try test_helpers.getAnthropicOAuthCredentials(testing.allocator)).?;
    defer creds.deinit(testing.allocator);

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = creds.access_token },
        .model = "claude-3-5-haiku-20241022",
        .params = .{ .max_tokens = 100 },
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
}
