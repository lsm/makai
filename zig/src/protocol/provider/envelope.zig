const std = @import("std");
const compat = @import("compat");
pub const protocol_types = @import("protocol_types");
const ai_types = @import("ai_types");
const fields = @import("envelope_fields");
const json_writer = @import("json_writer");
const transport = @import("transport");

const OpenAICompatMaxTokensField = @typeInfo(@TypeOf((ai_types.OpenAICompatOptions{}).max_tokens_field)).optional.child;
const OpenAICompatThinkingFormat = @typeInfo(@TypeOf((ai_types.OpenAICompatOptions{}).thinking_format)).optional.child;

pub fn serializeEnvelope(
    envelope: protocol_types.Envelope,
    allocator: std.mem.Allocator,
) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);

    try w.beginObject();

    try w.writeKey("type");
    if (envelope.payload == .event) {
        try w.writeString(@tagName(envelope.payload.event));
    } else {
        const payload_type = @tagName(envelope.payload);
        try w.writeString(payload_type);
    }

    var stream_id_buffer: [26]u8 = undefined;
    const stream_id_str = protocol_types.ulidToBuffer(envelope.stream_id, &stream_id_buffer);
    try w.writeStringField("stream_id", stream_id_str);

    var message_id_buffer: [26]u8 = undefined;
    const message_id_str = protocol_types.ulidToBuffer(envelope.message_id, &message_id_buffer);
    try w.writeStringField("message_id", message_id_str);

    try w.writeIntField("sequence", envelope.sequence);

    try w.writeIntField("timestamp", envelope.timestamp);

    try w.writeIntField("version", envelope.version);

    if (envelope.in_reply_to) |reply_to| {
        var reply_to_buffer: [26]u8 = undefined;
        const reply_to_str = protocol_types.ulidToBuffer(reply_to, &reply_to_buffer);
        try w.writeStringField("in_reply_to", reply_to_str);
    }

    try w.writeKey("payload");
    try serializePayload(&w, envelope.payload, allocator);

    try w.endObject();

    return buffer.toOwnedSlice(allocator);
}

fn serializePayload(
    w: *json_writer.JsonWriter,
    payload: protocol_types.Payload,
    allocator: std.mem.Allocator,
) !void {
    try w.beginObject();

    switch (payload) {
        .ping => {},
        .pong => |pong| {
            try w.writeStringField("ping_id", pong.ping_id.slice());
        },
        .goodbye => |goodbye| {
            if (goodbye.getReason()) |reason| {
                try w.writeStringField("reason", reason);
            }
        },
        .sync_request => |sync_req| {
            var target_buffer: [26]u8 = undefined;
            const target_str = protocol_types.ulidToBuffer(sync_req.target_stream_id, &target_buffer);
            try w.writeStringField("target_stream_id", target_str);
        },
        .sync => |sync_msg| {
            var target_buffer: [26]u8 = undefined;
            const target_str = protocol_types.ulidToBuffer(sync_msg.target_stream_id, &target_buffer);
            try w.writeStringField("target_stream_id", target_str);
            if (sync_msg.partial) |partial| {
                try w.writeKey("partial");
                try serializeResultPayload(w, partial, allocator);
            }
        },
        .stream_request => |req| {
            try w.writeKey("model");
            try serializeModel(w, req.model);
            try w.writeBoolField("include_partial", req.include_partial);

            try w.writeKey("context");
            try serializeContext(w, req.context, allocator);

            if (req.options) |opts| {
                try w.writeKey("options");
                try serializeStreamOptions(w, opts, allocator);
            }
        },
        .complete_request => |req| {
            try w.writeKey("model");
            try serializeModel(w, req.model);

            try w.writeKey("context");
            try serializeContext(w, req.context, allocator);

            if (req.options) |opts| {
                try w.writeKey("options");
                try serializeStreamOptions(w, opts, allocator);
            }
        },
        .abort_request => |req| {
            var target_buffer: [26]u8 = undefined;
            const target_str = protocol_types.ulidToBuffer(req.target_stream_id, &target_buffer);
            try w.writeStringField("target_stream_id", target_str);
            if (req.getReason()) |reason| {
                try w.writeStringField("reason", reason);
            }
        },
        .ack => |ack| {
            var acknowledged_id_buffer: [26]u8 = undefined;
            const acknowledged_id_str = protocol_types.ulidToBuffer(ack.acknowledged_id, &acknowledged_id_buffer);
            try w.writeStringField("acknowledged_id", acknowledged_id_str);
        },
        .nack => |nack| {
            var rejected_id_buffer: [26]u8 = undefined;
            const rejected_id_str = protocol_types.ulidToBuffer(nack.rejected_id, &rejected_id_buffer);
            try w.writeStringField("rejected_id", rejected_id_str);
            try w.writeStringField("reason", nack.reason.slice());
            if (nack.error_code) |code| {
                try w.writeStringField("error_code", @tagName(code));
            }
            const versions = nack.supported_versions.slice();
            if (versions.len > 0) {
                try w.writeKey("supported_versions");
                try w.beginArray();
                for (versions) |v| {
                    try w.writeString(v.slice());
                }
                try w.endArray();
            }
        },
        .event => |event| {
            try serializeEventPayload(w, event, allocator);
        },
        .result => |result| {
            try serializeResultPayload(w, result, allocator);
        },
        .stream_error => |err| {
            try w.writeStringField("code", @tagName(err.code));
            try w.writeStringField("message", err.message.slice());
        },
        .models_request => |req| {
            if (req.getProviderId()) |provider_id| {
                try w.writeStringField("provider_id", provider_id);
            }
            if (req.getApi()) |api| {
                try w.writeStringField("api", api);
            }
            if (req.getModelId()) |model_id| {
                try w.writeStringField("model_id", model_id);
            }
            try w.writeBoolField("include_deprecated", req.include_deprecated);
            try w.writeBoolField("include_login_required", req.include_login_required);
        },
        .models_response => |res| {
            try w.writeIntField("fetched_at_ms", res.fetched_at_ms);
            try w.writeIntField("cache_max_age_ms", res.cache_max_age_ms);
            try w.writeKey("models");
            try w.beginArray();
            for (res.models.slice()) |model| {
                try serializeModelDescriptor(w, model);
            }
            try w.endArray();
        },
    }

    try w.endObject();
}

fn serializeModel(
    w: *json_writer.JsonWriter,
    model: ai_types.Model,
) !void {
    try w.beginObject();
    try w.writeStringField("id", model.id);
    try w.writeStringField("name", model.name);
    try w.writeStringField("api", model.api);
    try w.writeStringField("provider", model.provider);
    try w.writeStringField("base_url", model.base_url);
    try w.writeBoolField("reasoning", model.reasoning);
    if (model.allows_anonymous) try w.writeBoolField("allows_anonymous", true);

    try w.writeKey("input");
    try w.beginArray();
    for (model.input) |input| {
        try w.writeString(input);
    }
    try w.endArray();

    try w.writeKey("cost");
    try w.beginObject();
    try w.writeKey("input");
    try writeFloat64(w, model.cost.input);
    try w.writeKey("output");
    try writeFloat64(w, model.cost.output);
    try w.writeKey("cache_read");
    try writeFloat64(w, model.cost.cache_read);
    try w.writeKey("cache_write");
    try writeFloat64(w, model.cost.cache_write);
    try w.endObject();

    try w.writeIntField("context_window", model.context_window);
    try w.writeIntField("max_tokens", model.max_tokens);

    if (model.headers) |headers| {
        try serializeHeaderPairs(w, headers);
    }

    if (model.compat) |compat_options| {
        try serializeOpenAICompatOptions(w, compat_options);
    }

    try w.endObject();
}

fn writeFloat64(w: *json_writer.JsonWriter, value: f64) !void {
    if (w.needs_comma) {
        try w.buffer.append(w.allocator, ',');
    }
    try w.buffer.print(w.allocator, "{d}", .{value});
    w.needs_comma = true;
}

fn serializeHeaderPairs(
    w: *json_writer.JsonWriter,
    headers: []const ai_types.HeaderPair,
) !void {
    try w.writeKey("headers");
    try w.beginArray();
    for (headers) |header| {
        try w.beginObject();
        try w.writeStringField("name", header.name);
        try w.writeStringField("value", header.value);
        try w.endObject();
    }
    try w.endArray();
}

fn serializeOptionalBoolField(
    w: *json_writer.JsonWriter,
    field: []const u8,
    value: ?bool,
) !void {
    if (value) |unwrapped| {
        try w.writeBoolField(field, unwrapped);
    }
}

fn serializeOptionalTagField(
    w: *json_writer.JsonWriter,
    field: []const u8,
    value: anytype,
) !void {
    if (value) |unwrapped| {
        try w.writeStringField(field, @tagName(unwrapped));
    }
}

fn serializeOpenAICompatOptions(
    w: *json_writer.JsonWriter,
    compat_options: ai_types.OpenAICompatOptions,
) !void {
    try w.writeKey("compat");
    try w.beginObject();
    try serializeOptionalBoolField(w, "supports_store", compat_options.supports_store);
    try serializeOptionalBoolField(w, "supports_developer_role", compat_options.supports_developer_role);
    try serializeOptionalBoolField(w, "supports_reasoning_effort", compat_options.supports_reasoning_effort);
    try serializeOptionalBoolField(w, "supports_usage_in_streaming", compat_options.supports_usage_in_streaming);
    try serializeOptionalTagField(w, "max_tokens_field", compat_options.max_tokens_field);
    try serializeOptionalBoolField(w, "requires_tool_result_name", compat_options.requires_tool_result_name);
    try serializeOptionalBoolField(w, "requires_assistant_after_tool_result", compat_options.requires_assistant_after_tool_result);
    try serializeOptionalBoolField(w, "requires_thinking_as_text", compat_options.requires_thinking_as_text);
    try serializeOptionalBoolField(w, "requires_mistral_tool_ids", compat_options.requires_mistral_tool_ids);
    try serializeOptionalTagField(w, "thinking_format", compat_options.thinking_format);
    try serializeOptionalBoolField(w, "supports_strict_mode", compat_options.supports_strict_mode);
    try serializeOptionalBoolField(w, "supports_anthropic_cache_ttl", compat_options.supports_anthropic_cache_ttl);
    try w.endObject();
}

fn serializeContext(
    w: *json_writer.JsonWriter,
    context: ai_types.Context,
    allocator: std.mem.Allocator,
) !void {
    try w.beginObject();

    if (context.getSystemPrompt()) |prompt| {
        try w.writeStringField("system_prompt", prompt);
    }

    try w.writeKey("messages");
    try w.beginArray();
    for (context.messages) |msg| {
        try serializeMessage(w, msg, allocator);
    }
    try w.endArray();

    if (context.tools) |tools| {
        try w.writeKey("tools");
        try w.beginArray();
        for (tools) |tool| {
            try serializeTool(w, tool);
        }
        try w.endArray();
    }

    try w.endObject();
}

fn serializeMessage(
    w: *json_writer.JsonWriter,
    msg: ai_types.Message,
    allocator: std.mem.Allocator,
) !void {
    try w.beginObject();

    switch (msg) {
        .user => |user_msg| {
            try w.writeStringField("role", "user");
            try w.writeIntField("timestamp", user_msg.timestamp);
            try w.writeKey("content");
            try serializeUserContent(w, user_msg.content, allocator);
        },
        .assistant => |asst_msg| {
            try w.writeStringField("role", "assistant");
            try w.writeStringField("model", asst_msg.model);
            try w.writeStringField("api", asst_msg.api);
            try w.writeStringField("provider", asst_msg.provider);
            try w.writeIntField("timestamp", asst_msg.timestamp);
            try w.writeStringField("stop_reason", @tagName(asst_msg.stop_reason));

            try w.writeKey("usage");
            try w.beginObject();
            try w.writeIntField("input", asst_msg.usage.input);
            try w.writeIntField("output", asst_msg.usage.output);
            try w.writeIntField("cache_read", asst_msg.usage.cache_read);
            try w.writeIntField("cache_write", asst_msg.usage.cache_write);
            try w.endObject();

            try w.writeKey("content");
            try w.beginArray();
            for (asst_msg.content) |block| {
                try transport.serializeAssistantContent(w, block);
            }
            try w.endArray();
        },
        .tool_result => |tool_res| {
            try w.writeStringField("role", "tool");
            try w.writeStringField("tool_call_id", tool_res.tool_call_id);
            try w.writeStringField("tool_name", tool_res.tool_name);
            try w.writeIntField("timestamp", tool_res.timestamp);
            try w.writeBoolField("is_error", tool_res.is_error);

            try w.writeKey("content");
            try w.beginArray();
            for (tool_res.content) |part| {
                try serializeUserContentPart(w, part);
            }
            try w.endArray();

            if (tool_res.getDetailsJson()) |details| {
                try w.writeStringField("details_json", details);
            }
        },
    }

    try w.endObject();
}

