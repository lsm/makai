const std = @import("std");
const json_writer = @import("json_writer");
const oap_types = @import("oap_types");
const oap_envelope = @import("oap_envelope");
const types = @import("oap_provider_types");

pub const DecodeError = error{
    InvalidEnvelope,
    UnknownEnvelopeType,
    ProtocolMismatch,
    VersionMismatch,
    ProfileMismatch,
    MissingField,
    InvalidField,
    CredentialInHeaders,
    UnknownField,
    PartialArgumentsInTerminal,
    ScopeRepeatedInPayload,
    AcceptanceScopeMismatch,
    CarryInReasoningOptions,
};

pub fn serializeEnvelope(env: types.Envelope, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);

    try w.beginObject();
    try w.writeStringField("protocol", types.PROTOCOL);
    try w.writeStringField("version", types.VERSION);
    try w.writeStringField("profile", types.PROFILE);
    try w.writeStringField("type", env.payload.typeName());
    try w.writeStringField("id", env.id);
    if (env.sequence) |sequence| try w.writeIntField("sequence", sequence);
    if (env.timestamp_ms) |timestamp| try w.writeIntField("timestamp_ms", timestamp);
    if (env.in_reply_to) |value| try w.writeStringField("in_reply_to", value);
    if (env.inference_id) |value| try w.writeStringField("inference_id", value);
    if (env.capability_revision) |value| try w.writeStringField("capability_revision", value);

    try w.writeKey("payload");
    try serializePayload(&w, env.payload);
    try w.endObject();

    const out = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return out;
}

fn writeHeaders(w: *json_writer.JsonWriter, headers: []const types.HeaderPair) !void {
    try w.writeKey("headers");
    try w.beginObject();
    for (headers) |header| try w.writeStringField(header.name, header.value);
    try w.endObject();
}

fn writeCompatibility(w: *json_writer.JsonWriter, facts: types.CompatibilityFacts) !void {
    try w.writeKey("compatibility");
    try w.beginObject();
    if (facts.max_tokens_field) |value| try w.writeStringField("max_tokens_field", @tagName(value));
    if (facts.thinking_format) |value| try w.writeStringField("thinking_format", @tagName(value));
    if (facts.usage_in_streaming) |value| try w.writeStringField("usage_in_streaming", @tagName(value));
    if (facts.requires_assistant_after_tool_result) |value| try w.writeBoolField("requires_assistant_after_tool_result", value);
    if (facts.requires_tool_result_name) |value| try w.writeBoolField("requires_tool_result_name", value);
    if (facts.requires_thinking_as_text) |value| try w.writeBoolField("requires_thinking_as_text", value);
    if (facts.supports_strict_mode) |value| try w.writeBoolField("supports_strict_mode", value);
    if (facts.supports_store) |value| try w.writeBoolField("supports_store", value);
    if (facts.supports_developer_role) |value| try w.writeBoolField("supports_developer_role", value);
    if (facts.supports_reasoning_effort) |value| try w.writeBoolField("supports_reasoning_effort", value);
    if (facts.tool_call_id_format) |value| try w.writeStringField("tool_call_id_format", value.toString());
    if (facts.cache_ttl_control) |value| try w.writeBoolField("cache_ttl_control", value);
    try w.endObject();
}

fn writeProviderDescriptor(w: *json_writer.JsonWriter, descriptor: types.ProviderDescriptor) !void {
    try w.beginObject();
    try w.writeStringField("id", descriptor.id);
    if (descriptor.display_name) |value| try w.writeStringField("display_name", value);
    try w.writeStringField("wire", descriptor.wire.toString());
    if (descriptor.wire_id) |wire_id| try w.writeStringField("wire_id", wire_id);
    try w.writeStringField("framing", @tagName(descriptor.framing));
    try w.writeStringField("endpoint", descriptor.endpoint);
    if (descriptor.headers.len > 0) try writeHeaders(w, descriptor.headers);
    if (!descriptor.compatibility.isEmpty()) try writeCompatibility(w, descriptor.compatibility);
    try w.writeKey("snapshot_policies");
    try w.beginArray();
    for (descriptor.snapshot_policies) |policy| try w.writeString(@tagName(policy));
    try w.endArray();
    try w.writeBoolField("answers_sync", descriptor.answers_sync);
    try w.writeStringField("credential_grant", @tagName(descriptor.credential_grant));
    if (descriptor.grant_kinds.len > 0) {
        try w.writeKey("grant_kinds");
        try w.beginArray();
        for (descriptor.grant_kinds) |kind| try w.writeString(@tagName(kind));
        try w.endArray();
    }
    try w.writeBoolField("allows_anonymous", descriptor.allows_anonymous);
    try w.writeBoolField("round_trips_carry", descriptor.round_trips_carry);
    if (descriptor.context_window) |value| try w.writeIntField("context_window", value);
    if (descriptor.max_output_tokens) |value| try w.writeIntField("max_output_tokens", value);
    try w.endObject();
}

fn writeModelEntry(w: *json_writer.JsonWriter, entry: types.ModelEntry) !void {
    try w.beginObject();
    try w.writeStringField("model_ref", entry.model_ref);
    try w.writeStringField("model_id", entry.model_id);
    if (entry.display_name) |value| try w.writeStringField("display_name", value);
    try w.writeStringField("provider_id", entry.provider_id);
    try w.writeStringField("wire", entry.wire.toString());
    if (entry.context_window) |value| try w.writeIntField("context_window", value);
    if (entry.max_output_tokens) |value| try w.writeIntField("max_output_tokens", value);
    try w.writeKey("capabilities");
    try w.beginArray();
    for (entry.capabilities) |capability| try w.writeString(@tagName(capability));
    try w.endArray();
    try w.writeStringField("lifecycle", @tagName(entry.lifecycle));
    try w.writeStringField("source", @tagName(entry.source));
    if (entry.reasoning_default) |value| try w.writeStringField("reasoning_default", @tagName(value));
    try w.writeStringField("auth_status", @tagName(entry.auth_status));
    try w.endObject();
}

fn writeProtocolError(w: *json_writer.JsonWriter, err: types.ProtocolError) !void {
    try w.beginObject();
    try w.writeStringField("code", @tagName(err.code));
    try w.writeStringField("message", err.message);
    if (err.details.len > 0) {
        try w.writeKey("details");
        try w.beginObject();
        for (err.details) |entry| try w.writeStringField(entry.key, entry.value);
        try w.endObject();
    }
    try w.endObject();
}

fn writeSnapshotPart(w: *json_writer.JsonWriter, part: oap_types.ContentPart) !void {
    switch (part) {
        .tool_call => |value| {
            try w.beginObject();
            try w.writeStringField("type", "tool_call");
            try w.writeStringField("tool_call_id", value.tool_call_id);
            try w.writeStringField("name", value.name);
            if (value.arguments_partial) |partial| {
                try w.writeStringField("arguments_partial", partial);
            } else {
                try w.writeKey("arguments_json");
                try oap_envelope.writeJsonValueOrString(w, value.arguments_json);
            }
            if (value.carry) |carry| try w.writeStringField("carry", carry);
            try w.endObject();
        },
        else => try oap_envelope.serializeContentPart(w, part),
    }
}

fn writeSnapshotMessage(w: *json_writer.JsonWriter, message: oap_types.Message) !void {
    try w.beginObject();
    if (message.id) |id| try w.writeStringField("id", id);
    try w.writeStringField("role", @tagName(message.role));
    try w.writeKey("content");
    switch (message.content) {
        .text => |value| try w.writeString(value),
        .parts => |parts| {
            try w.beginArray();
            for (parts) |part| try writeSnapshotPart(w, part);
            try w.endArray();
        },
    }
    try w.endObject();
}

fn writeMessageArray(w: *json_writer.JsonWriter, key: []const u8, messages: []const oap_types.Message) !void {
    try w.writeKey(key);
    try w.beginArray();
    for (messages) |message| try writeSnapshotMessage(w, message);
    try w.endArray();
}

