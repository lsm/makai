const std = @import("std");
const compat = @import("compat");
const zz = @import("zigzag");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const register_builtins = @import("register_builtins");
const agent = @import("agent");
const event_stream = @import("event_stream");
const tui_runtime = @import("tui_runtime");
const tui_state = @import("tui_state");
const tui_commands = @import("tui_commands");
const tui_login = @import("tui_login");
const tui_model_catalog = @import("tui_model_catalog");
const tui_config = @import("tui_config");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");
const oauth_storage = @import("oauth/storage");
const session_store = @import("tui_session_store");
const transcript_view = @import("tui_view_transcript");
const composer_view = @import("tui_view_composer");
const status_bar_view = @import("tui_view_status_bar");
const approval_view = @import("tui_view_approval");
const preview_view = @import("tui_view_preview");
const session_picker_view = @import("tui_view_session_picker");
const menu_picker_view = @import("tui_view_menu_picker");
const tui_render = @import("tui_render");
const permission = @import("permission");
const OwnedSlice = @import("owned_slice").OwnedSlice;
const tools_common = @import("tools/common");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub const TuiRuntime = tui_runtime.TuiRuntime;
pub const TuiRuntimeOptions = tui_runtime.TuiRuntimeOptions;

const max_session_event_jsonl_bytes = 8 * 1024 * 1024;
const max_session_event_payload_bytes = max_session_event_jsonl_bytes / 2;
const artifact_display_preview_read_limit = 256 * 1024;
const artifact_preview_head_lines = 40;
const artifact_preview_tail_lines = 20;

fn isSecretLoginPrompt(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "API key") != null or std.mem.indexOf(u8, message, "api key") != null;
}

fn firstArtifactReference(refs: []const u8) ?[]const u8 {
    var iter = std.mem.splitSequence(u8, refs, ", ");
    while (iter.next()) |ref| {
        const trimmed = std.mem.trim(u8, ref, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, ".makai/tool-artifacts/")) return trimmed;
    }
    return null;
}

fn artifactDisplayPreview(allocator: std.mem.Allocator, data: []const u8, raw_total_bytes: u64, reference: []const u8) ![]u8 {
    const safe_data = try sanitizeTerminalPreviewText(allocator, data);
    defer allocator.free(safe_data);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    const line_count = countTextLines(safe_data);
    const byte_count = if (raw_total_bytes > 0) raw_total_bytes else data.len;
    try writer.print("raw output preview ({d} bytes, {d} lines)\n", .{ byte_count, line_count });
    try writer.writeAll("head:\n");
    try writeFirstTextLines(writer, safe_data, artifact_preview_head_lines);
    if (line_count > artifact_preview_head_lines + artifact_preview_tail_lines) {
        try writer.writeAll("\n...\ntail:\n");
        try writeLastTextLines(allocator, writer, safe_data, artifact_preview_tail_lines);
    }
    try writer.print("\nartifact: {s}\nCtrl+O or /artifact opens the full local output. Ask for grep/range to filter without loading full output into context.", .{reference});
    return out.toOwnedSlice();
}

fn writeFirstTextLines(writer: *std.Io.Writer, data: []const u8, max_lines: usize) !void {
    var emitted: usize = 0;
    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| {
        if (emitted >= max_lines) break;
        try writer.writeAll(line);
        try writer.writeByte('\n');
        emitted += 1;
    }
}

fn writeLastTextLines(allocator: std.mem.Allocator, writer: *std.Io.Writer, data: []const u8, max_lines: usize) !void {
    if (max_lines == 0) return;
    const capacity = max_lines + 1;
    var starts = try allocator.alloc(usize, capacity);
    defer allocator.free(starts);
    var starts_len: usize = 1;
    starts[0] = 0;
    for (data, 0..) |c, i| {
        if (c == '\n' and i + 1 < data.len) {
            if (starts_len == capacity) {
                std.mem.copyForwards(usize, starts[0 .. capacity - 1], starts[1..capacity]);
                starts_len -= 1;
            }
            starts[starts_len] = i + 1;
            starts_len += 1;
        }
    }
    const start_index = if (starts_len > max_lines) starts_len - max_lines else 0;
    var i = start_index;
    while (i < starts_len) : (i += 1) {
        const start = starts[i];
        const end = if (i + 1 < starts_len) starts[i + 1] - 1 else data.len;
        try writer.writeAll(data[start..end]);
        try writer.writeByte('\n');
    }
}

fn countTextLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var lines: usize = 1;
    for (text) |c| {
        if (c == '\n') lines += 1;
    }
    if (text[text.len - 1] == '\n') lines -= 1;
    return lines;
}

fn sanitizeTerminalPreviewText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '\n', '\t' => {
                try writer.writeByte(c);
                i += 1;
                continue;
            },
            '\r' => {
                try writer.writeByte('\n');
                i += 1;
                continue;
            },
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
                i += 1;
                continue;
            },
            else => {},
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        _ = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += 1;
            continue;
        };
        try writer.writeAll(text[i .. i + len]);
        i += len;
    }
    return out.toOwnedSlice();
}

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

    /// Reject the currently pending approval wait without shutting the waiter
    /// down, so future approval requests can still block normally.
    pub fn rejectPending(self: *ApprovalWaiter) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.tool_call_id.len > 0) {
            self.decision = .reject;
        }
    }

    pub fn deinit(self: *ApprovalWaiter) void {
        self.cancel();
        if (self.tool_call_id.len > 0) self.allocator.free(self.tool_call_id);
        self.* = undefined;
    }
};

fn loadRuntimeModels(allocator: std.mem.Allocator) ![]ai_types.Model {
    return loadRuntimeModelsWithCatalog(allocator, tui_model_catalog.loadProductionModels, true);
}

fn loadRuntimeModelsFresh(allocator: std.mem.Allocator) ![]ai_types.Model {
    return loadRuntimeModelsWithCatalog(allocator, tui_model_catalog.refreshProductionModels, false);
}

fn loadRuntimeModelsWithCatalog(
    allocator: std.mem.Allocator,
    comptime loadCatalog: fn (std.mem.Allocator) anyerror![]ai_types.Model,
    comptime catch_catalog_errors: bool,
) ![]ai_types.Model {
    var catalog_models = loadCatalog(allocator) catch |err| if (catch_catalog_errors)
        try allocator.alloc(ai_types.Model, 0)
    else
        return err;
    errdefer tui_model_catalog.deinitModels(allocator, catalog_models);

    const models = try allocator.alloc(ai_types.Model, 1 + catalog_models.len);
    errdefer allocator.free(models);
    models[0] = defaultModel();
    for (catalog_models, 0..) |model, idx| {
        models[idx + 1] = model;
    }
    allocator.free(catalog_models);
    catalog_models = &.{};
    errdefer for (models) |*model| model.deinit(allocator);
    return models;
}

pub const ProductionRuntime = struct {
    allocator: std.mem.Allocator,
    registry: api_registry.ApiRegistry,
    bridge: agent.InProcessProviderProtocolBridge,
    permission_engine: permission.PermissionEngine,
    models: []ai_types.Model,
    initial_model: ?SavedModelRef = null,

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

        const models = try loadRuntimeModels(allocator);
        errdefer tui_model_catalog.deinitModels(allocator, models);

        var initial_model = loadSavedModelRef(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        errdefer if (initial_model) |*model| model.deinit(allocator);

        const runtime = ProductionRuntime{
            .allocator = allocator,
            .registry = registry,
            .bridge = undefined,
            .permission_engine = permission_engine,
            .models = models,
            .initial_model = initial_model,
        };
        initial_model = null;
        return runtime;
    }

    pub fn initBridge(self: *ProductionRuntime) void {
        self.bridge = agent.InProcessProviderProtocolBridge.init(&self.registry);
    }

    pub fn options(self: *ProductionRuntime) tui_runtime.TuiRuntimeOptions {
        return .{
            .protocol = (&self.bridge).protocolClient(),
            .models = self.models,
            .initial_model = if (self.initial_model) |model| .{
                .id = model.id,
                .provider = model.provider,
                .api = model.api,
            } else null,
            .permission_engine = &self.permission_engine,
            .workspace_root = self.permission_engine.workspace_root,
            .run_async = true,
            .compact_output = true,
        };
    }

    pub fn deinit(self: *ProductionRuntime) void {
        tui_model_catalog.deinitModels(self.allocator, self.models);
        if (self.initial_model) |*model| model.deinit(self.allocator);
        self.permission_engine.deinit();
        self.registry.deinit();
        self.* = undefined;
    }
};

const SavedModelRef = struct {
    id: []u8,
    provider: []u8,
    api: []u8,

    fn deinit(self: *SavedModelRef, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.provider);
        allocator.free(self.api);
        self.* = undefined;
    }
};

fn loadSavedModelRef(allocator: std.mem.Allocator) !?SavedModelRef {
    var store = tui_config.Store.initDefault(allocator) catch |err| switch (err) {
        error.HomeNotFound => return null,
        else => return err,
    };
    defer store.deinit();
    return try loadSavedModelRefFromStore(allocator, store);
}

fn loadSavedModelRefFromStore(allocator: std.mem.Allocator, store: tui_config.Store) !?SavedModelRef {
    var cfg = (try store.loadIfExists()) orelse return null;
    defer cfg.deinit(allocator);
    if (cfg.model.len == 0) return null;
    const id = try allocator.dupe(u8, cfg.model);
    errdefer allocator.free(id);
    const provider = try allocator.dupe(u8, cfg.provider);
    errdefer allocator.free(provider);
    const api = try allocator.dupe(u8, cfg.api);
    errdefer allocator.free(api);
    return .{
        .id = id,
        .provider = provider,
        .api = api,
    };
}

