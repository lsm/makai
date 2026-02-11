const std = @import("std");
const types = @import("types");
const event_stream = @import("event_stream");
const json_writer = @import("json_writer");

// --- Wire message type ---

pub const MessageOrControl = union(enum) {
    event: types.MessageEvent,
    result: types.AssistantMessage,
    stream_error: []const u8,
};

// --- Transport interfaces ---

pub const Sender = struct {
    context: *anyopaque,
    write_fn: *const fn (ctx: *anyopaque, data: []const u8) anyerror!void,
    flush_fn: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    close_fn: ?*const fn (ctx: *anyopaque) void = null,

    pub fn write(self: *const Sender, data: []const u8) !void {
        return self.write_fn(self.context, data);
    }

    pub fn flush(self: *const Sender) !void {
        if (self.flush_fn) |f| return f(self.context);
    }

    pub fn close(self: *const Sender) void {
        if (self.close_fn) |f| f(self.context);
    }
};

pub const Receiver = struct {
    context: *anyopaque,
    read_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]const u8,
    close_fn: ?*const fn (ctx: *anyopaque) void = null,

    pub fn read(self: *const Receiver, allocator: std.mem.Allocator) !?[]const u8 {
        return self.read_fn(self.context, allocator);
    }

    pub fn close(self: *const Receiver) void {
        if (self.close_fn) |f| f(self.context);
    }
};

// --- Generic adapters ---

/// Forward all events from a stream to a Sender. Blocks until stream is complete.
pub fn forwardStream(
    stream: *event_stream.AssistantMessageStream,
    sender: *const Sender,
    allocator: std.mem.Allocator,
) !void {
    while (stream.wait()) |ev| {
        const json_bytes = try serializeEvent(ev, allocator);
        defer allocator.free(json_bytes);
        try sender.write(json_bytes);
        try sender.flush();
    }

    if (stream.getError()) |err_msg| {
        const json_bytes = try serializeError(err_msg, allocator);
        defer allocator.free(json_bytes);
        try sender.write(json_bytes);
    } else if (stream.getResult()) |result| {
        const json_bytes = try serializeResult(result, allocator);
        defer allocator.free(json_bytes);
        try sender.write(json_bytes);
    }
    try sender.flush();
}

/// Receive from a Receiver and push into a local stream. Blocks until done.
pub fn receiveStream(
    receiver: *const Receiver,
    stream: *event_stream.AssistantMessageStream,
    allocator: std.mem.Allocator,
) !void {
    while (try receiver.read(allocator)) |line| {
        defer allocator.free(line);
        const msg = try deserialize(line, allocator);
        switch (msg) {
            .event => |ev| try stream.push(ev),
            .result => |r| {
                stream.complete(r);
                return;
            },
            .stream_error => |e| {
                stream.completeWithError(e);
                return;
            },
        }
    }
    stream.completeWithError("Transport closed unexpectedly");
}

// --- Serialization ---

pub fn serializeEvent(event: types.MessageEvent, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);

    try w.beginObject();

    switch (event) {
        .start => |s| {
            try w.writeStringField("type", "start");
            try w.writeStringField("model", s.model);
        },
        .text_start => |e| {
            try w.writeStringField("type", "text_start");
            try w.writeIntField("index", e.index);
        },
        .text_delta => |d| {
            try w.writeStringField("type", "text_delta");
            try w.writeIntField("index", d.index);
            try w.writeStringField("delta", d.delta);
        },
        .text_end => |e| {
            try w.writeStringField("type", "text_end");
            try w.writeIntField("index", e.index);
        },
        .thinking_start => |e| {
            try w.writeStringField("type", "thinking_start");
            try w.writeIntField("index", e.index);
        },
        .thinking_delta => |d| {
            try w.writeStringField("type", "thinking_delta");
            try w.writeIntField("index", d.index);
            try w.writeStringField("delta", d.delta);
        },
        .thinking_end => |e| {
            try w.writeStringField("type", "thinking_end");
            try w.writeIntField("index", e.index);
        },
        .toolcall_start => |tc| {
            try w.writeStringField("type", "toolcall_start");
            try w.writeIntField("index", tc.index);
            try w.writeStringField("id", tc.id);
            try w.writeStringField("name", tc.name);
        },
        .toolcall_delta => |d| {
            try w.writeStringField("type", "toolcall_delta");
            try w.writeIntField("index", d.index);
            try w.writeStringField("delta", d.delta);
        },
        .toolcall_end => |e| {
            try w.writeStringField("type", "toolcall_end");
            try w.writeIntField("index", e.index);
            try w.writeStringField("input_json", e.input_json);
        },
        .done => |d| {
            try w.writeStringField("type", "done");
            try w.writeStringField("stop_reason", @tagName(d.stop_reason));
            try w.writeIntField("input_tokens", d.usage.input_tokens);
            try w.writeIntField("output_tokens", d.usage.output_tokens);
            try w.writeIntField("cache_read_tokens", d.usage.cache_read_tokens);
            try w.writeIntField("cache_write_tokens", d.usage.cache_write_tokens);
        },
        .@"error" => |e| {
            try w.writeStringField("type", "error");
            try w.writeStringField("message", e.message);
        },
        .ping => {
            try w.writeStringField("type", "ping");
        },
    }

    try w.endObject();

    const result = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return result;
}

