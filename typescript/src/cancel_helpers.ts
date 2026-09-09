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
 *
 * `opts` is APPENDED after the pre-existing positional arguments so callers
 * written against the original `(transport, sessionId, idleMs, maxMs)`
 * signature keep compiling — and already-built JavaScript keeps landing each
 * positional argument where it belongs.
 */
export async function drainSessionFramesUntilQuiescent(
  transport: MakaiStdioClient,
  sessionId: string,
  idleMs = 50,
  maxMs = 250,
  opts: { stopReplyTo?: string } = {},
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

/**
 * Sends the cleanup `agent_stop` for an UNRESOLVED `agent_message` outcome by
 * probing BOTH possible server counter states (spec §13.4.1, #210 gap 7):
 * acceptance has no positive receipt, so after a timeout or lost output the
 * server's expected inbound sequence may still be the PRE-send value (the
 * message was rejected and the counter rolled back) or the POST-send value
 * (the message was accepted and its output was merely lost or delayed).
 *
 * The probe sends the stop at `preSend` first and waits (bounded) for its
 * correlated reply: a request-correlated `invalid_request` rejection (either
 * the `agent_error` or the `nack` shape) proves the counter advanced, so the
 * stop is retried exactly ONCE at `postSend`; a correlated `agent_stopped`
 * settles cleanup at whichever value the stop carried. Any other outcome —
 * `agent_not_found` (the session is already gone), a non-`invalid_request`
 * rejection, or the bounded wait expiring quiescent — ends the probe without
 * a retry. Acceptance at either value settles cleanup; neither marks the
 * message as duplicated.
 *
 * Uncorrelated frames read during the wait are dropped: the probe runs only
 * on a dead attempt's teardown, and the late run output it may consume was
 * already lost to the caller's timeout.
 *
 * @returns The sequence at which the stop was accepted, or `undefined` when
 * the probe ended unresolved (no reply, session already gone, or both
 * candidate states rejected).
 */
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
    if (budgetTimer !== undefined) clearTimeout(budgetTimer);
    if (!frame) break;
    if (frame.in_reply_to !== outstanding.messageId) continue;
    if (frame.type === "agent_stopped") return outstanding.sequence;
    const code = correlatedRejectionCode(frame);
    if (code === "invalid_request" && !retried) {
      // The server counter holds the post-send state — retry the stop there.
      retried = true;
      outstanding = { messageId: bestEffortStopAgent(transport, sessionId, sequences.postSend, reason), sequence: sequences.postSend };
      continue;
    }
    if (code === "agent_not_found") break;
    // Other correlated replies (e.g. fixture acks) prove nothing either way;
    // the idle window ends the probe if nothing terminal follows.
  }
  return undefined;
}

/**
 * Extracts the rejection code from a request-correlated reply frame — the
 * real server rejects with an `agent_error` (`payload.code`); peers and test
 * fixtures may use the `nack` shape (`payload.error_code`).
 */
function correlatedRejectionCode(frame: { type?: unknown; payload?: unknown }): string | undefined {
  if (frame.type !== "agent_error" && frame.type !== "nack") return undefined;
  const payload = frame.payload;
  if (payload === undefined || typeof payload !== "object" || payload === null) return undefined;
  const record = payload as Record<string, unknown>;
  if (typeof record.code === "string") return record.code;
  if (typeof record.error_code === "string") return record.error_code;
  return undefined;
}
