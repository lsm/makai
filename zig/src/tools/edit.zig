const std = @import("std");
const ai_types = @import("ai_types");
const agent = @import("agent");
const common = @import("tools/common");

pub const schema_apply =
    \\{"type":"object","properties":{"workspace_root":{"type":"string"},"path":{"type":"string"},"operation":{"type":"string","enum":["find_replace","line_replace","insert","delete"]},"find":{"type":"string"},"replace":{"type":"string"},"start_line":{"type":"integer","minimum":1},"end_line":{"type":"integer","minimum":1},"content":{"type":"string"}},"required":["workspace_root","path","operation"],"additionalProperties":false}
;

pub const apply_tool = agent.AgentTool{ .label = "Structured Edit", .name = "edit_apply", .description = "Apply structured edits: find/replace, line range replace, insert, or delete.", .parameters_schema_json = schema_apply, .execute = applyExecute };

pub fn applyExecute(tool_call_id: []const u8, args_json: []const u8, cancel_token: ?ai_types.CancelToken, on_update_ctx: ?*anyopaque, on_update: ?agent.ToolUpdateCallback, allocator: std.mem.Allocator) anyerror!agent.AgentToolResult {
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
    const operation = try common.requiredString(obj, "operation");
    const original = try common.readWorkspaceFile(allocator, workspace_root, path, common.max_file_bytes);
    defer allocator.free(original);
    if (common.isBinary(original)) return error.BinaryFileRejected;

    var replacement_count: usize = 0;
    const edited = if (std.mem.eql(u8, operation, "find_replace")) blk: {
        const find = try common.requiredString(obj, "find");
        const replace = try common.requiredString(obj, "replace");
        break :blk try applyFindReplace(allocator, original, find, replace, &replacement_count);
    } else if (std.mem.eql(u8, operation, "line_replace")) blk: {
        const start_line = common.optionalUsize(obj, "start_line", 0);
        const end_line = common.optionalUsize(obj, "end_line", start_line);
        const content = try common.requiredString(obj, "content");
        break :blk try applyLineRange(allocator, original, start_line, end_line, content, &replacement_count);
    } else if (std.mem.eql(u8, operation, "insert")) blk: {
        const start_line = common.optionalUsize(obj, "start_line", 0);
        const content = try common.requiredString(obj, "content");
        break :blk try applyLineRange(allocator, original, start_line, start_line -| 1, content, &replacement_count);
    } else if (std.mem.eql(u8, operation, "delete")) blk: {
        const start_line = common.optionalUsize(obj, "start_line", 0);
        const end_line = common.optionalUsize(obj, "end_line", start_line);
        break :blk try applyLineRange(allocator, original, start_line, end_line, "", &replacement_count);
    } else return error.InvalidEditOperation;
    defer allocator.free(edited);

    try common.writeWorkspaceFile(allocator, workspace_root, path, edited);
    const details = try common.jsonString(allocator, .{ .ok = true, .path = path, .operation = operation, .duration_ms = common.durationMs(start_ms), .raw_bytes = original.len, .returned_bytes = edited.len, .replacement_count = replacement_count });
    errdefer allocator.free(details);
    const text = try std.fmt.allocPrint(allocator, "edited {s}: {d} replacement(s)", .{ path, replacement_count });
    return common.makeTextResultOwned(allocator, text, details);
}

fn applyFindReplace(allocator: std.mem.Allocator, input: []const u8, find: []const u8, replace: []const u8, count: *usize) ![]u8 {
    if (find.len == 0) return error.EmptyFind;
    count.* = std.mem.count(u8, input, find);
    if (count.* == 0) return error.FindNotFound;
    return std.mem.replaceOwned(u8, allocator, input, find, replace);
}

fn lineStartOffset(input: []const u8, target_line: usize) !usize {
    if (target_line == 0) return error.InvalidLineRange;
    if (target_line == 1) return 0;
    var line: usize = 1;
    for (input, 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            if (line == target_line) return i + 1;
        }
    }
    if (line + 1 == target_line) return input.len;
    return error.LineOutOfBounds;
}

fn lineEndOffset(input: []const u8, target_line: usize) !usize {
    if (target_line == 0) return error.InvalidLineRange;
    var line: usize = 1;
    for (input, 0..) |c, i| {
        if (line == target_line and c == '\n') return i + 1;
        if (c == '\n') line += 1;
    }
    if (line == target_line) return input.len;
    return error.LineOutOfBounds;
}