pub const App = struct {
    allocator: std.mem.Allocator,
    state: tui_state.AppState,
    runtime: ?*tui_runtime.TuiRuntime = null,
    session: ?tui_runtime.TuiSession = null,
    approval_waiter: ?*ApprovalWaiter = null,
    login: ?*tui_login.LoginSession = null,
    store: ?session_store.Store = null,
    session_id: []u8 = &.{},
    session_created_at: i64 = 0,
    working_dir: []u8 = &.{},
    last_view_height: usize = 8,
    inline_history_flushed: usize = 0,
    last_inline_view_lines: usize = 4,
    /// Text staged for the system clipboard, flushed to the terminal via OSC 52
    /// on the next `update` (where a mutable `Context` is available). Owned.
    ///
    /// `Ctrl+Y` / `/copy` provide an explicit OSC 52 copy path for when
    /// dragging selection isn't convenient.
    pending_clipboard: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, options: tui_runtime.TuiRuntimeOptions) !App {
        var runtime_options = options;
        const approval_waiter = try allocator.create(ApprovalWaiter);
        errdefer allocator.destroy(approval_waiter);
        approval_waiter.* = .{ .allocator = allocator };
        runtime_options.tool_approval_ctx = approval_waiter;
        runtime_options.tool_approval_callback = approvalCallback;
        // The runtime is heap-allocated so its address is stable: the session
        // created below stores a pointer back to it, and `App` is returned by
        // value (moved into its caller). An inline runtime would leave that
        // pointer dangling after the move.
        const runtime_ptr = try allocator.create(tui_runtime.TuiRuntime);
        runtime_ptr.* = tui_runtime.TuiRuntime.init(allocator, runtime_options) catch |err| {
            allocator.destroy(runtime_ptr);
            return err;
        };
        var app = App{
            .allocator = allocator,
            .state = tui_state.AppState.init(allocator),
            .runtime = runtime_ptr,
            .approval_waiter = approval_waiter,
        };
        errdefer app.deinit();
        app.session = app.runtime.?.createSession();
        app.state.permission_mode = app.runtime.?.permissionMode();
        app.state.thinking_level = app.runtime.?.thinkingLevel();
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
        // Pre-populate sessions list on a best-effort basis. Startup should not
        // lose the interactive runtime just because saved-session discovery fails.
        app.loadSessions() catch |err| try app.recordError(@errorName(err));
        return app;
    }

    pub fn initWithoutRuntime(allocator: std.mem.Allocator) App {
        return .{ .allocator = allocator, .state = tui_state.AppState.init(allocator) };
    }

    pub fn deinit(self: *App) void {
        if (self.login) |session| {
            session.deinit();
            self.login = null;
        }
        if (self.approval_waiter) |waiter| waiter.cancel();
        if (self.runtime) |runtime| {
            runtime.deinit();
            self.allocator.destroy(runtime);
        }
        if (self.approval_waiter) |waiter| {
            waiter.deinit();
            self.allocator.destroy(waiter);
        }
        if (self.store) |*store| store.deinit();
        if (self.pending_clipboard) |c| self.allocator.free(c);
        if (self.session_id.len > 0) self.allocator.free(self.session_id);
        if (self.working_dir.len > 0) self.allocator.free(self.working_dir);
        self.state.deinit();
        self.* = undefined;
    }

    /// Load sessions from the store into state.sessions.
    pub fn loadSessions(self: *App) !void {
        const store = self.store orelse return;
        var metas = try store.list();
        for (self.state.sessions.items) |*s| s.deinit(self.allocator);
        self.state.sessions.clearRetainingCapacity();
        defer {
            for (metas.items) |*meta| meta.deinit(self.allocator);
            metas.deinit(self.allocator);
        }
        std.mem.sort(session_store.SessionMetadata, metas.items, {}, newerSessionFirst);
        for (metas.items) |meta| {
            const label = try formatSessionLabel(self.allocator, meta);
            defer self.allocator.free(label);
            try self.state.addSessionWithDetails(meta.session_id, label, meta.model, meta.provider);
        }
    }

    /// Resume the session currently selected in the session picker.
    pub fn resumeSelectedSession(self: *App) !void {
        const store = self.store orelse return error.NoStoreConfigured;
        const runtime = if (self.runtime) |r| r else return error.NoRuntimeConfigured;
        self.state.clampSessionSelectionToFilter();
        const selected = self.state.sessionAtFilteredIndex(self.state.session_index) orelse return;
        const id = selected.id;
        var loaded = try store.resumeSession(id, runtime);
        defer loaded.deinit(self.allocator);
        const new_session_id = try self.allocator.dupe(u8, loaded.metadata.session_id);
        self.discardPendingEvents();
        self.state.resetReplayState();
        self.inline_history_flushed = 0;
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
            try self.applyRuntimeEvent(event.*);
            self.hydrateToolDisplayPreview(event.*) catch |err| try self.recordError(@errorName(err));
        }
        if (self.session) |*session| session.clearQueuedMessages();
        self.state.clearQueuedPreviews();
        self.refreshQueuedCounts();
        self.state.status.streaming = false;
        self.state.mode = .normal;
    }

    /// Providers that expose an interactive login or API-key setup flow.
    const login_providers = [_][]const u8{ "anthropic", "github-copilot", "openai-codex", "kimi" };

    const permission_modes = [_]tui_runtime.PermissionMode{ .bypass, .ask };

    const view_modes = [_]tui_state.TranscriptVisibilityMode{ .everything, .verbose, .balanced, .chat };

    const thinking_levels = [_]ai_types.ThinkingLevel{ .off, .low, .medium, .high, .xhigh };

    const export_methods = [_]ExportMethod{ .clipboard, .file };

    const ExportMethod = enum {
        clipboard,
        file,
    };

    fn loginProviderEnum(idx: usize) tui_login.Provider {
        return switch (idx) {
            0 => .anthropic,
            1 => .github_copilot,
            2 => .openai_codex,
            3 => .kimi,
            else => .anthropic,
        };
    }

    fn loginProviderIndex(provider_id: []const u8) ?usize {
        for (login_providers, 0..) |provider, idx| {
            if (std.mem.eql(u8, provider_id, provider)) return idx;
        }
        if (std.mem.eql(u8, provider_id, "codex") or std.mem.eql(u8, provider_id, "openai")) return 2;
        if (std.mem.eql(u8, provider_id, "github")) return 1;
        if (std.mem.eql(u8, provider_id, "moonshot")) return 3;
        return null;
    }

    /// Open the model picker, pre-selecting the currently active model.
    fn openModelPicker(self: *App) void {
        self.state.menu_scroll = 0;
        self.state.menu_index = 0;
        const runtime = self.runtime orelse return self.enterMenu(.model_picker);
        const current = runtime.currentModel();
        if (current) |active| {
            for (runtime.availableModels(), 0..) |model, i| {
                if (std.mem.eql(u8, model.id, active.id)) {
                    self.state.menu_index = i;
                    break;
                }
            }
        }
        self.enterMenu(.model_picker);
    }

    fn openPermissionPicker(self: *App) void {
        self.state.menu_scroll = 0;
        self.state.menu_index = 0;
        if (self.runtime) |runtime| self.state.permission_mode = runtime.permissionMode();
        for (permission_modes, 0..) |mode, i| {
            if (mode == self.state.permission_mode) {
                self.state.menu_index = i;
                break;
            }
        }
        self.enterMenu(.permission_picker);
    }

    fn openViewPicker(self: *App) void {
        self.state.menu_scroll = 0;
        self.state.menu_index = 0;
        for (view_modes, 0..) |mode, i| {
            if (mode == self.state.transcript_mode) {
                self.state.menu_index = i;
                break;
            }
        }
        self.enterMenu(.view_picker);
    }

    fn openThinkingPicker(self: *App) void {
        self.state.menu_scroll = 0;
        self.state.menu_index = 0;
        if (self.runtime) |runtime| self.state.thinking_level = runtime.thinkingLevel();
        for (thinking_levels, 0..) |level, i| {
            if (level == self.state.thinking_level) {
                self.state.menu_index = i;
                break;
            }
        }
        self.enterMenu(.thinking_picker);
    }

    fn openExportPicker(self: *App) void {
        self.state.menu_scroll = 0;
        self.state.menu_index = 0;
        self.enterMenu(.export_picker);
    }

    fn enterMenu(self: *App, mode: tui_state.AppMode) void {
        self.state.mode = mode;
        self.ensureMenuSelectionVisible();
    }

    fn menuItemCount(self: *const App) usize {
        return switch (self.state.mode) {
            .model_picker => if (self.runtime) |runtime| runtime.availableModels().len else 0,
            .login_picker => login_providers.len,
            .permission_picker => permission_modes.len,
            .view_picker => view_modes.len,
            .thinking_picker => thinking_levels.len,
            .export_picker => export_methods.len,
            else => 0,
        };
    }

    /// Apply the model highlighted in the model picker, then return to normal.
    fn applySelectedModel(self: *App) !void {
        const runtime = self.runtime orelse return error.NoRuntimeConfigured;
        const models = runtime.availableModels();
        if (models.len == 0 or self.state.menu_index >= models.len) {
            self.state.mode = .normal;
            return;
        }
        const model = models[self.state.menu_index];
        if (self.session) |*session| {
            try session.switchModelExact(model);
        } else {
            try runtime.switchModelExact(model);
        }
        if (runtime.currentModel()) |m| {
            try self.state.status.setModelWithContext(self.allocator, m.id, m.provider, m.context_window);
            self.state.telemetry.context_window = m.context_window;
        }
        self.persistCurrentModel();
        self.state.mode = .normal;
        const msg = try std.fmt.allocPrint(self.allocator, "model switched to {s} ({s})", .{ model.id, model.provider });
        defer self.allocator.free(msg);
        try self.state.appendTranscript(.system, msg);
    }

    /// Start the login/setup worker for a provider index. The flow then drives
    /// forward via `pollLogin()` on each tick.
    fn startLoginProviderIndex(self: *App, idx: usize) !void {
        const provider = login_providers[idx];
        self.state.mode = .normal;
        if (self.login != null) {
            try self.state.appendTranscript(.system, "a login is already in progress");
            return;
        }
        self.login = tui_login.LoginSession.start(self.allocator, loginProviderEnum(idx)) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "could not start login for {s}: {s}", .{ provider, @errorName(err) });
            defer self.allocator.free(msg);
            try self.state.appendTranscript(.@"error", msg);
            return;
        };
        const msg = try std.fmt.allocPrint(self.allocator, "starting login for {s}…", .{provider});
        defer self.allocator.free(msg);
        try self.state.appendTranscript(.system, msg);
    }

    fn startLoginProviderName(self: *App, provider_id: []const u8) !void {
        const idx = loginProviderIndex(provider_id) orelse {
            const msg = try std.fmt.allocPrint(self.allocator, "unknown login provider: {s}", .{provider_id});
            defer self.allocator.free(msg);
            try self.state.status.setError(self.allocator, msg);
            try self.state.appendTranscript(.@"error", msg);
            return;
        };
        try self.startLoginProviderIndex(idx);
    }

    /// Start the login/setup worker for the highlighted provider.
    fn applySelectedLogin(self: *App) !void {
        const idx = @min(self.state.menu_index, login_providers.len - 1);
        try self.startLoginProviderIndex(idx);
    }

    fn applySelectedPermission(self: *App) !void {
        const idx = @min(self.state.menu_index, permission_modes.len - 1);
        const mode = permission_modes[idx];
        const runtime = self.runtime orelse return error.NoRuntimeConfigured;
        try runtime.setPermissionMode(mode);
        self.state.permission_mode = mode;
        self.state.mode = .normal;
        const msg = try std.fmt.allocPrint(self.allocator, "permission mode set to {s}", .{@tagName(mode)});
        defer self.allocator.free(msg);
        try self.state.appendTranscript(.system, msg);
    }

    fn applySelectedView(self: *App) !void {
        const idx = @min(self.state.menu_index, view_modes.len - 1);
        const mode = view_modes[idx];
        self.state.setTranscriptMode(mode);
        self.state.mode = .normal;
        const msg = try std.fmt.allocPrint(self.allocator, "view mode set to {s}", .{@tagName(mode)});
        defer self.allocator.free(msg);
        try self.state.appendTranscript(.system, msg);
    }

    fn applySelectedThinking(self: *App) !void {
        const idx = @min(self.state.menu_index, thinking_levels.len - 1);
        const level = thinking_levels[idx];
        if (self.runtime) |runtime| runtime.setThinkingLevel(level);
        self.state.thinking_level = level;
        self.state.mode = .normal;
        const msg = try std.fmt.allocPrint(self.allocator, "thinking level set to {s}", .{@tagName(level)});
        defer self.allocator.free(msg);
        try self.state.appendTranscript(.system, msg);
    }

    fn applySelectedExport(self: *App) !void {
        const idx = @min(self.state.menu_index, export_methods.len - 1);
        const method = export_methods[idx];
        self.state.mode = .normal;
        switch (method) {
            .clipboard => self.exportTranscriptToClipboard(),
            .file => try self.exportTranscriptToFile(null),
        }
    }

    /// Drive the active login session forward. Called each tick; surfaces the
    /// authorization URL, switches to an input prompt when the worker blocks on
    /// pasted input, and persists credentials when the flow completes.
    fn pollLogin(self: *App) !void {
        const session = self.login orelse return;
        switch (session.poll()) {
            .none => {},
            .show_auth => |auth| {
                const msg = if (auth.instructions) |ins|
                    try std.fmt.allocPrint(self.allocator, "open this URL to authorize:\n{s}\n{s}", .{ auth.url, ins })
                else
                    try std.fmt.allocPrint(self.allocator, "open this URL to authorize:\n{s}", .{auth.url});
                defer self.allocator.free(msg);
                try self.state.appendTranscript(.system, msg);
            },
            .request_input => |req| {
                const msg = try std.fmt.allocPrint(self.allocator, "{s} (type your answer and press Enter)", .{req.message});
                defer self.allocator.free(msg);
                try self.state.appendTranscript(.system, msg);
                self.state.login_input_secret = isSecretLoginPrompt(req.message);
                self.state.mode = .login_input;
            },
            .done => |creds| {
                const provider_id = session.provider_id;
                const save_err = self.saveLoginCredentials(provider_id, creds);
                creds.deinit(self.allocator);
                self.finishLogin();
                if (save_err) |_| {
                    const refresh_err = self.refreshModelsAfterLogin();
                    const msg = try std.fmt.allocPrint(self.allocator, "logged in to {s}", .{provider_id});
                    defer self.allocator.free(msg);
                    try self.state.appendTranscript(.system, msg);
                    if (refresh_err) |_| {
                        try self.state.appendTranscript(.system, "model catalog refreshed");
                    } else |err| {
                        const refresh_msg = try std.fmt.allocPrint(self.allocator, "login succeeded but refreshing models failed: {s}", .{@errorName(err)});
                        defer self.allocator.free(refresh_msg);
                        try self.state.appendTranscript(.@"error", refresh_msg);
                    }
                } else |err| {
                    const msg = try std.fmt.allocPrint(self.allocator, "login succeeded but saving credentials failed: {s}", .{@errorName(err)});
                    defer self.allocator.free(msg);
                    try self.state.appendTranscript(.@"error", msg);
                }
            },
            .failed => |name| {
                const msg = try std.fmt.allocPrint(self.allocator, "login failed: {s}", .{name});
                defer self.allocator.free(msg);
                self.finishLogin();
                try self.state.appendTranscript(.@"error", msg);
            },
        }
    }

    /// Tear down the active login session and leave any input mode.
    fn finishLogin(self: *App) void {
        if (self.login) |session| {
            session.deinit();
            self.login = null;
        }
        if (self.state.mode == .login_input) self.state.mode = .normal;
    }

    /// Persist freshly obtained credentials, replacing any existing entry for
    /// the provider. Does not take ownership of `creds`.
    fn saveLoginCredentials(self: *App, provider_id: []const u8, creds: oauth_storage.Credentials) !void {
        var storage = try oauth_storage.AuthStorage.loadDefault(self.allocator);
        defer storage.deinit();

        const key = try self.allocator.dupe(u8, provider_id);
        var owned = false;
        errdefer if (!owned) self.allocator.free(key);
        if (std.mem.eql(u8, provider_id, "kimi")) {
            // Kimi uses API key auth with optional region in provider_data
            const api_key = try self.allocator.dupe(u8, creds.access);
            errdefer if (!owned) self.allocator.free(api_key);

            // Copy provider_data if present (format: "region:china" or "region:global")
            const provider_data: ?[]const u8 = if (creds.provider_data) |pd|
                try self.allocator.dupe(u8, pd)
            else
                null;
            errdefer if (!owned) {
                if (provider_data) |pd| self.allocator.free(pd);
            };

            if (storage.providers.fetchRemove(provider_id)) |removed| {
                self.allocator.free(removed.key);
                removed.value.deinit(self.allocator);
            }

            // Store with region data if present
            if (provider_data) |pd| {
                try storage.providers.put(key, .{ .oauth = .{
                    .refresh = "",
                    .access = api_key,
                    .expires = std.math.maxInt(i64),
                    .provider_data = pd,
                } });
            } else {
                try storage.providers.put(key, .{ .api_key = api_key });
            }
            owned = true;
            try storage.persist();
            return;
        }

        const refresh = try self.allocator.dupe(u8, creds.refresh);
        errdefer if (!owned) self.allocator.free(refresh);
        const access = try self.allocator.dupe(u8, creds.access);
        errdefer if (!owned) self.allocator.free(access);
        const pd: ?[]const u8 = if (creds.provider_data) |d| try self.allocator.dupe(u8, d) else null;
        errdefer if (!owned) {
            if (pd) |d| self.allocator.free(d);
        };

        if (storage.providers.fetchRemove(provider_id)) |removed| {
            self.allocator.free(removed.key);
            removed.value.deinit(self.allocator);
        }

        try storage.providers.put(key, .{ .oauth = .{
            .refresh = refresh,
            .access = access,
            .expires = creds.expires,
            .provider_data = pd,
        } });
        owned = true;
        try storage.persist();
    }

    fn refreshModelsAfterLogin(self: *App) !void {
        const runtime = self.runtime orelse return;
        const current_model = runtime.currentModel();
        const models = try loadRuntimeModelsFresh(self.allocator);
        defer tui_model_catalog.deinitModels(self.allocator, models);
        try runtime.replaceModels(models, current_model);
    }

    /// Hand pasted input to the worker the login flow is blocked on.
    fn submitLoginInput(self: *App, text: []const u8) void {
        const session = self.login orelse {
            self.state.mode = .normal;
            return;
        };
        session.provideInput(text) catch |err| {
            self.recordError(@errorName(err)) catch {};
            return;
        };
        self.state.login_input_secret = false;
        self.state.mode = .normal;
    }

    /// Abort an in-progress login.
    fn cancelLogin(self: *App) void {
        self.finishLogin();
        self.state.appendTranscript(.system, "login cancelled") catch {};
        self.state.composer.clear();
        self.state.login_input_secret = false;
        self.state.mode = .normal;
    }

    fn moveMenuSelection(self: *App, delta: isize) void {
        const n = self.menuItemCount();
        if (n == 0) {
            self.state.menu_index = 0;
            self.state.menu_scroll = 0;
            return;
        }
        if (delta < 0) {
            self.state.menu_index -|= @as(usize, @intCast(-delta));
        } else {
            self.state.menu_index = @min(n - 1, self.state.menu_index + @as(usize, @intCast(delta)));
        }
        self.ensureMenuSelectionVisible();
    }

    fn ensureMenuSelectionVisible(self: *App) void {
        const height = @max(self.last_view_height, 8) / 2;
        if (self.state.menu_index < self.state.menu_scroll) {
            self.state.menu_scroll = self.state.menu_index;
        } else if (height > 0 and self.state.menu_index >= self.state.menu_scroll + height) {
            self.state.menu_scroll = self.state.menu_index + 1 - height;
        }
    }

    /// Save one event to the session store (best-effort: ignores errors).
    fn saveEvent(self: *App, event: tui_runtime.TuiEvent) void {
        const store = self.store orelse return;
        // Save replay-critical and debug-visible events while still rejecting
        // oversized payloads that would make the JSONL session unwieldy.
        switch (event) {
            .message_start, .tool_execution_start, .context_usage, .prompt_segment_usage, .agent_start, .turn_start, .turn_end, .agent_end => {},
            .text_delta => |payload| {
                if (jsonStringBudget(payload.delta.slice()) > max_session_event_payload_bytes) return;
            },
            .thinking_delta => |payload| {
                if (jsonStringBudget(payload.delta.slice()) > max_session_event_payload_bytes) return;
            },
            .tool_call_delta => |payload| {
                if (jsonStringBudget(payload.delta.slice()) > max_session_event_payload_bytes) return;
            },
            .provider_event => |payload| {
                if (jsonStringBudget(payload.event_json.slice()) > max_session_event_payload_bytes) return;
            },
            .tool_approval_requested => |payload| {
                if (toolRequestPayloadSize(payload) > max_session_event_payload_bytes) return;
            },
            .tool_execution_update => |payload| {
                if (toolUpdatePayloadSize(payload) > max_session_event_payload_bytes) return;
            },
            .message_end => |payload| {
                if (messageEndPayloadSize(payload) > max_session_event_payload_bytes) return;
            },
            .tool_execution_end => |payload| {
                if (toolExecutionEndPayloadSize(payload) > max_session_event_payload_bytes) return;
            },
            .system_warning => |payload| {
                if (jsonStringBudget(payload.message.slice()) > max_session_event_payload_bytes) return;
            },
            .backpressure_status => {},
            .@"error" => |payload| {
                if (jsonStringBudget(payload.message.slice()) > max_session_event_payload_bytes) return;
            },
        }
        const meta = self.currentSessionMetadata();
        store.save(meta, event) catch {};
    }

    fn messageEndPayloadSize(payload: @TypeOf(@as(tui_runtime.TuiEvent, undefined).message_end)) usize {
        return jsonStringBudget(payload.text.slice()) +
            jsonStringBudget(payload.content_json.slice()) +
            jsonStringBudget(payload.tool_call_id.slice()) +
            jsonStringBudget(payload.tool_name.slice()) +
            jsonStringBudget(payload.args_json.slice()) +
            jsonStringBudget(payload.tool_calls_json.slice()) +
            jsonStringBudget(payload.details_json.slice()) +
            jsonStringBudget(payload.artifacts_json.slice());
    }

    fn toolExecutionEndPayloadSize(payload: @TypeOf(@as(tui_runtime.TuiEvent, undefined).tool_execution_end)) usize {
        return jsonStringBudget(payload.result_json.slice()) +
            jsonStringBudget(payload.tool_call_id.slice()) +
            jsonStringBudget(payload.tool_name.slice()) +
            jsonStringBudget(payload.artifact_refs.slice());
    }

    fn toolRequestPayloadSize(payload: anytype) usize {
        return jsonStringBudget(payload.tool_call_id.slice()) +
            jsonStringBudget(payload.tool_name.slice()) +
            jsonStringBudget(payload.args_json.slice());
    }

    fn toolUpdatePayloadSize(payload: @TypeOf(@as(tui_runtime.TuiEvent, undefined).tool_execution_update)) usize {
        return toolRequestPayloadSize(payload) +
            jsonStringBudget(payload.partial_result_json.slice());
    }

    fn jsonStringBudget(value: []const u8) usize {
        return value.len * 6;
    }

    test "json string budget accounts for worst-case escaping" {
        try std.testing.expectEqual(@as(usize, 24), jsonStringBudget("\\\\\\\\"));
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
        var completed_agent_end = false;
        while (session.popEvent()) |event| {
            var ev = event;
            defer ev.deinit(self.allocator);
            if (ev == .agent_end and ev.agent_end.reason == .completed) completed_agent_end = true;
            self.saveEvent(ev);
            try self.applyRuntimeEvent(ev);
            try self.hydrateToolDisplayPreview(ev);
        }
        self.refreshQueuedCounts();
        self.syncBackpressureState();
        if (completed_agent_end and self.state.queue.total() > 0) {
            session.resumeSession() catch |err| {
                try self.state.status.setError(self.allocator, @errorName(err));
                try self.state.appendTranscript(.@"error", @errorName(err));
                return;
            };
            self.refreshQueuedCounts();
        }
    }

    fn applyRuntimeEvent(self: *App, event: tui_runtime.TuiEvent) !void {
        switch (event) {
            .message_start => |payload| {
                if (payload.role == .user) return;
            },
            .message_end => |payload| {
                if (payload.role == .user) {
                    try self.appendRuntimeUserMessage(payload.text.slice());
                    return;
                }
            },
            else => {},
        }
        try self.state.applyEvent(event);
    }

    fn appendRuntimeUserMessage(self: *App, text: []const u8) !void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        _ = self.state.consumeQueuedPreviewText(trimmed);
        if (self.state.transcript.items.len > 0) {
            const last = &self.state.transcript.items[self.state.transcript.items.len - 1];
            if (last.kind == .user and std.mem.eql(u8, last.text.items, trimmed)) return;
        }
        try self.state.appendUserMessage(trimmed);
    }

    fn syncBackpressureState(self: *App) void {
        const runtime = self.runtime orelse return;
        const bp = runtime.backpressureState();
        self.state.backpressure_active = bp.active;
        self.state.dropped_event_count = bp.dropped_count;
    }

    fn refreshQueuedCounts(self: *App) void {
        if (self.session) |*session| {
            const counts = session.queuedCounts();
            self.state.setQueuedCounts(counts);
            if (!self.state.status.streaming) self.state.pruneQueuedPreviewsToCounts(counts);
        }
    }

    fn steeringAvailable(self: *const App) bool {
        if (self.runtime) |runtime| return runtime.canSteer();
        if (self.session) |*session| return session.canSteer();
        return false;
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
        self.state.stream_aborted = false;
        if (self.session) |*session| {
            session.submitTurn(trimmed) catch |err| {
                if (err == error.QueueFull) return err;
                try self.state.status.setError(self.allocator, @errorName(err));
                try self.state.appendTranscript(.@"error", @errorName(err));
                return;
            };
        }
        try self.state.appendUserMessage(trimmed);
        self.refreshQueuedCounts();
    }

    pub fn steer(self: *App, text: []const u8) !void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        if (trimmed[0] == '/') return try self.submitCommand(trimmed);
        if (self.session) |*session| {
            try session.steer(trimmed);
            try self.state.addQueuedPreview(.steering, trimmed);
            self.refreshQueuedCounts();
            return;
        }
        try self.state.appendUserMessage(trimmed);
    }

    pub fn queueFollowUp(self: *App, text: []const u8) !void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        if (trimmed[0] == '/') return try self.submitCommand(trimmed);
        if (self.session) |*session| {
            try session.queueFollowUp(trimmed);
            try self.state.addQueuedPreview(.follow_up, trimmed);
            self.refreshQueuedCounts();
            return;
        }
        try self.state.appendUserMessage(trimmed);
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

        if (command.kind == .sessions or command.kind == .@"resume") self.loadSessions() catch |err| {
            try self.state.status.setError(self.allocator, @errorName(err));
            try self.state.appendTranscript(.@"error", @errorName(err));
            return;
        };

        var result = tui_commands.dispatch(.{
            .allocator = self.allocator,
            .state = &self.state,
            .runtime = if (self.runtime) |runtime| runtime else null,
            .session = if (self.session) |*session| session else null,
        }, command) catch |err| {
            try self.state.status.setError(self.allocator, @errorName(err));
            try self.state.appendTranscript(.@"error", @errorName(err));
            return;
        };
        defer result.deinit(self.allocator);

        if (command.kind == .abort) {
            if (self.approval_waiter) |waiter| waiter.rejectPending();
        }

        switch (result.action) {
            .quit => return error.QuitRequested,
            .clear_transcript => {
                self.state.clearTranscript();
                self.inline_history_flushed = 0;
            },
            .open_session_picker => {
                // Refresh sessions list from store then open the picker.
                try self.loadSessions();
                self.state.session_index = 0;
                self.state.session_scroll = 0;
                self.state.session_filter.clear();
                self.state.mode = .session_picker;
            },
            .open_model_picker => self.openModelPicker(),
            .open_login_picker => {
                self.state.menu_index = 0;
                self.state.menu_scroll = 0;
                self.state.mode = .login_picker;
            },
            .open_permission_picker => self.openPermissionPicker(),
            .open_view_picker => self.openViewPicker(),
            .open_thinking_picker => self.openThinkingPicker(),
            .open_export_picker => self.openExportPicker(),
            .start_login_provider => try self.startLoginProviderName(result.login_provider),
            .copy_last => self.copyLastAssistant(),
            .copy_all => self.copyTranscript(),
            .open_artifact_viewer => try self.openLatestArtifact(),
            .export_file => try self.exportTranscriptToFile(if (result.export_path.len > 0) result.export_path else null),
            .none => {},
        }
        if ((command.kind == .model or command.kind == .provider) and command.arg != null) self.persistCurrentModel();
        if (result.output.len > 0) {
            try self.state.appendTranscript(if (result.is_error) .@"error" else .system, result.output);
            if (result.is_error) try self.state.status.setError(self.allocator, result.output);
        }
    }

    pub fn recordError(self: *App, message: []const u8) !void {
        if (std.mem.eql(u8, message, "QueueFull")) {
            try self.state.status.setError(self.allocator, "stream backlog; draining");
            return;
        }
        try self.state.status.setError(self.allocator, message);
        try self.state.appendTranscript(.@"error", message);
    }

    fn persistCurrentModel(self: *App) void {
        const runtime = self.runtime orelse return;
        const model = runtime.currentModel() orelse return;
        self.persistSelectedModel(model) catch |err| self.recordError(@errorName(err)) catch {};
    }

    fn persistSelectedModel(self: *App, model: ai_types.Model) !void {
        var store = try tui_config.Store.initDefault(self.allocator);
        defer store.deinit();
        var cfg = try store.load();
        defer cfg.deinit(self.allocator);

        try replaceOwnedString(self.allocator, &cfg.model, model.id);
        try replaceOwnedString(self.allocator, &cfg.provider, model.provider);
        try replaceOwnedString(self.allocator, &cfg.api, model.api);
        try store.save(cfg);
    }

    fn replaceOwnedString(allocator: std.mem.Allocator, field: *[]u8, value: []const u8) !void {
        const next = try allocator.dupe(u8, value);
        allocator.free(field.*);
        field.* = next;
    }

    /// Stage text for the system clipboard. The bytes are copied; the actual
    /// OSC 52 write happens in `update` via `flushClipboard`.
    fn stageClipboard(self: *App, text: []const u8) void {
        const dup = self.allocator.dupe(u8, text) catch return;
        if (self.pending_clipboard) |old| self.allocator.free(old);
        self.pending_clipboard = dup;
    }

    /// Write any staged clipboard text to the terminal's clipboard (OSC 52).
    fn flushClipboard(self: *App, ctx: *zz.Context) void {
        const text = self.pending_clipboard orelse return;
        self.pending_clipboard = null;
        defer self.allocator.free(text);
        _ = ctx.setClipboard(text) catch {};
    }

    /// Copy the most recent assistant reply to the system clipboard.
    fn copyLastAssistant(self: *App) void {
        const text = self.state.lastAssistantText() orelse {
            self.state.appendTranscript(.system, "nothing to copy yet") catch {};
            return;
        };
        self.stageClipboard(text);
        self.state.appendTranscript(.system, "copied last reply to clipboard") catch {};
    }

    /// Copy the full transcript to the system clipboard.
    fn copyTranscript(self: *App) void {
        const text = self.state.transcriptToText(self.allocator) catch {
            self.recordError("copy failed") catch {};
            return;
        };
        defer self.allocator.free(text);
        if (text.len == 0) {
            self.state.appendTranscript(.system, "nothing to copy yet") catch {};
            return;
        }
        self.stageClipboard(text);
        self.state.appendTranscript(.system, "copied transcript to clipboard") catch {};
    }

    fn copyPreview(self: *App) void {
        if (self.state.preview.content.len == 0) {
            self.state.appendTranscript(.system, "nothing to copy yet") catch {};
            return;
        }
        self.stageClipboard(self.state.preview.content);
        self.state.appendTranscript(.system, "copied preview to clipboard") catch {};
    }

    fn openLatestArtifact(self: *App) !void {
        var i = self.state.tools.items.len;
        while (i > 0) {
            i -= 1;
            const refs = self.state.tools.items[i].artifact_refs;
            const reference = firstArtifactReference(refs) orelse continue;
            const data = tools_common.retrieveArtifact(self.allocator, reference, 64 * 1024 * 1024) catch |err| {
                try self.recordError(@errorName(err));
                return;
            };
            defer self.allocator.free(data);
            const safe_data = try sanitizeTerminalPreviewText(self.allocator, data);
            defer self.allocator.free(safe_data);
            try self.state.setPreview(.artifact, reference, safe_data);
            return;
        }
        try self.state.appendTranscript(.system, "no local artifact to open");
    }

    fn hydrateToolDisplayPreview(self: *App, event: tui_runtime.TuiEvent) !void {
        switch (event) {
            .tool_execution_end => |payload| {
                if (payload.artifact_count == 0) return;
                const reference = firstArtifactReference(payload.artifact_refs.slice()) orelse return;
                const data = tools_common.retrieveArtifactPrefix(self.allocator, reference, artifact_display_preview_read_limit) catch return;
                defer self.allocator.free(data);
                const preview = try artifactDisplayPreview(self.allocator, data, payload.raw_total_bytes, reference);
                errdefer self.allocator.free(preview);
                for (self.state.tools.items) |*tool| {
                    if (!std.mem.eql(u8, tool.id, payload.tool_call_id.slice())) continue;
                    if (tool.display_preview.len > 0) self.allocator.free(tool.display_preview);
                    tool.display_preview = preview;
                    return;
                }
                self.allocator.free(preview);
            },
            else => {},
        }
    }

    fn exportTranscriptToClipboard(self: *App) void {
        const text = self.state.transcriptToMarkdown(self.allocator) catch |err| {
            self.recordExportError("clipboard", err) catch {};
            return;
        };
        defer self.allocator.free(text);
        if (text.len == 0) {
            self.state.appendTranscript(.system, "nothing to export yet") catch {};
            return;
        }
        self.stageClipboard(text);
        self.state.appendTranscript(.system, "exported transcript to clipboard") catch {};
    }

    fn exportTranscriptToFile(self: *App, maybe_path: ?[]const u8) !void {
        const text = self.state.transcriptToMarkdown(self.allocator) catch |err| {
            try self.recordExportError("file", err);
            return;
        };
        defer self.allocator.free(text);
        if (text.len == 0) {
            try self.state.appendTranscript(.system, "nothing to export yet");
            return;
        }

        const owned_default = if (maybe_path == null) try defaultExportPath(self.allocator) else null;
        defer if (owned_default) |path| self.allocator.free(path);
        const path = maybe_path orelse owned_default.?;

        var file = std.Io.Dir.createFile(.cwd(), defaultIo(), path, .{ .truncate = true }) catch |err| {
            try self.recordExportError(path, err);
            return;
        };
        defer file.close(defaultIo());
        file.writeStreamingAll(defaultIo(), text) catch |err| {
            try self.recordExportError(path, err);
            return;
        };

        const msg = try std.fmt.allocPrint(self.allocator, "exported transcript to {s}", .{path});
        defer self.allocator.free(msg);
        try self.state.appendTranscript(.system, msg);
    }

    fn recordExportError(self: *App, target: []const u8, err: anyerror) !void {
        const msg = try std.fmt.allocPrint(self.allocator, "export failed for {s}: {s}", .{ target, @errorName(err) });
        defer self.allocator.free(msg);
        try self.recordError(msg);
    }

    fn cycleThinkingLevel(self: *App) void {
        const level = self.state.cycleThinkingLevel();
        if (self.runtime) |runtime| runtime.setThinkingLevel(level);
    }

    pub fn appendWelcome(self: *App) !void {
        if (self.state.sessions.items.len == 0) {
            const model = if (self.state.status.model.len > 0) self.state.status.model else "no-model";
            const provider = if (self.state.status.provider.len > 0) self.state.status.provider else "local";
            const cwd = if (self.working_dir.len > 0) self.working_dir else ".";
            const tips = if (self.steeringAvailable())
                "Enter submit • Enter while streaming steers • Alt+Enter queues follow-up • /sessions resumes • Ctrl+G editor • Shift+Tab thinking level • Ctrl+Y copy reply • Ctrl+D timestamp • /help commands"
            else
                "Enter submit • Alt+Enter queues follow-up • /sessions resumes • Ctrl+G editor • Shift+Tab thinking level • Ctrl+Y copy reply • Ctrl+D timestamp • /help commands";
            const welcome = try std.fmt.allocPrint(self.allocator,
                \\Makai TUI
                \\model: {s}/{s}
                \\cwd: {s}
                \\tips: {s}
            , .{ provider, model, cwd, tips });
            defer self.allocator.free(welcome);
            try self.state.appendTranscript(.system, welcome);
            return;
        }
        const model = if (self.state.status.model.len > 0) self.state.status.model else "no-model";
        const provider = if (self.state.status.provider.len > 0) self.state.status.provider else "local";
        const welcome = try std.fmt.allocPrint(self.allocator, "Makai TUI • {s}/{s} • /sessions resumes saved work", .{ provider, model });
        defer self.allocator.free(welcome);
        try self.state.appendTranscript(.system, welcome);
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

pub const TuiModel = struct {
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
            app.appendWelcome() catch |err| app.recordError(@errorName(err)) catch {};
        }
        return .{ .every = 50 * std.time.ns_per_ms };
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
                return editorReturnCommand();
            },
            .editor_failed => {
                app.recordError("external editor failed") catch {};
                return editorReturnCommand();
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
                        't' => {
                            app.state.toggleLatestToolExpanded();
                            return .none;
                        },
                        'o' => {
                            app.openLatestArtifact() catch |err| app.recordError(@errorName(err)) catch {};
                            return .none;
                        },
                        'y' => {
                            if (app.state.mode == .preview) app.copyPreview() else app.copyLastAssistant();
                            app.flushClipboard(ctx);
                            return .none;
                        },
                        'd' => {
                            // Issue #137: cycle time → date+time → off for
                            // transcript message timestamps.
                            _ = app.state.cycleTimestampDisplay();
                            return .none;
                        },
                        'p' => {
                            if (app.state.mode == .normal) _ = app.state.composerHistoryPrev() catch false;
                            return .none;
                        },
                        'n' => {
                            if (app.state.mode == .normal) _ = app.state.composerHistoryNext() catch false;
                            return .none;
                        },
                        else => return .none,
                    },
                    else => {},
                };
                if (key.key == .tab and key.modifiers.eql(.{ .shift = true })) {
                    app.cycleThinkingLevel();
                    return .none;
                }
                if (app.state.mode == .approval) {
                    const composer_empty = app.state.composer.buffer.items.len == 0;
                    if (composer_empty) {
                        var decided = false;
                        switch (key.key) {
                            .char => |c| switch (c) {
                                'y' => {
                                    app.decideApproval(true, false) catch |err| app.recordError(@errorName(err)) catch {};
                                    decided = true;
                                },
                                'a' => {
                                    app.decideApproval(true, true) catch |err| app.recordError(@errorName(err)) catch {};
                                    decided = true;
                                },
                                'n' => {
                                    app.decideApproval(false, false) catch |err| app.recordError(@errorName(err)) catch {};
                                    decided = true;
                                },
                                else => {},
                            },
                            .escape => {
                                app.decideApproval(false, false) catch |err| app.recordError(@errorName(err)) catch {};
                                decided = true;
                            },
                            else => {},
                        }
                        if (decided) return .none;
                    } else if (key.key == .escape) {
                        app.state.composer.clear();
                        return .none;
                    }
                }
                // Session picker navigation and filtering.
                if (app.state.mode == .session_picker) {
                    switch (key.key) {
                        .up => moveSessionSelection(app, -1),
                        .down => moveSessionSelection(app, 1),
                        .backspace => updateSessionFilter(app, .backspace, null),
                        .delete => updateSessionFilter(app, .delete, null),
                        .char => |c| updateSessionFilter(app, .char, c),
                        .space => updateSessionFilter(app, .char, ' '),
                        .left => _ = app.state.session_filter.moveCursorPrev(),
                        .right => _ = app.state.session_filter.moveCursorNext(),
                        .home => app.state.session_filter.moveCursorHome(),
                        .end => app.state.session_filter.moveCursorEnd(),
                        .enter => {
                            app.resumeSelectedSession() catch |err| app.recordError(@errorName(err)) catch {};
                        },
                        .escape => app.state.mode = .normal,
                        else => {},
                    }
                    return .none;
                }
                // Pasted-input prompt during an OAuth login flow.
                if (app.state.mode == .login_input) {
                    switch (key.key) {
                        .enter => {
                            const text = app.state.composer.text();
                            app.submitLoginInput(text);
                            app.state.composer.clear();
                        },
                        .escape => app.cancelLogin(),
                        .backspace => _ = app.state.composer.deleteBeforeCursor(),
                        .char => |c| appendChar(app, c) catch {},
                        .paste => |text| app.state.composer.insertSlice(app.allocator, text) catch {},
                        .space => app.state.composer.insertSlice(app.allocator, " ") catch {},
                        .left => _ = app.state.composer.moveCursorPrev(),
                        .right => _ = app.state.composer.moveCursorNext(),
                        .home => app.state.composer.moveCursorHome(),
                        .end => app.state.composer.moveCursorEnd(),
                        else => {},
                    }
                    return .none;
                }
                // Single-column selector menu navigation.
                if (isMenuMode(app.state.mode)) {
                    switch (key.key) {
                        .up => app.moveMenuSelection(-1),
                        .down => app.moveMenuSelection(1),
                        .char => |c| switch (c) {
                            'k' => app.moveMenuSelection(-1),
                            'j' => app.moveMenuSelection(1),
                            else => {},
                        },
                        .enter => {
                            if (app.state.mode == .model_picker) {
                                app.applySelectedModel() catch |err| app.recordError(@errorName(err)) catch {};
                            } else if (app.state.mode == .login_picker) {
                                app.applySelectedLogin() catch |err| app.recordError(@errorName(err)) catch {};
                            } else if (app.state.mode == .permission_picker) {
                                app.applySelectedPermission() catch |err| app.recordError(@errorName(err)) catch {};
                            } else if (app.state.mode == .view_picker) {
                                app.applySelectedView() catch |err| app.recordError(@errorName(err)) catch {};
                            } else if (app.state.mode == .thinking_picker) {
                                app.applySelectedThinking() catch |err| app.recordError(@errorName(err)) catch {};
                            } else if (app.state.mode == .export_picker) {
                                app.applySelectedExport() catch |err| app.recordError(@errorName(err)) catch {};
                            }
                        },
                        .escape => app.state.mode = .normal,
                        else => {},
                    }
                    return .none;
                }
                if (app.state.mode == .preview) {
                    switch (key.key) {
                        .up => app.state.preview.scroll += 1,
                        .down => app.state.preview.scroll -|= 1,
                        .page_up => app.state.preview.scroll += 10,
                        .page_down => app.state.preview.scroll -|= 10,
                        .home => app.state.preview.scroll = 0,
                        .escape => app.state.mode = .normal,
                        else => {},
                    }
                    return .none;
                }
                switch (key.key) {
                    .enter => {
                        if (key.modifiers.shift) {
                            app.state.composer.insertSlice(app.allocator, "\n") catch |err| app.recordError(@errorName(err)) catch {};
                            return .none;
                        }
                        app.drainEvents() catch |err| {
                            app.state.status.setError(app.allocator, @errorName(err)) catch {};
                            app.state.appendTranscript(.@"error", @errorName(err)) catch {};
                        };
                        const text = app.state.composer.text();
                        if (app.state.mode == .approval) {
                            // Only /abort is allowed while a tool approval is pending.
                            const command = tui_commands.parse(text) catch return .none;
                            if (command.kind != .abort) return .none;
                        }
                        var consumed = true;
                        if (app.state.mode == .approval) {
                            app.submit(text) catch |err| {
                                if (err == error.QuitRequested) return .quit;
                                if (err == error.QueueFull) consumed = false;
                                app.state.status.setError(app.allocator, @errorName(err)) catch {};
                                if (err != error.QueueFull) app.state.appendTranscript(.@"error", @errorName(err)) catch {};
                            };
                        } else if (app.state.status.streaming) {
                            if (key.modifiers.alt) {
                                app.queueFollowUp(text) catch |err| {
                                    if (err == error.QuitRequested) return .quit;
                                    if (err == error.QueueFull) consumed = false;
                                    app.recordError(@errorName(err)) catch {};
                                };
                            } else if (app.steeringAvailable()) {
                                app.steer(text) catch |err| {
                                    if (err == error.QuitRequested) return .quit;
                                    if (err == error.QueueFull) consumed = false;
                                    app.recordError(@errorName(err)) catch {};
                                };
                            } else {
                                // Remote backend does not support steering mid-stream; keep the
                                // draft in the composer and let the composer hint explain why.
                                // Still allow slash commands such as /quit and /abort to run.
                                const trimmed = std.mem.trim(u8, text, " \t\r\n");
                                if (std.mem.startsWith(u8, trimmed, "/")) {
                                    app.submit(text) catch |err| {
                                        if (err == error.QuitRequested) return .quit;
                                        if (err == error.QueueFull) consumed = false;
                                        app.state.status.setError(app.allocator, @errorName(err)) catch {};
                                        if (err != error.QueueFull) app.state.appendTranscript(.@"error", @errorName(err)) catch {};
                                    };
                                } else {
                                    consumed = false;
                                }
                            }
                        } else {
                            app.submit(text) catch |err| {
                                if (err == error.QuitRequested) return .quit;
                                if (err == error.QueueFull) consumed = false;
                                app.state.status.setError(app.allocator, @errorName(err)) catch {};
                                if (err != error.QueueFull) app.state.appendTranscript(.@"error", @errorName(err)) catch {};
                            };
                        }
                        if (consumed) {
                            // Only record history when the draft was actually consumed (submitted,
                            // steered, queued, or run as a slash command). An ignored remote Enter
                            // keeps the draft in the composer so it must not pollute Up-arrow history.
                            app.state.recordComposerHistory(text) catch |err| app.recordError(@errorName(err)) catch {};
                            app.state.composer.clear();
                            app.drainEvents() catch |err| {
                                app.state.status.setError(app.allocator, @errorName(err)) catch {};
                                app.state.appendTranscript(.@"error", @errorName(err)) catch {};
                            };
                        }
                    },
                    .backspace => _ = app.state.composer.deleteBeforeCursor(),
                    .char => |c| appendChar(app, c) catch {},
                    .paste => |text| app.state.composer.insertSlice(app.allocator, text) catch {},
                    .space => app.state.composer.insertSlice(app.allocator, " ") catch {},
                    .left => _ = app.state.composer.moveCursorPrev(),
                    .right => _ = app.state.composer.moveCursorNext(),
                    .home => app.state.composer.moveCursorHome(),
                    .end => app.state.composer.moveCursorEnd(),
                    .up => {
                        _ = app.state.composerHistoryPrev() catch false;
                    },
                    .down => {
                        _ = app.state.composerHistoryNext() catch false;
                    },
                    // PageUp/PageDown scroll by 5 lines for faster navigation.
                    .page_up => app.state.transcript_scroll += 5,
                    .page_down => app.state.transcript_scroll -|= 5,
                    .escape => app.state.mode = .normal,
                    else => {},
                }
            },
            .mouse => |mouse| handleMouse(app, mouse),
            .tick => {
                app.state.anim_tick +%= 1;
                app.drainEvents() catch {};
                app.pollLogin() catch {};
                flushInlineHistory(app, ctx) catch |err| app.recordError(@errorName(err)) catch {};
            },
            .quit => return .quit,
        }
        // A command (e.g. `/copy`) may have staged clipboard text; flush it now
        // that a mutable Context is in hand.
        flushInlineHistory(app, ctx) catch |err| app.recordError(@errorName(err)) catch {};
        app.flushClipboard(ctx);
        return .none;
    }

    pub fn view(self: *TuiModel, ctx: *const zz.Context) []const u8 {
        const app = &(self.app orelse return "Makai TUI failed to initialize");
        const width: usize = @max(ctx.width, 20);
        const height: usize = @max(ctx.height, 8);
        app.last_view_height = height;
        // A single one-line status bar sits below the composer; the transcript
        // fills the rest of the screen. The tool panel and verbose telemetry
        // panel were removed — their context/token data already lives in the
        // status line, and tool details are available via `/tools`.
        const status = status_bar_view.render(ctx.allocator, &app.state, .{ .width = width }) catch "";
        const composer = composer_view.render(ctx.allocator, &app.state, .{
            .width = width,
            .steering_available = app.steeringAvailable(),
        }) catch "";
        const queued = renderQueuedShelf(ctx.allocator, &app.state, width) catch "";
        const extra = switch (app.state.mode) {
            .approval => approval_view.render(ctx.allocator, &app.state, .{ .width = width }) catch "",
            .preview => preview_view.render(ctx.allocator, &app.state, .{ .width = width, .height = height / 2 }) catch "",
            .session_picker => session_picker_view.render(ctx.allocator, &app.state, .{ .width = width, .height = sessionPickerHeight(app), .offset = app.state.session_scroll }) catch "",
            .model_picker => blk: {
                const models = if (app.runtime) |runtime| runtime.availableModels() else &[_]ai_types.Model{};
                const items = ctx.allocator.alloc(menu_picker_view.Item, models.len) catch break :blk "";
                for (models, 0..) |model, i| items[i] = .{ .label = model.id, .detail = model.provider };
                break :blk menu_picker_view.render(ctx.allocator, .{
                    .title = "Select model",
                    .items = items,
                    .selected = app.state.menu_index,
                    .width = width,
                    .height = sessionPickerHeight(app),
                    .offset = app.state.menu_scroll,
                    .empty_message = "  no models available",
                }) catch "";
            },
            .login_picker => blk: {
                var items: [App.login_providers.len]menu_picker_view.Item = undefined;
                for (App.login_providers, 0..) |provider, i| items[i] = .{ .label = provider };
                break :blk menu_picker_view.render(ctx.allocator, .{
                    .title = "Login provider",
                    .items = &items,
                    .selected = app.state.menu_index,
                    .width = width,
                    .height = sessionPickerHeight(app),
                    .offset = app.state.menu_scroll,
                }) catch "";
            },
            .permission_picker => blk: {
                var items: [App.permission_modes.len]menu_picker_view.Item = undefined;
                for (App.permission_modes, 0..) |mode, i| {
                    items[i] = .{ .label = @tagName(mode), .detail = permissionModeDetail(mode) };
                }
                break :blk menu_picker_view.render(ctx.allocator, .{
                    .title = "Tool permissions",
                    .items = &items,
                    .selected = app.state.menu_index,
                    .width = width,
                    .height = sessionPickerHeight(app),
                    .offset = app.state.menu_scroll,
                }) catch "";
            },
            .view_picker => blk: {
                var items: [App.view_modes.len]menu_picker_view.Item = undefined;
                for (App.view_modes, 0..) |mode, i| {
                    items[i] = .{ .label = @tagName(mode), .detail = viewModeDetail(mode) };
                }
                break :blk menu_picker_view.render(ctx.allocator, .{
                    .title = "Transcript view",
                    .items = &items,
                    .selected = app.state.menu_index,
                    .width = width,
                    .height = sessionPickerHeight(app),
                    .offset = app.state.menu_scroll,
                }) catch "";
            },
            .thinking_picker => blk: {
                var items: [App.thinking_levels.len]menu_picker_view.Item = undefined;
                for (App.thinking_levels, 0..) |level, i| {
                    items[i] = .{ .label = @tagName(level), .detail = thinkingLevelDetail(level) };
                }
                break :blk menu_picker_view.render(ctx.allocator, .{
                    .title = "Thinking level",
                    .items = &items,
                    .selected = app.state.menu_index,
                    .width = width,
                    .height = sessionPickerHeight(app),
                    .offset = app.state.menu_scroll,
                }) catch "";
            },
            .export_picker => blk: {
                var items: [App.export_methods.len]menu_picker_view.Item = undefined;
                for (App.export_methods, 0..) |method, i| {
                    items[i] = .{ .label = exportMethodLabel(method), .detail = exportMethodDetail(method) };
                }
                break :blk menu_picker_view.render(ctx.allocator, .{
                    .title = "Export conversation",
                    .subtitle = "Select export method",
                    .footer = "Esc to cancel",
                    .items = &items,
                    .selected = app.state.menu_index,
                    .width = width,
                    .height = sessionPickerHeight(app),
                    .offset = app.state.menu_scroll,
                }) catch "";
            },
            .login_input => "",
            .normal => "",
        };
        if (ctx._terminal != null) {
            const fixed = countLines(status) + countLines(composer) + countLines(queued) + @max(countLines(extra), 1);
            const active_height = height -| fixed;
            const active = renderInlineActiveTranscript(ctx.allocator, &app.state, width, active_height) catch "";
            const live_frame = if (active.len > 0 and queued.len > 0)
                tui_render.joinVertical(ctx.allocator, &.{ active, extra, queued, composer, status }) catch ""
            else if (active.len > 0)
                tui_render.joinVertical(ctx.allocator, &.{ active, extra, composer, status }) catch ""
            else if (queued.len > 0)
                tui_render.joinVertical(ctx.allocator, &.{ extra, queued, composer, status }) catch ""
            else
                tui_render.joinVertical(ctx.allocator, &.{ extra, composer, status }) catch "";
            app.last_inline_view_lines = @max(countLines(live_frame), 1);
            return tui_render.withSynchronizedOutput(ctx.allocator, live_frame) catch live_frame;
        }

        const fixed = countLines(status) + countLines(composer) + countLines(queued) + @max(countLines(extra), 1);
        const transcript_height = if (height > fixed) height - fixed else 3;
        const transcript = transcript_view.render(ctx.allocator, &app.state, .{ .width = width, .height = transcript_height }) catch "";
        const frame = if (queued.len > 0)
            tui_render.joinVertical(ctx.allocator, &.{ transcript, extra, queued, composer, status }) catch ""
        else
            tui_render.joinVertical(ctx.allocator, &.{ transcript, extra, composer, status }) catch "";
        return tui_render.withSynchronizedOutput(ctx.allocator, frame) catch frame;
    }

    fn renderInlineActiveTranscript(allocator: std.mem.Allocator, state: *const tui_state.AppState, width: usize, max_lines: usize) ![]const u8 {
        if (max_lines == 0) return allocator.dupe(u8, "");

        var indices: [3]usize = undefined;
        var len: usize = 0;
        addActiveTranscriptIndex(&indices, &len, state.active_user_entry, state.transcript.items.len);
        addActiveTranscriptIndex(&indices, &len, state.active_assistant_entry, state.transcript.items.len);
        addActiveTranscriptIndex(&indices, &len, state.active_tool_result_entry, state.transcript.items.len);
        if (len == 0) return allocator.dupe(u8, "");
        sortSmallIndices(indices[0..len]);

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const writer = &out.writer;
        for (indices[0..len], 0..) |idx, i| {
            if (i > 0) try writer.writeAll("\n\n");
            const rendered = try transcript_view.renderTranscriptEntry(allocator, &state.transcript.items[idx], width, state.timestamp_display);
            defer allocator.free(rendered);
            try writer.writeAll(rendered);
        }
        const rendered_active = try out.toOwnedSlice();
        defer allocator.free(rendered_active);
        return tailLines(allocator, rendered_active, max_lines);
    }

    fn addActiveTranscriptIndex(indices: *[3]usize, len: *usize, maybe_index: ?usize, transcript_len: usize) void {
        const idx = maybe_index orelse return;
        if (idx >= transcript_len) return;
        for (indices[0..len.*]) |existing| {
            if (existing == idx) return;
        }
        indices[len.*] = idx;
        len.* += 1;
    }

    fn sortSmallIndices(indices: []usize) void {
        var i: usize = 1;
        while (i < indices.len) : (i += 1) {
            const value = indices[i];
            var j = i;
            while (j > 0 and indices[j - 1] > value) : (j -= 1) {
                indices[j] = indices[j - 1];
            }
            indices[j] = value;
        }
    }

    fn tailLines(allocator: std.mem.Allocator, text: []const u8, max_lines: usize) ![]const u8 {
        if (max_lines == 0 or text.len == 0) return allocator.dupe(u8, "");
        var lines: usize = 1;
        for (text) |byte| {
            if (byte == '\n') lines += 1;
        }
        if (lines <= max_lines) return allocator.dupe(u8, text);

        var line_start = text.len;
        var remaining = max_lines;
        while (line_start > 0 and remaining > 0) {
            line_start -= 1;
            if (text[line_start] == '\n') remaining -= 1;
        }
        const start = if (remaining == 0) line_start + 1 else 0;
        return allocator.dupe(u8, text[start..]);
    }

    fn renderQueuedShelf(allocator: std.mem.Allocator, state: *const tui_state.AppState, width: usize) ![]const u8 {
        if (state.queued_previews.items.len == 0) return allocator.dupe(u8, "");

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const writer = &out.writer;
        const max_width = width -| 4;
        for (state.queued_previews.items, 0..) |preview, i| {
            if (i > 0) try writer.writeByte('\n');
            const label = switch (preview.kind) {
                .steering => "steering",
                .follow_up => "queued follow-up",
            };
            const raw_prefix = try std.fmt.allocPrint(allocator, "  {s} {s}: ", .{ tui_theme.glyph.prompt, label });
            defer allocator.free(raw_prefix);
            const prefix_style = switch (preview.kind) {
                .steering => tui_theme.runningText(),
                .follow_up => tui_theme.warningText(),
            };
            const prefix = try prefix_style.render(allocator, raw_prefix);
            defer allocator.free(prefix);
            const body_width = max_width -| tui_text.visibleWidth(raw_prefix);
            const body = try tui_text.truncateToWidth(allocator, preview.text, body_width);
            defer allocator.free(body);
            const styled_body = try tui_theme.bodyStyle(.user).render(allocator, body);
            defer allocator.free(styled_body);
            try writer.writeAll(prefix);
            try writer.writeAll(styled_body);
        }
        return out.toOwnedSlice();
    }

    fn appendChar(app: *App, c: u21) !void {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(c, &buf);
        try app.state.composer.insertSlice(app.allocator, buf[0..len]);
    }

    fn flushInlineHistory(app: *App, ctx: *zz.Context) !void {
        if (@import("builtin").is_test) {
            const ok: anyerror!void = {};
            return ok;
        }
        if (ctx._terminal == null) return;
        if (app.inline_history_flushed >= app.state.transcript.items.len) return;

        const stop = inlineFlushStop(app);
        if (stop <= app.inline_history_flushed) return;

        var out: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer out.deinit();
        const writer = &out.writer;
        for (app.state.transcript.items[app.inline_history_flushed..stop], 0..) |*entry, rel_i| {
            if (rel_i > 0) try writer.writeAll("\n\n");
            const rendered = try transcript_view.renderTranscriptEntry(ctx.allocator, entry, @max(ctx.width, 20), app.state.timestamp_display);
            defer ctx.allocator.free(rendered);
            try writer.writeAll(rendered);
        }
        const rendered_history = out.written();
        if (rendered_history.len > 0) {
            try writeInlineHistory(ctx, app.last_inline_view_lines, rendered_history);
            app.inline_history_flushed = stop;
            app.state.transcript_scroll = 0;
        }
    }

    fn inlineFlushStop(app: *const App) usize {
        var stop = app.state.transcript.items.len;
        if (app.state.active_user_entry) |idx| stop = @min(stop, idx);
        if (app.state.active_assistant_entry) |idx| stop = @min(stop, idx);
        if (app.state.active_tool_result_entry) |idx| stop = @min(stop, idx);
        return stop;
    }

    fn writeInlineHistory(ctx: *zz.Context, reserved_lines: usize, text: []const u8) !void {
        const term = ctx._terminal orelse return;
        const reserved: u16 = @intCast(@min(@max(reserved_lines, 1), @as(usize, ctx.height -| 1)));
        const history_bottom: u16 = if (ctx.height > reserved) ctx.height - reserved else 1;
        const writer = term.writer();

        try writer.writeAll(zz.ansi.sync_start);
        try zz.ansi.setScrollRegion(writer, 1, history_bottom);
        try zz.ansi.cursorTo(writer, history_bottom, 1);

        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try writer.writeAll("\r\n");
            first = false;
            try writer.writeAll(line);
            try writer.writeAll(zz.ansi.line_clear_right);
        }
        try writer.writeAll("\r\n");

        try zz.ansi.resetScrollRegion(writer);
        try zz.ansi.cursorTo(writer, history_bottom + 1, 1);
        try writer.writeAll(zz.ansi.sync_end);
        try term.flush();
    }

    const SessionFilterEdit = enum { backspace, delete, char };

    fn updateSessionFilter(app: *App, edit: SessionFilterEdit, c: ?u21) void {
        const selected_raw_index = app.state.sessionRawIndexAtFilteredIndex(app.state.session_index);
        switch (edit) {
            .backspace => _ = app.state.session_filter.deleteBeforeCursor(),
            .delete => _ = app.state.session_filter.deleteAfterCursor(),
            .char => {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c.?, &buf) catch return;
                app.state.session_filter.insertSlice(app.allocator, buf[0..len]) catch |err| {
                    app.recordError(@errorName(err)) catch {};
                    return;
                };
            },
        }
        if (selected_raw_index) |raw_index| {
            if (app.state.sessionFilteredIndexForRawIndex(raw_index)) |filtered_index| {
                app.state.session_index = filtered_index;
            } else {
                app.state.clampSessionSelectionToFilter();
            }
        } else {
            app.state.clampSessionSelectionToFilter();
        }
        ensureSessionSelectionVisible(app);
    }

    fn handleMouse(app: *App, mouse: zz.MouseEvent) void {
        if (mouse.event_type != .press) return;
        switch (mouse.button) {
            .wheel_up => app.state.transcript_scroll += 3,
            .wheel_down => app.state.transcript_scroll -|= 3,
            else => {},
        }
    }

    fn isMenuMode(mode: tui_state.AppMode) bool {
        return switch (mode) {
            .model_picker, .login_picker, .permission_picker, .view_picker, .thinking_picker, .export_picker => true,
            else => false,
        };
    }

    fn permissionModeDetail(mode: tui_runtime.PermissionMode) []const u8 {
        return switch (mode) {
            .bypass => "run tools without prompts",
            .ask => "ask before tool execution",
        };
    }

    fn viewModeDetail(mode: tui_state.TranscriptVisibilityMode) []const u8 {
        return switch (mode) {
            .everything => "full protocol log",
            .verbose => "more internals",
            .balanced => "balanced details",
            .chat => "mostly messages",
        };
    }

    fn thinkingLevelDetail(level: ai_types.ThinkingLevel) []const u8 {
        return switch (level) {
            .off => "disabled",
            .minimal, .low => "light reasoning",
            .medium => "balanced reasoning",
            .high => "deeper reasoning",
            .xhigh => "maximum reasoning",
        };
    }

    fn exportMethodLabel(method: App.ExportMethod) []const u8 {
        return switch (method) {
            .clipboard => "Copy to clipboard",
            .file => "Save to file",
        };
    }

    fn exportMethodDetail(method: App.ExportMethod) []const u8 {
        return switch (method) {
            .clipboard => "Copy the conversation to your system clipboard",
            .file => "Save the conversation to a file in the current directory",
        };
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
        const n = app.state.filteredSessionCount();
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
        app.state.clampSessionSelectionToFilter();
        const height = sessionPickerHeight(app);
        if (app.state.session_index < app.state.session_scroll) {
            app.state.session_scroll = app.state.session_index;
        } else if (height > 0 and app.state.session_index >= app.state.session_scroll + height) {
            app.state.session_scroll = app.state.session_index + 1 - height;
        }
    }

    fn visibleSessionCount(app: *const App) usize {
        return @min(app.state.filteredSessionCount() -| app.state.session_scroll, sessionPickerHeight(app));
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

/// Build the default export filename, e.g. "transcript-20260615-120000.md".
fn defaultExportPath(allocator: std.mem.Allocator) ![]u8 {
    const millis = compat.time.nowMillis();
    const secs: i64 = @divFloor(millis, 1000);
    const epoch = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(@max(secs, 0))) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();
    return std.fmt.allocPrint(
        allocator,
        "transcript-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.md",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
        },
    );
}

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
    production.initBridge();

    var program = zz.Program(TuiModel).initWithOptions(allocator, io, &environ_map, tuiProgramOptions());
    program.model = .{ .options = production.options() };
    defer program.deinit();
    try program.run();
}

