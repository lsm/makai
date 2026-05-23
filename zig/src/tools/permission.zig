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

    /// Initialize engine without loading persisted file.
    /// Use when on-disk permissions are corrupt or unreadable.
    pub fn initEmpty(allocator: std.mem.Allocator, options: PermissionEngineOptions) !Self {
        const workspace_root = try allocator.dupe(u8, options.workspace_root);
        errdefer allocator.free(workspace_root);

        const persistence_path = if (options.persistence_path) |path|
            try allocator.dupe(u8, path)
        else
            try defaultPersistencePath(allocator);
        errdefer allocator.free(persistence_path);

        return Self{
            .allocator = allocator,
            .workspace_root = workspace_root,
            .persistence_path = persistence_path,
            .approval_callback = options.approval_callback,
        };
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
        const call = parseToolCall(self.allocator, tool_name, args_json) catch return .reject;
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
            .approve_always => if (canPersistDecision(call)) self.persistDecision(call, .allow) catch return .approve else return .approve,
            .reject_always => if (canPersistDecision(call)) self.persistDecision(call, .deny) catch return .reject else return .reject,
            .approve, .reject => {},
        }
        return decision;
    }

    pub fn persistDecision(self: *Self, call: ToolCall, decision: PermissionDecision) !void {
        var normalized_path: ?[]u8 = null;
        defer if (normalized_path) |path| self.allocator.free(path);
        if (call.path) |path| {
            normalized_path = try self.normalizePathScope(path);
        }
        const normalized_call: ToolCall = .{
            .tool_name = call.tool_name,
            .args_json = call.args_json,
            .operation = call.operation,
            .path = normalized_path orelse call.path,
            .command = call.command,
        };

        for (self.persisted.items) |*existing| {
            if (matchesPersisted(existing.*, normalized_call)) {
                existing.decision = decision;
                try self.save();
                return;
            }
        }

        const persisted = PersistedDecision{
            .tool_name = try self.allocator.dupe(u8, normalized_call.tool_name),
            .operation = normalized_call.operation,
            .path = if (normalized_call.path) |path| try self.allocator.dupe(u8, path) else null,
            .command = if (normalized_call.command) |command| try self.allocator.dupe(u8, command) else null,
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
        var normalized_path: ?[]u8 = null;
        defer if (normalized_path) |path| self.allocator.free(path);
        if (call.path) |path| {
            normalized_path = self.normalizePathScope(path) catch null;
        }
        const normalized_call: ToolCall = .{
            .tool_name = call.tool_name,
            .args_json = call.args_json,
            .operation = call.operation,
            .path = normalized_path orelse call.path,
            .command = call.command,
        };

        for (self.persisted.items) |decision| {
            if (matchesPersisted(decision, normalized_call)) return decision.decision;
        }
        return null;
    }

    fn isInsideWorkspace(self: *Self, path: []const u8) bool {
        var normalized_root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const normalized_root = normalizeAbsolutePath(self.workspace_root, &normalized_root_buffer) orelse return false;

        var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const absolute_path = normalizeToolPath(path, normalized_root, &absolute_buffer) orelse return false;
        return pathWithinRoot(absolute_path, normalized_root);
    }

    fn normalizePathScope(self: *Self, path: []const u8) ![]u8 {
        var normalized_root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const normalized_root = normalizeAbsolutePath(self.workspace_root, &normalized_root_buffer) orelse return error.InvalidPath;

        var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const absolute_path = normalizeToolPath(path, normalized_root, &absolute_buffer) orelse return error.InvalidPath;
        return self.allocator.dupe(u8, absolute_path);
    }
};

pub fn parseToolCall(allocator: std.mem.Allocator, tool_name: []const u8, args_json: []const u8) !ToolCall {
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
            if (!std.fs.path.isAbsolute(value)) {
                if (firstStringField(obj, &.{"workspace_root"})) |workspace_root| {
                    path = try std.fs.path.join(allocator, &.{ workspace_root, value });
                } else {
                    path = try allocator.dupe(u8, value);
                }
            } else {
                path = try allocator.dupe(u8, value);
            }
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

pub fn deinitParsedToolCall(allocator: std.mem.Allocator, call: ToolCall) void {
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
    var start: ?usize = null;
    for (haystack, 0..) |ch, idx| {
        if (isToolNameTokenChar(ch)) {
            if (start == null) start = idx;
        } else if (start) |token_start| {
            if (tokenMatches(haystack[token_start..idx], needles)) return true;
            start = null;
        }
    }
    if (start) |token_start| {
        if (tokenMatches(haystack[token_start..], needles)) return true;
    }
    return false;
}

fn tokenMatches(token: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.ascii.eqlIgnoreCase(token, needle)) return true;
    }
    return false;
}

