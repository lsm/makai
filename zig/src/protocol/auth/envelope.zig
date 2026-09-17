const std = @import("std");
const compat = @import("compat");
const auth_types = @import("auth_types");
const fields = @import("envelope_fields");
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

    const root = try fields.rootObject(parsed.value);
    const type_str = try fields.requiredString(root, "type");
    const stream_id = try parseUlidRequired(try fields.requiredString(root, "stream_id"));
    const message_id = try parseUlidRequired(try fields.requiredString(root, "message_id"));
    const sequence = try fields.requiredInt(u64, root, "sequence");
    const timestamp = try fields.requiredInteger(root, "timestamp");
    const version = try fields.requiredInt(u8, root, "version");

    var in_reply_to: ?auth_types.Ulid = null;
    if (try fields.optionalString(root, "in_reply_to")) |value| {
        in_reply_to = try parseUlidRequired(value);
    }

    const payload = try deserializePayload(type_str, try fields.requiredObject(root, "payload"), allocator);

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
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(payload, "provider_id"))),
        } };
    }

    if (std.mem.eql(u8, type_str, "auth_prompt_response")) {
        const flow_id = try parseUlidRequired(try fields.requiredString(payload, "flow_id"));
        var prompt_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(payload, "prompt_id")));
        errdefer prompt_id.deinit(allocator);
        const answer = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(payload, "answer")));
        return .{ .auth_prompt_response = .{
            .flow_id = flow_id,
            .prompt_id = prompt_id,
            .answer = answer,
        } };
    }

    if (std.mem.eql(u8, type_str, "auth_cancel")) {
        return .{ .auth_cancel = .{
            .flow_id = try parseUlidRequired(try fields.requiredString(payload, "flow_id")),
        } };
    }

    if (std.mem.eql(u8, type_str, "ack")) {
        return .{ .ack = .{
            .acknowledged_id = try parseUlidRequired(try fields.requiredString(payload, "acknowledged_id")),
        } };
    }

    if (std.mem.eql(u8, type_str, "nack")) {
        const rejected_id = try parseUlidRequired(try fields.requiredString(payload, "rejected_id"));
        var nack = auth_types.Nack{
            .rejected_id = rejected_id,
            .reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(payload, "reason"))),
        };
        errdefer nack.deinit(allocator);

        if (try fields.optionalString(payload, "error_code")) |error_code| {
            nack.error_code = std.meta.stringToEnum(auth_types.ErrorCode, error_code) orelse .invalid_request;
        }

        return .{ .nack = nack };
    }

    if (std.mem.eql(u8, type_str, "auth_providers_response")) {
        const providers_value = payload.get("providers") orelse return error.InvalidPayloadType;
        if (providers_value != .array) return error.InvalidPayloadType;

        const providers = try allocator.alloc(auth_types.AuthProviderInfo, providers_value.array.items.len);
        var initialized: usize = 0;
        errdefer {
            for (providers[0..initialized]) |*provider| {
                provider.deinit(allocator);
            }
            allocator.free(providers);
        }

        for (providers_value.array.items, 0..) |provider_value, i| {
            const provider_obj = try fields.asObject(provider_value);

            var id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(provider_obj, "id")));
            errdefer id.deinit(allocator);
            var name = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(provider_obj, "name")));
            errdefer name.deinit(allocator);
            const auth_status = std.meta.stringToEnum(auth_types.AuthStatus, try fields.requiredString(provider_obj, "auth_status")) orelse .unknown;

            var last_error = OwnedSlice(u8).initBorrowed("");
            if (try fields.optionalString(provider_obj, "last_error")) |value| {
                last_error = OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
            }

            providers[i] = .{
                .id = id,
                .name = name,
                .auth_status = auth_status,
                .last_error = last_error,
            };
            initialized = i + 1;
        }

        return .{ .auth_providers_response = .{
            .providers = OwnedSlice(auth_types.AuthProviderInfo).initOwned(providers),
        } };
    }

    if (std.mem.eql(u8, type_str, "auth_event")) {
        return .{ .auth_event = try deserializeAuthEvent(payload, allocator) };
    }

    if (std.mem.eql(u8, type_str, "auth_login_result")) {
        const flow_id = try parseUlidRequired(try fields.requiredString(payload, "flow_id"));
        var provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(payload, "provider_id")));
        errdefer provider_id.deinit(allocator);
        const status = std.meta.stringToEnum(auth_types.AuthLoginStatus, try fields.requiredString(payload, "status")) orelse .failed;
        return .{ .auth_login_result = .{
            .flow_id = flow_id,
            .provider_id = provider_id,
            .status = status,
        } };
    }

    if (std.mem.eql(u8, type_str, "ping")) {
        return .ping;
    }

    if (std.mem.eql(u8, type_str, "pong")) {
        return .{ .pong = .{
            .ping_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(payload, "ping_id"))),
        } };
    }

    if (std.mem.eql(u8, type_str, "goodbye")) {
        var goodbye = auth_types.Goodbye{};
        if (try fields.optionalString(payload, "reason")) |reason| {
            goodbye.reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, reason));
        }
        return .{ .goodbye = goodbye };
    }

    return error.InvalidPayloadType;
}

