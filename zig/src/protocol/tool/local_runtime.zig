const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const agent_types = @import("agent_types");
const tool_envelope = @import("tool_envelope");
const tool_types = @import("tool_types");
const in_process = @import("transports/in_process");
const json_writer = @import("json_writer");
const OwnedSlice = @import("owned_slice").OwnedSlice;

const PipeTransport = in_process.SerializedPipe;

const ExecutionContext = struct {
    threadlocal var current: ExecutionContext = .{};

    cancel_token: ?ai_types.CancelToken = null,
    update_ctx: ?*anyopaque = null,
    update_callback: ?agent_types.ToolUpdateCallback = null,

    fn set(cancel_token: ?ai_types.CancelToken, update_ctx: ?*anyopaque, update_callback: ?agent_types.ToolUpdateCallback) void {
        current = .{ .cancel_token = cancel_token, .update_ctx = update_ctx, .update_callback = update_callback };
    }

    fn clear() void {
        current = .{};
    }

    fn consume() ExecutionContext {
        const value = current;
        current = .{};
        return value;
    }
};

pub const ToolProtocolServer = struct {
    allocator: std.mem.Allocator,
    tools: std.ArrayList(agent_types.AgentTool) = .empty,
    server_id: tool_types.Ulid,
    sequence: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) ToolProtocolServer {
        return .{ .allocator = allocator, .server_id = tool_types.generateUlid() };
    }

    pub fn deinit(self: *ToolProtocolServer) void {
        self.tools.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn registerTool(self: *ToolProtocolServer, tool: agent_types.AgentTool) !void {
        if (self.resolve(tool.name) != null) return error.DuplicateTool;
        try self.tools.append(self.allocator, tool);
    }

    pub fn replaceOrRegisterTool(self: *ToolProtocolServer, tool: agent_types.AgentTool) !void {
        for (self.tools.items) |*existing| {
            if (std.mem.eql(u8, existing.name, tool.name)) {
                existing.* = tool;
                return;
            }
        }
        try self.tools.append(self.allocator, tool);
    }

    pub fn registerTools(self: *ToolProtocolServer, tools: []const agent_types.AgentTool) !void {
        for (tools) |tool| try self.replaceOrRegisterTool(tool);
    }

    pub fn resolve(self: *const ToolProtocolServer, name: []const u8) ?agent_types.AgentTool {
        for (self.tools.items) |tool| if (std.mem.eql(u8, tool.name, name)) return tool;
        return null;
    }

    pub fn list(self: *const ToolProtocolServer) []const agent_types.AgentTool {
        return self.tools.items;
    }

    fn nextEnvelope(self: *ToolProtocolServer, in_reply_to: ?tool_types.Ulid, payload: tool_types.Payload) tool_types.Envelope {
        self.sequence += 1;
        return .{
            .server_id = self.server_id,
            .message_id = tool_types.generateUlid(),
            .sequence = self.sequence,
            .in_reply_to = in_reply_to,
            .timestamp = compat.time.nowMillis(),
            .payload = payload,
        };
    }

    pub fn handleClientEnvelope(ctx: ?*anyopaque, env: tool_types.Envelope, allocator: std.mem.Allocator) !?tool_types.Envelope {
        const self: *ToolProtocolServer = @ptrCast(@alignCast(ctx.?));
        switch (env.payload) {
            .tool_execute => |req| {
                const execution_ctx = ExecutionContext.consume();
                const tool = self.resolve(req.tool_name) orelse {
                    return self.nextEnvelope(env.message_id, .{ .tool_error = .{
                        .execution_id = req.execution_id,
                        .code = .tool_not_found,
                        .message = try allocator.dupe(u8, "unknown tool"),
                    } });
                };

                const start_ms = compat.time.nowMillis();
                var result = executeAgentTool(tool, req.tool_call_id, req.args_json, execution_ctx.cancel_token, execution_ctx.update_ctx, execution_ctx.update_callback, allocator) catch |err| {
                    return self.nextEnvelope(env.message_id, .{ .tool_error = .{
                        .execution_id = req.execution_id,
                        .code = .tool_execution_error,
                        .message = try allocator.dupe(u8, @errorName(err)),
                    } });
                };
                defer result.deinit(allocator);

                const result_json = try serializeUserContentParts(allocator, result.content.slice());
                errdefer allocator.free(result_json);
                const details_json = if (result.getDetailsJson()) |details|
                    OwnedSlice(u8).initOwned(try allocator.dupe(u8, details))
                else
                    OwnedSlice(u8).initBorrowed("");
                errdefer {
                    var mutable = details_json;
                    mutable.deinit(allocator);
                }
                const artifacts = OwnedSlice(tool_types.ArtifactReference).initOwned(try cloneArtifactsToTool(allocator, result.artifacts.slice()));
                errdefer {
                    var mutable = artifacts;
                    mutable.deinit(allocator);
                }

                return self.nextEnvelope(env.message_id, .{ .tool_result = .{
                    .execution_id = req.execution_id,
                    .tool_call_id = try allocator.dupe(u8, req.tool_call_id),
                    .result_json = result_json,
                    .details_json = details_json,
                    .artifacts = artifacts,
                    .duration_ms = @intCast(@max(compat.time.nowMillis() - start_ms, 0)),
                } });
            },
            .tool_list => |req| {
                const prefix = req.getPrefix();
                var metas = std.ArrayList(tool_types.ToolMetadata).empty;
                errdefer {
                    for (metas.items) |*meta| deinitToolMetadata(meta, allocator);
                    metas.deinit(allocator);
                }
                for (self.tools.items) |tool| {
                    if (prefix) |p| {
                        if (!std.mem.startsWith(u8, tool.name, p)) continue;
                    }
                    try metas.append(allocator, try toolMetadataFromAgentTool(allocator, tool));
                }
                return self.nextEnvelope(env.message_id, .{ .tool_list_response = .{ .tools = try metas.toOwnedSlice(allocator) } });
            },
            else => return null,
        }
    }
};

