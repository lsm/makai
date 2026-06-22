const std = @import("std");
const ai_types = @import("ai_types");
const agent = @import("agent");
const common = @import("tools/common");
const tool_types = @import("protocol_tool_types");

pub const schema_read =
    \\{"type":"object","properties":{"description":{"type":"string","description":"Why this tool call is needed and what information or change it is intended to produce."},"workspace_root":{"type":"string"},"path":{"type":"string"},"start_line":{"type":"integer","minimum":1},"end_line":{"type":"integer","minimum":1},"byte_limit":{"type":"integer","minimum":0}},"required":["description","workspace_root","path"],"additionalProperties":false}
;

pub const schema_edit =
    \\{"type":"object","properties":{"description":{"type":"string","description":"Why this tool call is needed and what information or change it is intended to produce."},"workspace_root":{"type":"string"},"path":{"type":"string"},"operation":{"type":"string","enum":["replace_range","insert_before","insert_after","delete_range"]},"start_line":{"type":"integer","minimum":1},"start_hash":{"type":"string"},"end_line":{"type":"integer","minimum":1},"end_hash":{"type":"string"},"replacement":{"type":"string"},"preview_only":{"type":"boolean"}},"required":["description","workspace_root","path","operation","start_line","start_hash"],"additionalProperties":false}
;

pub const read_tool = agent.AgentTool{ .label = "Hashline Read", .name = "hashline_read", .description = "Read a workspace file line range with stable SHA-256 per-line anchors for large-file edits.", .short_description = "Read line range with SHA-256 anchors.", .parameters_schema_json = schema_read, .execute = readExecute };
pub const edit_tool = agent.AgentTool{ .label = "Hashline Edit", .name = "hashline_edit", .description = "Preview or apply hash-anchored structured edits. Edits reject stale line anchors before writing.", .short_description = "Edit line range with anchor checks.", .parameters_schema_json = schema_edit, .execute = editExecute };

const Operation = tool_types.HashlineEditOperation;
const max_read_bytes: usize = common.max_file_bytes;
const max_preview_bytes: usize = common.default_file_limit;

const Line = struct {
    no: usize,
    text: []const u8,
    start: usize,
    end: usize,
};

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
    const start_line = common.optionalUsize(obj, "start_line", 1);
    const byte_limit = @min(common.optionalUsize(obj, "byte_limit", common.default_file_limit), max_read_bytes);
    if (start_line == 0) return error.InvalidLineRange;

    const content = try common.readWorkspaceFile(allocator, workspace_root, path, common.max_file_bytes);
    defer allocator.free(content);
    if (common.isBinary(content)) return error.BinaryFileRejected;

    const total_lines = countTextLines(content);
    const default_end = if (total_lines == 0) start_line else total_lines;
    const end_line = common.optionalUsize(obj, "end_line", default_end);
    if (end_line < start_line) return error.InvalidLineRange;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var emitted: usize = 0;
    var returned_text_bytes: usize = 0;
    var iter = LineIterator.init(content);
    while (iter.next()) |line| {
        if (line.no < start_line) continue;
        if (line.no > end_line) break;
        const hash = sha256Hex(line.text);
        const row = try std.fmt.allocPrint(allocator, "{d}:{s}|{s}\n", .{ line.no, &hash, line.text });
        defer allocator.free(row);
        if (out.items.len + row.len > byte_limit) {
            if (emitted == 0) return error.StreamTooLong;
            break;
        }
        try out.appendSlice(allocator, row);
        emitted += 1;
        returned_text_bytes += line.text.len;
    }
    if (emitted == 0 and total_lines > 0) return error.LineOutOfBounds;

    const text = try out.toOwnedSlice(allocator);
    errdefer allocator.free(text);
    const details = try common.jsonString(allocator, .{ .ok = true, .path = path, .duration_ms = common.durationMs(start_ms), .raw_bytes = content.len, .returned_bytes = text.len, .line_count = emitted, .start_line = start_line, .end_line = if (emitted == 0) start_line else start_line + emitted - 1, .returned_text_bytes = returned_text_bytes });
    errdefer allocator.free(details);
    return common.makeTextResultOwned(allocator, text, details);
}

