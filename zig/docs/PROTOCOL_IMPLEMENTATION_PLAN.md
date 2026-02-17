# Makai Protocol Implementation Plan

## Overview

This document outlines the implementation plan for the Makai Wire Protocol layer, which will enable transport-agnostic streaming communication for AI interactions.

## Current State Analysis

### What Exists

| Component | File | Status |
|-----------|------|--------|
| Core Transport Abstraction | `transport.zig` | ✅ Complete |
| Sender/Receiver Interfaces | `transport.zig` | ✅ Complete |
| MessageOrControl Union | `transport.zig` | ✅ Complete |
| Serialization | `transport.zig` | ✅ Complete (partial) |
| Deserialization | `transport.zig` | ✅ Complete (partial) |
| Stdio Transport | `transports/stdio.zig` | ✅ Complete |
| SSE Transport | `transports/sse.zig` | ✅ Complete |
| SSE Parser | `providers/sse_parser.zig` | ✅ Complete |
| JSON Writer | `json/writer.zig` | ✅ Complete |
| Streaming JSON Parser | `streaming_json.zig`, `utils/streaming_json.zig` | ✅ Complete |

### What's Missing

| Component | Description | Priority |
|-----------|-------------|----------|
| Envelope Types | Protocol envelope with request_id, timestamp, encoding | High |
| Proxy Mode Types | Bandwidth-optimized event types without `partial` | High |
| Proxy Mode Serialization | Serialize events without partial field | High |
| Proxy Mode Reconstruction | Client-side partial message builder | High |
| Control Messages | ack, nack, ping, pong, goodbye | Medium |
| Request Types | stream_request, complete_request, abort_request | Medium |
| WebSocket Transport | WebSocket client/server implementation | Medium |
| gRPC Transport | gRPC service definition and implementation | Low |
| Fragmentation | Large message splitting and reassembly | Low |

## Implementation Phases

### Phase 1: Protocol Types (Estimated: 1-2 days)

**Goal**: Define all protocol message types

**Files to Create/Modify**:
- `src/protocol/types.zig` - New file for protocol-specific types
- `src/protocol/envelope.zig` - Envelope wrapper types

**Types to Define**:

```zig
// src/protocol/types.zig

pub const Encoding = enum {
    full,
    proxy,
};

pub const Envelope = struct {
    type: []const u8,
    request_id: []const u8,
    timestamp: ?i64 = null,
    encoding: Encoding = .full,
    sequence: ?u32 = null,
    fragment: ?Fragment = null,
    payload: Payload,
};

pub const Fragment = struct {
    index: u32,
    total: u32,
    id: []const u8,
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
    options: ?ai_types.StreamOptions = null,
};

pub const AbortRequest = struct {
    target_request_id: []const u8,
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
    usage: ?ai_types.Usage = null,
};
```

**Proxy Event Types**:

```zig
// src/protocol/proxy_types.zig

// Proxy events omit the `partial` field for bandwidth optimization
pub const ProxyEvent = union(enum) {
    start: void,
    text_start: ContentIndexPayload,
    text_delta: DeltaPayload,
    text_end: TextEndPayload,
    thinking_start: ContentIndexPayload,
    thinking_delta: DeltaPayload,
    thinking_end: ThinkingEndPayload,
    toolcall_start: ToolCallStartPayload,
    toolcall_delta: DeltaPayload,
    toolcall_end: ToolCallEndPayload,
    done: ProxyDonePayload,
    error: ProxyErrorPayload,
    ping: void,
};

pub const ContentIndexPayload = struct {
    content_index: u32,
};

pub const DeltaPayload = struct {
    content_index: u32,
    delta: []const u8,
};

pub const TextEndPayload = struct {
    content_index: u32,
    content_signature: ?[]const u8 = null,
};

pub const ThinkingEndPayload = struct {
    content_index: u32,
    thinking_signature: ?[]const u8 = null,
};

pub const ToolCallStartPayload = struct {
    content_index: u32,
    id: []const u8,
    name: []const u8,
};

pub const ToolCallEndPayload = struct {
    content_index: u32,
    tool_call: ?ai_types.ToolCall = null, // Optional in proxy mode
};

pub const ProxyDonePayload = struct {
    reason: ai_types.StopReason,
    usage: ai_types.Usage,
};

pub const ProxyErrorPayload = struct {
    reason: union(enum) { aborted: void, error: void },
    error_message: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    usage: ?ai_types.Usage = null,
};
```

