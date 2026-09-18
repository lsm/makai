# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Makai is a Zig-first streaming AI runtime plus SDKs for TypeScript, Python, Go and Rust. The Zig core (`zig/src/`) provides a unified multi-provider streaming abstraction (Anthropic, OpenAI Completions/Responses, Azure OpenAI, Google Generative AI, OpenAI Codex, Gemini CLI, Ollama; a Vertex implementation exists but is not registered, see Providers), four distributed wire protocols (auth, provider, agent, tool) plus two native Open Agent Protocol endpoints (`protocol/oap/` for agent control, `protocol/oap/provider/` for model providers), an agent loop with local tool execution, OAuth flows with credential storage, pluggable transports, and a `makai` binary that runs as a stdio protocol host, a native OAP host, a terminal UI, or a one-shot CLI. Each SDK (`typescript/`, `python/`, `go/`, `rust/`) spawns `makai --stdio` and exposes the same `auth`/`models`/`provider`/`agent` namespaces over newline-delimited JSON frames; none of them is wired into the Zig build.

`DESIGN.md` is the authoritative design reference (layers, protocol boundaries, sequencing, ownership, transport posture, test strategy). `docs/v1-sdk-agent-provider-spec.md` is the normative SDK + protocol spec. Read those before changing protocol or SDK behavior.

## Build and Test Commands

All Zig commands run from the repo root (where `build.zig` and `build.zig.zon` live). Requires Zig 0.16.0 (`mlugg/setup-zig` in CI). Node 22 for the TypeScript SDK and scripts.

```bash
zig build                         # Build + install zig-out/bin/makai
zig build run -- --version        # Run the makai CLI (args after --)
zig build run-tui                 # Run the terminal UI
zig build test                    # Run every unit test module
zig build -Doptimize=ReleaseFast  # Optimized binary (what the PTY harness uses)
zig build -Doptimize=ReleaseSafe  # What the tagged release workflow builds
```

A root `Makefile` wraps the everyday commands: `make build`, `make tui` (build, then start
`makai --tui`), `make test`, `make test-tui`, `make check` (guardrail scripts), `make clean`
(project `.zig-cache` + `zig-out`) and `make clean-all` (also the global zig cache).

### macOS: the Keychain, non-interactive runs, and test isolation

On macOS, credential storage is Keychain-first, and the two directions behave differently.

**Reads fail fast.** Every read path runs under `SecKeychainSetUserInteractionAllowed(0)`, so a
binary the `ai.hyperneo.oap` item's access list does not authorize gets `errSecInteractionNotAllowed`
rather than an authorization prompt, and `AuthStorage.loadDefault` falls back to `~/.makai/auth.json`.
That fallback goes through `loadFromFile`, **not** `loadFromFileWithSaveFn`, so a background token
refresh cannot re-save and re-arm the prompt. The degradation is silent by design: the run continues
with whatever the file holds, which may be nothing. Reads also tell contention apart from refusal —
the keychain mutex is taken with a bounded retry, and a holder that outlasts the budget yields a
distinct `busy` result instead of being reported as `needs_interaction`, so an interactive write
mid-prompt no longer makes a concurrent read look like an authorization failure.

**Writes still prompt.** `macos_keychain.write` takes the mutex blocking and leaves interaction
enabled, so persisting credentials from an unauthorized binary raises the prompt — and in a
non-interactive shell that prompt never surfaces, so the write blocks rather than failing. Access
lists bind to the **code hash**, so every unsigned rebuild is a new identity and prompts again. Only
a signed build escapes it, because the access list then binds to the signing certificate rather than
the hash. Released macOS binaries are signed with Developer ID, hardened-runtime enabled and
notarized in `release-binaries.yml`; a tag build fails rather than publishing unsigned macOS
artifacts. Locally, `make build MAKAI_CODESIGN_IDENTITY=<sha1>` signs `zig-out/bin/makai` under the
stable identifier `ai.hyperneo.oap` — a self-signed code-signing certificate is enough for the access
list, no Apple account needed — and a bad identity fails the build instead of silently leaving it
unsigned. Pass the certificate's SHA-1 hash from `security find-identity -v -p codesigning` rather
than its `Developer ID Application: ...` name: a keychain holding the certificate twice makes the
name ambiguous and `codesign` refuses it, while the hash names exactly one certificate. The release
secrets use the same names and formats as `lsm/hyperneo` so one set of values serves both repos —
`APPLE_CERTIFICATE` (base64 `.p12`), `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`,
`APPLE_API_PRIVATE_KEY` (raw `.p8` PEM, **not** base64), `APPLE_API_KEY` (key id) and
`APPLE_API_ISSUER`. Either identity form works in CI, where the throwaway keychain holds one
certificate; the ambiguity is a developer-machine problem. The Keychain item is `ai.hyperneo.oap` (renamed from `com.makai.auth`). Nothing reads the old
service: an existing `com.makai.auth` item is ignored and left in place, so the first run after the
rename falls back to `auth.json` or a fresh login. Delete it manually when you no longer want it. Delete it once after switching signing identity, since the old
access list still names the previous one. Bound any invocation that may persist
credentials with an external timeout so a hang is visible rather than silent.

