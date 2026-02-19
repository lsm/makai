# Agent Loop Design Plan

## Overview

This document describes the design for implementing an agent loop in the Makai Zig codebase, mirroring the pi-mono TypeScript implementation. The agent package provides:

1. **Low-level API**: `agentLoop()` / `agentLoopContinue()` functions - stateless generator functions
2. **High-level API**: `Agent` class - stateful, manages subscriptions, queues messages

## Goals

1. **Flexible Provider Access**: Support both direct provider access (via `ApiRegistry`) and protocol client access (via custom stream function)
2. **Event-Driven Architecture**: Emit granular events for UI updates via `AgentEventStream`
3. **Tool Execution**: Execute tools sequentially with streaming update support
4. **Multi-Turn Support**: Automatically continue conversation when tools are called
5. **Steering/Follow-up**: Support mid-run interruption and post-completion follow-up messages
6. **State Management**: Track streaming state, pending tool calls, and current partial message

## Architecture

### Module Structure

```
zig/src/agent/
├── types.zig        # AgentEvent, AgentTool, AgentLoopConfig, AgentState, AgentContext
├── agent_loop.zig   # Low-level: agentLoop() and agentLoopContinue() functions
├── agent.zig        # High-level: Agent class with state and message queues
└── mod.zig          # Public exports
```

### Dependency Graph

```
types.zig
  ├── agent_loop.zig
  │     └── agent.zig
  └── (uses ai_types, event_stream, api_registry)
```

---

## Type Definitions (types.zig)

### AgentEvent

```zig
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

pub const AgentEndPayload = struct {
    messages: []const ai_types.Message,
    owned_strings: bool = false,

    pub fn deinit(self: *AgentEndPayload, allocator: std.mem.Allocator) void;
};

pub const TurnEndPayload = struct {
    message: ai_types.AssistantMessage,
    tool_results: []const ai_types.ToolResultMessage,
    owned_strings: bool = false,

    pub fn deinit(self: *TurnEndPayload, allocator: std.mem.Allocator) void;
};

pub const MessageStartPayload = struct {
    message: ai_types.Message,
    owned_strings: bool = false,
};

pub const MessageUpdatePayload = struct {
    message: ai_types.AssistantMessage,
    event: ai_types.AssistantMessageEvent,
};

pub const MessageEndPayload = struct {
    message: ai_types.Message,
    owned_strings: bool = false,
};

pub const ToolExecutionStartPayload = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
};

pub const ToolExecutionUpdatePayload = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    partial_result_json: []const u8,
};

pub const ToolExecutionEndPayload = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    result_json: []const u8,
    is_error: bool,
};
```

### AgentTool

```zig
/// Tool result returned from execute
pub const AgentToolResult = struct {
    content: []const ai_types.UserContentPart,
    details_json: ?[]const u8 = null,
    owned_strings: bool = false,

    pub fn deinit(self: *AgentToolResult, allocator: std.mem.Allocator) void {
        if (!self.owned_strings) return;
        const mut_content: []ai_types.UserContentPart = @constCast(self.content);
        for (mut_content) |*part| part.deinit(allocator);
        allocator.free(self.content);
        if (self.details_json) |dj| allocator.free(dj);
    }
};

/// Callback for streaming tool execution updates
pub const ToolUpdateCallback = *const fn (
    ctx: ?*anyopaque,
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
```

### AgentStreamFn

```zig
/// Custom stream function for provider access.
/// If provided, used directly. Otherwise, falls back to registry lookup.
/// This allows both in-process (via registry) and remote (via protocol client) access.
pub const AgentStreamFn = *const fn (
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageEventStream;
```

### AgentLoopConfig

```zig
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

pub const AgentLoopConfig = struct {
    // Required
    model: ai_types.Model,

    // Provider access (one of these is required):
    // Option 1: Custom stream function (e.g., protocol client, mock, etc.)
    stream_fn: ?AgentStreamFn = null,
    // Option 2: Registry for direct provider access (in-process)
    registry: ?*api_registry.ApiRegistry = null,

    // Tools (optional)
    tools: ?[]const AgentTool = null,

    // Streaming options (passed through to provider)
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
```

### AgentContext

