// The extension's origin checks (docs/traps.md, "Origins"), on the real scripts in a Node vm
// with stand-ins for Safari's `browser`, the window and the document:
//   node --test Tests/extension/*.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";

const dir = new URL("../../Extension/Resources/", import.meta.url);
const source = (name) => readFileSync(new URL(name, dir), "utf8");
const SITE = "https://funkhaus.example.org";
const EXT = "safari-web-extension://ABCD";
const tick = () => new Promise((r) => setTimeout(r, 20));
// Objects from the vm come from another realm; compare plain copies.
const plain = (o) => (o === undefined ? o : JSON.parse(JSON.stringify(o)));

// A window: its listeners, what was posted on it, the frames put into its document.
function page(origin, { frameLoads = true } = {}) {
  const listeners = [];
  const posted = [];
  const frames = [];
  const win = {
    location: { origin },
    addEventListener: (t, f) => { if (t === "message") listeners.push(f); },
    postMessage: (data, target, ports) => posted.push({ data, target, ports }),
  };
  const document = {
    body: { appendChild: (f) => { frames.push(f); if (frameLoads) setTimeout(() => f.onload && f.onload(), 0); } },
    documentElement: null,
    readyState: "complete",
    addEventListener() {},
    createElement: () => {
      const f = { style: {}, setAttribute() {}, contentWindow: { postMessage() {} } };
      f.addEventListener = (t, fn) => { if (t === "load") f.onload = fn; };
      return f;
    },
  };
  // A message from the page itself, as the Funkhaus page sends its hello.
  const send = async (data) => { for (const f of listeners) await f({ source: win, data, ports: [] }); };
  return { win, document, listeners, posted, frames, send };
}

class FakeChannel { constructor() { this.port1 = { side: 1 }; this.port2 = { side: 2 }; } }

// wellKnown: what the page's own /.well-known/funkhaus.json answers (an object, or null for 404).
function runContent(origin, background, options = {}) {
  const p = page(origin, options);
  p.fetched = [];
  const fetch = async (url, init) => {
    p.fetched.push({ url, init });
    const body = options.wellKnown;
    return body ? { ok: true, json: async () => body } : { ok: false, json: async () => null };
  };
  const browser = {
    runtime: {
      getManifest: () => ({ version: "1.1.0" }),
      getURL: (x) => `${EXT}/${x}`,
      sendMessage: async (msg) => background(msg, { url: `${origin}/encoder` }),
    },
  };
  vm.runInNewContext(source("content.js"), {
    browser, window: p.win, document: p.document, location: p.win.location, MessageChannel: FakeChannel, URL, fetch,
  });
  return p;
}

// The real background.js with a fake native side: the app is set up for SITE and running.
function runBackground(nativeSite = SITE, nativeLog = []) {
  let listener;
  const browser = {
    runtime: {
      getURL: (x) => `${EXT}/${x}`,
      onMessage: { addListener: (f) => { listener = f; } },
      sendNativeMessage: async (_app, msg) => {
        nativeLog.push(msg);
        if (msg.type === "site") return { site: nativeSite };
        if (msg.type === "connect") return { opened: true };
        if (msg.type === "presence") return { present: true, port: 51760, token: "t0ken", version: "1.1.0", name: "Mac" };
        if (msg.type === "launch") return { present: true, launched: true, version: "1.1.0", name: "Mac" };
        return null;
      },
    },
  };
  vm.runInNewContext(source("background.js"), { browser, URL, Date });
  return (msg, sender) => new Promise((resolve) => {
    const kept = listener(msg, sender, resolve);
    if (kept !== true) resolve(undefined);
  });
}

test("background: a page elsewhere learns nothing", async () => {
  const bg = runBackground();
  assert.deepEqual(plain(await bg({ type: "site" }, { url: "https://evil.example/x" })), { match: false });
  assert.equal(await bg({ type: "presence" }, { url: "https://evil.example/x" }), null);
  assert.equal(await bg({ type: "launch" }, { url: "https://evil.example/x" }), null);
  assert.equal(await bg({ type: "loopback" }, { url: "https://evil.example/x" }), null);
  // A look-alike host is another origin.
  assert.equal(await bg({ type: "presence" }, { url: "https://funkhaus.example.org.evil.example/" }), null);
});

