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
const custom_providers = @import("custom_providers");
const model_catalog = @import("model_catalog");
const tui_config = @import("tui_config");
const tui_theme = @import("tui_theme");
const tui_text = @import("tui_text");
const oauth_storage = @import("oauth/storage");
const session_store = @import("tui_session_store");
const transcript_view = @import("tui_view_transcript");
const composer_view = @import("tui_view_composer");
const status_bar_view = @import("tui_view_status_bar");
const approval_view = @import("tui_view_approval");
const session_picker_view = @import("tui_view_session_picker");
const menu_picker_view = @import("tui_view_menu_picker");
const tui_render = @import("tui_render");
const permission = @import("permission");
const fixture_provider = @import("tui_fixture");
const OwnedSlice = @import("owned_slice").OwnedSlice;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub const TuiRuntime = tui_runtime.TuiRuntime;
pub const TuiRuntimeOptions = tui_runtime.TuiRuntimeOptions;

const max_session_event_jsonl_bytes = 8 * 1024 * 1024;
const max_session_event_payload_bytes = max_session_event_jsonl_bytes / 2;

fn isSecretLoginPrompt(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "API key") != null or std.mem.indexOf(u8, message, "api key") != null;
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
    return loadRuntimeModelsWithCatalog(allocator, model_catalog.loadProductionModels, true);
}

fn fixtureModels(allocator: std.mem.Allocator) ![]ai_types.Model {
    const models = try allocator.alloc(ai_types.Model, 1);
    errdefer allocator.free(models);
    models[0] = defaultModel();
    return models;
}

fn loadRuntimeModelsFresh(allocator: std.mem.Allocator) ![]ai_types.Model {
    return loadRuntimeModelsWithCatalog(allocator, model_catalog.refreshProductionModels, false);
}

fn loadRuntimeModelsWithCatalog(
    allocator: std.mem.Allocator,
    comptime loadCatalog: fn (std.mem.Allocator) anyerror![]ai_types.Model,
    comptime catch_catalog_errors: bool,
) ![]ai_types.Model {
    const catalog_models = loadCatalog(allocator) catch |err| if (catch_catalog_errors)
        try allocator.alloc(ai_types.Model, 0)
    else
        return err;
    var consumed: usize = 0;
    errdefer {
        for (catalog_models[consumed..]) |*model| model.deinit(allocator);
        allocator.free(catalog_models);
    }

    var models = std.ArrayList(ai_types.Model).empty;
    errdefer {
        if (models.items.len > 1) for (models.items[1..]) |*model| model.deinit(allocator);
        models.deinit(allocator);
    }
    try models.append(allocator, defaultModel());
    for (catalog_models) |model| {
        if (isDatedVariantOf(model.id, models.items[0].id)) {
            models.items[0] = foldCatalogLimits(models.items[0], model);
            var folded = model;
            folded.deinit(allocator);
            consumed += 1;
            continue;
        }
        try models.append(allocator, model);
        consumed += 1;
    }
    const result = try models.toOwnedSlice(allocator);
    allocator.free(catalog_models);
    return result;
}

fn foldCatalogLimits(base: ai_types.Model, catalog: ai_types.Model) ai_types.Model {
    var folded = base;
    folded.max_tokens = catalog.max_tokens;
    folded.context_window = catalog.context_window;
    folded.reasoning = catalog.reasoning;
    if (catalog.cost.input > 0) folded.cost = catalog.cost;
    return folded;
}

fn ownedTestModel(allocator: std.mem.Allocator, id: []const u8, max_tokens: u32, input_cost: f64) !ai_types.Model {
    var model = defaultModel();
    model.id = id;
    model.max_tokens = max_tokens;
    model.context_window = 1_000_000;
    model.cost = .{ .input = input_cost, .output = input_cost * 5, .cache_read = 0, .cache_write = 0 };
    return ai_types.cloneModel(allocator, model);
}

fn datedDefaultCatalog(allocator: std.mem.Allocator) anyerror![]ai_types.Model {
    const models = try allocator.alloc(ai_types.Model, 2);
    errdefer allocator.free(models);
    models[0] = try ownedTestModel(allocator, "claude-sonnet-4-5-20250929", 64_000, 0);
    errdefer models[0].deinit(allocator);
    models[1] = try ownedTestModel(allocator, "claude-opus-4-1", 32_000, 15.0);
    return models;
}

fn runtimeModelsFoldProbe(allocator: std.mem.Allocator) !void {
    const models = try loadRuntimeModelsWithCatalog(allocator, datedDefaultCatalog, false);
    defer model_catalog.deinitModels(allocator, models);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", models[0].id);
    try std.testing.expectEqualStrings("Claude Sonnet 4.5", models[0].name);
    try std.testing.expect(!models[0].is_owned);
    try std.testing.expectEqual(@as(u32, 64_000), models[0].max_tokens);
    try std.testing.expectEqual(@as(u32, 1_000_000), models[0].context_window);
    try std.testing.expectEqual(@as(f64, 3.0), models[0].cost.input);
    try std.testing.expectEqualStrings("claude-opus-4-1", models[1].id);
    try std.testing.expect(models[1].is_owned);
}

test "runtime models fold the catalog's default alias into the fallback and keep one owner per model" {
    try runtimeModelsFoldProbe(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runtimeModelsFoldProbe, .{});
}

fn isDatedVariantOf(id: []const u8, base: []const u8) bool {
    if (std.mem.eql(u8, id, base)) return true;
    if (id.len != base.len + 9 or !std.mem.startsWith(u8, id, base) or id[base.len] != '-') return false;
    for (id[base.len + 1 ..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

test "isDatedVariantOf recognises dated aliases of the default model" {
    try std.testing.expect(isDatedVariantOf("claude-sonnet-4-5-20250929", "claude-sonnet-4-5"));
    try std.testing.expect(isDatedVariantOf("claude-sonnet-4-5", "claude-sonnet-4-5"));
    try std.testing.expect(!isDatedVariantOf("claude-sonnet-4-5-fast", "claude-sonnet-4-5"));
    try std.testing.expect(!isDatedVariantOf("claude-opus-4-1-20250805", "claude-sonnet-4-5"));
}

test "App loginStatusFor reports stored, environment and expired credentials" {
    var storage = oauth_storage.AuthStorage{ .providers = std.StringHashMap(oauth_storage.ProviderAuth).init(std.testing.allocator), .allocator = std.testing.allocator };
    defer storage.deinit();
    try storage.providers.put(try std.testing.allocator.dupe(u8, "kimi"), .{ .api_key = try std.testing.allocator.dupe(u8, "sk-kimi") });
    try storage.providers.put(try std.testing.allocator.dupe(u8, "anthropic"), .{ .oauth = .{
        .refresh = try std.testing.allocator.dupe(u8, "r"),
        .access = try std.testing.allocator.dupe(u8, "sk-ant-oat-x"),
        .expires = std.math.maxInt(i64),
    } });
    try storage.providers.put(try std.testing.allocator.dupe(u8, "openai-codex"), .{ .oauth = .{
        .refresh = try std.testing.allocator.dupe(u8, "r"),
        .access = try std.testing.allocator.dupe(u8, "old"),
        .expires = 1,
    } });

    try std.testing.expectEqual(App.LoginStatus.api_key, App.loginStatusFor(&storage, "kimi", false));
    try std.testing.expectEqual(App.LoginStatus.oauth, App.loginStatusFor(&storage, "anthropic", false));
    try std.testing.expectEqual(App.LoginStatus.env_key, App.loginStatusFor(null, "anthropic", true));
    try std.testing.expectEqual(App.LoginStatus.none, App.loginStatusFor(null, "kimi", false));
    try std.testing.expectEqual(App.LoginStatus.expired, App.loginStatusFor(&storage, "openai-codex", false));
    try std.testing.expectEqual(App.LoginStatus.env_key, App.loginStatusFor(&storage, "github-copilot", true));
    try std.testing.expectEqual(App.LoginStatus.none, App.loginStatusFor(&storage, "github-copilot", false));
    try std.testing.expect(std.mem.indexOf(u8, App.loginBadge(.oauth).?, "logged in") != null);
    try std.testing.expect(App.loginBadge(.none) == null);
}

test "App welcome banner neutralises control bytes in the working directory" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    std.testing.allocator.free(app.working_dir);
    app.working_dir = try std.testing.allocator.dupe(u8, "/tmp/evil\x1b[2J\x1b]0;pwned\x07dir");
    try app.appendWelcome();
    const entry = app.state.transcript.items[app.state.transcript.items.len - 1];
    try std.testing.expectEqual(tui_state.TranscriptKind.welcome, entry.kind);
    try std.testing.expect(std.mem.indexOf(u8, entry.text.items, "\x1b") == null);
    try std.testing.expect(std.mem.indexOf(u8, entry.text.items, "\x07") == null);
    try std.testing.expect(std.mem.indexOf(u8, entry.text.items, "/tmp/evil?[2J?]0;pwned?dir") != null);
}

test "Context requestClearScreen discards history queued before the request" {
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    try tctx.ctx.printAbove("stale row");
    tctx.ctx.requestClearScreen();
    try std.testing.expect(!tctx.ctx.hasPendingAbove());
    try tctx.ctx.printAbove("transcript cleared");
    const above = try tctx.ctx.takeAbove(std.testing.allocator);
    defer std.testing.allocator.free(above);
    try std.testing.expectEqualStrings("transcript cleared\n", above);
}

test "TuiModel login picker shows which providers are logged in" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator), .render_mode = .inline_history };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    tctx.ctx.width = 80;
    tctx.ctx.height = 24;
    model.app.?.login_status[0] = .oauth;
    model.app.?.login_status[3] = .api_key;
    model.app.?.state.mode = .picker;
    model.app.?.state.picker_kind = .login;

    const frame = model.view(&tctx.ctx);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Login provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "logged in") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "api key") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "expired") == null);
}

