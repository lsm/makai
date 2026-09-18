const std = @import("std");
const json_writer = @import("json_writer");
const oap_types = @import("oap_types");

pub const DecodeError = error{
    InvalidEnvelope,
    UnknownEnvelopeType,
    ProtocolMismatch,
    VersionMismatch,
    ProfileMismatch,
    MissingField,
    InvalidField,
};

pub fn serializeEnvelope(env: oap_types.Envelope, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);

    try w.beginObject();
    try w.writeStringField("protocol", oap_types.PROTOCOL);
    try w.writeStringField("version", oap_types.VERSION);
    try w.writeStringField("profile", oap_types.PROFILE);
    try w.writeStringField("type", env.payload.typeName());
    try w.writeStringField("id", env.id);
    if (env.sequence) |sequence| try w.writeIntField("sequence", sequence);
    if (env.timestamp_ms) |timestamp| try w.writeIntField("timestamp_ms", timestamp);
    if (env.in_reply_to) |value| try w.writeStringField("in_reply_to", value);
    if (env.session_id) |value| try w.writeStringField("session_id", value);
    if (env.run_id) |value| try w.writeStringField("run_id", value);
    if (env.turn_id) |value| try w.writeStringField("turn_id", value);
    if (env.tool_call_id) |value| try w.writeStringField("tool_call_id", value);
    if (env.capability_revision) |value| try w.writeStringField("capability_revision", value);

    try w.writeKey("payload");
    try serializePayload(&w, env.payload);
    try w.endObject();

    const out = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return out;
}

pub fn writeJsonValueOrString(w: *json_writer.JsonWriter, raw: []const u8) !void {
    if (isWellFormedJson(raw)) {
        try w.writeRawJson(raw);
    } else {
        try w.writeString(raw);
    }
}

fn isWellFormedJson(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return false;
    var scanner = std.json.Scanner.initCompleteInput(std.heap.page_allocator, trimmed);
    defer scanner.deinit();
    while (true) {
        const token = scanner.next() catch return false;
        if (token == .end_of_document) return true;
    }
}

pub fn serializeContentPart(w: *json_writer.JsonWriter, part: oap_types.ContentPart) !void {
    try w.beginObject();
    switch (part) {
        .text => |value| {
            try w.writeStringField("type", "text");
            try w.writeStringField("text", value);
        },
        .reasoning => |value| {
            try w.writeStringField("type", "reasoning");
            try w.writeStringField("reasoning", value.text);
            if (value.carry) |carry| try w.writeStringField("carry", carry);
        },
        .tool_call => |value| {
            try w.writeStringField("type", "tool_call");
            try w.writeStringField("tool_call_id", value.tool_call_id);
            try w.writeStringField("name", value.name);
            try w.writeKey("arguments_json");
            try writeJsonValueOrString(w, value.arguments_json);
            if (value.carry) |carry| try w.writeStringField("carry", carry);
        },
        .tool_result => |value| {
            try w.writeStringField("type", "tool_result");
            try w.writeStringField("tool_call_id", value.tool_call_id);
            try w.writeKey("result");
            try writeJsonValueOrString(w, value.result_json);
            if (value.is_error) |is_error| try w.writeBoolField("is_error", is_error);
        },
    }
    try w.endObject();
}

pub fn serializeMessage(w: *json_writer.JsonWriter, message: oap_types.Message) !void {
    try w.beginObject();
    if (message.id) |id| try w.writeStringField("id", id);
    try w.writeStringField("role", @tagName(message.role));
    try w.writeKey("content");
    switch (message.content) {
        .text => |value| try w.writeString(value),
        .parts => |parts| {
            try w.beginArray();
            for (parts) |part| try serializeContentPart(w, part);
            try w.endArray();
        },
    }
    try w.endObject();
}

pub fn serializeUsage(w: *json_writer.JsonWriter, usage: oap_types.Usage) !void {
    try w.writeKey("usage");
    try w.beginObject();
    if (usage.input_tokens) |value| try w.writeIntField("input_tokens", value);
    if (usage.output_tokens) |value| try w.writeIntField("output_tokens", value);
    if (usage.total_tokens) |value| try w.writeIntField("total_tokens", value);
    try w.endObject();
}

fn serializeProtocolError(w: *json_writer.JsonWriter, err: oap_types.ProtocolError) !void {
    try w.beginObject();
    try w.writeStringField("code", @tagName(err.code));
    try w.writeStringField("message", err.message);
    if (err.retriable) |retriable| try w.writeBoolField("retriable", retriable);
    if (err.details.len > 0) {
        try w.writeKey("details");
        try w.beginObject();
        for (err.details) |entry| try w.writeStringField(entry.key, entry.value);
        try w.endObject();
    }
    try w.endObject();
}

fn serializeSessionState(w: *json_writer.JsonWriter, state: oap_types.SessionState) !void {
    try w.writeStringField("session_id", state.session_id);
    try w.writeStringField("status", @tagName(state.status));
    if (state.active_run_id) |value| try w.writeStringField("active_run_id", value);
    if (state.current_model_id) |value| try w.writeStringField("current_model_id", value);
    if (state.updated_at_ms) |value| try w.writeIntField("updated_at_ms", value);
}

fn serializeEndpoint(w: *json_writer.JsonWriter, endpoint: oap_types.Endpoint) !void {
    try w.beginObject();
    try w.writeStringField("id", endpoint.id);
    if (endpoint.name) |value| try w.writeStringField("name", value);
    if (endpoint.version) |value| try w.writeStringField("version", value);
    if (endpoint.adapter) |value| try w.writeStringField("adapter", value);
    try w.endObject();
}

pub fn serializeStringArray(w: *json_writer.JsonWriter, key: []const u8, values: []const []const u8) !void {
    try w.writeKey(key);
    try w.beginArray();
    for (values) |value| try w.writeString(value);
    try w.endArray();
}

