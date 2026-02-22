# Makai V1 SDK + Protocol Spec

Status: draft for implementation review

## 1. Scope

This spec defines:
- End-user OAuth and model-selection flow.
- TypeScript SDK public interfaces for auth, model discovery, agent execution, and provider-direct execution.
- Provider protocol schema additions for model discovery.
- Agent protocol schema additions for model-discovery passthrough.

This spec does not define transport framing changes.

## 2. End-User Flow (Normative)

1. User creates a single client and connects to `makai`.
2. User calls `client.auth.listProviders()`.
3. User calls `client.auth.login(providerId)` if needed.
4. User calls `client.models.list()`.
5. User uses returned `model_ref` with either:
- `client.agent.run(...)` (default path)
- `client.provider.complete(...)` or `client.provider.stream(...)` (advanced path)

Normative rule: end users do not manage provider-specific headers, token files, or response parsing.

## 3. TypeScript SDK Public API (Normative)

```ts
export type ProviderId = string;
export type ApiId =
  | "anthropic-messages"
  | "openai-completions"
  | "openai-responses"
  | "azure-openai-responses"
  | "google-generative-ai"
  | "google-gemini-cli"
  | "ollama"
  | string;

export type AuthStatus = "authenticated" | "login_required" | "expired" | "unknown";

export type ModelLifecycle = "stable" | "preview" | "deprecated";

export type ModelCapability =
  | "chat"
  | "streaming"
  | "tools"
  | "vision"
  | "reasoning"
  | "prompt_cache"
  | "audio_input"
  | "audio_output";

export interface ProviderAuthInfo {
  id: ProviderId;
  name: string;
  auth_status: AuthStatus;
  last_error?: string;
}

export interface ModelDescriptor {
  model_ref: string; // stable ref: "<provider>:<model_id>"
  model_id: string;
  display_name: string;
  provider_id: ProviderId;
  api: ApiId;
  base_url?: string;
  auth_status: AuthStatus;
  lifecycle: ModelLifecycle;
  capabilities: ModelCapability[];
  context_window?: number;
  max_output_tokens?: number;
  reasoning_default?: "off" | "minimal" | "low" | "medium" | "high" | "xhigh";
  metadata?: Record<string, string>;
}

export interface ListModelsRequest {
  provider_id?: ProviderId;
  api?: ApiId;
  include_deprecated?: boolean;
  include_login_required?: boolean;
}

export interface ListModelsResponse {
  models: ModelDescriptor[];
  fetched_at_ms: number;
}

export interface ChatMessage {
  role: "system" | "developer" | "user" | "assistant" | "tool";
  content: string;
  name?: string;
  tool_call_id?: string;
}

export interface ToolDefinition {
  name: string;
  description: string;
  parameters_schema_json: string;
}

export interface RunOptions {
  temperature?: number;
  max_tokens?: number;
  reasoning_effort?: "minimal" | "low" | "medium" | "high" | "xhigh";
  session_id?: string;
  metadata?: Record<string, string>;
}

export interface AgentRunRequest {
  model_ref: string;
  messages: ChatMessage[];
  tools?: ToolDefinition[];
  options?: RunOptions;
}

export interface AgentRunResponse {
  message: {
    role: "assistant";
    content: string;
  };
  usage?: {
    input: number;
    output: number;
    cache_read?: number;
    cache_write?: number;
  };
  provider_id: ProviderId;
  api: ApiId;
  model_id: string;
}

export type AgentStreamEvent =
  | { type: "message_start" }
  | { type: "text_delta"; delta: string }
  | { type: "tool_call"; name: string; arguments_json: string; id: string }
  | { type: "message_end" }
  | { type: "error"; message: string; code?: string };

export interface ProviderCompleteRequest {
  model_ref: string;
  messages: ChatMessage[];
  options?: RunOptions;
}

export interface ProviderCompleteResponse {
  message: {
    role: "assistant";
    content: string;
  };
  usage?: {
    input: number;
    output: number;
    cache_read?: number;
    cache_write?: number;
  };
  provider_id: ProviderId;
  api: ApiId;
  model_id: string;
}

export interface MakaiAuthApi {
  listProviders(): Promise<ProviderAuthInfo[]>;
  login(providerId: ProviderId, handlers?: {
    onEvent?: (event: unknown) => void;
    onPrompt?: (prompt: { message: string; allow_empty: boolean }) => Promise<string> | string;
  }): Promise<void>;
}

export interface MakaiModelsApi {
  list(request?: ListModelsRequest): Promise<ListModelsResponse>;
}

export interface MakaiAgentApi {
  run(request: AgentRunRequest): Promise<AgentRunResponse>;
  stream(request: AgentRunRequest): AsyncIterable<AgentStreamEvent>;
}

export interface MakaiProviderApi {
  complete(request: ProviderCompleteRequest): Promise<ProviderCompleteResponse>;
  stream(request: ProviderCompleteRequest): AsyncIterable<AgentStreamEvent>;
}

export interface MakaiClient {
  auth: MakaiAuthApi;
  models: MakaiModelsApi;
  agent: MakaiAgentApi;
  provider: MakaiProviderApi;
  close(): Promise<void>;
}
```

