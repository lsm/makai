const std = @import("std");
const compat = @import("compat");

pub const PermissionDecision = enum(u8) {
    allow,
    deny,
    prompt,
};

pub const ApprovalDecision = enum(u8) {
    approve,
    reject,
    approve_always,
    reject_always,
};

pub const Operation = enum(u8) {
    unknown,
    read,
    write,
    shell,
};

pub const ToolCall = struct {
    tool_name: []const u8,
    args_json: []const u8,
    operation: Operation = .unknown,
    path: ?[]const u8 = null,
    command: ?[]const u8 = null,
};

pub const ToolCallC = extern struct {
    tool_name_ptr: [*]const u8,
    tool_name_len: usize,
    args_json_ptr: [*]const u8,
    args_json_len: usize,
    operation: Operation,
    path_ptr: ?[*]const u8 = null,
    path_len: usize = 0,
    command_ptr: ?[*]const u8 = null,
    command_len: usize = 0,

    pub fn fromToolCall(call: ToolCall) ToolCallC {
        const path_value = call.path orelse "";
        const command_value = call.command orelse "";
        return .{
            .tool_name_ptr = call.tool_name.ptr,
            .tool_name_len = call.tool_name.len,
            .args_json_ptr = call.args_json.ptr,
            .args_json_len = call.args_json.len,
            .operation = call.operation,
            .path_ptr = if (call.path != null) path_value.ptr else null,
            .path_len = path_value.len,
            .command_ptr = if (call.command != null) command_value.ptr else null,
            .command_len = command_value.len,
        };
    }

    pub fn toolName(self: ToolCallC) []const u8 {
        return self.tool_name_ptr[0..self.tool_name_len];
    }

    pub fn argsJson(self: ToolCallC) []const u8 {
        return self.args_json_ptr[0..self.args_json_len];
    }

    pub fn path(self: ToolCallC) ?[]const u8 {
        const ptr = self.path_ptr orelse return null;
        return ptr[0..self.path_len];
    }

    pub fn command(self: ToolCallC) ?[]const u8 {
        const ptr = self.command_ptr orelse return null;
        return ptr[0..self.command_len];
    }
};

pub const ApprovalCallback = *const fn (ToolCallC) callconv(.c) ApprovalDecision;

const PersistedDecision = struct {
    tool_name: []u8,
    operation: Operation,
    path: ?[]u8 = null,
    command: ?[]u8 = null,
    decision: PermissionDecision,

    fn deinit(self: *PersistedDecision, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        if (self.path) |path| allocator.free(path);
        if (self.command) |command| allocator.free(command);
        self.* = undefined;
    }
};

pub const PermissionEngineOptions = struct {
    workspace_root: []const u8,
    persistence_path: ?[]const u8 = null,
    approval_callback: ?ApprovalCallback = null,
};

