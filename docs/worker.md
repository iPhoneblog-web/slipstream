# The embedded worker

Slipstream carries the queue's worker, `encode-worker` from
[kyrios/encode-queue](https://github.com/kyrios/encode-queue), as
`Contents/Helpers/encode-worker`, the macOS arm64 binary of its release, with that release's
toolchain beside it (`bin/fetch-worker`, `v0.2.4`, toolchain 2; [tools.md](tools.md)). From
`v0.2.0` it reports the Mac's hardware (chip, cores, memory, OS) and its transfer rates to the
queue, and a tool ended by a signal as `killed`.

**No `--app-version`, but `--host-app-*`.** The helper API's `app_version` is the worker's own
release, which the queue compares with its `min_app_version`; the worker sends it by itself.
Slipstream's own name and version go to `host_app` (helper.yaml 1.1.1, worker `v0.2.1` and later), so the
queue and the Funkhaus's Encoder page see which Slipstream a Mac runs.

## How the app runs it

```
/usr/bin/nice -n 19 encode-worker --key-stdin --tunnel-file <support>/tunnel.conf
  --state-dir <support>/worker --name <Mac name> --host-app-name Slipstream --host-app-version <x.y.z>
  --threads N --gpu true|false --jobs N
  --ffmpeg <Helpers>/ffmpeg --ffprobe <Helpers>/ffprobe
  --whisper-cli <Helpers>/whisper-cli --whisper-models <support>/models --control stdio
  --whisper-version <from Resources/versions.txt>
```

`<support>` is `~/Library/Application Support/Slipstream`. It starts only when `tunnel.conf`
exists (pairing wrote it) and starts again 10 s after it exits.

**Standard input:** the first line is the WireGuard private key, base64, from the keychain.
After it, one JSON object per line:

| line | does |
|---|---|
| `{"cmd":"pause","until":"<RFC 3339>"}` | the menu's pause: suspend, give the job back after the queue's `pause_give_back_s`, claim nothing until then |
| `{"cmd":"resume"}` | end the pause |
| `{"cmd":"limits","threads":N,"gpu":bool,"jobs":N}` | the settings changed |
| `{"cmd":"quit"}` | give every lease back (reason `quit`) and exit; also on end of input |

**Standard output:** one JSON object per line, unknown events and fields ignored:

| event | fields | the menu shows |
|---|---|---|
| `connection` | `up`, `last_answer_at`, `refused: [{kind, reason}]` | tunnel up or down, the last answer, a job kind refused for a tool version |
| `job` | `lease_id`, `title`, `kind` (`rung`, `whisper`), `rung`, `phase`, `fraction`, `fps`, `speed`, `eta_s` | the current job, its share in the icon |
| `idle` | | no job |
| `result` | `title`, `verdict` (`accepted`, `rejected`, `given_back`), `check` | the last three results, the count today |
| `paused` | `until` or null | the pause the queue knows |
| `update` | `latest` | "Update verfügbar" |
| `tools` | `tools: [{name, version}]` | About |
| `log` | `lease_id`, `line` | "Protokoll anzeigen" |

Its standard error goes to the log window and to the unified log.

encode-queue implements this contract from `v0.1.0` on (its `worker-control.yaml`). It sends
`job` at every phase change and once a second. whisper.cpp's version comes with
`--whisper-version`: the toolchain's `versions.txt` lives in `Contents/Resources`, since codesign
takes no data in `Contents/Helpers`. `bin/fetch-worker` pins the release by tag and sha256;
`HelperCore/WorkerProtocol.swift` and its tests hold the format on this side.

## Pairing

The Funkhaus's Encoder page asks the extension for the Mac's name and public key
(`pairing.identity`), registers the worker with the queue, and hands the tunnel configuration
back (`pairing.tunnel`). Slipstream writes it as one `eqtunnel1 …` line to `tunnel.conf` and
restarts the worker. The key pair is made on first use and stays in the login keychain, item
"Slipstream WireGuard".
