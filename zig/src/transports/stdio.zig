const std = @import("std");
const transport = @import("transport");

pub const StdioSender = struct {
    file: std.fs.File,

    pub fn init() StdioSender {
        return .{ .file = std.io.getStdOut() };
    }

    pub fn initWithFile(file: std.fs.File) StdioSender {
        return .{ .file = file };
    }

    pub fn sender(self: *StdioSender) transport.Sender {
        return .{
            .context = @ptrCast(self),
            .write_fn = writeFn,
        };
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) !void {
        const self: *StdioSender = @ptrCast(@alignCast(ctx));
        try self.file.writeAll(data);
        try self.file.writeAll("\n");
    }
};

pub const StdioReceiver = struct {
    file: std.fs.File,
    read_buf: [4096]u8 = undefined,
    /// Unprocessed data carried over from previous read
    leftover: std.ArrayList(u8) = std.ArrayList(u8){},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StdioReceiver {
        return .{ .file = std.io.getStdIn(), .allocator = allocator };
    }

    pub fn initWithFile(file: std.fs.File, allocator: std.mem.Allocator) StdioReceiver {
        return .{ .file = file, .allocator = allocator };
    }

    pub fn deinit(self: *StdioReceiver) void {
        self.leftover.deinit(self.allocator);
    }

    pub fn receiver(self: *StdioReceiver) transport.Receiver {
        return .{
            .context = @ptrCast(self),
            .read_fn = readFn,
        };
    }

    fn readFn(ctx: *anyopaque, allocator: std.mem.Allocator) !?[]const u8 {
        const self: *StdioReceiver = @ptrCast(@alignCast(ctx));

        while (true) {
            // Check leftover buffer for a complete line
            if (std.mem.indexOfScalar(u8, self.leftover.items, '\n')) |nl_pos| {
                const line = try allocator.dupe(u8, self.leftover.items[0..nl_pos]);
                // Remove consumed bytes including the newline
                const remaining = self.leftover.items[nl_pos + 1 ..];
                std.mem.copyForwards(u8, self.leftover.items[0..remaining.len], remaining);
                self.leftover.shrinkRetainingCapacity(remaining.len);
                return line;
            }

            // Read more data
            const bytes_read = self.file.read(&self.read_buf) catch return null;
            if (bytes_read == 0) {
                // EOF — return remaining data as last line if any
                if (self.leftover.items.len > 0) {
                    const line = try allocator.dupe(u8, self.leftover.items);
                    self.leftover.clearRetainingCapacity();
                    return line;
                }
                return null;
            }

            try self.leftover.appendSlice(self.allocator, self.read_buf[0..bytes_read]);
        }
    }
};

// --- Async implementations ---

pub const AsyncStdioSender = struct {
    file: std.fs.File,

    pub fn init() AsyncStdioSender {
        return .{ .file = std.io.getStdOut() };
    }

    pub fn initWithFile(file: std.fs.File) AsyncStdioSender {
        return .{ .file = file };
    }

    pub fn sender(self: *AsyncStdioSender) transport.AsyncSender {
        return .{
            .context = @ptrCast(self),
            .write_fn = writeFn,
        };
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) !void {
        const self: *AsyncStdioSender = @ptrCast(@alignCast(ctx));
        try self.file.writeAll(data);
        try self.file.writeAll("\n");
    }
};

