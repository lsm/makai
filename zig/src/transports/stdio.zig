const std = @import("std");
const compat = @import("compat");
const transport = @import("transport");

pub const default_line_bytes: usize = 1024 * 1024;

const LineFramer = struct {
    const Outcome = union(enum) {
        line: struct { start: usize, len: usize },
        line_too_large,
    };

    buffer: std.ArrayList(u8) = .empty,
    queued_bytes: std.ArrayList(u8) = .empty,
    outcomes: std.ArrayList(Outcome) = .empty,
    outcome_head: usize = 0,
    allocator: std.mem.Allocator,
    limit: usize,
    discarding_line: bool = false,

    fn init(allocator: std.mem.Allocator, limit: usize) LineFramer {
        return .{ .allocator = allocator, .limit = limit };
    }

    fn deinit(self: *LineFramer) void {
        self.buffer.deinit(self.allocator);
        self.queued_bytes.deinit(self.allocator);
        self.outcomes.deinit(self.allocator);
    }

    fn append(self: *LineFramer, bytes: []const u8) !void {
        const buffer_capacity = @min(self.limit, try std.math.add(usize, self.buffer.items.len, bytes.len));
        const queued_capacity = try std.math.add(usize, self.queued_bytes.items.len, try std.math.add(usize, self.buffer.items.len, bytes.len));
        const outcomes_capacity = try std.math.add(usize, self.outcomes.items.len, bytes.len +| 1);
        try self.buffer.ensureTotalCapacity(self.allocator, buffer_capacity);
        try self.queued_bytes.ensureTotalCapacity(self.allocator, queued_capacity);
        try self.outcomes.ensureTotalCapacity(self.allocator, outcomes_capacity);

        for (bytes) |byte| {
            if (self.discarding_line) {
                if (byte == '\n') {
                    self.discarding_line = false;
                    self.outcomes.appendAssumeCapacity(.line_too_large);
                }
                continue;
            }

            if (byte == '\n') {
                self.queueCurrentLineAssumeCapacity();
            } else {
                if (self.buffer.items.len >= self.limit) {
                    self.buffer.clearRetainingCapacity();
                    self.discarding_line = true;
                    continue;
                }
                self.buffer.appendAssumeCapacity(byte);
            }
        }
    }

    fn takeLine(self: *LineFramer, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.outcome_head == self.outcomes.items.len) return null;
        return switch (self.outcomes.items[self.outcome_head]) {
            .line => |line| blk: {
                const copy = try allocator.dupe(u8, self.queued_bytes.items[line.start..][0..line.len]);
                self.advanceOutcome();
                break :blk copy;
            },
            .line_too_large => {
                self.advanceOutcome();
                return error.LineTooLarge;
            },
        };
    }

    fn takeEof(self: *LineFramer, allocator: std.mem.Allocator) !?[]const u8 {
        try self.finishEof();
        return self.takeLine(allocator);
    }

    fn finishEof(self: *LineFramer) !void {
        if (self.discarding_line) {
            try self.outcomes.append(self.allocator, .line_too_large);
            self.discarding_line = false;
        } else if (self.buffer.items.len > 0) {
            try self.queued_bytes.ensureUnusedCapacity(self.allocator, self.buffer.items.len);
            try self.outcomes.ensureUnusedCapacity(self.allocator, 1);
            self.queueCurrentLineAssumeCapacity();
        }
    }

    fn queueCurrentLineAssumeCapacity(self: *LineFramer) void {
        const start = self.queued_bytes.items.len;
        self.queued_bytes.appendSliceAssumeCapacity(self.buffer.items);
        self.outcomes.appendAssumeCapacity(.{ .line = .{ .start = start, .len = self.buffer.items.len } });
        self.buffer.clearRetainingCapacity();
    }

    fn advanceOutcome(self: *LineFramer) void {
        self.outcome_head += 1;
        if (self.outcome_head == self.outcomes.items.len) {
            self.outcomes.clearRetainingCapacity();
            self.queued_bytes.clearRetainingCapacity();
            self.outcome_head = 0;
        }
    }
};

pub const StdioSender = struct {
    file: compat.stdio.File,

    pub fn init() StdioSender {
        return .{ .file = compat.stdio.stdout() };
    }

    pub fn initWithFile(file: compat.stdio.File) StdioSender {
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
        try compat.stdio.writeLine(self.file, data);
    }
};

