// The background asks Slipstream's app extension (native messaging) three things: which site the
// app is set up for, whether the app runs (and on which port, with which token), and to start it.
// It answers a content script only on that site, and the port and token only to the bridge
// (docs/extension-protocol.md, docs/traps.md "Origins").
const APP = "io.github.kyrios.slipstream";
const BRIDGE = browser.runtime.getURL("bridge.html");

async function native(type) {
  try {
    return await browser.runtime.sendNativeMessage(APP, { type });
  } catch (e) {
    return null;
  }
}

// The configured site's origin (`https://<host>`), or null before setup. Asked again after
// 10 s, so a site changed in the app reaches the extension soon.
let cache = { site: null, at: 0 };
async function site() {
  if (Date.now() - cache.at > 10000) {
    const r = await native("site");
    cache = { site: (r && typeof r.site === "string") ? r.site : null, at: Date.now() };
  }
  return cache.site;
}

function originOf(url) {
  try { return new URL(url).origin; } catch (e) { return null; }
}

// Whether the sender is a page (or frame) of the configured site.
async function onSite(sender) {
  const s = await site();
  return !!s && originOf(sender && sender.url) === s;
}

async function presence() {
  const r = await native("presence");
  return r && r.present ? r : { present: false, reason: (r && r.reason) || "not-running" };
}

async function answer(msg, sender) {
  if (msg.type === "site") {
    // Only yes or no: a content script elsewhere learns nothing about the site.
    return { match: await onSite(sender) };
  }
  if (msg.type === "presence") {
    if (!(await onSite(sender))) return null;
    const r = await presence();
    return r.present ? { present: true, version: r.version, name: r.name } : { present: false, reason: r.reason };
  }
  if (msg.type === "launch") {
    if (!(await onSite(sender))) return null;
    const r = await native("launch");
    return r && r.present
      ? { present: true, launched: !!r.launched, version: r.version, name: r.name }
      : { present: false, launched: !!(r && r.launched), reason: (r && r.reason) || "not-running", error: r && r.error };
  }
  if (msg.type === "loopback") {
    // Only the bridge, the extension's own page, learns the port, the token and the site; it
    // checks its parent against the site itself.
    if (!sender || !sender.url || !sender.url.startsWith(BRIDGE)) return null;
    const s = await site();
    if (!s) return null;
    const r = await presence();
    return r.present ? { port: r.port, token: r.token, site: s } : null;
  }
  return null;
}

browser.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg) return;
  answer(msg, sender).then(sendResponse, () => sendResponse(null));
  return true;
});
