const std = @import("std");
const compat = @import("compat");
const tool_types = @import("tool_types");
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

    const root = parsed.value.object;
    const type_str = root.get("type").?.string;
    const server_id = try parseUlidRequired(root.get("server_id").?.string);
    const message_id = try parseUlidRequired(root.get("message_id").?.string);
    const sequence = @as(u64, @intCast(root.get("sequence").?.integer));
    const timestamp = root.get("timestamp").?.integer;
    const version = @as(u8, @intCast(root.get("version").?.integer));

    var in_reply_to: ?tool_types.Ulid = null;
    if (root.get("in_reply_to")) |v| in_reply_to = try parseUlidRequired(v.string);

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

fn parseUlidRequired(str: []const u8) !tool_types.Ulid {
    return tool_types.parseUlid(str) orelse error.InvalidUlid;
}

fn parseJsonString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.InvalidPayloadType,
    };
}

fn parseJsonArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |a| a,
        else => error.InvalidPayloadType,
    };
}

fn parseJsonObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |o| o,
        else => error.InvalidPayloadType,
    };
}

fn parseRequiredJsonString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return parseJsonString(obj.get(key) orelse return error.InvalidPayloadType);
}

fn parseRequiredJsonArray(obj: std.json.ObjectMap, key: []const u8) !std.json.Array {
    return parseJsonArray(obj.get(key) orelse return error.InvalidPayloadType);
}

fn parseRequiredJsonObject(obj: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    return parseJsonObject(obj.get(key) orelse return error.InvalidPayloadType);
}

fn parseUnsignedJsonInteger(comptime T: type, value: std.json.Value) !T {
    return switch (value) {
        .integer => |n| std.math.cast(T, n) orelse error.InvalidPayloadType,
        else => error.InvalidPayloadType,
    };
}

fn parseOptionalUnsignedJsonInteger(comptime T: type, value: ?std.json.Value) !?T {
    return if (value) |v| try parseUnsignedJsonInteger(T, v) else null;
}

