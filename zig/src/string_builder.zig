const std = @import("std");

/// Two-phase string builder that counts capacity first, allocates once, then fills.
///
/// Inspired by Bun's StringBuilder pattern. This avoids repeated reallocations
/// by separating the "how much space do we need?" phase from the "fill it in" phase.
///
/// Usage:
/// ```zig
/// var sb = StringBuilder{};
///
/// // Phase 1: count needed capacity
/// sb.count("hello");
/// sb.count(", ");
/// sb.count("world");
///
/// // Phase 2: allocate and fill
/// try sb.allocate(allocator);
/// defer sb.deinit(allocator);
///
/// const hello = sb.append("hello");
/// _ = sb.append(", ");
/// const world = sb.append("world");
///
/// // hello and world are slices into the single allocated buffer
/// ```
pub const StringBuilder = struct {
    cap: usize = 0,
    len: usize = 0,
    ptr: ?[*]u8 = null,

    // Phase 1: count needed capacity

    /// Add the length of a string to the required capacity.
    pub fn count(self: *StringBuilder, str: []const u8) void {
        self.cap += str.len;
    }

    /// Add the formatted length to the required capacity.
    pub fn countFmt(self: *StringBuilder, comptime fmt: []const u8, args: anytype) void {
        self.cap += std.fmt.count(fmt, args);
    }

    // Phase 2: allocate and fill

    /// Allocate the buffer with the accumulated capacity.
    /// Must be called after all `count`/`countFmt` calls and before any `append`/`appendFmt` calls.
    pub fn allocate(self: *StringBuilder, allocator: std.mem.Allocator) !void {
        if (self.cap == 0) return;
        const buf = try allocator.alloc(u8, self.cap);
        self.ptr = buf.ptr;
        self.len = 0;
    }

    /// Append a string to the buffer, returning a slice into the buffer.
    /// The returned slice is valid for the lifetime of the StringBuilder.
    pub fn append(self: *StringBuilder, str: []const u8) []const u8 {
        if (str.len == 0) return "";
        const buf = self.ptr.?;
        const start = self.len;
        @memcpy(buf[start .. start + str.len], str);
        self.len += str.len;
        return buf[start..self.len];
    }

    /// Append formatted text to the buffer, returning a slice into the buffer.
    pub fn appendFmt(self: *StringBuilder, comptime fmt: []const u8, args: anytype) []const u8 {
        const buf = self.ptr.?;
        const start = self.len;
        const result = std.fmt.bufPrint(buf[start..self.cap], fmt, args) catch return "";
        self.len += result.len;
        return buf[start..self.len];
    }

    /// Free the backing buffer.
    pub fn deinit(self: *StringBuilder, allocator: std.mem.Allocator) void {
        if (self.ptr) |p| {
            allocator.free(p[0..self.cap]);
        }
        self.* = undefined;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "StringBuilder basic usage" {
    const allocator = std.testing.allocator;

    var sb = StringBuilder{};

    // Phase 1: count
    sb.count("hello");
    sb.count(", ");
    sb.count("world");

    try std.testing.expectEqual(@as(usize, 12), sb.cap);

    // Phase 2: allocate and fill
    try sb.allocate(allocator);
    defer sb.deinit(allocator);

    const hello = sb.append("hello");
    _ = sb.append(", ");
    const world = sb.append("world");

    try std.testing.expectEqualStrings("hello", hello);
    try std.testing.expectEqualStrings("world", world);
    try std.testing.expectEqual(@as(usize, 12), sb.len);
}

test "StringBuilder with fmt" {
    const allocator = std.testing.allocator;

    var sb = StringBuilder{};

    sb.count("name=");
    sb.countFmt("{d}", .{42});

    try sb.allocate(allocator);
    defer sb.deinit(allocator);

    _ = sb.append("name=");
    const num = sb.appendFmt("{d}", .{42});

    try std.testing.expectEqualStrings("42", num);
}

test "StringBuilder empty" {
    const allocator = std.testing.allocator;

    var sb = StringBuilder{};
    try sb.allocate(allocator);
    // No allocation happened for zero capacity, deinit is safe
    sb.deinit(allocator);
}

test "StringBuilder append empty string" {
    const allocator = std.testing.allocator;

    var sb = StringBuilder{};
    sb.count("abc");

    try sb.allocate(allocator);
    defer sb.deinit(allocator);

    const empty = sb.append("");
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const abc = sb.append("abc");
    try std.testing.expectEqualStrings("abc", abc);
}

test "StringBuilder slices share buffer" {
    const allocator = std.testing.allocator;

    var sb = StringBuilder{};
    sb.count("aaa");
    sb.count("bbb");

    try sb.allocate(allocator);
    defer sb.deinit(allocator);

    const a = sb.append("aaa");
    const b_slice = sb.append("bbb");

    // Both slices point into the same buffer
    try std.testing.expect(@intFromPtr(a.ptr) + a.len == @intFromPtr(b_slice.ptr));
}
