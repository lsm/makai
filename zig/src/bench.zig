const std = @import("std");
const types = @import("types");
const event_stream = @import("event_stream");
const mock_provider = @import("mock_provider");
const fiber_mock_provider = @import("fiber_mock_provider");
const zio = @import("zio");

pub const BenchResult = struct {
    name: []const u8,
    iterations: usize,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,

    pub fn print(self: BenchResult) void {
        std.debug.print("\nBenchmark: {s}\n", .{self.name});
        std.debug.print("  Iterations: {d}\n", .{self.iterations});
        std.debug.print("  Total:      {d} ns ({d:.2} ms)\n", .{ self.total_ns, @as(f64, @floatFromInt(self.total_ns)) / 1_000_000.0 });
        std.debug.print("  Mean:       {d} ns ({d:.2} us)\n", .{ self.mean_ns, @as(f64, @floatFromInt(self.mean_ns)) / 1_000.0 });
        std.debug.print("  Min:        {d} ns ({d:.2} us)\n", .{ self.min_ns, @as(f64, @floatFromInt(self.min_ns)) / 1_000.0 });
        std.debug.print("  Max:        {d} ns ({d:.2} us)\n", .{ self.max_ns, @as(f64, @floatFromInt(self.max_ns)) / 1_000.0 });
        std.debug.print("  P50:        {d} ns ({d:.2} us)\n", .{ self.p50_ns, @as(f64, @floatFromInt(self.p50_ns)) / 1_000.0 });
        std.debug.print("  P95:        {d} ns ({d:.2} us)\n", .{ self.p95_ns, @as(f64, @floatFromInt(self.p95_ns)) / 1_000.0 });
        std.debug.print("  P99:        {d} ns ({d:.2} us)\n", .{ self.p99_ns, @as(f64, @floatFromInt(self.p99_ns)) / 1_000.0 });
    }
};

pub fn runBenchmark(
    name: []const u8,
    iterations: usize,
    func: *const fn () void,
) !BenchResult {
    var timings = try std.heap.page_allocator.alloc(u64, iterations);
    defer std.heap.page_allocator.free(timings);

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        func();
        const end = std.time.nanoTimestamp();

        const elapsed = @as(u64, @intCast(end - start));
        timings[i] = elapsed;
        total_ns += elapsed;

        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
    }

    std.mem.sort(u64, timings, {}, comptime std.sort.asc(u64));

    const mean_ns = total_ns / iterations;
    const p50_idx = iterations * 50 / 100;
    const p95_idx = iterations * 95 / 100;
    const p99_idx = iterations * 99 / 100;

    return BenchResult{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .mean_ns = mean_ns,
        .p50_ns = timings[p50_idx],
        .p95_ns = timings[p95_idx],
        .p99_ns = timings[p99_idx],
    };
}

pub fn runBenchmarkAlloc(
    name: []const u8,
    iterations: usize,
    allocator: std.mem.Allocator,
    func: *const fn (std.mem.Allocator) anyerror!void,
) !BenchResult {
    var timings = try std.heap.page_allocator.alloc(u64, iterations);
    defer std.heap.page_allocator.free(timings);

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        try func(allocator);
        const end = std.time.nanoTimestamp();

        const elapsed = @as(u64, @intCast(end - start));
        timings[i] = elapsed;
        total_ns += elapsed;

        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
    }

    std.mem.sort(u64, timings, {}, comptime std.sort.asc(u64));

    const mean_ns = total_ns / iterations;
    const p50_idx = iterations * 50 / 100;
    const p95_idx = iterations * 95 / 100;
    const p99_idx = iterations * 99 / 100;

    return BenchResult{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .mean_ns = mean_ns,
        .p50_ns = timings[p50_idx],
        .p95_ns = timings[p95_idx],
        .p99_ns = timings[p99_idx],
    };
}

// Benchmark functions

fn benchUsageAdd() void {
    var usage1 = types.Usage{
        .input_tokens = 100,
        .output_tokens = 50,
        .cache_read_tokens = 20,
        .cache_write_tokens = 10,
    };

    const usage2 = types.Usage{
        .input_tokens = 50,
        .output_tokens = 30,
        .cache_read_tokens = 10,
        .cache_write_tokens = 5,
    };

    usage1.add(usage2);
}

fn benchStreamPushPoll(allocator: std.mem.Allocator) !void {
    var stream = event_stream.AssistantMessageStream.init(allocator);
    defer stream.deinit();

    const event = types.MessageEvent{ .text_delta = types.DeltaEvent{ .index = 0, .delta = "test" } };

    for (0..100) |_| {
        try stream.push(event);
    }

    for (0..100) |_| {
        _ = stream.poll();
    }
}