fn tuiProgramOptions() zz.Options {
    return .{ .kitty_keyboard = true, .mouse = false, .alternate_scroll = false, .alt_screen = false, .inline_bottom_viewport = true, .cursor = true };
}

fn editorReturnCommand() zz.Cmd(TuiModel.Msg) {
    if (tuiProgramOptions().alt_screen) {
        return .{ .sequence = &.{
            .enter_alt_screen,
            .hide_cursor,
        } };
    }
    return .none;
}

pub fn tuiProgramOptionsForTest() zz.Options {
    if (!@import("builtin").is_test) @compileError("test-only helper");
    return tuiProgramOptions();
}

test "App init seeds registered tools from runtime" {
    var production = try ProductionRuntime.init(std.testing.allocator);
    defer production.deinit();
    production.initBridge();
    var app = try App.init(std.testing.allocator, production.options());
    defer app.deinit();

    try std.testing.expect(app.state.registered_tools.items.len >= 12);
    try std.testing.expectEqual(app.runtime.?.availableTools().len, app.state.registered_tools.items.len);
    try std.testing.expectEqualStrings("shell_execute", app.state.registered_tools.items[0].name);
    try std.testing.expect(app.runtime.?.permission_engine.?.workspace_root.len > 0);
}

test "App refreshes runtime models after login" {
    const extra_model = ai_types.Model{
        .id = "temporary-extra-model",
        .name = "Temporary Extra",
        .api = "test-api",
        .provider = "test",
        .base_url = "https://example.invalid",
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 256,
    };
    const runtime = try std.testing.allocator.create(tui_runtime.TuiRuntime);
    errdefer std.testing.allocator.destroy(runtime);
    runtime.* = try tui_runtime.TuiRuntime.init(std.testing.allocator, .{ .models = &[_]ai_types.Model{ extra_model, defaultModel() }, .initial_model_id = "temporary-extra-model" });
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    app.runtime = runtime;

    try std.testing.expectEqual(@as(usize, 2), runtime.availableModels().len);
    try app.refreshModelsAfterLogin();
    try std.testing.expectEqual(@as(usize, 1), runtime.availableModels().len);
    try std.testing.expectEqualStrings(defaultModel().id, runtime.currentModel().?.id);
}

