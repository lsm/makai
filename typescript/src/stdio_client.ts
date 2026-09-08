import { ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { createInterface, Interface as ReadlineInterface } from "node:readline";
import { BinaryResolverOptions, resolveMakaiBinary } from "./binary_resolver";
import { getNoopLogger, isNoopLogger, type MakaiLogger } from "./logger";

/** A single JSON-line protocol frame exchanged with `makai --stdio`. */
export type StdioFrame = {
  type: string;
  [key: string]: unknown;
};

/** Options for constructing a {@link MakaiStdioClient}. */
export type MakaiStdioClientOptions = {
  command: string;
  args?: string[];
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  expectedProtocolVersion?: string;
  handshakeTimeoutMs?: number;
  streamFrameQueueTtlMs?: number;
  logger?: MakaiLogger;
};

/** @deprecated Use MakaiStdioClientOptions. Kept for backward compatibility. */
export type MakaiClientOptions = MakaiStdioClientOptions;

/** Error raised for stdio protocol negotiation failures. */
export class StdioProtocolError extends Error {
  /**
   * @param message Human-readable protocol failure.
   * @param code Optional protocol error code.
   */
  constructor(
    message: string,
    public readonly code?: string,
  ) {
    super(message);
    this.name = "StdioProtocolError";
  }
}

type PendingFrameWaiter = {
  resolve: (frame: StdioFrame) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
};

type PendingHandshake = {
  resolve: () => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
};

type StreamQueueEntry = {
  frame: StdioFrame;
  expiresAt: number;
  /** `in_reply_to` of the parked frame, when it carries one. */
  replyTo?: string;
};

/**
 * Options for the targeted frame waits ({@link MakaiStdioClient.nextFrameForStream}
 * / {@link MakaiStdioClient.nextFrameForSession}).
 */
export type FrameWaitOptions = {
  /**
   * `message_id` of the outstanding request this wait is correlated with.
   * While the wait is in flight, a frame whose `in_reply_to` equals
   * `correlate` is delivered to THIS waiter — even when other waiters share
   * the same stream/session route — and a frame replying to another
   * registered request is parked on that request's reply queue instead of
   * the shared route (spec §13.3.1, issue #201). Frames without
   * `in_reply_to`, or whose `in_reply_to` matches no registered request,
   * keep stream/session-routed behavior.
   */
  correlate?: string;
  /**
   * Deliver ONLY frames replying to `correlate` (requires `correlate`):
   * everything else read on the shared route — including frames without
   * `in_reply_to` — is parked for its owner instead of consumed. Use while a
   * request's reply is outstanding and the caller does not yet own the
   * session's output (pre-acceptance agent waits): consuming uncorrelated
   * frames there would eat the established run's async output, and parking
   * them cannot spin because a replies-only waiter never dequeues what it
   * parks.
   */
  repliesOnly?: boolean;
};

/** Options for {@link MakaiStdioClient.nextFrameForSession}. */
export type SessionFrameWaitOptions = FrameWaitOptions & {
  /** Abandons the wait; an in-flight read re-routes its frame instead of consuming it. */
  signal?: AbortSignal;
};

const STREAM_FRAME_QUEUE_TTL_MS = 30_000;

/** Low-level stdio transport client used by higher-level Makai APIs. */
export class MakaiStdioClient {
  private readonly options: Required<Pick<MakaiStdioClientOptions, "args" | "expectedProtocolVersion" | "handshakeTimeoutMs" | "streamFrameQueueTtlMs">> &
    Omit<MakaiStdioClientOptions, "args" | "expectedProtocolVersion" | "handshakeTimeoutMs" | "streamFrameQueueTtlMs">;
  private readonly logger: MakaiLogger;
  private child: ChildProcessWithoutNullStreams | null = null;
  private lineReader: ReadlineInterface | null = null;
  private pendingHandshake: PendingHandshake | null = null;
  private frameQueue: StdioFrame[] = [];
  private frameWaiters: PendingFrameWaiter[] = [];
  private streamFrameQueues = new Map<string, StreamQueueEntry[]>();
  private sessionFrameQueues = new Map<string, StreamQueueEntry[]>();
  private replyFrameQueues = new Map<string, StreamQueueEntry[]>();
  private activeCorrelates = new Map<string, number>();
  private correlateDeliveries = new Map<string, { signal: () => void; state: { settled: boolean } }>();
  private streamReadLock: Promise<void> = Promise.resolve();

  /**
   * @param options Command, process, handshake, and queue options.
   */
  constructor(options: MakaiStdioClientOptions) {
    this.options = {
      ...options,
      args: options.args ?? [],
      expectedProtocolVersion: options.expectedProtocolVersion ?? "1",
      handshakeTimeoutMs: options.handshakeTimeoutMs ?? 1500,
      streamFrameQueueTtlMs: options.streamFrameQueueTtlMs ?? STREAM_FRAME_QUEUE_TTL_MS,
    };
    this.logger = options.logger ?? getNoopLogger();
  }

  /**
   * Spawns the stdio process and waits for the protocol handshake.
   *
   * @throws If the client is already connected, the process errors, or handshake fails.
   */
  async connect(): Promise<void> {
    if (this.child) {
      throw new Error("client is already connected");
    }

    this.logger.debug("stdio: spawning process", { command: this.options.command, args: this.options.args });

    const child = spawn(this.options.command, this.options.args, {
      cwd: this.options.cwd,
      env: this.options.env,
      stdio: "pipe",
    });
    this.child = child;

    child.on("error", (error) => {
      this.logger.error("stdio: process error event", { error: error.message });
      this.failHandshakeIfPending(error);
      this.failPendingFrameWaiters(error);
    });

    child.on("exit", (code, signal) => {
      this.logger.debug("stdio: process exited", { code, signal: signal ?? undefined });
      const error = new Error(`stdio process exited (code=${code}, signal=${signal})`);
      this.failHandshakeIfPending(error);
      this.failPendingFrameWaiters(error);
      this.cleanupProcessHandles();
    });

    this.lineReader = createInterface({ input: child.stdout });
    this.lineReader.on("line", (line) => this.handleLine(line));

    this.logger.debug("stdio: waiting for handshake", { timeout_ms: this.options.handshakeTimeoutMs });
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error(`stdio handshake timed out after ${this.options.handshakeTimeoutMs}ms`));
        this.pendingHandshake = null;
      }, this.options.handshakeTimeoutMs);
      this.pendingHandshake = { resolve, reject, timer };
    });
    this.logger.info("stdio: handshake complete");
  }

  /**
   * Sends one JSON frame to the child process.
   *
   * @param frame Frame to serialize and write.
   * @throws If the client is not connected.
   */
  send(frame: StdioFrame): void {
    if (!this.child) {
      throw new Error("client is not connected");
    }
    if (!isNoopLogger(this.logger)) {
      this.logger.debug("stdio: sending frame", { type: frame.type, stream_id: frame.stream_id, session_id: frame.session_id, sequence: frame.sequence });
    }
    this.child.stdin.write(`${JSON.stringify(frame)}\n`);
  }

  /**
   * Waits for the next unrouted frame from the transport.
   *
   * @param timeoutMs Maximum wait time in milliseconds.
   * @returns The next frame.
   * @throws If no frame arrives before the timeout.
   */
  nextFrame(timeoutMs = 1000): Promise<StdioFrame> {
    if (this.frameQueue.length > 0) {
      return Promise.resolve(this.frameQueue.shift()!);
    }
    return new Promise<StdioFrame>((resolve, reject) => {
      const waiter = { resolve, reject, timer: undefined as unknown as NodeJS.Timeout };
      waiter.timer = setTimeout(() => {
        // Remove the timed-out waiter: handleLine resolves waiters FIFO
        // without checking settlement, so a stale entry here would have the
        // next incoming frame delivered to an already-rejected promise and
        // silently dropped.
        const index = this.frameWaiters.indexOf(waiter);
        if (index >= 0) this.frameWaiters.splice(index, 1);
        reject(new Error(`timed out waiting for frame after ${timeoutMs}ms`));
      }, timeoutMs);
      this.frameWaiters.push(waiter);
    });
  }

  /**
   * Waits for the next frame matching a stream ID.
   *
   * @param streamId Stream identifier to route by.
   * @param timeoutMs Maximum wait time in milliseconds.
   * @param options Correlation options; see {@link FrameWaitOptions}.
   * @returns The next matching frame.
   * @throws If `streamId` is empty or no matching frame arrives before timeout.
   */
  async nextFrameForStream(streamId: string, timeoutMs = 1000, options?: FrameWaitOptions): Promise<StdioFrame> {
    if (streamId.length === 0) {
      throw new Error("streamId is required");
    }
    return this.waitForRoutedFrame("stream", streamId, timeoutMs, options);
  }

  /**
   * Waits for the next frame matching an agent session ID.
   *
   * @param sessionId Session identifier to route by.
   * @param timeoutMs Maximum wait time in milliseconds.
   * @param options Correlation and abort options; see {@link SessionFrameWaitOptions}.
   * @returns The next matching frame.
   * @throws If `sessionId` is empty or no matching frame arrives before timeout.
   */
  async nextFrameForSession(sessionId: string, timeoutMs = 1000, options?: SessionFrameWaitOptions): Promise<StdioFrame> {
    if (sessionId.length === 0) {
      throw new Error("sessionId is required");
    }
    return this.waitForRoutedFrame("session", sessionId, timeoutMs, options);
  }

  /**
   * Shared implementation of the targeted frame waits. A waiter dequeues from
   * its own routes — the reply queue keyed by its `correlate` (registered for
   * the whole duration of this call, including while queued behind the read
   * lock) first, then its stream/session queue — and, under the read lock,
   * routes every inbound frame with `in_reply_to`-awareness (spec §13.3.1,
   * #201): a reply to a REGISTERED outstanding request is delivered only to
   * that request's waiter, never to a waiter that merely shares the
   * stream/session route, so overlapping calls on one route cannot consume
   * each other's replies. Re-routing never targets a queue the re-routing
   * waiter itself dequeues from, so a shared route cannot spin.
   *
   * A correlated wait races its read-lock loop against a poke: the current
   * lock holder parks a reply to `correlate` in this wait's reply queue and
   * pokes it, so delivery does not wait for the holder's lock to cycle (the
   * holder may be blocked for its full timeout on a silent route).
   */
  private async waitForRoutedFrame(
    route: "stream" | "session",
    routeId: string,
    timeoutMs: number,
    options?: FrameWaitOptions & { signal?: AbortSignal },
  ): Promise<StdioFrame> {
    const correlate = options?.correlate;
    if (correlate !== undefined) this.retainCorrelate(correlate);
    try {
      const queued = this.dequeueOwnFrame(route, routeId, correlate, options?.repliesOnly);
      if (queued) return queued;

      if (correlate === undefined) {
        return await this.withStreamReadLock(() => this.readRoutedLoop(route, routeId, timeoutMs, options));
      }

      const state = { settled: false };
      let signalPoke!: () => void;
      const poke = new Promise<void>((resolve) => {
        signalPoke = resolve;
      });
      this.correlateDeliveries.set(correlate, { signal: signalPoke, state });
      let winner: StdioFrame | undefined;
      try {
        winner = await Promise.race([
          this.withStreamReadLock(async () => {
            // The wait settled via a poke while queued behind the read lock:
            // exit without reading so the next lock holder owns all reads.
            if (state.settled) throw new Error(`frame wait for ${route} ${routeId} superseded`);
            return await this.readRoutedLoop(route, routeId, timeoutMs, options);
          }),
          poke.then(() => {
            // The wait was abandoned before its parked reply was claimed:
            // reject like an aborted read and leave the reply parked for the
            // replacement waiter instead of fulfilling with it.
            if (options?.signal?.aborted) {
              throw new Error(`frame wait for session ${routeId} aborted`);
            }
            return this.dequeueRoutedFrame(this.replyFrameQueues, correlate);
          }),
        ]);
      } finally {
        state.settled = true;
        if (this.correlateDeliveries.get(correlate)?.state === state) this.correlateDeliveries.delete(correlate);
      }
      if (winner !== undefined) return winner;
      // Spurious poke (the reply is no longer queued): one more lock-gated
      // pass. Its per-iteration dequeue re-checks the reply queue, and parks
      // for this correlate now land there without a poke slot.
      return await this.withStreamReadLock(() => this.readRoutedLoop(route, routeId, timeoutMs, options));
    } finally {
      if (correlate !== undefined) this.releaseCorrelate(correlate);
    }
  }

  private async readRoutedLoop(
    route: "stream" | "session",
    routeId: string,
    timeoutMs: number,
    options?: FrameWaitOptions & { signal?: AbortSignal },
  ): Promise<StdioFrame> {
    if (options?.signal?.aborted) {
      throw new Error(`frame wait for session ${routeId} aborted`);
    }
    const deadline = Date.now() + timeoutMs;
    while (true) {
      const remainingMs = deadline - Date.now();
      if (remainingMs <= 0) {
        throw new Error(`timed out waiting for frame for ${route} ${routeId} after ${timeoutMs}ms`);
      }

      const queued = this.dequeueOwnFrame(route, routeId, options?.correlate, options?.repliesOnly);
      if (queued) return queued;

      let frame: StdioFrame;
      try {
        frame = await this.nextFrame(remainingMs);
      } catch (error) {
        if (deadline - Date.now() <= 0 || isNextFrameTimeout(error, remainingMs)) {
          throw new Error(`timed out waiting for frame for ${route} ${routeId} after ${timeoutMs}ms`);
        }
        throw error;
      }
      if (options?.signal?.aborted) {
        // The wait was abandoned while its read was in flight: put the
        // frame back so the waiter it actually belongs to can still
        // receive it, instead of consuming it here.
        this.enqueueRoutableFrame(frame);
        throw new Error(`frame wait for session ${routeId} aborted`);
      }
      const frameReplyTo = typeof frame.in_reply_to === "string" ? frame.in_reply_to : undefined;
      if (options?.correlate !== undefined && frameReplyTo === options.correlate) return frame;
      if (frameReplyTo !== undefined && this.hasActiveCorrelate(frameReplyTo)) {
        // Reply to another waiter's outstanding request: park it on that
        // request's reply queue (and poke the waiter if it is queued behind
        // this lock) instead of consuming it off the shared route.
        this.enqueueRoutableFrame(frame);
        continue;
      }
      if (frameReplyTo !== undefined && options?.correlate !== undefined) {
        // Reply to a request that is not currently registered — its owner
        // may simply be between waits (the correlate is retained per frame
        // wait, not per SDK attempt). A correlated waiter must not consume
        // it off the shared route even then (§13.3.1): park it with its
        // replyTo recorded so the owner's next dequeue claims it and other
        // correlated waiters skip it; uncorrelated waiters keep taking it.
        this.enqueueRoutableFrame(frame);
        continue;
      }
      if (options?.repliesOnly) {
        // This waiter's request reply is still outstanding: nothing
        // uncorrelated on the shared route is its to consume — park the
        // frame (unmarked; its owner or a drain takes it) and keep waiting.
        // Parking cannot spin: a replies-only waiter only dequeues entries
        // whose replyTo equals its correlate.
        this.enqueueRoutableFrame(frame);
        continue;
      }
      if (this.frameMatchesRoute(frame, route, routeId)) return frame;
      this.enqueueRoutableFrame(frame);
      // Frames without stream_id/session_id cannot be routed to a targeted waiter.
    }
  }

  /**
   * Closes the child process and releases local handles.
   *
   * @returns A promise that resolves after graceful shutdown or forced termination.
   */
  async close(): Promise<void> {
    if (!this.child) return;

    this.logger.debug("stdio: closing transport");
    const child = this.child;
    child.stdin.end();
    await Promise.race([
      new Promise<void>((resolve) => {
        child.once("exit", () => resolve());
      }),
      new Promise<void>((resolve) => {
        setTimeout(() => {
          if (child.exitCode === null) {
            child.kill();
          }
          resolve();
        }, 200);
      }),
    ]);

    this.cleanupProcessHandles();
  }

  private dequeueStreamFrame(streamId: string): StdioFrame | undefined {
    return this.dequeueRoutedFrame(this.streamFrameQueues, streamId);
  }

  private dequeueSessionFrame(sessionId: string): StdioFrame | undefined {
    return this.dequeueRoutedFrame(this.sessionFrameQueues, sessionId);
  }

  /**
   * Dequeues for one waiter: its correlate-keyed reply queue first, then its
   * stream/session queue. On the shared route a correlated waiter claims the
   * first entry that is not a reply to a DIFFERENT request — entries parked
   * with a replyTo (e.g. while their owner was between waits) are skipped
   * until their owner (or an uncorrelated waiter) takes them; an entry whose
   * replyTo equals this waiter's correlate is its own parked reply and is
   * claimed. A replies-only waiter additionally skips entries with no
   * replyTo: while its request's reply is outstanding nothing uncorrelated
   * on the route is its to consume.
   */
  private dequeueOwnFrame(route: "stream" | "session", routeId: string, correlate?: string, repliesOnly = false): StdioFrame | undefined {
    this.pruneExpiredRoutedFrames();
    if (correlate !== undefined) {
      const reply = this.dequeueRoutedFrame(this.replyFrameQueues, correlate);
      if (reply) return reply;
    }
    const queues = route === "stream" ? this.streamFrameQueues : this.sessionFrameQueues;
    const queued = queues.get(routeId);
    if (!queued || queued.length === 0) return undefined;
    let index: number;
    if (correlate === undefined) {
      index = 0;
    } else if (repliesOnly) {
      index = queued.findIndex((entry) => entry.replyTo === correlate);
    } else {
      index = queued.findIndex((entry) => entry.replyTo === undefined || entry.replyTo === correlate);
    }
    if (index < 0) return undefined;
    const [entry] = queued.splice(index, 1);
    if (queued.length === 0) queues.delete(routeId);
    return entry.frame;
  }

  private frameMatchesRoute(frame: StdioFrame, route: "stream" | "session", routeId: string): boolean {
    if (route === "stream") {
      return typeof frame.stream_id === "string" && frame.stream_id === routeId;
    }
    return typeof frame.session_id === "string" && frame.session_id === routeId;
  }

  private dequeueRoutedFrame(queues: Map<string, StreamQueueEntry[]>, id: string): StdioFrame | undefined {
    this.pruneExpiredRoutedFrames();
    const queued = queues.get(id);
    if (!queued || queued.length === 0) return undefined;
    const entry = queued.shift()!;
    if (queued.length === 0) queues.delete(id);
    return entry.frame;
  }

  private enqueueRoutableFrame(frame: StdioFrame): void {
    const frameReplyTo = typeof frame.in_reply_to === "string" ? frame.in_reply_to : undefined;
    if (frameReplyTo !== undefined && this.hasActiveCorrelate(frameReplyTo)) {
      // §13.3.1: the frame replies to a registered outstanding request —
      // park it on that request's reply queue, never on a shared route a
      // foreign waiter could consume it from.
      this.deliverCorrelatedFrame(frameReplyTo, frame);
      return;
    }
    const frameStreamId = typeof frame.stream_id === "string" ? frame.stream_id : undefined;
    if (frameStreamId) {
      this.enqueueRoutedFrame(this.streamFrameQueues, frameStreamId, frame, frameReplyTo);
      return;
    }
    const frameSessionId = typeof frame.session_id === "string" ? frame.session_id : undefined;
    if (frameSessionId) {
      this.enqueueRoutedFrame(this.sessionFrameQueues, frameSessionId, frame, frameReplyTo);
    }
  }

  /**
   * Parks a reply on its request's reply queue and pokes the request's
   * waiter if it is currently queued behind the read lock (a settled or
   * absent poke slot just leaves the frame parked for the waiter's next
   * dequeue). Enqueueing before poking lets the poked waiter dequeue the
   * frame synchronously in its poke continuation.
   */
  private deliverCorrelatedFrame(correlate: string, frame: StdioFrame): void {
    this.enqueueRoutedFrame(this.replyFrameQueues, correlate, frame, correlate);
    const pending = this.correlateDeliveries.get(correlate);
    if (pending && !pending.state.settled) pending.signal();
  }

  private enqueueRoutedFrame(queues: Map<string, StreamQueueEntry[]>, id: string, frame: StdioFrame, replyTo?: string): void {
    this.pruneExpiredRoutedFrames();
    const queued = queues.get(id) ?? [];
    queued.push({ frame, expiresAt: Date.now() + this.options.streamFrameQueueTtlMs, replyTo });
    queues.set(id, queued);
  }

  private retainCorrelate(correlate: string): void {
    this.activeCorrelates.set(correlate, (this.activeCorrelates.get(correlate) ?? 0) + 1);
  }

  private releaseCorrelate(correlate: string): void {
    const count = (this.activeCorrelates.get(correlate) ?? 0) - 1;
    if (count > 0) this.activeCorrelates.set(correlate, count);
    else this.activeCorrelates.delete(correlate);
  }

  private hasActiveCorrelate(correlate: string): boolean {
    return (this.activeCorrelates.get(correlate) ?? 0) > 0;
  }

  private pruneExpiredRoutedFrames(now = Date.now()): void {
    this.pruneExpiredQueue(this.streamFrameQueues, now);
    this.pruneExpiredQueue(this.sessionFrameQueues, now);
    this.pruneExpiredQueue(this.replyFrameQueues, now);
  }

  private pruneExpiredQueue(queues: Map<string, StreamQueueEntry[]>, now: number): void {
    for (const [id, queued] of queues) {
      const unexpired = queued.filter((entry) => entry.expiresAt > now);
      if (unexpired.length > 0) {
        if (unexpired.length !== queued.length) {
          queues.set(id, unexpired);
        }
      } else {
        queues.delete(id);
      }
    }
  }

  private async withStreamReadLock<T>(operation: () => Promise<T>): Promise<T> {
    const previous = this.streamReadLock;
    let release!: () => void;
    this.streamReadLock = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    try {
      return await operation();
    } finally {
      release();
    }
  }

  private handleLine(line: string): void {
    let frame: StdioFrame;
    try {
      frame = JSON.parse(line) as StdioFrame;
    } catch {
      this.logger.error("stdio: invalid JSON frame received", { line: line.length > 200 ? line.slice(0, 200) + "..." : line });
      this.failHandshakeIfPending(new Error(`invalid JSON frame: ${line}`));
      return;
    }

    if (!isNoopLogger(this.logger)) {
      this.logger.debug("stdio: received frame", { type: frame.type, stream_id: frame.stream_id, session_id: frame.session_id, sequence: frame.sequence });
    }

    if (this.pendingHandshake) {
      const pending = this.pendingHandshake;
      this.pendingHandshake = null;
      clearTimeout(pending.timer);

      if (frame.type === "error") {
        pending.reject(
          new StdioProtocolError(
            String(frame.message ?? "stdio handshake failed"),
            typeof frame.code === "string" ? frame.code : undefined,
          ),
        );
        return;
      }

      if (frame.type !== "ready") {
        pending.reject(new Error(`unexpected handshake frame type: ${frame.type}`));
        return;
      }

      const protocolVersion = String(frame.protocol_version ?? "");
      if (protocolVersion !== this.options.expectedProtocolVersion) {
        pending.reject(
          new StdioProtocolError(
            `protocol version mismatch (expected ${this.options.expectedProtocolVersion}, got ${protocolVersion})`,
            "version_mismatch",
          ),
        );
        return;
      }

      pending.resolve();
      return;
    }

    if (this.frameWaiters.length > 0) {
      const waiter = this.frameWaiters.shift()!;
      clearTimeout(waiter.timer);
      waiter.resolve(frame);
      return;
    }
    this.frameQueue.push(frame);
  }

  private failHandshakeIfPending(error: Error): void {
    if (!this.pendingHandshake) return;
    const pending = this.pendingHandshake;
    this.pendingHandshake = null;
    clearTimeout(pending.timer);
    pending.reject(error);
  }

  private failPendingFrameWaiters(error: Error): void {
    const waiters = this.frameWaiters.splice(0);
    for (const waiter of waiters) {
      clearTimeout(waiter.timer);
      waiter.reject(error);
    }
  }

  private cleanupProcessHandles(): void {
    this.lineReader?.close();
    this.lineReader = null;
    this.child = null;
  }
}

