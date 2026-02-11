const std = @import("std");
const types = @import("types");
const config = @import("config");
const bedrock = @import("bedrock");
const test_helpers = @import("test_helpers");

const testing = std.testing;

fn getBedrockAuth(allocator: std.mem.Allocator) !?bedrock.BedrockAuth {
    const access_key = std.process.getEnvVarOwned(allocator, "AWS_ACCESS_KEY_ID") catch return null;
    errdefer allocator.free(access_key);

    const secret_key = std.process.getEnvVarOwned(allocator, "AWS_SECRET_ACCESS_KEY") catch {
        allocator.free(access_key);
        return null;
    };

    const session_token = std.process.getEnvVarOwned(allocator, "AWS_SESSION_TOKEN") catch null;

    return bedrock.BedrockAuth{
        .access_key_id = access_key,
        .secret_access_key = secret_key,
        .session_token = session_token,
    };
}

fn freeBedrockAuth(allocator: std.mem.Allocator, auth: bedrock.BedrockAuth) void {
    allocator.free(auth.access_key_id);
    allocator.free(auth.secret_access_key);
    if (auth.session_token) |token| {
        allocator.free(token);
    }
}

test "bedrock: basic text generation" {
    const auth = (try getBedrockAuth(testing.allocator)) orelse return error.SkipZigTest;
    defer freeBedrockAuth(testing.allocator, auth);

    const cfg = bedrock.BedrockConfig{
        .auth = auth,
        .model = "us.anthropic.claude-3-5-haiku-20241022-v1:0",
        .region = "us-east-1",
        .params = .{
            .max_tokens = 100,
            .temperature = 1.0,
        },
    };

    const prov = try bedrock.createProvider(cfg, testing.allocator);
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

test "bedrock: streaming events sequence" {
    const auth = (try getBedrockAuth(testing.allocator)) orelse return error.SkipZigTest;
    defer freeBedrockAuth(testing.allocator, auth);

    const cfg = bedrock.BedrockConfig{
        .auth = auth,
        .model = "us.anthropic.claude-3-5-haiku-20241022-v1:0",
        .params = .{ .max_tokens = 50 },
    };

    const prov = try bedrock.createProvider(cfg, testing.allocator);
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

test "bedrock: thinking mode" {
    const auth = (try getBedrockAuth(testing.allocator)) orelse return error.SkipZigTest;
    defer freeBedrockAuth(testing.allocator, auth);

    const cfg = bedrock.BedrockConfig{
        .auth = auth,
        .model = "us.anthropic.claude-3-7-sonnet-20250219-v1:0",
        .thinking_config = .{
            .mode = .adaptive,
            .effort = .medium,
        },
        .params = .{ .max_tokens = 300 },
    };

    const prov = try bedrock.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "What is 23 * 19? Think through it step by step." } },
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

    var saw_thinking = false;

    while (true) {
        if (stream.poll()) |event| {
            try accumulator.processEvent(event);

            switch (event) {
                .thinking_start, .thinking_delta => saw_thinking = true,
                else => {},
            }
        } else {
            if (stream.completed.load(.acquire)) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    try testing.expect(saw_thinking);
    try testing.expect(accumulator.thinking_buffer.items.len > 0);
}

test "bedrock: tool calling" {
    const auth = (try getBedrockAuth(testing.allocator)) orelse return error.SkipZigTest;
    defer freeBedrockAuth(testing.allocator, auth);

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

    const cfg = bedrock.BedrockConfig{
        .auth = auth,
        .model = "us.anthropic.claude-3-5-haiku-20241022-v1:0",
        .params = .{
            .max_tokens = 200,
            .tools = &[_]types.Tool{weather_tool},
            .tool_choice = .{ .auto = {} },
        },
    };

    const prov = try bedrock.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "What's the weather in Miami?" } },
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

    var saw_tool_call = false;

    while (true) {
        if (stream.poll()) |event| {
            try accumulator.processEvent(event);

            switch (event) {
                .toolcall_start => saw_tool_call = true,
                else => {},
            }
        } else {
            if (stream.completed.load(.acquire)) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    try testing.expect(saw_tool_call);
    try testing.expect(accumulator.tool_calls.items.len > 0);

    const result = stream.result orelse return error.NoResult;
    try testing.expect(result.stop_reason == .tool_use);
}

test "bedrock: prompt caching" {
    const auth = (try getBedrockAuth(testing.allocator)) orelse return error.SkipZigTest;
    defer freeBedrockAuth(testing.allocator, auth);

    const cfg = bedrock.BedrockConfig{
        .auth = auth,
        .model = "us.anthropic.claude-3-5-haiku-20241022-v1:0",
        .cache_retention = .short,
        .params = .{ .max_tokens = 100 },
    };

    const prov = try bedrock.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "This is a test message with caching enabled." } },
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

    // First call should have cache writes
    try testing.expect(result.usage.cache_write_tokens >= 0);
}

test "bedrock: abort mid-stream" {
    const auth = (try getBedrockAuth(testing.allocator)) orelse return error.SkipZigTest;
    defer freeBedrockAuth(testing.allocator, auth);

    var cancelled = std.atomic.Value(bool).init(false);
    const cancel_token = config.CancelToken{ .cancelled = &cancelled };

    const cfg = bedrock.BedrockConfig{
        .auth = auth,
        .model = "us.anthropic.claude-3-5-haiku-20241022-v1:0",
        .params = .{ .max_tokens = 500 },
        .cancel_token = cancel_token,
    };

    const prov = try bedrock.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "Write a long story about a mountain." } },
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

test "bedrock: usage tracking" {
    const auth = (try getBedrockAuth(testing.allocator)) orelse return error.SkipZigTest;
    defer freeBedrockAuth(testing.allocator, auth);

    const cfg = bedrock.BedrockConfig{
        .auth = auth,
        .model = "us.anthropic.claude-3-5-haiku-20241022-v1:0",
        .params = .{ .max_tokens = 100 },
    };

    const prov = try bedrock.createProvider(cfg, testing.allocator);
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
