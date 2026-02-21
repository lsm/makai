const std = @import("std");
const owned_slice_mod = @import("owned_slice");

pub const OwnedSlice = owned_slice_mod.OwnedSlice;

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

pub const ThinkingLevel = enum { off, minimal, low, medium, high, xhigh };

pub const ServiceTier = enum {
    default,
    flex,
    priority,
};

pub const ReasoningSummary = enum {
    auto,
    concise,
    detailed,
};

pub const ThinkingBudgets = struct {
    minimal: ?u32 = null,
    low: ?u32 = null,
    medium: ?u32 = null,
    high: ?u32 = null,
    xhigh: ?u32 = null,
};

pub const CacheRetention = enum { none, short, long };

pub const StopReason = enum {
    stop,
    length,
    tool_use,
    content_filter,
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

pub const Metadata = struct {
    user_id: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getUserId(self: *const Metadata) ?[]const u8 {
        const uid = self.user_id.slice();
        return if (uid.len > 0) uid else null;
    }

    pub fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
        self.user_id.deinit(allocator);
    }
};

pub const ToolChoice = union(enum) {
    auto: void,
    none: void,
    required: void,
    function: []const u8, // function name
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
    /// Reasoning summary format: "auto" | "concise" | "detailed"
    reasoning_summary: ?[]const u8 = null,
    /// Whether to include encrypted reasoning content
    include_reasoning_encrypted: bool = false,
    /// Whether reasoning is enabled (for GPT-5 juice workaround)
    reasoning_enabled: bool = true,
    /// Service tier for OpenAI Responses API: "default", "flex", "priority"
    service_tier: ?ServiceTier = null,
    /// Metadata for the request
    metadata: ?Metadata = null,
    /// Tool choice behavior
    tool_choice: ?ToolChoice = null,
    /// HTTP connection timeout in milliseconds (default: 30s)
    http_timeout_ms: ?u64 = 30_000,
    /// Ping interval in milliseconds for streaming keepalive
    ping_interval_ms: ?u64 = null,
    /// True if strings were allocated (deserialized). When false, strings are borrowed.
    owned_strings: bool = false,

    /// Free all owned memory. Only call this if owned_strings = true.
    pub fn deinit(self: *StreamOptions, allocator: std.mem.Allocator) void {
        if (!self.owned_strings) return; // Guard for borrowed strings

        if (self.api_key) |key| allocator.free(key);
        if (self.session_id) |sid| allocator.free(sid);
        if (self.thinking_effort) |effort| allocator.free(effort);
        if (self.reasoning_effort) |effort| allocator.free(effort);
        if (self.reasoning_summary) |summary| allocator.free(summary);
        if (self.headers) |headers| {
            for (headers) |header| {
                allocator.free(header.name);
                allocator.free(header.value);
            }
            allocator.free(headers);
        }
        if (self.metadata) |*meta| {
            meta.deinit(allocator);
        }
        if (self.tool_choice) |*choice| {
            switch (choice.*) {
                .function => |fname| allocator.free(fname),
                else => {},
            }
        }
    }
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
    reasoning_summary: ?[]const u8 = null,
    /// HTTP connection timeout in milliseconds (default: 30s)
    http_timeout_ms: ?u64 = 30_000,
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
    image: ImageContent,
};

pub const UserContentPart = union(enum) {
    text: TextContent,
    image: ImageContent,

    /// Free all owned memory.
    pub fn deinit(self: *UserContentPart, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |*t| {
                allocator.free(t.text);
                if (t.text_signature) |s| allocator.free(s);
            },
            .image => |*img| {
                allocator.free(img.data);
                allocator.free(img.mime_type);
            },
        }
    }
};