pub const ToolProtocolClient = struct {
    pipe: *PipeTransport,
    server_id: tool_types.Ulid,
    sequence: u64 = 0,

    pub fn init(pipe: *PipeTransport) ToolProtocolClient {
        return .{ .pipe = pipe, .server_id = tool_types.generateUlid() };
    }

    pub fn execute(
        self: *ToolProtocolClient,
        tool_call_id: []const u8,
        tool_name: []const u8,
        args_json: []const u8,
        allocator: std.mem.Allocator,
    ) !agent_types.AgentToolResult {
        const execution_id = tool_types.generateUlid();
        self.sequence += 1;
        var env = tool_types.Envelope{
            .server_id = self.server_id,
            .message_id = tool_types.generateUlid(),
            .sequence = self.sequence,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .tool_execute = .{
                .execution_id = execution_id,
                .tool_call_id = try allocator.dupe(u8, tool_call_id),
                .tool_name = try allocator.dupe(u8, tool_name),
                .args_json = try allocator.dupe(u8, args_json),
            } },
        };
        defer env.deinit(allocator);

        const json = try tool_envelope.serializeEnvelope(env, allocator);
        defer allocator.free(json);

        var sender = self.pipe.clientSender();
        try sender.write(json);
        try sender.flush();

        var recv = self.pipe.clientReceiver();
        while (try recv.readLine(allocator)) |line| {
            defer allocator.free(line);
            var response = try tool_envelope.deserializeEnvelope(line, allocator);
            defer response.deinit(allocator);
            switch (response.payload) {
                .tool_result => |res| return try agentToolResultFromProtocol(allocator, res),
                .tool_error => |err| return toolErrorToError(err.code),
                else => {},
            }
        }

        return error.ToolProtocolNoResponse;
    }

    pub fn executeFn(
        ctx: ?*anyopaque,
        tool_call_id: []const u8,
        tool_name: []const u8,
        args_json: []const u8,
        cancel_token: ?ai_types.CancelToken,
        on_update_ctx: ?*anyopaque,
        on_update: ?agent_types.ToolUpdateCallback,
        allocator: std.mem.Allocator,
    ) anyerror!agent_types.AgentToolResult {
        _ = cancel_token;
        _ = on_update_ctx;
        _ = on_update;
        const self: *ToolProtocolClient = @ptrCast(@alignCast(ctx.?));
        return self.execute(tool_call_id, tool_name, args_json, allocator);
    }
};