pub const ProductionRuntime = struct {
    allocator: std.mem.Allocator,
    registry: api_registry.ApiRegistry,
    bridge: agent.InProcessProviderProtocolBridge,
    permission_engine: permission.PermissionEngine,
    models: []ai_types.Model,
    initial_model: ?SavedModelRef = null,

    pub const InitOptions = struct {
        fixture: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, init_options: InitOptions) !ProductionRuntime {
        var registry = api_registry.ApiRegistry.init(allocator);
        errdefer registry.deinit();
        try register_builtins.registerBuiltInApiProviders(&registry);

        const workspace_root = try currentPathOwned(allocator);
        defer allocator.free(workspace_root);
        var permission_engine = permission.PermissionEngine.init(allocator, .{ .workspace_root = workspace_root }) catch
            permission.PermissionEngine.initEmpty(allocator, .{ .workspace_root = workspace_root }) catch
            @panic("OOM initializing permission engine");
        errdefer permission_engine.deinit();

        const models = if (init_options.fixture)
            try fixtureModels(allocator)
        else
            try loadRuntimeModels(allocator);
        errdefer model_catalog.deinitModels(allocator, models);

        var saved_config: ?tui_config.Config = null;
        var maybe_store: ?tui_config.Store = tui_config.Store.initDefault(allocator) catch |err| switch (err) {
            error.HomeNotFound => null,
            else => return err,
        };
        if (maybe_store) |*store| {
            defer store.deinit();
            saved_config = store.loadIfExists() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
        }
        errdefer if (saved_config) |*cfg| cfg.deinit(allocator);

        var initial_model: ?SavedModelRef = null;
        if (saved_config) |cfg| {
            if (cfg.model.len > 0) {
                initial_model = SavedModelRef{
                    .id = try allocator.dupe(u8, cfg.model),
                    .provider = try allocator.dupe(u8, cfg.provider),
                    .api = try allocator.dupe(u8, cfg.api),
                };
            }
        }
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
        if (saved_config) |*cfg| cfg.deinit(allocator);
        saved_config = null;
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
        model_catalog.deinitModels(self.allocator, self.models);
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

pub const fixture_env_var = "MAKAI_TUI_FIXTURE";

const fixture_step_separator = '|';
const fixture_step_escape = '\\';
const fixture_tool_arg_json = "{}";

pub const FixtureStepError = error{
    EmptyFixtureStep,
    UnknownFixtureStepPrefix,
    OutOfMemory,
};

pub const FixtureRuntime = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    steps: std.ArrayList(fixture_provider.ResponseStep),
    tool_specs: std.ArrayList([]fixture_provider.ToolCallSpec),
    payloads: std.ArrayList([]u8),
    provider: fixture_provider.MockProvider,

    pub fn fromEnv(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !?*FixtureRuntime {
        return fromValue(allocator, env.get(fixture_env_var));
    }

    fn fromValue(allocator: std.mem.Allocator, value: ?[]const u8) !?*FixtureRuntime {
        const supplied = value orelse return null;
        if (supplied.len == 0) return null;
        const text = try allocator.dupe(u8, supplied);
        errdefer allocator.free(text);
        const self = try allocator.create(FixtureRuntime);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .text = text,
            .steps = .empty,
            .tool_specs = .empty,
            .payloads = .empty,
            .provider = undefined,
        };
        errdefer self.deinitSteps();
        if (firstSegmentIsScenarioStep(text)) {
            try self.appendScenarioSteps(text);
        } else {
            try self.steps.append(allocator, .{ .text = text });
        }
        self.provider = fixture_provider.MockProvider.init(.{ .steps = self.steps.items, .repeat_last = true });
        return self;
    }

    fn firstSegmentIsScenarioStep(text: []const u8) bool {
        const first = text[0..unescapedSeparatorIndex(text)];
        return scenarioStepKind(first) != null;
    }

    fn scenarioStepKind(segment: []const u8) ?enum { text, tool, hold, err } {
        if (std.mem.startsWith(u8, segment, "text:")) return .text;
        if (std.mem.startsWith(u8, segment, "tool:")) return .tool;
        if (std.mem.eql(u8, segment, "hold")) return .hold;
        if (std.mem.startsWith(u8, segment, "error:")) return .err;
        return null;
    }

    fn unescapedSeparatorIndex(text: []const u8) usize {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == fixture_step_escape and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (text[i] == fixture_step_separator) return i;
        }
        return text.len;
    }

    fn unescapeStep(self: *FixtureRuntime, raw: []const u8) FixtureStepError![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, fixture_step_escape) == null) return raw;
        const out = try self.allocator.alloc(u8, raw.len);
        self.payloads.append(self.allocator, out) catch {
            self.allocator.free(out);
            return error.OutOfMemory;
        };
        var len: usize = 0;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == fixture_step_escape and i + 1 < raw.len and
                (raw[i + 1] == fixture_step_separator or raw[i + 1] == fixture_step_escape))
            {
                i += 1;
            }
            out[len] = raw[i];
            len += 1;
            i += 1;
        }
        return out[0..len];
    }

    fn appendScenarioSteps(self: *FixtureRuntime, text: []const u8) FixtureStepError!void {
        var rest = text;
        while (true) {
            const segment_end = unescapedSeparatorIndex(rest);
            const had_separator = segment_end < rest.len;
            const segment = try self.unescapeStep(rest[0..segment_end]);
            if (segment.len == 0) return error.EmptyFixtureStep;
            const kind = scenarioStepKind(segment) orelse return error.UnknownFixtureStepPrefix;
            switch (kind) {
                .text => {
                    const body = segment["text:".len..];
                    if (body.len == 0) return error.EmptyFixtureStep;
                    try self.steps.append(self.allocator, .{ .text = body });
                },
                .tool => {
                    const step_rest = segment["tool:".len..];
                    var name = step_rest;
                    var args_json: []const u8 = fixture_tool_arg_json;
                    if (std.mem.indexOfScalar(u8, step_rest, '#')) |hash| {
                        name = step_rest[0..hash];
                        args_json = step_rest[hash + 1 ..];
                    }
                    if (name.len == 0 or args_json.len == 0) return error.EmptyFixtureStep;
                    const spec = try self.allocator.alloc(fixture_provider.ToolCallSpec, 1);
                    spec[0] = .{ .id = "fixture-tool-call", .name = name, .arguments_json = args_json };
                    self.tool_specs.append(self.allocator, spec) catch {
                        self.allocator.free(spec);
                        return error.OutOfMemory;
                    };
                    try self.steps.append(self.allocator, .{ .tool_calls = spec });
                },
                .hold => try self.steps.append(self.allocator, .{ .wait_for_cancel = {} }),
                .err => {
                    const body = segment["error:".len..];
                    if (body.len == 0) return error.EmptyFixtureStep;
                    try self.steps.append(self.allocator, .{ .provider_error = body });
                },
            }
            if (!had_separator) return;
            rest = rest[segment_end + 1 ..];
            if (rest.len == 0) return error.EmptyFixtureStep;
        }
    }

    fn deinitSteps(self: *FixtureRuntime) void {
        for (self.tool_specs.items) |spec| self.allocator.free(spec);
        self.tool_specs.deinit(self.allocator);
        for (self.payloads.items) |payload| self.allocator.free(payload);
        self.payloads.deinit(self.allocator);
        self.steps.deinit(self.allocator);
    }

    pub fn deinit(self: *FixtureRuntime) void {
        self.deinitSteps();
        self.allocator.free(self.text);
        self.allocator.destroy(self);
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    state: tui_state.AppState,
    runtime: ?*tui_runtime.TuiRuntime = null,
    session: ?tui_runtime.TuiSession = null,
    approval_waiter: ?*ApprovalWaiter = null,
    login: ?*tui_login.LoginSession = null,
    store: ?session_store.Store = null,
    session_id: []u8 = &.{},
    working_dir: []u8 = &.{},
    last_view_height: usize = 8,
    inline_history_flushed: usize = 0,
    inline_flushed_rows: usize = 0,
    login_status: [login_providers.len]LoginStatus = [_]LoginStatus{.none} ** login_providers.len,
    pending_session_reset: bool = false,
    quarantine_events: bool = false,
    quarantine_generation: u32 = 0,
    quarantine_buffer: std.ArrayList(tui_runtime.TuiEvent) = .empty,
    pending_clipboard: ?[]u8 = null,
    interrupt_armed_tick: ?u64 = null,
    pending_clear_screen: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: tui_runtime.TuiRuntimeOptions) !App {
        var runtime_options = options;
        const approval_waiter = try allocator.create(ApprovalWaiter);
        errdefer allocator.destroy(approval_waiter);
        approval_waiter.* = .{ .allocator = allocator };
        runtime_options.tool_approval_ctx = approval_waiter;
        runtime_options.tool_approval_callback = approvalCallback;
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
            .quarantine_buffer = std.ArrayList(tui_runtime.TuiEvent).empty,
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
        app.store = session_store.Store.initDefault(allocator) catch null;
        try app.ensureSessionId();
        app.working_dir = currentPathOwned(allocator) catch try allocator.dupe(u8, "");
        app.loadSessions() catch |err| try app.recordError(@errorName(err));
        return app;
    }

    pub fn initWithoutRuntime(allocator: std.mem.Allocator) App {
        return .{
            .allocator = allocator,
            .state = tui_state.AppState.init(allocator),
            .quarantine_buffer = std.ArrayList(tui_runtime.TuiEvent).empty,
        };
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
        for (self.quarantine_buffer.items) |*event| event.deinit(self.allocator);
        self.quarantine_buffer.deinit(self.allocator);
        self.state.deinit();
        self.* = undefined;
    }

    fn ensureSessionId(self: *App) !void {
        if (self.session_id.len > 0) return;
        self.session_id = generateSessionId(self.allocator) catch try self.allocator.dupe(u8, "default");
        try self.state.status.setSessionId(self.allocator, self.session_id);
    }

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
            try self.state.addSession(meta.session_id, label);
        }
    }

    pub fn resumeSelectedSession(self: *App) !void {
        const store = self.store orelse return error.NoStoreConfigured;
        if (self.state.session_index >= self.state.sessions.items.len) return;
        const selected = self.state.sessions.items[self.state.session_index];
        const runtime = if (self.runtime) |r| r else return error.NoRuntimeConfigured;
        const id = selected.id;
        var loaded = try store.resumeSession(id, runtime);
        defer loaded.deinit(self.allocator);
        const new_session_id = try self.allocator.dupe(u8, loaded.metadata.session_id);
        self.discardPendingEvents();
        self.pending_session_reset = false;
        self.quarantine_events = false;
        for (self.quarantine_buffer.items) |*buf_ev| {
            var mutable = buf_ev.*;
            mutable.deinit(self.allocator);
        }
        self.quarantine_buffer.clearRetainingCapacity();
        self.state.resetReplayState();
        self.inline_history_flushed = 0;
        self.inline_flushed_rows = 0;
        if (self.session_id.len > 0) self.allocator.free(self.session_id);
        self.session_id = new_session_id;
        try self.state.status.setSessionId(self.allocator, self.session_id);
        if (runtime.currentModel()) |model| {
            try self.state.status.setModelWithContext(self.allocator, model.id, model.provider, model.context_window);
            self.state.telemetry.context_window = model.context_window;
        } else {
            try self.state.status.setModelWithContext(self.allocator, loaded.metadata.model, loaded.metadata.provider, 0);
        }
        for (loaded.events.items) |*event| {
            try self.applyRuntimeEvent(event.*);
        }
        try self.state.finalizeInterruptedTools();
        self.state.retireToolOccurrences();
        if (self.session) |*session| session.clearQueuedMessages();
        self.refreshQueuedCounts();
        self.state.status.streaming = false;
        self.state.mode = .normal;
    }

    const login_providers = [_][]const u8{ "anthropic", "github-copilot", "openai-codex", "kimi" };
    const login_env_keys = [_][]const []const u8{ &.{ "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY" }, &.{}, &.{}, &.{} };

    pub const LoginStatus = enum { none, api_key, env_key, oauth, expired };

    pub fn loginStatusFor(storage: ?*const oauth_storage.AuthStorage, provider_id: []const u8, env_key_present: bool) LoginStatus {
        if (storage) |stored| {
            if (stored.providers.get(provider_id)) |auth| {
                return switch (auth) {
                    .api_key => .api_key,
                    .oauth => if (stored.configuredCredentialsExpired(provider_id)) .expired else .oauth,
                };
            }
        }
        return if (env_key_present) .env_key else .none;
    }

    pub fn loginBadge(status: LoginStatus) ?[]const u8 {
        return switch (status) {
            .none => null,
            .api_key => tui_theme.glyph.check ++ " api key",
            .env_key => tui_theme.glyph.check ++ " env key",
            .oauth => tui_theme.glyph.check ++ " logged in",
            .expired => "expired · login again",
        };
    }

    fn refreshLoginStatus(self: *App) void {
        var loaded: ?oauth_storage.AuthStorage = oauth_storage.AuthStorage.loadDefaultStoredOnly(self.allocator) catch null;
        defer if (loaded) |*storage| storage.deinit();
        const storage: ?*const oauth_storage.AuthStorage = if (loaded) |*stored| stored else null;
        for (login_providers, 0..) |provider, i| {
            var env_present = false;
            for (login_env_keys[i]) |name| {
                if (compat.getEnvVarOwned(self.allocator, name)) |value| {
                    env_present = env_present or value.len > 0;
                    self.allocator.free(value);
                } else |_| {}
            }
            self.login_status[i] = loginStatusFor(storage, provider, env_present);
        }
    }

    const permission_modes = [_]tui_runtime.PermissionMode{ .bypass, .ask };

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

    fn openPicker(self: *App, kind: tui_state.PickerKind) void {
        self.state.picker_kind = kind;
        self.state.menu_index = 0;
        self.state.menu_scroll = 0;
        switch (kind) {
            .model => if (self.runtime) |runtime| {
                if (runtime.currentModel()) |active| {
                    for (runtime.availableModels(), 0..) |model, i| {
                        if (std.mem.eql(u8, model.id, active.id)) {
                            self.state.menu_index = i;
                            break;
                        }
                    }
                }
            },
            .permission => {
                if (self.runtime) |runtime| self.state.permission_mode = runtime.permissionMode();
                for (permission_modes, 0..) |mode, i| {
                    if (mode == self.state.permission_mode) {
                        self.state.menu_index = i;
                        break;
                    }
                }
            },
            .login => self.refreshLoginStatus(),
        }
        self.state.mode = .picker;
        self.ensureMenuSelectionVisible();
    }

    fn menuItemCount(self: *const App) usize {
        return switch (self.state.picker_kind) {
            .model => if (self.runtime) |runtime| runtime.availableModels().len else 0,
            .login => login_providers.len,
            .permission => permission_modes.len,
        };
    }

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

    fn warnOnUnreadableCustomProviders(self: *App) void {
        const path = custom_providers.configPath(self.allocator) catch return;
        defer self.allocator.free(path);
        const data = compat.fs.readFileAlloc(self.allocator, compat.fs.getCwd(), path, custom_providers.max_config_bytes) catch return;
        defer self.allocator.free(data);
        const providers = custom_providers.parse(self.allocator, data) catch |err| {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "{s} was not loaded: {s}. Custom providers are disabled until it parses.",
                .{ path, @errorName(err) },
            ) catch return;
            defer self.allocator.free(msg);
            self.state.appendTranscript(.@"error", msg) catch {};
            return;
        };
        custom_providers.deinitProviders(self.allocator, providers);
    }

    fn isDeclaredCustomProvider(self: *App, provider_id: []const u8) bool {
        const providers = custom_providers.load(self.allocator, custom_providers.max_config_bytes) catch return false;
        defer custom_providers.deinitProviders(self.allocator, providers);
        for (providers) |provider| {
            if (std.mem.eql(u8, provider.id, provider_id)) return true;
        }
        return false;
    }

    fn startCustomLogin(self: *App, provider_id: []const u8) !void {
        self.state.mode = .normal;
        if (self.login != null) {
            try self.state.appendTranscript(.system, "a login is already in progress");
            return;
        }
        self.login = tui_login.LoginSession.startApiKey(self.allocator, provider_id) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "could not start login for {s}: {s}", .{ provider_id, @errorName(err) });
            defer self.allocator.free(msg);
            try self.state.appendTranscript(.@"error", msg);
            return;
        };
        const msg = try std.fmt.allocPrint(self.allocator, "starting login for {s}…", .{provider_id});
        defer self.allocator.free(msg);
        try self.state.appendTranscript(.system, msg);
    }

    fn startLoginProviderName(self: *App, provider_id: []const u8) !void {
        const idx = loginProviderIndex(provider_id) orelse {
            if (self.isDeclaredCustomProvider(provider_id)) return self.startCustomLogin(provider_id);
            const msg = try std.fmt.allocPrint(self.allocator, "unknown login provider: {s}", .{provider_id});
            defer self.allocator.free(msg);
            try self.state.status.setError(self.allocator, msg);
            try self.state.appendTranscript(.@"error", msg);
            return;
        };
        try self.startLoginProviderIndex(idx);
    }

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
                const provider_id = try self.allocator.dupe(u8, session.provider_id);
                defer self.allocator.free(provider_id);
                const save_err = self.saveLoginCredentials(provider_id, creds, session.storesApiKey());
                creds.deinit(self.allocator);
                self.finishLogin();
                if (save_err) |_| {
                    self.refreshLoginStatus();
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

    fn finishLogin(self: *App) void {
        if (self.login) |session| {
            session.deinit();
            self.login = null;
        }
        if (self.state.mode == .login_input) self.state.mode = .normal;
    }

    fn saveLoginCredentials(self: *App, provider_id: []const u8, creds: oauth_storage.Credentials, stores_api_key: bool) !void {
        var storage = try oauth_storage.AuthStorage.loadDefault(self.allocator);
        defer storage.deinit();

        const key = try self.allocator.dupe(u8, provider_id);
        var owned = false;
        errdefer if (!owned) self.allocator.free(key);
        if (stores_api_key) {
            const api_key = try self.allocator.dupe(u8, creds.access);
            errdefer if (!owned) self.allocator.free(api_key);

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
        defer model_catalog.deinitModels(self.allocator, models);
        try runtime.replaceModels(models, current_model);
    }

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

    fn saveEvent(self: *App, event: tui_runtime.TuiEvent) void {
        const store = self.store orelse return;
        switch (event) {
            .message_start, .context_usage, .prompt_segment_usage, .agent_start, .turn_start, .turn_end, .agent_end => {},
            .text_delta => |payload| {
                if (jsonStringBudget(payload.delta.slice()) > max_session_event_payload_bytes) return;
            },
            .thinking_delta => |payload| {
                if (jsonStringBudget(payload.delta.slice()) > max_session_event_payload_bytes) return;
            },
            .tool_call_delta => |payload| {
                if (jsonStringBudget(payload.delta.slice()) > max_session_event_payload_bytes) return;
            },
            .tool_execution_start => |payload| {
                if (toolRequestPayloadSize(payload) > max_session_event_payload_bytes) return;
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
            .last_active = compat.time.nowMillis(),
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

            const gen = ev.generation();
            if (self.quarantine_generation > 0 and gen <= self.quarantine_generation) {
                continue;
            }

            if (self.quarantine_events) {
                const is_lifecycle = ev == .agent_start or ev == .turn_start;
                const is_terminal = ev == .agent_end or ev == .@"error";
                if (is_lifecycle or is_terminal) {
                    self.quarantine_events = false;
                    {
                        defer {
                            for (self.quarantine_buffer.items) |*remaining| {
                                var mutable = remaining.*;
                                mutable.deinit(self.allocator);
                            }
                            self.quarantine_buffer.clearRetainingCapacity();
                        }
                        while (self.quarantine_buffer.items.len > 0) {
                            var mutable = self.quarantine_buffer.orderedRemove(0);
                            defer mutable.deinit(self.allocator);
                            if (mutable == .agent_end and mutable.agent_end.reason == .completed) completed_agent_end = true;
                            self.saveEvent(mutable);
                            try self.applyRuntimeEvent(mutable);
                        }
                    }
                } else {
                    const cloned = try ev.clone(self.allocator);
                    self.quarantine_buffer.append(self.allocator, cloned) catch |err| {
                        var to_free = cloned;
                        to_free.deinit(self.allocator);
                        return err;
                    };
                    continue;
                }
            }
            if (ev == .agent_end and ev.agent_end.reason == .completed) completed_agent_end = true;
            self.saveEvent(ev);
            try self.applyRuntimeEvent(ev);
        }
        self.refreshQueuedCounts();
        self.state.reconcileSteers(session.steersConsumedCount());
        self.syncBackpressureState();
        self.syncModelTelemetry();
        if (self.pending_session_reset and !self.state.status.streaming) {
            if (self.runtime) |runtime| {
                if (runtime.local_agent) |*local| {
                    if (local.isIdle()) {
                        local.clearAllQueues();
                        local.replaceMessages(&.{}) catch {};
                        self.pending_session_reset = false;
                    }
                }
            } else {
                self.pending_session_reset = false;
            }
        }
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
                    if (payload.steering) return;
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
            self.state.setQueuedCounts(session.queuedCounts());
        }
    }

    fn discardPendingEvents(self: *App) void {
        var session = &(self.session orelse return);
        while (session.popEvent()) |event| {
            var ev = event;
            defer ev.deinit(self.allocator);
            if (!self.quarantine_events and ev.generation() > self.quarantine_generation) {
                self.saveEvent(ev);
            }
        }
    }

    fn applyPendingSessionResetSync(self: *App) !void {
        if (!self.pending_session_reset) return;
        if (self.runtime) |runtime| {
            if (runtime.local_agent) |*local| {
                if (!local.isIdle()) return error.PendingSessionReset;
                local.clearAllQueues();
                local.replaceMessages(&.{}) catch {};
            }
        }
        self.pending_session_reset = false;
    }

    pub fn submit(self: *App, text: []const u8) !void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        self.state.transcript_scroll = 0;
        if (trimmed[0] == '/') return try self.submitCommand(trimmed);
        self.applyPendingSessionResetSync() catch |err| {
            if (err == error.PendingSessionReset) {
                try self.state.appendTranscript(.@"error", "Session reset pending; wait for the current run to finish.");
                return err;
            }
            return err;
        };
        try self.ensureSessionId();
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
        self.applyPendingSessionResetSync() catch |err| {
            if (err == error.PendingSessionReset) {
                try self.state.appendTranscript(.@"error", "Session reset pending; wait for the current run to finish.");
                return err;
            }
            return err;
        };
        try self.ensureSessionId();
        if (self.session) |*session| {
            try session.steer(trimmed);
            try self.state.appendSteeredMessage(trimmed);
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

        if (command.kind == .@"resume") self.loadSessions() catch |err| {
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
                self.state.clearTools();
                self.inline_history_flushed = 0;
                self.inline_flushed_rows = 0;
                self.pending_clear_screen = true;
            },
            .open_session_picker => {
                try self.loadSessions();
                self.state.session_index = 0;
                self.state.session_scroll = 0;
                self.state.mode = .session_picker;
            },
            .open_model_picker => self.openPicker(.model),
            .open_login_picker => self.openPicker(.login),
            .open_permission_picker => self.openPicker(.permission),
            .start_login_provider => try self.startLoginProviderName(result.login_provider),
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

    fn stageClipboard(self: *App, text: []const u8) void {
        const dup = self.allocator.dupe(u8, text) catch return;
        if (self.pending_clipboard) |old| self.allocator.free(old);
        self.pending_clipboard = dup;
    }

    fn flushClipboard(self: *App, ctx: *zz.Context) void {
        const text = self.pending_clipboard orelse return;
        self.pending_clipboard = null;
        defer self.allocator.free(text);
        const copied = ctx.setClipboard(text) catch |err| {
            self.recordError(@errorName(err)) catch {};
            return;
        };
        if (!copied) self.recordError("clipboard unavailable") catch {};
    }

    fn copyLastAssistant(self: *App) void {
        const text = self.state.lastAssistantText() orelse {
            self.state.appendTranscript(.system, "nothing to copy yet") catch {};
            return;
        };
        self.stageClipboard(text);
        self.state.appendTranscript(.system, "copied last reply to clipboard") catch {};
    }

    fn cycleThinkingLevel(self: *App) void {
        const level = self.state.cycleThinkingLevel();
        if (self.runtime) |runtime| runtime.setThinkingLevel(level);
    }

    pub fn appendWelcome(self: *App) !void {
        const model = try tui_text.sanitizeTerminalText(self.allocator, if (self.state.status.model.len > 0) self.state.status.model else "no-model");
        defer self.allocator.free(model);
        const provider = try tui_text.sanitizeTerminalText(self.allocator, if (self.state.status.provider.len > 0) self.state.status.provider else "local");
        defer self.allocator.free(provider);
        const cwd = try tui_text.sanitizeTerminalText(self.allocator, if (self.working_dir.len > 0) self.working_dir else ".");
        defer self.allocator.free(cwd);
        const k = tui_theme.key;
        if (self.state.sessions.items.len == 0) {
            const welcome = try std.fmt.allocPrint(self.allocator,
                \\Makai TUI
                \\model: {s}/{s}
                \\cwd: {s}
                \\tips: {s} send {s} {s}{s} newline {s} {s}{s} thinking {s} {s}Y copy reply {s} /help commands
            , .{ provider, model, cwd, k.enter, tui_theme.glyph.dot, k.shift, k.enter, tui_theme.glyph.dot, k.shift, k.tab, tui_theme.glyph.dot, k.ctrl, tui_theme.glyph.dot });
            defer self.allocator.free(welcome);
            try self.state.appendTranscript(.welcome, welcome);
            return;
        }
        const welcome = try std.fmt.allocPrint(self.allocator,
            \\Makai TUI
            \\model: {s}/{s}
            \\cwd: {s}
            \\sessions: {d} saved {s} /resume to continue one
        , .{ provider, model, cwd, self.state.sessions.items.len, tui_theme.glyph.dot });
        defer self.allocator.free(welcome);
        try self.state.appendTranscript(.welcome, welcome);
    }

    fn syncModelTelemetry(self: *App) void {
        const runtime = self.runtime orelse return;
        const model = runtime.currentModel() orelse return;
        self.state.telemetry.input_cost_per_million = model.cost.input;
    }

    pub fn slashQuery(self: *const App) ?[]const u8 {
        const text = self.state.composer.text();
        if (text.len == 0 or text[0] != '/') return null;
        if (std.mem.indexOfAny(u8, text, " \t\n") != null) return null;
        return text[1..];
    }

    pub fn completeSlashCommand(self: *App) !bool {
        const query = self.slashQuery() orelse return false;
        for (&tui_commands.commands) |info| {
            if (!std.mem.startsWith(u8, info.name, query)) continue;
            const has_args = std.mem.indexOfScalar(u8, info.usage, ' ') != null;
            const completed = try std.fmt.allocPrint(self.allocator, "/{s}{s}", .{ info.name, if (has_args) " " else "" });
            defer self.allocator.free(completed);
            try self.state.replaceComposerBuffer(completed);
            return true;
        }
        return false;
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

fn encodeHexLower(out: []u8, bytes: []const u8) void {
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
}

pub const RenderMode = enum {
    auto,
    inline_history,
    full_transcript,
};

pub const TuiModel = struct {
    app: ?App = null,
    options: tui_runtime.TuiRuntimeOptions = .{},
    render_mode: RenderMode = .auto,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        mouse: zz.MouseEvent,
        tick: struct { timestamp: u64, delta: u64 },
        window_size: struct { width: u16, height: u16 },
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
            app.appendWelcome() catch |err| app.recordError(@errorName(err)) catch {};
            app.warnOnUnreadableCustomProviders();
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
            .key => |key| {
                if (key.modifiers.ctrl) switch (key.key) {
                    .char => |c| switch (c) {
                        'c' => return self.handleInterrupt(app, ctx),
                        'd' => {
                            if (app.state.composer.buffer.items.len == 0 and app.state.mode == .normal and !app.state.status.streaming) return self.quitCmd(app, ctx);
                            return .none;
                        },
                        'y' => {
                            app.copyLastAssistant();
                            app.flushClipboard(ctx);
                            return .none;
                        },
                        'u' => {
                            _ = app.state.composer.deleteToLineStart();
                            return .none;
                        },
                        'k' => {
                            _ = app.state.composer.deleteToLineEnd();
                            return .none;
                        },
                        'w' => {
                            _ = app.state.composer.deleteWordBeforeCursor();
                            return .none;
                        },
                        'a' => {
                            app.state.composer.moveCursorHome();
                            return .none;
                        },
                        'e' => {
                            app.state.composer.moveCursorEnd();
                            return .none;
                        },
                        else => return .none,
                    },
                    .left => {
                        app.state.composer.moveCursorWordPrev();
                        return .none;
                    },
                    .right => {
                        app.state.composer.moveCursorWordNext();
                        return .none;
                    },
                    else => {},
                };
                if (key.modifiers.alt) switch (key.key) {
                    .left => {
                        app.state.composer.moveCursorWordPrev();
                        return .none;
                    },
                    .right => {
                        app.state.composer.moveCursorWordNext();
                        return .none;
                    },
                    .backspace => {
                        _ = app.state.composer.deleteWordBeforeCursor();
                        return .none;
                    },
                    .char => |c| switch (c) {
                        'b' => {
                            app.state.composer.moveCursorWordPrev();
                            return .none;
                        },
                        'f' => {
                            app.state.composer.moveCursorWordNext();
                            return .none;
                        },
                        else => {},
                    },
                    else => {},
                };
                app.interrupt_armed_tick = null;
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
                if (app.state.mode == .picker) {
                    switch (key.key) {
                        .up => app.moveMenuSelection(-1),
                        .down => app.moveMenuSelection(1),
                        .char => |c| switch (c) {
                            'k' => app.moveMenuSelection(-1),
                            'j' => app.moveMenuSelection(1),
                            else => {},
                        },
                        .enter => switch (app.state.picker_kind) {
                            .model => app.applySelectedModel() catch |err| app.recordError(@errorName(err)) catch {},
                            .login => app.applySelectedLogin() catch |err| app.recordError(@errorName(err)) catch {},
                            .permission => app.applySelectedPermission() catch |err| app.recordError(@errorName(err)) catch {},
                        },
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
                            const command = tui_commands.parse(text) catch return .none;
                            if (command.kind != .abort) return .none;
                        }
                        var consumed = true;
                        if (app.state.mode == .approval) {
                            app.submit(text) catch |err| {
                                if (err == error.QuitRequested) return self.quitCmd(app, ctx);
                                if (err == error.QueueFull or err == error.PendingSessionReset) consumed = false;
                                if (err == error.PendingSessionReset) return .none;
                                app.state.status.setError(app.allocator, @errorName(err)) catch {};
                                if (err != error.QueueFull) app.state.appendTranscript(.@"error", @errorName(err)) catch {};
                            };
                        } else if (app.state.status.streaming) {
                            app.steer(text) catch |err| {
                                if (err == error.QuitRequested) return self.quitCmd(app, ctx);
                                if (err == error.QueueFull or err == error.PendingSessionReset) consumed = false;
                                if (err == error.PendingSessionReset) return .none;
                                app.recordError(@errorName(err)) catch {};
                            };
                        } else {
                            app.submit(text) catch |err| {
                                if (err == error.QuitRequested) return self.quitCmd(app, ctx);
                                if (err == error.QueueFull or err == error.PendingSessionReset) consumed = false;
                                if (err == error.PendingSessionReset) return .none;
                                app.state.status.setError(app.allocator, @errorName(err)) catch {};
                                if (err != error.QueueFull) app.state.appendTranscript(.@"error", @errorName(err)) catch {};
                            };
                        }
                        if (consumed) {
                            app.state.recordComposerHistory(text) catch |err| app.recordError(@errorName(err)) catch {};
                            app.state.composer.clear();
                            app.drainEvents() catch |err| {
                                app.state.status.setError(app.allocator, @errorName(err)) catch {};
                                app.state.appendTranscript(.@"error", @errorName(err)) catch {};
                            };
                        }
                    },
                    .backspace => _ = app.state.composer.deleteBeforeCursor(),
                    .delete => _ = app.state.composer.deleteAtCursor(),
                    .tab => _ = app.completeSlashCommand() catch false,
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
                    .page_up => app.state.transcript_scroll += 5,
                    .page_down => app.state.transcript_scroll -|= 5,
                    .escape => self.handleEscape(app),
                    else => {},
                }
            },
            .mouse => |mouse| handleMouse(app, mouse),
            .window_size => self.refillInlineWindowAfterResize(app, ctx) catch |err| app.recordError(@errorName(err)) catch {},
            .tick => {
                app.state.anim_tick +%= 1;
                app.drainEvents() catch {};
                app.pollLogin() catch {};
                app.state.refreshStreamingElapsed(compat.time.nowMillis());
                if (app.interrupt_armed_tick) |armed| {
                    if (app.state.anim_tick -% armed > interrupt_window_ticks) app.interrupt_armed_tick = null;
                }
            },
            .quit => return self.quitCmd(app, ctx),
        }
        if (app.pending_clear_screen) {
            app.pending_clear_screen = false;
            if (self.inlineMode(ctx)) ctx.requestClearScreen();
        }
        self.flushInlineHistory(app, ctx, false) catch |err| app.recordError(@errorName(err)) catch {};
        app.flushClipboard(ctx);
        return .none;
    }

    fn quitCmd(self: *TuiModel, app: *App, ctx: *zz.Context) zz.Cmd(Msg) {
        self.flushInlineHistory(app, ctx, true) catch {};
        return .quit;
    }

    const interrupt_window_ticks: u64 = 30;

    fn streamActive(app: *const App) bool {
        if (app.state.status.streaming) return true;
        if (app.runtime) |runtime| return runtime.stream_active;
        return false;
    }

    fn abortTurn(app: *App) void {
        app.submit("/abort") catch |err| app.recordError(@errorName(err)) catch {};
    }

    fn handleInterrupt(self: *TuiModel, app: *App, ctx: *zz.Context) zz.Cmd(Msg) {
        if (app.interrupt_armed_tick != null) return self.quitCmd(app, ctx);
        if (app.state.mode == .login_input) {
            app.cancelLogin();
            return .none;
        }
        if (app.state.mode == .approval or streamActive(app)) {
            abortTurn(app);
            app.state.composer.clear();
            app.interrupt_armed_tick = app.state.anim_tick;
            return .none;
        }
        if (app.state.mode != .normal) {
            app.state.mode = .normal;
            return .none;
        }
        if (app.state.composer.buffer.items.len > 0) {
            app.state.composer.clear();
            app.interrupt_armed_tick = app.state.anim_tick;
            return .none;
        }
        return self.quitCmd(app, ctx);
    }

    fn handleEscape(self: *TuiModel, app: *App) void {
        _ = self;
        if (app.state.composer.buffer.items.len > 0) {
            app.state.composer.clear();
            return;
        }
        if (streamActive(app)) {
            abortTurn(app);
            return;
        }
        app.state.mode = .normal;
    }

    pub fn inlineMode(self: *const TuiModel, ctx: *const zz.Context) bool {
        return switch (self.render_mode) {
            .auto => ctx._terminal != null,
            .inline_history => true,
            .full_transcript => false,
        };
    }

    pub fn view(self: *TuiModel, ctx: *const zz.Context) []const u8 {
        const app = &(self.app orelse return "Makai TUI failed to initialize");
        const width: usize = @max(ctx.width, 20);
        const height: usize = @max(ctx.height, 8);
        app.last_view_height = height;
        const chrome = self.renderChrome(app, ctx, width);
        if (self.inlineMode(ctx)) {
            const fixed = countLines(chrome.status) + countLines(chrome.composer) + countLines(chrome.extra) + 1;
            const body_budget = height -| fixed;
            const body = renderInlineBody(app, ctx, width, body_budget) catch "";
            var parts: [5][]const u8 = undefined;
            var len: usize = 0;
            if (body.len > 0) {
                parts[len] = body;
                len += 1;
            }
            parts[len] = "";
            len += 1;
            if (chrome.extra.len > 0) {
                parts[len] = chrome.extra;
                len += 1;
            }
            parts[len] = chrome.composer;
            len += 1;
            parts[len] = chrome.status;
            len += 1;
            const frame = tui_render.joinVertical(ctx.allocator, parts[0..len]) catch return chrome.composer;
            return padFrameToHeight(ctx.allocator, frame, height) catch frame;
        }

        const fixed = countLines(chrome.status) + countLines(chrome.composer) + @max(countLines(chrome.extra), 1);
        const transcript_height = if (height > fixed) height - fixed else 3;
        const transcript = transcript_view.render(ctx.allocator, &app.state, .{ .width = width, .height = transcript_height, .anim_tick = app.state.anim_tick }) catch "";
        return tui_render.joinVertical(ctx.allocator, &.{ transcript, chrome.extra, chrome.composer, chrome.status }) catch "";
    }

    const Chrome = struct {
        composer: []const u8,
        status: []const u8,
        extra: []const u8,
    };

    fn renderInlineBody(app: *App, ctx: *const zz.Context, width: usize, budget: usize) ![]const u8 {
        if (app.state.transcript_scroll > 0 and budget >= 2) {
            const stream = try renderInlineStream(ctx.allocator, &app.state, 0, 0, width, true);
            const total = countLines(stream);
            const view_rows = budget - 1;
            const max_scroll = total -| view_rows;
            const scroll = @min(app.state.transcript_scroll, max_scroll);
            app.state.transcript_scroll = scroll;
            if (scroll > 0) {
                const window = try transcript_view.lineWindow(ctx.allocator, stream, view_rows, scroll);
                const pct = transcript_view.scrollPercent(total, view_rows, scroll);
                const label = try std.fmt.allocPrint(ctx.allocator, "\u{2191} SCROLL {d}% \u{b7} PgDn to return", .{pct});
                const indicator = try tui_theme.muted().render(ctx.allocator, label);
                return tui_render.joinVertical(ctx.allocator, &.{ indicator, window });
            }
        } else {
            app.state.transcript_scroll = 0;
        }
        const stream = try renderInlineStream(ctx.allocator, &app.state, app.inline_history_flushed, app.inline_flushed_rows, width, true);
        return tailLines(ctx.allocator, stream, budget);
    }

    fn renderChrome(self: *TuiModel, app: *App, ctx: *const zz.Context, width: usize) Chrome {
        _ = self;
        const hint = if (app.interrupt_armed_tick != null)
            tui_theme.key.ctrl ++ "C again to quit"
        else
            composer_view.hintText(ctx.allocator, &app.state) catch "";
        const status = status_bar_view.render(ctx.allocator, &app.state, .{ .width = width, .hint = hint }) catch "";
        const composer = composer_view.render(ctx.allocator, &app.state, .{
            .width = width,
            .anim_tick = app.state.anim_tick,
        }) catch "";
        const extra = switch (app.state.mode) {
            .approval => approval_view.render(ctx.allocator, &app.state, .{ .width = width }) catch "",
            .session_picker => session_picker_view.render(ctx.allocator, &app.state, .{ .width = width, .height = sessionPickerHeight(app), .offset = app.state.session_scroll }) catch "",
            .picker => blk: {
                var login_items: [App.login_providers.len]menu_picker_view.Item = undefined;
                var permission_items: [App.permission_modes.len]menu_picker_view.Item = undefined;
                var title: []const u8 = "";
                var empty_message: []const u8 = "  (nothing to select)";
                const items: []const menu_picker_view.Item = switch (app.state.picker_kind) {
                    .model => model_items: {
                        const models = if (app.runtime) |runtime| runtime.availableModels() else &[_]ai_types.Model{};
                        const current = if (app.runtime) |runtime| runtime.currentModel() else null;
                        const list = ctx.allocator.alloc(menu_picker_view.Item, models.len) catch break :blk "";
                        for (models, 0..) |model, i| {
                            const is_current = if (current) |active| std.mem.eql(u8, active.id, model.id) else false;
                            list[i] = .{ .label = model.id, .detail = model.provider, .badge = if (is_current) tui_theme.glyph.system ++ " current" else null };
                        }
                        title = "Select model";
                        empty_message = "  no models available";
                        break :model_items list;
                    },
                    .login => login_items_blk: {
                        for (App.login_providers, 0..) |provider, i| login_items[i] = .{ .label = provider, .badge = App.loginBadge(app.login_status[i]) };
                        title = "Login provider";
                        break :login_items_blk &login_items;
                    },
                    .permission => permission_items_blk: {
                        for (App.permission_modes, 0..) |mode, i| {
                            permission_items[i] = .{ .label = @tagName(mode), .detail = permissionModeDetail(mode) };
                        }
                        title = "Tool permissions";
                        break :permission_items_blk &permission_items;
                    },
                };
                break :blk menu_picker_view.render(ctx.allocator, .{
                    .title = title,
                    .items = items,
                    .selected = app.state.menu_index,
                    .width = width,
                    .height = sessionPickerHeight(app),
                    .offset = app.state.menu_scroll,
                    .empty_message = empty_message,
                }) catch "";
            },
            .login_input => "",
            .normal => renderCommandPalette(ctx.allocator, app, width) catch "",
        };
        return .{ .composer = composer, .status = status, .extra = extra };
    }

    fn flushBudget(self: *TuiModel, app: *App, ctx: *const zz.Context) usize {
        const width: usize = @max(ctx.width, 20);
        const height: usize = @max(ctx.height, 8);
        const chrome = self.renderChrome(app, ctx, width);
        return height -| (countLines(chrome.status) + countLines(chrome.composer) + 1);
    }

    fn renderCommandPalette(allocator: std.mem.Allocator, app: *const App, width: usize) ![]const u8 {
        const query = app.slashQuery() orelse return "";
        var items: [tui_commands.commands.len]menu_picker_view.Item = undefined;
        var len: usize = 0;
        for (&tui_commands.commands) |info| {
            if (!std.mem.startsWith(u8, info.name, query)) continue;
            items[len] = .{ .label = info.usage, .detail = info.description };
            len += 1;
        }
        if (len == 0) return "";
        return menu_picker_view.render(allocator, .{
            .title = "Commands",
            .items = items[0..len],
            .selected = 0,
            .width = width,
            .height = 8,
            .footer = tui_theme.key.tab ++ " complete " ++ tui_theme.glyph.dot ++ " " ++ tui_theme.key.enter ++ " run",
        });
    }

    fn renderInlineBlock(allocator: std.mem.Allocator, state: *const tui_state.AppState, index: usize, width: usize, live: bool) ![]u8 {
        const entries = state.transcript.items;
        const entry = &entries[index];
        const detached = index == 0 or !transcript_view.entriesAttached(&entries[index - 1], entry);
        const awaiting = live and state.mode == .approval and entry.kind == .tool and entry.tool_call_id.len > 0 and std.mem.eql(u8, entry.tool_call_id, state.approval.tool_call_id);
        const rendered = try transcript_view.renderTranscriptEntryWith(allocator, entry, width, .{ .live = live and isLiveEntry(state, index), .anim_tick = state.anim_tick, .awaiting_approval = awaiting });
        defer allocator.free(rendered);
        if (!detached) return allocator.dupe(u8, rendered);
        return std.mem.concat(allocator, u8, &.{ "\n", rendered });
    }

    fn renderInlineStream(allocator: std.mem.Allocator, state: *const tui_state.AppState, from: usize, skip_rows: usize, width: usize, live: bool) ![]const u8 {
        const entries = state.transcript.items;
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const writer = &out.writer;
        var first = true;
        var i = @min(from, entries.len);
        while (i < entries.len) : (i += 1) {
            if (!first) try writer.writeAll("\n");
            first = false;
            const block = try renderInlineBlock(allocator, state, i, width, live);
            defer allocator.free(block);
            try writer.writeAll(block);
        }
        if (live and state.status.streaming and state.active_assistant_entry == null and state.active_tool_summary_entry == null and state.mode != .approval) {
            if (!first) try writer.writeAll("\n");
            try writer.writeAll("\n");
            const waiting = try transcript_view.renderWaitingLine(allocator, state.status.model, state.anim_tick, state.status.streaming_elapsed_ms);
            defer allocator.free(waiting);
            try writer.writeAll(waiting);
        }
        return dropLines(allocator, out.written(), skip_rows);
    }

    fn dropLines(allocator: std.mem.Allocator, text: []const u8, count: usize) ![]const u8 {
        var start: usize = 0;
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            const newline = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return allocator.dupe(u8, "");
            start = newline + 1;
        }
        return allocator.dupe(u8, text[start..]);
    }

    fn isLiveEntry(state: *const tui_state.AppState, index: usize) bool {
        if (state.active_assistant_entry) |idx| if (idx == index) return true;
        if (state.active_thinking_entry) |idx| if (idx == index) return true;
        if (state.active_tool_summary_entry) |idx| if (idx == index) return true;
        return false;
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

    fn appendChar(app: *App, c: u21) !void {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(c, &buf);
        try app.state.composer.insertSlice(app.allocator, buf[0..len]);
    }

    fn flushInlineHistory(self: *TuiModel, app: *App, ctx: *zz.Context, include_active: bool) !void {
        if (!self.inlineMode(ctx)) return;
        const entries = app.state.transcript.items;
        if (app.inline_history_flushed >= entries.len) return;
        app.state.advanceSummaryScanFloor();

        const width: usize = @max(ctx.width, 20);
        const stop = if (include_active) entries.len else inlineFlushStop(app);
        var overflow: usize = std.math.maxInt(usize);
        if (!include_active) {
            const stream = try renderInlineStream(ctx.allocator, &app.state, app.inline_history_flushed, app.inline_flushed_rows, width, true);
            defer ctx.allocator.free(stream);
            overflow = countLines(stream) -| self.flushBudget(app, ctx);
        }
        while (overflow > 0 and app.inline_history_flushed < stop) {
            const block = try renderInlineBlock(ctx.allocator, &app.state, app.inline_history_flushed, width, false);
            defer ctx.allocator.free(block);
            const block_rows = countLines(block);
            const offset = app.inline_flushed_rows;
            const take = @min(block_rows -| offset, overflow);
            if (take == 0) break;
            try printAboveRows(ctx, block, offset, take);
            overflow -= take;
            if (offset + take >= block_rows) {
                app.inline_history_flushed += 1;
                app.inline_flushed_rows = 0;
            } else {
                app.inline_flushed_rows = offset + take;
            }
        }
    }

    fn printAboveRows(ctx: *zz.Context, text: []const u8, skip: usize, count: usize) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var index: usize = 0;
        var printed: usize = 0;
        while (lines.next()) |line| : (index += 1) {
            if (index < skip) continue;
            if (printed >= count) break;
            try ctx.printAbove(line);
            printed += 1;
        }
    }

    fn refillInlineWindowAfterResize(self: *TuiModel, app: *App, ctx: *zz.Context) !void {
        app.state.transcript_scroll = 0;
        if (!self.inlineMode(ctx)) return;
        const width: usize = @max(ctx.width, 20);
        const budget = self.flushBudget(app, ctx);
        const entries = app.state.transcript.items;
        var start = @min(app.inline_history_flushed, entries.len);
        const visible = try renderInlineStream(ctx.allocator, &app.state, start, app.inline_flushed_rows, width, true);
        defer ctx.allocator.free(visible);
        var rows = countLines(visible);
        if (rows >= budget) return;
        rows += app.inline_flushed_rows;
        while (start > 0 and rows < budget) {
            start -= 1;
            const block = try renderInlineBlock(ctx.allocator, &app.state, start, width, false);
            defer ctx.allocator.free(block);
            rows += countLines(block);
        }
        app.inline_history_flushed = start;
        app.inline_flushed_rows = rows -| budget;
    }

    fn inlineFlushStop(app: *const App) usize {
        var stop = app.state.transcript.items.len;
        if (app.state.active_user_entry) |idx| stop = @min(stop, idx);
        if (app.state.active_assistant_entry) |idx| stop = @min(stop, idx);
        if (app.state.active_thinking_entry) |idx| stop = @min(stop, idx);
        if (app.state.active_tool_result_entry) |idx| stop = @min(stop, idx);
        if (app.state.active_tool_summary_entry) |idx| stop = @min(stop, idx);
        return @min(stop, app.state.summary_scan_floor);
    }

    fn handleMouse(app: *App, mouse: zz.MouseEvent) void {
        if (mouse.event_type != .press) return;
        switch (mouse.button) {
            .wheel_up => {
                app.state.transcript_scroll += 3;
            },
            .wheel_down => {
                app.state.transcript_scroll -|= 3;
            },
            else => {},
        }
    }

    fn permissionModeDetail(mode: tui_runtime.PermissionMode) []const u8 {
        return switch (mode) {
            .bypass => "run tools without prompts",
            .ask => "ask before tool execution",
        };
    }

    fn padFrameToHeight(allocator: std.mem.Allocator, frame: []const u8, height: usize) ![]const u8 {
        const rows = countLines(frame);
        if (rows >= height) return frame;
        const pad = height - rows;
        const out = try allocator.alloc(u8, pad + frame.len);
        @memset(out[0..pad], '\n');
        @memcpy(out[pad..], frame);
        return out;
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
        if (app.state.sessions.items.len == 0) {
            app.state.session_index = 0;
            app.state.session_scroll = 0;
            return;
        }
        if (app.state.session_index >= app.state.sessions.items.len) app.state.session_index = app.state.sessions.items.len - 1;
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
        .base_url = "https://api.anthropic.com",
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

    var stderr_redirect = redirectStderrToLog(allocator, &environ_map);
    defer stderr_redirect.restore();
    if (stderr_redirect.active()) std.debug.print("--- makai --tui session started at {d} ms (stderr redirected here while the TUI owns the terminal) ---\n", .{compat.time.nowMillis()});

    const fixture = try FixtureRuntime.fromEnv(allocator, &environ_map);
    defer if (fixture) |runtime| runtime.deinit();

    var production = try ProductionRuntime.init(allocator, .{ .fixture = fixture != null });
    defer production.deinit();
    production.initBridge();

    var options = production.options();
    if (fixture) |runtime| options.protocol = runtime.provider.protocolClient();

    var program = zz.Program(TuiModel).initWithOptions(allocator, io, &environ_map, tuiProgramOptions());
    program.model = .{ .options = options };
    defer program.deinit();
    try program.run();
}

const StderrRedirect = struct {
    saved_fd: ?std.posix.fd_t = null,
    log_fd: ?std.posix.fd_t = null,

    fn active(self: *const StderrRedirect) bool {
        return self.log_fd != null;
    }

    fn restore(self: *StderrRedirect) void {
        if (comptime @import("builtin").os.tag == .windows) return;
        if (self.saved_fd) |saved| {
            _ = std.c.dup2(saved, std.posix.STDERR_FILENO);
            _ = std.c.close(saved);
        }
        if (self.log_fd) |fd| _ = std.c.close(fd);
        self.* = .{};
    }
};

pub fn stderrLogPath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ home, ".makai", "tui-stderr.log" });
}

