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
/// The agent uses a ProtocolClient interface to communicate with the provider layer.
/// This abstracts away transport, credentials, and provider-specific details.
///
/// ### Example: In-Process Provider Access
/// ```zig
/// const protocol = createInProcessProtocolClient(allocator, &registry);
/// var agent = Agent.init(allocator, .{
///     .protocol = protocol,
/// });
/// ```
///
/// ### Example: Remote Protocol Server
/// ```zig
/// const protocol = createRemoteProtocolClient(allocator, "ws://localhost:8080");
/// var agent = Agent.init(allocator, .{
///     .protocol = protocol,
/// });
/// ```
const std = @import("std");
const types = @import("agent_types");
const agent_loop_mod = @import("agent_loop");

// Re-export all public types from types.zig
pub const AgentEvent = types.AgentEvent;
pub const AgentEndPayload = types.AgentEndPayload;
pub const TurnEndPayload = types.TurnEndPayload;
pub const MessageStartPayload = types.MessageStartPayload;
pub const MessageUpdatePayload = types.MessageUpdatePayload;
pub const MessageEndPayload = types.MessageEndPayload;
pub const ToolExecutionStartPayload = types.ToolExecutionStartPayload;
pub const ToolExecutionUpdatePayload = types.ToolExecutionUpdatePayload;
pub const ToolExecutionEndPayload = types.ToolExecutionEndPayload;
pub const AgentTool = types.AgentTool;
pub const AgentToolResult = types.AgentToolResult;
pub const ToolUpdateCallback = types.ToolUpdateCallback;
pub const ToolExecuteFn = types.ToolExecuteFn;
pub const AgentStreamFn = types.AgentStreamFn;
pub const TransformContextFn = types.TransformContextFn;
pub const GetSteeringMessagesFn = types.GetSteeringMessagesFn;
pub const GetFollowUpMessagesFn = types.GetFollowUpMessagesFn;
pub const ConvertToLlmFn = types.ConvertToLlmFn;
pub const GetApiKeyFn = types.GetApiKeyFn;
pub const AgentLoopConfig = types.AgentLoopConfig;
pub const AgentContext = types.AgentContext;
pub const AgentState = types.AgentState;
pub const AgentLoopResult = types.AgentLoopResult;
pub const AgentEventStream = types.AgentEventStream;
pub const QueueMode = types.QueueMode;

// Re-export ProtocolClient types
pub const ProtocolClient = types.ProtocolClient;
pub const ProtocolOptions = types.ProtocolOptions;
pub const ProtocolStreamFn = types.ProtocolStreamFn;

// Re-export low-level functions from agent_loop.zig
pub const agentLoop = agent_loop_mod.agentLoop;
pub const agentLoopContinue = agent_loop_mod.agentLoopContinue;

// Re-export high-level Agent class from agent.zig
pub const Agent = @import("agent.zig").Agent;
pub const AgentOptions = @import("agent.zig").AgentOptions;
pub const InProcessProviderProtocolBridge = @import("provider_protocol_bridge.zig").InProcessProviderProtocolBridge;

// Re-export commonly used types from dependencies for convenience
pub const ai_types = @import("ai_types");
pub const api_registry = @import("api_registry");
pub const event_stream = @import("event_stream");

// ============================================================================
// Tests
// ============================================================================

test {
    // Run all tests in the module
    _ = types;
    _ = agent_loop_mod;
    _ = @import("agent.zig");
    _ = @import("provider_protocol_bridge.zig");
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
    const bridge: InProcessProviderProtocolBridge = undefined;
    const protocol: ProtocolClient = undefined;
    const protocol_opts: ProtocolOptions = undefined;

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
    _ = bridge;
    _ = protocol;
    _ = protocol_opts;
}