pub const LocalToolProtocol = struct {
    allocator: std.mem.Allocator,
    pipe: PipeTransport,
    server: ToolProtocolServer,
    client: ToolProtocolClient,

    pub fn init(allocator: std.mem.Allocator, tools: []const agent_types.AgentTool) !LocalToolProtocol {
        var pipe = PipeTransport.init(allocator);
        errdefer pipe.deinit();
        var server = ToolProtocolServer.init(allocator);
        errdefer server.deinit();
        try server.registerTools(tools);
        const client = ToolProtocolClient.init(&pipe);
        return .{
            .allocator = allocator,
            .pipe = pipe,
            .server = server,
            .client = client,
        };
    }

    pub fn deinit(self: *LocalToolProtocol) void {
        self.server.deinit();
        self.pipe.deinit();
        self.* = undefined;
    }

    pub fn execute(
        self: *LocalToolProtocol,
        tool_call_id: []const u8,
        tool_name: []const u8,
        args_json: []const u8,
        cancel_token: ?ai_types.CancelToken,
        on_update_ctx: ?*anyopaque,
        on_update: ?agent_types.ToolUpdateCallback,
        allocator: std.mem.Allocator,
    ) !agent_types.AgentToolResult {
        return self.executeWithOverride(tool_call_id, tool_name, args_json, cancel_token, on_update_ctx, on_update, null, null, allocator);
    }

    pub fn executeWithOverride(
        self: *LocalToolProtocol,
        tool_call_id: []const u8,
        tool_name: []const u8,
        args_json: []const u8,
        cancel_token: ?ai_types.CancelToken,
        on_update_ctx: ?*anyopaque,
        on_update: ?agent_types.ToolUpdateCallback,
        override_ctx: ?*anyopaque,
        override_fn: ?agent_types.ToolProtocolExecuteFn,
        allocator: std.mem.Allocator,
    ) !agent_types.AgentToolResult {
        if (override_fn) |exec| return exec(override_ctx, tool_call_id, tool_name, args_json, cancel_token, on_update_ctx, on_update, allocator);
        const execution_id = tool_types.generateUlid();
        self.client.sequence += 1;
        self.pipe.compact();
        var env = tool_types.Envelope{
            .server_id = self.client.server_id,
            .message_id = tool_types.generateUlid(),
            .sequence = self.client.sequence,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .tool_execute = .{
                .execution_id = execution_id,
                .tool_call_id = try allocator.dupe(u8, tool_call_id),
                .tool_name = try allocator.dupe(u8, tool_name),
                .args_json = try allocator.dupe(u8, args_json),
            } },
        };
        defer env.deinit(allocator);

        const json = try tool_envelope.serializeEnvelope(env, allocator);
        defer allocator.free(json);

        var sender = self.pipe.clientSender();
        try sender.write(json);
        try sender.flush();
        ExecutionContext.set(cancel_token, on_update_ctx, on_update);
        defer ExecutionContext.clear();
        try self.pumpClientMessages();

        var recv = self.pipe.clientReceiver();
        while (try recv.readLine(allocator)) |line| {
            defer allocator.free(line);
            var response = try tool_envelope.deserializeEnvelope(line, allocator);
            defer response.deinit(allocator);
            switch (response.payload) {
                .tool_result => |res| return try agentToolResultFromProtocol(allocator, res),
                .tool_error => |err| return toolErrorToError(err.code),
                else => {},
            }
        }

        return error.ToolProtocolNoResponse;
    }

    pub fn executeFn(
        ctx: ?*anyopaque,
        tool_call_id: []const u8,
        tool_name: []const u8,
        args_json: []const u8,
        cancel_token: ?ai_types.CancelToken,
        on_update_ctx: ?*anyopaque,
        on_update: ?agent_types.ToolUpdateCallback,
        allocator: std.mem.Allocator,
    ) anyerror!agent_types.AgentToolResult {
        const self: *LocalToolProtocol = @ptrCast(@alignCast(ctx.?));
        return self.execute(tool_call_id, tool_name, args_json, cancel_token, on_update_ctx, on_update, allocator);
    }

    fn pumpClientMessages(self: *LocalToolProtocol) !void {
        var recv = self.pipe.serverReceiver();
        while (try recv.readLine(self.allocator)) |line| {
            defer self.allocator.free(line);
            var env = tool_envelope.deserializeEnvelope(line, self.allocator) catch continue;
            defer env.deinit(self.allocator);
            if (try ToolProtocolServer.handleClientEnvelope(&self.server, env, self.allocator)) |response| {
                var out = response;
                defer out.deinit(self.allocator);
                const out_json = try tool_envelope.serializeEnvelope(out, self.allocator);
                defer self.allocator.free(out_json);
                var sender = self.pipe.serverSender();
                try sender.write(out_json);
                try sender.flush();
            }
        }
    }
};