fn serializeUserContent(
    w: *json_writer.JsonWriter,
    content: ai_types.UserContent,
    _: std.mem.Allocator,
) !void {
    switch (content) {
        .text => |text| {
            try w.writeString(text);
        },
        .parts => |parts| {
            try w.beginArray();
            for (parts) |part| {
                try serializeUserContentPart(w, part);
            }
            try w.endArray();
        },
    }
}

fn serializeUserContentPart(
    w: *json_writer.JsonWriter,
    part: ai_types.UserContentPart,
) !void {
    try w.beginObject();
    switch (part) {
        .text => |t| {
            try w.writeStringField("type", "text");
            try w.writeStringField("text", t.text);
            if (t.text_signature) |sig| {
                try w.writeStringField("text_signature", sig);
            }
        },
        .image => |img| {
            try w.writeStringField("type", "image");
            try w.writeStringField("data", img.data);
            try w.writeStringField("mime_type", img.mime_type);
        },
    }
    try w.endObject();
}

fn serializeTool(w: *json_writer.JsonWriter, tool: ai_types.Tool) !void {
    try w.beginObject();
    try w.writeStringField("name", tool.name);
    try w.writeStringField("description", tool.description);
    try w.writeKey("parameters_schema_json");
    try w.writeRawJson(tool.parameters_schema_json);
    try w.endObject();
}

fn serializeStreamOptions(
    w: *json_writer.JsonWriter,
    opts: ai_types.StreamOptions,
    _: std.mem.Allocator,
) !void {
    try w.beginObject();

    if (opts.getApiKey()) |key| {
        try w.writeStringField("api_key", key);
    }
    if (opts.temperature) |temp| {
        try w.writeKey("temperature");
        try w.writeFloat(temp);
    }
    if (opts.max_tokens) |max| {
        try w.writeIntField("max_tokens", max);
    }
    if (opts.cache_retention) |ret| {
        try w.writeStringField("cache_retention", @tagName(ret));
    }
    if (opts.getSessionId()) |sid| {
        try w.writeStringField("session_id", sid);
    }
    if (opts.thinking_enabled) {
        try w.writeBoolField("thinking_enabled", true);
    }
    if (opts.thinking_budget_tokens) |budget| {
        try w.writeIntField("thinking_budget_tokens", budget);
    }
    if (opts.getThinkingEffort()) |effort| {
        try w.writeStringField("thinking_effort", effort);
    }
    if (opts.getReasoningEffort()) |effort| {
        try w.writeStringField("reasoning_effort", effort);
    }
    if (opts.getReasoningSummary()) |summary| {
        try w.writeStringField("reasoning_summary", summary);
    }
    if (opts.include_reasoning_encrypted) {
        try w.writeBoolField("include_reasoning_encrypted", true);
    }
    if (!opts.reasoning_enabled) {
        try w.writeBoolField("reasoning_enabled", false);
    }
    if (opts.service_tier) |tier| {
        try w.writeStringField("service_tier", @tagName(tier));
    }
    if (opts.metadata) |meta| {
        try w.writeKey("metadata");
        try w.beginObject();
        if (meta.getUserId()) |uid| {
            try w.writeStringField("user_id", uid);
        }
        try w.endObject();
    }
    if (opts.tool_choice) |choice| {
        try w.writeKey("tool_choice");
        try w.beginObject();
        try w.writeStringField("type", @tagName(choice));
        if (choice == .function) {
            try w.writeStringField("function", choice.function);
        }
        try w.endObject();
    }
    if (opts.http_timeout_ms) |timeout| {
        try w.writeIntField("http_timeout_ms", timeout);
    }
    if (opts.ping_interval_ms) |interval| {
        try w.writeIntField("ping_interval_ms", interval);
    }

    if (opts.headers) |headers| {
        try serializeHeaderPairs(w, headers);
    }

    if (opts.retry.max_retry_delay_ms) |delay| {
        try w.writeKey("retry");
        try w.beginObject();
        try w.writeIntField("max_retry_delay_ms", delay);
        try w.endObject();
    }

    try w.endObject();
}

fn serializeEventPayload(
    w: *json_writer.JsonWriter,
    event: ai_types.AssistantMessageEvent,
    allocator: std.mem.Allocator,
) !void {
    const event_json = try transport.serializeEvent(event, allocator);
    defer allocator.free(event_json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, event_json, .{});
    defer parsed.deinit();

    const obj = try fields.rootObject(parsed.value);
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "type")) continue;
        try w.writeKey(entry.key_ptr.*);
        try writeJsonValue(w, entry.value_ptr.*, allocator);
    }
}

fn serializeResultPayload(
    w: *json_writer.JsonWriter,
    result: ai_types.AssistantMessage,
    allocator: std.mem.Allocator,
) !void {
    const result_json = try transport.serializeResult(result, allocator);
    defer allocator.free(result_json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer parsed.deinit();

    const obj = try fields.rootObject(parsed.value);
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        try w.writeKey(entry.key_ptr.*);
        try writeJsonValue(w, entry.value_ptr.*, allocator);
    }
}

fn serializeModelDescriptor(
    w: *json_writer.JsonWriter,
    model: protocol_types.ModelDescriptor,
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
    if (model.metadata) |metadata_entries| {
        try w.writeKey("metadata");
        try w.beginObject();
        for (metadata_entries.slice()) |entry| {
            try w.writeStringField(entry.key.slice(), entry.value.slice());
        }
        try w.endObject();
    }

    try w.endObject();
}

fn writeJsonValue(
    w: *json_writer.JsonWriter,
    value: std.json.Value,
    allocator: std.mem.Allocator,
) !void {
    switch (value) {
        .null => try w.writeNull(),
        .bool => |b| try w.writeBool(b),
        .integer => |i| try w.writeInt(i),
        .float => |f| {
            try w.buffer.print(allocator, "{d}", .{f});
            w.needs_comma = true;
        },
        .number_string => |s| {
            try w.buffer.appendSlice(allocator, s);
            w.needs_comma = true;
        },
        .string => |s| try w.writeString(s),
        .array => |arr| {
            try w.beginArray();
            for (arr.items) |item| {
                try writeJsonValue(w, item, allocator);
            }
            try w.endArray();
        },
        .object => |obj| {
            try w.beginObject();
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                try w.writeKey(entry.key_ptr.*);
                try writeJsonValue(w, entry.value_ptr.*, allocator);
            }
            try w.endObject();
        },
    }
}

pub fn deserializeEnvelope(
    data: []const u8,
    allocator: std.mem.Allocator,
) !protocol_types.Envelope {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const obj = try fields.rootObject(parsed.value);

    const version = try fields.requiredInt(u8, obj, "version");

    const stream_id_str = try fields.requiredString(obj, "stream_id");
    const stream_id = protocol_types.parseUlid(stream_id_str) orelse return error.InvalidUlid;

    const message_id_str = try fields.requiredString(obj, "message_id");
    const message_id = protocol_types.parseUlid(message_id_str) orelse return error.InvalidUlid;

    const sequence = try fields.requiredInt(u64, obj, "sequence");

    const timestamp = try fields.requiredInteger(obj, "timestamp");

    var in_reply_to: ?protocol_types.Ulid = null;
    if (try fields.optionalString(obj, "in_reply_to")) |reply_val| {
        in_reply_to = protocol_types.parseUlid(reply_val) orelse return error.InvalidUlid;
    }

    const type_str = try fields.requiredString(obj, "type");

    const payload_obj = try fields.requiredObject(obj, "payload");
    const payload = try deserializePayload(type_str, payload_obj, allocator);

    return protocol_types.Envelope{
        .version = version,
        .stream_id = stream_id,
        .message_id = message_id,
        .sequence = sequence,
        .timestamp = timestamp,
        .in_reply_to = in_reply_to,
        .payload = payload,
    };
}

fn deserializePayload(
    type_str: []const u8,
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.Payload {
    if (std.mem.eql(u8, type_str, "ping")) {
        return .ping;
    }
    if (std.mem.eql(u8, type_str, "pong")) {
        return .{ .pong = try deserializePong(obj, allocator) };
    }
    if (std.mem.eql(u8, type_str, "goodbye")) {
        return .{ .goodbye = try deserializeGoodbye(obj, allocator) };
    }
    if (std.mem.eql(u8, type_str, "sync_request")) {
        return .{ .sync_request = try deserializeSyncRequest(obj) };
    }
    if (std.mem.eql(u8, type_str, "sync")) {
        return .{ .sync = try deserializeSync(obj, allocator) };
    }
    if (std.mem.eql(u8, type_str, "stream_request")) {
        return .{ .stream_request = try deserializeStreamRequest(obj, allocator) };
    }
    if (std.mem.eql(u8, type_str, "complete_request")) {
        return .{ .complete_request = try deserializeCompleteRequest(obj, allocator) };
    }
    if (std.mem.eql(u8, type_str, "abort_request")) {
        return .{ .abort_request = try deserializeAbortRequest(obj, allocator) };
    }
    if (std.mem.eql(u8, type_str, "models_request")) {
        return .{ .models_request = try deserializeModelsRequest(obj, allocator) };
    }
    if (std.mem.eql(u8, type_str, "ack")) {
        return .{ .ack = try deserializeAck(obj) };
    }
    if (std.mem.eql(u8, type_str, "nack")) {
        return .{ .nack = try deserializeNack(obj, allocator) };
    }
    if (std.mem.eql(u8, type_str, "result")) {
        const result = try transport.parseAssistantMessage(obj, allocator);
        return .{ .result = result };
    }
    if (std.mem.eql(u8, type_str, "stream_error")) {
        return .{ .stream_error = try deserializeStreamError(obj, allocator) };
    }
    if (std.mem.eql(u8, type_str, "models_response")) {
        return .{ .models_response = try deserializeModelsResponse(obj, allocator) };
    }

    if (isEventType(type_str)) {
        const event = try transport.parseAssistantMessageEvent(type_str, obj, allocator);
        return .{ .event = event };
    }

    return error.UnknownPayloadType;
}

fn isEventType(type_str: []const u8) bool {
    const event_types = [_][]const u8{
        "start",
        "text_start",
        "text_delta",
        "text_end",
        "thinking_start",
        "thinking_delta",
        "thinking_end",
        "toolcall_start",
        "toolcall_delta",
        "toolcall_end",
        "done",
        "error",
        "keepalive",
    };

    for (event_types) |evt| {
        if (std.mem.eql(u8, type_str, evt)) {
            return true;
        }
    }
    return false;
}

fn deserializeModel(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !ai_types.Model {
    const id = try dupeValidatedString(allocator, obj, "id", MAX_MODEL_FIELD_LENGTH);
    errdefer allocator.free(id);
    const name = try dupeValidatedString(allocator, obj, "name", MAX_MODEL_FIELD_LENGTH);
    errdefer allocator.free(name);
    const api = try dupeValidatedString(allocator, obj, "api", MAX_IDENTIFIER_LENGTH);
    errdefer allocator.free(api);
    const provider = try dupeValidatedString(allocator, obj, "provider", MAX_IDENTIFIER_LENGTH);
    errdefer allocator.free(provider);
    const base_url = try dupeValidatedString(allocator, obj, "base_url", MAX_MODEL_FIELD_LENGTH);
    errdefer allocator.free(base_url);

    const input = try deserializeInputModalities(obj, allocator);
    errdefer freeInputModalities(allocator, input);

    const headers = if (obj.get("headers")) |headers_val|
        try deserializeHeaderPairsValue(headers_val, allocator)
    else
        null;
    errdefer if (headers) |pairs| freeHeaderPairs(allocator, pairs);

    return .{
        .id = id,
        .name = name,
        .api = api,
        .provider = provider,
        .base_url = base_url,
        .reasoning = if (obj.get("reasoning")) |value| try valueAsBool(value) else false,
        .input = input,
        .cost = if (obj.get("cost")) |value| blk: {
            if (value != .object) return error.InvalidUserContent;
            break :blk try deserializeCost(try fields.asObject(value));
        } else .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = try optionalU32(obj, "context_window", 0),
        .max_tokens = try optionalU32(obj, "max_tokens", 0),
        .headers = headers,
        .compat = if (obj.get("compat")) |value| blk: {
            if (value != .object) return error.InvalidUserContent;
            break :blk try deserializeOpenAICompatOptions(try fields.asObject(value));
        } else null,
        .allows_anonymous = if (obj.get("allows_anonymous")) |value| try valueAsBool(value) else false,
        .is_owned = true,
    };
}

fn dupeValidatedString(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    field: []const u8,
    max_len: usize,
) ![]u8 {
    const value = try fields.requiredString(obj, field);
    try validateLength(value, max_len);
    return try allocator.dupe(u8, value);
}

fn deserializeInputModalities(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) ![]const []const u8 {
    const input_val = obj.get("input") orelse return try allocator.alloc([]const u8, 0);
    if (input_val != .array) return error.InvalidUserContent;
    const input_arr = try fields.asArray(input_val);
    const input = try allocator.alloc([]const u8, input_arr.items.len);
    var initialized: usize = 0;
    errdefer {
        for (input[0..initialized]) |item| allocator.free(item);
        allocator.free(input);
    }

    for (input_arr.items, 0..) |item, idx| {
        if (item != .string) return error.InvalidUserContent;
        try validateLength(try fields.asString(item), MAX_IDENTIFIER_LENGTH);
        input[idx] = try allocator.dupe(u8, try fields.asString(item));
        initialized += 1;
    }

    return input;
}

fn freeInputModalities(allocator: std.mem.Allocator, input: []const []const u8) void {
    for (input) |item| allocator.free(item);
    allocator.free(input);
}

fn deserializeHeaderPairs(
    array: std.json.Array,
    allocator: std.mem.Allocator,
) ![]ai_types.HeaderPair {
    const headers = try allocator.alloc(ai_types.HeaderPair, array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (headers[0..initialized]) |*header| header.deinit(allocator);
        allocator.free(headers);
    }

    for (array.items, 0..) |item, idx| {
        if (item != .object) return error.InvalidUserContent;
        const header_obj = try fields.asObject(item);
        const name_field = header_obj.get("name") orelse return error.InvalidUserContent;
        if (name_field != .string) return error.InvalidUserContent;
        const name_value = try fields.asString(name_field);
        try validateLength(name_value, MAX_HEADER_NAME_LENGTH);
        const name = try allocator.dupe(u8, name_value);
        errdefer allocator.free(name);

        const value_field = header_obj.get("value") orelse return error.InvalidUserContent;
        if (value_field != .string) return error.InvalidUserContent;
        const header_value = try fields.asString(value_field);
        try validateLength(header_value, MAX_HEADER_VALUE_LENGTH);
        const value = try allocator.dupe(u8, header_value);
        errdefer allocator.free(value);

        headers[idx] = .{ .name = name, .value = value };
        initialized += 1;
    }

    return headers;
}

fn deserializeHeaderPairsValue(
    value: std.json.Value,
    allocator: std.mem.Allocator,
) ![]ai_types.HeaderPair {
    if (value != .array) return error.InvalidUserContent;
    return try deserializeHeaderPairs(try fields.asArray(value), allocator);
}

fn freeHeaderPairs(allocator: std.mem.Allocator, headers: []const ai_types.HeaderPair) void {
    const mutable_headers: []ai_types.HeaderPair = @constCast(headers);
    for (mutable_headers) |*header| header.deinit(allocator);
    allocator.free(headers);
}

fn deserializeCost(obj: std.json.ObjectMap) !ai_types.Cost {
    return .{
        .input = try optionalF64(obj, "input", 0),
        .output = try optionalF64(obj, "output", 0),
        .cache_read = try optionalF64(obj, "cache_read", 0),
        .cache_write = try optionalF64(obj, "cache_write", 0),
    };
}

fn optionalU32(obj: std.json.ObjectMap, field: []const u8, default: u32) !u32 {
    const value = obj.get(field) orelse return default;
    return try valueAsU32(value);
}

fn valueAsU32(value: std.json.Value) !u32 {
    const parsed = try valueAsU64(value);
    if (parsed > std.math.maxInt(u32)) return error.InvalidUserContent;
    return @intCast(parsed);
}

fn valueAsU64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |number| blk: {
            if (number < 0) return error.InvalidUserContent;
            break :blk @intCast(number);
        },
        .number_string => |number| std.fmt.parseUnsigned(u64, number, 10) catch error.InvalidUserContent,
        else => error.InvalidUserContent,
    };
}

