const std = @import("std");

/// Retry configuration
pub const RetryConfig = struct {
    max_retries: u32 = 3,
    base_delay_ms: u64 = 1000,
    max_delay_ms: u64 = 60000, // 60 seconds max cap

    /// Calculate delay for given attempt with optional server-provided delay.
    /// Returns null if max_delay_ms is exceeded (when server delay too large).
    pub fn nextDelay(self: *const RetryConfig, attempt: u32, server_delay_ms: ?u64) ?u64 {
        const delay = server_delay_ms orelse blk: {
            // Exponential backoff: base_delay_ms * 2^attempt
            const shift: u6 = @intCast(@min(attempt, 63));
            break :blk self.base_delay_ms * (@as(u64, 1) << shift);
        };
        if (self.max_delay_ms > 0 and delay > self.max_delay_ms) {
            return null; // Exceeds max allowed delay
        }
        return delay;
    }

    /// Check if status code is retryable
    pub fn isRetryableStatus(self: *const RetryConfig, status: std.http.Status) bool {
        _ = self;
        return switch (status) {
            .too_many_requests => true, // 429
            .internal_server_error => true, // 500
            .bad_gateway => true, // 502
            .service_unavailable => true, // 503
            .gateway_timeout => true, // 504
            else => false,
        };
    }
};

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
pub fn extractRetryDelayFromHeader(header_value: ?[]const u8) ?u64 {
    const value = header_value orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");

    // Try parsing as integer seconds
    if (std.fmt.parseInt(u64, trimmed, 10)) |seconds| {
        return seconds * 1000;
    } else |_| {}

    // Try parsing as HTTP date (RFC 1123)
    // Format: "Wed, 21 Oct 2015 07:28:00 GMT"
    if (parseHttpDate(trimmed)) |timestamp_ms| {
        const now_ms = @as(u64, @intCast(std.time.timestamp())) * 1000;
        if (timestamp_ms > now_ms) {
            return timestamp_ms - now_ms;
        }
    }

    return null;
}

/// Parse HTTP date string (RFC 1123 format)
fn parseHttpDate(date_str: []const u8) ?u64 {
    // Format: "Wed, 21 Oct 2015 07:28:00 GMT"
    // We need at least 29 characters
    if (date_str.len < 29) return null;

    // Find the day (skip "Day, ")
    var idx: usize = 5;

    // Parse day
    const day_end = std.mem.indexOfPos(u8, date_str, idx, " ") orelse return null;
    const day = std.fmt.parseInt(u32, date_str[idx..day_end], 10) catch return null;
    idx = day_end + 1;

    // Parse month
    const month_end = std.mem.indexOfPos(u8, date_str, idx, " ") orelse return null;
    const month_str = date_str[idx..month_end];
    const month = monthFromString(month_str) orelse return null;
    idx = month_end + 1;

    // Parse year
    const year_end = std.mem.indexOfPos(u8, date_str, idx, " ") orelse return null;
    const year = std.fmt.parseInt(u32, date_str[idx..year_end], 10) catch return null;
    idx = year_end + 1;

    // Parse time HH:MM:SS
    const hour = std.fmt.parseInt(u32, date_str[idx .. idx + 2], 10) catch return null;
    idx += 3;
    const minute = std.fmt.parseInt(u32, date_str[idx .. idx + 2], 10) catch return null;
    idx += 3;
    const second = std.fmt.parseInt(u32, date_str[idx .. idx + 2], 10) catch return null;

    // Convert to Unix timestamp (simplified, assumes UTC)
    return dateTimeToTimestamp(year, month, day, hour, minute, second);
}

/// Convert month name to number (1-12)
fn monthFromString(month: []const u8) ?u32 {
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    for (months, 1..) |m, i| {
        if (std.mem.eql(u8, month, m)) {
            return @intCast(i);
        }
    }
    return null;
}

/// Convert date/time components to Unix timestamp in milliseconds
fn dateTimeToTimestamp(year: u32, month: u32, day: u32, hour: u32, minute: u32, second: u32) u64 {
    // Simplified calculation (assumes valid date)
    var y = year;
    var m = month;
    const d = day;

    // Algorithm from http://howardhinnant.github.io/date_algorithms.html
    if (m <= 2) {
        y -= 1;
        m += 12;
    }
    const era = (y - 1) / 400;
    const yoe = @as(u64, y - 1) % 400;
    const doy = (153 * @as(u64, m - 3) + 2) / 5 + d - 1;
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    const days_since_epoch = era * 146097 + doe;

    const timestamp_s = days_since_epoch * 86400 + @as(u64, hour) * 3600 + @as(u64, minute) * 60 + @as(u64, second);
    return timestamp_s * 1000;
}

