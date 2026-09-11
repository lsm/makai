const std = @import("std");
const provider_types = @import("protocol_types");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const Ulid = provider_types.Ulid;
pub const generateUlid = provider_types.generateUlid;
pub const ulidToString = provider_types.ulidToString;
pub const parseUlid = provider_types.parseUlid;

pub const ToolErrorCode = enum {
    invalid_request,
    tool_not_found,
    tool_execution_error,
    tool_timeout,
    rate_limited,
    internal_error,
    tool_unavailable,
    invalid_arguments,
    artifact_not_found,
    hashline_disabled,
    stale_anchor,
};

pub const ToolMetadata = struct {
    name: []const u8,
    description: []const u8,
    parameters_schema_json: []const u8,
    version: []const u8 = "1.0.0",
    supports_streaming: bool = false,
    estimated_duration_ms: ?u32 = null,
    is_destructive: bool = false,
    required_permissions: ?[]const []const u8 = null,
};

pub const ToolRegisterRequest = struct {
    tool: ToolMetadata,
    callback_url: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getCallbackUrl(self: *const ToolRegisterRequest) ?[]const u8 {
        const url = self.callback_url.slice();
        return if (url.len > 0) url else null;
    }
};

pub const ToolRegisterResponse = struct {
    tool_id: []const u8,
    registered_at: i64,
};

pub const ToolUnregisterRequest = struct {
    tool_id: []const u8,
};

pub const ToolListRequest = struct {
    prefix: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    supports_streaming: ?bool = null,

    pub fn getPrefix(self: *const ToolListRequest) ?[]const u8 {
        const prefix = self.prefix.slice();
        return if (prefix.len > 0) prefix else null;
    }
};

pub const ToolListResponse = struct {
    tools: []const ToolMetadata,
};

pub const ToolExecuteRequest = struct {
    execution_id: Ulid,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
    timeout_ms: ?u32 = null,
    stream_callback_url: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getStreamCallbackUrl(self: *const ToolExecuteRequest) ?[]const u8 {
        const url = self.stream_callback_url.slice();
        return if (url.len > 0) url else null;
    }
};

pub const ToolStreamUpdate = struct {
    execution_id: Ulid,
    tool_call_id: []const u8,
    partial_result_json: []const u8,
    progress: ?u8 = null,
    status: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getStatus(self: *const ToolStreamUpdate) ?[]const u8 {
        const status = self.status.slice();
        return if (status.len > 0) status else null;
    }
};

pub const ToolExecuteResult = struct {
    execution_id: Ulid,
    tool_call_id: []const u8,
    result_json: []const u8,
    is_error: bool = false,
    error_message: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    details_json: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    artifacts: OwnedSlice(ArtifactReference) = OwnedSlice(ArtifactReference).initBorrowed(&.{}),
    duration_ms: u32,

    pub fn getErrorMessage(self: *const ToolExecuteResult) ?[]const u8 {
        const msg = self.error_message.slice();
        return if (msg.len > 0) msg else null;
    }

    pub fn getDetailsJson(self: *const ToolExecuteResult) ?[]const u8 {
        const details = self.details_json.slice();
        return if (details.len > 0) details else null;
    }
};

pub const ToolCancelRequest = struct {
    execution_id: Ulid,
    reason: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getReason(self: *const ToolCancelRequest) ?[]const u8 {
        const reason = self.reason.slice();
        return if (reason.len > 0) reason else null;
    }
};

pub const ToolExecutionStatus = enum {
    pending,
    running,
    streaming,
    completed,
    failed,
    cancelled,
    timeout,
};

pub const ToolExecutionInfo = struct {
    execution_id: Ulid,
    tool_name: []const u8,
    status: ToolExecutionStatus,
    started_at: i64,
    completed_at: ?i64 = null,
};

pub const ArtifactReference = struct {
    artifact_id: []const u8,
    uri: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    mime_type: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    byte_size: ?u64 = null,
    sha256: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    description: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getUri(self: *const ArtifactReference) ?[]const u8 {
        const value = self.uri.slice();
        return if (value.len > 0) value else null;
    }

    pub fn getMimeType(self: *const ArtifactReference) ?[]const u8 {
        const value = self.mime_type.slice();
        return if (value.len > 0) value else null;
    }

    pub fn getSha256(self: *const ArtifactReference) ?[]const u8 {
        const value = self.sha256.slice();
        return if (value.len > 0) value else null;
    }

    pub fn getDescription(self: *const ArtifactReference) ?[]const u8 {
        const value = self.description.slice();
        return if (value.len > 0) value else null;
    }

    pub fn deinit(self: *ArtifactReference, allocator: std.mem.Allocator) void {
        allocator.free(self.artifact_id);
        self.uri.deinit(allocator);
        self.mime_type.deinit(allocator);
        self.sha256.deinit(allocator);
        self.description.deinit(allocator);
    }
};

