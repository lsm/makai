const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const register_builtins = @import("register_builtins");
const test_helpers = @import("test_helpers");
const protocol_server = @import("protocol_server");
const protocol_client = @import("protocol_client");
const envelope = @import("envelope");
const transport = @import("transport");

const testing = std.testing;
const ProtocolServer = protocol_server.ProtocolServer;
const ProtocolClient = protocol_client.ProtocolClient;

// Access protocol_types through envelope module (which re-exports types)
const protocol_types = envelope.protocol_types;

/// Helper to get env var or return null
fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

/// In-memory pipe transport for testing the protocol layer
const PipeTransport = struct {
    /// Buffer for server -> client messages
    to_client: std.ArrayList(u8),
    /// Buffer for client -> server messages
    to_server: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .to_client = std.ArrayList(u8).initCapacity(allocator, 4096) catch unreachable,
            .to_server = std.ArrayList(u8).initCapacity(allocator, 4096) catch unreachable,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.to_client.deinit(self.allocator);
        self.to_server.deinit(self.allocator);
    }

    /// Server writes to this to send to client
    pub fn serverSender(self: *Self) transport.AsyncSender {
        return .{
            .context = self,
            .write_fn = struct {
                fn write(ctx: *anyopaque, data: []const u8) !void {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    try s.to_client.appendSlice(s.allocator, data);
                    try s.to_client.append(s.allocator, '\n');
                }
            }.write,
            .flush_fn = struct {
                fn flush(_: *anyopaque) !void {}
            }.flush,
        };
    }

    /// Client reads from this
    pub fn clientReceiver(self: *Self) Receiver {
        return .{
            .transport = self,
            .read_pos = 0,
        };
    }

    /// Client writes to this to send to server
    pub fn clientSender(self: *Self) transport.AsyncSender {
        return .{
            .context = self,
            .write_fn = struct {
                fn write(ctx: *anyopaque, data: []const u8) !void {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    try s.to_server.appendSlice(s.allocator, data);
                    try s.to_server.append(s.allocator, '\n');
                }
            }.write,
            .flush_fn = struct {
                fn flush(_: *anyopaque) !void {}
            }.flush,
        };
    }

    /// Server reads from this
    pub fn serverReceiver(self: *Self) Receiver {
        return .{
            .transport = self,
            .read_pos = 0,
        };
    }

    pub const Receiver = struct {
        transport: *Self,
        read_pos: usize,

        pub fn readLine(self: *@This(), allocator: std.mem.Allocator) !?[]const u8 {
            // Determine which buffer to read from based on direction
            const buffer = if (self.read_pos < self.transport.to_client.items.len)
                &self.transport.to_client
            else
                &self.transport.to_server;

            // Find next newline starting from read_pos
            const start_pos = if (self.read_pos < self.transport.to_client.items.len)
                self.read_pos
            else
                self.read_pos - self.transport.to_client.items.len;

            if (start_pos >= buffer.items.len) return null;

            const remaining = buffer.items[start_pos..];
            if (std.mem.indexOfScalar(u8, remaining, '\n')) |nl_pos| {
                const line_end = start_pos + nl_pos;
                const line = buffer.items[start_pos..line_end];
                const result = try allocator.dupe(u8, line);
                self.read_pos = line_end + 1;
                return result;
            }
            return null;
        }
    };
};

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

            // Poll the provider's event stream
            if (active_stream.event_stream.poll()) |event| {
                // Create an envelope with the event
                const seq = self.server.getNextSequence(stream_id);
                var env = protocol_types.Envelope{
                    .stream_id = stream_id,
                    .message_id = protocol_types.generateUuid(),
                    .sequence = seq,
                    .timestamp = std.time.milliTimestamp(),
                    .payload = .{ .event = event },
                };
                defer env.deinit(self.allocator);

                // Serialize and send to client
                const json = try envelope.serializeEnvelope(env, self.allocator);
                defer self.allocator.free(json);

                var sender = self.pipe.serverSender();
                try sender.write(json);
                try sender.flush();

                events_forwarded += 1;
            }

            // Check if stream is done
            if (active_stream.event_stream.isDone()) {
                // Send done event if we haven't already
                if (active_stream.event_stream.getResult()) |result| {
                    const seq = self.server.getNextSequence(stream_id);
                    var env = protocol_types.Envelope{
                        .stream_id = stream_id,
                        .message_id = protocol_types.generateUuid(),
                        .sequence = seq,
                        .timestamp = std.time.milliTimestamp(),
                        .payload = .{ .result = result },
                    };
                    defer env.deinit(self.allocator);

                    const json = try envelope.serializeEnvelope(env, self.allocator);
                    defer self.allocator.free(json);

                    var sender = self.pipe.serverSender();
                    try sender.write(json);
                    try sender.flush();
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
    var pipe = PipeTransport.init(allocator);
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

    // Create stream request envelope
    const stream_id = protocol_types.generateUuid();
    const message_id = protocol_types.generateUuid();

    var stream_req_env = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = message_id,
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = ctx,
            .options = .{
                .api_key = api_key,
                .max_tokens = 50,
                .temperature = 0.0,
            },
        } },
    };
    defer stream_req_env.deinit(allocator);

    // Serialize and send through client
    const req_json = try envelope.serializeEnvelope(stream_req_env, allocator);
    defer allocator.free(req_json);

    var sender = pipe.clientSender();
    try sender.write(req_json);
    try sender.flush();

    // Process the request through server
    var pump = ProtocolPump{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };

    // Process client -> server message
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

        // Check client's event stream for events
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
    var pipe = PipeTransport.init(allocator);
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

    // Create and send stream request
    const stream_id = protocol_types.generateUuid();
    const message_id = protocol_types.generateUuid();

    var stream_req_env = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = message_id,
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = ctx,
            .options = .{
                .api_key = api_key,
                .max_tokens = 500,
            },
        } },
    };
    defer stream_req_env.deinit(allocator);

    const req_json = try envelope.serializeEnvelope(stream_req_env, allocator);
    defer allocator.free(req_json);

    var sender = pipe.clientSender();
    try sender.write(req_json);
    try sender.flush();

    // Set up pump
    var pump = ProtocolPump{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };

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

        if (client.getEventStream().poll()) |_| {
            event_count += 1;
        }

        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Get the stream_id from the client
    const current_stream_id = client.getCurrentStreamId() orelse return error.NoActiveStream;

    // Create abort request envelope
    client.sequence = 2; // Next sequence
    var abort_env = protocol_types.Envelope{
        .stream_id = current_stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .abort_request = .{
            .target_stream_id = current_stream_id,
            .reason = null,
        } },
    };
    defer abort_env.deinit(allocator);

    const abort_json = try envelope.serializeEnvelope(abort_env, allocator);
    defer allocator.free(abort_json);

    try sender.write(abort_json);
    try sender.flush();

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

    var creds = (try test_helpers.getGitHubCopilotCredentials(allocator)) orelse return error.SkipZigTest;
    defer creds.deinit(allocator);

    // Set up pipe transport
    var pipe = PipeTransport.init(allocator);
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

    // Create and send stream request
    const stream_id = protocol_types.generateUuid();
    const message_id = protocol_types.generateUuid();

    var stream_req_env = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = message_id,
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = ctx,
            .options = .{
                .api_key = creds.copilot_token,
                .session_id = "test-session",
                .max_tokens = 50,
                .temperature = 0.0,
            },
        } },
    };
    defer stream_req_env.deinit(allocator);

    const req_json = try envelope.serializeEnvelope(stream_req_env, allocator);
    defer allocator.free(req_json);

    var sender = pipe.clientSender();
    try sender.write(req_json);
    try sender.flush();

    // Set up pump
    var pump = ProtocolPump{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };

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

    var creds = (try test_helpers.getGitHubCopilotCredentials(allocator)) orelse return error.SkipZigTest;
    defer creds.deinit(allocator);

    // Set up pipe transport
    var pipe = PipeTransport.init(allocator);
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

    // Create and send stream request
    const stream_id = protocol_types.generateUuid();
    const message_id = protocol_types.generateUuid();

    var stream_req_env = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = message_id,
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = ctx,
            .options = .{
                .api_key = creds.copilot_token,
                .session_id = "test-session",
                .max_tokens = 500,
            },
        } },
    };
    defer stream_req_env.deinit(allocator);

    const req_json = try envelope.serializeEnvelope(stream_req_env, allocator);
    defer allocator.free(req_json);

    var sender = pipe.clientSender();
    try sender.write(req_json);
    try sender.flush();

    // Set up pump
    var pump = ProtocolPump{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };

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

        if (client.getEventStream().poll()) |_| {
            event_count += 1;
        }

        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Get the stream_id from the client
    const current_stream_id = client.getCurrentStreamId() orelse return error.NoActiveStream;

    // Create abort request envelope
    var abort_env = protocol_types.Envelope{
        .stream_id = current_stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .abort_request = .{
            .target_stream_id = current_stream_id,
            .reason = null,
        } },
    };
    defer abort_env.deinit(allocator);

    const abort_json = try envelope.serializeEnvelope(abort_env, allocator);
    defer allocator.free(abort_json);

    try sender.write(abort_json);
    try sender.flush();

    // Process abort request
    try pump.pumpClientMessages();

    // Verify stream was removed
    try testing.expect(server.activeStreamCount() == 0);

    // Verify we got at least one event before abort
    try testing.expect(event_count >= 1);

    test_helpers.testSuccess("Protocol: GitHub Copilot abort through protocol layer");
}
