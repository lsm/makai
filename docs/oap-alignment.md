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
  (#208)") for the §6.1/§13.4.2 teardown-guard claims, and the #210 gap-7
  client sequence-control PR (rollback + bounded counter probing in both
  clients; update this pin with its merge sha on landing) for the §13.1
  client-side sequence-discipline and §13.4.1 cleanup-probing claims. The
  session-lifecycle pass itself was verified against `67ad514`
  ("fix(agent): send agent_stop on session teardown — terminal, error, and
  auth-retry paths (#200)"). The §13.1/§13.5 wire-key (rename) claims pin to the
  #198 rename's landing on `main` (the rename PR; update this pin with its merge
  sha on landing). Every `[current]` claim in §13 and every status
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
| `session_id` (stable session scope) | agent session container keyed by NanoID session id | aligned | Multi-message containers by design (`publishAgentResult` → `.ready`); no persistence, so stability is process-lifetime only. The `agent_start` payload key was renamed `resume_session_id` → `session_id` (#198); the old key is accepted as a permanent legacy alias (both makai clients emit it transitionally alongside the canonical key for the same reason). |
| endpoint / participant identity | none | deviating: no endpoint or participant exists to address | Required for OAP initialization and reverse-interaction ownership; a makai introduction needs its own spec pass. |
| `submission_id` / `run_id` split | none — one `agent_message` per run in SDK usage | absent by design (v1) | No admission receipt: `agent_message` has no synchronous reply. A run is identified operationally by `(session_id, settlement frame)`. Candidate future revision if the adapter needs stable run identity; nothing queued. |
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

## P0 makai follow-ups (queued)

These implement the `[planned]` rules of spec §13; each lands as its own PR:

1. #201 — LANDED: `in_reply_to`-aware frame routing in the transport (implements
   §13.3.1; `correlate` wait option, reply-queue parking for registered requests,
   SDK correlation of each attempt's `agent_start` `message_id` plus a
   pre-acceptance `agent_started` correlation check). Overlapping same-session
   calls now each receive their own replies; the pre-#201 modes (duplicate
   timing out, established run destroyed, wrong request proceeding) are closed.
2. #204/#210 — server enforcement gaps the spec marks `[planned]`. LANDED (first
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
   running even when the reply's own publication fails. LANDED (#210
   gap 7): client sequence control in BOTH clients — split across two PRs at
   review time (TS SDK half in #215; zig `AgentProtocolClient` + TUI half
   here, byte-identical to the tree both PRs reviewed before the split) — the
   `AgentProtocolClient`
   rolls its per-session counter back when a correlated `agent_error`/`nack`
   names the send (`processEnvelope` matches `in_reply_to` against the session's
   outstanding counter-advancing sends and rolls back to the minimum; a
   correlated `agent_not_found` drops the counter state instead), never
   advances the counter on stop sends (a rejected stop leaves the expected
   value in place for its retry), and exposes the control surface recovery
   paths need: `peekNextSequence`, `sendAgentMessageWithSequence`,
   `sendAgentStopWithSequence`, and `sendAgentStopProbing` — a bounded
   two-state probe (stop at the last admitted message send's PRE-send
   sequence; on a correlated `invalid_request` reply processed through
   `processEnvelope`, exactly one retry at the post-send value whose own
   replies are consumed identically; any other reply retires the probe, with
   `agent_not_found` clearing the tracked sequence state and marking the
   session complete; probe replies are consumed as cleanup mechanics, never
   session errors — and probing requires BOTH a recorded `agent_message`
   send AND an observed `agent_started` for the registration, else it sends
   NOTHING: without admission evidence a stop at the tracker's value would
   destroy a foreign owner's fresh session, §6.1). The TS SDK's tracker
   (`ActiveAgentSession`) marks the `agent_message` send unresolved at send,
   rolls back to the pre-send sequence on a correlated rejection, confirms
   the advanced counter on the first run output, and — while the outcome is
   unresolved — tears down with the same bounded probe
   (`stopAgentWithSequenceProbe`: pre-send stop, one
   correlated-`invalid_request` retry at the post-send value with
   correlated reads, acceptance at either settles; both `run()` and
   `stream()`, awaited on error paths so the probe's reads cannot race a
   same-id follow-up). Same-sequence retries and unknown-outcome cleanup
   are supported in both clients (§13.1/§13.4.1); the TUI's remote
   disconnect/cancel teardown routes through the probe first, with the
   plain tracked stop as the ineligible fallback (its ids are
   client-generated and exclusive, §6.1 — the fallback's optimistic
   sequence is the correct one exactly when the probe is ineligible).
   Review-hardened in the same slice: the TS teardown drains queued
   session output after the probe settles at EITHER outcome — correlated
   reads are served ahead of the session queue, so the reply resolving
   the probe can overtake still-parked late output, which an immediate
   same-id follow-up would otherwise claim as its own (§13.3.1); and the
   TUI defers a teardown-observed SSE receive disconnect to a pre-start
   reconnect on the next session (`remote_sse_reconnect_needed`), so the
   still-working SSE send side can no longer register a session whose
   reply dies on the dead stream while the disconnect recovery registers
   a second one, leaking the first until eviction.
   Residual, documented
   (§13.1): the admission gate cannot prove CURRENT-registration ownership of
   a caller-supplied id after a silent TTL eviction — eviction emits no
   frame, so a foreign re-registration and our own are wire-indistinguishable
   until the next request — the same residual class as §6.1/#205's
   buffered-`agent_started` evidence and §13.4.5's no-generation-on-the-wire
   caveat; closing it needs a client-visible registration generation (future
   wire revision). With gap 7 (TS SDK half #215, zig client + TUI here),
   every gap of #210 (4–7) has landed; the issue can close once both halves
   merge.
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

## Deferred scope

Not claimed by this ledger, each requiring a spec revision plus OAP coordination
before implementation: transcript persistence and load; resume attachment; event
replay with cursors; endpoint/participant identity; run-scoped cancellation;
queue/steer/btw delivery; negotiated capabilities; multi-connection session
ownership; admission receipts and stable run/submission identity.
