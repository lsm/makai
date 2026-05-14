import type { ApiId, ProviderId } from "./models_types";
import type { AuthFlowHandlers } from "./auth_protocol";
import type { TimeoutDiagnostics } from "./timeout_diagnostics";
import type { MakaiLogger } from "./logger";

/** Controls whether execution APIs automatically retry once after an authentication challenge. */
export type AuthRetryPolicy = "manual" | "auto_once";

/**
 * Reason a model, provider, or agent turn stopped producing output.
 *
 * Known values mirror provider protocol stop reasons, while arbitrary strings are
 * allowed for forward-compatible provider-specific reasons.
 */
export type StopReason =
  | "end_turn"
  | "max_tokens"
  | "tool_use"
  | "stop_sequence"
  | "max_turns"
  | string;

/** A text block in a {@link ChatMessage} or {@link CompletionResponse}. */
export type TextContentPart = {
  type: "text";
  text: string;
  text_signature?: string;
};

/** A reasoning/thinking block emitted by providers that expose extended thinking. */
export type ThinkingContentPart = {
  type: "thinking";
  thinking: string;
  thinking_signature?: string;
};

/** A base64-encoded image block supplied as multimodal message content. */
export type ImageContentPart = {
  type: "image";
  data: string;
  mime_type: string;
};

/** A tool invocation requested by the assistant. */
export type ToolCallContentPart = {
  type: "tool_call";
  tool_call_id: string;
  name: string;
  arguments_json: string;
};

/** The result of executing a tool call, suitable for sending back to the model. */
export type ToolResultContentPart = {
  type: "tool_result";
  tool_call_id: string;
  tool_name: string;
  content: string | TextContentPart[];
  is_error?: boolean;
  details_json?: string;
};

/** Union of structured message content blocks accepted and returned by Makai. */
export type ContentPart =
  | TextContentPart
  | ThinkingContentPart
  | ImageContentPart
  | ToolCallContentPart
  | ToolResultContentPart;

/**
 * A conversation message passed to {@link MakaiAgentApi.run},
 * {@link MakaiAgentApi.stream}, {@link MakaiProviderApi.complete}, or
 * {@link MakaiProviderApi.stream}.
 */
export interface ChatMessage {
  role: "system" | "developer" | "user" | "assistant" | "tool";
  content: string | ContentPart[];
  name?: string;
  tool_call_id?: string;
}

/** Describes a JSON-schema tool that the model or agent may call. */
export interface ToolDefinition {
  name: string;
  description: string;
  parameters_schema_json: string;
}

/** Optional execution controls shared by agent and provider requests. */
export interface RunOptions {
  temperature?: number;
  max_tokens?: number;
  reasoning_effort?: "off" | "minimal" | "low" | "medium" | "high" | "xhigh";
  auth_retry_policy?: AuthRetryPolicy;
  session_id?: string;
  metadata?: Record<string, string>;
  /** Abort signal to cancel in-flight execution. */
  signal?: AbortSignal;
}

/** Token usage reported by a provider or aggregated by an agent run. */
export interface UsageSummary {
  input: number;
  output: number;
  cache_read?: number;
  cache_write?: number;
}

/** Request body for {@link MakaiAgentApi.run} and {@link MakaiAgentApi.stream}. */
export interface AgentRunRequest {
  model_ref: string;
  messages: ChatMessage[];
  tools?: ToolDefinition[];
  options?: RunOptions;
}

/** Final non-streaming assistant response returned by provider and agent APIs. */
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

/** Final response returned by {@link MakaiAgentApi.run}. */
export type AgentRunResponse = CompletionResponse;

/** Streaming events emitted by {@link MakaiProviderApi.stream}. */
export type ProviderStreamEvent =
  | { type: "message_start"; provider_id?: ProviderId; api?: ApiId; model_id?: string }
  | { type: "text_delta"; delta: string }
  | { type: "thinking_delta"; delta: string }
  | { type: "tool_call"; name: string; arguments_json: string; tool_call_id: string }
  | { type: "message_end"; usage?: UsageSummary; stop_reason?: StopReason }
  | { type: "error"; message: string; code?: string; provider_id?: string };