### Phase 2: Proxy Mode Implementation (Estimated: 2-3 days)

**Goal**: Implement bandwidth-optimized event serialization and client-side reconstruction

**Files to Create**:
- `src/protocol/proxy_serializer.zig` - Serialize events without partial
- `src/protocol/proxy_reconstructor.zig` - Client-side partial message builder

**Proxy Serializer**:

```zig
// src/protocol/proxy_serializer.zig

pub const ProxySerializer = struct {
    /// Serialize an AssistantMessageEvent to proxy format (no partial)
    pub fn serializeEvent(
        allocator: std.mem.Allocator,
        event: ai_types.AssistantMessageEvent,
        request_id: []const u8,
    ) ![]const u8 {
        var writer = json_writer.JsonWriter.init(allocator);
        defer writer.deinit();

        try writer.beginObject();

        // Write type
        try writer.writeStringField("type", @tagName(event));

        // Write request_id
        try writer.writeStringField("request_id", request_id);

        // Write encoding
        try writer.writeStringField("encoding", "proxy");

        // Write payload based on event type
        try writer.writeKey("payload");
        try serializePayload(&writer, event);

        try writer.endObject();

        return writer.toOwnedSlice();
    }

    fn serializePayload(writer: *json_writer.JsonWriter, event: ai_types.AssistantMessageEvent) !void {
        try writer.beginObject();

        switch (event) {
            .start => |e| {
                _ = e;
                // Start has minimal payload in proxy mode
            },
            .text_delta => |e| {
                try writer.writeIntField("content_index", e.content_index);
                try writer.writeStringField("delta", e.delta);
            },
            .toolcall_start => |e| {
                try writer.writeIntField("content_index", e.content_index);
                try writer.writeStringField("id", e.id);
                try writer.writeStringField("name", e.name);
            },
            // ... other event types
            .done => |e| {
                try serializeStopReason(writer, e.reason);
                try serializeUsage(writer, e.message.usage);
            },
            .@"error" => |e| {
                try writer.writeStringField("reason", @tagName(e.reason));
                if (e.err.error_message) |msg| {
                    try writer.writeStringField("error_message", msg);
                }
            },
            else => {},
        }

        try writer.endObject();
    }
};
```

**Proxy Reconstructor**:

```zig
// src/protocol/proxy_reconstructor.zig

pub const ProxyReconstructor = struct {
    allocator: std.mem.Allocator,
    partial: ai_types.AssistantMessage,
    tool_call_json_accumulators: std.AutoHashMap(u32, []const u8),

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
            .tool_call_json_accumulators = std.AutoHashMap(u32, []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up partial content
        for (self.partial.content) |block| {
            ai_types.freeAssistantContent(block, self.allocator);
        }
        self.allocator.free(self.partial.content);

        // Clean up JSON accumulators
        var iter = self.tool_call_json_accumulators.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.tool_call_json_accumulators.deinit();
    }

    /// Process a proxy event and update partial state
    pub fn processEvent(self: *Self, event: ProxyEvent) !void {
        switch (event) {
            .start => {
                // Initialize empty partial
            },
            .text_start => |e| {
                try self.addContentBlock(.{ .text = .{
                    .text = "",
                    .text_signature = null,
                }}, e.content_index);
            },
            .text_delta => |e| {
                try self.appendTextDelta(e.content_index, e.delta);
            },
            .text_end => |e| {
                if (e.content_signature) |sig| {
                    try self.setTextSignature(e.content_index, sig);
                }
            },
            .thinking_start => |e| {
                try self.addContentBlock(.{ .thinking = .{
                    .thinking = "",
                    .thinking_signature = null,
                }}, e.content_index);
            },
            .thinking_delta => |e| {
                try self.appendThinkingDelta(e.content_index, e.delta);
            },
            .toolcall_start => |e| {
                try self.addContentBlock(.{ .tool_call = .{
                    .id = try self.allocator.dupe(u8, e.id),
                    .name = try self.allocator.dupe(u8, e.name),
                    .arguments_json = "",
                    .thought_signature = null,
                }}, e.content_index);
            },
            .toolcall_delta => |e| {
                try self.accumulateToolCallJson(e.content_index, e.delta);
            },
            .toolcall_end => |e| {
                _ = e;
                // Finalize tool call JSON
            },
            .done => |e| {
                self.partial.usage = e.usage;
                self.partial.stop_reason = e.reason;
            },
            .@"error" => |e| {
                self.partial.stop_reason = .@"error";
                if (e.usage) |usage| {
                    self.partial.usage = usage;
                }
            },
            .ping => {},
        }
    }

    /// Get the reconstructed partial message
    pub fn getPartial(self: *Self) *ai_types.AssistantMessage {
        return &self.partial;
    }

    // ... helper methods
};
```

