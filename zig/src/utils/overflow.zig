const std = @import("std");
const ai_types = @import("ai_types");

/// Check if an AssistantMessage represents a context overflow error.
///
/// Provider-specific patterns to detect:
/// - Anthropic: "prompt is too long"
/// - OpenAI: "exceeds the context window"
/// - Google: "input token count.*exceeds the maximum"
/// - xAI: "maximum prompt length is"
/// - Groq: "reduce the length"
/// - OpenRouter: "maximum context length"
/// - Cerebras/Mistral: "400/413 status code (no body)"
/// - GitHub Copilot: "exceeds the limit"
/// - llama.cpp: "exceeds the available context"
/// - LM Studio: "greater than the context length"
/// - MiniMax: "context window exceeds limit"
/// - Kimi: "exceeded model token limit"
pub fn isContextOverflow(message: ai_types.AssistantMessage, context_window: ?u64) bool {
    // Case 1: Check error message patterns
    if (message.stop_reason == .@"error") {
        if (message.getErrorMessage()) |err_msg| {
            if (matchesOverflowPattern(err_msg)) {
                return true;
            }
        }
    }

    // Case 2: Silent overflow (z.ai style) - successful but usage exceeds context
    if (context_window) |window| {
        if (message.stop_reason == .stop) {
            const input_tokens = message.usage.input + message.usage.cache_read;
            if (input_tokens > window) {
                return true;
            }
        }
    }

    return false;
}

/// Check if error message matches known overflow patterns
fn matchesOverflowPattern(err_msg: []const u8) bool {
    // Use std.mem.indexOfPosScalar for case-insensitive matching
    // We use std.ascii.lower to do case-insensitive comparisons

    // Anthropic: "prompt is too long"
    if (indexOfCaseInsensitive(err_msg, "prompt is too long")) |_| return true;

    // Amazon Bedrock: "input is too long for requested model"
    if (indexOfCaseInsensitive(err_msg, "input is too long for requested model")) |_| return true;

    // OpenAI: "exceeds the context window"
    if (indexOfCaseInsensitive(err_msg, "exceeds the context window")) |_| return true;

    // Google: "input token count" + "exceeds the maximum"
    if (indexOfCaseInsensitive(err_msg, "input token count")) |_| {
        if (indexOfCaseInsensitive(err_msg, "exceeds the maximum")) |_| return true;
    }

    // xAI: "maximum prompt length is"
    if (indexOfCaseInsensitive(err_msg, "maximum prompt length is")) |_| return true;

    // Groq: "reduce the length of the messages"
    if (indexOfCaseInsensitive(err_msg, "reduce the length of the messages")) |_| return true;

    // OpenRouter: "maximum context length is"
    if (indexOfCaseInsensitive(err_msg, "maximum context length is")) |_| return true;

    // GitHub Copilot: "exceeds the limit of"
    if (indexOfCaseInsensitive(err_msg, "exceeds the limit of")) |_| return true;

    // llama.cpp: "exceeds the available context size"
    if (indexOfCaseInsensitive(err_msg, "exceeds the available context size")) |_| return true;

    // LM Studio: "greater than the context length"
    if (indexOfCaseInsensitive(err_msg, "greater than the context length")) |_| return true;

    // MiniMax: "context window exceeds limit"
    if (indexOfCaseInsensitive(err_msg, "context window exceeds limit")) |_| return true;

    // Kimi: "exceeded model token limit"
    if (indexOfCaseInsensitive(err_msg, "exceeded model token limit")) |_| return true;

    // Generic fallbacks
    // "context_length_exceeded" or "context length exceeded"
    if (indexOfCaseInsensitive(err_msg, "context_length_exceeded")) |_| return true;
    if (indexOfCaseInsensitive(err_msg, "context length exceeded")) |_| return true;

    // "too many tokens"
    if (indexOfCaseInsensitive(err_msg, "too many tokens")) |_| return true;

    // "token limit exceeded"
    if (indexOfCaseInsensitive(err_msg, "token limit exceeded")) |_| return true;

    // Cerebras and Mistral return 400/413 with no body for context overflow
    // Note: 429 is rate limiting, NOT context overflow
    if (matchesStatusNoBody(err_msg, "400")) return true;
    if (matchesStatusNoBody(err_msg, "413")) return true;

    return false;
}

