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
      flow_id: string; // 26-character Crockford's Base32 ULID
      provider_id: ProviderId;
      url: string;
      instructions?: string;
    }
  | {
      type: "prompt";
      flow_id: string; // 26-character Crockford's Base32 ULID
      prompt_id: string;
      provider_id: ProviderId;
      message: string;
      allow_empty: boolean;
    }
  | {
      type: "progress";
      flow_id: string; // 26-character Crockford's Base32 ULID
      provider_id: ProviderId;
      message: string;
    }
  | {
      type: "success";
      flow_id: string; // 26-character Crockford's Base32 ULID
      provider_id: ProviderId;
    }
  | {
      type: "error";
      flow_id: string; // 26-character Crockford's Base32 ULID
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
  // Optional 21-character alphanumeric NanoID. If omitted, the agent runtime creates one.
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
  // Optional diagnostic error text when stop_reason === "error" — the provider
  // error detail (e.g. "auth_required") or a server-side failure cause.
  error_message?: string;
}

export type AgentRunResponse = CompletionResponse;

// Provider-native reasoning/thinking deltas are normalized to `thinking_delta`.
export type ProviderStreamEvent =
  | { type: "message_start"; provider_id?: ProviderId; api?: ApiId; model_id?: string }
  | { type: "text_delta"; delta: string }
  | { type: "thinking_delta"; delta: string }
  // V1 emits tool calls only after full argument buffering (non-incremental).
  | { type: "tool_call"; name: string; arguments_json: string; tool_call_id: string }
  | { type: "message_end"; usage?: UsageSummary; stop_reason?: StopReason; error_message?: string }
  | { type: "error"; message: string; code?: string };

export type AgentStreamEvent =
  | ProviderStreamEvent
  | { type: "agent_start"; session_id?: string /* 21-character alphanumeric NanoID */ }
  | { type: "agent_end"; stop_reason?: StopReason; usage?: UsageSummary; error_message?: string; provider_id?: ProviderId; api?: ApiId }
  | { type: "turn_start" }
  | { type: "turn_end"; stop_reason?: StopReason; error_message?: string }
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

### 3.1 ID Formats (Normative)

Protocol ID fields use two wire formats:
- `session_id`: 21-character alphanumeric NanoID (`[A-Za-z0-9]{21}`), generated by the agent runtime when omitted by the caller.
- `message_id`, `stream_id`, and `flow_id`: 26-character Crockford's Base32 ULID (`[0-9A-HJKMNP-TV-Z]{26}`). ULIDs are serialized as uppercase strings and must be treated as opaque identifiers by clients.

`flow_id` values correlate all messages for an interactive auth login flow. `stream_id` values correlate provider and standalone auth request/response streams. `message_id` values identify individual envelopes.

### 3.2 `model_ref` Format (Normative)

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

### 3.3 `ModelDescriptor` vs `ai_types.Model` (Normative)

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

### 3.4 Auth Cancellation Semantics (Normative)

- User-cancelled OAuth (`auth_login_result.status = cancelled`) must reject with `MakaiAuthError { kind: "cancelled" }`.
- Successful login resolves with `{ status: "success" }`.

### 3.5 Stream Lifecycle and Error Propagation (Normative)

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
- When a turn fails at the provider (auth, invalid URL, network), `turn_end` and `agent_end` must carry the provider error detail in `error_message` (e.g. `"auth_required"`); `message_end` includes `error_message` when the failed turn still produced a terminal provider message event.
- The SDK keeps provider auth failures retryable: when the terminal `agent_end` (or the non-streaming run response) reports `stop_reason: "error"` with an auth failure `error_message` (mirroring the server-side auth failure detector: `auth_required` / `auth_expired` / `auth_refresh_failed` / 401 / 403 / unauthorized / forbidden), the SDK raises the typed auth error path (`MakaiAuthRequiredError`, engaging `auth_retry_policy`) instead of treating the run as a normal completion. Non-auth provider failures surface via the `error_message` fields above.
- V1 tool execution events are lifecycle-only: `tool_execution_start` and `tool_execution_end`.
- `tool_execution_update` is deferred to a future revision and is not required for V1 compatibility.
- For a single failure that surfaces as a stream `error` event (the loop-internal failure shape, §13.4.2), SDK-visible stream events must contain one terminal `error` event (no duplicate provider+agent terminal errors for the same failure), and `agent_end` must not be emitted. Provider-originated failures follow the preceding bullet instead: the failed turn still settles through the result path and `agent_end` IS emitted carrying the error detail — the two bullets are the event-stream projections of §13.4.2's two failure shapes.

SDK behavior:
- Async iterator failure paths may throw `MakaiStreamError`.
- Envelope-level protocol errors and stream terminal `error` events should map to a single surfaced failure per request.

### 3.6 `models.resolve` Wire Mapping (Normative)

- V1 does not define separate `resolve_model_request` / `resolve_model_response` envelope types.
- `models.resolve(...)` maps to `models_request` with:
  - required `provider_id`,
  - required exact `model_id` filter,
  - optional `api`.
- If runtime returns more than one result for a resolve request, SDK must treat it as an `invalid_request` error.
- If runtime returns no result for a resolve request, SDK must surface `invalid_request` with a "model not found" message.

### 3.7 Auth Transport Semantics (Normative)

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

Add request/response structs (`ULID` is the 26-character Crockford's Base32 protocol ID type):

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
    flow_id: ULID,
    prompt_id: OwnedSlice(u8),
    answer: OwnedSlice(u8),
};

pub const AuthCancelRequest = struct {
    flow_id: ULID,
};

pub const AuthEvent = union(enum) {
    auth_url: struct { flow_id: ULID, provider_id: OwnedSlice(u8), url: OwnedSlice(u8), instructions: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed("") },
    prompt: struct { flow_id: ULID, prompt_id: OwnedSlice(u8), provider_id: OwnedSlice(u8), message: OwnedSlice(u8), allow_empty: bool = false },
    progress: struct { flow_id: ULID, provider_id: OwnedSlice(u8), message: OwnedSlice(u8) },
    success: struct { flow_id: ULID, provider_id: OwnedSlice(u8) },
    error: struct { flow_id: ULID, provider_id: OwnedSlice(u8), code: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""), message: OwnedSlice(u8) },
};

