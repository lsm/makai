const std = @import("std");
const ai_types = @import("ai_types");
const event_stream_module = @import("event_stream");
const api_registry = @import("api_registry");
const types = @import("types.zig");

// Re-export types needed by callers
pub const AgentEvent = types.AgentEvent;
pub const AgentEventStream = types.AgentEventStream;
pub const AgentLoopConfig = types.AgentLoopConfig;
pub const AgentLoopResult = types.AgentLoopResult;
pub const AgentContext = types.AgentContext;
pub const AgentTool = types.AgentTool;
pub const AgentToolResult = types.AgentToolResult;

/// Resolve the stream function from config.
/// Priority: explicit stream_fn > registry lookup
fn getStreamFn(config: AgentLoopConfig) !types.AgentStreamFn {
    // Explicit stream_fn takes precedence
    if (config.stream_fn) |fn_ptr| return fn_ptr;

    // Fall back to registry lookup
    if (config.registry) |registry| {
        const provider = registry.getApiProvider(config.model.api) orelse return error.ProviderNotFound;
        return provider.stream_simple;
    }

    return error.NoStreamFunction;
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

/// Create an error result for failed tool execution
fn createErrorResult(allocator: std.mem.Allocator, err: anyerror) !AgentToolResult {
    const error_name = @errorName(err);
    _ = error_name; // We could include this in the error message
    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    content[0] = .{ .text = .{
        .text = try allocator.dupe(u8, "Tool execution failed"),
    } };
    return .{
        .content = content,
        .details_json = null,
        .owned_strings = true,
    };
}

/// Create a tool result message from execution result
fn createToolResultMessage(
    allocator: std.mem.Allocator,
    tool_call: ai_types.ToolCall,
    result: AgentToolResult,
    is_error: bool,
) !ai_types.ToolResultMessage {
    return .{
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
        .tool_name = try allocator.dupe(u8, tool_call.name),
        .content = result.content,
        .details_json = result.details_json,
        .is_error = is_error,
        .timestamp = std.time.milliTimestamp(),
    };
}

/// Callback context for tool updates
const ToolUpdateContext = struct {
    event_stream: *AgentEventStream,
    tool_call_id: []const u8,
    tool_name: []const u8,
};

/// Tool update callback implementation
fn onToolUpdate(ctx: ?*anyopaque, tool_call_id: []const u8, tool_name: []const u8, partial_result_json: []const u8) void {
    _ = ctx;
    _ = tool_call_id;
    _ = tool_name;
    _ = partial_result_json;
    // Note: In a full implementation, we would push a tool_execution_update event here.
    // For now, this is a placeholder as streaming tool updates are optional.
}

/// Result from tool execution phase
const ToolExecutionResult = struct {
    tool_results: []ai_types.ToolResultMessage,
    has_steering: bool,
    steering_messages: ?[]ai_types.Message,

    fn deinit(self: *ToolExecutionResult, allocator: std.mem.Allocator) void {
        for (self.tool_results) |*result| {
            result.deinit(allocator);
        }
        allocator.free(self.tool_results);
        if (self.steering_messages) |msgs| {
            const mut_msgs: []ai_types.Message = @constCast(msgs);
            for (mut_msgs) |*msg| msg.deinit(allocator);
            allocator.free(mut_msgs);
        }
    }
};

/// Execute tool calls from assistant message
fn executeToolCalls(
    allocator: std.mem.Allocator,
    assistant_message: ai_types.AssistantMessage,
    config: AgentLoopConfig,
    event_stream: *AgentEventStream,
) !ToolExecutionResult {
    // Extract tool calls from assistant message
    var tool_calls: std.ArrayList(ai_types.ToolCall) = .{};
    defer tool_calls.deinit(allocator);

    for (assistant_message.content) |block| {
        if (block == .tool_call) {
            try tool_calls.append(allocator, block.tool_call);
        }
    }

    var results: std.ArrayList(ai_types.ToolResultMessage) = .{};
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
        } });

        var result: AgentToolResult = undefined;
        var is_error = false;

        if (tool) |t| {
            result = t.execute(
                tool_call.id,
                tool_call.arguments_json,
                config.cancel_token,
                event_stream,
                onToolUpdate,
                allocator,
            ) catch |err| {
                result = try createErrorResult(allocator, err);
                is_error = true;
            };
        } else {
            result = try createErrorResult(allocator, error.ToolNotFound);
            is_error = true;
        }

        // Build result JSON for event
        const result_json = result.details_json orelse "null";

        // Emit end event
        try event_stream.push(.{ .tool_execution_end = .{
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .result_json = result_json,
            .is_error = is_error,
        } });

        // Create tool result message
        const tool_result_msg = try createToolResultMessage(allocator, tool_call, result, is_error);
        try results.append(allocator, tool_result_msg);

        // Check for steering messages - skip remaining tools if any
        if (config.get_steering_messages_fn) |get_steering| {
            if (try get_steering(config.get_steering_messages_ctx, allocator)) |msgs| {
                if (msgs.len > 0) {
                    steering_messages = msgs;
                    has_steering = true;
                    // Skip remaining tools - steering message takes priority
                    break;
                } else {
                    allocator.free(msgs);
                }
            }
        }
    }

    return .{
        .tool_results = try results.toOwnedSlice(allocator),
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
    // Resolve stream function (custom or from registry)
    const stream_fn = try getStreamFn(config);

    // Build tools array for LLM
    var tools: ?[]ai_types.Tool = null;
    defer if (tools) |t| allocator.free(t);
    tools = try buildToolsArray(allocator, context.tools);

    // Build LLM context
    const llm_context = ai_types.Context{
        .system_prompt = context.system_prompt,
        .messages = context.messagesSlice(),
        .tools = tools,
        .owned_strings = false,
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

    // Emit turn_start
    try event_stream.push(.turn_start);

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
                    .owned_strings = false,
                } });
                message_started = true;
            },
            .text_start, .text_delta, .text_end, .thinking_start, .thinking_delta, .thinking_end, .toolcall_start, .toolcall_delta, .toolcall_end => |evt| {
                // Forward as message_update
                const partial_msg = switch (provider_event) {
                    .text_start => evt.partial,
                    .text_delta => evt.partial,
                    .text_end => evt.partial,
                    .thinking_start => evt.partial,
                    .thinking_delta => evt.partial,
                    .thinking_end => evt.partial,
                    .toolcall_start => evt.partial,
                    .toolcall_delta => evt.partial,
                    .toolcall_end => evt.partial,
                    else => unreachable,
                };
                try event_stream.push(.{ .message_update = .{
                    .message = partial_msg,
                    .event = provider_event,
                } });
            },
            .done => |d| {
                final_message = d.message;
                const msg: ai_types.Message = .{ .assistant = d.message };
                try event_stream.push(.{ .message_end = .{
                    .message = msg,
                    .owned_strings = false,
                } });
            },
            .@"error" => |e| {
                final_message = e.err;
                const msg: ai_types.Message = .{ .assistant = e.err };
                try event_stream.push(.{ .message_end = .{
                    .message = msg,
                    .owned_strings = false,
                } });
            },
            .keepalive => {
                // Ignore keepalive events
            },
        }
    }

    // Return final message (required to be set by done/error)
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
        .messages = .{},
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
                .owned_strings = false,
            } });
            try event_stream.push(.{ .message_end = .{
                .message = prompt,
                .owned_strings = false,
            } });
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
            var steering_messages: ?[]ai_types.Message = null;
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
                            .owned_strings = false,
                        } });
                        try event_stream.push(.{ .message_end = .{
                            .message = steering_msg,
                            .owned_strings = false,
                        } });
                    }
                    allocator.free(msgs);
                } else {
                    allocator.free(msgs);
                }
            }

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
                    .error_message = @errorName(err),
                    .timestamp = std.time.milliTimestamp(),
                    .owned_strings = false,
                };
                state.final_message = error_msg;

                // Emit turn_end with error
                try event_stream.push(.{ .turn_end = .{
                    .message = error_msg,
                    .tool_results = &.{},
                    .owned_strings = false,
                } });

                break :outer;
            };

            state.iterations += 1;
            state.final_message = assistant_message;

            // Check stop_reason
            switch (assistant_message.stop_reason) {
                .@"error", .aborted => {
                    // Emit turn_end and exit
                    try event_stream.push(.{ .turn_end = .{
                        .message = assistant_message,
                        .tool_results = &.{},
                        .owned_strings = false,
                    } });
                    break :outer;
                },
                .stop, .length, .content_filter => {
                    // Emit turn_end, check follow-up messages
                    try event_stream.push(.{ .turn_end = .{
                        .message = assistant_message,
                        .tool_results = &.{},
                        .owned_strings = false,
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
                                        .owned_strings = false,
                                    } });
                                    try event_stream.push(.{ .message_end = .{
                                        .message = follow_up,
                                        .owned_strings = false,
                                    } });
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
                        .tool_results = tool_result.tool_results,
                        .owned_strings = false,
                    } });

                    // Add assistant message to context
                    try context.appendMessage(.{ .assistant = assistant_message });

                    // Add tool results to context
                    for (tool_result.tool_results) |tool_result_msg| {
                        try context.appendMessage(.{ .tool_result = tool_result_msg });
                    }

                    // If steering messages arrived, they'll be picked up at the top of inner loop
                    // Continue inner loop to get next assistant response
                },
            }
        }
    }

    // Build result
    const result = AgentLoopResult{
        .messages = try state.messages.toOwnedSlice(allocator),
        .final_message = state.final_message orelse .{
            .content = &.{},
            .api = config.model.api,
            .provider = config.model.provider,
            .model = config.model.id,
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = std.time.milliTimestamp(),
            .owned_strings = false,
        },
        .iterations = state.iterations,
        .owned_strings = true,
    };

    // Emit agent_end
    try event_stream.push(.{ .agent_end = .{
        .messages = result.messages,
        .owned_strings = false, // Ownership transferred to result
    } });

    // Complete the stream
    event_stream.complete(result);
}

/// Start an agent loop with new prompt messages.
/// Returns an event stream that emits events during execution.
/// Caller owns the returned stream and must call deinit().
pub fn agentLoop(
    allocator: std.mem.Allocator,
    prompts: []const ai_types.Message,
    context: *AgentContext,
    config: AgentLoopConfig,
) !*AgentEventStream {
    const stream = try allocator.create(AgentEventStream);
    stream.* = AgentEventStream.init(allocator);

    // Run the loop (in a real implementation, this would be async/threaded)
    try runLoop(allocator, prompts, context, config, stream);

    return stream;
}

/// Continue an agent loop from the current context without adding new messages.
/// Used for retries - context already has user message or tool results.
pub fn agentLoopContinue(
    allocator: std.mem.Allocator,
    context: *AgentContext,
    config: AgentLoopConfig,
) !*AgentEventStream {
    const stream = try allocator.create(AgentEventStream);
    stream.* = AgentEventStream.init(allocator);

    // Run the loop without initial prompts
    try runLoop(allocator, null, context, config, stream);

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

    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(result.content[0] == .text);
}

// Note: Full integration tests would require a mock provider
// which is beyond the scope of this unit test file
