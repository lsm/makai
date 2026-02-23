# Makai V1 SDK + Protocol Spec

Status: approved for implementation

## 1. Scope

This spec defines:
- End-user OAuth and model-selection flow.
- TypeScript SDK public interfaces for auth, model discovery, agent execution, and provider-direct execution.
- Auth protocol schema for interactive OAuth flows.
- Provider protocol schema additions for model discovery.
- Agent protocol schema additions for model-discovery passthrough.

This spec does not define transport framing changes.

## 2. End-User Flow (Normative)

1. User creates a single client and connects to `makai`.
2. User calls `client.auth.listProviders()`.
3. User calls `client.auth.login(providerId)` if needed.
4. User calls `client.models.list()`.
   - Optional: call `client.models.resolve(...)` for deterministic provider/model lookup.
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
  - supports provider-native tool/function calling via request `tools` when available,
  - preferred for simple passthrough chat/completion workloads.

### 2.2 Auth Path and Transport (Normative)

- `client.auth.*` is a protocol client surface at the same level as `client.agent.*` and `client.provider.*`.
- Auth is a dedicated protocol surface, not a sub-mode of provider protocol.
- SDK auth operations must use the same configured transport stack (stdio now, HTTP/WS later) as other APIs.
- SDK implementations must not spawn `makai auth ...` subprocesses as the primary auth path.
- OAuth credentials and refresh tokens remain binary-managed and are never returned to SDK callers.
- CLI commands (`makai auth providers`, `makai auth login`) must be thin wrappers over the same auth protocol runtime.
- SDKs should support client-level auth defaults (retry policy + interactive handlers) so apps configure auth UX once and reuse it across requests.

### 2.3 Model Data Source and Caching (Normative)

Model discovery is provider-owned and auth-aware.

Data source precedence:
1. Dynamic provider fetch (if provider exposes model listing and credentials allow it).
2. Static built-in fallback catalog (for providers without dynamic listing support).

Caching rules:
- `fetched_at_ms` is required for all responses.
- `cache_max_age_ms` is required for all responses.
- Clients treat cached data as stale when `now_ms > fetched_at_ms + cache_max_age_ms`.
- If `cache_max_age_ms` is missing from a non-conformant server response, clients should default to `300_000` (5 minutes).
- `source` is per-model metadata: `"dynamic"` or `"static_fallback"`.
- `fetched_at_ms` is response-generation time (not per-model last-verified time).
- Recommended server defaults:
  - dynamic source: `cache_max_age_ms = 300_000` (5 minutes),
  - static fallback: `cache_max_age_ms = 3_600_000` (1 hour).
- Auth status can lag reality by up to `cache_max_age_ms` in cache-hit paths.
- `models.resolve(...)` reuses the same cache semantics as `models.list(...)`.

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
export type AuthRetryPolicy = "manual" | "auto_once";

// Known values are standardized; the union stays open-ended for forward compatibility.
export type StopReason =
  | "end_turn"
  | "max_tokens"
  | "tool_use"
  | "stop_sequence"
  | "max_turns"
  | string;

export interface ProviderAuthInfo {
  id: ProviderId;
  name: string;
  auth_status: AuthStatus;
  last_error?: string;
}

export type MakaiAuthEvent =
  | {
      type: "auth_url";
      flow_id: string;
      provider_id: ProviderId;
      url: string;
      instructions?: string;
    }
  | {
      type: "prompt";
      flow_id: string;
      prompt_id: string;
      provider_id: ProviderId;
      message: string;
      allow_empty: boolean;
    }
  | {
      type: "progress";
      flow_id: string;
      provider_id: ProviderId;
      message: string;
    }
  | {
      type: "success";
      flow_id: string;
      provider_id: ProviderId;
    }
  | {
      type: "error";
      flow_id: string;
      provider_id: ProviderId;
      code?: string;
      message: string;
    };

export interface AuthFlowHandlers {
  onEvent?: (event: MakaiAuthEvent) => void;
  onPrompt?: (prompt: Extract<MakaiAuthEvent, { type: "prompt" }>) => Promise<string> | string;
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
  model_id?: string; // exact-match filter used by resolve semantics
  include_deprecated?: boolean;
  include_login_required?: boolean;
}

