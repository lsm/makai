# Phase A performance and memory baseline

The Phase A harness measures two deterministic, offline workloads before allocation-focused refactoring:

- `sse_parse` feeds a fixed SSE fixture through stable, uneven chunk boundaries.
- `transport_round_trip` serializes and deserializes fixed control and string-bearing provider-protocol envelopes.

Run latency and allocation collection separately from `zig/` with an optimized build:

```bash
zig build bench -Doptimize=ReleaseFast -Dgit-revision=$(git rev-parse HEAD) -- --mode latency --samples 100 --iterations 10000 --host-class mac-arm64
zig build bench -Doptimize=ReleaseFast -Dgit-revision=$(git rev-parse HEAD) -- --mode allocation --samples 100 --iterations 1000 --host-class mac-arm64
```

Each workload emits one JSON object. The transport workload includes small control, typical result, and deterministic 64 KiB result payload classes. Preserve the output as the baseline artifact, then compare it with a candidate collected using the same command:

```bash
zig build bench-compare -Doptimize=ReleaseFast -- baseline.json candidate.json
```

The versioned report records the source revision, host class, complete target identity (architecture, OS, ABI, CPU model, and feature-set hash), Zig version, optimization mode, measurement mode, fixture version, a workload hash derived from the actual fixtures (including the SSE chunk schedule), workload parameters, bytes and completed work per iteration, raw measurement-window timings, p50/p95/p99 window-average latency, and a semantic digest. These percentiles describe throughput-window averages, not independent per-operation tail latency. Latency mode reports allocation fields as `null`; it never implies that zero allocations occurred. Allocation mode uses `CountingAllocator` and fails if live bytes remain after a workload. The comparison command accepts schema version 1 only, requires both workloads exactly once, rejects differing identities, zero-work reports, or semantic results, and reports window-average latency statistics plus allocation count, free count, allocated bytes, freed bytes, and peak live bytes normalized by completed work. `--samples` is capped at 10,000 so generated reports remain within the comparator's input limit.

For a harness sanity check, add `--extra-copy` to candidate allocation collection. Both workloads will report increased allocated bytes without changing their semantic digest; do not use this diagnostic flag for a real baseline.

Use a stable, explicit host class for tracked baselines. Do not compare `local` reports from unrelated machines, and avoid running latency collection alongside other CPU-heavy work. Re-run a noisy sample before drawing conclusions; this Phase A harness is a regression tripwire, not a general-purpose microbenchmark framework.

## Canonical capture

Run the **Capture Benchmark Baseline** workflow manually on the revision that will serve as the comparison baseline. It uses the pinned `ubuntu-24.04` x86_64 runner class, validates each JSON Lines report with `bench-compare`, and retains the raw reports, validation summaries, revision, and host class for 90 days. The artifact name includes the full source revision and runner class.

The same capture can be reproduced locally from the repository root:

```bash
./scripts/capture-benchmark-baseline.sh artifacts/benchmark <stable-host-class> [git-revision]
```

Only compare artifacts whose report identities and workload parameters are compatible. Baseline capture is informational: it does not define or enforce a merge threshold.

## Pull request reports

The **Benchmark Report** workflow runs on pull requests using the same pinned runner class and capture parameters. It locates the latest successful manual baseline run on `main`, validates the candidate reports, adds a human-readable latency and allocation comparison to the workflow summary, and retains the raw candidate reports for 30 days.

This job is intentionally non-blocking while variance is calibrated. A missing canonical baseline is reported with instructions and still produces candidate artifacts; an incompatible report identity is surfaced in the workflow rather than silently compared.
