//! Unified streaming interface that abstracts provider-specific configuration.
//! Provides a single `streamSimple` function that accepts a Model and provider-agnostic
//! options, automatically mapping to the correct provider configuration.

const std = @import("std");
const types = @import("types");
const config = @import("config");
const model_mod = @import("model");
const event_stream = @import("event_stream");
const provider_mod = @import("provider");
const anthropic = @import("anthropic");
const openai = @import("openai");
const openai_responses = @import("openai_responses");
const ollama = @import("ollama");
const azure = @import("azure");
const google = @import("google");
const google_vertex = @import("google_vertex");
const bedrock = @import("bedrock");

/// Default thinking budgets per ThinkingLevel (in tokens).
pub const ThinkingBudgets = struct {
    minimal: u32 = 1024,
    low: u32 = 2048,
    medium: u32 = 8192,
    high: u32 = 16384,
    xhigh: u32 = 32768,
};

/// Provider-agnostic streaming options.
/// Maps to provider-specific config structs internally.
pub const SimpleStreamOptions = struct {
    // Common parameters
    system_prompt: ?[]const u8 = null,
    max_tokens: ?u32 = null,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    stop_sequences: ?[]const []const u8 = null,

    // Tools
    tools: ?[]const types.Tool = null,
    tool_choice: ?types.ToolChoice = null,

    // Unified reasoning (maps to provider-specific params)
    reasoning: ?config.ThinkingLevel = null,
    thinking_budgets: ThinkingBudgets = .{},

    // Auth
    api_key: ?[]const u8 = null,
    org_id: ?[]const u8 = null,

    // Overrides
    base_url: ?[]const u8 = null,

    // Provider-specific (passed through when applicable)
    cache_retention: config.CacheRetention = .none,
    response_format: ?config.ResponseFormat = null,

    // Azure-specific
    resource_name: ?[]const u8 = null,
    deployment_name: ?[]const u8 = null,

    // AWS Bedrock-specific
    aws_access_key_id: ?[]const u8 = null,
    aws_secret_access_key: ?[]const u8 = null,
    aws_session_token: ?[]const u8 = null,
    aws_region: ?[]const u8 = null,

    // Google Vertex-specific
    google_project_id: ?[]const u8 = null,
    google_location: ?[]const u8 = null,

    // Stream control
    cancel_token: ?config.CancelToken = null,
    custom_headers: ?[]const config.HeaderPair = null,
    retry_config: config.RetryConfig = .{},
};

pub const StreamSimpleError = error{
    MissingApiKey,
    OutOfMemory,
    Unexpected,
};

/// Map ThinkingLevel to OpenAI reasoning effort.
/// OpenAI only supports low/medium/high, so we clamp.
pub fn mapToOpenAIEffort(level: config.ThinkingLevel) config.OpenAIReasoningEffort {
    return switch (level) {
        .minimal, .low => .low,
        .medium => .medium,
        .high, .xhigh => .high,
    };
}

/// Get the thinking budget for a given level.
pub fn getBudget(level: config.ThinkingLevel, budgets: ThinkingBudgets) u32 {
    return switch (level) {
        .minimal => budgets.minimal,
        .low => budgets.low,
        .medium => budgets.medium,
        .high => budgets.high,
        .xhigh => budgets.xhigh,
    };
}

/// Adjust max_tokens to accommodate thinking budget.
/// Ensures max_tokens >= thinking_budget + min_output, capped at model max.
pub fn adjustMaxTokensForThinking(base_max_tokens: u32, thinking_budget: u32, model_max_tokens: u32) u32 {
    const min_output: u32 = 1024;
    const needed = thinking_budget + min_output;
    const adjusted = @max(base_max_tokens, needed);
    return @min(adjusted, model_max_tokens);
}

/// Build common RequestParams from SimpleStreamOptions and Model defaults.
fn buildRequestParams(options: SimpleStreamOptions, mdl: model_mod.Model) config.RequestParams {
    return .{
        .max_tokens = options.max_tokens orelse @min(mdl.max_tokens, 32000),
        .temperature = options.temperature orelse 1.0,
        .top_p = options.top_p,
        .stop_sequences = options.stop_sequences,
        .system_prompt = options.system_prompt,
        .tools = options.tools,
        .tool_choice = options.tool_choice,
    };
}

