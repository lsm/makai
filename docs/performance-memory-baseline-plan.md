# Performance and Memory Baseline Plan

## Finding

Makai currently has no repeatable, repository-owned performance or memory baseline. It has strong
unit and mock-E2E coverage, and `scripts/websocket-poc-gate.sh` defines a JSON comparison gate for
WebSocket latency and throughput. That script has no benchmark producer, does not record memory,
and is intended for a future interop POC rather than ordinary refactoring.

We should establish a baseline before speculative buffering, ownership, allocation, or hot-streaming
performance refactors. Correctness limits and their deterministic parser tests may proceed after the
lighter Step 0 baseline in the reliability plan; the full Phase A baseline is required before using
measurements to justify pooling, zero-copy, or similar optimization. The baseline must measure the
same work on every revision, avoid provider/network variance, and make regressions explainable.

## What to measure

Use two metric classes. Do not substitute one for the other.

| Metric | Meaning | First-tranche collection |
|---|---|---|
| `throughput_ops_per_sec` | Completed operations divided by measured wall time. | Yes |
| `latency_ns` (median, p95, p99) | Per-operation latency distribution. | Yes |
| `allocations` / `frees` | Heap allocation churn in the workload. | Yes |
| `allocated_bytes` / `freed_bytes` | Requested heap traffic; useful for comparing copies. | Yes |
| `live_bytes_peak` | High-water mark of requested bytes still live through the workload. | Yes |
| `leak_bytes` | Requested bytes still live when the workload ends. | Yes—must be zero for a closed workload |
| `peak_rss_bytes` | Process-level resident memory including stacks, allocator metadata, and runtime. | Local/nightly only initially |
| CPU counters / flamegraphs | Attribution of a measured regression. | On demand, not a CI baseline metric |

Allocation metrics reveal work introduced by a clone or `ArrayList` growth. RSS answers a different
question—what the OS retained—and varies substantially with the allocator and host. Keep them
separate in reports.

## First workloads

The baseline should be offline and deterministic. External providers measure remote model and
network behavior, not Makai changes.

| ID | Workload | Primary metrics | Why it comes first |
|---|---|---|---|
| `sse_parse` | Parse a fixed representative event fixture with a fixed sequence of chunk boundaries. | events/s, bytes/s, latency, allocations, peak live bytes | Every streaming provider relies on this parser; it is the first bounded-framing target. |
| `transport_round_trip` | Serialize then deserialize representative event/result/control fixtures. | messages/s, latency, allocations, peak live bytes | Exercises the high-copy protocol boundary without I/O variance. |
| `event_stream` | One producer/one consumer and a bounded multi-producer scenario using a trivial fixed-size event. | events/s, p99 latency, queue-full count | Protects the fixed-capacity concurrency core without measuring string ownership. |
| `websocket_frame` | Decode/encode fixed text, control, and fragmented fixtures using an in-memory scripted stream. | frames/s, latency, allocations, peak live bytes | Establishes a baseline before touching receiver/fragment limits. |

Fixtures must include small, typical, and deliberately large-but-supported payload classes. They
must be versioned locally, scrubbed of credentials and user content, and report their byte sizes.
Do not benchmark invalid/over-limit input as a normal throughput workload; cover it in tests.

## Minimal design

### 1. A standalone benchmark executable

Add a `zig build bench` step with explicit workload selection, for example:

```sh
cd zig
zig build bench -- --workload sse_parse --sample-count 15 --warmup-ms 500 --measure-ms 2000 \
  --json ../artifacts/bench/sse-parse.json
```

The executable should not run under `zig test`, make network calls, require API keys, or print a
human-oriented stream on stdout when `--json` is selected. A text summary can go to stderr.

### 2. A workload-scoped `CountingAllocator`

Implement a small allocator wrapper around the normal benchmark backing allocator. It must record
only the requested allocation sizes visible through `std.mem.Allocator`:

* allocation and free call counts;
* allocated, freed, current-live, and peak-live bytes;
* resize/remap deltas correctly;
* zero current-live bytes at a workload's normal completion.

This wrapper is measurement infrastructure, not a production allocator. Keep its implementation
and tests separate from `zig/src/` runtime ownership code. Record that it changes timing, which is
why allocation measurements and latency measurements should run as separate modes if its overhead
is material.

### 3. A stable timer and sampling protocol

Use a monotonic timer. Warm up first, run a fixed number of measurement samples, and emit every
sample in JSON; calculate median/p95/p99 only from measured samples. Record the iteration count and
bytes processed so readers can identify a workload that accidentally did less work. Each sample must
also validate the workload's expected result outside the timed interval: an expected event/message
count plus a content digest, or round-trip equality as appropriate. Reject a sample whose semantic
result is wrong even if its iteration and byte counts look complete.

The harness must pin the fixture identity, chunk schedule, concurrency, Zig version, optimization
mode, measurement mode (allocation or latency), host class, and workload parameters in its output.
It should reject a zero iteration count, an incomplete run, or a failed semantic validation.

### 4. JSON report and comparison tool

Store one report per execution, never overwrite a named source baseline. Minimum schema:

