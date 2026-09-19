const std = @import("std");
const compat = @import("compat");
const json_writer = @import("json_writer");
const agent_types = @import("agent_types");
const agent_envelope = @import("agent_envelope");
const OwnedSlice = @import("owned_slice").OwnedSlice;
const oap_types = @import("oap_types");
const oap_server = @import("oap_server");

pub const Server = oap_server.Server;

const Evidence = struct {
    text: []const u8,
    stop_reason: []const u8,
    usage: oap_types.Usage,

    fn deinit(self: *Evidence, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.stop_reason);
    }
};

const NativeSession = struct {
    native_id: agent_types.SessionId,
    next_sequence: u64,
    started: bool,
    evidence: ?Evidence,

    fn deinit(self: *NativeSession, allocator: std.mem.Allocator) void {
        if (self.evidence) |*evidence| evidence.deinit(allocator);
    }
};

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(NativeSession),
    reverse: std.StringHashMap([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(NativeSession).init(allocator),
            .reverse = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.sessions.deinit();

        var reverse_iterator = self.reverse.iterator();
        while (reverse_iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.reverse.deinit();

        self.* = undefined;
    }

    pub fn oapSessionFor(self: *Self, native_id: agent_types.SessionId) ?[]const u8 {
        return self.reverse.get(native_id[0..]);
    }

    fn ensureSession(self: *Self, oap_session_id: []const u8) !*NativeSession {
        if (self.sessions.getPtr(oap_session_id)) |existing| return existing;

        const native_id = agent_types.generateSessionId();
        const key = try self.allocator.dupe(u8, oap_session_id);
        errdefer self.allocator.free(key);
        const reverse_key = try self.allocator.dupe(u8, native_id[0..]);
        errdefer self.allocator.free(reverse_key);

        try self.sessions.put(key, .{
            .native_id = native_id,
            .next_sequence = 1,
            .started = false,
            .evidence = null,
        });
        errdefer _ = self.sessions.remove(key);

        const stored_key = self.sessions.getKeyPtr(key).?.*;
        try self.reverse.put(reverse_key, stored_key);

        return self.sessions.getPtr(key).?;
    }

    pub fn appendSubmissionLines(
        self: *Self,
        pending: oap_server.PendingSubmission,
        out: *std.ArrayList([]const u8),
    ) !void {
        const session = try self.ensureSession(pending.session_id);

        if (!session.started) {
            const config_json = try buildConfigJson(self.allocator, pending.model_id);
            defer self.allocator.free(config_json);
            const line = try self.serializeNative(session.native_id, session.next_sequence, .{
                .agent_start = .{
                    .config_json = config_json,
                    .session_id = session.native_id,
                },
            });
            errdefer self.allocator.free(line);
            try out.append(self.allocator, line);
            session.next_sequence += 1;
            session.started = true;
        }

        const message_json = try buildMessageJson(self.allocator, pending);
        defer self.allocator.free(message_json);
        const line = try self.serializeNative(session.native_id, session.next_sequence, .{
            .agent_message = .{
                .session_id = session.native_id,
                .message_json = message_json,
            },
        });
        errdefer self.allocator.free(line);
        try out.append(self.allocator, line);
        session.next_sequence += 1;
    }

    pub fn cancelLine(self: *Self, pending: oap_server.PendingCancel) !?[]const u8 {
        const session = self.sessions.getPtr(pending.session_id) orelse return null;
        if (!session.started) return null;
        const reason = pending.reason orelse "cancelled by the control layer";
        const line = try self.serializeNative(session.native_id, session.next_sequence, .{
            .agent_stop = .{
                .session_id = session.native_id,
                .reason = OwnedSlice(u8).initBorrowed(reason),
            },
        });
        session.next_sequence += 1;
        return line;
    }

    fn serializeNative(
        self: *Self,
        session_id: agent_types.SessionId,
        sequence: u64,
        payload: agent_types.Payload,
    ) ![]const u8 {
        const env = agent_types.Envelope{
            .session_id = session_id,
            .message_id = agent_types.generateUlid(),
            .sequence = sequence,
            .timestamp = compat.time.nowMillis(),
            .payload = payload,
        };
        return agent_envelope.serializeEnvelope(env, self.allocator);
    }

    pub fn applyNativeLine(self: *Self, server: *Server, line: []const u8) !void {
        if (!self.nativeEnvelopeIsAddressable(line)) return;

        var env = agent_envelope.deserializeEnvelope(line, self.allocator) catch return;
        defer env.deinit(self.allocator);

        const oap_session_id = self.reverse.get(env.session_id[0..]) orelse return;

        switch (env.payload) {
            .agent_event => |event_json| try self.applyAgentEvent(server, oap_session_id, event_json),
            .agent_result => |result_json| try self.retainResultEvidence(oap_session_id, result_json),
            .agent_error => |payload| {
                const mapped = mapNativeErrorCode(payload.code);
                try server.settleFailed(oap_session_id, mapped, payload.message);
                if (mapped == .session_not_found) self.forgetSession(oap_session_id);
            },
            .agent_stopped => try server.settleCancelled(oap_session_id, null),
            else => {},
        }
    }

    fn nativeEnvelopeIsAddressable(self: *Self, line: []const u8) bool {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const root = parsed.value.object;

        const type_value = root.get("type") orelse return false;
        if (type_value != .string) return false;
        const session_value = root.get("session_id") orelse return false;
        if (session_value != .string) return false;
        if (agent_types.parseSessionId(session_value.string) == null) return false;
        const message_value = root.get("message_id") orelse return false;
        if (message_value != .string) return false;
        if (agent_types.parseUlid(message_value.string) == null) return false;
        const payload_value = root.get("payload") orelse return false;
        if (payload_value != .object) return false;

        for ([_][]const u8{ "sequence", "timestamp", "version" }) |key| {
            const value = root.get(key) orelse return false;
            if (value != .integer) return false;
        }
        if (root.get("in_reply_to")) |value| {
            if (value != .string) return false;
            if (agent_types.parseUlid(value.string) == null) return false;
        }
        return true;
    }

    fn retainResultEvidence(self: *Self, oap_session_id: []const u8, result_json: []const u8) !void {
        const session = self.sessions.getPtr(oap_session_id) orelse return;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const root = parsed.value.object;

        const text = try collectResultText(self.allocator, root);
        errdefer self.allocator.free(text);
        const stop_reason = try self.allocator.dupe(u8, stringField(root, "stop_reason") orelse "end_turn");

        if (session.evidence) |*existing| existing.deinit(self.allocator);
        session.evidence = .{
            .text = text,
            .stop_reason = stop_reason,
            .usage = usageFromResult(root),
        };
    }

    fn applyAgentEvent(
        self: *Self,
        server: *Server,
        oap_session_id: []const u8,
        event_json: []const u8,
    ) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, event_json, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const root = parsed.value.object;
        const event_type = stringField(root, "type") orelse return;

        if (std.mem.eql(u8, event_type, "message_update")) {
            const inner = root.get("event") orelse return;
            if (inner != .object) return;
            const inner_type = stringField(inner.object, "type") orelse return;
            const delta = stringField(inner.object, "delta") orelse return;
            if (std.mem.eql(u8, inner_type, "text_delta")) {
                try server.noteContent(oap_session_id, .{ .text = delta });
            } else if (std.mem.eql(u8, inner_type, "thinking_delta")) {
                try server.noteContent(oap_session_id, .{ .reasoning = .{ .text = delta } });
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "message_end")) {
            server.noteMessageBoundary(oap_session_id);
            return;
        }

        if (std.mem.eql(u8, event_type, "error")) {
            const message = stringField(root, "message") orelse "the agent loop failed";
            const code = if (stringField(root, "code")) |text|
                mapNativeErrorName(text)
            else
                oap_types.ErrorCode.internal_error;
            try server.settleFailed(oap_session_id, code, message);
            return;
        }

        if (std.mem.eql(u8, event_type, "agent_end")) {
            try self.settleFromEvidence(server, oap_session_id, stringField(root, "stop_reason"));
            return;
        }
    }

    fn settleFromEvidence(
        self: *Self,
        server: *Server,
        oap_session_id: []const u8,
        event_stop_reason: ?[]const u8,
    ) !void {
        const session = self.sessions.getPtr(oap_session_id) orelse return;
        const evidence = session.evidence;

        const stop_reason = blk: {
            if (evidence) |value| break :blk value.stop_reason;
            break :blk event_stop_reason orelse "end_turn";
        };

        if (std.mem.eql(u8, stop_reason, "cancelled")) {
            try server.settleCancelled(oap_session_id, "the native agent loop reported cancellation");
        } else if (std.mem.eql(u8, stop_reason, "error")) {
            const message = if (evidence) |value| value.text else "the agent loop ended in an error state";
            try server.settleFailed(oap_session_id, .provider_error, message);
        } else {
            if (evidence) |value| server.noteUsage(oap_session_id, value.usage);
            const text = if (evidence) |value| value.text else "";
            try server.settleCompleted(oap_session_id, text, stop_reason);
        }

        if (session.evidence) |*retained| retained.deinit(self.allocator);
        session.evidence = null;
    }

    pub fn forgetSession(self: *Self, oap_session_id: []const u8) void {
        const kv = self.sessions.fetchRemove(oap_session_id) orelse return;
        if (self.reverse.fetchRemove(kv.value.native_id[0..])) |reverse_kv| {
            self.allocator.free(reverse_kv.key);
        }
        var value = kv.value;
        value.deinit(self.allocator);
        self.allocator.free(kv.key);
    }

    pub fn failUnmappedActiveRuns(self: *Self, server: *Server, message: []const u8) !bool {
        var ids = std.ArrayList([]const u8).empty;
        defer ids.deinit(self.allocator);
        try server.appendActiveRunSessionIds(self.allocator, &ids);

        var settled_any = false;
        for (ids.items) |session_id| {
            if (self.sessions.contains(session_id)) continue;
            try server.settleFailed(session_id, .internal_error, message);
            settled_any = true;
        }
        return settled_any;
    }

    pub fn failActiveRuns(self: *Self, server: *Server, message: []const u8) !void {
        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            try server.settleFailed(entry.key_ptr.*, .internal_error, message);
        }
    }
};

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn unsignedField(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = obj.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn usageFromResult(root: std.json.ObjectMap) oap_types.Usage {
    const input = unsignedField(root, "input");
    const output = unsignedField(root, "output");
    if (input == null and output == null) return .{};
    const total = (input orelse 0) + (output orelse 0);
    return .{ .input_tokens = input, .output_tokens = output, .total_tokens = total };
}

fn collectResultText(allocator: std.mem.Allocator, root: std.json.ObjectMap) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    if (root.get("content")) |content| {
        if (content == .array) {
            for (content.array.items) |item| {
                if (item != .object) continue;
                const part_type = stringField(item.object, "type") orelse continue;
                if (!std.mem.eql(u8, part_type, "text")) continue;
                const text = stringField(item.object, "text") orelse continue;
                try buffer.appendSlice(allocator, text);
            }
        }
    }

    if (buffer.items.len == 0) {
        if (stringField(root, "error_message")) |message| {
            try buffer.appendSlice(allocator, message);
        }
    }

    const out = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return out;
}