fn serializePayload(w: *json_writer.JsonWriter, payload: types.Payload) !void {
    switch (payload) {
        .provider_describe_request, .inference_sync_request => {
            try w.beginObject();
            try w.endObject();
        },
        .provider_describe_response => |value| {
            try w.beginObject();
            if (value.profile_revision) |revision| try w.writeStringField("profile_revision", revision);
            try w.writeKey("providers");
            try w.beginArray();
            for (value.providers) |descriptor| try writeProviderDescriptor(w, descriptor);
            try w.endArray();
            try oap_envelope.serializeStringArray(w, "protocol_versions", value.protocol_versions);
            try w.endObject();
        },
        .provider_models_list_request => |value| {
            try w.beginObject();
            if (value.provider_id) |id| try w.writeStringField("provider_id", id);
            try w.endObject();
        },
        .provider_models_list_response => |value| {
            try w.beginObject();
            try w.writeKey("models");
            try w.beginArray();
            for (value.models) |entry| try writeModelEntry(w, entry);
            try w.endArray();
            try w.endObject();
        },
        .provider_credential_grant_request => |value| {
            try w.beginObject();
            try w.writeStringField("provider_id", value.provider_id);
            try w.writeStringField("nonce", value.nonce);
            if (value.ttl_ms) |ttl| try w.writeIntField("ttl_ms", ttl);
            if (value.value) |secret| try w.writeStringField("value", secret);
            try w.endObject();
        },
        .provider_credential_grant_channel => |value| {
            try w.beginObject();
            try w.writeStringField("nonce", value.nonce);
            try w.writeStringField("channel", value.channel);
            try w.endObject();
        },
        .provider_credential_grant_response => |value| {
            try w.beginObject();
            try w.writeBoolField("accepted", value.accepted);
            if (value.credential_ref) |ref| try w.writeStringField("credential_ref", ref);
            if (value.expires_at_ms) |expiry| try w.writeIntField("expires_at_ms", expiry);
            if (value.err) |err| {
                try w.writeKey("error");
                try writeProtocolError(w, err);
            }
            try w.endObject();
        },
        .inference_create_request => |value| {
            try w.beginObject();
            try w.writeStringField("model_ref", value.model_ref);
            try writeMessageArray(w, "messages", value.messages);
            if (value.tools.len > 0) {
                try w.writeKey("tools");
                try w.beginArray();
                for (value.tools) |tool| {
                    try w.beginObject();
                    try w.writeStringField("name", tool.name);
                    if (tool.description) |description| try w.writeStringField("description", description);
                    if (tool.input_schema_json) |schema| {
                        try w.writeKey("input_schema");
                        try oap_envelope.writeJsonValueOrString(w, schema);
                    }
                    try w.endObject();
                }
                try w.endArray();
            }
            if (value.tool_choice) |choice| {
                try w.writeKey("tool_choice");
                switch (choice) {
                    .auto => try w.writeString("auto"),
                    .none => try w.writeString("none"),
                    .required => try w.writeString("required"),
                    .function => |name| {
                        try w.beginObject();
                        try w.writeStringField("function", name);
                        try w.endObject();
                    },
                }
            }
            if (value.max_output_tokens) |max| try w.writeIntField("max_output_tokens", max);
            if (value.temperature) |temperature| {
                try w.writeKey("temperature");
                try w.writeFloat(temperature);
            }
            if (value.top_p) |top_p| {
                try w.writeKey("top_p");
                try w.writeFloat(top_p);
            }
            if (value.output_schema_json) |schema| {
                try w.writeKey("output_schema");
                try oap_envelope.writeJsonValueOrString(w, schema);
            }
            try w.writeBoolField("stream", value.stream);
            if (value.reasoning) |reasoning| {
                try w.writeKey("reasoning");
                try w.beginObject();
                if (reasoning.enabled) |enabled| try w.writeBoolField("enabled", enabled);
                if (reasoning.budget_tokens) |budget| try w.writeIntField("budget_tokens", budget);
                if (reasoning.effort) |effort| try w.writeStringField("effort", effort);
                try w.endObject();
            }
            try w.writeStringField("include_snapshot", @tagName(value.include_snapshot));
            if (value.headers.len > 0) try writeHeaders(w, value.headers);
            if (value.credential_ref) |ref| try w.writeStringField("credential_ref", ref);
            if (value.allow_degraded_features.len > 0) {
                try oap_envelope.serializeStringArray(w, "allow_degraded_features", value.allow_degraded_features);
            }
            if (value.metadata_json) |metadata| {
                try w.writeKey("metadata");
                try oap_envelope.writeJsonValueOrString(w, metadata);
            }
            try w.endObject();
        },
        .inference_create_response => |value| {
            try w.beginObject();
            try w.writeBoolField("accepted", value.accepted);
            if (value.honoured) |honoured| {
                try w.writeKey("honoured");
                try w.beginObject();
                try w.writeStringField("include_snapshot", @tagName(honoured));
                try w.endObject();
            }
            if (value.err) |err| {
                try w.writeKey("error");
                try writeProtocolError(w, err);
            }
            try w.endObject();
        },
        .inference_started => |value| {
            try w.beginObject();
            try w.writeStringField("model_ref", value.model_ref);
            try w.writeIntField("started_at_ms", value.started_at_ms);
            try w.endObject();
        },
        .inference_part_started => |value| {
            try w.beginObject();
            try w.writeIntField("part_index", value.part_index);
            try w.writeStringField("part_kind", @tagName(value.part_kind));
            if (value.tool_call_id) |id| try w.writeStringField("tool_call_id", id);
            if (value.name) |name| try w.writeStringField("name", name);
            try w.endObject();
        },
        .inference_part_delta => |value| {
            try w.beginObject();
            try w.writeIntField("part_index", value.part_index);
            try w.writeStringField("delta", value.delta);
            if (value.snapshot) |messages| try writeMessageArray(w, "snapshot", messages);
            try w.endObject();
        },
        .inference_part_ended => |value| {
            try w.beginObject();
            try w.writeIntField("part_index", value.part_index);
            try w.writeStringField("part_kind", @tagName(value.part_kind));
            if (value.text) |text| try w.writeStringField("text", text);
            if (value.tool_call) |call| {
                try w.writeKey("tool_call");
                try w.beginObject();
                try w.writeStringField("tool_call_id", call.tool_call_id);
                try w.writeStringField("name", call.name);
                try w.writeKey("arguments_json");
                try oap_envelope.writeJsonValueOrString(w, call.arguments_json);
                try w.endObject();
            }
            if (value.carry) |carry| try w.writeStringField("carry", carry);
            if (value.snapshot) |messages| try writeMessageArray(w, "snapshot", messages);
            try w.endObject();
        },
        .inference_completed => |value| {
            try w.beginObject();
            try w.writeKey("message");
            try oap_envelope.serializeMessage(w, value.message);
            try w.writeStringField("stop_reason", @tagName(value.stop_reason));
            if (value.usage) |usage| {
                if (!usage.isEmpty()) try oap_envelope.serializeUsage(w, usage);
            }
            try w.endObject();
        },
        .inference_failed => |value| {
            try w.beginObject();
            try w.writeKey("error");
            try writeProtocolError(w, value.err);
            if (value.usage) |usage| {
                if (!usage.isEmpty()) try oap_envelope.serializeUsage(w, usage);
            }
            try w.endObject();
        },
        .inference_cancel_request => |value| {
            try w.beginObject();
            if (value.reason) |reason| try w.writeStringField("reason", reason);
            try w.endObject();
        },
        .inference_cancel_response => |value| {
            try w.beginObject();
            try w.writeBoolField("accepted", value.accepted);
            try w.endObject();
        },
        .inference_sync_response => |value| {
            try w.beginObject();
            if (value.snapshot) |messages| try writeMessageArray(w, "snapshot", messages);
            try w.endObject();
        },
        .protocol_error => |value| {
            try w.beginObject();
            try w.writeKey("error");
            try writeProtocolError(w, value.err);
            if (value.protocol_versions.len > 0) {
                try oap_envelope.serializeStringArray(w, "protocol_versions", value.protocol_versions);
            }
            try w.endObject();
        },
    }
}

pub fn deserializeEnvelope(line: []const u8, allocator: std.mem.Allocator) !types.Envelope {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return DecodeError.InvalidEnvelope,
    };
    defer parsed.deinit();

    if (parsed.value != .object) return DecodeError.InvalidEnvelope;
    const root = parsed.value.object;

    const protocol = try oap_envelope.requiredString(root, "protocol");
    if (!std.mem.eql(u8, protocol, types.PROTOCOL)) return DecodeError.ProtocolMismatch;

    const version = try oap_envelope.requiredString(root, "version");
    if (!std.mem.eql(u8, version, types.VERSION)) return DecodeError.VersionMismatch;

    const profile = try oap_envelope.requiredString(root, "profile");
    if (!std.mem.eql(u8, profile, types.PROFILE)) return DecodeError.ProfileMismatch;

    const type_name = try oap_envelope.requiredString(root, "type");
    const tag = types.payloadTypeFromName(type_name) orelse return DecodeError.UnknownEnvelopeType;

    const payload_value = root.get("payload") orelse return DecodeError.MissingField;
    if (payload_value != .object) return DecodeError.InvalidField;

    const id = try oap_envelope.requiredOwnedString(root, "id", allocator);
    errdefer allocator.free(id);

    const in_reply_to = try oap_envelope.optionalOwnedString(root, "in_reply_to", allocator);
    errdefer if (in_reply_to) |value| allocator.free(value);

    const inference_id = try oap_envelope.optionalOwnedString(root, "inference_id", allocator);
    errdefer if (inference_id) |value| allocator.free(value);

    const capability_revision = try oap_envelope.optionalOwnedString(root, "capability_revision", allocator);
    errdefer if (capability_revision) |value| allocator.free(value);

    const sequence = try oap_envelope.optionalUnsigned(root, "sequence");
    const timestamp_ms = try oap_envelope.optionalInteger(root, "timestamp_ms");

    var payload = try deserializePayload(tag, payload_value.object, allocator);
    errdefer payload.deinit(allocator);

    if (payload.isScopedEvent()) {
        if (sequence == null or sequence.? == 0) return DecodeError.InvalidField;
        if (inference_id == null) return DecodeError.MissingField;
    }

    if (payload == .inference_create_response) {
        const accepted = payload.inference_create_response.accepted;
        if (accepted and inference_id == null) return DecodeError.AcceptanceScopeMismatch;
        if (!accepted and inference_id != null) return DecodeError.AcceptanceScopeMismatch;
    }

    return types.Envelope{
        .id = id,
        .payload = payload,
        .sequence = sequence,
        .timestamp_ms = timestamp_ms,
        .in_reply_to = in_reply_to,
        .inference_id = inference_id,
        .capability_revision = capability_revision,
    };
}

fn deserializeHeaders(obj: std.json.ObjectMap, allocator: std.mem.Allocator, policed: bool) ![]const types.HeaderPair {
    const value = obj.get("headers") orelse return &.{};
    if (value != .object) return DecodeError.InvalidField;

    var list = std.ArrayList(types.HeaderPair).empty;
    errdefer {
        for (list.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        list.deinit(allocator);
    }

    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) return DecodeError.InvalidField;
        const candidate = types.HeaderPair{ .name = entry.key_ptr.*, .value = entry.value_ptr.string };
        if (policed and types.headerCarriesCredential(candidate)) return DecodeError.CredentialInHeaders;
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name);
        const header_value = try allocator.dupe(u8, entry.value_ptr.string);
        errdefer allocator.free(header_value);
        try list.append(allocator, .{ .name = name, .value = header_value });
    }

    return list.toOwnedSlice(allocator);
}

fn deserializeCompatibility(obj: std.json.ObjectMap) !types.CompatibilityFacts {
    const value = obj.get("compatibility") orelse return .{};
    if (value != .object) return DecodeError.InvalidField;
    const facts = value.object;

    return types.CompatibilityFacts{
        .max_tokens_field = try oap_envelope.optionalEnum(types.MaxTokensField, facts, "max_tokens_field"),
        .thinking_format = try oap_envelope.optionalEnum(types.ThinkingFormat, facts, "thinking_format"),
        .usage_in_streaming = try oap_envelope.optionalEnum(types.UsageInStreaming, facts, "usage_in_streaming"),
        .requires_assistant_after_tool_result = try oap_envelope.optionalBool(facts, "requires_assistant_after_tool_result"),
        .requires_tool_result_name = try oap_envelope.optionalBool(facts, "requires_tool_result_name"),
        .requires_thinking_as_text = try oap_envelope.optionalBool(facts, "requires_thinking_as_text"),
        .supports_strict_mode = try oap_envelope.optionalBool(facts, "supports_strict_mode"),
        .supports_store = try oap_envelope.optionalBool(facts, "supports_store"),
        .supports_developer_role = try oap_envelope.optionalBool(facts, "supports_developer_role"),
        .supports_reasoning_effort = try oap_envelope.optionalBool(facts, "supports_reasoning_effort"),
        .tool_call_id_format = try optionalToolCallIdFormat(facts),
        .cache_ttl_control = try oap_envelope.optionalBool(facts, "cache_ttl_control"),
    };
}

