
const std = @import("std");
const transport = @import("transport");
const event_stream = @import("event_stream");
const compat = @import("compat");

pub const OnRetryFn = *const fn (err: anyerror, attempt: u32, delay_ms: u64) void;

pub const TransportRetryOptions = struct {
    max_retries: u32 = 2,

    base_delay_ms: u64 = 100,

    max_delay_ms: u64 = 5000,

    retryable_error_names: ?[]const []const u8 = null,

    on_retry_fn: ?OnRetryFn = null,

    pub const default_retryable_error_names = [_][]const u8{
        "ConnectionRefused",
        "ConnectionResetByPeer",
        "ConnectionTimedOut",
        "BrokenPipe",
        "NetworkUnreachable",
        "ConnectionAborted",
        "HostUnreachable",
    };

    pub fn isRetryable(self: *const TransportRetryOptions, err: anyerror) bool {
        const err_name = @errorName(err);
        const error_list = self.retryable_error_names orelse &default_retryable_error_names;
        for (error_list) |retryable_name| {
            if (std.mem.eql(u8, retryable_name, err_name)) return true;
        }
        return false;
    }

    pub fn calculateBackoff(self: *const TransportRetryOptions, attempt: u32) u64 {
        const shift: u5 = @intCast(@min(attempt, 30));
        const shl_result = @shlWithOverflow(self.base_delay_ms, shift);
        const exponential: u64 = if (shl_result.@"1" != 0) self.max_delay_ms else shl_result.@"0";
        const capped = @min(exponential, self.max_delay_ms);

        const seed: u64 = @intCast(compat.time.nowNanos());
        var prng = std.Random.DefaultPrng.init(seed);

        if (capped <= self.base_delay_ms) return capped;
        return prng.random().intRangeAtMost(u64, self.base_delay_ms, capped);
    }
};

pub fn retryableRead(
    receiver: *const transport.Receiver,
    allocator: std.mem.Allocator,
    opts: *const TransportRetryOptions,
) anyerror!?[]const u8 {
    var attempt: u32 = 0;
    while (true) {
        const result = receiver.read(allocator) catch |err| {
            if (attempt < opts.max_retries and opts.isRetryable(err)) {
                const delay = opts.calculateBackoff(attempt);
                if (opts.on_retry_fn) |on_retry| {
                    on_retry(err, attempt, delay);
                }
                compat.time.sleepMs(delay);
                attempt += 1;
                continue;
            }
            return err;
        };
        return result;
    }
}

pub fn receiveStreamWithRetry(
    receiver: *const transport.Receiver,
    stream: *event_stream.AssistantMessageStream,
    allocator: std.mem.Allocator,
    opts: TransportRetryOptions,
) !void {
    while (true) {
        const line = retryableRead(receiver, allocator, &opts) catch |err| {
            const err_name = @errorName(err);
            const allocated_msg = std.fmt.allocPrint(allocator, "Transport read error: {s}", .{err_name}) catch
                @as(?[]const u8, null);
            const msg: []const u8 = allocated_msg orelse "Transport read error: unknown";
            defer if (allocated_msg != null) allocator.free(msg);
            stream.completeWithError(msg);
            return error.TransportReadFailed;
        };

        if (line) |data| {
            defer allocator.free(data);

            const msg = transport.deserialize(data, allocator) catch |err| {
                if (err == error.OutOfMemory) {
                    stream.completeWithError("Out of memory during deserialization");
                    return error.OutOfMemory;
                }
                continue;
            };

            switch (msg) {
                .event => |ev| {
                    stream.push(ev) catch {
                        transport.freeEventStrings(ev, allocator);
                        stream.completeWithError("Stream queue full");
                        return error.StreamQueueFull;
                    };
                },
                .result => |r| {
                    stream.complete(r);
                    return;
                },
                .stream_error => |e| {
                    stream.completeWithError(e.slice());
                    var mutable_e = e;
                    mutable_e.deinit(allocator);
                    return;
                },
                .control => |ctrl| {
                    if (receiver.control_callback) |cb| {
                        cb(ctrl, receiver.control_callback_ctx);
                    }
                    transport.freeControlStrings(ctrl, allocator);
                },
            }
        } else {
            break;
        }
    }
    stream.completeWithError("Transport closed unexpectedly");
}

