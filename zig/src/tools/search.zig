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

pub fn searchTool() agent_types.AgentTool {
    return .{
        .label = "Search Text",
        .name = "search_text",
        .description = "Search files for literal text under a root directory. Results use file:line:content format; large result sets are stored as artifacts.",
        .short_description = "Search text; large results become artifact.",
        .parameters_schema_json = "{\"type\":\"object\",\"properties\":{\"root\":{\"type\":\"string\"},\"query\":{\"type\":\"string\"}},\"required\":[\"root\",\"query\"]}",
        .execute = executeSearch,
    };
}

pub fn executeSearch(
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?agent_types.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!agent_types.AgentToolResult {
    _ = cancel_token;
    _ = on_update_ctx;
    _ = on_update;
    const parsed = try parseArgs(allocator, args_json);
    defer parsed.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var dir = try compat.fs.getCwd().openDir(defaultIo(), parsed.root, .{ .iterate = true });
    defer dir.close(defaultIo());
    try searchDir(allocator, &out, dir, parsed.root, parsed.query);
    const details = try common.telemetryDetails(allocator, out.items.len, out.items.len, false);
    defer allocator.free(details);
    const made = try common.makeTextResultWithArtifact(allocator, .{ .tool_name = "search_text", .call_id = tool_call_id, .text = out.items, .details_json = details });
    defer if (made.artifact_path) |path| allocator.free(path);
    return made.result;
}

fn searchDir(allocator: std.mem.Allocator, out: *std.ArrayList(u8), dir: compat.fs.Dir, prefix: []const u8, query: []const u8) !void {
    var it = dir.iterate();
    while (try it.next(defaultIo())) |entry| {
        if (entry.kind == .directory) continue;
        const path = try std.fs.path.join(allocator, &.{ prefix, entry.name });
        defer allocator.free(path);
        const data = compat.fs.readFileAlloc(allocator, compat.fs.getCwd(), path, 1024 * 1024) catch continue;
        defer allocator.free(data);
        var line_no: usize = 1;
        var start: usize = 0;
        while (start <= data.len) {
            const end = std.mem.indexOfScalarPos(u8, data, start, '\n') orelse data.len;
            const line = data[start..end];
            if (std.mem.indexOf(u8, line, query) != null) {
                const formatted = try std.fmt.allocPrint(allocator, "{s}:{d}:{s}\n", .{ path, line_no, line });
                defer allocator.free(formatted);
                try out.appendSlice(allocator, formatted);
            }
            if (end == data.len) break;
            start = end + 1;
            line_no += 1;
        }
    }
}

const ParsedArgs = struct {
    parsed: std.json.Parsed(std.json.Value),
    root: []const u8,
    query: []const u8,

    fn deinit(self: *const ParsedArgs) void {
        self.parsed.deinit();
    }
};

fn parseArgs(allocator: std.mem.Allocator, args_json: []const u8) !ParsedArgs {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const obj = parsed.value.object;
    const root = obj.get("root") orelse return error.InvalidArguments;
    const query = obj.get("query") orelse return error.InvalidArguments;
    if (root != .string or query != .string) return error.InvalidArguments;
    return .{ .parsed = parsed, .root = root.string, .query = query.string };
}
