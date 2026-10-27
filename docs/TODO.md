# TODO

Open work, most important first. Delete an item when it is done.

- **The first real run of v1.1.0** is the extension's two checks ([traps.md](traps.md),
  "Checks"): install, set up the site, the extension on, pairing on the Encoder page, one ProRes
  upload inside the frame the Funkhaus runs in. Record there what it showed, and in
  [extension-protocol.md](extension-protocol.md) whether the Funkhaus's CSP needs
  `frame-src safari-web-extension:`.
- **Embed encode-queue v0.2.8** when it is tagged: its worker takes `--toolchain-versions`,
  which the app already passes when the worker lists it ([tools.md](tools.md), "Captions").
  Pin it in `bin/fetch-worker` and check that `encode-worker versions` lists libass 0.17.5.
- **Look at Settings → Leistung once on a paired Mac**: the whisper models as the worker reports
  them, a download's progress, the disk use.
- **A new Developer ID certificate before 2027-02-01**, when the current one ends with Apple's G1
  intermediate: make it as before, export it as a `.p12` without a password, and replace the
  secret `DEVELOPER_ID_P12_BASE64` ([release.md](release.md)).
- **The first real ProRes export through `bin/rungs.zsh`**: if the 4K rung
  from the intermediate loses more than 1 VMAF point at 50 Mbit/s, raise the rate in
  [encoding.md](encoding.md) and `Plan.swift`. Also the encode time on a plain M2.
- **Look at the menu once**: the icon's states, the pause, the log window and About need a person
  looking at the screen.
- **HDR sources** (HLG or PQ from an iPhone timeline) are untested in the intermediate: the colour
  tags pass through, the HDR metadata may not.
