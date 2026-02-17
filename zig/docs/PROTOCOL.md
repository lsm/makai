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

---

## 1. Overview

### 1.1 Purpose

The Makai Wire Protocol provides a standardized communication format for AI streaming interactions between clients, proxies, and AI providers. It is designed to:

- Enable bidirectional streaming of AI requests and responses
- Support multiple transport layers (stdio, WebSocket, gRPC, SSE, etc.)
- Optimize bandwidth for proxy scenarios by eliminating redundant partial message data
- Handle message fragmentation and reassembly
- Support cancellation and abort operations
- Be extensible for future agent loop events

### 1.2 Protocol Version

```
MAKAI/1.0.0
```

Version negotiation is performed during connection establishment via the `protocol_version` field in the initial handshake.

### 1.3 Terminology

- **Client**: The entity initiating an AI request
- **Server**: The entity processing requests (may be a proxy or direct provider)
- **Stream**: A logical bidirectional channel for request/response pairs
- **Event**: An atomic message within a stream (e.g., text delta, tool call)
- **Partial Message**: The cumulative state of an assistant message being built
- **Proxy Mode**: Bandwidth-optimized mode where partial messages are reconstructed client-side

---

## 2. Design Principles

### 2.1 Transport Agnostic

The protocol defines message semantics independently of the transport. Transport-specific adaptations are defined in Section 5.

### 2.2 Bandwidth Optimized

Two encoding modes are supported:

1. **Full Mode**: Events include the complete `partial` message state (for local communication)
2. **Proxy Mode**: Events omit `partial` messages; clients reconstruct state locally (for remote/proxy communication)

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
  |-- complete_request    - Request non-streaming completion
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
  |-- ping                - Keepalive

Control
  |-- ack                 - Acknowledgment
  |-- nack                - Negative acknowledgment
  |-- ping                - Transport keepalive
  |-- pong                - Keepalive response
  |-- goodbye             - Graceful connection close

Response
  |-- result              - Final assistant message (complete mode)
  |-- stream_error        - Stream-level error
```

---

## 4. Wire Format Specification

### 4.1 Envelope Structure

All messages are wrapped in an envelope:

```json
{
  "type": "<message_type>",
  "request_id": "<uuid>",
  "timestamp": <unix_ms>,
  "payload": { ... }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | Yes | Message type discriminator |
| `request_id` | string (UUID) | Yes | Correlation ID for request/response pairing |
| `timestamp` | integer | No | Unix timestamp in milliseconds |
| `payload` | object | Yes | Type-specific message content |
| `encoding` | string | No | "full" or "proxy" (default: "full") |
| `sequence` | integer | No | Sequence number for ordering (when fragmentation is used) |
| `fragment` | object | No | Fragment metadata when message is split |

### 4.2 Fragmentation

Large messages may be fragmented. When `fragment` is present:

```json
{
  "type": "...",
  "request_id": "...",
  "fragment": {
    "index": 0,
    "total": 3,
    "id": "<fragment-uuid>"
  },
  "payload": { ... partial content ... }
}
```

Fragments are reassembled by concatenating payloads in order. The `fragment.id` groups fragments belonging to the same logical message.

### 4.3 Encoding Modes

#### Full Mode (Default)

Events include the complete `partial` message:

```json
{
  "type": "text_delta",
  "request_id": "req-123",
  "payload": {
    "content_index": 0,
    "delta": "Hello",
    "partial": {
      "role": "assistant",
      "content": [{ "type": "text", "text": "Hello" }],
      "usage": { "input": 100, "output": 5 },
      "stop_reason": null,
      "model": "claude-3-opus",
      "timestamp": 1234567890
    }
  }
}
```

#### Proxy Mode (Bandwidth Optimized)

Events omit `partial`; client reconstructs:

```json
{
  "type": "text_delta",
  "request_id": "req-123",
  "encoding": "proxy",
  "payload": {
    "content_index": 0,
    "delta": "Hello"
  }
}
```

---

## 5. Transport Mappings

### 5.1 Stdio Transport

**Framing**: Line-delimited JSON (LDJSON)

Each message is a single line ending with `\n`:

```
{"type":"stream_request","request_id":"req-1","payload":{...}}\n
{"type":"start","request_id":"req-1","payload":{...}}\n
{"type":"text_delta","request_id":"req-1","payload":{...}}\n
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
data: {"type":"start","request_id":"req-1","payload":{...}}

event: message
data: {"type":"text_delta","request_id":"req-1","payload":{...}}

```

**Custom Event Types**:
- `message`: Regular event
- `control`: Control message
- `error`: Error message

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
Client -> Server: {"type":"stream_request", ...}
Server -> Client: {"type":"start", ...} (multiple frames)
```

**Ping/Pong**:
- Use native WebSocket ping/pong frames for keepalive
- Protocol-level `ping`/`pong` messages are also supported for application-level heartbeats

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
  string request_id = 2;
  int64 timestamp = 3;
  bytes payload = 4;  // JSON-encoded
  string encoding = 5;

  message Fragment {
    uint32 index = 1;
    uint32 total = 2;
    string id = 3;
  }
  Fragment fragment = 6;
}
```

**Implementation Notes**:
- Payload is JSON-encoded for consistency with other transports
- Binary protobuf payload encoding may be added as an extension
- Use gRPC metadata for authentication and protocol version

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
X-Makai-Encoding: proxy
```

---

## 6. JSON Schema Definitions

### 6.1 Common Types

#### ContentBlock (Full Mode)

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
        "type": { "const": "tool_use" },
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

### 6.2 Request Messages

#### StreamRequest

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "stream_request" },
    "request_id": { "type": "string", "format": "uuid" },
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
  "required": ["type", "request_id", "payload"]
}
```

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
    "api_key": { "type": "string" },
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

#### AbortRequest

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "abort_request" },
    "request_id": { "type": "string", "format": "uuid" },
    "payload": {
      "type": "object",
      "properties": {
        "target_request_id": { "type": "string", "format": "uuid" },
        "reason": { "type": "string" }
      },
      "required": ["target_request_id"]
    }
  },
  "required": ["type", "request_id", "payload"]
}
```

### 6.3 Event Messages (Full Mode)

#### StartEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "start" },
    "request_id": { "type": "string" },
    "payload": {
      "type": "object",
      "properties": {
        "model": { "type": "string" },
        "input_tokens": { "type": "integer" },
        "partial": { "$ref": "#/$defs/AssistantMessage" }
      },
      "required": ["model", "partial"]
    }
  }
}
```

#### TextDeltaEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "text_delta" },
    "request_id": { "type": "string" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 },
        "delta": { "type": "string" },
        "partial": { "$ref": "#/$defs/AssistantMessage" }
      },
      "required": ["content_index", "delta", "partial"]
    }
  }
}
```

#### ThinkingDeltaEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "thinking_delta" },
    "request_id": { "type": "string" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 },
        "delta": { "type": "string" },
        "partial": { "$ref": "#/$defs/AssistantMessage" }
      },
      "required": ["content_index", "delta", "partial"]
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
    "request_id": { "type": "string" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 },
        "id": { "type": "string" },
        "name": { "type": "string" },
        "partial": { "$ref": "#/$defs/AssistantMessage" }
      },
      "required": ["content_index", "id", "name", "partial"]
    }
  }
}
```

#### ToolCallDeltaEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "toolcall_delta" },
    "request_id": { "type": "string" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 },
        "delta": { "type": "string" },
        "partial": { "$ref": "#/$defs/AssistantMessage" }
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
    "request_id": { "type": "string" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer", "minimum": 0 },
        "tool_call": { "$ref": "#/$defs/ToolCall" },
        "partial": { "$ref": "#/$defs/AssistantMessage" }
      },
      "required": ["content_index", "tool_call", "partial"]
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
    "request_id": { "type": "string" },
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
    "request_id": { "type": "string" },
    "payload": {
      "type": "object",
      "properties": {
        "reason": { "enum": ["error", "aborted"] },
        "error_message": { "type": "string" },
        "error_code": { "type": "string" },
        "usage": { "$ref": "#/$defs/Usage" },
        "partial": { "$ref": "#/$defs/AssistantMessage" }
      },
      "required": ["reason"]
    }
  }
}
```

### 6.4 Proxy Mode Events (Bandwidth Optimized)

In proxy mode, events omit the `partial` field. The client reconstructs state locally.

#### ProxyStartEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "start" },
    "request_id": { "type": "string" },
    "encoding": { "const": "proxy" },
    "payload": {}
  }
}
```

#### ProxyTextDeltaEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "text_delta" },
    "request_id": { "type": "string" },
    "encoding": { "const": "proxy" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer" },
        "delta": { "type": "string" }
      },
      "required": ["content_index", "delta"]
    }
  }
}
```

#### ProxyTextEndEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "text_end" },
    "request_id": { "type": "string" },
    "encoding": { "const": "proxy" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer" },
        "content_signature": { "type": "string" }
      },
      "required": ["content_index"]
    }
  }
}
```

#### ProxyToolCallStartEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "toolcall_start" },
    "request_id": { "type": "string" },
    "encoding": { "const": "proxy" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer" },
        "id": { "type": "string" },
        "name": { "type": "string" }
      },
      "required": ["content_index", "id", "name"]
    }
  }
}
```

#### ProxyToolCallEndEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "toolcall_end" },
    "request_id": { "type": "string" },
    "encoding": { "const": "proxy" },
    "payload": {
      "type": "object",
      "properties": {
        "content_index": { "type": "integer" }
      },
      "required": ["content_index"]
    }
  }
}
```

#### ProxyDoneEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "done" },
    "request_id": { "type": "string" },
    "encoding": { "const": "proxy" },
    "payload": {
      "type": "object",
      "properties": {
        "reason": { "enum": ["stop", "length", "tool_use"] },
        "usage": { "$ref": "#/$defs/Usage" }
      },
      "required": ["reason", "usage"]
    }
  }
}
```

#### ProxyErrorEvent

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "error" },
    "request_id": { "type": "string" },
    "encoding": { "const": "proxy" },
    "payload": {
      "type": "object",
      "properties": {
        "reason": { "enum": ["aborted", "error"] },
        "error_message": { "type": "string" },
        "usage": { "$ref": "#/$defs/Usage" }
      },
      "required": ["reason", "usage"]
    }
  }
}
```

### 6.5 Control Messages

