const std = @import("std");
const compat = @import("compat");
const tool_types = @import("tool_types");
const fields = @import("envelope_fields");
const json_writer = @import("json_writer");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const protocol_types = tool_types;

pub fn serializeEnvelope(env: tool_types.Envelope, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);

    try w.beginObject();
    try w.writeStringField("type", @tagName(env.payload));

    const server_id_str = try tool_types.ulidToString(env.server_id, allocator);
    defer allocator.free(server_id_str);
    try w.writeStringField("server_id", server_id_str);

    const message_id_str = try tool_types.ulidToString(env.message_id, allocator);
    defer allocator.free(message_id_str);
    try w.writeStringField("message_id", message_id_str);

    try w.writeIntField("sequence", env.sequence);
    try w.writeIntField("timestamp", env.timestamp);
    try w.writeIntField("version", env.version);

    if (env.in_reply_to) |reply_to| {
        const reply_to_str = try tool_types.ulidToString(reply_to, allocator);
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
            const execution_id_str = try tool_types.ulidToString(req.execution_id, allocator);
            defer allocator.free(execution_id_str);
            try w.writeStringField("execution_id", execution_id_str);
            try w.writeStringField("tool_call_id", req.tool_call_id);
            try w.writeStringField("tool_name", req.tool_name);
            try w.writeStringField("args_json", req.args_json);
            if (req.timeout_ms) |timeout_ms| try w.writeIntField("timeout_ms", timeout_ms);
            if (req.getStreamCallbackUrl()) |url| try w.writeStringField("stream_callback_url", url);
        },
        .tool_stream => |update| {
            const execution_id_str = try tool_types.ulidToString(update.execution_id, allocator);
            defer allocator.free(execution_id_str);
            try w.writeStringField("execution_id", execution_id_str);
            try w.writeStringField("tool_call_id", update.tool_call_id);
            try w.writeStringField("partial_result_json", update.partial_result_json);
            if (update.progress) |progress| try w.writeIntField("progress", progress);
            if (update.getStatus()) |status| try w.writeStringField("status", status);
        },
        .tool_result => |res| {
            const execution_id_str = try tool_types.ulidToString(res.execution_id, allocator);
            defer allocator.free(execution_id_str);
            try w.writeStringField("execution_id", execution_id_str);
            try w.writeStringField("tool_call_id", res.tool_call_id);
            try w.writeStringField("result_json", res.result_json);
            try w.writeBoolField("is_error", res.is_error);
            if (res.getErrorMessage()) |msg| try w.writeStringField("error_message", msg);
            if (res.getDetailsJson()) |details| try w.writeStringField("details_json", details);
            if (res.artifacts.slice().len > 0) {
                try w.writeKey("artifacts");
                try w.beginArray();
                for (res.artifacts.slice()) |artifact| {
                    try serializeArtifactReference(w, artifact);
                }
                try w.endArray();
            }
            try w.writeIntField("duration_ms", res.duration_ms);
        },
        .tool_cancel => |req| {
            const execution_id_str = try tool_types.ulidToString(req.execution_id, allocator);
            defer allocator.free(execution_id_str);
            try w.writeStringField("execution_id", execution_id_str);
            if (req.getReason()) |reason| try w.writeStringField("reason", reason);
        },
        .tool_cancelled => |cancelled| {
            const execution_id_str = try tool_types.ulidToString(cancelled.execution_id, allocator);
            defer allocator.free(execution_id_str);
            try w.writeStringField("execution_id", execution_id_str);
        },
        .tool_error => |err| {
            const execution_id_str = try tool_types.ulidToString(err.execution_id, allocator);
            defer allocator.free(execution_id_str);
            try w.writeStringField("execution_id", execution_id_str);
            try w.writeStringField("code", @tagName(err.code));
            try w.writeStringField("message", err.message);
        },
        .tool_status => |req| {
            const execution_id_str = try tool_types.ulidToString(req.execution_id, allocator);
            defer allocator.free(execution_id_str);
            try w.writeStringField("execution_id", execution_id_str);
        },
        .tool_status_response => |info| {
            const execution_id_str = try tool_types.ulidToString(info.execution_id, allocator);
            defer allocator.free(execution_id_str);
            try w.writeStringField("execution_id", execution_id_str);
            try w.writeStringField("tool_name", info.tool_name);
            try w.writeStringField("status", @tagName(info.status));
            try w.writeIntField("started_at", info.started_at);
            if (info.completed_at) |completed_at| try w.writeIntField("completed_at", completed_at);
        },
        .artifact_retrieve => |req| {
            try w.writeStringField("artifact_id", req.artifact_id);
            if (req.byte_offset) |offset| try w.writeIntField("byte_offset", offset);
            if (req.byte_limit) |limit| try w.writeIntField("byte_limit", limit);
        },
        .artifact_retrieved => |res| {
            try w.writeKey("artifact");
            try serializeArtifactReference(w, res.artifact);
            if (res.getContentJson()) |content_json| try w.writeStringField("content_json", content_json);
        },
        .artifact_search => |req| {
            try w.writeStringField("query", req.query);
            if (req.limit) |limit| try w.writeIntField("limit", limit);
        },
        .artifact_search_result => |res| {
            try w.writeKey("results");
            try w.beginArray();
            for (res.results) |result| {
                try w.beginObject();
                try w.writeKey("artifact");
                try serializeArtifactReference(w, result.artifact);
                if (result.getSnippet()) |snippet| try w.writeStringField("snippet", snippet);
                if (result.score) |score| {
                    try w.writeKey("score");
                    try w.writeFloat(score);
                }
                try w.endObject();
            }
            try w.endArray();
        },
        .hashline_read => |req| {
            try w.writeStringField("path", req.path);
            try w.writeBoolField("feature_enabled", req.feature_enabled);
            if (req.byte_limit) |limit| try w.writeIntField("byte_limit", limit);
        },
        .hashline_read_result => |res| {
            try w.writeStringField("path", res.path);
            try w.writeKey("lines");
            try w.beginArray();
            for (res.lines) |line| {
                try w.beginObject();
                try w.writeIntField("line", line.line);
                try w.writeStringField("hash", line.hash);
                try w.writeStringField("text", line.text);
                try w.endObject();
            }
            try w.endArray();
        },
        .hashline_edit => |req| {
            try w.writeStringField("path", req.path);
            try w.writeStringField("operation", @tagName(req.operation));
            try w.writeIntField("start_line", req.start_line);
            try w.writeStringField("start_hash", req.start_hash);
            if (req.end_line) |line| try w.writeIntField("end_line", line);
            if (req.getEndHash()) |hash| try w.writeStringField("end_hash", hash);
            if (req.getReplacement()) |replacement| try w.writeStringField("replacement", replacement);
            try w.writeBoolField("feature_enabled", req.feature_enabled);
        },
        .hashline_edit_result => |res| {
            try w.writeStringField("path", res.path);
            try w.writeBoolField("applied", res.applied);
            if (res.new_artifact) |artifact| {
                try w.writeKey("new_artifact");
                try serializeArtifactReference(w, artifact);
            }
        },
        .ping => {},
        .pong => |pong| try w.writeStringField("ping_id", pong.ping_id.slice()),
        .goodbye => |goodbye| {
            if (goodbye.getReason()) |reason| try w.writeStringField("reason", reason);
        },
    }

    try w.endObject();
}

