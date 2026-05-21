const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const tui_session = @import("tui_session");
const tui_runtime = @import("tui_runtime");
const agent = @import("agent");
const json_writer = @import("json_writer");
const builtin = @import("builtin");
const OwnedSlice = @import("owned_slice").OwnedSlice;

const ToolResultSource = enum { execution_end, message_end };

const ToolResultReplayEntry = struct {
    tool_call_id: []u8,
    message_index: usize,
    source: ToolResultSource,

    fn deinit(self: *ToolResultReplayEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        self.* = undefined;
    }
};

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
    _ = builtin;
    var file = try compat.fs.getCwd().createFile(defaultIo(), path, .{ .truncate = false, .read = true, .lock = .exclusive, .permissions = compat.fs.default_file_mode });
    defer file.close(defaultIo());
    const stat = try file.stat(defaultIo());
    try file.writePositionalAll(defaultIo(), data, stat.size);
}

const load_max_bytes = 64 * 1024 * 1024;
const metadata_max_bytes = 1024 * 1024;
const max_jsonl_line_bytes = 8 * 1024 * 1024;

fn readJsonlRecords(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize, ctx: anytype, comptime onLine: fn (@TypeOf(ctx), []const u8) anyerror!void) !void {
    var file = try compat.fs.getCwd().openFile(defaultIo(), path, .{});
    defer file.close(defaultIo());
    var file_buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(defaultIo(), &file_buffer);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var total: usize = 0;
    while (true) {
        out.clearRetainingCapacity();
        _ = reader.interface.streamDelimiterEnding(&out.writer, '\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.WriteFailed => return error.OutOfMemory,
        };
        const raw_line = out.written();
        total += raw_line.len;
        if (total > max_bytes) return error.StreamTooLong;
        if (raw_line.len > max_jsonl_line_bytes) return error.StreamTooLong;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len > 0) try onLine(ctx, line);
        if (reader.interface.buffered().len == 0) break;
        _ = reader.interface.takeByte() catch break;
        total += 1;
        if (total > max_bytes) return error.StreamTooLong;
    }
}

fn readLastJsonlLines(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try compat.fs.getCwd().openFile(defaultIo(), path, .{});
    defer file.close(defaultIo());
    const stat = try file.stat(defaultIo());
    const read_len: usize = @intCast(@min(stat.size, max_bytes));
    const offset = stat.size - read_len;
    const data = try allocator.alloc(u8, read_len);
    errdefer allocator.free(data);
    const read = try file.readPositionalAll(defaultIo(), data, offset);
    if (read == data.len) return data;
    return allocator.realloc(data, read);
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

const ReplayState = struct {
    current_role: ?tui_session.TuiEvent.MessageRole = null,
    assistant_text: std.ArrayList(u8) = .empty,
    tool_call_json: std.ArrayList(u8) = .empty,
    tool_results: std.ArrayList(ToolResultReplayEntry) = .empty,

    fn deinit(self: *ReplayState, allocator: std.mem.Allocator) void {
        for (self.tool_results.items) |*entry| entry.deinit(allocator);
        self.tool_results.deinit(allocator);
        self.assistant_text.deinit(allocator);
        self.tool_call_json.deinit(allocator);
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
        var loaded = LoadedSession{ .metadata = try defaultMetadata(self.allocator, session_id) };
        errdefer loaded.deinit(self.allocator);
        var replay = ReplayState{};
        defer replay.deinit(self.allocator);
        var ctx = LoadLineContext{ .allocator = self.allocator, .loaded = &loaded, .replay = &replay };
        try readJsonlRecords(self.allocator, path, load_max_bytes, &ctx, loadLine);
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
            var metadata = self.loadMetadata(session_id) catch continue;
            errdefer metadata.deinit(self.allocator);
            try result.append(self.allocator, metadata);
        }
        return result;
    }

    fn loadMetadata(self: Store, session_id: []const u8) !SessionMetadata {
        const path = try sessionPath(self.allocator, self.base_dir, session_id);
        defer self.allocator.free(path);
        const data = try readLastJsonlLines(self.allocator, path, metadata_max_bytes);
        defer self.allocator.free(data);
        var meta = try defaultMetadata(self.allocator, session_id);
        errdefer meta.deinit(self.allocator);

        var end = data.len;
        while (end > 0) {
            while (end > 0 and (data[end - 1] == '\n' or data[end - 1] == '\r' or data[end - 1] == ' ' or data[end - 1] == '\t')) end -= 1;
            if (end == 0) break;
            const start = if (std.mem.lastIndexOfScalar(u8, data[0..end], '\n')) |idx| idx + 1 else 0;
            const line = std.mem.trim(u8, data[start..end], " \t\r");
            end = if (start == 0) 0 else start - 1;
            if (line.len == 0) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            const obj = switch (parsed.value) { .object => |o| o, else => continue };
            if (obj.get("metadata")) |value| switch (value) {
                .object => |meta_obj| {
                    try updateMetadata(self.allocator, &meta, meta_obj);
                    break;
                },
                else => {},
            };
        }
        return meta;
    }

    pub fn resumeSession(self: Store, session_id: []const u8, runtime: *tui_runtime.TuiRuntime) !LoadedSession {
        var loaded = try self.load(session_id);
        errdefer loaded.deinit(self.allocator);
        try runtime.start();
        if (loaded.metadata.model.len > 0) try runtime.switchModel(loaded.metadata.model);
        try runtime.replaceMessages(loaded.messages.items);
        return loaded;
    }
};

