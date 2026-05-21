const std = @import("std");
const compat = @import("compat");
const zz = @import("zigzag");
const tui_runtime = @import("tui_runtime");
const tui_state = @import("tui_state");
const transcript_view = @import("tui_view_transcript");
const composer_view = @import("tui_view_composer");
const status_bar_view = @import("tui_view_status_bar");
const tool_panel_view = @import("tui_view_tool_panel");
const approval_view = @import("tui_view_approval");
const preview_view = @import("tui_view_preview");
const session_picker_view = @import("tui_view_session_picker");

pub const App = struct {
    allocator: std.mem.Allocator,
    state: tui_state.AppState,
    runtime: ?tui_runtime.TuiRuntime = null,
    session: ?tui_runtime.TuiSession = null,

    pub fn init(allocator: std.mem.Allocator, options: tui_runtime.TuiRuntimeOptions) !App {
        var app = App{
            .allocator = allocator,
            .state = tui_state.AppState.init(allocator),
            .runtime = try tui_runtime.TuiRuntime.init(allocator, options),
        };
        errdefer app.deinit();
        app.session = app.runtime.?.createSession();
        if (app.runtime.?.currentModel()) |model| try app.state.status.setModel(allocator, model.id, model.provider);
        return app;
    }

    pub fn initWithoutRuntime(allocator: std.mem.Allocator) App {
        return .{ .allocator = allocator, .state = tui_state.AppState.init(allocator) };
    }

    pub fn deinit(self: *App) void {
        if (self.runtime) |*runtime| runtime.deinit();
        self.state.deinit();
        self.* = undefined;
    }

    pub fn start(self: *App) !void {
        if (self.session) |*session| {
            session.start() catch |err| {
                try self.state.status.setError(self.allocator, @errorName(err));
                try self.state.appendTranscript(.@"error", @errorName(err));
                return;
            };
        } else {
            try self.state.status.setError(self.allocator, "no runtime configured");
        }
    }

    pub fn drainEvents(self: *App) !void {
        var session = &(self.session orelse return);
        while (session.popEvent()) |event| {
            var ev = event;
            defer ev.deinit(self.allocator);
            try self.state.applyEvent(ev);
        }
    }

    pub fn submit(self: *App, text: []const u8) !void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        if (std.mem.eql(u8, trimmed, "/quit")) return error.QuitRequested;
        try self.state.appendUserMessage(trimmed);
        if (self.session) |*session| {
            session.submitTurn(trimmed) catch |err| {
                try self.state.status.setError(self.allocator, @errorName(err));
                try self.state.appendTranscript(.@"error", @errorName(err));
                return;
            };
        }
    }
};