pub fn serializeResult(result: types.AssistantMessage, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);

    try w.beginObject();
    try w.writeStringField("type", "result");
    try w.writeStringField("stop_reason", @tagName(result.stop_reason));
    try w.writeStringField("model", result.model);
    try w.writeIntField("timestamp", result.timestamp);
    try w.writeIntField("input_tokens", result.usage.input_tokens);
    try w.writeIntField("output_tokens", result.usage.output_tokens);
    try w.writeIntField("cache_read_tokens", result.usage.cache_read_tokens);
    try w.writeIntField("cache_write_tokens", result.usage.cache_write_tokens);

    try w.writeKey("content");
    try w.beginArray();
    for (result.content) |block| {
        try serializeContentBlock(&w, block);
    }
    try w.endArray();

    try w.endObject();

    const out = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return out;
}

pub fn serializeError(msg: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);

    try w.beginObject();
    try w.writeStringField("type", "stream_error");
    try w.writeStringField("message", msg);
    try w.endObject();

    const out = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return out;
}

fn serializeContentBlock(w: *json_writer.JsonWriter, block: types.ContentBlock) !void {
    try w.beginObject();
    switch (block) {
        .text => |t| {
            try w.writeStringField("type", "text");
            try w.writeStringField("text", t.text);
            if (t.signature) |sig| {
                try w.writeStringField("signature", sig);
            }
        },
        .tool_use => |t| {
            try w.writeStringField("type", "tool_use");
            try w.writeStringField("id", t.id);
            try w.writeStringField("name", t.name);
            try w.writeStringField("input_json", t.input_json);
            if (t.thought_signature) |sig| {
                try w.writeStringField("thought_signature", sig);
            }
        },
        .thinking => |t| {
            try w.writeStringField("type", "thinking");
            try w.writeStringField("thinking", t.thinking);
            if (t.signature) |sig| {
                try w.writeStringField("signature", sig);
            }
        },
        .image => |img| {
            try w.writeStringField("type", "image");
            try w.writeStringField("media_type", img.media_type);
            try w.writeStringField("data", img.data);
        },
    }
    try w.endObject();
}

// --- Deserialization ---

pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !MessageOrControl {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const type_str = obj.get("type").?.string;

    if (std.mem.eql(u8, type_str, "result")) {
        return .{ .result = try parseAssistantMessage(obj, allocator) };
    }
    if (std.mem.eql(u8, type_str, "stream_error")) {
        const msg = obj.get("message").?.string;
        return .{ .stream_error = try allocator.dupe(u8, msg) };
    }

    return .{ .event = try parseMessageEvent(type_str, obj, allocator) };
}

