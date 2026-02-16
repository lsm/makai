# Implementation Plan: Fix 9 Critical Gaps in Zig AI Tool Call Parsing

## Overview

This plan addresses 9 verified gaps between the Zig implementation and the TypeScript reference implementation. The fixes follow the patterns established in the TS codebase from `badlogic/pi-mono`.

---

## Gap Analysis Summary

| # | Gap | File(s) Affected | Priority |
|---|-----|------------------|----------|
| 1 | Anthropic tool calls not parsed | `anthropic_messages_api.zig` | P0 |
| 2 | OpenAI Completions tool calls not parsed | `openai_completions_api.zig` | P0 |
| 3 | OpenAI Responses tool calls not parsed | `openai_responses_api.zig` | P0 |
| 4 | Google tool calls not parsed | `google_generative_api.zig` | P0 |
| 5 | Ollama tool calls not parsed | `ollama_api.zig` | P0 |
| 6 | Cost calculation never invoked | All providers | P1 |
| 7 | Anthropic max_tokens default differs | `anthropic_messages_api.zig` | P2 |
| 8 | OpenAI Completions missing store:false | `openai_completions_api.zig` | P2 |
| 9 | OpenAI Responses missing store:false and caching | `openai_responses_api.zig` | P2 |

---

## Phase 1: Core Infrastructure (Shared Utilities)

### 1.1 Streaming JSON Accumulator

**File:** `zig/src/streaming_json.zig` (NEW)

Create a utility for accumulating partial JSON during tool call streaming:

```zig
/// Accumulates partial JSON strings and provides best-effort parsing
pub const StreamingJsonAccumulator = struct {
    buffer: std.ArrayList(u8),
    
    pub fn init(allocator: std.mem.Allocator) Self
    pub fn deinit(self: *Self) void
    pub fn append(self: *Self, delta: []const u8) !void
    pub fn getBuffer(self: Self) []const u8
    pub fn parseCurrent(self: Self, allocator: std.mem.Allocator) ?std.json.Value
};
```

**Key insight from TS:** Uses `partial-json` library to parse incomplete JSON. In Zig, we'll do best-effort parsing with graceful fallback.

### 1.2 Tool Call Tracker

**File:** `zig/src/tool_call_tracker.zig` (NEW)

Utility for tracking in-progress tool calls across streaming events:

```zig
/// Tracks tool calls being accumulated during streaming
pub const ToolCallTracker = struct {
    calls: std.AutoHashMap(usize, InProgressToolCall),
    next_index: usize,
    
    pub const InProgressToolCall = struct {
        id: []const u8,
        name: []const u8,
        json_accumulator: StreamingJsonAccumulator,
        api_index: usize, // Index from API (for Anthropic/OpenAI tracking)
    };
    
    pub fn init(allocator: std.mem.Allocator) Self
    pub fn deinit(self: *Self) void
    pub fn startCall(self: *Self, api_index: usize, id: []const u8, name: []const u8) !usize
    pub fn appendDelta(self: *Self, api_index: usize, delta: []const u8) !void
    pub fn completeCall(self: *Self, api_index: usize, allocator: std.mem.Allocator) ?ai_types.ToolCall
};
```

---

## Phase 2: Provider-Specific Fixes (P0)

### 2.1 Anthropic (`anthropic_messages_api.zig`)

**Current State:**
- Lines 772-774: `tool_use` in `content_block_start` does nothing
- Lines 795-797: `input_json` delta does nothing
- Lines 840-842: `tool_use` in `content_block_stop` does nothing

**Fix:**

1. Add tool call accumulators alongside text/thinking:
```zig
var tool_call_tracker = ToolCallTracker.init(allocator);
defer tool_call_tracker.deinit();
```

2. In `content_block_start` for `tool_use`:
```zig
.tool_use => {
    // Extract tool_use_id and name from content_block
    const tool_id = content_block.object.get("id");
    const tool_name = content_block.object.get("name");
    
    const content_idx = content_blocks.items.len;
    try tool_call_tracker.startCall(cbs.index, tool_id, tool_name);
    
    stream.push(.{ .toolcall_start = .{
        .content_index = content_idx,
        .partial = createPartialMessage(model),
    }}) catch {};
}
```

