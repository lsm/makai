# Agent Loop Design Plan

## Overview

This document describes the design for implementing an agent loop in the Makai Zig codebase, mirroring the pi-mono TypeScript implementation. The agent package provides:

1. **Low-level API**: `agentLoop()` / `agentLoopContinue()` functions - stateless generator functions
2. **High-level API**: `Agent` class - stateful, manages subscriptions, queues messages

## Goals

1. **Clean Architecture**: Agent loop uses ProtocolClient as single interface to provider layer
2. **Event-Driven Architecture**: Emit granular events for UI updates via `AgentEventStream`
3. **Tool Execution**: Execute tools sequentially with streaming update support
4. **Multi-Turn Support**: Automatically continue conversation when tools are called
5. **Steering/Follow-up**: Support mid-run interruption and post-completion follow-up messages
6. **State Management**: Track streaming state, pending tool calls, and current partial message

## Architecture

### Layer Separation

```
┌─────────────────────────────────────────────────────────────────┐
│                        Agent Layer                               │
│  agent.zig, agent_loop.zig, types.zig                           │
│  - Turn management, tool execution, steering/follow-up          │
│  - Uses ProtocolClient interface (no provider knowledge)        │
└─────────────────────┬───────────────────────────────────────────┘
                      │ ProtocolClient interface
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Protocol Layer                               │
│  client.zig, server.zig, types.zig                              │
│  - Wire protocol (envelopes, sequencing)                        │
│  - Transport abstraction (WebSocket, TCP, etc.)                 │
└─────────────────────┬───────────────────────────────────────────┘
                      │ Provider API calls
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Provider Layer                              │
│  api_registry.zig, providers/*                                  │
│  - Provider implementations (Anthropic, OpenAI, Google, etc.)   │
│  - Credential management, transport details (SSE, etc.)         │
└─────────────────────────────────────────────────────────────────┘
```

**Key Principle**: The agent loop does NOT know about:
- Which transport the provider uses (SSE, WebSocket, etc.)
- How credentials are resolved
- Provider-specific API formats

