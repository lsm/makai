const std = @import("std");
const types = @import("types");

/// Authentication configuration
pub const AuthConfig = struct {
    api_key: []const u8,
    org_id: ?[]const u8 = null, // Optional organization ID (OpenAI)
};

/// Cache retention options
pub const CacheRetention = enum {
    none,
    short,
    long,
};

/// Thinking effort level
pub const ThinkingLevel = enum {
    minimal,
    low,
    medium,
    high,
    xhigh,
};

/// Thinking configuration for Anthropic API
pub const ThinkingConfig = union(enum) {
    disabled,
    enabled: struct {
        budget_tokens: u32 = 1024,
    },
    adaptive: struct {
        effort: ThinkingLevel = .medium,
    },
};

/// Response format configuration
pub const ResponseFormat = union(enum) {
    text,
    json_object,
    json_schema: []const u8, // JSON schema string
};

/// OpenAI reasoning effort levels (only low/medium/high are valid for the API)
pub const OpenAIReasoningEffort = enum {
    low,
    medium,
    high,
};

/// Custom HTTP header pair for provider requests.
pub const HeaderPair = struct {
    name: []const u8,
    value: []const u8,
};

/// Configuration for automatic retry on transient errors.
pub const RetryConfig = struct {
    max_retries: u8 = 3,
    base_delay_ms: u32 = 1000,
    max_delay_ms: u32 = 60_000,
};

/// Cancellation token for aborting in-flight streaming requests.
/// Shared between caller and streaming thread via atomic pointer.
pub const CancelToken = struct {
    cancelled: *std.atomic.Value(bool),

    pub fn isCancelled(self: CancelToken) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn cancel(self: CancelToken) void {
        self.cancelled.store(true, .release);
    }
};

/// Common request parameters
pub const RequestParams = struct {
    max_tokens: u32 = 4096,
    temperature: f32 = 1.0,
    top_p: ?f32 = null,
    top_k: ?u32 = null,
    stop_sequences: ?[]const []const u8 = null,
    system_prompt: ?[]const u8 = null,
    tools: ?[]const types.Tool = null,
    tool_choice: ?types.ToolChoice = null,
    seed: ?u64 = null,
    user: ?[]const u8 = null,
    frequency_penalty: ?f32 = null,
    presence_penalty: ?f32 = null,
};

/// Anthropic-specific configuration
pub const AnthropicConfig = struct {
    auth: AuthConfig,
    model: []const u8 = "claude-sonnet-4-20250514",
    base_url: []const u8 = "https://api.anthropic.com",
    api_version: []const u8 = "2023-06-01",
    params: RequestParams = .{},
    thinking_level: ?ThinkingLevel = null,
    thinking_budget: ?u32 = null,
    cache_retention: CacheRetention = .none,
    metadata_user_id: ?[]const u8 = null,
    custom_headers: ?[]const HeaderPair = null,
    retry_config: RetryConfig = .{},
    cancel_token: ?CancelToken = null,
};

/// OpenAI-specific configuration
pub const OpenAIConfig = struct {
    auth: AuthConfig,
    model: []const u8 = "gpt-4o",
    base_url: []const u8 = "https://api.openai.com",
    params: RequestParams = .{},
    reasoning_effort: ?OpenAIReasoningEffort = null,
    max_completion_tokens: ?u32 = null,
    max_reasoning_tokens: ?u32 = null,
    parallel_tool_calls: ?bool = null,
    response_format: ?ResponseFormat = null,
    include_usage: bool = true,
    custom_headers: ?[]const HeaderPair = null,
    retry_config: RetryConfig = .{},
    cancel_token: ?CancelToken = null,
};