fn serializeArtifactReference(w: *json_writer.JsonWriter, artifact: tool_types.ArtifactReference) !void {
    try w.beginObject();
    try w.writeStringField("artifact_id", artifact.artifact_id);
    if (artifact.getUri()) |uri| try w.writeStringField("uri", uri);
    if (artifact.getMimeType()) |mime_type| try w.writeStringField("mime_type", mime_type);
    if (artifact.byte_size) |byte_size| try w.writeIntField("byte_size", byte_size);
    if (artifact.getSha256()) |sha256| try w.writeStringField("sha256", sha256);
    if (artifact.getDescription()) |description| try w.writeStringField("description", description);
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

    const root = try fields.rootObject(parsed.value);
    const type_str = try fields.requiredString(root, "type");
    const server_id = try parseUlidRequired(try fields.requiredString(root, "server_id"));
    const message_id = try parseUlidRequired(try fields.requiredString(root, "message_id"));
    const sequence = try fields.requiredInt(u64, root, "sequence");
    const timestamp = try fields.requiredInteger(root, "timestamp");
    const version = try fields.requiredInt(u8, root, "version");

    var in_reply_to: ?tool_types.Ulid = null;
    if (try fields.optionalString(root, "in_reply_to")) |v| in_reply_to = try parseUlidRequired(v);

    const payload_obj = try fields.requiredObject(root, "payload");
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

fn parseUlidRequired(str: []const u8) !tool_types.Ulid {
    return tool_types.parseUlid(str) orelse error.InvalidUlid;
}

fn deserializeArtifactReference(obj: std.json.ObjectMap, allocator: std.mem.Allocator) !tool_types.ArtifactReference {
    var artifact = tool_types.ArtifactReference{
        .artifact_id = try allocator.dupe(u8, try fields.requiredString(obj, "artifact_id")),
    };
    errdefer artifact.deinit(allocator);

    if (try fields.optionalString(obj, "uri")) |v| artifact.uri = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
    if (try fields.optionalString(obj, "mime_type")) |v| artifact.mime_type = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
    if (try fields.optionalIntValue(u64, obj.get("byte_size"))) |v| artifact.byte_size = v;
    if (try fields.optionalString(obj, "sha256")) |v| artifact.sha256 = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
    if (try fields.optionalString(obj, "description")) |v| artifact.description = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));

    return artifact;
}

fn deserializeArtifactReferences(array: std.json.Array, allocator: std.mem.Allocator) ![]tool_types.ArtifactReference {
    const artifacts = try allocator.alloc(tool_types.ArtifactReference, array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (artifacts[0..initialized]) |*artifact| artifact.deinit(allocator);
        allocator.free(artifacts);
    }

    for (array.items, 0..) |item, i| {
        artifacts[i] = try deserializeArtifactReference(try fields.asObject(item), allocator);
        initialized += 1;
    }

    return artifacts;
}