fn sessionPath(allocator: std.mem.Allocator, base_dir: []const u8, session_id: []const u8) ![]u8 {
    try validateSessionId(session_id);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{session_id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ base_dir, file_name });
}

fn validateSessionId(session_id: []const u8) !void {
    if (session_id.len == 0) return error.InvalidSessionId;
    if (std.mem.indexOfScalar(u8, session_id, '/') != null) return error.InvalidSessionId;
    if (std.mem.indexOfScalar(u8, session_id, '\\') != null) return error.InvalidSessionId;
    if (std.mem.indexOf(u8, session_id, "..") != null) return error.InvalidSessionId;
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

const LoadLineContext = struct {
    allocator: std.mem.Allocator,
    loaded: *LoadedSession,
    replay: *ReplayState,
};

fn loadLine(ctx: *LoadLineContext, line: []const u8) !void {
    applyLine(ctx.allocator, ctx.loaded, ctx.replay, line) catch |err| switch (err) {
        error.InvalidRecord, error.InvalidEvent, error.SyntaxError, error.UnexpectedToken, error.InvalidNumber, error.DuplicateField, error.UnknownField, error.MissingField, error.LengthMismatch => {},
        else => return err,
    };
}

fn applyLine(allocator: std.mem.Allocator, loaded: *LoadedSession, replay: *ReplayState, line: []const u8) !void {
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
        try replayEvent(allocator, &loaded.messages, replay, loaded.metadata, event);
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

fn replayEvent(allocator: std.mem.Allocator, messages: *std.ArrayList(ai_types.Message), replay: *ReplayState, meta: SessionMetadata, event: tui_session.TuiEvent) !void {
    switch (event) {
        .message_start => |payload| {
            replay.current_role = payload.role;
            replay.assistant_text.clearRetainingCapacity();
            replay.tool_call_json.clearRetainingCapacity();
        },
        .text_delta => |payload| if (replay.current_role == .assistant) {
            try replay.assistant_text.appendSlice(allocator, payload.delta.slice());
        },
        .tool_call_delta => |payload| if (replay.current_role == .assistant) {
            try replay.tool_call_json.appendSlice(allocator, payload.delta.slice());
        },
        .message_end => |payload| {
            defer {
                replay.current_role = null;
                replay.assistant_text.clearRetainingCapacity();
                replay.tool_call_json.clearRetainingCapacity();
            }
            switch (payload.role) {
                .user => {
                    if (payload.content_json.slice().len > 0) {
                        try messages.append(allocator, .{ .user = .{ .content = try parseUserContent(allocator, payload.content_json.slice()), .timestamp = compat.time.nowMillis() } });
                    } else if (payload.text.slice().len > 0) {
                        try messages.append(allocator, try userMessage(allocator, payload.text.slice()));
                    }
                },
                .assistant => {
                    if (payload.content_json.slice().len > 0) {
                        try messages.append(allocator, .{ .assistant = try parseAssistantMessageFromContentJson(allocator, meta, payload.content_json.slice(), payload.stop_reason) });
                    } else if (payload.tool_calls_json.slice().len > 0) {
                        try messages.append(allocator, .{ .assistant = try parseAssistantMessageFromContentJson(allocator, meta, payload.tool_calls_json.slice(), payload.stop_reason) });
                    } else if (payload.tool_call_id.slice().len > 0) {
                        try messages.append(allocator, .{ .assistant = try assistantToolCallMessage(allocator, meta, payload.tool_call_id.slice(), payload.tool_name.slice(), payload.args_json.slice()) });
                    } else if (payload.text.slice().len > 0) {
                        try messages.append(allocator, .{ .assistant = try assistantTextMessageWithMeta(allocator, meta, payload.text.slice(), payload.stop_reason) });
                    } else if (replay.assistant_text.items.len > 0) {
                        try messages.append(allocator, .{ .assistant = try assistantTextMessageWithMeta(allocator, meta, replay.assistant_text.items, payload.stop_reason) });
                    } else if (replay.tool_call_json.items.len > 0) {
                        try messages.append(allocator, .{ .assistant = try assistantToolCallMessage(allocator, meta, "", "", replay.tool_call_json.items) });
                    }
                },
                .tool_result => if (payload.tool_call_id.slice().len > 0 and payload.content_json.slice().len > 0) {
                    const message = ai_types.Message{ .tool_result = try parseToolResultFromPayload(allocator, payload) };
                    errdefer {
                        var msg = message;
                        msg.deinit(allocator);
                    }
                    try rememberToolResultMessage(allocator, messages, replay, payload.tool_call_id.slice(), message, .message_end);
                },
            }
        },
        .tool_execution_end => |payload| {
            const message = ai_types.Message{ .tool_result = try toolResultMessage(allocator, payload) };
            errdefer {
                var msg = message;
                msg.deinit(allocator);
            }
            try rememberToolResultMessage(allocator, messages, replay, payload.tool_call_id.slice(), message, .execution_end);
        },
        else => {},
    }
}

fn findToolResult(replay: *ReplayState, tool_call_id: []const u8) ?usize {
    if (tool_call_id.len == 0) return null;
    for (replay.tool_results.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.tool_call_id, tool_call_id)) return i;
    }
    return null;
}

