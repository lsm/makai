//! Streaming JSON parser for handling partial/incomplete JSON.
//!
//! This is useful for parsing tool call arguments during streaming,
//! before the complete JSON is received.
//!
//! Based on the approach from partial-json npm package:
//! https://www.npmjs.com/package/partial-json

const std = @import("std");

/// Error types for streaming JSON parsing
pub const StreamingJsonError = error{
    /// The JSON is completely malformed (not just incomplete)
    MalformedJson,
    /// Out of memory
    OutOfMemory,
    /// Invalid UTF-8
    InvalidUtf8,
};

/// Options for what types are allowed to be partial
pub const AllowPartial = struct {
    str: bool = true,
    num: bool = true,
    arr: bool = true,
    obj: bool = true,
    null: bool = true,
    bool: bool = true,

    /// Allow all types to be partial (default)
    pub const all = AllowPartial{
        .str = true,
        .num = true,
        .arr = true,
        .obj = true,
        .null = true,
        .bool = true,
    };

    /// Don't allow any partial types (only complete values)
    pub const none = AllowPartial{
        .str = false,
        .num = false,
        .arr = false,
        .obj = false,
        .null = false,
        .bool = false,
    };
};

/// State tracker for the parser
const ParserState = struct {
    json: []const u8,
    index: usize,
    allow: AllowPartial,

    fn currentChar(self: ParserState) ?u8 {
        if (self.index >= self.json.len) return null;
        return self.json[self.index];
    }

    fn peek(self: ParserState, offset: usize) ?u8 {
        if (self.index + offset >= self.json.len) return null;
        return self.json[self.index + offset];
    }

    fn remaining(self: ParserState) []const u8 {
        if (self.index >= self.json.len) return "";
        return self.json[self.index..];
    }

    fn advance(self: *ParserState) void {
        self.index += 1;
    }

    fn skipWhitespace(self: *ParserState) void {
        while (self.index < self.json.len) {
            switch (self.json[self.index]) {
                ' ', '\n', '\r', '\t' => self.advance(),
                else => break,
            }
        }
    }
};

/// Parse potentially incomplete JSON, returning best-guess value as std.json.Value
pub fn parsePartial(allocator: std.mem.Allocator, json: []const u8) StreamingJsonError!std.json.Value {
    return parsePartialWithOptions(allocator, json, AllowPartial.all);
}

/// Parse potentially incomplete JSON with specific partial options
pub fn parsePartialWithOptions(allocator: std.mem.Allocator, json: []const u8, allow: AllowPartial) StreamingJsonError!std.json.Value {
    // Trim whitespace
    const trimmed = std.mem.trim(u8, json, " \t\n\r");
    if (trimmed.len == 0) {
        return StreamingJsonError.MalformedJson;
    }

    var state = ParserState{
        .json = trimmed,
        .index = 0,
        .allow = allow,
    };

    return parseValue(allocator, &state);
}

/// Parse with a specific type (using the inferred complete JSON)
pub fn parsePartialTyped(comptime T: type, allocator: std.mem.Allocator, json: []const u8) StreamingJsonError!T {
    const value = try parsePartial(allocator, json);
    defer freeJsonValue(allocator, value);

    // Parse the value into the target type
    // We need to serialize the value back to JSON and parse it as the target type
    var buf = try std.ArrayList(u8).initCapacity(allocator, json.len + 32);
    defer buf.deinit(allocator);

    try stringifyValue(value, buf.writer(allocator));

    const parsed = std.json.parseFromSliceLeaky(T, allocator, buf.items, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch {
        return StreamingJsonError.MalformedJson;
    };

    return parsed;
}

/// Simple JSON stringifier for std.json.Value
fn stringifyValue(value: std.json.Value, writer: anytype) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try writer.print("{}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .number_string => |s| try writer.writeAll(s),
        .string => |s| {
            try writer.writeByte('"');
            for (s) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeByte('"');
        },
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try stringifyValue(item, writer);
            }
            try writer.writeByte(']');
        },
        .object => |obj| {
            try writer.writeByte('{');
            var iter = obj.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                // Stringify key
                try stringifyValue(.{ .string = entry.key_ptr.* }, writer);
                try writer.writeByte(':');
                try stringifyValue(entry.value_ptr.*, writer);
            }
            try writer.writeByte('}');
        },
    }
}