/// Case-insensitive substring search
fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

/// Check for "400/413 status code (no body)" pattern
fn matchesStatusNoBody(err_msg: []const u8, status_code: []const u8) bool {
    // Pattern: "400 (no body)" or "400 status code (no body)" or "413 (no body)"
    if (indexOfCaseInsensitive(err_msg, status_code)) |idx| {
        // Check if followed by "(no body)" (possibly with "status code" in between)
        const rest = err_msg[idx + status_code.len ..];
        if (indexOfCaseInsensitive(rest, "(no body)")) |_| return true;
        if (indexOfCaseInsensitive(rest, "status code (no body)")) |_| return true;
    }
    return false;
}

test "isContextOverflow detects Anthropic pattern" {
    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "" } }};
    const message = ai_types.AssistantMessage{
        .content = &content,
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude-3-opus",
        .usage = .{ .input = 213462 },
        .stop_reason = .@"error",
        .error_message = ai_types.OwnedSlice(u8).initBorrowed("prompt is too long: 213462 tokens > 200000 maximum"),
        .timestamp = 0,
    };

    try std.testing.expect(isContextOverflow(message, null));
}

test "isContextOverflow detects OpenAI pattern" {
    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "" } }};
    const message = ai_types.AssistantMessage{
        .content = &content,
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4o",
        .usage = .{ .input = 150000 },
        .stop_reason = .@"error",
        .error_message = ai_types.OwnedSlice(u8).initBorrowed("Your input exceeds the context window of this model"),
        .timestamp = 0,
    };

    try std.testing.expect(isContextOverflow(message, null));
}

test "isContextOverflow detects xAI pattern" {
    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "" } }};
    const message = ai_types.AssistantMessage{
        .content = &content,
        .api = "openai-completions",
        .provider = "xai",
        .model = "grok-2",
        .usage = .{ .input = 537812 },
        .stop_reason = .@"error",
        .error_message = ai_types.OwnedSlice(u8).initBorrowed("This model's maximum prompt length is 131072 but the request contains 537812 tokens"),
        .timestamp = 0,
    };

    try std.testing.expect(isContextOverflow(message, null));
}

test "isContextOverflow detects Groq pattern" {
    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "" } }};
    const message = ai_types.AssistantMessage{
        .content = &content,
        .api = "openai-completions",
        .provider = "groq",
        .model = "llama-3",
        .usage = .{},
        .stop_reason = .@"error",
        .error_message = ai_types.OwnedSlice(u8).initBorrowed("Please reduce the length of the messages or completion"),
        .timestamp = 0,
    };

    try std.testing.expect(isContextOverflow(message, null));
}

test "isContextOverflow detects Google pattern" {
    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "" } }};
    const message = ai_types.AssistantMessage{
        .content = &content,
        .api = "google-generative-ai",
        .provider = "google",
        .model = "gemini-2.5-flash",
        .usage = .{ .input = 1196265 },
        .stop_reason = .@"error",
        .error_message = ai_types.OwnedSlice(u8).initBorrowed("The input token count (1196265) exceeds the maximum number of tokens allowed (1048575)"),
        .timestamp = 0,
    };

    try std.testing.expect(isContextOverflow(message, null));
}

test "isContextOverflow detects llama.cpp pattern" {
    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "" } }};
    const message = ai_types.AssistantMessage{
        .content = &content,
        .api = "openai-completions",
        .provider = "llamacpp",
        .model = "llama-3",
        .usage = .{},
        .stop_reason = .@"error",
        .error_message = ai_types.OwnedSlice(u8).initBorrowed("the request exceeds the available context size, try increasing it"),
        .timestamp = 0,
    };

    try std.testing.expect(isContextOverflow(message, null));
}