fn deserializeGrantKinds(obj: std.json.ObjectMap, allocator: std.mem.Allocator) ![]const types.GrantKind {
    const value = obj.get("grant_kinds") orelse return &.{};
    if (value != .array) return DecodeError.InvalidField;
    var list = std.ArrayList(types.GrantKind).empty;
    errdefer list.deinit(allocator);
    for (value.array.items) |item| {
        if (item != .string) return DecodeError.InvalidField;
        const kind = types.GrantKind.parse(item.string) orelse return DecodeError.InvalidField;
        try list.append(allocator, kind);
    }
    return list.toOwnedSlice(allocator);
}

fn optionalToolCallIdFormat(obj: std.json.ObjectMap) !?types.ToolCallIdFormat {
    const value = obj.get("tool_call_id_format") orelse return null;
    if (value != .string) return DecodeError.InvalidField;
    return types.ToolCallIdFormat.parse(value.string) orelse DecodeError.InvalidField;
}

fn deserializeSnapshotPart(
    value: std.json.Value,
    allocator: std.mem.Allocator,
    allow_partial: bool,
) !oap_types.ContentPart {
    if (value == .object) {
        if (value.object.get("arguments_partial")) |partial| {
            if (!allow_partial) return DecodeError.PartialArgumentsInTerminal;
            if (partial != .string) return DecodeError.InvalidField;
            if (value.object.get("arguments_json") != null) return DecodeError.InvalidField;

            const tool_call_id = try oap_envelope.requiredOwnedString(value.object, "tool_call_id", allocator);
            errdefer allocator.free(tool_call_id);
            const name = try oap_envelope.requiredOwnedString(value.object, "name", allocator);
            errdefer allocator.free(name);
            const empty = try allocator.dupe(u8, "");
            errdefer allocator.free(empty);
            const owned_partial = try allocator.dupe(u8, partial.string);
            errdefer allocator.free(owned_partial);
            const carry = try oap_envelope.optionalOwnedString(value.object, "carry", allocator);

            return oap_types.ContentPart{ .tool_call = .{
                .tool_call_id = tool_call_id,
                .name = name,
                .arguments_json = empty,
                .arguments_partial = owned_partial,
                .carry = carry,
            } };
        }
    }
    return oap_envelope.deserializeContentPart(value, allocator);
}

fn deserializeSnapshotMessage(
    value: std.json.Value,
    allocator: std.mem.Allocator,
    allow_partial: bool,
) !oap_types.Message {
    if (value != .object) return DecodeError.InvalidField;
    const obj = value.object;

    const content_value = obj.get("content") orelse return DecodeError.MissingField;
    if (content_value != .array) return oap_envelope.deserializeMessage(value, allocator);

    const id = try oap_envelope.optionalOwnedString(obj, "id", allocator);
    errdefer if (id) |owned| allocator.free(owned);
    const role = try oap_envelope.requiredEnum(oap_types.Role, obj, "role");

    if (content_value.array.items.len == 0) return DecodeError.InvalidField;
    const parts = try allocator.alloc(oap_types.ContentPart, content_value.array.items.len);
    var built: usize = 0;
    errdefer {
        for (parts[0..built]) |*part| part.deinit(allocator);
        allocator.free(parts);
    }
    for (content_value.array.items, 0..) |item, index| {
        parts[index] = try deserializeSnapshotPart(item, allocator, allow_partial);
        built += 1;
    }

    return oap_types.Message{ .id = id, .role = role, .content = .{ .parts = parts } };
}

fn deserializeMessageArrayWithPolicy(
    obj: std.json.ObjectMap,
    key: []const u8,
    allocator: std.mem.Allocator,
    allow_partial: bool,
) !?[]oap_types.Message {
    const value = obj.get(key) orelse return null;
    if (value != .array) return DecodeError.InvalidField;

    var list = std.ArrayList(oap_types.Message).empty;
    errdefer {
        for (list.items) |*message| message.deinit(allocator);
        list.deinit(allocator);
    }

    for (value.array.items) |item| {
        const message = try deserializeSnapshotMessage(item, allocator, allow_partial);
        try list.append(allocator, message);
    }

    return try list.toOwnedSlice(allocator);
}

fn deserializeMessageArray(obj: std.json.ObjectMap, key: []const u8, allocator: std.mem.Allocator) !?[]oap_types.Message {
    return deserializeMessageArrayWithPolicy(obj, key, allocator, true);
}

fn deserializeProtocolError(value: std.json.Value, allocator: std.mem.Allocator) !types.ProtocolError {
    if (value != .object) return DecodeError.InvalidField;
    const obj = value.object;

    const code = try oap_envelope.requiredEnum(types.ErrorCode, obj, "code");
    const message = try oap_envelope.requiredOwnedString(obj, "message", allocator);
    errdefer allocator.free(message);

    var details = std.ArrayList(oap_types.DetailEntry).empty;
    errdefer {
        for (details.items) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        details.deinit(allocator);
    }

    if (obj.get("details")) |detail_value| {
        if (detail_value != .object) return DecodeError.InvalidField;
        var it = detail_value.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) return DecodeError.InvalidField;
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            const detail_text = try allocator.dupe(u8, entry.value_ptr.string);
            errdefer allocator.free(detail_text);
            try details.append(allocator, .{ .key = key, .value = detail_text });
        }
    }

    return types.ProtocolError{
        .code = code,
        .message = message,
        .details = try details.toOwnedSlice(allocator),
    };
}

fn rejectUnknownMembers(obj: std.json.ObjectMap, allowed: []const []const u8) !void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        var known = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                known = true;
                break;
            }
        }
        if (!known) return DecodeError.UnknownField;
    }
}

fn allowedPayloadMembers(tag: std.meta.Tag(types.Payload)) []const []const u8 {
    return switch (tag) {
        .provider_describe_request => &.{},
        .provider_describe_response => &.{ "profile_revision", "protocol_versions", "providers" },
        .provider_models_list_request => &.{"provider_id"},
        .provider_models_list_response => &.{"models"},
        .provider_credential_grant_request => &.{ "nonce", "provider_id", "ttl_ms", "value" },
        .provider_credential_grant_response => &.{ "accepted", "credential_ref", "error", "expires_at_ms" },
        .provider_credential_grant_channel => &.{ "channel", "nonce" },
        .inference_create_request => &.{
            "allow_degraded_features", "credential_ref",   "headers",  "include_snapshot",
            "max_output_tokens",       "messages",         "metadata", "model_ref",
            "output_schema",           "reasoning",        "stream",   "temperature",
            "tool_choice",             "tools",            "top_p",
        },
        .inference_create_response => &.{ "accepted", "error", "honoured" },
        .inference_started => &.{ "endpoint", "model_ref", "started_at_ms" },
        .inference_part_started => &.{ "name", "part_index", "part_kind", "tool_call_id" },
        .inference_part_delta => &.{ "delta", "part_index", "snapshot" },
        .inference_part_ended => &.{ "carry", "part_index", "part_kind", "snapshot", "text", "tool_call" },
        .inference_completed => &.{ "message", "stop_reason", "usage" },
        .inference_failed => &.{ "error", "usage" },
        .inference_cancel_request => &.{"reason"},
        .inference_cancel_response => &.{"accepted"},
        .inference_sync_request => &.{},
        .inference_sync_response => &.{"snapshot"},
        .protocol_error => &.{ "error", "protocol_versions" },
    };
}

