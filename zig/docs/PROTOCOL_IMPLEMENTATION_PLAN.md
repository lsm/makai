# Makai Protocol Implementation Plan

## Overview

This document outlines the implementation plan for the Makai Wire Protocol layer, which will enable transport-agnostic streaming communication for AI interactions.

## Current State Analysis

### What Exists

| Component | File | Status |
|-----------|------|--------|
| Core Transport Abstraction | `transport.zig` | COMPLETE |
| Sender/Receiver Interfaces | `transport.zig` | COMPLETE |
| AsyncSender/AsyncReceiver | `transport.zig` | COMPLETE |
| ByteChunk, ByteStream | `transport.zig` | COMPLETE |
| MessageOrControl Union | `transport.zig` | COMPLETE |
| Event Serialization | `transport.zig` | COMPLETE |
| Event Deserialization | `transport.zig` | COMPLETE |
| Stream Bridge Functions | `transport.zig` | COMPLETE |
| Stdio Transport | `transports/stdio.zig` | COMPLETE |
| SSE Transport | `transports/sse.zig` | COMPLETE |
| SSE Parser | `providers/sse_parser.zig` | COMPLETE |
| JSON Writer | `json/writer.zig` | COMPLETE |
| Streaming JSON Parser | `streaming_json.zig`, `utils/streaming_json.zig` | COMPLETE |
| Core AI Types | `ai_types.zig` | COMPLETE |

### What's Missing

| Component | Description | Priority |
|-----------|-------------|----------|
| Envelope Types | Protocol envelope with stream_id, message_id, sequence | High |
| include_partial Types | Lightweight per-block partial types | High |
| include_partial Serialization | Serialize events with per-block partial | High |
| include_partial Reconstructor | Client-side partial builder | High |
| Control Messages | ack, nack, ping, pong, goodbye | Medium |
| Request Types | stream_request, complete_request, abort_request | Medium |
| WebSocket Transport | WebSocket client/server implementation | Medium |
| gRPC Transport | gRPC service definition and implementation | Low |

## Implementation Phases

### Phase 1: Protocol Types (Status: DONE)

**Goal**: Define all protocol message types

**Note**: The old `types.zig` file has been removed. `ai_types.zig` is now the canonical source for AI-related types.

**Files to Create/Modify**:
- `src/protocol/types.zig` - New file for protocol-specific types
- `src/protocol/envelope.zig` - Envelope wrapper types

**Types to Define**:

```zig
// src/protocol/types.zig

pub const Envelope = struct {
    type: []const u8,
    stream_id: []const u8,      // Stable identifier for stream lifecycle
    message_id: []const u8,     // Unique identifier for each envelope
    sequence: u32,              // REQUIRED - starts at 1
    timestamp: ?i64 = null,
    in_reply_to: ?[]const u8 = null,  // For ack/nack correlation
    include_partial: bool = false,
    payload: Payload,
};

pub const Payload = union(enum) {
    stream_request: StreamRequest,
    complete_request: CompleteRequest,
    abort_request: AbortRequest,

    // Events (wrap existing types)
    event: ai_types.AssistantMessageEvent,

    // Control messages
    ack: AckPayload,
    nack: NackPayload,
    ping: void,
    pong: PongPayload,
    goodbye: GoodbyePayload,

    // Final results
    result: ai_types.AssistantMessage,
    stream_error: StreamError,
};

pub const StreamRequest = struct {
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?StreamOptions = null,
};

pub const StreamOptions = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    include_partial: bool = false,  // NEW: replaces "encoding" field
    cache_retention: ?ai_types.CacheRetention = null,
    session_id: ?[]const u8 = null,
    // NOTE: api_key removed - passed via transport headers only
    thinking_enabled: bool = false,
    thinking_budget_tokens: ?u32 = null,
    thinking_effort: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    service_tier: ?ai_types.ServiceTier = null,
    tool_choice: ?ai_types.ToolChoice = null,
    http_timeout_ms: ?u64 = 30_000,
    ping_interval_ms: ?u64 = null,
};

pub const AbortRequest = struct {
    target_stream_id: []const u8,
    reason: ?[]const u8 = null,
};

pub const AckPayload = struct {
    acknowledged_id: []const u8,
};

pub const NackPayload = struct {
    rejected_id: []const u8,
    reason: []const u8,
    error_code: ?[]const u8 = null,
    supported_versions: ?[][]const u8 = null,
};

pub const StreamError = struct {
    error_code: []const u8,
    error_message: []const u8,
    retry_after_ms: ?u64 = null,
    usage: ai_types.Usage,  // REQUIRED in error events
};
```

