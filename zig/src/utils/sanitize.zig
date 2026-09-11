
const std = @import("std");

fn isHighSurrogate(cp: u21) bool {
    return cp >= 0xD800 and cp <= 0xDBFF;
}

fn isLowSurrogate(cp: u21) bool {
    return cp >= 0xDC00 and cp <= 0xDFFF;
}

pub fn sanitizeSurrogates(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len);
    defer result.deinit(allocator);

    var i: usize = 0;
    var prev_was_high_surrogate = false;
    var high_surrogate_start: usize = 0;

    while (i < input.len) {
        const byte = input[i];

        const seq_len: usize = if (byte < 0x80)
            1
        else if (byte < 0xC0)
            1
        else if (byte < 0xE0)
            2
        else if (byte < 0xF0)
            3
        else if (byte < 0xF8)
            4
        else
            1;

        if (i + seq_len > input.len) {
            try result.appendSlice(allocator, input[i..]);
            break;
        }

        const cp = decodeCodepoint(input[i..]) orelse {
            try result.appendSlice(allocator, input[i .. i + 1]);
            i += 1;
            continue;
        };

        if (isHighSurrogate(cp)) {
            prev_was_high_surrogate = true;
            high_surrogate_start = result.items.len;
            try result.appendSlice(allocator, input[i .. i + seq_len]);
            i += seq_len;
        } else if (isLowSurrogate(cp)) {
            if (prev_was_high_surrogate) {
                try result.appendSlice(allocator, input[i .. i + seq_len]);
            }
            prev_was_high_surrogate = false;
            i += seq_len;
        } else {
            if (prev_was_high_surrogate) {
                result.shrinkRetainingCapacity(high_surrogate_start);
            }
            prev_was_high_surrogate = false;

            try result.appendSlice(allocator, input[i .. i + seq_len]);
            i += seq_len;
        }
    }

    if (prev_was_high_surrogate) {
        result.shrinkRetainingCapacity(high_surrogate_start);
    }

    return result.toOwnedSlice(allocator);
}

fn decodeCodepoint(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;

    const byte = bytes[0];

    if (byte < 0x80) {
        return @as(u21, byte);
    } else if (byte < 0xC0) {
        return null;
    } else if (byte < 0xE0) {
        if (bytes.len < 2) return null;
        if ((bytes[1] & 0xC0) != 0x80) return null;
        const cp = (@as(u21, byte & 0x1F) << 6) | (@as(u21, bytes[1] & 0x3F));
        return cp;
    } else if (byte < 0xF0) {
        if (bytes.len < 3) return null;
        if ((bytes[1] & 0xC0) != 0x80) return null;
        if ((bytes[2] & 0xC0) != 0x80) return null;
        const cp = (@as(u21, byte & 0x0F) << 12) | (@as(u21, bytes[1] & 0x3F) << 6) | (@as(u21, bytes[2] & 0x3F));
        return cp;
    } else if (byte < 0xF8) {
        if (bytes.len < 4) return null;
        if ((bytes[1] & 0xC0) != 0x80) return null;
        if ((bytes[2] & 0xC0) != 0x80) return null;
        if ((bytes[3] & 0xC0) != 0x80) return null;
        const cp = (@as(u21, byte & 0x07) << 18) | (@as(u21, bytes[1] & 0x3F) << 12) | (@as(u21, bytes[2] & 0x3F) << 6) | (@as(u21, bytes[3] & 0x3F));
        return cp;
    }

    return null;
}

pub fn needsSanitization(input: []const u8) bool {
    var i: usize = 0;
    var expect_low: bool = false;

    while (i < input.len) {
        const cp = decodeCodepoint(input[i..]) orelse {
            i += 1;
            continue;
        };

        const seq_len = utf8SeqLen(input[i]) orelse 1;

        if (isHighSurrogate(cp)) {
            expect_low = true;
        } else if (isLowSurrogate(cp)) {
            if (!expect_low) {
                return true;
            }
            expect_low = false;
        } else {
            if (expect_low) {
                return true;
            }
        }

        i += seq_len;
    }

    if (expect_low) {
        return true;
    }

    return false;
}

fn utf8SeqLen(byte: u8) ?usize {
    return if (byte < 0x80)
        1
    else if (byte < 0xC0)
        null
    else if (byte < 0xE0)
        2
    else if (byte < 0xF0)
        3
    else if (byte < 0xF8)
        4
    else
        null;
}

pub fn sanitizeSurrogatesInPlace(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (!needsSanitization(text)) {
        return text;
    }

    return sanitizeSurrogates(allocator, text);
}

fn encodeSurrogateUtf8(cp: u21, out: *[3]u8) void {
    out[0] = 0xE0 | @as(u8, @intCast((cp >> 12) & 0x0F));
    out[1] = 0x80 | @as(u8, @intCast((cp >> 6) & 0x3F));
    out[2] = 0x80 | @as(u8, @intCast(cp & 0x3F));
}

test "sanitizeSurrogates removes lone high surrogate" {
    const allocator = std.testing.allocator;

    var input_buf: [10]u8 = undefined;
    var input_len: usize = 0;

    encodeSurrogateUtf8(0xD83D, input_buf[0..3]);
    input_len += 3;

    const text = "text";
    @memcpy(input_buf[input_len..][0..text.len], text);
    input_len += text.len;

    const input = input_buf[0..input_len];

    const result = try sanitizeSurrogates(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, "text", result);
}

test "sanitizeSurrogates removes lone low surrogate" {
    const allocator = std.testing.allocator;

    var input_buf: [10]u8 = undefined;
    var input_len: usize = 0;

    const text = "test";
    @memcpy(input_buf[input_len..][0..text.len], text);
    input_len += text.len;

    encodeSurrogateUtf8(0xDC00, input_buf[input_len..][0..3]);
    input_len += 3;

    const input = input_buf[0..input_len];

    const result = try sanitizeSurrogates(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, "test", result);
}

