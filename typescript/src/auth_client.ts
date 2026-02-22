import { ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { BinaryResolverOptions, resolveMakaiBinary } from "./binary_resolver";

export type AuthProviderInfo = {
  id: string;
  name: string;
};

export type MakaiAuthEvent =
  | {
      type: "auth_url";
      provider: string;
      url: string;
      instructions?: string;
    }
  | {
      type: "prompt";
      provider: string;
      message: string;
      allow_empty: boolean;
    }
  | {
      type: "progress";
      provider: string;
      message: string;
    }
  | {
      type: "success";
      provider: string;
    }
  | {
      type: "error";
      provider: string;
      code?: string;
      message: string;
    };

export class MakaiAuthError extends Error {
  constructor(
    message: string,
    public readonly code?: string,
  ) {
    super(message);
    this.name = "MakaiAuthError";
  }
}

type SharedAuthOptions = {
  command?: string;
  args?: string[];
  resolver?: BinaryResolverOptions;
  cwd?: string;
  env?: NodeJS.ProcessEnv;
};

export type LoginWithMakaiAuthOptions = SharedAuthOptions & {
  provider?: string;
  onEvent?: (event: MakaiAuthEvent) => void;
  onPrompt?: (event: Extract<MakaiAuthEvent, { type: "prompt" }>) => string | Promise<string>;
};

export type ListMakaiAuthProvidersOptions = SharedAuthOptions & {
  onEvent?: (event: MakaiAuthEvent) => void;
};

async function resolveCommandAndArgs(
  options: SharedAuthOptions,
  defaultArgs: string[],
): Promise<{ command: string; args: string[] }> {
  if (options.command && options.args) {
    return { command: options.command, args: options.args };
  }
  const command = options.command ?? (await resolveMakaiBinary(options.resolver));
  return { command, args: options.args ?? defaultArgs };
}

function parseAuthEvent(line: string): MakaiAuthEvent {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    throw new MakaiAuthError(`invalid auth event JSON: ${line}`);
  }
  if (!parsed || typeof parsed !== "object" || !("type" in parsed)) {
    throw new MakaiAuthError(`invalid auth event payload: ${line}`);
  }
  return parsed as MakaiAuthEvent;
}

export async function loginWithMakaiAuth(options: LoginWithMakaiAuthOptions): Promise<void> {
  const provider = options.provider ?? "github-copilot";
  const { command, args } = await resolveCommandAndArgs(options, [
    "auth",
    "login",
    "--provider",
    provider,
    "--json",
  ]);

  const child: ChildProcessWithoutNullStreams = spawn(command, args, {
    cwd: options.cwd,
    env: options.env,
    stdio: "pipe",
  });

  const rl = createInterface({ input: child.stdout });
  let stderr = "";
  let sawSuccess = false;
  let settled = false;

  await new Promise<void>((resolve, reject) => {
    const rejectOnce = (error: Error): void => {
      if (settled) return;
      settled = true;
      rl.close();
      reject(error);
    };
    const resolveOnce = (): void => {
      if (settled) return;
      settled = true;
      rl.close();
      resolve();
    };

    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", (error) => rejectOnce(error));
    child.on("exit", (code, signal) => {
      if (sawSuccess && code === 0) {
        resolveOnce();
        return;
      }
      if (settled) return;
      rejectOnce(
        new MakaiAuthError(
          `auth command exited (code=${code}, signal=${signal})${stderr ? `: ${stderr.trim()}` : ""}`,
        ),
      );
    });

    rl.on("line", (line) => {
      void (async () => {
        const event = parseAuthEvent(line);
        options.onEvent?.(event);

        if (event.type === "prompt") {
          if (!options.onPrompt) {
            throw new MakaiAuthError(`prompt requested but no onPrompt handler provided: ${event.message}`);
          }
          const answer = await options.onPrompt(event);
          child.stdin.write(`${answer ?? ""}\n`);
          return;
        }

        if (event.type === "error") {
          const stderrDetail = stderr.trim();
          const message = stderrDetail.length > 0 ? `${event.message}: ${stderrDetail}` : event.message;
          throw new MakaiAuthError(message, event.code);
        }

        if (event.type === "success") {
          sawSuccess = true;
        }
      })().catch((error: unknown) => {
        child.kill();
        rejectOnce(error instanceof Error ? error : new Error(String(error)));
      });
    });
  });
}

export async function listMakaiAuthProviders(options: ListMakaiAuthProvidersOptions = {}): Promise<AuthProviderInfo[]> {
  const { command, args } = await resolveCommandAndArgs(options, ["auth", "providers", "--json"]);
  const child: ChildProcessWithoutNullStreams = spawn(command, args, {
    cwd: options.cwd,
    env: options.env,
    stdio: "pipe",
  });

  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk: Buffer) => {
    stdout += chunk.toString("utf8");
  });
  child.stderr.on("data", (chunk: Buffer) => {
    stderr += chunk.toString("utf8");
  });

  await new Promise<void>((resolve, reject) => {
    child.on("error", (error) => reject(error));
    child.on("exit", (code, signal) => {
      if (code === 0) resolve();
      else
        reject(
          new MakaiAuthError(
            `auth providers exited (code=${code}, signal=${signal})${stderr ? `: ${stderr.trim()}` : ""}`,
          ),
        );
    });
  });

  const lines = stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  const last = lines.at(-1);
  if (!last) {
    throw new MakaiAuthError("auth providers produced no output");
  }

  const parsed = JSON.parse(last) as { providers?: AuthProviderInfo[] };
  if (!Array.isArray(parsed.providers)) {
    throw new MakaiAuthError("auth providers output missing providers array");
  }
  return parsed.providers;
}