### Phase 2: include_partial Mode (Estimated: 2-3 days)

**Goal**: Implement per-block partial serialization and client-side reconstruction

**Files to Create**:
- `src/protocol/content_partial.zig` - Per-block partial types
- `src/protocol/partial_serializer.zig` - Serialize events with partial
- `src/protocol/partial_reconstructor.zig` - Client-side partial builder

**ContentPartial Types**:

```zig
// src/protocol/content_partial.zig

/// Lightweight per-block partial state
pub const ContentPartial = union(enum) {
    text: TextPartial,
    thinking: ThinkingPartial,
    tool_call: ToolCallPartial,
    image: ImagePartial,
};

pub const TextPartial = struct {
    current_text: []const u8,
};

pub const ThinkingPartial = struct {
    current_thinking: []const u8,
};

pub const ToolCallPartial = struct {
    current_arguments_json: []const u8,
};

pub const ImagePartial = struct {
    // Future: partial image data
};
```

**Partial Serializer**:

```zig
// src/protocol/partial_serializer.zig

pub const PartialSerializer = struct {
    /// Serialize an AssistantMessageEvent with include_partial flag
    pub fn serializeEvent(
        allocator: std.mem.Allocator,
        event: ai_types.AssistantMessageEvent,
        stream_id: []const u8,
        message_id: []const u8,
        sequence: u32,
        include_partial: bool,
    ) ![]const u8 {
        var writer = json_writer.JsonWriter.init(allocator);
        defer writer.deinit();

        try writer.beginObject();

        // Write envelope fields
        try writer.writeStringField("type", @tagName(event));
        try writer.writeStringField("stream_id", stream_id);
        try writer.writeStringField("message_id", message_id);
        try writer.writeIntField("sequence", sequence);

        if (include_partial) {
            try writer.writeBoolField("include_partial", true);
        }

        // Write payload
        try writer.writeKey("payload");
        try serializePayload(&writer, event, include_partial);

        try writer.endObject();

        return writer.toOwnedSlice();
    }

    fn serializePayload(
        writer: *json_writer.JsonWriter,
        event: ai_types.AssistantMessageEvent,
        include_partial: bool,
    ) !void {
        try writer.beginObject();

        switch (event) {
            .start => |e| {
                try writer.writeStringField("model", e.partial.model);
                // input_tokens if available
            },
            .text_delta => |e| {
                try writer.writeIntField("content_index", e.content_index);
                try writer.writeStringField("delta", e.delta);
                if (include_partial) {
                    try writer.writeKey("partial");
                    try writer.beginObject();
                    try writer.writeStringField("current_text", e.partial.content[e.content_index].text.text);
                    try writer.endObject();
                }
            },
            .toolcall_start => |e| {
                try writer.writeIntField("content_index", e.content_index);
                // Extract tool call info from partial content
            },
            .toolcall_delta => |e| {
                try writer.writeIntField("content_index", e.content_index);
                try writer.writeStringField("delta", e.delta);
                if (include_partial) {
                    try writer.writeKey("partial");
                    try writer.beginObject();
                    try writer.writeStringField("current_arguments_json", /* accumulated json */);
                    try writer.endObject();
                }
            },
            .done => |e| {
                try serializeStopReason(writer, e.reason);
                try serializeUsage(writer, e.message.usage);
            },
            .@"error" => |e| {
                try writer.writeStringField("reason", @tagName(e.reason));
                // usage is REQUIRED
            },
            else => {},
        }

        try writer.endObject();
    }
};
```

**Partial Reconstructor (Simpler Design)**:

```zig
// src/protocol/partial_reconstructor.zig

pub const PartialReconstructor = struct {
    allocator: std.mem.Allocator,
    partial: ai_types.AssistantMessage,
    current_text: []const u8,
    current_thinking: []const u8,
    current_arguments_json: []const u8,

    pub fn init(allocator: std.mem.Allocator, model: []const u8) Self {
        return .{
            .allocator = allocator,
            .partial = .{
                .role = .assistant,
                .content = &.{},
                .usage = .{},
                .stop_reason = null,
                .model = model,
                .timestamp = std.time.timestamp(),
            },
            .current_text = "",
            .current_thinking = "",
            .current_arguments_json = "",
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up partial content
        for (self.partial.content) |block| {
            ai_types.deinitAssistantContent(block, self.allocator);
        }
        self.allocator.free(self.partial.content);
    }

    /// Process a protocol event and update partial state
    pub fn processEvent(self: *Self, event: ProtocolEvent) !void {
        switch (event) {
            .start => |e| {
                // Initialize with model info
                self.partial.model = e.model;
            },
            .text_start => |e| {
                try self.addContentBlock(.{ .text = .{
                    .text = "",
                    .text_signature = null,
                }}, e.content_index);
                self.current_text = "";
            },
            .text_delta => |e| {
                self.current_text = try self.appendToString(
                    self.current_text,
                    e.delta,
                );
                try self.updateTextContent(e.content_index, self.current_text);
            },
            .text_end => |e| {
                if (e.content_signature) |sig| {
                    try self.setTextSignature(e.content_index, sig);
                }
            },
            .toolcall_start => |e| {
                try self.addContentBlock(.{ .tool_call = .{
                    .id = try self.allocator.dupe(u8, e.id),
                    .name = try self.allocator.dupe(u8, e.name),
                    .arguments_json = "",
                    .thought_signature = null,
                }}, e.content_index);
                self.current_arguments_json = "";
            },
            .toolcall_delta => |e| {
                self.current_arguments_json = try self.appendToString(
                    self.current_arguments_json,
                    e.delta,
                );
                try self.updateToolCallArguments(e.content_index, self.current_arguments_json);
            },
            .done => |e| {
                self.partial.usage = e.usage;
                self.partial.stop_reason = e.reason;
            },
            .@"error" => |e| {
                self.partial.stop_reason = .@"error";
                self.partial.usage = e.usage;  // REQUIRED
            },
            else => {},
        }
    }

    /// Get the reconstructed partial message
    pub fn getPartial(self: *Self) *ai_types.AssistantMessage {
        return &self.partial;
    }

    // ... helper methods
};
```

### Phase 3: Async Transport Redesign (Status: DONE)

**Goal**: Implement async byte stream abstraction for all transports

**What was implemented**:

1. **ByteChunk** - A chunk of bytes with ownership semantics:
   ```zig
   pub const ByteChunk = struct {
       data: []const u8,
       owned: bool = true,
   };
   ```

2. **ByteStream** - Stream of byte chunks:
   ```zig
   pub const ByteStream = event_stream.EventStream(ByteChunk, void);
   ```

3. **AsyncSender** - Async write interface:
   ```zig
   pub const AsyncSender = struct {
       context: *anyopaque,
       write_fn: *const fn (ctx: *anyopaque, data: []const u8) anyerror!void,
       flush_fn: ?*const fn (ctx: *anyopaque) anyerror!void = null,
       close_fn: ?*const fn (ctx: *anyopaque) void = null,
   };
   ```

4. **AsyncReceiver** - Async receive interface with stream support:
   ```zig
   pub const AsyncReceiver = struct {
       context: *anyopaque,
       receive_stream_fn: *const fn (
           ctx: *anyopaque,
           allocator: std.mem.Allocator,
       ) anyerror!*ByteStream,
       read_fn: ?*const fn (...) anyerror!?[]const u8 = null,
       close_fn: ?*const fn (ctx: *anyopaque) void = null,
   };
   ```

5. **Bridge Functions**:
   - `receiveStreamFromByteStream()` - Bridges ByteStream to AssistantMessageStream
   - `spawnReceiver()` - Spawns a thread to handle async receiving

### Phase 4: Envelope Serialization (Estimated: 1 day)

**Goal**: Implement full envelope serialization/deserialization

**Files to Modify**:
- `src/transport.zig` - Add envelope serialization

