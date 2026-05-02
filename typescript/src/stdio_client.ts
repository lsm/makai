import { ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { createInterface, Interface as ReadlineInterface } from "node:readline";
import { BinaryResolverOptions, resolveMakaiBinary } from "./binary_resolver";

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
};

/** @deprecated Use MakaiStdioClientOptions. Kept for backward compatibility. */
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
};

const STREAM_FRAME_QUEUE_TTL_MS = 30_000;

export class MakaiStdioClient {
  private readonly options: Required<Pick<MakaiStdioClientOptions, "args" | "expectedProtocolVersion" | "handshakeTimeoutMs" | "streamFrameQueueTtlMs">> &
    Omit<MakaiStdioClientOptions, "args" | "expectedProtocolVersion" | "handshakeTimeoutMs" | "streamFrameQueueTtlMs">;
  private child: ChildProcessWithoutNullStreams | null = null;
  private lineReader: ReadlineInterface | null = null;
  private pendingHandshake: PendingHandshake | null = null;
  private frameQueue: StdioFrame[] = [];
  private frameWaiters: PendingFrameWaiter[] = [];
  private streamFrameQueues = new Map<string, StreamQueueEntry[]>();
  private streamReadLock: Promise<void> = Promise.resolve();

  constructor(options: MakaiStdioClientOptions) {
    this.options = {
      ...options,
      args: options.args ?? [],
      expectedProtocolVersion: options.expectedProtocolVersion ?? "1",
      handshakeTimeoutMs: options.handshakeTimeoutMs ?? 1500,
      streamFrameQueueTtlMs: options.streamFrameQueueTtlMs ?? STREAM_FRAME_QUEUE_TTL_MS,
    };
  }

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

  send(frame: StdioFrame): void {
    if (!this.child) {
      throw new Error("client is not connected");
    }
    this.child.stdin.write(`${JSON.stringify(frame)}\n`);
  }

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

  async nextFrameForStream(streamId: string, timeoutMs = 1000): Promise<StdioFrame> {
    if (streamId.length === 0) {
      throw new Error("streamId is required");
    }

    const queued = this.dequeueStreamFrame(streamId);
    if (queued) return queued;

    const deadline = Date.now() + timeoutMs;
    return this.withStreamReadLock(async () => {
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
        if (frameStreamId) {
          this.enqueueStreamFrame(frameStreamId, frame);
        }
        // Frames without stream_id cannot be routed to a stream-specific waiter.
      }
    });
  }

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
    this.pruneExpiredStreamFrames();
    const queued = this.streamFrameQueues.get(streamId);
    if (!queued || queued.length === 0) return undefined;
    const entry = queued.shift()!;
    if (queued.length === 0) this.streamFrameQueues.delete(streamId);
    return entry.frame;
  }

  private enqueueStreamFrame(streamId: string, frame: StdioFrame): void {
    this.pruneExpiredStreamFrames();
    const queued = this.streamFrameQueues.get(streamId) ?? [];
    queued.push({ frame, expiresAt: Date.now() + this.options.streamFrameQueueTtlMs });
    this.streamFrameQueues.set(streamId, queued);
  }

  private pruneExpiredStreamFrames(now = Date.now()): void {
    for (const [streamId, queued] of this.streamFrameQueues) {
      const unexpired = queued.filter((entry) => entry.expiresAt > now);
      if (unexpired.length > 0) {
        if (unexpired.length !== queued.length) {
          this.streamFrameQueues.set(streamId, unexpired);
        }
      } else {
        this.streamFrameQueues.delete(streamId);
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

export type CreateMakaiStdioClientOptions = Omit<MakaiStdioClientOptions, "command"> & {
  command?: string;
  resolver?: BinaryResolverOptions;
};

/** @deprecated Use CreateMakaiStdioClientOptions. Kept for backward compatibility. */
export type CreateMakaiClientOptions = CreateMakaiStdioClientOptions;

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
