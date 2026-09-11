
const std = @import("std");
const ansi = @import("../terminal/ansi.zig");

pub const SnapshotError = error{
    SnapshotMismatch,
} || std.fs.File.OpenError || std.fs.File.WriteError || std.mem.Allocator.Error;

pub const Options = struct {
    strip_ansi: bool = true,
    trim_trailing_whitespace: bool = true,
};

pub fn expectSnapshot(
    allocator: std.mem.Allocator,
    path: []const u8,
    actual: []const u8,
) SnapshotError!void {
    return expectSnapshotOpts(allocator, path, actual, .{});
}

pub fn expectSnapshotOpts(
    allocator: std.mem.Allocator,
    path: []const u8,
    actual: []const u8,
    opts: Options,
) SnapshotError!void {
    const normalized = try normalize(allocator, actual, opts);
    defer allocator.free(normalized);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    const update_env = std.posix.getenv("ZIGZAG_UPDATE_SNAPSHOTS");
    const update = update_env != null and update_env.?.len > 0 and !std.mem.eql(u8, update_env.?, "0");

    if (update) {
        try writeAll(path, normalized);
        return;
    }

    const existing = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            try writeAll(path, normalized);
            return;
        },
        else => return err,
    };
    defer allocator.free(existing);

    const existing_norm = try normalize(allocator, existing, opts);
    defer allocator.free(existing_norm);

    if (!std.mem.eql(u8, existing_norm, normalized)) {
        printDiff(path, existing_norm, normalized);
        return SnapshotError.SnapshotMismatch;
    }
}

fn writeAll(path: []const u8, contents: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buf: [4096]u8 = undefined;
    var w = file.writer(&buf);
    try w.interface.writeAll(contents);
    try w.interface.flush();
}

fn normalize(allocator: std.mem.Allocator, input: []const u8, opts: Options) ![]u8 {
    var work: []u8 = try allocator.dupe(u8, input);
    errdefer allocator.free(work);

    if (opts.strip_ansi) {
        const stripped = try stripAnsi(allocator, work);
        allocator.free(work);
        work = stripped;
    }

    if (opts.trim_trailing_whitespace) {
        const trimmed = try trimTrailingWhitespace(allocator, work);
        allocator.free(work);
        work = trimmed;
    }

    return work;
}

fn stripAnsi(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = try std.array_list.Managed(u8).initCapacity(allocator, input.len);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c != 0x1b) {
            try out.append(c);
            i += 1;
            continue;
        }

        i += 1;
        if (i >= input.len) break;

        const next = input[i];
        if (next == '[') {
            i += 1;
            while (i < input.len) {
                const b = input[i];
                i += 1;
                if ((b >= '@' and b <= '~')) break;
            }
        } else if (next == ']') {
            i += 1;
            while (i < input.len) {
                const b = input[i];
                if (b == 0x07) {
                    i += 1;
                    break;
                }
                if (b == 0x1b and i + 1 < input.len and input[i + 1] == '\\') {
                    i += 2;
                    break;
                }
                i += 1;
            }
        } else {
            i += 1;
        }
    }

    return out.toOwnedSlice();
}

fn trimTrailingWhitespace(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = try std.array_list.Managed(u8).initCapacity(allocator, input.len);
    errdefer out.deinit();

    var lines = std.mem.splitScalar(u8, input, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append('\n');
        first = false;
        var end = line.len;
        while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\r')) {
            end -= 1;
        }
        try out.appendSlice(line[0..end]);
    }
    return out.toOwnedSlice();
}

fn printDiff(path: []const u8, expected: []const u8, actual: []const u8) void {
    const stderr = std.debug;
    stderr.print(
        "\nSnapshot mismatch: {s}\n" ++
            "  run with ZIGZAG_UPDATE_SNAPSHOTS=1 to update.\n" ++
            "--- expected ---\n{s}\n" ++
            "--- actual ---\n{s}\n" ++
            "----------------\n",
        .{ path, expected, actual },
    );
}

test "stripAnsi removes CSI and OSC" {
    const allocator = std.testing.allocator;
    const input = "\x1b[31mred\x1b[0m \x1b]0;title\x07plain";
    const stripped = try stripAnsi(allocator, input);
    defer allocator.free(stripped);
    try std.testing.expectEqualStrings("red plain", stripped);
}

test "trimTrailingWhitespace" {
    const allocator = std.testing.allocator;
    const out = try trimTrailingWhitespace(allocator, "hello   \nworld \t\n");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello\nworld\n", out);
}

test "expectSnapshot creates file when missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var orig = try std.fs.cwd().openDir(".", .{});
    defer orig.close();
    try tmp.dir.setAsCwd();
    defer orig.setAsCwd() catch {};

    try expectSnapshot(allocator, "snap.txt", "hello world");
    try expectSnapshot(allocator, "snap.txt", "hello world");

    const err = expectSnapshot(allocator, "snap.txt", "hello there");
    try std.testing.expectError(SnapshotError.SnapshotMismatch, err);
}
