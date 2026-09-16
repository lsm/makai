const std = @import("std");
const ai_types = @import("ai_types");
const tui_runtime = @import("tui_runtime");
const tui_state = @import("tui_state");

pub const CommandKind = enum {
    help,
    model,
    login,
    provider,
    status,
    @"resume",
    permissions,
    clear,
    abort,
    quit,
};

pub const Command = struct {
    kind: CommandKind,
    arg: ?[]const u8 = null,
};

pub const ParseError = error{
    NotACommand,
    EmptyCommand,
    UnknownCommand,
};

pub const CommandAction = enum {
    none,
    quit,
    clear_transcript,
    open_session_picker,
    open_model_picker,
    open_login_picker,
    open_permission_picker,
    start_login_provider,
};

pub const CommandResult = struct {
    action: CommandAction = .none,
    output: []u8 = &.{},
    login_provider: []u8 = &.{},
    is_error: bool = false,

    pub fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
        if (self.output.len > 0) allocator.free(self.output);
        if (self.login_provider.len > 0) allocator.free(self.login_provider);
        self.* = undefined;
    }
};

pub const CommandContext = struct {
    allocator: std.mem.Allocator,
    state: *tui_state.AppState,
    runtime: ?*tui_runtime.TuiRuntime = null,
    session: ?*tui_runtime.TuiSession = null,
};

const Handler = *const fn (CommandContext, Command) anyerror!CommandResult;

pub const CommandInfo = struct {
    name: []const u8,
    kind: CommandKind,
    usage: []const u8,
    description: []const u8,
    handler: Handler,
};

pub const commands = [_]CommandInfo{
    .{ .name = "help", .kind = .help, .usage = "/help", .description = "List available commands", .handler = handleHelp },
    .{ .name = "model", .kind = .model, .usage = "/model [name]", .description = "Open model picker or switch active model", .handler = handleModel },
    .{ .name = "login", .kind = .login, .usage = "/login [provider]", .description = "Sign in to a provider", .handler = handleLogin },
    .{ .name = "provider", .kind = .provider, .usage = "/provider [name]", .description = "Show or switch active provider", .handler = handleProvider },
    .{ .name = "status", .kind = .status, .usage = "/status", .description = "Show session status", .handler = handleStatus },
    .{ .name = "sessions", .kind = .@"resume", .usage = "/sessions", .description = "Open saved sessions", .handler = handleSessions },
    .{ .name = "resume", .kind = .@"resume", .usage = "/resume", .description = "Open saved sessions", .handler = handleSessions },
    .{ .name = "permissions", .kind = .permissions, .usage = "/permissions [ask|bypass]", .description = "Pick or set tool permission mode", .handler = handlePermissions },
    .{ .name = "perm", .kind = .permissions, .usage = "/perm [ask|bypass]", .description = "Pick or set tool permission mode", .handler = handlePermissions },
    .{ .name = "clear", .kind = .clear, .usage = "/clear", .description = "Clear transcript display", .handler = handleClear },
    .{ .name = "abort", .kind = .abort, .usage = "/abort", .description = "Cancel the active streaming turn", .handler = handleAbort },
    .{ .name = "quit", .kind = .quit, .usage = "/quit", .description = "Exit TUI", .handler = handleQuit },
};

pub fn parse(input: []const u8) ParseError!Command {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '/') return error.NotACommand;
    const body = trimLeftAscii(trimmed[1..]);
    if (body.len == 0) return error.EmptyCommand;

    var name_end: usize = 0;
    while (name_end < body.len and !std.ascii.isWhitespace(body[name_end])) : (name_end += 1) {}
    const name = body[0..name_end];
    const arg_text = std.mem.trim(u8, body[name_end..], " \t\r\n");

    if (findCommand(name)) |info| return .{ .kind = info.kind, .arg = if (arg_text.len > 0) arg_text else null };
    return error.UnknownCommand;
}