```json
{
  "schema_version": 1,
  "git_revision": "...",
  "zig_version": "0.16.0",
  "target": "...",
  "optimization": "ReleaseFast",
  "host": { "class": "...", "os": "...", "arch": "...", "cpu_model": "..." },
  "measurement_mode": "latency",
  "workload": { "id": "sse_parse", "fixture_hash": "...", "fixture_bytes": 0, "chunk_schedule": "...", "concurrency": 1, "parameters": {} },
  "samples": [{
    "iterations": 0,
    "input_bytes": 0,
    "elapsed_ns": 0,
    "operation_latency_ns": [],
    "semantic_validation": { "passed": true, "expected_output_count": 0, "output_count": 0, "output_digest": "..." },
    "allocation": null
  }],
  "summary": {
    "throughput_ops_per_sec": 0,
    "latency_ns": { "p50": 0, "p95": 0, "p99": 0 },
    "allocation": null
  }
}
```

`allocation` is `null` in latency mode, where the counting allocator is intentionally disabled;
when `measurement_mode` is `allocation`, it contains `allocation_count`, `free_count`,
`allocated_bytes`, `freed_bytes`, `live_bytes_peak`, and `leak_bytes`. The summary follows the same
rule so an unmeasured memory metric is never reported as zero.

Add a comparison script that rejects mismatched schema, fixture identity, workload ID/parameters,
chunk schedule, concurrency, target, optimization, Zig version, measurement mode, or host class.
For fixed-duration samples it compares allocation counts and bytes normalized per completed
operation (and, where applicable, per input byte), rather than raw totals. Alternatively an
allocation-only mode may execute the same fixed amount of work in every sample. It reports relative
deltas and fails if a collected `leak_bytes != 0`; it does not treat `null` allocation metrics as
zero. It should *not* initially fail on a tiny timing delta; shared CI machines are noisy.

### 5. Optional process-RSS runner

Use a separate local or dedicated-host runner to execute each benchmark in a child process and
collect maximum RSS. On Linux, `/usr/bin/time -v` is a pragmatic first implementation; on macOS
use `/usr/bin/time -l`; a future portable Zig runner can obtain child resource usage. RSS output is
host-qualified and should not be compared across operating systems or allocator configurations.
Each platform adapter must normalize its native result to `peak_rss_bytes` before writing JSON; GNU
`time -v` reports maximum RSS in KiB, so its value must be multiplied by 1024 rather than emitted
directly as bytes.

## Reproducibility rules

* Commit fixtures, workload parameters, schema, and comparison code.
* Use `ReleaseFast` for the performance baseline and report the mode; retain a debug/test mode only
  for validating harness correctness.
* Compare only runs made with the same report identity: dedicated host class, target, Zig version,
  optimization and measurement modes, fixture hash, chunk schedule, concurrency, and workload
  parameters. Disable CPU turbo/power-saving variance where the benchmark host permits it.
* Run at least 15 samples after warm-up. For p95/p99, collect at least 100 independent per-operation
  timings in each measured sample and document the aggregation method; do not present a percentile
  calculated from one per-window observation as a tail-latency metric.
* Make the benchmark process single-purpose: no API calls, background model traffic, or build work
  inside the measured interval.
* Save raw JSON artifacts for a baseline and every proposed optimization. A chart without raw data
  is not a baseline.

## Rollout: effort and decision gates

### Phase A — useful baseline (target: the first 20%)

1. Define the schema and two deterministic fixtures (`sse_parse`, `transport_round_trip`).
2. Implement the benchmark executable, timer, warm-up/sampling loop, JSON writer, and a tested
   counting allocator.
3. Add a local `bench` build step and documented commands.
4. Capture a named baseline on one identified development/performance host.
5. Add a comparison script that produces a human-readable table and validates schema/leaks.

**Stop gate:** the reports are reproducible, the two workloads detect an intentional extra copy,
and a clean workload reports zero live bytes. At this point we can safely evaluate allocation or
ownership optimizations such as pooling or zero-copy. The correctness-limit work may proceed under
the reliability plan's Step 0 baseline; do not expand this harness merely for completeness.

### Phase B — only after Phase A proves useful

1. Add `event_stream` and `websocket_frame` workloads.
2. Add a dedicated scheduled performance host/runner that uploads JSON artifacts but does not gate
PRs yet.
3. Calibrate regression thresholds from observed variance, then gate only material regressions
(for example a sustained >10% throughput/latency change plus no justified workload change).
4. Add process RSS collection on the dedicated host.

### Phase C — diagnostic tooling, on demand

Use a profiler or flamegraph only after a baseline identifies a material regression. Retain the
report and the command used to generate it with the optimization PR. Do not make profiling a
mandatory CI dependency.

## What this takes

| Work | Estimated scope | Main risk controlled |
|---|---|---|
| Phase A harness, allocator, two workloads, reports, docs | One focused engineering PR; roughly a few days including calibration and review. | Measuring a fake or irreproducible workload. |
| First named baseline | One controlled local/dedicated-host run and artifact review. | Treating a laptop or shared-runner result as a universal threshold. |
| Phase B automation | A separate infrastructure PR after variance is understood. | Flaky CI and misleading performance gates. |

The important cost is not the timer or JSON writer; it is choosing fixtures that represent the
work we will optimize and preserving their comparability. Phase A deliberately avoids provider E2E,
full-agent runs, RSS portability, and automatic PR failure so that it gives decision-quality data
quickly.

## Relationship to existing work

`DESIGN.md` already requires objective WebSocket POC metrics and
`scripts/websocket-poc-gate.sh` validates a baseline/candidate JSON pair. The new harness should
reuse compatible field names where reasonable, but its general workload schema should not be bent
around the WebSocket POC's 25% improvement gate. First establish measurement validity; only then
decide a workload-specific threshold.

The baseline is a prerequisite to speculative pooling or zero-copy work in the reliability plan.
It is not a prerequisite to adding correctness limits and parser tests, but those changes should
capture a before/after report once Phase A exists.
