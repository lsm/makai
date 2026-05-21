const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const tui_session = @import("tui_session");
const tui_runtime = @import("tui_runtime");
const agent = @import("agent");
const json_writer = @import("json/writer");
const OwnedSlice = @import("owned_slice").OwnedSlice;

fn tmpBase(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "sessions" });
    errdefer allocator.free(base);
    try compat.fs.createDir(compat.fs.getCwd(), base);
    return base;
}

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

fn appendFile(path: []const u8, data: []const u8) !void {
    var file = try compat.fs.getCwd().createFile(defaultIo(), path, .{ .truncate = false, .read = true, .permissions = compat.fs.default_file_mode });
    defer file.close(defaultIo());
    const stat = try file.stat(defaultIo());
    try file.writePositionalAll(defaultIo(), data, stat.size);
}

pub const SessionMetadata = struct {
    session_id: []u8,
    model: []u8,
    provider: []u8,
    created_at: i64,
    last_active: i64,
    turn_count: usize,
    working_dir: []u8,

    pub fn deinit(self: *SessionMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.model);
        allocator.free(self.provider);
        allocator.free(self.working_dir);
        self.* = undefined;
    }
};

pub const LoadedSession = struct {
    metadata: SessionMetadata,
    events: std.ArrayList(tui_session.TuiEvent) = .empty,
    messages: std.ArrayList(ai_types.Message) = .empty,

    pub fn deinit(self: *LoadedSession, allocator: std.mem.Allocator) void {
        self.metadata.deinit(allocator);
        for (self.events.items) |*event| event.deinit(allocator);
        self.events.deinit(allocator);
        for (self.messages.items) |*msg| msg.deinit(allocator);
        self.messages.deinit(allocator);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    base_dir: []u8,

    pub fn init(allocator: std.mem.Allocator, base_dir: []const u8) !Store {
        return .{ .allocator = allocator, .base_dir = try allocator.dupe(u8, base_dir) };
    }

    pub fn initDefault(allocator: std.mem.Allocator) !Store {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return error.HomeNotFound,
            else => return err,
        };
        defer allocator.free(home);
        const base = try std.fs.path.join(allocator, &.{ home, ".makai", "sessions" });
        defer allocator.free(base);
        return init(allocator, base);
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.base_dir);
        self.* = undefined;
    }

    pub fn save(self: Store, metadata: SessionMetadata, event: tui_session.TuiEvent) !void {
        try compat.fs.createDir(compat.fs.getCwd(), self.base_dir);
        const path = try sessionPath(self.allocator, self.base_dir, metadata.session_id);
        defer self.allocator.free(path);
        const line = try serializeEventRecord(self.allocator, metadata, event);
        defer self.allocator.free(line);
        try appendFile(path, line);
    }

    pub fn load(self: Store, session_id: []const u8) !LoadedSession {
        const path = try sessionPath(self.allocator, self.base_dir, session_id);
        defer self.allocator.free(path);
        const data = try compat.fs.readFileAlloc(self.allocator, compat.fs.getCwd(), path, 16 * 1024 * 1024);
        defer self.allocator.free(data);
        var loaded = LoadedSession{ .metadata = try defaultMetadata(self.allocator, session_id) };
        errdefer loaded.deinit(self.allocator);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            applyLine(self.allocator, &loaded, trimmed) catch continue;
        }
        return loaded;
    }

    pub fn list(self: Store) !std.ArrayList(SessionMetadata) {
        var result: std.ArrayList(SessionMetadata) = .empty;
        errdefer {
            for (result.items) |*meta| meta.deinit(self.allocator);
            result.deinit(self.allocator);
        }
        var dir = compat.fs.getCwd().openDir(defaultIo(), self.base_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return result,
            else => return err,
        };
        defer dir.close(defaultIo());
        var iter = dir.iterate();
        while (try iter.next(defaultIo())) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
            const session_id = entry.name[0 .. entry.name.len - ".jsonl".len];
            var loaded = self.load(session_id) catch continue;
            defer loaded.deinit(self.allocator);
            try result.append(self.allocator, try cloneMetadata(self.allocator, loaded.metadata));
        }
        return result;
    }

    pub fn resumeSession(self: Store, session_id: []const u8, runtime: *tui_runtime.TuiRuntime) !LoadedSession {
        var loaded = try self.load(session_id);
        errdefer loaded.deinit(self.allocator);
        try runtime.start();
        try runtime.replaceMessages(loaded.messages.items);
        return loaded;
    }
};

