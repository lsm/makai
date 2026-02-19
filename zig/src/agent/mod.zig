/// Agent module - high-level agent loop abstraction
///
/// This module provides two levels of API:
///
/// 1. Low-level API: `agentLoop()` and `agentLoopContinue()` functions
///    - Stateless generator functions that emit events via AgentEventStream
///    - Full control over execution flow
///
/// 2. High-level API: `Agent` class
///    - Stateful wrapper that manages subscriptions and message queues
///    - Easier to use for most use cases
///
/// ## Provider Access
///
/// The agent supports two modes of provider access:
///
/// ### Option 1: Direct Provider Access (via ApiRegistry)
/// For in-process use where providers are registered locally:
/// ```zig
/// var registry = api_registry.ApiRegistry.init(allocator);
/// try registerBuiltins(&registry);
///
/// var agent = Agent.init(allocator, .{
///     .registry = &registry,
/// });
/// ```
///
/// ### Option 2: Custom Stream Function (via Protocol Client)
/// For remote access or custom implementations:
/// ```zig
/// fn streamViaProtocol(
///     model: ai_types.Model,
///     context: ai_types.Context,
///     options: ?ai_types.SimpleStreamOptions,
///     allocator: std.mem.Allocator,
/// ) anyerror!*event_stream.AssistantMessageEventStream {
///     // Use protocol client to communicate with remote server
/// }
///
/// var agent = Agent.init(allocator, .{
///     .stream_fn = streamViaProtocol,
/// });
/// ```

const std = @import("std");

// Re-export all public types from types.zig
pub const AgentEvent = @import("types.zig").AgentEvent;
pub const AgentEndPayload = @import("types.zig").AgentEndPayload;
pub const TurnEndPayload = @import("types.zig").TurnEndPayload;
pub const MessageStartPayload = @import("types.zig").MessageStartPayload;
pub const MessageUpdatePayload = @import("types.zig").MessageUpdatePayload;
pub const MessageEndPayload = @import("types.zig").MessageEndPayload;
pub const ToolExecutionStartPayload = @import("types.zig").ToolExecutionStartPayload;
pub const ToolExecutionUpdatePayload = @import("types.zig").ToolExecutionUpdatePayload;
pub const ToolExecutionEndPayload = @import("types.zig").ToolExecutionEndPayload;
pub const AgentTool = @import("types.zig").AgentTool;
pub const AgentToolResult = @import("types.zig").AgentToolResult;
pub const ToolUpdateCallback = @import("types.zig").ToolUpdateCallback;
pub const ToolExecuteFn = @import("types.zig").ToolExecuteFn;
pub const AgentStreamFn = @import("types.zig").AgentStreamFn;
pub const TransformContextFn = @import("types.zig").TransformContextFn;
pub const GetSteeringMessagesFn = @import("types.zig").GetSteeringMessagesFn;
pub const GetFollowUpMessagesFn = @import("types.zig").GetFollowUpMessagesFn;
pub const ConvertToLlmFn = @import("types.zig").ConvertToLlmFn;
pub const GetApiKeyFn = @import("types.zig").GetApiKeyFn;
pub const AgentLoopConfig = @import("types.zig").AgentLoopConfig;
pub const AgentContext = @import("types.zig").AgentContext;
pub const AgentState = @import("types.zig").AgentState;
pub const AgentLoopResult = @import("types.zig").AgentLoopResult;
pub const AgentEventStream = @import("types.zig").AgentEventStream;
pub const QueueMode = @import("types.zig").QueueMode;

// Re-export low-level functions from agent_loop.zig
pub const agentLoop = @import("agent_loop.zig").agentLoop;
pub const agentLoopContinue = @import("agent_loop.zig").agentLoopContinue;

// Re-export high-level Agent class from agent.zig
pub const Agent = @import("agent.zig").Agent;
pub const AgentOptions = @import("agent.zig").AgentOptions;

// Re-export commonly used types from dependencies for convenience
pub const ai_types = @import("ai_types");
pub const api_registry = @import("api_registry");
pub const event_stream = @import("event_stream");

// ============================================================================
// Tests
// ============================================================================

test {
    // Run all tests in the module
    _ = @import("types.zig");
    _ = @import("agent_loop.zig");
    _ = @import("agent.zig");
}

test "module exports all required types" {
    // Verify all types are accessible by referencing them
    const event: AgentEvent = undefined;
    const tool: AgentTool = undefined;
    const config: AgentLoopConfig = undefined;
    const ctx: AgentContext = undefined;
    const state: AgentState = undefined;
    const result: AgentLoopResult = undefined;
    const stream: AgentEventStream = undefined;
    const mode: QueueMode = undefined;
    const agent: Agent = undefined;
    const opts: AgentOptions = undefined;

    // Use the variables to avoid unused errors
    _ = event;
    _ = tool;
    _ = config;
    _ = ctx;
    _ = state;
    _ = result;
    _ = stream;
    _ = mode;
    _ = agent;
    _ = opts;
}
