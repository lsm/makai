const std = @import("std");
pub const protocol_types = @import("protocol_types");
const ai_types = @import("ai_types");
const json_writer = @import("json_writer");
const transport = @import("transport");

/// Serialize envelope to JSON
pub fn serializeEnvelope(
    envelope: protocol_types.Envelope,
    allocator: std.mem.Allocator,
) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);

    try w.beginObject();

    // Write type field - for events, use the event's type at top level
    try w.writeKey("type");
    if (envelope.payload == .event) {
        // For events, serialize the event type at the top level per PROTOCOL.md
        try w.writeString(@tagName(envelope.payload.event));
    } else {
        const payload_type = @tagName(envelope.payload);
        try w.writeString(payload_type);
    }

    // Write stream_id
    const stream_id_str = try protocol_types.uuidToString(envelope.stream_id, allocator);
    defer allocator.free(stream_id_str);
    try w.writeStringField("stream_id", stream_id_str);

    // Write message_id
    const message_id_str = try protocol_types.uuidToString(envelope.message_id, allocator);
    defer allocator.free(message_id_str);
    try w.writeStringField("message_id", message_id_str);

    // Write sequence
    try w.writeIntField("sequence", envelope.sequence);

    // Write timestamp
    try w.writeIntField("timestamp", envelope.timestamp);

    // Write version
    try w.writeIntField("version", envelope.version);

    // Write in_reply_to if present
    if (envelope.in_reply_to) |reply_to| {
        const reply_to_str = try protocol_types.uuidToString(reply_to, allocator);
        defer allocator.free(reply_to_str);
        try w.writeStringField("in_reply_to", reply_to_str);
    }

    // Write payload
    try w.writeKey("payload");
    try serializePayload(&w, envelope.payload, allocator);

    try w.endObject();

    const result = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return result;
}

