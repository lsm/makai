
const std = @import("std");

pub const Logger = struct {
    io: std.Io,
    file: std.Io.File,
    end_pos: u64,
    mutex: std.Io.Mutex,

    pub fn init(io: std.Io, path: []const u8) !Logger {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
        const end_pos = std.Io.File.length(file, io) catch 0;
        return .{
            .io = io,
            .file = file,
            .end_pos = end_pos,
            .mutex = .init,
        };
    }

    pub fn deinit(self: *Logger) void {
        self.file.close(self.io);
    }

    pub fn log(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var buf: [1024]u8 = undefined;
        var w = self.file.writer(self.io, &buf);
        w.seekTo(self.end_pos) catch return;

        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(now) };
        const day_seconds = epoch_seconds.getDaySeconds();

        w.interface.print("[{d:0>2}:{d:0>2}:{d:0>2}] ", .{
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        }) catch return;

        w.interface.print(fmt, args) catch return;
        w.interface.writeByte('\n') catch return;
        w.interface.flush() catch return;

        self.end_pos = w.logicalPos();
    }
};