fn sessionPath(allocator: std.mem.Allocator, base_dir: []const u8, session_id: []const u8) ![]u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{session_id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ base_dir, file_name });
}

fn defaultMetadata(allocator: std.mem.Allocator, session_id: []const u8) !SessionMetadata {
    return .{
        .session_id = try allocator.dupe(u8, session_id),
        .model = try allocator.dupe(u8, ""),
        .provider = try allocator.dupe(u8, ""),
        .created_at = 0,
        .last_active = 0,
        .turn_count = 0,
        .working_dir = try allocator.dupe(u8, ""),
    };
}

fn cloneMetadata(allocator: std.mem.Allocator, meta: SessionMetadata) !SessionMetadata {
    return .{
        .session_id = try allocator.dupe(u8, meta.session_id),
        .model = try allocator.dupe(u8, meta.model),
        .provider = try allocator.dupe(u8, meta.provider),
        .created_at = meta.created_at,
        .last_active = meta.last_active,
        .turn_count = meta.turn_count,
        .working_dir = try allocator.dupe(u8, meta.working_dir),
    };
}

fn applyLine(allocator: std.mem.Allocator, loaded: *LoadedSession, line: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidRecord,
    };
    if (obj.get("metadata")) |meta_value| switch (meta_value) {
        .object => |meta_obj| try updateMetadata(allocator, &loaded.metadata, meta_obj),
        else => {},
    };
    if (obj.get("event")) |event_value| {
        const event = try parseEvent(allocator, event_value);
        errdefer {
            var ev = event;
            ev.deinit(allocator);
        }
        try loaded.events.append(allocator, event);
    }
    if (obj.get("message")) |message_value| {
        const message = try parseMessage(allocator, message_value);
        errdefer {
            var msg = message;
            msg.deinit(allocator);
        }
        try loaded.messages.append(allocator, message);
    }
}

fn updateMetadata(allocator: std.mem.Allocator, meta: *SessionMetadata, obj: std.json.ObjectMap) !void {
    if (stringField(obj, "session_id")) |v| try replaceString(allocator, &meta.session_id, v);
    if (stringField(obj, "model")) |v| try replaceString(allocator, &meta.model, v);
    if (stringField(obj, "provider")) |v| try replaceString(allocator, &meta.provider, v);
    if (intField(obj, "created_at")) |v| meta.created_at = v;
    if (intField(obj, "last_active")) |v| meta.last_active = v;
    if (uintField(obj, "turn_count")) |v| meta.turn_count = v;
    if (stringField(obj, "working_dir")) |v| try replaceString(allocator, &meta.working_dir, v);
}

fn replaceString(allocator: std.mem.Allocator, target: *[]u8, value: []const u8) !void {
    if (target.len > 0) allocator.free(target.*);
    target.* = try allocator.dupe(u8, value);
}

fn serializeEventRecord(allocator: std.mem.Allocator, metadata: SessionMetadata, event: tui_session.TuiEvent) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buf, allocator);
    try w.beginObject();
    try writeMetadata(&w, metadata);
    try w.writeKey("event");
    try writeEvent(&w, event);
    if (messageFromEvent(allocator, event)) |message| {
        var msg = message;
        defer msg.deinit(allocator);
        try w.writeKey("message");
        try writeMessage(&w, msg);
    } else |_| {}
    try w.endObject();
    try buf.append(allocator, '\n');
    return buf.toOwnedSlice(allocator);
}

