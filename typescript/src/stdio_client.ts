import { ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { createInterface, Interface as ReadlineInterface } from "node:readline";
import { BinaryResolverOptions, resolveMakaiBinary } from "./binary_resolver";

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
};

const STREAM_FRAME_QUEUE_TTL_MS = 30_000;

/** Low-level stdio transport client used by higher-level Makai APIs. */
export class MakaiStdioClient {
  private readonly options: Required<Pick<MakaiStdioClientOptions, "args" | "expectedProtocolVersion" | "handshakeTimeoutMs" | "streamFrameQueueTtlMs">> &
    Omit<MakaiStdioClientOptions, "args" | "expectedProtocolVersion" | "handshakeTimeoutMs" | "streamFrameQueueTtlMs">;
  private child: ChildProcessWithoutNullStreams | null = null;
  private lineReader: ReadlineInterface | null = null;
  private pendingHandshake: PendingHandshake | null = null;
  private frameQueue: StdioFrame[] = [];
  private frameWaiters: PendingFrameWaiter[] = [];
  private streamFrameQueues = new Map<string, StreamQueueEntry[]>();
  private sessionFrameQueues = new Map<string, StreamQueueEntry[]>();
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

    const child = spawn(this.options.command, this.options.args, {
      cwd: this.options.cwd,
      env: this.options.env,
      stdio: "pipe",
    });
    this.child = child;

    child.on("error", (error) => {
      this.failHandshakeIfPending(error);
      this.failPendingFrameWaiters(error);
    });

    child.on("exit", (code, signal) => {
      const error = new Error(`stdio process exited (code=${code}, signal=${signal})`);
      this.failHandshakeIfPending(error);
      this.failPendingFrameWaiters(error);
      this.cleanupProcessHandles();
    });

