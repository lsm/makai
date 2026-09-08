# Makai OAP Alignment Ledger

Status: deviations ledger and convergence contract between makai's agent-protocol
semantics and the Open Agent Protocol (OAP) agent-control core. This is the document
OAP adapter #3 (lsm/open-agent-protocol#3) maps makai against.

Normative counterpart: `v1-sdk-agent-provider-spec.md` §13 ("Session Lifecycle &
Frame Routing, V1.1") defines the semantics summarized here.

## Provenance

- Makai pins: `lsm/makai` `main` @ `1413ef7` ("fix(sdk): in_reply_to-aware waiter
  routing in the stdio transport (#207)") for the §13.3 routing claims, and
  `lsm/makai` `main` @ `bad82f0c` ("feat(agent): server-side idle-session TTL
  eviction (#202) (#206)") for the §13.2.6-rule-6 eviction claims. The
  session-lifecycle pass itself was verified against `67ad514`
  ("fix(agent): send agent_stop on session teardown — terminal, error, and
  auth-retry paths (#200)"). Every `[current]` claim in §13 and every status
  below was verified against one of these revisions.
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
  protocols are out of scope until their own passes.

Feedback rule (from lsm/open-agent-protocol#3): an adapter mismatch resolves as
either an OAP revision (issue/decision on lsm/open-agent-protocol) or a makai fix
(issue on lsm/makai) — never silent adapter-side compensation. Cross-reference issue
numbers in both directions.

## Identity domains

| Makai identity | OAP identity | Status | Rule |
| --- | --- | --- | --- |
| envelope `session_id` + payload `session_id` / `resume_session_id` | `session_id` | aligned (semantics), `renamed` (wire key) | Correlation + session-container key only; never a resume/replay handle (#198). OAP `session.open` returns a stable id; makai's `agent_start`/`agent_started` pair plays that role. |
| envelope `message_id` / `in_reply_to` | envelope `id` / `in_reply_to` | aligned | `in_reply_to` references the request envelope's `message_id` only; set on synchronous replies, absent on async run output. |
| envelope `sequence` | `sequence` | deviating: scope | Makai: per-direction, per-session. Inbound consumption is accepted-only: each ACCEPTED `agent_message` advances the counter (an accepted `agent_stop` removes it with the session); rejected requests and the non-consuming request types (`agent_status`, `ping`, `tool_list`, `models_request`, `goodbye` — accepted silently, no teardown, no reply) never advance it. Outbound has two frame classes: allocated frames draw a monotonic counter scoped to the session-container registration (a re-registered id restarts) — monotonic ABSENT allocation failure (`nextOutgoingSequence` ignores its map-update failure, so duplicate values are possible under memory pressure, #204) — while echo replies (`session_info`, `pong`, `tool_list_response`) copy the inbound sequence verbatim and validation errors carry 0 — a permanent deviation (decision (b) of #204; see the deviations ledger entry on echo-reply sequencing). OAP v0.1: run-scoped, positive, contiguous, and requests/responses do not consume it. Adapters must renumber per OAP run sequence from native receive order and must not order echo replies by sequence. |
| provider `stream_id` / auth `flow_id` | none (binding-private) | aligned by analogy | Correlation values private to their adjacent protocols on the same connection; never OAP identities (OAP Decision 0001 keeps native IDs out of portable identity). |
| payload `tool_call_id` | `tool_call_id` | deviating: uniqueness scope | Correlates concurrently in-flight calls only. Ids originate from provider output and the server keeps no session-wide registry — a provider may reuse a value across turns or runs of one session. Adapters must not key tool history by bare `tool_call_id` (namespacing or per-run scoping required). |
| — | `endpoint_id`, `participant_id` | absent (deviation) | Makai has no endpoint or participant identity; the transport connection is implicit and there is exactly one server per stdio process. Affects reverse-interaction ownership: `tool_execute` is the only server-initiated request and its ownership is implicitly "the session's client." |

## Deviations ledger

Statuses: `aligned` · `renamed` · `deviating: reason` · `absent by design`.

| OAP term | Makai construct | Status | Notes |
| --- | --- | --- | --- |
| `session_id` (stable session scope) | agent session container keyed by NanoID session id | aligned; wire key `renamed` (#198) | Multi-message containers by design (`publishAgentResult` → `.ready`); no persistence, so stability is process-lifetime only. |
| endpoint / participant identity | none | deviating: no endpoint or participant exists to address | Required for OAP initialization and reverse-interaction ownership; a makai introduction needs its own spec pass. |
| `submission_id` / `run_id` split | none — one `agent_message` per run in SDK usage | absent by design (v1) | No admission receipt: `agent_message` has no synchronous reply. A run is identified operationally by `(session_id, settlement frame)`. Candidate future revision if the adapter needs stable run identity; nothing queued. |
| `message_id` / `in_reply_to` / `sequence` | envelope fields of the same names | aligned (`in_reply_to`), deviating: sequence scope (see identity table) | Per §13.1/§13.3. |
| monotonic outbound `sequence` across ALL server frames | allocated frames draw the per-session counter; echo replies (`session_info`, `pong`, `tool_list_response`) copy the request's inbound sequence verbatim and request-validation `agent_error` envelopes carry `sequence: 0` | deviating: permanent — echo replies | Decision (b) of #204: the echo is kept deliberately. It is a correlation echo (a consumer can match a reply to its request by sequence without `in_reply_to`), not an ordering allocation; re-allocating echo replies from the per-session counter (option (a)) would break any consumer relying on that echo and buy only cross-class monotonicity, which consumers are already forbidden to assume (§13.1: "consumers MUST NOT order echo replies against allocated frames by sequence"). Adapters renumber per OAP run sequence from native receive order and never order echo replies by sequence. |
| admission (`session.message.submit.response` before stream) | server ACCEPTS `agent_message` by enqueueing it; rejected writes (unknown session / bad sequence / `.processing`) return a request-correlated validation `agent_error` and admit nothing | deviating: no admission receipt | OAP separates "the endpoint accepted the submission" from execution; makai acceptance has no positive frame — observable only through subsequent run output on an EXCLUSIVE, quiescent route (shared/reused-id output is uncorrelated and can belong to another run, §13.3.2) or the PROBABILISTIC absence of a correlated rejection (an allocation failure in the acceptance path escapes without one), so adapters MUST bound waits and treat expiry as an unknown outcome (§13.4.1/§13.4.6). |
| settlement (exactly one terminal per accepted run) | `agent_result` frame for both `run()` and `stream()` (the SDK projects it into the terminal `agent_end` event); loop-internal failure = the `agent_event`(error) + settlement `agent_error` pair counted as ONE settlement; provider-originated failure (auth/network/URL) = an error-valued `agent_result` (`stop_reason: "error"` + `error_message`) — classified by payload, not frame type | aligned for natural outcomes; deviating: cancelled runs | A run cancelled by `agent_stop` produces NO run settlement frame — the session is removed and the cancelled run's later publications are discarded; the `agent_stopped` reply is the client's only terminal (unless that reply's own publication fails — gap 5: the session is removed before the reply is built, and a failure can also strike the direct synchronous write of an already-built reply outside the outbox, skipping run cancellation and tool-bridge cleanup with it). No OAP `run.cancelled` equivalent exists. §13.4.2/§13.4.4. |
| single terminal arbiter (children settle first; duplicate terminals suppressed) | run pump settles result XOR error; trailing `agent_end` held until after `agent_result` | aligned, with known deviations | §13.4.3. Residual races/failures: a stopped (or evicted) session's cancelled run can no longer publish into a re-created id — registration generations (#204) bind each run to the registration it was admitted under and discard stale publications (no events, no settlement, no state mutation; a listed stale run no longer fails the fresh registration's run start with `agent_busy`) — but frames the OLD registration already buffered downstream (outbox, pipe, stdout) carry no generation on the wire and remain attributable to the new registration until drained (§6.1); under memory pressure a run can emit NO settlement (swallowed result-publication OOM) or re-emit its terminal projection repeatedly (mid-pair OOM leaves the run queued) — exactly-once terminal behavior is not provided under publication failure (#204 gap 5). |
| `run.cancel` (run-scoped; intent ≠ settlement; races defined) | `agent_stop` — session-scoped teardown that also cancels the in-flight run | deviating: cancellation is session-scoped, not run-scoped | No mid-message run-scoped cancel in v1; a cancelled run emits no run settlement frame (see settlement row). Per OAP Decision 0001's consequence, session-scoped cancellation forces one foreground run per session — makai enforces exactly that (`agent_busy` on duplicate start and on message-to-processing-session). Idle-TTL eviction (§13.2.6, #202) never selects sessions with in-flight runs, and where a removal does land under a live run the host cancels it exactly as stop does. |
| run statuses (`queued`/`running`/`waiting_for_input`/`cancelling`/terminals) | `AgentStatus` (starting/ready/processing/waiting_for_tool/stopping/stopped/error) | renamed + partial: session-level, not run-level; declared ≠ observable | The stdio runtime only ever assigns `ready` → `processing` → `ready` \| `error` (stop removes the entry outright): `starting`, `waiting_for_tool`, `stopping`, and `stopped` are declared enum values no host currently emits — adapters MUST NOT wait on them. No cancelled/failed terminal distinction at the status level; failure is carried by settlement frames (§3.5), not session status. |
| state reconciliation (`session.state`) | `agent_status` → `session_info` | deviating: counters only | Returns status, model, message_count, timestamps — no transcript cursor, no authoritative transcript. Not a recovery source of truth. |
| transcript load | none | absent by design | §13.5; client supplies full history in `messages` every call. |
| resume (attachment without history) | none | absent by design | §13.5; a reused session id creates a fresh container or is rejected `agent_busy` — never restores state. The wire key `resume_session_id` is a historical misnomer (#198). |
| replay (canonical events from cursor) | none | absent by design | §13.5/§12; no journal, cursor, or gap reporting. An adapter may journal its own canonical output (degraded replay per OAP rules) but must not claim native replay. |
| capability negotiation (revisioned descriptors) | implicit probing (`not_implemented` nack) | deviating: no negotiated capabilities | Spec §9. Adapters synthesize OAP capability revisions from probe results + policy, as the ACP ledger does. |
| delivery modes `queue`/`steer`/`btw` | none — `agent_busy` on concurrent delivery | absent by design | §13.2.4; OAP optional units, unavailable here. |
| envelope shape | flat envelope: `version`, `type`, `session_id`, `message_id`, `sequence`, `in_reply_to`, `timestamp`, `payload` | aligned structurally | OAP's envelope adds `protocol`/`profile` strings and scope fields (`run_id`, `turn_id`, …) makai does not carry; mapping is mechanical for the adapter. |
| process exit before settlement | transport rejects the registered frame wait; reads queued behind the transport read lock surface the death as their response timeout; no fabricated result | aligned | "Failure, never success" — §13.4.6, matching the ACP ledger's process-exit rule; adapters must keep timeout handling for lock-queued reads rather than expecting prompt rejection for every concurrent request. |
| stdin EOF while a run waits on a distributed `tool_result` | server process stays alive; the client observes silence until its response timeout | deviating: tracked (#204 gap 4) | The tool wait has no EOF-triggered cancel (`makai.zig` `executeStdioToolViaAgentProtocol` polls until result or run-cancel), so the process and its sessions hang indefinitely (§13.2.7); client frame waits are rejected only on process exit, so this case surfaces as timeout, not a prompt terminal. |

## P0 makai follow-ups (queued)

These implement the `[planned]` rules of spec §13; each lands as its own PR:

1. #201 — LANDED: `in_reply_to`-aware frame routing in the transport (implements
   §13.3.1; `correlate` wait option, reply-queue parking for registered requests,
   SDK correlation of each attempt's `agent_start` `message_id` plus a
   pre-acceptance `agent_started` correlation check). Overlapping same-session
   calls now each receive their own replies; the pre-#201 modes (duplicate
   timing out, established run destroyed, wrong request proceeding) are closed.
2. #204 — server enforcement gaps the spec marks `[planned]`. LANDED (first
   slice): envelope/payload session-id agreement rejection (all four
   session-scoped handlers plus the stdio host's stop validation), the
   echo-reply sequence decision — decision (b): echo kept as a permanent
   deviation, see the deviations ledger — and the session generation counter
   so a stopped OR evicted session's cancelled run cannot settle a re-created
   id (stale-generation publications discarded; a listed stale run no longer
   fails the fresh id's run start with `agent_busy`). Still open: EOF /
   disconnect-triggered cancellation of active runs (the distributed-tool EOF hang),
   settlement on result-, failure-pair-, correlated-stop-reply-, or tool-request-
   publication failure instead of the swallowed/propagating OOM (settle or
   propagate once, never re-publish a processed terminal; tool-request
   publication, outbox delivery, the final pipe-to-stdout drain, and ORDINARY
   event publication are all transactional — a popped envelope is dropped on
   serialization/write failure, the stdio drain advances its pipe position before
   buffering (failures swallowed), and a dropped `agent_event` is never
   reconstructed, silently truncating a stream that still settles successfully;
   the stop transaction includes tool-bridge cleanup, and for a result the run is
   already removed, leaving no settlement and nothing to retry — transactionality
   extends through the final pipe-to-stdout handoff: the stdio drain advances the
   pipe read position before its buffer append, and a failure there is swallowed,
   dropping an already-delivered frame), and
   stale-`tool_result` correlation for reused
   `tool_call_id`s (validate `in_reply_to` against the current `tool_execute`) —
   plus gap 7: client sequence control in BOTH clients — `AgentProtocolClient`
   (rollback on rejected sends or explicit-sequence sends) and the TypeScript SDK
   (its tracker advances before the outcome is known) — where "control" includes
   bounded probing of BOTH counter states after an uncorrelated outcome (pre-send,
   then post-send on a correlated `invalid_request`): rollback alone is wrong when
   the message was actually accepted and output was merely delayed or lost.
   Without it, same-sequence retries and unknown-outcome cleanup are unsupported.
3. #205 — TS SDK teardown guards: ownership-evidence stop on unknown start
   outcomes — per §6.1's raised bar, an EXCLUSIVE, never-reused client-generated id
   is the only sufficient evidence until #204 supplies generation tokens (a buffered
   correlated `agent_started` can outlive removal and re-registration of the id and
   authorize a stop of the NEW session) — a mandatory drain (or
   correlation/generation discard) of the failure pair's second frame before id
   reuse, and independent tool-execution tracking for the `auto_once` retry gate
   (§13.5.3: a tool executed while its lifecycle events were dropped by a
   publication failure is invisible to the yielded-event gate, so a retry can
   duplicate its side effects).
4. #198 — rename the `agent_start` payload key `resume_session_id` → `session_id`
   (wire change; semantics already fixed by §13.1/§13.5 — the rename rests on them).

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

## Deferred scope

Not claimed by this ledger, each requiring a spec revision plus OAP coordination
before implementation: transcript persistence and load; resume attachment; event
replay with cursors; endpoint/participant identity; run-scoped cancellation;
queue/steer/btw delivery; negotiated capabilities; multi-connection session
ownership; admission receipts and stable run/submission identity.