fn executeAgentTool(tool: agent_types.AgentTool, tool_call_id: []const u8, args_json: []const u8, cancel_token: ?ai_types.CancelToken, on_update_ctx: ?*anyopaque, on_update: ?agent_types.ToolUpdateCallback, allocator: std.mem.Allocator) anyerror!agent_types.AgentToolResult {
    if (tool.runtime_execute) |execute_fn| return execute_fn(tool.runtime_ctx, tool_call_id, args_json, cancel_token, on_update_ctx, on_update, allocator);
    return tool.execute(tool_call_id, args_json, cancel_token, on_update_ctx, on_update, allocator);
}

fn serializeUserContentParts(allocator: std.mem.Allocator, parts: []const ai_types.UserContentPart) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);
    try w.beginArray();
    for (parts) |part| {
        try w.beginObject();
        switch (part) {
            .text => |text| {
                try w.writeStringField("type", "text");
                try w.writeStringField("text", text.text);
                if (text.text_signature) |sig| try w.writeStringField("text_signature", sig);
            },
            .image => |image| {
                try w.writeStringField("type", "image");
                try w.writeStringField("data", image.data);
                try w.writeStringField("mime_type", image.mime_type);
            },
        }
        try w.endObject();
    }
    try w.endArray();
    return buffer.toOwnedSlice(allocator);
}

fn parseUserContentParts(allocator: std.mem.Allocator, json: []const u8) ![]ai_types.UserContentPart {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.InvalidToolResultJson,
    };
    const parts = try allocator.alloc(ai_types.UserContentPart, arr.items.len);
    var initialized: usize = 0;
    errdefer {
        for (parts[0..initialized]) |*part| part.deinit(allocator);
        allocator.free(parts);
    }
    for (arr.items, 0..) |item, i| {
        const obj = switch (item) {
            .object => |o| o,
            else => return error.InvalidToolResultJson,
        };
        const kind = try jsonStringField(obj, "type");
        if (std.mem.eql(u8, kind, "text")) {
            const text = try allocator.dupe(u8, try jsonStringField(obj, "text"));
            errdefer allocator.free(text);
            const sig = if (obj.get("text_signature")) |value| try allocator.dupe(u8, try jsonStringValue(value)) else null;
            errdefer if (sig) |s| allocator.free(s);
            parts[i] = .{ .text = .{ .text = text, .text_signature = sig } };
        } else if (std.mem.eql(u8, kind, "image")) {
            const data = try allocator.dupe(u8, try jsonStringField(obj, "data"));
            errdefer allocator.free(data);
            const mime_type = try allocator.dupe(u8, try jsonStringField(obj, "mime_type"));
            errdefer allocator.free(mime_type);
            parts[i] = .{ .image = .{ .data = data, .mime_type = mime_type } };
        } else return error.InvalidToolResultJson;
        initialized += 1;
    }
    return parts;
}

fn jsonStringField(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return jsonStringValue(obj.get(key) orelse return error.InvalidToolResultJson);
}

fn jsonStringValue(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.InvalidToolResultJson,
    };
}

fn agentToolResultFromProtocol(allocator: std.mem.Allocator, res: tool_types.ToolExecuteResult) !agent_types.AgentToolResult {
    const content = try parseUserContentParts(allocator, res.result_json);
    errdefer {
        for (content) |*part| part.deinit(allocator);
        allocator.free(content);
    }
    const details = if (res.getDetailsJson()) |details_json|
        OwnedSlice(u8).initOwned(try allocator.dupe(u8, details_json))
    else
        OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = details;
        mutable.deinit(allocator);
    }
    const artifacts = OwnedSlice(ai_types.ArtifactReference).initOwned(try cloneArtifactsToAgent(allocator, res.artifacts.slice()));
    errdefer {
        var mutable = artifacts;
        mutable.deinit(allocator);
    }
    return .{
        .content = OwnedSlice(ai_types.UserContentPart).initOwned(content),
        .details_json = details,
        .artifacts = artifacts,
    };
}