/// Parse any JSON value
fn parseValue(allocator: std.mem.Allocator, state: *ParserState) StreamingJsonError!std.json.Value {
    state.skipWhitespace();

    if (state.index >= state.json.len) {
        return StreamingJsonError.MalformedJson;
    }

    const char = state.currentChar() orelse return StreamingJsonError.MalformedJson;

    return switch (char) {
        '"' => parseString(allocator, state),
        '{' => parseObject(allocator, state),
        '[' => parseArray(allocator, state),
        'n' => parseNull(state),
        't' => parseTrue(state),
        'f' => parseFalse(state),
        '-', '0'...'9' => parseNumber(state),
        else => StreamingJsonError.MalformedJson,
    };
}

/// Unescape a JSON string content
fn unescapeString(allocator: std.mem.Allocator, content: []const u8) StreamingJsonError![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, content.len);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '\\') {
            if (i + 1 >= content.len) {
                // Incomplete escape at end - just stop
                break;
            }
            const escaped = content[i + 1];
            switch (escaped) {
                '"' => try result.append(allocator, '"'),
                '\\' => try result.append(allocator, '\\'),
                '/' => try result.append(allocator, '/'),
                'n' => try result.append(allocator, '\n'),
                'r' => try result.append(allocator, '\r'),
                't' => try result.append(allocator, '\t'),
                'b' => try result.append(allocator, 0x08),
                'f' => try result.append(allocator, 0x0c),
                'u' => {
                    // Unicode escape \uXXXX
                    if (i + 5 >= content.len) {
                        // Incomplete unicode escape - skip
                        break;
                    }
                    const hex = content[i + 2 .. i + 6];
                    const code_point = std.fmt.parseInt(u21, hex, 16) catch 0xFFFD; // replacement char on error

                    // Convert to UTF-8
                    var utf8_buf: [4]u8 = undefined;
                    const utf8_len = std.unicode.utf8Encode(code_point, &utf8_buf) catch blk: {
                        // Use replacement character on error
                        utf8_buf[0] = 0xEF;
                        utf8_buf[1] = 0xBF;
                        utf8_buf[2] = 0xBD;
                        break :blk 3;
                    };
                    try result.appendSlice(allocator, utf8_buf[0..utf8_len]);
                    i += 4; // Skip XXXX (we'll add 2 more below)
                },
                else => {
                    // Unknown escape - just keep the character
                    try result.append(allocator, escaped);
                },
            }
            i += 2;
        } else {
            try result.append(allocator, content[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Parse a string value
fn parseString(allocator: std.mem.Allocator, state: *ParserState) StreamingJsonError!std.json.Value {
    std.debug.assert(state.currentChar() == '"');
    state.advance(); // Skip opening quote

    const start = state.index;
    var escape = false;
    var needs_unescaping = false;

    // Find the end of the string
    while (state.index < state.json.len) {
        const c = state.json[state.index];
        if (escape) {
            escape = false;
            needs_unescaping = true;
        } else if (c == '\\') {
            escape = true;
        } else if (c == '"') {
            break;
        }
        state.advance();
    }

    // Check if we found the closing quote
    const has_closing_quote = state.currentChar() == '"';
    const end = state.index;

    if (!has_closing_quote and !state.allow.str) {
        return StreamingJsonError.MalformedJson;
    }

    // Get the string content
    var content = state.json[start..end];

    // Handle incomplete escape sequences at the end
    if (!has_closing_quote and content.len > 0 and content[content.len - 1] == '\\') {
        // Remove the trailing backslash
        content = content[0 .. content.len - 1];
    }

    // Skip closing quote if present
    if (has_closing_quote) {
        state.advance();
    }

    // Unescape if needed
    if (needs_unescaping) {
        const unescaped = try unescapeString(allocator, content);
        return std.json.Value{ .string = unescaped };
    } else {
        // No escapes, just dupe the string
        const str = try allocator.dupe(u8, content);
        return std.json.Value{ .string = str };
    }
}

/// Parse an object
fn parseObject(allocator: std.mem.Allocator, state: *ParserState) StreamingJsonError!std.json.Value {
    std.debug.assert(state.currentChar() == '{');
    state.advance(); // Skip opening brace

    var obj = std.json.ObjectMap.init(allocator);
    errdefer obj.deinit();

    state.skipWhitespace();

    // Handle empty object or end of input
    if (state.index >= state.json.len) {
        if (state.allow.obj) {
            return std.json.Value{ .object = obj };
        }
        return StreamingJsonError.MalformedJson;
    }

    if (state.currentChar() == '}') {
        state.advance();
        return std.json.Value{ .object = obj };
    }

    while (true) {
        state.skipWhitespace();

        // Check for end of input
        if (state.index >= state.json.len) {
            if (state.allow.obj) {
                return std.json.Value{ .object = obj };
            }
            return StreamingJsonError.MalformedJson;
        }

        // Check for end of object
        if (state.currentChar() == '}') {
            state.advance();
            return std.json.Value{ .object = obj };
        }

        // Parse key
        if (state.currentChar() != '"') {
            if (state.allow.obj) {
                return std.json.Value{ .object = obj };
            }
            return StreamingJsonError.MalformedJson;
        }

        const key_value = parseString(allocator, state) catch {
            if (state.allow.obj) {
                return std.json.Value{ .object = obj };
            }
            return StreamingJsonError.MalformedJson;
        };

        const key = key_value.string;

        state.skipWhitespace();

        // Check for colon
        if (state.index >= state.json.len) {
            allocator.free(key);
            if (state.allow.obj) {
                return std.json.Value{ .object = obj };
            }
            return StreamingJsonError.MalformedJson;
        }

        if (state.currentChar() != ':') {
            allocator.free(key);
            if (state.allow.obj) {
                return std.json.Value{ .object = obj };
            }
            return StreamingJsonError.MalformedJson;
        }
        state.advance(); // Skip colon

        state.skipWhitespace();

        // Parse value
        const value = parseValue(allocator, state) catch {
            allocator.free(key);
            if (state.allow.obj) {
                return std.json.Value{ .object = obj };
            }
            return StreamingJsonError.MalformedJson;
        };

        try obj.put(key, value);

        state.skipWhitespace();

        // Check for comma or end
        if (state.index >= state.json.len) {
            if (state.allow.obj) {
                return std.json.Value{ .object = obj };
            }
            return StreamingJsonError.MalformedJson;
        }

        if (state.currentChar() == ',') {
            state.advance();
            // Continue to next key-value pair
        } else if (state.currentChar() == '}') {
            state.advance();
            return std.json.Value{ .object = obj };
        } else {
            if (state.allow.obj) {
                return std.json.Value{ .object = obj };
            }
            return StreamingJsonError.MalformedJson;
        }
    }
}

/// Parse an array
fn parseArray(allocator: std.mem.Allocator, state: *ParserState) StreamingJsonError!std.json.Value {
    std.debug.assert(state.currentChar() == '[');
    state.advance(); // Skip opening bracket

    var arr = std.json.Array.init(allocator);
    errdefer arr.deinit();

    state.skipWhitespace();

    // Handle empty array or end of input
    if (state.index >= state.json.len) {
        if (state.allow.arr) {
            return std.json.Value{ .array = arr };
        }
        return StreamingJsonError.MalformedJson;
    }

    if (state.currentChar() == ']') {
        state.advance();
        return std.json.Value{ .array = arr };
    }

    while (true) {
        state.skipWhitespace();

        // Check for end of input
        if (state.index >= state.json.len) {
            if (state.allow.arr) {
                return std.json.Value{ .array = arr };
            }
            return StreamingJsonError.MalformedJson;
        }

        // Check for end of array (empty slot after comma)
        if (state.currentChar() == ']') {
            state.advance();
            return std.json.Value{ .array = arr };
        }

        // Parse value
        const value = parseValue(allocator, state) catch {
            if (state.allow.arr) {
                return std.json.Value{ .array = arr };
            }
            return StreamingJsonError.MalformedJson;
        };

        try arr.append(value);

        state.skipWhitespace();

        // Check for comma or end
        if (state.index >= state.json.len) {
            if (state.allow.arr) {
                return std.json.Value{ .array = arr };
            }
            return StreamingJsonError.MalformedJson;
        }

        if (state.currentChar() == ',') {
            state.advance();
            // Continue to next value
        } else if (state.currentChar() == ']') {
            state.advance();
            return std.json.Value{ .array = arr };
        } else {
            if (state.allow.arr) {
                return std.json.Value{ .array = arr };
            }
            return StreamingJsonError.MalformedJson;
        }
    }
}

/// Parse null
fn parseNull(state: *ParserState) StreamingJsonError!std.json.Value {
    const remaining = state.remaining();

    if (std.mem.startsWith(u8, remaining, "null")) {
        state.index += 4;
        return std.json.Value.null;
    }

    // Check for partial null
    if (state.allow.null) {
        const partial_nulls = [_][]const u8{ "nul", "nu", "n" };
        for (partial_nulls) |partial| {
            if (std.mem.startsWith(u8, remaining, partial)) {
                state.index += partial.len;
                return std.json.Value.null;
            }
        }
    }

    return StreamingJsonError.MalformedJson;
}

/// Parse true
fn parseTrue(state: *ParserState) StreamingJsonError!std.json.Value {
    const remaining = state.remaining();

    if (std.mem.startsWith(u8, remaining, "true")) {
        state.index += 4;
        return std.json.Value{ .bool = true };
    }

    // Check for partial true
    if (state.allow.bool) {
        const partial_trues = [_][]const u8{ "tru", "tr", "t" };
        for (partial_trues) |partial| {
            if (std.mem.startsWith(u8, remaining, partial)) {
                state.index += partial.len;
                return std.json.Value{ .bool = true };
            }
        }
    }

    return StreamingJsonError.MalformedJson;
}

/// Parse false
fn parseFalse(state: *ParserState) StreamingJsonError!std.json.Value {
    const remaining = state.remaining();

    if (std.mem.startsWith(u8, remaining, "false")) {
        state.index += 5;
        return std.json.Value{ .bool = false };
    }

    // Check for partial false
    if (state.allow.bool) {
        const partial_falses = [_][]const u8{ "fals", "fal", "fa", "f" };
        for (partial_falses) |partial| {
            if (std.mem.startsWith(u8, remaining, partial)) {
                state.index += partial.len;
                return std.json.Value{ .bool = false };
            }
        }
    }

    return StreamingJsonError.MalformedJson;
}

/// Parse a number
fn parseNumber(state: *ParserState) StreamingJsonError!std.json.Value {
    const start = state.index;

    // Handle negative sign
    if (state.currentChar() == '-') {
        state.advance();
    }

    // Parse digits before decimal
    while (state.index < state.json.len) {
        const c = state.json[state.index];
        switch (c) {
            '0'...'9' => state.advance(),
            else => break,
        }
    }

    // Parse decimal part
    if (state.index < state.json.len and state.json[state.index] == '.') {
        state.advance();
        while (state.index < state.json.len) {
            const c = state.json[state.index];
            switch (c) {
                '0'...'9' => state.advance(),
                else => break,
            }
        }
    }

    // Parse exponent
    if (state.index < state.json.len and (state.json[state.index] == 'e' or state.json[state.index] == 'E')) {
        state.advance();

        // Handle exponent sign
        if (state.index < state.json.len and (state.json[state.index] == '+' or state.json[state.index] == '-')) {
            state.advance();
        }

        while (state.index < state.json.len) {
            const c = state.json[state.index];
            switch (c) {
                '0'...'9' => state.advance(),
                else => break,
            }
        }
    }

    const num_str = state.json[start..state.index];

    // Handle incomplete numbers
    if (num_str.len == 0 or (num_str.len == 1 and num_str[0] == '-')) {
        if (state.allow.num) {
            return std.json.Value{ .integer = 0 };
        }
        return StreamingJsonError.MalformedJson;
    }

    // Handle numbers ending with 'e' or 'E' (incomplete exponent)
    const last_char = num_str[num_str.len - 1];
    if (last_char == 'e' or last_char == 'E') {
        if (state.allow.num) {
            // Remove the trailing 'e' or 'E'
            const trimmed = num_str[0 .. num_str.len - 1];
            return parseNumberString(trimmed);
        }
        return StreamingJsonError.MalformedJson;
    }

    // Handle numbers ending with 'e+' or 'e-'
    if (num_str.len >= 2) {
        const second_last = num_str[num_str.len - 2];
        if ((second_last == 'e' or second_last == 'E') and (last_char == '+' or last_char == '-')) {
            if (state.allow.num) {
                // Remove the trailing exponent sign and 'e'
                const trimmed = num_str[0 .. num_str.len - 2];
                return parseNumberString(trimmed);
            }
            return StreamingJsonError.MalformedJson;
        }
    }

    // Handle numbers ending with '.'
    if (last_char == '.') {
        if (state.allow.num) {
            // Remove the trailing '.'
            const trimmed = num_str[0 .. num_str.len - 1];
            return parseNumberString(trimmed);
        }
        return StreamingJsonError.MalformedJson;
    }

    return parseNumberString(num_str);
}

/// Parse a number string into a JSON value
fn parseNumberString(num_str: []const u8) StreamingJsonError!std.json.Value {
    // Try integer first
    if (std.fmt.parseInt(i64, num_str, 10)) |int_val| {
        return std.json.Value{ .integer = int_val };
    } else |_| {
        // Try float
        if (std.fmt.parseFloat(f64, num_str)) |float_val| {
            return std.json.Value{ .float = float_val };
        } else |_| {
            return StreamingJsonError.MalformedJson;
        }
    }
}

/// Helper function to free a JSON value recursively
pub fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .object => |obj| {
            var mutable_obj = obj;
            var iter = mutable_obj.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            mutable_obj.deinit();
        },
        .array => |arr| {
            var mutable_arr = arr;
            for (mutable_arr.items) |item| {
                freeJsonValue(allocator, item);
            }
            mutable_arr.deinit();
        },
        else => {},
    }
}

// =============================================================================
// Tests
// =============================================================================

test "parse complete JSON string" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "\"hello world\"");
    defer freeJsonValue(allocator, result);

    try std.testing.expectEqualStrings("hello world", result.string);
}

