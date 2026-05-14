/**
 * High-level `client.models.*` API on top of the stdio protocol transport.
 *
 * Spec: docs/v1-sdk-agent-provider-spec.md §3 / §3.5 / §5.
 *
 * Wire mapping:
 * - `list(request)` → `models_request` envelope; reply is `ack` then
 *   `models_response`, or `nack` on failure.
 * - `resolve({ provider_id, model_id, api? })` → same `models_request` envelope
 *   with the exact `model_id` filter set (spec §3.5: V1 reuses the same
 *   envelope, no separate resolve type).
 *
 * Defensive client-side checks for resolve (per task acceptance criteria):
 * - 0 results → throw `invalid_request` "model not found".
 * - >1 results → throw `invalid_request` ambiguous match.
 *
 * Cache semantics (spec §2.3):
 * - `fetched_at_ms` and `cache_max_age_ms` are surfaced on the response.
 * - If the runtime omits `cache_max_age_ms` (non-conformant), default to 5 min.
 */

import { ulid } from "ulid";
import { checkAbort, isAbortError, raceWithAbort } from "./abort_signal";
import { getNoopLogger, type MakaiLogger } from "./logger";
import {
  AuthStatus,
  ListModelsRequest,
  ListModelsResponse,
  MakaiModelsApi,
  MakaiProtocolError,
  ModelCapability,
  ModelDescriptor,
  ModelLifecycle,
  ModelSource,
  ReasoningLevel,
  ResolveModelRequest,
  ResolveModelResponse,
} from "./models_types";
import { MakaiStdioClient, StdioFrame } from "./stdio_client";
import {
  createTimeoutDiagnostics,
  formatTimeoutMessage,
  isTimeoutLikeError,
  type TimeoutDiagnosticContext,
} from "./timeout_diagnostics";

const ENVELOPE_VERSION = 1;
const DEFAULT_CACHE_MAX_AGE_MS = 300_000; // spec §2.3 fallback when server omits
const DEFAULT_RESPONSE_TIMEOUT_MS = 5_000;
const MAX_PROVIDER_ID_LENGTH = 256;
const MAX_MODEL_ID_LENGTH = 256;

const KNOWN_AUTH_STATUSES: ReadonlySet<string> = new Set([
  "authenticated",
  "login_required",
  "expired",
  "refreshing",
  "login_in_progress",
  "failed",
  "unknown",
]);

const KNOWN_LIFECYCLES: ReadonlySet<string> = new Set([
  "stable",
  "preview",
  "deprecated",
]);

const KNOWN_CAPABILITIES: ReadonlySet<string> = new Set([
  "chat",
  "streaming",
  "tools",
  "vision",
  "reasoning",
  "prompt_cache",
  "audio_input",
  "audio_output",
]);

const KNOWN_SOURCES: ReadonlySet<string> = new Set([
  "dynamic",
  "static_fallback",
]);

const KNOWN_REASONING_LEVELS: ReadonlySet<string> = new Set([
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
]);

/** Options for {@link createMakaiModelsApi}. */
export interface ModelsApiOptions {
  /** How long `list` / `resolve` waits for a terminal response frame. */
  responseTimeoutMs?: number;
  /** Optional structured logger for models API diagnostics. */
  logger?: MakaiLogger;
}

/**
 * Build a {@link MakaiModelsApi} bound to an already-connected
 * {@link MakaiStdioClient}.
 *
 * The transport is shared, so do not interleave concurrent calls without
 * external synchronization — V1 frame correlation is sequential per stream.
 *
 * @param client Connected stdio client used to exchange model-discovery frames.
 * @param options Response timeout configuration.
 * @returns A models API facade bound to the supplied transport.
 *
 * @example
 * ```ts
 * const models = createMakaiModelsApi(transport);
 * const { models: available } = await models.list();
 * ```
 */
export function createMakaiModelsApi(
  client: MakaiStdioClient,
  options: ModelsApiOptions = {},
): MakaiModelsApi {
  return new StdioModelsApi(client, options);
}