/// Serialize payload based on its type
fn serializePayload(
    w: *json_writer.JsonWriter,
    payload: protocol_types.Payload,
    allocator: std.mem.Allocator,
) !void {
    try w.beginObject();

    switch (payload) {
        .ping => {
            // Empty payload for ping
        },
        .pong => |pong| {
            try w.writeStringField("ping_id", pong.ping_id.slice());
        },
        .goodbye => |goodbye| {
            if (goodbye.getReason()) |reason| {
                try w.writeStringField("reason", reason);
            }
        },
        .sync_request => |sync_req| {
            const target_str = try protocol_types.uuidToString(sync_req.target_stream_id, allocator);
            defer allocator.free(target_str);
            try w.writeStringField("target_stream_id", target_str);
        },
        .sync => |sync_msg| {
            const target_str = try protocol_types.uuidToString(sync_msg.target_stream_id, allocator);
            defer allocator.free(target_str);
            try w.writeStringField("target_stream_id", target_str);
            if (sync_msg.partial) |partial| {
                try w.writeKey("partial");
                try serializeResultPayload(w, partial, allocator);
            }
        },
        .stream_request => |req| {
            // Nest model fields inside a "model" object per PROTOCOL.md
            try w.writeKey("model");
            try w.beginObject();
            try w.writeStringField("id", req.model.id);
            try w.writeStringField("name", req.model.name);
            try w.writeStringField("api", req.model.api);
            try w.writeStringField("provider", req.model.provider);
            try w.writeStringField("base_url", req.model.base_url);
            try w.endObject();
            try w.writeBoolField("include_partial", req.include_partial);

            // Serialize context
            try w.writeKey("context");
            try serializeContext(w, req.context, allocator);

            // Serialize options if present
            if (req.options) |opts| {
                try w.writeKey("options");
                try serializeStreamOptions(w, opts, allocator);
            }
        },
        .complete_request => |req| {
            // Nest model fields inside a "model" object per PROTOCOL.md
            try w.writeKey("model");
            try w.beginObject();
            try w.writeStringField("id", req.model.id);
            try w.writeStringField("name", req.model.name);
            try w.writeStringField("api", req.model.api);
            try w.writeStringField("provider", req.model.provider);
            try w.writeStringField("base_url", req.model.base_url);
            try w.endObject();

            // Serialize context
            try w.writeKey("context");
            try serializeContext(w, req.context, allocator);

            // Serialize options if present
            if (req.options) |opts| {
                try w.writeKey("options");
                try serializeStreamOptions(w, opts, allocator);
            }
        },
        .abort_request => |req| {
            const target_str = try protocol_types.uuidToString(req.target_stream_id, allocator);
            defer allocator.free(target_str);
            try w.writeStringField("target_stream_id", target_str);
            if (req.getReason()) |reason| {
                try w.writeStringField("reason", reason);
            }
        },
        .ack => |ack| {
            const acknowledged_id_str = try protocol_types.uuidToString(ack.acknowledged_id, allocator);
            defer allocator.free(acknowledged_id_str);
            try w.writeStringField("acknowledged_id", acknowledged_id_str);
        },
        .nack => |nack| {
            const rejected_id_str = try protocol_types.uuidToString(nack.rejected_id, allocator);
            defer allocator.free(rejected_id_str);
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
    }

    try w.endObject();
}

/// Serialize context
fn serializeContext(
    w: *json_writer.JsonWriter,
    context: ai_types.Context,
    allocator: std.mem.Allocator,
) !void {
    try w.beginObject();

    if (context.getSystemPrompt()) |prompt| {
        try w.writeStringField("system_prompt", prompt);
    }

    // Serialize messages
    try w.writeKey("messages");
    try w.beginArray();
    for (context.messages) |msg| {
        try serializeMessage(w, msg, allocator);
    }
    try w.endArray();

    // Serialize tools if present
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

/// Serialize a message
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

/// Serialize user content
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

/// Serialize user content part
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

/// Serialize tool
fn serializeTool(w: *json_writer.JsonWriter, tool: ai_types.Tool) !void {
    try w.beginObject();
    try w.writeStringField("name", tool.name);
    try w.writeStringField("description", tool.description);
    try w.writeKey("parameters_schema_json");
    try w.writeRawJson(tool.parameters_schema_json);
    try w.endObject();
}

/// Serialize stream options
fn serializeStreamOptions(
    w: *json_writer.JsonWriter,
    opts: ai_types.StreamOptions,
    _: std.mem.Allocator,
) !void {
    try w.beginObject();

    if (opts.api_key) |key| {
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
    if (opts.session_id) |sid| {
        try w.writeStringField("session_id", sid);
    }
    if (opts.thinking_enabled) {
        try w.writeBoolField("thinking_enabled", true);
    }
    if (opts.thinking_budget_tokens) |budget| {
        try w.writeIntField("thinking_budget_tokens", budget);
    }
    if (opts.thinking_effort) |effort| {
        try w.writeStringField("thinking_effort", effort);
    }
    if (opts.reasoning_effort) |effort| {
        try w.writeStringField("reasoning_effort", effort);
    }
    if (opts.reasoning_summary) |summary| {
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

    // Serialize headers if present
    if (opts.headers) |headers| {
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

    // Retry config
    if (opts.retry.max_retry_delay_ms) |delay| {
        try w.writeKey("retry");
        try w.beginObject();
        try w.writeIntField("max_retry_delay_ms", delay);
        try w.endObject();
    }

    try w.endObject();
}

/// Serialize event payload (without "type" field - type is at envelope top level)
fn serializeEventPayload(
    w: *json_writer.JsonWriter,
    event: ai_types.AssistantMessageEvent,
    allocator: std.mem.Allocator,
) !void {
    // Use the transport serializeEvent and extract fields
    const event_json = try transport.serializeEvent(event, allocator);
    defer allocator.free(event_json);

    // Parse the event JSON and copy fields (excluding "type" which is at top level)
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, event_json, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        // Skip "type" field - it's already at the envelope top level per PROTOCOL.md
        if (std.mem.eql(u8, entry.key_ptr.*, "type")) continue;
        try w.writeKey(entry.key_ptr.*);
        try writeJsonValue(w, entry.value_ptr.*, allocator);
    }
}

/// Serialize result payload
fn serializeResultPayload(
    w: *json_writer.JsonWriter,
    result: ai_types.AssistantMessage,
    allocator: std.mem.Allocator,
) !void {
    // Use the transport serializeResult and extract fields
    const result_json = try transport.serializeResult(result, allocator);
    defer allocator.free(result_json);

    // Parse the result JSON and copy fields
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        try w.writeKey(entry.key_ptr.*);
        try writeJsonValue(w, entry.value_ptr.*, allocator);
    }
}

/// Write a json.Value to JsonWriter
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
            // Float formatting
            const writer = w.buffer.writer(allocator);
            try std.fmt.format(writer, "{d}", .{f});
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

/// Deserialize envelope from JSON
pub fn deserializeEnvelope(
    data: []const u8,
    allocator: std.mem.Allocator,
) !protocol_types.Envelope {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;

    // Parse version
    const version: u8 = if (obj.get("version")) |v|
        @intCast(v.integer)
    else
        1;

    // Parse stream_id
    const stream_id_str = obj.get("stream_id").?.string;
    const stream_id = protocol_types.parseUuid(stream_id_str) orelse return error.InvalidUuid;

    // Parse message_id
    const message_id_str = obj.get("message_id").?.string;
    const message_id = protocol_types.parseUuid(message_id_str) orelse return error.InvalidUuid;

    // Parse sequence
    const sequence: u64 = @intCast(obj.get("sequence").?.integer);

    // Parse timestamp
    const timestamp: i64 = obj.get("timestamp").?.integer;

    // Parse in_reply_to if present
    var in_reply_to: ?protocol_types.Uuid = null;
    if (obj.get("in_reply_to")) |reply_val| {
        in_reply_to = protocol_types.parseUuid(reply_val.string) orelse return error.InvalidUuid;
    }

    // Parse type
    const type_str = obj.get("type").?.string;

    // Parse payload
    const payload_obj = obj.get("payload").?.object;
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

/// Deserialize payload based on type
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

    // Check if type_str is an event type - the type is at top level per PROTOCOL.md
    if (isEventType(type_str)) {
        const event = try transport.parseAssistantMessageEvent(type_str, obj, allocator);
        return .{ .event = event };
    }

    return error.UnknownPayloadType;
}

/// Check if a string is a known event type
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

/// Deserialize stream request
fn deserializeStreamRequest(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.StreamRequest {
    // Parse nested model object per PROTOCOL.md
    const model_obj = obj.get("model").?.object;

    // Allocate each field separately with errdefer to avoid leaks on OOM
    const id = try allocator.dupe(u8, model_obj.get("id").?.string);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, model_obj.get("name").?.string);
    errdefer allocator.free(name);
    const api = try allocator.dupe(u8, model_obj.get("api").?.string);
    errdefer allocator.free(api);
    const provider = try allocator.dupe(u8, model_obj.get("provider").?.string);
    errdefer allocator.free(provider);
    const base_url = try allocator.dupe(u8, model_obj.get("base_url").?.string);
    errdefer allocator.free(base_url);

    const model = ai_types.Model{
        .id = id,
        .name = name,
        .api = api,
        .provider = provider,
        .base_url = base_url,
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 0,
        .max_tokens = 0,
        .owned_strings = true, // Mark as owned since we duped the strings
    };

    const context = if (obj.get("context")) |ctx_val|
        try deserializeContext(ctx_val.object, allocator)
    else
        ai_types.Context{ .messages = &.{} };

    const include_partial = if (obj.get("include_partial")) |ip|
        ip.bool
    else
        false;

    const options = if (obj.get("options")) |opts_val|
        try deserializeStreamOptions(opts_val.object, allocator)
    else
        null;

    return .{
        .model = model,
        .context = context,
        .options = options,
        .include_partial = include_partial,
    };
}

/// Deserialize complete request
fn deserializeCompleteRequest(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.CompleteRequest {
    // Parse nested model object per PROTOCOL.md
    const model_obj = obj.get("model").?.object;

    // Allocate each field separately with errdefer to avoid leaks on OOM
    const id = try allocator.dupe(u8, model_obj.get("id").?.string);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, model_obj.get("name").?.string);
    errdefer allocator.free(name);
    const api = try allocator.dupe(u8, model_obj.get("api").?.string);
    errdefer allocator.free(api);
    const provider = try allocator.dupe(u8, model_obj.get("provider").?.string);
    errdefer allocator.free(provider);
    const base_url = try allocator.dupe(u8, model_obj.get("base_url").?.string);
    errdefer allocator.free(base_url);

    const model = ai_types.Model{
        .id = id,
        .name = name,
        .api = api,
        .provider = provider,
        .base_url = base_url,
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 0,
        .max_tokens = 0,
        .owned_strings = true, // Mark as owned since we duped the strings
    };

    const context = if (obj.get("context")) |ctx_val|
        try deserializeContext(ctx_val.object, allocator)
    else
        ai_types.Context{ .messages = &.{} };

    const options = if (obj.get("options")) |opts_val|
        try deserializeStreamOptions(opts_val.object, allocator)
    else
        null;

    return .{
        .model = model,
        .context = context,
        .options = options,
    };
}

/// Deserialize abort request
fn deserializeAbortRequest(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.AbortRequest {
    const target_str = obj.get("target_stream_id").?.string;
    const target_id = protocol_types.parseUuid(target_str) orelse return error.InvalidUuid;

    const reason = if (obj.get("reason")) |r|
        protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, r.string))
    else
        protocol_types.OwnedSlice(u8).initBorrowed("");

    return .{
        .target_stream_id = target_id,
        .reason = reason,
    };
}

/// Deserialize ack
fn deserializeAck(obj: std.json.ObjectMap) !protocol_types.Ack {
    const acknowledged_id_str = obj.get("acknowledged_id").?.string;
    const acknowledged_id = protocol_types.parseUuid(acknowledged_id_str) orelse return error.InvalidUuid;

    return .{
        .acknowledged_id = acknowledged_id,
    };
}

/// Deserialize nack
fn deserializeNack(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.Nack {
    const rejected_id_str = obj.get("rejected_id").?.string;
    const rejected_id = protocol_types.parseUuid(rejected_id_str) orelse return error.InvalidUuid;

    const reason = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, obj.get("reason").?.string));
    errdefer {
        var mutable_reason = reason;
        mutable_reason.deinit(allocator);
    }

    const error_code = if (obj.get("error_code")) |code_val|
        parseErrorCode(code_val.string)
    else
        null;

    var supported_versions = protocol_types.OwnedSlice(protocol_types.OwnedSlice(u8)).initBorrowed(&.{});
    if (obj.get("supported_versions")) |versions_val| {
        const versions_arr = versions_val.array;
        const versions = try allocator.alloc(protocol_types.OwnedSlice(u8), versions_arr.items.len);
        var allocated_count: usize = 0;
        errdefer {
            for (versions[0..allocated_count]) |*v| v.deinit(allocator);
            allocator.free(versions);
        }
        for (versions_arr.items, 0..) |item, i| {
            versions[i] = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, item.string));
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

/// Deserialize stream error
fn deserializeStreamError(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.StreamError {
    const code_str = obj.get("code").?.string;
    const code = parseErrorCode(code_str);

    const message = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, obj.get("message").?.string));

    return .{
        .code = code,
        .message = message,
    };
}

/// Deserialize pong
fn deserializePong(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.Pong {
    const ping_id = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, obj.get("ping_id").?.string));
    return .{ .ping_id = ping_id };
}

