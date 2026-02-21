const std = @import("std");
const provider_types = @import("protocol_types");
const OwnedSlice = @import("owned_slice").OwnedSlice;

/// Re-export Uuid from provider types for convenience
pub const Uuid = provider_types.Uuid;
pub const generateUuid = provider_types.generateUuid;
pub const uuidToString = provider_types.uuidToString;
pub const parseUuid = provider_types.parseUuid;

// ============================================================================
// Tool Protocol Types
// ============================================================================
//
// These types define the wire protocol for distributed tool communication.
// This protocol allows tools to run on separate processes/machines from
// the agent.
//
// Architecture:
//   Agent <--protocol/tool--> Tool Server
//
// The tool protocol enables:
// - Remote tool execution
// - Tool service scaling
// - Sandboxed tool execution
// - Streaming tool results

/// Error codes specific to tool protocol
pub const ToolErrorCode = enum {
    invalid_request,
    tool_not_found,
    tool_execution_error,
    tool_timeout,
    rate_limited,
    internal_error,
    tool_unavailable,
    invalid_arguments,
};

/// Tool metadata for registration
pub const ToolMetadata = struct {
    /// Unique tool name
    name: []const u8,
    /// Human-readable description
    description: []const u8,
    /// JSON Schema for parameters
    parameters_schema_json: []const u8,
    /// Tool version
    version: []const u8 = "1.0.0",
    /// Whether tool supports streaming results
    supports_streaming: bool = false,
    /// Estimated execution time in milliseconds (optional)
    estimated_duration_ms: ?u32 = null,
    /// Whether tool is destructive (modifies state)
    is_destructive: bool = false,
    /// Required permissions
    required_permissions: ?[]const []const u8 = null,
};

/// Request to register a tool with the tool server
pub const ToolRegisterRequest = struct {
    /// Tool metadata
    tool: ToolMetadata,
    /// Callback URL for execution requests (for remote tools)
    callback_url: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getCallbackUrl(self: *const ToolRegisterRequest) ?[]const u8 {
        const url = self.callback_url.slice();
        return if (url.len > 0) url else null;
    }
};

/// Response from tool registration
pub const ToolRegisterResponse = struct {
    /// Assigned tool ID
    tool_id: []const u8,
    /// Registration timestamp
    registered_at: i64,
};

/// Request to unregister a tool
pub const ToolUnregisterRequest = struct {
    tool_id: []const u8,
};

/// Request to list available tools
pub const ToolListRequest = struct {
    /// Filter by name prefix
    prefix: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    /// Filter by capability
    supports_streaming: ?bool = null,

    pub fn getPrefix(self: *const ToolListRequest) ?[]const u8 {
        const prefix = self.prefix.slice();
        return if (prefix.len > 0) prefix else null;
    }
};

/// Response from tool list request
pub const ToolListResponse = struct {
    tools: []const ToolMetadata,
};

/// Request to execute a tool
pub const ToolExecuteRequest = struct {
    /// Execution ID for correlation
    execution_id: Uuid,
    /// Tool call ID (from LLM)
    tool_call_id: []const u8,
    /// Tool name
    tool_name: []const u8,
    /// Arguments as JSON
    args_json: []const u8,
    /// Timeout in milliseconds
    timeout_ms: ?u32 = null,
    /// Callback URL for streaming results
    stream_callback_url: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getStreamCallbackUrl(self: *const ToolExecuteRequest) ?[]const u8 {
        const url = self.stream_callback_url.slice();
        return if (url.len > 0) url else null;
    }
};

/// Streaming update during tool execution
pub const ToolStreamUpdate = struct {
    execution_id: Uuid,
    tool_call_id: []const u8,
    /// Partial result as JSON
    partial_result_json: []const u8,
    /// Progress percentage (0-100)
    progress: ?u8 = null,
    /// Status message
    status: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getStatus(self: *const ToolStreamUpdate) ?[]const u8 {
        const status = self.status.slice();
        return if (status.len > 0) status else null;
    }
};

/// Final result from tool execution
pub const ToolExecuteResult = struct {
    execution_id: Uuid,
    tool_call_id: []const u8,
    /// Result content as JSON array of UserContentPart
    result_json: []const u8,
    /// Whether execution failed
    is_error: bool = false,
    /// Error message (if failed)
    error_message: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    /// Additional details JSON
    details_json: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    /// Execution duration in milliseconds
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

/// Request to cancel a tool execution
pub const ToolCancelRequest = struct {
    execution_id: Uuid,
    reason: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getReason(self: *const ToolCancelRequest) ?[]const u8 {
        const reason = self.reason.slice();
        return if (reason.len > 0) reason else null;
    }
};

/// Tool execution status
pub const ToolExecutionStatus = enum {
    pending,
    running,
    streaming,
    completed,
    failed,
    cancelled,
    timeout,
};

/// Tool execution info
pub const ToolExecutionInfo = struct {
    execution_id: Uuid,
    tool_name: []const u8,
    status: ToolExecutionStatus,
    started_at: i64,
    completed_at: ?i64 = null,
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

/// Tool protocol payload
pub const Payload = union(enum) {
    // Tool Registration
    tool_register: ToolRegisterRequest,
    tool_registered: ToolRegisterResponse,
    tool_unregister: ToolUnregisterRequest,
    tool_unregistered: struct { tool_id: []const u8 },

    // Tool Discovery
    tool_list: ToolListRequest,
    tool_list_response: ToolListResponse,

    // Tool Execution
    tool_execute: ToolExecuteRequest,
    tool_stream: ToolStreamUpdate,
    tool_result: ToolExecuteResult,
    tool_cancel: ToolCancelRequest,
    tool_cancelled: struct { execution_id: Uuid },
    tool_error: struct { execution_id: Uuid, code: ToolErrorCode, message: []const u8 },
    tool_status: struct { execution_id: Uuid },
    tool_status_response: ToolExecutionInfo,

    // Keepalive
    ping: void,
    pong: struct { ping_id: OwnedSlice(u8) },

    // Connection management
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
            },
            .tool_cancel => |*req| req.reason.deinit(allocator),
            .tool_error => |*err| allocator.free(err.message),
            .pong => |*p| p.ping_id.deinit(allocator),
            .goodbye => |*g| g.deinit(allocator),
            .ping, .tool_cancelled, .tool_status, .tool_status_response => {},
        }
    }
};

/// Tool protocol envelope
pub const Envelope = struct {
    /// Protocol version
    version: u8 = 1,
    /// Tool server identifier
    server_id: Uuid,
    /// Message ID (unique per message)
    message_id: Uuid,
    /// Sequence number within connection
    sequence: u64,
    /// For request/response correlation
    in_reply_to: ?Uuid = null,
    /// Unix timestamp in milliseconds
    timestamp: i64,
    /// The actual payload
    payload: Payload,

    pub fn deinit(self: *Envelope, allocator: std.mem.Allocator) void {
        self.payload.deinit(allocator);
    }
};

// Tests
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
    // Should not leak
}