fn deserializeAuthEvent(payload: std.json.ObjectMap, allocator: std.mem.Allocator) !auth_types.AuthEvent {
    if (payload.get("auth_url")) |auth_url_value| {
        const auth_url = try fields.asObject(auth_url_value);

        const flow_id = try parseUlidRequired(try fields.requiredString(auth_url, "flow_id"));
        var provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(auth_url, "provider_id")));
        errdefer provider_id.deinit(allocator);
        var url = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(auth_url, "url")));
        errdefer url.deinit(allocator);

        var instructions = OwnedSlice(u8).initBorrowed("");
        if (try fields.optionalString(auth_url, "instructions")) |value| {
            instructions = OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
        }

        return .{ .auth_url = .{
            .flow_id = flow_id,
            .provider_id = provider_id,
            .url = url,
            .instructions = instructions,
        } };
    }

    if (payload.get("prompt")) |prompt_value| {
        const prompt = try fields.asObject(prompt_value);
        const flow_id = try parseUlidRequired(try fields.requiredString(prompt, "flow_id"));
        var prompt_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(prompt, "prompt_id")));
        errdefer prompt_id.deinit(allocator);
        var provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(prompt, "provider_id")));
        errdefer provider_id.deinit(allocator);
        var message = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(prompt, "message")));
        errdefer message.deinit(allocator);
        const allow_empty = try fields.optionalBool(prompt, "allow_empty", false);
        return .{ .prompt = .{
            .flow_id = flow_id,
            .prompt_id = prompt_id,
            .provider_id = provider_id,
            .message = message,
            .allow_empty = allow_empty,
        } };
    }

    if (payload.get("progress")) |progress_value| {
        const progress = try fields.asObject(progress_value);
        const flow_id = try parseUlidRequired(try fields.requiredString(progress, "flow_id"));
        var provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(progress, "provider_id")));
        errdefer provider_id.deinit(allocator);
        const message = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(progress, "message")));
        return .{ .progress = .{
            .flow_id = flow_id,
            .provider_id = provider_id,
            .message = message,
        } };
    }

    if (payload.get("success")) |success_value| {
        const success = try fields.asObject(success_value);
        return .{ .success = .{
            .flow_id = try parseUlidRequired(try fields.requiredString(success, "flow_id")),
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(success, "provider_id"))),
        } };
    }

    if (payload.get("error")) |error_value| {
        const event_error = try fields.asObject(error_value);

        const flow_id = try parseUlidRequired(try fields.requiredString(event_error, "flow_id"));
        var provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(event_error, "provider_id")));
        errdefer provider_id.deinit(allocator);
        var message = OwnedSlice(u8).initOwned(try allocator.dupe(u8, try fields.requiredString(event_error, "message")));
        errdefer message.deinit(allocator);

        var code = OwnedSlice(u8).initBorrowed("");
        if (try fields.optionalString(event_error, "code")) |value| {
            code = OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
        }

        return .{ .@"error" = .{
            .flow_id = flow_id,
            .provider_id = provider_id,
            .message = message,
            .code = code,
        } };
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