pub fn parseOrMessage(allocator: std.mem.Allocator, input: []const u8) !CommandParseResult {
    const command = parse(input) catch |err| switch (err) {
        error.UnknownCommand => return .{ .message = try unknownCommandMessage(allocator, input) },
        error.EmptyCommand => return .{ .message = try allocator.dupe(u8, "empty command. Type /help for commands") },
        error.NotACommand => return err,
    };
    return .{ .command = command };
}

pub const CommandParseResult = union(enum) {
    command: Command,
    message: []u8,

    pub fn deinit(self: *CommandParseResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .message => |message| allocator.free(message),
            .command => {},
        }
        self.* = undefined;
    }
};

pub fn dispatch(ctx: CommandContext, command: Command) !CommandResult {
    const info = findCommandByKind(command.kind) orelse return .{ .output = try ctx.allocator.dupe(u8, "unknown command"), .is_error = true };
    return try info.handler(ctx, command);
}

pub fn helpText(allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    try writer.writeAll("Available commands:\n");
    for (&commands) |info| try writer.print("  {s:<18} {s}\n", .{ info.usage, info.description });
    return out.toOwnedSlice();
}

pub fn unknownCommandMessage(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const name = commandName(input) orelse "";
    if (suggestCommand(name)) |suggestion| {
        return std.fmt.allocPrint(allocator, "unknown command: /{s}. Did you mean /{s}?", .{ name, suggestion });
    }
    return std.fmt.allocPrint(allocator, "unknown command: /{s}. Type /help for commands", .{name});
}

fn trimLeftAscii(input: []const u8) []const u8 {
    var start: usize = 0;
    while (start < input.len and (input[start] == ' ' or input[start] == '\t')) : (start += 1) {}
    return input[start..];
}

fn commandName(input: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '/') return null;
    const body = trimLeftAscii(trimmed[1..]);
    if (body.len == 0) return null;
    var end: usize = 0;
    while (end < body.len and !std.ascii.isWhitespace(body[end])) : (end += 1) {}
    return body[0..end];
}

fn findCommand(name: []const u8) ?CommandInfo {
    for (&commands) |info| if (std.mem.eql(u8, info.name, name)) return info;
    return null;
}

fn findCommandByKind(kind: CommandKind) ?CommandInfo {
    for (&commands) |info| if (info.kind == kind) return info;
    return null;
}

fn suggestCommand(name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    for (&commands) |info| if (std.mem.startsWith(u8, info.name, name) or std.mem.startsWith(u8, name, info.name)) return info.name;
    for (&commands) |info| if (info.name[0] == name[0]) return info.name;
    return null;
}

fn handleHelp(ctx: CommandContext, command: Command) !CommandResult {
    _ = command;
    return .{ .output = try helpText(ctx.allocator) };
}

fn handleModel(ctx: CommandContext, command: Command) !CommandResult {
    if (command.arg) |model_id| {
        if (ctx.session) |session| {
            try session.switchModel(model_id);
        } else if (ctx.runtime) |runtime| {
            try runtime.switchModel(model_id);
        } else {
            return error.NoRuntimeConfigured;
        }
        const model = currentModel(ctx);
        if (model) |m| try ctx.state.status.setModel(ctx.allocator, m.id, m.provider);
        return .{ .output = try std.fmt.allocPrint(ctx.allocator, "model switched to {s}", .{model_id}) };
    }
    return .{ .action = .open_model_picker };
}

fn handleLogin(ctx: CommandContext, command: Command) !CommandResult {
    if (command.arg) |provider| {
        return .{
            .action = .start_login_provider,
            .login_provider = try ctx.allocator.dupe(u8, provider),
        };
    }
    return .{ .action = .open_login_picker };
}

