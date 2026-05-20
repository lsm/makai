const std = @import("std");
const ai_types = @import("ai_types");
const agent = @import("agent");
const common = @import("tools/common");
const process_runner = @import("tools/process_runner");

pub const schema_info =
    \\{"type":"object","properties":{"workspace_root":{"type":"string"}},"required":["workspace_root"],"additionalProperties":false}
;
pub const schema_list =
    \\{"type":"object","properties":{"workspace_root":{"type":"string"},"max_results":{"type":"integer","minimum":0}},"required":["workspace_root"],"additionalProperties":false}
;
pub const schema_git_status =
    \\{"type":"object","properties":{"workspace_root":{"type":"string"},"timeout_ms":{"type":"integer","minimum":1}},"required":["workspace_root"],"additionalProperties":false}
;

pub const info_tool = agent.AgentTool{ .label = "Workspace Info", .name = "workspace_info", .description = "Return workspace root metadata and detected project root.", .short_description = "Show workspace path info.", .parameters_schema_json = schema_info, .execute = infoExecute };
pub const list_tool = agent.AgentTool{ .label = "Workspace List", .name = "workspace_list", .description = "List files under workspace root.", .short_description = "List workspace files.", .parameters_schema_json = schema_list, .execute = listExecute };
pub const git_status_tool = agent.AgentTool{ .label = "Git Status", .name = "workspace_git_status", .description = "Return git status for workspace root.", .short_description = "Show git status.", .parameters_schema_json = schema_git_status, .execute = gitStatusExecute };

pub fn infoExecute(tool_call_id: []const u8, args_json: []const u8, cancel_token: ?ai_types.CancelToken, on_update_ctx: ?*anyopaque, on_update: ?agent.ToolUpdateCallback, allocator: std.mem.Allocator) anyerror!agent.AgentToolResult {
    _ = tool_call_id;
    _ = on_update_ctx;
    _ = on_update;
    if (common.isCancelled(cancel_token)) return error.Cancelled;
    const start_ms = common.nowMs();
    var parsed = try common.parseArgs(allocator, args_json);
    defer parsed.deinit();
    const workspace_root = try common.requiredString(parsed.value.object, "workspace_root");
    var dir = try common.openWorkspace(workspace_root, false);
    defer dir.close(common.defaultIo());
    const project_root = try detectProjectRoot(allocator, workspace_root);
    defer allocator.free(project_root);
    const details = try common.jsonString(allocator, .{ .ok = true, .workspace_root = workspace_root, .project_root = project_root, .duration_ms = common.durationMs(start_ms), .raw_bytes = 0 });
    errdefer allocator.free(details);
    const text = try std.fmt.allocPrint(allocator, "workspace_root: {s}\nproject_root: {s}", .{ workspace_root, project_root });
    return common.makeTextResultOwned(allocator, text, details);
}

pub fn listExecute(tool_call_id: []const u8, args_json: []const u8, cancel_token: ?ai_types.CancelToken, on_update_ctx: ?*anyopaque, on_update: ?agent.ToolUpdateCallback, allocator: std.mem.Allocator) anyerror!agent.AgentToolResult {
    _ = tool_call_id;
    _ = on_update_ctx;
    _ = on_update;
    if (common.isCancelled(cancel_token)) return error.Cancelled;
    const start_ms = common.nowMs();
    var parsed = try common.parseArgs(allocator, args_json);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const workspace_root = try common.requiredString(obj, "workspace_root");
    const max = @min(common.optionalUsize(obj, "max_results", 200), 1000);
    var root = try common.openWorkspace(workspace_root, true);
    defer root.close(common.defaultIo());
    var walker = try root.walk(allocator);
    defer walker.deinit();
    var paths = std.ArrayList([]u8).empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    while (try walker.next(common.defaultIo())) |entry| {
        if (common.isCancelled(cancel_token)) return error.Cancelled;
        if (paths.items.len >= max) break;
        if (entry.kind == .file) try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]u8, paths.items, {}, lessPath);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (paths.items) |p| {
        try out.appendSlice(allocator, p);
        try out.append(allocator, '\n');
    }
    const text = try out.toOwnedSlice(allocator);
    errdefer allocator.free(text);
    const details = try common.jsonString(allocator, .{ .ok = true, .duration_ms = common.durationMs(start_ms), .raw_bytes = text.len, .returned_bytes = text.len, .file_count = paths.items.len });
    errdefer allocator.free(details);
    return common.makeTextResultOwned(allocator, text, details);
}