test "parse partial JSON string" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "\"hello wo");
    defer freeJsonValue(allocator, result);

    try std.testing.expectEqualStrings("hello wo", result.string);
}

test "parse complete JSON object" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "{\"key\": \"value\"}");
    defer freeJsonValue(allocator, result);

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 1), result.object.count());
}

test "parse partial JSON object" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "{\"key\": \"val");
    defer freeJsonValue(allocator, result);

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 1), result.object.count());
}

test "parse partial JSON object - key only" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "{\"key\":");
    defer freeJsonValue(allocator, result);

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 0), result.object.count());
}

test "parse partial JSON object - empty" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "{");
    defer freeJsonValue(allocator, result);

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 0), result.object.count());
}

test "parse complete JSON array" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "[1, 2, 3]");
    defer freeJsonValue(allocator, result);

    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 3), result.array.items.len);
}

test "parse partial JSON array" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "[1, 2");
    defer freeJsonValue(allocator, result);

    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 2), result.array.items.len);
}

test "parse JSON numbers" {
    const allocator = std.testing.allocator;

    // Integer
    const int_result = try parsePartial(allocator, "42");
    try std.testing.expect(int_result == .integer);
    try std.testing.expectEqual(@as(i64, 42), int_result.integer);

    // Float
    const float_result = try parsePartial(allocator, "3.14");
    try std.testing.expect(float_result == .float);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), float_result.float, 0.001);

    // Negative
    const neg_result = try parsePartial(allocator, "-10");
    try std.testing.expect(neg_result == .integer);
    try std.testing.expectEqual(@as(i64, -10), neg_result.integer);

    // Scientific notation
    const sci_result = try parsePartial(allocator, "1e5");
    try std.testing.expect(sci_result == .float);
    try std.testing.expectApproxEqAbs(@as(f64, 100000.0), sci_result.float, 0.001);
}

