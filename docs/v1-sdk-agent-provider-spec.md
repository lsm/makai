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

The server removes an agent session only on `agent_stop`; as of this revision there is no TTL and no terminal-state eviction (V1.1 §13.2 grants servers eviction rights; the idle-TTL requirement is tracked in #202). Session teardown is therefore client-owned:

- A client that uses one session per run (start → message → result) MUST send `agent_stop` when a run it owns reaches a terminal state: success, failure, or abandonment (including an auth-retry attempt whose session id is discarded). Otherwise the session stays registered for the process lifetime and its id is permanently rejected on reuse (`agent_busy`). The mandate is bounded by ownership: a client MUST NOT stop a session its own `agent_start` did not establish — in particular, a start rejected with `agent_busy` means the id belongs to another live run, and a stop carrying the live session's expected sequence would remove and cancel that unrelated run. If the start's outcome is unknowable (reply lost, timeout), the client MAY stop: either the session is its own and is cleaned up, or the stop is rejected harmlessly.
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
- Session-level replay/resume is deferred to a future revision; §13.5 defines the load/resume/replay trichotomy these deferrals are stated against.

## 13. Session Lifecycle & Frame Routing (V1.1)

Status: normative revision (docs-only; no wire-format changes). Amends §6, §6.1, and
§12. Vocabulary is aligned to the Open Agent Protocol (OAP) agent-control core — the
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
| Session | 21-char alphanumeric NanoID (`[A-Za-z0-9]{21}`, §3.1) | envelope `session_id` on every agent frame; payload `session_id` on `agent_message`/`agent_stop`/`agent_status`; payload `resume_session_id` on `agent_start` | Session-container key and frame-correlation scope ONLY (see the `agent_start` id-allocation exception below) |
| Envelope message | 26-char Crockford Base32 ULID (§3.1) | envelope `message_id`; envelope `in_reply_to` | Per-envelope identity; request/reply correlation |
| Ordering | `u64` | envelope `sequence` | Per-direction, per-session monotonic ordering — never an identity |
| Provider stream / auth flow | 26-char ULID | `stream_id` / `flow_id` on provider/auth frames of the same connection | Adjacent protocol domains; never valid agent-domain identifiers despite the shared format |
| Tool call | provider-originated string | payload `tool_call_id` on `tool_execute`/`tool_result` and tool-execution events | Correlates one in-flight tool execution; uniqueness not enforced session-wide (see rules) |

Rules:

- `session_id` is a correlation key and the server-side session-container key. It is
  NOT a resume, replay, or persistence handle (§13.5); treating it as one is the error
  makai #198 exists to correct. The `agent_start` payload key is currently spelled
  `resume_session_id` for historical reasons; its semantics are those of `session_id`,
  and the rename is tracked in #198 (this revision defines semantics only and does not
  change the wire).
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
  `agent_status`, `ping`, `tool_list`, and `models_request` never consume inbound
  sequence. `tool_result` frames are intercepted by the stdio host before the agent
  protocol and never consume agent inbound sequence numbers.
  Outbound `[current]`: emitted frames come in two classes. Allocated frames
  (`agent_started`, `agent_stopped`, `ack`, `nack`, `models_response`, `agent_event`,
  `agent_result`, settlement `agent_error`, `tool_execute`) draw from one monotonic
  per-session counter — scoped to the session-container REGISTRATION, not the id
  string: `agent_start` initializes the counter to 0 (overwriting any numbers the
  id consumed for `models_request`s issued before the start), and an id
  re-registered after a stop restarts it, so sequence values may repeat across
  registrations of the same id. Consumers MUST treat the outbound counter as
  per-registration. Echo replies (`session_info`, `pong`, `tool_list_response`)
  copy the
  request's inbound sequence verbatim — a correlation echo, not an ordering
  allocation — and request-validation `agent_error` envelopes carry `sequence: 0`
  (outside the ordering domain). Consumers MUST NOT order echo replies against
  allocated frames by sequence. Whether echo replies should instead allocate from the
  per-session counter (uniform outbound ordering) is the open decision in #204; until
  it is resolved, the split above is the contract.
- When a scoped identifier appears in both the envelope and the payload of one frame,
  the values MUST agree (OAP rule). On `agent_start` — when the payload id is
  present — the envelope `session_id` and the payload key select the same
  session-container key (the SDK always sends them equal). Exception
  `[current]`: when `agent_start` OMITS the payload id, the request envelope's
  `session_id` is ignored — the server generates the container id and returns it in
  `agent_started` (both its envelope `session_id` and payload). Consumers MUST adopt
  the id from `agent_started` and MUST NOT assume their request envelope id became
  the session key. Enforcement of the agreement rule is
  `[planned — #204]`: today the server keys all session handlers on the payload id
  and does not compare the envelope id, so agreement is a client convention, not a
  server-checked invariant; #204 adds the `invalid_request` rejection for mismatches.
