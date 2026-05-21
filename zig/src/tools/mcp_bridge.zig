const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const agent = @import("agent");
const common = @import("tools/common");

pub const McpServerConfig = struct {
    name: []u8,
    command: []u8,
    args: [][]u8 = &.{},
    env: []EnvVar = &.{},

    pub fn deinit(self: *McpServerConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
        for (self.args) |arg| allocator.free(arg);
        allocator.free(self.args);
        for (self.env) |*entry| entry.deinit(allocator);
        allocator.free(self.env);
        self.* = undefined;
    }
};

pub const EnvVar = struct {
    key: []u8,
    value: []u8,

    fn deinit(self: *EnvVar, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const McpToolDefinition = struct {
    server_name: []const u8,
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
    is_destructive: bool = false,

    pub fn toAgentTool(self: McpToolDefinition, allocator: std.mem.Allocator, ctx: ?*anyopaque) !agent.AgentTool {
        const tool_name = try sanitizedToolName(allocator, self.server_name, self.name);
        errdefer allocator.free(tool_name);
        const label = try std.fmt.allocPrint(allocator, "{s}: {s} (mcp)", .{ self.server_name, self.name });
        errdefer allocator.free(label);
        const description = try std.fmt.allocPrint(allocator, "MCP tool from {s}: {s}", .{ self.server_name, self.description });
        errdefer allocator.free(description);
        const short_description = try std.fmt.allocPrint(allocator, "{s} (mcp)", .{self.description});
        errdefer allocator.free(short_description);
        const schema = try allocator.dupe(u8, self.input_schema_json);
        errdefer allocator.free(schema);

        return .{
            .label = label,
            .name = tool_name,
            .description = description,
            .short_description = short_description,
            .parameters_schema_json = schema,
            .execute = unavailableExecute,
            .execute_ctx = ctx,
            .execute_with_context = executeWithContext,
            .approval_ctx = if (self.is_destructive) ctx else null,
            .approval_fn = null,
        };
    }
};

const McpToolExecContext = struct {
    bridge: **McpBridge,
    server_index: usize,
    mcp_name: []u8,
};

const McpToolRecord = struct {
    server_index: usize,
    mcp_name: []u8,
    agent_tool: agent.AgentTool,
    exec_ctx: *McpToolExecContext,
    is_destructive: bool,

    fn deinit(self: *McpToolRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.exec_ctx.mcp_name);
        allocator.destroy(self.exec_ctx);
        allocator.free(self.mcp_name);
        deinitAgentToolFields(allocator, &self.agent_tool);
    }
};

const mcp_discovery_timeout_ms: u64 = 5_000;

const McpServerSession = struct {
    config: McpServerConfig,
    child: ?std.process.Child = null,
    next_id: u64 = 1,
    stdout_pending: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    mock_response: ?std.json.Value = null,

    fn deinit(self: *McpServerSession, allocator: std.mem.Allocator) void {
        self.stop();
        self.stdout_pending.deinit(allocator);
        self.config.deinit(allocator);
        self.stderr.deinit(allocator);
    }

    fn stop(self: *McpServerSession) void {
        if (self.child) |*child| {
            const io = common.defaultIo();
            if (child.id != null) child.kill(io);
            if (child.stdin) |stdin| stdin.close(io);
            if (child.stdout) |stdout| stdout.close(io);
            if (child.stderr) |stderr| stderr.close(io);
            child.* = undefined;
            self.child = null;
        }
    }

    fn start(self: *McpServerSession, allocator: std.mem.Allocator) !void {
        if (self.child != null) return;
        const argv = try buildArgv(allocator, self.config.command, self.config.args);
        defer allocator.free(argv);

        var env_map: ?std.process.Environ.Map = null;
        defer if (env_map) |*map| map.deinit();
        if (self.config.env.len > 0) {
            env_map = try compat.createEnvMap(allocator);
            for (self.config.env) |entry| try env_map.?.put(entry.key, entry.value);
        }

        self.child = try std.process.spawn(common.defaultIo(), .{
            .argv = argv,
            .environ_map = if (env_map) |*map| map else null,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .create_no_window = true,
        });
    }

    fn sendRequest(self: *McpServerSession, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8, cancel_token: ?ai_types.CancelToken, timeout_ms: ?u64) !std.json.Parsed(std.json.Value) {
        if (common.isCancelled(cancel_token)) return error.Cancelled;
        if (self.mock_response) |value| {
            return std.json.parseFromValue(std.json.Value, allocator, value, .{});
        }
        try self.start(allocator);
        const child = &(self.child orelse return error.McpServerNotRunning);
        const id = self.next_id;
        self.next_id += 1;
        const escaped_method = try std.json.Stringify.valueAlloc(allocator, method, .{});
        defer allocator.free(escaped_method);
        const request = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{s},\"params\":{s}}}\n", .{ id, escaped_method, params_json });
        defer allocator.free(request);
        if (std.mem.indexOfScalar(u8, request[0 .. request.len - 1], '\n') != null) return error.InvalidMcpRequest;
        try child.stdin.?.writeStreamingAll(common.defaultIo(), request);

        const start_ms = common.nowMs();
        const poll_timeout: std.Io.Timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(common.process_poll_ms), .clock = .boot } };
        var matched_response: ?std.json.Parsed(std.json.Value) = null;
        errdefer if (matched_response) |*response| response.deinit();

        while (true) {
            if (common.isCancelled(cancel_token)) return error.Cancelled;
            while (try takePendingLine(allocator, &self.stdout_pending)) |line| {
                defer allocator.free(line);
                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                if (trimmed.len == 0) continue;
                var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
                errdefer parsed.deinit();
                if (parsed.value != .object) return error.InvalidMcpResponse;
                const obj = parsed.value.object;
                if (isPendingResponse(obj, id)) {
                    if (matched_response) |*response| response.deinit();
                    matched_response = parsed;
                    continue;
                }
                try self.respondToInboundRequest(allocator, obj);
                parsed.deinit();
            }
            if (matched_response) |response| {
                matched_response = null;
                return response;
            }
            if (timeout_ms) |limit| if (common.durationMs(start_ms) >= limit) return error.Timeout;
            var multi_reader_buffer: std.Io.File.MultiReader.Buffer(1) = undefined;
            var multi_reader: std.Io.File.MultiReader = undefined;
            multi_reader.init(allocator, common.defaultIo(), multi_reader_buffer.toStreams(), &.{child.stdout.?});
            defer multi_reader.deinit();
            const reader = multi_reader.reader(0);
            multi_reader.fill(1, poll_timeout) catch |err| switch (err) {
                error.Timeout => continue,
                error.EndOfStream => return error.McpServerClosed,
                else => |e| return e,
            };
            try self.stdout_pending.appendSlice(allocator, reader.buffered());
        }
    }

    fn sendNotification(self: *McpServerSession, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) !void {
        if (self.mock_response != null) return;
        try self.start(allocator);
        const child = &(self.child orelse return error.McpServerNotRunning);
        const escaped_method = try std.json.Stringify.valueAlloc(allocator, method, .{});
        defer allocator.free(escaped_method);
        const notification = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"method\":{s},\"params\":{s}}}\n", .{ escaped_method, params_json });
        defer allocator.free(notification);
        try child.stdin.?.writeStreamingAll(common.defaultIo(), notification);
    }

    fn sendResponse(self: *McpServerSession, allocator: std.mem.Allocator, id: std.json.Value, result_json: []const u8) !void {
        if (self.mock_response != null) return;
        const child = &(self.child orelse return error.McpServerNotRunning);
        const id_json = try std.json.Stringify.valueAlloc(allocator, id, .{});
        defer allocator.free(id_json);
        const response = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}\n", .{ id_json, result_json });
        defer allocator.free(response);
        try child.stdin.?.writeStreamingAll(common.defaultIo(), response);
    }

    fn sendError(self: *McpServerSession, allocator: std.mem.Allocator, id: std.json.Value, code: i64, message: []const u8) !void {
        if (self.mock_response != null) return;
        const child = &(self.child orelse return error.McpServerNotRunning);
        const id_json = try std.json.Stringify.valueAlloc(allocator, id, .{});
        defer allocator.free(id_json);
        const message_json = try std.json.Stringify.valueAlloc(allocator, message, .{});
        defer allocator.free(message_json);
        const response = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{s}}}}}\n", .{ id_json, code, message_json });
        defer allocator.free(response);
        try child.stdin.?.writeStreamingAll(common.defaultIo(), response);
    }

    fn respondToInboundRequest(self: *McpServerSession, allocator: std.mem.Allocator, obj: std.json.ObjectMap) !void {
        const method = getString(obj, "method") orelse return;
        const id = obj.get("id") orelse return;
        if (std.mem.eql(u8, method, "ping")) {
            try self.sendResponse(allocator, id, "{}");
            return;
        }
        try self.sendError(allocator, id, -32601, "Method not found");
    }
};

