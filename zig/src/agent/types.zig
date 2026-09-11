const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");
const owned_slice_mod = @import("owned_slice");
pub const permission = @import("permission");

pub const OwnedSlice = owned_slice_mod.OwnedSlice;
pub const ArtifactReference = ai_types.ArtifactReference;

pub const AgentTermination = enum {
    max_turns,
    cancelled,
};

pub const AgentEndPayload = struct {
    messages: OwnedSlice(ai_types.Message) = OwnedSlice(ai_types.Message).initBorrowed(&.{}),
    termination: ?AgentTermination = null,
    final_message: ?ai_types.AssistantMessage = null,

    pub fn deinit(self: *AgentEndPayload, allocator: std.mem.Allocator) void {
        self.messages.deinit(allocator);
    }
};

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

pub const MessageStartPayload = struct {
    message: ai_types.Message,
};

pub const MessageUpdatePayload = struct {
    message: ai_types.AssistantMessage,
    event: ai_types.AssistantMessageEvent,
    owns_event: bool = false,

    pub fn deinit(self: *MessageUpdatePayload, allocator: std.mem.Allocator) void {
        if (self.owns_event) {
            ai_types.deinitAssistantMessageEvent(allocator, &self.event);
            self.owns_event = false;
        }
    }
};

pub const MessageEndPayload = struct {
    message: ai_types.Message,
};

pub const ContextUsagePayload = struct {
    system_prompt_bytes: u64 = 0,
    message_bytes: u64 = 0,
    tool_definition_bytes: u64 = 0,
    total_bytes: u64 = 0,
    estimated_tokens: u64 = 0,
    message_count: u32 = 0,
    tool_count: u32 = 0,
};

pub const PromptSegmentKind = enum {
    system_prompt,
    message_history,
    tool_definitions,
};

pub const PromptSegmentCacheRole = enum {
    stable,
    dynamic,
};

pub const PromptSegmentUsagePayload = struct {
    segment: PromptSegmentKind,
    cache_role: PromptSegmentCacheRole,
    bytes: u64 = 0,
    estimated_tokens: u64 = 0,
    item_count: u32 = 0,
};

pub const ToolExecutionStartPayload = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
};

pub const ToolExecutionUpdatePayload = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
    partial_result_json: []const u8,
};

pub const ToolExecutionEndPayload = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    result_json: []const u8,
    content_json: []const u8 = "",
    is_error: bool,
    args_bytes: u64 = 0,
    raw_result_bytes: u64 = 0,
    returned_result_bytes: u64 = 0,
    raw_details_bytes: u64 = 0,
    returned_details_bytes: u64 = 0,
    raw_total_bytes: u64 = 0,
    returned_total_bytes: u64 = 0,
    estimated_returned_tokens: u64 = 0,
    artifact_count: u32 = 0,
    artifacts: []const ArtifactReference = &.{},
};