3. In `content_block_delta` for `input_json`:
```zig
.input_json => |json_delta| {
    try tool_call_tracker.appendDelta(cbd.index, json_delta);
    
    if (tool_call_tracker.getByApiIndex(cbd.index)) |tc| {
        stream.push(.{ .toolcall_delta = .{
            .content_index = tc.content_index,
            .delta = json_delta,
            .partial = createPartialMessage(model),
        }}) catch {};
    }
}
```

4. In `content_block_stop` for `tool_use`:
```zig
.tool_use => {
    if (tool_call_tracker.completeCall(cbs.index, allocator)) |tool_call| {
        content_blocks.append(allocator, .{ .tool_call = tool_call }) catch {};
        
        stream.push(.{ .toolcall_end = .{
            .content_index = content_blocks.items.len - 1,
            .tool_call = tool_call,
            .partial = createPartialMessage(model),
        }}) catch {};
    }
}
```

5. Also need to parse `id` and `name` from `content_block_start` event.

### 2.2 OpenAI Completions (`openai_completions_api.zig`)

**Current State:**
- `parseChunk()` only handles `delta.content` and reasoning fields
- No handling of `delta.tool_calls` array

**Fix:**

1. Add to `parseChunk()` function signature:
```zig
fn parseChunk(
    data: []const u8,
    text: *std.ArrayList(u8),
    thinking: *std.ArrayList(u8),
    usage: *ai_types.Usage,
    stop_reason: *ai_types.StopReason,
    current_block: *BlockType,
    reasoning_signature: *?[]const u8,
    tool_call_tracker: *ToolCallTracker,  // NEW
    tool_call_events: *std.ArrayList(ToolCallEvent),  // NEW - for emitting events
    allocator: std.mem.Allocator,
) !void
```

2. Add parsing for `delta.tool_calls`:
```zig
// After checking for reasoning and text content
if (d.object.get("tool_calls")) |tool_calls| {
    if (tool_calls == .array) {
        for (tool_calls.array.items) |tc| {
            if (tc == .object) {
                const tc_id = tc.object.get("id");
                const tc_func = tc.object.get("function");
                
                // If has id, it's a new tool call
                if (tc_id) |id| {
                    if (id == .string and id.string.len > 0) {
                        // Start new tool call
                        const name = if (tc_func) |f| 
                            if (f == .object and f.object.get("name")) |n|
                                if (n == .string) n.string else ""
                            else ""
                        else "";
                        
                        try tool_call_tracker.startCall(...);
                        try tool_call_events.append(.{ .start = ... });
                    }
                }
                
                // Append arguments delta
                if (tc_func) |f| {
                    if (f == .object and f.object.get("arguments")) |args| {
                        if (args == .string and args.string.len > 0) {
                            try tool_call_tracker.appendDelta(...);
                            try tool_call_events.append(.{ .delta = args.string });
                        }
                    }
                }
            }
        }
    }
}
```

3. In `runThread()`, process tool call events and emit stream events.

### 2.3 OpenAI Responses (`openai_responses_api.zig`)

**Current State:**
- Only handles `output_text.delta` and `response.completed`

**Fix:**

Add handling for:
1. `response.output_item.added` with `type: "function_call"` → emit `toolcall_start`
2. `response.function_call_arguments.delta` → emit `toolcall_delta`
3. `response.function_call_arguments.done` → emit `toolcall_end`
4. `response.reasoning.delta` → emit `thinking_delta`
5. `response.reasoning.done` → emit `thinking_end`

### 2.4 Google (`google_generative_api.zig`)

**Current State:**
- `parseGoogleEventExtended()` only extracts `text` parts with thinking flag
- No handling of `functionCall` parts

**Fix:**

In `parseGoogleEventExtended()`, add:
```zig
// Check for functionCall
if (p.object.get("functionCall")) |fc| {
    if (fc == .object) {
        const name = fc.object.get("name");
        const args = fc.object.get("args");
        const id = fc.object.get("id");
        
        // Return as a tool call part
        // Note: Google sends complete functionCall in single event
        // No delta accumulation needed
    }
}
```

Update `ParsedPart` to include tool calls:
```zig
const ParsedPart = union(enum) {
    text: struct { text: []const u8, is_thinking: bool, signature: ?[]const u8 },
    tool_call: struct { id: ?[]const u8, name: []const u8, args_json: []const u8 },
};
```

