const std = @import("std");
const agent_types = @import("agent_types");
const envelope = @import("agent_envelope");
const transport = @import("transport");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const AgentProtocolClient = struct {
    allocator: std.mem.Allocator,
    sender: ?transport.AsyncSender = null,
    /// Deprecated compatibility field; sequence is now tracked per session.
    sequence: u64 = 0,
    session_id: ?agent_types.Uuid = null,
    last_error: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    last_result_json: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    event_queue: std.ArrayList(OwnedSlice(u8)),
    next_sequence_by_session: std.AutoHashMap(agent_types.Uuid, u64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .event_queue = std.ArrayList(OwnedSlice(u8)){},
            .next_sequence_by_session = std.AutoHashMap(agent_types.Uuid, u64).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.last_error.deinit(self.allocator);
        self.last_result_json.deinit(self.allocator);
        for (self.event_queue.items) |*e| e.deinit(self.allocator);
        self.event_queue.deinit(self.allocator);
        self.next_sequence_by_session.deinit();
        self.* = undefined;
    }

    pub fn setSender(self: *Self, sender: transport.AsyncSender) void {
        self.sender = sender;
    }

    fn nextSequence(self: *Self, session_id: agent_types.Uuid) !u64 {
        const next = if (self.next_sequence_by_session.get(session_id)) |cur| cur + 1 else 1;
        try self.next_sequence_by_session.put(session_id, next);
        self.sequence = next; // compatibility mirror
        return next;
    }

    pub fn sendAgentStart(self: *Self, config_json: []const u8, system_prompt: ?[]const u8) !agent_types.Uuid {
        const sid = agent_types.generateUuid();
        const msg_id = agent_types.generateUuid();
        const seq = try self.nextSequence(sid);

        var payload = agent_types.Payload{ .agent_start = .{ .config_json = try self.allocator.dupe(u8, config_json), .session_id = sid } };
        defer payload.deinit(self.allocator);
        if (system_prompt) |sp| {
            payload.agent_start.system_prompt = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, sp));
        }

        try self.sendEnvelope(.{
            .session_id = sid,
            .message_id = msg_id,
            .sequence = seq,
            .timestamp = std.time.milliTimestamp(),
            .payload = payload,
        });

        return msg_id;
    }

    pub fn sendAgentMessage(self: *Self, session_id: agent_types.Uuid, message_json: []const u8, options_json: ?[]const u8) !agent_types.Uuid {
        const msg_id = agent_types.generateUuid();
        const seq = try self.nextSequence(session_id);

        var payload = agent_types.Payload{ .agent_message = .{
            .session_id = session_id,
            .message_json = try self.allocator.dupe(u8, message_json),
        } };
        defer payload.deinit(self.allocator);
        if (options_json) |opts| payload.agent_message.options_json = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, opts));

        try self.sendEnvelope(.{
            .session_id = session_id,
            .message_id = msg_id,
            .sequence = seq,
            .timestamp = std.time.milliTimestamp(),
            .payload = payload,
        });
        return msg_id;
    }

    pub fn sendAgentStop(self: *Self, session_id: agent_types.Uuid, reason: ?[]const u8) !agent_types.Uuid {
        const msg_id = agent_types.generateUuid();
        const seq = try self.nextSequence(session_id);

        var payload = agent_types.Payload{ .agent_stop = .{ .session_id = session_id } };
        defer payload.deinit(self.allocator);
        if (reason) |r| payload.agent_stop.reason = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, r));

        try self.sendEnvelope(.{
            .session_id = session_id,
            .message_id = msg_id,
            .sequence = seq,
            .timestamp = std.time.milliTimestamp(),
            .payload = payload,
        });
        return msg_id;
    }

    fn sendEnvelope(self: *Self, env: agent_types.Envelope) !void {
        if (self.sender == null) return error.NoSender;
        const json = try envelope.serializeEnvelope(env, self.allocator);
        defer self.allocator.free(json);
        try self.sender.?.write(json);
        try self.sender.?.flush();
    }

    pub fn processEnvelope(self: *Self, env: agent_types.Envelope) !void {
        switch (env.payload) {
            .agent_started => |p| self.session_id = p.session_id,
            .agent_event => |json| try self.event_queue.append(self.allocator, OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, json))),
            .agent_result => |json| {
                self.last_result_json.deinit(self.allocator);
                self.last_result_json = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, json));
            },
            .agent_error => |e| {
                self.last_error.deinit(self.allocator);
                self.last_error = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, e.message));
            },
            .agent_stopped => |p| {
                if (self.session_id) |sid| {
                    if (std.mem.eql(u8, sid[0..], p.session_id[0..])) self.session_id = null;
                }
                _ = self.next_sequence_by_session.remove(p.session_id);
            },
            else => {},
        }
    }

    pub fn popEvent(self: *Self) ?OwnedSlice(u8) {
        if (self.event_queue.items.len == 0) return null;
        return self.event_queue.orderedRemove(0);
    }

    pub fn getLastError(self: *Self) ?[]const u8 {
        const err = self.last_error.slice();
        return if (err.len == 0) null else err;
    }

    pub fn getLastResultJson(self: *Self) ?[]const u8 {
        const json = self.last_result_json.slice();
        return if (json.len == 0) null else json;
    }
};

test "AgentProtocolClient processes events and results" {
    const allocator = std.testing.allocator;
    var client = AgentProtocolClient.init(allocator);
    defer client.deinit();

    const sid = agent_types.generateUuid();

    try client.processEnvelope(.{
        .session_id = sid,
        .message_id = agent_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .agent_started = .{ .session_id = sid } },
    });

    var event_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .agent_event = try allocator.dupe(u8, "{\"type\":\"turn_start\"}") },
    };
    defer event_env.deinit(allocator);
    try client.processEnvelope(event_env);

    var result_env = agent_types.Envelope{
        .session_id = sid,
        .message_id = agent_types.generateUuid(),
        .sequence = 3,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .agent_result = try allocator.dupe(u8, "{\"ok\":true}") },
    };
    defer result_env.deinit(allocator);
    try client.processEnvelope(result_env);

    var ev = client.popEvent().?;
    defer ev.deinit(allocator);
    try std.testing.expectEqualStrings("{\"type\":\"turn_start\"}", ev.slice());
    try std.testing.expectEqualStrings("{\"ok\":true}", client.getLastResultJson().?);
}
