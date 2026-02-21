const std = @import("std");

/// A slice that tracks ownership, replacing scattered legacy bool-guard ownership patterns.
///
/// When `is_owned` is true, `deinit()` frees the items (calling per-element `deinit` if available)
/// and then frees the backing slice. When `is_owned` is false, `deinit()` is a no-op.
///
/// Inspired by Bun's ownership tracking patterns.
pub fn OwnedSlice(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []const T,
        is_owned: bool,

        /// Create a borrowed (non-owning) slice. `deinit()` will be a no-op.
        pub fn initBorrowed(items: []const T) Self {
            return .{ .items = items, .is_owned = false };
        }

        /// Create an owned slice. `deinit()` will free items and the backing memory.
        pub fn initOwned(items: []const T) Self {
            return .{ .items = items, .is_owned = true };
        }

        /// Access the underlying slice.
        pub fn slice(self: Self) []const T {
            return self.items;
        }

        /// Ensure this slice is owned by duplicating if currently borrowed.
        /// No-op if already owned.
        pub fn ensureOwned(self: *Self, allocator: std.mem.Allocator) !void {
            if (self.is_owned) return;
            self.items = try allocator.dupe(T, self.items);
            self.is_owned = true;
        }

        /// Backward-compatible alias for ensureOwned().
        pub fn cloneIfBorrowed(self: *Self, allocator: std.mem.Allocator) !void {
            return self.ensureOwned(allocator);
        }

        /// Free owned memory. No-op for borrowed slices.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (!self.is_owned) return;

            const mut_items: []T = @constCast(self.items);

            // Call per-element deinit if T has one (taking allocator)
            const has_deinit = comptime blk: {
                const info = @typeInfo(T);
                switch (info) {
                    .@"struct", .@"union", .@"enum", .@"opaque" => {
                        break :blk @hasDecl(T, "deinit");
                    },
                    else => break :blk false,
                }
            };

            if (has_deinit) {
                for (mut_items) |*item| {
                    item.deinit(allocator);
                }
            }

            allocator.free(self.items);
            self.* = undefined;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "OwnedSlice borrowed does not free" {
    const items = [_]u32{ 1, 2, 3 };
    var s = OwnedSlice(u32).initBorrowed(&items);
    // deinit on borrowed is a no-op — no crash, no leak
    s.deinit(std.testing.allocator);
}

test "OwnedSlice owned frees memory" {
    const allocator = std.testing.allocator;

    const items = try allocator.alloc(u32, 3);
    items[0] = 10;
    items[1] = 20;
    items[2] = 30;

    var s = OwnedSlice(u32).initOwned(items);
    try std.testing.expectEqual(@as(usize, 3), s.slice().len);
    try std.testing.expectEqual(@as(u32, 20), s.slice()[1]);

    s.deinit(allocator);
    // testing.allocator will detect leaks if deinit didn't free
}

test "OwnedSlice with struct that has deinit" {
    const allocator = std.testing.allocator;

    const Item = struct {
        data: []const u8,

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            alloc.free(self.data);
        }
    };

    const items = try allocator.alloc(Item, 2);
    items[0] = .{ .data = try allocator.dupe(u8, "hello") };
    items[1] = .{ .data = try allocator.dupe(u8, "world") };

    var s = OwnedSlice(Item).initOwned(items);
    try std.testing.expectEqual(@as(usize, 2), s.slice().len);
    try std.testing.expectEqualStrings("hello", s.slice()[0].data);

    s.deinit(allocator);
}

test "OwnedSlice empty owned slice" {
    const allocator = std.testing.allocator;

    const items = try allocator.alloc(u32, 0);
    var s = OwnedSlice(u32).initOwned(items);
    try std.testing.expectEqual(@as(usize, 0), s.slice().len);

    s.deinit(allocator);
}

test "OwnedSlice empty borrowed slice" {
    var s = OwnedSlice(u32).initBorrowed(&.{});
    try std.testing.expectEqual(@as(usize, 0), s.slice().len);
    s.deinit(std.testing.allocator);
}

test "OwnedSlice ensureOwned upgrades borrowed slice" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 'a', 'b', 'c' };

    var s = OwnedSlice(u8).initBorrowed(&input);
    try std.testing.expect(!s.is_owned);

    try s.ensureOwned(allocator);
    defer s.deinit(allocator);

    try std.testing.expect(s.is_owned);
    try std.testing.expectEqualStrings("abc", s.slice());
}

test "OwnedSlice cloneIfBorrowed is alias of ensureOwned" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 'x', 'y' };

    var s = OwnedSlice(u8).initBorrowed(&input);
    try s.cloneIfBorrowed(allocator);
    defer s.deinit(allocator);

    try std.testing.expect(s.is_owned);
    try std.testing.expectEqualStrings("xy", s.slice());
}
