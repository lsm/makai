const std = @import("std");
const auth_types = @import("auth_types");
const json_writer = @import("json_writer");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const protocol_types = auth_types;

pub fn serializeEnvelope(env: auth_types.Envelope, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);
    var writer = json_writer.JsonWriter.init(&buffer, allocator);

    try writer.beginObject();
    try writer.writeStringField("type", @tagName(env.payload));

    const stream_id = try auth_types.uuidToString(env.stream_id, allocator);
    defer allocator.free(stream_id);
    try writer.writeStringField("stream_id", stream_id);

    const message_id = try auth_types.uuidToString(env.message_id, allocator);
    defer allocator.free(message_id);
    try writer.writeStringField("message_id", message_id);

    try writer.writeIntField("sequence", env.sequence);
    try writer.writeIntField("timestamp", env.timestamp);
    try writer.writeIntField("version", env.version);

    if (env.in_reply_to) |reply_to| {
        const in_reply_to = try auth_types.uuidToString(reply_to, allocator);
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
            const flow_id = try auth_types.uuidToString(response.flow_id, allocator);
            defer allocator.free(flow_id);
            try writer.writeStringField("flow_id", flow_id);
            try writer.writeStringField("prompt_id", response.prompt_id.slice());
            try writer.writeStringField("answer", response.answer.slice());
        },
        .auth_cancel => |request| {
            const flow_id = try auth_types.uuidToString(request.flow_id, allocator);
            defer allocator.free(flow_id);
            try writer.writeStringField("flow_id", flow_id);
        },
        .ack => |ack| {
            const acknowledged_id = try auth_types.uuidToString(ack.acknowledged_id, allocator);
            defer allocator.free(acknowledged_id);
            try writer.writeStringField("acknowledged_id", acknowledged_id);
        },
        .nack => |nack| {
            const rejected_id = try auth_types.uuidToString(nack.rejected_id, allocator);
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
            const flow_id = try auth_types.uuidToString(result.flow_id, allocator);
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
            const flow_id = try auth_types.uuidToString(payload.flow_id, allocator);
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
            const flow_id = try auth_types.uuidToString(payload.flow_id, allocator);
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
            const flow_id = try auth_types.uuidToString(payload.flow_id, allocator);
            defer allocator.free(flow_id);

            try writer.writeKey("progress");
            try writer.beginObject();
            try writer.writeStringField("flow_id", flow_id);
            try writer.writeStringField("provider_id", payload.provider_id.slice());
            try writer.writeStringField("message", payload.message.slice());
            try writer.endObject();
        },
        .success => |payload| {
            const flow_id = try auth_types.uuidToString(payload.flow_id, allocator);
            defer allocator.free(flow_id);

            try writer.writeKey("success");
            try writer.beginObject();
            try writer.writeStringField("flow_id", flow_id);
            try writer.writeStringField("provider_id", payload.provider_id.slice());
            try writer.endObject();
        },
        .@"error" => |payload| {
            const flow_id = try auth_types.uuidToString(payload.flow_id, allocator);
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

    const root = parsed.value.object;
    const type_str = root.get("type").?.string;
    const stream_id = try parseUuidRequired(root.get("stream_id").?.string);
    const message_id = try parseUuidRequired(root.get("message_id").?.string);
    const sequence = @as(u64, @intCast(root.get("sequence").?.integer));
    const timestamp = root.get("timestamp").?.integer;
    const version = @as(u8, @intCast(root.get("version").?.integer));

    var in_reply_to: ?auth_types.Uuid = null;
    if (root.get("in_reply_to")) |value| {
        in_reply_to = try parseUuidRequired(value.string);
    }

    const payload = try deserializePayload(type_str, root.get("payload").?.object, allocator);

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

fn parseUuidRequired(value: []const u8) !auth_types.Uuid {
    return auth_types.parseUuid(value) orelse error.InvalidUuid;
}

fn deserializePayload(type_str: []const u8, payload: std.json.ObjectMap, allocator: std.mem.Allocator) !auth_types.Payload {
    if (std.mem.eql(u8, type_str, "auth_providers_request")) {
        return .{ .auth_providers_request = .{} };
    }

    if (std.mem.eql(u8, type_str, "auth_login_start")) {
        return .{ .auth_login_start = .{
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, payload.get("provider_id").?.string)),
        } };
    }

    if (std.mem.eql(u8, type_str, "auth_prompt_response")) {
        return .{ .auth_prompt_response = .{
            .flow_id = try parseUuidRequired(payload.get("flow_id").?.string),
            .prompt_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, payload.get("prompt_id").?.string)),
            .answer = OwnedSlice(u8).initOwned(try allocator.dupe(u8, payload.get("answer").?.string)),
        } };
    }

    if (std.mem.eql(u8, type_str, "auth_cancel")) {
        return .{ .auth_cancel = .{
            .flow_id = try parseUuidRequired(payload.get("flow_id").?.string),
        } };
    }

    if (std.mem.eql(u8, type_str, "ack")) {
        return .{ .ack = .{
            .acknowledged_id = try parseUuidRequired(payload.get("acknowledged_id").?.string),
        } };
    }

    if (std.mem.eql(u8, type_str, "nack")) {
        var nack = auth_types.Nack{
            .rejected_id = try parseUuidRequired(payload.get("rejected_id").?.string),
            .reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, payload.get("reason").?.string)),
        };

        if (payload.get("error_code")) |error_code| {
            nack.error_code = std.meta.stringToEnum(auth_types.ErrorCode, error_code.string) orelse .invalid_request;
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
            const provider_obj = provider_value.object;

            providers[i] = .{
                .id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, provider_obj.get("id").?.string)),
                .name = OwnedSlice(u8).initOwned(try allocator.dupe(u8, provider_obj.get("name").?.string)),
                .auth_status = std.meta.stringToEnum(auth_types.AuthStatus, provider_obj.get("auth_status").?.string) orelse .unknown,
            };

            if (provider_obj.get("last_error")) |last_error| {
                providers[i].last_error = OwnedSlice(u8).initOwned(try allocator.dupe(u8, last_error.string));
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
            .flow_id = try parseUuidRequired(payload.get("flow_id").?.string),
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, payload.get("provider_id").?.string)),
            .status = std.meta.stringToEnum(auth_types.AuthLoginStatus, payload.get("status").?.string) orelse .failed,
        } };
    }

    if (std.mem.eql(u8, type_str, "ping")) {
        return .ping;
    }

    if (std.mem.eql(u8, type_str, "pong")) {
        return .{ .pong = .{
            .ping_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, payload.get("ping_id").?.string)),
        } };
    }

    if (std.mem.eql(u8, type_str, "goodbye")) {
        var goodbye = auth_types.Goodbye{};
        if (payload.get("reason")) |reason| {
            goodbye.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, reason.string));
        }
        return .{ .goodbye = goodbye };
    }

    return error.InvalidPayloadType;
}

