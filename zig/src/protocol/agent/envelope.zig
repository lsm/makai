const std = @import("std");
const compat = @import("compat");
const agent_types = @import("agent_types");
const json_writer = @import("json_writer");
const model_catalog_types = @import("model_catalog_types");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const protocol_types = agent_types;

pub fn serializeEnvelope(env: agent_types.Envelope, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);

    try w.beginObject();
    try w.writeStringField("type", @tagName(env.payload));

    const session_id_str = try agent_types.sessionIdToString(env.session_id, allocator);
    defer allocator.free(session_id_str);
    try w.writeStringField("session_id", session_id_str);

    const message_id_str = try agent_types.ulidToString(env.message_id, allocator);
    defer allocator.free(message_id_str);
    try w.writeStringField("message_id", message_id_str);

    try w.writeIntField("sequence", env.sequence);
    try w.writeIntField("timestamp", env.timestamp);
    try w.writeIntField("version", env.version);

    if (env.in_reply_to) |reply_to| {
        const reply_str = try agent_types.ulidToString(reply_to, allocator);
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
                const id_str = try agent_types.sessionIdToString(id, allocator);
                defer allocator.free(id_str);
                try w.writeStringField("session_id", id_str);
                try w.writeStringField("resume_session_id", id_str);
            }
        },
        .agent_message => |p| {
            const session_id = try agent_types.sessionIdToString(p.session_id, allocator);
            defer allocator.free(session_id);
            try w.writeStringField("session_id", session_id);
            try w.writeStringField("message_json", p.message_json);
            if (p.getOptionsJson()) |opts| try w.writeStringField("options_json", opts);
        },
        .agent_stop => |p| {
            const session_id = try agent_types.sessionIdToString(p.session_id, allocator);
            defer allocator.free(session_id);
            try w.writeStringField("session_id", session_id);
            if (p.getReason()) |reason| try w.writeStringField("reason", reason);
        },
        .agent_status => |p| {
            const session_id = try agent_types.sessionIdToString(p.session_id, allocator);
            defer allocator.free(session_id);
            try w.writeStringField("session_id", session_id);
        },
        .tool_list => |p| {
            if (p.getPrefix()) |prefix| try w.writeStringField("prefix", prefix);
        },
        .agent_started => |p| {
            const session_id = try agent_types.sessionIdToString(p.session_id, allocator);
            defer allocator.free(session_id);
            try w.writeStringField("session_id", session_id);
        },
        .agent_event => |p| try w.writeStringField("event_json", p),
        .agent_result => |p| try w.writeStringField("result_json", p),
        .agent_stopped => |p| {
            const session_id = try agent_types.sessionIdToString(p.session_id, allocator);
            defer allocator.free(session_id);
            try w.writeStringField("session_id", session_id);
            if (p.getReason()) |reason| try w.writeStringField("reason", reason);
        },
        .agent_error => |p| {
            try w.writeStringField("code", @tagName(p.code));
            try w.writeStringField("message", p.message);
        },
        .session_info => |p| {
            const session_id = try agent_types.sessionIdToString(p.session_id, allocator);
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
        .ack => |p| {
            const ack_id = try agent_types.ulidToString(p.acknowledged_id, allocator);
            defer allocator.free(ack_id);
            try w.writeStringField("acknowledged_id", ack_id);
        },
        .nack => |p| {
            const rejected_id = try agent_types.ulidToString(p.rejected_id, allocator);
            defer allocator.free(rejected_id);
            try w.writeStringField("rejected_id", rejected_id);
            try w.writeStringField("reason", p.reason.slice());
            if (p.error_code) |code| {
                try w.writeStringField("error_code", @tagName(code));
            }
        },
        .models_request => |p| {
            if (p.getProviderId()) |provider_id| try w.writeStringField("provider_id", provider_id);
            if (p.getApi()) |api| try w.writeStringField("api", api);
            if (p.getModelId()) |model_id| try w.writeStringField("model_id", model_id);
            try w.writeBoolField("include_deprecated", p.include_deprecated);
            try w.writeBoolField("include_login_required", p.include_login_required);
        },
        .models_response => |p| {
            try w.writeIntField("fetched_at_ms", p.fetched_at_ms);
            try w.writeIntField("cache_max_age_ms", p.cache_max_age_ms);
            try w.writeKey("models");
            try w.beginArray();
            for (p.models.slice()) |descriptor| {
                try serializeModelDescriptor(w, descriptor);
            }
            try w.endArray();
        },
    }

    try w.endObject();
}

fn serializeModelDescriptor(
    w: *json_writer.JsonWriter,
    model: model_catalog_types.ModelDescriptor,
) !void {
    try w.beginObject();

    try w.writeStringField("model_ref", model.model_ref.slice());
    try w.writeStringField("model_id", model.model_id.slice());
    try w.writeStringField("display_name", model.display_name.slice());
    try w.writeStringField("provider_id", model.provider_id.slice());
    try w.writeStringField("api", model.api.slice());
    if (model.base_url.slice().len > 0) {
        try w.writeStringField("base_url", model.base_url.slice());
    }
    try w.writeStringField("auth_status", @tagName(model.auth_status));
    try w.writeStringField("lifecycle", @tagName(model.lifecycle));
    try w.writeStringField("source", @tagName(model.source));

    try w.writeKey("capabilities");
    try w.beginArray();
    for (model.capabilities.slice()) |capability| {
        try w.writeString(@tagName(capability));
    }
    try w.endArray();

    if (model.context_window) |value| {
        try w.writeIntField("context_window", value);
    }
    if (model.max_output_tokens) |value| {
        try w.writeIntField("max_output_tokens", value);
    }
    if (model.reasoning_default) |value| {
        try w.writeStringField("reasoning_default", @tagName(value));
    }
    if (model.metadata) |entries| {
        try w.writeKey("metadata");
        try w.beginObject();
        for (entries.slice()) |entry| {
            try w.writeStringField(entry.key.slice(), entry.value.slice());
        }
        try w.endObject();
    }

    try w.endObject();
}

