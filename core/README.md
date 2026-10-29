# Slipstream's core

The part of Slipstream that runs on every machine: the worker that takes jobs from
[encode-queue](https://github.com/kyrios/encode-queue) through its own userspace WireGuard and
runs them with ffmpeg, whisper.cpp and the aligner. The Mac app embeds it; on Linux it is the
image `ghcr.io/kyrios/slipstream`. Its history up to encode-queue v0.2.26 came along from
encode-queue, where it was `encode-worker`.

```
cmd/slipstream/      the binary (still named encode-worker when built: Dockerfile, the app)
worker/              jobs, tools, calibration, pause, the CPU limit, the control API
tunnel/              WireGuard: keys, the tunnel line, the device; the queue imports it too
aligner/             the align job's engines and facts; the queue imports them too
internal/config/     flags and environment variables
api/worker-control.yaml  the control API the app talks to (OpenAPI 3.1)
Dockerfile           the Linux image, on encode-toolchain (build context: this folder)
```

The Go module is `github.com/kyrios/slipstream/core`. The queue imports `tunnel`, `aligner` and,
for its end-to-end tests, `worker`; keep their exported names stable, or change encode-queue in
step.

```bash
cd core
go test -race ./...
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -o /tmp/encode-worker ./cmd/slipstream
docker build -t slipstream:dev .
```

The worker's tests that run ffmpeg skip without it; `EQ_REQUIRE_REAL_FFMPEG=1` makes them fail
instead (CI runs them in the toolchain image). The flags, the environment, the events on
standard output and how the queue schedules are described in encode-queue's
[README](https://github.com/kyrios/encode-queue#the-worker) for now ([docs/TODO.md](../docs/TODO.md)).

The protocol with the queue is encode-queue's `api/helper.yaml`. The queue compares the worker's
`app_version` with its own gates by number, field by field.
