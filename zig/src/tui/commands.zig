const std = @import("std");
const ai_types = @import("ai_types");
const compat = @import("compat");
const tui_runtime = @import("tui_runtime");
const tui_state = @import("tui_state");
const tui_config = @import("tui_config");
const sse_transport = @import("transports/sse");

pub const CommandKind = enum {
    help,
    model,
    login,
    provider,
    status,
    sessions,
    @"resume",
    tools,
    permissions,
    think,
    view,
    compact,
    clear,
    copy,
    artifact,
    diff,
    abort,
    quit,
    remote,
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
    open_view_picker,
    open_thinking_picker,
    start_login_provider,
    copy_last,
    copy_all,
    open_artifact_viewer,
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
    .{ .name = "sessions", .kind = .sessions, .usage = "/sessions", .description = "List saved sessions", .handler = handleSessions },
    .{ .name = "resume", .kind = .@"resume", .usage = "/resume", .description = "Open saved sessions", .handler = handleResume },
    .{ .name = "tools", .kind = .tools, .usage = "/tools", .description = "List registered tools", .handler = handleTools },
    .{ .name = "permissions", .kind = .permissions, .usage = "/permissions [ask|bypass]", .description = "Pick or set tool permission mode", .handler = handlePermissions },
    .{ .name = "perm", .kind = .permissions, .usage = "/perm [ask|bypass]", .description = "Pick or set tool permission mode", .handler = handlePermissions },
    .{ .name = "think", .kind = .think, .usage = "/think [off|low|medium|high|xhigh]", .description = "Pick or set thinking level", .handler = handleThink },
    .{ .name = "view", .kind = .view, .usage = "/view [everything|verbose|balanced|chat]", .description = "Show or set transcript detail level", .handler = handleView },
    .{ .name = "compact", .kind = .compact, .usage = "/compact", .description = "Compact conversation context", .handler = handleCompact },
    .{ .name = "clear", .kind = .clear, .usage = "/clear", .description = "Clear transcript display", .handler = handleClear },
    .{ .name = "copy", .kind = .copy, .usage = "/copy [all]", .description = "Copy last reply (or whole transcript) to clipboard", .handler = handleCopy },
    .{ .name = "artifact", .kind = .artifact, .usage = "/artifact", .description = "Open the latest artifact in a local viewer", .handler = handleArtifact },
    .{ .name = "diff", .kind = .diff, .usage = "/diff", .description = "Show pending file changes", .handler = handleDiff },
    .{ .name = "abort", .kind = .abort, .usage = "/abort", .description = "Cancel the active streaming turn", .handler = handleAbort },
    .{ .name = "quit", .kind = .quit, .usage = "/quit", .description = "Exit TUI", .handler = handleQuit },
    .{ .name = "remote", .kind = .remote, .usage = "/remote [stdio|sse <url>|ws <url>|auth <token>|header <name> <value>|off]", .description = "Configure remote transport", .handler = handleRemote },
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
    // No argument: open the interactive picker instead of dumping a list.
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
    // Sessions are loaded by App.loadSessions() before dispatch.
    // Return the open_session_picker action so App can switch mode.
    if (ctx.state.sessions.items.len == 0) {
        return .{ .output = try ctx.allocator.dupe(u8, "no saved sessions") };
    }
    return .{ .action = .open_session_picker };
}

