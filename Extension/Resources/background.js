// The background asks Slipstream's app extension (native messaging) whether the app runs, and
// on which port and with which token. The content script gets only yes or no; the token goes to
// the bridge alone (docs/extension-protocol.md).
const APP = "io.github.iphoneblog-web.slipstream";

async function presence() {
  try {
    const r = await browser.runtime.sendNativeMessage(APP, { type: "presence" });
    return r && r.present ? r : { present: false, reason: (r && r.reason) || "not-running" };
  } catch (e) {
    return { present: false, reason: "not-running" };
  }
}

const bridgeURL = browser.runtime.getURL("bridge.html");

browser.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg) return;
  if (msg.type === "presence") {
    presence().then((r) => sendResponse(r.present
      ? { present: true, version: r.version, name: r.name }
      : { present: false, reason: r.reason }));
    return true;
  }
  if (msg.type === "launch") {
    // The app extension starts the app it sits in, and answers once its loopback is up.
    browser.runtime.sendNativeMessage(APP, { type: "launch" })
      .then((r) => sendResponse(r && r.present
        ? { present: true, launched: !!r.launched, version: r.version, name: r.name }
        : { present: false, launched: !!(r && r.launched), reason: (r && r.reason) || "not-running", error: r && r.error }))
      .catch((e) => sendResponse({ present: false, launched: false, reason: "not-running", error: String(e) }));
    return true;
  }
  if (msg.type === "loopback") {
    // Only the bridge, the extension's own page, learns the port and the token.
    if (!sender.url || !sender.url.startsWith(bridgeURL)) { sendResponse(null); return; }
    presence().then((r) => sendResponse(r.present ? { port: r.port, token: r.token } : null));
    return true;
  }
});
