const std = @import("std");
const compat = @import("compat");
const auth_types = @import("auth_types");
const json_writer = @import("json_writer");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const protocol_types = auth_types;

pub fn serializeEnvelope(env: auth_types.Envelope, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var writer = json_writer.JsonWriter.init(&buffer, allocator);

    try writer.beginObject();
    try writer.writeStringField("type", @tagName(env.payload));

    const stream_id = try auth_types.ulidToString(env.stream_id, allocator);
    defer allocator.free(stream_id);
    try writer.writeStringField("stream_id", stream_id);

    const message_id = try auth_types.ulidToString(env.message_id, allocator);
    defer allocator.free(message_id);
    try writer.writeStringField("message_id", message_id);

    try writer.writeIntField("sequence", env.sequence);
    try writer.writeIntField("timestamp", env.timestamp);
    try writer.writeIntField("version", env.version);

    if (env.in_reply_to) |reply_to| {
        const in_reply_to = try auth_types.ulidToString(reply_to, allocator);
        defer allocator.free(in_reply_to);
        try writer.writeStringField("in_reply_to", in_reply_to);
    }

    try writer.writeKey("payload");
    try serializePayload(&writer, env.payload, allocator);
    try writer.endObject();

    const out = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return out;
}

fn serializePayload(writer: *json_writer.JsonWriter, payload: auth_types.Payload, allocator: std.mem.Allocator) !void {
    try writer.beginObject();

    switch (payload) {
        .auth_providers_request => {},
        .auth_login_start => |request| {
            try writer.writeStringField("provider_id", request.provider_id.slice());
        },
        .auth_prompt_response => |response| {
            const flow_id = try auth_types.ulidToString(response.flow_id, allocator);
            defer allocator.free(flow_id);
            try writer.writeStringField("flow_id", flow_id);
            try writer.writeStringField("prompt_id", response.prompt_id.slice());
            try writer.writeStringField("answer", response.answer.slice());
        },
        .auth_cancel => |request| {
            const flow_id = try auth_types.ulidToString(request.flow_id, allocator);
            defer allocator.free(flow_id);
            try writer.writeStringField("flow_id", flow_id);
        },
        .ack => |ack| {
            const acknowledged_id = try auth_types.ulidToString(ack.acknowledged_id, allocator);
            defer allocator.free(acknowledged_id);
            try writer.writeStringField("acknowledged_id", acknowledged_id);
        },
        .nack => |nack| {
            const rejected_id = try auth_types.ulidToString(nack.rejected_id, allocator);
            defer allocator.free(rejected_id);
            try writer.writeStringField("rejected_id", rejected_id);
            try writer.writeStringField("reason", nack.reason.slice());
            if (nack.error_code) |error_code| {
                try writer.writeStringField("error_code", @tagName(error_code));
            }
        },
        .auth_providers_response => |response| {
            try writer.writeKey("providers");
            try writer.beginArray();
            for (response.providers.slice()) |provider| {
                try writer.beginObject();
                try writer.writeStringField("id", provider.id.slice());
                try writer.writeStringField("name", provider.name.slice());
                try writer.writeStringField("auth_status", @tagName(provider.auth_status));
                if (provider.last_error.slice().len > 0) {
                    try writer.writeStringField("last_error", provider.last_error.slice());
                }
                try writer.endObject();
            }
            try writer.endArray();
        },
        .auth_event => |event| {
            try serializeAuthEvent(writer, event, allocator);
        },
        .auth_login_result => |result| {
            const flow_id = try auth_types.ulidToString(result.flow_id, allocator);
            defer allocator.free(flow_id);
            try writer.writeStringField("flow_id", flow_id);
            try writer.writeStringField("provider_id", result.provider_id.slice());
            try writer.writeStringField("status", @tagName(result.status));
        },
        .ping => {},
        .pong => |pong| {
            try writer.writeStringField("ping_id", pong.ping_id.slice());
        },
        .goodbye => |goodbye| {
            if (goodbye.reason.slice().len > 0) {
                try writer.writeStringField("reason", goodbye.reason.slice());
            }
        },
    }

    try writer.endObject();
}