fn handleProvider(ctx: CommandContext, command: Command) !CommandResult {
    const runtime = ctx.runtime orelse return error.NoRuntimeConfigured;
    if (command.arg) |provider| {
        for (runtime.availableModels()) |model| {
            if (std.mem.eql(u8, model.provider, provider)) {
                if (ctx.session) |session| {
                    try session.switchModelExact(model);
                } else {
                    try runtime.switchModelExact(model);
                }
                try ctx.state.status.setModel(ctx.allocator, model.id, model.provider);
                return .{ .output = try std.fmt.allocPrint(ctx.allocator, "provider switched to {s} via model {s}", .{ provider, model.id }) };
            }
        }
        return error.ProviderNotFound;
    }

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    const writer = &out.writer;
    try writer.print("current provider: {s}\navailable providers:", .{ctx.state.status.provider});
    for (runtime.availableModels(), 0..) |model, idx| {
        var seen = false;
        for (runtime.availableModels()[0..idx]) |prev| {
            if (std.mem.eql(u8, prev.provider, model.provider)) {
                seen = true;
                break;
            }
        }
        if (!seen) try writer.print("\n  {s}", .{model.provider});
    }
    return .{ .output = try out.toOwnedSlice() };
}

fn handleStatus(ctx: CommandContext, command: Command) !CommandResult {
    _ = command;
    const status = ctx.state.status;
    return .{ .output = try std.fmt.allocPrint(ctx.allocator, "session: {s}\nmodel: {s}\nprovider: {s}\nturns: {d}\ncontext: {d}/{d}\nstreaming: {s}", .{
        if (status.session_id.len > 0) status.session_id else "(current)",
        if (status.model.len > 0) status.model else "none",
        if (status.provider.len > 0) status.provider else "none",
        status.turn_count,
        status.context_used,
        status.context_limit,
        if (status.streaming) "yes" else "no",
    }) };
}

fn handleSessions(ctx: CommandContext, command: Command) !CommandResult {
    _ = command;
    if (ctx.state.sessions.items.len == 0) {
        return .{ .output = try ctx.allocator.dupe(u8, "no saved sessions") };
    }
    return .{ .action = .open_session_picker };
}

fn handlePermissions(ctx: CommandContext, command: Command) !CommandResult {
    if (command.arg) |arg| {
        const mode = parsePermissionMode(arg) orelse {
            return .{
                .output = try std.fmt.allocPrint(ctx.allocator, "unknown permission mode: {s}", .{arg}),
                .is_error = true,
            };
        };
        const runtime = ctx.runtime orelse return error.NoRuntimeConfigured;
        try runtime.setPermissionMode(mode);
        ctx.state.permission_mode = mode;
        return .{ .output = try std.fmt.allocPrint(ctx.allocator, "permission mode set to {s}", .{@tagName(mode)}) };
    }

    if (ctx.runtime) |runtime| {
        ctx.state.permission_mode = runtime.permissionMode();
    }
    return .{ .action = .open_permission_picker };
}

fn parsePermissionMode(value: []const u8) ?tui_runtime.PermissionMode {
    if (std.mem.eql(u8, value, "ask")) return .ask;
    if (std.mem.eql(u8, value, "bypass")) return .bypass;
    return null;
}

fn handleClear(ctx: CommandContext, command: Command) !CommandResult {
    _ = command;
    return .{ .action = .clear_transcript, .output = try ctx.allocator.dupe(u8, "transcript cleared") };
}

fn handleAbort(ctx: CommandContext, command: Command) !CommandResult {
    _ = command;
    const active = ctx.state.status.streaming or
        (ctx.runtime != null and ctx.runtime.?.stream_active);
    if (active) {
        if (ctx.session) |session| {
            session.cancel();
            session.clearQueuedMessages();
        } else if (ctx.runtime) |runtime| {
            runtime.cancel();
            runtime.clearQueuedMessages();
        } else {
            return .{ .output = try ctx.allocator.dupe(u8, "Nothing to abort — agent is idle.") };
        }
        ctx.state.status.streaming = false;
        ctx.state.stream_aborted = true;
        ctx.state.clearPendingSteers();
        if (ctx.state.mode == .approval) {
            ctx.state.approval.deinit(ctx.allocator);
            ctx.state.mode = .normal;
        }
        return .{ .output = try ctx.allocator.dupe(u8, "Turn aborted.") };
    }
    return .{ .output = try ctx.allocator.dupe(u8, "Nothing to abort — agent is idle.") };
}