fn deserializePayload(type_str: []const u8, payload: std.json.ObjectMap, allocator: std.mem.Allocator) !tool_types.Payload {
    if (std.mem.eql(u8, type_str, "tool_register")) {
        const tool = try deserializeToolMetadata(try fields.requiredObject(payload, "tool"), allocator);
        errdefer tool.deinit(allocator);
        var req = tool_types.ToolRegisterRequest{ .tool = tool };
        if (try fields.optionalString(payload, "callback_url")) |v| req.callback_url = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
        return .{ .tool_register = req };
    }
    if (std.mem.eql(u8, type_str, "tool_registered")) {
        return .{ .tool_registered = .{
            .tool_id = try allocator.dupe(u8, try fields.requiredString(payload, "tool_id")),
            .registered_at = try fields.requiredInteger(payload, "registered_at"),
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_unregister")) {
        return .{ .tool_unregister = .{
            .tool_id = try allocator.dupe(u8, try fields.requiredString(payload, "tool_id")),
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_unregistered")) {
        return .{ .tool_unregistered = .{
            .tool_id = try allocator.dupe(u8, try fields.requiredString(payload, "tool_id")),
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_list")) {
        var req = tool_types.ToolListRequest{};
        if (try fields.optionalString(payload, "prefix")) |v| req.prefix = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
        if (payload.get("supports_streaming")) |v| req.supports_streaming = try fields.asBool(v);
        return .{ .tool_list = req };
    }
    if (std.mem.eql(u8, type_str, "tool_list_response")) {
        const tools_arr = try fields.requiredArray(payload, "tools");
        const tools = try allocator.alloc(tool_types.ToolMetadata, tools_arr.items.len);
        var initialized: usize = 0;
        errdefer {
            for (tools[0..initialized]) |*tool| tool.deinit(allocator);
            allocator.free(tools);
        }
        for (tools_arr.items, 0..) |t, i| {
            tools[i] = try deserializeToolMetadata(try fields.asObject(t), allocator);
            initialized = i + 1;
        }
        return .{ .tool_list_response = .{ .tools = tools } };
    }
    if (std.mem.eql(u8, type_str, "tool_execute")) {
        const args_json = try allocator.dupe(u8, try fields.requiredString(payload, "args_json"));
        errdefer allocator.free(args_json);
        try validateJson(args_json, allocator);

        const execution_id = try parseUlidRequired(try fields.requiredString(payload, "execution_id"));
        const tool_call_id = try allocator.dupe(u8, try fields.requiredString(payload, "tool_call_id"));
        errdefer allocator.free(tool_call_id);
        const tool_name = try allocator.dupe(u8, try fields.requiredString(payload, "tool_name"));
        errdefer allocator.free(tool_name);
        var req = tool_types.ToolExecuteRequest{
            .execution_id = execution_id,
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
            .args_json = args_json,
        };
        if (try fields.optionalIntValue(u32, payload.get("timeout_ms"))) |v| req.timeout_ms = v;
        if (try fields.optionalString(payload, "stream_callback_url")) |v| req.stream_callback_url = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
        return .{ .tool_execute = req };
    }
    if (std.mem.eql(u8, type_str, "tool_stream")) {
        const stream_execution_id = try parseUlidRequired(try fields.requiredString(payload, "execution_id"));
        const stream_tool_call_id = try allocator.dupe(u8, try fields.requiredString(payload, "tool_call_id"));
        errdefer allocator.free(stream_tool_call_id);
        const partial_result_json = try allocator.dupe(u8, try fields.requiredString(payload, "partial_result_json"));
        errdefer allocator.free(partial_result_json);
        var update = tool_types.ToolStreamUpdate{
            .execution_id = stream_execution_id,
            .tool_call_id = stream_tool_call_id,
            .partial_result_json = partial_result_json,
        };
        if (try fields.optionalIntValue(u8, payload.get("progress"))) |v| update.progress = v;
        if (try fields.optionalString(payload, "status")) |v| update.status = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
        return .{ .tool_stream = update };
    }
    if (std.mem.eql(u8, type_str, "tool_result")) {
        const result_execution_id = try parseUlidRequired(try fields.requiredString(payload, "execution_id"));
        const is_error = try fields.optionalBool(payload, "is_error", false);
        const duration_ms = try fields.requiredInt(u32, payload, "duration_ms");
        const result_tool_call_id = try allocator.dupe(u8, try fields.requiredString(payload, "tool_call_id"));
        errdefer allocator.free(result_tool_call_id);
        const result_json = try allocator.dupe(u8, try fields.requiredString(payload, "result_json"));
        errdefer allocator.free(result_json);
        var result = tool_types.ToolExecuteResult{
            .execution_id = result_execution_id,
            .tool_call_id = result_tool_call_id,
            .result_json = result_json,
            .is_error = is_error,
            .duration_ms = duration_ms,
        };
        errdefer {
            result.error_message.deinit(allocator);
            result.details_json.deinit(allocator);
            result.artifacts.deinit(allocator);
        }
        if (try fields.optionalString(payload, "error_message")) |v| result.error_message = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
        if (try fields.optionalString(payload, "details_json")) |v| result.details_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
        if (payload.get("artifacts")) |v| result.artifacts = OwnedSlice(tool_types.ArtifactReference).initOwned(try deserializeArtifactReferences(try fields.asArray(v), allocator));
        return .{ .tool_result = result };
    }
    if (std.mem.eql(u8, type_str, "tool_cancel")) {
        var req = tool_types.ToolCancelRequest{
            .execution_id = try parseUlidRequired(try fields.requiredString(payload, "execution_id")),
        };
        if (try fields.optionalString(payload, "reason")) |v| req.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
        return .{ .tool_cancel = req };
    }
    if (std.mem.eql(u8, type_str, "tool_cancelled")) {
        return .{ .tool_cancelled = .{
            .execution_id = try parseUlidRequired(try fields.requiredString(payload, "execution_id")),
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_error")) {
        const error_execution_id = try parseUlidRequired(try fields.requiredString(payload, "execution_id"));
        const error_code = std.meta.stringToEnum(tool_types.ToolErrorCode, try fields.requiredString(payload, "code")) orelse return error.InvalidPayloadType;
        const error_message = try allocator.dupe(u8, try fields.requiredString(payload, "message"));
        return .{ .tool_error = .{
            .execution_id = error_execution_id,
            .code = error_code,
            .message = error_message,
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_status")) {
        return .{ .tool_status = .{
            .execution_id = try parseUlidRequired(try fields.requiredString(payload, "execution_id")),
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_status_response")) {
        const status_execution_id = try parseUlidRequired(try fields.requiredString(payload, "execution_id"));
        const status_name = try fields.requiredString(payload, "tool_name");
        const status = std.meta.stringToEnum(tool_types.ToolExecutionStatus, try fields.requiredString(payload, "status")) orelse return error.InvalidPayloadType;
        const started_at = try fields.requiredInteger(payload, "started_at");
        const completed_at = try fields.optionalInteger(payload, "completed_at");
        return .{ .tool_status_response = .{
            .execution_id = status_execution_id,
            .tool_name = try allocator.dupe(u8, status_name),
            .status = status,
            .started_at = started_at,
            .completed_at = completed_at,
        } };
    }
    if (std.mem.eql(u8, type_str, "artifact_retrieve")) {
        var req = tool_types.ArtifactRetrieveRequest{
            .artifact_id = try allocator.dupe(u8, try fields.requiredString(payload, "artifact_id")),
        };
        errdefer allocator.free(req.artifact_id);

        req.byte_offset = try fields.optionalIntValue(u64, payload.get("byte_offset"));
        req.byte_limit = try fields.optionalIntValue(u64, payload.get("byte_limit"));
        return .{ .artifact_retrieve = req };
    }
    if (std.mem.eql(u8, type_str, "artifact_retrieved")) {
        var res = tool_types.ArtifactRetrieveResponse{
            .artifact = try deserializeArtifactReference(try fields.requiredObject(payload, "artifact"), allocator),
        };
        errdefer res.deinit(allocator);
        if (payload.get("content_json")) |v| res.content_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(v)));
        return .{ .artifact_retrieved = res };
    }
    if (std.mem.eql(u8, type_str, "artifact_search")) {
        var req = tool_types.ArtifactSearchRequest{
            .query = try allocator.dupe(u8, try fields.requiredString(payload, "query")),
        };
        errdefer allocator.free(req.query);

        req.limit = try fields.optionalIntValue(u32, payload.get("limit"));
        return .{ .artifact_search = req };
    }
    if (std.mem.eql(u8, type_str, "artifact_search_result")) {
        const values = try fields.requiredArray(payload, "results");
        const results = try allocator.alloc(tool_types.ArtifactSearchResult, values.items.len);
        var initialized: usize = 0;
        errdefer {
            for (results[0..initialized]) |*result| result.deinit(allocator);
            allocator.free(results);
        }
        for (values.items, 0..) |item, i| {
            const obj = try fields.asObject(item);
            results[i] = blk: {
                var result = tool_types.ArtifactSearchResult{
                    .artifact = try deserializeArtifactReference(try fields.requiredObject(obj, "artifact"), allocator),
                };
                errdefer result.deinit(allocator);
                if (try fields.optionalString(obj, "snippet")) |v| result.snippet = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
                if (obj.get("score")) |v| result.score = switch (v) {
                    .float => |f| @floatCast(f),
                    .integer => |n| @floatFromInt(n),
                    else => null,
                };
                break :blk result;
            };
            initialized += 1;
        }
        return .{ .artifact_search_result = .{ .results = results } };
    }
    if (std.mem.eql(u8, type_str, "hashline_read")) {
        const feature_enabled = if (payload.get("feature_enabled")) |v| try fields.asBool(v) else false;
        var req = tool_types.HashlineReadRequest{
            .path = try allocator.dupe(u8, try fields.requiredString(payload, "path")),
            .feature_enabled = feature_enabled,
        };
        errdefer allocator.free(req.path);

        req.byte_limit = try fields.optionalIntValue(u64, payload.get("byte_limit"));
        return .{ .hashline_read = req };
    }
    if (std.mem.eql(u8, type_str, "hashline_read_result")) {
        const values = try fields.requiredArray(payload, "lines");
        const lines = try allocator.alloc(tool_types.HashlineLine, values.items.len);
        var initialized: usize = 0;
        errdefer {
            for (lines[0..initialized]) |*line| line.deinit(allocator);
            allocator.free(lines);
        }
        for (values.items, 0..) |item, i| {
            const obj = try fields.asObject(item);
            lines[i] = blk: {
                const line = try fields.asInt(u32, obj.get("line") orelse return error.InvalidPayloadType);
                const hash = try allocator.dupe(u8, try fields.requiredString(obj, "hash"));
                errdefer allocator.free(hash);
                const text = try allocator.dupe(u8, try fields.requiredString(obj, "text"));
                errdefer allocator.free(text);
                break :blk .{
                    .line = line,
                    .hash = hash,
                    .text = text,
                };
            };
            initialized += 1;
        }
        return .{ .hashline_read_result = .{
            .path = try allocator.dupe(u8, try fields.requiredString(payload, "path")),
            .lines = lines,
        } };
    }
    if (std.mem.eql(u8, type_str, "hashline_edit")) {
        const feature_enabled = if (payload.get("feature_enabled")) |v| try fields.asBool(v) else false;
        var req = tool_types.HashlineEditRequest{
            .path = try allocator.dupe(u8, try fields.requiredString(payload, "path")),
            .operation = undefined,
            .start_line = undefined,
            .start_hash = "",
            .feature_enabled = feature_enabled,
        };
        var owns_start_hash = false;
        errdefer {
            allocator.free(req.path);
            if (owns_start_hash) allocator.free(req.start_hash);
            req.end_hash.deinit(allocator);
            req.replacement.deinit(allocator);
        }
        req.operation = std.meta.stringToEnum(tool_types.HashlineEditOperation, try fields.requiredString(payload, "operation")) orelse return error.InvalidPayloadType;
        req.start_line = try fields.asInt(u32, payload.get("start_line") orelse return error.InvalidPayloadType);
        req.start_hash = try allocator.dupe(u8, try fields.requiredString(payload, "start_hash"));
        owns_start_hash = true;
        if (payload.get("end_line")) |v| req.end_line = try fields.asInt(u32, v);
        if (payload.get("end_hash")) |v| req.end_hash = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(v)));
        if (payload.get("replacement")) |v| req.replacement = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.asString(v)));
        return .{ .hashline_edit = req };
    }
    if (std.mem.eql(u8, type_str, "hashline_edit_result")) {
        const applied = try fields.requiredBool(payload, "applied");
        var res = tool_types.HashlineEditResponse{
            .path = try allocator.dupe(u8, try fields.requiredString(payload, "path")),
            .applied = applied,
        };
        errdefer res.deinit(allocator);
        if (payload.get("new_artifact")) |v| res.new_artifact = try deserializeArtifactReference(try fields.asObject(v), allocator);
        return .{ .hashline_edit_result = res };
    }
    if (std.mem.eql(u8, type_str, "ping")) return .ping;
    if (std.mem.eql(u8, type_str, "pong")) {
        return .{ .pong = .{
            .ping_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(payload, "ping_id"))),
        } };
    }
    if (std.mem.eql(u8, type_str, "goodbye")) {
        var goodbye = tool_types.Goodbye{};
        if (try fields.optionalString(payload, "reason")) |v| goodbye.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v));
        return .{ .goodbye = goodbye };
    }

    return error.InvalidPayloadType;
}

fn deserializeToolMetadata(obj: std.json.ObjectMap, allocator: std.mem.Allocator) !tool_types.ToolMetadata {
    var required_permissions: ?[]const []const u8 = null;
    var permissions_filled: usize = 0;
    errdefer if (required_permissions) |perms| {
        for (perms[0..permissions_filled]) |p| allocator.free(p);
        allocator.free(perms);
    };
    if (try fields.optionalArray(obj, "required_permissions")) |permissions_arr| {
        const permissions = try allocator.alloc([]const u8, permissions_arr.items.len);
        required_permissions = permissions;
        for (permissions_arr.items, 0..) |permission, i| {
            permissions[i] = try allocator.dupe(u8, try fields.asString(permission));
            permissions_filled = i + 1;
        }
    }

    const meta_name = try allocator.dupe(u8, try fields.requiredString(obj, "name"));
    errdefer allocator.free(meta_name);
    const meta_description = try allocator.dupe(u8, try fields.requiredString(obj, "description"));
    errdefer allocator.free(meta_description);
    const meta_schema = try allocator.dupe(u8, try fields.requiredString(obj, "parameters_schema_json"));
    errdefer allocator.free(meta_schema);
    const meta_version = try allocator.dupe(u8, try fields.optionalString(obj, "version") orelse "1.0.0");
    errdefer allocator.free(meta_version);
    return .{
        .name = meta_name,
        .description = meta_description,
        .parameters_schema_json = meta_schema,
        .version = meta_version,
        .supports_streaming = try fields.optionalBool(obj, "supports_streaming", false),
        .estimated_duration_ms = try fields.optionalIntValue(u32, obj.get("estimated_duration_ms")),
        .is_destructive = try fields.optionalBool(obj, "is_destructive", false),
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
        .server_id = tool_types.generateUlid(),
        .message_id = tool_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .tool_execute = .{
            .execution_id = tool_types.generateUlid(),
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
        .server_id = tool_types.generateUlid(),
        .message_id = tool_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
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
        "{\"type\":\"tool_error\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"execution_id\":\"00000000000000000000000003\",\"code\":\"tool_not_found\",\"message\":\"unknown tool\"}}";

    var env = try deserializeEnvelope(json, allocator);
    defer env.deinit(allocator);

    try std.testing.expect(env.payload == .tool_error);
    try std.testing.expectEqual(tool_types.ToolErrorCode.tool_not_found, env.payload.tool_error.code);
}

test "tool envelope negative malformed args" {
    const allocator = std.testing.allocator;
    const json =
        "{\"type\":\"tool_execute\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"execution_id\":\"00000000000000000000000003\",\"tool_call_id\":\"call_1\",\"tool_name\":\"grep\",\"args_json\":\"{bad json\"}}";

    try std.testing.expectError(error.InvalidArgumentsJson, deserializeEnvelope(json, allocator));
}

test "tool envelope negative timeout error" {
    const allocator = std.testing.allocator;
    const json =
        "{\"type\":\"tool_error\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"execution_id\":\"00000000000000000000000003\",\"code\":\"tool_timeout\",\"message\":\"timed out\"}}";

    var env = try deserializeEnvelope(json, allocator);
    defer env.deinit(allocator);

    try std.testing.expect(env.payload == .tool_error);
    try std.testing.expectEqual(tool_types.ToolErrorCode.tool_timeout, env.payload.tool_error.code);
}

test "tool envelope roundtrip artifact search response" {
    const allocator = std.testing.allocator;

    const results = try allocator.alloc(tool_types.ArtifactSearchResult, 1);
    results[0] = .{
        .artifact = .{
            .artifact_id = try allocator.dupe(u8, "artifact-1"),
            .uri = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "makai-artifact://artifact-1")),
            .mime_type = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "text/plain")),
            .byte_size = 128,
            .description = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "raw logs")),
        },
        .snippet = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "error line")),
        .score = 0.75,
    };

    var env = tool_types.Envelope{
        .server_id = tool_types.generateUlid(),
        .message_id = tool_types.generateUlid(),
        .sequence = 3,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .artifact_search_result = .{ .results = results } },
    };
    defer env.deinit(allocator);

    const json = try serializeEnvelope(env, allocator);
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.payload == .artifact_search_result);
    try std.testing.expectEqual(@as(usize, 1), parsed.payload.artifact_search_result.results.len);
    try std.testing.expectEqualStrings("artifact-1", parsed.payload.artifact_search_result.results[0].artifact.artifact_id);
    try std.testing.expectEqualStrings("error line", parsed.payload.artifact_search_result.results[0].snippet.slice());
}