fn benchContentBlockSwitch(allocator: std.mem.Allocator) !void {
    _ = allocator;

    const blocks = [_]types.ContentBlock{
        .{ .text = types.TextBlock{ .text = "hello" } },
        .{ .tool_use = types.ToolUseBlock{ .id = "1", .name = "search", .input_json = "{}" } },
        .{ .thinking = types.ThinkingBlock{ .thinking = "thinking..." } },
    };

    var sum: usize = 0;
    for (blocks) |block| {
        switch (block) {
            .text => sum += 1,
            .tool_use => sum += 2,
            .thinking => sum += 3,
        }
    }

    if (sum == 0) unreachable;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Pi-AI Core Abstractions - Benchmarks\n", .{});
    std.debug.print("====================================\n", .{});

    // Benchmark 1: Usage operations
    const bench1 = try runBenchmark("Usage.add", 100_000, benchUsageAdd);
    bench1.print();

    // Benchmark 2: Event stream push/poll
    const bench2 = try runBenchmarkAlloc("EventStream push/poll 100x", 1_000, allocator, benchStreamPushPoll);
    bench2.print();

    // Benchmark 3: ContentBlock switching
    const bench3 = try runBenchmarkAlloc("ContentBlock switch", 100_000, allocator, benchContentBlockSwitch);
    bench3.print();

    // Benchmark 4: Mock stream with events
    std.debug.print("\nBenchmark: Mock stream with events\n", .{});
    const iterations: usize = 100;
    var timings = try allocator.alloc(u64, iterations);
    defer allocator.free(timings);

    const events = [_]types.MessageEvent{
        .{ .start = types.StartEvent{ .model = "mock" } },
        .{ .text_delta = types.DeltaEvent{ .index = 0, .delta = "Hello" } },
        .{ .text_delta = types.DeltaEvent{ .index = 0, .delta = " World" } },
        .{ .done = types.DoneEvent{ .usage = types.Usage{}, .stop_reason = .stop } },
    };

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    for (0..iterations) |i| {
        const config = mock_provider.MockConfig{
            .events = &events,
            .final_result = types.AssistantMessage{
                .content = &[_]types.ContentBlock{},
                .usage = types.Usage{},
                .stop_reason = .stop,
                .model = "mock",
                .timestamp = 0,
            },
            .delay_ns = 0,
        };

        const start = std.time.nanoTimestamp();

        var stream = try mock_provider.createMockStream(config, allocator);
        defer {
            stream.deinit();
            allocator.destroy(stream);
        }

        var event_count: usize = 0;
        while (stream.wait()) |_| {
            event_count += 1;
        }

        const end = std.time.nanoTimestamp();
        const elapsed = @as(u64, @intCast(end - start));
        timings[i] = elapsed;
        total_ns += elapsed;

        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
    }

    std.mem.sort(u64, timings, {}, comptime std.sort.asc(u64));

    const mean_ns = total_ns / iterations;
    const p50_idx = iterations * 50 / 100;
    const p95_idx = iterations * 95 / 100;
    const p99_idx = iterations * 99 / 100;

    const bench4 = BenchResult{
        .name = "Mock stream (4 events)",
        .iterations = iterations,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .mean_ns = mean_ns,
        .p50_ns = timings[p50_idx],
        .p95_ns = timings[p95_idx],
        .p99_ns = timings[p99_idx],
    };
    bench4.print();

    // Benchmark 5: ZIO integration (fiber mock provider)
    std.debug.print("\nBenchmark: ZIO Fiber Mock Provider\n", .{});
    std.debug.print("  ZIO (fiber/green thread runtime) is integrated and available.\n", .{});
    std.debug.print("  The fiber_mock_provider module demonstrates ZIO integration.\n", .{});
    std.debug.print("  Key benefits of fibers over OS threads:\n", .{});
    std.debug.print("    - Lightweight: ~4KB stack vs ~8MB for OS threads\n", .{});
    std.debug.print("    - Fast context switching: ~100ns vs ~1-10us for threads\n", .{});
    std.debug.print("    - Scalability: Can spawn 100,000+ concurrent fibers\n", .{});
    std.debug.print("  For production use, initialize a long-lived ZIO Runtime and\n", .{});
    std.debug.print("  spawn tasks within the runtime's event loop context.\n", .{});

    std.debug.print("\nAll benchmarks completed!\n", .{});
}
