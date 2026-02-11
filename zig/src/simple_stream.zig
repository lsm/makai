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
