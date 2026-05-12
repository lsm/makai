#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "[patterns] checking runtime catch unreachable usage..."
all_catch_unreachable="$(grep -Rns "catch unreachable" zig/src || true)"
if [[ -n "$all_catch_unreachable" ]]; then
  runtime_catch_unreachable="$(printf "%s\n" "$all_catch_unreachable" \
    | grep -vE "^[^:]+:[0-9]+:\s*//" \
    | grep -v "zig/src/utils/retry.zig" || true)"
  if [[ -n "$runtime_catch_unreachable" ]]; then
    echo "[patterns] unexpected runtime 'catch unreachable' found:" >&2
    echo "$runtime_catch_unreachable" >&2
    echo "[patterns] prefer oom.unreachableOnOom(...) or explicit error handling" >&2
    exit 1
  fi
fi

echo "[patterns] checking direct std.crypto.random usage..."
all_crypto_random="$(grep -Rns "std\.crypto\.random" zig/src || true)"
if [[ -n "$all_crypto_random" ]]; then
  crypto_random_violations="$(printf "%s\n" "$all_crypto_random" \
    | grep -v "zig/src/compat/random.zig" \
    | grep -vE "^[^:]+:[0-9]+:\s*//" || true)"
  if [[ -n "$crypto_random_violations" ]]; then
    echo "[patterns] direct std.crypto.random usage found:" >&2
    echo "$crypto_random_violations" >&2
    echo "[patterns] use compat.random secure/ordinary helpers instead" >&2
    exit 1
  fi
fi

secure_random_files=(
  "zig/src/oauth/pkce.zig"
  "zig/src/utils/oauth/pkce.zig"
  "zig/src/oauth/openai_codex.zig"
  "zig/src/oauth/google_gemini_cli.zig"
  "zig/src/oauth/google_antigravity.zig"
  "zig/src/transports/websocket.zig"
  "zig/src/protocol/provider/types.zig"
)

for file in "${secure_random_files[@]}"; do
  if grep -nE "compat\.random\.(fillRandomBytes|randomBytes|randomIntRangeLessThan|int)\b|\.random\(" "$file" >/dev/null; then
    echo "[patterns] security-sensitive random path uses ordinary entropy in $file" >&2
    grep -nE "compat\.random\.(fillRandomBytes|randomBytes|randomIntRangeLessThan|int)\b|\.random\(" "$file" >&2
    echo "[patterns] use compat.random secure helpers / io.randomSecure for OAuth, WebSocket, and protocol IDs" >&2
    exit 1
  fi
done

echo "[patterns] checking deinit poisoning in critical types..."
required_files=(
  "zig/src/event_stream.zig"
  "zig/src/api_registry.zig"
  "zig/src/agent/agent.zig"
  "zig/src/protocol/provider/client.zig"
  "zig/src/protocol/provider/server.zig"
  "zig/src/tool_call_tracker.zig"
  "zig/src/streaming_json.zig"
  "zig/src/providers/sse_parser.zig"
  "zig/src/protocol/provider/partial_reconstructor.zig"
)

for file in "${required_files[@]}"; do
  if ! grep -q "self\.\* = undefined;" "$file"; then
    echo "[patterns] missing deinit poisoning in $file" >&2
    exit 1
  fi
done

echo "[patterns] ok"