Reads blocked the same way before #315, which is why older notes describe `makai auth providers
--json` printing `ready` and then going silent on the first credential-touching request. That
symptom is gone. A machine with no `ai.hyperneo.oap` item never reproduced it either —
`SecKeychainFindGenericPassword` returns `errSecItemNotFound` and the load falls back to the file —
so a clean CI runner was never a useful test of it.

```bash
export MAKAI_KEYCHAIN_SERVICE="makai-test-$(uuidgen)"
```

This redirects the whole makai store — `keychainServiceName` in `zig/src/utils/oauth/storage.zig`
picks the service for every makai keychain read and write, not one item. Use a genuinely unique
name per run: a stable one stops being unused the moment anything writes to it, and `$(date +%s)-$$`
collides between subshells started in the same second.

Four limits:

1. **It does not isolate `~/.makai/auth.json`.** With no item under the overridden service,
   `loadDefault` falls back to that file, so a supposedly isolated run can still consume real
   tokens. Redirect `HOME` as well if it may hold live credentials.
2. **It does not isolate the Codex CLI import**, which reads the fixed `Codex Auth` service. That
   import runs on `loadDefault` paths — `makai auth providers` among them — and reads a service the
   override does not cover. It does **not** run on `loadDefaultStoredOnly`, which passes
   `import_codex = false` and serves provider credential resolution, TUI login-status refreshes and
   stored Kimi lookup.
3. **A unique service accumulates credential items.** Anything that persists credentials writes one
   there — not just logins: an ordinary request that refreshes an expired token
   (`streamWithRefresh` → `refreshCredentials` → `persist()`) writes too. makai never deletes them;
   its only delete path is the legacy `auth.json` migration. Clean up on every exit path with
   `security delete-generic-password -s "$MAKAI_KEYCHAIN_SERVICE"`.
4. **The real-binary SDK tests cannot pass on macOS as written.** With or without the override,
   `loadDefault` attaches the Keychain save callback when the service has no item (the `.not_found`
   branch, which the read-side fail-fast change does not touch), so login writes go to the Keychain
   rather than the temporary `HOME`'s `auth.json` and the login assertions in
   `typescript/test/makai_binary_smoke.test.ts` and `typescript/test/demo_server.test.ts` fail on
   `ENOENT`. There is no switch that forces file-backed storage — `shouldUseKeychain()` is
   hardcoded to macOS non-test builds. Run those on Linux.

This does not change where credentials live (see On-disk state below) and is not a reason to move
them to a file.

### Print Mode CLI

```bash
makai -p [--agent] [--storage] [--model <id>] "<prompt>"
```

`--agent`, `--storage`, and `--model <id>` are accepted in any position — before or after the prompt. An unrecognized `--flag` or a second positional argument fails with an error instead of being ignored.

### Grouped Unit Test Steps

There is no per-test filter; the smallest runnable unit is a group step. Tests are inline `test "name" { ... }` blocks in each `.zig` file.

Most groups map to a job in the `unit-tests` matrix in `.github/workflows/ci.yml` (6-minute timeout), but **`test-unit-agent` does not**. That matrix runs the six `agent-*` subgroups and never the aggregate, so a test wired only into `test-unit-agent` passes locally and is never executed by CI. Add new agent tests to the specific `agent-*` subgroup (and to `test`), not just the aggregate.

`tools/*` tests have their own matrix-covered group, **`test-unit-tools`**; none of the `agent-*` subgroups contains them. All eleven tool artifacts are wired there, and `test_unit_agent_step` pulls that step in rather than re-listing its members. So a new `tools/*` test goes into `test_unit_tools_step` (plus `test`).

The invariant behind both paragraphs: every artifact wired into the global `test` step must also be wired into at least one group the matrix actually invokes, and vice versa — `zig build test` is meant to be the superset of CI, not a disjoint set. Wiring a test only into `test` and `test-unit-agent` runs it in no CI job at all; that was live for `tools_artifact_test` until the `test-unit-tools` group was added, and for `sse_parser_test` and `transport_retry_test` in the opposite direction, which sat in matrix groups but not in `test`. `oauth/storage.zig` was the worst case: it had a module but no `addTest` at all, so its thirteen tests ran nowhere and silently rotted past compiling against Zig 0.16 until `oauth_storage_test` was wired into both steps. A module without a test artifact is invisible to this invariant, so check that the `addTest` exists, not just that a group references it.

```bash
zig build test-unit-core          # event_stream, streaming_json, ai_types, tool_call_tracker, owned_slice, string_builder, hive_array, compat, artifact store, bench helpers
zig build test-unit-transport     # transport, stdio, sse, websocket, in_process, transport_retry
zig build test-unit-protocol      # provider/agent/auth/tool protocol types+envelope+server+client+runtime, oap types+envelope+server+bridge (incl. the three golden OAP traces), partial serializer/reconstructor, model_ref, model catalog types, provider_base_url
zig build test-unit-providers     # api_registry, stream, register_builtins, sse_parser, every provider API, auth provider defs
zig build test-unit-utils         # oauth (pkce, openai_codex, refresh_lock, storage, mod), github_copilot, overflow, retry, oom, sanitize, pre_transform, auth_resolver
zig build test-unit-makai-cli     # zig/src/tools/makai.zig + auth_cli
zig build test-unit-tui           # tui runtime/session/config/state/commands/login/app/views, model_catalog, scenarios + e2e + mock transport
zig build test-unit-tools         # all 11 tools/*: common, process_runner, artifact, shell, file, edit, hashline, search, workspace, mcp_bridge, registry
zig build test-unit-agent         # aggregate (local-only, not in the CI matrix): permission, agent types/loop/mod/bridge, tools/*, tui runtime, zig/test/unit/*
zig build test-unit-agent-types   # agent types + permission
zig build test-unit-agent-loop    # agent loop only
zig build test-unit-agent-mod     # agent module only
zig build test-unit-agent-bridge  # agent provider-protocol bridge
zig build test-unit-agent-unit    # zig/test/unit/agent.zig
zig build test-unit-agent-chain   # zig/test/unit/agent_protocol_chain.zig
```

### E2E Steps

```bash
zig build test-e2e-protocol                     # mock-based, no keys; runs in CI
zig build test-e2e-distributed-fullstack        # mock-based, no keys
zig build test-e2e-anthropic                    # ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN, ANTHROPIC_MODEL
zig build test-e2e-openai                       # OPENAI_API_KEY, OPENAI_MODEL, OPENAI_RESPONSES_MODEL
zig build test-e2e-google                       # GOOGLE_API_KEY, GOOGLE_MODEL
zig build test-e2e-ollama                       # OLLAMA_API_KEY, OLLAMA_MODEL
zig build test-e2e-azure                        # AZURE_OPENAI_API_KEY, AZURE_OPENAI_BASE_URL, AZURE_OPENAI_MODEL (disabled in CI)
zig build test-e2e-github-copilot               # GH_COPILOT_REFRESH, GH_COPILOT_ACCESS (disabled in CI, quota)
zig build test-e2e-provider-protocol-fullstack-ollama
zig build test-e2e-provider-protocol-fullstack-github
zig build test-e2e-distributed-fullstack-github
zig build test-e2e                              # aggregate; runs distributed-fullstack via test-e2e-protocol, but omits the -github variant
```

See `.github/workflows/ci.yml` for the exact env wiring and which lanes are currently gated off.

### Guardrails (CI runs both before unit tests)

```bash
./scripts/check-zig-patterns.sh                  # no runtime `catch unreachable`, no direct std.crypto.random, deinit poisoning in critical types, no multi-allocation struct literals
node scripts/check-no-comments.mjs --check       # zero-comments policy over every tracked .zig/.ts (--stats for counts, --write to strip)
node --test scripts/check-no-comments.test.mjs   # checker self-tests
```

`check-zig-patterns.sh` also rejects **a struct literal that allocates more than once**. Zig
evaluates literal fields in order, so when a later `try allocator.dupe` fails the literal never
completes and every field already allocated for it leaks; an `errdefer` cannot be placed inside a
literal, and one written after it never runs, because the assignment it guards was never reached.
The remedy is to build each field into a local with its own `errdefer` first, so the literal itself
is infallible — `cloneModelDescriptor` in `zig/src/protocol/model_catalog_types.zig` is the
reference shape, and `std.testing.checkAllAllocationFailures` is how a fix is proved. The check
scans only non-`test` code and only `dupe`/`dupeZ`/`allocSentinel`/`allocPrint`/`owned(` calls, so
it is a floor rather than a complete detector: the sibling shapes it does **not** see are an
`errdefer` that frees a container without its contents, a fully-built value dropped in a
hand-off such as `try list.append(allocator, try build(allocator))`, and an `errdefer` left armed
after a successful ownership transfer, where a later `try` in the same scope frees what the new
owner will free again. That last one is the most common defect in this tree — six instances on the
`model-provider-core` branch alone — and the thing that finds it is not this script but
`std.testing.checkAllAllocationFailures` over the allocating function, which aborts inside the
owner's `deinit`. Any function that allocates and then hands off ownership should have one. `known_multi_alloc_literals`
declares the 41 sites that predate the check. It is a shrinking backlog, not an approved list:
adding an entry needs a commit-message reason why that literal cannot leak, and the check also
fails when a declared entry disappears, so fixing one requires removing its line.


### TypeScript SDK

```bash
npm ci
npm run build:sdk                 # tsc -> dist/
npm run test:sdk                  # build + node --test dist/test/**/*.test.js (passes with no binary)
npm run check:declarations        # verifies the packed tarball ships .d.ts and type-checks in a fresh consumer
npm run demo:start                # builds then runs dist/demo/server.js
```

`resolveMakaiBinary` picks the binary in this order: `MAKAI_BINARY_PATH` or an explicit `binaryPath`; `MAKAI_BINARY_URL`/`binaryUrl` (checksum required); the platform package `@makai/cli-<platform>-<arch>`; `./zig-out/bin/makai`; `./zig/zig-out/bin/makai`; then `PATH`. **The platform package outranks both local build paths**, so if an optional `@makai/cli-*` package is installed, `zig build` alone does not make the SDK tests exercise your fresh binary. Set `MAKAI_BINARY_PATH` to be sure which one runs (CI builds with `zig build install --prefix /tmp/makai-smoke` and points `MAKAI_BINARY_PATH` at it).

That variable is also what gates real-binary coverage. Every test in `typescript/test/makai_binary_smoke.test.ts` calls `t.skip("MAKAI_BINARY_PATH is not set")` when it is unset, so `npm run test:sdk` passes green with **zero** end-to-end binary coverage, and a binary found through `zig-out` or the platform package does not switch those tests on. Export `MAKAI_BINARY_PATH` explicitly when you mean to exercise the real runtime.

### TUI PTY Harness and Benchmarks

```bash
zig build install -Doptimize=ReleaseFast --prefix /tmp/makai-pty
python3 scripts/tui-pty-driver.py --binary /tmp/makai-pty/bin/makai --output-dir tui-pty-out --scenario all
zig build bench -Doptimize=ReleaseFast -- --mode latency --samples 30 --iterations 100 --host-class <host>
zig build bench-compare -Doptimize=ReleaseFast -- baseline.jsonl candidate.jsonl
./scripts/capture-benchmark-baseline.sh <out-dir> <host-class> [git-revision]
```

The PTY driver is deterministic: `MAKAI_TUI_FIXTURE` selects a canned reply (see `zig/src/tui/fixture_provider.zig`), so no keys or network are needed. It is Linux-only (rejects macOS). Details in `docs/tui-performance-baseline.md` and `docs/performance-baseline.md`.

## Build System Conventions

`build.zig` (~2000 lines) declares a `b.createModule` per **module root** with an explicit `.imports` list, then a `b.addTest` per module, then wires each test into `test` and the matching `test-unit-*` group. Most source files are roots, but not all, and the distinction decides how you add a file:

- Source files import by module name, not path: `@import("ai_types")`, `@import("oauth/storage")`, `@import("tools/registry")`, `@import("compat")`. The name is whatever `build.zig` assigned; `oauth/*` names map to `zig/src/utils/oauth/*`.
- **Module roots** are reached by name. Adding one means: create the module in `build.zig`, list every import it needs, add an `addTest`, and add the run artifact to both `test_step` and the right group step. A missing import fails at compile time with "no module named ...".
- **Files compiled through an existing root** are reached by relative `@import("sibling.zig")` and may need no `build.zig` entry; their tests then run as part of the root's test artifact. `zig/src/compat/{time,random,fs,stdio,http,net}.zig` hang off `compat/mod.zig` this way, as does `agent/agent.zig` off `agent/mod.zig`.
- **A relative import does not by itself mean a file has no module.** `protocol/provider/{partial_serializer,partial_reconstructor}.zig` are imported relatively by `server.zig` and `client.zig` *and* have their own modules and test artifacts wired into `test-unit-protocol`, deliberately, so their tests run as a named group. Decide by checking both the existing importers and `build.zig`, never from the import syntax alone.
- Some tracked files are neither. Four files, about 2,300 lines, have no module, no importer, and are **never compiled by any build step**: `utils/streaming_json.zig` (a different and larger file than the live top-level `streaming_json.zig`), `utils/message_transform.zig`, `utils/tool_utils.zig`, and `utils/tokens.zig`. Nothing type-checks them, so they rot silently rather than loudly, and `utils/tool_utils.zig` still holds a declared entry in `check-zig-patterns.sh`'s `expected_ordinary_entropy_sites` — a security allowlist carrying an exemption for code that never runs, which cannot be removed while the file stays. Confirm with a grep for an `@import` of the file before treating one as load-bearing, and do not copy their wiring as a pattern.
- The live OAuth code is the `zig/src/utils/oauth/` module roots: `storage`, `refresh_lock`, `pkce`, `anthropic`, `github_copilot`, `openai_codex`. The unreferenced `utils/oauth.zig` aggregator and the Google OAuth island it alone reached (`google.zig`, `callback_server.zig`) were deleted; `zig/src/oauth/` contributes just `mod.zig` + `pkce.zig` to the utils test group. Prefer `utils/oauth/` when adding OAuth code.
- `zigzag` is the only **`build.zig.zon`** dependency: a vendored TUI framework at `zig/vendor/zigzag`, declared as a path dependency, and subject to the zero-comments policy like everything else. The repo is not dependency-free overall — `package.json` adds runtime deps (`nanoid`, `ulid`), dev deps (`typescript`, `@types/node`), and six optional `@makai/cli-*` platform packages, all of which `npm ci` resolves. Count both graphs for offline-build or supply-chain work.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Hosts: zig/src/tools/makai.zig (CLI: --stdio, --tui, -p,    │
│         auth), zig/src/tui/ (zigzag TUI), typescript/ (SDK)  │
├──────────────────────────────────────────────────────────────┤
│  Agent Layer (agent/): agent.zig, agent_loop.zig, types.zig, │
│    provider_protocol_bridge.zig                              │
│  Local tools (tools/): shell, file, edit, search, workspace, │
│    artifact, hashline, mcp_bridge, registry, permission      │
├──────────────────────────────────────────────────────────────┤
│  Protocol Layer (protocol/): auth/, provider/, agent/, tool/,│
│    oap/ (native Open Agent Protocol endpoint: types, envelope,│
│    server, bridge; translates to/from the agent protocol)    │
│    all: types + envelope + runtime. provider/agent add       │
│    client+server; auth adds server; tool keeps its           │
│    server/client/pipe inside local_runtime.zig               │
│    model_ref.zig, model_catalog_types.zig                    │
├──────────────────────────────────────────────────────────────┤
│  Transport Layer: transport.zig (Sender/Receiver, ByteStream)│
│    transports/: stdio, sse, websocket, in_process, retry     │
├──────────────────────────────────────────────────────────────┤
│  Streaming Core: ai_types, event_stream, api_registry,       │
│    stream, streaming_json, tool_call_tracker, json/writer,   │
│    providers/sse_parser, model_catalog, provider_base_url    │
├──────────────────────────────────────────────────────────────┤
│  Providers (providers/): anthropic_messages, openai_         │
│    completions, openai_responses, azure_openai_responses,    │
│    google_generative, google_vertex, ollama,                 │
│    register_builtins                                         │
├──────────────────────────────────────────────────────────────┤
│  Utils, auth, compat: utils/ (oauth/*, auth_resolver, retry, │
│    sanitize, overflow, pre_transform, provider_caps, ...),   │
│    auth/providers.zig, compat/ (time, random, fs, stdio,     │
│    http, net wrappers over Zig 0.16 std.Io)                  │
└──────────────────────────────────────────────────────────────┘
```

### Canonical Distributed Topology

```
End user code -> Agent Protocol Client -> transport -> Agent Protocol Server
  -> Agent -> Agent Loop -> Provider Protocol Client -> transport
  -> Provider Protocol Server -> Provider
Agent Loop -> Tool Protocol Client -> transport -> Tool Protocol Server -> Tool Runtime
```

Ownership and auth boundary (non-negotiable):
- **Agent layer is auth-agnostic**: no API keys or OAuth handling in agent logic.
- **Auth protocol/runtime owns interactive OAuth flows and credential persistence**; **providers own request-time credential consumption/refresh** (`utils/auth_resolver.zig`, `utils/oauth/storage.zig`).
- **Tool auth/permissions live at the tool protocol / tool runtime boundary** (`tools/permission.zig`, `protocol/tool/local_runtime.zig`).
- SDKs never see raw tokens and must not spawn `makai auth ...` subprocesses as their auth path.

### How the `makai --stdio` host is wired

`runStdioMode` in `zig/src/tools/makai.zig` hosts all three protocol servers (auth, provider, agent) in one process, each behind its own `in_process.SerializedPipe`, and routes inbound stdin frames by envelope type. The agent server drives `agent_loop` through `agent/provider_protocol_bridge.zig` (`InProcessProviderProtocolBridge`), so even in-process the agent talks to providers through the provider protocol. Distributed tools are executed by the SDK client: the host publishes `tool_execute`, waits for a correlated `tool_result` (`in_reply_to` must match the request `message_id`), and cancels parked waits on stdin EOF. `MAKAI_AGENT_SESSION_IDLE_TTL_MS` tunes server-side idle-session eviction (default 30 min, `0` disables). `MAKAI_OAP_PROVIDER_STREAM_IDLE_TTL_MS` does the same for `makai --oap-provider`: it cancels a provider stream that has produced **no event** for that long (default 2 min, `0` disables). It measures silence rather than total duration on purpose — an extended-thinking generation legitimately runs for minutes and would be aborted by a wall-clock cap, while a wedged connection produces nothing at all.

### The two OAP profiles are separate endpoints, not one endpoint with a switch

`makai --oap` serves `open-agent-protocol.agent-control-core` and `makai --oap-provider` serves
`open-agent-protocol.model-provider-core`. Each **refuses the other's profile** at decode, so a
client cannot reach the provider vocabulary through the agent-control mode or the reverse, and the
refusal names which profile the endpoint serves. They share the base envelope and the shared
vocabulary (`ContentPart`, `Message`, `Usage`) by importing the agent-control types rather than
redeclaring them, so a content part means the same thing on both boundaries. They do **not** share
`ProtocolError`: the two profiles have disjoint error code sets and neither is a subset of the
other, so each carries its own.

The provider endpoint is `zig/src/protocol/oap/provider/` — `types`, `envelope`, `server`,
`catalog`, `runtime`. `catalog.zig` maps our eight registered APIs onto the profile's closed wire
set: five earn a named wire (`anthropic-messages`, `openai-chat-completions`, and
`openai-responses`, which Azure, Codex and native OpenAI all share and are told apart by provider
id and endpoint), and three say `other` with an opaque `wire_id` because no second implementer
speaks their shape — both Google APIs and Ollama. `runtime.zig` translates our assistant event
union into the profile's part triples and our `OpenAICompatOptions` into its twelve compatibility
facts.

**Eleven of those twelve facts carry across unchanged; `usage_in_streaming` does not.** Ours gates
whether we send `stream_options.include_usage` — a request-shape fact. The profile's describes when
usage arrives. `true` implies `always`, but `false` says nothing about whether the endpoint reports
usage in its terminal chunk, so the mapping leaves the fact unstated rather than guessing between
`never` and `terminal_only`, and reports the undecidable case in its return type.

Two rules the profile makes normative are enforced at **both** ends rather than only on decode: a
`tool_call` part start must carry `tool_call_id` and `name` and a `text` or `reasoning` start must
not, and a part end is kind-discriminated. Refusing to *build* an invalid frame is what stops a
host from discovering it in somebody else's decoder. The same applies to the structural invariants
— a delta with no open part, a mismatched part index, a terminal with a part still open, a second
terminal.

**Anything decidable from the descriptor and the request alone is a create-time refusal, never a
terminal.** An unsupported `include_snapshot`, an unknown provider and a malformed `model_ref` are
knowable before a request leaves the process, so they refuse at `inference.create` and allocate
nothing. A rate limit, a provider outage and an expired credential are terminals, because only the
attempt reveals them. An inference exists if and only if it was accepted; a refusal carries no
`inference_id` and owes no terminal.

A missing credential splits across that line and the rule decides which side by its own test rather
than by the word "credential". When the endpoint does **not** resolve its own credentials, a request
that had to name one and did not is decidable from the descriptor and the request, and refuses at
create. When the endpoint **does** resolve its own — which is what `makai --oap-provider` advertises,
`resolves_own_credentials = true` — whether a usable credential exists is keychain state at the
moment of the attempt, which is neither the descriptor nor the request, so it is an `inference.failed`
terminal carrying `credential_missing`. Callers must expect the terminal from this host: the
create-time branch exists for an endpoint configured the other way and never fires here.

Credential grants are advertised on the descriptor (`credential_grant`, `grant_kinds`) so a caller
learns the tier before sending a secret. makai advertises the **out-of-band tier with the `static`
kind only**, and only where it can serve it: the channel is a per-grant unix socket, so a build
whose toolchain reports no unix-socket support advertises `none` rather than a tier it cannot open.
That is `std.Io.net.has_unix_sockets`, which is false for Windows targets in Zig 0.16 — a fact about
this toolchain and not about the platform, since Windows itself has carried AF_UNIX since build
17063. The guard names the capability rather than the operating system so it stops applying by
itself if the toolchain gains support. A static key is safe by construction
because a per-call `api_key` short-circuits the storage path entirely in `streamWithRefresh`; a
**refreshable** grant is still refused, because `AuthStorage.persist` has two branches and both
write, so we have no representation for a credential that cannot reach durable storage and the
profile's non-persistable requirement is not satisfiable until one exists.

The channel lives in `protocol/oap/provider/grant_channel.zig` and follows the stdio binding: the
socket is created per grant under a directory created 0700, the accept and the read are polled with
a zero timeout so the envelope stream never blocks on a silent caller, exactly one connection is
read, a first line that is not the nonce closes the connection without an error envelope, the value
is the bytes after that newline to the close, and the socket and its directory are destroyed when
the grant settles either way. A grant whose socket cannot be opened is refused immediately rather
than left pending, because the arrival deadline runs from the channel envelope and an unannounced
grant would have no deadline at all.

The profile can be **conformance-tested** and cannot yet be **compatibility-tested**, and the two
words must not be used interchangeably about it. A harness can spawn `makai --oap-provider`, drive
discovery, run an inference against a local anonymous provider with no credentials, and assemble a
trace — that covers every envelope. None of the twelve compatibility facts has been checked against
the vendor it describes.

### Protocol Normative Rules (from DESIGN.md §4-5)

- IDs: `session_id` is a 21-char NanoID; `message_id`, `stream_id`, `flow_id` are 26-char uppercase Crockford ULIDs. Treat all as opaque.
- Sequencing is per session/stream (provider: `stream_id`; auth: `stream_id` for queries, `flow_id` for login; agent: `session_id`) and starts at 1. A global counter is non-conformant.
- The strict "+1, no gaps or duplicates" reading applies to **inbound** request sequences. On the agent protocol's outbound side it does not: per spec §13, `session_info`, `pong`, and `tool_list_response` echo the request's inbound sequence verbatim as a correlation value, request-validation `agent_error` envelopes carry `sequence: 0`, allocated frames can be observed out of counter order, a retried publication may burn a value and leave a gap, and a re-registered session id restarts its counter so values repeat. Consumers must not order echo frames against allocated frames or treat gaps as loss. Read `docs/v1-sdk-agent-provider-spec.md` §13 before changing any of this.
- The auth, provider, and agent protocols multiplex concurrent sessions over one transport; ordering is guaranteed only within a session/stream. DESIGN.md §5 scopes this to those three: the tool protocol is envelope-keyed by `server_id` and its local runtime advances a single runtime-wide sequence, so per-session tool counters are not a behavior you can assume.
- Model refs are `provider_id/api@<percent-encoded model_id>` (`protocol/model_ref.zig`). `formatModelRef` percent-encodes every byte outside the unreserved set (`A-Z a-z 0-9 - . _ ~`), and `parseModelRef` rejects a raw one, so Ollama's `gemma4:31b` travels as `gemma4%3A31b`. Build refs with `formatModelRef` rather than concatenating; SDK consumers must treat the result as opaque and neither parse nor construct it.
- `session_id` is a correlation key, never a resume handle. Sessions are not resumable.

### Key Abstractions

**`ai_types.zig`**: `AssistantContent` is the assistant-side content union — variants `text: TextContent`, `thinking: ThinkingContent`, `tool_call: ToolCall`, `image: ImageContent`. There is **no** `ContentBlock` type and no `tool_use` variant; `tool_result` is a variant of the top-level `Message` union (`user`, `assistant`, `tool_result`), not of assistant content. `AssistantMessageEvent` (start, the text/thinking/toolcall start/delta/end triples, `done`, `@"error"`, `keepalive`). Only the first ten carry a `partial: AssistantMessage`; `done` carries `message`, `@"error"` carries `err`, and `keepalive` is `void`, `AssistantMessage`, `Usage` (+ `calculateCost`), `Model` (with `OpenAICompatOptions`), `StreamOptions`, `CancelToken`, `ToolCall`, plus `clone*`/`deinit*` helpers.

**`event_stream.zig`**: `EventStream(T, R)`, a lock-free ring buffer with futex wakeups (`RING_BUFFER_SIZE = 1024`, `usable_capacity = 1023` because one slot separates full from empty; read the constants rather than hard-coding either number). `AssistantMessageStream = EventStream(AssistantMessageEvent, AssistantMessage)`. Methods: `push`, `poll`, `pollBatch`, `wait`, `complete`, `completeWithError`, `getError`, `getResult` (borrowed), `cloneResult` (owned). `owns_events` (default false) is an **ownership** flag, not a cloning switch: it says the consumer frees each polled event and that `deinit()` frees whatever is still queued. `push` deep-copies only when `clone_event_fn` is **also** set. Both production routes exist, and you must pick one deliberately: the stdio host and TUI set `owns_events` together with `clone_event_fn = ai_types.cloneAssistantMessageEvent` and let `push` clone, while `ProtocolClient` and the OpenAI Completions provider set `owns_events` alone and call `cloneAssistantMessageEvent` themselves before pushing. Setting `owns_events` with neither is a use-after-free: `push` stores your borrowed slices and they are later freed as owned memory.

**`api_registry.zig` + `register_builtins.zig`**: providers register by API name. Built-ins: `anthropic-messages`, `openai-completions`, `openai-responses`, `azure-openai-responses`, `openai-codex-responses`, `google-generative-ai`, `google-gemini-cli`, `ollama`. `stream.zig` exposes `stream`/`streamSimple`/`complete`/`completeSimple` facades over the registry.

**`protocol/provider/client.zig`**: `ProtocolClient` is multiplexed. Per-stream lifecycle: `startStream` (keep the `stream_id`) -> `getEventStreamFor` -> `waitResultFor`/`getLastErrorFor` -> `closeStream` -> `removeStreamState`. **`waitResultFor` hands back a shallow copy of the message held in `stream_results`, and `removeStreamState` calls `deinit` on that stored message.** This is a different API from `EventStream.cloneResult` and the stream rules below do not cover it: if the result must outlive cleanup, `cloneAssistantMessage` it before calling `removeStreamState`, or you are left holding freed slices. `partial_serializer.zig`/`partial_reconstructor.zig` move `AssistantMessage` snapshots across the wire.

**`protocol/*/runtime.zig`** files are pump/orchestration runtimes hosted on the server side of each boundary, not protocol definitions.

The four protocol directories are **not** symmetric, so do not go looking for a file by analogy: `provider/` has `client.zig` + `server.zig` (plus the partial serializer/reconstructor and `content_partial.zig`), `agent/` has `client.zig` + `server.zig`, `auth/` has `server.zig` and **no client module**, and `tool/` has neither at top level. `tool/local_runtime.zig` holds `ToolProtocolServer`, `ToolProtocolClient`, and `LocalToolProtocol` together, with `tool/runtime.zig` providing `ToolProtocolRuntime`.

**`agent/`**: `AgentEvent` has twelve variants — `agent_start`, `agent_end`, `turn_start`, `turn_end`, `message_start`, `message_update`, `message_end`, `context_usage`, `prompt_segment_usage`, `tool_execution_start`, `tool_execution_update`, `tool_execution_end`. There is **no** `error` variant, and failure does not arrive through one channel. Check three things, in this order:

1. **`stream.getError()`** — when `runLoop` returns an error the thread calls `completeWithError` *instead of* pushing `agent_end` (`agent_loop.zig`), so no terminal event ever arrives. A consumer that waits for `agent_end` hangs. Check this first.
2. **`final_message.stop_reason == .@"error"`** — a provider failure still produces a normal `agent_end`, with `termination` left `null`. `Agent.` code treats this as `error.AgentLoopFailed` (`agent.zig`).
3. **`AgentEndPayload.termination`** — an optional `AgentTermination` that encodes only `max_turns` or `cancelled`. It is `null` both on a clean finish and on the provider-failure case above, so **a null `termination` is not proof of success.** Also `AgentTool`, `AgentLoopConfig`, `AgentContext`, `AgentEventStream`. `agent_loop.zig` supports steering/follow-up messages and sequential tool execution with streaming updates. `zig/docs/agent-loop-design.md` describes the design.

**`tools/registry.zig`**: `ToolRegistry.registerDefaults()` installs the built-in local tools; `registerMcpBridge` adds MCP-provided tools. `tools/permission.zig` classifies calls (read/write/shell) into allow/deny/prompt decisions and drives the TUI approval flow.

**`compat/`**: Makai-owned wrappers over Zig 0.16 `std.Io` (time, random, fs, stdio, http, net). Per `docs/zig-0.16.0-io-architecture-decision.md`, public constructors and entry points must not take `std.Io` in their signatures; only internal helpers may. Use `compat.random` secure helpers for OAuth state, PKCE, WebSocket masks, and protocol IDs. `check-zig-patterns.sh` enforces this two ways. Its `secure_random_files` list — both `pkce.zig` files, `utils/oauth/openai_codex.zig`, `transports/websocket.zig`, `protocol/provider/types.zig`, and `tui/app.zig` — fails on *any* ordinary-entropy call, matched as raw text on purpose so a scanner bug cannot quietly unprotect them, and it also fails if a listed path stops existing, so moving one of these files is loud rather than silent. Separately it scans every `zig/src/**/*.zig` for ordinary-entropy calls and fails on any site not declared in `expected_ordinary_entropy_sites`, and on any declared site that has gone away. Adding an ordinary-entropy call anywhere under `zig/src` therefore means declaring that exact line with rationale in the commit message.

### Stream Completion and Memory Ownership (CRITICAL)

A stream ends via `complete(result)` / `completeWithError(msg)`. Never gate on a `.done` event: no built-in provider pushes one (pushing `.done` would alias the same `AssistantMessage` in an event and the result and double-free). Consumer pattern: drain `wait()` until it returns `null`, check `getError()`, then `cloneResult(allocator)` before `deinit()`.

**EventStream does not own event strings** unless `owns_events` is true. Provider events carry borrowed slices into SSE/JSON buffers owned by the producer thread. `ProtocolClient` deep-copies with `cloneAssistantMessageEvent()` before it queues. **Do not make event cleanup in `EventStream.deinit()` unconditional**; an unguarded `deinitAssistantMessageEvent()` double-frees borrowed paths (CI, 2026-02-19). The existing guarded call must stay: `deinit` drains through `deinitGenericEvent`, which calls `deinitAssistantMessageEvent` **only when `owns_events` is true**, and that is what frees unread events on owned streams. Removing or bypassing the guarded call leaks every queued event on the owned-stream paths. Providers and mocks must hand `complete()` a fully heap-owned result because the stream frees it at `deinit()`. Full contract: `docs/zig-stream-memory-ownership.md`.

Passing an explicit `std.mem.Allocator` is the convention, not a guarantee the codebase currently meets everywhere: `transports/stdio.zig` builds its compatibility framer on `std.heap.page_allocator` and `utils/oauth/storage.zig` parses JWT expiry through it, so neither shows up in a test allocator's leak accounting. Tests use `std.testing.allocator` for leak detection. The ring buffer's 1024 slots are preallocated and streaming never grows them, but streaming is not allocation-free: on an owned-event stream with `clone_event_fn` set, every `push` deep-copies the event.

## The `makai` Binary

```
makai --version
makai --stdio                                   # protocol host for the TS SDK (NDJSON frames on stdin/stdout)
makai --oap [--model <model-ref>]               # native Open Agent Protocol host, agent-control-core profile
makai --oap-provider                            # native Open Agent Protocol host, model-provider-core profile
makai --tui                                     # local-only terminal UI
makai -p [--agent] [--storage] [--model <id>] "<prompt>"   # print mode: stream one prompt, dump every event
makai auth providers [--json]                   # thin wrappers over the auth protocol runtime
makai auth login --provider <id> [--json]
```

Print-mode options are position-independent as of #287 (see Print Mode CLI above): `--agent`, `--storage`, and `--model <id>` parse before or after the prompt, an unknown `--flag` or a second positional argument is a hard error rather than being ignored, and `--tui-runtime` must still precede the prompt.

On-disk state: **credential storage is platform-dependent.** On macOS the login Keychain item `ai.hyperneo.oap` (account `auth.shared.json`, renamed from `com.makai.auth`, which is no longer read) is the primary store: `AuthStorage.loadDefault` reads it first and `saveToPreferredStorage` writes there, falling back to `~/.makai/auth.json` only when the item is absent or the Keychain is unavailable. Everywhere else (and under `builtin.is_test`) the file is the store. So on macOS, debugging, backing up, or clearing credentials by touching `auth.json` alone inspects the wrong place and can leave live credentials in the Keychain. The file itself is mode 0600, written via same-directory temp + rename. TUI sessions live in `~/.makai/sessions` and TUI config under `~/.makai`. `.makai/` is gitignored. `MAKAI_BASE_URL` (+ `MAKAI_BASE_URL_IS_PROXY`) and per-provider `*_BASE_URL` vars override endpoints (`provider_base_url.zig`). `MAKAI_DEBUG_PROVIDER_PAYLOAD=<path>` makes the OpenAI Completions provider write its request body to that file.

## Providers

**Adding a provider**: create `zig/src/providers/<name>_api.zig` with `stream*()` functions that build JSON via `json/writer.zig`, parse the upstream response in whatever framing it actually uses, and push into an `AssistantMessageStream` honoring the `CancelToken`. Use `providers/sse_parser.zig` only for genuine Server-Sent Events (Anthropic, both OpenAI APIs, Azure, both Google APIs); `ollama_api.zig` is the counterexample, parsing newline-delimited JSON with no SSE parser at all; register it in `register_builtins.zig`; declare the module and tests in `build.zig` (`test-unit-providers` group); add an E2E file under `zig/test/e2e/` and a CI lane if it needs keys.

**Adding a transport**: implement `Sender`/`Receiver` from `transport.zig` in `zig/src/transports/<name>.zig`; wire into `build.zig` with the `transport` import and the `test-unit-transport` group.

**Custom endpoints**: users declare OpenAI- and Anthropic-compatible endpoints in `~/.makai/providers.json`, parsed by `zig/src/custom_providers.zig` and turned into models by `loadCustomModels` in `model_catalog.zig`. That file never holds a key: credentials come from the keychain under the provider id (`/login <id>`) or from an environment variable the entry names. A declared `models` list is an allowlist over live `/v1/models` discovery, not just a fallback. `base_url` is normalised to the origin, because `openai_completions_api.buildUrlWithSuffix` concatenates without a double-suffix guard and a pasted `.../v1` would otherwise 404. A `capabilities` block populates `Model.compat`, which both OpenAI providers honor through `mergeCompat`. Capability fallback is per key: `parseCapabilities` seeds undeclared keys with the generic values URL detection yields for an unrecognised host, because the struct's own defaults are OpenAI-native and cannot express unset. Custom providers reach the TUI and CLI only; `models.list` is a separate catalog. See `docs/custom-endpoints.md`.

Notes: OpenAI Responses (`openai-responses`) and Completions (`openai-completions`) are separate wire formats; Google Generative uses API keys, and Vertex needs `GOOGLE_CLOUD_PROJECT` (or `GCLOUD_PROJECT`), `GOOGLE_CLOUD_LOCATION`, and an API key from `GOOGLE_API_KEY` or `StreamOptions.api_key` — there is no Application Default Credentials support, and `GOOGLE_APPLICATION_CREDENTIALS` is read and discarded, so an ADC-only setup fails with `error.MissingApiKey`. **Vertex is also not reachable at runtime**: `register_builtins.zig` never imports or registers `google_vertex_api.zig`, so there is no `google-vertex` API in the registry and a request for one fails provider lookup. The module is compiled only as its own test artifact. Registered APIs are exactly: `anthropic-messages`, `openai-completions`, `openai-responses`, `azure-openai-responses`, `openai-codex-responses`, `google-generative-ai`, `google-gemini-cli`, `ollama`; Anthropic and Google support `thinking` blocks with `budget_tokens` (Google replays `thoughtSignature`); OpenAI Completions is an owned-event stream (`owns_events == true`). The SDK's `models.list` is served by `handleModelsRequest` in `protocol/provider/server.zig` and falls back to the `STATIC_MODEL_CATALOG` array in that same file — **that** is the array to edit when a model should appear to SDK callers. The separate top-level `model_catalog.zig` loads Codex and Kimi models for the CLI and TUI runtime and does not feed `models.list`. AWS Bedrock is **not** supported and has no implementation in the tree; the unwired stub and the unused SigV4 signing helper were deleted rather than left to rot.

## TUI

`zig/src/tui/` is built on the vendored `zigzag` framework: `app.zig` (entry, approval waiter, fixture runtime), `runtime.zig` (`TuiRuntime` over the agent loop with local tools and a `PermissionMode` of ask/bypass), `session.zig`/`session_store.zig` (JSONL persistence; a session file may reach `load_max_bytes` = 64 MiB, each record is capped at `max_jsonl_line_bytes` = 8 MiB, and metadata loads read a 1 MiB tail), `state.zig`, `commands.zig` (10 ratified `CommandKind`s — help, model, login, provider, status, resume, permissions, clear, abort, quit — exposed as 12 accepted names, since `/sessions` aliases `/resume` and `/perm` aliases `/permissions`), `views/` (transcript, composer, status_bar, approval, session_picker, menu_picker), `render.zig`, `text.zig`, `theme.zig`. The TUI is local-only (no remote backend). Deterministic tests use `fixture_provider.zig` and `tests/mock_transport.zig`; the PTY harness covers the real terminal path.

`makai --tui` is an inline (non-alt-screen) terminal UI on the vendored `zigzag` framework. The renderer contract — cursor-relative live region, `Context.printAbove` for persistent transcript rows, `Context.requestClearScreen`, the app's `inline_history_flushed` cursor and active-entry rules, the visual language, and the key map — is documented in `docs/tui-rendering-model.md`; read it before touching `app.zig` `view`/`update`, the views, or `zig/vendor/zigzag/src/core/program.zig`. Tests that drive `TuiModel.update` must pass a real `zz.Context` (`TestContext` in `app.zig`), and the e2e driver runs in `.inline_history` mode. The TUI owns the terminal: never print to stdout/stderr from TUI code paths (stderr is redirected to `~/.makai/tui-stderr.log` while it runs); append a transcript row instead. Credential storage (`zig/src/utils/oauth/storage.zig`) is keychain-first on macOS: reads fail fast and fall back to `auth.json`, writes still prompt, and `MAKAI_KEYCHAIN_SERVICE` isolates items in local runs — see the macOS Keychain section above for the mechanism and the four limits of that override. Never move credentials to a plain file. The PTY harness (`scripts/tui-pty-driver.py`, Linux only) plus `docs/tui-performance-baseline.md` cover the real binary.

## Zig Conventions

- **Zero comments** in every tracked `.zig` and `.ts` file, including `build.zig`, tests, fixtures, and `zig/vendor`: no `//`, `///`, `//!`, block, or JSDoc comments. The only exemptions are functional directives: `// zig fmt: off|on`; in TypeScript, shebangs, file-leading `/// <reference>` and `@ts-check`/`@ts-nocheck`, `@ts-ignore`/`@ts-expect-error`, JSDoc `@deprecated`, `biome-ignore`, `eslint-*`, `oxlint-*`, knip `@public`/`knip-ignore`, and `v8`/`istanbul`/`c8` ignores. The allowlist ratchet is retired (`scripts/no-comments-allowlist.txt.retired`); there is no grandfathering. Rationale goes in commit messages, PR descriptions, `docs/`, and tests.
- **Do not encode a capability claim in a name.** With no comments, a name is the only documentation a reader gets, and a name that contradicts its body is the one defect the policy makes invisible — nothing goes stale, nothing fails to compile. The risk is specific to names asserting what the code *supports*: `handleSyncUnsupported` answered `inference.sync` with a real snapshot for as long as sync existed, because the name was accurate when written and nothing forced the author back to it once support arrived. Names encoding an action or a predicate over data cannot rot this way — `abandonOpenPart`, `expiredGrantNonce`, `allowsDegraded` stay true because actions do not change underneath their names. An audit of the fifteen assertion-shaped names in `protocol/oap/provider/` found exactly one rotted, and it was the only capability-state one. The rule is sharper for **test** names than function names: a function with a stale name still does what it does, while a test named for a policy its body never exercises is a claim that something was checked when it wasn't, and the gap it names looks closed to everyone who scans the list. `"a published descriptor header is not policed the way caller text is"` only ever decoded a benign `X-Tenant` header, so it passed unchanged when that policy was reversed.
- snake_case functions/variables, PascalCase types, inline tests, error unions, comptime generics.
- **Poison after deinit**: critical `deinit()` methods end with `self.* = undefined;`. The pattern script requires it in event_stream, api_registry, agent, protocol client/server, tool_call_tracker, streaming_json, sse_parser, partial_reconstructor.
- **`OwnedSlice(T)`** (`owned_slice.zig`) instead of ad-hoc `owned_*: bool` flags.
- **`oom.unreachableOnOom(...)`** (`utils/oom.zig`) instead of `catch unreachable` (only `utils/retry.zig` is exempt).
- **Two-phase `StringBuilder`** (`string_builder.zig`): `count`/`countFmt`, one `allocate`, then `append`/`appendFmt`.
- **`HiveArray(T, capacity)`** (`hive_array.zig`) for bounded high-churn pools.
- **Artifact-store tests must isolate their root.** `tools/common.zig`'s `storeArtifact`/`retrieveArtifact`/`cleanupArtifacts` resolve `.makai/tool-artifacts` against an injectable root: the process cwd in production (the override is typed `void` outside test builds, so the branch is comptime-dead and the shipped binary is unchanged), a per-test `std.testing.tmpDir` in tests. Any test that reaches the store — directly, or through a tool like `file_read`/`shell_execute` that stores large output — must open with `var artifact_root = common.TestArtifactRoot.init(); defer artifact_root.deinit();`. Reaching it without one **panics** in test builds rather than silently falling back to the real cwd store, so a forgotten isolation fails deterministically on first run instead of flaking. This replaced the `build.zig` run-step chain that used to serialize `tools_common -> artifact -> shell -> search -> file`: those five binaries shared one cwd directory, and `cleanupArtifacts()`'s `deleteTree` in one wiped files another was mid-read on. Membership was by static reachability (grep `makeTextResultWithArtifact|storeArtifact|retrieveArtifact|cleanupArtifacts` under `zig/src/tools/`); the panic now enforces that rule at runtime, so tool tests run in parallel again.
- Background reading: `docs/bun-zig-patterns.md`, `docs/tigerbeetle-zig-patterns.md` (invariant helpers, explicit limits at external accumulation points, validate-at-boundary vs assert-internal).

