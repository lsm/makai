const std = @import("std");
const zio = @import("zio");

const BenchResult = struct {
    name: []const u8,
    iterations: usize,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    median_ns: u64,
    p95_ns: u64,
    p99_ns: u64,

    fn print(self: BenchResult) void {
        std.debug.print("\n{s}\n", .{self.name});
        std.debug.print("  Iterations: {d}\n", .{self.iterations});
        std.debug.print("  Total:      {d} ns ({d:.2} ms)\n", .{
            self.total_ns,
            @as(f64, @floatFromInt(self.total_ns)) / 1_000_000.0,
        });
        std.debug.print("  Mean:       {d} ns ({d:.2} us)\n", .{
            self.mean_ns,
            @as(f64, @floatFromInt(self.mean_ns)) / 1_000.0,
        });
        std.debug.print("  Min:        {d} ns ({d:.2} us)\n", .{
            self.min_ns,
            @as(f64, @floatFromInt(self.min_ns)) / 1_000.0,
        });
        std.debug.print("  Max:        {d} ns ({d:.2} us)\n", .{
            self.max_ns,
            @as(f64, @floatFromInt(self.max_ns)) / 1_000.0,
        });
        std.debug.print("  Median:     {d} ns ({d:.2} us)\n", .{
            self.median_ns,
            @as(f64, @floatFromInt(self.median_ns)) / 1_000.0,
        });
        std.debug.print("  P95:        {d} ns ({d:.2} us)\n", .{
            self.p95_ns,
            @as(f64, @floatFromInt(self.p95_ns)) / 1_000.0,
        });
        std.debug.print("  P99:        {d} ns ({d:.2} us)\n", .{
            self.p99_ns,
            @as(f64, @floatFromInt(self.p99_ns)) / 1_000.0,
        });
    }
};

fn calculateStats(timings: []u64) BenchResult {
    var total: u64 = 0;
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;

    for (timings) |t| {
        total += t;
        if (t < min) min = t;
        if (t > max) max = t;
    }

    std.mem.sort(u64, timings, {}, comptime std.sort.asc(u64));

    const mean = total / timings.len;
    const median_idx = timings.len / 2;
    const p95_idx = (timings.len * 95) / 100;
    const p99_idx = (timings.len * 99) / 100;

    return BenchResult{
        .name = "",
        .iterations = timings.len,
        .total_ns = total,
        .min_ns = min,
        .max_ns = max,
        .mean_ns = mean,
        .median_ns = timings[median_idx],
        .p95_ns = timings[p95_idx],
        .p99_ns = timings[p99_idx],
    };
}

// Mock event structure - simulates pushing 4 events
const MockEvent = struct {
    index: usize,
    data: []const u8,
};