pub fn receiveStreamFromByteStreamTolerant(
    byte_stream: *transport.ByteStream,
    msg_stream: *event_stream.AssistantMessageStream,
    allocator: std.mem.Allocator,
) void {
    receiveStreamFromByteStreamTolerantWithControl(byte_stream, msg_stream, null, null, allocator);
}

pub fn receiveStreamFromByteStreamTolerantWithControl(
    byte_stream: *transport.ByteStream,
    msg_stream: *event_stream.AssistantMessageStream,
    control_callback: ?transport.ControlMessageCallback,
    control_callback_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
) void {
    defer byte_stream.complete({});

    while (byte_stream.wait()) |chunk| {
        defer {
            var mutable_chunk = chunk;
            mutable_chunk.deinit(allocator);
        }

        const msg = transport.deserialize(chunk.data, allocator) catch |err| {
            if (err == error.OutOfMemory) {
                msg_stream.completeWithError("Out of memory during deserialization");
                return;
            }
            continue;
        };

        switch (msg) {
            .event => |ev| {
                msg_stream.push(ev) catch {
                    msg_stream.completeWithError("Stream queue full");
                    transport.freeEventStrings(ev, allocator);
                    return;
                };
            },
            .result => |r| {
                msg_stream.complete(r);
                return;
            },
            .stream_error => |e| {
                msg_stream.completeWithError(e.slice());
                var mutable_e = e;
                mutable_e.deinit(allocator);
                return;
            },
            .control => |ctrl| {
                if (control_callback) |cb| {
                    cb(ctrl, control_callback_ctx);
                }
                transport.freeControlStrings(ctrl, allocator);
            },
        }
    }

    if (byte_stream.getError()) |err| {
        msg_stream.completeWithError(err);
    } else {
        msg_stream.completeWithError("Transport closed unexpectedly");
    }
}

test "TransportRetryOptions defaults" {
    const opts = TransportRetryOptions{};
    try std.testing.expectEqual(@as(u32, 2), opts.max_retries);
    try std.testing.expectEqual(@as(u64, 100), opts.base_delay_ms);
    try std.testing.expectEqual(@as(u64, 5000), opts.max_delay_ms);
    try std.testing.expect(opts.retryable_error_names == null);
    try std.testing.expect(opts.on_retry_fn == null);
}

test "TransportRetryOptions isRetryable with default errors" {
    const opts = TransportRetryOptions{};

    try std.testing.expect(opts.isRetryable(error.ConnectionRefused));
    try std.testing.expect(opts.isRetryable(error.ConnectionResetByPeer));
    try std.testing.expect(opts.isRetryable(error.ConnectionTimedOut));
    try std.testing.expect(opts.isRetryable(error.BrokenPipe));
    try std.testing.expect(opts.isRetryable(error.NetworkUnreachable));

    try std.testing.expect(!opts.isRetryable(error.OutOfMemory));
    try std.testing.expect(!opts.isRetryable(error.InvalidData));
    try std.testing.expect(!opts.isRetryable(error.PermissionDenied));
}

test "TransportRetryOptions isRetryable with custom error list" {
    const custom_errors = [_][]const u8{ "CustomTransientError", "AnotherRetryable" };
    const opts = TransportRetryOptions{
        .retryable_error_names = &custom_errors,
    };

    try std.testing.expect(opts.isRetryable(error.CustomTransientError));
    try std.testing.expect(!opts.isRetryable(error.ConnectionRefused));
    try std.testing.expect(!opts.isRetryable(error.OutOfMemory));
}