fn serializePayload(w: *json_writer.JsonWriter, payload: oap_types.Payload) !void {
    try w.beginObject();
    switch (payload) {
        .capabilities_request => {},
        .initialize_request => |value| {
            try serializeStringArray(w, "protocol_versions", value.protocol_versions);
            try serializeStringArray(w, "profiles", value.profiles);
            if (value.participant) |participant| {
                try w.writeKey("participant");
                try w.beginObject();
                try w.writeStringField("id", participant.id);
                if (participant.name) |name| try w.writeStringField("name", name);
                if (participant.version) |version| try w.writeStringField("version", version);
                try w.endObject();
            }
        },
        .initialize_response => |value| {
            try w.writeStringField("protocol_version", value.protocol_version);
            try w.writeStringField("profile", value.profile);
            try w.writeKey("endpoint");
            try serializeEndpoint(w, value.endpoint);
        },
        .capabilities_response => |value| {
            try w.writeKey("endpoint");
            try serializeEndpoint(w, value.endpoint);
            if (value.protocol_versions.len > 0) {
                try serializeStringArray(w, "protocol_versions", value.protocol_versions);
            }
            if (value.profiles.len > 0) {
                try serializeStringArray(w, "profiles", value.profiles);
            }
            if (value.bindings.len > 0) {
                try w.writeKey("bindings");
                try w.beginArray();
                for (value.bindings) |binding| {
                    try w.beginObject();
                    try w.writeStringField("kind", binding.kind);
                    if (binding.serialization) |serialization| {
                        try w.writeStringField("serialization", serialization);
                    }
                    try w.endObject();
                }
                try w.endArray();
            }
            if (value.features.len > 0) {
                try w.writeKey("features");
                try w.beginObject();
                for (value.features) |feature| {
                    try w.writeKey(feature.key);
                    try w.beginObject();
                    try w.writeStringField("level", @tagName(feature.level));
                    if (feature.mode) |mode| try w.writeStringField("mode", mode);
                    if (feature.reason) |reason| try w.writeStringField("reason", reason);
                    try w.endObject();
                }
                try w.endObject();
            }
            if (value.requested_delivery_modes.len > 0 or value.effective_delivery_modes.len > 0) {
                try w.writeKey("layers");
                try w.beginObject();
                try w.writeKey("agent_loop");
                try w.beginObject();
                if (value.requested_delivery_modes.len > 0) {
                    try w.writeKey("requested_delivery_modes");
                    try w.beginArray();
                    for (value.requested_delivery_modes) |mode| try w.writeString(@tagName(mode));
                    try w.endArray();
                }
                if (value.effective_delivery_modes.len > 0) {
                    try w.writeKey("effective_delivery_modes");
                    try w.beginArray();
                    for (value.effective_delivery_modes) |mode| try w.writeString(@tagName(mode));
                    try w.endArray();
                }
                try w.endObject();
                try w.endObject();
            }
            if (value.degradation.len > 0) {
                try w.writeKey("degradation");
                try w.beginArray();
                for (value.degradation) |record| {
                    try w.beginObject();
                    try w.writeStringField("feature", record.feature);
                    if (record.from) |from| try w.writeStringField("from", @tagName(from));
                    try w.writeStringField("to", @tagName(record.to));
                    try w.writeStringField("reason", record.reason);
                    try w.endObject();
                }
                try w.endArray();
            }
        },
        .session_open_request => |value| {
            if (value.session_id) |session_id| try w.writeStringField("session_id", session_id);
        },
        .session_state_request => |value| {
            try w.writeStringField("session_id", value.session_id);
        },
        .session_open_response, .session_state_response, .session_state_updated => |value| {
            try serializeSessionState(w, value);
        },
        .message_submit_request => |value| {
            try w.writeStringField("session_id", value.session_id);
            try w.writeKey("messages");
            try w.beginArray();
            for (value.messages) |message| try serializeMessage(w, message);
            try w.endArray();
            try w.writeStringField("delivery", @tagName(value.delivery));
            if (value.model_id) |model_id| try w.writeStringField("model_id", model_id);
            if (value.instructions) |instructions| try w.writeStringField("instructions", instructions);
            if (value.tool_choice_json) |tool_choice| {
                try w.writeKey("tool_choice");
                try writeJsonValueOrString(w, tool_choice);
            }
            if (value.output_schema_json) |output_schema| {
                try w.writeKey("output_schema");
                try writeJsonValueOrString(w, output_schema);
            }
            if (value.allow_degraded_features.len > 0) {
                try serializeStringArray(w, "allow_degraded_features", value.allow_degraded_features);
            }
        },
        .message_submit_response => |value| {
            try w.writeStringField("session_id", value.session_id);
            try w.writeBoolField("accepted", value.accepted);
            try w.writeStringField("submission_id", value.submission_id);
            try w.writeStringField("requested_delivery", @tagName(value.requested_delivery));
            try w.writeStringField("effective_delivery", @tagName(value.effective_delivery));
            if (value.delivery_resolution) |resolution| {
                try w.writeStringField("delivery_resolution", resolution);
            }
            try w.writeStringField("admission", @tagName(value.admission));
            if (value.run_id) |run_id| try w.writeStringField("run_id", run_id);
            if (value.status) |status| try w.writeStringField("status", @tagName(status));
            if (value.model_id) |model_id| try w.writeStringField("model_id", model_id);
        },
        .run_cancel_request => |value| {
            try w.writeStringField("session_id", value.session_id);
            try w.writeStringField("run_id", value.run_id);
            if (value.reason) |reason| try w.writeStringField("reason", reason);
        },
        .run_cancel_response => |value| {
            try w.writeStringField("session_id", value.session_id);
            try w.writeStringField("run_id", value.run_id);
            try w.writeBoolField("accepted", value.accepted);
            try w.writeStringField("status", @tagName(value.status));
        },
        .run_started => |value| {
            try w.writeStringField("session_id", value.session_id);
            try w.writeStringField("run_id", value.run_id);
            try w.writeStringField("status", "running");
            if (value.model_id) |model_id| try w.writeStringField("model_id", model_id);
            if (value.started_at_ms) |started| try w.writeIntField("started_at_ms", started);
        },
        .run_status_updated => |value| {
            try w.writeStringField("session_id", value.session_id);
            try w.writeStringField("run_id", value.run_id);
            try w.writeStringField("status", @tagName(value.status));
            if (value.updated_at_ms) |updated| try w.writeIntField("updated_at_ms", updated);
        },
        .content_delta => |value| {
            try w.writeStringField("session_id", value.session_id);
            try w.writeStringField("run_id", value.run_id);
            if (value.message_id) |message_id| try w.writeStringField("message_id", message_id);
            try w.writeKey("part");
            try serializeContentPart(w, value.part);
        },
        .run_completed => |value| {
            try w.writeStringField("session_id", value.session_id);
            try w.writeStringField("run_id", value.run_id);
            try w.writeKey("final_response");
            try serializeMessage(w, value.final_response);
            try w.writeStringField("stop_reason", value.stop_reason);
            if (value.model_id) |model_id| try w.writeStringField("model_id", model_id);
            if (!value.usage.isEmpty()) try serializeUsage(w, value.usage);
            if (value.duration_ms) |duration| try w.writeIntField("duration_ms", duration);
        },
        .run_failed => |value| {
            try w.writeStringField("session_id", value.session_id);
            try w.writeStringField("run_id", value.run_id);
            try w.writeKey("error");
            try serializeProtocolError(w, value.err);
            if (!value.usage.isEmpty()) try serializeUsage(w, value.usage);
            if (value.duration_ms) |duration| try w.writeIntField("duration_ms", duration);
        },
        .run_cancelled => |value| {
            try w.writeStringField("session_id", value.session_id);
            try w.writeStringField("run_id", value.run_id);
            if (value.reason) |reason| try w.writeStringField("reason", reason);
            if (!value.usage.isEmpty()) try serializeUsage(w, value.usage);
            if (value.duration_ms) |duration| try w.writeIntField("duration_ms", duration);
        },
        .error_response => |value| {
            try w.writeKey("error");
            try serializeProtocolError(w, value);
        },
    }
    try w.endObject();
}