pub const StdioReceiver = struct {
    file: compat.stdio.File,
    read_buf: [4096]u8 = undefined,
    /// Unprocessed data carried over from previous read
    framer: LineFramer,
    allocator: std.mem.Allocator,
    cancel_token: ?*std.atomic.Value(bool) = null,
    last_status: ReadStatus = .pending,

    pub const ReadStatus = enum {
        pending,
        eof,
        would_block,
        cancelled,
        read_error,
    };

    pub fn init(allocator: std.mem.Allocator) StdioReceiver {
        return initWithFileAndLimit(compat.stdio.stdin(), allocator, default_line_bytes);
    }

    pub fn initWithFile(file: compat.stdio.File, allocator: std.mem.Allocator) StdioReceiver {
        return initWithFileAndLimit(file, allocator, default_line_bytes);
    }

    pub fn initWithFileAndLimit(file: compat.stdio.File, allocator: std.mem.Allocator, line_bytes: usize) StdioReceiver {
        return .{ .file = file, .framer = LineFramer.init(allocator, line_bytes), .allocator = allocator };
    }

    pub fn initWithFileAndCancelToken(file: compat.stdio.File, allocator: std.mem.Allocator, cancel_token: *std.atomic.Value(bool)) StdioReceiver {
        return .{ .file = file, .framer = LineFramer.init(allocator, default_line_bytes), .allocator = allocator, .cancel_token = cancel_token };
    }

    pub fn deinit(self: *StdioReceiver) void {
        self.framer.deinit();
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
            if (try self.framer.takeLine(allocator)) |line| return line;

            // Read more data
            if (self.cancel_token) |token| {
                if (token.load(.acquire)) {
                    self.last_status = .cancelled;
                    return null;
                }
            }
            const bytes_read = compat.stdio.read(self.file, &self.read_buf) catch |err| {
                if (err == error.EndOfStream) {
                    self.last_status = .eof;
                    return try self.framer.takeEof(allocator);
                }
                if (err == error.WouldBlock) {
                    self.last_status = .would_block;
                    return null;
                }
                self.last_status = .read_error;
                return null;
            };
            if (bytes_read == 0) {
                // EOF - return remaining data as last line if any
                if (try self.framer.takeEof(allocator)) |line| {
                    self.last_status = .eof;
                    return line;
                }
                self.last_status = .eof;
                return null;
            }
            self.last_status = .pending;

            try self.framer.append(self.read_buf[0..bytes_read]);
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
    fallback_receiver: ?*StdioReceiver = null,

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

        if (self.fallback_receiver) |receiver| {
            receiver.file = compat.stdio.setBlockingFile(receiver.file) catch receiver.file;
            receiver.deinit();
            self.allocator.destroy(receiver);
            self.fallback_receiver = null;
        }

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
    file: compat.stdio.File,

    pub fn init() AsyncStdioSender {
        return .{ .file = compat.stdio.stdout() };
    }

    pub fn initWithFile(file: compat.stdio.File) AsyncStdioSender {
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
        try compat.stdio.writeLine(self.file, data);
    }
};

pub const AsyncStdioReceiver = struct {
    file: compat.stdio.File,
    line_limit: usize,
    compatibility_framer: ?LineFramer = null,
    compatibility_eof: bool = false,

    const Self = @This();

    pub fn init() Self {
        return .{ .file = compat.stdio.stdin(), .line_limit = default_line_bytes };
    }

    pub fn initWithFile(file: compat.stdio.File) Self {
        return initWithFileAndLimit(file, default_line_bytes);
    }

    pub fn initWithFileAndLimit(file: compat.stdio.File, line_bytes: usize) Self {
        return .{ .file = file, .line_limit = line_bytes };
    }

    pub fn deinit(self: *Self) void {
        if (self.compatibility_framer) |*framer| framer.deinit();
        self.compatibility_framer = null;
        self.compatibility_eof = false;
    }

    pub fn receiver(self: *Self) transport.AsyncReceiver {
        return .{
            .context = @ptrCast(self),
            .receive_stream_fn = receiveStreamFn,
            .read_fn = readFn,
            .close_fn = closeFn,
        };
    }

    const ProducerContext = struct {
        stream: *transport.ByteStream,
        file: compat.stdio.File,
        allocator: std.mem.Allocator,
        framer: LineFramer,
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
            .framer = LineFramer.init(allocator, self.line_limit),
            .cancel_token = cancel_token,
            .owns_cancel_token = true, // Thread owns it in legacy mode
        };

        const thread = try std.Thread.spawn(.{}, producerThread, .{thread_ctx});

        // Keep this legacy receiveStream() path for transport interface callers
        // that do not yet use receiveStreamWithHandle(). It detaches the producer
        // for backward compatibility, while the handle API below keeps lifecycle
        // ownership explicit.
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
            .framer = LineFramer.init(allocator, self.line_limit),
            .cancel_token = cancel_token,
            .owns_cancel_token = false, // Handle owns it
        };

        const thread = try std.Thread.spawn(.{}, producerThread, .{thread_ctx});

        return .{
            .stream = stream,
            .thread = thread,
            .cancel_token = cancel_token,
            .allocator = allocator,
            .fallback_receiver = null,
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
            ctx.framer.deinit();
            if (owns_cancel_token) {
                allocator.destroy(cancel_token);
            }
            allocator.destroy(ctx);
            // Mark thread done AFTER all cleanup so waitForThread guarantees memory is freed
            stream.markThreadDone();
        }

        while (!ctx.cancel_token.load(.acquire)) {
            // Check for complete line in leftover
            if (ctx.framer.takeLine(ctx.allocator) catch |err| {
                ctx.stream.completeWithError(if (err == error.LineTooLarge) "stdio line too large" else "Out of memory");
                return;
            }) |line| {
                const chunk = transport.ByteChunk{ .data = line, .owned = true };
                ctx.stream.push(chunk) catch {
                    var owned_chunk = chunk;
                    owned_chunk.deinit(ctx.allocator);
                    ctx.stream.completeWithError("Stream queue full");
                    return;
                };
                continue;
            }

            // Read more data
            const bytes_read = compat.stdio.read(ctx.file, &ctx.read_buf) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.yield() catch {};
                    continue;
                }
                if (err == error.EndOfStream) {
                    if (ctx.framer.takeEof(ctx.allocator) catch |framing_err| {
                        ctx.stream.completeWithError(if (framing_err == error.LineTooLarge) "stdio line too large" else "Out of memory");
                        return;
                    }) |line| {
                        const chunk = transport.ByteChunk{ .data = line, .owned = true };
                        ctx.stream.push(chunk) catch {
                            var owned_chunk = chunk;
                            owned_chunk.deinit(ctx.allocator);
                            ctx.stream.completeWithError("Stream queue full");
                            return;
                        };
                    }
                    ctx.stream.complete({});
                    return;
                }
                ctx.stream.completeWithError("Read error");
                return;
            };

            if (bytes_read == 0) {
                // EOF - send any remaining data
                if (ctx.framer.takeEof(ctx.allocator) catch |framing_err| {
                    ctx.stream.completeWithError(if (framing_err == error.LineTooLarge) "stdio line too large" else "Out of memory");
                    return;
                }) |line| {
                    const chunk = transport.ByteChunk{ .data = line, .owned = true };
                    ctx.stream.push(chunk) catch {
                        var owned_chunk = chunk;
                        owned_chunk.deinit(ctx.allocator);
                        ctx.stream.completeWithError("Stream queue full");
                        return;
                    };
                }
                ctx.stream.complete({});
                return;
            }

            ctx.framer.append(ctx.read_buf[0..bytes_read]) catch {
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
        if (self.compatibility_framer == null) {
            self.compatibility_framer = LineFramer.init(std.heap.page_allocator, self.line_limit);
        }
        const framer = &self.compatibility_framer.?;
        var read_buf: [4096]u8 = undefined;

        while (true) {
            // Check for complete line
            if (try framer.takeLine(allocator)) |line| return line;

            if (self.compatibility_eof) {
                self.deinit();
                return null;
            }

            // Read more data
            const bytes_read = compat.stdio.read(self.file, &read_buf) catch |err| {
                if (err == error.EndOfStream) {
                    try framer.finishEof();
                    self.compatibility_eof = true;
                    continue;
                }
                self.deinit();
                return null;
            };
            if (bytes_read == 0) {
                try framer.finishEof();
                self.compatibility_eof = true;
                continue;
            }

            try framer.append(read_buf[0..bytes_read]);
        }
    }

    fn closeFn(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};