/// Deserialize goodbye
fn deserializeGoodbye(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.Goodbye {
    const reason = if (obj.get("reason")) |r|
        protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, r.string))
    else
        protocol_types.OwnedSlice(u8).initBorrowed("");

    return .{ .reason = reason };
}

/// Deserialize sync_request
fn deserializeSyncRequest(obj: std.json.ObjectMap) !protocol_types.SyncRequest {
    const target_str = obj.get("target_stream_id").?.string;
    const target_id = protocol_types.parseUuid(target_str) orelse return error.InvalidUuid;

    return .{ .target_stream_id = target_id };
}

/// Deserialize sync
fn deserializeSync(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !protocol_types.Sync {
    const target_str = obj.get("target_stream_id").?.string;
    const target_stream_id = protocol_types.parseUuid(target_str) orelse return error.InvalidUuid;

    const partial = if (obj.get("partial")) |p|
        try transport.parseAssistantMessage(p.object, allocator)
    else
        null;

    return .{
        .target_stream_id = target_stream_id,
        .partial = partial,
    };
}

/// Parse error code from string
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
    return .internal_error;
}

/// Deserialize context
fn deserializeContext(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !ai_types.Context {
    var system_prompt = if (obj.get("system_prompt")) |sp|
        ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, sp.string))
    else
        ai_types.OwnedSlice(u8).initBorrowed("");
    errdefer system_prompt.deinit(allocator);

    const messages_arr = if (obj.get("messages")) |msgs_val|
        msgs_val.array
    else {
        const empty_messages = try allocator.alloc(ai_types.Message, 0);
        return ai_types.Context{
            .system_prompt = system_prompt,
            .messages = empty_messages,
            .owned_strings = true,
        };
    };

    const messages = try allocator.alloc(ai_types.Message, messages_arr.items.len);
    errdefer allocator.free(messages);

    for (messages_arr.items, 0..) |item, i| {
        messages[i] = try deserializeMessage(item.object, allocator);
    }

    var tools: ?[]ai_types.Tool = null;
    if (obj.get("tools")) |tools_val| {
        const tools_arr = tools_val.array;
        tools = try allocator.alloc(ai_types.Tool, tools_arr.items.len);
        for (tools_arr.items, 0..) |item, i| {
            tools.?[i] = try deserializeTool(item.object, allocator);
        }
    }

    return .{
        .system_prompt = system_prompt,
        .messages = messages,
        .tools = tools,
        .owned_strings = true, // Mark as owned since we allocated all strings/arrays
    };
}

