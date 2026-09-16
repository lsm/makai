#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: notarize-macos.sh <signed-binary> [signed-binary ...]

Submits already-signed binaries to Apple's notary service and waits for the
verdict. On rejection the notary log is printed, which names the offending
binary and reason.

A bare command line executable cannot carry a stapled ticket (stapling works
only on .app bundles, .dmg and .pkg), so Gatekeeper resolves the ticket online
for a quarantined download. Notarizing still matters: without it a quarantined
copy is refused outright.

Credentials, App Store Connect API key (preferred):
  MACOS_NOTARY_KEY        base64 of the .p8 private key
  MACOS_NOTARY_KEY_ID     the key ID
  MACOS_NOTARY_ISSUER_ID  the issuer UUID

Credentials, Apple ID fallback:
  MACOS_NOTARY_APPLE_ID   Apple ID email
  MACOS_NOTARY_PASSWORD   an app-specific password, never the account password
  MACOS_NOTARY_TEAM_ID    the 10 character team ID
USAGE
}

if [[ $# -eq 0 ]]; then
  usage
  exit 2
fi

work_dir="$(mktemp -d)"
chmod 700 "$work_dir"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

credential_args=()
if [[ -n "${MACOS_NOTARY_KEY:-}" ]]; then
  if [[ -z "${MACOS_NOTARY_KEY_ID:-}" || -z "${MACOS_NOTARY_ISSUER_ID:-}" ]]; then
    echo "[notarize] MACOS_NOTARY_KEY needs MACOS_NOTARY_KEY_ID and MACOS_NOTARY_ISSUER_ID" >&2
    exit 1
  fi
  key_path="$work_dir/notary.p8"
  printf '%s' "$MACOS_NOTARY_KEY" | base64 --decode > "$key_path"
  credential_args=(--key "$key_path" --key-id "$MACOS_NOTARY_KEY_ID" --issuer "$MACOS_NOTARY_ISSUER_ID")
  echo "[notarize] authenticating with an App Store Connect API key"
elif [[ -n "${MACOS_NOTARY_APPLE_ID:-}" ]]; then
  if [[ -z "${MACOS_NOTARY_PASSWORD:-}" || -z "${MACOS_NOTARY_TEAM_ID:-}" ]]; then
    echo "[notarize] MACOS_NOTARY_APPLE_ID needs MACOS_NOTARY_PASSWORD and MACOS_NOTARY_TEAM_ID" >&2
    exit 1
  fi
  credential_args=(--apple-id "$MACOS_NOTARY_APPLE_ID" --password "$MACOS_NOTARY_PASSWORD" --team-id "$MACOS_NOTARY_TEAM_ID")
  echo "[notarize] authenticating with an Apple ID and app-specific password"
else
  echo "[notarize] no notary credentials configured; see docs/macos-code-signing.md" >&2
  exit 1
fi

for binary in "$@"; do
  if [[ ! -f "$binary" ]]; then
    echo "[notarize] not a file: $binary" >&2
    exit 1
  fi
  if ! codesign --verify --strict "$binary" 2>/dev/null; then
    echo "[notarize] $binary is not validly signed; run scripts/sign-macos.sh first" >&2
    exit 1
  fi
done

archive="$work_dir/submission.zip"
payload="$work_dir/payload"
index=0
for binary in "$@"; do
  index=$((index + 1))
  mkdir -p "$payload/$index"
  cp "$binary" "$payload/$index/$(basename "$binary")"
done
ditto -c -k --sequesterRsrc --keepParent "$payload" "$archive"
echo "[notarize] submitting $# binaries; the notary ticket is keyed to each code hash, not to the archive layout"

response="$(xcrun notarytool submit "$archive" "${credential_args[@]}" --wait --timeout 30m --output-format json)"
echo "$response"

read_field() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1" <<<"$response"
}
submission_id="$(read_field id)"
status="$(read_field status)"

if [[ "$status" != "Accepted" ]]; then
  echo "[notarize] notarization did not succeed (status: ${status:-unknown})" >&2
  if [[ -n "$submission_id" ]]; then
    echo "[notarize] notary log for $submission_id:" >&2
    xcrun notarytool log "$submission_id" "${credential_args[@]}" >&2 || true
  fi
  exit 1
fi

echo "[notarize] accepted (submission $submission_id)"

for binary in "$@"; do
  probe="$work_dir/$(basename "$binary").quarantined"
  cp "$binary" "$probe"
  xattr -w com.apple.quarantine "0081;00000000;Makai;" "$probe"
  if spctl --assess --type exec --verbose=2 "$probe" 2>&1 | tee "$work_dir/spctl.txt"; then
    echo "[notarize] $binary passes Gatekeeper as a quarantined download"
  else
    echo "[notarize] warning: Gatekeeper rejected a quarantined copy of $binary" >&2
    cat "$work_dir/spctl.txt" >&2
  fi
done

echo "[notarize] ok"
