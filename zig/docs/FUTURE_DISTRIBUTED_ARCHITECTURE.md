# Makai Distributed Architecture Vision

This document outlines the future vision for Makai's fully distributed architecture, where users, agent-loops, providers, and tool executions can all run on separate machines.

## Current State (PR #9)

### Protocol Layer Structure

```
zig/src/protocol/
├── types.zig              # Core types: UUID, Envelope, Payload, ErrorCode
├── envelope.zig           # JSON serialization/deserialization for envelopes
├── server.zig             # Server-side protocol handler
├── client.zig             # Client-side protocol handler
├── partial_serializer.zig # Server-side partial state serialization
├── partial_reconstructor.zig # Client-side message reconstruction
└── content_partial.zig    # Lightweight partial state types
```

### Current RPC Support

| Layer | RPC Support | Status |
|-------|-------------|--------|
| User → Agent-Loop | ✅ ProtocolClient/Server | Ready |
| Agent-Loop → Provider | ✅ ProtocolClient/Server | Ready |
| Agent-Loop → Tools | ❌ Not yet | Needs design |

## Architecture Comparison

### pi-mono Architecture (Reference)

```
┌─────────────────────────────────────────────────────────────────┐
│                        pi-mono Process                          │
│                                                                 │
│  ┌──────────────┐     Same Process     ┌──────────────────┐   │
│  │    Agent     │ ──────────────────►  │   API Registry   │   │
│  │  AgentLoop   │                      │                  │   │
│  │              │  ◄────────────────── │ Providers        │   │
│  └──────────────┘   Events/Results     │ (OpenAI, etc.)   │   │
│         │                           └──────────────────┘   │
│         │                                                    │
│         │ Optional RPC Mode (stdio JSON Lines)              │
│         ▼                                                    │
│  ┌──────────────┐                                          │
│  │  RPC Server  │ ◄──── stdin (commands)                   │
│  │              │ ────► stdout (responses/events)           │
│  └──────────────┘                                          │
└─────────────────────────────────────────────────────────────┘
```

pi-mono builds RPC on top of agent-loop layer only. All providers run in the same process.

### Makai Architecture (Current)

```
┌─────────────────────────────────────────────────────────────────┐
│                        Makai Process                            │
│                                                                 │
│  ┌──────────────┐     Same Process     ┌──────────────────┐   │
│  │  Agent-Loop  │ ──────────────────►  │    Provider      │   │
│  │   (future)   │                      │    Registry      │   │
│  │              │  ◄────────────────── │ (OpenAI, etc.)   │   │
│  └──────────────┘   Events/Results     └──────────────────┘   │
│                                                                 │
│  OR use Protocol layer for remote access                        │
│                                                                 │
│  ┌──────────────┐     Protocol        ┌──────────────────┐   │
│  │ProtocolClient│ ═════════════════►  │ ProtocolServer   │   │
│  │              │     (network)        │ + Providers      │   │
│  │              │ ◄═════════════════   │                  │   │
│  └──────────────┘   Envelopes          └──────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

Makai supports RPC at both the provider layer AND the agent-loop layer.

### Makai Architecture (Future: Fully Distributed)

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│    User     │     │ Agent-Loop  │     │  Provider   │     │   Tools     │
│  (Machine A)│     │ (Machine B) │     │ (Machine C) │     │ (Machine D) │
│             │     │             │     │             │     │             │
│ Protocol    │◄───►│ Protocol    │◄───►│ Protocol    │     │             │
│ Client      │     │ Server+     │     │ Server      │     │             │
│             │     │ Client      │     │             │     │             │
│             │     │             │     │             │     │             │
│             │     │ Tool RPC    │◄═══════════════════════►│ Tool Server │
│             │     │ Client      │     │             │     │ (bash, etc.)│
└─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
      │                    │                   │                    │
      └────────────────────┴───────────────────┴────────────────────┘
                     All connected via Protocol layer
```

## Same-Process Options

### Stdio Transport (Thread-based)

```
┌──────────────────────────────────────────────────────────────┐
│                         Single Process                        │
│                                                              │
│  ┌──────────────┐    stdin/stdout    ┌──────────────────┐   │
│  │  Agent-Loop  │ ◄───────────────► │ ProtocolServer   │   │
│  │ (Main Thread)│                    │ + Providers      │   │
│  │              │   stdio.zig        │ (Worker Thread)  │   │
│  └──────────────┘                    └──────────────────┘   │
│        │                                                      │
│        └── Uses ProtocolClient                                │
│            with stdio Sender/Receiver                         │
└──────────────────────────────────────────────────────────────┘
```

