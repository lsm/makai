# Makai OAP Alignment Ledger

Status: deviations ledger and convergence contract between makai's agent-protocol
semantics and the Open Agent Protocol (OAP) agent-control core. This is the document
OAP adapter #3 (lsm/open-agent-protocol#3) maps makai against.

Normative counterpart: `v1-sdk-agent-provider-spec.md` §13 ("Session Lifecycle &
Frame Routing, V1.1") defines the semantics summarized here.

## Provenance

- Makai pin: `lsm/makai` `main` @ `67ad514` ("fix(agent): send agent_stop on session
  teardown — terminal, error, and auth-retry paths (#200)"). Every `[current]` claim
  in §13 and every status below was verified against this revision.
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
| envelope `sequence` | `sequence` | deviating: scope | Makai: per-direction, per-session. Inbound consumption is accepted-only: each ACCEPTED `agent_message` advances the counter (an accepted `agent_stop` removes it with the session); rejected requests and the non-consuming request types (`agent_status`, `ping`, `tool_list`, `models_request`) never advance it. Outbound has two frame classes: allocated frames draw a monotonic counter scoped to the session-container registration (a re-registered id restarts it), while echo replies (`session_info`, `pong`, `tool_list_response`) copy the inbound sequence verbatim and validation errors carry 0 (see #204). OAP v0.1: run-scoped, positive, contiguous, and requests/responses do not consume it. Adapters must renumber per OAP run sequence from native receive order and must not order echo replies by sequence. |
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
| admission (`session.message.submit.response` before stream) | server ACCEPTS `agent_message` by enqueueing it; rejected writes (unknown session / bad sequence / `.processing`) return a request-correlated validation `agent_error` and admit nothing | deviating: no admission receipt | OAP separates "the endpoint accepted the submission" from execution; makai acceptance has no positive frame — observable only through subsequent run output on an EXCLUSIVE, quiescent route (shared/reused-id output is uncorrelated and can belong to another run, §13.3.2) or the PROBABILISTIC absence of a correlated rejection (an allocation failure in the acceptance path escapes without one), so adapters MUST bound waits and treat expiry as an unknown outcome (§13.4.1/§13.4.6). |
| settlement (exactly one terminal per accepted run) | `agent_result` frame for both `run()` and `stream()` (the SDK projects it into the terminal `agent_end` event); loop-internal failure = the `agent_event`(error) + settlement `agent_error` pair counted as ONE settlement; provider-originated failure (auth/network/URL) = an error-valued `agent_result` (`stop_reason: "error"` + `error_message`) — classified by payload, not frame type | aligned for natural outcomes; deviating: cancelled runs | A run cancelled by `agent_stop` produces NO run settlement frame — the session is removed and the cancelled run's later publications are discarded; the `agent_stopped` reply is the client's only terminal. No OAP `run.cancelled` equivalent exists. §13.4.2/§13.4.4. |
| single terminal arbiter (children settle first; duplicate terminals suppressed) | run pump settles result XOR error; trailing `agent_end` held until after `agent_result` | aligned, with known deviations | §13.4.3. Residual races/failures: a stopped session's cancelled run can publish into the same id re-created by an immediate start (generation/tombstone pending #204); under memory pressure a run can emit NO settlement (swallowed result-publication OOM) or re-emit its terminal projection repeatedly (mid-pair OOM leaves the run queued) — exactly-once terminal behavior is not provided under publication failure (#204 gap 5). |
| `run.cancel` (run-scoped; intent ≠ settlement; races defined) | `agent_stop` — session-scoped teardown that also cancels the in-flight run | deviating: cancellation is session-scoped, not run-scoped | No mid-message run-scoped cancel in v1; a cancelled run emits no run settlement frame (see settlement row). Per OAP Decision 0001's consequence, session-scoped cancellation forces one foreground run per session — makai enforces exactly that (`agent_busy` on duplicate start and on message-to-processing-session). Eviction (#202) and stop share cancel semantics. |
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

1. #201 — `in_reply_to`-aware frame routing in the transport (implements §13.3.1;
   today the SDK correlates only pre-acceptance and the general case can misdeliver
   same-session replies).
2. #202 — server-side eviction: idle TTL with default + config knob, optional bounded
   map, `agent_not_found` semantics for evicted ids (implements §13.2.6). Ordering
   dependency: an admission racing a cap eviction MUST be closed server-side —
   #204's generation/tombstone tokens, or deferral of removal/re-registration until
   the cancelled run's publications cease — the client cannot observe the eviction
   to drain, so #202 MUST NOT ship without one of those protections.
3. #204 — server enforcement gaps the spec marks `[planned]`: envelope/payload
   session-id agreement rejection, consistent outbound sequencing for echo replies
   (`session_info`/`pong`/`tool_list_response`), session generation/tombstone so a
   stopped OR evicted session's cancelled run cannot settle a re-created id, EOF /
   disconnect-triggered cancellation of active runs (the distributed-tool EOF hang),
   settlement on result- OR failure-pair-publication failure instead of the
   swallowed/propagating OOM (settle or propagate once, never re-publish a
   processed terminal), and stale-`tool_result` correlation for reused
   `tool_call_id`s (validate `in_reply_to` against the current `tool_execute`) —
   plus gap 7: `AgentProtocolClient` sequence control (rollback on rejected sends
   or explicit-sequence sends), without which same-sequence retries through the
   built-in client are unsupported.
4. #205 — TS SDK teardown guards: ownership-evidence stop on unknown start
   outcomes — per §6.1's raised bar, an EXCLUSIVE, never-reused client-generated id
   is the only sufficient evidence until #204 supplies generation tokens (a buffered
   correlated `agent_started` can outlive removal and re-registration of the id and
   authorize a stop of the NEW session) — and a mandatory drain (or
   correlation/generation discard) of the failure pair's second frame before id
   reuse.
5. #198 — rename the `agent_start` payload key `resume_session_id` → `session_id`
   (wire change; semantics already fixed by §13.1/§13.5 — the rename rests on them).

Adapter mismatches discovered by OAP adapter #3 beyond these resolve per the feedback
rule above.

## Deferred scope

Not claimed by this ledger, each requiring a spec revision plus OAP coordination
before implementation: transcript persistence and load; resume attachment; event
replay with cursors; endpoint/participant identity; run-scoped cancellation;
queue/steer/btw delivery; negotiated capabilities; multi-connection session
ownership; admission receipts and stable run/submission identity.
