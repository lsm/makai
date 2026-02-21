//! In-Process Transport
//!
//! Transport for communication within the same process with configurable modes:
//!
//! - `.direct`: Zero-copy, deserialize on write and push events directly to stream.
//!   Use for production in-process communication, agent-to-agent bridging.
//!
//! - `.serialized`: Serialize to bytes with framing, deserialize on read.
//!   Use for testing to validate the full serialization/deserialization path.
//!
//! Use cases:
//! - Testing without mock transports
//! - Agent-to-agent communication in same process
//! - Protocol adapters and bridges
//! - Full-stack e2e tests that need to exercise serialization

const std = @import("std");
const transport_mod = @import("transport");
const event_stream = @import("event_stream");
const ai_types = @import("ai_types");
const oom = @import("oom");

/// Transport mode determining how messages are handled
pub const Mode = enum {
    /// Zero-copy: deserialize on write, push events directly to stream
    direct,
    /// Serialize to bytes with newline framing, deserialize on read
    /// Tests full serialization path
    serialized,
};

/// In-process transport with configurable serialization mode.
pub const InProcessTransport = struct {
    stream: *event_stream.AssistantMessageStream,
    allocator: std.mem.Allocator,
    owns_stream: bool,
    mode: Mode,

    const Self = @This();

    /// Initialize with an existing stream (does not take ownership)
    pub fn initWithStream(stream: *event_stream.AssistantMessageStream, allocator: std.mem.Allocator) Self {
        return .{
            .stream = stream,
            .allocator = allocator,
            .owns_stream = false,
            .mode = .direct,
        };
    }

    /// Initialize with a new stream in direct mode (takes ownership)
    pub fn init(allocator: std.mem.Allocator) !*Self {
        return initWithMode(allocator, .direct);
    }

    /// Initialize with a new stream and specified mode (takes ownership)
    pub fn initWithMode(allocator: std.mem.Allocator, mode: Mode) !*Self {
        const self = try allocator.create(Self);
        const stream = try allocator.create(event_stream.AssistantMessageStream);
        stream.* = event_stream.AssistantMessageStream.init(allocator);

        self.* = .{
            .stream = stream,
            .allocator = allocator,
            .owns_stream = true,
            .mode = mode,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.owns_stream) {
            self.stream.deinit();
            self.allocator.destroy(self.stream);
            self.allocator.destroy(self);
        }
    }

    /// Get the underlying stream for direct access
    pub fn getStream(self: *Self) *event_stream.AssistantMessageStream {
        return self.stream;
    }

    /// Convert to AsyncSender interface
    pub fn asyncSender(self: *Self) transport_mod.AsyncSender {
        return .{
            .context = @ptrCast(self),
            .write_fn = writeFn,
            .flush_fn = flushFn,
            .close_fn = closeFn,
        };
    }

    /// Convert to AsyncReceiver interface
    pub fn asyncReceiver(self: *Self) transport_mod.AsyncReceiver {
        return .{
            .context = @ptrCast(self),
            .receive_stream_fn = receiveStreamFn,
            .read_fn = null, // Not supported - use receiveStream instead
            .close_fn = closeReceiverFn,
        };
    }

    // --- AsyncSender implementation ---

    fn writeFn(ctx: *anyopaque, data: []const u8) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        // Deserialize and push event directly into the stream
        const msg = try transport_mod.deserialize(data, self.allocator);
        switch (msg) {
            .event => |ev| {
                try self.stream.push(ev);
            },
            .result => |r| {
                self.stream.complete(r);
            },
            .stream_error => |e| {
                self.stream.completeWithError(e.slice());
                var mutable_e = e;
                mutable_e.deinit(self.allocator);
            },
            .control => |ctrl| {
                // Handle control messages (ping/pong/etc)
                handleControlMessage(ctrl, self.allocator);
            },
        }
    }

    fn flushFn(ctx: *anyopaque) !void {
        _ = ctx;
        // In-process transport doesn't need flushing
    }

    fn closeFn(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.owns_stream) {
            self.stream.completeWithError("Transport closed");
        }
    }

    // --- AsyncReceiver implementation ---

    const ProducerContext = struct {
        stream: *event_stream.AssistantMessageStream,
        byte_stream: *transport_mod.ByteStream,
        allocator: std.mem.Allocator,
    };

    fn receiveStreamFn(ctx: *anyopaque, allocator: std.mem.Allocator) !*transport_mod.ByteStream {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const byte_stream = try allocator.create(transport_mod.ByteStream);
        byte_stream.* = transport_mod.ByteStream.init(allocator);

        const thread_ctx = try allocator.create(ProducerContext);
        thread_ctx.* = .{
            .stream = self.stream,
            .byte_stream = byte_stream,
            .allocator = allocator,
        };

        const thread = try std.Thread.spawn(.{}, producerThread, .{thread_ctx});
        thread.detach();

        return byte_stream;
    }

    fn closeReceiverFn(ctx: *anyopaque) void {
        _ = ctx;
        // The receiver doesn't own the stream
    }

    fn producerThread(ctx: *ProducerContext) void {
        defer {
            ctx.byte_stream.markThreadDone();
            ctx.allocator.destroy(ctx);
        }

        // Forward all events from AssistantMessageStream to ByteStream
        while (ctx.stream.wait()) |ev| {
            // Serialize event to JSON for ByteStream
            const json_bytes = transport_mod.serializeEvent(ev, ctx.allocator) catch {
                ctx.byte_stream.completeWithError("Serialization error");
                return;
            };

            // Free event strings after serialization
            var mutable_ev = ev;
            ai_types.deinitAssistantMessageEvent(ctx.allocator, &mutable_ev);

            const chunk = transport_mod.ByteChunk{
                .data = json_bytes,
                .owned = true,
            };

            ctx.byte_stream.push(chunk) catch {
                ctx.allocator.free(json_bytes);
                ctx.byte_stream.completeWithError("Stream queue full");
                return;
            };
        }

        // Stream completed
        if (ctx.stream.getError()) |err| {
            ctx.byte_stream.completeWithError(err);
        } else {
            ctx.byte_stream.complete({});
        }
    }

    fn handleControlMessage(ctrl: transport_mod.ControlMessage, allocator: std.mem.Allocator) void {
        // Free control message strings
        freeControlStrings(ctrl, allocator);
    }
};

