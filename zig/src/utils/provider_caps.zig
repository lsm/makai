const std = @import("std");

pub const ProviderType = enum {
    anthropic,
    openai_compatible,
    openai_native,
    google,
    bedrock,
    azure,
    ollama,
    unknown,
};

pub const ProviderCapabilities = struct {
    streaming: bool = true,

    extended_thinking: bool = false,

    prompt_caching: bool = false,

    vision: bool = false,

    function_calling: bool = true,

    requires_mistral_tool_ids: bool = false,

    supports_reasoning_effort: bool = false,

    reasoning_field: ?[]const u8 = null,

    provider_type: ProviderType = .unknown,

    supports_developer_role: bool = false,

    max_tokens_field: []const u8 = "max_tokens",

    thinking_format: enum { openai, zai, qwen } = .openai,

    requires_thinking_as_text: bool = false,

    requires_assistant_after_tool: bool = false,

    requires_tool_result_name: bool = false,
};

pub fn isGitHubCopilot(base_url: ?[]const u8) bool {
    const url = base_url orelse return false;
    return std.mem.find(u8, url, "api.githubcopilot.com") != null;
}

pub fn isMistral(base_url: ?[]const u8) bool {
    const url = base_url orelse return false;
    return std.mem.find(u8, url, "api.mistral.ai") != null;
}

pub fn isGroq(base_url: ?[]const u8) bool {
    const url = base_url orelse return false;
    return std.mem.find(u8, url, "api.groq.com") != null;
}

pub fn isCerebras(base_url: ?[]const u8) bool {
    const url = base_url orelse return false;
    return std.mem.find(u8, url, "api.cerebras.ai") != null;
}

pub fn isZai(base_url: ?[]const u8) bool {
    const url = base_url orelse return false;
    return std.mem.find(u8, url, "api.zukijourney.com") != null or std.mem.find(u8, url, "zai") != null;
}

pub fn isOpenRouter(base_url: ?[]const u8) bool {
    const url = base_url orelse return false;
    return std.mem.find(u8, url, "openrouter.ai") != null;
}

pub fn isChutes(base_url: ?[]const u8) bool {
    const url = base_url orelse return false;
    return std.mem.find(u8, url, "chutes.ai") != null;
}

pub fn isQwen(base_url: ?[]const u8) bool {
    const url = base_url orelse return false;
    return std.mem.find(u8, url, "dashscope") != null or std.mem.find(u8, url, "qwen") != null;
}

pub fn isDeepSeek(base_url: ?[]const u8) bool {
    const url = base_url orelse return false;
    return std.mem.find(u8, url, "api.deepseek.com") != null;
}

pub fn isOpenAINative(base_url: ?[]const u8) bool {
    const url = base_url orelse return false;
    return std.mem.find(u8, url, "api.openai.com") != null;
}

pub fn isAnthropic(base_url: ?[]const u8) bool {
    const url = base_url orelse return false;
    return std.mem.find(u8, url, "api.anthropic.com") != null;
}

pub fn detectProviderType(base_url: ?[]const u8) ProviderType {
    const url = base_url orelse return .unknown;

    if (isAnthropic(url)) return .anthropic;
    if (isOpenAINative(url)) return .openai_native;
    if (isGitHubCopilot(url)) return .openai_compatible;
    if (isMistral(url)) return .openai_compatible;
    if (isGroq(url)) return .openai_compatible;
    if (isCerebras(url)) return .openai_compatible;
    if (isZai(url)) return .openai_compatible;
    if (isOpenRouter(url)) return .openai_compatible;
    if (std.mem.find(u8, url, "generativelanguage.googleapis.com") != null) return .google;
    if (std.mem.find(u8, url, "aiplatform.googleapis.com") != null) return .google;
    if (std.mem.find(u8, url, "bedrock-runtime.") != null or std.mem.find(u8, url, "bedrock.") != null) return .bedrock;
    if (std.mem.find(u8, url, ".openai.azure.com") != null or std.mem.find(u8, url, "cognitiveservices.azure.com") != null) return .azure;
    if (std.mem.find(u8, url, "localhost:11434") != null or std.mem.find(u8, url, "127.0.0.1:11434") != null or std.mem.find(u8, url, "ollama") != null) return .ollama;

    if (url.len > 0) return .openai_compatible;

    return .unknown;
}