test "tool envelope roundtrip tool result artifacts" {
    const allocator = std.testing.allocator;

    const artifacts = try allocator.alloc(tool_types.ArtifactReference, 1);
    artifacts[0] = .{
        .artifact_id = try allocator.dupe(u8, "artifact-tool-output"),
        .uri = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "makai-artifact://artifact-tool-output")),
        .mime_type = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "application/json")),
        .byte_size = 4096,
    };

    var env = tool_types.Envelope{
        .server_id = tool_types.generateUlid(),
        .message_id = tool_types.generateUlid(),
        .sequence = 4,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .tool_result = .{
            .execution_id = tool_types.generateUlid(),
            .tool_call_id = try allocator.dupe(u8, "call_1"),
            .result_json = try allocator.dupe(u8, "[{\"type\":\"text\",\"text\":\"summary\"}]"),
            .details_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "{\"summary\":true}")),
            .artifacts = OwnedSlice(tool_types.ArtifactReference).initOwned(artifacts),
            .duration_ms = 25,
        } },
    };
    defer env.deinit(allocator);

    const json = try serializeEnvelope(env, allocator);
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.payload == .tool_result);
    try std.testing.expectEqual(@as(usize, 1), parsed.payload.tool_result.artifacts.slice().len);
    try std.testing.expectEqualStrings("artifact-tool-output", parsed.payload.tool_result.artifacts.slice()[0].artifact_id);
}

