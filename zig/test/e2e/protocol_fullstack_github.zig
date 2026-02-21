//! Protocol Fullstack E2E Tests - GitHub Copilot Provider
//!
//! Tests the full protocol stack: ProtocolClient -> SerializedPipe -> ProtocolServer -> GitHub Copilot

const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const register_builtins = @import("register_builtins");
const test_helpers = @import("test_helpers");
const protocol_server = @import("protocol_server");
const protocol_client = @import("protocol_client");
const envelope = @import("envelope");
const in_process = @import("transports/in_process");
const protocol_pump = @import("protocol_pump.zig");

const testing = std.testing;
const ProtocolServer = protocol_server.ProtocolServer;
const ProtocolClient = protocol_client.ProtocolClient;
const ProtocolPump = protocol_pump.ProtocolPump;
const PipeTransport = in_process.SerializedPipe;

// Access protocol_types through envelope module (which re-exports types)
const protocol_types = envelope.protocol_types;

// =============================================================================
// GitHub Copilot Protocol Layer E2E Tests
// =============================================================================

test "Protocol: GitHub Copilot streaming through ProtocolServer and ProtocolClient" {
    const allocator = testing.allocator;

    // Check for GitHub Copilot credentials
    try test_helpers.skipGitHubCopilotTest(allocator);

    test_helpers.testStart("Protocol: GitHub Copilot streaming through ProtocolServer and ProtocolClient");

    var creds = (try test_helpers.getFreshGitHubCopilotCredentials(allocator)) orelse return error.SkipZigTest;
    defer creds.deinit(allocator);

    // Use base_url from token, or fall back to default
    const base_url = creds.base_url orelse "https://api.individual.githubcopilot.com";

    // Set up pipe transport
    var pipe = in_process.createSerializedPipe(allocator);
    defer pipe.deinit();

    // Set up provider registry
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    // Set up ProtocolServer
    var server = ProtocolServer.init(allocator, &registry, .{});
    defer server.deinit();

    // Set up ProtocolClient
    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();
    client.setSender(pipe.clientSender());

    // Create model and context
    // GitHub Copilot uses openai-completions API with github-copilot provider
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

    // Set up pump
    var pump = ProtocolPump{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };

    // Send stream request using official ProtocolClient API
    const options = ai_types.StreamOptions{
        .api_key = ai_types.OwnedSlice(u8).initBorrowed(creds.copilot_token),
        .session_id = ai_types.OwnedSlice(u8).initBorrowed("test-session"),
        .max_tokens = 50,
        .temperature = 0.0,
    };
    _ = try client.sendStreamRequest(model, ctx, options);

    // Process stream request
    try pump.pumpClientMessages();

    // Track events
    var text_buffer = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
    defer text_buffer.deinit(allocator);

    var saw_start = false;
    var saw_text_delta = false;
    var saw_done = false;
    var saw_result = false;

    // Pump events until complete
    const deadline = test_helpers.createDeadline(test_helpers.DEFAULT_E2E_TIMEOUT_MS);

    while (!test_helpers.isDeadlineExceeded(deadline)) {
        _ = try pump.pumpEvents();

        var client_receiver = pipe.clientReceiver();
        while (try client_receiver.readLine(allocator)) |line| {
            defer allocator.free(line);

            var env = envelope.deserializeEnvelope(line, allocator) catch continue;
            defer env.deinit(allocator);

            try client.processEnvelope(env);
        }

        // Check client's event stream for events - poll ALL available events
        while (client.getEventStream().poll()) |event| {
            var ev = event; // Make mutable copy for deinit
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

        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Check for errors before asserting success
    if (client.getLastError()) |err| {
        std.debug.print("\n\x1b[31mERROR\x1b[0m: Stream failed with error: {s}\n", .{err});
        return error.StreamError;
    }

    // Verify event sequence
    try testing.expect(saw_start);
    try testing.expect(saw_text_delta);
    try testing.expect(saw_done or saw_result);
    try testing.expect(text_buffer.items.len > 0);

    test_helpers.testSuccess("Protocol: GitHub Copilot streaming through ProtocolServer and ProtocolClient");
}

test "Protocol: GitHub Copilot abort through protocol layer" {
    const allocator = testing.allocator;

    // Check for GitHub Copilot credentials
    try test_helpers.skipGitHubCopilotTest(allocator);

    test_helpers.testStart("Protocol: GitHub Copilot abort through protocol layer");

    var creds = (try test_helpers.getFreshGitHubCopilotCredentials(allocator)) orelse return error.SkipZigTest;
    defer creds.deinit(allocator);

    // Use base_url from token, or fall back to default
    const base_url = creds.base_url orelse "https://api.individual.githubcopilot.com";

    // Set up pipe transport
    var pipe = in_process.createSerializedPipe(allocator);
    defer pipe.deinit();

    // Set up provider registry
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    // Set up ProtocolServer
    var server = ProtocolServer.init(allocator, &registry, .{});
    defer server.deinit();

    // Set up ProtocolClient
    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();
    client.setSender(pipe.clientSender());

    // Create model and context
    // GitHub Copilot uses openai-completions API with github-copilot provider
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
        .timestamp = std.time.timestamp(),
    } };

    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user_msg} };

    // Set up pump
    var pump = ProtocolPump{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };

    // Send stream request using official ProtocolClient API
    const options = ai_types.StreamOptions{
        .api_key = ai_types.OwnedSlice(u8).initBorrowed(creds.copilot_token),
        .session_id = ai_types.OwnedSlice(u8).initBorrowed("test-session"),
        .max_tokens = 500,
    };
    _ = try client.sendStreamRequest(model, ctx, options);

    // Process stream request
    try pump.pumpClientMessages();

    // Read a few events then abort
    var event_count: usize = 0;
    const max_events = 5;

    const deadline = test_helpers.createDeadline(10_000);
    while (event_count < max_events and !test_helpers.isDeadlineExceeded(deadline)) {
        _ = try pump.pumpEvents();

        var client_receiver = pipe.clientReceiver();
        while (try client_receiver.readLine(allocator)) |line| {
            defer allocator.free(line);

            var env = envelope.deserializeEnvelope(line, allocator) catch continue;
            defer env.deinit(allocator);

            try client.processEnvelope(env);
        }

        // Poll ALL available events
        while (client.getEventStream().poll()) |event| {
            var ev = event;
            defer protocol_types.deinitEvent(allocator, &ev);
            event_count += 1;
        }

        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Check for errors before proceeding
    if (client.getLastError()) |err| {
        std.debug.print("\n\x1b[31mERROR\x1b[0m: Stream failed with error: {s}\n", .{err});
        return error.StreamError;
    }

    // Send abort request using official ProtocolClient API
    try client.sendAbortRequest(null);

    // Process abort request
    try pump.pumpClientMessages();

    // Verify stream was removed
    try testing.expect(server.activeStreamCount() == 0);

    // Verify we got at least one event before abort
    try testing.expect(event_count >= 1);

    test_helpers.testSuccess("Protocol: GitHub Copilot abort through protocol layer");
}
