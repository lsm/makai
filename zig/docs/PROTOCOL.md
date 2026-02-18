# Makai Wire Protocol Specification v1.0.0

## Table of Contents

1. [Overview](#1-overview)
2. [Design Principles](#2-design-principles)
3. [Message Taxonomy](#3-message-taxonomy)
4. [Wire Format Specification](#4-wire-format-specification)
5. [Transport Mappings](#5-transport-mappings)
6. [JSON Schema Definitions](#6-json-schema-definitions)
7. [Protocol Lifecycle](#7-protocol-lifecycle)
8. [Error Handling](#8-error-handling)
9. [Extension Mechanisms](#9-extension-mechanisms)
10. [Examples](#10-examples)
11. [Security](#11-security)
12. [Memory Ownership](#12-memory-ownership)

---

## 1. Overview

### 1.1 Purpose

The Makai Wire Protocol provides a standardized communication format for AI streaming interactions between clients, proxies, and AI providers. It is designed to:

- Enable bidirectional streaming of AI requests and responses
- Support multiple transport layers (stdio, WebSocket, gRPC, SSE, etc.)
- Optimize bandwidth for proxy scenarios with `include_partial` flag
- Support cancellation and abort operations
- Be extensible for future agent loop events

### 1.2 Protocol Version

```
MAKAI/1.0.0
```

Version negotiation is handled at the transport layer:

| Transport | Negotiation Method |
|-----------|-------------------|
| WebSocket | Subprotocol: `Sec-WebSocket-Protocol: makai.v1` |
| HTTP | Header: `X-Makai-Version: 1.0.0` |
| gRPC | Metadata key: `makai-version` |
| stdio | Initial handshake line: `MAKAI/1.0.0` |

### 1.3 Terminology

- **Client**: The entity initiating an AI request
- **Server**: The entity processing requests (may be a proxy or direct provider)
- **Stream**: A logical bidirectional channel for request/response pairs
- **Event**: An atomic message within a stream (e.g., text delta, tool call)
- **Partial Message**: The cumulative state of an assistant message being built
- **include_partial**: Flag to include per-block partial state in events

---

## 2. Design Principles

### 2.1 Transport Agnostic

The protocol defines message semantics independently of the transport. Transport-specific adaptations are defined in Section 5.

### 2.2 Bandwidth Optimized

The `include_partial` flag controls partial message data in events:

1. **include_partial: false** (default): Events omit partial; client reconstructs locally (bandwidth optimized)
2. **include_partial: true**: Events include per-block partial state (simpler client logic)

### 2.3 Streaming First

All operations are designed for streaming from the ground up:
- Requests can be sent while previous responses are still streaming
- Events are emitted incrementally as content is generated
- Backpressure is handled via transport-level flow control

### 2.4 Type Safe

All messages are strongly typed with explicit discriminated unions (via `type` field) for reliable parsing.

---

## 3. Message Taxonomy

### 3.1 Top-Level Categories

```
Envelope
  |-- Request          (client -> server)
  |-- Response         (server -> client, immediate)
  |-- Event            (server -> client, streaming)
  |-- Control          (bidirectional)
```

### 3.2 Message Type Hierarchy

```
Request
  |-- stream_request      - Initiate a streaming AI request
  |-- complete_request    - Initiate a non-streaming AI request
  |-- abort_request       - Cancel an in-flight request

Event
  |-- start               - Stream started
  |-- text_start          - Text content block started
  |-- text_delta          - Text content increment
  |-- text_end            - Text content block completed
  |-- thinking_start      - Thinking block started
  |-- thinking_delta      - Thinking content increment
  |-- thinking_end        - Thinking block completed
  |-- toolcall_start      - Tool call started
  |-- toolcall_delta      - Tool call arguments increment
  |-- toolcall_end        - Tool call completed
  |-- image_start         - Image generation started (future)
  |-- image_delta         - Image data increment (future)
  |-- image_end           - Image completed (future)
  |-- done                - Stream completed successfully
  |-- error               - Stream error
  |-- keepalive           - Stream-level keepalive

Control
  |-- ack                 - Acknowledgment
  |-- nack                - Negative acknowledgment
  |-- ping                - Connection-level transport keepalive
  |-- pong                - Connection-level keepalive response
  |-- goodbye             - Graceful connection close *(planned for v1.1)*
  |-- sync_request        - Request full state resync *(planned for v1.1)*
  |-- sync                - Full partial state resync *(planned for v1.1)*

Response
  |-- stream_error        - Stream-level error
```

**Note on Non-Streaming Mode**: The protocol includes `complete_request` for non-streaming operations (see [CompleteRequest schema](#completerequest)). This returns a single `result` envelope containing the final `AssistantMessage`. For compatibility with streaming-only clients, non-streaming can also be implemented as streaming with all events buffered until `done` is received.

---

## 4. Wire Format Specification

### 4.1 Envelope Structure

All messages are wrapped in an envelope:

```json
{
  "type": "<message_type>",
  "stream_id": "<stable-uuid>",
  "message_id": "<unique-uuid>",
  "sequence": <u32>,
  "timestamp": <unix_ms>,
  "in_reply_to": "<correlated_message_id>",
  "payload": { ... }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | Yes | Message type discriminator |
| `stream_id` | string (UUID) | Yes | Stable identifier for stream lifecycle |
| `message_id` | string (UUID) | Yes | Unique identifier for each envelope |
| `sequence` | integer | **Yes** | Sequence number for ordering (required, starts at 1) |
| `timestamp` | integer | No | Unix timestamp in milliseconds |
| `in_reply_to` | string | No | Correlates response to original message (for ack/nack) |
| `payload` | object | Yes | Type-specific message content |

**Note**: Message fragmentation is handled by the transport layer. The protocol does not include fragmentation fields.

#### 4.1.1 Sequence Scope

The `sequence` field has per-stream scope:

- **Monotonically increasing**: Sequence numbers increment by 1 for each message within a single `stream_id`
- **Starts at 1**: The first message for any stream has `sequence: 1`
- **Resets per stream**: Each new `stream_id` starts its own independent sequence counter

This allows clients to detect missing or out-of-order messages on a per-stream basis.

#### 4.1.2 Identifier Semantics

The following rules govern identifier generation and usage:

- **`stream_id`**:
  - Client generates the `stream_id` for all requests (e.g., in `stream_request`)
  - Server echoes the same `stream_id` in all response events for that stream
  - Must be a valid UUID v4 format (36 characters: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)

- **`message_id`**:
  - The sender of each envelope generates a unique `message_id`
  - Used for correlation via `in_reply_to` field in acknowledgments

**Connection-level sentinel**: Messages that are not associated with any particular stream (e.g., connection-level control messages) use the reserved nil UUID `00000000-0000-0000-0000-000000000000` as the `stream_id`.

### 4.2 Encoding Modes

#### include_partial: false (Default - Bandwidth Optimized)

Events omit full `partial` message; client reconstructs:

```json
{
  "type": "text_delta",
  "stream_id": "stream-123",
  "message_id": "msg-456",
  "sequence": 3,
  "payload": {
    "content_index": 0,
    "delta": "Hello"
  }
}
```

#### include_partial: true (Per-Block Partial)

Events include lightweight per-block partial state:

```json
{
  "type": "text_delta",
  "stream_id": "stream-123",
  "message_id": "msg-456",
  "sequence": 3,
  "include_partial": true,
  "payload": {
    "content_index": 0,
    "delta": " world",
    "partial": {
      "current_text": "Hello world"
    }
  }
}
```

The `partial` object in events with `include_partial: true` contains only the relevant partial state for that content block type:

- **Text events**: `{ "current_text": "accumulated text" }`
- **Thinking events**: `{ "current_thinking": "accumulated thinking" }`
- **Tool call events**: `{ "current_arguments_json": "{\"partial\":..." }`

---

## 5. Transport Mappings

### 5.1 Stdio Transport

**Framing**: Line-delimited JSON (LDJSON)

Each message is a single line ending with `\n`:

```
{"type":"stream_request","stream_id":"stream-1","message_id":"msg-1","sequence":1,"payload":{...}}\n
{"type":"start","stream_id":"stream-1","message_id":"msg-2","sequence":2,"payload":{...}}\n
{"type":"text_delta","stream_id":"stream-1","message_id":"msg-3","sequence":3,"payload":{...}}\n
```

**Version Negotiation**: Initial handshake line before any messages:
```
MAKAI/1.0.0\n
```

**Implementation Notes**:
- Use LF (`\n`) only, not CRLF
- Maximum line length: 16 MB
- Empty lines should be ignored
- Stdin receives requests, stdout sends responses/events

### 5.2 SSE (Server-Sent Events) Transport

**Framing**: Standard SSE format

```
event: message
data: {"type":"start","stream_id":"stream-1","message_id":"msg-1","sequence":1,"payload":{...}}

event: message
data: {"type":"text_delta","stream_id":"stream-1","message_id":"msg-2","sequence":2,"payload":{...}}

```

**Custom Event Types**:
- `message`: Regular event
- `control`: Control message
- `error`: Error message

**Version Negotiation**: HTTP header `X-Makai-Version: 1.0.0`

**Implementation Notes**:
- Standard SSE parsing rules apply
- Multi-line `data:` fields are concatenated with newlines
- `event:` field distinguishes message categories

### 5.3 WebSocket Transport

**Framing**: WebSocket text frames

Each frame contains a single JSON message. Binary frames are reserved for future use (e.g., binary protocol buffers).

**Subprotocol Name**: `makai.v1`

**Connection Flow**:
```
Client -> Server: WebSocket handshake with Sec-WebSocket-Protocol: makai.v1
Server -> Client: Accept with selected protocol
Client -> Server: {"type":"stream_request", "stream_id":"...", ...}
Server -> Client: {"type":"start", ...} (multiple frames)
```

**Version Negotiation**: Subprotocol `Sec-WebSocket-Protocol: makai.v1`

**Ping/Pong**:
- Use native WebSocket ping/pong frames for keepalive
- Protocol-level `ping`/`pong` messages are also supported for application-level heartbeats

#### WebSocket Transport (Beta)

The WebSocket transport is currently in **beta** status. The following limitations apply:

| Limitation | Status | Workaround |
|------------|--------|------------|
| TLS (`wss://`) | Not implemented | Use reverse proxy (nginx, Caddy) for TLS termination |
| Continuation frames | Incomplete | Messages must fit in single frame (<125KB typical) |
| DNS resolution | Brittle | Use IP addresses for now |
| Handshake validation | Simplified | Works with compliant servers |

**Production recommendation**: Use a reverse proxy for TLS termination until `wss://` support is added.

These limitations will be addressed in a future release.

### 5.4 gRPC Transport

**Service Definition** (protobuf):

```protobuf
syntax = "proto3";

package makai.v1;

service MakaiService {
  // Bidirectional streaming
  rpc Stream(stream Envelope) returns (stream Envelope);

  // Unary (non-streaming)
  rpc Complete(Envelope) returns (Envelope);
}

message Envelope {
  string type = 1;
  string stream_id = 2;
  string message_id = 3;
  uint32 sequence = 4;
  int64 timestamp = 5;
  string in_reply_to = 6;
  bytes payload = 7;  // JSON-encoded
  bool include_partial = 8;
}
```

**Version Negotiation**: gRPC metadata key `makai-version: 1.0.0`

**Implementation Notes**:
- Payload is JSON-encoded for consistency with other transports
- Binary protobuf payload encoding may be added as an extension
- Use gRPC metadata for authentication

### 5.5 HTTP/2 Transport

**Framing**: HTTP/2 streams with chunked transfer encoding

**Endpoints**:
- `POST /v1/stream` - Streaming requests (SSE response)
- `POST /v1/complete` - Non-streaming requests (JSON response)
- `POST /v1/abort` - Abort in-flight request

**Request Headers**:
```
Content-Type: application/json
Accept: text/event-stream
X-Makai-Version: 1.0.0
```

---

## 6. JSON Schema Definitions

### 6.1 Common Types

#### ContentBlock (include_partial: true)

```json
{
  "oneOf": [
    {
      "type": "object",
      "properties": {
        "type": { "const": "text" },
        "text": { "type": "string" },
        "signature": { "type": "string" }
      },
      "required": ["type", "text"]
    },
    {
      "type": "object",
      "properties": {
        "type": { "const": "thinking" },
        "thinking": { "type": "string" },
        "signature": { "type": "string" }
      },
      "required": ["type", "thinking"]
    },
    {
      "type": "object",
      "properties": {
        "type": { "const": "tool_call" },
        "id": { "type": "string" },
        "name": { "type": "string" },
        "input_json": { "type": "string" },
        "thought_signature": { "type": "string" }
      },
      "required": ["type", "id", "name", "input_json"]
    },
    {
      "type": "object",
      "properties": {
        "type": { "const": "image" },
        "media_type": { "type": "string" },
        "data": { "type": "string" }
      },
      "required": ["type", "media_type", "data"]
    }
  ]
}
```

#### Usage

```json
{
  "type": "object",
  "properties": {
    "input": { "type": "integer", "minimum": 0 },
    "output": { "type": "integer", "minimum": 0 },
    "cache_read": { "type": "integer", "minimum": 0 },
    "cache_write": { "type": "integer", "minimum": 0 },
    "total_tokens": { "type": "integer", "minimum": 0 },
    "cost": {
      "type": "object",
      "properties": {
        "input": { "type": "number" },
        "output": { "type": "number" },
        "cache_read": { "type": "number" },
        "cache_write": { "type": "number" },
        "total": { "type": "number" }
      }
    }
  },
  "required": ["input", "output"]
}
```

#### StopReason

```json
{
  "type": "string",
  "enum": ["stop", "length", "tool_use", "content_filter", "error", "aborted"]
}
```

#### Tool

```json
{
  "type": "object",
  "properties": {
    "name": { "type": "string" },
    "description": { "type": "string" },
    "parameters_schema_json": { "type": "string" }
  },
  "required": ["name", "parameters_schema_json"]
}
```

#### UserMessage

```json
{
  "type": "object",
  "properties": {
    "role": { "const": "user" },
    "content": {
      "oneOf": [
        { "type": "string" },
        {
          "type": "array",
          "items": {
            "oneOf": [
              {
                "type": "object",
                "properties": {
                  "type": { "const": "text" },
                  "text": { "type": "string" }
                },
                "required": ["type", "text"]
              },
              {
                "type": "object",
                "properties": {
                  "type": { "const": "image" },
                  "source": {
                    "type": "object",
                    "properties": {
                      "type": { "type": "string" },
                      "media_type": { "type": "string" },
                      "data": { "type": "string" }
                    }
                  }
                },
                "required": ["type", "source"]
              }
            ]
          }
        }
      ]
    },
    "timestamp": { "type": "integer" }
  },
  "required": ["role", "content"]
}
```

#### AssistantMessage

```json
{
  "type": "object",
  "properties": {
    "role": { "const": "assistant" },
    "content": {
      "type": "array",
      "items": { "$ref": "#/$defs/ContentBlock" }
    },
    "usage": { "$ref": "#/$defs/Usage" },
    "stop_reason": { "$ref": "#/$defs/StopReason" },
    "model": { "type": "string" },
    "api": {
      "type": "string",
      "description": "The API identifier used for this response"
    },
    "provider": {
      "type": "string",
      "description": "The provider name that handled this request"
    },
    "timestamp": { "type": "integer" }
  },
  "required": ["role", "content", "usage", "stop_reason", "model", "api", "provider"]
}
```

#### Message

A discriminated union of UserMessage and AssistantMessage for use in Context.messages.

```json
{
  "oneOf": [
    { "$ref": "#/$defs/UserMessage" },
    { "$ref": "#/$defs/AssistantMessage" }
  ]
}
```

### 6.2 Request Messages

#### StreamRequest

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "stream_request" },
    "stream_id": { "type": "string", "format": "uuid" },
    "message_id": { "type": "string", "format": "uuid" },
    "sequence": { "type": "integer", "minimum": 1 },
    "timestamp": { "type": "integer" },
    "payload": {
      "type": "object",
      "properties": {
        "model": { "$ref": "#/$defs/Model" },
        "context": { "$ref": "#/$defs/Context" },
        "options": { "$ref": "#/$defs/StreamOptions" },
        "include_partial": {
          "type": "boolean",
          "description": "If true, include lightweight partials in events (default: false)"
        }
      },
      "required": ["model", "context"]
    }
  },
  "required": ["type", "stream_id", "message_id", "sequence", "payload"]
}
```

#### CompleteRequest

Request for non-streaming AI completion. Unlike `stream_request`, this returns a single response envelope containing the final `AssistantMessage` without intermediate streaming events.

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "complete_request" },
    "stream_id": { "type": "string", "format": "uuid" },
    "message_id": { "type": "string", "format": "uuid" },
    "sequence": { "type": "integer", "minimum": 1 },
    "timestamp": { "type": "integer" },
    "payload": {
      "type": "object",
      "properties": {
        "model": { "$ref": "#/$defs/Model" },
        "context": { "$ref": "#/$defs/Context" },
        "options": { "$ref": "#/$defs/StreamOptions" }
      },
      "required": ["model", "context"]
    }
  },
  "required": ["type", "stream_id", "message_id", "sequence", "payload"]
}
```

**Response**: The server returns a single envelope with `type: "result"` containing the final `AssistantMessage` in the payload.

#### Model

```json
{
  "type": "object",
  "properties": {
    "id": { "type": "string" },
    "name": { "type": "string" },
    "api": { "type": "string" },
    "provider": { "type": "string" },
    "base_url": { "type": "string" },
    "reasoning": { "type": "boolean" },
    "cost": { "$ref": "#/$defs/Cost" },
    "context_window": { "type": "integer" },
    "max_tokens": { "type": "integer" }
  },
  "required": ["id", "name", "api", "provider", "base_url"]
}
```

#### Context

```json
{
  "type": "object",
  "properties": {
    "system_prompt": { "type": "string" },
    "messages": {
      "type": "array",
      "items": { "$ref": "#/$defs/Message" }
    },
    "tools": {
      "type": "array",
      "items": { "$ref": "#/$defs/Tool" }
    }
  },
  "required": ["messages"]
}
```

#### StreamOptions

```json
{
  "type": "object",
  "properties": {
    "temperature": { "type": "number", "minimum": 0, "maximum": 2 },
    "max_tokens": { "type": "integer", "minimum": 1 },
    "cache_retention": { "enum": ["none", "short", "long"] },
    "session_id": { "type": "string" },
    "thinking_enabled": { "type": "boolean" },
    "thinking_budget_tokens": { "type": "integer" },
    "thinking_effort": { "enum": ["low", "medium", "high", "max"] },
    "reasoning_effort": { "enum": ["minimal", "low", "medium", "high", "xhigh"] },
    "service_tier": { "enum": ["default", "flex", "priority"] },
    "tool_choice": {
      "oneOf": [
        { "enum": ["auto", "none", "required"] },
        { "type": "object", "properties": { "function": { "type": "string" } } }
      ]
    },
    "http_timeout_ms": { "type": "integer" },
    "ping_interval_ms": { "type": "integer" }
  }
}
```

**Note**: API keys are NOT included in StreamOptions. They are passed via transport headers only (see Section 11).

#### AbortRequest

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "abort_request" },
    "stream_id": { "type": "string", "format": "uuid" },
    "message_id": { "type": "string", "format": "uuid" },
    "sequence": { "type": "integer", "minimum": 1 },
    "payload": {
      "type": "object",
      "properties": {
        "target_stream_id": { "type": "string", "format": "uuid" },
        "reason": { "type": "string" }
      },
      "required": ["target_stream_id"]
    }
  },
  "required": ["type", "stream_id", "message_id", "sequence", "payload"]
}
```

### 6.3 Event Messages

**include_partial Immutability**: The `include_partial` flag is immutable for the lifetime of a stream. It is set once in the `stream_request` and cannot be changed mid-stream. If a client needs to change the partial inclusion mode, it must start a new stream.

#### StartEvent

When `include_partial: false`, the start event includes model and initial token info:

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "start" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "payload": {
      "type": "object",
      "properties": {
        "model": { "type": "string" },
        "input_tokens": { "type": "integer" }
      },
      "required": ["model"]
    }
  }
}
```

#### TextStartEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "text_start" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 }
      },
      "required": ["content_index"]
    }
  }
}
```

#### TextDeltaEvent (include_partial: false)

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "text_delta" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 },
        "delta": { "type": "string" }
      },
      "required": ["content_index", "delta"]
    }
  }
}
```

#### TextDeltaEvent (include_partial: true)

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "text_delta" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "include_partial": { "const": true },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 },
        "delta": { "type": "string" },
        "partial": {
          "type": "object",
          "properties": {
            "current_text": { "type": "string" }
          },
          "required": ["current_text"]
        }
      },
      "required": ["content_index", "delta", "partial"]
    }
  }
}
```

#### TextEndEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "text_end" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 },
        "text": { "type": "string" },
        "signature": { "type": "string" }
      },
      "required": ["content_index"]
    }
  }
}
```

