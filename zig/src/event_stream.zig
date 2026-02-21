const std = @import("std");
const ai_types = @import("ai_types");

pub fn EventStream(comptime T: type, comptime R: type) type {
    return struct {
        const Self = @This();
        const RING_BUFFER_SIZE = 256;
        const RING_BUFFER_MASK = RING_BUFFER_SIZE - 1;

        ring_buffer: [RING_BUFFER_SIZE]T,
        /// Published flags ensure data is visible before consumers read.
        /// Each slot has a flag that is set to true after data is written.
        published: [RING_BUFFER_SIZE]std.atomic.Value(bool),
        head: std.atomic.Value(usize),
        tail: std.atomic.Value(usize),
        result: ?R = null,
        completed: std.atomic.Value(bool),
        err_msg: ?[]const u8 = null,
        mutex: std.Thread.Mutex = .{},
        futex: std.atomic.Value(u32),
        thread_done: std.atomic.Value(bool),
        allocator: std.mem.Allocator,
        /// When true, events in this stream were deep-copied via cloneAssistantMessageEvent()
        /// and should be freed in deinit(). When false (default), events contain borrowed
        /// string slices and must NOT be freed by the stream.
        owns_events: bool = false,

        pub fn init(allocator: std.mem.Allocator) Self {
            var published: [RING_BUFFER_SIZE]std.atomic.Value(bool) = undefined;
            for (&published) |*p| {
                p.* = std.atomic.Value(bool).init(false);
            }
            return Self{
                .ring_buffer = undefined,
                .published = published,
                .head = std.atomic.Value(usize).init(0),
                .tail = std.atomic.Value(usize).init(0),
                .completed = std.atomic.Value(bool).init(false),
                .futex = std.atomic.Value(u32).init(0),
                .thread_done = std.atomic.Value(bool).init(false),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            // Wait for producer thread to finish before cleanup
            _ = self.waitForThread(5000);

            // Drain any remaining events in the ring buffer.
            // IMPORTANT: By default (owns_events=false), events contain BORROWED string slices
            // that point into provider-managed temporary buffers (SSE parser buffers, JSON buffers).
            // The stream does NOT own these strings, so freeing them would cause double-free panics.
            //
            // Memory ownership model:
            // - Providers: Push events with borrowed strings; provider manages buffer lifetimes (owns_events=false)
            // - ProtocolClient: Deep-copies via cloneAssistantMessageEvent() before push (owns_events=true)
            //
            // DO NOT change the default behavior - see CI failures from 2026-02-19.
            const is_assistant_message_event = comptime blk: {
                if (@hasDecl(ai_types, "AssistantMessageEvent")) {
                    break :blk T == ai_types.AssistantMessageEvent;
                }
                break :blk false;
            };

            while (self.poll()) |event| {
                if (comptime is_assistant_message_event) {
                    if (self.owns_events) {
                        var ev = event;
                        ai_types.deinitAssistantMessageEvent(self.allocator, &ev);
                    }
                }
            }

            if (self.result) |*result| {
                // Only call deinit if R has a deinit method
                // Use comptime to check if R is a type that can have decls
                const has_deinit = comptime blk: {
                    const info = @typeInfo(R);
                    switch (info) {
                        .@"struct", .@"union", .@"enum", .@"opaque" => {
                            break :blk @hasDecl(R, "deinit");
                        },
                        else => break :blk false,
                    }
                };
                if (has_deinit) {
                    result.deinit(self.allocator);
                }
            }

            // Free error message (completeWithError always dupes it)
            if (self.err_msg) |msg| {
                self.allocator.free(msg);
            }

            // Poison freed memory to catch use-after-free in debug builds
            self.* = undefined;
        }

        /// Push an event to the stream.
        ///
        /// IMPORTANT: The event's string fields (delta, content, id, name, etc.) are
        /// treated as BORROWED references. The stream does NOT take ownership and will
        /// NOT free them in deinit(). The caller must ensure the backing memory outlives
        /// the event's consumption from the stream (typically by managing buffer lifetimes
        /// in the producer thread).
        ///
        /// If you need the stream to own event memory, deep-copy via cloneAssistantMessageEvent()
        /// before calling push(), and manage cleanup separately.
        pub fn push(self: *Self, event: T) !void {
            while (true) {
                const current_head = self.head.load(.acquire);
                const current_tail = self.tail.load(.acquire);

                const next_head = (current_head + 1) & RING_BUFFER_MASK;

                if (next_head == current_tail) {
                    return error.QueueFull;
                }

                // Try to claim this slot
                if (self.head.cmpxchgWeak(current_head, next_head, .acquire, .acquire)) |_| {
                    continue;
                }

                // We claimed slot at current_head - now write the data
                self.ring_buffer[current_head] = event;

                // Mark the slot as published with release semantics
                // This ensures the write above is visible before the flag
                self.published[current_head].store(true, .release);

                _ = self.futex.fetchAdd(1, .release);
                std.Thread.Futex.wake(&self.futex, 1);

                return;
            }
        }

        pub fn complete(self: *Self, result: R) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.result = result;
            self.completed.store(true, .release);

            _ = self.futex.fetchAdd(1, .release);
            std.Thread.Futex.wake(&self.futex, std.math.maxInt(u32));
        }

        pub fn completeWithError(self: *Self, msg: []const u8) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Always dupe the message so the stream owns its memory
            // This allows callers to free their copy immediately after this call
            // On OOM, store null (losing the error message is better than crashing)
            self.err_msg = self.allocator.dupe(u8, msg) catch null;
            self.completed.store(true, .release);

            _ = self.futex.fetchAdd(1, .release);
            std.Thread.Futex.wake(&self.futex, std.math.maxInt(u32));
        }

        pub fn markThreadDone(self: *Self) void {
            self.thread_done.store(true, .release);
            _ = self.futex.fetchAdd(1, .release);
            std.Thread.Futex.wake(&self.futex, std.math.maxInt(u32));
        }

        pub fn waitForThread(self: *Self, timeout_ms: u64) bool {
            const start_time = std.time.nanoTimestamp();
            const timeout_ns = @as(i128, timeout_ms) * 1_000_000;

            var futex_value = self.futex.load(.acquire);

            while (!self.thread_done.load(.acquire)) {
                const elapsed = std.time.nanoTimestamp() - start_time;
                if (elapsed >= timeout_ns) {
                    return false;
                }

                const remaining_ns = timeout_ns - elapsed;
                const remaining_ms = @as(u64, @intCast(@divFloor(remaining_ns, 1_000_000)));
                const remaining_max_ms = @min(remaining_ms, std.math.maxInt(u32));

                std.Thread.Futex.timedWait(&self.futex, futex_value, remaining_max_ms) catch {};

                futex_value = self.futex.load(.acquire);
            }

            return true;
        }

        pub fn poll(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const current_tail = self.tail.load(.acquire);
            const current_head = self.head.load(.acquire);

            if (current_tail == current_head) {
                return null;
            }

            // Spin-wait for the slot to be published (data visible)
            // This is safe because push() marks published before waking consumers
            while (!self.published[current_tail].load(.acquire)) {
                std.Thread.yield() catch {};
            }

            const event = self.ring_buffer[current_tail];

            // Clear published flag for slot reuse and advance tail
            self.published[current_tail].store(false, .release);
            self.tail.store((current_tail + 1) & RING_BUFFER_MASK, .release);

            return event;
        }

        pub fn pollBatch(self: *Self, buffer: []T) usize {
            self.mutex.lock();
            defer self.mutex.unlock();

            var count: usize = 0;
            var current_tail = self.tail.load(.acquire);
            const current_head = self.head.load(.acquire);

            while (count < buffer.len and current_tail != current_head) {
                // Spin-wait for the slot to be published (data visible)
                while (!self.published[current_tail].load(.acquire)) {
                    std.Thread.yield() catch {};
                }

                buffer[count] = self.ring_buffer[current_tail];

                // Clear published flag for slot reuse
                self.published[current_tail].store(false, .release);
                current_tail = (current_tail + 1) & RING_BUFFER_MASK;
                count += 1;
            }

            if (count > 0) {
                self.tail.store(current_tail, .release);
            }

            return count;
        }

        pub fn wait(self: *Self) ?T {
            var futex_value = self.futex.load(.acquire);

            while (true) {
                self.mutex.lock();

                const current_tail = self.tail.load(.acquire);
                const current_head = self.head.load(.acquire);

                if (current_tail != current_head) {
                    // Spin-wait for the slot to be published (data visible)
                    while (!self.published[current_tail].load(.acquire)) {
                        std.Thread.yield() catch {};
                    }

                    const event = self.ring_buffer[current_tail];

                    // Clear published flag for slot reuse and advance tail
                    self.published[current_tail].store(false, .release);
                    self.tail.store((current_tail + 1) & RING_BUFFER_MASK, .release);
                    self.mutex.unlock();
                    return event;
                }

                if (self.completed.load(.acquire)) {
                    self.mutex.unlock();
                    return null;
                }

                self.mutex.unlock();

                std.Thread.Futex.wait(&self.futex, futex_value);
                futex_value = self.futex.load(.acquire);
            }
        }

        pub fn isDone(self: *Self) bool {
            return self.completed.load(.acquire);
        }

        pub fn getResult(self: *Self) ?R {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.result;
        }

        pub fn getError(self: *Self) ?[]const u8 {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.err_msg;
        }
    };
}

