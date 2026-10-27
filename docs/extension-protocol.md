# The extension's messages

How a Funkhaus page talks to Slipstream on the same Mac: page ↔ content script ↔ bridge ↔
helper. The Funkhaus's design record (ADR-0007, §5 pairing and §7 ProRes) says why; this page
says what goes over the wire. Protocol version **1**. A change that breaks a page bumps it, and
the Funkhaus names the protocols it speaks in its well-known file (section 4).

```
page (the Funkhaus site set up in Slipstream, maybe inside another site's iframe)
  │  window.postMessage: hello only
content script (the extension, in the page's frame)
  │  browser.runtime: presence ──► background ──► native messaging ──► Slipstream's app extension
  │  hands the page one end of a MessageChannel, the bridge the other
bridge (the extension's page bridge.html, a hidden iframe in the page)
  │  fetch, X-Slipstream-Token, X-Slipstream-Site
helper (Slipstream's loopback endpoint on 127.0.0.1)
```

**The page never sees the port or the token**, and never fetches `127.0.0.1` itself: Safari
blocks that from an HTTPS page and from a content script ([traps.md](traps.md)). Only the
bridge does. **Everything here happens on the configured site only**; on every other page the
extension stays silent ([traps.md](traps.md), "Origins").

## 1. Hello: is the helper there?

The content script runs on every https page, in every frame, from `document_start`, and answers
only when the page's origin is the site Slipstream is set up for (`https://<host>`); the bridge
takes its port only from that origin. The page asks:

```js
window.postMessage({ slipstream: 1, type: "hello", id: "h1" }, location.origin);
```

The content script answers on the same window, with the same `id` in `re`:

```js
// helper running: one end of a MessageChannel travels with the answer (ev.ports[0])
{ slipstream: 1, type: "hello", re: "h1", ok: true, extension: "1.0.0",
  helper: { present: true, version: "1.0.0", name: "Studio-Mac" } }
// extension there, helper not running (or too old): no port
{ slipstream: 1, type: "hello", re: "h1", ok: true, extension: "1.0.0",
  helper: { present: false, reason: "not-running" } }       // or "too-old"
```

- **No answer within 3 s** (and no `ready`, see below) means no extension. The page then treats the helper as absent too:
  for a ProRes file it shows that ProRes is not supported here and that it works with Slipstream
  running, and uploads nothing (ADR-0007 §7, step 2).
- The page reads only messages with `ev.source === window`, `ev.data.slipstream === 1` and a
  `re` it sent. Its own `hello` comes back to its listener too; it has no `re`.
- A page may say `hello` again at any time (after the user starts Slipstream, say). Each answer
  with `present: true` carries a new port; the page drops the old one.

**`ready`, unasked (since 1.1.1).** On the configured site the content script also posts, at
`document_start`, again at `DOMContentLoaded` and at `load`:

```js
{ slipstream: 1, type: "ready", extension: "1.1.1", protocol: 1 }
```

It carries no port and needs no answer. It tells a page that its hello may now be answered.

**What the page should do**, so a slow first answer does not read as "no extension":

- Wait **3 s** for the first hello's answer, not 1 s. The extension answers on the site only once
  it knows the page is the site and whether the app runs; both are native-messaging round trips,
  and the first after Safari starts also starts the extension's background and app extension.
  The content script asks both at `document_start`, before the page does, and answers without
  waiting for the bridge frame, so a warm answer takes milliseconds.
- When a `ready` arrives and the page holds no port (no answer yet, or the answer said the
  helper is absent), say `hello` again.
- Say `hello` again when the tab becomes visible (`visibilitychange`) and the page holds no
  port: the user may have started Slipstream meanwhile.

**The three states** the hello tells apart, for the upload center's banner on a Mac in Safari:

| hello | state | the banner |
|---|---|---|
| no answer within 3 s, and no `ready` | the extension is missing, turned off, or not allowed on this site | install Slipstream, turn the extension on and allow it here |
| `helper.present: false` | the extension runs, the app does not | "Slipstream starten" (`launch`, below) |
| `helper.present: true` | both run | none |

### Launch: "Slipstream starten" (since 1.0.1)

