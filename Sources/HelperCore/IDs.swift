import Foundation

/// The names the app, its Safari extension and the log share. Lowercase: Safari checks the
/// extension's bundle id against the app's as a prefix, and a capital letter broke that in the
/// test of ADR-0007 (docs/traps.md).
public enum SlipstreamIDs {
    public static let bundle = "io.github.iphoneblog-web.slipstream"
    public static let extensionBundle = "io.github.iphoneblog-web.slipstream.extension"
    /// The app group both read: the app writes `loopbackFile` into it, the extension reads it.
    /// Team-prefixed, so a Developer ID app needs no provisioning profile for it.
    public static let appGroup = "W9N692KH39.io.github.iphoneblog-web.slipstream"
    public static let loopbackFile = "loopback.json"
    public static let logSubsystem = bundle
    /// The extension protocol's version (docs/extension-protocol.md).
    public static let protocolVersion = 1
}

/// What the app writes into the app group at every start, for the extension's presence check
/// (docs/extension-protocol.md, section 3).
public struct LoopbackAnnouncement: Codable, Equatable, Sendable {
    public var port: Int
    public var token: String
    public var pid: Int32
    public var version: String
    public var name: String

    public init(port: Int, token: String, pid: Int32, version: String, name: String) {
        self.port = port
        self.token = token
        self.pid = pid
        self.version = version
        self.name = name
    }

    /// 32 random bytes as hex.
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
