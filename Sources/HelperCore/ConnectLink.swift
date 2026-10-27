import Foundation

/// The connect link a Funkhaus offers beside its download (docs/funkhaus-api.md, "Connect link"):
/// `slipstream://connect?site=<host>`. It only names a host for the setup window: the app checks
/// that host's `/.well-known/funkhaus.json` and saves nothing before the user confirms, because
/// any website can send this link.
public enum ConnectLink {
    public static let scheme = "slipstream"

    public enum Problem: Error, Equatable {
        /// Not `slipstream://connect`, or parameters other than one `site`.
        case notConnect
        /// `site` is not a host by the setup field's rules, or carries more than a host.
        case badHost

        /// German, for the setup window.
        public var message: String {
            switch self {
            case .notConnect: return "Dieser Link ist kein Slipstream-Link zum Verbinden."
            case .badHost: return "Der Link nennt kein Funkhaus wie funkhaus.example.org."
            }
        }
    }

    /// The host a connect link names, as `SiteConfig.host(from:)` writes it. Strict: exactly one
    /// parameter, `site`, holding a host and optional port only (no scheme, path, user or query),
    /// so a link cannot smuggle more than the host the setup field would take.
    public static func host(from url: URL) throws -> String {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == scheme, c.host?.lowercased() == "connect",
              c.user == nil, c.password == nil, c.port == nil, c.path.isEmpty || c.path == "/", c.fragment == nil,
              let items = c.queryItems, items.count == 1, items[0].name == "site" else {
            throw Problem.notConnect
        }
        guard let site = items[0].value, !site.isEmpty,
              site.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":") }),
              let host = try? SiteConfig.host(from: site) else {
            throw Problem.badHost
        }
        return host
    }
}
