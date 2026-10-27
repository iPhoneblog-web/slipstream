// Runs on every https page, in every frame, from document_start, because the site is the user's
// choice, not the manifest's. It works only for the Funkhaus Slipstream is set up for; on every
// other page it puts nothing into the page (docs/traps.md, "Origins"). One exception (1.3.1): a
// page that says hello and proves to be a Funkhaus, by its own /.well-known/funkhaus.json, hears
// that Slipstream is set up elsewhere (or not yet), never where, and may ask to connect; it gets
// no port and no bridge. Any other page gets no answer and no request. On the site it answers the page's hello (docs/extension-protocol.md, section 1) and, with
// Slipstream running, puts the bridge into the page and hands the page one end of a
// MessageChannel, the bridge the other.
//
// Fast: the page waits a second for the hello's answer. So both questions go out at
// document_start, before the page asks; the answer waits for them, never for the bridge frame,
// and the bridge gets its end of the channel once its frame has loaded (messages wait in the
// channel until then). On the site it also says `ready`, so a page that gave up says hello again.
(() => {
  const VERSION = browser.runtime.getManifest().version;
  const PROTOCOLS = [1];
  const BRIDGE = browser.runtime.getURL("bridge.html");
  const BRIDGE_ORIGIN = new URL(BRIDGE).origin;

  // Is this the configured site? Asked at once; every message waits for the answer. Asked again
  // when a page message finds it older than 2 s and it was no, so a page that just connected
  // (section 1, "connect") is the site at its next hello.
  const askSite = () => browser.runtime.sendMessage({ type: "site" }).then((r) => !!(r && r.match), () => false);
  let mine = askSite();
  let mineAt = Date.now();
  async function isMine() {
    if (!(await mine) && Date.now() - mineAt > 2000) {
      mineAt = Date.now();
      mine = askSite();
    }
    return mine;
  }

  // Is the app there? Asked at once on the site, and again when that answer is older than 2 s
  // (the user may have started Slipstream since).
  let presence = null;
  function askPresence() {
    const at = Date.now();
    const p = browser.runtime.sendMessage({ type: "presence" })
      .then((r) => r || { present: false, reason: "not-running" }, () => ({ present: false, reason: "not-running" }));
    presence = { at, p };
    p.then((r) => { if (r.present) ensureBridge(); });
    return p;
  }
  function currentPresence() {
    return presence && Date.now() - presence.at < 2000 ? presence.p : askPresence();
  }

  let bridge = null;
  function ensureBridge() {
    if (bridge) return bridge;
    bridge = new Promise((resolve) => {
      const frame = document.createElement("iframe");
      frame.src = BRIDGE;
      frame.setAttribute("aria-hidden", "true");
      frame.tabIndex = -1;
      frame.style.cssText = "display:none!important";
      frame.addEventListener("load", () => resolve(frame), { once: true });
      (document.body || document.documentElement).appendChild(frame);
    });
    return bridge;
  }

  // Another page: a Funkhaus only if its own origin serves the well-known file, from that host
  // (no redirect), with app "funkhaus" and a protocol this extension speaks. Fetched once per
  // page and only after the page said hello, so no other site ever sees a request. Same-origin,
  // so it needs no host permission; without cookies.
  let proof = null;
  function provenFunkhaus() {
    if (!proof) {
      proof = fetch(location.origin + "/.well-known/funkhaus.json", { credentials: "omit", redirect: "error", cache: "no-store" })
        .then((r) => (r.ok ? r.json() : null))
        .then((o) => !!(o && o.app === "funkhaus" && o.slipstream && PROTOCOLS.includes(o.slipstream.protocol)), () => false);
    }
    return proof;
  }

  // On a proven Funkhaus that is not the configured site: "not-set-up" or "other-site", nothing
  // about which site. null on any other page.
  async function elsewhere() {
    if (await isMine()) return null;
    if (!(await provenFunkhaus())) return null;
    let r = null;
    try { r = await browser.runtime.sendMessage({ type: "setup" }); } catch (e) { r = null; }
    if (!r || typeof r.configured !== "boolean") return null;
    return r.configured ? "other-site" : "not-set-up";
  }

  function announce() {
    window.postMessage({ slipstream: 1, type: "ready", extension: VERSION, protocol: 1 }, location.origin);
  }
  mine.then((m) => {
    if (!m) return;
    askPresence();
    // Now, and again once the page's own scripts may be listening.
    announce();
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", announce, { once: true });
    window.addEventListener("load", announce, { once: true });
  });

  // The page's "Slipstream starten" (docs/extension-protocol.md, section 1): the app extension
  // starts the app; the answer says whether it runs now. The page then says hello again.
  window.addEventListener("message", async (ev) => {
    const d = ev.data;
    if (ev.source !== window || !d || d.slipstream !== 1 || d.type !== "launch" || d.re !== undefined) return;
    if (!(await isMine())) return;
    let r;
    try {
      r = await browser.runtime.sendMessage({ type: "launch" });
    } catch (e) {
      r = { present: false, launched: false, reason: "not-running", error: String(e) };
    }
    presence = null;
    const helper = r && r.present ? { present: true, version: r.version, name: r.name }
                                  : { present: false, reason: (r && r.reason) || "not-running" };
    const ok = !!(r && r.present);
    window.postMessage(ok
      ? { slipstream: 1, type: "launch", re: d.id, ok: true, launched: !!r.launched, helper }
      : { slipstream: 1, type: "launch", re: d.id, ok: false, launched: !!(r && r.launched), helper,
          error: { code: "launch-failed", message: "Slipstream ließ sich nicht starten." + (r && r.error ? " (" + r.error + ")" : "") } },
      location.origin);
  });

  // A proven Funkhaus elsewhere asks Slipstream to connect to it (docs/extension-protocol.md,
  // section 1, "connect"). The app asks the user before it changes anything; the background
  // names the page's own host, never one the page sends.
  window.addEventListener("message", async (ev) => {
    const d = ev.data;
    if (ev.source !== window || !d || d.slipstream !== 1 || d.type !== "connect" || d.re !== undefined) return;
    if (!(await elsewhere())) return;
    let r = null;
    try { r = await browser.runtime.sendMessage({ type: "connect" }); } catch (e) { r = null; }
    window.postMessage(r && r.opened
      ? { slipstream: 1, type: "connect", re: d.id, ok: true }
      : { slipstream: 1, type: "connect", re: d.id, ok: false,
          error: { code: "connect-failed", message: "Slipstream ließ sich nicht öffnen." } },
      location.origin);
  });

  window.addEventListener("message", async (ev) => {
    const d = ev.data;
    if (ev.source !== window || !d || d.slipstream !== 1 || d.type !== "hello" || d.re !== undefined) return;
    if (!(await isMine())) {
      const reason = await elsewhere();
      if (reason) {
        window.postMessage({ slipstream: 1, type: "hello", re: d.id, ok: true, extension: VERSION, protocol: 1,
          helper: { present: false, reason } }, location.origin);
      }
      return;
    }
    const p = await currentPresence();
    const reply = { slipstream: 1, type: "hello", re: d.id, ok: true, extension: VERSION, protocol: 1,
      helper: p.present ? { present: true, version: p.version, name: p.name }
                        : { present: false, reason: p.reason || "not-running" } };
    if (!p.present) {
      window.postMessage(reply, location.origin);
      return;
    }
    // The answer goes now; the bridge's end follows when its frame has loaded.
    const channel = new MessageChannel();
    window.postMessage(reply, location.origin, [channel.port1]);
    ensureBridge().then((frame) => {
      frame.contentWindow.postMessage({ slipstream: 1, type: "port" }, BRIDGE_ORIGIN, [channel.port2]);
    });
  });
})();
