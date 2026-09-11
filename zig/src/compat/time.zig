const std = @import("std");

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

pub fn nowMillis() i64 {
    return std.Io.Timestamp.now(defaultIo(), .real).toMilliseconds();
}

pub fn nowSeconds() i64 {
    return std.Io.Timestamp.now(defaultIo(), .real).toSeconds();
}

pub fn nowNanos() i64 {
    return @intCast(std.Io.Timestamp.now(defaultIo(), .real).toNanoseconds());
}

var monotonic_origin: ?std.Io.Timestamp = null;
var monotonic_mutex: std.Io.Mutex = .init;

pub fn monotonicNanos() !u64 {
    monotonic_mutex.lockUncancelable(defaultIo());
    defer monotonic_mutex.unlock(defaultIo());

    const now = std.Io.Timestamp.now(defaultIo(), .boot);
    if (monotonic_origin == null) {
        monotonic_origin = now;
    }

    return @intCast(monotonic_origin.?.durationTo(now).nanoseconds);
}

pub fn monotonicMillis() !i64 {
    return @intCast(try monotonicNanos() / std.time.ns_per_ms);
}

pub fn sleepNs(ns: u64) void {
    const capped_ns = @min(ns, @as(u64, std.math.maxInt(i64)));
    defaultIo().sleep(.fromNanoseconds(@intCast(capped_ns)), .boot) catch {};
}

pub fn sleepMs(ms: u64) void {
    sleepNs(std.math.mul(u64, ms, std.time.ns_per_ms) catch std.math.maxInt(u64));
}

test "compat time helpers return expected public types" {
    const millis: i64 = nowMillis();
    const seconds: i64 = nowSeconds();
    const nanos: i64 = nowNanos();
    const monotonic: u64 = try monotonicNanos();
    const monotonic_ms: i64 = try monotonicMillis();

    _ = millis;
    _ = seconds;
    _ = nanos;
    _ = monotonic;
    _ = monotonic_ms;
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

    try std.testing.expect(elapsed_ns >= 1 * std.time.ns_per_ms);
}

test "compat sleep helpers accept zero duration" {
    sleepNs(0);
    sleepMs(0);
}