```zig
// Add to src/transport.zig

pub fn serializeEnvelope(
    allocator: std.mem.Allocator,
    envelope: protocol.Envelope,
) ![]const u8 {
    var writer = json_writer.JsonWriter.init(allocator);
    defer writer.deinit();

    try writer.beginObject();

    try writer.writeStringField("type", envelope.type);
    try writer.writeStringField("stream_id", envelope.stream_id);
    try writer.writeStringField("message_id", envelope.message_id);
    try writer.writeIntField("sequence", envelope.sequence);  // REQUIRED

    if (envelope.timestamp) |ts| {
        try writer.writeIntField("timestamp", ts);
    }

    if (envelope.in_reply_to) |reply_to| {
        try writer.writeStringField("in_reply_to", reply_to);
    }

    if (envelope.include_partial) {
        try writer.writeBoolField("include_partial", true);
    }

    try writer.writeKey("payload");
    try serializePayload(&writer, envelope.payload);

    try writer.endObject();

    return writer.toOwnedSlice();
}

pub fn deserializeEnvelope(
    allocator: std.mem.Allocator,
    json_text: []const u8,
) !protocol.Envelope {
    var parser = std.json.Parser.init(allocator, false);
    defer parser.deinit();

    var tree = try parser.parse(json_text);
    defer tree.deinit();

    const root = tree.root.Object;

    var envelope: protocol.Envelope = undefined;
    envelope.type = try allocator.dupe(u8, root.get("type").?.String);
    envelope.stream_id = try allocator.dupe(u8, root.get("stream_id").?.String);
    envelope.message_id = try allocator.dupe(u8, root.get("message_id").?.String);
    envelope.sequence = @intCast(root.get("sequence").?.Integer);  // REQUIRED

    // Parse optional fields
    envelope.timestamp = if (root.get("timestamp")) |ts| ts.Integer else null;
    envelope.in_reply_to = if (root.get("in_reply_to")) |r|
        try allocator.dupe(u8, r.String)
    else
        null;
    envelope.include_partial = if (root.get("include_partial")) |ip|
        ip.Bool
    else
        false;

    // Parse payload based on type
    const payload_obj = root.get("payload").?.Object;
    envelope.payload = try deserializePayload(allocator, envelope.type, payload_obj);

    return envelope;
}
```

### Phase 5: WebSocket Transport (Estimated: 2-3 days)

**Goal**: Implement WebSocket transport using libxev

**Dependencies**: Phase 3 (Async Transport) - COMPLETE

**Files to Create**:
- `src/transports/websocket.zig` - WebSocket client implementation

**Dependencies**:
- libxev (already available)
- WebSocket protocol implementation

```zig
// src/transports/websocket.zig

const libxev = @import("libxev");
const transport = @import("../transport.zig");

pub const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    loop: *libxev.Loop,
    tcp: ?libxev.TCP,
    state: State,

    const State = enum {
        disconnected,
        connecting,
        connected,
        closing,
        closed,
    };

    pub fn init(allocator: std.mem.Allocator, loop: *libxev.Loop) Self {
        return .{
            .allocator = allocator,
            .loop = loop,
            .tcp = null,
            .state = .disconnected,
        };
    }

    pub fn connect(
        self: *Self,
        url: []const u8,
        headers: ?[]const transport.HeaderPair,
    ) !void {
        // Parse URL, establish TCP connection
        // Perform WebSocket handshake with:
        //   Sec-WebSocket-Protocol: makai.v1
        //   Authorization: Bearer <api_key> (if provided)
    }

    pub fn send(self: *Self, message: []const u8) !void {
        // Send text frame
    }

    pub fn receiveStream(
        self: *Self,
        allocator: std.mem.Allocator,
    ) !*transport.ByteStream {
        // Create a ByteStream and spawn async receiver
    }

    pub fn close(self: *Self) void {
        // Send close frame, cleanup
    }

    // Convert to AsyncSender interface
    pub fn asyncSender(self: *Self) transport.AsyncSender {
        return transport.AsyncSender.init(
            self,
            struct {
                fn write(ctx: *anyopaque, data: []const u8) anyerror!void {
                    const s = @as(*WebSocketClient, @ptrCast(@alignCast(ctx)));
                    try s.send(data);
                }
                fn close(ctx: *anyopaque) void {
                    const s = @as(*WebSocketClient, @ptrCast(@alignCast(ctx)));
                    s.close();
                }
            }.write,
            null,
            struct {
                fn close(ctx: *anyopaque) void {
                    const s = @as(*WebSocketClient, @ptrCast(@alignCast(ctx)));
                    s.close();
                }
            }.close,
        );
    }

    // Convert to AsyncReceiver interface
    pub fn asyncReceiver(self: *Self) transport.AsyncReceiver {
        return transport.AsyncReceiver.init(
            self,
            struct {
                fn receiveStream(
                    ctx: *anyopaque,
                    allocator: std.mem.Allocator,
                ) anyerror!*transport.ByteStream {
                    const s = @as(*WebSocketClient, @ptrCast(@alignCast(ctx)));
                    return try s.receiveStream(allocator);
                }
            }.receiveStream,
        );
    }
};
```