```zig
pub const AgentContext = struct {
    system_prompt: ?[]const u8 = null,
    messages: std.ArrayList(ai_types.Message),
    tools: ?[]const AgentTool = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AgentContext {
        return .{
            .messages = std.ArrayList(ai_types.Message).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AgentContext) void {
        // Free messages if owned
        for (self.messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.messages.deinit();
        if (self.system_prompt) |p| self.allocator.free(p);
    }

    pub fn appendMessage(self: *AgentContext, msg: ai_types.Message) !void {
        try self.messages.append(msg);
    }

    pub fn messagesSlice(self: AgentContext) []const ai_types.Message {
        return self.messages.items;
    }
};
```

### AgentState

```zig
pub const AgentState = struct {
    system_prompt: []const u8 = "",
    model: ?ai_types.Model = null,
    thinking_level: ai_types.ThinkingLevel = .minimal,
    tools: []const AgentTool = &.{},
    messages: std.ArrayList(ai_types.Message),
    is_streaming: bool = false,
    stream_message: ?ai_types.Message = null,
    pending_tool_calls: std.StringHashMap(void),
    error_message: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AgentState {
        return .{
            .messages = std.ArrayList(ai_types.Message).init(allocator),
            .pending_tool_calls = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AgentState) void {
        for (self.messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.messages.deinit();
        if (self.system_prompt.len > 0) self.allocator.free(self.system_prompt);
        if (self.error_message) |e| self.allocator.free(e);
        // Note: doesn't own model or tools
    }
};
```

### AgentEventStream

```zig
pub const AgentEventStream = event_stream.EventStream(AgentEvent, AgentLoopResult);

pub const AgentLoopResult = struct {
    messages: []const ai_types.Message,
    final_message: ai_types.AssistantMessage,
    iterations: u32,
    owned_strings: bool = false,

    pub fn deinit(self: *AgentLoopResult, allocator: std.mem.Allocator) void {
        if (!self.owned_strings) return;
        const mut_msgs: []ai_types.Message = @constCast(self.messages);
        for (mut_msgs) |*msg| msg.deinit(allocator);
        allocator.free(self.messages);
        var final = self.final_message;
        final.deinit(allocator);
    }
};
```

### QueueMode

```zig
pub const QueueMode = enum {
    all,
    one_at_a_time,
};
```

---

## Low-Level API (agent_loop.zig)

### agentLoop

```zig
/// Start an agent loop with new prompt messages.
/// Returns an event stream that emits events during execution.
/// Caller owns the returned stream and must call deinit().
pub fn agentLoop(
    allocator: std.mem.Allocator,
    prompts: []const ai_types.Message,
    context: AgentContext,
    config: AgentLoopConfig,
) !*AgentEventStream;
```

### agentLoopContinue

```zig
/// Continue an agent loop from the current context without adding new messages.
/// Used for retries - context already has user message or tool results.
pub fn agentLoopContinue(
    allocator: std.mem.Allocator,
    context: AgentContext,
    config: AgentLoopConfig,
) !*AgentEventStream;
```

### Loop Algorithm

```
1. Emit agent_start
2. Outer loop (handles follow-up messages):
   a. Inner loop (process tool calls and steering):
      i. If pending messages (steering):
         - Emit message_start/message_end for each
         - Add to context
      ii. Stream assistant response:
          - Call provider via registry
          - Forward AssistantMessageEvents as message_update events
          - Emit message_start on first event, message_end on done
      iii. Check stop_reason:
           - error/aborted: exit both loops
           - tool_use: execute tools
           - stop: continue to outer loop
      iv. If tool calls:
          - For each tool call (sequential):
            a. Emit tool_execution_start
            b. Execute tool
            c. Emit tool_execution_update during execution (if streaming)
            d. Emit tool_execution_end
            e. Check steering messages - if any, skip remaining tools
          - Create ToolResultMessage for each result
          - Emit message_start/message_end for each tool result
          - Add to context
      v. Check steering messages after turn
          - If any, set as pending for next iteration
   b. End inner loop when no tool calls and no steering messages
   c. Check follow-up messages:
      - If any, set as pending and continue outer loop
      - Otherwise, exit outer loop
3. Emit agent_end with all new messages
4. Complete the stream
```

---

## High-Level API (agent.zig)

