const std = @import("std");

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
    user_id: ?[]const u8 = null,
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
    /// If true, api/provider/model strings are owned and will be freed in deinit
    owned_strings: bool = false,

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

    const error_msg = if (msg.error_message) |e| try allocator.dupe(u8, e) else null;

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