pub const McpBridge = struct {
    allocator: std.mem.Allocator,
    self_ptr: *McpBridge = undefined,
    self_ref: *McpBridge = undefined,
    servers: std.ArrayList(McpServerSession) = .empty,
    tools: std.ArrayList(McpToolRecord) = .empty,

    pub fn init(allocator: std.mem.Allocator) McpBridge {
        return .{ .allocator = allocator };
    }

    pub fn bind(self: *McpBridge) void {
        self.self_ptr = self;
        self.self_ref = self;
    }

    pub fn deinit(self: *McpBridge) void {
        for (self.tools.items) |*tool| tool.deinit(self.allocator);
        self.tools.deinit(self.allocator);
        for (self.servers.items) |*server| server.deinit(self.allocator);
        self.servers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn loadConfigJson(self: *McpBridge, config_json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, config_json, .{});
        defer parsed.deinit();
        const servers_value = if (parsed.value == .object)
            parsed.value.object.get("mcp_servers") orelse return
        else
            parsed.value;
        if (servers_value != .array) return error.InvalidMcpConfig;
        var parsed_servers = std.ArrayList(McpServerSession).empty;
        errdefer {
            for (parsed_servers.items) |*server| server.deinit(self.allocator);
            parsed_servers.deinit(self.allocator);
        }
        for (servers_value.array.items) |item| {
            try parsed_servers.append(self.allocator, .{ .config = try parseServerConfig(self.allocator, item) });
        }
        try self.servers.appendSlice(self.allocator, parsed_servers.items);
        parsed_servers.deinit(self.allocator);
    }

    pub fn discover(self: *McpBridge) !void {
        for (self.servers.items, 0..) |*server, server_index| {
            var initialize_response = try server.sendRequest(self.allocator, "initialize", "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"makai\",\"version\":\"0.1.0\"}}", null, mcp_discovery_timeout_ms);
            defer initialize_response.deinit();
            try validateRpcResult(initialize_response.value);
            try server.sendNotification(self.allocator, "notifications/initialized", "{}");
            var list_params = try self.allocator.dupe(u8, "{}");
            var list_params_owned = true;
            errdefer if (list_params_owned) self.allocator.free(list_params);
            while (true) {
                var response = try server.sendRequest(self.allocator, "tools/list", list_params, null, mcp_discovery_timeout_ms);
                const next_cursor = try self.addToolsFromResponse(server_index, response.value);
                if (next_cursor) |cursor| {
                    const cursor_json = try std.json.Stringify.valueAlloc(self.allocator, cursor, .{});
                    defer self.allocator.free(cursor_json);
                    const next_params = try std.fmt.allocPrint(self.allocator, "{{\"cursor\":{s}}}", .{cursor_json});
                    response.deinit();
                    self.allocator.free(list_params);
                    list_params = next_params;
                    continue;
                }
                response.deinit();
                self.allocator.free(list_params);
                list_params_owned = false;
                break;
            }
        }
    }

    pub fn appendAgentTools(self: *McpBridge, out: *std.ArrayList(agent.AgentTool)) !void {
        for (self.tools.items) |record| try out.append(self.allocator, record.agent_tool);
    }

    fn addToolsFromResponse(self: *McpBridge, server_index: usize, value: std.json.Value) !?[]const u8 {
        const result = resultObject(value) orelse return error.InvalidMcpResponse;
        const tools_value = result.get("tools") orelse return error.InvalidMcpResponse;
        if (tools_value != .array) return error.InvalidMcpResponse;
        const next_cursor = if (result.get("nextCursor")) |cursor| blk: {
            if (cursor != .string) return error.InvalidMcpResponse;
            break :blk cursor.string;
        } else null;
        const server_name = self.servers.items[server_index].config.name;
        for (tools_value.array.items) |item| {
            if (item != .object) return error.InvalidMcpResponse;
            const obj = item.object;
            const mcp_name = getString(obj, "name") orelse return error.InvalidMcpResponse;
            const desc = getString(obj, "description") orelse "MCP tool";
            const schema = if (obj.get("inputSchema")) |schema_value|
                try std.json.Stringify.valueAlloc(self.allocator, schema_value, .{})
            else
                try self.allocator.dupe(u8, "{\"type\":\"object\"}");
            defer self.allocator.free(schema);
            const destructive = inferDestructive(mcp_name, desc, obj);
            const def = McpToolDefinition{ .server_name = server_name, .name = mcp_name, .description = desc, .input_schema_json = schema, .is_destructive = destructive };
            var tool = try def.toAgentTool(self.allocator, null);
            errdefer deinitAgentToolFields(self.allocator, &tool);
            try self.disambiguateToolName(&tool);
            const exec_ctx = try self.allocator.create(McpToolExecContext);
            errdefer self.allocator.destroy(exec_ctx);
            const ctx_mcp_name = try self.allocator.dupe(u8, mcp_name);
            errdefer self.allocator.free(ctx_mcp_name);
            exec_ctx.* = .{ .bridge = &self.self_ref, .server_index = server_index, .mcp_name = ctx_mcp_name };
            tool.execute_ctx = exec_ctx;
            try self.tools.append(self.allocator, .{
                .server_index = server_index,
                .mcp_name = try self.allocator.dupe(u8, mcp_name),
                .agent_tool = tool,
                .exec_ctx = exec_ctx,
                .is_destructive = destructive,
            });
        }
        return next_cursor;
    }

    fn disambiguateToolName(self: *McpBridge, tool: *agent.AgentTool) !void {
        var candidate = try self.allocator.dupe(u8, tool.name);
        errdefer self.allocator.free(candidate);
        var suffix: usize = 2;
        while (self.hasToolName(candidate)) : (suffix += 1) {
            const next = try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ tool.name, suffix });
            self.allocator.free(candidate);
            candidate = next;
        }
        self.allocator.free(tool.name);
        tool.name = candidate;
    }

    fn hasToolName(self: *const McpBridge, name: []const u8) bool {
        for (self.tools.items) |record| if (std.mem.eql(u8, record.agent_tool.name, name)) return true;
        return false;
    }

    fn executeTool(self: *McpBridge, ctx: *McpToolExecContext, tool_call_id: []const u8, args_json: []const u8, cancel_token: ?ai_types.CancelToken, allocator: std.mem.Allocator) !agent.AgentToolResult {
        _ = tool_call_id;
        const escaped_tool = try std.json.Stringify.valueAlloc(allocator, ctx.mcp_name, .{});
        defer allocator.free(escaped_tool);
        var parsed_args = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
        defer parsed_args.deinit();
        const compact_args = try std.json.Stringify.valueAlloc(allocator, parsed_args.value, .{});
        defer allocator.free(compact_args);
        const params = try std.fmt.allocPrint(allocator, "{{\"name\":{s},\"arguments\":{s}}}", .{ escaped_tool, compact_args });
        defer allocator.free(params);
        var response = try self.servers.items[ctx.server_index].sendRequest(allocator, "tools/call", params, cancel_token, null);
        defer response.deinit();
        try validateRpcResult(response.value);
        const result = resultObject(response.value) orelse return error.InvalidMcpResponse;
        return resultFromMcp(allocator, result);
    }
};

