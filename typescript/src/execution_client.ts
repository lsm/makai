import { randomInt } from "node:crypto";
import { ulid } from "ulid";
import { checkAbort, isAbortError, raceWithAbort } from "./abort_signal";
import { MakaiAuthClient, MakaiAuthError, type AuthFlowHandlers, type MakaiAuthApi } from "./auth_protocol";
import { bestEffortCancelStream, bestEffortCancelAgent, drainStreamFrames, drainSessionFrames } from "./cancel_helpers";
import { parseModelRef } from "./diagnostics/model_ref";
import { getNoopLogger, isNoopLogger, type MakaiLogger } from "./logger";
import { createMakaiModelsApi } from "./models_client";
import { MakaiProtocolError, type MakaiModelsApi } from "./models_types";
import { type CreateMakaiStdioClientOptions, createMakaiStdioClient, MakaiStdioClient, type StdioFrame } from "./stdio_client";
import {
  createTimeoutDiagnostics,
  formatTimeoutMessage,
  isTimeoutLikeError,
  type TimeoutDiagnosticContext,
} from "./timeout_diagnostics";
import {
  MakaiAuthRequiredError,
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
  type TextContentPart,
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
  logger?: MakaiLogger;
};

type AgentToolExecutionResult = string | TextContentPart[];

/** Root Makai SDK client returned by {@link createMakaiClient}. */
export interface MakaiClient {
  auth: MakaiAuthApi;
  models: MakaiModelsApi;
  agent: MakaiAgentModelsApi;
  provider: MakaiProviderApi;
  /**
   * Closes the underlying shared stdio transport.
   *
   * @returns A promise that resolves after the transport closes.
   */
  close(): Promise<void>;
}

/** Options for {@link createMakaiClient}. */
export type CreateMakaiClientOptions = CreateMakaiStdioClientOptions & MakaiClientOptions;

/**
 * Creates a direct provider API facade over an existing stdio transport.
 *
 * @param transport Connected stdio transport.
 * @param options Execution timeout and auth retry options.
 * @returns A {@link MakaiProviderApi} bound to the transport.
 */
export function createMakaiProviderApi(
  transport: MakaiStdioClient,
  options: ExecutionOptions = {},
): MakaiProviderApi {
  return new StdioProviderApi(transport, options);
}

/**
 * Creates an agent execution API facade over an existing stdio transport.
 *
 * @param transport Connected stdio transport.
 * @param options Execution timeout and auth retry options.
 * @returns A {@link MakaiAgentApi} bound to the transport.
 */
export function createMakaiAgentApi(
  transport: MakaiStdioClient,
  options: ExecutionOptions = {},
): MakaiAgentApi {
  return new StdioAgentApi(transport, options);
}

/**
 * Agent API augmented with the model-discovery API for convenience.
 *
 * `client.agent.models` is a separate {@link MakaiModelsApi} instance that
 * delegates to the same underlying model-discovery API over the shared
 * transport as `client.models`. Prefer `client.models` when you don't also
 * need agent methods; use `client.agent.models` when chaining discovery with
 * an agent call on the same namespace.
 */
export interface MakaiAgentModelsApi extends MakaiAgentApi {
  /** Convenience accessor for model discovery; delegates to the same API as {@link MakaiClient.models}. */
  models: MakaiModelsApi;
}

/**
 * Creates an agent API facade with a nested {@link MakaiModelsApi}.
 *
 * @param transport Connected stdio transport.
 * @param options Execution timeout and auth retry options.
 * @returns A {@link MakaiAgentModelsApi} bound to the transport.
 */
export function createMakaiAgentApiWithModels(
  transport: MakaiStdioClient,
  options: ExecutionOptions = {},
): MakaiAgentModelsApi {
  return Object.assign(new StdioAgentApi(transport, options), {
    models: createMakaiModelsApi(transport, { responseTimeoutMs: options.responseTimeoutMs, logger: options.logger }),
  });
}

class StdioProviderApi implements MakaiProviderApi {
  private readonly responseTimeoutMs: number;
  private readonly authRetryPolicy?: RunOptions["auth_retry_policy"];
  private readonly auth?: MakaiAuthApi;
  private readonly authHandlers?: AuthFlowHandlers;
  private readonly logger: MakaiLogger;

