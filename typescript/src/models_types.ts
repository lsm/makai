
import type { TimeoutDiagnostics } from "./timeout_diagnostics";

export type ProviderId = string;

export type ApiId =
  | "anthropic-messages"
  | "openai-completions"
  | "openai-responses"
  | "azure-openai-responses"
  | "google-generative-ai"
  | "google-gemini-cli"
  | "ollama"
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
  model_id?: string;
  include_deprecated?: boolean;
  include_login_required?: boolean;
  signal?: AbortSignal;
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
  signal?: AbortSignal;
}

export interface ResolveModelResponse {
  model: ModelDescriptor;
}

export interface MakaiModelsApi {
  list(request?: ListModelsRequest): Promise<ListModelsResponse>;
  resolve(request: ResolveModelRequest): Promise<ResolveModelResponse>;
}

export class MakaiProtocolError extends Error {
  public readonly diagnostics?: TimeoutDiagnostics;

  constructor(
    message: string,
    public readonly code?: string,
    options: { diagnostics?: TimeoutDiagnostics } = {},
  ) {
    super(message);
    this.name = "MakaiProtocolError";
    this.diagnostics = options.diagnostics;
  }
}
