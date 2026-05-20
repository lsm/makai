const std = @import("std");
const ai_types = @import("ai_types");
const agent_types = @import("agent_types");
const artifact_store = @import("artifact/store");
const compat = @import("compat");

const AgentToolResult = agent_types.AgentToolResult;
const ToolOutputMiddlewareInput = agent_types.ToolOutputMiddlewareInput;

pub const default_shell_limit: usize = 10 * 1024;
pub const default_file_limit: usize = 20 * 1024;
pub const default_search_limit: usize = 15 * 1024;

const mime_text_plain = "text/plain";
const marker_prefix = "\n[... truncated. artifact_id=";
const marker_suffix = " ...]";

pub const Limits = struct {
    shell: usize = default_shell_limit,
    file: usize = default_file_limit,
    search: usize = default_search_limit,
    fallback: ?usize = null,

    pub fn forTool(self: Limits, tool_name: []const u8) ?usize {
        const kind = classifyTool(tool_name);
        return switch (kind) {
            .shell => self.shell,
            .file => self.file,
            .search => self.search,
            .other => self.fallback,
        };
    }
};

const ToolKind = enum { shell, file, search, other };

pub const TruncationMiddleware = struct {
    store: *artifact_store.ArtifactStore,
    limits: Limits = .{},

    pub fn middleware(ctx: ?*anyopaque, input: ToolOutputMiddlewareInput, result: *AgentToolResult, allocator: std.mem.Allocator) anyerror!void {
        const self: *TruncationMiddleware = @ptrCast(@alignCast(ctx.?));
        try self.apply(input, result, allocator);
    }

    pub fn apply(self: *TruncationMiddleware, input: ToolOutputMiddlewareInput, result: *AgentToolResult, allocator: std.mem.Allocator) !void {
        const limit = self.limits.forTool(input.tool_name) orelse return;

        const raw_output = try collectToolOutput(allocator, result.*);
        defer allocator.free(raw_output);
        const details = result.getDetailsJson() orelse "";

        if (raw_output.len + details.len <= limit) return;

        var store_reference = try self.store.write(.{
            .content = raw_output,
            .mime_type = mime_text_plain,
            .description = "raw tool output",
        });
        defer store_reference.deinit(self.store.allocator);

        var reference = try cloneArtifactReference(allocator, store_reference);
        errdefer reference.deinit(allocator);

        const returned_details = try truncateDetailsJson(allocator, details, limit, reference.artifact_id);
        errdefer allocator.free(returned_details);

        const text_budget = limit -| returned_details.len;
        const truncated = try truncateWithMarker(allocator, raw_output, text_budget, reference.artifact_id);
        errdefer allocator.free(truncated);

        const new_content = try allocator.alloc(ai_types.UserContentPart, 1);
        errdefer allocator.free(new_content);
        new_content[0] = .{ .text = .{ .text = truncated } };

        const artifacts = try appendArtifactReference(allocator, result.artifacts.slice(), reference);
        errdefer {
            for (artifacts) |*artifact| artifact.deinit(allocator);
            allocator.free(artifacts);
        }

        const details_json = ai_types.OwnedSlice(u8).initOwned(returned_details);
        errdefer details_json.deinit(allocator);

        result.content.deinit(allocator);
        result.details_json.deinit(allocator);
        result.artifacts.deinit(allocator);

        result.* = .{
            .content = ai_types.OwnedSlice(ai_types.UserContentPart).initOwned(new_content),
            .details_json = details_json,
            .artifacts = ai_types.OwnedSlice(ai_types.ArtifactReference).initOwned(artifacts),
        };
    }
};

fn classifyTool(tool_name: []const u8) ToolKind {
    if (matchesToolName(tool_name, "shell")) return .shell;
    if (matchesToolName(tool_name, "file") or matchesToolName(tool_name, "read") or matchesToolName(tool_name, "write") or matchesToolName(tool_name, "edit")) return .file;
    if (matchesToolName(tool_name, "search") or matchesToolName(tool_name, "grep")) return .search;
    return .other;
}

fn matchesToolName(tool_name: []const u8, token: []const u8) bool {
    if (std.mem.eql(u8, tool_name, token)) return true;
    if (!std.mem.startsWith(u8, tool_name, token)) return false;
    if (tool_name.len <= token.len) return false;
    const separator = tool_name[token.len];
    return separator == '_' or separator == '-';
}

fn collectToolOutput(allocator: std.mem.Allocator, result: AgentToolResult) ![]u8 {
    var total: usize = 0;
    for (result.content.slice()) |part| switch (part) {
        .text => |text| total += text.text.len,
        .image => {},
    };

    var out = try allocator.alloc(u8, total);
    var offset: usize = 0;
    for (result.content.slice()) |part| switch (part) {
        .text => |text| {
            @memcpy(out[offset .. offset + text.text.len], text.text);
            offset += text.text.len;
        },
        .image => {},
    };
    return out;
}