#### ThinkingStartEvent (include_partial: false)

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "thinking_start" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 }
      },
      "required": ["content_index"]
    }
  }
}
```

#### ThinkingStartEvent (include_partial: true)

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "thinking_start" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "include_partial": { "const": true },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 },
        "partial": {
          "type": "object",
          "properties": {
            "current_thinking": { "type": "string" }
          },
          "required": ["current_thinking"]
        }
      },
      "required": ["content_index", "partial"]
    }
  }
}
```

#### ThinkingDeltaEvent (include_partial: false)

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "thinking_delta" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 },
        "delta": { "type": "string" }
      },
      "required": ["content_index", "delta"]
    }
  }
}
```

#### ThinkingDeltaEvent (include_partial: true)

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "thinking_delta" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "include_partial": { "const": true },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 },
        "delta": { "type": "string" },
        "partial": {
          "type": "object",
          "properties": {
            "current_thinking": { "type": "string" }
          },
          "required": ["current_thinking"]
        }
      },
      "required": ["content_index", "delta", "partial"]
    }
  }
}
```

#### ThinkingEndEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "thinking_end" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 },
        "thinking": { "type": "string" },
        "signature": { "type": "string" }
      },
      "required": ["content_index"]
    }
  }
}
```

#### ToolCallStartEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "toolcall_start" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 },
        "id": { "type": "string" },
        "name": { "type": "string" }
      },
      "required": ["content_index", "id", "name"]
    }
  }
}
```

