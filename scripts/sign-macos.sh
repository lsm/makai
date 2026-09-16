#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: sign-macos.sh <binary> [binary ...]

Signs each Mach-O binary with a Developer ID Application certificate, turning on
the hardened runtime and a secure timestamp so the result can be notarized, then
verifies the signature and prints the team identifier it carries.

Environment:
  MACOS_CERTIFICATE_P12       base64 of a .p12 holding the Developer ID
                              Application certificate and its private key. When
                              set, it is imported into a temporary keychain that
                              is deleted when this script exits. When unset, the
                              identity comes from the keychains already on the
                              search list.
  MACOS_CERTIFICATE_PASSWORD  password for that .p12 (required alongside it)
  MACOS_SIGN_IDENTITY         identity to sign with; defaults to the first
                              "Developer ID Application" identity available
  MACOS_SIGN_IDENTIFIER       code signing identifier (default: com.makai.cli)
  MACOS_SIGN_ENTITLEMENTS     optional entitlements plist; makai needs none
  MACOS_SIGN_TIMESTAMP        "none" signs without a secure timestamp, for
                              offline local builds. Such a signature is valid
                              locally but cannot be notarized.
USAGE
}

if [[ $# -eq 0 ]]; then
  usage
  exit 2
fi

for binary in "$@"; do
  if [[ ! -f "$binary" ]]; then
    echo "[sign] not a file: $binary" >&2
    exit 1
  fi
done

identifier="${MACOS_SIGN_IDENTIFIER:-com.makai.cli}"
keychain_path=""
restore_keychains=()

cleanup() {
  if [[ -n "$keychain_path" ]]; then
    if [[ ${#restore_keychains[@]} -gt 0 ]]; then
      security list-keychains -d user -s "${restore_keychains[@]}" >/dev/null 2>&1 || true
    fi
    security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
    echo "[sign] removed the temporary signing keychain"
  fi
}
trap cleanup EXIT

if [[ -n "${MACOS_CERTIFICATE_P12:-}" ]]; then
  if [[ -z "${MACOS_CERTIFICATE_PASSWORD:-}" ]]; then
    echo "[sign] MACOS_CERTIFICATE_P12 is set but MACOS_CERTIFICATE_PASSWORD is not" >&2
    exit 1
  fi

  work_dir="$(mktemp -d)"
  chmod 700 "$work_dir"
  p12_path="$work_dir/certificate.p12"
  keychain_path="$work_dir/makai-signing.keychain-db"
  keychain_password="$(uuidgen)"

  printf '%s' "$MACOS_CERTIFICATE_P12" | base64 --decode > "$p12_path"

  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%\"}"
    line="${line#\"}"
    [[ -n "$line" ]] && restore_keychains+=("$line")
  done < <(security list-keychains -d user)

  security create-keychain -p "$keychain_password" "$keychain_path"
  security set-keychain-settings -lut 21600 "$keychain_path"
  security unlock-keychain -p "$keychain_password" "$keychain_path"
  security import "$p12_path" -k "$keychain_path" -P "$MACOS_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$keychain_password" "$keychain_path" >/dev/null
  security list-keychains -d user -s "$keychain_path" "${restore_keychains[@]}"
  rm -f "$p12_path"
  echo "[sign] imported the signing certificate into a temporary keychain"
fi

resolve_identity() {
  if [[ -n "${MACOS_SIGN_IDENTITY:-}" ]]; then
    printf '%s' "$MACOS_SIGN_IDENTITY"
    return 0
  fi
  local listing
  if [[ -n "$keychain_path" ]]; then
    listing="$(security find-identity -v -p codesigning "$keychain_path")"
  else
    listing="$(security find-identity -v -p codesigning)"
  fi
  local name
  name="$(awk -F'"' '/Developer ID Application/ { print $2; exit }' <<<"$listing")"
  if [[ -z "$name" ]]; then
    name="$(awk -F'"' '/^[[:space:]]*[0-9]+\)/ { print $2; exit }' <<<"$listing")"
  fi
  printf '%s' "$name"
}

identity="$(resolve_identity)"
if [[ -z "$identity" ]]; then
  echo "[sign] no code signing identity found." >&2
  echo "[sign] install a Developer ID Application certificate, or set MACOS_CERTIFICATE_P12 / MACOS_SIGN_IDENTITY." >&2
  echo "[sign] see docs/macos-code-signing.md" >&2
  exit 1
fi
echo "[sign] signing as: $identity"

codesign_args=(--force --sign "$identity" --identifier "$identifier" --options runtime)
if [[ "${MACOS_SIGN_TIMESTAMP:-auto}" == "none" ]]; then
  codesign_args+=(--timestamp=none)
  echo "[sign] secure timestamp disabled; this signature cannot be notarized"
else
  codesign_args+=(--timestamp)
fi
if [[ -n "${MACOS_SIGN_ENTITLEMENTS:-}" ]]; then
  codesign_args+=(--entitlements "$MACOS_SIGN_ENTITLEMENTS")
fi
if [[ -n "$keychain_path" ]]; then
  codesign_args+=(--keychain "$keychain_path")
fi

for binary in "$@"; do
  echo "[sign] signing $binary"
  codesign "${codesign_args[@]}" "$binary"
  codesign --verify --strict --verbose=2 "$binary"
  details="$(codesign -dvvv "$binary" 2>&1 || true)"
  team="$(awk -F'=' '/^TeamIdentifier=/ { print $2 }' <<<"$details" | head -n 1)"
  authority="$(awk -F'=' '/^Authority=/ { print $2 }' <<<"$details" | head -n 1)"
  echo "[sign] $binary authority=${authority:-unknown} team=${team:-not set}"
  if [[ "${team:-not set}" == "not set" ]]; then
    echo "[sign] warning: the signature carries no team identifier, so keychain access lists stay bound to the code hash" >&2
  fi
done

echo "[sign] ok"
