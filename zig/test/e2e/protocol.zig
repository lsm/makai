const std = @import("std");
const transport = @import("transport");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const event_stream = @import("event_stream");
const envelope = @import("protocol_envelope");
const stdio = @import("stdio");

const testing = std.testing;

// =============================================================================
// Mock Transport for Testing
// =============================================================================

/// Mock sender that captures written data for verification
const MockSender = struct {
    captured: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) MockSender {
        const list = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
        return .{
            .captured = list,
            .allocator = allocator,
        };
    }

    fn deinit(self: *MockSender) void {
        for (self.captured.items) |item| {
            self.allocator.free(item);
        }
        self.captured.deinit(self.allocator);
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) !void {
        const self: *MockSender = @ptrCast(@alignCast(ctx));
        const copy = try self.allocator.dupe(u8, data);
        try self.captured.append(self.allocator, copy);
    }

    fn flushFn(_: *anyopaque) !void {}

    fn sender(self: *MockSender) transport.AsyncSender {
        return .{
            .context = @ptrCast(self),
            .write_fn = writeFn,
            .flush_fn = flushFn,
        };
    }
};

/// Mock receiver that provides pre-loaded data
const MockReceiver = struct {
    data: []const []const u8,
    index: usize = 0,
    allocator: std.mem.Allocator,

    fn receiveStreamFn(ctx: *anyopaque, allocator: std.mem.Allocator) !*transport.ByteStream {
        const self: *MockReceiver = @ptrCast(@alignCast(ctx));

        const stream = try allocator.create(transport.ByteStream);
        stream.* = transport.ByteStream.init(allocator);

        // Push all data into the stream
        for (self.data) |item| {
            const data = try allocator.dupe(u8, item);
            try stream.push(.{ .data = data, .owned = true });
        }
        stream.complete({});

        return stream;
    }

    fn receiver(self: *MockReceiver) transport.AsyncReceiver {
        return .{
            .context = @ptrCast(self),
            .receive_stream_fn = receiveStreamFn,
        };
    }
};

// =============================================================================
// Envelope Serialization Tests
// =============================================================================

test "Envelope serialization roundtrip with ping" {
    const allocator = testing.allocator;

    // Create a minimal ping envelope using JSON
    const json =
        \\{
        \\  "type": "ping",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "version": 1,
        \\  "payload": {}
        \\}
    ;

    var parsed = try envelope.deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    // Serialize back
    const serialized = try envelope.serializeEnvelope(parsed, allocator);
    defer allocator.free(serialized);

    // Verify structure
    try testing.expect(std.mem.indexOf(u8, serialized, "\"type\":\"ping\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"sequence\":1") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"timestamp\":1708234567890") != null);
}

test "Envelope serialization roundtrip with pong" {
    const allocator = testing.allocator;

    const json =
        \\{
        \\  "type": "pong",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 2,
        \\  "timestamp": 1708234567900,
        \\  "version": 1,
        \\  "payload": {
        \\    "ping_id": "test-ping-123"
        \\  }
        \\}
    ;

    var parsed = try envelope.deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    const serialized = try envelope.serializeEnvelope(parsed, allocator);
    defer allocator.free(serialized);

    try testing.expect(std.mem.indexOf(u8, serialized, "\"type\":\"pong\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"ping_id\":\"test-ping-123\"") != null);
}

test "Envelope roundtrip preserves ACK structure" {
    const allocator = testing.allocator;

    const json =
        \\{
        \\  "type": "ack",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 2,
        \\  "timestamp": 1708234567900,
        \\  "version": 1,
        \\  "payload": {
        \\    "acknowledged_id": "abcdef01-2345-6789-abcd-ef0123456789"
        \\  }
        \\}
    ;

    var parsed = try envelope.deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    const serialized = try envelope.serializeEnvelope(parsed, allocator);
    defer allocator.free(serialized);

    try testing.expect(parsed.payload == .ack);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"type\":\"ack\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"acknowledged_id\"") != null);
}

