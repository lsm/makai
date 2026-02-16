const std = @import("std");
const event_stream = @import("event_stream");

pub const KnownApi = enum {
    openai_completions,
    openai_responses,
    azure_openai_responses,
    openai_codex_responses,
    anthropic_messages,
    google_generative_ai,
    google_gemini_cli,
    ollama,
};

pub const ThinkingLevel = enum { minimal, low, medium, high, xhigh };

pub const ThinkingBudgets = struct {
    minimal: ?u32 = null,
    low: ?u32 = null,
    medium: ?u32 = null,
    high: ?u32 = null,
};

pub const CacheRetention = enum { none, short, long };

pub const StopReason = enum {
    stop,
    length,
    tool_use,
    @"error",
    aborted,
};

pub const HeaderPair = struct {
    name: []const u8,
    value: []const u8,
};

pub const RetryConfig = struct {
    max_retry_delay_ms: ?u32 = 60_000,
};

pub const CancelToken = struct {
    cancelled: *std.atomic.Value(bool),

    pub fn isCancelled(self: CancelToken) bool {
        return self.cancelled.load(.acquire);
    }
};

pub const StreamOptions = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    api_key: ?[]const u8 = null,
    cache_retention: ?CacheRetention = null,
    session_id: ?[]const u8 = null,
    headers: ?[]const HeaderPair = null,
    retry: RetryConfig = .{},
    cancel_token: ?CancelToken = null,
    on_payload_fn: ?*const fn (ctx: ?*anyopaque, payload_json: []const u8) void = null,
    on_payload_ctx: ?*anyopaque = null,
    /// Enable extended thinking. For Opus 4.6+: uses adaptive thinking.
    /// For older models: uses budget-based thinking with thinking_budget_tokens.
    thinking_enabled: bool = false,
    /// Token budget for extended thinking (older models only).
    thinking_budget_tokens: ?u32 = null,
    /// Effort level for adaptive thinking (Opus 4.6+ only). Values: "low", "medium", "high", "max".
    thinking_effort: ?[]const u8 = null,
    /// Reasoning effort level for OpenAI-compatible endpoints. Values: "minimal", "low", "medium", "high", "xhigh".
    reasoning_effort: ?[]const u8 = null,
};

pub const SimpleStreamOptions = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    api_key: ?[]const u8 = null,
    cache_retention: ?CacheRetention = null,
    session_id: ?[]const u8 = null,
    headers: ?[]const HeaderPair = null,
    retry: RetryConfig = .{},
    cancel_token: ?CancelToken = null,
    on_payload_fn: ?*const fn (ctx: ?*anyopaque, payload_json: []const u8) void = null,
    on_payload_ctx: ?*anyopaque = null,
    reasoning: ?ThinkingLevel = null,
    thinking_budgets: ?ThinkingBudgets = null,
};

pub const TextContent = struct {
    text: []const u8,
    text_signature: ?[]const u8 = null,
};

pub const ThinkingContent = struct {
    thinking: []const u8,
    thinking_signature: ?[]const u8 = null,
};

pub const ImageContent = struct {
    data: []const u8,
    mime_type: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
    thought_signature: ?[]const u8 = null,
};

pub const AssistantContent = union(enum) {
    text: TextContent,
    thinking: ThinkingContent,
    tool_call: ToolCall,
};

pub const UserContentPart = union(enum) {
    text: TextContent,
    image: ImageContent,
};

pub const UserContent = union(enum) {
    text: []const u8,
    parts: []const UserContentPart,
};

pub const UsageCost = struct {
    input: f64 = 0,
    output: f64 = 0,
    cache_read: f64 = 0,
    cache_write: f64 = 0,
    total: f64 = 0,
};

pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    total_tokens: u64 = 0,
    cost: UsageCost = .{},
};

pub const UserMessage = struct {
    content: UserContent,
    timestamp: i64,
};

pub const AssistantMessage = struct {
    content: []const AssistantContent,
    api: []const u8,
    provider: []const u8,
    model: []const u8,
    usage: Usage,
    stop_reason: StopReason,
    error_message: ?[]const u8 = null,
    timestamp: i64,

    pub fn deinit(self: *AssistantMessage, allocator: std.mem.Allocator) void {
        for (self.content) |block| {
            switch (block) {
                .text => |t| {
                    allocator.free(t.text);
                    if (t.text_signature) |s| allocator.free(s);
                },
                .thinking => |t| {
                    allocator.free(t.thinking);
                    if (t.thinking_signature) |s| allocator.free(s);
                },
                .tool_call => |tc| {
                    allocator.free(tc.id);
                    allocator.free(tc.name);
                    allocator.free(tc.arguments_json);
                    if (tc.thought_signature) |s| allocator.free(s);
                },
            }
        }
        allocator.free(self.content);
        allocator.free(self.api);
        allocator.free(self.provider);
        allocator.free(self.model);
        if (self.error_message) |e| allocator.free(e);
    }
};

