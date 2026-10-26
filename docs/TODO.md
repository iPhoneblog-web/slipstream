# TODO

Open work, most important first. Delete an item when it is done.

- **Embed the worker and its toolchain** once `kyrios/encode-queue` releases `v0.1.0`:
  `bin/fetch-worker` picks both up in CI; check the asset names, the worker's flags and events
  against [worker.md](worker.md), and correct the page, the script and
  `HelperCore/WorkerProtocol.swift` where they differ.
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
