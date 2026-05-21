const std = @import("std");
const ai_types = @import("ai_types");
const tui_runtime = @import("tui_runtime");
const tui_state = @import("tui_state");

pub const CommandKind = enum {
    help,
    model,
    provider,
    status,
    sessions,
    @"resume",
    tools,
    permissions,
    compact,
    clear,
    diff,
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
};

pub const CommandResult = struct {
    action: CommandAction = .none,
    output: []u8 = &.{},
    is_error: bool = false,

    pub fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
        if (self.output.len > 0) allocator.free(self.output);
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
    .{ .name = "model", .kind = .model, .usage = "/model [name]", .description = "Show or switch active model", .handler = handleModel },
    .{ .name = "provider", .kind = .provider, .usage = "/provider [name]", .description = "Show or switch active provider", .handler = handleProvider },
    .{ .name = "status", .kind = .status, .usage = "/status", .description = "Show session status", .handler = handleStatus },
    .{ .name = "sessions", .kind = .sessions, .usage = "/sessions", .description = "List saved sessions", .handler = handleSessions },
    .{ .name = "resume", .kind = .@"resume", .usage = "/resume [id]", .description = "Resume saved session", .handler = handleResume },
    .{ .name = "tools", .kind = .tools, .usage = "/tools", .description = "List registered tools", .handler = handleTools },
    .{ .name = "permissions", .kind = .permissions, .usage = "/permissions", .description = "Show tool permission policies", .handler = handlePermissions },
    .{ .name = "compact", .kind = .compact, .usage = "/compact", .description = "Compact conversation context", .handler = handleCompact },
    .{ .name = "clear", .kind = .clear, .usage = "/clear", .description = "Clear transcript display", .handler = handleClear },
    .{ .name = "diff", .kind = .diff, .usage = "/diff", .description = "Show pending file changes", .handler = handleDiff },
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

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    const writer = &out.writer;
    if (currentModel(ctx)) |model| {
        try writer.print("current model: {s} ({s})\n", .{ model.id, model.provider });
    } else {
        try writer.writeAll("current model: none\n");
    }
    if (ctx.runtime) |runtime| {
        try writer.writeAll("available models:");
        for (runtime.availableModels()) |model| try writer.print("\n  {s} ({s})", .{ model.id, model.provider });
    }
    return .{ .output = try out.toOwnedSlice() };
}