/// Deserialize message
fn deserializeMessage(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !ai_types.Message {
    const role = obj.get("role").?.string;

    if (std.mem.eql(u8, role, "user")) {
        const timestamp: i64 = if (obj.get("timestamp")) |ts| ts.integer else 0;
        const content = try deserializeUserContent(obj.get("content").?, allocator);

        return .{ .user = .{
            .content = content,
            .timestamp = timestamp,
        } };
    }

    if (std.mem.eql(u8, role, "assistant")) {
        return .{ .assistant = try transport.parseAssistantMessage(obj, allocator) };
    }

    if (std.mem.eql(u8, role, "tool")) {
        const tool_call_id = try allocator.dupe(u8, obj.get("tool_call_id").?.string);
        const tool_name = try allocator.dupe(u8, obj.get("tool_name").?.string);
        const timestamp: i64 = if (obj.get("timestamp")) |ts| ts.integer else 0;
        const is_error = if (obj.get("is_error")) |ie| ie.bool else false;

        const content_arr = if (obj.get("content")) |c| c.array else return error.MissingContent;
        const content = try allocator.alloc(ai_types.UserContentPart, content_arr.items.len);
        for (content_arr.items, 0..) |item, i| {
            content[i] = try deserializeUserContentPart(item.object, allocator);
        }

        const details_json = if (obj.get("details_json")) |dj|
            ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, dj.string))
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

/// Deserialize user content
fn deserializeUserContent(
    value: std.json.Value,
    allocator: std.mem.Allocator,
) !ai_types.UserContent {
    switch (value) {
        .string => |s| return .{ .text = try allocator.dupe(u8, s) },
        .array => |arr| {
            const parts = try allocator.alloc(ai_types.UserContentPart, arr.items.len);
            for (arr.items, 0..) |item, i| {
                parts[i] = try deserializeUserContentPart(item.object, allocator);
            }
            return .{ .parts = parts };
        },
        else => return error.InvalidUserContent,
    }
}

/// Deserialize user content part
fn deserializeUserContentPart(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !ai_types.UserContentPart {
    const type_str = obj.get("type").?.string;

    if (std.mem.eql(u8, type_str, "text")) {
        const text = try allocator.dupe(u8, obj.get("text").?.string);
        const text_signature = if (obj.get("text_signature")) |sig|
            try allocator.dupe(u8, sig.string)
        else
            null;
        return .{ .text = .{ .text = text, .text_signature = text_signature } };
    }

    if (std.mem.eql(u8, type_str, "image")) {
        const data = try allocator.dupe(u8, obj.get("data").?.string);
        const mime_type = try allocator.dupe(u8, obj.get("mime_type").?.string);
        return .{ .image = .{ .data = data, .mime_type = mime_type } };
    }

    return error.UnknownContentPartType;
}

/// Deserialize tool
fn deserializeTool(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !ai_types.Tool {
    const name = try allocator.dupe(u8, obj.get("name").?.string);
    const description = try allocator.dupe(u8, obj.get("description").?.string);

    // Get parameters_schema_json - it should be a string already in the protocol
    // If it's a JSON object, we need to serialize it
    const schema_json = if (obj.get("parameters_schema_json")) |schema| switch (schema) {
        .string => |s| try allocator.dupe(u8, s),
        else => blk: {
            var buffer = std.ArrayList(u8){};
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

/// Deserialize stream options
fn deserializeStreamOptions(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !ai_types.StreamOptions {
    var opts: ai_types.StreamOptions = .{
        .owned_strings = true, // Mark as owned since we dupe string fields
    };

    if (obj.get("api_key")) |key| {
        opts.api_key = try allocator.dupe(u8, key.string);
    }
    if (obj.get("temperature")) |temp| {
        opts.temperature = switch (temp) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }
    if (obj.get("max_tokens")) |max| {
        opts.max_tokens = @intCast(max.integer);
    }
    if (obj.get("cache_retention")) |ret| {
        opts.cache_retention = parseCacheRetention(ret.string);
    }
    if (obj.get("session_id")) |sid| {
        opts.session_id = try allocator.dupe(u8, sid.string);
    }
    if (obj.get("thinking_enabled")) |te| {
        opts.thinking_enabled = te.bool;
    }
    if (obj.get("thinking_budget_tokens")) |tbt| {
        opts.thinking_budget_tokens = @intCast(tbt.integer);
    }
    if (obj.get("thinking_effort")) |effort| {
        opts.thinking_effort = try allocator.dupe(u8, effort.string);
    }
    if (obj.get("reasoning_effort")) |effort| {
        opts.reasoning_effort = try allocator.dupe(u8, effort.string);
    }
    if (obj.get("reasoning_summary")) |summary| {
        opts.reasoning_summary = try allocator.dupe(u8, summary.string);
    }
    if (obj.get("include_reasoning_encrypted")) |ire| {
        opts.include_reasoning_encrypted = ire.bool;
    }
    if (obj.get("reasoning_enabled")) |re| {
        opts.reasoning_enabled = re.bool;
    }
    if (obj.get("service_tier")) |tier| {
        opts.service_tier = parseServiceTier(tier.string);
    }
    if (obj.get("metadata")) |meta| {
        opts.metadata = .{
            .user_id = if (meta.object.get("user_id")) |uid|
                ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, uid.string))
            else
                ai_types.OwnedSlice(u8).initBorrowed(""),
        };
    }
    if (obj.get("tool_choice")) |choice| {
        const choice_type = choice.object.get("type").?.string;
        if (std.mem.eql(u8, choice_type, "auto")) {
            opts.tool_choice = .auto;
        } else if (std.mem.eql(u8, choice_type, "none")) {
            opts.tool_choice = .none;
        } else if (std.mem.eql(u8, choice_type, "required")) {
            opts.tool_choice = .required;
        } else if (std.mem.eql(u8, choice_type, "function")) {
            opts.tool_choice = .{ .function = try allocator.dupe(u8, choice.object.get("function").?.string) };
        }
    }
    if (obj.get("http_timeout_ms")) |timeout| {
        opts.http_timeout_ms = @intCast(timeout.integer);
    }
    if (obj.get("ping_interval_ms")) |interval| {
        opts.ping_interval_ms = @intCast(interval.integer);
    }

    return opts;
}

/// Parse cache retention from string
fn parseCacheRetention(str: []const u8) ?ai_types.CacheRetention {
    if (std.mem.eql(u8, str, "none")) return .none;
    if (std.mem.eql(u8, str, "short")) return .short;
    if (std.mem.eql(u8, str, "long")) return .long;
    return null;
}

/// Parse service tier from string
fn parseServiceTier(str: []const u8) ?ai_types.ServiceTier {
    if (std.mem.eql(u8, str, "default")) return .default;
    if (std.mem.eql(u8, str, "flex")) return .flex;
    if (std.mem.eql(u8, str, "priority")) return .priority;
    return null;
}

/// Create a new envelope with auto-generated IDs and timestamp
pub fn createEnvelope(
    stream_id: protocol_types.Uuid,
    sequence: u64,
    payload: protocol_types.Payload,
    allocator: std.mem.Allocator,
) protocol_types.Envelope {
    _ = allocator; // Not needed for basic envelope creation
    return .{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = sequence,
        .timestamp = std.time.milliTimestamp(),
        .payload = payload,
    };
}

/// Create a reply envelope (sets in_reply_to)
pub fn createReply(
    original: protocol_types.Envelope,
    payload: protocol_types.Payload,
    allocator: std.mem.Allocator,
) protocol_types.Envelope {
    _ = allocator;
    return .{
        .stream_id = original.stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = original.sequence + 1,
        .in_reply_to = original.message_id,
        .timestamp = std.time.milliTimestamp(),
        .payload = payload,
    };
}

/// Create an ack envelope
pub fn createAck(
    original: protocol_types.Envelope,
    allocator: std.mem.Allocator,
) protocol_types.Envelope {
    _ = allocator;
    return .{
        .stream_id = original.stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = original.sequence + 1,
        .in_reply_to = original.message_id,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .ack = .{
            .acknowledged_id = original.message_id,
        } },
    };
}

/// Create a nack envelope
pub fn createNack(
    original: protocol_types.Envelope,
    reason: []const u8,
    error_code: ?protocol_types.ErrorCode,
    allocator: std.mem.Allocator,
) !protocol_types.Envelope {
    const reason_copy = try allocator.dupe(u8, reason);
    return .{
        .stream_id = original.stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = original.sequence + 1,
        .in_reply_to = original.message_id,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .nack = .{
            .rejected_id = original.message_id,
            .reason = protocol_types.OwnedSlice(u8).initOwned(reason_copy),
            .error_code = error_code,
        } },
    };
}

// Custom error set
pub const EnvelopeError = error{
    InvalidUuid,
    UnknownPayloadType,
    UnknownMessageRole,
    InvalidUserContent,
    UnknownContentPartType,
    MissingContent,
};

// Tests

test "serializeEnvelope with ping payload" {
    const allocator = std.testing.allocator;

    const envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = 1708234567890,
        .payload = .ping,
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    // Check that the JSON contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"ping\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sequence\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"timestamp\":1708234567890") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"payload\":{}") != null);
}

test "serializeEnvelope with pong payload" {
    const allocator = std.testing.allocator;

    const ping_id = try allocator.dupe(u8, "test-ping-123");
    // Note: ping_id ownership is transferred to envelope, will be freed by envelope.deinit

    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 2,
        .timestamp = 1708234567900,
        .payload = .{ .pong = .{ .ping_id = protocol_types.OwnedSlice(u8).initOwned(ping_id) } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"pong\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sequence\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ping_id\":\"test-ping-123\"") != null);

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
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
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

    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"stream_request\"") != null);
    // Check for nested model object format per PROTOCOL.md
    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"gpt-4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"GPT-4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"system_prompt\":\"You are helpful.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"include_partial\":true") != null);

    envelope.deinit(allocator);
}