const MALFORMED_RESPONSE_CODE = "malformed_response";

class StdioModelsApi implements MakaiModelsApi {
  private readonly responseTimeoutMs: number;
  private readonly logger: MakaiLogger;

  constructor(
    private readonly client: MakaiStdioClient,
    options: ModelsApiOptions,
  ) {
    this.responseTimeoutMs = options.responseTimeoutMs ?? DEFAULT_RESPONSE_TIMEOUT_MS;
    this.logger = options.logger ?? getNoopLogger();
  }

  async list(request: ListModelsRequest = {}): Promise<ListModelsResponse> {
    if (typeof request.provider_id === "string" && request.provider_id.length > MAX_PROVIDER_ID_LENGTH) {
      throw new MakaiProtocolError(
        `provider_id exceeds maximum length of ${MAX_PROVIDER_ID_LENGTH} characters`,
        "invalid_request",
      );
    }
    if (typeof request.model_id === "string" && request.model_id.length > MAX_MODEL_ID_LENGTH) {
      throw new MakaiProtocolError(
        `model_id exceeds maximum length of ${MAX_MODEL_ID_LENGTH} characters`,
        "invalid_request",
      );
    }
    return this.dispatch(request, request.signal);
  }

  async resolve(request: ResolveModelRequest): Promise<ResolveModelResponse> {
    if (!request || typeof request.provider_id !== "string" || request.provider_id.length === 0) {
      throw new MakaiProtocolError("resolve requires provider_id", "invalid_request");
    }
    if (request.provider_id.length > MAX_PROVIDER_ID_LENGTH) {
      throw new MakaiProtocolError(
        `provider_id exceeds maximum length of ${MAX_PROVIDER_ID_LENGTH} characters`,
        "invalid_request",
      );
    }
    if (typeof request.model_id !== "string" || request.model_id.length === 0) {
      throw new MakaiProtocolError("resolve requires model_id", "invalid_request");
    }
    if (request.model_id.length > MAX_MODEL_ID_LENGTH) {
      throw new MakaiProtocolError(
        `model_id exceeds maximum length of ${MAX_MODEL_ID_LENGTH} characters`,
        "invalid_request",
      );
    }

    const response = await this.dispatch({
      provider_id: request.provider_id,
      api: request.api,
      model_id: request.model_id,
    }, request.signal);

    if (response.models.length === 0) {
      throw new MakaiProtocolError("model not found", "invalid_request");
    }
    if (response.models.length > 1) {
      throw new MakaiProtocolError(
        `resolve returned ${response.models.length} matches; expected exactly 1`,
        "invalid_request",
      );
    }

    const model = response.models[0]!;
    if (model.provider_id !== request.provider_id) {
      throw new MakaiProtocolError("resolved model provider_id mismatch", "invalid_request");
    }
    if (model.model_id !== request.model_id) {
      throw new MakaiProtocolError("resolved model_id mismatch", "invalid_request");
    }
    if (request.api !== undefined && model.api !== request.api) {
      throw new MakaiProtocolError("resolved model api mismatch", "invalid_request");
    }

    return { model };
  }

  private async nextFrameForStream(streamId: string, timeoutMs: number, context: TimeoutDiagnosticContext, signal?: AbortSignal): Promise<StdioFrame> {
    try {
      return await raceWithAbort(this.client.nextFrameForStream(streamId, timeoutMs), signal, "models.list aborted");
    } catch (error) {
      if (isAbortError(error)) throw error;
      throw new MakaiProtocolError(
        isTimeoutLikeError(error)
          ? formatTimeoutMessage(context)
          : error instanceof Error ? error.message : String(error),
        undefined,
        { diagnostics: isTimeoutLikeError(error) ? createTimeoutDiagnostics(context) : undefined },
      );
    }
  }

