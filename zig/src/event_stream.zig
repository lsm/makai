const std = @import("std");
const ai_types = @import("ai_types");

pub fn EventStream(comptime T: type, comptime R: type) type {
    return struct {
        const Self = @This();
        const RING_BUFFER_SIZE = 1024;
        const RING_BUFFER_MASK = RING_BUFFER_SIZE - 1;
        pub const usable_capacity = RING_BUFFER_SIZE - 1;

        ring_buffer: [RING_BUFFER_SIZE]T,
        /// Published flags ensure data is visible before consumers read.
        /// Each slot has a flag that is set to true after data is written.
        published: [RING_BUFFER_SIZE]std.atomic.Value(bool),
        head: std.atomic.Value(usize),
        tail: std.atomic.Value(usize),
        result: ?R = null,
        completed: std.atomic.Value(bool),
        err_msg: ?[]const u8 = null,
        mutex: std.Io.Mutex = .init,
        futex: std.atomic.Value(u32),
        thread_done: std.atomic.Value(bool),
        allocator: std.mem.Allocator,
        /// When true, deinit waits for markThreadDone() from a producer thread.
        wait_for_thread_on_deinit: bool = false,
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

        fn defaultIo() std.Io {
            return if (@import("builtin").is_test)
                std.testing.io
            else
                std.Io.Threaded.global_single_threaded.io();
        }

        /// Zig 0.16 routes futex operations through the active `std.Io` context.
        /// The EventStream still uses a monotonically increasing futex word so
        /// wake/wait semantics match the previous `std.Thread.Futex` design:
        /// waiters sleep only while the observed word remains unchanged, and
        /// every push/completion/thread-done transition increments before wake.
        fn wake(self: *Self, max_waiters: u32) void {
            defaultIo().futexWake(u32, &self.futex.raw, max_waiters);
        }

        fn waitUncancelable(self: *Self, expected: u32) void {
            defaultIo().futexWaitUncancelable(u32, &self.futex.raw, expected);
        }

        /// Timed waits now use `std.Io.Timeout` on the boot clock. Timeout and
        /// spurious-wake errors are intentionally collapsed here because callers
        /// re-check `thread_done` and their monotonic deadline after every wait,
        /// preserving the public bool-returning timeout behavior.
        fn waitTimeoutMs(self: *Self, expected: u32, timeout_ms: u64) void {
            const capped_ms = @min(timeout_ms, @as(u64, std.math.maxInt(i64)));
            defaultIo().futexWaitTimeout(u32, &self.futex.raw, expected, .{ .duration = .{
                .raw = .fromMilliseconds(@intCast(capped_ms)),
                .clock = .boot,
            } }) catch {};
        }

        fn monotonicNanos() i128 {
            return std.Io.Timestamp.now(defaultIo(), .boot).toNanoseconds();
        }

        pub fn deinit(self: *Self) void {
            if (self.wait_for_thread_on_deinit) {
                // Wake any blocking producer before waiting for it. Without this,
                // a full queue can leave the producer stuck in pushBlocking() until
                // this wait times out, after which deinit poisons memory that the
                // producer may still touch.
                self.completed.store(true, .release);
                _ = self.futex.fetchAdd(1, .release);
                self.wake(std.math.maxInt(u32));
                _ = self.waitForThread(120_000);
            }

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

            const event_has_deinit = comptime blk: {
                const info = @typeInfo(T);
                switch (info) {
                    .@"struct", .@"union", .@"enum", .@"opaque" => break :blk @hasDecl(T, "deinit"),
                    else => break :blk false,
                }
            };

            while (self.poll()) |event| {
                if (comptime is_assistant_message_event) {
                    if (self.owns_events) {
                        var ev = event;
                        ai_types.deinitAssistantMessageEvent(self.allocator, &ev);
                    }
                } else if (comptime event_has_deinit) {
                    var ev = event;
                    ev.deinit(self.allocator);
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
                if (self.completed.load(.acquire)) return error.StreamCompleted;
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
                self.wake(1);

                return;
            }
        }

        /// Push an event, waiting for the consumer to make room when the ring is full.
        ///
        /// Use this for ordered producer streams where dropping an event would corrupt
        /// the logical stream. UI projection layers that can tolerate loss should still
        /// prefer an explicit drop-oldest policy at that boundary.
        pub fn pushBlocking(self: *Self, event: T) bool {
            while (true) {
                self.push(event) catch |err| switch (err) {
                    error.QueueFull => {
                        if (self.completed.load(.acquire)) return false;
                        waitTimeoutMs(self, self.futex.load(.acquire), 1);
                        continue;
                    },
                    error.StreamCompleted => return false,
                };
                return true;
            }
        }

        pub fn complete(self: *Self, result: R) void {
            self.mutex.lockUncancelable(defaultIo());
            defer self.mutex.unlock(defaultIo());

            self.result = result;
            self.completed.store(true, .release);

            _ = self.futex.fetchAdd(1, .release);
            self.wake(std.math.maxInt(u32));
        }

        pub fn completeWithError(self: *Self, msg: []const u8) void {
            self.mutex.lockUncancelable(defaultIo());
            defer self.mutex.unlock(defaultIo());

            // Free previous error message if this stream was already completed
            // with an error (e.g., provider thread completed before abort).
            if (self.err_msg) |old| {
                self.allocator.free(old);
                self.err_msg = null;
            }

            // Always dupe the message so the stream owns its memory
            // This allows callers to free their copy immediately after this call
            // On OOM, store null (losing the error message is better than crashing)
            self.err_msg = self.allocator.dupe(u8, msg) catch null;
            self.completed.store(true, .release);

            _ = self.futex.fetchAdd(1, .release);
            self.wake(std.math.maxInt(u32));
        }

        pub fn markThreadDone(self: *Self) void {
            self.thread_done.store(true, .release);
            _ = self.futex.fetchAdd(1, .release);
            self.wake(std.math.maxInt(u32));
        }

        pub fn waitForThread(self: *Self, timeout_ms: u64) bool {
            const start_time = monotonicNanos();
            const timeout_ns = @as(i128, timeout_ms) * 1_000_000;

            var futex_value = self.futex.load(.acquire);

            while (!self.thread_done.load(.acquire)) {
                const elapsed = monotonicNanos() - start_time;
                if (elapsed >= timeout_ns) {
                    return false;
                }

                const remaining_ns = timeout_ns - elapsed;
                const remaining_ms = @as(u64, @intCast(@divFloor(remaining_ns, 1_000_000)));
                const remaining_max_ms = @min(remaining_ms, std.math.maxInt(u32));

                self.waitTimeoutMs(futex_value, remaining_max_ms);

                futex_value = self.futex.load(.acquire);
            }

            return true;
        }

        pub fn poll(self: *Self) ?T {
            self.mutex.lockUncancelable(defaultIo());
            defer self.mutex.unlock(defaultIo());

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
            self.mutex.lockUncancelable(defaultIo());
            defer self.mutex.unlock(defaultIo());

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
                self.mutex.lockUncancelable(defaultIo());

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
                    self.mutex.unlock(defaultIo());
                    return event;
                }

                if (self.completed.load(.acquire)) {
                    self.mutex.unlock(defaultIo());
                    return null;
                }

                self.mutex.unlock(defaultIo());

                self.waitUncancelable(futex_value);
                futex_value = self.futex.load(.acquire);
            }
        }

        pub fn isDone(self: *Self) bool {
            return self.completed.load(.acquire);
        }

        pub fn hasPending(self: *Self) bool {
            self.mutex.lockUncancelable(defaultIo());
            defer self.mutex.unlock(defaultIo());
            return self.head.load(.acquire) != self.tail.load(.acquire);
        }

        pub fn getResult(self: *Self) ?R {
            self.mutex.lockUncancelable(defaultIo());
            defer self.mutex.unlock(defaultIo());

            return self.result;
        }

        pub fn getError(self: *Self) ?[]const u8 {
            self.mutex.lockUncancelable(defaultIo());
            defer self.mutex.unlock(defaultIo());

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

test "EventStream push returns QueueFull when ring buffer exhausted" {
    const TestStream = EventStream(u32, bool);
    var stream = TestStream.init(std.testing.allocator);
    defer stream.deinit();

    // Capacity is RING_BUFFER_SIZE - 1 because head==tail means empty.
    for (0..TestStream.usable_capacity) |i| {
        try stream.push(@intCast(i));
    }
    try std.testing.expectError(error.QueueFull, stream.push(TestStream.usable_capacity));
}

test "EventStream pushBlocking reports completed full stream" {
    const TestStream = EventStream(u32, bool);
    var stream = TestStream.init(std.testing.allocator);
    defer stream.deinit();

    for (0..TestStream.usable_capacity) |i| {
        try stream.push(@intCast(i));
    }
    stream.complete(true);

    try std.testing.expect(!stream.pushBlocking(TestStream.usable_capacity));
}

const BlockingPushDeinitCtx = struct {
    stream: *EventStream(u32, bool),
    started: *std.atomic.Value(bool),
    returned: *std.atomic.Value(bool),
    ok: *std.atomic.Value(bool),

    fn run(self: *@This()) void {
        self.started.store(true, .release);
        const pushed = self.stream.pushBlocking(TestStream.usable_capacity);
        self.ok.store(pushed, .release);
        self.returned.store(true, .release);
        self.stream.markThreadDone();
    }

    const TestStream = EventStream(u32, bool);
};

test "EventStream deinit unblocks producer waiting in pushBlocking" {
    const TestStream = EventStream(u32, bool);
    const stream = try std.testing.allocator.create(TestStream);
    stream.* = TestStream.init(std.testing.allocator);
    stream.wait_for_thread_on_deinit = true;

    for (0..TestStream.usable_capacity) |i| {
        try stream.push(@intCast(i));
    }

    var started = std.atomic.Value(bool).init(false);
    var returned = std.atomic.Value(bool).init(false);
    var ok = std.atomic.Value(bool).init(true);
    var ctx = BlockingPushDeinitCtx{
        .stream = stream,
        .started = &started,
        .returned = &returned,
        .ok = &ok,
    };

    const thread = try std.Thread.spawn(.{}, BlockingPushDeinitCtx.run, .{&ctx});
    thread.detach();
    while (!started.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    stream.deinit();
    std.testing.allocator.destroy(stream);

    try std.testing.expect(returned.load(.acquire));
    try std.testing.expect(!ok.load(.acquire));
}

test "EventStream ring buffer wrap-around preserves order" {
    const TestStream = EventStream(u32, bool);
    var stream = TestStream.init(std.testing.allocator);
    defer stream.deinit();

    // Force head/tail wrap-around across the ring.
    for (0..TestStream.usable_capacity + 44) |i| {
        try stream.push(@intCast(i));
        const v = stream.poll().?;
        try std.testing.expectEqual(@as(u32, @intCast(i)), v);
    }

    try std.testing.expect(stream.poll() == null);
}

const WaitPushCtx = struct {
    stream: *EventStream(u32, bool),
};

fn pushEventAfterDelay(ctx: *WaitPushCtx) void {
    std.testing.io.sleep(.fromNanoseconds(10 * std.time.ns_per_ms), .boot) catch {};
    ctx.stream.push(42) catch {};
}

test "EventStream wait wakes and returns pushed event" {
    const TestStream = EventStream(u32, bool);
    var stream = TestStream.init(std.testing.allocator);
    defer stream.deinit();

    var ctx = WaitPushCtx{ .stream = &stream };
    const th = try std.Thread.spawn(.{}, pushEventAfterDelay, .{&ctx});
    defer th.join();

    const got = stream.wait();
    try std.testing.expectEqual(@as(?u32, 42), got);
}

const CompletionAfterErrorCtx = struct {
    stream: *EventStream(u32, u32),
    ready: *std.atomic.Value(bool),

    fn run(self: *@This()) void {
        while (!self.ready.load(.acquire)) {
            std.Thread.yield() catch {};
        }
        self.stream.complete(99);
    }
};

test "completion_after_error_is_stable" {
    const TestStream = EventStream(u32, u32);
    var stream = TestStream.init(std.testing.allocator);
    defer stream.deinit();

    stream.completeWithError("first failure");

    var ready = std.atomic.Value(bool).init(false);
    var ctx = CompletionAfterErrorCtx{ .stream = &stream, .ready = &ready };
    const thread = try std.Thread.spawn(.{}, CompletionAfterErrorCtx.run, .{&ctx});
    ready.store(true, .release);
    thread.join();

    try std.testing.expect(stream.isDone());
    try std.testing.expectEqualStrings("first failure", stream.getError().?);
    try std.testing.expectEqual(@as(?u32, 99), stream.getResult());
    try std.testing.expect(stream.wait() == null);
}

test "double_completion_is_idempotent_or_errors_predictably" {
    const TestStream = EventStream(u32, u32);
    var stream = TestStream.init(std.testing.allocator);
    defer stream.deinit();

    stream.complete(1);
    stream.complete(2);

    try std.testing.expect(stream.isDone());
    try std.testing.expectEqual(@as(?u32, 2), stream.getResult());
    try std.testing.expect(stream.getError() == null);
    try std.testing.expect(stream.wait() == null);
}

const WaitTimeoutCtx = struct {
    stream: *EventStream(u32, u32),
    result: std.atomic.Value(u32) = std.atomic.Value(u32).init(999),

    fn run(self: *@This()) void {
        const got = self.stream.wait();
        self.result.store(if (got) |v| v else 0, .release);
    }
};

test "wait_returns_null_after_complete_without_event" {
    const TestStream = EventStream(u32, u32);
    var stream = TestStream.init(std.testing.allocator);
    defer stream.deinit();

    var ctx = WaitTimeoutCtx{ .stream = &stream };
    const thread = try std.Thread.spawn(.{}, WaitTimeoutCtx.run, .{&ctx});

    try std.testing.expect(!stream.waitForThread(1));
    stream.complete(7);
    thread.join();

    try std.testing.expectEqual(@as(u32, 0), ctx.result.load(.acquire));
}

const StressEvent = struct {
    producer: u16,
    seq: u16,
};

const MultiProducerStressCtx = struct {
    stream: *EventStream(StressEvent, usize),
    producer: u16,
    start: *std.atomic.Value(bool),

    const per_producer = 50;

    fn run(self: *@This()) void {
        while (!self.start.load(.acquire)) {
            std.Thread.yield() catch {};
        }

        var seq: u16 = 0;
        while (seq < per_producer) : (seq += 1) {
            while (true) {
                self.stream.push(.{ .producer = self.producer, .seq = seq }) catch |err| switch (err) {
                    error.QueueFull => {
                        std.Thread.yield() catch {};
                        continue;
                    },
                    error.StreamCompleted => return,
                };
                break;
            }
        }
    }
};

test "multi_producer_stress_preserves_events" {
    const producer_count = 4;
    const per_producer = MultiProducerStressCtx.per_producer;
    const expected_total = producer_count * per_producer;

    const StressStream = EventStream(StressEvent, usize);
    var stream = StressStream.init(std.testing.allocator);
    defer stream.deinit();

    var start = std.atomic.Value(bool).init(false);
    var contexts: [producer_count]MultiProducerStressCtx = undefined;
    var threads: [producer_count]std.Thread = undefined;

    for (&contexts, 0..) |*ctx, i| {
        ctx.* = .{ .stream = &stream, .producer = @intCast(i), .start = &start };
        threads[i] = try std.Thread.spawn(.{}, MultiProducerStressCtx.run, .{ctx});
    }
    start.store(true, .release);

    var seen = [_][per_producer]bool{[_]bool{false} ** per_producer} ** producer_count;
    var received: usize = 0;
    while (received < expected_total) {
        if (stream.wait()) |event| {
            try std.testing.expect(event.producer < producer_count);
            try std.testing.expect(event.seq < per_producer);
            try std.testing.expect(!seen[event.producer][event.seq]);
            seen[event.producer][event.seq] = true;
            received += 1;
        }
    }

    for (&threads) |*thread| thread.join();

    for (seen) |producer_seen| {
        for (producer_seen) |was_seen| {
            try std.testing.expect(was_seen);
        }
    }
}

const MemoryOrderingCtx = struct {
    stream: *EventStream(u64, u64),
    side_channel: *std.atomic.Value(u64),
    start: *std.atomic.Value(bool),

    fn run(self: *@This()) void {
        while (!self.start.load(.acquire)) {
            std.Thread.yield() catch {};
        }
        self.side_channel.store(0xC0FFEE, .release);
        self.stream.complete(0xC0FFEE);
    }
};

test "completion_memory_ordering_visibility" {
    const TestStream = EventStream(u64, u64);
    var stream = TestStream.init(std.testing.allocator);
    defer stream.deinit();

    var side_channel = std.atomic.Value(u64).init(0);
    var start = std.atomic.Value(bool).init(false);
    var ctx = MemoryOrderingCtx{ .stream = &stream, .side_channel = &side_channel, .start = &start };
    const thread = try std.Thread.spawn(.{}, MemoryOrderingCtx.run, .{&ctx});
    defer thread.join();

    start.store(true, .release);
    while (!stream.isDone()) {
        std.Thread.yield() catch {};
    }

    try std.testing.expectEqual(@as(u64, 0xC0FFEE), side_channel.load(.acquire));
    try std.testing.expectEqual(@as(?u64, 0xC0FFEE), stream.getResult());
}
