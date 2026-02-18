const std = @import("std");
const protocol_types = @import("types.zig");
const envelope = @import("envelope.zig");
const partial_reconstructor = @import("partial_reconstructor.zig");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");
const transport = @import("transport");

/// Client-side protocol handler for the Makai Wire Protocol
pub const ProtocolClient = struct {
    // Declarations must come before fields
    pub const PendingRequest = struct {
        message_id: protocol_types.Uuid,
        sent_at: i64,
        timeout_ms: u64,
    };

    pub const Options = struct {
        include_partial: bool = true,
        request_timeout_ms: u64 = 30_000,
    };

    const Self = @This();

    // Fields
    allocator: std.mem.Allocator,

    /// Transport for sending
    sender: ?transport.AsyncSender = null,

    /// Reconstructor for building messages from events
    reconstructor: partial_reconstructor.PartialReconstructor,

    /// Pending requests awaiting ACK/NACK
    pending_requests: std.AutoHashMap(protocol_types.Uuid, PendingRequest),

    /// Current stream ID (if streaming)
    current_stream_id: ?protocol_types.Uuid = null,

    /// Event stream for consuming events
    event_stream: *event_stream.AssistantMessageEventStream,

    /// Last received result (from done event or result envelope)
    last_result: ?ai_types.AssistantMessage = null,

    /// Last error message (from NACK or stream_error)
    last_error: ?[]const u8 = null,

    /// Whether the stream is complete
    stream_complete: bool = false,

    /// Sequence number for outgoing messages
    sequence: u64 = 0,

    options: Options,

    /// Initialize a new ProtocolClient
    pub fn init(allocator: std.mem.Allocator, options: Options) Self {
        const es = allocator.create(event_stream.AssistantMessageEventStream) catch unreachable;
        es.* = event_stream.AssistantMessageEventStream.init(allocator);
        return .{
            .allocator = allocator,
            .reconstructor = partial_reconstructor.PartialReconstructor.init(allocator),
            .pending_requests = std.AutoHashMap(protocol_types.Uuid, PendingRequest).init(allocator),
            .event_stream = es,
            .options = options,
        };
    }

    /// Deinitialize the ProtocolClient
    pub fn deinit(self: *Self) void {
        // Clean up pending requests
        self.pending_requests.deinit();

        // Clean up reconstructor
        self.reconstructor.deinit();

        // Clean up event stream
        self.event_stream.deinit();
        self.allocator.destroy(self.event_stream);

        // Clean up last result
        if (self.last_result) |*result| {
            result.deinit(self.allocator);
        }

        // Clean up last error
        if (self.last_error) |err| {
            self.allocator.free(err);
        }
    }

    /// Set the transport sender
    pub fn setSender(self: *Self, sender: transport.AsyncSender) void {
        self.sender = sender;
    }

    /// Send stream_request, returns message_id for correlation
    pub fn sendStreamRequest(
        self: *Self,
        model: ai_types.Model,
        context: ai_types.Context,
        options: ?ai_types.StreamOptions,
    ) !protocol_types.Uuid {
        if (self.sender == null) {
            return error.NoSender;
        }

        const message_id = protocol_types.generateUuid();
        self.sequence += 1;

        const stream_id = self.current_stream_id orelse message_id;

        const payload = protocol_types.Payload{
            .stream_request = .{
                .model = model,
                .context = context,
                .options = options,
                .include_partial = self.options.include_partial,
            },
        };

        var env = protocol_types.Envelope{
            .stream_id = stream_id,
            .message_id = message_id,
            .sequence = self.sequence,
            .timestamp = std.time.milliTimestamp(),
            .payload = payload,
        };
        defer env.deinit(self.allocator);

        const json = try envelope.serializeEnvelope(env, self.allocator);
        defer self.allocator.free(json);

        try self.sender.?.write(json);
        try self.sender.?.flush();

        // Store pending request
        try self.pending_requests.put(message_id, .{
            .message_id = message_id,
            .sent_at = std.time.milliTimestamp(),
            .timeout_ms = self.options.request_timeout_ms,
        });

        return message_id;
    }

    /// Send abort_request for current stream
    pub fn sendAbortRequest(self: *Self, reason: ?[]const u8) !void {
        if (self.sender == null) {
            return error.NoSender;
        }

        if (self.current_stream_id == null) {
            return error.NoActiveStream;
        }

        self.sequence += 1;

        const reason_dup = if (reason) |r| try self.allocator.dupe(u8, r) else null;

        const payload = protocol_types.Payload{
            .abort_request = .{
                .target_stream_id = self.current_stream_id.?,
                .reason = reason_dup,
            },
        };

        var env = protocol_types.Envelope{
            .stream_id = self.current_stream_id.?,
            .message_id = protocol_types.generateUuid(),
            .sequence = self.sequence,
            .timestamp = std.time.milliTimestamp(),
            .payload = payload,
        };
        defer env.deinit(self.allocator);

        const json = try envelope.serializeEnvelope(env, self.allocator);
        defer self.allocator.free(json);

        try self.sender.?.write(json);
        try self.sender.?.flush();
    }

    /// Process incoming envelope from server
    pub fn processEnvelope(self: *Self, env: protocol_types.Envelope) !void {
        switch (env.payload) {
            .ack => |ack| {
                // Correlate with pending request
                if (self.pending_requests.fetchRemove(ack.in_reply_to)) |_| {
                    // Request acknowledged
                    if (ack.stream_id) |sid| {
                        self.current_stream_id = sid;
                    }
                }
            },
            .nack => |nack| {
                // Mark request as failed
                _ = self.pending_requests.fetchRemove(nack.in_reply_to);

                // Store error
                if (self.last_error) |err| {
                    self.allocator.free(err);
                }
                self.last_error = try self.allocator.dupe(u8, nack.message);
            },
            .event => |evt| {
                // Push to event stream for polling
                try self.event_stream.push(evt);

                // Process through reconstructor
                try self.reconstructor.processEvent(evt);

                // Check for done event
                if (evt == .done) {
                    self.stream_complete = true;

                    // Build final message from reconstructor
                    const result = try self.reconstructor.buildMessage(
                        evt.done.reason,
                        evt.done.message.timestamp,
                    );

                    // Clean up previous result
                    if (self.last_result) |*prev| {
                        prev.deinit(self.allocator);
                    }
                    self.last_result = result;
                }
            },
            .result => |result| {
                // Store as last result
                if (self.last_result) |*prev| {
                    prev.deinit(self.allocator);
                }

                // Deep copy the result
                self.last_result = try ai_types.cloneAssistantMessage(self.allocator, result);
                self.stream_complete = true;
            },
            .stream_error => |err| {
                // Store error
                if (self.last_error) |e| {
                    self.allocator.free(e);
                }
                self.last_error = try self.allocator.dupe(u8, err.message);
                self.stream_complete = true;

                // Complete the event stream with error
                self.event_stream.completeWithError(err.message);
            },
            .pong => {
                // No-op for pong
            },
            else => {
                // Ignore other payload types
            },
        }
    }

    /// Get the event stream for consuming events
    pub fn getEventStream(self: *Self) *event_stream.AssistantMessageEventStream {
        return self.event_stream;
    }

    /// Get last result (blocking wait if not ready)
    pub fn waitResult(self: *Self, timeout_ms: u64) !?ai_types.AssistantMessage {
        const start_time = std.time.milliTimestamp();
        const deadline = start_time + @as(i64, @intCast(timeout_ms));

        while (!self.stream_complete) {
            if (std.time.milliTimestamp() >= deadline) {
                return error.TimeoutExceeded;
            }

            // Check for errors
            if (self.last_error) |_| {
                return error.StreamError;
            }

            // Wait for more events
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }

        // Check for error
        if (self.last_error) |_| {
            return error.StreamError;
        }

        return self.last_result;
    }

    /// Check if stream is complete
    pub fn isComplete(self: *Self) bool {
        return self.stream_complete;
    }

    /// Reset for a new stream
    pub fn reset(self: *Self) void {
        self.reconstructor.reset();
        self.pending_requests.clearRetainingCapacity();
        self.current_stream_id = null;
        self.stream_complete = false;
        self.sequence = 0;

        if (self.last_result) |*result| {
            result.deinit(self.allocator);
            self.last_result = null;
        }

        if (self.last_error) |err| {
            self.allocator.free(err);
            self.last_error = null;
        }
    }

    /// Get the current stream ID
    pub fn getCurrentStreamId(self: *Self) ?protocol_types.Uuid {
        return self.current_stream_id;
    }

    /// Get the last error message
    pub fn getLastError(self: *Self) ?[]const u8 {
        return self.last_error;
    }
};