pub fn mapNativeErrorCode(code: agent_types.AgentErrorCode) oap_types.ErrorCode {
    return switch (code) {
        .invalid_request => .invalid_request,
        .agent_not_found, .session_expired => .session_not_found,
        .agent_busy => .session_busy,
        .tool_not_found, .tool_execution_error => .provider_error,
        .context_overflow, .rate_limited, .auth_required => .provider_error,
        .internal_error => .internal_error,
    };
}

fn mapNativeErrorName(name: []const u8) oap_types.ErrorCode {
    const code = std.meta.stringToEnum(agent_types.AgentErrorCode, name) orelse return .internal_error;
    return mapNativeErrorCode(code);
}

fn buildConfigJson(allocator: std.mem.Allocator, model_ref: []const u8) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);
    try w.beginObject();
    try w.writeStringField("model_ref", model_ref);
    try w.writeKey("tools");
    try w.beginArray();
    try w.endArray();
    try w.endObject();
    const out = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return out;
}

fn buildMessageJson(allocator: std.mem.Allocator, pending: oap_server.PendingSubmission) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);

    try w.beginObject();
    try w.writeStringField("model_ref", pending.model_id);
    try w.writeKey("messages");
    try w.beginArray();
    for (pending.messages) |message| {
        try w.beginObject();
        try w.writeStringField("role", @tagName(message.role));
        try w.writeKey("content");
        switch (message.content) {
            .text => |text| try w.writeString(text),
            .parts => |parts| {
                try w.beginArray();
                for (parts) |part| {
                    switch (part) {
                        .text => |text| {
                            try w.beginObject();
                            try w.writeStringField("type", "text");
                            try w.writeStringField("text", text);
                            try w.endObject();
                        },
                        else => {},
                    }
                }
                try w.endArray();
            },
        }
        try w.endObject();
    }
    try w.endArray();
    try w.writeKey("tools");
    try w.beginArray();
    try w.endArray();
    try w.endObject();

    const out = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return out;
}