fn rememberToolResultMessage(allocator: std.mem.Allocator, messages: *std.ArrayList(ai_types.Message), replay: *ReplayState, tool_call_id: []const u8, message: ai_types.Message, source: ToolResultSource) !void {
    if (findToolResult(replay, tool_call_id)) |entry_index| {
        const entry = &replay.tool_results.items[entry_index];
        if (entry.source == .execution_end and source == .message_end) {
            messages.items[entry.message_index].deinit(allocator);
            messages.items[entry.message_index] = message;
            entry.source = source;
        } else {
            var unused = message;
            unused.deinit(allocator);
        }
        return;
    }

    try messages.append(allocator, message);
    errdefer _ = messages.pop();
    const owned_id = try allocator.dupe(u8, tool_call_id);
    errdefer allocator.free(owned_id);
    try replay.tool_results.append(allocator, .{ .tool_call_id = owned_id, .message_index = messages.items.len - 1, .source = source });
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
        .message_end => |p| {
            try w.writeStringField("type", "message_end");
            try w.writeStringField("role", @tagName(p.role));
            try w.writeStringField("text", p.text.slice());
            try w.writeStringField("content_json", p.content_json.slice());
            try w.writeStringField("tool_call_id", p.tool_call_id.slice());
            try w.writeStringField("tool_name", p.tool_name.slice());
            try w.writeStringField("args_json", p.args_json.slice());
            try w.writeStringField("tool_calls_json", p.tool_calls_json.slice());
            try w.writeStringField("details_json", p.details_json.slice());
            try w.writeStringField("artifacts_json", p.artifacts_json.slice());
            try w.writeStringField("stop_reason", @tagName(p.stop_reason));
            try w.writeBoolField("is_error", p.is_error);
        },
        .tool_approval_requested => |p| { try w.writeStringField("type", "tool_approval_requested"); try writeToolFields(w, p.tool_call_id.slice(), p.tool_name.slice(), p.args_json.slice()); },
        .tool_execution_start => |p| { try w.writeStringField("type", "tool_execution_start"); try writeToolFields(w, p.tool_call_id.slice(), p.tool_name.slice(), p.args_json.slice()); },
        .tool_execution_update => |p| { try w.writeStringField("type", "tool_execution_update"); try writeToolFields(w, p.tool_call_id.slice(), p.tool_name.slice(), p.args_json.slice()); try w.writeStringField("partial_result_json", p.partial_result_json.slice()); },
        .tool_execution_end => |p| {
            try w.writeStringField("type", "tool_execution_end");
            try w.writeStringField("tool_call_id", p.tool_call_id.slice());
            try w.writeStringField("tool_name", p.tool_name.slice());
            try w.writeStringField("result_json", p.result_json.slice());
            try w.writeBoolField("is_error", p.is_error);
            try w.writeIntField("raw_total_bytes", p.raw_total_bytes);
            try w.writeIntField("returned_total_bytes", p.returned_total_bytes);
            try w.writeIntField("estimated_returned_tokens", p.estimated_returned_tokens);
            try w.writeIntField("artifact_count", p.artifact_count);
            try w.writeStringField("artifact_refs", p.artifact_refs.slice());
        },
        .context_usage => |p| {
            try w.writeStringField("type", "context_usage");
            try w.writeIntField("system_prompt_bytes", p.system_prompt_bytes);
            try w.writeIntField("message_bytes", p.message_bytes);
            try w.writeIntField("tool_definition_bytes", p.tool_definition_bytes);
            try w.writeIntField("total_bytes", p.total_bytes);
            try w.writeIntField("estimated_tokens", p.estimated_tokens);
            try w.writeIntField("message_count", p.message_count);
            try w.writeIntField("tool_count", p.tool_count);
        },
        .prompt_segment_usage => |p| {
            try w.writeStringField("type", "prompt_segment_usage");
            try w.writeStringField("segment", @tagName(p.segment));
            try w.writeStringField("cache_role", @tagName(p.cache_role));
            try w.writeIntField("bytes", p.bytes);
            try w.writeIntField("estimated_tokens", p.estimated_tokens);
            try w.writeIntField("item_count", p.item_count);
        },
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
    if (std.mem.eql(u8, kind, "message_end")) return .{ .message_end = .{
        .role = parseRole(stringField(obj, "role") orelse "assistant"),
        .text = try owned(allocator, stringField(obj, "text") orelse ""),
        .content_json = try owned(allocator, stringField(obj, "content_json") orelse ""),
        .tool_call_id = try owned(allocator, stringField(obj, "tool_call_id") orelse ""),
        .tool_name = try owned(allocator, stringField(obj, "tool_name") orelse ""),
        .args_json = try owned(allocator, stringField(obj, "args_json") orelse ""),
        .tool_calls_json = try owned(allocator, stringField(obj, "tool_calls_json") orelse ""),
        .details_json = try owned(allocator, stringField(obj, "details_json") orelse ""),
        .artifacts_json = try owned(allocator, stringField(obj, "artifacts_json") orelse ""),
        .stop_reason = parseStopReason(stringField(obj, "stop_reason") orelse "stop"),
        .is_error = boolField(obj, "is_error", false),
    } };
    if (std.mem.eql(u8, kind, "tool_approval_requested")) return .{ .tool_approval_requested = .{ .tool_call_id = try owned(allocator, stringField(obj, "tool_call_id") orelse ""), .tool_name = try owned(allocator, stringField(obj, "tool_name") orelse ""), .args_json = try owned(allocator, stringField(obj, "args_json") orelse "") } };
    if (std.mem.eql(u8, kind, "tool_execution_start")) return .{ .tool_execution_start = .{ .tool_call_id = try owned(allocator, stringField(obj, "tool_call_id") orelse ""), .tool_name = try owned(allocator, stringField(obj, "tool_name") orelse ""), .args_json = try owned(allocator, stringField(obj, "args_json") orelse "") } };
    if (std.mem.eql(u8, kind, "tool_execution_update")) return .{ .tool_execution_update = .{ .tool_call_id = try owned(allocator, stringField(obj, "tool_call_id") orelse ""), .tool_name = try owned(allocator, stringField(obj, "tool_name") orelse ""), .args_json = try owned(allocator, stringField(obj, "args_json") orelse ""), .partial_result_json = try owned(allocator, stringField(obj, "partial_result_json") orelse "") } };
    if (std.mem.eql(u8, kind, "tool_execution_end")) return .{ .tool_execution_end = .{
        .tool_call_id = try owned(allocator, stringField(obj, "tool_call_id") orelse ""),
        .tool_name = try owned(allocator, stringField(obj, "tool_name") orelse ""),
        .result_json = try owned(allocator, stringField(obj, "result_json") orelse ""),
        .is_error = boolField(obj, "is_error", false),
        .raw_total_bytes = uint64Field(obj, "raw_total_bytes") orelse 0,
        .returned_total_bytes = uint64Field(obj, "returned_total_bytes") orelse 0,
        .estimated_returned_tokens = uint64Field(obj, "estimated_returned_tokens") orelse 0,
        .artifact_count = uint32Field(obj, "artifact_count") orelse 0,
        .artifact_refs = try owned(allocator, stringField(obj, "artifact_refs") orelse ""),
    } };
    if (std.mem.eql(u8, kind, "context_usage")) return .{ .context_usage = .{
        .system_prompt_bytes = uint64Field(obj, "system_prompt_bytes") orelse 0,
        .message_bytes = uint64Field(obj, "message_bytes") orelse 0,
        .tool_definition_bytes = uint64Field(obj, "tool_definition_bytes") orelse 0,
        .total_bytes = uint64Field(obj, "total_bytes") orelse 0,
        .estimated_tokens = uint64Field(obj, "estimated_tokens") orelse 0,
        .message_count = uint32Field(obj, "message_count") orelse 0,
        .tool_count = uint32Field(obj, "tool_count") orelse 0,
    } };
    if (std.mem.eql(u8, kind, "prompt_segment_usage")) return .{ .prompt_segment_usage = .{
        .segment = parsePromptSegmentKind(stringField(obj, "segment") orelse "message_history"),
        .cache_role = parsePromptSegmentCacheRole(stringField(obj, "cache_role") orelse "dynamic"),
        .bytes = uint64Field(obj, "bytes") orelse 0,
        .estimated_tokens = uint64Field(obj, "estimated_tokens") orelse 0,
        .item_count = uint32Field(obj, "item_count") orelse 0,
    } };
    if (std.mem.eql(u8, kind, "turn_end")) return .{ .turn_end = .{ .stop_reason = parseStopReason(stringField(obj, "stop_reason") orelse "stop") } };
    if (std.mem.eql(u8, kind, "agent_end")) return .{ .agent_end = .{ .reason = parseEndReason(stringField(obj, "reason") orelse "completed") } };
    if (std.mem.eql(u8, kind, "error")) return .{ .@"error" = .{ .message = try owned(allocator, stringField(obj, "message") orelse "") } };
    return error.InvalidEvent;
}