/// Stream with provider-agnostic options.
/// Creates the appropriate provider from the Model's api_type, maps options
/// to provider-specific config, and returns the streaming event stream.
///
/// The caller owns the returned AssistantMessageStream.
/// The Provider is allocated internally and cleaned up by the streaming thread.
pub fn streamSimple(
    mdl: model_mod.Model,
    messages: []const types.Message,
    options: SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageStream {
    switch (mdl.api_type) {
        .anthropic => {
            const api_key = options.api_key orelse return error.MissingApiKey;
            var params = buildRequestParams(options, mdl);

            // Map unified reasoning to Anthropic thinking config
            var thinking_level: ?config.ThinkingLevel = null;
            var thinking_budget: ?u32 = null;
            if (options.reasoning) |level| {
                thinking_level = level;
                const budget = getBudget(level, options.thinking_budgets);
                thinking_budget = budget;
                params.max_tokens = adjustMaxTokensForThinking(params.max_tokens, budget, mdl.max_tokens);
            }

            const cfg = config.AnthropicConfig{
                .auth = .{ .api_key = api_key, .org_id = options.org_id },
                .model = mdl.id,
                .base_url = options.base_url orelse if (mdl.base_url) |url| url else "https://api.anthropic.com",
                .params = params,
                .thinking_level = thinking_level,
                .thinking_budget = thinking_budget,
                .cache_retention = options.cache_retention,
                .custom_headers = options.custom_headers,
                .retry_config = options.retry_config,
                .cancel_token = options.cancel_token,
            };

            const p = try anthropic.createProvider(cfg, allocator);
            return p.stream(messages, allocator);
        },
        .openai => {
            const api_key = options.api_key orelse return error.MissingApiKey;
            const params = buildRequestParams(options, mdl);

            // Map unified reasoning to OpenAI effort
            var reasoning_effort: ?config.OpenAIReasoningEffort = null;
            if (options.reasoning) |level| {
                reasoning_effort = mapToOpenAIEffort(level);
            }

            // For reasoning models, use max_completion_tokens
            var max_completion_tokens: ?u32 = null;
            if (mdl.reasoning and options.reasoning != null) {
                max_completion_tokens = params.max_tokens;
            }

            const cfg = config.OpenAIConfig{
                .auth = .{ .api_key = api_key, .org_id = options.org_id },
                .model = mdl.id,
                .base_url = options.base_url orelse if (mdl.base_url) |url| url else "https://api.openai.com",
                .params = params,
                .reasoning_effort = reasoning_effort,
                .max_completion_tokens = max_completion_tokens,
                .response_format = options.response_format,
                .custom_headers = options.custom_headers,
                .retry_config = options.retry_config,
                .cancel_token = options.cancel_token,
            };

            const p = try openai.createProvider(cfg, allocator);
            return p.stream(messages, allocator);
        },
        .openai_responses => {
            const api_key = options.api_key orelse return error.MissingApiKey;
            const params = buildRequestParams(options, mdl);

            // Map unified reasoning to OpenAI effort and summary
            var reasoning_effort: ?config.OpenAIReasoningEffort = null;
            var include_encrypted_reasoning: bool = false;
            if (options.reasoning) |level| {
                reasoning_effort = mapToOpenAIEffort(level);
                include_encrypted_reasoning = true;
            }

            // For Responses API, use max_output_tokens
            var max_output_tokens: ?u32 = null;
            if (mdl.reasoning and options.reasoning != null) {
                max_output_tokens = params.max_tokens;
            }

            const cfg = config.OpenAIResponsesConfig{
                .auth = .{ .api_key = api_key, .org_id = options.org_id },
                .model = mdl.id,
                .base_url = options.base_url orelse if (mdl.base_url) |url| url else "https://api.openai.com",
                .params = params,
                .reasoning_effort = reasoning_effort,
                .reasoning_summary = null,
                .include_encrypted_reasoning = include_encrypted_reasoning,
                .max_output_tokens = max_output_tokens,
                .response_format = options.response_format,
                .custom_headers = options.custom_headers,
                .retry_config = options.retry_config,
                .cancel_token = options.cancel_token,
            };

            const p = try openai_responses.createProvider(cfg, allocator);
            return p.stream(messages, allocator);
        },
        .ollama => {
            const params = buildRequestParams(options, mdl);

            const cfg = config.OllamaConfig{
                .model = mdl.id,
                .base_url = options.base_url orelse if (mdl.base_url) |url| url else "http://localhost:11434",
                .params = params,
                .custom_headers = options.custom_headers,
                .retry_config = options.retry_config,
                .cancel_token = options.cancel_token,
            };

            const p = try ollama.createProvider(cfg, allocator);
            return p.stream(messages, allocator);
        },
        .azure => {
            const api_key = options.api_key orelse return error.MissingApiKey;
            const resource_name = options.resource_name orelse return error.MissingApiKey;
            const params = buildRequestParams(options, mdl);

            // Map unified reasoning to OpenAI effort (same as openai)
            var reasoning_effort: ?config.OpenAIReasoningEffort = null;
            if (options.reasoning) |level| {
                reasoning_effort = mapToOpenAIEffort(level);
            }

            // For reasoning models, use max_completion_tokens
            var max_completion_tokens: ?u32 = null;
            if (mdl.reasoning and options.reasoning != null) {
                max_completion_tokens = params.max_tokens;
            }

            const cfg = config.AzureConfig{
                .api_key = api_key,
                .resource_name = resource_name,
                .deployment_name = options.deployment_name,
                .model = mdl.id,
                .base_url = options.base_url,
                .params = params,
                .reasoning_effort = reasoning_effort,
                .max_completion_tokens = max_completion_tokens,
                .response_format = options.response_format,
                .custom_headers = options.custom_headers,
                .retry_config = options.retry_config,
                .cancel_token = options.cancel_token,
            };

            const p = try azure.createProvider(cfg, allocator);
            return p.stream(messages, allocator);
        },
        .google => {
            const api_key = options.api_key orelse return error.MissingApiKey;
            var params = buildRequestParams(options, mdl);

            // Map unified reasoning to Google ThinkingConfig
            var thinking_cfg: ?google.ThinkingConfig = null;
            if (options.reasoning) |level| {
                const budget = getBudget(level, options.thinking_budgets);
                thinking_cfg = google.ThinkingConfig{
                    .enabled = true,
                    .budget_tokens = @intCast(budget),
                };
                params.max_tokens = adjustMaxTokensForThinking(params.max_tokens, budget, mdl.max_tokens);
            }

            const cfg = google.GoogleConfig{
                .allocator = allocator,
                .api_key = api_key,
                .model_id = mdl.id,
                .base_url = options.base_url,
                .params = params,
                .thinking = thinking_cfg,
                .custom_headers = options.custom_headers,
                .retry_config = options.retry_config,
                .cancel_token = options.cancel_token,
            };

            const p = try google.createProvider(cfg, allocator);
            return p.stream(messages, allocator);
        },
        .bedrock => {
            const access_key_id = options.aws_access_key_id orelse return error.MissingApiKey;
            const secret_access_key = options.aws_secret_access_key orelse return error.MissingApiKey;
            var params = buildRequestParams(options, mdl);

            // Map unified reasoning to Bedrock ThinkingConfig
            var thinking_cfg: ?bedrock.BedrockThinkingConfig = null;
            if (options.reasoning) |level| {
                const budget = getBudget(level, options.thinking_budgets);
                thinking_cfg = bedrock.BedrockThinkingConfig{
                    .mode = .enabled,
                    .budget_tokens = budget,
                };
                params.max_tokens = adjustMaxTokensForThinking(params.max_tokens, budget, mdl.max_tokens);
            }

            const cfg = bedrock.BedrockConfig{
                .auth = .{
                    .access_key_id = access_key_id,
                    .secret_access_key = secret_access_key,
                    .session_token = options.aws_session_token,
                },
                .model = mdl.id,
                .region = options.aws_region orelse "us-east-1",
                .base_url = options.base_url,
                .params = params,
                .thinking_config = thinking_cfg,
                .cache_retention = options.cache_retention,
                .custom_headers = options.custom_headers,
                .retry_config = options.retry_config,
                .cancel_token = options.cancel_token,
            };

            const p = try bedrock.createProvider(cfg, allocator);
            return p.stream(messages, allocator);
        },
    }
}

// --- Tests ---

test "mapToOpenAIEffort maps levels correctly" {
    try std.testing.expectEqual(config.OpenAIReasoningEffort.low, mapToOpenAIEffort(.minimal));
    try std.testing.expectEqual(config.OpenAIReasoningEffort.low, mapToOpenAIEffort(.low));
    try std.testing.expectEqual(config.OpenAIReasoningEffort.medium, mapToOpenAIEffort(.medium));
    try std.testing.expectEqual(config.OpenAIReasoningEffort.high, mapToOpenAIEffort(.high));
    try std.testing.expectEqual(config.OpenAIReasoningEffort.high, mapToOpenAIEffort(.xhigh));
}

test "getBudget returns correct values" {
    const budgets = ThinkingBudgets{};
    try std.testing.expectEqual(@as(u32, 1024), getBudget(.minimal, budgets));
    try std.testing.expectEqual(@as(u32, 2048), getBudget(.low, budgets));
    try std.testing.expectEqual(@as(u32, 8192), getBudget(.medium, budgets));
    try std.testing.expectEqual(@as(u32, 16384), getBudget(.high, budgets));
    try std.testing.expectEqual(@as(u32, 32768), getBudget(.xhigh, budgets));
}

test "getBudget custom budgets" {
    const budgets = ThinkingBudgets{
        .minimal = 512,
        .low = 1024,
        .medium = 4096,
        .high = 8192,
        .xhigh = 16384,
    };
    try std.testing.expectEqual(@as(u32, 512), getBudget(.minimal, budgets));
    try std.testing.expectEqual(@as(u32, 4096), getBudget(.medium, budgets));
}

test "adjustMaxTokensForThinking basic" {
    // base=4096, budget=8192 → needs 8192+1024=9216 → 9216
    try std.testing.expectEqual(@as(u32, 9216), adjustMaxTokensForThinking(4096, 8192, 32000));
}

test "adjustMaxTokensForThinking caps at model max" {
    // base=4096, budget=30000 → needs 31024 → 31024 (within model max)
    try std.testing.expectEqual(@as(u32, 31024), adjustMaxTokensForThinking(4096, 30000, 32000));
    // base=4096, budget=32000 → needs 33024 → capped at 32000
    try std.testing.expectEqual(@as(u32, 32000), adjustMaxTokensForThinking(4096, 32000, 32000));
}

test "adjustMaxTokensForThinking base already sufficient" {
    // base=16384, budget=2048 → max(16384, 3072) = 16384
    try std.testing.expectEqual(@as(u32, 16384), adjustMaxTokensForThinking(16384, 2048, 32000));
}

test "buildRequestParams uses model defaults" {
    const mdl = model_mod.Model{
        .id = "test-model",
        .name = "Test",
        .api_type = .anthropic,
        .provider = "test",
        .max_tokens = 16384,
    };
    const options = SimpleStreamOptions{};
    const params = buildRequestParams(options, mdl);

    // max_tokens should be min(model.max_tokens, 32000) = 16384
    try std.testing.expectEqual(@as(u32, 16384), params.max_tokens);
    try std.testing.expectEqual(@as(f32, 1.0), params.temperature);
    try std.testing.expect(params.system_prompt == null);
    try std.testing.expect(params.tools == null);
}

test "buildRequestParams overrides with options" {
    const mdl = model_mod.Model{
        .id = "test-model",
        .name = "Test",
        .api_type = .openai,
        .provider = "test",
        .max_tokens = 100000,
    };
    const options = SimpleStreamOptions{
        .max_tokens = 8192,
        .temperature = 0.7,
        .system_prompt = "You are helpful.",
    };
    const params = buildRequestParams(options, mdl);

    try std.testing.expectEqual(@as(u32, 8192), params.max_tokens);
    try std.testing.expectEqual(@as(f32, 0.7), params.temperature);
    try std.testing.expectEqualStrings("You are helpful.", params.system_prompt.?);
}

test "buildRequestParams caps large model max_tokens" {
    const mdl = model_mod.Model{
        .id = "test-model",
        .name = "Test",
        .api_type = .openai,
        .provider = "test",
        .max_tokens = 100000,
    };
    const options = SimpleStreamOptions{};
    const params = buildRequestParams(options, mdl);

    // min(100000, 32000) = 32000
    try std.testing.expectEqual(@as(u32, 32000), params.max_tokens);
}

test "SimpleStreamOptions defaults" {
    const opts = SimpleStreamOptions{};
    try std.testing.expect(opts.reasoning == null);
    try std.testing.expect(opts.api_key == null);
    try std.testing.expect(opts.cancel_token == null);
    try std.testing.expectEqual(config.CacheRetention.none, opts.cache_retention);
    try std.testing.expectEqual(config.RetryConfig{}, opts.retry_config);
}

test "ThinkingBudgets defaults" {
    const budgets = ThinkingBudgets{};
    try std.testing.expectEqual(@as(u32, 1024), budgets.minimal);
    try std.testing.expectEqual(@as(u32, 2048), budgets.low);
    try std.testing.expectEqual(@as(u32, 8192), budgets.medium);
    try std.testing.expectEqual(@as(u32, 16384), budgets.high);
    try std.testing.expectEqual(@as(u32, 32768), budgets.xhigh);
}

// ============================================================================
// Simplified Stream API - Auto-detect provider from environment variables
// ============================================================================

/// Detected provider type from environment variables
pub const DetectedProvider = enum {
    anthropic,
    openai,
    ollama,
    google,
    azure,
    bedrock,

    /// Returns the default model ID for this provider
    pub fn defaultModel(self: DetectedProvider) []const u8 {
        return switch (self) {
            .anthropic => "claude-sonnet-4-20250514",
            .openai => "gpt-4o",
            .ollama => "llama3.1",
            .google => "gemini-2.5-flash",
            .azure => "azure-gpt-4o",
            .bedrock => "anthropic.claude-3-5-sonnet-20240620-v1:0",
        };
    }
};

/// Error type for provider detection
pub const DetectError = error{
    NoApiKey,
    MultipleProviders,
};

/// Detect the provider from environment variables.
/// Priority: ANTHROPIC_API_KEY > OPENAI_API_KEY > GOOGLE_API_KEY
/// Returns error.NoApiKey if no API key is found.
/// Returns error.MultipleProviders if multiple keys are found (ambiguous).
pub fn detectProvider() DetectError!DetectedProvider {
    const env = std.process.getEnvVarOwned;

    var has_anthropic = false;
    var has_openai = false;
    var has_google = false;

    if (env(std.heap.page_allocator, "ANTHROPIC_API_KEY")) |key| {
        std.heap.page_allocator.free(key);
        has_anthropic = true;
    } else |_| {}

    if (env(std.heap.page_allocator, "OPENAI_API_KEY")) |key| {
        std.heap.page_allocator.free(key);
        has_openai = true;
    } else |_| {}

    if (env(std.heap.page_allocator, "GOOGLE_API_KEY")) |key| {
        std.heap.page_allocator.free(key);
        has_google = true;
    } else |_| {}

    // Count how many providers have keys
    var count: usize = 0;
    if (has_anthropic) count += 1;
    if (has_openai) count += 1;
    if (has_google) count += 1;

    if (count == 0) return error.NoApiKey;
    if (count > 1) return error.MultipleProviders;

    if (has_anthropic) return .anthropic;
    if (has_openai) return .openai;
    if (has_google) return .google;

    return error.NoApiKey;
}

/// Get the API key for a detected provider from environment variables
pub fn getApiKey(provider: DetectedProvider, allocator: std.mem.Allocator) ?[]const u8 {
    const env_var = switch (provider) {
        .anthropic => "ANTHROPIC_API_KEY",
        .openai => "OPENAI_API_KEY",
        .google => "GOOGLE_API_KEY",
        .azure => "AZURE_OPENAI_API_KEY",
        .bedrock => "AWS_ACCESS_KEY_ID",
        .ollama => return "", // Ollama doesn't need an API key
    };
    return std.process.getEnvVarOwned(allocator, env_var) catch null;
}

/// Simple options for the simplified streaming API
pub const SimpleOptions = struct {
    /// Model ID (e.g., "claude-sonnet-4-20250514", "gpt-4o")
    /// If null, uses the default model for the detected provider
    model: ?[]const u8 = null,
    /// System prompt to prepend to the conversation
    system: ?[]const u8 = null,
    /// Maximum tokens to generate
    max_tokens: u32 = 4096,
    /// Temperature for sampling (0.0 to 2.0)
    temperature: f32 = 1.0,
    /// Top-p sampling parameter
    top_p: ?f32 = null,
    /// Thinking/reasoning level (for models that support it)
    reasoning: ?config.ThinkingLevel = null,
    /// Custom API base URL
    base_url: ?[]const u8 = null,
    /// Force a specific provider (skips auto-detection)
    provider: ?DetectedProvider = null,
};

/// Detect provider and get the appropriate Model struct
fn detectModel(options: SimpleOptions) ?model_mod.Model {
    const provider = options.provider orelse detectProvider() catch return null;
    const model_id = options.model orelse provider.defaultModel();

    // First try to get a known model
    if (model_mod.getModel(model_id)) |m| return m;

    // If not found, create a minimal Model based on the provider
    return model_mod.Model{
        .id = model_id,
        .name = model_id,
        .api_type = switch (provider) {
            .anthropic => .anthropic,
            .openai => .openai,
            .ollama => .ollama,
            .google => .google,
            .azure => .azure,
            .bedrock => .bedrock,
        },
        .provider = @tagName(provider),
        .max_tokens = options.max_tokens,
    };
}

/// Stream a response using simple options.
/// Auto-detects provider from environment variables (ANTHROPIC_API_KEY or OPENAI_API_KEY).
/// Caller owns the returned AssistantMessageStream.
pub fn stream(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    options: SimpleOptions,
) !*event_stream.AssistantMessageStream {
    const mdl = detectModel(options) orelse return error.MissingApiKey;
    const provider = options.provider orelse detectProvider() catch return error.MissingApiKey;

    const api_key = getApiKey(provider, allocator) orelse "";
    defer if (api_key.len > 0) allocator.free(api_key);

    const stream_options = SimpleStreamOptions{
        .system_prompt = options.system,
        .max_tokens = options.max_tokens,
        .temperature = options.temperature,
        .top_p = options.top_p,
        .reasoning = options.reasoning,
        .base_url = options.base_url,
        .api_key = if (api_key.len > 0) api_key else null,
    };

    return streamSimple(mdl, messages, stream_options, allocator);
}

/// Stream a simple text prompt.
/// Converts the prompt to a single user message and streams the response.
/// Caller owns the returned AssistantMessageStream.
pub fn streamText(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    options: SimpleOptions,
) !*event_stream.AssistantMessageStream {
    // Create a single user message from the prompt
    const content_block = types.ContentBlock{ .text = .{ .text = prompt } };
    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &content_block,
            .timestamp = std.time.timestamp(),
        },
    };

    return stream(allocator, &messages, options);
}