fn unavailableExecute(tool_call_id: []const u8, args_json: []const u8, cancel_token: ?ai_types.CancelToken, on_update_ctx: ?*anyopaque, on_update: ?agent.ToolUpdateCallback, allocator: std.mem.Allocator) anyerror!agent.AgentToolResult {
    _ = tool_call_id;
    _ = args_json;
    _ = cancel_token;
    _ = on_update_ctx;
    _ = on_update;
    _ = allocator;
    return error.McpBridgeContextRequired;
}

fn executeWithContext(ctx: ?*anyopaque, tool_call_id: []const u8, args_json: []const u8, cancel_token: ?ai_types.CancelToken, on_update_ctx: ?*anyopaque, on_update: ?agent.ToolUpdateCallback, allocator: std.mem.Allocator) anyerror!agent.AgentToolResult {
    _ = on_update_ctx;
    _ = on_update;
    const exec_ctx: *McpToolExecContext = @ptrCast(@alignCast(ctx.?));
    return exec_ctx.bridge.*.executeTool(exec_ctx, tool_call_id, args_json, cancel_token, allocator);
}

fn parseServerConfig(allocator: std.mem.Allocator, value: std.json.Value) !McpServerConfig {
    if (value != .object) return error.InvalidMcpConfig;
    const obj = value.object;
    var cfg = McpServerConfig{
        .name = try allocator.dupe(u8, getString(obj, "name") orelse return error.InvalidMcpConfig),
        .command = try allocator.dupe(u8, getString(obj, "command") orelse return error.InvalidMcpConfig),
    };
    errdefer cfg.deinit(allocator);
    if (obj.get("args")) |args_value| {
        if (args_value != .array) return error.InvalidMcpConfig;
        cfg.args = try allocator.alloc([]u8, args_value.array.items.len);
        @memset(cfg.args, &.{});
        for (args_value.array.items, 0..) |arg, i| {
            if (arg != .string) return error.InvalidMcpConfig;
            cfg.args[i] = try allocator.dupe(u8, arg.string);
        }
    }
    if (obj.get("env")) |env_value| {
        if (env_value != .object) return error.InvalidMcpConfig;
        cfg.env = try allocator.alloc(EnvVar, env_value.object.count());
        @memset(cfg.env, .{ .key = &.{}, .value = &.{} });
        var it = env_value.object.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            if (entry.value_ptr.* != .string) return error.InvalidMcpConfig;
            cfg.env[i] = .{ .key = try allocator.dupe(u8, entry.key_ptr.*), .value = try allocator.dupe(u8, entry.value_ptr.string) };
        }
    }
    return cfg;
}

