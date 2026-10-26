# The worker's tools

The queue offers a worker a job only when its tools match `encoder`'s exactly, as text
(ADR-0007 §2). So there is one toolchain, built from source by
[kyrios/encode-queue](https://github.com/kyrios/encode-queue) for Linux and for macOS arm64
(Thorsten's decision, 2026-10-26), and Slipstream embeds the macOS build of its release:
`bin/fetch-worker` downloads it beside the worker, checks it against the release's
`SHA256SUMS`, and `bin/package` copies `ffmpeg`, `ffprobe`, `whisper-cli` and `versions.txt`
into `Contents/Helpers`. This repository builds no tool of its own.

| tool | version on `encoder` (Debian 13) |
|---|---|
| ffmpeg, ffprobe | 7.1.5, `7.1.5-0+deb13u1` |
| x265 | 4.1 |
| x264 | 0.164.3108 31e19f9 |
| whisper.cpp | v1.9.5, with Metal on the Mac |

- **When `encoder` moves to another version**, encode-queue's toolchain follows, and a new
  Slipstream embeds it. Until then the queue gives the Macs no rungs, and the menu says which
  tool differs.
- **ADR test 2 decides** whether a Mac's rung equals `encoder`'s: the same clip, the same rung,
  size within 1 %, SSIM and PSNR within 0.1.
- **Licence:** ffmpeg with x264 and x265 is GPL v2 or later; encode-queue's release names its
  sources.
- The whisper models are not in the app. The app gives the worker the folder
  `~/Library/Application Support/Slipstream/models`; how a model gets there is the worker's
  business ([worker.md](worker.md)).
