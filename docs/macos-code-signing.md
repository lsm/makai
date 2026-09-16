# macOS code signing and notarization

Zig leaves macOS binaries with an **ad-hoc, linker-generated signature**. You can
see it on any local build:

```bash
codesign -dvvv zig-out/bin/makai 2>&1 | grep -E 'Signature|TeamIdentifier'
```

```
Signature=adhoc
TeamIdentifier=not set
```

Two things follow from `TeamIdentifier=not set`, and both are why this document
exists.

**Keychain access lists re-prompt on every rebuild.** `zig/src/utils/oauth/storage.zig`
stores credentials in the login keychain and creates the item with
`SecAccessCreate`, which trusts only the creating binary. securityd identifies an
unsigned binary by its code hash, so each rebuild is a different application to it
and "Always Allow" cannot stick. A Developer ID signature is identified by the
10-character team ID instead, which is stable across rebuilds and across released
versions.

**Gatekeeper refuses a quarantined download.** A binary downloaded through a
browser carries `com.apple.quarantine`; without a Developer ID signature *and* a
notarization ticket, macOS refuses to run it. This does not affect `npm install`
(npm does not set the quarantine attribute), but it does affect anyone who
downloads a `makai-*-macos-*.tar.gz` from the GitHub release page.

| | ad-hoc (today) | Developer ID + notarized |
| --- | --- | --- |
| Keychain "Always Allow" survives a rebuild | no | yes |
| Runs after a browser download | no | yes |
| Runs after `npm install` | yes | yes |
| Hardened runtime | no | yes |

## One-time Apple setup

These four steps need a person with Apple credentials and a card. Nothing in this
repository can do them for you.

