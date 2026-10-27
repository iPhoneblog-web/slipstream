# Slipstream

Slipstream is a Mac helper for a **Funkhaus**, a web app that takes video uploads and encodes
them on its own server with [encode-queue](https://github.com/kyrios/encode-queue). It lives in
the menu bar and does two things:

- **ProRes in the browser.** A ProRes file dropped into the Funkhaus in Safari is encoded on
  this Mac into an HEVC intermediate at 50 Mbit/s before the page uploads it
  ([docs/encoding.md](docs/encoding.md)). Its Safari extension carries the file from the page to
  the app and the result back ([docs/extension-protocol.md](docs/extension-protocol.md)).
- **Jobs from the queue.** Once paired, it runs encode-queue's worker, which takes encodes and
  whisper runs from the server through its own WireGuard tunnel, at low priority
  ([docs/worker.md](docs/worker.md)).

Slipstream works for one Funkhaus site, set up at first launch. Its extension answers that site
only and stays silent everywhere else ([docs/traps.md](docs/traps.md), "Origins").

## What is a Funkhaus?

A **Funkhaus** is a web app where a team uploads its videos and prepares their publication:
titles, posters, cuts, captions. Behind it runs an encode queue
([encode-queue](https://github.com/kyrios/encode-queue)) that turns each upload into the files
readers get. The Funkhaus's own code is not public; what it offers Slipstream is:
[docs/funkhaus-api.md](docs/funkhaus-api.md) describes that contract (the well-known file, the
page's messages, pairing with the queue), enough to build a compatible site.

Slipstream is the Funkhaus's helper on a Mac. It encodes ProRes before the browser uploads it,
and, once paired, it takes encode jobs from the queue when the Mac has time.

**Download:** [Slipstream.dmg](../../releases/latest/download/Slipstream.dmg), the newest
release, signed and notarised, for Macs with Apple Silicon and macOS 14 or later.

## Install

1. **Download and copy.** Open the DMG and drag **Slipstream** onto **Programme**
   (Applications). Start it; macOS asks once whether to open an app from the internet.
   Slipstream has no main window; it shows a wind icon in the menu bar.
2. **Set up the site.** The first launch opens "Slipstream einrichten": enter the Funkhaus's
   host, such as `funkhaus.example.org`, and choose **Prüfen und speichern**. Slipstream fetches
   `https://<host>/.well-known/funkhaus.json` and keeps the site only if it answers as a
   Funkhaus speaking a protocol this version knows. Until then the menu offers only
   **Einrichten …**. Settings can change the site later. **Bei der Anmeldung starten**, on by
   default, makes Slipstream a login item; Settings and System Settings → General → Login Items
   can turn it off.
3. **Quit Safari with ⌘Q and open it again**, after installing and after every update: a Safari
   that was running before keeps the old extension, and the Funkhaus then gets no answer.
4. **Turn the extension on.** Safari → Settings → Extensions → tick **Slipstream**. Safari says
   the extension can read and change pages on **all websites** ("alle Websites"): it is matched to
   every https page because the site is your choice, not the manifest's, but it answers only the
   site set up in step 2. Safari still asks per site: on the Funkhaus's first visit choose
   **Always allow on this website**.
5. **Check it.** Open the Funkhaus in Safari (reload it if it was open). The menu now says
   "Safari-Extension: verbunden". To pair the Mac for queue jobs, use the Funkhaus's Encoder page,
   "Diesen Mac als Helper hinzufügen".

An update: when the menu says "Update verfügbar", download the new DMG, replace the app, and
quit Safari with ⌘Q and open it again. The site, the extension and the pairing stay.

## Licences

Slipstream's own code is MIT: [LICENSE](LICENSE). It embeds programs under their own licences:
encode-worker (MIT) and encode-queue's toolchain, in which **ffmpeg and ffprobe are GPLv3**
(with x264 and x265, GPLv2 or later; LAME, LGPL; libvmaf, BSD-2-Clause-Patent) and whisper-cli is
MIT. Every licence is in the app (menu: "Lizenzen …"); the source of the toolchain is attached to
encode-queue's `toolchain-<N>` release ([docs/tools.md](docs/tools.md), "Licences").

## The code

Swift 6 (language mode 5), SwiftUI, AVFoundation, VideoToolbox, Network.framework; macOS 14 or
later, Apple Silicon. The app and its Safari extension are an Xcode project made by `xcodegen`
from `project.yml`, because only `xcodebuild` builds a Safari web extension; everything that
needs no app is a Swift package (`swift test`).

```
bin/package          tests, xcodebuild, helpers in, signed inside out, dist/Slipstream.dmg, .zip, SHA256SUMS
bin/fetch-worker     the worker and its tools (ffmpeg, ffprobe, whisper-cli) from kyrios/encode-queue's release
bin/check-launch     starts the built app and checks that Settings opens (CI)
bin/test-encode      a 4K ProRes sample through the intermediate, checked with ffprobe
bin/rungs.zsh        the intermediate's rate against the 1-point rule: intermediates, the 4K rung, VMAF
swift test           the tests (the fixtures are committed)
```

```
Sources/DropCore/        the intermediate: Plan, Transcoder and its checks, Naming, DropError, MP4Boxes
Sources/HelperCore/      the loopback endpoint (HTTP, routes), the ProRes jobs, the tunnel config and
                         WireGuard key, the worker's events and commands, the encode process
Sources/slipstream-cli/  the encode as a process: the app runs it at nice 19; also for bin/test-encode
App/Slipstream/          the menu bar app: menu, settings, log, loopback listener, worker, keychain
Extension/               the Safari web extension: native-messaging handler, content script, bridge
Tests/                   XCTest; DropCoreTests/fixtures holds small ffmpeg-made files (make.sh)
```

| Page | Read it for |
|---|---|
| [docs/encoding.md](docs/encoding.md) | The intermediate: what comes out, why 50 Mbit/s, the measurements |
| [docs/funkhaus-api.md](docs/funkhaus-api.md) | What a Funkhaus offers Slipstream: the well-known file, the page's messages, pairing |
| [docs/extension-protocol.md](docs/extension-protocol.md) | The messages between the Funkhaus, the extension and the app |
| [docs/worker.md](docs/worker.md) | How the app runs the queue's worker, and pairing |
| [docs/tools.md](docs/tools.md) | ffmpeg, x265, x264, whisper.cpp: encode-queue's toolchain |
| [docs/release.md](docs/release.md) | Tags, CI, signing, notarisation, the secrets, the certificate's end |
| [docs/traps.md](docs/traps.md) | Safari, priority, encoding and signing traps |
| [docs/anleitung.md](docs/anleitung.md) | The menu and what helps when something fails, in German, the app's language |
| [docs/TODO.md](docs/TODO.md) | Open work |

## Where it logs

```
/usr/bin/log show --last 1h --predicate 'subsystem == "io.github.kyrios.slipstream"'
```

Type `/usr/bin/log`, not `log`: zsh has a builtin of that name. Its files are in
`~/Library/Application Support/Slipstream` (the ProRes jobs, the tunnel, the worker's state).