fn serializeAuthEvent(writer: *json_writer.JsonWriter, event: auth_types.AuthEvent, allocator: std.mem.Allocator) !void {
    switch (event) {
        .auth_url => |payload| {
            const flow_id = try auth_types.ulidToString(payload.flow_id, allocator);
            defer allocator.free(flow_id);

            try writer.writeKey("auth_url");
            try writer.beginObject();
            try writer.writeStringField("flow_id", flow_id);
            try writer.writeStringField("provider_id", payload.provider_id.slice());
            try writer.writeStringField("url", payload.url.slice());
            if (payload.instructions.slice().len > 0) {
                try writer.writeStringField("instructions", payload.instructions.slice());
            }
            try writer.endObject();
        },
        .prompt => |payload| {
            const flow_id = try auth_types.ulidToString(payload.flow_id, allocator);
            defer allocator.free(flow_id);

            try writer.writeKey("prompt");
            try writer.beginObject();
            try writer.writeStringField("flow_id", flow_id);
            try writer.writeStringField("prompt_id", payload.prompt_id.slice());
            try writer.writeStringField("provider_id", payload.provider_id.slice());
            try writer.writeStringField("message", payload.message.slice());
            try writer.writeBoolField("allow_empty", payload.allow_empty);
            try writer.endObject();
        },
        .progress => |payload| {
            const flow_id = try auth_types.ulidToString(payload.flow_id, allocator);
            defer allocator.free(flow_id);

            try writer.writeKey("progress");
            try writer.beginObject();
            try writer.writeStringField("flow_id", flow_id);
            try writer.writeStringField("provider_id", payload.provider_id.slice());
            try writer.writeStringField("message", payload.message.slice());
            try writer.endObject();
        },
        .success => |payload| {
            const flow_id = try auth_types.ulidToString(payload.flow_id, allocator);
            defer allocator.free(flow_id);

            try writer.writeKey("success");
            try writer.beginObject();
            try writer.writeStringField("flow_id", flow_id);
            try writer.writeStringField("provider_id", payload.provider_id.slice());
            try writer.endObject();
        },
        .@"error" => |payload| {
            const flow_id = try auth_types.ulidToString(payload.flow_id, allocator);
            defer allocator.free(flow_id);

            try writer.writeKey("error");
            try writer.beginObject();
            try writer.writeStringField("flow_id", flow_id);
            try writer.writeStringField("provider_id", payload.provider_id.slice());
            if (payload.code.slice().len > 0) {
                try writer.writeStringField("code", payload.code.slice());
            }
            try writer.writeStringField("message", payload.message.slice());
            try writer.endObject();
        },
    }
}

