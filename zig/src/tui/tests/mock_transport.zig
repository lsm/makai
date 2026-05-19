const std = @import("std");
const transport = @import("transport");

pub const MockTransport = struct {
    allocator: std.mem.Allocator,
    inbound: std.ArrayList([]u8) = .empty,
    outbound: std.ArrayList([]u8) = .empty,
    read_index: usize = 0,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator) MockTransport {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MockTransport) void {
        for (self.inbound.items[self.read_index..]) |frame| self.allocator.free(frame);
        self.inbound.deinit(self.allocator);
        for (self.outbound.items) |frame| self.allocator.free(frame);
        self.outbound.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn sender(self: *MockTransport) transport.Sender {
        return .{
            .context = self,
            .write_fn = writeFn,
            .flush_fn = flushFn,
            .close_fn = closeFn,
        };
    }

    pub fn receiver(self: *MockTransport) transport.Receiver {
        return .{
            .context = self,
            .read_fn = readFn,
            .close_fn = closeFn,
        };
    }

    pub fn enqueueInbound(self: *MockTransport, frame: []const u8) !void {
        try self.inbound.append(self.allocator, try self.allocator.dupe(u8, frame));
    }

    pub fn outboundFrame(self: *const MockTransport, index: usize) []const u8 {
        return self.outbound.items[index];
    }

    pub fn outboundCount(self: *const MockTransport) usize {
        return self.outbound.items.len;
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) !void {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        if (self.closed) return error.TransportClosed;
        try self.outbound.append(self.allocator, try self.allocator.dupe(u8, data));
    }

    fn flushFn(ctx: *anyopaque) !void {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        if (self.closed) return error.TransportClosed;
    }

    fn readFn(ctx: *anyopaque, allocator: std.mem.Allocator) !?[]const u8 {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        if (self.read_index >= self.inbound.items.len) return null;
        const frame = self.inbound.items[self.read_index];
        const copy = try allocator.dupe(u8, frame);
        self.read_index += 1;
        self.allocator.free(frame);
        return copy;
    }

    fn closeFn(ctx: *anyopaque) void {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }
};

test "mock transport reads inbound frames FIFO and records outbound" {
    var mock = MockTransport.init(std.testing.allocator);
    defer mock.deinit();

    try mock.enqueueInbound("one");
    try mock.enqueueInbound("two");

    var receiver = mock.receiver();
    const first = (try receiver.read(std.testing.allocator)).?;
    defer std.testing.allocator.free(first);
    const second = (try receiver.read(std.testing.allocator)).?;
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("one", first);
    try std.testing.expectEqualStrings("two", second);
    try std.testing.expect((try receiver.read(std.testing.allocator)) == null);

    var sender = mock.sender();
    try sender.write("out");
    try sender.flush();
    try std.testing.expectEqual(@as(usize, 1), mock.outboundCount());
    try std.testing.expectEqualStrings("out", mock.outboundFrame(0));

    sender.close();
    try std.testing.expectError(error.TransportClosed, sender.write("after-close"));
}