test "parse partial JSON numbers" {
    const allocator = std.testing.allocator;

    // Number ending with decimal point
    const decimal_result = try parsePartial(allocator, "3.");
    try std.testing.expect(decimal_result == .integer);
    try std.testing.expectEqual(@as(i64, 3), decimal_result.integer);

    // Number ending with 'e'
    const exp_result = try parsePartial(allocator, "1e");
    try std.testing.expect(exp_result == .integer);
    try std.testing.expectEqual(@as(i64, 1), exp_result.integer);

    // Just negative sign
    const neg_result = try parsePartial(allocator, "-");
    try std.testing.expect(neg_result == .integer);
    try std.testing.expectEqual(@as(i64, 0), neg_result.integer);
}

test "parse JSON booleans" {
    const allocator = std.testing.allocator;

    const true_result = try parsePartial(allocator, "true");
    try std.testing.expect(true_result == .bool);
    try std.testing.expect(true_result.bool);

    const false_result = try parsePartial(allocator, "false");
    try std.testing.expect(false_result == .bool);
    try std.testing.expect(!false_result.bool);
}

test "parse partial JSON booleans" {
    const allocator = std.testing.allocator;

    const t_result = try parsePartial(allocator, "t");
    try std.testing.expect(t_result == .bool);
    try std.testing.expect(t_result.bool);

    const tr_result = try parsePartial(allocator, "tr");
    try std.testing.expect(tr_result == .bool);
    try std.testing.expect(tr_result.bool);

    const f_result = try parsePartial(allocator, "f");
    try std.testing.expect(f_result == .bool);
    try std.testing.expect(!f_result.bool);
}