### AgentOptions

```zig
pub const AgentOptions = struct {
    // Initial state
    initial_state: ?AgentState = null,

    // Provider access (one of these is required):
    // Option 1: Registry for direct provider access
    registry: ?*api_registry.ApiRegistry = null,
    // Option 2: Custom stream function (e.g., protocol client)
    stream_fn: ?AgentStreamFn = null,

    // Message transformation
    convert_to_llm_fn: ?ConvertToLlmFn = null,
    convert_to_llm_ctx: ?*anyopaque = null,
    transform_context_fn: ?TransformContextFn = null,
    transform_context_ctx: ?*anyopaque = null,

    // Queue modes
    steering_mode: QueueMode = .one_at_a_time,
    follow_up_mode: QueueMode = .one_at_a_time,

    // Provider options
    session_id: ?[]const u8 = null,
    get_api_key_fn: ?GetApiKeyFn = null,
    get_api_key_ctx: ?*anyopaque = null,
    thinking_budgets: ?ai_types.ThinkingBudgets = null,
    max_retry_delay_ms: ?u32 = 60_000,
};
```

### Agent Class

```zig
pub const Agent = struct {
    // Internal state
    _state: AgentState,
    _allocator: std.mem.Allocator,

    // Provider access (one of these)
    _registry: ?*api_registry.ApiRegistry,
    _stream_fn: ?AgentStreamFn,

    // Subscribers
    _listeners: std.ArrayList(*const fn (event: AgentEvent) void),

    // Control
    _cancel_token: ?ai_types.CancelToken = null,
    _running_promise: ?Promise(void) = null,

    // Message queues
    _steering_queue: std.ArrayList(ai_types.Message),
    _follow_up_queue: std.ArrayList(ai_types.Message),
    _steering_mode: QueueMode,
    _follow_up_mode: QueueMode,

    // Configuration
    _convert_to_llm_fn: ?ConvertToLlmFn,
    _convert_to_llm_ctx: ?*anyopaque,
    _transform_context_fn: ?TransformContextFn,
    _transform_context_ctx: ?*anyopaque,
    _session_id: ?[]const u8,
    _get_api_key_fn: ?GetApiKeyFn,
    _get_api_key_ctx: ?*anyopaque,
    _thinking_budgets: ?ai_types.ThinkingBudgets,
    _max_retry_delay_ms: ?u32,

    // === Lifecycle ===

    pub fn init(allocator: std.mem.Allocator, options: AgentOptions) Agent;
    pub fn deinit(self: *Agent) void;

    // === Subscribe ===

    pub fn subscribe(self: *Agent, callback: *const fn (event: AgentEvent) void) void;
    pub fn unsubscribe(self: *Agent, callback: *const fn (event: AgentEvent) void) void;

    // === State Accessors ===

    pub fn state(self: Agent) AgentState;

    // === State Mutators ===

    pub fn setSystemPrompt(self: *Agent, prompt: []const u8) !void;
    pub fn setModel(self: *Agent, model: ai_types.Model) void;
    pub fn setThinkingLevel(self: *Agent, level: ai_types.ThinkingLevel) void;
    pub fn setTools(self: *Agent, tools: []const AgentTool) void;
    pub fn setSteeringMode(self: *Agent, mode: QueueMode) void;
    pub fn setFollowUpMode(self: *Agent, mode: QueueMode) void;

    pub fn replaceMessages(self: *Agent, messages: []const ai_types.Message) !void;
    pub fn appendMessage(self: *Agent, message: ai_types.Message) !void;
    pub fn clearMessages(self: *Agent) void;

    // === Message Queues ===

    /// Queue a steering message to interrupt the agent mid-run.
    /// Delivered after current tool execution, skips remaining tools.
    pub fn steer(self: *Agent, message: ai_types.Message) !void;

    /// Queue a follow-up message to be processed after the agent finishes.
    /// Delivered only when agent has no more tool calls or steering messages.
    pub fn followUp(self: *Agent, message: ai_types.Message) !void;

    pub fn clearSteeringQueue(self: *Agent) void;
    pub fn clearFollowUpQueue(self: *Agent) void;
    pub fn clearAllQueues(self: *Agent) void;
    pub fn hasQueuedMessages(self: Agent) bool;

    // === Control Flow ===

    /// Send a prompt to start a new conversation turn.
    /// Throws error if already streaming.
    pub fn prompt(self: *Agent, message: ai_types.Message) anyerror!void;

    /// Continue from current context (for retries and queued messages).
    pub fn continueFromContext(self: *Agent) anyerror!void;

    /// Abort the current operation.
    pub fn abort(self: *Agent) void;

    /// Reset all state (clear messages, queues, error).
    pub fn reset(self: *Agent) void;

    // === Internal ===

    fn runLoop(self: *Agent, messages: ?[]const ai_types.Message) !void;
    fn emit(self: *Agent, event: AgentEvent) void;
    fn dequeueSteeringMessages(self: *Agent) ?[]const ai_types.Message;
    fn dequeueFollowUpMessages(self: *Agent) ?[]const ai_types.Message;
    fn getStreamFn(self: Agent) ?AgentStreamFn;
};
```

