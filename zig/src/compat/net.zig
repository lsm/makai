const std = @import("std");

pub const Address = std.net.Address;
pub const AddressList = std.net.AddressList;
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
/// `allocator` owns temporary DNS resolver allocations during this call.
pub fn resolveAddress(allocator: std.mem.Allocator, host: []const u8, port: u16) !Address {
    var list = try std.net.getAddressList(allocator, host, port);
    defer list.deinit();

    if (list.addrs.len == 0) return error.UnknownHostName;
    return list.addrs[0];
}

/// Resolve a host/port into an owned address list.
///
/// Callers own the returned list and must call `deinit`.
pub fn resolveAddressList(allocator: std.mem.Allocator, host: []const u8, port: u16) !*AddressList {
    return std.net.getAddressList(allocator, host, port);
}

/// Connect to the first reachable TCP peer from a resolved address list.
pub fn tcpConnectAny(list: *const AddressList) !Stream {
    if (list.addrs.len == 0) return error.UnknownHostName;

    var last_err: ?anyerror = null;
    for (list.addrs) |address| {
        if (tcpConnect(address)) |stream| {
            return stream;
        } else |err| {
            last_err = err;
        }
    }

    return last_err orelse error.ConnectionRefused;
}

/// Connect to a TCP host, trying resolved addresses in resolver order.
pub fn tcpConnectHost(allocator: std.mem.Allocator, host: []const u8, port: u16) !Stream {
    var list = try resolveAddressList(allocator, host, port);
    defer list.deinit();
    return tcpConnectAny(list);
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
