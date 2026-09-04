const std = @import("std");

pub const Metrics = struct {
    allocation_count: usize = 0,
    free_count: usize = 0,
    allocated_bytes: usize = 0,
    freed_bytes: usize = 0,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,

    pub fn leakBytes(self: Metrics) usize {
        return self.live_bytes;
    }
};

pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    metrics: Metrics = .{},

    pub fn init(backing: std.mem.Allocator) CountingAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn recordGrowth(self: *CountingAllocator, bytes: usize) void {
        self.metrics.allocated_bytes += bytes;
        self.metrics.live_bytes += bytes;
        self.metrics.peak_live_bytes = @max(self.metrics.peak_live_bytes, self.metrics.live_bytes);
    }

    fn recordShrink(self: *CountingAllocator, bytes: usize) void {
        self.metrics.freed_bytes += bytes;
        self.metrics.live_bytes -= bytes;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.metrics.allocation_count += 1;
        self.recordGrowth(len);
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) self.recordGrowth(new_len - memory.len) else self.recordShrink(memory.len - new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) self.recordGrowth(new_len - memory.len) else self.recordShrink(memory.len - new_len);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.metrics.free_count += 1;
        self.recordShrink(memory.len);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

test "CountingAllocator records balanced allocations and peak live bytes" {
    var counter = CountingAllocator.init(std.testing.allocator);
    const allocator = counter.allocator();
    const first = try allocator.alloc(u8, 32);
    const second = try allocator.alloc(u8, 16);
    allocator.free(first);
    allocator.free(second);

    try std.testing.expectEqual(@as(usize, 2), counter.metrics.allocation_count);
    try std.testing.expectEqual(@as(usize, 2), counter.metrics.free_count);
    try std.testing.expectEqual(@as(usize, 48), counter.metrics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 48), counter.metrics.freed_bytes);
    try std.testing.expectEqual(@as(usize, 48), counter.metrics.peak_live_bytes);
    try std.testing.expectEqual(@as(usize, 0), counter.metrics.leakBytes());
}

test "CountingAllocator exposes intentional copy overhead" {
    var baseline = CountingAllocator.init(std.testing.allocator);
    const base_allocator = baseline.allocator();
    const base = try base_allocator.dupe(u8, "fixture");
    base_allocator.free(base);

    var candidate = CountingAllocator.init(std.testing.allocator);
    const candidate_allocator = candidate.allocator();
    const original = try candidate_allocator.dupe(u8, "fixture");
    const copy = try candidate_allocator.dupe(u8, original);
    candidate_allocator.free(copy);
    candidate_allocator.free(original);

    try std.testing.expect(candidate.metrics.allocated_bytes > baseline.metrics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), candidate.metrics.leakBytes());
}