// Custom error set
pub const ClientError = error{
    NoSender,
    NoActiveStream,
    TimeoutExceeded,
    StreamError,
};

// =============================================================================
// Tests
// =============================================================================

test "ProtocolClient init and deinit" {
    const allocator = std.testing.allocator;

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    try std.testing.expect(client.sender == null);
    try std.testing.expect(client.current_stream_id == null);
    try std.testing.expect(!client.stream_complete);
}

test "sendStreamRequest creates valid envelope" {
    const allocator = std.testing.allocator;

    // Create a mock sender that captures the written data
    var written_data: ?[]const u8 = null;

    const MockSender = struct {
        captured: *?[]const u8,

        fn writeFn(ctx: *anyopaque, data: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.captured.* = try std.testing.allocator.dupe(u8, data);
        }

        fn flushFn(_: *anyopaque) !void {}
    };

    var mock = MockSender{ .captured = &written_data };
    const sender = transport.AsyncSender{
        .context = @ptrCast(&mock),
        .write_fn = MockSender.writeFn,
        .flush_fn = MockSender.flushFn,
    };

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    client.setSender(sender);

    const model = ai_types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    const context = ai_types.Context{
        .messages = &.{},
    };

    const message_id = try client.sendStreamRequest(model, context, null);

    // Verify message_id was returned
    try std.testing.expect(!std.mem.allEqual(u8, &message_id, 0));

    // Verify data was written
    try std.testing.expect(written_data != null);
    defer if (written_data) |d| std.testing.allocator.free(d);

    // Parse and verify the envelope
    var env = try envelope.deserializeEnvelope(written_data.?, allocator);

    try std.testing.expect(env.payload == .stream_request);
    try std.testing.expectEqualStrings("gpt-4", env.payload.stream_request.model.id);
    try std.testing.expectEqualSlices(u8, &message_id, &env.message_id);

    // Manually free the allocated model strings (StreamRequest.deinit is a no-op)
    allocator.free(env.payload.stream_request.model.id);
    allocator.free(env.payload.stream_request.model.name);
    allocator.free(env.payload.stream_request.model.api);
    allocator.free(env.payload.stream_request.model.provider);
    allocator.free(env.payload.stream_request.model.base_url);
}

