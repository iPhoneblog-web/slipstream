# Slipstream's core

The part of Slipstream that runs on every machine: the worker that takes jobs from
[encode-queue](https://github.com/kyrios/encode-queue) through its own userspace WireGuard and
runs them with ffmpeg, whisper.cpp and the aligner. The Mac app embeds it as
`Contents/Helpers/slipstream` ([docs/worker.md](../docs/worker.md)); on Linux it is the image
`ghcr.io/kyrios/slipstream`. Both come from one tag at one version ([docs/release.md](../docs/release.md)).
Up to encode-queue v0.2.27 it was encode-queue's `encode-worker`, and its history before the
move is there: `git log fc1e617 -- cmd/encode-worker internal/worker internal/tunnel
internal/aligner internal/config` in [kyrios/encode-queue](https://github.com/kyrios/encode-queue)
(fc1e617, the strip fix, is its last commit there). It came here in one commit (#34). The
`v0.2.x` numbers in comments and below are its versions from that time.

```
cmd/slipstream/      the binary
worker/              jobs, tools, calibration, pause, the CPU limit, the control API
tunnel/              WireGuard: keys, the tunnel line, the device; the queue imports it too
aligner/             the align job's engines and facts; the queue imports them too
internal/config/     flags and environment variables
api/worker-control.yaml  the control API the app talks to (OpenAPI 3.1)
Dockerfile           the Linux image, on encode-toolchain (build context: this folder)
```

The Go module is `github.com/kyrios/slipstream/core`, tagged `core/v<version>` beside each
release's `v<version>`. The queue imports `tunnel`, `aligner` and, for its end-to-end tests,
`worker`; keep their exported names stable, or change encode-queue in step.

```bash
cd core
go test -race ./...
go build -ldflags "-X main.version=1.4.0" -o /tmp/slipstream ./cmd/slipstream
docker build --build-arg VERSION=1.4.0 -t slipstream:dev .
```

The worker's tests that run ffmpeg skip without it; `EQ_REQUIRE_REAL_FFMPEG=1` makes them fail
instead (CI runs them in the toolchain image).

**One name, one version.** `slipstream --version` prints `slipstream 1.4.0 (macOS 26.5,
darwin/arm64)` or `slipstream 1.4.0 (Linux (Debian 13), linux/amd64)`. To the queue it reports
`app_version` 1.4.0 and `host_app` Slipstream 1.4.0, unless `--host-app-name` names another app;
the queue's view, its metrics and the Encoder page show that. The queue compares `app_version`
with its gates and its `EQ_MIN_APP_VERSION` by number, field by field, so 1.4.0 passes every
`v0.2.x` gate. The protocol is encode-queue's `api/helper.yaml`; how the queue schedules, the
slots, the CPU limit, pause and realtime jobs are described in encode-queue's
[README](https://github.com/kyrios/encode-queue#how-it-behaves).

## Running it

1. `slipstream pubkey` prints the worker's public key, made on first use (in
   `$EQ_WORKER_STATE_DIR/wireguard.key`, mode 0600; the private key never leaves the machine).
2. Paste it into the Encoder page (or `POST /v1/workers`): the answer is one line,
   `eqtunnel1 address=… server_public_key=… endpoint=… allowed_ips=… keepalive=25 api=…`.
3. Give the worker that line in `EQ_TUNNEL` or the file `EQ_TUNNEL_FILE` (default
   `$EQ_WORKER_STATE_DIR/tunnel.conf`) and start `slipstream run`.

| variable | what it is |
|---|---|
| `EQ_WORKER_STATE_DIR` | its key, tunnel line, model cache; default `encode-worker` in the user's config directory, where the key has always been |
| `EQ_TUNNEL`, `EQ_TUNNEL_FILE` | the tunnel line |
| `EQ_TUNNEL_ENDPOINT` | another `host:port` for the queue's UDP (a worker beside the queue) |
| `EQ_WORK_DIR` | where sources and results are while a job runs; default `$EQ_WORKER_STATE_DIR/work` |
| `EQ_FFMPEG`, `EQ_WHISPER_CLI` | the tools; default `ffmpeg`, `whisper-cli` from `PATH` |
| `EQ_WHISPER_VERSION` | the whisper.cpp release, when there is no `versions.txt` beside `whisper-cli` (the toolchain has one) |
| `EQ_TOOLCHAIN_VERSIONS` | the toolchain's `versions.txt` when it is not beside ffmpeg and whisper-cli (Slipstream's signed bundle keeps it in `Contents/Resources`): libass's and whisper.cpp's versions come from it; `EQ_WHISPER_VERSION` still wins (v0.2.8) |
| `EQ_WHISPER_MODELS_DIR` | the `*.bin` models, found by sha256 (`/models` in the image), and the aligner's folder `qwen3-forced-aligner-0.6b-c7cbfc20` (v0.2.16); the models the queue wants and, where the worker has an aligner engine, the aligner are fetched into it, or into `STATE/models` without it. A read-only folder (encoder's, filled by infra) fetches nothing: a wanted model it lacks is `unavailable`, provided by the host, never a failure |
| `EQ_ALIGNER_PYTHON` | the Python of the aligner's engine (v0.2.16; the image's `/opt/aligner/python/bin/python3`). Unset on an Apple-silicon Mac, the worker sets up MLX in `STATE/aligner` itself; `off`: no align jobs |
| `EQ_CALIBRATE` | `false` skips the calibration at pairing (`true` by default) |
| `EQ_FONTS` | font families to announce besides fontconfig's, comma-separated |
| `EQ_HOST_APP_NAME`, `EQ_HOST_APP_VERSION` | the app the worker runs inside (Slipstream and its version), shown on the Encoder page; never compared with the queue's minimum |
| `EQ_CPU_THREADS` | x265's pool (`pools=N`) and whisper.cpp's threads, and the cores a running tool may use (v0.2.17, encode-queue's README, **The CPU limit**); default the tools' own |
| `EQ_GPU` | whisper.cpp may use the GPU; default false |
| `EQ_MAX_PARALLEL_JOBS` | normal slots, which take every job; default 1 |
| `EQ_EFFICIENCY` | `all` or `archive`: those jobs run on the efficiency cores only (macOS's background QoS, v0.2.18); default `off` |
| `EQ_HIGH_PRIORITY_SLOTS` | high-priority slots on top, which take only `now` and `stage1` jobs; default 1, 0 none (v0.2.14) |
| `EQ_CONTROL_SOCKET` | a Unix socket for [worker-control.yaml](api/worker-control.yaml) |
| `EQ_WORKER_KEY_FILE` | the private key; default `$EQ_WORKER_STATE_DIR/wireguard.key`, made only when missing, so a key Ansible puts there keeps the worker's identity |
| `EQ_LOG_LEVEL` | as the queue's |

Every variable is also a flag (`slipstream -h`); the flag wins. `slipstream healthcheck`
exits 0 when the queue answered within two minutes (the image's `HEALTHCHECK`). The image runs
as uid 10001 (`worker`) with its scratch space in `/var/lib/encode-worker/work`.

## Embedding (the Mac app)

```
slipstream --key-stdin --tunnel-file … --state-dir … --name … --host-app-name … --host-app-version … \
  --threads N --gpu true|false --jobs N [--high-slots N] [--efficiency off|all|archive] --ffmpeg … --ffprobe … --whisper-cli … \
  --whisper-models … --control stdio
```

- **Standard input**: the first line is the WireGuard private key in base64 (the app keeps it
  in the keychain). Then one JSON object per line: `{"cmd":"pause","until":"<RFC 3339>","mode":"now"}`
  (`mode` `now` or `after_job`, v0.2.18; `now` without one), `{"cmd":"resume"}`,
  `{"cmd":"limits","threads":N,"gpu":bool,"jobs":N,"high_slots":N,"efficiency":"off"}`
  (`efficiency` `off`, `all` or `archive`, v0.2.18),
  `{"cmd":"quit"}` (give every lease back with `reason=quit`, exit 0). The end of input quits too.
  A `limits` line without `high_slots` or `efficiency` keeps them; a worker before 0.2.14 ignores the field (and
  `EQ_HIGH_PRIORITY_SLOTS`), so an app may send both to any worker. A `limits` line counts at
  once: the queue hears it, the next tool starts with it, and a running tool is held to its
  `threads` (v0.2.17, encode-queue's README, **The CPU limit**).
- **Standard output**: one JSON object per line, `event` naming it: `connection` (`up`,
  `last_answer_at`, `refused: [{kind, reason}]`), `job` (`lease_id`, `title`, `kind`, `rung`,
  `slot`: `normal` or `high`, `phase`, `fraction`, `fps`, `speed`, `eta_s`; at every phase change and once a second),
  `idle`, `result` (`lease_id`, `title`, `verdict`: `accepted`, `rejected` or `given_back`,
  `check`), `paused` (`until` or null, `mode`; v0.2.18), `update` (`latest`, when the queue wants a newer app),
  `tools` (`tools: [{name, version}]`), `points` (`table`, `today`, `week`, `total`, `rank`, `of`,
  when they or the place change; v0.2.15), `limits` (`threads` in effect, the machine's
  `cores`, `throttled`: how many running jobs are held to it, `efficiency` (v0.2.18); at the
  start, after each `limits` line and when a job is held or freed; v0.2.17), `log` (`lease_id`, `line`, and
  from v0.2.21 `level`: `DEBUG`, `INFO`, `WARN` or `ERROR`, slog's words), `calibrating` (`classes`,
  when the calibration clip starts) and `calibrated` (`classes`, when it is done), and `model`
  for each whisper model the queue wants (`name`, `sha256`, `state`: `wanted`, `downloading`,
  `checking`, `calibrating`, `ready`, `failed`, or `unavailable` when the models folder is read-only and the host provides the models; `bytes`, `bytes_done` while downloading,
  `speed` in times real time once timed, `reason` when it failed); the aligner's folder is
  `Qwen3-ForcedAligner-0.6B` among them (v0.2.16). `aligner` (v0.2.16): the aligner's engine,
  `state` `downloading`, `installing`, `ready` or `failed`, with `engine`, `bytes`, `bytes_done`
  and `reason`.
- **Standard error** is the log for people.

Without `--control stdio`, `--control <path>` serves [worker-control.yaml](api/worker-control.yaml)
on a Unix socket instead.
`slipstream selftest` encodes, cuts and remuxes a three-second clip with the machine's own
ffmpeg, checks each result and prints the figures; it exits 1 with the problems. A lease works
in its own folder below `EQ_WORK_DIR`, deleted however the lease ends; at start the worker
deletes any lease folder a crash left.

`slipstream versions` prints what the worker runs, exactly as the queue will compare it. The
worker builds ffmpeg's arguments itself from the job's structured settings, in the order
infra's `video-encode` did (a test compares them with `video-encode`'s own), so a worker's file
is the file `encoder` made before the split. The cut and the check run the commands
video-pipeline ran itself before v0.2.8 (testdata/pipeline-v028-args.json).


## The image

`ghcr.io/kyrios/slipstream:v<version>`, linux/amd64: the core (`/usr/local/bin/slipstream`, and
`encode-worker` as a link to it, the name up to v0.2.27) on encode-queue's toolchain image
(`encode-toolchain:3`, pinned by digest in the Dockerfile), and from v0.2.16 the aligner's
engine in `/opt/aligner`: python-build-standalone's CPython 3.12.12 with PyTorch 2.15.0 for the
CPU and qwen-asr 0.0.6, every package by its hash (`aligner/requirements-torch*.txt`): 1.8 GB
more in the image, 0.52 GB more to download. Models are not in the image; mount them at
`/models` or point `EQ_WHISPER_MODELS_DIR` at a read-only mount. The state stays in
`/var/lib/encode-worker`, where a host's volume keeps the key. Up to v0.2.27 encode-queue built
this image; its tags `v0.2.x` stay on the registry. infra pins the image by digest.

## Licence

The core is MIT, as all of Slipstream ([LICENSE](../LICENSE)). The toolchain under it is not:
ffmpeg and ffprobe are GPLv3, and every component's licence is in
`/opt/encode-toolchain/licenses` in the image, the source on encode-queue's `toolchain-<N>`
release. The core calls ffmpeg as a separate program; it links none of it.
