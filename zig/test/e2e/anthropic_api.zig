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

test "anthropic e2e: messages api (cheap model)" {
    const key = envOwned(testing.allocator, "ANTHROPIC_AUTH_TOKEN") orelse
                envOwned(testing.allocator, "ANTHROPIC_API_KEY") orelse {
        std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: anthropic e2e requires ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY\n", .{});
        return error.SkipZigTest;
    };
    defer testing.allocator.free(key);

    const model_id = envOwned(testing.allocator, "ANTHROPIC_MODEL") orelse try testing.allocator.dupe(u8, "claude-haiku-4-5");
    defer testing.allocator.free(model_id);

    var registry = api_registry.ApiRegistry.init(testing.allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    const model = ai_types.Model{
        .id = model_id,
        .name = model_id,
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 200_000,
        .max_tokens = 64,
    };

    const user = ai_types.Message{ .user = .{ .content = .{ .text = "Reply with: anthropic ok" }, .timestamp = std.time.timestamp() } };
    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user} };

    const stream = try stream_mod.stream(&registry, model, ctx, .{ .api_key = key, .max_tokens = 48, .temperature = 0.0 }, testing.allocator);
    defer {
        stream.deinit();
        testing.allocator.destroy(stream);
    }

    const deadline = test_helpers.createDeadline(test_helpers.DEFAULT_E2E_TIMEOUT_MS);
    while (!stream.isDone()) {
        if (test_helpers.isDeadlineExceeded(deadline)) {
            return error.TimeoutExceeded;
        }
        _ = stream.poll();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Allow detached provider thread to complete deferred cleanup
    std.Thread.sleep(50 * std.time.ns_per_ms);

    if (stream.getError()) |err| {
        std.debug.print("\nTest FAILED: anthropic e2e stream error: {s}\n", .{err});
        return error.TestFailed;
    }

    const result = stream.getResult() orelse return error.NoResult;
    try testing.expect(result.content.len > 0);
    switch (result.content[0]) {
        .text => |t| try testing.expect(t.text.len > 0),
        else => return error.ExpectedText,
    }
}
