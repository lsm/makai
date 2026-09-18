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

ordinary_entropy_pattern='\b(fillRandomBytes|randomBytes|randomIntRangeLessThan)\b|\b(IoSource|DefaultPrng|DeterministicSource)\b|random[[:space:]]*\.[[:space:]]*int\b|\.[[:space:]]*random[[:space:]]*[;(]|\.[[:space:]]*Random[[:space:]]*[.;]'
secure_entropy_pattern='\b(fillSecureBytes|secureBytes|secureIntRangeLessThan|randomSecure)\b'

strip_noncode() {
  awk '
  {
    line = $0
    out = ""
    n = length(line)
    i = 1
    while (i <= n) {
      c = substr(line, i, 1)
      d = substr(line, i + 1, 1)
      if (c == "/" && d == "/") break
      if (c == "\\" && d == "\\") break
      if (c == "@" && d == "\"") {
        i += 2
        while (i <= n) {
          ch = substr(line, i, 1)
          if (ch == "\\") {
            esc = substr(line, i + 1, 1)
            if (esc == "x") {
              hex = substr(line, i + 2, 2)
              if (hex ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) {
                v = (index("0123456789abcdef", tolower(substr(hex, 1, 1))) - 1) * 16 + index("0123456789abcdef", tolower(substr(hex, 2, 1))) - 1
                if (v > 0 && v < 128) out = out sprintf("%c", v); else out = out "?"
                i += 4
                continue
              }
            } else if (esc == "u") {
              rest = substr(line, i + 2)
              if (substr(rest, 1, 1) == "{") {
                end = index(rest, "}")
                if (end > 2) {
                  cp = substr(rest, 2, end - 2)
                  if (cp ~ /^[0-9A-Fa-f]+$/) {
                    v = 0
                    for (p = 1; p <= length(cp); p++) v = v * 16 + index("0123456789abcdef", tolower(substr(cp, p, 1))) - 1
                    if (v > 0 && v < 128) out = out sprintf("%c", v); else out = out "?"
                    i += 2 + end
                    continue
                  }
                }
              }
            }
            out = out substr(line, i, 2); i += 2; continue
          }
          i++
          if (ch == "\"") break
          out = out ch
        }
        continue
      }
      if (c == "\"" || c == "'"'"'") {
        quote = c
        i++
        while (i <= n) {
          ch = substr(line, i, 1)
          if (ch == "\\") { i += 2; continue }
          i++
          if (ch == quote) break
        }
        out = out " "
        continue
      }
      out = out c
      i++
    }
    print out
  }'
}