fn handleResume(ctx: CommandContext, command: Command) !CommandResult {
    return try handleSessions(ctx, command);
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

fn handleView(ctx: CommandContext, command: Command) !CommandResult {
    if (command.arg) |arg| {
        const mode = parseTranscriptMode(arg) orelse {
            return .{
                .output = try std.fmt.allocPrint(ctx.allocator, "unknown view mode: {s}", .{arg}),
                .is_error = true,
            };
        };
        ctx.state.setTranscriptMode(mode);
        return .{ .output = try std.fmt.allocPrint(ctx.allocator, "view mode set to {s}", .{@tagName(mode)}) };
    }
    return .{ .action = .open_view_picker };
}

fn parseTranscriptMode(value: []const u8) ?tui_state.TranscriptVisibilityMode {
    if (std.mem.eql(u8, value, "everything")) return .everything;
    if (std.mem.eql(u8, value, "verbose")) return .verbose;
    if (std.mem.eql(u8, value, "balanced")) return .balanced;
    if (std.mem.eql(u8, value, "chat")) return .chat;
    return null;
}

fn handleThink(ctx: CommandContext, command: Command) !CommandResult {
    if (command.arg) |arg| {
        const level = parseThinkingLevel(arg) orelse {
            return .{
                .output = try std.fmt.allocPrint(ctx.allocator, "unknown thinking level: {s}", .{arg}),
                .is_error = true,
            };
        };
        if (ctx.runtime) |runtime| runtime.setThinkingLevel(level);
        ctx.state.thinking_level = level;
        return .{ .output = try std.fmt.allocPrint(ctx.allocator, "thinking level set to {s}", .{@tagName(level)}) };
    }
    if (ctx.runtime) |runtime| ctx.state.thinking_level = runtime.thinkingLevel();
    return .{ .action = .open_thinking_picker };
}

fn parseThinkingLevel(value: []const u8) ?ai_types.ThinkingLevel {
    if (std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "none") or std.mem.eql(u8, value, "disabled")) return .off;
    if (std.mem.eql(u8, value, "minimal") or std.mem.eql(u8, value, "min")) return .low;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium") or std.mem.eql(u8, value, "med")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh") or std.mem.eql(u8, value, "max") or std.mem.eql(u8, value, "extra_high") or std.mem.eql(u8, value, "extra-high")) return .xhigh;
    return null;
}

fn handleCompact(ctx: CommandContext, command: Command) !CommandResult {
    _ = command;
    const session = ctx.session orelse return error.NoRuntimeConfigured;
    const result = try session.compactMessages();
    const output = if (result.before == result.after)
        try std.fmt.allocPrint(ctx.allocator, "conversation context already compact ({d} messages)", .{result.before})
    else
        try std.fmt.allocPrint(ctx.allocator, "conversation context compacted: {d} -> {d} messages", .{ result.before, result.after });
    return .{ .output = output };
}

fn handleClear(ctx: CommandContext, command: Command) !CommandResult {
    _ = command;
    return .{ .action = .clear_transcript, .output = try ctx.allocator.dupe(u8, "transcript cleared") };
}

fn handleCopy(ctx: CommandContext, command: Command) !CommandResult {
    _ = ctx;
    // The app stages the clipboard write and reports status itself, so no output.
    if (command.arg) |arg| {
        if (std.mem.eql(u8, std.mem.trim(u8, arg, " \t"), "all")) {
            return .{ .action = .copy_all };
        }
    }
    return .{ .action = .copy_last };
}