fn writeMetadata(w: *json_writer.JsonWriter, meta: SessionMetadata) !void {
    try w.writeKey("metadata");
    try w.beginObject();
    try w.writeStringField("session_id", meta.session_id);
    try w.writeStringField("model", meta.model);
    try w.writeStringField("provider", meta.provider);
    try w.writeIntField("created_at", meta.created_at);
    try w.writeIntField("last_active", meta.last_active);
    try w.writeIntField("turn_count", meta.turn_count);
    try w.writeStringField("working_dir", meta.working_dir);
    try w.endObject();
}

fn writeEvent(w: *json_writer.JsonWriter, event: tui_session.TuiEvent) !void {
    try w.beginObject();
    switch (event) {
        .agent_start => try w.writeStringField("type", "agent_start"),
        .turn_start => try w.writeStringField("type", "turn_start"),
        .message_start => |p| { try w.writeStringField("type", "message_start"); try w.writeStringField("role", @tagName(p.role)); },
        .text_delta => |p| { try w.writeStringField("type", "text_delta"); try w.writeIntField("content_index", p.content_index); try w.writeStringField("delta", p.delta.slice()); },
        .thinking_delta => |p| { try w.writeStringField("type", "thinking_delta"); try w.writeIntField("content_index", p.content_index); try w.writeStringField("delta", p.delta.slice()); },
        .tool_call_delta => |p| { try w.writeStringField("type", "tool_call_delta"); try w.writeIntField("content_index", p.content_index); try w.writeStringField("delta", p.delta.slice()); },
        .message_end => |p| { try w.writeStringField("type", "message_end"); try w.writeStringField("role", @tagName(p.role)); },
        .tool_approval_requested => |p| { try w.writeStringField("type", "tool_approval_requested"); try writeToolFields(w, p.tool_call_id.slice(), p.tool_name.slice(), p.args_json.slice()); },
        .tool_execution_start => |p| { try w.writeStringField("type", "tool_execution_start"); try writeToolFields(w, p.tool_call_id.slice(), p.tool_name.slice(), p.args_json.slice()); },
        .tool_execution_update => |p| { try w.writeStringField("type", "tool_execution_update"); try writeToolFields(w, p.tool_call_id.slice(), p.tool_name.slice(), p.args_json.slice()); try w.writeStringField("partial_result_json", p.partial_result_json.slice()); },
        .tool_execution_end => |p| { try w.writeStringField("type", "tool_execution_end"); try w.writeStringField("tool_call_id", p.tool_call_id.slice()); try w.writeStringField("tool_name", p.tool_name.slice()); try w.writeStringField("result_json", p.result_json.slice()); try w.writeBoolField("is_error", p.is_error); },
        .turn_end => |p| { try w.writeStringField("type", "turn_end"); try w.writeStringField("stop_reason", @tagName(p.stop_reason)); },
        .agent_end => |p| { try w.writeStringField("type", "agent_end"); try w.writeStringField("reason", @tagName(p.reason)); },
        .@"error" => |p| { try w.writeStringField("type", "error"); try w.writeStringField("message", p.message.slice()); },
    }
    try w.endObject();
}

fn writeToolFields(w: *json_writer.JsonWriter, id: []const u8, name: []const u8, args: []const u8) !void {
    try w.writeStringField("tool_call_id", id);
    try w.writeStringField("tool_name", name);
    try w.writeStringField("args_json", args);
}

