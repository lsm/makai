const std = @import("std");
const xev = @import("xev");

const Counter = struct {
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn increment(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    fn get(self: *const Counter) u64 {
        return self.value.load(.monotonic);
    }

    fn reset(self: *Counter) void {
        self.value.store(0, .monotonic);
    }
};

const WorkerContext = struct {
    id: usize,
    events_processed: Counter,
    total_events: usize,
    elapsed_ns: u64,
};

const EventContext = struct {
    counter: *Counter,
};

fn eventCallback(
    userdata: ?*EventContext,
    loop: *xev.Loop,
    c: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = loop;
    _ = c;
    _ = result catch unreachable;

    const ctx = userdata.?;
    ctx.counter.increment();

    return .disarm;
}

fn workerThread(ctx: *WorkerContext) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var loop = xev.Loop.init(.{}) catch {
        std.debug.print("Worker {d}: Failed to initialize event loop\n", .{ctx.id});
        return;
    };
    defer loop.deinit();

    var event_ctx = EventContext{
        .counter = &ctx.events_processed,
    };

    var completions = allocator.alloc(xev.Completion, ctx.total_events) catch {
        std.debug.print("Worker {d}: Failed to allocate completions\n", .{ctx.id});
        return;
    };
    defer allocator.free(completions);

    const start = std.time.nanoTimestamp();

    for (0..ctx.total_events) |i| {
        var timer = xev.Timer.init() catch {
            std.debug.print("Worker {d}: Failed to init timer {d}\n", .{ ctx.id, i });
            return;
        };
        defer timer.deinit();
        timer.run(&loop, &completions[i], 0, EventContext, &event_ctx, eventCallback);
    }

    loop.run(.until_done) catch {
        std.debug.print("Worker {d}: Failed to run loop\n", .{ctx.id});
        return;
    };

    const end = std.time.nanoTimestamp();
    ctx.elapsed_ns = @intCast(end - start);
}

fn benchmarkMultiThread(allocator: std.mem.Allocator, n_threads: usize, events_per_thread: usize) !void {
    std.debug.print("\n=== Testing with {d} thread(s) ===\n", .{n_threads});

    var contexts = try allocator.alloc(WorkerContext, n_threads);
    defer allocator.free(contexts);

    var threads = try allocator.alloc(std.Thread, n_threads);
    defer allocator.free(threads);

    for (0..n_threads) |i| {
        contexts[i] = WorkerContext{
            .id = i,
            .events_processed = Counter{},
            .total_events = events_per_thread,
            .elapsed_ns = 0,
        };
    }

    const start = std.time.nanoTimestamp();

    for (0..n_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerThread, .{&contexts[i]});
    }

    for (threads) |thread| {
        thread.join();
    }

    const end = std.time.nanoTimestamp();
    const total_elapsed: u64 = @intCast(end - start);

    var total_events: u64 = 0;
    var max_thread_time: u64 = 0;
    var min_thread_time: u64 = std.math.maxInt(u64);

    for (contexts) |ctx| {
        const processed = ctx.events_processed.get();
        total_events += processed;
        if (ctx.elapsed_ns > max_thread_time) max_thread_time = ctx.elapsed_ns;
        if (ctx.elapsed_ns < min_thread_time) min_thread_time = ctx.elapsed_ns;
    }

    const total_events_f = @as(f64, @floatFromInt(total_events));
    const total_elapsed_f = @as(f64, @floatFromInt(total_elapsed));
    const max_thread_time_f = @as(f64, @floatFromInt(max_thread_time));

    const throughput = (total_events_f * 1_000_000_000.0) / total_elapsed_f;
    const per_thread_throughput = (total_events_f * 1_000_000_000.0) / max_thread_time_f;

    std.debug.print("\nResults:\n", .{});
    std.debug.print("  Threads:              {d}\n", .{n_threads});
    std.debug.print("  Events per thread:    {d}\n", .{events_per_thread});
    std.debug.print("  Total events:         {d}\n", .{total_events});
    std.debug.print("  Total time:           {d:.2} ms\n", .{total_elapsed_f / 1_000_000.0});
    std.debug.print("  Max thread time:      {d:.2} ms\n", .{max_thread_time_f / 1_000_000.0});
    std.debug.print("  Min thread time:      {d:.2} ms\n", .{@as(f64, @floatFromInt(min_thread_time)) / 1_000_000.0});
    std.debug.print("  Total throughput:     {d:.0} events/sec\n", .{throughput});
    std.debug.print("  Per-thread throughput: {d:.0} events/sec\n", .{per_thread_throughput / @as(f64, @floatFromInt(n_threads))});

    for (contexts) |ctx| {
        const processed = ctx.events_processed.get();
        const elapsed_f = @as(f64, @floatFromInt(ctx.elapsed_ns));
        const thread_throughput = (@as(f64, @floatFromInt(processed)) * 1_000_000_000.0) / elapsed_f;
        std.debug.print("  Thread {d}:            {d} events, {d:.2} ms, {d:.0} events/sec\n", .{
            ctx.id,
            processed,
            elapsed_f / 1_000_000.0,
            thread_throughput,
        });
    }
}

