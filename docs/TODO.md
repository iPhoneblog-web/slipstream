# TODO

Open work, most important first. Delete an item when it is done.

- **Thorsten's first real run of v1.0.0** is the extension's two checks ([traps.md](traps.md),
  "Checks"): install, the extension on, pairing on the Encoder page, one ProRes upload inside
  wp-admin. Record there what it showed, and in [extension-protocol.md](extension-protocol.md)
  whether the upload center's CSP needs `frame-src safari-web-extension:`.
- **A new Developer ID certificate before 2027-02-01**, when the current one ends with Apple's G1
  intermediate: make it as before, export it as a `.p12` without a password, and replace the
  secret `DEVELOPER_ID_P12_BASE64` ([release.md](release.md)).
- **Alex's first real ProRes export through `bin/rungs.zsh`** (ADR-0007 test 5): if the 4K rung
  from the intermediate loses more than 1 VMAF point at 50 Mbit/s, raise the rate in
  [encoding.md](encoding.md) and `Plan.swift`. Also the encode time on his M2.
- **Look at the menu once**: the icon's states, the pause, the log window and About need a person
  looking at the screen.
- **HDR sources** (HLG or PQ from an iPhone timeline) are untested in the intermediate: the colour
  tags pass through, the HDR metadata may not.