export interface ListModelsResponse {
  models: ModelDescriptor[];
  fetched_at_ms: number;
  cache_max_age_ms: number;
}

export interface ResolveModelRequest {
  provider_id: ProviderId;
  api?: ApiId;
  model_id: string;
}

export interface ResolveModelResponse {
  model: ModelDescriptor;
}

export type TextContentPart = {
  type: "text";
  text: string;
  // Optional provider passthrough signature for replay/integrity workflows.
  text_signature?: string;
};

export type ThinkingContentPart = {
  type: "thinking";
  thinking: string;
  // Optional provider passthrough signature for replay/integrity workflows.
  thinking_signature?: string;
};

export type ImageContentPart = {
  type: "image";
  data: string;
  mime_type: string;
};

export type ToolCallContentPart = {
  type: "tool_call";
  // Correlates with Zig/provider tool-use identifiers.
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
  // Optional JSON-encoded provider/runtime metadata for diagnostics or replay context.
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
  // JSON-string form preserves wire parity with Zig protocol envelopes.
  parameters_schema_json: string;
}

export interface RunOptions {
  temperature?: number;
  max_tokens?: number;
  // If the selected model lacks `reasoning` capability, server may ignore this field.
  reasoning_effort?: "off" | "minimal" | "low" | "medium" | "high" | "xhigh";
  // Overrides client-level default when provided.
  // Effective default remains "manual".
  auth_retry_policy?: AuthRetryPolicy;
  session_id?: string;
  metadata?: Record<string, string>;
}

export interface UsageSummary {
  input: number;
  output: number;
  cache_read?: number;
  cache_write?: number;
}

export interface AgentRunRequest {
  model_ref: string;
  messages: ChatMessage[];
  tools?: ToolDefinition[];
  options?: RunOptions;
}

export interface CompletionResponse {
  message: {
    role: "assistant";
    content: string | ContentPart[];
  };
  usage?: UsageSummary;
  provider_id: ProviderId;
  api: ApiId;
  model_id: string;
  stop_reason?: StopReason;
}

export type AgentRunResponse = CompletionResponse;

// Provider-native reasoning/thinking deltas are normalized to `thinking_delta`.
export type ProviderStreamEvent =
  | { type: "message_start"; provider_id?: ProviderId; api?: ApiId; model_id?: string }
  | { type: "text_delta"; delta: string }
  | { type: "thinking_delta"; delta: string }
  // V1 emits tool calls only after full argument buffering (non-incremental).
  | { type: "tool_call"; name: string; arguments_json: string; tool_call_id: string }
  | { type: "message_end"; usage?: UsageSummary; stop_reason?: StopReason }
  | { type: "error"; message: string; code?: string };

export type AgentStreamEvent =
  | ProviderStreamEvent
  | { type: "agent_start"; session_id?: string }
  | { type: "agent_end"; stop_reason?: StopReason; usage?: UsageSummary }
  | { type: "turn_start" }
  | { type: "turn_end"; stop_reason?: StopReason }
  | { type: "tool_execution_start"; tool_call_id: string; tool_name: string }
  | { type: "tool_execution_end"; tool_call_id: string; is_error?: boolean };

export interface ProviderCompleteRequest {
  model_ref: string;
  messages: ChatMessage[];
  tools?: ToolDefinition[];
  options?: RunOptions;
}
// V1 request shapes are currently aligned across agent/provider; method namespaces
// stay separate for ergonomics and future divergence.

export type ProviderCompleteResponse = CompletionResponse;
// V1 reuses a shared completion shape for both agent/provider non-streaming paths.
// Method namespaces stay separate for ergonomics and future divergence.

export interface MakaiAuthApi {
  listProviders(): Promise<ProviderAuthInfo[]>;
  // Handler precedence: per-call handlers > client-level defaults > none.
  login(providerId: ProviderId, handlers?: AuthFlowHandlers): Promise<{ status: "success" }>;
}

export class MakaiAuthError extends Error {
  code?: string;
  kind: "provider_error" | "cancelled" | "transport_error" | "unknown";
}

export class MakaiStreamError extends Error {
  code?: string;
  kind: "provider_error" | "transport_error" | "aborted" | "unknown";
}