test "deserializeEnvelope parses valid JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "ping",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
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

    // Verify stream_id
    const expected_stream_id: protocol_types.Uuid = .{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10 };
    try std.testing.expectEqualSlices(u8, &expected_stream_id, &envelope.stream_id);
}

test "serializeEnvelope and deserializeEnvelope roundtrip with ping" {
    const allocator = std.testing.allocator;

    const original = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 42,
        .timestamp = std.time.milliTimestamp(),
        .in_reply_to = protocol_types.generateUuid(),
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

    const acknowledged_id = protocol_types.generateUuid();

    const original = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
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

    const rejected_id = protocol_types.generateUuid();
    const reason = try allocator.dupe(u8, "Test error reason");
    // Note: reason ownership is transferred to original, will be freed by original.deinit

    var original = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
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

    const stream_id = protocol_types.generateUuid();
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
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 5,
        .timestamp = std.time.milliTimestamp(),
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

    var original = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
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
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
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

test "serializeEnvelope with abort_request payload" {
    const allocator = std.testing.allocator;

    const reason = try allocator.dupe(u8, "User cancelled");
    // Note: reason ownership is transferred to envelope, will be freed by envelope.deinit

    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 10,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .abort_request = .{
            .target_stream_id = protocol_types.generateUuid(),
            .reason = protocol_types.OwnedSlice(u8).initOwned(reason),
        } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"abort_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reason\":\"User cancelled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"target_stream_id\"") != null);

    envelope.deinit(allocator);
}

