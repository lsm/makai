# Makai OAP Alignment Ledger

Status: deviations ledger and convergence contract between makai's agent-protocol
semantics and the Open Agent Protocol (OAP) agent-control core. This is the document
OAP adapter #3 (lsm/open-agent-protocol#3) maps makai against.

Normative counterpart: `v1-sdk-agent-provider-spec.md` §13 ("Session Lifecycle &
Frame Routing, V1.1") defines the semantics summarized here.

## Provenance

- Makai pins: `lsm/makai` `main` @ `1413ef7` ("fix(sdk): in_reply_to-aware waiter
  routing in the stdio transport (#207)") for the §13.3 routing claims,
  `main` @ `bad82f0` ("feat(agent): server-side idle-session TTL eviction (#202)
  (#206)") for the §13.2.6-rule-6 eviction claims, and `main` @ `9a3e5df`
  ("fix(sdk): teardown guards — ownership-evidence stop, failure-pair drain
  (#208)") for the §6.1/§13.4.2 teardown-guard claims. The
  session-lifecycle pass itself was verified against `67ad514`
  ("fix(agent): send agent_stop on session teardown — terminal, error, and
  auth-retry paths (#200)"). The §13.1/§13.5 wire-key (rename) claims pin to the
  #198 rename's landing on `main` — PR #211, merged as `65a28fb`
  ("fix(agent): rename agent_start payload key resume_session_id → session_id
  (#198)"). The §13.1 client-side sequence-discipline and §13.4.1
  cleanup-probing claims pin to the gap-7 client sequence-control slices landed
  on `main`: the TS SDK half PR #215 (`ec2bc2d`), and the Zig client slices S1
  `2efce28` (#216), S2a `f578903` (#218), S2b-1 `560f635` (#226), S2b-2
  `a8a6c07` (#227), S2b-3 `8925a8c` (#231), S3 `e4c568b` (#232), S4 `f5fd0b5`
  (#239), S5 `d61f6dd` (#240) — every slice of the series has landed. Every
  `[current]` claim in §13 and every status below was verified against one of
  these revisions.
- OAP references:
  - Decision 0001 — "Agent-Control v0.1 Executable Core" (accepted 2026-09-06):
    typed identity domains, one-foreground-run-per-session, deterministic run event
    order, cancellation intent vs settlement, resume/reconciliation/replay split.
  - `drafts/agent-control-core.md` (agent-control-core profile draft).
  - Coordination: lsm/open-agent-protocol#3 (makai queued as the third OAP adapter,
  adapter-first; makai's goal is to eventually speak native OAP).
- Ledger scope: the agent-protocol surface — `zig/src/protocol/agent/` (types,
  envelope, server, runtime), the stdio host (`zig/src/tools/makai.zig`), and the TS
  SDK client (`typescript/src/execution_client.ts`). Provider, auth, and tool
  protocols are out of scope until their own passes. The native OAP endpoint added
  under `zig/src/protocol/oap/` (types, envelope, server, bridge) and the
  `makai --oap` host are in scope and covered by their own section below; they sit
  in front of the agent-protocol surface and change none of its rows.

Feedback rule (from lsm/open-agent-protocol#3): an adapter mismatch resolves as
either an OAP revision (issue/decision on lsm/open-agent-protocol) or a makai fix
(issue on lsm/makai) — never silent adapter-side compensation. Cross-reference issue
numbers in both directions.

## Identity domains

| Makai identity | OAP identity | Status | Rule |
| --- | --- | --- | --- |
| envelope `session_id` + payload `session_id` (legacy `resume_session_id` alias on `agent_start`) | `session_id` | aligned | Correlation + session-container key only; never a resume/replay handle (#198 renamed the `agent_start` wire key to `session_id`; the old key survives as a server-accepted parse alias, also emitted transitionally by both makai clients — TS SDK and Zig serializer — with the same value for pre-rename-server compat). OAP `session.open` returns a stable id; makai's `agent_start`/`agent_started` pair plays that role. |
| envelope `message_id` / `in_reply_to` | envelope `id` / `in_reply_to` | aligned | `in_reply_to` references the request envelope's `message_id` only; set on synchronous replies, absent on async run output. |
| envelope `sequence` | `sequence` | deviating: scope | Makai: per-direction, per-session. Inbound consumption is accepted-only: each ACCEPTED `agent_message` advances the counter (an accepted `agent_stop` removes it with the session); rejected requests and the non-consuming request types (`agent_status`, `ping`, `tool_list`, `models_request`, `goodbye` — accepted silently, no teardown, no reply) never advance it. Outbound has two frame classes: allocated frames draw a monotonic counter scoped to the session-container registration (a re-registered id restarts; a failed counter update propagates rather than being swallowed — #210 gap 5 — so allocated sequences stay monotonic, with a retried publication possibly leaving a gap, which consumers must not treat as loss) — while echo replies (`session_info`, `pong`, `tool_list_response`) copy the inbound sequence verbatim and validation errors carry 0 — a permanent deviation (decision (b) of #204; see the deviations ledger entry on echo-reply sequencing). OAP v0.1: run-scoped, positive, contiguous, and requests/responses do not consume it. Adapters must renumber per OAP run sequence from native receive order and must not order echo replies by sequence. |
| provider `stream_id` / auth `flow_id` | none (binding-private) | aligned by analogy | Correlation values private to their adjacent protocols on the same connection; never OAP identities (OAP Decision 0001 keeps native IDs out of portable identity). |
| payload `tool_call_id` | `tool_call_id` | deviating: uniqueness scope | Correlates concurrently in-flight calls only. Ids originate from provider output and the server keeps no session-wide registry — a provider may reuse a value across turns or runs of one session. Adapters must not key tool history by bare `tool_call_id` (namespacing or per-run scoping required). Reuse no longer misattributes in-flight waits (#210 gap 6, §13.1): the stdio interception correlates each `tool_result` by `in_reply_to` against the CURRENT outstanding `tool_execute`'s `message_id` — mismatched, absent, and unsolicited replies are discarded. |
| — | `endpoint_id`, `participant_id` | absent (deviation) | Makai has no endpoint or participant identity; the transport connection is implicit and there is exactly one server per stdio process. Affects reverse-interaction ownership: `tool_execute` is the only server-initiated request and its ownership is implicitly "the session's client." |

## Deviations ledger

Statuses: `aligned` · `renamed` · `deviating: reason` · `absent by design`.

| OAP term | Makai construct | Status | Notes |
| --- | --- | --- | --- |
| `session_id` (stable session scope) | agent session container keyed by NanoID session id | aligned | Multi-message containers by design (`publishAgentResult` → `.ready`); no persistence, so stability is process-lifetime only. The `agent_start` payload key was renamed `resume_session_id` → `session_id` (#198); the old key is accepted as a permanent legacy alias (both makai clients emit it transitionally alongside the canonical key for the same reason). Idle-TTL eviction is silent and no frame carries a registration generation, so a reused id's holder is not provable from the wire — `RESIDUAL-1`; the session-gone answer's own attribution is `RESIDUAL-2`. |
| endpoint / participant identity | none | deviating: no endpoint or participant exists to address | Required for OAP initialization and reverse-interaction ownership; a makai introduction needs its own spec pass. |
| `submission_id` / `run_id` split | none — one `agent_message` per run in SDK usage | absent by design (v1) | No admission receipt: `agent_message` has no synchronous reply. A run is identified operationally by `(session_id, settlement frame)`. Candidate future revision if the adapter needs stable run identity; nothing queued. The absence is load-bearing: `agent_result` carries no run identity, so settlement-based bookkeeping attributes a settlement by insertion order — `RESIDUAL-5`. |
| `message_id` / `in_reply_to` / `sequence` | envelope fields of the same names | aligned (`in_reply_to`), deviating: sequence scope (see identity table) | Per §13.1/§13.3. |
| monotonic outbound `sequence` across ALL server frames | allocated frames draw the per-session counter; echo replies (`session_info`, `pong`, `tool_list_response`) copy the request's inbound sequence verbatim and request-validation `agent_error` envelopes carry `sequence: 0` | deviating: permanent — echo replies | Decision (b) of #204: the echo is kept deliberately. It is a correlation echo (a consumer can match a reply to its request by sequence without `in_reply_to`), not an ordering allocation; re-allocating echo replies from the per-session counter (option (a)) would break any consumer relying on that echo and buy only cross-class monotonicity, which consumers are already forbidden to assume (§13.1: "consumers MUST NOT order echo replies against allocated frames by sequence"). Adapters renumber per OAP run sequence from native receive order and never order echo replies by sequence. |
| admission (`session.message.submit.response` before stream) | server ACCEPTS `agent_message` by enqueueing it; rejected writes (unknown session / bad sequence / `.processing`) return a request-correlated validation `agent_error` and admit nothing | deviating: no admission receipt | OAP separates "the endpoint accepted the submission" from execution; makai acceptance has no positive frame — observable only through subsequent run output on an EXCLUSIVE, quiescent route (shared/reused-id output is uncorrelated and can belong to another run, §13.3.2) or the PROBABILISTIC absence of a correlated rejection (an allocation failure in the acceptance path escapes without one), so adapters MUST bound waits and treat expiry as an unknown outcome (§13.4.1/§13.4.6). |
| settlement (exactly one terminal per accepted run) | `agent_result` frame for both `run()` and `stream()` (the SDK projects it into the terminal `agent_end` event); loop-internal failure = the `agent_event`(error) + settlement `agent_error` pair counted as ONE settlement; provider-originated failure (auth/network/URL) = an error-valued `agent_result` (`stop_reason: "error"` + `error_message`) — classified by payload, not frame type | aligned for natural outcomes; deviating: cancelled runs | A run cancelled by `agent_stop` produces NO run settlement frame — the session is removed and the cancelled run's later publications are discarded; the `agent_stopped` reply is the client's only terminal. If that reply's own publication fails (#210 gap 5): the reply's owned fields are now built BEFORE the removal, and run cancellation + tool-bridge cleanup complete even when the reply's serialization or its direct synchronous write (outside the outbox) fails — the failure surfaces as the host's dispatch error frame, but the client still sees no `agent_stopped`, only that uncorrelated runtime error or a timeout, although teardown succeeded. No OAP `run.cancelled` equivalent exists. §13.4.2/§13.4.4. |
| single terminal arbiter (children settle first; duplicate terminals suppressed) | run pump settles result XOR error; trailing `agent_end` held until after `agent_result` | aligned, with known deviations | §13.4.3. Residual races/failures: a stopped (or evicted) session's cancelled run can no longer publish into a re-created id — registration generations (#204) bind each run to the registration it was admitted under and discard stale publications (no events, no settlement, no state mutation; a listed stale run no longer fails the fresh registration's run start with `agent_busy`) — but frames the OLD registration already buffered downstream (outbox, pipe, stdout) carry no generation on the wire and remain attributable to the new registration until drained (§6.1). Publication failure is now transactional (#210 gap 5): settlement steps record progress on the run and failures propagate as the host's typed runtime error frames — the settlement frame is retried, never re-published after committing; a mid-pair failure (the pair's error-event projection delivered, the envelope not) retries ONLY the envelope — the projection is never re-emitted, and the envelope is never abandoned after its projection because the Zig client settles only on `agent_error`/`agent_result` (a bare `agent_event` is merely queued); session status flips ride the COMMITTED frame (a pending result or pair keeps the session `.processing`, so follow-ups are rejected `agent_busy` at admission — clean non-admission — instead of accepted and later converted into an `AgentBusy` settlement), while a run whose frame committed no longer occupies the one-active-run slot while it retries its trailing projection; the trailing `agent_end` publishes only after the `agent_result` commits, so a failed result publication can no longer produce a false-success projection; a run that dropped an `agent_event` settles through the failure pair, never a success `agent_result`; a stream completed with neither a result nor a recoverable error (`completeWithError` drops its message copy on OOM) settles through a generic typed failure instead of being retained forever; outbox delivery peeks before popping (a failed delivery retries the queued frame; the pipe write is all-or-nothing, so a retry never lands on a partial line); tool-request publication keeps the request queued until its envelope commits, so a failure retries instead of stranding the tool wait; the stdio drain reserves its buffer slot before reading the pipe (and reserves nothing on an empty pipe — draining cannot fail with nothing pending — while the host flushes already-buffered frames on a drain error instead of stranding them); a run whose settlement frame committed no longer occupies the session's one-active-run slot while it retries its trailing projection — the next `agent_message` is admitted rather than turned into an `AgentBusy` error settlement. Residual exception: run-START failure pairs have no run object to resume — a mid-pair OOM there propagates with the session already `.error` and only the lone event projection delivered (documented, §13.4.2). |
| `run.cancel` (run-scoped; intent ≠ settlement; races defined) | `agent_stop` — session-scoped teardown that also cancels the in-flight run | deviating: cancellation is session-scoped, not run-scoped | No mid-message run-scoped cancel in v1; a cancelled run emits no run settlement frame (see settlement row). Per OAP Decision 0001's consequence, session-scoped cancellation forces one foreground run per session — makai enforces exactly that (`agent_busy` on duplicate start and on message-to-processing-session). Idle-TTL eviction (§13.2.6, #202) never selects sessions with in-flight runs, and where a removal does land under a live run the host cancels it exactly as stop does. |
| run statuses (`queued`/`running`/`waiting_for_input`/`cancelling`/terminals) | `AgentStatus` (starting/ready/processing/waiting_for_tool/stopping/stopped/error) | renamed + partial: session-level, not run-level; declared ≠ observable | The stdio runtime only ever assigns `ready` → `processing` → `ready` \| `error` (stop removes the entry outright): `starting`, `waiting_for_tool`, `stopping`, and `stopped` are declared enum values no host currently emits — adapters MUST NOT wait on them. No cancelled/failed terminal distinction at the status level; failure is carried by settlement frames (§3.5), not session status. |
| state reconciliation (`session.state`) | `agent_status` → `session_info` | deviating: counters only | Returns status, model, message_count, timestamps — no transcript cursor, no authoritative transcript. Not a recovery source of truth. |
| transcript load | none | absent by design | §13.5; client supplies full history in `messages` every call. |
| resume (attachment without history) | none | absent by design | §13.5; a reused session id creates a fresh container or is rejected `agent_busy` — never restores state. (The pre-rename wire key `resume_session_id` was a historical misnomer, corrected by the #198 rename; it survives only as a parse alias.) |
| replay (canonical events from cursor) | none | absent by design | §13.5/§12; no journal, cursor, or gap reporting. An adapter may journal its own canonical output (degraded replay per OAP rules) but must not claim native replay. |
| capability negotiation (revisioned descriptors) | implicit probing (`not_implemented` nack) | deviating: no negotiated capabilities | Spec §9. Adapters synthesize OAP capability revisions from probe results + policy, as the ACP ledger does. |
| delivery modes `queue`/`steer`/`btw` | none — `agent_busy` on concurrent delivery | absent by design | §13.2.4; OAP optional units, unavailable here. |
| envelope shape | flat envelope: `version`, `type`, `session_id`, `message_id`, `sequence`, `in_reply_to`, `timestamp`, `payload` | aligned structurally | OAP's envelope adds `protocol`/`profile` strings and scope fields (`run_id`, `turn_id`, …) makai does not carry; mapping is mechanical for the adapter. |
| process exit before settlement | transport rejects the registered frame wait; reads queued behind the transport read lock surface the death as their response timeout; no fabricated result | aligned | "Failure, never success" — §13.4.6, matching the ACP ledger's process-exit rule; adapters must keep timeout handling for lock-queued reads rather than expecting prompt rejection for every concurrent request. |
| stdin EOF while a run waits on a distributed `tool_result` | the host latches the disconnect; the wait fails with a typed error and the run settles through the failure pair (`tool_execution_error` settlement), then the process drains and exits | aligned (#210 gap 4) | §13.2.7 rule 7: EOF-cancel applies to the tool-waiting case — the tool host IS the disconnected client. A `tool_result` delivered before EOF wins its wait (checked before the latch); a run needing client input after EOF settles failed, never success (§13.4.6), with pending tool requests dropped unpublished; provider-executing runs keep being pumped toward settlement until they need client input. Late frames from the cancelled run settle nothing — the pump's disconnect classification publishes the failure pair once and the run is removed, working with (not around) the §13.4.5 generation guard. |
| control-layer-provided tools (`session.open.request.tools`, staged unit T3c, [OAP Decision 0011](https://github.com/lsm/open-agent-protocol/blob/main/decisions/0011-control-layer-provided-tools.md)) | tool catalogue carried in the `agent_start` `config_json` and restated in the `agent_message` `message_json`; `parseAgentTools` resolves message-first, config as fallback | deviating: per-submit override, unexercised — `[planned]` aligned (session-scoped) | §13.2 rule 8. The override is dead capability in both directions: every consumer writes the same list into both payloads from one request object and always emits the key (empty array when none), so the message value unconditionally shadows the config and **the session-scoped field has never been read by any consumer**. All three SDKs in tree (TypeScript, Go, Python) are one-shot and expose no session handle, as does the unmerged Rust client (#309); the native OAP bridge is the only multi-message consumer and declares `"tools": []` in both payloads. Makai narrows to session-scoped declaration on its own timeline, justified by the silent failure the current precedence permits (declare tools at start, send `"tools": []` per message, receive no tools and no error) and NOT contingent on T3c graduating. Decision 0011 provisions tools at session open and defers per-submit, citing this row's finding; when it graduates, makai's narrowing is already aligned. Reversal condition: sufficient only while makai owns every consumer — the host accepts repeated `agent_message` (§13.2 rule 3), so the wire supports per-submit provisioning and only the SDKs decline it; a persistent-session API with steering messages reopens this row. |
| caller-executed tools (`action.call.resolve.request` / `.response`, staged unit T3c) | `tool_execute` published by the host, answered by a correlated `tool_result` (`in_reply_to` matches the request `message_id`) | deviating: no counterpart in the shipped OAP core | The shipped `action.call.*` six are observational — they report execution the endpoint owns, with `execution_owner` naming the actor — and the only caller round-trips in the core are `action.permission.resolve.*` and `user.input.resolve.*`. Decision 0008 (accepted 2026-09-16) scopes its unit to T3a/T3b and names T3c a deferral; [Decision 0011](https://github.com/lsm/open-agent-protocol/blob/main/decisions/0011-control-layer-provided-tools.md) discharges that deferral with the missing resolve pair but is `Status: proposed`, so client-hosted tools remain unavailable over OAP by two distinct mechanisms, neither of which compensates. Through the Go adapter in lsm/open-agent-protocol, a host-published `tool_execute` fails the run — `adapter/makai/session.go:288` in that repo, error string `makai_tool_executor_unavailable`; the identifier is the adapter's own and appears nowhere in this tree. In native OAP mode the frame never arises: `bridge.zig` declares `"tools": []` in both payloads (`buildConfigJson`, `buildMessageJson`), so the agent loop is offered no tool to call, and the bridge has no `tool_execute` handling at all — `applyNativeLine`'s switch ends `else => {}`, so such a frame would be dropped rather than answered if one ever appeared. This gap is live through the bridge today and is not created by any native-mode decision; it is the one item that keeps T3c on the critical path for replacing the native wire. Note `execution_owner` ships on `protocol.ToolDefinition` but is undescribed in the core profile draft — an upstream documentation gap, raised. |

## Native OAP mode (`makai --oap`)

Everything above describes makai's **native agent protocol**, which this section
does not change. `makai --oap` adds a second, parallel front end: an OAP
agent-control-core endpoint that speaks OAP envelopes on the wire and drives the
same in-process agent host the `--stdio` mode drives. The adapter-first plan of
lsm/open-agent-protocol#3 is unchanged — this is the first native slice, not a
replacement for the external adapter, and the two can disagree only where this
section says they do.

### Protocol source

Worked from `lsm/open-agent-protocol` @ `main`:

- `drafts/agent-control-core.md` — the profile: envelope, minimum core surface,
  data shapes, capability keys, snapshot freshness, minimum conformance.
- `drafts/conformance.md` — profile/unit claim syntax, the ten stateful checks,
  degradation expectations.
- `decisions/0001-agent-control-v0.1-executable-core.md` — typed identity
  domains, one foreground run per session, deterministic run event order,
  cancellation intent vs settlement, resume/reconciliation/replay split.
- `decisions/0002-admission-before-start.md` — the two canonical admission
  shapes and pre-start settlement.
- `decisions/0005-run-controls.md` — the fail-closed run-control gate.
- `schema/v0.1/*.json` — the normative envelope and payload schemas.
- `cmd/oap validate` — the executable validator used as the conformance oracle
  below.

### Claim

`open-agent-protocol.agent-control-core+run-controls`, over a JSONL-on-stdio
binding. The core is transport agnostic by its own Transport section, and
bindings are a binding concern; stdio NDJSON is chosen because it is already
makai's language-neutral process boundary and needs no new transport. The
binding is declared in the descriptor as `{kind: "stdio", serialization:
"jsonl"}`, so a later HTTP/SSE or WebSocket binding is additive.

`+run-controls` is claimed in its refusal half plus one executed control. Three
of the four controls are unadvertised and refused before admission with
`unsupported_feature` / `details.reason: "unadvertised"`; `run.model_selection`
is advertised `native` with `mode: "per_run"`, because makai genuinely applies a
per-message `model_ref` to the run it was requested for and leaves the session
default alone.

No other unit is claimed. `+tools`, `+permissions`, `+user-input`,
`+persistence`, `+models`, `+queue`, `+steer`, `+btw`, `capabilities.updates`,
and extension packs are all unadvertised, and an unadvertised key is refused
rather than silently ignored.

### How the mode resolves the deviations above

| Deviation (native row) | Resolution at the OAP boundary | Residual |
| --- | --- | --- |
| endpoint / participant identity absent | The OAP endpoint synthesizes a stable `endpoint_id` (`makai.agent-control`) and answers `protocol.initialize.request` with it. | Participant identity is accepted on the request and not yet used for reverse-interaction ownership, because no reverse interaction is advertised. |
| no `submission_id` / `run_id` split | The endpoint allocates both as fresh ULIDs at admission and keys all run-scoped events by `run_id`. | The native settlement frame still carries no run identity (`RESIDUAL-5`), so the endpoint attributes a settlement to the session's single in-flight run. That is exact only because the endpoint enforces one foreground run per session. |
| no admission receipt | `session.message.submit.response` is emitted synchronously, before the native `agent_message` is written, as Decision 0002 shape 1 (`admission: "started"`, `effective_delivery: "start"`, `status: "running"`, `delivery_resolution: "session_idle"`), with `run.started` emitted atomically after it. | A native rejection that arrives later settles the already-started run as `run.failed`. This is legal under Decision 0002 but means `admission: "started"` is makai's promotion evidence, not proof the provider accepted the work. |
| sequence scope / echo replies / `sequence: 0` | Native sequence is never reused. The endpoint generates its own positive contiguous per-`run_id` sequence from receive order, starting at 1 with `run.started`, and a separate per-session counter for `session.state.updated`. | None. This is the documented resolution of the §13.1 echo/zero/gap rules: the OAP sequence domain is the endpoint's, not makai's. |
| `agent_result` published before the terminal `agent_end` | The bridge retains the result as **evidence** and settles only on the terminal signal, then emits exactly one of `run.completed` / `run.failed` / `run.cancelled`. Anything arriving after settlement is dropped. | None observable. The duplicate-terminal suppression is tested directly. |
| cancellation is session-scoped | `run.cancel.request` is accepted as **intent** (`run.cancel.response` with `accepted: true`, `status: "cancelling"`, plus `run.status.updated`), the native `agent_stop` is issued, and only authoritative settlement emits `run.cancelled`. Natural completion may win the race and does. | **Unresolved and disclosed**: the session dies with the run. `run.cancel` is advertised `degraded` with a degradation record, and the endpoint moves the session to `closed`, refusing later submissions with `session_not_found`. OAP has no vocabulary for "cancel closed the session". |
| no capability negotiation | `capabilities.request` returns a revisioned descriptor (`capability_revision: "makai-oap-core-v1"`), and every non-bootstrap request carrying a different revision is refused `stale_capabilities`. | The revision is static for the process. `capabilities.updates` is not advertised, which the core explicitly permits. |
| envelope shape | The endpoint emits the flat OAP envelope with `protocol`/`version`/`profile` and the scope fields; the native envelope is never exposed. | None. |
| transcript load / resume / replay absent | Not advertised; `session.state` returns authoritative current state only. | **Unresolved and disclosed**: OAP separates resume, reconciliation and replay, and makai has only reconciliation. A degradation record on `session.state` says so. |

### Identity domains in native mode

The OAP `session_id` is **not** the native session id. The bridge allocates a
fresh native NanoID per OAP session and keeps a two-way map. That is deliberate:
OAP ids are opaque non-empty strings while makai's are a fixed 21-character
alphabet, so aliasing them would let a caller's id choice decide whether the
native server accepts a session. Envelope `id` is a fresh ULID per frame;
`run_id`, `submission_id` and the portable assistant `message_id` are separate
ULIDs; the native envelope `message_id` is never exposed as an OAP identity.

### Conformance evidence

Three traces produced by the real binary were validated with the OAP repository's
own validator (`go run ./cmd/oap validate`), all `PASS`:

1. a completed run (initialize, capabilities, session open, session state,
   submit, `run.started`, two `content.delta`, `run.completed`) against a local
   mock Anthropic SSE endpoint;
2. a provider failure (a real HTTP 401) mapped to one `run.failed` with
   `provider_error`;
3. a cancellation (intent acknowledged, `run.status.updated: cancelling`,
   authoritative `run.cancelled`, session `closed`).

The frame-by-frame shape of all three is pinned in CI by the golden-trace tests
in `zig/src/protocol/oap/bridge.zig` (`zig build test-unit-protocol`), so a
regression that would break external validation fails a unit test first.

The endpoint also passes the OAP repository's own conformance harness end to
end — `go run ./cmd/oap conformance --command "makai --oap --model <ref>"`,
which spawns the binary, drives a scripted session over
`drafts/endpoint-stdio.md`, and hands the assembled trace to the validator the
adapters are held to. Cursor replay is recorded as a skip: makai implements no
transport control, answers `unsupported_control`, and the binding permits
exactly that. The harness needs `--model` because makai advertises no
`models.list` catalog over OAP; `+models` is an optional unit and its absence
is not a conformance gap.

### Conflicts raised, not compensated

Per the feedback rule, these resolve as an OAP revision or a makai fix, never
silent adapter-side compensation. None is compensated for in the code.

1. **Cancellation closes the session.** Makai's only cancel is destructive
   session teardown. OAP's `run.cancelled` says nothing about the session's
   fate, and `session.status: "closed"` is reachable but has no stated relation
   to cancellation. Disclosed as a `run.cancel` degradation record and as a
   `closed` session that refuses further submissions. Needs either a makai
   run-scoped cancel or an OAP note that a cancelled run may close its session.
2. **`stale_capabilities` detail direction is ambiguous.** The core requires
   `expected_revision` and `current_revision` in the error details but does not
   say which is the sender's and which is the endpoint's, and no fixture pins
   it. This endpoint reports the sender's pinned value as `expected_revision`
   and its own as `current_revision`. Needs an OAP clarification or a fixture.
3. **Sessions are not resumable, and OAP's `session.open` accepts a
   `session_id`.** Reopening a known id here returns its current state; it never
   restores a run or a transcript. `session_id` remains a correlation key. The
   endpoint advertises no resume, load or replay capability, so no OAP rule is
   broken — but a control layer that reads `session.open(session_id)` as resume
   would be wrong, and the core does not forbid that reading.
4. **A submission needs a model the core has no place to carry.** OAP
   `session.open.request` has no model field, and makai cannot start a run
   without a `model_ref`. The endpoint takes a process default (`--oap --model`,
   or `MAKAI_OAP_MODEL`) and reports it as `current_model_id`; a submission with
   neither is refused `model_not_found`. Needs either an OAP session-level
   default-model control or acceptance that the default is endpoint
   configuration.

### Not implemented

Local tool execution is deliberately switched off in this mode (the bridge sends
an empty tool list), so no `action.call.*` lifecycle can be owed. Also absent:
`models.list`, `transcript.load`/`transcript.delta`, `session.list`, permission
and user-input interactions, `queue`/`steer`/`btw` delivery, dynamic capability
updates, extension packs, and any binding other than stdio JSONL. Each is
unadvertised, and each is refused with a typed `unsupported_feature` error
naming the key rather than ignored.

## Documented residuals

The residual classes accumulated by gap 7 (#210) and its neighbours. Grep
`RESIDUAL-` for the full set. Most are unresolvable on the wire: no frame
carries a registration or run generation (spec §13.4.5), so the paired
situations there are indistinguishable at a client's inputs, only the
generation tokens of a future wire revision close them, and adapters MUST treat
them as documented uncertainty rather than protocol guarantees. Two entries are
different in kind, and both are recorded because mishandling them is silent:
`RESIDUAL-2` is already locally solvable from `in_reply_to`, and `RESIDUAL-6` is
a mechanism-COVERAGE gap — a landed reconciliation not yet applied on one
transport — fixable with no wire change at all.

| Residual | Spec | What cannot be told apart | Recorded mitigation |
| --- | --- | --- | --- |
| `RESIDUAL-1` stale admission after a silent TTL eviction | §6.1, §13.2.6 | Eviction emits no frame, so an id admitted under one registration may be evicted and re-registered by another caller before our next message; a message of ours accepted by that fresh registration (its counter restarts and can match ours) is the same bytes as our own registration accepting it. | §6.1's admission evidence bounds the teardown stop's blast radius: an exclusive client-generated id is the only sufficient form until generation tokens exist, and it qualifies only while the client has not allowed that id to be removed and re-registered. |
| `RESIDUAL-2` delayed `agent_not_found` across re-registration | §13.1, §13.2.6 | Locally resolvable, NOT wire-bound: a session-gone answer carries `in_reply_to` naming the exact request, so it is attributable IF the sender kept per-request registration provenance. A purely id-keyed pending list cannot tell the old registration's delayed answer from the current registration's own — the first delayed `agent_not_found` matches the still-registered record and clears state the re-registration just established. | Tag pending sends with the registration epoch and discard a reply whose epoch predates the id's re-registration. The Zig client approximates this by clearing the session's pending-send list together with its counter/control state on a session-gone answer, so a later copy matches nothing; the id-keyed store is a local bookkeeping limit, not a wire gap. |
| `RESIDUAL-3` stale trailing output misattributed to a reused id | §13.4.2 | Consumed run output is the strongest acceptance tie the wire affords, so the TS attempt clears its unresolved marker on frames reaching its own correlated post-acceptance waits; a stale trailing frame from a previous run on a quickly reused id can reach those waits and clear the marker without proving THIS attempt was accepted. The hazard is not marker bookkeeping: when the stale frame is an `agent_result` the attempt parses and RETURNS the previous run's response, and stale events can be yielded on the `stream()` path — wrong returned data, not merely a missed acceptance signal. | The alternative is not "no leak": leaving the marker set routes teardown through `stopAgentWithSequenceProbe`, so the trade is one extra bounded probe against a wrong-result hazard — and the clear is kept, both because returned data must come from this attempt and because the probe is the marker's own consumer. Closing it needs an identity the wire lacks (run identity on the settlement frame, `RESIDUAL-5`'s remedy). |
| `RESIDUAL-4` post-probe backlog-drain unattributability | §13.4.1 | A correlated wait is served ahead of the session queue, so the probe's reply can overtake the attempt's still-parked output; frames parking between the stop's acceptance and the drain's reads may be the just-stopped run's trailing output or a racing re-registration's output. | The TS SDK's failure-pair teardown AWAITS a single immediate-pass drain of the queued backlog before the id is reused; its abort paths (`drain: "background"` in `run()`/`stream()`) deliberately leave the same drain running un-awaited, so a same-id retry can register while it is still consuming the backlog and race it. The TUI's teardown pump does not close the window either: it consumes parked frames only while driving the probe (bounded, exiting the moment the probe settles) and performs no post-settlement drain. Not draining at all would reinstate the parked-output poisoning of the next same-id run, so this is a policy trade rather than a fix — the window closes only with the generation tokens. |
| `RESIDUAL-5` settlement-based retirement needs run identity | §13.1, §13.3.2 | `agent_result` carries no run identity, so retiring the settled run's pending record attributes the settlement to the OLDEST pending message (insertion order) and the proven floor rises only to the minimum pending-message sequence + 1. | A mis-attribution errs toward surfacing a duplicate rather than swallowing a failure — the self-correcting direction; a run identity on the settlement frame would close it. |
| `RESIDUAL-6` SSE ambiguous message writes unreconciled | §13.2.6 (TUI teardown) | On SSE, every failed `sendRemoteMessages` POST skips the ambiguous-write reconciliation — it is gated on the websocket-owned path — so BOTH failure modes leave an unknown admission outcome unreconciled: the partial write (`ConnectionFailed`, proves nothing) and the complete write whose response headers failed (`HttpPostFailed`, proves transmission). A later result can then arrive orphaned, and the next submission's rejection depends on which branch applied — the partial/no-delivery case (client advanced, server not) is rejected `invalid_request`, because the server compares the sequence against its expected value BEFORE the `.processing` state, while a fully-transmitted request whose run is still processing is rejected `agent_busy`. | Pre-existing coverage gap, unchanged by the TUI teardown — pre-teardown main did strictly less (returned the error with no probe and no session drop). The websocket case IS reconciled. Closing it needs the SSE ambiguity set decided (the two modes carry different evidence) and the probe-stop + session-drop factored into a shared helper; tracked in #242, not wire-bound. |

`RESIDUAL-3` and `RESIDUAL-4` share the downstream-buffer shape the spec records
at §6.1 and §13.4.5: frames already buffered downstream of a removed
registration carry no generation and stay attributable to whatever registration
holds the id next, so a drain's timing is a policy trade rather than a fix.
`RESIDUAL-1` needs the same registration generation but NOT that buffering — no
frame from the removed registration has to be parked: the id is re-registered
before our next outbound message, whose counter matches the fresh registration's
restart, so only ownership/generation evidence separates the two. `RESIDUAL-5`
needs neither draining nor a registration generation — it can occur entirely
within one live registration, with several message sends pending and an
uncorrelated `agent_result` unable to say which run settled, so it needs run
identity on the settlement frame.

## P0 makai follow-ups

These implemented the `[planned]` rules of spec §13, each as its own PR; the
per-item status is the record of what landed. An item is still open exactly
where its spec claims remain `[planned]`.

1. #201 — LANDED: `in_reply_to`-aware frame routing in the transport (implements
   §13.3.1; `correlate` wait option, reply-queue parking for registered requests,
   SDK correlation of each attempt's `agent_start` `message_id` plus a
   pre-acceptance `agent_started` correlation check). Overlapping same-session
   calls now each receive their own replies; the pre-#201 modes (duplicate
   timing out, established run destroyed, wrong request proceeding) are closed.
2. #204/#210 — server enforcement gaps filed against §13's `[planned]` rules. LANDED (first
   slice, #209): envelope/payload session-id agreement rejection (all four
   session-scoped handlers plus the stdio host's stop validation), the
   echo-reply sequence decision — decision (b): echo kept as a permanent
   deviation, see the deviations ledger — and the session generation counter
   so a stopped OR evicted session's cancelled run cannot settle a re-created
   id (stale-generation publications discarded; a listed stale run no longer
   fails the fresh id's run start with `agent_busy`). LANDED (#210 gaps 4+6):
   EOF/disconnect-triggered cancellation of the distributed-tool wait — stdin
   EOF latches the bridge disconnected, the wait fails with a typed error, the
   run settles through the failure pair (`tool_execution_error` settlement)
   and the process drains instead of hanging (§13.2.7 rule 7; deviations
   ledger) — and stale-`tool_result` correlation for reused `tool_call_id`s
   (`in_reply_to` validated against the current outstanding `tool_execute`;
   mismatched/absent/unsolicited replies discarded, §13.1). LANDED (#210 gap
   5): transactional publication — settle-or-propagate exactly once through
   every publication failure path. Settlement steps (result frame, failure
   pair, trailing `agent_end` projection) record progress on the run; a
   failure propagates as the host's typed runtime error frame and the next
   pump RESUMES where it stopped — the settlement frame is retried, never
   re-published after committing; a mid-pair failure (projection delivered,
   envelope not) retries ONLY the envelope — the projection is never
   re-emitted, and the envelope is never abandoned because the Zig client
   settles only on the envelope frame; session status flips ride the
   COMMITTED frame (a pending settlement keeps the session non-admissible),
   while a committed run no longer occupies the one-active-run slot while
   it retries its trailing projection; the trailing `agent_end`
   publishes only after the `agent_result` commits (no false-success
   projection); a run that dropped an `agent_event` (serialization or
   publication failure between consuming it from the stream and committing
   it to the outbox) settles through the failure pair, never a success — a
   truncated stream cannot settle "successfully"; a stream completed with
   neither a result nor a recoverable error settles through a generic typed
   failure instead of being retained forever; run-start failures mark
   the session `.error` BEFORE publishing the pair, so a mid-pair OOM
   leaves recoverable state (documented exception: no run object to resume,
   the lone projection is not re-emitted); tool-request publication peeks
   the bridge head and commits by removal only after the `tool_execute`
   envelope is enqueued — a failure retries instead of freeing the request
   under a parked tool wait; outbox delivery peeks before popping and the
   pipe write reserves data + newline before appending (all-or-nothing), so
   a failed delivery retries the queued frame and never corrupts framing;
   the stdio drain reserves its buffer slot before reading the pipe
   (buffer-before-advance — an already-delivered frame can no longer be
   dropped); the outgoing-sequence counter update is no longer swallowed
   (no duplicate wire sequences); and a stop's reply fields are built
   BEFORE the session removal, with run cancellation + tool-bridge cleanup
   running even when the reply's own publication fails. Gap 7 — client sequence
   control in BOTH clients — is LANDED for the TypeScript SDK in #215 (merged
   `ec2bc2d`): the tracker marks the `agent_message` send unresolved at send,
   rolls back on a correlated rejection, and, while the outcome is unresolved,
   tears down through `stopAgentWithSequenceProbe` — a bounded two-state probe
   (pre-send stop, then the post-send value on a correlated `invalid_request`,
   correlated reads, acceptance at either) awaited on the failure-pair path,
   which then AWAITS a single immediate-pass drain of the queued backlog before
   the id is reused. The abort paths (`drain: "background"` in `run()` and
   `stream()`) deliberately leave that drain running un-awaited, so a same-id
   retry can register while it is still consuming the backlog — the trade
   RESIDUAL-4 records.
   LANDED for the Zig client (S1 `2efce28`, S2a `f578903`, S2b-1/2/3
   `560f635`/`a8a6c07`/`8925a8c`, S3 `e4c568b`, S4 `f5fd0b5`, S5 `d61f6dd`): the
   `AgentProtocolClient` tracks every outstanding send, rolls the tracker back
   MONOTONICALLY on a correlated `agent_error`/`nack` (an older unresolved
   send's floor is never lost), drops the counter state on a correlated
   `agent_not_found`/`session_expired`, never advances on stop sends, and
   exposes the explicit-sequence control surface (`peekNextSequence`,
   `sendAgentMessageWithSequence`, `sendAgentStopWithSequence`,
   `sendAgentStopProbing`) alongside the S2b/S3 duplicate-evidence, ancestry,
   proven-floor, and pending-record guards. The Zig client's own bounded
   two-state stop probe landed in S4 `f5fd0b5` (#239), gated on §6.1 ownership
   evidence and walking a discrete candidate set, and the TUI teardown
   integration landed in S5 `d61f6dd` (#240). No gap-7 work remains open here.
   Same-sequence retries and unknown-outcome cleanup are supported in both
   clients (§13.1/§13.4.1).
3. #205 — TS SDK teardown guards (ownership-evidence stop and failure-pair drain
   IMPLEMENTED; tool-execution tracking pending): the ownership-evidence stop on
   unknown start outcomes — per §6.1's raised bar, an EXCLUSIVE, never-reused
   client-generated id is the only sufficient evidence until #204 supplies
   generation tokens (a buffered correlated `agent_started` can outlive removal
   and re-registration of the id and authorize a stop of the NEW session) — now
   holds in the SDK: teardown settles without sending when no reply to the
   attempt's own `agent_start` was observed and the id was caller-supplied. The
   mandatory drain (or correlation/generation discard) of the failure pair's
   second frame before id reuse now holds for `run()` via a bounded quiescent
   drain on the failure-pair termination (`stream()` drained via its terminal
   teardown already); still pending: independent tool-execution tracking for the
   `auto_once` retry gate (§13.5.3: a tool executed while its lifecycle events
   were dropped by a publication failure is invisible to the yielded-event gate,
   so a retry can duplicate its side effects).
4. #198 — LANDED: the `agent_start` payload key `resume_session_id` → `session_id`
   rename (wire change; semantics already fixed by §13.1/§13.5 — the rename rests on
   them). Both emitters (Zig serializer and TS SDK) send the canonical `session_id`
   key plus the legacy alias (same value) so pre-rename servers keep binding the
   caller's id — the Zig client's sequence counter is keyed under the sent id, so
   binding it avoids an adopted-id sequence-1 mismatch on the first follow-up
   message. The Zig deserializer accepts `resume_session_id` as a permanent legacy
   alias (canonical key wins when both appear), and the §13.1 envelope-agreement
   check applies to whichever key carried the id.

Landed: #202 — server-side idle-TTL eviction (§13.2.6 rule 6) shipped with the
30-minute default, `AgentProtocolServer.Options.session_idle_ttl_ms` +
`MAKAI_AGENT_SESSION_IDLE_TTL_MS` knobs (`0` disables), and `agent_not_found`
semantics for evicted ids. The admission-vs-eviction race is closed server-side
by construction: admission sets `.processing` synchronously, admission and the
sweep run serialized on the host's single pump thread, and the stdio run pump
already cancels runs whose session disappeared with post-removal publications
swallowed as `SessionNotFound` no-ops. The optional bounded-map cap (§13.2.6
resource-caps bullet, MAY) remains unimplemented: process-per-connection hosting
scopes session ownership and lifetime to one connection but does not bound the
count — a single client may register arbitrarily many sessions within the TTL,
which is exactly the growth the cap would backstop.

Adapter mismatches discovered by OAP adapter #3 beyond these resolve per the feedback
rule above.

## The model-provider-core profile

`makai --oap-provider` serves `open-agent-protocol.model-provider-core`, a peer profile of
agent-control-core rather than a unit inside it. Nothing agent-control owns changes because it
exists, and `makai --oap` refuses its envelopes.

The profile was specified against makai's provider layer as design input, and this implementation
is the first to speak it. Seventeen findings from building it changed the draft; the ones that
remain visible as deviations on our side are below.

| Area | Profile | makai | Why |
| --- | --- | --- | --- |
| Wire set | closed, three named values plus `other` | eight registered APIs | Five earn a named wire. Both Google APIs and Ollama say `other` with an opaque `wire_id`, because a wire is named only when more than one independent implementer speaks it. |
| `usage_in_streaming` | `always`, `terminal_only`, `never` | `supports_usage_in_streaming`, boolean | Ours is a request-shape fact gating `stream_options.include_usage`; the profile's is a response-behaviour fact. `true` maps to `always`; `false` is undecidable between the other two and is left unstated. |
| Credential grants | two tiers, out-of-band mandatory where the binding allows | out-of-band served, `static` kind only | The channel is a per-grant unix socket, so a build whose toolchain reports no unix-socket support advertises `none` and no kinds rather than a tier it cannot open. A granted static key is safe by construction, since a per-call `api_key` short-circuits storage in `streamWithRefresh`. A **refreshable** grant is still refused: `AuthStorage.persist` writes on both branches, so a credential that cannot reach durable storage is unrepresentable, and the profile's non-persistable requirement is not satisfiable until one exists. |
| Specimen control frame | a stdio binding control frame, not an envelope | `makai --oap-provider --specimens` | Opt-in at startup: without the flag the frame draws `specimen.error`, so the shipped default emits no frame outside a real exchange. Refused while any inference is active, so specimen and real frames never interleave on one stream, and the specimen scope is `specimen-inference` — unproducible by the real generator, which emits 32 lowercase hex characters. Both grant answers are withheld and said to be withheld. |
| Keepalive | a binding concern, not an envelope | `AssistantMessageEvent.keepalive` | Dropped in translation and consumes no sequence number. |
| Reasoning options | one object, three members | seven `StreamOptions` fields | The `thinking_*`/`reasoning_*` split is vendor vocabulary rather than two concepts. The carry is no longer a reasoning option: a request-level `encrypted_carry` needed a placement rule as soon as a conversation held two reasoning blocks, so the profile removed it and the carry now rides the `reasoning` and `tool_call` content parts in `messages[]`, symmetric with the `carry` on `inference.part.ended`. A request still naming `reasoning.encrypted_carry` is refused rather than ignored, and the refusal says where the carry moved: members inside a payload object are not policed the way payload members are, so without the explicit rule the removed member would decode away silently and the request would succeed with its carry dropped. |
| Stop reasons | closed set of six | identical six | The one place "carried across whole" is demonstrated rather than asserted. |
| Compatibility facts under a destination override | facts undefined while a destination is overridden; a suite must not check them | stated only behind a declared transparent proxy | A plain `*_BASE_URL` redirect says nothing about what answers at the new address, so makai asserts nothing; `*_BASE_URL_IS_PROXY` says the vendor is still behind it, so the vendor's facts hold and we publish them. Nothing in a URL reveals which redirect it is, which is why it takes an operator flag rather than detection — and why the profile cannot require the distinction without also specifying the out-of-band carrier it has just ruled off the wire. Without this, a conformance run against a local mock checks the vendor's claims against the mock's behaviour. |
| Destination overrides | operator-set, out of band, never from the wire | `MAKAI_BASE_URL` and the per-provider vars | The only way to reach a controlled endpoint, so conformance testing depends on it. It stays off the wire because the destination is resolved before the credential is attached: a caller-supplied override would redirect a credentialed provider to an address it chose and have the host attach the vendor key. |

Conformance status: every envelope is implementable and implemented. No compatibility fact has been
observed against the vendor it describes, which needs a live credentialed endpoint and expires when
the vendor changes. The two words are not interchangeable about this profile.

The two decoders each carry their own copy of the `protocol` and `version` checks, and only the
agent-control one had tests for them until a mutation run over the provider decoder found the copy
unverified. That is a structural trap rather than a testing gap: each file reads as covered because
the other file's tests cover its own copy, and mutating either file alone never reveals it. The same
shape produced a duplicate `model_ref` parser in this profile, where three tests covered the copy
`inference.create` never reaches. When a rule exists twice, coverage of one instance says nothing
about the other, and the tests are attached to the wrong artifact to tell you so.

Mutation results for the provider decoder, as a baseline for anyone changing it: 49 single-line
refusals, 29 killed, 20 surviving. That is 49 of the 68 `return DecodeError` sites in the file --
the other nineteen are `orelse return DecodeError.MissingField`, which has no neutralising mutation
because removing the return needs a type-appropriate default that does not exist. Those nineteen
are unmeasured, not verified, and reading "49 guards swept" as "the decode surface is covered" is
the same mistake as believing a descriptor that under-claims. The killed set contains every rule the profile makes normative.
The survivors are type tags guarding a union field access — malformed-input robustness, which the
profile does not specify and which was correct but unverified rather than wrong. Recording which
test kills each mutant matters as much as the count: a rule killed only by a generically named test
reads as uncovered to anyone scanning test names, which is how the rule that a `wire_id` may
accompany only the `other` wire came to be verified by a test about JSON types.

## Deferred scope

Not claimed by this ledger, each requiring a spec revision plus OAP coordination
before implementation: transcript persistence and load; resume attachment; event
replay with cursors; endpoint/participant identity; run-scoped cancellation;
queue/steer/btw delivery; negotiated capabilities; multi-connection session
ownership; admission receipts and stable run/submission identity.
