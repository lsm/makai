# Plan: Zig 0.15.2 → 0.16.0 Migration Decomposition

## Goal summary

Deliver a concrete, reviewable implementation plan for migrating Makai from Zig 0.15.2 to Zig 0.16.0 based on the approved impact assessment in `docs/zig-0.16.0-upgrade-impact-assessment.md`. The migration proceeds through an explicit architecture-decision prerequisite, preparation wrappers/tests on Zig 0.15.2, a green compiler/dependency baseline PR, core/std fixes, I/O/provider/OAuth/transport migration, and final Zig 0.16 validation. The primary implementation deliverable is `docs/zig-0.16.0-migration-plan.md`, which decomposes the work into single-PR tasks with dependency ordering, risk mitigations, rollback strategy, and remaining clarification points.

## Work items

1. **Decide Zig 0.16 I/O architecture and ownership model**  
   Priority: **urgent**  
   Make the default `std.Io` backend and ownership model an up-front architecture decision before wrapper work starts. The binding default for dispatch is that Phase 0 wrappers MUST NOT expose `std.Io` in public API signatures; public constructors use Makai-owned context/default-I/O patterns, while internal helpers may accept explicit I/O handles when needed. Document wrapper naming conventions and parameter order so dependent PRs are consistent.

2. **Add I/O compatibility design skeleton**  
   Priority: **high**  
   Create the base compatibility module and build wiring for time, sleep, random, filesystem/stdio, HTTP, and networking seams. Keep it Zig 0.15.2-compatible and document how each seam should map to the architecture decision from work item 1. This creates a shared foundation for parallel Phase 0 wrapper PRs.

3. **Add time and sleep wrappers on Zig 0.15.2**  
   Priority: **high**  
   Introduce helpers for wall-clock timestamps, monotonic time, and sleeping using current `std.time` and `std.Thread.sleep` APIs. Migrate representative low-risk call sites only. These wrappers become the post-switch location for `std.Io.Timestamp`, `Io.Clock`, `Duration`, and timeout behavior.

4. **Add random and secure-random wrappers on Zig 0.15.2**  
   Priority: **high**  
   Add helpers that distinguish security-sensitive entropy from ordinary random bytes. The wrappers should support later migration of PKCE, OAuth state, WebSocket nonce/masks, protocol IDs, and storage temporary names. Include deterministic test seams where practical.

5. **Add filesystem and stdio helper layer on Zig 0.15.2**  
   Priority: **high**  
   Add wrappers around cwd/open/read/write/atomic rename, stdin/stdout, and file reader/writer operations. The initial implementation should use 0.15.2 `std.fs`/`std.io` while preserving existing behavior. Include tests for read/write, missing files, directory creation, and atomic replacement.

6. **Add HTTP client/request abstraction on Zig 0.15.2**  
   Priority: **high**  
   Define a thin abstraction over provider/OAuth HTTP client creation, request sending, response body reading, and streaming. The goal is to hide Zig 0.16 `std.http.Client{ .io = ... }` and new request-flow changes behind one project API. Validate the shape with a test double; production provider rollout is split into later PRs.

7. **Add networking helper layer on Zig 0.15.2**  
   Priority: **normal**  
   Create wrappers for TCP connect, address resolution, listen/accept, and stream read/write operations used by WebSocket transport and OAuth callback server. Keep the implementation backed by `std.net` until the compiler switch. Add loopback or unit tests that do not depend on external services.

8. **Add focused regression tests before semantic migration**  
   Priority: **high**  
   Expand tests for core EventStream/stream behavior, auth/OAuth refresh locking, OAuth storage atomic writes, WebSocket frame parsing/masking, SSE parsing, and protocol envelope JSON. These tests should run on Zig 0.15.2 and become the safety net for post-switch changes. Avoid external provider E2E tests.

9. **Switch to a first green Zig 0.16 baseline PR**  
   Priority: **urgent**  
   Update `zig/build.zig.zon`, select and hash a Zig 0.16-compatible libxev pin, update CI Zig versions, and apply only minimum compile-restoring source fixes needed for the baseline to compile and pass an agreed smoke/unit subset. This plan chooses a first green baseline PR rather than an unmerged integration checkpoint, so downstream migration PRs are based on mergeable Zig 0.16 code. Phase 0 PRs may land on `main` while it still targets 0.15.2; after this PR merges, follow-up migration work should use short-lived branches targeting Zig 0.16 `main` rather than a long-lived feature branch.

