const std = @import("std");
const types = @import("types");
const config = @import("config");
const azure = @import("azure");
const test_helpers = @import("test_helpers");

const testing = std.testing;

fn getAzureKey(allocator: std.mem.Allocator) !?[]const u8 {
    return test_helpers.getApiKey(allocator, "azure");
}

fn getAzureResource(allocator: std.mem.Allocator) !?[]const u8 {
    if (std.process.getEnvVarOwned(allocator, "AZURE_RESOURCE_NAME")) |resource| {
        return resource;
    } else |_| {
        return null;
    }
}

test "azure: basic text generation" {
    if (test_helpers.shouldSkipProvider(testing.allocator, "azure")) {
        return error.SkipZigTest;
    }
    const api_key = (try getAzureKey(testing.allocator)).?;
    defer testing.allocator.free(api_key);

    const resource = (try getAzureResource(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(resource);

    const cfg = config.AzureConfig{
        .api_key = api_key,
        .resource_name = resource,
        .model = "gpt-4o-mini",
        .params = .{
            .max_tokens = 100,
            .temperature = 1.0,
        },
    };

    const prov = try azure.createProvider(cfg, testing.allocator);
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

test "azure: streaming events sequence" {
    if (test_helpers.shouldSkipProvider(testing.allocator, "azure")) {
        return error.SkipZigTest;
    }
    const api_key = (try getAzureKey(testing.allocator)).?;
    defer testing.allocator.free(api_key);

    const resource = (try getAzureResource(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(resource);

    const cfg = config.AzureConfig{
        .api_key = api_key,
        .resource_name = resource,
        .model = "gpt-4o-mini",
        .params = .{ .max_tokens = 50 },
    };

    const prov = try azure.createProvider(cfg, testing.allocator);
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

test "azure: reasoning mode" {
    if (test_helpers.shouldSkipProvider(testing.allocator, "azure")) {
        return error.SkipZigTest;
    }
    const api_key = (try getAzureKey(testing.allocator)).?;
    defer testing.allocator.free(api_key);

    const resource = (try getAzureResource(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(resource);

    const cfg = config.AzureConfig{
        .api_key = api_key,
        .resource_name = resource,
        .model = "o3-mini",
        .reasoning_effort = .medium,
        .params = .{ .max_tokens = 300 },
    };

    const prov = try azure.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "What is 19 * 23? Show your work." } },
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

test "azure: tool calling" {
    if (test_helpers.shouldSkipProvider(testing.allocator, "azure")) {
        return error.SkipZigTest;
    }
    const api_key = (try getAzureKey(testing.allocator)).?;
    defer testing.allocator.free(api_key);

    const resource = (try getAzureResource(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(resource);

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

    const cfg = config.AzureConfig{
        .api_key = api_key,
        .resource_name = resource,
        .model = "gpt-4o-mini",
        .params = .{
            .max_tokens = 200,
            .tools = &[_]types.Tool{weather_tool},
            .tool_choice = .{ .auto = {} },
        },
    };

    const prov = try azure.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "What's the weather in London?" } },
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

test "azure: abort mid-stream" {
    if (test_helpers.shouldSkipProvider(testing.allocator, "azure")) {
        return error.SkipZigTest;
    }
    const api_key = (try getAzureKey(testing.allocator)).?;
    defer testing.allocator.free(api_key);

    const resource = (try getAzureResource(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(resource);

    var cancelled = std.atomic.Value(bool).init(false);
    const cancel_token = config.CancelToken{ .cancelled = &cancelled };

    const cfg = config.AzureConfig{
        .api_key = api_key,
        .resource_name = resource,
        .model = "gpt-4o-mini",
        .params = .{ .max_tokens = 500 },
        .cancel_token = cancel_token,
    };

    const prov = try azure.createProvider(cfg, testing.allocator);
    defer prov.deinit(testing.allocator);

    const user_msg = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = .{ .text = "Write a long story about a wizard." } },
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

test "azure: usage tracking" {
    if (test_helpers.shouldSkipProvider(testing.allocator, "azure")) {
        return error.SkipZigTest;
    }
    const api_key = (try getAzureKey(testing.allocator)).?;
    defer testing.allocator.free(api_key);

    const resource = (try getAzureResource(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(resource);

    const cfg = config.AzureConfig{
        .api_key = api_key,
        .resource_name = resource,
        .model = "gpt-4o-mini",
        .params = .{ .max_tokens = 100 },
    };

    const prov = try azure.createProvider(cfg, testing.allocator);
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