pub fn editExecute(tool_call_id: []const u8, args_json: []const u8, cancel_token: ?ai_types.CancelToken, on_update_ctx: ?*anyopaque, on_update: ?agent.ToolUpdateCallback, allocator: std.mem.Allocator) anyerror!agent.AgentToolResult {
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
    const operation_name = try common.requiredString(obj, "operation");
    const operation = std.meta.stringToEnum(Operation, operation_name) orelse return error.InvalidEditOperation;
    const start_line = common.optionalUsize(obj, "start_line", 0);
    const end_line = common.optionalUsize(obj, "end_line", start_line);
    const start_hash = try common.requiredString(obj, "start_hash");
    const end_hash = common.optionalString(obj, "end_hash") orelse start_hash;
    const replacement = common.optionalString(obj, "replacement") orelse "";
    const preview_only = common.optionalBool(obj, "preview_only", false);
    if (start_line == 0 or end_line == 0 or end_line < start_line) return error.InvalidLineRange;

    const original = try common.readWorkspaceFile(allocator, workspace_root, path, common.max_file_bytes);
    defer allocator.free(original);
    if (common.isBinary(original)) return error.BinaryFileRejected;

    const first = getLine(original, start_line) orelse return error.LineOutOfBounds;
    const last = getLine(original, end_line) orelse return error.LineOutOfBounds;
    try verifyHash(first.text, start_hash);
    try verifyHash(last.text, end_hash);

    var replacement_count: usize = 0;
    const edited = try applyOperation(allocator, original, operation, first, last, replacement, &replacement_count);
    defer allocator.free(edited);
    const preview = try renderPreview(allocator, path, operation, operation_name, original[first.start..last.end], first, last, replacement, start_hash, end_hash);
    errdefer allocator.free(preview);

    if (!preview_only) try common.writeWorkspaceFile(allocator, workspace_root, path, edited);

    const details = try common.jsonString(allocator, .{ .ok = true, .path = path, .operation = operation_name, .applied = !preview_only, .duration_ms = common.durationMs(start_ms), .raw_bytes = original.len, .returned_bytes = preview.len, .replacement_count = replacement_count, .start_line = start_line, .end_line = end_line });
    errdefer allocator.free(details);
    return common.makeTextResultOwned(allocator, preview, details);
}

pub fn sha256Hex(line: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(line, &digest, .{});
    return hexEncode(&digest);
}

fn hexEncode(bytes: []const u8) [64]u8 {
    const alphabet = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (bytes, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

fn verifyHash(line: []const u8, expected: []const u8) !void {
    const actual = sha256Hex(line);
    if (!std.mem.eql(u8, expected, &actual)) return error.StaleHash;
}

fn countTextLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    if (text[text.len - 1] == '\n') count -= 1;
    return count;
}

const LineIterator = struct {
    input: []const u8,
    start: usize = 0,
    no: usize = 1,

    fn init(input: []const u8) LineIterator {
        return .{ .input = input };
    }

    fn next(self: *LineIterator) ?Line {
        if (self.start >= self.input.len) return null;
        const line_start = self.start;
        const text_end = std.mem.indexOfScalarPos(u8, self.input, line_start, '\n') orelse self.input.len;
        const line_end = if (text_end < self.input.len) text_end + 1 else text_end;
        const line = Line{ .no = self.no, .text = self.input[line_start..text_end], .start = line_start, .end = line_end };
        self.start = line_end;
        self.no += 1;
        return line;
    }
};

fn getLine(input: []const u8, target_line: usize) ?Line {
    var iter = LineIterator.init(input);
    while (iter.next()) |line| {
        if (line.no == target_line) return line;
        if (line.no > target_line) return null;
    }
    return null;
}

fn applyOperation(allocator: std.mem.Allocator, input: []const u8, operation: Operation, first: Line, last: Line, replacement: []const u8, replacement_count: *usize) ![]u8 {
    const start = switch (operation) {
        .replace_range, .delete_range, .insert_before => first.start,
        .insert_after => last.end,
    };
    const end = switch (operation) {
        .replace_range, .delete_range => last.end,
        .insert_before, .insert_after => start,
    };
    const inserted = switch (operation) {
        .delete_range => "",
        else => replacement,
    };
    replacement_count.* = if (operation == .insert_before or operation == .insert_after or end > start) 1 else 0;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, input[0..start]);
    if (operation == .insert_after and inserted.len > 0 and start > 0 and input[start - 1] != '\n') try out.append(allocator, '\n');
    try out.appendSlice(allocator, inserted);
    if (inserted.len > 0 and inserted[inserted.len - 1] != '\n' and end < input.len) try out.append(allocator, '\n');
    try out.appendSlice(allocator, input[end..]);
    return out.toOwnedSlice(allocator);
}

