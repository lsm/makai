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

        if (raw_output.len <= limit) return;

        var reference = try self.store.write(.{
            .content = raw_output,
            .mime_type = mime_text_plain,
            .description = "raw tool output",
        });
        errdefer reference.deinit(allocator);

        const truncated = try truncateWithMarker(allocator, raw_output, limit, reference.artifact_id);
        errdefer allocator.free(truncated);

        const new_content = try allocator.alloc(ai_types.UserContentPart, 1);
        errdefer allocator.free(new_content);
        new_content[0] = .{ .text = .{ .text = truncated } };

        const artifacts = try appendArtifactReference(allocator, result.artifacts.slice(), reference);
        errdefer {
            for (artifacts) |*artifact| artifact.deinit(allocator);
            allocator.free(artifacts);
        }

        result.content.deinit(allocator);
        result.details_json.deinit(allocator);
        result.artifacts.deinit(allocator);

        result.* = .{
            .content = ai_types.OwnedSlice(ai_types.UserContentPart).initOwned(new_content),
            .details_json = ai_types.OwnedSlice(u8).initBorrowed(""),
            .artifacts = ai_types.OwnedSlice(ai_types.ArtifactReference).initOwned(artifacts),
        };
    }
};

fn classifyTool(tool_name: []const u8) ToolKind {
    if (std.mem.indexOf(u8, tool_name, "shell") != null) return .shell;
    if (std.mem.indexOf(u8, tool_name, "file") != null or std.mem.indexOf(u8, tool_name, "read") != null or std.mem.indexOf(u8, tool_name, "write") != null or std.mem.indexOf(u8, tool_name, "edit") != null) return .file;
    if (std.mem.indexOf(u8, tool_name, "search") != null or std.mem.indexOf(u8, tool_name, "grep") != null) return .search;
    return .other;
}

fn collectToolOutput(allocator: std.mem.Allocator, result: AgentToolResult) ![]u8 {
    var total: usize = 0;
    for (result.content.slice()) |part| switch (part) {
        .text => |text| total += text.text.len,
        .image => {},
    };
    if (result.getDetailsJson()) |details| total += details.len;

    var out = try allocator.alloc(u8, total);
    var offset: usize = 0;
    for (result.content.slice()) |part| switch (part) {
        .text => |text| {
            @memcpy(out[offset .. offset + text.text.len], text.text);
            offset += text.text.len;
        },
        .image => {},
    };
    if (result.getDetailsJson()) |details| {
        @memcpy(out[offset .. offset + details.len], details);
    }
    return out;
}

fn truncateWithMarker(allocator: std.mem.Allocator, raw_output: []const u8, limit: usize, artifact_id: []const u8) ![]u8 {
    const head_len = @min(limit, raw_output.len);
    return std.fmt.allocPrint(allocator, "{s}" ++ marker_prefix ++ "{s}" ++ marker_suffix, .{ raw_output[0..head_len], artifact_id[0..@min(artifact_id.len, 12)] });
}

fn appendArtifactReference(allocator: std.mem.Allocator, existing: []const ai_types.ArtifactReference, new_reference: ai_types.ArtifactReference) ![]ai_types.ArtifactReference {
    const out = try allocator.alloc(ai_types.ArtifactReference, existing.len + 1);
    errdefer allocator.free(out);

    for (existing, 0..) |artifact, i| {
        out[i] = try cloneArtifactReference(allocator, artifact);
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

    const raw_output = "abcdefghijklmnopqrstuvwxyz0123456789";
    var middleware = TruncationMiddleware{ .store = &store, .limits = .{ .shell = 32 } };
    var result = try makeTextResult(allocator, raw_output, "");
    defer result.deinit(allocator);

    try middleware.apply(testInput("shell_execute", raw_output.len), &result, allocator);

    try std.testing.expectEqual(@as(usize, 1), result.artifacts.slice().len);
    const artifact_id = result.artifacts.slice()[0].artifact_id;
    const text = result.content.slice()[0].text.text;
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

    try std.testing.expectEqualStrings(raw_output[0..90], result.content.slice()[0].text.text[0..90]);
}