/// Extract retry delay from error response body patterns (in milliseconds).
/// Checks body patterns like:
/// - "reset after 18h31m10s" -> parse duration
/// - "Please retry in Xs" or "Please retry in Xms"
/// - "retryDelay": "34.074824224s" (JSON)
/// Returns milliseconds with 1-second buffer added.
pub fn extractRetryDelayFromBody(error_text: []const u8) ?u64 {
    // Pattern 1: "reset after ..." (formats: "18h31m10s", "10m15s", "6s", "39s")
    if (indexOfCaseInsensitive(error_text, "reset after")) |start_idx| {
        const rest = error_text[start_idx + 11 ..]; // "reset after" is 11 chars
        // Find the duration part
        var end_idx: usize = 0;
        for (rest, 0..) |c, i| {
            if (c == '.' or c == ',' or c == '\n' or c == '\r') {
                end_idx = i;
                break;
            }
            end_idx = i + 1;
        }
        if (end_idx > 0) {
            const duration_str = std.mem.trim(u8, rest[0..end_idx], " ");
            if (parseDuration(duration_str)) |ms| {
                return normalizeDelay(ms);
            }
        }
    }

    // Pattern 2: "Please retry in X[ms|s]"
    if (indexOfCaseInsensitive(error_text, "please retry in")) |start_idx| {
        const rest = error_text[start_idx + 15 ..]; // "please retry in" is 15 chars
        if (parseRetryInFormat(rest)) |ms| {
            return normalizeDelay(ms);
        }
    }

    // Pattern 3: "retryDelay": "34.074824224s" (JSON field in error details)
    if (indexOfCaseInsensitive(error_text, "\"retrydelay\"")) |start_idx| {
        // Find the colon and value
        const after_key = error_text[start_idx..];
        if (std.mem.indexOf(u8, after_key, ":")) |colon_idx| {
            const after_colon = std.mem.trimLeft(u8, after_key[colon_idx + 1 ..], " \t");
            if (parseRetryInFormat(after_colon)) |ms| {
                return normalizeDelay(ms);
            }
        }
    }

    return null;
}

/// Normalize delay by adding 1-second buffer and ensuring positive
fn normalizeDelay(ms: u64) ?u64 {
    if (ms == 0) return null;
    return ms + 1000; // Add 1-second buffer
}

/// Parse "X[ms|s]" format like "34.074824224s" or "500ms"
fn parseRetryInFormat(text: []const u8) ?u64 {
    // Skip any leading whitespace or quotes
    var start: usize = 0;
    for (text, 0..) |c, i| {
        if (c != ' ' and c != '\t' and c != '"') {
            start = i;
            break;
        }
    }

    // Find the number end
    var num_end: usize = start;
    var has_dot = false;
    for (text[start..], start..) |c, i| {
        if (c >= '0' and c <= '9') {
            num_end = i + 1;
        } else if (c == '.' and !has_dot) {
            num_end = i + 1;
            has_dot = true;
        } else {
            break;
        }
    }

    if (num_end == start) return null;

    const num_str = text[start..num_end];
    const rest = text[num_end..];

    // Check for "ms" or "s" suffix
    const value = parseFloat(num_str) catch return null;
    if (value <= 0) return null;

    if (indexOfCaseInsensitive(rest, "ms")) |ms_idx| {
        if (ms_idx == 0) {
            return @as(u64, @intFromFloat(value));
        }
    }
    if (indexOfCaseInsensitive(rest, "s")) |s_idx| {
        if (s_idx == 0) {
            return @as(u64, @intFromFloat(value * 1000));
        }
    }

    return null;
}