pub const AsyncStdioReceiver = struct {
    file: std.fs.File,

    const Self = @This();

    pub fn init() Self {
        return .{ .file = std.io.getStdIn() };
    }

    pub fn initWithFile(file: std.fs.File) Self {
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
        leftover: std.ArrayList(u8),
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
            .leftover = std.ArrayList(u8).init(allocator),
        };

        const thread = try std.Thread.spawn(.{}, producerThread, .{thread_ctx});
        thread.detach();

        return stream;
    }

    fn producerThread(ctx: *ProducerContext) void {
        defer {
            ctx.leftover.deinit();
            ctx.stream.markThreadDone();
            ctx.allocator.destroy(ctx);
        }

        while (true) {
            // Check for complete line in leftover
            if (std.mem.indexOfScalar(u8, ctx.leftover.items, '\n')) |nl_pos| {
                const line = ctx.leftover.items[0..nl_pos];
                const chunk = transport.ByteChunk{
                    .data = ctx.allocator.dupe(u8, line) catch {
                        ctx.stream.completeWithError("Out of memory");
                        return;
                    },
                    .owned = true,
                };
                ctx.stream.push(chunk) catch {
                    ctx.stream.completeWithError("Stream queue full");
                    return;
                };
                // Remove consumed bytes
                const remaining = ctx.leftover.items[nl_pos + 1 ..];
                std.mem.copyForwards(u8, ctx.leftover.items[0..remaining.len], remaining);
                ctx.leftover.shrinkRetainingCapacity(remaining.len);
                continue;
            }

            // Read more data
            const bytes_read = ctx.file.read(&ctx.read_buf) catch {
                ctx.stream.completeWithError("Read error");
                return;
            };

            if (bytes_read == 0) {
                // EOF - send any remaining data
                if (ctx.leftover.items.len > 0) {
                    const chunk = transport.ByteChunk{
                        .data = ctx.allocator.dupe(u8, ctx.leftover.items) catch {
                            ctx.stream.completeWithError("Out of memory");
                            return;
                        },
                        .owned = true,
                    };
                    ctx.stream.push(chunk) catch {};
                }
                ctx.stream.complete({});
                return;
            }

            ctx.leftover.appendSlice(ctx.read_buf[0..bytes_read]) catch {
                ctx.stream.completeWithError("Out of memory");
                return;
            };
        }
    }

    // Keep backward-compatible blocking read
    fn readFn(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        var leftover = std.ArrayList(u8).init(allocator);
        defer leftover.deinit();
        var read_buf: [4096]u8 = undefined;

        while (true) {
            // Check for complete line
            if (std.mem.indexOfScalar(u8, leftover.items, '\n')) |nl_pos| {
                const line = try allocator.dupe(u8, leftover.items[0..nl_pos]);
                return line;
            }

            // Read more data
            const bytes_read = self.file.read(&read_buf) catch return null;
            if (bytes_read == 0) {
                // EOF - return remaining data if any
                if (leftover.items.len > 0) {
                    return try allocator.dupe(u8, leftover.items);
                }
                return null;
            }

            try leftover.appendSlice(read_buf[0..bytes_read]);
        }
    }
};

// Tests

test "StdioSender and StdioReceiver round-trip via pipe" {
    const allocator = std.testing.allocator;

    // Create a pipe for testing
    const pipe = try std.posix.pipe();
    const read_file = std.fs.File{ .handle = pipe[0] };
    const write_file = std.fs.File{ .handle = pipe[1] };
    defer read_file.close();

    // Set up sender and receiver
    var stdio_sender = StdioSender.initWithFile(write_file);
    var stdio_receiver = StdioReceiver.initWithFile(read_file, allocator);
    defer stdio_receiver.deinit();

    var s = stdio_sender.sender();
    var r = stdio_receiver.receiver();

    // Write test data
    try s.write("{\"type\":\"ping\"}");
    try s.write("{\"type\":\"start\",\"model\":\"test\"}");

    // Close write end so receiver gets EOF after reading
    write_file.close();

    // Read it back
    const line1 = try r.read(allocator);
    try std.testing.expect(line1 != null);
    try std.testing.expectEqualStrings("{\"type\":\"ping\"}", line1.?);
    allocator.free(line1.?);

    const line2 = try r.read(allocator);
    try std.testing.expect(line2 != null);
    try std.testing.expectEqualStrings("{\"type\":\"start\",\"model\":\"test\"}", line2.?);
    allocator.free(line2.?);

    // EOF
    const line3 = try r.read(allocator);
    try std.testing.expect(line3 == null);
}