export interface MakaiModelsApi {
  list(request?: ListModelsRequest): Promise<ListModelsResponse>;
  resolve(request: ResolveModelRequest): Promise<ResolveModelResponse>;
}

export interface MakaiClientOptions {
  auth?: {
    // Client-level default for all provider/agent requests unless overridden in RunOptions.
    auth_retry_policy?: AuthRetryPolicy;
    // Default interactive handlers used by auth.login(...) and auto_once retry flows.
    handlers?: AuthFlowHandlers;
  };
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

export function createMakaiClient(options?: MakaiClientOptions): Promise<MakaiClient>;
```

### 3.1 `model_ref` Format (Normative)

`model_ref` is an opaque, server-issued stable handle. Clients must not parse it.

Server canonicalization requirement:
- provider runtime defines canonical `formatModelRef(...)` and `parseModelRef(...)` helpers,
- helpers must support model IDs containing `:` and other UTF-8 characters without ambiguity.
- provider-returned `model_id` values are preserved as-is in `ModelDescriptor.model_id` (including colons).

Recommended internal canonical form:
- `<provider_id>/<api>@<percent-encoded-model-id>`
- this is a server detail; clients still treat `model_ref` as opaque.

Versioning/stability:
- servers may remap legacy aliases to canonical refs,
- once a ref is emitted by `models.list`, it must remain valid until model retirement policy removes it.
- scripts/config/tests may persist `model_ref` values directly.

Bootstrapping requirement:
- SDK must provide `models.resolve({ provider_id, api?, model_id }) -> { model }` for deterministic lookup.
- `resolve` is server-side and maps to `models_request` with exact `model_id` filter (not client-side full-list filtering by default).
- If `api` is omitted and multiple models match within the provider, server must return `nack` with `error_code = invalid_request`.
- If no models match resolve criteria, server must return `nack` with `error_code = invalid_request` and a "model not found" message.

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
- Wire format note: `capabilities` are string-encoded in JSON and deserialized into `ModelCapability` enums in Zig.
- Wire format note: `metadata` serializes as a JSON object (`Record<string, string>` in TS) and maps to `MetadataEntry[]` in Zig.

### 3.3 Auth Cancellation Semantics (Normative)

- User-cancelled OAuth (`auth_login_result.status = cancelled`) must reject with `MakaiAuthError { kind: "cancelled" }`.
- Successful login resolves with `{ status: "success" }`.

### 3.4 Stream Lifecycle and Error Propagation (Normative)

Provider stream rules:
- Each provider stream must emit exactly one terminal event: `message_end` or `error`.
- Terminal `error` must end the stream; `message_end` must not be followed by `error`.
- Provider-native naming differences for reasoning output (for example `"reasoning"` vs `"thinking"`) must be normalized to `thinking_delta`.
- `message_start` may include resolved `provider_id`, `api`, and `model_id` metadata when available.
- `message_end` should include `usage` and `stop_reason` when available from upstream provider.
- `tool_call` is emitted after full argument buffering in V1; incremental tool-call delta streaming is deferred (planned future shape: `tool_call_start` / `tool_call_delta` / `tool_call_end`).

Agent stream rules:
- Agent streams wrap one or more provider turns and may emit `turn_start` / `turn_end` plus tool execution lifecycle events.
- `agent_start` should be the first agent-level event for a run and may include resolved `session_id`.
- Each agent stream must emit exactly one terminal event for the overall run: `agent_end` or `error`.
- On success, `agent_end` must be the last event in the stream and should include aggregate `usage` and `stop_reason`.
- Aggregate `usage` sums token counts across all provider turns; `cache_read` reflects total cache-hit tokens, not unique cached content.
- `turn_end` marks per-turn boundaries only and must not be interpreted as overall stream completion.
- `turn_end.stop_reason` is turn-scoped; `agent_end.stop_reason` may include agent-level reasons such as `max_turns`.
- V1 tool execution events are lifecycle-only: `tool_execution_start` and `tool_execution_end`.
- `tool_execution_update` is deferred to a future revision and is not required for V1 compatibility.
- For a single failure, SDK-visible stream events must contain one terminal `error` event (no duplicate provider+agent terminal errors for the same failure), and `agent_end` must not be emitted.

SDK behavior:
- Async iterator failure paths may throw `MakaiStreamError`.
- Envelope-level protocol errors and stream terminal `error` events should map to a single surfaced failure per request.

### 3.5 `models.resolve` Wire Mapping (Normative)

- V1 does not define separate `resolve_model_request` / `resolve_model_response` envelope types.
- `models.resolve(...)` maps to `models_request` with:
  - required `provider_id`,
  - required exact `model_id` filter,
  - optional `api`.
- If runtime returns more than one result for a resolve request, SDK must treat it as an `invalid_request` error.
- If runtime returns no result for a resolve request, SDK must surface `invalid_request` with a "model not found" message.

### 3.6 Auth Transport Semantics (Normative)

- `MakaiAuthApi.listProviders` and `MakaiAuthApi.login` must map to auth protocol envelopes over the active transport.
- `login(...)` must maintain a single active auth flow, route prompt events to `onPrompt`, and publish all auth events to `onEvent`.
- Handler resolution order for `login(...)` is normative: per-call handlers first, then `MakaiClientOptions.auth.handlers`, then none.
- SDK must not read `~/.makai/auth.json` directly and must not return token material to callers.
- CLI-subprocess auth wiring is prohibited in the V1 protocol-only implementation.
- On `auth_required` from provider/agent calls:
  - `auth_retry_policy = "manual"` (default): SDK throws typed error containing `provider_id`.
  - `auth_retry_policy = "auto_once"`: SDK runs `client.auth.login(provider_id)` then retries the original request once.
  - `auto_once` uses client-level default auth handlers from `MakaiClientOptions.auth.handlers`.
  - If `auto_once` is selected and interactive auth is required but no default handlers are configured, SDK must fail fast with typed `auth_required` (manual-login path), not silently hang.
  - If provider auth can complete non-interactively, `auto_once` may succeed without handlers.

## 4. Auth Protocol Changes (Normative)

File target: `zig/src/protocol/auth/types.zig`

Add payload variants:
- `auth_providers_request: struct {}`
- `auth_providers_response: AuthProvidersResponse`
- `auth_login_start: AuthLoginStartRequest`
- `auth_prompt_response: AuthPromptResponse`
- `auth_cancel: AuthCancelRequest`
- `auth_event: AuthEvent`
- `auth_login_result: AuthLoginResult`

Add request/response structs:

```zig
pub const AuthProviderInfo = struct {
    id: OwnedSlice(u8),
    name: OwnedSlice(u8),
    auth_status: enum { authenticated, login_required, expired, refreshing, login_in_progress, failed, unknown },
    last_error: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
};

pub const AuthProvidersResponse = struct {
    providers: OwnedSlice(AuthProviderInfo),
};

pub const AuthLoginStartRequest = struct {
    provider_id: OwnedSlice(u8),
};

pub const AuthPromptResponse = struct {
    flow_id: Uuid,
    prompt_id: OwnedSlice(u8),
    answer: OwnedSlice(u8),
};

pub const AuthCancelRequest = struct {
    flow_id: Uuid,
};

pub const AuthEvent = union(enum) {
    auth_url: struct { flow_id: Uuid, provider_id: OwnedSlice(u8), url: OwnedSlice(u8), instructions: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed("") },
    prompt: struct { flow_id: Uuid, prompt_id: OwnedSlice(u8), provider_id: OwnedSlice(u8), message: OwnedSlice(u8), allow_empty: bool = false },
    progress: struct { flow_id: Uuid, provider_id: OwnedSlice(u8), message: OwnedSlice(u8) },
    success: struct { flow_id: Uuid, provider_id: OwnedSlice(u8) },
    error: struct { flow_id: Uuid, provider_id: OwnedSlice(u8), code: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""), message: OwnedSlice(u8) },
};

