const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const event_stream_module = @import("event_stream");
const types = @import("agent_types");
const owned_slice_mod = @import("owned_slice");

// Re-export types needed by callers
pub const AgentEvent = types.AgentEvent;
pub const AgentEventStream = types.AgentEventStream;
pub const AgentLoopConfig = types.AgentLoopConfig;
pub const AgentLoopResult = types.AgentLoopResult;
pub const AgentContext = types.AgentContext;
pub const AgentTool = types.AgentTool;
pub const AgentToolResult = types.AgentToolResult;
pub const ProtocolClient = types.ProtocolClient;
pub const ProtocolOptions = types.ProtocolOptions;

const ByteTokenEstimate = struct {
    bytes: u64 = 0,
    estimated_tokens: u64 = 0,
};

const ToolResultUsage = struct {
    result_bytes: u64 = 0,
    details_bytes: u64 = 0,
    total_bytes: u64 = 0,
    estimated_tokens: u64 = 0,
    artifact_count: u32 = 0,
};

const ContextUsage = struct {
    system_prompt: ByteTokenEstimate = .{},
    messages: ByteTokenEstimate = .{},
    tools: ByteTokenEstimate = .{},

    fn totalBytes(self: ContextUsage) u64 {
        return self.system_prompt.bytes + self.messages.bytes + self.tools.bytes;
    }

    fn totalEstimatedTokens(self: ContextUsage) u64 {
        return self.system_prompt.estimated_tokens + self.messages.estimated_tokens + self.tools.estimated_tokens;
    }
};

fn estimateTextTokens(len: usize) u64 {
    if (len == 0) return 0;
    return @intCast((len + 3) / 4);
}

fn addText(est: *ByteTokenEstimate, text: []const u8) void {
    est.bytes += text.len;
    est.estimated_tokens += estimateTextTokens(text.len);
}

fn addImage(est: *ByteTokenEstimate, image: ai_types.ImageContent) void {
    est.bytes += image.data.len + image.mime_type.len;
    est.estimated_tokens += 850;
}

fn estimateUserContentPart(part: ai_types.UserContentPart) ByteTokenEstimate {
    var est: ByteTokenEstimate = .{};
    switch (part) {
        .text => |text| addText(&est, text.text),
        .image => |image| addImage(&est, image),
    }
    return est;
}

fn estimateUserContentParts(parts: []const ai_types.UserContentPart) ByteTokenEstimate {
    var est: ByteTokenEstimate = .{};
    for (parts) |part| {
        const part_est = estimateUserContentPart(part);
        est.bytes += part_est.bytes;
        est.estimated_tokens += part_est.estimated_tokens;
    }
    return est;
}

fn estimateAssistantContent(block: ai_types.AssistantContent) ByteTokenEstimate {
    var est: ByteTokenEstimate = .{};
    switch (block) {
        .text => |text| addText(&est, text.text),
        .thinking => |thinking| addText(&est, thinking.thinking),
        .image => |image| addImage(&est, image),
        .tool_call => |tool_call| {
            addText(&est, tool_call.id);
            addText(&est, tool_call.name);
            addText(&est, tool_call.arguments_json);
            est.estimated_tokens += 50;
        },
    }
    return est;
}

fn estimateMessage(message: ai_types.Message) ByteTokenEstimate {
    var est: ByteTokenEstimate = .{ .estimated_tokens = 5 };
    switch (message) {
        .user => |user| switch (user.content) {
            .text => |text| addText(&est, text),
            .parts => |parts| {
                const parts_est = estimateUserContentParts(parts);
                est.bytes += parts_est.bytes;
                est.estimated_tokens += parts_est.estimated_tokens;
            },
        },
        .assistant => |assistant| {
            for (assistant.content) |block| {
                const block_est = estimateAssistantContent(block);
                est.bytes += block_est.bytes;
                est.estimated_tokens += block_est.estimated_tokens;
            }
        },
        .tool_result => |tool_result| {
            addText(&est, tool_result.tool_call_id);
            addText(&est, tool_result.tool_name);
            const parts_est = estimateUserContentParts(tool_result.content);
            est.bytes += parts_est.bytes;
            est.estimated_tokens += parts_est.estimated_tokens;
            if (tool_result.getDetailsJson()) |details| addText(&est, details);
        },
    }
    return est;
}

fn estimateMessages(messages: []const ai_types.Message) ByteTokenEstimate {
    var est: ByteTokenEstimate = .{};
    for (messages) |message| {
        const msg_est = estimateMessage(message);
        est.bytes += msg_est.bytes;
        est.estimated_tokens += msg_est.estimated_tokens;
    }
    return est;
}

fn estimateToolDefinitions(tools: ?[]const ai_types.Tool) ByteTokenEstimate {
    var est: ByteTokenEstimate = .{};
    const defs = tools orelse return est;
    for (defs) |tool| {
        addText(&est, tool.name);
        addText(&est, tool.description);
        addText(&est, tool.parameters_schema_json);
        est.estimated_tokens += 12;
    }
    return est;
}

fn estimateContextUsage(context: ai_types.Context) ContextUsage {
    const system_prompt = context.getSystemPrompt() orelse "";
    return .{
        .system_prompt = .{
            .bytes = system_prompt.len,
            .estimated_tokens = estimateTextTokens(system_prompt.len),
        },
        .messages = estimateMessages(context.messages),
        .tools = estimateToolDefinitions(context.tools),
    };
}

fn emitContextUsage(event_stream: *AgentEventStream, context: ai_types.Context) !void {
    const usage = estimateContextUsage(context);
    const system_prompt: []const u8 = context.getSystemPrompt() orelse "";
    try event_stream.push(.{ .prompt_segment_usage = .{
        .segment = .system_prompt,
        .cache_role = .stable,
        .bytes = usage.system_prompt.bytes,
        .estimated_tokens = usage.system_prompt.estimated_tokens,
        .item_count = if (system_prompt.len > 0) 1 else 0,
    } });
    try event_stream.push(.{ .prompt_segment_usage = .{
        .segment = .tool_definitions,
        .cache_role = .stable,
        .bytes = usage.tools.bytes,
        .estimated_tokens = usage.tools.estimated_tokens,
        .item_count = if (context.tools) |tools| @intCast(tools.len) else 0,
    } });
    try event_stream.push(.{ .prompt_segment_usage = .{
        .segment = .message_history,
        .cache_role = .dynamic,
        .bytes = usage.messages.bytes,
        .estimated_tokens = usage.messages.estimated_tokens,
        .item_count = @intCast(context.messages.len),
    } });
    try event_stream.push(.{ .context_usage = .{
        .system_prompt_bytes = usage.system_prompt.bytes,
        .message_bytes = usage.messages.bytes,
        .tool_definition_bytes = usage.tools.bytes,
        .total_bytes = usage.totalBytes(),
        .estimated_tokens = usage.totalEstimatedTokens(),
        .message_count = @intCast(context.messages.len),
        .tool_count = if (context.tools) |tools| @intCast(tools.len) else 0,
    } });
}

