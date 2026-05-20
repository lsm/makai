const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const agent_types = @import("agent_types");
const common = @import("tools/common");

pub fn editTool() agent_types.AgentTool {
    return .{
        .label = "File Edit",
        .name = "file_edit",
        .description = "Edit text files using find_replace, line_replace, insert, delete, hash_replace, or hash_range_replace. Hash operations reject stale reads before mutation.",
        .short_description = "Edit file; supports hash-anchored replacements.",
        .parameters_schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"operation\":{\"type\":\"string\"},\"line\":{\"type\":\"integer\"},\"line_hash\":{\"type\":\"string\"},\"start_line\":{\"type\":\"integer\"},\"start_hash\":{\"type\":\"string\"},\"end_line\":{\"type\":\"integer\"},\"end_hash\":{\"type\":\"string\"},\"new_content\":{\"type\":\"string\"},\"old\":{\"type\":\"string\"}},\"required\":[\"path\",\"operation\"]}",
        .execute = executeEdit,
    };
}

pub fn executeEdit(
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?agent_types.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!agent_types.AgentToolResult {
    _ = tool_call_id;
    _ = cancel_token;
    _ = on_update_ctx;
    _ = on_update;
    const args = try parseArgs(allocator, args_json);
    defer args.deinit();
    const original = try compat.fs.readFileAlloc(allocator, compat.fs.getCwd(), args.path, 64 * 1024 * 1024);
    defer allocator.free(original);
    const edited = try applyEdit(allocator, original, args);
    defer allocator.free(edited);
    try compat.fs.writeFile(compat.fs.getCwd(), args.path, edited);
    const body = try std.fmt.allocPrint(allocator, "ok {d} {s}", .{ edited.len, args.path });
    defer allocator.free(body);
    const details = try common.telemetryDetails(allocator, original.len, body.len, false);
    defer allocator.free(details);
    return common.makeTextResult(allocator, body, details);
}

pub fn applyEdit(allocator: std.mem.Allocator, original: []const u8, args: ParsedArgs) ![]u8 {
    if (std.mem.eql(u8, args.operation, "hash_replace")) {
        const line_no = args.line orelse return error.InvalidArguments;
        const expected = args.line_hash orelse return error.InvalidArguments;
        const new_content = args.new_content orelse return error.InvalidArguments;
        const line = getLine(original, line_no) orelse return error.LineOutOfRange;
        const actual = common.lineHash(line);
        if (!std.mem.eql(u8, expected, &actual)) return error.StaleHash;
        return replaceLine(allocator, original, line_no, new_content);
    }
    if (std.mem.eql(u8, args.operation, "hash_range_replace")) {
        const start_line = args.start_line orelse return error.InvalidArguments;
        const end_line = args.end_line orelse return error.InvalidArguments;
        const start_hash = args.start_hash orelse return error.InvalidArguments;
        const end_hash = args.end_hash orelse return error.InvalidArguments;
        const new_content = args.new_content orelse return error.InvalidArguments;
        const first = getLine(original, start_line) orelse return error.LineOutOfRange;
        const last = getLine(original, end_line) orelse return error.LineOutOfRange;
        const actual_start = common.lineHash(first);
        const actual_end = common.lineHash(last);
        if (!std.mem.eql(u8, start_hash, &actual_start) or !std.mem.eql(u8, end_hash, &actual_end)) return error.StaleHash;
        return replaceRange(allocator, original, start_line, end_line, new_content);
    }
    if (std.mem.eql(u8, args.operation, "line_replace")) {
        return replaceLine(allocator, original, args.line orelse return error.InvalidArguments, args.new_content orelse return error.InvalidArguments);
    }
    if (std.mem.eql(u8, args.operation, "find_replace")) {
        const old = args.old orelse return error.InvalidArguments;
        const new_content = args.new_content orelse return error.InvalidArguments;
        const idx = std.mem.indexOf(u8, original, old) orelse return error.PatternNotFound;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, original[0..idx]);
        try out.appendSlice(allocator, new_content);
        try out.appendSlice(allocator, original[idx + old.len ..]);
        return out.toOwnedSlice(allocator);
    }
    if (std.mem.eql(u8, args.operation, "insert")) {
        return insertBeforeLine(allocator, original, args.line orelse return error.InvalidArguments, args.new_content orelse return error.InvalidArguments);
    }
    if (std.mem.eql(u8, args.operation, "delete")) {
        const line = args.line orelse return error.InvalidArguments;
        return replaceRange(allocator, original, line, line, "");
    }
    return error.InvalidOperation;
}

pub const ParsedArgs = struct {
    parsed: ?std.json.Parsed(std.json.Value) = null,
    path: []const u8 = "",
    operation: []const u8,
    line: ?usize = null,
    line_hash: ?[]const u8 = null,
    start_line: ?usize = null,
    start_hash: ?[]const u8 = null,
    end_line: ?usize = null,
    end_hash: ?[]const u8 = null,
    old: ?[]const u8 = null,
    new_content: ?[]const u8 = null,

    fn deinit(self: *const ParsedArgs) void {
        if (self.parsed) |parsed| parsed.deinit();
    }
};