pub fn deserializeEnvelope(json: []const u8, allocator: std.mem.Allocator) !agent_types.Envelope {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = try asObject(parsed.value);
    const type_str = try requiredString(root, "type");
    const session_id = try parseSessionIdRequired(try requiredString(root, "session_id"));
    const message_id = try parseUlidRequired(try requiredString(root, "message_id"));
    const sequence = try requiredBoundedInteger(u64, root, "sequence");
    const timestamp = try requiredInteger(root, "timestamp");
    const version: u8 = if (root.get("version")) |v| try asBoundedInteger(u8, v) else 1;

    var in_reply_to: ?agent_types.Ulid = null;
    if (root.get("in_reply_to")) |v| in_reply_to = try parseUlidRequired(try asString(v));

    const payload_obj = try requiredObject(root, "payload");
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

const FieldError = error{ MissingField, InvalidField };

fn asString(value: std.json.Value) FieldError![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.InvalidField,
    };
}

fn asBool(value: std.json.Value) FieldError!bool {
    return switch (value) {
        .bool => |b| b,
        else => error.InvalidField,
    };
}

fn asInteger(value: std.json.Value) FieldError!i64 {
    return switch (value) {
        .integer => |n| n,
        else => error.InvalidField,
    };
}

fn asBoundedInteger(comptime T: type, value: std.json.Value) FieldError!T {
    return std.math.cast(T, try asInteger(value)) orelse error.InvalidField;
}

fn asArray(value: std.json.Value) FieldError!std.json.Array {
    return switch (value) {
        .array => |a| a,
        else => error.InvalidField,
    };
}

fn asObject(value: std.json.Value) FieldError!std.json.ObjectMap {
    return switch (value) {
        .object => |o| o,
        else => error.InvalidField,
    };
}

fn requiredField(obj: std.json.ObjectMap, key: []const u8) FieldError!std.json.Value {
    return obj.get(key) orelse error.MissingField;
}

fn requiredString(obj: std.json.ObjectMap, key: []const u8) FieldError![]const u8 {
    return asString(try requiredField(obj, key));
}

fn requiredInteger(obj: std.json.ObjectMap, key: []const u8) FieldError!i64 {
    return asInteger(try requiredField(obj, key));
}

fn requiredBoundedInteger(comptime T: type, obj: std.json.ObjectMap, key: []const u8) FieldError!T {
    return asBoundedInteger(T, try requiredField(obj, key));
}

fn requiredArray(obj: std.json.ObjectMap, key: []const u8) FieldError!std.json.Array {
    return asArray(try requiredField(obj, key));
}

fn requiredObject(obj: std.json.ObjectMap, key: []const u8) FieldError!std.json.ObjectMap {
    return asObject(try requiredField(obj, key));
}

fn optionalString(obj: std.json.ObjectMap, key: []const u8) FieldError!?[]const u8 {
    return if (obj.get(key)) |v| try asString(v) else null;
}

fn optionalBool(obj: std.json.ObjectMap, key: []const u8, fallback: bool) FieldError!bool {
    return if (obj.get(key)) |v| try asBool(v) else fallback;
}

fn optionalBoundedInteger(comptime T: type, obj: std.json.ObjectMap, key: []const u8) FieldError!?T {
    return if (obj.get(key)) |v| try asBoundedInteger(T, v) else null;
}

fn parseUlidRequired(str: []const u8) !agent_types.Ulid {
    return agent_types.parseUlid(str) orelse error.InvalidUlid;
}

fn parseSessionIdRequired(str: []const u8) !agent_types.SessionId {
    return agent_types.parseSessionId(str) orelse error.InvalidSessionId;
}