const testing = std.testing;

fn nextOap(server: *Server, allocator: std.mem.Allocator) !oap_types.Envelope {
    const line = server.popOutbound() orelse return error.NoOutboundFrame;
    defer allocator.free(line);
    return @import("oap_envelope").deserializeEnvelope(line, allocator);
}

fn drainOap(server: *Server, allocator: std.mem.Allocator) void {
    while (server.popOutbound()) |line| allocator.free(line);
}

fn freeLines(allocator: std.mem.Allocator, lines: *std.ArrayList([]const u8)) void {
    for (lines.items) |line| allocator.free(line);
    lines.deinit(allocator);
}

fn nativeLine(
    allocator: std.mem.Allocator,
    session_id: agent_types.SessionId,
    payload: agent_types.Payload,
) ![]const u8 {
    const env = agent_types.Envelope{
        .session_id = session_id,
        .message_id = agent_types.generateUlid(),
        .sequence = 1,
        .timestamp = 0,
        .payload = payload,
    };
    return agent_envelope.serializeEnvelope(env, allocator);
}

fn feedNative(
    bridge: *Bridge,
    server: *Server,
    allocator: std.mem.Allocator,
    session_id: agent_types.SessionId,
    payload_in: agent_types.Payload,
) !void {
    var payload = payload_in;
    defer payload.deinit(allocator);
    const line = try nativeLine(allocator, session_id, payload);
    defer allocator.free(line);
    try bridge.applyNativeLine(server, line);
}

const Fixture = struct {
    server: Server,
    bridge: Bridge,
    native_id: agent_types.SessionId,

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.bridge.deinit();
        self.server.deinit();
    }
};

