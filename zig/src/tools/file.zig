const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const agent_types = @import("agent_types");
const common = @import("tools/common");

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

pub fn readTool() agent_types.AgentTool {
    return .{
        .label = "File Read",
        .name = "file_read",
        .description = "Read a UTF-8 text file. Output includes per-line content hashes as line_no:hash|content for hash-anchored edits.",
        .short_description = "Read file with line hashes.",
        .parameters_schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}",
        .execute = executeRead,
    };
}

pub fn writeTool() agent_types.AgentTool {
    return .{
        .label = "File Write",
        .name = "file_write",
        .description = "Write full text content to a file, replacing any existing content.",
        .short_description = "Write file content.",
        .parameters_schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"},\"compact_output\":{\"type\":\"boolean\"}},\"required\":[\"path\",\"content\"]}",
        .execute = executeWrite,
    };
}

pub fn statTool() agent_types.AgentTool {
    return .{
        .label = "File Stat",
        .name = "file_stat",
        .description = "Return file size and kind for a path.",
        .short_description = "Stat file path.",
        .parameters_schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"compact_output\":{\"type\":\"boolean\"}},\"required\":[\"path\"]}",
        .execute = executeStat,
    };
}

pub fn executeRead(
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
    const content = try compat.fs.readFileAlloc(allocator, compat.fs.getCwd(), args.path, 64 * 1024 * 1024);
    defer allocator.free(content);
    const hashed = try formatWithLineHashes(allocator, content);
    defer allocator.free(hashed);
    const details = try common.telemetryDetails(allocator, content.len, hashed.len, false);
    defer allocator.free(details);
    return common.makeTextResult(allocator, hashed, details);
}

pub fn executeWrite(
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
    const content = args.content orelse return error.InvalidArguments;
    try compat.fs.writeFile(compat.fs.getCwd(), args.path, content);
    const body = if (args.compact_output)
        try std.fmt.allocPrint(allocator, "ok {d} {s}", .{ content.len, args.path })
    else
        try std.fmt.allocPrint(allocator, "wrote {d} bytes to {s}", .{ content.len, args.path });
    defer allocator.free(body);
    const details = try common.telemetryDetails(allocator, content.len, body.len, false);
    defer allocator.free(details);
    return common.makeTextResult(allocator, body, details);
}

pub fn executeStat(
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
    const stat = try compat.fs.getCwd().statFile(defaultIo(), args.path, .{});
    const kind = @tagName(stat.kind);
    const body = if (args.compact_output)
        try std.fmt.allocPrint(allocator, "{s} {s} {d}", .{ args.path, kind, stat.size })
    else
        try std.fmt.allocPrint(allocator, "path: {s}\nkind: {s}\nsize: {d}", .{ args.path, kind, stat.size });
    defer allocator.free(body);
    const details = try common.telemetryDetails(allocator, body.len, body.len, false);
    defer allocator.free(details);
    return common.makeTextResult(allocator, body, details);
}

pub fn formatWithLineHashes(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var line_no: usize = 1;
    var start: usize = 0;
    while (start <= content.len) {
        const end = std.mem.indexOfScalarPos(u8, content, start, '\n') orelse content.len;
        if (start == content.len and end == content.len) break;
        const line = content[start..end];
        const hash = common.lineHash(line);
        const formatted = try std.fmt.allocPrint(allocator, "{d}:{s}|{s}\n", .{ line_no, &hash, line });
        defer allocator.free(formatted);
        try out.appendSlice(allocator, formatted);
        line_no += 1;
        if (end == content.len) break;
        start = end + 1;
    }
    return out.toOwnedSlice(allocator);
}

const ParsedArgs = struct {
    parsed: std.json.Parsed(std.json.Value),
    path: []const u8,
    content: ?[]const u8 = null,
    compact_output: bool = false,

    fn deinit(self: *const ParsedArgs) void {
        self.parsed.deinit();
    }
};

fn parseArgs(allocator: std.mem.Allocator, args_json: []const u8) !ParsedArgs {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const obj = parsed.value.object;
    const path_value = obj.get("path") orelse return error.InvalidArguments;
    if (path_value != .string) return error.InvalidArguments;
    const content = if (obj.get("content")) |value| blk: {
        if (value != .string) return error.InvalidArguments;
        break :blk value.string;
    } else null;
    const compact = if (obj.get("compact_output")) |value| value == .bool and value.bool else false;
    return .{ .parsed = parsed, .path = path_value.string, .content = content, .compact_output = compact };
}

test "file_read output includes line hashes" {
    const allocator = std.testing.allocator;
    const content = try formatWithLineHashes(allocator, "alpha\nbeta");
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "|alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "|beta") != null);
}
