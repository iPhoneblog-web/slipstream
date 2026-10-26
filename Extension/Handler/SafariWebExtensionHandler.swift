import Foundation
import SafariServices

/// Safari's native messaging lands here, in the app extension, not in the app. It answers one
/// question, the presence check (docs/extension-protocol.md, section 3): is Slipstream running,
/// and on which port and with which token does its loopback endpoint listen. The app writes that
/// into the app group at every start; the extension reads it and checks the process is alive.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    /// SlipstreamIDs in HelperCore; repeated here so the extension links no package.
    static let appGroup = "W9N692KH39.io.github.iphoneblog-web.slipstream"
    static let loopbackFile = "loopback.json"

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
        let answer: [String: Any]
        switch message?["type"] as? String {
        case "presence":
            answer = Self.presence()
        default:
            answer = ["error": "unknown message"]
        }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: answer]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    static func presence() -> [String: Any] {
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