test("background: the configured site gets presence, only the bridge the port and token", async () => {
  const bg = runBackground();
  assert.deepEqual(plain(await bg({ type: "site" }, { url: `${SITE}/encoder` })), { match: true });
  assert.deepEqual(plain(await bg({ type: "presence" }, { url: `${SITE}/encoder` })), { present: true, version: "1.1.0", name: "Mac" });
  assert.equal(await bg({ type: "loopback" }, { url: `${SITE}/encoder` }), null);
  assert.deepEqual(plain(await bg({ type: "loopback" }, { url: `${EXT}/bridge.html` })), { port: 51760, token: "t0ken", site: SITE });
});

test("background: before setup nobody matches", async () => {
  const bg = runBackground(null);
  assert.deepEqual(plain(await bg({ type: "site" }, { url: `${SITE}/` })), { match: false });
  assert.equal(await bg({ type: "loopback" }, { url: `${EXT}/bridge.html` }), null);
});

test("content script: silent on a foreign page, no bridge in it", async () => {
  const bg = runBackground();
  const p = runContent("https://evil.example", bg);
  await p.send({ slipstream: 1, type: "hello", id: "h1" });
  await p.send({ slipstream: 1, type: "launch", id: "l1" });
  await tick();
  assert.equal(p.posted.length, 0);
  assert.equal(p.frames.length, 0);
});

test("content script: answers the configured site, with a port", async () => {
  const bg = runBackground();
  const p = runContent(SITE, bg);
  await p.send({ slipstream: 1, type: "hello", id: "h1" });
  await tick();
  const hello = p.posted.filter((m) => m.data.type === "hello");
  assert.equal(hello.length, 1);
  assert.equal(hello[0].data.re, "h1");
  assert.equal(hello[0].data.helper.present, true);
  assert.equal(hello[0].target, SITE);
  assert.equal(hello[0].ports.length, 1);
  assert.equal(p.frames.length, 1);
});

test("content script: on the site it says ready, unasked, so a late page says hello again", async () => {
  const p = runContent(SITE, runBackground());
  await tick();
  const ready = p.posted.filter((m) => m.data.type === "ready");
  assert.ok(ready.length >= 1);
  assert.equal(ready[0].target, SITE);
  assert.equal(ready[0].data.protocol, 1);
});

test("content script: the answer does not wait for the bridge frame", async () => {
  const p = runContent(SITE, runBackground(), { frameLoads: false });
  await p.send({ slipstream: 1, type: "hello", id: "h1" });
  await tick();
  const hello = p.posted.filter((m) => m.data.type === "hello");
  assert.equal(hello.length, 1);
  assert.equal(hello[0].ports.length, 1);
});

function runBridge(loopbackAnswer) {
  const listeners = [];
  const fetched = [];
  const parent = {};
  const win = { addEventListener: (t, f) => { if (t === "message") listeners.push(f); }, parent };
  const browser = { runtime: { sendMessage: async (m) => (m.type === "loopback" ? loopbackAnswer : null) } };
  const fetch = async (url, init) => { fetched.push({ url, init }); return { ok: true, status: 200, json: async () => ({ jobs: [] }) }; };
  vm.runInNewContext(source("bridge.js"), { browser, window: win, fetch, Blob: class {}, setTimeout, clearTimeout, URL });
  const offer = async (origin) => {
    const port = { posted: [], postMessage(m) { this.posted.push(m); }, start() {} };
    for (const f of listeners) await f({ source: parent, origin, data: { slipstream: 1, type: "port" }, ports: [port] });
    return port;
  };
  return { offer, fetched };
}

test("bridge: a parent elsewhere gets no port", async () => {
  const b = runBridge({ port: 51760, token: "t0ken", site: SITE });
  const port = await b.offer("https://evil.example");
  assert.equal(port.onmessage, undefined);
  assert.equal(b.fetched.length, 0);
});

test("bridge: the configured site gets a port, and the loopback hears which site", async () => {
  const b = runBridge({ port: 51760, token: "t0ken", site: SITE });
  const port = await b.offer(SITE);
  assert.equal(typeof port.onmessage, "function");
  await port.onmessage({ data: { id: "r1", type: "job.list" } });
  assert.equal(b.fetched.length, 1);
  assert.equal(b.fetched[0].init.headers["X-Slipstream-Site"], SITE);
  assert.equal(port.posted[0].ok, true);
});

test("bridge: no site set up, no port", async () => {
  const b = runBridge(null);
  const port = await b.offer(SITE);
  assert.equal(port.onmessage, undefined);
});

