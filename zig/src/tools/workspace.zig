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

pub fn infoTool() agent_types.AgentTool {
    return .{
        .label = "Workspace Info",
        .name = "workspace_info",
        .description = "Return current workspace path and basic environment information.",
        .short_description = "Show workspace path info.",
        .parameters_schema_json = "{\"type\":\"object\",\"properties\":{\"compact_output\":{\"type\":\"boolean\"}}}",
        .execute = executeInfo,
    };
}

pub fn listTool() agent_types.AgentTool {
    return .{
        .label = "Workspace List",
        .name = "workspace_list",
        .description = "List entries in a workspace directory.",
        .short_description = "List directory entries.",
        .parameters_schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"compact_output\":{\"type\":\"boolean\"}}}",
        .execute = executeList,
    };
}

pub fn gitStatusTool() agent_types.AgentTool {
    return .{
        .label = "Git Status",
        .name = "git_status",
        .description = "Return git status in compact porcelain form.",
        .short_description = "Show git status.",
        .parameters_schema_json = "{\"type\":\"object\",\"properties\":{\"compact_output\":{\"type\":\"boolean\"}}}",
        .execute = executeGitStatus,
    };
}

pub fn executeInfo(tool_call_id: []const u8, args_json: []const u8, cancel_token: ?ai_types.CancelToken, on_update_ctx: ?*anyopaque, on_update: ?agent_types.ToolUpdateCallback, allocator: std.mem.Allocator) anyerror!agent_types.AgentToolResult {
    _ = tool_call_id; _ = cancel_token; _ = on_update_ctx; _ = on_update;
    const compact = compactFromArgs(allocator, args_json) catch false;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.process.currentPath(defaultIo(), &buffer);
    const cwd = buffer[0..len];
    const body = if (compact) try std.fmt.allocPrint(allocator, "cwd {s}", .{cwd}) else try std.fmt.allocPrint(allocator, "cwd: {s}", .{cwd});
    defer allocator.free(body);
    const details = try common.telemetryDetails(allocator, body.len, body.len, false);
    defer allocator.free(details);
    return common.makeTextResult(allocator, body, details);
}

pub fn executeList(tool_call_id: []const u8, args_json: []const u8, cancel_token: ?ai_types.CancelToken, on_update_ctx: ?*anyopaque, on_update: ?agent_types.ToolUpdateCallback, allocator: std.mem.Allocator) anyerror!agent_types.AgentToolResult {
    _ = tool_call_id; _ = cancel_token; _ = on_update_ctx; _ = on_update;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();
    const obj = if (parsed.value == .object) parsed.value.object else return error.InvalidArguments;
    const path = if (obj.get("path")) |v| if (v == .string) v.string else return error.InvalidArguments else ".";
    const compact = if (obj.get("compact_output")) |v| v == .bool and v.bool else false;
    var dir = try compat.fs.getCwd().openDir(defaultIo(), path, .{ .iterate = true });
    defer dir.close(defaultIo());
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var it = dir.iterate();
    while (try it.next(defaultIo())) |entry| {
        const formatted = if (compact)
            try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ @tagName(entry.kind), entry.name })
        else
            try std.fmt.allocPrint(allocator, "{s}\t{s}\n", .{ @tagName(entry.kind), entry.name });
        defer allocator.free(formatted);
        try out.appendSlice(allocator, formatted);
    }
    const details = try common.telemetryDetails(allocator, out.items.len, out.items.len, false);
    defer allocator.free(details);
    return common.makeTextResult(allocator, out.items, details);
}

pub fn executeGitStatus(tool_call_id: []const u8, args_json: []const u8, cancel_token: ?ai_types.CancelToken, on_update_ctx: ?*anyopaque, on_update: ?agent_types.ToolUpdateCallback, allocator: std.mem.Allocator) anyerror!agent_types.AgentToolResult {
    _ = tool_call_id; _ = args_json; _ = cancel_token; _ = on_update_ctx; _ = on_update;
    const output = try std.process.run(allocator, defaultIo(), .{
        .argv = &.{ "git", "status", "--short", "--branch" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(output.stdout);
    defer allocator.free(output.stderr);
    const body = if (output.stderr.len > 0) try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ output.stdout, output.stderr }) else try allocator.dupe(u8, output.stdout);
    defer allocator.free(body);
    const details = try common.telemetryDetails(allocator, output.stdout.len + output.stderr.len, body.len, false);
    defer allocator.free(details);
    return common.makeTextResult(allocator, body, details);
}

fn compactFromArgs(allocator: std.mem.Allocator, args_json: []const u8) !bool {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    return if (parsed.value.object.get("compact_output")) |v| v == .bool and v.bool else false;
}

test "workspace compact info format" {
    const allocator = std.testing.allocator;
    var result = try executeInfo("call", "{\"compact_output\":true}", null, null, null, allocator);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.startsWith(u8, result.content.slice()[0].text.text, "cwd "));
}
