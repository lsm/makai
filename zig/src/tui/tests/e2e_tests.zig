//! UI-level end-to-end tests for the Makai TUI.
//!
//! These drive the real `TuiModel` (init/update/view) the same way the zigzag
//! runtime does: simulated keystrokes flow through `update`, and assertions run
//! against the fully rendered frame produced by `view`. A `MockProvider` stands
//! in for the network so turns, tool calls, and approvals are deterministic.
//!
//! The driver redirects `$HOME` to a throwaway temp directory so the session
//! store never touches the developer's real `~/.makai`, keeping each test
//! hermetic.

const std = @import("std");
const compat = @import("compat");
const zz = @import("zigzag");
const ai_types = @import("ai_types");
const tui_app = @import("tui_app");
const tui_runtime = @import("tui_runtime");
const tui_state = @import("tui_state");
const tui_session = @import("tui_session");
const session_store = @import("tui_session_store");
const tui_config = @import("tui_config");
const mock_provider = @import("tui_tests_mock_provider");
const fixtures = @import("tui_tests_fixtures");
const OwnedSlice = @import("owned_slice").OwnedSlice;

const App = tui_app.App;
const TuiModel = tui_app.TuiModel;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const DriverOptions = struct {
    width: u16 = 100,
    height: u16 = 30,
};

/// Drives a real `TuiModel` through simulated keystrokes and renders frames,
/// mirroring how the zigzag `Program` runtime would.
const Driver = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    env: zz.Environment,
    ctx: zz.Context,
    model: TuiModel,
    tmp: std.testing.TmpDir,
    saved_home: ?[]u8,
    init_cmd: zz.Cmd(TuiModel.Msg),

    fn init(gpa: std.mem.Allocator, options: tui_runtime.TuiRuntimeOptions, view_opts: DriverOptions) !*Driver {
        const self = try gpa.create(Driver);
        errdefer gpa.destroy(self);

        self.gpa = gpa;
        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        self.env = .{};
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();

        // Point the session store at the temp dir. The store joins HOME with
        // ".makai/sessions" and creates it relative to the cwd, so a cwd-relative
        // HOME keeps every file inside the temp tree the cleanup() removes.
        self.saved_home = compat.getEnvVarOwned(gpa, "HOME") catch null;
        const rel_home = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{self.tmp.sub_path[0..]});
        defer gpa.free(rel_home);
        const rel_home_z = try gpa.dupeZ(u8, rel_home);
        defer gpa.free(rel_home_z);
        _ = setenv("HOME", rel_home_z.ptr, 1);

        // Frame allocator is the arena (reset each render); model state lives on gpa.
        self.ctx = zz.Context.init(self.arena.allocator(), gpa, std.testing.io, &self.env);
        self.ctx.width = view_opts.width;
        self.ctx.height = view_opts.height;

        self.model = .{ .options = options };
        self.init_cmd = self.model.init(&self.ctx);
        return self;
    }

    fn deinit(self: *Driver) void {
        self.model.deinit();
        self.restoreHome();
        self.arena.deinit();
        self.tmp.cleanup();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn restoreHome(self: *Driver) void {
        if (self.saved_home) |home| {
            if (self.gpa.dupeZ(u8, home)) |home_z| {
                _ = setenv("HOME", home_z.ptr, 1);
                self.gpa.free(home_z);
            } else |_| {}
            self.gpa.free(home);
        } else {
            _ = unsetenv("HOME");
        }
    }

    fn app(self: *Driver) *App {
        return &self.model.app.?;
    }

    fn sendKey(self: *Driver, key: zz.Key) void {
        _ = self.model.update(.{ .key = .{ .key = key } }, &self.ctx);
    }

    fn typeText(self: *Driver, text: []const u8) void {
        const view = std.unicode.Utf8View.init(text) catch return;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            _ = self.model.update(.{ .key = .{ .key = .{ .char = cp } } }, &self.ctx);
        }
    }

    fn pressEnter(self: *Driver) void {
        self.sendKey(.enter);
    }

    fn tick(self: *Driver) void {
        _ = self.model.update(.{ .tick = .{ .timestamp = 0, .delta = 0 } }, &self.ctx);
    }

    /// Render a frame. The returned slice is owned by the frame arena and stays
    /// valid until the next `frame()` call or `deinit()`.
    fn frame(self: *Driver) []const u8 {
        _ = self.arena.reset(.retain_capacity);
        return self.model.view(&self.ctx);
    }

    fn frameContains(self: *Driver, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.frame(), needle) != null;
    }

    /// Tick (draining async events) until `pred` holds or the budget runs out.
    fn pumpUntil(self: *Driver, pred: *const fn (*App) bool, max_iters: usize) !void {
        var i: usize = 0;
        while (i < max_iters) : (i += 1) {
            self.tick();
            if (pred(self.app())) return;
            compat.time.sleepMs(2);
        }
        return error.PumpTimeout;
    }
};