fn truncateWithMarker(allocator: std.mem.Allocator, raw_output: []const u8, limit: usize, artifact_id: []const u8) ![]u8 {
    if (limit == 0) return try allocator.dupe(u8, "");

    const compact_id = artifact_id[0..@min(artifact_id.len, 12)];
    const marker = try std.fmt.allocPrint(allocator, marker_prefix ++ "{s}" ++ marker_suffix, .{compact_id});
    defer allocator.free(marker);

    if (limit <= marker.len) return try allocator.dupe(u8, marker[0..limit]);

    const head_len = @min(limit - marker.len, raw_output.len);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ raw_output[0..head_len], marker });
}

fn truncateDetailsJson(allocator: std.mem.Allocator, details: []const u8, limit: usize, artifact_id: []const u8) ![]u8 {
    if (details.len == 0) return try allocator.dupe(u8, "");
    if (details.len <= limit) return try allocator.dupe(u8, details);
    return truncateWithMarker(allocator, details, limit, artifact_id);
}

fn appendArtifactReference(allocator: std.mem.Allocator, existing: []const ai_types.ArtifactReference, new_reference: ai_types.ArtifactReference) ![]ai_types.ArtifactReference {
    const out = try allocator.alloc(ai_types.ArtifactReference, existing.len + 1);
    var cloned_count: usize = 0;
    errdefer {
        for (out[0..cloned_count]) |*artifact| artifact.deinit(allocator);
        allocator.free(out);
    }

    for (existing, 0..) |artifact, i| {
        out[i] = try cloneArtifactReference(allocator, artifact);
        cloned_count += 1;
    }
    out[existing.len] = new_reference;
    return out;
}

fn cloneArtifactReference(allocator: std.mem.Allocator, artifact: ai_types.ArtifactReference) !ai_types.ArtifactReference {
    var cloned = ai_types.ArtifactReference{
        .artifact_id = try allocator.dupe(u8, artifact.artifact_id),
        .byte_size = artifact.byte_size,
    };
    errdefer cloned.deinit(allocator);

    if (artifact.uri.slice().len > 0) cloned.uri = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, artifact.uri.slice()));
    if (artifact.mime_type.slice().len > 0) cloned.mime_type = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, artifact.mime_type.slice()));
    if (artifact.sha256.slice().len > 0) cloned.sha256 = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, artifact.sha256.slice()));
    if (artifact.description.slice().len > 0) cloned.description = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, artifact.description.slice()));
    return cloned;
}

fn makeTextResult(allocator: std.mem.Allocator, text: []const u8, details_json: []const u8) !AgentToolResult {
    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    errdefer content[0].deinit(allocator);

    return .{
        .content = ai_types.OwnedSlice(ai_types.UserContentPart).initOwned(content),
        .details_json = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, details_json)),
    };
}

fn testInput(tool_name: []const u8, bytes: usize) ToolOutputMiddlewareInput {
    return .{
        .tool_call_id = "call_1",
        .tool_name = tool_name,
        .args_json = "{}",
        .is_error = false,
        .raw_result_bytes = bytes,
        .raw_details_bytes = 0,
        .raw_total_bytes = bytes,
    };
}

fn tmpStore(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) !artifact_store.ArtifactStore {
    const root_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "artifacts" });
    defer allocator.free(root_path);
    try compat.fs.createDir(compat.fs.getCwd(), root_path);
    return artifact_store.ArtifactStore.initWithPath(allocator, root_path, null);
}

test "truncation middleware passes under-limit output unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    var store = try tmpStore(allocator, &tmp);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    var middleware = TruncationMiddleware{ .store = &store, .limits = .{ .shell = 16 } };
    var result = try makeTextResult(allocator, "small output", "");
    defer result.deinit(allocator);

    try middleware.apply(testInput("shell_execute", 12), &result, allocator);

    try std.testing.expectEqual(@as(usize, 1), result.content.slice().len);
    try std.testing.expectEqualStrings("small output", result.content.slice()[0].text.text);
    try std.testing.expectEqual(@as(usize, 0), result.artifacts.slice().len);
    const artifacts = try store.list(.{});
    defer {
        for (artifacts) |*artifact| artifact.deinit(allocator);
        allocator.free(artifacts);
    }
    try std.testing.expectEqual(@as(usize, 0), artifacts.len);
}

