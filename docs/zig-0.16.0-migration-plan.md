# Zig 0.15.2 → 0.16.0 Migration Plan

Date: 2026-05-07  
Source research: [`docs/zig-0.16.0-upgrade-impact-assessment.md`](./zig-0.16.0-upgrade-impact-assessment.md)  
Target: Makai `zig/` codebase and CI, migrating from Zig 0.15.2 to Zig 0.16.0

## Goal summary

Migrate Makai from Zig 0.15.2 to Zig 0.16.0 while preserving current provider, protocol, transport, OAuth, agent-loop, and CLI behavior. The migration should be delivered as a staged sequence of reviewable PRs: first make a prerequisite I/O architecture decision, then add compatibility seams and focused regression tests that still compile on 0.15.2, then land a first green compiler/dependency baseline, then complete the core/std, I/O, provider/OAuth, transport, and validation work on 0.16.0. The initial objective is compile/test parity and controlled architectural churn, not a full redesign around evented I/O or a libxev-backed `std.Io` adapter.

## Design decisions and rationale

1. **Make the `std.Io` backend and ownership model an explicit prerequisite.**  
   The wrapper APIs cannot be designed responsibly while the default backend and I/O lifecycle ownership are unresolved. The binding default for dispatch is: Phase 0 wrappers MUST NOT expose `std.Io` in public API signatures; public constructors and entry points should use Makai-owned context/default-I/O patterns, while internal helpers may accept explicit I/O handles where needed. Work item 1 must document where CLI, tests, providers, OAuth flows, and transports obtain their I/O handles within that default.

2. **Use a staged migration instead of one large rewrite.**  
   The impact assessment identifies high-volume mechanical changes and high-risk I/O/concurrency changes. Splitting architecture, wrapper/test preparation, compiler switch, and subsystem migration keeps PRs reviewable and prevents unrelated concerns from being coupled.

3. **Make Phase 1 a first green Zig 0.16 baseline PR.**  
   This plan chooses a mergeable baseline PR with minimum compile-restoring fixes over an unmerged integration checkpoint with stacked red PRs. The Phase 1 PR should update toolchain/dependency metadata, verify libxev, and apply only the minimum source changes needed to produce an agreed green Zig 0.16 build/test subset; remaining issues become follow-up tasks.

4. **Prefer project-level compatibility seams over ad hoc call-site rewrites.**  
   Introduce central wrappers for time, sleep, random, filesystem/stdio, HTTP client construction/request flows, and networking. The wrappers should reflect the prerequisite architecture decision and avoid duplicating 0.16-specific decisions across providers, OAuth flows, transports, and CLI code.

5. **Use the simplest supported `std.Io` backend for initial parity.**  
   Do not depend on libxev implementing `std.Io`; the research notes that upstream libxev issue #219 is still open. The initial migration should choose a standard Zig 0.16 backend with networking support, then defer evented/libxev integration to a later project.

6. **Preserve public behavior before redesigning APIs.**  
   Public API churn should be limited to what the architecture decision and compiler require. The migration does not need to preserve Zig 0.15.2 source compatibility after Phase 1, but it must preserve documented Makai behavior where possible and provide migration notes for any public API signature changes. Where API changes are unavoidable, isolate them behind constructors/context objects and document them in the relevant implementation PR.

7. **Treat provider HTTP streaming and core stream synchronization as separate high-risk tracks.**  
   Provider/OAuth HTTP request flow changes and futex/mutex/condition migration can introduce subtle runtime failures even after compilation succeeds. Core `EventStream`/`stream` synchronization, auth/OAuth synchronization, shared HTTP abstraction, and provider-family rollout should each be reviewed in separate PRs.

## Phased PR sequence

### Phase -1 — Architecture prerequisite

Purpose: decide the foundational `std.Io` backend, ownership, and API model before wrappers encode accidental architecture.

#### Work item 1 — Decide Zig 0.16 I/O architecture and ownership model

Priority: **urgent**