fn valueAsBool(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |b| b,
        else => error.InvalidUserContent,
    };
}

fn optionalF64(obj: std.json.ObjectMap, field: []const u8, default: f64) !f64 {
    const value = obj.get(field) orelse return default;
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        .number_string => |number| try std.fmt.parseFloat(f64, number),
        else => error.InvalidUserContent,
    };
}

fn optionalBool(obj: std.json.ObjectMap, field: []const u8) !?bool {
    const value = obj.get(field) orelse return null;
    return try valueAsBool(value);
}

fn deserializeOpenAICompatOptions(obj: std.json.ObjectMap) !ai_types.OpenAICompatOptions {
    return .{
        .supports_store = try optionalBool(obj, "supports_store"),
        .supports_developer_role = try optionalBool(obj, "supports_developer_role"),
        .supports_reasoning_effort = try optionalBool(obj, "supports_reasoning_effort"),
        .supports_usage_in_streaming = try optionalBool(obj, "supports_usage_in_streaming"),
        .max_tokens_field = if (obj.get("max_tokens_field")) |value| blk: {
            if (value != .string) return error.InvalidUserContent;
            break :blk try parseMaxTokensField(try fields.asString(value));
        } else null,
        .requires_tool_result_name = try optionalBool(obj, "requires_tool_result_name"),
        .requires_assistant_after_tool_result = try optionalBool(obj, "requires_assistant_after_tool_result"),
        .requires_thinking_as_text = try optionalBool(obj, "requires_thinking_as_text"),
        .requires_mistral_tool_ids = try optionalBool(obj, "requires_mistral_tool_ids"),
        .thinking_format = if (obj.get("thinking_format")) |value| blk: {
            if (value != .string) return error.InvalidUserContent;
            break :blk try parseThinkingFormat(try fields.asString(value));
        } else null,
        .supports_strict_mode = try optionalBool(obj, "supports_strict_mode"),
        .supports_anthropic_cache_ttl = try optionalBool(obj, "supports_anthropic_cache_ttl"),
    };
}

fn parseMaxTokensField(str: []const u8) error{InvalidEnumValue}!OpenAICompatMaxTokensField {
    if (std.mem.eql(u8, str, "max_completion_tokens")) return .max_completion_tokens;
    if (std.mem.eql(u8, str, "max_tokens")) return .max_tokens;
    return error.InvalidEnumValue;
}

fn parseThinkingFormat(str: []const u8) error{InvalidEnumValue}!OpenAICompatThinkingFormat {
    if (std.mem.eql(u8, str, "openai")) return .openai;
    if (std.mem.eql(u8, str, "zai")) return .zai;
    if (std.mem.eql(u8, str, "qwen")) return .qwen;
    return error.InvalidEnumValue;
}

fn deserializeStreamRequest(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.StreamRequest {
    const model_obj = try fields.requiredObject(obj, "model");
    const model = try deserializeModel(model_obj, allocator);
    errdefer {
        var mutable_model = model;
        mutable_model.deinit(allocator);
    }

    const context = if (obj.get("context")) |ctx_val|
        try deserializeContext(try fields.asObject(ctx_val), allocator)
    else
        ai_types.Context{ .messages = &.{} };
    errdefer {
        var mutable_context = context;
        mutable_context.deinit(allocator);
    }

    const include_partial = if (obj.get("include_partial")) |ip|
        try fields.asBool(ip)
    else
        false;

    const options = if (obj.get("options")) |opts_val|
        try deserializeStreamOptions(try fields.asObject(opts_val), allocator)
    else
        null;
    errdefer if (options) |opts| {
        var mutable_opts = opts;
        mutable_opts.deinit(allocator);
    };

    return .{
        .model = model,
        .context = context,
        .options = options,
        .include_partial = include_partial,
    };
}

fn deserializeCompleteRequest(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.CompleteRequest {
    const model_obj = try fields.requiredObject(obj, "model");
    const model = try deserializeModel(model_obj, allocator);
    errdefer {
        var mutable_model = model;
        mutable_model.deinit(allocator);
    }

    const context = if (obj.get("context")) |ctx_val|
        try deserializeContext(try fields.asObject(ctx_val), allocator)
    else
        ai_types.Context{ .messages = &.{} };
    errdefer {
        var mutable_context = context;
        mutable_context.deinit(allocator);
    }

    const options = if (obj.get("options")) |opts_val|
        try deserializeStreamOptions(try fields.asObject(opts_val), allocator)
    else
        null;
    errdefer if (options) |opts| {
        var mutable_opts = opts;
        mutable_opts.deinit(allocator);
    };

    return .{
        .model = model,
        .context = context,
        .options = options,
    };
}

fn deserializeAbortRequest(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.AbortRequest {
    const target_str = try fields.requiredString(obj, "target_stream_id");
    const target_id = protocol_types.parseUlid(target_str) orelse return error.InvalidUlid;

    const reason = if (obj.get("reason")) |r|
        protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(r)))
    else
        protocol_types.OwnedSlice(u8).initBorrowed("");

    return .{
        .target_stream_id = target_id,
        .reason = reason,
    };
}

fn deserializeModelsRequest(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.ModelsRequest {
    const provider_id = if (obj.get("provider_id")) |value| blk: {
        try validateLength(try fields.asString(value), MAX_IDENTIFIER_LENGTH);
        break :blk protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(value)));
    } else protocol_types.OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = provider_id;
        mutable.deinit(allocator);
    }

    const api = if (obj.get("api")) |value|
        protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(value)))
    else
        protocol_types.OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = api;
        mutable.deinit(allocator);
    }

    const model_id = if (obj.get("model_id")) |value| blk: {
        try validateLength(try fields.asString(value), MAX_IDENTIFIER_LENGTH);
        break :blk protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(value)));
    } else protocol_types.OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = model_id;
        mutable.deinit(allocator);
    }

    const include_deprecated = if (obj.get("include_deprecated")) |value|
        try fields.asBool(value)
    else
        false;
    const include_login_required = if (obj.get("include_login_required")) |value|
        try fields.asBool(value)
    else
        true;

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
) !protocol_types.ModelsResponse {
    const fetched_at_ms = try fields.requiredInteger(obj, "fetched_at_ms");
    const cache_max_age_ms = try valueAsU64(try fields.required(obj, "cache_max_age_ms"));
    const models_array = try fields.requiredArray(obj, "models");

    const models = try allocator.alloc(protocol_types.ModelDescriptor, models_array.items.len);
    var allocated_count: usize = 0;
    errdefer {
        for (models[0..allocated_count]) |*model| model.deinit(allocator);
        allocator.free(models);
    }

    for (models_array.items, 0..) |item, idx| {
        models[idx] = try deserializeModelDescriptor(try fields.asObject(item), allocator);
        allocated_count += 1;
    }

    return .{
        .models = protocol_types.OwnedSlice(protocol_types.ModelDescriptor).initOwned(models),
        .fetched_at_ms = fetched_at_ms,
        .cache_max_age_ms = cache_max_age_ms,
    };
}

fn deserializeModelDescriptor(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.ModelDescriptor {
    const model_ref = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(obj, "model_ref")));
    errdefer {
        var mutable = model_ref;
        mutable.deinit(allocator);
    }

    const model_id = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(obj, "model_id")));
    errdefer {
        var mutable = model_id;
        mutable.deinit(allocator);
    }

    const display_name = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(obj, "display_name")));
    errdefer {
        var mutable = display_name;
        mutable.deinit(allocator);
    }

    const provider_id = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(obj, "provider_id")));
    errdefer {
        var mutable = provider_id;
        mutable.deinit(allocator);
    }

    const api = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(obj, "api")));
    errdefer {
        var mutable = api;
        mutable.deinit(allocator);
    }

    const base_url = if (obj.get("base_url")) |value|
        protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(value)))
    else
        protocol_types.OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = base_url;
        mutable.deinit(allocator);
    }

    const capabilities_array = try fields.requiredArray(obj, "capabilities");
    const capabilities = try allocator.alloc(protocol_types.ModelCapability, capabilities_array.items.len);
    errdefer allocator.free(capabilities);
    for (capabilities_array.items, 0..) |item, idx| {
        capabilities[idx] = try parseModelCapability(try fields.asString(item));
    }

    var metadata: ?protocol_types.OwnedSlice(protocol_types.MetadataEntry) = null;
    var metadata_items: []protocol_types.MetadataEntry = &.{};
    var metadata_count: usize = 0;
    errdefer {
        for (metadata_items[0..metadata_count]) |*entry| entry.deinit(allocator);
        allocator.free(metadata_items);
    }
    if (obj.get("metadata")) |metadata_value| {
        const metadata_obj = try fields.asObject(metadata_value);
        metadata_items = try allocator.alloc(protocol_types.MetadataEntry, metadata_obj.count());

        var iter = metadata_obj.iterator();
        while (iter.next()) |entry| {
            const value_text = try fields.asString(entry.value_ptr.*);

            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            const value = try allocator.dupe(u8, value_text);

            metadata_items[metadata_count] = .{
                .key = protocol_types.OwnedSlice(u8).initOwned(key),
                .value = protocol_types.OwnedSlice(u8).initOwned(value),
            };
            metadata_count += 1;
        }

        metadata = protocol_types.OwnedSlice(protocol_types.MetadataEntry).initOwned(metadata_items);
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
        .capabilities = protocol_types.OwnedSlice(protocol_types.ModelCapability).initOwned(capabilities),
        .source = try parseModelSource(try fields.requiredString(obj, "source")),
        .context_window = if (obj.get("context_window")) |value| try valueAsU32(value) else null,
        .max_output_tokens = if (obj.get("max_output_tokens")) |value| try valueAsU32(value) else null,
        .reasoning_default = if (obj.get("reasoning_default")) |value| try parseReasoningLevel(try fields.asString(value)) else null,
        .metadata = metadata,
    };
}

