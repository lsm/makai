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

### 2.1 Agent vs Provider Path (Normative)

- `client.agent.run` / `client.agent.stream`:
  - default end-user path,
  - includes session semantics and tool-orchestration behavior,
  - preferred for agentic workflows and multi-turn execution.
- `client.provider.complete` / `client.provider.stream`:
  - advanced direct-provider path,
  - no agent loop/tool orchestration beyond what provider natively supports,
  - preferred for simple passthrough chat/completion workloads.

### 2.2 Model Data Source and Caching (Normative)

Model discovery is provider-owned and auth-aware.

Data source precedence:
1. Dynamic provider fetch (if provider exposes model listing and credentials allow it).
2. Static built-in fallback catalog (for providers without dynamic listing support).

Caching rules:
- `fetched_at_ms` is required for all responses.
- `cache_max_age_ms` is required for all responses.
- Clients treat cached data as stale when `now_ms > fetched_at_ms + cache_max_age_ms`.
- `source` is per-model metadata: `"dynamic"` or `"static_fallback"`.
- Recommended server defaults:
  - dynamic source: `cache_max_age_ms = 300_000` (5 minutes),
  - static fallback: `cache_max_age_ms = 3_600_000` (1 hour).
- Auth status can lag reality by up to `cache_max_age_ms` in cache-hit paths.

Auth for listing:
- Providers that require auth for model listing must return `auth_status = "login_required"` (or `"expired"` / `"failed"`).
- Missing auth must not hard-fail the whole response if static fallback is available.

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

export type AuthStatus =
  | "authenticated"
  | "login_required"
  | "expired"
  | "refreshing"
  | "login_in_progress"
  | "failed"
  | "unknown";

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

export type ModelSource = "dynamic" | "static_fallback";

export interface ProviderAuthInfo {
  id: ProviderId;
  name: string;
  auth_status: AuthStatus;
  last_error?: string;
}

export interface ModelDescriptor {
  model_ref: string; // opaque stable handle, server-issued
  model_id: string;
  display_name: string;
  provider_id: ProviderId;
  api: ApiId;
  base_url?: string;
  auth_status: AuthStatus;
  lifecycle: ModelLifecycle;
  capabilities: ModelCapability[];
  source: ModelSource;
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
  cache_max_age_ms: number;
}

export type TextContentPart = {
  type: "text";
  text: string;
  text_signature?: string;
};

export type ThinkingContentPart = {
  type: "thinking";
  thinking: string;
  thinking_signature?: string;
};

export type ImageContentPart = {
  type: "image";
  data: string;
  mime_type: string;
};

export type ToolCallContentPart = {
  type: "tool_call";
  tool_call_id: string;
  name: string;
  arguments_json: string;
};

export type ToolResultContentPart = {
  type: "tool_result";
  tool_call_id: string;
  tool_name: string;
  content: string | TextContentPart[]; // V1 minimal structured result
  is_error?: boolean;
  details_json?: string;
};

export type ContentPart =
  | TextContentPart
  | ThinkingContentPart
  | ImageContentPart
  | ToolCallContentPart
  | ToolResultContentPart;

export interface ChatMessage {
  role: "system" | "developer" | "user" | "assistant" | "tool";
  content: string | ContentPart[];
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
  reasoning_effort?: "off" | "minimal" | "low" | "medium" | "high" | "xhigh";
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
    content: string | ContentPart[];
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

export type ProviderStreamEvent =
  | { type: "message_start" }
  | { type: "text_delta"; delta: string }
  | { type: "thinking_delta"; delta: string }
  | { type: "reasoning_delta"; delta: string }
  | { type: "tool_call"; name: string; arguments_json: string; tool_call_id: string }
  | { type: "message_end" }
  | { type: "error"; message: string; code?: string };

export type AgentStreamEvent =
  | ProviderStreamEvent
  | { type: "turn_start" }
  | { type: "turn_end"; stop_reason?: string }
  | { type: "tool_execution_start"; tool_call_id: string; tool_name: string }
  | { type: "tool_execution_update"; tool_call_id: string; delta: string }
  | { type: "tool_execution_end"; tool_call_id: string; is_error?: boolean };

export interface ProviderCompleteRequest {
  model_ref: string;
  messages: ChatMessage[];
  options?: RunOptions;
}

export interface ProviderCompleteResponse {
  message: {
    role: "assistant";
    content: string | ContentPart[];
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
  }): Promise<{ status: "success" }>;
}

export class MakaiAuthError extends Error {
  code?: string;
  kind: "provider_error" | "cancelled" | "transport_error" | "unknown";
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
  stream(request: ProviderCompleteRequest): AsyncIterable<ProviderStreamEvent>;
}