test "TUI program enables enhanced keyboard protocol" {
    try std.testing.expect(tuiProgramOptions().kitty_keyboard);
}

test "TUI program preserves native text selection" {
    try std.testing.expect(!tuiProgramOptions().mouse);
    try std.testing.expect(!tuiProgramOptions().alternate_scroll);
    try std.testing.expect(!tuiProgramOptions().alt_screen);
    try std.testing.expect(tuiProgramOptions().inline_bottom_viewport);
}

test "editor return does not enter alt screen in inline mode" {
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, editorReturnCommand());
}

test "saved model ref loads from config store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "makai" });
    defer std.testing.allocator.free(base);

    var store = try tui_config.Store.init(std.testing.allocator, base);
    defer store.deinit();
    var cfg = try tui_config.Config.defaults(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    std.testing.allocator.free(cfg.model);
    cfg.model = try std.testing.allocator.dupe(u8, "persisted-model");
    std.testing.allocator.free(cfg.provider);
    cfg.provider = try std.testing.allocator.dupe(u8, "persisted-provider");
    std.testing.allocator.free(cfg.api);
    cfg.api = try std.testing.allocator.dupe(u8, "persisted-api");
    try store.save(cfg);

    var model_ref = (try loadSavedModelRefFromStore(std.testing.allocator, store)).?;
    defer model_ref.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("persisted-model", model_ref.id);
    try std.testing.expectEqualStrings("persisted-provider", model_ref.provider);
    try std.testing.expectEqualStrings("persisted-api", model_ref.api);
}