Make the default `std.Io` backend and lifecycle ownership model an up-front architecture decision. Use the binding default that Phase 0 wrappers MUST NOT expose `std.Io` in public API signatures; public constructors use Makai-owned context/default-I/O patterns, while internal helpers may accept explicit I/O handles when the implementation requires them. Document where the default I/O instance is created for CLI runs, tests, providers, OAuth flows, transports, and protocol/agent runtime paths.

Suggested scope for one PR:
- Add an architecture note or design section that records the backend, ownership, and context/default-I/O decision and rationale.
- Identify public API signatures expected to change, stay stable, or receive transitional overloads; do not promise Zig 0.15.2 source compatibility after Phase 1.
- Define wrapper naming conventions and parameter order, including allocator/context first, explicit internal I/O handle second when present, then operation-specific parameters, to reduce review friction on dependent PRs.
- Confirm the selected backend supports the networking paths needed for HTTP providers, OAuth callback server, and WebSocket transport.

Depends on: none.

### Phase 0 — Preparation wrappers and regression tests on Zig 0.15.2

Purpose: create compatibility seams and tests while the codebase still builds on the current toolchain. Phase 0 tasks can be done in parallel after work item 1 where they touch separate layers.

#### Work item 2 — Add I/O compatibility design skeleton

Priority: **high**

Create a small `zig/src/utils` or `zig/src/compat` module that defines the intended wrapper boundaries for time, sleep, random, filesystem/stdio, HTTP, and networking. In the first PR, keep implementations thin and Zig 0.15.2-compatible, with comments documenting the planned Zig 0.16 mapping based on work item 1. Add the module to `zig/build.zig` imports and expose only stable helper functions/types needed by follow-up PRs.

Suggested scope for one PR:
- Add the compatibility module and build wiring.
- Add smoke tests for helper construction and no-op/basic behavior.
- Do not migrate all call sites yet.

Depends on: work item 1.

#### Work item 3 — Add time and sleep wrappers on 0.15.2

Priority: **high**

Introduce project helpers for `nowMillis`, `nowSeconds`, `nowNanos`/monotonic time, and `sleepNs` backed by current `std.time` and `std.Thread.sleep` APIs. Update a narrow set of central call sites, such as retry utilities and protocol timestamps, to validate ergonomics without destabilizing the full tree. These wrappers become the single place to remap `std.time.timestamp`, `milliTimestamp`, `nanoTimestamp`, and `Io.Clock` behavior after the compiler switch.

Suggested scope for one PR:
- Implement wrappers and tests on Zig 0.15.2.
- Migrate representative low-risk call sites only.
- Record remaining direct timestamp/sleep call sites for later PRs.

Depends on: work item 2.

#### Work item 4 — Add random/secure-random wrappers on 0.15.2

Priority: **high**

Create random helpers that distinguish security-sensitive randomness from ordinary IDs. Use them for PKCE verifiers, OAuth state, WebSocket nonce/masks, protocol IDs, and storage temporary-name generation in follow-up PRs. In Phase 0, implement wrappers using `std.crypto.random` and add deterministic test seams where possible.

Suggested scope for one PR:
- Add `secureBytes`, `randomBytes`, and test/deterministic source helpers if needed.
- Add unit tests for length, non-empty generation, and deterministic test behavior.
- Migrate one low-risk ID generation path only if straightforward.

Depends on: work item 2.

#### Work item 5 — Add filesystem and stdio helper layer on 0.15.2

Priority: **high**

Add wrappers around cwd/open/read/write/atomic rename, stdin/stdout access, and file reader/writer operations used by OAuth storage, stdio transport, and CLI tooling. The wrapper should preserve current ownership and error behavior while keeping OAuth storage migration separate from stdio/CLI migration later. Avoid changing provider behavior in this PR.

Suggested scope for one PR:
- Implement wrappers with 0.15.2 `std.fs`/`std.io` APIs.
- Add tests for read/write, missing file behavior, directory creation, and atomic replace semantics.
- Do not migrate OAuth storage, stdio transport, and CLI file I/O together; leave those for separate post-switch PRs.

Depends on: work item 2.

#### Work item 6 — Add HTTP client/request abstraction on 0.15.2

Priority: **high**

