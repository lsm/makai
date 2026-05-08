# Zig 0.15.2 → 0.16.0 Migration Plan

Date: 2026-05-07  
Source research: [`docs/zig-0.16.0-upgrade-impact-assessment.md`](./zig-0.16.0-upgrade-impact-assessment.md)  
Target: Makai `zig/` codebase and CI, migrating from Zig 0.15.2 to Zig 0.16.0

## Goal summary

Migrate Makai from Zig 0.15.2 to Zig 0.16.0 while preserving current provider, protocol, transport, OAuth, agent-loop, and CLI behavior. The migration should be delivered as a staged sequence of reviewable PRs: first add compatibility seams and focused regression tests that still compile on 0.15.2, then switch the compiler/dependency baseline, then complete the core/std, I/O, provider/OAuth, transport, and validation work on 0.16.0. The initial objective is compile/test parity and minimal architectural churn, not a full redesign around evented I/O or a libxev-backed `std.Io` adapter.

## Design decisions and rationale

1. **Use a staged migration instead of one large rewrite.**  
   The impact assessment identifies high-volume mechanical changes and high-risk I/O/concurrency changes. Splitting wrapper/test preparation from the compiler switch keeps early PRs reviewable and reduces the amount of behavior change that lands at the Zig 0.16.0 sync point.

2. **Make the compiler switch the hard synchronization point.**  
   All Phase 0 work must compile and pass on Zig 0.15.2. After the Phase 1 compiler/dependency switch lands, all follow-up work should target Zig 0.16.0 only.

3. **Prefer project-level compatibility seams over ad hoc call-site rewrites.**  
   Introduce central wrappers for time, sleep, random, filesystem/stdio, HTTP client construction/request flows, and networking. This avoids duplicating 0.16-specific decisions across providers, OAuth flows, transports, and CLI code.

4. **Use the simplest supported `std.Io` backend for initial parity.**  
   Do not depend on libxev implementing `std.Io`; the research notes that upstream libxev issue #219 is still open. The initial migration should choose a standard Zig 0.16 backend with networking support, then defer evented/libxev integration to a later project.

5. **Preserve public behavior before redesigning APIs.**  
   Threading explicit `std.Io` through every public API may be the long-term direction, but the first migration should minimize downstream churn. Where API changes are unavoidable, isolate them behind constructors/context objects and document them in the relevant implementation PR.

6. **Treat provider HTTP streaming and `EventStream` synchronization as the highest-risk areas.**  
   Provider/OAuth HTTP request flow changes and futex/mutex/condition migration can introduce subtle runtime failures even after compilation succeeds. These work items require focused regression tests and careful review.

## Phased PR sequence

### Phase 0 — Preparation wrappers and regression tests on Zig 0.15.2

Purpose: create compatibility seams and tests while the codebase still builds on the current toolchain. Phase 0 tasks should be done in parallel where they touch separate layers.

#### Work item 1 — Add I/O compatibility design skeleton

Priority: **high**

Create a small `zig/src/utils` or `zig/src/compat` module that defines the intended wrapper boundaries for time, sleep, random, filesystem/stdio, HTTP, and networking. In the first PR, keep implementations thin and Zig 0.15.2-compatible, with comments documenting the planned Zig 0.16 mapping. Add the module to `zig/build.zig` imports and expose only stable helper functions/types needed by follow-up PRs.

Suggested scope for one PR:
- Add the compatibility module and build wiring.
- Add smoke tests for helper construction and no-op/basic behavior.
- Do not migrate all call sites yet.

Depends on: none.

#### Work item 2 — Add time and sleep wrappers on 0.15.2

Priority: **high**

Introduce project helpers for `nowMillis`, `nowSeconds`, `nowNanos`/monotonic time, and `sleepNs` backed by current `std.time` and `std.Thread.sleep` APIs. Update a narrow set of central call sites, such as retry utilities and protocol timestamps, to validate ergonomics without destabilizing the full tree. These wrappers become the single place to remap `std.time.timestamp`, `milliTimestamp`, `nanoTimestamp`, and `Io.Clock` behavior after the compiler switch.

Suggested scope for one PR:
- Implement wrappers and tests on Zig 0.15.2.
- Migrate representative low-risk call sites only.
- Record remaining direct timestamp/sleep call sites for later PRs.

Depends on: work item 1.

