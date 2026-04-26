const std = @import("std");
const provider_types = @import("protocol_types");
const model_catalog_types = @import("model_catalog_types");
const OwnedSlice = @import("owned_slice").OwnedSlice;

/// Re-export Uuid from provider types for convenience
pub const Uuid = provider_types.Uuid;
pub const generateUuid = provider_types.generateUuid;
pub const uuidToString = provider_types.uuidToString;
pub const parseUuid = provider_types.parseUuid;

/// Re-export provider ack/nack/error-code envelope types so that the agent
/// passthrough emits the same shape as the provider protocol.
pub const Ack = provider_types.Ack;
pub const Nack = provider_types.Nack;
pub const ErrorCode = provider_types.ErrorCode;

/// Re-export shared model catalog types — the agent passthrough must return
/// the same typed shape as the provider protocol (no raw JSON blob passthrough).
/// See `docs/v1-sdk-agent-provider-spec.md §6`.
pub const ModelDescriptor = model_catalog_types.ModelDescriptor;
pub const ModelCapability = model_catalog_types.ModelCapability;
pub const ModelLifecycle = model_catalog_types.ModelLifecycle;
pub const ModelSource = model_catalog_types.ModelSource;
pub const ReasoningLevel = model_catalog_types.ReasoningLevel;
pub const AuthStatus = model_catalog_types.AuthStatus;
pub const MetadataEntry = model_catalog_types.MetadataEntry;
pub const ModelsResponse = model_catalog_types.ModelsResponse;

/// Reuse provider's `ModelsRequest` shape verbatim so the agent passthrough is
/// indistinguishable from the canonical provider protocol on the wire.
pub const ModelsRequest = provider_types.ModelsRequest;

// ============================================================================
// Agent Protocol Types
// ============================================================================
//
// These types define the wire protocol for distributed agent communication.
// This protocol allows agents to run on separate processes/machines from
// clients and providers.
//
// Architecture:
//   Client <--protocol/agent--> Agent <--protocol/provider--> Provider
//
// The agent protocol enables:
// - Remote agent execution
// - Agent service scaling
// - Tool execution distribution

/// Error codes specific to agent protocol
pub const AgentErrorCode = enum {
    invalid_request,
    agent_not_found,
    tool_not_found,
    tool_execution_error,
    context_overflow,
    rate_limited,
    internal_error,
    agent_busy,
    session_expired,
    /// No credentials available for the upstream provider; client must
    /// authenticate. Mirrors `protocol/provider` `auth_required` so the
    /// agent surface can propagate auth-required signals from the request
    /// path. M-007 will add `auth_refresh_failed` and `auth_expired` as
    /// refresh-on-expiry semantics land.
    auth_required,
};

/// Request to start an agent session
pub const AgentStartRequest = struct {
    /// Agent configuration (model, tools, etc.)
    config_json: []const u8,
    /// Initial system prompt
    system_prompt: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    /// Session ID for resumption (null for new session)
    session_id: ?Uuid = null,

    pub fn getSystemPrompt(self: *const AgentStartRequest) ?[]const u8 {
        const prompt = self.system_prompt.slice();
        return if (prompt.len > 0) prompt else null;
    }
};

/// Request to send a message to an agent
pub const AgentMessageRequest = struct {
    /// Target agent session
    session_id: Uuid,
    /// Message to send
    message_json: []const u8,
    /// Options for this message
    options_json: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getOptionsJson(self: *const AgentMessageRequest) ?[]const u8 {
        const options = self.options_json.slice();
        return if (options.len > 0) options else null;
    }
};

/// Request to stop an agent session
pub const AgentStopRequest = struct {
    /// Target agent session
    session_id: Uuid,
    /// Reason for stopping
    reason: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getReason(self: *const AgentStopRequest) ?[]const u8 {
        const reason = self.reason.slice();
        return if (reason.len > 0) reason else null;
    }
};

