const std = @import("std");
const builtin = @import("builtin");
const sse = @import("sse_parser");
const in_process = @import("transports/in_process");
const counting = @import("counting_allocator");
const compat = @import("compat");

const sse_fixture =
    "event: delta\n" ++
    "data: {\"text\":\"hello\"}\n\n" ++
    "data: {\"text\":\" world\"}\n\n" ++
    "event: done\n" ++
    "data: [DONE]\n\n";
const transport_fixture = "{\"type\":\"ping\",\"sequence\":42}";

const Result = struct {
    completed: usize,
    digest: u64,
};

fn digestField(digest: *std.hash.Wyhash, tag: u8, value: ?[]const u8) void {
    digest.update(&.{tag});
    if (value) |bytes| {
        digest.update(&.{1});
        const len: u64 = bytes.len;
        digest.update(std.mem.asBytes(&len));
        digest.update(bytes);
    } else digest.update(&.{0});
}

fn runSse(allocator: std.mem.Allocator) !Result {
    var parser = sse.SSEParser.init(allocator);
    defer parser.deinit();
    var completed: usize = 0;
    var digest = std.hash.Wyhash.init(0);
    var offset: usize = 0;
    const chunks = [_]usize{ 1, 7, 3, 19, 2, 11 };
    var chunk_index: usize = 0;
    while (offset < sse_fixture.len) : (chunk_index += 1) {
        const end = @min(sse_fixture.len, offset + chunks[chunk_index % chunks.len]);
        for (try parser.feed(sse_fixture[offset..end])) |event| {
            completed += 1;
            digestField(&digest, 0xE0, event.event_type);
            digestField(&digest, 0xD0, event.data);
        }
        offset = end;
    }
    return .{ .completed = completed, .digest = digest.final() };
}

fn runTransport(allocator: std.mem.Allocator) !Result {
    var pipe = in_process.createSerializedPipe(allocator);
    defer pipe.deinit();
    var sender = pipe.clientSender();
    try sender.write(transport_fixture);
    var receiver = pipe.serverReceiver();
    const received = (try receiver.readLine(allocator)) orelse return error.MissingRoundTrip;
    defer allocator.free(received);
    if (!std.mem.eql(u8, transport_fixture, received)) return error.RoundTripMismatch;
    return .{ .completed = 1, .digest = std.hash.Wyhash.hash(0, received) };
}

fn emitWorkload(
    allocator: std.mem.Allocator,
    name: []const u8,
    iterations: usize,
    samples: usize,
    mode: []const u8,
    host_class: []const u8,
    extra_copy: bool,
    comptime workload: fn (std.mem.Allocator) anyerror!Result,
) !void {
    const stdout = std.Io.File.stdout();
    const expected = try workload(allocator);
    var raw_samples = std.ArrayList(u8).empty;
    defer raw_samples.deinit(allocator);
    var elapsed_total: u64 = 0;
    var sample_index: usize = 0;
    while (sample_index < samples) : (sample_index += 1) {
        const start_ns = try compat.time.monotonicNanos();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const result = try workload(allocator);
            if (result.completed != expected.completed or result.digest != expected.digest) return error.SemanticMismatch;
            std.mem.doNotOptimizeAway(result);
        }
        const elapsed_ns = try compat.time.monotonicNanos() - start_ns;
        elapsed_total += elapsed_ns;
        if (sample_index > 0) try raw_samples.append(allocator, ',');
        try raw_samples.print(allocator, "{d}", .{elapsed_ns});
    }

    var counter = counting.CountingAllocator.init(allocator);
    const counted_result = try workload(counter.allocator());
    if (extra_copy) {
        const copy = try counter.allocator().dupe(u8, name);
        counter.allocator().free(copy);
    }
    if (counted_result.completed != expected.completed or counted_result.digest != expected.digest) return error.SemanticMismatch;
    if (counter.metrics.leakBytes() != 0) return error.BenchmarkLeak;

    const allocation_json = if (std.mem.eql(u8, mode, "allocation"))
        try std.fmt.allocPrint(allocator, ",\"allocation_count\":{d},\"free_count\":{d},\"allocated_bytes\":{d},\"freed_bytes\":{d},\"peak_live_bytes\":{d},\"leak_bytes\":{d}", .{ counter.metrics.allocation_count, counter.metrics.free_count, counter.metrics.allocated_bytes, counter.metrics.freed_bytes, counter.metrics.peak_live_bytes, counter.metrics.leakBytes() })
    else
        try allocator.dupe(u8, ",\"allocation_count\":null,\"free_count\":null,\"allocated_bytes\":null,\"freed_bytes\":null,\"peak_live_bytes\":null,\"leak_bytes\":null");
    defer allocator.free(allocation_json);

    const cpu_features_hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&builtin.target.cpu.features));
    const line = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"host_class\":\"{s}\",\"target\":\"{s}-{s}-{s}\",\"cpu_model\":\"{s}\",\"cpu_features_hash\":{d},\"zig_version\":\"{s}\",\"optimize\":\"{s}\",\"mode\":\"{s}\",\"workload\":\"{s}\",\"fixture_version\":1,\"iterations\":{d},\"samples\":{d},\"completed_per_iteration\":{d},\"digest\":{d},\"raw_samples_ns\":[{s}],\"ns_per_iteration\":{d}{s}}}\n", .{ host_class, @tagName(builtin.target.cpu.arch), @tagName(builtin.target.os.tag), @tagName(builtin.target.abi), builtin.target.cpu.model.name, cpu_features_hash, builtin.zig_version_string, @tagName(builtin.mode), mode, name, iterations, samples, expected.completed, expected.digest, raw_samples.items, elapsed_total / samples / iterations, allocation_json });
    defer allocator.free(line);
    try stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), line);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    var mode: []const u8 = "latency";
    var host_class: []const u8 = "local";
    var extra_copy = false;
    var iterations: usize = 1000;
    var samples: usize = 5;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--mode") and i + 1 < args.len) {
            i += 1;
            mode = args[i];
        } else if (std.mem.eql(u8, args[i], "--host-class") and i + 1 < args.len) {
            i += 1;
            host_class = args[i];
        } else if (std.mem.eql(u8, args[i], "--iterations") and i + 1 < args.len) {
            i += 1;
            iterations = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--samples") and i + 1 < args.len) {
            i += 1;
            samples = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--extra-copy")) {
            extra_copy = true;
        } else return error.InvalidArgument;
    }
    if (iterations == 0 or samples == 0 or samples > 10_000) return error.InvalidArgument;
    if (!std.mem.eql(u8, mode, "latency") and !std.mem.eql(u8, mode, "allocation")) return error.InvalidMode;
    if (host_class.len == 0) return error.InvalidHostClass;
    for (host_class) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') return error.InvalidHostClass;

    try emitWorkload(allocator, "sse_parse", iterations, samples, mode, host_class, extra_copy, runSse);
    try emitWorkload(allocator, "transport_round_trip", iterations, samples, mode, host_class, extra_copy, runTransport);
}
