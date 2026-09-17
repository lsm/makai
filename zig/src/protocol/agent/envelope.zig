const std = @import("std");
const compat = @import("compat");
const agent_types = @import("agent_types");
const fields = @import("envelope_fields");
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

    const root = try fields.rootObject(parsed.value);
    const type_str = try fields.requiredString(root, "type");
    const session_id = parseSessionIdOrError(try fields.requiredString(root, "session_id")) orelse return error.InvalidSessionId;
    const message_id = try parseUlidRequired(try fields.requiredString(root, "message_id"));
    const sequence = try fields.requiredInt(u64, root, "sequence");
    const timestamp = try fields.requiredInteger(root, "timestamp");
    const version = try fields.requiredInt(u8, root, "version");

    var in_reply_to: ?agent_types.Ulid = null;
    if (try fields.optionalString(root, "in_reply_to")) |v| in_reply_to = try parseUlidRequired(v);

    const payload_obj = try fields.requiredObject(root, "payload");
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

fn parseUlidRequired(str: []const u8) !agent_types.Ulid {
    return agent_types.parseUlid(str) orelse error.InvalidUlid;
}

fn parseSessionIdRequired(str: []const u8) !agent_types.SessionId {
    return agent_types.parseSessionId(str) orelse error.InvalidSessionId;
}

fn parseSessionIdOrError(str: []const u8) ?agent_types.SessionId {
    return agent_types.parseSessionId(str);
}