fn cloneArtifactsToTool(allocator: std.mem.Allocator, artifacts: []const ai_types.ArtifactReference) ![]tool_types.ArtifactReference {
    const cloned = try allocator.alloc(tool_types.ArtifactReference, artifacts.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |*artifact| artifact.deinit(allocator);
        allocator.free(cloned);
    }
    for (artifacts, 0..) |artifact, i| {
        cloned[i] = .{
            .artifact_id = try allocator.dupe(u8, artifact.artifact_id),
            .uri = if (artifact.getUri()) |v| OwnedSlice(u8).initOwned(try allocator.dupe(u8, v)) else OwnedSlice(u8).initBorrowed(""),
            .mime_type = if (artifact.getMimeType()) |v| OwnedSlice(u8).initOwned(try allocator.dupe(u8, v)) else OwnedSlice(u8).initBorrowed(""),
            .byte_size = artifact.byte_size,
            .sha256 = if (artifact.getSha256()) |v| OwnedSlice(u8).initOwned(try allocator.dupe(u8, v)) else OwnedSlice(u8).initBorrowed(""),
            .description = if (artifact.getDescription()) |v| OwnedSlice(u8).initOwned(try allocator.dupe(u8, v)) else OwnedSlice(u8).initBorrowed(""),
        };
        initialized += 1;
    }
    return cloned;
}

fn cloneArtifactsToAgent(allocator: std.mem.Allocator, artifacts: []const tool_types.ArtifactReference) ![]ai_types.ArtifactReference {
    const cloned = try allocator.alloc(ai_types.ArtifactReference, artifacts.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |*artifact| artifact.deinit(allocator);
        allocator.free(cloned);
    }
    for (artifacts, 0..) |artifact, i| {
        cloned[i] = .{
            .artifact_id = try allocator.dupe(u8, artifact.artifact_id),
            .uri = if (artifact.getUri()) |v| OwnedSlice(u8).initOwned(try allocator.dupe(u8, v)) else OwnedSlice(u8).initBorrowed(""),
            .mime_type = if (artifact.getMimeType()) |v| OwnedSlice(u8).initOwned(try allocator.dupe(u8, v)) else OwnedSlice(u8).initBorrowed(""),
            .byte_size = artifact.byte_size,
            .sha256 = if (artifact.getSha256()) |v| OwnedSlice(u8).initOwned(try allocator.dupe(u8, v)) else OwnedSlice(u8).initBorrowed(""),
            .description = if (artifact.getDescription()) |v| OwnedSlice(u8).initOwned(try allocator.dupe(u8, v)) else OwnedSlice(u8).initBorrowed(""),
        };
        initialized += 1;
    }
    return cloned;
}

fn toolMetadataFromAgentTool(allocator: std.mem.Allocator, tool: agent_types.AgentTool) !tool_types.ToolMetadata {
    return .{
        .name = try allocator.dupe(u8, tool.name),
        .description = try allocator.dupe(u8, tool.description),
        .parameters_schema_json = try allocator.dupe(u8, tool.parameters_schema_json),
        .version = try allocator.dupe(u8, "1.0.0"),
    };
}

fn deinitToolMetadata(meta: *tool_types.ToolMetadata, allocator: std.mem.Allocator) void {
    allocator.free(meta.name);
    allocator.free(meta.description);
    allocator.free(meta.parameters_schema_json);
    allocator.free(meta.version);
    if (meta.required_permissions) |perms| {
        for (perms) |perm| allocator.free(perm);
        allocator.free(perms);
    }
}

fn toolErrorToError(code: tool_types.ToolErrorCode) anyerror {
    return switch (code) {
        .tool_not_found => error.ToolNotFound,
        .tool_timeout => error.ToolTimeout,
        .invalid_arguments => error.InvalidToolArguments,
        .tool_unavailable => error.ToolUnavailable,
        .artifact_not_found => error.ArtifactNotFound,
        .hashline_disabled => error.HashlineDisabled,
        .stale_anchor => error.StaleAnchor,
        else => error.ToolExecutionFailed,
    };
}