fn parseArgs(allocator: std.mem.Allocator, args_json: []const u8) !ParsedArgs {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const obj = parsed.value.object;
    return .{
        .parsed = parsed,
        .path = try reqString(obj, "path"),
        .operation = try reqString(obj, "operation"),
        .line = optUsize(obj, "line"),
        .line_hash = optString(obj, "line_hash"),
        .start_line = optUsize(obj, "start_line"),
        .start_hash = optString(obj, "start_hash"),
        .end_line = optUsize(obj, "end_line"),
        .end_hash = optString(obj, "end_hash"),
        .old = optString(obj, "old"),
        .new_content = optString(obj, "new_content"),
    };
}

fn reqString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = obj.get(key) orelse return error.InvalidArguments;
    if (value != .string) return error.InvalidArguments;
    return value.string;
}

fn optString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn optUsize(obj: std.json.ObjectMap, key: []const u8) ?usize {
    const value = obj.get(key) orelse return null;
    return if (value == .integer and value.integer > 0) @intCast(value.integer) else null;
}

fn getLine(text: []const u8, line_no: usize) ?[]const u8 {
    var current: usize = 1;
    var start: usize = 0;
    while (start <= text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        if (current == line_no) return text[start..end];
        if (end == text.len) break;
        start = end + 1;
        current += 1;
    }
    return null;
}

fn lineBounds(text: []const u8, line_no: usize) ?struct { start: usize, end_with_newline: usize, end_without_newline: usize } {
    var current: usize = 1;
    var start: usize = 0;
    while (start <= text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        if (current == line_no) return .{ .start = start, .end_without_newline = end, .end_with_newline = if (end < text.len) end + 1 else end };
        if (end == text.len) break;
        start = end + 1;
        current += 1;
    }
    return null;
}

fn replaceLine(allocator: std.mem.Allocator, text: []const u8, line_no: usize, replacement: []const u8) ![]u8 {
    return replaceRange(allocator, text, line_no, line_no, replacement);
}

fn replaceRange(allocator: std.mem.Allocator, text: []const u8, start_line: usize, end_line: usize, replacement: []const u8) ![]u8 {
    if (end_line < start_line) return error.InvalidArguments;
    const start = lineBounds(text, start_line) orelse return error.LineOutOfRange;
    const end = lineBounds(text, end_line) orelse return error.LineOutOfRange;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, text[0..start.start]);
    try out.appendSlice(allocator, replacement);
    if (replacement.len > 0 and end.end_with_newline < text.len and (replacement[replacement.len - 1] != '\n')) try out.append(allocator, '\n');
    try out.appendSlice(allocator, text[end.end_with_newline..]);
    return out.toOwnedSlice(allocator);
}

fn insertBeforeLine(allocator: std.mem.Allocator, text: []const u8, line_no: usize, insertion: []const u8) ![]u8 {
    const bounds = lineBounds(text, line_no) orelse return error.LineOutOfRange;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, text[0..bounds.start]);
    try out.appendSlice(allocator, insertion);
    if (insertion.len > 0 and insertion[insertion.len - 1] != '\n') try out.append(allocator, '\n');
    try out.appendSlice(allocator, text[bounds.start..]);
    return out.toOwnedSlice(allocator);
}

test "hash_replace rejects stale hash" {
    const allocator = std.testing.allocator;
    const args = ParsedArgs{ .operation = "hash_replace", .line = 1, .line_hash = "00", .new_content = "new" };
    try std.testing.expectError(error.StaleHash, applyEdit(allocator, "old\n", args));
}

test "hash_replace detects concurrent modification" {
    const allocator = std.testing.allocator;
    const read_hash = common.lineHash("before");
    const args = ParsedArgs{ .operation = "hash_replace", .line = 1, .line_hash = &read_hash, .new_content = "after" };
    try std.testing.expectError(error.StaleHash, applyEdit(allocator, "changed\n", args));
}

test "hash_range_replace verifies both endpoints" {
    const allocator = std.testing.allocator;
    const h1 = common.lineHash("one");
    const h3 = common.lineHash("three");
    const args = ParsedArgs{ .operation = "hash_range_replace", .start_line = 1, .start_hash = &h1, .end_line = 3, .end_hash = &h3, .new_content = "merged" };
    const out = try applyEdit(allocator, "one\ntwo\nthree\nfour\n", args);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("merged\nfour\n", out);
}

test "hash collision tolerance still checks current matching hash" {
    const allocator = std.testing.allocator;
    const hash = common.lineHash("same");
    const args = ParsedArgs{ .operation = "hash_replace", .line = 1, .line_hash = &hash, .new_content = "new" };
    const out = try applyEdit(allocator, "same\n", args);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("new", out);
}
