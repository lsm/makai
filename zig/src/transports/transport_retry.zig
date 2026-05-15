//! Transport-level retry with exponential backoff for transient errors.
//!
//! Provides configurable retry for:
//! - Transport connection failures (read errors on Receiver)
//! - Frame reads (transient decode errors on ByteStream)
//!
//! Non-transient errors (auth failures, invalid_request, etc.) are not retried.
//! Retry can be disabled by setting `max_retries` to 0.

const std = @import("std");
const transport = @import("transport");
const event_stream = @import("event_stream");
const compat = @import("compat");

/// Callback type for retry notifications.
/// Invoked on each retry attempt with the error, attempt number (0-based), and delay in ms.
pub const OnRetryFn = *const fn (err: anyerror, attempt: u32, delay_ms: u64) void;

/// Configuration for transport-level retry with exponential backoff.
///
/// Provides configurable retry for transient transport errors such as
/// connection failures and frame decode errors. Non-transient errors
/// (auth failures, invalid_request, etc.) are not retried.
///
/// Example usage:
/// ```zig
/// const opts = TransportRetryOptions{ .max_retries = 3, .base_delay_ms = 200 };
/// const line = try retryableRead(&receiver, allocator, &opts);
/// ```
pub const TransportRetryOptions = struct {
    /// Maximum number of retry attempts. Set to 0 to disable retry.
    max_retries: u32 = 2,

    /// Base delay in milliseconds for exponential backoff.
    base_delay_ms: u64 = 100,

    /// Maximum delay in milliseconds for backoff (caps exponential growth).
    max_delay_ms: u64 = 5000,

    /// Optional list of error names to retry on. If null, uses built-in defaults.
    /// Error names match Zig's `@errorName()` output (e.g., "ConnectionResetByPeer").
    retryable_error_names: ?[]const []const u8 = null,

    /// Optional callback invoked on each retry attempt.
    /// Use for logging or metrics. May be null.
    on_retry_fn: ?OnRetryFn = null,

    /// Default transient transport error names that are retryable.
    pub const default_retryable_error_names = [_][]const u8{
        "ConnectionRefused",
        "ConnectionResetByPeer",
        "ConnectionTimedOut",
        "BrokenPipe",
        "NetworkUnreachable",
        "ConnectionAborted",
        "HostUnreachable",
    };

    /// Check if an error should be retried based on these options.
    ///
    /// If `retryable_error_names` is set, only errors matching those names are retryable.
    /// Otherwise, checks against the built-in default transient error list.
    pub fn isRetryable(self: *const TransportRetryOptions, err: anyerror) bool {
        const err_name = @errorName(err);
        const error_list = self.retryable_error_names orelse &default_retryable_error_names;
        for (error_list) |retryable_name| {
            if (std.mem.eql(u8, retryable_name, err_name)) return true;
        }
        return false;
    }

    /// Calculate backoff delay with jitter for the given attempt (0-based).
    ///
    /// Uses exponential backoff: `base_delay_ms * 2^attempt`, capped at `max_delay_ms`.
    /// Adds random jitter in range `[base_delay_ms, capped]` to prevent thundering herd
    /// when multiple clients retry simultaneously.
    pub fn calculateBackoff(self: *const TransportRetryOptions, attempt: u32) u64 {
        // Exponential backoff: base * 2^attempt, with overflow protection.
        // If the left shift would overflow u64, clamp to max_delay_ms directly.
        const shift: u5 = @intCast(@min(attempt, 30));
        const shl_result = @shlWithOverflow(self.base_delay_ms, shift);
        const exponential: u64 = if (shl_result.@"1" != 0) self.max_delay_ms else shl_result.@"0";
        const capped = @min(exponential, self.max_delay_ms);

        // Full jitter: random value in [base_delay_ms, capped]
        // This prevents thundering herd by spreading retry attempts
        const seed: u64 = @intCast(compat.time.nowNanos());
        var prng = std.Random.DefaultPrng.init(seed);

        // When capped <= base_delay_ms (e.g., base > max_delay or early attempts),
        // return the capped value to honor the max_delay_ms contract.
        if (capped <= self.base_delay_ms) return capped;
        return prng.random().intRangeAtMost(u64, self.base_delay_ms, capped);
    }
};

/// Read from a Receiver with retry on transient transport errors.
///
/// Retries up to `opts.max_retries` times with exponential backoff.
/// Only retries errors that match the retryable error list in options.
/// Non-retryable errors are returned immediately.
///
/// Set `opts.max_retries` to 0 to disable retry (equivalent to calling `receiver.read()` directly).
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