pub fn deserializeEnvelope(json: []const u8, allocator: std.mem.Allocator) !auth_types.Envelope {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = try asObject(parsed.value);
    const type_str = try requiredString(root, "type");
    const stream_id = try parseUlidRequired(try requiredString(root, "stream_id"));
    const message_id = try parseUlidRequired(try requiredString(root, "message_id"));
    const sequence = try requiredBoundedInteger(u64, root, "sequence");
    const timestamp = try requiredInteger(root, "timestamp");
    const version: u8 = if (root.get("version")) |value|
        try asBoundedInteger(u8, value)
    else
        auth_types.PROTOCOL_VERSION;

    var in_reply_to: ?auth_types.Ulid = null;
    if (root.get("in_reply_to")) |value| {
        in_reply_to = try parseUlidRequired(try asString(value));
    }

    const payload = try deserializePayload(type_str, try requiredObject(root, "payload"), allocator);

    return .{
        .version = version,
        .stream_id = stream_id,
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
    return if (obj.get(key)) |value| try asString(value) else null;
}

fn optionalBool(obj: std.json.ObjectMap, key: []const u8, fallback: bool) FieldError!bool {
    return if (obj.get(key)) |value| try asBool(value) else fallback;
}

fn parseUlidRequired(value: []const u8) !auth_types.Ulid {
    return auth_types.parseUlid(value) orelse error.InvalidUlid;
}

fn deserializePayload(type_str: []const u8, payload: std.json.ObjectMap, allocator: std.mem.Allocator) !auth_types.Payload {
    if (std.mem.eql(u8, type_str, "auth_providers_request")) {
        return .{ .auth_providers_request = .{} };
    }

    if (std.mem.eql(u8, type_str, "auth_login_start")) {
        const provider_id = try requiredString(payload, "provider_id");
        return .{ .auth_login_start = .{
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, provider_id)),
        } };
    }

    if (std.mem.eql(u8, type_str, "auth_prompt_response")) {
        const flow_id = try parseUlidRequired(try requiredString(payload, "flow_id"));
        const prompt_id = try requiredString(payload, "prompt_id");
        const answer = try requiredString(payload, "answer");

        const prompt_id_slice = OwnedSlice(u8).initOwned(try allocator.dupe(u8, prompt_id));
        errdefer {
            var mutable = prompt_id_slice;
            mutable.deinit(allocator);
        }

        return .{ .auth_prompt_response = .{
            .flow_id = flow_id,
            .prompt_id = prompt_id_slice,
            .answer = OwnedSlice(u8).initOwned(try allocator.dupe(u8, answer)),
        } };
    }

    if (std.mem.eql(u8, type_str, "auth_cancel")) {
        return .{ .auth_cancel = .{
            .flow_id = try parseUlidRequired(try requiredString(payload, "flow_id")),
        } };
    }

    if (std.mem.eql(u8, type_str, "ack")) {
        return .{ .ack = .{
            .acknowledged_id = try parseUlidRequired(try requiredString(payload, "acknowledged_id")),
        } };
    }

    if (std.mem.eql(u8, type_str, "nack")) {
        const rejected_id = try parseUlidRequired(try requiredString(payload, "rejected_id"));
        const reason = try requiredString(payload, "reason");
        const error_code = try optionalString(payload, "error_code");

        var nack = auth_types.Nack{
            .rejected_id = rejected_id,
            .reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, reason)),
        };

        if (error_code) |value| {
            nack.error_code = std.meta.stringToEnum(auth_types.ErrorCode, value) orelse .invalid_request;
        }

        return .{ .nack = nack };
    }

    if (std.mem.eql(u8, type_str, "auth_providers_response")) {
        const providers_array = try requiredArray(payload, "providers");

        const providers = try allocator.alloc(auth_types.AuthProviderInfo, providers_array.items.len);
        var initialized: usize = 0;
        errdefer {
            for (providers[0..initialized]) |*provider| {
                provider.deinit(allocator);
            }
            allocator.free(providers);
        }

        for (providers_array.items, 0..) |provider_value, i| {
            const provider_obj = try asObject(provider_value);
            const id = try requiredString(provider_obj, "id");
            const name = try requiredString(provider_obj, "name");
            const auth_status = try requiredString(provider_obj, "auth_status");
            const last_error = try optionalString(provider_obj, "last_error");

            const id_slice = OwnedSlice(u8).initOwned(try allocator.dupe(u8, id));
            errdefer {
                var mutable = id_slice;
                mutable.deinit(allocator);
            }
            const name_slice = OwnedSlice(u8).initOwned(try allocator.dupe(u8, name));
            errdefer {
                var mutable = name_slice;
                mutable.deinit(allocator);
            }

            providers[i] = .{
                .id = id_slice,
                .name = name_slice,
                .auth_status = std.meta.stringToEnum(auth_types.AuthStatus, auth_status) orelse .unknown,
            };

            if (last_error) |value| {
                providers[i].last_error = OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
            }
            initialized += 1;
        }

        return .{ .auth_providers_response = .{
            .providers = OwnedSlice(auth_types.AuthProviderInfo).initOwned(providers),
        } };
    }

    if (std.mem.eql(u8, type_str, "auth_event")) {
        return .{ .auth_event = try deserializeAuthEvent(payload, allocator) };
    }

    if (std.mem.eql(u8, type_str, "auth_login_result")) {
        const flow_id = try parseUlidRequired(try requiredString(payload, "flow_id"));
        const provider_id = try requiredString(payload, "provider_id");
        const status = try requiredString(payload, "status");

        return .{ .auth_login_result = .{
            .flow_id = flow_id,
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, provider_id)),
            .status = std.meta.stringToEnum(auth_types.AuthLoginStatus, status) orelse .failed,
        } };
    }

    if (std.mem.eql(u8, type_str, "ping")) {
        return .ping;
    }

    if (std.mem.eql(u8, type_str, "pong")) {
        const ping_id = try requiredString(payload, "ping_id");
        return .{ .pong = .{
            .ping_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, ping_id)),
        } };
    }

    if (std.mem.eql(u8, type_str, "goodbye")) {
        const reason = try optionalString(payload, "reason");
        var goodbye = auth_types.Goodbye{};
        if (reason) |value| {
            goodbye.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
        }
        return .{ .goodbye = goodbye };
    }

    return error.InvalidPayloadType;
}

