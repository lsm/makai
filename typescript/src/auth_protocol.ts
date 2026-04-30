import { randomUUID } from "node:crypto";
import { BinaryResolverOptions } from "./binary_resolver";
import {
  MakaiStdioClient,
  StdioFrame,
  createMakaiStdioClient,
  type CreateMakaiStdioClientOptions,
} from "./stdio_client";

// ---------------------------------------------------------------------------
// Spec-aligned types (docs/v1-sdk-agent-provider-spec.md §3, §3.6, §4).
// ---------------------------------------------------------------------------

export type ProviderId = string;

export const AUTH_STATUSES = [
  "authenticated",
  "login_required",
  "expired",
  "refreshing",
  "login_in_progress",
  "failed",
  "unknown",
] as const;

export type AuthStatus = (typeof AUTH_STATUSES)[number];

const VALID_AUTH_STATUSES = new Set<string>(AUTH_STATUSES);

export interface ProviderAuthInfo {
  id: ProviderId;
  name: string;
  auth_status: AuthStatus;
  last_error?: string;
}

export type MakaiAuthEvent =
  | {
      type: "auth_url";
      flow_id: string;
      provider_id: ProviderId;
      url: string;
      instructions?: string;
    }
  | {
      type: "prompt";
      flow_id: string;
      prompt_id: string;
      provider_id: ProviderId;
      message: string;
      allow_empty: boolean;
    }
  | {
      type: "progress";
      flow_id: string;
      provider_id: ProviderId;
      message: string;
    }
  | {
      type: "success";
      flow_id: string;
      provider_id: ProviderId;
    }
  | {
      type: "error";
      flow_id: string;
      provider_id: ProviderId;
      code?: string;
      message: string;
    };

export interface AuthFlowHandlers {
  onEvent?: (event: MakaiAuthEvent) => void;
  onPrompt?: (
    prompt: Extract<MakaiAuthEvent, { type: "prompt" }>,
  ) => Promise<string> | string;
}

export type MakaiAuthErrorKind =
  | "provider_error"
  | "cancelled"
  | "transport_error"
  | "unknown";

export class MakaiAuthError extends Error {
  public readonly kind: MakaiAuthErrorKind;
  public readonly code?: string;

  constructor(
    message: string,
    options: { kind?: MakaiAuthErrorKind; code?: string } = {},
  ) {
    super(message);
    this.name = "MakaiAuthError";
    this.kind = options.kind ?? "unknown";
    this.code = options.code;
  }
}

export interface MakaiAuthApi {
  listProviders(): Promise<ProviderAuthInfo[]>;
  /**
   * Handler precedence: per-call handlers > client-level defaults > none.
   */
  login(
    providerId: ProviderId,
    handlers?: AuthFlowHandlers,
  ): Promise<{ status: "success" }>;
}

// ---------------------------------------------------------------------------
// Wire helpers.
// ---------------------------------------------------------------------------

const AUTH_EVENT_VARIANTS = [
  "auth_url",
  "prompt",
  "progress",
  "success",
  "error",
] as const;
type AuthEventVariant = (typeof AUTH_EVENT_VARIANTS)[number];

/**
 * Auth events on the wire are Zig union objects (e.g. `{ "prompt": { ... } }`).
 * Flatten to the SDK's `MakaiAuthEvent` shape (`{ type: "prompt", ... }`).
 */
export function flattenAuthEvent(payload: Record<string, unknown>): MakaiAuthEvent {
  for (const variant of AUTH_EVENT_VARIANTS) {
    const value = payload[variant];
    if (value && typeof value === "object" && !Array.isArray(value)) {
      return normalizeAuthEvent(variant, value as Record<string, unknown>);
    }
  }
  throw new MakaiAuthError(
    `unknown auth_event variant: ${JSON.stringify(payload)}`,
    { kind: "unknown" },
  );
}

function normalizeAuthEvent(
  variant: AuthEventVariant,
  data: Record<string, unknown>,
): MakaiAuthEvent {
  const flow_id = stringField(data, "flow_id");
  const provider_id = stringField(data, "provider_id");
  switch (variant) {
    case "auth_url": {
      const event: Extract<MakaiAuthEvent, { type: "auth_url" }> = {
        type: "auth_url",
        flow_id,
        provider_id,
        url: stringField(data, "url"),
      };
      const instructions = optionalStringField(data, "instructions");
      if (instructions !== undefined) event.instructions = instructions;
      return event;
    }
    case "prompt":
      return {
        type: "prompt",
        flow_id,
        prompt_id: stringField(data, "prompt_id"),
        provider_id,
        message: stringField(data, "message"),
        allow_empty:
          typeof data["allow_empty"] === "boolean" ? (data["allow_empty"] as boolean) : false,
      };
    case "progress":
      return {
        type: "progress",
        flow_id,
        provider_id,
        message: stringField(data, "message"),
      };
    case "success":
      return {
        type: "success",
        flow_id,
        provider_id,
      };
    case "error": {
      const event: Extract<MakaiAuthEvent, { type: "error" }> = {
        type: "error",
        flow_id,
        provider_id,
        message: stringField(data, "message"),
      };
      const code = optionalStringField(data, "code");
      if (code !== undefined) event.code = code;
      return event;
    }
  }
}