**1. Join the Apple Developer Program.** $99/year, at
[developer.apple.com/programs](https://developer.apple.com/programs/). Developer ID
certificates are only issued to paid memberships, and only to the Account Holder
role, so enroll as the account that will own the certificate.

**2. Create a Developer ID Application certificate.** Xcode is not required.

- Open Keychain Access → menu **Certificate Assistant → Request a Certificate From
  a Certificate Authority**. Enter your email, leave CA Email blank, choose **Saved
  to disk**, and save the `.certSigningRequest` file.
- Go to [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates),
  press **+**, and choose **Developer ID Application**. Not "Apple Development" and
  not "Mac App Distribution" — those cannot sign software distributed outside the
  App Store.
- Upload the request, download the resulting `.cer`, and double-click it to install
  it into your login keychain.

Confirm it landed, and note the 10 characters in parentheses — that is your team ID:

```bash
security find-identity -v -p codesigning
```

**3. Export the certificate as a `.p12`.** In Keychain Access, find the
"Developer ID Application: …" entry, right-click → **Export**, choose
Personal Information Exchange (.p12), and set a strong password. The export must
include the private key, so export the certificate row (which has a disclosure
triangle holding the key), not a bare certificate.

**4. Create an App Store Connect API key for notarization.** At
[appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Users and Access
→ Integrations → App Store Connect API**, create a key with the **Developer** role.
Download the `.p8` — Apple allows that download exactly once. Record the **Key ID**
next to it and the **Issuer ID** shown above the key list.

An Apple ID plus an app-specific password also works and the scripts accept it
(`MACOS_NOTARY_APPLE_ID`, `MACOS_NOTARY_PASSWORD`, `MACOS_NOTARY_TEAM_ID`), but the
API key is preferable: it is scoped, revocable on its own, and unaffected by
two-factor prompts.

## GitHub secrets

Add these under **Settings → Secrets and variables → Actions**. Base64-encode the
two binary files, since secrets hold text:

```bash
base64 -i DeveloperID.p12 | pbcopy
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

| Secret | Contents | Required |
| --- | --- | --- |
| `MACOS_CERTIFICATE_P12` | base64 of the `.p12` | yes |
| `MACOS_CERTIFICATE_PASSWORD` | the password you set on export | yes |
| `MACOS_NOTARY_KEY` | base64 of the `.p8` | yes |
| `MACOS_NOTARY_KEY_ID` | the key ID, e.g. `ABC123DEF4` | yes |
| `MACOS_NOTARY_ISSUER_ID` | the issuer UUID | yes |
| `MACOS_SIGN_IDENTITY` | full identity name | no, auto-detected |

`MACOS_SIGN_IDENTITY` only matters if the certificate is not the only Developer ID
Application identity in the keychain; otherwise the script picks it up on its own.

Treat the `.p12` and `.p8` as private keys: keep them in a password manager, never
in the repository. Neither is recoverable from GitHub once stored.

## Rollout order

The signing step is deliberately strict: once this is on `main`, a `v*` tag with no
signing secrets **fails the release** instead of publishing unsigned macOS binaries.
So configure the secrets before the next tag:

1. Complete the Apple setup and add the five required secrets.
2. Run the workflow manually (**Actions → Release Binaries → Run workflow**) on the
   branch. A `workflow_dispatch` run signs but does not notarize or publish, so it
   confirms the certificate and password decode and that `codesign` succeeds.
3. Merge, then tag. The tag run notarizes and publishes.

Running step 2 before step 1 is harmless — it warns, keeps the ad-hoc signature, and
still builds every target.

## What the release pipeline does

`.github/workflows/release-binaries.yml` signs both macOS targets between building
and packaging, so the tarball, the checksum and the `@makai/cli-darwin-*` npm
payload all carry the same signed bytes:

1. **Sign** (`scripts/sign-macos.sh`) — imports the certificate into a temporary
   keychain, signs with `--options runtime --timestamp`, verifies with
   `codesign --verify --strict`, prints the resulting team identifier, then deletes
   the keychain and restores the previous keychain search list.
2. **Notarize** (`scripts/notarize-macos.sh`, tagged releases only) — submits the
   signed binaries to Apple, waits for the verdict, prints the notary log if Apple
   rejects them, and finally re-checks a quarantined copy through `spctl`.

A tag build **fails** rather than publishing unsigned macOS binaries when
`MACOS_CERTIFICATE_P12` or `MACOS_NOTARY_KEY` is missing. A manual
`workflow_dispatch` run without the secrets warns and keeps the ad-hoc signature,
so the workflow stays usable for a build check before the certificate exists.

## Signing local development builds

Once the certificate is in your login keychain, this is what stops the daily
keychain prompt:

```bash
make sign
```

That builds and then signs `zig-out/bin/makai` with the same hardened-runtime
settings the release uses. Add `MACOS_SIGN_TIMESTAMP=none` when working offline;
the signature is then valid locally but cannot be notarized.

The first signed run still prompts once. The keychain item was created by an
earlier unsigned build, so its access list names that old code hash; clicking
**Always Allow** records your team ID and later rebuilds stop asking. To skip that
transition entirely, delete the item first and let the signed build recreate it:

```bash
security delete-generic-password -s com.makai.auth
```

That discards the stored credentials, so you will re-run `/login` afterwards.

## Verifying

```bash
codesign -dvvv zig-out/bin/makai 2>&1 | grep -E 'Authority|TeamIdentifier'
codesign --verify --strict --verbose=2 zig-out/bin/makai
security find-generic-password -s com.makai.auth
```

A correctly signed binary reports `Authority=Developer ID Application: …` and a
`TeamIdentifier` of 10 characters. To reproduce the Gatekeeper path a downloader
sees, mark a copy as quarantined and assess it — this only passes once the binary
has been notarized:

```bash
cp zig-out/bin/makai /tmp/makai-gatekeeper-probe
xattr -w com.apple.quarantine "0081;00000000;Safari;" /tmp/makai-gatekeeper-probe
spctl --assess --type exec --verbose=2 /tmp/makai-gatekeeper-probe
```

## Limits

**The ticket cannot be stapled.** `xcrun stapler` attaches a notarization ticket
only to `.app` bundles, `.dmg` images and `.pkg` installers. makai ships as a bare
executable inside a `.tar.gz`, so Gatekeeper resolves the ticket from Apple's
servers on first run, which needs network access. Shipping a `.pkg` or `.dmg` for
the macOS download is the only way to make first run work fully offline; that is a
packaging change, not a signing one.

**Notarization only gates quarantined files.** Binaries from `npm install`, `curl`
or a `git` checkout are not quarantined and run regardless. Signing still matters
for all of them, because the keychain behavior follows the signature alone.

**Hardened runtime needs no entitlements here.** makai links only `Security`,
`CoreFoundation`, `libSystem` and `libobjc`, loads nothing at runtime and has no
JIT, so it runs unmodified under `--options runtime`. Adding `dlopen` of a
non-system library later would require `com.apple.security.cs.disable-library-validation`
and an entitlements plist passed through `MACOS_SIGN_ENTITLEMENTS`.

## Renewal

A Developer ID Application certificate is valid for five years; the notary API key
does not expire but can be revoked. The secure timestamp means binaries signed
before expiry stay valid afterwards, so a lapsed certificate breaks new releases,
not released ones. Renewal is steps 2 and 3 again, followed by replacing
`MACOS_CERTIFICATE_P12` and `MACOS_CERTIFICATE_PASSWORD`.

Keep the team ID stable across renewals. It is the identity the keychain access
lists are bound to, and it is tied to the membership rather than the certificate,
so an ordinary renewal preserves it. Moving makai to a different Apple
Developer account would change it, and every user would be prompted once more.
