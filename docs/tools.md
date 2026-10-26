# The worker's tools

The queue offers a worker a job only when its tools match `encoder`'s exactly, as text
(ADR-0007 §2). `encoder` runs Debian 13's packages, so `bin/build-tools` builds the same versions
for macOS arm64 from the same sources, checked by sha256, into `build/tools`; `bin/package`
copies them into `Contents/Helpers`.

| tool | version | source | built |
|---|---|---|---|
| ffmpeg, ffprobe | 7.1.5, reporting `7.1.5-0+deb13u1` as Debian's does | ffmpeg.org release tarball | `--enable-gpl --enable-libx264 --enable-libx265 --disable-autodetect --enable-zlib`, static |
| x265 | 4.1 | Debian's `x265_4.1.orig.tar.xz` | 8-bit main with the 10- and 12-bit libraries linked in, as Debian builds it |
| x264 | 0.164.3108 31e19f9 | Debian's orig tarball | every bit depth; the version written by hand, as Debian does, since the tarball has no git |
| whisper.cpp | v1.9.5 | the GitHub release tarball | Metal, the shader library embedded, static; `GGML_NATIVE=OFF` so it runs on any M chip |

- **When `encoder` moves to another version** (infra's `encoder` role, `encoder_whisper_version`
  and Debian's ffmpeg), change `bin/build-tools` in the same week: until then the queue gives
  Macs no rungs, and the menu says which tool differs.
- **ADR test 2 decides** whether a Mac's rung equals `encoder`'s: the same clip, the same
  rung, size within 1 %, SSIM and PSNR within 0.1. Debian's patches are not applied here.
- **Licence:** ffmpeg built with x264 and x265 is GPL v2 or later. The sources are the tarballs
  `bin/build-tools` names; whoever asks gets them from there.
- The whisper models are not in the app. The app gives the worker the folder
  `~/Library/Application Support/Slipstream/models`; how a model gets there is the worker's
  business ([worker.md](worker.md)).