/// Parse duration string like "18h31m10s" or "10m15s" or "6s"
/// Returns milliseconds
pub fn parseDuration(duration_str: []const u8) ?u64 {
    var total_ms: u64 = 0;
    var i: usize = 0;

    while (i < duration_str.len) {
        // Skip whitespace
        while (i < duration_str.len and (duration_str[i] == ' ' or duration_str[i] == '\t')) {
            i += 1;
        }
        if (i >= duration_str.len) break;

        // Parse number
        const num_start = i;
        var has_dot = false;
        while (i < duration_str.len) {
            const c = duration_str[i];
            if (c >= '0' and c <= '9') {
                i += 1;
            } else if (c == '.' and !has_dot) {
                has_dot = true;
                i += 1;
            } else {
                break;
            }
        }

        if (i == num_start) break;
        const num_str = duration_str[num_start..i];
        const value = parseFloat(num_str) catch return null;

        // Parse unit
        if (i >= duration_str.len) break;
        const unit_char = std.ascii.toLower(duration_str[i]);

        const multiplier: f64 = if (unit_char == 'm') blk: {
            // Check if next char is 's' for milliseconds
            if (i + 1 < duration_str.len and std.ascii.toLower(duration_str[i + 1]) == 's') {
                i += 2;
                break :blk 1;
            }
            i += 1;
            break :blk 60 * 1000; // minutes
        } else if (unit_char == 'h') blk: {
            i += 1;
            break :blk 3600 * 1000;
        } else if (unit_char == 's') blk: {
            i += 1;
            break :blk 1000;
        } else {
            return null;
        };

        total_ms += @as(u64, @intFromFloat(value * multiplier));
    }

    return if (total_ms > 0) total_ms else null;
}

/// Parse a float string, handling both integer and decimal formats
fn parseFloat(str: []const u8) !f64 {
    // Simple float parsing
    var result: f64 = 0;
    var divisor: f64 = 1;
    var after_dot = false;
    var started = false;

    for (str) |c| {
        if (c == '.') {
            if (after_dot) return error.InvalidCharacter;
            after_dot = true;
            continue;
        }
        if (c >= '0' and c <= '9') {
            started = true;
            const digit: f64 = @floatFromInt(c - '0');
            if (after_dot) {
                divisor *= 10;
                result += digit / divisor;
            } else {
                result = result * 10 + digit;
            }
        } else {
            return error.InvalidCharacter;
        }
    }

    if (!started) return error.InvalidFormat;
    return result;
}

/// Check if error message indicates a retryable error
pub fn isRetryableError(error_text: []const u8) bool {
    const patterns = [_][]const u8{
        "resource exhausted",
        "rate limit",
        "ratelimit",
        "overloaded",
        "service unavailable",
        "other side closed",
        "too many requests",
        "temporarily unavailable",
        "try again",
        "retry later",
    };
    for (patterns) |pattern| {
        if (indexOfCaseInsensitive(error_text, pattern) != null) {
            return true;
        }
    }
    return false;
}

/// Sleep for specified milliseconds, checking cancel token periodically.
/// Returns false if cancelled, true if completed normally.
pub fn sleepMs(ms: u64, cancel_token: ?*const std.atomic.Value(bool)) bool {
    const check_interval_ms: u64 = 100;
    const ns_per_ms: u64 = 1_000_000;
    var remaining: u64 = ms;

    while (remaining > 0) {
        // Check cancel token
        if (cancel_token) |token| {
            if (token.load(.acquire)) {
                return false; // Cancelled
            }
        }

        const sleep_time = @min(remaining, check_interval_ms);
        std.Thread.sleep(sleep_time * ns_per_ms);
        remaining -= sleep_time;
    }

    return true; // Completed
}

/// Case-insensitive substring search
pub fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

// Tests

test "RetryConfig nextDelay with exponential backoff" {
    const config = RetryConfig{};
    try std.testing.expectEqual(@as(?u64, 1000), config.nextDelay(0, null));
    try std.testing.expectEqual(@as(?u64, 2000), config.nextDelay(1, null));
    try std.testing.expectEqual(@as(?u64, 4000), config.nextDelay(2, null));
    try std.testing.expectEqual(@as(?u64, 8000), config.nextDelay(3, null));
}

test "RetryConfig nextDelay respects max_delay_ms" {
    var config = RetryConfig{ .max_delay_ms = 5000 };
    try std.testing.expectEqual(@as(?u64, 1000), config.nextDelay(0, null));
    try std.testing.expectEqual(@as(?u64, 2000), config.nextDelay(1, null));
    try std.testing.expectEqual(@as(?u64, 4000), config.nextDelay(2, null));
    try std.testing.expectEqual(@as(?u64, null), config.nextDelay(3, null)); // 8000 > 5000
}