test "Envelope roundtrip preserves NACK structure" {
    const allocator = testing.allocator;

    const json =
        \\{
        \\  "type": "nack",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 3,
        \\  "timestamp": 1708234567900,
        \\  "version": 1,
        \\  "payload": {
        \\    "rejected_id": "abcdef01-2345-6789-abcd-ef0123456789",
        \\    "reason": "Model not found",
        \\    "error_code": "model_not_found"
        \\  }
        \\}
    ;

    var parsed = try envelope.deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    const serialized = try envelope.serializeEnvelope(parsed, allocator);
    defer allocator.free(serialized);

    try testing.expect(parsed.payload == .nack);
    try testing.expectEqualStrings("Model not found", parsed.payload.nack.reason.slice());
}

test "Envelope roundtrip preserves abort_request" {
    const allocator = testing.allocator;

    const json =
        \\{
        \\  "type": "abort_request",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 10,
        \\  "timestamp": 1708234567900,
        \\  "version": 1,
        \\  "payload": {
        \\    "target_stream_id": "abcdef01-2345-6789-abcd-ef0123456789",
        \\    "reason": "User cancelled"
        \\  }
        \\}
    ;

    var parsed = try envelope.deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try testing.expect(parsed.payload == .abort_request);
    try testing.expectEqualStrings("User cancelled", parsed.payload.abort_request.getReason().?);
}

test "Envelope roundtrip preserves stream_error" {
    const allocator = testing.allocator;

    const json =
        \\{
        \\  "type": "stream_error",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 20,
        \\  "timestamp": 1708234567900,
        \\  "version": 1,
        \\  "payload": {
        \\    "code": "provider_error",
        \\    "message": "Connection timeout"
        \\  }
        \\}
    ;

    var parsed = try envelope.deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try testing.expect(parsed.payload == .stream_error);
    try testing.expectEqualStrings("Connection timeout", parsed.payload.stream_error.message.slice());
}

test "Envelope roundtrip preserves goodbye" {
    const allocator = testing.allocator;

    const json =
        \\{
        \\  "type": "goodbye",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 100,
        \\  "timestamp": 1708234567900,
        \\  "version": 1,
        \\  "payload": {
        \\    "reason": "Client shutting down"
        \\  }
        \\}
    ;

    var parsed = try envelope.deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try testing.expect(parsed.payload == .goodbye);
    try testing.expectEqualStrings("Client shutting down", parsed.payload.goodbye.getReason().?);
}

// =============================================================================
// Stdio Transport Protocol Tests
// =============================================================================

test "Stdio transport frames messages correctly" {
    // Create a pipe for testing
    const pipe = try std.posix.pipe();
    const read_file = std.fs.File{ .handle = pipe[0] };
    const write_file = std.fs.File{ .handle = pipe[1] };
    defer read_file.close();

    // Create sender with write end
    var stdio_sender = stdio.AsyncStdioSender.initWithFile(write_file);
    var sender = stdio_sender.sender();

    // Write test messages
    const msg1 = "{\"type\":\"ping\"}";
    const msg2 = "{\"type\":\"start\",\"model\":\"test\"}";
    try sender.write(msg1);
    try sender.write(msg2);
    write_file.close();

    // Create receiver with read end
    var async_receiver = stdio.AsyncStdioReceiver.initWithFile(read_file);
    var handle = try async_receiver.receiveStreamWithHandle(testing.allocator);

    // Read first message
    const stream = handle.getStream();
    if (stream.wait()) |chunk| {
        defer {
            var mutable = chunk;
            mutable.deinit(testing.allocator);
        }
        try testing.expectEqualStrings(msg1, chunk.data);
    }

    // Read second message
    if (stream.wait()) |chunk| {
        defer {
            var mutable = chunk;
            mutable.deinit(testing.allocator);
        }
        try testing.expectEqualStrings(msg2, chunk.data);
    }

    // Clean up
    const exited = handle.deinit(5000);
    try testing.expect(exited);
}