test "sanitizeSurrogates preserves valid surrogate pairs" {
    const allocator = std.testing.allocator;

    const emoji_utf8 = "\xF0\x9F\x99\x88";

    const input = "Hello " ++ emoji_utf8 ++ " World";

    const result = try sanitizeSurrogates(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, input, result);
}

test "sanitizeSurrogates preserves normal text" {
    const allocator = std.testing.allocator;

    const input = "Hello, World! This is normal text.";

    const result = try sanitizeSurrogates(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, input, result);
}

test "sanitizeSurrogates handles empty string" {
    const allocator = std.testing.allocator;

    const input = "";

    const result = try sanitizeSurrogates(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, "", result);
}

test "sanitizeSurrogates removes multiple unpaired surrogates" {
    const allocator = std.testing.allocator;

    var input_buf: [20]u8 = undefined;
    var input_len: usize = 0;

    input_buf[input_len] = 'a';
    input_len += 1;

    encodeSurrogateUtf8(0xD800, input_buf[input_len..][0..3]);
    input_len += 3;

    input_buf[input_len] = 'b';
    input_len += 1;

    encodeSurrogateUtf8(0xDFFF, input_buf[input_len..][0..3]);
    input_len += 3;

    input_buf[input_len] = 'c';
    input_len += 1;

    const input = input_buf[0..input_len];

    const result = try sanitizeSurrogates(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, "abc", result);
}

test "sanitizeSurrogates handles string ending with high surrogate" {
    const allocator = std.testing.allocator;

    var input_buf: [10]u8 = undefined;
    var input_len: usize = 0;

    const text = "text";
    @memcpy(input_buf[input_len..][0..text.len], text);
    input_len += text.len;

    encodeSurrogateUtf8(0xD83D, input_buf[input_len..][0..3]);
    input_len += 3;

    const input = input_buf[0..input_len];

    const result = try sanitizeSurrogates(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, "text", result);
}

test "sanitizeSurrogates handles mixed valid emoji and lone surrogates" {
    const allocator = std.testing.allocator;

    var input_buf: [30]u8 = undefined;
    var input_len: usize = 0;

    const prefix = "start ";
    @memcpy(input_buf[input_len..][0..prefix.len], prefix);
    input_len += prefix.len;

    const emoji = "\xF0\x9F\x98\x80";
    @memcpy(input_buf[input_len..][0..emoji.len], emoji);
    input_len += emoji.len;

    const mid = " ";
    @memcpy(input_buf[input_len..][0..mid.len], mid);
    input_len += mid.len;

    encodeSurrogateUtf8(0xD83D, input_buf[input_len..][0..3]);
    input_len += 3;

    const suffix = " end";
    @memcpy(input_buf[input_len..][0..suffix.len], suffix);
    input_len += suffix.len;

    const input = input_buf[0..input_len];

    const result = try sanitizeSurrogates(allocator, input);
    defer allocator.free(result);

    const expected = "start " ++ emoji ++ "  end";
    try std.testing.expectEqualSlices(u8, expected, result);
}

test "sanitizeSurrogates preserves valid surrogate pair in ill-formed UTF-8" {
    const allocator = std.testing.allocator;

    var input_buf: [20]u8 = undefined;
    var input_len: usize = 0;

    const prefix = "test ";
    @memcpy(input_buf[input_len..][0..prefix.len], prefix);
    input_len += prefix.len;

    encodeSurrogateUtf8(0xD83D, input_buf[input_len..][0..3]);
    input_len += 3;
    encodeSurrogateUtf8(0xDE48, input_buf[input_len..][0..3]);
    input_len += 3;

    const suffix = " end";
    @memcpy(input_buf[input_len..][0..suffix.len], suffix);
    input_len += suffix.len;

    const input = input_buf[0..input_len];

    const result = try sanitizeSurrogates(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, input, result);
}

test "needsSanitization returns false for clean text" {
    const input = "Hello, World!";
    try std.testing.expect(!needsSanitization(input));
}

test "needsSanitization returns false for valid emoji" {
    const input = "Hello \xF0\x9F\x98\x80 World";
    try std.testing.expect(!needsSanitization(input));
}

test "needsSanitization returns true for lone high surrogate" {
    var buf: [10]u8 = undefined;
    encodeSurrogateUtf8(0xD800, buf[0..3]);
    try std.testing.expect(needsSanitization(buf[0..3]));
}

test "needsSanitization returns true for lone low surrogate" {
    var buf: [10]u8 = undefined;
    encodeSurrogateUtf8(0xDC00, buf[0..3]);
    try std.testing.expect(needsSanitization(buf[0..3]));
}

test "sanitizeSurrogatesInPlace returns original when no sanitization needed" {
    const allocator = std.testing.allocator;

    const input = "Hello, World!";
    const result = try sanitizeSurrogatesInPlace(allocator, input);

    try std.testing.expect(result.ptr == input.ptr);
}

test "sanitizeSurrogatesInPlace allocates when sanitization needed" {
    const allocator = std.testing.allocator;

    var input_buf: [10]u8 = undefined;
    var input_len: usize = 0;

    input_buf[input_len] = 'a';
    input_len += 1;

    encodeSurrogateUtf8(0xD83D, input_buf[input_len..][0..3]);
    input_len += 3;

    input_buf[input_len] = 'b';
    input_len += 1;

    const input = input_buf[0..input_len];

    const result = try sanitizeSurrogatesInPlace(allocator, input);
    defer allocator.free(result);

    try std.testing.expect(result.ptr != input.ptr);
    try std.testing.expectEqualSlices(u8, "ab", result);
}
