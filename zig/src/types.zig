const std = @import("std");

// Tool parameter schema (JSON Schema subset)
pub const ToolParameter = struct {
    name: []const u8,
    param_type: []const u8, // "string", "number", "boolean", "object", "array"
    description: ?[]const u8 = null,
    required: bool = false,
};

// Tool definition for function calling
pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    parameters: []const ToolParameter = &[_]ToolParameter{},
};

// Tool choice options
pub const ToolChoice = union(enum) {
    auto,
    none,
    any,
    specific: []const u8, // tool name
};

// Content block types
pub const TextBlock = struct {
    text: []const u8,
    signature: ?[]const u8 = null,
};

pub const ToolUseBlock = struct {
    id: []const u8,
    name: []const u8,
    input_json: []const u8,
    thought_signature: ?[]const u8 = null,
};

pub const ThinkingBlock = struct {
    thinking: []const u8,
    signature: ?[]const u8 = null,
};

pub const ImageBlock = struct {
    media_type: []const u8, // "image/jpeg", "image/png", etc.
    data: []const u8, // base64 encoded
};

// Tool result content - supports text or images in tool results
pub const ToolResultContent = union(enum) {
    text: []const u8,
    image: ImageBlock,
};

// Tool result block - represents a tool/function call result
pub const ToolResultBlock = struct {
    tool_call_id: []const u8,
    content: []const ToolResultContent, // Supports text and images
    is_error: bool = false,
};

// ContentBlock - tagged union
pub const ContentBlock = union(enum) {
    text: TextBlock,
    tool_use: ToolUseBlock,
    thinking: ThinkingBlock,
    image: ImageBlock,
};

// Usage tracking
pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,

    pub fn add(self: *Usage, other: Usage) void {
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
        self.cache_read_tokens += other.cache_read_tokens;
        self.cache_write_tokens += other.cache_write_tokens;
    }

    pub fn total(self: Usage) u64 {
        return self.input_tokens + self.output_tokens +
               self.cache_read_tokens + self.cache_write_tokens;
    }
};

// Message roles
pub const Role = enum {
    user,
    assistant,
    tool_result,
};

// Stop reasons
pub const StopReason = enum {
    stop,
    length,
    tool_use,
    content_filter,
    @"error",
    aborted,
};

// Basic message
pub const Message = struct {
    role: Role,
    content: []const ContentBlock,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    is_error: bool = false,
    /// Stop reason for assistant messages (used for filtering aborted/error messages)
    stop_reason: ?StopReason = null,
    timestamp: i64,
};

// Assistant message with full metadata
pub const AssistantMessage = struct {
    content: []const ContentBlock,
    usage: Usage,
    stop_reason: StopReason,
    model: []const u8,
    timestamp: i64,

    pub fn deinit(self: *AssistantMessage, allocator: std.mem.Allocator) void {
        // Free the model string
        allocator.free(self.model);

        // Free all strings within each ContentBlock
        for (self.content) |block| {
            switch (block) {
                .text => |text_block| {
                    // Only free non-empty text - empty slices may be static
                    if (text_block.text.len > 0) allocator.free(text_block.text);
                    if (text_block.signature) |sig| {
                        allocator.free(sig);
                    }
                },
                .tool_use => |tool_block| {
                    allocator.free(tool_block.id);
                    allocator.free(tool_block.name);
                    // Only free non-empty input_json - empty slices may be static
                    if (tool_block.input_json.len > 0) allocator.free(tool_block.input_json);
                    if (tool_block.thought_signature) |sig| {
                        allocator.free(sig);
                    }
                },
                .thinking => |thinking_block| {
                    // Only free non-empty thinking - empty slices may be static
                    if (thinking_block.thinking.len > 0) allocator.free(thinking_block.thinking);
                    if (thinking_block.signature) |sig| {
                        allocator.free(sig);
                    }
                },
                .image => |image_block| {
                    allocator.free(image_block.media_type);
                    allocator.free(image_block.data);
                },
            }
        }

        // Free the content array itself
        allocator.free(self.content);
    }
};

// Event structures for streaming
pub const StartEvent = struct {
    model: []const u8,
    input_tokens: u64 = 0,
};

pub const ContentIndexEvent = struct {
    index: usize,
};

pub const DeltaEvent = struct {
    index: usize,
    delta: []const u8,
};