pub const AuthLoginResult = struct {
    flow_id: ULID,
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
- `flow_id` is a ULID string with the same validation rules as `message_id` and `stream_id`.

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

### 6.1 Agent Session Teardown (Normative)

The server removes an agent session on `agent_stop` and, since the #202 idle-TTL eviction landed, on idleness past the configured TTL (§13.2.6 rule 6 — default 30 minutes, sessions with in-flight runs exempt, evicted ids indistinguishable from stopped ones). Session teardown is therefore client-owned for well-behaved clients, with server eviction as the backstop for abandoned ones:

- A client that uses one session per run (start → message → result) MUST send `agent_stop` when a run it owns reaches a terminal state: success, failure, or abandonment (including an auth-retry attempt whose session id is discarded). Otherwise the session stays registered until the idle TTL evicts it (§13.2.6 rule 6) — or for as long as continued activity keeps refreshing the TTL — and its id is rejected on reuse (`agent_busy`) for exactly as long as it stays registered. The mandate is bounded by ownership: a client MUST NOT stop a session its own `agent_start` did not establish — in particular, a start rejected with `agent_busy` means the id belongs to another live run, and a stop carrying the live session's expected sequence would remove and cancel that unrelated run. If the start's outcome is unknowable (reply lost, timeout), stopping is NOT unconditionally safe: the id may have been registered by another caller whose start won the race (ours rejected `agent_busy` with the reply lost), and that owner's fresh pre-message session also expects inbound sequence 2 — a sequence-2 stop is then ACCEPTED and destroys the owner's session. A client MAY stop on an unknown start outcome only with positive evidence the start was its own, and until generation tokens exist (#204) only ONE form is sufficient: an exclusive client-generated id that no other caller could have supplied AND that this client has not since allowed to be removed and re-registered. A request-correlated `agent_started` (`in_reply_to` naming its own start) proves ownership of the registration that request created, NOT that the same registration still occupies the id when the delayed reply is finally observed — if the id was stopped and re-registered in between (§13.4.5), the buffered correlated reply authorizes a sequence-2 stop against the NEW pre-message session; it qualifies only with generation proof. Session-scoped run output does NOT qualify at all (it carries no `in_reply_to`, §13.3.2, and on a colliding id may belong to the caller that won). Otherwise it SHOULD NOT stop: today the un-stopped session stays registered until the idle TTL evicts it (§13.2.6 rule 6) — repeated timeouts accumulate leaked sessions only until the TTL expires — still strictly preferable to destroying another caller's live session; the leak is bounded by eviction. This ownership guard is `[current — #205]`: the TS SDK settles the teardown tracker WITHOUT sending when an attempt ends without any reply to its own `agent_start` (timeout, lost reply, abort inside the start window) and the id was caller-supplied — a client-generated id keeps the unconditional stop (the one sufficient pre-#204 evidence), and any request-correlated reply to the start (`agent_started`, `nack`, or `agent_error` reaching the attempt's own correlation) resolves the start's outcome and restores the normal teardown; a correlated `agent_busy` still settles without stopping via the foreign-session guard. Ownership-safe teardown of unknown-outcome starts ultimately requires request-scoped ownership (a generation token on `agent_started`), tracked with the §13.4.5 reuse race in #204.
- The stop MUST carry the session's next expected inbound sequence (start=1, message=2, then one per follow-up message); out-of-order stops are rejected and leave the session registered. Tool-result replies do not consume inbound sequence numbers.
- `reason` is a free-form string; the TS SDK sends `"completed"` for terminal and error teardown and `"client aborted"` for signal aborts.
- After a successful stop, clients SHOULD drain remaining per-session frames: the server queues a terminal `agent_end` event after the `agent_result` frame, and a later run reusing the session id would otherwise consume that stale frame as its first frame.

## 7. JSON Envelope Examples (Normative)

Auth providers request:

```json
{
  "type": "auth_providers_request",
  "stream_id": "01K7ZY2P9B8X4FQJ3M6N0RTV5C",
  "message_id": "01K7ZY2P9B8X4FQJ3M6N0RTV5C",
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
  "stream_id": "01K7ZY2P9B8X4FQJ3M6N0RTV5C",
  "message_id": "01K7ZY315C6W2D8E9F0G1H2J3K",
  "sequence": 3,
  "timestamp": 1760000000500,
  "version": 1,
  "payload": {
    "prompt": {
      "flow_id": "01K7ZY2P9B8X4FQJ3M6N0RTV5C",
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
  "stream_id": "01K7ZY3ABCD4EFGHJKMNPQRSTV",
  "message_id": "01K7ZY3ABCD4EFGHJKMNPQRSTV",
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
  "stream_id": "01K7ZY3M1N2P3Q4R5S6T7V8W9X",
  "message_id": "01K7ZY3M1N2P3Q4R5S6T7V8W9X",
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
  "stream_id": "01K7ZY3ABCD4EFGHJKMNPQRSTV",
  "message_id": "01K7ZY3NF4A5B6C7D8E9F0G1H2",
  "sequence": 2,
  "in_reply_to": "01K7ZY3ABCD4EFGHJKMNPQRSTV",
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
- `agent_start` payload session key (#198): `session_id` is canonical; servers accept
  the legacy `resume_session_id` alias permanently (dual-key parse; the canonical key
  wins when both appear). Both makai emitters (TS SDK and Zig serializer) send the
  two keys with the same value so pre-rename servers (which read only the alias)
  keep binding the caller's id; the alias emission is transitional and drops once
  pre-rename servers are gone. A canonical-only emitter against a pre-rename server
  degrades to the §13.1 id-omitting exception.

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
- Client behavior on interruption: retry request with full context — for idempotent workloads. An unsettled non-idempotent run (tools or other side effects) has an UNKNOWN outcome: with no run identity, reconciliation, or replay (§13.5) a client cannot prove the first attempt did not execute, so automatic retry may duplicate side effects; such callers must decide under at-least-once semantics (§13.4.6).
- Session-level replay/resume is deferred to a future revision; §13.5 defines the load/resume/replay trichotomy these deferrals are stated against.

## 13. Session Lifecycle & Frame Routing (V1.1)

Status: normative revision. Amends §6, §6.1, and §12. Originally docs-only (no
wire-format changes); since amended by the #198 rename — the `agent_start` payload key
`resume_session_id` → `session_id` with permanent dual-key parse compat — the
section's one wire change. Vocabulary is aligned to the Open Agent Protocol (OAP)
agent-control core — the
full OAP term → makai construct mapping is the deviations ledger in
[`docs/oap-alignment.md`](oap-alignment.md); the governing OAP references are
Decision 0001 ("Agent-Control v0.1 Executable Core") and the cross-repo coordination
issue lsm/open-agent-protocol#3 (makai is queued as OAP adapter #3).

This section defines what a session *is*. Makai issues #198, #199 (fixed by PR #200),
#201, and #202 all trace to the V1 spec never defining session semantics.

Rules below are tagged:

- `[current]` — codifies behavior verified on `main` as of this revision;
- `[planned]` — normative requirement whose implementation is tracked in the listed
  makai issue; until it lands, the `[current]` behavior remains in force.

### 13.1 Typed Identity Domains (Normative)

Makai agent-protocol identifiers are opaque strings in distinct semantic domains.
Following OAP Decision 0001, identifiers in different domains are not interchangeable,
even when their string values happen to coincide.

| Domain | Wire format | Carried by | Role |
| --- | --- | --- | --- |
| Session | 21-char alphanumeric NanoID (`[A-Za-z0-9]{21}`, §3.1) | envelope `session_id` on every agent frame; payload `session_id` on `agent_start`/`agent_message`/`agent_stop`/`agent_status` (`resume_session_id` on `agent_start` is a legacy alias — see rules) | Session-container key and frame-correlation scope ONLY (see the `agent_start` id-allocation exception below) |
| Envelope message | 26-char Crockford Base32 ULID (§3.1) | envelope `message_id`; envelope `in_reply_to` | Per-envelope identity; request/reply correlation |
| Ordering | `u64` | envelope `sequence` | Per-direction, per-session ALLOCATION counter — never an identity; observed wire order can interleave and echo/validation frames do not participate (see rules) |
| Provider stream / auth flow | 26-char ULID | `stream_id` / `flow_id` on provider/auth frames of the same connection | Adjacent protocol domains; never valid agent-domain identifiers despite the shared format |
| Tool call | provider-originated string | payload `tool_call_id` on `tool_execute`/`tool_result` and tool-execution events | Correlates one in-flight tool execution; uniqueness not enforced session-wide (see rules) |

Rules:

- `session_id` is a correlation key and the server-side session-container key. It is
  NOT a resume, replay, or persistence handle (§13.5); treating it as one is the error
  makai #198 exists to correct. #198 also renamed the `agent_start` payload key
  `resume_session_id` → `session_id` (a wire change landing on the semantics this
  section defined), unifying payload vocabulary with
  `agent_message`/`agent_stop`/`agent_status`. The canonical `agent_start` payload key
  is `session_id` `[current]`; the server accepts `resume_session_id` as a permanent
  legacy alias carrying the same value, and when both keys appear the canonical one
  wins. The envelope-agreement rule below compares the effective payload id whichever
  key carried it. During the transition makai's own emitters (the TS SDK and the
  Zig serializer/client) additionally emit the legacy alias with the SAME value: a
  pre-rename server cannot read the canonical key, and without the alias it would
  treat the payload id as absent and generate its own id (the id-omitting exception
  below) — the TS SDK does not adopt a generated id and would then fail every
  subsequent session-scoped frame with `agent_not_found`, and while the Zig
  `AgentProtocolClient` does adopt the returned id, its per-session sequence counter
  stays keyed under the sent id, so the first `agent_message` under the adopted id
  carries sequence 1 where the server expects 2 (`invalid_request`). The alias keeps
  old servers binding the caller's id on both clients while dual-key servers take
  the canonical value; the alias emission drops once pre-rename servers are gone. A
  canonical-only emitter against a pre-rename server degrades to that same
  id-omitting exception; such consumers MUST adopt the id from `agent_started`
  (rule below) and re-key their per-session sequence state to it.
- `in_reply_to` references the request envelope's `message_id` ONLY (OAP Decision 0001
  rule). It never references a session id, stream id, flow id, or payload-level id,
  even where values coincide. Synchronous server replies (`agent_started`,
  `agent_stopped`, `ack`, `nack`, `agent_error` from request validation,
  `session_info`, `pong`, `tool_list_response`) set `in_reply_to`; a queued
  `models_response` is likewise request-correlated (`in_reply_to` names its
  `models_request`) though delivered asynchronously after its `ack`; asynchronous
  run output (`agent_event`, `agent_result`, settlement `agent_error`,
  `tool_execute`) carries no `in_reply_to` and is session-scoped (§13.3).
- `sequence` is scoped per session AND per direction: the client's inbound counter and
  the server's outbound counter are independent.
  Inbound `[current]`: `agent_start` MUST carry sequence 1. Each ACCEPTED
  `agent_message` advances the expected counter by one; an accepted `agent_stop`
  consumes the counter together with the session (the entry is removed). Rejected
  requests (`invalid_request`, `agent_busy`, `agent_not_found`) never advance it — in
  particular, an `agent_message` rejected `agent_busy` against a `.processing` session
  leaves the counter unchanged, and the client retries with the same expected value.
  Zig client sequence discipline `[current — #210 gap 7, slices 1–4 of the
  client sequence-control series: S1 #216, S2a #218, S2b-1 #226, S2b-2 #227,
  S2b-3 #231, S3 #232, S4 #239]`: the `AgentProtocolClient` mirrors the
  server's counter optimistically — the tracker advances at SEND, before the
  outcome is known — and reconciles on evidence. A CORRELATED rejection (an
  `agent_error` OR `nack` whose `in_reply_to` names the client's own send)
  rolls the
  tracker back, so a corrected retry reuses the sequence (every outstanding
  send is tracked and the rollback floor carries every still-unresolved
  MESSAGE record's pre-send tracker and sequence — the counter the server
  holds in the all-rejected world, so an older unresolved send's floor is
  never lost to a younger send's rejection; a pending START's floor is
  never taken, since a non-session-gone rejection proves the counter is
  past it); a correlated `agent_busy` floors to EXACTLY the rejected
  sequence instead — the server validates the inbound sequence before the
  processing state, so a busy answer proves every lower sequence was
  consumed; a correlated `agent_not_found` (or `session_expired`)
  drops the counter state instead, since the session is gone server-side.
  Stop sends never advance the tracker: an accepted stop consumes the
  counter with the session, and a rejected stop leaves the expected value
  in place for its retry; stops are tracked requests too, so a
  session-gone answer discovered through a stop drops the counter state
  for the re-registration. An explicit STOP RESYNCS the tracker to its
  caller-supplied value without advancing past it, and its correlated
  rejection undoes the resync — when the tracker still holds the stop's
  value (a pending mirror counts as the owner of that value only while
  it is LIVE — its own write was the LAST tracker write of any kind:
  another send's mirror or resync, or a reconciliation's floor or
  restore, supersedes it, so ownership follows write ordering, never
  value equality; the undo applies only to a stop that actually MOVED
  the tracker — an ordinary stop, or an explicit one resynced onto the
  current value, made no move, and its rejection only lifts the tracker
  to the proven floor — and a stop carrying the tracker's current value
  writes nothing at all, asserting no newer counter state that could
  supersede a pending mirror's ownership) — to the pre-resync tracker CAPPED by the still-pending messages'
  floor (the pre-resync value may itself be an unresolved send's
  optimistic mirror), max the proven floor (below); the refuted resync's
  revert bound is durably recorded — an allocation failure surfaces
  rather than being forgotten, or a later stop's rejection would restore
  a prior this resync had contaminated; wherever the undo is
  skipped, a tracker sitting below the proven floor (a stop's own
  duplicate_sequence step included) is still raised to it. A settlement retires
  the settled run's own message record (the oldest pending message),
  keeping a long-lived session's records bounded by its unresolved sends
  rather than its history; the settlement also raises the proven floor to
  the MINIMUM pending-message sequence + 1 — the settled run is only
  KNOWN to be one of the pending messages (the insertion-order
  attribution is a heuristic; agent_result carries no run identity,
  §13.3.2 — residual `RESIDUAL-5` in the ledger's residual catalogue), so the
  heuristically retired record's own sequence proves
  nothing — and the tracker follows the floor, restoring progress a
  stale rewind (a delayed busy answer's parity floor for a retry that
  was actually accepted) had pulled below.
  Explicit-sequence sends `[current — #210 gap 7]`:
  `sendAgentMessageWithSequence` and `sendAgentStopWithSequence` carry a
  caller-supplied counter value (recovery paths that know the server's
  state are not forced to guess);
  the tracker mirrors it optimistically but restores its PRE-SEND state
  when the pre-wire bookkeeping fails (nothing reached the wire — the
  value AND its write epoch, so a still-pending mirror's ownership
  survives the rollback),
  `maxInt(u64)` is rejected before any mutation for the MESSAGE variant
  (a start against a tracker already at the maximum is rejected the same
  way; a STOP may carry the maximum itself — a stop never computes
  `sequence + 1`, so the ceiling teardown is sendable), and a
  correlated rejection restores the record's pre-send tracker rather
  than the send's own optimistic regression (a backward explicit send's
  regression must not pin the tracker below the server) — except
  `agent_busy`: the server validates the sequence before the processing
  state, so a busy answer proves the sequence MATCHED and the tracker
  rests at exactly the rejected sequence (a busy-rejected explicit send
  retries its own sequence, never the stale pre-send tracker).
  A correlated nack rejects a request exactly like a correlated
  `agent_error`, while nacks for NON-run requests (models, tool_list,
  ping, status) stay request-scoped and are dropped. A
  `duplicate_sequence` answer is duplicate evidence proving exactly ONE
  step — the server's counter is past the sent sequence, never that it
  reached any optimistic value derived from unresolved sends: a RETRY of
  a still-unresolved message (same sequence AND payload digest, via
  `sendAgentMessageWithSequence`; an empty `options_json` digests
  identically to absence — the wire treats them the same) retires
  silently with the tracker restored to `sequence + 1` MAX the session's
  proven floor (see below), while a
  mismatched payload, a competing different-payload record at the
  sequence, a non-retry MESSAGE, or an ancestry that was never
  admissible — every same-payload copy was sent below an
  already-proven floor (the protocol's INTRINSIC post-start floor
  included: a session's sequence 1 is consumed by its agent_start, so
  a MESSAGE at 1 is never admissible even when the started reply was
  lost), so nothing could have run or settled and the
  duplicate must surface however the retry bit reads (the check judges
  the SOURCE's send-time floor, min-inherited down the retry chain: a
  retry recorded after the floor rose past the sequence keeps the
  silent path while its source predates the floor, and a SETTLED
  source demonstrably ran the payload there, outranking the floor
  heuristic) keeps the proven step
  (`sequence + 1`)
  and SURFACES through the error bookkeeping — nothing of that envelope
  will ever settle; a START duplicate runs the ordinary rejection
  rollback instead and surfaces likewise, while a STOP duplicate still
  records its counter-past proof (the proven step `sequence + 1`) before
  running the ordinary stop-rejection path and surfacing. The silent
  path's retry
  provenance is a lattice over the pending records, not the send-time bit
  alone: a record's retry bit derives from an EARLIER same-sequence
  same-payload record whose own source chain is intact, and every
  reconciliation that removes a record re-derives the sequence's records
  against the current set — DIRECTIONALLY (two retries of the same payload
  cannot vouch for each other; only an earlier record is a source),
  TRANSITIVELY (rejecting a source breaks its whole same-payload chain,
  masked ancestry included — a record whose retry bit a then-present
  competitor masked to false still carries its ancestry, and the chain
  breaks when that ancestry dies), and COMPETING-PAYLOAD-GATED (a
  different-payload record still pending at the sequence disqualifies the
  silent path and blocks re-qualification; the retirement of such a
  competitor RE-QUALIFIES the other payloads' retries it had masked). A
  non-retry duplicate retirement breaks its same-payload descendants the
  same way — the retired envelope never ran either. A settlement
  reconciles its sequence's provenance in two asymmetric moves (the
  oldest-record attribution is a heuristic — `agent_result` carries no run
  identity, §13.3.2): a GRANTED settled justification, only when
  UNAMBIGUOUS — every pending message record shares the retired record's
  sequence and payload, so whichever record the run belonged to, it
  demonstrably ran THAT payload at THAT sequence — sets the remaining
  same-pair records' retry bits TRUE (overriding a competitor mask,
  superseding an earlier broken marker, standing through later
  re-derivations, and propagating to later same-payload records recorded
  while a settled-flagged record remains pending; the answer-time
  competing check still gates while the competitor remains); and an
  attribution-trusting BREAK marks the remaining different-payload records
  at the settled sequence provenance-broken — the settled run consumed the
  sequence, so those payloads never ran there (under a mis-attribution
  the break errs toward a surfaced duplicate, the self-correcting
  direction, where a mis-granted settled bit would silently swallow a
  failure). The client keeps a monotone PROVEN FLOOR per session: every
  reconciliation that establishes a sound lower bound — a busy answer's
  exact parity, an all-rejected floor, a duplicate answer's proven step
  (for a message OR a tracked stop), a settlement's minimum-candidate
  step, a stop-undo's capped restore, an accepted start's consumed
  sequence — maxes it, and every later floor or restore maxes with it
  (the counter never moves backward, so a bound once proven stays
  proven; optimistic mirrors from unresolved sends never participate —
  an unresolved stop's resync is caller-asserted, and message-rejection
  floors carry the stop's PRE-RESEND prior so the caller's value cannot
  be laundered into the floor through later snapshots). Recording a
  floor propagates allocation failures — a bound is never silently
  dropped once its envelope has been accepted for processing, since a
  forgotten floor can wedge the tracker on a consumed sequence; the
  tracker's own rise to the floor stays best-effort, healing through
  duplicate evidence — and each reconciliation's floor is stored BEFORE the
  matched pending record retires, so a storage failure leaves the
  envelope retryable instead of stranded with the refuted optimistic
  state). An accepted start additionally INVALIDATES
  pending message records below its seeded floor: the start
  demonstrably consumed those sequences, so no same-payload source
  could have run — records sent before the started reply was processed
  snapshot the older floor and would otherwise stay silently eligible
  for a failure whose settlement can never arrive. A higher true
  counter than the restore is reached one
  step per round trip (the next send at the restored value is answered
  `duplicate_sequence` in turn, and as a same-payload retry it retires
  silently). The pending-record lifecycle and stale-reply guards, the
  bounded stop probe for unknown outcomes (§13.4.1), and the TUI teardown
  integration — drain-before-sync in the remote pump, the exclusive-id
  registration whose admission is the §6.1 evidence that lets the bounded
  teardown driver pump an in-flight stop probe to settlement, the
  ambiguous-write reconciliation that stops the old registration instead of
  resending it, and the session-gone identity clear — are landed
  (`[current — #210 gap 7]`). The probe's admission gate and the teardown's
  backlog drain carry residuals `RESIDUAL-1` and `RESIDUAL-4` in the ledger's
  residual catalogue.
  `agent_status`, `ping`, `tool_list`, `models_request`, and `goodbye` never
  consume inbound sequence. `goodbye` is accepted silently: it neither tears down a
  session nor produces a reply — the session remains usable afterward (only the
  stdio host's EOF/exit logic ends the process). `tool_result` frames are
  intercepted by the stdio host before the agent
  protocol and never consume agent inbound sequence numbers.
  Outbound `[current]`: emitted frames come in two classes. Allocated frames
  (`agent_started`, `agent_stopped`, `ack`, `nack`, `models_response`, `agent_event`,
  `agent_result`, settlement `agent_error`, `tool_execute`) draw from one monotonic
  per-session counter — describing ALLOCATION order, not necessarily observed wire
  order: when several requests are consumed in one input batch, their synchronous
  replies are written before the outbox flushes queued responses, so the peer can
  observe allocated frames out of counter order (e.g. `ack(1), ack(3),
  models_response(2), models_response(4)`); consumers MUST NOT detect gaps or
  reorder from observed allocated-frame sequences alone. The counter is scoped to
  the session-container REGISTRATION, not the id string: `agent_start` initializes
  the counter to 0 (overwriting any numbers the id consumed for `models_request`s
  issued before the start), and an id re-registered after a stop restarts it, so
  sequence values may repeat across registrations of the same id. Consumers MUST
  treat the outbound counter as per-registration. `[current — #210 gap 5]` a
  failed counter update now propagates instead of being swallowed: the frame
  whose publication failed is not built, so allocated sequences remain
  monotonic (a retried publication may burn the already-recorded value and
  leave a GAP — gaps are already possible across allocated frames and MUST
  NOT be treated as loss). Echo
  replies (`session_info`, `pong`, `tool_list_response`) copy the
  request's inbound sequence verbatim — a correlation echo, not an ordering
  allocation — and request-validation `agent_error` envelopes carry `sequence: 0`
  (outside the ordering domain). Consumers MUST NOT order echo replies against
  allocated frames by sequence. `[current — #204 decision (b)]` the echo is kept
  permanently: a reply's sequence names the request it answers, which consumers
  may rely on for correlation without inspecting `in_reply_to`; allocating echo
  replies from the per-session counter (#204 option (a)) was considered and
  rejected as a breaking change for echo-relying consumers that would buy only
  the cross-class monotonicity the rule above already forbids depending on.
  Recorded as a permanent deviation in the deviations ledger
  ([`oap-alignment.md`](oap-alignment.md)).
- When a scoped identifier appears in both the envelope and the payload of one frame,
  the values MUST agree (OAP rule). On `agent_start` — when the payload id is
  present — the envelope `session_id` and the payload key select the same
  session-container key (the SDK always sends them equal). Exception
  `[current]`: when `agent_start` OMITS the payload id, the request envelope's
  `session_id` is ignored — the server generates the container id and returns it in
  `agent_started` (both its envelope `session_id` and payload). Consumers MUST adopt
  the id from `agent_started` and MUST NOT assume their request envelope id became
  the session key. Because `agent_started` then travels under the GENERATED id, a
  consumer waiting on an exact session-id route (`nextFrameForSession`-style)
  cannot receive it: such consumers MUST NOT omit the payload id (send envelope and
  payload ids equal) — id-omitting starts are usable only with an untargeted
  waiter or once `in_reply_to`-aware routing lands (#201); otherwise the reply is
  unreachable and the generated session leaks registered. Enforcement of the
  agreement rule is
  `[current — #204]`: every session-scoped handler (`agent_start` when the payload
  id is present — the effective payload id, whichever key (`session_id` or the
  legacy `resume_session_id` alias) carried it — `agent_message`, `agent_stop`,
  `agent_status`) compares the two
  ids FIRST and rejects a mismatch with a request-correlated `invalid_request`
  before any lookup, mutation, removal, or cancellation — the expected inbound
  sequence is not consumed and the idleness clock is not touched. The stdio host
  applies the same rule to its stop interception: a stop whose envelope and
  payload ids disagree is not a validated stop, so the host neither cancels the
  payload-id session's run nor discards its tool-bridge state on its own.
- `tool_call_id` correlation is scoped to concurrently in-flight calls. Ids originate
  from provider output and the server keeps no session-wide registry: a provider MAY
  reuse a value in a later turn or a later run of the same multi-message session.
  Consumers and adapters MUST NOT key tool history by bare `tool_call_id`. Reuse
  hazard closed for in-flight waits `[current — #210]`: the stdio interception
  correlates a `tool_result` against the CURRENT outstanding `tool_execute` — the
  in-flight key records the published request's `message_id`, and only a reply
  whose `in_reply_to` names it settles the wait. A delayed or retried result from
  an earlier execution of a reused id (wrong `in_reply_to`), an uncorrelated reply
  (no `in_reply_to`), and an unsolicited or already-consumed reply (no in-flight
  key) are all DISCARDED — the interception rejects the frame and the host emits
  its `unknown_envelope` runtime error, so a stale result can no longer complete a
  later call reusing the id while its real reply is dropped. History beyond the
  in-flight window remains uncorrelated (adapters still MUST NOT key tool history
  by bare `tool_call_id`).

### 13.2 Session Lifecycle & Ownership (Normative)

A session is a server-side, in-memory container of agent execution state (status,
resolved model, config, system prompt, message counter, timestamps) keyed by its
session id. It is created by `agent_start`, destroyed by `agent_stop` or by
server eviction (rule 6), and holds no transcript and no persistence.

1. Creation `[current]`: `agent_start` allocates the session id — the payload id when
   supplied, else a server-generated NanoID — and registers the container in state
   `.ready`. A start naming an id already registered is rejected with `agent_busy`
   ("session already exists").
2. Ownership `[current]`: sessions are owned by the connection that created them. The
   stdio host is process-per-connection: one agent protocol server per process, and
   sessions die with the process. No v1 host shares or persists sessions across
   connections.
3. Multi-message by design `[current]`: a successful settlement returns the session to
   `.ready`; subsequent `agent_message` frames on the same id are accepted
   with the next expected sequence and increment the message counter. A
   loop-internal failure (settlement via the `agent_error` envelope, §13.4.2) marks
   the session `.error` — it stays registered, and only `.processing` blocks a
   further message, so a failed session may still be reused or stopped. A
   provider-originated failure (§13.4.2) settles through `agent_result` and leaves
   the session `.ready` despite the error-valued `stop_reason` — `agent_status`
   after such a failure reports `.ready`, not `.error`. One session per run is a
   client convention (the TS SDK pattern per §6.1), not a server limitation.
4. One active run per session `[current]`: an `agent_message` against a session in
   `.processing` is rejected with `agent_busy` ("session already processing a
   message"). V1 defines no queueing, steering, or side-channel delivery.
5. Teardown `[current, extends §6.1]`: `agent_stop` is the only CLIENT-initiated
   session removal path (server-initiated idle eviction is rule 6); a validated stop
   also cancels the session's in-flight run and discards its pending tool work.
   The §6.1 client mandate (stop on terminal/error/abandon, bounded by ownership)
   is normative for one-run-per-session clients.
6. Eviction rights `[current — #202]`: servers evict sessions idle longer than
   a configurable TTL, with these semantics:
   - Idle TTL `[current]`: the server evicts sessions idle longer than a
     configurable TTL with a defined non-zero default (30 minutes;
     `AgentProtocolServer.Options.session_idle_ttl_ms`, `0` disables; the stdio
     host exposes it as `MAKAI_AGENT_SESSION_IDLE_TTL_MS`). Idleness is measured
     from the session's last activity — inbound (`agent_message` acceptance,
     `agent_status` poll; stop removes the session outright) OR server-side run
     activity (`agent_event` or settlement publication) — and a session with an
     in-flight run (status `.processing`) is NEVER idle, so a long-running turn
     or tool execution cannot be evicted out from under its run. Settlement
     publication resets the idle clock (it is the final activity of a completed
     run): a settled multi-message session is idle-but-alive with a full TTL
     ahead of it, by design (rule 3) — settlement never evicts; it only starts
     the idle interval.
   - Resource caps `[planned — optional]`: a server MAY additionally bound
     registered sessions and evict least-recently-active entries. Cap eviction,
     like the TTL, selects ONLY among sessions without in-flight runs — a
     session with a live run is never cap-evicted; if no idle candidate exists,
     the server surfaces the pressure by rejecting new `agent_start`s
     (`agent_busy` or a resource error) rather than cancelling live work. Not
     implemented in v1.1. Process-per-connection hosting scopes sessions to one
     client connection (ownership and lifetime end with the process) but does
     NOT bound their count: a single client may register arbitrarily many
     distinct sessions within the TTL, so the cap remains the (unimplemented)
     backstop for that growth — the TTL bounds how long leaked sessions live,
     not how many can accumulate.
   - An evicted session's next session-scoped request other than `agent_start`
     (`agent_message`, `agent_stop`, `agent_status`) receives the existing
     `agent_not_found` error ("session not found") — identical to an unknown or
     already-stopped id; eviction MUST NOT be distinguishable from stop by error
     code. `agent_start` on an unregistered id (evicted, stopped, or never created)
     creates a fresh container per §13.5.2 — clients re-supply full context (§12).
   - If an eviction lands on a session whose run admission raced the eviction
     decision (the run is in flight at removal), the eviction MUST cancel that run
     (same semantics as `agent_stop`), and this race MUST be closed server-side:
     by #204's generation/tombstone tokens, or by deferring removal or
     re-registration of the id until the cancelled run's publications have ceased.
     The client-side drain discipline from §6.1 does NOT apply here — the client
     cannot observe the eviction in time. `[current]` The shipped TTL eviction
     closes the race by construction: admission sets `.processing` synchronously
     before accepting, admission and the sweep run serialized on the host's
     single pump thread, and the stdio run pump already cancels any run whose
     session disappeared (the `agent_stop` path) with post-removal publications
     surfacing as swallowed `SessionNotFound` no-ops — so a session is either
     `.processing` (never selected for eviction) or removed before its message
     arrives (no run admitted). Multi-threaded hosts must preserve this
     serialization before sweeping; the registration-generation counter
     (`[current — #204]`, §13.4.5) closes the stopped-or-evicted-id reuse race
     for run publications — downstream-buffered frames of the old registration
     remain attributable to a re-registered id until drained (§6.1).
     Idleness is measured on the host's monotonic clock — wall-clock
     adjustments (NTP steps, snapshot restores) neither evict fresh sessions
     nor strand stale ones; the wall-clock `updated_at` remains
     protocol-reporting only.
7. Disconnect `[current for the stdio host]`: the process exits when stdin closes and
   no runs, provider streams, or auth flows remain active, bounding session lifetime
   by the connection. Disconnect does not cancel provider work in V1: a run
   executing against a provider is pumped to completion and its settlement frames
   are still drained to stdout — stdin and stdout are independent pipes, so a
   client that closed only its write side but keeps reading still receives them
   (lost only when the read side is gone), and only until the run needs client
   input: a provider turn that returns `stop_reason = tool_use` after EOF moves the
   run into the tool-waiting case when the call reaches the distributed executor
   (unknown tools, invalid arguments, and approval-required calls synthesize local
   results and the loop continues). The tool-waiting case is EOF-cancelled
   `[current — #210]`: when the host observes stdin EOF it latches the connection
   disconnected, and every distributed tool wait — one already parked or one a
   post-EOF turn reaches — fails promptly with a typed error instead of polling
   forever (the tool host IS the disconnected client; a `tool_result` delivered
   before EOF wins its wait). A run whose wait failed on the latch settles through
   the failure pair (a settlement `agent_error` carrying
   `tool_execution_error` and a disconnect message — EOF before settlement is
   failure, never success), pending tool requests are dropped unpublished, and the
   host loop sees the run go idle so the process drains and exits instead of
   staying alive indefinitely. Future multi-connection hosts
   MUST scope sessions to their owning connection (rule 2) and evict on disconnect
   (beyond the idle TTL of rule 6; per-connection ownership is not built yet).

### 13.3 Frame Routing (Normative)

1. Request-correlated delivery `[current — #201]`: a reply frame carrying
   `in_reply_to` MUST be delivered to the waiter whose outstanding request's
   `message_id` equals that `in_reply_to` — not merely to any waiter on the session.
   The server sets `in_reply_to` on all synchronous replies; the TS transport
   implements the rule via the `correlate` wait option on
   `nextFrameForStream`/`nextFrameForSession`: a wait registered with
   `correlate: M` receives frames whose `in_reply_to` equals `M` (delivered
   promptly even while the waiter is queued behind the transport read lock), a
   frame replying to another request is parked for its owner — on that
   request's reply queue when registered, or on the shared route with its
   `in_reply_to` recorded (claimable by the owner's next correlated wait,
   skipped by foreign correlated waiters, visible to uncorrelated waiters)
   during the owner's between-waits gap — and frames without `in_reply_to`
   keep stream/session-routed behavior. A `repliesOnly` correlated wait
   additionally parks uncorrelated frames instead of consuming them. The SDK
   registers each attempt's `agent_start` `message_id` for its frame waits —
   replies-only until the start is accepted (a pre-acceptance duplicate owns
   nothing uncorrelated on the route), then the `agent_message` `message_id`
   once sent — and additionally rejects a pre-acceptance `agent_started`
   whose `in_reply_to` names a different request. Re-routing never targets a
   queue the re-routing waiter itself dequeues from, so a shared route cannot
   spin (SDK-layer re-enqueueing remains a non-fix).
2. Session-scoped delivery `[current]`: asynchronous run output (`agent_event`,
   `agent_result`, settlement `agent_error`, `tool_execute`) carries no `in_reply_to`
   and is delivered on the session's route. Rule §13.2.4 (one active run per session)
   keeps session scope unambiguous for run output.
3. Concurrent calls on one explicit session id `[current — #201]`: two
   overlapping calls sharing one consumer-supplied session id share one frame route
   and MUST fail rather than interleave: the server rejects the duplicate start with
   `agent_busy` ("session already exists") and a message against the processing
   session with `agent_busy` ("session already processing a message"). A client that
   receives `agent_busy` MUST treat the attempt as rejected and MUST NOT stop the
   session (it is not the attempt's to stop — §6.1). With rule 1's correlated
   delivery, each call receives its own start reply: the duplicate's `agent_busy`
   rejection reaches it promptly (no response timeout), and the established call
   neither consumes that rejection after acceptance (which tore the legitimate
   session down — cancelling the live run) nor loses its `agent_started` to the
   duplicate (which let the wrong request submit its `agent_message` under the
   session). The SDK's pre-acceptance `in_reply_to` skips remain as defense for
   unmatched-reply delivery.
4. Tool side channel `[current]`: `tool_execute` is delivered on the session route;
   `tool_result` replies carry `in_reply_to` referencing the `tool_execute`
   `message_id` but are intercepted by the stdio host before the agent protocol
   (§13.1 sequence rule) and never appear on the session route. The interception
   CORRELATES the reply `[current — #210]`: only a `tool_result` whose
   `in_reply_to` names the current outstanding `tool_execute` for the
   `(session_id, tool_call_id)` settles the wait (§13.1); anything else is
   discarded as an unknown observation.

### 13.4 Admission, Settlement, and the Single Terminal Arbiter (Normative)

1. Admission `[current]`: a run is admitted when the server ACCEPTS an
   `agent_message` (after `agent_started`) and enqueues it for execution — writing
   the frame alone is not admission. A message rejected for an unknown session
   (`agent_not_found`), an out-of-order sequence (`invalid_request`), or a
   `.processing` session (`agent_busy`) produces a request-correlated validation
   `agent_error` and enqueues nothing; a rejected submission MUST be treated as
   non-admission — an adapter that records it as accepted would wait for a
   settlement that can never arrive. Acceptance has no positive receipt: it is
   observable only through subsequent run output — and that output proves
   acceptance only for a caller with an EXCLUSIVE, quiescent session route; on a
   shared or recently reused id, run output is session-scoped and uncorrelated
   (§13.3.2), so a caller whose `agent_message` was rejected can lose its
   validation error and consume another run's output instead — or —
   probabilistically — the continued absence of a correlated rejection (the
   receipt-less admission is a ledger deviation). Silence is NOT proof of acceptance: an allocation failure
   inside the server's message-acceptance path (duplicating the message, updating
   the expected sequence, or enqueueing) propagates without a correlated
   rejection, so the client sees an unscoped runtime error or nothing at all;
   clients MUST bound their wait with a response timeout regardless and treat it
   as an unknown outcome (§13.4.6). Cleanup sequencing for that unknown outcome
   MUST probe both possible counter states — a timeout does not prove the
   acceptance path failed: the server may have accepted and advanced (a slow
   provider or any documented publication loss delays output past the timeout),
   or the acceptance may have failed with the counter rolled back to its
   PRE-SEND value. A cleanup stop therefore tries the pre-send sequence and, if
   rejected with a correlated `invalid_request`, the post-send value; acceptance
   at either settles cleanup. The tracker advances before the outcome is known,
   so a cleanup stop sent only at the advanced value fails in the rolled-back
   case and leaks the owned session indefinitely; a probing client instead walks
   a bounded, DISCRETE, ascending candidate set of the counter states its
   unresolved sends can still occupy — the floor (the lowest such state: the
   minimum sequence and pre-send value across the unresolved `agent_message`
   sends and the tracker, raised to the session's proven floor), one past each
   unresolved message's sequence, every tracked send's pre-send high-water, and
   the tracker. The set is never a dense interval: long-lived settled traffic
   can leave the true counter far above the floor, and sweeping every
   intervening integer would outlive any bounded teardown driver. Each
   correlated `invalid_request` advances to the next candidate — one stop per
   candidate — `agent_not_found` or `session_expired` ends the probe as
   session-gone, and exhausting the set retires it; probe replies are cleanup
   mechanics and MUST NOT surface as run errors. Probing requires §6.1
   ownership evidence: an exclusive client-generated id whose
   request-correlated `agent_started` this client observed. Without that
   evidence, or with no recorded `agent_message` whose outcome is unresolved, a
   client MUST send nothing and leak the registration to the idle TTL rather
   than risk stopping a foreign session (`[current — #210 gap 7]`). The probe's
   admission gate cannot prove current-registration ownership (`RESIDUAL-1`),
   and its post-probe drain cannot attribute parked frames (`RESIDUAL-4`) — see
   the ledger's residual catalogue. A start
   rejected before admission
   (`agent_busy`, invalid sequence, `nack`) never admits. Admission is not
   settlement.
2. Settlement `[current]`: exactly one settlement frame settles an admitted run
   that reaches its own outcome — a run cancelled by `agent_stop` produces no run
   settlement frame at all (§13.4.4):
   - success: the `agent_result` frame — the ONLY agent-protocol settlement
     frame. (The TypeScript SDK additionally accepts provider-shaped
     `result`/`complete_response` frames as a non-protocol compatibility fallback
     on the shared transport; those belong to the provider protocol and are never
     emitted by the agent server — the Zig agent client cannot parse them, so
     implementations MUST NOT emit them on the agent surface.) This is the
     settlement frame for BOTH consumption modes: the SDK's
     `stream()` projects the `agent_result` frame into its terminal `agent_end` event
     and terminates there — it does not wait for the server's trailing `agent_end`
     frame, which is drained per §6.1. The server publishes `agent_result` BEFORE the
     trailing `agent_end` event frame; the trailing frame is an aggregate restatement
     of the same settlement for event-stream consumers, not a second settlement.
   - failure comes in two shapes, classified per shape: a settlement `agent_error`
     frame IS a failure by frame type (its payload carries only `code` and
     `message` — no `stop_reason`); an `agent_result` frame must be classified by
     its payload (`stop_reason`), because the same frame type settles both
     successes and provider-originated failures:
     - loop-internal failures (non-OOM run-start failure, agent-run stream error):
       the failure pair — an `agent_event` carrying the terminal `error` event
       (§3.5's one-terminal-error rule) followed by the settlement `agent_error`
       envelope — is ONE settlement. The `agent_error` envelope is the settlement
       frame; the `agent_event` is its event-stream projection. Consumers terminate
       on the first-delivered frame of the pair and MUST NOT count the pair as two
       settlements. An out-of-memory run-start failure is the exception: it
       propagates unbound (the pending-run pump returns without publishing),
       leaving the admitted message consumed, the session in `.processing`, and no
       settlement frame at all — the host itself is failing. A consumer that
       terminates on the FIRST frame of the pair MUST drain (or otherwise discard
       by correlation/generation) the remaining projection before the session id
       is reused: the queued settlement `agent_error` carries no `in_reply_to`, so
       an immediate same-id follow-up consumes it — under §13.3.1's pre-acceptance
       routing it is parked through the pre-start window and then claimed by the
       follow-up's first post-acceptance wait — treats it as its own rejection,
       and can stop the newly registered session (`[current — #205]`: the TS
       SDK's `run()` tears the failure-pair termination down with a bounded
       quiescent drain — stop, then consume the settlement — before surfacing
       the error, and `stream()` already drained via its terminal teardown;
       the residual race for a settlement arriving after the bounded drain
       remains, as in §13.4.5 — residual `RESIDUAL-3`).
       Publication failures are transactional `[current — #210 gap 5]` —
       settle-or-propagate exactly once through every publication path, with
       the failure surfacing as the host's typed runtime error frame rather
       than vanishing:
       - RESULT publication: the run records settlement progress; a failed
         `agent_result` publication keeps the run queued and propagates, the
         next pump retries the frame, and the trailing `agent_end` projection
         publishes ONLY after the frame commits — a failed result publication
         can no longer produce a false-success projection. The session's
         status flip rides the append (commit-then-flip): while the result
         publication is pending the session stays `.processing`, so a
         follow-up `agent_message` is rejected `agent_busy` at admission
         (clean non-admission) rather than accepted and later converted into
         an `AgentBusy` internal-error settlement by the retained run. A run
         whose settlement frame committed no longer occupies the session's
         one-active-run slot while it retries the trailing projection: the
         next `agent_message` is admitted (the late trailing `agent_end` is
         the §13.4.3 stale-`agent_end` interleave consumers drain per §6.1).
       - the failure pair: the leading error-event projection and the
         settlement envelope each record their commitment; a failure before
         the projection retries the pair whole; a failure BETWEEN them (the
         projection delivered, the envelope not) retries ONLY the envelope —
         the projection is never re-emitted, and the envelope is never
         abandoned after its projection because it is the frame clients
         settle on (the Zig `AgentProtocolClient` marks a session complete
         only on `agent_error`/`agent_result`/`agent_stopped`; a bare
         `agent_event` is merely queued). The session's `.error` flip rides
         the envelope's commit, so a pair being published or retried keeps
         the session non-admissible exactly like a pending result.
       - a stream that completed with NEITHER a result nor a recoverable
         error — `completeWithError` marks the stream done even when copying
         its error message hits OOM, leaving no outcome to publish and none
         that a retry could produce — settles through the failure pair with
         a generic typed failure; the run is never retained on an outcome
         that cannot appear (the stdio shutdown drain waits on the run
         list).
       - ORDINARY `agent_event` frames: an event consumed from the run stream
         but not committed to the outbox (serialization or publication
         failure) cannot be reconstructed; the run is marked truncated and
         its settlement converts to the loop-internal failure pair — a
         truncated stream never settles "successfully".
       - tool-request publication: the pending request stays queued until its
         `tool_execute` envelope is committed to the outbox, so a failure
         retries instead of freeing the request under the agent thread's
         parked tool wait.
       - outbox delivery: the envelope is peeked, serialized, and written
         BEFORE being removed — a failed delivery retries the queued frame;
         the pipe write reserves data + newline before appending
         (all-or-nothing), so a retry never lands on a partial line.
       - the final stdio drain reserves its buffer slot before reading the
         pipe (buffer-before-advance): an allocation failure leaves the frame
         in the pipe for the next drain instead of dropping an
         already-delivered one.
       - the per-session outgoing-sequence counter update is no longer
         swallowed (a failed counter write propagates; two frames can no
         longer share a sequence).
       Run-START failures remain the exception `[current]`: the pending
       message is consumed before the error pair is published and no active
       run exists to resume, so a mid-pair failure there emits only the lone
       event projection, never settles, and does NOT re-emit — but the
       session is marked `.error` BEFORE the pair is published, so a
       mid-pair OOM leaves recoverable state rather than a `.processing`
       wedge: `agent_status` reports `.error` and another `agent_message` is
       permitted — recovery logic MUST NOT wait on a processing run that no
       longer exists.
     - provider-originated failures (auth, network, invalid URL): the provider turn
       converts the error into a result message with `stop_reason = "error"` and the
       provider's own `error_message` (§3.5), the loop completes normally, and the
       run settles through the SUCCESS shape — an `agent_result` frame carrying
       `stop_reason: "error"` + `error_message`, followed by the trailing
       `agent_end`. No `agent_error` envelope is emitted for these. An adapter that
       treats every `agent_result` as success will misreport these failures. This is
       §3.5's "turn fails at the provider" rule (`turn_end`/`agent_end` carry the
       error detail); §3.5's one-terminal-`error`/no-`agent_end` rule applies to the
       loop-internal shape above, not to this one.
3. Single terminal arbiter `[current]`: a run that reaches its own outcome settles
   exactly once, via result XOR error, never both — including under publication
   failure `[current — #210 gap 5]`: a failed settlement publication propagates
   (the host surfaces it as a typed runtime error frame) and is retried with the
   run's recorded progress, so no terminal frame or projection is re-published
   after committing (the run-start mid-pair exception aside, §13.4.2). Children
   settle first: pending tool work resolves and the trailing `agent_end` is
   published only after `agent_result`. Duplicate or late frames after settlement
   (e.g. a stale `agent_end` read by a follow-up run on the same id) MUST NOT
   produce a second settlement — clients drain per §6.1.
4. Cancellation is session settlement, not run settlement `[current]`: a validated
   `agent_stop` removes the session mid-run and cancels the run; the cancelled run's
   subsequent result/error publications are discarded because the session no longer
   exists. A cancelled run therefore produces NO run settlement frame — the
   `agent_stopped` reply correlated to the stop request is the client's terminal
   observation `[current exception]`: if that reply's own publication fails —
   `[current — #210 gap 5]` the reply's owned fields are built BEFORE the
   removal, and the stop's dispatch completes run cancellation and tool-bridge
   cleanup (the bridge session discard) even when the reply's serialization or
   its direct synchronous write — outside the outbox — fails, surfacing the
   failure as the host's dispatch error frame — the client still sees no
   `agent_stopped`, only that uncorrelated runtime error or a timeout, although
   teardown succeeded and no bridge memory leaks. Misattribution is
   nonetheless closed by `in_reply_to` correlation (`[current — #210]`, §13.1): a
   delayed old `tool_result` names the old `tool_execute`'s `message_id` and is
   discarded against a later same-id call.
   Makai has no run-scoped cancelled terminal (OAP
   `run.cancelled` is a ledger deviation); there is nothing for a consumer to wait
   on after `agent_stopped`.
5. Stopped-id reuse race `[current — #204]`: the cancelled run of a stopped session
   stays alive until its provider stream drains, and a new `agent_start` may
   re-register the same id before then. Server-side, the race is closed by
   REGISTRATION GENERATIONS: every registration stamps a monotonically
   increasing generation from one server-wide counter; a run binds the
   generation it was admitted under and may publish only while that generation
   is still the id's current one. A stopped or evicted id (no current
   generation) or a re-registered one (a newer generation) makes the run
   stale, and every stale publication is discarded — no run events, no
   settlement, no state mutation: the re-created container is never marked
   `.error` by the stale run's failure, its idleness clock is untouched, and
   a stale run's queued `tool_execute` requests are dropped at publication
   (the enqueuing agent thread does not observe its cancel token before
   enqueueing, so a request can land after the stop's bridge discard —
   requests carry their registration generation and publication validates
   it against the id's current one).
   The generation check also scopes the one-active-run rule (§13.2.4): a
   listed stale run no longer fails the re-created id's ADMITTED run at start
   with an `internal_error` settlement — the fresh registration's run starts
   and settles on its own. Generations close the run-to-container race for
   stopped AND evicted ids alike (eviction does not widen the race to begin
   with — it fires only after a full TTL of no activity, versus a stop's
   immediate reuse window). What generations do NOT close is the
   downstream-buffer confusion: frames the OLD registration already published
   (outbox, pipe, stdout) carry no generation on the wire, so a consumer
   attributes them to whichever registration currently occupies the id —
   clients that reuse an explicit id after a stop SHOULD still drain quiescent
   first (§6.1) or use a fresh id.
6. Transport death `[current]`: process exit before settlement is failure, never
   success — the client transport rejects the frame wait currently registered with
   it on exit (reads queued behind the transport's read lock install their waiter
   only after acquiring the lock, so they surface the death as their response
   timeout rather than a prompt rejection), and no result is fabricated for an
   unsettled run. Stdin EOF splits by run state
   (§13.2.7): a provider-executing run is pumped toward settlement and its frames
   are still drained to stdout — stdin and stdout are independent pipes, so a
   client that closed only its write side but keeps reading CAN receive its
   settlement (a delivered settlement is not a transport failure, and a client
   MUST NOT retry a run it already saw settle); the frames are lost only when the
   read side is gone or the process dies. This holds only while the run needs no
   further client input: if the in-flight provider turn returns
   `stop_reason = tool_use` after EOF AND the call reaches the distributed
   executor (a configured tool with schema-valid arguments whose approval path
   permits execution), the run transitions into the tool-waiting case below,
   which the disconnect latch then fails (see the next sentence — it settles
   through the failure pair, not silence); an unknown tool, schema-invalid
   arguments, or an
   approval-required call (the stdio host locally rejects those without a
   reachable approver) synthesizes a local error tool-result instead, the loop
   continues, and the run can still settle on stdout. A run waiting on a distributed
   `tool_result` is EOF-cancelled `[current — #210]`: the wait fails with a typed
   error on the disconnect latch, the run settles through the failure pair
   (§13.2.7 rule 7), and the process drains and exits — a half-closed client that
   keeps reading receives the failure settlement; one that is gone surfaces the
   error through transport death below. In every case an unsettled run is
   never a success. Recovery is not unconditional: makai has no run identity,
   reconciliation, or replay (§13.5), so a client cannot prove an unsettled
   attempt did not execute — if the run used tools or other non-idempotent side
   effects, retrying with full context (§12) may execute them again. Retry is the
   general recovery for idempotent workloads only; otherwise the application must
   treat the outcome as unknown (at-least-once semantics).

### 13.5 Load, Resume, and Replay Trichotomy (Normative)

Terms, aligned with OAP Decision 0001 ("resume, reconciliation, and replay are
separate"):

- **Load** (transcript reconstruction): materialize a session's message history from
  a persisted store. Inherently lossy — it reconstructs content, not the original
  event stream, run identities, or ordering.
- **Resume** (attachment without history): re-attach a client to existing execution or
  conversation state without replaying anything.
- **Replay** (canonical event replay): re-deliver the canonical event stream from a
  cursor, with explicit gap reporting when the cursor can no longer be satisfied.

Rules:

1. Makai V1 has none of the three `[current]`: streams are not resumable (§12);
   sessions hold no transcript; `session_info` exposes status and counters only; no
   persistence, cursor, or journal exists.
2. No V1 field implies any of the three `[normative]`. A session id — including the
   `agent_start` payload `session_id` (formerly misnamed `resume_session_id`; renamed
   by #198, which changed only the key, never the semantics) — is
   a correlation and container key only. Supplying a previously-used id to
   `agent_start` either creates a fresh, empty container (unknown, stopped, or
   evicted id) or is rejected `agent_busy` (registered id); it never restores state.
   History is supplied by the client in `messages` on every call.
3. Client retry artifacts are not replay `[current]`: `auto_once` auth retry may
   re-emit the failed attempt's lifecycle markers in a fresh session; that is
   client-side reconstruction across sessions, not protocol replay, and MUST NOT
   duplicate provider content or tool side effects (the SDK gates retry on no content
   yielded and no tools executed). `[current exception]` the gate is
   event-delivery-based: a `tool_execute` that was executed while its tool-lifecycle
   events were dropped by a publication failure (§13.4.2, #210 gap 5) is invisible
   to the retry gate, so `auto_once` can re-run after a tool already executed.
   Tracking tool execution independently of event delivery is `[planned — #205]`;
   until then the no-duplicate guarantee holds absent publication failure.

### 13.6 OAP Alignment

The deviations ledger in [`docs/oap-alignment.md`](oap-alignment.md) is the
convergence contract between makai and OAP: adapter #3 (lsm/open-agent-protocol#3)
maps against it, and per that issue's feedback rule, an adapter mismatch resolves as
either an OAP revision or a makai change — never silent adapter-side compensation.
The ledger also carries the greppable catalogue of documented residuals
(`RESIDUAL-1` … `RESIDUAL-5`). Most are wire-unobservable — this section cannot
resolve them because no frame carries a registration or run generation
(§13.4.5) — and are documented uncertainty rather than guarantees an adapter
may rely on; `RESIDUAL-2` is the exception, locally solvable from `in_reply_to`
and recorded as a caution.