fn deserializeAck(obj: std.json.ObjectMap) !protocol_types.Ack {
    const acknowledged_id_str = try fields.requiredString(obj, "acknowledged_id");
    const acknowledged_id = protocol_types.parseUlid(acknowledged_id_str) orelse return error.InvalidUlid;

    return .{
        .acknowledged_id = acknowledged_id,
    };
}

fn deserializeNack(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.Nack {
    const rejected_id_str = try fields.requiredString(obj, "rejected_id");
    const rejected_id = protocol_types.parseUlid(rejected_id_str) orelse return error.InvalidUlid;

    const reason = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(obj, "reason")));
    errdefer {
        var mutable_reason = reason;
        mutable_reason.deinit(allocator);
    }

    const error_code = if (obj.get("error_code")) |code_val|
        parseErrorCode(try fields.asString(code_val))
    else
        null;

    var supported_versions = protocol_types.OwnedSlice(protocol_types.OwnedSlice(u8)).initBorrowed(&.{});
    if (obj.get("supported_versions")) |versions_val| {
        const versions_arr = try fields.asArray(versions_val);
        const versions = try allocator.alloc(protocol_types.OwnedSlice(u8), versions_arr.items.len);
        var allocated_count: usize = 0;
        errdefer {
            for (versions[0..allocated_count]) |*v| v.deinit(allocator);
            allocator.free(versions);
        }
        for (versions_arr.items, 0..) |item, i| {
            versions[i] = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(item)));
            allocated_count += 1;
        }
        supported_versions = protocol_types.OwnedSlice(protocol_types.OwnedSlice(u8)).initOwned(versions);
    }

    return .{
        .rejected_id = rejected_id,
        .reason = reason,
        .error_code = error_code,
        .supported_versions = supported_versions,
    };
}

fn deserializeStreamError(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.StreamError {
    const code_str = try fields.requiredString(obj, "code");
    const code = parseErrorCode(code_str);

    const message = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(obj, "message")));

    return .{
        .code = code,
        .message = message,
    };
}

fn deserializePong(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.Pong {
    const ping_id = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(obj, "ping_id")));
    return .{ .ping_id = ping_id };
}

fn deserializeGoodbye(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.Goodbye {
    const reason = if (obj.get("reason")) |r|
        protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(r)))
    else
        protocol_types.OwnedSlice(u8).initBorrowed("");

    return .{ .reason = reason };
}

fn deserializeSyncRequest(obj: std.json.ObjectMap) !protocol_types.SyncRequest {
    const target_str = try fields.requiredString(obj, "target_stream_id");
    const target_id = protocol_types.parseUlid(target_str) orelse return error.InvalidUlid;

    return .{ .target_stream_id = target_id };
}

fn deserializeSync(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.Sync {
    const target_str = try fields.requiredString(obj, "target_stream_id");
    const target_stream_id = protocol_types.parseUlid(target_str) orelse return error.InvalidUlid;

    const partial = if (obj.get("partial")) |p|
        try transport.parseAssistantMessage(try fields.asObject(p), allocator)
    else
        null;

    return .{
        .target_stream_id = target_stream_id,
        .partial = partial,
    };
}

fn parseAuthStatus(str: []const u8) protocol_types.AuthStatus {
    if (std.mem.eql(u8, str, "authenticated")) return .authenticated;
    if (std.mem.eql(u8, str, "login_required")) return .login_required;
    if (std.mem.eql(u8, str, "expired")) return .expired;
    if (std.mem.eql(u8, str, "refreshing")) return .refreshing;
    if (std.mem.eql(u8, str, "login_in_progress")) return .login_in_progress;
    if (std.mem.eql(u8, str, "failed")) return .failed;
    return .unknown;
}

fn parseModelLifecycle(str: []const u8) error{InvalidEnumValue}!protocol_types.ModelLifecycle {
    if (std.mem.eql(u8, str, "stable")) return .stable;
    if (std.mem.eql(u8, str, "preview")) return .preview;
    if (std.mem.eql(u8, str, "deprecated")) return .deprecated;
    return error.InvalidEnumValue;
}

fn parseModelCapability(str: []const u8) error{InvalidEnumValue}!protocol_types.ModelCapability {
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

fn parseModelSource(str: []const u8) error{InvalidEnumValue}!protocol_types.ModelSource {
    if (std.mem.eql(u8, str, "dynamic")) return .dynamic;
    if (std.mem.eql(u8, str, "static_fallback")) return .static_fallback;
    return error.InvalidEnumValue;
}

fn parseReasoningLevel(str: []const u8) error{InvalidEnumValue}!protocol_types.ReasoningLevel {
    if (std.mem.eql(u8, str, "off")) return .off;
    if (std.mem.eql(u8, str, "minimal")) return .minimal;
    if (std.mem.eql(u8, str, "low")) return .low;
    if (std.mem.eql(u8, str, "medium")) return .medium;
    if (std.mem.eql(u8, str, "high")) return .high;
    if (std.mem.eql(u8, str, "xhigh")) return .xhigh;
    return error.InvalidEnumValue;
}

fn parseErrorCode(str: []const u8) protocol_types.ErrorCode {
    if (std.mem.eql(u8, str, "invalid_request")) return .invalid_request;
    if (std.mem.eql(u8, str, "model_not_found")) return .model_not_found;
    if (std.mem.eql(u8, str, "provider_error")) return .provider_error;
    if (std.mem.eql(u8, str, "rate_limited")) return .rate_limited;
    if (std.mem.eql(u8, str, "internal_error")) return .internal_error;
    if (std.mem.eql(u8, str, "stream_not_found")) return .stream_not_found;
    if (std.mem.eql(u8, str, "stream_already_exists")) return .stream_already_exists;
    if (std.mem.eql(u8, str, "version_mismatch")) return .version_mismatch;
    if (std.mem.eql(u8, str, "invalid_sequence")) return .invalid_sequence;
    if (std.mem.eql(u8, str, "duplicate_sequence")) return .duplicate_sequence;
    if (std.mem.eql(u8, str, "sequence_gap")) return .sequence_gap;
    if (std.mem.eql(u8, str, "not_implemented")) return .not_implemented;
    if (std.mem.eql(u8, str, "auth_required")) return .auth_required;
    if (std.mem.eql(u8, str, "auth_refresh_failed")) return .auth_refresh_failed;
    if (std.mem.eql(u8, str, "auth_expired")) return .auth_expired;
    if (std.mem.eql(u8, str, "stream_cancelled")) return .stream_cancelled;
    return .internal_error;
}

fn deserializeContext(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !ai_types.Context {
    var system_prompt = if (obj.get("system_prompt")) |sp|
        ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(sp)))
    else
        ai_types.OwnedSlice(u8).initBorrowed("");
    errdefer system_prompt.deinit(allocator);

    const messages_arr = if (obj.get("messages")) |msgs_val|
        try fields.asArray(msgs_val)
    else {
        const empty_messages = try allocator.alloc(ai_types.Message, 0);
        return ai_types.Context{
            .system_prompt = system_prompt,
            .messages = empty_messages,
            .is_owned = true,
        };
    };

    const messages = try allocator.alloc(ai_types.Message, messages_arr.items.len);
    var messages_initialized: usize = 0;
    errdefer {
        for (messages[0..messages_initialized]) |*message| message.deinit(allocator);
        allocator.free(messages);
    }

    for (messages_arr.items, 0..) |item, i| {
        messages[i] = try deserializeMessage(try fields.asObject(item), allocator);
        messages_initialized += 1;
    }

    var tools: ?[]ai_types.Tool = null;
    if (try fields.optionalArray(obj, "tools")) |tools_arr| {
        const allocated = try allocator.alloc(ai_types.Tool, tools_arr.items.len);
        var tools_initialized: usize = 0;
        errdefer {
            for (allocated[0..tools_initialized]) |*tool| tool.deinit(allocator);
            allocator.free(allocated);
        }
        for (tools_arr.items, 0..) |item, i| {
            allocated[i] = try deserializeTool(try fields.asObject(item), allocator);
            tools_initialized += 1;
        }
        tools = allocated;
    }

    return .{
        .system_prompt = system_prompt,
        .messages = messages,
        .tools = tools,
        .is_owned = true,
    };
}

fn deserializeMessage(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !ai_types.Message {
    const role = try fields.requiredString(obj, "role");

    if (std.mem.eql(u8, role, "user")) {
        const timestamp: i64 = if (obj.get("timestamp")) |ts| try fields.asInteger(ts) else 0;
        const content = try deserializeUserContent(try fields.required(obj, "content"), allocator);

        return .{ .user = .{
            .content = content,
            .timestamp = timestamp,
        } };
    }

    if (std.mem.eql(u8, role, "assistant")) {
        return .{ .assistant = try transport.parseAssistantMessage(obj, allocator) };
    }

    if (std.mem.eql(u8, role, "tool")) {
        const tool_call_id = try allocator.dupe(u8, try fields.requiredString(obj, "tool_call_id"));
        errdefer allocator.free(tool_call_id);
        const tool_name = try allocator.dupe(u8, try fields.requiredString(obj, "tool_name"));
        errdefer allocator.free(tool_name);
        const timestamp: i64 = if (obj.get("timestamp")) |ts| try fields.asInteger(ts) else 0;
        const is_error = if (obj.get("is_error")) |ie| try fields.asBool(ie) else false;

        const content_arr = if (obj.get("content")) |c| try fields.asArray(c) else return error.MissingContent;
        const content = try allocator.alloc(ai_types.UserContentPart, content_arr.items.len);
        var content_initialized: usize = 0;
        errdefer {
            for (content[0..content_initialized]) |*part| part.deinit(allocator);
            allocator.free(content);
        }
        for (content_arr.items, 0..) |item, i| {
            content[i] = try deserializeUserContentPart(try fields.asObject(item), allocator);
            content_initialized += 1;
        }

        const details_json = if (obj.get("details_json")) |dj|
            ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(dj)))
        else
            ai_types.OwnedSlice(u8).initBorrowed("");

        return .{ .tool_result = .{
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
            .content = content,
            .details_json = details_json,
            .is_error = is_error,
            .timestamp = timestamp,
        } };
    }

    return error.UnknownMessageRole;
}

fn deserializeUserContent(
    value: std.json.Value,
    allocator: std.mem.Allocator,
) !ai_types.UserContent {
    switch (value) {
        .string => |s| return .{ .text = try allocator.dupe(u8, s) },
        .array => |arr| {
            const parts = try allocator.alloc(ai_types.UserContentPart, arr.items.len);
            var initialized: usize = 0;
            errdefer {
                for (parts[0..initialized]) |*part| part.deinit(allocator);
                allocator.free(parts);
            }
            for (arr.items, 0..) |item, i| {
                parts[i] = try deserializeUserContentPart(try fields.asObject(item), allocator);
                initialized += 1;
            }
            return .{ .parts = parts };
        },
        else => return error.InvalidUserContent,
    }
}