fn deserializePayload(
    tag: std.meta.Tag(types.Payload),
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !types.Payload {
    if (obj.get("inference_id") != null) return DecodeError.ScopeRepeatedInPayload;
    try rejectUnknownMembers(obj, allowedPayloadMembers(tag));
    switch (tag) {
        .provider_describe_request => return types.Payload{ .provider_describe_request = .{} },
        .inference_sync_request => return types.Payload{ .inference_sync_request = .{} },
        .inference_cancel_response => {
            return types.Payload{ .inference_cancel_response = .{
                .accepted = try oap_envelope.requiredBool(obj, "accepted"),
            } };
        },
        .provider_models_list_request => {
            const provider_id = try oap_envelope.optionalOwnedString(obj, "provider_id", allocator);
            return types.Payload{ .provider_models_list_request = .{ .provider_id = provider_id } };
        },
        .inference_cancel_request => {
            const reason = try oap_envelope.optionalOwnedString(obj, "reason", allocator);
            return types.Payload{ .inference_cancel_request = .{ .reason = reason } };
        },
        .inference_sync_response => {
            const snapshot = try deserializeMessageArray(obj, "snapshot", allocator);
            return types.Payload{ .inference_sync_response = .{ .snapshot = snapshot } };
        },
        .provider_credential_grant_request => {
            const provider_id = try oap_envelope.requiredOwnedString(obj, "provider_id", allocator);
            errdefer allocator.free(provider_id);
            const nonce = try oap_envelope.requiredOwnedString(obj, "nonce", allocator);
            errdefer allocator.free(nonce);
            const ttl_ms = try oap_envelope.optionalUnsigned(obj, "ttl_ms");
            const value = try oap_envelope.optionalOwnedString(obj, "value", allocator);
            return types.Payload{ .provider_credential_grant_request = .{
                .provider_id = provider_id,
                .nonce = nonce,
                .ttl_ms = ttl_ms,
                .value = value,
            } };
        },
        .provider_credential_grant_channel => {
            const nonce = try oap_envelope.requiredOwnedString(obj, "nonce", allocator);
            errdefer allocator.free(nonce);
            const channel = try oap_envelope.requiredOwnedString(obj, "channel", allocator);
            return types.Payload{ .provider_credential_grant_channel = .{ .nonce = nonce, .channel = channel } };
        },
        .provider_credential_grant_response => {
            const accepted = try oap_envelope.requiredBool(obj, "accepted");
            const credential_ref = try oap_envelope.optionalOwnedString(obj, "credential_ref", allocator);
            errdefer if (credential_ref) |value| allocator.free(value);
            const expires_at_ms = try oap_envelope.optionalInteger(obj, "expires_at_ms");
            var err: ?types.ProtocolError = null;
            errdefer if (err) |*value| value.deinit(allocator);
            if (obj.get("error")) |error_value| {
                err = try deserializeProtocolError(error_value, allocator);
            }
            if (accepted and credential_ref == null) return DecodeError.MissingField;
            if (!accepted and credential_ref != null) return DecodeError.InvalidField;
            if (accepted and err != null) return DecodeError.InvalidField;
            if (!accepted and err == null) return DecodeError.MissingField;
            return types.Payload{ .provider_credential_grant_response = .{
                .accepted = accepted,
                .credential_ref = credential_ref,
                .expires_at_ms = expires_at_ms,
                .err = err,
            } };
        },
        .inference_create_response => {
            const accepted = try oap_envelope.requiredBool(obj, "accepted");
            const honoured = blk: {
                const value = obj.get("honoured") orelse break :blk null;
                if (value != .object) return DecodeError.InvalidField;
                break :blk try oap_envelope.optionalEnum(types.SnapshotPolicy, value.object, "include_snapshot");
            };
            var err: ?types.ProtocolError = null;
            errdefer if (err) |*value| value.deinit(allocator);
            if (obj.get("error")) |error_value| {
                err = try deserializeProtocolError(error_value, allocator);
            }
            if (accepted and err != null) return DecodeError.InvalidField;
            if (!accepted and err == null) return DecodeError.MissingField;
            if (!accepted and honoured != null) return DecodeError.InvalidField;
            return types.Payload{ .inference_create_response = .{
                .accepted = accepted,
                .honoured = honoured,
                .err = err,
            } };
        },
        .inference_started => {
            const model_ref = try oap_envelope.requiredOwnedString(obj, "model_ref", allocator);
            errdefer allocator.free(model_ref);
            const started = try oap_envelope.optionalInteger(obj, "started_at_ms") orelse return DecodeError.MissingField;
            return types.Payload{ .inference_started = .{ .model_ref = model_ref, .started_at_ms = started } };
        },
        .inference_part_started => {
            const part_index = try requiredPartIndex(obj);
            const part_kind = try oap_envelope.requiredEnum(types.PartKind, obj, "part_kind");
            const tool_call_id = try oap_envelope.optionalOwnedString(obj, "tool_call_id", allocator);
            errdefer if (tool_call_id) |value| allocator.free(value);
            const name = try oap_envelope.optionalOwnedString(obj, "name", allocator);
            errdefer if (name) |value| allocator.free(value);
            if (part_kind == .tool_call and (tool_call_id == null or name == null)) return DecodeError.MissingField;
            if (part_kind != .tool_call and (tool_call_id != null or name != null)) return DecodeError.InvalidField;
            return types.Payload{ .inference_part_started = .{
                .part_index = part_index,
                .part_kind = part_kind,
                .tool_call_id = tool_call_id,
                .name = name,
            } };
        },
        .inference_part_delta => {
            const part_index = try requiredPartIndex(obj);
            const delta = try oap_envelope.requiredOwnedString(obj, "delta", allocator);
            errdefer allocator.free(delta);
            const snapshot = try deserializeMessageArray(obj, "snapshot", allocator);
            return types.Payload{ .inference_part_delta = .{
                .part_index = part_index,
                .delta = delta,
                .snapshot = snapshot,
            } };
        },
        .inference_part_ended => {
            const part_index = try requiredPartIndex(obj);
            const part_kind = try oap_envelope.requiredEnum(types.PartKind, obj, "part_kind");
            var text: ?[]const u8 = null;
            errdefer if (text) |value| allocator.free(value);
            var tool_call: ?oap_types.ToolCallPart = null;
            errdefer if (tool_call) |*value| value.deinit(allocator);

            switch (part_kind) {
                .tool_call => {
                    const call_value = obj.get("tool_call") orelse return DecodeError.MissingField;
                    if (call_value != .object) return DecodeError.InvalidField;
                    const call_obj = call_value.object;
                    const call_id = try oap_envelope.requiredOwnedString(call_obj, "tool_call_id", allocator);
                    errdefer allocator.free(call_id);
                    const name = try oap_envelope.requiredOwnedString(call_obj, "name", allocator);
                    errdefer allocator.free(name);
                    const arguments_value = call_obj.get("arguments_json") orelse return DecodeError.MissingField;
                    const arguments = try oap_envelope.ownedRawJson(arguments_value, allocator);
                    tool_call = .{ .tool_call_id = call_id, .name = name, .arguments_json = arguments };
                },
                .text, .reasoning => {
                    text = try oap_envelope.requiredOwnedString(obj, "text", allocator);
                },
            }

            const carry = try oap_envelope.optionalOwnedString(obj, "carry", allocator);
            errdefer if (carry) |value| allocator.free(value);
            if (carry != null and part_kind == .text) return DecodeError.InvalidField;

            const snapshot = try deserializeMessageArray(obj, "snapshot", allocator);
            return types.Payload{ .inference_part_ended = .{
                .part_index = part_index,
                .part_kind = part_kind,
                .text = text,
                .tool_call = tool_call,
                .carry = carry,
                .snapshot = snapshot,
            } };
        },
        .inference_completed => {
            const message_value = obj.get("message") orelse return DecodeError.MissingField;
            var message = try deserializeSnapshotMessage(message_value, allocator, false);
            errdefer message.deinit(allocator);
            const stop_reason = try oap_envelope.requiredEnum(types.StopReason, obj, "stop_reason");
            var usage: ?oap_types.Usage = null;
            if (obj.get("usage")) |usage_value| {
                if (usage_value != .object) return DecodeError.InvalidField;
                usage = try oap_envelope.deserializeUsage(obj);
            }
            return types.Payload{ .inference_completed = .{
                .message = message,
                .stop_reason = stop_reason,
                .usage = usage,
            } };
        },
        .inference_failed => {
            const error_value = obj.get("error") orelse return DecodeError.MissingField;
            var err = try deserializeProtocolError(error_value, allocator);
            errdefer err.deinit(allocator);
            var usage: ?oap_types.Usage = null;
            if (obj.get("usage")) |usage_value| {
                if (usage_value != .object) return DecodeError.InvalidField;
                usage = try oap_envelope.deserializeUsage(obj);
            }
            return types.Payload{ .inference_failed = .{ .err = err, .usage = usage } };
        },
        .protocol_error => {
            const error_value = obj.get("error") orelse return DecodeError.MissingField;
            var err = try deserializeProtocolError(error_value, allocator);
            errdefer err.deinit(allocator);
            const versions = if (obj.get("protocol_versions") != null)
                try oap_envelope.deserializeStringArray(obj, "protocol_versions", allocator)
            else
                &.{};
            return types.Payload{ .protocol_error = .{ .err = err, .protocol_versions = versions } };
        },
        .inference_create_request => return try deserializeCreateRequest(obj, allocator),
        .provider_describe_response => return try deserializeDescribeResponse(obj, allocator),
        .provider_models_list_response => return try deserializeModelsListResponse(obj, allocator),
    }
}

fn requiredPartIndex(obj: std.json.ObjectMap) !u32 {
    const value = try oap_envelope.optionalUnsigned(obj, "part_index") orelse return DecodeError.MissingField;
    if (value > std.math.maxInt(u32)) return DecodeError.InvalidField;
    return @intCast(value);
}

fn optionalU32(obj: std.json.ObjectMap, key: []const u8) !?u32 {
    const value = try oap_envelope.optionalUnsigned(obj, key) orelse return null;
    if (value > std.math.maxInt(u32)) return DecodeError.InvalidField;
    return @intCast(value);
}

fn optionalF32(obj: std.json.ObjectMap, key: []const u8) !?f32 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => DecodeError.InvalidField,
    };
}

fn deserializeCreateRequest(obj: std.json.ObjectMap, allocator: std.mem.Allocator) !types.Payload {
    const model_ref = try oap_envelope.requiredOwnedString(obj, "model_ref", allocator);
    errdefer allocator.free(model_ref);

    const messages = try deserializeMessageArray(obj, "messages", allocator) orelse return DecodeError.MissingField;
    errdefer {
        for (messages) |*message| message.deinit(allocator);
        allocator.free(messages);
    }

    var tools = std.ArrayList(types.ToolDefinition).empty;
    errdefer {
        for (tools.items) |*tool| tool.deinit(allocator);
        tools.deinit(allocator);
    }
    if (obj.get("tools")) |tools_value| {
        if (tools_value != .array) return DecodeError.InvalidField;
        for (tools_value.array.items) |item| {
            if (item != .object) return DecodeError.InvalidField;
            const name = try oap_envelope.requiredOwnedString(item.object, "name", allocator);
            errdefer allocator.free(name);
            const description = try oap_envelope.optionalOwnedString(item.object, "description", allocator);
            errdefer if (description) |value| allocator.free(value);
            const schema = try oap_envelope.optionalRawJson(item.object, "input_schema", allocator);
            errdefer if (schema) |value| allocator.free(value);
            try tools.append(allocator, .{
                .name = name,
                .description = description,
                .input_schema_json = schema,
            });
        }
    }

    var tool_choice: ?types.ToolChoice = null;
    errdefer if (tool_choice) |*choice| choice.deinit(allocator);
    if (obj.get("tool_choice")) |choice_value| {
        switch (choice_value) {
            .string => |value| {
                if (std.mem.eql(u8, value, "auto")) {
                    tool_choice = .auto;
                } else if (std.mem.eql(u8, value, "none")) {
                    tool_choice = .none;
                } else if (std.mem.eql(u8, value, "required")) {
                    tool_choice = .required;
                } else return DecodeError.InvalidField;
            },
            .object => |choice_obj| {
                const name = try oap_envelope.requiredOwnedString(choice_obj, "function", allocator);
                tool_choice = .{ .function = name };
            },
            else => return DecodeError.InvalidField,
        }
    }

    const output_schema = try oap_envelope.optionalRawJson(obj, "output_schema", allocator);
    errdefer if (output_schema) |value| allocator.free(value);

    var reasoning: ?types.ReasoningOptions = null;
    errdefer if (reasoning) |*value| value.deinit(allocator);
    if (obj.get("reasoning")) |reasoning_value| {
        if (reasoning_value != .object) return DecodeError.InvalidField;
        const reasoning_obj = reasoning_value.object;
        if (reasoning_obj.get("encrypted_carry") != null) return DecodeError.CarryInReasoningOptions;
        const effort = try oap_envelope.optionalOwnedString(reasoning_obj, "effort", allocator);
        errdefer if (effort) |value| allocator.free(value);
        reasoning = .{
            .enabled = try oap_envelope.optionalBool(reasoning_obj, "enabled"),
            .budget_tokens = try optionalU32(reasoning_obj, "budget_tokens"),
            .effort = effort,
        };
    }

    const include_snapshot = try oap_envelope.optionalEnum(types.SnapshotPolicy, obj, "include_snapshot") orelse .never;

    const headers = try deserializeHeaders(obj, allocator, true);
    errdefer types.freeHeaders(allocator, headers);

    const credential_ref = try oap_envelope.optionalOwnedString(obj, "credential_ref", allocator);
    errdefer if (credential_ref) |value| allocator.free(value);

    const metadata = try oap_envelope.optionalRawJson(obj, "metadata", allocator);
    errdefer if (metadata) |value| allocator.free(value);

    const max_output_tokens = try optionalU32(obj, "max_output_tokens");
    const temperature = try optionalF32(obj, "temperature");
    const top_p = try optionalF32(obj, "top_p");
    const stream = try oap_envelope.optionalBool(obj, "stream") orelse true;

    const degraded = if (obj.get("allow_degraded_features") != null)
        try oap_envelope.deserializeStringArray(obj, "allow_degraded_features", allocator)
    else
        &.{};
    errdefer types.freeStringList(allocator, degraded);

    const owned_tools = try tools.toOwnedSlice(allocator);

    return types.Payload{ .inference_create_request = .{
        .model_ref = model_ref,
        .messages = messages,
        .tools = owned_tools,
        .tool_choice = tool_choice,
        .max_output_tokens = max_output_tokens,
        .temperature = temperature,
        .top_p = top_p,
        .output_schema_json = output_schema,
        .stream = stream,
        .reasoning = reasoning,
        .include_snapshot = include_snapshot,
        .headers = headers,
        .credential_ref = credential_ref,
        .metadata_json = metadata,
        .allow_degraded_features = degraded,
    } };
}

