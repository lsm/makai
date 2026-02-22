const std = @import("std");
const tool_types = @import("tool_types");
const json_writer = @import("json_writer");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const protocol_types = tool_types;

pub fn serializeEnvelope(env: tool_types.Envelope, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);

    try w.beginObject();
    try w.writeStringField("type", @tagName(env.payload));

    const server_id_str = try tool_types.uuidToString(env.server_id, allocator);
    defer allocator.free(server_id_str);
    try w.writeStringField("server_id", server_id_str);

    const message_id_str = try tool_types.uuidToString(env.message_id, allocator);
    defer allocator.free(message_id_str);
    try w.writeStringField("message_id", message_id_str);

    try w.writeIntField("sequence", env.sequence);
    try w.writeIntField("timestamp", env.timestamp);
    try w.writeIntField("version", env.version);

    if (env.in_reply_to) |reply_to| {
        const reply_to_str = try tool_types.uuidToString(reply_to, allocator);
        defer allocator.free(reply_to_str);
        try w.writeStringField("in_reply_to", reply_to_str);
    }

    try w.writeKey("payload");
    try serializePayload(&w, env.payload, allocator);
    try w.endObject();

    const out = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return out;
}

fn serializePayload(w: *json_writer.JsonWriter, payload: tool_types.Payload, allocator: std.mem.Allocator) !void {
    try w.beginObject();

    switch (payload) {
        .tool_register => |req| {
            try w.writeKey("tool");
            try serializeToolMetadata(w, req.tool);
            if (req.getCallbackUrl()) |url| try w.writeStringField("callback_url", url);
        },
        .tool_registered => |res| {
            try w.writeStringField("tool_id", res.tool_id);
            try w.writeIntField("registered_at", res.registered_at);
        },
        .tool_unregister => |req| try w.writeStringField("tool_id", req.tool_id),
        .tool_unregistered => |res| try w.writeStringField("tool_id", res.tool_id),
        .tool_list => |req| {
            if (req.getPrefix()) |prefix| try w.writeStringField("prefix", prefix);
            if (req.supports_streaming) |supports_streaming| try w.writeBoolField("supports_streaming", supports_streaming);
        },
        .tool_list_response => |res| {
            try w.writeKey("tools");
            try w.beginArray();
            for (res.tools) |tool| {
                try serializeToolMetadata(w, tool);
            }
            try w.endArray();
        },
        .tool_execute => |req| {
            const execution_id_str = try tool_types.uuidToString(req.execution_id, allocator);
            defer allocator.free(execution_id_str);
            try w.writeStringField("execution_id", execution_id_str);
            try w.writeStringField("tool_call_id", req.tool_call_id);
            try w.writeStringField("tool_name", req.tool_name);
            try w.writeStringField("args_json", req.args_json);
            if (req.timeout_ms) |timeout_ms| try w.writeIntField("timeout_ms", timeout_ms);
            if (req.getStreamCallbackUrl()) |url| try w.writeStringField("stream_callback_url", url);
        },
        .tool_stream => |update| {
            const execution_id_str = try tool_types.uuidToString(update.execution_id, allocator);
            defer allocator.free(execution_id_str);
            try w.writeStringField("execution_id", execution_id_str);
            try w.writeStringField("tool_call_id", update.tool_call_id);
            try w.writeStringField("partial_result_json", update.partial_result_json);
            if (update.progress) |progress| try w.writeIntField("progress", progress);
            if (update.getStatus()) |status| try w.writeStringField("status", status);
        },
        .tool_result => |res| {
            const execution_id_str = try tool_types.uuidToString(res.execution_id, allocator);
            defer allocator.free(execution_id_str);
            try w.writeStringField("execution_id", execution_id_str);
            try w.writeStringField("tool_call_id", res.tool_call_id);
            try w.writeStringField("result_json", res.result_json);
            try w.writeBoolField("is_error", res.is_error);
            if (res.getErrorMessage()) |msg| try w.writeStringField("error_message", msg);
            if (res.getDetailsJson()) |details| try w.writeStringField("details_json", details);
            try w.writeIntField("duration_ms", res.duration_ms);
        },
        .tool_cancel => |req| {
            const execution_id_str = try tool_types.uuidToString(req.execution_id, allocator);
            defer allocator.free(execution_id_str);
            try w.writeStringField("execution_id", execution_id_str);
            if (req.getReason()) |reason| try w.writeStringField("reason", reason);
        },
        .tool_cancelled => |cancelled| {
            const execution_id_str = try tool_types.uuidToString(cancelled.execution_id, allocator);
            defer allocator.free(execution_id_str);
            try w.writeStringField("execution_id", execution_id_str);
        },
        .tool_error => |err| {
            const execution_id_str = try tool_types.uuidToString(err.execution_id, allocator);
            defer allocator.free(execution_id_str);
            try w.writeStringField("execution_id", execution_id_str);
            try w.writeStringField("code", @tagName(err.code));
            try w.writeStringField("message", err.message);
        },
        .tool_status => |req| {
            const execution_id_str = try tool_types.uuidToString(req.execution_id, allocator);
            defer allocator.free(execution_id_str);
            try w.writeStringField("execution_id", execution_id_str);
        },
        .tool_status_response => |info| {
            const execution_id_str = try tool_types.uuidToString(info.execution_id, allocator);
            defer allocator.free(execution_id_str);
            try w.writeStringField("execution_id", execution_id_str);
            try w.writeStringField("tool_name", info.tool_name);
            try w.writeStringField("status", @tagName(info.status));
            try w.writeIntField("started_at", info.started_at);
            if (info.completed_at) |completed_at| try w.writeIntField("completed_at", completed_at);
        },
        .ping => {},
        .pong => |pong| try w.writeStringField("ping_id", pong.ping_id.slice()),
        .goodbye => |goodbye| {
            if (goodbye.getReason()) |reason| try w.writeStringField("reason", reason);
        },
    }

    try w.endObject();
}