pub const AssistantMessageStream = EventStream(ai_types.AssistantMessageEvent, ai_types.AssistantMessage);

/// Alias for AssistantMessageStream (same type, different name for clarity)
pub const AssistantMessageEventStream = AssistantMessageStream;

// Tests
test "EventStream push and poll" {
    const TestStream = EventStream(u32, bool);
    var stream = TestStream.init(std.testing.allocator);
    defer stream.deinit();

    try stream.push(1);
    try stream.push(2);
    try stream.push(3);

    try std.testing.expectEqual(@as(?u32, 1), stream.poll());
    try std.testing.expectEqual(@as(?u32, 2), stream.poll());
    try std.testing.expectEqual(@as(?u32, 3), stream.poll());
    try std.testing.expectEqual(@as(?u32, null), stream.poll());
}

test "EventStream complete" {
    const TestStream = EventStream(u32, bool);
    var stream = TestStream.init(std.testing.allocator);
    defer stream.deinit();

    try std.testing.expect(!stream.isDone());

    stream.complete(true);

    try std.testing.expect(stream.isDone());
    try std.testing.expectEqual(@as(?bool, true), stream.getResult());
}

test "EventStream error" {
    const TestStream = EventStream(u32, bool);
    var stream = TestStream.init(std.testing.allocator);
    defer stream.deinit();

    stream.completeWithError("test error");

    try std.testing.expect(stream.isDone());
    try std.testing.expectEqualStrings("test error", stream.getError().?);
}