test "App saveEvent keeps debug-visible event types" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "sessions" });
    defer std.testing.allocator.free(base);

    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    app.store = try session_store.Store.init(std.testing.allocator, base);
    app.session_id = try std.testing.allocator.dupe(u8, "save-debug-events");
    app.session_created_at = 1;

    var thinking = tui_runtime.TuiEvent{ .thinking_delta = .{ .content_index = 0, .delta = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "plan")) } };
    defer thinking.deinit(std.testing.allocator);
    app.saveEvent(thinking);

    var approval = tui_runtime.TuiEvent{ .tool_approval_requested = .{
        .tool_call_id = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "call-1")),
        .tool_name = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "shell_execute")),
        .args_json = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "{\"command\":\"pwd\"}")),
    } };
    defer approval.deinit(std.testing.allocator);
    app.saveEvent(approval);

    var update = tui_runtime.TuiEvent{ .tool_execution_update = .{
        .tool_call_id = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "call-1")),
        .tool_name = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "shell_execute")),
        .args_json = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "{\"command\":\"pwd\"}")),
        .partial_result_json = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "{\"stdout\":\"/tmp\"}")),
    } };
    defer update.deinit(std.testing.allocator);
    app.saveEvent(update);

    var provider = tui_runtime.TuiEvent{ .provider_event = .{ .event_json = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "{\"type\":\"done\"}")) } };
    defer provider.deinit(std.testing.allocator);
    app.saveEvent(provider);

    var err = tui_runtime.TuiEvent{ .@"error" = .{ .message = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "boom")) } };
    defer err.deinit(std.testing.allocator);
    app.saveEvent(err);

    var loaded = try app.store.?.load("save-debug-events");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), loaded.events.items.len);
    try std.testing.expect(loaded.events.items[0] == .thinking_delta);
    try std.testing.expect(loaded.events.items[1] == .tool_approval_requested);
    try std.testing.expect(loaded.events.items[2] == .tool_execution_update);
    try std.testing.expect(loaded.events.items[3] == .provider_event);
    try std.testing.expectEqualStrings("{\"type\":\"done\"}", loaded.events.items[3].provider_event.event_json.slice());
    try std.testing.expect(loaded.events.items[4] == .@"error");
}