fn redirectStderrToLog(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) StderrRedirect {
    var redirect: StderrRedirect = .{};
    if (comptime @import("builtin").os.tag == .windows) return redirect;
    const fd = openStderrLog(allocator, environ_map) catch openDevNull() catch return redirect;
    const saved = std.c.dup(std.posix.STDERR_FILENO);
    if (saved < 0) {
        _ = std.c.close(fd);
        return redirect;
    }
    if (std.c.dup2(fd, std.posix.STDERR_FILENO) < 0) {
        _ = std.c.close(saved);
        _ = std.c.close(fd);
        return redirect;
    }
    redirect.saved_fd = saved;
    redirect.log_fd = fd;
    return redirect;
}

fn openStderrLog(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !std.posix.fd_t {
    const home = environ_map.get("HOME") orelse return error.HomeNotFound;
    if (home.len == 0) return error.HomeNotFound;
    const dir = try std.fs.path.join(allocator, &.{ home, ".makai" });
    defer allocator.free(dir);
    try compat.fs.createDir(compat.fs.getCwd(), dir);
    const path = try stderrLogPath(allocator, home);
    defer allocator.free(path);
    return std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600);
}

fn openDevNull() !std.posix.fd_t {
    return std.posix.openat(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
}

test "stderr log path lives under the makai home directory" {
    const path = try stderrLogPath(std.testing.allocator, "/tmp/home");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/home/.makai/tui-stderr.log", path);
}

fn tuiProgramOptions() zz.Options {
    return .{ .kitty_keyboard = true, .mouse = false, .alternate_scroll = false, .alt_screen = false, .inline_bottom_viewport = true, .cursor = false, .ctrl_c_quits = false };
}

pub fn tuiProgramOptionsForTest() zz.Options {
    if (!@import("builtin").is_test) @compileError("test-only helper");
    return tuiProgramOptions();
}

const TestContext = struct {
    arena: std.heap.ArenaAllocator,
    env: zz.Environment,
    ctx: zz.Context,

    fn setup(self: *TestContext) void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.env = .{};
        self.ctx = zz.Context.init(self.arena.allocator(), std.testing.allocator, std.testing.io, &self.env);
    }

    fn deinit(self: *TestContext) void {
        self.ctx.deinit();
        self.arena.deinit();
    }
};

