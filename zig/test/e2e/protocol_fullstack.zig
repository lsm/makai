const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const register_builtins = @import("register_builtins");
const test_helpers = @import("test_helpers");
const protocol_server = @import("protocol_server");
const protocol_client = @import("protocol_client");
const envelope = @import("envelope");
const transport = @import("transport");
const in_process = @import("transports/in_process");

const testing = std.testing;
const ProtocolServer = protocol_server.ProtocolServer;
const ProtocolClient = protocol_client.ProtocolClient;

// Access protocol_types through envelope module (which re-exports types)
const protocol_types = envelope.protocol_types;

// Use SerializedPipe from in_process transport module
const PipeTransport = in_process.SerializedPipe;

/// Helper to get env var or return null
fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

/// Protocol pump that forwards events from provider stream to client via protocol layer
const ProtocolPump = struct {
    server: *ProtocolServer,
    pipe: *PipeTransport,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Forward events from all active streams to the client
    /// Returns number of events forwarded
    pub fn pumpEvents(self: *Self) !usize {
        var events_forwarded: usize = 0;

        // Get the server's active streams using the public iterator
        var iter = self.server.activeStreamIterator();
        while (iter.next()) |entry| {
            const active_stream = entry.stream;
            const stream_id = entry.stream_id;

            // Poll ALL available events from the provider's event stream
            // before checking if the stream is done
            while (active_stream.event_stream.poll()) |event| {
                // Create an envelope with the event
                const seq = self.server.getNextSequence(stream_id);
                const env = protocol_types.Envelope{
                    .stream_id = stream_id,
                    .message_id = protocol_types.generateUuid(),
                    .sequence = seq,
                    .timestamp = std.time.milliTimestamp(),
                    .payload = .{ .event = event },
                };
                // NOTE: Do NOT call env.deinit() - event payloads have borrowed strings
                // from the provider's internal buffer that will be freed when the stream deinit

                // Serialize and send to client
                const json = try envelope.serializeEnvelope(env, self.allocator);
                defer self.allocator.free(json);

                var sender = self.pipe.serverSender();
                try sender.write(json);
                try sender.flush();

                events_forwarded += 1;
            }

            // Check if stream is done (only after polling all events)
            if (active_stream.event_stream.isDone()) {
                // Send result or error to client
                if (active_stream.event_stream.getResult()) |result| {
                    const seq = self.server.getNextSequence(stream_id);
                    const env = protocol_types.Envelope{
                        .stream_id = stream_id,
                        .message_id = protocol_types.generateUuid(),
                        .sequence = seq,
                        .timestamp = std.time.milliTimestamp(),
                        .payload = .{ .result = result },
                    };
                    // NOTE: Do NOT call env.deinit() - result payloads have borrowed strings
                    // from the provider's internal buffer that will be freed when the stream deinit

                    const json = try envelope.serializeEnvelope(env, self.allocator);
                    defer self.allocator.free(json);

                    var sender = self.pipe.serverSender();
                    try sender.write(json);
                    try sender.flush();
                } else if (active_stream.event_stream.getError()) |err_msg| {
                    // Stream completed with error - send stream_error to client
                    const seq = self.server.getNextSequence(stream_id);
                    const err_copy = try self.allocator.dupe(u8, err_msg);
                    var env = protocol_types.Envelope{
                        .stream_id = stream_id,
                        .message_id = protocol_types.generateUuid(),
                        .sequence = seq,
                        .timestamp = std.time.milliTimestamp(),
                        .payload = .{ .stream_error = .{
                            .code = .provider_error,
                            .message = err_copy,
                        } },
                    };

                    const json = try envelope.serializeEnvelope(env, self.allocator);
                    defer self.allocator.free(json);

                    var sender = self.pipe.serverSender();
                    try sender.write(json);
                    try sender.flush();

                    // Free the error envelope's allocated memory
                    env.deinit(self.allocator);
                }
            }
        }

        return events_forwarded;
    }

    /// Process any pending messages from client to server
    pub fn pumpClientMessages(self: *Self) !void {
        var receiver = self.pipe.serverReceiver();
        while (try receiver.readLine(self.allocator)) |line| {
            defer self.allocator.free(line);

            var env = envelope.deserializeEnvelope(line, self.allocator) catch continue;
            defer env.deinit(self.allocator);

            // Process through server
            if (try self.server.handleEnvelope(env)) |response| {
                var mut_response = response;
                defer mut_response.deinit(self.allocator);

                const json = try envelope.serializeEnvelope(mut_response, self.allocator);
                defer self.allocator.free(json);

                var sender = self.pipe.serverSender();
                try sender.write(json);
                try sender.flush();
            }
        }
    }
};

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
        .api_key = api_key,
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
        .api_key = api_key,
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
    if (client.last_error) |err| {
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
    const base_url = creds.base_url orelse "https://api.githubcopilot.com";

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
        .api_key = creds.copilot_token,
        .session_id = "test-session",
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

        if (client.getEventStream().poll()) |event| {
            switch (event) {
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
    if (client.last_error) |err| {
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
    const base_url = creds.base_url orelse "https://api.githubcopilot.com";

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
        .api_key = creds.copilot_token,
        .session_id = "test-session",
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
    if (client.last_error) |err| {
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
