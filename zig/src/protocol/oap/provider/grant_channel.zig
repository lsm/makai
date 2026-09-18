const std = @import("std");
const compat = @import("compat");

pub const MAX_VALUE_BYTES: usize = 64 * 1024;

pub const Outcome = union(enum) {
    pending,
    value: []u8,
    rejected,
};

pub const GrantChannel = struct {
    allocator: std.mem.Allocator,
    dir_path: []u8,
    socket_path: []u8,
    server: std.Io.net.Server,
    connection: ?compat.net.Stream = null,
    accepted_one: bool = false,
    buffer: std.ArrayList(u8) = .empty,
    settled: bool = false,

    const Self = @This();

    pub const supported = compat.net.supports_unix_channels;

    pub fn open(allocator: std.mem.Allocator, ordinal: u64) !Self {
        if (!supported) return error.UnsupportedPlatform;
        const base = compat.getEnvVarOwned(allocator, "TMPDIR") catch null;
        defer if (base) |value| allocator.free(value);
        const trimmed = std.mem.trimEnd(u8, base orelse "/tmp", "/");

        const dir_path = try std.fmt.allocPrint(allocator, "{s}/makai-grant-{d}-{d}", .{
            trimmed,
            @as(u64, @bitCast(compat.time.nowMillis())),
            ordinal,
        });
        errdefer allocator.free(dir_path);

        try compat.fs.createPrivateDir(dir_path);
        errdefer compat.fs.removeDir(dir_path);

        const socket_path = try std.fmt.allocPrint(allocator, "{s}/s", .{dir_path});
        errdefer allocator.free(socket_path);

        const server = try compat.net.unixListen(socket_path);

        return .{
            .allocator = allocator,
            .dir_path = dir_path,
            .socket_path = socket_path,
            .server = server,
        };
    }

    pub fn path(self: *const Self) []const u8 {
        return self.socket_path;
    }

    pub fn poll(self: *Self, expected_nonce: []const u8) !Outcome {
        if (self.settled) return .rejected;

        if (self.connection == null) {
            if (!try compat.net.readableWithin(compat.net.serverHandle(&self.server), 0)) return .pending;
            var stream = compat.net.acceptStream(&self.server) catch return .pending;
            if (self.accepted_one) {
                stream.close();
                return .pending;
            }
            self.accepted_one = true;
            self.connection = stream;
        }

        var stream = &self.connection.?;
        if (!try compat.net.readableWithin(compat.net.streamHandle(stream), 0)) return .pending;

        var chunk: [4096]u8 = undefined;
        const read = stream.read(&chunk) catch 0;
        if (read == 0) {
            self.settled = true;
            return self.finish(expected_nonce);
        }

        if (self.buffer.items.len + read > MAX_VALUE_BYTES) {
            self.settled = true;
            return .rejected;
        }
        try self.buffer.appendSlice(self.allocator, chunk[0..read]);

        if (std.mem.indexOfScalar(u8, self.buffer.items, '\n')) |newline| {
            if (!std.mem.eql(u8, self.buffer.items[0..newline], expected_nonce)) {
                self.settled = true;
                return .rejected;
            }
        }
        return .pending;
    }

    fn finish(self: *Self, expected_nonce: []const u8) !Outcome {
        const newline = std.mem.indexOfScalar(u8, self.buffer.items, '\n') orelse return .rejected;
        if (!std.mem.eql(u8, self.buffer.items[0..newline], expected_nonce)) return .rejected;
        const raw = self.buffer.items[newline + 1 ..];
        if (raw.len == 0) return .rejected;
        return .{ .value = try self.allocator.dupe(u8, raw) };
    }

    pub fn deinit(self: *Self) void {
        if (self.connection) |*stream| stream.close();
        compat.net.closeServer(&self.server);
        compat.fs.removeFile(self.socket_path);
        compat.fs.removeDir(self.dir_path);
        self.buffer.deinit(self.allocator);
        self.allocator.free(self.socket_path);
        self.allocator.free(self.dir_path);
        self.* = undefined;
    }
};

pub fn connectAndWrite(path: []const u8, payload: []const u8) !void {
    const address = try compat.net.UnixAddress.init(path);
    var stream = try address.connect(if (@import("builtin").is_test) std.testing.io else std.Io.Threaded.global_single_threaded.io());
    defer stream.close(if (@import("builtin").is_test) std.testing.io else std.Io.Threaded.global_single_threaded.io());
    var wrapped = compat.net.Stream.init(stream);
    try wrapped.writeAll(payload);
}

fn drain(channel: *GrantChannel, nonce: []const u8) !Outcome {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        const outcome = try channel.poll(nonce);
        switch (outcome) {
            .pending => {},
            else => return outcome,
        }
    }
    return .pending;
}

test "a value written after the nonce reaches the endpoint" {
    const allocator = std.testing.allocator;
    var channel = try GrantChannel.open(allocator, 9001);
    defer channel.deinit();

    try connectAndWrite(channel.path(), "nonce-abc\nsk-secret-value");

    const outcome = try drain(&channel, "nonce-abc");
    try std.testing.expect(outcome == .value);
    defer allocator.free(outcome.value);
    try std.testing.expectEqualStrings("sk-secret-value", outcome.value);
}

test "a connection whose first line is not the nonce is rejected" {
    const allocator = std.testing.allocator;
    var channel = try GrantChannel.open(allocator, 9002);
    defer channel.deinit();

    try connectAndWrite(channel.path(), "wrong-nonce\nsk-secret-value");

    const outcome = try drain(&channel, "nonce-abc");
    try std.testing.expect(outcome == .rejected);
}

test "a connection that closes without a value is rejected" {
    const allocator = std.testing.allocator;
    var channel = try GrantChannel.open(allocator, 9003);
    defer channel.deinit();

    try connectAndWrite(channel.path(), "nonce-abc\n");

    const outcome = try drain(&channel, "nonce-abc");
    try std.testing.expect(outcome == .rejected);
}

test "the channel directory is owner only and disappears with the grant" {
    const allocator = std.testing.allocator;
    var channel = try GrantChannel.open(allocator, 9004);

    const dir_path = try allocator.dupe(u8, channel.dir_path);
    defer allocator.free(dir_path);

    try std.testing.expectEqual(@as(u32, 0o700), try compat.fs.directoryPermissions(dir_path));

    channel.deinit();
    try std.testing.expectError(error.FileNotFound, compat.fs.directoryPermissions(dir_path));
}