#### ToolCallDeltaEvent (include_partial: false)

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "toolcall_delta" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 },
        "delta": { "type": "string" }
      },
      "required": ["content_index", "delta"]
    }
  }
}
```

#### ToolCallDeltaEvent (include_partial: true)

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "toolcall_delta" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "include_partial": { "const": true },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 },
        "delta": { "type": "string" },
        "partial": {
          "type": "object",
          "properties": {
            "current_arguments_json": { "type": "string" }
          },
          "required": ["current_arguments_json"]
        }
      },
      "required": ["content_index", "delta", "partial"]
    }
  }
}
```

#### ToolCallEndEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "toolcall_end" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 },
        "tool_call": { "$ref": "#/$defs/ToolCall" }
      },
      "required": ["content_index", "tool_call"]
    }
  }
}
```

#### DoneEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "done" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "payload": {
      "type": "object",
      "properties": {
        "reason": { "$ref": "#/$defs/StopReason" },
        "message": { "$ref": "#/$defs/AssistantMessage" }
      },
      "required": ["reason", "message"]
    }
  }
}
```

#### ErrorEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "error" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "payload": {
      "type": "object",
      "properties": {
        "reason": { "enum": ["error", "aborted"] },
        "error_message": { "type": "string" },
        "error_code": { "type": "string" },
        "usage": { "$ref": "#/$defs/Usage" }
      },
      "required": ["reason", "usage"]
    }
  }
}
```

**Note**: `usage` is REQUIRED in error events to allow proper token accounting.

### 6.4 Control Messages

#### AckControl

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "ack" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "in_reply_to": { "type": "string" },
    "payload": {
      "type": "object",
      "properties": {
        "acknowledged_id": { "type": "string" }
      },
      "required": ["acknowledged_id"]
    }
  }
}
```