pub const AuthLoginResult = struct {
    flow_id: Uuid,
    provider_id: OwnedSlice(u8),
    status: enum { success, cancelled, failed },
};
```

Envelope type values:
- `"auth_providers_request"`
- `"auth_providers_response"`
- `"auth_login_start"`
- `"auth_prompt_response"`
- `"auth_cancel"`
- `"auth_event"`
- `"auth_login_result"`

Server behavior:
1. On `auth_providers_request`, return `ack` then `auth_providers_response`.
2. On `auth_login_start`, return `ack`, then zero or more `auth_event`, then exactly one terminal `auth_login_result`.
3. If a login flow emits `prompt`, server waits for matching `auth_prompt_response` (`flow_id`, `prompt_id`) before continuing.
4. `auth_cancel` must terminate the targeted flow and emit `auth_login_result.status = cancelled`.
5. Credentials are persisted by auth runtime; token/refresh secrets must never be emitted in protocol payloads.
6. Standalone auth queries (`auth_providers_request`) are sequenced by envelope `stream_id`; login flow messages are sequenced by `flow_id`.
7. Terminal auth event ordering is required: emit `auth_event.success` or `auth_event.error` before `auth_login_result`.
8. `auth_prompt_response` received after flow termination/cancellation must be ignored.
9. Provider adapters that require manual code fallback (for example Google `onManualCodeInput`) must surface it as a normal `auth_event.prompt` (message-driven).

Client behavior:
1. SDK auth APIs must use this protocol over the active transport (stdio/HTTP/WS).
2. SDK auth APIs must not shell out to `makai auth ...`.
3. CLI auth commands (`makai auth providers/login`) must call the same auth protocol runtime (wrapper mode), not duplicate OAuth logic.
4. SDK event adapters must flatten auth event wire shape for TS API consumers.

Wire format note:
- Auth events on the wire are Zig union objects (for example `{ "prompt": { ... } }`).
- TS SDK presents flattened events (`{ type: "prompt", ... }`) via `MakaiAuthEvent`.

## 5. Provider Protocol Changes (Normative)

File target: `zig/src/protocol/provider/types.zig`

Add payload variants:
- `models_request: ModelsRequest`
- `models_response: ModelsResponse`

Add request/response structs:

```zig
pub const ModelsRequest = struct {
    provider_id: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    api: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    model_id: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""), // exact match filter
    include_deprecated: bool = false,
    include_login_required: bool = true,

    pub fn getProviderId(self: *const ModelsRequest) ?[]const u8 { ... }
    pub fn getApi(self: *const ModelsRequest) ?[]const u8 { ... }
    pub fn getModelId(self: *const ModelsRequest) ?[]const u8 { ... }
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
    reasoning_default: ?ReasoningLevel = null,
    metadata: ?OwnedSlice(MetadataEntry) = null,
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