test "App init seeds registered tools from runtime" {
    var production = try ProductionRuntime.init(std.testing.allocator, .{});
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

const TempHome = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    previous: ?[]u8,

    fn init(sub: []const u8) !TempHome {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, sub });
        errdefer std.testing.allocator.free(home);
        try compat.fs.createDir(compat.fs.getCwd(), home);
        const previous = std.process.Environ.getAlloc(std.testing.environ, std.testing.allocator, "HOME") catch null;
        const home_z = try std.testing.allocator.dupeZ(u8, home);
        defer std.testing.allocator.free(home_z);
        _ = setenv("HOME", home_z.ptr, 1);
        return .{ .tmp = tmp, .home = home, .previous = previous };
    }

    fn deinit(self: *TempHome) void {
        if (self.previous) |value| {
            if (std.testing.allocator.dupeZ(u8, value) catch null) |home_z| {
                defer std.testing.allocator.free(home_z);
                _ = setenv("HOME", home_z.ptr, 1);
            }
            std.testing.allocator.free(value);
        } else {
            _ = unsetenv("HOME");
        }
        std.testing.allocator.free(self.home);
        self.tmp.cleanup();
    }
};

test "App stores a custom provider key under its own id" {
    var env = try TempHome.init("home-custom-key");
    defer env.deinit();

    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    const creds = oauth_storage.Credentials{
        .refresh = try std.testing.allocator.dupe(u8, ""),
        .access = try std.testing.allocator.dupe(u8, "gateway-secret"),
        .expires = std.math.maxInt(i64),
    };
    defer creds.deinit(std.testing.allocator);

    try app.saveLoginCredentials("gateway", creds, true);

    var storage = try oauth_storage.AuthStorage.loadFromFile(std.testing.allocator);
    defer storage.deinit();
    const auth = storage.providers.get("gateway") orelse return error.MissingCustomAuth;
    switch (auth) {
        .api_key => |key| try std.testing.expectEqualStrings("gateway-secret", key),
        else => return error.UnexpectedAuthKind,
    }
}

