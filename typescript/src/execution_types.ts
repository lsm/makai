import type { ApiId, ProviderId } from "./models_types";
import type { AuthFlowHandlers } from "./auth_protocol";

export type AuthRetryPolicy = "manual" | "auto_once";

export type StopReason =
  | "end_turn"
  | "max_tokens"
  | "tool_use"
  | "stop_sequence"
  | "max_turns"
  | string;

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
  content: string | TextContentPart[];
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

export type ProviderStreamEvent =
  | { type: "message_start"; provider_id?: ProviderId; api?: ApiId; model_id?: string }
  | { type: "text_delta"; delta: string }
  | { type: "thinking_delta"; delta: string }
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

export type ProviderCompleteResponse = CompletionResponse;

export interface MakaiAgentApi {
  run(request: AgentRunRequest): Promise<AgentRunResponse>;
  stream(request: AgentRunRequest): AsyncIterable<AgentStreamEvent>;
}

export interface MakaiProviderApi {
  complete(request: ProviderCompleteRequest): Promise<ProviderCompleteResponse>;
  stream(request: ProviderCompleteRequest): AsyncIterable<ProviderStreamEvent>;
}

export type MakaiStreamErrorKind = "provider_error" | "transport_error" | "aborted" | "unknown";

export class MakaiStreamError extends Error {
  public readonly kind: MakaiStreamErrorKind;
  public readonly code?: string;

  constructor(message: string, options: { kind?: MakaiStreamErrorKind; code?: string } = {}) {
    super(message);
    this.name = "MakaiStreamError";
    this.kind = options.kind ?? "unknown";
    this.code = options.code;
  }
}

export interface MakaiClientOptions {
  auth?: {
    auth_retry_policy?: AuthRetryPolicy;
    handlers?: AuthFlowHandlers;
  };
  responseTimeoutMs?: number;
  frameTimeoutMs?: number;
}