test "auth envelope rejects missing required root fields" {
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
        \\{"type":"ping","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"payload":{}}
        ,
        \\{"type":"ping","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1}
        ,
    };

    for (cases) |json| {
        try std.testing.expectError(error.MissingField, deserializeEnvelope(json, allocator));
    }
}

test "auth envelope rejects wrong-typed and out-of-range root fields" {
    const allocator = std.testing.allocator;
    const wrong_typed = [_][]const u8{
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
    };
    for (wrong_typed) |json| {
        try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(json, allocator));
    }

    const negative_sequence =
        \\{"type":"ping","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":-1,"timestamp":1,"version":1,"payload":{}}
    ;
    try std.testing.expectError(error.FieldOutOfRange, deserializeEnvelope(negative_sequence, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope("[1,2,3]", allocator));
}

test "auth envelope rejects malformed payload fields without leaking" {
    const allocator = std.testing.allocator;
    const login_missing_provider =
        \\{"type":"auth_login_start","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{}}
    ;
    const prompt_response_missing_answer =
        \\{"type":"auth_prompt_response","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"flow_id":"01M2MYK69FX2M3DY769FEHK3M2","prompt_id":"p"}}
    ;
    const providers_missing_name =
        \\{"type":"auth_providers_response","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"providers":[{"id":"anthropic"}]}}
    ;
    const event_url_wrong_typed =
        \\{"type":"auth_event","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"auth_url":{"flow_id":"01M2MYK69FX2M3DY769FEHK3M2","provider_id":"anthropic","url":7}}}
    ;

    const event_instructions_wrong_typed =
        \\{"type":"auth_event","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"auth_url":{"flow_id":"01M2MYK69FX2M3DY769FEHK3M2","provider_id":"anthropic","url":"https://example.test/login","instructions":7}}}
    ;
    const event_error_code_wrong_typed =
        \\{"type":"auth_event","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"error":{"flow_id":"01M2MYK69FX2M3DY769FEHK3M2","provider_id":"anthropic","message":"denied","code":7}}}
    ;

    try std.testing.expectError(error.MissingField, deserializeEnvelope(login_missing_provider, allocator));
    try std.testing.expectError(error.MissingField, deserializeEnvelope(prompt_response_missing_answer, allocator));
    try std.testing.expectError(error.MissingField, deserializeEnvelope(providers_missing_name, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(event_url_wrong_typed, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(event_instructions_wrong_typed, allocator));
    try std.testing.expectError(error.InvalidFieldType, deserializeEnvelope(event_error_code_wrong_typed, allocator));
}

fn authProvidersResponseProbe(allocator: std.mem.Allocator) !void {
    const json =
        \\{"type":"auth_providers_response","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"providers":[{"id":"anthropic","name":"Anthropic","auth_status":"authenticated","last_error":"none"},{"id":"openai","name":"OpenAI","auth_status":"unknown","last_error":"expired"}]}}
    ;
    var parsed = try deserializeEnvelope(json, allocator);
    parsed.deinit(allocator);
}

test "auth_providers_response survives an allocation failure at every step" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, authProvidersResponseProbe, .{});
}

test "a malformed provider entry after a good one is rejected without leaking" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        \\{"type":"auth_providers_response","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"providers":[{"id":"anthropic","name":"Anthropic","auth_status":"authenticated"},{"id":"openai"}]}}
        ,
        \\{"type":"auth_providers_response","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"providers":[{"id":"anthropic","name":"Anthropic","auth_status":"authenticated"},{"id":"openai","name":7,"auth_status":"unknown"}]}}
        ,
        \\{"type":"auth_providers_response","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"providers":[{"id":"anthropic","name":"Anthropic","auth_status":"authenticated"},{"id":"openai","name":"OpenAI","auth_status":"unknown","last_error":7}]}}
        ,
        \\{"type":"auth_providers_response","stream_id":"01M2MYK69FX2M3DY769FEHK3M0","message_id":"01M2MYK69FX2M3DY769FEHK3M1","sequence":1,"timestamp":1,"version":1,"payload":{"providers":[{"id":"anthropic","name":"Anthropic","auth_status":"authenticated"},7]}}
        ,
    };

    for (cases) |json| {
        try std.testing.expect(std.meta.isError(deserializeEnvelope(json, allocator)));
    }
}
