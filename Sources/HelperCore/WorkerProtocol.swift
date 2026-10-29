import Foundation

/// What the embedded worker (`slipstream`, Slipstream's core in core/) prints on its standard
/// output, one JSON object per line (docs/worker.md). Unknown events and fields are ignored, so a
/// newer worker does not break an older app.
public enum WorkerEvent: Equatable, Sendable {
    case connection(up: Bool, lastAnswerAt: Date?, refused: [Refusal])
    case job(WorkerJob)
    case idle
    /// A job's line; `level` a slog level word, from a worker that sends one (docs/logging.md).
    case log(leaseId: String?, line: String, level: String?)
    /// A job this worker ended; `leaseId` names the running job it ends.
    case result(leaseId: String?, title: String, verdict: String, check: String?)
    /// The pause the worker keeps; `mode` from encode-queue v0.2.18, nil before.
    case paused(until: Date?, mode: PauseMode?)
    case update(latest: String)
    case tools([Tool])
    /// One whisper model the queue wants this Mac to hold, at each change of its state (v0.2.7).
    case model(Model)
    /// This Mac's points and its place today, when either changes (v0.2.15).
    case points(Points)
    /// The CPU limit in effect, at the start, after each `limits` line and when a running job's
    /// tool is held to it or freed (v0.2.17).
    case limits(Limits)

    /// The worker's word on the CPU limit (encode-queue v0.2.17): the threads a new tool starts
    /// with, of the Mac's cores, and how many running jobs' tools are held to it now, having
    /// started with more (a lowered limit reaches them as a duty cycle of SIGSTOP and SIGCONT).
    public struct Limits: Codable, Equatable, Sendable {
        public var threads: Int
        public var cores: Int
        public var throttled: Int
        /// Which jobs run on the efficiency cores: off, all, archive (Efficiency).
        public var efficiency: String?

        public init(threads: Int, cores: Int, throttled: Int = 0, efficiency: String? = nil) {
            (self.threads, self.cores, self.throttled, self.efficiency) = (threads, cores, throttled, efficiency)
        }
    }

    /// What the queue says this Mac's accepted jobs earned by its points table (encode-queue
    /// v0.2.15, "Punkte-Tabelle v1": one point is a minute of the Mac Studio's work), and its
    /// place today among every paired worker. The queue computes them; the app only shows them.
    public struct Points: Codable, Equatable, Sendable {
        public var table: String?
        public var today: Double
        public var week: Double?
        public var total: Double?
        public var rank: Int
        public var of: Int

        public init(today: Double, rank: Int, of: Int, week: Double? = nil, total: Double? = nil, table: String? = nil) {
            self.today = today
            self.rank = rank
            self.of = of
            self.week = week
            self.total = total
            self.table = table
        }

        /// The menu's line: "1.240 Punkte heute · Platz 1 von 3", whole points, German grouping.
        public var line: String {
            let n = max(0, Int(today.rounded()))
            var digits = String(n)
            var groups: [String] = []
            while digits.count > 3 {
                groups.insert(String(digits.suffix(3)), at: 0)
                digits.removeLast(3)
            }
            groups.insert(digits, at: 0)
            return "\(groups.joined(separator: ".")) \(n == 1 ? "Punkt" : "Punkte") heute · Platz \(rank) von \(of)"
        }
    }

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
            return .log(leaseId: object["lease_id"] as? String, line: object["line"] as? String ?? "", level: object["level"] as? String)
        case "result":
            return .result(leaseId: object["lease_id"] as? String, title: object["title"] as? String ?? "",
                           verdict: object["verdict"] as? String ?? "", check: object["check"] as? String)
        case "paused":
            return .paused(until: date("until"), mode: (object["mode"] as? String).flatMap(PauseMode.init(rawValue:)))
        case "update":
            guard let latest = object["latest"] as? String else { return nil }
            return .update(latest: latest)
        case "tools":
            return .tools(decode([Tool].self, "tools") ?? [])
        case "model":
            guard let d = try? JSONSerialization.data(withJSONObject: object),
                  let model = try? JSONCoding.decoder.decode(Model.self, from: d) else { return nil }
            return .model(model)
        case "points":
            guard let d = try? JSONSerialization.data(withJSONObject: object),
                  let points = try? JSONCoding.decoder.decode(Points.self, from: d), points.rank > 0, points.of > 0 else { return nil }
            return .points(points)
        case "limits":
            guard let d = try? JSONSerialization.data(withJSONObject: object),
                  let limits = try? JSONCoding.decoder.decode(Limits.self, from: d), limits.threads > 0, limits.cores > 0 else { return nil }
            return .limits(limits)
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
    /// `normal` or `high`: the slot it runs in (encode-queue v0.2.14).
    public var slot: String?
    public var phase: String?
    public var fraction: Double?
    public var fps: Double?
    public var speed: Double?
    public var etaS: Int?
}