  constructor(private readonly transport: MakaiStdioClient, options: ExecutionOptions) {
    this.responseTimeoutMs = options.responseTimeoutMs ?? DEFAULT_RESPONSE_TIMEOUT_MS;
    this.authRetryPolicy = options.authRetryPolicy;
    this.auth = options.auth;
    this.authHandlers = options.authHandlers;
    this.logger = options.logger ?? getNoopLogger();
  }

  async complete(request: ProviderCompleteRequest): Promise<ProviderCompleteResponse> {
    const signal = request.options?.signal;
    checkAbort(signal, "provider.complete aborted before start");
    const effectivePolicy = request.options?.auth_retry_policy ?? this.authRetryPolicy;
    // Track the active stream ID so withAuthRetry can cancel+drain on abort
    // during auth retry (the stream ID is created inside completeOnce).
    const activeStreamId: { value?: string } = {};
    return withAuthRetry(
      () => this.completeOnce(request, effectivePolicy, signal, activeStreamId),
      {
        auth: this.auth,
        authHandlers: this.authHandlers,
        authRetryPolicy: effectivePolicy,
        fallbackProviderId: providerIdFromRequest(request),
        signal,
        logger: this.logger,
        onAbort: () => {
          const streamId = activeStreamId.value;
          if (streamId) {
            bestEffortCancelStream(this.transport, streamId);
            // Fire-and-forget: the aborted nextFrameForStream may still hold
            // withStreamReadLock, so awaiting drain would block until that
            // lock is released (up to responseTimeoutMs). Drain runs in the
            // background instead.
            drainStreamFrames(this.transport, streamId);
          }
        },
      },
    );
  }

  private async completeOnce(request: ProviderCompleteRequest, effectivePolicy: RunOptions["auth_retry_policy"] | undefined, signal?: AbortSignal, activeStreamId?: { value?: string }): Promise<ProviderCompleteResponse> {
    checkAbort(signal, "provider.complete aborted");
    const streamId = ulid();
    if (activeStreamId) activeStreamId.value = streamId;
    const fallbackProviderId = providerIdFromRequest(request);
    if (!isNoopLogger(this.logger)) {
      this.logger.debug("provider: sending complete_request", { stream_id: streamId, model_ref: request.model_ref });
    }
    this.transport.send(buildEnvelope("complete_request", streamId, buildExecutionPayload(request, { authRetryPolicy: effectivePolicy })));
    const timeoutContext = executionTimeoutContext("provider complete_response", this.responseTimeoutMs, streamId, request);
    try {
      while (true) {
        checkAbort(signal, "provider.complete aborted");
        const frame = await raceWithAbort(nextFrame(this.transport, streamId, timeoutContext), signal, "provider.complete aborted");
        if (frame.type === "ack") continue;
        if (frame.type === "nack") throw nackToStreamError(frame, fallbackProviderId);
        if (frame.type === "stream_error") throw streamErrorFrameToError(frame);
        if (frame.type === "result" || frame.type === "complete_response") {
          return parseCompletionResponse(frame.payload ?? frame);
        }
        throw new MakaiStreamError(`unexpected frame type while awaiting provider result: ${String(frame.type)}`, { kind: "transport_error" });
      }
    } catch (error) {
      if (isAbortError(error)) {
        bestEffortCancelStream(this.transport, streamId);
        // Fire-and-forget: avoids blocking behind withStreamReadLock held by
        // the aborted nextFrameForStream call.
        drainStreamFrames(this.transport, streamId);
      }
      throw error;
    }
  }