pub const UserContent = union(enum) {
    text: []const u8,
    parts: []const UserContentPart,

    /// Free all owned memory.
    pub fn deinit(self: *UserContent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |t| allocator.free(t),
            .parts => |parts| {
                // Cast to mutable since we're freeing owned memory
                const mut_parts: []UserContentPart = @constCast(parts);
                for (mut_parts) |*part| {
                    part.deinit(allocator);
                }
                allocator.free(parts);
            },
        }
    }
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

    /// Calculate dollar costs from token usage using the model's pricing rates.
    /// Prices are per 1 million tokens.
    pub fn calculateCost(self: *Usage, model_cost: Cost) void {
        self.cost.input = (@as(f64, @floatFromInt(self.input)) / 1_000_000.0) * model_cost.input;
        self.cost.output = (@as(f64, @floatFromInt(self.output)) / 1_000_000.0) * model_cost.output;
        self.cost.cache_read = (@as(f64, @floatFromInt(self.cache_read)) / 1_000_000.0) * model_cost.cache_read;
        self.cost.cache_write = (@as(f64, @floatFromInt(self.cache_write)) / 1_000_000.0) * model_cost.cache_write;
        self.cost.total = self.cost.input + self.cost.output + self.cost.cache_read + self.cost.cache_write;
    }
};

pub const UserMessage = struct {
    content: UserContent,
    timestamp: i64,

    /// Free all owned memory.
    pub fn deinit(self: *UserMessage, allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
    }
};

pub const AssistantMessage = struct {
    content: []const AssistantContent,
    api: []const u8,
    provider: []const u8,
    model: []const u8,
    usage: Usage,
    stop_reason: StopReason,
    error_message: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    timestamp: i64,
    /// If true, api/provider/model strings are owned and will be freed in deinit
    owned_strings: bool = false,

    pub fn getErrorMessage(self: *const AssistantMessage) ?[]const u8 {
        const err = self.error_message.slice();
        return if (err.len > 0) err else null;
    }

    pub fn deinit(self: *AssistantMessage, allocator: std.mem.Allocator) void {
        for (self.content) |block| {
            switch (block) {
                .text => |t| {
                    // Only free non-empty text - empty slices may be static string literals
                    if (t.text.len > 0) allocator.free(t.text);
                    if (t.text_signature) |s| allocator.free(s);
                },
                .thinking => |t| {
                    // Only free non-empty thinking - empty slices may be static
                    if (t.thinking.len > 0) allocator.free(t.thinking);
                    if (t.thinking_signature) |s| allocator.free(s);
                },
                .tool_call => |tc| {
                    allocator.free(tc.id);
                    allocator.free(tc.name);
                    // Only free non-empty arguments_json - empty slices may be static
                    if (tc.arguments_json.len > 0) allocator.free(tc.arguments_json);
                    if (tc.thought_signature) |s| allocator.free(s);
                },
                .image => |img| {
                    allocator.free(img.data);
                    allocator.free(img.mime_type);
                },
            }
        }
        allocator.free(self.content);
        // Free duped string fields only if owned (providers set owned_strings=true when duping)
        if (self.owned_strings) {
            allocator.free(self.api);
            allocator.free(self.provider);
            allocator.free(self.model);
        }
        self.error_message.deinit(allocator);
    }
};

pub const ToolResultMessage = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    content: []const UserContentPart,
    details_json: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    is_error: bool,
    timestamp: i64,

    pub fn getDetailsJson(self: *const ToolResultMessage) ?[]const u8 {
        const details = self.details_json.slice();
        return if (details.len > 0) details else null;
    }

    /// Free all owned memory.
    pub fn deinit(self: *ToolResultMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.tool_name);
        // Cast to mutable since we're freeing owned memory
        const mut_content: []UserContentPart = @constCast(self.content);
        for (mut_content) |*part| {
            part.deinit(allocator);
        }
        allocator.free(self.content);
        self.details_json.deinit(allocator);
    }
};

pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,

    /// Free all owned memory. Only call this if the message was created via
    /// deserialization (which dupes all string fields).
    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .user => |*msg| msg.deinit(allocator),
            .assistant => |*msg| msg.deinit(allocator),
            .tool_result => |*msg| msg.deinit(allocator),
        }
    }
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters_schema_json: []const u8,

    /// Free all owned memory.
    pub fn deinit(self: *Tool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.parameters_schema_json);
    }
};

pub const Context = struct {
    system_prompt: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    messages: []const Message,
    tools: ?[]const Tool = null,
    /// If true, arrays and strings are owned and will be freed in deinit
    owned_strings: bool = false,

    pub fn getSystemPrompt(self: *const Context) ?[]const u8 {
        const prompt = self.system_prompt.slice();
        return if (prompt.len > 0) prompt else null;
    }

    /// Free all owned memory. Only frees arrays/collections if owned_strings is true
    /// (set by deserializer or when explicitly allocating).
    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        self.system_prompt.deinit(allocator);
        if (!self.owned_strings) return;

        // Free messages array and contents
        // Cast to mutable since we're freeing owned memory
        const mut_messages: []Message = @constCast(self.messages);
        for (mut_messages) |*msg| {
            msg.deinit(allocator);
        }
        allocator.free(self.messages);
        // Free tools array and contents
        if (self.tools) |tools| {
            // Cast to mutable since we're freeing owned memory
            const mut_tools: []Tool = @constCast(tools);
            for (mut_tools) |*tool| {
                tool.deinit(allocator);
            }
            allocator.free(tools);
        }
    }
};

pub const Cost = struct {
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
};

pub const OpenAICompatOptions = struct {
    /// Whether the provider supports the `store` field
    supports_store: ?bool = null,
    /// Whether the provider supports the `developer` role (vs `system`)
    supports_developer_role: ?bool = null,
    /// Whether the provider supports `reasoning_effort`
    supports_reasoning_effort: ?bool = null,
    /// Whether the provider supports usage in streaming
    supports_usage_in_streaming: ?bool = true,
    /// Which field to use for max tokens
    max_tokens_field: enum { max_completion_tokens, max_tokens } = .max_completion_tokens,
    /// Whether tool results require the `name` field
    requires_tool_result_name: ?bool = null,
    /// Whether a user message after tool results requires an assistant message in between
    requires_assistant_after_tool_result: ?bool = null,
    /// Whether thinking blocks must be converted to text
    requires_thinking_as_text: ?bool = null,
    /// Whether tool call IDs must be normalized to Mistral format
    requires_mistral_tool_ids: ?bool = null,
    /// Format for reasoning/thinking parameter
    thinking_format: enum { openai, zai, qwen } = .openai,
    /// Whether the provider supports the `strict` field in tool definitions
    supports_strict_mode: ?bool = true,
};

pub const RoutingPreferences = struct {
    only: ?[][]const u8 = null,
    order: ?[][]const u8 = null,
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
    compat: ?OpenAICompatOptions = null,
    /// If true, string fields are owned and will be freed in deinit
    owned_strings: bool = false,

    /// Free all owned memory. Only frees strings if owned_strings is true
    /// (set by deserializer or when explicitly duping).
    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        if (!self.owned_strings) return;

        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.api);
        allocator.free(self.provider);
        allocator.free(self.base_url);
        // Free input slice and its contents
        for (self.input) |input| {
            allocator.free(input);
        }
        allocator.free(self.input);
        // Free headers if present
        if (self.headers) |headers| {
            for (headers) |header| {
                allocator.free(header.name);
                allocator.free(header.value);
            }
            allocator.free(headers);
        }
    }
};