fn inApprovalMode(app: *App) bool {
    return app.state.mode == .approval;
}

fn notStreaming(app: *App) bool {
    return !app.state.status.streaming;
}

fn ownedText(text: []const u8) !OwnedSlice(u8) {
    return OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, text));
}

test "e2e: /help renders all command names into the transcript" {
    const models = [_]ai_types.Model{mock_provider.test_model};
    var provider = mock_provider.MockProvider.init(.{ .steps = &.{} });
    var d = try Driver.init(std.testing.allocator, .{
        .protocol = provider.protocolClient(),
        .models = &models,
        .run_async = false,
    }, .{ .height = 60 });
    defer d.deinit();

    d.typeText("/help");
    d.pressEnter();

    const screen = d.frame();
    const expected = [_][]const u8{
        "/help",  "/model",       "/provider", "/status",
        "/tools", "/permissions", "/compact",  "/clear",
        "/diff",  "/quit",
    };
    for (expected) |needle| {
        if (std.mem.indexOf(u8, screen, needle) == null) {
            std.debug.print("missing {s} in rendered frame:\n{s}\n", .{ needle, screen });
            return error.MissingCommand;
        }
    }
}

test "e2e: a submitted turn streams the assistant reply into the transcript" {
    const models = [_]ai_types.Model{mock_provider.test_model};
    const steps = [_]mock_provider.ResponseStep{.{ .text = fixtures.expected_text }};
    var provider = mock_provider.MockProvider.init(.{ .steps = &steps });
    var d = try Driver.init(std.testing.allocator, .{
        .protocol = provider.protocolClient(),
        .models = &models,
        .run_async = false,
    }, .{});
    defer d.deinit();

    d.typeText("hello there");
    d.pressEnter();

    const screen = d.frame();
    try std.testing.expect(std.mem.indexOf(u8, screen, "hello there") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, fixtures.expected_text) != null);
    try std.testing.expectEqual(@as(usize, 1), provider.call_count);
    try std.testing.expect(!d.app().state.status.streaming);
}

test "e2e: up arrow recalls the previous submission into the composer" {
    const models = [_]ai_types.Model{mock_provider.test_model};
    const steps = [_]mock_provider.ResponseStep{
        .{ .text = fixtures.expected_text },
        .{ .text = fixtures.expected_text },
    };
    var provider = mock_provider.MockProvider.init(.{ .steps = &steps });
    var d = try Driver.init(std.testing.allocator, .{
        .protocol = provider.protocolClient(),
        .models = &models,
        .run_async = false,
    }, .{});
    defer d.deinit();

    d.typeText("first message");
    d.pressEnter();
    d.typeText("second message");
    d.pressEnter();

    // Composer is empty after submitting; arrow-up walks back through history.
    try std.testing.expectEqualStrings("", d.app().state.composer.text());
    d.sendKey(.up);
    try std.testing.expectEqualStrings("second message", d.app().state.composer.text());
    d.sendKey(.up);
    try std.testing.expectEqualStrings("first message", d.app().state.composer.text());
    d.sendKey(.down);
    try std.testing.expectEqualStrings("second message", d.app().state.composer.text());
}

test "e2e: tool approval prompt appears and approving runs the tool to completion" {
    const models = [_]ai_types.Model{mock_provider.test_model};
    const tools = fixtures.tools();
    const steps = [_]mock_provider.ResponseStep{
        .{ .tool_calls = &fixtures.approval_tool_calls },
        .{ .text = fixtures.final_text },
    };
    var provider = mock_provider.MockProvider.init(.{ .steps = &steps });
    var d = try Driver.init(std.testing.allocator, .{
        .protocol = provider.protocolClient(),
        .models = &models,
        .tools = &tools,
        .permission_mode = .ask,
        .run_async = true,
    }, .{});
    defer d.deinit();

    d.typeText("please run the shell tool");
    d.pressEnter();

    // The agent thread blocks awaiting approval; ticking surfaces the prompt.
    try d.pumpUntil(inApprovalMode, 2000);
    try std.testing.expect(d.frameContains("shell_command"));

    // Approve: 'y' in approval mode resolves the waiter and the loop resumes.
    d.typeText("y");
    try d.pumpUntil(notStreaming, 2000);

    try std.testing.expect(d.frameContains(fixtures.final_text));
    try std.testing.expectEqual(tui_state.AppMode.normal, d.app().state.mode);
    try std.testing.expectEqual(@as(usize, 2), provider.call_count);
}

