const std = @import("std");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");
const owned_slice_mod = @import("owned_slice");

pub const OwnedSlice = owned_slice_mod.OwnedSlice;

// ============================================================================
// Agent Event Types
// ============================================================================

/// Payload for agent_end event
pub const AgentEndPayload = struct {
    messages: OwnedSlice(ai_types.Message) = OwnedSlice(ai_types.Message).initBorrowed(&.{}),

    pub fn deinit(self: *AgentEndPayload, allocator: std.mem.Allocator) void {
        self.messages.deinit(allocator);
    }
};

/// Payload for turn_end event
pub const TurnEndPayload = struct {
    message: ai_types.AssistantMessage,
    tool_results: OwnedSlice(ai_types.ToolResultMessage) = OwnedSlice(ai_types.ToolResultMessage).initBorrowed(&.{}),

    pub fn deinit(self: *TurnEndPayload, allocator: std.mem.Allocator) void {
        if (self.message.is_owned) {
            var mut_msg = self.message;
            mut_msg.deinit(allocator);
        }
        self.tool_results.deinit(allocator);
    }
};

/// Payload for message_start event
pub const MessageStartPayload = struct {
    message: ai_types.Message,
};

/// Payload for message_update event
pub const MessageUpdatePayload = struct {
    message: ai_types.AssistantMessage,
    event: ai_types.AssistantMessageEvent,
};

/// Payload for message_end event
pub const MessageEndPayload = struct {
    message: ai_types.Message,
};

/// Payload for tool_execution_start event
pub const ToolExecutionStartPayload = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
};

/// Payload for tool_execution_update event
pub const ToolExecutionUpdatePayload = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
    partial_result_json: []const u8,
};

/// Payload for tool_execution_end event
pub const ToolExecutionEndPayload = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    result_json: []const u8,
    is_error: bool,
};

/// Agent event types emitted during execution
pub const AgentEvent = union(enum) {
    // Agent lifecycle
    agent_start: void,
    agent_end: AgentEndPayload,

    // Turn lifecycle (turn = one assistant response + tool executions)
    turn_start: void,
    turn_end: TurnEndPayload,

    // Message lifecycle
    message_start: MessageStartPayload,
    message_update: MessageUpdatePayload,
    message_end: MessageEndPayload,

    // Tool execution lifecycle
    tool_execution_start: ToolExecutionStartPayload,
    tool_execution_update: ToolExecutionUpdatePayload,
    tool_execution_end: ToolExecutionEndPayload,
};

// ============================================================================
// Agent Tool Types
// ============================================================================

/// Tool result returned from execute
pub const AgentToolResult = struct {
    content: OwnedSlice(ai_types.UserContentPart) = OwnedSlice(ai_types.UserContentPart).initBorrowed(&.{}),
    details_json: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getDetailsJson(self: *const AgentToolResult) ?[]const u8 {
        const details = self.details_json.slice();
        return if (details.len > 0) details else null;
    }

    pub fn deinit(self: *AgentToolResult, allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
        self.details_json.deinit(allocator);
    }
};

/// Callback for streaming tool execution updates
pub const ToolUpdateCallback = *const fn (
    ctx: ?*anyopaque,
    tool_call_id: []const u8,
    tool_name: []const u8,
    partial_result_json: []const u8,
) void;