Define a thin project abstraction for provider/OAuth HTTP client creation and response-body streaming. It should hide the future Zig 0.16 `std.http.Client{ .io = ... }` construction and request/send/receive API differences while preserving streaming SSE behavior. Start with a test double or mock consumer; production provider rollout is explicitly split after the Zig 0.16 abstraction is proven.

Suggested scope for one PR:
- Add HTTP abstraction interfaces/helpers backed by current `std.http.Client`.
- Add tests with local/mock response behavior where feasible.
- Avoid migrating all providers in this preparatory PR.

Depends on: work item 2.

#### Work item 7 — Add networking helper layer on 0.15.2

Priority: **normal**

Create wrappers for TCP connect, address resolution, listen/accept, and stream read/write paths used by WebSocket transport and OAuth callback server. Keep the 0.15.2 implementation backed by `std.net`. This sets up contained Zig 0.16 migrations for WebSocket and OAuth callback networking without coupling either to filesystem/stdin/stdout work.

Suggested scope for one PR:
- Add connect/listen/stream wrapper types or helper functions.
- Add loopback tests where possible without external services.
- Avoid full WebSocket/callback-server migration until after wrappers are reviewed.

Depends on: work item 2.

#### Work item 8 — Add focused regression tests for concurrency, parsing, protocol, and storage

Priority: **high**

Strengthen tests before changing core behavior. Add or expand tests for `EventStream.wait`, `pollBatch`, completion and error paths, OAuth refresh lock coordination, OAuth storage atomic writes, WebSocket frame parsing/masking, provider SSE parsing, and protocol envelope JSON round trips. These tests should run under Zig 0.15.2 and become the safety net for post-switch changes.

Suggested scope for one PR:
- Add focused unit tests only; avoid production behavior changes except test-only helpers.
- Keep tests in the existing grouped test structure.
- Do not add external provider E2E coverage.

Depends on: work item 1; can run in parallel with wrapper tasks.

### Phase 1 — Dependency and compiler switch

Purpose: move the branch to Zig 0.16.0 with a mergeable green baseline. After this PR lands, no further work should assume Zig 0.15.2 compatibility.

Branch strategy: Phase 0 PRs may land directly on `main` while `main` still targets Zig 0.15.2. Phase 1 should be a normal PR to `main` that switches `main` to Zig 0.16.0 with the agreed green baseline. After Phase 1 merges, follow-up migration PRs are short-lived branches targeting `main`; avoid a long-lived feature branch unless Phase 1 is explicitly re-planned as a red integration checkpoint.

#### Work item 9 — Switch to a first green Zig 0.16 baseline PR

Priority: **urgent**

Update `zig/build.zig.zon` `.version` to `0.16.0`, select and pin a libxev commit/release that builds with Zig 0.16.0, refresh the dependency hash, and update CI setup-zig versions. Apply only minimum compile-restoring source fixes needed for the agreed baseline test subset to pass; do not use an unmerged red integration branch as the normal path. Capture the remaining compile/test inventory and assign it to follow-up tasks.

Suggested scope for one PR:
- Update `build.zig.zon`, CI Zig versions, and any docs/scripts that hard-code 0.15.2.
- Verify libxev with Zig 0.16.0 and record the chosen pin rationale.
- Apply minimal fixes needed for a green baseline, such as build metadata/API adjustments that unblock the build graph.
- Document the exact baseline command set that passed.

Depends on: work items 1-8, or an explicit decision to accept reduced pre-switch coverage.

### Phase 2 — Core/std migration on Zig 0.16.0

Purpose: resolve compiler errors and behavior changes in core shared code before provider and transport rollout.

#### Work item 10 — Migrate `std.mem.indexOf*` call sites to `std.mem.find*`

Priority: **high**

Replace `std.mem.indexOf`, `indexOfScalar`, `indexOfAny`, and `indexOfPos` usages with the correct Zig 0.16 `std.mem.find*` family. This is high-volume but mostly mechanical and should happen before deeper I/O work so mechanical errors do not obscure complex failures. Verify exact scalar, positional, and any/none replacement names against Zig 0.16.0.

Suggested scope for one PR:
- Migrate all production and test call sites in `zig/**/*.zig`.
- Run relevant grouped unit tests once compilation reaches those modules.
- Avoid unrelated `ArrayList` or I/O changes.

