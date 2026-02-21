const std = @import("std");
const agent_types = @import("agent_types");
const json_writer = @import("json_writer");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const protocol_types = agent_types;

pub fn serializeEnvelope(env: agent_types.Envelope, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);

    try w.beginObject();
    try w.writeStringField("type", @tagName(env.payload));

    const session_id_str = try agent_types.uuidToString(env.session_id, allocator);
    defer allocator.free(session_id_str);
    try w.writeStringField("session_id", session_id_str);

    const message_id_str = try agent_types.uuidToString(env.message_id, allocator);
    defer allocator.free(message_id_str);
    try w.writeStringField("message_id", message_id_str);

    try w.writeIntField("sequence", env.sequence);
    try w.writeIntField("timestamp", env.timestamp);
    try w.writeIntField("version", env.version);

    if (env.in_reply_to) |reply_to| {
        const reply_str = try agent_types.uuidToString(reply_to, allocator);
        defer allocator.free(reply_str);
        try w.writeStringField("in_reply_to", reply_str);
    }

    try w.writeKey("payload");
    try serializePayload(&w, env.payload, allocator);
    try w.endObject();

    const out = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return out;
}

fn serializePayload(w: *json_writer.JsonWriter, payload: agent_types.Payload, allocator: std.mem.Allocator) !void {
    try w.beginObject();

    switch (payload) {
        .agent_start => |p| {
            try w.writeStringField("config_json", p.config_json);
            if (p.getSystemPrompt()) |prompt| try w.writeStringField("system_prompt", prompt);
            if (p.session_id) |id| {
                const id_str = try agent_types.uuidToString(id, allocator);
                defer allocator.free(id_str);
                try w.writeStringField("resume_session_id", id_str);
            }
        },
        .agent_message => |p| {
            const session_id = try agent_types.uuidToString(p.session_id, allocator);
            defer allocator.free(session_id);
            try w.writeStringField("session_id", session_id);
            try w.writeStringField("message_json", p.message_json);
            if (p.getOptionsJson()) |opts| try w.writeStringField("options_json", opts);
        },
        .agent_stop => |p| {
            const session_id = try agent_types.uuidToString(p.session_id, allocator);
            defer allocator.free(session_id);
            try w.writeStringField("session_id", session_id);
            if (p.getReason()) |reason| try w.writeStringField("reason", reason);
        },
        .agent_status => |p| {
            const session_id = try agent_types.uuidToString(p.session_id, allocator);
            defer allocator.free(session_id);
            try w.writeStringField("session_id", session_id);
        },
        .tool_list => |p| {
            if (p.getPrefix()) |prefix| try w.writeStringField("prefix", prefix);
        },
        .agent_started => |p| {
            const session_id = try agent_types.uuidToString(p.session_id, allocator);
            defer allocator.free(session_id);
            try w.writeStringField("session_id", session_id);
        },
        .agent_event => |p| try w.writeStringField("event_json", p),
        .agent_result => |p| try w.writeStringField("result_json", p),
        .agent_stopped => |p| {
            const session_id = try agent_types.uuidToString(p.session_id, allocator);
            defer allocator.free(session_id);
            try w.writeStringField("session_id", session_id);
            if (p.getReason()) |reason| try w.writeStringField("reason", reason);
        },
        .agent_error => |p| {
            try w.writeStringField("code", @tagName(p.code));
            try w.writeStringField("message", p.message);
        },
        .session_info => |p| {
            const session_id = try agent_types.uuidToString(p.session_id, allocator);
            defer allocator.free(session_id);
            try w.writeStringField("session_id", session_id);
            try w.writeStringField("status", @tagName(p.status));
            try w.writeStringField("model", p.model);
            try w.writeIntField("message_count", p.message_count);
            try w.writeIntField("created_at", p.created_at);
            try w.writeIntField("updated_at", p.updated_at);
        },
        .tool_list_response => |p| {
            try w.writeKey("tools");
            try w.beginArray();
            for (p.tools) |tool| {
                try w.beginObject();
                try w.writeStringField("name", tool.name);
                try w.writeStringField("description", tool.description);
                try w.writeStringField("parameters_schema_json", tool.parameters_schema_json);
                try w.endObject();
            }
            try w.endArray();
        },
        .tool_execute => |p| {
            try w.writeStringField("tool_call_id", p.tool_call_id);
            try w.writeStringField("tool_name", p.tool_name);
            try w.writeStringField("args_json", p.args_json);
            if (p.getCallbackUrl()) |url| try w.writeStringField("callback_url", url);
        },
        .tool_result => |p| {
            try w.writeStringField("tool_call_id", p.tool_call_id);
            try w.writeStringField("result_json", p.result_json);
            try w.writeBoolField("is_error", p.is_error);
            if (p.getDetailsJson()) |details| try w.writeStringField("details_json", details);
        },
        .tool_streaming => |p| {
            try w.writeStringField("tool_call_id", p.tool_call_id);
            try w.writeStringField("partial_json", p.partial_json);
        },
        .ping => {},
        .pong => |p| try w.writeStringField("ping_id", p.ping_id.slice()),
        .goodbye => |p| {
            if (p.getReason()) |reason| try w.writeStringField("reason", reason);
        },
    }

    try w.endObject();
}