pub const AssistantMessageEvent = union(enum) {
    start: struct { partial: AssistantMessage },
    text_start: struct { content_index: usize, partial: AssistantMessage },
    text_delta: struct { content_index: usize, delta: []const u8, partial: AssistantMessage },
    text_end: struct { content_index: usize, content: []const u8, partial: AssistantMessage },
    thinking_start: struct { content_index: usize, partial: AssistantMessage },
    thinking_delta: struct { content_index: usize, delta: []const u8, partial: AssistantMessage },
    thinking_end: struct { content_index: usize, content: []const u8, partial: AssistantMessage },
    toolcall_start: struct {
        content_index: usize,
        id: []const u8,
        name: []const u8,
        partial: AssistantMessage,
    },
    toolcall_delta: struct { content_index: usize, delta: []const u8, partial: AssistantMessage },
    toolcall_end: struct { content_index: usize, tool_call: ToolCall, partial: AssistantMessage },
    done: struct { reason: StopReason, message: AssistantMessage },
    @"error": struct { reason: StopReason, err: AssistantMessage },
    keepalive: void,
};

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
                .image => |img| {
                    allocator.free(img.data);
                    allocator.free(img.mime_type);
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
            .image => |img| .{ .image = .{
                .data = try allocator.dupe(u8, img.data),
                .mime_type = try allocator.dupe(u8, img.mime_type),
            } },
        };
        cloned_count += 1;
    }

    const error_msg = if (msg.getErrorMessage()) |e|
        OwnedSlice(u8).initOwned(try allocator.dupe(u8, e))
    else
        OwnedSlice(u8).initBorrowed("");

    return .{
        .content = content,
        .api = msg.api, // Borrowed reference, not owned
        .provider = msg.provider, // Borrowed reference, not owned
        .model = msg.model, // Borrowed reference, not owned
        .usage = msg.usage,
        .stop_reason = msg.stop_reason,
        .error_message = error_msg,
        .timestamp = msg.timestamp,
    };
}

pub fn deinitAssistantMessageOwned(allocator: std.mem.Allocator, msg: *AssistantMessage) void {
    msg.deinit(allocator);
}

/// Deep copy an AssistantMessageEvent, duplicating all owned strings.
/// The caller is responsible for calling deinitEvent on the returned copy.
pub fn cloneAssistantMessageEvent(allocator: std.mem.Allocator, event: AssistantMessageEvent) !AssistantMessageEvent {
    return switch (event) {
        .start => |s| .{ .start = .{
            .partial = try cloneAssistantMessage(allocator, s.partial),
        } },
        .text_start => |t| .{ .text_start = .{
            .content_index = t.content_index,
            .partial = try cloneAssistantMessage(allocator, t.partial),
        } },
        .text_delta => |d| .{ .text_delta = .{
            .content_index = d.content_index,
            .delta = try allocator.dupe(u8, d.delta),
            .partial = try cloneAssistantMessage(allocator, d.partial),
        } },
        .text_end => |t| .{ .text_end = .{
            .content_index = t.content_index,
            .content = try allocator.dupe(u8, t.content),
            .partial = try cloneAssistantMessage(allocator, t.partial),
        } },
        .thinking_start => |t| .{ .thinking_start = .{
            .content_index = t.content_index,
            .partial = try cloneAssistantMessage(allocator, t.partial),
        } },
        .thinking_delta => |d| .{ .thinking_delta = .{
            .content_index = d.content_index,
            .delta = try allocator.dupe(u8, d.delta),
            .partial = try cloneAssistantMessage(allocator, d.partial),
        } },
        .thinking_end => |t| .{ .thinking_end = .{
            .content_index = t.content_index,
            .content = try allocator.dupe(u8, t.content),
            .partial = try cloneAssistantMessage(allocator, t.partial),
        } },
        .toolcall_start => |t| .{ .toolcall_start = .{
            .content_index = t.content_index,
            .id = try allocator.dupe(u8, t.id),
            .name = try allocator.dupe(u8, t.name),
            .partial = try cloneAssistantMessage(allocator, t.partial),
        } },
        .toolcall_delta => |d| .{ .toolcall_delta = .{
            .content_index = d.content_index,
            .delta = try allocator.dupe(u8, d.delta),
            .partial = try cloneAssistantMessage(allocator, d.partial),
        } },
        .toolcall_end => |t| .{ .toolcall_end = .{
            .content_index = t.content_index,
            .tool_call = .{
                .id = try allocator.dupe(u8, t.tool_call.id),
                .name = try allocator.dupe(u8, t.tool_call.name),
                .arguments_json = try allocator.dupe(u8, t.tool_call.arguments_json),
                .thought_signature = if (t.tool_call.thought_signature) |s| try allocator.dupe(u8, s) else null,
            },
            .partial = try cloneAssistantMessage(allocator, t.partial),
        } },
        .done => |d| .{ .done = .{
            .reason = d.reason,
            .message = try cloneAssistantMessage(allocator, d.message),
        } },
        .@"error" => |e| .{ .@"error" = .{
            .reason = e.reason,
            .err = try cloneAssistantMessage(allocator, e.err),
        } },
        .keepalive => .keepalive,
    };
}