fn applyLineRange(allocator: std.mem.Allocator, input: []const u8, start_line: usize, end_line: usize, content: []const u8, count: *usize) ![]u8 {
    if (start_line == 0) return error.InvalidLineRange;
    if (end_line != 0 and end_line < start_line - 1) return error.InvalidLineRange;
    const start = try lineStartOffset(input, start_line);
    const end = if (end_line < start_line) start else try lineEndOffset(input, end_line);
    count.* = if (end > start) 1 else 0;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, input[0..start]);
    try out.appendSlice(allocator, content);
    if (content.len > 0 and (content[content.len - 1] != '\n') and end < input.len) try out.append(allocator, '\n');
    try out.appendSlice(allocator, input[end..]);
    return out.toOwnedSlice(allocator);
}

test "edit find replace modifies file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(common.defaultIo(), std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const root = try std.Io.Dir.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "a.txt", .data = "hello world\n" });
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"find_replace\",\"find\":\"world\",\"replace\":\"zig\"}}", .{root});
    defer std.testing.allocator.free(args);
    var result = try applyExecute("call", args, null, null, null, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    const data = try tmp.dir.readFileAlloc(common.defaultIo(), "a.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("hello zig\n", data);
}

test "edit line replace insert delete" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(common.defaultIo(), std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const root = try std.Io.Dir.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "a.txt", .data = "one\ntwo\nthree\n" });
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"line_replace\",\"start_line\":2,\"end_line\":2,\"content\":\"TWO\"}}", .{root});
    defer std.testing.allocator.free(args);
    var result = try applyExecute("call", args, null, null, null, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    const data = try tmp.dir.readFileAlloc(common.defaultIo(), "a.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("one\nTWO\nthree\n", data);
    const default_end_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"line_replace\",\"start_line\":2,\"content\":\"two\"}}", .{root});
    defer std.testing.allocator.free(default_end_args);
    var default_end_result = try applyExecute("call", default_end_args, null, null, null, std.testing.allocator);
    defer default_end_result.deinit(std.testing.allocator);
    const default_end_data = try tmp.dir.readFileAlloc(common.defaultIo(), "a.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(default_end_data);
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", default_end_data);
    const insert_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"insert\",\"start_line\":2,\"content\":\"INSERTED\"}}", .{root});
    defer std.testing.allocator.free(insert_args);
    var insert_result = try applyExecute("call", insert_args, null, null, null, std.testing.allocator);
    defer insert_result.deinit(std.testing.allocator);
    const insert_data = try tmp.dir.readFileAlloc(common.defaultIo(), "a.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(insert_data);
    try std.testing.expectEqualStrings("one\nINSERTED\ntwo\nthree\n", insert_data);
    const delete_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"delete\",\"start_line\":2}}", .{root});
    defer std.testing.allocator.free(delete_args);
    var delete_result = try applyExecute("call", delete_args, null, null, null, std.testing.allocator);
    defer delete_result.deinit(std.testing.allocator);
    const delete_data = try tmp.dir.readFileAlloc(common.defaultIo(), "a.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(delete_data);
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", delete_data);
}

test "edit rejects invalid inputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(common.defaultIo(), std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const root = try std.Io.Dir.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "a.txt", .data = "one\ntwo\n" });
    const empty_find_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"find_replace\",\"find\":\"\",\"replace\":\"x\"}}", .{root});
    defer std.testing.allocator.free(empty_find_args);
    try std.testing.expectError(error.EmptyFind, applyExecute("call", empty_find_args, null, null, null, std.testing.allocator));
    const absent_find_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"find_replace\",\"find\":\"absent\",\"replace\":\"x\"}}", .{root});
    defer std.testing.allocator.free(absent_find_args);
    try std.testing.expectError(error.FindNotFound, applyExecute("call", absent_find_args, null, null, null, std.testing.allocator));
    const line_oob_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"line_replace\",\"start_line\":9,\"content\":\"x\"}}", .{root});
    defer std.testing.allocator.free(line_oob_args);
    try std.testing.expectError(error.LineOutOfBounds, applyExecute("call", line_oob_args, null, null, null, std.testing.allocator));
    const delete_oob_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"delete\",\"start_line\":9}}", .{root});
    defer std.testing.allocator.free(delete_oob_args);
    try std.testing.expectError(error.LineOutOfBounds, applyExecute("call", delete_oob_args, null, null, null, std.testing.allocator));
    const insert_oob_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"insert\",\"start_line\":9,\"content\":\"x\"}}", .{root});
    defer std.testing.allocator.free(insert_oob_args);
    try std.testing.expectError(error.LineOutOfBounds, applyExecute("call", insert_oob_args, null, null, null, std.testing.allocator));
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "bin.dat", .data = "a\x00b" });
    const binary_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"bin.dat\",\"operation\":\"find_replace\",\"find\":\"a\",\"replace\":\"b\"}}", .{root});
    defer std.testing.allocator.free(binary_args);
    try std.testing.expectError(error.BinaryFileRejected, applyExecute("call", binary_args, null, null, null, std.testing.allocator));
}