pub const PermissionEngine = struct {
    allocator: std.mem.Allocator,
    workspace_root: []u8,
    persistence_path: []u8,
    approval_callback: ?ApprovalCallback = null,
    persisted: std.ArrayList(PersistedDecision) = .empty,

    const Self = @This();
    const MAX_PERMISSION_FILE_BYTES = 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator, options: PermissionEngineOptions) !Self {
        const workspace_root = try allocator.dupe(u8, options.workspace_root);
        errdefer allocator.free(workspace_root);

        const persistence_path = if (options.persistence_path) |path|
            try allocator.dupe(u8, path)
        else
            try defaultPersistencePath(allocator);
        errdefer allocator.free(persistence_path);

        var engine = Self{
            .allocator = allocator,
            .workspace_root = workspace_root,
            .persistence_path = persistence_path,
            .approval_callback = options.approval_callback,
        };
        errdefer engine.deinit();
        try engine.load();
        return engine;
    }

    pub fn deinit(self: *Self) void {
        for (self.persisted.items) |*decision| decision.deinit(self.allocator);
        self.persisted.deinit(self.allocator);
        self.allocator.free(self.workspace_root);
        self.allocator.free(self.persistence_path);
        self.* = undefined;
    }

    pub fn evaluate(self: *Self, tool_name: []const u8, args_json: []const u8) PermissionDecision {
        const call = parseToolCall(self.allocator, tool_name, args_json) catch return .prompt;
        defer deinitParsedToolCall(self.allocator, call);
        return self.evaluateCall(call);
    }

    pub fn evaluateCall(self: *Self, call: ToolCall) PermissionDecision {
        if (self.findPersisted(call)) |decision| return decision;
        return self.defaultDecision(call);
    }

    pub fn approve(self: *Self, tool_name: []const u8, args_json: []const u8) !ApprovalDecision {
        const call = try parseToolCall(self.allocator, tool_name, args_json);
        defer deinitParsedToolCall(self.allocator, call);
        return try self.approveCall(call);
    }

    pub fn approveCall(self: *Self, call: ToolCall) !ApprovalDecision {
        switch (self.evaluateCall(call)) {
            .allow => return .approve,
            .deny => return .reject,
            .prompt => {},
        }

        const callback = self.approval_callback orelse return .reject;
        const decision = callback(ToolCallC.fromToolCall(call));
        switch (decision) {
            .approve_always => try self.persistDecision(call, .allow),
            .reject_always => try self.persistDecision(call, .deny),
            .approve, .reject => {},
        }
        return decision;
    }

    pub fn persistDecision(self: *Self, call: ToolCall, decision: PermissionDecision) !void {
        for (self.persisted.items) |*existing| {
            if (matchesPersisted(existing.*, call)) {
                existing.decision = decision;
                try self.save();
                return;
            }
        }

        const persisted = PersistedDecision{
            .tool_name = try self.allocator.dupe(u8, call.tool_name),
            .operation = call.operation,
            .path = if (call.path) |path| try self.allocator.dupe(u8, path) else null,
            .command = if (call.command) |command| try self.allocator.dupe(u8, command) else null,
            .decision = decision,
        };
        try self.persisted.append(self.allocator, persisted);
        try self.save();
    }

    pub fn load(self: *Self) !void {
        const content = readFileAbsolute(self.allocator, self.persistence_path, MAX_PERMISSION_FILE_BYTES) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(content);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidPermissionFile;
        const decisions_value = parsed.value.object.get("decisions") orelse return;
        if (decisions_value != .array) return error.InvalidPermissionFile;

        for (decisions_value.array.items) |item| {
            if (item != .object) return error.InvalidPermissionFile;
            const obj = item.object;
            const tool_name = getStringField(obj, "tool_name") orelse return error.InvalidPermissionFile;
            const operation_text = getStringField(obj, "operation") orelse "unknown";
            const decision_text = getStringField(obj, "decision") orelse return error.InvalidPermissionFile;
            const decision = std.meta.stringToEnum(PermissionDecision, decision_text) orelse return error.InvalidPermissionFile;
            const operation = std.meta.stringToEnum(Operation, operation_text) orelse .unknown;

            try self.persisted.append(self.allocator, .{
                .tool_name = try self.allocator.dupe(u8, tool_name),
                .operation = operation,
                .path = if (getStringField(obj, "path")) |path| try self.allocator.dupe(u8, path) else null,
                .command = if (getStringField(obj, "command")) |command| try self.allocator.dupe(u8, command) else null,
                .decision = decision,
            });
        }
    }

    pub fn save(self: *Self) !void {
        const dir_path = std.fs.path.dirname(self.persistence_path) orelse ".";
        try compat.fs.createDir(compat.fs.getCwd(), dir_path);

        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.allocator);
        try buffer.appendSlice(self.allocator, "{\"decisions\":[");
        for (self.persisted.items, 0..) |decision, idx| {
            if (idx > 0) try buffer.append(self.allocator, ',');
            try buffer.append(self.allocator, '{');
            try appendJsonStringField(&buffer, self.allocator, "tool_name", decision.tool_name, false);
            try appendJsonStringField(&buffer, self.allocator, "operation", @tagName(decision.operation), true);
            if (decision.path) |path| try appendJsonStringField(&buffer, self.allocator, "path", path, true);
            if (decision.command) |command| try appendJsonStringField(&buffer, self.allocator, "command", command, true);
            try appendJsonStringField(&buffer, self.allocator, "decision", @tagName(decision.decision), true);
            try buffer.append(self.allocator, '}');
        }
        try buffer.appendSlice(self.allocator, "]}");

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.persistence_path});
        defer self.allocator.free(tmp_path);
        try compat.fs.atomicReplace(compat.fs.getCwd(), self.persistence_path, tmp_path, buffer.items);
    }

    fn defaultDecision(self: *Self, call: ToolCall) PermissionDecision {
        switch (call.operation) {
            .read => {
                const path = call.path orelse return .prompt;
                return if (self.isInsideWorkspace(path)) .allow else .deny;
            },
            .write => {
                const path = call.path orelse return .prompt;
                return if (self.isInsideWorkspace(path)) .prompt else .deny;
            },
            .shell => {
                const command = call.command orelse return .prompt;
                if (isDestructiveShell(command)) return .deny;
                if (isSafeShell(command)) return .allow;
                return .prompt;
            },
            .unknown => return .prompt,
        }
    }

    fn findPersisted(self: *Self, call: ToolCall) ?PermissionDecision {
        for (self.persisted.items) |decision| {
            if (matchesPersisted(decision, call)) return decision.decision;
        }
        return null;
    }

    fn isInsideWorkspace(self: *Self, path: []const u8) bool {
        if (!std.fs.path.isAbsolute(path)) return true;
        return pathWithinRoot(path, self.workspace_root);
    }
};