fn handleQuit(ctx: CommandContext, command: Command) !CommandResult {
    _ = ctx;
    _ = command;
    return .{ .action = .quit };
}

fn currentModel(ctx: CommandContext) ?ai_types.Model {
    if (ctx.session) |session| return session.currentModel();
    if (ctx.runtime) |runtime| return runtime.currentModel();
    return null;
}

test "parse model command with argument" {
    const command = try parse("/model gpt-4o");
    try std.testing.expectEqual(CommandKind.model, command.kind);
    try std.testing.expectEqualStrings("gpt-4o", command.arg.?);
}

test "parse abort command" {
    const command = try parse("/abort");
    try std.testing.expectEqual(CommandKind.abort, command.kind);
}

test "parse unknown command returns unknown message" {
    var parsed = try parseOrMessage(std.testing.allocator, "/unknown");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed == .message);
    try std.testing.expect(std.mem.indexOf(u8, parsed.message, "unknown command") != null);
}

test "help output contains all command names" {
    const text = try helpText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    for (&commands) |info| {
        const needle = try std.fmt.allocPrint(std.testing.allocator, "/{s}", .{info.name});
        defer std.testing.allocator.free(needle);
        try std.testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }
}

test "dispatch reaches command handlers" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.status.setModel(std.testing.allocator, "model-a", "provider-a");
    try state.addSession("s1", "Saved");
    _ = try state.resolveToolOccurrenceForTest("t1", "file_write", "{}", .live_intent, .done);

    const ctx = CommandContext{ .allocator = std.testing.allocator, .state = &state };
    const kinds = [_]CommandKind{ .help, .status, .@"resume", .permissions, .clear, .abort, .quit };
    for (kinds) |kind| {
        var result = try dispatch(ctx, .{ .kind = kind });
        defer result.deinit(std.testing.allocator);
        if (kind == .quit) {
            try std.testing.expectEqual(CommandAction.quit, result.action);
        } else if (kind == .clear) {
            try std.testing.expectEqual(CommandAction.clear_transcript, result.action);
        } else if (kind == .@"resume") {
            try std.testing.expectEqual(CommandAction.open_session_picker, result.action);
        } else if (kind == .permissions) {
            try std.testing.expectEqual(CommandAction.open_permission_picker, result.action);
        } else {
            try std.testing.expect(result.output.len > 0);
        }
    }
}

test "login command can target a provider directly" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state }, .{ .kind = .login, .arg = "openai-codex" });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(CommandAction.start_login_provider, result.action);
    try std.testing.expectEqualStrings("openai-codex", result.login_provider);
}

test "resume opens the session picker when sessions exist" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.addSession("s1", "Saved");

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state }, .{ .kind = .@"resume" });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(CommandAction.open_session_picker, result.action);
}

test "sessions alias parses to resume" {
    const command = try parse("/sessions");
    try std.testing.expectEqual(CommandKind.@"resume", command.kind);
}

test "resume reports empty store" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state }, .{ .kind = .@"resume" });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "no saved sessions") != null);
}

test "permissions opens picker without argument" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state }, .{ .kind = .permissions });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(CommandAction.open_permission_picker, result.action);
}

