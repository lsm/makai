const std = @import("std");
const HostName = std.Io.net.HostName;

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
/// Uses streams produced by Makai default-context networking helpers without
/// exposing raw `std.Io` in this public wrapper API.
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

/// Return the bound listener address through Makai's selected networking backend.
pub fn listenAddress(server: *const Server) Address {
    return server.socket.address;
}

/// Stop a TCP listener through the compatibility networking boundary.
pub fn closeServer(server: *Server) void {
    server.deinit(defaultIo());
}

/// Accept a TCP connection and wrap its stream at the Makai compatibility seam.
///
/// Preserves this helper shape over Makai's selected networking backend.
pub fn accept(server: *Server) !Connection {
    const stream = try server.accept(defaultIo());
    return .{
        .stream = Stream.init(stream),
        .address = stream.socket.address,
    };
}

/// Resolve a host/port into an address.
///
/// Returns the first resolved address, preserving DNS hostname support in
/// addition to literal IP inputs. Keeps this public signature while routing
/// through the selected Makai networking context internally.
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

    if (Address.parse(host, port)) |address| {
        list.* = .{
            .addrs = try allocator.dupe(Address, &.{address}),
            .allocator = allocator,
        };
        return list;
    } else |_| {}

    const host_name = try HostName.init(host);
    var result_buffer: [32]HostName.LookupResult = undefined;
    var result_queue = std.Io.Queue(HostName.LookupResult).init(&result_buffer);
    try HostName.lookup(host_name, defaultIo(), &result_queue, .{ .port = port });

    var addresses: std.ArrayList(Address) = .empty;
    defer addresses.deinit(allocator);
    while (result_queue.getOne(defaultIo())) |result| {
        switch (result) {
            .address => |address| try addresses.append(allocator, address),
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Closed => {},
        else => |e| return e,
    }

    if (addresses.items.len == 0) return error.UnknownHostName;
    list.* = .{
        .addrs = try addresses.toOwnedSlice(allocator),
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

/// Connect to a TCP peer through the Makai default I/O context.
pub fn tcpConnect(address: Address) !Stream {
    return Stream.init(try address.connect(defaultIo(), .{ .mode = .stream, .protocol = .tcp }));
}

/// Listen for TCP connections on `address` through the Makai default I/O context.
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
