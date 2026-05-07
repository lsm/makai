import { randomInt } from "node:crypto";
import { ulid } from "ulid";
import { MakaiAuthClient, type AuthFlowHandlers, type MakaiAuthApi } from "./auth_protocol";
import { parseModelRef } from "./diagnostics/model_ref";
import { createMakaiModelsApi } from "./models_client";
import type { MakaiModelsApi } from "./models_types";
import { type CreateMakaiStdioClientOptions, createMakaiStdioClient, MakaiStdioClient, type StdioFrame } from "./stdio_client";
import {
  MakaiStreamError,
  type AgentRunRequest,
  type AgentRunResponse,
  type AgentStreamEvent,
  type ChatMessage,
  type CompletionResponse,
  type ContentPart,
  type MakaiAgentApi,
  type MakaiClientOptions,
  type MakaiProviderApi,
  type ProviderCompleteRequest,
  type ProviderCompleteResponse,
  type ProviderStreamEvent,
  type RunOptions,
  type ToolDefinition,
  type UsageSummary,
} from "./execution_types";

const ENVELOPE_VERSION = 1;
const DEFAULT_RESPONSE_TIMEOUT_MS = 30_000;
const NANO_ID_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

function generateNanoId(): string {
  let id = "";
  for (let i = 0; i < 21; i++) {
    id += NANO_ID_ALPHABET[randomInt(NANO_ID_ALPHABET.length)];
  }
  return id;
}

type ExecutionOptions = {
  responseTimeoutMs?: number;
  authRetryPolicy?: RunOptions["auth_retry_policy"];
  auth?: MakaiAuthApi;
  authHandlers?: AuthFlowHandlers;
};

export interface MakaiClient {
  auth: MakaiAuthApi;
  models: MakaiModelsApi;
  agent: MakaiAgentApi;
  provider: MakaiProviderApi;
  close(): Promise<void>;
}

export type CreateMakaiClientOptions = CreateMakaiStdioClientOptions & MakaiClientOptions;

export function createMakaiProviderApi(
  transport: MakaiStdioClient,
  options: ExecutionOptions = {},
): MakaiProviderApi {
  return new StdioProviderApi(transport, options);
}

export function createMakaiAgentApi(
  transport: MakaiStdioClient,
  options: ExecutionOptions = {},
): MakaiAgentApi {
  return new StdioAgentApi(transport, options);
}

class StdioProviderApi implements MakaiProviderApi {
  private readonly responseTimeoutMs: number;
  private readonly authRetryPolicy?: RunOptions["auth_retry_policy"];
  private readonly auth?: MakaiAuthApi;
  private readonly authHandlers?: AuthFlowHandlers;

  constructor(private readonly transport: MakaiStdioClient, options: ExecutionOptions) {
    this.responseTimeoutMs = options.responseTimeoutMs ?? DEFAULT_RESPONSE_TIMEOUT_MS;
    this.authRetryPolicy = options.authRetryPolicy;
    this.auth = options.auth;
    this.authHandlers = options.authHandlers;
  }

  async complete(request: ProviderCompleteRequest): Promise<ProviderCompleteResponse> {
    const effectivePolicy = request.options?.auth_retry_policy ?? this.authRetryPolicy;
    return withAuthRetry(
      () => this.completeOnce(request, effectivePolicy),
      { auth: this.auth, authHandlers: this.authHandlers, authRetryPolicy: effectivePolicy, fallbackProviderId: providerIdFromRequest(request) },
    );
  }

  private async completeOnce(request: ProviderCompleteRequest, effectivePolicy: RunOptions["auth_retry_policy"] | undefined): Promise<ProviderCompleteResponse> {
    const streamId = ulid();
    const fallbackProviderId = providerIdFromRequest(request);
    this.transport.send(buildEnvelope("complete_request", streamId, buildExecutionPayload(request, { authRetryPolicy: effectivePolicy })));
    while (true) {
      const frame = await nextFrame(this.transport, streamId, this.responseTimeoutMs);
      if (frame.type === "ack") continue;
      if (frame.type === "nack") throw nackToStreamError(frame, fallbackProviderId);
      if (frame.type === "stream_error") throw streamErrorFrameToError(frame);
      if (frame.type === "result" || frame.type === "complete_response") {
        return parseCompletionResponse(frame.payload ?? frame);
      }
      throw new MakaiStreamError(`unexpected frame type while awaiting provider result: ${String(frame.type)}`, { kind: "transport_error" });
    }
  }