  private async dispatch(request: ListModelsRequest, signal?: AbortSignal): Promise<ListModelsResponse> {
    checkAbort(signal, "models.list aborted before start");
    const streamId = ulid();
    this.logger.debug("models: sending models_request", { stream_id: streamId, provider_id: request.provider_id, api: request.api });
    const envelope: StdioFrame = {
      type: "models_request",
      stream_id: streamId,
      message_id: streamId,
      sequence: 1,
      timestamp: Date.now(),
      version: ENVELOPE_VERSION,
      payload: buildPayload(request),
    };
    this.client.send(envelope);

    const timeoutContext: TimeoutDiagnosticContext = {
      operation: "models_response",
      timeout_ms: this.responseTimeoutMs,
      stream_id: streamId,
      message_id: streamId,
      provider_id: request.provider_id,
      api: request.api,
      model_id: request.model_id,
    };
    const deadline = Date.now() + this.responseTimeoutMs;
    while (true) {
      checkAbort(signal, "models.list aborted");
      const remaining = deadline - Date.now();
      if (remaining <= 0) {
        throw new MakaiProtocolError(
          formatTimeoutMessage(timeoutContext),
          undefined,
          { diagnostics: createTimeoutDiagnostics(timeoutContext) },
        );
      }
      const frame = await this.nextFrameForStream(streamId, remaining, timeoutContext, signal);

      switch (frame.type) {
        case "ack":
          continue;
        case "nack":
          throw nackToError(frame);
        case "models_response": {
          const response = parseModelsResponse(frame);
          this.logger.debug("models: received models_response", { count: response.models.length, stream_id: streamId });
          return response;
        }
        default:
          throw malformedResponseError(
            `unexpected frame type while awaiting models_response: ${frame.type}`,
          );
      }
    }
  }
}

function buildPayload(request: ListModelsRequest): Record<string, unknown> {
  const payload: Record<string, unknown> = {};
  if (typeof request.provider_id === "string" && request.provider_id.length > 0) {
    payload.provider_id = request.provider_id;
  }
  if (typeof request.api === "string" && request.api.length > 0) {
    payload.api = request.api;
  }
  if (typeof request.model_id === "string" && request.model_id.length > 0) {
    payload.model_id = request.model_id;
  }
  if (typeof request.include_deprecated === "boolean") {
    payload.include_deprecated = request.include_deprecated;
  }
  if (typeof request.include_login_required === "boolean") {
    payload.include_login_required = request.include_login_required;
  }
  return payload;
}

function nackToError(frame: StdioFrame): MakaiProtocolError {
  const payload = isObject(frame.payload) ? frame.payload : {};
  const reason = typeof payload.reason === "string" && payload.reason.length > 0
    ? payload.reason
    : "models request rejected";
  const code = typeof payload.error_code === "string" ? payload.error_code : undefined;
  return new MakaiProtocolError(reason, code);
}

function malformedResponseError(message: string): MakaiProtocolError {
  return new MakaiProtocolError(message, MALFORMED_RESPONSE_CODE);
}

function parseModelsResponse(frame: StdioFrame): ListModelsResponse {
  if (!isObject(frame.payload)) {
    throw malformedResponseError("models_response missing payload object");
  }
  const payload = frame.payload;

  const modelsRaw = payload.models;
  if (!Array.isArray(modelsRaw)) {
    throw malformedResponseError("models_response missing 'models' array");
  }

  if (typeof payload.fetched_at_ms !== "number" || !Number.isFinite(payload.fetched_at_ms)) {
    throw malformedResponseError("models_response missing numeric 'fetched_at_ms'");
  }

  // Spec §2.3: clients should default to 300_000ms when the server omits it.
  const cacheMaxAgeMs =
    typeof payload.cache_max_age_ms === "number" && Number.isFinite(payload.cache_max_age_ms)
      ? payload.cache_max_age_ms
      : DEFAULT_CACHE_MAX_AGE_MS;

  const models = modelsRaw.map((item, idx) => parseModelDescriptor(item, idx));

  return {
    models,
    fetched_at_ms: payload.fetched_at_ms,
    cache_max_age_ms: cacheMaxAgeMs,
  };
}