#### AckControl

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "ack" },
    "request_id": { "type": "string" },
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
    "request_id": { "type": "string" },
    "payload": {
      "type": "object",
      "properties": {
        "rejected_id": { "type": "string" },
        "reason": { "type": "string" },
        "error_code": { "type": "string" }
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
    "request_id": { "type": "string" },
    "payload": {}
  }
}
```

#### PongControl

```json
{
  "type": "object",
  "properties": {
    "type": { "const": "pong" },
    "request_id": { "type": "string" },
    "payload": {
      "type": "object",
      "properties": {
        "ping_id": { "type": "string" }
      },
      "required": ["ping_id"]
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
    "request_id": { "type": "string" },
    "payload": {
      "type": "object",
      "properties": {
        "reason": { "type": "string" }
      }
    }
  }
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

### 7.2 Version Negotiation

The client includes `protocol_version` in the first message:

```json
{
  "type": "stream_request",
  "request_id": "req-001",
  "protocol_version": "1.0.0",
  "payload": { ... }
}
```

If the server does not support the version, it responds with:

```json
{
  "type": "nack",
  "request_id": "resp-001",
  "payload": {
    "rejected_id": "req-001",
    "reason": "Unsupported protocol version",
    "error_code": "VERSION_MISMATCH",
    "supported_versions": ["0.9.0"]
  }
}
```

### 7.3 Streaming Flow

```
Client                                            Server
  |                                                 |
  |---- StreamRequest (request_id: A) ------------>|
  |                                                 |
  |<--- StartEvent (request_id: A) ----------------|
  |<--- TextStartEvent (request_id: A) ------------|
  |<--- TextDeltaEvent (request_id: A) ------------|
  |<--- TextDeltaEvent (request_id: A) ------------|
  |---- AbortRequest (target: A) ----------------->|  <-- Optional abort
  |<--- ErrorEvent (reason: aborted) --------------|
  |                                                 |
```

### 7.4 Concurrent Streams

Multiple streams may be multiplexed using distinct `request_id` values:

```
Client                                            Server
  |                                                 |
  |---- StreamRequest (request_id: A) ------------>|
  |---- StreamRequest (request_id: B) ------------>|
  |                                                 |
  |<--- TextDeltaEvent (request_id: A) ------------|
  |<--- TextDeltaEvent (request_id: B) ------------|  <-- Interleaved
  |<--- TextDeltaEvent (request_id: A) ------------|
  |<--- DoneEvent (request_id: A) -----------------|
  |<--- TextDeltaEvent (request_id: B) ------------|
  |<--- DoneEvent (request_id: B) -----------------|
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
| `INVALID_REQUEST_ID` | Protocol | Request ID format invalid |
| `STREAM_NOT_FOUND` | Stream | Target stream does not exist |
| `STREAM_ALREADY_EXISTS` | Stream | Duplicate request ID |
| `PROVIDER_ERROR` | Provider | Upstream provider error |
| `RATE_LIMITED` | Provider | Rate limit exceeded |
| `AUTHENTICATION_FAILED` | Auth | Invalid credentials |
| `AUTHORIZATION_FAILED` | Auth | Insufficient permissions |
| `CONTEXT_TOO_LARGE` | Context | Context exceeds limits |
| `MODEL_NOT_FOUND` | Model | Requested model unavailable |
| `INTERNAL_ERROR` | Server | Internal server error |

### 8.2 Error Event Payload

```json
{
  "type": "error",
  "request_id": "req-123",
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

### 8.3 Recovery Strategies

1. **Transient Errors**: Client should retry with exponential backoff
2. **Permanent Errors**: Client should not retry; fix the request
3. **Stream Errors**: Stream is terminated; check `reason` field

---

## 9. Extension Mechanisms

### 9.1 Extension Fields

Messages may include additional fields with `x_` prefix:

```json
{
  "type": "text_delta",
  "request_id": "req-123",
  "payload": {
    "content_index": 0,
    "delta": "Hello",
    "partial": { ... },
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

---

## 10. Examples

### 10.1 Basic Text Streaming (Full Mode)

**Request:**
```json
{
  "type": "stream_request",
  "request_id": "550e8400-e29b-41d4-a716-446655440001",
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
          "user": {
            "content": { "text": "What is 2+2?" },
            "timestamp": 1708234567000
          }
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
{"type":"start","request_id":"550e8400-e29b-41d4-a716-446655440001","payload":{"model":"claude-3-opus-20240229","input_tokens":15,"partial":{"role":"assistant","content":[],"usage":{"input":15,"output":0},"stop_reason":null,"model":"claude-3-opus-20240229","timestamp":1708234567895}}}

{"type":"text_start","request_id":"550e8400-e29b-41d4-a716-446655440001","payload":{"content_index":0,"partial":{"role":"assistant","content":[{"type":"text","text":""}],"usage":{"input":15,"output":0},"stop_reason":null,"model":"claude-3-opus-20240229","timestamp":1708234567895}}}

{"type":"text_delta","request_id":"550e8400-e29b-41d4-a716-446655440001","payload":{"content_index":0,"delta":"2 + 2","partial":{"role":"assistant","content":[{"type":"text","text":"2 + 2"}],"usage":{"input":15,"output":3},"stop_reason":null,"model":"claude-3-opus-20240229","timestamp":1708234567900}}}

{"type":"text_delta","request_id":"550e8400-e29b-41d4-a716-446655440001","payload":{"content_index":0,"delta":" equals ","partial":{"role":"assistant","content":[{"type":"text","text":"2 + 2 equals "}],"usage":{"input":15,"output":10},"stop_reason":null,"model":"claude-3-opus-20240229","timestamp":1708234567905}}}

{"type":"text_delta","request_id":"550e8400-e29b-41d4-a716-446655440001","payload":{"content_index":0,"delta":"4.","partial":{"role":"assistant","content":[{"type":"text","text":"2 + 2 equals 4."}],"usage":{"input":15,"output":12},"stop_reason":null,"model":"claude-3-opus-20240229","timestamp":1708234567910}}}

{"type":"text_end","request_id":"550e8400-e29b-41d4-a716-446655440001","payload":{"content_index":0,"partial":{"role":"assistant","content":[{"type":"text","text":"2 + 2 equals 4."}],"usage":{"input":15,"output":12},"stop_reason":null,"model":"claude-3-opus-20240229","timestamp":1708234567915}}}

{"type":"done","request_id":"550e8400-e29b-41d4-a716-446655440001","payload":{"reason":"stop","message":{"role":"assistant","content":[{"type":"text","text":"2 + 2 equals 4."}],"usage":{"input":15,"output":12,"total_tokens":27},"stop_reason":"stop","model":"claude-3-opus-20240229","timestamp":1708234567920}}}
```

### 10.2 Tool Call Streaming (Proxy Mode)

**Request:**
```json
{
  "type": "stream_request",
  "request_id": "550e8400-e29b-41d4-a716-446655440002",
  "encoding": "proxy",
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
          "user": {
            "content": { "text": "What's the weather in Tokyo?" },
            "timestamp": 1708234567000
          }
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
    }
  }
}
```

**Response Events (Proxy Mode - No Partial):**
```json
{"type":"start","request_id":"550e8400-e29b-41d4-a716-446655440002","encoding":"proxy","payload":{}}

{"type":"toolcall_start","request_id":"550e8400-e29b-41d4-a716-446655440002","encoding":"proxy","payload":{"content_index":0,"id":"call_abc123","name":"get_weather"}}

{"type":"toolcall_delta","request_id":"550e8400-e29b-41d4-a716-446655440002","encoding":"proxy","payload":{"content_index":0,"delta":"{\"loca"}}

{"type":"toolcall_delta","request_id":"550e8400-e29b-41d4-a716-446655440002","encoding":"proxy","payload":{"content_index":0,"delta":"tion\":"}}

{"type":"toolcall_delta","request_id":"550e8400-e29b-41d4-a716-446655440002","encoding":"proxy","payload":{"content_index":0,"delta":"\"Tokyo\"}"}

{"type":"toolcall_end","request_id":"550e8400-e29b-41d4-a716-446655440002","encoding":"proxy","payload":{"content_index":0}}

{"type":"done","request_id":"550e8400-e29b-41d4-a716-446655440002","encoding":"proxy","payload":{"reason":"tool_use","usage":{"input":45,"output":18,"total_tokens":63}}}
```

**Client-Side Reconstruction:**
```javascript
// Client maintains partial message state
let partial = {
  role: "assistant",
  content: [],
  usage: { input: 0, output: 0 },
  stopReason: "stop",
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
  "request_id": "550e8400-e29b-41d4-a716-446655440003",
  "payload": {
    "model": { "id": "claude-3-opus-20240229", ... },
    "context": { "messages": [...] }
  }
}
```

**Abort Request:**
```json
{
  "type": "abort_request",
  "request_id": "550e8400-e29b-41d4-a716-446655440099",
  "payload": {
    "target_request_id": "550e8400-e29b-41d4-a716-446655440003",
    "reason": "User cancelled"
  }
}
```

**Response:**
```json
{"type":"ack","request_id":"550e8400-e29b-41d4-a716-446655440099","payload":{"acknowledged_id":"550e8400-e29b-41d4-a716-446655440099"}}

{"type":"error","request_id":"550e8400-e29b-41d4-a716-446655440003","payload":{"reason":"aborted","error_message":"User cancelled","usage":{"input":100,"output":50}}}
```

### 10.4 WebSocket Full Session

```
Client                                                    Server
  |                                                         |
  |--- WebSocket Handshake (Sec-WebSocket-Protocol: makai.v1)
  |<-- 101 Switching Protocols ----------------------------|
  |                                                         |
  |--- Text Frame ----------------------------------------->|
  |    {"type":"stream_request","request_id":"A",...}       |
  |                                                         |
  |<-- Text Frame ------------------------------------------|
  |    {"type":"ack","payload":{"acknowledged_id":"A"}}     |
  |                                                         |
  |<-- Text Frame ------------------------------------------|
  |    {"type":"start","request_id":"A",...}                |
  |                                                         |
  |<-- Text Frame ------------------------------------------|
  |    {"type":"text_delta","request_id":"A",...}           |
  |                                                         |
  |--- Ping Frame ----------------------------------------->| (WS-level)
  |<-- Pong Frame ------------------------------------------|
  |                                                         |
  |<-- Text Frame ------------------------------------------|
  |    {"type":"done","request_id":"A",...}                 |
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
{"type":"stream_request","request_id":"req-001","payload":{"model":{...},"context":{...}}}
```

**Output (stdout):**
```
{"type":"ack","request_id":"ack-001","payload":{"acknowledged_id":"req-001"}}
{"type":"start","request_id":"req-001","payload":{"model":"...","partial":{...}}}
{"type":"text_delta","request_id":"req-001","payload":{"content_index":0,"delta":"Hello","partial":{...}}}
{"type":"text_delta","request_id":"req-001","payload":{"content_index":0,"delta":" world","partial":{...}}}
{"type":"text_end","request_id":"req-001","payload":{"content_index":0,"partial":{...}}}
{"type":"done","request_id":"req-001","payload":{"reason":"stop","message":{...}}}
```

---

## Appendix A: Type Mappings to Zig Implementation

| Protocol Type | Zig Type (types.zig) | Zig Type (ai_types.zig) |
|--------------|---------------------|------------------------|
| ContentBlock | types.ContentBlock | ai_types.AssistantContent |
| Usage | types.Usage | ai_types.Usage |
| StopReason | types.StopReason | ai_types.StopReason |
| MessageEvent | types.MessageEvent | ai_types.AssistantMessageEvent |
| AssistantMessage | types.AssistantMessage | ai_types.AssistantMessage |

---

## Appendix B: Transport Implementation Reference

| Transport | Zig Module | Key Functions |
|-----------|-----------|---------------|
| Stdio | `transports/stdio.zig` | `StdioSender.sender()`, `StdioReceiver.receiver()` |
| SSE | `transports/sse.zig` | `SseSender.sender()`, `SseReceiver.receiver()` |
| Core | `transport.zig` | `forwardStream()`, `receiveStream()`, `serializeEvent()`, `deserialize()` |