test "App approval decisions map to requested choices" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    try app.state.approval.setPending(std.testing.allocator, "call-approval", "edit_file", "edit_file", "{\"path\":\"README.md\"}");
    app.state.mode = .approval;

    try app.decideApproval(true, false);
    try std.testing.expectEqual(tui_state.AppMode.normal, app.state.mode);
    try std.testing.expectEqual(tui_state.ApprovalStatus.approved, app.state.approval.status);
    try std.testing.expect(!app.state.approval.always);

    try app.state.approval.setPending(std.testing.allocator, "call-approval", "edit_file", "edit_file", "{\"path\":\"README.md\"}");
    app.state.mode = .approval;
    try app.decideApproval(true, true);
    try std.testing.expectEqual(tui_state.ApprovalStatus.approved, app.state.approval.status);
    try std.testing.expect(app.state.approval.always);

    try app.state.approval.setPending(std.testing.allocator, "call-approval", "edit_file", "edit_file", "{\"path\":\"README.md\"}");
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

test "App submit starts direct OpenAI Codex login command" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();

    try app.submit("/login openai-codex");

    try std.testing.expect(app.login != null);
    try std.testing.expectEqualStrings("openai-codex", app.login.?.provider_id);
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "starting login for openai-codex") != null);
}

test "App submit starts direct Kimi API key login command" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();

    try app.submit("/login kimi");

    try std.testing.expect(app.login != null);
    try std.testing.expectEqualStrings("kimi", app.login.?.provider_id);
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "starting login for kimi") != null);
}

test "App cancel login clears secret composer draft" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();

    app.state.mode = .login_input;
    app.state.login_input_secret = true;
    try app.state.composer.insertSlice(std.testing.allocator, "moonshot-secret-key");

    app.cancelLogin();

    try std.testing.expectEqual(tui_state.AppMode.normal, app.state.mode);
    try std.testing.expect(!app.state.login_input_secret);
    try std.testing.expectEqual(@as(usize, 0), app.state.composer.text().len);
}

test "App saves Kimi login credentials as api key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "home" });
    defer std.testing.allocator.free(home);
    try compat.fs.createDir(compat.fs.getCwd(), home);
    const previous_home = std.process.Environ.getAlloc(std.testing.environ, std.testing.allocator, "HOME") catch null;
    defer {
        if (previous_home) |value| {
            const value_z = std.testing.allocator.dupeZ(u8, value) catch null;
            if (value_z) |home_z| {
                defer std.testing.allocator.free(home_z);
                _ = setenv("HOME", home_z.ptr, 1);
            }
            std.testing.allocator.free(value);
        } else {
            _ = unsetenv("HOME");
        }
    }
    const home_z = try std.testing.allocator.dupeZ(u8, home);
    defer std.testing.allocator.free(home_z);
    _ = setenv("HOME", home_z.ptr, 1);

    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    const creds = oauth_storage.Credentials{
        .refresh = try std.testing.allocator.dupe(u8, ""),
        .access = try std.testing.allocator.dupe(u8, "moonshot-test-key"),
        .expires = std.math.maxInt(i64),
    };
    defer creds.deinit(std.testing.allocator);

    try app.saveLoginCredentials("kimi", creds);

    var storage = try oauth_storage.AuthStorage.loadFromFile(std.testing.allocator);
    defer storage.deinit();
    const auth = storage.providers.get("kimi") orelse return error.MissingKimiAuth;
    switch (auth) {
        .api_key => |key| try std.testing.expectEqualStrings("moonshot-test-key", key),
        .oauth => return error.ExpectedApiKeyAuth,
    }
}

test "multi-line /help output renders all lines into transcript view" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    try app.submit("/help");

    const rendered = try transcript_view.render(std.testing.allocator, &app.state, .{ .width = 100, .height = 30 });
    defer std.testing.allocator.free(rendered);

    // Every command name must appear in the rendered transcript — the previous
    // bug (inline_style theme stripped newlines) collapsed the whole help
    // listing to a single truncated line.
    const expect = [_][]const u8{
        "/help",  "/model",       "/provider", "/status",
        "/tools", "/permissions", "/view",     "/compact",
        "/clear", "/diff",        "/quit",
    };
    for (expect) |needle| {
        if (std.mem.indexOf(u8, rendered, needle) == null) {
            std.debug.print("missing {s} in rendered output:\n{s}\n", .{ needle, rendered });
            return error.TestExpectedHelpLine;
        }
    }
}

test "App submit routes unknown command to error transcript" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    try app.submit("/unknown");
    try std.testing.expectEqual(@as(usize, 1), app.state.transcript.items.len);
    try std.testing.expectEqual(tui_state.TranscriptKind.@"error", app.state.transcript.items[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "unknown command") != null);
}

test "App submit abort when idle reports idle transcript" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    try app.submit("/abort");
    try std.testing.expectEqual(@as(usize, 1), app.state.transcript.items.len);
    try std.testing.expectEqual(tui_state.TranscriptKind.system, app.state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("Nothing to abort — agent is idle.", app.state.transcript.items[0].text.items);
}

test "App submit abort when streaming cancels and reports transcript" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    app.session = mock.session();
    app.state.status.streaming = true;

    try app.submit("/abort");

    try std.testing.expectEqual(@as(usize, 1), mock.cancel_count);
    try std.testing.expect(!app.state.status.streaming);
    try std.testing.expectEqual(@as(usize, 1), app.state.transcript.items.len);
    try std.testing.expectEqual(tui_state.TranscriptKind.system, app.state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("Turn aborted.", app.state.transcript.items[0].text.items);
}

test "App submit abort when streaming via runtime-only cancels and reports transcript" {
    var runtime = try initRemoteRuntimeForTest(std.testing.allocator);
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    app.runtime = runtime;
    runtime = undefined;
    app.runtime.?.stream_active = true;

    try app.submit("/abort");

    try std.testing.expect(app.runtime.?.cancelled.load(.acquire));
    try std.testing.expect(!app.state.status.streaming);
    try std.testing.expect(app.state.stream_aborted);
    try std.testing.expectEqual(@as(usize, 1), app.state.transcript.items.len);
    try std.testing.expectEqual(tui_state.TranscriptKind.system, app.state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("Turn aborted.", app.state.transcript.items[0].text.items);
}

test "App submit does not clear stream_aborted for slash commands" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    app.state.stream_aborted = true;

    try app.submit("/help");

    try std.testing.expect(app.state.stream_aborted);
    try std.testing.expect(app.state.transcript.items.len > 0);
}

test "App submit abort does not permanently shut down approval waiter" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    const waiter = try app.allocator.create(ApprovalWaiter);
    waiter.* = .{ .allocator = app.allocator };
    app.approval_waiter = waiter;
    waiter.tool_call_id = try app.allocator.dupe(u8, "call-1");

    try app.submit("/abort");

    try std.testing.expect(!waiter.shutting_down);
    try std.testing.expect(waiter.decision == .reject);

    // Verify the waiter can still accept a future approval decision.
    waiter.decision = null;
    try app.state.approval.setPending(app.allocator, "call-1", "edit_file", "edit_file", "{}");
    try app.decideApproval(true, false);
    try std.testing.expect(waiter.decision == .approve);
}

test "App welcome uses session count" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    app.session = mock.session();
    try app.state.status.setModel(std.testing.allocator, "model-a", "provider-a");
    app.working_dir = try std.testing.allocator.dupe(u8, "/tmp/work");

    try app.appendWelcome();
    try std.testing.expectEqual(tui_state.TranscriptKind.system, app.state.transcript.items[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "tips:") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "Alt+Enter") != null);

    app.state.clearTranscript();
    try app.state.addSession("s1", "saved");
    try app.appendWelcome();
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "tips:") == null);
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "/sessions") != null);
}

test "App welcome shows follow-up tips but hides steering tips for remote runtime" {
    var runtime = try initRemoteRuntimeForTest(std.testing.allocator);
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    app.runtime = runtime;
    runtime = undefined;
    try app.state.status.setModel(std.testing.allocator, "model-a", "provider-a");
    app.working_dir = try std.testing.allocator.dupe(u8, "/tmp/work");

    try app.appendWelcome();
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "tips:") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "Alt+Enter") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "Enter while streaming") == null);
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "Enter submit") != null);
}