  async *stream(request: ProviderCompleteRequest): AsyncIterable<ProviderStreamEvent> {
    const effectivePolicy = request.options?.auth_retry_policy ?? this.authRetryPolicy;
    const fallbackProviderId = providerIdFromRequest(request);
    let attempt = this.streamAttempt(request, effectivePolicy);
    let iterator = attempt[Symbol.asyncIterator]();
    let yielded = false;
    let retried = false;

    while (true) {
      let result;
      try {
        result = await iterator.next();
      } catch (error) {
        if (!yielded && !retried && isRetryableAuthError(error) && effectivePolicy === "auto_once" && this.auth) {
          const providerId = error.provider_id ?? fallbackProviderId;
          if (providerId) {
            try {
              await this.auth.login(providerId, this.authHandlers);
            } catch {
              throw error;
            }
            retried = true;
            attempt = this.streamAttempt(request, effectivePolicy);
            iterator = attempt[Symbol.asyncIterator]();
            continue;
          }
        }
        throw error;
      }
      if (result.done) return;
      yielded = true;
      yield result.value;
    }
  }

  private async *streamAttempt(request: ProviderCompleteRequest, effectivePolicy: RunOptions["auth_retry_policy"] | undefined): AsyncIterable<ProviderStreamEvent> {
    const streamId = ulid();
    const fallbackProviderId = providerIdFromRequest(request);
    this.transport.send(buildEnvelope("stream_request", streamId, buildExecutionPayload(request, { suppressPartial: true, authRetryPolicy: effectivePolicy })));
    let terminal = false;
    const toolBuffers = new Map<number, { id?: string; name?: string; args: string }>();
    try {
      while (!terminal) {
        const frame = await nextFrame(this.transport, streamId, this.responseTimeoutMs);
        if (frame.type === "ack") continue;
        if (frame.type === "nack") throw nackToStreamError(frame, fallbackProviderId);
        const event = normalizeProviderFrame(frame, toolBuffers);
        if (!event) continue;
        if (event.type === "error") {
          terminal = true;
          if (event.code === "auth_required") {
            throw new MakaiStreamError(event.message, { kind: "provider_error", code: event.code, provider_id: event.provider_id });
          }
          yield event;
          continue;
        }
        if (event.type === "message_end") terminal = true;
        yield event;
      }
    } catch (error) {
      if (error instanceof MakaiStreamError) throw error;
      throw new MakaiStreamError(error instanceof Error ? error.message : String(error), { kind: "transport_error" });
    }
  }
}

class StdioAgentApi implements MakaiAgentApi {
  private readonly responseTimeoutMs: number;
  private readonly authRetryPolicy?: RunOptions["auth_retry_policy"];
  private readonly auth?: MakaiAuthApi;
  private readonly authHandlers?: AuthFlowHandlers;

  constructor(private readonly transport: MakaiStdioClient, options: ExecutionOptions) {
    this.responseTimeoutMs = options.responseTimeoutMs ?? DEFAULT_RESPONSE_TIMEOUT_MS;
    this.authRetryPolicy = options.authRetryPolicy;
    this.auth = options.auth;
    this.authHandlers = options.authHandlers;
  }

  async run(request: AgentRunRequest): Promise<AgentRunResponse> {
    const effectivePolicy = request.options?.auth_retry_policy ?? this.authRetryPolicy;
    let retryRequest = request;
    return withAuthRetry(
      () => this.runOnce(retryRequest, effectivePolicy),
      {
        auth: this.auth,
        authHandlers: this.authHandlers,
        authRetryPolicy: effectivePolicy,
        fallbackProviderId: providerIdFromRequest(request),
        beforeRetry: () => {
          retryRequest = {
            ...request,
            options: { ...request.options, session_id: generateNanoId() },
          };
        },
      },
    );
  }

  private async runOnce(request: AgentRunRequest, effectivePolicy: RunOptions["auth_retry_policy"] | undefined): Promise<AgentRunResponse> {
    const sessionId = agentSessionId(request);
    const fallbackProviderId = providerIdFromRequest(request);
    this.transport.send(buildAgentEnvelope("agent_start", sessionId, 1, buildAgentStartPayload(request, sessionId)));
    const events: AgentStreamEvent[] = [];
    const toolBuffers = new Map<number, { id?: string; name?: string; args: string }>();
    let messageSent = false;
    while (true) {
      const frame = await nextAgentFrame(this.transport, sessionId, this.responseTimeoutMs);
      if (frame.type === "ack") continue;
      if (frame.type === "nack") throw nackToStreamError(frame, fallbackProviderId);
      if (frame.type === "agent_error") throw streamErrorFrameToError(frame);
      if (frame.type === "agent_started") {
        if (!messageSent) {
          this.transport.send(buildAgentEnvelope("agent_message", sessionId, 2, buildAgentMessagePayload(request, sessionId, effectivePolicy)));
          messageSent = true;
        }
        continue;
      }
      if (frame.type === "agent_result") return parseAgentRunResponse(readJsonStringPayload(frame, "result_json"));
      if (frame.type === "result" || frame.type === "complete_response") return parseCompletionResponse(frame.payload ?? frame);

      const normalized = normalizeAgentFrame(frame, toolBuffers);
      if (normalized.length === 0) {
        throw new MakaiStreamError(`unexpected frame type while awaiting agent result: ${String(frame.type)}`, { kind: "transport_error" });
      }
      for (const event of normalized) {
        if (event.type === "error") throw new MakaiStreamError(event.message, { kind: "provider_error", code: event.code, provider_id: event.provider_id });
        events.push(event);
        if (event.type === "agent_end") return buildAgentRunResponseFromEvents(events);
      }
    }
  }

