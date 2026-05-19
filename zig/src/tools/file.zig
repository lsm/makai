const std = @import("std");
const ai_types = @import("ai_types");
const agent = @import("agent");
const common = @import("tools/common");

pub const schema_read =
    \\{"type":"object","properties":{"workspace_root":{"type":"string"},"path":{"type":"string"},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":0}},"required":["workspace_root","path"],"additionalProperties":false}
;
pub const schema_write =
    \\{"type":"object","properties":{"workspace_root":{"type":"string"},"path":{"type":"string"},"content":{"type":"string"}},"required":["workspace_root","path","content"],"additionalProperties":false}
;
pub const schema_stat =
    \\{"type":"object","properties":{"workspace_root":{"type":"string"},"path":{"type":"string"}},"required":["workspace_root","path"],"additionalProperties":false}
;

pub const read_tool = agent.AgentTool{ .label = "File Read", .name = "file_read", .description = "Read a text file from the workspace, optionally by byte range.", .parameters_schema_json = schema_read, .execute = readExecute };
pub const write_tool = agent.AgentTool{ .label = "File Write", .name = "file_write", .description = "Create or overwrite a file in the workspace.", .parameters_schema_json = schema_write, .execute = writeExecute };
pub const stat_tool = agent.AgentTool{ .label = "File Stat", .name = "file_stat", .description = "Return file metadata for a workspace path.", .parameters_schema_json = schema_stat, .execute = statExecute };

pub fn readExecute(tool_call_id: []const u8, args_json: []const u8, cancel_token: ?ai_types.CancelToken, on_update_ctx: ?*anyopaque, on_update: ?agent.ToolUpdateCallback, allocator: std.mem.Allocator) anyerror!agent.AgentToolResult {
    _ = tool_call_id;
    _ = on_update_ctx;
    _ = on_update;
    if (common.isCancelled(cancel_token)) return error.Cancelled;
    const start_ms = common.nowMs();
    var parsed = try common.parseArgs(allocator, args_json);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const workspace_root = try common.requiredString(obj, "workspace_root");
    const path = try common.requiredString(obj, "path");
    const offset = common.optionalUsize(obj, "offset", 0);
    const limit = common.optionalUsize(obj, "limit", common.max_file_bytes);

    const data = try common.readWorkspaceFile(allocator, workspace_root, path, common.max_file_bytes);
    defer allocator.free(data);
    if (common.isBinary(data)) return error.BinaryFileRejected;
    if (offset > data.len) return error.RangeOutOfBounds;
    const end = @min(data.len, offset + @min(limit, data.len - offset));
    const slice = data[offset..end];
    const details = try common.jsonString(allocator, .{ .ok = true, .path = path, .duration_ms = common.durationMs(start_ms), .raw_bytes = data.len, .returned_bytes = slice.len, .offset = offset, .limit = limit });
    errdefer allocator.free(details);
    const text = try allocator.dupe(u8, slice);
    errdefer allocator.free(text);
    return common.makeTextResultOwned(allocator, text, details);
}

pub fn writeExecute(tool_call_id: []const u8, args_json: []const u8, cancel_token: ?ai_types.CancelToken, on_update_ctx: ?*anyopaque, on_update: ?agent.ToolUpdateCallback, allocator: std.mem.Allocator) anyerror!agent.AgentToolResult {
    _ = tool_call_id;
    _ = on_update_ctx;
    _ = on_update;
    if (common.isCancelled(cancel_token)) return error.Cancelled;
    const start_ms = common.nowMs();
    var parsed = try common.parseArgs(allocator, args_json);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const workspace_root = try common.requiredString(obj, "workspace_root");
    const path = try common.requiredString(obj, "path");
    const content = try common.requiredString(obj, "content");
    try common.writeWorkspaceFile(allocator, workspace_root, path, content);
    const details = try common.jsonString(allocator, .{ .ok = true, .path = path, .duration_ms = common.durationMs(start_ms), .raw_bytes = content.len, .written_bytes = content.len });
    errdefer allocator.free(details);
    const text = try std.fmt.allocPrint(allocator, "wrote {d} bytes to {s}", .{ content.len, path });
    return common.makeTextResultOwned(allocator, text, details);
}

pub fn statExecute(tool_call_id: []const u8, args_json: []const u8, cancel_token: ?ai_types.CancelToken, on_update_ctx: ?*anyopaque, on_update: ?agent.ToolUpdateCallback, allocator: std.mem.Allocator) anyerror!agent.AgentToolResult {
    _ = tool_call_id;
    _ = on_update_ctx;
    _ = on_update;
    if (common.isCancelled(cancel_token)) return error.Cancelled;
    const start_ms = common.nowMs();
    var parsed = try common.parseArgs(allocator, args_json);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const workspace_root = try common.requiredString(obj, "workspace_root");
    const path = try common.requiredString(obj, "path");
    const st = try common.statWorkspaceFile(allocator, workspace_root, path);
    const details = try common.jsonString(allocator, .{ .ok = true, .path = path, .duration_ms = common.durationMs(start_ms), .raw_bytes = 0, .size = st.size, .kind = @tagName(st.kind), .mtime_ns = st.mtime.toNanoseconds() });
    errdefer allocator.free(details);
    const text = try std.fmt.allocPrint(allocator, "{s}: {s}, {d} bytes", .{ path, @tagName(st.kind), st.size });
    return common.makeTextResultOwned(allocator, text, details);
}

test "file read write stat" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(common.defaultIo(), std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const root = try std.Io.Dir.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);
    const write_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"content\":\"hello\"}}", .{root});
    defer std.testing.allocator.free(write_args);
    var wr = try writeExecute("call", write_args, null, null, null, std.testing.allocator);
    defer wr.deinit(std.testing.allocator);
    const read_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\"}}", .{root});
    defer std.testing.allocator.free(read_args);
    var rd = try readExecute("call", read_args, null, null, null, std.testing.allocator);
    defer rd.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", rd.content.slice()[0].text.text);
    var st = try statExecute("call", read_args, null, null, null, std.testing.allocator);
    defer st.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, st.getDetailsJson().?, "\"size\":5") != null);
}

test "file read rejects missing binary and workspace escape" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(common.defaultIo(), std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const root = try std.Io.Dir.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);
    const missing_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"missing.txt\"}}", .{root});
    defer std.testing.allocator.free(missing_args);
    try std.testing.expectError(error.FileNotFound, readExecute("call", missing_args, null, null, null, std.testing.allocator));
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "bin.dat", .data = "a\x00b" });
    const bin_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"bin.dat\"}}", .{root});
    defer std.testing.allocator.free(bin_args);
    try std.testing.expectError(error.BinaryFileRejected, readExecute("call", bin_args, null, null, null, std.testing.allocator));
    const escape_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"{s}.outside\"}}", .{ root, root });
    defer std.testing.allocator.free(escape_args);
    try std.testing.expectError(error.PathEscapesWorkspace, readExecute("call", escape_args, null, null, null, std.testing.allocator));
    try std.testing.expectError(error.PathEscapesWorkspace, statExecute("call", escape_args, null, null, null, std.testing.allocator));
    const write_escape_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"{s}.outside\",\"content\":\"nope\"}}", .{ root, root });
    defer std.testing.allocator.free(write_escape_args);
    try std.testing.expectError(error.PathEscapesWorkspace, writeExecute("call", write_escape_args, null, null, null, std.testing.allocator));
}
