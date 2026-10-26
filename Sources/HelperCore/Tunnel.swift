import CryptoKit
import Foundation

/// The worker's tunnel to the queue, as the queue's enrolment answers it (encode-queue's
/// pipeline-admin API, `TunnelConfig`), and its one-line form `eqtunnel1 key=value …`, which
/// the worker reads from a file.
public struct TunnelConfig: Codable, Equatable, Sendable {
    public var address: String
    public var serverPublicKey: String
    public var endpoint: String
    public var allowedIps: String
    public var persistentKeepaliveS: Int?
    public var api: String

    public init(address: String, serverPublicKey: String, endpoint: String, allowedIps: String,
                persistentKeepaliveS: Int?, api: String) {
        self.address = address
        self.serverPublicKey = serverPublicKey
        self.endpoint = endpoint
        self.allowedIps = allowedIps
        self.persistentKeepaliveS = persistentKeepaliveS
        self.api = api
    }

    public enum Invalid: Error, Equatable {
        case format(String)
    }

    /// The order the queue's spec gives.
    public var configLine: String {
        var parts = ["eqtunnel1", "address=\(address)", "server_public_key=\(serverPublicKey)",
                     "endpoint=\(endpoint)", "allowed_ips=\(allowedIps)"]
        if let k = persistentKeepaliveS { parts.append("keepalive=\(k)") }
        parts.append("api=\(api)")
        return parts.joined(separator: " ")
    }

    public init(configLine: String) throws {
        let words = configLine.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard words.first == "eqtunnel1" else { throw Invalid.format("Zeile beginnt nicht mit eqtunnel1") }
        var values: [String: String] = [:]
        for word in words.dropFirst() {
            guard let eq = word.firstIndex(of: "=") else { throw Invalid.format("\(word) ohne =") }
            values[String(word[..<eq])] = String(word[word.index(after: eq)...])
        }
        func need(_ key: String) throws -> String {
            guard let v = values[key], !v.isEmpty else { throw Invalid.format("\(key) fehlt") }
            return v
        }
        self.init(address: try need("address"), serverPublicKey: try need("server_public_key"),
                  endpoint: try need("endpoint"), allowedIps: try need("allowed_ips"),
                  persistentKeepaliveS: values["keepalive"].flatMap(Int.init), api: try need("api"))
        try validate()
    }

    /// A config from the page: the JSON object, or `{"config_line": "…"}`.
    public static func fromPage(_ body: Data) throws -> TunnelConfig {
        if let text = String(data: body, encoding: .utf8), text.hasPrefix("eqtunnel1") {
            return try TunnelConfig(configLine: text)
        }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw Invalid.format("kein JSON-Objekt")
        }
        if let line = object["config_line"] as? String { return try TunnelConfig(configLine: line) }
        let source = (object["tunnel"] as? [String: Any]) ?? object
        let data = try JSONSerialization.data(withJSONObject: source)
        guard let config = try? JSONCoding.decoder.decode(TunnelConfig.self, from: data) else {
            throw Invalid.format("Felder fehlen")
        }
        try config.validate()
        return config
    }

    public func validate() throws {
        let all = [address, serverPublicKey, endpoint, allowedIps, api]
        if all.contains(where: { $0.contains(" ") || $0.isEmpty }) { throw Invalid.format("leerer Wert oder Leerzeichen") }
        guard address.contains("/") else { throw Invalid.format("address ohne Präfix") }
        guard WireGuardKey.isValidPublic(serverPublicKey) else { throw Invalid.format("server_public_key") }
        guard let colon = endpoint.lastIndex(of: ":"), Int(endpoint[endpoint.index(after: colon)...]) != nil else {
            throw Invalid.format("endpoint ohne Port")
        }
        guard let url = URL(string: api), url.scheme == "http" || url.scheme == "https" else {
            throw Invalid.format("api")
        }
    }
}

/// A WireGuard key pair: Curve25519, base64. The app keeps the private key in the keychain and
/// hands it to the worker on its standard input; it never leaves the Mac.
public struct WireGuardKey: Sendable {
    public let privateKey: Data

    public init(privateKey: Data) throws {
        guard privateKey.count == 32 else { throw TunnelConfig.Invalid.format("Schlüssellänge") }
        self.privateKey = privateKey
    }

    /// A new key, clamped as WireGuard makes them.
    public static func generate() -> WireGuardKey {
        var bytes = [UInt8](Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        bytes[0] &= 248
        bytes[31] = (bytes[31] & 127) | 64
        return try! WireGuardKey(privateKey: Data(bytes))
    }

    public var privateBase64: String { privateKey.base64EncodedString() }

    public var publicBase64: String {
        let key = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        return key.publicKey.rawRepresentation.base64EncodedString()
    }

    public static func isValidPublic(_ s: String) -> Bool {
        s.count == 44 && Data(base64Encoded: s)?.count == 32
    }
}
