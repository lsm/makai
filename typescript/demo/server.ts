import { randomUUID } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { promises as fs } from "node:fs";
import path from "node:path";
import { listMakaiAuthProviders, loginWithMakaiAuth, type LoginWithMakaiAuthOptions, type MakaiAuthEvent } from "../src";

type AuthProviderInfo = {
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
};

type RunningDemoServer = {
  server: Server;
  url: string;
  close: () => Promise<void>;
};

const PUBLIC_DIR = path.resolve(process.cwd(), "typescript/demo/public");
const AUTH_FILE_RELATIVE = path.join(".makai", "auth.json");
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

const FALLBACK_AUTH_PROVIDERS: AuthProviderInfo[] = [
  { id: "test-fixture", name: "Test Fixture (CI)" },
  { id: "github-copilot", name: "GitHub Copilot" },
  { id: "anthropic", name: "Anthropic" },
];

type StoredProviderAuth = {
  api_key?: string;
  refresh?: string;
  access?: string;
  expires?: number;
  provider_data?: string;
};

type StoredAuthFile = Record<string, StoredProviderAuth>;

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

async function readAuthFile(homeDir: string): Promise<StoredAuthFile> {
  const authPath = path.join(homeDir, AUTH_FILE_RELATIVE);
  try {
    const raw = await fs.readFile(authPath, "utf8");
    return JSON.parse(raw) as StoredAuthFile;
  } catch {
    return {};
  }
}

function extractCopilotBaseUrl(token: string): string {
  const prefix = "proxy-ep=";
  const index = token.indexOf(prefix);
  if (index < 0) {
    return "https://api.individual.githubcopilot.com";
  }
  const start = index + prefix.length;
  const end = token.indexOf(";", start);
  const proxyHost = end >= 0 ? token.slice(start, end) : token.slice(start);
  if (proxyHost.startsWith("proxy.")) {
    return `https://api.${proxyHost.slice("proxy.".length)}`;
  }
  return `https://${proxyHost}`;
}

function extractMessageFromOpenAICompletion(payload: unknown): string {
  if (!payload || typeof payload !== "object") return "";
  const choices = (payload as { choices?: unknown }).choices;
  if (!Array.isArray(choices) || choices.length === 0) return "";
  const first = choices[0] as { message?: { content?: unknown } };
  const content = first?.message?.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => (part && typeof part === "object" && "text" in part ? String((part as { text: unknown }).text) : ""))
      .join("");
  }
  return "";
}

function extractMessageFromAnthropic(payload: unknown): string {
  if (!payload || typeof payload !== "object") return "";
  const content = (payload as { content?: unknown }).content;
  if (!Array.isArray(content)) return "";
  return content
    .map((block) => {
      if (!block || typeof block !== "object") return "";
      if ((block as { type?: unknown }).type === "text") {
        return String((block as { text?: unknown }).text ?? "");
      }
      return "";
    })
    .filter((text) => text.length > 0)
    .join("\n");
}

async function chatWithTestFixture(model: string, message: string): Promise<string> {
  return `[${model}] ${message.split("").reverse().join("")}`;
}

async function chatWithGitHubCopilot(auth: StoredProviderAuth, model: string, message: string): Promise<string> {
  const token = auth.access ?? auth.api_key;
  if (!token) {
    throw new Error("missing github-copilot token");
  }

  const response = await fetch(`${extractCopilotBaseUrl(token)}/chat/completions`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      accept: "application/json",
      "user-agent": "GitHubCopilotChat/0.35.0",
      "editor-version": "vscode/1.107.0",
      "editor-plugin-version": "copilot-chat/0.35.0",
      "copilot-integration-id": "vscode-chat",
      "x-initiator": "user",
      "openai-intent": "conversation-edits",
    },
    body: JSON.stringify({
      model,
      stream: false,
      messages: [{ role: "user", content: message }],
    }),
  });

  if (!response.ok) {
    const err = await response.text();
    throw new Error(`copilot chat failed (${response.status}): ${err.slice(0, 240)}`);
  }

  const payload = (await response.json()) as unknown;
  const text = extractMessageFromOpenAICompletion(payload);
  if (!text) {
    throw new Error("copilot response did not include message content");
  }
  return text;
}