---

## Provider Access

The agent supports two modes of provider access:

### Option 1: Direct Provider Access (via ApiRegistry)

For in-process use where providers are registered locally:

```zig
const config = agent.AgentLoopConfig{
    .model = my_model,
    .registry = &registry,  // Direct provider access
    .api_key = "sk-...",
};
```

### Option 2: Custom Stream Function (via Protocol Client)

For remote access or custom implementations:

```zig
// Custom stream function wrapping a protocol client
fn streamViaProtocol(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageEventStream {
    // Use protocol client to communicate with remote server
    const client = protocol.Client.init(...);
    return client.streamRequest(model, context, options, allocator);
}

const config = agent.AgentLoopConfig{
    .model = my_model,
    .stream_fn = streamViaProtocol,  // Custom stream function
};
```

### Resolution Logic

```zig
fn getStreamFn(config: AgentLoopConfig) anyerror!AgentStreamFn {
    // Explicit stream_fn takes precedence
    if (config.stream_fn) |fn| return fn;

    // Fall back to registry lookup
    if (config.registry) |registry| {
        const provider = registry.getApiProvider(config.model.api)
            orelse return error.ProviderNotFound;
        return provider.stream_simple;
    }

    return error.NoStreamFunction;
}
```

### Full Example

```zig
fn streamAssistantResponse(
    allocator: std.mem.Allocator,
    context: *AgentContext,
    config: AgentLoopConfig,
    event_stream: *AgentEventStream,
) !ai_types.AssistantMessage {
    // Resolve stream function (custom or from registry)
    const stream_fn = try getStreamFn(config);

    // Build tools array for LLM
    var tools: ?[]ai_types.Tool = null;
    defer if (tools) |t| allocator.free(t);
    if (context.tools) |agent_tools| {
        tools = try allocator.alloc(ai_types.Tool, agent_tools.len);
        for (agent_tools, 0..) |tool, i| {
            tools.?[i] = tool.toTool(allocator);
        }
    }

    // Build LLM context
    const llm_context = ai_types.Context{
        .system_prompt = context.system_prompt,
        .messages = context.messagesSlice(),
        .tools = tools,
    };

    // Build stream options
    const options = ai_types.SimpleStreamOptions{
        .temperature = config.temperature,
        .max_tokens = config.max_tokens,
        .api_key = config.api_key,
        .cancel_token = config.cancel_token,
        .session_id = config.session_id,
        .thinking_budgets = config.thinking_budgets,
        .retry = .{ .max_retry_delay_ms = config.max_retry_delay_ms },
    };

    // Call stream function (either direct provider or custom)
    const provider_stream = try stream_fn(
        config.model,
        llm_context,
        options,
        allocator,
    );
    defer provider_stream.deinit();

    // Forward events and collect final message
    // ... (poll loop forwarding events)
}
```

---

## Tool Execution

