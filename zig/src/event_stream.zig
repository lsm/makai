const std = @import("std");
const ai_types = @import("ai_types");

pub fn EventStream(comptime T: type, comptime R: type) type {
    return struct {
        const Self = @This();
        const RING_BUFFER_SIZE = 1024;
        const RING_BUFFER_MASK = RING_BUFFER_SIZE - 1;
        pub const usable_capacity = RING_BUFFER_SIZE - 1;

        ring_buffer: [RING_BUFFER_SIZE]T,
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
        wait_for_thread_on_deinit: bool = false,
        owns_events: bool = false,
        clone_event_fn: ?*const fn (std.mem.Allocator, T) error{OutOfMemory}!T = null,

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

        fn deinitGenericEvent(self: *Self, event: *T) void {
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
            if (comptime is_assistant_message_event) {
                if (self.owns_events) {
                    ai_types.deinitAssistantMessageEvent(self.allocator, event);
                }
            } else if (comptime event_has_deinit) {
                event.deinit(self.allocator);
            }
        }

        fn defaultIo() std.Io {
            return if (@import("builtin").is_test)
                std.testing.io
            else
                std.Io.Threaded.global_single_threaded.io();
        }

        fn wake(self: *Self, max_waiters: u32) void {
            defaultIo().futexWake(u32, &self.futex.raw, max_waiters);
        }

        fn waitUncancelable(self: *Self, expected: u32) void {
            defaultIo().futexWaitUncancelable(u32, &self.futex.raw, expected);
        }

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
                self.completed.store(true, .release);
                _ = self.futex.fetchAdd(1, .release);
                self.wake(std.math.maxInt(u32));
                _ = self.waitForThread(120_000);
            }

            while (self.poll()) |event| {
                var ev = event;
                self.deinitGenericEvent(&ev);
            }

            if (self.result) |*result| {
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

            if (self.err_msg) |msg| {
                self.allocator.free(msg);
            }

            self.* = undefined;
        }

        pub fn push(self: *Self, event: T) !void {
            var owned_event: ?T = null;
            defer if (owned_event) |*e| self.deinitGenericEvent(e);

            while (true) {
                if (self.completed.load(.acquire)) return error.StreamCompleted;
                const current_head = self.head.load(.acquire);
                const current_tail = self.tail.load(.acquire);

                const next_head = (current_head + 1) & RING_BUFFER_MASK;

                if (next_head == current_tail) {
                    return error.QueueFull;
                }

                if (self.owns_events) {
                    if (self.clone_event_fn) |clone_fn| {
                        if (owned_event == null) {
                            owned_event = try clone_fn(self.allocator, event);
                        }
                    }
                }

                if (self.head.cmpxchgWeak(current_head, next_head, .acquire, .acquire)) |_| {
                    continue;
                }

                var event_to_store = event;
                if (self.owns_events) {
                    if (self.clone_event_fn) |clone_fn| {
                        _ = clone_fn;
                        if (owned_event) |*owned| {
                            event_to_store = owned.*;
                            owned_event = null;
                        }
                    }
                }
                self.ring_buffer[current_head] = event_to_store;

                self.published[current_head].store(true, .release);

                _ = self.futex.fetchAdd(1, .release);
                self.wake(1);

                return;
            }
        }

        pub fn pushBlocking(self: *Self, event: T) bool {
            while (true) {
                self.push(event) catch |err| switch (err) {
                    error.QueueFull => {
                        if (self.completed.load(.acquire)) return false;
                        waitTimeoutMs(self, self.futex.load(.acquire), 1);
                        continue;
                    },
                    error.StreamCompleted, error.OutOfMemory => return false,
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

            if (self.err_msg) |old| {
                self.allocator.free(old);
                self.err_msg = null;
            }

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

        pub fn waitForCompletion(self: *Self, timeout_ms: u64) bool {
            const start_time = monotonicNanos();
            const timeout_ns = @as(i128, timeout_ms) * 1_000_000;

            var futex_value = self.futex.load(.acquire);

            while (!self.completed.load(.acquire)) {
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

            while (!self.published[current_tail].load(.acquire)) {
                std.Thread.yield() catch {};
            }

            const event = self.ring_buffer[current_tail];

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
                while (!self.published[current_tail].load(.acquire)) {
                    std.Thread.yield() catch {};
                }

                buffer[count] = self.ring_buffer[current_tail];

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
                    while (!self.published[current_tail].load(.acquire)) {
                        std.Thread.yield() catch {};
                    }

                    const event = self.ring_buffer[current_tail];

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

        pub fn isFull(self: *Self) bool {
            self.mutex.lockUncancelable(defaultIo());
            defer self.mutex.unlock(defaultIo());
            const current_head = self.head.load(.acquire);
            const current_tail = self.tail.load(.acquire);
            return ((current_head + 1) & RING_BUFFER_MASK) == current_tail;
        }

        pub fn freeSlots(self: *Self) usize {
            self.mutex.lockUncancelable(defaultIo());
            defer self.mutex.unlock(defaultIo());
            const current_head = self.head.load(.acquire);
            const current_tail = self.tail.load(.acquire);
            const used = (current_head -% current_tail) & RING_BUFFER_MASK;
            return (RING_BUFFER_SIZE - 1) - used;
        }

        pub fn getResult(self: *Self) ?R {
            self.mutex.lockUncancelable(defaultIo());
            defer self.mutex.unlock(defaultIo());

            return self.result;
        }

        pub fn cloneResult(self: *Self, allocator: std.mem.Allocator) error{OutOfMemory}!?ai_types.AssistantMessage {
            comptime if (R != ai_types.AssistantMessage) {
                @compileError("cloneResult() is only available on streams whose result type is ai_types.AssistantMessage");
            };
            self.mutex.lockUncancelable(defaultIo());
            const snapshot = self.result;
            const err = self.err_msg;
            self.mutex.unlock(defaultIo());
            if (err != null) return null;
            const result = snapshot orelse return null;
            return try ai_types.cloneAssistantMessage(allocator, result);
        }

        pub fn getError(self: *Self) ?[]const u8 {
            self.mutex.lockUncancelable(defaultIo());
            defer self.mutex.unlock(defaultIo());

            return self.err_msg;
        }
    };
}

pub const AssistantMessageStream = EventStream(ai_types.AssistantMessageEvent, ai_types.AssistantMessage);

pub const AssistantMessageEventStream = AssistantMessageStream;

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
    var stream = AssistantMessageStream.init(std.testing.allocator);
    defer stream.deinit();

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

}

test "EventStream push returns QueueFull when ring buffer exhausted" {
    const TestStream = EventStream(u32, bool);
    var stream = TestStream.init(std.testing.allocator);
    defer stream.deinit();

    for (0..TestStream.usable_capacity) |i| {
        try stream.push(@intCast(i));
    }
    try std.testing.expect(stream.isFull());
    try std.testing.expectError(error.QueueFull, stream.push(TestStream.usable_capacity));
    _ = stream.poll().?;
    try std.testing.expect(!stream.isFull());
}

test "AssistantMessageStream safe consumer flow: wait, copy, cloneResult, deinit" {
    const allocator = std.testing.allocator;

    var stream = AssistantMessageStream.init(allocator);

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    try stream.push(.{ .start = .{ .partial = partial } });
    try stream.push(.{ .text_delta = .{
        .content_index = 0,
        .delta = "hello ",
        .partial = partial,
    } });
    try stream.push(.{ .text_delta = .{
        .content_index = 0,
        .delta = "world",
        .partial = partial,
    } });
    try stream.push(.{ .toolcall_end = .{
        .content_index = 1,
        .tool_call = .{
            .id = "call-1",
            .name = "get_weather",
            .arguments_json = "{\"city\":\"SF\"}",
        },
        .partial = partial,
    } });

    const result_content = try allocator.alloc(ai_types.AssistantContent, 2);
    result_content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "hello world") } };
    result_content[1] = .{ .tool_call = .{
        .id = try allocator.dupe(u8, "call-1"),
        .name = try allocator.dupe(u8, "get_weather"),
        .arguments_json = try allocator.dupe(u8, "{\"city\":\"SF\"}"),
    } };
    stream.complete(.{
        .content = result_content,
        .api = try allocator.dupe(u8, "test-api"),
        .provider = try allocator.dupe(u8, "test-provider"),
        .model = try allocator.dupe(u8, "test-model"),
        .usage = .{ .input = 3, .output = 2 },
        .stop_reason = .tool_use,
        .timestamp = 1,
        .is_owned = true,
    });

    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);

    var tool_calls = std.ArrayList(ai_types.ToolCall).empty;
    defer {
        for (tool_calls.items) |*tc| ai_types.deinitToolCall(allocator, tc);
        tool_calls.deinit(allocator);
    }

    var saw_done_event = false;
    while (stream.wait()) |event| {
        switch (event) {
            .text_delta => |d| try text.appendSlice(allocator, d.delta),
            .toolcall_end => |tc| {
                var owned = try ai_types.cloneToolCall(allocator, tc.tool_call);
                errdefer ai_types.deinitToolCall(allocator, &owned);
                try tool_calls.append(allocator, owned);
            },
            .done => saw_done_event = true,
            else => {},
        }
    }
    try std.testing.expect(!saw_done_event);
    try std.testing.expect(stream.getError() == null);

    var result = (try stream.cloneResult(allocator)) orelse return error.NoResult;

    stream.deinit();

    try std.testing.expectEqualStrings("hello world", text.items);
    try std.testing.expectEqual(@as(usize, 1), tool_calls.items.len);
    try std.testing.expectEqualStrings("get_weather", tool_calls.items[0].name);
    try std.testing.expectEqualStrings("hello world", result.content[0].text.text);
    try std.testing.expectEqualStrings("get_weather", result.content[1].tool_call.name);
    try std.testing.expect(result.is_owned);

    result.deinit(allocator);
}