fn deserializeDescribeResponse(obj: std.json.ObjectMap, allocator: std.mem.Allocator) !types.Payload {
    const providers_value = obj.get("providers") orelse return DecodeError.MissingField;
    if (providers_value != .array) return DecodeError.InvalidField;

    var providers = std.ArrayList(types.ProviderDescriptor).empty;
    errdefer {
        for (providers.items) |*descriptor| descriptor.deinit(allocator);
        providers.deinit(allocator);
    }

    for (providers_value.array.items) |item| {
        if (item != .object) return DecodeError.InvalidField;
        const descriptor_obj = item.object;

        const id = try oap_envelope.requiredOwnedString(descriptor_obj, "id", allocator);
        errdefer allocator.free(id);
        const display_name = try oap_envelope.optionalOwnedString(descriptor_obj, "display_name", allocator);
        errdefer if (display_name) |value| allocator.free(value);
        const wire = try oap_envelope.requiredEnum(types.Wire, descriptor_obj, "wire");
        const wire_id = try oap_envelope.optionalOwnedString(descriptor_obj, "wire_id", allocator);
        errdefer if (wire_id) |value| allocator.free(value);
        if (wire_id != null and wire != .other) return DecodeError.InvalidField;
        const framing = try oap_envelope.requiredEnum(types.Framing, descriptor_obj, "framing");
        const endpoint = try oap_envelope.requiredOwnedString(descriptor_obj, "endpoint", allocator);
        errdefer allocator.free(endpoint);
        const headers = try deserializeHeaders(descriptor_obj, allocator, true);
        errdefer types.freeHeaders(allocator, headers);
        const compatibility = try deserializeCompatibility(descriptor_obj);

        var policies = std.ArrayList(types.SnapshotPolicy).empty;
        errdefer policies.deinit(allocator);
        const answers_sync = try oap_envelope.optionalBool(descriptor_obj, "answers_sync") orelse false;
        if (descriptor_obj.get("snapshot_policies")) |list_value| {
            if (list_value != .array) return DecodeError.InvalidField;
            for (list_value.array.items) |policy_item| {
                if (policy_item != .string) return DecodeError.InvalidField;
                const policy = types.SnapshotPolicy.parse(policy_item.string) orelse return DecodeError.InvalidField;
                try policies.append(allocator, policy);
            }
        }

        const credential_grant = try oap_envelope.optionalEnum(types.CredentialGrantChannel, descriptor_obj, "credential_grant") orelse .none;
        const allows_anonymous = try oap_envelope.optionalBool(descriptor_obj, "allows_anonymous") orelse false;
        const round_trips_carry = try oap_envelope.optionalBool(descriptor_obj, "round_trips_carry") orelse false;
        const context_window = try optionalU32(descriptor_obj, "context_window");
        const max_output_tokens = try optionalU32(descriptor_obj, "max_output_tokens");
        const grant_kinds = try deserializeGrantKinds(descriptor_obj, allocator);
        errdefer allocator.free(grant_kinds);
        const owned_policies = try policies.toOwnedSlice(allocator);
        errdefer allocator.free(owned_policies);

        try providers.append(allocator, .{
            .id = id,
            .display_name = display_name,
            .wire = wire,
            .wire_id = wire_id,
            .framing = framing,
            .endpoint = endpoint,
            .headers = headers,
            .compatibility = compatibility,
            .snapshot_policies = owned_policies,
            .answers_sync = answers_sync,
            .credential_grant = credential_grant,
            .grant_kinds = grant_kinds,
            .allows_anonymous = allows_anonymous,
            .round_trips_carry = round_trips_carry,
            .context_window = context_window,
            .max_output_tokens = max_output_tokens,
        });
    }

    const versions = if (obj.get("protocol_versions") != null)
        try oap_envelope.deserializeStringArray(obj, "protocol_versions", allocator)
    else
        &.{};
    errdefer types.freeStringList(allocator, versions);

    const profile_revision = try oap_envelope.optionalOwnedString(obj, "profile_revision", allocator);
    errdefer if (profile_revision) |value| allocator.free(value);

    const owned_providers = try providers.toOwnedSlice(allocator);

    return types.Payload{ .provider_describe_response = .{
        .providers = owned_providers,
        .protocol_versions = versions,
        .profile_revision = profile_revision,
    } };
}

fn deserializeModelsListResponse(obj: std.json.ObjectMap, allocator: std.mem.Allocator) !types.Payload {
    const models_value = obj.get("models") orelse return DecodeError.MissingField;
    if (models_value != .array) return DecodeError.InvalidField;

    var models = std.ArrayList(types.ModelEntry).empty;
    errdefer {
        for (models.items) |*entry| entry.deinit(allocator);
        models.deinit(allocator);
    }

    for (models_value.array.items) |item| {
        if (item != .object) return DecodeError.InvalidField;
        const entry_obj = item.object;

        const model_ref = try oap_envelope.requiredOwnedString(entry_obj, "model_ref", allocator);
        errdefer allocator.free(model_ref);
        const model_id = try oap_envelope.requiredOwnedString(entry_obj, "model_id", allocator);
        errdefer allocator.free(model_id);
        const display_name = try oap_envelope.optionalOwnedString(entry_obj, "display_name", allocator);
        errdefer if (display_name) |value| allocator.free(value);
        const provider_id = try oap_envelope.requiredOwnedString(entry_obj, "provider_id", allocator);
        errdefer allocator.free(provider_id);
        const wire = try oap_envelope.requiredEnum(types.Wire, entry_obj, "wire");

        var capabilities = std.ArrayList(types.ModelCapability).empty;
        errdefer capabilities.deinit(allocator);
        if (entry_obj.get("capabilities")) |caps_value| {
            if (caps_value != .array) return DecodeError.InvalidField;
            for (caps_value.array.items) |cap_item| {
                if (cap_item != .string) return DecodeError.InvalidField;
                const capability = types.ModelCapability.parse(cap_item.string) orelse return DecodeError.InvalidField;
                try capabilities.append(allocator, capability);
            }
        }

        const context_window = try optionalU32(entry_obj, "context_window");
        const max_output_tokens = try optionalU32(entry_obj, "max_output_tokens");
        const lifecycle = try oap_envelope.optionalEnum(types.ModelLifecycle, entry_obj, "lifecycle") orelse .stable;
        const source = try oap_envelope.optionalEnum(types.ModelSource, entry_obj, "source") orelse .discovered;
        const reasoning_default = try oap_envelope.optionalEnum(types.ReasoningLevel, entry_obj, "reasoning_default");
        const auth_status = try oap_envelope.optionalEnum(types.AuthStatus, entry_obj, "auth_status") orelse .unknown;
        const owned_capabilities = try capabilities.toOwnedSlice(allocator);
        errdefer allocator.free(owned_capabilities);

        try models.append(allocator, .{
            .model_ref = model_ref,
            .model_id = model_id,
            .display_name = display_name,
            .provider_id = provider_id,
            .wire = wire,
            .context_window = context_window,
            .max_output_tokens = max_output_tokens,
            .capabilities = owned_capabilities,
            .lifecycle = lifecycle,
            .source = source,
            .reasoning_default = reasoning_default,
            .auth_status = auth_status,
        });
    }

    return types.Payload{ .provider_models_list_response = .{
        .models = try models.toOwnedSlice(allocator),
    } };
}

fn expectRoundTrip(allocator: std.mem.Allocator, env: types.Envelope) !types.Envelope {
    const line = try serializeEnvelope(env, allocator);
    defer allocator.free(line);
    return try deserializeEnvelope(line, allocator);
}

test "a grant response cannot grant and refuse at the same time" {
    const allocator = std.testing.allocator;

    const cases = [_]struct { payload: []const u8, expected: DecodeError }{
        .{
            .payload = "{\"accepted\":true,\"credential_ref\":\"cr1\",\"error\":{\"code\":\"credential_rejected\",\"message\":\"no\"}}",
            .expected = DecodeError.InvalidField,
        },
        .{ .payload = "{\"accepted\":false}", .expected = DecodeError.MissingField },
    };
    for (cases) |case| {
        const line = try std.fmt.allocPrint(
            allocator,
            "{{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"{s}\",\"type\":\"provider.credential.grant.response\",\"id\":\"g3\",\"payload\":{s}}}",
            .{ types.PROFILE, case.payload },
        );
        defer allocator.free(line);
        try std.testing.expectError(case.expected, deserializeEnvelope(line, allocator));
    }
}