test "TransportRetryOptions calculateBackoff increases with attempts" {
    const opts = TransportRetryOptions{
        .base_delay_ms = 100,
        .max_delay_ms = 10000,
    };

    const d0 = opts.calculateBackoff(0);
    const d5 = opts.calculateBackoff(5);

    try std.testing.expect(d0 >= 100);
    try std.testing.expect(d0 <= 100);

    try std.testing.expect(d5 >= 100);
    try std.testing.expect(d5 <= 3200);
}

test "TransportRetryOptions calculateBackoff respects max_delay_ms" {
    const opts = TransportRetryOptions{
        .base_delay_ms = 100,
        .max_delay_ms = 500,
    };

    const d20 = opts.calculateBackoff(20);
    try std.testing.expect(d20 >= 100);
    try std.testing.expect(d20 <= 500);
}

test "TransportRetryOptions calculateBackoff respects max_delay_ms when base exceeds it" {
    const opts = TransportRetryOptions{
        .base_delay_ms = 10000,
        .max_delay_ms = 500,
    };

    const d0 = opts.calculateBackoff(0);
    try std.testing.expect(d0 <= 500);
}

test "TransportRetryOptions calculateBackoff with jitter produces varied delays" {
    const opts = TransportRetryOptions{
        .base_delay_ms = 100,
        .max_delay_ms = 10000,
    };

    const d1 = opts.calculateBackoff(5);
    compat.time.sleepNs(1_000_000);
    const d2 = opts.calculateBackoff(5);

    try std.testing.expect(d1 >= 100);
    try std.testing.expect(d1 <= 3200);
    try std.testing.expect(d2 >= 100);
    try std.testing.expect(d2 <= 3200);
}

test "retryableRead succeeds after transient failures" {
    const allocator = std.testing.allocator;

    const MockReceiver = struct {
        data: []const []const u8,
        index: usize = 0,
        remaining_failures: u32,

        fn readFn(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.remaining_failures > 0) {
                self.remaining_failures -= 1;
                return error.ConnectionResetByPeer;
            }
            if (self.index >= self.data.len) return null;
            const result = try alloc.dupe(u8, self.data[self.index]);
            self.index += 1;
            return result;
        }
    };

    const test_data = [_][]const u8{ "hello", "world" };
    var mock = MockReceiver{
        .data = &test_data,
        .remaining_failures = 3,
    };

    var receiver = transport.Receiver{
        .context = @ptrCast(&mock),
        .read_fn = MockReceiver.readFn,
    };

    const opts = TransportRetryOptions{
        .max_retries = 5,
        .base_delay_ms = 1,
        .max_delay_ms = 10,
    };

    const line1 = try retryableRead(&receiver, allocator, &opts);
    try std.testing.expect(line1 != null);
    try std.testing.expectEqualStrings("hello", line1.?);
    allocator.free(line1.?);

    const line2 = try retryableRead(&receiver, allocator, &opts);
    try std.testing.expect(line2 != null);
    try std.testing.expectEqualStrings("world", line2.?);
    allocator.free(line2.?);

    const line3 = try retryableRead(&receiver, allocator, &opts);
    try std.testing.expect(line3 == null);
}

test "retryableRead returns error after exhausting retries" {
    const allocator = std.testing.allocator;

    const AlwaysFailReceiver = struct {
        attempt_count: u32 = 0,

        fn readFn(ctx: *anyopaque, _: std.mem.Allocator) anyerror!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.attempt_count += 1;
            return error.ConnectionRefused;
        }
    };

    var mock = AlwaysFailReceiver{};
    var receiver = transport.Receiver{
        .context = @ptrCast(&mock),
        .read_fn = AlwaysFailReceiver.readFn,
    };

    const opts = TransportRetryOptions{
        .max_retries = 2,
        .base_delay_ms = 1,
        .max_delay_ms = 5,
    };

    const result = retryableRead(&receiver, allocator, &opts);
    try std.testing.expectError(error.ConnectionRefused, result);

    try std.testing.expectEqual(@as(u32, 3), mock.attempt_count);
}

