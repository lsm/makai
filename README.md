# Makai TypeScript SDK

TypeScript SDK for Makai's stdio protocol. The SDK starts or connects to a `makai --stdio` runtime and exposes high-level namespaces for provider completions, streaming, agent runs, auth flows, and model discovery.

## Installation

The current package name is `makai`:

```bash
npm install makai
```

If you are consuming a scoped release, install the scope published by your registry instead, for example:

```bash
npm install @anthropic/makai
```

You also need access to the Makai runtime binary. By default the SDK looks for a local build under `zig-out/bin/makai` or `zig/zig-out/bin/makai`, then falls back to `makai` on `PATH`. See [Configuration](#configuration) for explicit binary resolver options.

## Quick start

Create a client, resolve a model, send one chat message, and print the assistant response.

```ts
import { createMakaiClient } from "makai";

async function main(): Promise<void> {
  const client = await createMakaiClient();

  try {
    const { model } = await client.models.resolve({
      provider_id: "anthropic",
      api: "anthropic-messages",
      model_id: "claude-sonnet-4-5",
    });

    const response = await client.provider.complete({
      model_ref: model.model_ref,
      messages: [{ role: "user", content: "Write a haiku about streams." }],
      options: { max_tokens: 128 },
    });

    const content = response.message.content;
    console.log(typeof content === "string" ? content : JSON.stringify(content, null, 2));
  } finally {
    await client.close();
  }
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
```

## Streaming completions

Use `client.provider.stream(...)` for provider-level streaming. It is the SDK's streaming form of `complete`; each `text_delta` contains newly generated text.

```ts
import { createMakaiClient } from "makai";

async function main(): Promise<void> {
  const client = await createMakaiClient();

  try {
    const { model } = await client.models.resolve({
      provider_id: "anthropic",
      api: "anthropic-messages",
      model_id: "claude-sonnet-4-5",
    });

    for await (const event of client.provider.stream({
      model_ref: model.model_ref,
      messages: [{ role: "user", content: "Explain lock-free queues in one paragraph." }],
      options: { max_tokens: 256 },
    })) {
      switch (event.type) {
        case "message_start":
          console.error(`Streaming ${event.provider_id ?? "provider"}/${event.model_id ?? "model"}`);
          break;
        case "text_delta":
          process.stdout.write(event.delta);
          break;
        case "thinking_delta":
          // Reasoning output is surfaced separately from normal text.
          break;
        case "tool_call":
          console.error(`\nTool call requested: ${event.name}(${event.arguments_json})`);
          break;
        case "message_end":
          process.stdout.write("\n");
          console.error("Stop reason:", event.stop_reason);
          break;
        case "error":
          throw new Error(event.message);
      }
    }
  } finally {
    await client.close();
  }
}

void main();
```

If you are migrating from an API that used `client.complete({ stream: true })`, the equivalent Makai SDK call is `client.provider.stream(request)`; non-streaming calls use `client.provider.complete(request)`.

## Agent loop with tools

Use `client.agent.run(...)` when you want the Makai agent loop to manage provider turns and tool execution lifecycle. Tool definitions are JSON Schema strings. Tool execution is handled by the Makai runtime/tool protocol boundary; the TypeScript SDK sends tool schemas and receives the final assistant response plus streaming lifecycle events when using `agent.stream(...)`.

```ts
import { createMakaiClient, type ToolDefinition } from "makai";

const tools: ToolDefinition[] = [
  {
    name: "get_weather",
    description: "Get the current weather for a city.",
    parameters_schema_json: JSON.stringify({
      type: "object",
      properties: {
        city: { type: "string", description: "City and state or country." },
      },
      required: ["city"],
      additionalProperties: false,
    }),
  },
];

async function main(): Promise<void> {
  const client = await createMakaiClient();

  try {
    const { model } = await client.models.resolve({
      provider_id: "anthropic",
      api: "anthropic-messages",
      model_id: "claude-sonnet-4-5",
    });

    const response = await client.agent.run({
      model_ref: model.model_ref,
      messages: [{ role: "user", content: "Should I bring an umbrella in San Francisco today?" }],
      tools,
      options: { max_tokens: 512, auth_retry_policy: "auto_once" },
    });

    console.log(response.message.content);
  } finally {
    await client.close();
  }
}

void main();
```

For agent streaming, iterate over `client.agent.stream(request)` and handle `agent_start`, `turn_start`, `tool_execution_start`, `tool_execution_end`, provider deltas, and the terminal `agent_end` event.

### Agent model discovery

`client.agent.models` is a separate `MakaiModelsApi` instance that delegates to the same underlying model-discovery API over the shared transport as `client.models`. The two instances produce the same results but are not the same object (`client.agent.models !== client.models`).

```ts
// Both call the same underlying API and return the same results:
const { models } = await client.models.list();
const { models: agentModels } = await client.agent.models.list();
```

Prefer `client.models` when you only need model discovery. Use `client.agent.models` when chaining discovery with an agent call on the same namespace.

## Auth

Use `client.auth.listProviders()` to inspect auth state, and `client.auth.login(providerId, handlers)` to start an interactive login flow. Token material is owned by the runtime and is not exposed by the SDK.

```ts
import { createMakaiClient, type MakaiAuthEvent } from "makai";
import { createInterface } from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";

async function main(): Promise<void> {
  const client = await createMakaiClient();
  const rl = createInterface({ input, output });

  try {
    const providers = await client.auth.listProviders();
    const anthropic = providers.find((provider) => provider.id === "anthropic");

    if (anthropic?.auth_status !== "authenticated") {
      await client.auth.login("anthropic", {
        onEvent(event: MakaiAuthEvent): void {
          if (event.type === "auth_url") {
            console.log(`Open ${event.url}`);
            if (event.instructions) console.log(event.instructions);
          } else if (event.type === "progress") {
            console.log(event.message);
          }
        },
        async onPrompt(prompt): Promise<string> {
          return rl.question(`${prompt.message} `);
        },
      });
    }
  } finally {
    rl.close();
    await client.close();
  }
}

void main();
```

You can also configure automatic one-shot auth retry for `provider` and `agent` calls:

```ts
import { createMakaiClient } from "makai";

async function main(): Promise<void> {
  const client = await createMakaiClient({
    auth: {
      auth_retry_policy: "auto_once",
      handlers: {
        onEvent: (event) => {
          if (event.type === "auth_url") console.log(`Open ${event.url}`);
        },
        onPrompt: async (prompt) => prompt.allow_empty ? "" : process.env.MAKAI_AUTH_CODE ?? "",
      },
    },
  });

  try {
    // Calls that hit auth_required can now trigger one login attempt automatically.
  } finally {
    await client.close();
  }
}

void main();
```

## Models

Models are discovered through `client.models`. Use `model_ref` from the returned descriptor in completion and agent requests. Treat `model_ref` as opaque; do not parse or construct it in application code.

```ts
import { createMakaiClient } from "makai";

async function main(): Promise<void> {
  const client = await createMakaiClient();

  try {
    const { models, fetched_at_ms, cache_max_age_ms } = await client.models.list({
      provider_id: "anthropic",
      include_login_required: true,
    });

    console.log(`Fetched ${models.length} models at ${new Date(fetched_at_ms).toISOString()}`);
    console.log(`Cache max age: ${cache_max_age_ms}ms`);

    for (const model of models) {
      console.log(`${model.display_name}: ${model.model_ref} [${model.auth_status}]`);
    }

    const resolved = await client.models.resolve({
      provider_id: "anthropic",
      api: "anthropic-messages",
      model_id: "claude-sonnet-4-5",
    });

    console.log("Use this model_ref:", resolved.model.model_ref);
  } finally {
    await client.close();
  }
}

void main();
```

## Configuration

`createMakaiClient(...)`, `createMakaiStdioClient(...)`, and `createMakaiAuthClient(...)` accept stdio transport options and binary resolver options.

### Explicit binary path

```ts
import { createMakaiClient } from "makai";

async function main(): Promise<void> {
  const client = await createMakaiClient({
    resolver: {
      binaryPath: "/opt/makai/bin/makai",
    },
  });

  try {
    // Use client.provider, client.agent, client.auth, or client.models here.
  } finally {
    await client.close();
  }
}

void main();
```

You can also set `MAKAI_BINARY_PATH=/opt/makai/bin/makai`.

### Download from URL with checksum

```ts
import { createMakaiClient } from "makai";

async function main(): Promise<void> {
  const client = await createMakaiClient({
    resolver: {
      binaryUrl: "https://example.com/releases/makai-darwin-arm64",
      checksumSha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      cacheDir: "/tmp/makai-bin-cache",
    },
  });

  try {
    // Use client.provider, client.agent, client.auth, or client.models here.
  } finally {
    await client.close();
  }
}

void main();
```

Environment variable equivalents are `MAKAI_BINARY_URL` and `MAKAI_BINARY_SHA256`.

### PATH lookup and local builds

With no resolver options, Makai checks:

1. `./zig-out/bin/makai` (or `makai.exe` on Windows)
2. `./zig/zig-out/bin/makai`
3. `makai` on `PATH`

```ts
import { createMakaiClient } from "makai";

async function main(): Promise<void> {
  const client = await createMakaiClient({
    // Optional transport settings:
    args: ["--stdio"],
    cwd: process.cwd(),
    env: { ...process.env, MAKAI_LOG: "info" },
    handshakeTimeoutMs: 2_000,
    responseTimeoutMs: 30_000,
    frameTimeoutMs: 30_000,
  });

  try {
    // Use client.provider, client.agent, client.auth, or client.models here.
  } finally {
    await client.close();
  }
}

void main();
```

Close clients when done:

```ts
async function closeClient(client: { close(): Promise<void> }): Promise<void> {
  await client.close();
}
```

## Error handling

The SDK exports error classes for common failure surfaces:

- `MakaiStreamError` — provider, stream, transport, abort, or unknown failures while running `provider` or `agent` calls.
- `MakaiAuthRequiredError` — specialized `MakaiStreamError` for `auth_required` failures. It includes `provider_id`.
- `MakaiProtocolError` — models API protocol failures such as `invalid_request`, malformed responses, or request `nack`s.
- `MakaiAuthError` — auth provider listing and login failures. The `kind` can be `provider_error`, `cancelled`, `transport_error`, or `unknown`.

```ts
import {
  MakaiAuthError,
  MakaiAuthRequiredError,
  MakaiProtocolError,
  MakaiStreamError,
  createMakaiClient,
} from "makai";

async function run(): Promise<void> {
  const client = await createMakaiClient();

  try {
    const { model } = await client.models.resolve({
      provider_id: "anthropic",
      api: "anthropic-messages",
      model_id: "claude-sonnet-4-5",
    });

    await client.provider.complete({
      model_ref: model.model_ref,
      messages: [{ role: "user", content: "Hello" }],
    });
  } catch (error: unknown) {
    if (error instanceof MakaiAuthRequiredError) {
      console.error(`Login required for ${error.provider_id}`);
    } else if (error instanceof MakaiStreamError) {
      console.error(`Stream failed (${error.kind}/${error.code ?? "no-code"}): ${error.message}`);
    } else if (error instanceof MakaiProtocolError) {
      console.error(`Protocol failed (${error.code ?? "no-code"}): ${error.message}`);
    } else if (error instanceof MakaiAuthError) {
      console.error(`Auth failed (${error.kind}/${error.code ?? "no-code"}): ${error.message}`);
    } else {
      throw error;
    }
  } finally {
    await client.close();
  }
}

void run();
```

## Zig core library

The Zig core lives under `zig/src/` and is consumed directly as a path dependency (see `build.zig.zon`). Streaming APIs hand out borrowed string slices by design, so memory ownership follows explicit rules: event strings are borrowed from provider buffers, `wait()` returning `null` is the completion signal (not a `done` event), and the final result is taken with `cloneResult()` as a caller-owned deep copy.

Read [`docs/zig-stream-memory-ownership.md`](docs/zig-stream-memory-ownership.md) before writing your first consumer loop or mock provider — it documents the ownership contract for streams, events, and results, and the helper APIs (`cloneResult`, `cloneToolCall`) that make the safe pattern one call.

## TypeScript types

Public types are exported from the package root and generated in `dist/src/index.d.ts` when you run `npm run build:sdk`. Key API types include:

```ts
import type {
  AgentRunRequest,
  AgentRunResponse,
  AgentStreamEvent,
  AuthFlowHandlers,
  AuthStatus,
  BinaryResolverOptions,
  ChatMessage,
  CompletionResponse,
  ContentPart,
  CreateMakaiClientOptions,
  ListModelsRequest,
  ListModelsResponse,
  MakaiAgentApi,
  MakaiAgentModelsApi,
  MakaiAuthApi,
  MakaiClient,
  MakaiModelsApi,
  MakaiProviderApi,
  ModelDescriptor,
  ProviderCompleteRequest,
  ProviderCompleteResponse,
  ProviderStreamEvent,
  RunOptions,
  ToolDefinition,
  UsageSummary,
} from "makai";
```

Most requests share this shape:

```ts
type ChatMessage = {
  role: "system" | "developer" | "user" | "assistant" | "tool";
  content: string | ContentPart[];
  name?: string;
  tool_call_id?: string;
};

type ToolDefinition = {
  name: string;
  description: string;
  parameters_schema_json: string;
};

type RunOptions = {
  temperature?: number;
  max_tokens?: number;
  reasoning_effort?: "off" | "minimal" | "low" | "medium" | "high" | "xhigh";
  auth_retry_policy?: "manual" | "auto_once";
  session_id?: string;
  metadata?: Record<string, string>;
};
```

Core namespaces:

```ts
type MakaiClient = {
  auth: MakaiAuthApi;
  models: MakaiModelsApi;
  agent: MakaiAgentModelsApi; // extends MakaiAgentApi with a `models` convenience alias
  provider: MakaiProviderApi;
  close(): Promise<void>;
};
```