fn startFixture(allocator: std.mem.Allocator, oap_session_id: []const u8) !Fixture {
    var server = try Server.init(allocator, .{ .default_model_id = "anthropic/anthropic-messages@claude" });
    errdefer server.deinit();
    var bridge = Bridge.init(allocator);
    errdefer bridge.deinit();

    try server.handleEnvelope(.{
        .id = "open-1",
        .payload = .{ .session_open_request = .{ .session_id = oap_session_id } },
    });
    drainOap(&server, allocator);

    var parts = [_]oap_types.ContentPart{.{ .text = "go" }};
    var messages = [_]oap_types.Message{.{ .role = .user, .content = .{ .parts = &parts } }};
    try server.handleEnvelope(.{
        .id = "submit-1",
        .session_id = oap_session_id,
        .payload = .{ .message_submit_request = .{
            .session_id = oap_session_id,
            .messages = &messages,
            .delivery = .auto,
        } },
    });
    drainOap(&server, allocator);

    var pending = server.popPendingSubmission().?;
    defer pending.deinit(allocator);

    var lines = std.ArrayList([]const u8).empty;
    defer freeLines(allocator, &lines);
    try bridge.appendSubmissionLines(pending, &lines);

    const native_id = bridge.sessions.getPtr(oap_session_id).?.native_id;
    return .{ .server = server, .bridge = bridge, .native_id = native_id };
}

test "a submission becomes a native agent_start and agent_message pair" {
    const allocator = testing.allocator;
    var server = try Server.init(allocator, .{ .default_model_id = "ollama/ollama@gemma" });
    defer server.deinit();
    var bridge = Bridge.init(allocator);
    defer bridge.deinit();

    try server.handleEnvelope(.{
        .id = "open-1",
        .payload = .{ .session_open_request = .{ .session_id = "oap-session-key" } },
    });
    drainOap(&server, allocator);

    var parts = [_]oap_types.ContentPart{.{ .text = "hello there" }};
    var messages = [_]oap_types.Message{.{ .role = .user, .content = .{ .parts = &parts } }};
    try server.handleEnvelope(.{
        .id = "submit-1",
        .session_id = "oap-session-key",
        .payload = .{ .message_submit_request = .{
            .session_id = "oap-session-key",
            .messages = &messages,
            .delivery = .auto,
        } },
    });
    drainOap(&server, allocator);

    var pending = server.popPendingSubmission().?;
    defer pending.deinit(allocator);

    var lines = std.ArrayList([]const u8).empty;
    defer freeLines(allocator, &lines);
    try bridge.appendSubmissionLines(pending, &lines);
    try testing.expectEqual(@as(usize, 2), lines.items.len);

    var start = try agent_envelope.deserializeEnvelope(lines.items[0], allocator);
    defer start.deinit(allocator);
    try testing.expectEqual(@as(u64, 1), start.sequence);
    try testing.expect(std.mem.indexOf(u8, start.payload.agent_start.config_json, "ollama/ollama@gemma") != null);

    var message = try agent_envelope.deserializeEnvelope(lines.items[1], allocator);
    defer message.deinit(allocator);
    try testing.expectEqual(@as(u64, 2), message.sequence);
    const body = message.payload.agent_message.message_json;
    try testing.expect(std.mem.indexOf(u8, body, "hello there") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"model_ref\":\"ollama/ollama@gemma\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);

    try testing.expect(!std.mem.eql(u8, start.session_id[0..], "oap-session-key"));
    try testing.expectEqual(@as(usize, 21), start.session_id.len);
    try testing.expectEqualStrings("oap-session-key", bridge.oapSessionFor(start.session_id).?);
}

test "a second submission reuses the native session and advances its sequence" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "oap-session-key");
    defer fixture.deinit(allocator);

    try fixture.server.settleCompleted("oap-session-key", "first", "end_turn");
    drainOap(&fixture.server, allocator);

    var parts = [_]oap_types.ContentPart{.{ .text = "again" }};
    var messages = [_]oap_types.Message{.{ .role = .user, .content = .{ .parts = &parts } }};
    try fixture.server.handleEnvelope(.{
        .id = "submit-2",
        .session_id = "oap-session-key",
        .payload = .{ .message_submit_request = .{
            .session_id = "oap-session-key",
            .messages = &messages,
            .delivery = .auto,
        } },
    });
    drainOap(&fixture.server, allocator);

    var pending = fixture.server.popPendingSubmission().?;
    defer pending.deinit(allocator);

    var lines = std.ArrayList([]const u8).empty;
    defer freeLines(allocator, &lines);
    try fixture.bridge.appendSubmissionLines(pending, &lines);

    try testing.expectEqual(@as(usize, 1), lines.items.len);
    var message = try agent_envelope.deserializeEnvelope(lines.items[0], allocator);
    defer message.deinit(allocator);
    try testing.expectEqual(@as(u64, 3), message.sequence);
    try testing.expectEqualStrings(fixture.native_id[0..], message.session_id[0..]);
}

test "native text and thinking deltas become portable content parts" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "oap-session-key");
    defer fixture.deinit(allocator);

    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_event = try allocator.dupe(
            u8,
            "{\"type\":\"message_update\",\"event\":{\"type\":\"text_delta\",\"content_index\":0,\"delta\":\"par\"}}",
        ),
    });
    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_event = try allocator.dupe(
            u8,
            "{\"type\":\"message_update\",\"event\":{\"type\":\"thinking_delta\",\"content_index\":0,\"delta\":\"hmm\"}}",
        ),
    });

    var text = try nextOap(&fixture.server, allocator);
    defer text.deinit(allocator);
    try testing.expectEqualStrings("par", text.payload.content_delta.part.text);
    try testing.expectEqual(@as(u64, 2), text.sequence.?);

    var reasoning = try nextOap(&fixture.server, allocator);
    defer reasoning.deinit(allocator);
    try testing.expectEqualStrings("hmm", reasoning.payload.content_delta.part.reasoning.text);
    try testing.expectEqual(@as(u64, 3), reasoning.sequence.?);
}