  async *stream(request: AgentRunRequest): AsyncIterable<AgentStreamEvent> {
    const effectivePolicy = request.options?.auth_retry_policy ?? this.authRetryPolicy;
    const fallbackProviderId = providerIdFromRequest(request);
    let streamRequest = request;
    let attempt = this.streamAttempt(streamRequest, effectivePolicy);
    let iterator = attempt[Symbol.asyncIterator]();
    let yielded = false;
    let retried = false;

    while (true) {
      let result;
      try {
        result = await iterator.next();
      } catch (error) {
        if (!yielded && !retried && isRetryableAuthError(error) && effectivePolicy === "auto_once" && this.auth) {
          const providerId = error.provider_id ?? fallbackProviderId;
          if (providerId) {
            try {
              await this.auth.login(providerId, this.authHandlers);
            } catch {
              throw error;
            }
            retried = true;
            streamRequest = {
              ...request,
              options: { ...request.options, session_id: generateNanoId() },
            };
            attempt = this.streamAttempt(streamRequest, effectivePolicy);
            iterator = attempt[Symbol.asyncIterator]();
            continue;
          }
        }
        throw error;
      }
      if (result.done) return;
      yielded = true;
      yield result.value;
    }
  }

  private async *streamAttempt(request: AgentRunRequest, effectivePolicy: RunOptions["auth_retry_policy"] | undefined): AsyncIterable<AgentStreamEvent> {
    const sessionId = agentSessionId(request);
    const fallbackProviderId = providerIdFromRequest(request);
    this.transport.send(buildAgentEnvelope("agent_start", sessionId, 1, buildAgentStartPayload(request, sessionId)));
    let terminal = false;
    let messageSent = false;
    let started = false;
    let aggregateUsage: UsageSummary | undefined;
    const toolBuffers = new Map<number, { id?: string; name?: string; args: string }>();
    try {
      while (!terminal) {
        const frame = await nextAgentFrame(this.transport, sessionId, this.responseTimeoutMs);
        if (frame.type === "ack") continue;
        if (frame.type === "nack") throw nackToStreamError(frame, fallbackProviderId);
        if (frame.type === "agent_started" && !messageSent) {
          this.transport.send(buildAgentEnvelope("agent_message", sessionId, 2, buildAgentMessagePayload(request, sessionId, effectivePolicy)));
          messageSent = true;
          continue;
        }
        const events = normalizeAgentFrame(frame, toolBuffers);
        for (const rawEvent of events) {
          let event = rawEvent;
          if (event.type === "error" && event.code === "auth_required") {
            terminal = true;
            throw new MakaiStreamError(event.message, { kind: "provider_error", code: event.code, provider_id: event.provider_id });
          }
          if (!started) {
            started = true;
            if (event.type !== "agent_start") {
              yield { type: "agent_start", session_id: sessionId };
            }
          }
          if (event.type === "message_end" && event.usage) {
            aggregateUsage = aggregateUsage ? addUsage(aggregateUsage, event.usage) : event.usage;
          }
          if (event.type === "agent_end") {
            event = { ...event, usage: aggregateUsage ?? event.usage };
            terminal = true;
          } else if (event.type === "error") {
            terminal = true;
          }
          yield event;
          if (terminal) break;
        }
      }
    } catch (error) {
      if (error instanceof MakaiStreamError) throw error;
      throw new MakaiStreamError(error instanceof Error ? error.message : String(error), { kind: "transport_error" });
    }
  }
}

function buildEnvelope(type: string, streamId: string, payload: Record<string, unknown>): StdioFrame {
  return {
    type,
    stream_id: streamId,
    message_id: streamId,
    sequence: 1,
    timestamp: Date.now(),
    version: ENVELOPE_VERSION,
    payload,
  };
}

function buildAgentEnvelope(type: string, sessionId: string, sequence: number, payload: Record<string, unknown>): StdioFrame {
  return {
    type,
    session_id: sessionId,
    message_id: ulid(),
    sequence,
    timestamp: Date.now(),
    version: ENVELOPE_VERSION,
    payload,
  };
}

function buildExecutionPayload(
  request: ProviderCompleteRequest | AgentRunRequest,
  options: { suppressPartial?: boolean; authRetryPolicy?: RunOptions["auth_retry_policy"] } = {},
): Record<string, unknown> {
  validateExecutionRequest(request);
  const model = modelFromRef(request.model_ref);
  const payload: Record<string, unknown> = {
    model,
    context: executionContext(request),
    model_ref: request.model_ref,
  };
  const serializedOptions = serializeOptionsWithDefaults(request.options, options.authRetryPolicy);
  if (Object.keys(serializedOptions).length > 0) payload.options = serializedOptions;
  // V1 streams emit fully-buffered tool calls, so ask capable runtimes not to
  // include heavy partial message snapshots on stream deltas.
  if (options.suppressPartial) payload.include_partial = false;
  return payload;
}