code_matches_only() {
  local pattern="$1" prefix_fields="$2" hit content stripped
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    content="$hit"
    for ((i = 0; i < prefix_fields; i++)); do content="${content#*:}"; done
    stripped="$(printf '%s' "$content" | strip_noncode)"
    if printf '%s' "$stripped" | grep -qE "$pattern"; then printf '%s\n' "$hit"; fi
  done
}

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
zig/src/compat/random.zig|        const ordinary_value = randomIntRangeLessThan(usize, 62);
zig/src/compat/random.zig|        const ordinary_value = randomIntRangeLessThan(usize, 62);
zig/src/compat/random.zig|        return .{ .prng = std.Random.DefaultPrng.init(seed) };
zig/src/compat/random.zig|        self.prng.random().bytes(buf);
zig/src/compat/random.zig|    const OrdinaryHelper = @TypeOf(fillRandomBytes);
zig/src/compat/random.zig|    const ordinary = try randomBytes(std.testing.allocator, 0);
zig/src/compat/random.zig|    const ordinary = try randomBytes(std.testing.allocator, 17);
zig/src/compat/random.zig|    const ordinary = try randomBytes(std.testing.allocator, 32);
zig/src/compat/random.zig|    defaultIo().random(buf);
zig/src/compat/random.zig|    fillRandomBytes(&empty);
zig/src/compat/random.zig|    fillRandomBytes(buf);
zig/src/compat/random.zig|    prng: std.Random.DefaultPrng,
zig/src/compat/random.zig|    pub fn allocBytes(self: *DeterministicSource, allocator: std.mem.Allocator, len: usize) ![]u8 {
zig/src/compat/random.zig|    pub fn bytes(self: *DeterministicSource, buf: []u8) void {
zig/src/compat/random.zig|    pub fn init(seed: u64) DeterministicSource {
zig/src/compat/random.zig|    try std.testing.expect(fillSecureBytes != fillRandomBytes);
zig/src/compat/random.zig|    try std.testing.expectEqual(@as(usize, 0), randomIntRangeLessThan(usize, 1));
zig/src/compat/random.zig|    var different_source = DeterministicSource.init(0x8765_4321);
zig/src/compat/random.zig|    var first_source = DeterministicSource.init(0x1234_5678);
zig/src/compat/random.zig|    var second_source = DeterministicSource.init(0x1234_5678);
zig/src/compat/random.zig|    var source: std.Random.IoSource = .{ .io = defaultIo() };
zig/src/compat/random.zig|    var source: std.Random.IoSource = .{ .io = defaultIo() };
zig/src/compat/random.zig|pub const DeterministicSource = struct {
zig/src/compat/random.zig|pub fn fillRandomBytes(buf: []u8) void {
zig/src/compat/random.zig|pub fn randomBytes(allocator: std.mem.Allocator, len: usize) ![]u8 {
zig/src/compat/random.zig|pub fn randomIntRangeLessThan(comptime T: type, upper_bound: T) T {
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

expected_sensitive_noncode_matches="$(cat <<'NONCODE'
NONCODE
)"

echo "[patterns] checking security-sensitive entropy call sites..."
for file in "${secure_random_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "[patterns] secure_random_files lists a path that does not exist: $file" >&2
    echo "[patterns] update scripts/check-zig-patterns.sh when entropy call sites move or are deleted" >&2
    exit 1
  fi
  secure_file_matches="$(grep -nE "$ordinary_entropy_pattern" "$file" \
    | sed "s|^[0-9]*:|$file\||" || true)"
  if [[ -n "$secure_file_matches" ]]; then
    secure_file_matches="$(comm -13 \
      <(printf "%s\n" "$expected_sensitive_noncode_matches" | grep -v '^$' | sort) \
      <(printf "%s\n" "$secure_file_matches" | grep -v '^$' | sort))"
  fi
  if [[ -n "$secure_file_matches" ]]; then
    echo "[patterns] security-sensitive random path uses ordinary entropy in $file" >&2
    echo "$secure_file_matches" >&2
    echo "[patterns] use compat.random secure helpers / io.randomSecure for OAuth, WebSocket, and protocol IDs" >&2
    echo "[patterns] this check matches raw text on purpose, so a scanner bug cannot unprotect these files;" >&2
    echo "[patterns] if the match is genuinely non-code, declare it in expected_sensitive_noncode_matches" >&2
    exit 1
  fi
done

echo "[patterns] checking ordinary entropy call sites are declared..."
if [[ ! -f "$ordinary_entropy_definition_file" ]]; then
  echo "[patterns] ordinary_entropy_definition_file does not exist: $ordinary_entropy_definition_file" >&2
  exit 1
fi

escaped_identifier_pattern='\\x[0-9A-Fa-f][0-9A-Fa-f]|\\u[{][0-9A-Fa-f]'
scan_prefilter_pattern="$ordinary_entropy_pattern|$escaped_identifier_pattern"

actual_ordinary_entropy_sites="$(grep -RnsE --include="*.zig" "$scan_prefilter_pattern" zig/src \
  | code_matches_only "$ordinary_entropy_pattern" 2 \
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

echo "[patterns] checking line-broken ordinary entropy..."
while IFS= read -r -d '' file; do
  joined_hits="$(strip_noncode < "$file" \
    | awk '
    { lines[NR] = $0 }
    END {
      k = 1
      while (k <= NR) {
        acc = lines[k]; first = lines[k]
        while (k < NR && lines[k + 1] ~ /^[[:space:]]*[.(]/) { k++; acc = acc " " lines[k] }
        if (acc != first) print acc
        k++
      }
    }' \
    | grep -E "$ordinary_entropy_pattern" || true)"
  if [[ -n "$joined_hits" ]]; then
    echo "[patterns] ordinary entropy split across lines in $file" >&2
    printf "%s\n" "$joined_hits" | sed "s|^|$file: joined: |" >&2
    echo "[patterns] the deny patterns are line-based; write entropy calls on one line so the guard can see them" >&2
    exit 1
  fi
done < <(find zig/src -name '*.zig' -print0 | sort -z)

echo "[patterns] checking secure entropy call sites are present..."
expected_secure_entropy_sites="$(cat <<'SECURE'
zig/src/compat/random.zig|        const secure_value = secureIntRangeLessThan(usize, 62);
zig/src/compat/random.zig|        const secure_value = secureIntRangeLessThan(usize, 62);
zig/src/compat/random.zig|        fillSecureBytes(&bytes);
zig/src/compat/random.zig|    const SecureHelper = @TypeOf(fillSecureBytes);
zig/src/compat/random.zig|    const first = try secureBytes(std.testing.allocator, 32);
zig/src/compat/random.zig|    const second = try secureBytes(std.testing.allocator, 32);
zig/src/compat/random.zig|    const secure = try secureBytes(std.testing.allocator, 0);
zig/src/compat/random.zig|    const secure = try secureBytes(std.testing.allocator, 32);
zig/src/compat/random.zig|    const secure = try secureBytes(std.testing.allocator, 32);
zig/src/compat/random.zig|    defaultIo().randomSecure(buf) catch |err| {
zig/src/compat/random.zig|    fillSecureBytes(&empty);
zig/src/compat/random.zig|    fillSecureBytes(buf);
zig/src/compat/random.zig|    try std.testing.expect(fillSecureBytes != fillRandomBytes);
zig/src/compat/random.zig|    try std.testing.expectEqual(@as(usize, 0), secureIntRangeLessThan(usize, 1));
zig/src/compat/random.zig|pub fn fillSecureBytes(buf: []u8) void {
zig/src/compat/random.zig|pub fn secureBytes(allocator: std.mem.Allocator, len: usize) ![]u8 {
zig/src/compat/random.zig|pub fn secureIntRangeLessThan(comptime T: type, upper_bound: T) T {
zig/src/oauth/pkce.zig|    return generatePKCEWithRandom(compat.random.fillSecureBytes);
zig/src/protocol/provider/types.zig|    return generateSessionIdWithRandomInt(compat.random.secureIntRangeLessThan);
zig/src/protocol/provider/types.zig|    return generateUlidWithRandom(compat.random.fillSecureBytes);
zig/src/transports/websocket.zig|        compat.random.fillSecureBytes(&mask);
zig/src/transports/websocket.zig|    compat.random.fillSecureBytes(&nonce);
zig/src/tui/app.zig|    compat.random.fillSecureBytes(&random_bytes);
zig/src/utils/oauth/openai_codex.zig|    return generateStateWithRandom(allocator, compat.random.fillSecureBytes);
zig/src/protocol/oap/provider/server.zig|        compat.random.fillSecureBytes(&raw);
zig/src/utils/oauth/pkce.zig|    return generateWithRandom(allocator, compat.random.fillSecureBytes);
SECURE
)"

actual_secure_entropy_sites="$(grep -RnsE --include="*.zig" "$secure_entropy_pattern" zig/src \
  | code_matches_only "$secure_entropy_pattern" 2 \
  | sed 's/^\([^:]*\):[0-9]*:/\1|/' || true)"

if [[ "$(printf "%s\n" "$expected_secure_entropy_sites" | sort)" != "$(printf "%s\n" "$actual_secure_entropy_sites" | sort)" ]]; then
  echo "[patterns] secure entropy call sites changed:" >&2
  diff <(printf "%s\n" "$expected_secure_entropy_sites" | sort) \
       <(printf "%s\n" "$actual_secure_entropy_sites" | sort) >&2 || true
  echo "[patterns] a security-sensitive generator must keep consuming secure entropy; declare intentional changes here" >&2
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
  echo "[patterns] every public export of the entropy module must be classified as secure or ordinary and declared here" >&2
  exit 1
fi

echo "[patterns] checking compat.random secure wrapper bodies..."
compat_random_file="zig/src/compat/random.zig"
secure_wrappers=(
  "fillSecureBytes:defaultIo().randomSecure("
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
  "zig/src/protocol/oap/server.zig"
  "zig/src/protocol/oap/bridge.zig"
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

known_multi_alloc_literals="$(cat <<'LITERALS'
zig/src/agent/agent.zig|                .data = try self._allocator.dupe(u8, i.data),
zig/src/agent/agent_loop.zig|        .tool_call_id = try allocator.dupe(u8, tool_call.id),
zig/src/agent/agent_loop.zig|        .tool_call_id = try allocator.dupe(u8, tool_call.id),
zig/src/agent/provider_protocol_bridge.zig|        .api_key = if (options.api_key) |k| try allocator.dupe(u8, k) else null,
zig/src/protocol/auth/server.zig|                .id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, definition.id)),
zig/src/protocol/auth/server.zig|                .prompt_id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, prompt_id)),
zig/src/protocol/auth/server.zig|                .provider_id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, flow.provider_id)),
zig/src/protocol/auth/server.zig|                .provider_id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, flow.provider_id)),
zig/src/protocol/auth/server.zig|            .provider_id = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, flow.provider_id)),
zig/src/protocol/auth/server.zig|            .refresh = try self.allocator.dupe(u8, "fixture-refresh-token"),
zig/src/protocol/provider/partial_reconstructor.zig|                    .id = if (tc.id) |id| try self.allocator.dupe(u8, id) else try self.allocator.dupe(u8, ""),
zig/src/protocol/provider/server.zig|            .refresh = try allocator.dupe(u8, "refresh"),
zig/src/protocol/provider/server.zig|        .model_id = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, model_id_value)),
zig/src/protocol/provider/server.zig|        .refresh = try allocator.dupe(u8, "refresh"),
zig/src/protocol/provider/server.zig|        .refresh = try allocator.dupe(u8, credentials.refresh),
zig/src/tools/auth_cli.zig|            .prompt_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, prompt_id)),
zig/src/tools/makai.zig|            .prompt_id = AuthProtocolTypes.OwnedSlice(u8).initOwned(try allocator.dupe(u8, prompt_id)),
zig/src/tools/makai.zig|            .tool_call_id = try allocator.dupe(u8, tool_call_id),
zig/src/tools/permission.zig|                .tool_name = try self.allocator.dupe(u8, tool_name),
zig/src/transport.zig|            .api = try allocator.dupe(u8, ""),
zig/src/transport.zig|            .api = try allocator.dupe(u8, ""),
zig/src/transport.zig|            .api = try allocator.dupe(u8, ""),
zig/src/tui/config.zig|            .model = try allocator.dupe(u8, "claude-sonnet-4-5"),
zig/src/tui/runtime.zig|                .data = try allocator.dupe(u8, img.data),
zig/src/tui/runtime.zig|                .id = try allocator.dupe(u8, tc.id),
zig/src/tui/runtime.zig|                .text = try allocator.dupe(u8, t.text),
zig/src/tui/runtime.zig|                .thinking = try allocator.dupe(u8, t.thinking),
zig/src/tui/session_store.zig|        .session_id = try allocator.dupe(u8, session_id),
zig/src/tui/state.zig|            .id = try allocator.dupe(u8, id),
zig/src/tui/state.zig|            .tool_call_id = try allocator.dupe(u8, tool_call_id),
zig/src/utils/oauth/anthropic.zig|        .access_token = try allocator.dupe(u8, access_token),
zig/src/utils/oauth/anthropic.zig|        .code = try allocator.dupe(u8, input),
zig/src/utils/oauth/anthropic.zig|        .refresh = try allocator.dupe(u8, token_response.refresh_token),
zig/src/utils/oauth/anthropic.zig|        .refresh = try allocator.dupe(u8, token_response.refresh_token),
zig/src/utils/oauth/github_copilot.zig|        .device_code = try allocator.dupe(u8, parsed.value.device_code),
zig/src/utils/oauth/openai_codex.zig|        .code = try allocator.dupe(u8, trimmed),
zig/src/utils/pre_transform.zig|                                        .thinking = try allocator.dupe(u8, t.thinking),
zig/src/utils/pre_transform.zig|                                    .text = try allocator.dupe(u8, t.text),
zig/src/utils/pre_transform.zig|                                    .thinking = try allocator.dupe(u8, t.thinking),
zig/src/utils/pre_transform.zig|                                .data = try allocator.dupe(u8, img.data),
LITERALS
)"