pub fn deserializeEnvelope(line: []const u8, allocator: std.mem.Allocator) !oap_types.Envelope {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        return DecodeError.InvalidEnvelope;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return DecodeError.InvalidEnvelope;
    const root = parsed.value.object;

    const protocol = try requiredString(root, "protocol");
    if (!std.mem.eql(u8, protocol, oap_types.PROTOCOL)) return DecodeError.ProtocolMismatch;
    const version = try requiredString(root, "version");
    if (!std.mem.eql(u8, version, oap_types.VERSION)) return DecodeError.VersionMismatch;
    const profile = try requiredString(root, "profile");
    if (!std.mem.eql(u8, profile, oap_types.PROFILE)) return DecodeError.ProfileMismatch;

    const type_str = try requiredString(root, "type");
    const id_str = try requiredString(root, "id");
    if (id_str.len == 0) return DecodeError.InvalidField;

    const payload_value = root.get("payload") orelse return DecodeError.MissingField;
    if (payload_value != .object) return DecodeError.InvalidField;

    var sequence: ?u64 = null;
    if (root.get("sequence")) |value| {
        if (value != .integer or value.integer < 1) return DecodeError.InvalidField;
        sequence = @intCast(value.integer);
    }
    var timestamp_ms: ?i64 = null;
    if (root.get("timestamp_ms")) |value| {
        if (value != .integer) return DecodeError.InvalidField;
        timestamp_ms = value.integer;
    }

    const in_reply_to = try optionalOwnedString(root, "in_reply_to", allocator);
    errdefer if (in_reply_to) |owned| allocator.free(owned);
    const session_id = try optionalOwnedString(root, "session_id", allocator);
    errdefer if (session_id) |owned| allocator.free(owned);
    const run_id = try optionalOwnedString(root, "run_id", allocator);
    errdefer if (run_id) |owned| allocator.free(owned);
    const turn_id = try optionalOwnedString(root, "turn_id", allocator);
    errdefer if (turn_id) |owned| allocator.free(owned);
    const tool_call_id = try optionalOwnedString(root, "tool_call_id", allocator);
    errdefer if (tool_call_id) |owned| allocator.free(owned);
    const capability_revision = try optionalOwnedString(root, "capability_revision", allocator);
    errdefer if (capability_revision) |owned| allocator.free(owned);

    const id = try allocator.dupe(u8, id_str);
    errdefer allocator.free(id);

    const payload = try deserializePayload(type_str, payload_value.object, allocator);

    return .{
        .id = id,
        .payload = payload,
        .sequence = sequence,
        .timestamp_ms = timestamp_ms,
        .in_reply_to = in_reply_to,
        .session_id = session_id,
        .run_id = run_id,
        .turn_id = turn_id,
        .tool_call_id = tool_call_id,
        .capability_revision = capability_revision,
    };
}

pub fn requiredString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = obj.get(key) orelse return DecodeError.MissingField;
    if (value != .string) return DecodeError.InvalidField;
    return value.string;
}

pub fn requiredOwnedString(obj: std.json.ObjectMap, key: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const value = try requiredString(obj, key);
    if (value.len == 0) return DecodeError.InvalidField;
    return allocator.dupe(u8, value);
}

pub fn optionalOwnedString(obj: std.json.ObjectMap, key: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return DecodeError.InvalidField;
    if (value.string.len == 0) return DecodeError.InvalidField;
    return try allocator.dupe(u8, value.string);
}

pub fn optionalBool(obj: std.json.ObjectMap, key: []const u8) !?bool {
    const value = obj.get(key) orelse return null;
    if (value != .bool) return DecodeError.InvalidField;
    return value.bool;
}

pub fn requiredBool(obj: std.json.ObjectMap, key: []const u8) !bool {
    return (try optionalBool(obj, key)) orelse DecodeError.MissingField;
}

pub fn optionalUnsigned(obj: std.json.ObjectMap, key: []const u8) !?u64 {
    const value = obj.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return DecodeError.InvalidField;
    return @intCast(value.integer);
}

pub fn optionalInteger(obj: std.json.ObjectMap, key: []const u8) !?i64 {
    const value = obj.get(key) orelse return null;
    if (value != .integer) return DecodeError.InvalidField;
    return value.integer;
}

pub fn requiredEnum(comptime T: type, obj: std.json.ObjectMap, key: []const u8) !T {
    const value = try requiredString(obj, key);
    return std.meta.stringToEnum(T, value) orelse DecodeError.InvalidField;
}

pub fn optionalEnum(comptime T: type, obj: std.json.ObjectMap, key: []const u8) !?T {
    const value = obj.get(key) orelse return null;
    if (value != .string) return DecodeError.InvalidField;
    return std.meta.stringToEnum(T, value.string) orelse DecodeError.InvalidField;
}

pub fn decodeEnumList(
    comptime T: type,
    obj: std.json.ObjectMap,
    key: []const u8,
    allocator: std.mem.Allocator,
) ![]const T {
    const value = obj.get(key) orelse return &.{};
    if (value != .array) return DecodeError.InvalidField;
    const decoded = try allocator.alloc(T, value.array.items.len);
    errdefer allocator.free(decoded);
    for (value.array.items, 0..) |item, index| {
        if (item != .string) return DecodeError.InvalidField;
        decoded[index] = std.meta.stringToEnum(T, item.string) orelse return DecodeError.InvalidField;
    }
    return decoded;
}

pub fn ownedRawJson(value: std.json.Value, allocator: std.mem.Allocator) ![]const u8 {
    if (value == .string) return allocator.dupe(u8, value.string);
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub fn optionalRawJson(obj: std.json.ObjectMap, key: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const value = obj.get(key) orelse return null;
    return try ownedRawJson(value, allocator);
}

pub fn deserializeUsage(obj: std.json.ObjectMap) !oap_types.Usage {
    const value = obj.get("usage") orelse return .{};
    if (value != .object) return DecodeError.InvalidField;
    return .{
        .input_tokens = try optionalUnsigned(value.object, "input_tokens"),
        .output_tokens = try optionalUnsigned(value.object, "output_tokens"),
        .total_tokens = try optionalUnsigned(value.object, "total_tokens"),
    };
}

pub fn deserializeContentPart(value: std.json.Value, allocator: std.mem.Allocator) !oap_types.ContentPart {
    if (value != .object) return DecodeError.InvalidField;
    const obj = value.object;
    const part_type = try requiredString(obj, "type");

    if (obj.get("carry") != null and
        !std.mem.eql(u8, part_type, "reasoning") and
        !std.mem.eql(u8, part_type, "tool_call"))
    {
        return DecodeError.InvalidField;
    }

    if (std.mem.eql(u8, part_type, "text")) {
        const text = try requiredString(obj, "text");
        return .{ .text = try allocator.dupe(u8, text) };
    }
    if (std.mem.eql(u8, part_type, "reasoning")) {
        const reasoning = try requiredString(obj, "reasoning");
        const text = try allocator.dupe(u8, reasoning);
        errdefer allocator.free(text);
        const carry = try optionalOwnedString(obj, "carry", allocator);
        return .{ .reasoning = .{ .text = text, .carry = carry } };
    }
    if (std.mem.eql(u8, part_type, "tool_call")) {
        const tool_call_id = try requiredOwnedString(obj, "tool_call_id", allocator);
        errdefer allocator.free(tool_call_id);
        const name = try requiredOwnedString(obj, "name", allocator);
        errdefer allocator.free(name);
        const arguments = obj.get("arguments_json") orelse return DecodeError.MissingField;
        const arguments_json = try ownedRawJson(arguments, allocator);
        errdefer allocator.free(arguments_json);
        const carry = try optionalOwnedString(obj, "carry", allocator);
        return .{ .tool_call = .{
            .tool_call_id = tool_call_id,
            .name = name,
            .arguments_json = arguments_json,
            .carry = carry,
        } };
    }
    if (std.mem.eql(u8, part_type, "tool_result")) {
        const tool_call_id = try requiredOwnedString(obj, "tool_call_id", allocator);
        errdefer allocator.free(tool_call_id);
        const result = obj.get("result") orelse return DecodeError.MissingField;
        const result_json = try ownedRawJson(result, allocator);
        errdefer allocator.free(result_json);
        return .{ .tool_result = .{
            .tool_call_id = tool_call_id,
            .result_json = result_json,
            .is_error = try optionalBool(obj, "is_error"),
        } };
    }
    return DecodeError.InvalidField;
}

pub fn deserializeContent(value: std.json.Value, allocator: std.mem.Allocator) !oap_types.Content {
    switch (value) {
        .string => |text| return .{ .text = try allocator.dupe(u8, text) },
        .array => |array| {
            if (array.items.len == 0) return DecodeError.InvalidField;
            const parts = try allocator.alloc(oap_types.ContentPart, array.items.len);
            var filled: usize = 0;
            errdefer {
                for (parts[0..filled]) |*part| part.deinit(allocator);
                allocator.free(parts);
            }
            for (array.items, 0..) |item, index| {
                parts[index] = try deserializeContentPart(item, allocator);
                filled = index + 1;
            }
            return .{ .parts = parts };
        },
        else => return DecodeError.InvalidField,
    }
}

pub fn deserializeMessage(value: std.json.Value, allocator: std.mem.Allocator) !oap_types.Message {
    if (value != .object) return DecodeError.InvalidField;
    const obj = value.object;
    const id = try optionalOwnedString(obj, "id", allocator);
    errdefer if (id) |owned| allocator.free(owned);
    const role = try requiredEnum(oap_types.Role, obj, "role");
    const content_value = obj.get("content") orelse return DecodeError.MissingField;
    const content = try deserializeContent(content_value, allocator);
    return .{ .id = id, .role = role, .content = content };
}

fn deserializeProtocolError(value: std.json.Value, allocator: std.mem.Allocator) !oap_types.ProtocolError {
    if (value != .object) return DecodeError.InvalidField;
    const obj = value.object;
    const code = try requiredEnum(oap_types.ErrorCode, obj, "code");
    const message = try requiredOwnedString(obj, "message", allocator);
    errdefer allocator.free(message);
    const retriable = try optionalBool(obj, "retriable");

    var details: []const oap_types.DetailEntry = &.{};
    if (obj.get("details")) |details_value| {
        if (details_value != .object) return DecodeError.InvalidField;
        const entries = try allocator.alloc(oap_types.DetailEntry, details_value.object.count());
        var filled: usize = 0;
        errdefer {
            for (entries[0..filled]) |entry| {
                allocator.free(entry.key);
                allocator.free(entry.value);
            }
            allocator.free(entries);
        }
        var iterator = details_value.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* != .string) return DecodeError.InvalidField;
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            const detail_value = try allocator.dupe(u8, entry.value_ptr.string);
            entries[filled] = .{ .key = key, .value = detail_value };
            filled += 1;
        }
        details = entries;
    }

    return .{ .code = code, .message = message, .retriable = retriable, .details = details };
}

