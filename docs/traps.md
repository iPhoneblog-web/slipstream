# Traps

Things that cost time once, so they cost it only once. Each says what happens and what to do.

## Safari and the loopback

- **Safari blocks `http://127.0.0.1` and `http://localhost` from an HTTPS page and from a
  content script**: mixed content, "Load failed", and no request arrives. An extension page gets
  through, as an iframe in the page or as the background. Hence the bridge
  ([extension-protocol.md](extension-protocol.md)). Measured on Safari 26 (ADR-0007, test 1).
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

## Priority

- **macOS's `background` quality of service keeps a process on the efficiency cores**, which
  makes x265 several times slower. Every encode runs at `nice 19` instead.
- **`nice 19` on the whole app starved its loopback**: with another encode at `nice 19` on the
  Mac (load 70), 1 GiB in 64 MiB slices came in at 160 MB/s; the app at normal priority, its
  encodes in their own processes at `nice 19`, took 563 MB/s with load 137 (Mac Studio,
  2026-10-26). So the app never renices itself; `ProcessEncoder` and the worker start through
  `/usr/bin/nice -n 19`.

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

## Checks

**The extension's two checks** (ADR-0007 test 1, the part that needs the signed extension):
the bridge inside wp-admin's frame and under the upload center's real page and CSP, and the
intermediate fetched back in 64 MiB `Range` slices through the bridge. **Thorsten's first real
run of v1.0.0 is these checks**: he installs it, turns the extension on in Safari, pairs his Mac
on the Encoder page and uploads one ProRes file through the upload center inside wp-admin. The
pairing passes the bridge in the frame; the upload passes the file in 64 MiB slices and the
intermediate back in 64 MiB `Range` slices. A test build with a self-test in the frame was
built and dropped: any page of wp-admin's origin could have driven it.