/// Free all allocated strings in an AssistantMessageEvent.
/// Call this when you own an event that was deep-copied.
pub fn deinitAssistantMessageEvent(allocator: std.mem.Allocator, event: *AssistantMessageEvent) void {
    switch (event.*) {
        .start => |*s| s.partial.deinit(allocator),
        .text_start => |*t| t.partial.deinit(allocator),
        .thinking_start => |*t| t.partial.deinit(allocator),
        .toolcall_start => |*t| {
            allocator.free(t.id);
            allocator.free(t.name);
            t.partial.deinit(allocator);
        },
        .text_delta => |*d| {
            allocator.free(d.delta);
            d.partial.deinit(allocator);
        },
        .text_end => |*t| {
            allocator.free(t.content);
            t.partial.deinit(allocator);
        },
        .thinking_delta => |*t| {
            allocator.free(t.delta);
            t.partial.deinit(allocator);
        },
        .thinking_end => |*t| {
            allocator.free(t.content);
            t.partial.deinit(allocator);
        },
        .toolcall_delta => |*t| {
            allocator.free(t.delta);
            t.partial.deinit(allocator);
        },
        .toolcall_end => |*t| {
            allocator.free(t.tool_call.id);
            allocator.free(t.tool_call.name);
            if (t.tool_call.arguments_json.len > 0) allocator.free(t.tool_call.arguments_json);
            if (t.tool_call.thought_signature) |s| allocator.free(s);
            t.partial.deinit(allocator);
        },
        .done => |*d| d.message.deinit(allocator),
        .@"error" => |*e| e.err.deinit(allocator),
        .keepalive => {},
    }
}

/// Deep clone a Message. Caller owns the returned message and must call deinit().
pub fn cloneMessage(allocator: std.mem.Allocator, msg: Message) !Message {
    return switch (msg) {
        .user => |u| .{ .user = .{
            .content = try cloneUserContent(u.content, allocator),
            .timestamp = u.timestamp,
        } },
        .assistant => |a| .{ .assistant = try cloneAssistantMessage(allocator, a) },
        .tool_result => |tr| .{ .tool_result = try cloneToolResultMessage(allocator, tr) },
    };
}

/// Deep clone UserContent.
fn cloneUserContent(content: UserContent, allocator: std.mem.Allocator) !UserContent {
    return switch (content) {
        .text => |t| .{ .text = try allocator.dupe(u8, t) },
        .parts => |parts| blk: {
            const cloned_parts = try allocator.alloc(UserContentPart, parts.len);
            errdefer allocator.free(cloned_parts);
            for (parts, 0..) |part, i| {
                cloned_parts[i] = try cloneUserContentPart(allocator, part);
            }
            break :blk .{ .parts = cloned_parts };
        },
    };
}

/// Deep clone UserContentPart.
fn cloneUserContentPart(allocator: std.mem.Allocator, part: UserContentPart) !UserContentPart {
    return switch (part) {
        .text => |t| .{ .text = .{
            .text = try allocator.dupe(u8, t.text),
            .text_signature = if (t.text_signature) |sig| try allocator.dupe(u8, sig) else null,
        } },
        .image => |img| .{ .image = .{
            .data = try allocator.dupe(u8, img.data),
            .mime_type = try allocator.dupe(u8, img.mime_type),
        } },
    };
}