fn deserializeSessionState(obj: std.json.ObjectMap, allocator: std.mem.Allocator) !oap_types.SessionState {
    const session_id = try requiredOwnedString(obj, "session_id", allocator);
    errdefer allocator.free(session_id);
    const status = try requiredEnum(oap_types.SessionStatus, obj, "status");
    const active_run_id = try optionalOwnedString(obj, "active_run_id", allocator);
    errdefer if (active_run_id) |owned| allocator.free(owned);
    const current_model_id = try optionalOwnedString(obj, "current_model_id", allocator);
    errdefer if (current_model_id) |owned| allocator.free(owned);
    const updated_at_ms = try optionalInteger(obj, "updated_at_ms");
    return .{
        .session_id = session_id,
        .status = status,
        .active_run_id = active_run_id,
        .current_model_id = current_model_id,
        .updated_at_ms = updated_at_ms,
    };
}

fn deserializeEndpoint(value: std.json.Value, allocator: std.mem.Allocator) !oap_types.Endpoint {
    if (value != .object) return DecodeError.InvalidField;
    const obj = value.object;
    const id = try requiredOwnedString(obj, "id", allocator);
    errdefer allocator.free(id);
    const name = try optionalOwnedString(obj, "name", allocator);
    errdefer if (name) |owned| allocator.free(owned);
    const version = try optionalOwnedString(obj, "version", allocator);
    errdefer if (version) |owned| allocator.free(owned);
    const adapter = try optionalOwnedString(obj, "adapter", allocator);
    return .{ .id = id, .name = name, .version = version, .adapter = adapter };
}

pub fn deserializeStringArray(obj: std.json.ObjectMap, key: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    const value = obj.get(key) orelse return DecodeError.MissingField;
    if (value != .array) return DecodeError.InvalidField;
    const out = try allocator.alloc([]const u8, value.array.items.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |entry| allocator.free(entry);
        allocator.free(out);
    }
    for (value.array.items, 0..) |item, index| {
        if (item != .string) return DecodeError.InvalidField;
        out[index] = try allocator.dupe(u8, item.string);
        filled = index + 1;
    }
    return out;
}