test "truncation middleware stores over-limit output and returns reference" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    var store = try tmpStore(allocator, &tmp);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    const raw_output = "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789";
    var middleware = TruncationMiddleware{ .store = &store, .limits = .{ .shell = 64 } };
    var result = try makeTextResult(allocator, raw_output, "");
    defer result.deinit(allocator);

    try middleware.apply(testInput("shell_execute", raw_output.len), &result, allocator);

    try std.testing.expectEqual(@as(usize, 1), result.artifacts.slice().len);
    const artifact_id = result.artifacts.slice()[0].artifact_id;
    const text = result.content.slice()[0].text.text;
    try std.testing.expect(text.len + result.details_json.slice().len <= 64);
    try std.testing.expect(std.mem.startsWith(u8, text, "abc"));
    try std.testing.expect(std.mem.indexOf(u8, text, artifact_id[0..12]) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[... truncated. artifact_id=") != null);

    var stored = try store.read(artifact_id);
    defer stored.deinit(allocator);
    try std.testing.expectEqualStrings(raw_output, stored.content);
}

test "truncation middleware respects per-tool limits" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    var store = try tmpStore(allocator, &tmp);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    var middleware = TruncationMiddleware{ .store = &store, .limits = .{ .shell = 8, .file = 32, .search = 16 } };

    var file_result = try makeTextResult(allocator, "0123456789abcdefghijklmnopqrst", "");
    defer file_result.deinit(allocator);
    try middleware.apply(testInput("file_read", 30), &file_result, allocator);
    try std.testing.expectEqual(@as(usize, 0), file_result.artifacts.slice().len);

    var search_result = try makeTextResult(allocator, "0123456789abcdefghijklmnopqrst", "");
    defer search_result.deinit(allocator);
    try middleware.apply(testInput("search_text", 30), &search_result, allocator);
    try std.testing.expectEqual(@as(usize, 1), search_result.artifacts.slice().len);
}

test "truncation middleware preserves details and counts them toward limit" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    var store = try tmpStore(allocator, &tmp);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    const details = "{\"ok\":false,\"exit_code\":42}";
    var middleware = TruncationMiddleware{ .store = &store, .limits = .{ .shell = 31 } };
    var result = try makeTextResult(allocator, "short", details);
    defer result.deinit(allocator);

    try middleware.apply(testInput("shell_execute", 5 + details.len), &result, allocator);

    try std.testing.expectEqual(@as(usize, 1), result.artifacts.slice().len);
    try std.testing.expectEqualStrings(details, result.details_json.slice());
    try std.testing.expect(result.content.slice()[0].text.text.len + result.details_json.slice().len <= 31);
}

test "truncation middleware truncates details that exceed limit" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    var store = try tmpStore(allocator, &tmp);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    const details = "{\"query\":\"abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz\"}";
    var middleware = TruncationMiddleware{ .store = &store, .limits = .{ .search = 32 } };
    var result = try makeTextResult(allocator, "short", details);
    defer result.deinit(allocator);

    try middleware.apply(testInput("search_text", 5 + details.len), &result, allocator);

    try std.testing.expectEqual(@as(usize, 1), result.artifacts.slice().len);
    try std.testing.expect(result.content.slice()[0].text.text.len + result.details_json.slice().len <= 32);
    try std.testing.expect(result.details_json.slice().len <= 32);
    try std.testing.expect(!std.mem.eql(u8, details, result.details_json.slice()));
}

test "truncation middleware ignores unknown tools without fallback" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    var store = try tmpStore(allocator, &tmp);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    var middleware = TruncationMiddleware{ .store = &store };
    var result = try makeTextResult(allocator, "0123456789abcdefghijklmnopqrst", "");
    defer result.deinit(allocator);

    try middleware.apply(testInput("profile_read", 30), &result, allocator);

    try std.testing.expectEqual(@as(usize, 0), result.artifacts.slice().len);
    try std.testing.expectEqualStrings("0123456789abcdefghijklmnopqrst", result.content.slice()[0].text.text);
}

test "truncation middleware preserves first bytes verbatim" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    var store = try tmpStore(allocator, &tmp);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    const raw_output = "0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz";
    var middleware = TruncationMiddleware{ .store = &store, .limits = .{ .shell = 90 } };
    var result = try makeTextResult(allocator, raw_output, "");
    defer result.deinit(allocator);

    try middleware.apply(testInput("shell_execute", raw_output.len), &result, allocator);

    const compact_id_len = @min(result.artifacts.slice()[0].artifact_id.len, 12);
    const marker_len = marker_prefix.len + compact_id_len + marker_suffix.len;
    const head_len = 90 - marker_len;
    try std.testing.expect(result.content.slice()[0].text.text.len + result.details_json.slice().len <= 90);
    try std.testing.expectEqualStrings(raw_output[0..head_len], result.content.slice()[0].text.text[0..head_len]);
}