test "a create response cannot accept and refuse at the same time, and a refusal honours nothing" {
    const allocator = std.testing.allocator;

    const cases = [_]struct { scope: []const u8, payload: []const u8, expected: DecodeError }{
        .{
            .scope = ",\"inference_id\":\"0123456789abcdef0123456789abcdef\"",
            .payload = "{\"accepted\":true,\"error\":{\"code\":\"invalid_request\"," ++
                "\"message\":\"a message long enough to allocate\"}}",
            .expected = DecodeError.InvalidField,
        },
        .{ .scope = "", .payload = "{\"accepted\":false}", .expected = DecodeError.MissingField },
        .{
            .scope = "",
            .payload = "{\"accepted\":false,\"honoured\":{\"include_snapshot\":\"never\"}," ++
                "\"error\":{\"code\":\"invalid_request\",\"message\":\"a message long enough to allocate\"}}",
            .expected = DecodeError.InvalidField,
        },
    };
    for (cases) |case| {
        const line = try std.fmt.allocPrint(
            allocator,
            "{{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"{s}\"," ++
                "\"type\":\"inference.create.response\",\"id\":\"c1\",\"in_reply_to\":\"q1\"{s}," ++
                "\"payload\":{s}}}",
            .{ types.PROFILE, case.scope, case.payload },
        );
        defer allocator.free(line);
        try std.testing.expectError(case.expected, deserializeEnvelope(line, allocator));
    }

    const coherent =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"inference.create.response\",\"id\":\"c1\",\"in_reply_to\":\"q1\"," ++
        "\"inference_id\":\"0123456789abcdef0123456789abcdef\"," ++
        "\"payload\":{\"accepted\":true,\"honoured\":{\"include_snapshot\":\"on_part_end\"}}}";
    var decoded = try deserializeEnvelope(coherent, allocator);
    defer decoded.deinit(allocator);
    try std.testing.expect(decoded.payload.inference_create_response.accepted);
    try std.testing.expectEqual(types.SnapshotPolicy.on_part_end, decoded.payload.inference_create_response.honoured.?);
}

test "a tool call keeps its carry through whichever snapshot encoding it uses" {
    const allocator = std.testing.allocator;

    const forms = [_][]const u8{
        "{\"type\":\"tool_call\",\"tool_call_id\":\"c1\",\"name\":\"search\",\"arguments_json\":\"{}\",\"carry\":\"TOOL-SIG\"}",
        "{\"type\":\"tool_call\",\"tool_call_id\":\"c1\",\"name\":\"search\",\"arguments_partial\":\"{\\\"q\\\":\",\"carry\":\"TOOL-SIG\"}",
    };

    for (forms) |raw| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        var part = try deserializeSnapshotPart(parsed.value, allocator, true);
        defer part.deinit(allocator);
        try std.testing.expectEqualStrings("TOOL-SIG", part.tool_call.carry orelse "");
    }
}

test "a tool call part start carries identity and a text part start refuses it" {
    const allocator = std.testing.allocator;

    var env = types.Envelope{
        .id = try allocator.dupe(u8, "m1"),
        .inference_id = try allocator.dupe(u8, "inf1"),
        .sequence = 4,
        .payload = .{ .inference_part_started = .{
            .part_index = 2,
            .part_kind = .tool_call,
            .tool_call_id = try allocator.dupe(u8, "call_7"),
            .name = try allocator.dupe(u8, "search"),
        } },
    };
    defer env.deinit(allocator);

    var decoded = try expectRoundTrip(allocator, env);
    defer decoded.deinit(allocator);

    const started = decoded.payload.inference_part_started;
    try std.testing.expectEqual(types.PartKind.tool_call, started.part_kind);
    try std.testing.expectEqualStrings("call_7", started.tool_call_id.?);
    try std.testing.expectEqualStrings("search", started.name.?);

    const missing_identity =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"inference.part.started\",\"id\":\"m2\",\"inference_id\":\"inf1\",\"sequence\":1," ++
        "\"payload\":{\"part_index\":0,\"part_kind\":\"tool_call\"}}";
    try std.testing.expectError(DecodeError.MissingField, deserializeEnvelope(missing_identity, allocator));

    const text_with_identity =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"inference.part.started\",\"id\":\"m3\",\"inference_id\":\"inf1\",\"sequence\":1," ++
        "\"payload\":{\"part_index\":0,\"part_kind\":\"text\",\"tool_call_id\":\"x\",\"name\":\"y\"}}";
    try std.testing.expectError(DecodeError.InvalidField, deserializeEnvelope(text_with_identity, allocator));
}

test "a part end is kind discriminated between a string and a complete tool call" {
    const allocator = std.testing.allocator;

    var text_env = types.Envelope{
        .id = try allocator.dupe(u8, "m1"),
        .inference_id = try allocator.dupe(u8, "inf1"),
        .sequence = 5,
        .payload = .{ .inference_part_ended = .{
            .part_index = 0,
            .part_kind = .text,
            .text = try allocator.dupe(u8, "hello there"),
        } },
    };
    defer text_env.deinit(allocator);

    var text_decoded = try expectRoundTrip(allocator, text_env);
    defer text_decoded.deinit(allocator);
    try std.testing.expectEqualStrings("hello there", text_decoded.payload.inference_part_ended.text.?);
    try std.testing.expect(text_decoded.payload.inference_part_ended.tool_call == null);

    var call_env = types.Envelope{
        .id = try allocator.dupe(u8, "m2"),
        .inference_id = try allocator.dupe(u8, "inf1"),
        .sequence = 6,
        .payload = .{ .inference_part_ended = .{
            .part_index = 1,
            .part_kind = .tool_call,
            .tool_call = .{
                .tool_call_id = try allocator.dupe(u8, "call_7"),
                .name = try allocator.dupe(u8, "search"),
                .arguments_json = try allocator.dupe(u8, "{\"q\":\"zig\"}"),
            },
        } },
    };
    defer call_env.deinit(allocator);

    var call_decoded = try expectRoundTrip(allocator, call_env);
    defer call_decoded.deinit(allocator);
    const ended = call_decoded.payload.inference_part_ended;
    try std.testing.expect(ended.text == null);
    try std.testing.expectEqualStrings("call_7", ended.tool_call.?.tool_call_id);
    try std.testing.expectEqualStrings("{\"q\":\"zig\"}", ended.tool_call.?.arguments_json);
}

test "a scoped event without a contiguous sequence or an inference id is refused" {
    const allocator = std.testing.allocator;

    const no_sequence =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"inference.started\",\"id\":\"m1\",\"inference_id\":\"inf1\"," ++
        "\"payload\":{\"model_ref\":\"p/openai-responses@m\",\"started_at_ms\":1}}";
    try std.testing.expectError(DecodeError.InvalidField, deserializeEnvelope(no_sequence, allocator));

    const zero_sequence =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"inference.started\",\"id\":\"m1\",\"inference_id\":\"inf1\",\"sequence\":0," ++
        "\"payload\":{\"model_ref\":\"p/openai-responses@m\",\"started_at_ms\":1}}";
    try std.testing.expectError(DecodeError.InvalidField, deserializeEnvelope(zero_sequence, allocator));

    const no_inference_id =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"inference.started\",\"id\":\"m1\",\"sequence\":1," ++
        "\"payload\":{\"model_ref\":\"p/openai-responses@m\",\"started_at_ms\":1}}";
    try std.testing.expectError(DecodeError.MissingField, deserializeEnvelope(no_inference_id, allocator));
}

test "a credential in call headers is refused and a tenancy header is not" {
    const allocator = std.testing.allocator;

    const prefix =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"inference.create.request\",\"id\":\"m1\",\"payload\":{\"model_ref\":\"p/ollama@m\",\"messages\":[],\"headers\":";

    const named = prefix ++ "{\"Authorization\":\"whatever\"}}}";
    try std.testing.expectError(DecodeError.CredentialInHeaders, deserializeEnvelope(named, allocator));

    const bearer_shaped = prefix ++ "{\"X-Custom\":\"Bearer sk-abc\"}}}";
    try std.testing.expectError(DecodeError.CredentialInHeaders, deserializeEnvelope(bearer_shaped, allocator));

    const tenancy = prefix ++ "{\"X-Tenant\":\"acme\"}}}";
    var decoded = try deserializeEnvelope(tenancy, allocator);
    defer decoded.deinit(allocator);
    const headers = decoded.payload.inference_create_request.headers;
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings("X-Tenant", headers[0].name);
}

test "a descriptor carries its ordinary headers through a decode" {
    const allocator = std.testing.allocator;

    const line =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"provider.describe.response\",\"id\":\"m1\",\"capability_revision\":\"r1\",\"payload\":{" ++
        "\"providers\":[{\"id\":\"gw\",\"wire\":\"openai-chat-completions\",\"framing\":\"sse\"," ++
        "\"endpoint\":\"https://gw.test\",\"headers\":{\"X-Tenant\":\"acme\"}}]}}";

    var decoded = try deserializeEnvelope(line, allocator);
    defer decoded.deinit(allocator);
    const descriptor = decoded.payload.provider_describe_response.providers[0];
    try std.testing.expectEqualStrings("X-Tenant", descriptor.headers[0].name);
    try std.testing.expectEqual(types.Framing.sse, descriptor.framing);
}

test "a descriptor may not publish a credential in its headers" {
    const allocator = std.testing.allocator;

    const prefix =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"provider.describe.response\",\"id\":\"m1\",\"capability_revision\":\"r1\",\"payload\":{" ++
        "\"providers\":[{\"id\":\"gw\",\"wire\":\"openai-chat-completions\",\"framing\":\"sse\"," ++
        "\"endpoint\":\"https://gw.test\",\"headers\":";

    const named = prefix ++ "{\"Authorization\":\"whatever\"}}]}}";
    try std.testing.expectError(DecodeError.CredentialInHeaders, deserializeEnvelope(named, allocator));

    const bearer_shaped = prefix ++ "{\"X-Gateway\":\"Bearer sk-abc\"}}]}}";
    try std.testing.expectError(DecodeError.CredentialInHeaders, deserializeEnvelope(bearer_shaped, allocator));
}