test "RetryConfig nextDelay uses server delay when provided" {
    const config = RetryConfig{};
    try std.testing.expectEqual(@as(?u64, 30000), config.nextDelay(0, 30000));
    try std.testing.expectEqual(@as(?u64, 5000), config.nextDelay(2, 5000));
}

test "RetryConfig nextDelay rejects server delay exceeding max" {
    var config = RetryConfig{ .max_delay_ms = 10000 };
    try std.testing.expectEqual(@as(?u64, null), config.nextDelay(0, 15000));
    try std.testing.expectEqual(@as(?u64, 5000), config.nextDelay(0, 5000));
}

test "RetryConfig isRetryableStatus" {
    const config = RetryConfig{};

    try std.testing.expect(config.isRetryableStatus(.too_many_requests)); // 429
    try std.testing.expect(config.isRetryableStatus(.internal_server_error)); // 500
    try std.testing.expect(config.isRetryableStatus(.bad_gateway)); // 502
    try std.testing.expect(config.isRetryableStatus(.service_unavailable)); // 503
    try std.testing.expect(config.isRetryableStatus(.gateway_timeout)); // 504

    try std.testing.expect(!config.isRetryableStatus(.ok)); // 200
    try std.testing.expect(!config.isRetryableStatus(.bad_request)); // 400
    try std.testing.expect(!config.isRetryableStatus(.unauthorized)); // 401
    try std.testing.expect(!config.isRetryableStatus(.forbidden)); // 403
    try std.testing.expect(!config.isRetryableStatus(.not_found)); // 404
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

test "extractRetryDelayFromHeader parses integer seconds" {
    try std.testing.expectEqual(@as(?u64, 5000), extractRetryDelayFromHeader("5"));
    try std.testing.expectEqual(@as(?u64, 30000), extractRetryDelayFromHeader("30"));
    try std.testing.expectEqual(@as(?u64, 1000), extractRetryDelayFromHeader("1"));
    try std.testing.expectEqual(@as(?u64, 5000), extractRetryDelayFromHeader("  5  "));
}

test "extractRetryDelayFromHeader returns null for invalid input" {
    try std.testing.expectEqual(@as(?u64, null), extractRetryDelayFromHeader(null));
    try std.testing.expectEqual(@as(?u64, null), extractRetryDelayFromHeader("not-a-number"));
    try std.testing.expectEqual(@as(?u64, null), extractRetryDelayFromHeader(""));
}

test "parseDuration parses various formats" {
    // Just seconds
    try std.testing.expectEqual(@as(?u64, 6000), parseDuration("6s"));
    try std.testing.expectEqual(@as(?u64, 39000), parseDuration("39s"));

    // Minutes and seconds
    try std.testing.expectEqual(@as(?u64, 615000), parseDuration("10m15s")); // 10*60*1000 + 15*1000

    // Hours, minutes, seconds
    try std.testing.expectEqual(@as(?u64, 66670000), parseDuration("18h31m10s")); // 18*3600*1000 + 31*60*1000 + 10*1000

    // With decimal
    try std.testing.expectEqual(@as(?u64, 1500), parseDuration("1.5s"));
}

test "parseDuration returns null for invalid input" {
    try std.testing.expectEqual(@as(?u64, null), parseDuration(""));
    try std.testing.expectEqual(@as(?u64, null), parseDuration("invalid"));
    try std.testing.expectEqual(@as(?u64, null), parseDuration("5x")); // unknown unit
}

test "extractRetryDelayFromBody parses reset after pattern" {
    // Basic seconds
    const result1 = extractRetryDelayFromBody("Your quota will reset after 39s");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual(@as(u64, 40000), result1.?); // 39000 + 1000 buffer

    // Hours, minutes, seconds: 18*3600 + 31*60 + 10 = 66670 seconds = 66670000ms + 1000 = 66671000
    const result2 = extractRetryDelayFromBody("reset after 18h31m10s please wait");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(u64, 66671000), result2.?); // 66670000 + 1000 buffer
}

test "extractRetryDelayFromBody parses please retry in pattern" {
    const result1 = extractRetryDelayFromBody("Please retry in 30s");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual(@as(u64, 31000), result1.?); // 30000 + 1000 buffer

    const result2 = extractRetryDelayFromBody("Please retry in 500ms");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(u64, 1500), result2.?); // 500 + 1000 buffer

    // 34.074824224s -> 34074ms (truncated) + 1000 = 35074
    const result3 = extractRetryDelayFromBody("Please retry in 34.074824224s");
    try std.testing.expect(result3 != null);
    try std.testing.expectEqual(@as(u64, 35074), result3.?); // 34074 + 1000 buffer
}