fn handleProvider(ctx: CommandContext, command: Command) !CommandResult {
    const runtime = ctx.runtime orelse return error.NoRuntimeConfigured;
    if (command.arg) |provider| {
        for (runtime.availableModels()) |model| {
            if (std.mem.eql(u8, model.provider, provider)) {
                if (ctx.session) |session| {
                    try session.switchModel(model.id);
                } else {
                    try runtime.switchModel(model.id);
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
    return .{ .output = try std.fmt.allocPrint(ctx.allocator,
        "session: {s}\nmodel: {s}\nprovider: {s}\nturns: {d}\ncontext: {d}/{d}\nstreaming: {s}",
        .{
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
    if (ctx.state.sessions.items.len == 0) return .{ .output = try ctx.allocator.dupe(u8, "no saved sessions (saved-session discovery is not wired yet)") };
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    const writer = &out.writer;
    try writer.writeAll("saved sessions:");
    for (ctx.state.sessions.items) |session| try writer.print("\n  {s}  {s}", .{ session.id, session.label });
    return .{ .output = try out.toOwnedSlice() };
}

fn handleResume(ctx: CommandContext, command: Command) !CommandResult {
    if (command.arg) |id| {
        for (ctx.state.sessions.items) |entry| {
            if (std.mem.eql(u8, entry.id, id)) {
                return .{
                    .output = try std.fmt.allocPrint(ctx.allocator, "resume by id is not wired yet: {s}", .{id}),
                    .is_error = true,
                };
            }
        }
        return error.SessionNotFound;
    }
    const session = ctx.session orelse return error.NoRuntimeConfigured;
    try session.resumeSession();
    return .{ .output = try ctx.allocator.dupe(u8, "current session resumed") };
}

fn handleTools(ctx: CommandContext, command: Command) !CommandResult {
    _ = command;
    const runtime = ctx.runtime orelse return error.NoRuntimeConfigured;
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    const writer = &out.writer;
    try writer.writeAll("registered tools:");
    for (runtime.tool_registry.list()) |tool| {
        try writer.print("\n  {s}", .{tool.name});
        if (tool.short_description) |desc| try writer.print(" - {s}", .{desc});
    }
    return .{ .output = try out.toOwnedSlice() };
}

fn handlePermissions(ctx: CommandContext, command: Command) !CommandResult {
    _ = command;
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    const writer = &out.writer;
    try writer.writeAll("tool permissions:\n");
    if (ctx.runtime) |runtime| {
        if (runtime.tool_approval_callback != null) {
            try writer.writeAll("  approval callback: configured\n");
        } else {
            try writer.writeAll("  approval callback: none (tools auto-approve unless tool policy rejects)\n");
        }
        try writer.print("  registered tools: {d}\n", .{runtime.tool_registry.list().len});
    } else {
        try writer.writeAll("  runtime: not configured\n");
    }
    try writer.print("  current approval: {s}", .{@tagName(ctx.state.approval.status)});
    if (ctx.state.approval.status == .pending) try writer.print("\n  pending tool: {s} ({s})", .{ ctx.state.approval.tool_name, ctx.state.approval.tool_call_id });
    return .{ .output = try out.toOwnedSlice() };
}

fn handleCompact(ctx: CommandContext, command: Command) !CommandResult {
    _ = command;
    return .{ .output = try ctx.allocator.dupe(u8, "compact not yet implemented") };
}

fn handleClear(ctx: CommandContext, command: Command) !CommandResult {
    _ = command;
    return .{ .action = .clear_transcript, .output = try ctx.allocator.dupe(u8, "transcript cleared") };
}

fn handleDiff(ctx: CommandContext, command: Command) !CommandResult {
    _ = command;
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    const writer = &out.writer;
    var count: usize = 0;
    for (ctx.state.tools.items) |tool| {
        if (std.mem.indexOf(u8, tool.name, "write") == null and std.mem.indexOf(u8, tool.name, "edit") == null) continue;
        if (count == 0) try writer.writeAll("pending file changes from tools:");
        try writer.print("\n  {s} [{s}]", .{ tool.name, @tagName(tool.status) });
        if (tool.output.items.len > 0) try writer.print("\n    {s}", .{tool.output.items[0..@min(tool.output.items.len, 160)]});
        count += 1;
    }
    if (count == 0) try writer.writeAll("no pending file changes");
    return .{ .output = try out.toOwnedSlice() };
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
    _ = try state.upsertToolForTest("t1", "file_write", "{}", .done);

    const ctx = CommandContext{ .allocator = std.testing.allocator, .state = &state };
    const kinds = [_]CommandKind{ .help, .status, .sessions, .permissions, .compact, .clear, .diff, .quit };
    for (kinds) |kind| {
        var result = try dispatch(ctx, .{ .kind = kind });
        defer result.deinit(std.testing.allocator);
        if (kind == .quit) {
            try std.testing.expectEqual(CommandAction.quit, result.action);
        } else if (kind == .clear) {
            try std.testing.expectEqual(CommandAction.clear_transcript, result.action);
        } else {
            try std.testing.expect(result.output.len > 0);
        }
    }
}

test "resume by id does not resume current context" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.addSession("s1", "Saved");

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state }, .{ .kind = .@"resume", .arg = "s1" });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "not wired") != null);
}

test "sessions reports discovery gap when runtime has no source" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state }, .{ .kind = .sessions });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "not wired") != null);
}

test "permissions reports runtime approval state not hardcoded policy" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state }, .{ .kind = .permissions });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "runtime: not configured") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "reads inside workspace") == null);
}

test "runtime dependent commands dispatch to no-runtime errors" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    const ctx = CommandContext{ .allocator = std.testing.allocator, .state = &state };
    try std.testing.expectError(error.NoRuntimeConfigured, dispatch(ctx, .{ .kind = .model, .arg = "model-a" }));
    try std.testing.expectError(error.NoRuntimeConfigured, dispatch(ctx, .{ .kind = .provider }));
    try std.testing.expectError(error.NoRuntimeConfigured, dispatch(ctx, .{ .kind = .tools }));
    try std.testing.expectError(error.NoRuntimeConfigured, dispatch(ctx, .{ .kind = .@"resume" }));
}