All of that is hidden behind the `ProtocolClient` interface.

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
  └── (uses ai_types, event_stream)
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
```

### ProtocolClient Interface

The agent loop uses a single interface to communicate with the provider layer:

```zig
/// Protocol client interface for agent loop.
/// Abstracts away transport, credentials, and provider specifics.
pub const ProtocolClient = struct {
    /// Stream function pointer
    stream_fn: *const fn (
        ctx: ?*anyopaque,
        model: ai_types.Model,
        context: ai_types.Context,
        options: ProtocolOptions,
        allocator: std.mem.Allocator,
    ) anyerror!*event_stream.AssistantMessageEventStream,

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

/// Options for protocol streaming (agent-level concerns only)
pub const ProtocolOptions = struct {
    api_key: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    cancel_token: ?ai_types.CancelToken = null,
    thinking_budgets: ?ai_types.ThinkingBudgets = null,
    max_retry_delay_ms: u32 = 60_000,
    // Note: NO transport field - that's provider-level config
};
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

    // Protocol client (single interface to provider layer)
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
          - Call protocol.stream()
          - Forward AssistantMessageEvents as message_update events
          - Emit message_start on first event, message_end on done
      iii. Check stop_reason:
           - error/aborted: exit both loops
           - tool_use: execute tools
           - stop: continue to outer loop
      iv. If tool calls:
          - For each tool call (sequential):
            a. Emit tool_execution_start
            b. Execute tool (may emit tool_execution_update during)
            c. Emit tool_execution_end
            d. Check steering messages - if any:
               - Skip remaining tools with skipToolCall()
               - Break out of tool loop
          - Create ToolResultMessage for each result (including skipped)
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

## Tool Execution

### executeToolCalls

```zig
const ToolExecutionResult = struct {
    tool_results: []ai_types.ToolResultMessage,
    has_steering: bool,
    steering_messages: ?[]ai_types.Message,
};

fn executeToolCalls(
    allocator: std.mem.Allocator,
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
    var has_steering = false;
    var steering_messages: ?[]ai_types.Message = null;

    for (tool_calls.items) |tool_call| {
        // Find tool
        const tool = findTool(config.tools, tool_call.name);

        // Emit start event
        try event_stream.push(.{ .tool_execution_start = .{
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .args_json = tool_call.arguments_json,
        }});

        var result: AgentToolResult = undefined;
        var is_error = false;

        if (tool) |t| {
            // Create context for tool update callback
            var update_ctx = ToolUpdateContext{
                .event_stream = event_stream,
                .tool_call_id = tool_call.id,
                .tool_name = tool_call.name,
            };

            result = t.execute(
                tool_call.id,
                tool_call.arguments_json,
                config.cancel_token,
                &update_ctx,     // Context for callback
                onToolUpdate,    // Callback function
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
        }});

        // Create tool result message
        try results.append(createToolResultMessage(allocator, tool_call, result, is_error));

        // Check for steering messages - skip remaining tools if any
        if (config.get_steering_messages_fn) |get_steering| {
            if (try get_steering(config.get_steering_messages_ctx, allocator)) |msgs| {
                if (msgs.len > 0) {
                    steering_messages = msgs;
                    has_steering = true;

                    // Skip remaining tools - emit skip events for each
                    const remaining = tool_calls.items[tool_call_index + 1..];
                    for (remaining) |skipped_call| {
                        try results.append(skipToolCall(allocator, skipped_call, event_stream));
                    }
                    break;
                } else {
                    allocator.free(msgs);
                }
            }
        }
    }

    return .{
        .tool_results = try results.toOwnedSlice(),
        .has_steering = has_steering,
        .steering_messages = steering_messages,
    };
}
```

### skipToolCall

When a steering message arrives, remaining tool calls must be marked as skipped so the LLM receives complete tool results:

```zig
/// Skip a tool call due to steering message interrupt.
/// Emits tool_execution_start/end events and returns a ToolResultMessage
/// with an error indicating the tool was skipped.
fn skipToolCall(
    allocator: std.mem.Allocator,
    tool_call: ai_types.ToolCall,
    event_stream: *AgentEventStream,
) !ai_types.ToolResultMessage {
    const skip_message = "Skipped due to queued user message.";

    // Emit start event
    try event_stream.push(.{ .tool_execution_start = .{
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .args_json = tool_call.arguments_json,
    }});

    // Emit end event with skip result
    try event_stream.push(.{ .tool_execution_end = .{
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .result_json = skip_message,
        .is_error = true,
    }});

    // Create tool result message
    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    content[0] = .{ .text = .{
        .text = try allocator.dupe(u8, skip_message),
    }};

    return .{
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
        .tool_name = try allocator.dupe(u8, tool_call.name),
        .content = content,
        .is_error = true,
        .timestamp = std.time.milliTimestamp(),
    };
}
```

### Tool Update Streaming

Long-running tools can report progress via the `on_update` callback:

```zig
/// Context passed to tool update callback
const ToolUpdateContext = struct {
    event_stream: *AgentEventStream,
    tool_call_id: []const u8,
    tool_name: []const u8,
};

/// Callback invoked by tools during execution to report progress
fn onToolUpdate(
    ctx: ?*anyopaque,
    tool_call_id: []const u8,
    tool_name: []const u8,
    partial_result_json: []const u8,
) void {
    const context: *ToolUpdateContext = @ptrCast(@alignCast(ctx));

    context.event_stream.push(.{ .tool_execution_update = .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .partial_result_json = partial_result_json,
    }}) catch {};
}
```

**Example: Long-running tool with progress updates**

```zig
const SearchFilesTool = struct {
    fn execute(
        tool_call_id: []const u8,
        args_json: []const u8,
        cancel_token: ?ai_types.CancelToken,
        on_update_ctx: ?*anyopaque,
        on_update: ?ToolUpdateCallback,
        allocator: std.mem.Allocator,
    ) anyerror!AgentToolResult {
        const args = try parseArgs(allocator, args_json);
        var results = std.ArrayList(FileMatch).init(allocator);

        const files = try getAllFiles(allocator, args.directory);
        for (files, 0..) |file, i| {
            // Check for cancellation
            if (cancel_token) |token| {
                if (token.isCancelled()) break;
            }

            const matches = try searchFile(allocator, file, args.query);
            try results.appendSlice(matches);

            // Report progress every 100 files
            if (on_update) |callback| {
                if (i % 100 == 0) {
                    const progress = try std.fmt.allocPrint(allocator,
                        "{{\"scanned\":{},\"total\":{},\"matches\":{}}}",
                        .{ i + 1, files.len, results.items.len });
                    defer allocator.free(progress);

                    callback(on_update_ctx, tool_call_id, "search_files", progress);
                }
            }
        }

        return .{
            .content = try buildContent(allocator, results.items),
            .details_json = try buildDetails(allocator, results.items),
            .owned_strings = true,
        };
    }
};
```

---

## High-Level API (agent.zig)

### AgentOptions

```zig
pub const AgentOptions = struct {
    // Initial state
    initial_state: ?AgentState = null,

    // Protocol client (required)
    protocol: ProtocolClient,

    // Message transformation
    convert_to_llm_fn: ?ConvertToLlmFn = null,
    convert_to_llm_ctx: ?*anyopaque = null,
    transform_context_fn: ?TransformContextFn = null,
    transform_context_ctx: ?*anyopaque = null,

    // Queue modes
    steering_mode: QueueMode = .one_at_a_time,
    follow_up_mode: QueueMode = .one_at_a_time,

    // Protocol options
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

    // Protocol client
    _protocol: ProtocolClient,

    // Subscribers
    _listeners: std.ArrayList(*const fn (event: AgentEvent) void),

    // Control
    _cancel_token: ?ai_types.CancelToken = null,
    _is_running: bool = false,

    // Message queues
    _steering_queue: std.ArrayList(ai_types.Message),
    _follow_up_queue: std.ArrayList(ai_types.Message),
    _steering_mode: QueueMode,
    _follow_up_mode: QueueMode,

    // Skip initial steering poll flag (stored in run context, not global)
    _skip_initial_steering_poll: bool = false,

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

    /// Wait for the agent to become idle.
    /// Returns immediately if not running, otherwise blocks until current operation completes.
    pub fn waitForIdle(self: *Agent) void;

    /// Reset all state (clear messages, queues, error).
    pub fn reset(self: *Agent) void;

    // === Internal ===

    fn runLoop(self: *Agent, messages: ?[]const ai_types.Message) !void;
    fn emit(self: *Agent, event: AgentEvent) void;
    fn dequeueSteeringMessages(self: *Agent) ?[]const ai_types.Message;
    fn dequeueFollowUpMessages(self: *Agent) ?[]const ai_types.Message;
};
```

---

## Protocol Client Integration

### Creating a Protocol Client

The protocol client wraps the protocol layer and provides a clean interface to the agent:

```zig
const protocol = @import("protocol");

/// Create a protocol client that connects to a remote server
fn createProtocolClient(allocator: std.mem.Allocator, server_url: []const u8) !ProtocolClient {
    var client = try protocol.Client.init(allocator, server_url);

    return .{
        .stream_fn = protocolStreamFn,
        .ctx = client,
    };
}

/// Stream function that uses protocol client
fn protocolStreamFn(
    ctx: ?*anyopaque,
    model: ai_types.Model,
    context: ai_types.Context,
    options: ProtocolOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageEventStream {
    const client: *protocol.Client = @ptrCast(@alignCast(ctx));

    // Convert protocol options to stream options
    const stream_options = ai_types.SimpleStreamOptions{
        .api_key = options.api_key,
        .session_id = options.session_id,
        .cancel_token = options.cancel_token,
        .thinking_budgets = options.thinking_budgets,
        .retry = .{ .max_retry_delay_ms = options.max_retry_delay_ms },
    };

    return client.streamRequest(model, context, stream_options, allocator);
}
```

### In-Process Protocol (Direct Provider Access)

For cases where the agent runs in the same process as the providers:

```zig
const api_registry = @import("api_registry");

/// Create a protocol client that uses providers directly
fn createInProcessProtocolClient(allocator: std.mem.Allocator, registry: *api_registry.ApiRegistry) !ProtocolClient {
    var ctx = try allocator.create(InProcessContext);
    ctx.* = .{
        .allocator = allocator,
        .registry = registry,
    };

    return .{
        .stream_fn = inProcessStreamFn,
        .ctx = ctx,
    };
}

const InProcessContext = struct {
    allocator: std.mem.Allocator,
    registry: *api_registry.ApiRegistry,
};

fn inProcessStreamFn(
    ctx: ?*anyopaque,
    model: ai_types.Model,
    context: ai_types.Context,
    options: ProtocolOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageEventStream {
    const ipc: *InProcessContext = @ptrCast(@alignCast(ctx));

    // Look up provider in registry
    const provider = ipc.registry.getApiProvider(model.api)
        orelse return error.ProviderNotFound;

    // Build stream options
    const stream_options = ai_types.SimpleStreamOptions{
        .api_key = options.api_key,
        .session_id = options.session_id,
        .cancel_token = options.cancel_token,
        .thinking_budgets = options.thinking_budgets,
        .retry = .{ .max_retry_delay_ms = options.max_retry_delay_ms },
    };

    // Call provider directly
    return provider.stream_simple(model, context, stream_options, allocator);
}
```

---

## Example Usage

### High-Level API with Remote Protocol Server

```zig
const std = @import("std");
const agent = @import("agent");
const ai_types = @import("ai_types");

fn onAgentEvent(event: agent.AgentEvent) void {
    switch (event) {
        .tool_execution_start => |e| {
            std.debug.print("Tool started: {s}\n", .{e.tool_name});
        },
        .tool_execution_update => |e| {
            std.debug.print("Tool progress: {s}\n", .{e.partial_result_json});
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

    // Create protocol client (connects to remote server)
    const protocol_client = try createProtocolClient(allocator, "ws://localhost:8080");

    // Create agent with protocol client
    var ag = agent.Agent.init(allocator, .{
        .protocol = protocol_client,
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

    // Wait for completion
    ag.waitForIdle();
}
```

### High-Level API with In-Process Providers

```zig
const std = @import("std");
const agent = @import("agent");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize registry with built-in providers
    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try @import("register_builtins").registerBuiltins(&registry);

    // Create in-process protocol client
    const protocol_client = try createInProcessProtocolClient(allocator, &registry);

    // Create agent
    var ag = agent.Agent.init(allocator, .{
        .protocol = protocol_client,
    });
    defer ag.deinit();

    // ... rest is the same
}
```

---

## Implementation Order

1. **types.zig** - All type definitions
   - AgentEvent variants and payloads
   - AgentTool, AgentToolResult
   - ProtocolClient, ProtocolOptions
   - AgentLoopConfig, AgentContext, AgentState
   - QueueMode

2. **agent_loop.zig** - Core loop implementation
   - `agentLoop()` entry point
   - `agentLoopContinue()` entry point
   - `runLoop()` inner/outer loop logic
   - `streamAssistantResponse()` - protocol client integration
   - `executeToolCalls()` - tool execution with steering check
   - `skipToolCall()` - mark skipped tools
   - `onToolUpdate()` - streaming progress callback

3. **agent.zig** - High-level Agent class
   - State management
   - Message queues (steering/follow-up)
   - Subscribe/unsubscribe
   - Control flow (prompt, continue, abort, reset, waitForIdle)

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
| Provider access | streamFn or direct | ProtocolClient interface only |
| Steering skip | Global skipInitialSteeringPoll | Stored in run context |

---

## Notes

- **Clean Layer Separation**: Agent loop uses ProtocolClient as single interface. Transport and credential details are hidden in the provider layer.
- **skipToolCall**: When steering messages arrive, remaining tools are skipped with proper error events so the LLM receives complete tool results.
- **Tool Update Streaming**: Long-running tools can report progress via the on_update callback, which pushes tool_execution_update events.
- **No Global State**: The skip_initial_steering_poll flag is stored in the run context, not a global variable, making it safe for multiple agents.
- **TypeScript's declaration merging for AgentMessage** doesn't translate to Zig - we use `ai_types.Message` directly
- **AbortController pattern** replaced with `CancelToken` (atomic bool wrapper)
