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

  // The check of the upload center inside wp-admin's frame (docs/traps.md, "Checks"): wp-admin's
  // page asks the frame to run the bridge there, sends a synthetic file of `mb` MB through it
  // into a job of its own, deletes that job, reads `read_id`'s intermediate back in 64 MiB
  // slices, and gets the timings, never the bytes.
  const WP_ADMIN = ["https://www.iphoneblog.de"];
  window.addEventListener("message", async (ev) => {
    const d = ev.data;
    if (window === window.top || ev.source !== window.parent || !WP_ADMIN.includes(ev.origin)) return;
    if (!d || d.slipstream !== 1 || d.type !== "selftest") return;
    const out = { frame: location.href, extension: VERSION };
    try {
      let t = performance.now();
      const p = await browser.runtime.sendMessage({ type: "presence" });
      out.presence_ms = Math.round(performance.now() - t);
      out.present = !!(p && p.present);
      if (!out.present) throw new Error("helper not running");
      t = performance.now();
      const port = await connect();
      let n = 0;
      const pending = new Map();
      port.onmessage = (e) => { const r = pending.get(e.data.re); if (r) { pending.delete(e.data.re); r(e.data); } };
      port.start();
      const ask = (m) => new Promise((resolve) => { const id = "s" + (++n); pending.set(id, resolve); port.postMessage({ id, ...m }); });
      const list = await ask({ type: "job.list" });
      out.bridge_ms = Math.round(performance.now() - t);
      out.bridge_ok = list.ok;
      const mb = Math.min(Number(d.mb) || 512, 2048);
      const file = new File([new Uint8Array(mb * 1048576)], "selftest.mov");
      const id = "selftest-" + Date.now();
      await ask({ type: "job.open", upload_id: id, file: { name: file.name, size: file.size, last_modified: 0 } });
      t = performance.now();
      const sent = await ask({ type: "job.send", upload_id: id, file });
      out.send_MB_per_s = Math.round(mb / ((performance.now() - t) / 1000));
      out.send_ok = sent.ok && sent.job && sent.job.received === file.size;
      await ask({ type: "job.cancel", upload_id: id });
      if (d.read_id) {
        t = performance.now();
        let offset = 0, total = 1, slices = 0;
        while (offset < total) {
          const r = await ask({ type: "job.read", upload_id: d.read_id, offset, length: 64 * 1048576 });
          if (!r.ok) throw new Error(JSON.stringify(r.error));
          total = r.total;
          offset += r.blob.size;
          slices++;
        }
        out.read_MB = Math.round(total / 1048576);
        out.read_slices = slices;
        out.read_MB_per_s = Math.round((total / 1048576) / ((performance.now() - t) / 1000));
      }
    } catch (e) {
      out.error = String(e);
    }
    ev.source.postMessage({ slipstream: 1, type: "selftest", out }, ev.origin);
  });
})();