10. **Migrate `std.mem.indexOf*` call sites to `std.mem.find*`**  
    Priority: **high**  
    Replace all `std.mem.indexOf`, `indexOfScalar`, `indexOfAny`, and `indexOfPos` usages with the correct Zig 0.16 `find` family. This high-volume mechanical work should be isolated to reduce noise in deeper I/O PRs. Verify exact replacement names against Zig 0.16.0.

11. **Migrate core EventStream and stream synchronization**  
    Priority: **high**  
    Port synchronization in `zig/src/event_stream.zig` and `zig/src/stream.zig` from `std.Thread.Futex`/related primitives to Zig 0.16-compatible `std.Io.*` primitives or suitable equivalents. Keep this PR focused on central streaming semantics only. Use the regression tests from work item 8 to validate wake, timeout, completion, polling, and error behavior, and preserve existing stream error messages/error types unless a compiler-enforced change is documented.

12. **Migrate agent/auth/OAuth synchronization**  
    Priority: **high**  
    Port synchronization in `zig/src/agent/agent.zig`, `zig/src/protocol/auth/server.zig`, and `zig/src/utils/oauth/refresh_lock.zig` separately from core EventStream work. This isolates auth/agent coordination review from lock-free stream review. Validate refresh coordination, auth protocol locking, and agent event completion behavior.

13. **Migrate time, sleep, and timestamp call sites through wrappers**  
    Priority: **high**  
    Convert remaining direct timestamp and sleep calls to the project wrapper API. Update wrapper implementations to use the chosen Zig 0.16 `std.Io` time primitives. Preserve wall-clock versus monotonic semantics explicitly.

14. **Migrate random and protocol/OAuth ID generation**  
    Priority: **high**  
    Update random wrappers to use Zig 0.16 `io.random`, `io.randomSecure`, or `std.Random.IoSource` as appropriate. Migrate PKCE, OAuth state, WebSocket masks/nonces, protocol IDs, and storage temporary names. Treat secure entropy call sites as explicit security review points.

15. **Migrate ArrayList, formatting, custom JSON writer, and std.json drift**  
    Priority: **high**  
    Fix container and writer API compile errors after the compiler switch. Convert only compile-confirmed `std.ArrayList` breakages and migrate `std.fmt.format` uses in the custom JSON writer/protocol envelope code. Validate `std.json` parse/stringify APIs through protocol/provider/utils tests.

16. **Migrate OAuth credential storage filesystem operations**  
    Priority: **high**  
    Port OAuth credential storage to Zig 0.16 filesystem helpers as its own user-data-focused PR. Preserve atomic replacement, directory creation, missing-file behavior, permissions expectations, rollback/backup safety, and existing storage error messages/error types unless a compiler-enforced change is documented. Keep stdio transport and CLI file I/O out of this PR.

17. **Migrate stdio transport and CLI file I/O**  
    Priority: **high**  
    Port stdio transport and CLI file operations to Zig 0.16 filesystem/stdio helpers. Keep this separate from OAuth credential storage so transport/CLI review does not obscure user-data safety. Validate transport and CLI-related unit tests, plus CLI output formatting, exit codes, and auth-flow prompts.

18. **Migrate shared HTTP abstraction and one proving provider**  
    Priority: **urgent**  
    Port the shared HTTP abstraction to Zig 0.16's `std.Io`-aware request/response flow and migrate exactly one representative streaming provider as the proving provider. The proving provider should exercise request bodies, response head handling, incremental body reads, SSE parsing, cancellation, and provider error-body handling. Preserve existing provider error messages/error types unless a compiler-enforced change is documented; do not migrate all provider families until this PR establishes the abstraction shape.

19. **Migrate remaining OpenAI/Azure provider HTTP implementations**  
    Priority: **high**  
    Migrate OpenAI Completions, OpenAI Responses, and Azure OpenAI Responses providers through the proven shared HTTP abstraction. Keep request/response formatting changes limited to what Zig 0.16 requires. Run provider unit tests and mock/non-secret tests.

