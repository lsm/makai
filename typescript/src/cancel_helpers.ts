/**
 * Shared best-effort cancel and drain helpers for stream/session cleanup
 * on abort. Used by both the execution client and models client to send
 * cancel envelopes and drain remaining in-flight frames before propagating
 * the original abort error.
 *
 * This module is the single source of truth for the cancel/drain protocol;
 * consumers should NOT duplicate this logic locally.
 */

import { ulid } from "ulid";
import type { MakaiStdioClient } from "./stdio_client";

const ENVELOPE_VERSION = 1;

/**
 * Sends an `abort_request` envelope for the given stream, swallowing any
 * transport errors so the original abort error propagates cleanly.
 */
export function bestEffortCancelStream(transport: MakaiStdioClient, streamId: string): void {
  try {
    transport.send({
      type: "abort_request",
      stream_id: streamId,
      message_id: ulid(),
      sequence: 2, // Initial request is sequence 1; abort is the next per-stream message
      timestamp: Date.now(),
      version: ENVELOPE_VERSION,
      payload: { target_stream_id: streamId, reason: "client aborted" },
    });
  } catch {
    // Best-effort cancellation; ignore transport errors here so we keep
    // surfacing the original failure to the caller.
  }
}

/**
 * Sends an `agent_stop` envelope for the given session, swallowing any
 * transport errors so the original abort error propagates cleanly.
 */
export function bestEffortCancelAgent(transport: MakaiStdioClient, sessionId: string, sequence = 2): void {
  bestEffortStopAgent(transport, sessionId, sequence, "client aborted");
}

/**
 * Sends an `agent_stop` envelope for the given session with an explicit
 * reason, swallowing any transport errors so the caller's own result or
 * error propagates cleanly.
 *
 * `sequence` must be the session's next expected inbound sequence (start=1,
 * message=2, then one per follow-up message) — the server rejects
 * out-of-order stops, which would silently leave the session registered.
 */
export function bestEffortStopAgent(transport: MakaiStdioClient, sessionId: string, sequence: number, reason: string): void {
  try {
    transport.send({
      type: "agent_stop",
      session_id: sessionId,
      message_id: ulid(),
      sequence,
      timestamp: Date.now(),
      version: ENVELOPE_VERSION,
      payload: { session_id: sessionId, reason },
    });
  } catch {
    // Best-effort teardown; ignore transport errors here so we keep
    // surfacing the caller's own result or failure.
  }
}

/**
 * Drains remaining in-flight frames for an abandoned stream from the
 * transport buffer. Prevents orphaned frames from interfering with
 * subsequent operations on the shared transport.
 *
 * Uses a Promise.race with a per-iteration timeout so it never blocks
 * indefinitely even if the transport mock doesn't respect timeoutMs.
 */
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

/**
 * Drains remaining in-flight frames for an abandoned agent session from the
 * transport buffer.
 */
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

/**
 * Drains remaining frames for a finished agent session until the transport
 * buffer goes quiet. Unlike {@link drainSessionFrames}, which always runs to
 * its deadline, this returns as soon as an idle window passes with no frame,
 * so awaiting it after a session's terminal `agent_stop` costs one idle
 * window instead of the full drain timeout. Bounded by `maxMs` so a chatty
 * or wedged peer cannot stall the caller.
 */
export async function drainSessionFramesUntilQuiescent(
  transport: MakaiStdioClient,
  sessionId: string,
  idleMs = 50,
  maxMs = 250,
): Promise<void> {
  const deadline = Date.now() + maxMs;
  while (Date.now() < deadline) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) break;
    const waitMs = Math.min(idleMs, remaining);
    try {
      await transport.nextFrameForSession(sessionId, waitMs);
    } catch {
      // Idle window elapsed with no frame — the session buffer is quiescent.
      return;
    }
  }
}
