const std = @import("std");

pub const JsonWriter = struct {
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    depth: usize,
    needs_comma: bool,

    pub fn init(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator) JsonWriter {
        return JsonWriter{
            .buffer = buffer,
            .allocator = allocator,
            .depth = 0,
            .needs_comma = false,
        };
    }

    // Object methods
    pub fn beginObject(self: *JsonWriter) !void {
        try self.writeCommaIfNeeded();
        try self.buffer.append(self.allocator, '{');
        self.depth += 1;
        self.needs_comma = false;
    }

    pub fn endObject(self: *JsonWriter) !void {
        try self.buffer.append(self.allocator, '}');
        self.depth -= 1;
        self.needs_comma = true;
    }

    // Array methods
    pub fn beginArray(self: *JsonWriter) !void {
        try self.writeCommaIfNeeded();
        try self.buffer.append(self.allocator, '[');
        self.depth += 1;
        self.needs_comma = false;
    }

    pub fn endArray(self: *JsonWriter) !void {
        try self.buffer.append(self.allocator, ']');
        self.depth -= 1;
        self.needs_comma = true;
    }

    // Key-value writing (for objects)
    pub fn writeKey(self: *JsonWriter, key: []const u8) !void {
        try self.writeCommaIfNeeded();
        try self.writeEscapedString(key);
        try self.buffer.append(self.allocator, ':');
        self.needs_comma = false;
    }

    // Value writing
    pub fn writeString(self: *JsonWriter, value: []const u8) !void {
        try self.writeCommaIfNeeded();
        try self.writeEscapedString(value);
        self.needs_comma = true;
    }

    pub fn writeInt(self: *JsonWriter, value: anytype) !void {
        try self.writeCommaIfNeeded();
        try self.buffer.print(self.allocator, "{d}", .{value});
        self.needs_comma = true;
    }

    pub fn writeFloat(self: *JsonWriter, value: f32) !void {
        try self.writeCommaIfNeeded();
        try self.buffer.print(self.allocator, "{d}", .{value});
        self.needs_comma = true;
    }

    pub fn writeBool(self: *JsonWriter, value: bool) !void {
        try self.writeCommaIfNeeded();
        try self.buffer.appendSlice(self.allocator, if (value) "true" else "false");
        self.needs_comma = true;
    }

    pub fn writeNull(self: *JsonWriter) !void {
        try self.writeCommaIfNeeded();
        try self.buffer.appendSlice(self.allocator, "null");
        self.needs_comma = true;
    }

    /// Write pre-serialized JSON directly without escaping.
    /// Useful for embedding already-serialized JSON strings (e.g., schema definitions).
    pub fn writeRawJson(self: *JsonWriter, json_string: []const u8) !void {
        try self.writeCommaIfNeeded();
        try self.buffer.appendSlice(self.allocator, json_string);
        self.needs_comma = true;
    }

    // Combined key:value for convenience
    pub fn writeStringField(self: *JsonWriter, key: []const u8, value: []const u8) !void {
        try self.writeKey(key);
        try self.writeString(value);
    }

    pub fn writeIntField(self: *JsonWriter, key: []const u8, value: anytype) !void {
        try self.writeKey(key);
        try self.writeInt(value);
    }

    pub fn writeBoolField(self: *JsonWriter, key: []const u8, value: bool) !void {
        try self.writeKey(key);
        try self.writeBool(value);
    }

    // Helper for string escaping
    fn writeEscapedString(self: *JsonWriter, s: []const u8) !void {
        try self.buffer.append(self.allocator, '"');
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            switch (c) {
                '"' => try self.buffer.appendSlice(self.allocator, "\\\""),
                '\\' => try self.buffer.appendSlice(self.allocator, "\\\\"),
                '\n' => try self.buffer.appendSlice(self.allocator, "\\n"),
                '\r' => try self.buffer.appendSlice(self.allocator, "\\r"),
                '\t' => try self.buffer.appendSlice(self.allocator, "\\t"),
                0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                    // Other control characters
                    try self.buffer.print(self.allocator, "\\u{x:0>4}", .{c});
                },
                0x80...0xFF => {
                    const len = std.unicode.utf8ByteSequenceLength(c) catch {
                        try self.buffer.appendSlice(self.allocator, "\\ufffd");
                        i += 1;
                        continue;
                    };
                    if (i + len <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + len])) {
                        try self.buffer.appendSlice(self.allocator, s[i .. i + len]);
                        i += len;
                        continue;
                    }
                    try self.buffer.appendSlice(self.allocator, "\\ufffd");
                },
                else => try self.buffer.append(self.allocator, c),
            }
            i += 1;
        }
        try self.buffer.append(self.allocator, '"');
    }

    fn writeCommaIfNeeded(self: *JsonWriter) !void {
        if (self.needs_comma) {
            try self.buffer.append(self.allocator, ',');
        }
    }
};