fn parseEvent(allocator: std.mem.Allocator, value: std.json.Value) !tui_session.TuiEvent {
    const obj = switch (value) { .object => |o| o, else => return error.InvalidEvent };
    const kind = stringField(obj, "type") orelse return error.InvalidEvent;
    if (std.mem.eql(u8, kind, "agent_start")) return .agent_start;
    if (std.mem.eql(u8, kind, "turn_start")) return .turn_start;
    if (std.mem.eql(u8, kind, "message_start")) return .{ .message_start = .{ .role = parseRole(stringField(obj, "role") orelse "assistant") } };
    if (std.mem.eql(u8, kind, "text_delta")) return .{ .text_delta = .{ .content_index = uintField(obj, "content_index") orelse 0, .delta = try owned(allocator, stringField(obj, "delta") orelse "") } };
    if (std.mem.eql(u8, kind, "thinking_delta")) return .{ .thinking_delta = .{ .content_index = uintField(obj, "content_index") orelse 0, .delta = try owned(allocator, stringField(obj, "delta") orelse "") } };
    if (std.mem.eql(u8, kind, "tool_call_delta")) return .{ .tool_call_delta = .{ .content_index = uintField(obj, "content_index") orelse 0, .delta = try owned(allocator, stringField(obj, "delta") orelse "") } };
    if (std.mem.eql(u8, kind, "message_end")) return .{ .message_end = .{ .role = parseRole(stringField(obj, "role") orelse "assistant") } };
    if (std.mem.eql(u8, kind, "tool_approval_requested")) return .{ .tool_approval_requested = .{ .tool_call_id = try owned(allocator, stringField(obj, "tool_call_id") orelse ""), .tool_name = try owned(allocator, stringField(obj, "tool_name") orelse ""), .args_json = try owned(allocator, stringField(obj, "args_json") orelse "") } };
    if (std.mem.eql(u8, kind, "tool_execution_start")) return .{ .tool_execution_start = .{ .tool_call_id = try owned(allocator, stringField(obj, "tool_call_id") orelse ""), .tool_name = try owned(allocator, stringField(obj, "tool_name") orelse ""), .args_json = try owned(allocator, stringField(obj, "args_json") orelse "") } };
    if (std.mem.eql(u8, kind, "tool_execution_update")) return .{ .tool_execution_update = .{ .tool_call_id = try owned(allocator, stringField(obj, "tool_call_id") orelse ""), .tool_name = try owned(allocator, stringField(obj, "tool_name") orelse ""), .args_json = try owned(allocator, stringField(obj, "args_json") orelse ""), .partial_result_json = try owned(allocator, stringField(obj, "partial_result_json") orelse "") } };
    if (std.mem.eql(u8, kind, "tool_execution_end")) return .{ .tool_execution_end = .{ .tool_call_id = try owned(allocator, stringField(obj, "tool_call_id") orelse ""), .tool_name = try owned(allocator, stringField(obj, "tool_name") orelse ""), .result_json = try owned(allocator, stringField(obj, "result_json") orelse ""), .is_error = boolField(obj, "is_error", false) } };
    if (std.mem.eql(u8, kind, "turn_end")) return .{ .turn_end = .{ .stop_reason = parseStopReason(stringField(obj, "stop_reason") orelse "stop") } };
    if (std.mem.eql(u8, kind, "agent_end")) return .{ .agent_end = .{ .reason = parseEndReason(stringField(obj, "reason") orelse "completed") } };
    if (std.mem.eql(u8, kind, "error")) return .{ .@"error" = .{ .message = try owned(allocator, stringField(obj, "message") orelse "") } };
    return error.InvalidEvent;
}

fn owned(allocator: std.mem.Allocator, value: []const u8) !OwnedSlice(u8) {
    return OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
}

fn messageFromEvent(allocator: std.mem.Allocator, event: tui_session.TuiEvent) !ai_types.Message {
    return switch (event) {
        .message_start => |p| switch (p.role) {
            else => error.NoMessage,
        },
        .text_delta => |p| .{ .user = .{ .content = .{ .text = try allocator.dupe(u8, p.delta.slice()) }, .timestamp = compat.time.nowMillis() } },
        .tool_execution_end => |p| .{ .tool_result = try toolResultMessage(allocator, p) },
        else => error.NoMessage,
    };
}