## Docs and PR Process

- Commits follow `type(scope): subject (#PR)` (e.g. `fix(tui): ...`, `feat(agent): ...`, `docs(spec): ...`). `CHANGELOG.md` follows Keep a Changelog; add entries under `Unreleased`.
- `.github/PULL_REQUEST_TEMPLATE.md` is deliberately minimal: what changed and why, plus reviewer notes. Keep PR descriptions short and scannable — no section headers for a single-area change, no checklist of every command that passed. The heavier requirements live in `docs/review-process.md` §6–§7 and apply only to the PRs its §2 scopes.
- The heavier gate in `docs/review-process.md` is **scoped**: by its own §2 it is required for V1 implementation PRs across Phases 1, 1.25, 1.5, 2a, 2b, 2c, and 3 through 6. Those PRs must link exact spec clauses (`docs/v1-sdk-agent-provider-spec.md`, `docs/ts-sdk-chat-integration-plan.md`, `DESIGN.md`), update rows in `docs/implementation-traceability-matrix.md`, stay inside one phase/sub-phase, and clear at least two external review rounds with no unresolved P0/P1. Unrelated docs, tooling, release, or TUI work is not bound by the traceability-matrix and spec-clause requirements.
- Either way, if behavior changes, update the spec/docs in the same PR. No spec drift.
- `docs/oap-alignment.md` is the Open Agent Protocol deviations ledger; `docs/zig-0.16.0-*.md` record the completed Zig 0.16 migration and its I/O decision; `docs/persisted-tool-call-rendering.md` and `docs/markdown-rendering-investigation.md` cover TUI rendering decisions.
- Release: tagging `v*` runs `.github/workflows/release-binaries.yml` (six targets) and `scripts/package-npm.ts` builds the `@makai/cli-<platform>` optional-dependency packages that `bin/makai.js` dispatches to. CI's cross-compile smoke job builds the non-native targets on every PR.
