import AppKit
import Foundation
import SafariServices

/// Safari's native messaging lands here, in the app extension, not in the app. It answers the
/// presence check (docs/extension-protocol.md, section 3): is Slipstream running, and on which
/// port and with which token does its loopback endpoint listen. The app writes that into the app
/// group at every start; the extension reads it and checks the process is alive. And it starts
/// the app on the page's request (`launch`, section 1).
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    /// SlipstreamIDs in HelperCore; repeated here so the extension links no package.
    static let appGroup = "W9N692KH39.io.github.kyrios.slipstream"
    static let loopbackFile = "loopback.json"
    static let extensionSeenFile = "extension-seen"
    static let siteFile = "site.json"

    private struct Announcement: Decodable {
        var port: Int
        var token: String
        var pid: Int32
        var version: String
        var name: String
    }

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        func reply(_ answer: [String: Any]) {
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: answer]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
        // The app's menu shows whether Safari's extension reaches it: one file's time.
        if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) {
            let marker = dir.appendingPathComponent(Self.extensionSeenFile)
            if !FileManager.default.createFile(atPath: marker.path, contents: Data()) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: marker.path)
            }
        }
        switch message?["type"] as? String {
        case "presence":
            reply(Self.presence())
        case "launch":
            Self.launch(reply)
        case "site":
            reply(["site": Self.site() ?? NSNull()])
        default:
            reply(["error": "unknown message"])
        }
    }

    /// The app this extension sits in: `Slipstream.app/Contents/PlugIns/<this>.appex`.
    static var containingApp: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Starts the containing app, without bringing it to the front, and answers once its
    /// loopback is announced, or after 10 s with what is there then.
    static func launch(_ reply: @escaping ([String: Any]) -> Void) {
        if presence()["present"] as? Bool == true {
            reply(presence().merging(["launched": false]) { $1 })
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: containingApp, configuration: configuration) { _, error in
            if let error {
                reply(["present": false, "reason": "not-running", "launched": false,
                       "error": error.localizedDescription])
                return
            }
            let deadline = Date().addingTimeInterval(10)
            func wait() {
                let now = presence()
                if now["present"] as? Bool == true || Date() > deadline {
                    reply(now.merging(["launched": true]) { $1 })
                } else {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25, execute: wait)
                }
            }
            wait()
        }
    }

    /// The configured site's origin, `https://<host>`, from the app group; nil before setup.
    /// The host is checked again here: the extension trusts no file it did not write.
    static func site() -> String? {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup),
              let data = try? Data(contentsOf: dir.appendingPathComponent(siteFile)),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = o["host"] as? String, !host.isEmpty,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":") }) else {
            return nil
        }
        return "https://" + host.lowercased()
    }

    static func presence() -> [String: Any] {
        guard site() != nil else { return ["present": false, "reason": "not-set-up"] }
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup),
              let data = try? Data(contentsOf: dir.appendingPathComponent(loopbackFile)),
              let note = try? JSONDecoder().decode(Announcement.self, from: data) else {
            return ["present": false, "reason": "not-running"]
        }
        // Alive: kill(pid, 0) succeeds, or the sandbox forbids the signal to a process that exists.
        guard kill(note.pid, 0) == 0 || errno == EPERM else {
            return ["present": false, "reason": "not-running"]
        }
        return ["present": true, "port": note.port, "token": note.token, "version": note.version, "name": note.name]
    }
}