/** Streaming events emitted by {@link MakaiAgentApi.stream}, including provider events. */
export type AgentStreamEvent =
  | ProviderStreamEvent
  | { type: "agent_start"; session_id?: string }
  | { type: "agent_end"; stop_reason?: StopReason; usage?: UsageSummary }
  | { type: "turn_start" }
  | { type: "turn_end"; stop_reason?: StopReason }
  | { type: "tool_execution_start"; tool_call_id: string; tool_name: string }
  | { type: "tool_execution_end"; tool_call_id: string; is_error?: boolean };

/** Request body for {@link MakaiProviderApi.complete} and {@link MakaiProviderApi.stream}. */
export interface ProviderCompleteRequest {
  model_ref: string;
  messages: ChatMessage[];
  tools?: ToolDefinition[];
  options?: RunOptions;
}

/** Final response returned by {@link MakaiProviderApi.complete}. */
export type ProviderCompleteResponse = CompletionResponse;

/** High-level agent execution API. */
export interface MakaiAgentApi {
  /**
   * Runs the agent loop to completion.
   *
   * @param request Agent run request.
   * @returns Final assistant response.
   * @throws {@link MakaiStreamError} for execution or transport failures.
   */
  run(request: AgentRunRequest): Promise<AgentRunResponse>;
  /**
   * Streams agent lifecycle and provider events.
   *
   * @param request Agent run request.
   * @returns Async iterable of {@link AgentStreamEvent} values.
   * @throws {@link MakaiStreamError} while iterating on execution or transport failures.
   */
  stream(request: AgentRunRequest): AsyncIterable<AgentStreamEvent>;
}

/** Direct provider execution API that bypasses the agent loop. */
export interface MakaiProviderApi {
  /**
   * Requests a non-streaming completion directly from a provider.
   *
   * @param request Provider completion request.
   * @returns Final assistant response.
   * @throws {@link MakaiStreamError} for provider or transport failures.
   */
  complete(request: ProviderCompleteRequest): Promise<ProviderCompleteResponse>;
  /**
   * Streams provider response events directly from a provider.
   *
   * @param request Provider completion request.
   * @returns Async iterable of {@link ProviderStreamEvent} values.
   * @throws {@link MakaiStreamError} while iterating on provider or transport failures.
   */
  stream(request: ProviderCompleteRequest): AsyncIterable<ProviderStreamEvent>;
}

/** Categorizes failures raised by Makai streaming and completion APIs. */
export type MakaiStreamErrorKind = "provider_error" | "transport_error" | "aborted" | "unknown";

/** Error thrown for provider, stream, transport, cancellation, and unknown execution failures. */
export class MakaiStreamError extends Error {
  public readonly kind: MakaiStreamErrorKind;
  public readonly code?: string;
  public readonly provider_id?: string;
  public readonly diagnostics?: TimeoutDiagnostics;

  /**
   * @param message Human-readable error message.
   * @param options Optional structured error metadata.
   */
  constructor(message: string, options: { kind?: MakaiStreamErrorKind; code?: string; provider_id?: string; diagnostics?: TimeoutDiagnostics } = {}) {
    super(message);
    this.name = "MakaiStreamError";
    this.kind = options.kind ?? "unknown";
    this.code = options.code;
    this.provider_id = options.provider_id;
    this.diagnostics = options.diagnostics;
  }
}

/** Error thrown when a request requires provider authentication before it can continue. */
export class MakaiAuthRequiredError extends MakaiStreamError {
  public readonly code = "auth_required";
  public readonly provider_id: ProviderId;

  /**
   * @param providerId Provider that requires authentication.
   * @param message Optional custom message.
   */
  constructor(providerId: ProviderId, message = `authentication required for provider ${providerId}`) {
    super(message, { kind: "provider_error", code: "auth_required", provider_id: providerId });
    this.name = "MakaiAuthRequiredError";
    this.provider_id = providerId;
  }
}

/** Options shared by {@link createMakaiClient} execution, auth, and frame handling. */
export interface MakaiClientOptions {
  auth?: {
    auth_retry_policy?: AuthRetryPolicy;
    handlers?: AuthFlowHandlers;
  };
  responseTimeoutMs?: number;
  frameTimeoutMs?: number;
  /** Optional structured logger for SDK diagnostics. */
  logger?: MakaiLogger;
}