function isNextFrameTimeout(error: unknown, timeoutMs: number): boolean {
  return error instanceof Error && error.message === `timed out waiting for frame after ${timeoutMs}ms`;
}

/** Options for {@link createMakaiStdioClient}; `command` is optional and can be resolved automatically. */
export type CreateMakaiStdioClientOptions = Omit<MakaiStdioClientOptions, "command"> & {
  command?: string;
  resolver?: BinaryResolverOptions;
};

/** @deprecated Use CreateMakaiStdioClientOptions. Kept for backward compatibility. */
export type CreateMakaiClientOptions = CreateMakaiStdioClientOptions;

/**
 * Creates an unconnected {@link MakaiStdioClient}, resolving the binary if needed.
 *
 * @param options Transport and binary resolver options.
 * @returns A stdio client; call {@link MakaiStdioClient.connect} before use.
 * @throws If binary resolution fails.
 */
export async function createMakaiStdioClient(
  options: CreateMakaiStdioClientOptions = {},
): Promise<MakaiStdioClient> {
  const resolverWithLogger: BinaryResolverOptions = options.logger
    ? { ...options.resolver, logger: options.logger }
    : options.resolver ?? {};
  const command = options.command ?? (await resolveMakaiBinary(resolverWithLogger));
  const args = options.args ?? ["--stdio"];
  return new MakaiStdioClient({
    command,
    args,
    cwd: options.cwd,
    env: options.env,
    expectedProtocolVersion: options.expectedProtocolVersion,
    handshakeTimeoutMs: options.handshakeTimeoutMs,
    streamFrameQueueTtlMs: options.streamFrameQueueTtlMs,
    logger: options.logger,
  });
}