test "isContextOverflow detects Cerebras/Mistral 400 status code (no body)" {
    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "" } }};
    const message = ai_types.AssistantMessage{
        .content = &content,
        .api = "openai-completions",
        .provider = "cerebras",
        .model = "llama-3",
        .usage = .{},
        .stop_reason = .@"error",
        .error_message = ai_types.OwnedSlice(u8).initBorrowed("400 status code (no body)"),
        .timestamp = 0,
    };

    try std.testing.expect(isContextOverflow(message, null));
}

test "isContextOverflow detects Cerebras/Mistral 413 status code (no body)" {
    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "" } }};
    const message = ai_types.AssistantMessage{
        .content = &content,
        .api = "openai-completions",
        .provider = "mistral",
        .model = "mistral-large",
        .usage = .{},
        .stop_reason = .@"error",
        .error_message = ai_types.OwnedSlice(u8).initBorrowed("413 (no body)"),
        .timestamp = 0,
    };

    try std.testing.expect(isContextOverflow(message, null));
}

test "isContextOverflow detects silent overflow with context_window" {
    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "Response text" } }};
    const message = ai_types.AssistantMessage{
        .content = &content,
        .api = "openai-completions",
        .provider = "zai",
        .model = "model-x",
        .usage = .{ .input = 250000, .cache_read = 10000 },
        .stop_reason = .stop, // Successful response
        .error_message = ai_types.OwnedSlice(u8).initBorrowed(""),
        .timestamp = 0,
    };

    // Input + cache_read = 260000 > 200000 context window
    try std.testing.expect(isContextOverflow(message, 200000));
}

test "isContextOverflow returns false for normal errors" {
    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "" } }};

    // Rate limit error (429) - should NOT be detected as overflow
    const rate_limit_msg = ai_types.AssistantMessage{
        .content = &content,
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4o",
        .usage = .{},
        .stop_reason = .@"error",
        .error_message = ai_types.OwnedSlice(u8).initBorrowed("429 status code (no body)"), // Rate limiting
        .timestamp = 0,
    };
    try std.testing.expect(!isContextOverflow(rate_limit_msg, null));

    // Generic API error
    const api_error_msg = ai_types.AssistantMessage{
        .content = &content,
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude-3-opus",
        .usage = .{},
        .stop_reason = .@"error",
        .error_message = ai_types.OwnedSlice(u8).initBorrowed("API error: service unavailable"),
        .timestamp = 0,
    };
    try std.testing.expect(!isContextOverflow(api_error_msg, null));

    // Normal successful response within context window
    const success_msg = ai_types.AssistantMessage{
        .content = &content,
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4o",
        .usage = .{ .input = 50000 },
        .stop_reason = .stop,
        .error_message = ai_types.OwnedSlice(u8).initBorrowed(""),
        .timestamp = 0,
    };
    try std.testing.expect(!isContextOverflow(success_msg, 128000));
}

test "isContextOverflow case insensitive matching" {
    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "" } }};

    // Test uppercase
    const uppercase_msg = ai_types.AssistantMessage{
        .content = &content,
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude-3-opus",
        .usage = .{},
        .stop_reason = .@"error",
        .error_message = ai_types.OwnedSlice(u8).initBorrowed("PROMPT IS TOO LONG: exceeded limit"),
        .timestamp = 0,
    };
    try std.testing.expect(isContextOverflow(uppercase_msg, null));

    // Test mixed case
    const mixedcase_msg = ai_types.AssistantMessage{
        .content = &content,
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4o",
        .usage = .{},
        .stop_reason = .@"error",
        .error_message = ai_types.OwnedSlice(u8).initBorrowed("Your Input Exceeds The Context Window"),
        .timestamp = 0,
    };
    try std.testing.expect(isContextOverflow(mixedcase_msg, null));
}

test "indexOfCaseInsensitive finds substrings correctly" {
    try std.testing.expect(indexOfCaseInsensitive("hello world", "world").? == 6);
    try std.testing.expect(indexOfCaseInsensitive("Hello World", "WORLD").? == 6);
    try std.testing.expect(indexOfCaseInsensitive("HELLO WORLD", "hello").? == 0);
    try std.testing.expect(indexOfCaseInsensitive("hello", "world") == null);
    try std.testing.expect(indexOfCaseInsensitive("hi", "hello") == null);
}
