const std = @import("std");

pub const Address = std.net.Address;
pub const Server = std.net.Server;

/// TCP stream wrapper used as the stable Makai networking boundary.
///
/// Zig 0.16 mapping: wrap streams produced by Makai default-context networking
/// helpers. The public wrapper avoids exposing `std.Io` while preserving current
/// byte-stream read/write/close behavior for transports and OAuth callback code.
pub const Stream = struct {
    inner: std.net.Stream,

    pub fn init(inner: std.net.Stream) Stream {
        return .{ .inner = inner };
    }

    pub fn read(self: *Stream, buffer: []u8) !usize {
        return self.inner.read(buffer);
    }

    pub fn write(self: *Stream, data: []const u8) !usize {
        return self.inner.write(data);
    }

    pub fn writeAll(self: *Stream, data: []const u8) !void {
        try self.inner.writeAll(data);
    }

    pub fn close(self: *Stream) void {
        self.inner.close();
    }
};

/// Resolve a host/port into an address.
///
/// Zig 0.16 mapping: route through the selected Makai default I/O/networking
/// backend internally while keeping this wrapper signature context/allocator
/// first and free of raw `std.Io`.
///
/// `allocator` is intentionally reserved for the future resolver implementation,
/// which may allocate address lists or context-backed resolver state. The Zig
/// 0.15.2 pass-through uses `std.net.Address.resolveIp` and does not allocate.
pub fn resolveAddress(allocator: std.mem.Allocator, host: []const u8, port: u16) !Address {
    _ = allocator;
    return std.net.Address.resolveIp(host, port);
}

/// Connect to a TCP peer.
pub fn tcpConnect(address: Address) !Stream {
    return .{ .inner = try std.net.tcpConnectToAddress(address) };
}

/// Listen for TCP connections on `address`.
pub fn tcpListen(address: Address, options: Address.ListenOptions) !Server {
    return address.listen(options);
}

test "compat networking resolves loopback address" {
    const address = try resolveAddress(std.testing.allocator, "127.0.0.1", 0);
    try std.testing.expectEqual(@as(u16, 0), address.getPort());
}

test "compat networking can listen on loopback" {
    const address = try resolveAddress(std.testing.allocator, "127.0.0.1", 0);
    var server = try tcpListen(address, .{ .reuse_address = true });
    defer server.deinit();

    try std.testing.expect(server.listen_address.getPort() != 0);
}