const Counter = struct {
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn increment(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    fn get(self: *Counter) u64 {
        return self.value.load(.monotonic);
    }

    fn reset(self: *Counter) void {
        self.value.store(0, .monotonic);
    }
};

// Simulates a mock stream fiber that pushes 4 events
fn mockStreamFiber(counter: *Counter) !void {
    // Simulate pushing 4 events (like Go's mock provider)
    const events = [_]MockEvent{
        .{ .index = 0, .data = "start" },
        .{ .index = 1, .data = "Hello" },
        .{ .index = 2, .data = " World" },
        .{ .index = 3, .data = "done" },
    };

    for (events) |_| {
        // Simulate minimal event processing
        counter.increment();
    }
}

// Thread worker for comparison
fn threadWorker(counter: *Counter) void {
    const events = [_]MockEvent{
        .{ .index = 0, .data = "start" },
        .{ .index = 1, .data = "Hello" },
        .{ .index = 2, .data = " World" },
        .{ .index = 3, .data = "done" },
    };

    for (events) |_| {
        counter.increment();
    }
}

// Benchmark: Shared ZIO Runtime (like Go's shared scheduler)
fn benchmarkSharedRuntime(allocator: std.mem.Allocator, n_streams: usize) !BenchResult {
    var timings = try allocator.alloc(u64, n_streams);
    defer allocator.free(timings);

    // Create ONE runtime - like Go's runtime
    const rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    var counter = Counter{};
    var group: zio.Group = .init;
    defer group.cancel();

    // Measure the overhead of spawning each fiber into the shared runtime
    for (0..n_streams) |i| {
        const start = std.time.nanoTimestamp();

        // Spawn fiber into shared runtime
        try group.spawn(mockStreamFiber, .{&counter});

        const end = std.time.nanoTimestamp();
        timings[i] = @intCast(end - start);
    }

    // Wait for all fibers to complete
    try group.wait();

    var result = calculateStats(timings);
    result.name = "ZIO Shared Runtime (fiber spawn)";
    return result;
}

// Benchmark: New Runtime Per Stream (current mock_provider approach)
fn benchmarkNewRuntimePerStream(allocator: std.mem.Allocator, n_streams: usize) !BenchResult {
    var timings = try allocator.alloc(u64, n_streams);
    defer allocator.free(timings);

    var counter = Counter{};

    for (0..n_streams) |i| {
        const start = std.time.nanoTimestamp();

        // Create NEW runtime for each stream
        const rt = try zio.Runtime.init(allocator, .{});
        defer rt.deinit();

        var group: zio.Group = .init;
        defer group.cancel();

        try group.spawn(mockStreamFiber, .{&counter});
        try group.wait();

        const end = std.time.nanoTimestamp();
        timings[i] = @intCast(end - start);
    }

    var result = calculateStats(timings);
    result.name = "ZIO New Runtime Per Stream (current)";
    return result;
}

// Benchmark: OS Threads for comparison
fn benchmarkOSThreads(allocator: std.mem.Allocator, n_threads: usize) !BenchResult {
    var timings = try allocator.alloc(u64, n_threads);
    defer allocator.free(timings);

    var counter = Counter{};
    var threads = try allocator.alloc(std.Thread, n_threads);
    defer allocator.free(threads);

    for (0..n_threads) |i| {
        const start = std.time.nanoTimestamp();

        threads[i] = try std.Thread.spawn(.{}, threadWorker, .{&counter});

        const end = std.time.nanoTimestamp();
        timings[i] = @intCast(end - start);
    }

    for (threads) |thread| {
        thread.join();
    }

    var result = calculateStats(timings);
    result.name = "OS Thread Spawn";
    return result;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("=======================================================\n", .{});
    std.debug.print("   Shared ZIO Runtime Benchmark (Like Go's Scheduler)\n", .{});
    std.debug.print("=======================================================\n", .{});

    const n_streams = 1000;

    std.debug.print("\nBenchmarking {d} mock streams (4 events each)\n", .{n_streams});
    std.debug.print("Each stream simulates: start, text_delta, text_delta, done\n", .{});

    std.debug.print("\n=== 1. Shared ZIO Runtime (Recommended Pattern) ===\n", .{});
    std.debug.print("Pattern: ONE runtime at startup, spawn fibers into it\n", .{});
    std.debug.print("This mimics Go's goroutine scheduler\n", .{});

    const shared_result = try benchmarkSharedRuntime(allocator, n_streams);
    shared_result.print();

    std.debug.print("\n=== 2. New Runtime Per Stream (Current Approach) ===\n", .{});
    std.debug.print("Pattern: Create runtime for each stream (adds overhead)\n", .{});

    const new_runtime_result = try benchmarkNewRuntimePerStream(allocator, n_streams);
    new_runtime_result.print();

    std.debug.print("\n=== 3. OS Threads (Traditional Concurrency) ===\n", .{});

    const thread_result = try benchmarkOSThreads(allocator, n_streams);
    thread_result.print();

    std.debug.print("\n=== Comparison ===\n", .{});

    const go_mock_stream_us: f64 = 2.7;
    std.debug.print("\nGo Mock Stream (reference): {d:.2} us\n", .{go_mock_stream_us});

    const shared_us = @as(f64, @floatFromInt(shared_result.mean_ns)) / 1_000.0;
    const new_runtime_us = @as(f64, @floatFromInt(new_runtime_result.mean_ns)) / 1_000.0;
    const thread_us = @as(f64, @floatFromInt(thread_result.mean_ns)) / 1_000.0;

    std.debug.print("\nShared Runtime vs Go:\n", .{});
    std.debug.print("  ZIO (shared):   {d:.2} us\n", .{shared_us});
    std.debug.print("  Go (goroutine): {d:.2} us\n", .{go_mock_stream_us});
    std.debug.print("  Ratio:          {d:.2}x ", .{shared_us / go_mock_stream_us});
    if (shared_us < go_mock_stream_us) {
        std.debug.print("(ZIO FASTER)\n", .{});
    } else {
        std.debug.print("(Go faster)\n", .{});
    }

    std.debug.print("\nRuntime Creation Overhead:\n", .{});
    const overhead_us = new_runtime_us - shared_us;
    std.debug.print("  Per-stream overhead: {d:.2} us\n", .{overhead_us});
    std.debug.print("  Speedup with shared: {d:.2}x faster\n", .{new_runtime_us / shared_us});

    std.debug.print("\nFibers vs OS Threads:\n", .{});
    std.debug.print("  Fiber spawn:  {d:.2} us\n", .{shared_us});
    std.debug.print("  Thread spawn: {d:.2} us\n", .{thread_us});
    std.debug.print("  Speedup:      {d:.2}x faster with fibers\n", .{thread_us / shared_us});

    std.debug.print("\n=== Key Insights ===\n", .{});
    std.debug.print("\n1. Shared Runtime Pattern (like Go):\n", .{});
    std.debug.print("   - Create ONE ZIO runtime at application startup\n", .{});
    std.debug.print("   - Spawn all fibers into this shared runtime\n", .{});
    std.debug.print("   - Overhead: ~{d:.2} us per fiber (fiber spawn only)\n", .{shared_us});
    std.debug.print("\n2. Current Approach (new runtime per stream):\n", .{});
    std.debug.print("   - Creates runtime initialization overhead\n", .{});
    std.debug.print("   - Overhead: ~{d:.2} us per stream (runtime + fiber)\n", .{new_runtime_us});
    std.debug.print("   - Extra cost: ~{d:.2} us per stream\n", .{overhead_us});
    std.debug.print("\n3. Recommendation:\n", .{});
    std.debug.print("   - Use shared runtime pattern for production\n", .{});
    std.debug.print("   - Store runtime in application state\n", .{});
    std.debug.print("   - Pass runtime reference to provider functions\n", .{});
    std.debug.print("\n", .{});
}