function stringField(data: Record<string, unknown>, key: string): string {
  const value = data[key];
  if (typeof value !== "string") {
    throw new MakaiAuthError(`auth_event field "${key}" missing or not a string`, {
      kind: "transport_error",
    });
  }
  return value;
}

function optionalStringField(
  data: Record<string, unknown>,
  key: string,
): string | undefined {
  const value = data[key];
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") return undefined;
  return value.length > 0 ? value : undefined;
}

// ---------------------------------------------------------------------------
// Auth client implementation over a stdio transport.
// ---------------------------------------------------------------------------

const PROTOCOL_VERSION = 1;

type RawEnvelope = StdioFrame & {
  stream_id?: unknown;
  in_reply_to?: unknown;
  payload?: unknown;
};

export interface MakaiAuthClientOptions {
  /**
   * Default handlers used when `login()` is invoked without per-call handlers.
   * Per-call handlers take precedence.
   */
  handlers?: AuthFlowHandlers;
  /**
   * Maximum time to wait for individual response frames (ms). Defaults to 30s.
   * This bounds prompt-handler-free flows; interactive flows depend on the
   * caller's onPrompt to drive progress.
   */
  frameTimeoutMs?: number;
}

/**
 * High-level auth API implemented on top of an auth-capable stdio transport.
 *
 * Per docs/v1-sdk-agent-provider-spec.md §3.6, all calls map to auth protocol
 * envelopes; CLI-subprocess wiring is prohibited in V1.
 */
export class MakaiAuthClient implements MakaiAuthApi {
  private readonly transport: MakaiStdioClient;
  private readonly defaultHandlers?: AuthFlowHandlers;
  private readonly frameTimeoutMs: number;
  private readonly streamFrameQueues = new Map<string, RawEnvelope[]>();
  private readLock: Promise<void> = Promise.resolve();

  constructor(transport: MakaiStdioClient, options: MakaiAuthClientOptions = {}) {
    this.transport = transport;
    this.defaultHandlers = options.handlers;
    this.frameTimeoutMs = options.frameTimeoutMs ?? 30_000;
  }

  async listProviders(): Promise<ProviderAuthInfo[]> {
    const streamId = randomUUID();
    const messageId = randomUUID();
    const envelope = {
      type: "auth_providers_request",
      stream_id: streamId,
      message_id: messageId,
      sequence: 1,
      timestamp: Date.now(),
      version: PROTOCOL_VERSION,
      payload: {},
    };

    this.sendOrThrow(envelope);

    while (true) {
      const frame = await this.nextFrameForStream(streamId);
      if (frame.type === "ack") continue;
      if (frame.type === "nack") {
        throw nackToAuthError(frame);
      }
      if (frame.type === "auth_providers_response") {
        return parseProviders(frame);
      }
      throw new MakaiAuthError(
        `unexpected envelope type while awaiting auth_providers_response: ${String(frame.type)}`,
        { kind: "transport_error" },
      );
    }
  }