test "App only offers an api-key login for a declared custom provider" {
    var env = try TempHome.init("home-custom-login");
    defer env.deinit();

    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    try std.testing.expect(!app.isDeclaredCustomProvider("gateway"));

    const makai_dir = try std.fs.path.join(std.testing.allocator, &.{ env.home, ".makai" });
    defer std.testing.allocator.free(makai_dir);
    try compat.fs.createDir(compat.fs.getCwd(), makai_dir);
    const config_path = try std.fs.path.join(std.testing.allocator, &.{ makai_dir, "providers.json" });
    defer std.testing.allocator.free(config_path);
    try compat.fs.writeFile(compat.fs.getCwd(), config_path,
        \\{"providers":[{"id":"gateway","base_url":"https://gw.test"}]}
    );

    try std.testing.expect(app.isDeclaredCustomProvider("gateway"));
    try std.testing.expect(!app.isDeclaredCustomProvider("not-declared"));
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

test "TUI program routes Ctrl+C to the model and hides the terminal cursor" {
    try std.testing.expect(!tuiProgramOptions().ctrl_c_quits);
    try std.testing.expect(!tuiProgramOptions().cursor);
}

test "TuiModel Ctrl+C clears a draft first and quits on the second press" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    try model.app.?.state.replaceComposerBuffer("draft");

    const first = model.update(.{ .key = .{ .key = .{ .char = 'c' }, .modifiers = .{ .ctrl = true } } }, &tctx.ctx);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, first);
    try std.testing.expectEqualStrings("", model.app.?.state.composer.text());
    try std.testing.expect(model.app.?.interrupt_armed_tick != null);

    const second = model.update(.{ .key = .{ .key = .{ .char = 'c' }, .modifiers = .{ .ctrl = true } } }, &tctx.ctx);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).quit, second);
}

test "TuiModel Ctrl+C quits immediately on an empty idle composer" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();

    const cmd = model.update(.{ .key = .{ .key = .{ .char = 'c' }, .modifiers = .{ .ctrl = true } } }, &tctx.ctx);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).quit, cmd);
}

test "TuiModel window resize refills the inline window with the history tail" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator), .render_mode = .inline_history };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    tctx.ctx.width = 60;
    tctx.ctx.height = 14;
    for (0..12) |i| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "history entry {d}", .{i});
        defer std.testing.allocator.free(text);
        try model.app.?.state.appendTranscript(.assistant, text);
    }
    model.app.?.inline_history_flushed = model.app.?.state.transcript.items.len;

    _ = model.update(.{ .window_size = .{ .width = 60, .height = 14 } }, &tctx.ctx);
    try std.testing.expect(!tctx.ctx.hasPendingAbove());
    const frame = model.view(&tctx.ctx);
    try std.testing.expectEqual(@as(usize, 14), TuiModel.countLines(frame));
    try std.testing.expect(std.mem.indexOf(u8, frame, "history entry 11") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "history entry 0") == null);
    var lines = std.mem.splitScalar(u8, frame, '\n');
    while (lines.next()) |line| try std.testing.expect(tui_text.visibleWidth(line) <= 60);
}

test "TuiModel inline flush keeps scrollback and window contiguous" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator), .render_mode = .inline_history };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    tctx.ctx.width = 60;
    tctx.ctx.height = 14;
    for (0..12) |i| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "history entry {d}", .{i});
        defer std.testing.allocator.free(text);
        try model.app.?.state.appendTranscript(.assistant, text);
    }

    _ = model.update(.{ .tick = .{ .timestamp = 0, .delta = 0 } }, &tctx.ctx);
    const above = try tctx.ctx.takeAbove(std.testing.allocator);
    defer std.testing.allocator.free(above);
    const frame = model.view(&tctx.ctx);
    try std.testing.expectEqual(@as(usize, 14), TuiModel.countLines(frame));
    try std.testing.expect(std.mem.indexOf(u8, above, "history entry 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "history entry 11") != null);
    try std.testing.expect(model.app.?.inline_flushed_rows > 0 or model.app.?.inline_history_flushed > 0);

    const stream = try TuiModel.renderInlineStream(std.testing.allocator, &model.app.?.state, 0, 0, 60, true);
    defer std.testing.allocator.free(stream);
    const joined = try std.mem.concat(std.testing.allocator, u8, &.{ above, frame });
    defer std.testing.allocator.free(joined);
    var expected = std.mem.splitScalar(u8, stream, '\n');
    var actual = std.mem.splitScalar(u8, joined, '\n');
    while (expected.next()) |row| {
        const got = actual.next() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(std.mem.trimEnd(u8, row, " "), std.mem.trimEnd(u8, got, " "));
    }
    try std.testing.expectEqualStrings("", std.mem.trimEnd(u8, actual.next() orelse return error.TestUnexpectedResult, " "));
}

test "App inline flush stop follows the reconciliation floor" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var resolution = try app.state.resolveToolOccurrenceForTest("call-h", "shell_execute", "{\"command\":\"pwd\"}", .live_intent, .running);
    try app.state.appendToolSummaryTranscript("running now", resolution.tool.id);
    try app.state.appendTranscript(.assistant, "later text");
    app.state.advanceSummaryScanFloor();
    try std.testing.expectEqual(@as(usize, 0), TuiModel.inlineFlushStop(&app));

    resolution.tool.terminal_evidence = .both;
    app.state.advanceSummaryScanFloor();
    try std.testing.expectEqual(@as(usize, 2), TuiModel.inlineFlushStop(&app));
}

