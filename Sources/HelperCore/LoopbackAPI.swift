import Foundation

/// What `pairing.identity` answers.
public struct PairingIdentity: Codable, Equatable, Sendable {
    public var name: String
    public var publicKey: String
    public var paired: Bool
    public var tunnelAddress: String?

    public init(name: String, publicKey: String, paired: Bool, tunnelAddress: String?) {
        self.name = name
        self.publicKey = publicKey
        self.paired = paired
        self.tunnelAddress = tunnelAddress
    }
}

/// The app's side of pairing; the app keeps the key in the keychain and restarts its worker.
public protocol Pairing: Sendable {
    func identity() async throws -> PairingIdentity
    func setTunnel(_ config: TunnelConfig) async throws
}

/// The loopback endpoint's routes (docs/extension-protocol.md, section 3). Transport-free: the
/// app's listener parses a request, calls `handle`, and writes the answer.
public struct LoopbackAPI: Sendable {
    public let token: String
    public let version: String
    public let name: String
    public let jobs: ProResJobs
    public let pairing: Pairing
    /// Called for every request with the right token and site: the bridge reached the app.
    public let seen: (@Sendable () -> Void)?
    /// The configured site's origin (`https://<host>`), read at every request; nil before setup.
    public let site: @Sendable () -> String?

    public init(token: String, version: String, name: String, jobs: ProResJobs, pairing: Pairing,
                site: @escaping @Sendable () -> String?, seen: (@Sendable () -> Void)? = nil) {
        self.token = token
        self.version = version
        self.name = name
        self.jobs = jobs
        self.pairing = pairing
        self.site = site
        self.seen = seen
    }

    /// Only the extension's own pages: Safari gives them this scheme.
    public static func allowed(origin: String?) -> Bool {
        origin?.hasPrefix("safari-web-extension://") == true
    }

    private func cors(_ origin: String) -> [(String, String)] {
        [("Access-Control-Allow-Origin", origin), ("Vary", "Origin"),
         ("Access-Control-Expose-Headers", "Content-Range, Content-Length")]
    }

    public func handle(_ req: HTTPRequest) async -> HTTPResponse {
        guard let origin = req.header("origin"), Self.allowed(origin: origin) else {
            return HTTPResponse(status: 403)
        }
        if req.method == "OPTIONS" {
            var headers = cors(origin)
            headers += [("Access-Control-Allow-Methods", "GET, PUT, DELETE, OPTIONS"),
                        ("Access-Control-Allow-Headers", "X-Slipstream-Token, X-Slipstream-Site, Content-Type, Content-Range, Range"),
                        ("Access-Control-Max-Age", "600")]
            if req.header("access-control-request-private-network") != nil {
                headers.append(("Access-Control-Allow-Private-Network", "true"))
            }
            return HTTPResponse(status: 204, headers: headers)
        }
        var response: HTTPResponse
        if !Self.sameToken(req.header("x-slipstream-token") ?? "", token) {
            response = Self.problem(JobError("bad-request", "Falsches Token."), status: 403)
        } else if site() == nil || req.header("x-slipstream-site") != site() {
            // The bridge names the page it serves; anything but the configured site, or no site
            // set up yet, gets nothing (docs/traps.md, "Origins").
            response = Self.problem(JobError("bad-request", "Nicht das eingerichtete Funkhaus."), status: 403)
        } else {
            seen?()
            do {
                response = try await route(req, site: site())
            } catch {
                let e = JobError.from(error)
                response = Self.problem(e, status: e.status)
            }
        }
        response.headers += cors(origin)
        return response
    }

    static func problem(_ e: JobError, status: Int) -> HTTPResponse {
        .json(["error": e], status: status)
    }

    /// Compares in constant time.
    static func sameToken(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !y.isEmpty else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private struct OpenBody: Decodable {
        var name: String
        var size: Int64
        var lastModified: Int64?
    }

    private struct Ping: Encodable {
        var app = "Slipstream"
        var version: String
        var name: String
        var `protocol` = SlipstreamIDs.protocolVersion
    }

    /// `site` is the checked site; every job call is for that site's jobs only.
    private func route(_ req: HTTPRequest, site: String?) async throws -> HTTPResponse {
        let s = req.segments
        guard s.first == "v1" else { return HTTPResponse(status: 404) }
        // `PUT jobs/:id/source`: the route with the id taken out.
        var rest = Array(s.dropFirst())
        let id = rest.count >= 2 && rest[0] == "jobs" ? rest[1] : ""
        if !id.isEmpty { rest[1] = ":id" }
        switch "\(req.method) \(rest.joined(separator: "/"))" {
        case "GET ping":
            return .json(Ping(version: version, name: name))
        case "GET pairing":
            return .json(try await pairing.identity())
        case "PUT pairing":
            let config: TunnelConfig
            do { config = try TunnelConfig.fromPage(req.body) } catch {
                throw JobError("bad-request", "Die Tunnel-Konfiguration ist ungültig: \(error)")
            }
            try await pairing.setTunnel(config)
            return HTTPResponse(status: 204)
        case "GET jobs":
            return .json(["jobs": await jobs.list(site: site)])
        case "PUT jobs/:id":
            guard let body = try? JSONCoding.decoder.decode(OpenBody.self, from: req.body) else {
                throw JobError("bad-request", "Name oder Größe fehlt.")
            }
            return .json(try await jobs.open(id: id, name: body.name, size: body.size, lastModified: body.lastModified, site: site))
        case "GET jobs/:id":
            return .json(try await jobs.status(id: id, site: site))
        case "PUT jobs/:id/source":
            guard let header = req.header("content-range"), let (range, total) = HTTPParser.contentRange(header) else {
                throw JobError("bad-request", "Content-Range fehlt.")
            }
            return .json(try await jobs.receive(id: id, range: range, total: total, data: req.body, site: site))
        case "GET jobs/:id/intermediate":
            let status = try await jobs.status(id: id, site: site)
            guard status.phase == .ready, let info = status.intermediate else {
                throw JobError("not-ready", "Die Datei ist noch nicht fertig.")
            }
            let wanted = req.header("range").map { HTTPParser.range($0, total: info.size) }
                ?? (0..<min(info.size, Int64(ProResJobs.maxSlice)))
            guard let range = wanted else {
                return HTTPResponse(status: 416, headers: [("Content-Range", "bytes */\(info.size)")])
            }
            guard range.count <= ProResJobs.maxSlice else {
                throw JobError("bad-request", "Höchstens 64 MiB auf einmal.")
            }
            let (data, total) = try await jobs.readIntermediate(id: id, range: range, site: site)
            let last = range.lowerBound + Int64(data.count) - 1
            return HTTPResponse(status: 206, headers: [("Content-Type", "video/mp4"),
                                                       ("Content-Range", "bytes \(range.lowerBound)-\(last)/\(total)")],
                                body: data)
        case "DELETE jobs/:id":
            try await jobs.delete(id: id, site: site)
            return HTTPResponse(status: 204)
        default:
            return HTTPResponse(status: 404)
        }
    }
}