In the streaming loop, emit `toolcall_start`, `toolcall_delta`, `toolcall_end` in sequence for each `functionCall` (Google sends complete, not streamed).

### 2.5 Ollama (`ollama_api.zig`)

**Current State:**
- `parseLine()` only extracts `message.content`, usage, stop reason
- No handling of tool calls

**Fix:**

Add parsing for `message.tool_calls` array in the response:
```zig
if (msg_obj.get("tool_calls")) |tool_calls| {
    if (tool_calls == .array) {
        for (tool_calls.array.items) |tc| {
            // Ollama format: { "function": { "name": "...", "arguments": {...} } }
        }
    }
}
```

---

## Phase 3: Cost Calculation (P1)

### 3.1 Call `calculateCost()` in All Providers

**Pattern from TS:** Call after every usage update:
- Anthropic: In `message_start` and `message_delta` events
- OpenAI: When `usage` field is present
- Google: When `usageMetadata` is present

**Fix:** In each provider's streaming thread, after updating usage:
```zig
usage.calculateCost(model.cost);
```

**Files to modify:**
- `anthropic_messages_api.zig` (lines 748-752, 846-848)
- `openai_completions_api.zig` (after line 270)
- `openai_responses_api.zig` (in response.completed handler)
- `google_generative_api.zig` (after line 540)
- `ollama_api.zig` (after usage extraction)

---

## Phase 4: API Behavior Fixes (P2)

### 4.1 Anthropic max_tokens Default

**Current (line 133):**
```zig
try w.writeIntField("max_tokens", options.max_tokens orelse model.max_tokens);
```

**Fix:**
```zig
const default_max = @min(model.max_tokens / 3, 32000);
try w.writeIntField("max_tokens", options.max_tokens orelse default_max);
```

### 4.2 OpenAI Completions `store: false`

**Add to `buildRequestBody()` after line 176:**
```zig
// Privacy: don't store requests for OpenAI training
try w.writeBoolField("store", false);
```

**Note:** Only add for `api.openai.com` and `api.openai.com`-compatible endpoints that support it.

### 4.3 OpenAI Responses Caching Fields

**Add to request body:**
```zig
// Privacy
try w.writeBoolField("store", false);

// Session-based caching
if (options.session_id) |sid| {
    try w.writeStringField("prompt_cache_key", sid);
}

// Cache retention
if (options.cache_retention) |retention| {
    if (retention != .none and std.mem.indexOf(u8, model.base_url, "openai.com") != null) {
        try w.writeStringField("prompt_cache_retention", "24h");
    }
}
```

---

## Implementation Order

1. **Phase 1** - Create shared utilities (streaming_json.zig, tool_call_tracker.zig)
2. **Phase 2.1** - Fix Anthropic (most complex, good test case)
3. **Phase 2.2** - Fix OpenAI Completions
4. **Phase 2.3** - Fix OpenAI Responses  
5. **Phase 2.4** - Fix Google
6. **Phase 2.5** - Fix Ollama
7. **Phase 3** - Add cost calculation to all providers
8. **Phase 4** - Add privacy/caching fields

---

## Testing Strategy

Each provider fix should include:
1. Unit test for parsing tool call events from fixture data
2. Integration test with mock SSE stream
3. Verify no memory leaks with `std.testing.allocator`

Test fixture examples from TS reference:
- Anthropic: `content_block_start` with `tool_use`, `input_json_delta` chunks
- OpenAI: `delta.tool_calls` array with incremental arguments
- Google: Single `functionCall` part
- Ollama: `message.tool_calls` array

---

## Files Changed Summary

| File | Changes |
|------|---------|
| `zig/src/streaming_json.zig` | NEW - JSON accumulator |
| `zig/src/tool_call_tracker.zig` | NEW - Tool call tracking |
| `zig/src/providers/anthropic_messages_api.zig` | Tool call parsing, cost calc, max_tokens |
| `zig/src/providers/openai_completions_api.zig` | Tool call parsing, cost calc, store:false |
| `zig/src/providers/openai_responses_api.zig` | Tool call parsing, cost calc, caching fields |
| `zig/src/providers/google_generative_api.zig` | Tool call parsing, cost calc |
| `zig/src/providers/ollama_api.zig` | Tool call parsing, cost calc |
| `zig/build.zig` | Add new modules |