#### NackControl

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "nack" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "in_reply_to": { "type": "string" },
    "payload": {
      "type": "object",
      "properties": {
        "rejected_id": { "type": "string" },
        "reason": { "type": "string" },
        "error_code": { "type": "string" },
        "supported_versions": {
          "type": "array",
          "items": { "type": "string" },
          "description": "List of protocol versions supported by the server (present when error_code is VERSION_MISMATCH)"
        }
      },
      "required": ["rejected_id", "reason"]
    }
  }
}
```

#### PingControl

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "ping" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "payload": {}
  }
}
```

#### PongControl

**Note**: In v1.0, the `pong` response is implemented as a simple `void` type without echo of `ping_id`. The `ping_id` field is documented here for forward compatibility and planned for v1.1.

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "pong" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "in_reply_to": { "type": "string" },
    "payload": {
      "type": "object",
      "properties": {
        "ping_id": { "type": "string", "description": "Echo of ping_id (optional in v1.0, required in v1.1+)" }
      },
      "required": []
    }
  }
}
```

#### GoodbyeControl

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "goodbye" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "payload": {
      "type": "object",
      "properties": {
        "reason": { "type": "string" }
      }
    }
  }
}
```

#### SyncRequestControl

Client sends `sync_request` to request a full state resync from the server. This is useful when the client has lost partial state and needs to reconstruct it.

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "sync_request" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "payload": {
      "type": "object",
      "properties": {
        "target_stream_id": { "type": "string" }
      },
      "required": ["target_stream_id"]
    }
  },
  "required": ["type", "stream_id", "message_id", "sequence", "payload"]
}
```

#### SyncControl

Server sends `sync` in response to a `sync_request`, containing the full partial state for the requested stream.

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "sync" },
    "stream_id": { "type": "string" },
    "message_id": { "type": "string" },
    "sequence": { "type": "integer" },
    "in_reply_to": { "type": "string" },
    "payload": {
      "type": "object",
      "properties": {
        "target_stream_id": { "type": "string" },
        "partial": { "$ref": "#/$defs/AssistantMessage" }
      },
      "required": ["target_stream_id", "partial"]
    }
  },
  "required": ["type", "stream_id", "message_id", "sequence", "in_reply_to", "payload"]
}
```

