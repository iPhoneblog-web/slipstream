// The bridge: the extension's own page, a hidden iframe in the Funkhaus site. Safari lets it
// reach 127.0.0.1, which neither the page nor the content script may (docs/traps.md). It takes
// requests from the page over the MessagePort the content script handed it and calls
// Slipstream's loopback endpoint (docs/extension-protocol.md, sections 2 and 3). Any page could
// load it as a frame (it is web-accessible on every https page), so it takes a port only from a
// parent on the configured site, and names that site to the loopback, which checks it too.
const SLICE = 64 * 1024 * 1024;

// The page this bridge serves: the configured site's origin, once a port came from it.
let page = null;

let loop = null;

function fail(code, message) {
  return { code, message };
}

async function loopback(refresh) {
  if (!loop || refresh) {
    const r = await browser.runtime.sendMessage({ type: "loopback" });
    loop = r ? { base: `http://127.0.0.1:${r.port}/v1`, token: r.token, site: r.site } : null;
  }
  if (!loop) throw fail("helper-gone", "Slipstream läuft nicht.");
  return loop;
}

// One call to the helper; after a restart of the app (new port, new token) it asks again once.
async function call(method, path, { body, headers, raw } = {}, retried = false) {
  const l = await loopback(false);
  let r;
  try {
    r = await fetch(l.base + path, { method, body,
      headers: { "X-Slipstream-Token": l.token, "X-Slipstream-Site": page, ...(headers || {}) } });
  } catch (e) {
    if (!retried) { loop = null; return call(method, path, { body, headers, raw }, true); }
    throw fail("helper-gone", "Slipstream antwortet nicht.");
  }
  if (r.status === 403 && !retried) { loop = null; return call(method, path, { body, headers, raw }, true); }
  if (!r.ok) {
    let j = null;
    try { j = await r.json(); } catch (e) { /* no body */ }
    throw (j && j.error) || fail("internal", `Slipstream antwortet mit ${r.status}.`);
  }
  if (raw) return r;
  return r.status === 204 ? null : r.json();
}

const enc = encodeURIComponent;

// Where the index (moov) sits, from the top-level boxes' headers; null if not found.
async function findIndex(file) {
  let off = 0;
  for (let i = 0; i < 64 && off + 8 <= file.size; i++) {
    const h = new DataView(await file.slice(off, off + 16).arrayBuffer());
    let size = h.getUint32(0);
    const type = String.fromCharCode(h.getUint8(4), h.getUint8(5), h.getUint8(6), h.getUint8(7));
    if (size === 1 && h.byteLength >= 16) size = Number(h.getBigUint64(8));
    else if (size === 0) size = file.size - off;
    if (size < 8) return null;
    if (type === "moov") return [off, off + size];
    off += size;
  }
  return null;
}

// Sends what Slipstream lacks, in slices of at most 64 MiB, the slices holding the index first.
async function send(port, id, file) {
  let job = await call("GET", `/jobs/${enc(id)}`);
  if (job.name !== file.name || job.size !== file.size) throw fail("file-mismatch", "Die Datei passt nicht zu diesem Upload.");
  const slices = [];
  for (const [a, b] of job.missing || []) {
    for (let s = a; s < b; s += SLICE) slices.push([s, Math.min(s + SLICE, b)]);
  }
  const index = await findIndex(file);
  if (index) {
    const first = (s) => (s[0] < index[1] && s[1] > index[0] ? 0 : 1);
    slices.sort((x, y) => first(x) - first(y) || x[0] - y[0]);
  }
  for (const [a, b] of slices) {
    job = await call("PUT", `/jobs/${enc(id)}/source`, {
      body: file.slice(a, b),
      headers: { "Content-Type": "application/octet-stream", "Content-Range": `bytes ${a}-${b - 1}/${file.size}` },
    });
    port.postMessage({ type: "event", event: "job", job });
  }
  return job;
}

const watching = new Map();

function watch(port, id) {
  if (watching.has(id)) return;
  let last = "";
  const tick = async () => {
    if (!watching.has(id)) return;
    try {
      const job = await call("GET", `/jobs/${enc(id)}`);
      delete job.missing;
      const now = JSON.stringify(job);
      if (now !== last) { last = now; port.postMessage({ type: "event", event: "job", job }); }
      if (job.phase === "ready" || job.phase === "failed") { watching.delete(id); return; }
    } catch (e) {
      port.postMessage({ type: "event", event: "error", upload_id: id, error: e });
      watching.delete(id);
      return;
    }
    watching.set(id, setTimeout(tick, 500));
  };
  watching.set(id, setTimeout(tick, 500));
}

async function handle(port, m) {
  const id = m.upload_id;
  switch (m.type) {
    case "pairing.identity":
      return call("GET", "/pairing");
    case "pairing.tunnel":
      if (m.config_line) return void await call("PUT", "/pairing", { body: m.config_line, headers: { "Content-Type": "text/plain" } });
      if (m.tunnel) return void await call("PUT", "/pairing", { body: JSON.stringify(m.tunnel), headers: { "Content-Type": "application/json" } });
      throw fail("bad-request", "tunnel oder config_line fehlt.");
    case "job.open": {
      const f = m.file || {};
      const job = await call("PUT", `/jobs/${enc(id)}`, {
        body: JSON.stringify({ name: f.name, size: f.size, last_modified: f.last_modified }),
        headers: { "Content-Type": "application/json" },
      });
      return { job };
    }
    case "job.send":
      if (!(m.file instanceof Blob)) throw fail("bad-request", "file ist keine Datei.");
      return { job: await send(port, id, m.file) };
    case "job.watch": {
      const job = await call("GET", `/jobs/${enc(id)}`);
      watch(port, id);
      return { job };
    }
    case "job.unwatch":
      clearTimeout(watching.get(id));
      watching.delete(id);
      return {};
    case "job.read": {
      const offset = Number(m.offset), length = Number(m.length);
      if (!(offset >= 0) || !(length > 0) || length > SLICE) throw fail("bad-request", "offset oder length passt nicht.");
      const r = await call("GET", `/jobs/${enc(id)}/intermediate`, { headers: { Range: `bytes=${offset}-${offset + length - 1}` }, raw: true });
      const total = Number((r.headers.get("Content-Range") || "").split("/")[1]);
      return { blob: await r.blob(), offset, total };
    }
    case "job.finish":
    case "job.cancel":
      await call("DELETE", `/jobs/${enc(id)}?reason=${m.type === "job.finish" ? "finish" : "cancel"}`);
      return {};
    case "job.list":
      return call("GET", "/jobs");
    default:
      throw fail("bad-request", `Unbekannte Anfrage ${m.type}.`);
  }
}

window.addEventListener("message", async (ev) => {
  if (ev.source !== window.parent || window.parent === window) return;
  if (!ev.data || ev.data.slipstream !== 1 || ev.data.type !== "port" || !ev.ports[0]) return;
  let l;
  try { l = await loopback(true); } catch (e) { return; }
  // Only the configured site's page; everything else gets no port and no answer.
  if (!l.site || ev.origin !== l.site) return;
  page = ev.origin;
  const port = ev.ports[0];
  port.onmessage = async (e) => {
    const m = e.data || {};
    try {
      const answer = await handle(port, m);
      port.postMessage({ re: m.id, ok: true, ...(answer || {}) });
    } catch (err) {
      const error = err && err.code ? err : fail("internal", String(err));
      port.postMessage({ re: m.id, ok: false, error });
    }
  };
  port.start();
});