#### Work item 3 — Add random/secure-random wrappers on 0.15.2

Priority: **high**

Create random helpers that distinguish security-sensitive randomness from ordinary IDs. Use them for PKCE verifiers, OAuth state, WebSocket nonce/masks, protocol IDs, and storage temporary-name generation in follow-up PRs. In Phase 0, implement wrappers using `std.crypto.random` and add deterministic test seams where possible.

Suggested scope for one PR:
- Add `secureBytes`, `randomBytes`, and test/deterministic source helpers if needed.
- Add unit tests for length, non-empty generation, and deterministic test behavior.
- Migrate one low-risk ID generation path only if straightforward.

Depends on: work item 1.

#### Work item 4 — Add filesystem and stdio helper layer on 0.15.2

Priority: **high**

Add wrappers around cwd/open/read/write/atomic rename, stdin/stdout access, and file reader/writer operations used by OAuth storage, stdio transport, and CLI tooling. The wrapper should preserve current ownership and error behavior, especially around credential storage and atomic file replacement. Avoid changing provider behavior in this PR.

Suggested scope for one PR:
- Implement wrappers with 0.15.2 `std.fs`/`std.io` APIs.
- Add tests for read/write, missing file behavior, directory creation, and atomic replace semantics.
- Migrate OAuth storage only if the PR remains small; otherwise leave migration for work item 14.

Depends on: work item 1.

#### Work item 5 — Add HTTP client/request abstraction on 0.15.2

Priority: **high**

Define a thin project abstraction for provider/OAuth HTTP client creation and response-body streaming. It should hide the future Zig 0.16 `std.http.Client{ .io = ... }` construction and request/send/receive API differences while preserving streaming SSE behavior. Start with one provider or test double so the abstraction shape is proven before all providers move.

Suggested scope for one PR:
- Add HTTP abstraction interfaces/helpers backed by current `std.http.Client`.
- Add tests with local/mock response behavior where feasible.
- Migrate at most one low-risk HTTP consumer to validate the shape.

Depends on: work item 1.

#### Work item 6 — Add networking helper layer on 0.15.2

Priority: **normal**

Create wrappers for TCP connect, address resolution, listen/accept, and stream read/write paths used by WebSocket transport and OAuth callback server. Keep the 0.15.2 implementation backed by `std.net`. This sets up a contained Zig 0.16 migration to `std.Io.net` later.

Suggested scope for one PR:
- Add connect/listen/stream wrapper types or helper functions.
- Add loopback tests where possible without external services.
- Avoid a full WebSocket/callback-server migration until after wrappers are reviewed.

Depends on: work item 1.

#### Work item 7 — Add focused regression tests for concurrency, parsing, protocol, and storage

Priority: **high**

Strengthen tests before changing core behavior. Add or expand tests for `EventStream.wait`, `pollBatch`, completion and error paths, OAuth refresh lock coordination, OAuth storage atomic writes, WebSocket frame parsing/masking, provider SSE parsing, and protocol envelope JSON round trips. These tests should run under Zig 0.15.2 and become the safety net for post-switch changes.

Suggested scope for one PR:
- Add focused unit tests only; avoid production behavior changes except test-only helpers.
- Keep tests in the existing grouped test structure.
- Do not add external provider E2E coverage.

Depends on: none; can run in parallel with wrapper tasks.

### Phase 1 — Dependency and compiler switch

Purpose: move the branch to Zig 0.16.0 and establish the new baseline. This is the critical sync point; no further work should assume Zig 0.15.2 compatibility after it lands.

#### Work item 8 — Switch CI/build metadata to Zig 0.16.0 and verify libxev

Priority: **urgent**

Update `zig/build.zig.zon` `.version` to `0.16.0`, select and pin a libxev commit/release that builds with Zig 0.16.0, refresh the dependency hash, and update CI setup-zig versions. Run the smallest build/test steps needed to prove dependency resolution and capture first-pass compile failures. This PR is expected to require minimal source fixes only when necessary to keep the tree buildable enough for downstream migration PRs.

Suggested scope for one PR:
- Update `build.zig.zon`, CI Zig versions, and any docs/scripts that hard-code 0.15.2.
- Verify libxev with Zig 0.16.0 and record the chosen pin rationale.
- Commit a compile-error inventory if not everything is fixed in the same PR.

Depends on: work items 1-7, or an explicit decision to skip incomplete Phase 0 coverage.