Depends on: work item 9.

#### Work item 11 — Migrate core EventStream and stream synchronization

Priority: **high**

Port synchronization in `zig/src/event_stream.zig` and `zig/src/stream.zig` from `std.Thread.Futex` and related primitives to Zig 0.16-compatible `std.Io.*` primitives or equivalent constructs. Keep this PR focused on central streaming semantics only, because `EventStream` is shared by providers, protocol clients, and agent paths. Use the Phase 0 regression tests to validate wait, timeout, wake, completion, polling, and error behavior.

Suggested scope for one PR:
- Migrate `zig/src/event_stream.zig` and `zig/src/stream.zig`.
- Run `zig build test-unit-core` and any new stream stress tests.
- Preserve existing error messages and error types for stream completion/error paths unless a compiler-enforced change is documented.
- Document semantic differences in timeout or wake behavior.

Depends on: work items 8 and 9.

#### Work item 12 — Migrate agent/auth/OAuth synchronization

Priority: **high**

Port synchronization in `zig/src/agent/agent.zig`, `zig/src/protocol/auth/server.zig`, and `zig/src/utils/oauth/refresh_lock.zig` separately from core EventStream work. This isolates auth/agent coordination review from lock-free stream review. Validate refresh coordination, auth protocol locking, and agent event completion behavior.

Suggested scope for one PR:
- Migrate agent reset events and auth/OAuth mutex/condition usage.
- Run relevant agent, protocol/auth, and utils tests.
- Confirm no provider auth logic leaks into the auth-agnostic agent layer.

Depends on: work items 8, 9, and 11.

#### Work item 13 — Migrate time, sleep, and timestamp call sites through wrappers

Priority: **high**

Convert remaining direct `std.time.timestamp`, `milliTimestamp`, `nanoTimestamp`, and `std.Thread.sleep` call sites to the project wrapper API. Remap wrapper implementations to Zig 0.16 `std.Io.Timestamp`, `Io.Clock`, `Duration`, and timeout facilities as appropriate. Preserve wall-clock vs monotonic-time semantics explicitly.

Suggested scope for one PR:
- Update wrapper implementation for Zig 0.16.
- Migrate all remaining production call sites and tests.
- Run core, protocol, provider, utils, and agent unit groups as applicable.

Depends on: work items 3 and 9; may depend on work item 11 if wrappers use migrated stream timing primitives.

#### Work item 14 — Migrate random and protocol/OAuth ID generation

Priority: **high**

Update random wrappers to use Zig 0.16 `io.random`, `io.randomSecure`, or `std.Random.IoSource` as appropriate. Migrate PKCE, OAuth state, WebSocket masks/nonces, protocol ID generation, and storage temporary names through these wrappers. Treat OAuth and security-sensitive call sites as requiring explicit secure entropy.

Suggested scope for one PR:
- Update wrapper implementation for Zig 0.16.
- Migrate all `std.crypto.random` call sites identified in the assessment.
- Add or update tests to distinguish deterministic test mode from secure production mode.

Depends on: work items 4 and 9.

#### Work item 15 — Migrate ArrayList, formatting, custom JSON writer, and std.json drift

Priority: **high**

Fix container and writer-related compile errors after the compiler switch. Verify whether Makai's `std.ArrayList` patterns still compile or need unmanaged-style allocator parameters, then migrate affected call sites consistently. Port `std.fmt.format` usage in the custom JSON writer and protocol envelope code to Zig 0.16 writer/print APIs, and fix any `std.json` parse/stringify drift.

Suggested scope for one PR:
- Convert only compile-confirmed ArrayList breakages; avoid speculative churn.
- Update `zig/src/json/writer.zig`, `zig/src/utils/streaming_json.zig`, and related envelope/provider request code.
- Run protocol/provider/utils unit groups to cover serialization.

Depends on: work item 9; can run after or in parallel with work item 10 if merge conflicts are managed.

### Phase 3 — I/O stack migration on Zig 0.16.0

Purpose: migrate filesystem, stdio, HTTP, and networking consumers through the reviewed wrappers and architecture model.