  async login(
    providerId: ProviderId,
    handlers?: AuthFlowHandlers,
  ): Promise<{ status: "success" }> {
    // Spec §3.6: per-call handlers > client-level defaults > none.
    // Whole-object replacement: per-call handlers entirely replace defaults
    // (not per-property merge), so `{ onPrompt }` intentionally drops a
    // client-level `onEvent`.
    const effective = handlers ?? this.defaultHandlers;
    const flowId = randomUUID();
    let outboundSequence = 1;

    this.sendOrThrow({
      type: "auth_login_start",
      stream_id: flowId,
      message_id: randomUUID(),
      sequence: outboundSequence++,
      timestamp: Date.now(),
      version: PROTOCOL_VERSION,
      payload: { provider_id: providerId },
    });

    let lastErrorEvent:
      | { code?: string; message: string }
      | undefined;
    let cancelled = false;

    while (true) {
      const frame = await this.nextFrameForStream(flowId);

      if (frame.type === "ack") continue;
      if (frame.type === "nack") {
        throw nackToAuthError(frame);
      }

      if (frame.type === "auth_event") {
        const eventPayload = readPayload(frame);
        const event = flattenAuthEvent(eventPayload);
        try {
          effective?.onEvent?.(event);
        } catch (err) {
          // onEvent should not throw; propagate as transport_error if it does.
          throw new MakaiAuthError(
            err instanceof Error ? err.message : String(err),
            { kind: "unknown" },
          );
        }

        if (event.type === "error") {
          lastErrorEvent = { code: event.code, message: event.message };
          continue;
        }

        if (event.type === "prompt") {
          if (!effective?.onPrompt) {
            // No prompt handler: cancel the flow so the server can clean up.
            cancelled = true;
            this.bestEffortCancel(flowId, outboundSequence++);
            // Continue draining until terminal `auth_login_result`.
            continue;
          }
          let answer: string;
          try {
            answer = await effective.onPrompt(event);
          } catch (err) {
            this.bestEffortCancel(flowId, outboundSequence++);
            throw new MakaiAuthError(
              err instanceof Error ? err.message : String(err),
              { kind: "unknown" },
            );
          }
          this.sendOrThrow({
            type: "auth_prompt_response",
            stream_id: flowId,
            message_id: randomUUID(),
            sequence: outboundSequence++,
            timestamp: Date.now(),
            version: PROTOCOL_VERSION,
            payload: {
              flow_id: flowId,
              prompt_id: event.prompt_id,
              answer: answer ?? "",
            },
          });
          continue;
        }

        // auth_url, progress, success — already published via onEvent.
        continue;
      }

      if (frame.type === "auth_login_result") {
        const payload = readPayload(frame);
        const status = typeof payload["status"] === "string" ? payload["status"] : undefined;
        if (status === "success") return { status: "success" };
        if (status === "cancelled") {
          throw new MakaiAuthError(
            lastErrorEvent?.message ??
              (cancelled
                ? "auth login cancelled (no onPrompt handler configured)"
                : "auth login cancelled"),
            { kind: "cancelled", code: lastErrorEvent?.code },
          );
        }
        if (status === "failed") {
          throw new MakaiAuthError(
            lastErrorEvent?.message ?? "auth login failed",
            { kind: "provider_error", code: lastErrorEvent?.code },
          );
        }
        throw new MakaiAuthError(
          `unexpected auth_login_result status: ${String(status)}`,
          { kind: "unknown" },
        );
      }

      throw new MakaiAuthError(
        `unexpected envelope type during login flow: ${String(frame.type)}`,
        { kind: "transport_error" },
      );
    }
  }

  private async nextFrameForStream(streamId: string): Promise<RawEnvelope> {
    const queued = this.dequeueStreamFrame(streamId);
    if (queued) return queued;

    return this.withReadLock(() => this.readUntilStreamFrame(streamId));
  }

  private dequeueStreamFrame(streamId: string): RawEnvelope | undefined {
    const queued = this.streamFrameQueues.get(streamId);
    if (!queued || queued.length === 0) return undefined;
    const frame = queued.shift()!;
    if (queued.length === 0) this.streamFrameQueues.delete(streamId);
    return frame;
  }

  private async withReadLock<T>(operation: () => Promise<T>): Promise<T> {
    const previous = this.readLock;
    let release!: () => void;
    this.readLock = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    try {
      return await operation();
    } finally {
      release();
    }
  }

  private async readUntilStreamFrame(streamId: string): Promise<RawEnvelope> {
    const deadline = Date.now() + this.frameTimeoutMs;
    while (true) {
      const queued = this.dequeueStreamFrame(streamId);
      if (queued) return queued;

      const remainingMs = deadline - Date.now();
      if (remainingMs <= 0) {
        throw new MakaiAuthError(
          `timed out waiting for frame for stream ${streamId} after ${this.frameTimeoutMs}ms`,
          { kind: "transport_error" },
        );
      }

      const frame = await this.nextTransportFrame(remainingMs);
      if (frameMatchesStream(frame, streamId)) return frame;

      const foreignStreamId = typeof frame.stream_id === "string" ? frame.stream_id : undefined;
      if (foreignStreamId) {
        const queue = this.streamFrameQueues.get(foreignStreamId) ?? [];
        queue.push(frame);
        this.streamFrameQueues.set(foreignStreamId, queue);
      }
      // Frames without stream_id (e.g. handshake leftovers) are foreign to auth
      // flows and cannot be routed to a stream-specific waiter.
    }
  }

