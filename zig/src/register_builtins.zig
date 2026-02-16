const std = @import("std");
const api_registry = @import("api_registry");
const anthropic_api = @import("anthropic_messages_api");
const openai_completions_api = @import("openai_completions_api");
const openai_responses_api = @import("openai_responses_api");
const azure_api = @import("azure_openai_responses_api");
const google_api = @import("google_generative_api");
const ollama_api = @import("ollama_api");

pub fn registerBuiltInApiProviders(registry: *api_registry.ApiRegistry) !void {
    try anthropic_api.registerAnthropicMessagesApiProvider(registry);
    try openai_completions_api.registerOpenAICompletionsApiProvider(registry);
    try openai_responses_api.registerOpenAIResponsesApiProvider(registry);
    try azure_api.registerAzureOpenAIResponsesApiProvider(registry);
    try openai_responses_api.registerOpenAICodexResponsesApiProvider(registry);
    try google_api.registerGoogleGenerativeApiProvider(registry);
    try google_api.registerGoogleGeminiCliApiProvider(registry);
    try ollama_api.registerOllamaApiProvider(registry);
}

test "registerBuiltInApiProviders registers expected api providers" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registerBuiltInApiProviders(&registry);

    try std.testing.expect(registry.getApiProvider("anthropic-messages") != null);
    try std.testing.expect(registry.getApiProvider("openai-completions") != null);
    try std.testing.expect(registry.getApiProvider("openai-responses") != null);
    try std.testing.expect(registry.getApiProvider("azure-openai-responses") != null);
    try std.testing.expect(registry.getApiProvider("openai-codex-responses") != null);
    try std.testing.expect(registry.getApiProvider("google-generative-ai") != null);
    try std.testing.expect(registry.getApiProvider("google-gemini-cli") != null);
    try std.testing.expect(registry.getApiProvider("ollama") != null);
}