function buildAgentStartPayload(request: AgentRunRequest, sessionId: string): Record<string, unknown> {
  validateExecutionRequest(request);
  return {
    resume_session_id: sessionId,
    config_json: JSON.stringify({ model_ref: request.model_ref, tools: request.tools ?? [] }),
  };
}

function buildAgentMessagePayload(
  request: AgentRunRequest,
  sessionId: string,
  authRetryPolicy: RunOptions["auth_retry_policy"] | undefined,
): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    session_id: sessionId,
    message_json: JSON.stringify({ model_ref: request.model_ref, messages: request.messages, tools: request.tools ?? [] }),
  };
  const serializedOptions = serializeOptionsWithDefaults(request.options, authRetryPolicy);
  if (Object.keys(serializedOptions).length > 0) payload.options_json = JSON.stringify(serializedOptions);
  return payload;
}

function validateExecutionRequest(request: ProviderCompleteRequest | AgentRunRequest): void {
  if (!request || typeof request.model_ref !== "string" || request.model_ref.length === 0) {
    throw new TypeError("request requires opaque model_ref");
  }
  if (!Array.isArray(request.messages)) {
    throw new TypeError("request requires messages array");
  }
}

function modelFromRef(modelRef: string): Record<string, unknown> {
  try {
    const parsed = parseModelRef(modelRef);
    return {
      id: parsed.modelId,
      name: parsed.modelId,
      api: parsed.api,
      provider: parsed.providerId,
      base_url: "",
    };
  } catch {
    // Best-effort: extract provider/api even when model_id is non-canonical
    // so the runtime has routing metadata for opaque server-issued handles.
    const slashIndex = modelRef.indexOf("/");
    const atIndex = modelRef.indexOf("@");
    if (slashIndex !== -1 && atIndex !== -1 && slashIndex < atIndex) {
      const provider = modelRef.slice(0, slashIndex);
      const api = modelRef.slice(slashIndex + 1, atIndex);
      const id = modelRef.slice(atIndex + 1);
      if (provider.length > 0 && api.length > 0) {
        return {
          id,
          name: id,
          api,
          provider,
          base_url: "",
        };
      }
    }
    return opaqueModel(modelRef);
  }
}

function opaqueModel(modelRef: string): Record<string, unknown> {
  return {
    id: modelRef,
    name: modelRef,
    api: "",
    provider: "",
    base_url: "",
  };
}

function executionContext(request: ProviderCompleteRequest | AgentRunRequest): Record<string, unknown> {
  const messages: Record<string, unknown>[] = [];
  const systemPrompts: string[] = [];
  for (const message of request.messages) {
    if (message.role === "system" || message.role === "developer") {
      systemPrompts.push(contentAsPromptText(message.content));
    } else {
      messages.push(serializeChatMessage(message));
    }
  }

  const context: Record<string, unknown> = { messages };
  if (systemPrompts.length > 0) context.system_prompt = systemPrompts.join("\n\n");
  if (request.tools) context.tools = request.tools.map(serializeTool);
  return context;
}

function agentSessionId(request: AgentRunRequest): string {
  const sessionId = request.options?.session_id;
  if (sessionId === undefined) return generateNanoId();
  if (!isNanoId(sessionId)) {
    throw new TypeError("request.options.session_id must be a 21-character alphanumeric NanoID for agent transport");
  }
  return sessionId;
}

function isNanoId(value: string): boolean {
  return /^[0-9A-Za-z]{21}$/.test(value);
}

function serializeChatMessage(message: ChatMessage): Record<string, unknown> {
  const out: Record<string, unknown> = { role: message.role, content: serializeMessageContent(message) };
  if (message.name) out.name = message.name;
  if (message.role === "tool") out.tool_name = message.name ?? "";
  if (message.tool_call_id) out.tool_call_id = message.tool_call_id;
  return out;
}

function serializeMessageContent(message: ChatMessage): string | ContentPart[] {
  if (message.role === "tool") return contentAsUserParts(message.content);
  return message.content;
}

function contentAsPromptText(content: ChatMessage["content"]): string {
  if (typeof content === "string") return content;
  return content.map(contentPartText).filter((part) => part.length > 0).join("\n");
}

function contentPartText(part: ContentPart): string {
  if (part.type === "text") return part.text;
  if (part.type === "thinking") return part.thinking;
  if (part.type === "tool_result") return typeof part.content === "string" ? part.content : contentAsPromptText(part.content);
  return "";
}

function contentAsUserParts(content: ChatMessage["content"]): ContentPart[] {
  if (typeof content === "string") return [{ type: "text", text: content }];
  return content;
}

function serializeTool(tool: ToolDefinition): Record<string, unknown> {
  return {
    name: tool.name,
    description: tool.description,
    parameters_schema_json: tool.parameters_schema_json,
  };
}

