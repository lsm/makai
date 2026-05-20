const std = @import("std");
const ai_types = @import("ai_types");
const agent = @import("agent");
const common = @import("tools/common");

pub const schema_read =
    \\{"type":"object","properties":{"workspace_root":{"type":"string"},"path":{"type":"string"},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":0}},"required":["workspace_root","path"],"additionalProperties":false}
;
pub const schema_write =
    \\{"type":"object","properties":{"workspace_root":{"type":"string"},"path":{"type":"string"},"content":{"type":"string"},"compact_output":{"type":"boolean"}},"required":["workspace_root","path","content"],"additionalProperties":false}
;
pub const schema_stat =
    \\{"type":"object","properties":{"workspace_root":{"type":"string"},"path":{"type":"string"},"compact_output":{"type":"boolean"}},"required":["workspace_root","path"],"additionalProperties":false}
;

pub const read_tool = agent.AgentTool{ .label = "File Read", .name = "file_read", .description = "Read a text file from the workspace, optionally by byte range. Output includes per-line content hashes as line_no:hash|content for hash-anchored edits.", .short_description = "Read file with line hashes.", .parameters_schema_json = schema_read, .execute = readExecute };
pub const write_tool = agent.AgentTool{ .label = "File Write", .name = "file_write", .description = "Create or overwrite a file in the workspace.", .short_description = "Write file content.", .parameters_schema_json = schema_write, .execute = writeExecute };
pub const stat_tool = agent.AgentTool{ .label = "File Stat", .name = "file_stat", .description = "Return file metadata for a workspace path.", .short_description = "Stat file path.", .parameters_schema_json = schema_stat, .execute = statExecute };

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
    const limit = @min(common.optionalUsize(obj, "limit", common.max_file_bytes), common.max_file_bytes);

    var file = try common.openWorkspaceFile(allocator, workspace_root, path);
    defer file.close(common.defaultIo());
    const st = try file.stat(common.defaultIo());
    if (offset > st.size) return error.RangeOutOfBounds;
    const line_no_base = try lineNumberAtOffset(allocator, file, offset);
    const remaining: usize = @intCast(st.size - offset);
    const read_len = @min(limit, remaining);
    const text = try allocator.alloc(u8, read_len);
    defer allocator.free(text);
    const bytes_read = try file.readPositionalAll(common.defaultIo(), text, offset);
    if (common.isBinary(text[0..bytes_read])) return error.BinaryFileRejected;
    const hashed = try formatWithLineHashesFrom(allocator, text[0..bytes_read], line_no_base);
    errdefer allocator.free(hashed);
    const details = try common.jsonString(allocator, .{ .ok = true, .path = path, .duration_ms = common.durationMs(start_ms), .raw_bytes = st.size, .returned_bytes = hashed.len, .saved_bytes = if (st.size > hashed.len) st.size - hashed.len else 0, .compressed = false, .offset = offset, .limit = limit });
    errdefer allocator.free(details);
    return common.makeTextResultOwned(allocator, hashed, details);
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
    const compact = common.optionalBool(obj, "compact_output", false);
    try common.writeWorkspaceFile(allocator, workspace_root, path, content);
    const text = if (compact)
        try std.fmt.allocPrint(allocator, "ok {d} {s}", .{ content.len, path })
    else
        try std.fmt.allocPrint(allocator, "wrote {d} bytes to {s}", .{ content.len, path });
    errdefer allocator.free(text);
    const details = try common.jsonString(allocator, .{ .ok = true, .path = path, .duration_ms = common.durationMs(start_ms), .raw_bytes = content.len, .returned_bytes = text.len, .saved_bytes = content.len -| text.len, .compressed = false, .written_bytes = content.len });
    errdefer allocator.free(details);
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
    const compact = common.optionalBool(obj, "compact_output", false);
    const st = try common.statWorkspaceFile(allocator, workspace_root, path);
    const text = if (compact)
        try std.fmt.allocPrint(allocator, "{s} {s} {d}", .{ path, @tagName(st.kind), st.size })
    else
        try std.fmt.allocPrint(allocator, "{s}: {s}, {d} bytes", .{ path, @tagName(st.kind), st.size });
    errdefer allocator.free(text);
    const details = try common.jsonString(allocator, .{ .ok = true, .path = path, .duration_ms = common.durationMs(start_ms), .raw_bytes = text.len, .returned_bytes = text.len, .saved_bytes = 0, .compressed = false, .size = st.size, .kind = @tagName(st.kind), .mtime_ns = st.mtime.toNanoseconds() });
    errdefer allocator.free(details);
    return common.makeTextResultOwned(allocator, text, details);
}

pub fn formatWithLineHashes(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    return formatWithLineHashesFrom(allocator, content, 1);
}

fn formatWithLineHashesFrom(allocator: std.mem.Allocator, content: []const u8, first_line_no: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var line_no: usize = first_line_no;
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

fn lineNumberAtOffset(allocator: std.mem.Allocator, file: std.Io.File, offset: usize) !usize {
    if (offset == 0) return 1;
    const chunk_size: usize = 64 * 1024;
    const buf = try allocator.alloc(u8, chunk_size);
    defer allocator.free(buf);
    var line_no: usize = 1;
    var pos: usize = 0;
    while (pos < offset) {
        const read_len = @min(buf.len, offset - pos);
        const bytes_read = try file.readPositionalAll(common.defaultIo(), buf[0..read_len], pos);
        for (buf[0..bytes_read]) |c| {
            if (c == '\n') line_no += 1;
        }
        if (bytes_read < read_len) break;
        pos += bytes_read;
    }
    return line_no;
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
    try std.testing.expect(std.mem.indexOf(u8, rd.content.slice()[0].text.text, "1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rd.content.slice()[0].text.text, "|hello") != null);
    var st = try statExecute("call", read_args, null, null, null, std.testing.allocator);
    defer st.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, st.getDetailsJson().?, "\"size\":5") != null);
}

test "file read supports byte ranges without loading full file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(common.defaultIo(), std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const root = try std.Io.Dir.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);
    const big = try std.testing.allocator.alloc(u8, common.max_file_bytes + 1024);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    @memcpy(big[common.max_file_bytes + 10 .. common.max_file_bytes + 15], "range");
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "big.txt", .data = big });
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"big.txt\",\"offset\":{d},\"limit\":5}}", .{ root, common.max_file_bytes + 10 });
    defer std.testing.allocator.free(args);
    var result = try readExecute("call", args, null, null, null, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.content.slice()[0].text.text, "1:0000000000000000|range") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.content.slice()[0].text.text, "|range") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.getDetailsJson().?, "\"limit\":5") != null);
}

test "file read clamps requested range limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(common.defaultIo(), std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const root = try std.Io.Dir.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);
    const big = try std.testing.allocator.alloc(u8, common.max_file_bytes + 1024);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "big.txt", .data = big });
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"big.txt\",\"limit\":{d}}}", .{ root, common.max_file_bytes + 1024 });
    defer std.testing.allocator.free(args);
    var result = try readExecute("call", args, null, null, null, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.getDetailsJson().?, "\"limit\":16777216") != null);
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
    const traversal_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"{s}/../outside.txt\"}}", .{ root, root });
    defer std.testing.allocator.free(traversal_args);
    try std.testing.expectError(error.PathEscapesWorkspace, readExecute("call", traversal_args, null, null, null, std.testing.allocator));
}

test "file compact output mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(common.defaultIo(), std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const root = try std.Io.Dir.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"content\":\"hello\",\"compact_output\":true}}", .{root});
    defer std.testing.allocator.free(args);
    var result = try writeExecute("call", args, null, null, null, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ok 5 a.txt", result.content.slice()[0].text.text);
}