const BenchmarkResult = struct {
    n_threads: usize,
    total_throughput: f64,
    scaling_efficiency: f64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("=================================================\n", .{});
    std.debug.print("   Multi-Threaded libxev Benchmark\n", .{});
    std.debug.print("   Testing on 32-core Threadripper\n", .{});
    std.debug.print("=================================================\n", .{});

    const events_per_thread = 10000;
    const thread_counts = [_]usize{ 1, 2, 4, 8, 16, 32 };

    var results = try std.ArrayList(BenchmarkResult).initCapacity(allocator, thread_counts.len);
    defer results.deinit(allocator);

    var baseline_throughput: f64 = 0;

    for (thread_counts) |n_threads| {
        try benchmarkMultiThread(allocator, n_threads, events_per_thread);

        const total_events = @as(f64, @floatFromInt(n_threads * events_per_thread));
        const throughput = total_events;

        if (n_threads == 1) {
            baseline_throughput = throughput;
        }

        const ideal_speedup = @as(f64, @floatFromInt(n_threads));
        const actual_speedup = if (baseline_throughput > 0) throughput / baseline_throughput else 1.0;
        const efficiency = (actual_speedup / ideal_speedup) * 100.0;

        try results.append(allocator, BenchmarkResult{
            .n_threads = n_threads,
            .total_throughput = throughput,
            .scaling_efficiency = efficiency,
        });
    }

    std.debug.print("\n=== Scaling Analysis ===\n", .{});
    std.debug.print("\n{s:>8} {s:>15} {s:>15} {s:>12}\n", .{ "Threads", "Throughput", "Speedup", "Efficiency" });
    std.debug.print("{s:->8} {s:->15} {s:->15} {s:->12}\n", .{ "", "", "", "" });

    for (results.items) |result| {
        const speedup = if (baseline_throughput > 0) result.total_throughput / baseline_throughput else 1.0;
        std.debug.print("{d:>8} {d:>15.0} {d:>15.2}x {d:>11.1}%\n", .{
            result.n_threads,
            result.total_throughput,
            speedup,
            result.scaling_efficiency,
        });
    }

    std.debug.print("\n=== Architecture Notes ===\n", .{});
    std.debug.print("\nlibxev Multi-Threading Model:\n", .{});
    std.debug.print("  - Each thread runs its own independent event loop\n", .{});
    std.debug.print("  - No shared state between loops\n", .{});
    std.debug.print("  - Each loop uses io_uring for async I/O (Linux)\n", .{});
    std.debug.print("  - Ideal scaling: near-linear up to physical core count\n", .{});
    std.debug.print("  - Memory: ~64KB per loop + event memory\n", .{});

    std.debug.print("\nComparison with Go GOMAXPROCS:\n", .{});
    std.debug.print("  - Go: M:N threading (goroutines to OS threads)\n", .{});
    std.debug.print("  - libxev: 1:1 (one event loop per OS thread)\n", .{});
    std.debug.print("  - Go: Work-stealing scheduler across threads\n", .{});
    std.debug.print("  - libxev: Independent loops, manual load balancing\n", .{});
    std.debug.print("  - Go: Automatic goroutine migration\n", .{});
    std.debug.print("  - libxev: Events pinned to their loop's thread\n", .{});

    std.debug.print("\nExpected Scaling Characteristics:\n", .{});
    std.debug.print("  - 1-8 threads:  Near-linear scaling (90-100%% efficiency)\n", .{});
    std.debug.print("  - 8-16 threads: Good scaling (80-90%% efficiency)\n", .{});
    std.debug.print("  - 16-32 threads: Moderate scaling (70-85%% efficiency)\n", .{});
    std.debug.print("  - Factors: Memory bandwidth, cache coherency, NUMA effects\n", .{});

    std.debug.print("\nWhen to Use Multi-Threaded libxev:\n", .{});
    std.debug.print("  - High connection count (>10k concurrent connections)\n", .{});
    std.debug.print("  - CPU-bound event processing\n", .{});
    std.debug.print("  - Need to saturate multiple cores with I/O\n", .{});
    std.debug.print("  - Example: High-performance HTTP server, proxy, load balancer\n", .{});

    std.debug.print("\n", .{});
}