#### Work item 16 — Migrate OAuth credential storage filesystem operations

Priority: **high**

Port OAuth credential storage to Zig 0.16 filesystem helpers as a standalone user-data-focused PR. Preserve atomic credential-file replacement behavior, directory creation, missing-file handling, permission expectations, and current error behavior. Keep stdio transport and CLI file I/O out of this PR so user-data safety receives focused review.

Suggested scope for one PR:
- Migrate `zig/src/utils/oauth/storage.zig` through filesystem helpers.
- Run OAuth storage and utils tests.
- Preserve existing storage error messages and error types unless a compiler-enforced change is documented.
- Include manual notes for credential storage rollback/backup behavior if relevant.

Depends on: work items 5, 9, 13, 14, and 15.

#### Work item 17 — Migrate stdio transport and CLI file I/O

Priority: **high**

Port stdio transport and CLI file operations to Zig 0.16 filesystem/stdio helpers separately from OAuth credential storage. This keeps transport/CLI review focused on byte I/O and user interaction rather than credential safety. Preserve current stdin/stdout semantics and CLI harness behavior.

Suggested scope for one PR:
- Migrate `zig/src/transports/stdio.zig` and targeted `zig/src/tools/makai.zig` file/stdio call sites.
- Run transport and CLI-related tests.
- Validate CLI output formatting, exit codes, and auth-flow prompts remain unchanged except where explicitly documented.
- Avoid changes to OAuth storage.

Depends on: work items 5, 9, 13, and 15.

#### Work item 18 — Migrate shared HTTP abstraction and one proving provider

Priority: **urgent**

Port the shared HTTP abstraction to Zig 0.16's `std.Io`-aware HTTP request/response flow and migrate exactly one representative streaming provider as a proving provider. The proving provider should exercise request bodies, response head handling, incremental body reads, SSE parsing, cancellation, and provider error-body handling. Do not migrate all provider families until this PR establishes the abstraction shape.

Suggested scope for one PR:
- Update shared HTTP abstraction for Zig 0.16.
- Migrate one representative provider, preferably one with SSE streaming and nontrivial request/error handling.
- Run provider unit tests and mock/non-secret tests for that provider.
- Preserve existing provider error messages and error types unless a compiler-enforced change is documented.

Depends on: work items 6, 9, 13, 14, and 15.

#### Work item 19 — Migrate remaining OpenAI/Azure provider HTTP implementations

Priority: **high**

Migrate OpenAI Completions, OpenAI Responses, and Azure OpenAI Responses providers through the proven shared HTTP abstraction. Keep request JSON and response parsing changes limited to what Zig 0.16 requires. Preserve cancellation, usage accounting, tool-call delta handling, and error-body handling.

Suggested scope for one PR:
- Migrate OpenAI and Azure provider HTTP call sites.
- Run provider unit tests and mock/non-secret tests.
- Avoid changing Anthropic/Google/Ollama in the same PR unless required by shared test fixtures.

Depends on: work item 18.

#### Work item 20 — Migrate remaining Anthropic/Google/Ollama provider HTTP implementations

Priority: **high**

Migrate Anthropic Messages, Google Generative, Google Vertex, and Ollama providers through the proven shared HTTP abstraction. Preserve streaming, SSE parsing, cancellation, extended thinking blocks, provider-specific request options, and provider-specific error handling. Keep this separate from the OpenAI/Azure migration to keep provider-family review manageable.

Suggested scope for one PR:
- Migrate Anthropic, Google, and Ollama provider HTTP call sites.
- Run provider unit tests and mock/non-secret tests.
- Do not require external provider E2E.

Depends on: work item 18; can run in parallel with work item 19 if shared abstraction is stable.

#### Work item 21 — Migrate OAuth HTTP flows and callback networking

Priority: **high**

Port OAuth HTTP clients and callback-server networking to Zig 0.16 `std.Io` APIs. Cover GitHub Copilot, Anthropic, Google, and OpenAI Codex OAuth paths, including response-body reading limits and secure state/PKCE generation. Preserve auth-boundary guidance: provider/OAuth layers own credentials; agent logic remains auth-agnostic.