// Tests

test "LineFramer bounds logical lines independent of chunking" {
    const allocator = std.testing.allocator;
    var framer = LineFramer.init(allocator, 4);
    defer framer.deinit();

    try framer.append("ab");
    try framer.append("cd\n");
    const exact = (try framer.takeLine(allocator)).?;
    defer allocator.free(exact);
    try std.testing.expectEqualStrings("abcd", exact);

    try framer.append("a\nbb\nccc\n");
    const first = (try framer.takeLine(allocator)).?;
    defer allocator.free(first);
    const second = (try framer.takeLine(allocator)).?;
    defer allocator.free(second);
    const third = (try framer.takeLine(allocator)).?;
    defer allocator.free(third);
    try std.testing.expectEqualStrings("a", first);
    try std.testing.expectEqualStrings("bb", second);
    try std.testing.expectEqualStrings("ccc", third);

    try framer.append("tail");
    const eof_line = (try framer.takeEof(allocator)).?;
    defer allocator.free(eof_line);
    try std.testing.expectEqualStrings("tail", eof_line);
}

test "LineFramer discards an oversized line and preserves neighbors" {
    const allocator = std.testing.allocator;
    var framer = LineFramer.init(allocator, 4);
    defer framer.deinit();

    try framer.append("ok\nabcde\nbadbad\nnext\n");
    const before = (try framer.takeLine(allocator)).?;
    defer allocator.free(before);
    try std.testing.expectError(error.LineTooLarge, framer.takeLine(allocator));
    try std.testing.expectError(error.LineTooLarge, framer.takeLine(allocator));
    const after = (try framer.takeLine(allocator)).?;
    defer allocator.free(after);
    try std.testing.expectEqualStrings("ok", before);
    try std.testing.expectEqualStrings("next", after);
    try std.testing.expect((try framer.takeEof(allocator)) == null);

    try framer.append("abcd");
    try framer.append("e");
    try std.testing.expectError(error.LineTooLarge, framer.takeEof(allocator));
}

