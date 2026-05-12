/**
 * Public TypeScript types for the Makai V1 model-discovery API.
 *
 * Spec: docs/v1-sdk-agent-provider-spec.md §3 (TS SDK Public API).
 *
 * The shapes mirror the spec verbatim; unknown wire fields are ignored on parse
 * per spec §9 (additive-only V1 evolution rule).
 */

/** Stable identifier for a provider configured in the Makai runtime. */
export type ProviderId = string;

/** Identifier for a provider API implementation supported by Makai. */
export type ApiId =
  | "anthropic-messages"
  | "openai-completions"
  | "openai-responses"
  | "azure-openai-responses"
  | "google-generative-ai"
  | "google-gemini-cli"
  | "ollama"
  // Open union for forward compatibility with future providers.
  | (string & {});

/** Authentication state reported for a provider or model. */
export type AuthStatus =
  | "authenticated"
  | "login_required"
  | "expired"
  | "refreshing"
  | "login_in_progress"
  | "failed"
  | "unknown";

/** Lifecycle state for a model descriptor. */
export type ModelLifecycle = "stable" | "preview" | "deprecated";

/** Capability advertised by a model. */
export type ModelCapability =
  | "chat"
  | "streaming"
  | "tools"
  | "vision"
  | "reasoning"
  | "prompt_cache"
  | "audio_input"
  | "audio_output";

/** Indicates whether model metadata came from live discovery or bundled fallback data. */
export type ModelSource = "dynamic" | "static_fallback";

/** Supported reasoning-effort levels for models that expose reasoning controls. */
export type ReasoningLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh";

/** Describes one model returned by {@link MakaiModelsApi.list} or {@link MakaiModelsApi.resolve}. */
export interface ModelDescriptor {
  /** Opaque, server-issued stable handle. Clients must not parse it. */
  model_ref: string;
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
  reasoning_default?: ReasoningLevel;
  metadata?: Record<string, string>;
}

/** Filters accepted by {@link MakaiModelsApi.list}. */
export interface ListModelsRequest {
  provider_id?: ProviderId;
  api?: ApiId;
  /** Exact-match filter; server-side filtering is mandated by spec §5. */
  model_id?: string;
  include_deprecated?: boolean;
  include_login_required?: boolean;
}

/** Response returned by {@link MakaiModelsApi.list}. */
export interface ListModelsResponse {
  models: ModelDescriptor[];
  fetched_at_ms: number;
  cache_max_age_ms: number;
}

/** Request used by {@link MakaiModelsApi.resolve} to find exactly one model. */
export interface ResolveModelRequest {
  provider_id: ProviderId;
  api?: ApiId;
  model_id: string;
}

/** Response returned by {@link MakaiModelsApi.resolve}. */
export interface ResolveModelResponse {
  model: ModelDescriptor;
}

/** Model discovery API exposed as `client.models`. */
export interface MakaiModelsApi {
  /**
   * Lists available models, optionally filtered by provider, API, or model ID.
   *
   * @param request Optional model filters.
   * @returns Model descriptors and cache metadata.
   * @throws {@link MakaiProtocolError} on protocol failures or malformed responses.
   */
  list(request?: ListModelsRequest): Promise<ListModelsResponse>;
  /**
   * Resolves one exact model by provider, model ID, and optional API.
   *
   * @param request Exact model lookup request.
   * @returns The matching model descriptor.
   * @throws {@link MakaiProtocolError} if no model, multiple models, or malformed data is returned.
   */
  resolve(request: ResolveModelRequest): Promise<ResolveModelResponse>;
}

/**
 * Error thrown by the models API for protocol-level failures.
 *
 * `code` is the protocol `error_code` (e.g. `invalid_request`,
 * `not_implemented`, `provider_error`) when the runtime emits a `nack`,
 * or a synthetic code when the client itself rejects a malformed reply.
 */
export class MakaiProtocolError extends Error {
  /**
   * @param message Human-readable protocol failure.
   * @param code Optional protocol error code.
   */
  constructor(
    message: string,
    public readonly code?: string,
  ) {
    super(message);
    this.name = "MakaiProtocolError";
  }
}