test "AssistantMessageStream cloneResult returns an independent deep copy" {
    const allocator = std.testing.allocator;

    var stream = AssistantMessageStream.init(allocator);

    const result_content = try allocator.alloc(ai_types.AssistantContent, 1);
    result_content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "ok") } };
    stream.complete(.{
        .content = result_content,
        .api = try allocator.dupe(u8, "test-api"),
        .provider = try allocator.dupe(u8, "test-provider"),
        .model = try allocator.dupe(u8, "test-model"),
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
        .is_owned = true,
    });

    var copy = (try stream.cloneResult(allocator)) orelse return error.NoResult;

    const internal = stream.getResult().?;
    try std.testing.expectEqualStrings("ok", copy.content[0].text.text);
    try std.testing.expect(
        @intFromPtr(copy.content[0].text.text.ptr) != @intFromPtr(internal.content[0].text.text.ptr),
    );

    stream.deinit();
    copy.deinit(allocator);
}

test "AssistantMessageStream cloneResult returns null on error-completed stream" {
    const allocator = std.testing.allocator;

    var stream = AssistantMessageStream.init(allocator);
    defer stream.deinit();

    stream.completeWithError("boom");

    try std.testing.expect((try stream.cloneResult(allocator)) == null);
    try std.testing.expectEqualStrings("boom", stream.getError().?);

    const result_content = try allocator.alloc(ai_types.AssistantContent, 1);
    result_content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "late") } };
    stream.complete(.{
        .content = result_content,
        .api = try allocator.dupe(u8, "test-api"),
        .provider = try allocator.dupe(u8, "test-provider"),
        .model = try allocator.dupe(u8, "test-model"),
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
        .is_owned = true,
    });

    try std.testing.expect(stream.getResult() != null);
    try std.testing.expect((try stream.cloneResult(allocator)) == null);
    try std.testing.expectEqualStrings("boom", stream.getError().?);
}