test "LineFramer allocation failures preserve pending outcomes" {
    const allocator = std.testing.allocator;
    var framer = LineFramer.init(allocator, 8);
    defer framer.deinit();
    try framer.append("line\n");

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, framer.takeLine(failing.allocator()));
    const retried = (try framer.takeLine(allocator)).?;
    defer allocator.free(retried);
    try std.testing.expectEqualStrings("line", retried);

    var eof_framer = LineFramer.init(allocator, 4);
    defer eof_framer.deinit();
    try eof_framer.append("abcde");
    eof_framer.outcomes.deinit(allocator);
    eof_framer.outcomes = .empty;
    var eof_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    eof_framer.allocator = eof_failing.allocator();
    try std.testing.expectError(error.OutOfMemory, eof_framer.takeEof(allocator));
    eof_framer.allocator = allocator;
    try std.testing.expectError(error.LineTooLarge, eof_framer.takeEof(allocator));
}

test "StdioReceiver surfaces a recoverable logical line limit" {
    const allocator = std.testing.allocator;
    const pipe = try compat.stdio.pipe();
    defer compat.stdio.close(pipe[0]);

    var receiver_impl = StdioReceiver.initWithFileAndLimit(pipe[0], allocator, 4);
    defer receiver_impl.deinit();
    var receiver = receiver_impl.receiver();

    try compat.stdio.writeAll(pipe[1], "ok\nabcde\nbadbad\nnext\n");
    compat.stdio.close(pipe[1]);
    const before = (try receiver.read(allocator)).?;
    defer allocator.free(before);
    try std.testing.expectError(error.LineTooLarge, receiver.read(allocator));
    try std.testing.expectError(error.LineTooLarge, receiver.read(allocator));
    const after = (try receiver.read(allocator)).?;
    defer allocator.free(after);
    try std.testing.expectEqualStrings("ok", before);
    try std.testing.expectEqualStrings("next", after);
}