test "TuiModel inline frame fills the viewport when there is nothing to show yet" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator), .render_mode = .inline_history };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    tctx.ctx.width = 60;
    tctx.ctx.height = 20;

    _ = model.update(.{ .tick = .{ .timestamp = 0, .delta = 0 } }, &tctx.ctx);
    const empty = model.view(&tctx.ctx);
    try std.testing.expectEqual(@as(usize, 20), TuiModel.countLines(empty));

    try model.app.?.state.replaceComposerBuffer("/m");
    _ = model.update(.{ .tick = .{ .timestamp = 0, .delta = 0 } }, &tctx.ctx);
    const with_palette = model.view(&tctx.ctx);
    try std.testing.expectEqual(@as(usize, 20), TuiModel.countLines(with_palette));
    try std.testing.expect(std.mem.indexOf(u8, with_palette, "/model") != null);

    var rows = std.mem.splitScalar(u8, with_palette, '\n');
    var last: []const u8 = "";
    while (rows.next()) |row| last = row;
    try std.testing.expect(last.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, with_palette, "\n"));
}

test "TuiModel inline frame keeps the composer on the bottom row across a picker" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator), .render_mode = .inline_history };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    tctx.ctx.width = 60;
    tctx.ctx.height = 16;
    for (0..12) |i| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "history entry {d}", .{i});
        defer std.testing.allocator.free(text);
        try model.app.?.state.appendTranscript(.assistant, text);
    }
    _ = model.update(.{ .tick = .{ .timestamp = 0, .delta = 0 } }, &tctx.ctx);
    tctx.ctx.above_buffer.clearRetainingCapacity();
    const before = try std.testing.allocator.dupe(u8, model.view(&tctx.ctx));
    defer std.testing.allocator.free(before);
    try std.testing.expectEqual(@as(usize, 16), TuiModel.countLines(before));

    model.app.?.state.mode = .picker;
    model.app.?.state.picker_kind = .model;
    _ = model.update(.{ .tick = .{ .timestamp = 0, .delta = 0 } }, &tctx.ctx);
    const during = model.view(&tctx.ctx);
    try std.testing.expectEqual(@as(usize, 16), TuiModel.countLines(during));
    try std.testing.expect(std.mem.indexOf(u8, during, "Select model") != null);
    try std.testing.expect(std.mem.indexOf(u8, during, "history entry 11") != null);
    try std.testing.expect(!tctx.ctx.hasPendingAbove());

    model.app.?.state.mode = .normal;
    _ = model.update(.{ .tick = .{ .timestamp = 0, .delta = 0 } }, &tctx.ctx);
    try std.testing.expect(!tctx.ctx.hasPendingAbove());
    try std.testing.expectEqualStrings(before, model.view(&tctx.ctx));
}

test "TuiModel Escape clears the draft before anything else" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    try model.app.?.state.replaceComposerBuffer("draft");

    _ = model.update(.{ .key = .{ .key = .escape } }, &tctx.ctx);
    try std.testing.expectEqualStrings("", model.app.?.state.composer.text());
    try std.testing.expectEqual(tui_state.AppMode.normal, model.app.?.state.mode);
}

test "TuiModel Tab completes the first matching slash command" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    try model.app.?.state.replaceComposerBuffer("/perm");

    _ = model.update(.{ .key = .{ .key = .tab } }, &tctx.ctx);
    try std.testing.expectEqualStrings("/permissions ", model.app.?.state.composer.text());
    try std.testing.expect(model.app.?.slashQuery() == null);
}

test "TuiModel word editing shortcuts edit the composer" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    try model.app.?.state.replaceComposerBuffer("alpha beta gamma");

    _ = model.update(.{ .key = .{ .key = .{ .char = 'w' }, .modifiers = .{ .ctrl = true } } }, &tctx.ctx);
    try std.testing.expectEqualStrings("alpha beta ", model.app.?.state.composer.text());
    _ = model.update(.{ .key = .{ .key = .left, .modifiers = .{ .alt = true } } }, &tctx.ctx);
    try std.testing.expectEqual(@as(usize, 6), model.app.?.state.composer.cursor);
    _ = model.update(.{ .key = .{ .key = .{ .char = 'u' }, .modifiers = .{ .ctrl = true } } }, &tctx.ctx);
    try std.testing.expectEqualStrings("beta ", model.app.?.state.composer.text());
    _ = model.update(.{ .key = .{ .key = .{ .char = 'k' }, .modifiers = .{ .ctrl = true } } }, &tctx.ctx);
    try std.testing.expectEqualStrings("", model.app.?.state.composer.text());
}

test "fixture runtime stays inactive without a non-empty env value" {
    try std.testing.expectEqual(@as(?*FixtureRuntime, null), try FixtureRuntime.fromValue(std.testing.allocator, null));
    try std.testing.expectEqual(@as(?*FixtureRuntime, null), try FixtureRuntime.fromValue(std.testing.allocator, ""));
}

test "fixture runtime streams the env-provided text" {
    var env = try compat.createEnvMap(std.testing.allocator);
    defer env.deinit();
    try env.put(fixture_env_var, "pty fixture reply");
    const fixture = (try FixtureRuntime.fromEnv(std.testing.allocator, &env)).?;
    defer fixture.deinit();

    const client = fixture.provider.protocolClient();
    const stream_ptr = try client.stream(fixture_provider.test_model, .{ .messages = &.{}, .is_owned = false }, .{}, std.testing.allocator);
    defer {
        stream_ptr.deinit();
        std.testing.allocator.destroy(stream_ptr);
    }

    var saw_delta = false;
    while (stream_ptr.wait()) |event| {
        var ev = event;
        defer switch (ev) {
            .done => |*payload| payload.message.deinit(std.testing.allocator),
            .@"error" => |*payload| payload.err.deinit(std.testing.allocator),
            else => {},
        };
        if (ev == .text_delta) saw_delta = std.mem.eql(u8, ev.text_delta.delta, "pty fixture reply");
    }
    try std.testing.expect(saw_delta);
    try std.testing.expectEqual(@as(usize, 1), fixture.provider.call_count);
}

test "fixture runtime parses scenario steps" {
    const fixture = (try FixtureRuntime.fromValue(std.testing.allocator, "text:one|tool:workspace_info|hold|error:boom|text:two")).?;
    defer fixture.deinit();

    try std.testing.expectEqual(@as(usize, 5), fixture.steps.items.len);
    try std.testing.expectEqualStrings("one", fixture.steps.items[0].text);
    try std.testing.expectEqualStrings("workspace_info", fixture.steps.items[1].tool_calls[0].name);
    try std.testing.expectEqualStrings("{}", fixture.steps.items[1].tool_calls[0].arguments_json);
    try std.testing.expect(fixture.steps.items[2] == .wait_for_cancel);
    try std.testing.expectEqualStrings("boom", fixture.steps.items[3].provider_error);
    try std.testing.expectEqualStrings("two", fixture.steps.items[4].text);
}

test "fixture runtime parses tool args after the hash" {
    const fixture = (try FixtureRuntime.fromValue(std.testing.allocator, "tool:workspace_info#{\"workspace_root\":\"/tmp\"}")).?;
    defer fixture.deinit();

    try std.testing.expectEqualStrings("workspace_info", fixture.steps.items[0].tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"workspace_root\":\"/tmp\"}", fixture.steps.items[0].tool_calls[0].arguments_json);
}

test "fixture runtime keeps pipe-less text that is not a step" {
    const fixture = (try FixtureRuntime.fromValue(std.testing.allocator, "plain|reply|text")).?;
    defer fixture.deinit();

    try std.testing.expectEqual(@as(usize, 1), fixture.steps.items.len);
    try std.testing.expectEqualStrings("plain|reply|text", fixture.steps.items[0].text);
}

test "fixture runtime unescapes separators inside step payloads" {
    const fixture = (try FixtureRuntime.fromValue(std.testing.allocator, "text:pipe\\|inside|tool:shell_execute#{\"command\":\"printf a \\| cat\"}|text:done")).?;
    defer fixture.deinit();

    try std.testing.expectEqual(@as(usize, 3), fixture.steps.items.len);
    try std.testing.expectEqualStrings("pipe|inside", fixture.steps.items[0].text);
    try std.testing.expectEqualStrings("shell_execute", fixture.steps.items[1].tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"printf a | cat\"}", fixture.steps.items[1].tool_calls[0].arguments_json);
    try std.testing.expectEqualStrings("done", fixture.steps.items[2].text);
}

test "fixture runtime unescapes backslashes and keeps lone ones literal" {
    const fixture = (try FixtureRuntime.fromValue(std.testing.allocator, "text:c:\\\\path\\\\\\|end")).?;
    defer fixture.deinit();

    try std.testing.expectEqualStrings("c:\\path\\|end", fixture.steps.items[0].text);
}

test "fixture runtime rejects unknown step after a scenario prefix" {
    try std.testing.expectError(error.UnknownFixtureStepPrefix, FixtureRuntime.fromValue(std.testing.allocator, "text:one|wat"));
    try std.testing.expectError(error.EmptyFixtureStep, FixtureRuntime.fromValue(std.testing.allocator, "text:"));
    try std.testing.expectError(error.EmptyFixtureStep, FixtureRuntime.fromValue(std.testing.allocator, "text:one|"));
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

    var start = tui_runtime.TuiEvent{ .tool_execution_start = .{
        .tool_call_id = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "call-1")),
        .tool_name = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "shell_execute")),
        .args_json = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "{\"command\":\"pwd\"}")),
    } };
    defer start.deinit(std.testing.allocator);
    app.saveEvent(start);

    var loaded = try app.store.?.load("save-debug-events");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), loaded.events.items.len);
    try std.testing.expect(loaded.events.items[0] == .thinking_delta);
    try std.testing.expect(loaded.events.items[1] == .tool_approval_requested);
    try std.testing.expect(loaded.events.items[2] == .tool_execution_update);
    try std.testing.expect(loaded.events.items[3] == .provider_event);
    try std.testing.expectEqualStrings("{\"type\":\"done\"}", loaded.events.items[3].provider_event.event_json.slice());
    try std.testing.expect(loaded.events.items[4] == .@"error");
    try std.testing.expect(loaded.events.items[5] == .tool_execution_start);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", loaded.events.items[5].tool_execution_start.args_json.slice());
}

test "App clear_transcript clears the tool registry" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    _ = try app.state.resolveToolOccurrenceForTest("call-1", "shell_execute", "{\"command\":\"pwd\"}", .live_intent, .done);
    try app.state.appendToolSummaryTranscript("◈ shell_execute \"pwd\" ok", "call-1");

    try app.submit("/clear");

    try std.testing.expectEqual(@as(usize, 0), app.state.tools.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.state.transcript.items.len);
    try std.testing.expectEqual(tui_state.TranscriptKind.system, app.state.transcript.items[0].kind);
    try std.testing.expectEqual(@as(usize, 0), app.inline_history_flushed);
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

    try app.saveLoginCredentials("kimi", creds, true);

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

    const expect = [_][]const u8{
        "/help",   "/model", "/provider",    "/status",
        "/resume", "/login", "/permissions", "/abort",
        "/clear",  "/quit",
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
    const runtime = try std.testing.allocator.create(tui_runtime.TuiRuntime);
    errdefer std.testing.allocator.destroy(runtime);
    runtime.* = try tui_runtime.TuiRuntime.init(std.testing.allocator, .{});
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    app.runtime = runtime;
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
    try std.testing.expectEqual(tui_state.TranscriptKind.welcome, app.state.transcript.items[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "Makai TUI") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "tips:") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "Alt+Enter") == null);

    app.state.clearTranscript();
    try app.state.addSession("s1", "saved");
    try app.appendWelcome();
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "tips:") == null);
    try std.testing.expect(std.mem.indexOf(u8, app.state.transcript.items[0].text.items, "/resume") != null);
}