fn owned(allocator: std.mem.Allocator, value: []const u8) !OwnedSlice(u8) {
    return OwnedSlice(u8).initOwned(try allocator.dupe(u8, value));
}

fn userMessage(allocator: std.mem.Allocator, text: []const u8) !ai_types.Message {
    return .{ .user = .{ .content = .{ .text = try allocator.dupe(u8, text) }, .timestamp = compat.time.nowMillis() } };
}

fn parseUserContent(allocator: std.mem.Allocator, json: []const u8) !ai_types.UserContent {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const arr = switch (parsed.value) { .array => |a| a, else => return error.InvalidMessage };
    const parts = try allocator.alloc(ai_types.UserContentPart, arr.items.len);
    var initialized: usize = 0;
    errdefer {
        for (parts[0..initialized]) |*part| part.deinit(allocator);
        allocator.free(parts);
    }
    for (arr.items, 0..) |item, i| {
        parts[i] = try parseUserContentPart(allocator, item);
        initialized += 1;
    }
    return .{ .parts = parts };
}

fn parseUserParts(allocator: std.mem.Allocator, json: []const u8) ![]const ai_types.UserContentPart {
    const content = try parseUserContent(allocator, json);
    return switch (content) {
        .parts => |parts| parts,
        .text => error.InvalidMessage,
    };
}