fn deserializeAuthEvent(payload: std.json.ObjectMap, allocator: std.mem.Allocator) !auth_types.AuthEvent {
    if (payload.get("auth_url")) |auth_url_value| {
        const auth_url = try asObject(auth_url_value);
        const flow_id = try parseUlidRequired(try requiredString(auth_url, "flow_id"));
        const provider_id = try requiredString(auth_url, "provider_id");
        const url = try requiredString(auth_url, "url");
        const instructions = try optionalString(auth_url, "instructions");

        const provider_id_slice = OwnedSlice(u8).initOwned(try allocator.dupe(u8, provider_id));
        errdefer {
            var mutable = provider_id_slice;
            mutable.deinit(allocator);
        }
        const url_slice = OwnedSlice(u8).initOwned(try allocator.dupe(u8, url));
        errdefer {
            var mutable = url_slice;
            mutable.deinit(allocator);
        }

        var result: auth_types.AuthEvent = .{ .auth_url = .{
            .flow_id = flow_id,
            .provider_id = provider_id_slice,
            .url = url_slice,
        } };

        if (instructions) |value| {
            result.auth_url.instructions = OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
        }

        return result;
    }

    if (payload.get("prompt")) |prompt_value| {
        const prompt = try asObject(prompt_value);
        const flow_id = try parseUlidRequired(try requiredString(prompt, "flow_id"));
        const prompt_id = try requiredString(prompt, "prompt_id");
        const provider_id = try requiredString(prompt, "provider_id");
        const message = try requiredString(prompt, "message");
        const allow_empty = try optionalBool(prompt, "allow_empty", false);

        const prompt_id_slice = OwnedSlice(u8).initOwned(try allocator.dupe(u8, prompt_id));
        errdefer {
            var mutable = prompt_id_slice;
            mutable.deinit(allocator);
        }
        const provider_id_slice = OwnedSlice(u8).initOwned(try allocator.dupe(u8, provider_id));
        errdefer {
            var mutable = provider_id_slice;
            mutable.deinit(allocator);
        }

        return .{ .prompt = .{
            .flow_id = flow_id,
            .prompt_id = prompt_id_slice,
            .provider_id = provider_id_slice,
            .message = OwnedSlice(u8).initOwned(try allocator.dupe(u8, message)),
            .allow_empty = allow_empty,
        } };
    }

    if (payload.get("progress")) |progress_value| {
        const progress = try asObject(progress_value);
        const flow_id = try parseUlidRequired(try requiredString(progress, "flow_id"));
        const provider_id = try requiredString(progress, "provider_id");
        const message = try requiredString(progress, "message");

        const provider_id_slice = OwnedSlice(u8).initOwned(try allocator.dupe(u8, provider_id));
        errdefer {
            var mutable = provider_id_slice;
            mutable.deinit(allocator);
        }

        return .{ .progress = .{
            .flow_id = flow_id,
            .provider_id = provider_id_slice,
            .message = OwnedSlice(u8).initOwned(try allocator.dupe(u8, message)),
        } };
    }

    if (payload.get("success")) |success_value| {
        const success = try asObject(success_value);
        const flow_id = try parseUlidRequired(try requiredString(success, "flow_id"));
        const provider_id = try requiredString(success, "provider_id");

        return .{ .success = .{
            .flow_id = flow_id,
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, provider_id)),
        } };
    }

    if (payload.get("error")) |error_value| {
        const event_error = try asObject(error_value);
        const flow_id = try parseUlidRequired(try requiredString(event_error, "flow_id"));
        const provider_id = try requiredString(event_error, "provider_id");
        const message = try requiredString(event_error, "message");
        const code = try optionalString(event_error, "code");

        const provider_id_slice = OwnedSlice(u8).initOwned(try allocator.dupe(u8, provider_id));
        errdefer {
            var mutable = provider_id_slice;
            mutable.deinit(allocator);
        }
        const message_slice = OwnedSlice(u8).initOwned(try allocator.dupe(u8, message));
        errdefer {
            var mutable = message_slice;
            mutable.deinit(allocator);
        }

        var result: auth_types.AuthEvent = .{ .@"error" = .{
            .flow_id = flow_id,
            .provider_id = provider_id_slice,
            .message = message_slice,
        } };

        if (code) |value| {
            result.@"error".code = OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
        }

        return result;
    }

    return error.InvalidPayloadType;
}

