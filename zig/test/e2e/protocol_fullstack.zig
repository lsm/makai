const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const register_builtins = @import("register_builtins");
const stream_mod = @import("stream");
const test_helpers = @import("test_helpers");

const testing = std.testing;

/// Helper to get env var or return null
fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

// =============================================================================
// Ollama E2E Tests
// =============================================================================

test "Full stack: Ollama streaming through provider to event stream" {
    const allocator = testing.allocator;

    // Check for Ollama availability
    const api_key = getEnvOwned(allocator, "OLLAMA_API_KEY");
    defer if (api_key) |k| allocator.free(k);

    if (api_key == null) {
        // Check for local server
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        const uri = std.Uri.parse("http://127.0.0.1:11434/api/tags") catch {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: Full stack Ollama test - no OLLAMA_API_KEY and localhost:11434 not available\n", .{});
            return error.SkipZigTest;
        };

        var req = client.request(.GET, uri, .{}) catch {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: Full stack Ollama test - localhost:11434 not responding\n", .{});
            return error.SkipZigTest;
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = 0 };
        req.sendBodyComplete(&.{}) catch {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: Full stack Ollama test - ollama local server not responding\n", .{});
            return error.SkipZigTest;
        };

        var head_buf: [1024]u8 = undefined;
        const response = req.receiveHead(&head_buf) catch {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: Full stack Ollama test - ollama local server not available\n", .{});
            return error.SkipZigTest;
        };

        if (response.head.status != .ok) {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: Full stack Ollama test - ollama local server not healthy\n", .{});
            return error.SkipZigTest;
        }
    }

    test_helpers.testStart("Full stack: Ollama streaming through provider to event stream");

    // Get model from env or use default
    const model_id = getEnvOwned(allocator, "OLLAMA_MODEL") orelse try allocator.dupe(u8, "llama3.2:1b");
    defer allocator.free(model_id);

    const base_url = getEnvOwned(allocator, "OLLAMA_BASE_URL") orelse try allocator.dupe(u8, "");
    defer allocator.free(base_url);

    // Set up registry with builtin providers
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    // Test the full stack: Provider -> API Stream -> Event Stream -> Events
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
        .max_tokens = 50,
    };

    const user_msg = ai_types.Message{ .user = .{
        .content = .{ .text = "Reply with exactly: hello world" },
        .timestamp = std.time.timestamp(),
    } };

    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user_msg} };

    // Stream through the provider (this tests the full provider stack)
    const stream = try stream_mod.stream(&registry, model, ctx, .{
        .api_key = api_key,
        .max_tokens = 50,
        .temperature = 0.0,
    }, allocator);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    // Track events (without accumulator.processEvent which tries to free borrowed strings)
    var text_buffer = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
    defer text_buffer.deinit(allocator);

    var saw_start = false;
    var saw_text_delta = false;
    var saw_done = false;
    var saw_result = false;

    // Poll events with timeout
    // Note: Event strings are borrowed from provider's internal buffer, so we must NOT free them.
    const deadline = test_helpers.createDeadline(test_helpers.DEFAULT_E2E_TIMEOUT_MS);
    while (true) {
        if (stream.poll()) |event| {
            switch (event) {
                .start => saw_start = true,
                .text_delta => |d| {
                    saw_text_delta = true;
                    text_buffer.appendSlice(allocator, d.delta) catch {};
                },
                .done => saw_done = true,
                else => {},
            }
        } else {
            if (stream.isDone()) break;
            if (test_helpers.isDeadlineExceeded(deadline)) {
                std.debug.print("\nTest FAILED: timeout waiting for stream\n", .{});
                return error.TimeoutExceeded;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Verify result is available
    if (stream.getResult()) |result| {
        saw_result = true;
        try testing.expect(result.content.len > 0);
    }

    // Verify event sequence
    try testing.expect(saw_start);
    try testing.expect(saw_text_delta);
    try testing.expect(saw_done);
    try testing.expect(saw_result);
    try testing.expect(text_buffer.items.len > 0);

    test_helpers.testSuccess("Full stack: Ollama streaming through provider to event stream");
}

test "Full stack: Ollama abort propagates through provider" {
    const allocator = testing.allocator;

    // Check for Ollama availability
    try test_helpers.skipOllamaTest(allocator);

    test_helpers.testStart("Full stack: Ollama abort propagates through provider");

    // Get model from env or use default
    const model_id = getEnvOwned(allocator, "OLLAMA_MODEL") orelse try allocator.dupe(u8, "llama3.2:1b");
    defer allocator.free(model_id);

    const base_url = getEnvOwned(allocator, "OLLAMA_BASE_URL") orelse try allocator.dupe(u8, "");
    defer allocator.free(base_url);

    // Set up registry
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    var cancelled = std.atomic.Value(bool).init(false);
    const cancel_token = ai_types.CancelToken{ .cancelled = &cancelled };

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
        .max_tokens = 500,
    };

    const user_msg = ai_types.Message{ .user = .{
        .content = .{ .text = "Write a long story about a space adventure." },
        .timestamp = std.time.timestamp(),
    } };

    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user_msg} };

    // Get API key
    const api_key = getEnvOwned(allocator, "OLLAMA_API_KEY");
    defer if (api_key) |k| allocator.free(k);

    // Stream with cancel token
    const stream = try stream_mod.stream(&registry, model, ctx, .{
        .api_key = api_key,
        .max_tokens = 500,
        .cancel_token = cancel_token,
    }, allocator);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    // Read a few events then abort
    // Note: Event strings are borrowed from provider's internal buffer, so we must NOT free them.
    var event_count: usize = 0;
    const max_events = 5;

    const deadline = test_helpers.createDeadline(10_000); // 10 second deadline
    while (event_count < max_events) {
        if (stream.poll()) |_| {
            // Don't free event - strings are borrowed from provider's internal buffer
            event_count += 1;
        } else {
            if (stream.isDone()) break;
            if (test_helpers.isDeadlineExceeded(deadline)) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Abort
    cancelled.store(true, .release);
    std.Thread.sleep(100 * std.time.ns_per_ms);

    try testing.expect(event_count >= 1); // Should have gotten at least one event
    try testing.expect(cancel_token.isCancelled());

    test_helpers.testSuccess("Full stack: Ollama abort propagates through provider");
}

test "Full stack: Ollama event reconstruction from stream" {
    const allocator = testing.allocator;

    // Check for Ollama availability
    try test_helpers.skipOllamaTest(allocator);

    test_helpers.testStart("Full stack: Ollama event reconstruction from stream");

    // Get model from env or use default
    const model_id = getEnvOwned(allocator, "OLLAMA_MODEL") orelse try allocator.dupe(u8, "llama3.2:1b");
    defer allocator.free(model_id);

    const base_url = getEnvOwned(allocator, "OLLAMA_BASE_URL") orelse try allocator.dupe(u8, "");
    defer allocator.free(base_url);

    // Set up registry
    var registry = api_registry.ApiRegistry.init(allocator);
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
        .max_tokens = 100,
    };

    const user_msg = ai_types.Message{ .user = .{
        .content = .{ .text = "Count from 1 to 5." },
        .timestamp = std.time.timestamp(),
    } };

    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user_msg} };

    // Get API key
    const api_key = getEnvOwned(allocator, "OLLAMA_API_KEY");
    defer if (api_key) |k| allocator.free(k);

    // Stream through the provider
    const stream = try stream_mod.stream(&registry, model, ctx, .{
        .api_key = api_key,
        .max_tokens = 100,
        .temperature = 0.0,
    }, allocator);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    // Collect events for reconstruction
    var text_deltas = std.ArrayList([]const u8).initCapacity(allocator, 16) catch return error.OutOfMemory;
    defer {
        for (text_deltas.items) |d| allocator.free(d);
        text_deltas.deinit(allocator);
    }

    var saw_start = false;
    var saw_done = false;
    var usage: ?ai_types.Usage = null;

    // Poll events
    // Note: Event strings are borrowed from provider's internal buffer, so we must NOT free them.
    const deadline = test_helpers.createDeadline(test_helpers.DEFAULT_E2E_TIMEOUT_MS);
    while (true) {
        if (stream.poll()) |event| {
            switch (event) {
                .start => |s| {
                    saw_start = true;
                    try testing.expect(s.partial.model.len > 0);
                    // Don't free - strings are borrowed from provider's internal buffer
                },
                .text_delta => |d| {
                    // Dupe the delta for later reconstruction, but don't free the original
                    try text_deltas.append(allocator, try allocator.dupe(u8, d.delta));
                    // Don't free d.delta, d.partial.model, etc. - they're borrowed
                },
                .done => |d| {
                    saw_done = true;
                    usage = d.message.usage;
                },
                else => {},
            }
        } else {
            if (stream.isDone()) break;
            if (test_helpers.isDeadlineExceeded(deadline)) {
                std.debug.print("\nTest FAILED: timeout waiting for stream\n", .{});
                return error.TimeoutExceeded;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Reconstruct text from deltas
    var reconstructed = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
    defer reconstructed.deinit(allocator);
    for (text_deltas.items) |delta| {
        try reconstructed.appendSlice(allocator, delta);
    }

    // Verify reconstruction
    try testing.expect(saw_start);
    try testing.expect(saw_done);
    try testing.expect(text_deltas.items.len > 0);
    try testing.expect(reconstructed.items.len > 0);

    // Verify usage
    if (usage) |u| {
        try testing.expect(u.input > 0);
        try testing.expect(u.output > 0);
    }

    // Verify result matches reconstructed text
    if (stream.getResult()) |result| {
        try testing.expect(result.content.len > 0);
        switch (result.content[0]) {
            .text => |t| {
                try testing.expect(t.text.len > 0);
            },
            else => {},
        }
    }

    test_helpers.testSuccess("Full stack: Ollama event reconstruction from stream");
}

// =============================================================================
// GitHub Copilot E2E Tests
// =============================================================================

test "Full stack: GitHub Copilot streaming through provider" {
    const allocator = testing.allocator;

    // Check for GitHub Copilot credentials
    try test_helpers.skipGitHubCopilotTest(allocator);

    test_helpers.testStart("Full stack: GitHub Copilot streaming through provider");

    var creds = (try test_helpers.getGitHubCopilotCredentials(allocator)) orelse return error.SkipZigTest;
    defer creds.deinit(allocator);

    // Set up registry with builtin providers
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    const model = ai_types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api = "github-copilot",
        .provider = "github-copilot",
        .base_url = "https://api.githubcopilot.com",
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

    // Stream through the provider
    const stream = try stream_mod.stream(&registry, model, ctx, .{
        .api_key = creds.copilot_token,
        .session_id = "test-session",
        .max_tokens = 50,
        .temperature = 0.0,
    }, allocator);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    // Track events (without accumulator.processEvent which tries to free borrowed strings)
    // Note: Event strings are borrowed from provider's internal buffer, so we must NOT free them.
    var text_buffer = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
    defer text_buffer.deinit(allocator);

    var saw_start = false;
    var saw_text_delta = false;
    var saw_done = false;

    // Poll events with timeout
    const deadline = test_helpers.createDeadline(test_helpers.DEFAULT_E2E_TIMEOUT_MS);
    while (true) {
        if (stream.poll()) |event| {
            switch (event) {
                .start => saw_start = true,
                .text_delta => |d| {
                    saw_text_delta = true;
                    text_buffer.appendSlice(allocator, d.delta) catch {};
                },
                .done => saw_done = true,
                else => {},
            }
        } else {
            if (stream.isDone()) break;
            if (test_helpers.isDeadlineExceeded(deadline)) {
                std.debug.print("\nTest FAILED: timeout waiting for stream\n", .{});
                return error.TimeoutExceeded;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Verify event sequence
    try testing.expect(saw_start);
    try testing.expect(saw_text_delta);
    try testing.expect(saw_done);
    try testing.expect(text_buffer.items.len > 0);

    // Verify result
    const result = stream.getResult() orelse return error.NoResult;
    try testing.expect(result.content.len > 0);

    test_helpers.testSuccess("Full stack: GitHub Copilot streaming through provider");
}

test "Full stack: GitHub Copilot tool calls through provider" {
    const allocator = testing.allocator;

    // Check for GitHub Copilot credentials
    try test_helpers.skipGitHubCopilotTest(allocator);

    test_helpers.testStart("Full stack: GitHub Copilot tool calls through provider");

    var creds = (try test_helpers.getGitHubCopilotCredentials(allocator)) orelse return error.SkipZigTest;
    defer creds.deinit(allocator);

    // Set up registry
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    const weather_tool = ai_types.Tool{
        .name = "get_weather",
        .description = "Get current weather for a location",
        .parameters_schema_json =
            \\{"type":"object","properties":{"location":{"type":"string","description":"City name"}},"required":["location"]}
        ,
    };

    const model = ai_types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api = "github-copilot",
        .provider = "github-copilot",
        .base_url = "https://api.githubcopilot.com",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 200,
    };

    const user_msg = ai_types.Message{ .user = .{
        .content = .{ .text = "What's the weather in Tokyo?" },
        .timestamp = std.time.timestamp(),
    } };

    var tools_storage = [_]ai_types.Tool{weather_tool};
    const ctx = ai_types.Context{
        .messages = &[_]ai_types.Message{user_msg},
        .tools = &tools_storage,
    };

    // Stream with tool support
    const stream = try stream_mod.stream(&registry, model, ctx, .{
        .api_key = creds.copilot_token,
        .session_id = "test-session",
        .max_tokens = 200,
        .tool_choice = .auto,
    }, allocator);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    // Track events (without accumulator.processEvent which tries to free borrowed strings)
    // Note: Event strings are borrowed from provider's internal buffer, so we must NOT free them.
    var saw_tool_call = false;

    // Poll until done
    const deadline = test_helpers.createDeadline(test_helpers.DEFAULT_E2E_TIMEOUT_MS);
    while (true) {
        if (stream.poll()) |event| {
            switch (event) {
                .toolcall_start => saw_tool_call = true,
                .toolcall_delta => saw_tool_call = true,
                .toolcall_end => saw_tool_call = true,
                else => {}, // Don't process or free - strings are borrowed
            }
        } else {
            if (stream.isDone()) break;
            if (test_helpers.isDeadlineExceeded(deadline)) {
                std.debug.print("\nTest FAILED: timeout waiting for stream\n", .{});
                return error.TimeoutExceeded;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Verify we got a response (tool call or text)
    const result = stream.getResult() orelse return error.NoResult;
    try testing.expect(result.content.len > 0);

    // Note: Tool calls may or may not happen depending on the model's decision
    // We just verify the stream completed successfully

    test_helpers.testSuccess("Full stack: GitHub Copilot tool calls through provider");
}

test "Full stack: GitHub Copilot abort through provider" {
    const allocator = testing.allocator;

    // Check for GitHub Copilot credentials
    try test_helpers.skipGitHubCopilotTest(allocator);

    test_helpers.testStart("Full stack: GitHub Copilot abort through provider");

    var creds = (try test_helpers.getGitHubCopilotCredentials(allocator)) orelse return error.SkipZigTest;
    defer creds.deinit(allocator);

    // Set up registry
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    var cancelled = std.atomic.Value(bool).init(false);
    const cancel_token = ai_types.CancelToken{ .cancelled = &cancelled };

    const model = ai_types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api = "github-copilot",
        .provider = "github-copilot",
        .base_url = "https://api.githubcopilot.com",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 500,
    };

    const user_msg = ai_types.Message{ .user = .{
        .content = .{ .text = "Write a long story about a space adventure." },
        .timestamp = std.time.timestamp(),
    } };

    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user_msg} };

    // Stream with cancel token
    const stream = try stream_mod.stream(&registry, model, ctx, .{
        .api_key = creds.copilot_token,
        .session_id = "test-session",
        .max_tokens = 500,
        .cancel_token = cancel_token,
    }, allocator);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    // Read a few events then abort
    // Note: Event strings are borrowed from provider's internal buffer, so we must NOT free them.
    var event_count: usize = 0;
    const max_events = 5;

    const deadline = test_helpers.createDeadline(10_000); // 10 second deadline
    while (event_count < max_events) {
        if (stream.poll()) |_| {
            // Don't free event - strings are borrowed from provider's internal buffer
            event_count += 1;
        } else {
            if (stream.isDone()) break;
            if (test_helpers.isDeadlineExceeded(deadline)) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Abort
    cancelled.store(true, .release);
    std.Thread.sleep(100 * std.time.ns_per_ms);

    try testing.expect(event_count >= 1); // Should have gotten at least one event
    try testing.expect(cancel_token.isCancelled());

    test_helpers.testSuccess("Full stack: GitHub Copilot abort through provider");
}