fn parseUserContentPart(allocator: std.mem.Allocator, value: std.json.Value) !ai_types.UserContentPart {
    const obj = switch (value) { .object => |o| o, else => return error.InvalidMessage };
    const kind = stringField(obj, "type") orelse return error.InvalidMessage;
    if (std.mem.eql(u8, kind, "text")) return .{ .text = .{
        .text = try allocator.dupe(u8, stringField(obj, "text") orelse ""),
        .text_signature = if (stringField(obj, "text_signature")) |sig| try allocator.dupe(u8, sig) else null,
    } };
    if (std.mem.eql(u8, kind, "image")) return .{ .image = .{
        .data = try allocator.dupe(u8, stringField(obj, "data") orelse ""),
        .mime_type = try allocator.dupe(u8, stringField(obj, "mime_type") orelse ""),
    } };
    return error.InvalidMessage;
}

fn parseAssistantMessageFromContentJson(allocator: std.mem.Allocator, meta: SessionMetadata, json: []const u8, fallback_stop_reason: ai_types.StopReason) !ai_types.AssistantMessage {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const arr = switch (parsed.value) { .array => |a| a, else => return error.InvalidMessage };
    const content = try allocator.alloc(ai_types.AssistantContent, arr.items.len);
    var initialized: usize = 0;
    var has_tool_call = false;
    errdefer {
        deinitAssistantContentPrefix(allocator, content[0..initialized]);
        allocator.free(content);
    }
    for (arr.items, 0..) |item, i| {
        content[i] = try parseAssistantContent(allocator, item);
        if (content[i] == .tool_call) has_tool_call = true;
        initialized += 1;
    }
    const stop_reason: ai_types.StopReason = if (fallback_stop_reason == .stop and has_tool_call) .tool_use else fallback_stop_reason;
    return assistantMessage(allocator, meta, content, stop_reason);
}

fn parseAssistantContent(allocator: std.mem.Allocator, value: std.json.Value) !ai_types.AssistantContent {
    const obj = switch (value) { .object => |o| o, else => return error.InvalidMessage };
    const kind = stringField(obj, "type") orelse return error.InvalidMessage;
    if (std.mem.eql(u8, kind, "text")) return .{ .text = .{
        .text = try allocator.dupe(u8, stringField(obj, "text") orelse ""),
        .text_signature = if (stringField(obj, "text_signature")) |sig| try allocator.dupe(u8, sig) else null,
    } };
    if (std.mem.eql(u8, kind, "thinking")) return .{ .thinking = .{
        .thinking = try allocator.dupe(u8, stringField(obj, "thinking") orelse ""),
        .thinking_signature = if (stringField(obj, "thinking_signature")) |sig| try allocator.dupe(u8, sig) else null,
    } };
    if (std.mem.eql(u8, kind, "tool_call")) return .{ .tool_call = .{
        .id = try allocator.dupe(u8, stringField(obj, "id") orelse ""),
        .name = try allocator.dupe(u8, stringField(obj, "name") orelse ""),
        .arguments_json = try allocator.dupe(u8, stringField(obj, "arguments_json") orelse ""),
        .thought_signature = if (stringField(obj, "thought_signature")) |sig| try allocator.dupe(u8, sig) else null,
    } };
    if (std.mem.eql(u8, kind, "image")) return .{ .image = .{
        .data = try allocator.dupe(u8, stringField(obj, "data") orelse ""),
        .mime_type = try allocator.dupe(u8, stringField(obj, "mime_type") orelse ""),
    } };
    return error.InvalidMessage;
}

fn parseToolResultFromPayload(allocator: std.mem.Allocator, payload: anytype) !ai_types.ToolResultMessage {
    return .{
        .tool_call_id = try allocator.dupe(u8, payload.tool_call_id.slice()),
        .tool_name = try allocator.dupe(u8, payload.tool_name.slice()),
        .content = try parseUserParts(allocator, payload.content_json.slice()),
        .details_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, payload.details_json.slice())),
        .artifacts = OwnedSlice(ai_types.ArtifactReference).initOwned(try parseArtifacts(allocator, payload.artifacts_json.slice())),
        .is_error = payload.is_error,
        .timestamp = compat.time.nowMillis(),
    };
}

