const std = @import("std");

/// Wall-clock milliseconds since the Unix epoch.
///
/// Zig 0.16 mapping: this remains a wall-clock timestamp helper, backed by the
/// Makai default I/O context/clock selected in the architecture decision rather
/// than exposing `std.Io` in the public signature.
pub fn nowMillis() i64 {
    return std.time.milliTimestamp();
}

/// Wall-clock seconds since the Unix epoch.
///
/// Zig 0.16 mapping: preserve wall-clock semantics while moving the internal
/// source to the default Makai context clock.
pub fn nowSeconds() i64 {
    return std.time.timestamp();
}

/// Wall-clock nanoseconds since the Unix epoch.
///
/// Zig 0.16 mapping: preserve timestamp semantics separately from monotonic
/// timing; use the context-backed timestamp source internally.
pub fn nowNanos() i128 {
    return std.time.nanoTimestamp();
}

var monotonic_timer: ?std.time.Timer = null;
var monotonic_mutex: std.Thread.Mutex = .{};

/// Monotonic nanoseconds suitable for durations and deadlines.
///
/// Zig 0.15.2 mapping: use a process-wide `std.time.Timer` so readings share a
/// stable monotonic origin and can be subtracted for elapsed-duration math.
/// Zig 0.16 mapping: move to the chosen `std.Io.Threaded`/default-context
/// monotonic clock internally while keeping raw `std.Io` out of this API.
pub fn monotonicNanos() u64 {
    monotonic_mutex.lock();
    defer monotonic_mutex.unlock();

    if (monotonic_timer == null) {
        monotonic_timer = std.time.Timer.start() catch return 0;
    }

    return monotonic_timer.?.read();
}

/// Sleep for a number of nanoseconds.
///
/// Zig 0.16 mapping: route through the Makai default I/O context timeout/sleep
/// primitive while keeping this public helper stable.
pub fn sleepNs(ns: u64) void {
    std.Thread.sleep(ns);
}

/// Sleep for a number of milliseconds.
pub fn sleepMs(ms: u64) void {
    sleepNs(std.math.mul(u64, ms, std.time.ns_per_ms) catch std.math.maxInt(u64));
}

test "compat time helpers return plausible timestamps" {
    try std.testing.expect(nowMillis() > 0);
    try std.testing.expect(nowSeconds() > 0);
    try std.testing.expect(nowNanos() > 0);
    _ = monotonicNanos();
}

test "compat sleep helpers accept zero duration" {
    sleepNs(0);
    sleepMs(0);
}
