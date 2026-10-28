# Traps

Things that cost time once, so they cost it only once. Each says what happens and what to do.

## Safari and the loopback

- **Safari blocks `http://127.0.0.1` and `http://localhost` from an HTTPS page and from a
  content script**: mixed content, "Load failed", and no request arrives. An extension page gets
  through, as an iframe in the page or as the background. Hence the bridge
  ([extension-protocol.md](extension-protocol.md)). Measured on Safari 26, 2026-10-26.
- **Safari forgets "Nicht signierte Erweiterungen erlauben" and every temporary extension when it
  quits.** A temporary extension's content script runs only after the tab reloads. The signed
  build avoids both.
- **Safari 26 upgrades plain HTTP sites to HTTPS** (neverssl.com came back as `https://`). Test
  an HTTP origin on `http://localhost:<port>`.
- **macOS has no `127.0.0.2`** until an alias is added. Bind to `127.0.0.1`.
- **An app extension built with xcodebuild did not show in Safari unsigned**; the temporary
  extension route did. **The bundle id must be lowercase**: Safari checks the extension's id
  against the app's as a prefix.
- **Safari's native messaging reaches the app extension, not the app.** The extension reads the
  port and token the app writes into their app group; the app extension needs no network.
- **`curl` waits a second per request** for `100 Continue` when it sends a large body; the
  loopback answers it. Safari does not send `Expect`.
- **Safari runs the content script only on a site the user allowed for the extension**, and a
  new build of the app registers the extension anew: after replacing 1.0.0 with 1.0.1 the
  Funkhaus got no answer to its hello ("ProRes geht hier nicht"), though the extension was on.
  Allow the Funkhaus site again in Safari → Einstellungen → Erweiterungen → Slipstream. The
  line "Safari-Extension" in the menu's "Verbindung" submenu says whether the extension reached
  the app since it started.
- **A Safari that was running before an install or update keeps the old extension**: after
  1.0.3 was deleted and 1.1.0 installed, the Funkhaus got no answer until Safari was quit with
  ⌘Q (2026-10-27). The install steps and the setup window say so.
- **A new bundle id is a new app** for macOS and Safari. 1.1.0 moved to
  `io.github.kyrios.slipstream`: the old app must be
  removed, the new extension turned on again, and the WireGuard key is new (the keychain item
  belongs to the old app), so the Mac is paired again. Jobs under
  `~/Library/Application Support/Slipstream` stay.

## Origins

**Slipstream answers one site**, the Funkhaus set up at first launch (`SiteConfig`, the app
group's `site.json`). The manifest matches every https page, because the site is the user's
choice and a Safari extension cannot change its matches at run time; each part checks the origin
itself, and a page elsewhere gets no answer, no bridge and no loopback. The one exception
(1.3.1): a page that says hello and serves a valid `/.well-known/funkhaus.json` itself hears
`other-site` or `not-set-up`, never which site, and may send `connect`, which opens the app's
question for that page's own host:

| where | checks | test |
|---|---|---|
| the background (`background.js`) | answers a content script only `{match}` for its page; `presence` and `launch` only for a page of the site; the port and token only to the bridge | `Tests/extension`: "a page elsewhere learns nothing", "only the bridge the port and token", "before setup nobody matches" |
| the content script (`content.js`) | asks whether the page is the site; elsewhere it answers no `launch` and puts no frame into the page, and answers `hello` and `connect` only after the page's own well-known file proved a Funkhaus, fetched only after a hello | "silent on a foreign page, no bridge in it", "a page that never says hello causes no request", "no answer on a page without a valid funkhaus.json", "a proven Funkhaus elsewhere hears other-site, no port, no bridge, no host" |
| `connect` (background, app extension, app) | the host is the sender's own origin, never the message's; never for the configured site or plain http; the app parses the link strictly and switches only on "Verbinden" | "connect: … only for a proven Funkhaus", "background: connect names the sender's host", `ConnectLinkTests`, bin/check-launch |
| the bridge (`bridge.js`) | web-accessible on every https page, so any page could frame it: it takes a port only from a parent on the site, and names that site to the loopback | "a parent elsewhere gets no port", "no site set up, no port" |
| the loopback (`LoopbackAPI`) | the request's `Origin` must be an extension page, the token must match, and `X-Slipstream-Site` must be the configured site; before setup nothing passes | `LoopbackTests`: `testOnlyTheExtensionsOrigin`, `testOnlyTheConfiguredSite` |
| the ProRes jobs (`ProResJobs`) | each job keeps the site that made it; after a site change the new site neither lists, reads, writes nor deletes the old one's | `testJobsBelongToTheirSite` |
| the app extension (`SafariWebExtensionHandler`) | reads the site from the app group and checks it is a host before handing it on; before setup `presence` says `not-set-up` | the setup and the site file: `SiteConfigTests` |

- **What Safari shows when the extension is turned on:** that it can read and change web pages
  on **all websites** ("alle Websites"), because of the `https://*/*` match. Safari still asks
  per site before a content script runs there; the user allows the Funkhaus site once. Other
  sites run the content script only if the user allows them too, and then it stays silent.
- **The stored host is written as the browser writes the origin** (`SiteConfig.host`): `:443` goes,
  `:08443` becomes `:8443`, and a port is plain ASCII digits (Swift's `Int("+443")` is 443, and
  that host made no URL). Otherwise the extension would compare against an origin Safari never
  reports.
- **The site is checked before it is kept:** `https://<host>/.well-known/funkhaus.json` must answer
  `{"app": "funkhaus", "slipstream": {"protocol": 1, "min_version": …}}` with a protocol this
  version speaks and a minimum it meets (`SiteConfig.check`). A login page or another app
  answers something else and is refused.

## The menu bar app

- **`SettingsLink` and SwiftUI's `Settings` scene do not open from a menu bar app's menu**
  (`LSUIElement`, so never the active app): "Einstellungen …" did nothing in 1.0.1. Settings and
  the log are windows AppKit owns (`Windows` in `SlipstreamApp.swift`), opened after
  `NSApp.activate`. `bin/check-launch` opens Settings through the same path in CI.
- **A published value that changes every second closes an open submenu**: MenuBarExtra rebuilds
  its menu on every change of what it reads, and in 1.1.0 the worker's `job` event (once a
  second), presence answers and the extension's last contact did so; "Pause" and "CPU …" opened
  and closed about once a second. The menu reads `MenuMirror` instead: finished text, changed
  only when a line's text changes (times to the minute, fps and speed rounded), and held while a
  menu is tracking.