fn isToolNameTokenChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch);
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

pub fn canPersistDecision(call: ToolCall) bool {
    return switch (call.operation) {
        .read, .write => call.path != null,
        .shell => call.command != null,
        .unknown => false,
    };
}

fn normalizeToolPath(path: []const u8, workspace_root: []const u8, buffer: []u8) ?[]const u8 {
    if (std.fs.path.isAbsolute(path)) return normalizeAbsolutePath(path, buffer);
    if (pathEscapesRoot(path)) return null;
    const joined = std.fmt.bufPrint(buffer, "{s}/{s}", .{ workspace_root, path }) catch return null;
    return normalizeAbsolutePathInPlace(joined, buffer);
}

fn normalizeAbsolutePath(path: []const u8, buffer: []u8) ?[]const u8 {
    if (!std.fs.path.isAbsolute(path)) return null;
    if (path.len > buffer.len) return null;
    @memcpy(buffer[0..path.len], path);
    return normalizeAbsolutePathInPlace(buffer[0..path.len], buffer);
}

fn normalizeAbsolutePathInPlace(path: []const u8, buffer: []u8) ?[]const u8 {
    if (!std.fs.path.isAbsolute(path)) return null;
    var segments: [128][]const u8 = undefined;
    var segment_count: usize = 0;
    var it = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (segment_count == 0) return null;
            segment_count -= 1;
            continue;
        }
        if (segment_count == segments.len) return null;
        segments[segment_count] = segment;
        segment_count += 1;
    }

    var out: usize = 0;
    buffer[out] = std.fs.path.sep;
    out += 1;
    for (segments[0..segment_count], 0..) |segment, idx| {
        if (idx > 0) {
            if (out >= buffer.len) return null;
            buffer[out] = std.fs.path.sep;
            out += 1;
        }
        if (out + segment.len > buffer.len) return null;
        std.mem.copyForwards(u8, buffer[out .. out + segment.len], segment);
        out += segment.len;
    }
    return buffer[0..out];
}

fn pathEscapesRoot(path: []const u8) bool {
    var depth: usize = 0;
    var it = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (depth == 0) return true;
            depth -= 1;
        } else {
            depth += 1;
        }
    }
    return false;
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
    if (containsShellControl(trimmed)) return false;
    return std.mem.eql(u8, trimmed, "echo") or std.mem.startsWith(u8, trimmed, "echo ");
}

fn containsShellControl(command: []const u8) bool {
    return std.mem.indexOfAny(u8, command, ";&|`$()<>") != null or std.mem.indexOfAny(u8, command, "\r\n") != null;
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
    try std.testing.expectEqual(PermissionDecision.prompt, engine.evaluate("shell", "{\"command\":\"echo hello; cat /etc/passwd\"}"));
    try std.testing.expectEqual(PermissionDecision.prompt, engine.evaluate("shell", "{\"command\":\"echo hello\\ncat /etc/passwd\"}"));
    try std.testing.expectEqual(PermissionDecision.deny, engine.evaluate("shell", "{\"command\":\"rm -rf /\"}"));
}

test "path policy allows read inside workspace and denies outside write" {
    var engine = try PermissionEngine.init(std.testing.allocator, .{
        .workspace_root = "/workspace",
        .persistence_path = "zig-cache/test-permissions-path.json",
    });
    defer engine.deinit();

    try std.testing.expectEqual(PermissionDecision.allow, engine.evaluate("file:read", "{\"path\":\"/workspace/src/main.zig\"}"));
    try std.testing.expectEqual(PermissionDecision.allow, engine.evaluate("file:read", "{\"path\":\"src/main.zig\"}"));
    try std.testing.expectEqual(PermissionDecision.deny, engine.evaluate("file:read", "{\"workspace_root\":\"/tmp\",\"path\":\"secret.txt\"}"));
    try std.testing.expectEqual(PermissionDecision.prompt, engine.evaluate("file:write", "{\"path\":\"/workspace/src/main.zig\"}"));
    try std.testing.expectEqual(PermissionDecision.deny, engine.evaluate("file:write", "{\"path\":\"/tmp/outside.txt\"}"));
    try std.testing.expectEqual(PermissionDecision.deny, engine.evaluate("file:write", "{\"path\":\"../../etc/passwd\"}"));
    try std.testing.expectEqual(PermissionDecision.deny, engine.evaluate("file:write", "{\"path\":\"/workspace/../tmp/outside.txt\"}"));
}