/// OpenAI Responses API-specific configuration
pub const OpenAIResponsesConfig = struct {
    auth: AuthConfig,
    model: []const u8 = "o3-mini",
    base_url: []const u8 = "https://api.openai.com",
    params: RequestParams = .{},
    reasoning_effort: ?OpenAIReasoningEffort = null,
    reasoning_summary: ?[]const u8 = null, // null, "auto", "concise", "detailed"
    include_encrypted_reasoning: bool = false,
    max_output_tokens: ?u32 = null,
    parallel_tool_calls: ?bool = null,
    custom_headers: ?[]const HeaderPair = null,
    retry_config: RetryConfig = .{},
    cancel_token: ?CancelToken = null,
};

/// GitHub Copilot-specific configuration
pub const GitHubCopilotConfig = struct {
    copilot_token: []const u8, // From OAuth flow (includes proxy-ep for base URL)
    github_token: []const u8, // Refresh token (GitHub access token)
    model: []const u8 = "gpt-4o",
    base_url: ?[]const u8 = null, // Parsed from token's proxy-ep, or enterprise URL
    enabled_models: ?[][]const u8 = null, // Models successfully enabled via policy
    params: RequestParams = .{},
    include_usage: bool = true,
    custom_headers: ?[]const HeaderPair = null,
    retry_config: RetryConfig = .{},
    cancel_token: ?CancelToken = null,
};

/// Ollama-specific configuration
pub const OllamaConfig = struct {
    model: []const u8 = "llama3.2",
    base_url: []const u8 = "http://localhost:11434",
    params: RequestParams = .{},
    // No auth needed for local Ollama
    num_ctx: ?u32 = null,
    num_predict: ?i32 = null, // -1 = infinite, -2 = fill context
    keep_alive: ?[]const u8 = null, // "5m", "24h", etc.
    format: ?ResponseFormat = null,
    repeat_penalty: ?f32 = null,
    seed: ?u64 = null,
    custom_headers: ?[]const HeaderPair = null,
    retry_config: RetryConfig = .{},
    cancel_token: ?CancelToken = null,
};

/// Azure OpenAI-specific configuration
pub const AzureConfig = struct {
    api_key: []const u8,
    resource_name: []const u8, // myresource -> myresource.openai.azure.com
    deployment_name: ?[]const u8 = null, // Override model ID
    api_version: []const u8 = "2024-10-01-preview", // Default
    base_url: ?[]const u8 = null, // Override full URL
    model: []const u8 = "gpt-4o", // Used as deployment name if deployment_name is null
    params: RequestParams = .{},
    reasoning_effort: ?OpenAIReasoningEffort = null,
    max_completion_tokens: ?u32 = null,
    max_reasoning_tokens: ?u32 = null,
    session_id: ?[]const u8 = null, // For prompt caching via prompt_cache_key
    parallel_tool_calls: ?bool = null,
    response_format: ?ResponseFormat = null,
    include_usage: bool = true,
    custom_headers: ?[]const HeaderPair = null,
    retry_config: RetryConfig = .{},
    cancel_token: ?CancelToken = null,
};

// Unit tests
test "AuthConfig basic creation" {
    const auth = AuthConfig{
        .api_key = "test-key-123",
    };
    try std.testing.expectEqualStrings("test-key-123", auth.api_key);
    try std.testing.expect(auth.org_id == null);
}

test "AuthConfig with org_id" {
    const auth = AuthConfig{
        .api_key = "test-key-123",
        .org_id = "org-456",
    };
    try std.testing.expectEqualStrings("test-key-123", auth.api_key);
    try std.testing.expectEqualStrings("org-456", auth.org_id.?);
}

test "RequestParams default values" {
    const params = RequestParams{};
    try std.testing.expectEqual(@as(u32, 4096), params.max_tokens);
    try std.testing.expectEqual(@as(f32, 1.0), params.temperature);
    try std.testing.expect(params.top_p == null);
    try std.testing.expect(params.stop_sequences == null);
}

