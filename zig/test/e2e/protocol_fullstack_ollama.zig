//! Protocol Fullstack E2E Tests - Ollama Provider
//!
//! Tests the full protocol stack: ProtocolClient -> SerializedPipe -> ProtocolServer -> Ollama

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

/// Helper to get env var or return null
fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

// =============================================================================
// Ollama Protocol Layer E2E Tests
// =============================================================================

test "Protocol: Ollama streaming through ProtocolServer and ProtocolClient" {
    const allocator = testing.allocator;

    // Check for Ollama availability
    const api_key = getEnvOwned(allocator, "OLLAMA_API_KEY");
    defer if (api_key) |k| allocator.free(k);

    if (api_key == null) {
        // Check for local server
        var http_client = std.http.Client{ .allocator = allocator };
        defer http_client.deinit();

        const uri = std.Uri.parse("http://127.0.0.1:11434/api/tags") catch {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: Protocol Ollama test - no OLLAMA_API_KEY and localhost:11434 not available\n", .{});
            return error.SkipZigTest;
        };

        var req = http_client.request(.GET, uri, .{}) catch {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: Protocol Ollama test - localhost:11434 not responding\n", .{});
            return error.SkipZigTest;
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = 0 };
        req.sendBodyComplete(&.{}) catch {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: Protocol Ollama test - ollama local server not responding\n", .{});
            return error.SkipZigTest;
        };

        var head_buf: [1024]u8 = undefined;
        const response = req.receiveHead(&head_buf) catch {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: Protocol Ollama test - ollama local server not available\n", .{});
            return error.SkipZigTest;
        };

        if (response.head.status != .ok) {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: Protocol Ollama test - ollama local server not healthy\n", .{});
            return error.SkipZigTest;
        }
    }

    test_helpers.testStart("Protocol: Ollama streaming through ProtocolServer and ProtocolClient");

    // Get model from env or use default
    const model_id = getEnvOwned(allocator, "OLLAMA_MODEL") orelse try allocator.dupe(u8, "llama3.2:1b");
    defer allocator.free(model_id);

    const base_url = getEnvOwned(allocator, "OLLAMA_BASE_URL") orelse try allocator.dupe(u8, "");
    defer allocator.free(base_url);

    // Set up pipe transport
    var pipe = in_process.createSerializedPipe(allocator);
    defer pipe.deinit();

    // Set up provider registry with builtin providers
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    // Set up ProtocolServer with registry
    var server = ProtocolServer.init(allocator, &registry, .{});
    defer server.deinit();

    // Set up ProtocolClient connected to pipe
    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();
    client.setSender(pipe.clientSender());

    // Create model and context
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

    // Set up protocol pump
    var pump = ProtocolPump{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };

    // Send stream request using official ProtocolClient API
    const options = ai_types.StreamOptions{
        .api_key = if (api_key) |k| ai_types.OwnedSlice(u8).initBorrowed(k) else ai_types.OwnedSlice(u8).initBorrowed(""),
        .max_tokens = 50,
        .temperature = 0.0,
    };
    _ = try client.sendStreamRequest(model, ctx, options);

    // Process the request through server
    try pump.pumpClientMessages();

    // Verify stream was created
    try testing.expect(server.activeStreamCount() == 1);

    // Track events received by client
    var text_buffer = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
    defer text_buffer.deinit(allocator);

    var saw_start = false;
    var saw_text_delta = false;
    var saw_done = false;
    var saw_result = false;

    // Pump events until stream is complete
    const deadline = test_helpers.createDeadline(test_helpers.DEFAULT_E2E_TIMEOUT_MS);

    while (!test_helpers.isDeadlineExceeded(deadline)) {
        // Pump events from provider to client
        _ = try pump.pumpEvents();

        // Process server -> client messages
        var client_receiver = pipe.clientReceiver();
        while (try client_receiver.readLine(allocator)) |line| {
            defer allocator.free(line);

            var env = envelope.deserializeEnvelope(line, allocator) catch continue;
            defer env.deinit(allocator);

            // Process through client
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

        // Check if complete
        if (client.isComplete()) {
            if (client.last_result) |_| {
                saw_result = true;
            }
            break;
        }

        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Verify event sequence
    try testing.expect(saw_start);
    try testing.expect(saw_text_delta);
    try testing.expect(saw_done or saw_result);
    try testing.expect(text_buffer.items.len > 0);

    test_helpers.testSuccess("Protocol: Ollama streaming through ProtocolServer and ProtocolClient");
}

test "Protocol: Ollama abort through protocol layer" {
    const allocator = testing.allocator;

    // Check for Ollama availability using skipOllamaTest
    // Note: skipOllamaTest only checks for OLLAMA_API_KEY, so we also check local server
    const api_key = getEnvOwned(allocator, "OLLAMA_API_KEY");
    defer if (api_key) |k| allocator.free(k);

    if (api_key == null) {
        // Check for local server
        var http_client = std.http.Client{ .allocator = allocator };
        defer http_client.deinit();

        const uri = std.Uri.parse("http://127.0.0.1:11434/api/tags") catch {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: Protocol Ollama abort test - no OLLAMA_API_KEY and localhost:11434 not available\n", .{});
            return error.SkipZigTest;
        };

        var req = http_client.request(.GET, uri, .{}) catch {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: Protocol Ollama abort test - localhost:11434 not responding\n", .{});
            return error.SkipZigTest;
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = 0 };
        req.sendBodyComplete(&.{}) catch {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: Protocol Ollama abort test - ollama local server not responding\n", .{});
            return error.SkipZigTest;
        };

        var head_buf: [1024]u8 = undefined;
        const response = req.receiveHead(&head_buf) catch {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: Protocol Ollama abort test - ollama local server not available\n", .{});
            return error.SkipZigTest;
        };

        if (response.head.status != .ok) {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: Protocol Ollama abort test - ollama local server not healthy\n", .{});
            return error.SkipZigTest;
        }
    }

    test_helpers.testStart("Protocol: Ollama abort through protocol layer");

    // Get model from env or use default
    const model_id = getEnvOwned(allocator, "OLLAMA_MODEL") orelse try allocator.dupe(u8, "llama3.2:1b");
    defer allocator.free(model_id);

    const base_url = getEnvOwned(allocator, "OLLAMA_BASE_URL") orelse try allocator.dupe(u8, "");
    defer allocator.free(base_url);

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

    // Set up pump
    var pump = ProtocolPump{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };

    // Send stream request using official ProtocolClient API
    const options = ai_types.StreamOptions{
        .api_key = if (api_key) |k| ai_types.OwnedSlice(u8).initBorrowed(k) else ai_types.OwnedSlice(u8).initBorrowed(""),
        .max_tokens = 500,
    };
    _ = try client.sendStreamRequest(model, ctx, options);

    // Process stream request
    try pump.pumpClientMessages();

    // Verify stream was created
    try testing.expect(server.activeStreamCount() == 1);

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

    test_helpers.testSuccess("Protocol: Ollama abort through protocol layer");
}
