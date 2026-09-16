#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: setup-macos-signing-secrets.sh --p12 <file> --notary-key <file> \
         --key-id <id> --issuer <uuid> [--repo owner/name] [--dry-run]

Validates the Apple signing material and uploads it to GitHub Actions as the five
secrets .github/workflows/release-binaries.yml expects. Values are read from disk
and piped straight to gh, so no secret is typed into a browser, passed on the
command line, or written to shell history.

  --p12         Developer ID Application certificate exported as .p12, with key
  --notary-key  App Store Connect API key (.p8) used for notarization
  --key-id      the key ID shown beside that key, 10 characters
  --issuer      the issuer UUID shown above the key list
  --repo        target repository (default: the current checkout's origin)
  --dry-run     validate and report, upload nothing

The .p12 password is prompted for and never echoed. See docs/macos-code-signing.md.
USAGE
}

p12_path=""
notary_key_path=""
key_id=""
issuer_id=""
repo=""
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --p12) p12_path="${2:-}"; shift 2 ;;
    --notary-key) notary_key_path="${2:-}"; shift 2 ;;
    --key-id) key_id="${2:-}"; shift 2 ;;
    --issuer) issuer_id="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[secrets] unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$p12_path" || -z "$notary_key_path" || -z "$key_id" || -z "$issuer_id" ]]; then
  usage
  exit 2
fi

for file in "$p12_path" "$notary_key_path"; do
  if [[ ! -f "$file" ]]; then
    echo "[secrets] not a file: $file" >&2
    exit 1
  fi
done

if ! command -v gh >/dev/null 2>&1; then
  echo "[secrets] the GitHub CLI (gh) is required: https://cli.github.com" >&2
  exit 1
fi

if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

if [[ ! "$key_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "[secrets] warning: --key-id is normally 10 uppercase alphanumerics, got '$key_id'" >&2
fi
if [[ ! "$issuer_id" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  echo "[secrets] warning: --issuer is normally a 36 character UUID, got '$issuer_id'" >&2
fi

if ! grep -q "BEGIN PRIVATE KEY" "$notary_key_path"; then
  echo "[secrets] $notary_key_path does not look like an App Store Connect .p8 key" >&2
  exit 1
fi

printf '[secrets] password for %s: ' "$(basename "$p12_path")" >&2
read -rs p12_password
printf '\n' >&2
if [[ -z "$p12_password" ]]; then
  echo "[secrets] an empty .p12 password is not supported" >&2
  exit 1
fi

read_certificate_subject() {
  openssl pkcs12 -in "$p12_path" -nokeys -passin env:P12_PASSWORD "$@" 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null || true
}

export P12_PASSWORD="$p12_password"
subject="$(read_certificate_subject)"
if [[ -z "$subject" ]]; then
  subject="$(read_certificate_subject -legacy)"
fi
unset P12_PASSWORD
if [[ -z "$subject" ]]; then
  echo "[secrets] could not read $p12_path with that password" >&2
  exit 1
fi

echo "[secrets] certificate: $subject"
if [[ "$subject" != *"Developer ID Application"* ]]; then
  echo "[secrets] warning: this is not a 'Developer ID Application' certificate." >&2
  echo "[secrets] Apple Development and Mac App Distribution certificates cannot sign" >&2
  echo "[secrets] software distributed outside the App Store; the release will fail." >&2
fi
team="$(sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p' <<<"$subject" | head -n 1)"
if [[ -n "$team" ]]; then
  echo "[secrets] team identifier: $team"
else
  echo "[secrets] warning: no 10 character team identifier found in the certificate subject" >&2
fi

echo "[secrets] target repository: $repo"
if [[ "$dry_run" -eq 1 ]]; then
  echo "[secrets] dry run: would set MACOS_CERTIFICATE_P12, MACOS_CERTIFICATE_PASSWORD,"
  echo "[secrets]          MACOS_NOTARY_KEY, MACOS_NOTARY_KEY_ID, MACOS_NOTARY_ISSUER_ID"
  exit 0
fi

base64 < "$p12_path" | gh secret set MACOS_CERTIFICATE_P12 --repo "$repo"
printf '%s' "$p12_password" | gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$repo"
base64 < "$notary_key_path" | gh secret set MACOS_NOTARY_KEY --repo "$repo"
printf '%s' "$key_id" | gh secret set MACOS_NOTARY_KEY_ID --repo "$repo"
printf '%s' "$issuer_id" | gh secret set MACOS_NOTARY_ISSUER_ID --repo "$repo"
unset p12_password

echo "[secrets] uploaded. Configured signing secrets now on $repo:"
gh secret list --repo "$repo" | grep -E '^MACOS_' || true
echo "[secrets] next: Actions -> Release Binaries -> Run workflow, to sign without publishing"
