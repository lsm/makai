const std = @import("std");

/// Wall-clock milliseconds since the Unix epoch.
///
/// 0.15.2: wraps `compat.time.nowMillis()`.
/// 0.16: use `std.Io.Timestamp.now` through the Makai default context while
/// keeping raw `std.Io` out of this public signature.
fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

pub fn nowMillis() i64 {
    return std.Io.Timestamp.now(defaultIo(), .real).toMilliseconds();
}

/// Wall-clock seconds since the Unix epoch.
///
/// 0.15.2: wraps `std.time.timestamp()`.
/// 0.16: use `std.Io.Timestamp.now` through the Makai default context while
/// preserving wall-clock semantics.
pub fn nowSeconds() i64 {
    return std.Io.Timestamp.now(defaultIo(), .real).toSeconds();
}

/// Wall-clock nanoseconds since the Unix epoch.
///
/// 0.15.2: wraps `std.time.nanoTimestamp()`.
/// 0.16: use `std.Io.Timestamp.now` through the Makai default context and keep
/// this separate from monotonic-duration measurements.
pub fn nowNanos() i64 {
    return @intCast(std.Io.Timestamp.now(defaultIo(), .real).toNanoseconds());
}

var monotonic_origin: ?std.Io.Timestamp = null;
var monotonic_mutex: std.Io.Mutex = .init;

/// Monotonic nanoseconds suitable for durations and deadlines.
///
/// 0.15.2: use a process-wide `std.time.Timer` so readings share a stable
/// monotonic origin and can be subtracted for elapsed-duration math.
/// 0.16: use `std.Io.Clock`/the chosen default-context monotonic clock
/// internally while keeping raw `std.Io` out of this API.
pub fn monotonicNanos() !u64 {
    monotonic_mutex.lockUncancelable(defaultIo());
    defer monotonic_mutex.unlock(defaultIo());

    const now = std.Io.Timestamp.now(defaultIo(), .boot);
    if (monotonic_origin == null) {
        monotonic_origin = now;
    }

    return @intCast(monotonic_origin.?.durationTo(now).nanoseconds);
}

/// Sleep for a number of nanoseconds.
///
/// 0.15.2: wraps `std.Thread.sleep`.
/// 0.16: route through the Makai default I/O context timeout/sleep primitive
/// while keeping this public helper stable.
pub fn sleepNs(ns: u64) void {
    const capped_ns = @min(ns, @as(u64, std.math.maxInt(i64)));
    defaultIo().sleep(.fromNanoseconds(@intCast(capped_ns)), .boot) catch {};
}

/// Sleep for a number of milliseconds.
pub fn sleepMs(ms: u64) void {
    sleepNs(std.math.mul(u64, ms, std.time.ns_per_ms) catch std.math.maxInt(u64));
}

test "compat time helpers return expected public types" {
    const millis: i64 = nowMillis();
    const seconds: i64 = nowSeconds();
    const nanos: i64 = nowNanos();
    const monotonic: u64 = try monotonicNanos();

    _ = millis;
    _ = seconds;
    _ = nanos;
    _ = monotonic;
}

test "compat time helpers return plausible wall-clock timestamps" {
    const seconds = nowSeconds();
    const millis = nowMillis();
    const nanos = nowNanos();

    try std.testing.expect(seconds > 0);
    try std.testing.expect(millis > 0);
    try std.testing.expect(nanos > 0);
    try std.testing.expect(@divTrunc(millis, std.time.ms_per_s) >= seconds - 1);
    try std.testing.expect(@divTrunc(nanos, std.time.ns_per_s) >= seconds - 1);
}

test "compat monotonic nanoseconds are nondecreasing" {
    const before = try monotonicNanos();
    sleepNs(1);
    const after = try monotonicNanos();

    try std.testing.expect(after >= before);
}

test "compat sleep helpers bound short sleeps" {
    const start_ns = try monotonicNanos();
    sleepNs(1 * std.time.ns_per_ms);
    const elapsed_ns = try monotonicNanos() - start_ns;

    // Only assert the lower bound: `sleepNs` must wait at least the requested
    // duration. Avoid an absolute upper bound here because scheduler pauses on
    // loaded or virtualized CI runners can legitimately exceed any tight
    // ceiling without indicating a defect in the wrapper.
    try std.testing.expect(elapsed_ns >= 1 * std.time.ns_per_ms);
}

test "compat sleep helpers accept zero duration" {
    sleepNs(0);
    sleepMs(0);
}