pub const ContentEndEvent = struct {
    index: usize,
};

pub const ToolCallStartEvent = struct {
    index: usize,
    id: []const u8,
    name: []const u8,
};

pub const ToolCallEndEvent = struct {
    index: usize,
    input_json: []const u8,
};

pub const DoneEvent = struct {
    usage: Usage,
    stop_reason: StopReason,
};

pub const ErrorEvent = struct {
    message: []const u8,
};

// MessageEvent - 13-variant tagged union for streaming
pub const MessageEvent = union(enum) {
    start: StartEvent,
    text_start: ContentIndexEvent,
    text_delta: DeltaEvent,
    text_end: ContentEndEvent,
    thinking_start: ContentIndexEvent,
    thinking_delta: DeltaEvent,
    thinking_end: ContentEndEvent,
    toolcall_start: ToolCallStartEvent,
    toolcall_delta: DeltaEvent,
    toolcall_end: ToolCallEndEvent,
    done: DoneEvent,
    @"error": ErrorEvent,
    ping: void,
};

// Tests
test "Usage add and total" {
    var usage1 = Usage{
        .input_tokens = 100,
        .output_tokens = 50,
        .cache_read_tokens = 20,
        .cache_write_tokens = 10,
    };

    const usage2 = Usage{
        .input_tokens = 50,
        .output_tokens = 30,
        .cache_read_tokens = 10,
        .cache_write_tokens = 5,
    };

    usage1.add(usage2);

    try std.testing.expectEqual(@as(u64, 150), usage1.input_tokens);
    try std.testing.expectEqual(@as(u64, 80), usage1.output_tokens);
    try std.testing.expectEqual(@as(u64, 30), usage1.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 15), usage1.cache_write_tokens);
    try std.testing.expectEqual(@as(u64, 275), usage1.total());
}

test "ContentBlock variants" {
    const text_block = ContentBlock{ .text = TextBlock{ .text = "hello" } };
    const tool_block = ContentBlock{ .tool_use = ToolUseBlock{
        .id = "1",
        .name = "search",
        .input_json = "{}",
    } };
    const thinking_block = ContentBlock{ .thinking = ThinkingBlock{ .thinking = "thinking..." } };

    try std.testing.expect(std.meta.activeTag(text_block) == .text);
    try std.testing.expect(std.meta.activeTag(tool_block) == .tool_use);
    try std.testing.expect(std.meta.activeTag(thinking_block) == .thinking);
}

test "MessageEvent variants" {
    const start_event = MessageEvent{ .start = StartEvent{ .model = "claude-3" } };
    const text_delta = MessageEvent{ .text_delta = DeltaEvent{ .index = 0, .delta = "hello" } };
    const done_event = MessageEvent{ .done = DoneEvent{
        .usage = Usage{},
        .stop_reason = .stop,
    } };

    try std.testing.expect(std.meta.activeTag(start_event) == .start);
    try std.testing.expect(std.meta.activeTag(text_delta) == .text_delta);
    try std.testing.expect(std.meta.activeTag(done_event) == .done);
}

test "Tool and ToolParameter" {
    const param = ToolParameter{
        .name = "location",
        .param_type = "string",
        .description = "City name",
        .required = true,
    };

    try std.testing.expectEqualStrings("location", param.name);
    try std.testing.expectEqualStrings("string", param.param_type);
    try std.testing.expectEqualStrings("City name", param.description.?);
    try std.testing.expect(param.required);

    const tool = Tool{
        .name = "get_weather",
        .description = "Get weather info",
        .parameters = &[_]ToolParameter{param},
    };

    try std.testing.expectEqualStrings("get_weather", tool.name);
    try std.testing.expectEqualStrings("Get weather info", tool.description.?);
    try std.testing.expectEqual(@as(usize, 1), tool.parameters.len);
}

test "ToolChoice variants" {
    const auto_choice = ToolChoice{ .auto = {} };
    const none_choice = ToolChoice{ .none = {} };
    const any_choice = ToolChoice{ .any = {} };
    const specific_choice = ToolChoice{ .specific = "get_weather" };

    try std.testing.expect(std.meta.activeTag(auto_choice) == .auto);
    try std.testing.expect(std.meta.activeTag(none_choice) == .none);
    try std.testing.expect(std.meta.activeTag(any_choice) == .any);
    try std.testing.expect(std.meta.activeTag(specific_choice) == .specific);
    try std.testing.expectEqualStrings("get_weather", specific_choice.specific);
}