test "permissions command switches runtime mode" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    var runtime = try tui_runtime.TuiRuntime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    try std.testing.expectEqual(tui_runtime.PermissionMode.bypass, runtime.permissionMode());
    try std.testing.expectEqual(tui_runtime.PermissionMode.bypass, state.permission_mode);

    var bypass = try dispatch(.{ .allocator = std.testing.allocator, .state = &state, .runtime = &runtime }, .{ .kind = .permissions, .arg = "bypass" });
    defer bypass.deinit(std.testing.allocator);
    try std.testing.expectEqual(tui_runtime.PermissionMode.bypass, runtime.permissionMode());
    try std.testing.expectEqual(tui_runtime.PermissionMode.bypass, state.permission_mode);
    try std.testing.expect(std.mem.indexOf(u8, bypass.output, "permission mode set to bypass") != null);

    var ask = try dispatch(.{ .allocator = std.testing.allocator, .state = &state, .runtime = &runtime }, .{ .kind = .permissions, .arg = "ask" });
    defer ask.deinit(std.testing.allocator);
    try std.testing.expectEqual(tui_runtime.PermissionMode.ask, runtime.permissionMode());
    try std.testing.expectEqual(tui_runtime.PermissionMode.ask, state.permission_mode);
}

test "perm alias parses as permissions command" {
    const command = try parse("/perm ask");
    try std.testing.expectEqual(CommandKind.permissions, command.kind);
    try std.testing.expectEqualStrings("ask", command.arg.?);
}

test "runtime dependent commands dispatch to no-runtime errors" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    const ctx = CommandContext{ .allocator = std.testing.allocator, .state = &state };
    try std.testing.expectError(error.NoRuntimeConfigured, dispatch(ctx, .{ .kind = .model, .arg = "model-a" }));
    try std.testing.expectError(error.NoRuntimeConfigured, dispatch(ctx, .{ .kind = .provider }));
}

test "abort when idle reports idle" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state }, .{ .kind = .abort });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Nothing to abort — agent is idle.", result.output);
    try std.testing.expect(!state.status.streaming);
}

test "abort when streaming cancels session" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.status.streaming = true;

    var mock = MockAbortSession{};
    defer mock.deinit();
    var session = mock.session();

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state, .session = &session }, .{ .kind = .abort });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Turn aborted.", result.output);
    try std.testing.expect(!state.status.streaming);
    try std.testing.expect(state.stream_aborted);
    try std.testing.expectEqual(@as(usize, 1), mock.cancel_count);
}

test "abort when streaming drops queued steers but keeps their echoes" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.status.streaming = true;
    try state.appendSteeredMessage("steer before abort");

    var mock = MockAbortSession{};
    defer mock.deinit();
    var session = mock.session();

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state, .session = &session }, .{ .kind = .abort });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Turn aborted.", result.output);
    try std.testing.expectEqual(@as(usize, 1), mock.clear_count);
    try std.testing.expectEqual(@as(usize, 0), state.pending_steers.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqualStrings("steer before abort", state.transcript.items[0].text.items);
}

test "abort cancels active turn before streaming status is set" {
    var runtime = try tui_runtime.TuiRuntime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    runtime.stream_active = true;

    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state, .runtime = &runtime }, .{ .kind = .abort });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Turn aborted.", result.output);
    try std.testing.expect(!state.status.streaming);
    try std.testing.expect(state.stream_aborted);
    try std.testing.expect(runtime.cancelled.load(.acquire));
}

test "abort during approval clears approval state" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.status.streaming = true;
    state.mode = .approval;
    try state.approval.setPending(std.testing.allocator, "call-1", "edit_file", "edit_file", "{\"path\":\"README.md\"}");

    var mock = MockAbortSession{};
    defer mock.deinit();
    var session = mock.session();

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state, .session = &session }, .{ .kind = .abort });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Turn aborted.", result.output);
    try std.testing.expectEqual(tui_state.AppMode.normal, state.mode);
    try std.testing.expectEqual(tui_state.ApprovalStatus.none, state.approval.status);
    try std.testing.expectEqual(@as(usize, 1), mock.cancel_count);
}