pub fn deserializeEnvelope(json: []const u8, allocator: std.mem.Allocator) !agent_types.Envelope {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const type_str = root.get("type").?.string;
    const session_id = parseUuidOrError(root.get("session_id").?.string) orelse return error.InvalidUuid;
    const message_id = parseUuidOrError(root.get("message_id").?.string) orelse return error.InvalidUuid;
    const sequence = @as(u64, @intCast(root.get("sequence").?.integer));
    const timestamp = root.get("timestamp").?.integer;
    const version = @as(u8, @intCast(root.get("version").?.integer));

    var in_reply_to: ?agent_types.Uuid = null;
    if (root.get("in_reply_to")) |v| in_reply_to = try parseUuidRequired(v.string);

    const payload_obj = root.get("payload").?.object;
    const payload = try deserializePayload(type_str, payload_obj, allocator);

    return .{
        .version = version,
        .session_id = session_id,
        .message_id = message_id,
        .sequence = sequence,
        .in_reply_to = in_reply_to,
        .timestamp = timestamp,
        .payload = payload,
    };
}

fn parseUuidRequired(str: []const u8) !agent_types.Uuid {
    return agent_types.parseUuid(str) orelse error.InvalidUuid;
}

fn parseUuidOrError(str: []const u8) ?agent_types.Uuid {
    return agent_types.parseUuid(str);
}

