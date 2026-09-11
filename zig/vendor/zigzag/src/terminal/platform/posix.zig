
const std = @import("std");
const Writer = std.Io.Writer;
const posix = std.posix;
const ansi = @import("../ansi.zig");

pub const TerminalError = error{
    NotATty,
    GetAttrFailed,
    SetAttrFailed,
    IoctlFailed,
    PipeFailed,
    SignalSetupFailed,
};

pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub const State = struct {
    original_termios: ?posix.termios = null,
    in_raw_mode: bool = false,
    in_alt_screen: bool = false,
    mouse_enabled: bool = false,
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,

    pub fn init() State {
        return .{
            .stdin_fd = posix.STDIN_FILENO,
            .stdout_fd = posix.STDOUT_FILENO,
        };
    }
};

pub fn isTty(fd: posix.fd_t) bool {
    var wsz: posix.winsize = undefined;
    return posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&wsz)) == 0;
}

pub fn getSize(fd: posix.fd_t) !Size {
    var wsz: posix.winsize = undefined;
    const result = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (result != 0) {
        if (!isTty(fd)) {
            return .{ .rows = 24, .cols = 80 };
        }
        return TerminalError.IoctlFailed;
    }
    return .{
        .rows = wsz.row,
        .cols = wsz.col,
    };
}

pub fn enableRawMode(state: *State) !void {
    if (state.in_raw_mode) return;

    if (!isTty(state.stdin_fd)) {
        state.in_raw_mode = true;
        return;
    }

    state.original_termios = posix.tcgetattr(state.stdin_fd) catch {
        return TerminalError.GetAttrFailed;
    };

    var raw = state.original_termios.?;

    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;

    raw.oflag.OPOST = false;

    raw.cflag.CSIZE = .CS8;

    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;

    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 1;

    posix.tcsetattr(state.stdin_fd, .FLUSH, raw) catch {
        return TerminalError.SetAttrFailed;
    };

    state.in_raw_mode = true;
}

pub fn disableRawMode(state: *State) void {
    if (!state.in_raw_mode) return;

    if (state.original_termios) |termios| {
        posix.tcsetattr(state.stdin_fd, .FLUSH, termios) catch {};
    }

    state.in_raw_mode = false;
}

pub fn enterAltScreen(state: *State, writer: *Writer) !void {
    if (state.in_alt_screen) return;

    try writer.writeAll(ansi.alt_screen_enter);
    state.in_alt_screen = true;
}

pub fn exitAltScreen(state: *State, writer: *Writer) !void {
    if (!state.in_alt_screen) return;

    try writer.writeAll(ansi.alt_screen_exit);
    state.in_alt_screen = false;
}

pub fn enableMouse(state: *State, writer: *Writer) !void {
    if (state.mouse_enabled) return;

    try writer.writeAll("\x1b[?1000h\x1b[?1006h");
    state.mouse_enabled = true;
}

pub fn disableMouse(state: *State, writer: *Writer) !void {
    if (!state.mouse_enabled) return;

    try writer.writeAll("\x1b[?1006l\x1b[?1000l");
    state.mouse_enabled = false;
}

pub fn readInput(state: *State, buffer: []u8, timeout_ms: i32) !usize {
    var pollfds = [_]posix.pollfd{
        .{
            .fd = state.stdin_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        },
    };

    const result = posix.poll(&pollfds, timeout_ms) catch return 0;

    if (result > 0 and (pollfds[0].revents & posix.POLL.IN) != 0) {
        return posix.read(state.stdin_fd, buffer) catch 0;
    }

    return 0;
}

pub fn flush(fd: posix.fd_t) void {
    _ = posix.system.fsync(fd);
}

var resize_signaled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn setupSignals() !void {
    const handler = posix.Sigaction{
        .handler = .{
            .handler = struct {
                fn handle(_: posix.SIG) callconv(.c) void {
                    resize_signaled.store(true, .release);
                }
            }.handle,
        },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.WINCH, &handler, null);
}

pub fn checkResize() bool {
    return resize_signaled.swap(false, .acquire);
}