```js
window.postMessage({ slipstream: 1, type: "launch", id: "l1" }, location.origin);
```

The extension's app extension starts the app it sits in, in the background and without a
prompt, and answers once the app's loopback is up, after at most about 10 s:

```js
{ slipstream: 1, type: "launch", re: "l1", ok: true, launched: true,
  helper: { present: true, version: "1.0.1", name: "Studio-Mac" } }
// it already ran: launched false
{ slipstream: 1, type: "launch", re: "l1", ok: true, launched: false, helper: { present: true, … } }
// it did not come up
{ slipstream: 1, type: "launch", re: "l1", ok: false, launched: false,
  helper: { present: false, reason: "not-running" },
  error: { code: "launch-failed", message: "Slipstream ließ sich nicht starten. (…)" } }
```

- No port travels with it: on `ok: true` the page says `hello` again and gets its port there.
- Allow 12 s for the answer. An extension older than 1.0.1 never answers `launch`; the page
  then sends the user to the release page instead.
- It is a message, not a URL scheme: the extension already reaches the app extension by
  native messaging, which starts the app with no Safari prompt and reports whether it came up; a
  `slipstream://` link would ask the user each time and could not tell the page anything.

## 2. The port: requests, answers, events

Everything else goes over the `MessagePort` from the hello. `File` and `Blob` objects pass as
they are (structured clone: a reference to the file on disk, not a copy).

```js
// request, page → bridge
{ id: "r7", type: "job.open", upload_id: "u_8f3k", file: { name: "Folge 12.mov", size: 5368709120, last_modified: 1761480000000 } }
// answer, bridge → page: exactly one per request
{ re: "r7", ok: true, job: { … } }
{ re: "r7", ok: false, error: { code: "helper-gone", message: "Slipstream antwortet nicht." } }
// event, bridge → page, no re
{ type: "event", event: "job", job: { … } }
```

`id` is any string the page picks, unique per port. `error.message` is German, for the user;
the page acts on `code`.

### Pairing

| type | request fields | answer fields |
|---|---|---|
| `pairing.identity` | none | `name`, `public_key` (WireGuard, base64, 44 characters), `paired` (bool), `tunnel_address` (or null) |
| `pairing.tunnel` | `tunnel`: the queue's `TunnelConfig` object, or `config_line`: its one-line form (`eqtunnel1 …`) | none: `ok: true` once Slipstream stored it and started its worker with it |

The page sends `name` and `public_key` to the queue's `POST /workers` and hands the answer's
`tunnel` (or `config_line`) back with `pairing.tunnel`. Pairing again replaces the old tunnel.
The private key never leaves the Mac's keychain.

### ProRes: a job per upload

One job per upload, named by the upload center's upload id (`upload_id`: 1 to 64 of
`A–Z a–z 0–9 _ -`).

| type | request fields | answer fields |
|---|---|---|
| `job.open` | `upload_id`, `file` (`name`, `size`, `last_modified`) | `job`. Creates the job, or returns the one Slipstream holds under that id (after the tab was closed) |
| `job.send` | `upload_id`, `file`: the `File` | `job`, once Slipstream has every byte. Sends only what Slipstream lacks, in 64 MiB slices, the slices holding the index (`moov`) first. Progress comes as events, phase `receiving` |
| `job.watch` | `upload_id` | `job` now, then an event at most twice a second while anything changes, and a last one at `ready` or `failed` |
| `job.unwatch` | `upload_id` | none |
| `job.read` | `upload_id`, `offset`, `length` (at most 67108864) | `blob`: a `Blob` of the intermediate's bytes `offset` to `offset + length − 1` (shorter at the end), `offset`, `total` |
| `job.finish` | `upload_id` | none. The upload center has the whole intermediate: Slipstream deletes its copy of the source and the intermediate |
| `job.cancel` | `upload_id` | none. Stops the job and deletes both files |
| `job.list` | none | `jobs`: every job Slipstream holds |

Slipstream starts the encode by itself once it has the whole source. It keeps both files
until `job.finish` or `job.cancel`, and deletes anything older than 7 days.

**The job** (the `job` field, in answers and events):