test "auth envelope roundtrip with auth_event prompt" {
    const allocator = std.testing.allocator;
    const flow_id = auth_types.generateUlid();

    var envelope = auth_types.Envelope{
        .stream_id = flow_id,
        .message_id = auth_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .auth_event = .{ .prompt = .{
            .flow_id = flow_id,
            .prompt_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "prompt-1")),
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "test-fixture")),
            .message = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "Enter fixture code:")),
            .allow_empty = false,
        } } },
    };
    defer envelope.deinit(allocator);

    const json = try serializeEnvelope(envelope, allocator);
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.payload == .auth_event);
    try std.testing.expect(parsed.payload.auth_event == .prompt);
    try std.testing.expectEqualStrings("prompt-1", parsed.payload.auth_event.prompt.prompt_id.slice());
    try std.testing.expectEqualStrings("test-fixture", parsed.payload.auth_event.prompt.provider_id.slice());
}

test "auth envelope rejects unknown payload type" {
    const allocator = std.testing.allocator;
    const bad =
        "{\"type\":\"not_real\",\"stream_id\":\"00000000000000000000000001\",\"message_id\":\"00000000000000000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{}}";
    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(bad, allocator));
}

const test_stream_id = "00000000000000000000000001";
const test_message_id = "00000000000000000000000002";

fn expectEnvelopeDecodeError(expected: anyerror, json: []const u8) !void {
    try std.testing.expectError(expected, deserializeEnvelope(json, std.testing.allocator));
}

fn expectAuthPayloadDecodeError(expected: anyerror, type_str: []const u8, payload_json: []const u8) !void {
    const allocator = std.testing.allocator;
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"{s}\",\"stream_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{s}}}",
        .{ type_str, test_stream_id, test_message_id, payload_json },
    );
    defer allocator.free(json);
    try std.testing.expectError(expected, deserializeEnvelope(json, allocator));
}

test "auth envelope rejects a non-object root" {
    try expectEnvelopeDecodeError(error.InvalidField, "[1,2,3]");
    try expectEnvelopeDecodeError(error.InvalidField, "42");
    try expectEnvelopeDecodeError(error.InvalidField, "\"frame\"");
}

test "auth envelope rejects a frame with no envelope fields instead of panicking" {
    try expectEnvelopeDecodeError(error.MissingField, "{\"type\":\"auth_event\"}");
    try expectEnvelopeDecodeError(error.MissingField, "{}");
}

test "auth envelope rejects a missing or non-string type" {
    const allocator = std.testing.allocator;

    const missing = try std.fmt.allocPrint(
        allocator,
        "{{\"stream_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{ test_stream_id, test_message_id },
    );
    defer allocator.free(missing);
    try expectEnvelopeDecodeError(error.MissingField, missing);

    const non_string = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":7,\"stream_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{ test_stream_id, test_message_id },
    );
    defer allocator.free(non_string);
    try expectEnvelopeDecodeError(error.InvalidField, non_string);
}