fn measureToolResult(result: AgentToolResult) ToolResultUsage {
    const content = estimateUserContentParts(result.content.slice());
    const details_bytes: u64 = if (result.getDetailsJson()) |details| details.len else 0;
    return .{
        .result_bytes = content.bytes,
        .details_bytes = details_bytes,
        .total_bytes = content.bytes + details_bytes,
        .estimated_tokens = content.estimated_tokens + estimateTextTokens(@intCast(details_bytes)),
        .artifact_count = @intCast(result.artifacts.slice().len),
    };
}

/// Build tool definitions array for LLM request
fn buildToolsArray(
    allocator: std.mem.Allocator,
    tools: ?[]const AgentTool,
) !?[]ai_types.Tool {
    const agent_tools = tools orelse return null;
    if (agent_tools.len == 0) return null;

    var result = try allocator.alloc(ai_types.Tool, agent_tools.len);
    for (agent_tools, 0..) |tool, i| {
        result[i] = try tool.toTool(allocator);
    }
    return result;
}

/// Find a tool by name
fn findTool(tools: ?[]const AgentTool, name: []const u8) ?AgentTool {
    const agent_tools = tools orelse return null;
    for (agent_tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

/// Validate tool arguments against the tool's parameter schema.
/// Currently a placeholder that passes through arguments unchanged.
/// TODO: Implement JSON Schema validation when a suitable validator is available.
fn validateToolArguments(
    allocator: std.mem.Allocator,
    tool: AgentTool,
    args_json: []const u8,
) ![]const u8 {
    _ = allocator;
    _ = tool.parameters_schema_json; // Would be used for schema validation

    // For now, pass through the arguments unchanged.
    // In the future, this should:
    // 1. Parse the JSON schema from tool.parameters_schema_json
    // 2. Parse args_json
    // 3. Validate args against schema
    // 4. Return validated args (possibly with defaults filled in)
    // 5. Return error.InvalidToolArguments if validation fails

    return args_json;
}

/// Create an error result for failed tool execution
fn createErrorResult(allocator: std.mem.Allocator, err: anyerror) !AgentToolResult {
    const error_name = @errorName(err);
    _ = error_name; // We could include this in the error message
    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    content[0] = .{ .text = .{
        .text = try allocator.dupe(u8, "Tool execution failed"),
    } };
    return .{
        .content = types.OwnedSlice(ai_types.UserContentPart).initOwned(content),
        .details_json = ai_types.OwnedSlice(u8).initBorrowed(""),
    };
}

fn rejectedToolResult(allocator: std.mem.Allocator) !AgentToolResult {
    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    content[0] = .{ .text = .{
        .text = try allocator.dupe(u8, "Tool execution rejected by user"),
    } };
    return .{
        .content = types.OwnedSlice(ai_types.UserContentPart).initOwned(content),
        .details_json = types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "{\"rejected\":true}")),
    };
}

/// Create a tool result message from execution result
fn createToolResultMessage(
    allocator: std.mem.Allocator,
    tool_call: ai_types.ToolCall,
    result: AgentToolResult,
    is_error: bool,
) !ai_types.ToolResultMessage {
    const details_json = if (result.getDetailsJson()) |details|
        if (result.details_json.is_owned)
            ai_types.OwnedSlice(u8).initOwned(@constCast(details))
        else
            ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, details))
    else
        ai_types.OwnedSlice(u8).initBorrowed("");
    errdefer {
        var mutable = details_json;
        mutable.deinit(allocator);
    }

    const artifacts = if (result.artifacts.is_owned)
        ai_types.OwnedSlice(ai_types.ArtifactReference).initOwned(@constCast(result.artifacts.slice()))
    else
        ai_types.OwnedSlice(ai_types.ArtifactReference).initBorrowed(result.artifacts.slice());

    return .{
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
        .tool_name = try allocator.dupe(u8, tool_call.name),
        .content = result.content.slice(),
        .details_json = details_json,
        .artifacts = artifacts,
        .is_error = is_error,
        .timestamp = compat.time.nowMillis(),
    };
}

/// Callback context for tool updates
const ToolUpdateContext = struct {
    event_stream: *AgentEventStream,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
};

/// Tool update callback implementation - pushes tool_execution_update events
fn onToolUpdate(ctx: ?*anyopaque, tool_call_id: []const u8, tool_name: []const u8, partial_result_json: []const u8) void {
    const context: *ToolUpdateContext = @ptrCast(@alignCast(ctx));

    context.event_stream.push(.{ .tool_execution_update = .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .args_json = context.args_json,
        .partial_result_json = partial_result_json,
    } }) catch {};
}

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
    } });

    // Emit end event with skip result
    try event_stream.push(.{ .tool_execution_end = .{
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .result_json = skip_message,
        .is_error = true,
    } });

    // Create tool result message
    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    content[0] = .{ .text = .{
        .text = try allocator.dupe(u8, skip_message),
    } };

    return .{
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
        .tool_name = try allocator.dupe(u8, tool_call.name),
        .content = content,
        .details_json = ai_types.OwnedSlice(u8).initBorrowed(""),
        .is_error = true,
        .timestamp = compat.time.nowMillis(),
    };
}

fn finalizeToolExecution(
    allocator: std.mem.Allocator,
    config: AgentLoopConfig,
    event_stream: *AgentEventStream,
    results: *std.ArrayList(ai_types.ToolResultMessage),
    tool_call: ai_types.ToolCall,
    args_json: []const u8,
    result: *AgentToolResult,
    is_error: bool,
) !void {
    const raw_usage = measureToolResult(result.*);

    if (config.tool_output_middleware_fn) |middleware| {
        try middleware(config.tool_output_middleware_ctx, .{
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .args_json = args_json,
            .is_error = is_error,
            .raw_result_bytes = raw_usage.result_bytes,
            .raw_details_bytes = raw_usage.details_bytes,
            .raw_total_bytes = raw_usage.total_bytes,
        }, result, allocator);
    }

    const returned_usage = measureToolResult(result.*);
    const result_json = result.getDetailsJson() orelse "null";
    const args_bytes: u64 = @intCast(args_json.len);

    try event_stream.push(.{ .tool_execution_end = .{
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .result_json = result_json,
        .is_error = is_error,
        .args_bytes = args_bytes,
        .raw_result_bytes = raw_usage.result_bytes,
        .returned_result_bytes = returned_usage.result_bytes,
        .raw_details_bytes = raw_usage.details_bytes,
        .returned_details_bytes = returned_usage.details_bytes,
        .raw_total_bytes = raw_usage.total_bytes + args_bytes,
        .returned_total_bytes = returned_usage.total_bytes + args_bytes,
        .estimated_returned_tokens = returned_usage.estimated_tokens + estimateTextTokens(args_json.len),
        .artifact_count = returned_usage.artifact_count,
        .artifacts = result.artifacts.slice(),
    } });

    const tool_result_msg = try createToolResultMessage(allocator, tool_call, result.*, is_error);
    try results.append(allocator, tool_result_msg);
}