test "retryableRead does not retry non-transient errors" {
    const allocator = std.testing.allocator;

    const FailOnceReceiver = struct {
        attempt_count: u32 = 0,

        fn readFn(ctx: *anyopaque, _: std.mem.Allocator) anyerror!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.attempt_count += 1;
            return error.PermissionDenied;
        }
    };

    var mock = FailOnceReceiver{};
    var receiver = transport.Receiver{
        .context = @ptrCast(&mock),
        .read_fn = FailOnceReceiver.readFn,
    };

    const opts = TransportRetryOptions{
        .max_retries = 5,
        .base_delay_ms = 1,
    };

    const result = retryableRead(&receiver, allocator, &opts);
    try std.testing.expectError(error.PermissionDenied, result);

    try std.testing.expectEqual(@as(u32, 1), mock.attempt_count);
}

test "retryableRead disabled with max_retries 0" {
    const allocator = std.testing.allocator;

    const FailOnceReceiver = struct {
        attempt_count: u32 = 0,

        fn readFn(ctx: *anyopaque, _: std.mem.Allocator) anyerror!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.attempt_count += 1;
            return error.ConnectionResetByPeer;
        }
    };

    var mock = FailOnceReceiver{};
    var receiver = transport.Receiver{
        .context = @ptrCast(&mock),
        .read_fn = FailOnceReceiver.readFn,
    };

    const opts = TransportRetryOptions{
        .max_retries = 0,
    };

    const result = retryableRead(&receiver, allocator, &opts);
    try std.testing.expectError(error.ConnectionResetByPeer, result);

    try std.testing.expectEqual(@as(u32, 1), mock.attempt_count);
}

test "retryableRead invokes on_retry_fn callback" {
    const allocator = std.testing.allocator;

    const CallbackState = struct {
        var retry_count: u32 = 0;
        var last_error_name: []const u8 = "";
        var last_attempt: u32 = 0;
        var last_delay_ms: u64 = 0;

        fn reset() void {
            retry_count = 0;
            last_error_name = "";
            last_attempt = 0;
            last_delay_ms = 0;
        }

        fn onRetry(err: anyerror, attempt: u32, delay_ms: u64) void {
            retry_count += 1;
            last_error_name = @errorName(err);
            last_attempt = attempt;
            last_delay_ms = delay_ms;
        }
    };
    CallbackState.reset();

    const MockReceiver = struct {
        remaining_failures: u32,
        data: []const []const u8,
        index: usize = 0,

        fn readFn(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.remaining_failures > 0) {
                self.remaining_failures -= 1;
                return error.ConnectionRefused;
            }
            if (self.index >= self.data.len) return null;
            const result = try alloc.dupe(u8, self.data[self.index]);
            self.index += 1;
            return result;
        }
    };

    const data = [_][]const u8{"success"};
    var mock = MockReceiver{
        .remaining_failures = 2,
        .data = &data,
    };

    var receiver = transport.Receiver{
        .context = @ptrCast(&mock),
        .read_fn = MockReceiver.readFn,
    };

    const opts = TransportRetryOptions{
        .max_retries = 5,
        .base_delay_ms = 1,
        .max_delay_ms = 5,
        .on_retry_fn = CallbackState.onRetry,
    };

    const line = try retryableRead(&receiver, allocator, &opts);
    try std.testing.expect(line != null);
    defer allocator.free(line.?);

    try std.testing.expectEqual(@as(u32, 2), CallbackState.retry_count);
    try std.testing.expectEqualStrings("ConnectionRefused", CallbackState.last_error_name);
    try std.testing.expect(CallbackState.last_delay_ms > 0);
}