### Phase 2 — Core/std migration on Zig 0.16.0

Purpose: resolve compiler errors and behavior changes in core shared code before provider and transport work.

#### Work item 9 — Migrate `std.mem.indexOf*` call sites to `std.mem.find*`

Priority: **high**

Replace `std.mem.indexOf`, `indexOfScalar`, `indexOfAny`, and `indexOfPos` usages with the correct Zig 0.16 `std.mem.find*` family. This is high-volume but mostly mechanical and should happen before deeper I/O work so mechanical errors do not obscure complex failures. Verify exact scalar, positional, and any/none replacement names against Zig 0.16.0.

Suggested scope for one PR:
- Migrate all production and test call sites in `zig/**/*.zig`.
- Run relevant grouped unit tests once compilation reaches those modules.
- Avoid unrelated `ArrayList` or I/O changes.

Depends on: work item 8.

#### Work item 10 — Migrate `EventStream` and synchronization primitives

Priority: **high**

Port `std.Thread.Futex`, `Mutex`, `Condition`, and `ResetEvent` usage to Zig 0.16-compatible `std.Io.*` primitives or equivalent constructs. Start with `EventStream` because it is central to provider streaming and protocol clients, then update agent/auth refresh synchronization. Use the Phase 0 regression tests to validate wait, timeout, wake, completion, and error behavior.

Suggested scope for one PR:
- Migrate `zig/src/event_stream.zig`, `zig/src/stream.zig`, `zig/src/agent/agent.zig`, `zig/src/protocol/auth/server.zig`, and `zig/src/utils/oauth/refresh_lock.zig` if tightly coupled.
- Run `zig build test-unit-core`, auth/protocol-related tests, and any new stress tests.
- Document any semantic differences in timeout or wake behavior.

Depends on: work items 7 and 8.

#### Work item 11 — Migrate time, sleep, and timestamp call sites through wrappers

Priority: **high**

Convert remaining direct `std.time.timestamp`, `milliTimestamp`, `nanoTimestamp`, and `std.Thread.sleep` call sites to the project wrapper API. Remap wrapper implementations to Zig 0.16 `std.Io.Timestamp`, `Io.Clock`, `Duration`, and timeout facilities as appropriate. Preserve wall-clock vs monotonic-time semantics explicitly.

Suggested scope for one PR:
- Update wrapper implementation for Zig 0.16.
- Migrate all remaining production call sites and tests.
- Run core, protocol, provider, utils, and agent unit groups as applicable.

Depends on: work items 2 and 8; may depend on work item 10 if wrappers use migrated sync primitives.

#### Work item 12 — Migrate random and protocol/OAuth ID generation

Priority: **high**

Update random wrappers to use Zig 0.16 `io.random`, `io.randomSecure`, or `std.Random.IoSource` as appropriate. Migrate PKCE, OAuth state, WebSocket masks/nonces, protocol ID generation, and storage temporary names through these wrappers. Treat OAuth and security-sensitive call sites as requiring explicit secure entropy.

Suggested scope for one PR:
- Update wrapper implementation for Zig 0.16.
- Migrate all `std.crypto.random` call sites identified in the assessment.
- Add or update tests to distinguish deterministic test mode from secure production mode.

Depends on: work items 3 and 8.

#### Work item 13 — Migrate ArrayList, formatting, custom JSON writer, and std.json drift

Priority: **high**

Fix container and writer-related compile errors after the compiler switch. Verify whether Makai's `std.ArrayList` patterns still compile or need unmanaged-style allocator parameters, then migrate affected call sites consistently. Port `std.fmt.format` usage in the custom JSON writer and protocol envelope code to Zig 0.16 writer/print APIs, and fix any `std.json` parse/stringify drift.

Suggested scope for one PR:
- Convert only compile-confirmed ArrayList breakages; avoid speculative churn.
- Update `zig/src/json/writer.zig`, `zig/src/utils/streaming_json.zig`, and related envelope/provider request code.
- Run protocol/provider/utils unit groups to cover serialization.

Depends on: work item 8; can run after or in parallel with work item 9 if merge conflicts are managed.

### Phase 3 — I/O stack migration on Zig 0.16.0

Purpose: migrate filesystem, stdio, HTTP, and networking consumers once core helpers are ready.

#### Work item 14 — Migrate filesystem, stdio transport, OAuth storage, and CLI file I/O

