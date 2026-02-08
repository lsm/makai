const std = @import("std");
const types = @import("types");

pub fn EventStream(comptime T: type, comptime R: type) type {
    return struct {
        const Self = @This();
        const RING_BUFFER_SIZE = 256;
        const RING_BUFFER_MASK = RING_BUFFER_SIZE - 1;

        ring_buffer: [RING_BUFFER_SIZE]T,
        head: std.atomic.Value(usize),
        tail: std.atomic.Value(usize),
        result: ?R = null,
        completed: std.atomic.Value(bool),
        err_msg: ?[]const u8 = null,
        mutex: std.Thread.Mutex = .{},
        futex: std.atomic.Value(u32),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .ring_buffer = undefined,
                .head = std.atomic.Value(usize).init(0),
                .tail = std.atomic.Value(usize).init(0),
                .completed = std.atomic.Value(bool).init(false),
                .futex = std.atomic.Value(u32).init(0),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn push(self: *Self, event: T) !void {
            while (true) {
                const current_head = self.head.load(.acquire);
                const current_tail = self.tail.load(.acquire);

                const next_head = (current_head + 1) & RING_BUFFER_MASK;

                if (next_head == current_tail) {
                    return error.QueueFull;
                }

                if (self.head.cmpxchgWeak(current_head, next_head, .release, .acquire)) |_| {
                    continue;
                }

                self.ring_buffer[current_head] = event;

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

            self.err_msg = msg;
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

            const event = self.ring_buffer[current_tail];
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
                buffer[count] = self.ring_buffer[current_tail];
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
                    const event = self.ring_buffer[current_tail];
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

    const start_event = types.MessageEvent{ .start = types.StartEvent{ .model = "test-model" } };
    try stream.push(start_event);

    const event = stream.poll();
    try std.testing.expect(event != null);
    try std.testing.expect(std.meta.activeTag(event.?) == .start);

    const result = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .usage = types.Usage{},
        .stop_reason = .stop,
        .model = "test-model",
        .timestamp = 0,
    };
    stream.complete(result);

    try std.testing.expect(stream.isDone());
    const res = stream.getResult();
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings("test-model", res.?.model);
}