test "AssistantMessageStream owned events: consumer frees each polled event" {
    const allocator = std.testing.allocator;

    var stream = AssistantMessageStream.init(allocator);
    stream.owns_events = true;
    stream.clone_event_fn = ai_types.cloneAssistantMessageEvent;

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try stream.push(.{ .text_delta = .{
        .content_index = 0,
        .delta = "consumed",
        .partial = partial,
    } });
    try stream.push(.{ .text_delta = .{
        .content_index = 0,
        .delta = "left queued",
        .partial = partial,
    } });

    const result_content = try allocator.alloc(ai_types.AssistantContent, 1);
    result_content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "ok") } };
    stream.complete(.{
        .content = result_content,
        .api = try allocator.dupe(u8, "test-api"),
        .provider = try allocator.dupe(u8, "test-provider"),
        .model = try allocator.dupe(u8, "test-model"),
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
        .is_owned = true,
    });

    var polled: usize = 0;
    while (stream.wait()) |event| {
        var ev = event;
        defer ai_types.deinitAssistantMessageEvent(allocator, &ev);
        switch (ev) {
            .text_delta => |d| try std.testing.expect(d.delta.len > 0),
            else => {},
        }
        polled += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), polled);

    var result = (try stream.cloneResult(allocator)) orelse return error.NoResult;
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("ok", result.content[0].text.text);

    stream.deinit();
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

    for (0..TestStream.usable_capacity + 44) |i| {
        try stream.push(@intCast(i));
        const v = stream.poll().?;
        try std.testing.expectEqual(@as(u32, @intCast(i)), v);
    }

    try std.testing.expect(stream.poll() == null);
}

test "EventStream freeSlots stays correct after ring wrap-around" {
    const TestStream = EventStream(u32, bool);
    var stream = TestStream.init(std.testing.allocator);
    defer stream.deinit();

    for (0..TestStream.usable_capacity + 145) |i| {
        try stream.push(@intCast(i));
        _ = stream.poll().?;
        try std.testing.expectEqual(@as(usize, TestStream.usable_capacity), stream.freeSlots());
    }

    for (0..10) |_| try stream.push(0);
    try std.testing.expectEqual(@as(usize, TestStream.usable_capacity - 10), stream.freeSlots());
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

const DelayedCompleteCtx = struct {
    stream: *EventStream(u32, u32),

    fn run(self: *@This()) void {
        self.stream.markThreadDone();
        std.testing.io.sleep(.fromNanoseconds(10 * std.time.ns_per_ms), .boot) catch {};
        self.stream.complete(42);
    }
};

test "EventStream waitForCompletion gates on result publication" {
    const TestStream = EventStream(u32, u32);
    var stream = TestStream.init(std.testing.allocator);
    defer stream.deinit();

    try std.testing.expect(!stream.waitForCompletion(1));

    var ctx = DelayedCompleteCtx{ .stream = &stream };
    const th = try std.Thread.spawn(.{}, DelayedCompleteCtx.run, .{&ctx});
    defer th.join();

    try std.testing.expect(stream.waitForThread(2_000));
    try std.testing.expect(stream.waitForCompletion(2_000));
    try std.testing.expectEqual(@as(u32, 42), stream.getResult().?);
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
                    error.StreamCompleted, error.OutOfMemory => return,
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
