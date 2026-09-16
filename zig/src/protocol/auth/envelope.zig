const std = @import("std");
const compat = @import("compat");
const auth_types = @import("auth_types");
const json_writer = @import("json_writer");
const OwnedSlice = @import("owned_slice").OwnedSlice;
const jf = @import("json_field");

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

    const root = try jf.asObject(parsed.value);
    const type_str = try jf.requireString(root, "type");
    const stream_id = try parseUlidRequired(try jf.requireString(root, "stream_id"));
    const message_id = try parseUlidRequired(try jf.requireString(root, "message_id"));
    const sequence = try jf.requireUnsigned(u64, root, "sequence");
    const timestamp = try jf.requireInteger(root, "timestamp");
    const version = try jf.unsignedOr(u8, root, "version", 1);

    var in_reply_to: ?auth_types.Ulid = null;
    if (try jf.optionalString(root, "in_reply_to")) |value| {
        in_reply_to = try parseUlidRequired(value);
    }

    const payload = try deserializePayload(type_str, try jf.requireObject(root, "payload"), allocator);

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

fn parseUlidRequired(value: []const u8) !auth_types.Ulid {
    return auth_types.parseUlid(value) orelse error.InvalidUlid;
}

fn deserializePayload(type_str: []const u8, payload: std.json.ObjectMap, allocator: std.mem.Allocator) !auth_types.Payload {
    if (std.mem.eql(u8, type_str, "auth_providers_request")) {
        return .{ .auth_providers_request = .{} };
    }

    if (std.mem.eql(u8, type_str, "auth_login_start")) {
        return .{ .auth_login_start = .{
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(payload, "provider_id"))),
        } };
    }

    if (std.mem.eql(u8, type_str, "auth_prompt_response")) {
        return .{ .auth_prompt_response = .{
            .flow_id = try parseUlidRequired(try jf.requireString(payload, "flow_id")),
            .prompt_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(payload, "prompt_id"))),
            .answer = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(payload, "answer"))),
        } };
    }

    if (std.mem.eql(u8, type_str, "auth_cancel")) {
        return .{ .auth_cancel = .{
            .flow_id = try parseUlidRequired(try jf.requireString(payload, "flow_id")),
        } };
    }

    if (std.mem.eql(u8, type_str, "ack")) {
        return .{ .ack = .{
            .acknowledged_id = try parseUlidRequired(try jf.requireString(payload, "acknowledged_id")),
        } };
    }

    if (std.mem.eql(u8, type_str, "nack")) {
        var nack = auth_types.Nack{
            .rejected_id = try parseUlidRequired(try jf.requireString(payload, "rejected_id")),
            .reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(payload, "reason"))),
        };

        if (try jf.optionalString(payload, "error_code")) |error_code| {
            nack.error_code = std.meta.stringToEnum(auth_types.ErrorCode, error_code) orelse .invalid_request;
        }

        return .{ .nack = nack };
    }

    if (std.mem.eql(u8, type_str, "auth_providers_response")) {
        const providers_value = payload.get("providers") orelse return error.InvalidPayloadType;
        if (providers_value != .array) return error.InvalidPayloadType;

        const providers = try allocator.alloc(auth_types.AuthProviderInfo, providers_value.array.items.len);
        errdefer {
            for (providers) |*provider| {
                provider.deinit(allocator);
            }
            allocator.free(providers);
        }

        for (providers_value.array.items, 0..) |provider_value, i| {
            if (provider_value != .object) return error.InvalidPayloadType;
            const provider_obj = try jf.elementAsObject(provider_value);

            providers[i] = .{
                .id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(provider_obj, "id"))),
                .name = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(provider_obj, "name"))),
                .auth_status = std.meta.stringToEnum(auth_types.AuthStatus, try jf.requireString(provider_obj, "auth_status")) orelse .unknown,
            };

            if (try jf.optionalString(provider_obj, "last_error")) |last_error| {
                providers[i].last_error = OwnedSlice(u8).initOwned(try allocator.dupe(u8, last_error));
            }
        }

        return .{ .auth_providers_response = .{
            .providers = OwnedSlice(auth_types.AuthProviderInfo).initOwned(providers),
        } };
    }

    if (std.mem.eql(u8, type_str, "auth_event")) {
        return .{ .auth_event = try deserializeAuthEvent(payload, allocator) };
    }

    if (std.mem.eql(u8, type_str, "auth_login_result")) {
        return .{ .auth_login_result = .{
            .flow_id = try parseUlidRequired(try jf.requireString(payload, "flow_id")),
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(payload, "provider_id"))),
            .status = std.meta.stringToEnum(auth_types.AuthLoginStatus, try jf.requireString(payload, "status")) orelse .failed,
        } };
    }

    if (std.mem.eql(u8, type_str, "ping")) {
        return .ping;
    }

    if (std.mem.eql(u8, type_str, "pong")) {
        return .{ .pong = .{
            .ping_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(payload, "ping_id"))),
        } };
    }

    if (std.mem.eql(u8, type_str, "goodbye")) {
        var goodbye = auth_types.Goodbye{};
        if (try jf.optionalString(payload, "reason")) |reason| {
            goodbye.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, reason));
        }
        return .{ .goodbye = goodbye };
    }

    return error.InvalidPayloadType;
}

fn deserializeAuthEvent(payload: std.json.ObjectMap, allocator: std.mem.Allocator) !auth_types.AuthEvent {
    if (try jf.optionalObject(payload, "auth_url")) |auth_url| {

        var result: auth_types.AuthEvent = .{ .auth_url = .{
            .flow_id = try parseUlidRequired(try jf.requireString(auth_url, "flow_id")),
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(auth_url, "provider_id"))),
            .url = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(auth_url, "url"))),
        } };

        if (try jf.optionalString(auth_url, "instructions")) |instructions| {
            result.auth_url.instructions = OwnedSlice(u8).initOwned(try allocator.dupe(u8, instructions));
        }

        return result;
    }

    if (try jf.optionalObject(payload, "prompt")) |prompt| {
        return .{ .prompt = .{
            .flow_id = try parseUlidRequired(try jf.requireString(prompt, "flow_id")),
            .prompt_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(prompt, "prompt_id"))),
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(prompt, "provider_id"))),
            .message = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(prompt, "message"))),
            .allow_empty = if (try jf.optionalBool(prompt, "allow_empty")) |allow_empty| allow_empty else false,
        } };
    }

    if (try jf.optionalObject(payload, "progress")) |progress| {
        return .{ .progress = .{
            .flow_id = try parseUlidRequired(try jf.requireString(progress, "flow_id")),
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(progress, "provider_id"))),
            .message = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(progress, "message"))),
        } };
    }

    if (try jf.optionalObject(payload, "success")) |success| {
        return .{ .success = .{
            .flow_id = try parseUlidRequired(try jf.requireString(success, "flow_id")),
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(success, "provider_id"))),
        } };
    }

    if (try jf.optionalObject(payload, "error")) |event_error| {

        var result: auth_types.AuthEvent = .{ .@"error" = .{
            .flow_id = try parseUlidRequired(try jf.requireString(event_error, "flow_id")),
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(event_error, "provider_id"))),
            .message = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try jf.requireString(event_error, "message"))),
        } };

        if (try jf.optionalString(event_error, "code")) |code| {
            result.@"error".code = OwnedSlice(u8).initOwned(try allocator.dupe(u8, code));
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
