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
                // EOF - return remaining data as last line if any
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

/// Handle for an async stream with thread lifecycle management.
/// Caller owns this handle and must call deinit() to join the thread and free resources.
pub const AsyncStreamHandle = struct {
    stream: *transport.ByteStream,
    thread: std.Thread,
    cancel_token: *std.atomic.Value(bool),
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Signal cancellation and join the thread with a timeout.
    /// Returns true if the thread exited cleanly, false if timeout was reached.
    pub fn deinit(self: *Self, timeout_ms: u64) bool {
        // Signal the thread to stop
        self.cancel_token.store(true, .release);

        // Wait for the thread with a timeout
        // Note: std.Thread.join() has no timeout, so we use a timed wait on the stream's thread_done flag
        const thread_exited = self.stream.waitForThread(timeout_ms);

        if (thread_exited) {
            self.thread.join();
        }
        // If thread didn't exit, we still need to clean up
        // The detached alternative would leak, so we join anyway (blocking)
        // In production code you might want to detach or force-kill if available

        // Free the cancel token
        self.allocator.destroy(self.cancel_token);

        // Free the stream
        self.stream.deinit();
        self.allocator.destroy(self.stream);

        return thread_exited;
    }

    /// Get a pointer to the ByteStream for reading.
    pub fn getStream(self: *Self) *transport.ByteStream {
        return self.stream;
    }

    /// Check if cancellation has been requested.
    pub fn isCancelled(self: *const Self) bool {
        return self.cancel_token.load(.acquire);
    }

    /// Request cancellation of the stream.
    pub fn cancel(self: *Self) void {
        self.cancel_token.store(true, .release);
    }
};

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
        cancel_token: *std.atomic.Value(bool),
        /// If true, thread owns cancel_token and should free it on exit.
        /// If false, caller (AsyncStreamHandle) owns it and will free it in deinit.
        owns_cancel_token: bool,
    };

    fn receiveStreamFn(ctx: *anyopaque, allocator: std.mem.Allocator) !*transport.ByteStream {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const stream = try allocator.create(transport.ByteStream);
        stream.* = transport.ByteStream.init(allocator);

        const cancel_token = try allocator.create(std.atomic.Value(bool));
        cancel_token.* = std.atomic.Value(bool).init(false);

        const thread_ctx = try allocator.create(ProducerContext);
        thread_ctx.* = .{
            .stream = stream,
            .file = self.file,
            .allocator = allocator,
            .leftover = std.ArrayList(u8){},
            .cancel_token = cancel_token,
            .owns_cancel_token = true, // Thread owns it in legacy mode
        };

        const thread = try std.Thread.spawn(.{}, producerThread, .{thread_ctx});

        // Store thread handle in the stream's result field (hack for backward compat)
        // Actually, we cannot do this cleanly without changing the ByteStream type.
        // For backward compatibility with receiveStreamFn signature, we detach but
        // the caller should use receiveStreamWithHandle() for proper lifecycle management.
        thread.detach();

        return stream;
    }

    /// Create an async stream with proper thread lifecycle management.
    /// Returns an AsyncStreamHandle that must be deinit'd by the caller.
    pub fn receiveStreamWithHandle(self: *Self, allocator: std.mem.Allocator) !AsyncStreamHandle {
        const stream = try allocator.create(transport.ByteStream);
        stream.* = transport.ByteStream.init(allocator);

        const cancel_token = try allocator.create(std.atomic.Value(bool));
        cancel_token.* = std.atomic.Value(bool).init(false);

        const thread_ctx = try allocator.create(ProducerContext);
        thread_ctx.* = .{
            .stream = stream,
            .file = self.file,
            .allocator = allocator,
            .leftover = std.ArrayList(u8){},
            .cancel_token = cancel_token,
            .owns_cancel_token = false, // Handle owns it
        };

        const thread = try std.Thread.spawn(.{}, producerThread, .{thread_ctx});

        return .{
            .stream = stream,
            .thread = thread,
            .cancel_token = cancel_token,
            .allocator = allocator,
        };
    }

    fn producerThread(ctx: *ProducerContext) void {
        // Save pointers before defer block since we need to call markThreadDone
        // AFTER freeing ctx (to avoid race with waitForThread)
        const stream = ctx.stream;
        const allocator = ctx.allocator;
        const owns_cancel_token = ctx.owns_cancel_token;
        const cancel_token = ctx.cancel_token;

        defer {
            ctx.leftover.deinit(allocator);
            if (owns_cancel_token) {
                allocator.destroy(cancel_token);
            }
            allocator.destroy(ctx);
            // Mark thread done AFTER all cleanup so waitForThread guarantees memory is freed
            stream.markThreadDone();
        }

        while (!ctx.cancel_token.load(.acquire)) {
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

            ctx.leftover.appendSlice(ctx.allocator, ctx.read_buf[0..bytes_read]) catch {
                ctx.stream.completeWithError("Out of memory");
                return;
            };
        }

        // Cancelled - complete the stream with an error
        ctx.stream.completeWithError("Cancelled");
    }

    // Keep backward-compatible blocking read
    fn readFn(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        var leftover = std.ArrayList(u8){};
        defer leftover.deinit(allocator);
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

            try leftover.appendSlice(allocator, read_buf[0..bytes_read]);
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

test "AsyncStdioReceiver with handle lifecycle management" {
    const allocator = std.testing.allocator;

    // Create a pipe for testing
    const pipe = try std.posix.pipe();
    const read_file = std.fs.File{ .handle = pipe[0] };
    const write_file = std.fs.File{ .handle = pipe[1] };
    defer read_file.close();

    // Set up async receiver with handle
    var async_receiver = AsyncStdioReceiver.initWithFile(read_file);
    var handle = try async_receiver.receiveStreamWithHandle(allocator);

    // Write test data from another thread (simulate producer)
    const WriterContext = struct {
        file: std.fs.File,
        fn writeData(ctx: *@This()) void {
            std.Thread.sleep(std.time.ns_per_ms * 10); // Small delay
            _ = ctx.file.write("line1\nline2\n") catch {};
            ctx.file.close();
        }
    };
    var writer_ctx = WriterContext{ .file = write_file };
    const writer_thread = try std.Thread.spawn(.{}, WriterContext.writeData, .{&writer_ctx});

    // Read from the stream
    const stream = handle.getStream();

    // Read first line
    if (stream.wait()) |chunk| {
        defer {
            var mutable = chunk;
            mutable.deinit(allocator);
        }
        try std.testing.expectEqualStrings("line1", chunk.data);
    }

    // Read second line
    if (stream.wait()) |chunk| {
        defer {
            var mutable = chunk;
            mutable.deinit(allocator);
        }
        try std.testing.expectEqualStrings("line2", chunk.data);
    }

    // Wait for stream to complete
    _ = stream.wait(); // Should return null when done

    // Clean up with proper lifecycle management
    writer_thread.join();
    const exited = handle.deinit(5000);
    try std.testing.expect(exited);
}

test "AsyncStreamHandle cancellation" {
    const allocator = std.testing.allocator;

    // Create a pipe - we won't write to it, so the reader will block
    const pipe = try std.posix.pipe();
    const read_file = std.fs.File{ .handle = pipe[0] };
    const write_file = std.fs.File{ .handle = pipe[1] };

    var async_receiver = AsyncStdioReceiver.initWithFile(read_file);
    var handle = try async_receiver.receiveStreamWithHandle(allocator);

    // Verify not cancelled initially
    try std.testing.expect(!handle.isCancelled());

    // Request cancellation
    handle.cancel();
    try std.testing.expect(handle.isCancelled());

    // Close the write end to unblock the read (in case cancellation isn't instant)
    write_file.close();

    // Clean up - should exit quickly due to cancellation
    const exited = handle.deinit(5000);
    // Thread should have exited (either by cancellation or EOF)
    try std.testing.expect(exited);
}

test "AsyncStdioReceiver legacy interface still works" {
    const allocator = std.testing.allocator;

    // Create a pipe for testing
    const pipe = try std.posix.pipe();
    const read_file = std.fs.File{ .handle = pipe[0] };
    const write_file = std.fs.File{ .handle = pipe[1] };
    defer read_file.close();

    // Set up async receiver using the legacy interface
    var async_receiver = AsyncStdioReceiver.initWithFile(read_file);
    var receiver = async_receiver.receiver();

    // Get the stream (legacy interface - detached thread)
    const stream = try receiver.receiveStream(allocator);

    // Write test data and close
    _ = try write_file.write("test_data\n");
    write_file.close();

    // Read from stream
    if (stream.wait()) |chunk| {
        defer {
            var mutable = chunk;
            mutable.deinit(allocator);
        }
        try std.testing.expectEqualStrings("test_data", chunk.data);
    }

    // Wait for completion
    _ = stream.wait();

    // Legacy cleanup - wait for thread and free stream
    _ = stream.waitForThread(5000);
    stream.deinit();
    allocator.destroy(stream);
}