fn deserializeUserContentPart(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !ai_types.UserContentPart {
    const type_str = try fields.requiredString(obj, "type");

    if (std.mem.eql(u8, type_str, "text")) {
        const text = try allocator.dupe(u8, try fields.requiredString(obj, "text"));
        errdefer allocator.free(text);
        const text_signature = if (obj.get("text_signature")) |sig|
            try allocator.dupe(u8, try fields.asString(sig))
        else
            null;
        return .{ .text = .{ .text = text, .text_signature = text_signature } };
    }

    if (std.mem.eql(u8, type_str, "image")) {
        const data = try allocator.dupe(u8, try fields.requiredString(obj, "data"));
        errdefer allocator.free(data);
        const mime_type = try allocator.dupe(u8, try fields.requiredString(obj, "mime_type"));
        return .{ .image = .{ .data = data, .mime_type = mime_type } };
    }

    return error.UnknownContentPartType;
}

fn deserializeTool(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !ai_types.Tool {
    const name = try allocator.dupe(u8, try fields.requiredString(obj, "name"));
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, try fields.requiredString(obj, "description"));
    errdefer allocator.free(description);

    const schema_json = if (obj.get("parameters_schema_json")) |schema| switch (schema) {
        .string => |s| try allocator.dupe(u8, s),
        else => blk: {
            var buffer = std.ArrayList(u8).empty;
            errdefer buffer.deinit(allocator);
            var w = json_writer.JsonWriter.init(&buffer, allocator);
            try writeJsonValue(&w, schema, allocator);
            break :blk try buffer.toOwnedSlice(allocator);
        },
    } else try allocator.dupe(u8, "{}");

    return .{
        .name = name,
        .description = description,
        .parameters_schema_json = schema_json,
    };
}

fn deserializeStreamOptions(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !ai_types.StreamOptions {
    var opts: ai_types.StreamOptions = .{};
    errdefer opts.deinit(allocator);

    if (obj.get("api_key")) |key| {
        opts.api_key = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(key)));
    }
    if (obj.get("temperature")) |temp| {
        opts.temperature = switch (temp) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }
    if (obj.get("max_tokens")) |max| {
        opts.max_tokens = try valueAsU32(max);
    }
    if (obj.get("cache_retention")) |ret| {
        opts.cache_retention = parseCacheRetention(try fields.asString(ret));
    }
    if (obj.get("session_id")) |sid| {
        opts.session_id = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(sid)));
    }
    if (obj.get("thinking_enabled")) |te| {
        opts.thinking_enabled = try fields.asBool(te);
    }
    if (obj.get("thinking_budget_tokens")) |tbt| {
        opts.thinking_budget_tokens = try valueAsU32(tbt);
    }
    if (obj.get("thinking_effort")) |effort| {
        opts.thinking_effort = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(effort)));
    }
    if (obj.get("reasoning_effort")) |effort| {
        opts.reasoning_effort = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(effort)));
    }
    if (obj.get("reasoning_summary")) |summary| {
        opts.reasoning_summary = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(summary)));
    }
    if (obj.get("include_reasoning_encrypted")) |ire| {
        opts.include_reasoning_encrypted = try fields.asBool(ire);
    }
    if (obj.get("reasoning_enabled")) |re| {
        opts.reasoning_enabled = try fields.asBool(re);
    }
    if (obj.get("service_tier")) |tier| {
        opts.service_tier = parseServiceTier(try fields.asString(tier));
    }
    if (obj.get("metadata")) |meta| {
        opts.metadata = .{
            .user_id = if ((try fields.asObject(meta)).get("user_id")) |uid|
                ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(uid)))
            else
                ai_types.OwnedSlice(u8).initBorrowed(""),
        };
    }
    if (obj.get("tool_choice")) |choice| {
        const choice_type = try fields.requiredString(try fields.asObject(choice), "type");
        if (std.mem.eql(u8, choice_type, "auto")) {
            opts.tool_choice = .auto;
        } else if (std.mem.eql(u8, choice_type, "none")) {
            opts.tool_choice = .none;
        } else if (std.mem.eql(u8, choice_type, "required")) {
            opts.tool_choice = .required;
        } else if (std.mem.eql(u8, choice_type, "function")) {
            const function_name = try allocator.dupe(u8, try fields.requiredString(try fields.asObject(choice), "function"));
            opts.tool_choice = .{ .function = function_name };
            opts.owned_tool_choice_function = ai_types.OwnedSlice(u8).initOwned(function_name);
        }
    }
    if (obj.get("http_timeout_ms")) |timeout| {
        opts.http_timeout_ms = try valueAsU64(timeout);
    }
    if (obj.get("ping_interval_ms")) |interval| {
        opts.ping_interval_ms = try valueAsU64(interval);
    }
    if (obj.get("headers")) |headers_val| {
        const headers = try deserializeHeaderPairsValue(headers_val, allocator);
        opts.headers = headers;
        opts.owned_headers = ai_types.OwnedSlice(ai_types.HeaderPair).initOwned(headers);
    }

    return opts;
}

fn parseCacheRetention(str: []const u8) ?ai_types.CacheRetention {
    if (std.mem.eql(u8, str, "none")) return .none;
    if (std.mem.eql(u8, str, "short")) return .short;
    if (std.mem.eql(u8, str, "long")) return .long;
    return null;
}

fn parseServiceTier(str: []const u8) ?ai_types.ServiceTier {
    if (std.mem.eql(u8, str, "default")) return .default;
    if (std.mem.eql(u8, str, "flex")) return .flex;
    if (std.mem.eql(u8, str, "priority")) return .priority;
    return null;
}

pub fn createEnvelope(
    stream_id: protocol_types.Ulid,
    sequence: u64,
    payload: protocol_types.Payload,
    allocator: std.mem.Allocator,
) protocol_types.Envelope {
    _ = allocator;
    return .{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = sequence,
        .timestamp = compat.time.nowMillis(),
        .payload = payload,
    };
}

pub fn createReply(
    original: protocol_types.Envelope,
    payload: protocol_types.Payload,
    allocator: std.mem.Allocator,
) protocol_types.Envelope {
    _ = allocator;
    return .{
        .stream_id = original.stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = original.sequence + 1,
        .in_reply_to = original.message_id,
        .timestamp = compat.time.nowMillis(),
        .payload = payload,
    };
}

pub fn createAck(
    original: protocol_types.Envelope,
    allocator: std.mem.Allocator,
) protocol_types.Envelope {
    _ = allocator;
    return .{
        .stream_id = original.stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = original.sequence + 1,
        .in_reply_to = original.message_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .ack = .{
            .acknowledged_id = original.message_id,
        } },
    };
}

pub fn createNack(
    original: protocol_types.Envelope,
    reason: []const u8,
    error_code: ?protocol_types.ErrorCode,
    allocator: std.mem.Allocator,
) !protocol_types.Envelope {
    const reason_copy = try allocator.dupe(u8, reason);
    return .{
        .stream_id = original.stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = original.sequence + 1,
        .in_reply_to = original.message_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = original.message_id,
            .reason = protocol_types.OwnedSlice(u8).initOwned(reason_copy),
            .error_code = error_code,
        } },
    };
}

pub fn createVersionMismatchNack(
    original: protocol_types.Envelope,
    allocator: std.mem.Allocator,
) !protocol_types.Envelope {
    const reason = try std.fmt.allocPrint(allocator, "Unsupported protocol version: {d}", .{original.version});
    errdefer allocator.free(reason);

    const supported_versions = try allocator.alloc(protocol_types.OwnedSlice(u8), protocol_types.SUPPORTED_PROTOCOL_VERSIONS.len);
    var populated_count: usize = 0;
    errdefer {
        for (supported_versions[0..populated_count]) |*version| {
            version.deinit(allocator);
        }
        allocator.free(supported_versions);
    }
    for (protocol_types.SUPPORTED_PROTOCOL_VERSIONS, 0..) |version, i| {
        supported_versions[i] = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, version));
        populated_count += 1;
    }

    return .{
        .stream_id = original.stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = original.sequence + 1,
        .in_reply_to = original.message_id,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = original.message_id,
            .reason = protocol_types.OwnedSlice(u8).initOwned(reason),
            .error_code = .version_mismatch,
            .supported_versions = protocol_types.OwnedSlice(protocol_types.OwnedSlice(u8)).initOwned(supported_versions),
        } },
    };
}

pub const EnvelopeError = error{
    InvalidUlid,
    UnknownPayloadType,
    UnknownMessageRole,
    InvalidUserContent,
    UnknownContentPartType,
    MissingContent,
    InvalidEnumValue,
    InputTooLong,
};

pub const MAX_IDENTIFIER_LENGTH: usize = 256;

pub const MAX_MODEL_FIELD_LENGTH: usize = 512;

pub const MAX_HEADER_NAME_LENGTH: usize = 256;

pub const MAX_HEADER_VALUE_LENGTH: usize = 8192;

fn validateLength(slice: []const u8, max_len: usize) EnvelopeError!void {
    if (slice.len > max_len) return error.InputTooLong;
}

test "serializeEnvelope with ping payload" {
    const allocator = std.testing.allocator;

    const envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 1708234567890,
        .payload = .ping,
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"type\":\"ping\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"sequence\":1") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"timestamp\":1708234567890") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"payload\":{}") != null);
}

test "serializeEnvelope with pong payload" {
    const allocator = std.testing.allocator;

    const ping_id = try allocator.dupe(u8, "test-ping-123");

    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = 1708234567900,
        .payload = .{ .pong = .{ .ping_id = protocol_types.OwnedSlice(u8).initOwned(ping_id) } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"type\":\"pong\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"sequence\":2") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"ping_id\":\"test-ping-123\"") != null);

    envelope.deinit(allocator);
}

test "serializeEnvelope with stream_request payload" {
    const allocator = std.testing.allocator;

    const model = ai_types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    const context = ai_types.Context{
        .system_prompt = ai_types.OwnedSlice(u8).initBorrowed("You are helpful."),
        .messages = &.{},
    };

    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 1708234567890,
        .payload = .{ .stream_request = .{
            .model = model,
            .context = context,
            .options = null,
            .include_partial = true,
        } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"type\":\"stream_request\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"model\":{") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"id\":\"gpt-4\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"name\":\"GPT-4\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"system_prompt\":\"You are helpful.\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"include_partial\":true") != null);

    envelope.deinit(allocator);
}

test "stream_request round trips model metadata" {
    const allocator = std.testing.allocator;

    const input = [_][]const u8{ "text", "image" };
    const headers = [_]ai_types.HeaderPair{
        .{ .name = "version", .value = "0.135.0" },
        .{ .name = "ChatGPT-Account-ID", .value = "account-123" },
    };
    const model = ai_types.Model{
        .id = "gpt-5.4-mini",
        .name = "GPT-5.4 Mini",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api/codex",
        .reasoning = true,
        .input = &input,
        .cost = .{ .input = 1.25, .output = 2.5, .cache_read = 0.125, .cache_write = 0.25 },
        .context_window = 272_000,
        .max_tokens = 16_384,
        .headers = &headers,
        .compat = .{
            .supports_store = false,
            .max_tokens_field = .max_tokens,
            .thinking_format = .zai,
        },
    };

    const context = ai_types.Context{ .messages = &.{} };
    const options = ai_types.StreamOptions{ .headers = &headers };
    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 1708234567890,
        .payload = .{ .stream_request = .{
            .model = model,
            .context = context,
            .options = options,
            .include_partial = true,
        } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);
    envelope.deinit(allocator);

    var decoded = try deserializeEnvelope(json, allocator);
    defer decoded.deinit(allocator);

    try std.testing.expect(decoded.payload == .stream_request);
    const decoded_model = decoded.payload.stream_request.model;
    try std.testing.expectEqualStrings("gpt-5.4-mini", decoded_model.id);
    try std.testing.expectEqualStrings("GPT-5.4 Mini", decoded_model.name);
    try std.testing.expectEqualStrings("openai-codex-responses", decoded_model.api);
    try std.testing.expectEqualStrings("openai-codex", decoded_model.provider);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex", decoded_model.base_url);
    try std.testing.expect(decoded_model.reasoning);
    try std.testing.expectEqual(@as(usize, 2), decoded_model.input.len);
    try std.testing.expectEqualStrings("text", decoded_model.input[0]);
    try std.testing.expectEqualStrings("image", decoded_model.input[1]);
    try std.testing.expectEqual(@as(u32, 272_000), decoded_model.context_window);
    try std.testing.expectEqual(@as(u32, 16_384), decoded_model.max_tokens);
    try std.testing.expect(decoded_model.headers != null);
    try std.testing.expectEqual(@as(usize, 2), decoded_model.headers.?.len);
    try std.testing.expectEqualStrings("version", decoded_model.headers.?[0].name);
    try std.testing.expectEqualStrings("0.135.0", decoded_model.headers.?[0].value);
    try std.testing.expect(decoded_model.compat != null);
    try std.testing.expectEqual(@as(?bool, false), decoded_model.compat.?.supports_store);
    try std.testing.expect(decoded_model.compat.?.max_tokens_field.? == .max_tokens);
    try std.testing.expect(decoded_model.compat.?.thinking_format.? == .zai);
    try std.testing.expect(decoded.payload.stream_request.options != null);
    try std.testing.expect(decoded.payload.stream_request.options.?.headers != null);
    try std.testing.expectEqualStrings("ChatGPT-Account-ID", decoded.payload.stream_request.options.?.headers.?[1].name);
}