fn assistantTextMessage(allocator: std.mem.Allocator, text: []const u8, stop_reason: ai_types.StopReason) !ai_types.AssistantMessage {
    const content = try allocator.alloc(ai_types.AssistantContent, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    const api = try allocator.dupe(u8, "");
    errdefer allocator.free(api);
    const provider = try allocator.dupe(u8, "");
    errdefer allocator.free(provider);
    const model = try allocator.dupe(u8, "");
    errdefer allocator.free(model);
    return .{
        .content = content,
        .api = api,
        .provider = provider,
        .model = model,
        .usage = .{},
        .stop_reason = stop_reason,
        .timestamp = compat.time.nowMillis(),
        .is_owned = true,
    };
}

fn toolResultMessage(allocator: std.mem.Allocator, p: anytype) !ai_types.ToolResultMessage {
    const parts = try allocator.alloc(ai_types.UserContentPart, 1);
    errdefer allocator.free(parts);
    parts[0] = .{ .text = .{ .text = try allocator.dupe(u8, p.result_json.slice()) } };
    return .{
        .tool_call_id = try allocator.dupe(u8, p.tool_call_id.slice()),
        .tool_name = try allocator.dupe(u8, p.tool_name.slice()),
        .content = parts,
        .details_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, p.result_json.slice())),
        .is_error = p.is_error,
        .timestamp = compat.time.nowMillis(),
    };
}

fn writeMessage(w: *json_writer.JsonWriter, message: ai_types.Message) !void {
    try w.beginObject();
    switch (message) {
        .user => |m| { try w.writeStringField("role", "user"); try w.writeStringField("text", switch (m.content) { .text => |t| t, .parts => "" }); try w.writeIntField("timestamp", m.timestamp); },
        .assistant => |m| { try w.writeStringField("role", "assistant"); try w.writeStringField("text", assistantText(m.content)); try w.writeStringField("stop_reason", @tagName(m.stop_reason)); try w.writeIntField("timestamp", m.timestamp); },
        .tool_result => |m| { try w.writeStringField("role", "tool_result"); try w.writeStringField("tool_call_id", m.tool_call_id); try w.writeStringField("tool_name", m.tool_name); try w.writeStringField("text", userPartsText(m.content)); try w.writeStringField("details_json", m.details_json.slice()); try w.writeBoolField("is_error", m.is_error); try w.writeIntField("timestamp", m.timestamp); },
    }
    try w.endObject();
}

fn parseMessage(allocator: std.mem.Allocator, value: std.json.Value) !ai_types.Message {
    const obj = switch (value) { .object => |o| o, else => return error.InvalidMessage };
    const role = stringField(obj, "role") orelse return error.InvalidMessage;
    if (std.mem.eql(u8, role, "user")) return .{ .user = .{ .content = .{ .text = try allocator.dupe(u8, stringField(obj, "text") orelse "") }, .timestamp = intField(obj, "timestamp") orelse 0 } };
    if (std.mem.eql(u8, role, "assistant")) return .{ .assistant = try assistantTextMessage(allocator, stringField(obj, "text") orelse "", parseStopReason(stringField(obj, "stop_reason") orelse "stop")) };
    if (std.mem.eql(u8, role, "tool_result")) {
        const parts = try allocator.alloc(ai_types.UserContentPart, 1);
        errdefer allocator.free(parts);
        parts[0] = .{ .text = .{ .text = try allocator.dupe(u8, stringField(obj, "text") orelse "") } };
        return .{ .tool_result = .{
            .tool_call_id = try allocator.dupe(u8, stringField(obj, "tool_call_id") orelse ""),
            .tool_name = try allocator.dupe(u8, stringField(obj, "tool_name") orelse ""),
            .content = parts,
            .details_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, stringField(obj, "details_json") orelse "")),
            .is_error = boolField(obj, "is_error", false),
            .timestamp = intField(obj, "timestamp") orelse 0,
        } };
    }
    return error.InvalidMessage;
}

fn assistantText(content: []const ai_types.AssistantContent) []const u8 {
    for (content) |block| switch (block) { .text => |t| return t.text, else => {} };
    return "";
}

fn userPartsText(parts: []const ai_types.UserContentPart) []const u8 {
    for (parts) |part| switch (part) { .text => |t| return t.text, else => {} };
    return "";
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) { .string => |s| s, else => null };
}

