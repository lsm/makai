const std = @import("std");
const compat = @import("compat");
const zz = @import("zigzag");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const register_builtins = @import("register_builtins");
const agent = @import("agent");
const tui_runtime = @import("tui_runtime");
const tui_state = @import("tui_state");
const tui_commands = @import("tui_commands");
const transcript_view = @import("tui_view_transcript");
const composer_view = @import("tui_view_composer");
const status_bar_view = @import("tui_view_status_bar");
const tool_panel_view = @import("tui_view_tool_panel");
const telemetry_view = @import("tui_view_telemetry");
const approval_view = @import("tui_view_approval");
const preview_view = @import("tui_view_preview");
const session_picker_view = @import("tui_view_session_picker");
const tui_render = @import("tui_render");
const permission = @import("permission");

pub const ApprovalWaiter = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    tool_call_id: []u8 = &.{},
    decision: ?tui_runtime.ToolApprovalDecision = null,
    shutting_down: bool = false,

    pub fn cancel(self: *ApprovalWaiter) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        self.shutting_down = true;
        self.decision = .reject;
    }

    pub fn deinit(self: *ApprovalWaiter) void {
        self.cancel();
        if (self.tool_call_id.len > 0) self.allocator.free(self.tool_call_id);
        self.* = undefined;
    }
};