const TuiModel = struct {
    app: ?App = null,
    options: tui_runtime.TuiRuntimeOptions = .{},

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        tick: struct { timestamp: u64, delta: u64 },
        quit: void,
    };

    pub fn init(self: *TuiModel, ctx: *zz.Context) zz.Cmd(Msg) {
        self.deinit();
        self.app = App.init(ctx.persistent_allocator, self.options) catch |err| blk: {
            var fallback = App.initWithoutRuntime(ctx.persistent_allocator);
            fallback.state.status.setError(ctx.persistent_allocator, @errorName(err)) catch {};
            fallback.state.appendTranscript(.@"error", @errorName(err)) catch {};
            break :blk fallback;
        };
        if (self.app) |*app| {
            app.start() catch |err| {
                app.state.status.setError(app.allocator, @errorName(err)) catch {};
                app.state.appendTranscript(.@"error", @errorName(err)) catch {};
            };
            app.state.appendTranscript(.system, "Makai TUI") catch {};
            app.state.appendTranscript(.system, "Enter submits composer, Ctrl+C or /quit exits") catch {};
        }
        return .{ .every = 50 * std.time.ns_per_ms };
    }

    pub fn deinit(self: *TuiModel) void {
        if (self.app) |*app| app.deinit();
        self.app = null;
    }

    pub fn update(self: *TuiModel, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        _ = ctx;
        const app = &(self.app orelse return .none);
        switch (msg) {
            .key => |key| {
                if (key.modifiers.ctrl) switch (key.key) {
                    .char => |c| if (c == 'c') return .quit,
                    else => {},
                };
                if (app.state.mode == .approval) {
                    switch (key.key) {
                        .char => |c| switch (c) {
                            'a' => app.state.setApprovalDecision(true, false),
                            'A' => app.state.setApprovalDecision(true, true),
                            'd' => app.state.setApprovalDecision(false, false),
                            else => {},
                        },
                        .escape => app.state.setApprovalDecision(false, false),
                        else => {},
                    }
                    return .none;
                }
                switch (key.key) {
                    .enter => {
                        const text = app.state.composer.text();
                        if (std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), "/quit")) return .quit;
                        app.submit(text) catch |err| {
                            if (err == error.QuitRequested) return .quit;
                            app.state.status.setError(app.allocator, @errorName(err)) catch {};
                            app.state.appendTranscript(.@"error", @errorName(err)) catch {};
                        };
                        app.state.composer.clear();
                        app.drainEvents() catch |err| {
                            app.state.status.setError(app.allocator, @errorName(err)) catch {};
                            app.state.appendTranscript(.@"error", @errorName(err)) catch {};
                        };
                    },
                    .backspace => {
                        if (app.state.composer.buffer.items.len > 0) _ = app.state.composer.buffer.pop();
                    },
                    .char => |c| appendChar(app, c) catch {},
                    .space => app.state.composer.buffer.append(app.allocator, ' ') catch {},
                    .up, .page_up => app.state.transcript_scroll += 1,
                    .down, .page_down => app.state.transcript_scroll -|= 1,
                    .escape => app.state.mode = .normal,
                    else => {},
                }
            },
            .tick => app.drainEvents() catch {},
            .quit => return .quit,
        }
        return .none;
    }

    pub fn view(self: *TuiModel, ctx: *const zz.Context) []const u8 {
        const app = &(self.app orelse return "Makai TUI failed to initialize");
        const width: usize = @max(ctx.width, 20);
        const height: usize = @max(ctx.height, 8);
        const status = status_bar_view.render(ctx.allocator, &app.state, .{ .width = width }) catch "";
        const composer = composer_view.render(ctx.allocator, &app.state, .{ .width = width }) catch "";
        const tool_height: usize = if (app.state.tools.items.len > 0) @min(@as(usize, 8), height / 4) else 2;
        const tools = tool_panel_view.render(ctx.allocator, &app.state, .{ .width = width, .height = tool_height }) catch "";
        const extra = switch (app.state.mode) {
            .approval => approval_view.render(ctx.allocator, &app.state, .{ .width = width }) catch "",
            .preview => preview_view.render(ctx.allocator, &app.state, .{ .width = width, .height = height / 2 }) catch "",
            .session_picker => session_picker_view.render(ctx.allocator, &app.state, .{ .height = height / 2 }) catch "",
            .normal => "",
        };
        const fixed = countLines(status) + countLines(composer) + countLines(tools) + countLines(extra) + 4;
        const transcript_height = if (height > fixed) height - fixed else 3;
        const transcript = transcript_view.render(ctx.allocator, &app.state, .{ .width = width, .height = transcript_height }) catch "";
        return std.fmt.allocPrint(ctx.allocator, "{s}\n{s}\n{s}\n{s}\n{s}", .{ transcript, tools, extra, composer, status }) catch "";
    }

    fn appendChar(app: *App, c: u21) !void {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(c, &buf);
        try app.state.composer.buffer.appendSlice(app.allocator, buf[0..len]);
    }

    fn countLines(text: []const u8) usize {
        if (text.len == 0) return 0;
        var count: usize = 1;
        for (text) |c| {
            if (c == '\n') count += 1;
        }
        return count;
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var environ_map = try compat.createEnvMap(allocator);
    defer environ_map.deinit();

    var program = zz.Program(TuiModel).init(allocator, io, &environ_map);
    program.model = .{ .options = .{} };
    defer program.deinit();
    try program.run();
}

test "App submit appends user transcript without runtime" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    try app.submit("hello");
    try std.testing.expectEqual(@as(usize, 1), app.state.transcript.items.len);
    try std.testing.expectEqualStrings("hello", app.state.transcript.items[0].text.items);
}