test "a native result is retained as evidence and settles only on agent_end" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "oap-session-key");
    defer fixture.deinit(allocator);

    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_result = try allocator.dupe(
            u8,
            "{\"type\":\"result\",\"stop_reason\":\"end_turn\",\"model\":\"m\",\"api\":\"a\",\"provider\":\"p\"," ++
                "\"timestamp\":0,\"input\":11,\"output\":7,\"cache_read\":0,\"cache_write\":0," ++
                "\"content\":[{\"type\":\"text\",\"text\":\"the answer\"}]}",
        ),
    });
    try testing.expect(fixture.server.popOutbound() == null);

    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_event = try allocator.dupe(u8, "{\"type\":\"agent_end\",\"stop_reason\":\"end_turn\"}"),
    });

    var completed = try nextOap(&fixture.server, allocator);
    defer completed.deinit(allocator);
    const payload = completed.payload.run_completed;
    try testing.expectEqualStrings("the answer", payload.final_response.content.text);
    try testing.expectEqualStrings("end_turn", payload.stop_reason);
    try testing.expectEqual(@as(u64, 11), payload.usage.input_tokens.?);
    try testing.expectEqual(@as(u64, 7), payload.usage.output_tokens.?);
    try testing.expectEqual(@as(u64, 18), payload.usage.total_tokens.?);
    try testing.expectEqual(@as(u64, 2), completed.sequence.?);

    var state = try nextOap(&fixture.server, allocator);
    defer state.deinit(allocator);
    try testing.expectEqual(oap_types.SessionStatus.idle, state.payload.session_state_updated.status);
    try testing.expect(fixture.server.popOutbound() == null);
}

test "a trailing native terminal after settlement is suppressed" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "oap-session-key");
    defer fixture.deinit(allocator);

    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_event = try allocator.dupe(u8, "{\"type\":\"agent_end\",\"stop_reason\":\"end_turn\"}"),
    });
    drainOap(&fixture.server, allocator);

    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_event = try allocator.dupe(u8, "{\"type\":\"agent_end\",\"stop_reason\":\"end_turn\"}"),
    });
    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_error = .{ .code = .internal_error, .message = try allocator.dupe(u8, "late") },
    });
    try testing.expect(fixture.server.popOutbound() == null);
}

test "a native error event settles the run as a typed failure" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "oap-session-key");
    defer fixture.deinit(allocator);

    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_event = try allocator.dupe(
            u8,
            "{\"type\":\"error\",\"message\":\"upstream refused\",\"code\":\"rate_limited\"}",
        ),
    });

    var failed = try nextOap(&fixture.server, allocator);
    defer failed.deinit(allocator);
    try testing.expectEqual(oap_types.ErrorCode.provider_error, failed.payload.run_failed.err.code);
    try testing.expectEqualStrings("upstream refused", failed.payload.run_failed.err.message);
}

test "a correlated native agent_error settles the run as a failure" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "oap-session-key");
    defer fixture.deinit(allocator);

    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_error = .{
            .code = .agent_not_found,
            .message = try allocator.dupe(u8, "session not found"),
        },
    });

    var failed = try nextOap(&fixture.server, allocator);
    defer failed.deinit(allocator);
    try testing.expectEqual(oap_types.ErrorCode.session_not_found, failed.payload.run_failed.err.code);
}

test "a native agent_end reporting cancellation settles as cancelled behind an accepted intent" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "oap-session-key");
    defer fixture.deinit(allocator);

    const run_id = try allocator.dupe(u8, fixture.server.activeRunId("oap-session-key").?);
    defer allocator.free(run_id);
    try fixture.server.handleEnvelope(.{
        .id = "cancel-1",
        .session_id = "oap-session-key",
        .run_id = run_id,
        .payload = .{ .run_cancel_request = .{ .session_id = "oap-session-key", .run_id = run_id } },
    });
    drainOap(&fixture.server, allocator);

    var pending = fixture.server.popPendingCancel().?;
    defer pending.deinit(allocator);
    const stop_line = (try fixture.bridge.cancelLine(pending)).?;
    defer allocator.free(stop_line);
    var stop_env = try agent_envelope.deserializeEnvelope(stop_line, allocator);
    defer stop_env.deinit(allocator);
    try testing.expectEqualStrings(fixture.native_id[0..], stop_env.payload.agent_stop.session_id[0..]);
    try testing.expectEqual(@as(u64, 3), stop_env.sequence);

    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_event = try allocator.dupe(u8, "{\"type\":\"agent_end\",\"stop_reason\":\"cancelled\"}"),
    });

    var cancelled = try nextOap(&fixture.server, allocator);
    defer cancelled.deinit(allocator);
    try testing.expectEqual(oap_types.Payload.run_cancelled, std.meta.activeTag(cancelled.payload));
}