### In-Process Transport (Future: Zero-copy)

```
┌──────────────────────────────────────────────────────────────┐
│                         Single Process                        │
│                                                              │
│  ┌──────────────┐   Lock-free Queue   ┌──────────────────┐  │
│  │  Agent-Loop  │ ═════════════════► │ ProtocolServer   │  │
│  │ (Thread A)   │                     │ + Providers      │  │
│  │              │ ◄═════════════════  │ (Thread B)       │  │
│  └──────────────┘   Events/Results    └──────────────────┘  │
│                                                              │
│  No serialization! Direct struct passing through queue       │
└──────────────────────────────────────────────────────────────┘
```

| Feature | Stdio Transport | In-Process (future) |
|---------|-----------------|---------------------|
| Zero-copy | ❌ (serializes to JSON) | ✅ (passes structs) |
| Thread-safe | ✅ | ✅ |
| Debuggable | ✅ (can log JSON) | ✅ |
| Isolation | Medium | Low |
| Latency | Low (pipe) | Very low (memory) |
| Already exists | ✅ | ❌ |

## Remote Tool Execution Design

### Proposed Protocol Extensions

```zig
// Add to Payload union in types.zig
pub const Payload = union(enum) {
    // Existing...
    stream_request: StreamRequest,
    event: AssistantMessageEvent,

    // NEW: Tool execution
    tool_request: ToolRequest,    // Agent → Tool Server
    tool_response: ToolResponse,  // Tool Server → Agent
};

pub const ToolRequest = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    arguments: []const u8,  // JSON
    timeout_ms: ?u64 = null,
};

pub const ToolResponse = struct {
    tool_call_id: []const u8,
    result: []const u8,  // JSON or text
    is_error: bool = false,
    exit_code: ?i32 = null,  // For bash
};
```

### Streaming Tool Events (for long-running tools)

```zig
pub const ToolEvent = union(enum) {
    tool_start: struct {
        tool_call_id: []const u8,
        tool_name: []const u8,
    },
    tool_stdout: struct {
        tool_call_id: []const u8,
        delta: []const u8,
    },
    tool_stderr: struct {
        tool_call_id: []const u8,
        delta: []const u8,
    },
    tool_end: struct {
        tool_call_id: []const u8,
        exit_code: i32,
        is_error: bool,
    },
};
```

### Architecture with Remote Tools

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Machine B: Agent-Loop                         │
│                                                                      │
│  ┌────────────┐     ┌────────────┐     ┌────────────────────────┐  │
│  │   Agent    │────►│  Protocol  │────►│  Tool Router/Client    │  │
│  │   Loop     │     │  Server    │     │                        │  │
│  │            │     │            │     │  Routes tool_calls to  │  │
│  │ Receives:  │◄────│            │◄────│  appropriate servers   │  │
│  │ toolcall_  │     │            │     │                        │  │
│  │ start/delta│     │            │     │  tool_request ──────►  │  │
│  │            │     │            │     │  ◄──── tool_response   │  │
│  └────────────┘     └────────────┘     └────────────────────────┘  │
│                                                │                     │
└────────────────────────────────────────────────│─────────────────────┘
                                                 │
                    ┌────────────────────────────┼────────────────────────┐
                    │                            │                        │
                    ▼                            ▼                        ▼
           ┌──────────────┐            ┌──────────────┐         ┌──────────────┐
           │  Machine D1  │            │  Machine D2  │         │  Machine D3  │
           │ Tool Server  │            │ Tool Server  │         │ Tool Server  │
           │              │            │              │         │              │
           │ - bash       │            │ - filesystem │         │ - sandboxed  │
           │ - git        │            │ - editor     │         │ - untrusted  │
           │ - safe tools │            │              │         │   execution  │
           └──────────────┘            └──────────────┘         └──────────────┘