fn serializeToolMetadata(w: *json_writer.JsonWriter, tool: tool_types.ToolMetadata) !void {
    try w.beginObject();
    try w.writeStringField("name", tool.name);
    try w.writeStringField("description", tool.description);
    try w.writeStringField("parameters_schema_json", tool.parameters_schema_json);
    try w.writeStringField("version", tool.version);
    try w.writeBoolField("supports_streaming", tool.supports_streaming);
    if (tool.estimated_duration_ms) |duration_ms| try w.writeIntField("estimated_duration_ms", duration_ms);
    try w.writeBoolField("is_destructive", tool.is_destructive);
    if (tool.required_permissions) |permissions| {
        try w.writeKey("required_permissions");
        try w.beginArray();
        for (permissions) |permission| {
            try w.writeString(permission);
        }
        try w.endArray();
    }
    try w.endObject();
}

pub fn deserializeEnvelope(json: []const u8, allocator: std.mem.Allocator) !tool_types.Envelope {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const type_str = root.get("type").?.string;
    const server_id = try parseUuidRequired(root.get("server_id").?.string);
    const message_id = try parseUuidRequired(root.get("message_id").?.string);
    const sequence = @as(u64, @intCast(root.get("sequence").?.integer));
    const timestamp = root.get("timestamp").?.integer;
    const version = @as(u8, @intCast(root.get("version").?.integer));

    var in_reply_to: ?tool_types.Uuid = null;
    if (root.get("in_reply_to")) |v| in_reply_to = try parseUuidRequired(v.string);

    const payload_obj = root.get("payload").?.object;
    const payload = try deserializePayload(type_str, payload_obj, allocator);

    return .{
        .version = version,
        .server_id = server_id,
        .message_id = message_id,
        .sequence = sequence,
        .in_reply_to = in_reply_to,
        .timestamp = timestamp,
        .payload = payload,
    };
}

fn parseUuidRequired(str: []const u8) !tool_types.Uuid {
    return tool_types.parseUuid(str) orelse error.InvalidUuid;
}