test "a native agent_stopped settles cancellation when no earlier terminal won" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "oap-session-key");
    defer fixture.deinit(allocator);

    const run_id = try allocator.dupe(u8, fixture.server.activeRunId("oap-session-key").?);
    defer allocator.free(run_id);
    try fixture.server.handleEnvelope(.{
        .id = "cancel-1",
        .session_id = "oap-session-key",
        .run_id = run_id,
        .payload = .{ .run_cancel_request = .{ .session_id = "oap-session-key", .run_id = run_id } },
    });
    drainOap(&fixture.server, allocator);
    var pending = fixture.server.popPendingCancel().?;
    defer pending.deinit(allocator);

    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_stopped = .{ .session_id = fixture.native_id },
    });

    var cancelled = try nextOap(&fixture.server, allocator);
    defer cancelled.deinit(allocator);
    try testing.expectEqual(oap_types.Payload.run_cancelled, std.meta.activeTag(cancelled.payload));

    var closed = try nextOap(&fixture.server, allocator);
    defer closed.deinit(allocator);
    try testing.expectEqual(oap_types.SessionStatus.closed, closed.payload.session_state_updated.status);
}

test "a native stop with no accepted cancellation settles as a failure, not a cancellation" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "oap-session-key");
    defer fixture.deinit(allocator);

    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_stopped = .{ .session_id = fixture.native_id },
    });

    var terminal = try nextOap(&fixture.server, allocator);
    defer terminal.deinit(allocator);
    try testing.expectEqual(oap_types.Payload.run_failed, std.meta.activeTag(terminal.payload));
}

test "native frames for an unmapped session are ignored" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "oap-session-key");
    defer fixture.deinit(allocator);

    const stranger = agent_types.generateSessionId();
    try feedNative(&fixture.bridge, &fixture.server, allocator, stranger, .{
        .agent_event = try allocator.dupe(u8, "{\"type\":\"agent_end\",\"stop_reason\":\"end_turn\"}"),
    });
    try testing.expect(fixture.server.popOutbound() == null);
    try testing.expect(fixture.server.hasActiveRun());
}

test "a malformed native line never disturbs the portable run" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "oap-session-key");
    defer fixture.deinit(allocator);

    try fixture.bridge.applyNativeLine(&fixture.server, "not a frame");
    try fixture.bridge.applyNativeLine(&fixture.server, "{\"type\":\"agent_event\"}");
    try testing.expect(fixture.server.popOutbound() == null);
    try testing.expect(fixture.server.hasActiveRun());
}

test "a message boundary event closes the portable assistant message" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "oap-session-key");
    defer fixture.deinit(allocator);

    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_event = try allocator.dupe(
            u8,
            "{\"type\":\"message_update\",\"event\":{\"type\":\"text_delta\",\"content_index\":0,\"delta\":\"a\"}}",
        ),
    });
    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_event = try allocator.dupe(u8, "{\"type\":\"message_end\",\"stop_reason\":\"tool_use\"}"),
    });
    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_event = try allocator.dupe(
            u8,
            "{\"type\":\"message_update\",\"event\":{\"type\":\"text_delta\",\"content_index\":0,\"delta\":\"b\"}}",
        ),
    });

    var first = try nextOap(&fixture.server, allocator);
    defer first.deinit(allocator);
    var second = try nextOap(&fixture.server, allocator);
    defer second.deinit(allocator);
    try testing.expect(!std.mem.eql(
        u8,
        first.payload.content_delta.message_id.?,
        second.payload.content_delta.message_id.?,
    ));
}

test "end of input leaves a dispatched run alone and settles an undispatched one" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "oap-session-key");
    defer fixture.deinit(allocator);

    try testing.expect(fixture.server.hasActiveRun());
    try testing.expect(!try fixture.bridge.failUnmappedActiveRuns(
        &fixture.server,
        "the makai host reached end of input before the run settled",
    ));
    try testing.expect(fixture.server.popOutbound() == null);
    try testing.expect(fixture.server.hasActiveRun());

    try fixture.server.handleEnvelope(.{
        .id = "open-2",
        .payload = .{ .session_open_request = .{ .session_id = "oap-session-stuck" } },
    });
    var parts = [_]oap_types.ContentPart{.{ .text = "go" }};
    var messages = [_]oap_types.Message{.{ .role = .user, .content = .{ .parts = &parts } }};
    try fixture.server.handleEnvelope(.{
        .id = "submit-2",
        .session_id = "oap-session-stuck",
        .payload = .{ .message_submit_request = .{
            .session_id = "oap-session-stuck",
            .messages = &messages,
            .delivery = .auto,
        } },
    });
    drainOap(&fixture.server, allocator);
    var pending = fixture.server.popPendingSubmission().?;
    pending.deinit(allocator);

    try testing.expect(try fixture.bridge.failUnmappedActiveRuns(
        &fixture.server,
        "the makai host reached end of input before the run settled",
    ));

    var failed = try nextOap(&fixture.server, allocator);
    defer failed.deinit(allocator);
    try testing.expectEqual(oap_types.Payload.run_failed, std.meta.activeTag(failed.payload));
    try testing.expectEqualStrings("oap-session-stuck", failed.payload.run_failed.session_id);
    drainOap(&fixture.server, allocator);

    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_event = try allocator.dupe(u8, "{\"type\":\"agent_end\",\"stop_reason\":\"end_turn\"}"),
    });
    var completed = try nextOap(&fixture.server, allocator);
    defer completed.deinit(allocator);
    try testing.expectEqual(oap_types.Payload.run_completed, std.meta.activeTag(completed.payload));
    try testing.expectEqualStrings("oap-session-key", completed.payload.run_completed.session_id);
}

