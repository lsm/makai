#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <metrics.json>" >&2
  exit 2
fi

metrics_file="$1"
if [[ ! -f "$metrics_file" ]]; then
  echo "metrics file not found: $metrics_file" >&2
  exit 2
fi

python3 - "$metrics_file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

required = (
    "p99_latency_ms",
    "throughput_msgs_per_sec",
    "reconnect_success_rate",
    "crash_count",
    "leak_count",
    "ordering_violations",
    "backpressure_failures",
)

def require_metrics(name):
    section = data.get(name)
    if not isinstance(section, dict):
        raise SystemExit(f"missing object: {name}")
    for key in required:
        if key not in section:
            raise SystemExit(f"missing metric: {name}.{key}")
    return section

baseline = require_metrics("baseline")
candidate = require_metrics("candidate")

if baseline["p99_latency_ms"] <= 0 or baseline["throughput_msgs_per_sec"] <= 0:
    raise SystemExit("baseline p99/throughput must be > 0")

reliability_ok = (
    candidate["crash_count"] == 0
    and candidate["leak_count"] == 0
    and candidate["ordering_violations"] == 0
    and candidate["backpressure_failures"] == 0
    and candidate["reconnect_success_rate"] >= 99.9
)

latency_ok = candidate["p99_latency_ms"] <= baseline["p99_latency_ms"] * 0.80
throughput_ok = (
    candidate["throughput_msgs_per_sec"]
    >= baseline["throughput_msgs_per_sec"] * 1.25
)
performance_ok = latency_ok or throughput_ok

if reliability_ok and performance_ok:
    print("GO: reliability gate passed and performance threshold met")
    sys.exit(0)

print("NO-GO: gate failed")
if not reliability_ok:
    print("- reliability thresholds not met")
if not performance_ok:
    print("- performance thresholds not met")
sys.exit(1)
PY
