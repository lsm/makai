import { ulid } from "ulid";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { promises as fs } from "node:fs";
import path from "node:path";
import {
  createMakaiClient,
  type CreateMakaiClientOptions,
  type MakaiAuthEvent,
  type ProviderAuthInfo,
  type ProviderStreamEvent,
} from "../src";

type DemoOAuthProvider = {
  id: string;
  name: string;
};

type ChatProviderId = "test-fixture" | "github-copilot" | "anthropic";

type ChatProviderConfig = {
  id: ChatProviderId;
  name: string;
  models: string[];
};

type AuthSessionStatus = "running" | "waiting_for_input" | "success" | "error";

type AuthSession = {
  id: string;
  provider: string;
  status: AuthSessionStatus;
  events: MakaiAuthEvent[];
  pendingPrompt?: Extract<MakaiAuthEvent, { type: "prompt" }>;
  error?: string;
  resolvePrompt?: (value: string) => void;
  rejectPrompt?: (error: Error) => void;
  createdAt: number;
  updatedAt: number;
};

type DemoServerOptions = {
  host?: string;
  port?: number;
  homeDir?: string;
  binaryPath?: string;
  command?: string;
  args?: string[];
  env?: NodeJS.ProcessEnv;
};

type RunningDemoServer = {
  server: Server;
  url: string;
  close: () => Promise<void>;
};

const PUBLIC_DIR = path.resolve(process.cwd(), "typescript/demo/public");
const SESSION_TTL_MS = 30 * 60 * 1000;

const CHAT_PROVIDERS: ChatProviderConfig[] = [
  {
    id: "test-fixture",
    name: "Test Fixture",
    models: ["fixture-echo-v1"],
  },
  {
    id: "github-copilot",
    name: "GitHub Copilot",
    models: ["gpt-4.1", "gpt-5", "claude-sonnet-4.5", "gemini-2.5-pro"],
  },
  {
    id: "anthropic",
    name: "Anthropic",
    models: ["claude-haiku-4-5", "claude-sonnet-4-5", "claude-opus-4-5"],
  },
];

const FALLBACK_AUTH_PROVIDERS: DemoOAuthProvider[] = [
  { id: "test-fixture", name: "Test Fixture (CI)" },
  { id: "github-copilot", name: "GitHub Copilot" },
  { id: "anthropic", name: "Anthropic" },
];


function json(res: ServerResponse, status: number, payload: unknown): void {
  const body = JSON.stringify(payload);
  res.statusCode = status;
  res.setHeader("content-type", "application/json; charset=utf-8");
  res.end(body);
}

async function readJsonBody(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  if (chunks.length === 0) return {};
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (raw.length === 0) return {};
  return JSON.parse(raw);
}

function modelRefFor(providerId: string, model: string): string {
  switch (providerId) {
    case "github-copilot":
      return `${providerId}/openai-completions@${encodeURIComponent(model)}`;
    case "anthropic":
      return `${providerId}/anthropic-messages@${encodeURIComponent(model)}`;
    default:
      return `${providerId}/test-fixture@${encodeURIComponent(model)}`;
  }
}

function appendProviderStreamText(reply: string, event: ProviderStreamEvent): string {
  if (event.type !== "text_delta") return reply;
  return reply + event.delta;
}

function contentTypeForFile(filePath: string): string {
  if (filePath.endsWith(".html")) return "text/html; charset=utf-8";
  if (filePath.endsWith(".js")) return "text/javascript; charset=utf-8";
  if (filePath.endsWith(".css")) return "text/css; charset=utf-8";
  return "application/octet-stream";
}

function cleanupSessions(sessions: Map<string, AuthSession>): void {
  const now = Date.now();
  for (const [id, session] of sessions.entries()) {
    if (now - session.updatedAt > SESSION_TTL_MS) {
      session.rejectPrompt?.(new Error("auth session expired"));
      sessions.delete(id);
    }
  }
}