const MockAppSession = struct {
    steer_count: usize = 0,
    submit_count: usize = 0,
    resume_count: usize = 0,
    cancel_count: usize = 0,
    clear_count: usize = 0,
    queued_counts: tui_runtime.QueuedCounts = .{},
    steers_consumed: u64 = 0,
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
                .clear_queued_messages = clearQueuedMessages,
                .queued_counts = queuedCounts,
                .steers_consumed = steersConsumed,
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
        _ = text;
        const self = ptr(ctx);
        self.submit_count += 1;
    }

    fn steer(ctx: ?*anyopaque, text: []const u8) anyerror!void {
        _ = text;
        const self = ptr(ctx);
        self.steer_count += 1;
        if (self.queued_counts.total() == 0) self.queued_counts.steering += 1;
    }

    fn clearQueuedMessages(ctx: ?*anyopaque) void {
        const self = ptr(ctx);
        self.clear_count += 1;
        self.queued_counts = .{};
    }

    fn queuedCounts(ctx: ?*anyopaque) tui_runtime.QueuedCounts {
        return ptr(ctx).queued_counts;
    }

    fn steersConsumed(ctx: ?*anyopaque) u64 {
        return ptr(ctx).steers_consumed;
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

test "App steer handles fallback empty and session paths" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();

    try app.steer("  steer fallback  ");
    try std.testing.expectEqual(@as(usize, 1), app.state.transcript.items.len);
    try std.testing.expectEqualStrings("steer fallback", app.state.transcript.items[0].text.items);

    try app.steer("   ");
    try std.testing.expectEqual(@as(usize, 1), app.state.transcript.items.len);

    app.state.clearTranscript();
    var mock = MockAppSession{ .queued_counts = .{ .steering = 1 } };
    app.session = mock.session();

    try app.steer(" steer me ");
    try std.testing.expectEqual(@as(usize, 1), mock.steer_count);
    try std.testing.expectEqual(@as(usize, 1), app.state.transcript.items.len);
    try std.testing.expectEqual(tui_state.TranscriptKind.user, app.state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("steer me", app.state.transcript.items[0].text.items);
    try std.testing.expectEqual(@as(usize, 1), app.state.pending_steers.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.state.queue.steering);
}

test "TuiModel exits quit command while streaming" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    model.app.?.state.status.streaming = true;
    try model.app.?.state.replaceComposerBuffer("/quit");

    const cmd = model.update(.{ .key = .{ .key = .enter } }, &tctx.ctx);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).quit, cmd);
}

test "TuiModel Shift Enter inserts newline without submitting" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    try model.app.?.state.replaceComposerBuffer("first");

    const cmd = model.update(.{ .key = .{ .key = .enter, .modifiers = .{ .shift = true } } }, &tctx.ctx);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, cmd);
    try std.testing.expectEqualStrings("first\n", model.app.?.state.composer.text());
    try std.testing.expectEqual(@as(usize, 0), model.app.?.state.transcript.items.len);
}

test "TuiModel Shift Tab cycles thinking level" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();

    try std.testing.expectEqual(ai_types.ThinkingLevel.low, model.app.?.state.thinking_level);
    const cmd = model.update(.{ .key = .{ .key = .tab, .modifiers = .{ .shift = true } } }, &tctx.ctx);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, cmd);
    try std.testing.expectEqual(ai_types.ThinkingLevel.medium, model.app.?.state.thinking_level);
}

test "App drain quarantines late events until the next turn starts" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    app.session = mock.session();
    app.session_id = try std.testing.allocator.dupe(u8, "deleted");
    app.quarantine_events = true;
    app.quarantine_generation = 1;

    try mock.eventStream().push(.{ .text_delta = .{
        .generation = 1,
        .content_index = 0,
        .delta = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "stale")),
    } });
    try app.drainEvents();
    try std.testing.expectEqual(@as(usize, 0), app.state.transcript.items.len);

    try mock.eventStream().push(.{ .agent_start = .{ .generation = 2 } });
    try mock.eventStream().push(.{ .text_delta = .{
        .generation = 2,
        .content_index = 0,
        .delta = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "fresh")),
    } });
    try app.drainEvents();
    var found_fresh = false;
    var found_stale = false;
    for (app.state.transcript.items) |entry| {
        if (std.mem.eql(u8, entry.text.items, "fresh")) found_fresh = true;
        if (std.mem.eql(u8, entry.text.items, "stale")) found_stale = true;
    }
    try std.testing.expect(found_fresh);
    try std.testing.expect(!found_stale);
    try std.testing.expect(!app.quarantine_events);
}

test "App drain exits quarantine on turn_start for remote-style streams" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    app.session = mock.session();
    app.session_id = try std.testing.allocator.dupe(u8, "deleted");
    app.quarantine_events = true;
    app.quarantine_generation = 1;

    try mock.eventStream().push(.{ .text_delta = .{
        .generation = 1,
        .content_index = 0,
        .delta = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "stale")),
    } });
    try app.drainEvents();
    try std.testing.expectEqual(@as(usize, 0), app.state.transcript.items.len);

    try mock.eventStream().push(.{ .turn_start = .{ .generation = 2 } });
    try mock.eventStream().push(.{ .text_delta = .{
        .generation = 2,
        .content_index = 0,
        .delta = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "fresh")),
    } });
    try app.drainEvents();
    try std.testing.expectEqual(@as(usize, 1), app.state.transcript.items.len);
    try std.testing.expectEqualStrings("fresh", app.state.transcript.items[0].text.items);
    try std.testing.expect(!app.quarantine_events);
}

test "App drain ignores stale lifecycle events while quarantined" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    app.session = mock.session();
    app.session_id = try std.testing.allocator.dupe(u8, "deleted");
    app.quarantine_events = true;
    app.quarantine_generation = 1;

    try mock.eventStream().push(.{ .agent_start = .{ .generation = 1 } });
    try mock.eventStream().push(.{ .turn_start = .{ .generation = 1 } });
    try mock.eventStream().push(.{ .text_delta = .{
        .generation = 1,
        .content_index = 0,
        .delta = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "stale")),
    } });
    try app.drainEvents();
    try std.testing.expect(app.quarantine_events);
    try std.testing.expectEqual(@as(usize, 0), app.state.transcript.items.len);

    try mock.eventStream().push(.{ .turn_start = .{ .generation = 2 } });
    try mock.eventStream().push(.{ .text_delta = .{
        .generation = 2,
        .content_index = 0,
        .delta = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "fresh")),
    } });
    try app.drainEvents();
    try std.testing.expect(!app.quarantine_events);
    try std.testing.expectEqual(@as(usize, 1), app.state.transcript.items.len);
    try std.testing.expectEqualStrings("fresh", app.state.transcript.items[0].text.items);
}

test "App drain buffers fresh user message_end during quarantine until lifecycle marker" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    app.session = mock.session();
    app.session_id = try std.testing.allocator.dupe(u8, "deleted");
    app.quarantine_events = true;
    app.quarantine_generation = 1;

    try mock.eventStream().push(.{ .message_end = .{
        .generation = 2,
        .role = .user,
        .text = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "next prompt")),
    } });
    try mock.eventStream().push(.{ .turn_start = .{ .generation = 2 } });
    try mock.eventStream().push(.{ .text_delta = .{
        .generation = 2,
        .content_index = 0,
        .delta = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "reply")),
    } });
    try app.drainEvents();

    try std.testing.expect(!app.quarantine_events);
    var found_prompt = false;
    var found_reply = false;
    for (app.state.transcript.items) |entry| {
        if (std.mem.eql(u8, entry.text.items, "next prompt")) found_prompt = true;
        if (std.mem.eql(u8, entry.text.items, "reply")) found_reply = true;
    }
    try std.testing.expect(found_prompt);
    try std.testing.expect(found_reply);
}

test "App drain ends quarantine on fresh terminal error and surfaces it" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    app.session = mock.session();
    app.session_id = try std.testing.allocator.dupe(u8, "deleted");
    app.quarantine_events = true;
    app.quarantine_generation = 1;

    try mock.eventStream().push(.{ .message_end = .{
        .generation = 2,
        .role = .user,
        .text = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "next prompt")),
    } });
    try mock.eventStream().push(.{ .@"error" = .{
        .generation = 2,
        .message = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "remote failed")),
    } });
    try app.drainEvents();

    try std.testing.expect(!app.quarantine_events);
    try std.testing.expectEqual(@as(usize, 0), app.quarantine_buffer.items.len);
    var found_error = false;
    for (app.state.transcript.items) |entry| {
        if (entry.kind == .@"error" and std.mem.eql(u8, entry.text.items, "remote failed")) found_error = true;
    }
    try std.testing.expect(found_error);
}

test "App drain keeps filtering stale generations after quarantine ends" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    app.session = mock.session();
    app.session_id = try std.testing.allocator.dupe(u8, "deleted");
    app.quarantine_events = true;
    app.quarantine_generation = 1;

    try mock.eventStream().push(.{ .agent_start = .{ .generation = 2 } });
    try mock.eventStream().push(.{ .text_delta = .{
        .generation = 2,
        .content_index = 0,
        .delta = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "fresh")),
    } });
    try app.drainEvents();
    try std.testing.expect(!app.quarantine_events);

    try mock.eventStream().push(.{ .text_delta = .{
        .generation = 1,
        .content_index = 0,
        .delta = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "late stale")),
    } });
    try app.drainEvents();
    var found_stale = false;
    for (app.state.transcript.items) |entry| {
        if (std.mem.eql(u8, entry.text.items, "late stale")) found_stale = true;
    }
    try std.testing.expect(!found_stale);
}

test "App submit clears pending session reset flag" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    app.session = mock.session();
    app.pending_session_reset = true;

    try app.submit("hello");
    try std.testing.expect(!app.pending_session_reset);
    try std.testing.expectEqual(@as(usize, 1), mock.submit_count);
}

test "setting pickers apply selected values" {
    const runtime_ptr = try std.testing.allocator.create(tui_runtime.TuiRuntime);
    runtime_ptr.* = try tui_runtime.TuiRuntime.init(std.testing.allocator, .{});

    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    app.runtime = runtime_ptr;

    app.openPicker(.permission);
    try std.testing.expectEqual(tui_state.AppMode.picker, app.state.mode);
    try std.testing.expectEqual(tui_state.PickerKind.permission, app.state.picker_kind);
    app.state.menu_index = 1;
    try app.applySelectedPermission();
    try std.testing.expectEqual(tui_runtime.PermissionMode.ask, app.state.permission_mode);
    try std.testing.expectEqual(tui_runtime.PermissionMode.ask, runtime_ptr.permissionMode());
}

test "TuiModel drains events before routing Enter while streaming" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    model.app.?.session = mock.session();
    model.app.?.state.status.streaming = true;
    try mock.eventStream().push(.{ .turn_end = .{ .stop_reason = .stop } });
    try mock.eventStream().push(.{ .agent_end = .{ .reason = .completed } });
    try model.app.?.state.composer.buffer.appendSlice(std.testing.allocator, "new turn");

    const cmd = model.update(.{ .key = .{ .key = .enter } }, &tctx.ctx);
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

test "App drain suppresses consumption duplicate of steered message" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    app.session = mock.session();

    try app.steer("steer mid turn");
    mock.steers_consumed = 1;
    try mock.eventStream().push(.{ .message_end = .{
        .role = .assistant,
        .text = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "turn one done")),
    } });
    try mock.eventStream().push(.{ .message_end = .{
        .role = .user,
        .steering = true,
        .text = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "steer mid turn")),
    } });

    try app.drainEvents();

    try std.testing.expectEqual(@as(usize, 2), app.state.transcript.items.len);
    try std.testing.expectEqual(tui_state.TranscriptKind.user, app.state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("steer mid turn", app.state.transcript.items[0].text.items);
    try std.testing.expectEqualStrings("turn one done", app.state.transcript.items[1].text.items);
    try std.testing.expectEqual(@as(usize, 0), app.state.pending_steers.items.len);
}

test "App drain keeps two steered echoes and renders unmatched user message" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    app.session = mock.session();

    try app.steer("steer one");
    try app.steer("steer two");
    mock.steers_consumed = 2;
    try mock.eventStream().push(.{ .message_end = .{
        .role = .user,
        .steering = true,
        .text = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "steer one")),
    } });
    try mock.eventStream().push(.{ .message_end = .{
        .role = .user,
        .steering = true,
        .text = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "steer two")),
    } });
    try mock.eventStream().push(.{ .message_end = .{
        .role = .user,
        .text = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "submitted prompt")),
    } });

    try app.drainEvents();

    try std.testing.expectEqual(@as(usize, 3), app.state.transcript.items.len);
    try std.testing.expectEqualStrings("steer one", app.state.transcript.items[0].text.items);
    try std.testing.expectEqualStrings("steer two", app.state.transcript.items[1].text.items);
    try std.testing.expectEqualStrings("submitted prompt", app.state.transcript.items[2].text.items);
    try std.testing.expectEqual(@as(usize, 0), app.state.pending_steers.items.len);
}

test "App drain reconciles pending steers when consumption events are evicted" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    app.session = mock.session();

    try app.steer("steer one");
    try app.steer("steer two");
    mock.steers_consumed = 2;
    try mock.eventStream().push(.{ .message_end = .{
        .role = .user,
        .steering = true,
        .text = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "steer two")),
    } });

    try app.drainEvents();

    try std.testing.expectEqual(@as(usize, 2), app.state.transcript.items.len);
    try std.testing.expectEqualStrings("steer one", app.state.transcript.items[0].text.items);
    try std.testing.expectEqualStrings("steer two", app.state.transcript.items[1].text.items);
    try std.testing.expectEqual(@as(usize, 0), app.state.pending_steers.items.len);

    try mock.eventStream().push(.{ .message_end = .{
        .role = .user,
        .text = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "steer one")),
    } });

    try app.drainEvents();

    try std.testing.expectEqual(@as(usize, 3), app.state.transcript.items.len);
    try std.testing.expectEqualStrings("steer one", app.state.transcript.items[2].text.items);
    try std.testing.expectEqual(@as(usize, 0), app.state.pending_steers.items.len);
}

test "TuiModel inline render shows every steer echo while assistant streams" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.applyEvent(.{ .message_start = .{ .role = .assistant } });
    try state.appendSteeredMessage("first steer");
    try state.appendTranscript(.system, "status row between steers");
    try state.appendSteeredMessage("second steer");
    try std.testing.expectEqual(@as(usize, 0), state.active_assistant_entry.?);
    try std.testing.expectEqual(@as(usize, 1), state.active_user_entry.?);

    const out = try TuiModel.renderInlineStream(std.testing.allocator, &state, 0, 0, 100, true);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "first steer") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "second steer") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "status row between steers") != null);
}

test "App drain auto-resumes remaining steering after completed turn" {
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    var mock = MockAppSession{ .queued_counts = .{ .steering = 2 } };
    defer mock.deinit();
    app.session = mock.session();
    app.state.setQueuedCounts(mock.queued_counts);
    try mock.eventStream().push(.{ .message_end = .{
        .role = .user,
        .text = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "run pwd")),
    } });

    try mock.eventStream().push(.{ .agent_end = .{ .reason = .completed } });
    try app.drainEvents();

    try std.testing.expectEqual(@as(usize, 1), mock.resume_count);
    try std.testing.expectEqual(@as(usize, 1), app.state.queue.steering);
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