extension WorkerJob {
    /// The menu's line for this job (Thorsten, 2026-10-28: "Use Sub-menues for details"): what it
    /// does, its title and its share, "Wandelt um: one_144_Hey_Siri · 12 %".
    public var menuTitle: String {
        let doing: String
        switch phase {
        case "downloading": doing = "Lädt"
        case "checking": doing = "Prüft"
        case "uploading": doing = "Sendet"
        case "paused": doing = "Angehalten"
        default: doing = kind == "whisper" ? "Hört zu" : "Wandelt um"
        }
        let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? leaseId ?? "Auftrag"
        return "\(doing): \(name)" + menuShare
    }

    /// The end of `menuTitle`, " · 12 %", which the menu keeps when it cuts a long title.
    public var menuShare: String { " · \(Int((fraction ?? 0) * 100)) %" }

    /// Its submenu: the file, the rung, fps, speed, time left and the slot.
    public var menuDetails: [String] {
        var out: [String] = []
        if let title, !title.isEmpty { out.append("Datei: \(title)") }
        if kind == "whisper" {
            out.append("Untertitel (Whisper)")
        } else if let rung {
            out.append("Stufe: \(rung)p")
        }
        if let fps { out.append("FPS: " + Self.de(fps, digits: fps < 10 ? 1 : 0)) }
        if let speed { out.append("Tempo: " + Self.de(speed, digits: 1) + "× Echtzeit") }
        if let etaS {
            let rounded = etaS > 90 ? (etaS + 30) / 60 * 60 : etaS
            out.append("Noch: " + Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))
        }
        if let slot { out.append(slot == "high" ? "Platz: Sofort und Stufe 1" : "Platz: Normal") }
        return out
    }

    static func de(_ v: Double, digits: Int) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "de_DE")))
    }
}

/// Which flags the embedded worker takes, from its `-h` usage, so the app passes a newer flag
/// only to a worker that knows it (an unknown flag stops a Go worker at start).
public enum WorkerFlags {
    /// The usage `executable -h` prints, nil when it does not start. It blocks the calling thread
    /// until the worker exits and never runs the run loop: `Process.waitUntilExit` does, and in
    /// 1.3.6 SwiftUI built the menu inside that wait, whose CPU picker read the `static let`
    /// still being initialised, and libdispatch ended the app at every launch (docs/traps.md,
    /// "A static that runs the run loop").
    public static func usage(of executable: URL) -> String? {
        let p = Process()
        p.executableURL = executable
        p.arguments = ["-h"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        return String(decoding: data, as: UTF8.self)
    }

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

/// How the menu's pause treats a running job (encode-queue v0.2.18): `now` stops its tool at once,
/// and the job goes on where it stood when the pause ends (an archive or stage 2 job; a Sofort or
/// stage 1 job goes back to the queue after a minute, for another Mac); `afterJob` lets it finish.
/// Either way the Mac takes no new job until the pause ends. A worker before v0.2.18 takes no mode
/// and pauses as `now`.
public enum PauseMode: String, Codable, Equatable, Sendable {
    case now
    case afterJob = "after_job"

    /// The menu's first line while paused: "Pausiert bis 20:00", or "Pause nach diesem Auftrag,
    /// bis 20:00" while a job still runs to its end.
    public static func stateLine(until: String, mode: PauseMode, jobsRunning: Bool) -> String {
        mode == .afterJob && jobsRunning ? "Pause nach diesem Auftrag, bis \(until)" : "Pausiert bis \(until)"
    }
}

/// What the app writes to the worker's standard input, one JSON object per line, after the
/// first line, which is the private key.
public enum WorkerCommand: Equatable, Sendable {
    case pause(until: Date, mode: PauseMode)
    case resume
    /// `jobs`: the normal slots, which take every job; `highSlots`: the high-priority slots on top,
    /// which take only Sofort and Stufe 1 (encode-queue v0.2.14; an older worker ignores them).
    /// `efficiency`: which jobs run on the efficiency cores only (encode-queue v0.2.18; an older
    /// worker ignores it).
    case limits(threads: Int, gpu: Bool, jobs: Int, highSlots: Int, efficiency: Efficiency)
    /// Give every lease back (reason `quit`) and exit.
    case quit

    public var line: String {
        let object: [String: Any]
        switch self {
        case .pause(let until, let mode):
            object = ["cmd": "pause", "until": ISO8601DateFormatter().string(from: until), "mode": mode.rawValue]
        case .resume:
            object = ["cmd": "resume"]
        case .limits(let threads, let gpu, let jobs, let highSlots, let efficiency):
            object = ["cmd": "limits", "threads": threads, "gpu": gpu, "jobs": jobs, "high_slots": highSlots,
                      "efficiency": efficiency.rawValue]
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
