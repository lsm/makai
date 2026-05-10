const std = @import("std");

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

/// Deterministic byte source for tests that need stable random-dependent output.
pub const DeterministicSource = struct {
    prng: std.Random.DefaultPrng,

    pub fn init(seed: u64) DeterministicSource {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    pub fn bytes(self: *DeterministicSource, buf: []u8) void {
        self.prng.random().bytes(buf);
    }

    pub fn allocBytes(self: *DeterministicSource, allocator: std.mem.Allocator, len: usize) ![]u8 {
        const buf = try allocator.alloc(u8, len);
        self.bytes(buf);
        return buf;
    }
};

/// Fill `buf` with security-sensitive random bytes.
///
/// 0.15.2: wraps `std.crypto.random.bytes`.
/// 0.16: use `io.randomSecure` through the Makai default context while keeping
/// raw `std.Io` out of this public signature. OAuth PKCE/state, credential
/// material, and protocol-sensitive nonces should prefer this helper.
pub fn fillSecureBytes(buf: []u8) void {
    defaultIo().randomSecure(buf) catch |err| {
        std.debug.panic("secure random unavailable: {}", .{err});
    };
}

/// Fill `buf` with ordinary random bytes.
///
/// 0.15.2: this is currently equivalent to `fillSecureBytes`; both use
/// `std.crypto.random.bytes` until the Zig 0.16 I/O context exists.
///
/// 0.16: use `io.random` through the Makai default context and keep this
/// separate from `fillSecureBytes`. Do not use this for credentials, PKCE,
/// OAuth state, or other security-sensitive values.
pub fn fillRandomBytes(buf: []u8) void {
    defaultIo().random(buf);
}

/// Allocate and fill security-sensitive random bytes.
///
/// 0.16: use `io.randomSecure` through the Makai default context.
pub fn secureBytes(allocator: std.mem.Allocator, len: usize) ![]u8 {
    const buf = try allocator.alloc(u8, len);
    fillSecureBytes(buf);
    return buf;
}

/// Allocate and fill ordinary random bytes for non-security identifiers.
///
/// 0.16: use `io.random` through the Makai default context.
pub fn randomBytes(allocator: std.mem.Allocator, len: usize) ![]u8 {
    const buf = try allocator.alloc(u8, len);
    fillRandomBytes(buf);
    return buf;
}

/// Return a secure random integer in `[0, upper_bound)` without modulo bias.
///
/// 0.15.2: delegates to `std.crypto.random.intRangeLessThan`, which uses
/// rejection sampling. 0.16: use `io.randomSecure` through the Makai default
/// context and preserve rejection-sampling semantics.
pub fn secureIntRangeLessThan(comptime T: type, upper_bound: T) T {
    var source: std.Random.IoSource = .{ .io = defaultIo() };
    return source.interface().intRangeLessThan(T, 0, upper_bound);
}

/// Return an ordinary random integer in `[0, upper_bound)` without modulo bias.
///
/// 0.15.2: this is currently equivalent to `secureIntRangeLessThan`; both use
/// `std.crypto.random.intRangeLessThan` until the Zig 0.16 I/O context exists.
/// 0.16: use `io.random` through the Makai default context and preserve
/// rejection-sampling semantics.
pub fn randomIntRangeLessThan(comptime T: type, upper_bound: T) T {
    var source: std.Random.IoSource = .{ .io = defaultIo() };
    return source.interface().intRangeLessThan(T, 0, upper_bound);
}

/// Return an ordinary random integer of type `T`.
pub fn int(comptime T: type) T {
    var source: std.Random.IoSource = .{ .io = defaultIo() };
    return source.interface().int(T);
}

fn isAllZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

test "compat random helpers allocate requested lengths" {
    const secure = try secureBytes(std.testing.allocator, 32);
    defer std.testing.allocator.free(secure);
    const ordinary = try randomBytes(std.testing.allocator, 17);
    defer std.testing.allocator.free(ordinary);

    try std.testing.expectEqual(@as(usize, 32), secure.len);
    try std.testing.expectEqual(@as(usize, 17), ordinary.len);
}

test "compat random helpers generate non-empty bytes" {
    const secure = try secureBytes(std.testing.allocator, 32);
    defer std.testing.allocator.free(secure);
    const ordinary = try randomBytes(std.testing.allocator, 32);
    defer std.testing.allocator.free(ordinary);

    try std.testing.expect(!isAllZero(secure));
    try std.testing.expect(!isAllZero(ordinary));
}

test "compat random helpers have basic uniqueness" {
    const first = try secureBytes(std.testing.allocator, 32);
    defer std.testing.allocator.free(first);
    const second = try secureBytes(std.testing.allocator, 32);
    defer std.testing.allocator.free(second);

    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "compat random range helpers respect upper bound" {
    for (0..128) |_| {
        const secure_value = secureIntRangeLessThan(usize, 62);
        const ordinary_value = randomIntRangeLessThan(usize, 62);
        try std.testing.expect(secure_value < 62);
        try std.testing.expect(ordinary_value < 62);
    }
}

test "compat random range helpers accept a single value range" {
    try std.testing.expectEqual(@as(usize, 0), secureIntRangeLessThan(usize, 1));
    try std.testing.expectEqual(@as(usize, 0), randomIntRangeLessThan(usize, 1));
}

test "compat deterministic random source is reproducible" {
    var first_source = DeterministicSource.init(0x1234_5678);
    var second_source = DeterministicSource.init(0x1234_5678);
    var different_source = DeterministicSource.init(0x8765_4321);

    const first = try first_source.allocBytes(std.testing.allocator, 32);
    defer std.testing.allocator.free(first);
    const second = try second_source.allocBytes(std.testing.allocator, 32);
    defer std.testing.allocator.free(second);
    const different = try different_source.allocBytes(std.testing.allocator, 32);
    defer std.testing.allocator.free(different);

    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expect(!std.mem.eql(u8, first, different));
}

test "compat random helpers accept empty buffers" {
    var empty: [0]u8 = .{};
    fillSecureBytes(&empty);
    fillRandomBytes(&empty);

    const secure = try secureBytes(std.testing.allocator, 0);
    defer std.testing.allocator.free(secure);
    const ordinary = try randomBytes(std.testing.allocator, 0);
    defer std.testing.allocator.free(ordinary);

    try std.testing.expectEqual(@as(usize, 0), secure.len);
    try std.testing.expectEqual(@as(usize, 0), ordinary.len);
}