fn deserializeArtifactReference(obj: std.json.ObjectMap, allocator: std.mem.Allocator) !tool_types.ArtifactReference {
    var artifact = tool_types.ArtifactReference{
        .artifact_id = try allocator.dupe(u8, try parseRequiredJsonString(obj, "artifact_id")),
    };
    errdefer artifact.deinit(allocator);

    if (obj.get("uri")) |v| artifact.uri = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try parseJsonString(v)));
    if (obj.get("mime_type")) |v| artifact.mime_type = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try parseJsonString(v)));
    if (obj.get("byte_size")) |v| artifact.byte_size = try parseUnsignedJsonInteger(u64, v);
    if (obj.get("sha256")) |v| artifact.sha256 = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try parseJsonString(v)));
    if (obj.get("description")) |v| artifact.description = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try parseJsonString(v)));

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
        artifacts[i] = try deserializeArtifactReference(try parseJsonObject(item), allocator);
        initialized += 1;
    }

    return artifacts;
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
            .execution_id = try parseUlidRequired(payload.get("execution_id").?.string),
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
            .execution_id = try parseUlidRequired(payload.get("execution_id").?.string),
            .tool_call_id = try allocator.dupe(u8, payload.get("tool_call_id").?.string),
            .partial_result_json = try allocator.dupe(u8, payload.get("partial_result_json").?.string),
        };
        if (payload.get("progress")) |v| update.progress = @as(u8, @intCast(v.integer));
        if (payload.get("status")) |v| update.status = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .tool_stream = update };
    }
    if (std.mem.eql(u8, type_str, "tool_result")) {
        var result = tool_types.ToolExecuteResult{
            .execution_id = try parseUlidRequired(payload.get("execution_id").?.string),
            .tool_call_id = try allocator.dupe(u8, payload.get("tool_call_id").?.string),
            .result_json = try allocator.dupe(u8, payload.get("result_json").?.string),
            .is_error = if (payload.get("is_error")) |v| v.bool else false,
            .duration_ms = @as(u32, @intCast(payload.get("duration_ms").?.integer)),
        };
        errdefer {
            allocator.free(result.tool_call_id);
            allocator.free(result.result_json);
            result.error_message.deinit(allocator);
            result.details_json.deinit(allocator);
            result.artifacts.deinit(allocator);
        }
        if (payload.get("error_message")) |v| result.error_message = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        if (payload.get("details_json")) |v| result.details_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        if (payload.get("artifacts")) |v| result.artifacts = OwnedSlice(tool_types.ArtifactReference).initOwned(try deserializeArtifactReferences(try parseJsonArray(v), allocator));
        return .{ .tool_result = result };
    }
    if (std.mem.eql(u8, type_str, "tool_cancel")) {
        var req = tool_types.ToolCancelRequest{
            .execution_id = try parseUlidRequired(payload.get("execution_id").?.string),
        };
        if (payload.get("reason")) |v| req.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, v.string));
        return .{ .tool_cancel = req };
    }
    if (std.mem.eql(u8, type_str, "tool_cancelled")) {
        return .{ .tool_cancelled = .{
            .execution_id = try parseUlidRequired(payload.get("execution_id").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_error")) {
        return .{ .tool_error = .{
            .execution_id = try parseUlidRequired(payload.get("execution_id").?.string),
            .code = std.meta.stringToEnum(tool_types.ToolErrorCode, payload.get("code").?.string) orelse return error.InvalidPayloadType,
            .message = try allocator.dupe(u8, payload.get("message").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_status")) {
        return .{ .tool_status = .{
            .execution_id = try parseUlidRequired(payload.get("execution_id").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_status_response")) {
        return .{ .tool_status_response = .{
            .execution_id = try parseUlidRequired(payload.get("execution_id").?.string),
            .tool_name = try allocator.dupe(u8, payload.get("tool_name").?.string),
            .status = std.meta.stringToEnum(tool_types.ToolExecutionStatus, payload.get("status").?.string) orelse return error.InvalidPayloadType,
            .started_at = payload.get("started_at").?.integer,
            .completed_at = if (payload.get("completed_at")) |v| v.integer else null,
        } };
    }
    if (std.mem.eql(u8, type_str, "artifact_retrieve")) {
        var req = tool_types.ArtifactRetrieveRequest{
            .artifact_id = try allocator.dupe(u8, try parseRequiredJsonString(payload, "artifact_id")),
        };
        errdefer allocator.free(req.artifact_id);

        req.byte_offset = try parseOptionalUnsignedJsonInteger(u64, payload.get("byte_offset"));
        req.byte_limit = try parseOptionalUnsignedJsonInteger(u64, payload.get("byte_limit"));
        return .{ .artifact_retrieve = req };
    }
    if (std.mem.eql(u8, type_str, "artifact_retrieved")) {
        var res = tool_types.ArtifactRetrieveResponse{
            .artifact = try deserializeArtifactReference(try parseRequiredJsonObject(payload, "artifact"), allocator),
        };
        errdefer res.deinit(allocator);
        if (payload.get("content_json")) |v| res.content_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try parseJsonString(v)));
        return .{ .artifact_retrieved = res };
    }
    if (std.mem.eql(u8, type_str, "artifact_search")) {
        var req = tool_types.ArtifactSearchRequest{
            .query = try allocator.dupe(u8, try parseRequiredJsonString(payload, "query")),
        };
        errdefer allocator.free(req.query);

        req.limit = try parseOptionalUnsignedJsonInteger(u32, payload.get("limit"));
        return .{ .artifact_search = req };
    }
    if (std.mem.eql(u8, type_str, "artifact_search_result")) {
        const values = try parseRequiredJsonArray(payload, "results");
        const results = try allocator.alloc(tool_types.ArtifactSearchResult, values.items.len);
        var initialized: usize = 0;
        errdefer {
            for (results[0..initialized]) |*result| result.deinit(allocator);
            allocator.free(results);
        }
        for (values.items, 0..) |item, i| {
            const obj = try parseJsonObject(item);
            results[i] = blk: {
                var result = tool_types.ArtifactSearchResult{
                    .artifact = try deserializeArtifactReference(try parseRequiredJsonObject(obj, "artifact"), allocator),
                };
                errdefer result.deinit(allocator);
                if (obj.get("snippet")) |v| result.snippet = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try parseJsonString(v)));
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
        var req = tool_types.HashlineReadRequest{
            .path = try allocator.dupe(u8, try parseRequiredJsonString(payload, "path")),
            .feature_enabled = if (payload.get("feature_enabled")) |v| v.bool else false,
        };
        errdefer allocator.free(req.path);

        req.byte_limit = try parseOptionalUnsignedJsonInteger(u64, payload.get("byte_limit"));
        return .{ .hashline_read = req };
    }
    if (std.mem.eql(u8, type_str, "hashline_read_result")) {
        const values = try parseRequiredJsonArray(payload, "lines");
        const lines = try allocator.alloc(tool_types.HashlineLine, values.items.len);
        var initialized: usize = 0;
        errdefer {
            for (lines[0..initialized]) |*line| line.deinit(allocator);
            allocator.free(lines);
        }
        for (values.items, 0..) |item, i| {
            const obj = try parseJsonObject(item);
            lines[i] = blk: {
                const line = try parseUnsignedJsonInteger(u32, obj.get("line") orelse return error.InvalidPayloadType);
                const hash = try allocator.dupe(u8, try parseRequiredJsonString(obj, "hash"));
                errdefer allocator.free(hash);
                const text = try allocator.dupe(u8, try parseRequiredJsonString(obj, "text"));
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
            .path = try allocator.dupe(u8, try parseRequiredJsonString(payload, "path")),
            .lines = lines,
        } };
    }
    if (std.mem.eql(u8, type_str, "hashline_edit")) {
        var req = tool_types.HashlineEditRequest{
            .path = try allocator.dupe(u8, try parseRequiredJsonString(payload, "path")),
            .operation = undefined,
            .start_line = undefined,
            .start_hash = "",
            .feature_enabled = if (payload.get("feature_enabled")) |v| v.bool else false,
        };
        var owns_start_hash = false;
        errdefer {
            allocator.free(req.path);
            if (owns_start_hash) allocator.free(req.start_hash);
            req.end_hash.deinit(allocator);
            req.replacement.deinit(allocator);
        }
        req.operation = std.meta.stringToEnum(tool_types.HashlineEditOperation, try parseRequiredJsonString(payload, "operation")) orelse return error.InvalidPayloadType;
        req.start_line = try parseUnsignedJsonInteger(u32, payload.get("start_line") orelse return error.InvalidPayloadType);
        req.start_hash = try allocator.dupe(u8, try parseRequiredJsonString(payload, "start_hash"));
        owns_start_hash = true;
        if (payload.get("end_line")) |v| req.end_line = try parseUnsignedJsonInteger(u32, v);
        if (payload.get("end_hash")) |v| req.end_hash = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try parseJsonString(v)));
        if (payload.get("replacement")) |v| req.replacement = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try parseJsonString(v)));
        return .{ .hashline_edit = req };
    }
    if (std.mem.eql(u8, type_str, "hashline_edit_result")) {
        var res = tool_types.HashlineEditResponse{
            .path = try allocator.dupe(u8, try parseRequiredJsonString(payload, "path")),
            .applied = payload.get("applied").?.bool,
        };
        errdefer res.deinit(allocator);
        if (payload.get("new_artifact")) |v| res.new_artifact = try deserializeArtifactReference(try parseJsonObject(v), allocator);
        return .{ .hashline_edit_result = res };
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

    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(negative_offset, allocator));
    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(negative_limit, allocator));
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

    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(invalid_operation, allocator));
    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(negative_start_line, allocator));
    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(non_string_end_hash, allocator));
    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(non_string_replacement, allocator));
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

    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(missing_artifact_id, allocator));
    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(negative_byte_size, allocator));
    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(non_string_uri, allocator));
    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(non_string_content_json, allocator));
}

