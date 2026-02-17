const std = @import("std");
const transport = @import("transport");
const sse_parser = @import("sse_parser");

/// SSE Sender — writes events in Server-Sent Events wire format.
/// Each write becomes: "data: <json>\n\n"
pub const SseSender = struct {
    file: std.fs.File,

    pub fn init(file: std.fs.File) SseSender {
        return .{ .file = file };
    }

    pub fn sender(self: *SseSender) transport.Sender {
        return .{
            .context = @ptrCast(self),
            .write_fn = writeFn,
        };
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) !void {
        const self: *SseSender = @ptrCast(@alignCast(ctx));
        try self.file.writeAll("data: ");
        try self.file.writeAll(data);
        try self.file.writeAll("\n\n");
    }
};

/// SSE Receiver — reads from a byte source, feeds into SSEParser,
/// and yields one data payload per read() call.
pub const SseReceiver = struct {
    parser: sse_parser.SSEParser,
    file: std.fs.File,
    read_buf: [4096]u8 = undefined,
    /// Pending events from last parser.feed() — stored as duped data strings
    pending: std.ArrayList([]u8),
    pending_index: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(file: std.fs.File, allocator: std.mem.Allocator) SseReceiver {
        return .{
            .parser = sse_parser.SSEParser.init(allocator),
            .file = file,
            .pending = std.ArrayList([]u8){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SseReceiver) void {
        for (self.pending.items[self.pending_index..]) |item| {
            self.allocator.free(item);
        }
        self.pending.deinit(self.allocator);
        self.parser.deinit();
    }

    pub fn receiver(self: *SseReceiver) transport.Receiver {
        return .{
            .context = @ptrCast(self),
            .read_fn = readFn,
            .close_fn = closeFn,
        };
    }

    fn readFn(ctx: *anyopaque, allocator: std.mem.Allocator) !?[]const u8 {
        const self: *SseReceiver = @ptrCast(@alignCast(ctx));

        while (true) {
            // Drain any pending events
            if (self.pending_index < self.pending.items.len) {
                const data = self.pending.items[self.pending_index];
                self.pending_index += 1;

                // If caller allocator differs from internal, re-dupe; otherwise transfer ownership
                if (allocator.ptr == self.allocator.ptr) {
                    return data;
                } else {
                    const copy = try allocator.dupe(u8, data);
                    self.allocator.free(data);
                    return copy;
                }
            }

            // All pending consumed — clear for next batch
            self.pending.clearRetainingCapacity();
            self.pending_index = 0;

            // Read more bytes from the source
            const bytes_read = self.file.read(&self.read_buf) catch return null;
            if (bytes_read == 0) return null; // EOF

            // Feed to parser — parser returns slice of SSEEvent
            const events = try self.parser.feed(self.read_buf[0..bytes_read]);

            // Dupe the data strings before next feed() invalidates them
            for (events) |event| {
                const duped = try self.allocator.dupe(u8, event.data);
                try self.pending.append(self.allocator, duped);
            }
        }
    }

    fn closeFn(ctx: *anyopaque) void {
        const self: *SseReceiver = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};

// --- Async implementations ---

/// Async SSE Sender — writes events in Server-Sent Events wire format.
pub const AsyncSseSender = struct {
    file: std.fs.File,

    pub fn init(file: std.fs.File) AsyncSseSender {
        return .{ .file = file };
    }

    pub fn sender(self: *AsyncSseSender) transport.AsyncSender {
        return .{
            .context = @ptrCast(self),
            .write_fn = writeFn,
        };
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) !void {
        const self: *AsyncSseSender = @ptrCast(@alignCast(ctx));
        try self.file.writeAll("data: ");
        try self.file.writeAll(data);
        try self.file.writeAll("\n\n");
    }
};

/// Async SSE Receiver — produces ByteStream with parsed SSE data payloads.
pub const AsyncSseReceiver = struct {
    file: std.fs.File,

    const Self = @This();

    pub fn init(file: std.fs.File) Self {
        return .{ .file = file };
    }

    pub fn receiver(self: *Self) transport.AsyncReceiver {
        return .{
            .context = @ptrCast(self),
            .receive_stream_fn = receiveStreamFn,
            .read_fn = readFn,
        };
    }

    const ProducerContext = struct {
        stream: *transport.ByteStream,
        file: std.fs.File,
        allocator: std.mem.Allocator,
        parser: sse_parser.SSEParser,
        read_buf: [4096]u8 = undefined,
    };

    fn receiveStreamFn(ctx: *anyopaque, allocator: std.mem.Allocator) !*transport.ByteStream {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const stream = try allocator.create(transport.ByteStream);
        stream.* = transport.ByteStream.init(allocator);

        const thread_ctx = try allocator.create(ProducerContext);
        thread_ctx.* = .{
            .stream = stream,
            .file = self.file,
            .allocator = allocator,
            .parser = sse_parser.SSEParser.init(allocator),
        };

        const thread = try std.Thread.spawn(.{}, producerThread, .{thread_ctx});
        thread.detach();

        return stream;
    }

    fn producerThread(ctx: *ProducerContext) void {
        defer {
            ctx.parser.deinit();
            ctx.stream.markThreadDone();
            ctx.allocator.destroy(ctx);
        }

        while (true) {
            // Read more bytes from the source
            const bytes_read = ctx.file.read(&ctx.read_buf) catch {
                ctx.stream.completeWithError("Read error");
                return;
            };

            if (bytes_read == 0) {
                // EOF
                ctx.stream.complete({});
                return;
            }

            // Feed to parser
            const events = ctx.parser.feed(ctx.read_buf[0..bytes_read]) catch {
                ctx.stream.completeWithError("SSE parse error");
                return;
            };

            // Push each event as a ByteChunk
            for (events) |event| {
                const data = ctx.allocator.dupe(u8, event.data) catch {
                    ctx.stream.completeWithError("Out of memory");
                    return;
                };
                const chunk = transport.ByteChunk{
                    .data = data,
                    .owned = true,
                };
                ctx.stream.push(chunk) catch {
                    ctx.stream.completeWithError("Stream queue full");
                    return;
                };
            }
        }
    }

    // Keep backward-compatible blocking read
    fn readFn(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        var parser = sse_parser.SSEParser.init(allocator);
        defer parser.deinit();
        var read_buf: [4096]u8 = undefined;
        var pending = std.ArrayList([]u8).init(allocator);
        defer {
            for (pending.items) |item| {
                allocator.free(item);
            }
            pending.deinit(allocator);
        }
        var pending_index: usize = 0;

        while (true) {
            // Drain any pending events
            if (pending_index < pending.items.len) {
                const data = pending.items[pending_index];
                pending_index += 1;
                return data; // Transfer ownership
            }

            // All pending consumed — clear for next batch
            pending.clearRetainingCapacity();
            pending_index = 0;

            // Read more bytes from the source
            const bytes_read = self.file.read(&read_buf) catch return null;
            if (bytes_read == 0) return null; // EOF

            // Feed to parser
            const events = try parser.feed(read_buf[0..bytes_read]);

            // Dupe the data strings
            for (events) |event| {
                const duped = try allocator.dupe(u8, event.data);
                try pending.append(allocator, duped);
            }
        }
    }
};

// Tests

test "SseSender writes SSE format" {
    // Create a pipe
    const pipe = try std.posix.pipe();
    const read_file = std.fs.File{ .handle = pipe[0] };
    const write_file = std.fs.File{ .handle = pipe[1] };
    defer read_file.close();

    var sse_sender = SseSender.init(write_file);
    var s = sse_sender.sender();

    try s.write("{\"type\":\"ping\"}");
    try s.write("{\"type\":\"start\",\"model\":\"test\"}");
    write_file.close();

    // Read raw bytes and verify SSE format
    var buf: [1024]u8 = undefined;
    const n = try read_file.readAll(&buf);
    const output = buf[0..n];

    const expected = "data: {\"type\":\"ping\"}\n\ndata: {\"type\":\"start\",\"model\":\"test\"}\n\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "SseReceiver parses SSE format" {
    const allocator = std.testing.allocator;

    // Create a pipe
    const pipe = try std.posix.pipe();
    const read_file = std.fs.File{ .handle = pipe[0] };
    const write_file = std.fs.File{ .handle = pipe[1] };
    defer read_file.close();

    // Write SSE-formatted data
    try write_file.writeAll("data: {\"type\":\"ping\"}\n\ndata: {\"type\":\"start\",\"model\":\"test\"}\n\n");
    write_file.close();

    var sse_recv = SseReceiver.init(read_file, allocator);
    defer sse_recv.deinit();
    var r = sse_recv.receiver();

    const line1 = try r.read(allocator);
    try std.testing.expect(line1 != null);
    try std.testing.expectEqualStrings("{\"type\":\"ping\"}", line1.?);
    allocator.free(line1.?);

    const line2 = try r.read(allocator);
    try std.testing.expect(line2 != null);
    try std.testing.expectEqualStrings("{\"type\":\"start\",\"model\":\"test\"}", line2.?);
    allocator.free(line2.?);

    const line3 = try r.read(allocator);
    try std.testing.expect(line3 == null);
}

test "SseSender and SseReceiver round-trip with transport" {
    const allocator = std.testing.allocator;

    // Create a pipe
    const pipe = try std.posix.pipe();
    const read_file = std.fs.File{ .handle = pipe[0] };
    const write_file = std.fs.File{ .handle = pipe[1] };
    defer read_file.close();

    // Serialize a real event through SseSender
    var sse_sender = SseSender.init(write_file);
    var s = sse_sender.sender();

    const ai_types = @import("ai_types");
    const empty_partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const event_json = try transport.serializeEvent(
        .{ .text_delta = .{ .content_index = 0, .delta = "Hello", .partial = empty_partial } },
        allocator,
    );
    defer allocator.free(event_json);
    try s.write(event_json);

    const result_json = try transport.serializeResult(.{
        .content = &[_]ai_types.AssistantContent{},
        .usage = .{},
        .stop_reason = .stop,
        .model = "test",
        .api = "test-api",
        .provider = "test-provider",
        .timestamp = 1,
    }, allocator);
    defer allocator.free(result_json);
    try s.write(result_json);

    write_file.close();

    // Read back through SseReceiver + deserialize
    var sse_recv = SseReceiver.init(read_file, allocator);
    defer sse_recv.deinit();
    var r = sse_recv.receiver();

    const line1 = try r.read(allocator);
    try std.testing.expect(line1 != null);
    defer allocator.free(line1.?);
    const msg1 = try transport.deserialize(line1.?, allocator);
    try std.testing.expect(msg1 == .event);
    try std.testing.expect(msg1.event == .text_delta);
    allocator.free(msg1.event.text_delta.delta);

    const line2 = try r.read(allocator);
    try std.testing.expect(line2 != null);
    defer allocator.free(line2.?);
    const msg2 = try transport.deserialize(line2.?, allocator);
    try std.testing.expect(msg2 == .result);
    msg2.result.deinit(allocator);
}