fn buildArgv(allocator: std.mem.Allocator, command: []const u8, args: [][]u8) ![][]const u8 {
    const argv = try allocator.alloc([]const u8, args.len + 1);
    argv[0] = command;
    for (args, 0..) |arg, i| argv[i + 1] = arg;
    return argv;
}

fn sanitizedToolName(allocator: std.mem.Allocator, server_name: []const u8, tool_name: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "mcp_");
    try appendSanitized(&out, allocator, server_name);
    try out.append(allocator, '_');
    try appendSanitized(&out, allocator, tool_name);
    return out.toOwnedSlice(allocator);
}

fn appendSanitized(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |ch| {
        try out.append(allocator, if (std.ascii.isAlphanumeric(ch)) ch else '_');
    }
}

fn deinitAgentToolFields(allocator: std.mem.Allocator, tool: *agent.AgentTool) void {
    allocator.free(tool.label);
    allocator.free(tool.name);
    allocator.free(tool.description);
    if (tool.short_description) |short| allocator.free(short);
    allocator.free(tool.parameters_schema_json);
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn resultObject(value: std.json.Value) ?std.json.ObjectMap {
    if (value != .object) return null;
    const result = value.object.get("result") orelse return null;
    return if (result == .object) result.object else null;
}

fn validateRpcResult(value: std.json.Value) !void {
    if (value != .object) return error.InvalidMcpResponse;
    const obj = value.object;
    if (obj.get("error") != null) return error.McpToolError;
    if (obj.get("result") == null) return error.InvalidMcpResponse;
}

fn isPendingResponse(obj: std.json.ObjectMap, id: u64) bool {
    if (obj.get("method") != null) return false;
    if (obj.get("result") == null and obj.get("error") == null) return false;
    const value = obj.get("id") orelse return false;
    return value == .integer and value.integer == @as(i64, @intCast(id));
}

fn takePendingLine(allocator: std.mem.Allocator, pending: *std.ArrayList(u8)) !?[]u8 {
    const index = std.mem.indexOfScalar(u8, pending.items, '\n') orelse return null;
    const line = try allocator.dupe(u8, pending.items[0..index]);
    const remaining = pending.items[index + 1 ..];
    std.mem.copyForwards(u8, pending.items[0..remaining.len], remaining);
    pending.shrinkRetainingCapacity(remaining.len);
    return line;
}

fn inferDestructive(name: []const u8, desc: []const u8, obj: std.json.ObjectMap) bool {
    if (obj.get("destructiveHint")) |v| if (v == .bool and v.bool) return true;
    if (hasToken(name, "write") or hasToken(name, "delete") or hasToken(name, "remove")) return true;
    if (std.ascii.indexOfIgnoreCase(desc, "delete") != null) return true;
    if (std.ascii.indexOfIgnoreCase(desc, "write") != null) return true;
    return false;
}

fn hasToken(value: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(value, needle) != null;
}

fn resultFromMcp(allocator: std.mem.Allocator, result: std.json.ObjectMap) !agent.AgentToolResult {
    const is_error = if (result.get("isError")) |v| v == .bool and v.bool else false;
    if (is_error) return error.McpToolError;
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    if (result.get("content")) |content_value| {
        if (content_value == .array) {
            for (content_value.array.items, 0..) |item, i| {
                if (i > 0) try text.append(allocator, '\n');
                if (item == .object and std.mem.eql(u8, getString(item.object, "type") orelse "", "text")) {
                    try text.appendSlice(allocator, getString(item.object, "text") orelse "");
                } else {
                    try text.appendSlice(allocator, "[non-text MCP content]");
                }
            }
        }
    }
    if (text.items.len == 0) {
        if (result.get("structuredContent")) |structured| {
            const structured_json = try std.json.Stringify.valueAlloc(allocator, structured, .{});
            defer allocator.free(structured_json);
            try text.appendSlice(allocator, structured_json);
        } else {
            const result_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = result }, .{});
            defer allocator.free(result_json);
            try text.appendSlice(allocator, result_json);
        }
    }
    return common.makeTextResult(allocator, text.items, "{\"source\":\"mcp\"}");
}