test "tool envelope roundtrip hashline edit" {
    const allocator = std.testing.allocator;

    var env = tool_types.Envelope{
        .server_id = tool_types.generateUlid(),
        .message_id = tool_types.generateUlid(),
        .sequence = 5,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .hashline_edit = .{
            .path = try allocator.dupe(u8, "src/main.zig"),
            .operation = .replace_range,
            .start_line = 10,
            .start_hash = try allocator.dupe(u8, "a1b2"),
            .end_line = 12,
            .end_hash = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "c3d4")),
            .replacement = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "const x = 1;")),
            .feature_enabled = true,
        } },
    };
    defer env.deinit(allocator);

    const json = try serializeEnvelope(env, allocator);
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.payload == .hashline_edit);
    try std.testing.expect(parsed.payload.hashline_edit.feature_enabled);
    try std.testing.expectEqual(tool_types.HashlineEditOperation.replace_range, parsed.payload.hashline_edit.operation);
    try std.testing.expectEqualStrings("a1b2", parsed.payload.hashline_edit.start_hash);
    try std.testing.expectEqualStrings("const x = 1;", parsed.payload.hashline_edit.replacement.slice());
}

test "tool envelope rejects negative artifact retrieve byte ranges" {
    const allocator = std.testing.allocator;
    const negative_offset =
        "{\"type\":\"artifact_retrieve\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"artifact_id\":\"artifact-1\",\"byte_offset\":-1}}";
    const negative_limit =
        "{\"type\":\"artifact_retrieve\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"artifact_id\":\"artifact-1\",\"byte_limit\":-1}}";

    try std.testing.expectError(error.FieldOutOfRange, deserializeEnvelope(negative_offset, allocator));
    try std.testing.expectError(error.FieldOutOfRange, deserializeEnvelope(negative_limit, allocator));
}