fn runLegacyApproval(tool: AgentTool, approval_request: types.ToolApprovalRequest, allocator: std.mem.Allocator) types.ToolApprovalDecision {
    if (tool.approval_ui_fn) |notify| {
        notify(tool.approval_ui_ctx, approval_request, allocator);
    }
    if (tool.approval_fn) |approval| {
        return approval(tool.approval_ctx, approval_request);
    }
    return .approve;
}

/// Result from tool execution phase
const ToolExecutionResult = struct {
    tool_results: []ai_types.ToolResultMessage,
    compact_args: [][]u8 = &.{},
    has_steering: bool,
    steering_messages: ?[]const ai_types.Message,

    fn deinit(self: *ToolExecutionResult, allocator: std.mem.Allocator) void {
        for (self.tool_results) |*result| {
            result.deinit(allocator);
        }
        allocator.free(self.tool_results);
        for (self.compact_args) |args| allocator.free(args);
        allocator.free(self.compact_args);
        if (self.steering_messages) |msgs| {
            const mut_msgs: []ai_types.Message = @constCast(msgs);
            for (mut_msgs) |*msg| msg.deinit(allocator);
            allocator.free(mut_msgs);
        }
    }
};

/// Execute tool calls from assistant message
fn supportsCompactToolOutput(allocator: std.mem.Allocator, tool: AgentTool) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, tool.parameters_schema_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const properties = parsed.value.object.get("properties") orelse return false;
    if (properties != .object) return false;
    return properties.object.contains("compact_output");
}

test "compact output support requires root schema property" {
    const nested = AgentTool{
        .label = "Nested",
        .name = "nested",
        .description = "Nested compact_output mention only.",
        .parameters_schema_json = "{\"type\":\"object\",\"properties\":{\"options\":{\"type\":\"object\",\"properties\":{\"compact_output\":{\"type\":\"boolean\"}}}},\"additionalProperties\":false}",
        .execute = undefined,
    };
    try std.testing.expect(!try supportsCompactToolOutput(std.testing.allocator, nested));
    const root = AgentTool{
        .label = "Root",
        .name = "root",
        .description = "Root compact_output property.",
        .parameters_schema_json = "{\"type\":\"object\",\"properties\":{\"compact_output\":{\"type\":\"boolean\"}},\"additionalProperties\":false}",
        .execute = undefined,
    };
    try std.testing.expect(try supportsCompactToolOutput(std.testing.allocator, root));
}