test "EventStream pollBatch" {
    const TestStream = EventStream(u32, bool);
    var stream = TestStream.init(std.testing.allocator);
    defer stream.deinit();

    try stream.push(1);
    try stream.push(2);
    try stream.push(3);
    try stream.push(4);
    try stream.push(5);

    var buffer: [3]u32 = undefined;
    const count1 = stream.pollBatch(&buffer);
    try std.testing.expectEqual(@as(usize, 3), count1);
    try std.testing.expectEqual(@as(u32, 1), buffer[0]);
    try std.testing.expectEqual(@as(u32, 2), buffer[1]);
    try std.testing.expectEqual(@as(u32, 3), buffer[2]);

    const count2 = stream.pollBatch(&buffer);
    try std.testing.expectEqual(@as(usize, 2), count2);
    try std.testing.expectEqual(@as(u32, 4), buffer[0]);
    try std.testing.expectEqual(@as(u32, 5), buffer[1]);

    const count3 = stream.pollBatch(&buffer);
    try std.testing.expectEqual(@as(usize, 0), count3);
}

test "AssistantMessageStream basic usage" {
    var stream = AssistantMessageStream.init(std.testing.allocator);
    defer stream.deinit();

    // Create a partial message for the start event
    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const start_event = ai_types.AssistantMessageEvent{ .start = .{ .partial = partial } };
    try stream.push(start_event);

    const event = stream.poll();
    try std.testing.expect(event != null);
    try std.testing.expect(std.meta.activeTag(event.?) == .start);

    // Complete with a result
    const result = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    stream.complete(result);

    try std.testing.expect(stream.isDone());
    const res = stream.getResult();
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings("test-model", res.?.model);
}

test "AssistantMessageStream deinit drains unpollled events" {
    // This test verifies that deinit() properly frees memory in events
    // that were pushed but not polled before the stream is destroyed.
    var stream = AssistantMessageStream.init(std.testing.allocator);
    defer stream.deinit();

    // Create a start event - partial message has no heap allocations
    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const start_event = ai_types.AssistantMessageEvent{ .start = .{ .partial = partial } };
    try stream.push(start_event);

    // Do NOT poll the event - deinit() should drain and free it

    const result = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    stream.complete(result);

    // deinit() will drain events and clean up
}