/// Tool execution function signature
pub const ToolExecuteFn = *const fn (
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!AgentToolResult;

/// Agent tool definition
pub const AgentTool = struct {
    label: []const u8, // Human-readable label for UI
    name: []const u8,
    description: []const u8,
    parameters_schema_json: []const u8,
    execute: ToolExecuteFn,

    /// Convert to ai_types.Tool for LLM requests
    pub fn toTool(self: AgentTool, allocator: std.mem.Allocator) !ai_types.Tool {
        _ = allocator;
        return .{
            .name = self.name,
            .description = self.description,
            .parameters_schema_json = self.parameters_schema_json,
        };
    }
};

// ============================================================================
// Protocol Client Interface
// ============================================================================

/// Options for protocol streaming (agent-level concerns only).
/// Transport and credential details are handled by the protocol client.
pub const ProtocolOptions = struct {
    api_key: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    cancel_token: ?ai_types.CancelToken = null,
    thinking_budgets: ?ai_types.ThinkingBudgets = null,
    max_retry_delay_ms: u32 = 60_000,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
};

/// Stream function signature for ProtocolClient.
pub const ProtocolStreamFn = *const fn (
    ctx: ?*anyopaque,
    model: ai_types.Model,
    context: ai_types.Context,
    options: ProtocolOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageEventStream;

/// Protocol client interface for agent loop.
/// Abstracts away transport, credentials, and provider specifics.
/// This is the single interface the agent loop uses to communicate
/// with the provider layer.
pub const ProtocolClient = struct {
    /// Stream function pointer
    stream_fn: ProtocolStreamFn,

    /// Context pointer passed to stream_fn
    ctx: ?*anyopaque = null,

    /// Convenience method to call the stream function
    pub fn stream(
        self: ProtocolClient,
        model: ai_types.Model,
        context: ai_types.Context,
        options: ProtocolOptions,
        allocator: std.mem.Allocator,
    ) anyerror!*event_stream.AssistantMessageEventStream {
        return self.stream_fn(self.ctx, model, context, options, allocator);
    }
};

// ============================================================================
// Legacy Stream Function (for backward compatibility)
// ============================================================================

/// Custom stream function for provider access.
/// If provided, used directly. Otherwise, falls back to registry lookup.
/// This allows both in-process (via registry) and remote (via protocol client) access.
/// Note: Prefer using ProtocolClient for new code.
pub const AgentStreamFn = *const fn (
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageEventStream;

// ============================================================================
// Agent Loop Config
// ============================================================================

/// Context transformation function - converts messages before LLM call
pub const TransformContextFn = *const fn (
    ctx: ?*anyopaque,
    messages: []const ai_types.Message,
    allocator: std.mem.Allocator,
) anyerror![]const ai_types.Message;

/// Steering message callback - returns messages to inject mid-run
pub const GetSteeringMessagesFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
) anyerror!?[]const ai_types.Message;

/// Follow-up message callback - returns messages after agent would stop
pub const GetFollowUpMessagesFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
) anyerror!?[]const ai_types.Message;

/// Convert AgentMessage to LLM Message (simplified - just filter for now)
pub const ConvertToLlmFn = *const fn (
    ctx: ?*anyopaque,
    messages: []const ai_types.Message,
    allocator: std.mem.Allocator,
) anyerror![]const ai_types.Message;

/// Dynamic API key resolution
pub const GetApiKeyFn = *const fn (
    ctx: ?*anyopaque,
    provider: []const u8,
) ?[]const u8;

/// Configuration for agent loop execution
pub const AgentLoopConfig = struct {
    // Required
    model: ai_types.Model,

    // Protocol client (single interface to provider layer)
    // This abstracts away transport, credentials, and provider specifics.
    protocol: ProtocolClient,

    // Tools (optional)
    tools: ?[]const AgentTool = null,

    // Streaming options (passed through to protocol)
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    api_key: ?[]const u8 = null,
    cancel_token: ?ai_types.CancelToken = null,

    // Agent-specific options
    max_iterations: ?u32 = null, // Max tool use iterations
    session_id: ?[]const u8 = null,
    thinking_budgets: ?ai_types.ThinkingBudgets = null,
    max_retry_delay_ms: ?u32 = 60_000,

    // Callbacks
    transform_context_fn: ?TransformContextFn = null,
    transform_context_ctx: ?*anyopaque = null,
    get_steering_messages_fn: ?GetSteeringMessagesFn = null,
    get_steering_messages_ctx: ?*anyopaque = null,
    get_follow_up_messages_fn: ?GetFollowUpMessagesFn = null,
    get_follow_up_messages_ctx: ?*anyopaque = null,
    convert_to_llm_fn: ?ConvertToLlmFn = null,
    convert_to_llm_ctx: ?*anyopaque = null,
    get_api_key_fn: ?GetApiKeyFn = null,
    get_api_key_ctx: ?*anyopaque = null,
};

// ============================================================================
// Agent Context
// ============================================================================

/// Context for agent execution - holds messages, system prompt, and tools
pub const AgentContext = struct {
    system_prompt: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    messages: std.ArrayList(ai_types.Message),
    tools: ?[]const AgentTool = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AgentContext {
        return .{
            .messages = .{},
            .allocator = allocator,
        };
    }

    pub fn getSystemPrompt(self: *const AgentContext) ?[]const u8 {
        const prompt = self.system_prompt.slice();
        return if (prompt.len > 0) prompt else null;
    }

    pub fn deinit(self: *AgentContext) void {
        // Free messages if owned
        for (self.messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.messages.deinit(self.allocator);
        self.system_prompt.deinit(self.allocator);
    }

    pub fn appendMessage(self: *AgentContext, msg: ai_types.Message) !void {
        try self.messages.append(self.allocator, msg);
    }

    pub fn messagesSlice(self: AgentContext) []const ai_types.Message {
        return self.messages.items;
    }
};

// ============================================================================
// Agent State
// ============================================================================

/// State tracked by the high-level Agent class
pub const AgentState = struct {
    system_prompt: []const u8 = "",
    model: ?ai_types.Model = null,
    thinking_level: ai_types.ThinkingLevel = .minimal,
    tools: []const AgentTool = &.{},
    messages: std.ArrayList(ai_types.Message),
    is_streaming: bool = false,
    stream_message: ?ai_types.Message = null,
    pending_tool_calls: std.StringHashMap(void),
    error_message: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AgentState {
        return .{
            .messages = .{},
            .pending_tool_calls = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn getErrorMessage(self: *const AgentState) ?[]const u8 {
        const msg = self.error_message.slice();
        return if (msg.len > 0) msg else null;
    }

    pub fn deinit(self: *AgentState) void {
        for (self.messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.messages.deinit(self.allocator);
        if (self.system_prompt.len > 0) self.allocator.free(self.system_prompt);
        self.error_message.deinit(self.allocator);
        // Note: doesn't own model or tools
        self.pending_tool_calls.deinit();
    }
};

// ============================================================================
// Agent Event Stream
// ============================================================================

/// Result from agent loop execution
pub const AgentLoopResult = struct {
    messages: OwnedSlice(ai_types.Message),
    final_message: ai_types.AssistantMessage,
    iterations: u32,

    pub fn deinit(self: *AgentLoopResult, allocator: std.mem.Allocator) void {
        self.messages.deinit(allocator);
        var final = self.final_message;
        final.deinit(allocator);
    }
};

/// Event stream for agent events
pub const AgentEventStream = event_stream.EventStream(AgentEvent, AgentLoopResult);

// ============================================================================
// Queue Mode
// ============================================================================

/// Mode for message queue delivery
pub const QueueMode = enum {
    all,
    one_at_a_time,
};

// ============================================================================
// AgentMessage - Extended Message Type
// ============================================================================

/// Custom message types can be added by apps.
/// This placeholder allows for future extension without breaking changes.
/// Apps that need custom message types can create their own union that
/// includes this AgentMessage as one of its variants.
pub const CustomAgentMessage = union(enum) {
    /// Placeholder for custom message types.
    /// Apps should define their own specific message types.
    custom: struct {
        /// Type identifier for the custom message
        type: []const u8,
        /// JSON-encoded payload
        payload: []const u8,
        /// Timestamp in milliseconds
        timestamp: i64,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.type);
            allocator.free(self.payload);
        }
    },

    pub fn deinit(self: *CustomAgentMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .custom => |*c| c.deinit(allocator),
        }
    }
};

/// AgentMessage is the union of LLM-compatible Message types and custom message types.
/// This separation allows apps to track additional metadata (artifacts, notifications, etc.)
/// that shouldn't be sent to the LLM but should be tracked in the conversation history.
///
/// Use `convertToLlm` in AgentLoopConfig to filter/convert AgentMessages to LLM-compatible
/// Messages before each LLM call.
pub const AgentMessage = union(enum) {
    /// Standard LLM message (user, assistant, or tool_result)
    llm: ai_types.Message,
    /// Custom application-specific message
    custom: CustomAgentMessage,

    /// Create an AgentMessage from a standard LLM Message
    pub fn fromLlm(msg: ai_types.Message) AgentMessage {
        return .{ .llm = msg };
    }

    /// Create an AgentMessage from a user message
    pub fn fromUser(user: ai_types.UserMessage) AgentMessage {
        return .{ .llm = .{ .user = user } };
    }

    /// Create an AgentMessage from an assistant message
    pub fn fromAssistant(assistant: ai_types.AssistantMessage) AgentMessage {
        return .{ .llm = .{ .assistant = assistant } };
    }

    /// Create an AgentMessage from a tool result message
    pub fn fromToolResult(tool_result: ai_types.ToolResultMessage) AgentMessage {
        return .{ .llm = .{ .tool_result = tool_result } };
    }

    /// Check if this is an LLM-compatible message
    pub fn isLlmCompatible(self: AgentMessage) bool {
        return self == .llm;
    }

    /// Get the LLM message if this is an LLM-compatible message
    pub fn getLlm(self: AgentMessage) ?ai_types.Message {
        if (self == .llm) return self.llm;
        return null;
    }

    /// Get timestamp from any message variant
    pub fn getTimestamp(self: AgentMessage) i64 {
        return switch (self) {
            .llm => |msg| switch (msg) {
                .user => |u| u.timestamp,
                .assistant => |a| a.timestamp,
                .tool_result => |t| t.timestamp,
            },
            .custom => |c| c.custom.timestamp,
        };
    }

    /// Free all owned memory
    pub fn deinit(self: *AgentMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .llm => |*msg| msg.deinit(allocator),
            .custom => |*c| c.deinit(allocator),
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AgentEvent tags are correct" {
    const event: AgentEvent = .agent_start;
    try std.testing.expect(std.meta.activeTag(event) == .agent_start);

    const end_event: AgentEvent = .{ .agent_end = .{
        .messages = OwnedSlice(ai_types.Message).initBorrowed(&.{}),
    } };
    try std.testing.expect(std.meta.activeTag(end_event) == .agent_end);
}

test "AgentContext init and deinit" {
    var context = AgentContext.init(std.testing.allocator);
    defer context.deinit();

    try std.testing.expect(context.messages.items.len == 0);
    try std.testing.expect(context.getSystemPrompt() == null);
}

test "AgentContext appendMessage" {
    var context = AgentContext.init(std.testing.allocator);
    defer context.deinit();

    // Create a message with owned strings
    const text = try std.testing.allocator.dupe(u8, "Hello");
    const msg = ai_types.Message{
        .user = .{
            .content = .{ .text = text },
            .timestamp = std.time.milliTimestamp(),
        },
    };
    try context.appendMessage(msg);

    try std.testing.expect(context.messages.items.len == 1);
}

test "AgentState init and deinit" {
    var state = AgentState.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expect(state.messages.items.len == 0);
    try std.testing.expect(!state.is_streaming);
    try std.testing.expect(state.model == null);
}

test "AgentTool.toTool conversion" {
    const tool = AgentTool{
        .label = "Test Tool",
        .name = "test_tool",
        .description = "A test tool",
        .parameters_schema_json = "{}",
        .execute = undefined, // Would be a real function in practice
    };

    const converted = try tool.toTool(std.testing.allocator);
    try std.testing.expectEqualStrings("test_tool", converted.name);
    try std.testing.expectEqualStrings("A test tool", converted.description);
}

test "QueueMode enum values" {
    try std.testing.expectEqual(QueueMode.all, .all);
    try std.testing.expectEqual(QueueMode.one_at_a_time, .one_at_a_time);
}

test "AgentEventStream basic usage" {
    var stream = AgentEventStream.init(std.testing.allocator);
    defer stream.deinit();

    try stream.push(.agent_start);

    const event = stream.poll();
    try std.testing.expect(event != null);
    try std.testing.expect(std.meta.activeTag(event.?) == .agent_start);

    const result = AgentLoopResult{
        .messages = OwnedSlice(ai_types.Message).initBorrowed(&.{}),
        .final_message = .{
            .content = &.{},
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 0,
        },
        .iterations = 0,
    };
    stream.complete(result);

    try std.testing.expect(stream.isDone());
}

test "AgentEndPayload deinit with owned strings" {
    const msg = ai_types.Message{
        .user = .{
            .content = .{ .text = try std.testing.allocator.dupe(u8, "test") },
            .timestamp = 0,
        },
    };
    const msgs = try std.testing.allocator.alloc(ai_types.Message, 1);
    msgs[0] = msg;

    var payload = AgentEndPayload{
        .messages = OwnedSlice(ai_types.Message).initOwned(msgs),
    };

    payload.deinit(std.testing.allocator);
    // Should not leak
}

test "TurnEndPayload with tool results" {
    const payload = TurnEndPayload{
        .message = .{
            .content = &.{},
            .api = "test",
            .provider = "test",
            .model = "test",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 0,
        },
        .tool_results = OwnedSlice(ai_types.ToolResultMessage).initBorrowed(&.{}),
    };

    // Just verify it compiles and has correct fields
    try std.testing.expect(payload.tool_results.slice().len == 0);
}

test "ProtocolClient has stream method" {
    // This is a compile-time check that ProtocolClient has the expected interface
    const client: ProtocolClient = .{
        .stream_fn = undefined,
        .ctx = null,
    };
    try std.testing.expect(client.ctx == null);
}

test "ProtocolOptions defaults" {
    const opts = ProtocolOptions{};
    try std.testing.expect(opts.api_key == null);
    try std.testing.expect(opts.session_id == null);
    try std.testing.expect(opts.cancel_token == null);
    try std.testing.expect(opts.thinking_budgets == null);
    try std.testing.expectEqual(@as(u32, 60_000), opts.max_retry_delay_ms);
    try std.testing.expect(opts.temperature == null);
    try std.testing.expect(opts.max_tokens == null);
}

test "AgentMessage fromLlm" {
    const user_msg = ai_types.UserMessage{
        .content = .{ .text = "Hello" },
        .timestamp = 12345,
    };
    const agent_msg = AgentMessage.fromUser(user_msg);

    try std.testing.expect(agent_msg == .llm);
    try std.testing.expect(agent_msg.isLlmCompatible());
    try std.testing.expectEqual(@as(i64, 12345), agent_msg.getTimestamp());

    const llm = agent_msg.getLlm();
    try std.testing.expect(llm != null);
    try std.testing.expect(llm.? == .user);
}

test "AgentMessage custom message" {
    // Create with owned strings
    const msg_type = try std.testing.allocator.dupe(u8, "notification");
    const payload = try std.testing.allocator.dupe(u8, "{\"text\": \"Test notification\"}");

    var custom = CustomAgentMessage{ .custom = .{
        .type = msg_type,
        .payload = payload,
        .timestamp = 12345,
    } };
    defer custom.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("notification", custom.custom.type);
    try std.testing.expectEqualStrings("{\"text\": \"Test notification\"}", custom.custom.payload);
}

test "AgentMessage fromAssistant" {
    const assistant_msg = ai_types.AssistantMessage{
        .content = &.{.{ .text = .{ .text = "Hello back" } }},
        .api = "test",
        .provider = "test",
        .model = "test",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 12345,
    };
    const agent_msg = AgentMessage.fromAssistant(assistant_msg);

    try std.testing.expect(agent_msg == .llm);
    try std.testing.expect(agent_msg.isLlmCompatible());
    try std.testing.expectEqual(@as(i64, 12345), agent_msg.getTimestamp());
}

test "AgentMessage fromToolResult" {
    const tool_result = ai_types.ToolResultMessage{
        .tool_call_id = "call-123",
        .tool_name = "test_tool",
        .content = &.{.{ .text = .{ .text = "result" } }},
        .is_error = false,
        .timestamp = 12345,
    };
    const agent_msg = AgentMessage.fromToolResult(tool_result);

    try std.testing.expect(agent_msg == .llm);
    try std.testing.expect(agent_msg.isLlmCompatible());
    try std.testing.expectEqual(@as(i64, 12345), agent_msg.getTimestamp());
}