fn deserializePayload(type_str: []const u8, payload: std.json.ObjectMap, allocator: std.mem.Allocator) !agent_types.Payload {
    if (std.mem.eql(u8, type_str, "agent_start")) {
        const config_json = try requiredString(payload, "config_json");
        const system_prompt = try optionalString(payload, "system_prompt");
        const session_id: ?agent_types.SessionId = if (payload.get("session_id")) |v|
            try parseSessionIdRequired(try asString(v))
        else if (payload.get("resume_session_id")) |v|
            try parseSessionIdRequired(try asString(v))
        else
            null;

        const config = try allocator.dupe(u8, config_json);
        errdefer allocator.free(config);

        var result = agent_types.AgentStartRequest{ .config_json = config, .session_id = session_id };
        if (system_prompt) |value| result.system_prompt = OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
        return .{ .agent_start = result };
    }
    if (std.mem.eql(u8, type_str, "agent_message")) {
        const session_id = try parseSessionIdRequired(try requiredString(payload, "session_id"));
        const message_json = try requiredString(payload, "message_json");
        const options_json = try optionalString(payload, "options_json");

        const msg = try allocator.dupe(u8, message_json);
        errdefer allocator.free(msg);

        var req = agent_types.AgentMessageRequest{
            .session_id = session_id,
            .message_json = msg,
        };
        if (options_json) |value| req.options_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
        return .{ .agent_message = req };
    }
    if (std.mem.eql(u8, type_str, "agent_stop")) {
        const session_id = try parseSessionIdRequired(try requiredString(payload, "session_id"));
        const reason = try optionalString(payload, "reason");

        var req = agent_types.AgentStopRequest{ .session_id = session_id };
        if (reason) |value| req.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
        return .{ .agent_stop = req };
    }
    if (std.mem.eql(u8, type_str, "agent_status")) {
        return .{ .agent_status = .{ .session_id = try parseSessionIdRequired(try requiredString(payload, "session_id")) } };
    }
    if (std.mem.eql(u8, type_str, "tool_list")) {
        const prefix = try optionalString(payload, "prefix");
        var req = agent_types.ToolListRequest{};
        if (prefix) |value| req.prefix = OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
        return .{ .tool_list = req };
    }
    if (std.mem.eql(u8, type_str, "agent_started")) {
        return .{ .agent_started = .{ .session_id = try parseSessionIdRequired(try requiredString(payload, "session_id")) } };
    }
    if (std.mem.eql(u8, type_str, "agent_event")) return .{ .agent_event = try allocator.dupe(u8, try requiredString(payload, "event_json")) };
    if (std.mem.eql(u8, type_str, "agent_result")) return .{ .agent_result = try allocator.dupe(u8, try requiredString(payload, "result_json")) };
    if (std.mem.eql(u8, type_str, "agent_stopped")) {
        const session_id = try parseSessionIdRequired(try requiredString(payload, "session_id"));
        const reason = try optionalString(payload, "reason");

        var stopped = agent_types.AgentStopped{ .session_id = session_id };
        if (reason) |value| stopped.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
        return .{ .agent_stopped = stopped };
    }
    if (std.mem.eql(u8, type_str, "agent_error")) {
        const code = try requiredString(payload, "code");
        const message = try requiredString(payload, "message");
        return .{ .agent_error = .{
            .code = std.meta.stringToEnum(agent_types.AgentErrorCode, code) orelse .internal_error,
            .message = try allocator.dupe(u8, message),
        } };
    }
    if (std.mem.eql(u8, type_str, "session_info")) {
        const session_id = try parseSessionIdRequired(try requiredString(payload, "session_id"));
        const status = try requiredString(payload, "status");
        const model = try requiredString(payload, "model");
        const message_count = try requiredBoundedInteger(u32, payload, "message_count");
        const created_at = try requiredInteger(payload, "created_at");
        const updated_at = try requiredInteger(payload, "updated_at");

        return .{ .session_info = .{
            .session_id = session_id,
            .status = std.meta.stringToEnum(agent_types.AgentStatus, status) orelse .@"error",
            .model = try allocator.dupe(u8, model),
            .message_count = message_count,
            .created_at = created_at,
            .updated_at = updated_at,
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_list_response")) {
        const tools_arr = try requiredArray(payload, "tools");
        const tools = try allocator.alloc(agent_types.ToolDefinition, tools_arr.items.len);
        var initialized: usize = 0;
        errdefer {
            for (tools[0..initialized]) |tool| {
                allocator.free(tool.name);
                allocator.free(tool.description);
                allocator.free(tool.parameters_schema_json);
            }
            allocator.free(tools);
        }

        for (tools_arr.items, 0..) |t, i| {
            const tool_obj = try asObject(t);
            const name = try requiredString(tool_obj, "name");
            const description = try requiredString(tool_obj, "description");
            const parameters_schema_json = try requiredString(tool_obj, "parameters_schema_json");

            const name_copy = try allocator.dupe(u8, name);
            errdefer allocator.free(name_copy);
            const description_copy = try allocator.dupe(u8, description);
            errdefer allocator.free(description_copy);

            tools[i] = .{
                .name = name_copy,
                .description = description_copy,
                .parameters_schema_json = try allocator.dupe(u8, parameters_schema_json),
            };
            initialized += 1;
        }
        return .{ .tool_list_response = .{ .tools = tools } };
    }
    if (std.mem.eql(u8, type_str, "tool_execute")) {
        const tool_call_id = try requiredString(payload, "tool_call_id");
        const tool_name = try requiredString(payload, "tool_name");
        const args_json = try requiredString(payload, "args_json");
        const callback_url = try optionalString(payload, "callback_url");

        const tool_call_id_copy = try allocator.dupe(u8, tool_call_id);
        errdefer allocator.free(tool_call_id_copy);
        const tool_name_copy = try allocator.dupe(u8, tool_name);
        errdefer allocator.free(tool_name_copy);
        const args_json_copy = try allocator.dupe(u8, args_json);
        errdefer allocator.free(args_json_copy);

        var req = agent_types.ToolExecuteRequest{
            .tool_call_id = tool_call_id_copy,
            .tool_name = tool_name_copy,
            .args_json = args_json_copy,
        };
        if (callback_url) |value| req.callback_url = OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
        return .{ .tool_execute = req };
    }
    if (std.mem.eql(u8, type_str, "tool_result")) {
        const tool_call_id = try requiredString(payload, "tool_call_id");
        const result_json = try requiredString(payload, "result_json");
        const is_error = try optionalBool(payload, "is_error", false);
        const details_json = try optionalString(payload, "details_json");

        const tool_call_id_copy = try allocator.dupe(u8, tool_call_id);
        errdefer allocator.free(tool_call_id_copy);
        const result_json_copy = try allocator.dupe(u8, result_json);
        errdefer allocator.free(result_json_copy);

        var res = agent_types.ToolExecuteResponse{
            .tool_call_id = tool_call_id_copy,
            .result_json = result_json_copy,
            .is_error = is_error,
        };
        if (details_json) |value| res.details_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
        return .{ .tool_result = res };
    }
    if (std.mem.eql(u8, type_str, "tool_streaming")) {
        const tool_call_id = try requiredString(payload, "tool_call_id");
        const partial_json = try requiredString(payload, "partial_json");

        const tool_call_id_copy = try allocator.dupe(u8, tool_call_id);
        errdefer allocator.free(tool_call_id_copy);

        return .{ .tool_streaming = .{
            .tool_call_id = tool_call_id_copy,
            .partial_json = try allocator.dupe(u8, partial_json),
        } };
    }
    if (std.mem.eql(u8, type_str, "ping")) return .ping;
    if (std.mem.eql(u8, type_str, "pong")) {
        const ping_id = try requiredString(payload, "ping_id");
        return .{ .pong = .{ .ping_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, ping_id)) } };
    }
    if (std.mem.eql(u8, type_str, "goodbye")) {
        const reason = try optionalString(payload, "reason");
        var g = agent_types.Goodbye{};
        if (reason) |value| g.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
        return .{ .goodbye = g };
    }
    if (std.mem.eql(u8, type_str, "ack")) {
        return .{ .ack = .{ .acknowledged_id = try parseUlidRequired(try requiredString(payload, "acknowledged_id")) } };
    }
    if (std.mem.eql(u8, type_str, "nack")) {
        const rejected_id = try parseUlidRequired(try requiredString(payload, "rejected_id"));
        const reason_str = try requiredString(payload, "reason");
        const error_code: ?agent_types.ErrorCode = if (payload.get("error_code")) |v|
            std.meta.stringToEnum(agent_types.ErrorCode, try asString(v))
        else
            null;
        return .{ .nack = .{
            .rejected_id = rejected_id,
            .reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, reason_str)),
            .error_code = error_code,
        } };
    }
    if (std.mem.eql(u8, type_str, "models_request")) {
        return .{ .models_request = try deserializeModelsRequest(payload, allocator) };
    }
    if (std.mem.eql(u8, type_str, "models_response")) {
        return .{ .models_response = try deserializeModelsResponse(payload, allocator) };
    }

    return error.InvalidPayloadType;
}

