const std = @import("std");
const types = @import("types");
const config = @import("config");
const github_copilot = @import("github_copilot");
const test_helpers = @import("test_helpers");

const testing = std.testing;

test "github_copilot: basic text generation" {
    if (test_helpers.shouldSkipGitHubCopilot(testing.allocator)) {
        return error.SkipZigTest;
    }
    var creds = (try test_helpers.getGitHubCopilotCredentials(testing.allocator)).?;
    defer creds.deinit(testing.allocator);

    const cfg = config.GitHubCopilotConfig{
        .copilot_token = creds.copilot_token,
        .github_token = creds.github_token,
        .model = "gpt-4o",
        .params = .{
            .max_tokens = 100,
            .temperature = 1.0,
        },
    };

    const prov = try github_copilot.createProvider(cfg, testing.allocator);
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

test "github_copilot: streaming events sequence" {
    if (test_helpers.shouldSkipGitHubCopilot(testing.allocator)) {
        return error.SkipZigTest;
    }
    var creds = (try test_helpers.getGitHubCopilotCredentials(testing.allocator)).?;
    defer creds.deinit(testing.allocator);

    const cfg = config.GitHubCopilotConfig{
        .copilot_token = creds.copilot_token,
        .github_token = creds.github_token,
        .model = "gpt-4o",
        .params = .{ .max_tokens = 50 },
    };

    const prov = try github_copilot.createProvider(cfg, testing.allocator);
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

test "github_copilot: usage tracking" {
    if (test_helpers.shouldSkipGitHubCopilot(testing.allocator)) {
        return error.SkipZigTest;
    }
    var creds = (try test_helpers.getGitHubCopilotCredentials(testing.allocator)).?;
    defer creds.deinit(testing.allocator);

    const cfg = config.GitHubCopilotConfig{
        .copilot_token = creds.copilot_token,
        .github_token = creds.github_token,
        .model = "gpt-4o",
        .params = .{ .max_tokens = 100 },
    };

    const prov = try github_copilot.createProvider(cfg, testing.allocator);
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
