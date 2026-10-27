import Foundation
import HelperCore
import Security

/// Where Slipstream keeps its files: `~/Library/Application Support/Slipstream`.
enum Paths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Slipstream", isDirectory: true)
    }

    static var jobs: URL { support.appendingPathComponent("jobs", isDirectory: true) }
    static var tunnel: URL { support.appendingPathComponent("tunnel.conf") }
    static var workerState: URL { support.appendingPathComponent("worker", isDirectory: true) }
    static var models: URL { support.appendingPathComponent("models", isDirectory: true) }

    /// The app group container the extension reads; created by hand when the system gives none
    /// (an ad hoc build without the entitlement).
    static var appGroup: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SlipstreamIDs.appGroup) {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(SlipstreamIDs.appGroup)", isDirectory: true)
    }

    /// The toolchain's `versions.txt`, in `Contents/Resources`: codesign takes no data in
    /// `Contents/Helpers`.
    static var toolVersions: String? {
        Bundle.main.url(forResource: "versions", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// whisper.cpp's release from it (`whisper.cpp v1.9.5`), for the worker, which looks for the
    /// file beside `whisper-cli` otherwise.
    static var whisperVersion: String? {
        toolVersions?.split(separator: "\n").first { $0.hasPrefix("whisper.cpp ") }
            .map { String($0.dropFirst("whisper.cpp ".count)) }
    }

    /// The tools inside the app: `Contents/Helpers`. In a debug build `SLIPSTREAM_WORKER`
    /// points at a stand-in worker; never in a release, where it would hand the private key to
    /// whatever binary the environment names.
    static func helper(_ name: String) -> URL {
        #if DEBUG
        if name == "encode-worker", let path = ProcessInfo.processInfo.environment["SLIPSTREAM_WORKER"] {
            return URL(fileURLWithPath: path)
        }
        #endif
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
    }
}

/// The WireGuard key in the login keychain. Its private half never leaves this Mac: the worker
/// gets it on its standard input.
enum KeyStore {
    private static let service = SlipstreamIDs.bundle + ".wireguard"
    private static let account = "worker"

    static func loadOrCreate() throws -> WireGuardKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let key = try? WireGuardKey(privateKey: data) {
            return key
        }
        guard status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        let key = WireGuardKey.generate()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: key.privateKey,
                                  kSecAttrLabel as String: "Slipstream WireGuard",
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        return key
    }
}

/// The app's side of pairing for the loopback endpoint.
struct AppPairing: Pairing {
    let onTunnel: @Sendable (TunnelConfig) async -> Void

    static var macName: String { Host.current().localizedName ?? "Mac" }

    static func storedTunnel() -> TunnelConfig? {
        guard let line = try? String(contentsOf: Paths.tunnel, encoding: .utf8) else { return nil }
        return try? TunnelConfig(configLine: line)
    }

    func identity() async throws -> PairingIdentity {
        let key = try KeyStore.loadOrCreate()
        let tunnel = Self.storedTunnel()
        return PairingIdentity(name: Self.macName, publicKey: key.publicBase64, paired: tunnel != nil,
                               tunnelAddress: tunnel?.address)
    }

    func setTunnel(_ config: TunnelConfig) async throws {
        do { _ = try KeyStore.loadOrCreate() } catch {
            throw JobError("not-paired", "Slipstream findet seinen Schlüssel nicht im Schlüsselbund.")
        }
        try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try (config.configLine + "\n").write(to: Paths.tunnel, atomically: true, encoding: .utf8)
        await onTunnel(config)
    }
}
