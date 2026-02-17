//! Unicode sanitization utilities.
//!
//! Provides functions to sanitize strings by removing invalid Unicode sequences
//! that would cause issues with JSON serialization or API providers.

const std = @import("std");

/// Check if a codepoint is a high surrogate (0xD800-0xDBFF)
fn isHighSurrogate(cp: u21) bool {
    return cp >= 0xD800 and cp <= 0xDBFF;
}

/// Check if a codepoint is a low surrogate (0xDC00-0xDFFF)
fn isLowSurrogate(cp: u21) bool {
    return cp >= 0xDC00 and cp <= 0xDFFF;
}

/// Remove unpaired Unicode surrogate characters from a UTF-8 string.
///
/// Unpaired surrogates (high surrogates 0xD800-0xDBFF without matching low surrogates
/// 0xDC00-0xDFFF, or vice versa) cause JSON serialization errors in many API providers.
///
/// Valid surrogate pairs (used for characters outside the Basic Multilingual Plane,
/// like emoji) will be preserved.
///
/// This function handles the case where ill-formed UTF-8 containing surrogate codepoints
/// (encoded as 3-byte sequences: 0xED 0xA0 0x80 - 0xED 0xBF 0xBF) has somehow made it
/// into the input string.
///
/// Returns a newly allocated string with unpaired surrogates removed.
pub fn sanitizeSurrogates(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len);
    defer result.deinit(allocator);

    // We need to iterate byte-by-byte to handle potentially invalid UTF-8
    // containing surrogate codepoints encoded as 3-byte sequences
    var i: usize = 0;
    var prev_was_high_surrogate = false;
    var high_surrogate_start: usize = 0;

    while (i < input.len) {
        const byte = input[i];

        // Determine the sequence length based on the first byte
        const seq_len: usize = if (byte < 0x80)
            1
        else if (byte < 0xC0)
            1 // Invalid continuation byte, treat as single byte
        else if (byte < 0xE0)
            2
        else if (byte < 0xF0)
            3
        else if (byte < 0xF8)
            4
        else
            1; // Invalid, treat as single byte

        // Check if we have enough bytes
        if (i + seq_len > input.len) {
            // Not enough bytes, copy remaining and exit
            try result.appendSlice(allocator, input[i..]);
            break;
        }

        // Try to decode the codepoint
        const cp = decodeCodepoint(input[i..]) orelse {
            // Invalid sequence, copy as-is and continue
            try result.appendSlice(allocator, input[i .. i + 1]);
            i += 1;
            continue;
        };

        if (isHighSurrogate(cp)) {
            // Mark the start position of this high surrogate
            prev_was_high_surrogate = true;
            high_surrogate_start = result.items.len;
            // Emit the high surrogate bytes for now
            try result.appendSlice(allocator, input[i .. i + seq_len]);
            i += seq_len;
        } else if (isLowSurrogate(cp)) {
            if (prev_was_high_surrogate) {
                // This is a valid surrogate pair - emit the low surrogate
                try result.appendSlice(allocator, input[i .. i + seq_len]);
            }
            // If no preceding high surrogate, skip this lone low surrogate
            prev_was_high_surrogate = false;
            i += seq_len;
        } else {
            // Regular codepoint - if previous was a lone high surrogate, remove it
            if (prev_was_high_surrogate) {
                // Remove the last emitted high surrogate
                result.shrinkRetainingCapacity(high_surrogate_start);
            }
            prev_was_high_surrogate = false;

            // Emit this regular codepoint
            try result.appendSlice(allocator, input[i .. i + seq_len]);
            i += seq_len;
        }
    }

    // Handle case where string ends with a lone high surrogate
    if (prev_was_high_surrogate) {
        result.shrinkRetainingCapacity(high_surrogate_start);
    }

    return result.toOwnedSlice(allocator);
}

/// Decode a UTF-8 codepoint from the beginning of a byte slice.
/// Returns null if the sequence is invalid.
fn decodeCodepoint(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;

    const byte = bytes[0];

    if (byte < 0x80) {
        return @as(u21, byte);
    } else if (byte < 0xC0) {
        // Invalid: continuation byte at start
        return null;
    } else if (byte < 0xE0) {
        // 2-byte sequence
        if (bytes.len < 2) return null;
        if ((bytes[1] & 0xC0) != 0x80) return null;
        const cp = (@as(u21, byte & 0x1F) << 6) | (@as(u21, bytes[1] & 0x3F));
        return cp;
    } else if (byte < 0xF0) {
        // 3-byte sequence
        if (bytes.len < 3) return null;
        if ((bytes[1] & 0xC0) != 0x80) return null;
        if ((bytes[2] & 0xC0) != 0x80) return null;
        const cp = (@as(u21, byte & 0x0F) << 12) | (@as(u21, bytes[1] & 0x3F) << 6) | (@as(u21, bytes[2] & 0x3F));
        return cp;
    } else if (byte < 0xF8) {
        // 4-byte sequence
        if (bytes.len < 4) return null;
        if ((bytes[1] & 0xC0) != 0x80) return null;
        if ((bytes[2] & 0xC0) != 0x80) return null;
        if ((bytes[3] & 0xC0) != 0x80) return null;
        const cp = (@as(u21, byte & 0x07) << 18) | (@as(u21, bytes[1] & 0x3F) << 12) | (@as(u21, bytes[2] & 0x3F) << 6) | (@as(u21, bytes[3] & 0x3F));
        return cp;
    }

    return null;
}

