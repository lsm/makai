# Makai Rust SDK

Rust SDK for Makai's stdio protocol. The SDK starts a `makai --stdio` runtime and exposes high-level namespaces for provider completions, streaming, agent runs with client-side tools, auth flows, and model discovery.

It mirrors the [TypeScript SDK](../typescript/README.md): same protocol, same namespaces, same error taxonomy.

## Installation

The crate lives in this repository at `rust/`. Until it is published, depend on it by path or by git:

```toml
[dependencies]
makai = { git = "https://github.com/lsm/makai", package = "makai" }
tokio = { version = "1", features = ["rt-multi-thread", "macros"] }
futures = "0.3"
```

You also need the Makai runtime binary. By default the SDK looks for a local build under `zig-out/bin/makai` or `zig/zig-out/bin/makai`, then falls back to `makai` on `PATH`. See [Configuration](#configuration) for explicit options.

```bash
zig build install --prefix /tmp/makai
export MAKAI_BINARY_PATH=/tmp/makai/bin/makai
```

## Quick start

Create a client, resolve a model, send one message, print the reply.

```rust
use makai::{Client, ExecutionRequest};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let client = Client::connect().await?;

    let model = client
        .models()
        .resolve("anthropic", Some("anthropic-messages"), "claude-sonnet-4-5")
        .await?;

    let response = client
        .provider()
        .complete(
            ExecutionRequest::prompt(&model.model_ref, "Write a haiku about streams.")
                .with_max_tokens(128),
        )
        .await?;

    println!("{}", response.text());

    client.close().await;
    Ok(())
}
```

## Streaming completions

`provider().stream(...)` is the streaming form of `complete`. Each `TextDelta` carries newly generated text; deltas concatenate.

```rust
use futures::StreamExt;
use makai::{Client, ExecutionRequest, ProviderEvent};

# async fn run(client: &makai::Client, model_ref: &str) -> makai::Result<()> {
let mut events = Box::pin(
    client
        .provider()
        .stream(ExecutionRequest::prompt(model_ref, "Explain lock-free queues.")),
);

while let Some(event) = events.next().await {
    match event? {
        ProviderEvent::TextDelta { delta } => print!("{delta}"),
        ProviderEvent::ToolCall { name, arguments_json, .. } => {
            eprintln!("tool call: {name}({arguments_json})");
        }
        ProviderEvent::MessageEnd { stop_reason, .. } => {
            eprintln!("stop reason: {stop_reason:?}");
        }
        _ => {}
    }
}
# Ok(())
# }
```

Exactly one terminal event ends the stream — `MessageEnd` or `Error`. Failures that never reach the event plane (a rejected request, a dead runtime, a timeout) arrive as an `Err` item.

**Cancellation.** Dropping the stream cancels the work: the SDK sends `abort_request` for a provider stream and `agent_stop` for an agent run, so the runtime stops rather than finishing into a queue nobody is reading. Dropping the whole `Client` terminates and reaps the child process.

## Agent loop with tools

`agent().run(...)` and `agent().stream(...)` drive the Makai agent loop. Tool schemas are JSON Schema documents in a string; tools with a handler **execute in your process** — the runtime publishes `tool_execute` and waits for the correlated `tool_result`.

```rust
use makai::{Client, ExecutionRequest, Tool};
use serde::Deserialize;

#[derive(Deserialize)]
struct WeatherArgs {
    city: String,
}

# async fn run(client: &makai::Client, model_ref: &str) -> makai::Result<()> {
let weather = Tool::new(
    "get_weather",
    "Get the current weather for a city.",
    r#"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#,
)
.on_call(|invocation| async move {
    let args: WeatherArgs = invocation.args().map_err(|err| err.to_string())?;
    Ok(format!("It is 18C and raining in {}.", args.city))
});

let response = client
    .agent()
    .run(
        ExecutionRequest::prompt(model_ref, "Should I bring an umbrella in San Francisco?")
            .with_tool(weather)
            .with_max_tokens(512),
    )
    .await?;

println!("{}", response.text());
# Ok(())
# }
```

A `Tool` without a handler is declaration-only: if the loop asks for it, the SDK answers with an error result rather than stalling.

For streaming, iterate `agent().stream(request)` and handle `AgentStart`, `TurnStart`, `ToolExecutionStart`, `ToolExecutionEnd`, the wrapped provider deltas, and the terminal `AgentEnd`.

### Agent model discovery

`client.agent().models()` returns the same `ModelsApi` as `client.models()`, over the same transport, for chaining discovery with a run.

## Auth

`auth().list_providers()` inspects auth state; `auth().login(...)` runs an interactive flow. Token material is owned by the runtime and is never exposed by the SDK.

```rust
use makai::{AuthEvent, AuthHandlers, AuthStatus, Client};

# async fn run(client: &makai::Client) -> makai::Result<()> {
let providers = client.auth().list_providers().await?;
let needs_login = providers
    .iter()
    .find(|provider| provider.id == "anthropic")
    .is_none_or(|provider| provider.auth_status != AuthStatus::Authenticated);

if needs_login {
    let handlers = AuthHandlers::new()
        .on_event(|event| {
            if let AuthEvent::AuthUrl { url, .. } = event {
                println!("Open {url}");
            }
        })
        .on_prompt(|prompt| async move {
            println!("{}", prompt.message);
            let mut answer = String::new();
            std::io::stdin().read_line(&mut answer).map_err(|e| e.to_string())?;
            Ok(answer.trim().to_owned())
        });

    client.auth().login("anthropic", Some(&handlers)).await?;
}
# Ok(())
# }
```

A flow that reaches a prompt with no `on_prompt` handler is cancelled rather than left hanging. Dropping the login future sends `auth_cancel`, so the runtime does not leave an OAuth listener running.

You can also configure one-shot automatic retry for `provider` and `agent` calls:

```rust
use makai::{AuthHandlers, AuthRetryPolicy, Client};

# async fn run() -> makai::Result<()> {
let client = Client::builder()
    .auth_retry_policy(AuthRetryPolicy::AutoOnce)
    .auth_handlers(AuthHandlers::new().on_prompt(|_| async move {
        Ok(std::env::var("MAKAI_AUTH_CODE").unwrap_or_default())
    }))
    .connect()
    .await?;
# let _ = client;
# Ok(())
# }
```

With `AutoOnce`, a call that hits `auth_required` logs in once and retries. With no handlers configured and interactive auth required, it fails fast with the typed error rather than hanging.

## Models

Models are discovered through `client.models()`. Use `model_ref` from the returned descriptor in provider and agent requests. **Treat `model_ref` as opaque**: do not parse or construct it.

```rust
use makai::{Client, ListModelsRequest};

# async fn run(client: &makai::Client) -> makai::Result<()> {
let response = client
    .models()
    .list(ListModelsRequest {
        provider_id: Some("anthropic".into()),
        include_login_required: Some(true),
        ..Default::default()
    })
    .await?;

for model in &response.models {
    println!("{}: {} [{:?}]", model.display_name, model.model_ref, model.auth_status);
}
# Ok(())
# }
```

`resolve(provider_id, api, model_id)` is the deterministic single-model lookup. Zero or multiple matches are an `invalid_request` failure.

## Sessions

`RunOptions::session_id` is a **correlation key, not a resume handle**. Sessions are not resumable: on interruption, resend the full context under a fresh id. The SDK generates one per run when you do not supply it, and under `AuthRetryPolicy::AutoOnce` the retried attempt always uses a fresh id, because the first attempt's session is stopped on the way out.

## Configuration

`Client::builder()` configures the transport and binary resolution.

```rust
use std::time::Duration;
use makai::Client;

# async fn run() -> makai::Result<()> {
let client = Client::builder()
    .binary_path("/opt/makai/bin/makai")
    .env("MAKAI_LOG", "info")
    .handshake_timeout(Duration::from_secs(2))
    .response_timeout(Duration::from_secs(30))
    .frame_timeout(Duration::from_secs(30))
    .connect()
    .await?;
# let _ = client;
# Ok(())
# }
```

### Binary resolution

Mirroring the TypeScript resolver, in order:

1. `MAKAI_BINARY_PATH`, then `ClientBuilder::binary_path` / `BinaryResolver::binary_path`;
2. `MAKAI_BINARY_URL` / `binary_url` with a **required** SHA-256 checksum (`MAKAI_BINARY_SHA256` / `checksum_sha256`), cached under `~/.cache/makai/bin`;
3. *(TypeScript only)* the `@makai/cli-<platform>-<arch>` npm package — **not implemented in Rust**, see below;
4. `./zig-out/bin/makai`;
5. `./zig/zig-out/bin/makai`;
6. `makai` on `PATH`.

The environment variable outranks the builder option, as in TypeScript, so an operator can redirect an application that hardcoded a path. `ClientBuilder::command(path)` bypasses resolution entirely when that override is not wanted.

**The npm platform-package step is deliberately omitted.** It resolves through Node's module resolution against an optional npm dependency; Rust has no equivalent channel that ships a platform-specific executable alongside a library crate, and inventing one (a `build.rs` download, say) would put a network fetch in the build with none of the checksum guarantees step 2 insists on. Install the binary however you like and point `MAKAI_BINARY_PATH` at it, or let step 6 find it on `PATH`.

Downloading from a URL needs the `download` feature (off by default, to keep an HTTP stack out of the default dependency tree):

```toml
makai = { version = "0.1", features = ["download"] }
```

Without it, an already-cached file is still checksum-verified and used, and a cache miss is a clear error rather than a silent fallback to a different binary than you pinned.

## Error handling

All failures are one `Error` enum, mirroring the TypeScript error classes:

| TypeScript | Rust |
| --- | --- |
| `MakaiStreamError` | `Error::Stream { kind, code, provider_id, message }` |
| `MakaiAuthRequiredError` | `Error::AuthRequired { provider_id, message }` |
| `MakaiProtocolError` | `Error::Protocol { code, message }` |
| `MakaiAuthError` | `Error::Auth { kind, code, message }` |
| *(untyped in TS)* | `Error::Transport { message }` — spawn, handshake, binary resolution |
| *(untyped in TS)* | `Error::InvalidRequest { message }` — rejected before anything is sent |

```rust
use makai::Error;

# fn handle(error: makai::Error) {
match error {
    Error::AuthRequired { provider_id, .. } => eprintln!("login required for {provider_id}"),
    Error::Stream { kind, code, .. } => eprintln!("stream failed ({kind}/{code:?})"),
    Error::Protocol { code, message } => eprintln!("protocol failed ({code:?}): {message}"),
    Error::Auth { kind, message, .. } => eprintln!("auth failed ({kind}): {message}"),
    other => eprintln!("{other}"),
}
# }
```

`Error::code()`, `Error::provider_id()`, `Error::is_auth_required()`, and `Error::is_cancelled()` are available on every variant.

## Examples

```bash
cargo run --example complete
cargo run --example stream
cargo run --example agent_tools
cargo run --example login -- anthropic
```

## Development

```bash
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test
```

`cargo test` needs no credentials and no runtime binary: the integration tests drive `makai-protocol-fake`, a scriptable stand-in for `makai --stdio` that ships with the crate. Point `ClientBuilder::command` at it to test your own code the same way:

```rust
# fn build() -> makai::ClientBuilder {
makai::ClientBuilder::new()
    .command(env!("CARGO_BIN_EXE_makai-protocol-fake"))
    .args(Vec::<String>::new())
    .env_clear()
    .env("MAKAI_FAKE_SCENARIO", "ok")
# }
```

To also exercise a real runtime:

```bash
zig build install --prefix /tmp/makai-rs
MAKAI_BINARY_PATH=/tmp/makai-rs/bin/makai cargo test
```

Without `MAKAI_BINARY_PATH` the `real_binary` tests skip, mirroring `typescript/test/makai_binary_smoke.test.ts`.

**On macOS**, the two tests that make the runtime *persist* credentials skip by default: `saveToPreferredStorage` writes to the login Keychain, and creating that item from an unsigned local build blocks in `AuthorizationCopyRights` waiting on a UI prompt no test runner can answer. Everything else runs. Set `MAKAI_RUST_SDK_ALLOW_KEYCHAIN=1` to run them on a Mac where the item's ACL is already approved. CI runs on Linux, where the file store is used and the write is unattended.