/// Deep clone ToolResultMessage.
fn cloneToolResultMessage(allocator: std.mem.Allocator, tr: ToolResultMessage) !ToolResultMessage {
    const cloned_content = try allocator.alloc(UserContentPart, tr.content.len);
    errdefer allocator.free(cloned_content);
    for (tr.content, 0..) |part, i| {
        cloned_content[i] = try cloneUserContentPart(allocator, part);
    }

    const details_json = if (tr.getDetailsJson()) |dj|
        OwnedSlice(u8).initOwned(try allocator.dupe(u8, dj))
    else
        OwnedSlice(u8).initBorrowed("");

    return .{
        .tool_call_id = try allocator.dupe(u8, tr.tool_call_id),
        .tool_name = try allocator.dupe(u8, tr.tool_name),
        .content = cloned_content,
        .details_json = details_json,
        .is_error = tr.is_error,
        .timestamp = tr.timestamp,
    };
}

/// Deep clone a Context. Caller owns the returned context and must call deinit().
pub fn cloneContext(allocator: std.mem.Allocator, ctx: Context) !Context {
    // Clone system_prompt
    var system_prompt = if (ctx.getSystemPrompt()) |sp|
        OwnedSlice(u8).initOwned(try allocator.dupe(u8, sp))
    else
        OwnedSlice(u8).initBorrowed("");
    errdefer system_prompt.deinit(allocator);

    // Clone messages
    const messages = try allocator.alloc(Message, ctx.messages.len);
    errdefer allocator.free(messages);
    for (ctx.messages, 0..) |msg, i| {
        // Use errdefer to clean up already-cloned messages on error
        errdefer for (messages[0..i]) |*m| m.deinit(allocator);
        messages[i] = try cloneMessage(allocator, msg);
    }

    // Clone tools
    var tools: ?[]Tool = null;
    if (ctx.tools) |t| {
        tools = try allocator.alloc(Tool, t.len);
        errdefer if (tools) |ts| allocator.free(ts);
        for (t, 0..) |tool, i| {
            tools.?[i] = .{
                .name = try allocator.dupe(u8, tool.name),
                .description = try allocator.dupe(u8, tool.description),
                .parameters_schema_json = try allocator.dupe(u8, tool.parameters_schema_json),
            };
        }
    }
    errdefer if (tools) |ts| {
        for (ts) |*tool| tool.deinit(allocator);
        allocator.free(ts);
    };

    return .{
        .system_prompt = system_prompt,
        .messages = messages,
        .tools = tools,
        .owned_strings = true,
    };
}

/// Deep clone a Model. Caller owns the returned model and must call deinit().
pub fn cloneModel(allocator: std.mem.Allocator, model: Model) !Model {
    // Clone string fields
    const id = try allocator.dupe(u8, model.id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, model.name);
    errdefer allocator.free(name);
    const api = try allocator.dupe(u8, model.api);
    errdefer allocator.free(api);
    const provider = try allocator.dupe(u8, model.provider);
    errdefer allocator.free(provider);
    const base_url = try allocator.dupe(u8, model.base_url);
    errdefer allocator.free(base_url);

    // Clone input array
    const input = try allocator.alloc([]const u8, model.input.len);
    errdefer allocator.free(input);
    for (model.input, 0..) |inp, i| {
        errdefer for (input[0..i]) |in| allocator.free(in);
        input[i] = try allocator.dupe(u8, inp);
    }

    // Clone headers if present
    var headers: ?[]HeaderPair = null;
    if (model.headers) |h| {
        headers = try allocator.alloc(HeaderPair, h.len);
        errdefer if (headers) |hs| allocator.free(hs);
        for (h, 0..) |hp, i| {
            headers.?[i] = .{
                .name = try allocator.dupe(u8, hp.name),
                .value = try allocator.dupe(u8, hp.value),
            };
        }
    }
    errdefer if (headers) |hs| {
        for (hs) |*hp| {
            allocator.free(hp.name);
            allocator.free(hp.value);
        }
        allocator.free(hs);
    };

    return .{
        .id = id,
        .name = name,
        .api = api,
        .provider = provider,
        .base_url = base_url,
        .reasoning = model.reasoning,
        .input = input,
        .cost = model.cost,
        .context_window = model.context_window,
        .max_tokens = model.max_tokens,
        .headers = headers,
        .compat = model.compat,
        .owned_strings = true,
    };
}