fn handleArtifact(ctx: CommandContext, command: Command) !CommandResult {
    _ = ctx;
    _ = command;
    return .{ .action = .open_artifact_viewer };
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

fn handleAbort(ctx: CommandContext, command: Command) !CommandResult {
    _ = command;
    const active = ctx.state.status.streaming or
        (ctx.runtime != null and ctx.runtime.?.stream_active);
    if (active) {
        if (ctx.session) |session| {
            session.cancel();
        } else if (ctx.runtime) |runtime| {
            runtime.cancel();
        } else {
            return .{ .output = try ctx.allocator.dupe(u8, "Nothing to abort — agent is idle.") };
        }
        ctx.state.status.streaming = false;
        ctx.state.stream_aborted = true;
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

fn handleRemote(ctx: CommandContext, command: Command) !CommandResult {
    var store = try tui_config.Store.initDefault(ctx.allocator);
    defer store.deinit();
    return try applyRemoteCommand(ctx.allocator, store, command.arg);
}

fn applyRemoteCommand(allocator: std.mem.Allocator, store: tui_config.Store, arg: ?[]const u8) !CommandResult {
    var cfg = try store.load();
    defer cfg.deinit(allocator);

    var restart_notice = false;
    if (arg) |value| {
        var iter = std.mem.splitScalar(u8, value, ' ');
        const sub = iter.first();
        const rest = std.mem.trim(u8, iter.rest(), " \t");

        if (std.mem.eql(u8, sub, "stdio")) {
            if (rest.len > 0) {
                return .{ .output = try allocator.dupe(u8, "stdio transport uses the current process; no command argument is supported"), .is_error = true };
            }
            // stdio remote would bind the agent protocol to the TUI's own
            // stdin/stdout. Until subprocess spawning is wired up, persist the
            // transport preference but do not enable remote mode.
            cfg.remote.enabled = false;
            try replaceRemoteString(allocator, &cfg.remote.transport, "stdio");
            try replaceRemoteString(allocator, &cfg.remote.command, "");
            try replaceRemoteString(allocator, &cfg.remote.endpoint, "");
        } else if (std.mem.eql(u8, sub, "sse")) {
            if (rest.len == 0) {
                return .{ .output = try allocator.dupe(u8, "usage: /remote sse <url>"), .is_error = true };
            }
            validateUrlScheme(rest, &.{"http"}) catch {
                return .{ .output = try allocator.dupe(u8, "SSE endpoint must use http scheme (TLS not yet supported)"), .is_error = true };
            };
            cfg.remote.enabled = true;
            try replaceRemoteString(allocator, &cfg.remote.transport, "sse");
            try replaceRemoteString(allocator, &cfg.remote.endpoint, rest);
            try replaceRemoteString(allocator, &cfg.remote.command, "");
        } else if (std.mem.eql(u8, sub, "ws") or std.mem.eql(u8, sub, "websocket")) {
            if (rest.len == 0) {
                return .{ .output = try allocator.dupe(u8, "usage: /remote ws <url>"), .is_error = true };
            }
            validateUrlScheme(rest, &.{ "ws", "wss" }) catch {
                return .{ .output = try allocator.dupe(u8, "WebSocket endpoint must use ws or wss scheme"), .is_error = true };
            };
            return .{ .output = try allocator.dupe(u8, "WebSocket remote transport is not yet supported"), .is_error = true };
        } else if (std.mem.eql(u8, sub, "auth")) {
            if (rest.len == 0) {
                return .{ .output = try allocator.dupe(u8, "usage: /remote auth <token>"), .is_error = true };
            }
            try replaceRemoteString(allocator, &cfg.remote.auth_token, rest);
            try replaceRemoteString(allocator, &cfg.remote.auth_header_value, "");
        } else if (std.mem.eql(u8, sub, "header")) {
            const trimmed = std.mem.trim(u8, rest, " \t");
            var hiter = std.mem.splitScalar(u8, trimmed, ' ');
            const name = hiter.first();
            const header_value = std.mem.trim(u8, hiter.rest(), " \t");
            if (name.len == 0 or header_value.len == 0) {
                return .{ .output = try allocator.dupe(u8, "usage: /remote header <name> <value>"), .is_error = true };
            }
            try replaceRemoteString(allocator, &cfg.remote.auth_token, "");
            try replaceRemoteString(allocator, &cfg.remote.auth_header_name, name);
            try replaceRemoteString(allocator, &cfg.remote.auth_header_value, header_value);
        } else if (std.mem.eql(u8, sub, "off")) {
            cfg.remote.enabled = false;
            restart_notice = true;
        } else {
            return .{ .output = try std.fmt.allocPrint(allocator, "unknown remote subcommand: {s}", .{sub}), .is_error = true };
        }
        try store.save(cfg);
    }

    if (restart_notice) {
        const status = try formatRemoteStatus(allocator, cfg.remote);
        defer allocator.free(status);
        return .{ .output = try std.fmt.allocPrint(allocator, "{s}\nNote: change applies on next TUI start; active remote sessions keep using the current runtime.", .{status}) };
    }

    return .{ .output = try formatRemoteStatus(allocator, cfg.remote) };
}

fn replaceRemoteString(allocator: std.mem.Allocator, field: *[]u8, value: []const u8) !void {
    const next = try allocator.dupe(u8, value);
    if (field.len > 0) allocator.free(field.*);
    field.* = next;
}

fn validateUrlScheme(url: []const u8, schemes: []const []const u8) !void {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidUrl;
    const scheme = url[0..scheme_end];
    var matched = false;
    for (schemes) |allowed| {
        if (std.mem.eql(u8, scheme, allowed)) {
            matched = true;
            break;
        }
    }
    if (!matched) return error.InvalidUrl;

    if (std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "https")) {
        _ = sse_transport.parseHttpUrl(url) catch return error.InvalidUrl;
        return;
    }

    const after = url[scheme_end + 3 ..];
    var auth_end: usize = 0;
    while (auth_end < after.len and after[auth_end] != '/' and after[auth_end] != '?' and after[auth_end] != '#') : (auth_end += 1) {}
    const authority = after[0..auth_end];
    if (authority.len == 0) return error.InvalidUrl;
    var host = authority;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| host = authority[at + 1 ..];
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
    if (host.len == 0) return error.InvalidUrl;
}

fn formatRemoteStatus(allocator: std.mem.Allocator, remote: tui_config.RemoteConfig) ![]u8 {
    const status = if (remote.enabled) "enabled" else "disabled";
    const auth = if (remote.auth_token.len > 0 or remote.auth_header_value.len > 0) "yes" else "no";
    return try std.fmt.allocPrint(allocator, "remote {s}\ntransport: {s}\nendpoint: {s}\ncommand: {s}\nauth: {s}", .{
        status,
        remote.transport,
        remote.endpoint,
        remote.command,
        auth,
    });
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
    _ = try state.upsertToolForTest("t1", "file_write", "{}", .done);

    const ctx = CommandContext{ .allocator = std.testing.allocator, .state = &state };
    const kinds = [_]CommandKind{ .help, .status, .sessions, .permissions, .think, .view, .clear, .diff, .abort, .quit };
    for (kinds) |kind| {
        var result = try dispatch(ctx, .{ .kind = kind });
        defer result.deinit(std.testing.allocator);
        if (kind == .quit) {
            try std.testing.expectEqual(CommandAction.quit, result.action);
        } else if (kind == .clear) {
            try std.testing.expectEqual(CommandAction.clear_transcript, result.action);
        } else if (kind == .sessions) {
            try std.testing.expectEqual(CommandAction.open_session_picker, result.action);
        } else if (kind == .permissions) {
            try std.testing.expectEqual(CommandAction.open_permission_picker, result.action);
        } else if (kind == .think) {
            try std.testing.expectEqual(CommandAction.open_thinking_picker, result.action);
        } else if (kind == .view) {
            try std.testing.expectEqual(CommandAction.open_view_picker, result.action);
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

test "resume is an alias for sessions" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.addSession("s1", "Saved");

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state }, .{ .kind = .@"resume" });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(CommandAction.open_session_picker, result.action);
}

const CompactCommandSession = struct {
    before: usize = 12,
    after: usize = 9,
    compact_count: usize = 0,

    fn session(self: *CompactCommandSession) tui_runtime.TuiSession {
        return .{
            .ctx = self,
            .ops = .{
                .compact_messages = compactMessages,
                .can_steer = canSteer,
            },
        };
    }

    fn canSteer(ctx: ?*anyopaque) bool {
        _ = ctx;
        return false;
    }

    fn compactMessages(ctx: ?*anyopaque) anyerror!tui_runtime.CompactMessagesResult {
        const self: *CompactCommandSession = @ptrCast(@alignCast(ctx.?));
        self.compact_count += 1;
        return .{ .before = self.before, .after = self.after };
    }
};

test "compact command compacts session history" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    var compact = CompactCommandSession{};
    var session = compact.session();

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state, .session = &session }, .{ .kind = .compact });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), compact.compact_count);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "12 -> 9") != null);
}

