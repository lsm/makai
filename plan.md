# Plan: Zig 0.15.2 → 0.16.0 Migration Decomposition

## Goal summary

Deliver a concrete, reviewable implementation plan for migrating Makai from Zig 0.15.2 to Zig 0.16.0 based on the approved impact assessment in `docs/zig-0.16.0-upgrade-impact-assessment.md`. The migration should proceed through preparation wrappers/tests on Zig 0.15.2, a compiler/dependency synchronization point, core/std fixes, I/O/provider/OAuth/transport migration, and final Zig 0.16 validation. The primary deliverable is `docs/zig-0.16.0-migration-plan.md`, which decomposes the work into single-PR implementation tasks with dependency ordering, risk mitigations, rollback strategy, and open questions.

## Work items

1. **Add I/O compatibility design skeleton**  
   Priority: **high**  
   Create the base compatibility module and build wiring for time, sleep, random, filesystem/stdio, HTTP, and networking seams. Keep it Zig 0.15.2-compatible and document how each seam should map to Zig 0.16 `std.Io`. This creates a shared foundation for parallel Phase 0 wrapper PRs.

2. **Add time and sleep wrappers on Zig 0.15.2**  
   Priority: **high**  
   Introduce helpers for wall-clock timestamps, monotonic time, and sleeping using the current `std.time` and `std.Thread.sleep` APIs. Migrate only representative low-risk call sites initially. These wrappers become the post-switch location for `std.Io.Timestamp`, `Io.Clock`, `Duration`, and timeout behavior.

3. **Add random and secure-random wrappers on Zig 0.15.2**  
   Priority: **high**  
   Add helpers that distinguish security-sensitive entropy from ordinary random bytes. The wrappers should support later migration of PKCE, OAuth state, WebSocket nonce/masks, protocol IDs, and storage temporary names. Include deterministic test seams where practical.

4. **Add filesystem and stdio helper layer on Zig 0.15.2**  
   Priority: **high**  
   Add wrappers around cwd/open/read/write/atomic rename, stdin/stdout, and file reader/writer operations. The initial implementation should use 0.15.2 `std.fs`/`std.io` while preserving existing OAuth credential-storage semantics. Include tests for read/write, missing files, directory creation, and atomic replacement.

5. **Add HTTP client/request abstraction on Zig 0.15.2**  
   Priority: **high**  
   Define a thin abstraction over provider/OAuth HTTP client creation, request sending, response body reading, and streaming. The goal is to hide Zig 0.16 `std.http.Client{ .io = ... }` and new request-flow changes behind one project API. Validate the shape with a test double or one low-risk HTTP consumer.

6. **Add networking helper layer on Zig 0.15.2**  
   Priority: **normal**  
   Create wrappers for TCP connect, address resolution, listen/accept, and stream read/write operations used by WebSocket transport and OAuth callback server. Keep the implementation backed by `std.net` until the compiler switch. Add loopback or unit tests that do not depend on external services.

7. **Add focused regression tests before semantic migration**  
   Priority: **high**  
   Expand tests for `EventStream` wait/poll/complete/error behavior, auth refresh locking, OAuth storage atomic writes, WebSocket frame parsing/masking, SSE parsing, and protocol envelope JSON. These tests should run on Zig 0.15.2 and become the safety net for post-switch changes. Avoid external provider E2E tests.

8. **Switch CI/build metadata to Zig 0.16.0 and verify libxev**  
   Priority: **urgent**  
   Update `zig/build.zig.zon`, select and hash a Zig 0.16-compatible libxev pin, and update CI Zig versions. Run initial Zig 0.16 build/test steps to prove dependency resolution and collect first-pass compile errors. This is the hard sync point after which remaining work targets Zig 0.16.0 only.

9. **Migrate `std.mem.indexOf*` call sites to `std.mem.find*`**  
   Priority: **high**  
   Replace all `std.mem.indexOf`, `indexOfScalar`, `indexOfAny`, and `indexOfPos` usages with the correct Zig 0.16 `find` family. This high-volume mechanical work should be isolated to reduce noise in deeper I/O PRs. Verify exact replacement names against Zig 0.16.0.

10. **Migrate `EventStream` and synchronization primitives**  
    Priority: **high**  
    Port `std.Thread.Futex`, `Mutex`, `Condition`, and `ResetEvent` usage to Zig 0.16-compatible `std.Io.*` primitives or suitable equivalents. Start with `EventStream`, then update agent/auth refresh synchronization. Use the regression tests from work item 7 to validate wake, timeout, completion, and error semantics.

11. **Migrate time, sleep, and timestamp call sites through wrappers**  
    Priority: **high**  
    Convert remaining direct timestamp and sleep calls to the project wrapper API. Update wrapper implementations to use the chosen Zig 0.16 `std.Io` time primitives. Preserve wall-clock versus monotonic semantics explicitly.

