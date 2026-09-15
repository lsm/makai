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

ordinary_entropy_pattern='\b(fillRandomBytes|randomBytes|randomIntRangeLessThan)\b|\b(IoSource|DefaultPrng|DeterministicSource)\b|random\.int\b|\.random[[:space:]]*;|\.random\(|std\.Random\.'
comment_line_filter='^[^:]+:[0-9]+:[[:space:]]*//'

secure_random_files=(
  "zig/src/oauth/pkce.zig"
  "zig/src/utils/oauth/pkce.zig"
  "zig/src/utils/oauth/openai_codex.zig"
  "zig/src/transports/websocket.zig"
  "zig/src/protocol/provider/types.zig"
  "zig/src/tui/app.zig"
)

ordinary_entropy_definition_file="zig/src/compat/random.zig"

expected_ordinary_entropy_sites="$(cat <<'SITES'
zig/src/model_catalog.zig|    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}.{x}", .{ path, compat.time.nowMillis(), compat.random.int(u64) });
zig/src/providers/sse_parser.zig|    const random = prng.random();
zig/src/providers/sse_parser.zig|    var prng = std.Random.DefaultPrng.init(seed);
zig/src/transports/transport_retry.zig|        return prng.random().intRangeAtMost(u64, self.base_delay_ms, capped);
zig/src/transports/transport_retry.zig|        var prng = std.Random.DefaultPrng.init(seed);
zig/src/utils/oauth/storage.zig|    const tmp_name = try std.fmt.allocPrint(allocator, "{s}{d}.{x}", .{ auth_temp_prefix, compat.time.nowMillis(), compat.random.int(u64) });
zig/src/utils/retry.zig|            const rand = prng.random().float(f32);
zig/src/utils/retry.zig|            var prng = std.Random.DefaultPrng.init(seed);
zig/src/utils/tool_utils.zig|    return generateMistralToolCallIdWithRandom(allocator, compat.random.fillRandomBytes);
SITES
)"

echo "[patterns] checking security-sensitive entropy call sites..."
for file in "${secure_random_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "[patterns] secure_random_files lists a path that does not exist: $file" >&2
    echo "[patterns] update scripts/check-zig-patterns.sh when entropy call sites move or are deleted" >&2
    exit 1
  fi
  secure_file_matches="$(grep -nE "$ordinary_entropy_pattern" "$file" \
    | grep -vE "^[0-9]+:[[:space:]]*//" || true)"
  if [[ -n "$secure_file_matches" ]]; then
    echo "[patterns] security-sensitive random path uses ordinary entropy in $file" >&2
    echo "$secure_file_matches" >&2
    echo "[patterns] use compat.random secure helpers / io.randomSecure for OAuth, WebSocket, and protocol IDs" >&2
    exit 1
  fi
done

echo "[patterns] checking ordinary entropy call sites are declared..."
if [[ ! -f "$ordinary_entropy_definition_file" ]]; then
  echo "[patterns] ordinary_entropy_definition_file does not exist: $ordinary_entropy_definition_file" >&2
  exit 1
fi

actual_ordinary_entropy_sites="$(grep -RnsE --include="*.zig" "$ordinary_entropy_pattern" zig/src \
  | grep -v "^$ordinary_entropy_definition_file:" \
  | grep -vE "$comment_line_filter" \
  | sed 's/^\([^:]*\):[0-9]*:/\1|/' || true)"

undeclared_ordinary_entropy="$(comm -13 \
  <(printf "%s\n" "$expected_ordinary_entropy_sites" | grep -v '^$' | sort) \
  <(printf "%s\n" "$actual_ordinary_entropy_sites" | grep -v '^$' | sort))"
if [[ -n "$undeclared_ordinary_entropy" ]]; then
  echo "[patterns] undeclared ordinary entropy call site:" >&2
  echo "$undeclared_ordinary_entropy" >&2
  echo "[patterns] use compat.random secure helpers, or declare the exact call site in expected_ordinary_entropy_sites with rationale in the commit message" >&2
  exit 1
fi

stale_ordinary_entropy="$(comm -23 \
  <(printf "%s\n" "$expected_ordinary_entropy_sites" | grep -v '^$' | sort) \
  <(printf "%s\n" "$actual_ordinary_entropy_sites" | grep -v '^$' | sort))"
if [[ -n "$stale_ordinary_entropy" ]]; then
  echo "[patterns] expected_ordinary_entropy_sites declares a call site that no longer exists:" >&2
  echo "$stale_ordinary_entropy" >&2
  echo "[patterns] update scripts/check-zig-patterns.sh when entropy call sites move or are deleted" >&2
  exit 1
fi

echo "[patterns] checking compat.random public exports..."
expected_compat_random_exports="$(cat <<'EXPORTS'
pub const DeterministicSource
pub fn fillRandomBytes
pub fn fillSecureBytes
pub fn int
pub fn randomBytes
pub fn randomIntRangeLessThan
pub fn secureBytes
pub fn secureIntRangeLessThan
EXPORTS
)"

actual_compat_random_exports="$(grep -oE '^pub (const|fn) [A-Za-z_][A-Za-z0-9_]*' \
  "$ordinary_entropy_definition_file" | sort)"

if [[ "$expected_compat_random_exports" != "$actual_compat_random_exports" ]]; then
  echo "[patterns] public exports of $ordinary_entropy_definition_file changed:" >&2
  diff <(printf "%s\n" "$expected_compat_random_exports") \
       <(printf "%s\n" "$actual_compat_random_exports") >&2 || true
  echo "[patterns] this file is exempt from the call-site sweep, so every public export must be classified as secure or ordinary and declared here" >&2
  exit 1
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