---

## 7. Protocol Lifecycle

### 7.1 Connection Establishment

```
Client                                      Server
  |                                           |
  |---------- StreamRequest ----------------->|
  |                                           |
  |<--------- Ack (or Nack with error) -------|
  |                                           |
  |<--------- StartEvent ---------------------|
  |                                           |
  |<--------- ... streaming events ... -------|
  |                                           |
  |<--------- DoneEvent ----------------------|
  |                                           |
```

### 7.2 Version Negotiation (Transport Layer)

Version negotiation happens at the transport layer, not in the protocol messages:

**WebSocket**:
```
Client: Sec-WebSocket-Protocol: makai.v1
Server: Sec-WebSocket-Protocol: makai.v1 (in response)
```

**HTTP**:
```
Client: X-Makai-Version: 1.0.0
Server: X-Makai-Version: 1.0.0 (in response)
```

**gRPC**:
```
Client: metadata: makai-version=1.0.0
```

**stdio**:
```
Initial line: MAKAI/1.0.0
```

If version mismatch, server responds with Nack containing supported versions.

### 7.3 Streaming Flow

```
Client                                            Server
  |                                                 |
  |---- StreamRequest (stream_id: A) ------------->|
  |      (message_id: msg-1, sequence: 1)           |
  |                                                 |
  |<--- StartEvent (stream_id: A) -----------------|
  |      (message_id: msg-2, sequence: 2)           |
  |<--- TextStartEvent (stream_id: A) -------------|
  |      (message_id: msg-3, sequence: 3)           |
  |<--- TextDeltaEvent (stream_id: A) -------------|
  |      (message_id: msg-4, sequence: 4)           |
  |<--- TextDeltaEvent (stream_id: A) -------------|
  |      (message_id: msg-5, sequence: 5)           |
  |---- AbortRequest (target: A) ----------------->|  <-- Optional abort
  |      (message_id: msg-6, sequence: 6)           |
  |<--- ErrorEvent (reason: aborted) --------------|
  |      (message_id: msg-7, sequence: 7)           |
  |                                                 |
```

### 7.4 Concurrent Streams

Multiple streams are multiplexed using distinct `stream_id` values:

```
Client                                            Server
  |                                                 |
  |---- StreamRequest (stream_id: A) ------------->|
  |---- StreamRequest (stream_id: B) ------------->|
  |                                                 |
  |<--- TextDeltaEvent (stream_id: A) -------------|
  |<--- TextDeltaEvent (stream_id: B) -------------|  <-- Interleaved
  |<--- TextDeltaEvent (stream_id: A) -------------|
  |<--- DoneEvent (stream_id: A) ------------------|
  |<--- TextDeltaEvent (stream_id: B) -------------|
  |<--- DoneEvent (stream_id: B) ------------------|
```

### 7.5 Graceful Shutdown

```
Client                                            Server
  |                                                 |
  |---- GoodbyeControl --------------------------->|
  |                                                 |
  |<--- GoodbyeControl ----------------------------|
  |                                                 |
  | [Connection closed]                            |
```

---

## 8. Error Handling

### 8.1 Error Codes

| Code | Category | Description |
|------|----------|-------------|
| `VERSION_MISMATCH` | Protocol | Client version not supported |
| `INVALID_MESSAGE` | Protocol | Malformed message |
| `UNKNOWN_TYPE` | Protocol | Unknown message type |
| `MISSING_FIELD` | Protocol | Required field missing |
| `INVALID_STREAM_ID` | Protocol | Stream ID format invalid |
| `STREAM_NOT_FOUND` | Stream | Target stream does not exist |
| `STREAM_ALREADY_EXISTS` | Stream | Duplicate stream ID |
| `PROVIDER_ERROR` | Provider | Upstream provider error |
| `RATE_LIMITED` | Provider | Rate limit exceeded |
| `AUTHENTICATION_FAILED` | Auth | Invalid credentials |
| `AUTHORIZATION_FAILED` | Auth | Insufficient permissions |
| `CONTEXT_TOO_LARGE` | Context | Context exceeds limits |
| `MODEL_NOT_FOUND` | Model | Requested model unavailable |
| `INTERNAL_ERROR` | Server | Internal server error |
| `TIMEOUT` | Transport | Operation timed out |
| `CONNECTION_RESET` | Transport | Connection was reset |
| `BACKPRESSURE` | Transport | Backpressure limit exceeded |

### 8.2 Error Event Payload