test "ImageBlock" {
    const image = ImageBlock{
        .media_type = "image/jpeg",
        .data = "base64data",
    };

    try std.testing.expectEqualStrings("image/jpeg", image.media_type);
    try std.testing.expectEqualStrings("base64data", image.data);
}

test "ContentBlock with image" {
    const image_block = ContentBlock{ .image = ImageBlock{
        .media_type = "image/png",
        .data = "iVBORw0KGgo=",
    } };

    try std.testing.expect(std.meta.activeTag(image_block) == .image);
    try std.testing.expectEqualStrings("image/png", image_block.image.media_type);
    try std.testing.expectEqualStrings("iVBORw0KGgo=", image_block.image.data);
}

test "TextBlock with signature" {
    const block = TextBlock{ .text = "hello", .signature = "sig123" };
    try std.testing.expectEqualStrings("sig123", block.signature.?);

    const block_no_sig = TextBlock{ .text = "hello" };
    try std.testing.expect(block_no_sig.signature == null);
}

test "ThinkingBlock with signature" {
    const block = ThinkingBlock{ .thinking = "reasoning", .signature = "think_sig" };
    try std.testing.expectEqualStrings("think_sig", block.signature.?);
}

test "ToolUseBlock with thought signature" {
    const block = ToolUseBlock{ .id = "id1", .name = "tool1", .input_json = "{}", .thought_signature = "thought_sig" };
    try std.testing.expectEqualStrings("thought_sig", block.thought_signature.?);
}

test "Message with tool result metadata" {
    const msg = Message{
        .role = .tool_result,
        .content = &[_]ContentBlock{},
        .tool_call_id = "call_123",
        .tool_name = "bash",
        .is_error = true,
        .timestamp = 1000,
    };
    try std.testing.expectEqualStrings("call_123", msg.tool_call_id.?);
    try std.testing.expectEqualStrings("bash", msg.tool_name.?);
    try std.testing.expect(msg.is_error);
}

test "Message defaults backward compatible" {
    const msg = Message{
        .role = .user,
        .content = &[_]ContentBlock{},
        .timestamp = 1000,
    };
    try std.testing.expect(msg.tool_name == null);
    try std.testing.expect(!msg.is_error);
    try std.testing.expect(msg.tool_call_id == null);
}

test "ToolResultContent text variant" {
    const content = ToolResultContent{ .text = "Tool executed successfully" };
    try std.testing.expect(std.meta.activeTag(content) == .text);
    try std.testing.expectEqualStrings("Tool executed successfully", content.text);
}

test "ToolResultContent image variant" {
    const content = ToolResultContent{ .image = ImageBlock{
        .media_type = "image/png",
        .data = "iVBORw0KGgo=",
    } };
    try std.testing.expect(std.meta.activeTag(content) == .image);
    try std.testing.expectEqualStrings("image/png", content.image.media_type);
}

test "ToolResultBlock with text content" {
    const result = ToolResultBlock{
        .tool_call_id = "call_123",
        .content = &[_]ToolResultContent{
            ToolResultContent{ .text = "Result text" },
        },
        .is_error = false,
    };
    try std.testing.expectEqualStrings("call_123", result.tool_call_id);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
}

test "ToolResultBlock with mixed content" {
    const contents = [_]ToolResultContent{
        ToolResultContent{ .text = "Here is the screenshot:" },
        ToolResultContent{ .image = ImageBlock{ .media_type = "image/png", .data = "abc123" } },
    };
    const result = ToolResultBlock{
        .tool_call_id = "call_456",
        .content = &contents,
        .is_error = false,
    };
    try std.testing.expectEqual(@as(usize, 2), result.content.len);
    try std.testing.expect(std.meta.activeTag(result.content[0]) == .text);
    try std.testing.expect(std.meta.activeTag(result.content[1]) == .image);
}

test "ToolResultBlock error case" {
    const result = ToolResultBlock{
        .tool_call_id = "call_789",
        .content = &[_]ToolResultContent{
            ToolResultContent{ .text = "Error: File not found" },
        },
        .is_error = true,
    };
    try std.testing.expect(result.is_error);
}
