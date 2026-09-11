const std = @import("std");

pub fn HiveArray(comptime T: type, comptime capacity: u16) type {
    return struct {
        const Self = @This();

        buffer: [capacity]T = undefined,
        available: std.StaticBitSet(capacity),

        pub fn init() Self {
            var self: Self = undefined;
            self.available = std.StaticBitSet(capacity).initFull();
            return self;
        }

        pub fn get(self: *Self) ?*T {
            const index = self.available.findFirstSet() orelse return null;
            self.available.unset(index);
            self.buffer[index] = undefined;
            return &self.buffer[index];
        }

        pub fn put(self: *Self, ptr: *T) void {
            const index = self.indexOf(ptr);
            ptr.* = undefined;
            self.available.set(index);
        }

        pub fn count(self: *const Self) usize {
            return capacity - self.available.count();
        }

        pub fn available_count(self: *const Self) usize {
            return self.available.count();
        }

        pub fn isFull(self: *const Self) bool {
            return self.available.count() == 0;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.available.count() == capacity;
        }

        fn indexOf(self: *Self, ptr: *T) usize {
            const base = @intFromPtr(&self.buffer[0]);
            const addr = @intFromPtr(ptr);
            return (addr - base) / @sizeOf(T);
        }
    };
}

test "HiveArray init starts empty" {
    var pool = HiveArray(u64, 4).init();
    try std.testing.expectEqual(@as(usize, 0), pool.count());
    try std.testing.expectEqual(@as(usize, 4), pool.available_count());
    try std.testing.expect(pool.isEmpty());
    try std.testing.expect(!pool.isFull());
}

test "HiveArray get and put" {
    var pool = HiveArray(u64, 4).init();

    const ptr1 = pool.get().?;
    ptr1.* = 42;
    try std.testing.expectEqual(@as(usize, 1), pool.count());

    const ptr2 = pool.get().?;
    ptr2.* = 99;
    try std.testing.expectEqual(@as(usize, 2), pool.count());

    try std.testing.expectEqual(@as(u64, 42), ptr1.*);
    try std.testing.expectEqual(@as(u64, 99), ptr2.*);

    pool.put(ptr1);
    try std.testing.expectEqual(@as(usize, 1), pool.count());

    pool.put(ptr2);
    try std.testing.expectEqual(@as(usize, 0), pool.count());
    try std.testing.expect(pool.isEmpty());
}

test "HiveArray full pool returns null" {
    var pool = HiveArray(u32, 2).init();

    const p1 = pool.get();
    const p2 = pool.get();
    try std.testing.expect(p1 != null);
    try std.testing.expect(p2 != null);
    try std.testing.expect(pool.isFull());

    try std.testing.expect(pool.get() == null);

    pool.put(p1.?);
    try std.testing.expect(!pool.isFull());

    const p3 = pool.get();
    try std.testing.expect(p3 != null);
    try std.testing.expect(pool.isFull());

    pool.put(p2.?);
    pool.put(p3.?);
}

test "HiveArray reuses slots" {
    var pool = HiveArray(u32, 2).init();

    const p1 = pool.get().?;
    p1.* = 1;
    pool.put(p1);

    const p2 = pool.get().?;
    p2.* = 2;
    try std.testing.expectEqual(@as(u32, 2), p2.*);

    pool.put(p2);
}

test "HiveArray with struct type" {
    const Connection = struct {
        id: u32,
        active: bool,
    };

    var pool = HiveArray(Connection, 8).init();

    const conn = pool.get().?;
    conn.* = .{ .id = 1, .active = true };

    try std.testing.expectEqual(@as(u32, 1), conn.id);
    try std.testing.expect(conn.active);
    try std.testing.expectEqual(@as(usize, 1), pool.count());

    pool.put(conn);
    try std.testing.expect(pool.isEmpty());
}