Suggested scope for one PR:
- Migrate OAuth HTTP helpers and callback server.
- Run utils/auth/OAuth tests and mock callback-server tests.
- Avoid external login E2E unless explicitly configured.

Depends on: work items 6, 7, 14, 16, and 18. It does not depend on stdio transport/CLI migration.

#### Work item 22 — Migrate WebSocket transport networking

Priority: **normal**

Port WebSocket connection setup, stream read/write, nonce/mask generation, and network error handling to Zig 0.16 networking APIs. Preserve frame parsing behavior and existing transport interfaces. Validate with loopback or mock tests rather than external endpoints.

Suggested scope for one PR:
- Migrate `zig/src/transports/websocket.zig` through networking/random wrappers.
- Run transport unit tests and WebSocket-specific regression tests.
- Document any unsupported `std.Io` backend/networking caveats.

Depends on: work items 7 and 14. It does not depend on filesystem/stdio/OAuth storage migration.

### Phase 4 — Validation and stabilization

Purpose: prove Zig 0.16 parity and prepare the migration series for merge.

#### Work item 23 — Full unit and mock E2E validation on Zig 0.16.0

Priority: **urgent**

Run and stabilize all grouped unit tests plus mock-based protocol E2E tests on Zig 0.16.0. Per standing instruction, do not add or require external provider E2E testing in this phase. Capture CI status, fix flakes, and update any CI timeouts only with evidence.

Suggested scope for one PR:
- Run `zig build test-unit-core`, `test-unit-transport`, `test-unit-protocol`, `test-unit-providers`, `test-unit-utils`, `test-unit-agent`, and current split agent groups if CI still uses them.
- Run `zig build test-e2e-protocol`.
- Validate CLI output formatting, exit codes, and auth-flow prompts remain unchanged after the full migration.
- Fix only validation failures and test harness drift.

Depends on: work items 10-22.

#### Work item 24 — Documentation, migration notes, and cleanup

Priority: **normal**

Update developer documentation, build instructions, CI comments, changelog/release notes, and downstream migration notes to reflect Zig 0.16.0. Remove transitional TODOs or dead compatibility paths that are no longer needed after the switch. Keep any deliberate wrappers that provide ongoing abstraction value.

Suggested scope for one PR:
- Update `CLAUDE.md`, including changing the build requirement from Zig 0.15.2 to Zig 0.16.0.
- Add a changelog or release-notes entry for the Zig version upgrade.
- Add a downstream migration guide for consumers depending on Makai public types and constructors.
- Update README/build docs if present and relevant internal docs.
- Remove obsolete 0.15.2-only comments or code paths.
- Confirm pattern guardrails and docs references are current.

Depends on: work item 23.

## Dependency graph

- Work item 1 is the prerequisite for work items 2-8.
- Work item 2 is the base for wrapper work items 3-7.
- Work item 8 can run in parallel with wrapper tasks after work item 1.
- Work item 9 depends on completion of work items 1-8 unless the team explicitly accepts reduced pre-switch coverage.
- Work item 10 depends on work item 9.
- Work item 11 depends on work items 8 and 9.
- Work item 12 depends on work items 8, 9, and 11.
- Work item 13 depends on work items 3 and 9, and may depend on work item 11 if wrapper tests require migrated stream timing semantics.
- Work item 14 depends on work items 4 and 9.
- Work item 15 depends on work item 9, and can run after or in parallel with work item 10 with conflict coordination.
- Work item 16 depends on work items 5, 9, 13, 14, and 15.
- Work item 17 depends on work items 5, 9, 13, and 15. It does not depend on work item 16.
- Work item 18 depends on work items 6, 9, 13, 14, and 15.
- Work item 19 depends on work item 18.
- Work item 20 depends on work item 18 and can run in parallel with work item 19 if shared helpers are stable.
- Work item 21 depends on work items 6, 7, 14, 16, and 18. It does not depend on work item 17.
- Work item 22 depends on work items 7 and 14. It does not depend on work items 16 or 17.
- Work item 23 depends on work items 10-22.
- Work item 24 depends on work item 23.

