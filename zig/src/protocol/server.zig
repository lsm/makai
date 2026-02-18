const std = @import("std");
const protocol_types = @import("types.zig");
const envelope = @import("envelope.zig");
const partial_serializer = @import("partial_serializer.zig");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const event_stream = @import("event_stream");

/// Errors for sequence validation
pub const SequenceError = error{
    InvalidSequence,
    DuplicateSequence,
    SequenceGap,
};

/// Validate incoming sequence number
fn validateSequence(expected: u64, received: u64) SequenceError!void {
    if (received == 0) return error.InvalidSequence;
    if (received < expected) return error.DuplicateSequence;
    if (received > expected) return error.SequenceGap;
    // received == expected is OK
}

/// Server-side protocol handler for the Makai Wire Protocol
///
/// Current Limitation (v1.0): The server creates streams and returns ACK but does
/// not yet forward stream events as protocol envelopes. Event forwarding requires
/// integration with the async runtime to poll provider streams and wrap events.
/// This is planned for v2.0.
pub const ProtocolServer = struct {
    allocator: std.mem.Allocator,

    /// Active streams by stream_id
    /// NOTE: While this map supports multiple streams, event forwarding is not
    /// yet implemented. The server currently handles stream creation/abortion
    /// but does not poll and forward events from provider streams.
    active_streams: std.AutoHashMap(protocol_types.Uuid, ActiveStream),

    /// API registry for provider lookup
    registry: *api_registry.ApiRegistry,

    /// Sequence counter per stream (outgoing)
    sequence_counters: std.AutoHashMap(protocol_types.Uuid, u64),

    /// Expected next sequence number per stream (incoming)
    expected_sequences: std.AutoHashMap(protocol_types.Uuid, u64),

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
        include_partial: bool = false,
        max_streams: usize = 100,
        stream_timeout_ms: u64 = 300_000,
    };

    pub fn init(allocator: std.mem.Allocator, registry: *api_registry.ApiRegistry, options: Options) ProtocolServer {
        return .{
            .allocator = allocator,
            .active_streams = std.AutoHashMap(protocol_types.Uuid, ActiveStream).init(allocator),
            .registry = registry,
            .sequence_counters = std.AutoHashMap(protocol_types.Uuid, u64).init(allocator),
            .expected_sequences = std.AutoHashMap(protocol_types.Uuid, u64).init(allocator),
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
        self.expected_sequences.deinit();
    }

    /// Handle incoming envelope, optionally return response envelope
    pub fn handleEnvelope(self: *ProtocolServer, env: protocol_types.Envelope) !?protocol_types.Envelope {
        switch (env.payload) {
            .stream_request => |req| {
                return try handleStreamRequest(self, req, env.message_id, env.sequence);
            },
            .abort_request => |req| {
                return try handleAbortRequest(self, req, env.message_id, env.sequence);
            },
            .complete_request => |req| {
                return try handleCompleteRequest(self, req, env.message_id, env.sequence);
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
            _ = self.expected_sequences.remove(stream_id);
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

    /// Validate and update expected sequence for incoming message
    fn validateAndUpdateSequence(self: *ProtocolServer, stream_id: protocol_types.Uuid, received: u64) SequenceError!void {
        const expected = self.expected_sequences.get(stream_id) orelse 1;
        try validateSequence(expected, received);
        // Update expected sequence for next message
        self.expected_sequences.put(stream_id, received + 1) catch {};
    }
};

/// Handle stream_request - create stream, return ack with stream_id
fn handleStreamRequest(server: *ProtocolServer, request: protocol_types.StreamRequest, in_reply_to: protocol_types.Uuid, received_seq: u64) !protocol_types.Envelope {
    // Check max streams limit
    if (server.active_streams.count() >= server.options.max_streams) {
        return try envelope.createNack(
            .{
                .stream_id = protocol_types.generateUuid(),
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            "Maximum concurrent streams limit reached",
            .rate_limited,
            server.allocator,
        );
    }

    // Look up provider in registry using model.api
    const provider = server.registry.getApiProvider(request.model.api) orelse {
        return try envelope.createNack(
            .{
                .stream_id = protocol_types.generateUuid(),
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            "Provider not found for API",
            .provider_error,
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
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            err_msg,
            .provider_error,
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

    // Initialize sequence counter (outgoing)
    try server.sequence_counters.put(stream_id, 0);

    // Initialize expected sequence for incoming messages (starts at 1)
    // The first message for a new stream should have sequence 1
    try server.expected_sequences.put(stream_id, received_seq + 1);

    // Return ack with acknowledged_id
    return .{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .in_reply_to = in_reply_to,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .ack = .{
            .acknowledged_id = in_reply_to,
        } },
    };
}

/// Handle abort_request - cancel stream, return ack
fn handleAbortRequest(server: *ProtocolServer, request: protocol_types.AbortRequest, in_reply_to: protocol_types.Uuid, received_seq: u64) !protocol_types.Envelope {
    // Validate sequence for existing stream
    if (server.expected_sequences.get(request.target_stream_id)) |expected| {
        try validateSequence(expected, received_seq);
    }

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

        // Get sequence BEFORE removing counter, then remove
        const seq = server.nextSequence(request.target_stream_id);
        _ = server.sequence_counters.remove(request.target_stream_id);
        _ = server.expected_sequences.remove(request.target_stream_id);

        // Return ack
        return .{
            .stream_id = request.target_stream_id,
            .message_id = protocol_types.generateUuid(),
            .sequence = seq,
            .in_reply_to = in_reply_to,
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .ack = .{
                .acknowledged_id = in_reply_to,
            } },
        };
    } else {
        // Stream not found - return nack
        return try envelope.createNack(
            .{
                .stream_id = request.target_stream_id,
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            "Stream not found",
            .stream_not_found,
            server.allocator,
        );
    }
}

/// Handle complete_request - get final result
fn handleCompleteRequest(server: *ProtocolServer, request: protocol_types.CompleteRequest, in_reply_to: protocol_types.Uuid, received_seq: u64) !protocol_types.Envelope {
    _ = received_seq; // Complete requests are one-shot, no sequence validation needed

    // For complete_request, we use the stream_id from the envelope
    // Since CompleteRequest doesn't have a target_stream_id, we need to find
    // a stream for this model/context combination, or create one for non-streaming

    // Look up provider
    const provider = server.registry.getApiProvider(request.model.api) orelse {
        return try envelope.createNack(
            .{
                .stream_id = protocol_types.generateUuid(),
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            "Provider not found for API",
            .provider_error,
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
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            err_msg,
            .provider_error,
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
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            err_msg,
            .provider_error,
            server.allocator,
        );
    } else {
        // Timeout or unknown error
        return try envelope.createNack(
            .{
                .stream_id = protocol_types.generateUuid(),
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            "Stream did not complete in time",
            .internal_error,
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
    try std.testing.expectEqual(protocol_types.ErrorCode.provider_error, response.?.payload.nack.error_code.?);

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

    const msg_id = protocol_types.generateUuid();
    var stream_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = msg_id,
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
    try std.testing.expectEqualSlices(u8, &msg_id, &response.?.payload.ack.acknowledged_id);

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
    const stream_id = create_response.?.stream_id;

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
    try std.testing.expectEqual(protocol_types.ErrorCode.stream_not_found, response.?.payload.nack.error_code.?);
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
    try std.testing.expectEqual(protocol_types.ErrorCode.rate_limited, resp3.?.payload.nack.error_code.?);
    req3.deinit(std.testing.allocator);
    if (resp3) |*r| r.deinit(std.testing.allocator);
}

test "validateSequence accepts correct sequence" {
    try validateSequence(1, 1);
    try validateSequence(5, 5);
}

test "validateSequence rejects zero sequence" {
    try std.testing.expectError(error.InvalidSequence, validateSequence(1, 0));
}

test "validateSequence rejects duplicate sequence" {
    try std.testing.expectError(error.DuplicateSequence, validateSequence(5, 3));
    try std.testing.expectError(error.DuplicateSequence, validateSequence(5, 4));
}

test "validateSequence rejects sequence gap" {
    try std.testing.expectError(error.SequenceGap, validateSequence(5, 6));
    try std.testing.expectError(error.SequenceGap, validateSequence(5, 10));
}
