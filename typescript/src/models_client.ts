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

import { randomUUID } from "node:crypto";
import {
  ListModelsRequest,
  ListModelsResponse,
  MakaiModelsApi,
  MakaiProtocolError,
  ModelCapability,
  ModelDescriptor,
  ResolveModelRequest,
  ResolveModelResponse,
} from "./models_types";
import { MakaiStdioClient, StdioFrame } from "./stdio_client";

const ENVELOPE_VERSION = 1;
const DEFAULT_CACHE_MAX_AGE_MS = 300_000; // spec §2.3 fallback when server omits
const DEFAULT_RESPONSE_TIMEOUT_MS = 5_000;

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

export interface ModelsApiOptions {
  /** How long `list` / `resolve` waits for a terminal response frame. */
  responseTimeoutMs?: number;
}

/**
 * Build a {@link MakaiModelsApi} bound to an already-connected
 * {@link MakaiStdioClient}.
 *
 * The transport is shared, so do not interleave concurrent calls without
 * external synchronization — V1 frame correlation is sequential per stream.
 */
export function createMakaiModelsApi(
  client: MakaiStdioClient,
  options: ModelsApiOptions = {},
): MakaiModelsApi {
  return new StdioModelsApi(client, options);
}

class StdioModelsApi implements MakaiModelsApi {
  private readonly responseTimeoutMs: number;

  constructor(
    private readonly client: MakaiStdioClient,
    options: ModelsApiOptions,
  ) {
    this.responseTimeoutMs = options.responseTimeoutMs ?? DEFAULT_RESPONSE_TIMEOUT_MS;
  }

  async list(request: ListModelsRequest = {}): Promise<ListModelsResponse> {
    return this.dispatch(request);
  }

  async resolve(request: ResolveModelRequest): Promise<ResolveModelResponse> {
    if (!request || typeof request.provider_id !== "string" || request.provider_id.length === 0) {
      throw new MakaiProtocolError("resolve requires provider_id", "invalid_request");
    }
    if (typeof request.model_id !== "string" || request.model_id.length === 0) {
      throw new MakaiProtocolError("resolve requires model_id", "invalid_request");
    }

    const response = await this.dispatch({
      provider_id: request.provider_id,
      api: request.api,
      model_id: request.model_id,
    });

    if (response.models.length === 0) {
      throw new MakaiProtocolError("model not found", "invalid_request");
    }
    if (response.models.length > 1) {
      throw new MakaiProtocolError(
        `resolve returned ${response.models.length} matches; expected exactly 1`,
        "invalid_request",
      );
    }
    return { model: response.models[0]! };
  }

  private async dispatch(request: ListModelsRequest): Promise<ListModelsResponse> {
    const streamId = randomUUID();
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

    const deadline = Date.now() + this.responseTimeoutMs;
    while (true) {
      const remaining = Math.max(deadline - Date.now(), 1);
      const frame = await this.client.nextFrame(remaining);

      // V1 sequencing: requests are issued one at a time per client. We still
      // skip frames belonging to a different stream so a stale event from a
      // prior request cannot poison the next.
      if (typeof frame.stream_id === "string" && frame.stream_id !== streamId) {
        continue;
      }

      switch (frame.type) {
        case "ack":
          continue;
        case "nack":
          throw nackToError(frame);
        case "models_response":
          return parseModelsResponse(frame);
        default:
          throw new MakaiProtocolError(
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

function parseModelsResponse(frame: StdioFrame): ListModelsResponse {
  if (!isObject(frame.payload)) {
    throw new MakaiProtocolError("models_response missing payload object");
  }
  const payload = frame.payload;

  const modelsRaw = payload.models;
  if (!Array.isArray(modelsRaw)) {
    throw new MakaiProtocolError("models_response missing 'models' array");
  }

  if (typeof payload.fetched_at_ms !== "number" || !Number.isFinite(payload.fetched_at_ms)) {
    throw new MakaiProtocolError("models_response missing numeric 'fetched_at_ms'");
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
    throw new MakaiProtocolError(`models[${idx}] is not an object`);
  }

  const modelRef = requireString(raw.model_ref, `models[${idx}].model_ref`);
  const modelId = requireString(raw.model_id, `models[${idx}].model_id`);
  const displayName = requireString(raw.display_name, `models[${idx}].display_name`);
  const providerId = requireString(raw.provider_id, `models[${idx}].provider_id`);
  const api = requireString(raw.api, `models[${idx}].api`);
  const authStatus = requireString(raw.auth_status, `models[${idx}].auth_status`);
  const lifecycle = requireString(raw.lifecycle, `models[${idx}].lifecycle`);
  const source = requireString(raw.source, `models[${idx}].source`);

  if (!Array.isArray(raw.capabilities)) {
    throw new MakaiProtocolError(`models[${idx}].capabilities must be an array`);
  }
  const capabilities: ModelCapability[] = raw.capabilities.map((cap, capIdx) => {
    if (typeof cap !== "string") {
      throw new MakaiProtocolError(
        `models[${idx}].capabilities[${capIdx}] must be a string`,
      );
    }
    if (!KNOWN_CAPABILITIES.has(cap)) {
      // Spec §9: unknown fields/values are not fatal — but capability values
      // are an enum on the wire. Surface as protocol error so we do not
      // silently accept future capabilities as the closed TS union.
      throw new MakaiProtocolError(
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
    auth_status: authStatus as ModelDescriptor["auth_status"],
    lifecycle: lifecycle as ModelDescriptor["lifecycle"],
    capabilities,
    source: source as ModelDescriptor["source"],
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
  if (typeof raw.reasoning_default === "string" && raw.reasoning_default.length > 0) {
    descriptor.reasoning_default = raw.reasoning_default as ModelDescriptor["reasoning_default"];
  }
  if (isObject(raw.metadata)) {
    const metadata: Record<string, string> = {};
    for (const [key, value] of Object.entries(raw.metadata)) {
      if (typeof value === "string") {
        metadata[key] = value;
      } else {
        throw new MakaiProtocolError(
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
    throw new MakaiProtocolError(`${fieldName} must be a string`);
  }
  return value;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