test "serializeEnvelope with stream_error payload" {
    const allocator = std.testing.allocator;

    const msg = try allocator.dupe(u8, "Connection timeout");
    // Note: msg ownership is transferred to envelope, will be freed by envelope.deinit

    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 20,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_error = .{
            .code = .provider_error,
            .message = protocol_types.OwnedSlice(u8).initOwned(msg),
        } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"stream_error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"code\":\"provider_error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"message\":\"Connection timeout\"") != null);

    envelope.deinit(allocator);
}

test "deserializeEnvelope with version field defaults to 1" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "ping",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 1,
        \\  "timestamp": 1708234567890,
        \\  "payload": {}
        \\}
    ;

    var envelope = try deserializeEnvelope(json, allocator);
    defer envelope.deinit(allocator);

    // Version should default to 1 when not specified
    try std.testing.expect(envelope.version == 1);
}

test "deserializeEnvelope with explicit version" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "ping",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
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
    // This test verifies that deinit properly frees all allocated memory
    // when deserializing a stream_request (Issue #3)
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "stream_request",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
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

    // Verify the envelope was parsed correctly
    try std.testing.expect(envelope.payload == .stream_request);
    try std.testing.expectEqualStrings("gpt-4o", envelope.payload.stream_request.model.id);
    try std.testing.expectEqualStrings("GPT-4o", envelope.payload.stream_request.model.name);
    try std.testing.expect(envelope.payload.stream_request.model.owned_strings);
    try std.testing.expect(envelope.payload.stream_request.context.owned_strings);

    // deinit will be called by defer - if it doesn't free all memory,
    // the test will fail with a memory leak error
}