// 1.3.1: a Funkhaus page that is not the configured site.
const OTHER = "https://neu.example.org";
const FUNKHAUS = { app: "funkhaus", name: "Neu", slipstream: { protocol: 1 } };

test("content script: a page that never says hello causes no request", async () => {
  const p = runContent(OTHER, runBackground(), { wellKnown: FUNKHAUS });
  await tick();
  assert.equal(p.fetched.length, 0);
  assert.equal(p.posted.length, 0);
});

test("content script: no answer on a page without a valid funkhaus.json", async () => {
  for (const wellKnown of [null, { app: "other", slipstream: { protocol: 1 } }, { app: "funkhaus", slipstream: { protocol: 9 } }, { app: "funkhaus" }]) {
    const p = runContent(OTHER, runBackground(), { wellKnown });
    await p.send({ slipstream: 1, type: "hello", id: "h1" });
    await p.send({ slipstream: 1, type: "connect", id: "c1" });
    await tick();
    assert.equal(p.posted.length, 0, JSON.stringify(wellKnown));
    assert.equal(p.frames.length, 0);
  }
});

test("content script: a proven Funkhaus elsewhere hears other-site, no port, no bridge, no host", async () => {
  const p = runContent(OTHER, runBackground(), { wellKnown: FUNKHAUS });
  await p.send({ slipstream: 1, type: "hello", id: "h1" });
  await tick();
  assert.equal(p.fetched.length, 1);
  assert.equal(p.fetched[0].url, `${OTHER}/.well-known/funkhaus.json`);
  assert.equal(p.fetched[0].init.credentials, "omit");
  assert.equal(p.fetched[0].init.redirect, "error");
  const hello = p.posted.filter((m) => m.data.type === "hello");
  assert.equal(hello.length, 1);
  assert.deepEqual(plain(hello[0].data.helper), { present: false, reason: "other-site" });
  assert.equal(hello[0].ports, undefined);
  assert.equal(hello[0].target, OTHER);
  assert.equal(p.frames.length, 0);
  assert.equal(p.posted.filter((m) => m.data.type === "ready").length, 0);
  assert.ok(!JSON.stringify(plain(p.posted.map((m) => m.data))).includes("funkhaus.example.org"));
  // launch stays the configured site's.
  await p.send({ slipstream: 1, type: "launch", id: "l1" });
  await tick();
  assert.equal(p.posted.filter((m) => m.data.type === "launch").length, 0);
});

test("content script: a proven Funkhaus before any setup hears not-set-up", async () => {
  const p = runContent(OTHER, runBackground(null), { wellKnown: FUNKHAUS });
  await p.send({ slipstream: 1, type: "hello", id: "h1" });
  await tick();
  assert.equal(plain(p.posted[0].data.helper).reason, "not-set-up");
});

test("connect: the app opens the link for the page's own host, and only for a proven Funkhaus", async () => {
  const log = [];
  const p = runContent(OTHER, runBackground(SITE, log), { wellKnown: FUNKHAUS });
  await p.send({ slipstream: 1, type: "connect", id: "c1", site: "evil.example" });
  await tick();
  const connects = log.filter((m) => m.type === "connect");
  assert.equal(connects.length, 1);
  assert.equal(connects[0].site, "neu.example.org");
  const answer = p.posted.filter((m) => m.data.type === "connect");
  assert.equal(answer[0].data.re, "c1");
  assert.equal(answer[0].data.ok, true);

  const log2 = [];
  const q = runContent("https://evil.example", runBackground(SITE, log2), { wellKnown: null });
  await q.send({ slipstream: 1, type: "connect", id: "c1" });
  await tick();
  assert.equal(log2.filter((m) => m.type === "connect").length, 0);
  assert.equal(q.posted.length, 0);
});

test("background: connect names the sender's host, never for the configured site or plain http", async () => {
  const log = [];
  const bg = runBackground(SITE, log);
  assert.deepEqual(plain(await bg({ type: "connect", site: "evil.example" }, { url: `${OTHER}/upload` })), { opened: true });
  assert.equal(log.filter((m) => m.type === "connect")[0].site, "neu.example.org");
  assert.equal(await bg({ type: "connect" }, { url: `${SITE}/upload` }), null);
  assert.equal(await bg({ type: "connect" }, { url: "http://neu.example.org/" }), null);
  // setup says only yes or no.
  assert.deepEqual(plain(await bg({ type: "setup" }, { url: `${OTHER}/` })), { configured: true });
});