- `tool_call_id` correlation is scoped to concurrently in-flight calls. Ids originate
  from provider output and the server keeps no session-wide registry: a provider MAY
  reuse a value in a later turn or a later run of the same multi-message session.
  Consumers and adapters MUST NOT key tool history by bare `tool_call_id`.

### 13.2 Session Lifecycle & Ownership (Normative)

A session is a server-side, in-memory container of agent execution state (status,
resolved model, config, system prompt, message counter, timestamps) keyed by its
session id. It is created by `agent_start`, destroyed by `agent_stop` (or, once
granted, server eviction), and holds no transcript and no persistence.

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
5. Teardown `[current, extends §6.1]`: `agent_stop` is the only session removal path;
   a validated stop also cancels the session's in-flight run and discards its pending
   tool work. The §6.1 client mandate (stop on terminal/error/abandon, bounded by
   ownership) is normative for one-run-per-session clients.
6. Eviction rights `[planned — #202]`: servers are granted the right to evict
   sessions, with these semantics:
   - Idle TTL: a server MUST evict sessions idle longer than a configurable TTL with
     a defined non-zero default. Idleness is measured from the session's last
     activity — inbound (message, stop, status) OR server-side run activity (event
     publication) — and a session with an in-flight run is NEVER idle, so a
     long-running turn or tool execution cannot be evicted out from under its run.
     Idleness is never measured from run settlement — a settled multi-message session
     is idle-but-alive, by design (rule 3).
   - Resource caps: a server MAY additionally bound registered sessions and evict
     least-recently-active entries.
   - An evicted session's next session-scoped request other than `agent_start`
     (`agent_message`, `agent_stop`, `agent_status`) receives the existing
     `agent_not_found` error ("session not found") — identical to an unknown or
     already-stopped id; eviction MUST NOT be distinguishable from stop by error
     code. `agent_start` on an unregistered id (evicted, stopped, or never created)
     creates a fresh container per §13.5.2 — clients re-supply full context (§12).
   - Evicting a session with an in-flight run MUST cancel that run (same semantics as
     `agent_stop`).
   - Until #202 lands, no eviction exists: lifetime is 100% client-owned (§6.1).
