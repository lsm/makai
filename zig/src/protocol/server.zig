const std = @import("std");
const protocol_types = @import("types.zig");
const envelope = @import("envelope.zig");
const partial_serializer = @import("partial_serializer.zig");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const event_stream = @import("event_stream");

pub const ProtocolServer = struct {
    allocator: std.mem.Allocator,

    /// Active streams by stream_id
    active_streams: std.AutoHashMap(protocol_types.Uuid, ActiveStream),

    /// API registry for provider lookup
    registry: *api_registry.ApiRegistry,

    /// Sequence counter per stream
    sequence_counters: std.AutoHashMap(protocol_types.Uuid, u64),

    /// Options
    options: Options,

    pub const ActiveStream = struct {
        stream_id: protocol_types.Uuid,
        model: ai_types.Model,
        event_stream: *event_stream.AssistantMessageEventStream,
        partial_state: partial_serializer.PartialState,
        started_at: i64,
    };

    pub const Options = struct {
        include_partial: bool = true,
        max_streams: usize = 100,
        stream_timeout_ms: u64 = 300_000,
    };

    pub fn init(allocator: std.mem.Allocator, registry: *api_registry.ApiRegistry, options: Options) ProtocolServer {
        return .{
            .allocator = allocator,
            .active_streams = std.AutoHashMap(protocol_types.Uuid, ActiveStream).init(allocator),
            .registry = registry,
            .sequence_counters = std.AutoHashMap(protocol_types.Uuid, u64).init(allocator),
            .options = options,
        };
    }

    pub fn deinit(self: *ProtocolServer) void {
        // Clean up all active streams
        var iter = self.active_streams.iterator();
        while (iter.next()) |entry| {
            var active_stream = entry.value_ptr.*;
            active_stream.partial_state.deinit();
            // Clean up the event stream
            active_stream.event_stream.deinit();
            self.allocator.destroy(active_stream.event_stream);
        }
        self.active_streams.deinit();
        self.sequence_counters.deinit();
    }

    /// Handle incoming envelope, optionally return response envelope
    pub fn handleEnvelope(self: *ProtocolServer, env: protocol_types.Envelope) !?protocol_types.Envelope {
        switch (env.payload) {
            .stream_request => |req| {
                return try handleStreamRequest(self, req, env.message_id);
            },
            .abort_request => |req| {
                return try handleAbortRequest(self, req, env.message_id);
            },
            .complete_request => |req| {
                return try handleCompleteRequest(self, req, env.message_id);
            },
            .ack, .nack, .event, .result, .stream_error => {
                // Server receives these from clients - no response needed
                return null;
            },
            .ping => {
                // Respond with pong
                return envelope.createReply(env, .pong, self.allocator);
            },
            .pong => {
                // No response to pong
                return null;
            },
        }
    }

    /// Clean up completed streams
    pub fn cleanupCompletedStreams(self: *ProtocolServer) void {
        var to_remove = std.ArrayList(protocol_types.Uuid).initCapacity(self.allocator, 16) catch return;
        defer to_remove.deinit(self.allocator);

        var iter = self.active_streams.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.event_stream.isDone()) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |stream_id| {
            if (self.active_streams.fetchRemove(stream_id)) |removed| {
                var partial = removed.value.partial_state;
                partial.deinit();
                // Clean up the event stream
                removed.value.event_stream.deinit();
                self.allocator.destroy(removed.value.event_stream);
            }
            _ = self.sequence_counters.remove(stream_id);
        }
    }

    /// Get active stream count
    pub fn activeStreamCount(self: *ProtocolServer) usize {
        return self.active_streams.count();
    }

    /// Get next sequence number for a stream
    fn nextSequence(self: *ProtocolServer, stream_id: protocol_types.Uuid) u64 {
        const current = self.sequence_counters.get(stream_id) orelse 0;
        const next = current + 1;
        self.sequence_counters.put(stream_id, next) catch return next;
        return next;
    }
};