pub const ArtifactRetrieveRequest = struct {
    artifact_id: []const u8,
    byte_offset: ?u64 = null,
    byte_limit: ?u64 = null,
};

pub const ArtifactRetrieveResponse = struct {
    artifact: ArtifactReference,
    content_json: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getContentJson(self: *const ArtifactRetrieveResponse) ?[]const u8 {
        const value = self.content_json.slice();
        return if (value.len > 0) value else null;
    }

    pub fn deinit(self: *ArtifactRetrieveResponse, allocator: std.mem.Allocator) void {
        self.artifact.deinit(allocator);
        self.content_json.deinit(allocator);
    }
};

pub const ArtifactSearchRequest = struct {
    query: []const u8,
    limit: ?u32 = null,
};

pub const ArtifactSearchResult = struct {
    artifact: ArtifactReference,
    snippet: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    score: ?f32 = null,

    pub fn getSnippet(self: *const ArtifactSearchResult) ?[]const u8 {
        const value = self.snippet.slice();
        return if (value.len > 0) value else null;
    }

    pub fn deinit(self: *ArtifactSearchResult, allocator: std.mem.Allocator) void {
        self.artifact.deinit(allocator);
        self.snippet.deinit(allocator);
    }
};

pub const ArtifactSearchResponse = struct {
    results: []const ArtifactSearchResult,

    pub fn deinit(self: *ArtifactSearchResponse, allocator: std.mem.Allocator) void {
        const mut_results: []ArtifactSearchResult = @constCast(self.results);
        for (mut_results) |*result| result.deinit(allocator);
        allocator.free(self.results);
    }
};

pub const HashlineEditOperation = enum {
    replace_range,
    insert_before,
    insert_after,
    delete_range,
};

pub const HashlineReadRequest = struct {
    path: []const u8,
    feature_enabled: bool = false,
    byte_limit: ?u64 = null,
};

pub const HashlineLine = struct {
    line: u32,
    hash: []const u8,
    text: []const u8,

    pub fn deinit(self: *HashlineLine, allocator: std.mem.Allocator) void {
        allocator.free(self.hash);
        allocator.free(self.text);
    }
};

pub const HashlineReadResponse = struct {
    path: []const u8,
    lines: []const HashlineLine,

    pub fn deinit(self: *HashlineReadResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        const mut_lines: []HashlineLine = @constCast(self.lines);
        for (mut_lines) |*line| line.deinit(allocator);
        allocator.free(self.lines);
    }
};

pub const HashlineEditRequest = struct {
    path: []const u8,
    operation: HashlineEditOperation,
    start_line: u32,
    start_hash: []const u8,
    end_line: ?u32 = null,
    end_hash: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    replacement: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    feature_enabled: bool = false,

    pub fn getEndHash(self: *const HashlineEditRequest) ?[]const u8 {
        const value = self.end_hash.slice();
        return if (value.len > 0) value else null;
    }

    pub fn getReplacement(self: *const HashlineEditRequest) ?[]const u8 {
        const value = self.replacement.slice();
        return if (value.len > 0) value else null;
    }
};

pub const HashlineEditResponse = struct {
    path: []const u8,
    applied: bool,
    new_artifact: ?ArtifactReference = null,

    pub fn deinit(self: *HashlineEditResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.new_artifact) |*artifact| artifact.deinit(allocator);
    }
};

pub const Goodbye = struct {
    reason: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getReason(self: *const Goodbye) ?[]const u8 {
        const reason = self.reason.slice();
        return if (reason.len > 0) reason else null;
    }

    pub fn deinit(self: *Goodbye, allocator: std.mem.Allocator) void {
        self.reason.deinit(allocator);
    }
};

