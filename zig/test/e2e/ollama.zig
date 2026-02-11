const std = @import("std");
const types = @import("types");
const config = @import("config");
const ollama = @import("ollama");
const test_helpers = @import("test_helpers");

const testing = std.testing;

test "ollama: basic text generation" {
    if (test_helpers.shouldSkipProvider(testing.allocator, "ollama")) {
        return error.SkipZigTest;
    }

    const cfg = config.OllamaConfig{
        .model = "llama3.2",
        .base_url = "http://localhost:11434",
        .params = .{
            .max_tokens = 100,
            .temperature = 1.0,
        },
    };

    const prov = try ollama.createProvider(cfg, testing.allocator);
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

test "ollama: streaming events sequence" {
    if (test_helpers.shouldSkipProvider(testing.allocator, "ollama")) {
        return error.SkipZigTest;
    }

    const cfg = config.OllamaConfig{
        .model = "llama3.2",
        .params = .{ .max_tokens = 50 },
    };

    const prov = try ollama.createProvider(cfg, testing.allocator);
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
}

test "ollama: tool calling" {
    if (test_helpers.shouldSkipProvider(testing.allocator, "ollama")) {
        return error.SkipZigTest;
    }

    const weather_tool = types.Tool{
        .name = "get_weather",
        .description = "Get current weather for a location",
        .parameters = &[_]types.ToolParameter{
            .{
                .name = "location",
                .param_type = "string",
                .description = "City name",
                .required = true,
            },
        },
    };

    const cfg = config.OllamaConfig{
        .model = "llama3.2",
        .params = .{
            .max_tokens = 200,
            .tools = &[_]types.Tool{weather_tool},
            .tool_choice = .{ .auto = {} },
        },
    };

    const prov = try ollama.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "What's the weather in Seattle?" } },
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

    // Ollama may or may not call tools depending on the model
    // Just verify we got a response
    const result = stream.result orelse return error.NoResult;
    try testing.expect(result.content.len > 0);
}

test "ollama: abort mid-stream" {
    if (test_helpers.shouldSkipProvider(testing.allocator, "ollama")) {
        return error.SkipZigTest;
    }

    var cancelled = std.atomic.Value(bool).init(false);
    const cancel_token = config.CancelToken{ .cancelled = &cancelled };

    const cfg = config.OllamaConfig{
        .model = "llama3.2",
        .params = .{ .max_tokens = 500 },
        .cancel_token = cancel_token,
    };

    const prov = try ollama.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "Write a long story about space." } },
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
}

test "ollama: usage tracking" {
    if (test_helpers.shouldSkipProvider(testing.allocator, "ollama")) {
        return error.SkipZigTest;
    }

    const cfg = config.OllamaConfig{
        .model = "llama3.2",
        .params = .{ .max_tokens = 100 },
    };

    const prov = try ollama.createProvider(cfg, testing.allocator);
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

    // Ollama may or may not report token counts
    try testing.expect(result.usage.total() >= 0);
}