/// Encode a surrogate codepoint (0xD800-0xDFFF) as UTF-8 bytes.
/// Surrogates are encoded as 3-byte sequences: 0xED 0xA0 0x80 - 0xED 0xBF 0xBF
fn encodeSurrogateUtf8(cp: u21, out: *[3]u8) void {
    // Surrogates are in range 0xD800-0xDFFF
    // UTF-8 encoding for 3-byte sequence:
    // 1110xxxx 10xxxxxx 10xxxxxx
    // For surrogates: bits are D800 = 1101 1000 0000 0000
    out[0] = 0xE0 | @as(u8, @intCast((cp >> 12) & 0x0F));
    out[1] = 0x80 | @as(u8, @intCast((cp >> 6) & 0x3F));
    out[2] = 0x80 | @as(u8, @intCast(cp & 0x3F));
}

test "sanitizeSurrogates removes lone high surrogate" {
    const allocator = std.testing.allocator;

    // Create a string with a lone high surrogate (0xD83D) encoded as invalid UTF-8
    // 0xD83D = 1101 1000 0011 1101
    // UTF-8: 0xED 0xA0 0xBD
    var input_buf: [10]u8 = undefined;
    var input_len: usize = 0;

    // Encode lone high surrogate
    encodeSurrogateUtf8(0xD83D, input_buf[0..3]);
    input_len += 3;

    // Append "text" after the surrogate
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

    // Create a string with a lone low surrogate (0xDC00)
    // 0xDC00 = 1101 1100 0000 0000
    // UTF-8: 0xED 0xB0 0x80
    var input_buf: [10]u8 = undefined;
    var input_len: usize = 0;

    const text = "test";
    @memcpy(input_buf[input_len..][0..text.len], text);
    input_len += text.len;

    // Append lone low surrogate
    encodeSurrogateUtf8(0xDC00, input_buf[input_len..][0..3]);
    input_len += 3;

    const input = input_buf[0..input_len];

    const result = try sanitizeSurrogates(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, "test", result);
}

test "sanitizeSurrogates preserves valid surrogate pairs" {
    const allocator = std.testing.allocator;

    // Emoji is a valid surrogate pair: 0xD83D 0xDE48 (monkey face)
    // But in valid UTF-8, this is encoded as a single 4-byte sequence
    // 0xF0 0x9F 0x99 0x88
    const emoji_utf8 = "\xF0\x9F\x99\x88"; // Monkey face emoji

    const input = "Hello " ++ emoji_utf8 ++ " World";

    const result = try sanitizeSurrogates(allocator, input);
    defer allocator.free(result);

    // The valid emoji (encoded properly as 4-byte UTF-8) should be preserved
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

    // Build a string: "a" + lone_high + "b" + lone_low + "c"
    var input_buf: [20]u8 = undefined;
    var input_len: usize = 0;

    input_buf[input_len] = 'a';
    input_len += 1;

    // Lone high surrogate (0xD800)
    encodeSurrogateUtf8(0xD800, input_buf[input_len..][0..3]);
    input_len += 3;

    input_buf[input_len] = 'b';
    input_len += 1;

    // Lone low surrogate (0xDFFF)
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

    // Build: "text" + lone_high
    var input_buf: [10]u8 = undefined;
    var input_len: usize = 0;

    const text = "text";
    @memcpy(input_buf[input_len..][0..text.len], text);
    input_len += text.len;

    // Lone high surrogate (0xD83D)
    encodeSurrogateUtf8(0xD83D, input_buf[input_len..][0..3]);
    input_len += 3;

    const input = input_buf[0..input_len];

    const result = try sanitizeSurrogates(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, "text", result);
}

test "sanitizeSurrogates handles mixed valid emoji and lone surrogates" {
    const allocator = std.testing.allocator;

    // Build: "start " + emoji (valid 4-byte) + " " + lone_high + " end"
    var input_buf: [30]u8 = undefined;
    var input_len: usize = 0;

    const prefix = "start ";
    @memcpy(input_buf[input_len..][0..prefix.len], prefix);
    input_len += prefix.len;

    // Valid emoji (4-byte UTF-8, not surrogate pair)
    const emoji = "\xF0\x9F\x98\x80"; // Grinning face emoji
    @memcpy(input_buf[input_len..][0..emoji.len], emoji);
    input_len += emoji.len;

    const mid = " ";
    @memcpy(input_buf[input_len..][0..mid.len], mid);
    input_len += mid.len;

    // Lone high surrogate (0xD83D)
    encodeSurrogateUtf8(0xD83D, input_buf[input_len..][0..3]);
    input_len += 3;

    const suffix = " end";
    @memcpy(input_buf[input_len..][0..suffix.len], suffix);
    input_len += suffix.len;

    const input = input_buf[0..input_len];

    const result = try sanitizeSurrogates(allocator, input);
    defer allocator.free(result);

    // Expected: "start " + emoji + " " + " end" (lone high removed)
    const expected = "start " ++ emoji ++ "  end";
    try std.testing.expectEqualSlices(u8, expected, result);
}

test "sanitizeSurrogates preserves valid surrogate pair in ill-formed UTF-8" {
    const allocator = std.testing.allocator;

    // This test handles the rare case where valid surrogate pairs are
    // encoded as two separate 3-byte sequences (ill-formed UTF-8, but
    // sometimes occurs when UTF-16 is naively transcoded to UTF-8)
    var input_buf: [20]u8 = undefined;
    var input_len: usize = 0;

    const prefix = "test ";
    @memcpy(input_buf[input_len..][0..prefix.len], prefix);
    input_len += prefix.len;

    // Valid surrogate pair: 0xD83D 0xDE48 (monkey face emoji)
    // Encoded as two 3-byte sequences
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

    // The valid surrogate pair (even in ill-formed UTF-8) should be preserved
    // Result should be: "test " + [3 bytes high] + [3 bytes low] + " end"
    try std.testing.expectEqualSlices(u8, input, result);
}