- **A frozen Settings window** (1.3.0): every click froze it for seconds. Settings asked
  `SMAppService.mainApp.status` on the main thread, an XPC call to the background task daemon
  that takes about 0.5 s on a Mac Studio (measured 2026-10-28) and longer with many login
  items; a toggle made four such calls. Now `LoginItem` is async and runs off the main thread,
  and so do the keychain read for "Kopplung" and the models' disk use; the app group's URL and
  the Mac's name are read once (`Host.current()` waits on DNS). `Watchdog` logs "main thread
  blocked N ms" whenever the main queue takes 100 ms or more. `bin/check-launch` goes through the
  Settings tabs and a connect link and fails on a wait of 250 ms or more; it shows those from
  100 ms with the app's log around them (a CI runner may need over 100 ms for a tab's first
  layout). Nothing in a view's body or its `@State`
  initial values may call a daemon, the keychain or the disk.
- **One long settings form did not fit a 13-inch screen** and could not be resized (1.1.0).
  Settings has four tabs, each as tall as its content, in a resizable window with a minimum
  size.

## Priority

- **macOS's `background` quality of service keeps a process on the efficiency cores**, which
  makes x265 several times slower. Every encode runs at `nice 19` instead.
- **`nice 19` on the whole app starved its loopback**: with another encode at `nice 19` on the
  Mac (load 70), 1 GiB in 64 MiB slices came in at 160 MB/s; the app at normal priority, its
  encodes in their own processes at `nice 19`, took 563 MB/s with load 137 (Mac Studio,
  2026-10-26). So the app never renices itself; `ProcessEncoder` starts through
  `/usr/bin/nice -n 19`.
- **The worker starts at nice 0, user-initiated** (encode-queue v0.2.20): it puts each normal
  job's tools at nice 19 under the utility QoS clamp (`taskpolicy -c utility nice -n 19`) itself,
  and a Sofort job's at its own priority. Under `/usr/bin/nice -n 19`, as up to 1.3.6, a Sofort
  tool ran at 19 too, since an unprivileged process cannot lower its nice again. Measured on the
  Mac Studio (`ps -o nice,pri`): a tool of the worker started the old way ran at nice 19,
  priority 31; started the new way, a Sofort tool runs at nice 0, priority 31, and a normal one at
  nice 19, priority 20 (the utility clamp). `qualityOfService = .userInitiated` sets no clamp:
  a process launched with it shows priority 31, as with the default, and 20 with `.utility`. The
  core limit's duty cycle holds both kinds of tool (encode-queue's throttle test, normal and
  Sofort, about 1 core under a limit of 1).

## Encoding

- **VideoToolbox's time barely changes with the bit rate** (4.0 to 5.5 s for 10 s of 4K from 5 to
  120 Mbit/s on the M2 Max); x265's does.
- **`vmaf_4k_v0.6.1` is lenient**: VideoToolbox at 40 Mbit/s scores 98.9 with it and 98.5 with
  `vmaf_v0.6.1`, at 20 Mbit/s 94.8 against 90.0. Name the model with every score.

## Signing

- **The Developer ID certificate expires on 2027-02-01**, with Apple's G1 intermediate
  ([release.md](release.md)). Builds notarised before then keep running.
- **Two teams in one keychain**: the Apple Development certificate belongs to team
  `2X64N8XML3`, the Developer ID to `W9N692KH39`. The project sets `W9N692KH39`; a build signed
  with the other team's certificate gets a different extension id in Safari and cannot read the
  keychain item of the first.

## Keychain prompts from xcodebuild

**xcodebuild asks the login keychain for github.com** whenever it resolves a Swift package
(Sparkle): Xcode's own git, and SwiftPM before it downloads Sparkle's binary zip. On a Mac with
github.com in the keychain, every build opens a prompt, "xcodebuild möchte deine vertraulichen
Informationen verwenden …", and waits on it; unanswered, the build stalls on "Fetching" or
"Downloading binary artifact". `bin/package` therefore resolves with
`-scmProvider system -packageAuthorizationProvider netrc`: the system git and `~/.netrc`
instead of the keychain. Sparkle is public and needs no credentials. Any other xcodebuild that
resolves packages takes the same two flags, and none runs in a loop or a watcher on someone's
Mac: one stalled build is one prompt, a loop is a screen full.

## Checks

**The extension's two checks**, the part of the loopback test that needs the signed extension:
the bridge inside the frame the Funkhaus may run in and under its real page and CSP, and the
intermediate fetched back in 64 MiB `Range` slices through the bridge. **The first real run of a
release is these checks**: install, set up the site, turn the extension on, pair the Mac on the
Encoder page and upload one ProRes file. The pairing passes the bridge in the frame; the upload
passes the file in 64 MiB slices and the intermediate back in 64 MiB `Range` slices. A test
build with a self-test in the frame was built and dropped: any page of the parent's origin
could have driven it.