test "unset compat enums are omitted on the wire and decode back as unset" {
    const allocator = std.testing.allocator;

    const input = [_][]const u8{"text"};
    const model = ai_types.Model{
        .id = "gateway-model",
        .name = "Gateway Model",
        .api = "openai-completions",
        .provider = "gateway",
        .base_url = "https://gw.internal",
        .reasoning = false,
        .input = &input,
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 4096,
        .compat = .{ .supports_anthropic_cache_ttl = true },
    };

    const context = ai_types.Context{ .messages = &.{} };
    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 1708234567890,
        .payload = .{ .stream_request = .{
            .model = model,
            .context = context,
            .options = null,
            .include_partial = false,
        } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);
    envelope.deinit(allocator);

    try std.testing.expect(std.mem.find(u8, json, "max_tokens_field") == null);
    try std.testing.expect(std.mem.find(u8, json, "thinking_format") == null);
    try std.testing.expect(std.mem.find(u8, json, "supports_strict_mode") == null);
    try std.testing.expect(std.mem.find(u8, json, "supports_usage_in_streaming") == null);

    var decoded = try deserializeEnvelope(json, allocator);
    defer decoded.deinit(allocator);

    const decoded_compat = decoded.payload.stream_request.model.compat.?;
    try std.testing.expectEqual(@as(?bool, true), decoded_compat.supports_anthropic_cache_ttl);
    try std.testing.expect(decoded_compat.max_tokens_field == null);
    try std.testing.expect(decoded_compat.thinking_format == null);
    try std.testing.expect(decoded_compat.supports_strict_mode == null);
    try std.testing.expect(decoded_compat.supports_usage_in_streaming == null);
}

test "allows_anonymous round trips and defaults off when the field is absent" {
    const allocator = std.testing.allocator;

    const input = [_][]const u8{"text"};
    const base = ai_types.Model{
        .id = "m",
        .name = "M",
        .api = "openai-completions",
        .provider = "local",
        .base_url = "http://localhost:8000/v1",
        .reasoning = false,
        .input = &input,
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 8_192,
        .max_tokens = 1_024,
    };

    for ([_]bool{ true, false }) |anonymous| {
        var model = base;
        model.allows_anonymous = anonymous;

        var envelope = protocol_types.Envelope{
            .stream_id = protocol_types.generateUlid(),
            .message_id = protocol_types.generateUlid(),
            .sequence = 1,
            .timestamp = 1708234567890,
            .payload = .{ .stream_request = .{
                .model = model,
                .context = ai_types.Context{ .messages = &.{} },
                .options = null,
                .include_partial = false,
            } },
        };

        const json = try serializeEnvelope(envelope, allocator);
        defer allocator.free(json);
        envelope.deinit(allocator);

        try std.testing.expectEqual(anonymous, std.mem.find(u8, json, "\"allows_anonymous\":true") != null);

        var decoded = try deserializeEnvelope(json, allocator);
        defer decoded.deinit(allocator);
        try std.testing.expectEqual(anonymous, decoded.payload.stream_request.model.allows_anonymous);
    }
}

test "stream_request rejects oversized model integer fields" {
    const allocator = std.testing.allocator;
    const model = ai_types.Model{
        .id = "gpt-test",
        .name = "GPT Test",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://example.invalid",
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1,
        .max_tokens = 1,
    };
    const context = ai_types.Context{ .messages = &.{} };
    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 1708234567890,
        .payload = .{ .stream_request = .{
            .model = model,
            .context = context,
            .options = null,
            .include_partial = true,
        } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);
    envelope.deinit(allocator);

    const oversized = try std.mem.replaceOwned(u8, allocator, json, "\"context_window\":1", "\"context_window\":4294967296");
    defer allocator.free(oversized);

    try std.testing.expectError(error.InvalidUserContent, deserializeEnvelope(oversized, allocator));
}

test "stream_request rejects malformed model headers" {
    const allocator = std.testing.allocator;
    const headers = [_]ai_types.HeaderPair{.{ .name = "version", .value = "0.135.0" }};
    const model = ai_types.Model{
        .id = "gpt-test",
        .name = "GPT Test",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://example.invalid",
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1,
        .max_tokens = 1,
        .headers = &headers,
    };
    const context = ai_types.Context{ .messages = &.{} };
    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 1708234567890,
        .payload = .{ .stream_request = .{
            .model = model,
            .context = context,
            .options = null,
            .include_partial = true,
        } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);
    envelope.deinit(allocator);

    const malformed_object = try std.mem.replaceOwned(u8, allocator, json, "\"headers\":[{\"name\":\"version\",\"value\":\"0.135.0\"}]", "\"headers\":{}");
    defer allocator.free(malformed_object);
    try std.testing.expectError(error.InvalidUserContent, deserializeEnvelope(malformed_object, allocator));

    const missing_value = try std.mem.replaceOwned(u8, allocator, json, "\"headers\":[{\"name\":\"version\",\"value\":\"0.135.0\"}]", "\"headers\":[{\"name\":\"version\"}]");
    defer allocator.free(missing_value);
    try std.testing.expectError(error.InvalidUserContent, deserializeEnvelope(missing_value, allocator));
}

test "stream_request rejects malformed model input and compat metadata" {
    const allocator = std.testing.allocator;
    const model = ai_types.Model{
        .id = "gpt-test",
        .name = "GPT Test",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://example.invalid",
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1,
        .max_tokens = 1,
        .compat = .{ .supports_store = false },
    };
    const context = ai_types.Context{ .messages = &.{} };
    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = 1708234567890,
        .payload = .{ .stream_request = .{
            .model = model,
            .context = context,
            .options = null,
            .include_partial = true,
        } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);
    envelope.deinit(allocator);

    const input_object = try std.mem.replaceOwned(u8, allocator, json, "\"input\":[\"text\"]", "\"input\":{}");
    defer allocator.free(input_object);
    try std.testing.expectError(error.InvalidUserContent, deserializeEnvelope(input_object, allocator));

    const input_non_string = try std.mem.replaceOwned(u8, allocator, json, "\"input\":[\"text\"]", "\"input\":[{}]");
    defer allocator.free(input_non_string);
    try std.testing.expectError(error.InvalidUserContent, deserializeEnvelope(input_non_string, allocator));

    const compat_string_bool = try std.mem.replaceOwned(u8, allocator, json, "\"supports_store\":false", "\"supports_store\":\"false\"");
    defer allocator.free(compat_string_bool);
    try std.testing.expectError(error.InvalidUserContent, deserializeEnvelope(compat_string_bool, allocator));

    const compat_object = try std.mem.replaceOwned(u8, allocator, json, "\"compat\":{", "\"compat\":\"bad\",\"compat_extra\":{");
    defer allocator.free(compat_object);
    try std.testing.expectError(error.InvalidUserContent, deserializeEnvelope(compat_object, allocator));
}

test "deserializeEnvelope parses valid JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "ping",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "version": 1,
        \\  "payload": {}
        \\}
    ;

    var envelope = try deserializeEnvelope(json, allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(envelope.version == 1);
    try std.testing.expect(envelope.sequence == 1);
    try std.testing.expect(envelope.timestamp == 1708234567890);
    try std.testing.expect(envelope.payload == .ping);

    const expected_stream_id: protocol_types.Ulid = .{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10 };
    try std.testing.expectEqualSlices(u8, &expected_stream_id, &envelope.stream_id);
}

test "deserializeEnvelope rejects invalid in_reply_to ulid" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "ping",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "version": 1,
        \\  "in_reply_to": "not-a-ulid",
        \\  "payload": {}
        \\}
    ;

    try std.testing.expectError(error.InvalidUlid, deserializeEnvelope(json, allocator));
}

test "serializeEnvelope and deserializeEnvelope roundtrip with ping" {
    const allocator = std.testing.allocator;

    const original = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 42,
        .timestamp = compat.time.nowMillis(),
        .in_reply_to = protocol_types.generateUlid(),
        .payload = .ping,
    };

    const json = try serializeEnvelope(original, allocator);
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualSlices(u8, &original.stream_id, &parsed.stream_id);
    try std.testing.expectEqualSlices(u8, &original.message_id, &parsed.message_id);
    try std.testing.expectEqual(original.sequence, parsed.sequence);
    try std.testing.expectEqual(original.timestamp, parsed.timestamp);
    try std.testing.expect(parsed.in_reply_to != null);
    try std.testing.expectEqualSlices(u8, &original.in_reply_to.?, &parsed.in_reply_to.?);
    try std.testing.expect(parsed.payload == .ping);
}

test "serializeEnvelope and deserializeEnvelope roundtrip with ack" {
    const allocator = std.testing.allocator;

    const acknowledged_id = protocol_types.generateUlid();

    const original = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .ack = .{
            .acknowledged_id = acknowledged_id,
        } },
    };

    const json = try serializeEnvelope(original, allocator);
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.payload == .ack);
    try std.testing.expectEqualSlices(u8, &acknowledged_id, &parsed.payload.ack.acknowledged_id);
}

test "serializeEnvelope and deserializeEnvelope roundtrip with nack" {
    const allocator = std.testing.allocator;

    const rejected_id = protocol_types.generateUlid();
    const reason = try allocator.dupe(u8, "Test error reason");

    var original = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = rejected_id,
            .reason = protocol_types.OwnedSlice(u8).initOwned(reason),
            .error_code = .invalid_request,
        } },
    };

    const json = try serializeEnvelope(original, allocator);
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.payload == .nack);
    try std.testing.expectEqualSlices(u8, &rejected_id, &parsed.payload.nack.rejected_id);
    try std.testing.expectEqual(protocol_types.ErrorCode.invalid_request, parsed.payload.nack.error_code.?);
    try std.testing.expectEqualStrings("Test error reason", parsed.payload.nack.reason.slice());

    original.deinit(allocator);
}

test "createEnvelope generates valid envelope" {
    const allocator = std.testing.allocator;

    const stream_id = protocol_types.generateUlid();
    var envelope = createEnvelope(stream_id, 1, .ping, allocator);
    defer envelope.deinit(allocator);

    try std.testing.expectEqualSlices(u8, &stream_id, &envelope.stream_id);
    try std.testing.expect(envelope.sequence == 1);
    try std.testing.expect(envelope.timestamp > 0);
    try std.testing.expect(envelope.payload == .ping);
    try std.testing.expect(envelope.in_reply_to == null);
}

test "createReply sets in_reply_to correctly" {
    const allocator = std.testing.allocator;

    var original = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 5,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = undefined,
            .context = undefined,
        } },
    };

    var reply = createReply(original, .ping, allocator);
    defer reply.deinit(allocator);

    try std.testing.expectEqualSlices(u8, &original.stream_id, &reply.stream_id);
    try std.testing.expectEqualSlices(u8, &original.message_id, &reply.in_reply_to.?);
    try std.testing.expect(reply.sequence == 6);
    try std.testing.expect(reply.payload == .ping);
}

test "createAck creates valid ack" {
    const allocator = std.testing.allocator;

    const original = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = undefined,
            .context = undefined,
        } },
    };

    var ack_env = createAck(original, allocator);
    defer ack_env.deinit(allocator);

    try std.testing.expect(ack_env.payload == .ack);
    try std.testing.expectEqualSlices(u8, &original.message_id, &ack_env.payload.ack.acknowledged_id);
    try std.testing.expect(ack_env.in_reply_to != null);
    try std.testing.expectEqualSlices(u8, &original.message_id, &ack_env.in_reply_to.?);
}

test "createNack creates valid nack" {
    const allocator = std.testing.allocator;

    var original = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = undefined,
            .context = undefined,
        } },
    };

    var nack_env = try createNack(original, "Model gpt-5 not found", .model_not_found, allocator);
    defer nack_env.deinit(allocator);

    try std.testing.expect(nack_env.payload == .nack);
    try std.testing.expectEqualSlices(u8, &original.message_id, &nack_env.payload.nack.rejected_id);
    try std.testing.expectEqual(protocol_types.ErrorCode.model_not_found, nack_env.payload.nack.error_code.?);
    try std.testing.expectEqualStrings("Model gpt-5 not found", nack_env.payload.nack.reason.slice());
    try std.testing.expect(nack_env.in_reply_to != null);
    try std.testing.expectEqualSlices(u8, &original.message_id, &nack_env.in_reply_to.?);
}

test "createVersionMismatchNack includes supported versions" {
    const allocator = std.testing.allocator;

    const original = protocol_types.Envelope{
        .version = 2,
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .ping,
    };

    var nack_env = try createVersionMismatchNack(original, allocator);
    defer nack_env.deinit(allocator);

    try std.testing.expect(nack_env.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.version_mismatch, nack_env.payload.nack.error_code.?);
    const supported_versions = nack_env.payload.nack.supported_versions.slice();
    try std.testing.expectEqual(@as(usize, 1), supported_versions.len);
    try std.testing.expectEqualStrings("1", supported_versions[0].slice());
}

