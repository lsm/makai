const std = @import("std");

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

pub const Address = std.Io.net.IpAddress;
pub const ListenOptions = Address.ListenOptions;
pub const Server = std.Io.net.Server;

pub const AddressList = struct {
    addrs: []Address,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AddressList) void {
        const allocator = self.allocator;
        allocator.free(self.addrs);
        allocator.destroy(self);
    }
};

/// TCP stream wrapper used as the stable Makai networking boundary.
///
/// Zig 0.15.2: owns a `std.net.Stream` and forwards byte reads/writes.
/// 0.16: use streams produced by Makai default-context networking helpers
/// (`std.Io.net.tcpConnect` internally) without exposing raw `std.Io` in this
/// public wrapper API.
pub const Stream = struct {
    inner: std.Io.net.Stream,

    pub fn init(inner: std.Io.net.Stream) Stream {
        return .{ .inner = inner };
    }

    pub fn read(self: *Stream, buffer: []u8) !usize {
        var reader = self.inner.reader(defaultIo(), &.{});
        return reader.interface.readSliceShort(buffer);
    }

    pub fn write(self: *Stream, data: []const u8) !usize {
        return defaultIo().vtable.netWrite(defaultIo().userdata, self.inner.socket.handle, &.{}, &.{data}, 1);
    }

    pub fn writeAll(self: *Stream, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            written += try self.write(data[written..]);
        }
    }

    pub fn close(self: *Stream) void {
        self.inner.close(defaultIo());
    }
};

fn readAll(stream: *Stream, buffer: []u8) !void {
    var total_read: usize = 0;
    while (total_read < buffer.len) {
        const bytes_read = try stream.read(buffer[total_read..]);
        if (bytes_read == 0) return error.EndOfStream;
        total_read += bytes_read;
    }
}

/// Accepted TCP connection returned by `accept`.
pub const Connection = struct {
    stream: Stream,
    address: Address,
};

/// Return the bound listener address.
///
/// Zig 0.15.2: reads `std.net.Server.listen_address`.
/// 0.16: route through Makai's selected networking backend internally.
pub fn listenAddress(server: *const Server) Address {
    return server.socket.address;
}

/// Accept a TCP connection and wrap its stream at the Makai compatibility seam.
///
/// Zig 0.15.2: wraps `std.net.Server.accept`.
/// 0.16: preserve this helper shape over Makai's selected networking backend.
pub fn accept(server: *Server) !Connection {
    const stream = try server.accept(defaultIo());
    return .{
        .stream = Stream.init(stream),
        .address = stream.socket.address,
    };
}

/// Resolve a host/port into an address.
///
/// Zig 0.15.2: wraps `std.net.getAddressList` and returns the first resolved
/// address, preserving DNS hostname support in addition to literal IP inputs.
/// 0.16: keep this public signature and route through the selected Makai
/// networking context internally.
///
/// `allocator` owns temporary DNS resolver allocations during this call.
pub fn resolveAddress(allocator: std.mem.Allocator, host: []const u8, port: u16) !Address {
    var list = try resolveAddressList(allocator, host, port);
    defer list.deinit();

    if (list.addrs.len == 0) return error.UnknownHostName;
    return list.addrs[0];
}

/// Resolve a host/port into an owned address list for DNS-style consumers.
///
/// Callers own the returned list and must call `deinit`.
pub fn resolveAddressList(allocator: std.mem.Allocator, host: []const u8, port: u16) !*AddressList {
    const list = try allocator.create(AddressList);
    errdefer allocator.destroy(list);

    const address = Address.resolve(defaultIo(), host, port) catch blk: {
        if (std.ascii.eqlIgnoreCase(host, "localhost")) {
            break :blk Address{ .ip4 = .loopback(port) };
        }
        return error.UnknownHostName;
    };
    list.* = .{
        .addrs = try allocator.dupe(Address, &.{address}),
        .allocator = allocator,
    };
    return list;
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
///
/// Zig 0.15.2: wraps `std.net.tcpConnectToAddress`.
/// 0.16: use std.Io.net.tcpConnect internally.
pub fn tcpConnect(address: Address) !Stream {
    return Stream.init(try address.connect(defaultIo(), .{ .mode = .stream, .protocol = .tcp }));
}

/// Listen for TCP connections on `address`.
///
/// Zig 0.15.2: wraps `std.net.Address.listen`.
/// 0.16: use std.Io.net.tcpListen internally.
pub fn tcpListen(address: Address, options: ListenOptions) !Server {
    return address.listen(defaultIo(), options);
}

const LoopbackServerContext = struct {
    server: *Server,
    result: anyerror!void = {},
};

fn loopbackServerThread(context: *LoopbackServerContext) void {
    var connection = accept(context.server) catch |err| {
        context.result = err;
        return;
    };
    defer connection.stream.close();

    var buffer: [4]u8 = undefined;
    readAll(&connection.stream, &buffer) catch |err| {
        context.result = err;
        return;
    };

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
    defer server.deinit(defaultIo());

    try std.testing.expect(listenAddress(&server).getPort() != 0);
}

test "compat networking loopback connect read write round trip" {
    const address = try resolveAddress(std.testing.allocator, "127.0.0.1", 0);
    var server = try tcpListen(address, .{ .reuse_address = true });
    defer server.deinit(defaultIo());

    var client = try tcpConnect(listenAddress(&server));
    defer client.close();

    var context = LoopbackServerContext{ .server = &server };
    const thread = try std.Thread.spawn(.{}, loopbackServerThread, .{&context});
    var thread_joined = false;
    defer if (!thread_joined) thread.join();

    try client.writeAll("ping");

    var response: [4]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < response.len) {
        const bytes_read = try client.read(response[total_read..]);
        if (bytes_read == 0) return error.EndOfStream;
        total_read += bytes_read;
    }
    try std.testing.expectEqualStrings("pong", &response);

    thread.join();
    thread_joined = true;
    try context.result;
}
