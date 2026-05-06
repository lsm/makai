const std = @import("std");
const agent_types = @import("agent_types");
const json_writer = @import("json_writer");
const model_catalog_types = @import("model_catalog_types");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const protocol_types = agent_types;

pub fn serializeEnvelope(env: agent_types.Envelope, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8){};
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

    const root = parsed.value.object;
    const type_str = root.get("type").?.string;
    const session_id = parseSessionIdOrError(root.get("session_id").?.string) orelse return error.InvalidSessionId;
    const message_id = try parseUlidRequired(root.get("message_id").?.string);
    const sequence = @as(u64, @intCast(root.get("sequence").?.integer));
    const timestamp = root.get("timestamp").?.integer;
    const version = @as(u8, @intCast(root.get("version").?.integer));

    var in_reply_to: ?agent_types.Ulid = null;
    if (root.get("in_reply_to")) |v| in_reply_to = try parseUlidRequired(v.string);

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
        const config = try allocator.dupe(u8, payload.get("config_json").?.string);
        var result = agent_types.AgentStartRequest{ .config_json = config };
        if (payload.get("system_prompt")) |v| result.system_prompt = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        if (payload.get("resume_session_id")) |v| result.session_id = try parseSessionIdRequired(v.string);
        return .{ .agent_start = result };
    }
    if (std.mem.eql(u8, type_str, "agent_message")) {
        const msg = try allocator.dupe(u8, payload.get("message_json").?.string);
        var req = agent_types.AgentMessageRequest{
            .session_id = try parseSessionIdRequired(payload.get("session_id").?.string),
            .message_json = msg,
        };
        if (payload.get("options_json")) |v| req.options_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .agent_message = req };
    }
    if (std.mem.eql(u8, type_str, "agent_stop")) {
        var req = agent_types.AgentStopRequest{ .session_id = try parseSessionIdRequired(payload.get("session_id").?.string) };
        if (payload.get("reason")) |v| req.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .agent_stop = req };
    }
    if (std.mem.eql(u8, type_str, "agent_status")) {
        return .{ .agent_status = .{ .session_id = try parseSessionIdRequired(payload.get("session_id").?.string) } };
    }
    if (std.mem.eql(u8, type_str, "tool_list")) {
        var req = agent_types.ToolListRequest{};
        if (payload.get("prefix")) |v| req.prefix = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .tool_list = req };
    }
    if (std.mem.eql(u8, type_str, "agent_started")) {
        return .{ .agent_started = .{ .session_id = try parseSessionIdRequired(payload.get("session_id").?.string) } };
    }
    if (std.mem.eql(u8, type_str, "agent_event")) return .{ .agent_event = try allocator.dupe(u8, payload.get("event_json").?.string) };
    if (std.mem.eql(u8, type_str, "agent_result")) return .{ .agent_result = try allocator.dupe(u8, payload.get("result_json").?.string) };
    if (std.mem.eql(u8, type_str, "agent_stopped")) {
        var stopped = agent_types.AgentStopped{ .session_id = try parseSessionIdRequired(payload.get("session_id").?.string) };
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
            .session_id = try parseSessionIdRequired(payload.get("session_id").?.string),
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
    if (std.mem.eql(u8, type_str, "ack")) {
        return .{ .ack = .{ .acknowledged_id = try parseUlidRequired(payload.get("acknowledged_id").?.string) } };
    }
    if (std.mem.eql(u8, type_str, "nack")) {
        const rejected_id = try parseUlidRequired(payload.get("rejected_id").?.string);
        const reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, payload.get("reason").?.string));
        // forward-compat: unknown error codes degrade to null rather than
        // failing deserialization. This is intentional asymmetry from the
        // other enum parsers in this file (which fail with InvalidEnumValue):
        // a newer peer may emit a code our build doesn't know about, and we
        // would rather still surface the human-readable `reason` than reject
        // the whole nack envelope. Callers MUST treat `null` as "unrecognised
        // code" and fall back to `reason` for diagnostics.
        const error_code = if (payload.get("error_code")) |v|
            std.meta.stringToEnum(agent_types.ErrorCode, v.string)
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
    const provider_id = if (obj.get("provider_id")) |value|
        OwnedSlice(u8).initOwned(try allocator.dupe(u8, value.string))
    else
        OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = provider_id;
        mutable.deinit(allocator);
    }

    const api = if (obj.get("api")) |value|
        OwnedSlice(u8).initOwned(try allocator.dupe(u8, value.string))
    else
        OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = api;
        mutable.deinit(allocator);
    }

    const model_id = if (obj.get("model_id")) |value|
        OwnedSlice(u8).initOwned(try allocator.dupe(u8, value.string))
    else
        OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = model_id;
        mutable.deinit(allocator);
    }

    const include_deprecated = if (obj.get("include_deprecated")) |value| value.bool else false;
    const include_login_required = if (obj.get("include_login_required")) |value| value.bool else true;

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
    const fetched_at_ms = obj.get("fetched_at_ms").?.integer;
    const cache_max_age_ms: u64 = @intCast(obj.get("cache_max_age_ms").?.integer);
    const models_array = obj.get("models").?.array;

    const descriptors = try allocator.alloc(model_catalog_types.ModelDescriptor, models_array.items.len);
    var allocated_count: usize = 0;
    errdefer {
        for (descriptors[0..allocated_count]) |*descriptor| descriptor.deinit(allocator);
        allocator.free(descriptors);
    }

    for (models_array.items, 0..) |item, idx| {
        descriptors[idx] = try deserializeModelDescriptor(item.object, allocator);
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
    const model_ref = OwnedSlice(u8).initOwned(try allocator.dupe(u8, obj.get("model_ref").?.string));
    errdefer {
        var mutable = model_ref;
        mutable.deinit(allocator);
    }

    const model_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, obj.get("model_id").?.string));
    errdefer {
        var mutable = model_id;
        mutable.deinit(allocator);
    }

    const display_name = OwnedSlice(u8).initOwned(try allocator.dupe(u8, obj.get("display_name").?.string));
    errdefer {
        var mutable = display_name;
        mutable.deinit(allocator);
    }

    const provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, obj.get("provider_id").?.string));
    errdefer {
        var mutable = provider_id;
        mutable.deinit(allocator);
    }

    const api = OwnedSlice(u8).initOwned(try allocator.dupe(u8, obj.get("api").?.string));
    errdefer {
        var mutable = api;
        mutable.deinit(allocator);
    }

    const base_url = if (obj.get("base_url")) |value|
        OwnedSlice(u8).initOwned(try allocator.dupe(u8, value.string))
    else
        OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = base_url;
        mutable.deinit(allocator);
    }

    const capabilities_array = obj.get("capabilities").?.array;
    const capabilities = try allocator.alloc(model_catalog_types.ModelCapability, capabilities_array.items.len);
    errdefer allocator.free(capabilities);
    for (capabilities_array.items, 0..) |item, idx| {
        capabilities[idx] = try parseModelCapability(item.string);
    }

    var metadata: ?OwnedSlice(model_catalog_types.MetadataEntry) = null;
    if (obj.get("metadata")) |metadata_value| {
        const metadata_obj = metadata_value.object;
        const metadata_items = try allocator.alloc(model_catalog_types.MetadataEntry, metadata_obj.count());
        var metadata_count: usize = 0;
        errdefer {
            for (metadata_items[0..metadata_count]) |*entry| entry.deinit(allocator);
            allocator.free(metadata_items);
        }

        var iter = metadata_obj.iterator();
        while (iter.next()) |entry| {
            metadata_items[metadata_count] = .{
                .key = OwnedSlice(u8).initOwned(try allocator.dupe(u8, entry.key_ptr.*)),
                .value = OwnedSlice(u8).initOwned(try allocator.dupe(u8, entry.value_ptr.string)),
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
        .auth_status = parseAuthStatus(obj.get("auth_status").?.string),
        .lifecycle = try parseModelLifecycle(obj.get("lifecycle").?.string),
        .capabilities = OwnedSlice(model_catalog_types.ModelCapability).initOwned(capabilities),
        .source = try parseModelSource(obj.get("source").?.string),
        .context_window = if (obj.get("context_window")) |value| @intCast(value.integer) else null,
        .max_output_tokens = if (obj.get("max_output_tokens")) |value| @intCast(value.integer) else null,
        .reasoning_default = if (obj.get("reasoning_default")) |value| try parseReasoningLevel(value.string) else null,
        .metadata = metadata,
    };
}

// `.unknown` is a forward-compatibility sentinel — auth states added in
// future protocol versions degrade gracefully to `.unknown` rather than
// failing deserialization (intentionally asymmetric with `parseModelLifecycle`
// / `parseModelCapability` / `parseModelSource` / `parseReasoningLevel`,
// which all fail hard on unknown strings because those enums have no
// "unknown" sentinel and a missing variant indicates a real protocol bug).
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
    const bad =
        "{\"type\":\"ping\",\"session_id\":\"not-a-ulid\",\"message_id\":\"not-a-ulid\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{}}";
    try std.testing.expectError(error.InvalidUlid, deserializeEnvelope(bad, allocator));
}

test "deserializeEnvelope rejects unknown payload type" {
    const allocator = std.testing.allocator;
    const sid = "00000000000000000000000001";
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
        .timestamp = std.time.milliTimestamp(),
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

test "agent envelope roundtrip for models_request" {
    const allocator = std.testing.allocator;

    var env = agent_types.Envelope{
        .session_id = agent_types.generateSessionId(),
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
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
        .timestamp = std.time.milliTimestamp(),
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
        .timestamp = std.time.milliTimestamp(),
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
        .timestamp = std.time.milliTimestamp(),
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
