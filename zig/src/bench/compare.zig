const std = @import("std");
const compat = @import("compat");

const Report = struct {
    schema_version: u32,
    git_revision: []const u8,
    host_class: []const u8,
    target: []const u8,
    cpu_model: []const u8,
    cpu_features_hash: u64,
    zig_version: []const u8,
    optimize: []const u8,
    mode: []const u8,
    workload: []const u8,
    fixture_version: u32,
    iterations: usize,
    samples: usize,
    completed_per_iteration: usize,
    digest: u64,
    raw_samples_ns: []const u64,
    ns_per_iteration: u64,
    latency_p50_ns: u64,
    latency_p95_ns: u64,
    latency_p99_ns: u64,
    allocation_count: ?usize,
    free_count: ?usize,
    allocated_bytes: ?usize,
    freed_bytes: ?usize,
    peak_live_bytes: ?usize,
    leak_bytes: ?usize,
};

const LatencyStats = struct { p50: u64, p95: u64, p99: u64 };

fn latencyStats(allocator: std.mem.Allocator, report: Report) !LatencyStats {
    var values = try allocator.alloc(u64, report.raw_samples_ns.len);
    defer allocator.free(values);
    for (report.raw_samples_ns, 0..) |elapsed, i| values[i] = elapsed / report.iterations + @intFromBool(elapsed % report.iterations != 0);
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    const at = struct {
        fn percentile(sorted: []const u64, numerator: usize) u64 {
            const rank = (sorted.len * numerator + 99) / 100;
            return sorted[@max(rank, 1) - 1];
        }
    }.percentile;
    return .{ .p50 = at(values, 50), .p95 = at(values, 95), .p99 = at(values, 99) };
}

fn validate(report: Report) !void {
    if (report.schema_version != 1 or report.git_revision.len == 0 or report.iterations == 0 or report.samples == 0 or report.raw_samples_ns.len != report.samples or report.ns_per_iteration == 0) return error.InvalidReport;
    const metrics = [_]?usize{ report.allocation_count, report.free_count, report.allocated_bytes, report.freed_bytes, report.peak_live_bytes, report.leak_bytes };
    if (std.mem.eql(u8, report.mode, "allocation")) {
        for (metrics) |metric| if (metric == null) return error.InvalidReport;
        if (report.leak_bytes.? != 0) return error.InvalidReport;
    } else if (std.mem.eql(u8, report.mode, "latency")) {
        for (metrics) |metric| if (metric != null) return error.InvalidReport;
    } else return error.InvalidReport;
}

fn expectCompatible(baseline: Report, candidate: Report) !void {
    try validate(baseline);
    try validate(candidate);
    if (baseline.schema_version != candidate.schema_version or
        baseline.fixture_version != candidate.fixture_version or
        baseline.iterations != candidate.iterations or
        baseline.samples != candidate.samples or
        baseline.completed_per_iteration != candidate.completed_per_iteration or
        !std.mem.eql(u8, baseline.host_class, candidate.host_class) or
        !std.mem.eql(u8, baseline.target, candidate.target) or
        !std.mem.eql(u8, baseline.cpu_model, candidate.cpu_model) or
        baseline.cpu_features_hash != candidate.cpu_features_hash or
        !std.mem.eql(u8, baseline.zig_version, candidate.zig_version) or
        !std.mem.eql(u8, baseline.optimize, candidate.optimize) or
        !std.mem.eql(u8, baseline.mode, candidate.mode) or
        !std.mem.eql(u8, baseline.workload, candidate.workload)) return error.IncompatibleReports;
    if ((baseline.allocated_bytes == null) != (candidate.allocated_bytes == null)) return error.IncompatibleReports;
    if (baseline.digest != candidate.digest) return error.SemanticMismatch;
}

fn workloadIndex(workload: []const u8) !usize {
    if (std.mem.eql(u8, workload, "sse_parse")) return 0;
    if (std.mem.eql(u8, workload, "transport_round_trip")) return 1;
    return error.InvalidReport;
}