fn parseArtifacts(allocator: std.mem.Allocator, json: []const u8) ![]ai_types.ArtifactReference {
    if (json.len == 0) return allocator.alloc(ai_types.ArtifactReference, 0);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const arr = switch (parsed.value) { .array => |a| a, else => return error.InvalidMessage };
    const artifacts = try allocator.alloc(ai_types.ArtifactReference, arr.items.len);
    var initialized: usize = 0;
    errdefer {
        for (artifacts[0..initialized]) |*artifact| artifact.deinit(allocator);
        allocator.free(artifacts);
    }
    for (arr.items, 0..) |item, i| {
        const obj = switch (item) { .object => |o| o, else => return error.InvalidMessage };
        artifacts[i] = .{
            .artifact_id = try allocator.dupe(u8, stringField(obj, "artifact_id") orelse ""),
            .uri = OwnedSlice(u8).initOwned(try allocator.dupe(u8, stringField(obj, "uri") orelse "")),
            .mime_type = OwnedSlice(u8).initOwned(try allocator.dupe(u8, stringField(obj, "mime_type") orelse "")),
            .byte_size = uintField(obj, "byte_size"),
            .sha256 = OwnedSlice(u8).initOwned(try allocator.dupe(u8, stringField(obj, "sha256") orelse "")),
            .description = OwnedSlice(u8).initOwned(try allocator.dupe(u8, stringField(obj, "description") orelse "")),
        };
        initialized += 1;
    }
    return artifacts;
}

fn deinitAssistantContentPrefix(allocator: std.mem.Allocator, content: []ai_types.AssistantContent) void {
    for (content) |block| switch (block) {
        .text => |text| {
            allocator.free(text.text);
            if (text.text_signature) |sig| allocator.free(sig);
        },
        .thinking => |thinking| {
            allocator.free(thinking.thinking);
            if (thinking.thinking_signature) |sig| allocator.free(sig);
        },
        .tool_call => |tool| {
            allocator.free(tool.id);
            allocator.free(tool.name);
            allocator.free(tool.arguments_json);
            if (tool.thought_signature) |sig| allocator.free(sig);
        },
        .image => |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        },
    };
}

fn assistantTextMessage(allocator: std.mem.Allocator, text: []const u8, stop_reason: ai_types.StopReason) !ai_types.AssistantMessage {
    const meta = SessionMetadata{
        .session_id = @constCast(""),
        .model = @constCast(""),
        .provider = @constCast(""),
        .created_at = 0,
        .last_active = 0,
        .turn_count = 0,
        .working_dir = @constCast(""),
    };
    return assistantTextMessageWithMeta(allocator, meta, text, stop_reason);
}