fn deserializePayload(type_str: []const u8, payload: std.json.ObjectMap, allocator: std.mem.Allocator) !tool_types.Payload {
    if (std.mem.eql(u8, type_str, "tool_register")) {
        const tool = try deserializeToolMetadata(payload.get("tool").?.object, allocator);
        var req = tool_types.ToolRegisterRequest{ .tool = tool };
        if (payload.get("callback_url")) |v| req.callback_url = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .tool_register = req };
    }
    if (std.mem.eql(u8, type_str, "tool_registered")) {
        return .{ .tool_registered = .{
            .tool_id = try allocator.dupe(u8, payload.get("tool_id").?.string),
            .registered_at = payload.get("registered_at").?.integer,
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_unregister")) {
        return .{ .tool_unregister = .{
            .tool_id = try allocator.dupe(u8, payload.get("tool_id").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_unregistered")) {
        return .{ .tool_unregistered = .{
            .tool_id = try allocator.dupe(u8, payload.get("tool_id").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_list")) {
        var req = tool_types.ToolListRequest{};
        if (payload.get("prefix")) |v| req.prefix = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        if (payload.get("supports_streaming")) |v| req.supports_streaming = v.bool;
        return .{ .tool_list = req };
    }
    if (std.mem.eql(u8, type_str, "tool_list_response")) {
        const tools_arr = payload.get("tools").?.array;
        const tools = try allocator.alloc(tool_types.ToolMetadata, tools_arr.items.len);
        for (tools_arr.items, 0..) |t, i| {
            tools[i] = try deserializeToolMetadata(t.object, allocator);
        }
        return .{ .tool_list_response = .{ .tools = tools } };
    }
    if (std.mem.eql(u8, type_str, "tool_execute")) {
        const args_json = try allocator.dupe(u8, payload.get("args_json").?.string);
        errdefer allocator.free(args_json);
        try validateJson(args_json, allocator);

        var req = tool_types.ToolExecuteRequest{
            .execution_id = try parseUuidRequired(payload.get("execution_id").?.string),
            .tool_call_id = try allocator.dupe(u8, payload.get("tool_call_id").?.string),
            .tool_name = try allocator.dupe(u8, payload.get("tool_name").?.string),
            .args_json = args_json,
        };
        if (payload.get("timeout_ms")) |v| req.timeout_ms = @as(u32, @intCast(v.integer));
        if (payload.get("stream_callback_url")) |v| req.stream_callback_url = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .tool_execute = req };
    }
    if (std.mem.eql(u8, type_str, "tool_stream")) {
        var update = tool_types.ToolStreamUpdate{
            .execution_id = try parseUuidRequired(payload.get("execution_id").?.string),
            .tool_call_id = try allocator.dupe(u8, payload.get("tool_call_id").?.string),
            .partial_result_json = try allocator.dupe(u8, payload.get("partial_result_json").?.string),
        };
        if (payload.get("progress")) |v| update.progress = @as(u8, @intCast(v.integer));
        if (payload.get("status")) |v| update.status = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .tool_stream = update };
    }
    if (std.mem.eql(u8, type_str, "tool_result")) {
        var result = tool_types.ToolExecuteResult{
            .execution_id = try parseUuidRequired(payload.get("execution_id").?.string),
            .tool_call_id = try allocator.dupe(u8, payload.get("tool_call_id").?.string),
            .result_json = try allocator.dupe(u8, payload.get("result_json").?.string),
            .is_error = if (payload.get("is_error")) |v| v.bool else false,
            .duration_ms = @as(u32, @intCast(payload.get("duration_ms").?.integer)),
        };
        if (payload.get("error_message")) |v| result.error_message = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        if (payload.get("details_json")) |v| result.details_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .tool_result = result };
    }
    if (std.mem.eql(u8, type_str, "tool_cancel")) {
        var req = tool_types.ToolCancelRequest{
            .execution_id = try parseUuidRequired(payload.get("execution_id").?.string),
        };
        if (payload.get("reason")) |v| req.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .tool_cancel = req };
    }
    if (std.mem.eql(u8, type_str, "tool_cancelled")) {
        return .{ .tool_cancelled = .{
            .execution_id = try parseUuidRequired(payload.get("execution_id").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_error")) {
        return .{ .tool_error = .{
            .execution_id = try parseUuidRequired(payload.get("execution_id").?.string),
            .code = std.meta.stringToEnum(tool_types.ToolErrorCode, payload.get("code").?.string) orelse return error.InvalidPayloadType,
            .message = try allocator.dupe(u8, payload.get("message").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_status")) {
        return .{ .tool_status = .{
            .execution_id = try parseUuidRequired(payload.get("execution_id").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_status_response")) {
        return .{ .tool_status_response = .{
            .execution_id = try parseUuidRequired(payload.get("execution_id").?.string),
            .tool_name = try allocator.dupe(u8, payload.get("tool_name").?.string),
            .status = std.meta.stringToEnum(tool_types.ToolExecutionStatus, payload.get("status").?.string) orelse return error.InvalidPayloadType,
            .started_at = payload.get("started_at").?.integer,
            .completed_at = if (payload.get("completed_at")) |v| v.integer else null,
        } };
    }
    if (std.mem.eql(u8, type_str, "ping")) return .ping;
    if (std.mem.eql(u8, type_str, "pong")) {
        return .{ .pong = .{
            .ping_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, payload.get("ping_id").?.string)),
        } };
    }
    if (std.mem.eql(u8, type_str, "goodbye")) {
        var goodbye = tool_types.Goodbye{};
        if (payload.get("reason")) |v| goodbye.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .goodbye = goodbye };
    }

    return error.InvalidPayloadType;
}

fn deserializeToolMetadata(obj: std.json.ObjectMap, allocator: std.mem.Allocator) !tool_types.ToolMetadata {
    var required_permissions: ?[]const []const u8 = null;
    if (obj.get("required_permissions")) |permissions_value| {
        const permissions_arr = permissions_value.array;
        const permissions = try allocator.alloc([]const u8, permissions_arr.items.len);
        for (permissions_arr.items, 0..) |permission, i| {
            permissions[i] = try allocator.dupe(u8, permission.string);
        }
        required_permissions = permissions;
    }

    return .{
        .name = try allocator.dupe(u8, obj.get("name").?.string),
        .description = try allocator.dupe(u8, obj.get("description").?.string),
        .parameters_schema_json = try allocator.dupe(u8, obj.get("parameters_schema_json").?.string),
        .version = if (obj.get("version")) |v| try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "1.0.0"),
        .supports_streaming = if (obj.get("supports_streaming")) |v| v.bool else false,
        .estimated_duration_ms = if (obj.get("estimated_duration_ms")) |v| @as(u32, @intCast(v.integer)) else null,
        .is_destructive = if (obj.get("is_destructive")) |v| v.bool else false,
        .required_permissions = required_permissions,
    };
}

fn validateJson(json: []const u8, allocator: std.mem.Allocator) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.InvalidArgumentsJson;
    defer parsed.deinit();
}

test "tool envelope roundtrip execute request" {
    const allocator = std.testing.allocator;

    var env = tool_types.Envelope{
        .server_id = tool_types.generateUuid(),
        .message_id = tool_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .tool_execute = .{
            .execution_id = tool_types.generateUuid(),
            .tool_call_id = try allocator.dupe(u8, "call_123"),
            .tool_name = try allocator.dupe(u8, "search"),
            .args_json = try allocator.dupe(u8, "{\"query\":\"zig\"}"),
            .timeout_ms = 5_000,
            .stream_callback_url = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "http://127.0.0.1:8080/callback")),
        } },
    };
    defer env.deinit(allocator);

    const json = try serializeEnvelope(env, allocator);
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.payload == .tool_execute);
    try std.testing.expectEqualStrings("call_123", parsed.payload.tool_execute.tool_call_id);
    try std.testing.expectEqualStrings("search", parsed.payload.tool_execute.tool_name);
    try std.testing.expectEqualStrings("{\"query\":\"zig\"}", parsed.payload.tool_execute.args_json);
    try std.testing.expectEqual(@as(u32, 5_000), parsed.payload.tool_execute.timeout_ms.?);
}

test "tool envelope roundtrip list response" {
    const allocator = std.testing.allocator;

    const tools = try allocator.alloc(tool_types.ToolMetadata, 1);
    tools[0] = .{
        .name = try allocator.dupe(u8, "grep"),
        .description = try allocator.dupe(u8, "Search text"),
        .parameters_schema_json = try allocator.dupe(u8, "{\"type\":\"object\"}"),
        .version = try allocator.dupe(u8, "1.2.3"),
        .supports_streaming = false,
        .estimated_duration_ms = 100,
        .is_destructive = false,
        .required_permissions = null,
    };

    var env = tool_types.Envelope{
        .server_id = tool_types.generateUuid(),
        .message_id = tool_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .tool_list_response = .{ .tools = tools } },
    };
    defer env.deinit(allocator);

    const json = try serializeEnvelope(env, allocator);
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.payload == .tool_list_response);
    try std.testing.expectEqual(@as(usize, 1), parsed.payload.tool_list_response.tools.len);
    try std.testing.expectEqualStrings("grep", parsed.payload.tool_list_response.tools[0].name);
}

test "tool envelope negative unknown tool error" {
    const allocator = std.testing.allocator;
    const json =
        "{\"type\":\"tool_error\",\"server_id\":\"00000000-0000-0000-0000-000000000001\",\"message_id\":\"00000000-0000-0000-0000-000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"execution_id\":\"00000000-0000-0000-0000-000000000003\",\"code\":\"tool_not_found\",\"message\":\"unknown tool\"}}";

    var env = try deserializeEnvelope(json, allocator);
    defer env.deinit(allocator);

    try std.testing.expect(env.payload == .tool_error);
    try std.testing.expectEqual(tool_types.ToolErrorCode.tool_not_found, env.payload.tool_error.code);
}

test "tool envelope negative malformed args" {
    const allocator = std.testing.allocator;
    const json =
        "{\"type\":\"tool_execute\",\"server_id\":\"00000000-0000-0000-0000-000000000001\",\"message_id\":\"00000000-0000-0000-0000-000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"execution_id\":\"00000000-0000-0000-0000-000000000003\",\"tool_call_id\":\"call_1\",\"tool_name\":\"grep\",\"args_json\":\"{bad json\"}}";

    try std.testing.expectError(error.InvalidArgumentsJson, deserializeEnvelope(json, allocator));
}

test "tool envelope negative timeout error" {
    const allocator = std.testing.allocator;
    const json =
        "{\"type\":\"tool_error\",\"server_id\":\"00000000-0000-0000-0000-000000000001\",\"message_id\":\"00000000-0000-0000-0000-000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"execution_id\":\"00000000-0000-0000-0000-000000000003\",\"code\":\"tool_timeout\",\"message\":\"timed out\"}}";

    var env = try deserializeEnvelope(json, allocator);
    defer env.deinit(allocator);

    try std.testing.expect(env.payload == .tool_error);
    try std.testing.expectEqual(tool_types.ToolErrorCode.tool_timeout, env.payload.tool_error.code);
}
