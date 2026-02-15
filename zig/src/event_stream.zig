const std = @import("std");
const types = @import("types");

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
        allocator: std.mem.Allocator,

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
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            // Drain any remaining events in the ring buffer and free their allocations
            // This is critical when tests abort mid-stream or complete without polling all events
            while (self.poll()) |event| {
                // Free allocated strings in the event based on the event type
                // We need to check if T is MessageEvent to avoid trying to free non-pointer types
                const is_message_event = comptime blk: {
                    if (@hasDecl(types, "MessageEvent")) {
                        break :blk T == types.MessageEvent;
                    }
                    break :blk false;
                };

                if (is_message_event) {
                    switch (event) {
                        .start => |s| self.allocator.free(s.model),
                        .text_delta => |d| self.allocator.free(d.delta),
                        .thinking_delta => |d| self.allocator.free(d.delta),
                        .toolcall_start => |tc| {
                            self.allocator.free(tc.id);
                            self.allocator.free(tc.name);
                        },
                        .toolcall_delta => |d| self.allocator.free(d.delta),
                        .toolcall_end => |e| self.allocator.free(e.input_json),
                        .@"error" => |e| self.allocator.free(e.message),
                        else => {},
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
        }

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

pub const AssistantMessageStream = EventStream(types.MessageEvent, types.AssistantMessage);

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

    // The model string MUST be heap-allocated when creating start events
    // because deinit() will free it when draining unpollled events
    const model_str = try std.testing.allocator.dupe(u8, "test-model");
    const start_event = types.MessageEvent{ .start = types.StartEvent{ .model = model_str } };
    try stream.push(start_event);

    const event = stream.poll();
    try std.testing.expect(event != null);
    try std.testing.expect(std.meta.activeTag(event.?) == .start);

    // Free the polled event's model string
    if (event) |evt| {
        switch (evt) {
            .start => |s| std.testing.allocator.free(s.model),
            else => {},
        }
    }

    const result_model_str = try std.testing.allocator.dupe(u8, "test-model");
    const result = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .usage = types.Usage{},
        .stop_reason = .stop,
        .model = result_model_str,
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
    // The model string MUST be heap-allocated because deinit will free it.
    var stream = AssistantMessageStream.init(std.testing.allocator);
    defer stream.deinit();

    // Heap-allocate the model string - deinit() will free this
    const model_str = try std.testing.allocator.dupe(u8, "test-model");
    const start_event = types.MessageEvent{ .start = types.StartEvent{ .model = model_str } };
    try stream.push(start_event);

    // Do NOT poll the event - deinit() should drain and free it
    // If model_str was a string literal, deinit would crash with "Invalid free"

    const result_model_str = try std.testing.allocator.dupe(u8, "test-model");
    const result = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .usage = types.Usage{},
        .stop_reason = .stop,
        .model = result_model_str,
        .timestamp = 0,
    };
    stream.complete(result);

    // deinit() will:
    // 1. Poll and free the start event's model string
    // 2. Call AssistantMessage.deinit() which frees result.model
}