20. **Migrate remaining Anthropic/Google/Ollama provider HTTP implementations**  
    Priority: **high**  
    Migrate Anthropic Messages, Google Generative, Google Vertex, and Ollama providers through the proven shared HTTP abstraction. Preserve streaming, SSE parsing, cancellation, thinking blocks, and provider-specific error handling. Run provider unit tests and mock/non-secret tests.

21. **Migrate OAuth HTTP flows and callback networking**  
    Priority: **high**  
    Port GitHub Copilot, Anthropic, Google, and OpenAI Codex OAuth HTTP paths plus callback-server networking to Zig 0.16 APIs. Preserve credential ownership boundaries and response-body limits. Validate with utility/auth tests and mock callback-server tests, not external login E2E.

22. **Migrate WebSocket transport networking**  
    Priority: **normal**  
    Port WebSocket connection setup, stream read/write, nonce/mask generation, and network error handling through the networking/random wrappers. Preserve frame parsing and existing transport interfaces. Validate with loopback or mock transport tests.

23. **Run full unit and mock E2E validation on Zig 0.16.0**  
    Priority: **urgent**  
    Run all grouped unit test steps plus mock-based protocol E2E on Zig 0.16.0. Stabilize failures and CI timing without adding external provider E2E requirements. Validate CLI output formatting, exit codes, and auth-flow prompts as part of the acceptance gate for compile/test parity.

24. **Update documentation, migration notes, and cleanup transitional code**  
    Priority: **normal**  
    Update developer docs, build instructions, changelog/release notes, and downstream migration notes to reflect Zig 0.16.0. Specifically update `CLAUDE.md` from "Requires Zig 0.15.2" to "Requires Zig 0.16.0" and add guidance for consumers depending on Makai public types/constructors. Remove obsolete Zig 0.15.2-only comments or dead compatibility paths while preserving wrappers that remain useful.

## Dependencies

- Work item 1 is the prerequisite for work items 2-7.
- Work item 2 is the base for work items 3-7.
- Work item 8 can run in parallel with work items 2-7 after work item 1 is decided.
- Work item 9 depends on work items 1-8.
- Work item 10 depends on work item 9.
- Work item 11 depends on work items 8 and 9.
- Work item 12 depends on work items 8, 9, and 11.
- Work item 13 depends on work items 3 and 9, and may depend on work item 11 if shared timing primitives affect tests.
- Work item 14 depends on work items 4 and 9.
- Work item 15 depends on work item 9 and can run after or in parallel with work item 10 with conflict coordination.
- Work item 16 depends on work items 5, 9, 13, 14, and 15.
- Work item 17 depends on work items 5, 9, 13, and 15; it does not depend on OAuth credential storage.
- Work item 18 depends on work items 6, 9, 13, 14, and 15.
- Work item 19 depends on work item 18.
- Work item 20 depends on work item 18 and can run in parallel with work item 19 if shared provider helpers are stable.
- Work item 21 depends on work items 6, 7, 14, 16, and 18.
- Work item 22 depends on work items 7 and 14; it does not depend on filesystem/stdio/OAuth storage migration.
- Work item 23 depends on work items 10-22.
- Work item 24 depends on work item 23.

## Out of scope

- Full evented-I/O redesign of Makai's public APIs beyond the explicit architecture decision required for this migration.
- Preserving Zig 0.15.2 source compatibility after Phase 1; public API changes are allowed when documented in migration notes.
- Building or maintaining a libxev-to-`std.Io` adapter.
- Waiting for upstream libxev `std.Io` support before the initial migration.
- Adding new providers, transports, OAuth flows, or agent features.
- External provider E2E stabilization or new secret-dependent tests.
- Broad performance optimization unrelated to compile/test parity.
- Changes to GitHub repository rules, admin bypass, or direct local-root modifications beyond instructed sync operations.

## Open questions

1. Which libxev commit or release should be selected as the Zig 0.16-compatible pin, and what verification is required?
2. Does Zig 0.16.0 preserve `std.time.milliTimestamp`/`nanoTimestamp`, or should all usage move immediately to wrapper implementations backed by `std.Io.Timestamp`/`Io.Clock`?
3. Which provider should serve as the proving provider for the shared HTTP abstraction PR?
