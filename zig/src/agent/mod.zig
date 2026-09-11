const std = @import("std");
const types = @import("agent_types");
const agent_loop_mod = @import("agent_loop");

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
pub const ToolApprovalDecision = types.ToolApprovalDecision;
pub const ToolApprovalRequest = types.ToolApprovalRequest;
pub const ToolApprovalUiFn = types.ToolApprovalUiFn;
pub const ToolApprovalDecisionFn = types.ToolApprovalDecisionFn;
pub const ToolApprovalFn = types.ToolApprovalFn;
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

pub const ProtocolClient = types.ProtocolClient;
pub const ProtocolOptions = types.ProtocolOptions;
pub const ProtocolStreamFn = types.ProtocolStreamFn;

pub const agentLoop = agent_loop_mod.agentLoop;
pub const agentLoopContinue = agent_loop_mod.agentLoopContinue;

pub const Agent = @import("agent.zig").Agent;
pub const AgentOptions = @import("agent.zig").AgentOptions;
pub const InProcessProviderProtocolBridge = @import("provider_protocol_bridge.zig").InProcessProviderProtocolBridge;

pub const ai_types = @import("ai_types");
pub const api_registry = @import("api_registry");
pub const event_stream = @import("event_stream");

test {
    _ = types;
    _ = agent_loop_mod;
    _ = @import("agent.zig");
    _ = @import("provider_protocol_bridge.zig");
}

test "module exports all required types" {
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