test "RequestParams custom values" {
    const params = RequestParams{
        .max_tokens = 2048,
        .temperature = 0.7,
        .top_p = 0.9,
    };
    try std.testing.expectEqual(@as(u32, 2048), params.max_tokens);
    try std.testing.expectEqual(@as(f32, 0.7), params.temperature);
    try std.testing.expectEqual(@as(f32, 0.9), params.top_p.?);
}

test "AnthropicConfig default values" {
    const config = AnthropicConfig{
        .auth = .{ .api_key = "sk-ant-test" },
    };
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", config.model);
    try std.testing.expectEqualStrings("https://api.anthropic.com", config.base_url);
    try std.testing.expectEqualStrings("2023-06-01", config.api_version);
    try std.testing.expect(config.thinking_level == null);
    try std.testing.expect(config.thinking_budget == null);
}

test "AnthropicConfig with thinking enabled" {
    const config = AnthropicConfig{
        .auth = .{ .api_key = "sk-ant-test" },
        .thinking_level = .medium,
        .thinking_budget = 10000,
    };
    try std.testing.expect(config.thinking_level.? == .medium);
    try std.testing.expectEqual(@as(u32, 10000), config.thinking_budget.?);
}

test "OpenAIConfig default values" {
    const config = OpenAIConfig{
        .auth = .{ .api_key = "sk-test" },
    };
    try std.testing.expectEqualStrings("gpt-4o", config.model);
    try std.testing.expectEqualStrings("https://api.openai.com", config.base_url);
}

test "OpenAIConfig with org_id" {
    const config = OpenAIConfig{
        .auth = .{
            .api_key = "sk-test",
            .org_id = "org-123",
        },
    };
    try std.testing.expectEqualStrings("org-123", config.auth.org_id.?);
}

test "OllamaConfig default values" {
    const config = OllamaConfig{};
    try std.testing.expectEqualStrings("llama3.2", config.model);
    try std.testing.expectEqualStrings("http://localhost:11434", config.base_url);
}

test "OllamaConfig custom model" {
    const config = OllamaConfig{
        .model = "mistral",
    };
    try std.testing.expectEqualStrings("mistral", config.model);
}

test "RequestParams with system_prompt" {
    const params = RequestParams{
        .system_prompt = "You are a helpful assistant.",
    };
    try std.testing.expectEqualStrings("You are a helpful assistant.", params.system_prompt.?);
}

test "CacheRetention enum values" {
    const none: CacheRetention = .none;
    const short: CacheRetention = .short;
    const long: CacheRetention = .long;

    try std.testing.expect(none == .none);
    try std.testing.expect(short == .short);
    try std.testing.expect(long == .long);
}

test "AnthropicConfig with cache_retention" {
    const config = AnthropicConfig{
        .auth = .{ .api_key = "sk-ant-test" },
        .cache_retention = .short,
    };
    try std.testing.expect(config.cache_retention == .short);
}

test "ThinkingLevel enum values" {
    const minimal: ThinkingLevel = .minimal;
    const low: ThinkingLevel = .low;
    const medium: ThinkingLevel = .medium;
    const high: ThinkingLevel = .high;
    const xhigh: ThinkingLevel = .xhigh;

    try std.testing.expect(minimal == .minimal);
    try std.testing.expect(low == .low);
    try std.testing.expect(medium == .medium);
    try std.testing.expect(high == .high);
    try std.testing.expect(xhigh == .xhigh);
}

test "RequestParams with tools" {
    const param1 = types.ToolParameter{
        .name = "location",
        .param_type = "string",
        .required = true,
    };

    const tool = types.Tool{
        .name = "get_weather",
        .description = "Get weather info",
        .parameters = &[_]types.ToolParameter{param1},
    };

    const params = RequestParams{
        .tools = &[_]types.Tool{tool},
        .tool_choice = .{ .auto = {} },
    };

    try std.testing.expect(params.tools != null);
    try std.testing.expectEqual(@as(usize, 1), params.tools.?.len);
    try std.testing.expectEqualStrings("get_weather", params.tools.?[0].name);
    try std.testing.expect(params.tool_choice != null);
}