pub const ToolResultMessage = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    content: []const UserContentPart,
    details_json: ?[]const u8 = null,
    is_error: bool,
    timestamp: i64,
};

pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters_schema_json: []const u8,
};

pub const Context = struct {
    system_prompt: ?[]const u8 = null,
    messages: []const Message,
    tools: ?[]const Tool = null,
};

pub const Cost = struct {
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
};

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    api: []const u8,
    provider: []const u8,
    base_url: []const u8,
    reasoning: bool,
    input: []const []const u8,
    cost: Cost,
    context_window: u32,
    max_tokens: u32,
    headers: ?[]const HeaderPair = null,
};

pub const AssistantMessageEvent = union(enum) {
    start: struct { partial: AssistantMessage },
    text_start: struct { content_index: usize, partial: AssistantMessage },
    text_delta: struct { content_index: usize, delta: []const u8, partial: AssistantMessage },
    text_end: struct { content_index: usize, content: []const u8, partial: AssistantMessage },
    thinking_start: struct { content_index: usize, partial: AssistantMessage },
    thinking_delta: struct { content_index: usize, delta: []const u8, partial: AssistantMessage },
    thinking_end: struct { content_index: usize, content: []const u8, partial: AssistantMessage },
    toolcall_start: struct { content_index: usize, partial: AssistantMessage },
    toolcall_delta: struct { content_index: usize, delta: []const u8, partial: AssistantMessage },
    toolcall_end: struct { content_index: usize, tool_call: ToolCall, partial: AssistantMessage },
    done: struct { reason: StopReason, message: AssistantMessage },
    @"error": struct { reason: StopReason, err: AssistantMessage },
};

pub const AssistantMessageEventStream = event_stream.EventStream(AssistantMessageEvent, AssistantMessage);

pub fn cloneAssistantMessage(allocator: std.mem.Allocator, msg: AssistantMessage) !AssistantMessage {
    var content = try allocator.alloc(AssistantContent, msg.content.len);
    var cloned_count: usize = 0;
    errdefer {
        // Free any successfully cloned content blocks on error
        for (content[0..cloned_count]) |block| {
            switch (block) {
                .text => |t| {
                    allocator.free(t.text);
                    if (t.text_signature) |s| allocator.free(s);
                },
                .thinking => |t| {
                    allocator.free(t.thinking);
                    if (t.thinking_signature) |s| allocator.free(s);
                },
                .tool_call => |tc| {
                    allocator.free(tc.id);
                    allocator.free(tc.name);
                    allocator.free(tc.arguments_json);
                    if (tc.thought_signature) |s| allocator.free(s);
                },
            }
        }
        allocator.free(content);
    }

    for (msg.content, 0..) |block, i| {
        content[i] = switch (block) {
            .text => |t| .{ .text = .{
                .text = try allocator.dupe(u8, t.text),
                .text_signature = if (t.text_signature) |s| try allocator.dupe(u8, s) else null,
            } },
            .thinking => |t| .{ .thinking = .{
                .thinking = try allocator.dupe(u8, t.thinking),
                .thinking_signature = if (t.thinking_signature) |s| try allocator.dupe(u8, s) else null,
            } },
            .tool_call => |tc| .{ .tool_call = .{
                .id = try allocator.dupe(u8, tc.id),
                .name = try allocator.dupe(u8, tc.name),
                .arguments_json = try allocator.dupe(u8, tc.arguments_json),
                .thought_signature = if (tc.thought_signature) |s| try allocator.dupe(u8, s) else null,
            } },
        };
        cloned_count += 1;
    }

    const api = try allocator.dupe(u8, msg.api);
    errdefer allocator.free(api);

    const provider = try allocator.dupe(u8, msg.provider);
    errdefer allocator.free(provider);

    const model_id = try allocator.dupe(u8, msg.model);
    errdefer allocator.free(model_id);

    const error_msg = if (msg.error_message) |e| try allocator.dupe(u8, e) else null;

    return .{
        .content = content,
        .api = api,
        .provider = provider,
        .model = model_id,
        .usage = msg.usage,
        .stop_reason = msg.stop_reason,
        .error_message = error_msg,
        .timestamp = msg.timestamp,
    };
}

pub fn deinitAssistantMessageOwned(allocator: std.mem.Allocator, msg: *AssistantMessage) void {
    msg.deinit(allocator);
}

test "cloneAssistantMessage deep copies text content" {
    const content = [_]AssistantContent{.{ .text = .{ .text = "hello" } }};
    const msg = AssistantMessage{
        .content = &content,
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4o",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 123,
    };

    var cloned = try cloneAssistantMessage(std.testing.allocator, msg);
    defer deinitAssistantMessageOwned(std.testing.allocator, &cloned);

    try std.testing.expectEqualStrings("hello", cloned.content[0].text.text);
    try std.testing.expectEqualStrings("openai", cloned.provider);
}
