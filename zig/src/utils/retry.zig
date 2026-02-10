const std = @import("std");

/// HTTP status codes that are retryable (transient errors)
pub fn isRetryable(status_code: u16) bool {
    return switch (status_code) {
        429, 500, 502, 503, 504 => true,
        else => false,
    };
}

/// Calculate exponential backoff delay in milliseconds.
/// Returns min(base_delay_ms * 2^attempt, max_delay_ms)
pub fn calculateDelay(attempt: u8, base_delay_ms: u32, max_delay_ms: u32) u64 {
    const shift: u6 = @intCast(@min(attempt, 63));
    const exp_delay: u64 = @as(u64, base_delay_ms) *% (@as(u64, 1) << shift);
    return @min(exp_delay, max_delay_ms);
}

/// Extract retry delay from Retry-After header value.
/// Supports integer seconds format. Returns delay in milliseconds, or null.
pub fn extractRetryDelay(header_value: ?[]const u8) ?u64 {
    const value = header_value orelse return null;
    const seconds = std.fmt.parseInt(u64, value, 10) catch return null;
    return seconds * 1000;
}

test "isRetryable identifies retryable status codes" {
    try std.testing.expect(isRetryable(429));
    try std.testing.expect(isRetryable(500));
    try std.testing.expect(isRetryable(502));
    try std.testing.expect(isRetryable(503));
    try std.testing.expect(isRetryable(504));
    try std.testing.expect(!isRetryable(200));
    try std.testing.expect(!isRetryable(400));
    try std.testing.expect(!isRetryable(401));
    try std.testing.expect(!isRetryable(403));
    try std.testing.expect(!isRetryable(404));
    try std.testing.expect(!isRetryable(422));
}

test "calculateDelay exponential backoff" {
    // attempt 0: 1000 * 1 = 1000
    try std.testing.expectEqual(@as(u64, 1000), calculateDelay(0, 1000, 60000));
    // attempt 1: 1000 * 2 = 2000
    try std.testing.expectEqual(@as(u64, 2000), calculateDelay(1, 1000, 60000));
    // attempt 2: 1000 * 4 = 4000
    try std.testing.expectEqual(@as(u64, 4000), calculateDelay(2, 1000, 60000));
    // attempt 3: 1000 * 8 = 8000
    try std.testing.expectEqual(@as(u64, 8000), calculateDelay(3, 1000, 60000));
    // attempt 6: 1000 * 64 = 64000, capped at 60000
    try std.testing.expectEqual(@as(u64, 60000), calculateDelay(6, 1000, 60000));
}

test "calculateDelay custom base" {
    try std.testing.expectEqual(@as(u64, 500), calculateDelay(0, 500, 30000));
    try std.testing.expectEqual(@as(u64, 1000), calculateDelay(1, 500, 30000));
}

test "extractRetryDelay parses integer seconds" {
    try std.testing.expectEqual(@as(?u64, 5000), extractRetryDelay("5"));
    try std.testing.expectEqual(@as(?u64, 30000), extractRetryDelay("30"));
    try std.testing.expectEqual(@as(?u64, 1000), extractRetryDelay("1"));
}

test "extractRetryDelay returns null for invalid input" {
    try std.testing.expectEqual(@as(?u64, null), extractRetryDelay(null));
    try std.testing.expectEqual(@as(?u64, null), extractRetryDelay("not-a-number"));
    try std.testing.expectEqual(@as(?u64, null), extractRetryDelay(""));
}
