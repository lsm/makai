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
const session_store = @import("tui_session_store");
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

const max_session_event_jsonl_bytes = 8 * 1024 * 1024;
const max_session_event_payload_bytes = max_session_event_jsonl_bytes / 2;

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

        const workspace_root = try currentPathOwned(allocator);
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
    store: ?session_store.Store = null,
    session_id: []u8 = &.{},
    session_created_at: i64 = 0,
    working_dir: []u8 = &.{},
    last_view_height: usize = 8,

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
        // Initialize session store and generate a session ID.
        app.store = session_store.Store.initDefault(allocator) catch null;
        app.session_id = generateSessionId(allocator) catch try allocator.dupe(u8, "default");
        app.session_created_at = compat.time.nowMillis();
        app.working_dir = currentPathOwned(allocator) catch try allocator.dupe(u8, "");
        try app.state.status.setSessionId(allocator, app.session_id);
        // Pre-populate sessions list.
        try app.loadSessions();
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
        if (self.store) |*store| store.deinit();
        if (self.session_id.len > 0) self.allocator.free(self.session_id);
        if (self.working_dir.len > 0) self.allocator.free(self.working_dir);
        self.state.deinit();
        self.* = undefined;
    }

    /// Load sessions from the store into state.sessions.
    pub fn loadSessions(self: *App) !void {
        const store = self.store orelse return;
        for (self.state.sessions.items) |*s| s.deinit(self.allocator);
        self.state.sessions.clearRetainingCapacity();
        var metas = store.list() catch return;
        defer {
            for (metas.items) |*meta| meta.deinit(self.allocator);
            metas.deinit(self.allocator);
        }
        std.mem.sort(session_store.SessionMetadata, metas.items, {}, newerSessionFirst);
        for (metas.items) |meta| {
            const label = try formatSessionLabel(self.allocator, meta);
            defer self.allocator.free(label);
            try self.state.addSession(meta.session_id, label);
        }
    }

    /// Resume the session currently selected in the session picker.
    pub fn resumeSelectedSession(self: *App) !void {
        const store = self.store orelse return error.NoStoreConfigured;
        const runtime = if (self.runtime) |*r| r else return error.NoRuntimeConfigured;
        const sessions = self.state.sessions.items;
        if (sessions.len == 0) return;
        const idx = self.state.session_index;
        if (idx >= sessions.len) return;
        const id = sessions[idx].id;
        var loaded = try store.resumeSession(id, runtime);
        defer loaded.deinit(self.allocator);
        const new_session_id = try self.allocator.dupe(u8, loaded.metadata.session_id);
        self.discardPendingEvents();
        self.state.resetReplayState();
        if (self.session_id.len > 0) self.allocator.free(self.session_id);
        self.session_id = new_session_id;
        self.session_created_at = loaded.metadata.created_at;
        try self.state.status.setSessionId(self.allocator, self.session_id);
        if (runtime.currentModel()) |model| {
            try self.state.status.setModelWithContext(self.allocator, model.id, model.provider, model.context_window);
            self.state.telemetry.context_window = model.context_window;
        } else {
            try self.state.status.setModelWithContext(self.allocator, loaded.metadata.model, loaded.metadata.provider, 0);
        }
        // Replay events into transcript and status counters.
        for (loaded.events.items) |*event| {
            try self.state.applyEvent(event.*);
        }
        self.state.status.streaming = false;
        self.state.mode = .normal;
    }

    /// Save one event to the session store (best-effort: ignores errors).
    fn saveEvent(self: *App, event: tui_runtime.TuiEvent) void {
        const store = self.store orelse return;
        // Only save events that are needed for session replay.
        switch (event) {
            .message_start, .tool_execution_start, .context_usage, .prompt_segment_usage, .agent_start, .turn_start, .turn_end, .agent_end => {},
            .text_delta => |payload| {
                if (payload.delta.slice().len > max_session_event_payload_bytes) return;
            },
            .tool_call_delta => |payload| {
                if (payload.delta.slice().len > max_session_event_payload_bytes) return;
            },
            .message_end => |payload| {
                if (messageEndPayloadSize(payload) > max_session_event_payload_bytes) return;
            },
            .tool_execution_end => |payload| {
                if (toolExecutionEndPayloadSize(payload) > max_session_event_payload_bytes) return;
            },
            else => return,
        }
        const meta = self.currentSessionMetadata();
        store.save(meta, event) catch {};
    }

    fn messageEndPayloadSize(payload: @TypeOf(@as(tui_runtime.TuiEvent, undefined).message_end)) usize {
        return payload.text.slice().len +
            payload.content_json.slice().len +
            payload.tool_call_id.slice().len +
            payload.tool_name.slice().len +
            payload.args_json.slice().len +
            payload.tool_calls_json.slice().len +
            payload.details_json.slice().len +
            payload.artifacts_json.slice().len;
    }

    fn toolExecutionEndPayloadSize(payload: @TypeOf(@as(tui_runtime.TuiEvent, undefined).tool_execution_end)) usize {
        return payload.result_json.slice().len +
            payload.tool_call_id.slice().len +
            payload.tool_name.slice().len +
            payload.artifact_refs.slice().len;
    }

    fn currentSessionMetadata(self: *App) session_store.SessionMetadata {
        return .{
            .session_id = self.session_id,
            .model = self.state.status.model,
            .provider = self.state.status.provider,
            .created_at = self.session_created_at,
            .last_active = compat.time.nowMillis(),
            .turn_count = self.state.status.turn_count,
            .working_dir = self.working_dir,
        };
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
            self.saveEvent(ev);
            try self.state.applyEvent(ev);
        }
    }

    fn discardPendingEvents(self: *App) void {
        var session = &(self.session orelse return);
        while (session.popEvent()) |event| {
            var ev = event;
            defer ev.deinit(self.allocator);
            self.saveEvent(ev);
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

        if (command.kind == .sessions) self.loadSessions() catch {};

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
            .open_session_picker => {
                // Refresh sessions list from store then open the picker.
                self.loadSessions() catch {};
                self.state.session_index = 0;
                self.state.session_scroll = 0;
                self.state.mode = .session_picker;
            },
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

/// Module-level state for the external editor launch (T11).
/// Stores the owned temp file path so the stateless `perform` fn can access it.
var editor_tmp_path: []u8 = &.{};
var editor_tmp_allocator: ?std.mem.Allocator = null;

const editor_tmp_dir_prefix = "makai-editor-";
const editor_tmp_file_name = "composer.txt";

/// T11: Write composer buffer to a temp file and return a batch command that
/// exits alt screen, runs the editor, and returns an editor_done message.
fn launchExternalEditor(app: *App, allocator: std.mem.Allocator) ?zz.Cmd(TuiModel.Msg) {
    if (@import("builtin").is_test) return null; // skip in tests
    if (@import("builtin").os.tag == .windows) return null;

    const content = app.state.composer.buffer.items;
    const tmp_path = createExternalEditorTempFile(allocator, content) catch return null;
    errdefer {
        cleanupExternalEditorTempPath(tmp_path);
        allocator.free(tmp_path);
    }

    // Store owned path in module-level state for the perform fn.
    if (editor_tmp_path.len > 0) {
        cleanupExternalEditorTempPath(editor_tmp_path);
        allocator.free(editor_tmp_path);
    }
    editor_tmp_path = tmp_path;
    editor_tmp_allocator = allocator;

    return zz.Cmd(TuiModel.Msg){ .sequence = &.{
        .exit_alt_screen,
        .show_cursor,
        .{ .perform = runEditorPerform },
    } };
}

fn encodeHexLower(out: []u8, bytes: []const u8) void {
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn createExternalEditorTempFile(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var random_bytes: [16]u8 = undefined;
    compat.random.fillSecureBytes(&random_bytes);
    var random_hex: [32]u8 = undefined;
    encodeHexLower(&random_hex, &random_bytes);

    const tmp_dir = compat.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmp_dir);
    const dir_path = try std.fs.path.join(allocator, &.{ tmp_dir, editor_tmp_dir_prefix ++ random_hex });
    defer allocator.free(dir_path);
    try std.Io.Dir.createDirAbsolute(defaultIo(), dir_path, @enumFromInt(0o700));
    errdefer std.Io.Dir.deleteDirAbsolute(defaultIo(), dir_path) catch {};

    const file_path = try std.fs.path.join(allocator, &.{ dir_path, editor_tmp_file_name });
    errdefer allocator.free(file_path);

    var file = try std.Io.Dir.createFileAbsolute(defaultIo(), file_path, .{ .exclusive = true, .truncate = false, .permissions = @enumFromInt(0o600) });
    errdefer std.Io.Dir.deleteFileAbsolute(defaultIo(), file_path) catch {};
    defer file.close(defaultIo());
    try file.writeStreamingAll(defaultIo(), content);
    return file_path;
}

fn cleanupExternalEditorTempPath(path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(defaultIo(), path) catch {};
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.deleteDirAbsolute(defaultIo(), dir) catch {};
}

fn appendEditorArg(parts: *std.ArrayList([]u8), allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) !void {
    if (buffer.items.len == 0) return;
    try parts.append(allocator, try allocator.dupe(u8, buffer.items));
    buffer.clearRetainingCapacity();
}

fn buildEditorArgv(allocator: std.mem.Allocator, editor: []const u8, path: []const u8) ![]const []const u8 {
    var parts: std.ArrayList([]u8) = .empty;
    errdefer {
        for (parts.items) |part| allocator.free(part);
        parts.deinit(allocator);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);

    var quote: ?u8 = null;
    var escape = false;
    for (editor) |c| {
        if (escape) {
            try current.append(allocator, c);
            escape = false;
            continue;
        }
        if (c == '\\') {
            escape = true;
            continue;
        }
        if (quote) |q| {
            if (c == q) {
                quote = null;
            } else {
                try current.append(allocator, c);
            }
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            try appendEditorArg(&parts, allocator, &current);
            continue;
        }
        try current.append(allocator, c);
    }
    if (escape) try current.append(allocator, '\\');
    try appendEditorArg(&parts, allocator, &current);
    if (parts.items.len == 0) try parts.append(allocator, try allocator.dupe(u8, "vi"));
    try parts.append(allocator, try allocator.dupe(u8, path));
    return parts.toOwnedSlice(allocator);
}

fn freeEditorArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

/// Stateless perform fn: spawns $EDITOR on the temp file and reads result back.
fn runEditorPerform() ?TuiModel.Msg {
    if (editor_tmp_path.len == 0) return TuiModel.Msg{ .editor_failed = {} };
    const allocator = editor_tmp_allocator orelse return TuiModel.Msg{ .editor_failed = {} };
    const path = editor_tmp_path;
    defer {
        cleanupExternalEditorTempPath(path);
        allocator.free(path);
        editor_tmp_path = &.{};
        editor_tmp_allocator = null;
    }

    // Resolve $EDITOR or fall back to vi.
    const editor_owned = compat.getEnvVarOwned(allocator, "EDITOR") catch
        (compat.getEnvVarOwned(allocator, "VISUAL") catch allocator.dupe(u8, "vi") catch return TuiModel.Msg{ .editor_failed = {} });
    defer allocator.free(editor_owned);
    const argv = buildEditorArgv(allocator, editor_owned, path) catch return TuiModel.Msg{ .editor_failed = {} };
    defer freeEditorArgv(allocator, argv);

    // Spawn editor and wait.
    var child = std.process.spawn(defaultIo(), .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return TuiModel.Msg{ .editor_failed = {} };
    defer if (child.id != null) child.kill(defaultIo());
    _ = child.wait(defaultIo()) catch return TuiModel.Msg{ .editor_failed = {} };

    // Read file back.
    const content = std.Io.Dir.readFileAlloc(.cwd(), defaultIo(), path, allocator, .limited(10 * 1024 * 1024)) catch return TuiModel.Msg{ .editor_failed = {} };

    return TuiModel.Msg{ .editor_done = content };
}

const TuiModel = struct {
    app: ?App = null,
    options: tui_runtime.TuiRuntimeOptions = .{},

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        mouse: zz.MouseEvent,
        tick: struct { timestamp: u64, delta: u64 },
        quit: void,
        /// Content read back from the external editor (owned by persistent allocator).
        editor_done: []u8,
        /// External editor failed after leaving alt screen; restore terminal state.
        editor_failed: void,
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
        return .{ .batch = &.{
            .{ .every = 50 * std.time.ns_per_ms },
            .enable_mouse,
        } };
    }

    pub fn deinit(self: *TuiModel) void {
        if (self.app) |*app| app.deinit();
        self.app = null;
    }

    pub fn update(self: *TuiModel, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        const app = &(self.app orelse return .none);
        switch (msg) {
            .editor_done => |content| {
                // Content was read back from the external editor. Load into composer.
                defer ctx.persistent_allocator.free(content);
                app.state.replaceComposerBuffer(content) catch {};
                // Re-enter alt screen and hide cursor after editor exit.
                return .{ .sequence = &.{
                    .enter_alt_screen,
                    .hide_cursor,
                } };
            },
            .editor_failed => {
                app.recordError("external editor failed") catch {};
                return .{ .sequence = &.{
                    .enter_alt_screen,
                    .hide_cursor,
                } };
            },
            .key => |key| {
                if (key.modifiers.ctrl) switch (key.key) {
                    .char => |c| switch (c) {
                        'c' => return .quit,
                        'g' => {
                            // T11: Open external editor with current composer buffer.
                            if (launchExternalEditor(app, ctx.persistent_allocator)) |cmd| return cmd;
                            return .none;
                        },
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
                // Session picker navigation (T10).
                if (app.state.mode == .session_picker) {
                    switch (key.key) {
                        .up => moveSessionSelection(app, -1),
                        .down => moveSessionSelection(app, 1),
                        .char => |c| switch (c) {
                            'k' => moveSessionSelection(app, -1),
                            'j' => moveSessionSelection(app, 1),
                            else => {},
                        },
                        .enter => {
                            app.resumeSelectedSession() catch |err| app.recordError(@errorName(err)) catch {};
                        },
                        .escape => app.state.mode = .normal,
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
                    // PageUp/PageDown scroll by 5 lines for faster navigation.
                    .page_up => app.state.transcript_scroll += 5,
                    .page_down => app.state.transcript_scroll -|= 5,
                    .escape => app.state.mode = .normal,
                    else => {},
                }
            },
            .mouse => |mouse| {
                if (mouse.event_type == .press) switch (mouse.button) {
                    .wheel_up => app.state.transcript_scroll += 3,
                    .wheel_down => app.state.transcript_scroll -|= 3,
                    else => {},
                };
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
        app.last_view_height = height;
        const status = status_bar_view.render(ctx.allocator, &app.state, .{ .width = width }) catch "";
        const composer = composer_view.render(ctx.allocator, &app.state, .{ .width = width }) catch "";
        const tool_height: usize = if (app.state.tools.items.len > 0) @min(@as(usize, 8), height / 4) else 2;
        const tools = tool_panel_view.render(ctx.allocator, &app.state, .{ .width = width, .height = tool_height }) catch "";
        const telemetry = telemetry_view.render(ctx.allocator, &app.state, .{ .width = width }) catch "";
        const extra = switch (app.state.mode) {
            .approval => approval_view.render(ctx.allocator, &app.state, .{ .width = width }) catch "",
            .preview => preview_view.render(ctx.allocator, &app.state, .{ .width = width, .height = height / 2 }) catch "",
            .session_picker => session_picker_view.render(ctx.allocator, &app.state, .{ .height = sessionPickerHeight(app), .offset = app.state.session_scroll }) catch "",
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

    fn moveSessionSelection(app: *App, delta: isize) void {
        const n = app.state.sessions.items.len;
        if (n == 0) {
            app.state.session_index = 0;
            app.state.session_scroll = 0;
            return;
        }
        if (delta < 0) {
            app.state.session_index -|= @as(usize, @intCast(-delta));
        } else {
            app.state.session_index = @min(n - 1, app.state.session_index + @as(usize, @intCast(delta)));
        }
        ensureSessionSelectionVisible(app);
    }

    fn ensureSessionSelectionVisible(app: *App) void {
        const height = sessionPickerHeight(app);
        if (app.state.session_index < app.state.session_scroll) {
            app.state.session_scroll = app.state.session_index;
        } else if (height > 0 and app.state.session_index >= app.state.session_scroll + height) {
            app.state.session_scroll = app.state.session_index + 1 - height;
        }
    }

    fn visibleSessionCount(app: *const App) usize {
        return @min(app.state.sessions.items.len -| app.state.session_scroll, sessionPickerHeight(app));
    }

    fn sessionPickerHeight(app: *const App) usize {
        return @max(app.last_view_height, 8) / 2;
    }
};

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

fn currentPathOwned(allocator: std.mem.Allocator) ![]u8 {
    const path_z = try std.process.currentPathAlloc(defaultIo(), allocator);
    defer allocator.free(path_z);
    return allocator.dupe(u8, path_z);
}

fn newerSessionFirst(_: void, a: session_store.SessionMetadata, b: session_store.SessionMetadata) bool {
    if (a.last_active == b.last_active) return std.mem.lessThan(u8, a.session_id, b.session_id);
    return a.last_active > b.last_active;
}

/// Generate a collision-resistant session ID, e.g. "20260523-150405-123-a1b2c3d4e5f60708".
fn generateSessionId(allocator: std.mem.Allocator) ![]u8 {
    const millis = compat.time.nowMillis();
    const secs: i64 = @divFloor(millis, 1000);
    const ms: i64 = @mod(millis, 1000);
    const epoch = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(@max(secs, 0))) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();
    var random_bytes: [8]u8 = undefined;
    compat.random.fillSecureBytes(&random_bytes);
    var random_hex: [16]u8 = undefined;
    encodeHexLower(&random_hex, &random_bytes);
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{d:0>3}-{s}",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
            ms,
            random_hex,
        },
    );
}

/// Format a session label from metadata: "model provider YYYY-MM-DD HH:MM".
fn formatSessionLabel(allocator: std.mem.Allocator, meta: session_store.SessionMetadata) ![]u8 {
    const ts = meta.last_active;
    const secs: i64 = @divFloor(ts, 1000);
    const epoch = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(@max(secs, 0))) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();
    return std.fmt.allocPrint(
        allocator,
        "{s} {s} {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}",
        .{
            if (meta.model.len > 0) meta.model else "unknown",
            if (meta.provider.len > 0) meta.provider else "",
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
        },
    );
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

test "session picker navigation pages through hidden rows" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    app.last_view_height = 8;
    try app.state.addSession("s1", "One");
    try app.state.addSession("s2", "Two");
    try app.state.addSession("s3", "Three");
    try app.state.addSession("s4", "Four");
    try app.state.addSession("s5", "Five");

    try std.testing.expectEqual(@as(usize, 4), TuiModel.visibleSessionCount(&app));
    TuiModel.moveSessionSelection(&app, 1);
    TuiModel.moveSessionSelection(&app, 1);
    TuiModel.moveSessionSelection(&app, 1);
    TuiModel.moveSessionSelection(&app, 1);
    try std.testing.expectEqual(@as(usize, 4), app.state.session_index);
    try std.testing.expectEqual(@as(usize, 1), app.state.session_scroll);
    try std.testing.expectEqual(@as(usize, 4), TuiModel.visibleSessionCount(&app));
}