pub const AgentEvent = union(enum) {
    agent_start: void,
    agent_end: AgentEndPayload,

    turn_start: void,
    turn_end: TurnEndPayload,

    message_start: MessageStartPayload,
    message_update: MessageUpdatePayload,
    message_end: MessageEndPayload,
    context_usage: ContextUsagePayload,
    prompt_segment_usage: PromptSegmentUsagePayload,

    tool_execution_start: ToolExecutionStartPayload,
    tool_execution_update: ToolExecutionUpdatePayload,
    tool_execution_end: ToolExecutionEndPayload,

    pub fn deinit(self: *AgentEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .message_update => |*payload| payload.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

pub const AgentToolResult = struct {
    content: OwnedSlice(ai_types.UserContentPart) = OwnedSlice(ai_types.UserContentPart).initBorrowed(&.{}),
    details_json: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    artifacts: OwnedSlice(ArtifactReference) = OwnedSlice(ArtifactReference).initBorrowed(&.{}),
    is_error: bool = false,

    pub fn getDetailsJson(self: *const AgentToolResult) ?[]const u8 {
        const details = self.details_json.slice();
        return if (details.len > 0) details else null;
    }

    pub fn deinit(self: *AgentToolResult, allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
        self.details_json.deinit(allocator);
        self.artifacts.deinit(allocator);
    }
};

pub const ToolUpdateCallback = *const fn (
    ctx: ?*anyopaque,
    tool_call_id: []const u8,
    tool_name: []const u8,
    partial_result_json: []const u8,
) void;

pub const ToolExecuteFn = *const fn (
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!AgentToolResult;

pub const ToolRuntimeExecuteFn = *const fn (
    ctx: ?*anyopaque,
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!AgentToolResult;

pub const ToolProtocolExecuteFn = *const fn (
    ctx: ?*anyopaque,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!AgentToolResult;

fn defaultToolProtocolExecute(
    ctx: ?*anyopaque,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!AgentToolResult {
    _ = ctx;
    _ = tool_call_id;
    _ = tool_name;
    _ = args_json;
    _ = cancel_token;
    _ = on_update_ctx;
    _ = on_update;
    _ = allocator;
    return error.ToolProtocolNotConfigured;
}

pub const ToolOutputMiddlewareInput = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
    is_error: bool,
    raw_result_bytes: u64,
    raw_details_bytes: u64,
    raw_total_bytes: u64,
};

pub const ToolOutputMiddlewareFn = *const fn (
    ctx: ?*anyopaque,
    input: ToolOutputMiddlewareInput,
    result: *AgentToolResult,
    allocator: std.mem.Allocator,
) anyerror!void;

pub const ToolApprovalDecision = permission.ApprovalDecision;

pub const ToolApprovalRequest = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
};

pub const ToolApprovalUiFn = *const fn (
    ctx: ?*anyopaque,
    request: ToolApprovalRequest,
    allocator: std.mem.Allocator,
) void;

pub const ToolApprovalDecisionFn = *const fn (
    ctx: ?*anyopaque,
    request: ToolApprovalRequest,
) ToolApprovalDecision;

pub const ToolApprovalFn = ToolApprovalDecisionFn;

pub const AgentTool = struct {
    label: []const u8,
    name: []const u8,
    description: []const u8,
    short_description: ?[]const u8 = null,
    parameters_schema_json: []const u8,
    execute: ToolExecuteFn,
    runtime_ctx: ?*anyopaque = null,
    runtime_execute: ?ToolRuntimeExecuteFn = null,
    approval_ctx: ?*anyopaque = null,
    approval_fn: ?ToolApprovalFn = null,
    approval_ui_ctx: ?*anyopaque = null,
    approval_ui_fn: ?ToolApprovalUiFn = null,

    pub fn toTool(self: AgentTool, allocator: std.mem.Allocator) !ai_types.Tool {
        _ = allocator;
        return .{
            .name = self.name,
            .description = self.short_description orelse self.description,
            .parameters_schema_json = self.parameters_schema_json,
        };
    }
};

pub const ProtocolOptions = struct {
    api_key: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    cancel_token: ?ai_types.CancelToken = null,
    thinking_level: ai_types.ThinkingLevel = .minimal,
    thinking_budgets: ?ai_types.ThinkingBudgets = null,
    max_retry_delay_ms: u32 = 60_000,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
};

pub const ProtocolStreamFn = *const fn (
    ctx: ?*anyopaque,
    model: ai_types.Model,
    context: ai_types.Context,
    options: ProtocolOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageEventStream;

pub const ProtocolClient = struct {
    stream_fn: ProtocolStreamFn,

    ctx: ?*anyopaque = null,

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

pub const AgentStreamFn = *const fn (
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageEventStream;

pub const TransformContextFn = *const fn (
    ctx: ?*anyopaque,
    messages: []const ai_types.Message,
    allocator: std.mem.Allocator,
) anyerror![]const ai_types.Message;

pub const GetSteeringMessagesFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
) anyerror!?[]const ai_types.Message;

pub const GetFollowUpMessagesFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
) anyerror!?[]const ai_types.Message;

pub const ConvertToLlmFn = *const fn (
    ctx: ?*anyopaque,
    messages: []const ai_types.Message,
    allocator: std.mem.Allocator,
) anyerror![]const ai_types.Message;

pub const GetApiKeyFn = *const fn (
    ctx: ?*anyopaque,
    provider: []const u8,
) ?[]const u8;

pub const AgentLoopConfig = struct {
    model: ai_types.Model,

    protocol: ProtocolClient,

    tools: ?[]const AgentTool = null,
    execute_tool_via_protocol_fn: ToolProtocolExecuteFn = defaultToolProtocolExecute,
    execute_tool_via_protocol_ctx: ?*anyopaque = null,
    tool_output_middleware_fn: ?ToolOutputMiddlewareFn = null,
    tool_output_middleware_ctx: ?*anyopaque = null,
    permission_engine: ?*permission.PermissionEngine = null,
    compact_tool_output: bool = false,

    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    api_key: ?[]const u8 = null,
    cancel_token: ?ai_types.CancelToken = null,
    thinking_level: ai_types.ThinkingLevel = .minimal,

    max_iterations: ?u32 = null,
    session_id: ?[]const u8 = null,
    thinking_budgets: ?ai_types.ThinkingBudgets = null,
    max_retry_delay_ms: ?u32 = 60_000,

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

pub const AgentContext = struct {
    system_prompt: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    messages: std.ArrayList(ai_types.Message),
    tools: ?[]const AgentTool = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AgentContext {
        return .{
            .messages = std.ArrayList(ai_types.Message).empty,
            .allocator = allocator,
        };
    }

    pub fn getSystemPrompt(self: *const AgentContext) ?[]const u8 {
        const prompt = self.system_prompt.slice();
        return if (prompt.len > 0) prompt else null;
    }

    pub fn deinit(self: *AgentContext) void {
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
            .messages = std.ArrayList(ai_types.Message).empty,
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
        self.clearStreamMessage();
        if (self.system_prompt.len > 0) self.allocator.free(self.system_prompt);
        self.error_message.deinit(self.allocator);
        self.pending_tool_calls.deinit();
    }

    pub fn clearStreamMessage(self: *AgentState) void {
        if (self.stream_message) |*msg| {
            msg.deinit(self.allocator);
        }
        self.stream_message = null;
    }
};

pub const AgentLoopResult = struct {
    messages: OwnedSlice(ai_types.Message),
    final_message: ai_types.AssistantMessage,
    iterations: u32,
    termination: ?AgentTermination = null,

    pub fn deinit(self: *AgentLoopResult, allocator: std.mem.Allocator) void {
        self.messages.deinit(allocator);
        var final = self.final_message;
        final.deinit(allocator);
    }
};

pub const AgentEventStream = event_stream.EventStream(AgentEvent, AgentLoopResult);

pub const QueueMode = enum {
    all,
    one_at_a_time,
};

pub const CustomAgentMessage = union(enum) {
    custom: struct {
        type: []const u8,
        payload: []const u8,
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

pub const AgentMessage = union(enum) {
    llm: ai_types.Message,
    custom: CustomAgentMessage,

    pub fn fromLlm(msg: ai_types.Message) AgentMessage {
        return .{ .llm = msg };
    }

    pub fn fromUser(user: ai_types.UserMessage) AgentMessage {
        return .{ .llm = .{ .user = user } };
    }

    pub fn fromAssistant(assistant: ai_types.AssistantMessage) AgentMessage {
        return .{ .llm = .{ .assistant = assistant } };
    }

    pub fn fromToolResult(tool_result: ai_types.ToolResultMessage) AgentMessage {
        return .{ .llm = .{ .tool_result = tool_result } };
    }

    pub fn isLlmCompatible(self: AgentMessage) bool {
        return self == .llm;
    }

    pub fn getLlm(self: AgentMessage) ?ai_types.Message {
        if (self == .llm) return self.llm;
        return null;
    }

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

    pub fn deinit(self: *AgentMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .llm => |*msg| msg.deinit(allocator),
            .custom => |*c| c.deinit(allocator),
        }
    }
};

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

    const text = try std.testing.allocator.dupe(u8, "Hello");
    const msg = ai_types.Message{
        .user = .{
            .content = .{ .text = text },
            .timestamp = compat.time.nowMillis(),
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
        .short_description = "Test compact",
        .parameters_schema_json = "{}",
        .execute = undefined,
    };

    const converted = try tool.toTool(std.testing.allocator);
    try std.testing.expectEqualStrings("test_tool", converted.name);
    try std.testing.expectEqualStrings("Test compact", converted.description);
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

test "AgentEvent deinit releases owned message update provider event" {
    const allocator = std.testing.allocator;

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .tool_use,
        .timestamp = 0,
    };
    const borrowed = ai_types.AssistantMessageEvent{ .toolcall_start = .{
        .content_index = 0,
        .id = "call-1",
        .name = "shell_execute",
        .partial = partial,
    } };
    const owned = try ai_types.cloneAssistantMessageEvent(allocator, borrowed);

    var event = AgentEvent{ .message_update = .{
        .message = owned.toolcall_start.partial,
        .event = owned,
        .owns_event = true,
    } };
    event.deinit(allocator);
}

test "AgentEventStream deinit drains owned message update events" {
    const allocator = std.testing.allocator;

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const borrowed = ai_types.AssistantMessageEvent{ .text_delta = .{
        .content_index = 0,
        .delta = "hello",
        .partial = partial,
    } };
    const owned = try ai_types.cloneAssistantMessageEvent(allocator, borrowed);

    var stream = AgentEventStream.init(allocator);
    defer stream.deinit();
    try stream.push(.{ .message_update = .{
        .message = owned.text_delta.partial,
        .event = owned,
        .owns_event = true,
    } });
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

    try std.testing.expect(payload.tool_results.slice().len == 0);
}

test "ProtocolClient has stream method" {
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
    try std.testing.expectEqual(ai_types.ThinkingLevel.minimal, opts.thinking_level);
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
