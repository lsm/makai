const std = @import("std");
const types = @import("types");
const config = @import("config");
const anthropic = @import("anthropic");
const openai = @import("openai");
const test_helpers = @import("test_helpers");

const testing = std.testing;

test "unicode: anthropic handles emoji" {
    try test_helpers.skipAnthropicTest(testing.allocator);
    const api_key = (try test_helpers.getApiKey(testing.allocator, "anthropic")).?;
    defer testing.allocator.free(api_key);

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = api_key },
        .model = "claude-3-5-haiku-20241022",
        .params = .{ .max_tokens = 100 },
    };

    const prov = try anthropic.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "Respond with a greeting using emoji: 👋 🌍" } },
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

test "unicode: openai handles CJK characters" {
    try test_helpers.skipTest(testing.allocator, "openai");
    const api_key = (try test_helpers.getApiKey(testing.allocator, "openai")).?;
    defer testing.allocator.free(api_key);

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
            .{ .text = .{ .text = "你好！请用中文回复。" } },
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

test "unicode: mixed scripts and symbols" {
    try test_helpers.skipAnthropicTest(testing.allocator);
    const api_key = (try test_helpers.getApiKey(testing.allocator, "anthropic")).?;
    defer testing.allocator.free(api_key);

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = api_key },
        .model = "claude-3-5-haiku-20241022",
        .params = .{ .max_tokens = 100 },
    };

    const prov = try anthropic.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "Hello мир 世界 🌎 α β γ ♠ ♣ ♥ ♦" } },
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

test "unicode: zero-width and control characters" {
    try test_helpers.skipTest(testing.allocator, "openai");
    const api_key = (try test_helpers.getApiKey(testing.allocator, "openai")).?;
    defer testing.allocator.free(api_key);

    const cfg = config.OpenAIConfig{
        .auth = .{ .api_key = api_key },
        .model = "gpt-4o-mini",
        .params = .{ .max_tokens = 100 },
    };

    const prov = try openai.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    // Text with zero-width joiner and other special Unicode
    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "Hello\u{200D}World\u{FEFF}Test" } },
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

test "unicode: right-to-left text" {
    try test_helpers.skipAnthropicTest(testing.allocator);
    const api_key = (try test_helpers.getApiKey(testing.allocator, "anthropic")).?;
    defer testing.allocator.free(api_key);

    const cfg = config.AnthropicConfig{
        .auth = .{ .api_key = api_key },
        .model = "claude-3-5-haiku-20241022",
        .params = .{ .max_tokens = 100 },
    };

    const prov = try anthropic.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "Respond to: مرحبا بك (Arabic greeting)" } },
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