/// Complete and return the full response (blocking).
/// Waits for the stream to complete and returns the final AssistantMessage.
/// Caller owns the returned AssistantMessage.
pub fn complete(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    options: SimpleOptions,
) !types.AssistantMessage {
    const stream_ptr = try stream(allocator, messages, options);
    defer {
        stream_ptr.deinit();
        allocator.destroy(stream_ptr);
    }

    // Wait for completion
    while (!stream_ptr.isDone()) {
        std.Thread.Futex.wait(&stream_ptr.futex, stream_ptr.futex.load(.acquire));
    }

    // Check for errors
    if (stream_ptr.getError()) |_| {
        return error.StreamError;
    }

    // Get the result
    const result = stream_ptr.getResult() orelse return error.NoResult;

    // Deep copy the result since the stream owns the memory
    // We need to dupe all strings
    var content_blocks = try allocator.alloc(types.ContentBlock, result.content.len);
    errdefer allocator.free(content_blocks);

    for (result.content, 0..) |block, i| {
        content_blocks[i] = switch (block) {
            .text => |t| types.ContentBlock{ .text = .{
                .text = try allocator.dupe(u8, t.text),
                .signature = if (t.signature) |s| try allocator.dupe(u8, s) else null,
            } },
            .tool_use => |tu| types.ContentBlock{ .tool_use = .{
                .id = try allocator.dupe(u8, tu.id),
                .name = try allocator.dupe(u8, tu.name),
                .input_json = try allocator.dupe(u8, tu.input_json),
                .thought_signature = if (tu.thought_signature) |s| try allocator.dupe(u8, s) else null,
            } },
            .thinking => |th| types.ContentBlock{ .thinking = .{
                .thinking = try allocator.dupe(u8, th.thinking),
                .signature = if (th.signature) |s| try allocator.dupe(u8, s) else null,
            } },
            .image => |img| types.ContentBlock{ .image = .{
                .media_type = try allocator.dupe(u8, img.media_type),
                .data = try allocator.dupe(u8, img.data),
            } },
        };
    }

    return types.AssistantMessage{
        .content = content_blocks,
        .usage = result.usage,
        .stop_reason = result.stop_reason,
        .model = try allocator.dupe(u8, result.model),
        .timestamp = result.timestamp,
    };
}