function serializeOptionsWithDefaults(
  options: RunOptions | undefined,
  authRetryPolicy: RunOptions["auth_retry_policy"] | undefined,
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (authRetryPolicy !== undefined) out.auth_retry_policy = authRetryPolicy;
  if (!options) return out;
  for (const key of ["temperature", "max_tokens", "reasoning_effort", "auth_retry_policy", "session_id", "metadata"] as const) {
    if (options[key] !== undefined) out[key] = options[key];
  }
  return out;
}

async function nextFrame(transport: MakaiStdioClient, streamId: string, timeoutMs: number): Promise<StdioFrame> {
  try {
    return await transport.nextFrameForStream(streamId, timeoutMs);
  } catch (error) {
    throw new MakaiStreamError(error instanceof Error ? error.message : String(error), { kind: "transport_error" });
  }
}

async function nextAgentFrame(transport: MakaiStdioClient, sessionId: string, timeoutMs: number): Promise<StdioFrame> {
  try {
    return await transport.nextFrameForSession(sessionId, timeoutMs);
  } catch (error) {
    throw new MakaiStreamError(error instanceof Error ? error.message : String(error), { kind: "transport_error" });
  }
}

function normalizeProviderFrame(
  frame: StdioFrame,
  toolBuffers: Map<number, { id?: string; name?: string; args: string }>,
): ProviderStreamEvent | undefined {
  if (frame.type === "event") {
    const payload = readPayloadOrFrame(frame);
    return normalizeProviderEvent(
      payload.event && isObject(payload.event) ? payload.event as Record<string, unknown> : payload,
      toolBuffers,
    );
  }
  if (frame.type === "stream_error") return parseError(readPayloadOrFrame(frame));
  if (frame.type === "start" || frame.type === "message_start") return messageStartFrom(readPayloadOrFrame(frame));
  if (frame.type === "text_delta") return { type: "text_delta", delta: stringValue(readPayloadOrFrame(frame).delta) };
  if (frame.type === "thinking_delta" || frame.type === "reasoning_delta" || frame.type === "reasoning") {
    return { type: "thinking_delta", delta: stringValue(readPayloadOrFrame(frame).delta ?? readPayloadOrFrame(frame).reasoning) };
  }
  if (frame.type === "tool_call") return parseToolCall(readPayloadOrFrame(frame));
  if (frame.type === "toolcall_start" || frame.type === "toolcall_delta" || frame.type === "toolcall_end") {
    return normalizeProviderEvent(readPayloadOrFrame(frame), toolBuffers);
  }
  if (frame.type === "message_end" || frame.type === "done" || frame.type === "result") return messageEndFrom(readPayloadOrFrame(frame));
  if (frame.type === "error") return parseError(readPayloadOrFrame(frame));
  return undefined;
}

function normalizeProviderEvent(
  payload: Record<string, unknown>,
  toolBuffers: Map<number, { id?: string; name?: string; args: string }>,
): ProviderStreamEvent | undefined {
  const type = stringValue(payload.type === "event" ? payload.event_type : payload.type ?? payload.event_type);
  if (type === "start") return messageStartFrom(payload.message && isObject(payload.message) ? payload.message : payload);
  if (type === "text_delta") return { type: "text_delta", delta: stringValue(payload.delta) };
  if (type === "thinking_delta" || type === "reasoning_delta" || type === "reasoning") {
    return { type: "thinking_delta", delta: stringValue(payload.delta ?? payload.reasoning) };
  }
  if (type === "toolcall_start") {
    const index = numericValue(payload.content_index, toolBuffers.size);
    toolBuffers.set(index, { id: optionalString(payload.id), name: optionalString(payload.name), args: "" });
    return undefined;
  }
  if (type === "toolcall_delta") {
    const index = numericValue(payload.content_index, 0);
    const existing = toolBuffers.get(index) ?? { args: "" };
    existing.args += stringValue(payload.delta);
    toolBuffers.set(index, existing);
    return undefined;
  }
  if (type === "toolcall_end") return parseBufferedToolCall(payload, toolBuffers);
  if (type === "tool_call") return parseToolCall(payload);
  if (type === "done" || type === "message_end") return messageEndFrom(payload);
  if (type === "stream_error" || type === "error") return parseError(payload);
  return undefined;
}

function normalizeAgentFrame(
  frame: StdioFrame,
  toolBuffers: Map<number, { id?: string; name?: string; args: string }>,
): AgentStreamEvent[] {
  if (frame.type === "agent_result") return [agentEndFrom(readJsonStringPayload(frame, "result_json"))];
  if (frame.type === "agent_error") return [parseError(readPayloadOrFrame(frame))];
  if (frame.type === "agent_event") return normalizeAgentEvent(readJsonStringPayload(frame, "event_json"), toolBuffers);
  if (frame.type === "event") {
    const payload = readPayloadOrFrame(frame);
    const inner = payload.event && isObject(payload.event) ? payload.event as Record<string, unknown> : payload;
    const type = stringValue(inner.type ?? inner.event_type);
    if (isAgentEventType(type)) return normalizeAgentEvent(inner, toolBuffers);
  }
  const providerEvent = normalizeProviderFrame(frame, toolBuffers);
  return providerEvent ? [providerEvent] : [];
}

