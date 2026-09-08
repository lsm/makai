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
 *
 * @returns The stop envelope's `message_id` — the server correlates its
 * `agent_stopped` reply to it, so a subsequent drain can distinguish the
 * current stop's reply from stale terminal frames on the same route.
 */
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
    // Best-effort teardown; ignore transport errors here so we keep
    // surfacing the caller's own result or failure. The id is still
    // returned: no reply will name it, so a correlated drain simply runs
    // to quiescence.
  }
  return messageId;
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
 * its deadline, this returns as soon as the peer acknowledges the session's
 * teardown — the CURRENT stop's `agent_stopped` reply (identified by
 * `opts.stopReplyTo`, the message id {@link bestEffortStopAgent} returned) is
 * the server's last possible frame for the session, so nothing further can
 * poison a later run reusing the id — or when an idle window passes with no
 * frame.
 *
 * Only a reply correlated to the current stop ends the drain early. Terminal-
 * SHAPED frames that do not name it are stale or belong to the just-failed
 * run: the failure pair's uncorrelated settlement `agent_error` (§13.4.2)
 * arrives BEFORE the stop's reply, and an `agent_stopped` replying to an
 * earlier stop on the same id may still sit on the route — exiting on either
 * (the old any-terminal-frame rule) left the current stop's reply queued,
 * where a LATER run's drain could terminate on it early and leave that run's
 * trailing terminal frame for a subsequent run to claim as its own
 * completion. Without `stopReplyTo` no frame ends the drain early; it runs to
 * quiescence.
 *
 * The `maxMs` budget covers read-lock acquisition too: the per-read timeout
 * only starts once the transport's read lock is granted, and the lock can be
 * held by a concurrent long-lived read on the shared transport, so the read
 * is raced against the remaining budget — and on timeout the pending read is
 * aborted via its signal, which re-routes any frame it had dequeued instead
 * of letting it be consumed after this drain has given up.
 */
export async function drainSessionFramesUntilQuiescent(
  transport: MakaiStdioClient,
  sessionId: string,
  opts: { stopReplyTo?: string } = {},
  idleMs = 50,
  maxMs = 250,
): Promise<void> {
  const deadline = Date.now() + maxMs;
  while (Date.now() < deadline) {
    const remaining = deadline - Date.now();
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
    // Clear the losing side's timer so a read that settles first does not
    // keep the event loop alive (or accumulate timers) until the deadline.
    if (budgetTimer !== undefined) clearTimeout(budgetTimer);
    if (!frame) return;
    // The CURRENT stop's correlated reply is the server's final word for the
    // session; exiting on positive acknowledgement beats waiting out the idle
    // window and cannot miss a later trailing frame. Frames not naming our
    // stop keep draining (see the doc comment for why terminal-shaped alone
    // is not sufficient).
    if (opts.stopReplyTo !== undefined && frame.type === "agent_stopped" && frame.in_reply_to === opts.stopReplyTo) return;
  }
}