const MockAppSession = struct {
    steer_count: usize = 0,
    queued_follow_up_count: usize = 0,
    submit_count: usize = 0,
    resume_count: usize = 0,
    cancel_count: usize = 0,
    clear_count: usize = 0,
    queued_counts: tui_runtime.QueuedCounts = .{},
    steer_enabled: bool = true,
    events: tui_runtime.TuiEventStream = undefined,
    events_initialized: bool = false,

    fn session(self: *MockAppSession) tui_runtime.TuiSession {
        return .{
            .ctx = self,
            .ops = .{
                .start = start,
                .resume_session = resumeSession,
                .cancel = cancel,
                .submit_turn = submitTurn,
                .steer = steer,
                .queue_follow_up = queueFollowUp,
                .clear_queued_messages = clearQueuedMessages,
                .queued_counts = queuedCounts,
                .can_steer = canSteer,
                .switch_model = switchModel,
                .switch_model_exact = switchModelExact,
                .current_model = currentModel,
                .decide_tool_approval = decideToolApproval,
                .stream_events = streamEvents,
            },
        };
    }

    fn ptr(ctx: ?*anyopaque) *MockAppSession {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn start(ctx: ?*anyopaque) anyerror!void {
        _ = ctx;
    }

    fn resumeSession(ctx: ?*anyopaque) anyerror!void {
        const self = ptr(ctx);
        self.resume_count += 1;
        if (self.queued_counts.steering > 0) {
            self.queued_counts.steering -= 1;
        } else if (self.queued_counts.follow_up > 0) {
            self.queued_counts.follow_up -= 1;
        }
    }

    fn cancel(ctx: ?*anyopaque) void {
        const self = ptr(ctx);
        self.cancel_count += 1;
    }

    fn submitTurn(ctx: ?*anyopaque, text: []const u8) anyerror!void {
        const self = ptr(ctx);
        self.submit_count += 1;
        try std.testing.expectEqualStrings("new turn", text);
    }

    fn steer(ctx: ?*anyopaque, text: []const u8) anyerror!void {
        const self = ptr(ctx);
        self.steer_count += 1;
        if (self.queued_counts.total() == 0) self.queued_counts.steering += 1;
        _ = text;
    }

    fn queueFollowUp(ctx: ?*anyopaque, text: []const u8) anyerror!void {
        const self = ptr(ctx);
        self.queued_follow_up_count += 1;
        if (self.queued_counts.total() == 0) self.queued_counts.follow_up += 1;
        try std.testing.expectEqualStrings("follow later", text);
    }

    fn clearQueuedMessages(ctx: ?*anyopaque) void {
        const self = ptr(ctx);
        self.clear_count += 1;
        self.queued_counts = .{};
    }

    fn queuedCounts(ctx: ?*anyopaque) tui_runtime.QueuedCounts {
        return ptr(ctx).queued_counts;
    }

    fn canSteer(ctx: ?*anyopaque) bool {
        return ptr(ctx).steer_enabled;
    }

    fn switchModel(ctx: ?*anyopaque, model_id: []const u8) anyerror!void {
        _ = ctx;
        _ = model_id;
    }

    fn switchModelExact(ctx: ?*anyopaque, model: ai_types.Model) anyerror!void {
        _ = ctx;
        _ = model;
    }

    fn currentModel(ctx: ?*anyopaque) ?ai_types.Model {
        _ = ctx;
        return null;
    }

    fn decideToolApproval(ctx: ?*anyopaque, tool_call_id: []const u8, decision: tui_runtime.ToolApprovalDecision) anyerror!void {
        _ = ctx;
        _ = tool_call_id;
        _ = decision;
    }

    fn eventStream(self: *MockAppSession) *tui_runtime.TuiEventStream {
        if (!self.events_initialized) {
            self.events = tui_runtime.TuiEventStream.init(std.testing.allocator);
            self.events_initialized = true;
        }
        return &self.events;
    }

    fn streamEvents(ctx: ?*anyopaque) *tui_runtime.TuiEventStream {
        return ptr(ctx).eventStream();
    }

    fn deinit(self: *MockAppSession) void {
        if (self.events_initialized) self.events.deinit();
    }
};

test "App submit quit command requests quit" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    try std.testing.expectError(error.QuitRequested, app.submit("/quit"));
}

test "artifact previews strip terminal control bytes" {
    const preview = try artifactDisplayPreview(std.testing.allocator, "head\x1b[2J\nok\x1b]0;title\x07\n", 0, ".makai/tool-artifacts/test");
    defer std.testing.allocator.free(preview);

    try std.testing.expect(std.mem.indexOfScalar(u8, preview, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, preview, 0x07) == null);
    try std.testing.expect(std.mem.indexOf(u8, preview, "head[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, preview, "ok]0;title") != null);
}

test "App steer and queue follow-up handle fallback empty and session paths" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();

    try app.steer("  steer fallback  ");
    try std.testing.expectEqual(@as(usize, 1), app.state.transcript.items.len);
    try std.testing.expectEqualStrings("steer fallback", app.state.transcript.items[0].text.items);

    try app.queueFollowUp("\tfollow fallback\n");
    try std.testing.expectEqual(@as(usize, 2), app.state.transcript.items.len);
    try std.testing.expectEqualStrings("follow fallback", app.state.transcript.items[1].text.items);

    try app.steer("   ");
    try app.queueFollowUp("\n\t");
    try std.testing.expectEqual(@as(usize, 2), app.state.transcript.items.len);

    app.state.clearTranscript();
    var mock = MockAppSession{ .queued_counts = .{ .steering = 1, .follow_up = 2 } };
    app.session = mock.session();

    try app.steer(" steer me ");
    try std.testing.expectEqual(@as(usize, 1), mock.steer_count);
    try std.testing.expectEqual(@as(usize, 0), app.state.transcript.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.state.queue.steering);
    try std.testing.expectEqual(@as(usize, 2), app.state.queue.follow_up);
    try std.testing.expectEqual(@as(usize, 1), app.state.queued_previews.items.len);
    try std.testing.expectEqual(tui_state.QueuedPreviewKind.steering, app.state.queued_previews.items[0].kind);
    try std.testing.expectEqualStrings("steer me", app.state.queued_previews.items[0].text);

    mock.queued_counts = .{ .steering = 3, .follow_up = 4 };
    try app.queueFollowUp(" follow later ");
    try std.testing.expectEqual(@as(usize, 1), mock.queued_follow_up_count);
    try std.testing.expectEqual(@as(usize, 0), app.state.transcript.items.len);
    try std.testing.expectEqual(@as(usize, 3), app.state.queue.steering);
    try std.testing.expectEqual(@as(usize, 4), app.state.queue.follow_up);
    try std.testing.expectEqual(@as(usize, 2), app.state.queued_previews.items.len);
    try std.testing.expectEqual(tui_state.QueuedPreviewKind.follow_up, app.state.queued_previews.items[1].kind);
    try std.testing.expectEqualStrings("follow later", app.state.queued_previews.items[1].text);
}

test "TuiModel exits quit command while streaming" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    model.app.?.state.status.streaming = true;
    try model.app.?.state.replaceComposerBuffer("/quit");

    const cmd = model.update(.{ .key = .{ .key = .enter } }, undefined);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).quit, cmd);
}

test "TuiModel Shift Enter inserts newline without submitting" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    try model.app.?.state.replaceComposerBuffer("first");

    const cmd = model.update(.{ .key = .{ .key = .enter, .modifiers = .{ .shift = true } } }, undefined);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, cmd);
    try std.testing.expectEqualStrings("first\n", model.app.?.state.composer.text());
    try std.testing.expectEqual(@as(usize, 0), model.app.?.state.transcript.items.len);
}

test "TuiModel Shift Tab cycles thinking level" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();

    try std.testing.expectEqual(ai_types.ThinkingLevel.low, model.app.?.state.thinking_level);
    const cmd = model.update(.{ .key = .{ .key = .tab, .modifiers = .{ .shift = true } } }, undefined);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, cmd);
    try std.testing.expectEqual(ai_types.ThinkingLevel.medium, model.app.?.state.thinking_level);
}

test "TuiModel Ctrl D cycles timestamp display" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();

    try std.testing.expectEqual(tui_state.TimestampDisplay.clock, model.app.?.state.timestamp_display);
    const cmd = model.update(.{ .key = .{ .key = .{ .char = 'd' }, .modifiers = .{ .ctrl = true } } }, undefined);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, cmd);
    try std.testing.expectEqual(tui_state.TimestampDisplay.full, model.app.?.state.timestamp_display);
}

test "setting pickers apply selected values" {
    const runtime_ptr = try std.testing.allocator.create(tui_runtime.TuiRuntime);
    runtime_ptr.* = try tui_runtime.TuiRuntime.init(std.testing.allocator, .{});

    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    app.runtime = runtime_ptr;

    app.openViewPicker();
    try std.testing.expectEqual(tui_state.AppMode.view_picker, app.state.mode);
    app.state.menu_index = 0;
    try app.applySelectedView();
    try std.testing.expectEqual(tui_state.TranscriptVisibilityMode.everything, app.state.transcript_mode);
    try std.testing.expectEqual(tui_state.AppMode.normal, app.state.mode);

    app.openThinkingPicker();
    try std.testing.expectEqual(tui_state.AppMode.thinking_picker, app.state.mode);
    app.state.menu_index = 3;
    try app.applySelectedThinking();
    try std.testing.expectEqual(ai_types.ThinkingLevel.high, app.state.thinking_level);
    try std.testing.expectEqual(ai_types.ThinkingLevel.high, runtime_ptr.thinkingLevel());

    app.openPermissionPicker();
    try std.testing.expectEqual(tui_state.AppMode.permission_picker, app.state.mode);
    app.state.menu_index = 1;
    try app.applySelectedPermission();
    try std.testing.expectEqual(tui_runtime.PermissionMode.ask, app.state.permission_mode);
    try std.testing.expectEqual(tui_runtime.PermissionMode.ask, runtime_ptr.permissionMode());
}

test "TuiModel drains events before routing Enter while streaming" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    model.app.?.session = mock.session();
    model.app.?.state.status.streaming = true;
    try mock.eventStream().push(.{ .turn_end = .{ .stop_reason = .stop } });
    try mock.eventStream().push(.{ .agent_end = .{ .reason = .completed } });
    try model.app.?.state.composer.buffer.appendSlice(std.testing.allocator, "new turn");

    const cmd = model.update(.{ .key = .{ .key = .enter } }, undefined);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, cmd);
    try std.testing.expectEqual(@as(usize, 1), mock.submit_count);
    try std.testing.expectEqual(@as(usize, 0), mock.steer_count);
    try std.testing.expect(!model.app.?.state.status.streaming);
}

test "App drain keeps consecutive user messages distinct" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    app.session = mock.session();

    try mock.eventStream().push(.{ .message_start = .{ .role = .user } });
    try mock.eventStream().push(.{ .message_end = .{
        .role = .user,
        .text = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "run pwd")),
    } });
    try mock.eventStream().push(.{ .message_start = .{ .role = .user } });
    try mock.eventStream().push(.{ .message_end = .{
        .role = .user,
        .text = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "run uname -a")),
    } });

    try app.drainEvents();

    try std.testing.expectEqual(@as(usize, 2), app.state.transcript.items.len);
    try std.testing.expectEqual(tui_state.TranscriptKind.user, app.state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("run pwd", app.state.transcript.items[0].text.items);
    try std.testing.expectEqual(tui_state.TranscriptKind.user, app.state.transcript.items[1].kind);
    try std.testing.expectEqualStrings("run uname -a", app.state.transcript.items[1].text.items);
}

test "App drain auto-resumes remaining steering after completed turn" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{ .queued_counts = .{ .steering = 2 } };
    defer mock.deinit();
    app.session = mock.session();
    try app.state.addQueuedPreview(.steering, "run pwd");
    try app.state.addQueuedPreview(.steering, "run uname -a");
    app.state.setQueuedCounts(mock.queued_counts);
    try mock.eventStream().push(.{ .message_end = .{
        .role = .user,
        .text = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "run pwd")),
    } });

    try mock.eventStream().push(.{ .agent_end = .{ .reason = .completed } });
    try app.drainEvents();

    try std.testing.expectEqual(@as(usize, 1), mock.resume_count);
    try std.testing.expectEqual(@as(usize, 1), app.state.queue.steering);
    try std.testing.expectEqual(@as(usize, 1), app.state.queued_previews.items.len);
    try std.testing.expectEqualStrings("run uname -a", app.state.queued_previews.items[0].text);
}

test "App drain prunes consumed steering preview after resume without user echo" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{ .queued_counts = .{ .steering = 2 } };
    defer mock.deinit();
    app.session = mock.session();
    try app.state.addQueuedPreview(.steering, "run pwd");
    try app.state.addQueuedPreview(.steering, "run ps -ef");
    app.state.setQueuedCounts(mock.queued_counts);

    try mock.eventStream().push(.{ .agent_end = .{ .reason = .completed } });
    try app.drainEvents();

    try std.testing.expectEqual(@as(usize, 1), mock.resume_count);
    try std.testing.expectEqual(@as(usize, 1), app.state.queue.steering);
    try std.testing.expectEqual(@as(usize, 1), app.state.queued_previews.items.len);
    try std.testing.expectEqualStrings("run ps -ef", app.state.queued_previews.items[0].text);
}

test "App drain keeps steering preview until runtime user message arrives" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{ .queued_counts = .{ .steering = 0 } };
    defer mock.deinit();
    app.session = mock.session();
    try app.state.addQueuedPreview(.steering, "run uname -a");
    app.state.setQueuedCounts(.{ .steering = 1 });
    app.state.status.streaming = true;

    try mock.eventStream().push(.{ .tool_execution_start = .{
        .tool_call_id = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "tool-1")),
        .tool_name = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "shell_execute")),
        .args_json = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "{}")),
    } });
    try app.drainEvents();

    try std.testing.expectEqual(@as(usize, 0), app.state.queue.steering);
    try std.testing.expectEqual(@as(usize, 1), app.state.queued_previews.items.len);
    try std.testing.expectEqualStrings("run uname -a", app.state.queued_previews.items[0].text);

    try mock.eventStream().push(.{ .message_end = .{
        .role = .user,
        .text = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "run uname -a")),
    } });
    try app.drainEvents();

    try std.testing.expectEqual(@as(usize, 0), app.state.queued_previews.items.len);
    try std.testing.expect(app.state.transcript.items.len >= 1);
    const last = app.state.transcript.items[app.state.transcript.items.len - 1];
    try std.testing.expectEqual(tui_state.TranscriptKind.user, last.kind);
    try std.testing.expectEqualStrings("run uname -a", last.text.items);
}

test "App refresh prunes stale idle steering preview" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{ .queued_counts = .{} };
    defer mock.deinit();
    app.session = mock.session();
    try app.state.addQueuedPreview(.steering, "run ps -ef");
    app.state.setQueuedCounts(.{ .steering = 1 });
    app.state.status.streaming = false;

    try app.drainEvents();

    try std.testing.expectEqual(@as(usize, 0), app.state.queue.total());
    try std.testing.expectEqual(@as(usize, 0), app.state.queued_previews.items.len);
}

test "App drain does not auto-resume queued steering after error turn" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{ .queued_counts = .{ .steering = 1 } };
    defer mock.deinit();
    app.session = mock.session();

    try mock.eventStream().push(.{ .agent_end = .{ .reason = .@"error" } });
    try app.drainEvents();

    try std.testing.expectEqual(@as(usize, 0), mock.resume_count);
    try std.testing.expectEqual(@as(usize, 1), app.state.queue.steering);
}