test "tool envelope rejects non-array tool result artifacts without leaks" {
    const allocator = std.testing.allocator;
    const json =
        "{\"type\":\"tool_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"execution_id\":\"00000000000000000000000003\",\"tool_call_id\":\"call_1\",\"result_json\":\"{}\",\"duration_ms\":1,\"artifacts\":\"not-array\"}}";

    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(json, allocator));
}

test "tool envelope rejects remaining negative unsigned fields without leaks" {
    const allocator = std.testing.allocator;
    const negative_search_limit =
        "{\"type\":\"artifact_search\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"query\":\"needle\",\"limit\":-1}}";
    const negative_read_limit =
        "{\"type\":\"hashline_read\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"byte_limit\":-1}}";
    const negative_result_line =
        "{\"type\":\"hashline_read_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"lines\":[{\"line\":-1,\"hash\":\"abc\",\"text\":\"bad\"}]}}";

    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(negative_search_limit, allocator));
    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(negative_read_limit, allocator));
    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(negative_result_line, allocator));
}

test "tool envelope rejects malformed artifact search results without leaks" {
    const allocator = std.testing.allocator;
    const missing_artifact =
        "{\"type\":\"artifact_search_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"results\":[{\"snippet\":\"hit\"}]}}";
    const non_object_artifact =
        "{\"type\":\"artifact_search_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"results\":[{\"artifact\":\"artifact-1\"}]}}";
    const non_object_result =
        "{\"type\":\"artifact_search_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"results\":[42]}}";

    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(missing_artifact, allocator));
    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(non_object_artifact, allocator));
    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(non_object_result, allocator));
}

test "tool envelope rejects malformed hashline read results without leaks" {
    const allocator = std.testing.allocator;
    const non_object_line =
        "{\"type\":\"hashline_read_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"lines\":[42]}}";
    const non_string_hash =
        "{\"type\":\"hashline_read_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"lines\":[{\"line\":1,\"hash\":42,\"text\":\"bad\"}]}}";
    const non_string_text =
        "{\"type\":\"hashline_read_result\",\"server_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{\"path\":\"src/main.zig\",\"lines\":[{\"line\":1,\"hash\":\"abc\",\"text\":42}]}}";

    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(non_object_line, allocator));
    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(non_string_hash, allocator));
    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(non_string_text, allocator));
}
