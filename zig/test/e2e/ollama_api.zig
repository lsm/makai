const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const register_builtins = @import("register_builtins");
const stream_mod = @import("stream");

const testing = std.testing;

fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

test "ollama e2e: basic text generation (new api)" {
    const api_key = getEnvOwned(testing.allocator, "OLLAMA_API_KEY") orelse {
        std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: ollama e2e requires OLLAMA_API_KEY\n", .{});
        return error.SkipZigTest;
    };
    defer testing.allocator.free(api_key);

    const model_id = getEnvOwned(testing.allocator, "OLLAMA_MODEL") orelse try testing.allocator.dupe(u8, "llama3.2:1b");
    defer testing.allocator.free(model_id);

    const base_url = getEnvOwned(testing.allocator, "OLLAMA_BASE_URL") orelse try testing.allocator.dupe(u8, "");
    defer testing.allocator.free(base_url);

    var registry = api_registry.ApiRegistry.init(testing.allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    const model = ai_types.Model{
        .id = model_id,
        .name = model_id,
        .api = "ollama",
        .provider = "ollama",
        .base_url = base_url,
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 131_072,
        .max_tokens = 48,
    };

    const user_msg = ai_types.Message{ .user = .{
        .content = .{ .text = "Reply with exactly: tiny ollama ok" },
        .timestamp = std.time.timestamp(),
    } };

    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user_msg} };

    const stream = try stream_mod.stream(&registry, model, ctx, .{
        .api_key = api_key,
        .max_tokens = 48,
        .temperature = 0.0,
    }, testing.allocator);
    defer {
        stream.deinit();
        testing.allocator.destroy(stream);
    }

    while (!stream.isDone()) {
        _ = stream.poll();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    if (stream.getError()) |err| {
        std.debug.print("\nTest FAILED: ollama e2e stream error: {s}\n", .{err});
        return error.TestFailed;
    }

    const result = stream.getResult() orelse return error.NoResult;
    try testing.expect(result.content.len > 0);

    switch (result.content[0]) {
        .text => |t| try testing.expect(t.text.len > 0),
        else => return error.ExpectedText,
    }
}