test "double abort is harmless after first cancellation" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    state.status.streaming = true;

    var mock = MockAbortSession{};
    defer mock.deinit();
    var session = mock.session();

    var first = try dispatch(.{ .allocator = std.testing.allocator, .state = &state, .session = &session }, .{ .kind = .abort });
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Turn aborted.", first.output);
    try std.testing.expectEqual(@as(usize, 1), mock.cancel_count);

    var second = try dispatch(.{ .allocator = std.testing.allocator, .state = &state, .session = &session }, .{ .kind = .abort });
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Nothing to abort — agent is idle.", second.output);
    try std.testing.expectEqual(@as(usize, 1), mock.cancel_count);
}

const MockAbortSession = struct {
    cancel_count: usize = 0,
    clear_count: usize = 0,
    steers_consumed: u64 = 0,
    events: tui_runtime.TuiEventStream = undefined,
    events_initialized: bool = false,

    fn session(self: *MockAbortSession) tui_runtime.TuiSession {
        return .{
            .ctx = self,
            .ops = .{
                .start = mockStart,
                .resume_session = mockResumeSession,
                .cancel = mockCancel,
                .submit_turn = mockSubmitTurn,
                .steer = mockSteer,
                .clear_queued_messages = mockClearQueuedMessages,
                .queued_counts = mockQueuedCounts,
                .steers_consumed = mockSteersConsumed,
                .can_steer = mockCanSteer,
                .switch_model = mockSwitchModel,
                .current_model = mockCurrentModel,
                .decide_tool_approval = mockDecideToolApproval,
                .stream_events = mockStreamEvents,
            },
        };
    }

    fn ptr(ctx: ?*anyopaque) *MockAbortSession {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn mockStart(ctx: ?*anyopaque) anyerror!void {
        _ = ctx;
    }

    fn mockResumeSession(ctx: ?*anyopaque) anyerror!void {
        _ = ctx;
    }

    fn mockCancel(ctx: ?*anyopaque) void {
        ptr(ctx).cancel_count += 1;
    }

    fn mockSubmitTurn(ctx: ?*anyopaque, text: []const u8) anyerror!void {
        _ = ctx;
        _ = text;
    }

    fn mockSteer(ctx: ?*anyopaque, text: []const u8) anyerror!void {
        _ = ctx;
        _ = text;
    }

    fn mockClearQueuedMessages(ctx: ?*anyopaque) void {
        ptr(ctx).clear_count += 1;
    }

    fn mockQueuedCounts(ctx: ?*anyopaque) tui_runtime.QueuedCounts {
        _ = ctx;
        return .{};
    }

    fn mockSteersConsumed(ctx: ?*anyopaque) u64 {
        return ptr(ctx).steers_consumed;
    }

    fn mockCanSteer(ctx: ?*anyopaque) bool {
        _ = ctx;
        return false;
    }

    fn mockSwitchModel(ctx: ?*anyopaque, model_id: []const u8) anyerror!void {
        _ = ctx;
        _ = model_id;
    }

    fn mockCurrentModel(ctx: ?*anyopaque) ?ai_types.Model {
        _ = ctx;
        return null;
    }

    fn mockDecideToolApproval(ctx: ?*anyopaque, tool_call_id: []const u8, decision: tui_runtime.ToolApprovalDecision) anyerror!void {
        _ = ctx;
        _ = tool_call_id;
        _ = decision;
    }

    fn eventStream(self: *MockAbortSession) *tui_runtime.TuiEventStream {
        if (!self.events_initialized) {
            self.events = tui_runtime.TuiEventStream.init(std.testing.allocator);
            self.events_initialized = true;
        }
        return &self.events;
    }

    fn mockStreamEvents(ctx: ?*anyopaque) *tui_runtime.TuiEventStream {
        return ptr(ctx).eventStream();
    }

    fn deinit(self: *MockAbortSession) void {
        if (self.events_initialized) self.events.deinit();
    }
};