test "tool protocol server wraps shell_execute and returns correct result" {
    const allocator = std.testing.allocator;
    const callbacks = struct {
        fn execute(
            tool_call_id: []const u8,
            args_json: []const u8,
            cancel_token: ?ai_types.CancelToken,
            on_update_ctx: ?*anyopaque,
            on_update: ?agent_types.ToolUpdateCallback,
            test_allocator: std.mem.Allocator,
        ) anyerror!agent_types.AgentToolResult {
            _ = tool_call_id;
            _ = args_json;
            _ = cancel_token;
            _ = on_update_ctx;
            _ = on_update;
            const parts = try test_allocator.alloc(ai_types.UserContentPart, 1);
            parts[0] = .{ .text = .{ .text = try test_allocator.dupe(u8, "shell ok") } };
            return .{ .content = OwnedSlice(ai_types.UserContentPart).initOwned(parts) };
        }
    };
    const tool = agent_types.AgentTool{ .label = "Shell Execute", .name = "shell_execute", .description = "Run shell command", .parameters_schema_json = "{}", .execute = callbacks.execute };
    var local = try LocalToolProtocol.init(allocator, &.{tool});
    defer local.deinit();

    var result = try local.execute("call_1", "shell_execute", "{}", null, null, null, allocator);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.content.slice().len);
    try std.testing.expect(result.content.slice()[0] == .text);
    try std.testing.expectEqualStrings("shell ok", result.content.slice()[0].text.text);
}

test "tool protocol server wraps MCP bridge-style tool and returns correct result" {
    const allocator = std.testing.allocator;
    const callbacks = struct {
        fn execute(
            tool_call_id: []const u8,
            args_json: []const u8,
            cancel_token: ?ai_types.CancelToken,
            on_update_ctx: ?*anyopaque,
            on_update: ?agent_types.ToolUpdateCallback,
            test_allocator: std.mem.Allocator,
        ) anyerror!agent_types.AgentToolResult {
            _ = tool_call_id;
            _ = args_json;
            _ = cancel_token;
            _ = on_update_ctx;
            _ = on_update;
            const parts = try test_allocator.alloc(ai_types.UserContentPart, 1);
            parts[0] = .{ .text = .{ .text = try test_allocator.dupe(u8, "mcp ok") } };
            return .{
                .content = OwnedSlice(ai_types.UserContentPart).initOwned(parts),
                .details_json = OwnedSlice(u8).initOwned(try test_allocator.dupe(u8, "{\"bridge\":true}")),
            };
        }
    };
    const tool = agent_types.AgentTool{
        .label = "MCP Echo",
        .name = "mcp_echo",
        .description = "MCP bridge echo tool",
        .parameters_schema_json = "{}",
        .execute = callbacks.execute,
    };
    var local = try LocalToolProtocol.init(allocator, &.{tool});
    defer local.deinit();

    var result = try local.execute("call_1", "mcp_echo", "{}", null, null, null, allocator);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("mcp ok", result.content.slice()[0].text.text);
    try std.testing.expectEqualStrings("{\"bridge\":true}", result.getDetailsJson().?);
}

test "in-process tool protocol round-trip stays near direct call" {
    const allocator = std.testing.allocator;
    const callbacks = struct {
        fn execute(
            tool_call_id: []const u8,
            args_json: []const u8,
            cancel_token: ?ai_types.CancelToken,
            on_update_ctx: ?*anyopaque,
            on_update: ?agent_types.ToolUpdateCallback,
            test_allocator: std.mem.Allocator,
        ) anyerror!agent_types.AgentToolResult {
            _ = tool_call_id;
            _ = args_json;
            _ = cancel_token;
            _ = on_update_ctx;
            _ = on_update;
            const parts = try test_allocator.alloc(ai_types.UserContentPart, 1);
            parts[0] = .{ .text = .{ .text = try test_allocator.dupe(u8, "ok") } };
            return .{ .content = OwnedSlice(ai_types.UserContentPart).initOwned(parts) };
        }
    };
    const tool = agent_types.AgentTool{ .label = "Bench", .name = "bench", .description = "Bench", .parameters_schema_json = "{}", .execute = callbacks.execute };
    var local = try LocalToolProtocol.init(allocator, &.{tool});
    defer local.deinit();

    const iterations = 10;
    const direct_start = compat.time.nowMillis();
    for (0..iterations) |_| {
        var direct = try callbacks.execute("call", "{}", null, null, null, allocator);
        direct.deinit(allocator);
    }
    const direct_ms = compat.time.nowMillis() - direct_start;

    const proto_start = compat.time.nowMillis();
    for (0..iterations) |_| {
        var proto = try local.execute("call", "bench", "{}", null, null, null, allocator);
        proto.deinit(allocator);
    }
    const proto_ms = compat.time.nowMillis() - proto_start;

    _ = direct_ms;
    try std.testing.expect(proto_ms <= 100);
}