test "RequestParams with top_k" {
    const params = RequestParams{
        .top_k = 50,
    };
    try std.testing.expectEqual(@as(u32, 50), params.top_k.?);
}

test "OpenAIConfig with reasoning_effort" {
    const config = OpenAIConfig{
        .auth = .{ .api_key = "sk-test" },
        .reasoning_effort = .high,
    };
    try std.testing.expect(config.reasoning_effort.? == .high);
}

test "ThinkingConfig disabled" {
    const config: ThinkingConfig = .disabled;
    try std.testing.expect(std.meta.activeTag(config) == .disabled);
}

test "ThinkingConfig enabled with default budget" {
    const config = ThinkingConfig{ .enabled = .{} };
    try std.testing.expect(std.meta.activeTag(config) == .enabled);
    try std.testing.expectEqual(@as(u32, 1024), config.enabled.budget_tokens);
}

test "ThinkingConfig enabled with custom budget" {
    const config = ThinkingConfig{ .enabled = .{ .budget_tokens = 2048 } };
    try std.testing.expectEqual(@as(u32, 2048), config.enabled.budget_tokens);
}

test "ThinkingConfig adaptive with default effort" {
    const config = ThinkingConfig{ .adaptive = .{} };
    try std.testing.expect(std.meta.activeTag(config) == .adaptive);
    try std.testing.expect(config.adaptive.effort == .medium);
}

test "ThinkingConfig adaptive with custom effort" {
    const config = ThinkingConfig{ .adaptive = .{ .effort = .high } };
    try std.testing.expect(config.adaptive.effort == .high);
}

test "ResponseFormat text" {
    const format: ResponseFormat = .text;
    try std.testing.expect(std.meta.activeTag(format) == .text);
}

test "ResponseFormat json_object" {
    const format: ResponseFormat = .json_object;
    try std.testing.expect(std.meta.activeTag(format) == .json_object);
}

test "ResponseFormat json_schema" {
    const schema = "{\"type\":\"object\",\"properties\":{}}";
    const format = ResponseFormat{ .json_schema = schema };
    try std.testing.expect(std.meta.activeTag(format) == .json_schema);
    try std.testing.expectEqualStrings(schema, format.json_schema);
}

test "AnthropicConfig with metadata_user_id" {
    const config = AnthropicConfig{
        .auth = .{ .api_key = "sk-ant-test" },
        .metadata_user_id = "user-123",
    };
    try std.testing.expectEqualStrings("user-123", config.metadata_user_id.?);
}

test "OpenAIConfig with frequency_penalty" {
    const config = OpenAIConfig{
        .auth = .{ .api_key = "sk-test" },
        .params = .{ .frequency_penalty = 0.5 },
    };
    try std.testing.expectEqual(@as(f32, 0.5), config.params.frequency_penalty.?);
}

test "OpenAIConfig with presence_penalty" {
    const config = OpenAIConfig{
        .auth = .{ .api_key = "sk-test" },
        .params = .{ .presence_penalty = -0.5 },
    };
    try std.testing.expectEqual(@as(f32, -0.5), config.params.presence_penalty.?);
}

test "OpenAIConfig with max_reasoning_tokens" {
    const config = OpenAIConfig{
        .auth = .{ .api_key = "sk-test" },
        .max_reasoning_tokens = 10000,
    };
    try std.testing.expectEqual(@as(u32, 10000), config.max_reasoning_tokens.?);
}

test "OpenAIConfig with parallel_tool_calls" {
    const config = OpenAIConfig{
        .auth = .{ .api_key = "sk-test" },
        .parallel_tool_calls = true,
    };
    try std.testing.expect(config.parallel_tool_calls.?);
}

