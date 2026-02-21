const std = @import("std");
const protocol_types = @import("protocol_types");
const envelope = @import("protocol_envelope");
const partial_reconstructor = @import("partial_reconstructor.zig");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");
const transport = @import("transport");
const oom = @import("oom");
const owned_slice_mod = @import("owned_slice");

const OwnedSlice = owned_slice_mod.OwnedSlice;

/// Client-side protocol handler for the Makai Wire Protocol.
///
/// Supports multiplexed streams with per-stream sequence tracking.
pub const ProtocolClient = struct {
    // Declarations must come before fields
    pub const PendingRequest = struct {
        message_id: protocol_types.Uuid,
        stream_id: protocol_types.Uuid = [_]u8{0} ** 16,
        sent_at: i64,
        timeout_ms: u64,
    };

    pub const Options = struct {
        include_partial: bool = false,
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

    /// Per-stream outgoing sequence counters
    stream_sequences: std.AutoHashMap(protocol_types.Uuid, u64),

    /// Per-stream reconstructors
    reconstructors: std.AutoHashMap(protocol_types.Uuid, partial_reconstructor.PartialReconstructor),

    /// Per-stream final results
    stream_results: std.AutoHashMap(protocol_types.Uuid, ai_types.AssistantMessage),

    /// Per-stream errors
    stream_errors: std.AutoHashMap(protocol_types.Uuid, OwnedSlice(u8)),

    /// Per-stream completion flags
    stream_complete_flags: std.AutoHashMap(protocol_types.Uuid, bool),

    /// Current stream ID (compatibility for legacy single-stream callers)
    current_stream_id: ?protocol_types.Uuid = null,

    /// Event stream for consuming events
    event_stream: *event_stream.AssistantMessageEventStream,

    /// Last received result (legacy compatibility)
    last_result: ?ai_types.AssistantMessage = null,

    /// Last error message (legacy compatibility)
    last_error: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    /// Whether the stream is complete (legacy compatibility)
    stream_complete: bool = false,

    /// Sequence number for outgoing messages (legacy compatibility mirror)
    sequence: u64 = 0,

    options: Options,

    /// Initialize a new ProtocolClient
    pub fn init(allocator: std.mem.Allocator, options: Options) Self {
        // OOM is the only possible error from allocator.create(); treat as fatal since
        // the client cannot function without its event stream.
        const es = oom.unreachableOnOom(allocator.create(event_stream.AssistantMessageEventStream));
        es.* = event_stream.AssistantMessageEventStream.init(allocator);
        // ProtocolClient deep-copies events via cloneAssistantMessageEvent() before pushing,
        // so the stream owns its events and must free them in deinit()
        es.owns_events = true;
        return .{
            .allocator = allocator,
            .reconstructor = partial_reconstructor.PartialReconstructor.init(allocator),
            .pending_requests = std.AutoHashMap(protocol_types.Uuid, PendingRequest).init(allocator),
            .stream_sequences = std.AutoHashMap(protocol_types.Uuid, u64).init(allocator),
            .reconstructors = std.AutoHashMap(protocol_types.Uuid, partial_reconstructor.PartialReconstructor).init(allocator),
            .stream_results = std.AutoHashMap(protocol_types.Uuid, ai_types.AssistantMessage).init(allocator),
            .stream_errors = std.AutoHashMap(protocol_types.Uuid, OwnedSlice(u8)).init(allocator),
            .stream_complete_flags = std.AutoHashMap(protocol_types.Uuid, bool).init(allocator),
            .event_stream = es,
            .options = options,
        };
    }

    /// Deinitialize the ProtocolClient
    pub fn deinit(self: *Self) void {
        // Clean up pending requests and stream metadata
        self.pending_requests.deinit();
        self.stream_sequences.deinit();
        self.stream_complete_flags.deinit();

        // Clean up per-stream reconstructors
        var recon_it = self.reconstructors.iterator();
        while (recon_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.reconstructors.deinit();

        // Clean up per-stream results
        var result_it = self.stream_results.iterator();
        while (result_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.stream_results.deinit();

        // Clean up per-stream errors
        var err_it = self.stream_errors.iterator();
        while (err_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.stream_errors.deinit();

        // Clean up legacy reconstructor
        self.reconstructor.deinit();

        // Clean up event stream
        self.event_stream.deinit();
        self.allocator.destroy(self.event_stream);

        // Clean up last result
        if (self.last_result) |*result| {
            result.deinit(self.allocator);
        }

        // Clean up last error
        self.last_error.deinit(self.allocator);

        // Poison freed memory to catch use-after-free in debug builds
        self.* = undefined;
    }

    /// Set the transport sender
    pub fn setSender(self: *Self, sender: transport.AsyncSender) void {
        self.sender = sender;
    }

    fn hasLastError(self: *const Self) bool {
        return self.last_error.slice().len > 0;
    }

    fn setLastError(self: *Self, msg: []const u8) !void {
        self.last_error.deinit(self.allocator);
        self.last_error = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, msg));
    }

    fn nextSequenceForStream(self: *Self, stream_id: protocol_types.Uuid) !u64 {
        const next = if (self.stream_sequences.get(stream_id)) |cur| cur + 1 else 1;
        try self.stream_sequences.put(stream_id, next);
        self.sequence = next; // compatibility mirror
        return next;
    }

    fn ensureReconstructor(self: *Self, stream_id: protocol_types.Uuid) !*partial_reconstructor.PartialReconstructor {
        if (self.reconstructors.getPtr(stream_id)) |r| return r;
        try self.reconstructors.put(stream_id, partial_reconstructor.PartialReconstructor.init(self.allocator));
        return self.reconstructors.getPtr(stream_id).?;
    }

    fn setStreamError(self: *Self, stream_id: protocol_types.Uuid, msg: []const u8) !void {
        if (self.stream_errors.getPtr(stream_id)) |existing| {
            existing.deinit(self.allocator);
            existing.* = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, msg));
        } else {
            try self.stream_errors.put(stream_id, OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, msg)));
        }
        try self.stream_complete_flags.put(stream_id, true);
    }

    fn setStreamResult(self: *Self, stream_id: protocol_types.Uuid, result: ai_types.AssistantMessage) !void {
        if (self.stream_results.getPtr(stream_id)) |existing| {
            existing.deinit(self.allocator);
            existing.* = result;
        } else {
            try self.stream_results.put(stream_id, result);
        }
        try self.stream_complete_flags.put(stream_id, true);
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
        const stream_id = message_id;
        const seq = try self.nextSequenceForStream(stream_id);

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
            .sequence = seq,
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
            .stream_id = stream_id,
            .sent_at = std.time.milliTimestamp(),
            .timeout_ms = self.options.request_timeout_ms,
        });
        try self.stream_complete_flags.put(stream_id, false);
        _ = try self.ensureReconstructor(stream_id);

        return message_id;
    }

    /// Send abort_request for current stream (legacy convenience method)
    pub fn sendAbortRequest(self: *Self, reason: ?[]const u8) !void {
        const stream_id = self.current_stream_id orelse return error.NoActiveStream;
        try self.sendAbortRequestFor(stream_id, reason);
    }

    /// Send abort_request for a specific stream
    pub fn sendAbortRequestFor(self: *Self, stream_id: protocol_types.Uuid, reason: ?[]const u8) !void {
        if (self.sender == null) {
            return error.NoSender;
        }
        if (!self.stream_sequences.contains(stream_id)) {
            return error.NoActiveStream;
        }

        const seq = try self.nextSequenceForStream(stream_id);

        const reason_owned = if (reason) |r|
            OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, r))
        else
            OwnedSlice(u8).initBorrowed("");

        const payload = protocol_types.Payload{
            .abort_request = .{
                .target_stream_id = stream_id,
                .reason = reason_owned,
            },
        };

        var env = protocol_types.Envelope{
            .stream_id = stream_id,
            .message_id = protocol_types.generateUuid(),
            .sequence = seq,
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
                if (self.pending_requests.fetchRemove(ack.acknowledged_id)) |pending| {
                    // Request acknowledged
                    var sid = pending.value.stream_id;
                    if (std.mem.allEqual(u8, &sid, 0)) sid = env.stream_id;
                    self.current_stream_id = sid;
                }
            },
            .nack => |nack| {
                // Mark request as failed
                if (self.pending_requests.fetchRemove(nack.rejected_id)) |pending| {
                    var sid = pending.value.stream_id;
                    if (std.mem.allEqual(u8, &sid, 0)) sid = env.stream_id;
                    try self.setStreamError(sid, nack.reason.slice());
                }

                // Store legacy error
                try self.setLastError(nack.reason.slice());
            },
            .event => |evt| {
                // Deep copy the event so the event stream owns its memory
                // This is necessary because the envelope's deinit will free
                // the original event's strings
                const owned_evt = try ai_types.cloneAssistantMessageEvent(self.allocator, evt);

                // Push to event stream for polling
                try self.event_stream.push(owned_evt);

                // Process through legacy reconstructor for compatibility
                try self.reconstructor.processEvent(owned_evt);

                // Process through per-stream reconstructor
                const recon = try self.ensureReconstructor(env.stream_id);
                try recon.processEvent(owned_evt);

                // Check for done event
                if (owned_evt == .done) {
                    const result = try recon.buildMessage(
                        owned_evt.done.reason,
                        owned_evt.done.message.timestamp,
                    );
                    try self.setStreamResult(env.stream_id, result);

                    // Legacy fields for current stream users
                    self.stream_complete = true;
                    if (self.last_result) |*prev| {
                        prev.deinit(self.allocator);
                    }
                    self.last_result = try ai_types.cloneAssistantMessage(self.allocator, self.stream_results.get(env.stream_id).?);
                }
            },
            .result => |result| {
                const result_copy = try ai_types.cloneAssistantMessage(self.allocator, result);
                try self.setStreamResult(env.stream_id, result_copy);

                // Legacy compatibility
                if (self.last_result) |*prev| {
                    prev.deinit(self.allocator);
                }
                self.last_result = try ai_types.cloneAssistantMessage(self.allocator, self.stream_results.get(env.stream_id).?);
                self.stream_complete = true;
            },
            .stream_error => |err| {
                const msg = err.message.slice();

                // Store per-stream + legacy error
                try self.setStreamError(env.stream_id, msg);
                try self.setLastError(msg);
                self.stream_complete = true;
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

    /// Get last result for current stream (legacy convenience)
    pub fn waitResult(self: *Self, timeout_ms: u64) !?ai_types.AssistantMessage {
        const stream_id = self.current_stream_id orelse return self.last_result;
        return self.waitResultFor(stream_id, timeout_ms);
    }

    /// Get result for a specific stream (blocking wait if not ready)
    pub fn waitResultFor(self: *Self, stream_id: protocol_types.Uuid, timeout_ms: u64) !?ai_types.AssistantMessage {
        const start_time = std.time.milliTimestamp();
        const deadline = start_time + @as(i64, @intCast(timeout_ms));

        while (!(self.stream_complete_flags.get(stream_id) orelse false)) {
            if (std.time.milliTimestamp() >= deadline) {
                return error.TimeoutExceeded;
            }
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }

        if (self.stream_errors.get(stream_id)) |_| {
            return error.StreamError;
        }

        if (self.stream_results.get(stream_id)) |result| {
            return result;
        }
        return null;
    }

    /// Check if current stream is complete (legacy)
    pub fn isComplete(self: *Self) bool {
        if (self.current_stream_id) |sid| {
            return self.isCompleteFor(sid);
        }
        return self.stream_complete;
    }

    /// Check if a specific stream is complete
    pub fn isCompleteFor(self: *Self, stream_id: protocol_types.Uuid) bool {
        return self.stream_complete_flags.get(stream_id) orelse false;
    }

    /// Reset all stream state
    pub fn reset(self: *Self) void {
        self.reconstructor.reset();
        self.pending_requests.clearRetainingCapacity();
        self.stream_sequences.clearRetainingCapacity();
        self.stream_complete_flags.clearRetainingCapacity();

        var recon_it = self.reconstructors.iterator();
        while (recon_it.next()) |entry| entry.value_ptr.deinit();
        self.reconstructors.clearRetainingCapacity();

        var result_it = self.stream_results.iterator();
        while (result_it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.stream_results.clearRetainingCapacity();

        var err_it = self.stream_errors.iterator();
        while (err_it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.stream_errors.clearRetainingCapacity();

        self.current_stream_id = null;
        self.stream_complete = false;
        self.sequence = 0;

        if (self.last_result) |*result| {
            result.deinit(self.allocator);
            self.last_result = null;
        }

        self.last_error.deinit(self.allocator);
        self.last_error = OwnedSlice(u8).initBorrowed("");
    }

    /// Get the current stream ID
    pub fn getCurrentStreamId(self: *Self) ?protocol_types.Uuid {
        return self.current_stream_id;
    }

    /// Get the last error message for current stream (legacy)
    pub fn getLastError(self: *Self) ?[]const u8 {
        if (!self.hasLastError()) return null;
        return self.last_error.slice();
    }

    /// Get error for a specific stream
    pub fn getLastErrorFor(self: *Self, stream_id: protocol_types.Uuid) ?[]const u8 {
        if (self.stream_errors.get(stream_id)) |err| {
            const msg = err.slice();
            if (msg.len > 0) return msg;
        }
        return null;
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
    defer env.deinit(allocator);

    try std.testing.expect(env.payload == .stream_request);
    try std.testing.expectEqualStrings("gpt-4", env.payload.stream_request.model.id);
    try std.testing.expectEqualSlices(u8, &message_id, &env.message_id);
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
            .acknowledged_id = message_id,
        } },
    };

    try client.processEnvelope(env);

    // Verify pending request was removed
    try std.testing.expect(!client.pending_requests.contains(message_id));

    // Verify stream_id was set from envelope
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
    const nack_reason = try allocator.dupe(u8, "Model not found");
    // Note: nack_reason ownership is transferred to envelope, will be freed by env.deinit()

    var env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .nack = .{
            .rejected_id = message_id,
            .reason = OwnedSlice(u8).initOwned(nack_reason),
            .error_code = .model_not_found,
        } },
    };

    try client.processEnvelope(env);

    // Verify pending request was removed
    try std.testing.expect(!client.pending_requests.contains(message_id));

    // Verify error was stored
    try std.testing.expect(client.getLastError() != null);
    try std.testing.expectEqualStrings("Model not found", client.getLastError().?);

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
    try std.testing.expect(env.payload.abort_request.getReason() != null);
    try std.testing.expectEqualStrings("User cancelled", env.payload.abort_request.getReason().?);
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
        .is_owned = true,
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
            .message = OwnedSlice(u8).initOwned(error_msg),
        } },
    };

    try client.processEnvelope(env);

    // Verify stream is complete
    try std.testing.expect(client.isComplete());

    // Verify error was stored
    try std.testing.expect(client.getLastError() != null);
    try std.testing.expectEqualStrings("Connection timeout", client.getLastError().?);

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
    client.last_error = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "test error"));

    // Reset
    client.reset();

    // Verify state is cleared
    try std.testing.expect(client.current_stream_id == null);
    try std.testing.expect(!client.stream_complete);
    try std.testing.expectEqual(@as(u64, 0), client.sequence);
    try std.testing.expect(client.last_result == null);
    try std.testing.expect(client.getLastError() == null);
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
    client.last_error = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "Test error"));

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
