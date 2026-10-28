# The embedded worker

Slipstream carries the queue's worker, `encode-worker` from
[kyrios/encode-queue](https://github.com/kyrios/encode-queue), as
`Contents/Helpers/encode-worker`, the macOS arm64 binary of its release, with that release's
toolchain beside it (`bin/fetch-worker`, `v0.2.15`, toolchain 3; [tools.md](tools.md)). From
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
  --high-slots N   (only when the worker's -h lists it, v0.2.14 on)
  --ffmpeg <Helpers>/ffmpeg --ffprobe <Helpers>/ffprobe
  --whisper-cli <Helpers>/whisper-cli --whisper-models <support>/models --control stdio
  --whisper-version <from Resources/versions.txt>
  --toolchain-versions <Resources>/versions.txt   (only when the worker's -h lists it, v0.2.8 on)
```

`<support>` is `~/Library/Application Support/Slipstream`. Its environment is the app's, with
`FONTCONFIG_FILE` at `Resources/fonts/fonts.conf`, `XDG_CACHE_HOME` at
`~/Library/Caches/io.github.kyrios.slipstream` and `Contents/Helpers` first on `PATH`
([tools.md](tools.md), "Captions"). It starts only when `tunnel.conf` exists (pairing wrote it);
when it stops, see "When the worker stops" below.

**Standard input:** the first line is the WireGuard private key, base64, from the keychain.
After it, one JSON object per line:

| line | does |
|---|---|
| `{"cmd":"pause","until":"<RFC 3339>"}` | the menu's pause: suspend, give the job back after the queue's `pause_give_back_s`, claim nothing until then |
| `{"cmd":"resume"}` | end the pause |
| `{"cmd":"limits","threads":N,"gpu":bool,"jobs":N,"high_slots":N}` | the settings changed, at once: the next tool starts with them, and from v0.2.17 a running tool that started with more threads is held to `threads` (below); a worker before v0.2.14 ignores `high_slots` |
| `{"cmd":"quit"}` | give every lease back (reason `quit`) and exit; also on end of input |

**Two kinds of slots** (encode-queue v0.2.14): Settings → Leistung, "Aufträge gleichzeitig"
(`jobs`, 1 or 2) are the normal slots, which take every job; "Dazu für Sofort und Stufe 1"
(`high_slots`, none, 1 or 2, default 1) are the high-priority slots on top, which take only jobs
of those priorities, so a long archive job never keeps captions waiting. Beside other work the
queue hands such a job out only while the Mac's free memory holds it.

**The CPU limit holds for a running job too** (encode-queue v0.2.17; Thorsten, 2026-10-28: the
setting said 3 of 12 cores while an archive encode, started with all 12, ran at 978 % for
hours). x265's pool and whisper.cpp's threads are fixed when a tool starts, so a tool that uses
clearly more cores than a lowered limit runs in a duty cycle: in each 100 ms it runs for a share
and stands still (SIGSTOP and SIGCONT) for the rest, the share set from its measured CPU time,
so it averages the limit's cores and loses no work. A higher limit frees it at once. The worker
tells the queue the new limit at once too, so its estimates plan with it. encode-queue's README,
"The CPU limit", has the measurements.

**Standard output:** one JSON object per line, unknown events and fields ignored:

| event | fields | the menu shows |
|---|---|---|
| `connection` | `up`, `last_answer_at`, `refused: [{kind, reason}]`; when the tunnel goes up or down, and from v0.2.14 also when the last answer's minute changes | "Verbindung: verbunden" or "getrennt"; its submenu: the tunnel and the last answer, a job kind refused for a tool version |
| `job` | `lease_id`, `title`, `kind` (`rung`, `whisper`), `rung`, `slot` (`normal`, `high`; v0.2.14), `phase`, `fraction`, `fps`, `speed`, `eta_s`; about once a second per running job | a line per job, "Wandelt um: one_144_Hey_Siri · 12 %", with its details as a submenu; the first job's share in the icon |
| `idle` | | no job |
| `result` | `lease_id`, `title`, `verdict` (`accepted`, `rejected`, `given_back`), `check` | "Letzte Ereignisse", the last ten, newest first; the count today; it ends its lease's line |
| `paused` | `until` or null | the pause the queue knows |
| `update` | `latest` | "Update verfügbar", which asks Sparkle at once (release.md, "Updates") |
| `tools` | `tools: [{name, version}]` | About |
| `log` | `lease_id`, `line` | "Protokoll anzeigen" |
| `model` | `name`, `sha256`, `state` (`wanted`, `downloading`, `checking`, `calibrating`, `ready`, `failed`, `unavailable`), `bytes`, `bytes_done`, `speed`, `reason`; from encode-queue v0.2.14 the queue wants small and large-v3-turbo on every Mac with the RAM for it, fetched by the worker from the pinned Hugging Face revision and checked by sha256 | Settings → Leistung, "Whisper-Modelle" |
| `points` | `table`, `today`, `week`, `total`, `rank`, `of` (encode-queue v0.2.15; when the points or the place change) | "1.240 Punkte heute · Platz 1 von 3" under "Heute fertig"; nothing before the first event |
| `limits` | `threads` (the limit in effect, the Mac's cores when unlimited), `cores`, `throttled` (how many running jobs are held to it); at the start, after each `limits` line and when a job is held or freed (encode-queue v0.2.17) | "CPU für den Encoder: 3 von 12 Kernen", with "(laufender Auftrag gedrosselt)" while `throttled` is above 0; the setting before the first event and with an older worker |

**Several jobs at once.** With two or more slots the worker runs jobs side by side, each with
its own `job` events, and sends `idle` only once none is left. A job that ends beside another
sends no event of its own unless its result comes at once (one still being checked waits for
its verdict), so the menu drops a job it has not heard of for 15 s (`HelperCore.RunningJobs`).

Its standard error goes to the log window, to the unified log (info level, which macOS does not
keep) and to `~/Library/Logs/Slipstream/worker.log`.

## When the worker stops

- **The menu says why**: "Encoder gestoppt: <reason>, neuer Versuch <time>". The reason
  (`HelperCore.WorkerExit`) is the worker's last word on standard error: a Go `panic:` line, else
  its `encode-worker: …` line, else its last line; and how it ended (`Status N`, or `Signal N`
  with its name). The app reads standard error to its end, at most 2 s, before it decides, so a
  panic's text is there. The line goes as soon as a new worker sends any event.
- **It starts again with backoff** (`HelperCore.WorkerRestart`): 10 s after the first stop,
  doubling to at most 10 min while stops follow each other; a worker that ran 5 min or more
  starts the count again. A start that fails (the keychain, the process) counts as a stop and is
  tried again the same way. A new pairing starts at once and at the start of the count.
- **The log file**, `~/Library/Logs/Slipstream/worker.log` (`WorkerLog`, `HelperCore.RotatingLog`):
  every line of the worker's standard error and of a job's `log` events, and the app's own lines
  ("slipstream: worker started, pid …", "slipstream: worker stopped after … s: …"), each with
  the time. At 5 MB it moves to `worker.log.1`. The log window shows its path and "Im Finder
  zeigen". The app's lines also go to the unified log at notice level, which macOS keeps:
  `log show --last 1d --predicate 'subsystem == "io.github.kyrios.slipstream"'`.

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
