const std = @import("std");

/// PKCE pair containing verifier and challenge
pub const PKCEPair = struct {
    verifier: [43]u8, // 32 bytes -> 43 base64url chars
    challenge: [43]u8, // SHA-256 hash -> 43 base64url chars
};

/// Generate a PKCE verifier and challenge pair.
/// Uses crypto.random for secure random bytes.
pub fn generatePKCE() PKCEPair {
    // 1. Generate 32 random bytes
    var random_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    // 2. Base64URL encode -> verifier (43 chars)
    var verifier: [43]u8 = undefined;
    const verifier_len = base64URLEncode(&random_bytes, &verifier);
    std.debug.assert(verifier_len == 43);

    // 3. SHA-256 hash the verifier
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&verifier, &hash, .{});

    // 4. Base64URL encode the hash -> challenge (43 chars)
    var challenge: [43]u8 = undefined;
    const challenge_len = base64URLEncode(&hash, &challenge);
    std.debug.assert(challenge_len == 43);

    return .{
        .verifier = verifier,
        .challenge = challenge,
    };
}

/// Base64URL encode without padding
/// Returns the number of bytes written to output.
/// Output buffer must be large enough (calc: (input.len * 4 + 2) / 3)
fn base64URLEncode(input: []const u8, output: []u8) usize {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded_len = encoder.calcSize(input.len);
    std.debug.assert(output.len >= encoded_len);
    _ = encoder.encode(output[0..encoded_len], input);
    return encoded_len;
}

test "generatePKCE produces valid pair" {
    const pair = generatePKCE();

    // Verifier should be 43 chars
    try std.testing.expectEqual(@as(usize, 43), pair.verifier.len);
    // Challenge should be 43 chars
    try std.testing.expectEqual(@as(usize, 43), pair.challenge.len);
    // They should be different
    try std.testing.expect(!std.mem.eql(u8, &pair.verifier, &pair.challenge));

    // Should not contain standard base64 characters
    for (pair.verifier) |c| {
        try std.testing.expect(c != '+');
        try std.testing.expect(c != '/');
        try std.testing.expect(c != '=');
    }
    for (pair.challenge) |c| {
        try std.testing.expect(c != '+');
        try std.testing.expect(c != '/');
        try std.testing.expect(c != '=');
    }
}

test "generatePKCE creates unique verifiers" {
    const pair1 = generatePKCE();
    const pair2 = generatePKCE();

    // Should be different
    try std.testing.expect(!std.mem.eql(u8, &pair1.verifier, &pair2.verifier));
    try std.testing.expect(!std.mem.eql(u8, &pair1.challenge, &pair2.challenge));
}

test "base64URLEncode produces correct output" {
    // Test known inputs/outputs
    const test_cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "hello world", .expected = "aGVsbG8gd29ybGQ" },
        .{ .input = "\x00\x00\x00", .expected = "AAAA" },
        .{ .input = "\xff\xff\xff", .expected = "____" },
        .{ .input = "any carnal pleasure.", .expected = "YW55IGNhcm5hbCBwbGVhc3VyZS4" },
    };

    for (test_cases) |tc| {
        var buffer: [64]u8 = undefined;
        const len = base64URLEncode(tc.input, &buffer);
        try std.testing.expectEqualStrings(tc.expected, buffer[0..len]);
    }
}

test "base64URLEncode 32 bytes produces 43 chars" {
    // 32 bytes base64url encoded = 43 characters (no padding)
    var input: [32]u8 = undefined;
    for (&input, 0..) |*b, i| {
        b.* = @intCast(i);
    }

    var output: [64]u8 = undefined;
    const len = base64URLEncode(&input, &output);
    try std.testing.expectEqual(@as(usize, 43), len);
}
