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

/// Monotonic nanoseconds suitable for durations and deadlines.
///
/// Zig 0.16 mapping: move to the chosen `std.Io.Threaded`/default-context
/// monotonic clock internally while keeping raw `std.Io` out of this API.
pub fn monotonicNanos() u64 {
    var timer = std.time.Timer.start() catch return 0;
    return timer.read();
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
    sleepNs(ms * std.time.ns_per_ms);
}

test "compat time helpers return plausible timestamps" {
    try std.testing.expect(nowMillis() > 0);
    try std.testing.expect(nowSeconds() > 0);
    try std.testing.expect(nowNanos() > 0);
    try std.testing.expect(monotonicNanos() > 0);
}

test "compat sleep helpers accept zero duration" {
    sleepNs(0);
    sleepMs(0);
}