12. **Migrate random and protocol/OAuth ID generation**  
    Priority: **high**  
    Update random wrappers to use Zig 0.16 `io.random`, `io.randomSecure`, or `std.Random.IoSource` as appropriate. Migrate PKCE, OAuth state, WebSocket masks/nonces, protocol IDs, and storage temporary names. Treat secure entropy call sites as explicit security review points.

13. **Migrate ArrayList, formatting, custom JSON writer, and std.json drift**  
    Priority: **high**  
    Fix container and writer API compile errors after the compiler switch. Convert only compile-confirmed `std.ArrayList` breakages and migrate `std.fmt.format` uses in the custom JSON writer/protocol envelope code. Validate `std.json` parse/stringify APIs through protocol/provider/utils tests.

14. **Migrate filesystem, stdio transport, OAuth storage, and CLI file I/O**  
    Priority: **high**  
    Port filesystem and stdio helpers to Zig 0.16 `std.Io.Dir`, `std.Io.File`, and reader/writer APIs. Migrate OAuth storage, stdio transport, and targeted CLI file I/O through the helpers. Preserve atomic credential-storage behavior and current error handling.

15. **Migrate provider HTTP streaming implementations**  
    Priority: **urgent**  
    Port Anthropic, OpenAI Completions, OpenAI Responses, Azure OpenAI Responses, Google Generative, Google Vertex, and Ollama providers to the Zig 0.16 HTTP flow. Preserve incremental SSE parsing and cancellation behavior. Use the shared HTTP abstraction rather than separate ad hoc provider implementations.

16. **Migrate OAuth HTTP flows and callback networking**  
    Priority: **high**  
    Port GitHub Copilot, Anthropic, Google, and OpenAI Codex OAuth HTTP paths plus callback-server networking to Zig 0.16 APIs. Preserve credential ownership boundaries and response-body limits. Validate with utility/auth tests and mock callback-server tests, not external login E2E.

17. **Migrate WebSocket transport networking**  
    Priority: **normal**  
    Port WebSocket connection setup, stream read/write, nonce/mask generation, and network error handling through the networking/random wrappers. Preserve frame parsing and existing transport interfaces. Validate with loopback or mock transport tests.

18. **Run full unit and mock E2E validation on Zig 0.16.0**  
    Priority: **urgent**  
    Run all grouped unit test steps plus mock-based protocol E2E on Zig 0.16.0. Stabilize failures and CI timing without adding external provider E2E requirements. This is the acceptance gate for compile/test parity.

19. **Update documentation, migration notes, and cleanup transitional code**  
    Priority: **normal**  
    Update developer docs and build instructions to reflect Zig 0.16.0. Remove obsolete Zig 0.15.2-only comments or dead compatibility paths while preserving wrappers that remain useful. Confirm pattern guardrails and CI references are current.

## Dependencies

- Work item 1 is the base for work items 2, 3, 4, 5, and 6.
- Work item 7 can run in parallel with work items 1-6.
- Work item 8 depends on work items 1-7, unless the team explicitly accepts reduced pre-switch coverage.
- Work item 9 depends on work item 8.
- Work item 10 depends on work items 7 and 8.
- Work item 11 depends on work items 2 and 8, and may depend on work item 10 if synchronization primitives affect wrapper implementation.
- Work item 12 depends on work items 3 and 8.
- Work item 13 depends on work item 8 and can run after or in parallel with work item 9 with conflict coordination.
- Work item 14 depends on work items 4, 8, 11, and 13.
- Work item 15 depends on work items 5, 8, 11, 12, and 13.
- Work item 16 depends on work items 5, 6, 12, and 14.
- Work item 17 depends on work items 6, 12, and 14.
- Work item 18 depends on work items 9-17.
- Work item 19 depends on work item 18.

## Out of scope

- Full evented-I/O redesign of Makai's public APIs.
- Building or maintaining a libxev-to-`std.Io` adapter.
- Waiting for upstream libxev `std.Io` support before the initial migration.
- Adding new providers, transports, OAuth flows, or agent features.
- External provider E2E stabilization or new secret-dependent tests.
- Broad performance optimization unrelated to compile/test parity.
- Changes to GitHub repository rules, admin bypass, or direct local-root modifications beyond instructed sync operations.

## Open questions

1. Which Zig 0.16 `std.Io` backend should Makai use by default for CLI, tests, providers, and networking flows?
2. Should public APIs accept explicit `std.Io`, or should Makai introduce context objects that own default I/O instances?
3. Should `EventStream` remain futex/atomic-based after migration, or should a follow-up redesign use higher-level `std.Io` primitives?
4. Which libxev commit or release should be selected as the Zig 0.16-compatible pin, and what verification is required?
5. Are downstream users expected to retain Zig 0.15.2 source compatibility after the compiler switch?
6. Should provider HTTP migration be one large provider PR or split by provider family after the shared abstraction lands?