/// Free allocated strings in a control message (local copy since transport.freeControlStrings is not pub)
fn freeControlStrings(ctrl: transport_mod.ControlMessage, allocator: std.mem.Allocator) void {
    switch (ctrl) {
        .ack => |a| {
            var id = a.acknowledged_id;
            id.deinit(allocator);
        },
        .nack => |n| {
            var rejected_id = n.rejected_id;
            rejected_id.deinit(allocator);

            var reason = n.reason;
            reason.deinit(allocator);

            var error_code = n.error_code;
            error_code.deinit(allocator);
        },
        .goodbye => |g| {
            var reason = g;
            reason.deinit(allocator);
        },
        .sync => |s| {
            var stream_id = s.stream_id;
            stream_id.deinit(allocator);

            var partial = s.partial;
            partial.deinit(allocator);
        },
        .ping, .pong, .sync_request => {},
    }
}

/// Create a connected pair of in-process transports.
/// Returns client (for sending) and server (for receiving).
pub fn createPair(allocator: std.mem.Allocator) !struct { client: *InProcessTransport, server: *InProcessTransport } {
    const stream = try allocator.create(event_stream.AssistantMessageStream);
    stream.* = event_stream.AssistantMessageStream.init(allocator);

    const client = try allocator.create(InProcessTransport);
    client.* = InProcessTransport.initWithStream(stream, allocator);

    const server = try allocator.create(InProcessTransport);
    server.* = InProcessTransport.initWithStream(stream, allocator);

    return .{ .client = client, .server = server };
}

/// Free a pair created by createPair
pub fn destroyPair(allocator: std.mem.Allocator, client: *InProcessTransport, server: *InProcessTransport) void {
    // Both share the same stream, only deinit once
    client.stream.deinit();
    allocator.destroy(client.stream);
    allocator.destroy(client);
    allocator.destroy(server);
}

/// Create a serialized pipe for testing the full serialization path.
/// This simulates a network-like transport where messages are serialized
/// to bytes with newline framing before being read on the other side.
pub fn createSerializedPipe(allocator: std.mem.Allocator) SerializedPipe {
    return SerializedPipe.init(allocator);
}

