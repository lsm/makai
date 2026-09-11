
const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const register_builtins = @import("register_builtins");
const test_helpers = @import("test_helpers");
const protocol_server = @import("protocol_server");
const protocol_client = @import("protocol_client");
const envelope = @import("envelope");
const in_process = @import("transports/in_process");
const protocol_runtime = @import("protocol_runtime");

const testing = std.testing;
const ProtocolServer = protocol_server.ProtocolServer;
const ProtocolClient = protocol_client.ProtocolClient;
const ProviderProtocolRuntime = protocol_runtime.ProviderProtocolRuntime;
const PipeTransport = in_process.SerializedPipe;

const protocol_types = envelope.protocol_types;

test "ProviderProtocol: GitHub Copilot streaming through ProtocolServer and ProtocolClient" {
    const allocator = testing.allocator;

    try test_helpers.skipGitHubCopilotTest(allocator);

    test_helpers.testStart("Protocol: GitHub Copilot streaming through ProtocolServer and ProtocolClient");

    var creds = (try test_helpers.getFreshGitHubCopilotCredentials(allocator)) orelse return error.SkipZigTest;
    defer creds.deinit(allocator);

    const base_url = creds.base_url orelse "https://api.individual.githubcopilot.com";

    var pipe = in_process.createSerializedPipe(allocator);
    defer pipe.deinit();

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    var server = ProtocolServer.init(allocator, &registry, .{});
    defer server.deinit();

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();
    client.setSender(pipe.clientSender());

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
        .timestamp = compat.time.nowSeconds(),
    } };

    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user_msg} };

    var runtime = ProviderProtocolRuntime{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };

    const options = ai_types.StreamOptions{
        .api_key = ai_types.OwnedSlice(u8).initBorrowed(creds.copilot_token),
        .session_id = ai_types.OwnedSlice(u8).initBorrowed("test-session"),
        .max_tokens = 50,
        .temperature = 0.0,
    };
    _ = try client.sendStreamRequest(model, ctx, options);

    try runtime.pumpClientMessages();

    var text_buffer = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
    defer text_buffer.deinit(allocator);

    var saw_start = false;
    var saw_text_delta = false;
    var saw_done = false;
    var saw_result = false;

    const deadline = test_helpers.createDeadline(test_helpers.DEFAULT_E2E_TIMEOUT_MS);

    while (!test_helpers.isDeadlineExceeded(deadline)) {
        _ = try runtime.pumpOnce(&client);

        while (client.getEventStream().poll()) |event| {
            var ev = event;
            defer protocol_types.deinitEvent(allocator, &ev);

            switch (ev) {
                .start => saw_start = true,
                .text_delta => |d| {
                    saw_text_delta = true;
                    text_buffer.appendSlice(allocator, d.delta) catch {};
                },
                .done => saw_done = true,
                else => {},
            }
        }

        if (client.isComplete()) {
            if (client.last_result) |_| {
                saw_result = true;
            }
            break;
        }

        compat.time.sleepNs(10 * std.time.ns_per_ms);
    }

    if (client.getLastError()) |err| {
        std.debug.print("\n\x1b[31mERROR\x1b[0m: Stream failed with error: {s}\n", .{err});
        return error.StreamError;
    }

    try testing.expect(saw_start);
    try testing.expect(saw_text_delta);
    try testing.expect(saw_done or saw_result);
    try testing.expect(text_buffer.items.len > 0);

    test_helpers.testSuccess("Protocol: GitHub Copilot streaming through ProtocolServer and ProtocolClient");
}

test "ProviderProtocol: GitHub Copilot abort through protocol layer" {
    const allocator = testing.allocator;

    try test_helpers.skipGitHubCopilotTest(allocator);

    test_helpers.testStart("Protocol: GitHub Copilot abort through protocol layer");

    var creds = (try test_helpers.getFreshGitHubCopilotCredentials(allocator)) orelse return error.SkipZigTest;
    defer creds.deinit(allocator);

    const base_url = creds.base_url orelse "https://api.individual.githubcopilot.com";

    var pipe = in_process.createSerializedPipe(allocator);
    defer pipe.deinit();

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    var server = ProtocolServer.init(allocator, &registry, .{});
    defer server.deinit();

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();
    client.setSender(pipe.clientSender());

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
        .max_tokens = 500,
    };

    const user_msg = ai_types.Message{ .user = .{
        .content = .{ .text = "Write a long story about a space adventure." },
        .timestamp = compat.time.nowSeconds(),
    } };

    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user_msg} };

    var runtime = ProviderProtocolRuntime{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };

    const options = ai_types.StreamOptions{
        .api_key = ai_types.OwnedSlice(u8).initBorrowed(creds.copilot_token),
        .session_id = ai_types.OwnedSlice(u8).initBorrowed("test-session"),
        .max_tokens = 500,
    };
    _ = try client.sendStreamRequest(model, ctx, options);

    try runtime.pumpClientMessages();

    var event_count: usize = 0;
    const max_events = 5;

    const deadline = test_helpers.createDeadline(10_000);
    while (event_count < max_events and !test_helpers.isDeadlineExceeded(deadline)) {
        _ = try runtime.pumpOnce(&client);

        while (client.getEventStream().poll()) |event| {
            var ev = event;
            defer protocol_types.deinitEvent(allocator, &ev);
            event_count += 1;
        }

        compat.time.sleepNs(10 * std.time.ns_per_ms);
    }

    if (client.getLastError()) |err| {
        std.debug.print("\n\x1b[31mERROR\x1b[0m: Stream failed with error: {s}\n", .{err});
        return error.StreamError;
    }

    try client.sendAbortRequest(null);

    try runtime.pumpClientMessages();

    _ = try runtime.pumpServerOutbox();
    try runtime.pumpServerMessagesIntoClient(&client);
    server.cleanupCompletedStreams();

    try testing.expect(server.activeStreamCount() == 0);

    try testing.expect(event_count >= 1);

    test_helpers.testSuccess("Protocol: GitHub Copilot abort through protocol layer");
}