fn deserializePayload(
    type_str: []const u8,
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !oap_types.Payload {
    if (std.mem.eql(u8, type_str, "capabilities.request")) {
        return .{ .capabilities_request = {} };
    }
    if (std.mem.eql(u8, type_str, "protocol.initialize.request")) {
        const protocol_versions = try deserializeStringArray(obj, "protocol_versions", allocator);
        errdefer oap_types.freeStringList(allocator, protocol_versions);
        const profiles = try deserializeStringArray(obj, "profiles", allocator);
        errdefer oap_types.freeStringList(allocator, profiles);
        if (protocol_versions.len == 0 or profiles.len == 0) return DecodeError.InvalidField;

        var participant: ?oap_types.Participant = null;
        if (obj.get("participant")) |value| {
            if (value != .object) return DecodeError.InvalidField;
            const id = try requiredOwnedString(value.object, "id", allocator);
            errdefer allocator.free(id);
            const name = try optionalOwnedString(value.object, "name", allocator);
            errdefer if (name) |owned| allocator.free(owned);
            const version = try optionalOwnedString(value.object, "version", allocator);
            participant = .{ .id = id, .name = name, .version = version };
        }
        return .{ .initialize_request = .{
            .protocol_versions = protocol_versions,
            .profiles = profiles,
            .participant = participant,
        } };
    }
    if (std.mem.eql(u8, type_str, "protocol.initialize.response")) {
        const protocol_version = try requiredOwnedString(obj, "protocol_version", allocator);
        errdefer allocator.free(protocol_version);
        const profile = try requiredOwnedString(obj, "profile", allocator);
        errdefer allocator.free(profile);
        const endpoint_value = obj.get("endpoint") orelse return DecodeError.MissingField;
        const endpoint = try deserializeEndpoint(endpoint_value, allocator);
        return .{ .initialize_response = .{
            .protocol_version = protocol_version,
            .profile = profile,
            .endpoint = endpoint,
        } };
    }
    if (std.mem.eql(u8, type_str, "capabilities.response")) {
        return .{ .capabilities_response = try deserializeCapabilities(obj, allocator) };
    }
    if (std.mem.eql(u8, type_str, "session.open.request")) {
        return .{ .session_open_request = .{
            .session_id = try optionalOwnedString(obj, "session_id", allocator),
        } };
    }
    if (std.mem.eql(u8, type_str, "session.state.request")) {
        return .{ .session_state_request = .{
            .session_id = try requiredOwnedString(obj, "session_id", allocator),
        } };
    }
    if (std.mem.eql(u8, type_str, "session.open.response")) {
        return .{ .session_open_response = try deserializeSessionState(obj, allocator) };
    }
    if (std.mem.eql(u8, type_str, "session.state.response")) {
        return .{ .session_state_response = try deserializeSessionState(obj, allocator) };
    }
    if (std.mem.eql(u8, type_str, "session.state.updated")) {
        return .{ .session_state_updated = try deserializeSessionState(obj, allocator) };
    }
    if (std.mem.eql(u8, type_str, "session.message.submit.request")) {
        return .{ .message_submit_request = try deserializeSubmitRequest(obj, allocator) };
    }
    if (std.mem.eql(u8, type_str, "session.message.submit.response")) {
        const session_id = try requiredOwnedString(obj, "session_id", allocator);
        errdefer allocator.free(session_id);
        const submission_id = try requiredOwnedString(obj, "submission_id", allocator);
        errdefer allocator.free(submission_id);
        const delivery_resolution = try optionalOwnedString(obj, "delivery_resolution", allocator);
        errdefer if (delivery_resolution) |owned| allocator.free(owned);
        const run_id = try optionalOwnedString(obj, "run_id", allocator);
        errdefer if (run_id) |owned| allocator.free(owned);
        const model_id = try optionalOwnedString(obj, "model_id", allocator);
        errdefer if (model_id) |owned| allocator.free(owned);
        const accepted = try requiredBool(obj, "accepted");
        const requested_delivery = try requiredEnum(oap_types.RequestedDelivery, obj, "requested_delivery");
        const effective_delivery = try requiredEnum(oap_types.EffectiveDelivery, obj, "effective_delivery");
        const admission = try requiredEnum(oap_types.Admission, obj, "admission");
        const status = try optionalEnum(oap_types.RunStatus, obj, "status");
        return .{ .message_submit_response = .{
            .session_id = session_id,
            .accepted = accepted,
            .submission_id = submission_id,
            .requested_delivery = requested_delivery,
            .effective_delivery = effective_delivery,
            .delivery_resolution = delivery_resolution,
            .admission = admission,
            .run_id = run_id,
            .status = status,
            .model_id = model_id,
        } };
    }
    if (std.mem.eql(u8, type_str, "run.cancel.request")) {
        const session_id = try requiredOwnedString(obj, "session_id", allocator);
        errdefer allocator.free(session_id);
        const run_id = try requiredOwnedString(obj, "run_id", allocator);
        errdefer allocator.free(run_id);
        return .{ .run_cancel_request = .{
            .session_id = session_id,
            .run_id = run_id,
            .reason = try optionalOwnedString(obj, "reason", allocator),
        } };
    }
    if (std.mem.eql(u8, type_str, "run.cancel.response")) {
        const session_id = try requiredOwnedString(obj, "session_id", allocator);
        errdefer allocator.free(session_id);
        const run_id = try requiredOwnedString(obj, "run_id", allocator);
        errdefer allocator.free(run_id);
        const accepted = try requiredBool(obj, "accepted");
        const status = try requiredEnum(oap_types.RunStatus, obj, "status");
        return .{ .run_cancel_response = .{
            .session_id = session_id,
            .run_id = run_id,
            .accepted = accepted,
            .status = status,
        } };
    }
    if (std.mem.eql(u8, type_str, "run.started")) {
        const session_id = try requiredOwnedString(obj, "session_id", allocator);
        errdefer allocator.free(session_id);
        const run_id = try requiredOwnedString(obj, "run_id", allocator);
        errdefer allocator.free(run_id);
        const model_id = try optionalOwnedString(obj, "model_id", allocator);
        errdefer if (model_id) |owned| allocator.free(owned);
        const started_at_ms = try optionalInteger(obj, "started_at_ms");
        return .{ .run_started = .{
            .session_id = session_id,
            .run_id = run_id,
            .model_id = model_id,
            .started_at_ms = started_at_ms,
        } };
    }
    if (std.mem.eql(u8, type_str, "run.status.updated")) {
        const session_id = try requiredOwnedString(obj, "session_id", allocator);
        errdefer allocator.free(session_id);
        const run_id = try requiredOwnedString(obj, "run_id", allocator);
        errdefer allocator.free(run_id);
        const status = try requiredEnum(oap_types.RunStatus, obj, "status");
        const updated_at_ms = try optionalInteger(obj, "updated_at_ms");
        return .{ .run_status_updated = .{
            .session_id = session_id,
            .run_id = run_id,
            .status = status,
            .updated_at_ms = updated_at_ms,
        } };
    }
    if (std.mem.eql(u8, type_str, "content.delta")) {
        const session_id = try requiredOwnedString(obj, "session_id", allocator);
        errdefer allocator.free(session_id);
        const run_id = try requiredOwnedString(obj, "run_id", allocator);
        errdefer allocator.free(run_id);
        const message_id = try optionalOwnedString(obj, "message_id", allocator);
        errdefer if (message_id) |owned| allocator.free(owned);
        const part_value = obj.get("part") orelse return DecodeError.MissingField;
        const part = try deserializeContentPart(part_value, allocator);
        return .{ .content_delta = .{
            .session_id = session_id,
            .run_id = run_id,
            .message_id = message_id,
            .part = part,
        } };
    }
    if (std.mem.eql(u8, type_str, "run.completed")) {
        const session_id = try requiredOwnedString(obj, "session_id", allocator);
        errdefer allocator.free(session_id);
        const run_id = try requiredOwnedString(obj, "run_id", allocator);
        errdefer allocator.free(run_id);
        const final_value = obj.get("final_response") orelse return DecodeError.MissingField;
        var final_response = try deserializeMessage(final_value, allocator);
        errdefer final_response.deinit(allocator);
        const stop_reason = try requiredOwnedString(obj, "stop_reason", allocator);
        errdefer allocator.free(stop_reason);
        const model_id = try optionalOwnedString(obj, "model_id", allocator);
        errdefer if (model_id) |owned| allocator.free(owned);
        const usage = try deserializeUsage(obj);
        const duration_ms = try optionalUnsigned(obj, "duration_ms");
        return .{ .run_completed = .{
            .session_id = session_id,
            .run_id = run_id,
            .final_response = final_response,
            .stop_reason = stop_reason,
            .model_id = model_id,
            .usage = usage,
            .duration_ms = duration_ms,
        } };
    }
    if (std.mem.eql(u8, type_str, "run.failed")) {
        const session_id = try requiredOwnedString(obj, "session_id", allocator);
        errdefer allocator.free(session_id);
        const run_id = try requiredOwnedString(obj, "run_id", allocator);
        errdefer allocator.free(run_id);
        const error_value = obj.get("error") orelse return DecodeError.MissingField;
        var err = try deserializeProtocolError(error_value, allocator);
        errdefer err.deinit(allocator);
        const usage = try deserializeUsage(obj);
        const duration_ms = try optionalUnsigned(obj, "duration_ms");
        return .{ .run_failed = .{
            .session_id = session_id,
            .run_id = run_id,
            .err = err,
            .usage = usage,
            .duration_ms = duration_ms,
        } };
    }
    if (std.mem.eql(u8, type_str, "run.cancelled")) {
        const session_id = try requiredOwnedString(obj, "session_id", allocator);
        errdefer allocator.free(session_id);
        const run_id = try requiredOwnedString(obj, "run_id", allocator);
        errdefer allocator.free(run_id);
        const reason = try optionalOwnedString(obj, "reason", allocator);
        errdefer if (reason) |owned| allocator.free(owned);
        const usage = try deserializeUsage(obj);
        const duration_ms = try optionalUnsigned(obj, "duration_ms");
        return .{ .run_cancelled = .{
            .session_id = session_id,
            .run_id = run_id,
            .reason = reason,
            .usage = usage,
            .duration_ms = duration_ms,
        } };
    }
    if (std.mem.eql(u8, type_str, "error.response")) {
        const error_value = obj.get("error") orelse return DecodeError.MissingField;
        return .{ .error_response = try deserializeProtocolError(error_value, allocator) };
    }

    return DecodeError.UnknownEnvelopeType;
}

fn deserializeSubmitRequest(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !oap_types.MessageSubmitRequest {
    const session_id = try requiredOwnedString(obj, "session_id", allocator);
    errdefer allocator.free(session_id);

    const messages_value = obj.get("messages") orelse return DecodeError.MissingField;
    if (messages_value != .array or messages_value.array.items.len == 0) return DecodeError.InvalidField;
    const messages = try allocator.alloc(oap_types.Message, messages_value.array.items.len);
    var filled: usize = 0;
    errdefer {
        for (messages[0..filled]) |*message| message.deinit(allocator);
        allocator.free(messages);
    }
    for (messages_value.array.items, 0..) |item, index| {
        messages[index] = try deserializeMessage(item, allocator);
        filled = index + 1;
    }

    const delivery = try requiredEnum(oap_types.RequestedDelivery, obj, "delivery");

    const model_id = if (obj.get("model_id")) |value| blk: {
        if (value != .string) return DecodeError.InvalidField;
        break :blk try allocator.dupe(u8, value.string);
    } else null;
    errdefer if (model_id) |owned| allocator.free(owned);

    const instructions = if (obj.get("instructions")) |value| blk: {
        if (value != .string) return DecodeError.InvalidField;
        break :blk try allocator.dupe(u8, value.string);
    } else null;
    errdefer if (instructions) |owned| allocator.free(owned);

    const tool_choice_json = try optionalRawJson(obj, "tool_choice", allocator);
    errdefer if (tool_choice_json) |owned| allocator.free(owned);
    const output_schema_json = try optionalRawJson(obj, "output_schema", allocator);
    errdefer if (output_schema_json) |owned| allocator.free(owned);

    var allow_degraded: []const []const u8 = &.{};
    if (obj.get("allow_degraded_features") != null) {
        allow_degraded = try deserializeStringArray(obj, "allow_degraded_features", allocator);
    }

    return .{
        .session_id = session_id,
        .messages = messages,
        .delivery = delivery,
        .model_id = model_id,
        .instructions = instructions,
        .tool_choice_json = tool_choice_json,
        .output_schema_json = output_schema_json,
        .allow_degraded_features = allow_degraded,
    };
}

fn deserializeCapabilities(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !oap_types.CapabilitiesResponse {
    const endpoint_value = obj.get("endpoint") orelse return DecodeError.MissingField;
    const endpoint = try deserializeEndpoint(endpoint_value, allocator);

    var result = oap_types.CapabilitiesResponse{ .endpoint = endpoint };
    errdefer result.deinit(allocator);

    if (obj.get("protocol_versions") != null) {
        result.protocol_versions = try deserializeStringArray(obj, "protocol_versions", allocator);
    }
    if (obj.get("profiles") != null) {
        result.profiles = try deserializeStringArray(obj, "profiles", allocator);
    }
    if (obj.get("bindings")) |value| {
        if (value != .array) return DecodeError.InvalidField;
        const bindings = try allocator.alloc(oap_types.Binding, value.array.items.len);
        var filled: usize = 0;
        errdefer {
            for (bindings[0..filled]) |*binding| binding.deinit(allocator);
            allocator.free(bindings);
        }
        for (value.array.items, 0..) |item, index| {
            if (item != .object) return DecodeError.InvalidField;
            const kind = try requiredOwnedString(item.object, "kind", allocator);
            errdefer allocator.free(kind);
            const serialization = try optionalOwnedString(item.object, "serialization", allocator);
            bindings[index] = .{ .kind = kind, .serialization = serialization };
            filled = index + 1;
        }
        result.bindings = bindings;
    }
    if (obj.get("features")) |value| {
        if (value != .object) return DecodeError.InvalidField;
        const features = try allocator.alloc(oap_types.Feature, value.object.count());
        var filled: usize = 0;
        errdefer {
            for (features[0..filled]) |*entry| entry.deinit(allocator);
            allocator.free(features);
        }
        var iterator = value.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* != .object) return DecodeError.InvalidField;
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            const level = try requiredEnum(oap_types.SupportLevel, entry.value_ptr.object, "level");
            const mode = try optionalOwnedString(entry.value_ptr.object, "mode", allocator);
            errdefer if (mode) |owned| allocator.free(owned);
            const reason = try optionalOwnedString(entry.value_ptr.object, "reason", allocator);
            features[filled] = .{ .key = key, .level = level, .mode = mode, .reason = reason };
            filled += 1;
        }
        result.features = features;
    }
    if (obj.get("layers")) |layers| {
        if (layers != .object) return DecodeError.InvalidField;
        if (layers.object.get("agent_loop")) |agent_loop| {
            if (agent_loop != .object) return DecodeError.InvalidField;
            result.requested_delivery_modes = try decodeEnumList(
                oap_types.RequestedDelivery,
                agent_loop.object,
                "requested_delivery_modes",
                allocator,
            );
            result.effective_delivery_modes = try decodeEnumList(
                oap_types.EffectiveDelivery,
                agent_loop.object,
                "effective_delivery_modes",
                allocator,
            );
        }
    }
    if (obj.get("degradation")) |value| {
        if (value != .array) return DecodeError.InvalidField;
        const records = try allocator.alloc(oap_types.Degradation, value.array.items.len);
        var filled: usize = 0;
        errdefer {
            for (records[0..filled]) |*record| record.deinit(allocator);
            allocator.free(records);
        }
        for (value.array.items, 0..) |item, index| {
            if (item != .object) return DecodeError.InvalidField;
            const feature = try requiredOwnedString(item.object, "feature", allocator);
            errdefer allocator.free(feature);
            const reason = try requiredOwnedString(item.object, "reason", allocator);
            errdefer allocator.free(reason);
            const from = try optionalEnum(oap_types.SupportLevel, item.object, "from");
            const to = try requiredEnum(oap_types.SupportLevel, item.object, "to");
            records[index] = .{
                .feature = feature,
                .from = from,
                .to = to,
                .reason = reason,
            };
            filled = index + 1;
        }
        result.degradation = records;
    }

    return result;
}

test "a carry on a content part kind that cannot hold one is refused rather than ignored" {
    const allocator = std.testing.allocator;

    const refused = [_][]const u8{
        "{\"type\":\"text\",\"text\":\"spoken\",\"carry\":\"sig\"}",
        "{\"type\":\"tool_result\",\"tool_call_id\":\"c1\",\"result\":\"ok\",\"carry\":\"sig\"}",
        "{\"type\":\"reasoning\",\"reasoning\":\"prior\",\"carry\":\"\"}",
        "{\"type\":\"tool_call\",\"tool_call_id\":\"c1\",\"name\":\"s\",\"arguments_json\":\"{}\",\"carry\":\"\"}",
    };
    for (refused) |raw| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        try std.testing.expectError(DecodeError.InvalidField, deserializeContentPart(parsed.value, allocator));
    }

    const accepted = "{\"type\":\"reasoning\",\"reasoning\":\"prior\",\"carry\":\"sig\"}";
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, accepted, .{});
    defer parsed.deinit();
    var part = try deserializeContentPart(parsed.value, allocator);
    defer part.deinit(allocator);
    try std.testing.expectEqualStrings("sig", part.reasoning.carry orelse "");
}