fn withCompactToolOutput(allocator: std.mem.Allocator, args_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return try allocator.dupe(u8, args_json);
    try parsed.value.object.put(allocator, "compact_output", .{ .bool = true });
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

fn executeToolCalls(
    allocator: std.mem.Allocator,
    assistant_message: ai_types.AssistantMessage,
    config: AgentLoopConfig,
    event_stream: *AgentEventStream,
) !ToolExecutionResult {
    // Extract tool calls from assistant message
    var tool_calls: std.ArrayList(ai_types.ToolCall) = .empty;
    defer tool_calls.deinit(allocator);

    for (assistant_message.content) |block| {
        if (block == .tool_call) {
            try tool_calls.append(allocator, block.tool_call);
        }
    }

    var results: std.ArrayList(ai_types.ToolResultMessage) = .empty;
    var compact_args: std.ArrayList([]u8) = .empty;
    errdefer {
        for (compact_args.items) |args| allocator.free(args);
        compact_args.deinit(allocator);
    }
    var has_steering = false;
    var steering_messages: ?[]const ai_types.Message = null;

    for (tool_calls.items, 0..) |tool_call, index| {
        // Find tool
        const tool = findTool(config.tools, tool_call.name);

        // Emit start event
        try event_stream.push(.{ .tool_execution_start = .{
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .args_json = tool_call.arguments_json,
        } });

        var result: AgentToolResult = undefined;
        var is_error = false;
        var execution_args = tool_call.arguments_json;

        if (tool) |t| {
            // Validate tool arguments against schema
            const validated_args = validateToolArguments(allocator, t, tool_call.arguments_json) catch |err| {
                result = try createErrorResult(allocator, err);
                is_error = true;
                try finalizeToolExecution(allocator, config, event_stream, &results, tool_call, execution_args, &result, is_error);
                continue;
            };
            const should_compact = if (config.compact_tool_output) supportsCompactToolOutput(allocator, t) catch |err| {
                result = try createErrorResult(allocator, err);
                is_error = true;
                try finalizeToolExecution(allocator, config, event_stream, &results, tool_call, execution_args, &result, is_error);
                continue;
            } else false;
            if (should_compact) {
                const owned_args = withCompactToolOutput(allocator, validated_args) catch |err| {
                    result = try createErrorResult(allocator, err);
                    is_error = true;
                    try finalizeToolExecution(allocator, config, event_stream, &results, tool_call, execution_args, &result, is_error);
                    continue;
                };
                errdefer allocator.free(owned_args);
                try compact_args.append(allocator, owned_args);
                execution_args = owned_args;
            }

            const approval_request = types.ToolApprovalRequest{
                .tool_call_id = tool_call.id,
                .tool_name = tool_call.name,
                .args_json = execution_args,
            };
            if (config.permission_engine) |engine| {
                const policy_decision = engine.evaluate(tool_call.name, validated_args);
                if (policy_decision == .deny) {
                    result = try rejectedToolResult(allocator);
                    is_error = true;
                    try finalizeToolExecution(allocator, config, event_stream, &results, tool_call, execution_args, &result, is_error);
                    continue;
                }
                if (policy_decision == .prompt and engine.approval_callback != null) {
                    const decision = try engine.approve(tool_call.name, validated_args);
                    if (decision == .reject or decision == .reject_always) {
                        result = try rejectedToolResult(allocator);
                        is_error = true;
                        try finalizeToolExecution(allocator, config, event_stream, &results, tool_call, execution_args, &result, is_error);
                        continue;
                    }
                } else if (policy_decision == .prompt) {
                    const legacy_decision = runLegacyApproval(t, approval_request, allocator);
                    if (legacy_decision == .reject or legacy_decision == .reject_always) {
                        result = try rejectedToolResult(allocator);
                        is_error = true;
                        try finalizeToolExecution(allocator, config, event_stream, &results, tool_call, execution_args, &result, is_error);
                        continue;
                    }
                }
            } else {
                const decision = runLegacyApproval(t, approval_request, allocator);
                if (decision == .reject or decision == .reject_always) {
                    result = try rejectedToolResult(allocator);
                    is_error = true;
                    try finalizeToolExecution(allocator, config, event_stream, &results, tool_call, execution_args, &result, is_error);
                    continue;
                }
            }

            // Create context for tool update callback
            var update_ctx = ToolUpdateContext{
                .event_stream = event_stream,
                .tool_call_id = tool_call.id,
                .tool_name = tool_call.name,
                .args_json = execution_args,
            };

            result = blk: {
                if (config.execute_tool_via_protocol_fn) |exec_remote| {
                    break :blk exec_remote(
                        config.execute_tool_via_protocol_ctx,
                        tool_call.id,
                        tool_call.name,
                        execution_args,
                        config.cancel_token,
                        &update_ctx,
                        onToolUpdate,
                        allocator,
                    ) catch |err| {
                        result = try createErrorResult(allocator, err);
                        is_error = true;
                        break :blk result;
                    };
                }

                break :blk t.execute(
                    tool_call.id,
                    execution_args,
                    config.cancel_token,
                    &update_ctx,
                    onToolUpdate,
                    allocator,
                ) catch |err| {
                    result = try createErrorResult(allocator, err);
                    is_error = true;
                    break :blk result;
                };
            };
        } else {
            result = try createErrorResult(allocator, error.ToolNotFound);
            is_error = true;
        }

        try finalizeToolExecution(allocator, config, event_stream, &results, tool_call, execution_args, &result, is_error);

        // Check for steering messages - skip remaining tools if any
        if (config.get_steering_messages_fn) |get_steering| {
            if (try get_steering(config.get_steering_messages_ctx, allocator)) |msgs| {
                if (msgs.len > 0) {
                    steering_messages = msgs;
                    has_steering = true;

                    // Skip remaining tools - emit skip events for each
                    const remaining = tool_calls.items[index + 1 ..];
                    for (remaining) |skipped_call| {
                        const skipped_result = try skipToolCall(allocator, skipped_call, event_stream);
                        try results.append(allocator, skipped_result);
                    }
                    break;
                } else {
                    allocator.free(msgs);
                }
            }
        }
    }

    return .{
        .tool_results = try results.toOwnedSlice(allocator),
        .compact_args = try compact_args.toOwnedSlice(allocator),
        .has_steering = has_steering,
        .steering_messages = steering_messages,
    };
}

/// Stream assistant response from provider
fn streamAssistantResponse(
    allocator: std.mem.Allocator,
    context: *AgentContext,
    config: AgentLoopConfig,
    event_stream: *AgentEventStream,
) !ai_types.AssistantMessage {
    // Get messages to send to LLM
    var messages = context.messagesSlice();

    // Apply context transformation if configured (works on Message[] level)
    var transformed_messages: ?[]const ai_types.Message = null;
    defer if (transformed_messages) |tm| allocator.free(tm);

    if (config.transform_context_fn) |transform| {
        transformed_messages = try transform(config.transform_context_ctx, messages, allocator);
        messages = transformed_messages.?;
    }

    // Convert to LLM-compatible messages if configured
    var llm_messages: ?[]const ai_types.Message = null;
    defer if (llm_messages) |_| allocator.free(llm_messages.?);

    if (config.convert_to_llm_fn) |convert| {
        llm_messages = try convert(config.convert_to_llm_ctx, messages, allocator);
        messages = llm_messages.?;
    }

    // Build tools array for LLM
    var tools: ?[]ai_types.Tool = null;
    defer if (tools) |t| allocator.free(t);
    tools = try buildToolsArray(allocator, context.tools);

    // Build LLM context
    const llm_context = ai_types.Context{
        .system_prompt = ai_types.OwnedSlice(u8).initBorrowed(context.getSystemPrompt() orelse ""),
        .messages = messages,
        .tools = tools,
        .is_owned = false,
    };
    try emitContextUsage(event_stream, llm_context);

    // Build protocol options
    const options = ProtocolOptions{
        .api_key = config.api_key,
        .session_id = config.session_id,
        .cancel_token = config.cancel_token,
        .thinking_budgets = config.thinking_budgets,
        .max_retry_delay_ms = config.max_retry_delay_ms orelse 60_000,
        .temperature = config.temperature,
        .max_tokens = config.max_tokens,
    };

    // Call protocol client to stream
    const provider_stream = try config.protocol.stream(
        config.model,
        llm_context,
        options,
        allocator,
    );
    defer {
        provider_stream.deinit();
        allocator.destroy(provider_stream);
    }

    // Forward events and collect final message
    var final_message: ?ai_types.AssistantMessage = null;
    var message_started = false;

    while (provider_stream.wait()) |provider_event| {
        switch (provider_event) {
            .start => |s| {
                // Create a Message wrapper for the assistant message
                const msg: ai_types.Message = .{ .assistant = s.partial };
                try event_stream.push(.{ .message_start = .{
                    .message = msg,
                } });
                message_started = true;
            },
            .text_start => |evt| {
                try event_stream.push(.{ .message_update = .{
                    .message = evt.partial,
                    .event = provider_event,
                } });
            },
            .text_delta => |evt| {
                try event_stream.push(.{ .message_update = .{
                    .message = evt.partial,
                    .event = provider_event,
                } });
            },
            .text_end => |evt| {
                try event_stream.push(.{ .message_update = .{
                    .message = evt.partial,
                    .event = provider_event,
                } });
            },
            .thinking_start => |evt| {
                try event_stream.push(.{ .message_update = .{
                    .message = evt.partial,
                    .event = provider_event,
                } });
            },
            .thinking_delta => |evt| {
                try event_stream.push(.{ .message_update = .{
                    .message = evt.partial,
                    .event = provider_event,
                } });
            },
            .thinking_end => |evt| {
                try event_stream.push(.{ .message_update = .{
                    .message = evt.partial,
                    .event = provider_event,
                } });
            },
            .toolcall_start => |evt| {
                try event_stream.push(.{ .message_update = .{
                    .message = evt.partial,
                    .event = provider_event,
                } });
            },
            .toolcall_delta => |evt| {
                try event_stream.push(.{ .message_update = .{
                    .message = evt.partial,
                    .event = provider_event,
                } });
            },
            .toolcall_end => |evt| {
                try event_stream.push(.{ .message_update = .{
                    .message = evt.partial,
                    .event = provider_event,
                } });
            },
            .done => |d| {
                final_message = d.message;
                const msg: ai_types.Message = .{ .assistant = d.message };
                try event_stream.push(.{ .message_end = .{
                    .message = msg,
                } });
            },
            .@"error" => |e| {
                final_message = e.err;
                const msg: ai_types.Message = .{ .assistant = e.err };
                try event_stream.push(.{ .message_end = .{
                    .message = msg,
                } });
            },
            .keepalive => {
                // Ignore keepalive events
            },
        }
    }

    // Fallback for providers that don't emit .done (e.g. OpenAI Completions, Anthropic)
    if (final_message == null) {
        if (provider_stream.getResult()) |result| {
            var cloned = try ai_types.cloneAssistantMessage(allocator, result);
            errdefer cloned.deinit(allocator);
            final_message = cloned;
            const msg: ai_types.Message = .{ .assistant = final_message.? };
            try event_stream.push(.{ .message_end = .{
                .message = msg,
            } });
        }
    }

    return final_message orelse error.NoFinalMessage;
}

/// Run state for the agent loop
const LoopState = struct {
    messages: std.ArrayList(ai_types.Message),
    iterations: u32,
    final_message: ?ai_types.AssistantMessage,

    fn deinit(self: *LoopState, allocator: std.mem.Allocator) void {
        for (self.messages.items) |*msg| {
            msg.deinit(allocator);
        }
        self.messages.deinit(allocator);
        if (self.final_message) |*fm| {
            fm.deinit(allocator);
        }
    }
};

fn appendClonedStateMessage(
    messages: *std.ArrayList(ai_types.Message),
    allocator: std.mem.Allocator,
    msg: ai_types.Message,
) !void {
    var cloned = try ai_types.cloneMessage(allocator, msg);
    errdefer cloned.deinit(allocator);
    try messages.append(allocator, cloned);
}

fn setFinalMessage(state: *LoopState, allocator: std.mem.Allocator, msg: ai_types.AssistantMessage) !void {
    var cloned = try ai_types.cloneAssistantMessage(allocator, msg);
    errdefer cloned.deinit(allocator);

    if (state.final_message) |*prev| {
        prev.deinit(allocator);
    }

    state.final_message = cloned;
}

/// Run the agent loop with new prompt messages.
/// This is the internal implementation used by both agentLoop and agentLoopContinue.
fn runLoop(
    allocator: std.mem.Allocator,
    prompts: ?[]const ai_types.Message,
    context: *AgentContext,
    config: AgentLoopConfig,
    event_stream: *AgentEventStream,
) !void {
    var state = LoopState{
        .messages = std.ArrayList(ai_types.Message).empty,
        .iterations = 0,
        .final_message = null,
    };
    defer state.deinit(allocator);

    // Add initial prompts to context
    if (prompts) |initial_prompts| {
        for (initial_prompts) |prompt| {
            try context.appendMessage(prompt);

            // Emit message_start/message_end for each prompt
            try event_stream.push(.{ .message_start = .{
                .message = prompt,
            } });
            try event_stream.push(.{ .message_end = .{
                .message = prompt,
            } });

            // Track as an owned result message
            try appendClonedStateMessage(&state.messages, allocator, prompt);
        }
    }

    // Emit agent_start
    try event_stream.push(.agent_start);

    const max_iterations = config.max_iterations orelse 100;

    // Outer loop: handles follow-up messages
    outer: while (state.iterations < max_iterations) {
        // Check for cancellation
        if (config.cancel_token) |token| {
            if (token.isCancelled()) {
                break;
            }
        }

        // Inner loop: process tool calls and steering
        while (state.iterations < max_iterations) {
            // Check for steering messages
            var steering_messages: ?[]const ai_types.Message = null;
            if (config.get_steering_messages_fn) |get_steering| {
                steering_messages = try get_steering(config.get_steering_messages_ctx, allocator);
            }

            if (steering_messages) |msgs| {
                if (msgs.len > 0) {
                    // Add steering messages to context
                    for (msgs) |steering_msg| {
                        try context.appendMessage(steering_msg);
                        try event_stream.push(.{ .message_start = .{
                            .message = steering_msg,
                        } });
                        try event_stream.push(.{ .message_end = .{
                            .message = steering_msg,
                        } });
                        try appendClonedStateMessage(&state.messages, allocator, steering_msg);
                    }
                    allocator.free(msgs);
                } else {
                    allocator.free(msgs);
                }
            }

            // Emit turn_start before streaming assistant response
            try event_stream.push(.turn_start);

            // Stream assistant response
            const assistant_message = streamAssistantResponse(
                allocator,
                context,
                config,
                event_stream,
            ) catch |err| {
                // Create error message
                const error_content = [_]ai_types.AssistantContent{.{
                    .text = .{ .text = "" },
                }};
                const error_msg = ai_types.AssistantMessage{
                    .content = &error_content,
                    .api = config.model.api,
                    .provider = config.model.provider,
                    .model = config.model.id,
                    .usage = .{},
                    .stop_reason = .@"error",
                    .error_message = ai_types.OwnedSlice(u8).initBorrowed(@errorName(err)),
                    .timestamp = compat.time.nowMillis(),
                    .is_owned = false,
                };
                try setFinalMessage(&state, allocator, error_msg);
                try appendClonedStateMessage(&state.messages, allocator, .{ .assistant = error_msg });

                // Emit turn_end with error
                try event_stream.push(.{ .turn_end = .{
                    .message = error_msg,
                    .tool_results = types.OwnedSlice(ai_types.ToolResultMessage).initBorrowed(&.{}),
                } });

                break :outer;
            };

            state.iterations += 1;
            try setFinalMessage(&state, allocator, assistant_message);
            try appendClonedStateMessage(&state.messages, allocator, .{ .assistant = assistant_message });

            // Check stop_reason
            switch (assistant_message.stop_reason) {
                .@"error", .aborted => {
                    // Emit turn_end and exit
                    try event_stream.push(.{ .turn_end = .{
                        .message = assistant_message,
                        .tool_results = types.OwnedSlice(ai_types.ToolResultMessage).initBorrowed(&.{}),
                    } });
                    // NOTE: We intentionally do NOT deinit assistant_message here.
                    // AgentEventStream.push performs shallow copies, so event consumers
                    // may read message fields after this branch exits. Deiniting would
                    // cause use-after-free. The state clones (setFinalMessage/
                    // appendClonedStateMessage) own independent copies; this local copy
                    // is kept alive for the event stream lifetime.
                    break :outer;
                },
                .stop, .length, .content_filter => {
                    // Emit turn_end, check follow-up messages
                    try event_stream.push(.{ .turn_end = .{
                        .message = assistant_message,
                        .tool_results = types.OwnedSlice(ai_types.ToolResultMessage).initBorrowed(&.{}),
                    } });

                    // Add assistant message to context
                    try context.appendMessage(.{ .assistant = assistant_message });

                    // Check for follow-up messages
                    if (config.get_follow_up_messages_fn) |get_follow_up| {
                        if (try get_follow_up(config.get_follow_up_messages_ctx, allocator)) |follow_ups| {
                            if (follow_ups.len > 0) {
                                // Add follow-up messages and continue outer loop
                                for (follow_ups) |follow_up| {
                                    try context.appendMessage(follow_up);
                                    try event_stream.push(.{ .message_start = .{
                                        .message = follow_up,
                                    } });
                                    try event_stream.push(.{ .message_end = .{
                                        .message = follow_up,
                                    } });
                                    try appendClonedStateMessage(&state.messages, allocator, follow_up);
                                }
                                allocator.free(follow_ups);
                                continue :outer;
                            }
                            allocator.free(follow_ups);
                        }
                    }

                    // No follow-up messages, we're done
                    break :outer;
                },
                .tool_use => {
                    // Execute tools
                    const tool_result = try executeToolCalls(
                        allocator,
                        assistant_message,
                        config,
                        event_stream,
                    );
                    defer {
                        // Tool results ownership is transferred to context
                        allocator.free(tool_result.tool_results);
                        if (tool_result.steering_messages) |msgs| {
                            const mut_msgs: []ai_types.Message = @constCast(msgs);
                            for (mut_msgs) |*msg| msg.deinit(allocator);
                            allocator.free(mut_msgs);
                        }
                    }

                    // Emit turn_end with tool results
                    try event_stream.push(.{ .turn_end = .{
                        .message = assistant_message,
                        .tool_results = types.OwnedSlice(ai_types.ToolResultMessage).initBorrowed(tool_result.tool_results),
                    } });

                    // Add assistant message to context
                    try context.appendMessage(.{ .assistant = assistant_message });

                    // Add tool results to context with message_start/end events
                    for (tool_result.tool_results) |tool_result_msg| {
                        const msg: ai_types.Message = .{ .tool_result = tool_result_msg };
                        try event_stream.push(.{ .message_start = .{
                            .message = msg,
                        } });
                        try context.appendMessage(msg);
                        try event_stream.push(.{ .message_end = .{
                            .message = msg,
                        } });
                        try appendClonedStateMessage(&state.messages, allocator, msg);
                    }

                    // If steering messages arrived, they'll be picked up at the top of inner loop
                    // Continue inner loop to get next assistant response
                },
            }
        }
    }

    // Build result and transfer ownership out of local loop state.
    const result_messages = try state.messages.toOwnedSlice(allocator);

    const result_final_message: ai_types.AssistantMessage = if (state.final_message) |fm| blk: {
        state.final_message = null;
        break :blk fm;
    } else blk: {
        break :blk .{
            .content = try allocator.alloc(ai_types.AssistantContent, 0),
            .api = config.model.api,
            .provider = config.model.provider,
            .model = config.model.id,
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = compat.time.nowMillis(),
            .is_owned = false,
        };
    };

    const result = AgentLoopResult{
        .messages = owned_slice_mod.OwnedSlice(ai_types.Message).initOwned(result_messages),
        .final_message = result_final_message,
        .iterations = state.iterations,
    };

    // Emit agent_end
    try event_stream.push(.{
        .agent_end = .{
            .messages = types.OwnedSlice(ai_types.Message).initBorrowed(result.messages.slice()), // Ownership retained by result
        },
    });

    // Complete the stream
    event_stream.complete(result);
}

/// Thread context for background agent loop execution.
///
/// Lifetime requirements on the caller:
/// - `prompts` and the strings inside each Message must stay alive until the
///   stream completes (they are shallow-copied into context.messages).
/// - `config.model` string fields must stay alive until the stream completes.
/// - `config.tools` slice and the string fields inside each AgentTool must stay
///   alive until the stream completes.
/// - All `config.*_ctx` callback context pointers must stay valid until the
///   stream completes.
/// - `api_key` and `session_id` are cloned into owned memory by agentLoop and
///   freed automatically by the background thread; the caller may free its
///   copies immediately after the call returns.
const RunLoopThreadCtx = struct {
    allocator: std.mem.Allocator,
    prompts: ?[]const ai_types.Message,
    context: *AgentContext,
    config: AgentLoopConfig,
    stream: *AgentEventStream,
    owned_api_key: ?[]u8 = null,
    owned_session_id: ?[]u8 = null,
};

/// Background thread entry point for the agent loop.
fn runLoopThread(ctx: *RunLoopThreadCtx) void {
    const allocator = ctx.allocator;
    const stream = ctx.stream;

    runLoop(allocator, ctx.prompts, ctx.context, ctx.config, stream) catch |err| {
        stream.completeWithError(@errorName(err));
    };

    if (ctx.owned_api_key) |key| allocator.free(key);
    if (ctx.owned_session_id) |sid| allocator.free(sid);

    allocator.destroy(ctx);
    stream.markThreadDone();
}

/// Clone config string fields that are commonly borrowed by callers.
fn cloneConfigStrings(
    allocator: std.mem.Allocator,
    config: AgentLoopConfig,
    out_owned_api_key: *?[]u8,
    out_owned_session_id: *?[]u8,
) !AgentLoopConfig {
    var cloned = config;
    if (config.api_key) |key| {
        out_owned_api_key.* = try allocator.dupe(u8, key);
        cloned.api_key = out_owned_api_key.*;
    }
    if (config.session_id) |sid| {
        out_owned_session_id.* = try allocator.dupe(u8, sid);
        cloned.session_id = out_owned_session_id.*;
    }
    return cloned;
}

/// Start an agent loop with new prompt messages.
/// Returns an event stream that emits events during execution.
/// Caller owns the returned stream and must call deinit().
///
/// Lifetime: the caller must keep `prompts` and all borrowed fields inside
/// `config` alive until the stream completes. Specifically:
/// - `prompts` messages (shallow-copied into context)
/// - `config.model` strings
/// - `config.tools` slice and tool string fields
/// - `config.*_ctx` callback context pointers
/// `api_key` and `session_id` are cloned internally and may be freed by the
/// caller immediately after this call returns.
pub fn agentLoop(
    allocator: std.mem.Allocator,
    prompts: []const ai_types.Message,
    context: *AgentContext,
    config: AgentLoopConfig,
) !*AgentEventStream {
    var owned_api_key: ?[]u8 = null;
    var owned_session_id: ?[]u8 = null;
    const thread_config = cloneConfigStrings(allocator, config, &owned_api_key, &owned_session_id) catch |err| {
        if (owned_api_key) |key| allocator.free(key);
        return err;
    };
    errdefer {
        if (owned_api_key) |key| allocator.free(key);
        if (owned_session_id) |sid| allocator.free(sid);
    }

    const stream = try allocator.create(AgentEventStream);
    errdefer allocator.destroy(stream);
    stream.* = AgentEventStream.init(allocator);
    stream.wait_for_thread_on_deinit = true;

    const ctx = try allocator.create(RunLoopThreadCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .prompts = prompts,
        .context = context,
        .config = thread_config,
        .stream = stream,
        .owned_api_key = owned_api_key,
        .owned_session_id = owned_session_id,
    };

    const th = try std.Thread.spawn(.{}, runLoopThread, .{ctx});
    th.detach();

    return stream;
}

/// Continue an agent loop from the current context without adding new messages.
/// Used for retries - context already has user message or tool results.
///
/// Lifetime: same borrowed-field rules as agentLoop apply.
pub fn agentLoopContinue(
    allocator: std.mem.Allocator,
    context: *AgentContext,
    config: AgentLoopConfig,
) !*AgentEventStream {
    var owned_api_key: ?[]u8 = null;
    var owned_session_id: ?[]u8 = null;
    const thread_config = cloneConfigStrings(allocator, config, &owned_api_key, &owned_session_id) catch |err| {
        if (owned_api_key) |key| allocator.free(key);
        return err;
    };
    errdefer {
        if (owned_api_key) |key| allocator.free(key);
        if (owned_session_id) |sid| allocator.free(sid);
    }

    const stream = try allocator.create(AgentEventStream);
    errdefer allocator.destroy(stream);
    stream.* = AgentEventStream.init(allocator);
    stream.wait_for_thread_on_deinit = true;

    const ctx = try allocator.create(RunLoopThreadCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .prompts = null,
        .context = context,
        .config = thread_config,
        .stream = stream,
        .owned_api_key = owned_api_key,
        .owned_session_id = owned_session_id,
    };

    const th = try std.Thread.spawn(.{}, runLoopThread, .{ctx});
    th.detach();

    return stream;
}

// ============================================================================
// Tests
// ============================================================================

test "findTool finds tool by name" {
    const tools = [_]AgentTool{
        .{
            .label = "Tool A",
            .name = "tool_a",
            .description = "First tool",
            .parameters_schema_json = "{}",
            .execute = undefined,
        },
        .{
            .label = "Tool B",
            .name = "tool_b",
            .description = "Second tool",
            .parameters_schema_json = "{}",
            .execute = undefined,
        },
    };

    const found = findTool(&tools, "tool_b");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("tool_b", found.?.name);

    const not_found = findTool(&tools, "tool_c");
    try std.testing.expect(not_found == null);
}

test "buildToolsArray creates correct array" {
    const tools = [_]AgentTool{
        .{
            .label = "Test",
            .name = "test_tool",
            .description = "A test tool",
            .parameters_schema_json = "{\"type\": \"object\"}",
            .execute = undefined,
        },
    };

    const result = try buildToolsArray(std.testing.allocator, &tools);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);

    try std.testing.expectEqual(@as(usize, 1), result.?.len);
    try std.testing.expectEqualStrings("test_tool", result.?[0].name);
}