test "e2e: /model opens the picker and selecting switches the active model" {
    const models = [_]ai_types.Model{
        mock_provider.test_model,
        .{
            .id = "second-model",
            .name = "Second Model",
            .api = "tui-fixture-api",
            .provider = "second-provider",
            .base_url = "https://example.invalid",
            .reasoning = false,
            .input = &.{"text"},
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
            .context_window = 4096,
            .max_tokens = 512,
        },
    };
    var provider = mock_provider.MockProvider.init(.{ .steps = &.{} });
    var d = try Driver.init(std.testing.allocator, .{
        .protocol = provider.protocolClient(),
        .models = &models,
        .run_async = false,
    }, .{});
    defer d.deinit();

    d.typeText("/model");
    d.pressEnter();
    _ = d.frame();

    try std.testing.expectEqual(tui_state.AppMode.model_picker, d.app().state.mode);
    try std.testing.expect(d.frameContains("Select model"));
    try std.testing.expect(d.frameContains("second-model"));

    // Highlight the second model and choose it.
    d.sendKey(.down);
    d.sendKey(.enter);

    try std.testing.expectEqual(tui_state.AppMode.normal, d.app().state.mode);
    try std.testing.expectEqualStrings("second-model", d.app().state.status.model);

    var store = try tui_config.Store.initDefault(std.testing.allocator);
    defer store.deinit();
    var cfg = try store.load();
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("second-model", cfg.model);
    try std.testing.expectEqualStrings("second-provider", cfg.provider);
}

test "e2e: /model and /provider commands persist the active model" {
    const models = [_]ai_types.Model{
        mock_provider.test_model,
        .{
            .id = "second-model",
            .name = "Second Model",
            .api = "tui-fixture-api",
            .provider = "second-provider",
            .base_url = "https://example.invalid",
            .reasoning = false,
            .input = &.{"text"},
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
            .context_window = 4096,
            .max_tokens = 512,
        },
    };
    var provider = mock_provider.MockProvider.init(.{ .steps = &.{} });
    var d = try Driver.init(std.testing.allocator, .{
        .protocol = provider.protocolClient(),
        .models = &models,
        .run_async = false,
    }, .{});
    defer d.deinit();

    d.typeText("/model second-model");
    d.pressEnter();
    try std.testing.expectEqualStrings("second-model", d.app().state.status.model);

    {
        var store = try tui_config.Store.initDefault(std.testing.allocator);
        defer store.deinit();
        var cfg = try store.load();
        defer cfg.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("second-model", cfg.model);
        try std.testing.expectEqualStrings("second-provider", cfg.provider);
    }

    d.typeText("/provider " ++ mock_provider.test_model.provider);
    d.pressEnter();
    try std.testing.expectEqualStrings(mock_provider.test_model.id, d.app().state.status.model);

    {
        var store = try tui_config.Store.initDefault(std.testing.allocator);
        defer store.deinit();
        var cfg = try store.load();
        defer cfg.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(mock_provider.test_model.id, cfg.model);
        try std.testing.expectEqualStrings(mock_provider.test_model.provider, cfg.provider);
    }
}

test "e2e: /login opens the provider picker and selecting starts the flow" {
    const models = [_]ai_types.Model{mock_provider.test_model};
    var provider = mock_provider.MockProvider.init(.{ .steps = &.{} });
    var d = try Driver.init(std.testing.allocator, .{
        .protocol = provider.protocolClient(),
        .models = &models,
        .run_async = false,
    }, .{});
    defer d.deinit();

    d.typeText("/login");
    d.pressEnter();
    _ = d.frame();

    try std.testing.expectEqual(tui_state.AppMode.login_picker, d.app().state.mode);
    try std.testing.expect(d.frameContains("Login provider"));
    try std.testing.expect(d.frameContains("anthropic"));

    // Selecting a provider starts its OAuth worker and reports progress. The
    // worker blocks awaiting a pasted code; cancelling (handled in deinit) makes
    // the flow abort locally without any network exchange.
    d.sendKey(.enter);
    try std.testing.expectEqual(tui_state.AppMode.normal, d.app().state.mode);
    try std.testing.expect(d.frameContains("starting login for anthropic"));
}