test "processEnvelope handles ack" {
    const allocator = std.testing.allocator;

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    // Add a pending request
    const message_id = protocol_types.generateUuid();
    try client.pending_requests.put(message_id, .{
        .message_id = message_id,
        .sent_at = std.time.milliTimestamp(),
        .timeout_ms = 30_000,
    });

    // Create an ack envelope
    const stream_id = protocol_types.generateUuid();
    const env = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .ack = .{
            .in_reply_to = message_id,
            .stream_id = stream_id,
        } },
    };

    try client.processEnvelope(env);

    // Verify pending request was removed
    try std.testing.expect(!client.pending_requests.contains(message_id));

    // Verify stream_id was set
    try std.testing.expect(client.current_stream_id != null);
    try std.testing.expectEqualSlices(u8, &stream_id, &client.current_stream_id.?);
}

test "processEnvelope handles nack" {
    const allocator = std.testing.allocator;

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    // Add a pending request
    const message_id = protocol_types.generateUuid();
    try client.pending_requests.put(message_id, .{
        .message_id = message_id,
        .sent_at = std.time.milliTimestamp(),
        .timeout_ms = 30_000,
    });

    // Create a nack envelope
    const nack_msg = try allocator.dupe(u8, "Model not found");
    // Note: nack_msg ownership is transferred to envelope, will be freed by env.deinit()

    var env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .nack = .{
            .in_reply_to = message_id,
            .error_code = .model_not_found,
            .message = nack_msg,
        } },
    };

    try client.processEnvelope(env);

    // Verify pending request was removed
    try std.testing.expect(!client.pending_requests.contains(message_id));

    // Verify error was stored
    try std.testing.expect(client.last_error != null);
    try std.testing.expectEqualStrings("Model not found", client.last_error.?);

    env.deinit(allocator);
}

test "processEnvelope handles events" {
    const allocator = std.testing.allocator;

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    // Create a start event
    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    var env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .event = .{ .start = .{ .partial = partial } } },
    };

    try client.processEnvelope(env);

    // Verify event was pushed to stream
    const evt = client.event_stream.poll();
    try std.testing.expect(evt != null);
    try std.testing.expect(evt.? == .start);

    env.deinit(allocator);
}

