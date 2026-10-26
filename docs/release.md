# Releases, signing and notarisation

## A release

A tag `v<major>.<minor>.<patch>` on `main` is a release. `.github/workflows/build.yml` builds
every push and pull request; on a tag it also publishes `Slipstream.dmg`, `Slipstream.zip` and
`SHA256SUMS` as that tag's release, marked latest. The file names carry no version, so
`releases/latest/download/Slipstream.dmg` is always the newest.

```bash
git tag -a v1.0.1 -m "Slipstream 1.0.1" origin/main && git push origin v1.0.1
```

Never upload a build from a Mac by hand. There is no Sparkle: when `encoder` asks for a newer
app (the worker's `update` event), the menu says "Update verfügbar" and links to the latest
release; the user installs it by hand.

## What CI does

Three jobs, so that nothing runs beside a secret it does not need:

1. **test**: `swift test`, no secret.
2. **build**, twice: the release, and on anything but a tag the check build (`--check`, the
   extension's frame self-test for the wp-admin check; [traps.md](traps.md), "Checks"). It runs
   `bin/fetch-worker` (the worker and its tools from encode-queue's release,
   [worker.md](worker.md), [tools.md](tools.md)) before any secret is on the runner, then
   imports the Developer ID identity into a temporary keychain and writes the notary key to a
   file, and `bin/package --no-test`: `xcodegen`, `xcodebuild`, the helpers into
   `Contents/Helpers`, signing inside out (each helper, the extension with its sandbox
   entitlements, the app) with the hardened runtime and a secure timestamp, notarising and
   stapling the app, the DMG signed, notarised and stapled. The keychain and the key go before
   the checks: `codesign --verify --strict`, `spctl -a -vv`, `stapler validate`. Read access
   only.
3. **publish**, on a tag only: the only job that may write; it publishes the release build's
   files and runs no code of this repository.

Actions are pinned by commit. A pull request from a fork gets no secrets and builds ad hoc.
Locally `bin/package` signs ad hoc too; give `SIGN_IDENTITY`, `NOTARY_KEY`, `NOTARY_KEY_ID`,
`NOTARY_ISSUER` to sign and notarise. `bin/package` fails when a signed bundle lacks its
entitlements, its extension point or its version, or when a release carries the self-test.

## The secrets

| secret | what |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | the Developer ID Application certificate and its key, a `.p12` without a password, base64 |
| `NOTARY_API_KEY_P8` | the App Store Connect team key `slipstream-notary` (access Developer), the `.p8` text |
| `NOTARY_API_KEY_ID` | its key id |
| `NOTARY_API_ISSUER_ID` | its issuer id |

No agent handles the keys; the maintainer sets the secrets.

## Team and certificate

- **Team `W9N692KH39`**, the maintainer's paid individual membership. `project.yml` and both
  entitlements files name it. Never `2X64N8XML3`, the free team of the Apple Development
  certificate. A move to another team gives Safari a new extension and makes every Mac's
  WireGuard key in the keychain unreadable: each Mac is enabled and paired again.
- **The Developer ID certificate expires on 2027-02-01**, with Apple's G1 intermediate. Builds
  signed with a timestamp and notarised before then keep running; new builds need a new
  certificate and a new `DEVELOPER_ID_P12_BASE64` ([TODO.md](TODO.md)).
- **The app group** `W9N692KH39.io.github.iphoneblog-web.slipstream` is team-prefixed, so a
  Developer ID app needs no provisioning profile for it.
