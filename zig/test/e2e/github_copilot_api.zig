const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const register_builtins = @import("register_builtins");
const stream_mod = @import("stream");
const test_helpers = @import("test_helpers");

const testing = std.testing;

test "github_copilot e2e: basic text generation" {
    // Check for GitHub Copilot credentials
    try test_helpers.skipGitHubCopilotTest(testing.allocator);

    var creds = (try test_helpers.getFreshGitHubCopilotCredentials(testing.allocator)) orelse return error.SkipZigTest;
    defer creds.deinit(testing.allocator);

    // Use base_url from token, or fall back to default
    const base_url = creds.base_url orelse "https://api.individual.githubcopilot.com";

    var registry = api_registry.ApiRegistry.init(testing.allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    const model = ai_types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api = "openai-completions",
        .provider = "github-copilot",
        .base_url = base_url,
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 50,
    };

    const user_msg = ai_types.Message{ .user = .{
        .content = .{ .text = "Reply with exactly: hello world" },
        .timestamp = std.time.timestamp(),
    } };

    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user_msg} };

    const stream = try stream_mod.stream(&registry, model, ctx, .{
        .api_key = ai_types.OwnedSlice(u8).initBorrowed(creds.copilot_token),
        .max_tokens = 50,
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

    // Allow detached provider thread to complete deferred cleanup
    std.Thread.sleep(50 * std.time.ns_per_ms);

    if (stream.getError()) |err| {
        std.debug.print("\nTest FAILED: github_copilot e2e stream error: {s}\n", .{err});
        return error.TestFailed;
    }

    const result = stream.getResult() orelse return error.NoResult;
    try testing.expect(result.content.len > 0);

    switch (result.content[0]) {
        .text => |t| try testing.expect(t.text.len > 0),
        else => return error.ExpectedText,
    }
}

test "github_copilot e2e: streaming events sequence" {
    // Check for GitHub Copilot credentials
    try test_helpers.skipGitHubCopilotTest(testing.allocator);

    var creds = (try test_helpers.getFreshGitHubCopilotCredentials(testing.allocator)) orelse return error.SkipZigTest;
    defer creds.deinit(testing.allocator);

    const base_url = creds.base_url orelse "https://api.individual.githubcopilot.com";

    var registry = api_registry.ApiRegistry.init(testing.allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    const model = ai_types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api = "openai-completions",
        .provider = "github-copilot",
        .base_url = base_url,
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 50,
    };

    const user_msg = ai_types.Message{ .user = .{
        .content = .{ .text = "Count to 3." },
        .timestamp = std.time.timestamp(),
    } };

    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user_msg} };

    const stream = try stream_mod.stream(&registry, model, ctx, .{
        .api_key = ai_types.OwnedSlice(u8).initBorrowed(creds.copilot_token),
        .max_tokens = 50,
    }, testing.allocator);
    defer {
        stream.deinit();
        testing.allocator.destroy(stream);
    }

    var saw_start = false;
    var saw_text_delta = false;
    var text_len: usize = 0;

    while (true) {
        if (stream.poll()) |event| {
            switch (event) {
                .start => saw_start = true,
                .text_delta => |d| {
                    saw_text_delta = true;
                    text_len += d.delta.len;
                },
                else => {},
            }
        } else {
            if (stream.isDone()) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Allow detached provider thread to complete deferred cleanup
    std.Thread.sleep(50 * std.time.ns_per_ms);

    if (stream.getError()) |err| {
        std.debug.print("\nTest FAILED: github_copilot e2e stream error: {s}\n", .{err});
        return error.TestFailed;
    }

    try testing.expect(saw_start);
    try testing.expect(saw_text_delta);
    try testing.expect(text_len > 0);
}