test "TuiModel remote streaming Enter is ignored and preserves composer" {
    var runtime = try initRemoteRuntimeForTest(std.testing.allocator);
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    model.app.?.runtime = runtime;
    runtime = undefined;
    var mock = MockAppSession{};
    defer mock.deinit();
    model.app.?.session = mock.session();
    model.app.?.state.status.streaming = true;
    try model.app.?.state.composer.buffer.appendSlice(std.testing.allocator, "new turn");

    const cmd = model.update(.{ .key = .{ .key = .enter } }, undefined);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, cmd);
    try std.testing.expectEqual(@as(usize, 0), mock.submit_count);
    try std.testing.expectEqual(@as(usize, 0), mock.steer_count);
    try std.testing.expectEqual(@as(usize, 0), mock.queued_follow_up_count);
    try std.testing.expectEqualStrings("new turn", model.app.?.state.composer.text());
    try std.testing.expectEqualStrings("", model.app.?.state.status.last_error);
    try std.testing.expectEqual(@as(usize, 0), model.app.?.state.composer.history.items.len);
}

test "TuiModel remote streaming Alt+Enter still queues follow-up" {
    var runtime = try initRemoteRuntimeForTest(std.testing.allocator);
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    model.app.?.runtime = runtime;
    runtime = undefined;
    var mock = MockAppSession{};
    defer mock.deinit();
    model.app.?.session = mock.session();
    model.app.?.state.status.streaming = true;
    try model.app.?.state.composer.buffer.appendSlice(std.testing.allocator, "follow later");

    const cmd = model.update(.{ .key = .{ .key = .enter, .modifiers = .{ .alt = true } } }, undefined);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, cmd);
    try std.testing.expectEqual(@as(usize, 0), mock.submit_count);
    try std.testing.expectEqual(@as(usize, 0), mock.steer_count);
    try std.testing.expectEqual(@as(usize, 1), mock.queued_follow_up_count);
    try std.testing.expectEqualStrings("", model.app.?.state.composer.text());
    try std.testing.expectEqual(@as(usize, 1), model.app.?.state.queue.follow_up);
    try std.testing.expectEqual(@as(usize, 1), model.app.?.state.queued_previews.items.len);
    try std.testing.expectEqualStrings("follow later", model.app.?.state.queued_previews.items[0].text);
}

test "TuiModel local streaming Enter steers when steering available" {
    const runtime = try std.testing.allocator.create(tui_runtime.TuiRuntime);
    errdefer std.testing.allocator.destroy(runtime);
    runtime.* = try tui_runtime.TuiRuntime.init(std.testing.allocator, .{});

    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    model.app.?.runtime = runtime;
    var mock = MockAppSession{};
    defer mock.deinit();
    model.app.?.session = mock.session();
    model.app.?.state.status.streaming = true;
    try model.app.?.state.composer.buffer.appendSlice(std.testing.allocator, "steer now");

    const cmd = model.update(.{ .key = .{ .key = .enter } }, undefined);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, cmd);
    try std.testing.expectEqual(@as(usize, 0), mock.submit_count);
    try std.testing.expectEqual(@as(usize, 1), mock.steer_count);
    try std.testing.expectEqual(@as(usize, 0), mock.queued_follow_up_count);
    try std.testing.expectEqualStrings("", model.app.?.state.composer.text());
    try std.testing.expectEqual(@as(usize, 1), model.app.?.state.queue.steering);
    try std.testing.expectEqual(@as(usize, 1), model.app.?.state.queued_previews.items.len);
    try std.testing.expectEqualStrings("steer now", model.app.?.state.queued_previews.items[0].text);
}

test "TuiModel stops Enter routing when drained event enters approval mode" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    model.app.?.session = mock.session();
    model.app.?.state.status.streaming = true;
    try mock.eventStream().push(.{ .tool_approval_requested = .{
        .tool_call_id = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "call-approval")),
        .tool_name = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "edit_file")),
        .args_json = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "{\"path\":\"README.md\"}")),
    } });
    try model.app.?.state.composer.buffer.appendSlice(std.testing.allocator, "should wait");

    const cmd = model.update(.{ .key = .{ .key = .enter } }, undefined);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, cmd);
    try std.testing.expectEqual(tui_state.AppMode.approval, model.app.?.state.mode);
    try std.testing.expectEqual(@as(usize, 0), mock.submit_count);
    try std.testing.expectEqual(@as(usize, 0), mock.steer_count);
    try std.testing.expectEqual(@as(usize, 0), mock.queued_follow_up_count);
    try std.testing.expectEqualStrings("should wait", model.app.?.state.composer.text());
}

test "TuiModel allows /abort slash command during approval mode" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    model.app.?.session = mock.session();
    model.app.?.state.status.streaming = true;
    try model.app.?.state.approval.setPending(std.testing.allocator, "call-approval", "edit_file", "edit_file", "{\"path\":\"README.md\"}");
    model.app.?.state.mode = .approval;

    const keys = [_]u21{ '/', 'a', 'b', 'o', 'r', 't' };
    for (keys) |c| _ = model.update(.{ .key = .{ .key = .{ .char = c } } }, undefined);

    const cmd = model.update(.{ .key = .{ .key = .enter } }, undefined);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, cmd);
    try std.testing.expectEqual(tui_state.AppMode.normal, model.app.?.state.mode);
    try std.testing.expectEqual(@as(usize, 1), mock.cancel_count);
    try std.testing.expect(!model.app.?.state.status.streaming);
    try std.testing.expectEqual(@as(usize, 1), model.app.?.state.transcript.items.len);
    try std.testing.expectEqual(tui_state.TranscriptKind.system, model.app.?.state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("Turn aborted.", model.app.?.state.transcript.items[0].text.items);
}

test "TuiModel blocks non-abort slash commands during approval mode" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    model.app.?.session = mock.session();
    model.app.?.state.status.streaming = true;
    try model.app.?.state.approval.setPending(std.testing.allocator, "call-approval", "edit_file", "edit_file", "{\"path\":\"README.md\"}");
    model.app.?.state.mode = .approval;

    const keys = [_]u21{ '/', 'h', 'e', 'l', 'p' };
    for (keys) |c| _ = model.update(.{ .key = .{ .key = .{ .char = c } } }, undefined);

    const cmd = model.update(.{ .key = .{ .key = .enter } }, undefined);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, cmd);
    try std.testing.expectEqual(tui_state.AppMode.approval, model.app.?.state.mode);
    try std.testing.expectEqual(@as(usize, 0), model.app.?.state.transcript.items.len);
    try std.testing.expectEqualStrings("/help", model.app.?.state.composer.text());
}

test "TuiModel moves composer cursor and edits in place" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();

    _ = model.update(.{ .key = .{ .key = .{ .char = 'a' } } }, undefined);
    _ = model.update(.{ .key = .{ .key = .{ .char = 'b' } } }, undefined);
    _ = model.update(.{ .key = .{ .key = .{ .char = 'c' } } }, undefined);
    _ = model.update(.{ .key = .{ .key = .left } }, undefined);
    _ = model.update(.{ .key = .{ .key = .{ .char = 'X' } } }, undefined);
    try std.testing.expectEqualStrings("abXc", model.app.?.state.composer.text());
    _ = model.update(.{ .key = .{ .key = .backspace } }, undefined);
    try std.testing.expectEqualStrings("abc", model.app.?.state.composer.text());
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

test "session picker typing filters without moving navigation" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    model.app.?.state.mode = .session_picker;
    try model.app.?.state.addSessionWithDetails("s1", "Alpha", "claude-sonnet", "anthropic");
    try model.app.?.state.addSessionWithDetails("s2", "Beta", "gpt-4o", "openai");

    _ = model.update(.{ .key = .{ .key = .{ .char = 'g' } } }, undefined);
    _ = model.update(.{ .key = .{ .key = .{ .char = 'p' } } }, undefined);
    _ = model.update(.{ .key = .{ .key = .{ .char = 't' } } }, undefined);

    try std.testing.expectEqualStrings("gpt", model.app.?.state.sessionFilterText());
    try std.testing.expectEqual(@as(usize, 1), model.app.?.state.filteredSessionCount());
    try std.testing.expectEqual(@as(usize, 0), model.app.?.state.session_index);
    try std.testing.expectEqual(@as(usize, 1), model.app.?.state.sessionRawIndexAtFilteredIndex(0).?);

    _ = model.update(.{ .key = .{ .key = .backspace } }, undefined);
    try std.testing.expectEqualStrings("gp", model.app.?.state.sessionFilterText());
}

test "session picker keeps selected session when still matched after filter" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    try app.state.addSessionWithDetails("s1", "Alpha", "claude-sonnet", "anthropic");
    try app.state.addSessionWithDetails("s2", "Beta", "gpt-4o", "openai");
    try app.state.addSessionWithDetails("s3", "Gamma", "gpt-4.1", "openai");
    app.state.session_index = 2;

    TuiModel.updateSessionFilter(&app, .char, 'g');
    TuiModel.updateSessionFilter(&app, .char, 'p');
    TuiModel.updateSessionFilter(&app, .char, 't');

    try std.testing.expectEqual(@as(usize, 2), app.state.filteredSessionCount());
    try std.testing.expectEqual(@as(usize, 1), app.state.session_index);
    try std.testing.expectEqual(@as(usize, 2), app.state.sessionRawIndexAtFilteredIndex(app.state.session_index).?);
}

fn initRemoteRuntimeForTest(allocator: std.mem.Allocator) !*tui_runtime.TuiRuntime {
    const runtime = try allocator.create(tui_runtime.TuiRuntime);
    runtime.* = tui_runtime.TuiRuntime.init(allocator, .{ .backend = .remote }) catch |err| {
        allocator.destroy(runtime);
        return err;
    };
    return runtime;
}

test "resume selected session allows remote runtime" {
    var runtime = try initRemoteRuntimeForTest(std.testing.allocator);
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    app.runtime = runtime;
    runtime = undefined;

    try std.testing.expectError(error.NoStoreConfigured, app.resumeSelectedSession());

    app.store = try session_store.Store.init(std.testing.allocator, ".");

    try app.resumeSelectedSession();
}

// ============================================================================
// Mock provider for ProductionRuntime lifetime regression tests
// ============================================================================

const MockProvider = struct {
    fn stream(
        model: ai_types.Model,
        context: ai_types.Context,
        options: ?ai_types.StreamOptions,
        a: std.mem.Allocator,
    ) anyerror!*event_stream.AssistantMessageEventStream {
        _ = model;
        _ = context;
        _ = options;

        const s = try a.create(event_stream.AssistantMessageEventStream);
        s.* = event_stream.AssistantMessageEventStream.init(a);

        s.push(.{ .start = .{ .partial = .{
            .content = &.{},
            .api = "mock-api",
            .provider = "mock",
            .model = "mock-model",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = compat.time.nowMillis(),
            .is_owned = false,
        } } }) catch {};

        s.complete(try ai_types.cloneAssistantMessage(a, .{
            .content = &.{.{ .text = .{ .text = "ok" } }},
            .api = "mock-api",
            .provider = "mock",
            .model = "mock-model",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = compat.time.nowMillis(),
            .is_owned = false,
        }));
        s.markThreadDone();
        return s;
    }

    fn streamSimple(
        model: ai_types.Model,
        context: ai_types.Context,
        options: ?ai_types.SimpleStreamOptions,
        a: std.mem.Allocator,
    ) anyerror!*event_stream.AssistantMessageEventStream {
        _ = options;
        return stream(model, context, null, a);
    }
};

fn registerMockProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "mock-api",
        .stream = MockProvider.stream,
        .stream_simple = MockProvider.streamSimple,
    }, null);
}

const test_model = ai_types.Model{
    .id = "mock-model",
    .name = "Mock",
    .api = "mock-api",
    .provider = "mock",
    .base_url = "",
    .reasoning = false,
    .input = &[_][]const u8{"text"},
    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
    .context_window = 1024,
    .max_tokens = 256,
};

fn testContext() ai_types.Context {
    const user = ai_types.Message{ .user = .{
        .content = .{ .text = "hi" },
        .timestamp = compat.time.nowMillis(),
    } };
    return .{ .messages = &[_]ai_types.Message{user} };
}

fn drainStreamAndVerify(allocator: std.mem.Allocator, stream: *event_stream.AssistantMessageEventStream) !void {
    var saw_start = false;
    while (stream.wait()) |ev| {
        var owned_ev = ev;
        defer ai_types.deinitAssistantMessageEvent(allocator, &owned_ev);
        if (ev == .start) saw_start = true;
    }
    try std.testing.expect(saw_start);
    try std.testing.expect(stream.getResult() != null);
}

// Regression test: initBridge() must be called after init() so the bridge's
// registry pointer is stable. This test would crash with hash map corruption
// if init() initialized the bridge with a dangling pointer to the local
// variable's registry.
test "ProductionRuntime initBridge gives stable registry pointer" {
    const allocator = std.testing.allocator;
    var production = try ProductionRuntime.init(allocator);
    defer production.deinit();

    try registerMockProvider(&production.registry);
    production.initBridge();

    const protocol = production.options().protocol.?;
    const stream = try protocol.stream(test_model, testContext(), .{ .api_key = "test-key" }, allocator);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    try drainStreamAndVerify(allocator, stream);
}

// Reuse scenario: the same ProductionRuntime (and therefore the same stable
// registry pointer) can be used for multiple sequential streams.
test "ProductionRuntime multiple sequential streams reuse stable pointer" {
    const allocator = std.testing.allocator;
    var production = try ProductionRuntime.init(allocator);
    defer production.deinit();

    try registerMockProvider(&production.registry);
    production.initBridge();

    const protocol = production.options().protocol.?;

    for (0..3) |_| {
        const stream = try protocol.stream(test_model, testContext(), .{ .api_key = "test-key" }, allocator);
        defer {
            stream.deinit();
            allocator.destroy(stream);
        }
        try drainStreamAndVerify(allocator, stream);
    }
}

// Lifetime ordering: stream threads may outlive TuiSession/TuiRuntime but
// must not outlive ProductionRuntime, because the stream thread references
// ProductionRuntime.registry. This test simulates that ordering by starting
// a stream through the protocol client, dropping the TuiRuntime/TuiSession
// that originated the request, and verifying the stream still completes and
// ProductionRuntime.deinit() is safe.
test "ProductionRuntime outlives stream threads from dropped TuiRuntime" {
    const allocator = std.testing.allocator;
    var production = try ProductionRuntime.init(allocator);
    defer production.deinit();

    try registerMockProvider(&production.registry);
    production.initBridge();

    const stream = blk: {
        const options = production.options();
        const protocol = options.protocol.?;
        const s = try protocol.stream(test_model, testContext(), .{ .api_key = "test-key" }, allocator);
        break :blk s;
    };
    // TuiRuntimeOptions and any associated TuiSession are now out of scope,
    // but the stream thread still references production.registry.
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    try drainStreamAndVerify(allocator, stream);
}