pub fn gitStatusExecute(tool_call_id: []const u8, args_json: []const u8, cancel_token: ?ai_types.CancelToken, on_update_ctx: ?*anyopaque, on_update: ?agent.ToolUpdateCallback, allocator: std.mem.Allocator) anyerror!agent.AgentToolResult {
    _ = tool_call_id;
    _ = on_update_ctx;
    _ = on_update;
    if (common.isCancelled(cancel_token)) return error.Cancelled;
    const start_ms = common.nowMs();
    var parsed = try common.parseArgs(allocator, args_json);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const workspace_root = try common.requiredString(obj, "workspace_root");
    const timeout_ms = @min(common.optionalU64(obj, "timeout_ms", 30_000), @as(u64, std.math.maxInt(i64)));
    var dir = try common.openWorkspace(workspace_root, false);
    defer dir.close(common.defaultIo());
    const argv = [_][]const u8{ "git", "status", "--short" };
    const result = process_runner.run(allocator, &argv, .{ .dir = dir }, timeout_ms, cancel_token) catch |err| {
        if (err == error.Cancelled) return err;
        const details = try common.jsonString(allocator, .{ .ok = false, .err = @errorName(err), .duration_ms = common.durationMs(start_ms), .raw_bytes = 0 });
        errdefer allocator.free(details);
        const text = try std.fmt.allocPrint(allocator, "git status failed: {s}", .{@errorName(err)});
        return common.makeTextResultOwned(allocator, text, details);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const text = try std.fmt.allocPrint(allocator, "{s}{s}", .{ result.stdout, result.stderr });
    errdefer allocator.free(text);
    const details = try common.jsonString(allocator, .{ .ok = result.term == .exited and result.term.exited == 0, .duration_ms = common.durationMs(start_ms), .raw_bytes = text.len, .returned_bytes = text.len });
    errdefer allocator.free(details);
    return common.makeTextResultOwned(allocator, text, details);
}

fn lessPath(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn detectProjectRoot(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    var current = try allocator.dupe(u8, workspace_root);
    errdefer allocator.free(current);
    while (true) {
        const git_path = try std.Io.Dir.path.join(allocator, &.{ current, ".git" });
        defer allocator.free(git_path);
        std.Io.Dir.cwd().access(common.defaultIo(), git_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (std.Io.Dir.path.dirname(current)) |parent| {
                    if (std.mem.eql(u8, parent, current)) return current;
                    const next = try allocator.dupe(u8, parent);
                    allocator.free(current);
                    current = next;
                    continue;
                } else return current;
            },
            else => return current,
        };
        return current;
    }
}

test "workspace info list and git status" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(common.defaultIo(), std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const root = try std.Io.Dir.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);
    try tmp.dir.createDir(common.defaultIo(), ".git", .default_dir);
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "a.txt", .data = "x" });
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\"}}", .{root});
    defer std.testing.allocator.free(args);
    var info = try infoExecute("call", args, null, null, null, std.testing.allocator);
    defer info.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, info.content.slice()[0].text.text, root) != null);
    var list = try listExecute("call", args, null, null, null, std.testing.allocator);
    defer list.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, list.content.slice()[0].text.text, "a.txt") != null);
    var cancelled = std.atomic.Value(bool).init(true);
    const token = ai_types.CancelToken{ .cancelled = &cancelled };
    try std.testing.expectError(error.Cancelled, listExecute("call", args, token, null, null, std.testing.allocator));
    var status = try gitStatusExecute("call", args, null, null, null, std.testing.allocator);
    defer status.deinit(std.testing.allocator);
    try std.testing.expect(status.getDetailsJson().?.len > 0);
}
