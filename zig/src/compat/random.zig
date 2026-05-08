const std = @import("std");

/// Fill `buf` with security-sensitive random bytes.
///
/// Zig 0.16 mapping: route to the Makai default context's secure entropy source
/// (`io.randomSecure` or equivalent) per the architecture decision. OAuth
/// PKCE/state, credential material, and protocol-sensitive nonces should prefer
/// this helper.
pub fn secureBytes(buf: []u8) void {
    std.crypto.random.bytes(buf);
}

/// Fill `buf` with ordinary random bytes.
///
/// Zig 0.16 mapping: route to the Makai default context's non-secure random
/// source (`io.random`/test deterministic source where appropriate). Do not use
/// this for credentials, PKCE, OAuth state, or other security-sensitive values.
pub fn randomBytes(buf: []u8) void {
    std.crypto.random.bytes(buf);
}

test "compat random helpers fill requested buffers" {
    var secure: [16]u8 = [_]u8{0} ** 16;
    var ordinary: [16]u8 = [_]u8{0} ** 16;

    secureBytes(&secure);
    randomBytes(&ordinary);

    try std.testing.expect(!std.mem.eql(u8, &secure, &([_]u8{0} ** 16)));
    try std.testing.expect(!std.mem.eql(u8, &ordinary, &([_]u8{0} ** 16)));
}

test "compat random helpers accept empty buffers" {
    var empty: [0]u8 = .{};
    secureBytes(&empty);
    randomBytes(&empty);
}