```zig
fn executeToolCalls(
    allocator: std.mem.Allocator,
    tools: ?[]const AgentTool,
    assistant_message: ai_types.AssistantMessage,
    config: AgentLoopConfig,
    event_stream: *AgentEventStream,
) !ToolExecutionResult {

    // Extract tool calls from assistant message
    var tool_calls = std.ArrayList(ai_types.ToolCall).init(allocator);
    defer tool_calls.deinit();
    for (assistant_message.content) |block| {
        if (block == .tool_call) {
            try tool_calls.append(block.tool_call);
        }
    }

    var results = std.ArrayList(ai_types.ToolResultMessage).init(allocator);
    var steering_messages: ?[]ai_types.Message = null;

    for (tool_calls.items) |tool_call| {
        // Find tool
        const tool = findTool(tools, tool_call.name);

        // Emit start event
        try event_stream.push(.{ .tool_execution_start = .{
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .args_json = tool_call.arguments_json,
        } });

        var result: AgentToolResult = undefined;
        var is_error = false;

        if (tool) |t| {
            result = t.execute(
                tool_call.id,
                tool_call.arguments_json,
                config.cancel_token,
                event_stream, // on_update_ctx
                onToolUpdate, // callback
                allocator,
            ) catch |err| {
                result = createErrorResult(allocator, err);
                is_error = true;
            };
        } else {
            result = createErrorResult(allocator, error.ToolNotFound);
            is_error = true;
        }

        // Emit end event
        try event_stream.push(.{ .tool_execution_end = .{
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .result_json = result.details_json orelse "null",
            .is_error = is_error,
        } });

        // Create tool result message
        try results.append(createToolResultMessage(allocator, tool_call, result, is_error));

        // Check for steering messages - skip remaining tools if any
        if (config.get_steering_messages_fn) |get_steering| {
            steering_messages = try get_steering(config.get_steering_messages_ctx, allocator);
            if (steering_messages != null and steering_messages.?.len > 0) {
                // Skip remaining tools
                // TODO: mark remaining as skipped
                break;
            }
        }
    }

    return .{
        .tool_results = try results.toOwnedSlice(),
        .steering_messages = steering_messages,
    };
}

fn onToolUpdate(ctx: ?*anyopaque, partial_result_json: []const u8) void {
    const event_stream: *AgentEventStream = @ptrCast(@alignCast(ctx));
    event_stream.push(.{ .tool_execution_update = .{
        .partial_result_json = partial_result_json,
    }}) catch {};
}
```

---

## Example Usage

### Low-Level API - Direct Provider Access

```zig
const std = @import("std");
const agent = @import("agent");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize registry
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try @import("register_builtins").registerBuiltins(&registry);

    // Create context
    var context = agent.AgentContext.init(allocator);
    defer context.deinit();
    context.system_prompt = try allocator.dupe(u8, "You are a helpful assistant.");

    // Configure loop with registry (direct provider access)
    const config = agent.AgentLoopConfig{
        .model = .{
            .id = "claude-sonnet-4-20250514",
            .api = "anthropic-messages",
            // ... other fields
        },
        .registry = &registry,
        .api_key = std.os.getenv("ANTHROPIC_API_KEY"),
    };

    // Create prompt
    const user_msg = ai_types.Message{
        .user = .{
            .content = .{ .text = "Hello!" },
            .timestamp = std.time.milliTimestamp(),
        },
    };

    // Run loop
    var event_stream = try agent.agentLoop(allocator, &.{user_msg}, context, config);
    defer event_stream.deinit();

    // Process events
    while (event_stream.poll()) |event| {
        switch (event) {
            .message_end => |e| {
                if (e.message == .assistant) {
                    std.debug.print("Assistant: {s}\n", .{e.message.assistant.content[0].text.text});
                }
            },
            .agent_end => {
                std.debug.print("Done!\n", .{});
            },
            else => {},
        }
    }
}
```

### Low-Level API - Protocol Client Access

```zig
const std = @import("std");
const agent = @import("agent");
const ai_types = @import("ai_types");
const protocol = @import("protocol");
const event_stream = @import("event_stream");

// Custom stream function using protocol client
fn myStreamFn(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageEventStream {
    var client = try protocol.Client.init(allocator, "ws://localhost:8080");
    return client.streamRequest(model, context, options);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var context = agent.AgentContext.init(allocator);
    defer context.deinit();
    context.system_prompt = try allocator.dupe(u8, "You are a helpful assistant.");

    // Configure loop with custom stream function (no registry needed)
    const config = agent.AgentLoopConfig{
        .model = .{
            .id = "claude-sonnet-4-20250514",
            .api = "anthropic-messages",
            // ... other fields
        },
        .stream_fn = myStreamFn,  // Custom stream function
    };

    // ... rest is the same
}
```