Priority: **high**

Port filesystem and stdio helpers to Zig 0.16 `std.Io.Dir`, `std.Io.File`, and writer/reader APIs, then migrate OAuth storage, stdio transport, and CLI file operations. Preserve atomic credential-file replacement behavior and current error handling. Keep user-data safety as the review focus.

Suggested scope for one PR:
- Update wrappers and migrate `zig/src/utils/oauth/storage.zig`, `zig/src/transports/stdio.zig`, and targeted CLI file I/O.
- Run utils, transport, and CLI-related tests.
- Include manual notes for credential storage rollback/backup behavior if relevant.

Depends on: work items 4, 8, 11, and 13.

#### Work item 15 — Migrate provider HTTP streaming implementations

Priority: **urgent**

Port all provider streaming implementations from the old `std.http.Client` construction/response reader flow to Zig 0.16's `std.Io`-aware HTTP request flow. Maintain incremental SSE parsing and cancellation semantics. Providers include Anthropic, OpenAI Completions, OpenAI Responses, Azure OpenAI Responses, Google Generative, Google Vertex, and Ollama.

Suggested scope for one PR, or split by provider family if too large:
- Update shared HTTP abstraction for Zig 0.16.
- Migrate provider files in cohesive groups.
- Run provider unit tests and mock/non-secret tests; do not require external provider E2E.

Depends on: work items 5, 8, 11, 12, and 13.

#### Work item 16 — Migrate OAuth HTTP flows and callback networking

Priority: **high**

Port OAuth HTTP clients and callback-server networking to Zig 0.16 `std.Io` APIs. Cover GitHub Copilot, Anthropic, Google, and OpenAI Codex OAuth paths, including response-body reading limits and secure state/PKCE generation. Preserve auth-boundary guidance: provider/OAuth layers own credentials; agent logic remains auth-agnostic.

Suggested scope for one PR:
- Migrate OAuth HTTP helpers and callback server.
- Run utils/auth/OAuth tests and mock callback-server tests.
- Avoid external login E2E unless explicitly configured.

Depends on: work items 5, 6, 12, and 14; may run partly in parallel with work item 15 if shared HTTP abstractions are stable.

#### Work item 17 — Migrate WebSocket transport networking

Priority: **normal**

Port WebSocket connection setup, stream read/write, nonce/mask generation, and network error handling to Zig 0.16 networking APIs. Preserve frame parsing behavior and existing transport interfaces. Validate with loopback or mock tests rather than external endpoints.

Suggested scope for one PR:
- Migrate `zig/src/transports/websocket.zig` through networking/random wrappers.
- Run transport unit tests and WebSocket-specific regression tests.
- Document any unsupported `std.Io` backend/networking caveats.

Depends on: work items 6, 12, and 14.

### Phase 4 — Validation and stabilization

Purpose: prove Zig 0.16 parity and prepare the migration series for merge.

#### Work item 18 — Full unit and mock E2E validation on Zig 0.16.0

Priority: **urgent**

Run and stabilize all grouped unit tests plus mock-based protocol E2E tests on Zig 0.16.0. Per standing instruction, do not add or require external provider E2E testing in this phase. Capture CI status, fix flakes, and update any CI timeouts only with evidence.

Suggested scope for one PR:
- Run `zig build test-unit-core`, `test-unit-transport`, `test-unit-protocol`, `test-unit-providers`, `test-unit-utils`, `test-unit-agent`, and current split agent groups if CI still uses them.
- Run `zig build test-e2e-protocol`.
- Fix only validation failures and test harness drift.

Depends on: work items 9-17.

#### Work item 19 — Documentation, migration notes, and cleanup

Priority: **normal**

Update developer documentation, build instructions, CI comments, and migration notes to reflect Zig 0.16.0. Remove transitional TODOs or dead compatibility paths that are no longer needed after the switch. Keep any deliberate wrappers that provide ongoing abstraction value.

Suggested scope for one PR:
- Update `CLAUDE.md`, README/build docs if present, and relevant internal docs.
- Remove obsolete 0.15.2-only comments or code paths.
- Confirm pattern guardrails and docs references are current.

Depends on: work item 18.

## Dependency graph

