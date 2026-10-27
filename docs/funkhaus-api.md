# What a Funkhaus offers Slipstream

The contract between a Funkhaus and Slipstream, abstract enough to build a compatible site from
it. A Funkhaus is any web app that serves these four things, and may offer a fifth, the connect
link; how it stores videos, encodes them or publishes them is its own business and not described
here.

| part | who calls whom | defined in |
|---|---|---|
| 1. the well-known file | Slipstream's setup → the site | this page |
| 2. the page's messages | the site's page ↔ Slipstream's Safari extension | this page, details in [extension-protocol.md](extension-protocol.md) |
| 3. the loopback API | the extension's bridge → Slipstream on the same Mac | [extension-protocol.md](extension-protocol.md), section 3; the site never calls it |
| 4. pairing with the queue | the site's server → its encode-queue; the page → Slipstream | encode-queue's [pipeline-admin.yaml](https://github.com/kyrios/encode-queue/blob/main/api/pipeline-admin.yaml) and [helper.yaml](https://github.com/kyrios/encode-queue/blob/main/api/helper.yaml) |
| 5. the connect link (optional) | the site's page → Slipstream's setup, through macOS | this page |

Protocol version **1**. A change that breaks a site raises it; a site names the versions it
speaks in its well-known file, and Slipstream names its own in every answer.

## 1. The well-known file

`GET https://<host>/.well-known/funkhaus.json`, without a login (Slipstream's setup has none),
answered from that host itself (no redirect to another host):

```json
{
  "app": "funkhaus",
  "name": "Funkhaus",
  "slipstream": { "protocol": 1, "min_version": "1.1.0" }
}
```

| field | meaning |
|---|---|
| `app` | always `"funkhaus"`; anything else is not a Funkhaus |
| `name` | what Slipstream's menu calls the site |
| `slipstream.protocol` | the extension protocol the site's page speaks |
| `slipstream.min_version` | the oldest Slipstream the site works with; an older one refuses the setup and asks for an update |

Slipstream keeps the host (lowercase, with a port only when it is not 443) and answers on
`https://<host>` only: its extension stays silent on every other page.

## 2. The page's messages

The page talks to the extension's content script with `window.postMessage` on its own window,
every message carrying `slipstream: 1`:

| message | from | answer |
|---|---|---|
| `hello` | the page | whether the extension and the app run; with the app running, a `MessagePort` to the bridge |
| `launch` | the page | the app started (or not) in the background, without a prompt; then say `hello` again |
| `ready` | the extension, unasked (Slipstream 1.2.0 on) | none; a page without a port says `hello` again |

Everything else goes over the `MessagePort`: the Mac's identity for pairing and the tunnel
configuration back, and one ProRes job per upload (the file in, the progress, the intermediate
back in Range slices, finish or cancel). The fields, the answers and the error codes are in
[extension-protocol.md](extension-protocol.md), sections 1 and 2.

**A site should:**

- wait about 3 s for the first `hello` answer, say `hello` again on `ready` and when its tab
  becomes visible, and treat no answer as "Slipstream missing, off, or not allowed on this site";
- show the three states it can tell apart (no extension, extension without the app, both), and
  offer "Slipstream starten" (`launch`) for the second;
- allow the extension's frame in its CSP: `frame-src 'self' safari-web-extension:`. The page
  never connects to `127.0.0.1` itself, so `connect-src` needs nothing.

## 3. The loopback API

Slipstream's local endpoint on `127.0.0.1`, which only the extension's bridge calls, with a
token it never shows the page and the site's origin in `X-Slipstream-Site`. A site needs to know
it exists, not to call it. [extension-protocol.md](extension-protocol.md), section 3.

## 4. Pairing with the queue

A Funkhaus runs [encode-queue](https://github.com/kyrios/encode-queue), and a paired Mac takes
its jobs through Slipstream's embedded worker:

1. The page asks the extension for the Mac's identity (`pairing.identity`): its name and its
   WireGuard public key. The private key stays in the Mac's keychain.
2. The site's server registers the worker with its queue (`POST /workers` in encode-queue's
   [pipeline-admin.yaml](https://github.com/kyrios/encode-queue/blob/main/api/pipeline-admin.yaml))
   and gets the worker's tunnel configuration.
3. The page hands it to Slipstream (`pairing.tunnel`), which starts its worker with it.

From then on the worker talks to the queue alone, through its tunnel, as encode-queue's
[helper.yaml](https://github.com/kyrios/encode-queue/blob/main/api/helper.yaml) describes. A
Mac without Safari is paired by paste instead: its public key in, the one-line configuration
out.

## 5. Connect link

A site may offer a link that sets Slipstream up for it without typing, from Slipstream 1.3.1 on:

```
slipstream://connect?site=<host>
```

- **`site`** is the host as the setup field takes it: lowercase letters, digits, dots and
  hyphens, at least one dot, a port only when it is not 443 (`funkhaus.example.org`,
  `funkhaus.example.org:8443`). Nothing else: no scheme, path, user or second parameter.
  Slipstream refuses any other link.
- **What happens.** macOS opens Slipstream (it starts if it is not running). Its setup window
  shows the host and runs the usual check of the well-known file (section 1). It then asks
  "Mit <name> (<host>) verbinden?", with the name from that file, and saves the site only when the
  user chooses **Verbinden**. Any website can send this link, so a click on it alone sets
  nothing up. A site set up before is replaced only by that click; the pairing stays.
- **Without Slipstream** macOS has no app for the scheme and the link does nothing. Show the
  link beside the download (the DMG), not instead of it, and say in words what it does.
- After a change of site, Slipstream asks the user to quit Safari with ⌘Q and open it again.