function parseModelDescriptor(raw: unknown, idx: number): ModelDescriptor {
  if (!isObject(raw)) {
    throw malformedResponseError(`models[${idx}] is not an object`);
  }

  const modelRef = requireString(raw.model_ref, `models[${idx}].model_ref`);
  const modelId = requireString(raw.model_id, `models[${idx}].model_id`);
  const displayName = requireString(raw.display_name, `models[${idx}].display_name`);
  const providerId = requireString(raw.provider_id, `models[${idx}].provider_id`);
  const api = requireString(raw.api, `models[${idx}].api`);
  const authStatus = requireKnownString(
    raw.auth_status,
    `models[${idx}].auth_status`,
    KNOWN_AUTH_STATUSES,
  ) as AuthStatus;
  const lifecycle = requireKnownString(
    raw.lifecycle,
    `models[${idx}].lifecycle`,
    KNOWN_LIFECYCLES,
  ) as ModelLifecycle;
  const source = requireKnownString(
    raw.source,
    `models[${idx}].source`,
    KNOWN_SOURCES,
  ) as ModelSource;

  if (!Array.isArray(raw.capabilities)) {
    throw malformedResponseError(`models[${idx}].capabilities must be an array`);
  }
  const capabilities: ModelCapability[] = raw.capabilities.map((cap, capIdx) => {
    if (typeof cap !== "string") {
      throw malformedResponseError(
        `models[${idx}].capabilities[${capIdx}] must be a string`,
      );
    }
    if (!KNOWN_CAPABILITIES.has(cap)) {
      // Spec §9: unknown fields/values are not fatal — but capability values
      // are an enum on the wire. Surface as protocol error so we do not
      // silently accept future capabilities as the closed TS union.
      throw malformedResponseError(
        `models[${idx}].capabilities[${capIdx}] has unknown value: ${cap}`,
      );
    }
    return cap as ModelCapability;
  });

  const descriptor: ModelDescriptor = {
    model_ref: modelRef,
    model_id: modelId,
    display_name: displayName,
    provider_id: providerId,
    api,
    auth_status: authStatus,
    lifecycle,
    capabilities,
    source,
  };

  if (typeof raw.base_url === "string" && raw.base_url.length > 0) {
    descriptor.base_url = raw.base_url;
  }
  if (typeof raw.context_window === "number" && Number.isFinite(raw.context_window)) {
    descriptor.context_window = raw.context_window;
  }
  if (typeof raw.max_output_tokens === "number" && Number.isFinite(raw.max_output_tokens)) {
    descriptor.max_output_tokens = raw.max_output_tokens;
  }
  if (raw.reasoning_default !== undefined) {
    descriptor.reasoning_default = requireKnownString(
      raw.reasoning_default,
      `models[${idx}].reasoning_default`,
      KNOWN_REASONING_LEVELS,
    ) as ReasoningLevel;
  }
  if (isObject(raw.metadata)) {
    const metadata: Record<string, string> = {};
    for (const [key, value] of Object.entries(raw.metadata)) {
      if (typeof value === "string") {
        metadata[key] = value;
      } else {
        throw malformedResponseError(
          `models[${idx}].metadata.${key} must be a string`,
        );
      }
    }
    descriptor.metadata = metadata;
  }

  return descriptor;
}

function requireString(value: unknown, fieldName: string): string {
  if (typeof value !== "string") {
    throw malformedResponseError(`${fieldName} must be a string`);
  }
  return value;
}

function requireKnownString(
  value: unknown,
  fieldName: string,
  knownValues: ReadonlySet<string>,
): string {
  const text = requireString(value, fieldName);
  if (!knownValues.has(text)) {
    throw malformedResponseError(`${fieldName} has unknown value: ${text}`);
  }
  return text;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