function normalizeAgentEvent(
  event: Record<string, unknown>,
  toolBuffers: Map<number, { id?: string; name?: string; args: string }>,
): AgentStreamEvent[] {
  const type = stringValue(event.type ?? firstKey(event));
  const data = event.type ? event : (event[type] && isObject(event[type]) ? event[type] as Record<string, unknown> : event);
  switch (type) {
    case "agent_start":
      return [{ type: "agent_start", ...(optionalString(data.session_id) ? { session_id: optionalString(data.session_id) } : {}) }];
    case "turn_start":
      return [{ type: "turn_start" }];
    case "turn_end":
      return [{ type: "turn_end", ...(optionalString(data.stop_reason) ? { stop_reason: optionalString(data.stop_reason) } : {}) }];
    case "tool_execution_start":
      return [{ type: "tool_execution_start", tool_call_id: stringValue(data.tool_call_id), tool_name: stringValue(data.tool_name) }];
    case "tool_execution_end":
      return [{ type: "tool_execution_end", tool_call_id: stringValue(data.tool_call_id), ...(typeof data.is_error === "boolean" ? { is_error: data.is_error } : {}) }];
    case "tool_execution_update":
      return [];
    case "agent_end":
      return [agentEndFrom(data)];
    case "message_start":
      return [messageStartFrom(data.message && isObject(data.message) ? data.message : data)];
    case "message_update": {
      const inner = data.event && isObject(data.event) ? data.event as Record<string, unknown> : data;
      const providerEvent = normalizeProviderEvent(inner, toolBuffers);
      return providerEvent ? [providerEvent] : [];
    }
    case "text_delta":
    case "thinking_delta":
    case "reasoning_delta":
    case "reasoning":
    case "toolcall_start":
    case "toolcall_delta":
    case "toolcall_end":
    case "tool_call": {
      const providerEvent = normalizeProviderEvent(event, toolBuffers);
      return providerEvent ? [providerEvent] : [];
    }
    case "message_end":
      return [messageEndFrom(data.message && isObject(data.message) ? data.message : data)];
    case "error":
      return [parseError(data)];
    default:
      return [];
  }
}

function parseCompletionResponse(raw: unknown): CompletionResponse {
  const data = isObject(raw) ? raw : {};
  const message = data.message && isObject(data.message) ? data.message : data;
  const content = parseContent(message.content);
  return {
    message: { role: "assistant", content },
    usage: parseUsage(message.usage ?? data.usage ?? data),
    provider_id: stringValue(message.provider_id ?? message.provider ?? data.provider_id ?? data.provider),
    api: stringValue(message.api ?? data.api),
    model_id: stringValue(message.model_id ?? message.model ?? data.model_id ?? data.model),
    stop_reason: optionalString(message.stop_reason ?? data.stop_reason ?? data.reason),
  };
}

function parseAgentRunResponse(raw: unknown): AgentRunResponse {
  const data = isObject(raw) ? raw : {};
  if (data.message && isObject(data.message)) return parseCompletionResponse(data);

  const messages = Array.isArray(data.messages) ? data.messages.filter(isObject) : [];
  const assistantMessage = [...messages].reverse().find((message) => message.role === "assistant") ?? data;
  const terminal = data.result && isObject(data.result) ? data.result : data;
  return buildCompletionResponseFromMessage(assistantMessage, terminal);
}

function buildAgentRunResponseFromEvents(events: AgentStreamEvent[]): AgentRunResponse {
  const reversed = [...events].reverse();
  const terminal = reversed.find((event) => event.type === "message_end" || event.type === "agent_end");
  const messageEnd = reversed.find((event) => event.type === "message_end");
  const finalMessageEvents = finalAssistantMessageEvents(events);
  const start = finalMessageEvents.find((event) => event.type === "message_start") as Extract<ProviderStreamEvent, { type: "message_start" }> | undefined;
  const content = contentFromEvents(finalMessageEvents);
  return {
    message: { role: "assistant", content },
    usage: (terminal && "usage" in terminal ? terminal.usage : undefined) ?? messageEnd?.usage,
    provider_id: start?.provider_id ?? "",
    api: start?.api ?? "",
    model_id: start?.model_id ?? "",
    stop_reason: terminal && "stop_reason" in terminal ? terminal.stop_reason : undefined,
  };
}

function finalAssistantMessageEvents(events: AgentStreamEvent[]): AgentStreamEvent[] {
  const startIndex = events.map((event) => event.type).lastIndexOf("message_start");
  if (startIndex < 0) return events;
  const endOffset = events.slice(startIndex + 1).findIndex((event) => event.type === "message_end");
  const endIndex = endOffset < 0 ? events.length : startIndex + 1 + endOffset + 1;
  return events.slice(startIndex, endIndex);
}