  async *stream(request: ProviderCompleteRequest): AsyncIterable<ProviderStreamEvent> {
    const signal = request.options?.signal;
    checkAbort(signal, "provider.stream aborted before start");
    const effectivePolicy = request.options?.auth_retry_policy ?? this.authRetryPolicy;
    const fallbackProviderId = providerIdFromRequest(request);
    // Track the active stream ID so abort during auth retry can cancel+drain
    const activeStreamId: { value?: string } = {};
    let attempt = this.streamAttempt(request, effectivePolicy, signal, activeStreamId);
    let iterator = attempt[Symbol.asyncIterator]();
    let yielded = false;
    let retried = false;

    if (!isNoopLogger(this.logger)) {
      this.logger.debug("provider: starting stream", { model_ref: request.model_ref });
    }

    try {
      while (true) {
        checkAbort(signal, "provider.stream aborted");
        let result;
        try {
          result = await raceWithAbort(iterator.next(), signal, "provider.stream aborted");
        } catch (error) {
          if (isAbortError(error)) {
            // Cancel+drain handled by outer catch to avoid triple-send.
            throw error;
          }
          if (!yielded && !retried && isRetryableAuthError(error) && effectivePolicy === "auto_once" && this.auth) {
            const providerId = error.provider_id ?? fallbackProviderId;
            if (providerId) {
              try {
                await raceWithAbort(this.auth.login(providerId, this.authHandlers, { signal }), signal, "provider.stream aborted during auth retry");
              } catch (authError) {
                if (isAbortError(authError)) {
                  // Cancel+drain handled by outer catch.
                  throw authError;
                }
                throw authRequiredError(providerId, error.message);
              }
              retried = true;
              attempt = this.streamAttempt(request, effectivePolicy, signal, activeStreamId);
              iterator = attempt[Symbol.asyncIterator]();
              continue;
            }
          }
          if (isRetryableAuthError(error)) {
            const providerId = error.provider_id ?? fallbackProviderId;
            if (providerId) throw authRequiredError(providerId, error.message);
          }
          throw error;
        }
        if (result.done) return;
        yielded = true;
        yield result.value;
      }
    } catch (error) {
      if (isAbortError(error)) {
        const streamId = activeStreamId.value;
        if (streamId) {
          bestEffortCancelStream(this.transport, streamId);
          // Fire-and-forget: avoids blocking behind withStreamReadLock held by
          // the aborted nextFrameForStream call from streamAttempt.
          drainStreamFrames(this.transport, streamId);
        }
      }
      throw error;
    }
  }

  private async *streamAttempt(request: ProviderCompleteRequest, effectivePolicy: RunOptions["auth_retry_policy"] | undefined, signal?: AbortSignal, activeStreamId?: { value?: string }): AsyncIterable<ProviderStreamEvent> {
    checkAbort(signal, "provider.stream aborted");
    const streamId = ulid();
    if (activeStreamId) activeStreamId.value = streamId;
    const fallbackProviderId = providerIdFromRequest(request);
    if (!isNoopLogger(this.logger)) {
      this.logger.debug("provider: sending stream_request", { stream_id: streamId, model_ref: request.model_ref });
    }
    this.transport.send(buildEnvelope("stream_request", streamId, buildExecutionPayload(request, { suppressPartial: true, authRetryPolicy: effectivePolicy })));
    const timeoutContext = executionTimeoutContext("provider stream event", this.responseTimeoutMs, streamId, request);
    let terminal = false;
    const toolBuffers = new Map<number, { id?: string; name?: string; args: string }>();
    if (!isNoopLogger(this.logger)) {
      this.logger.debug("provider: stream started", { stream_id: streamId });
    }
    try {
      while (!terminal) {
        checkAbort(signal, "provider.stream aborted");
        const frame = await raceWithAbort(nextFrame(this.transport, streamId, timeoutContext), signal, "provider.stream aborted");
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
      if (error instanceof MakaiStreamError) {
        this.logger.error("provider: stream error", { kind: error.kind, code: error.code, message: error.message });
        throw error;
      }
      if (isAbortError(error)) {
        // Cancel+drain handled by outer stream() catch to avoid triple-send.
        throw error;
      }
      this.logger.error("provider: unexpected stream error", { error: error instanceof Error ? error.message : String(error) });
      throw new MakaiStreamError(error instanceof Error ? error.message : String(error), { kind: "transport_error" });
    }
  }
}

class StdioAgentApi implements MakaiAgentApi {
  private readonly responseTimeoutMs: number;
  private readonly authRetryPolicy?: RunOptions["auth_retry_policy"];
  private readonly auth?: MakaiAuthApi;
  private readonly authHandlers?: AuthFlowHandlers;
  private readonly logger: MakaiLogger;

  constructor(private readonly transport: MakaiStdioClient, options: ExecutionOptions) {
    this.responseTimeoutMs = options.responseTimeoutMs ?? DEFAULT_RESPONSE_TIMEOUT_MS;
    this.authRetryPolicy = options.authRetryPolicy;
    this.auth = options.auth;
    this.authHandlers = options.authHandlers;
    this.logger = options.logger ?? getNoopLogger();
  }

