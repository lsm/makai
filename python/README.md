# Makai Python SDK

Python SDK for Makai's stdio protocol. The SDK starts a `makai --stdio` runtime and exposes high-level namespaces for provider completions, streaming, agent runs, auth flows, and model discovery.

The SDK is async-first (`asyncio`) with a thin blocking wrapper for scripts. It has no third-party runtime dependencies and requires Python 3.11+.

## Installation

The package is not published to PyPI yet. Install it from a checkout of this repository:

```bash
pip install ./python
```

Once it is published, `pip install makai` will do the same.

You also need access to the Makai runtime binary. By default the SDK looks for a local build under `zig-out/bin/makai` or `zig/zig-out/bin/makai`, then falls back to `makai` on `PATH`. See [Configuration](#configuration) for explicit binary resolver options.

## Quick start

Create a client, resolve a model, send one chat message, and print the assistant response.

```python
import asyncio

import makai


async def main() -> None:
    async with makai.connect() as client:
        model = await client.models.resolve(
            provider_id="anthropic",
            api="anthropic-messages",
            model_id="claude-sonnet-4-5",
        )

        response = await client.provider.complete(
            model_ref=model.model_ref,
            messages=[{"role": "user", "content": "Write a haiku about streams."}],
            options=makai.RunOptions(max_tokens=128),
        )

        print(response.text)


asyncio.run(main())
```

`async with makai.connect()` closes the client for you. If you would rather hold the client yourself, `client = await makai.connect()` works too — then you own `await client.close()`.

## Streaming completions

Use `client.provider.stream(...)` for provider-level streaming. It is the SDK's streaming form of `complete`; each `TextDelta` carries newly generated text.

```python
import asyncio
import sys

import makai


async def main() -> None:
    async with makai.connect() as client:
        model = await client.models.resolve(
            provider_id="anthropic",
            api="anthropic-messages",
            model_id="claude-sonnet-4-5",
        )

        async for event in client.provider.stream(
            model_ref=model.model_ref,
            messages=[{"role": "user", "content": "Explain lock-free queues in one paragraph."}],
            options=makai.RunOptions(max_tokens=256),
        ):
            match event:
                case makai.MessageStart():
                    print(f"Streaming {event.provider_id}/{event.model_id}", file=sys.stderr)
                case makai.TextDelta():
                    sys.stdout.write(event.delta)
                case makai.ThinkingDelta():
                    pass  # Reasoning output is surfaced separately from normal text.
                case makai.ToolCall():
                    print(f"\nTool call: {event.name}({event.arguments_json})", file=sys.stderr)
                case makai.MessageEnd():
                    print(f"\nStop reason: {event.stop_reason}", file=sys.stderr)
                case makai.StreamError():
                    raise RuntimeError(event.message)


asyncio.run(main())
```

Every event also has a `type` string (`"text_delta"`, `"message_end"`, ...) if you prefer `if event.type == ...` over `isinstance` / `match`.

A stream ends after exactly one terminal event: `MessageEnd` or `StreamError`. Cancelling the task sends an `abort_request` for the stream before the iterator unwinds.

If you `break` out of the loop, close the generator so the abort is sent promptly rather than at garbage-collection time:

```python
from contextlib import aclosing

async with aclosing(client.provider.stream(model_ref=..., messages=[...])) as stream:
    async for event in stream:
        if isinstance(event, makai.TextDelta) and "stop" in event.delta:
            break
```

Running a stream to completion needs no such ceremony.

## Agent loop with tools

Use `client.agent.run(...)` when you want the Makai agent loop to manage provider turns and tool execution. Tool schemas are JSON Schema **strings**. Supply an `execute` callback and the SDK runs the tool **in your process** when the runtime asks for it, replying with a correlated `tool_result`.

```python
import asyncio
import json
from typing import Any

import makai


def get_weather(args: dict[str, Any], context: makai.ToolContext) -> str:
    return f"It is 17C and raining in {args['city']}."


tools = [
    makai.ToolDefinition(
        name="get_weather",
        description="Get the current weather for a city.",
        parameters_schema_json=json.dumps(
            {
                "type": "object",
                "properties": {"city": {"type": "string", "description": "City and state or country."}},
                "required": ["city"],
                "additionalProperties": False,
            }
        ),
        execute=get_weather,
    )
]


async def main() -> None:
    async with makai.connect() as client:
        model = await client.models.resolve(
            provider_id="anthropic",
            api="anthropic-messages",
            model_id="claude-sonnet-4-5",
        )

        response = await client.agent.run(
            model_ref=model.model_ref,
            messages=[{"role": "user", "content": "Should I bring an umbrella in San Francisco today?"}],
            tools=tools,
            options=makai.RunOptions(max_tokens=512, auth_retry_policy="auto_once"),
        )

        print(response.text)


asyncio.run(main())
```

`execute` may be a plain function or a coroutine function. A tool that raises is reported back to the loop as an error result rather than failing the run. A tool the model calls but that has no `execute` is answered "not executable by this client".

For agent streaming, iterate `client.agent.stream(request)` and handle `AgentStart`, `TurnStart`, `ToolExecutionStart`, `ToolExecutionEnd`, provider deltas, and the terminal `AgentEnd`. `AgentEnd.usage` is the aggregate summed across the run's provider turns.

### Agent model discovery

`client.agent.models` is a separate `ModelsApi` instance that delegates to the same underlying model-discovery API over the shared transport as `client.models`. The two produce the same results but are not the same object.

```python
models = (await client.models.list()).models
agent_models = (await client.agent.models.list()).models
```

Prefer `client.models` when you only need discovery. Use `client.agent.models` when chaining discovery with an agent call on the same namespace.

## Auth

Use `client.auth.list_providers()` to inspect auth state, and `client.auth.login(provider_id, handlers)` to start an interactive login. Token material is owned by the runtime and is never returned by the SDK.

```python
import asyncio

import makai


async def main() -> None:
    async with makai.connect() as client:
        providers = await client.auth.list_providers()
        anthropic = next((p for p in providers if p.id == "anthropic"), None)

        if anthropic is not None and anthropic.auth_status != "authenticated":
            def on_event(event: makai.AuthEvent) -> None:
                if isinstance(event, makai.AuthUrlEvent):
                    print(f"Open {event.url}")
                    if event.instructions:
                        print(event.instructions)
                elif isinstance(event, makai.AuthProgressEvent):
                    print(event.message)

            def on_prompt(prompt: makai.AuthPromptEvent) -> str:
                return input(f"{prompt.message} ")

            await client.auth.login(
                "anthropic",
                makai.AuthFlowHandlers(on_event=on_event, on_prompt=on_prompt),
            )


asyncio.run(main())
```

Both handlers may be coroutine functions. A `prompt` event with no `on_prompt` handler cancels the flow instead of hanging, and `login` then raises `MakaiAuthError(kind="cancelled")`.

You can also configure automatic one-shot auth retry for `provider` and `agent` calls:

```python
client = await makai.connect(
    auth=makai.AuthOptions(
        auth_retry_policy="auto_once",
        handlers=makai.AuthFlowHandlers(on_event=lambda event: None),
    )
)
# Calls that hit auth_required can now trigger one login attempt automatically.
```

## Models

Models are discovered through `client.models`. Use `model_ref` from the returned descriptor in completion and agent requests. **Treat `model_ref` as opaque**: do not parse or construct it in application code.

```python
import asyncio
import datetime

import makai


async def main() -> None:
    async with makai.connect() as client:
        result = await client.models.list(provider_id="anthropic", include_login_required=True)

        fetched = datetime.datetime.fromtimestamp(result.fetched_at_ms / 1000, datetime.UTC)
        print(f"Fetched {len(result.models)} models at {fetched.isoformat()}")
        print(f"Cache max age: {result.cache_max_age_ms}ms")

        for model in result.models:
            print(f"{model.display_name}: {model.model_ref} [{model.auth_status}]")

        resolved = await client.models.resolve(
            provider_id="anthropic",
            api="anthropic-messages",
            model_id="claude-sonnet-4-5",
        )
        print("Use this model_ref:", resolved.model_ref)


asyncio.run(main())
```

`resolve` returns the `ModelDescriptor` directly (the TypeScript SDK's `{model}` wrapper carries nothing extra in Python). It raises `MakaiProtocolError("model not found", "invalid_request")` when nothing matches, and rejects a response with more than one match.

## Blocking wrapper

For scripts and REPLs, `makai.connect_sync()` runs the async client on a private event loop in a background thread. Do not call it from inside a running event loop.

```python
import makai

with makai.connect_sync() as client:
    model = client.models.resolve(provider_id="anthropic", model_id="claude-sonnet-4-5")
    for event in client.provider.stream(
        model_ref=model.model_ref,
        messages=[{"role": "user", "content": "hello"}],
    ):
        if isinstance(event, makai.TextDelta):
            print(event.delta, end="")
```

## Sessions are not resumable

`RunOptions.session_id` is a **correlation key**, not a resume handle (spec §13.1). It lets you line SDK calls up with runtime logs; it does not let you continue a previous run. On interruption, resend the full context. Under `auth_retry_policy="auto_once"` the SDK regenerates the id for the retried attempt, so it is not stable across a retry.

## Configuration

`makai.connect(...)` and `makai.connect_sync(...)` accept transport options and binary resolver options.

### Explicit binary path

```python
client = await makai.connect(
    resolver=makai.BinaryResolverOptions(binary_path="/opt/makai/bin/makai")
)
```

You can also set `MAKAI_BINARY_PATH=/opt/makai/bin/makai`, which takes precedence over `binary_path`.

### Download from URL with checksum

```python
client = await makai.connect(
    resolver=makai.BinaryResolverOptions(
        binary_url="https://example.com/releases/makai-darwin-arm64",
        checksum_sha256="0123456789abcdef" * 4,
        cache_dir="/tmp/makai-bin-cache",
    )
)
```

The checksum is mandatory and re-verified against the cache on every resolve. Environment variable equivalents are `MAKAI_BINARY_URL` and `MAKAI_BINARY_SHA256`.

### Resolution order

1. `resolver.binary_path`, or `MAKAI_BINARY_PATH` (the environment wins)
2. `resolver.binary_url` / `MAKAI_BINARY_URL`, which requires a SHA-256 checksum
3. `./zig-out/bin/makai`
4. `./zig/zig-out/bin/makai`
5. `makai` on `PATH`

The TypeScript SDK has one extra step between 2 and 3: an optional `@makai/cli-<platform>-<arch>` npm package. That step is **deliberately omitted** here — npm installs those automatically through optional dependencies, Python's equivalent would be platform-specific wheels, and none are published for makai. Set `MAKAI_BINARY_PATH` when you need to pin a specific binary.

### Transport options

```python
client = await makai.connect(
    args=["--stdio"],
    cwd=".",
    env={**os.environ, "MAKAI_LOG": "info"},
    handshake_timeout=5.0,   # seconds to wait for the `ready` frame
    response_timeout=30.0,   # seconds per provider/agent frame
    frame_timeout=30.0,      # seconds per auth frame
)
```

All timeouts are in **seconds** (floats), following `asyncio` convention, where the TypeScript SDK uses milliseconds.

Closing a client terminates the child process: stdin is closed, then `terminate()`, then `kill()`. Requests in flight fail with a typed transport error rather than hanging.

## Error handling

| Exception | Raised by | Key fields |
| --- | --- | --- |
| `MakaiError` | base class for everything below | `message`, `code` |
| `MakaiStreamError` | `provider` and `agent` calls | `kind`, `code`, `provider_id`, `diagnostics` |
| `MakaiAuthRequiredError` | `provider`/`agent` when a login is needed | `provider_id`, `code == "auth_required"` |
| `MakaiProtocolError` | `models` calls | `code` (`invalid_request`, `malformed_response`, ...) |
| `MakaiAuthError` | `auth` calls | `kind` (`provider_error`, `cancelled`, `transport_error`, `unknown`), `code` |

`MakaiStreamError.kind` is one of `provider_error`, `transport_error`, `aborted`, `unknown`. Timeouts carry a `diagnostics` mapping with the stream/session/message ids and remediation suggestions.

```python
import makai

try:
    response = await client.provider.complete(model_ref=model_ref, messages=messages)
except makai.MakaiAuthRequiredError as error:
    print(f"Login required for {error.provider_id}")
except makai.MakaiStreamError as error:
    print(f"Stream failed ({error.kind}/{error.code}): {error}")
except makai.MakaiProtocolError as error:
    print(f"Protocol failed ({error.code}): {error}")
except makai.MakaiAuthError as error:
    print(f"Auth failed ({error.kind}/{error.code}): {error}")
```

`MakaiAuthRequiredError` subclasses `MakaiStreamError`, so order your `except` clauses from most to least specific.

## Types

The package ships a `py.typed` marker and passes `mypy --strict`. Request shapes are `TypedDict`s so plain dictionaries work; responses and stream events are frozen dataclasses.

```python
from makai import (
    AgentEnd, AgentStart, AgentStreamEvent, AssistantMessage, AuthEvent,
    AuthFlowHandlers, ChatMessage, CompletionResponse, ContentPart,
    ListModelsResponse, MessageEnd, MessageStart, ModelDescriptor,
    ProviderAuthInfo, ProviderStreamEvent, RunOptions, StreamError, TextDelta,
    ThinkingDelta, ToolCall, ToolContext, ToolDefinition, ToolExecutionEnd,
    ToolExecutionStart, TurnEnd, TurnStart, Usage,
)
```

```python
class ChatMessage(TypedDict):
    role: Literal["system", "developer", "user", "assistant", "tool"]
    content: str | list[ContentPart]
    name: NotRequired[str]
    tool_call_id: NotRequired[str]


@dataclass(frozen=True)
class ToolDefinition:
    name: str
    description: str
    parameters_schema_json: str
    execute: ToolExecutor | None = None


@dataclass(frozen=True)
class RunOptions:
    temperature: float | None = None
    max_tokens: int | None = None
    reasoning_effort: Literal["off", "minimal", "low", "medium", "high", "xhigh"] | None = None
    auth_retry_policy: Literal["manual", "auto_once"] | None = None
    session_id: str | None = None          # correlation key only, NOT a resume handle
    metadata: Mapping[str, str] | None = None
```

## Development

```bash
cd python
pip install -e ".[dev]"

pytest                    # fake-server suite; no binary or credentials needed
mypy                      # strict type checking over src/ and tests/

zig build install --prefix /tmp/makai-py      # from the repo root
MAKAI_BINARY_PATH=/tmp/makai-py/bin/makai pytest   # adds the real-binary suite
```

Tests in `tests/test_real_binary.py` skip when `MAKAI_BINARY_PATH` is unset, so a green `pytest` without it means zero real-runtime coverage. Set it explicitly when you mean to exercise the real host.

Everything else runs against `tests/fixtures/fake_server.py`, a configurable protocol host in the spirit of `typescript/test/fixtures/*.js`.