test "buildToolsArray returns null for empty tools" {
    const result = try buildToolsArray(std.testing.allocator, null);
    try std.testing.expect(result == null);
}

test "createErrorResult creates valid result" {
    const result = try createErrorResult(std.testing.allocator, error.TestError);
    defer {
        var mut_result = result;
        mut_result.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), result.content.slice().len);
    try std.testing.expect(result.content.slice()[0] == .text);
}

fn mockContextUsageStream(
    ctx: ?*anyopaque,
    model: ai_types.Model,
    context: ai_types.Context,
    options: ProtocolOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream_module.AssistantMessageEventStream {
    _ = ctx;
    _ = model;
    _ = context;
    _ = options;

    const stream = try allocator.create(event_stream_module.AssistantMessageEventStream);
    stream.* = event_stream_module.AssistantMessageEventStream.init(allocator);

    const content = try allocator.alloc(ai_types.AssistantContent, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "ok") } };
    stream.complete(.{
        .content = content,
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    });

    return stream;
}

test "streamAssistantResponse emits context and prompt segment usage" {
    const allocator = std.testing.allocator;

    var context = AgentContext.init(allocator);
    defer context.deinit();
    context.system_prompt = types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "stable system prompt"));

    const user_text = try allocator.dupe(u8, "dynamic user prompt");
    try context.appendMessage(.{ .user = .{
        .content = .{ .text = user_text },
        .timestamp = 0,
    } });

    const tools = [_]AgentTool{.{
        .label = "Search",
        .name = "search",
        .description = "Search indexed artifacts",
        .parameters_schema_json = "{\"type\":\"object\"}",
        .execute = undefined,
    }};
    context.tools = &tools;

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test",
        .api = "test-api",
        .provider = "test-provider",
        .base_url = "",
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 256,
    };

    var agent_events = AgentEventStream.init(allocator);
    defer agent_events.deinit();

    var final = try streamAssistantResponse(
        allocator,
        &context,
        .{
            .model = model,
            .protocol = .{ .stream_fn = mockContextUsageStream },
        },
        &agent_events,
    );
    defer final.deinit(allocator);

    var saw_context_usage = false;
    var segment_count: usize = 0;
    while (agent_events.poll()) |evt| {
        switch (evt) {
            .context_usage => |usage| {
                saw_context_usage = true;
                try std.testing.expectEqual(@as(u32, 1), usage.message_count);
                try std.testing.expectEqual(@as(u32, 1), usage.tool_count);
                try std.testing.expect(usage.system_prompt_bytes > 0);
                try std.testing.expect(usage.message_bytes > 0);
                try std.testing.expect(usage.tool_definition_bytes > 0);
                try std.testing.expect(usage.estimated_tokens > 0);
            },
            .prompt_segment_usage => |segment| {
                segment_count += 1;
                if (segment.segment == .system_prompt or segment.segment == .tool_definitions) {
                    try std.testing.expectEqual(types.PromptSegmentCacheRole.stable, segment.cache_role);
                }
                if (segment.segment == .message_history) {
                    try std.testing.expectEqual(types.PromptSegmentCacheRole.dynamic, segment.cache_role);
                }
            },
            else => {},
        }
    }

    try std.testing.expect(saw_context_usage);
    try std.testing.expectEqual(@as(usize, 3), segment_count);
}