test "sessions opens picker when sessions exist" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.addSession("s1", "Saved");

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state }, .{ .kind = .sessions });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(CommandAction.open_session_picker, result.action);
}

test "sessions reports empty store" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state }, .{ .kind = .sessions });
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

test "view command switches transcript visibility mode" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();

    var result = try dispatch(.{ .allocator = std.testing.allocator, .state = &state }, .{ .kind = .view, .arg = "chat" });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(tui_state.TranscriptVisibilityMode.chat, state.transcript_mode);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "chat") != null);

    var current = try dispatch(.{ .allocator = std.testing.allocator, .state = &state }, .{ .kind = .view });
    defer current.deinit(std.testing.allocator);
    try std.testing.expectEqual(CommandAction.open_view_picker, current.action);

    var legacy = try dispatch(.{ .allocator = std.testing.allocator, .state = &state }, .{ .kind = .view, .arg = "normal" });
    defer legacy.deinit(std.testing.allocator);
    try std.testing.expect(legacy.is_error);
    try std.testing.expect(std.mem.indexOf(u8, legacy.output, "unknown view mode") != null);
}

test "think command switches thinking level and opens picker without argument" {
    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    var runtime = try tui_runtime.TuiRuntime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var high = try dispatch(.{ .allocator = std.testing.allocator, .state = &state, .runtime = &runtime }, .{ .kind = .think, .arg = "high" });
    defer high.deinit(std.testing.allocator);
    try std.testing.expectEqual(ai_types.ThinkingLevel.high, state.thinking_level);
    try std.testing.expectEqual(ai_types.ThinkingLevel.high, runtime.thinkingLevel());
    try std.testing.expect(std.mem.indexOf(u8, high.output, "thinking level set to high") != null);

    var picker = try dispatch(.{ .allocator = std.testing.allocator, .state = &state, .runtime = &runtime }, .{ .kind = .think });
    defer picker.deinit(std.testing.allocator);
    try std.testing.expectEqual(CommandAction.open_thinking_picker, picker.action);
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
    try std.testing.expectError(error.NoRuntimeConfigured, dispatch(ctx, .{ .kind = .tools }));
    try std.testing.expectError(error.NoRuntimeConfigured, dispatch(ctx, .{ .kind = .compact }));
}