test "Stdio transport handles multi-line message splitting" {
    const pipe = try std.posix.pipe();
    const read_file = std.fs.File{ .handle = pipe[0] };
    const write_file = std.fs.File{ .handle = pipe[1] };
    defer read_file.close();

    // Write multiple messages at once (with newlines)
    const combined = "{\"type\":\"ping\"}\n{\"type\":\"pong\"}\n{\"type\":\"ack\"}\n";
    _ = try write_file.write(combined);
    write_file.close();

    // Create receiver
    var async_receiver = stdio.AsyncStdioReceiver.initWithFile(read_file);
    var handle = try async_receiver.receiveStreamWithHandle(testing.allocator);

    const stream = handle.getStream();

    // Read all three messages
    var count: usize = 0;
    while (stream.wait()) |chunk| {
        defer {
            var mutable = chunk;
            mutable.deinit(testing.allocator);
        }
        count += 1;
        if (count == 1) try testing.expectEqualStrings("{\"type\":\"ping\"}", chunk.data);
        if (count == 2) try testing.expectEqualStrings("{\"type\":\"pong\"}", chunk.data);
        if (count == 3) try testing.expectEqualStrings("{\"type\":\"ack\"}", chunk.data);
    }

    try testing.expectEqual(@as(usize, 3), count);

    const exited = handle.deinit(5000);
    try testing.expect(exited);
}

test "Stdio transport sends and receives messages" {
    const allocator = testing.allocator;

    // Create a pipe for testing
    const pipe = try std.posix.pipe();
    const read_file = std.fs.File{ .handle = pipe[0] };
    const write_file = std.fs.File{ .handle = pipe[1] };
    defer read_file.close();

    // Create a simple message
    const msg = "test-message-123";

    // Send through stdio transport
    var stdio_sender = stdio.AsyncStdioSender.initWithFile(write_file);
    var sender = stdio_sender.sender();
    try sender.write(msg);
    try sender.write("\n"); // Add newline terminator
    write_file.close();

    // Receive through stdio transport
    var async_receiver = stdio.AsyncStdioReceiver.initWithFile(read_file);
    var handle = try async_receiver.receiveStreamWithHandle(allocator);

    const stream = handle.getStream();
    if (stream.wait()) |chunk| {
        defer {
            var mutable = chunk;
            mutable.deinit(allocator);
        }

        try testing.expectEqualStrings("test-message-123", chunk.data);
    }

    const exited = handle.deinit(5000);
    try testing.expect(exited);
}

// =============================================================================
// Control Message Callback Tests
// =============================================================================

const TestControlContext = struct {
    received_ack: bool = false,
    received_nack: bool = false,
    received_ping: bool = false,
    received_pong: bool = false,
    last_ack_id: ?[]const u8 = null,
    last_nack_reason: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    fn callback(ctrl: transport.ControlMessage, ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        switch (ctrl) {
            .ack => |a| {
                self.received_ack = true;
                if (self.last_ack_id) |id| self.allocator.free(id);
                self.last_ack_id = self.allocator.dupe(u8, a.acknowledged_id) catch null;
            },
            .nack => |n| {
                self.received_nack = true;
                if (self.last_nack_reason) |r| self.allocator.free(r);
                self.last_nack_reason = self.allocator.dupe(u8, n.reason) catch null;
            },
            .ping => {
                self.received_ping = true;
            },
            .pong => {
                self.received_pong = true;
            },
            else => {},
        }
    }

    fn deinit(self: *@This()) void {
        if (self.last_ack_id) |id| self.allocator.free(id);
        if (self.last_nack_reason) |r| self.allocator.free(r);
    }
};