fn deserializeAuthEvent(payload: std.json.ObjectMap, allocator: std.mem.Allocator) !auth_types.AuthEvent {
    if (payload.get("auth_url")) |auth_url_value| {
        if (auth_url_value != .object) return error.InvalidPayloadType;
        const auth_url = auth_url_value.object;

        var result: auth_types.AuthEvent = .{ .auth_url = .{
            .flow_id = try parseUuidRequired(auth_url.get("flow_id").?.string),
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, auth_url.get("provider_id").?.string)),
            .url = OwnedSlice(u8).initOwned(try allocator.dupe(u8, auth_url.get("url").?.string)),
        } };

        if (auth_url.get("instructions")) |instructions| {
            result.auth_url.instructions = OwnedSlice(u8).initOwned(try allocator.dupe(u8, instructions.string));
        }

        return result;
    }

    if (payload.get("prompt")) |prompt_value| {
        if (prompt_value != .object) return error.InvalidPayloadType;
        const prompt = prompt_value.object;
        return .{ .prompt = .{
            .flow_id = try parseUuidRequired(prompt.get("flow_id").?.string),
            .prompt_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, prompt.get("prompt_id").?.string)),
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, prompt.get("provider_id").?.string)),
            .message = OwnedSlice(u8).initOwned(try allocator.dupe(u8, prompt.get("message").?.string)),
            .allow_empty = if (prompt.get("allow_empty")) |allow_empty| allow_empty.bool else false,
        } };
    }

    if (payload.get("progress")) |progress_value| {
        if (progress_value != .object) return error.InvalidPayloadType;
        const progress = progress_value.object;
        return .{ .progress = .{
            .flow_id = try parseUuidRequired(progress.get("flow_id").?.string),
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, progress.get("provider_id").?.string)),
            .message = OwnedSlice(u8).initOwned(try allocator.dupe(u8, progress.get("message").?.string)),
        } };
    }

    if (payload.get("success")) |success_value| {
        if (success_value != .object) return error.InvalidPayloadType;
        const success = success_value.object;
        return .{ .success = .{
            .flow_id = try parseUuidRequired(success.get("flow_id").?.string),
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, success.get("provider_id").?.string)),
        } };
    }

    if (payload.get("error")) |error_value| {
        if (error_value != .object) return error.InvalidPayloadType;
        const event_error = error_value.object;

        var result: auth_types.AuthEvent = .{ .@"error" = .{
            .flow_id = try parseUuidRequired(event_error.get("flow_id").?.string),
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, event_error.get("provider_id").?.string)),
            .message = OwnedSlice(u8).initOwned(try allocator.dupe(u8, event_error.get("message").?.string)),
        } };

        if (event_error.get("code")) |code| {
            result.@"error".code = OwnedSlice(u8).initOwned(try allocator.dupe(u8, code.string));
        }

        return result;
    }

    return error.InvalidPayloadType;
}

test "auth envelope roundtrip with auth_event prompt" {
    const allocator = std.testing.allocator;
    const flow_id = auth_types.generateUuid();

    var envelope = auth_types.Envelope{
        .stream_id = flow_id,
        .message_id = auth_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
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
        "{\"type\":\"not_real\",\"stream_id\":\"00000000-0000-0000-0000-000000000001\",\"message_id\":\"00000000-0000-0000-0000-000000000002\",\"sequence\":1,\"timestamp\":1,\"version\":1,\"payload\":{}}";
    try std.testing.expectError(error.InvalidPayloadType, deserializeEnvelope(bad, allocator));
}
