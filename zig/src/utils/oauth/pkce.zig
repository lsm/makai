const std = @import("std");

/// PKCE challenge pair (verifier and challenge)
pub const PKCEChallenge = struct {
    verifier: []const u8,
    challenge: []const u8,

    pub fn deinit(self: *const PKCEChallenge, allocator: std.mem.Allocator) void {
        allocator.free(self.verifier);
        allocator.free(self.challenge);
    }
};

/// Generate PKCE challenge pair
/// Returns base64url(random_32_bytes) as verifier and base64url(SHA256(verifier)) as challenge
pub fn generate(allocator: std.mem.Allocator) !PKCEChallenge {
    // 1. Generate 32 random bytes
    var random_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    // 2. Base64url encode → verifier
    const verifier = try base64urlEncode(allocator, &random_bytes);
    errdefer allocator.free(verifier);

    // 3. SHA-256 hash of verifier
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &hash, .{});

    // 4. Base64url encode hash → challenge
    const challenge = try base64urlEncode(allocator, &hash);

    return .{ .verifier = verifier, .challenge = challenge };
}

/// Base64url encode data (RFC 4648 section 5)
/// Standard base64 but replace +/= with -/_ and remove padding
fn base64urlEncode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded_len = encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(encoded, data);
    return encoded;
}

test "generate - returns valid PKCE challenge" {
    const challenge = try generate(std.testing.allocator);
    defer challenge.deinit(std.testing.allocator);

    // Verifier should be 43 characters (32 bytes base64url encoded)
    try std.testing.expect(challenge.verifier.len == 43);
    // Challenge should be 43 characters (32 bytes SHA-256 base64url encoded)
    try std.testing.expect(challenge.challenge.len == 43);

    // Should not contain standard base64 characters
    try std.testing.expect(std.mem.indexOf(u8, challenge.verifier, "+") == null);
    try std.testing.expect(std.mem.indexOf(u8, challenge.verifier, "/") == null);
    try std.testing.expect(std.mem.indexOf(u8, challenge.verifier, "=") == null);

    try std.testing.expect(std.mem.indexOf(u8, challenge.challenge, "+") == null);
    try std.testing.expect(std.mem.indexOf(u8, challenge.challenge, "/") == null);
    try std.testing.expect(std.mem.indexOf(u8, challenge.challenge, "=") == null);
}

test "generate - creates unique verifiers" {
    const challenge1 = try generate(std.testing.allocator);
    defer challenge1.deinit(std.testing.allocator);

    const challenge2 = try generate(std.testing.allocator);
    defer challenge2.deinit(std.testing.allocator);

    // Should be different
    try std.testing.expect(!std.mem.eql(u8, challenge1.verifier, challenge2.verifier));
    try std.testing.expect(!std.mem.eql(u8, challenge1.challenge, challenge2.challenge));
}

test "base64urlEncode - encodes correctly" {
    const data = "hello world";
    const encoded = try base64urlEncode(std.testing.allocator, data);
    defer std.testing.allocator.free(encoded);

    // Should be base64url without padding
    try std.testing.expectEqualStrings("aGVsbG8gd29ybGQ", encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "=") == null);
}