fn parseToolCall(allocator: std.mem.Allocator, tool_name: []const u8, args_json: []const u8) !ToolCall {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();

    const operation = inferOperation(tool_name);
    var path: ?[]u8 = null;
    errdefer if (path) |owned| allocator.free(owned);
    var command: ?[]u8 = null;
    errdefer if (command) |owned| allocator.free(owned);

    if (parsed.value == .object) {
        const obj = parsed.value.object;
        if (firstStringField(obj, &.{ "path", "file_path", "target_path", "cwd" })) |value| {
            path = try allocator.dupe(u8, value);
        }
        if (firstStringField(obj, &.{ "command", "cmd", "script" })) |value| {
            command = try allocator.dupe(u8, value);
        }
    }

    return .{
        .tool_name = tool_name,
        .args_json = args_json,
        .operation = operation,
        .path = path,
        .command = command,
    };
}

fn deinitParsedToolCall(allocator: std.mem.Allocator, call: ToolCall) void {
    if (call.path) |path| allocator.free(@constCast(path));
    if (call.command) |command| allocator.free(@constCast(command));
}

fn inferOperation(tool_name: []const u8) Operation {
    if (hasAnyToken(tool_name, &.{ "read", "grep", "glob", "list" })) return .read;
    if (hasAnyToken(tool_name, &.{ "write", "edit", "delete", "move", "rename" })) return .write;
    if (hasAnyToken(tool_name, &.{ "shell", "bash", "exec", "run" })) return .shell;
    return .unknown;
}

fn hasAnyToken(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn firstStringField(obj: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (obj.get(key)) |value| {
            if (value == .string) return value.string;
        }
    }
    return null;
}

fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn matchesPersisted(decision: PersistedDecision, call: ToolCall) bool {
    if (!std.mem.eql(u8, decision.tool_name, call.tool_name)) return false;
    if (decision.operation != call.operation) return false;
    if (!optionalStringEql(decision.path, call.path)) return false;
    if (!optionalStringEql(decision.command, call.command)) return false;
    return true;
}

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn pathWithinRoot(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (root.len == 0) return false;
    if (root[root.len - 1] == std.fs.path.sep) return true;
    return path.len > root.len and path[root.len] == std.fs.path.sep;
}

fn isSafeShell(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    return std.mem.eql(u8, trimmed, "echo") or std.mem.startsWith(u8, trimmed, "echo ");
}

fn isDestructiveShell(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (std.mem.indexOf(u8, trimmed, "rm -rf /") != null) return true;
    if (std.mem.indexOf(u8, trimmed, "rm -fr /") != null) return true;
    if (std.mem.indexOf(u8, trimmed, "mkfs") != null) return true;
    if (std.mem.indexOf(u8, trimmed, ":(){") != null) return true;
    return false;
}

fn appendJsonStringField(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8, comma: bool) !void {
    if (comma) try buffer.append(allocator, ',');
    try appendJsonString(buffer, allocator, key);
    try buffer.append(allocator, ':');
    try appendJsonString(buffer, allocator, value);
}

fn appendJsonString(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try buffer.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try buffer.appendSlice(allocator, "\\\""),
            '\\' => try buffer.appendSlice(allocator, "\\\\"),
            '\n' => try buffer.appendSlice(allocator, "\\n"),
            '\r' => try buffer.appendSlice(allocator, "\\r"),
            '\t' => try buffer.appendSlice(allocator, "\\t"),
            else => try buffer.append(allocator, ch),
        }
    }
    try buffer.append(allocator, '"');
}

