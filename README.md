# Slipstream

Slipstream is the helper app on a Mac for the iPhoneblog video server (ADR-0007 in
iphoneblog-wordpress). It lives in the menu bar and does two things:

- **ProRes in the Funkhaus** (the upload center, `funkhaus.iphoneblog.de`, formerly
  `upload.iphoneblog.de`, which keeps working). A ProRes file dropped into the Funkhaus in Safari is
  encoded on this Mac into an HEVC intermediate at 50 Mbit/s before the page uploads it
  ([docs/encoding.md](docs/encoding.md)). Its Safari extension carries the file from the page to
  the app and the result back ([docs/extension-protocol.md](docs/extension-protocol.md)).
- **Jobs from the queue.** Once paired, it runs the queue's worker, which takes rungs and whisper
  runs from `encoder` through its own WireGuard tunnel, at low priority
  ([docs/worker.md](docs/worker.md)).

It was ProRes Drop, a drop window with its own 5 Mbit/s encode; that window is gone.

**Download:** [Slipstream.dmg](../../releases/latest/download/Slipstream.dmg), the newest
release, signed and notarised, for Macs with Apple Silicon and macOS 14 or later.

## Installieren

Für Alex, oder wer sonst ProRes ins Funkhaus zieht. Einmal pro Mac, etwa fünf Minuten.

1. **DMG laden:** [Slipstream.dmg](../../releases/latest/download/Slipstream.dmg). Öffnen und
   **Slipstream** auf **Programme** ziehen. Danach das DMG im Finder auswerfen.
2. **Slipstream starten:** in Programme doppelklicken. macOS fragt einmal, ob du eine App aus
   dem Internet öffnen willst: **Öffnen**. Slipstream hat kein Fenster; es erscheint als
   kleines Wind-Icon oben rechts in der Menüleiste.
3. **Die Safari-Extension einschalten:** Safari → **Einstellungen …** → **Erweiterungen**, bei
   **Slipstream** den Haken setzen. Safari fragt nach der Berechtigung für
   `funkhaus.iphoneblog.de` (und, falls gefragt, `upload.iphoneblog.de`): **Immer erlauben** (oder
   „Auf dieser Website immer erlauben“).
4. **Testen:** das Funkhaus in Safari öffnen (bzw. die Seite neu laden, falls sie schon
   offen war) und eine kurze ProRes-Datei hineinziehen. Statt der Meldung „ProRes wird hier
   nicht unterstützt“ zeigt die Seite jetzt den Fortschritt der Umwandlung.
5. **Bei jedem Login automatisch starten** (empfohlen): Systemeinstellungen → **Allgemein** →
   **Anmeldeobjekte** → unter „Beim Anmelden öffnen“ auf **+** und **Slipstream** wählen.

Ein Update: wenn das Menü „Update verfügbar“ zeigt, das neue DMG laden und die App in Programme
ersetzen. Die Extension bleibt eingeschaltet.

Wichtig: Slipstream muss laufen, solange ProRes umgewandelt wird, und der Tab bleibt offen, bis
der Upload durch ist. Schließt du ihn vorher, geht nichts verloren: Upload wieder öffnen, die
Seite macht weiter. Was das Menü zeigt und was bei Fehlern hilft: [docs/anleitung.md](docs/anleitung.md).

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
bin/rungs.zsh        ADR test 5: intermediates, the 4K rung from each, VMAF (docs/encoding.md)
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
| [docs/extension-protocol.md](docs/extension-protocol.md) | The messages between the Funkhaus, the extension and the app |
| [docs/worker.md](docs/worker.md) | How the app runs the queue's worker, and pairing |
| [docs/tools.md](docs/tools.md) | ffmpeg, x265, x264, whisper.cpp at `encoder`'s versions |
| [docs/release.md](docs/release.md) | Tags, CI, signing, notarisation, the secrets, the certificate's end |
| [docs/traps.md](docs/traps.md) | Safari, priority, encoding and signing traps |
| [docs/anleitung.md](docs/anleitung.md) | The user's guide, in German |
| [docs/TODO.md](docs/TODO.md) | Open work |

## Where it logs

```
/usr/bin/log show --last 1h --predicate 'subsystem == "io.github.iphoneblog-web.slipstream"'
```

Type `/usr/bin/log`, not `log`: zsh has a builtin of that name. Its files are in
`~/Library/Application Support/Slipstream` (the ProRes jobs, the tunnel, the worker's state).