test "MCP tool definition maps to AgentTool" {
    const def = McpToolDefinition{ .server_name = "fs", .name = "read-file", .description = "Read file", .input_schema_json = "{\"type\":\"object\"}" };
    var tool = try def.toAgentTool(std.testing.allocator, null);
    defer deinitAgentToolFields(std.testing.allocator, &tool);
    try std.testing.expectEqualStrings("mcp_fs_read_file", tool.name);
    try std.testing.expect(std.mem.indexOf(u8, tool.label, "(mcp)") != null);
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", tool.parameters_schema_json);
}

test "MCP config parser accepts object form" {
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try bridge.loadConfigJson("{\"mcp_servers\":[{\"name\":\"mock\",\"command\":\"python3\",\"args\":[\"server.py\"],\"env\":{\"A\":\"B\"}}]}");
    try std.testing.expectEqual(@as(usize, 1), bridge.servers.items.len);
    try std.testing.expectEqualStrings("mock", bridge.servers.items[0].config.name);
    try std.testing.expectEqualStrings("server.py", bridge.servers.items[0].config.args[0]);
    try std.testing.expectEqualStrings("A", bridge.servers.items[0].config.env[0].key);
}

test "MCP invocation forwards text result" {
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try bridge.loadConfigJson("[{\"name\":\"mock\",\"command\":\"mock\"}]");

    var response = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"hello from mcp\"}]}}",
        .{},
    );
    defer response.deinit();
    bridge.servers.items[0].mock_response = response.value;

    const def = McpToolDefinition{ .server_name = "mock", .name = "echo", .description = "Echo", .input_schema_json = "{\"type\":\"object\"}" };
    var tool = try def.toAgentTool(std.testing.allocator, null);
    errdefer deinitAgentToolFields(std.testing.allocator, &tool);
    const exec_ctx = try std.testing.allocator.create(McpToolExecContext);
    exec_ctx.* = .{ .bridge = &bridge.self_ref, .server_index = 0, .mcp_name = try std.testing.allocator.dupe(u8, "echo") };
    tool.execute_ctx = exec_ctx;
    try bridge.tools.append(std.testing.allocator, .{
        .server_index = 0,
        .mcp_name = try std.testing.allocator.dupe(u8, "echo"),
        .agent_tool = tool,
        .exec_ctx = exec_ctx,
        .is_destructive = false,
    });

    var result = try tool.execute_with_context.?(tool.execute_ctx, "call_1", "{}", null, null, null, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello from mcp", result.content.slice()[0].text.text);
}

test "MCP config parser rejects malformed arg and env types" {
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try std.testing.expectError(error.InvalidMcpConfig, bridge.loadConfigJson("[{\"name\":\"mock\",\"command\":\"mock\",\"args\":[1]}]"));
    try std.testing.expectError(error.InvalidMcpConfig, bridge.loadConfigJson("[{\"name\":\"mock\",\"command\":\"mock\",\"env\":{\"A\":1}}]"));
}


test "MCP config parser does not retain partial servers after malformed entry" {
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try std.testing.expectError(error.InvalidMcpConfig, bridge.loadConfigJson("[{\"name\":\"first\",\"command\":\"mock\"},{\"name\":\"bad\",\"command\":\"mock\",\"args\":[1]}]"));
    try std.testing.expectEqual(@as(usize, 0), bridge.servers.items.len);
}

test "MCP tool list rejects non-object entries" {
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try bridge.loadConfigJson("[{\"name\":\"mock\",\"command\":\"mock\"}]");
    var response = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[1]}}",
        .{},
    );
    defer response.deinit();
    try std.testing.expectError(error.InvalidMcpResponse, bridge.addToolsFromResponse(0, response.value));
}