/// Request to execute a tool (from agent to tool server)
pub const ToolExecuteRequest = struct {
    /// Tool call ID for correlation
    tool_call_id: []const u8,
    /// Tool name
    tool_name: []const u8,
    /// Arguments as JSON
    args_json: []const u8,
    /// Partial result callback URL (for streaming tools)
    callback_url: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getCallbackUrl(self: *const ToolExecuteRequest) ?[]const u8 {
        const url = self.callback_url.slice();
        return if (url.len > 0) url else null;
    }
};

/// Response from tool execution
pub const ToolExecuteResponse = struct {
    /// Tool call ID for correlation
    tool_call_id: []const u8,
    /// Result content as JSON array of UserContentPart
    result_json: []const u8,
    /// Whether execution failed
    is_error: bool = false,
    /// Additional details JSON (optional)
    details_json: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getDetailsJson(self: *const ToolExecuteResponse) ?[]const u8 {
        const details = self.details_json.slice();
        return if (details.len > 0) details else null;
    }
};

/// Request to list available tools
pub const ToolListRequest = struct {
    /// Filter by tool name prefix (optional)
    prefix: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getPrefix(self: *const ToolListRequest) ?[]const u8 {
        const prefix = self.prefix.slice();
        return if (prefix.len > 0) prefix else null;
    }
};

/// Tool definition for listing
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters_schema_json: []const u8,
};

/// Response from tool list request
pub const ToolListResponse = struct {
    tools: []const ToolDefinition,
};

/// Agent session status
pub const AgentStatus = enum {
    starting,
    ready,
    processing,
    waiting_for_tool,
    stopping,
    stopped,
    @"error",
};

/// Agent session info
pub const AgentSessionInfo = struct {
    session_id: Uuid,
    status: AgentStatus,
    model: []const u8,
    message_count: u32,
    created_at: i64,
    updated_at: i64,
};