export function createDemoServer(options: DemoServerOptions = {}): Server {
  const authSessions = new Map<string, AuthSession>();
  const homeDir = options.homeDir ?? process.env.HOME ?? "";
  const binaryPath = options.binaryPath ?? process.env.MAKAI_BINARY_PATH;

  function clientOptions(extra?: Partial<CreateMakaiClientOptions>): CreateMakaiClientOptions {
    const env: NodeJS.ProcessEnv = { ...process.env, ...(options.env ?? {}), ...(homeDir ? { HOME: homeDir } : {}) };
    return {
      ...(options.command ? { command: options.command, args: options.args, env } : binaryPath ? { resolver: { binaryPath }, env } : { env }),
      ...extra,
    };
  }

  async function resolveOAuthProviders(): Promise<ProviderAuthInfo[]> {
    let client: Awaited<ReturnType<typeof createMakaiClient>> | undefined;
    try {
      client = await createMakaiClient(clientOptions());
      return await client.auth.listProviders();
    } catch {
      return FALLBACK_AUTH_PROVIDERS.map((provider) => ({
        ...provider,
        auth_status: "unknown" as const,
      }));
    } finally {
      if (client) {
        await client.close().catch(() => undefined);
      }
    }
  }

  async function handleApi(req: IncomingMessage, res: ServerResponse, pathname: string): Promise<boolean> {
    cleanupSessions(authSessions);

    if (req.method === "GET" && pathname === "/api/meta") {
      const authProviders = await resolveOAuthProviders();
      const authStatusByProvider = new Map(authProviders.map((provider) => [provider.id, provider.auth_status]));
      const oauthProviders = authProviders.map((provider) => ({ id: provider.id, name: provider.name }));
      const chatProviders = CHAT_PROVIDERS.map((provider) => ({
        ...provider,
        authenticated: authStatusByProvider.get(provider.id) === "authenticated",
      }));
      json(res, 200, { oauthProviders, chatProviders });
      return true;
    }

    if (req.method === "POST" && pathname === "/api/auth/sessions") {
      const body = (await readJsonBody(req)) as { provider?: string };
      if (!body?.provider || typeof body.provider !== "string") {
        json(res, 400, { error: "provider is required" });
        return true;
      }

      const session: AuthSession = {
        id: ulid(),
        provider: body.provider,
        status: "running",
        events: [],
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      authSessions.set(session.id, session);

      const provider = body.provider;
      void (async () => {
        let client: Awaited<ReturnType<typeof createMakaiClient>> | undefined;
        try {
          client = await createMakaiClient(clientOptions());
          await client.auth.login(provider, {
            onEvent: (event) => {
              session.events.push(event);
              session.updatedAt = Date.now();
              if (event.type === "error") {
                session.status = "error";
                session.error = event.message;
              } else if (event.type === "success") {
                session.status = "success";
              }
            },
            onPrompt: async (prompt) => {
              session.pendingPrompt = prompt;
              session.status = "waiting_for_input";
              session.updatedAt = Date.now();
              return await new Promise<string>((resolve, reject) => {
                session.resolvePrompt = resolve;
                session.rejectPrompt = reject;
              });
            },
          });
          session.pendingPrompt = undefined;
          session.resolvePrompt = undefined;
          session.rejectPrompt = undefined;
          session.status = "success";
          session.updatedAt = Date.now();
        } catch (error: unknown) {
          session.pendingPrompt = undefined;
          session.resolvePrompt = undefined;
          session.rejectPrompt = undefined;
          session.status = "error";
          session.error = error instanceof Error ? error.message : String(error);
          session.updatedAt = Date.now();
        } finally {
          if (client) {
            await client.close().catch(() => undefined);
          }
        }
      })();

      json(res, 200, { sessionId: session.id });
      return true;
    }

    const authSessionMatch = pathname.match(/^\/api\/auth\/sessions\/([^/]+)$/);
    if (authSessionMatch && req.method === "GET") {
      const session = authSessions.get(authSessionMatch[1]);
      if (!session) {
        json(res, 404, { error: "session not found" });
        return true;
      }
      json(res, 200, {
        id: session.id,
        provider: session.provider,
        status: session.status,
        pendingPrompt: session.pendingPrompt,
        events: session.events,
        error: session.error,
      });
      return true;
    }

    const authRespondMatch = pathname.match(/^\/api\/auth\/sessions\/([^/]+)\/respond$/);
    if (authRespondMatch && req.method === "POST") {
      const session = authSessions.get(authRespondMatch[1]);
      if (!session) {
        json(res, 404, { error: "session not found" });
        return true;
      }
      if (!session.resolvePrompt) {
        json(res, 409, { error: "session is not waiting for input" });
        return true;
      }
      const body = (await readJsonBody(req)) as { answer?: string };
      if (typeof body?.answer !== "string") {
        json(res, 400, { error: "answer is required" });
        return true;
      }

      const resolvePrompt = session.resolvePrompt;
      session.resolvePrompt = undefined;
      session.rejectPrompt = undefined;
      session.pendingPrompt = undefined;
      session.status = "running";
      session.updatedAt = Date.now();
      resolvePrompt(body.answer);
      json(res, 200, { ok: true });
      return true;
    }

    if (req.method === "POST" && pathname === "/api/chat") {
      const body = (await readJsonBody(req)) as { provider?: string; model?: string; message?: string };
      if (typeof body?.provider !== "string" || typeof body.model !== "string" || typeof body.message !== "string") {
        json(res, 400, { error: "provider, model, and message are required" });
        return true;
      }
      const providerId = body.provider;
      const model = body.model;
      const message = body.message;
      if (!CHAT_PROVIDERS.some((provider) => provider.id === providerId && provider.models.includes(model))) {
        json(res, 400, { error: "unsupported provider/model combination" });
        return true;
      }

      let client: Awaited<ReturnType<typeof createMakaiClient>> | undefined;
      try {
        client = await createMakaiClient(clientOptions());
        let reply = "";
        for await (const event of client.provider.stream({
          model_ref: modelRefFor(providerId, model),
          messages: [{ role: "user", content: message }],
          options: { max_tokens: 1024, auth_retry_policy: "manual" },
        })) {
          if (event.type === "error") {
            throw new Error(event.message);
          }
          reply = appendProviderStreamText(reply, event);
        }

        json(res, 200, { reply, provider: providerId, model });
      } catch (error: unknown) {
        json(res, 500, {
          error: error instanceof Error ? error.message : String(error),
        });
      } finally {
        if (client) {
          await client.close().catch(() => undefined);
        }
      }
      return true;
    }

    return false;
  }

  const server = createServer(async (req, res) => {
    try {
      const method = req.method ?? "GET";
      const url = new URL(req.url ?? "/", "http://localhost");
      const pathname = url.pathname;

      if (pathname.startsWith("/api/")) {
        const handled = await handleApi(req, res, pathname);
        if (!handled) json(res, 404, { error: "not found" });
        return;
      }

      if (method !== "GET") {
        res.statusCode = 405;
        res.end("method not allowed");
        return;
      }

      const requested = pathname === "/" ? "index.html" : pathname.slice(1);
      const filePath = path.resolve(PUBLIC_DIR, requested);
      if (!filePath.startsWith(PUBLIC_DIR)) {
        res.statusCode = 403;
        res.end("forbidden");
        return;
      }
      const payload = await fs.readFile(filePath);
      res.statusCode = 200;
      res.setHeader("content-type", contentTypeForFile(filePath));
      res.end(payload);
    } catch (error: unknown) {
      json(res, 500, { error: error instanceof Error ? error.message : String(error) });
    }
  });

  server.on("close", () => {
    for (const session of authSessions.values()) {
      session.rejectPrompt?.(new Error("server stopped"));
    }
    authSessions.clear();
  });

  return server;
}

export async function startDemoServer(options: DemoServerOptions = {}): Promise<RunningDemoServer> {
  const host = options.host ?? "127.0.0.1";
  const port = options.port ?? 8787;
  const server = createDemoServer(options);

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, host, () => resolve());
  });

  const address = server.address();
  if (!address || typeof address === "string") {
    throw new Error("failed to resolve server address");
  }
  const url = `http://${host}:${address.port}`;

  return {
    server,
    url,
    close: () =>
      new Promise<void>((resolve, reject) => {
        server.close((error) => {
          if (error) reject(error);
          else resolve();
        });
      }),
  };
}

if (require.main === module) {
  startDemoServer({
    host: process.env.DEMO_HOST ?? "127.0.0.1",
    port: Number(process.env.DEMO_PORT ?? "8787"),
    homeDir: process.env.HOME,
    binaryPath: process.env.MAKAI_BINARY_PATH,
  })
    .then(({ url }) => {
      process.stdout.write(`Makai TS SDK demo running at ${url}\n`);
    })
    .catch((error: unknown) => {
      process.stderr.write(
        `Failed to start demo server: ${error instanceof Error ? error.message : String(error)}\n`,
      );
      process.exit(1);
    });
}