// Get the result as a slice
pub fn getResult(writer: *JsonWriter) []const u8 {
    return writer.buffer.items;
}

test "build anthropic request" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    var writer = JsonWriter.init(&buffer, allocator);

    // Build: {"model":"claude-3","max_tokens":1024,"messages":[{"role":"user","content":"Hello"}]}
    try writer.beginObject();
    try writer.writeStringField("model", "claude-3");
    try writer.writeIntField("max_tokens", 1024);
    try writer.writeKey("messages");
    try writer.beginArray();
    try writer.beginObject();
    try writer.writeStringField("role", "user");
    try writer.writeStringField("content", "Hello");
    try writer.endObject();
    try writer.endArray();
    try writer.endObject();

    const result = getResult(&writer);
    const expected = "{\"model\":\"claude-3\",\"max_tokens\":1024,\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}";

    try std.testing.expectEqualStrings(expected, result);
}

test "string escaping" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    var writer = JsonWriter.init(&buffer, allocator);

    try writer.beginObject();
    try writer.writeStringField("test", "Hello \"world\"\n\tTab\\Backslash");
    try writer.endObject();

    const result = getResult(&writer);
    const expected = "{\"test\":\"Hello \\\"world\\\"\\n\\tTab\\\\Backslash\"}";

    try std.testing.expectEqualStrings(expected, result);
}

test "control characters escape as unicode sequences" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    var writer = JsonWriter.init(&buffer, allocator);

    const value = [_]u8{ 'A', 0x01, 'B' };

    try writer.beginObject();
    try writer.writeStringField("control", &value);
    try writer.endObject();

    const result = getResult(&writer);
    const expected = "{\"control\":\"A\\u0001B\"}";

    try std.testing.expectEqualStrings(expected, result);
}

test "utf8 string bytes are preserved" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    var writer = JsonWriter.init(&buffer, allocator);
    try writer.beginObject();
    try writer.writeStringField("text", "café 🚀");
    try writer.endObject();

    try std.testing.expectEqualStrings("{\"text\":\"café 🚀\"}", getResult(&writer));
}

test "invalid utf8 bytes are replaced" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    var writer = JsonWriter.init(&buffer, allocator);
    const invalid = [_]u8{ 'a', 0x80, 'b' };
    try writer.beginObject();
    try writer.writeStringField("text", &invalid);
    try writer.endObject();

    try std.testing.expectEqualStrings("{\"text\":\"a\\ufffdb\"}", getResult(&writer));
}

test "nested objects and arrays" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    var writer = JsonWriter.init(&buffer, allocator);

    try writer.beginObject();
    try writer.writeStringField("name", "test");
    try writer.writeKey("nested");
    try writer.beginObject();
    try writer.writeIntField("value", 42);
    try writer.writeBoolField("active", true);
    try writer.endObject();
    try writer.writeKey("items");
    try writer.beginArray();
    try writer.writeInt(1);
    try writer.writeInt(2);
    try writer.writeInt(3);
    try writer.endArray();
    try writer.endObject();

    const result = getResult(&writer);
    const expected = "{\"name\":\"test\",\"nested\":{\"value\":42,\"active\":true},\"items\":[1,2,3]}";

    try std.testing.expectEqualStrings(expected, result);
}

test "null and boolean values" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    var writer = JsonWriter.init(&buffer, allocator);

    try writer.beginObject();
    try writer.writeKey("nullable");
    try writer.writeNull();
    try writer.writeBoolField("enabled", false);
    try writer.endObject();

    const result = getResult(&writer);
    const expected = "{\"nullable\":null,\"enabled\":false}";

    try std.testing.expectEqualStrings(expected, result);
}

test "float values" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    var writer = JsonWriter.init(&buffer, allocator);

    try writer.beginObject();
    try writer.writeKey("temperature");
    try writer.writeFloat(0.7);
    try writer.endObject();

    const result = getResult(&writer);

    // Float formatting may vary slightly, so just check structure
    try std.testing.expect(std.mem.startsWith(u8, result, "{\"temperature\":0.7"));
    try std.testing.expect(std.mem.endsWith(u8, result, "}"));
}

test "writeRawJson embeds pre-serialized JSON" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    var writer = JsonWriter.init(&buffer, allocator);

    // Simulate embedding a pre-serialized schema
    const schema_json = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}}}";

    try writer.beginObject();
    try writer.writeKey("name");
    try writer.writeString("my_tool");
    try writer.writeKey("parameters");
    try writer.writeRawJson(schema_json);
    try writer.endObject();

    const result = getResult(&writer);
    const expected = "{\"name\":\"my_tool\",\"parameters\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}}}}";

    try std.testing.expectEqualStrings(expected, result);
}
