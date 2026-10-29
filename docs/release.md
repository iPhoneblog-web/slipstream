# Releases, signing and notarisation

## A release

A tag `v<major>.<minor>.<patch>` on `main` is a release of **all of Slipstream at one version**:
the Mac app and the core inside it, the core for Linux and its image (Thorsten, 2026-10-29: "all
OS use Slipstream"; one number from 1.4.0, when the core left encode-queue at its v0.2.27). No Mac
runs an older core than the server. `.github/workflows/build.yml` builds every push and pull
request; on a tag it also publishes:

- the release, marked latest: `Slipstream.dmg`, `Slipstream.zip`, `slipstream-darwin-arm64`
  (the core as signed inside the app), `slipstream-linux-amd64`, `appcast.xml`, `SHA256SUMS`
  (all of them) and `SHA256SUMS.sig`. The file names carry no version, so
  `releases/latest/download/Slipstream.dmg` is always the newest.
- the image `ghcr.io/kyrios/slipstream:v<…>` (linux/amd64), which infra pins by digest.
- the tag `core/v<…>` on the same commit, under which Go finds the module
  `github.com/kyrios/slipstream/core`; encode-queue imports it at that version.

`bin/package` builds the core with the app's version (the last tag), so `slipstream --version`,
the queue's `app_version` and the app's About say the same number. A change the queue gates on
(a new job kind, a new flag) is a minor version; a fix is a patch.

```bash
git tag -a v1.0.1 -m "Slipstream 1.0.1" origin/main && git push origin v1.0.1
```

Never upload a build from a Mac by hand.

## Release notes

Every release has `release-notes/<version>.md`: a few German bullets for the people who use
Slipstream, what changed for them and what to do (release-notes/README.md has the format).
Merge it with the release's last pull request, before the tag. Thorsten, 2026-10-28: "Are we
using Sparkle properly? I'm not seeing "What's new" in some places"; up to 1.3.5 the appcast
carried only a link to the GitHub release, whose text was the install steps.

- **CI**: on a tag the test job runs `swift run release-notes <tag>` before anything is built, and
  a tag without its notes, or notes without a bullet, fails there. The build job makes
  `release-notes.html` and `release-notes.md` (the `release-notes` executable, `HelperCore.
  ReleaseNotes`) before any secret is on the runner. `bin/package` refuses a release build
  without the file too.
- **Sparkle**: `tools/appcast.swift` puts the HTML into the item's `<description>`, so the update
  dialog shows the notes; it refuses to write an appcast without them.
- **GitHub**: the publishing job puts the Markdown above the install steps and checksums.
- **The app** carries every version's notes in `Contents/Resources/release-notes`. After an
  update the menu starts with "Neu in 1.3.6 …" until it is opened: a window with the notes of
  every version since the last one seen (`notesSeenVersion` in the defaults). A Mac updated from
  a version without it sees the current version's; a new Mac sees none. "Über Slipstream" shows
  the current version's notes above the tool versions.

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
- **`SHA256SUMS.sig`**, on a tag too: `tools/sign.swift` signs the release's `SHA256SUMS` with
  the same key, after the same check against `SUPublicEDKey`. The file is the base64 of the
  Ed25519 signature over the exact bytes of `SHA256SUMS`, one line without a newline. A mirror
  of the DMG, such as a Funkhaus's, checks it against the public key in `project.yml`
  (`SPARKLE_PUBLIC_ED_KEY`) and then the DMG against the sums. The publishing job refuses a
  release without it. For a release from before (1.3.1 and older), run
  `.github/workflows/sign-sums.yml` by hand with the tag: it checks the release's DMG and zip
  against its sums, takes the public key from the app in its zip, signs, and attaches the
  signature.
- **Sparkle inside the app** is signed inside out by `bin/package`: its XPC services, Autoupdate,
  Updater.app, then the framework, like everything else with the hardened runtime.

## What CI does

Nothing runs beside a secret it does not need:

1. **test**: `swift test`, no secret. **core-test** (Linux and macOS), **core-real-ffmpeg** (the
   worker's tests in encode-toolchain 3, with its ffmpeg) and **core-image** (the Linux image
   built and started), no secret ([core/README.md](../core/README.md)).
2. **build**, after all tests but the image's: the core's Go modules and `bin/fetch-tools` (the
   toolchain from encode-queue's `toolchain-<N>` release, pinned by sha256; [worker.md](worker.md),
   [tools.md](tools.md)) before any secret is on the runner, then the Developer ID identity
   into a temporary keychain and the notary key into a file, and `bin/package --no-test` with
   `REQUIRE_WORKER=1`: `xcodegen`, `xcodebuild`, the core built for macOS and Linux, the
   helpers into `Contents/Helpers` (the log line `embedded: slipstream 1.4.0 (…)` shows which),
   signing inside out (each helper, the extension with its sandbox entitlements, the app) with
   the hardened runtime and a secure timestamp, notarising and stapling the app, the DMG
   signed, notarised and stapled. The keychain and the key go before the checks:
   `codesign --verify --strict`, `spctl -a -vv`, `stapler validate`, and `bin/check-launch`
   (the app starts, Settings opens, a cold start survives a slow worker). Read access only.
3. **core-publish-image**, on a tag only, after the signed build: the image from core-image's
   cache, pushed to ghcr. It may write packages, nothing else; the package `slipstream` grants
   this repository write access in its settings (2026-10-29).
4. **publish**, on a tag only, after the image: the only job that may write the repository; it
   publishes the release build's files, sets the tag `core/v<…>` and runs no code of this
   repository.

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
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle's EdDSA private key, the base64 Ed25519 seed (see "Updates"); used on tags and by `sign-sums.yml` only |

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