test "round trips a message submit request" {
    const allocator = std.testing.allocator;

    var parts = [_]oap_types.ContentPart{.{ .text = "hello" }};
    var messages = [_]oap_types.Message{.{
        .role = .user,
        .content = .{ .parts = &parts },
    }};
    const request = oap_types.Envelope{
        .id = "req-1",
        .session_id = "sess-1",
        .payload = .{ .message_submit_request = .{
            .session_id = "sess-1",
            .messages = &messages,
            .delivery = .auto,
            .model_id = "anthropic/anthropic-messages@claude",
        } },
    };

    const line = try serializeEnvelope(request, allocator);
    defer allocator.free(line);

    var decoded = try deserializeEnvelope(line, allocator);
    defer decoded.deinit(allocator);

    try std.testing.expectEqualStrings("req-1", decoded.id);
    try std.testing.expectEqualStrings("sess-1", decoded.session_id.?);
    const submit = decoded.payload.message_submit_request;
    try std.testing.expectEqual(oap_types.RequestedDelivery.auto, submit.delivery);
    try std.testing.expectEqual(@as(usize, 1), submit.messages.len);
    try std.testing.expectEqual(oap_types.Role.user, submit.messages[0].role);
    try std.testing.expectEqualStrings("hello", submit.messages[0].content.parts[0].text);
    try std.testing.expectEqualStrings("anthropic/anthropic-messages@claude", submit.model_id.?);
}