function buildCompletionResponseFromMessage(
  message: Record<string, unknown>,
  terminal: Record<string, unknown>,
): CompletionResponse {
  return {
    message: { role: "assistant", content: parseContent(message.content) },
    usage: parseUsage(message.usage ?? terminal.usage ?? terminal),
    provider_id: stringValue(message.provider_id ?? message.provider ?? terminal.provider_id ?? terminal.provider),
    api: stringValue(message.api ?? terminal.api),
    model_id: stringValue(message.model_id ?? message.model ?? terminal.model_id ?? terminal.model),
    stop_reason: optionalString(message.stop_reason ?? terminal.stop_reason ?? terminal.reason),
  };
}

function contentFromEvents(events: AgentStreamEvent[]): string | ContentPart[] {
  const parts: ContentPart[] = [];
  let text = "";
  for (const event of events) {
    if (event.type === "text_delta") {
      text += event.delta;
      continue;
    }
    if (event.type === "thinking_delta") {
      if (text.length > 0) {
        parts.push({ type: "text", text });
        text = "";
      }
      parts.push({ type: "thinking", thinking: event.delta });
      continue;
    }
    if (event.type === "tool_call") {
      if (text.length > 0) {
        parts.push({ type: "text", text });
        text = "";
      }
      parts.push({
        type: "tool_call",
        tool_call_id: event.tool_call_id,
        name: event.name,
        arguments_json: event.arguments_json,
      });
    }
  }
  if (parts.length === 0) return text;
  if (text.length > 0) parts.push({ type: "text", text });
  return parts;
}

function parseContent(raw: unknown): string | ContentPart[] {
  if (typeof raw === "string") return raw;
  if (!Array.isArray(raw)) return "";
  return raw.map((part) => {
    if (!isObject(part)) return { type: "text", text: String(part) } as ContentPart;
    if (part.type === "tool_call") return { type: "tool_call", tool_call_id: stringValue(part.tool_call_id ?? part.id), name: stringValue(part.name), arguments_json: stringValue(part.arguments_json) };
    return part as ContentPart;
  });
}

function messageStartFrom(data: Record<string, unknown>): ProviderStreamEvent {
  return {
    type: "message_start",
    ...(optionalString(data.provider_id ?? data.provider) ? { provider_id: optionalString(data.provider_id ?? data.provider) } : {}),
    ...(optionalString(data.api) ? { api: optionalString(data.api) } : {}),
    ...(optionalString(data.model_id ?? data.model) ? { model_id: optionalString(data.model_id ?? data.model) } : {}),
  };
}

function messageEndFrom(data: Record<string, unknown>): ProviderStreamEvent {
  const message = data.message && isObject(data.message) ? data.message as Record<string, unknown> : data;
  return { type: "message_end", usage: parseUsage(message.usage ?? data.usage ?? message), stop_reason: optionalString(data.stop_reason ?? data.reason ?? message.stop_reason) };
}

function agentEndFrom(data: Record<string, unknown>): AgentStreamEvent {
  return { type: "agent_end", usage: parseUsage(data.usage ?? data), stop_reason: optionalString(data.stop_reason ?? data.reason) };
}

function parseToolCall(data: Record<string, unknown>): ProviderStreamEvent {
  return { type: "tool_call", tool_call_id: stringValue(data.tool_call_id ?? data.id), name: stringValue(data.name), arguments_json: stringValue(data.arguments_json) };
}

function parseBufferedToolCall(
  data: Record<string, unknown>,
  toolBuffers: Map<number, { id?: string; name?: string; args: string }>,
): ProviderStreamEvent {
  const index = numericValue(data.content_index, 0);
  const buffered = toolBuffers.get(index);
  toolBuffers.delete(index);
  return { type: "tool_call", tool_call_id: stringValue(data.tool_call_id ?? data.id ?? buffered?.id), name: stringValue(data.name ?? buffered?.name), arguments_json: stringValue(data.arguments_json ?? buffered?.args) };
}

function parseError(data: Record<string, unknown>): ProviderStreamEvent {
  return {
    type: "error",
    message: stringValue(data.message ?? data.error_message ?? data.reason, "stream error"),
    code: optionalString(data.code ?? data.error_code),
    ...(optionalString(data.provider_id) ? { provider_id: optionalString(data.provider_id) } : {}),
  };
}

function parseUsage(raw: unknown): UsageSummary | undefined {
  if (!isObject(raw)) return undefined;
  const input = raw.input ?? raw.input_tokens;
  const output = raw.output ?? raw.output_tokens;
  if (typeof input !== "number" || typeof output !== "number") return undefined;
  const usage: UsageSummary = { input, output };
  if (typeof raw.cache_read === "number") usage.cache_read = raw.cache_read;
  if (typeof raw.cache_write === "number") usage.cache_write = raw.cache_write;
  return usage;
}