pub const AgentStopped = struct {
    session_id: Uuid,
    reason: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getReason(self: *const AgentStopped) ?[]const u8 {
        const reason = self.reason.slice();
        return if (reason.len > 0) reason else null;
    }

    pub fn deinit(self: *AgentStopped, allocator: std.mem.Allocator) void {
        self.reason.deinit(allocator);
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

/// Agent protocol payload
pub const Payload = union(enum) {
    // Client -> Agent Server
    agent_start: AgentStartRequest,
    agent_message: AgentMessageRequest,
    agent_stop: AgentStopRequest,
    agent_status: struct { session_id: Uuid },
    tool_list: ToolListRequest,
    /// Passthrough model discovery request — delegates to the provider protocol
    /// and returns the same `ModelsResponse` shape. See spec §6.
    models_request: ModelsRequest,

    // Agent Server -> Client
    agent_started: struct { session_id: Uuid },
    agent_event: []const u8, // JSON-encoded AgentEvent
    agent_result: []const u8, // JSON-encoded AgentLoopResult
    agent_stopped: AgentStopped,
    agent_error: struct { code: AgentErrorCode, message: []const u8 },
    session_info: AgentSessionInfo,
    tool_list_response: ToolListResponse,
    /// Acknowledgment for two-step request/response flows (e.g. models_request).
    ack: Ack,
    /// Negative acknowledgment used to surface typed protocol errors such as
    /// `not_implemented` for capability probes.
    nack: Nack,
    /// Passthrough models response — same typed shape as provider protocol.
    models_response: ModelsResponse,

    // Agent -> Tool Server
    tool_execute: ToolExecuteRequest,

    // Tool Server -> Agent
    tool_result: ToolExecuteResponse,
    tool_streaming: struct { tool_call_id: []const u8, partial_json: []const u8 },

    // Keepalive (reused from provider protocol)
    ping: void,
    pong: struct { ping_id: OwnedSlice(u8) },

    // Connection management
    goodbye: Goodbye,

    pub fn deinit(self: *Payload, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .agent_start => |*req| {
                allocator.free(req.config_json);
                req.system_prompt.deinit(allocator);
            },
            .agent_message => |*req| {
                allocator.free(req.message_json);
                req.options_json.deinit(allocator);
            },
            .agent_stop => |*req| {
                req.reason.deinit(allocator);
            },
            .tool_execute => |*req| {
                allocator.free(req.tool_call_id);
                allocator.free(req.tool_name);
                allocator.free(req.args_json);
                req.callback_url.deinit(allocator);
            },
            .tool_result => |*res| {
                allocator.free(res.tool_call_id);
                allocator.free(res.result_json);
                res.details_json.deinit(allocator);
            },
            .tool_list => |*req| {
                req.prefix.deinit(allocator);
            },
            .tool_list_response => |*res| {
                for (res.tools) |*tool| {
                    allocator.free(tool.name);
                    allocator.free(tool.description);
                    allocator.free(tool.parameters_schema_json);
                }
                allocator.free(res.tools);
            },
            .agent_event => |e| allocator.free(e),
            .agent_result => |r| allocator.free(r),
            .agent_stopped => |*s| s.deinit(allocator),
            .agent_error => |*e| allocator.free(e.message),
            .pong => |*p| p.ping_id.deinit(allocator),
            .goodbye => |*g| g.deinit(allocator),
            .tool_streaming => |*t| {
                allocator.free(t.tool_call_id);
                allocator.free(t.partial_json);
            },
            .session_info => |*s| allocator.free(s.model),
            .models_request => |*req| req.deinit(allocator),
            .models_response => |*res| res.deinit(allocator),
            .nack => |*n| n.deinit(allocator),
            .ack, .agent_started, .agent_status, .ping => {},
        }
    }
};

/// Agent protocol envelope
pub const Envelope = struct {
    /// Protocol version
    version: u8 = 1,
    /// Session identifier (stable for session lifecycle)
    session_id: Uuid,
    /// Message ID (unique per message)
    message_id: Uuid,
    /// Sequence number within session (starts at 1)
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
test "AgentErrorCode enum values" {
    try std.testing.expectEqual(AgentErrorCode.invalid_request, .invalid_request);
    try std.testing.expectEqual(AgentErrorCode.agent_not_found, .agent_not_found);
}

test "AgentStatus enum values" {
    try std.testing.expectEqual(AgentStatus.starting, .starting);
    try std.testing.expectEqual(AgentStatus.ready, .ready);
    try std.testing.expectEqual(AgentStatus.processing, .processing);
}

test "Payload deinit for agent_start" {
    const allocator = std.testing.allocator;

    const config = try allocator.dupe(u8, "{\"model\":\"test\"}");
    var payload = Payload{
        .agent_start = .{
            .config_json = config,
        },
    };

    payload.deinit(allocator);
    // Should not leak
}

test "Payload deinit for models_request frees owned filters" {
    const allocator = std.testing.allocator;

    var payload = Payload{
        .models_request = .{
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic")),
            .api = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic-messages")),
            .model_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "claude-sonnet-4-5")),
            .include_deprecated = false,
            .include_login_required = true,
        },
    };

    payload.deinit(allocator);
}

test "Payload deinit for models_response frees descriptors" {
    const allocator = std.testing.allocator;

    const capabilities = try allocator.alloc(ModelCapability, 1);
    capabilities[0] = .chat;

    const descriptors = try allocator.alloc(ModelDescriptor, 1);
    descriptors[0] = .{
        .model_ref = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic/anthropic-messages@claude-sonnet-4-5")),
        .model_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "claude-sonnet-4-5")),
        .display_name = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "Claude Sonnet 4.5")),
        .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic")),
        .api = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic-messages")),
        .auth_status = .authenticated,
        .lifecycle = .stable,
        .capabilities = OwnedSlice(ModelCapability).initOwned(capabilities),
        .source = .dynamic,
    };

    var payload = Payload{
        .models_response = .{
            .models = OwnedSlice(ModelDescriptor).initOwned(descriptors),
            .fetched_at_ms = 0,
            .cache_max_age_ms = 0,
        },
    };

    payload.deinit(allocator);
}

test "Payload deinit for nack frees reason" {
    const allocator = std.testing.allocator;

    var payload = Payload{
        .nack = .{
            .rejected_id = generateUuid(),
            .reason = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "not implemented")),
            .error_code = .not_implemented,
        },
    };

    payload.deinit(allocator);
}
