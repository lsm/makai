const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const register_builtins = @import("register_builtins");
const stream_mod = @import("stream");
const test_helpers = @import("test_helpers");

const testing = std.testing;

fn envOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

fn waitResultOrFail(stream: *ai_types.AssistantMessageEventStream) !ai_types.AssistantMessage {
    const deadline = test_helpers.createDeadline(test_helpers.DEFAULT_E2E_TIMEOUT_MS);
    while (!stream.isDone()) {
        if (test_helpers.isDeadlineExceeded(deadline)) {
            return error.TimeoutExceeded;
        }
        _ = stream.poll();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Small delay to allow detached provider thread to fully exit and free resources
    std.Thread.sleep(50 * std.time.ns_per_ms);

    if (stream.getError()) |err| {
        std.debug.print("\nTest FAILED: openai e2e stream error: {s}\n", .{err});
        return error.TestFailed;
    }

    return ai_types.cloneAssistantMessage(testing.allocator, stream.getResult() orelse return error.NoResult);
}

test "openai e2e: chat completions (cheap model)" {
    const key = envOwned(testing.allocator, "OPENAI_API_KEY") orelse {
        std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: openai e2e requires OPENAI_API_KEY\n", .{});
        return error.SkipZigTest;
    };
    defer testing.allocator.free(key);

    const model_id = envOwned(testing.allocator, "OPENAI_MODEL") orelse try testing.allocator.dupe(u8, "gpt-4o-mini");
    defer testing.allocator.free(model_id);

    var registry = api_registry.ApiRegistry.init(testing.allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    const model = ai_types.Model{
        .id = model_id,
        .name = model_id,
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 48,
    };

    const user = ai_types.Message{ .user = .{ .content = .{ .text = "Reply with: openai ok" }, .timestamp = std.time.timestamp() } };
    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user} };

    const stream = try stream_mod.stream(&registry, model, ctx, .{ .api_key = key, .max_tokens = 48, .temperature = 0.0 }, testing.allocator);
    defer {
        stream.deinit();
        testing.allocator.destroy(stream);
    }

    var result = try waitResultOrFail(stream);
    defer ai_types.deinitAssistantMessageOwned(testing.allocator, &result);

    try testing.expect(result.content.len > 0);
    switch (result.content[0]) {
        .text => |t| try testing.expect(t.text.len > 0),
        else => return error.ExpectedText,
    }
}

test "openai e2e: responses api (cheap model)" {
    const key = envOwned(testing.allocator, "OPENAI_API_KEY") orelse {
        std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: openai responses e2e requires OPENAI_API_KEY\n", .{});
        return error.SkipZigTest;
    };
    defer testing.allocator.free(key);

    const model_id = envOwned(testing.allocator, "OPENAI_RESPONSES_MODEL") orelse try testing.allocator.dupe(u8, "gpt-4o-mini");
    defer testing.allocator.free(model_id);

    var registry = api_registry.ApiRegistry.init(testing.allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    const model = ai_types.Model{
        .id = model_id,
        .name = model_id,
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 48,
    };

    const user = ai_types.Message{ .user = .{ .content = .{ .text = "Reply with: responses ok" }, .timestamp = std.time.timestamp() } };
    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user} };

    const stream = try stream_mod.stream(&registry, model, ctx, .{ .api_key = key, .max_tokens = 48, .temperature = 0.0 }, testing.allocator);
    defer {
        stream.deinit();
        testing.allocator.destroy(stream);
    }

    var result = try waitResultOrFail(stream);
    defer ai_types.deinitAssistantMessageOwned(testing.allocator, &result);

    try testing.expect(result.content.len > 0);
    switch (result.content[0]) {
        .text => |t| try testing.expect(t.text.len > 0),
        else => return error.ExpectedText,
    }
}