async function chatWithAnthropic(auth: StoredProviderAuth, model: string, message: string): Promise<string> {
  const token = auth.access ?? auth.api_key;
  if (!token) {
    throw new Error("missing anthropic token");
  }

  const headers: Record<string, string> = {
    "content-type": "application/json",
    "anthropic-version": "2023-06-01",
  };
  if (auth.api_key) {
    headers["x-api-key"] = auth.api_key;
    headers["anthropic-beta"] = "fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14";
  } else {
    headers.authorization = `Bearer ${token}`;
    headers["anthropic-beta"] =
      "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14";
    headers["anthropic-dangerous-direct-browser-access"] = "true";
    headers["user-agent"] = "claude-cli/2.1.2 (external, cli)";
    headers["x-app"] = "cli";
  }

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers,
    body: JSON.stringify({
      model,
      max_tokens: 1024,
      messages: [{ role: "user", content: message }],
    }),
  });

  if (!response.ok) {
    const err = await response.text();
    throw new Error(`anthropic chat failed (${response.status}): ${err.slice(0, 240)}`);
  }

  const payload = (await response.json()) as unknown;
  const text = extractMessageFromAnthropic(payload);
  if (!text) {
    throw new Error("anthropic response did not include text content");
  }
  return text;
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

  async function resolveOAuthProviders(): Promise<AuthProviderInfo[]> {
    const authOptions: LoginWithMakaiAuthOptions = binaryPath ? { resolver: { binaryPath } } : {};
    try {
      return await listMakaiAuthProviders(authOptions);
    } catch {
      return FALLBACK_AUTH_PROVIDERS;
    }
  }

  async function handleApi(req: IncomingMessage, res: ServerResponse, pathname: string): Promise<boolean> {
    cleanupSessions(authSessions);

    if (req.method === "GET" && pathname === "/api/meta") {
      const [oauthProviders, authMap] = await Promise.all([resolveOAuthProviders(), readAuthFile(homeDir)]);
      const chatProviders = CHAT_PROVIDERS.map((provider) => ({
        ...provider,
        authenticated: Boolean(authMap[provider.id]?.access || authMap[provider.id]?.api_key),
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
        id: randomUUID(),
        provider: body.provider,
        status: "running",
        events: [],
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      authSessions.set(session.id, session);

      const loginOptions: LoginWithMakaiAuthOptions = {
        provider: body.provider,
        env: homeDir ? { ...process.env, HOME: homeDir } : process.env,
        resolver: binaryPath ? { binaryPath } : undefined,
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
      };

      void loginWithMakaiAuth(loginOptions)
        .then(() => {
          session.pendingPrompt = undefined;
          session.resolvePrompt = undefined;
          session.rejectPrompt = undefined;
          session.status = "success";
          session.updatedAt = Date.now();
        })
        .catch((error: unknown) => {
          session.pendingPrompt = undefined;
          session.resolvePrompt = undefined;
          session.rejectPrompt = undefined;
          session.status = "error";
          session.error = error instanceof Error ? error.message : String(error);
          session.updatedAt = Date.now();
        });

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

      try {
        let reply: string;
        if (providerId === "test-fixture") {
          reply = await chatWithTestFixture(model, message);
        } else {
          const authMap = await readAuthFile(homeDir);
          const providerAuth = authMap[providerId];
          if (!providerAuth) {
            json(res, 400, { error: `${providerId} is not authenticated` });
            return true;
          }
          if (providerId === "github-copilot") {
            reply = await chatWithGitHubCopilot(providerAuth, model, message);
          } else {
            reply = await chatWithAnthropic(providerAuth, model, message);
          }
        }

        json(res, 200, { reply, provider: providerId, model });
      } catch (error: unknown) {
        json(res, 500, {
          error: error instanceof Error ? error.message : String(error),
        });
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