test "copy command selects last reply or whole transcript" {
    try std.testing.expectEqual(CommandKind.copy, (try parse("/copy")).kind);

    var state = tui_state.AppState.init(std.testing.allocator);
    defer state.deinit();
    const ctx = CommandContext{ .allocator = std.testing.allocator, .state = &state };

    var last = try dispatch(ctx, .{ .kind = .copy });
    defer last.deinit(std.testing.allocator);
    try std.testing.expectEqual(CommandAction.copy_last, last.action);

    var all = try dispatch(ctx, .{ .kind = .copy, .arg = "all" });
    defer all.deinit(std.testing.allocator);
    try std.testing.expectEqual(CommandAction.copy_all, all.action);
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

test "abort cancels active turn before streaming status is set" {
    var runtime = try tui_runtime.TuiRuntime.init(std.testing.allocator, .{ .backend = .local });
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
                .queue_follow_up = mockQueueFollowUp,
                .clear_queued_messages = mockClearQueuedMessages,
                .queued_counts = mockQueuedCounts,
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

    fn mockQueueFollowUp(ctx: ?*anyopaque, text: []const u8) anyerror!void {
        _ = ctx;
        _ = text;
    }

    fn mockClearQueuedMessages(ctx: ?*anyopaque) void {
        _ = ctx;
    }

    fn mockQueuedCounts(ctx: ?*anyopaque) tui_runtime.QueuedCounts {
        _ = ctx;
        return .{};
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

fn remoteTestStore(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) !tui_config.Store {
    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "makai" });
    defer allocator.free(base);
    try compat.fs.createDir(compat.fs.getCwd(), base);
    return try tui_config.Store.init(allocator, base);
}

test "remote command sets sse transport and persists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var result = try applyRemoteCommand(std.testing.allocator, store, "sse http://localhost:8080");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "transport: sse") != null);

    var loaded = try store.load();
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(loaded.remote.enabled);
    try std.testing.expectEqualStrings("sse", loaded.remote.transport);
    try std.testing.expectEqualStrings("http://localhost:8080", loaded.remote.endpoint);
}

test "remote command rejects invalid sse endpoint scheme" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var result = try applyRemoteCommand(std.testing.allocator, store, "sse ftp://localhost:8080");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SSE endpoint must use http scheme") != null);
}

test "remote command rejects https sse endpoint until TLS supported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var result = try applyRemoteCommand(std.testing.allocator, store, "sse https://localhost:8080");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "TLS not yet supported") != null);

    var loaded = try store.load();
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(!loaded.remote.enabled);
}

test "remote command rejects unsupported websocket transport" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var result = try applyRemoteCommand(std.testing.allocator, store, "ws ws://localhost:8080");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "WebSocket remote transport is not yet supported") != null);
}