test "round trips a run completed terminal with usage" {
    const allocator = std.testing.allocator;

    const completed = oap_types.Envelope{
        .id = "ev-1",
        .session_id = "sess-1",
        .run_id = "run-1",
        .sequence = 4,
        .payload = .{ .run_completed = .{
            .session_id = "sess-1",
            .run_id = "run-1",
            .final_response = .{ .role = .assistant, .content = .{ .text = "done" } },
            .stop_reason = "end_turn",
            .usage = .{ .input_tokens = 12, .output_tokens = 5, .total_tokens = 17 },
            .duration_ms = 42,
        } },
    };

    const line = try serializeEnvelope(completed, allocator);
    defer allocator.free(line);

    var decoded = try deserializeEnvelope(line, allocator);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 4), decoded.sequence.?);
    const payload = decoded.payload.run_completed;
    try std.testing.expectEqualStrings("end_turn", payload.stop_reason);
    try std.testing.expectEqualStrings("done", payload.final_response.content.text);
    try std.testing.expectEqual(@as(u64, 17), payload.usage.total_tokens.?);
    try std.testing.expectEqual(@as(u64, 42), payload.duration_ms.?);
}

test "round trips a typed error response with details" {
    const allocator = std.testing.allocator;

    const envelope = oap_types.Envelope{
        .id = "err-1",
        .in_reply_to = "req-9",
        .payload = .{ .error_response = .{
            .code = .unsupported_feature,
            .message = "run.instructions is not advertised",
            .retriable = false,
            .details = &.{
                .{ .key = "feature", .value = "run.instructions" },
                .{ .key = "reason", .value = "unadvertised" },
            },
        } },
    };

    const line = try serializeEnvelope(envelope, allocator);
    defer allocator.free(line);

    var decoded = try deserializeEnvelope(line, allocator);
    defer decoded.deinit(allocator);

    try std.testing.expectEqualStrings("req-9", decoded.in_reply_to.?);
    const err = decoded.payload.error_response;
    try std.testing.expectEqual(oap_types.ErrorCode.unsupported_feature, err.code);
    try std.testing.expectEqual(false, err.retriable.?);
    try std.testing.expectEqualStrings("run.instructions", err.detail("feature").?);
    try std.testing.expectEqualStrings("unadvertised", err.detail("reason").?);
}

test "round trips a capabilities response with features and degradation" {
    const allocator = std.testing.allocator;

    var bindings = [_]oap_types.Binding{.{ .kind = "stdio", .serialization = "jsonl" }};
    var features = [_]oap_types.Feature{
        .{ .key = "run.cancel", .level = .degraded, .reason = "session scoped" },
        .{ .key = "run.model_selection", .level = .native, .mode = "per_run" },
    };
    var degradation = [_]oap_types.Degradation{.{
        .feature = "run.cancel",
        .from = .native,
        .to = .degraded,
        .reason = "cancellation tears the session down",
    }};
    const versions = [_][]const u8{"0.1"};
    const profiles = [_][]const u8{oap_types.PROFILE};
    const requested = [_]oap_types.RequestedDelivery{.auto};
    const effective = [_]oap_types.EffectiveDelivery{.start};

    const envelope = oap_types.Envelope{
        .id = "cap-1",
        .in_reply_to = "req-2",
        .capability_revision = "rev-1",
        .payload = .{ .capabilities_response = .{
            .endpoint = .{ .id = "makai", .name = "Makai", .version = "0.2.0" },
            .protocol_versions = &versions,
            .profiles = &profiles,
            .bindings = &bindings,
            .features = &features,
            .requested_delivery_modes = &requested,
            .effective_delivery_modes = &effective,
            .degradation = &degradation,
        } },
    };

    const line = try serializeEnvelope(envelope, allocator);
    defer allocator.free(line);

    var decoded = try deserializeEnvelope(line, allocator);
    defer decoded.deinit(allocator);

    try std.testing.expectEqualStrings("rev-1", decoded.capability_revision.?);
    const capabilities = decoded.payload.capabilities_response;
    try std.testing.expectEqualStrings("makai", capabilities.endpoint.id);
    try std.testing.expectEqual(oap_types.SupportLevel.degraded, capabilities.feature("run.cancel").?.level);
    try std.testing.expectEqualStrings("per_run", capabilities.feature("run.model_selection").?.mode.?);
    try std.testing.expectEqual(@as(usize, 1), capabilities.degradation.len);
    try std.testing.expectEqual(oap_types.SupportLevel.degraded, capabilities.degradation[0].to);
    try std.testing.expectEqual(@as(usize, 1), capabilities.requested_delivery_modes.len);
    try std.testing.expectEqual(oap_types.RequestedDelivery.auto, capabilities.requested_delivery_modes[0]);
    try std.testing.expectEqual(@as(usize, 1), capabilities.effective_delivery_modes.len);
    try std.testing.expectEqual(oap_types.EffectiveDelivery.start, capabilities.effective_delivery_modes[0]);
}

test "rejects an unknown delivery mode in a capabilities response" {
    const allocator = std.testing.allocator;

    const line = "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ oap_types.PROFILE ++
        "\",\"type\":\"capabilities.response\",\"id\":\"cap-2\",\"payload\":{\"endpoint\":{\"id\":\"makai\"}," ++
        "\"layers\":{\"agent_loop\":{\"requested_delivery_modes\":[\"telepathy\"]}}}}";

    try std.testing.expectError(DecodeError.InvalidField, deserializeEnvelope(line, allocator));
}

