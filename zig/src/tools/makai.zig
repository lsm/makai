const std = @import("std");

pub const VERSION = "0.0.1";

fn printUsage(file: std.fs.File) !void {
    try file.writeAll(
        \\Usage: makai [--version] [--stdio]
        \\
        \\  --version  Print binary version
        \\  --stdio    Start stdio mode (placeholder)
        \\
    );
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();
    const stdin = std.fs.File.stdin();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len <= 1) {
        try printUsage(stdout);
        return;
    }

    if (std.mem.eql(u8, args[1], "--version")) {
        try stdout.writeAll(VERSION ++ "\n");
        return;
    }

    if (std.mem.eql(u8, args[1], "--stdio")) {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = try stdin.read(&buffer);
            if (n == 0) break;
        }
        return;
    }

    var msg_buf: [512]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "unknown argument: {s}\n\n", .{args[1]});
    try stderr.writeAll(msg);
    try printUsage(stderr);
    return error.InvalidArgument;
}
