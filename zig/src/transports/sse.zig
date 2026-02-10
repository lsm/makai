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

    const event_json = try transport.serializeEvent(
        .{ .text_delta = .{ .index = 0, .delta = "Hello" } },
        allocator,
    );
    defer allocator.free(event_json);
    try s.write(event_json);

    const result_json = try transport.serializeResult(.{
        .content = &[_]@import("types").ContentBlock{},
        .usage = .{},
        .stop_reason = .stop,
        .model = "test",
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
    allocator.free(msg2.result.model);
    allocator.free(msg2.result.content);
}