fn deserializeModelsRequest(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !agent_types.ModelsRequest {
    const provider_id_str = try optionalString(obj, "provider_id");
    const api_str = try optionalString(obj, "api");
    const model_id_str = try optionalString(obj, "model_id");
    const include_deprecated = try optionalBool(obj, "include_deprecated", false);
    const include_login_required = try optionalBool(obj, "include_login_required", true);

    const provider_id = if (provider_id_str) |value|
        OwnedSlice(u8).initOwned(try allocator.dupe(u8, value))
    else
        OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = provider_id;
        mutable.deinit(allocator);
    }

    const api = if (api_str) |value|
        OwnedSlice(u8).initOwned(try allocator.dupe(u8, value))
    else
        OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = api;
        mutable.deinit(allocator);
    }

    const model_id = if (model_id_str) |value|
        OwnedSlice(u8).initOwned(try allocator.dupe(u8, value))
    else
        OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = model_id;
        mutable.deinit(allocator);
    }

    return .{
        .provider_id = provider_id,
        .api = api,
        .model_id = model_id,
        .include_deprecated = include_deprecated,
        .include_login_required = include_login_required,
    };
}

fn deserializeModelsResponse(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !agent_types.ModelsResponse {
    const fetched_at_ms = try requiredInteger(obj, "fetched_at_ms");
    const cache_max_age_ms = try requiredBoundedInteger(u64, obj, "cache_max_age_ms");
    const models_array = try requiredArray(obj, "models");

    const descriptors = try allocator.alloc(model_catalog_types.ModelDescriptor, models_array.items.len);
    var allocated_count: usize = 0;
    errdefer {
        for (descriptors[0..allocated_count]) |*descriptor| descriptor.deinit(allocator);
        allocator.free(descriptors);
    }

    for (models_array.items, 0..) |item, idx| {
        descriptors[idx] = try deserializeModelDescriptor(try asObject(item), allocator);
        allocated_count += 1;
    }

    return .{
        .models = OwnedSlice(model_catalog_types.ModelDescriptor).initOwned(descriptors),
        .fetched_at_ms = fetched_at_ms,
        .cache_max_age_ms = cache_max_age_ms,
    };
}

fn deserializeModelDescriptor(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !model_catalog_types.ModelDescriptor {
    const model_ref_str = try requiredString(obj, "model_ref");
    const model_id_str = try requiredString(obj, "model_id");
    const display_name_str = try requiredString(obj, "display_name");
    const provider_id_str = try requiredString(obj, "provider_id");
    const api_str = try requiredString(obj, "api");
    const base_url_str = try optionalString(obj, "base_url");
    const auth_status = parseAuthStatus(try requiredString(obj, "auth_status"));
    const lifecycle = try parseModelLifecycle(try requiredString(obj, "lifecycle"));
    const source = try parseModelSource(try requiredString(obj, "source"));
    const context_window = try optionalBoundedInteger(u32, obj, "context_window");
    const max_output_tokens = try optionalBoundedInteger(u32, obj, "max_output_tokens");
    const reasoning_default: ?model_catalog_types.ReasoningLevel = if (obj.get("reasoning_default")) |value|
        try parseReasoningLevel(try asString(value))
    else
        null;
    const capabilities_array = try requiredArray(obj, "capabilities");

    const model_ref = OwnedSlice(u8).initOwned(try allocator.dupe(u8, model_ref_str));
    errdefer {
        var mutable = model_ref;
        mutable.deinit(allocator);
    }

    const model_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, model_id_str));
    errdefer {
        var mutable = model_id;
        mutable.deinit(allocator);
    }

    const display_name = OwnedSlice(u8).initOwned(try allocator.dupe(u8, display_name_str));
    errdefer {
        var mutable = display_name;
        mutable.deinit(allocator);
    }

    const provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, provider_id_str));
    errdefer {
        var mutable = provider_id;
        mutable.deinit(allocator);
    }

    const api = OwnedSlice(u8).initOwned(try allocator.dupe(u8, api_str));
    errdefer {
        var mutable = api;
        mutable.deinit(allocator);
    }

    const base_url = if (base_url_str) |value|
        OwnedSlice(u8).initOwned(try allocator.dupe(u8, value))
    else
        OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = base_url;
        mutable.deinit(allocator);
    }

    const capabilities = try allocator.alloc(model_catalog_types.ModelCapability, capabilities_array.items.len);
    errdefer allocator.free(capabilities);
    for (capabilities_array.items, 0..) |item, idx| {
        capabilities[idx] = try parseModelCapability(try asString(item));
    }

    var metadata: ?OwnedSlice(model_catalog_types.MetadataEntry) = null;
    if (obj.get("metadata")) |metadata_value| {
        const metadata_obj = try asObject(metadata_value);
        const metadata_items = try allocator.alloc(model_catalog_types.MetadataEntry, metadata_obj.count());
        var metadata_count: usize = 0;
        errdefer {
            for (metadata_items[0..metadata_count]) |*entry| entry.deinit(allocator);
            allocator.free(metadata_items);
        }

        var iter = metadata_obj.iterator();
        while (iter.next()) |entry| {
            const entry_value = try asString(entry.value_ptr.*);
            const key = OwnedSlice(u8).initOwned(try allocator.dupe(u8, entry.key_ptr.*));
            errdefer {
                var mutable = key;
                mutable.deinit(allocator);
            }
            metadata_items[metadata_count] = .{
                .key = key,
                .value = OwnedSlice(u8).initOwned(try allocator.dupe(u8, entry_value)),
            };
            metadata_count += 1;
        }

        metadata = OwnedSlice(model_catalog_types.MetadataEntry).initOwned(metadata_items);
    }

    return .{
        .model_ref = model_ref,
        .model_id = model_id,
        .display_name = display_name,
        .provider_id = provider_id,
        .api = api,
        .base_url = base_url,
        .auth_status = auth_status,
        .lifecycle = lifecycle,
        .capabilities = OwnedSlice(model_catalog_types.ModelCapability).initOwned(capabilities),
        .source = source,
        .context_window = context_window,
        .max_output_tokens = max_output_tokens,
        .reasoning_default = reasoning_default,
        .metadata = metadata,
    };
}