fn boolField(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const value = obj.get(key) orelse return default;
    return switch (value) { .bool => |b| b, else => default };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) { .integer => |i| @intCast(i), else => null };
}

fn uintField(obj: std.json.ObjectMap, key: []const u8) ?usize {
    const value = obj.get(key) orelse return null;
    return switch (value) { .integer => |i| if (i >= 0) @intCast(i) else null, else => null };
}

fn parseRole(value: []const u8) tui_session.TuiEvent.MessageRole {
    if (std.mem.eql(u8, value, "user")) return .user;
    if (std.mem.eql(u8, value, "tool_result")) return .tool_result;
    return .assistant;
}

fn parseStopReason(value: []const u8) ai_types.StopReason {
    if (std.mem.eql(u8, value, "length")) return .length;
    if (std.mem.eql(u8, value, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, value, "content_filter")) return .content_filter;
    if (std.mem.eql(u8, value, "error")) return .@"error";
    if (std.mem.eql(u8, value, "aborted")) return .aborted;
    return .stop;
}

fn parseEndReason(value: []const u8) tui_session.TuiEndReason {
    if (std.mem.eql(u8, value, "cancelled")) return .cancelled;
    if (std.mem.eql(u8, value, "error")) return .@"error";
    return .completed;
}

test "save 10 events load replays in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);
    var store = try Store.init(std.testing.allocator, base);
    defer store.deinit();
    var meta = try defaultMetadata(std.testing.allocator, "s1");
    defer meta.deinit(std.testing.allocator);
    try replaceString(std.testing.allocator, &meta.model, "model-a");
    try replaceString(std.testing.allocator, &meta.provider, "test");
    try replaceString(std.testing.allocator, &meta.working_dir, base);
    meta.created_at = 1;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        meta.last_active = @intCast(i + 1);
        meta.turn_count = i + 1;
        const delta = try std.fmt.allocPrint(std.testing.allocator, "d{d}", .{i});
        defer std.testing.allocator.free(delta);
        var event = tui_session.TuiEvent{ .text_delta = .{ .content_index = i, .delta = try owned(std.testing.allocator, delta) } };
        defer event.deinit(std.testing.allocator);
        try store.save(meta, event);
    }
    var loaded = try store.load("s1");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 10), loaded.events.items.len);
    for (loaded.events.items, 0..) |event, idx| try std.testing.expectEqual(idx, event.text_delta.content_index);
}

test "corrupted JSONL line is skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);
    var store = try Store.init(std.testing.allocator, base);
    defer store.deinit();
    var meta = try defaultMetadata(std.testing.allocator, "s2");
    defer meta.deinit(std.testing.allocator);
    try store.save(meta, .turn_start);
    const path = try sessionPath(std.testing.allocator, base, "s2");
    defer std.testing.allocator.free(path);
    try appendFile(path, "{bad json}\n");
    try store.save(meta, .{ .agent_end = .{ .reason = .completed } });
    var loaded = try store.load("s2");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), loaded.events.items.len);
    try std.testing.expect(loaded.events.items[0] == .turn_start);
    try std.testing.expect(loaded.events.items[1] == .agent_end);
}

test "session metadata updates from last valid line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);
    var store = try Store.init(std.testing.allocator, base);
    defer store.deinit();
    var meta = try defaultMetadata(std.testing.allocator, "s3");
    defer meta.deinit(std.testing.allocator);
    try replaceString(std.testing.allocator, &meta.model, "m1");
    try replaceString(std.testing.allocator, &meta.provider, "p1");
    meta.created_at = 10;
    meta.last_active = 20;
    meta.turn_count = 1;
    try store.save(meta, tui_session.TuiEvent.turn_start);
    meta.last_active = 30;
    meta.turn_count = 2;
    try store.save(meta, tui_session.TuiEvent.turn_start);
    var list = try store.list();
    defer {
        for (list.items) |*item| item.deinit(std.testing.allocator);
        list.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(i64, 30), list.items[0].last_active);
    try std.testing.expectEqual(@as(usize, 2), list.items[0].turn_count);
}