```

### Security Benefits of Distributed Tools

| Tool Type | Machine | Why Separate? |
|-----------|---------|---------------|
| Safe tools (read_file) | D1 | Standard operations |
| Privileged tools (deploy) | D2 | Needs production access |
| Untrusted tools (user_script) | D3 | Sandboxed/isolated |
| Filesystem | D4 | Different disk access |

## Comparison: pi-mono vs Makai

| Aspect | pi-mono (TypeScript) | Makai (Zig) |
|--------|---------------------|-------------|
| **Default Mode** | Same-process | Same-process |
| **RPC Mode** | Optional (JSON Lines/stdio) | Via Protocol layer |
| **Event Stream** | AsyncIterable (push/wait) | Lock-free ring buffer + futex |
| **Provider Registry** | Map<apiType, streamFn> | ProviderV2 interface |
| **Transports** | SSE, WebSocket | SSE, stdio (WS planned) |
| **Steering** | ✅ Built-in | ❌ Not yet |
| **Session Management** | ✅ Compaction, branching | ❌ Not yet |
| **Tools** | ✅ Built-in execution | ❌ Events only |
| **Extensions** | ✅ Full system | ❌ Not yet |
| **Proxy Auth** | ✅ Built-in | ✅ Via ProtocolServer |
| **Distributed Tools** | ❌ Same process | ✅ Designed for it |

### What Makai Could Learn from pi-mono

1. **Steering Queue** - Ability to interrupt/steer mid-stream
2. **Tool Execution Events** - `tool_execution_start/update/end`
3. **Extension UI Protocol** - Interactive prompts during execution
4. **Session Compaction** - Pruning context when it gets too large

### What pi-mono Could Learn from Makai

1. **Binary Protocol Option** - Zero-copy in-process transport
2. **Lock-free Streaming** - Better performance under load
3. **Type-safe Zig** - Compile-time guarantees
4. **Proxy Mode** - Bandwidth-optimized events (no partial field)
5. **Distributed Architecture** - Tools on separate machines

## Implementation Roadmap

### Phase 1: Foundation (Current - PR #9)
- [x] Protocol types (Envelope, Payload, ErrorCode)
- [x] Client/Server handlers
- [x] Partial serialization/reconstruction
- [x] Sequence validation
- [x] Control messages (ping, pong, ack, nack, goodbye, sync)

### Phase 2: Agent-Loop Layer
- [ ] Agent-loop implementation using protocol
- [ ] Turn management
- [ ] Steering/follow-up queues
- [ ] Session state management

### Phase 3: Tool Protocol
- [ ] Add `tool_request`/`tool_response` to Payload
- [ ] ToolServer implementation
- [ ] ToolRouter in agent-loop
- [ ] Streaming tool events

### Phase 4: Advanced Features
- [ ] Tool registration/discovery
- [ ] In-process transport (zero-copy)
- [ ] WebSocket transport
- [ ] Session compaction

### Phase 5: Production Hardening
- [ ] Security (TLS, auth)
- [ ] Load balancing
- [ ] Failover/recovery
- [ ] Monitoring/observability

## Usage Examples

### Client-Side (Connecting to Provider)

```zig
const std = @import("std");
const protocol = @import("protocol");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create client with options
    var client = protocol.client.ProtocolClient.init(allocator, .{
        .include_partial = true,
        .request_timeout_ms = 30000,
    });
    defer client.deinit();

    // Set up transport sender
    // client.setSender(&sender);

    // Send stream request
    const model = protocol.types.Model{ .name = "gpt-4o" };
    var context = protocol.types.Context{ .messages = &.{} };
    const stream_id = try client.sendStreamRequest(model, context, null);

    // Process incoming events
    const event_stream = client.getEventStream();
    while (!client.isComplete()) {
        const event = event_stream.wait(1000) catch null;
        if (event) |e| {
            // Handle: start, text_delta, toolcall_start, done, etc.
        }
    }

    // Get final result
    if (client.waitResult(5000)) |result| {
        // Use AssistantMessage
    } else |_| {
        // Handle error
    }
}
```

### Server-Side (Provider Proxy)

```zig
const std = @import("std");
const protocol = @import("protocol");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create server
    var server = protocol.server.ProtocolServer.init(allocator, null, .{
        .include_partial = true,
        .max_streams = 100,
        .stream_timeout_ms = 60000,
    });
    defer server.deinit();

    // Handle incoming envelopes
    // const envelope = try protocol.envelope.deserializeEnvelope(data, allocator);
    // const response = try server.handleEnvelope(envelope);
}
```

## References

- [PROTOCOL.md](./PROTOCOL.md) - Wire protocol specification
- [PROTOCOL_IMPLEMENTATION_PLAN.md](./PROTOCOL_IMPLEMENTATION_PLAN.md) - Implementation details
- pi-mono: https://github.com/badlogic/pi-mono - TypeScript reference implementation