pub fn detectCapabilities(base_url: ?[]const u8) ProviderCapabilities {
    const provider_type = detectProviderType(base_url);

    return switch (provider_type) {
        .anthropic => .{
            .extended_thinking = true,
            .prompt_caching = true,
            .vision = true,
            .function_calling = true,
            .provider_type = .anthropic,
        },
        .openai_native => capabilities: {
            var caps: ProviderCapabilities = .{
                .extended_thinking = true,
                .prompt_caching = true,
                .vision = true,
                .function_calling = true,
                .supports_reasoning_effort = true,
                .provider_type = .openai_native,
                .supports_developer_role = true,
                .max_tokens_field = "max_completion_tokens",
            };
            if (base_url) |url| {
                if (isZai(url)) {
                    caps.thinking_format = .zai;
                }
            }
            break :capabilities caps;
        },
        .openai_compatible => capabilities: {
            var caps: ProviderCapabilities = .{
                .vision = true,
                .function_calling = true,
                .provider_type = .openai_compatible,
            };
            if (base_url) |url| {
                caps.requires_mistral_tool_ids = isMistral(url);
                if (isMistral(url) or isChutes(url)) {
                    caps.max_tokens_field = "max_tokens";
                }
                if (isZai(url)) {
                    caps.thinking_format = .zai;
                }
                if (isQwen(url)) {
                    caps.thinking_format = .qwen;
                }
                if (isDeepSeek(url)) {
                    caps.requires_thinking_as_text = true;
                }
            }
            break :capabilities caps;
        },
        .google => .{
            .extended_thinking = true,
            .prompt_caching = true,
            .vision = true,
            .function_calling = true,
            .provider_type = .google,
        },
        .bedrock => .{
            .extended_thinking = true,
            .prompt_caching = true,
            .vision = true,
            .function_calling = true,
            .provider_type = .bedrock,
        },
        .azure => .{
            .extended_thinking = true,
            .prompt_caching = true,
            .vision = true,
            .function_calling = true,
            .provider_type = .azure,
        },
        .ollama => .{
            .vision = true,
            .function_calling = true,
            .provider_type = .ollama,
        },
        .unknown => .{},
    };
}

test "isGitHubCopilot detection" {
    try std.testing.expect(isGitHubCopilot("https://api.githubcopilot.com/v1/chat"));
    try std.testing.expect(!isGitHubCopilot("https://api.openai.com/v1/chat"));
    try std.testing.expect(!isGitHubCopilot(null));
}

test "isMistral detection" {
    try std.testing.expect(isMistral("https://api.mistral.ai/v1/chat/completions"));
    try std.testing.expect(!isMistral("https://api.openai.com/v1/chat"));
    try std.testing.expect(!isMistral(null));
}

test "isGroq detection" {
    try std.testing.expect(isGroq("https://api.groq.com/openai/v1/chat/completions"));
    try std.testing.expect(!isGroq("https://api.openai.com/v1/chat"));
    try std.testing.expect(!isGroq(null));
}

test "detectProviderType Anthropic" {
    try std.testing.expectEqual(ProviderType.anthropic, detectProviderType("https://api.anthropic.com/v1/messages"));
}

test "detectProviderType OpenAI native" {
    try std.testing.expectEqual(ProviderType.openai_native, detectProviderType("https://api.openai.com/v1/chat/completions"));
}

test "detectProviderType Mistral" {
    try std.testing.expectEqual(ProviderType.openai_compatible, detectProviderType("https://api.mistral.ai/v1/chat/completions"));
}

test "detectCapabilities Anthropic" {
    const caps = detectCapabilities("https://api.anthropic.com/v1/messages");
    try std.testing.expect(caps.extended_thinking);
    try std.testing.expect(caps.prompt_caching);
    try std.testing.expect(caps.vision);
    try std.testing.expect(!caps.requires_mistral_tool_ids);
}

test "detectCapabilities Mistral has tool ID requirement" {
    const caps = detectCapabilities("https://api.mistral.ai/v1/chat/completions");
    try std.testing.expect(caps.requires_mistral_tool_ids);
    try std.testing.expectEqual(ProviderType.openai_compatible, caps.provider_type);
}

test "detectCapabilities unknown returns defaults" {
    const caps = detectCapabilities(null);
    try std.testing.expect(!caps.extended_thinking);
    try std.testing.expect(!caps.prompt_caching);
    try std.testing.expectEqual(ProviderType.unknown, caps.provider_type);
}