test "serializeEnvelope with abort_request payload" {
    const allocator = std.testing.allocator;

    const reason = try allocator.dupe(u8, "User cancelled");

    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 10,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .abort_request = .{
            .target_stream_id = protocol_types.generateUlid(),
            .reason = protocol_types.OwnedSlice(u8).initOwned(reason),
        } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"type\":\"abort_request\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"reason\":\"User cancelled\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"target_stream_id\"") != null);

    envelope.deinit(allocator);
}

test "serializeEnvelope with stream_error payload" {
    const allocator = std.testing.allocator;

    const msg = try allocator.dupe(u8, "Connection timeout");

    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 20,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_error = .{
            .code = .provider_error,
            .message = protocol_types.OwnedSlice(u8).initOwned(msg),
        } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"type\":\"stream_error\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"code\":\"provider_error\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"message\":\"Connection timeout\"") != null);

    envelope.deinit(allocator);
}

test "deserializeEnvelope rejects an envelope with no version" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "ping",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "payload": {}
        \\}
    ;

    try std.testing.expectError(error.MissingField, deserializeEnvelope(json, allocator));
}

test "deserializeEnvelope with explicit version" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "ping",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "version": 2,
        \\  "payload": {}
        \\}
    ;

    var envelope = try deserializeEnvelope(json, allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(envelope.version == 2);
}

test "deserializeEnvelope with stream_request frees all memory" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "stream_request",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "version": 1,
        \\  "payload": {
        \\    "model": {
        \\      "id": "gpt-4o",
        \\      "name": "GPT-4o",
        \\      "api": "openai-completions",
        \\      "provider": "openai",
        \\      "base_url": "https://api.openai.com"
        \\    },
        \\    "context": {
        \\      "system_prompt": "You are helpful.",
        \\      "messages": [
        \\        {
        \\          "role": "user",
        \\          "timestamp": 123,
        \\          "content": "Hello"
        \\        }
        \\      ],
        \\      "tools": [
        \\        {
        \\          "name": "bash",
        \\          "description": "Run a command",
        \\          "parameters_schema_json": "{\"type\":\"object\"}"
        \\        }
        \\      ]
        \\    },
        \\    "include_partial": true
        \\  }
        \\}
    ;

    var envelope = try deserializeEnvelope(json, allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(envelope.payload == .stream_request);
    try std.testing.expectEqualStrings("gpt-4o", envelope.payload.stream_request.model.id);
    try std.testing.expectEqualStrings("GPT-4o", envelope.payload.stream_request.model.name);
    try std.testing.expect(envelope.payload.stream_request.model.is_owned);
    try std.testing.expect(envelope.payload.stream_request.context.is_owned);
}

test "deserializeEnvelope with complete_request frees all memory" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "complete_request",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "version": 1,
        \\  "payload": {
        \\    "model": {
        \\      "id": "claude-3",
        \\      "name": "Claude 3",
        \\      "api": "anthropic-messages",
        \\      "provider": "anthropic",
        \\      "base_url": "https://api.anthropic.com"
        \\    },
        \\    "context": {
        \\      "messages": []
        \\    }
        \\  }
        \\}
    ;

    var envelope = try deserializeEnvelope(json, allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(envelope.payload == .complete_request);
    try std.testing.expectEqualStrings("claude-3", envelope.payload.complete_request.model.id);
    try std.testing.expect(envelope.payload.complete_request.model.is_owned);
    try std.testing.expect(envelope.payload.complete_request.context.is_owned);
}

test "deserializeEnvelope with complex context frees all memory" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "stream_request",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "version": 1,
        \\  "payload": {
        \\    "model": {
        \\      "id": "gpt-4",
        \\      "name": "GPT-4",
        \\      "api": "openai-completions",
        \\      "provider": "openai",
        \\      "base_url": "https://api.openai.com"
        \\    },
        \\    "context": {
        \\      "system_prompt": "Be helpful",
        \\      "messages": [
        \\        {
        \\          "role": "user",
        \\          "timestamp": 100,
        \\          "content": "Hi"
        \\        },
        \\        {
        \\          "role": "tool",
        \\          "tool_call_id": "call-123",
        \\          "tool_name": "bash",
        \\          "timestamp": 200,
        \\          "is_error": false,
        \\          "content": [
        \\            {"type": "text", "text": "output"}
        \\          ]
        \\        }
        \\      ]
        \\    }
        \\  }
        \\}
    ;

    var envelope = try deserializeEnvelope(json, allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(envelope.payload == .stream_request);
    try std.testing.expect(envelope.payload.stream_request.context.messages.len == 2);
}

test "serializeEnvelope with goodbye payload" {
    const allocator = std.testing.allocator;

    const reason = try allocator.dupe(u8, "Server shutting down");
    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 100,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .goodbye = .{ .reason = protocol_types.OwnedSlice(u8).initOwned(reason) } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"type\":\"goodbye\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"reason\":\"Server shutting down\"") != null);

    envelope.deinit(allocator);
}

test "serializeEnvelope with goodbye payload (no reason)" {
    const allocator = std.testing.allocator;

    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 100,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .goodbye = .{} },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"type\":\"goodbye\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"reason\"") == null);

    envelope.deinit(allocator);
}

test "serializeEnvelope with sync_request payload" {
    const allocator = std.testing.allocator;

    const target_id = protocol_types.generateUlid();
    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 50,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .sync_request = .{ .target_stream_id = target_id } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"type\":\"sync_request\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"target_stream_id\"") != null);

    envelope.deinit(allocator);
}

test "serializeEnvelope with sync payload" {
    const allocator = std.testing.allocator;

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
        .is_owned = false,
    };
    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 60,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .sync = .{
            .target_stream_id = protocol_types.generateUlid(),
            .partial = partial,
        } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"type\":\"sync\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"target_stream_id\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"partial\"") != null);

    envelope.deinit(allocator);
}

test "deserializeEnvelope with pong payload" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "pong",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 2,
        \\  "timestamp": 1708234567900,
        \\  "version": 1,
        \\  "payload": {
        \\    "ping_id": "test-ping-456"
        \\  }
        \\}
    ;

    var envelope = try deserializeEnvelope(json, allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(envelope.payload == .pong);
    try std.testing.expectEqualStrings("test-ping-456", envelope.payload.pong.ping_id.slice());
}

test "deserializeEnvelope with goodbye payload" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "goodbye",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 100,
        \\  "timestamp": 1708234567900,
        \\  "version": 1,
        \\  "payload": {
        \\    "reason": "Server maintenance"
        \\  }
        \\}
    ;

    var envelope = try deserializeEnvelope(json, allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(envelope.payload == .goodbye);
    try std.testing.expectEqualStrings("Server maintenance", envelope.payload.goodbye.getReason().?);
}

test "deserializeEnvelope with goodbye payload (no reason)" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "goodbye",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 100,
        \\  "timestamp": 1708234567900,
        \\  "version": 1,
        \\  "payload": {}
        \\}
    ;

    var envelope = try deserializeEnvelope(json, allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(envelope.payload == .goodbye);
    try std.testing.expect(envelope.payload.goodbye.getReason() == null);
}

test "deserializeEnvelope with sync_request payload" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "sync_request",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 50,
        \\  "timestamp": 1708234567900,
        \\  "version": 1,
        \\  "payload": {
        \\    "target_stream_id": "5BSQQG28T5CY4TQKFF04HMASW9"
        \\  }
        \\}
    ;

    var envelope = try deserializeEnvelope(json, allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(envelope.payload == .sync_request);

    const expected_target: protocol_types.Ulid = .{ 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89 };
    try std.testing.expectEqualSlices(u8, &expected_target, &envelope.payload.sync_request.target_stream_id);
}

test "deserializeEnvelope with sync payload" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "sync",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 60,
        \\  "timestamp": 1708234567900,
        \\  "version": 1,
        \\  "payload": {
        \\    "target_stream_id": "5BSQQG28T5CY4TQKFF04HMASW9",
        \\    "partial": {
        \\      "stop_reason": "stop",
        \\      "model": "test-model",
        \\      "api": "test-api",
        \\      "provider": "test-provider",
        \\      "timestamp": 0,
        \\      "content": [{"type": "text", "text": "Hello"}]
        \\    }
        \\  }
        \\}
    ;

    var envelope = try deserializeEnvelope(json, allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(envelope.payload == .sync);
    const expected_target: protocol_types.Ulid = .{ 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89 };
    try std.testing.expectEqualSlices(u8, &expected_target, &envelope.payload.sync.target_stream_id);
    try std.testing.expect(envelope.payload.sync.partial != null);
}

test "serializeEnvelope and deserializeEnvelope roundtrip with pong" {
    const allocator = std.testing.allocator;

    const ping_id = try allocator.dupe(u8, "roundtrip-ping-id");
    var original = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 10,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .pong = .{ .ping_id = protocol_types.OwnedSlice(u8).initOwned(ping_id) } },
    };

    const json = try serializeEnvelope(original, allocator);
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.payload == .pong);
    try std.testing.expectEqualStrings("roundtrip-ping-id", parsed.payload.pong.ping_id.slice());

    original.deinit(allocator);
}

test "serializeEnvelope and deserializeEnvelope roundtrip with goodbye" {
    const allocator = std.testing.allocator;

    const reason = try allocator.dupe(u8, "Graceful shutdown");
    var original = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 200,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .goodbye = .{ .reason = protocol_types.OwnedSlice(u8).initOwned(reason) } },
    };

    const json = try serializeEnvelope(original, allocator);
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.payload == .goodbye);
    try std.testing.expectEqualStrings("Graceful shutdown", parsed.payload.goodbye.getReason().?);

    original.deinit(allocator);
}

test "serializeEnvelope and deserializeEnvelope roundtrip with models_request" {
    const allocator = std.testing.allocator;

    var original = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_request = .{
            .provider_id = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic")),
            .api = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic-messages")),
            .model_id = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "claude:sonnet-4-5")),
            .include_deprecated = false,
            .include_login_required = true,
        } },
    };

    const json = try serializeEnvelope(original, allocator);
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.payload == .models_request);
    try std.testing.expectEqualStrings("anthropic", parsed.payload.models_request.getProviderId().?);
    try std.testing.expectEqualStrings("anthropic-messages", parsed.payload.models_request.getApi().?);
    try std.testing.expectEqualStrings("claude:sonnet-4-5", parsed.payload.models_request.getModelId().?);
    try std.testing.expect(parsed.payload.models_request.include_login_required);

    original.deinit(allocator);
}

test "serializeEnvelope and deserializeEnvelope roundtrip with models_response" {
    const allocator = std.testing.allocator;

    const capabilities = try allocator.alloc(protocol_types.ModelCapability, 3);
    capabilities[0] = .chat;
    capabilities[1] = .streaming;
    capabilities[2] = .reasoning;

    const metadata = try allocator.alloc(protocol_types.MetadataEntry, 1);
    metadata[0] = .{
        .key = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "tier")),
        .value = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "premium")),
    };

    const models = try allocator.alloc(protocol_types.ModelDescriptor, 1);
    models[0] = .{
        .model_ref = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic/anthropic-messages@claude%3Asonnet-4-5")),
        .model_id = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "claude:sonnet-4-5")),
        .display_name = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "Claude Sonnet 4.5")),
        .provider_id = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic")),
        .api = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic-messages")),
        .base_url = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "https://api.anthropic.com")),
        .auth_status = .authenticated,
        .lifecycle = .stable,
        .capabilities = protocol_types.OwnedSlice(protocol_types.ModelCapability).initOwned(capabilities),
        .source = .dynamic,
        .context_window = 200_000,
        .max_output_tokens = 8_192,
        .reasoning_default = .high,
        .metadata = protocol_types.OwnedSlice(protocol_types.MetadataEntry).initOwned(metadata),
    };

    var original = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_response = .{
            .models = protocol_types.OwnedSlice(protocol_types.ModelDescriptor).initOwned(models),
            .fetched_at_ms = 1_760_000_000_198,
            .cache_max_age_ms = 300_000,
        } },
    };

    const json = try serializeEnvelope(original, allocator);
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.payload == .models_response);
    try std.testing.expectEqual(@as(usize, 1), parsed.payload.models_response.models.slice().len);
    const parsed_model = parsed.payload.models_response.models.slice()[0];
    try std.testing.expectEqualStrings("claude:sonnet-4-5", parsed_model.model_id.slice());
    try std.testing.expectEqual(protocol_types.ModelSource.dynamic, parsed_model.source);
    try std.testing.expectEqualStrings("premium", parsed_model.metadata.?.slice()[0].value.slice());
    try std.testing.expectEqual(protocol_types.ErrorCode.not_implemented, parseErrorCode("not_implemented"));

    original.deinit(allocator);
}

