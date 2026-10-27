// Runs on every https page, in every frame, from document_start, because the site is the user's
// choice, not the manifest's. It answers only on the Funkhaus site Slipstream is set up for; on
// every other page it stays silent, puts nothing into the page and answers nothing
// (docs/traps.md, "Origins"). There it answers the page's hello (docs/extension-protocol.md,
// section 1) and, with Slipstream running, puts the bridge into the page and hands the page one
// end of a MessageChannel, the bridge the other.
(() => {
  const VERSION = browser.runtime.getManifest().version;
  // Asked once per page: is this the configured site? Every message waits for the answer.
  const mine = browser.runtime.sendMessage({ type: "site" })
    .then((r) => !!(r && r.match), () => false);
  const BRIDGE = browser.runtime.getURL("bridge.html");
  const BRIDGE_ORIGIN = new URL(BRIDGE).origin;
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
    let p;
    try {
      p = await browser.runtime.sendMessage({ type: "presence" });
    } catch (e) {
      p = { present: false, reason: "not-running" };
    }
    const reply = { slipstream: 1, type: "hello", re: d.id, ok: true, extension: VERSION, protocol: 1,
      helper: p && p.present ? { present: true, version: p.version, name: p.name }
                             : { present: false, reason: (p && p.reason) || "not-running" } };
    if (!(p && p.present)) {
      window.postMessage(reply, location.origin);
      return;
    }
    window.postMessage(reply, location.origin, [await connect()]);
  });

  // A MessagePort to the bridge: one end for the page, the other for the bridge.
  async function connect() {
    const channel = new MessageChannel();
    const frame = await ensureBridge();
    frame.contentWindow.postMessage({ slipstream: 1, type: "port" }, BRIDGE_ORIGIN, [channel.port2]);
    return channel.port1;
  }
})();