test "the decoder refuses a foreign protocol, version and envelope shape" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(DecodeError.InvalidEnvelope, deserializeEnvelope("[]", allocator));
    try std.testing.expectError(DecodeError.InvalidEnvelope, deserializeEnvelope("\"x\"", allocator));

    const foreign_protocol =
        "{\"protocol\":\"other-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"inference.started\",\"id\":\"m1\",\"inference_id\":\"inf1\",\"sequence\":1,\"payload\":{}}";
    try std.testing.expectError(DecodeError.ProtocolMismatch, deserializeEnvelope(foreign_protocol, allocator));

    const foreign_version =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"9.9\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"inference.started\",\"id\":\"m1\",\"inference_id\":\"inf1\",\"sequence\":1,\"payload\":{}}";
    try std.testing.expectError(DecodeError.VersionMismatch, deserializeEnvelope(foreign_version, allocator));
}

test "a wire id rides only with the unnamed wire" {
    const allocator = std.testing.allocator;

    const head =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"provider.describe.response\",\"id\":\"m\",\"capability_revision\":\"r1\",\"payload\":{" ++
        "\"providers\":[{\"id\":\"g\",\"framing\":\"sse\",\"endpoint\":\"https://g.test\",";

    const named_with_id = head ++ "\"wire\":\"openai-chat-completions\",\"wire_id\":\"nope\"}]}}";
    try std.testing.expectError(DecodeError.InvalidField, deserializeEnvelope(named_with_id, allocator));

    const unnamed_with_id = head ++ "\"wire\":\"other\",\"wire_id\":\"ollama-chat\"}]}}";
    var decoded = try deserializeEnvelope(unnamed_with_id, allocator);
    defer decoded.deinit(allocator);
    const descriptor = decoded.payload.provider_describe_response.providers[0];
    try std.testing.expectEqual(types.Wire.other, descriptor.wire);
    try std.testing.expectEqualStrings("ollama-chat", descriptor.wire_id.?);
}

test "a payload member the profile does not define is refused" {
    const allocator = std.testing.allocator;

    const head =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++ "\",";

    const create_with_endpoint = head ++
        "\"type\":\"inference.create.request\",\"id\":\"m\",\"payload\":{\"model_ref\":\"p/ollama@m\"," ++
        "\"messages\":[],\"endpoint\":\"https://attacker.test\"}}";
    try std.testing.expectError(DecodeError.UnknownField, deserializeEnvelope(create_with_endpoint, allocator));

    const create_with_base_url = head ++
        "\"type\":\"inference.create.request\",\"id\":\"m\",\"payload\":{\"model_ref\":\"p/ollama@m\"," ++
        "\"messages\":[],\"base_url\":\"https://attacker.test\"}}";
    try std.testing.expectError(DecodeError.UnknownField, deserializeEnvelope(create_with_base_url, allocator));

    const describe_with_extra = head ++
        "\"type\":\"provider.describe.response\",\"id\":\"m\",\"payload\":{\"providers\":[],\"nonsense\":1}}";
    try std.testing.expectError(DecodeError.UnknownField, deserializeEnvelope(describe_with_extra, allocator));

    const accepted = head ++
        "\"type\":\"inference.create.request\",\"id\":\"m\",\"payload\":{\"model_ref\":\"p/ollama@m\"," ++
        "\"messages\":[],\"metadata\":{\"k\":\"v\"},\"temperature\":0.5}}";
    var decoded = try deserializeEnvelope(accepted, allocator);
    decoded.deinit(allocator);
}

const Refusal = struct { line: []const u8, want: DecodeError };

test "every required member and closed vocabulary is refused when it is absent or wrong" {
    const allocator = std.testing.allocator;
    const h = "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++ "\",";
    const scope = "\"inference_id\":\"i\",\"sequence\":1,";

    const cases = [_]Refusal{
        .{ .line = h ++ "\"type\":\"inference.started\",\"id\":\"m\"," ++ scope ++ "\"payload\":{}}", .want = DecodeError.MissingField },
        .{ .line = h ++ "\"type\":\"inference.started\",\"id\":\"m\"," ++ scope ++ "\"payload\":{\"model_ref\":\"p/ollama@m\"}}", .want = DecodeError.MissingField },
        .{ .line = h ++ "\"type\":\"provider.describe.request\",\"id\":\"m\"}", .want = DecodeError.MissingField },
        .{ .line = h ++ "\"type\":\"nonsense.type\",\"id\":\"m\",\"payload\":{}}", .want = DecodeError.UnknownEnvelopeType },
        .{ .line = h ++ "\"type\":\"inference.create.request\",\"id\":\"m\",\"payload\":{\"model_ref\":\"p/ollama@m\"}}", .want = DecodeError.MissingField },
        .{ .line = h ++ "\"type\":\"inference.completed\",\"id\":\"m\"," ++ scope ++ "\"payload\":{}}", .want = DecodeError.MissingField },
        .{ .line = h ++ "\"type\":\"inference.failed\",\"id\":\"m\"," ++ scope ++ "\"payload\":{}}", .want = DecodeError.MissingField },
        .{ .line = h ++ "\"type\":\"error\",\"id\":\"m\",\"payload\":{}}", .want = DecodeError.MissingField },
        .{ .line = h ++ "\"type\":\"inference.part.started\",\"id\":\"m\"," ++ scope ++ "\"payload\":{\"part_kind\":\"text\"}}", .want = DecodeError.MissingField },
        .{ .line = h ++ "\"type\":\"inference.part.ended\",\"id\":\"m\"," ++ scope ++ "\"payload\":{\"part_index\":0,\"part_kind\":\"tool_call\"}}", .want = DecodeError.MissingField },
        .{ .line = h ++ "\"type\":\"inference.part.ended\",\"id\":\"m\"," ++ scope ++ "\"payload\":{\"part_index\":0,\"part_kind\":\"tool_call\",\"tool_call\":{\"tool_call_id\":\"c\",\"name\":\"n\"}}}", .want = DecodeError.MissingField },
        .{ .line = h ++ "\"type\":\"provider.describe.response\",\"id\":\"m\",\"payload\":{}}", .want = DecodeError.MissingField },
        .{ .line = h ++ "\"type\":\"provider.models.list.response\",\"id\":\"m\",\"payload\":{}}", .want = DecodeError.MissingField },
        .{ .line = h ++ "\"type\":\"inference.sync.response\",\"id\":\"m\"," ++ scope ++ "\"payload\":{\"snapshot\":[{\"role\":\"assistant\"}]}}", .want = DecodeError.MissingField },
        .{ .line = h ++ "\"type\":\"provider.describe.response\",\"id\":\"m\",\"payload\":{\"providers\":[{\"id\":\"g\",\"wire\":\"other\",\"wire_id\":\"x\",\"framing\":\"sse\",\"endpoint\":\"e\",\"grant_kinds\":[\"nope\"]}]}}", .want = DecodeError.InvalidField },
        .{ .line = h ++ "\"type\":\"provider.describe.response\",\"id\":\"m\",\"payload\":{\"providers\":[{\"id\":\"g\",\"wire\":\"other\",\"wire_id\":\"x\",\"framing\":\"sse\",\"endpoint\":\"e\",\"snapshot_policies\":[\"nope\"]}]}}", .want = DecodeError.InvalidField },
        .{ .line = h ++ "\"type\":\"provider.models.list.response\",\"id\":\"m\",\"payload\":{\"models\":[{\"model_ref\":\"g/other:x@m\",\"model_id\":\"m\",\"provider_id\":\"g\",\"wire\":\"other\",\"capabilities\":[\"nope\"]}]}}", .want = DecodeError.InvalidField },
    };

    for (cases, 0..) |case, index| {
        const decoded = deserializeEnvelope(case.line, allocator);
        if (decoded) |env| {
            var owned = env;
            owned.deinit(allocator);
            std.debug.print("\ncase {d} was accepted but should be {s}\n  {s}\n", .{ index, @errorName(case.want), case.line });
            return error.RefusalMissing;
        } else |err| {
            if (err != case.want) {
                std.debug.print("\ncase {d} expected {s}, found {s}\n  {s}\n", .{ index, @errorName(case.want), @errorName(err), case.line });
                return error.WrongRefusal;
            }
        }
    }
}

test "a carry round trip claim survives the wire and defaults to absent" {
    const allocator = std.testing.allocator;

    var decoded = try deserializeEnvelope(DESCRIBE_RESPONSE_LINE, allocator);
    defer decoded.deinit(allocator);
    try std.testing.expect(!decoded.payload.provider_describe_response.providers[0].round_trips_carry);

    var env = types.Envelope{
        .id = try allocator.dupe(u8, "m1"),
        .payload = .{ .provider_describe_response = .{
            .providers = try allocator.dupe(types.ProviderDescriptor, &.{.{
                .id = try allocator.dupe(u8, "gw"),
                .wire = .@"anthropic-messages",
                .framing = .sse,
                .endpoint = try allocator.dupe(u8, "https://gw.test"),
                .round_trips_carry = true,
            }}),
        } },
    };
    defer env.deinit(allocator);

    var round_tripped = try expectRoundTrip(allocator, env);
    defer round_tripped.deinit(allocator);
    try std.testing.expect(round_tripped.payload.provider_describe_response.providers[0].round_trips_carry);
}

fn expectNoLeakUnderAllocationFailure(line: []const u8) !void {
    var index: usize = 0;
    while (index < 512) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        const allocator = failing.allocator();
        if (deserializeEnvelope(line, allocator)) |decoded| {
            var owned = decoded;
            owned.deinit(allocator);
        } else |_| {}
    }
}

const DESCRIBE_RESPONSE_LINE =
    "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
    "\",\"type\":\"provider.describe.response\",\"id\":\"m1\",\"capability_revision\":\"r1\",\"payload\":{" ++
    "\"providers\":[{\"id\":\"gw\",\"display_name\":\"Gateway\",\"wire\":\"other\",\"wire_id\":\"ollama-chat\"," ++
    "\"framing\":\"ndjson\",\"endpoint\":\"https://gw.test\",\"headers\":{\"X-Tenant\":\"acme\"}," ++
    "\"snapshot_policies\":[\"never\",\"on_part_end\",\"every_delta\"],\"answers_sync\":true," ++
    "\"credential_grant\":\"out_of_band\",\"grant_kinds\":[\"static\",\"refreshable\"]," ++
    "\"allows_anonymous\":false,\"context_window\":128000,\"max_output_tokens\":8192}]," ++
    "\"protocol_versions\":[\"0.1\"]}}";

