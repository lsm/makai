const std = @import("std");
const ai_types = @import("ai_types");
const common = @import("tools/common");

pub const ProcessResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8, cwd: std.process.Child.Cwd, timeout_ms: u64, cancel_token: ?ai_types.CancelToken) !ProcessResult {
    if (common.isCancelled(cancel_token)) return error.Cancelled;
    const io = common.defaultIo();
    const start_ms = common.nowMs();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    });
    defer child.kill(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const poll_timeout: std.Io.Timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(common.process_poll_ms), .clock = .boot } };

    while (true) {
        if (common.isCancelled(cancel_token)) return error.Cancelled;
        if (common.durationMs(start_ms) >= timeout_ms) return error.Timeout;
        multi_reader.fill(64, poll_timeout) catch |err| switch (err) {
            error.Timeout => continue,
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (stdout_reader.buffered().len > common.process_output_bytes) return error.StreamTooLong;
        if (stderr_reader.buffered().len > common.process_output_bytes) return error.StreamTooLong;
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    errdefer allocator.free(stderr);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

test "process runner honors cancellation" {
    var cancelled = std.atomic.Value(bool).init(true);
    const token = ai_types.CancelToken{ .cancelled = &cancelled };
    const argv = if (@import("builtin").os.tag == .windows)
        [_][]const u8{ "cmd.exe", "/C", "ping -n 3 127.0.0.1 >NUL" }
    else
        [_][]const u8{ "/bin/sh", "-c", "sleep 2" };
    try std.testing.expectError(error.Cancelled, run(std.testing.allocator, &argv, .inherit, 5_000, token));
}

test "process runner captures output beyond small std process defaults" {
    const argv = if (@import("builtin").os.tag == .windows)
        [_][]const u8{ "cmd.exe", "/C", "powershell -NoProfile -Command \"[Console]::Out.Write(('x' * 70000))\"" }
    else
        [_][]const u8{ "/bin/sh", "-c", "yes x | head -c 70000" };
    const result = try run(std.testing.allocator, &argv, .inherit, 5_000, null);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.stdout.len >= 70_000);
}