test "Control messages invoke callbacks" {
    const allocator = testing.allocator;

    var byte_stream = transport.ByteStream.init(allocator);
    defer byte_stream.deinit();

    // Push control messages
    try byte_stream.push(.{ .data = try allocator.dupe(u8, "{\"type\":\"ping\"}"), .owned = true });
    try byte_stream.push(.{ .data = try allocator.dupe(u8, "{\"type\":\"ack\",\"acknowledged_id\":\"msg-123\"}"), .owned = true });
    try byte_stream.push(.{ .data = try allocator.dupe(u8, "{\"type\":\"pong\"}"), .owned = true });
    try byte_stream.push(.{ .data = try allocator.dupe(u8, "{\"type\":\"nack\",\"rejected_id\":\"msg-456\",\"reason\":\"Test error\"}"), .owned = true });

    // Push a result to end the stream
    const result_json = try transport.serializeResult(.{
        .content = &.{},
        .usage = .{},
        .stop_reason = .stop,
        .model = "test-model",
        .api = "test-api",
        .provider = "test-provider",
        .timestamp = 0,
    }, allocator);
    defer allocator.free(result_json);
    try byte_stream.push(.{ .data = try allocator.dupe(u8, result_json), .owned = true });

    byte_stream.complete({});

    var msg_stream = event_stream.AssistantMessageStream.init(allocator);
    defer msg_stream.deinit();

    var test_ctx = TestControlContext{ .allocator = allocator };
    defer test_ctx.deinit();

    transport.receiveStreamFromByteStreamWithControl(
        &byte_stream,
        &msg_stream,
        TestControlContext.callback,
        &test_ctx,
        allocator,
    );

    // Verify all control messages were received
    try testing.expect(test_ctx.received_ping);
    try testing.expect(test_ctx.received_pong);
    try testing.expect(test_ctx.received_ack);
    try testing.expect(test_ctx.received_nack);
    try testing.expect(test_ctx.last_ack_id != null);
    try testing.expectEqualStrings("msg-123", test_ctx.last_ack_id.?);
    try testing.expect(test_ctx.last_nack_reason != null);
    try testing.expectEqualStrings("Test error", test_ctx.last_nack_reason.?);

    try testing.expect(msg_stream.isDone());
}

// =============================================================================
// Event Streaming Tests
// =============================================================================

test "Event streaming through byte stream with envelope framing" {
    const allocator = testing.allocator;

    var byte_stream = transport.ByteStream.init(allocator);
    defer byte_stream.deinit();

    // Ping control message
    const ping_json =
        \\{
        \\  "type": "ping",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567900,
        \\  "version": 1,
        \\  "payload": {}
        \\}
    ;
    try byte_stream.push(.{ .data = try allocator.dupe(u8, ping_json), .owned = true });

    // Pong control message
    const pong_json =
        \\{
        \\  "type": "pong",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543211",
        \\  "sequence": 2,
        \\  "timestamp": 1708234567901,
        \\  "version": 1,
        \\  "payload": {
        \\    "ping_id": "test-ping"
        \\  }
        \\}
    ;
    try byte_stream.push(.{ .data = try allocator.dupe(u8, pong_json), .owned = true });

    byte_stream.complete({});

    // Read and verify events
    var event_count: usize = 0;
    while (byte_stream.wait()) |chunk| {
        defer {
            var mutable = chunk;
            mutable.deinit(allocator);
        }
        event_count += 1;

        var parsed = try envelope.deserializeEnvelope(chunk.data, allocator);
        defer parsed.deinit(allocator);

        try testing.expect(parsed.payload == .ping or parsed.payload == .pong);
    }

    try testing.expectEqual(@as(usize, 2), event_count);
}

// =============================================================================
// Mock Transport Communication Tests
// =============================================================================

test "Mock sender captures messages correctly" {
    const allocator = testing.allocator;

    var mock_sender = MockSender.init(allocator);
    defer mock_sender.deinit();

    var s = mock_sender.sender();

    try s.write("{\"type\":\"ping\"}");
    try s.write("{\"type\":\"start\"}");

    try testing.expectEqual(@as(usize, 2), mock_sender.captured.items.len);
    try testing.expectEqualStrings("{\"type\":\"ping\"}", mock_sender.captured.items[0]);
    try testing.expectEqualStrings("{\"type\":\"start\"}", mock_sender.captured.items[1]);
}

test "Mock receiver provides pre-loaded data" {
    const allocator = testing.allocator;

    var mock_receiver = MockReceiver{
        .data = &.{
            "{\"type\":\"ping\"}",
            "{\"type\":\"pong\"}",
        },
        .allocator = allocator,
    };

    var r = mock_receiver.receiver();
    const stream = try r.receiveStream(allocator);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    // Read first message
    if (stream.wait()) |chunk| {
        defer {
            var mutable = chunk;
            mutable.deinit(allocator);
        }
        try testing.expectEqualStrings("{\"type\":\"ping\"}", chunk.data);
    }

    // Read second message
    if (stream.wait()) |chunk| {
        defer {
            var mutable = chunk;
            mutable.deinit(allocator);
        }
        try testing.expectEqualStrings("{\"type\":\"pong\"}", chunk.data);
    }
}