test "OpenAIConfig with seed" {
    const config = OpenAIConfig{
        .auth = .{ .api_key = "sk-test" },
        .params = .{ .seed = 42 },
    };
    try std.testing.expectEqual(@as(u64, 42), config.params.seed.?);
}

test "OpenAIConfig with user" {
    const config = OpenAIConfig{
        .auth = .{ .api_key = "sk-test" },
        .params = .{ .user = "user-456" },
    };
    try std.testing.expectEqualStrings("user-456", config.params.user.?);
}

test "OpenAIConfig with response_format" {
    const config = OpenAIConfig{
        .auth = .{ .api_key = "sk-test" },
        .response_format = .json_object,
    };
    try std.testing.expect(std.meta.activeTag(config.response_format.?) == .json_object);
}

test "OllamaConfig with num_ctx" {
    const config = OllamaConfig{
        .num_ctx = 4096,
    };
    try std.testing.expectEqual(@as(u32, 4096), config.num_ctx.?);
}

test "OllamaConfig with num_predict infinite" {
    const config = OllamaConfig{
        .num_predict = -1,
    };
    try std.testing.expectEqual(@as(i32, -1), config.num_predict.?);
}

test "OllamaConfig with num_predict fill context" {
    const config = OllamaConfig{
        .num_predict = -2,
    };
    try std.testing.expectEqual(@as(i32, -2), config.num_predict.?);
}

test "OllamaConfig with keep_alive" {
    const config = OllamaConfig{
        .keep_alive = "5m",
    };
    try std.testing.expectEqualStrings("5m", config.keep_alive.?);
}

test "OllamaConfig with format" {
    const config = OllamaConfig{
        .format = .json_object,
    };
    try std.testing.expect(std.meta.activeTag(config.format.?) == .json_object);
}

test "OllamaConfig with repeat_penalty" {
    const config = OllamaConfig{
        .repeat_penalty = 1.1,
    };
    try std.testing.expectEqual(@as(f32, 1.1), config.repeat_penalty.?);
}

test "OllamaConfig with seed" {
    const config = OllamaConfig{
        .seed = 12345,
    };
    try std.testing.expectEqual(@as(u64, 12345), config.seed.?);
}

test "RequestParams with seed" {
    const params = RequestParams{
        .seed = 999,
    };
    try std.testing.expectEqual(@as(u64, 999), params.seed.?);
}

test "RequestParams with user" {
    const params = RequestParams{
        .user = "user-789",
    };
    try std.testing.expectEqualStrings("user-789", params.user.?);
}

test "RequestParams with frequency_penalty" {
    const params = RequestParams{
        .frequency_penalty = 1.5,
    };
    try std.testing.expectEqual(@as(f32, 1.5), params.frequency_penalty.?);
}

test "RequestParams with presence_penalty" {
    const params = RequestParams{
        .presence_penalty = -1.0,
    };
    try std.testing.expectEqual(@as(f32, -1.0), params.presence_penalty.?);
}

test "OpenAIConfig comprehensive" {
    const config = OpenAIConfig{
        .auth = .{ .api_key = "sk-test", .org_id = "org-123" },
        .model = "gpt-4o-mini",
        .reasoning_effort = .high,
        .params = .{
            .frequency_penalty = 0.8,
            .presence_penalty = 0.6,
            .seed = 42,
            .user = "test-user",
        },
        .max_reasoning_tokens = 5000,
        .parallel_tool_calls = false,
        .response_format = .{ .json_schema = "{\"type\":\"object\"}" },
    };
    try std.testing.expectEqualStrings("gpt-4o-mini", config.model);
    try std.testing.expect(config.reasoning_effort.? == .high);
    try std.testing.expectEqual(@as(f32, 0.8), config.params.frequency_penalty.?);
    try std.testing.expectEqual(@as(f32, 0.6), config.params.presence_penalty.?);
    try std.testing.expectEqual(@as(u32, 5000), config.max_reasoning_tokens.?);
    try std.testing.expect(!config.parallel_tool_calls.?);
    try std.testing.expectEqual(@as(u64, 42), config.params.seed.?);
    try std.testing.expectEqualStrings("test-user", config.params.user.?);
    try std.testing.expect(std.meta.activeTag(config.response_format.?) == .json_schema);
}

