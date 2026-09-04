#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <output-directory> <host-class> [git-revision]" >&2
  exit 2
fi

output_directory=$1
host_class=$2
git_revision=${3:-$(git rev-parse HEAD)}

mkdir -p "$output_directory"
output_directory=$(cd "$output_directory" && pwd)

cd "$(git rev-parse --show-toplevel)"

zig build bench -Doptimize=ReleaseFast -Dgit-revision="$git_revision" -- \
  --mode latency --samples 30 --iterations 100 --host-class "$host_class" \
  > "$output_directory/latency.jsonl"
zig build bench -Doptimize=ReleaseFast -Dgit-revision="$git_revision" -- \
  --mode allocation --samples 15 --iterations 10 --host-class "$host_class" \
  > "$output_directory/allocation.jsonl"

# A report must be internally valid before it is retained as a baseline.
zig build bench-compare -Doptimize=ReleaseFast -- \
  "$output_directory/latency.jsonl" "$output_directory/latency.jsonl" \
  > "$output_directory/latency-summary.txt"
zig build bench-compare -Doptimize=ReleaseFast -- \
  "$output_directory/allocation.jsonl" "$output_directory/allocation.jsonl" \
  > "$output_directory/allocation-summary.txt"

printf '%s\n' "$git_revision" > "$output_directory/git-revision.txt"
printf '%s\n' "$host_class" > "$output_directory/host-class.txt"