fn parseAuthStatus(str: []const u8) model_catalog_types.AuthStatus {
    if (std.mem.eql(u8, str, "authenticated")) return .authenticated;
    if (std.mem.eql(u8, str, "login_required")) return .login_required;
    if (std.mem.eql(u8, str, "expired")) return .expired;
    if (std.mem.eql(u8, str, "refreshing")) return .refreshing;
    if (std.mem.eql(u8, str, "login_in_progress")) return .login_in_progress;
    if (std.mem.eql(u8, str, "failed")) return .failed;
    return .unknown;
}

fn parseModelLifecycle(str: []const u8) error{InvalidEnumValue}!model_catalog_types.ModelLifecycle {
    if (std.mem.eql(u8, str, "stable")) return .stable;
    if (std.mem.eql(u8, str, "preview")) return .preview;
    if (std.mem.eql(u8, str, "deprecated")) return .deprecated;
    return error.InvalidEnumValue;
}

fn parseModelCapability(str: []const u8) error{InvalidEnumValue}!model_catalog_types.ModelCapability {
    if (std.mem.eql(u8, str, "chat")) return .chat;
    if (std.mem.eql(u8, str, "streaming")) return .streaming;
    if (std.mem.eql(u8, str, "tools")) return .tools;
    if (std.mem.eql(u8, str, "vision")) return .vision;
    if (std.mem.eql(u8, str, "reasoning")) return .reasoning;
    if (std.mem.eql(u8, str, "prompt_cache")) return .prompt_cache;
    if (std.mem.eql(u8, str, "audio_input")) return .audio_input;
    if (std.mem.eql(u8, str, "audio_output")) return .audio_output;
    return error.InvalidEnumValue;
}

fn parseModelSource(str: []const u8) error{InvalidEnumValue}!model_catalog_types.ModelSource {
    if (std.mem.eql(u8, str, "dynamic")) return .dynamic;
    if (std.mem.eql(u8, str, "static_fallback")) return .static_fallback;
    return error.InvalidEnumValue;
}

fn parseReasoningLevel(str: []const u8) error{InvalidEnumValue}!model_catalog_types.ReasoningLevel {
    if (std.mem.eql(u8, str, "off")) return .off;
    if (std.mem.eql(u8, str, "minimal")) return .minimal;
    if (std.mem.eql(u8, str, "low")) return .low;
    if (std.mem.eql(u8, str, "medium")) return .medium;
    if (std.mem.eql(u8, str, "high")) return .high;
    if (std.mem.eql(u8, str, "xhigh")) return .xhigh;
    return error.InvalidEnumValue;
}

test "deserializeEnvelope rejects invalid ulid" {
    const allocator = std.testing.allocator;
    const sid = "000000000000000000000";
    const bad = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"session_id\":\"{s}\",\"message_id\":\"not-a-ulid\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{sid},
    );
    defer allocator.free(bad);
    try std.testing.expectError(error.InvalidUlid, deserializeEnvelope(bad, allocator));
}

test "deserializeEnvelope rejects unknown payload type" {
    const allocator = std.testing.allocator;
    const sid = "000000000000000000000";
    const mid = "00000000000000000000000002";
    const bad = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"not_real\",\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{ sid, mid },
    );
    defer allocator.free(bad);
    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(bad, allocator));
}

test "agent envelope roundtrip" {
    const allocator = std.testing.allocator;

    var env = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_message = .{
            .session_id = agent_types.generateSessionId(),
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

test "agent_start payload serializes the id under session_id plus the legacy alias (#198)" {
    const allocator = std.testing.allocator;

    const sid = agent_types.generateSessionId();
    var env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .agent_start = .{
            .session_id = sid,
            .config_json = try allocator.dupe(u8, "{}"),
        } },
    };
    defer env.deinit(allocator);

    const json = try serializeEnvelope(env, allocator);
    defer allocator.free(json);

    var parsed_json = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed_json.deinit();
    const payload = parsed_json.value.object.get("payload").?.object;
    try std.testing.expectEqualStrings(&sid, payload.get("session_id").?.string);
    try std.testing.expectEqualStrings(&sid, payload.get("resume_session_id").?.string);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(sid, parsed.payload.agent_start.session_id.?);
}

test "agent_start deserialization accepts the legacy resume_session_id alias (#198)" {
    const allocator = std.testing.allocator;
    const sid = "aaaaaaaaaaaaaaaaaaaaa";
    const mid = "00000000000000000000000002";
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"agent_start\",\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{\"config_json\":\"{{}}\",\"resume_session_id\":\"{s}\"}}}}",
        .{ sid, mid, sid },
    );
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.payload == .agent_start);
    try std.testing.expectEqualStrings(sid, &parsed.payload.agent_start.session_id.?);
}

test "agent_start deserialization prefers session_id when both payload keys appear (#198)" {
    const allocator = std.testing.allocator;
    const canonical = "aaaaaaaaaaaaaaaaaaaaa";
    const legacy = "bbbbbbbbbbbbbbbbbbbbb";
    const mid = "00000000000000000000000002";
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"agent_start\",\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{\"config_json\":\"{{}}\",\"session_id\":\"{s}\",\"resume_session_id\":\"{s}\"}}}}",
        .{ canonical, mid, canonical, legacy },
    );
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.payload == .agent_start);
    try std.testing.expectEqualStrings(canonical, &parsed.payload.agent_start.session_id.?);
}