fn deserializePayload(type_str: []const u8, payload: std.json.ObjectMap, allocator: std.mem.Allocator) !agent_types.Payload {
    if (std.mem.eql(u8, type_str, "agent_start")) {
        const config = try allocator.dupe(u8, try fields.requiredString(payload, "config_json"));
        errdefer allocator.free(config);

        var system_prompt = OwnedSlice(u8).initBorrowed("");
        errdefer system_prompt.deinit(allocator);
        if (try fields.optionalString(payload, "system_prompt")) |v| {
            system_prompt = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
        }

        var result = agent_types.AgentStartRequest{
            .config_json = config,
            .system_prompt = system_prompt,
        };
        if (try fields.optionalString(payload, "session_id")) |v| {
            result.session_id = try parseSessionIdRequired(v);
        } else if (try fields.optionalString(payload, "resume_session_id")) |v| {
            result.session_id = try parseSessionIdRequired(v);
        }
        return .{ .agent_start = result };
    }
    if (std.mem.eql(u8, type_str, "agent_message")) {
        const msg = try allocator.dupe(u8, try fields.requiredString(payload, "message_json"));
        errdefer allocator.free(msg);
        const session_id = try parseSessionIdRequired(try fields.requiredString(payload, "session_id"));

        var options_json = OwnedSlice(u8).initBorrowed("");
        if (try fields.optionalString(payload, "options_json")) |v| {
            options_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
        }

        return .{ .agent_message = .{
            .session_id = session_id,
            .message_json = msg,
            .options_json = options_json,
        } };
    }
    if (std.mem.eql(u8, type_str, "agent_stop")) {
        var req = agent_types.AgentStopRequest{ .session_id = try parseSessionIdRequired(try fields.requiredString(payload, "session_id")) };
        if (try fields.optionalString(payload, "reason")) |v| req.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
        return .{ .agent_stop = req };
    }
    if (std.mem.eql(u8, type_str, "agent_status")) {
        return .{ .agent_status = .{ .session_id = try parseSessionIdRequired(try fields.requiredString(payload, "session_id")) } };
    }
    if (std.mem.eql(u8, type_str, "tool_list")) {
        var req = agent_types.ToolListRequest{};
        if (try fields.optionalString(payload, "prefix")) |v| req.prefix = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
        return .{ .tool_list = req };
    }
    if (std.mem.eql(u8, type_str, "agent_started")) {
        return .{ .agent_started = .{ .session_id = try parseSessionIdRequired(try fields.requiredString(payload, "session_id")) } };
    }
    if (std.mem.eql(u8, type_str, "agent_event")) return .{ .agent_event = try allocator.dupe(u8, try fields.requiredString(payload, "event_json")) };
    if (std.mem.eql(u8, type_str, "agent_result")) return .{ .agent_result = try allocator.dupe(u8, try fields.requiredString(payload, "result_json")) };
    if (std.mem.eql(u8, type_str, "agent_stopped")) {
        var stopped = agent_types.AgentStopped{ .session_id = try parseSessionIdRequired(try fields.requiredString(payload, "session_id")) };
        if (try fields.optionalString(payload, "reason")) |v| stopped.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
        return .{ .agent_stopped = stopped };
    }
    if (std.mem.eql(u8, type_str, "agent_error")) {
        const code = std.meta.stringToEnum(agent_types.AgentErrorCode, try fields.requiredString(payload, "code")) orelse .internal_error;
        const message = try allocator.dupe(u8, try fields.requiredString(payload, "message"));
        return .{ .agent_error = .{
            .code = code,
            .message = message,
        } };
    }
    if (std.mem.eql(u8, type_str, "session_info")) {
        const session_id = try parseSessionIdRequired(try fields.requiredString(payload, "session_id"));
        const status = std.meta.stringToEnum(agent_types.AgentStatus, try fields.requiredString(payload, "status")) orelse .@"error";
        const message_count = try fields.requiredInt(u32, payload, "message_count");
        const created_at = try fields.requiredInteger(payload, "created_at");
        const updated_at = try fields.requiredInteger(payload, "updated_at");
        const model = try allocator.dupe(u8, try fields.requiredString(payload, "model"));
        return .{ .session_info = .{
            .session_id = session_id,
            .status = status,
            .model = model,
            .message_count = message_count,
            .created_at = created_at,
            .updated_at = updated_at,
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_list_response")) {
        const tools_arr = try fields.requiredArray(payload, "tools");
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
            const tool_obj = try fields.asObject(t);
            const name = try allocator.dupe(u8, try fields.requiredString(tool_obj, "name"));
            errdefer allocator.free(name);
            const description = try allocator.dupe(u8, try fields.requiredString(tool_obj, "description"));
            errdefer allocator.free(description);
            const parameters_schema_json = try allocator.dupe(u8, try fields.requiredString(tool_obj, "parameters_schema_json"));
            tools[i] = .{
                .name = name,
                .description = description,
                .parameters_schema_json = parameters_schema_json,
            };
            initialized += 1;
        }
        return .{ .tool_list_response = .{ .tools = tools } };
    }
    if (std.mem.eql(u8, type_str, "tool_execute")) {
        const tool_call_id = try allocator.dupe(u8, try fields.requiredString(payload, "tool_call_id"));
        errdefer allocator.free(tool_call_id);
        const tool_name = try allocator.dupe(u8, try fields.requiredString(payload, "tool_name"));
        errdefer allocator.free(tool_name);
        const args_json = try allocator.dupe(u8, try fields.requiredString(payload, "args_json"));
        errdefer allocator.free(args_json);
        var req = agent_types.ToolExecuteRequest{
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
            .args_json = args_json,
        };
        if (try fields.optionalString(payload, "callback_url")) |v| req.callback_url = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
        return .{ .tool_execute = req };
    }
    if (std.mem.eql(u8, type_str, "tool_result")) {
        const tool_call_id = try allocator.dupe(u8, try fields.requiredString(payload, "tool_call_id"));
        errdefer allocator.free(tool_call_id);
        const result_json = try allocator.dupe(u8, try fields.requiredString(payload, "result_json"));
        errdefer allocator.free(result_json);
        var res = agent_types.ToolExecuteResponse{
            .tool_call_id = tool_call_id,
            .result_json = result_json,
            .is_error = try fields.optionalBool(payload, "is_error", false),
        };
        if (try fields.optionalString(payload, "details_json")) |v| res.details_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
        return .{ .tool_result = res };
    }
    if (std.mem.eql(u8, type_str, "tool_streaming")) {
        const tool_call_id = try allocator.dupe(u8, try fields.requiredString(payload, "tool_call_id"));
        errdefer allocator.free(tool_call_id);
        const partial_json = try allocator.dupe(u8, try fields.requiredString(payload, "partial_json"));
        return .{ .tool_streaming = .{
            .tool_call_id = tool_call_id,
            .partial_json = partial_json,
        } };
    }
    if (std.mem.eql(u8, type_str, "ping")) return .ping;
    if (std.mem.eql(u8, type_str, "pong")) return .{ .pong = .{ .ping_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(payload, "ping_id"))) } };
    if (std.mem.eql(u8, type_str, "goodbye")) {
        var g = agent_types.Goodbye{};
        if (try fields.optionalString(payload, "reason")) |v| g.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
        return .{ .goodbye = g };
    }
    if (std.mem.eql(u8, type_str, "ack")) {
        return .{ .ack = .{ .acknowledged_id = try parseUlidRequired(try fields.requiredString(payload, "acknowledged_id")) } };
    }
    if (std.mem.eql(u8, type_str, "nack")) {
        const rejected_id = try parseUlidRequired(try fields.requiredString(payload, "rejected_id"));
        var reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(payload, "reason")));
        errdefer reason.deinit(allocator);
        const error_code = if (try fields.optionalString(payload, "error_code")) |v|
            std.meta.stringToEnum(agent_types.ErrorCode, v)
        else
            null;
        return .{ .nack = .{
            .rejected_id = rejected_id,
            .reason = reason,
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
    const provider_id = if (try fields.optionalString(obj, "provider_id")) |value|
        OwnedSlice(u8).initOwned(try allocator.dupe(u8, value))
    else
        OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = provider_id;
        mutable.deinit(allocator);
    }

    const api = if (try fields.optionalString(obj, "api")) |value|
        OwnedSlice(u8).initOwned(try allocator.dupe(u8, value))
    else
        OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = api;
        mutable.deinit(allocator);
    }

    const model_id = if (try fields.optionalString(obj, "model_id")) |value|
        OwnedSlice(u8).initOwned(try allocator.dupe(u8, value))
    else
        OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = model_id;
        mutable.deinit(allocator);
    }

    const include_deprecated = try fields.optionalBool(obj, "include_deprecated", false);
    const include_login_required = try fields.optionalBool(obj, "include_login_required", true);

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
    const fetched_at_ms = try fields.requiredInteger(obj, "fetched_at_ms");
    const cache_max_age_ms = try fields.requiredInt(u64, obj, "cache_max_age_ms");
    const models_array = try fields.requiredArray(obj, "models");

    const descriptors = try allocator.alloc(model_catalog_types.ModelDescriptor, models_array.items.len);
    var allocated_count: usize = 0;
    errdefer {
        for (descriptors[0..allocated_count]) |*descriptor| descriptor.deinit(allocator);
        allocator.free(descriptors);
    }

    for (models_array.items, 0..) |item, idx| {
        descriptors[idx] = try deserializeModelDescriptor(try fields.asObject(item), allocator);
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
    const model_ref = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(obj, "model_ref")));
    errdefer {
        var mutable = model_ref;
        mutable.deinit(allocator);
    }

    const model_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(obj, "model_id")));
    errdefer {
        var mutable = model_id;
        mutable.deinit(allocator);
    }

    const display_name = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(obj, "display_name")));
    errdefer {
        var mutable = display_name;
        mutable.deinit(allocator);
    }

    const provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(obj, "provider_id")));
    errdefer {
        var mutable = provider_id;
        mutable.deinit(allocator);
    }

    const api = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(obj, "api")));
    errdefer {
        var mutable = api;
        mutable.deinit(allocator);
    }

    const base_url = if (try fields.optionalString(obj, "base_url")) |value|
        OwnedSlice(u8).initOwned(try allocator.dupe(u8, value))
    else
        OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = base_url;
        mutable.deinit(allocator);
    }

    const capabilities_array = try fields.requiredArray(obj, "capabilities");
    const capabilities = try allocator.alloc(model_catalog_types.ModelCapability, capabilities_array.items.len);
    errdefer allocator.free(capabilities);
    for (capabilities_array.items, 0..) |item, idx| {
        capabilities[idx] = try parseModelCapability(try fields.asString(item));
    }

    var metadata: ?OwnedSlice(model_catalog_types.MetadataEntry) = null;
    var metadata_items: []model_catalog_types.MetadataEntry = &.{};
    var metadata_count: usize = 0;
    errdefer {
        for (metadata_items[0..metadata_count]) |*entry| entry.deinit(allocator);
        allocator.free(metadata_items);
    }
    if (try fields.optionalObject(obj, "metadata")) |metadata_obj| {
        metadata_items = try allocator.alloc(model_catalog_types.MetadataEntry, metadata_obj.count());

        var iter = metadata_obj.iterator();
        while (iter.next()) |entry| {
            const value_text = try fields.asString(entry.value_ptr.*);

            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            const value = try allocator.dupe(u8, value_text);

            metadata_items[metadata_count] = .{
                .key = OwnedSlice(u8).initOwned(key),
                .value = OwnedSlice(u8).initOwned(value),
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
        .auth_status = parseAuthStatus(try fields.requiredString(obj, "auth_status")),
        .lifecycle = try parseModelLifecycle(try fields.requiredString(obj, "lifecycle")),
        .capabilities = OwnedSlice(model_catalog_types.ModelCapability).initOwned(capabilities),
        .source = try parseModelSource(try fields.requiredString(obj, "source")),
        .context_window = try fields.optionalIntValue(u32, obj.get("context_window")),
        .max_output_tokens = try fields.optionalIntValue(u32, obj.get("max_output_tokens")),
        .reasoning_default = if (try fields.optionalString(obj, "reasoning_default")) |value| try parseReasoningLevel(value) else null,
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
    const payload = try fields.requiredObject(try fields.asObject(parsed_json.value), "payload");
    try std.testing.expectEqualStrings(&sid, try fields.requiredString(payload, "session_id"));
    try std.testing.expectEqualStrings(&sid, try fields.requiredString(payload, "resume_session_id"));

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

test "agent envelope rejects missing required root fields" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        \\{"session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","session_id":"V1StGXR8Z5jdHi6BmyT0a","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"payload":{}}
        ,
        \\{"type":"ping","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1}
        ,
    };

    for (cases) |json| {
        try std.testing.expectError(error.MissingField, deserializeEnvelope(json, allocator));
    }
}

test "agent envelope rejects wrong-typed root fields" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        \\{"type":7,"session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","session_id":7,"message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":7,"sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":"1","timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":"1","version":1,"payload":{}}
        ,
        \\{"type":"ping","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":[]}
        ,
        \\{"type":"ping","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"in_reply_to":7,"payload":{}}
        ,
    };

    for (cases) |json| {
        try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(json, allocator));
    }
}

test "agent envelope rejects out-of-range root numbers and non-object documents" {
    const allocator = std.testing.allocator;
    const negative_sequence =
        \\{"type":"ping","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":-1,"timestamp":1,"version":1,"payload":{}}
    ;
    const oversized_version =
        \\{"type":"ping","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":99999,"payload":{}}
    ;

    try std.testing.expectError(error.FieldOutOfRange, deserializeEnvelope(negative_sequence, allocator));
    try std.testing.expectError(error.FieldOutOfRange, deserializeEnvelope(oversized_version, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope("[1,2,3]", allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope("null", allocator));
}

test "agent envelope rejects malformed payload fields without leaking" {
    const allocator = std.testing.allocator;
    const start_missing_config =
        \\{"type":"agent_start","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
    ;
    const message_missing_json =
        \\{"type":"agent_message","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"session_id":"V1StGXR8Z5jdHi6BmyT0a"}}
    ;
    const message_wrong_typed_json =
        \\{"type":"agent_message","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"session_id":"V1StGXR8Z5jdHi6BmyT0a","message_json":7}}
    ;
    const tool_list_missing_description =
        \\{"type":"tool_list_response","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"tools":[{"name":"t"}]}}
    ;
    const tool_list_not_array =
        \\{"type":"tool_list_response","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"tools":{}}}
    ;
    const tool_execute_missing_args =
        \\{"type":"tool_execute","session_id":"V1StGXR8Z5jdHi6BmyT0a","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"tool_call_id":"c","tool_name":"t"}}
    ;

    try std.testing.expectError(error.MissingField, deserializeEnvelope(start_missing_config, allocator));
    try std.testing.expectError(error.MissingField, deserializeEnvelope(message_missing_json, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(message_wrong_typed_json, allocator));
    try std.testing.expectError(error.MissingField, deserializeEnvelope(tool_list_missing_description, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(tool_list_not_array, allocator));
    try std.testing.expectError(error.MissingField, deserializeEnvelope(tool_execute_missing_args, allocator));
}

test "a wrong-typed optional after an owned field is rejected without leaking" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        \\{"type":"agent_start","session_id":"Abcdefghijklmnopqrstu","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"config_json":"{}","system_prompt":7}}
        ,
        \\{"type":"agent_start","session_id":"Abcdefghijklmnopqrstu","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"config_json":"{}","system_prompt":"hi","session_id":"too-short"}}
        ,
        \\{"type":"agent_start","session_id":"Abcdefghijklmnopqrstu","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"config_json":"{}","resume_session_id":"too-short"}}
        ,
        \\{"type":"agent_message","session_id":"Abcdefghijklmnopqrstu","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":2,"timestamp":1,"version":1,"payload":{"message_json":"{}","session_id":"too-short"}}
        ,
        \\{"type":"agent_message","session_id":"Abcdefghijklmnopqrstu","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":2,"timestamp":1,"version":1,"payload":{"message_json":"{}","session_id":"Abcdefghijklmnopqrstu","options_json":7}}
        ,
    };

    for (cases) |json| {
        try std.testing.expect(std.meta.isError(deserializeEnvelope(json, allocator)));
    }
}

test "agent model descriptor frees metadata when a trailing field is malformed" {
    const allocator = std.testing.allocator;
    const base = "{\"type\":\"models_response\",\"session_id\":\"V1StGXR8Z5jdHi6BmyT0a\",\"message_id\":\"01M2MYK69FX2M3DY769FEHK3M1\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"fetched_at_ms\":1,\"cache_max_age_ms\":1,\"models\":[{\"model_ref\":\"p/a@m\",\"model_id\":\"m\",\"display_name\":\"d\",\"provider_id\":\"p\",\"api\":\"a\",\"capabilities\":[\"chat\"],\"metadata\":{\"one\":\"1\",\"two\":\"2\"},";

    const missing_auth_status = base ++ "\"lifecycle\":\"stable\",\"source\":\"dynamic\"}]}}";
    const missing_lifecycle = base ++ "\"auth_status\":\"authenticated\",\"source\":\"dynamic\"}]}}";
    const bad_lifecycle = base ++ "\"auth_status\":\"authenticated\",\"lifecycle\":\"nope\",\"source\":\"dynamic\"}]}}";
    const missing_source = base ++ "\"auth_status\":\"authenticated\",\"lifecycle\":\"stable\"}]}}";
    const bad_source = base ++ "\"auth_status\":\"authenticated\",\"lifecycle\":\"stable\",\"source\":\"nope\"}]}}";
    const bad_context_window = base ++ "\"auth_status\":\"authenticated\",\"lifecycle\":\"stable\",\"source\":\"dynamic\",\"context_window\":-1}]}}";
    const bad_reasoning_default = base ++ "\"auth_status\":\"authenticated\",\"lifecycle\":\"stable\",\"source\":\"dynamic\",\"reasoning_default\":\"nope\"}]}}";

    try std.testing.expectError(error.MissingField, deserializeEnvelope(missing_auth_status, allocator));
    try std.testing.expectError(error.MissingField, deserializeEnvelope(missing_lifecycle, allocator));
    try std.testing.expectError(error.InvalidEnumValue, deserializeEnvelope(bad_lifecycle, allocator));
    try std.testing.expectError(error.MissingField, deserializeEnvelope(missing_source, allocator));
    try std.testing.expectError(error.InvalidEnumValue, deserializeEnvelope(bad_source, allocator));
    try std.testing.expectError(error.FieldOutOfRange, deserializeEnvelope(bad_context_window, allocator));
    try std.testing.expectError(error.InvalidEnumValue, deserializeEnvelope(bad_reasoning_default, allocator));
}

test "agent models_response rejects a non-string metadata value without leaking the key" {
    const allocator = std.testing.allocator;

    const capabilities = try allocator.alloc(agent_types.ModelCapability, 1);
    capabilities[0] = .chat;

    const metadata = try allocator.alloc(agent_types.MetadataEntry, 1);
    metadata[0] = .{
        .key = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "tier")),
        .value = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "premium")),
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

    const mistyped = try std.mem.replaceOwned(u8, allocator, json, "\"premium\"", "5");
    defer allocator.free(mistyped);

    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(mistyped, allocator));
}