test "remote command rejects invalid websocket endpoint scheme" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var result = try applyRemoteCommand(std.testing.allocator, store, "ws http://localhost:8080");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "WebSocket endpoint must use ws or wss scheme") != null);
}

test "remote command sets auth token and persists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var result = try applyRemoteCommand(std.testing.allocator, store, "auth secret-token");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);

    var loaded = try store.load();
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("secret-token", loaded.remote.auth_token);
}

test "remote command shows current config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var result = try applyRemoteCommand(std.testing.allocator, store, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "remote") != null);
}

test "remote command parses as slash command" {
    const command = try parse("/remote sse http://localhost:8080");
    try std.testing.expectEqual(CommandKind.remote, command.kind);
    try std.testing.expectEqualStrings("sse http://localhost:8080", command.arg.?);
}

test "remote command sets stdio transport without enabling remote" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var result = try applyRemoteCommand(std.testing.allocator, store, "stdio");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "transport: stdio") != null);

    var loaded = try store.load();
    defer loaded.deinit(std.testing.allocator);
    // stdio remote would hijack the TUI's own stdio; keep it disabled until
    // subprocess spawning is implemented.
    try std.testing.expect(!loaded.remote.enabled);
    try std.testing.expectEqualStrings("stdio", loaded.remote.transport);
    try std.testing.expectEqualStrings("", loaded.remote.command);
    try std.testing.expectEqualStrings("", loaded.remote.endpoint);
}

test "remote command stdio rejects command argument" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var result = try applyRemoteCommand(std.testing.allocator, store, "stdio /bin/foo");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "no command argument is supported") != null);
}

test "remote command off disables remote" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var sse_result = try applyRemoteCommand(std.testing.allocator, store, "sse http://localhost:8080");
    defer sse_result.deinit(std.testing.allocator);
    try std.testing.expect(!sse_result.is_error);

    var off_result = try applyRemoteCommand(std.testing.allocator, store, "off");
    defer off_result.deinit(std.testing.allocator);
    try std.testing.expect(!off_result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, off_result.output, "disabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, off_result.output, "applies on next TUI start") != null);

    var loaded = try store.load();
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(!loaded.remote.enabled);
    try std.testing.expectEqualStrings("sse", loaded.remote.transport);
}

test "remote command header sets header and clears auth token" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var auth_result = try applyRemoteCommand(std.testing.allocator, store, "auth secret-token");
    defer auth_result.deinit(std.testing.allocator);
    try std.testing.expect(!auth_result.is_error);

    var header_result = try applyRemoteCommand(std.testing.allocator, store, "header X-Api-Key abc123");
    defer header_result.deinit(std.testing.allocator);
    try std.testing.expect(!header_result.is_error);

    var loaded = try store.load();
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", loaded.remote.auth_token);
    try std.testing.expectEqualStrings("X-Api-Key", loaded.remote.auth_header_name);
    try std.testing.expectEqualStrings("abc123", loaded.remote.auth_header_value);
}

test "remote command rejects unknown subcommand" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var result = try applyRemoteCommand(std.testing.allocator, store, "bogus");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "unknown remote subcommand: bogus") != null);
}

test "remote command rejects sse endpoint with empty host" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var result = try applyRemoteCommand(std.testing.allocator, store, "sse http://");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SSE endpoint must use http scheme") != null);
}

test "remote command rejects sse endpoint with path-only authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var result = try applyRemoteCommand(std.testing.allocator, store, "sse http:///events");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);

    var loaded = try store.load();
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(!loaded.remote.enabled);
}

test "remote command rejects sse endpoint with port-only authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var result = try applyRemoteCommand(std.testing.allocator, store, "sse http://:8080");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);

    var loaded = try store.load();
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(!loaded.remote.enabled);
}

test "remote command rejects sse endpoint with malformed port" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var result = try applyRemoteCommand(std.testing.allocator, store, "sse http://localhost:abc");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);

    var loaded = try store.load();
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(!loaded.remote.enabled);
}

test "remote command rejects sse endpoint with out-of-range port" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try remoteTestStore(std.testing.allocator, &tmp);
    defer store.deinit();

    var result = try applyRemoteCommand(std.testing.allocator, store, "sse http://localhost:70000");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);

    var loaded = try store.load();
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(!loaded.remote.enabled);
}

