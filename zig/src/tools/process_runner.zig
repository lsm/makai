const std = @import("std");
const builtin = @import("builtin");
const ai_types = @import("ai_types");
const common = @import("tools/common");

pub const ProcessResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8, cwd: std.process.Child.Cwd, timeout_ms: u64, cancel_token: ?ai_types.CancelToken) !ProcessResult {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    return runWithIo(allocator, threaded.io(), argv, cwd, timeout_ms, cancel_token);
}

fn runWithIo(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: std.process.Child.Cwd, timeout_ms: u64, cancel_token: ?ai_types.CancelToken) !ProcessResult {
    if (common.isCancelled(cancel_token)) return error.Cancelled;
    const start_ms = common.nowMs();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    });
    defer cleanupChild(&child, io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const poll_timeout: std.Io.Timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(common.process_poll_ms), .clock = .boot } };

    var pipes_closed = false;
    var term: ?std.process.Child.Term = null;
    while (true) {
        if (common.isCancelled(cancel_token)) return error.Cancelled;
        if (common.durationMs(start_ms) >= timeout_ms) return error.Timeout;
        if (term == null) term = try pollTerm(&child, io);
        if (!pipes_closed) {
            multi_reader.fill(64, poll_timeout) catch |err| switch (err) {
                error.Timeout => {
                    if (term) |t| return finish(allocator, &multi_reader, t, false);
                },
                error.EndOfStream => pipes_closed = true,
                else => |e| return e,
            };
            if (stdout_reader.buffered().len > common.process_output_bytes) return error.StreamTooLong;
            if (stderr_reader.buffered().len > common.process_output_bytes) return error.StreamTooLong;
        } else io.sleep(.fromMilliseconds(common.process_poll_ms), .boot) catch {};
        if (term) |t| if (pipes_closed) return finish(allocator, &multi_reader, t, true);
    }
}

fn cleanupChild(child: *std.process.Child, io: std.Io) void {
    if (child.id != null) child.kill(io);
    if (child.stdin) |stdin| {
        stdin.close(io);
        child.stdin = null;
    }
    if (child.stdout) |stdout| {
        stdout.close(io);
        child.stdout = null;
    }
    if (child.stderr) |stderr| {
        stderr.close(io);
        child.stderr = null;
    }
}

fn finish(allocator: std.mem.Allocator, multi_reader: *std.Io.File.MultiReader, term: std.process.Child.Term, check_errors: bool) !ProcessResult {
    if (check_errors) try multi_reader.checkAnyError();
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    errdefer allocator.free(stderr);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

fn pollTerm(child: *std.process.Child, io: std.Io) !?std.process.Child.Term {
    if (builtin.os.tag == .windows) return pollTermWindows(child, io);
    return pollTermPosix(child);
}

fn pollTermPosix(child: *std.process.Child) !?std.process.Child.Term {
    if (child.id == null) return null;
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    const pid = child.id.?;
    while (true) {
        const result = std.posix.system.waitpid(pid, &status, std.posix.W.NOHANG);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                if (result == 0) return null;
                child.id = null;
                return statusToTerm(@bitCast(status));
            },
            .INTR => continue,
            .CHILD => return null,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn statusToTerm(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .unknown = status };
}

fn pollTermWindows(child: *std.process.Child, io: std.Io) !?std.process.Child.Term {
    if (child.id == null) return null;
    const windows = std.os.windows;
    const handle = child.id.?;
    const minimal_timeout: windows.LARGE_INTEGER = -1;
    return switch (windows.ntdll.NtWaitForSingleObject(handle, .FALSE, &minimal_timeout)) {
        windows.NTSTATUS.WAIT_0 => {
            var info: windows.PROCESS.BASIC_INFORMATION = undefined;
            const term: std.process.Child.Term = switch (windows.ntdll.NtQueryInformationProcess(
                handle,
                .BasicInformation,
                &info,
                @sizeOf(windows.PROCESS.BASIC_INFORMATION),
                null,
            )) {
                .SUCCESS => .{ .exited = @as(u8, @truncate(@intFromEnum(info.ExitStatus))) },
                else => .{ .unknown = 0 },
            };
            windows.CloseHandle(handle);
            child.id = null;
            windows.CloseHandle(child.thread_handle);
            child.thread_handle = undefined;
            if (child.stdin) |stdin| {
                stdin.close(io);
                child.stdin = null;
            }
            return term;
        },
        .TIMEOUT => null,
        else => |status| return windows.unexpectedStatus(status),
    };
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

test "process runner spawns with initialized threaded io" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var dir = try common.openWorkspace("/", false);
    defer dir.close(common.defaultIo());

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const argv = [_][]const u8{ "/bin/sh", "-c", "[ \"$(pwd)\" = / ] && ls -al >/dev/null && printf ok" };
    const result = try runWithIo(std.testing.allocator, threaded.io(), &argv, .{ .dir = dir }, 10_000, null);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqualStrings("ok", result.stdout);
}

test "process runner captures output beyond small std process defaults" {
    const argv = if (@import("builtin").os.tag == .windows)
        [_][]const u8{ "cmd.exe", "/C", "powershell -NoProfile -Command \"[Console]::Out.Write(('x' * 70000))\"" }
    else
        [_][]const u8{ "/bin/sh", "-c", "python3 - <<'PY'\nimport sys\nsys.stdout.write('x' * 70000)\nPY" };
    const result = try run(std.testing.allocator, &argv, .inherit, 5_000, null);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.stdout.len >= 70_000);
}

test "process runner returns after child exits with inherited background pipe" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const argv = [_][]const u8{ "/bin/sh", "-c", "sleep 2 &" };
    const result = try run(std.testing.allocator, &argv, .inherit, 1_000, null);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "process runner enforces timeout after pipe eof" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const argv = [_][]const u8{ "/bin/sh", "-c", "exec >/dev/null 2>&1; sleep 2" };
    try std.testing.expectError(error.Timeout, run(std.testing.allocator, &argv, .inherit, 100, null));
}