fn assistantTextMessageWithMeta(allocator: std.mem.Allocator, meta: SessionMetadata, text: []const u8, stop_reason: ai_types.StopReason) !ai_types.AssistantMessage {
    const content = try allocator.alloc(ai_types.AssistantContent, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return assistantMessage(allocator, meta, content, stop_reason);
}

fn assistantToolCallMessage(allocator: std.mem.Allocator, meta: SessionMetadata, id: []const u8, name: []const u8, args_json: []const u8) !ai_types.AssistantMessage {
    const content = try allocator.alloc(ai_types.AssistantContent, 1);
    errdefer allocator.free(content);
    content[0] = .{ .tool_call = .{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .arguments_json = try allocator.dupe(u8, args_json),
    } };
    return assistantMessage(allocator, meta, content, .tool_use);
}

fn assistantMessage(allocator: std.mem.Allocator, meta: SessionMetadata, content: []const ai_types.AssistantContent, stop_reason: ai_types.StopReason) !ai_types.AssistantMessage {
    const api = try allocator.dupe(u8, "");
    errdefer allocator.free(api);
    const provider = try allocator.dupe(u8, meta.provider);
    errdefer allocator.free(provider);
    const model = try allocator.dupe(u8, meta.model);
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
    return toolResultFromFields(allocator, p.tool_call_id.slice(), p.tool_name.slice(), p.result_json.slice(), p.is_error);
}

fn toolResultFromFields(allocator: std.mem.Allocator, tool_call_id: []const u8, tool_name: []const u8, result: []const u8, is_error: bool) !ai_types.ToolResultMessage {
    const parts = try allocator.alloc(ai_types.UserContentPart, 1);
    errdefer allocator.free(parts);
    parts[0] = .{ .text = .{ .text = try allocator.dupe(u8, result) } };
    return .{
        .tool_call_id = try allocator.dupe(u8, tool_call_id),
        .tool_name = try allocator.dupe(u8, tool_name),
        .content = parts,
        .details_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, result)),
        .is_error = is_error,
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

fn uint64Field(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = obj.get(key) orelse return null;
    return switch (value) { .integer => |i| if (i >= 0) @intCast(i) else null, else => null };
}

fn uint32Field(obj: std.json.ObjectMap, key: []const u8) ?u32 {
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

fn parsePromptSegmentKind(value: []const u8) tui_session.TuiEvent.PromptSegmentKind {
    if (std.mem.eql(u8, value, "system_prompt")) return .system_prompt;
    if (std.mem.eql(u8, value, "tool_definitions")) return .tool_definitions;
    return .message_history;
}

fn parsePromptSegmentCacheRole(value: []const u8) tui_session.TuiEvent.PromptSegmentCacheRole {
    if (std.mem.eql(u8, value, "stable")) return .stable;
    return .dynamic;
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

test "invalid session id is rejected" {
    try std.testing.expectError(error.InvalidSessionId, validateSessionId("../escape"));
    try std.testing.expectError(error.InvalidSessionId, validateSessionId("foo/bar"));
    try std.testing.expectError(error.InvalidSessionId, validateSessionId("foo\\bar"));
    try validateSessionId("session-123");
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

test "metadata loads from tail of large session file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);
    var store = try Store.init(std.testing.allocator, base);
    defer store.deinit();
    var meta = try defaultMetadata(std.testing.allocator, "large-metadata");
    defer meta.deinit(std.testing.allocator);
    try replaceString(std.testing.allocator, &meta.model, "tail-model");
    try replaceString(std.testing.allocator, &meta.provider, "tail-provider");
    meta.last_active = 99;
    meta.turn_count = 7;

    const path = try sessionPath(std.testing.allocator, base, "large-metadata");
    defer std.testing.allocator.free(path);
    const padding = try std.testing.allocator.alloc(u8, metadata_max_bytes + 16);
    defer std.testing.allocator.free(padding);
    @memset(padding, ' ');
    try appendFile(path, padding);
    try appendFile(path, "\n");
    try store.save(meta, tui_session.TuiEvent.turn_start);

    var list = try store.list();
    defer {
        for (list.items) |*item| item.deinit(std.testing.allocator);
        list.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("tail-model", list.items[0].model);
    try std.testing.expectEqual(@as(i64, 99), list.items[0].last_active);
}

fn contentJson(text: []const u8) !OwnedSlice(u8) {
    return owned(std.testing.allocator, text);
}

fn testMeta(session_id: []const u8) !SessionMetadata {
    var meta = try defaultMetadata(std.testing.allocator, session_id);
    try replaceString(std.testing.allocator, &meta.model, "model-a");
    try replaceString(std.testing.allocator, &meta.provider, "provider-a");
    return meta;
}

const user_parts_json = "[{\"type\":\"text\",\"text\":\"see this\"},{\"type\":\"image\",\"data\":\"base64data\",\"mime_type\":\"image/png\"}]";
const assistant_mixed_json = "[{\"type\":\"text\",\"text\":\"I will call tools\"},{\"type\":\"tool_call\",\"id\":\"call-1\",\"name\":\"demo\",\"arguments_json\":\"{\\\"x\\\":1}\"}]";
const assistant_image_json = "[{\"type\":\"image\",\"data\":\"assistant-image\",\"mime_type\":\"image/png\"}]";


test "message_end replay preserves user image parts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);
    var store = try Store.init(std.testing.allocator, base);
    defer store.deinit();
    var meta = try testMeta("user-parts");
    defer meta.deinit(std.testing.allocator);

    var event = tui_session.TuiEvent{ .message_end = .{ .role = .user, .text = try owned(std.testing.allocator, "see this"), .content_json = try contentJson(user_parts_json) } };
    defer event.deinit(std.testing.allocator);
    try store.save(meta, event);

    var loaded = try store.load("user-parts");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), loaded.messages.items.len);
    const user = loaded.messages.items[0].user;
    try std.testing.expect(user.content == .parts);
    try std.testing.expectEqual(@as(usize, 2), user.content.parts.len);
    try std.testing.expect(user.content.parts[1] == .image);
    try std.testing.expectEqualStrings("base64data", user.content.parts[1].image.data);
}


test "message_end replay preserves mixed assistant text and tool calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);
    var store = try Store.init(std.testing.allocator, base);
    defer store.deinit();
    var meta = try testMeta("assistant-mixed");
    defer meta.deinit(std.testing.allocator);

    var event = tui_session.TuiEvent{ .message_end = .{ .role = .assistant, .text = try owned(std.testing.allocator, "I will call tools"), .content_json = try contentJson(assistant_mixed_json), .stop_reason = .length } };
    defer event.deinit(std.testing.allocator);
    try store.save(meta, event);

    var loaded = try store.load("assistant-mixed");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), loaded.messages.items.len);
    const assistant = loaded.messages.items[0].assistant;
    try std.testing.expectEqual(@as(usize, 2), assistant.content.len);
    try std.testing.expect(assistant.content[0] == .text);
    try std.testing.expect(assistant.content[1] == .tool_call);
    try std.testing.expectEqualStrings("call-1", assistant.content[1].tool_call.id);
    try std.testing.expectEqual(ai_types.StopReason.length, assistant.stop_reason);
}


test "message_end replay preserves assistant image content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);
    var store = try Store.init(std.testing.allocator, base);
    defer store.deinit();
    var meta = try testMeta("assistant-image");
    defer meta.deinit(std.testing.allocator);

    var event = tui_session.TuiEvent{ .message_end = .{ .role = .assistant, .content_json = try contentJson(assistant_image_json) } };
    defer event.deinit(std.testing.allocator);
    try store.save(meta, event);

    var loaded = try store.load("assistant-image");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), loaded.messages.items.len);
    const assistant = loaded.messages.items[0].assistant;
    try std.testing.expectEqual(@as(usize, 1), assistant.content.len);
    try std.testing.expect(assistant.content[0] == .image);
    try std.testing.expectEqualStrings("assistant-image", assistant.content[0].image.data);
}


test "load skips malformed json but propagates replay errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);
    var store = try Store.init(std.testing.allocator, base);
    defer store.deinit();
    var meta = try testMeta("bad-replay");
    defer meta.deinit(std.testing.allocator);
    try store.save(meta, .turn_start);
    const path = try sessionPath(std.testing.allocator, base, "bad-replay");
    defer std.testing.allocator.free(path);
    try appendFile(path, "{bad json}\n");
    try appendFile(path, "{\"event\":{\"type\":\"message_end\",\"role\":\"assistant\",\"content_json\":\"{}\"}}\n");
    try std.testing.expectError(error.InvalidMessage, store.load("bad-replay"));
}