/// Handle stream_request - create stream, return ack with stream_id
fn handleStreamRequest(server: *ProtocolServer, request: protocol_types.StreamRequest, in_reply_to: protocol_types.Uuid) !protocol_types.Envelope {
    // Check max streams limit
    if (server.active_streams.count() >= server.options.max_streams) {
        return try envelope.createNack(
            .{
                .stream_id = protocol_types.generateUuid(),
                .message_id = protocol_types.generateUuid(),
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            .rate_limited,
            "Maximum concurrent streams limit reached",
            server.allocator,
        );
    }

    // Look up provider in registry using model.api
    const provider = server.registry.getApiProvider(request.model.api) orelse {
        return try envelope.createNack(
            .{
                .stream_id = protocol_types.generateUuid(),
                .message_id = protocol_types.generateUuid(),
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            .provider_error,
            "Provider not found for API",
            server.allocator,
        );
    };

    // Create new stream via provider.stream()
    const stream = provider.stream(request.model, request.context, request.options, server.allocator) catch |err| {
        const err_msg = switch (err) {
            error.OutOfMemory => "Out of memory",
            else => "Failed to create stream",
        };
        return try envelope.createNack(
            .{
                .stream_id = protocol_types.generateUuid(),
                .message_id = protocol_types.generateUuid(),
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            .provider_error,
            err_msg,
            server.allocator,
        );
    };

    // Generate stream_id
    const stream_id = protocol_types.generateUuid();

    // Create ActiveStream entry
    const active_stream = ProtocolServer.ActiveStream{
        .stream_id = stream_id,
        .model = request.model,
        .event_stream = stream,
        .partial_state = partial_serializer.PartialState.init(server.allocator),
        .started_at = std.time.milliTimestamp(),
    };

    // Store in active_streams
    try server.active_streams.put(stream_id, active_stream);

    // Initialize sequence counter
    try server.sequence_counters.put(stream_id, 0);

    // Return ack with stream_id
    return .{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .in_reply_to = in_reply_to,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .ack = .{
            .in_reply_to = in_reply_to,
            .stream_id = stream_id,
        } },
    };
}

/// Handle abort_request - cancel stream, return ack
fn handleAbortRequest(server: *ProtocolServer, request: protocol_types.AbortRequest, in_reply_to: protocol_types.Uuid) !protocol_types.Envelope {
    // Find stream by stream_id
    if (server.active_streams.fetchRemove(request.target_stream_id)) |removed| {
        // Complete the stream with an error
        const reason = request.reason orelse "Stream aborted";
        removed.value.event_stream.completeWithError(reason);

        // Clean up - need to copy to mutable for deinit
        var partial = removed.value.partial_state;
        partial.deinit();
        removed.value.event_stream.deinit();
        server.allocator.destroy(removed.value.event_stream);

        _ = server.sequence_counters.remove(request.target_stream_id);

        // Return ack
        return .{
            .stream_id = request.target_stream_id,
            .message_id = protocol_types.generateUuid(),
            .sequence = server.nextSequence(request.target_stream_id),
            .in_reply_to = in_reply_to,
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .ack = .{
                .in_reply_to = in_reply_to,
                .stream_id = request.target_stream_id,
            } },
        };
    } else {
        // Stream not found - return nack
        return try envelope.createNack(
            .{
                .stream_id = request.target_stream_id,
                .message_id = protocol_types.generateUuid(),
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            .stream_not_found,
            "Stream not found",
            server.allocator,
        );
    }
}

/// Handle complete_request - get final result
fn handleCompleteRequest(server: *ProtocolServer, request: protocol_types.CompleteRequest, in_reply_to: protocol_types.Uuid) !protocol_types.Envelope {
    // For complete_request, we use the stream_id from the envelope
    // Since CompleteRequest doesn't have a target_stream_id, we need to find
    // a stream for this model/context combination, or create one for non-streaming

    // Look up provider
    const provider = server.registry.getApiProvider(request.model.api) orelse {
        return try envelope.createNack(
            .{
                .stream_id = protocol_types.generateUuid(),
                .message_id = protocol_types.generateUuid(),
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            .provider_error,
            "Provider not found for API",
            server.allocator,
        );
    };

    // Create a stream for non-streaming completion
    const stream = provider.stream(request.model, request.context, request.options, server.allocator) catch |err| {
        const err_msg = switch (err) {
            error.OutOfMemory => "Out of memory",
            else => "Failed to create stream",
        };
        return try envelope.createNack(
            .{
                .stream_id = protocol_types.generateUuid(),
                .message_id = protocol_types.generateUuid(),
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            .provider_error,
            err_msg,
            server.allocator,
        );
    };

    // Wait for stream to complete (with timeout)
    const timeout_ms = server.options.stream_timeout_ms;
    _ = stream.waitForThread(timeout_ms);

    // Get result
    if (stream.getResult()) |result| {
        // Clone the result to return (the stream owns the original)
        var cloned_result = try ai_types.cloneAssistantMessage(server.allocator, result);
        cloned_result.owned_strings = true;

        const response_stream_id = protocol_types.generateUuid();
        return .{
            .stream_id = response_stream_id,
            .message_id = protocol_types.generateUuid(),
            .sequence = 1,
            .in_reply_to = in_reply_to,
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .result = cloned_result },
        };
    } else if (stream.getError()) |err_msg| {
        // Return error as nack
        return try envelope.createNack(
            .{
                .stream_id = protocol_types.generateUuid(),
                .message_id = protocol_types.generateUuid(),
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            .provider_error,
            err_msg,
            server.allocator,
        );
    } else {
        // Timeout or unknown error
        return try envelope.createNack(
            .{
                .stream_id = protocol_types.generateUuid(),
                .message_id = protocol_types.generateUuid(),
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            .internal_error,
            "Stream did not complete in time",
            server.allocator,
        );
    }
}

// Tests

fn mockStream(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = context;
    _ = options;
    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);

    // Complete immediately for tests
    const result = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = std.time.milliTimestamp(),
    };
    s.complete(result);
    s.markThreadDone();

    return s;
}

fn mockStreamSimple(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = context;
    _ = options;
    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);

    const result = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = std.time.milliTimestamp(),
    };
    s.complete(result);
    s.markThreadDone();

    return s;
}

test "ProtocolServer init and deinit" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    var mut_server = server;
    defer mut_server.deinit();

    try std.testing.expectEqual(@as(usize, 0), mut_server.activeStreamCount());
}