## Risk mitigations

1. **Architecture decision before wrappers.**  
   Default backend, I/O ownership, and context-vs-explicit-io decisions must be recorded first so wrapper PRs do not encode conflicting assumptions.

2. **First green baseline instead of red stacked migration.**  
   The Phase 1 compiler switch should be mergeable and green for an agreed baseline command set. If that proves impossible, explicitly revisit the strategy rather than silently creating a long-lived red integration branch.

3. **Compile error inventory after Phase 1.**  
   Capture first-pass Zig 0.16 compile failures and use them to validate or adjust later task boundaries before assigning subsystem PRs.

4. **Regression tests before semantic rewrites.**  
   EventStream synchronization, auth/OAuth locks, OAuth storage, HTTP streaming, SSE parsing, protocol envelopes, and WebSocket framing should have tests in place before their migration PRs.

5. **Security-sensitive randomness review.**  
   Treat OAuth PKCE/state, WebSocket masks/nonces, and protocol IDs as explicit review points. Do not silently downgrade secure entropy to deterministic or weak randomness.

6. **Keep libxev independent of initial `std.Io` decisions.**  
   Verify libxev builds with Zig 0.16.0, but do not block the initial migration on libxev implementing `std.Io`.

7. **Provider migration by proving provider and provider families.**  
   First port the shared HTTP abstraction and one proving provider, then migrate remaining provider families in separate PRs. This prevents seven independent ad hoc request-flow migrations and avoids one oversized provider PR.

8. **No external E2E requirement for migration validation.**  
   Use grouped unit tests and mock E2E protocol tests as the acceptance gate. External provider E2E remains out of scope unless separately requested.

9. **Minimize public API churn.**  
   Prefer the architecture-approved context/default-I/O ownership pattern over forcing every caller to pass `std.Io` unless compiler or design constraints require it.

## Rollback strategy

- **Before Phase 1:** each Phase 0 PR is independently revertible because it should compile on Zig 0.15.2 and preserve behavior through thin wrappers/tests.
- **At Phase 1:** if libxev or the compiler switch cannot produce the agreed first green baseline, revert the compiler/dependency PR and continue improving Phase 0 wrappers/tests on 0.15.2. Do not merge a red Zig 0.16 baseline without explicitly changing this plan.
- **After Phase 1:** rollback should revert to the last green Zig 0.16 migration PR rather than partially restoring Zig 0.15.2 APIs. Keep each post-switch PR narrow enough to revert independently.
- **For core stream synchronization:** if core `EventStream` semantics regress, revert work item 11 independently without reverting auth/OAuth synchronization work that has not yet landed.
- **For auth/OAuth synchronization:** if refresh coordination or auth locks regress, revert work item 12 independently from core stream synchronization.
- **For user-data paths:** OAuth storage migration is isolated in work item 16. If a regression is found, revert that PR and keep stdio/CLI migration separate.
- **For provider regressions:** the proving-provider PR can be reverted independently from later provider-family PRs. Later regressions should revert only the affected provider-family PR while preserving shared abstraction fixes where safe.

## Out of scope

- Full evented-I/O redesign of Makai's public APIs beyond the explicit architecture decision required for this migration.
- Preserving Zig 0.15.2 source compatibility after Phase 1; public API changes are allowed when documented in migration notes.
- Implementing or maintaining a libxev-to-`std.Io` adapter.
- Waiting for libxev issue #219 before starting the compiler migration.
- Adding new providers, transports, OAuth providers, or agent features.
- External provider E2E stabilization or new secret-dependent tests.
- Broad performance optimization beyond preserving current behavior and avoiding obvious regressions.
- Changes to GitHub repository rules, admin bypass, or direct changes to the local root repo outside required sync operations.

## Open questions

1. Which libxev commit/release should be pinned for Zig 0.16.0, and what evidence is sufficient to accept it?
2. Does Zig 0.16.0 preserve `std.time.milliTimestamp`/`nanoTimestamp`, or should all usage move immediately to wrapper implementations backed by `std.Io.Timestamp`/`Io.Clock`?
3. Which provider should be selected as the proving provider for the shared HTTP abstraction PR?