### Phase 3: Envelope Serialization (Estimated: 1 day)

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
    try writer.writeStringField("request_id", envelope.request_id);

    if (envelope.timestamp) |ts| {
        try writer.writeIntField("timestamp", ts);
    }

    if (envelope.encoding != .full) {
        try writer.writeStringField("encoding", @tagName(envelope.encoding));
    }

    if (envelope.sequence) |seq| {
        try writer.writeIntField("sequence", seq);
    }

    if (envelope.fragment) |frag| {
        try writer.writeKey("fragment");
        try writer.beginObject();
        try writer.writeIntField("index", frag.index);
        try writer.writeIntField("total", frag.total);
        try writer.writeStringField("id", frag.id);
        try writer.endObject();
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
    envelope.request_id = try allocator.dupe(u8, root.get("request_id").?.String);

    // Parse optional fields
    envelope.timestamp = if (root.get("timestamp")) |ts| ts.Integer else null;
    envelope.encoding = if (root.get("encoding")) |enc|
        std.meta.stringToEnum(protocol.Encoding, enc.String) orelse .full
    else .full;

    // Parse payload based on type
    const payload_obj = root.get("payload").?.Object;
    envelope.payload = try deserializePayload(allocator, envelope.type, payload_obj);

    return envelope;
}
```

### Phase 4: WebSocket Transport (Estimated: 2-3 days)

**Goal**: Implement WebSocket transport using libxev

**Files to Create**:
- `src/transports/websocket.zig` - WebSocket client implementation

**Dependencies**:
- libxev (already available)
- WebSocket protocol implementation

```zig
// src/transports/websocket.zig