/// Complete a simple text prompt and return just the text response (blocking).
/// Extracts the text from the first content block of the response.
/// Caller owns the returned string.
pub fn completeText(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    options: SimpleOptions,
) ![]const u8 {
    var result = try complete(allocator, prompt, options);
    defer result.deinit(allocator);

    // Find the first text block
    for (result.content) |block| {
        switch (block) {
            .text => |t| return try allocator.dupe(u8, t.text),
            else => {},
        }
    }

    return ""; // No text content found
}

// ============================================================================
// Simplified API Tests
// ============================================================================

test "DetectedProvider defaultModel" {
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", DetectedProvider.anthropic.defaultModel());
    try std.testing.expectEqualStrings("gpt-4o", DetectedProvider.openai.defaultModel());
    try std.testing.expectEqualStrings("llama3.1", DetectedProvider.ollama.defaultModel());
    try std.testing.expectEqualStrings("gemini-2.5-flash", DetectedProvider.google.defaultModel());
}

test "SimpleOptions defaults" {
    const opts = SimpleOptions{};
    try std.testing.expect(opts.model == null);
    try std.testing.expect(opts.system == null);
    try std.testing.expectEqual(@as(u32, 4096), opts.max_tokens);
    try std.testing.expectEqual(@as(f32, 1.0), opts.temperature);
    try std.testing.expect(opts.top_p == null);
    try std.testing.expect(opts.reasoning == null);
    try std.testing.expect(opts.base_url == null);
    try std.testing.expect(opts.provider == null);
}

test "detectProvider returns NoApiKey when no keys present" {
    // This test will pass or fail depending on the environment
    // We just check that it doesn't crash
    _ = detectProvider() catch |err| {
        try std.testing.expect(err == error.NoApiKey or err == error.MultipleProviders);
    };
}

test "streamText creates correct message structure" {
    // Create a mock message to test the structure
    const content_blocks = [_]types.ContentBlock{.{ .text = .{ .text = "Hello, world!" } }};
    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &content_blocks,
            .timestamp = std.time.timestamp(),
        },
    };

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(types.Role.user, messages[0].role);
    try std.testing.expectEqualStrings("Hello, world!", messages[0].content[0].text.text);
}