### High-Level API (Agent Class) - Direct Provider Access

```zig
const std = @import("std");
const agent = @import("agent");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");

fn onAgentEvent(event: agent.AgentEvent) void {
    switch (event) {
        .tool_execution_start => |e| {
            std.debug.print("Tool started: {s}\n", .{e.tool_name});
        },
        .tool_execution_end => |e| {
            std.debug.print("Tool finished: {s} (error: {})\n", .{ e.tool_name, e.is_error });
        },
        .message_end => |e| {
            if (e.message == .assistant) {
                std.debug.print("Assistant: ...\n", .{});
            }
        },
        else => {},
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize registry with built-in providers
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try @import("register_builtins").registerBuiltins(&registry);

    // Create agent with direct provider access
    var ag = agent.Agent.init(allocator, .{
        .registry = &registry,  // Direct provider access
    });
    defer ag.deinit();

    // Configure
    try ag.setSystemPrompt("You are a helpful assistant.");
    ag.setModel(.{
        .id = "claude-sonnet-4-20250514",
        .api = "anthropic-messages",
        // ...
    });

    // Subscribe to events
    ag.subscribe(onAgentEvent);

    // Send prompt
    const user_msg = ai_types.Message{
        .user = .{
            .content = .{ .text = "Hello!" },
            .timestamp = std.time.milliTimestamp(),
        },
    };
    try ag.prompt(user_msg);
}
```

### High-Level API (Agent Class) - Protocol Client Access

```zig
const std = @import("std");
const agent = @import("agent");
const ai_types = @import("ai_types");
const protocol = @import("protocol");
const event_stream = @import("event_stream");

// Custom stream function that uses protocol client
fn streamViaProtocol(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageEventStream {
    var client = try protocol.Client.init(allocator, "ws://localhost:8080");
    return client.streamRequest(model, context, options);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create agent with custom stream function (no registry needed)
    var ag = agent.Agent.init(allocator, .{
        .stream_fn = streamViaProtocol,  // Custom stream function
    });
    defer ag.deinit();

    // Configure and use...
    try ag.setSystemPrompt("You are a helpful assistant.");
    ag.setModel(.{
        .id = "claude-sonnet-4-20250514",
        .api = "anthropic-messages",
        // ...
    });

    // ...
}
```

---

## Implementation Order

1. **types.zig** - All type definitions
   - AgentEvent variants and payloads
   - AgentTool, AgentToolResult
   - AgentLoopConfig, AgentContext, AgentState
   - QueueMode

2. **agent_loop.zig** - Core loop implementation
   - `agentLoop()` entry point
   - `agentLoopContinue()` entry point
   - `runLoop()` inner/outer loop logic
   - `streamAssistantResponse()` - provider integration
   - `executeToolCalls()` - tool execution

3. **agent.zig** - High-level Agent class
   - State management
   - Message queues (steering/follow-up)
   - Subscribe/unsubscribe
   - Control flow (prompt, continue, abort, reset)

4. **mod.zig** - Public exports

5. **Tests** - Unit tests for each component

---

## Differences from pi-mono

| Aspect | pi-mono (TypeScript) | Makai (Zig) |
|--------|---------------------|-------------|
| Memory | GC | Manual with deinit |
| Async | Promise/async-await | Polling-based (can add fiber later) |
| Error handling | Exceptions | Error unions |
| Subscribers | Set<fn> | ArrayList(*const fn) |
| Message queues | Array push/slice | ArrayList |
| Proxy | Built-in | Not needed (provider layer handles) |

---

## Notes

- **Flexible Provider Access**: Agent supports both direct provider access (via `registry`) and custom stream functions (e.g., protocol client). If `stream_fn` is provided, it takes precedence; otherwise falls back to registry lookup.
- **Proxy streaming is NOT implemented** since the provider layer already handles different transport mechanisms
- **TypeScript's declaration merging for AgentMessage** doesn't translate to Zig - we use `ai_types.Message` directly
- **AbortController pattern** replaced with `CancelToken` (atomic bool wrapper)
- **Promise tracking** for `waitForIdle()` would need a simple completion flag or condition variable