test "receiveStreamWithRetry skips bad frames and continues" {
    const allocator = std.testing.allocator;

    const MockReceiver = struct {
        items: []const []const u8,
        index: usize = 0,

        fn readFn(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.index >= self.items.len) return null;
            const result = try alloc.dupe(u8, self.items[self.index]);
            self.index += 1;
            return result;
        }
    };

    const start_json = try std.fmt.allocPrint(allocator, "{{\"type\":\"start\",\"model\":\"test-model\"}}", .{});
    defer allocator.free(start_json);

    const result_json = try transport.serializeResult(.{
        .content = &.{},
        .usage = .{},
        .stop_reason = .stop,
        .model = "test-model",
        .api = "test-api",
        .provider = "test-provider",
        .timestamp = 100,
    }, allocator);
    defer allocator.free(result_json);

    const items = [_][]const u8{
        "not valid json at all",
        start_json,
        result_json,
    };

    var mock = MockReceiver{ .items = &items };
    var receiver = transport.Receiver{
        .context = @ptrCast(&mock),
        .read_fn = MockReceiver.readFn,
    };

    var msg_stream = event_stream.AssistantMessageStream.init(allocator);
    defer msg_stream.deinit();

    const opts = TransportRetryOptions{ .max_retries = 0, .base_delay_ms = 1 };

    try receiveStreamWithRetry(&receiver, &msg_stream, allocator, opts);

    try std.testing.expect(msg_stream.isDone());

    const ev = msg_stream.poll();
    try std.testing.expect(ev != null);
    try std.testing.expect(ev.? == .start);

    var mutable_ev = ev.?;
    ai_types.deinitAssistantMessageEvent(allocator, &mutable_ev);
}

test "receiveStreamWithRetry retries transient read errors" {
    const allocator = std.testing.allocator;

    const MockReceiver = struct {
        data: []const []const u8,
        index: usize = 0,
        remaining_failures: u32,

        fn readFn(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.remaining_failures > 0) {
                self.remaining_failures -= 1;
                return error.ConnectionResetByPeer;
            }
            if (self.index >= self.data.len) return null;
            const result = try alloc.dupe(u8, self.data[self.index]);
            self.index += 1;
            return result;
        }
    };

    const result_json = try transport.serializeResult(.{
        .content = &.{},
        .usage = .{},
        .stop_reason = .stop,
        .model = "test-model",
        .api = "test-api",
        .provider = "test-provider",
        .timestamp = 100,
    }, allocator);
    defer allocator.free(result_json);

    const items = [_][]const u8{result_json};
    var mock = MockReceiver{
        .data = &items,
        .remaining_failures = 2,
    };

    var receiver = transport.Receiver{
        .context = @ptrCast(&mock),
        .read_fn = MockReceiver.readFn,
    };

    var msg_stream = event_stream.AssistantMessageStream.init(allocator);
    defer msg_stream.deinit();

    const opts = TransportRetryOptions{ .max_retries = 3, .base_delay_ms = 1, .max_delay_ms = 5 };

    try receiveStreamWithRetry(&receiver, &msg_stream, allocator, opts);

    try std.testing.expect(msg_stream.isDone());
    try std.testing.expect(msg_stream.getResult() != null);
}

test "receiveStreamFromByteStreamTolerant skips bad frames" {
    const allocator = std.testing.allocator;

    var byte_stream = transport.ByteStream.init(allocator);
    defer byte_stream.deinit();

    try byte_stream.push(.{ .data = try allocator.dupe(u8, "not valid json"), .owned = true });

    const event_json = try transport.serializeEvent(.{
        .text_delta = .{ .content_index = 0, .delta = "Hello", .partial = .{
            .content = &.{},
            .api = "",
            .provider = "",
            .model = "",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 0,
        } },
    }, allocator);
    defer allocator.free(event_json);
    try byte_stream.push(.{ .data = try allocator.dupe(u8, event_json), .owned = true });

    const result_json = try transport.serializeResult(.{
        .content = &.{},
        .usage = .{},
        .stop_reason = .stop,
        .model = "test-model",
        .api = "test-api",
        .provider = "test-provider",
        .timestamp = 0,
    }, allocator);
    defer allocator.free(result_json);
    try byte_stream.push(.{ .data = try allocator.dupe(u8, result_json), .owned = true });

    byte_stream.complete({});

    var msg_stream = event_stream.AssistantMessageStream.init(allocator);
    defer msg_stream.deinit();

    receiveStreamFromByteStreamTolerant(&byte_stream, &msg_stream, allocator);

    try std.testing.expect(msg_stream.isDone());

    const ev = msg_stream.poll();
    try std.testing.expect(ev != null);
    try std.testing.expect(ev.? == .text_delta);
    try std.testing.expectEqualStrings("Hello", ev.?.text_delta.delta);
    allocator.free(ev.?.text_delta.delta);
}