test "TuiModel local streaming Enter steers when steering available" {
    const runtime = try std.testing.allocator.create(tui_runtime.TuiRuntime);
    errdefer std.testing.allocator.destroy(runtime);
    runtime.* = try tui_runtime.TuiRuntime.init(std.testing.allocator, .{});

    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    model.app.?.runtime = runtime;
    var mock = MockAppSession{};
    defer mock.deinit();
    model.app.?.session = mock.session();
    model.app.?.state.status.streaming = true;
    try model.app.?.state.composer.buffer.appendSlice(std.testing.allocator, "steer now");

    const cmd = model.update(.{ .key = .{ .key = .enter } }, &tctx.ctx);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, cmd);
    try std.testing.expectEqual(@as(usize, 0), mock.submit_count);
    try std.testing.expectEqual(@as(usize, 1), mock.steer_count);
    try std.testing.expectEqualStrings("", model.app.?.state.composer.text());
    try std.testing.expectEqual(@as(usize, 1), model.app.?.state.queue.steering);
}

test "TuiModel stops Enter routing when drained event enters approval mode" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
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

    const cmd = model.update(.{ .key = .{ .key = .enter } }, &tctx.ctx);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, cmd);
    try std.testing.expectEqual(tui_state.AppMode.approval, model.app.?.state.mode);
    try std.testing.expectEqual(@as(usize, 0), mock.submit_count);
    try std.testing.expectEqual(@as(usize, 0), mock.steer_count);
    try std.testing.expectEqualStrings("should wait", model.app.?.state.composer.text());
}

test "TuiModel allows /abort slash command during approval mode" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    model.app.?.session = mock.session();
    model.app.?.state.status.streaming = true;
    try model.app.?.state.approval.setPending(std.testing.allocator, "call-approval", "edit_file", "edit_file", "{\"path\":\"README.md\"}");
    model.app.?.state.mode = .approval;

    const keys = [_]u21{ '/', 'a', 'b', 'o', 'r', 't' };
    for (keys) |c| _ = model.update(.{ .key = .{ .key = .{ .char = c } } }, &tctx.ctx);

    const cmd = model.update(.{ .key = .{ .key = .enter } }, &tctx.ctx);
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
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    var mock = MockAppSession{};
    defer mock.deinit();
    model.app.?.session = mock.session();
    model.app.?.state.status.streaming = true;
    try model.app.?.state.approval.setPending(std.testing.allocator, "call-approval", "edit_file", "edit_file", "{\"path\":\"README.md\"}");
    model.app.?.state.mode = .approval;

    const keys = [_]u21{ '/', 'h', 'e', 'l', 'p' };
    for (keys) |c| _ = model.update(.{ .key = .{ .key = .{ .char = c } } }, &tctx.ctx);

    const cmd = model.update(.{ .key = .{ .key = .enter } }, &tctx.ctx);
    try std.testing.expectEqual(zz.Cmd(TuiModel.Msg).none, cmd);
    try std.testing.expectEqual(tui_state.AppMode.approval, model.app.?.state.mode);
    try std.testing.expectEqual(@as(usize, 0), model.app.?.state.transcript.items.len);
    try std.testing.expectEqualStrings("/help", model.app.?.state.composer.text());
}

test "TuiModel moves composer cursor and edits in place" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();

    _ = model.update(.{ .key = .{ .key = .{ .char = 'a' } } }, &tctx.ctx);
    _ = model.update(.{ .key = .{ .key = .{ .char = 'b' } } }, &tctx.ctx);
    _ = model.update(.{ .key = .{ .key = .{ .char = 'c' } } }, &tctx.ctx);
    _ = model.update(.{ .key = .{ .key = .left } }, &tctx.ctx);
    _ = model.update(.{ .key = .{ .key = .{ .char = 'X' } } }, &tctx.ctx);
    try std.testing.expectEqualStrings("abXc", model.app.?.state.composer.text());
    _ = model.update(.{ .key = .{ .key = .backspace } }, &tctx.ctx);
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

test "session picker typing characters does not edit anything" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    model.app.?.state.mode = .session_picker;
    try model.app.?.state.addSession("s1", "Alpha");
    try model.app.?.state.addSession("s2", "Beta");
    model.app.?.state.session_index = 1;

    _ = model.update(.{ .key = .{ .key = .{ .char = 'g' } } }, &tctx.ctx);
    _ = model.update(.{ .key = .{ .key = .{ .char = 'p' } } }, &tctx.ctx);
    _ = model.update(.{ .key = .{ .key = .backspace } }, &tctx.ctx);
    _ = model.update(.{ .key = .{ .key = .{ .char = 'd' }, .modifiers = .{ .ctrl = true } } }, &tctx.ctx);

    try std.testing.expectEqual(@as(usize, 2), model.app.?.state.sessions.items.len);
    try std.testing.expectEqual(@as(usize, 1), model.app.?.state.session_index);
    try std.testing.expectEqual(tui_state.AppMode.session_picker, model.app.?.state.mode);
}

fn sessionStoreBaseForAppTest(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "sessions" });
    errdefer allocator.free(base);
    try compat.fs.createDir(compat.fs.getCwd(), base);
    return base;
}

fn saveTestSession(store: session_store.Store, id: []const u8, last_active: i64) !void {
    var meta = session_store.SessionMetadata{
        .session_id = try std.testing.allocator.dupe(u8, id),
        .model = try std.testing.allocator.dupe(u8, "model-a"),
        .provider = try std.testing.allocator.dupe(u8, "provider-a"),
        .last_active = last_active,
    };
    defer meta.deinit(std.testing.allocator);
    try store.save(meta, .{ .turn_start = .{} });
}

test "TuiModel PageUp scrolls the inline window and PageDown returns to the tail" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator), .render_mode = .inline_history };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    tctx.ctx.width = 60;
    tctx.ctx.height = 12;
    var i: usize = 0;
    while (i < 14) : (i += 1) {
        const text = try std.fmt.allocPrint(std.testing.allocator, "entry number {d}", .{i});
        defer std.testing.allocator.free(text);
        try model.app.?.state.appendTranscript(.user, text);
    }
    model.app.?.inline_history_flushed = 8;

    const tail = model.view(&tctx.ctx);
    try std.testing.expect(std.mem.indexOf(u8, tail, "SCROLL") == null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "entry number 13") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "entry number 0") == null);

    _ = model.update(.{ .key = .{ .key = .page_up } }, &tctx.ctx);
    try std.testing.expectEqual(@as(usize, 5), model.app.?.state.transcript_scroll);
    const scrolled = model.view(&tctx.ctx);
    try std.testing.expect(std.mem.indexOf(u8, scrolled, "SCROLL") != null);
    try std.testing.expect(std.mem.indexOf(u8, scrolled, "entry number 13") == null);
    try std.testing.expect(TuiModel.countLines(scrolled) <= 12);

    var n: usize = 0;
    while (n < 20) : (n += 1) _ = model.update(.{ .key = .{ .key = .page_up } }, &tctx.ctx);
    const top = model.view(&tctx.ctx);
    try std.testing.expect(std.mem.indexOf(u8, top, "entry number 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, top, "SCROLL 100%") != null);
    const clamped = model.app.?.state.transcript_scroll;
    try std.testing.expect(clamped < 5 + 20 * 5);

    _ = model.update(.{ .key = .{ .key = .page_down } }, &tctx.ctx);
    try std.testing.expectEqual(clamped - 5, model.app.?.state.transcript_scroll);
    while (model.app.?.state.transcript_scroll > 0) _ = model.update(.{ .key = .{ .key = .page_down } }, &tctx.ctx);
    const back = model.view(&tctx.ctx);
    try std.testing.expectEqualStrings(tail, back);

    _ = model.update(.{ .key = .{ .key = .page_up } }, &tctx.ctx);
    try model.app.?.submit("/help");
    try std.testing.expectEqual(@as(usize, 0), model.app.?.state.transcript_scroll);
}

test "TuiModel PageUp and PageDown scroll the transcript" {
    var model = TuiModel{ .app = App.initWithoutRuntime(std.testing.allocator) };
    defer model.deinit();
    var tctx: TestContext = undefined;
    tctx.setup();
    defer tctx.deinit();
    try model.app.?.state.appendTranscript(.user, "x");
    model.app.?.state.transcript_scroll = 0;

    _ = model.update(.{ .key = .{ .key = .page_up } }, &tctx.ctx);
    try std.testing.expectEqual(@as(usize, 5), model.app.?.state.transcript_scroll);
    _ = model.update(.{ .key = .{ .key = .page_down } }, &tctx.ctx);
    try std.testing.expectEqual(@as(usize, 0), model.app.?.state.transcript_scroll);
}

test "resume selected session clears delete reset flags" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try sessionStoreBaseForAppTest(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);

    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    app.store = try session_store.Store.init(std.testing.allocator, base);
    try saveTestSession(app.store.?, "s1", 1);
    try app.loadSessions();
    app.pending_session_reset = true;
    app.quarantine_events = true;

    try std.testing.expectError(error.NoRuntimeConfigured, app.resumeSelectedSession());
    try std.testing.expect(app.pending_session_reset);
    try std.testing.expect(app.quarantine_events);
}

test "resume selected session allows runtime without protocol" {
    const runtime = try std.testing.allocator.create(tui_runtime.TuiRuntime);
    errdefer std.testing.allocator.destroy(runtime);
    runtime.* = try tui_runtime.TuiRuntime.init(std.testing.allocator, .{});
    var app = App.initWithoutRuntime(std.testing.allocator);
    defer app.deinit();
    app.runtime = runtime;

    try std.testing.expectError(error.NoStoreConfigured, app.resumeSelectedSession());

    app.store = try session_store.Store.init(std.testing.allocator, ".");

    try app.resumeSelectedSession();
}

test "resume selected session clears delete reset flags on success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try sessionStoreBaseForAppTest(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);

    var production = try ProductionRuntime.init(std.testing.allocator, .{});
    defer production.deinit();
    production.initBridge();

    var app = try App.init(std.testing.allocator, production.options());
    defer app.deinit();
    app.runtime.?.run_async = false;

    if (app.store) |*store| store.deinit();
    app.store = try session_store.Store.init(std.testing.allocator, base);

    const model = app.runtime.?.currentModel() orelse return error.NoModelConfigured;
    var meta = session_store.SessionMetadata{
        .session_id = try std.testing.allocator.dupe(u8, "s1"),
        .model = try std.testing.allocator.dupe(u8, model.id),
        .provider = try std.testing.allocator.dupe(u8, model.provider),
        .last_active = 1,
    };
    defer meta.deinit(std.testing.allocator);
    try app.store.?.save(meta, .{ .turn_start = .{} });

    try app.loadSessions();
    app.pending_session_reset = true;
    app.quarantine_events = true;
    app.quarantine_generation = 1;

    try app.resumeSelectedSession();
    try std.testing.expect(!app.pending_session_reset);
    try std.testing.expect(!app.quarantine_events);
    try std.testing.expectEqual(@as(usize, 0), app.quarantine_buffer.items.len);
    try std.testing.expectEqualStrings("s1", app.session_id);
}

const MockProvider = struct {
    fn stream(
        model: ai_types.Model,
        context: ai_types.Context,
        options: ?ai_types.StreamOptions,
        a: std.mem.Allocator,
    ) anyerror!*event_stream.AssistantMessageEventStream {
        _ = model;
        _ = context;

        const s = try a.create(event_stream.AssistantMessageEventStream);
        s.* = event_stream.AssistantMessageEventStream.init(a);
        if (options) |opts| {
            if (opts.requires_owned_stream_events) {
                s.owns_events = true;
                s.clone_event_fn = ai_types.cloneAssistantMessageEvent;
            }
        }

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

const test_messages = [_]ai_types.Message{
    .{ .user = .{
        .content = .{ .text = "hi" },
        .timestamp = 0,
    } },
};

fn testContext() ai_types.Context {
    return .{ .messages = &test_messages };
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

test "ProductionRuntime initBridge gives stable registry pointer" {
    const allocator = std.testing.allocator;
    var production = try ProductionRuntime.init(allocator, .{});
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

test "ProductionRuntime multiple sequential streams reuse stable pointer" {
    const allocator = std.testing.allocator;
    var production = try ProductionRuntime.init(allocator, .{});
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

test "ProductionRuntime outlives stream threads from dropped TuiRuntime" {
    const allocator = std.testing.allocator;
    var production = try ProductionRuntime.init(allocator, .{});
    defer production.deinit();

    try registerMockProvider(&production.registry);
    production.initBridge();

    const stream = blk: {
        const options = production.options();
        const protocol = options.protocol.?;
        const s = try protocol.stream(test_model, testContext(), .{ .api_key = "test-key" }, allocator);
        break :blk s;
    };
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    try drainStreamAndVerify(allocator, stream);
}

test "a granted credential does not change what the login badge reports" {
    const allocator = std.testing.allocator;

    var storage = oauth_storage.AuthStorage{
        .providers = std.StringHashMap(oauth_storage.ProviderAuth).init(allocator),
        .allocator = allocator,
    };
    defer storage.deinit();

    try storage.providers.put(try allocator.dupe(u8, "anthropic"), .{ .oauth = .{
        .refresh = try allocator.dupe(u8, "stored-refresh"),
        .access = try allocator.dupe(u8, "stored-access"),
        .expires = 0,
    } });

    try std.testing.expectEqual(App.LoginStatus.expired, App.loginStatusFor(&storage, "anthropic", false));

    try storage.putEphemeral("anthropic", .{ .api_key = try allocator.dupe(u8, "sk-granted") });

    try std.testing.expectEqual(App.LoginStatus.expired, App.loginStatusFor(&storage, "anthropic", false));
    try std.testing.expectEqual(App.LoginStatus.none, App.loginStatusFor(&storage, "kimi", false));
}
