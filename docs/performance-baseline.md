# Phase A performance and memory baseline

The Phase A harness measures two deterministic, offline workloads before allocation-focused refactoring:

- `sse_parse` feeds a fixed SSE fixture through stable, uneven chunk boundaries.
- `transport_round_trip` serializes and deserializes fixed control and string-bearing provider-protocol envelopes.

Run latency and allocation collection separately from `zig/` with an optimized build:

```bash
zig build bench -Doptimize=ReleaseFast -Dgit-revision=$(git rev-parse HEAD) -- --mode latency --samples 100 --iterations 10000 --host-class mac-arm64
zig build bench -Doptimize=ReleaseFast -Dgit-revision=$(git rev-parse HEAD) -- --mode allocation --samples 100 --iterations 1000 --host-class mac-arm64
```

Each workload emits one JSON object. Preserve the output as the baseline artifact, then compare it with a candidate collected using the same command:

```bash
zig build bench-compare -Doptimize=ReleaseFast -- baseline.json candidate.json
```

The versioned report records the source revision, host class, complete target identity (architecture, OS, ABI, CPU model, and feature-set hash), Zig version, optimization mode, measurement mode, fixture version, a workload hash (including the SSE chunk schedule), workload parameters, raw timing samples, median/p95/p99 latency, completed work, and a semantic digest. Latency mode reports allocation fields as `null`; it never implies that zero allocations occurred. Allocation mode uses `CountingAllocator` and fails if live bytes remain after a workload. The comparison command accepts schema version 1 only, requires both workloads exactly once, rejects differing identities, zero-work reports, or semantic results, and reports robust latency statistics plus allocation count, free count, allocated bytes, freed bytes, and peak live bytes normalized by completed work. `--samples` is capped at 10,000 so generated reports remain within the comparator's input limit.

For a harness sanity check, add `--extra-copy` to candidate allocation collection. Both workloads will report increased allocated bytes without changing their semantic digest; do not use this diagnostic flag for a real baseline.

Use a stable, explicit host class for tracked baselines. Do not compare `local` reports from unrelated machines, and avoid running latency collection alongside other CPU-heavy work. Re-run a noisy sample before drawing conclusions; this Phase A harness is a regression tripwire, not a general-purpose microbenchmark framework.