test "receiveStreamFromByteStreamTolerant handles all-good stream" {
    const allocator = std.testing.allocator;

    var byte_stream = transport.ByteStream.init(allocator);
    defer byte_stream.deinit();

    const result_json = try transport.serializeResult(.{
        .content = &.{},
        .usage = .{},
        .stop_reason = .stop,
        .model = "test-model",
        .api = "test-api",
        .provider = "test-provider",
        .timestamp = 0,
    }, allocator);
    defer allocator.free(result_json);
    try byte_stream.push(.{ .data = try allocator.dupe(u8, result_json), .owned = true });

    byte_stream.complete({});

    var msg_stream = event_stream.AssistantMessageStream.init(allocator);
    defer msg_stream.deinit();

    receiveStreamFromByteStreamTolerant(&byte_stream, &msg_stream, allocator);

    try std.testing.expect(msg_stream.isDone());
    try std.testing.expect(msg_stream.getResult() != null);
}

test "receiveStreamFromByteStreamTolerantWithControl handles control messages" {
    const allocator = std.testing.allocator;

    var byte_stream = transport.ByteStream.init(allocator);
    defer byte_stream.deinit();

    try byte_stream.push(.{ .data = try allocator.dupe(u8, "bad json"), .owned = true });
    try byte_stream.push(.{ .data = try allocator.dupe(u8, "{\"type\":\"ping\"}"), .owned = true });

    const result_json = try transport.serializeResult(.{
        .content = &.{},
        .usage = .{},
        .stop_reason = .stop,
        .model = "test-model",
        .api = "test-api",
        .provider = "test-provider",
        .timestamp = 0,
    }, allocator);
    defer allocator.free(result_json);
    try byte_stream.push(.{ .data = try allocator.dupe(u8, result_json), .owned = true });

    byte_stream.complete({});

    var msg_stream = event_stream.AssistantMessageStream.init(allocator);
    defer msg_stream.deinit();

    var received_ping = false;
    const TestCallbackCtx = struct {
        flag: *bool,
        fn callback(ctrl: transport.ControlMessage, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (ctrl == .ping) {
                self.flag.* = true;
            }
        }
    };
    var cb_ctx = TestCallbackCtx{ .flag = &received_ping };

    receiveStreamFromByteStreamTolerantWithControl(
        &byte_stream,
        &msg_stream,
        TestCallbackCtx.callback,
        &cb_ctx,
        allocator,
    );

    try std.testing.expect(received_ping);
    try std.testing.expect(msg_stream.isDone());
}

test "TransportRetryOptions zero base_delay_ms returns zero" {
    const opts = TransportRetryOptions{
        .base_delay_ms = 0,
        .max_delay_ms = 1000,
    };

    const d = opts.calculateBackoff(0);
    try std.testing.expectEqual(@as(u64, 0), d);
}

test "TransportRetryOptions calculateBackoff handles large attempt without overflow" {
    const opts = TransportRetryOptions{
        .base_delay_ms = 100,
        .max_delay_ms = 5000,
    };

    const d = opts.calculateBackoff(100);
    try std.testing.expect(d >= 100);
    try std.testing.expect(d <= 5000);
}

const ai_types = @import("ai_types");

const CustomTransientError = error{CustomTransientError};