pub const Payload = union(enum) {
    tool_register: ToolRegisterRequest,
    tool_registered: ToolRegisterResponse,
    tool_unregister: ToolUnregisterRequest,
    tool_unregistered: struct { tool_id: []const u8 },

    tool_list: ToolListRequest,
    tool_list_response: ToolListResponse,

    tool_execute: ToolExecuteRequest,
    tool_stream: ToolStreamUpdate,
    tool_result: ToolExecuteResult,
    tool_cancel: ToolCancelRequest,
    tool_cancelled: struct { execution_id: Ulid },
    tool_error: struct { execution_id: Ulid, code: ToolErrorCode, message: []const u8 },
    tool_status: struct { execution_id: Ulid },
    tool_status_response: ToolExecutionInfo,

    artifact_retrieve: ArtifactRetrieveRequest,
    artifact_retrieved: ArtifactRetrieveResponse,
    artifact_search: ArtifactSearchRequest,
    artifact_search_result: ArtifactSearchResponse,

    hashline_read: HashlineReadRequest,
    hashline_read_result: HashlineReadResponse,
    hashline_edit: HashlineEditRequest,
    hashline_edit_result: HashlineEditResponse,

    ping: void,
    pong: struct { ping_id: OwnedSlice(u8) },

    goodbye: Goodbye,

    pub fn deinit(self: *Payload, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tool_register => |*req| {
                const tool = req.tool;
                allocator.free(tool.name);
                allocator.free(tool.description);
                allocator.free(tool.parameters_schema_json);
                allocator.free(tool.version);
                if (tool.required_permissions) |perms| {
                    for (perms) |p| allocator.free(p);
                    allocator.free(perms);
                }
                req.callback_url.deinit(allocator);
            },
            .tool_registered => |*res| allocator.free(res.tool_id),
            .tool_unregister => |*req| allocator.free(req.tool_id),
            .tool_unregistered => |*res| allocator.free(res.tool_id),
            .tool_list => |*req| req.prefix.deinit(allocator),
            .tool_list_response => |*res| {
                for (res.tools) |*tool| {
                    allocator.free(tool.name);
                    allocator.free(tool.description);
                    allocator.free(tool.parameters_schema_json);
                    allocator.free(tool.version);
                    if (tool.required_permissions) |perms| {
                        for (perms) |p| allocator.free(p);
                        allocator.free(perms);
                    }
                }
                allocator.free(res.tools);
            },
            .tool_execute => |*req| {
                allocator.free(req.tool_call_id);
                allocator.free(req.tool_name);
                allocator.free(req.args_json);
                req.stream_callback_url.deinit(allocator);
            },
            .tool_stream => |*upd| {
                allocator.free(upd.tool_call_id);
                allocator.free(upd.partial_result_json);
                upd.status.deinit(allocator);
            },
            .tool_result => |*res| {
                allocator.free(res.tool_call_id);
                allocator.free(res.result_json);
                res.error_message.deinit(allocator);
                res.details_json.deinit(allocator);
                res.artifacts.deinit(allocator);
            },
            .tool_cancel => |*req| req.reason.deinit(allocator),
            .tool_error => |*err| allocator.free(err.message),
            .tool_status_response => |*info| allocator.free(info.tool_name),
            .artifact_retrieve => |*req| allocator.free(req.artifact_id),
            .artifact_retrieved => |*res| res.deinit(allocator),
            .artifact_search => |*req| allocator.free(req.query),
            .artifact_search_result => |*res| res.deinit(allocator),
            .hashline_read => |*req| allocator.free(req.path),
            .hashline_read_result => |*res| res.deinit(allocator),
            .hashline_edit => |*req| {
                allocator.free(req.path);
                allocator.free(req.start_hash);
                req.end_hash.deinit(allocator);
                req.replacement.deinit(allocator);
            },
            .hashline_edit_result => |*res| res.deinit(allocator),
            .pong => |*p| p.ping_id.deinit(allocator),
            .goodbye => |*g| g.deinit(allocator),
            .ping, .tool_cancelled, .tool_status => {},
        }
    }
};

pub const Envelope = struct {
    version: u8 = 1,
    server_id: Ulid,
    message_id: Ulid,
    sequence: u64,
    in_reply_to: ?Ulid = null,
    timestamp: i64,
    payload: Payload,

    pub fn deinit(self: *Envelope, allocator: std.mem.Allocator) void {
        self.payload.deinit(allocator);
    }
};

test "ToolErrorCode enum values" {
    try std.testing.expectEqual(ToolErrorCode.invalid_request, .invalid_request);
    try std.testing.expectEqual(ToolErrorCode.tool_not_found, .tool_not_found);
}

test "ToolExecutionStatus enum values" {
    try std.testing.expectEqual(ToolExecutionStatus.pending, .pending);
    try std.testing.expectEqual(ToolExecutionStatus.running, .running);
    try std.testing.expectEqual(ToolExecutionStatus.streaming, .streaming);
}

test "Payload deinit for tool_register" {
    const allocator = std.testing.allocator;

    const name = try allocator.dupe(u8, "test_tool");
    const desc = try allocator.dupe(u8, "A test tool");
    const schema = try allocator.dupe(u8, "{}");
    const version = try allocator.dupe(u8, "1.0.0");

    var payload = Payload{
        .tool_register = .{
            .tool = .{
                .name = name,
                .description = desc,
                .parameters_schema_json = schema,
                .version = version,
            },
        },
    };

    payload.deinit(allocator);
}
