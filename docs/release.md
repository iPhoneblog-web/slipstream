# Releases, signing and notarisation

## A release

A tag `v<major>.<minor>.<patch>` on `main` is a release. `.github/workflows/build.yml` builds
every push and pull request; on a tag it also publishes `Slipstream.dmg`, `Slipstream.zip` and
`SHA256SUMS` as that tag's release, marked latest. The file names carry no version, so
`releases/latest/download/Slipstream.dmg` is always the newest.

```bash
git tag -a v1.0.1 -m "Slipstream 1.0.1" origin/main && git push origin v1.0.1
```

Never upload a build from a Mac by hand.

## Updates

**Sparkle 2** (pinned in `project.yml`) updates installed copies. Once a day the app reads
`https://github.com/kyrios/slipstream/releases/latest/download/appcast.xml`, which every release
publishes beside its DMG, and installs the release's `Slipstream.zip` in place, after checking
its EdDSA signature against `SUPublicEDKey`. "Nach Updates suchen …" checks at once; so does
"Update verfügbar", which appears when the queue asks for a newer app (the worker's `update`
event).

- **The key pair.** The public key is `SPARKLE_PUBLIC_ED_KEY` in `project.yml`, built into
  `SUPublicEDKey`. The private key, the base64 of a 32-byte Ed25519 seed as Sparkle's
  `generate_keys -x` exports it, exists only as the repository secret `SPARKLE_ED_PRIVATE_KEY`:
  never in a file, a commit, a log or a message. The maintainer makes it and sets the secret in
  one pipe, so nothing else holds it:

  ```bash
  swift -e 'import CryptoKit; import Foundation; let k = Curve25519.Signing.PrivateKey(); FileHandle.standardError.write(Data((k.publicKey.rawRepresentation.base64EncodedString() + "\n").utf8)); FileHandle.standardOutput.write(Data(k.rawRepresentation.base64EncodedString().utf8))' | gh secret set SPARKLE_ED_PRIVATE_KEY -R kyrios/slipstream
  ```

  The line it prints is the public key for `project.yml`. **A lost private key** means a new
  pair: copies with the old public key can then no longer update themselves, and their users
  install the next DMG by hand once.
- **On a tag**, CI's build job runs `tools/appcast.swift`: it signs `Slipstream.zip` with the
  secret, checks the signature against the app's own `SUPublicEDKey`, and writes
  `appcast.xml`, which the release attaches. `bin/package` refuses a tagged build without a
  public key, and the publishing job a release without an appcast.
- **Sparkle inside the app** is signed inside out by `bin/package`: its XPC services, Autoupdate,
  Updater.app, then the framework, like everything else with the hardened runtime.

## What CI does

Three jobs, so that nothing runs beside a secret it does not need:

1. **test**: `swift test`, no secret.
2. **build**: `bin/fetch-worker` (the worker and its tools from encode-queue's release, pinned
   by tag and sha256; [worker.md](worker.md), [tools.md](tools.md)) before any secret is on the
   runner, then the Developer ID identity into a temporary keychain and the notary key into a
   file, and `bin/package --no-test` with `REQUIRE_WORKER=1`: `xcodegen`, `xcodebuild`, the
   helpers into `Contents/Helpers` (the log line `embedded: encode-worker …` shows which),
   signing inside out (each helper, the extension with its sandbox entitlements, the app) with
   the hardened runtime and a secure timestamp, notarising and stapling the app, the DMG
   signed, notarised and stapled. The keychain and the key go before the checks:
   `codesign --verify --strict`, `spctl -a -vv`, `stapler validate`, and `bin/check-launch`
   (the app starts and Settings opens). Read access only.
3. **publish**, on a tag only: the only job that may write; it publishes the release build's
   files and runs no code of this repository.

Actions are pinned by commit. A pull request from a fork gets no secrets and builds ad hoc.
Locally `bin/package` signs ad hoc too; give `SIGN_IDENTITY`, `NOTARY_KEY`, `NOTARY_KEY_ID`,
`NOTARY_ISSUER` to sign and notarise. `bin/package` fails when a signed bundle lacks its
entitlements, its extension point or its version.

## The secrets

| secret | what |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | the Developer ID Application certificate and its key, a `.p12` without a password, base64 |
| `NOTARY_API_KEY_P8` | the App Store Connect team key `slipstream-notary` (access Developer), the `.p8` text |
| `NOTARY_API_KEY_ID` | its key id |
| `NOTARY_API_ISSUER_ID` | its issuer id |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle's EdDSA private key, the base64 Ed25519 seed (see "Updates"); used on tags only |

No agent handles the keys; the maintainer sets the secrets.

## Team and certificate

- **Team `W9N692KH39`**, the maintainer's paid individual membership. `project.yml` and both
  entitlements files name it. Never `2X64N8XML3`, the free team of the Apple Development
  certificate. A move to another team gives Safari a new extension and makes every Mac's
  WireGuard key in the keychain unreadable: each Mac is enabled and paired again.
- **The Developer ID certificate expires on 2027-02-01**, with Apple's G1 intermediate. Builds
  signed with a timestamp and notarised before then keep running; new builds need a new
  certificate and a new `DEVELOPER_ID_P12_BASE64` ([TODO.md](TODO.md)).
- **The app group** `W9N692KH39.io.github.kyrios.slipstream` is team-prefixed, so a
  Developer ID app needs no provisioning profile for it.
