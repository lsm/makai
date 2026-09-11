import { ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { createInterface, Interface as ReadlineInterface } from "node:readline";
import { BinaryResolverOptions, resolveMakaiBinary } from "./binary_resolver";
import { getNoopLogger, isNoopLogger, type MakaiLogger } from "./logger";

export type StdioFrame = {
  type: string;
  [key: string]: unknown;
};

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

export type MakaiClientOptions = MakaiStdioClientOptions;

export class StdioProtocolError extends Error {
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
  replyTo?: string;
};

export type FrameWaitOptions = {
  correlate?: string;
  repliesOnly?: boolean;
};

export type SessionFrameWaitOptions = FrameWaitOptions & {
  signal?: AbortSignal;
};

const STREAM_FRAME_QUEUE_TTL_MS = 30_000;

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

  send(frame: StdioFrame): void {
    if (!this.child) {
      throw new Error("client is not connected");
    }
    if (!isNoopLogger(this.logger)) {
      this.logger.debug("stdio: sending frame", { type: frame.type, stream_id: frame.stream_id, session_id: frame.session_id, sequence: frame.sequence });
    }
    this.child.stdin.write(`${JSON.stringify(frame)}\n`);
  }

  nextFrame(timeoutMs = 1000): Promise<StdioFrame> {
    if (this.frameQueue.length > 0) {
      return Promise.resolve(this.frameQueue.shift()!);
    }
    return new Promise<StdioFrame>((resolve, reject) => {
      const waiter = { resolve, reject, timer: undefined as unknown as NodeJS.Timeout };
      waiter.timer = setTimeout(() => {
        const index = this.frameWaiters.indexOf(waiter);
        if (index >= 0) this.frameWaiters.splice(index, 1);
        reject(new Error(`timed out waiting for frame after ${timeoutMs}ms`));
      }, timeoutMs);
      this.frameWaiters.push(waiter);
    });
  }

  async nextFrameForStream(streamId: string, timeoutMs = 1000, options?: FrameWaitOptions): Promise<StdioFrame> {
    if (streamId.length === 0) {
      throw new Error("streamId is required");
    }
    return this.waitForRoutedFrame("stream", streamId, timeoutMs, options);
  }

  async nextFrameForSession(sessionId: string, timeoutMs = 1000, options?: SessionFrameWaitOptions): Promise<StdioFrame> {
    if (sessionId.length === 0) {
      throw new Error("sessionId is required");
    }
    return this.waitForRoutedFrame("session", sessionId, timeoutMs, options);
  }

  private async waitForRoutedFrame(
    route: "stream" | "session",
    routeId: string,
    timeoutMs: number,
    options?: FrameWaitOptions & { signal?: AbortSignal },
  ): Promise<StdioFrame> {
    const correlate = options?.correlate;
    if (correlate !== undefined) this.retainCorrelate(correlate);
    try {
      if (options?.signal?.aborted) {
        throw new Error(`frame wait for session ${routeId} aborted`);
      }
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
            if (state.settled) throw new Error(`frame wait for ${route} ${routeId} superseded`);
            return await this.readRoutedLoop(route, routeId, timeoutMs, options);
          }),
          poke.then(() => {
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
        this.enqueueRoutableFrame(frame);
        throw new Error(`frame wait for session ${routeId} aborted`);
      }
      const frameReplyTo = typeof frame.in_reply_to === "string" ? frame.in_reply_to : undefined;
      if (options?.correlate !== undefined && frameReplyTo === options.correlate) return frame;
      if (frameReplyTo !== undefined && this.hasActiveCorrelate(frameReplyTo)) {
        this.enqueueRoutableFrame(frame);
        continue;
      }
      if (frameReplyTo !== undefined && options?.correlate !== undefined) {
        this.enqueueRoutableFrame(frame);
        continue;
      }
      if (options?.repliesOnly) {
        this.enqueueRoutableFrame(frame);
        continue;
      }
      if (this.frameMatchesRoute(frame, route, routeId)) return frame;
      this.enqueueRoutableFrame(frame);
    }
  }

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

export type CreateMakaiStdioClientOptions = Omit<MakaiStdioClientOptions, "command"> & {
  command?: string;
  resolver?: BinaryResolverOptions;
};

export type CreateMakaiClientOptions = CreateMakaiStdioClientOptions;

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