fn compareLine(allocator: std.mem.Allocator, baseline_line: []const u8, candidate_line: []const u8) !usize {
    const baseline = try std.json.parseFromSlice(Report, allocator, baseline_line, .{ .ignore_unknown_fields = false });
    defer baseline.deinit();
    const candidate = try std.json.parseFromSlice(Report, allocator, candidate_line, .{ .ignore_unknown_fields = false });
    defer candidate.deinit();
    try expectCompatible(baseline.value, candidate.value);
    const baseline_latency = try latencyStats(allocator, baseline.value);
    const candidate_latency = try latencyStats(allocator, candidate.value);
    if (baseline_latency.p50 != baseline.value.latency_p50_ns or baseline_latency.p95 != baseline.value.latency_p95_ns or baseline_latency.p99 != baseline.value.latency_p99_ns or
        candidate_latency.p50 != candidate.value.latency_p50_ns or candidate_latency.p95 != candidate.value.latency_p95_ns or candidate_latency.p99 != candidate.value.latency_p99_ns) return error.InvalidReport;

    const allocation_change: ?f64 = if (baseline.value.allocated_bytes) |baseline_bytes| blk: {
        const candidate_bytes = candidate.value.allocated_bytes orelse return error.IncompatibleReports;
        const work = baseline.value.completed_per_iteration;
        if (work == 0) return error.InvalidReport;
        const baseline_per_work = @as(f64, @floatFromInt(baseline_bytes)) / @as(f64, @floatFromInt(work));
        const candidate_per_work = @as(f64, @floatFromInt(candidate_bytes)) / @as(f64, @floatFromInt(work));
        break :blk if (baseline_per_work == 0) null else (candidate_per_work / baseline_per_work - 1) * 100;
    } else null;

    const p50_change = (@as(f64, @floatFromInt(candidate_latency.p50)) / @as(f64, @floatFromInt(baseline_latency.p50)) - 1) * 100;
    const p95_change = (@as(f64, @floatFromInt(candidate_latency.p95)) / @as(f64, @floatFromInt(baseline_latency.p95)) - 1) * 100;
    const p99_change = (@as(f64, @floatFromInt(candidate_latency.p99)) / @as(f64, @floatFromInt(baseline_latency.p99)) - 1) * 100;
    const allocation_text = if (baseline.value.allocated_bytes) |baseline_bytes|
        if (baseline_bytes == 0 and candidate.value.allocated_bytes.? > 0)
            try allocator.dupe(u8, "introduced")
        else if (allocation_change) |change|
            try std.fmt.allocPrint(allocator, "{d:.2}%", .{change})
        else
            try allocator.dupe(u8, "0.00%")
    else
        try allocator.dupe(u8, "unavailable");
    defer allocator.free(allocation_text);
    const output = try std.fmt.allocPrint(allocator, "{s}: latency p50 {d:.2}%, p95 {d:.2}%, p99 {d:.2}%; allocated bytes/work {s}\n", .{ baseline.value.workload, p50_change, p95_change, p99_change, allocation_text });
    defer allocator.free(output);
    try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), output);
    return workloadIndex(baseline.value.workload);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len != 3) return error.Usage;
    const baseline_data = try compat.fs.readFileAlloc(allocator, compat.fs.getCwd(), args[1], 1024 * 1024);
    defer allocator.free(baseline_data);
    const candidate_data = try compat.fs.readFileAlloc(allocator, compat.fs.getCwd(), args[2], 1024 * 1024);
    defer allocator.free(candidate_data);

    var baseline_lines = std.mem.tokenizeScalar(u8, baseline_data, '\n');
    var candidate_lines = std.mem.tokenizeScalar(u8, candidate_data, '\n');
    var seen = [_]bool{ false, false };
    while (baseline_lines.next()) |baseline_line| {
        const candidate_line = candidate_lines.next() orelse return error.IncompatibleReports;
        const workload_index = try compareLine(allocator, baseline_line, candidate_line);
        if (seen[workload_index]) return error.InvalidReport;
        seen[workload_index] = true;
    }
    if (candidate_lines.next() != null) return error.IncompatibleReports;
    if (!seen[0] or !seen[1]) return error.InvalidReport;
}

test "comparison rejects incompatible identity" {
    const samples = [_]u64{100};
    const baseline: Report = .{
        .schema_version = 1,
        .git_revision = "abc123",
        .host_class = "ci-arm64",
        .target = "aarch64-linux",
        .cpu_model = "generic",
        .cpu_features_hash = 7,
        .zig_version = "0.16.0",
        .optimize = "ReleaseFast",
        .mode = "allocation",
        .workload = "sse_parse",
        .fixture_version = 1,
        .iterations = 10,
        .samples = 1,
        .completed_per_iteration = 3,
        .digest = 42,
        .raw_samples_ns = &samples,
        .ns_per_iteration = 10,
        .latency_p50_ns = 10,
        .latency_p95_ns = 10,
        .latency_p99_ns = 10,
        .allocation_count = 1,
        .free_count = 1,
        .allocated_bytes = 12,
        .freed_bytes = 12,
        .peak_live_bytes = 12,
        .leak_bytes = 0,
    };
    var candidate = baseline;
    try expectCompatible(baseline, candidate);
    candidate.target = "x86_64-linux";
    try std.testing.expectError(error.IncompatibleReports, expectCompatible(baseline, candidate));

    candidate = baseline;
    candidate.leak_bytes = 1;
    try std.testing.expectError(error.InvalidReport, expectCompatible(baseline, candidate));
    candidate = baseline;
    candidate.leak_bytes = null;
    try std.testing.expectError(error.InvalidReport, expectCompatible(baseline, candidate));
    candidate = baseline;
    candidate.mode = "latency";
    try std.testing.expectError(error.InvalidReport, expectCompatible(baseline, candidate));
    candidate = baseline;
    candidate.schema_version = 2;
    try std.testing.expectError(error.InvalidReport, expectCompatible(baseline, candidate));
}
