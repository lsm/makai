const std = @import("std");

pub const Address = std.net.Address;
pub const AddressList = std.net.AddressList;
pub const ListenOptions = Address.ListenOptions;

/// TCP stream wrapper used as the stable Makai networking boundary.
///
/// Zig 0.15.2: owns a `std.net.Stream` and forwards byte reads/writes.
/// 0.16: use streams produced by Makai default-context networking helpers
/// (`std.Io.net.tcpConnect` internally) without exposing raw `std.Io` in this
/// public wrapper API.
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

/// Accepted TCP connection returned by `Server.accept`.
pub const Connection = struct {
    stream: Stream,
    address: Address,
};

/// TCP listener wrapper used by OAuth callback and transport networking paths.
///
/// Zig 0.15.2: owns a `std.net.Server`. 0.16: use Makai's selected networking
/// backend internally while preserving this listen/accept shape.
pub const Server = struct {
    inner: std.net.Server,

    pub fn init(inner: std.net.Server) Server {
        return .{ .inner = inner };
    }

    pub fn listenAddress(self: *const Server) Address {
        return self.inner.listen_address;
    }

    pub fn accept(self: *Server) !Connection {
        const connection = try self.inner.accept();
        return .{
            .stream = Stream.init(connection.stream),
            .address = connection.address,
        };
    }

    pub fn deinit(self: *Server) void {
        self.inner.deinit();
    }
};

/// Resolve an IPv4/IPv6 string host and port into an address.
///
/// Zig 0.15.2: wraps `std.net.Address.resolveIp`.
/// 0.16: keep this public signature and route through the selected Makai
/// networking context internally.
pub fn resolveAddress(host: []const u8, port: u16) !Address {
    return std.net.Address.resolveIp(host, port);
}

/// Resolve a host/port into an owned address list for DNS-style consumers.
///
/// Callers own the returned list and must call `deinit`.
pub fn resolveAddressList(allocator: std.mem.Allocator, host: []const u8, port: u16) !*AddressList {
    return std.net.getAddressList(allocator, host, port);
}

/// Connect to a TCP peer.
///
/// Zig 0.15.2: wraps `std.net.tcpConnectToAddress`.
/// 0.16: use std.Io.net.tcpConnect internally.
pub fn tcpConnect(address: Address) !Stream {
    return Stream.init(try std.net.tcpConnectToAddress(address));
}

/// Listen for TCP connections on `address`.
///
/// Zig 0.15.2: wraps `std.net.Address.listen`.
/// 0.16: use std.Io.net.tcpListen internally.
pub fn tcpListen(address: Address, options: ListenOptions) !Server {
    return Server.init(try address.listen(options));
}

const LoopbackServerContext = struct {
    server: *Server,
    result: anyerror!void = {},
};

fn loopbackServerThread(context: *LoopbackServerContext) void {
    var connection = context.server.accept() catch |err| {
        context.result = err;
        return;
    };
    defer connection.stream.close();

    var buffer: [32]u8 = undefined;
    const bytes_read = connection.stream.read(&buffer) catch |err| {
        context.result = err;
        return;
    };

    if (!std.mem.eql(u8, buffer[0..bytes_read], "ping")) {
        context.result = error.UnexpectedRequest;
        return;
    }

    connection.stream.writeAll("pong") catch |err| {
        context.result = err;
        return;
    };
}

test "compat networking resolves loopback address" {
    const address = try resolveAddress("127.0.0.1", 0);
    try std.testing.expectEqual(@as(u16, 0), address.getPort());
}

test "compat networking can listen on loopback" {
    const address = try resolveAddress("127.0.0.1", 0);
    var server = try tcpListen(address, .{ .reuse_address = true });
    defer server.deinit();

    try std.testing.expect(server.listenAddress().getPort() != 0);
}

test "compat networking loopback connect read write round trip" {
    const address = try resolveAddress("127.0.0.1", 0);
    var server = try tcpListen(address, .{ .reuse_address = true });
    defer server.deinit();

    var context = LoopbackServerContext{ .server = &server };
    const thread = try std.Thread.spawn(.{}, loopbackServerThread, .{&context});

    var client = try tcpConnect(server.listenAddress());
    defer client.close();

    try client.writeAll("ping");

    var response: [4]u8 = undefined;
    const bytes_read = try client.read(&response);
    try std.testing.expectEqualStrings("pong", response[0..bytes_read]);

    thread.join();
    try context.result;
}