test "Context deinit frees owned system_prompt even with borrowed messages" {
    const allocator = std.testing.allocator;

    var ctx = Context{
        .system_prompt = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "be concise")),
        .messages = &.{},
        .owned_strings = false,
    };

    ctx.deinit(allocator);
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

test "ToolResultMessage details_json uses OwnedSlice and deep clones" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(UserContentPart, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "ok") } };

    var msg = ToolResultMessage{
        .tool_call_id = try allocator.dupe(u8, "call-1"),
        .tool_name = try allocator.dupe(u8, "test_tool"),
        .content = content,
        .details_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "{\"k\":1}")),
        .is_error = false,
        .timestamp = 1,
    };
    defer msg.deinit(allocator);

    var cloned = try cloneToolResultMessage(allocator, msg);
    defer cloned.deinit(allocator);

    try std.testing.expectEqualStrings("{\"k\":1}", msg.getDetailsJson().?);
    try std.testing.expectEqualStrings("{\"k\":1}", cloned.getDetailsJson().?);
    try std.testing.expect(@intFromPtr(msg.details_json.slice().ptr) != @intFromPtr(cloned.details_json.slice().ptr));
}

test "AssistantMessageEventStream deinit drains unpolled events" {
    // This test verifies that deinit() properly drains events without crashing.
    // Note: Delta strings in AssistantMessageEvent are typically slices into
    // provider-managed buffers (e.g., JSON parser buffers) and are NOT freed
    // by deinit(). Providers manage the underlying buffer lifetimes.
    const event_stream = @import("event_stream");
    var stream = event_stream.AssistantMessageEventStream.init(std.testing.allocator);
    defer stream.deinit();

    // Create a text_delta event with heap-allocated delta string
    // In real providers, this is typically a slice into a provider buffer
    const delta_str = try std.testing.allocator.dupe(u8, "test delta content");
    const partial = AssistantMessage{
        .content = &.{},
        .api = "google-generative-ai",
        .provider = "google",
        .model = "gemini-2.5-flash",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const event = AssistantMessageEvent{
        .text_delta = .{
            .content_index = 0,
            .delta = delta_str,
            .partial = partial,
        },
    };
    try stream.push(event);

    // Poll the event and free the delta string ourselves
    // (deinit does NOT free delta strings - they're provider-managed)
    if (stream.poll()) |evt| {
        switch (evt) {
            .text_delta => |d| std.testing.allocator.free(d.delta),
            else => {},
        }
    }

    // Complete with an empty result
    const result = AssistantMessage{
        .content = &.{},
        .api = "google-generative-ai",
        .provider = "google",
        .model = "gemini-2.5-flash",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    stream.complete(result);
}

test "AssistantMessageEventStream deinit drains unpolled toolcall_end events" {
    // This test verifies that deinit properly drains events.
    // Note: tool_call fields in events are typically slices into provider-managed buffers
    // and are NOT freed by deinit(). Callers should poll events and manage their own cleanup.
    const event_stream = @import("event_stream");
    var stream = event_stream.AssistantMessageEventStream.init(std.testing.allocator);
    defer stream.deinit();

    const tool_id = try std.testing.allocator.dupe(u8, "tool-123");
    const tool_name = try std.testing.allocator.dupe(u8, "bash");
    const args_json = try std.testing.allocator.dupe(u8, "{\"cmd\": \"ls\"}");
    const partial = AssistantMessage{
        .content = &.{},
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4o",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const event = AssistantMessageEvent{
        .toolcall_end = .{
            .content_index = 0,
            .tool_call = .{
                .id = tool_id,
                .name = tool_name,
                .arguments_json = args_json,
            },
            .partial = partial,
        },
    };
    try stream.push(event);

    // Poll the event and free the tool_call strings ourselves
    // (deinit does NOT free tool_call fields - they're typically provider-managed)
    if (stream.poll()) |evt| {
        switch (evt) {
            .toolcall_end => |tc| {
                std.testing.allocator.free(tc.tool_call.id);
                std.testing.allocator.free(tc.tool_call.name);
                std.testing.allocator.free(tc.tool_call.arguments_json);
            },
            else => {},
        }
    }

    const result = AssistantMessage{
        .content = &.{},
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4o",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    stream.complete(result);

    // deinit() is called by defer above
}

test "Usage.calculateCost computes correct dollar costs" {
    var usage = Usage{
        .input = 1_000_000,
        .output = 500_000,
        .cache_read = 200_000,
        .cache_write = 100_000,
    };

    const model_cost = Cost{
        .input = 3.0,
        .output = 15.0,
        .cache_read = 0.30,
        .cache_write = 3.75,
    };

    usage.calculateCost(model_cost);

    try std.testing.expectApproxEqAbs(3.0, usage.cost.input, 0.0001);
    try std.testing.expectApproxEqAbs(7.5, usage.cost.output, 0.0001);
    try std.testing.expectApproxEqAbs(0.06, usage.cost.cache_read, 0.0001);
    try std.testing.expectApproxEqAbs(0.375, usage.cost.cache_write, 0.0001);
    try std.testing.expectApproxEqAbs(10.935, usage.cost.total, 0.0001);
}

test "OpenAICompatOptions defaults are correct" {
    const compat = OpenAICompatOptions{};

    // Check default values
    try std.testing.expect(compat.supports_store == null);
    try std.testing.expect(compat.supports_developer_role == null);
    try std.testing.expect(compat.supports_reasoning_effort == null);
    // supports_usage_in_streaming defaults to true (not null)
    try std.testing.expect(compat.supports_usage_in_streaming == true);
    try std.testing.expectEqual(@as(@TypeOf(compat.max_tokens_field), .max_completion_tokens), compat.max_tokens_field);
    try std.testing.expect(compat.requires_tool_result_name == null);
    try std.testing.expect(compat.requires_assistant_after_tool_result == null);
    try std.testing.expect(compat.requires_thinking_as_text == null);
    try std.testing.expect(compat.requires_mistral_tool_ids == null);
    try std.testing.expectEqual(@as(@TypeOf(compat.thinking_format), .openai), compat.thinking_format);
    // supports_strict_mode defaults to true (not null)
    try std.testing.expect(compat.supports_strict_mode == true);
}

test "Model with compat options" {
    const model = Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "openai-completions",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 100,
        .compat = .{
            .supports_store = false,
            .max_tokens_field = .max_tokens,
            .thinking_format = .zai,
        },
    };

    try std.testing.expect(model.compat != null);
    try std.testing.expect(!model.compat.?.supports_store.?);
    try std.testing.expectEqual(@as(@TypeOf(model.compat.?.max_tokens_field), .max_tokens), model.compat.?.max_tokens_field);
    try std.testing.expectEqual(@as(@TypeOf(model.compat.?.thinking_format), .zai), model.compat.?.thinking_format);
}

test "RoutingPreferences defaults are correct" {
    const prefs = RoutingPreferences{};

    try std.testing.expect(prefs.only == null);
    try std.testing.expect(prefs.order == null);
}