test "a transport failure settles every active run with one terminal" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "oap-session-key");
    defer fixture.deinit(allocator);

    try fixture.bridge.failActiveRuns(&fixture.server, "the makai host exited before the run settled");

    var failed = try nextOap(&fixture.server, allocator);
    defer failed.deinit(allocator);
    try testing.expectEqual(oap_types.Payload.run_failed, std.meta.activeTag(failed.payload));
    try testing.expectEqualStrings(
        "the makai host exited before the run settled",
        failed.payload.run_failed.err.message,
    );

    drainOap(&fixture.server, allocator);
    try fixture.bridge.failActiveRuns(&fixture.server, "again");
    try testing.expect(fixture.server.popOutbound() == null);
}

test "an agent_end that reports an error state settles as a failure" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "oap-session-key");
    defer fixture.deinit(allocator);

    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_result = try allocator.dupe(
            u8,
            "{\"type\":\"result\",\"stop_reason\":\"error\",\"model\":\"m\",\"api\":\"a\",\"provider\":\"p\"," ++
                "\"timestamp\":0,\"input\":0,\"output\":0,\"cache_read\":0,\"cache_write\":0," ++
                "\"content\":[],\"error_message\":\"the provider rejected the request\"}",
        ),
    });
    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_event = try allocator.dupe(u8, "{\"type\":\"agent_end\",\"stop_reason\":\"error\"}"),
    });

    var failed = try nextOap(&fixture.server, allocator);
    defer failed.deinit(allocator);
    try testing.expectEqual(oap_types.ErrorCode.provider_error, failed.payload.run_failed.err.code);
    try testing.expectEqualStrings("the provider rejected the request", failed.payload.run_failed.err.message);
}

test "a max turns termination is a completion with that stop reason" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "oap-session-key");
    defer fixture.deinit(allocator);

    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_result = try allocator.dupe(
            u8,
            "{\"type\":\"result\",\"stop_reason\":\"max_turns\",\"model\":\"m\",\"api\":\"a\",\"provider\":\"p\"," ++
                "\"timestamp\":0,\"input\":1,\"output\":1,\"cache_read\":0,\"cache_write\":0," ++
                "\"content\":[{\"type\":\"text\",\"text\":\"partial\"}]}",
        ),
    });
    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_event = try allocator.dupe(u8, "{\"type\":\"agent_end\",\"stop_reason\":\"max_turns\"}"),
    });

    var completed = try nextOap(&fixture.server, allocator);
    defer completed.deinit(allocator);
    try testing.expectEqualStrings("max_turns", completed.payload.run_completed.stop_reason);
    try testing.expectEqualStrings("partial", completed.payload.run_completed.final_response.content.text);
}

const GoldenFrame = struct {
    type_name: []const u8,
    sequence: ?u64,
    correlated: bool,
};

fn expectGoldenTrace(
    server: *Server,
    allocator: std.mem.Allocator,
    expected: []const GoldenFrame,
) !void {
    for (expected, 0..) |want, index| {
        var got = nextOap(server, allocator) catch |err| {
            std.debug.print("missing frame {d}, wanted {s}\n", .{ index, want.type_name });
            return err;
        };
        defer got.deinit(allocator);

        if (!std.mem.eql(u8, want.type_name, got.payload.typeName())) {
            std.debug.print(
                "frame {d}: wanted {s}, got {s}\n",
                .{ index, want.type_name, got.payload.typeName() },
            );
            return error.UnexpectedFrameType;
        }
        try testing.expectEqual(want.sequence, got.sequence);
        try testing.expectEqual(want.correlated, got.in_reply_to != null);
    }
    try testing.expect(server.popOutbound() == null);
}