### Phase 6: Request/Response Handling (Estimated: 1-2 days)

**Goal**: Implement request handling with stream_id/message_id correlation

**Files to Create**:
- `src/protocol/server.zig` - Server-side request handling
- `src/protocol/client.zig` - Client-side request/response correlation

```zig
// src/protocol/server.zig

pub const ProtocolServer = struct {
    allocator: std.mem.Allocator,
    registry: *api_registry.ApiRegistry,
    active_streams: std.StringHashMap(*StreamContext),
    sequence_counter: std.atomic.Value(u32),

    const StreamContext = struct {
        stream_id: []const u8,
        stream: *ai_types.AssistantMessageStream,
        abort_signal: bool,
        sequence: u32,
    };

    pub fn handleEnvelope(
        self: *ProtocolServer,
        envelope: protocol.Envelope,
        sender: transport.AsyncSender,
    ) !void {
        switch (envelope.payload) {
            .stream_request => |req| {
                try self.handleStreamRequest(envelope, req, sender);
            },
            .complete_request => |req| {
                try self.handleCompleteRequest(envelope, req, sender);
            },
            .abort_request => |req| {
                try self.handleAbortRequest(envelope, req);
            },
            else => {
                // Unknown request type
                try self.sendNack(sender, envelope, "UNKNOWN_TYPE", "Unknown request type");
            },
        }
    }

    fn handleStreamRequest(
        self: *ProtocolServer,
        envelope: protocol.Envelope,
        req: protocol.StreamRequest,
        sender: transport.AsyncSender,
    ) !void {
        // Send ACK with sequence number
        try self.sendAck(sender, envelope.stream_id, envelope.message_id);

        // Create stream
        var stream = try stream_module.stream(
            self.registry,
            req.model,
            req.context,
            req.options,
            self.allocator,
        );

        // Store context for abort support
        var ctx = try self.allocator.create(StreamContext);
        ctx.* = .{
            .stream_id = try self.allocator.dupe(u8, envelope.stream_id),
            .stream = stream,
            .abort_signal = false,
            .sequence = 1,
        };
        try self.active_streams.put(envelope.stream_id, ctx);

        // Forward events to sender with envelope wrapping
        // TODO: Spawn async task to forward events
    }

    fn sendAck(
        self: *ProtocolServer,
        sender: transport.AsyncSender,
        stream_id: []const u8,
        original_message_id: []const u8,
    ) !void {
        const seq = self.sequence_counter.fetchAdd(1, .monotonic);
        const envelope = protocol.Envelope{
            .type = "ack",
            .stream_id = stream_id,
            .message_id = try generateMessageId(self.allocator),
            .sequence = seq,
            .in_reply_to = original_message_id,
            .payload = .{ .ack = .{
                .acknowledged_id = original_message_id,
            }},
        };
        defer freeEnvelope(&envelope, self.allocator);

        const json = try transport.serializeEnvelope(self.allocator, envelope);
        defer self.allocator.free(json);

        try sender.write(json);
        try sender.flush();
    }
};
```

### Phase 7: Integration & Testing (Estimated: 2 days)

**Tests to Write**:

1. **Protocol Types Tests**
   - Envelope serialization/deserialization roundtrip
   - All payload types serialize correctly
   - Sequence number validation