const MODELS_LIST_RESPONSE_LINE =
    "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
    "\",\"type\":\"provider.models.list.response\",\"id\":\"m1\",\"payload\":{\"models\":[{" ++
    "\"model_ref\":\"gw/other:ollama-chat@llama3\",\"model_id\":\"llama3\",\"display_name\":\"Llama 3\"," ++
    "\"provider_id\":\"gw\",\"wire\":\"other\",\"context_window\":128000,\"max_output_tokens\":8192," ++
    "\"capabilities\":[\"chat\",\"streaming\"],\"lifecycle\":\"stable\",\"source\":\"discovered\"," ++
    "\"reasoning_default\":\"medium\",\"auth_status\":\"authenticated\"}]}}";

test "a describe response decode leaks nothing when an allocation fails" {
    try expectNoLeakUnderAllocationFailure(DESCRIBE_RESPONSE_LINE);
}

test "a models list decode leaks nothing when an allocation fails" {
    try expectNoLeakUnderAllocationFailure(MODELS_LIST_RESPONSE_LINE);
}

test "a field of the wrong json type is refused rather than reached into" {
    const allocator = std.testing.allocator;

    const head =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++ "\",";

    const cases = [_][]const u8{
        head ++ "\"type\":\"inference.started\",\"id\":\"m\",\"inference_id\":\"i\",\"sequence\":1,\"payload\":\"x\"}",
        head ++ "\"type\":\"provider.describe.response\",\"id\":\"m\",\"capability_revision\":\"r1\",\"payload\":{\"providers\":\"x\"}}",
        head ++ "\"type\":\"provider.describe.response\",\"id\":\"m\",\"capability_revision\":\"r1\",\"payload\":{\"providers\":[{\"id\":\"g\",\"wire\":\"openai-chat-completions\",\"framing\":\"sse\",\"endpoint\":\"https://g.test\",\"headers\":\"x\"}]}}",
        head ++ "\"type\":\"provider.describe.response\",\"id\":\"m\",\"capability_revision\":\"r1\",\"payload\":{\"providers\":[{\"id\":\"g\",\"wire\":\"openai-chat-completions\",\"framing\":\"sse\",\"endpoint\":\"https://g.test\",\"headers\":{\"X-A\":1}}]}}",
        head ++ "\"type\":\"provider.describe.response\",\"id\":\"m\",\"capability_revision\":\"r1\",\"payload\":{\"providers\":[{\"id\":\"g\",\"wire\":\"openai-chat-completions\",\"framing\":\"sse\",\"endpoint\":\"https://g.test\",\"compatibility\":\"x\"}]}}",
        head ++ "\"type\":\"provider.describe.response\",\"id\":\"m\",\"capability_revision\":\"r1\",\"payload\":{\"providers\":[{\"id\":\"g\",\"wire\":\"openai-chat-completions\",\"framing\":\"sse\",\"endpoint\":\"https://g.test\",\"compatibility\":{\"tool_call_id_format\":1}}]}}",
        head ++ "\"type\":\"provider.describe.response\",\"id\":\"m\",\"capability_revision\":\"r1\",\"payload\":{\"providers\":[{\"id\":\"g\",\"wire\":\"openai-chat-completions\",\"framing\":\"sse\",\"endpoint\":\"https://g.test\",\"grant_kinds\":\"x\"}]}}",
        head ++ "\"type\":\"provider.models.list.response\",\"id\":\"m\",\"payload\":{\"models\":\"x\"}}",
        head ++ "\"type\":\"inference.create.request\",\"id\":\"m\",\"payload\":{\"model_ref\":\"p/ollama@m\",\"messages\":\"x\"}}",
        head ++ "\"type\":\"inference.create.request\",\"id\":\"m\",\"payload\":{\"model_ref\":\"p/ollama@m\",\"messages\":[],\"tools\":\"x\"}}",
        head ++ "\"type\":\"inference.create.request\",\"id\":\"m\",\"payload\":{\"model_ref\":\"p/ollama@m\",\"messages\":[],\"reasoning\":\"x\"}}",
        head ++ "\"type\":\"inference.part.started\",\"id\":\"m\",\"inference_id\":\"i\",\"sequence\":1,\"payload\":{\"part_index\":4294967296,\"part_kind\":\"text\"}}",
    };

    for (cases) |line| {
        const decoded = deserializeEnvelope(line, allocator);
        if (decoded) |env| {
            var owned = env;
            owned.deinit(allocator);
            std.debug.print("\naccepted a malformed frame: {s}\n", .{line});
            return error.MalformedFrameAccepted;
        } else |err| {
            if (err != DecodeError.InvalidField) {
                std.debug.print("\n{s}\n  expected InvalidField, found {s}\n", .{ line, @errorName(err) });
                return error.WrongRefusal;
            }
        }
    }
}

test "all twelve compatibility facts survive a round trip" {
    const allocator = std.testing.allocator;

    var env = types.Envelope{
        .id = try allocator.dupe(u8, "m1"),
        .payload = .{ .provider_describe_response = .{
            .providers = try allocator.dupe(types.ProviderDescriptor, &.{.{
                .id = try allocator.dupe(u8, "acme"),
                .wire = .@"anthropic-messages",
                .framing = .ndjson,
                .endpoint = try allocator.dupe(u8, "https://acme.test"),
                .compatibility = .{
                    .max_tokens_field = .max_completion_tokens,
                    .thinking_format = .qwen,
                    .usage_in_streaming = .terminal_only,
                    .requires_assistant_after_tool_result = true,
                    .requires_tool_result_name = false,
                    .requires_thinking_as_text = true,
                    .supports_strict_mode = false,
                    .supports_store = true,
                    .supports_developer_role = false,
                    .supports_reasoning_effort = true,
                    .tool_call_id_format = .constrained,
                    .cache_ttl_control = true,
                },
            }}),

        } },
    };
    defer env.deinit(allocator);

    var decoded = try expectRoundTrip(allocator, env);
    defer decoded.deinit(allocator);

    const facts = decoded.payload.provider_describe_response.providers[0].compatibility;
    try std.testing.expectEqual(types.MaxTokensField.max_completion_tokens, facts.max_tokens_field.?);
    try std.testing.expectEqual(types.ThinkingFormat.qwen, facts.thinking_format.?);
    try std.testing.expectEqual(types.UsageInStreaming.terminal_only, facts.usage_in_streaming.?);
    try std.testing.expectEqual(true, facts.requires_assistant_after_tool_result.?);
    try std.testing.expectEqual(false, facts.requires_tool_result_name.?);
    try std.testing.expectEqual(true, facts.requires_thinking_as_text.?);
    try std.testing.expectEqual(false, facts.supports_strict_mode.?);
    try std.testing.expectEqual(true, facts.supports_store.?);
    try std.testing.expectEqual(false, facts.supports_developer_role.?);
    try std.testing.expectEqual(true, facts.supports_reasoning_effort.?);
    try std.testing.expectEqual(types.ToolCallIdFormat.constrained, facts.tool_call_id_format.?);
    try std.testing.expectEqual(true, facts.cache_ttl_control.?);
}

test "the agent control profile is refused on this wire" {
    const allocator = std.testing.allocator;
    const line =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ oap_types.PROFILE ++
        "\",\"type\":\"provider.describe.request\",\"id\":\"m1\",\"payload\":{}}";
    try std.testing.expectError(DecodeError.ProfileMismatch, deserializeEnvelope(line, allocator));
}

test "usage survives a round trip on both terminals" {
    const allocator = std.testing.allocator;

    var completed = types.Envelope{
        .id = try allocator.dupe(u8, "m1"),
        .inference_id = try allocator.dupe(u8, "inf1"),
        .sequence = 3,
        .payload = .{ .inference_completed = .{
            .message = .{ .role = .assistant, .content = .{ .text = try allocator.dupe(u8, "hi") } },
            .stop_reason = .stop,
            .usage = .{ .input_tokens = 11, .output_tokens = 5, .total_tokens = 16 },
        } },
    };
    defer completed.deinit(allocator);

    var decoded = try expectRoundTrip(allocator, completed);
    defer decoded.deinit(allocator);
    const usage = decoded.payload.inference_completed.usage.?;
    try std.testing.expectEqual(@as(u64, 11), usage.input_tokens.?);
    try std.testing.expectEqual(@as(u64, 5), usage.output_tokens.?);
    try std.testing.expectEqual(@as(u64, 16), usage.total_tokens.?);

    var failed = types.Envelope{
        .id = try allocator.dupe(u8, "m2"),
        .inference_id = try allocator.dupe(u8, "inf1"),
        .sequence = 4,
        .payload = .{ .inference_failed = .{
            .err = .{ .code = .rate_limited, .message = try allocator.dupe(u8, "slow down") },
            .usage = .{ .input_tokens = 7 },
        } },
    };
    defer failed.deinit(allocator);

    var failed_decoded = try expectRoundTrip(allocator, failed);
    defer failed_decoded.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 7), failed_decoded.payload.inference_failed.usage.?.input_tokens.?);
}

test "a malformed grant response frees what it decoded before refusing" {
    const allocator = std.testing.allocator;

    const accepted_without_reference =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"provider.credential.grant.response\",\"id\":\"m1\",\"in_reply_to\":\"q1\"," ++
        "\"payload\":{\"accepted\":true,\"error\":{\"code\":\"credential_rejected\",\"message\":\"a message long enough to allocate\"}}}";
    try std.testing.expectError(
        DecodeError.MissingField,
        deserializeEnvelope(accepted_without_reference, allocator),
    );

    const refusal_with_reference =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"provider.credential.grant.response\",\"id\":\"m1\",\"in_reply_to\":\"q1\"," ++
        "\"payload\":{\"accepted\":false,\"credential_ref\":\"grant:x:0\"," ++
        "\"error\":{\"code\":\"credential_rejected\",\"message\":\"a message long enough to allocate\"," ++
        "\"details\":{\"reason\":\"deadline\"}}}}";
    try std.testing.expectError(
        DecodeError.InvalidField,
        deserializeEnvelope(refusal_with_reference, allocator),
    );
}
