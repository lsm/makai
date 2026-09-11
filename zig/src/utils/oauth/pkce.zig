
const std = @import("std");
const compat = @import("compat");

pub const PKCEChallenge = struct {
    verifier: []const u8,
    challenge: []const u8,

    pub fn deinit(self: *const PKCEChallenge, allocator: std.mem.Allocator) void {
        allocator.free(self.verifier);
        allocator.free(self.challenge);
    }
};

pub fn generate(allocator: std.mem.Allocator) !PKCEChallenge {
    return generateWithRandom(allocator, compat.random.fillSecureBytes);
}

fn generateWithRandom(allocator: std.mem.Allocator, fill_random: fn ([]u8) void) !PKCEChallenge {
    var random_bytes: [32]u8 = undefined;
    fill_random(&random_bytes);

    const verifier = try base64urlEncode(allocator, &random_bytes);
    errdefer allocator.free(verifier);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &hash, .{});

    const challenge = try base64urlEncode(allocator, &hash);

    return .{ .verifier = verifier, .challenge = challenge };
}

fn base64urlEncode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded_len = encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(encoded, data);
    return encoded;
}

fn fillTestPkceBytes(buf: []u8) void {
    for (buf, 0..) |*byte, i| {
        byte.* = @intCast(i);
    }
}

test "generate - returns valid PKCE challenge" {
    const challenge = try generate(std.testing.allocator);
    defer challenge.deinit(std.testing.allocator);

    try std.testing.expect(challenge.verifier.len == 43);
    try std.testing.expect(challenge.challenge.len == 43);

    try std.testing.expect(std.mem.find(u8, challenge.verifier, "+") == null);
    try std.testing.expect(std.mem.find(u8, challenge.verifier, "/") == null);
    try std.testing.expect(std.mem.find(u8, challenge.verifier, "=") == null);

    try std.testing.expect(std.mem.find(u8, challenge.challenge, "+") == null);
    try std.testing.expect(std.mem.find(u8, challenge.challenge, "/") == null);
    try std.testing.expect(std.mem.find(u8, challenge.challenge, "=") == null);
}

test "generate - creates unique verifiers" {
    const challenge1 = try generate(std.testing.allocator);
    defer challenge1.deinit(std.testing.allocator);

    const challenge2 = try generate(std.testing.allocator);
    defer challenge2.deinit(std.testing.allocator);

    try std.testing.expect(!std.mem.eql(u8, challenge1.verifier, challenge2.verifier));
    try std.testing.expect(!std.mem.eql(u8, challenge1.challenge, challenge2.challenge));
}

test "generateWithRandom - is deterministic for test seam" {
    const challenge1 = try generateWithRandom(std.testing.allocator, fillTestPkceBytes);
    defer challenge1.deinit(std.testing.allocator);

    const challenge2 = try generateWithRandom(std.testing.allocator, fillTestPkceBytes);
    defer challenge2.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(challenge1.verifier, challenge2.verifier);
    try std.testing.expectEqualStrings(challenge1.challenge, challenge2.challenge);
    try std.testing.expectEqualStrings("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", challenge1.verifier);
}

test "base64urlEncode - encodes correctly" {
    const data = "hello world";
    const encoded = try base64urlEncode(std.testing.allocator, data);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings("aGVsbG8gd29ybGQ", encoded);
    try std.testing.expect(std.mem.find(u8, encoded, "=") == null);
}