test "agent envelope roundtrip for models_request" {
    const allocator = std.testing.allocator;

    var env = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_request = .{
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic")),
            .api = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic-messages")),
            .model_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "claude-sonnet-4-5")),
            .include_deprecated = false,
            .include_login_required = true,
        } },
    };
    defer env.deinit(allocator);

    const json = try serializeEnvelope(env, allocator);
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.payload == .models_request);
    try std.testing.expectEqualStrings("anthropic", parsed.payload.models_request.getProviderId().?);
    try std.testing.expectEqualStrings("anthropic-messages", parsed.payload.models_request.getApi().?);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", parsed.payload.models_request.getModelId().?);
    try std.testing.expect(!parsed.payload.models_request.include_deprecated);
    try std.testing.expect(parsed.payload.models_request.include_login_required);
}

test "agent envelope roundtrip for models_response preserves shape" {
    const allocator = std.testing.allocator;

    const capabilities = try allocator.alloc(agent_types.ModelCapability, 3);
    capabilities[0] = .chat;
    capabilities[1] = .streaming;
    capabilities[2] = .reasoning;

    const metadata = try allocator.alloc(agent_types.MetadataEntry, 1);
    metadata[0] = .{
        .key = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "tier")),
        .value = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "standard")),
    };

    const descriptors = try allocator.alloc(agent_types.ModelDescriptor, 1);
    descriptors[0] = .{
        .model_ref = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic/anthropic-messages@claude-sonnet-4-5")),
        .model_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "claude-sonnet-4-5")),
        .display_name = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "Claude Sonnet 4.5")),
        .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic")),
        .api = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic-messages")),
        .base_url = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "https://api.anthropic.com")),
        .auth_status = .authenticated,
        .lifecycle = .stable,
        .capabilities = OwnedSlice(agent_types.ModelCapability).initOwned(capabilities),
        .source = .dynamic,
        .context_window = 200_000,
        .max_output_tokens = 8_192,
        .reasoning_default = .medium,
        .metadata = OwnedSlice(agent_types.MetadataEntry).initOwned(metadata),
    };

    var env = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_response = .{
            .models = OwnedSlice(agent_types.ModelDescriptor).initOwned(descriptors),
            .fetched_at_ms = 1_700_000_000_000,
            .cache_max_age_ms = 300_000,
        } },
    };
    defer env.deinit(allocator);

    const json = try serializeEnvelope(env, allocator);
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.payload == .models_response);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), parsed.payload.models_response.fetched_at_ms);
    try std.testing.expectEqual(@as(u64, 300_000), parsed.payload.models_response.cache_max_age_ms);

    const parsed_models = parsed.payload.models_response.models.slice();
    try std.testing.expectEqual(@as(usize, 1), parsed_models.len);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", parsed_models[0].model_id.slice());
    try std.testing.expectEqualStrings("anthropic", parsed_models[0].provider_id.slice());
    try std.testing.expectEqualStrings("anthropic-messages", parsed_models[0].api.slice());
    try std.testing.expectEqual(agent_types.ModelSource.dynamic, parsed_models[0].source);
    try std.testing.expectEqual(@as(u32, 200_000), parsed_models[0].context_window.?);
    try std.testing.expectEqual(@as(u32, 8_192), parsed_models[0].max_output_tokens.?);
    try std.testing.expectEqual(agent_types.ReasoningLevel.medium, parsed_models[0].reasoning_default.?);
    try std.testing.expectEqual(@as(usize, 3), parsed_models[0].capabilities.slice().len);
    try std.testing.expectEqual(agent_types.ModelCapability.chat, parsed_models[0].capabilities.slice()[0]);
    try std.testing.expectEqual(agent_types.ModelCapability.reasoning, parsed_models[0].capabilities.slice()[2]);
    try std.testing.expectEqualStrings("tier", parsed_models[0].metadata.?.slice()[0].key.slice());
    try std.testing.expectEqualStrings("standard", parsed_models[0].metadata.?.slice()[0].value.slice());
}

test "agent envelope roundtrip for ack and nack" {
    const allocator = std.testing.allocator;

    const acked_id = agent_types.generateUlid();
    var ack_env = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .ack = .{ .acknowledged_id = acked_id } },
    };
    defer ack_env.deinit(allocator);

    const ack_json = try serializeEnvelope(ack_env, allocator);
    defer allocator.free(ack_json);

    var parsed_ack = try deserializeEnvelope(ack_json, allocator);
    defer parsed_ack.deinit(allocator);

    try std.testing.expect(parsed_ack.payload == .ack);
    try std.testing.expectEqualSlices(u8, &acked_id, &parsed_ack.payload.ack.acknowledged_id);

    const rejected_id = agent_types.generateUlid();
    var nack_env = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = rejected_id,
            .reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "models catalog is not implemented for this runtime")),
            .error_code = .not_implemented,
        } },
    };
    defer nack_env.deinit(allocator);

    const nack_json = try serializeEnvelope(nack_env, allocator);
    defer allocator.free(nack_json);

    var parsed_nack = try deserializeEnvelope(nack_json, allocator);
    defer parsed_nack.deinit(allocator);

    try std.testing.expect(parsed_nack.payload == .nack);
    try std.testing.expectEqualSlices(u8, &rejected_id, &parsed_nack.payload.nack.rejected_id);
    try std.testing.expectEqualStrings(
        "models catalog is not implemented for this runtime",
        parsed_nack.payload.nack.reason.slice(),
    );
    try std.testing.expectEqual(agent_types.ErrorCode.not_implemented, parsed_nack.payload.nack.error_code.?);
}

test "deserializeEnvelope rejects a non-object root" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidField, deserializeEnvelope("[1,2,3]", allocator));
    try std.testing.expectError(error.InvalidField, deserializeEnvelope("42", allocator));
    try std.testing.expectError(error.InvalidField, deserializeEnvelope("\"frame\"", allocator));
}

test "deserializeEnvelope rejects a frame with no envelope fields instead of panicking" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingField, deserializeEnvelope("{\"type\":\"agent_event\"}", allocator));
    try std.testing.expectError(error.MissingField, deserializeEnvelope("{}", allocator));
}