export interface MakaiClient {
  auth: MakaiAuthApi;
  models: MakaiModelsApi;
  agent: MakaiAgentApi;
  provider: MakaiProviderApi;
  close(): Promise<void>;
}
```

### 3.3 Auth Cancellation Semantics (Normative)

- User-cancelled OAuth must reject with `MakaiAuthError { kind: "cancelled" }`.
- Successful login resolves with `{ status: "success" }`.

### 3.1 `model_ref` Format (Normative)

`model_ref` is an opaque, server-issued stable handle. Clients must not parse it.

Server canonicalization requirement:
- provider runtime defines canonical `formatModelRef(...)` and `parseModelRef(...)` helpers,
- helpers must support model IDs containing `:` and other UTF-8 characters without ambiguity.

Recommended internal canonical form:
- `<provider_id>/<api>@<percent-encoded-model-id>`
- this is a server detail; clients still treat `model_ref` as opaque.

Versioning/stability:
- servers may remap legacy aliases to canonical refs,
- once a ref is emitted by `models.list`, it must remain valid until model retirement policy removes it.

Required helper surfaces:
- Zig: `protocol/model_ref.zig` with parse/format + tests.
- TS: `parseModelRef` utility for diagnostics only (not required for normal API usage).

### 3.2 `ModelDescriptor` vs `ai_types.Model` (Normative)

`ModelDescriptor` and `ai_types.Model` co-exist with distinct responsibilities:
- `ModelDescriptor`: discovery-plane metadata for SDK/users.
- `ai_types.Model`: execution-plane provider config used by stream/complete internals.

Resolution model:
1. External SDK requests carry `model_ref`.
2. Binary resolves `model_ref -> ai_types.Model` via a model resolver.
3. Existing internal provider protocol may continue using `ai_types.Model` payloads in V1.

Normative implementation requirement:
- introduce a single resolver component (`model_catalog` + `model_resolver`) that is the only conversion boundary.
- do not duplicate ad-hoc `ModelDescriptor -> Model` conversions across handlers.

Type safety requirement:
- Zig protocol model capabilities must use an enum (not string slices).
- TS string union remains API-facing; mapping happens at serialization boundaries.

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
    auth_status: enum { authenticated, login_required, expired, refreshing, login_in_progress, failed, unknown },
    lifecycle: enum { stable, preview, deprecated },
    capabilities: OwnedSlice(ModelCapability),
    source: enum { dynamic, static_fallback },
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
};

pub const ModelsResponse = struct {
    models: OwnedSlice(ModelDescriptor),
    fetched_at_ms: i64,
    cache_max_age_ms: u64,
    pub fn deinit(self: *ModelsResponse, allocator: std.mem.Allocator) void { ... }
};

pub const ModelCapability = enum {
    chat,
    streaming,
    tools,
    vision,
    reasoning,
    prompt_cache,
    audio_input,
    audio_output,
};
```

Envelope type values:
- `"models_request"`
- `"models_response"`

Server behavior:
1. On `models_request`, return `ack` then `models_response`, or `nack` on failure.
2. For unsupported runtime, return `nack` with `error_code = not_implemented`.
3. Dynamic listing should be preferred; static fallback may be used when dynamic listing is unavailable.
4. For mixed-auth states, return partial results with per-model `auth_status` instead of failing the entire call.

Client behavior:
1. Treat `not_implemented` as capability absence.
2. Preserve existing behavior for `stream_request` and `complete_request`.

## 5. Agent Protocol Changes (Normative)

File target: `zig/src/protocol/agent/types.zig`

Add payload variants:
- `models_request: struct { provider_id: OwnedSlice(u8), api: OwnedSlice(u8), include_deprecated: bool, include_login_required: bool }`
- `models_response: SharedModelsResponse`

Rationale: agent protocol carries passthrough model discovery for clients connected only to agent endpoint.
`SharedModelsResponse` must reuse the same typed shape as provider protocol (no raw JSON blob passthrough).

Required shared module:
- `protocol/model_catalog_types.zig`
  - contains `ModelCapability`, `ModelDescriptor`, `ModelsResponse`.
- provider and agent protocol types import shared model catalog types.

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
        "model_ref": "anthropic/anthropic-messages@claude-sonnet-4-5",
        "model_id": "claude-sonnet-4-5",
        "display_name": "Claude Sonnet 4.5",
        "provider_id": "anthropic",
        "api": "anthropic-messages",
        "auth_status": "authenticated",
        "lifecycle": "stable",
        "capabilities": ["chat", "streaming", "tools", "reasoning"],
        "source": "dynamic"
      }
    ],
    "cache_max_age_ms": 300000
  }
}
```

## 7. Error Model (Normative)

Use existing `nack` / `agent_error` envelopes.

Recommended error code mapping:
- Missing/invalid auth: `auth_required`
- Unsupported models list op: `not_implemented`
- Provider timeout/upstream issue: `provider_error`
- Invalid filter arguments: `invalid_request`
- Refresh failure: `auth_refresh_failed`
- Expired token without refresh path: `auth_expired`

Provider protocol requirement:
- extend provider `ErrorCode` enum with:
  - `auth_required`
  - `auth_refresh_failed`
  - `auth_expired`

Auth refresh semantics:
- Refresh occurs in Zig binary request path.
- On expired credentials, implementation may auto-refresh before request dispatch.
- If refresh fails, return typed code `auth_refresh_failed`.

## 8. Compatibility and Rollout

1. Phase A: ship provider `models_request/models_response` first.
2. Phase B: ship TS `client.models.list` against provider protocol.
3. Phase C: ship agent passthrough `models_request/models_response`.
4. Phase D: switch demo to spec interfaces only.

Backward compatibility:
- Keep envelope protocol version as `1`.
- Feature detect by attempting models request and handling `not_implemented`.
- V1 evolution rule: additive-only changes. Do not repurpose existing fields.
- Unknown fields must be ignored by parsers.

Capability negotiation:
- V1 uses implicit feature detection (`not_implemented` probing).
- Optional explicit capability advertisement may be added in a future protocol revision.

## 9. Acceptance Criteria

1. TS client can complete OAuth + list models + execute selected model without provider-specific app code.
2. Model list output shape is identical whether called via provider endpoint or agent passthrough.
3. Agent and provider execution accept the same `model_ref` format.
4. Existing auth and stream/complete flows remain functional.

## 10. Model List Scope and Cancellation (V1)

- V1 model list returns all matching models (no pagination).
- Pagination (`next_cursor`/`limit`) and search semantics are deferred to a future revision.
- `models_request` is not cancellable in V1.

## 11. Stream Recovery (V1)

- V1 streams are not resumable after transport interruption.
- Client behavior on interruption: retry request with full context.
- Session-level replay/resume is deferred to a future revision.