const libxev = @import("libxev");

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
        headers: ?[]const HeaderPair,
    ) !void {
        // Parse URL, establish TCP connection
        // Perform WebSocket handshake with Sec-WebSocket-Protocol: makai.v1
    }

    pub fn send(self: *Self, message: []const u8) !void {
        // Send text frame
    }

    pub fn receive(self: *Self, buffer: []u8) ![]const u8 {
        // Receive and decode frame
    }

    pub fn close(self: *Self) void {
        // Send close frame, cleanup
    }

    // Convert to Sender/Receiver interfaces
    pub fn sender(self: *Self) transport.Sender {
        return transport.Sender.init(
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
};
```

### Phase 5: Request/Response Handling (Estimated: 1-2 days)

**Goal**: Implement request handling with request_id correlation

**Files to Create**:
- `src/protocol/server.zig` - Server-side request handling
- `src/protocol/client.zig` - Client-side request/response correlation

```zig
// src/protocol/server.zig

pub const ProtocolServer = struct {
    allocator: std.mem.Allocator,
    registry: *api_registry.ApiRegistry,
    active_streams: std.StringHashMap(*StreamContext),

    const StreamContext = struct {
        request_id: []const u8,
        stream: *ai_types.AssistantMessageEventStream,
        abort_signal: bool,
    };

    pub fn handleEnvelope(
        self: *ProtocolServer,
        envelope: protocol.Envelope,
        sender: transport.Sender,
    ) !void {
        switch (envelope.payload) {
            .stream_request => |req| {
                try self.handleStreamRequest(envelope.request_id, req, sender);
            },
            .complete_request => |req| {
                try self.handleCompleteRequest(envelope.request_id, req, sender);
            },
            .abort_request => |req| {
                try self.handleAbortRequest(req);
            },
            else => {
                // Unknown request type
                try self.sendNack(sender, envelope.request_id, "UNKNOWN_TYPE", "Unknown request type");
            },
        }
    }

    fn handleStreamRequest(
        self: *ProtocolServer,
        request_id: []const u8,
        req: protocol.StreamRequest,
        sender: transport.Sender,
    ) !void {
        // Send ACK
        try self.sendAck(sender, request_id);

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
            .request_id = try self.allocator.dupe(u8, request_id),
            .stream = stream,
            .abort_signal = false,
        };
        try self.active_streams.put(request_id, ctx);

        // Forward events to sender
        // TODO: Spawn task/async to forward events
    }

    fn sendAck(self: *ProtocolServer, sender: transport.Sender, request_id: []const u8) !void {
        const envelope = protocol.Envelope{
            .type = "ack",
            .request_id = try generateRequestId(self.allocator),
            .payload = .{ .ack = .{
                .acknowledged_id = request_id,
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

### Phase 6: Integration & Testing (Estimated: 2 days)

**Tests to Write**:

1. **Protocol Types Tests**
   - Envelope serialization/deserialization roundtrip
   - All payload types serialize correctly
   - Fragment assembly

2. **Proxy Mode Tests**
   - Event serialization without partial
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
   - Error handling

## File Structure

```
zig/src/
├── protocol/
│   ├── types.zig           # Protocol message types
│   ├── envelope.zig        # Envelope wrapper
│   ├── proxy_types.zig     # Proxy mode event types
│   ├── proxy_serializer.zig # Proxy event serialization
│   ├── proxy_reconstructor.zig # Client-side reconstruction
│   ├── server.zig          # Server-side handling
│   └── client.zig          # Client-side handling
├── transports/
│   ├── stdio.zig           # (existing)
│   ├── sse.zig             # (existing)
│   └── websocket.zig       # (new)
├── transport.zig           # (modify for envelope support)
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
try server.handleEnvelope(envelope, sender);
```

### Client Usage

```zig
var reconstructor = protocol.proxy_reconstructor.ProxyReconstructor.init(allocator, "claude-3-opus");
defer reconstructor.deinit();

// Process proxy events
for (proxy_events) |event| {
    try reconstructor.processEvent(event);
}

// Get reconstructed message
const partial = reconstructor.getPartial();
```

### Proxy Server Usage

```zig
// Convert full events to proxy events for bandwidth optimization
var serializer = protocol.proxy_serializer.ProxySerializer.init(allocator);

const full_stream = try stream_simple.stream(model, context, options, allocator);
var event = try full_stream.wait();
while (!full_stream.isDone()) : (event = try full_stream.wait()) {
    const proxy_json = try serializer.serializeEvent(allocator, event, request_id);
    defer allocator.free(proxy_json);
    try sender.write(proxy_json);
    try sender.write("\n");
}
```

## Timeline Summary

| Phase | Duration | Dependencies |
|-------|----------|--------------|
| Phase 1: Protocol Types | 1-2 days | None |
| Phase 2: Proxy Mode | 2-3 days | Phase 1 |
| Phase 3: Envelope Serialization | 1 day | Phase 1 |
| Phase 4: WebSocket Transport | 2-3 days | Phase 3 |
| Phase 5: Request/Response Handling | 1-2 days | Phase 3 |
| Phase 6: Integration & Testing | 2 days | All phases |

**Total Estimated Time**: 9-13 days

## Success Criteria

1. ✅ All protocol types defined with JSON serialization
2. ✅ Proxy mode reduces bandwidth by ~50-70% for typical streams
3. ✅ Client-side reconstruction produces identical partial messages
4. ✅ WebSocket transport passes all tests
5. ✅ Concurrent streams work correctly with request_id correlation
6. ✅ Abort requests terminate streams immediately
7. ✅ All transports (stdio, SSE, WebSocket) work with protocol layer