test "a recognized frame that fails validation late frees what it already decoded" {
    const allocator = std.testing.allocator;

    const prefix = "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++
        oap_types.PROFILE ++ "\",\"id\":\"e-1\",\"type\":\"";

    const lines = [_][]const u8{
        prefix ++ "run.cancel.response\",\"payload\":{\"session_id\":\"s\",\"run_id\":\"r\"}}",
        prefix ++ "run.cancel.response\",\"payload\":{\"session_id\":\"s\",\"run_id\":\"r\",\"accepted\":true,\"status\":\"levitating\"}}",
        prefix ++ "run.status.updated\",\"payload\":{\"session_id\":\"s\",\"run_id\":\"r\",\"status\":\"levitating\"}}",
        prefix ++ "run.started\",\"payload\":{\"session_id\":\"s\",\"run_id\":\"r\",\"model_id\":\"m\",\"started_at_ms\":\"soon\"}}",
        prefix ++ "run.cancelled\",\"payload\":{\"session_id\":\"s\",\"run_id\":\"r\",\"reason\":\"why\",\"duration_ms\":\"later\"}}",
        prefix ++ "run.failed\",\"payload\":{\"session_id\":\"s\",\"run_id\":\"r\",\"error\":{\"code\":\"internal_error\",\"message\":\"boom\"},\"duration_ms\":\"later\"}}",
        prefix ++ "run.completed\",\"payload\":{\"session_id\":\"s\",\"run_id\":\"r\",\"final_response\":{\"role\":\"assistant\",\"content\":\"hi\"},\"stop_reason\":\"end_turn\",\"model_id\":\"m\",\"duration_ms\":\"later\"}}",
        prefix ++ "session.message.submit.response\",\"payload\":{\"session_id\":\"s\",\"submission_id\":\"sub\",\"delivery_resolution\":\"why\",\"run_id\":\"r\",\"model_id\":\"m\",\"accepted\":true,\"requested_delivery\":\"auto\",\"effective_delivery\":\"start\",\"admission\":\"telepathic\"}}",
        prefix ++ "session.state.response\",\"payload\":{\"session_id\":\"s\",\"status\":\"open\",\"active_run_id\":\"r\",\"current_model_id\":\"m\",\"updated_at_ms\":\"soon\"}}",
        prefix ++ "capabilities.response\",\"payload\":{\"endpoint\":{\"id\":\"makai\"},\"degradation\":[{\"feature\":\"run.cancel\",\"reason\":\"why\",\"to\":\"levitating\"}]}}",
        prefix ++ "capabilities.response\",\"payload\":{\"endpoint\":{\"id\":\"makai\"},\"layers\":{\"agent_loop\":{\"effective_delivery_modes\":[\"telepathy\"]}}}}",
    };

    for (lines) |line| {
        if (deserializeEnvelope(line, allocator)) |decoded| {
            var owned = decoded;
            owned.deinit(allocator);
            return error.TestExpectedDecodeFailure;
        } else |_| {}
    }
}

test "rejects a foreign protocol, version, or profile" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(DecodeError.ProtocolMismatch, deserializeEnvelope(
        "{\"protocol\":\"other\",\"version\":\"0.1\",\"profile\":\"" ++ oap_types.PROFILE ++ "\",\"type\":\"capabilities.request\",\"id\":\"a\",\"payload\":{}}",
        allocator,
    ));
    try std.testing.expectError(DecodeError.VersionMismatch, deserializeEnvelope(
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"9.9\",\"profile\":\"" ++ oap_types.PROFILE ++ "\",\"type\":\"capabilities.request\",\"id\":\"a\",\"payload\":{}}",
        allocator,
    ));
    try std.testing.expectError(DecodeError.ProfileMismatch, deserializeEnvelope(
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"other\",\"type\":\"capabilities.request\",\"id\":\"a\",\"payload\":{}}",
        allocator,
    ));
}

test "rejects malformed and unknown envelopes" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(DecodeError.InvalidEnvelope, deserializeEnvelope("not json", allocator));
    try std.testing.expectError(DecodeError.InvalidEnvelope, deserializeEnvelope("[]", allocator));
    try std.testing.expectError(DecodeError.MissingField, deserializeEnvelope(
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ oap_types.PROFILE ++ "\",\"type\":\"capabilities.request\",\"id\":\"a\"}",
        allocator,
    ));
    try std.testing.expectError(DecodeError.UnknownEnvelopeType, deserializeEnvelope(
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ oap_types.PROFILE ++ "\",\"type\":\"session.rename.request\",\"id\":\"a\",\"payload\":{}}",
        allocator,
    ));
    try std.testing.expectError(DecodeError.InvalidField, deserializeEnvelope(
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ oap_types.PROFILE ++ "\",\"type\":\"capabilities.request\",\"id\":\"a\",\"payload\":{},\"sequence\":0}",
        allocator,
    ));
}

test "a present but empty run control survives decoding as a present control" {
    const allocator = std.testing.allocator;

    var decoded = try deserializeEnvelope(
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ oap_types.PROFILE ++
            "\",\"type\":\"session.message.submit.request\",\"id\":\"a\",\"session_id\":\"s\"," ++
            "\"payload\":{\"session_id\":\"s\",\"delivery\":\"auto\",\"model_id\":\"\"," ++
            "\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}}",
        allocator,
    );
    defer decoded.deinit(allocator);

    const submit = decoded.payload.message_submit_request;
    try std.testing.expect(submit.model_id != null);
    try std.testing.expectEqual(@as(usize, 0), submit.model_id.?.len);
    try std.testing.expectEqualStrings("hi", submit.messages[0].content.text);
}

test "round trips reasoning and tool content parts" {
    const allocator = std.testing.allocator;

    const reasoning = oap_types.Envelope{
        .id = "ev-r",
        .session_id = "s",
        .run_id = "r",
        .sequence = 2,
        .payload = .{ .content_delta = .{
            .session_id = "s",
            .run_id = "r",
            .message_id = "m",
            .part = .{ .reasoning = .{ .text = "thinking" } },
        } },
    };
    const reasoning_line = try serializeEnvelope(reasoning, allocator);
    defer allocator.free(reasoning_line);
    var decoded_reasoning = try deserializeEnvelope(reasoning_line, allocator);
    defer decoded_reasoning.deinit(allocator);
    try std.testing.expectEqualStrings("thinking", decoded_reasoning.payload.content_delta.part.reasoning.text);
    try std.testing.expectEqualStrings("m", decoded_reasoning.payload.content_delta.message_id.?);

    const call = oap_types.Envelope{
        .id = "ev-c",
        .session_id = "s",
        .run_id = "r",
        .sequence = 3,
        .payload = .{ .content_delta = .{
            .session_id = "s",
            .run_id = "r",
            .part = .{ .tool_call = .{
                .tool_call_id = "call-1",
                .name = "read",
                .arguments_json = "{\"path\":\"a.txt\"}",
            } },
        } },
    };
    const call_line = try serializeEnvelope(call, allocator);
    defer allocator.free(call_line);
    var decoded_call = try deserializeEnvelope(call_line, allocator);
    defer decoded_call.deinit(allocator);
    try std.testing.expectEqualStrings("call-1", decoded_call.payload.content_delta.part.tool_call.tool_call_id);
    try std.testing.expectEqualStrings("read", decoded_call.payload.content_delta.part.tool_call.name);
}

test "serialized envelopes always carry the protocol triple" {
    const allocator = std.testing.allocator;

    const envelope = oap_types.Envelope{
        .id = "x",
        .payload = .{ .capabilities_request = {} },
    };
    const line = try serializeEnvelope(envelope, allocator);
    defer allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "\"protocol\":\"open-agent-protocol\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"version\":\"0.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"profile\":\"" ++ oap_types.PROFILE ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"type\":\"capabilities.request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\n") == null);
}