// =============================================================================
// Error Handling Tests
// =============================================================================

test "Envelope deserialization handles invalid JSON gracefully" {
    const allocator = testing.allocator;

    const invalid_json = "not valid json";

    const result = envelope.deserializeEnvelope(invalid_json, allocator);
    // The error can be either SyntaxError or InvalidCharacter depending on parsing stage
    try testing.expect(result == error.SyntaxError or result == error.InvalidCharacter);
}

// Note: Testing missing required fields is skipped because the current implementation
// panics rather than returning an error. This should be fixed in the deserializer to
// return FieldNotFound errors instead of using .? on optional values.

// =============================================================================
// Concurrent Access Tests (Basic)
// =============================================================================

test "ByteStream handles concurrent-like push and poll" {
    const allocator = testing.allocator;

    var byte_stream = transport.ByteStream.init(allocator);
    defer byte_stream.deinit();

    // Push multiple items rapidly
    for (0..10) |i| {
        const msg = try std.fmt.allocPrint(allocator, "message-{}", .{i});
        defer allocator.free(msg);
        try byte_stream.push(.{ .data = try allocator.dupe(u8, msg), .owned = true });
    }

    byte_stream.complete({});

    // Poll all items
    var count: usize = 0;
    while (byte_stream.wait()) |chunk| {
        defer {
            var mutable = chunk;
            mutable.deinit(allocator);
        }
        count += 1;
    }

    try testing.expectEqual(@as(usize, 10), count);
}

test "EventStream handles event batch processing" {
    const allocator = testing.allocator;

    var event_str = event_stream.AssistantMessageEventStream.init(allocator);
    defer event_str.deinit();

    // Push multiple events
    for (0..5) |_| {
        try event_str.push(.{ .start = .{
            .partial = .{
                .content = &.{},
                .api = "test-api",
                .provider = "test-provider",
                .model = "test-model",
                .usage = .{},
                .stop_reason = .stop,
                .timestamp = 0,
            },
        } });
    }

    // Poll events in batch
    var batch_count: usize = 0;
    var events_buf: [10]ai_types.AssistantMessageEvent = undefined;
    const count = event_str.pollBatch(&events_buf);
    batch_count += count;

    try testing.expectEqual(@as(usize, 5), batch_count);

    // Complete the stream
    event_str.complete(.{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    });

    try testing.expect(event_str.isDone());
}

// =============================================================================
// Version Handling Tests
// =============================================================================

test "Envelope defaults version to 1 when not specified" {
    const allocator = testing.allocator;

    const json_without_version =
        \\{
        \\  "type": "ping",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "payload": {}
        \\}
    ;

    var parsed = try envelope.deserializeEnvelope(json_without_version, allocator);
    defer parsed.deinit(allocator);

    try testing.expectEqual(@as(u8, 1), parsed.version);
}

test "Envelope preserves explicit version" {
    const allocator = testing.allocator;

    const json_with_version =
        \\{
        \\  "type": "ping",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "version": 2,
        \\  "payload": {}
        \\}
    ;

    var parsed = try envelope.deserializeEnvelope(json_with_version, allocator);
    defer parsed.deinit(allocator);

    try testing.expectEqual(@as(u8, 2), parsed.version);
}

// =============================================================================
// In-Reply-To Tests
// =============================================================================

test "Envelope preserves in_reply_to field" {
    const allocator = testing.allocator;

    const json =
        \\{
        \\  "type": "ack",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 2,
        \\  "timestamp": 1708234567890,
        \\  "version": 1,
        \\  "in_reply_to": "abcdef01-2345-6789-abcd-ef0123456789",
        \\  "payload": {
        \\    "acknowledged_id": "abcdef01-2345-6789-abcd-ef0123456789"
        \\  }
        \\}
    ;

    var parsed = try envelope.deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try testing.expect(parsed.in_reply_to != null);

    // Serialize and verify in_reply_to is preserved
    const serialized = try envelope.serializeEnvelope(parsed, allocator);
    defer allocator.free(serialized);

    try testing.expect(std.mem.indexOf(u8, serialized, "\"in_reply_to\"") != null);
}