test "auth envelope rejects a missing, non-string or invalid stream_id" {
    const allocator = std.testing.allocator;

    const missing = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{test_message_id},
    );
    defer allocator.free(missing);
    try expectEnvelopeDecodeError(error.MissingField, missing);

    const non_string = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"stream_id\":123,\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{test_message_id},
    );
    defer allocator.free(non_string);
    try expectEnvelopeDecodeError(error.InvalidField, non_string);

    const null_valued = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"stream_id\":null,\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{test_message_id},
    );
    defer allocator.free(null_valued);
    try expectEnvelopeDecodeError(error.InvalidField, null_valued);

    const bad_ulid = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"stream_id\":\"not-a-ulid\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{test_message_id},
    );
    defer allocator.free(bad_ulid);
    try expectEnvelopeDecodeError(error.InvalidUlid, bad_ulid);
}

test "auth envelope rejects a missing or non-string message_id" {
    const allocator = std.testing.allocator;

    const missing = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"stream_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{test_stream_id},
    );
    defer allocator.free(missing);
    try expectEnvelopeDecodeError(error.MissingField, missing);

    const non_string = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"stream_id\":\"{s}\",\"message_id\":[],\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
        .{test_stream_id},
    );
    defer allocator.free(non_string);
    try expectEnvelopeDecodeError(error.InvalidField, non_string);
}

test "auth envelope rejects a missing, non-integer or out-of-range sequence" {
    const allocator = std.testing.allocator;

    const cases = [_]struct { fragment: []const u8, expected: anyerror }{
        .{ .fragment = "", .expected = error.MissingField },
        .{ .fragment = "\"sequence\":\"1\",", .expected = error.InvalidField },
        .{ .fragment = "\"sequence\":1.5,", .expected = error.InvalidField },
        .{ .fragment = "\"sequence\":-1,", .expected = error.InvalidField },
    };

    for (cases) |case| {
        const json = try std.fmt.allocPrint(
            allocator,
            "{{\"type\":\"ping\",\"stream_id\":\"{s}\",\"message_id\":\"{s}\",{s}\"timestamp\":1,\"version\":1,\"payload\":{{}}}}",
            .{ test_stream_id, test_message_id, case.fragment },
        );
        defer allocator.free(json);
        try expectEnvelopeDecodeError(case.expected, json);
    }
}

test "auth envelope rejects a missing timestamp and an out-of-range version" {
    const allocator = std.testing.allocator;

    const missing_timestamp = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"stream_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"version\":1,\"payload\":{{}}}}",
        .{ test_stream_id, test_message_id },
    );
    defer allocator.free(missing_timestamp);
    try expectEnvelopeDecodeError(error.MissingField, missing_timestamp);

    const oversized_version = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"stream_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":999,\"payload\":{{}}}}",
        .{ test_stream_id, test_message_id },
    );
    defer allocator.free(oversized_version);
    try expectEnvelopeDecodeError(error.InvalidField, oversized_version);
}

test "auth envelope defaults version to the protocol version when absent" {
    const allocator = std.testing.allocator;

    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"stream_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"payload\":{{}}}}",
        .{ test_stream_id, test_message_id },
    );
    defer allocator.free(json);

    var parsed = try deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(auth_types.PROTOCOL_VERSION, parsed.version);
}

test "auth envelope rejects a missing or non-object payload and a non-string in_reply_to" {
    const allocator = std.testing.allocator;

    const missing_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"stream_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1}}",
        .{ test_stream_id, test_message_id },
    );
    defer allocator.free(missing_payload);
    try expectEnvelopeDecodeError(error.MissingField, missing_payload);

    const non_object_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"stream_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":\"{{}}\"}}",
        .{ test_stream_id, test_message_id },
    );
    defer allocator.free(non_object_payload);
    try expectEnvelopeDecodeError(error.InvalidField, non_object_payload);

    const non_string_reply = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"ping\",\"stream_id\":\"{s}\",\"message_id\":\"{s}\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"in_reply_to\":false,\"payload\":{{}}}}",
        .{ test_stream_id, test_message_id },
    );
    defer allocator.free(non_string_reply);
    try expectEnvelopeDecodeError(error.InvalidField, non_string_reply);
}