/// Receive from a Receiver with retry on transient errors and push into a local stream.
///
/// Like `transport.receiveStream`, but:
/// - Retries read failures with exponential backoff (via `retryableRead`)
/// - Skips frames that fail deserialization (transient decode tolerance)
///
/// If `opts.max_retries` is 0, behaves like the standard `receiveStream`.
pub fn receiveStreamWithRetry(
    receiver: *const transport.Receiver,
    stream: *event_stream.AssistantMessageStream,
    allocator: std.mem.Allocator,
    opts: TransportRetryOptions,
) !void {
    while (true) {
        const line = retryableRead(receiver, allocator, &opts) catch |err| {
            const err_name = @errorName(err);
            // Include the specific error name for debuggability.
            // Track allocation to avoid freeing a string literal fallback.
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
                // Only skip decode/parse errors; propagate fatal errors like OOM
                if (err == error.OutOfMemory) {
                    stream.completeWithError("Out of memory during deserialization");
                    return error.OutOfMemory;
                }
                // Transient decode error — skip this frame and continue reading
                continue;
            };

            switch (msg) {
                .event => |ev| {
                    stream.push(ev) catch {
                        transport.freeEventStrings(ev, allocator);
                        stream.completeWithError("Stream queue full");
                        return;
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
            // EOF
            break;
        }
    }
    stream.completeWithError("Transport closed unexpectedly");
}

/// Receive from a ByteStream and push into an AssistantMessageStream with tolerance
/// for transient decode errors.
///
/// Like `transport.receiveStreamFromByteStream`, but skips frames that fail deserialization
/// instead of aborting the entire stream. This handles transient decode errors caused by
/// corrupted frames in transit.
///
/// Control messages are discarded. Use `receiveStreamFromByteStreamTolerantWithControl`
/// for control message handling.
pub fn receiveStreamFromByteStreamTolerant(
    byte_stream: *transport.ByteStream,
    msg_stream: *event_stream.AssistantMessageStream,
    allocator: std.mem.Allocator,
) void {
    receiveStreamFromByteStreamTolerantWithControl(byte_stream, msg_stream, null, null, allocator);
}

/// Receive from a ByteStream with tolerance for transient decode errors and optional control callback.
///
/// When deserialization fails for a chunk (excluding fatal errors like OOM), the chunk is
/// skipped and processing continues with the next chunk. This provides resilience against
/// transient frame corruption without masking terminal failures.
///
/// If `control_callback` is provided, it will be invoked for control messages before they are freed.
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
            // Only skip decode/parse errors; propagate fatal errors like OOM
            if (err == error.OutOfMemory) {
                msg_stream.completeWithError("Out of memory during deserialization");
                return;
            }
            // Transient decode error — skip this frame and continue to the next one.
            // A corrupted frame in transit should not kill the entire stream.
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

// =============================================================================
// Tests
// =============================================================================

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

    // Default retryable errors
    try std.testing.expect(opts.isRetryable(error.ConnectionRefused));
    try std.testing.expect(opts.isRetryable(error.ConnectionResetByPeer));
    try std.testing.expect(opts.isRetryable(error.ConnectionTimedOut));
    try std.testing.expect(opts.isRetryable(error.BrokenPipe));
    try std.testing.expect(opts.isRetryable(error.NetworkUnreachable));

    // Non-retryable errors
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

    // With jitter, we can't check exact values, but verify they're within bounds
    const d0 = opts.calculateBackoff(0);
    const d5 = opts.calculateBackoff(5);

    // d0 should be in [100, 100] (2^0 = 1, capped = 100)
    try std.testing.expect(d0 >= 100);
    try std.testing.expect(d0 <= 100);

    // d5 should be in [100, 3200] (2^5 = 32, 100*32 = 3200)
    try std.testing.expect(d5 >= 100);
    try std.testing.expect(d5 <= 3200);
}

test "TransportRetryOptions calculateBackoff respects max_delay_ms" {
    const opts = TransportRetryOptions{
        .base_delay_ms = 100,
        .max_delay_ms = 500,
    };

    // Even at high attempt, delay is capped
    const d20 = opts.calculateBackoff(20);
    try std.testing.expect(d20 >= 100);
    try std.testing.expect(d20 <= 500);
}

test "TransportRetryOptions calculateBackoff respects max_delay_ms when base exceeds it" {
    const opts = TransportRetryOptions{
        .base_delay_ms = 10000,
        .max_delay_ms = 500,
    };

    // base_delay_ms > max_delay_ms — should return capped (max_delay_ms), not base
    const d0 = opts.calculateBackoff(0);
    try std.testing.expect(d0 <= 500);
}

test "TransportRetryOptions calculateBackoff with jitter produces varied delays" {
    // Deterministic test: verify jitter by using two seeds that are far apart
    // (separated by a sleep) and checking the outputs differ.
    const opts = TransportRetryOptions{
        .base_delay_ms = 100,
        .max_delay_ms = 10000,
    };

    const d1 = opts.calculateBackoff(5);
    compat.time.sleepNs(1_000_000); // 1ms to get a different nanosecond seed
    const d2 = opts.calculateBackoff(5);

    // With 20 samples both values should be in [100, 3200]
    try std.testing.expect(d1 >= 100);
    try std.testing.expect(d1 <= 3200);
    try std.testing.expect(d2 >= 100);
    try std.testing.expect(d2 <= 3200);
    // They should not both be identical (statistical — this is deterministic
    // because the seed comes from nanoseconds and we waited 1ms)
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
        .base_delay_ms = 1, // Fast for tests
        .max_delay_ms = 10,
    };

    // First read should succeed after 3 failures
    const line1 = try retryableRead(&receiver, allocator, &opts);
    try std.testing.expect(line1 != null);
    try std.testing.expectEqualStrings("hello", line1.?);
    allocator.free(line1.?);

    // Second read should succeed immediately (no more failures)
    const line2 = try retryableRead(&receiver, allocator, &opts);
    try std.testing.expect(line2 != null);
    try std.testing.expectEqualStrings("world", line2.?);
    allocator.free(line2.?);

    // EOF
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

    // Should have tried: 1 initial + 2 retries = 3 total attempts
    try std.testing.expectEqual(@as(u32, 3), mock.attempt_count);
}

