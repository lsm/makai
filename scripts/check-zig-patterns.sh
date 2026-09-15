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

ordinary_entropy_pattern='compat\.random\.(fillRandomBytes|randomBytes|randomIntRangeLessThan|int)\b|\.random\(|std\.Random\.'

secure_random_files=(
  "zig/src/oauth/pkce.zig"
  "zig/src/utils/oauth/pkce.zig"
  "zig/src/utils/oauth/openai_codex.zig"
  "zig/src/transports/websocket.zig"
  "zig/src/protocol/provider/types.zig"
  "zig/src/tui/app.zig"
)

ordinary_entropy_files=(
  "zig/src/compat/random.zig"
  "zig/src/model_catalog.zig"
  "zig/src/utils/oauth/storage.zig"
  "zig/src/utils/tool_utils.zig"
  "zig/src/providers/sse_parser.zig"
  "zig/src/transports/transport_retry.zig"
  "zig/src/utils/retry.zig"
)

echo "[patterns] checking security-sensitive entropy call sites..."
for file in "${secure_random_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "[patterns] secure_random_files lists a path that does not exist: $file" >&2
    echo "[patterns] update scripts/check-zig-patterns.sh when entropy call sites move or are deleted" >&2
    exit 1
  fi
  if grep -nE "$ordinary_entropy_pattern" "$file" >/dev/null; then
    echo "[patterns] security-sensitive random path uses ordinary entropy in $file" >&2
    grep -nE "$ordinary_entropy_pattern" "$file" >&2
    echo "[patterns] use compat.random secure helpers / io.randomSecure for OAuth, WebSocket, and protocol IDs" >&2
    exit 1
  fi
done

echo "[patterns] checking ordinary entropy call sites are declared..."
for file in "${ordinary_entropy_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "[patterns] ordinary_entropy_files lists a path that does not exist: $file" >&2
    echo "[patterns] update scripts/check-zig-patterns.sh when entropy call sites move or are deleted" >&2
    exit 1
  fi
done

all_ordinary_entropy="$(grep -RnsE --include="*.zig" "$ordinary_entropy_pattern" zig/src || true)"
if [[ -n "$all_ordinary_entropy" ]]; then
  undeclared_ordinary_entropy="$all_ordinary_entropy"
  for file in "${ordinary_entropy_files[@]}"; do
    undeclared_ordinary_entropy="$(printf "%s\n" "$undeclared_ordinary_entropy" | grep -v "^$file:" || true)"
  done
  if [[ -n "$undeclared_ordinary_entropy" ]]; then
    echo "[patterns] ordinary entropy used outside the declared non-security call sites:" >&2
    echo "$undeclared_ordinary_entropy" >&2
    echo "[patterns] use compat.random secure helpers, or add the file to ordinary_entropy_files with rationale in the commit message" >&2
    exit 1
  fi
fi

echo "[patterns] checking compat.random secure wrapper bodies..."
compat_random_file="zig/src/compat/random.zig"
secure_wrappers=(
  "fillSecureBytes:randomSecure("
  "secureBytes:fillSecureBytes("
  "secureIntRangeLessThan:fillSecureBytes("
)

for wrapper in "${secure_wrappers[@]}"; do
  wrapper_fn="${wrapper%%:*}"
  wrapper_requires="${wrapper##*:}"
  wrapper_body="$(awk -v target="pub fn $wrapper_fn(" \
    'index($0, target) == 1 { inside = 1 } inside { print } inside && $0 == "}" { exit }' \
    "$compat_random_file")"

  if [[ -z "$wrapper_body" ]]; then
    echo "[patterns] secure wrapper $wrapper_fn not found in $compat_random_file" >&2
    echo "[patterns] update scripts/check-zig-patterns.sh when the compat.random secure helpers are renamed" >&2
    exit 1
  fi

  if ! printf "%s\n" "$wrapper_body" | grep -qF "$wrapper_requires"; then
    echo "[patterns] secure wrapper $wrapper_fn no longer calls $wrapper_requires in $compat_random_file" >&2
    printf "%s\n" "$wrapper_body" >&2
    echo "[patterns] every secure call site depends on this wrapper staying on secure entropy" >&2
    exit 1
  fi

  if printf "%s\n" "$wrapper_body" | grep -qE "$ordinary_entropy_pattern"; then
    echo "[patterns] secure wrapper $wrapper_fn uses ordinary entropy in $compat_random_file" >&2
    printf "%s\n" "$wrapper_body" | grep -nE "$ordinary_entropy_pattern" >&2
    echo "[patterns] every secure call site depends on this wrapper staying on secure entropy" >&2
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