test "OllamaConfig comprehensive" {
    const config = OllamaConfig{
        .model = "mistral",
        .base_url = "http://custom:11434",
        .num_ctx = 8192,
        .num_predict = 1024,
        .keep_alive = "10m",
        .format = .text,
        .repeat_penalty = 1.2,
        .seed = 54321,
    };
    try std.testing.expectEqualStrings("mistral", config.model);
    try std.testing.expectEqualStrings("http://custom:11434", config.base_url);
    try std.testing.expectEqual(@as(u32, 8192), config.num_ctx.?);
    try std.testing.expectEqual(@as(i32, 1024), config.num_predict.?);
    try std.testing.expectEqualStrings("10m", config.keep_alive.?);
    try std.testing.expect(std.meta.activeTag(config.format.?) == .text);
    try std.testing.expectEqual(@as(f32, 1.2), config.repeat_penalty.?);
    try std.testing.expectEqual(@as(u64, 54321), config.seed.?);
}

test "OpenAIReasoningEffort enum values" {
    const low: OpenAIReasoningEffort = .low;
    const medium: OpenAIReasoningEffort = .medium;
    const high: OpenAIReasoningEffort = .high;
    try std.testing.expect(low == .low);
    try std.testing.expect(medium == .medium);
    try std.testing.expect(high == .high);
}

test "OpenAIConfig with max_completion_tokens" {
    const cfg = OpenAIConfig{
        .auth = .{ .api_key = "sk-test" },
        .max_completion_tokens = 8192,
    };
    try std.testing.expectEqual(@as(u32, 8192), cfg.max_completion_tokens.?);
}

test "OpenAIConfig include_usage defaults to true" {
    const cfg = OpenAIConfig{
        .auth = .{ .api_key = "sk-test" },
    };
    try std.testing.expect(cfg.include_usage);
}

test "HeaderPair creation" {
    const header = HeaderPair{ .name = "X-Custom", .value = "test-value" };
    try std.testing.expectEqualStrings("X-Custom", header.name);
    try std.testing.expectEqualStrings("test-value", header.value);
}

test "RetryConfig defaults" {
    const cfg = RetryConfig{};
    try std.testing.expectEqual(@as(u8, 3), cfg.max_retries);
    try std.testing.expectEqual(@as(u32, 1000), cfg.base_delay_ms);
    try std.testing.expectEqual(@as(u32, 60_000), cfg.max_delay_ms);
}

test "RetryConfig custom values" {
    const cfg = RetryConfig{
        .max_retries = 5,
        .base_delay_ms = 500,
        .max_delay_ms = 30_000,
    };
    try std.testing.expectEqual(@as(u8, 5), cfg.max_retries);
    try std.testing.expectEqual(@as(u32, 500), cfg.base_delay_ms);
    try std.testing.expectEqual(@as(u32, 30_000), cfg.max_delay_ms);
}

test "CancelToken" {
    var cancelled_val = std.atomic.Value(bool).init(false);
    const token = CancelToken{ .cancelled = &cancelled_val };

    try std.testing.expect(!token.isCancelled());
    token.cancel();
    try std.testing.expect(token.isCancelled());
}

test "AnthropicConfig with new stream options" {
    const cfg = AnthropicConfig{
        .auth = .{ .api_key = "key" },
        .custom_headers = &[_]HeaderPair{
            .{ .name = "X-Test", .value = "val" },
        },
        .retry_config = .{ .max_retries = 5 },
    };
    try std.testing.expectEqual(@as(usize, 1), cfg.custom_headers.?.len);
    try std.testing.expectEqual(@as(u8, 5), cfg.retry_config.max_retries);
    try std.testing.expect(cfg.cancel_token == null);
}