function addUsage(left: UsageSummary, right: UsageSummary): UsageSummary {
  return {
    input: left.input + right.input,
    output: left.output + right.output,
    cache_read: (left.cache_read ?? 0) + (right.cache_read ?? 0),
    cache_write: (left.cache_write ?? 0) + (right.cache_write ?? 0),
  };
}

function nackToStreamError(frame: StdioFrame, fallbackProviderId?: string): MakaiStreamError {
  const payload = readPayloadOrFrame(frame);
  const code = optionalString(payload.error_code);
  let providerId = optionalString(payload.provider_id);
  if (!providerId && code === "auth_required") {
    providerId = fallbackProviderId;
  }
  return new MakaiStreamError(stringValue(payload.reason, "request rejected"), {
    kind: "provider_error",
    code,
    provider_id: providerId,
  });
}

function streamErrorFrameToError(frame: StdioFrame): MakaiStreamError {
  const payload = readPayloadOrFrame(frame);
  return new MakaiStreamError(stringValue(payload.message ?? payload.reason, "stream error"), {
    kind: "provider_error",
    code: optionalString(payload.code ?? payload.error_code),
    provider_id: optionalString(payload.provider_id),
  });
}

function readPayloadOrFrame(frame: StdioFrame): Record<string, unknown> {
  return frame.payload && isObject(frame.payload) ? frame.payload : frame;
}

function readJsonStringPayload(frame: StdioFrame, key: string): Record<string, unknown> {
  const payload = readPayloadOrFrame(frame);
  const json = payload[key] ?? payload.event_json ?? payload.result_json;
  if (typeof json === "string") {
    try {
      const parsed = JSON.parse(json) as unknown;
      return isObject(parsed) ? parsed : {};
    } catch {
      throw new MakaiStreamError(`malformed JSON in ${key}`, { kind: "transport_error" });
    }
  }
  return payload;
}

function isAgentEventType(type: string): boolean {
  return type === "agent_start" ||
    type === "agent_end" ||
    type === "turn_start" ||
    type === "turn_end" ||
    type === "tool_execution_start" ||
    type === "tool_execution_end" ||
    type === "tool_execution_update";
}

function stringValue(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function numericValue(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function firstKey(value: Record<string, unknown>): string {
  return Object.keys(value)[0] ?? "";
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isRetryableAuthError(error: unknown): error is MakaiStreamError {
  return error instanceof MakaiStreamError && error.code === "auth_required";
}

function providerIdFromRequest(request: ProviderCompleteRequest | AgentRunRequest): string | undefined {
  // model_ref is opaque per spec, but canonical refs carry provider info.
  // We derive a fallback provider_id for auth retry only when the runtime
  // error frame does not include one.
  try {
    const parsed = parseModelRef(request.model_ref);
    return parsed.providerId;
  } catch {
    // Best-effort: extract provider even when model_id is non-canonical
    // so auto_once auth retry can still target the right provider.
    const slashIndex = request.model_ref.indexOf("/");
    const atIndex = request.model_ref.indexOf("@");
    if (slashIndex !== -1 && atIndex !== -1 && slashIndex < atIndex) {
      const provider = request.model_ref.slice(0, slashIndex);
      if (provider.length > 0) return provider;
    }
    return undefined;
  }
}

async function withAuthRetry<T>(
  operation: () => Promise<T>,
  options: {
    auth?: MakaiAuthApi;
    authHandlers?: AuthFlowHandlers;
    authRetryPolicy?: RunOptions["auth_retry_policy"];
    fallbackProviderId?: string;
    beforeRetry?: () => void;
  },
): Promise<T> {
  try {
    return await operation();
  } catch (error) {
    if (isRetryableAuthError(error) && options.authRetryPolicy === "auto_once" && options.auth) {
      const providerId = error.provider_id ?? options.fallbackProviderId;
      if (!providerId) throw error;
      try {
        await options.auth.login(providerId, options.authHandlers);
      } catch {
        throw error;
      }
      options.beforeRetry?.();
      return await operation();
    }
    throw error;
  }
}

export async function createMakaiClient(options: CreateMakaiClientOptions = {}): Promise<MakaiClient> {
  const { auth: authOptions, responseTimeoutMs, frameTimeoutMs, ...transportOptions } = options;
  const transport = await createMakaiStdioClient(transportOptions);
  await transport.connect();
  const authClient = new MakaiAuthClient(transport, { handlers: authOptions?.handlers, frameTimeoutMs });
  const executionOptions = {
    responseTimeoutMs: responseTimeoutMs ?? frameTimeoutMs,
    authRetryPolicy: authOptions?.auth_retry_policy,
    auth: authClient,
    authHandlers: authOptions?.handlers,
  };
  return {
    auth: authClient,
    models: createMakaiModelsApi(transport, { responseTimeoutMs: responseTimeoutMs ?? frameTimeoutMs }),
    agent: createMakaiAgentApi(transport, executionOptions),
    provider: createMakaiProviderApi(transport, executionOptions),
    close: () => transport.close(),
  };
}