test "deserializeEnvelope with complete_request frees all memory" {
    // This test verifies that deinit properly frees all allocated memory
    // when deserializing a complete_request (Issue #3)
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "complete_request",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
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

    // Verify the envelope was parsed correctly
    try std.testing.expect(envelope.payload == .complete_request);
    try std.testing.expectEqualStrings("claude-3", envelope.payload.complete_request.model.id);
    try std.testing.expect(envelope.payload.complete_request.model.owned_strings);
    try std.testing.expect(envelope.payload.complete_request.context.owned_strings);

    // deinit will be called by defer - if it doesn't free all memory,
    // the test will fail with a memory leak error
}

test "deserializeEnvelope with complex context frees all memory" {
    // Test with tool_result message to verify complete cleanup
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "stream_request",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
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

    // Verify parsing
    try std.testing.expect(envelope.payload == .stream_request);
    try std.testing.expect(envelope.payload.stream_request.context.messages.len == 2);

    // deinit will be called by defer - verifies complete cleanup
}

test "serializeEnvelope with goodbye payload" {
    const allocator = std.testing.allocator;

    const reason = try allocator.dupe(u8, "Server shutting down");
    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 100,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .goodbye = .{ .reason = protocol_types.OwnedSlice(u8).initOwned(reason) } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"goodbye\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reason\":\"Server shutting down\"") != null);

    envelope.deinit(allocator);
}