test "handleEnvelope returns pong for ping" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const ping_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .ping,
    };

    const response = try server.handleEnvelope(ping_env);
    try std.testing.expect(response != null);
    try std.testing.expect(response.?.payload == .pong);
}

test "handleEnvelope returns nack for stream_request without provider" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "unknown-api",
        .provider = "unknown",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var stream_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };

    var response = try server.handleEnvelope(stream_req_env);
    try std.testing.expect(response != null);
    try std.testing.expect(response.?.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.provider_error, response.?.payload.nack.error_code);

    stream_req_env.deinit(std.testing.allocator);
    if (response) |*r| r.deinit(std.testing.allocator);
}

test "handleStreamRequest creates stream and returns ack" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = api_registry.ApiProvider{
        .api = "test-api",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var stream_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };

    const response = try server.handleEnvelope(stream_req_env);
    try std.testing.expect(response != null);
    try std.testing.expect(response.?.payload == .ack);
    try std.testing.expect(response.?.payload.ack.stream_id != null);

    // Verify stream was created
    try std.testing.expectEqual(@as(usize, 1), server.activeStreamCount());

    stream_req_env.deinit(std.testing.allocator);
    // ack response doesn't allocate memory, so no need to deinit
}

test "handleAbortRequest cancels stream" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = api_registry.ApiProvider{
        .api = "test-api",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    // First create a stream
    var stream_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };

    const create_response = try server.handleEnvelope(stream_req_env);
    try std.testing.expect(create_response != null);
    const stream_id = create_response.?.payload.ack.stream_id.?;

    stream_req_env.deinit(std.testing.allocator);

    // Now abort the stream
    const abort_env = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .abort_request = .{
            .target_stream_id = stream_id,
            .reason = null,
        } },
    };

    const abort_response = try server.handleEnvelope(abort_env);
    try std.testing.expect(abort_response != null);
    try std.testing.expect(abort_response.?.payload == .ack);

    // Verify stream was removed
    try std.testing.expectEqual(@as(usize, 0), server.activeStreamCount());
}

test "handleAbortRequest returns nack for unknown stream" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const unknown_stream_id = protocol_types.generateUuid();

    const abort_env = protocol_types.Envelope{
        .stream_id = unknown_stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .abort_request = .{
            .target_stream_id = unknown_stream_id,
            .reason = null,
        } },
    };

    var response = try server.handleEnvelope(abort_env);
    try std.testing.expect(response != null);
    try std.testing.expect(response.?.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.stream_not_found, response.?.payload.nack.error_code);
    if (response) |*r| r.deinit(std.testing.allocator);
}

test "cleanupCompletedStreams removes done streams" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = api_registry.ApiProvider{
        .api = "test-api",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    // Create a stream
    var stream_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };

    _ = try server.handleEnvelope(stream_req_env);
    try std.testing.expectEqual(@as(usize, 1), server.activeStreamCount());

    // Mock stream is already complete, so cleanup should remove it
    server.cleanupCompletedStreams();
    try std.testing.expectEqual(@as(usize, 0), server.activeStreamCount());

    stream_req_env.deinit(std.testing.allocator);
}

test "max streams limit enforced" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = api_registry.ApiProvider{
        .api = "test-api",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{
        .max_streams = 2,
    });
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    // Create first stream - should succeed
    var req1 = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };
    const resp1 = try server.handleEnvelope(req1);
    try std.testing.expect(resp1 != null);
    try std.testing.expect(resp1.?.payload == .ack);
    req1.deinit(std.testing.allocator);

    // Create second stream - should succeed
    var req2 = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };
    const resp2 = try server.handleEnvelope(req2);
    try std.testing.expect(resp2 != null);
    try std.testing.expect(resp2.?.payload == .ack);
    req2.deinit(std.testing.allocator);

    // Create third stream - should fail with rate_limited
    var req3 = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 3,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };
    var resp3 = try server.handleEnvelope(req3);
    try std.testing.expect(resp3 != null);
    try std.testing.expect(resp3.?.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.rate_limited, resp3.?.payload.nack.error_code);
    req3.deinit(std.testing.allocator);
    if (resp3) |*r| r.deinit(std.testing.allocator);
}