## 4. Provider Protocol Changes (Normative)

File target: `zig/src/protocol/provider/types.zig`

Add payload variants:
- `models_request: ModelsRequest`
- `models_response: ModelsResponse`

Add request/response structs:

```zig
pub const ModelsRequest = struct {
    provider_id: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    api: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    include_deprecated: bool = false,
    include_login_required: bool = true,

    pub fn getProviderId(self: *const ModelsRequest) ?[]const u8 { ... }
    pub fn getApi(self: *const ModelsRequest) ?[]const u8 { ... }
    pub fn deinit(self: *ModelsRequest, allocator: std.mem.Allocator) void { ... }
};

pub const ModelDescriptor = struct {
    model_ref: OwnedSlice(u8),
    model_id: OwnedSlice(u8),
    display_name: OwnedSlice(u8),
    provider_id: OwnedSlice(u8),
    api: OwnedSlice(u8),
    base_url: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    auth_status: enum { authenticated, login_required, expired, unknown },
    lifecycle: enum { stable, preview, deprecated },
    capabilities: OwnedSlice(OwnedSlice(u8)),
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
};

pub const ModelsResponse = struct {
    models: OwnedSlice(ModelDescriptor),
    fetched_at_ms: i64,
    pub fn deinit(self: *ModelsResponse, allocator: std.mem.Allocator) void { ... }
};
```

Envelope type values:
- `"models_request"`
- `"models_response"`

Server behavior:
1. On `models_request`, return `ack` then `models_response`, or `nack` on failure.
2. For unsupported runtime, return `nack` with `error_code = not_implemented`.

Client behavior:
1. Treat `not_implemented` as capability absence.
2. Preserve existing behavior for `stream_request` and `complete_request`.

## 5. Agent Protocol Changes (Normative)

File target: `zig/src/protocol/agent/types.zig`

Add payload variants:
- `models_request: struct { provider_id: OwnedSlice(u8), api: OwnedSlice(u8), include_deprecated: bool, include_login_required: bool }`
- `models_response: struct { models_json: []const u8, fetched_at_ms: i64 }`

Rationale: agent protocol carries passthrough model discovery for clients connected only to agent endpoint.

Normative rule: provider protocol remains canonical source; agent protocol passthrough must return the same model set and shape.

## 6. JSON Envelope Examples (Normative)

Provider models request:

```json
{
  "type": "models_request",
  "stream_id": "4acb66d3-f669-454e-8f57-07ca938cc8a4",
  "message_id": "4acb66d3-f669-454e-8f57-07ca938cc8a4",
  "sequence": 1,
  "timestamp": 1760000000000,
  "version": 1,
  "payload": {
    "provider_id": "anthropic",
    "include_deprecated": false,
    "include_login_required": true
  }
}
```

Provider models response:

```json
{
  "type": "models_response",
  "stream_id": "4acb66d3-f669-454e-8f57-07ca938cc8a4",
  "message_id": "5f038bdf-f145-4852-bf80-5226eaeb7867",
  "sequence": 2,
  "in_reply_to": "4acb66d3-f669-454e-8f57-07ca938cc8a4",
  "timestamp": 1760000000200,
  "version": 1,
  "payload": {
    "fetched_at_ms": 1760000000198,
    "models": [
      {
        "model_ref": "anthropic:claude-sonnet-4-5",
        "model_id": "claude-sonnet-4-5",
        "display_name": "Claude Sonnet 4.5",
        "provider_id": "anthropic",
        "api": "anthropic-messages",
        "auth_status": "authenticated",
        "lifecycle": "stable",
        "capabilities": ["chat", "streaming", "tools", "reasoning"]
      }
    ]
  }
}
```

## 7. Error Model (Normative)

Use existing `nack` / `agent_error` envelopes.

Recommended error code mapping:
- Missing/invalid auth: `provider_error` with reason prefix `auth:`
- Unsupported models list op: `not_implemented`
- Provider timeout/upstream issue: `provider_error`
- Invalid filter arguments: `invalid_request`

## 8. Compatibility and Rollout

1. Phase A: ship provider `models_request/models_response` first.
2. Phase B: ship TS `client.models.list` against provider protocol.
3. Phase C: ship agent passthrough `models_request/models_response`.
4. Phase D: switch demo to spec interfaces only.

Backward compatibility:
- Keep protocol version as `1`.
- Feature detect by attempting models request and handling `not_implemented`.

## 9. Acceptance Criteria

1. TS client can complete OAuth + list models + execute selected model without provider-specific app code.
2. Model list output shape is identical whether called via provider endpoint or agent passthrough.
3. Agent and provider execution accept the same `model_ref` format.
4. Existing auth and stream/complete flows remain functional.
