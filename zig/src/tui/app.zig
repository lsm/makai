const std = @import("std");
const vaxis = @import("vaxis");

const composer_view = @import("views/composer.zig");
const status_bar_view = @import("views/status_bar.zig");
const transcript_view = @import("views/transcript.zig");

pub const UiEvent = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    mock_delta: []const u8,
};

pub const AppState = struct {
    transcript: transcript_view.Transcript,
    composer: composer_view.Composer,
    status: status_bar_view.Status = .{},
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator) !AppState {
        var state: AppState = .{
            .transcript = transcript_view.Transcript.init(allocator),
            .composer = composer_view.Composer.init(allocator),
        };
        errdefer state.deinit();

        try state.transcript.add(.system, "libvaxis spike booted");
        try state.transcript.add(.assistant, "background queue will push mock streaming rows");
        try state.transcript.add(.tool, "resize terminal; vaxis winsize event redraws frame");
        return state;
    }

    pub fn deinit(self: *AppState) void {
        self.composer.deinit();
        self.transcript.deinit();
        self.* = undefined;
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    tty_buffer: []u8,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    state: AppState,
    mock_done: std.atomic.Value(bool) = .init(false),
    mock_thread: ?std.Thread = null,

    pub fn init(init_args: std.process.Init) !App {
        const tty_buffer = try init_args.gpa.alloc(u8, 1024);
        errdefer init_args.gpa.free(tty_buffer);

        var tty = try vaxis.Tty.init(init_args.io, tty_buffer);
        errdefer tty.deinit();

        var vx = try vaxis.init(init_args.io, init_args.gpa, init_args.environ_map, .{
            .kitty_keyboard_flags = .{ .report_events = true },
        });
        errdefer vx.deinit(init_args.gpa, tty.writer());

        const state = try AppState.init(init_args.gpa);
        errdefer {
            var mutable_state = state;
            mutable_state.deinit();
        }

        return .{
            .allocator = init_args.gpa,
            .tty_buffer = tty_buffer,
            .tty = tty,
            .vx = vx,
            .state = state,
        };
    }

    pub fn deinit(self: *App) void {
        self.stopMockProducer();
        self.state.deinit();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.allocator.free(self.tty_buffer);
        self.* = undefined;
    }

    pub fn run(self: *App) !void {
        var loop: vaxis.Loop(UiEvent) = .init(self.tty.io, &self.tty, &self.vx);
        try loop.start();
        defer loop.stop();

        const writer = self.tty.writer();
        try self.vx.enterAltScreen(writer);
        try writer.flush();
        try self.vx.queryTerminal(writer, .fromSeconds(1));

        self.mock_thread = try std.Thread.spawn(.{}, mockProducer, .{ self, &loop });
        defer self.stopMockProducer();

        while (self.state.running) {
            const event = try loop.nextEvent();
            try self.handleEvent(event);
            try self.render();
        }
    }

    fn stopMockProducer(self: *App) void {
        self.mock_done.store(true, .release);
        if (self.mock_thread) |thread| {
            thread.join();
            self.mock_thread = null;
        }
    }

    fn handleEvent(self: *App, event: UiEvent) !void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    self.state.running = false;
                    return;
                }

                if (key.matches('l', .{ .ctrl = true })) {
                    self.vx.queueRefresh();
                    return;
                }

                const maybe_submitted = try self.state.composer.handleKey(key);
                if (maybe_submitted) |submitted| {
                    defer self.allocator.free(submitted);
                    if (std.mem.eql(u8, std.mem.trim(u8, submitted, " \t\r\n"), "/quit")) {
                        self.state.running = false;
                        return;
                    }
                    if (submitted.len > 0) {
                        try self.state.transcript.add(.user, submitted);
                    }
                } else if (self.state.composer.isQuitCommand()) {
                    self.state.status.state = "press Enter to quit";
                } else {
                    self.state.status.state = "typing";
                }
            },
            .winsize => |ws| try self.vx.resize(self.allocator, self.tty.writer(), ws),
            .mock_delta => |text| {
                defer self.allocator.free(text);
                self.state.status.state = "streaming mock events";
                try self.state.transcript.add(.assistant, text);
            },
            .mouse, .focus_in, .focus_out => {},
        }
    }

    fn render(self: *App) !void {
        const writer = self.tty.writer();
        const win = self.vx.window();
        win.clear();

        if (win.height == 0 or win.width == 0) return;

        const status_height: u16 = 1;
        const composer_height: u16 = if (win.height >= 5) 3 else 1;
        const transcript_height: u16 = if (win.height > status_height + composer_height)
            win.height - status_height - composer_height
        else
            0;

        status_bar_view.draw(win.child(.{ .height = status_height }), self.state.status);

        if (transcript_height > 0) {
            transcript_view.Transcript.draw(self.state.transcript, win.child(.{
                .y_off = status_height,
                .height = transcript_height,
            }));
        }

        self.state.composer.draw(win.child(.{
            .y_off = @intCast(status_height + transcript_height),
            .height = composer_height,
        }));

        try self.vx.render(writer);
        try writer.flush();
    }
};

pub fn run(init_args: std.process.Init) !void {
    var app = try App.init(init_args);
    defer app.deinit();
    try app.run();
}

fn mockProducer(app: *App, loop: *vaxis.Loop(UiEvent)) void {
    var counter: usize = 1;
    while (!app.mock_done.load(.acquire)) : (counter += 1) {
        loop.io.sleep(.fromMilliseconds(900), .real) catch break;
        if (app.mock_done.load(.acquire)) break;

        var buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "mock streamed delta #{d}", .{counter}) catch continue;
        const owned = app.allocator.dupe(u8, text) catch continue;
        loop.postEvent(.{ .mock_delta = owned }) catch {
            app.allocator.free(owned);
            break;
        };
    }
}

test {
    std.testing.refAllDecls(@This());
}