multi_alloc_literal_pattern='try[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*\\.(dupe|dupeZ|allocSentinel)[[:space:]]*\\(|try[[:space:]]+std\\.fmt\\.allocPrint[[:space:]]*\\(|try[[:space:]]+owned[[:space:]]*\\('

scan_multi_alloc_literals() {
  local file="$1"
  awk -v file="$file" -v pattern="$multi_alloc_literal_pattern" '
    NR == FNR { code[FNR] = $0; next }
    { orig[FNR] = $0; if (FNR > last) last = FNR }
    END {
      in_test = 0
      test_depth = 0
      depth = 0
      count = 0
      first = 0
      for (i = 1; i <= last; i++) {
        line = code[i]
        opens = gsub(/\{/, "{", line)
        closes = gsub(/\}/, "}", line)
        line = code[i]

        if (!in_test && orig[i] ~ /^[[:space:]]*test[[:space:]]*["{]/) {
          in_test = 1
          test_depth = opens - closes
          continue
        }
        if (in_test) {
          test_depth += opens - closes
          if (test_depth <= 0) in_test = 0
          continue
        }

        if (depth == 0) {
          trimmed = line
          sub(/[[:space:]]+$/, "", trimmed)
          if (trimmed ~ /\.\{$/ && opens > closes) {
            depth = opens - closes
            count = 0
            first = 0
          }
          continue
        }

        depth += opens - closes
        if (line ~ pattern) {
          count++
          if (first == 0) first = i
        }
        if (depth <= 0) {
          if (count >= 2) print file "|" orig[first]
          depth = 0
          count = 0
          first = 0
        }
      }
    }
  ' <(strip_noncode < "$file") "$file"
}

echo "[patterns] checking struct literals that allocate more than once..."
actual_multi_alloc_literals=""
while IFS= read -r -d '' file; do
  literal_hits="$(scan_multi_alloc_literals "$file")"
  if [[ -n "$literal_hits" ]]; then
    actual_multi_alloc_literals+="$literal_hits"$'\n'
  fi
done < <(find zig/src -name "*.zig" -print0 | sort -z)

undeclared_multi_alloc="$(comm -13 \
  <(printf "%s\n" "$known_multi_alloc_literals" | grep -v '^$' | sort) \
  <(printf "%s\n" "$actual_multi_alloc_literals" | grep -v '^$' | sort))"
if [[ -n "$undeclared_multi_alloc" ]]; then
  echo "[patterns] struct literal allocates more than once with no way to unwind:" >&2
  echo "$undeclared_multi_alloc" >&2
  echo "[patterns] Zig evaluates literal fields in order, so when a later allocation fails the" >&2
  echo "[patterns] literal never completes and every field already allocated for it leaks. An" >&2
  echo "[patterns] errdefer cannot help from inside a literal, and one placed after it never runs," >&2
  echo "[patterns] because the assignment it guards was never reached. Build each field into a" >&2
  echo "[patterns] local with its own errdefer first, so the literal itself becomes infallible;" >&2
  echo "[patterns] see cloneModelDescriptor in zig/src/protocol/model_catalog_types.zig." >&2
  echo "[patterns] Prove the fix with std.testing.checkAllAllocationFailures." >&2
  echo "[patterns] known_multi_alloc_literals is a shrinking backlog of sites that predate this" >&2
  echo "[patterns] check, not a list of approved ones. Adding to it needs a reason in the commit" >&2
  echo "[patterns] message that says why this literal cannot leak - an arena freed wholesale on" >&2
  echo "[patterns] error, for example. New code is expected to be fixed, not declared." >&2
  exit 1
fi

stale_multi_alloc="$(comm -23 \
  <(printf "%s\n" "$known_multi_alloc_literals" | grep -v '^$' | sort) \
  <(printf "%s\n" "$actual_multi_alloc_literals" | grep -v '^$' | sort))"
if [[ -n "$stale_multi_alloc" ]]; then
  echo "[patterns] known_multi_alloc_literals declares a literal that no longer exists:" >&2
  echo "$stale_multi_alloc" >&2
  echo "[patterns] a fixed site must be removed from the list so the count keeps ratcheting down" >&2
  exit 1
fi

echo "[patterns] checking providers do not drop stream events..."
dropped_events="$(grep -n '\.push(' zig/src/providers/*.zig | grep -v 'keepalive' || true)"
if [[ -n "$dropped_events" ]]; then
  echo "[patterns] provider uses push() for a non-keepalive event:" >&2
  echo "$dropped_events" >&2
  echo "[patterns] push() returns QueueFull when a slow consumer fills the ring, and providers" >&2
  echo "[patterns] historically discarded that error, silently losing streamed content while the" >&2
  echo "[patterns] final message stayed complete. Use pushBlocking() for every semantic event;" >&2
  echo "[patterns] only keepalive may be dropped, because it is advisory." >&2
  exit 1
fi

echo "[patterns] ok"
