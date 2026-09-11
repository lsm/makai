import { ulid } from "ulid";
import { checkAbort, isAbortError, raceWithAbort } from "./abort_signal";
import { BinaryResolverOptions } from "./binary_resolver";
import { getNoopLogger, type MakaiLogger } from "./logger";
import {
  MakaiStdioClient,
  StdioFrame,
  createMakaiStdioClient,
  type CreateMakaiStdioClientOptions,
} from "./stdio_client";
import {
  createTimeoutDiagnostics,
  formatTimeoutMessage,
  isTimeoutLikeError,
  type TimeoutDiagnosticContext,
  type TimeoutDiagnostics,
} from "./timeout_diagnostics";

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
  public readonly diagnostics?: TimeoutDiagnostics;

  constructor(
    message: string,
    options: { kind?: MakaiAuthErrorKind; code?: string; diagnostics?: TimeoutDiagnostics } = {},
  ) {
    super(message);
    this.name = "MakaiAuthError";
    this.kind = options.kind ?? "unknown";
    this.code = options.code;
    this.diagnostics = options.diagnostics;
  }
}

export interface MakaiAuthApi {
  listProviders(): Promise<ProviderAuthInfo[]>;
  login(
    providerId: ProviderId,
    handlers?: AuthFlowHandlers,
    options?: { signal?: AbortSignal },
  ): Promise<{ status: "success" }>;
}

const AUTH_EVENT_VARIANTS = [
  "auth_url",
  "prompt",
  "progress",
  "success",
  "error",
] as const;
type AuthEventVariant = (typeof AUTH_EVENT_VARIANTS)[number];

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

const PROTOCOL_VERSION = 1;

type RawEnvelope = StdioFrame & {
  stream_id?: unknown;
  in_reply_to?: unknown;
  payload?: unknown;
};

export interface MakaiAuthClientOptions {
  handlers?: AuthFlowHandlers;
  frameTimeoutMs?: number;
  logger?: MakaiLogger;
}

export class MakaiAuthClient implements MakaiAuthApi {
  private readonly transport: MakaiStdioClient;
  private readonly defaultHandlers?: AuthFlowHandlers;
  private readonly frameTimeoutMs: number;
  private readonly logger: MakaiLogger;

  constructor(transport: MakaiStdioClient, options: MakaiAuthClientOptions = {}) {
    this.transport = transport;
    this.defaultHandlers = options.handlers;
    this.frameTimeoutMs = options.frameTimeoutMs ?? 30_000;
    this.logger = options.logger ?? getNoopLogger();
  }