fn renderPreview(allocator: std.mem.Allocator, path: []const u8, operation: Operation, operation_name: []const u8, old_range: []const u8, first: Line, last: Line, replacement: []const u8, start_hash: []const u8, end_hash: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const header = try std.fmt.allocPrint(allocator, "hashline edit {s}\noperation: {s}\nrange: {d}:{s}..{d}:{s}\n", .{ path, operation_name, first.no, start_hash, last.no, end_hash });
    defer allocator.free(header);
    try appendPreview(&out, allocator, header);
    if (operation == .replace_range or operation == .delete_range) {
        var line_no = first.no;
        var old_iter = LineIterator.init(old_range);
        while (old_iter.next()) |line| {
            const old_hash = sha256Hex(line.text);
            const row = try std.fmt.allocPrint(allocator, "- {d}:{s}|{s}\n", .{ line_no, &old_hash, line.text });
            defer allocator.free(row);
            try appendPreview(&out, allocator, row);
            line_no += 1;
        }
    } else {
        const anchor_hash = sha256Hex(first.text);
        const row = try std.fmt.allocPrint(allocator, "  anchor {d}:{s}|{s}\n", .{ first.no, &anchor_hash, first.text });
        defer allocator.free(row);
        try appendPreview(&out, allocator, row);
    }
    var repl_iter = LineIterator.init(replacement);
    var repl_line: usize = if (operation == .insert_after) last.no + 1 else first.no;
    while (repl_iter.next()) |line| {
        const row = try std.fmt.allocPrint(allocator, "+ {d}|{s}\n", .{ repl_line, line.text });
        defer allocator.free(row);
        try appendPreview(&out, allocator, row);
        repl_line += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn appendPreview(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    if (out.items.len >= max_preview_bytes) return;
    const remaining = max_preview_bytes - out.items.len;
    if (text.len <= remaining) {
        try out.appendSlice(allocator, text);
        return;
    }
    if (remaining > 0) try out.appendSlice(allocator, text[0..remaining]);
    const marker = "\n... preview truncated ...\n";
    if (out.items.len + marker.len <= max_preview_bytes) try out.appendSlice(allocator, marker);
}

fn tmpRoot(allocator: std.mem.Allocator, tmp: std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(common.defaultIo(), allocator);
    defer allocator.free(cwd);
    return std.Io.Dir.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

test "hashline read range returns sha256 anchors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "a.txt", .data = "one\ntwo\nthree\n" });
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"start_line\":2,\"end_line\":3}}", .{root});
    defer std.testing.allocator.free(args);
    var result = try readExecute("call", args, null, null, null, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    const two_hash = sha256Hex("two");
    const expected = try std.fmt.allocPrint(std.testing.allocator, "2:{s}|two", .{&two_hash});
    defer std.testing.allocator.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, result.content.slice()[0].text.text, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content.slice()[0].text.text, "1:") == null);
}

test "hashline anchors are stable" {
    const a = sha256Hex("same line");
    const b = sha256Hex("same line");
    const c = sha256Hex("other line");
    try std.testing.expectEqualStrings(&a, &b);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
    try std.testing.expectEqual(@as(usize, 64), a.len);
}