test "parse JSON null" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "null");
    try std.testing.expect(result == .null);
}

test "parse partial JSON null" {
    const allocator = std.testing.allocator;

    const n_result = try parsePartial(allocator, "n");
    try std.testing.expect(n_result == .null);

    const nu_result = try parsePartial(allocator, "nu");
    try std.testing.expect(nu_result == .null);
}

test "parse nested partial JSON" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "{\"outer\": {\"inner\": \"val");
    defer freeJsonValue(allocator, result);

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 1), result.object.count());

    const outer_val = result.object.get("outer").?;
    try std.testing.expect(outer_val == .object);
    try std.testing.expectEqual(@as(usize, 1), outer_val.object.count());
}

test "parse array with partial objects" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "[{\"key\": \"value\"}, {\"key\": \"val");
    defer freeJsonValue(allocator, result);

    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 2), result.array.items.len);
}

test "parse escaped characters in string" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "\"hello\\nworld\"");
    defer freeJsonValue(allocator, result);

    try std.testing.expectEqualStrings("hello\nworld", result.string);
}

test "parse incomplete escaped string" {
    const allocator = std.testing.allocator;

    // String ending with backslash (incomplete escape)
    const result = try parsePartial(allocator, "\"hello\\");
    defer freeJsonValue(allocator, result);

    // Should handle gracefully - either return "hello" or "hello\"
    try std.testing.expect(result == .string);
}