const MockProtocolToolContext = struct {
    call_count: usize = 0,
    saw_update: bool = false,
};

fn mockProtocolExecute(
    ctx: ?*anyopaque,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?types.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!AgentToolResult {
    _ = args_json;
    _ = cancel_token;
    const protocol_ctx: *MockProtocolToolContext = @ptrCast(@alignCast(ctx.?));
    protocol_ctx.call_count += 1;

    if (on_update) |update| {
        update(on_update_ctx, tool_call_id, tool_name, "{\"status\":\"running\"}");
        protocol_ctx.saw_update = true;
    }

    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    content[0] = .{ .text = .{
        .text = try allocator.dupe(u8, "executed via protocol"),
    } };
    return .{
        .content = types.OwnedSlice(ai_types.UserContentPart).initOwned(content),
        .details_json = types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "{\"source\":\"protocol\"}")),
    };
}

fn mockProtocolExecuteCancelled(
    ctx: ?*anyopaque,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?types.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!AgentToolResult {
    _ = ctx;
    _ = tool_call_id;
    _ = tool_name;
    _ = args_json;
    _ = on_update_ctx;
    _ = on_update;
    _ = allocator;
    if (cancel_token) |token| {
        if (token.isCancelled()) return error.Cancelled;
    }
    return error.Cancelled;
}

fn mockLargeOutputTool(
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?types.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!AgentToolResult {
    _ = tool_call_id;
    _ = args_json;
    _ = cancel_token;
    _ = on_update_ctx;
    _ = on_update;

    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    content[0] = .{ .text = .{
        .text = try allocator.dupe(u8, "raw log line 1\nraw log line 2\nraw log line 3"),
    } };
    return .{
        .content = types.OwnedSlice(ai_types.UserContentPart).initOwned(content),
        .details_json = types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "{\"raw\":true,\"lines\":3}")),
    };
}

