import { randomUUID } from "node:crypto";
import { MakaiAuthClient, type MakaiAuthApi } from "./auth_protocol";
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

type ExecutionOptions = {
  responseTimeoutMs?: number;
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

  constructor(private readonly transport: MakaiStdioClient, options: ExecutionOptions) {
    this.responseTimeoutMs = options.responseTimeoutMs ?? DEFAULT_RESPONSE_TIMEOUT_MS;
  }

  async complete(request: ProviderCompleteRequest): Promise<ProviderCompleteResponse> {
    const streamId = randomUUID();
    this.transport.send(buildEnvelope("complete_request", streamId, buildExecutionPayload(request)));
    while (true) {
      const frame = await nextFrame(this.transport, streamId, this.responseTimeoutMs);
      if (frame.type === "ack") continue;
      if (frame.type === "nack") throw nackToStreamError(frame);
      if (frame.type === "stream_error") throw streamErrorFrameToError(frame);
      if (frame.type === "result" || frame.type === "complete_response") {
        return parseCompletionResponse(frame.payload ?? frame);
      }
      throw new MakaiStreamError(`unexpected frame type while awaiting provider result: ${String(frame.type)}`, { kind: "transport_error" });
    }
  }

  async *stream(request: ProviderCompleteRequest): AsyncIterable<ProviderStreamEvent> {
    const streamId = randomUUID();
    this.transport.send(buildEnvelope("stream_request", streamId, buildExecutionPayload(request, true)));
    let terminal = false;
    const toolBuffers = new Map<number, { id?: string; name?: string; args: string }>();
    try {
      while (!terminal) {
        const frame = await nextFrame(this.transport, streamId, this.responseTimeoutMs);
        if (frame.type === "ack") continue;
        if (frame.type === "nack") throw nackToStreamError(frame);
        const event = normalizeProviderFrame(frame, toolBuffers);
        if (!event) continue;
        if (event.type === "error") {
          terminal = true;
          throw new MakaiStreamError(event.message, { kind: "provider_error", code: event.code });
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

  constructor(private readonly transport: MakaiStdioClient, options: ExecutionOptions) {
    this.responseTimeoutMs = options.responseTimeoutMs ?? DEFAULT_RESPONSE_TIMEOUT_MS;
  }

  async run(request: AgentRunRequest): Promise<AgentRunResponse> {
    const events: AgentStreamEvent[] = [];
    for await (const event of this.stream(request)) events.push(event);
    const terminal = [...events].reverse().find((event: AgentStreamEvent) => event.type === "message_end" || event.type === "agent_end");
    const messageEnd = [...events].reverse().find((event: AgentStreamEvent) => event.type === "message_end");
    const text = events.filter((event) => event.type === "text_delta").map((event) => event.delta).join("");
    const start = events.find((event) => event.type === "message_start") as Extract<ProviderStreamEvent, { type: "message_start" }> | undefined;
    return {
      message: { role: "assistant", content: text },
      usage: (terminal && "usage" in terminal ? terminal.usage : undefined) ?? messageEnd?.usage,
      provider_id: start?.provider_id ?? "",
      api: start?.api ?? "",
      model_id: start?.model_id ?? "",
      stop_reason: terminal && "stop_reason" in terminal ? terminal.stop_reason : undefined,
    };
  }

  async *stream(request: AgentRunRequest): AsyncIterable<AgentStreamEvent> {
    const streamId = randomUUID();
    this.transport.send(buildEnvelope("agent_run_request", streamId, buildExecutionPayload(request)));
    let terminal = false;
    const toolBuffers = new Map<number, { id?: string; name?: string; args: string }>();
    try {
      while (!terminal) {
        const frame = await nextFrame(this.transport, streamId, this.responseTimeoutMs);
        if (frame.type === "ack") continue;
        if (frame.type === "nack") throw nackToStreamError(frame);
        const events = normalizeAgentFrame(frame, toolBuffers);
        for (const event of events) {
          if (event.type === "error") {
            terminal = true;
            throw new MakaiStreamError(event.message, { kind: "provider_error", code: event.code });
          }
          if (event.type === "agent_end") terminal = true;
          yield event;
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

function buildExecutionPayload(
  request: ProviderCompleteRequest | AgentRunRequest,
  includePartial = false,
): Record<string, unknown> {
  if (!request || typeof request.model_ref !== "string" || request.model_ref.length === 0) {
    throw new MakaiStreamError("request requires opaque model_ref", { kind: "transport_error", code: "invalid_request" });
  }
  if (!Array.isArray(request.messages)) {
    throw new MakaiStreamError("request requires messages array", { kind: "transport_error", code: "invalid_request" });
  }
  const payload: Record<string, unknown> = {
    model_ref: request.model_ref,
    messages: request.messages.map(serializeChatMessage),
  };
  if (request.tools) payload.tools = request.tools.map(serializeTool);
  if (request.options) payload.options = serializeOptions(request.options);
  if (includePartial) payload.include_partial = false;
  return payload;
}

function serializeChatMessage(message: ChatMessage): Record<string, unknown> {
  const out: Record<string, unknown> = { role: message.role, content: message.content };
  if (message.name) out.name = message.name;
  if (message.tool_call_id) out.tool_call_id = message.tool_call_id;
  return out;
}

function serializeTool(tool: ToolDefinition): Record<string, unknown> {
  return {
    name: tool.name,
    description: tool.description,
    parameters_schema_json: tool.parameters_schema_json,
  };
}

function serializeOptions(options: RunOptions): Record<string, unknown> {
  const out: Record<string, unknown> = {};
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

function normalizeProviderFrame(
  frame: StdioFrame,
  toolBuffers: Map<number, { id?: string; name?: string; args: string }>,
): ProviderStreamEvent | undefined {
  if (frame.type === "event") return normalizeProviderEvent(readPayloadOrFrame(frame), toolBuffers);
  if (frame.type === "stream_error") return { type: "error", message: stringValue(readPayloadOrFrame(frame).message, "stream error") };
  if (frame.type === "message_start") return messageStartFrom(readPayloadOrFrame(frame));
  if (frame.type === "text_delta") return { type: "text_delta", delta: stringValue(readPayloadOrFrame(frame).delta) };
  if (frame.type === "thinking_delta" || frame.type === "reasoning_delta" || frame.type === "reasoning") {
    return { type: "thinking_delta", delta: stringValue(readPayloadOrFrame(frame).delta ?? readPayloadOrFrame(frame).reasoning) };
  }
  if (frame.type === "tool_call") return parseToolCall(readPayloadOrFrame(frame));
  if (frame.type === "message_end" || frame.type === "done" || frame.type === "result") return messageEndFrom(readPayloadOrFrame(frame));
  if (frame.type === "error") return parseError(readPayloadOrFrame(frame));
  return undefined;
}

function normalizeProviderEvent(
  payload: Record<string, unknown>,
  toolBuffers: Map<number, { id?: string; name?: string; args: string }>,
): ProviderStreamEvent | undefined {
  const type = stringValue(payload.type ?? payload.event_type);
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
  if (type === "done") return messageEndFrom(payload);
  if (type === "error") return parseError(payload);
  return undefined;
}

function normalizeAgentFrame(
  frame: StdioFrame,
  toolBuffers: Map<number, { id?: string; name?: string; args: string }>,
): AgentStreamEvent[] {
  if (frame.type === "agent_result") return [agentEndFrom(readJsonStringPayload(frame, "result_json"))];
  if (frame.type === "agent_error") return [parseError(readPayloadOrFrame(frame))];
  if (frame.type === "agent_event") return normalizeAgentEvent(readJsonStringPayload(frame, "event_json"), toolBuffers);
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
  return { type: "error", message: stringValue(data.message ?? data.error_message ?? data.reason, "stream error"), code: optionalString(data.code ?? data.error_code ?? data.reason) };
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

function nackToStreamError(frame: StdioFrame): MakaiStreamError {
  const payload = readPayloadOrFrame(frame);
  return new MakaiStreamError(stringValue(payload.reason, "request rejected"), { kind: "provider_error", code: optionalString(payload.error_code) });
}

function streamErrorFrameToError(frame: StdioFrame): MakaiStreamError {
  const payload = readPayloadOrFrame(frame);
  return new MakaiStreamError(stringValue(payload.message ?? payload.reason, "stream error"), { kind: "provider_error", code: optionalString(payload.code ?? payload.error_code) });
}

function readPayloadOrFrame(frame: StdioFrame): Record<string, unknown> {
  return frame.payload && isObject(frame.payload) ? frame.payload : frame;
}

function readJsonStringPayload(frame: StdioFrame, key: string): Record<string, unknown> {
  const payload = readPayloadOrFrame(frame);
  const json = payload[key] ?? payload.event_json ?? payload.result_json;
  if (typeof json === "string") {
    const parsed = JSON.parse(json) as unknown;
    return isObject(parsed) ? parsed : {};
  }
  return payload;
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

export async function createMakaiClient(options: CreateMakaiClientOptions = {}): Promise<MakaiClient> {
  const { auth: authOptions, responseTimeoutMs, frameTimeoutMs, ...transportOptions } = options;
  const transport = await createMakaiStdioClient(transportOptions);
  await transport.connect();
  const executionOptions = { responseTimeoutMs: responseTimeoutMs ?? frameTimeoutMs };
  return {
    auth: new MakaiAuthClient(transport, { handlers: authOptions?.handlers, frameTimeoutMs }),
    models: createMakaiModelsApi(transport, { responseTimeoutMs: responseTimeoutMs ?? frameTimeoutMs }),
    agent: createMakaiAgentApi(transport, executionOptions),
    provider: createMakaiProviderApi(transport, executionOptions),
    close: () => transport.close(),
  };
}