```json
{
  "type": "error",
  "stream_id": "stream-123",
  "message_id": "msg-456",
  "sequence": 10,
  "payload": {
    "reason": "error",
    "error_code": "RATE_LIMITED",
    "error_message": "Rate limit exceeded. Retry after 60 seconds.",
    "retry_after_ms": 60000,
    "usage": {
      "input": 100,
      "output": 0
    }
  }
}
```

**Note**: `usage` is REQUIRED to allow proper token accounting even when errors occur.

### 8.3 Recovery Strategies

1. **Transient Errors**: Client should retry with exponential backoff
2. **Permanent Errors**: Client should not retry; fix the request
3. **Stream Errors**: Stream is terminated; check `reason` field
4. **Transport Errors**: Re-establish connection and retry

---

## 9. Extension Mechanisms

### 9.1 Extension Fields

Messages may include additional fields with `x_` prefix:

```json
{
  "type": "text_delta",
  "stream_id": "stream-123",
  "message_id": "msg-456",
  "sequence": 3,
  "payload": {
    "content_index": 0,
    "delta": "Hello",
    "x_sentiment": "positive"
  }
}
```

Implementations must ignore unknown `x_` prefixed fields.

### 9.2 New Event Types

Future event types should follow the naming convention:
- `{category}_{action}` for content events
- `{category}_start/delta/end` for streaming events

### 9.3 Agent Loop Events (Future)

Reserved event types for agentic workflows:

```json
// Agent requests tool execution
{ "type": "tool_request", "payload": { "tool_name": "...", "arguments": {} } }

// Tool execution result
{ "type": "tool_result", "payload": { "tool_call_id": "...", "result": {} } }

// Agent state change
{ "type": "agent_state", "payload": { "state": "thinking|acting|waiting|done" } }

// Delegation to sub-agent
{ "type": "agent_delegate", "payload": { "agent_id": "...", "context": {} } }

// Sub-agent result
{ "type": "agent_delegate_result", "payload": { "agent_id": "...", "result": {} } }
```

**Bidirectional Agent Loop Communication**:

Agent loop messages are **bidirectional**, inverting the typical client-to-server request model:

- **Server -> Client**: The server (AI agent) can send `tool_request` to the client, asking the client to execute a tool (e.g., file operations, API calls, user interactions).
- **Client -> Server**: The client sends `tool_result` back to the server with the execution outcome.

This inversion is necessary because in agentic workflows, the AI controls the flow and decides what actions to take. The client becomes the tool executor rather than the request initiator. Implementations must be prepared to handle incoming `tool_request` events at any time during an active agent loop session.

---

## 10. Examples

### 10.1 Basic Text Streaming (include_partial: false)

**Request:**
```json
{
  "type": "stream_request",
  "stream_id": "550e8400-e29b-41d4-a716-446655440001",
  "message_id": "550e8400-e29b-41d4-a716-446655440001",
  "sequence": 1,
  "timestamp": 1708234567890,
  "payload": {
    "model": {
      "id": "claude-3-opus-20240229",
      "name": "Claude 3 Opus",
      "api": "anthropic-messages",
      "provider": "anthropic",
      "base_url": "https://api.anthropic.com"
    },
    "context": {
      "system_prompt": "You are a helpful assistant.",
      "messages": [
        {
          "role": "user",
          "content": "What is 2+2?",
          "timestamp": 1708234567000
        }
      ]
    },
    "options": {
      "temperature": 0.7,
      "max_tokens": 1024
    }
  }
}
```

**Response Events:**
```json
{"type":"start","stream_id":"550e8400-e29b-41d4-a716-446655440001","message_id":"msg-001","sequence":2,"payload":{"model":"claude-3-opus-20240229","input_tokens":15}}

{"type":"text_start","stream_id":"550e8400-e29b-41d4-a716-446655440001","message_id":"msg-002","sequence":3,"payload":{"content_index":0}}

{"type":"text_delta","stream_id":"550e8400-e29b-41d4-a716-446655440001","message_id":"msg-003","sequence":4,"payload":{"content_index":0,"delta":"2 + 2"}}

{"type":"text_delta","stream_id":"550e8400-e29b-41d4-a716-446655440001","message_id":"msg-004","sequence":5,"payload":{"content_index":0,"delta":" equals "}}

{"type":"text_delta","stream_id":"550e8400-e29b-41d4-a716-446655440001","message_id":"msg-005","sequence":6,"payload":{"content_index":0,"delta":"4."}}

{"type":"text_end","stream_id":"550e8400-e29b-41d4-a716-446655440001","message_id":"msg-006","sequence":7,"payload":{"content_index":0}}

{"type":"done","stream_id":"550e8400-e29b-41d4-a716-446655440001","message_id":"msg-007","sequence":8,"payload":{"reason":"stop","message":{"role":"assistant","content":[{"type":"text","text":"2 + 2 equals 4."}],"usage":{"input":15,"output":12,"total_tokens":27},"stop_reason":"stop","model":"claude-3-opus-20240229","timestamp":1708234567920}}}
```

### 10.2 Tool Call Streaming (include_partial: true)

**Request:**
```json
{
  "type": "stream_request",
  "stream_id": "550e8400-e29b-41d4-a716-446655440002",
  "message_id": "550e8400-e29b-41d4-a716-446655440002",
  "sequence": 1,
  "payload": {
    "model": {
      "id": "gpt-4o",
      "name": "GPT-4o",
      "api": "openai-completions",
      "provider": "openai",
      "base_url": "https://api.openai.com"
    },
    "context": {
      "messages": [
        {
          "role": "user",
          "content": "What's the weather in Tokyo?",
          "timestamp": 1708234567000
        }
      ],
      "tools": [
        {
          "name": "get_weather",
          "description": "Get current weather for a location",
          "parameters_schema_json": "{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\"}},\"required\":[\"location\"]}"
        }
      ]
    },
    "options": {
      "tool_choice": "auto"
    },
    "include_partial": true
  }
}
```