test "deserializeEnvelope rejects a missing or non-string type" {
    const allocator = std.testing.allocator;
    const sid = "000000000000000000000";
    const mid = "00000000000000000000000002";

    const missing = try std.fmt.allocPrint(
        allocator,
        "{{\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{ sid, mid },
    );
    defer allocator.free(missing);
    try std.testing.expectError(error.MissingField, deserializeEnvelope(missing, allocator));

    const wrong_type = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":7,\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{ sid, mid },
    );
    defer allocator.free(wrong_type);
    try std.testing.expectError(error.InvalidField, deserializeEnvelope(wrong_type, allocator));
}

test "deserializeEnvelope rejects a missing or non-string session_id" {
    const allocator = std.testing.allocator;
    const mid = "00000000000000000000000002";

    const missing = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{mid},
    );
    defer allocator.free(missing);
    try std.testing.expectError(error.MissingField, deserializeEnvelope(missing, allocator));

    const non_string = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"session_id\":123,\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{mid},
    );
    defer allocator.free(non_string);
    try std.testing.expectError(error.InvalidField, deserializeEnvelope(non_string, allocator));

    const null_valued = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"session_id\":null,\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{mid},
    );
    defer allocator.free(null_valued);
    try std.testing.expectError(error.InvalidField, deserializeEnvelope(null_valued, allocator));

    const too_short = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"session_id\":\"short\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{mid},
    );
    defer allocator.free(too_short);
    try std.testing.expectError(error.InvalidSessionId, deserializeEnvelope(too_short, allocator));
}

test "deserializeEnvelope rejects a missing or non-string message_id" {
    const allocator = std.testing.allocator;
    const sid = "000000000000000000000";

    const missing = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"session_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{sid},
    );
    defer allocator.free(missing);
    try std.testing.expectError(error.MissingField, deserializeEnvelope(missing, allocator));

    const non_string = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"session_id\":\"{s}\",\"message_id\":[],\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{sid},
    );
    defer allocator.free(non_string);
    try std.testing.expectError(error.InvalidField, deserializeEnvelope(non_string, allocator));
}

test "deserializeEnvelope rejects a missing, non-integer or out-of-range sequence" {
    const allocator = std.testing.allocator;
    const sid = "000000000000000000000";
    const mid = "00000000000000000000000002";

    const missing = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{ sid, mid },
    );
    defer allocator.free(missing);
    try std.testing.expectError(error.MissingField, deserializeEnvelope(missing, allocator));

    const non_integer = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":\"1\",\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{ sid, mid },
    );
    defer allocator.free(non_integer);
    try std.testing.expectError(error.InvalidField, deserializeEnvelope(non_integer, allocator));

    const fractional = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1.5,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{ sid, mid },
    );
    defer allocator.free(fractional);
    try std.testing.expectError(error.InvalidField, deserializeEnvelope(fractional, allocator));

    const negative = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":-1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{ sid, mid },
    );
    defer allocator.free(negative);
    try std.testing.expectError(error.InvalidField, deserializeEnvelope(negative, allocator));
}

test "deserializeEnvelope rejects a missing timestamp and an out-of-range version" {
    const allocator = std.testing.allocator;
    const sid = "000000000000000000000";
    const mid = "00000000000000000000000002";

    const missing_timestamp = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"version\":1,\"payload\":{{}}}}",
        .{ sid, mid },
    );
    defer allocator.free(missing_timestamp);
    try std.testing.expectError(error.MissingField, deserializeEnvelope(missing_timestamp, allocator));

    const oversized_version = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":999,\"payload\":{{}}}}",
        .{ sid, mid },
    );
    defer allocator.free(oversized_version);
    try std.testing.expectError(error.InvalidField, deserializeEnvelope(oversized_version, allocator));
}

test "deserializeEnvelope defaults version to 1 when the field is absent" {
    const allocator = std.testing.allocator;
    const sid = "000000000000000000000";
    const mid = "00000000000000000000000002";

    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"payload\":{{}}}}",
        .{ sid, mid },
    );
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), parsed.version);
}

test "deserializeEnvelope rejects a missing or non-object payload" {
    const allocator = std.testing.allocator;
    const sid = "000000000000000000000";
    const mid = "00000000000000000000000002";

    const missing = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1}}",
        .{ sid, mid },
    );
    defer allocator.free(missing);
    try std.testing.expectError(error.MissingField, deserializeEnvelope(missing, allocator));

    const non_object = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":\"{{}}\"}}",
        .{ sid, mid },
    );
    defer allocator.free(non_object);
    try std.testing.expectError(error.InvalidField, deserializeEnvelope(non_object, allocator));
}

test "deserializeEnvelope rejects a non-string in_reply_to" {
    const allocator = std.testing.allocator;
    const sid = "000000000000000000000";
    const mid = "00000000000000000000000002";

    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"in_reply_to\":false,\"payload\":{{}}}}",
        .{ sid, mid },
    );
    defer allocator.free(json);
    try std.testing.expectError(error.InvalidField, deserializeEnvelope(json, allocator));
}

fn expectPayloadDecodeError(expected: anyerror, type_str: []const u8, payload_json: []const u8) !void {
    const allocator = std.testing.allocator;
    const sid = "000000000000000000000";
    const mid = "00000000000000000000000002";

    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"{s}\",\"session_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{s}}}",
        .{ type_str, sid, mid, payload_json },
    );
    defer allocator.free(json);
    try std.testing.expectError(expected, deserializeEnvelope(json, allocator));
}