test "OpenAIConfig with new stream options" {
    var cancelled_val = std.atomic.Value(bool).init(false);
    const cfg = OpenAIConfig{
        .auth = .{ .api_key = "key" },
        .cancel_token = CancelToken{ .cancelled = &cancelled_val },
    };
    try std.testing.expect(cfg.cancel_token != null);
    try std.testing.expect(!cfg.cancel_token.?.isCancelled());
}

test "OllamaConfig with new stream options" {
    const cfg = OllamaConfig{
        .retry_config = .{ .base_delay_ms = 2000 },
    };
    try std.testing.expectEqual(@as(u32, 2000), cfg.retry_config.base_delay_ms);
    try std.testing.expect(cfg.custom_headers == null);
}

test "existing configs still work with defaults" {
    // Verify backward compatibility - old-style config creation still works
    const anthropic = AnthropicConfig{ .auth = .{ .api_key = "test" } };
    try std.testing.expectEqual(RetryConfig{}, anthropic.retry_config);

    const openai = OpenAIConfig{ .auth = .{ .api_key = "test" } };
    try std.testing.expectEqual(RetryConfig{}, openai.retry_config);

    const ollama = OllamaConfig{};
    try std.testing.expectEqual(RetryConfig{}, ollama.retry_config);
}

test "OpenAIResponsesConfig default values" {
    const config = OpenAIResponsesConfig{
        .auth = .{ .api_key = "sk-test" },
    };
    try std.testing.expectEqualStrings("o3-mini", config.model);
    try std.testing.expectEqualStrings("https://api.openai.com", config.base_url);
    try std.testing.expect(config.reasoning_effort == null);
    try std.testing.expect(config.reasoning_summary == null);
    try std.testing.expect(!config.include_encrypted_reasoning);
}

test "OpenAIResponsesConfig with reasoning" {
    const config = OpenAIResponsesConfig{
        .auth = .{ .api_key = "sk-test" },
        .reasoning_effort = .high,
        .reasoning_summary = "concise",
        .include_encrypted_reasoning = true,
    };
    try std.testing.expect(config.reasoning_effort.? == .high);
    try std.testing.expectEqualStrings("concise", config.reasoning_summary.?);
    try std.testing.expect(config.include_encrypted_reasoning);
}

test "OpenAIResponsesConfig with max_output_tokens" {
    const config = OpenAIResponsesConfig{
        .auth = .{ .api_key = "sk-test" },
        .max_output_tokens = 16000,
    };
    try std.testing.expectEqual(@as(u32, 16000), config.max_output_tokens.?);
}

test "GitHubCopilotConfig default values" {
    const config = GitHubCopilotConfig{
        .copilot_token = "test-copilot-token",
        .github_token = "test-github-token",
    };
    try std.testing.expectEqualStrings("gpt-4o", config.model);
    try std.testing.expect(config.base_url == null);
    try std.testing.expect(config.enabled_models == null);
    try std.testing.expect(config.include_usage);
}

test "GitHubCopilotConfig with custom values" {
    const enabled: []const []const u8 = &[_][]const u8{ "gpt-4o", "claude-sonnet-4.5" };
    const config = GitHubCopilotConfig{
        .copilot_token = "test-copilot-token",
        .github_token = "test-github-token",
        .model = "claude-sonnet-4.5",
        .base_url = "https://api.individual.githubcopilot.com",
        .enabled_models = @as([][]const u8, @constCast(enabled)),
    };
    try std.testing.expectEqualStrings("claude-sonnet-4.5", config.model);
    try std.testing.expectEqualStrings("https://api.individual.githubcopilot.com", config.base_url.?);
    try std.testing.expectEqual(@as(usize, 2), config.enabled_models.?.len);
}