**Response Events (with include_partial: true):**
```json
{"type":"start","stream_id":"550e8400-e29b-41d4-a716-446655440002","message_id":"msg-001","sequence":2,"payload":{"model":"gpt-4o","input_tokens":45}}

{"type":"toolcall_start","stream_id":"550e8400-e29b-41d4-a716-446655440002","message_id":"msg-002","sequence":3,"payload":{"content_index":0,"id":"call_abc123","name":"get_weather"}}

{"type":"toolcall_delta","stream_id":"550e8400-e29b-41d4-a716-446655440002","message_id":"msg-003","sequence":4,"include_partial":true,"payload":{"content_index":0,"delta":"{\"loca","partial":{"current_arguments_json":"{\"loca"}}}

{"type":"toolcall_delta","stream_id":"550e8400-e29b-41d4-a716-446655440002","message_id":"msg-004","sequence":5,"include_partial":true,"payload":{"content_index":0,"delta":"tion\":","partial":{"current_arguments_json":"{\"location\":"}}}

{"type":"toolcall_delta","stream_id":"550e8400-e29b-41d4-a716-446655440002","message_id":"msg-005","sequence":6,"include_partial":true,"payload":{"content_index":0,"delta":"\"Tokyo\"}","partial":{"current_arguments_json":"{\"location\":\"Tokyo\"}"}}}

{"type":"toolcall_end","stream_id":"550e8400-e29b-41d4-a716-446655440002","message_id":"msg-006","sequence":7,"payload":{"content_index":0,"tool_call":{"id":"call_abc123","name":"get_weather","arguments_json":"{\"location\":\"Tokyo\"}"}}}

{"type":"done","stream_id":"550e8400-e29b-41d4-a716-446655440002","message_id":"msg-007","sequence":8,"payload":{"reason":"tool_use","message":{"role":"assistant","content":[{"type":"tool_call","id":"call_abc123","name":"get_weather","arguments_json":"{\"location\":\"Tokyo\"}"}],"usage":{"input":45,"output":18,"total_tokens":63},"stop_reason":"tool_use","model":"gpt-4o","timestamp":1708234567920}}}
```

**Client-Side Reconstruction (without include_partial):**
```javascript
// Client maintains partial message state
let partial = {
  role: "assistant",
  content: [],
  usage: { input: 0, output: 0 },
  stopReason: null,
  model: "gpt-4o",
  timestamp: Date.now()
};

// On toolcall_start
partial.content[0] = { type: "toolCall", id: "call_abc123", name: "get_weather", arguments: {} };

// On toolcall_delta - accumulate JSON
partialJson += delta;
partial.content[0].arguments = parseStreamingJson(partialJson);

// On toolcall_end
delete partial.content[0].partialJson;

// On done
partial.stopReason = event.payload.reason;
partial.usage = event.payload.usage;
```

### 10.3 Abort Scenario

**Request:**
```json
{
  "type": "stream_request",
  "stream_id": "550e8400-e29b-41d4-a716-446655440003",
  "message_id": "550e8400-e29b-41d4-a716-446655440003",
  "sequence": 1,
  "payload": {
    "model": { "id": "claude-3-opus-20240229" },
    "context": { "messages": [...] }
  }
}
```

**Abort Request:**
```json
{
  "type": "abort_request",
  "stream_id": "550e8400-e29b-41d4-a716-446655440099",
  "message_id": "550e8400-e29b-41d4-a716-446655440099",
  "sequence": 5,
  "in_reply_to": "550e8400-e29b-41d4-a716-446655440003",
  "payload": {
    "target_stream_id": "550e8400-e29b-41d4-a716-446655440003",
    "reason": "User cancelled"
  }
}
```

**Response:**
```json
{"type":"ack","stream_id":"550e8400-e29b-41d4-a716-446655440099","message_id":"msg-ack-001","sequence":6,"in_reply_to":"550e8400-e29b-41d4-a716-446655440099","payload":{"acknowledged_id":"550e8400-e29b-41d4-a716-446655440099"}}

{"type":"error","stream_id":"550e8400-e29b-41d4-a716-446655440003","message_id":"msg-err-001","sequence":7,"payload":{"reason":"aborted","error_message":"User cancelled","usage":{"input":100,"output":50}}}
```

**Abort Invariants**:

The following guarantees apply to abort handling:

1. **Idempotency**: `abort_request` is idempotent. The server MUST acknowledge (via `ack`) even if the target stream has already completed (with `done` or `error`).

2. **Terminal Guarantee**: For any stream, either `error` or `done` is always the final event. No events shall be emitted for a stream after a terminal event.

3. **Race Handling**: Due to network and processing latency, events with `sequence < abort_sequence` may still arrive after the client sends an abort. Clients SHOULD discard any events received after an abort that do not have the terminal `error` or `done` event. The server ensures the final event for an aborted stream is an `error` with `reason: "aborted"`.

### 10.4 WebSocket Full Session

```
Client                                                    Server
  |                                                         |
  |--- WebSocket Handshake (Sec-WebSocket-Protocol: makai.v1)
  |<-- 101 Switching Protocols ----------------------------|
  |                                                         |
  |--- Text Frame ----------------------------------------->|
  |    {"type":"stream_request","stream_id":"A",...}        |
  |                                                         |
  |<-- Text Frame ------------------------------------------|
  |    {"type":"ack","in_reply_to":"msg-1",...}             |
  |                                                         |
  |<-- Text Frame ------------------------------------------|
  |    {"type":"start","stream_id":"A",...}                 |
  |                                                         |
  |<-- Text Frame ------------------------------------------|
  |    {"type":"text_delta","stream_id":"A",...}            |
  |                                                         |
  |--- Ping Frame ----------------------------------------->| (WS-level)
  |<-- Pong Frame ------------------------------------------|
  |                                                         |
  |<-- Text Frame ------------------------------------------|
  |    {"type":"done","stream_id":"A",...}                  |
  |                                                         |
  |--- Text Frame ----------------------------------------->|
  |    {"type":"goodbye","payload":{}}                      |
  |                                                         |
  |<-- Text Frame ------------------------------------------|
  |    {"type":"goodbye","payload":{}}                      |
  |                                                         |
  |--- Close Frame ---------------------------------------->|
  |<-- Close Frame -----------------------------------------|
  |                                                         |
```

### 10.5 Stdio Transport Session

**Input (stdin):**
```
MAKAI/1.0.0
{"type":"stream_request","stream_id":"stream-001","message_id":"msg-001","sequence":1,"payload":{"model":{...},"context":{...}}}
```