test "processEnvelope accumulates to reconstructor" {
    const allocator = std.testing.allocator;

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    // Send start event
    var env1 = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .event = .{ .start = .{ .partial = partial } } },
    };
    try client.processEnvelope(env1);
    env1.deinit(allocator);

    // Send text_start event
    var env2 = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .event = .{ .text_start = .{ .content_index = 0, .partial = partial } } },
    };
    try client.processEnvelope(env2);
    env2.deinit(allocator);

    // Send text_delta event
    // Note: delta_str ownership is transferred to envelope, will be freed by env3.deinit()
    const delta_str = try allocator.dupe(u8, "Hello");

    var env3 = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 3,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .event = .{ .text_delta = .{
            .content_index = 0,
            .delta = delta_str,
            .partial = partial,
        } } },
    };
    try client.processEnvelope(env3);
    env3.deinit(allocator);

    // Verify reconstructor has accumulated text
    try std.testing.expectEqual(@as(usize, 1), client.reconstructor.content_blocks.count());
}

test "waitResult returns final message" {
    const allocator = std.testing.allocator;

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    // Set a pre-built result
    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "Final response" } }};
    client.last_result = try ai_types.cloneAssistantMessage(allocator, .{
        .content = &content,
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 12345,
    });
    client.stream_complete = true;

    const result = try client.waitResult(1000);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("test-model", result.?.model);
}

test "isComplete tracks stream state" {
    const allocator = std.testing.allocator;

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    // Initially not complete
    try std.testing.expect(!client.isComplete());

    // Set complete
    client.stream_complete = true;
    try std.testing.expect(client.isComplete());

    // Reset
    client.reset();
    try std.testing.expect(!client.isComplete());
}

test "sendAbortRequest sends valid envelope" {
    const allocator = std.testing.allocator;

    var written_data: ?[]const u8 = null;

    const MockSender = struct {
        captured: *?[]const u8,

        fn writeFn(ctx: *anyopaque, data: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.captured.* = try std.testing.allocator.dupe(u8, data);
        }

        fn flushFn(_: *anyopaque) !void {}
    };

    var mock = MockSender{ .captured = &written_data };
    const sender = transport.AsyncSender{
        .context = @ptrCast(&mock),
        .write_fn = MockSender.writeFn,
        .flush_fn = MockSender.flushFn,
    };

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    client.setSender(sender);

    // Set a stream ID first
    client.current_stream_id = protocol_types.generateUuid();

    try client.sendAbortRequest("User cancelled");

    // Verify data was written
    try std.testing.expect(written_data != null);
    defer if (written_data) |d| std.testing.allocator.free(d);

    // Parse and verify the envelope
    var env = try envelope.deserializeEnvelope(written_data.?, allocator);
    defer env.deinit(allocator);

    try std.testing.expect(env.payload == .abort_request);
    try std.testing.expect(env.payload.abort_request.reason != null);
    try std.testing.expectEqualStrings("User cancelled", env.payload.abort_request.reason.?);
}

test "processEnvelope handles done event and builds result" {
    const allocator = std.testing.allocator;

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    // Send start event
    var env1 = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .event = .{ .start = .{ .partial = partial } } },
    };
    try client.processEnvelope(env1);
    env1.deinit(allocator);

    // Send text_start event
    var env2 = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .event = .{ .text_start = .{ .content_index = 0, .partial = partial } } },
    };
    try client.processEnvelope(env2);
    env2.deinit(allocator);

    // Send text_delta event
    // Note: delta_str ownership is transferred to envelope, will be freed by env3.deinit()
    const delta_str = try allocator.dupe(u8, "Hello world");

    var env3 = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 3,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .event = .{ .text_delta = .{
            .content_index = 0,
            .delta = delta_str,
            .partial = partial,
        } } },
    };
    try client.processEnvelope(env3);
    env3.deinit(allocator);

    // Send done event
    const done_msg = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{ .input = 10, .output = 5 },
        .stop_reason = .stop,
        .timestamp = 1000,
    };

    var env4 = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 4,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .event = .{ .done = .{
            .reason = .stop,
            .message = done_msg,
        } } },
    };
    try client.processEnvelope(env4);
    env4.deinit(allocator);

    // Verify stream is complete
    try std.testing.expect(client.isComplete());

    // Verify last_result was built
    try std.testing.expect(client.last_result != null);
    try std.testing.expectEqualStrings("test-model", client.last_result.?.model);
    try std.testing.expectEqual(@as(usize, 1), client.last_result.?.content.len);
}

