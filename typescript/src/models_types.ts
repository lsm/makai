/**
 * Public TypeScript types for the Makai V1 model-discovery API.
 *
 * Spec: docs/v1-sdk-agent-provider-spec.md §3 (TS SDK Public API).
 *
 * The shapes mirror the spec verbatim; unknown wire fields are ignored on parse
 * per spec §9 (additive-only V1 evolution rule).
 */

export type ProviderId = string;

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

export type ReasoningLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh";

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

export interface ListModelsRequest {
  provider_id?: ProviderId;
  api?: ApiId;
  /** Exact-match filter; server-side filtering is mandated by spec §5. */
  model_id?: string;
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

export interface MakaiModelsApi {
  list(request?: ListModelsRequest): Promise<ListModelsResponse>;
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
  constructor(
    message: string,
    public readonly code?: string,
  ) {
    super(message);
    this.name = "MakaiProtocolError";
  }
}