fn deserializePayload(type_str: []const u8, payload: std.json.ObjectMap, allocator: std.mem.Allocator) !agent_types.Payload {
    if (std.mem.eql(u8, type_str, "agent_start")) {
        const config = try allocator.dupe(u8, payload.get("config_json").?.string);
        var result = agent_types.AgentStartRequest{ .config_json = config };
        if (payload.get("system_prompt")) |v| result.system_prompt = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        if (payload.get("resume_session_id")) |v| result.session_id = try parseUuidRequired(v.string);
        return .{ .agent_start = result };
    }
    if (std.mem.eql(u8, type_str, "agent_message")) {
        const msg = try allocator.dupe(u8, payload.get("message_json").?.string);
        var req = agent_types.AgentMessageRequest{
            .session_id = try parseUuidRequired(payload.get("session_id").?.string),
            .message_json = msg,
        };
        if (payload.get("options_json")) |v| req.options_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .agent_message = req };
    }
    if (std.mem.eql(u8, type_str, "agent_stop")) {
        var req = agent_types.AgentStopRequest{ .session_id = try parseUuidRequired(payload.get("session_id").?.string) };
        if (payload.get("reason")) |v| req.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .agent_stop = req };
    }
    if (std.mem.eql(u8, type_str, "agent_status")) {
        return .{ .agent_status = .{ .session_id = try parseUuidRequired(payload.get("session_id").?.string) } };
    }
    if (std.mem.eql(u8, type_str, "tool_list")) {
        var req = agent_types.ToolListRequest{};
        if (payload.get("prefix")) |v| req.prefix = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .tool_list = req };
    }
    if (std.mem.eql(u8, type_str, "agent_started")) {
        return .{ .agent_started = .{ .session_id = try parseUuidRequired(payload.get("session_id").?.string) } };
    }
    if (std.mem.eql(u8, type_str, "agent_event")) return .{ .agent_event = try allocator.dupe(u8, payload.get("event_json").?.string) };
    if (std.mem.eql(u8, type_str, "agent_result")) return .{ .agent_result = try allocator.dupe(u8, payload.get("result_json").?.string) };
    if (std.mem.eql(u8, type_str, "agent_stopped")) {
        var stopped = agent_types.AgentStopped{ .session_id = try parseUuidRequired(payload.get("session_id").?.string) };
        if (payload.get("reason")) |v| stopped.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .agent_stopped = stopped };
    }
    if (std.mem.eql(u8, type_str, "agent_error")) {
        return .{ .agent_error = .{
            .code = std.meta.stringToEnum(agent_types.AgentErrorCode, payload.get("code").?.string) orelse .internal_error,
            .message = try allocator.dupe(u8, payload.get("message").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "session_info")) {
        return .{ .session_info = .{
            .session_id = try parseUuidRequired(payload.get("session_id").?.string),
            .status = std.meta.stringToEnum(agent_types.AgentStatus, payload.get("status").?.string) orelse .@"error",
            .model = try allocator.dupe(u8, payload.get("model").?.string),
            .message_count = @as(u32, @intCast(payload.get("message_count").?.integer)),
            .created_at = payload.get("created_at").?.integer,
            .updated_at = payload.get("updated_at").?.integer,
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_list_response")) {
        const tools_arr = payload.get("tools").?.array;
        const tools = try allocator.alloc(agent_types.ToolDefinition, tools_arr.items.len);
        for (tools_arr.items, 0..) |t, i| {
            tools[i] = .{
                .name = try allocator.dupe(u8, t.object.get("name").?.string),
                .description = try allocator.dupe(u8, t.object.get("description").?.string),
                .parameters_schema_json = try allocator.dupe(u8, t.object.get("parameters_schema_json").?.string),
            };
        }
        return .{ .tool_list_response = .{ .tools = tools } };
    }
    if (std.mem.eql(u8, type_str, "tool_execute")) {
        var req = agent_types.ToolExecuteRequest{
            .tool_call_id = try allocator.dupe(u8, payload.get("tool_call_id").?.string),
            .tool_name = try allocator.dupe(u8, payload.get("tool_name").?.string),
            .args_json = try allocator.dupe(u8, payload.get("args_json").?.string),
        };
        if (payload.get("callback_url")) |v| req.callback_url = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .tool_execute = req };
    }
    if (std.mem.eql(u8, type_str, "tool_result")) {
        var res = agent_types.ToolExecuteResponse{
            .tool_call_id = try allocator.dupe(u8, payload.get("tool_call_id").?.string),
            .result_json = try allocator.dupe(u8, payload.get("result_json").?.string),
            .is_error = if (payload.get("is_error")) |v| v.bool else false,
        };
        if (payload.get("details_json")) |v| res.details_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .tool_result = res };
    }
    if (std.mem.eql(u8, type_str, "tool_streaming")) {
        return .{ .tool_streaming = .{
            .tool_call_id = try allocator.dupe(u8, payload.get("tool_call_id").?.string),
            .partial_json = try allocator.dupe(u8, payload.get("partial_json").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "ping")) return .ping;
    if (std.mem.eql(u8, type_str, "pong")) return .{ .pong = .{ .ping_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, payload.get("ping_id").?.string)) } };
    if (std.mem.eql(u8, type_str, "goodbye")) {
        var g = agent_types.Goodbye{};
        if (payload.get("reason")) |v| g.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .goodbye = g };
    }

    return error.InvalidPayloadType;
}

test "agent envelope roundtrip" {
    const allocator = std.testing.allocator;

    var env = agent_types.Envelope{
        .session_id = agent_types.generateUuid(),
        .message_id = agent_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .agent_message = .{
            .session_id = agent_types.generateUuid(),
            .message_json = try allocator.dupe(u8, "{\"role\":\"user\"}"),
            .options_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "{\"temperature\":0.5}")),
        } },
    };
    defer env.deinit(allocator);

    const json = try serializeEnvelope(env, allocator);
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.payload == .agent_message);
    try std.testing.expectEqualStrings("{\"role\":\"user\"}", parsed.payload.agent_message.message_json);
}