test "processEnvelope handles result payload" {
    const allocator = std.testing.allocator;

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    // Allocate everything so envelope.deinit can properly free them
    const text_str = try allocator.dupe(u8, "Result text");
    const api_str = try allocator.dupe(u8, "test-api");
    const provider_str = try allocator.dupe(u8, "test-provider");
    const model_str = try allocator.dupe(u8, "test-model");
    const content_slice = try allocator.alloc(ai_types.AssistantContent, 1);
    content_slice[0] = .{ .text = .{ .text = text_str } };

    const result_msg = ai_types.AssistantMessage{
        .content = content_slice,
        .api = api_str,
        .provider = provider_str,
        .model = model_str,
        .usage = .{ .input = 100, .output = 50 },
        .stop_reason = .stop,
        .timestamp = 12345,
        .owned_strings = true,
    };

    var env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .result = result_msg },
    };

    try client.processEnvelope(env);

    // Verify stream is complete
    try std.testing.expect(client.isComplete());

    // Verify last_result was set
    try std.testing.expect(client.last_result != null);
    try std.testing.expectEqualStrings("test-model", client.last_result.?.model);
    try std.testing.expectEqualStrings("Result text", client.last_result.?.content[0].text.text);

    env.deinit(allocator);
}

test "processEnvelope handles stream_error payload" {
    const allocator = std.testing.allocator;

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    // Note: error_msg ownership is transferred to envelope, will be freed by env.deinit()
    const error_msg = try allocator.dupe(u8, "Connection timeout");

    var env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_error = .{
            .code = .provider_error,
            .message = error_msg,
        } },
    };

    try client.processEnvelope(env);

    // Verify stream is complete
    try std.testing.expect(client.isComplete());

    // Verify error was stored
    try std.testing.expect(client.last_error != null);
    try std.testing.expectEqualStrings("Connection timeout", client.last_error.?);

    env.deinit(allocator);
}

test "reset clears all state" {
    const allocator = std.testing.allocator;

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    // Set up some state
    client.current_stream_id = protocol_types.generateUuid();
    client.stream_complete = true;
    client.sequence = 10;

    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "test" } }};
    client.last_result = try ai_types.cloneAssistantMessage(allocator, .{
        .content = &content,
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    });
    client.last_error = try allocator.dupe(u8, "test error");

    // Reset
    client.reset();

    // Verify state is cleared
    try std.testing.expect(client.current_stream_id == null);
    try std.testing.expect(!client.stream_complete);
    try std.testing.expectEqual(@as(u64, 0), client.sequence);
    try std.testing.expect(client.last_result == null);
    try std.testing.expect(client.last_error == null);
}

test "getCurrentStreamId returns correct value" {
    const allocator = std.testing.allocator;

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    // Initially null
    try std.testing.expect(client.getCurrentStreamId() == null);

    // After setting
    const stream_id = protocol_types.generateUuid();
    client.current_stream_id = stream_id;

    const result = client.getCurrentStreamId();
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, &stream_id, &result.?);
}

test "getLastError returns correct value" {
    const allocator = std.testing.allocator;

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    // Initially null
    try std.testing.expect(client.getLastError() == null);

    // After setting
    client.last_error = try allocator.dupe(u8, "Test error");

    const result = client.getLastError();
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Test error", result.?);
}

test "getEventStream returns internal stream" {
    const allocator = std.testing.allocator;

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    const stream = client.getEventStream();
    try std.testing.expect(stream == client.event_stream);
}

test "sendStreamRequest without sender returns error" {
    const allocator = std.testing.allocator;

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    // No sender set
    const model = ai_types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    const context = ai_types.Context{
        .messages = &.{},
    };

    const result = client.sendStreamRequest(model, context, null);
    try std.testing.expectError(error.NoSender, result);
}

test "sendAbortRequest without active stream returns error" {
    const allocator = std.testing.allocator;

    var written_data: ?[]const u8 = null;

    const MockSender = struct {
        captured: *?[]const u8,

        fn writeFn(_: *anyopaque, _: []const u8) !void {}
        fn flushFn(_: *anyopaque) !void {}
    };

    var mock = MockSender{ .captured = &written_data };
    const sender = transport.AsyncSender{
        .context = @ptrCast(&mock),
        .write_fn = MockSender.writeFn,
        .flush_fn = MockSender.flushFn,
    };

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();

    client.setSender(sender);

    // No stream ID set
    const result = client.sendAbortRequest(null);
    try std.testing.expectError(error.NoActiveStream, result);
}
