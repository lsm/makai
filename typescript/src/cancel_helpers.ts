
import { ulid } from "ulid";
import type { MakaiStdioClient } from "./stdio_client";

const ENVELOPE_VERSION = 1;

export function bestEffortCancelStream(transport: MakaiStdioClient, streamId: string): void {
  try {
    transport.send({
      type: "abort_request",
      stream_id: streamId,
      message_id: ulid(),
      sequence: 2,
      timestamp: Date.now(),
      version: ENVELOPE_VERSION,
      payload: { target_stream_id: streamId, reason: "client aborted" },
    });
  } catch {
  }
}

export function bestEffortCancelAgent(transport: MakaiStdioClient, sessionId: string, sequence = 2): void {
  bestEffortStopAgent(transport, sessionId, sequence, "client aborted");
}

export function bestEffortStopAgent(transport: MakaiStdioClient, sessionId: string, sequence: number, reason: string): string {
  const messageId = ulid();
  try {
    transport.send({
      type: "agent_stop",
      session_id: sessionId,
      message_id: messageId,
      sequence,
      timestamp: Date.now(),
      version: ENVELOPE_VERSION,
      payload: { session_id: sessionId, reason },
    });
  } catch {
  }
  return messageId;
}

export async function drainStreamFrames(transport: MakaiStdioClient, streamId: string, timeoutMs = 200): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) break;
    const perFrameMs = Math.min(remaining, 50);
    try {
      await Promise.race([
        transport.nextFrameForStream(streamId, perFrameMs).catch(() => undefined),
        new Promise<void>((resolve) => setTimeout(resolve, perFrameMs)),
      ]);
    } catch {
      break;
    }
  }
}

export async function drainSessionFrames(transport: MakaiStdioClient, sessionId: string, timeoutMs = 200): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) break;
    const perFrameMs = Math.min(remaining, 50);
    try {
      await Promise.race([
        transport.nextFrameForSession(sessionId, perFrameMs).catch(() => undefined),
        new Promise<void>((resolve) => setTimeout(resolve, perFrameMs)),
      ]);
    } catch {
      break;
    }
  }
}

export async function drainSessionFramesUntilQuiescent(
  transport: MakaiStdioClient,
  sessionId: string,
  idleMs = 50,
  maxMs = 250,
  opts: { stopReplyTo?: string } = {},
): Promise<void> {
  const deadline = performance.now() + maxMs;
  while (performance.now() < deadline) {
    const remaining = deadline - performance.now();
    if (remaining <= 0) break;
    const waitMs = Math.min(idleMs, remaining);
    const controller = new AbortController();
    const read = transport.nextFrameForSession(sessionId, waitMs, { signal: controller.signal }).catch(() => null);
    let budgetTimer: NodeJS.Timeout | undefined;
    const budget = new Promise<null>((resolve) => {
      budgetTimer = setTimeout(() => {
        controller.abort();
        resolve(null);
      }, remaining);
    });
    const frame = await Promise.race([read, budget]);
    if (budgetTimer !== undefined) clearTimeout(budgetTimer);
    if (!frame) return;
    if (opts.stopReplyTo !== undefined && frame.type === "agent_stopped" && frame.in_reply_to === opts.stopReplyTo) return;
  }
}

export async function stopAgentWithSequenceProbe(
  transport: MakaiStdioClient,
  sessionId: string,
  sequences: { preSend: number; postSend: number },
  reason: string,
  idleMs = 50,
  maxMs = 250,
): Promise<number | undefined> {
  let outstanding = { messageId: bestEffortStopAgent(transport, sessionId, sequences.preSend, reason), sequence: sequences.preSend };
  let retried = false;
  const deadline = performance.now() + maxMs;
  while (performance.now() < deadline) {
    const remaining = deadline - performance.now();
    if (remaining <= 0) break;
    const waitMs = Math.min(idleMs, remaining);
    const controller = new AbortController();
    const read = transport.nextFrameForSession(sessionId, waitMs, { correlate: outstanding.messageId, signal: controller.signal }).catch(() => null);
    let budgetTimer: NodeJS.Timeout | undefined;
    const budget = new Promise<null>((resolve) => {
      budgetTimer = setTimeout(() => {
        controller.abort();
        resolve(null);
      }, remaining);
    });
    const frame = await Promise.race([read, budget]);
    if (budgetTimer !== undefined) clearTimeout(budgetTimer);
    if (!frame) {
      continue;
    }
    if (frame.in_reply_to !== outstanding.messageId) continue;
    if (frame.type === "agent_stopped") return outstanding.sequence;
    const code = correlatedRejectionCode(frame);
    if (code === "invalid_request") {
      if (retried) {
        break;
      }
      retried = true;
      outstanding = { messageId: bestEffortStopAgent(transport, sessionId, sequences.postSend, reason), sequence: sequences.postSend };
      continue;
    }
    if (code === "agent_not_found") break;
  }
  return undefined;
}

function correlatedRejectionCode(frame: { type?: unknown; payload?: unknown }): string | undefined {
  if (frame.type !== "agent_error" && frame.type !== "nack") return undefined;
  const payload = frame.payload;
  if (payload === undefined || typeof payload !== "object" || payload === null) return undefined;
  const record = payload as Record<string, unknown>;
  const code = typeof record.code === "string" ? record.code : typeof record.error_code === "string" ? record.error_code : undefined;
  if (code === "invalid_sequence") return "invalid_request";
  return code;
}