fn parseMessageEvent(
    type_str: []const u8,
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !types.MessageEvent {
    if (std.mem.eql(u8, type_str, "start")) {
        return .{ .start = .{
            .model = try allocator.dupe(u8, obj.get("model").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "text_start")) {
        return .{ .text_start = .{
            .index = @intCast(obj.get("index").?.integer),
        } };
    }
    if (std.mem.eql(u8, type_str, "text_delta")) {
        return .{ .text_delta = .{
            .index = @intCast(obj.get("index").?.integer),
            .delta = try allocator.dupe(u8, obj.get("delta").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "text_end")) {
        return .{ .text_end = .{
            .index = @intCast(obj.get("index").?.integer),
        } };
    }
    if (std.mem.eql(u8, type_str, "thinking_start")) {
        return .{ .thinking_start = .{
            .index = @intCast(obj.get("index").?.integer),
        } };
    }
    if (std.mem.eql(u8, type_str, "thinking_delta")) {
        return .{ .thinking_delta = .{
            .index = @intCast(obj.get("index").?.integer),
            .delta = try allocator.dupe(u8, obj.get("delta").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "thinking_end")) {
        return .{ .thinking_end = .{
            .index = @intCast(obj.get("index").?.integer),
        } };
    }
    if (std.mem.eql(u8, type_str, "toolcall_start")) {
        return .{ .toolcall_start = .{
            .index = @intCast(obj.get("index").?.integer),
            .id = try allocator.dupe(u8, obj.get("id").?.string),
            .name = try allocator.dupe(u8, obj.get("name").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "toolcall_delta")) {
        return .{ .toolcall_delta = .{
            .index = @intCast(obj.get("index").?.integer),
            .delta = try allocator.dupe(u8, obj.get("delta").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "toolcall_end")) {
        return .{ .toolcall_end = .{
            .index = @intCast(obj.get("index").?.integer),
            .input_json = try allocator.dupe(u8, obj.get("input_json").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "done")) {
        return .{ .done = .{
            .stop_reason = parseStopReason(obj.get("stop_reason").?.string),
            .usage = .{
                .input_tokens = @intCast(obj.get("input_tokens").?.integer),
                .output_tokens = @intCast(obj.get("output_tokens").?.integer),
                .cache_read_tokens = @intCast(obj.get("cache_read_tokens").?.integer),
                .cache_write_tokens = @intCast(obj.get("cache_write_tokens").?.integer),
            },
        } };
    }
    if (std.mem.eql(u8, type_str, "error")) {
        return .{ .@"error" = .{
            .message = try allocator.dupe(u8, obj.get("message").?.string),
        } };
    }
    if (std.mem.eql(u8, type_str, "ping")) {
        return .{ .ping = {} };
    }

    return error.UnknownEventType;
}

fn parseAssistantMessage(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !types.AssistantMessage {
    const content_array = obj.get("content").?.array;
    var content = try allocator.alloc(types.ContentBlock, content_array.items.len);
    errdefer allocator.free(content);

    for (content_array.items, 0..) |item, i| {
        content[i] = try parseContentBlock(item.object, allocator);
    }

    return .{
        .content = content,
        .stop_reason = parseStopReason(obj.get("stop_reason").?.string),
        .model = try allocator.dupe(u8, obj.get("model").?.string),
        .timestamp = obj.get("timestamp").?.integer,
        .usage = .{
            .input_tokens = @intCast(obj.get("input_tokens").?.integer),
            .output_tokens = @intCast(obj.get("output_tokens").?.integer),
            .cache_read_tokens = @intCast(obj.get("cache_read_tokens").?.integer),
            .cache_write_tokens = @intCast(obj.get("cache_write_tokens").?.integer),
        },
    };
}

fn parseContentBlock(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !types.ContentBlock {
    const type_str = obj.get("type").?.string;

    if (std.mem.eql(u8, type_str, "text")) {
        const signature = if (obj.get("signature")) |sig_val|
            try allocator.dupe(u8, sig_val.string)
        else
            null;
        return .{ .text = .{
            .text = try allocator.dupe(u8, obj.get("text").?.string),
            .signature = signature,
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_use")) {
        const thought_signature = if (obj.get("thought_signature")) |sig_val|
            try allocator.dupe(u8, sig_val.string)
        else
            null;
        return .{ .tool_use = .{
            .id = try allocator.dupe(u8, obj.get("id").?.string),
            .name = try allocator.dupe(u8, obj.get("name").?.string),
            .input_json = try allocator.dupe(u8, obj.get("input_json").?.string),
            .thought_signature = thought_signature,
        } };
    }
    if (std.mem.eql(u8, type_str, "thinking")) {
        const signature = if (obj.get("signature")) |sig_val|
            try allocator.dupe(u8, sig_val.string)
        else
            null;
        return .{ .thinking = .{
            .thinking = try allocator.dupe(u8, obj.get("thinking").?.string),
            .signature = signature,
        } };
    }
    if (std.mem.eql(u8, type_str, "image")) {
        return .{ .image = .{
            .media_type = try allocator.dupe(u8, obj.get("media_type").?.string),
            .data = try allocator.dupe(u8, obj.get("data").?.string),
        } };
    }

    return error.UnknownContentBlockType;
}

fn parseStopReason(str: []const u8) types.StopReason {
    if (std.mem.eql(u8, str, "stop")) return .stop;
    if (std.mem.eql(u8, str, "length")) return .length;
    if (std.mem.eql(u8, str, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, str, "content_filter")) return .content_filter;
    if (std.mem.eql(u8, str, "error")) return .@"error";
    if (std.mem.eql(u8, str, "aborted")) return .aborted;
    return .@"error";
}

// Custom error set
pub const TransportError = error{
    UnknownEventType,
    UnknownContentBlockType,
};

// --- Tests ---

test "serialize and deserialize start event" {
    const allocator = std.testing.allocator;
    const event = types.MessageEvent{ .start = .{ .model = "claude-3" } };

    const json = try serializeEvent(event, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .event);
    try std.testing.expect(msg.event == .start);
    // model string was duped during deserialization, free it
    allocator.free(msg.event.start.model);
}

test "serialize and deserialize text_delta event" {
    const allocator = std.testing.allocator;
    const event = types.MessageEvent{ .text_delta = .{ .index = 2, .delta = "Hello world" } };

    const json = try serializeEvent(event, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .event);
    try std.testing.expect(msg.event == .text_delta);
    try std.testing.expectEqual(@as(usize, 2), msg.event.text_delta.index);
    try std.testing.expectEqualStrings("Hello world", msg.event.text_delta.delta);
    allocator.free(msg.event.text_delta.delta);
}

test "serialize and deserialize done event" {
    const allocator = std.testing.allocator;
    const event = types.MessageEvent{ .done = .{
        .stop_reason = .tool_use,
        .usage = .{
            .input_tokens = 100,
            .output_tokens = 50,
            .cache_read_tokens = 20,
            .cache_write_tokens = 10,
        },
    } };

    const json = try serializeEvent(event, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .event);
    try std.testing.expect(msg.event == .done);
    try std.testing.expectEqual(types.StopReason.tool_use, msg.event.done.stop_reason);
    try std.testing.expectEqual(@as(u64, 100), msg.event.done.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 50), msg.event.done.usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 20), msg.event.done.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 10), msg.event.done.usage.cache_write_tokens);
}

test "serialize and deserialize toolcall_start event" {
    const allocator = std.testing.allocator;
    const event = types.MessageEvent{ .toolcall_start = .{
        .index = 1,
        .id = "toolu_123",
        .name = "search",
    } };

    const json = try serializeEvent(event, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .event);
    try std.testing.expect(msg.event == .toolcall_start);
    try std.testing.expectEqual(@as(usize, 1), msg.event.toolcall_start.index);
    try std.testing.expectEqualStrings("toolu_123", msg.event.toolcall_start.id);
    try std.testing.expectEqualStrings("search", msg.event.toolcall_start.name);
    allocator.free(msg.event.toolcall_start.id);
    allocator.free(msg.event.toolcall_start.name);
}

test "serialize and deserialize ping event" {
    const allocator = std.testing.allocator;
    const event = types.MessageEvent{ .ping = {} };

    const json = try serializeEvent(event, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .event);
    try std.testing.expect(msg.event == .ping);
}

test "serialize and deserialize error event" {
    const allocator = std.testing.allocator;
    const event = types.MessageEvent{ .@"error" = .{ .message = "Rate limited" } };

    const json = try serializeEvent(event, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .event);
    try std.testing.expect(msg.event == .@"error");
    try std.testing.expectEqualStrings("Rate limited", msg.event.@"error".message);
    allocator.free(msg.event.@"error".message);
}

test "serialize and deserialize result" {
    const allocator = std.testing.allocator;
    const content = [_]types.ContentBlock{
        .{ .text = .{ .text = "Hello world" } },
    };
    const result = types.AssistantMessage{
        .content = &content,
        .usage = .{
            .input_tokens = 100,
            .output_tokens = 50,
            .cache_read_tokens = 0,
            .cache_write_tokens = 0,
        },
        .stop_reason = .stop,
        .model = "claude-3",
        .timestamp = 1234567890,
    };

    const json = try serializeResult(result, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .result);
    try std.testing.expectEqualStrings("claude-3", msg.result.model);
    try std.testing.expectEqual(@as(i64, 1234567890), msg.result.timestamp);
    try std.testing.expectEqual(types.StopReason.stop, msg.result.stop_reason);
    try std.testing.expectEqual(@as(u64, 100), msg.result.usage.input_tokens);
    try std.testing.expectEqual(@as(usize, 1), msg.result.content.len);
    try std.testing.expect(msg.result.content[0] == .text);
    try std.testing.expectEqualStrings("Hello world", msg.result.content[0].text.text);
    // Free duped strings
    allocator.free(msg.result.model);
    allocator.free(msg.result.content[0].text.text);
    allocator.free(msg.result.content);
}

test "serialize and deserialize stream_error" {
    const allocator = std.testing.allocator;

    const json = try serializeError("Connection failed", allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .stream_error);
    try std.testing.expectEqualStrings("Connection failed", msg.stream_error);
    allocator.free(msg.stream_error);
}

test "serialize and deserialize all index-based events" {
    const allocator = std.testing.allocator;

    // text_start
    {
        const event = types.MessageEvent{ .text_start = .{ .index = 0 } };
        const json = try serializeEvent(event, allocator);
        defer allocator.free(json);
        const msg = try deserialize(json, allocator);
        try std.testing.expect(msg.event == .text_start);
        try std.testing.expectEqual(@as(usize, 0), msg.event.text_start.index);
    }

    // text_end
    {
        const event = types.MessageEvent{ .text_end = .{ .index = 0 } };
        const json = try serializeEvent(event, allocator);
        defer allocator.free(json);
        const msg = try deserialize(json, allocator);
        try std.testing.expect(msg.event == .text_end);
        try std.testing.expectEqual(@as(usize, 0), msg.event.text_end.index);
    }

    // thinking_start
    {
        const event = types.MessageEvent{ .thinking_start = .{ .index = 1 } };
        const json = try serializeEvent(event, allocator);
        defer allocator.free(json);
        const msg = try deserialize(json, allocator);
        try std.testing.expect(msg.event == .thinking_start);
        try std.testing.expectEqual(@as(usize, 1), msg.event.thinking_start.index);
    }

    // thinking_delta
    {
        const event = types.MessageEvent{ .thinking_delta = .{ .index = 1, .delta = "Let me think..." } };
        const json = try serializeEvent(event, allocator);
        defer allocator.free(json);
        const msg = try deserialize(json, allocator);
        try std.testing.expect(msg.event == .thinking_delta);
        try std.testing.expectEqualStrings("Let me think...", msg.event.thinking_delta.delta);
        allocator.free(msg.event.thinking_delta.delta);
    }

    // thinking_end
    {
        const event = types.MessageEvent{ .thinking_end = .{ .index = 1 } };
        const json = try serializeEvent(event, allocator);
        defer allocator.free(json);
        const msg = try deserialize(json, allocator);
        try std.testing.expect(msg.event == .thinking_end);
        try std.testing.expectEqual(@as(usize, 1), msg.event.thinking_end.index);
    }

    // toolcall_delta
    {
        const event = types.MessageEvent{ .toolcall_delta = .{ .index = 0, .delta = "{\"loc\":" } };
        const json = try serializeEvent(event, allocator);
        defer allocator.free(json);
        const msg = try deserialize(json, allocator);
        try std.testing.expect(msg.event == .toolcall_delta);
        try std.testing.expectEqualStrings("{\"loc\":", msg.event.toolcall_delta.delta);
        allocator.free(msg.event.toolcall_delta.delta);
    }

    // toolcall_end
    {
        const event = types.MessageEvent{ .toolcall_end = .{ .index = 0, .input_json = "{\"location\":\"SF\"}" } };
        const json = try serializeEvent(event, allocator);
        defer allocator.free(json);
        const msg = try deserialize(json, allocator);
        try std.testing.expect(msg.event == .toolcall_end);
        try std.testing.expectEqualStrings("{\"location\":\"SF\"}", msg.event.toolcall_end.input_json);
        allocator.free(msg.event.toolcall_end.input_json);
    }
}

test "serialize and deserialize result with multiple content block types" {
    const allocator = std.testing.allocator;
    const content = [_]types.ContentBlock{
        .{ .text = .{ .text = "Here is the result" } },
        .{ .tool_use = .{ .id = "t1", .name = "search", .input_json = "{}" } },
        .{ .thinking = .{ .thinking = "I should search" } },
        .{ .image = .{ .media_type = "image/png", .data = "iVBOR" } },
    };
    const result = types.AssistantMessage{
        .content = &content,
        .usage = .{ .output_tokens = 25 },
        .stop_reason = .tool_use,
        .model = "claude-3",
        .timestamp = 999,
    };

    const json = try serializeResult(result, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .result);
    try std.testing.expectEqual(@as(usize, 4), msg.result.content.len);

    try std.testing.expect(msg.result.content[0] == .text);
    try std.testing.expectEqualStrings("Here is the result", msg.result.content[0].text.text);

    try std.testing.expect(msg.result.content[1] == .tool_use);
    try std.testing.expectEqualStrings("t1", msg.result.content[1].tool_use.id);
    try std.testing.expectEqualStrings("search", msg.result.content[1].tool_use.name);

    try std.testing.expect(msg.result.content[2] == .thinking);
    try std.testing.expectEqualStrings("I should search", msg.result.content[2].thinking.thinking);

    try std.testing.expect(msg.result.content[3] == .image);
    try std.testing.expectEqualStrings("image/png", msg.result.content[3].image.media_type);

    // Free all duped strings
    allocator.free(msg.result.model);
    allocator.free(msg.result.content[0].text.text);
    allocator.free(msg.result.content[1].tool_use.id);
    allocator.free(msg.result.content[1].tool_use.name);
    allocator.free(msg.result.content[1].tool_use.input_json);
    allocator.free(msg.result.content[2].thinking.thinking);
    allocator.free(msg.result.content[3].image.media_type);
    allocator.free(msg.result.content[3].image.data);
    allocator.free(msg.result.content);
}

test "forwardStream and receiveStream round-trip" {
    const allocator = std.testing.allocator;

    // Buffer to capture serialized output
    var captured = std.ArrayList([]u8){};
    defer {
        for (captured.items) |item| allocator.free(item);
        captured.deinit(allocator);
    }

    // Create a mock sender that captures writes
    const MockSenderCtx = struct {
        captured: *std.ArrayList([]u8),
        allocator: std.mem.Allocator,

        fn writeFn(ctx: *anyopaque, data: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const copy = try self.allocator.dupe(u8, data);
            try self.captured.append(self.allocator, copy);
        }
    };

    var sender_ctx = MockSenderCtx{ .captured = &captured, .allocator = allocator };
    const sender = Sender{
        .context = @ptrCast(&sender_ctx),
        .write_fn = MockSenderCtx.writeFn,
    };

    // Create a source stream and push events
    var source_stream = event_stream.AssistantMessageStream.init(allocator);
    defer source_stream.deinit();

    try source_stream.push(.{ .start = .{ .model = "test-model" } });
    try source_stream.push(.{ .text_delta = .{ .index = 0, .delta = "Hi" } });

    // Allocate model string to avoid "Invalid free" when deinit is called
    const model_str = try allocator.dupe(u8, "test-model");
    source_stream.complete(.{
        .content = &[_]types.ContentBlock{},
        .usage = .{ .output_tokens = 5 },
        .stop_reason = .stop,
        .model = model_str,
        .timestamp = 42,
    });

    // Forward the source stream to the sender
    try forwardStream(&source_stream, &sender, allocator);

    // We should have captured 3 writes: start, text_delta, result
    try std.testing.expectEqual(@as(usize, 3), captured.items.len);

    // Now create a mock receiver from the captured data
    const MockReceiverCtx = struct {
        items: [][]u8,
        index: usize,

        fn readFn(ctx: *anyopaque, alloc: std.mem.Allocator) !?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.index >= self.items.len) return null;
            const data = try alloc.dupe(u8, self.items[self.index]);
            self.index += 1;
            return data;
        }
    };

    var receiver_ctx = MockReceiverCtx{ .items = captured.items, .index = 0 };
    const receiver = Receiver{
        .context = @ptrCast(&receiver_ctx),
        .read_fn = MockReceiverCtx.readFn,
    };

    // Create a destination stream
    var dest_stream = event_stream.AssistantMessageStream.init(allocator);
    defer dest_stream.deinit();

    // Receive into the destination stream
    try receiveStream(&receiver, &dest_stream, allocator);

    // Verify events came through and free deserialized strings
    var event_count: usize = 0;
    while (dest_stream.poll()) |ev| {
        switch (ev) {
            .start => |s| allocator.free(s.model),
            .text_delta => |d| allocator.free(d.delta),
            .thinking_delta => |d| allocator.free(d.delta),
            .toolcall_start => |tc| {
                allocator.free(tc.id);
                allocator.free(tc.name);
            },
            .toolcall_delta => |d| allocator.free(d.delta),
            .toolcall_end => |e| allocator.free(e.input_json),
            .@"error" => |e| allocator.free(e.message),
            else => {},
        }
        event_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), event_count);
    try std.testing.expect(dest_stream.isDone());

    const result = dest_stream.getResult();
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("test-model", result.?.model);
    try std.testing.expectEqual(@as(u64, 5), result.?.usage.output_tokens);
}

test "serialize and deserialize text block with signature" {
    const allocator = std.testing.allocator;
    const content = [_]types.ContentBlock{
        .{ .text = .{ .text = "hello world", .signature = "sig_abc123" } },
    };
    const result = types.AssistantMessage{
        .content = &content,
        .usage = .{ .output_tokens = 2 },
        .stop_reason = .stop,
        .model = "test-model",
        .timestamp = 1000,
    };

    const json = try serializeResult(result, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .result);
    try std.testing.expectEqual(@as(usize, 1), msg.result.content.len);
    try std.testing.expect(msg.result.content[0] == .text);
    try std.testing.expectEqualStrings("hello world", msg.result.content[0].text.text);
    try std.testing.expect(msg.result.content[0].text.signature != null);
    try std.testing.expectEqualStrings("sig_abc123", msg.result.content[0].text.signature.?);

    // Free duped strings
    allocator.free(msg.result.model);
    allocator.free(msg.result.content[0].text.text);
    allocator.free(msg.result.content[0].text.signature.?);
    allocator.free(msg.result.content);
}

test "serialize and deserialize thinking block with signature" {
    const allocator = std.testing.allocator;
    const content = [_]types.ContentBlock{
        .{ .thinking = .{ .thinking = "Let me analyze this...", .signature = "think_sig_xyz" } },
    };
    const result = types.AssistantMessage{
        .content = &content,
        .usage = .{ .output_tokens = 5 },
        .stop_reason = .stop,
        .model = "test-model",
        .timestamp = 2000,
    };

    const json = try serializeResult(result, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .result);
    try std.testing.expectEqual(@as(usize, 1), msg.result.content.len);
    try std.testing.expect(msg.result.content[0] == .thinking);
    try std.testing.expectEqualStrings("Let me analyze this...", msg.result.content[0].thinking.thinking);
    try std.testing.expect(msg.result.content[0].thinking.signature != null);
    try std.testing.expectEqualStrings("think_sig_xyz", msg.result.content[0].thinking.signature.?);

    // Free duped strings
    allocator.free(msg.result.model);
    allocator.free(msg.result.content[0].thinking.thinking);
    allocator.free(msg.result.content[0].thinking.signature.?);
    allocator.free(msg.result.content);
}

test "serialize and deserialize tool_use with thought_signature" {
    const allocator = std.testing.allocator;
    const content = [_]types.ContentBlock{
        .{ .tool_use = .{
            .id = "toolu_456",
            .name = "calculator",
            .input_json = "{\"expr\":\"2+2\"}",
            .thought_signature = "tool_thought_sig",
        } },
    };
    const result = types.AssistantMessage{
        .content = &content,
        .usage = .{ .output_tokens = 10 },
        .stop_reason = .tool_use,
        .model = "test-model",
        .timestamp = 3000,
    };

    const json = try serializeResult(result, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .result);
    try std.testing.expectEqual(@as(usize, 1), msg.result.content.len);
    try std.testing.expect(msg.result.content[0] == .tool_use);
    try std.testing.expectEqualStrings("toolu_456", msg.result.content[0].tool_use.id);
    try std.testing.expectEqualStrings("calculator", msg.result.content[0].tool_use.name);
    try std.testing.expectEqualStrings("{\"expr\":\"2+2\"}", msg.result.content[0].tool_use.input_json);
    try std.testing.expect(msg.result.content[0].tool_use.thought_signature != null);
    try std.testing.expectEqualStrings("tool_thought_sig", msg.result.content[0].tool_use.thought_signature.?);

    // Free duped strings
    allocator.free(msg.result.model);
    allocator.free(msg.result.content[0].tool_use.id);
    allocator.free(msg.result.content[0].tool_use.name);
    allocator.free(msg.result.content[0].tool_use.input_json);
    allocator.free(msg.result.content[0].tool_use.thought_signature.?);
    allocator.free(msg.result.content);
}