const MiddlewareRecorder = struct {
    raw_total_bytes: u64 = 0,
    call_count: usize = 0,
};

fn compactToolOutputMiddleware(
    ctx: ?*anyopaque,
    input: types.ToolOutputMiddlewareInput,
    result: *AgentToolResult,
    allocator: std.mem.Allocator,
) anyerror!void {
    const recorder: *MiddlewareRecorder = @ptrCast(@alignCast(ctx.?));
    recorder.raw_total_bytes = input.raw_total_bytes;
    recorder.call_count += 1;

    result.content.deinit(allocator);
    result.details_json.deinit(allocator);

    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    content[0] = .{ .text = .{
        .text = try allocator.dupe(u8, "3 raw log lines stored as artifact"),
    } };

    const artifacts = try allocator.alloc(ai_types.ArtifactReference, 1);
    artifacts[0] = .{
        .artifact_id = try allocator.dupe(u8, "artifact-log-1"),
        .uri = types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "makai-artifact://artifact-log-1")),
        .mime_type = types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "text/plain")),
        .byte_size = input.raw_total_bytes,
        .description = types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "raw tool output")),
    };

    result.* = .{
        .content = types.OwnedSlice(ai_types.UserContentPart).initOwned(content),
        .details_json = types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "{\"summary\":true}")),
        .artifacts = types.OwnedSlice(ai_types.ArtifactReference).initOwned(artifacts),
    };
}