test "auth envelope rejects missing required payload fields" {
    try expectAuthPayloadDecodeError(error.MissingField, "auth_login_start", "{}");
    try expectAuthPayloadDecodeError(error.MissingField, "auth_prompt_response", "{}");
    try expectAuthPayloadDecodeError(error.MissingField, "auth_prompt_response", "{\"flow_id\":\"00000000000000000000000003\",\"prompt_id\":\"p\"}");
    try expectAuthPayloadDecodeError(error.MissingField, "auth_cancel", "{}");
    try expectAuthPayloadDecodeError(error.MissingField, "ack", "{}");
    try expectAuthPayloadDecodeError(error.MissingField, "nack", "{\"rejected_id\":\"00000000000000000000000003\"}");
    try expectAuthPayloadDecodeError(error.MissingField, "auth_providers_response", "{}");
    try expectAuthPayloadDecodeError(error.MissingField, "auth_providers_response", "{\"providers\":[{\"id\":\"anthropic\"}]}");
    try expectAuthPayloadDecodeError(error.MissingField, "auth_login_result", "{\"flow_id\":\"00000000000000000000000003\",\"provider_id\":\"anthropic\"}");
    try expectAuthPayloadDecodeError(error.MissingField, "pong", "{}");
    try expectAuthPayloadDecodeError(error.MissingField, "auth_event", "{\"prompt\":{\"flow_id\":\"00000000000000000000000003\"}}");
    try expectAuthPayloadDecodeError(error.MissingField, "auth_event", "{\"auth_url\":{\"flow_id\":\"00000000000000000000000003\",\"provider_id\":\"anthropic\"}}");
    try expectAuthPayloadDecodeError(error.MissingField, "auth_event", "{\"success\":{\"flow_id\":\"00000000000000000000000003\"}}");
    try expectAuthPayloadDecodeError(error.MissingField, "auth_event", "{\"progress\":{\"flow_id\":\"00000000000000000000000003\",\"provider_id\":\"anthropic\"}}");
    try expectAuthPayloadDecodeError(error.MissingField, "auth_event", "{\"error\":{\"flow_id\":\"00000000000000000000000003\",\"provider_id\":\"anthropic\"}}");
}

test "auth envelope rejects wrongly typed payload fields" {
    try expectAuthPayloadDecodeError(error.InvalidField, "auth_login_start", "{\"provider_id\":5}");
    try expectAuthPayloadDecodeError(error.InvalidField, "auth_cancel", "{\"flow_id\":[]}");
    try expectAuthPayloadDecodeError(error.InvalidField, "nack", "{\"rejected_id\":\"00000000000000000000000003\",\"reason\":\"x\",\"error_code\":7}");
    try expectAuthPayloadDecodeError(error.InvalidField, "auth_providers_response", "{\"providers\":\"none\"}");
    try expectAuthPayloadDecodeError(error.InvalidField, "auth_providers_response", "{\"providers\":[\"not-an-object\"]}");
    try expectAuthPayloadDecodeError(error.InvalidField, "auth_event", "{\"prompt\":\"not-an-object\"}");
    try expectAuthPayloadDecodeError(
        error.InvalidField,
        "auth_event",
        "{\"prompt\":{\"flow_id\":\"00000000000000000000000003\",\"prompt_id\":\"p\",\"provider_id\":\"anthropic\",\"message\":\"m\",\"allow_empty\":\"yes\"}}",
    );
    try expectAuthPayloadDecodeError(error.InvalidField, "goodbye", "{\"reason\":9}");
}

test "auth envelope frees earlier providers when a later provider is malformed" {
    try expectAuthPayloadDecodeError(
        error.MissingField,
        "auth_providers_response",
        "{\"providers\":[{\"id\":\"anthropic\",\"name\":\"Anthropic\",\"auth_status\":\"authenticated\",\"last_error\":\"none\"},{\"id\":\"openai\",\"name\":\"OpenAI\"}]}",
    );
    try expectAuthPayloadDecodeError(
        error.InvalidField,
        "auth_providers_response",
        "{\"providers\":[{\"id\":\"anthropic\",\"name\":\"Anthropic\",\"auth_status\":\"authenticated\"},7]}",
    );
}