  async run(request: AgentRunRequest): Promise<AgentRunResponse> {
    const signal = request.options?.signal;
    checkAbort(signal, "agent.run aborted before start");
    const effectivePolicy = request.options?.auth_retry_policy ?? this.authRetryPolicy;
    let retryRequest = request;
    // Track the active session ID so withAuthRetry can cancel+drain on abort
    // during auth retry (the session ID is created inside runOnce).
    const activeSessionId: { value?: string } = {};
    return withAuthRetry(
      () => this.runOnce(retryRequest, effectivePolicy, signal, activeSessionId),
      {
        auth: this.auth,
        authHandlers: this.authHandlers,
        authRetryPolicy: effectivePolicy,
        fallbackProviderId: providerIdFromRequest(request),
        signal,
        logger: this.logger,
        beforeRetry: () => {
          retryRequest = {
            ...request,
            options: { ...request.options, session_id: generateNanoId() },
          };
        },
        onAbort: () => {
          const sessionId = activeSessionId.value;
          if (sessionId) {
            bestEffortCancelAgent(this.transport, sessionId);
            // Fire-and-forget: avoids blocking behind withStreamReadLock.
            drainSessionFrames(this.transport, sessionId);
          }
        },
      },
    );
  }

  private async runOnce(request: AgentRunRequest, effectivePolicy: RunOptions["auth_retry_policy"] | undefined, signal?: AbortSignal, activeSessionId?: { value?: string }): Promise<AgentRunResponse> {
    checkAbort(signal, "agent.run aborted");
    const sessionId = agentSessionId(request);
    if (activeSessionId) activeSessionId.value = sessionId;
    const fallbackProviderId = providerIdFromRequest(request);
    if (!isNoopLogger(this.logger)) {
      this.logger.debug("agent: sending agent_start", { session_id: sessionId, model_ref: request.model_ref });
    }
    this.transport.send(buildAgentEnvelope("agent_start", sessionId, 1, buildAgentStartPayload(request, sessionId)));
    const timeoutContext = agentTimeoutContext("agent result", this.responseTimeoutMs, sessionId, request);
    const events: AgentStreamEvent[] = [];
    const toolBuffers = new Map<number, { id?: string; name?: string; args: string }>();
    let messageSent = false;
    try {
      while (true) {
        checkAbort(signal, "agent.run aborted");
        const frame = await raceWithAbort(nextAgentFrame(this.transport, sessionId, timeoutContext), signal, "agent.run aborted");
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
        if (frame.type === "tool_execute") {
          this.transport.send(await executeAgentToolFrame(frame, request.tools ?? []));
          continue;
        }

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
    } catch (error) {
      if (isAbortError(error)) {
        bestEffortCancelAgent(this.transport, sessionId);
        // Fire-and-forget: avoids blocking behind withStreamReadLock.
        drainSessionFrames(this.transport, sessionId);
      }
      throw error;
    }
  }

  async *stream(request: AgentRunRequest): AsyncIterable<AgentStreamEvent> {
    const signal = request.options?.signal;
    checkAbort(signal, "agent.stream aborted before start");
    const effectivePolicy = request.options?.auth_retry_policy ?? this.authRetryPolicy;
    const fallbackProviderId = providerIdFromRequest(request);
    let streamRequest = request;
    // Track the active session ID so abort during auth retry can cancel+drain
    const activeSessionId: { value?: string } = {};
    let attempt = this.streamAttempt(streamRequest, effectivePolicy, signal, activeSessionId);
    let iterator = attempt[Symbol.asyncIterator]();
    let yielded = false;
    let retried = false;

    if (!isNoopLogger(this.logger)) {
      this.logger.debug("agent: starting stream", { model_ref: request.model_ref });
    }

    try {
      while (true) {
        checkAbort(signal, "agent.stream aborted");
        let result;
        try {
          result = await raceWithAbort(iterator.next(), signal, "agent.stream aborted");
        } catch (error) {
          if (isAbortError(error)) {
            // Cancel+drain handled by outer catch to avoid triple-send.
            throw error;
          }
          if (!yielded && !retried && isRetryableAuthError(error) && effectivePolicy === "auto_once" && this.auth) {
            const providerId = error.provider_id ?? fallbackProviderId;
            if (providerId) {
              try {
                await raceWithAbort(this.auth.login(providerId, this.authHandlers, { signal }), signal, "agent.stream aborted during auth retry");
              } catch (authError) {
                if (isAbortError(authError)) {
                  // Cancel+drain handled by outer catch.
                  throw authError;
                }
                throw authRequiredError(providerId, error.message);
              }
              retried = true;
              streamRequest = {
                ...request,
                options: { ...request.options, session_id: generateNanoId() },
              };
              attempt = this.streamAttempt(streamRequest, effectivePolicy, signal, activeSessionId);
              iterator = attempt[Symbol.asyncIterator]();
              continue;
            }
          }
          if (isRetryableAuthError(error)) {
            const providerId = error.provider_id ?? fallbackProviderId;
            if (providerId) throw authRequiredError(providerId, error.message);
          }
          throw error;
        }
        if (result.done) return;
        yielded = true;
        yield result.value;
      }
    } catch (error) {
      if (isAbortError(error)) {
        const sessionId = activeSessionId.value;
        if (sessionId) {
          bestEffortCancelAgent(this.transport, sessionId);
          // Fire-and-forget: avoids blocking behind withStreamReadLock.
          drainSessionFrames(this.transport, sessionId);
        }
      }
      throw error;
    }
  }

  private async *streamAttempt(request: AgentRunRequest, effectivePolicy: RunOptions["auth_retry_policy"] | undefined, signal?: AbortSignal, activeSessionId?: { value?: string }): AsyncIterable<AgentStreamEvent> {
    checkAbort(signal, "agent.stream aborted");
    const sessionId = agentSessionId(request);
    if (activeSessionId) activeSessionId.value = sessionId;
    const fallbackProviderId = providerIdFromRequest(request);
    if (!isNoopLogger(this.logger)) {
      this.logger.debug("agent: sending agent_start", { session_id: sessionId, model_ref: request.model_ref });
    }
    this.transport.send(buildAgentEnvelope("agent_start", sessionId, 1, buildAgentStartPayload(request, sessionId)));
    const timeoutContext = agentTimeoutContext("agent stream event", this.responseTimeoutMs, sessionId, request);
    let terminal = false;
    let messageSent = false;
    let started = false;
    let aggregateUsage: UsageSummary | undefined;
    const toolBuffers = new Map<number, { id?: string; name?: string; args: string }>();
    if (!isNoopLogger(this.logger)) {
      this.logger.debug("agent: stream started", { session_id: sessionId });
    }
    try {
      while (!terminal) {
        checkAbort(signal, "agent.stream aborted");
        const frame = await raceWithAbort(nextAgentFrame(this.transport, sessionId, timeoutContext), signal, "agent.stream aborted");
        if (frame.type === "ack") continue;
        if (frame.type === "nack") throw nackToStreamError(frame, fallbackProviderId);
        if (frame.type === "agent_started" && !messageSent) {
          this.transport.send(buildAgentEnvelope("agent_message", sessionId, 2, buildAgentMessagePayload(request, sessionId, effectivePolicy)));
          messageSent = true;
          continue;
        }
        if (frame.type === "tool_execute") {
          this.transport.send(await executeAgentToolFrame(frame, request.tools ?? []));
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
            const usage = aggregateUsage ?? event.usage;
            event = usage ? { ...event, usage } : { ...event };
            if (!usage) delete event.usage;
            terminal = true;
          } else if (event.type === "error") {
            terminal = true;
          }
          yield event;
          if (terminal) break;
        }
      }
    } catch (error) {
      if (error instanceof MakaiStreamError) {
        this.logger.error("agent: stream error", { kind: error.kind, code: error.code, message: error.message });
        throw error;
      }
      if (isAbortError(error)) {
        // Cancel+drain handled by outer agent.stream() catch to avoid triple-send.
        throw error;
      }
      this.logger.error("agent: unexpected stream error", { error: error instanceof Error ? error.message : String(error) });
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

function buildAgentReplyEnvelope(type: string, requestFrame: StdioFrame, payload: Record<string, unknown>): StdioFrame {
  return {
    type,
    session_id: requestFrame.session_id,
    message_id: ulid(),
    sequence: numericValue(requestFrame.sequence, 0) + 1,
    timestamp: Date.now(),
    version: ENVELOPE_VERSION,
    in_reply_to: requestFrame.message_id,
    payload,
  };
}

async function executeAgentToolFrame(frame: StdioFrame, tools: ToolDefinition[]): Promise<StdioFrame> {
  const payload = readPayloadOrFrame(frame);
  const toolCallId = stringValue(payload.tool_call_id);
  const toolName = stringValue(payload.tool_name);
  const argsJson = stringValue(payload.args_json);
  const tool = tools.find((candidate) => candidate.name === toolName);

  if (!tool?.execute) {
    return buildToolResultEnvelope(frame, toolCallId, `Tool '${toolName}' is not executable by this client`, true);
  }

  try {
    const args = parseToolArguments(argsJson);
    const result = await tool.execute(args, { tool_call_id: toolCallId, tool_name: toolName, args_json: argsJson });
    return buildToolResultEnvelope(frame, toolCallId, result, false);
  } catch (error) {
    return buildToolResultEnvelope(frame, toolCallId, error instanceof Error ? error.message : String(error), true);
  }
}

function buildToolResultEnvelope(frame: StdioFrame, toolCallId: string, result: AgentToolExecutionResult, isError: boolean): StdioFrame {
  return buildAgentReplyEnvelope("tool_result", frame, {
    tool_call_id: toolCallId,
    result_json: serializeToolResultContent(result),
    is_error: isError,
  });
}

function parseToolArguments(argsJson: string): Record<string, unknown> {
  const parsed = argsJson.length > 0 ? JSON.parse(argsJson) : {};
  if (!isObject(parsed)) throw new Error("tool arguments must be a JSON object");
  return parsed;
}

function serializeToolResultContent(result: AgentToolExecutionResult): string {
  if (typeof result === "string") return JSON.stringify([{ type: "text", text: result }]);
  return JSON.stringify(result);
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

// Must accommodate max valid canonical ref: 256 (provider) + 1 (/) + 256 (api) + 1 (@) +
// 512 model_id bytes fully percent-encoded (512 * 3 = 1536) = 2050 chars.  Using 4096
// for a clean power-of-2 cap with margin against pathological multi-KB strings.
const MAX_MODEL_REF_LENGTH = 4096;
const MAX_IDENTIFIER_LENGTH = 256;
const MAX_MODEL_FIELD_LENGTH = 512;

function validateExecutionRequest(request: ProviderCompleteRequest | AgentRunRequest): void {
  if (!request || typeof request.model_ref !== "string" || request.model_ref.length === 0) {
    throw new TypeError("request requires opaque model_ref");
  }
  if (request.model_ref.length > MAX_MODEL_REF_LENGTH) {
    throw new MakaiProtocolError(
      `model_ref exceeds maximum length of ${MAX_MODEL_REF_LENGTH} characters`,
      "invalid_request",
    );
  }
  validateModelRefSegments(request.model_ref);
  if (!Array.isArray(request.messages)) {
    throw new TypeError("request requires messages array");
  }
}

/**
 * Best-effort segment-level length validation on model_ref.
 * Tries canonical parse first, then fallback slice extraction.
 * When neither applies (fully opaque ref), validates total length
 * against MAX_MODEL_FIELD_LENGTH since the entire ref becomes model.id/model.name
 * which the server caps at that limit.
 */
function validateModelRefSegments(modelRef: string): void {
  try {
    const parsed = parseModelRef(modelRef);
    validateModelSegments(parsed.providerId, parsed.api, parsed.modelId);
    return;
  } catch {
    // Not a canonical ref — try fallback extraction
  }
  const slashIndex = modelRef.indexOf("/");
  const atIndex = modelRef.indexOf("@");
  if (slashIndex !== -1 && atIndex !== -1 && slashIndex < atIndex) {
    const provider = modelRef.slice(0, slashIndex);
    const api = modelRef.slice(slashIndex + 1, atIndex);
    const id = modelRef.slice(atIndex + 1);
    if (provider.length > 0 && api.length > 0) {
      validateModelSegments(provider, api, id);
      return;
    }
  }
  // Fully opaque ref: the entire string becomes model.id/model.name on the wire.
  // The server caps those fields at MAX_MODEL_FIELD_LENGTH (512).
  if (modelRef.length > MAX_MODEL_FIELD_LENGTH) {
    throw new MakaiProtocolError(
      `model_ref exceeds maximum length of ${MAX_MODEL_FIELD_LENGTH} characters for opaque refs`,
      "invalid_request",
    );
  }
}

function modelFromRef(modelRef: string): Record<string, unknown> {
  try {
    const parsed = parseModelRef(modelRef);
    validateModelSegments(parsed.providerId, parsed.api, parsed.modelId);
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
        validateModelSegments(provider, api, id);
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

function validateModelSegments(provider: string, api: string, id: string): void {
  if (provider.length > MAX_IDENTIFIER_LENGTH) {
    throw new MakaiProtocolError(
      `model_ref provider segment exceeds maximum length of ${MAX_IDENTIFIER_LENGTH} characters`,
      "invalid_request",
    );
  }
  if (api.length > MAX_IDENTIFIER_LENGTH) {
    throw new MakaiProtocolError(
      `model_ref api segment exceeds maximum length of ${MAX_IDENTIFIER_LENGTH} characters`,
      "invalid_request",
    );
  }
  if (id.length > MAX_MODEL_FIELD_LENGTH) {
    throw new MakaiProtocolError(
      `model_ref model_id segment exceeds maximum length of ${MAX_MODEL_FIELD_LENGTH} characters`,
      "invalid_request",
    );
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

async function nextFrame(transport: MakaiStdioClient, streamId: string, context: TimeoutDiagnosticContext): Promise<StdioFrame> {
  try {
    return await transport.nextFrameForStream(streamId, context.timeout_ms);
  } catch (error) {
    throw timeoutAwareStreamError(error, context);
  }
}

async function nextAgentFrame(transport: MakaiStdioClient, sessionId: string, context: TimeoutDiagnosticContext): Promise<StdioFrame> {
  try {
    return await transport.nextFrameForSession(sessionId, context.timeout_ms);
  } catch (error) {
    throw timeoutAwareStreamError(error, context);
  }
}

function timeoutAwareStreamError(error: unknown, context: TimeoutDiagnosticContext): MakaiStreamError {
  if (isTimeoutLikeError(error)) {
    return new MakaiStreamError(formatTimeoutMessage(context), {
      kind: "transport_error",
      diagnostics: createTimeoutDiagnostics(context),
    });
  }
  return new MakaiStreamError(error instanceof Error ? error.message : String(error), { kind: "transport_error" });
}

function executionTimeoutContext(
  operation: string,
  timeoutMs: number,
  streamId: string,
  request: ProviderCompleteRequest | AgentRunRequest,
): TimeoutDiagnosticContext {
  const parsed = safeParseModelRef(request.model_ref);
  return {
    operation,
    timeout_ms: timeoutMs,
    stream_id: streamId,
    message_id: streamId,
    provider_id: parsed?.providerId,
    api: parsed?.api,
    model_ref: request.model_ref,
    model_id: parsed?.modelId,
  };
}

function agentTimeoutContext(
  operation: string,
  timeoutMs: number,
  sessionId: string,
  request: AgentRunRequest,
): TimeoutDiagnosticContext {
  const parsed = safeParseModelRef(request.model_ref);
  return {
    operation,
    timeout_ms: timeoutMs,
    session_id: sessionId,
    provider_id: parsed?.providerId,
    api: parsed?.api,
    model_ref: request.model_ref,
    model_id: parsed?.modelId,
  };
}

function safeParseModelRef(modelRef: string): ReturnType<typeof parseModelRef> | undefined {
  try {
    return parseModelRef(modelRef);
  } catch {
    return undefined;
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
    const payload = eventEnvelopePayload(frame);
    const inner = payload.event && isObject(payload.event) ? payload.event as Record<string, unknown> : payload;
    const type = eventKind(inner);
    if (isAgentEventType(type)) return normalizeAgentEvent({ ...inner, type }, toolBuffers);
  }
  const providerEvent = normalizeProviderFrame(frame, toolBuffers);
  return providerEvent ? [providerEvent] : [];
}

function normalizeAgentEvent(
  event: Record<string, unknown>,
  toolBuffers: Map<number, { id?: string; name?: string; args: string }>,
): AgentStreamEvent[] {
  const type = eventKind(event);
  const data = event.type || event.event_type ? event : (event[type] && isObject(event[type]) ? event[type] as Record<string, unknown> : event);
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
  const usage = parseUsage(data.usage ?? data);
  return {
    type: "agent_end",
    ...(usage ? { usage } : {}),
    ...(optionalString(data.stop_reason ?? data.reason) ? { stop_reason: optionalString(data.stop_reason ?? data.reason) } : {}),
  };
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
  const usage: UsageSummary = {
    input: left.input + right.input,
    output: left.output + right.output,
  };
  if (left.cache_read !== undefined || right.cache_read !== undefined) {
    usage.cache_read = (left.cache_read ?? 0) + (right.cache_read ?? 0);
  }
  if (left.cache_write !== undefined || right.cache_write !== undefined) {
    usage.cache_write = (left.cache_write ?? 0) + (right.cache_write ?? 0);
  }
  return usage;
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

function eventEnvelopePayload(frame: StdioFrame): Record<string, unknown> {
  const payload = readPayloadOrFrame(frame);
  if (payload === frame) return payload;
  return { ...frame, ...payload };
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

function eventKind(event: Record<string, unknown>): string {
  const explicitType = optionalString(event.type);
  const eventType = optionalString(event.event_type);
  return explicitType === "event" && eventType ? eventType : (explicitType ?? eventType ?? firstKey(event));
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

function authRequiredError(providerId: string, message: string): MakaiAuthRequiredError {
  return new MakaiAuthRequiredError(providerId, message);
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
    signal?: AbortSignal;
    logger?: MakaiLogger;
    /** Called when abort fires during auth retry to cancel the abandoned stream/session. */
    onAbort?: () => void;
  },
): Promise<T> {
  try {
    return await operation();
  } catch (error) {
    if (isAbortError(error)) throw error;
    if (isRetryableAuthError(error) && options.authRetryPolicy === "auto_once" && options.auth) {
      checkAbort(options.signal, "operation aborted during auth retry");
      const providerId = error.provider_id ?? options.fallbackProviderId;
      if (!providerId) throw error;
      const logger = options.logger ?? getNoopLogger();
      logger.info("execution: auto-retrying after auth_required", { provider_id: providerId });
      try {
        await raceWithAbort(
          options.auth.login(providerId, options.authHandlers, { signal: options.signal }),
          options.signal,
          "operation aborted during auth login",
        );
      } catch (loginError) {
        if (isAbortError(loginError)) {
          options.onAbort?.();
          throw loginError;
        }
        if (loginError instanceof MakaiAuthError && loginError.kind === "cancelled" && options.signal?.aborted) {
          options.onAbort?.();
          const abortError = new Error("operation aborted during auth retry");
          abortError.name = "AbortError";
          throw abortError;
        }
        throw authRequiredError(providerId, error.message);
      }
      checkAbort(options.signal, "operation aborted before retry");
      options.beforeRetry?.();
      try {
        return await operation();
      } catch (retryError) {
        if (isAbortError(retryError)) throw retryError;
        if (isRetryableAuthError(retryError)) {
          const retryProviderId = retryError.provider_id ?? providerId;
          throw authRequiredError(retryProviderId, retryError.message);
        }
        throw retryError;
      }
    }
    if (isRetryableAuthError(error)) {
      const providerId = error.provider_id ?? options.fallbackProviderId;
      if (providerId) throw authRequiredError(providerId, error.message);
    }
    throw error;
  }
}

/**
 * Creates and connects the root Makai SDK client backed by `makai --stdio`.
 *
 * The returned client exposes provider execution, agent execution, model
 * discovery, and authentication APIs over one shared transport. Always call
 * {@link MakaiClient.close} when finished.
 *
 * @param options Binary resolver, stdio transport, auth, and timeout options.
 * @returns A connected {@link MakaiClient}.
 * @throws If binary resolution, process startup, or protocol handshake fails.
 *
 * @example
 * ```ts
 * const client = await createMakaiClient();
 * const { models } = await client.models.list();
 * const result = await client.provider.complete({
 *   model_ref: models[0]!.model_ref,
 *   messages: [{ role: "user", content: "Hello!" }],
 * });
 * console.log(result.message.content);
 * await client.close();
 * ```
 */
export async function createMakaiClient(options: CreateMakaiClientOptions = {}): Promise<MakaiClient> {
  const { auth: authOptions, responseTimeoutMs, frameTimeoutMs, logger, ...transportOptions } = options;
  const transport = await createMakaiStdioClient({ ...transportOptions, logger });
  await transport.connect();
  const authClient = new MakaiAuthClient(transport, { handlers: authOptions?.handlers, frameTimeoutMs, logger });
  const executionOptions = {
    responseTimeoutMs: responseTimeoutMs ?? frameTimeoutMs,
    authRetryPolicy: authOptions?.auth_retry_policy,
    auth: authClient,
    authHandlers: authOptions?.handlers,
    logger,
  };
  return {
    auth: authClient,
    models: createMakaiModelsApi(transport, { responseTimeoutMs: responseTimeoutMs ?? frameTimeoutMs, logger }),
    agent: createMakaiAgentApiWithModels(transport, executionOptions),
    provider: createMakaiProviderApi(transport, executionOptions),
    close: () => transport.close(),
  };
}