test "executeToolCalls uses protocol executor when configured" {
    const allocator = std.testing.allocator;

    const tools = [_]AgentTool{
        .{
            .label = "Remote Tool",
            .name = "remote_tool",
            .description = "Remote tool",
            .parameters_schema_json = "{}",
            .execute = undefined,
        },
    };

    const assistant_content = [_]ai_types.AssistantContent{
        .{ .tool_call = .{
            .id = "call_1",
            .name = "remote_tool",
            .arguments_json = "{\"q\":\"x\"}",
        } },
    };
    const assistant_message = ai_types.AssistantMessage{
        .content = &assistant_content,
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .tool_use,
        .timestamp = 0,
    };

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test",
        .api = "test-api",
        .provider = "test-provider",
        .base_url = "",
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 256,
    };

    var protocol_ctx = MockProtocolToolContext{};
    var agent_events = AgentEventStream.init(allocator);
    defer agent_events.deinit();

    var tool_result = try executeToolCalls(
        allocator,
        assistant_message,
        .{
            .model = model,
            .protocol = .{ .stream_fn = undefined },
            .tools = &tools,
            .execute_tool_via_protocol_fn = mockProtocolExecute,
            .execute_tool_via_protocol_ctx = &protocol_ctx,
        },
        &agent_events,
    );
    defer tool_result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), protocol_ctx.call_count);
    try std.testing.expectEqual(@as(usize, 1), tool_result.tool_results.len);
    try std.testing.expect(!tool_result.tool_results[0].is_error);
    try std.testing.expectEqualStrings("executed via protocol", tool_result.tool_results[0].content[0].text.text);

    var saw_update = false;
    while (agent_events.poll()) |evt| {
        if (evt == .tool_execution_update) saw_update = true;
    }
    try std.testing.expect(protocol_ctx.saw_update);
    try std.testing.expect(saw_update);
}

test "executeToolCalls applies output middleware and reports byte telemetry" {
    const allocator = std.testing.allocator;

    const tools = [_]AgentTool{
        .{
            .label = "Logs",
            .name = "logs",
            .description = "Collect logs",
            .parameters_schema_json = "{}",
            .execute = mockLargeOutputTool,
        },
    };

    const assistant_content = [_]ai_types.AssistantContent{
        .{ .tool_call = .{
            .id = "call_logs",
            .name = "logs",
            .arguments_json = "{\"path\":\"server.log\"}",
        } },
    };
    const assistant_message = ai_types.AssistantMessage{
        .content = &assistant_content,
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .tool_use,
        .timestamp = 0,
    };

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test",
        .api = "test-api",
        .provider = "test-provider",
        .base_url = "",
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 256,
    };

    var recorder = MiddlewareRecorder{};
    var agent_events = AgentEventStream.init(allocator);
    defer agent_events.deinit();

    var tool_result = try executeToolCalls(
        allocator,
        assistant_message,
        .{
            .model = model,
            .protocol = .{ .stream_fn = undefined },
            .tools = &tools,
            .tool_output_middleware_fn = compactToolOutputMiddleware,
            .tool_output_middleware_ctx = &recorder,
        },
        &agent_events,
    );
    defer tool_result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), recorder.call_count);
    try std.testing.expect(recorder.raw_total_bytes > 0);
    try std.testing.expectEqual(@as(usize, 1), tool_result.tool_results.len);
    try std.testing.expectEqualStrings("3 raw log lines stored as artifact", tool_result.tool_results[0].content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), tool_result.tool_results[0].artifacts.slice().len);
    try std.testing.expectEqualStrings("artifact-log-1", tool_result.tool_results[0].artifacts.slice()[0].artifact_id);

    var saw_end = false;
    while (agent_events.poll()) |evt| {
        if (evt == .tool_execution_end) {
            saw_end = true;
            try std.testing.expect(evt.tool_execution_end.raw_total_bytes > evt.tool_execution_end.returned_total_bytes);
            try std.testing.expectEqual(@as(u32, 1), evt.tool_execution_end.artifact_count);
            try std.testing.expectEqual(@as(usize, 1), evt.tool_execution_end.artifacts.len);
            try std.testing.expectEqualStrings("artifact-log-1", evt.tool_execution_end.artifacts[0].artifact_id);
        }
    }
    try std.testing.expect(saw_end);
}

test "executeToolCalls emits terminal events on protocol cancellation" {
    const allocator = std.testing.allocator;

    const tools = [_]AgentTool{
        .{
            .label = "Remote Tool",
            .name = "remote_tool",
            .description = "Remote tool",
            .parameters_schema_json = "{}",
            .execute = undefined,
        },
    };

    const assistant_content = [_]ai_types.AssistantContent{
        .{ .tool_call = .{
            .id = "call_2",
            .name = "remote_tool",
            .arguments_json = "{\"q\":\"x\"}",
        } },
    };
    const assistant_message = ai_types.AssistantMessage{
        .content = &assistant_content,
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .tool_use,
        .timestamp = 0,
    };

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test",
        .api = "test-api",
        .provider = "test-provider",
        .base_url = "",
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 256,
    };

    var cancelled = std.atomic.Value(bool).init(true);
    const cancel_token = ai_types.CancelToken{ .cancelled = &cancelled };

    var agent_events = AgentEventStream.init(allocator);
    defer agent_events.deinit();

    var tool_result = try executeToolCalls(
        allocator,
        assistant_message,
        .{
            .model = model,
            .protocol = .{ .stream_fn = undefined },
            .tools = &tools,
            .cancel_token = cancel_token,
            .execute_tool_via_protocol_fn = mockProtocolExecuteCancelled,
        },
        &agent_events,
    );
    defer tool_result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), tool_result.tool_results.len);
    try std.testing.expect(tool_result.tool_results[0].is_error);

    var start_count: usize = 0;
    var end_count: usize = 0;
    while (agent_events.poll()) |evt| {
        switch (evt) {
            .tool_execution_start => start_count += 1,
            .tool_execution_end => end_count += 1,
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 1), start_count);
    try std.testing.expectEqual(@as(usize, 1), end_count);
}