```js
{
  upload_id: "u_8f3k", name: "Folge 12.mov", size: 5368709120,
  phase: "receiving",   // receiving | queued | encoding | checking | ready | failed
  received: 2147483648, // bytes of the source Slipstream holds
  fraction: 0.0,        // the encode's share done, 0…1
  fps: null, speed: null, eta_s: null,
  intermediate: null,   // at ready: { size, duration_s, width, height, bit_rate, codec: "hvc1" }
  error: null,          // at failed: { code, message }
  created_at: "2026-10-26T21:00:00Z", updated_at: "2026-10-26T21:01:10Z"
}
```

`queued`: another ProRes job is encoding; Slipstream encodes one at a time.

### Error codes

| code | meaning |
|---|---|
| `helper-gone` | the bridge cannot reach Slipstream (it quit); say `hello` again |
| `bad-request` | a field is missing or malformed, or a slice is longer than 64 MiB |
| `unknown-job` | no job under that `upload_id` |
| `file-mismatch` | `job.send`'s file differs in name or size from the job's |
| `not-ready` | `job.read` before `ready` |
| `not-a-video`, `cannot-decode`, `check-failed` | the encode failed: the file, its codec, or Slipstream's check of the result (the intermediate's checks) |
| `disk-full` | no room for the copy or the intermediate |
| `not-paired` | `pairing.tunnel` without a key (Slipstream lost its keychain item) |
| `launch-failed` | `launch` could not start the app, or it did not come up within about 10 s (section 1) |
| `internal` | anything else; `message` says what |

## 3. The bridge and the helper (inside Slipstream; the page never calls this)

The background asks Slipstream's app extension by native messaging (`site`, `presence`,
`launch`); it reads the files the app writes into their app group (`site.json` at setup,
`loopback.json` at every start). It tells a content script only whether its page is the site,
and gives the port, the token and the site only to the bridge. The token is 32 random bytes, hex, new at every start of the app; the port is free and
random. The endpoint listens on `127.0.0.1` only, takes the token in `X-Slipstream-Token` and
the page's origin in `X-Slipstream-Site` (it must be the configured site), answers only an
`Origin` of `safari-web-extension://…`, and answers a preflight with
`Access-Control-Allow-Private-Network: true`. Before setup it answers nothing but `403`.

| request | does |
|---|---|
| `GET /v1/ping` | `{app, version, name}` |
| `GET /v1/pairing` | `{name, public_key, paired, tunnel_address}` |
| `PUT /v1/pairing` | a `TunnelConfig` (JSON) or a `config_line` (text) |
| `PUT /v1/jobs/{upload_id}` | `{name, size, last_modified}`: create or return the job |
| `PUT /v1/jobs/{upload_id}/source` | one slice, `Content-Range: bytes a-b/size`, at most 64 MiB |
| `GET /v1/jobs/{upload_id}` | the job, with `missing`: the byte ranges still to send, `[[start, end), …]` |
| `GET /v1/jobs/{upload_id}/intermediate` | the intermediate, `Range: bytes=a-b`, `206` |
| `DELETE /v1/jobs/{upload_id}?reason=finish\|cancel` | `204` |
| `GET /v1/jobs` | every job |

## 4. What a Funkhaus serves and allows

- **`/.well-known/funkhaus.json`**, without a login, so Slipstream's setup can check the site:

  ```json
  {"app": "funkhaus", "name": "Funkhaus", "slipstream": {"protocol": 1, "min_version": "1.1.0"}}
  ```

  Slipstream keeps the site only if `app` is `funkhaus`, it speaks `slipstream.protocol`, and its
  version is at least `min_version`. The answer must come from that host (no redirect away).
- **Its CSP lets the bridge in:** `frame-src 'self' safari-web-extension:`. Without a
  `frame-src` the page's `default-src 'self'` applies to frames, and Safari may apply it to an
  extension's frame too. The first real run of a release settles it ([traps.md](traps.md),
  "Checks"), and this line then says what it found.
- Nothing else: the page never connects to `127.0.0.1`, so `connect-src` stays `'self'`. The
  `Blob` from `job.read` goes into the page's own tus upload as any `Blob`.