test "MCP JSON-RPC and result errors fail execution" {
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try bridge.loadConfigJson("[{\"name\":\"mock\",\"command\":\"mock\"}]");

    const exec_ctx = try std.testing.allocator.create(McpToolExecContext);
    exec_ctx.* = .{ .bridge = &bridge.self_ref, .server_index = 0, .mcp_name = try std.testing.allocator.dupe(u8, "echo") };
    var tool = try (McpToolDefinition{ .server_name = "mock", .name = "echo", .description = "Echo", .input_schema_json = "{\"type\":\"object\"}" }).toAgentTool(std.testing.allocator, exec_ctx);
    errdefer deinitAgentToolFields(std.testing.allocator, &tool);
    try bridge.tools.append(std.testing.allocator, .{
        .server_index = 0,
        .mcp_name = try std.testing.allocator.dupe(u8, "echo"),
        .agent_tool = tool,
        .exec_ctx = exec_ctx,
        .is_destructive = false,
    });

    var rpc_error = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"message\":\"boom\"}}",
        .{},
    );
    defer rpc_error.deinit();
    bridge.servers.items[0].mock_response = rpc_error.value;
    try std.testing.expectError(error.McpToolError, tool.execute_with_context.?(tool.execute_ctx, "call_1", "{}", null, null, null, std.testing.allocator));

    var result_error = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"bad\"}]}}",
        .{},
    );
    defer result_error.deinit();
    bridge.servers.items[0].mock_response = result_error.value;
    try std.testing.expectError(error.McpToolError, tool.execute_with_context.?(tool.execute_ctx, "call_2", "{}", null, null, null, std.testing.allocator));
}

fn makeTestTool(bridge: *McpBridge, name: []const u8) !agent.AgentTool {
    const exec_ctx = try std.testing.allocator.create(McpToolExecContext);
    errdefer std.testing.allocator.destroy(exec_ctx);
    exec_ctx.* = .{ .bridge = &bridge.self_ref, .server_index = 0, .mcp_name = try std.testing.allocator.dupe(u8, name) };
    errdefer std.testing.allocator.free(exec_ctx.mcp_name);
    var tool = try (McpToolDefinition{ .server_name = "mock", .name = name, .description = "Echo", .input_schema_json = "{\"type\":\"object\"}" }).toAgentTool(std.testing.allocator, exec_ctx);
    errdefer deinitAgentToolFields(std.testing.allocator, &tool);
    try bridge.tools.append(std.testing.allocator, .{
        .server_index = 0,
        .mcp_name = try std.testing.allocator.dupe(u8, name),
        .agent_tool = tool,
        .exec_ctx = exec_ctx,
        .is_destructive = false,
    });
    return tool;
}

fn countToolNames(bridge: *const McpBridge, name: []const u8) usize {
    var count: usize = 0;
    for (bridge.tools.items) |record| {
        if (std.mem.eql(u8, record.agent_tool.name, name)) count += 1;
    }
    return count;
}

fn fakeMcpServerScript() []const u8 {
    return "python3 -u -c 'import json,sys\n" ++
        "for line in sys.stdin:\n" ++
        " msg=json.loads(line); method=msg.get(\"method\")\n" ++
        " if method==\"initialize\": print(json.dumps({\"jsonrpc\":\"2.0\",\"id\":msg[\"id\"],\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}), flush=True)\n" ++
        " elif method==\"notifications/initialized\": pass\n" ++
        " elif method==\"tools/list\":\n" ++
        "  print(json.dumps({\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"ping\",\"params\":{}}), flush=True)\n" ++
        "  print(json.dumps({\"jsonrpc\":\"2.0\",\"id\":msg[\"id\"],\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo\",\"inputSchema\":{\"type\":\"object\"}}]}}), flush=True)\n" ++
        " elif method==\"tools/call\": print(json.dumps({\"jsonrpc\":\"2.0\",\"id\":msg[\"id\"],\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"called\"}]}}), flush=True)'";
}

fn bufferedInboundAfterResponseScript() []const u8 {
    return "python3 -u -c 'import json,sys\n" ++
        "for line in sys.stdin:\n" ++
        " msg=json.loads(line); method=msg.get(\"method\")\n" ++
        " if method==\"initialize\": print(json.dumps({\"jsonrpc\":\"2.0\",\"id\":msg[\"id\"],\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}), flush=True)\n" ++
        " elif method==\"notifications/initialized\": pass\n" ++
        " elif method==\"tools/list\":\n" ++
        "  sys.stdout.write(json.dumps({\"jsonrpc\":\"2.0\",\"id\":msg[\"id\"],\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo\",\"inputSchema\":{\"type\":\"object\"}}]}})+\"\\n\"+json.dumps({\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"ping\",\"params\":{}})+\"\\n\"); sys.stdout.flush()\n" ++
        " elif method==\"tools/call\": print(json.dumps({\"jsonrpc\":\"2.0\",\"id\":msg[\"id\"],\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"called\"}]}}), flush=True)'";
}

fn unsupportedInboundMethodScript() []const u8 {
    return "python3 -u -c 'import json,sys\n" ++
        "for line in sys.stdin:\n" ++
        " msg=json.loads(line); method=msg.get(\"method\")\n" ++
        " if method==\"initialize\": print(json.dumps({\"jsonrpc\":\"2.0\",\"id\":msg[\"id\"],\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}), flush=True)\n" ++
        " elif method==\"notifications/initialized\": pass\n" ++
        " elif method==\"tools/list\": print(json.dumps({\"jsonrpc\":\"2.0\",\"id\":101,\"method\":\"roots/list\",\"params\":{}}), flush=True)\n" ++
        " elif \"error\" in msg and msg.get(\"id\")==101: print(json.dumps({\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo\",\"inputSchema\":{\"type\":\"object\"}}]}}), flush=True)'";
}