test "the completed conversation matches the trace validated by the oap reference validator" {
    const allocator = testing.allocator;
    var server = try Server.init(allocator, .{
        .endpoint_version = "test",
        .default_model_id = "anthropic/anthropic-messages@mock-model",
    });
    defer server.deinit();
    var bridge = Bridge.init(allocator);
    defer bridge.deinit();

    const versions = [_][]const u8{oap_types.VERSION};
    const profiles = [_][]const u8{oap_types.PROFILE};
    try server.handleEnvelope(.{
        .id = "req-init",
        .payload = .{ .initialize_request = .{ .protocol_versions = &versions, .profiles = &profiles } },
    });
    try server.handleEnvelope(.{ .id = "req-cap", .payload = .{ .capabilities_request = {} } });
    try server.handleEnvelope(.{
        .id = "req-open",
        .payload = .{ .session_open_request = .{ .session_id = "smokesessionkey000001" } },
    });
    try server.handleEnvelope(.{
        .id = "req-state",
        .session_id = "smokesessionkey000001",
        .payload = .{ .session_state_request = .{ .session_id = "smokesessionkey000001" } },
    });

    var parts = [_]oap_types.ContentPart{.{ .text = "say hello" }};
    var messages = [_]oap_types.Message{.{ .role = .user, .content = .{ .parts = &parts } }};
    try server.handleEnvelope(.{
        .id = "req-submit",
        .session_id = "smokesessionkey000001",
        .payload = .{ .message_submit_request = .{
            .session_id = "smokesessionkey000001",
            .messages = &messages,
            .delivery = .auto,
        } },
    });

    var pending = server.popPendingSubmission().?;
    defer pending.deinit(allocator);
    var lines = std.ArrayList([]const u8).empty;
    defer freeLines(allocator, &lines);
    try bridge.appendSubmissionLines(pending, &lines);
    const native_id = bridge.sessions.getPtr("smokesessionkey000001").?.native_id;

    try feedNative(&bridge, &server, allocator, native_id, .{
        .agent_event = try allocator.dupe(
            u8,
            "{\"type\":\"message_update\",\"event\":{\"type\":\"text_delta\",\"content_index\":0,\"delta\":\"Hello\"}}",
        ),
    });
    try feedNative(&bridge, &server, allocator, native_id, .{
        .agent_event = try allocator.dupe(
            u8,
            "{\"type\":\"message_update\",\"event\":{\"type\":\"text_delta\",\"content_index\":0,\"delta\":\" from the mock.\"}}",
        ),
    });
    try feedNative(&bridge, &server, allocator, native_id, .{
        .agent_result = try allocator.dupe(
            u8,
            "{\"type\":\"result\",\"stop_reason\":\"stop\",\"model\":\"mock-model\",\"api\":\"anthropic-messages\"," ++
                "\"provider\":\"anthropic\",\"timestamp\":0,\"input\":11,\"output\":7,\"cache_read\":0,\"cache_write\":0," ++
                "\"content\":[{\"type\":\"text\",\"text\":\"Hello from the mock.\"}]}",
        ),
    });
    try feedNative(&bridge, &server, allocator, native_id, .{
        .agent_event = try allocator.dupe(u8, "{\"type\":\"agent_end\",\"stop_reason\":\"stop\"}"),
    });

    try expectGoldenTrace(&server, allocator, &[_]GoldenFrame{
        .{ .type_name = "protocol.initialize.response", .sequence = null, .correlated = true },
        .{ .type_name = "capabilities.response", .sequence = null, .correlated = true },
        .{ .type_name = "session.open.response", .sequence = null, .correlated = true },
        .{ .type_name = "session.state.response", .sequence = null, .correlated = true },
        .{ .type_name = "session.message.submit.response", .sequence = null, .correlated = true },
        .{ .type_name = "run.started", .sequence = 1, .correlated = false },
        .{ .type_name = "session.state.updated", .sequence = 1, .correlated = false },
        .{ .type_name = "content.delta", .sequence = 2, .correlated = false },
        .{ .type_name = "content.delta", .sequence = 3, .correlated = false },
        .{ .type_name = "run.completed", .sequence = 4, .correlated = false },
        .{ .type_name = "session.state.updated", .sequence = 2, .correlated = false },
    });
}

test "the cancelled conversation matches the trace validated by the oap reference validator" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "cancelsessionkey00001");
    defer fixture.deinit(allocator);
    drainOap(&fixture.server, allocator);

    const run_id = try allocator.dupe(u8, fixture.server.activeRunId("cancelsessionkey00001").?);
    defer allocator.free(run_id);
    try fixture.server.handleEnvelope(.{
        .id = "req-cancel",
        .session_id = "cancelsessionkey00001",
        .run_id = run_id,
        .payload = .{ .run_cancel_request = .{
            .session_id = "cancelsessionkey00001",
            .run_id = run_id,
            .reason = "the operator stopped it",
        } },
    });

    var pending = fixture.server.popPendingCancel().?;
    defer pending.deinit(allocator);
    const stop_line = (try fixture.bridge.cancelLine(pending)).?;
    defer allocator.free(stop_line);

    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_stopped = .{ .session_id = fixture.native_id },
    });

    try expectGoldenTrace(&fixture.server, allocator, &[_]GoldenFrame{
        .{ .type_name = "run.cancel.response", .sequence = null, .correlated = true },
        .{ .type_name = "run.status.updated", .sequence = 2, .correlated = false },
        .{ .type_name = "run.cancelled", .sequence = 3, .correlated = false },
        .{ .type_name = "session.state.updated", .sequence = 2, .correlated = false },
    });
}

test "the provider failure conversation matches the trace validated by the oap reference validator" {
    const allocator = testing.allocator;
    var fixture = try startFixture(allocator, "smokesessionkey000001");
    defer fixture.deinit(allocator);
    drainOap(&fixture.server, allocator);

    try feedNative(&fixture.bridge, &fixture.server, allocator, fixture.native_id, .{
        .agent_event = try allocator.dupe(
            u8,
            "{\"type\":\"error\",\"message\":\"anthropic request failed: HTTP 401\",\"code\":\"internal_error\"}",
        ),
    });

    try expectGoldenTrace(&fixture.server, allocator, &[_]GoldenFrame{
        .{ .type_name = "run.failed", .sequence = 2, .correlated = false },
        .{ .type_name = "session.state.updated", .sequence = 2, .correlated = false },
    });
}