2. **include_partial Mode Tests**
   - Event serialization with per-block partial
   - Reconstruction accuracy
   - Tool call JSON accumulation

3. **Transport Tests**
   - Stdio transport with envelopes
   - SSE transport with envelopes
   - WebSocket transport (when implemented)

4. **End-to-End Tests**
   - Full request/response cycle
   - Abort handling
   - Concurrent streams
   - Error handling with usage

## File Structure

```
zig/src/
├── protocol/
│   ├── types.zig           # Protocol message types
│   ├── envelope.zig        # Envelope wrapper
│   ├── content_partial.zig # Per-block partial types
│   ├── partial_serializer.zig # Partial event serialization
│   ├── partial_reconstructor.zig # Client-side reconstruction
│   ├── server.zig          # Server-side handling
│   └── client.zig          # Client-side handling
├── transports/
│   ├── stdio.zig           # (existing)
│   ├── sse.zig             # (existing)
│   └── websocket.zig       # (new)
├── transport.zig           # (existing - add envelope support)
├── ai_types.zig            # (canonical - types.zig removed)
└── ...
```

## Dependencies

| Dependency | Purpose | Status |
|------------|---------|--------|
| libxev | Async I/O for WebSocket | Already in project |
| std.json | JSON parsing | Standard library |
| json_writer | JSON serialization | Already in project |
| streaming_json | Partial JSON parsing | Already in project |

## API Examples

### Server Usage

```zig
var registry = api_registry.ApiRegistry.init(allocator);
try register_builtins.registerBuiltInApiProviders(&registry);

var server = protocol.server.ProtocolServer.init(allocator, &registry);

// Receive envelope from transport
const envelope = try transport.deserializeEnvelope(allocator, json_data);

// Handle and respond
try server.handleEnvelope(envelope, async_sender);
```

### Client Usage

```zig
var reconstructor = protocol.partial_reconstructor.PartialReconstructor.init(allocator, "claude-3-opus");
defer reconstructor.deinit();

// Process events (with include_partial: false)
for (events) |event| {
    try reconstructor.processEvent(event);
}

// Get reconstructed message
const partial = reconstructor.getPartial();
```

### include_partial Usage

```zig
// Create request with include_partial flag
const request = protocol.StreamRequest{
    .model = model,
    .context = context,
    .options = .{
        .include_partial = true,  // Get per-block partial
    },
};

// Events will include partial field:
// { "type": "text_delta", "payload": { "delta": " world", "partial": { "current_text": "Hello world" } } }
```

## Timeline Summary

| Phase | Duration | Status | Dependencies |
|-------|----------|--------|--------------|
| Phase 1: Protocol Types | 1-2 days | DONE | None |
| Phase 2: include_partial Mode | 2-3 days | Pending | Phase 1 |
| Phase 3: Async Transport | 2-3 days | DONE | None |
| Phase 4: Envelope Serialization | 1 day | Pending | Phase 1 |
| Phase 5: WebSocket Transport | 2-3 days | Pending | Phase 3 |
| Phase 6: Request/Response Handling | 1-2 days | Pending | Phase 4 |
| Phase 7: Integration & Testing | 2 days | Pending | All phases |

**Total Remaining Estimated Time**: 8-12 days

## Security Considerations

### API Key Handling

API keys are passed via transport headers only, never in protocol messages:

```zig
// CORRECT: Pass via transport headers
const headers = [_]transport.HeaderPair{
    .{ .name = "Authorization", .value = "Bearer sk-..." },
};

// INCORRECT: Do NOT include in request
// const options = protocol.StreamOptions{
//     .api_key = "sk-...",  // REMOVED
// };
```

### Log Redaction

Implementations should redact sensitive fields:

```zig
fn redactLog(message: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    // Redact Authorization headers
    // Redact fields containing "key", "secret", "token"
    // Redact message content if configured
}
```

## Success Criteria

1. All protocol types defined with JSON serialization
2. include_partial mode provides ~50-70% bandwidth reduction
3. Client-side reconstruction produces identical partial messages
4. WebSocket transport passes all tests
5. Concurrent streams work correctly with stream_id correlation
6. Abort requests terminate streams immediately
7. All transports (stdio, SSE, WebSocket) work with protocol layer
8. Error events always include usage field