  async listProviders(): Promise<ProviderAuthInfo[]> {
    const streamId = ulid();
    const messageId = ulid();
    const envelope = {
      type: "auth_providers_request",
      stream_id: streamId,
      message_id: messageId,
      sequence: 1,
      timestamp: Date.now(),
      version: PROTOCOL_VERSION,
      payload: {},
    };

    this.logger.debug("auth: sending auth_providers_request", { stream_id: streamId });
    this.sendOrThrow(envelope);

    while (true) {
      const frame = await this.nextFrameForStream(streamId, {
        operation: "auth_providers_response",
        message_id: messageId,
      });
      if (frame.type === "ack") continue;
      if (frame.type === "nack") {
        throw nackToAuthError(frame);
      }
      if (frame.type === "auth_providers_response") {
        const providers = parseProviders(frame);
        this.logger.debug("auth: received providers list", { count: providers.length });
        return providers;
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
    options?: { signal?: AbortSignal },
  ): Promise<{ status: "success" }> {
    const signal = options?.signal;
    if (signal?.aborted) {
      throw new MakaiAuthError("auth login aborted", { kind: "cancelled" });
    }
    const effective = handlers ?? this.defaultHandlers;
    const flowId = ulid();
    let outboundSequence = 1;
    let loginStarted = false;

    this.logger.info("auth: starting login flow", { provider_id: providerId, flow_id: flowId });

    const startMessageId = ulid();
    this.sendOrThrow({
      type: "auth_login_start",
      stream_id: flowId,
      message_id: startMessageId,
      sequence: outboundSequence++,
      timestamp: Date.now(),
      version: PROTOCOL_VERSION,
      payload: { provider_id: providerId },
    });
    loginStarted = true;

    let lastErrorEvent:
      | { code?: string; message: string }
      | undefined;
    let cancelled = false;

    while (true) {
      if (signal?.aborted) {
        if (loginStarted) {
          this.bestEffortCancel(flowId, outboundSequence++);
        }
        throw new MakaiAuthError("auth login aborted", { kind: "cancelled" });
      }
      const frame = await this.nextFrameForStream(flowId, {
        operation: "auth_login_result/auth_event",
        message_id: startMessageId,
        provider_id: providerId,
      }, signal, () => outboundSequence++);

      if (frame.type === "ack") continue;
      if (frame.type === "nack") {
        throw nackToAuthError(frame);
      }

      if (frame.type === "auth_event") {
        const eventPayload = readPayload(frame);
        const event = flattenAuthEvent(eventPayload);
        this.logger.debug("auth: received auth event", { event_type: event.type, flow_id: flowId, provider_id: providerId });
        try {
          effective?.onEvent?.(event);
        } catch (err) {
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
            cancelled = true;
            this.bestEffortCancel(flowId, outboundSequence++);
            continue;
          }
          let answer: string;
          try {
            answer = await raceWithAbort(Promise.resolve(effective.onPrompt(event)), signal, "auth.login aborted during prompt");
          } catch (err) {
            if (isAbortError(err)) {
              this.bestEffortCancel(flowId, outboundSequence++);
              throw new MakaiAuthError("auth login aborted", { kind: "cancelled" });
            }
            this.bestEffortCancel(flowId, outboundSequence++);
            await this.drainLoginResult(flowId);
            throw new MakaiAuthError(
              err instanceof Error ? err.message : String(err),
              { kind: "unknown" },
            );
          }
          this.sendOrThrow({
            type: "auth_prompt_response",
            stream_id: flowId,
            message_id: ulid(),
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

        continue;
      }

      if (frame.type === "auth_login_result") {
        const payload = readPayload(frame);
        const status = typeof payload["status"] === "string" ? payload["status"] : undefined;
        if (status === "success") {
          this.logger.info("auth: login succeeded", { provider_id: providerId, flow_id: flowId });
          return { status: "success" };
        }
        if (status === "cancelled") {
          this.logger.warn("auth: login cancelled", { provider_id: providerId, flow_id: flowId });
          throw new MakaiAuthError(
            lastErrorEvent?.message ??
              (cancelled
                ? "auth login cancelled (no onPrompt handler configured)"
                : "auth login cancelled"),
            { kind: "cancelled", code: lastErrorEvent?.code },
          );
        }
        if (status === "failed") {
          this.logger.error("auth: login failed", { provider_id: providerId, flow_id: flowId });
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

  private async drainLoginResult(flowId: string): Promise<void> {
    while (true) {
      const frame = await this.nextFrameForStream(flowId, {
        operation: "auth_login_result",
      });
      if (frame.type === "auth_login_result") return;
    }
  }

  private async nextFrameForStream(streamId: string, context: Omit<TimeoutDiagnosticContext, "timeout_ms" | "stream_id">, signal?: AbortSignal, nextCancelSequence?: () => number): Promise<RawEnvelope> {
    try {
      return (await raceWithAbort(this.transport.nextFrameForStream(streamId, this.frameTimeoutMs), signal, "auth.login aborted")) as RawEnvelope;
    } catch (error) {
      if (isAbortError(error)) {
        const seq = nextCancelSequence ? nextCancelSequence() : 999;
        this.bestEffortCancel(streamId, seq);
        throw new MakaiAuthError("auth login aborted", { kind: "cancelled" });
      }
      const diagnosticsContext = { ...context, timeout_ms: this.frameTimeoutMs, stream_id: streamId };
      throw new MakaiAuthError(
        isTimeoutLikeError(error)
          ? formatTimeoutMessage(diagnosticsContext)
          : error instanceof Error ? error.message : String(error),
        {
          kind: "transport_error",
          diagnostics: isTimeoutLikeError(error) ? createTimeoutDiagnostics(diagnosticsContext) : undefined,
        },
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
        message_id: ulid(),
        sequence,
        timestamp: Date.now(),
        version: PROTOCOL_VERSION,
        payload: { flow_id: flowId },
      });
    } catch {
    }
  }
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

export type CreateMakaiAuthClientOptions = CreateMakaiStdioClientOptions & {
  handlers?: AuthFlowHandlers;
  frameTimeoutMs?: number;
  resolver?: BinaryResolverOptions;
  logger?: MakaiLogger;
};

export interface MakaiAuthClientHandle {
  auth: MakaiAuthApi;
  close(): Promise<void>;
}

export async function createMakaiAuthClient(
  options: CreateMakaiAuthClientOptions = {},
): Promise<MakaiAuthClientHandle> {
  const { handlers, frameTimeoutMs, logger, ...transportOptions } = options;
  const transport = await createMakaiStdioClient({ ...transportOptions, logger });
  await transport.connect();
  const auth = new MakaiAuthClient(transport, { handlers, frameTimeoutMs, logger });
  return {
    auth,
    close: () => transport.close(),
  };
}