/// A serialized bidirectional pipe for testing.
/// Simulates network transport with full serialization/deserialization.
///
/// Usage:
/// ```zig
/// var pipe = try createSerializedPipe(allocator);
/// defer pipe.deinit();
///
/// // Client sends to server
/// var sender = pipe.clientSender();
/// try sender.write(json_data);
///
/// // Server receives
/// var receiver = pipe.serverReceiver();
/// const line = try receiver.readLine(allocator);
/// ```
pub const SerializedPipe = struct {
    /// Buffer for server -> client messages
    to_client: std.ArrayList(u8),
    /// Buffer for client -> server messages
    to_server: std.ArrayList(u8),
    /// Read position for client direction (client reads from to_client)
    to_client_read_pos: usize,
    /// Read position for server direction (server reads from to_server)
    to_server_read_pos: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SerializedPipe {
        return .{
            // OOM is the only possible error from initCapacity(); treat as fatal since
            // the pipe cannot function without its buffers.
            .to_client = oom.unreachableOnOom(std.ArrayList(u8).initCapacity(allocator, 4096)),
            .to_server = oom.unreachableOnOom(std.ArrayList(u8).initCapacity(allocator, 4096)),
            .to_client_read_pos = 0,
            .to_server_read_pos = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SerializedPipe) void {
        self.to_client.deinit(self.allocator);
        self.to_server.deinit(self.allocator);

        // Poison freed memory to catch use-after-free in debug builds
        self.* = undefined;
    }

    /// Server writes to this to send to client
    pub fn serverSender(self: *SerializedPipe) transport_mod.AsyncSender {
        return .{
            .context = self,
            .write_fn = struct {
                fn write(ctx: *anyopaque, data: []const u8) !void {
                    const s: *SerializedPipe = @ptrCast(@alignCast(ctx));
                    try s.to_client.appendSlice(s.allocator, data);
                    try s.to_client.append(s.allocator, '\n');
                }
            }.write,
            .flush_fn = struct {
                fn flush(_: *anyopaque) !void {}
            }.flush,
        };
    }

    /// Client reads from this (reads server->client messages from to_client buffer)
    pub fn clientReceiver(self: *SerializedPipe) Receiver {
        return .{
            .pipe = self,
            .buffer = &self.to_client,
            .read_pos_ptr = &self.to_client_read_pos,
        };
    }

    /// Client writes to this to send to server
    pub fn clientSender(self: *SerializedPipe) transport_mod.AsyncSender {
        return .{
            .context = self,
            .write_fn = struct {
                fn write(ctx: *anyopaque, data: []const u8) !void {
                    const s: *SerializedPipe = @ptrCast(@alignCast(ctx));
                    try s.to_server.appendSlice(s.allocator, data);
                    try s.to_server.append(s.allocator, '\n');
                }
            }.write,
            .flush_fn = struct {
                fn flush(_: *anyopaque) !void {}
            }.flush,
        };
    }

    /// Server reads from this (reads client->server messages from to_server buffer)
    pub fn serverReceiver(self: *SerializedPipe) Receiver {
        return .{
            .pipe = self,
            .buffer = &self.to_server,
            .read_pos_ptr = &self.to_server_read_pos,
        };
    }

    /// Receiver with line-based reading
    pub const Receiver = struct {
        pipe: *SerializedPipe,
        buffer: *std.ArrayList(u8),
        read_pos_ptr: *usize,

        pub fn readLine(self: *@This(), allocator: std.mem.Allocator) !?[]const u8 {
            const read_pos = self.read_pos_ptr.*;

            if (read_pos >= self.buffer.items.len) return null;

            const remaining = self.buffer.items[read_pos..];
            if (std.mem.indexOfScalar(u8, remaining, '\n')) |nl_pos| {
                const line_end = read_pos + nl_pos;
                const line = self.buffer.items[read_pos..line_end];
                const result = try allocator.dupe(u8, line);
                self.read_pos_ptr.* = line_end + 1;
                return result;
            }
            return null;
        }
    };
};

/// Direct event-to-event bridge without serialization.
/// Forwards events from source stream to destination stream.
pub const EventBridge = struct {
    source: *event_stream.AssistantMessageStream,
    dest: *event_stream.AssistantMessageStream,
    allocator: std.mem.Allocator,
    cancel_token: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(
        source: *event_stream.AssistantMessageStream,
        dest: *event_stream.AssistantMessageStream,
        allocator: std.mem.Allocator,
    ) Self {
        return .{
            .source = source,
            .dest = dest,
            .allocator = allocator,
            .cancel_token = std.atomic.Value(bool).init(false),
        };
    }

    /// Request cancellation of the bridge
    pub fn cancel(self: *Self) void {
        self.cancel_token.store(true, .release);
    }

    /// Run the bridge in the current thread (blocking).
    /// Forwards all events until source completes or cancellation.
    pub fn run(self: *Self) void {
        while (!self.cancel_token.load(.acquire)) {
            // Use poll with timeout to allow cancellation
            if (self.source.poll()) |ev| {
                // Clone the event for the destination
                const cloned = ai_types.cloneAssistantMessageEvent(self.allocator, ev) catch {
                    self.dest.completeWithError("Failed to clone event");
                    return;
                };

                // Free the source event
                var mutable_ev = ev;
                ai_types.deinitAssistantMessageEvent(self.allocator, &mutable_ev);

                self.dest.push(cloned) catch {
                    var mutable_cloned = cloned;
                    ai_types.deinitAssistantMessageEvent(self.allocator, &mutable_cloned);
                    self.dest.completeWithError("Destination queue full");
                    return;
                };
            } else {
                // No event available, check if source is done
                if (self.source.isDone()) {
                    // Forward completion
                    if (self.source.getError()) |err| {
                        self.dest.completeWithError(err);
                    } else if (self.source.getResult()) |result| {
                        self.dest.complete(result);
                    } else {
                        // No result, complete with empty
                        self.dest.complete(.{
                            .content = &.{},
                            .usage = .{},
                            .stop_reason = .stop,
                            .model = "",
                            .api = "",
                            .provider = "",
                            .timestamp = 0,
                        });
                    }
                    return;
                }

                // Wait a bit before polling again (simple backoff)
                std.Thread.sleep(1_000_000); // 1ms
            }
        }

        // Cancelled
        self.dest.completeWithError("Bridge cancelled");
    }

    /// Run the bridge in a background thread.
    /// Returns the thread handle (caller must join).
    pub fn runAsync(self: *Self) !std.Thread {
        return std.Thread.spawn(.{}, run, .{self});
    }
};

/// Zero-copy event forwarder for high-performance in-process routing.
/// Directly forwards events without cloning when possible.
pub const ZeroCopyForwarder = struct {
    dest: *event_stream.AssistantMessageStream,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(dest: *event_stream.AssistantMessageStream, allocator: std.mem.Allocator) Self {
        return .{
            .dest = dest,
            .allocator = allocator,
        };
    }

    /// Forward an event directly (takes ownership of the event).
    /// The caller must not use the event after calling this.
    pub fn forward(self: *Self, ev: ai_types.AssistantMessageEvent) !void {
        try self.dest.push(ev);
    }

    /// Forward completion
    pub fn forwardCompletion(self: *Self, result: ai_types.AssistantMessage) void {
        self.dest.complete(result);
    }

    /// Forward error
    pub fn forwardError(self: *Self, msg: []const u8) void {
        self.dest.completeWithError(msg);
    }

    /// Get the destination stream for direct pushing
    pub fn getDestStream(self: *Self) *event_stream.AssistantMessageStream {
        return self.dest;
    }
};

// --- Tests ---

test "InProcessTransport basic send and receive" {
    const allocator = std.testing.allocator;

    var ip_transport = try InProcessTransport.init(allocator);
    defer ip_transport.deinit();

    // Create a sender
    var sender = ip_transport.asyncSender();

    // Send a start event
    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const event_json = try transport_mod.serializeEvent(.{ .start = .{ .partial = partial } }, allocator);
    defer allocator.free(event_json);

    try sender.write(event_json);

    // Poll the stream directly
    const received = ip_transport.stream.poll();
    try std.testing.expect(received != null);
    try std.testing.expect(received.? == .start);

    // Clean up
    var mutable_ev = received.?;
    ai_types.deinitAssistantMessageEvent(allocator, &mutable_ev);
}

test "InProcessTransport pair communication" {
    const allocator = std.testing.allocator;

    const pair = try createPair(allocator);
    const client = pair.client;
    const server = pair.server;
    defer destroyPair(allocator, client, server);

    // Client sends
    var sender = client.asyncSender();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const event_json = try transport_mod.serializeEvent(.{ .start = .{ .partial = partial } }, allocator);
    defer allocator.free(event_json);

    try sender.write(event_json);

    // Server receives
    const received = server.stream.poll();
    try std.testing.expect(received != null);
    try std.testing.expect(received.? == .start);

    // Clean up
    var mutable_ev = received.?;
    ai_types.deinitAssistantMessageEvent(allocator, &mutable_ev);
}

test "EventBridge forwards events" {
    const allocator = std.testing.allocator;

    // Create source and destination streams
    var source_stream = event_stream.AssistantMessageStream.init(allocator);
    defer source_stream.deinit();

    var dest_stream = event_stream.AssistantMessageStream.init(allocator);
    defer dest_stream.deinit();

    // Push an event to source
    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const event = ai_types.AssistantMessageEvent{ .start = .{ .partial = partial } };
    const cloned = try ai_types.cloneAssistantMessageEvent(allocator, event);
    try source_stream.push(cloned);

    // Complete the source
    source_stream.complete(.{
        .content = &.{},
        .usage = .{},
        .stop_reason = .stop,
        .model = "",
        .api = "",
        .provider = "",
        .timestamp = 0,
    });

    // Create and run bridge
    var bridge = EventBridge.init(&source_stream, &dest_stream, allocator);
    bridge.run();

    // Check destination received the event
    const received = dest_stream.poll();
    try std.testing.expect(received != null);
    try std.testing.expect(received.? == .start);

    // Clean up
    var mutable_ev = received.?;
    ai_types.deinitAssistantMessageEvent(allocator, &mutable_ev);
}

test "ZeroCopyForwarder forwards events" {
    const allocator = std.testing.allocator;

    var dest_stream = event_stream.AssistantMessageStream.init(allocator);
    defer dest_stream.deinit();

    var forwarder = ZeroCopyForwarder.init(&dest_stream, allocator);

    // Create and forward an event
    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const event = try ai_types.cloneAssistantMessageEvent(
        allocator,
        .{ .start = .{ .partial = partial } },
    );

    try forwarder.forward(event);

    // Check it was forwarded
    const received = dest_stream.poll();
    try std.testing.expect(received != null);
    try std.testing.expect(received.? == .start);

    // Clean up
    var mutable_ev = received.?;
    ai_types.deinitAssistantMessageEvent(allocator, &mutable_ev);
}

test "InProcessTransport async receiver" {
    const allocator = std.testing.allocator;

    var transport_ptr = try InProcessTransport.init(allocator);
    defer transport_ptr.deinit();

    var receiver = transport_ptr.asyncReceiver();

    // Get byte stream
    const byte_stream = try receiver.receiveStream(allocator);

    // Send an event through the transport
    var sender = transport_ptr.asyncSender();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const event_json = try transport_mod.serializeEvent(.{ .start = .{ .partial = partial } }, allocator);
    defer allocator.free(event_json);

    try sender.write(event_json);

    // Complete the source so the producer thread exits
    transport_ptr.stream.complete(.{
        .content = &.{},
        .usage = .{},
        .stop_reason = .stop,
        .model = "",
        .api = "",
        .provider = "",
        .timestamp = 0,
    });

    // Read all chunks from the byte stream and free them
    while (byte_stream.wait()) |chunk| {
        var mutable_chunk = chunk;
        mutable_chunk.deinit(allocator);
    }

    // Clean up thread and stream
    _ = byte_stream.waitForThread(5000);
    byte_stream.deinit();
    allocator.destroy(byte_stream);
}

test "SerializedPipe bidirectional communication" {
    const allocator = std.testing.allocator;

    var pipe = createSerializedPipe(allocator);
    defer pipe.deinit();

    // Server sends a message to client
    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const event_json = try transport_mod.serializeEvent(.{ .start = .{ .partial = partial } }, allocator);
    defer allocator.free(event_json);

    var sender = pipe.serverSender();
    try sender.write(event_json);
    try sender.flush();

    // Client receives the message
    var receiver = pipe.clientReceiver();
    const line = try receiver.readLine(allocator) orelse return error.NoDataReceived;
    defer allocator.free(line);

    // Verify the line matches what was sent
    try std.testing.expectEqualStrings(event_json, line);
}

test "SerializedPipe full round trip" {
    const allocator = std.testing.allocator;

    var pipe = createSerializedPipe(allocator);
    defer pipe.deinit();

    // Client sends request to server
    const request = "{\"type\":\"ping\"}";
    var client_sender = pipe.clientSender();
    try client_sender.write(request);

    // Server receives request
    var server_receiver = pipe.serverReceiver();
    const received_req = try server_receiver.readLine(allocator) orelse return error.NoDataReceived;
    defer allocator.free(received_req);
    try std.testing.expectEqualStrings(request, received_req);

    // Server sends response to client
    const response = "{\"type\":\"pong\"}";
    var server_sender = pipe.serverSender();
    try server_sender.write(response);

    // Client receives response
    var client_receiver = pipe.clientReceiver();
    const received_resp = try client_receiver.readLine(allocator) orelse return error.NoDataReceived;
    defer allocator.free(received_resp);
    try std.testing.expectEqualStrings(response, received_resp);
}