    this.lineReader = createInterface({ input: child.stdout });
    this.lineReader.on("line", (line) => this.handleLine(line));

    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error(`stdio handshake timed out after ${this.options.handshakeTimeoutMs}ms`));
        this.pendingHandshake = null;
      }, this.options.handshakeTimeoutMs);
      this.pendingHandshake = { resolve, reject, timer };
    });
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
      const timer = setTimeout(() => {
        reject(new Error(`timed out waiting for frame after ${timeoutMs}ms`));
      }, timeoutMs);
      this.frameWaiters.push({ resolve, reject, timer });
    });
  }

  /**
   * Waits for the next frame matching a stream ID.
   *
   * @param streamId Stream identifier to route by.
   * @param timeoutMs Maximum wait time in milliseconds.
   * @returns The next matching frame.
   * @throws If `streamId` is empty or no matching frame arrives before timeout.
   */
  async nextFrameForStream(streamId: string, timeoutMs = 1000): Promise<StdioFrame> {
    if (streamId.length === 0) {
      throw new Error("streamId is required");
    }

    const queued = this.dequeueStreamFrame(streamId);
    if (queued) return queued;

    return this.withStreamReadLock(async () => {
      const deadline = Date.now() + timeoutMs;
      while (true) {
        const remainingMs = deadline - Date.now();
        if (remainingMs <= 0) {
          throw new Error(`timed out waiting for frame for stream ${streamId} after ${timeoutMs}ms`);
        }

        const queued = this.dequeueStreamFrame(streamId);
        if (queued) return queued;

        let frame: StdioFrame;
        try {
          frame = await this.nextFrame(remainingMs);
        } catch (error) {
          if (deadline - Date.now() <= 0 || isNextFrameTimeout(error, remainingMs)) {
            throw new Error(`timed out waiting for frame for stream ${streamId} after ${timeoutMs}ms`);
          }
          throw error;
        }
        const frameStreamId = typeof frame.stream_id === "string" ? frame.stream_id : undefined;
        if (frameStreamId === streamId) return frame;
        this.enqueueRoutableFrame(frame);
        // Frames without stream_id/session_id cannot be routed to a targeted waiter.
      }
    });
  }

  /**
   * Waits for the next frame matching an agent session ID.
   *
   * @param sessionId Session identifier to route by.
   * @param timeoutMs Maximum wait time in milliseconds.
   * @returns The next matching frame.
   * @throws If `sessionId` is empty or no matching frame arrives before timeout.
   */
  async nextFrameForSession(sessionId: string, timeoutMs = 1000): Promise<StdioFrame> {
    if (sessionId.length === 0) {
      throw new Error("sessionId is required");
    }

    const queued = this.dequeueSessionFrame(sessionId);
    if (queued) return queued;

    return this.withStreamReadLock(async () => {
      const deadline = Date.now() + timeoutMs;
      while (true) {
        const remainingMs = deadline - Date.now();
        if (remainingMs <= 0) {
          throw new Error(`timed out waiting for frame for session ${sessionId} after ${timeoutMs}ms`);
        }

        const queued = this.dequeueSessionFrame(sessionId);
        if (queued) return queued;

        let frame: StdioFrame;
        try {
          frame = await this.nextFrame(remainingMs);
        } catch (error) {
          if (deadline - Date.now() <= 0 || isNextFrameTimeout(error, remainingMs)) {
            throw new Error(`timed out waiting for frame for session ${sessionId} after ${timeoutMs}ms`);
          }
          throw error;
        }
        const frameSessionId = typeof frame.session_id === "string" ? frame.session_id : undefined;
        if (frameSessionId === sessionId) return frame;
        this.enqueueRoutableFrame(frame);
        // Frames without stream_id/session_id cannot be routed to a targeted waiter.
      }
    });
  }

  /**
   * Closes the child process and releases local handles.
   *
   * @returns A promise that resolves after graceful shutdown or forced termination.
   */
  async close(): Promise<void> {
    if (!this.child) return;

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

  private dequeueRoutedFrame(queues: Map<string, StreamQueueEntry[]>, id: string): StdioFrame | undefined {
    this.pruneExpiredRoutedFrames();
    const queued = queues.get(id);
    if (!queued || queued.length === 0) return undefined;
    const entry = queued.shift()!;
    if (queued.length === 0) queues.delete(id);
    return entry.frame;
  }

  private enqueueRoutableFrame(frame: StdioFrame): void {
    const frameStreamId = typeof frame.stream_id === "string" ? frame.stream_id : undefined;
    if (frameStreamId) {
      this.enqueueRoutedFrame(this.streamFrameQueues, frameStreamId, frame);
      return;
    }
    const frameSessionId = typeof frame.session_id === "string" ? frame.session_id : undefined;
    if (frameSessionId) {
      this.enqueueRoutedFrame(this.sessionFrameQueues, frameSessionId, frame);
    }
  }

  private enqueueRoutedFrame(queues: Map<string, StreamQueueEntry[]>, id: string, frame: StdioFrame): void {
    this.pruneExpiredRoutedFrames();
    const queued = queues.get(id) ?? [];
    queued.push({ frame, expiresAt: Date.now() + this.options.streamFrameQueueTtlMs });
    queues.set(id, queued);
  }

  private pruneExpiredRoutedFrames(now = Date.now()): void {
    this.pruneExpiredQueue(this.streamFrameQueues, now);
    this.pruneExpiredQueue(this.sessionFrameQueues, now);
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
      this.failHandshakeIfPending(new Error(`invalid JSON frame: ${line}`));
      return;
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
  const command = options.command ?? (await resolveMakaiBinary(options.resolver));
  const args = options.args ?? ["--stdio"];
  return new MakaiStdioClient({
    command,
    args,
    cwd: options.cwd,
    env: options.env,
    expectedProtocolVersion: options.expectedProtocolVersion,
    handshakeTimeoutMs: options.handshakeTimeoutMs,
    streamFrameQueueTtlMs: options.streamFrameQueueTtlMs,
  });
}