fn partialFrameAfterResponseScript() []const u8 {
    return "python3 -u -c 'import json,sys\n" ++
        "partial=False\n" ++
        "for line in sys.stdin:\n" ++
        " msg=json.loads(line); method=msg.get(\"method\")\n" ++
        " if method==\"initialize\": print(json.dumps({\"jsonrpc\":\"2.0\",\"id\":msg[\"id\"],\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}), flush=True)\n" ++
        " elif method==\"notifications/initialized\": pass\n" ++
        " elif method==\"tools/list\" and not partial:\n" ++
        "  partial=True; sys.stdout.write(json.dumps({\"jsonrpc\":\"2.0\",\"id\":msg[\"id\"],\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo\",\"inputSchema\":{\"type\":\"object\"}}]}})+\"\\n\"+\"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":200,\\\"method\\\":\\\"ping\"); sys.stdout.flush()\n" ++
        " elif method==\"tools/list\": sys.stdout.write(\"\\\",\\\"params\\\":{}}\\n\"+json.dumps({\"jsonrpc\":\"2.0\",\"id\":msg[\"id\"],\"result\":{\"tools\":[]}})+\"\\n\"); sys.stdout.flush()'";
}

fn hangingMcpServerScript() []const u8 {
    return "python3 -c \"import time; time.sleep(5)\"";
}

fn paginatedToolsListScript() []const u8 {
    return "python3 -u -c 'import json,sys\n" ++
        "for line in sys.stdin:\n" ++
        " msg=json.loads(line); method=msg.get(\"method\")\n" ++
        " if method==\"initialize\": print(json.dumps({\"jsonrpc\":\"2.0\",\"id\":msg[\"id\"],\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}), flush=True)\n" ++
        " elif method==\"notifications/initialized\": pass\n" ++
        " elif method==\"tools/list\":\n" ++
        "  cursor=msg.get(\"params\",{}).get(\"cursor\")\n" ++
        "  if cursor is None: print(json.dumps({\"jsonrpc\":\"2.0\",\"id\":msg[\"id\"],\"result\":{\"tools\":[{\"name\":\"first\",\"description\":\"First\",\"inputSchema\":{\"type\":\"object\"}}],\"nextCursor\":\"page2\"}}), flush=True)\n" ++
        "  elif cursor==\"page2\": print(json.dumps({\"jsonrpc\":\"2.0\",\"id\":msg[\"id\"],\"result\":{\"tools\":[{\"name\":\"second\",\"description\":\"Second\",\"inputSchema\":{\"type\":\"object\"}}]}}), flush=True)'";
}

fn makeShellConfigJson(allocator: std.mem.Allocator, script: []const u8) ![]u8 {
    const script_json = try std.json.Stringify.valueAlloc(allocator, script, .{});
    defer allocator.free(script_json);
    return try std.fmt.allocPrint(allocator, "[{{\"name\":\"mock\",\"command\":\"/bin/sh\",\"args\":[\"-c\",{s}]}}]", .{script_json});
}

fn expectNoDuplicateToolNames(bridge: *const McpBridge) !void {
    for (bridge.tools.items, 0..) |left, i| {
        for (bridge.tools.items[i + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(u8, left.agent_tool.name, right.agent_tool.name));
        }
    }
}

test "MCP discover responds to inbound ping and accepts matching response only" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const config_json = try makeShellConfigJson(std.testing.allocator, fakeMcpServerScript());
    defer std.testing.allocator.free(config_json);
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try bridge.loadConfigJson(config_json);
    try bridge.discover();
    try std.testing.expectEqual(@as(usize, 1), bridge.tools.items.len);
    try std.testing.expectEqualStrings("echo", bridge.tools.items[0].mcp_name);
}


test "MCP discover drains buffered inbound after matching response" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const config_json = try makeShellConfigJson(std.testing.allocator, bufferedInboundAfterResponseScript());
    defer std.testing.allocator.free(config_json);
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try bridge.loadConfigJson(config_json);
    try bridge.discover();
    try std.testing.expectEqual(@as(usize, 1), bridge.tools.items.len);
    try std.testing.expectEqualStrings("echo", bridge.tools.items[0].mcp_name);
}


test "MCP discover returns method-not-found for unsupported inbound request" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const config_json = try makeShellConfigJson(std.testing.allocator, unsupportedInboundMethodScript());
    defer std.testing.allocator.free(config_json);
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try bridge.loadConfigJson(config_json);
    try bridge.discover();
    try std.testing.expectEqual(@as(usize, 1), bridge.tools.items.len);
    try std.testing.expectEqualStrings("echo", bridge.tools.items[0].mcp_name);
}