- Work item 1 is the base for wrapper work items 2-6.
- Work item 7 can run in parallel with work items 1-6.
- Work item 8 depends on completion of work items 1-7 unless the team explicitly accepts reduced pre-switch coverage.
- Work item 9 depends on work item 8.
- Work item 10 depends on work items 7 and 8.
- Work item 11 depends on work items 2 and 8, and may depend on work item 10.
- Work item 12 depends on work items 3 and 8.
- Work item 13 depends on work item 8, and can run after or in parallel with work item 9 with conflict coordination.
- Work item 14 depends on work items 4, 8, 11, and 13.
- Work item 15 depends on work items 5, 8, 11, 12, and 13.
- Work item 16 depends on work items 5, 6, 12, and 14.
- Work item 17 depends on work items 6, 12, and 14.
- Work item 18 depends on work items 9-17.
- Work item 19 depends on work item 18.

## Risk mitigations

1. **Compile error inventory after Phase 1.**  
   Capture first-pass Zig 0.16 compile failures and use them to validate or adjust the planned task boundaries before assigning later PRs.

2. **Regression tests before semantic rewrites.**  
   EventStream synchronization, OAuth storage, HTTP streaming, SSE parsing, protocol envelopes, and WebSocket framing should have tests in place before their migration PRs.

3. **Security-sensitive randomness review.**  
   Treat OAuth PKCE/state, WebSocket masks/nonces, and protocol IDs as explicit review points. Do not silently downgrade secure entropy to deterministic or weak randomness.

4. **Keep libxev independent of initial `std.Io` decisions.**  
   Verify libxev builds with Zig 0.16.0, but do not block the initial migration on libxev implementing `std.Io`.

5. **Provider migration by shared abstraction.**  
   Migrate providers through a shared HTTP abstraction to prevent seven separate ad hoc request-flow implementations.

6. **No external E2E requirement for migration validation.**  
   Use grouped unit tests and mock E2E protocol tests as the acceptance gate. External provider E2E remains out of scope unless separately requested.

7. **Minimize public API churn.**  
   Prefer context/default-I/O ownership patterns over forcing every caller to pass `std.Io` unless compiler or architecture constraints require it.

## Rollback strategy

- **Before Phase 1:** each Phase 0 PR is independently revertible because it should compile on Zig 0.15.2 and preserve behavior through thin wrappers/tests.
- **At Phase 1:** if libxev or the compiler switch blocks progress, revert the compiler/dependency PR and continue improving Phase 0 wrappers/tests on 0.15.2.
- **After Phase 1:** rollback should revert to the last green Zig 0.16 migration PR rather than partially restoring Zig 0.15.2 APIs. Keep each post-switch PR narrow enough to revert independently.
- **For user-data paths:** OAuth storage migration PRs must preserve existing files and atomic write behavior. If a regression is found, revert the storage migration PR and keep the wrapper interface stable while fixing implementation details.
- **For provider regressions:** provider HTTP migration can be split by provider family if needed; revert only the affected provider family PR while preserving shared abstraction fixes.

## Out of scope

- Full evented-I/O redesign of Makai's public APIs.
- Implementing or maintaining a libxev-to-`std.Io` adapter.
- Waiting for libxev issue #219 before starting the compiler migration.
- Adding new providers, transports, OAuth providers, or agent features.
- External provider E2E stabilization or new secret-dependent tests.
- Broad performance optimization beyond preserving current behavior and avoiding obvious regressions.
- Changes to GitHub repository rules, admin bypass, or direct changes to the local root repo outside required sync operations.

## Open questions

1. Which Zig 0.16 `std.Io` backend should be the default for CLI, tests, providers, and networking-heavy flows?
2. Should public provider/agent APIs accept explicit `std.Io`, or should Makai introduce a context object that owns the default I/O instance?
3. Should `EventStream` remain futex/atomic-based using `std.Io.Futex`, or should it be redesigned around higher-level `std.Io` primitives after parity is achieved?
4. Which libxev commit/release should be pinned for Zig 0.16.0, and what evidence is sufficient to accept it?
5. Are downstream users relying on Zig 0.15.2 source compatibility after the compiler switch, or can public API signatures change with a migration note?
6. Does Zig 0.16.0 preserve `std.time.milliTimestamp`/`nanoTimestamp`, or should all usage move immediately to wrapper implementations backed by `std.Io.Timestamp`/`Io.Clock`?
7. Should provider HTTP migration be one PR for all providers or split by provider family after the shared abstraction lands?
