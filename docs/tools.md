# The worker's tools

The queue offers a worker a job only when its tools match the server's own worker exactly, as
text. So there is one toolchain, built from source by
[kyrios/encode-queue](https://github.com/kyrios/encode-queue) for Linux and for macOS arm64
(decided 2026-10-26), and Slipstream embeds the macOS build of its release:
`bin/fetch-worker` downloads it beside the worker, checks it against the release's
`SHA256SUMS`, and `bin/package` copies `ffmpeg`, `ffprobe`, `fc-list` and `whisper-cli` into
`Contents/Helpers`, and `versions.txt` and `fonts/` into `Contents/Resources`. This repository
builds no tool of its own.

The release's `encode-toolchain-darwin-arm64.tar.gz` holds `ffmpeg`, `ffprobe`, `fc-list`,
`whisper-cli`, `versions.txt` and `fonts/`, static, whisper.cpp with Metal. Its versions are
encode-queue's, the same on the server's worker image and on the Mac: toolchain 3, from
encode-queue `v0.2.7` on (ffmpeg 9.0.2, libx265 4.3, libx264 core 165 r3222, libvmaf 3.2.1,
lame 3.100, whisper.cpp v1.9.5, libass 0.17.5). `versions.txt` names them, and About shows it.
`bin/fetch-worker` pins the tag and both files' sha256; a new toolchain is a change to those
lines.

## Captions

Toolchain 3 builds libass and its stack (HarfBuzz, FriBidi, FreeType, fontconfig) from source on
Linux and macOS, so a Mac burns in the same captions as the server. `fonts/` holds Inter and a
`fonts.conf` that sees only those fonts. The worker would look for it beside ffmpeg, in
`Contents/fonts`, where a signed bundle keeps nothing; so the app starts the worker with
`FONTCONFIG_FILE` pointing at `Contents/Resources/fonts/fonts.conf`, fontconfig's cache in
`~/Library/Caches/io.github.kyrios.slipstream`, and `Contents/Helpers` first on `PATH`, so the
worker lists fonts with the toolchain's `fc-list` (`HelperCore/WorkerProtocol.swift`,
`WorkerEnvironment`). `bin/package` refuses a worker without `fc-list` and `fonts/`.

**libass's version** comes from `versions.txt`, which the worker looks for beside ffmpeg, where
codesign allows no data. From encode-queue `v0.2.8` the worker takes
`--toolchain-versions <Resources>/versions.txt` and reads every version from it; the app passes
the flag only when the worker's `-h` lists it. Worker `v0.2.7` reports no libass, so the queue
gives the Mac no caption job, though its ffmpeg renders them (docs/TODO.md).

- **When encode-queue's toolchain changes**, a new Slipstream embeds it. Until then the queue
  gives the Macs no rungs, and the menu says which tool differs.
- **A parity test decides** whether a Mac's rung equals the server's: the same clip, the same rung,
  size within 1 %, SSIM and PSNR within 0.1.
- **Licences:** see "Licences" below.
- The whisper models are not in the app. The app gives the worker the folder
  `~/Library/Application Support/Slipstream/models`; how a model gets there is the worker's
  business ([worker.md](worker.md)).

## Licences

**ffmpeg and ffprobe are GPLv3**: encode-queue builds them with `--enable-gpl --enable-version3`,
linked with x264 and x265 (GPLv2 or later), LAME (LGPL) and libvmaf (BSD-2-Clause-Patent);
whisper-cli is MIT. They are separate programs that Slipstream starts; Slipstream links none of
them, and its own code is MIT ([LICENSE](../LICENSE)), as is encode-worker's.

The app ships every licence in `Contents/Resources/licenses` (menu: "Lizenzen …"): Slipstream's,
encode-worker's, Sparkle's (MIT, linked into the app for updates), and the toolchain's folder
with each component's licence and `SOURCES.md`, which names each source by URL and sha256 and
ffmpeg's configuration. The source itself, the Corresponding Source, is attached to
encode-queue's `toolchain-<N>` release, from toolchain 2 on.
`bin/package` fails when it would ship ffmpeg without that folder.