fn defaultPersistencePath(allocator: std.mem.Allocator) ![]u8 {
    if (compat.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".makai", "permissions.json" });
    } else |_| {
        return try allocator.dupe(u8, ".makai/permissions.json");
    }
}

fn readFileAbsolute(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return compat.fs.readFileAlloc(allocator, compat.fs.getCwd(), path, max_bytes);
}

test "default policy allows safe shell and denies destructive shell" {
    var engine = try PermissionEngine.init(std.testing.allocator, .{
        .workspace_root = "/workspace",
        .persistence_path = "zig-cache/test-permissions-shell.json",
    });
    defer engine.deinit();

    try std.testing.expectEqual(PermissionDecision.allow, engine.evaluate("shell", "{\"command\":\"echo hello\"}"));
    try std.testing.expectEqual(PermissionDecision.deny, engine.evaluate("shell", "{\"command\":\"rm -rf /\"}"));
}

test "path policy allows read inside workspace and denies outside write" {
    var engine = try PermissionEngine.init(std.testing.allocator, .{
        .workspace_root = "/workspace",
        .persistence_path = "zig-cache/test-permissions-path.json",
    });
    defer engine.deinit();

    try std.testing.expectEqual(PermissionDecision.allow, engine.evaluate("file:read", "{\"path\":\"/workspace/src/main.zig\"}"));
    try std.testing.expectEqual(PermissionDecision.prompt, engine.evaluate("file:write", "{\"path\":\"/workspace/src/main.zig\"}"));
    try std.testing.expectEqual(PermissionDecision.deny, engine.evaluate("file:write", "{\"path\":\"/tmp/outside.txt\"}"));
}

const ApprovalRecorder = struct {
    calls: usize = 0,
    decision: ApprovalDecision = .approve,
};

var approval_recorder = ApprovalRecorder{};

fn approvalCallback(call: ToolCallC) callconv(.c) ApprovalDecision {
    _ = call;
    approval_recorder.calls += 1;
    return approval_recorder.decision;
}

test "approval callback fires and can approve" {
    approval_recorder = .{ .decision = .approve };
    var engine = try PermissionEngine.init(std.testing.allocator, .{
        .workspace_root = "/workspace",
        .persistence_path = "zig-cache/test-permissions-approve.json",
        .approval_callback = approvalCallback,
    });
    defer engine.deinit();

    try std.testing.expectEqual(ApprovalDecision.approve, try engine.approve("file:write", "{\"path\":\"/workspace/file.txt\"}"));
    try std.testing.expectEqual(@as(usize, 1), approval_recorder.calls);
}

test "approval callback fires and can reject" {
    approval_recorder = .{ .decision = .reject };
    var engine = try PermissionEngine.init(std.testing.allocator, .{
        .workspace_root = "/workspace",
        .persistence_path = "zig-cache/test-permissions-reject.json",
        .approval_callback = approvalCallback,
    });
    defer engine.deinit();

    try std.testing.expectEqual(ApprovalDecision.reject, try engine.approve("file:write", "{\"path\":\"/workspace/file.txt\"}"));
    try std.testing.expectEqual(@as(usize, 1), approval_recorder.calls);
}

test "persisted always allow decision reloads and auto-approves" {
    const persistence_path = "zig-cache/test-permissions-persist.json";
    compat.fs.getCwd().deleteFile(std.testing.io, persistence_path) catch {};

    approval_recorder = .{ .decision = .approve_always };
    {
        var engine = try PermissionEngine.init(std.testing.allocator, .{
            .workspace_root = "/workspace",
            .persistence_path = persistence_path,
            .approval_callback = approvalCallback,
        });
        defer engine.deinit();
        try std.testing.expectEqual(ApprovalDecision.approve_always, try engine.approve("file:write", "{\"path\":\"/workspace/file.txt\"}"));
    }

    approval_recorder = .{ .decision = .reject };
    {
        var engine = try PermissionEngine.init(std.testing.allocator, .{
            .workspace_root = "/workspace",
            .persistence_path = persistence_path,
            .approval_callback = approvalCallback,
        });
        defer engine.deinit();
        try std.testing.expectEqual(PermissionDecision.allow, engine.evaluate("file:write", "{\"path\":\"/workspace/file.txt\"}"));
        try std.testing.expectEqual(ApprovalDecision.approve, try engine.approve("file:write", "{\"path\":\"/workspace/file.txt\"}"));
        try std.testing.expectEqual(@as(usize, 0), approval_recorder.calls);
    }
}
