import Foundation

/// What the embedded worker (`encode-worker` from kyrios/encode-queue) prints on its standard
/// output, one JSON object per line (docs/worker.md). Unknown events and fields are ignored, so a
/// newer worker does not break an older app.
public enum WorkerEvent: Equatable, Sendable {
    case connection(up: Bool, lastAnswerAt: Date?, refused: [Refusal])
    case job(WorkerJob)
    case idle
    case log(leaseId: String?, line: String)
    case result(title: String, verdict: String, check: String?)
    case paused(until: Date?)
    case update(latest: String)
    case tools([Tool])
    /// One whisper model the queue wants this Mac to hold, at each change of its state (v0.2.7).
    case model(Model)

    public struct Refusal: Codable, Equatable, Sendable {
        public var kind: String
        public var reason: String
    }

    public struct Tool: Codable, Equatable, Sendable {
        public var name: String
        public var version: String
    }

    /// `state`: wanted, downloading, checking, calibrating, ready, failed, unavailable. `bytes`
    /// and `bytesDone` while it downloads, `speed` (times real time) once timed, `reason` when
    /// it failed or is unavailable.
    public struct Model: Codable, Equatable, Sendable {
        public var name: String
        public var sha256: String
        public var state: String
        public var bytes: Int64?
        public var bytesDone: Int64?
        public var speed: Double?
        public var reason: String?

        public init(name: String, sha256: String, state: String, bytes: Int64? = nil, bytesDone: Int64? = nil,
                    speed: Double? = nil, reason: String? = nil) {
            (self.name, self.sha256, self.state) = (name, sha256, state)
            (self.bytes, self.bytesDone, self.speed, self.reason) = (bytes, bytesDone, speed, reason)
        }

        /// Downloaded share, 0…1, while it downloads.
        public var fraction: Double? {
            guard let bytes, let bytesDone, bytes > 0 else { return nil }
            return min(1, Double(bytesDone) / Double(bytes))
        }
    }

    public static func parse(_ line: String) -> WorkerEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String else { return nil }
        func date(_ key: String) -> Date? {
            (object[key] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        }
        func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            guard let v = object[key], let d = try? JSONSerialization.data(withJSONObject: v) else { return nil }
            return try? JSONCoding.decoder.decode(T.self, from: d)
        }
        switch event {
        case "connection":
            return .connection(up: object["up"] as? Bool ?? false, lastAnswerAt: date("last_answer_at"),
                               refused: decode([Refusal].self, "refused") ?? [])
        case "job":
            guard let d = try? JSONSerialization.data(withJSONObject: object),
                  let job = try? JSONCoding.decoder.decode(WorkerJob.self, from: d) else { return nil }
            return .job(job)
        case "idle":
            return .idle
        case "log":
            return .log(leaseId: object["lease_id"] as? String, line: object["line"] as? String ?? "")
        case "result":
            return .result(title: object["title"] as? String ?? "", verdict: object["verdict"] as? String ?? "",
                           check: object["check"] as? String)
        case "paused":
            return .paused(until: date("until"))
        case "update":
            guard let latest = object["latest"] as? String else { return nil }
            return .update(latest: latest)
        case "tools":
            return .tools(decode([Tool].self, "tools") ?? [])
        case "model":
            guard let d = try? JSONSerialization.data(withJSONObject: object),
                  let model = try? JSONCoding.decoder.decode(Model.self, from: d) else { return nil }
            return .model(model)
        default:
            return nil
        }
    }
}

/// The job the worker holds right now.
public struct WorkerJob: Codable, Equatable, Sendable {
    public var leaseId: String?
    public var title: String?
    public var kind: String?
    public var rung: String?
    public var phase: String?
    public var fraction: Double?
    public var fps: Double?
    public var speed: Double?
    public var etaS: Int?
}

/// Which flags the embedded worker takes, from its `-h` usage, so the app passes a newer flag
/// only to a worker that knows it (an unknown flag stops a Go worker at start).
public enum WorkerFlags {
    public static func supports(_ flag: String, usage: String) -> Bool {
        usage.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-\(flag) ") || $0.trimmingCharacters(in: .whitespaces) == "-\(flag)" }
    }
}

/// The worker's environment: the app's, with the toolchain's fonts for libass (`FONTCONFIG_FILE`,
/// unless already set, as the worker itself would), fontconfig's cache under `cache`, and the
/// app's helpers first on `PATH`, so the worker finds the toolchain's `fc-list` before any other.
public enum WorkerEnvironment {
    public static func make(base: [String: String], helpers: String, fontsConf: String?, cache: String) -> [String: String] {
        var env = base
        if let fontsConf, (env["FONTCONFIG_FILE"] ?? "").isEmpty {
            env["FONTCONFIG_FILE"] = fontsConf
        }
        env["XDG_CACHE_HOME"] = cache
        let path = env["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = ([helpers] + path.split(separator: ":").map(String.init).filter { $0 != helpers }).joined(separator: ":")
        return env
    }
}

/// What the app writes to the worker's standard input, one JSON object per line, after the
/// first line, which is the private key.
public enum WorkerCommand: Equatable, Sendable {
    case pause(until: Date)
    case resume
    case limits(threads: Int, gpu: Bool, jobs: Int)
    /// Give every lease back (reason `quit`) and exit.
    case quit

    public var line: String {
        let object: [String: Any]
        switch self {
        case .pause(let until):
            object = ["cmd": "pause", "until": ISO8601DateFormatter().string(from: until)]
        case .resume:
            object = ["cmd": "resume"]
        case .limits(let threads, let gpu, let jobs):
            object = ["cmd": "limits", "threads": threads, "gpu": gpu, "jobs": jobs]
        case .quit:
            object = ["cmd": "quit"]
        }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)! + "\n"
    }
}

/// Splits a byte stream into lines.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0a) {
            let line = pending[pending.startIndex..<nl]
            lines.append(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }
}