test "operation inference uses token boundaries" {
    var engine = try PermissionEngine.init(std.testing.allocator, .{
        .workspace_root = "/workspace",
        .persistence_path = "zig-cache/test-permissions-token-boundary.json",
    });
    defer engine.deinit();

    try std.testing.expectEqual(PermissionDecision.prompt, engine.evaluate("thread_run", "{\"path\":\"/workspace/src/main.zig\"}"));
    try std.testing.expectEqual(PermissionDecision.allow, engine.evaluate("file_read", "{\"path\":\"/workspace/src/main.zig\"}"));
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

test "approve always without extracted scope does not persist wildcard" {
    const persistence_path = "zig-cache/test-permissions-wildcard.json";
    compat.fs.getCwd().deleteFile(std.testing.io, persistence_path) catch {};

    approval_recorder = .{ .decision = .approve_always };
    var engine = try PermissionEngine.init(std.testing.allocator, .{
        .workspace_root = "/workspace",
        .persistence_path = persistence_path,
        .approval_callback = approvalCallback,
    });
    defer engine.deinit();

    try std.testing.expectEqual(ApprovalDecision.approve, try engine.approve("file:write", "{\"unknown_path_key\":\"/workspace/file.txt\"}"));
    try std.testing.expectEqual(@as(usize, 0), engine.persisted.items.len);
}

test "malformed tool args reject without bubbling parse error" {
    var engine = try PermissionEngine.init(std.testing.allocator, .{
        .workspace_root = "/workspace",
        .persistence_path = "zig-cache/test-permissions-malformed.json",
        .approval_callback = approvalCallback,
    });
    defer engine.deinit();

    try std.testing.expectEqual(PermissionDecision.prompt, engine.evaluate("file:write", "{"));
    try std.testing.expectEqual(ApprovalDecision.reject, try engine.approve("file:write", "{"));
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

test "approve always persists scoped path decision" {
    const persistence_path = "zig-cache/test-permissions-approve-always-scope.json";
    compat.fs.getCwd().deleteFile(std.testing.io, persistence_path) catch {};

    approval_recorder = .{ .decision = .approve_always };
    var engine = try PermissionEngine.init(std.testing.allocator, .{
        .workspace_root = "/workspace",
        .persistence_path = persistence_path,
        .approval_callback = approvalCallback,
    });
    defer engine.deinit();

    try std.testing.expectEqual(ApprovalDecision.approve_always, try engine.approve("file:write", "{\"path\":\"src/main.zig\"}"));
    try std.testing.expectEqual(@as(usize, 1), engine.persisted.items.len);
    try std.testing.expectEqualStrings("/workspace/src/main.zig", engine.persisted.items[0].path.?);
    try std.testing.expectEqual(PermissionDecision.allow, engine.evaluate("file:write", "{\"path\":\"/workspace/src/main.zig\"}"));
}

test "persisted path scope matches normalized equivalent paths" {
    var engine = try PermissionEngine.init(std.testing.allocator, .{
        .workspace_root = "/workspace",
        .persistence_path = "zig-cache/test-permissions-normalized-path.json",
    });
    defer engine.deinit();

    try engine.persistDecision(.{
        .tool_name = "file:write",
        .args_json = "{}",
        .operation = .write,
        .path = "a.txt",
    }, .deny);

    try std.testing.expectEqual(PermissionDecision.deny, engine.evaluate("file:write", "{\"path\":\"/workspace/a.txt\"}"));
    try std.testing.expectEqual(PermissionDecision.deny, engine.evaluate("file:write", "{\"path\":\"./a.txt\"}"));
}

test "persist failure degrades always decisions to one shot" {
    const persistence_path = "zig-cache/test-permissions-persist-fail";
    compat.fs.getCwd().deleteFile(std.testing.io, persistence_path) catch {};
    compat.fs.getCwd().deleteTree(std.testing.io, persistence_path) catch {};

    approval_recorder = .{ .decision = .approve_always };
    var engine = try PermissionEngine.init(std.testing.allocator, .{
        .workspace_root = "/workspace",
        .persistence_path = persistence_path,
        .approval_callback = approvalCallback,
    });
    defer engine.deinit();
    try compat.fs.createDir(compat.fs.getCwd(), persistence_path);
    defer compat.fs.getCwd().deleteTree(std.testing.io, persistence_path) catch {};

    try std.testing.expectEqual(ApprovalDecision.approve, try engine.approve("file:write", "{\"path\":\"/workspace/file.txt\"}"));
}