test "deserializeEnvelope rejects models_request with oversized provider_id" {
    const allocator = std.testing.allocator;
    const long_id = "a" ** 257;

    const json = std.fmt.allocPrint(allocator,
        \\{{
        \\  "type": "models_request",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "version": 1,
        \\  "payload": {{
        \\    "provider_id": "{s}"
        \\  }}
        \\}}
    , .{long_id}) catch @panic("OOM");
    defer allocator.free(json);

    const result = deserializeEnvelope(json, allocator);
    try std.testing.expectError(error.InputTooLong, result);
}

test "deserializeEnvelope rejects models_request with oversized model_id" {
    const allocator = std.testing.allocator;
    const long_id = "b" ** 257;

    const json = std.fmt.allocPrint(allocator,
        \\{{
        \\  "type": "models_request",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "version": 1,
        \\  "payload": {{
        \\    "model_id": "{s}"
        \\  }}
        \\}}
    , .{long_id}) catch @panic("OOM");
    defer allocator.free(json);

    const result = deserializeEnvelope(json, allocator);
    try std.testing.expectError(error.InputTooLong, result);
}

test "deserializeEnvelope accepts models_request with provider_id at exactly 256 chars" {
    const allocator = std.testing.allocator;
    const exact_id = "a" ** 256;

    const json = std.fmt.allocPrint(allocator,
        \\{{
        \\  "type": "models_request",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "version": 1,
        \\  "payload": {{
        \\    "provider_id": "{s}"
        \\  }}
        \\}}
    , .{exact_id}) catch @panic("OOM");
    defer allocator.free(json);

    var env = try deserializeEnvelope(json, allocator);
    defer env.deinit(allocator);
    try std.testing.expect(env.payload == .models_request);
    try std.testing.expectEqualStrings(exact_id, env.payload.models_request.provider_id.slice());
}

test "deserializeEnvelope rejects stream_request with oversized model id" {
    const allocator = std.testing.allocator;
    const long_id = "a" ** 513;

    const json = std.fmt.allocPrint(allocator,
        \\{{
        \\  "type": "stream_request",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "version": 1,
        \\  "payload": {{
        \\    "model": {{
        \\      "id": "{s}",
        \\      "name": "test",
        \\      "api": "test-api",
        \\      "provider": "test-provider",
        \\      "base_url": ""
        \\    }},
        \\    "context": {{ "messages": [] }}
        \\  }}
        \\}}
    , .{long_id}) catch @panic("OOM");
    defer allocator.free(json);

    const result = deserializeEnvelope(json, allocator);
    try std.testing.expectError(error.InputTooLong, result);
}

test "deserializeEnvelope rejects stream_request with oversized provider" {
    const allocator = std.testing.allocator;
    const long_provider = "p" ** 257;

    const json = std.fmt.allocPrint(allocator,
        \\{{
        \\  "type": "stream_request",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "version": 1,
        \\  "payload": {{
        \\    "model": {{
        \\      "id": "test-model",
        \\      "name": "test",
        \\      "api": "test-api",
        \\      "provider": "{s}",
        \\      "base_url": ""
        \\    }},
        \\    "context": {{ "messages": [] }}
        \\  }}
        \\}}
    , .{long_provider}) catch @panic("OOM");
    defer allocator.free(json);

    const result = deserializeEnvelope(json, allocator);
    try std.testing.expectError(error.InputTooLong, result);
}

test "deserializeEnvelope rejects complete_request with oversized model id" {
    const allocator = std.testing.allocator;
    const long_id = "x" ** 513;

    const json = std.fmt.allocPrint(allocator,
        \\{{
        \\  "type": "complete_request",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "version": 1,
        \\  "payload": {{
        \\    "model": {{
        \\      "id": "{s}",
        \\      "name": "test",
        \\      "api": "test-api",
        \\      "provider": "test-provider",
        \\      "base_url": ""
        \\    }},
        \\    "context": {{ "messages": [] }}
        \\  }}
        \\}}
    , .{long_id}) catch @panic("OOM");
    defer allocator.free(json);

    const result = deserializeEnvelope(json, allocator);
    try std.testing.expectError(error.InputTooLong, result);
}

test "deserializeEnvelope accepts stream_request with model id at exactly 512 chars" {
    const allocator = std.testing.allocator;
    const exact_id = "a" ** 512;

    const json = std.fmt.allocPrint(allocator,
        \\{{
        \\  "type": "stream_request",
        \\  "stream_id": "014D2PF2DBSQQZXQ5TK1V58CGG",
        \\  "message_id": "0J6HB7H6NWVVRFXX5TK1V58CGG",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "version": 1,
        \\  "payload": {{
        \\    "model": {{
        \\      "id": "{s}",
        \\      "name": "test",
        \\      "api": "test-api",
        \\      "provider": "test-provider",
        \\      "base_url": ""
        \\    }},
        \\    "context": {{ "messages": [] }}
        \\  }}
        \\}}
    , .{exact_id}) catch @panic("OOM");
    defer allocator.free(json);

    var env = try deserializeEnvelope(json, allocator);
    defer env.deinit(allocator);
    try std.testing.expect(env.payload == .stream_request);
    try std.testing.expectEqualStrings(exact_id, env.payload.stream_request.model.id);
}

const VALID_COMPLETE_REQUEST =
    \\{"type":"complete_request","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"model":{"base_url":"","id":"m","provider":"anthropic","api":"anthropic-messages","name":"m"},"context":{"messages":[{"role":"user","content":"hi"}]}}}
;

test "provider envelope accepts the malformed-input baseline" {
    const allocator = std.testing.allocator;
    var env = try deserializeEnvelope(VALID_COMPLETE_REQUEST, allocator);
    defer env.deinit(allocator);
    try std.testing.expect(env.payload == .complete_request);
    try std.testing.expectEqual(@as(u64, 1), env.sequence);
}

test "provider envelope rejects missing required root fields" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        \\{"stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1}
        ,
    };

    for (cases) |json| {
        try std.testing.expectError(error.MissingField, deserializeEnvelope(json, allocator));
    }
}

test "provider envelope rejects wrong-typed root fields" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        \\{"type":7,"stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","stream_id":7,"message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":7,"sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":"1","timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":"1","version":1,"payload":{}}
        ,
        \\{"type":"ping","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":[]}
        ,
        \\{"type":"ping","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"in_reply_to":7,"payload":{}}
        ,
    };

    for (cases) |json| {
        try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(json, allocator));
    }
}

test "provider envelope rejects out-of-range root numbers" {
    const allocator = std.testing.allocator;
    const negative_sequence =
        \\{"type":"ping","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":-1,"timestamp":1,"version":1,"payload":{}}
    ;
    const oversized_version =
        \\{"type":"ping","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":99999,"payload":{}}
    ;

    try std.testing.expectError(error.FieldOutOfRange, deserializeEnvelope(negative_sequence, allocator));
    try std.testing.expectError(error.FieldOutOfRange, deserializeEnvelope(oversized_version, allocator));
}

test "provider envelope rejects non-object documents" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope("[1,2,3]", allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope("\"hello\"", allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope("null", allocator));
}

test "provider envelope rejects malformed complete_request payloads" {
    const allocator = std.testing.allocator;
    const missing_model =
        \\{"type":"complete_request","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"context":{"messages":[]}}}
    ;
    const model_as_string =
        \\{"type":"complete_request","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"model":"m","context":{"messages":[]}}}
    ;
    const model_as_null =
        \\{"type":"complete_request","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"model":null,"context":{"messages":[]}}}
    ;
    const model_missing_id =
        \\{"type":"complete_request","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"model":{"base_url":"","provider":"anthropic","api":"anthropic-messages","name":"m"},"context":{"messages":[]}}}
    ;
    const messages_not_array =
        \\{"type":"complete_request","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"model":{"base_url":"","id":"m","provider":"anthropic","api":"anthropic-messages","name":"m"},"context":{"messages":"hi"}}}
    ;
    const message_missing_role =
        \\{"type":"complete_request","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"model":{"base_url":"","id":"m","provider":"anthropic","api":"anthropic-messages","name":"m"},"context":{"messages":[{"content":"hi"}]}}}
    ;
    const message_missing_content =
        \\{"type":"complete_request","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"model":{"base_url":"","id":"m","provider":"anthropic","api":"anthropic-messages","name":"m"},"context":{"messages":[{"role":"user"}]}}}
    ;

    try std.testing.expectError(error.MissingField, deserializeEnvelope(missing_model, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(model_as_string, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(model_as_null, allocator));
    try std.testing.expectError(error.MissingField, deserializeEnvelope(model_missing_id, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(messages_not_array, allocator));
    try std.testing.expectError(error.MissingField, deserializeEnvelope(message_missing_role, allocator));
    try std.testing.expectError(error.MissingField, deserializeEnvelope(message_missing_content, allocator));
}

test "provider envelope rejects malformed assistant content without leaking" {
    const allocator = std.testing.allocator;
    const bad_tool_result =
        \\{"type":"complete_request","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"model":{"base_url":"","id":"m","provider":"anthropic","api":"anthropic-messages","name":"m"},"context":{"messages":[{"role":"tool","tool_call_id":"c1"}]}}}
    ;
    const bad_content_part =
        \\{"type":"complete_request","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"model":{"base_url":"","id":"m","provider":"anthropic","api":"anthropic-messages","name":"m"},"context":{"messages":[{"role":"user","content":[{"type":"text"}]}]}}}
    ;
    const bad_tool_definition =
        \\{"type":"complete_request","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"model":{"base_url":"","id":"m","provider":"anthropic","api":"anthropic-messages","name":"m"},"context":{"messages":[],"tools":[{"name":"t"}]}}}
    ;

    try std.testing.expectError(error.MissingField, deserializeEnvelope(bad_tool_result, allocator));
    try std.testing.expectError(error.MissingField, deserializeEnvelope(bad_content_part, allocator));
    try std.testing.expectError(error.MissingField, deserializeEnvelope(bad_tool_definition, allocator));
}

test "provider model descriptor frees metadata when a trailing field is malformed" {
    const allocator = std.testing.allocator;
    const base = "{\"type\":\"models_response\",\"stream_id\":\"01M2MYK69FX2M3DY769FEHK3M0\",\"message_id\":\"01M2MYK69FX2M3DY769FEHK3M1\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"fetched_at_ms\":1,\"cache_max_age_ms\":1,\"models\":[{\"model_ref\":\"p/a@m\",\"model_id\":\"m\",\"display_name\":\"d\",\"provider_id\":\"p\",\"api\":\"a\",\"capabilities\":[\"chat\"],\"metadata\":{\"one\":\"1\",\"two\":\"2\"},";

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
    try std.testing.expectError(error.InvalidUserContent, deserializeEnvelope(bad_context_window, allocator));
    try std.testing.expectError(error.InvalidEnumValue, deserializeEnvelope(bad_reasoning_default, allocator));
}

test "models_response rejects a non-string metadata value without leaking the key" {
    const allocator = std.testing.allocator;

    const capabilities = try allocator.alloc(protocol_types.ModelCapability, 1);
    capabilities[0] = .chat;

    const metadata = try allocator.alloc(protocol_types.MetadataEntry, 1);
    metadata[0] = .{
        .key = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "tier")),
        .value = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "premium")),
    };

    const models = try allocator.alloc(protocol_types.ModelDescriptor, 1);
    models[0] = .{
        .model_ref = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic/anthropic-messages@claude-sonnet-4-5")),
        .model_id = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "claude-sonnet-4-5")),
        .display_name = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "Claude Sonnet 4.5")),
        .provider_id = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic")),
        .api = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic-messages")),
        .base_url = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "https://api.anthropic.com")),
        .auth_status = .authenticated,
        .lifecycle = .stable,
        .capabilities = protocol_types.OwnedSlice(protocol_types.ModelCapability).initOwned(capabilities),
        .source = .dynamic,
        .context_window = 200_000,
        .max_output_tokens = 8_192,
        .reasoning_default = .high,
        .metadata = protocol_types.OwnedSlice(protocol_types.MetadataEntry).initOwned(metadata),
    };

    var original = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_response = .{
            .models = protocol_types.OwnedSlice(protocol_types.ModelDescriptor).initOwned(models),
            .fetched_at_ms = 1_760_000_000_198,
            .cache_max_age_ms = 300_000,
        } },
    };
    defer original.deinit(allocator);

    const json = try serializeEnvelope(original, allocator);
    defer allocator.free(json);

    const mistyped = try std.mem.replaceOwned(u8, allocator, json, "\"premium\"", "5");
    defer allocator.free(mistyped);

    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(mistyped, allocator));
}
