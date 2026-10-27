# The worker's tools

The queue offers a worker a job only when its tools match `encoder`'s exactly, as text
(ADR-0007 §2). So there is one toolchain, built from source by
[kyrios/encode-queue](https://github.com/kyrios/encode-queue) for Linux and for macOS arm64
(Thorsten's decision, 2026-10-26), and Slipstream embeds the macOS build of its release:
`bin/fetch-worker` downloads it beside the worker, checks it against the release's
`SHA256SUMS`, and `bin/package` copies `ffmpeg`, `ffprobe` and `whisper-cli` into
`Contents/Helpers`, and `versions.txt` into `Contents/Resources`. This repository builds no tool of its own.

The release's `encode-toolchain-darwin-arm64.tar.gz` holds `ffmpeg`, `ffprobe`, `whisper-cli`
and `versions.txt`, static, whisper.cpp with Metal. Its versions are encode-queue's, the same on
`encoder`'s worker image and on the Mac (toolchain 1, in encode-queue `v0.1.0` and `v0.2.0`: ffmpeg 9.0.2, libx265 4.3,
libx264 core 165 r3222, libvmaf 3.2.1, whisper.cpp v1.9.5); `versions.txt` names them, and About
shows it. `bin/fetch-worker` pins the tag and both files' sha256; a new toolchain is a change to
those lines. The Mac toolchain has no
libass, so a Mac announces no fonts and gets no jobs with burnt-in captions.

- **When encode-queue's toolchain changes**, a new Slipstream embeds it. Until then the queue
  gives the Macs no rungs, and the menu says which tool differs.
- **ADR test 2 decides** whether a Mac's rung equals `encoder`'s: the same clip, the same rung,
  size within 1 %, SSIM and PSNR within 0.1.
- **Licence:** ffmpeg with x264 and x265 is GPL v2 or later; encode-queue's release names its
  sources.
- The whisper models are not in the app. The app gives the worker the folder
  `~/Library/Application Support/Slipstream/models`; how a model gets there is the worker's
  business ([worker.md](worker.md)).
