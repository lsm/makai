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

/// Resolve a host/port into an address.
///
/// Zig 0.15.2: wraps `std.net.getAddressList` and returns the first resolved
/// address, preserving DNS hostname support in addition to literal IP inputs.
/// 0.16: keep this public signature and route through the selected Makai
/// networking context internally.
///
/// `allocator` owns temporary DNS resolver allocations during this call.
pub fn resolveAddress(allocator: std.mem.Allocator, host: []const u8, port: u16) !Address {
    var list = try std.net.getAddressList(allocator, host, port);
    defer list.deinit();

    if (list.addrs.len == 0) return error.UnknownHostName;
    return list.addrs[0];
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

    var buffer: [4]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < buffer.len) {
        const bytes_read = connection.stream.read(buffer[total_read..]) catch |err| {
            context.result = err;
            return;
        };
        if (bytes_read == 0) {
            context.result = error.EndOfStream;
            return;
        }
        total_read += bytes_read;
    }

    if (!std.mem.eql(u8, &buffer, "ping")) {
        context.result = error.UnexpectedRequest;
        return;
    }

    connection.stream.writeAll("pong") catch |err| {
        context.result = err;
        return;
    };
}

test "compat networking resolves loopback address" {
    const address = try resolveAddress(std.testing.allocator, "127.0.0.1", 0);
    try std.testing.expectEqual(@as(u16, 0), address.getPort());
}

test "compat networking resolves localhost hostname" {
    const address = try resolveAddress(std.testing.allocator, "localhost", 0);
    try std.testing.expectEqual(@as(u16, 0), address.getPort());
}

test "compat networking can listen on loopback" {
    const address = try resolveAddress(std.testing.allocator, "127.0.0.1", 0);
    var server = try tcpListen(address, .{ .reuse_address = true });
    defer server.deinit();

    try std.testing.expect(server.listenAddress().getPort() != 0);
}

test "compat networking loopback connect read write round trip" {
    const address = try resolveAddress(std.testing.allocator, "127.0.0.1", 0);
    var server = try tcpListen(address, .{ .reuse_address = true });
    defer server.deinit();

    var client = try tcpConnect(server.listenAddress());
    errdefer client.close();

    var context = LoopbackServerContext{ .server = &server };
    const thread = try std.Thread.spawn(.{}, loopbackServerThread, .{&context});
    defer thread.join();
    defer client.close();

    try client.writeAll("ping");

    var response: [4]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < response.len) {
        const bytes_read = try client.read(response[total_read..]);
        if (bytes_read == 0) return error.EndOfStream;
        total_read += bytes_read;
    }
    try std.testing.expectEqualStrings("pong", &response);

    try context.result;
}