pub const ReasoningLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const MetadataEntry = struct {
    key: OwnedSlice(u8),
    value: OwnedSlice(u8),
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
5. If `model_id` is set, server must apply exact-match filtering before response.
6. If `model_id` is set and `api` is omitted and multiple matches remain, return `nack` with `error_code = invalid_request`.
7. If `model_id` is set and no matches remain, return `nack` with `error_code = invalid_request` and "model not found" detail.

Client behavior:
1. Treat `not_implemented` as capability absence.
2. Preserve existing behavior for `stream_request` and `complete_request`.
3. `models.resolve(...)` should issue `models_request` with `provider_id` + exact `model_id` filter (and optional `api`).

## 6. Agent Protocol Changes (Normative)

File target: `zig/src/protocol/agent/types.zig`

Add payload variants:
- `models_request: struct { provider_id: OwnedSlice(u8), api: OwnedSlice(u8), model_id: OwnedSlice(u8), include_deprecated: bool, include_login_required: bool }`
- `models_response: ModelsResponse`

Rationale: agent protocol carries passthrough model discovery for clients connected only to agent endpoint.
`ModelsResponse` must reuse the same typed shape as provider protocol (no raw JSON blob passthrough).
Passthrough requirement includes all `ModelsResponse` fields (`models`, `fetched_at_ms`, `cache_max_age_ms`) and per-model `source`.

Required shared module:
- `protocol/model_catalog_types.zig`
  - contains `ModelCapability`, `ModelDescriptor`, `ModelsResponse`.
- provider and agent protocol types import shared model catalog types.

Normative rule: provider protocol remains canonical source; agent protocol passthrough must return the same model set and shape.

## 7. JSON Envelope Examples (Normative)

Auth providers request:

```json
{
  "type": "auth_providers_request",
  "stream_id": "89ef1cb9-9d15-4f5a-8cb6-8659e1986f01",
  "message_id": "89ef1cb9-9d15-4f5a-8cb6-8659e1986f01",
  "sequence": 1,
  "timestamp": 1760000000000,
  "version": 1,
  "payload": {}
}
```

Auth prompt event:

```json
{
  "type": "auth_event",
  "stream_id": "89ef1cb9-9d15-4f5a-8cb6-8659e1986f01",
  "message_id": "f642f5d0-30d1-4df2-8c5f-0fbc7b5f4fc2",
  "sequence": 3,
  "timestamp": 1760000000500,
  "version": 1,
  "payload": {
    "prompt": {
      "flow_id": "89ef1cb9-9d15-4f5a-8cb6-8659e1986f01",
      "prompt_id": "device_code",
      "provider_id": "anthropic",
      "message": "Enter the code shown in browser",
      "allow_empty": false
    }
  }
}
```

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

Resolve-style models request (same envelope with exact filter):

```json
{
  "type": "models_request",
  "stream_id": "10f42e8a-3d4c-4a90-9459-a7207d1d8b5f",
  "message_id": "10f42e8a-3d4c-4a90-9459-a7207d1d8b5f",
  "sequence": 1,
  "timestamp": 1760000001000,
  "version": 1,
  "payload": {
    "provider_id": "anthropic",
    "model_id": "claude-sonnet-4-5",
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

## 8. Error Model (Normative)

Use existing `nack` / `agent_error` / `auth_event.error` envelopes.

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

Auth protocol requirement:
- auth flow failures must emit both:
  - `auth_event.error` for user-visible detail, and
  - terminal `auth_login_result.status = failed`.
- SDK implementations must capture the terminal `auth_event.error` (`code`, `message`) and propagate it into `MakaiAuthError` when the terminal login result is `failed`.

Auth refresh semantics:
- Refresh occurs in Zig binary request path.
- On expired credentials, implementation may auto-refresh before request dispatch.
- If refresh fails, return typed code `auth_refresh_failed`.

## 9. Compatibility and Rollout

1. Phase A: ship auth protocol (`auth_providers_request`, `auth_login_start`, auth event loop) first.
2. Phase B: ship TS `client.auth.*` over protocol transport (remove CLI-subprocess primary path).
3. Phase C: migrate `makai auth providers/login` CLI commands to wrapper mode over auth protocol runtime.
4. Phase D: ship provider `models_request/models_response` and TS `client.models.*`.
5. Phase E: ship agent passthrough `models_request/models_response`.
6. Phase F: switch demo to spec interfaces only.

Backward compatibility:
- Keep envelope protocol version as `1`.
- Feature detect by attempting models request and handling `not_implemented`.
- V1 evolution rule: additive-only changes. Do not repurpose existing fields.
- Unknown fields must be ignored by parsers.

Capability negotiation:
- V1 uses implicit feature detection (`not_implemented` probing).
- Optional explicit capability advertisement may be added in a future protocol revision.

## 10. Acceptance Criteria

1. TS client can complete OAuth + list models + execute selected model without provider-specific app code.
2. Model list output shape is identical whether called via provider endpoint or agent passthrough.
3. Agent and provider execution accept the same `model_ref` format.
4. SDK auth APIs run over protocol transport without shelling out to CLI commands.
5. `makai auth providers/login` remains functional as wrapper commands over auth protocol runtime.
6. Existing stream/complete flows remain functional.

## 11. Model List Scope and Cancellation (V1)

- V1 model list returns all matching models (no pagination).
- Expected V1 scale target is O(100) models in a single response.
- Catalogs approaching O(1000+) models should be addressed with future pagination/search support.
- Pagination (`next_cursor`/`limit`) and search semantics are deferred to a future revision.
- `models_request` is not cancellable in V1.

## 12. Stream Recovery (V1)

- V1 streams are not resumable after transport interruption.
- Client behavior on interruption: retry request with full context.
- Session-level replay/resume is deferred to a future revision.