test "MCP preserves partial buffered frame across requests" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const config_json = try makeShellConfigJson(std.testing.allocator, partialFrameAfterResponseScript());
    defer std.testing.allocator.free(config_json);
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try bridge.loadConfigJson(config_json);
    var server = &bridge.servers.items[0];
    var initialize_response = try server.sendRequest(std.testing.allocator, "initialize", "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"makai\",\"version\":\"0.1.0\"}}", null, mcp_discovery_timeout_ms);
    defer initialize_response.deinit();
    try validateRpcResult(initialize_response.value);
    try server.sendNotification(std.testing.allocator, "notifications/initialized", "{}");
    var first_response = try server.sendRequest(std.testing.allocator, "tools/list", "{}", null, mcp_discovery_timeout_ms);
    defer first_response.deinit();
    try validateRpcResult(first_response.value);
    try std.testing.expect(server.stdout_pending.items.len > 0);
    var second_response = try server.sendRequest(std.testing.allocator, "tools/list", "{}", null, mcp_discovery_timeout_ms);
    defer second_response.deinit();
    try validateRpcResult(second_response.value);
    try std.testing.expectEqual(@as(usize, 0), server.stdout_pending.items.len);
}


test "MCP initialize rejects error or missing result" {
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try bridge.loadConfigJson("[{\"name\":\"mock\",\"command\":\"mock\"}]");

    var rpc_error = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"message\":\"bad\"}}", .{});
    defer rpc_error.deinit();
    bridge.servers.items[0].mock_response = rpc_error.value;
    try std.testing.expectError(error.McpToolError, bridge.discover());

    var missing_result = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1}", .{});
    defer missing_result.deinit();
    bridge.servers.items[0].mock_response = missing_result.value;
    try std.testing.expectError(error.InvalidMcpResponse, bridge.discover());
}


test "MCP execution honors cancellation while waiting" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const config_json = try makeShellConfigJson(std.testing.allocator, hangingMcpServerScript());
    defer std.testing.allocator.free(config_json);
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try bridge.loadConfigJson(config_json);
    const tool = try makeTestTool(&bridge, "echo");
    var cancelled = std.atomic.Value(bool).init(true);
    const token = ai_types.CancelToken{ .cancelled = &cancelled };
    try std.testing.expectError(error.Cancelled, tool.execute_with_context.?(tool.execute_ctx, "call_1", "{}", token, null, null, std.testing.allocator));
}


test "MCP discovery times out when server never responds" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const config_json = try makeShellConfigJson(std.testing.allocator, hangingMcpServerScript());
    defer std.testing.allocator.free(config_json);
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try bridge.loadConfigJson(config_json);
    try std.testing.expectError(error.Timeout, bridge.discover());
}


test "MCP discovery follows paginated tools list cursors" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const config_json = try makeShellConfigJson(std.testing.allocator, paginatedToolsListScript());
    defer std.testing.allocator.free(config_json);
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try bridge.loadConfigJson(config_json);
    try bridge.discover();
    try std.testing.expectEqual(@as(usize, 2), bridge.tools.items.len);
    try std.testing.expectEqualStrings("first", bridge.tools.items[0].mcp_name);
    try std.testing.expectEqualStrings("second", bridge.tools.items[1].mcp_name);
}


test "MCP sendRequest drains pending response before timeout" {
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try bridge.loadConfigJson("[{\"name\":\"mock\",\"command\":\"mock\"}]");
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":999,\"result\":{}}", .{});
    defer parsed.deinit();
    var server = &bridge.servers.items[0];
    server.mock_response = parsed.value;
    try server.stdout_pending.appendSlice(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n");
    var response = try server.sendRequest(std.testing.allocator, "initialize", "{}", null, 0);
    defer response.deinit();
    try validateRpcResult(response.value);
}


test "MCP tools/call arguments are compacted to one JSON-RPC line" {
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try bridge.loadConfigJson("[{\"name\":\"mock\",\"command\":\"mock\"}]");
    var response = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}",
        .{},
    );
    defer response.deinit();
    bridge.servers.items[0].mock_response = response.value;
    const tool = try makeTestTool(&bridge, "echo");
    var result = try tool.execute_with_context.?(tool.execute_ctx, "call_1", "{\n  \"value\": 1\n}", null, null, null, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", result.content.slice()[0].text.text);
}


test "MCP structured-only result is surfaced" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"structuredContent\":{\"answer\":42}}",
        .{},
    );
    defer parsed.deinit();
    var tool_result = try resultFromMcp(std.testing.allocator, parsed.value.object);
    defer tool_result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, tool_result.content.slice()[0].text.text, "\"answer\":42") != null);
}


test "MCP colliding sanitized names are disambiguated" {
    var bridge = McpBridge.init(std.testing.allocator);
    bridge.bind();
    defer bridge.deinit();
    try bridge.loadConfigJson("[{\"name\":\"mock\",\"command\":\"mock\"}]");
    var response = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"foo-bar\",\"description\":\"A\",\"inputSchema\":{\"type\":\"object\"}},{\"name\":\"foo_bar\",\"description\":\"B\",\"inputSchema\":{\"type\":\"object\"}}]}}",
        .{},
    );
    defer response.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try bridge.addToolsFromResponse(0, response.value));
    try std.testing.expectEqual(@as(usize, 2), bridge.tools.items.len);
    try expectNoDuplicateToolNames(&bridge);
    try std.testing.expectEqual(@as(usize, 1), countToolNames(&bridge, "mcp_mock_foo_bar"));
    try std.testing.expectEqual(@as(usize, 1), countToolNames(&bridge, "mcp_mock_foo_bar_2"));
}