test "AsyncStdioReceiver compatibility read preserves coalesced lines" {
    const allocator = std.testing.allocator;
    const pipe = try compat.stdio.pipe();
    defer compat.stdio.close(pipe[0]);

    var receiver_impl = AsyncStdioReceiver.initWithFileAndLimit(pipe[0], 4);
    defer receiver_impl.deinit();
    var receiver = receiver_impl.receiver();
    try compat.stdio.writeAll(pipe[1], "a\nabcdeFG\nbb\ntail");
    compat.stdio.close(pipe[1]);

    const first = (try receiver.read(allocator)).?;
    defer allocator.free(first);
    try std.testing.expectError(error.LineTooLarge, receiver.read(allocator));
    const second = (try receiver.read(allocator)).?;
    defer allocator.free(second);
    const eof_line = (try receiver.read(allocator)).?;
    defer allocator.free(eof_line);
    try std.testing.expectEqualStrings("a", first);
    try std.testing.expectEqualStrings("bb", second);
    try std.testing.expectEqualStrings("tail", eof_line);
    try std.testing.expect((try receiver.read(allocator)) == null);
}

test "AsyncStdioReceiver compatibility state outlives per-read allocators" {
    const pipe = try compat.stdio.pipe();
    defer compat.stdio.close(pipe[0]);

    var receiver_impl = AsyncStdioReceiver.initWithFile(pipe[0]);
    var receiver = receiver_impl.receiver();
    defer receiver.close();
    try compat.stdio.writeAll(pipe[1], "one\ntwo\n");
    compat.stdio.close(pipe[1]);

    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const first = (try receiver.read(first_arena.allocator())).?;
    try std.testing.expectEqualStrings("one", first);
    first_arena.deinit();

    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    const second = (try receiver.read(second_arena.allocator())).?;
    try std.testing.expectEqualStrings("two", second);
}

test "StdioSender and StdioReceiver round-trip via pipe" {
    const allocator = std.testing.allocator;

    // Create a pipe for testing
    const pipe = try compat.stdio.pipe();
    const read_file = pipe[0];
    const write_file = pipe[1];
    defer compat.stdio.close(read_file);

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
    compat.stdio.close(write_file);

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
    const pipe = try compat.stdio.pipe();
    const read_file = pipe[0];
    const write_file = pipe[1];
    defer compat.stdio.close(read_file);

    // Set up async receiver with handle
    var async_receiver = AsyncStdioReceiver.initWithFile(read_file);
    var handle = try async_receiver.receiveStreamWithHandle(allocator);

    // Write test data from another thread (simulate producer)
    const WriterContext = struct {
        file: compat.stdio.File,
        fn writeData(ctx: *@This()) void {
            compat.time.sleepNs(std.time.ns_per_ms * 10); // Small delay
            compat.stdio.writeAll(ctx.file, "line1\nline2\n") catch {};
            compat.stdio.close(ctx.file);
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
    const pipe = try compat.stdio.pipe();
    const read_file = pipe[0];
    const write_file = pipe[1];

    var async_receiver = AsyncStdioReceiver.initWithFile(read_file);
    var handle = try async_receiver.receiveStreamWithHandle(allocator);

    // Verify not cancelled initially
    try std.testing.expect(!handle.isCancelled());

    // Request cancellation
    handle.cancel();
    try std.testing.expect(handle.isCancelled());

    // Close the write end to unblock the read (in case cancellation isn't instant)
    compat.stdio.close(write_file);

    // Clean up - should exit quickly due to cancellation
    const exited = handle.deinit(5000);
    // Thread should have exited (either by cancellation or EOF)
    try std.testing.expect(exited);
}

test "AsyncStdioReceiver legacy interface still works" {
    const allocator = std.testing.allocator;

    // Create a pipe for testing
    const pipe = try compat.stdio.pipe();
    const read_file = pipe[0];
    const write_file = pipe[1];
    defer compat.stdio.close(read_file);

    // Set up async receiver using the legacy interface
    var async_receiver = AsyncStdioReceiver.initWithFile(read_file);
    var receiver = async_receiver.receiver();

    // Get the stream (legacy interface - detached thread)
    const stream = try receiver.receiveStream(allocator);

    // Write test data and close
    try compat.stdio.writeAll(write_file, "test_data\n");
    compat.stdio.close(write_file);

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