test "parse complex nested structure" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "name": "test",
        \\  "values": [1, 2, 3],
        \\  "nested": {
        \\    "key": "value",
        \\    "partial": "incom
        \\  }
        \\}
    ;

    const result = try parsePartial(allocator, json);
    defer freeJsonValue(allocator, result);

    try std.testing.expect(result == .object);
}

test "parse with AllowPartial.none fails on incomplete" {
    const allocator = std.testing.allocator;

    const result = parsePartialWithOptions(allocator, "\"hello", AllowPartial.none);
    try std.testing.expectError(StreamingJsonError.MalformedJson, result);
}

test "parse complete JSON with AllowPartial.none succeeds" {
    const allocator = std.testing.allocator;

    const result = try parsePartialWithOptions(allocator, "\"hello\"", AllowPartial.none);
    defer freeJsonValue(allocator, result);

    try std.testing.expectEqualStrings("hello", result.string);
}

test "parse empty object" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "{}");
    defer freeJsonValue(allocator, result);

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 0), result.object.count());
}

test "parse empty array" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "[]");
    defer freeJsonValue(allocator, result);

    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 0), result.array.items.len);
}

test "parse whitespace handling" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "  { \"key\" : \"value\" }  ");
    defer freeJsonValue(allocator, result);

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 1), result.object.count());
}

test "parse typed partial JSON" {
    const allocator = std.testing.allocator;

    const TestStruct = struct {
        value: i32,
        active: bool,
    };

    // This test uses only value types (no allocated strings)
    const result = try parsePartialTyped(TestStruct, allocator, "{\"value\": 42, \"active\": true}");

    try std.testing.expectEqual(@as(i32, 42), result.value);
    try std.testing.expect(result.active);
}

test "parse tool call arguments - typical streaming case" {
    const allocator = std.testing.allocator;

    // Simulate streaming tool call arguments
    const partial1 = try parsePartial(allocator, "{\"location\": \"San");
    const partial2 = try parsePartial(allocator, "{\"location\": \"San Francisco");
    const partial3 = try parsePartial(allocator, "{\"location\": \"San Francisco\"");

    // All should parse successfully with increasing content
    try std.testing.expect(partial1 == .object);
    try std.testing.expect(partial2 == .object);
    try std.testing.expect(partial3 == .object);

    // Clean up
    freeJsonValue(allocator, partial1);
    freeJsonValue(allocator, partial2);
    freeJsonValue(allocator, partial3);
}

test "parse Unicode in string" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "\"Hello \\u0041\"");
    defer freeJsonValue(allocator, result);

    try std.testing.expectEqualStrings("Hello A", result.string);
}

test "parse multiple values in object" {
    const allocator = std.testing.allocator;

    const result = try parsePartial(allocator, "{\"a\": 1, \"b\": 2, \"c\": 3");
    defer freeJsonValue(allocator, result);

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 3), result.object.count());
}