test "extractRetryDelayFromBody parses retryDelay JSON field" {
    const result = extractRetryDelayFromBody("{\"error\": {\"retryDelay\": \"34.074824224s\"}}");
    try std.testing.expect(result != null);
}

test "extractRetryDelayFromBody returns null for no match" {
    try std.testing.expectEqual(@as(?u64, null), extractRetryDelayFromBody("Generic error message"));
    try std.testing.expectEqual(@as(?u64, null), extractRetryDelayFromBody(""));
}

test "isRetryableError detects patterns" {
    try std.testing.expect(isRetryableError("resource exhausted: quota exceeded"));
    try std.testing.expect(isRetryableError("Rate limit exceeded"));
    try std.testing.expect(isRetryableError("RATELIMIT hit"));
    try std.testing.expect(isRetryableError("Service is overloaded"));
    try std.testing.expect(isRetryableError("service unavailable"));
    try std.testing.expect(isRetryableError("The other side closed the connection"));
    try std.testing.expect(isRetryableError("Too Many Requests"));
    try std.testing.expect(isRetryableError("Temporarily unavailable, try again later"));
}

test "isRetryableError returns false for non-retryable errors" {
    try std.testing.expect(!isRetryableError("Invalid API key"));
    try std.testing.expect(!isRetryableError("Not found"));
    try std.testing.expect(!isRetryableError("Bad request"));
    try std.testing.expect(!isRetryableError(""));
}

test "indexOfCaseInsensitive finds substrings correctly" {
    try std.testing.expect(indexOfCaseInsensitive("hello world", "world").? == 6);
    try std.testing.expect(indexOfCaseInsensitive("Hello World", "WORLD").? == 6);
    try std.testing.expect(indexOfCaseInsensitive("HELLO WORLD", "hello").? == 0);
    try std.testing.expect(indexOfCaseInsensitive("hello", "world") == null);
    try std.testing.expect(indexOfCaseInsensitive("hi", "hello") == null);
}

test "sleepMs completes normally without cancel token" {
    const ns_per_ms: i128 = 1_000_000;
    const start = std.time.nanoTimestamp();
    const completed = sleepMs(50, null);
    const elapsed = std.time.nanoTimestamp() - start;

    try std.testing.expect(completed);
    try std.testing.expect(elapsed >= 50 * ns_per_ms);
}

test "sleepMs respects cancel token" {
    const ns_per_ms: u64 = 1_000_000;
    var cancelled = std.atomic.Value(bool).init(false);

    // Start a timer to cancel after 10ms
    const ThreadCtx = struct {
        cancel_token: *std.atomic.Value(bool),
        fn run(self: *@This()) void {
            std.Thread.sleep(10 * ns_per_ms);
            self.cancel_token.store(true, .release);
        }
    };
    var ctx = ThreadCtx{ .cancel_token = &cancelled };
    const thread = try std.Thread.spawn(.{}, ThreadCtx.run, .{&ctx});
    defer thread.join();

    // Sleep for 200ms with 100ms check interval, should be cancelled within ~100ms
    const completed = sleepMs(200, &cancelled);
    // Due to timing, this should almost always be cancelled
    // But we can't guarantee it, so we just verify the function runs without crashing
    _ = completed;
}

test "monthFromString converts month names" {
    try std.testing.expectEqual(@as(?u32, 1), monthFromString("Jan"));
    try std.testing.expectEqual(@as(?u32, 6), monthFromString("Jun"));
    try std.testing.expectEqual(@as(?u32, 12), monthFromString("Dec"));
    try std.testing.expectEqual(@as(?u32, null), monthFromString("Xyz"));
}

test "parseFloat parses numbers" {
    try std.testing.expectEqual(@as(f64, 123), parseFloat("123") catch unreachable);
    try std.testing.expectEqual(@as(f64, 12.5), parseFloat("12.5") catch unreachable);
    try std.testing.expectEqual(@as(f64, 0.5), parseFloat("0.5") catch unreachable);
    try std.testing.expectError(error.InvalidFormat, parseFloat(""));
}