test "tool envelope rejects malformed hashline edit without leaks" {
    const allocator = std.testing.allocator;
    const invalid_operation =
        "{\"type\":\"hashline_edit\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"operation\":\"invalid\",\"start_line\":1,\"start_hash\":\"a1b2\"}}";
    const negative_start_line =
        "{\"type\":\"hashline_edit\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"operation\":\"replace_range\",\"start_line\":-1,\"start_hash\":\"a1b2\"}}";
    const non_string_end_hash =
        "{\"type\":\"hashline_edit\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"operation\":\"replace_range\",\"start_line\":1,\"start_hash\":\"a1b2\",\"end_hash\":42}}";
    const non_string_replacement =
        "{\"type\":\"hashline_edit\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"operation\":\"replace_range\",\"start_line\":1,\"start_hash\":\"a1b2\",\"replacement\":42}}";
    const non_bool_feature_enabled =
        "{\"type\":\"hashline_edit\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"operation\":\"replace_range\",\"start_line\":1,\"start_hash\":\"a1b2\",\"feature_enabled\":\"yes\"}}";

    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(invalid_operation, allocator));
    try std.testing.expectError(error.FieldOutOfRange, deserializeEnvelope(negative_start_line, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(non_string_end_hash, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(non_string_replacement, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(non_bool_feature_enabled, allocator));
}

test "tool envelope rejects malformed artifact references without leaks" {
    const allocator = std.testing.allocator;
    const missing_artifact_id =
        "{\"type\":\"artifact_retrieved\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"artifact\":{\"uri\":\"makai-artifact://artifact-1\"}}}";
    const negative_byte_size =
        "{\"type\":\"artifact_retrieved\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"artifact\":{\"artifact_id\":\"artifact-1\",\"byte_size\":-1}}}";
    const non_string_uri =
        "{\"type\":\"artifact_retrieved\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"artifact\":{\"artifact_id\":\"artifact-1\",\"uri\":42}}}";
    const non_string_content_json =
        "{\"type\":\"artifact_retrieved\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"artifact\":{\"artifact_id\":\"artifact-1\"},\"content_json\":42}}";

    try std.testing.expectError(error.MissingField, deserializeEnvelope(missing_artifact_id, allocator));
    try std.testing.expectError(error.FieldOutOfRange, deserializeEnvelope(negative_byte_size, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(non_string_uri, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(non_string_content_json, allocator));
}

test "tool envelope rejects non-array tool result artifacts without leaks" {
    const allocator = std.testing.allocator;
    const json =
        "{\"type\":\"tool_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"execution_id\":\"00000000000000000000000003\",\"tool_call_id\":\"call_1\",\"result_json\":\"{}\",\"duration_ms\":1,\"artifacts\":\"not-array\"}}";

    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(json, allocator));
}

test "tool envelope rejects remaining negative unsigned fields without leaks" {
    const allocator = std.testing.allocator;
    const negative_search_limit =
        "{\"type\":\"artifact_search\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"query\":\"needle\",\"limit\":-1}}";
    const negative_read_limit =
        "{\"type\":\"hashline_read\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"byte_limit\":-1}}";
    const negative_result_line =
        "{\"type\":\"hashline_read_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"lines\":[{\"line\":-1,\"hash\":\"abc\",\"text\":\"bad\"}]}}";

    try std.testing.expectError(error.FieldOutOfRange, deserializeEnvelope(negative_search_limit, allocator));
    try std.testing.expectError(error.FieldOutOfRange, deserializeEnvelope(negative_read_limit, allocator));
    try std.testing.expectError(error.FieldOutOfRange, deserializeEnvelope(negative_result_line, allocator));
}

test "tool envelope rejects malformed artifact search results without leaks" {
    const allocator = std.testing.allocator;
    const missing_artifact =
        "{\"type\":\"artifact_search_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"results\":[{\"snippet\":\"hit\"}]}}";
    const non_object_artifact =
        "{\"type\":\"artifact_search_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"results\":[{\"artifact\":\"artifact-1\"}]}}";
    const non_object_result =
        "{\"type\":\"artifact_search_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"results\":[42]}}";

    try std.testing.expectError(error.MissingField, deserializeEnvelope(missing_artifact, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(non_object_artifact, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(non_object_result, allocator));
}

test "tool envelope rejects malformed hashline read results without leaks" {
    const allocator = std.testing.allocator;
    const non_object_line =
        "{\"type\":\"hashline_read_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"lines\":[42]}}";
    const non_string_hash =
        "{\"type\":\"hashline_read_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"lines\":[{\"line\":1,\"hash\":42,\"text\":\"bad\"}]}}";
    const non_string_text =
        "{\"type\":\"hashline_read_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"lines\":[{\"line\":1,\"hash\":\"abc\",\"text\":42}]}}";

    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(non_object_line, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(non_string_hash, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(non_string_text, allocator));
}

test "tool envelope rejects malformed hashline read request feature flag without leaks" {
    const allocator = std.testing.allocator;
    const non_bool_feature_enabled =
        "{\"type\":\"hashline_read\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"feature_enabled\":\"yes\"}}";

    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(non_bool_feature_enabled, allocator));
}

test "tool envelope rejects malformed hashline edit results without leaks" {
    const allocator = std.testing.allocator;
    const missing_applied =
        "{\"type\":\"hashline_edit_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\"}}";
    const non_bool_applied =
        "{\"type\":\"hashline_edit_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"applied\":\"yes\"}}";

    try std.testing.expectError(error.MissingField, deserializeEnvelope(missing_applied, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(non_bool_applied, allocator));
}

test "tool envelope rejects missing required root fields" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        \\{"server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","server_id":"01M2MYK69FX2M3DY769FEHK3M0","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"payload":{}}
        ,
        \\{"type":"ping","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1}
        ,
    };

    for (cases) |json| {
        try std.testing.expectError(error.MissingField, deserializeEnvelope(json, allocator));
    }
}

test "tool envelope rejects wrong-typed and out-of-range root fields" {
    const allocator = std.testing.allocator;
    const wrong_typed = [_][]const u8{
        \\{"type":7,"server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","server_id":7,"message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":7,"sequence":1,"timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":"1","timestamp":1,"version":1,"payload":{}}
        ,
        \\{"type":"ping","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":"1","version":1,"payload":{}}
        ,
        \\{"type":"ping","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":[]}
        ,
    };
    for (wrong_typed) |json| {
        try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(json, allocator));
    }

    const negative_sequence =
        \\{"type":"ping","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":-1,"timestamp":1,"version":1,"payload":{}}
    ;
    const oversized_version =
        \\{"type":"ping","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":99999,"payload":{}}
    ;
    try std.testing.expectError(error.FieldOutOfRange, deserializeEnvelope(negative_sequence, allocator));
    try std.testing.expectError(error.FieldOutOfRange, deserializeEnvelope(oversized_version, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope("[1,2,3]", allocator));
}

test "tool envelope rejects malformed execute payloads without leaking" {
    const allocator = std.testing.allocator;
    const execute_missing_tool_name =
        \\{"type":"tool_execute","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"args_json":"{}","execution_id":"01M2MYK69FX2M3DY769FEHK3M2","tool_call_id":"c"}}
    ;
    const register_missing_tool =
        \\{"type":"tool_register","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
    ;
    const register_tool_not_object =
        \\{"type":"tool_register","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"tool":"t"}}
    ;
    const result_missing_duration =
        \\{"type":"tool_result","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"execution_id":"01M2MYK69FX2M3DY769FEHK3M2","tool_call_id":"c","result_json":"{}"}}
    ;

    try std.testing.expectError(error.MissingField, deserializeEnvelope(execute_missing_tool_name, allocator));
    try std.testing.expectError(error.MissingField, deserializeEnvelope(register_missing_tool, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(register_tool_not_object, allocator));
    try std.testing.expectError(error.MissingField, deserializeEnvelope(result_missing_duration, allocator));
}

fn toolRegisterProbe(allocator: std.mem.Allocator) !void {
    const json =
        \\{"type":"tool_register","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"tool":{"name":"grep","description":"search","parameters_schema_json":"{}","version":"2.0.0","required_permissions":["read","shell"]},"callback_url":"https://example.test/cb"}}
    ;
    var parsed = try deserializeEnvelope(json, allocator);
    parsed.deinit(allocator);
}

test "tool_register survives an allocation failure at every step" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, toolRegisterProbe, .{});
}

fn toolListResponseProbe(allocator: std.mem.Allocator) !void {
    const json =
        \\{"type":"tool_list_response","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"tools":[{"name":"grep","description":"search","parameters_schema_json":"{}"},{"name":"edit","description":"write","parameters_schema_json":"{}","required_permissions":["write"]}]}}
    ;
    var parsed = try deserializeEnvelope(json, allocator);
    parsed.deinit(allocator);
}

test "tool_list_response survives an allocation failure at every step" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, toolListResponseProbe, .{});
}

test "a malformed tool entry after a good one is rejected without leaking" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        \\{"type":"tool_list_response","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"tools":[{"name":"grep","description":"search","parameters_schema_json":"{}"},{"name":"edit"}]}}
        ,
        \\{"type":"tool_list_response","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"tools":[{"name":"grep","description":"search","parameters_schema_json":"{}"},7]}}
        ,
        \\{"type":"tool_list_response","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"tools":[{"name":"grep","description":"search","parameters_schema_json":"{}","required_permissions":7}]}}
        ,
        \\{"type":"tool_list_response","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"tools":[{"name":"grep","description":"search","parameters_schema_json":"{}","required_permissions":[7]}]}}
        ,
        \\{"type":"tool_register","server_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"tool":{"name":"grep","description":"search","parameters_schema_json":"{}"},"callback_url":7}}
        ,
    };

    for (cases) |json| {
        try std.testing.expect(std.meta.isError(deserializeEnvelope(json, allocator)));
    }
}