test "hashline edit valid anchor modifies file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "a.txt", .data = "one\ntwo\nthree\n" });
    const start_hash = sha256Hex("two");
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"replace_range\",\"start_line\":2,\"start_hash\":\"{s}\",\"replacement\":\"TWO\"}}", .{ root, &start_hash });
    defer std.testing.allocator.free(args);
    var result = try editExecute("call", args, null, null, null, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    const data = try tmp.dir.readFileAlloc(common.defaultIo(), "a.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("one\nTWO\nthree\n", data);
}

test "hashline edit stale anchor rejects and leaves file unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "a.txt", .data = "one\ntwo\nthree\n" });
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"replace_range\",\"start_line\":2,\"start_hash\":\"00\",\"replacement\":\"TWO\"}}", .{root});
    defer std.testing.allocator.free(args);
    try std.testing.expectError(error.StaleHash, editExecute("call", args, null, null, null, std.testing.allocator));
    const data = try tmp.dir.readFileAlloc(common.defaultIo(), "a.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", data);
}

test "hashline edit preview only leaves file unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "a.txt", .data = "one\ntwo\nthree\n" });
    const start_hash = sha256Hex("two");
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"replace_range\",\"start_line\":2,\"start_hash\":\"{s}\",\"replacement\":\"TWO\",\"preview_only\":true}}", .{ root, &start_hash });
    defer std.testing.allocator.free(args);
    var result = try editExecute("call", args, null, null, null, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.content.slice()[0].text.text, "- 2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content.slice()[0].text.text, "+ 2|TWO") != null);
    const data = try tmp.dir.readFileAlloc(common.defaultIo(), "a.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", data);
}

test "hashline insert previews do not show deletions and insert after eof separates lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "a.txt", .data = "lastline" });
    const start_hash = sha256Hex("lastline");
    const preview_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"insert_after\",\"start_line\":1,\"start_hash\":\"{s}\",\"replacement\":\"next\",\"preview_only\":true}}", .{ root, &start_hash });
    defer std.testing.allocator.free(preview_args);
    var preview = try editExecute("call", preview_args, null, null, null, std.testing.allocator);
    defer preview.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, preview.content.slice()[0].text.text, "- 1:") == null);
    try std.testing.expect(std.mem.indexOf(u8, preview.content.slice()[0].text.text, "anchor 1:") != null);

    const apply_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"insert_after\",\"start_line\":1,\"start_hash\":\"{s}\",\"replacement\":\"next\"}}", .{ root, &start_hash });
    defer std.testing.allocator.free(apply_args);
    var applied = try editExecute("call", apply_args, null, null, null, std.testing.allocator);
    defer applied.deinit(std.testing.allocator);
    const data = try tmp.dir.readFileAlloc(common.defaultIo(), "a.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("lastline\nnext", data);
}

test "hashline preview caps large replacements" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "a.txt", .data = "one\n" });
    const start_hash = sha256Hex("one");
    const replacement = try std.testing.allocator.alloc(u8, max_preview_bytes + 4096);
    defer std.testing.allocator.free(replacement);
    @memset(replacement, 'x');
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"replace_range\",\"start_line\":1,\"start_hash\":\"{s}\",\"replacement\":\"{s}\",\"preview_only\":true}}", .{ root, &start_hash, replacement });
    defer std.testing.allocator.free(args);
    var result = try editExecute("call", args, null, null, null, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.content.slice()[0].text.text.len <= max_preview_bytes);
}

test "hashline read then edit integration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "a.txt", .data = "one\ntwo\nthree\n" });
    const read_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"start_line\":2,\"end_line\":2}}", .{root});
    defer std.testing.allocator.free(read_args);
    var read_result = try readExecute("read", read_args, null, null, null, std.testing.allocator);
    defer read_result.deinit(std.testing.allocator);
    const text = read_result.content.slice()[0].text.text;
    const hash_start = std.mem.indexOfScalar(u8, text, ':').? + 1;
    const hash_end = std.mem.indexOfScalar(u8, text, '|').?;
    const hash = text[hash_start..hash_end];
    const edit_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"path\":\"a.txt\",\"operation\":\"replace_range\",\"start_line\":2,\"start_hash\":\"{s}\",\"replacement\":\"TWO\"}}", .{ root, hash });
    defer std.testing.allocator.free(edit_args);
    var edit_result = try editExecute("edit", edit_args, null, null, null, std.testing.allocator);
    defer edit_result.deinit(std.testing.allocator);
    const data = try tmp.dir.readFileAlloc(common.defaultIo(), "a.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("one\nTWO\nthree\n", data);
}