test "serializeEnvelope with goodbye payload (no reason)" {
    const allocator = std.testing.allocator;

    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 100,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .goodbye = .{} },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"goodbye\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reason\"") == null); // reason should not be present

    envelope.deinit(allocator);
}

test "serializeEnvelope with sync_request payload" {
    const allocator = std.testing.allocator;

    const target_id = protocol_types.generateUuid();
    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 50,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .sync_request = .{ .target_stream_id = target_id } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"sync_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"target_stream_id\"") != null);

    envelope.deinit(allocator);
}

test "serializeEnvelope with sync payload" {
    const allocator = std.testing.allocator;

    // Create a partial with empty content (no strings to free)
    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
        .owned_strings = false,
    };
    var envelope = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 60,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .sync = .{
            .target_stream_id = protocol_types.generateUuid(),
            .partial = partial,
        } },
    };

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"sync\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"target_stream_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"partial\"") != null);

    envelope.deinit(allocator);
}

test "deserializeEnvelope with pong payload" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "pong",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 2,
        \\  "timestamp": 1708234567900,
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
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 100,
        \\  "timestamp": 1708234567900,
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
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 100,
        \\  "timestamp": 1708234567900,
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
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 50,
        \\  "timestamp": 1708234567900,
        \\  "payload": {
        \\    "target_stream_id": "abcdef01-2345-6789-abcd-ef0123456789"
        \\  }
        \\}
    ;

    var envelope = try deserializeEnvelope(json, allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(envelope.payload == .sync_request);

    const expected_target: protocol_types.Uuid = .{ 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89 };
    try std.testing.expectEqualSlices(u8, &expected_target, &envelope.payload.sync_request.target_stream_id);
}

test "deserializeEnvelope with sync payload" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "type": "sync",
        \\  "stream_id": "01234567-89ab-cdef-fedc-ba9876543210",
        \\  "message_id": "12345678-9abc-def0-fedc-ba9876543210",
        \\  "sequence": 60,
        \\  "timestamp": 1708234567900,
        \\  "payload": {
        \\    "target_stream_id": "abcdef01-2345-6789-abcd-ef0123456789",
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
    const expected_target: protocol_types.Uuid = .{ 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89 };
    try std.testing.expectEqualSlices(u8, &expected_target, &envelope.payload.sync.target_stream_id);
    try std.testing.expect(envelope.payload.sync.partial != null);
}

test "serializeEnvelope and deserializeEnvelope roundtrip with pong" {
    const allocator = std.testing.allocator;

    const ping_id = try allocator.dupe(u8, "roundtrip-ping-id");
    var original = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 10,
        .timestamp = std.time.milliTimestamp(),
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
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 200,
        .timestamp = std.time.milliTimestamp(),
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