**Output (stdout):**
```
MAKAI/1.0.0
{"type":"ack","stream_id":"stream-001","message_id":"msg-ack-001","sequence":2,"in_reply_to":"msg-001","payload":{"acknowledged_id":"msg-001"}}
{"type":"start","stream_id":"stream-001","message_id":"msg-002","sequence":3,"payload":{"model":"...","input_tokens":15}}
{"type":"text_delta","stream_id":"stream-001","message_id":"msg-003","sequence":4,"payload":{"content_index":0,"delta":"Hello"}}
{"type":"text_delta","stream_id":"stream-001","message_id":"msg-004","sequence":5,"payload":{"content_index":0,"delta":" world"}}
{"type":"text_end","stream_id":"stream-001","message_id":"msg-005","sequence":6,"payload":{"content_index":0}}
{"type":"done","stream_id":"stream-001","message_id":"msg-006","sequence":7,"payload":{"reason":"stop","message":{...}}}
```

---

## 11. Security

### 11.1 API Key Handling

API keys must NEVER be transmitted in protocol messages. They are passed exclusively via transport-level mechanisms:

| Transport | API Key Method |
|-----------|---------------|
| WebSocket | `Authorization: Bearer <key>` header in handshake |
| HTTP | `Authorization: Bearer <key>` header |
| gRPC | `authorization` metadata |
| stdio | Environment variable or configuration file |

**Implementation Note**: The `StreamOptions.api_key` field has been removed from the protocol. All implementations must use transport headers.

### 11.2 Log Redaction

Implementations should redact sensitive information in logs:

1. **API Keys**: Redact any field named `api_key`, `authorization`, or containing `secret`, `token`, or `key`
2. **Content**: Optionally redact message content in debug logs
3. **PII**: Consider redacting personally identifiable information

Example log redaction:
```
// Before: Authorization: Bearer sk-ant-api03-xxxxx...
// After:  Authorization: Bearer [REDACTED]
```

### 11.3 Transport Security Requirements

| Transport | Minimum Security |
|-----------|-----------------|
| WebSocket | TLS (wss://) required in production |
| HTTP | TLS (https://) required in production |
| gRPC | TLS required in production |
| stdio | Local process isolation; no network exposure |

### 11.4 Authentication

The protocol does not define authentication mechanisms. Authentication is handled at the transport layer:

1. **Bearer Token**: Standard `Authorization: Bearer <token>` header
2. **mTLS**: Mutual TLS for server and client authentication
3. **API Gateway**: Authentication handled by intermediary

---

## 12. Memory Ownership

### 12.1 Ownership Model

All events in the stream follow a clear ownership model to ensure safe async handling without use-after-free:

1. **Events Own Their Strings**: Every event payload owns any string data it contains. Strings are not borrowed from external sources.

2. **Provider String Duplication**: When providers create events, they MUST duplicate any strings that come from external sources (e.g., provider API responses, user input). This ensures events remain valid even after the original source is deallocated.

3. **Protocol Layer Cleanup**: The protocol layer handles cleanup via `event_stream.deinit()`. This releases all resources owned by events in the stream.

### 12.2 Lifecycle Guarantees

| Resource | Owner | Lifetime |
|----------|-------|----------|
| Event payload strings | Event | Until `deinit()` called on event/stream |
| Content block strings | Content block | Same as containing event |
| Tool call arguments JSON | Tool call event | Same as containing event |
| Error messages | Error event | Same as containing event |

### 12.3 Implementation Requirements

- **Providers**: Must use `dupe()` or equivalent when creating events from borrowed strings
- **Protocol Layer**: Must provide `deinit()` method to release all event resources
- **Consumers**: Must not hold references to event data after `deinit()` is called

---

## Appendix C: Current Limitations (v1.0)

### Advanced Control Messages

The following control messages are documented for forward compatibility but **not yet implemented** in v1.0:

- **`goodbye`**: Graceful connection close *(planned for v1.1)*
- **`sync_request`**: Request full state resync *(planned for v1.1)*
- **`sync`**: Full partial state resync *(planned for v1.1)*
- **`pong.payload.ping_id`**: The `pong` response is currently implemented as a simple `void` type without echo of `ping_id`. The schema documents `ping_id` for forward compatibility, but v1.0 implementations should not expect this field.

### Single-Stream Mode

The current v1.0 implementation supports **single active stream per client**. While the protocol specification describes full multiplexing support (Section 7.4), the implementation currently tracks only one stream at a time via `current_stream_id` in the client.

**Implications:**
- Clients should wait for a stream to complete (via `done` or `error`) before initiating a new stream
- Concurrent `stream_request` messages may result in undefined behavior
- Stream IDs are tracked but only one is considered "active" for event processing

### Event Forwarding

The server implementation creates streams and returns acknowledgment (ACK) but **does not yet forward stream events as protocol envelopes**. Event forwarding requires integration with the async runtime infrastructure to:

1. Poll the provider's event stream
2. Wrap events in protocol envelopes with correct sequence numbers
3. Transmit envelopes via the transport layer

This is planned for v2.0.

### Sequence Validation

**Sequence validation not enforced**: While sequence numbers are tracked for each stream, the server does not reject out-of-order or duplicate messages. This is planned for v2.0 when implementing multiplexing.

### Planned for v2.0

- Full multiplexing with concurrent stream support
- Automatic event forwarding from providers to clients
- Stream state synchronization via `sync_request`/`sync` messages
- Backpressure management across multiple streams

---

## Appendix A: Type Mappings to Zig Implementation

| Protocol Type | Zig Type (ai_types.zig) |
|--------------|------------------------|
| ContentBlock | ai_types.AssistantContent |
| Usage | ai_types.Usage |
| StopReason | ai_types.StopReason |
| MessageEvent | ai_types.AssistantMessageEvent |
| AssistantMessage | ai_types.AssistantMessage |

---

## Appendix B: Transport Implementation Reference

| Transport | Zig Module | Key Types/Functions |
|-----------|-----------|---------------------|
| Core | `transport.zig` | `ByteChunk`, `ByteStream`, `AsyncSender`, `AsyncReceiver` |
| Stdio | `transports/stdio.zig` | `StdioSender.sender()`, `StdioReceiver.receiver()` |
| SSE | `transports/sse.zig` | `SseSender.sender()`, `SseReceiver.receiver()` |
| Bridge | `transport.zig` | `forwardStream()`, `receiveStream()`, `spawnReceiver()` |
