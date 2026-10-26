// Runs on the upload center, in every frame, from document_start. Answers the page's hello
// (docs/extension-protocol.md, section 1) and, with Slipstream running, puts the bridge into the
// page and hands the page one end of a MessageChannel, the bridge the other.
(() => {
  const VERSION = browser.runtime.getManifest().version;
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

  window.addEventListener("message", async (ev) => {
    const d = ev.data;
    if (ev.source !== window || !d || d.slipstream !== 1 || d.type !== "hello" || d.re !== undefined) return;
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