test "deserializePayload rejects missing required payload fields" {
    try expectPayloadDecodeError(error.MissingField, "agent_start", "{}");
    try expectPayloadDecodeError(error.MissingField, "agent_message", "{\"session_id\":\"000000000000000000000\"}");
    try expectPayloadDecodeError(error.MissingField, "agent_event", "{}");
    try expectPayloadDecodeError(error.MissingField, "agent_result", "{}");
    try expectPayloadDecodeError(error.MissingField, "agent_stop", "{}");
    try expectPayloadDecodeError(error.MissingField, "agent_status", "{}");
    try expectPayloadDecodeError(error.MissingField, "agent_started", "{}");
    try expectPayloadDecodeError(error.MissingField, "agent_stopped", "{}");
    try expectPayloadDecodeError(error.MissingField, "agent_error", "{\"code\":\"internal_error\"}");
    try expectPayloadDecodeError(error.MissingField, "tool_list_response", "{}");
    try expectPayloadDecodeError(error.MissingField, "tool_execute", "{\"tool_call_id\":\"call-1\"}");
    try expectPayloadDecodeError(error.MissingField, "tool_result", "{\"tool_call_id\":\"call-1\"}");
    try expectPayloadDecodeError(error.MissingField, "tool_streaming", "{\"tool_call_id\":\"call-1\"}");
    try expectPayloadDecodeError(error.MissingField, "pong", "{}");
    try expectPayloadDecodeError(error.MissingField, "ack", "{}");
    try expectPayloadDecodeError(error.MissingField, "nack", "{\"rejected_id\":\"00000000000000000000000002\"}");
    try expectPayloadDecodeError(error.MissingField, "session_info", "{\"session_id\":\"000000000000000000000\",\"status\":\"ready\",\"model\":\"m\"}");
    try expectPayloadDecodeError(error.MissingField, "models_response", "{}");
}

test "deserializePayload rejects wrongly typed payload fields" {
    try expectPayloadDecodeError(error.InvalidField, "agent_start", "{\"config_json\":{}}");
    try expectPayloadDecodeError(error.InvalidField, "agent_start", "{\"config_json\":\"{}\",\"system_prompt\":5}");
    try expectPayloadDecodeError(error.InvalidField, "agent_start", "{\"config_json\":\"{}\",\"session_id\":5}");
    try expectPayloadDecodeError(error.InvalidField, "agent_event", "{\"event_json\":[]}");
    try expectPayloadDecodeError(error.InvalidField, "agent_message", "{\"session_id\":\"000000000000000000000\",\"message_json\":12}");
    try expectPayloadDecodeError(error.InvalidField, "tool_result", "{\"tool_call_id\":\"call-1\",\"result_json\":\"{}\",\"is_error\":\"yes\"}");
    try expectPayloadDecodeError(error.InvalidField, "tool_list_response", "{\"tools\":{}}");
    try expectPayloadDecodeError(error.InvalidField, "tool_list_response", "{\"tools\":[\"not-an-object\"]}");
    try expectPayloadDecodeError(
        error.InvalidField,
        "session_info",
        "{\"session_id\":\"000000000000000000000\",\"status\":\"ready\",\"model\":\"m\",\"message_count\":-1,\"created_at\":1,\"updated_at\":2}",
    );
    try expectPayloadDecodeError(error.InvalidField, "models_request", "{\"provider_id\":9}");
    try expectPayloadDecodeError(error.InvalidField, "models_request", "{\"include_deprecated\":\"true\"}");
    try expectPayloadDecodeError(error.InvalidField, "models_response", "{\"fetched_at_ms\":1,\"cache_max_age_ms\":1,\"models\":\"none\"}");
}

const valid_descriptor_json =
    \\{"model_ref":"p/a@m","model_id":"m","display_name":"M","provider_id":"p","api":"a","auth_status":"authenticated","lifecycle":"stable","source":"dynamic","capabilities":["chat"]}
;

fn expectModelsResponseDecodeError(expected: anyerror, models_json: []const u8) !void {
    const allocator = std.testing.allocator;
    const payload_json = try std.fmt.allocPrint(
        allocator,
        "{{\"fetched_at_ms\":1,\"cache_max_age_ms\":1,\"models\":{s}}}",
        .{models_json},
    );
    defer allocator.free(payload_json);
    try expectPayloadDecodeError(expected, "models_response", payload_json);
}

test "deserializePayload frees earlier allocations when a later tool entry is malformed" {
    try expectPayloadDecodeError(
        error.MissingField,
        "tool_list_response",
        "{\"tools\":[{\"name\":\"a\",\"description\":\"d\",\"parameters_schema_json\":\"{}\"},{\"name\":\"b\",\"description\":\"d\"}]}",
    );
}

test "deserializePayload frees earlier descriptors when a later model is malformed" {
    const allocator = std.testing.allocator;
    const models_json = try std.fmt.allocPrint(
        allocator,
        "[{s},{{\"model_ref\":\"p/a@n\"}}]",
        .{valid_descriptor_json},
    );
    defer allocator.free(models_json);
    try expectModelsResponseDecodeError(error.MissingField, models_json);
}

test "deserializeModelDescriptor frees owned fields when capabilities or metadata are malformed" {
    try expectModelsResponseDecodeError(
        error.InvalidField,
        "[{\"model_ref\":\"p/a@m\",\"model_id\":\"m\",\"display_name\":\"M\",\"provider_id\":\"p\",\"api\":\"a\",\"base_url\":\"https://x\",\"auth_status\":\"authenticated\",\"lifecycle\":\"stable\",\"source\":\"dynamic\",\"capabilities\":[7]}]",
    );
    try expectModelsResponseDecodeError(
        error.InvalidField,
        "[{\"model_ref\":\"p/a@m\",\"model_id\":\"m\",\"display_name\":\"M\",\"provider_id\":\"p\",\"api\":\"a\",\"base_url\":\"https://x\",\"auth_status\":\"authenticated\",\"lifecycle\":\"stable\",\"source\":\"dynamic\",\"capabilities\":[\"chat\"],\"metadata\":{\"a\":\"1\",\"b\":2}}]",
    );
    try expectModelsResponseDecodeError(
        error.MissingField,
        "[{\"model_ref\":\"p/a@m\",\"model_id\":\"m\",\"display_name\":\"M\",\"provider_id\":\"p\",\"api\":\"a\",\"auth_status\":\"authenticated\",\"lifecycle\":\"stable\",\"source\":\"dynamic\"}]",
    );
    try expectModelsResponseDecodeError(
        error.InvalidEnumValue,
        "[{\"model_ref\":\"p/a@m\",\"model_id\":\"m\",\"display_name\":\"M\",\"provider_id\":\"p\",\"api\":\"a\",\"auth_status\":\"authenticated\",\"lifecycle\":\"experimental\",\"source\":\"dynamic\",\"capabilities\":[\"chat\"]}]",
    );
}
