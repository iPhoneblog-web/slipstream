// Runs on every https page, in every frame, from document_start, because the site is the user's
// choice, not the manifest's. It answers only on the Funkhaus Slipstream is set up for; on every
// other page it stays silent, puts nothing into the page and answers nothing (docs/traps.md,
// "Origins"). There it answers the page's hello (docs/extension-protocol.md, section 1) and, with
// Slipstream running, puts the bridge into the page and hands the page one end of a
// MessageChannel, the bridge the other.
//
// Fast: the page waits a second for the hello's answer. So both questions go out at
// document_start, before the page asks; the answer waits for them, never for the bridge frame,
// and the bridge gets its end of the channel once its frame has loaded (messages wait in the
// channel until then). On the site it also says `ready`, so a page that gave up says hello again.
(() => {
  const VERSION = browser.runtime.getManifest().version;
  const BRIDGE = browser.runtime.getURL("bridge.html");
  const BRIDGE_ORIGIN = new URL(BRIDGE).origin;

  // Is this the configured site? Asked once per page; every message waits for the answer.
  const mine = browser.runtime.sendMessage({ type: "site" })
    .then((r) => !!(r && r.match), () => false);

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
    if (!(await mine)) return;
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

  window.addEventListener("message", async (ev) => {
    const d = ev.data;
    if (ev.source !== window || !d || d.slipstream !== 1 || d.type !== "hello" || d.re !== undefined) return;
    if (!(await mine)) return;
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