7. Disconnect `[current for the stdio host]`: the process exits when stdin closes and
   no runs, provider streams, or auth flows remain active, bounding session lifetime
   by the connection. Disconnect does not cancel in-flight work in V1, with two
   distinct outcomes: a run executing against a provider is pumped to completion
   and its settlement frames are still drained to stdout — stdin and stdout are
   independent pipes, so a client that closed only its write side but keeps
   reading still receives them (lost only when the read side is gone); a run
   WAITING on a distributed
   `tool_result` cannot complete — the tool host is the disconnected client, the
   tool wait polls with no EOF-triggered cancel, and the host loop never sees the
   run go idle — so the process (and every session it owns) stays alive
   indefinitely until killed. EOF-triggered cancellation of active runs is tracked
   with the disconnect-cleanup family in #202/#204. Future multi-connection hosts
   MUST scope sessions to their owning connection (rule 2) and evict on disconnect
   (#202).

### 13.3 Frame Routing (Normative)

1. Request-correlated delivery `[planned — #201; partially current]`: a reply frame
   carrying `in_reply_to` MUST be delivered to the waiter whose outstanding request's
   `message_id` equals that `in_reply_to` — not merely to any waiter on the session.
   Current state: the server sets `in_reply_to` on all synchronous replies, but the
   TS transport routes frames per session id only; the SDK applies `in_reply_to`
   correlation itself, and only in the pre-acceptance window (before its own
   `agent_start` is accepted). #201 tracks the general rule in the transport.
2. Session-scoped delivery `[current]`: asynchronous run output (`agent_event`,
   `agent_result`, settlement `agent_error`, `tool_execute`) carries no `in_reply_to`
   and is delivered on the session's route. Rule §13.2.4 (one active run per session)
   keeps session scope unambiguous for run output.
3. Concurrent calls on one explicit session id `[current]`: until rule 1 lands, two
   overlapping calls sharing one consumer-supplied session id share one frame route
   and MUST fail rather than interleave: the server rejects the duplicate start with
   `agent_busy` ("session already exists") and a message against the processing
   session with `agent_busy` ("session already processing a message"). A client that
   receives `agent_busy` MUST treat the attempt as rejected and MUST NOT stop the
   session (it is not the attempt's to stop — §6.1). The routing defect is worse
   than a delayed rejection: the established call can consume the duplicate's
   `agent_busy` `agent_error` AFTER its own start was accepted (the SDK's
   `in_reply_to` correlation covers only the pre-acceptance window), treat it as
   its own failure, and tear the legitimate session down — cancelling the live
   run. Both failure modes (the duplicate timing out; the established run being
   destroyed) are what #201 fixes.
4. Tool side channel `[current]`: `tool_execute` is delivered on the session route;
   `tool_result` replies carry `in_reply_to` referencing the `tool_execute`
   `message_id` but are intercepted by the stdio host before the agent protocol
   (§13.1 sequence rule) and never appear on the session route.

### 13.4 Admission, Settlement, and the Single Terminal Arbiter (Normative)

1. Admission `[current]`: a run is admitted when the server ACCEPTS an
   `agent_message` (after `agent_started`) and enqueues it for execution — writing
   the frame alone is not admission. A message rejected for an unknown session
   (`agent_not_found`), an out-of-order sequence (`invalid_request`), or a
   `.processing` session (`agent_busy`) produces a request-correlated validation
   `agent_error` and enqueues nothing; a rejected submission MUST be treated as
   non-admission — an adapter that records it as accepted would wait for a
   settlement that can never arrive. Acceptance has no positive receipt: it is
   observable only through subsequent run output, or the continued absence of a
   correlated rejection (the receipt-less admission is a ledger deviation). A
   start rejected before admission (`agent_busy`, invalid sequence, `nack`) never
   admits. Admission is not settlement.
2. Settlement `[current]`: exactly one settlement frame settles an admitted run
   that reaches its own outcome — a run cancelled by `agent_stop` produces no run
   settlement frame at all (§13.4.4):
   - success: the `agent_result` frame (or provider-shaped `result`/`complete_response`
     frame). This is the settlement frame for BOTH consumption modes: the SDK's
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
     - loop-internal failures (run start failure, agent run stream error): the
       failure pair — an `agent_event` carrying the terminal `error` event (§3.5's
       one-terminal-error rule) followed by the settlement `agent_error` envelope —
       is ONE settlement. The `agent_error` envelope is the settlement frame; the
       `agent_event` is its event-stream projection. Consumers terminate on the
       first-delivered frame of the pair and MUST NOT count the pair as two
       settlements.
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
   exactly once, via result XOR error, never both. Children settle first: pending
   tool work resolves and the trailing `agent_end` is published only after
   `agent_result`. Duplicate or late frames after settlement (e.g. a stale
   `agent_end` read by a follow-up run on the same id) MUST NOT produce a second
   settlement — clients drain per §6.1.
4. Cancellation is session settlement, not run settlement `[current]`: a validated
   `agent_stop` removes the session mid-run and cancels the run; the cancelled run's
   subsequent result/error publications are discarded because the session no longer
   exists. A cancelled run therefore produces NO run settlement frame — the
   `agent_stopped` reply correlated to the stop request is the client's terminal
   observation. Makai has no run-scoped cancelled terminal (OAP `run.cancelled` is a
   ledger deviation); there is nothing for a consumer to wait on after
   `agent_stopped`.
5. Stopped-id reuse race `[planned — #204]`: the cancelled run of a stopped session
   stays alive until its provider stream drains. If a new `agent_start` re-registers
   the same id before then, late frames from the old run can publish into the new
   container, and the new run — already ADMITTED (its `agent_message` was accepted
   and enqueued against the re-created session) — fails at run start with an
   `internal_error` settlement: the run-start path refuses to double-start the id
   and the failure surfaces as the loop-error settlement pair (§13.4.2), not as a
   request-level `agent_busy` rejection. Draining (§6.1) narrows but does not
   eliminate this; a session
   generation/tombstone (#204) is required before immediate id reuse can be
   considered safe. Until then, clients that reuse an explicit id after a stop
   SHOULD drain quiescent first (§6.1) and accept the residual race, or use a fresh
   id.
6. Transport death `[current]`: process exit before settlement is failure, never
   success — the client transport rejects all pending frame waits on exit, and no
   result is fabricated for an unsettled run. Stdin EOF splits by run state
   (§13.2.7): a provider-executing run is pumped to settlement and its frames are
   still drained to stdout — stdin and stdout are independent pipes, so a client
   that closed only its write side but keeps reading CAN receive its settlement
   (a delivered settlement is not a transport failure, and a client MUST NOT retry
   a run it already saw settle); the frames are lost only when the read side is
   gone or the process dies. A run waiting on a distributed `tool_result` produces
   NO terminal at all — the server process hangs (#204 gap 4) and only the
   client's response timeout surfaces an error. In every case an unsettled run is
   never a success; recovery is retry with full context (§12).

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
   `agent_start` payload key `resume_session_id`, whose name is historical (#198) — is
   a correlation and container key only. Supplying a previously-used id to
   `agent_start` either creates a fresh, empty container (unknown, stopped, or
   evicted id) or is rejected `agent_busy` (registered id); it never restores state.
   History is supplied by the client in `messages` on every call.
3. Client retry artifacts are not replay `[current]`: `auto_once` auth retry may
   re-emit the failed attempt's lifecycle markers in a fresh session; that is
   client-side reconstruction across sessions, not protocol replay, and MUST NOT
   duplicate provider content or tool side effects (the SDK gates retry on no content
   yielded and no tools executed).

### 13.6 OAP Alignment

The deviations ledger in [`docs/oap-alignment.md`](oap-alignment.md) is the
convergence contract between makai and OAP: adapter #3 (lsm/open-agent-protocol#3)
maps against it, and per that issue's feedback rule, an adapter mismatch resolves as
either an OAP revision or a makai change — never silent adapter-side compensation.