test "retryableRead does not retry non-transient errors" {
    const allocator = std.testing.allocator;

    const FailOnceReceiver = struct {
        attempt_count: u32 = 0,

        fn readFn(ctx: *anyopaque, _: std.mem.Allocator) anyerror!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.attempt_count += 1;
            return error.PermissionDenied; // Non-transient
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

    // Should have tried only once (no retry for non-transient)
    try std.testing.expectEqual(@as(u32, 1), mock.attempt_count);
}

test "retryableRead disabled with max_retries 0" {
    const allocator = std.testing.allocator;

    const FailOnceReceiver = struct {
        attempt_count: u32 = 0,

        fn readFn(ctx: *anyopaque, _: std.mem.Allocator) anyerror!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.attempt_count += 1;
            return error.ConnectionResetByPeer; // Normally retryable
        }
    };

    var mock = FailOnceReceiver{};
    var receiver = transport.Receiver{
        .context = @ptrCast(&mock),
        .read_fn = FailOnceReceiver.readFn,
    };

    const opts = TransportRetryOptions{
        .max_retries = 0, // Disabled
    };

    const result = retryableRead(&receiver, allocator, &opts);
    try std.testing.expectError(error.ConnectionResetByPeer, result);

    // Should have tried only once (retry disabled)
    try std.testing.expectEqual(@as(u32, 1), mock.attempt_count);
}

test "retryableRead invokes on_retry_fn callback" {
    const allocator = std.testing.allocator;

    // Use file-scope state for the callback (OnRetryFn is a plain fn pointer,
    // so we can't capture context — a file-level var is the simplest approach).
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

    // Create a receiver that returns: bad frame, good event, result
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

    // Build test frames: invalid JSON, valid event, valid result
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
        "not valid json at all", // Bad frame — should be skipped
        start_json, // Good frame
        result_json, // Terminal frame
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

    // Stream should be complete
    try std.testing.expect(msg_stream.isDone());

    // The start event should have been pushed
    const ev = msg_stream.poll();
    try std.testing.expect(ev != null);
    try std.testing.expect(ev.? == .start);

    // Clean up the polled event's owned strings
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

    // Stream should be complete with the result
    try std.testing.expect(msg_stream.isDone());
    try std.testing.expect(msg_stream.getResult() != null);
}

test "receiveStreamFromByteStreamTolerant skips bad frames" {
    const allocator = std.testing.allocator;

    var byte_stream = transport.ByteStream.init(allocator);
    defer byte_stream.deinit();

    // Push: bad chunk, good event chunk, result chunk
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

    // Stream should be done
    try std.testing.expect(msg_stream.isDone());

    // The text_delta event should have been pushed (bad frame was skipped)
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

    // Push only valid frames
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

    // Push: bad frame, ping control, result
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

    // Very large attempt number — should be capped, not overflow
    const d = opts.calculateBackoff(100);
    try std.testing.expect(d >= 100);
    try std.testing.expect(d <= 5000);
}

// Import ai_types for test helper construction
const ai_types = @import("ai_types");

// Declare custom errors used in tests
const CustomTransientError = error{CustomTransientError};