test "load counts raw JSONL line bytes against caps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);
    const path = try sessionPath(std.testing.allocator, base, "raw-cap");
    defer std.testing.allocator.free(path);
    const padding = try std.testing.allocator.alloc(u8, max_jsonl_line_bytes + 1);
    defer std.testing.allocator.free(padding);
    @memset(padding, ' ');
    try appendFile(path, padding);
    try appendFile(path, "\n");
    var store = try Store.init(std.testing.allocator, base);
    defer store.deinit();
    try std.testing.expectError(error.StreamTooLong, store.load("raw-cap"));
}

test "message_end and tool_execution_end do not duplicate tool result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);
    var store = try Store.init(std.testing.allocator, base);
    defer store.deinit();
    var meta = try testMeta("tool-dedupe");
    defer meta.deinit(std.testing.allocator);

    var message_end = tui_session.TuiEvent{ .message_end = .{
        .role = .tool_result,
        .tool_call_id = try owned(std.testing.allocator, "call-1"),
        .tool_name = try owned(std.testing.allocator, "demo"),
        .content_json = try contentJson("[{\"type\":\"text\",\"text\":\"result\"}]"),
    } };
    defer message_end.deinit(std.testing.allocator);
    try store.save(meta, message_end);

    var tool_end = tui_session.TuiEvent{ .tool_execution_end = .{
        .tool_call_id = try owned(std.testing.allocator, "call-1"),
        .tool_name = try owned(std.testing.allocator, "demo"),
        .result_json = try owned(std.testing.allocator, "result"),
        .is_error = false,
    } };
    defer tool_end.deinit(std.testing.allocator);
    try store.save(meta, tool_end);

    var loaded = try store.load("tool-dedupe");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), loaded.messages.items.len);
    try std.testing.expect(loaded.messages.items[0] == .tool_result);
    try std.testing.expectEqualStrings("call-1", loaded.messages.items[0].tool_result.tool_call_id);
}

test "tool_execution_end before message_end keeps one rich tool result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);
    var store = try Store.init(std.testing.allocator, base);
    defer store.deinit();
    var meta = try testMeta("tool-dedupe-normal-order");
    defer meta.deinit(std.testing.allocator);

    var tool_end = tui_session.TuiEvent{ .tool_execution_end = .{
        .tool_call_id = try owned(std.testing.allocator, "call-1"),
        .tool_name = try owned(std.testing.allocator, "demo"),
        .result_json = try owned(std.testing.allocator, "fallback"),
        .is_error = false,
    } };
    defer tool_end.deinit(std.testing.allocator);
    try store.save(meta, tool_end);

    var message_end = tui_session.TuiEvent{ .message_end = .{
        .role = .tool_result,
        .tool_call_id = try owned(std.testing.allocator, "call-1"),
        .tool_name = try owned(std.testing.allocator, "demo"),
        .content_json = try contentJson("[{\"type\":\"text\",\"text\":\"rich\"}]"),
        .details_json = try owned(std.testing.allocator, "{\"rich\":true}"),
    } };
    defer message_end.deinit(std.testing.allocator);
    try store.save(meta, message_end);

    var loaded = try store.load("tool-dedupe-normal-order");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), loaded.messages.items.len);
    try std.testing.expect(loaded.messages.items[0] == .tool_result);
    try std.testing.expectEqualStrings("call-1", loaded.messages.items[0].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("rich", loaded.messages.items[0].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("{\"rich\":true}", loaded.messages.items[0].tool_result.details_json.slice());
}

test "assistant text fallback preserves stop reason" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);
    var store = try Store.init(std.testing.allocator, base);
    defer store.deinit();
    var meta = try testMeta("assistant-stop-reason");
    defer meta.deinit(std.testing.allocator);

    var event = tui_session.TuiEvent{ .message_end = .{ .role = .assistant, .text = try owned(std.testing.allocator, "partial"), .stop_reason = .aborted } };
    defer event.deinit(std.testing.allocator);
    try store.save(meta, event);

    var loaded = try store.load("assistant-stop-reason");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), loaded.messages.items.len);
    try std.testing.expect(loaded.messages.items[0] == .assistant);
    try std.testing.expectEqual(ai_types.StopReason.aborted, loaded.messages.items[0].assistant.stop_reason);
}

test "JSONL byte cap counts consumed delimiters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);
    const path = try sessionPath(std.testing.allocator, base, "delimiter-cap");
    defer std.testing.allocator.free(path);
    try appendFile(path, "\n\n");

    var loaded = LoadedSession{ .metadata = try defaultMetadata(std.testing.allocator, "delimiter-cap") };
    defer loaded.deinit(std.testing.allocator);
    var replay = ReplayState{};
    defer replay.deinit(std.testing.allocator);
    var ctx = LoadLineContext{ .allocator = std.testing.allocator, .loaded = &loaded, .replay = &replay };
    try std.testing.expectError(error.StreamTooLong, readJsonlRecords(std.testing.allocator, path, 1, &ctx, loadLine));
}