  private async nextTransportFrame(timeoutMs: number): Promise<RawEnvelope> {
    try {
      return (await this.transport.nextFrame(timeoutMs)) as RawEnvelope;
    } catch (error) {
      throw new MakaiAuthError(
        error instanceof Error ? error.message : String(error),
        { kind: "transport_error" },
      );
    }
  }

  private sendOrThrow(envelope: StdioFrame): void {
    try {
      this.transport.send(envelope);
    } catch (error) {
      throw new MakaiAuthError(
        error instanceof Error ? error.message : String(error),
        { kind: "transport_error" },
      );
    }
  }

  private bestEffortCancel(flowId: string, sequence: number): void {
    try {
      this.transport.send({
        type: "auth_cancel",
        stream_id: flowId,
        message_id: randomUUID(),
        sequence,
        timestamp: Date.now(),
        version: PROTOCOL_VERSION,
        payload: { flow_id: flowId },
      });
    } catch {
      // Best-effort cancellation; ignore transport errors here so we keep
      // surfacing the original failure to the caller.
    }
  }
}

function frameMatchesStream(frame: RawEnvelope, streamId: string): boolean {
  if (typeof frame.stream_id !== "string") {
    // Frames without stream_id (e.g. handshake) are foreign to our flow.
    return false;
  }
  return frame.stream_id === streamId;
}

function readPayload(frame: RawEnvelope): Record<string, unknown> {
  const payload = frame.payload;
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new MakaiAuthError(
      `envelope ${String(frame.type)} missing payload object`,
      { kind: "transport_error" },
    );
  }
  return payload as Record<string, unknown>;
}

function parseProviders(frame: RawEnvelope): ProviderAuthInfo[] {
  const payload = readPayload(frame);
  const providers = payload["providers"];
  if (!Array.isArray(providers)) {
    throw new MakaiAuthError(
      "auth_providers_response payload missing providers array",
      { kind: "transport_error" },
    );
  }
  return providers.map((entry, index) => parseProvider(entry, index));
}

function parseProvider(entry: unknown, index: number): ProviderAuthInfo {
  if (!entry || typeof entry !== "object") {
    throw new MakaiAuthError(
      `provider entry at index ${index} is not an object`,
      { kind: "transport_error" },
    );
  }
  const data = entry as Record<string, unknown>;
  const id = data["id"];
  const name = data["name"];
  const status = data["auth_status"];
  if (typeof id !== "string" || typeof name !== "string") {
    throw new MakaiAuthError(
      `provider entry at index ${index} missing id/name`,
      { kind: "transport_error" },
    );
  }
  const provider: ProviderAuthInfo = {
    id,
    name,
    auth_status:
      typeof status === "string" && VALID_AUTH_STATUSES.has(status)
        ? (status as AuthStatus)
        : "unknown",
  };
  const lastError = data["last_error"];
  if (typeof lastError === "string" && lastError.length > 0) {
    provider.last_error = lastError;
  }
  return provider;
}

function nackToAuthError(frame: RawEnvelope): MakaiAuthError {
  const payload =
    frame.payload && typeof frame.payload === "object" && !Array.isArray(frame.payload)
      ? (frame.payload as Record<string, unknown>)
      : {};
  const reason = typeof payload["reason"] === "string" ? (payload["reason"] as string) : "transport nack";
  const code = typeof payload["error_code"] === "string" ? (payload["error_code"] as string) : undefined;
  return new MakaiAuthError(reason, { kind: "transport_error", code });
}

// ---------------------------------------------------------------------------
// Factory.
// ---------------------------------------------------------------------------

export type CreateMakaiAuthClientOptions = CreateMakaiStdioClientOptions & {
  /** Default handlers reused by `login(...)` when no per-call handlers are provided. */
  handlers?: AuthFlowHandlers;
  /** See `MakaiAuthClientOptions.frameTimeoutMs`. */
  frameTimeoutMs?: number;
  /** Resolver options for locating the makai binary. */
  resolver?: BinaryResolverOptions;
};

export interface MakaiAuthClientHandle {
  auth: MakaiAuthApi;
  close(): Promise<void>;
}

/**
 * Creates an auth-capable client backed by `makai --stdio`. Connects the
 * underlying transport (handshake) before returning.
 */
export async function createMakaiAuthClient(
  options: CreateMakaiAuthClientOptions = {},
): Promise<MakaiAuthClientHandle> {
  const { handlers, frameTimeoutMs, ...transportOptions } = options;
  const transport = await createMakaiStdioClient(transportOptions);
  await transport.connect();
  const auth = new MakaiAuthClient(transport, { handlers, frameTimeoutMs });
  return {
    auth,
    close: () => transport.close(),
  };
}