test "e2e: TUI never enables mouse reporting so native selection works" {
    const models = [_]ai_types.Model{mock_provider.test_model};
    var provider = mock_provider.MockProvider.init(.{ .steps = &.{} });
    var d = try Driver.init(std.testing.allocator, .{
        .protocol = provider.protocolClient(),
        .models = &models,
        .run_async = false,
    }, .{});
    defer d.deinit();

    // The startup command must be the plain tick timer, NOT a batch that turns
    // on mouse capture. Grabbing the mouse (e.g. `\x1b[?1003h`) can leave the
    // user's shell receiving raw mouse sequences if the TUI aborts.
    try std.testing.expectEqual(
        @as(std.meta.Tag(zz.Cmd(TuiModel.Msg)), .every),
        std.meta.activeTag(d.init_cmd),
    );
}

test "e2e: /copy reports when there is a reply to copy" {
    const models = [_]ai_types.Model{mock_provider.test_model};
    var provider = mock_provider.MockProvider.init(.{ .steps = &.{} });
    var d = try Driver.init(std.testing.allocator, .{
        .protocol = provider.protocolClient(),
        .models = &models,
        .run_async = false,
    }, .{});
    defer d.deinit();

    // No assistant reply yet.
    d.typeText("/copy");
    d.pressEnter();
    try std.testing.expect(d.frameContains("nothing to copy yet"));

    // With a reply present, /copy reports success (clipboard write is a no-op
    // without a TTY, but the staging path runs).
    try d.app().state.appendTranscript(.assistant, "the answer is 42");
    d.typeText("/copy");
    d.pressEnter();
    try std.testing.expect(d.frameContains("copied last reply to clipboard"));
}

test "e2e: /sessions opens the picker and resuming replays the saved transcript" {
    const models = [_]ai_types.Model{mock_provider.test_model};
    var provider = mock_provider.MockProvider.init(.{ .steps = &.{} });
    var d = try Driver.init(std.testing.allocator, .{
        .protocol = provider.protocolClient(),
        .models = &models,
        .run_async = false,
    }, .{});
    defer d.deinit();

    // Seed one saved session into the (temp) store the driver's App reads from.
    {
        var store = try session_store.Store.initDefault(std.testing.allocator);
        defer store.deinit();
        var meta = session_store.SessionMetadata{
            .session_id = try std.testing.allocator.dupe(u8, "seeded-session"),
            .model = try std.testing.allocator.dupe(u8, mock_provider.test_model.id),
            .provider = try std.testing.allocator.dupe(u8, mock_provider.test_model.provider),
            .created_at = 1,
            .last_active = 1,
            .turn_count = 1,
            .working_dir = try std.testing.allocator.dupe(u8, "."),
        };
        defer meta.deinit(std.testing.allocator);

        try store.save(meta, .{ .message_start = .{ .role = .user } });
        var user_end = tui_session.TuiEvent{ .message_end = .{ .role = .user, .text = try ownedText("remembered question") } };
        defer user_end.deinit(std.testing.allocator);
        try store.save(meta, user_end);
        try store.save(meta, .{ .message_start = .{ .role = .assistant } });
        var assistant_delta = tui_session.TuiEvent{ .text_delta = .{ .content_index = 0, .delta = try ownedText("remembered answer") } };
        defer assistant_delta.deinit(std.testing.allocator);
        try store.save(meta, assistant_delta);
        try store.save(meta, .{ .message_end = .{ .role = .assistant } });
    }

    // /sessions reloads from the store and opens the picker.
    d.typeText("/sessions");
    d.pressEnter();
    _ = d.frame(); // establishes last_view_height for picker sizing

    try std.testing.expectEqual(tui_state.AppMode.session_picker, d.app().state.mode);
    try std.testing.expect(d.app().state.sessions.items.len >= 1);

    // Resume the (only) selected session; its transcript should be replayed.
    d.sendKey(.enter);

    try std.testing.expectEqual(tui_state.AppMode.normal, d.app().state.mode);
    const screen = d.frame();
    try std.testing.expect(std.mem.indexOf(u8, screen, "remembered question") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "remembered answer") != null);
}
