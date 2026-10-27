import Foundation

/// The one Funkhaus site this Mac works for. Set up at first launch (the app asks for the host
/// and checks `https://<host>/.well-known/funkhaus.json`), kept in the app group as `site.json`.
/// The extension answers on that site only, and the loopback only for it (docs/traps.md,
/// "Origins").
public struct SiteConfig: Codable, Equatable, Sendable {
    /// Lowercase host, no scheme, no path: `funkhaus.example.org`, or `host:port`.
    public var host: String
    /// The name the site gives itself, for the menu.
    public var name: String
    public var `protocol`: Int

    public init(host: String, name: String, protocol p: Int) {
        self.host = host
        self.name = name
        self.protocol = p
    }

    /// The origin a page of the site has: `https://<host>`.
    public var origin: String { "https://\(host)" }
    public var url: URL { URL(string: origin + "/")! }

    /// The extension protocols this app speaks (docs/extension-protocol.md).
    public static let protocols: Set<Int> = [SlipstreamIDs.protocolVersion]

    public enum Problem: Error, Equatable {
        case badHost
        case notFunkhaus(String)
        case unsupportedProtocol(Int)
        case tooOld(min: String)

        /// German, for the setup window.
        public var message: String {
            switch self {
            case .badHost: return "Das ist kein Hostname wie funkhaus.example.org."
            case .notFunkhaus(let why): return "Diese Seite antwortet nicht als Funkhaus (\(why))."
            case .unsupportedProtocol(let p): return "Diese Seite spricht Slipstream-Protokoll \(p); diese Version kann nur \(SiteConfig.protocols.sorted().map(String.init).joined(separator: ", "))."
            case .tooOld(let min): return "Diese Seite braucht Slipstream \(min) oder neuer. Bitte Slipstream aktualisieren."
            }
        }
    }

    /// What the user typed, as a host: a pasted URL loses its scheme and path; only letters,
    /// digits, dots, hyphens and a port; at least one dot.
    public static func host(from input: String) throws -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let name = parts.first, !name.isEmpty, name.contains("."),
              !name.hasPrefix("."), !name.hasSuffix("."), !name.contains(".."),
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            throw Problem.badHost
        }
        if parts.count == 2 {
            guard let port = Int(parts[1]), (1...65535).contains(port) else { throw Problem.badHost }
        }
        return s
    }

    /// The well-known file's URL for a host.
    public static func wellKnown(_ host: String) -> URL {
        URL(string: "https://\(host)/.well-known/funkhaus.json")!
    }

    /// Checks the answer of `/.well-known/funkhaus.json`:
    /// `{"app": "funkhaus", "name": …, "slipstream": {"protocol": 1, "min_version": "1.1.0"}}`.
    public static func check(host: String, wellKnown data: Data, appVersion: String) throws -> SiteConfig {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Problem.notFunkhaus("kein JSON")
        }
        guard o["app"] as? String == "funkhaus" else { throw Problem.notFunkhaus("app ist nicht funkhaus") }
        guard let s = o["slipstream"] as? [String: Any], let p = s["protocol"] as? Int else {
            throw Problem.notFunkhaus("slipstream.protocol fehlt")
        }
        guard protocols.contains(p) else { throw Problem.unsupportedProtocol(p) }
        if let min = s["min_version"] as? String, compare(appVersion, min) < 0 {
            throw Problem.tooOld(min: min)
        }
        let name = (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host
        return SiteConfig(host: host, name: name, protocol: p)
    }

    /// Dotted versions, numerically: `1.10.0` > `1.9.2`; missing parts count as 0. A build
    /// without a release tag (`0.0.0`) is older than every minimum.
    public static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    // MARK: - The file in the app group

    public static func load(from dir: URL) -> SiteConfig? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(SlipstreamIDs.siteFile)),
              let site = try? JSONCoding.decoder.decode(SiteConfig.self, from: data),
              (try? host(from: site.host)) == site.host else { return nil }
        return site
    }

    public func save(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(self).write(to: dir.appendingPathComponent(SlipstreamIDs.siteFile), options: .atomic)
    }
}