pub const ProductionRuntime = struct {
    allocator: std.mem.Allocator,
    registry: api_registry.ApiRegistry,
    bridge: agent.InProcessProviderProtocolBridge,
    permission_engine: permission.PermissionEngine,
    models: []ai_types.Model,

    pub fn init(allocator: std.mem.Allocator) !ProductionRuntime {
        var registry = api_registry.ApiRegistry.init(allocator);
        errdefer registry.deinit();
        try register_builtins.registerBuiltInApiProviders(&registry);

        const workspace_root = try std.process.currentPathAlloc(defaultIo(), allocator);
        defer allocator.free(workspace_root);
        var permission_engine = permission.PermissionEngine.init(allocator, .{ .workspace_root = workspace_root }) catch
            permission.PermissionEngine.initEmpty(allocator, .{ .workspace_root = workspace_root }) catch
            @panic("OOM initializing permission engine");
        errdefer permission_engine.deinit();

        var runtime = ProductionRuntime{
            .allocator = allocator,
            .registry = registry,
            .bridge = undefined,
            .permission_engine = permission_engine,
            .models = try allocator.alloc(ai_types.Model, 1),
        };
        runtime.bridge = agent.InProcessProviderProtocolBridge.init(&runtime.registry);
        runtime.models[0] = defaultModel();
        return runtime;
    }

    pub fn options(self: *ProductionRuntime) tui_runtime.TuiRuntimeOptions {
        return .{
            .protocol = (&self.bridge).protocolClient(),
            .models = self.models,
            .permission_engine = &self.permission_engine,
            .run_async = true,
            .compact_output = true,
        };
    }

    pub fn deinit(self: *ProductionRuntime) void {
        self.allocator.free(self.models);
        self.permission_engine.deinit();
        self.registry.deinit();
        self.* = undefined;
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    state: tui_state.AppState,
    runtime: ?tui_runtime.TuiRuntime = null,
    session: ?tui_runtime.TuiSession = null,
    approval_waiter: ?*ApprovalWaiter = null,

    pub fn init(allocator: std.mem.Allocator, options: tui_runtime.TuiRuntimeOptions) !App {
        var runtime_options = options;
        const approval_waiter = try allocator.create(ApprovalWaiter);
        errdefer allocator.destroy(approval_waiter);
        approval_waiter.* = .{ .allocator = allocator };
        runtime_options.tool_approval_ctx = approval_waiter;
        runtime_options.tool_approval_callback = approvalCallback;
        var app = App{
            .allocator = allocator,
            .state = tui_state.AppState.init(allocator),
            .runtime = try tui_runtime.TuiRuntime.init(allocator, runtime_options),
            .approval_waiter = approval_waiter,
        };
        errdefer app.deinit();
        app.session = app.runtime.?.createSession();
        try app.state.setRegisteredTools(app.runtime.?.availableTools());
        if (app.runtime.?.currentModel()) |model| {
            try app.state.status.setModelWithContext(allocator, model.id, model.provider, model.context_window);
            app.state.telemetry.context_window = model.context_window;
        }
        return app;
    }

    pub fn initWithoutRuntime(allocator: std.mem.Allocator) App {
        return .{ .allocator = allocator, .state = tui_state.AppState.init(allocator) };
    }

    pub fn deinit(self: *App) void {
        if (self.approval_waiter) |waiter| waiter.cancel();
        if (self.runtime) |*runtime| runtime.deinit();
        if (self.approval_waiter) |waiter| {
            waiter.deinit();
            self.allocator.destroy(waiter);
        }
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
        if (trimmed[0] == '/') return try self.submitCommand(trimmed);
        try self.state.appendUserMessage(trimmed);
        if (self.session) |*session| {
            session.submitTurn(trimmed) catch |err| {
                try self.state.status.setError(self.allocator, @errorName(err));
                try self.state.appendTranscript(.@"error", @errorName(err));
                return;
            };
        }
    }

    fn submitCommand(self: *App, text: []const u8) !void {
        var parsed = tui_commands.parseOrMessage(self.allocator, text) catch |err| {
            try self.state.status.setError(self.allocator, @errorName(err));
            try self.state.appendTranscript(.@"error", @errorName(err));
            return;
        };
        defer parsed.deinit(self.allocator);

        const command = switch (parsed) {
            .message => |message| {
                try self.state.status.setError(self.allocator, message);
                try self.state.appendTranscript(.@"error", message);
                return;
            },
            .command => |command| command,
        };

        var result = tui_commands.dispatch(.{
            .allocator = self.allocator,
            .state = &self.state,
            .runtime = if (self.runtime) |*runtime| runtime else null,
            .session = if (self.session) |*session| session else null,
        }, command) catch |err| {
            try self.state.status.setError(self.allocator, @errorName(err));
            try self.state.appendTranscript(.@"error", @errorName(err));
            return;
        };
        defer result.deinit(self.allocator);

        switch (result.action) {
            .quit => return error.QuitRequested,
            .clear_transcript => self.state.clearTranscript(),
            .none => {},
        }
        if (result.output.len > 0) {
            try self.state.appendTranscript(if (result.is_error) .@"error" else .system, result.output);
            if (result.is_error) try self.state.status.setError(self.allocator, result.output);
        }
    }

    pub fn recordError(self: *App, message: []const u8) !void {
        try self.state.status.setError(self.allocator, message);
        try self.state.appendTranscript(.@"error", message);
    }

    pub fn decideApproval(self: *App, approved: bool, always: bool) !void {
        const id = self.state.approval.tool_call_id;
        const decision: tui_runtime.ToolApprovalDecision = if (approved) if (always) .approve_always else .approve else if (always) .reject_always else .reject;
        var matched_waiter = false;
        if (self.approval_waiter) |waiter| {
            while (!waiter.mutex.tryLock()) std.atomic.spinLoopHint();
            defer waiter.mutex.unlock();
            if (waiter.tool_call_id.len > 0 and (id.len == 0 or std.mem.eql(u8, waiter.tool_call_id, id))) {
                waiter.decision = decision;
                matched_waiter = true;
            }
        }
        if (!matched_waiter) {
            if (self.session) |*session| {
                if (id.len > 0) try session.decideToolApproval(id, decision);
            }
        }
        self.state.setApprovalDecision(approved, always);
    }
};

fn approvalCallback(ctx: ?*anyopaque, request: tui_runtime.ToolApprovalRequest) tui_runtime.ToolApprovalDecision {
    const waiter: *ApprovalWaiter = @ptrCast(@alignCast(ctx.?));
    while (!waiter.mutex.tryLock()) std.atomic.spinLoopHint();
    if (waiter.tool_call_id.len > 0) waiter.allocator.free(waiter.tool_call_id);
    waiter.tool_call_id = waiter.allocator.dupe(u8, request.tool_call_id) catch {
        waiter.mutex.unlock();
        return .approve;
    };
    waiter.decision = null;
    waiter.mutex.unlock();
    while (true) {
        while (!waiter.mutex.tryLock()) std.atomic.spinLoopHint();
        const decision = waiter.decision;
        const shutting_down = waiter.shutting_down;
        waiter.mutex.unlock();
        if (decision) |value| {
            while (!waiter.mutex.tryLock()) std.atomic.spinLoopHint();
            if (waiter.tool_call_id.len > 0) waiter.allocator.free(waiter.tool_call_id);
            waiter.tool_call_id = &.{};
            waiter.decision = null;
            waiter.mutex.unlock();
            return value;
        }
        if (shutting_down) return .reject;
        compat.time.sleepNs(1 * std.time.ns_per_ms);
    }
}

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
                    .char => |c| switch (c) {
                        'c' => return .quit,
                        'r' => {
                            app.state.toggleThinking();
                            return .none;
                        },
                        else => return .none,
                    },
                    else => {},
                };
                if (app.state.mode == .approval) {
                    switch (key.key) {
                        .char => |c| switch (c) {
                            'y' => app.decideApproval(true, false) catch |err| app.recordError(@errorName(err)) catch {},
                            'a' => app.decideApproval(true, true) catch |err| app.recordError(@errorName(err)) catch {},
                            'n' => app.decideApproval(false, false) catch |err| app.recordError(@errorName(err)) catch {},
                            else => {},
                        },
                        .escape => app.decideApproval(false, false) catch |err| app.recordError(@errorName(err)) catch {},
                        else => {},
                    }
                    return .none;
                }
                switch (key.key) {
                    .enter => {
                        if (key.modifiers.shift) {
                            app.state.composer.buffer.append(app.allocator, '\n') catch |err| app.recordError(@errorName(err)) catch {};
                            return .none;
                        }
                        const text = app.state.composer.text();
                        app.state.recordComposerHistory(text) catch |err| app.recordError(@errorName(err)) catch {};
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
                    .backspace => deleteLastCodepoint(app),
                    .char => |c| appendChar(app, c) catch {},
                    .space => app.state.composer.buffer.append(app.allocator, ' ') catch {},
                    .up => {
                        if (!(app.state.composerHistoryPrev() catch false)) app.state.transcript_scroll += 1;
                    },
                    .down => {
                        if (!(app.state.composerHistoryNext() catch false)) app.state.transcript_scroll -|= 1;
                    },
                    .page_up => app.state.transcript_scroll += 1,
                    .page_down => app.state.transcript_scroll -|= 1,
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
        const telemetry = telemetry_view.render(ctx.allocator, &app.state, .{ .width = width }) catch "";
        const extra = switch (app.state.mode) {
            .approval => approval_view.render(ctx.allocator, &app.state, .{ .width = width }) catch "",
            .preview => preview_view.render(ctx.allocator, &app.state, .{ .width = width, .height = height / 2 }) catch "",
            .session_picker => session_picker_view.render(ctx.allocator, &app.state, .{ .height = height / 2 }) catch "",
            .normal => "",
        };
        const fixed = countLines(status) + countLines(composer) + countLines(tools) + countLines(telemetry) + countLines(extra) + 5;
        const transcript_height = if (height > fixed) height - fixed else 3;
        const transcript = transcript_view.render(ctx.allocator, &app.state, .{ .width = width, .height = transcript_height }) catch "";
        const frame = tui_render.joinVertical(ctx.allocator, &.{ transcript, tools, telemetry, extra, composer, status }) catch "";
        return tui_render.withSynchronizedOutput(ctx.allocator, frame) catch frame;
    }

    fn appendChar(app: *App, c: u21) !void {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(c, &buf);
        try app.state.composer.buffer.appendSlice(app.allocator, buf[0..len]);
    }

    fn deleteLastCodepoint(app: *App) void {
        const text = app.state.composer.buffer.items;
        if (text.len == 0) return;
        var idx = text.len - 1;
        while (idx > 0 and (text[idx] & 0b1100_0000) == 0b1000_0000) idx -= 1;
        app.state.composer.buffer.shrinkRetainingCapacity(idx);
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

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

fn defaultModel() ai_types.Model {
    return .{
        .id = "claude-sonnet-4-5",
        .name = "Claude Sonnet 4.5",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1/messages",
        .reasoning = true,
        .input = &.{"text"},
        .cost = .{ .input = 3.0, .output = 15.0, .cache_read = 0.30, .cache_write = 3.75 },
        .context_window = 200_000,
        .max_tokens = 8192,
    };
}

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var environ_map = try compat.createEnvMap(allocator);
    defer environ_map.deinit();

    var production = try ProductionRuntime.init(allocator);
    defer production.deinit();

    var program = zz.Program(TuiModel).init(allocator, io, &environ_map);
    program.model = .{ .options = production.options() };
    defer program.deinit();
    try program.run();
}

test "App init seeds registered tools from runtime" {
    var production = try ProductionRuntime.init(std.testing.allocator);
    defer production.deinit();
    var app = try App.init(std.testing.allocator, production.options());
    defer app.deinit();

    try std.testing.expect(app.state.registered_tools.items.len >= 12);
    try std.testing.expectEqual(app.runtime.?.availableTools().len, app.state.registered_tools.items.len);
    try std.testing.expectEqualStrings("shell_execute", app.state.registered_tools.items[0].name);
    try std.testing.expect(app.runtime.?.permission_engine.?.workspace_root.len > 0);
}

test "App approval decisions map to requested choices" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    try app.state.approval.setPending(std.testing.allocator, "call-approval", "edit_file", "{\"path\":\"README.md\"}");
    app.state.mode = .approval;

    try app.decideApproval(true, false);
    try std.testing.expectEqual(tui_state.AppMode.normal, app.state.mode);
    try std.testing.expectEqual(tui_state.ApprovalStatus.approved, app.state.approval.status);
    try std.testing.expect(!app.state.approval.always);

    try app.state.approval.setPending(std.testing.allocator, "call-approval", "edit_file", "{\"path\":\"README.md\"}");
    app.state.mode = .approval;
    try app.decideApproval(true, true);
    try std.testing.expectEqual(tui_state.ApprovalStatus.approved, app.state.approval.status);
    try std.testing.expect(app.state.approval.always);

    try app.state.approval.setPending(std.testing.allocator, "call-approval", "edit_file", "{\"path\":\"README.md\"}");
    app.state.mode = .approval;
    try app.decideApproval(false, false);
    try std.testing.expectEqual(tui_state.ApprovalStatus.rejected, app.state.approval.status);
    try std.testing.expect(!app.state.approval.always);
}

test "App submit appends user transcript without runtime" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    try app.submit("hello");
    try std.testing.expectEqual(@as(usize, 1), app.state.transcript.items.len);
    try std.testing.expectEqualStrings("hello", app.state.transcript.items[0].text.items);
}

test "App submit routes help command to system transcript" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    try app.submit("/help");
    try std.testing.expectEqual(@as(usize, 1), app.state.transcript.items.len);
    try std.testing.expectEqual(tui_state.TranscriptKind.system, app.state.transcript.items[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "/model") != null);
}

test "App submit routes unknown command to error transcript" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    try app.submit("/unknown");
    try std.testing.expectEqual(@as(usize, 1), app.state.transcript.items.len);
    try std.testing.expectEqual(tui_state.TranscriptKind.@"error", app.state.transcript.items[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "unknown command") != null);
}

test "App submit quit command requests quit" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    try std.testing.expectError(error.QuitRequested, app.submit("/quit"));
}
