import Foundation

/// A line to log: the app writes it to the unified log and the file (docs/logging.md).
public struct LogRecord: Equatable, Sendable {
    public var level: LogLevel
    public var category: LogCategory
    public var message: String

    public init(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        (self.level, self.category, self.message) = (level, category, message)
    }
}

/// The log lines for the worker's events: each change of state once, not each event (a running
/// job sends one a second). The tunnel up and down, a job's start, phases, every 10 % and its
/// end with its time, a pause, the CPU limit in effect, the models, a newer app; every event
/// itself at debug level. Main thread only, like the model that feeds it.
public struct WorkerEventLog {
    private struct Job {
        var started: Date
        var title: String
        var phase: String?
        var tenth: Int
    }

    private var up: Bool?
    private var refused: [WorkerEvent.Refusal] = []
    private var jobs: [String: Job] = [:]
    private var paused: (until: Date?, mode: PauseMode?)?
    private var limits: WorkerEvent.Limits?
    private var models: [String: String] = [:]
    private var update: String?
    private var tools: [WorkerEvent.Tool] = []

    public init() {}

    /// A new worker: what the old one said is gone.
    public mutating func reset() {
        self = WorkerEventLog()
    }

    public mutating func lines(for event: WorkerEvent, at now: Date = Date()) -> [LogRecord] {
        switch event {
        case .connection(let up, _, let refused):
            var out: [LogRecord] = []
            if up != self.up {
                out.append(LogRecord(up ? .notice : .warning, .tunnel, up ? "tunnel up: the queue answers" : "tunnel down: no answer from the queue"))
                self.up = up
            }
            if refused != self.refused {
                for r in refused where !self.refused.contains(r) {
                    out.append(LogRecord(.warning, .tunnel, "the queue refuses \(r.kind) jobs: \(r.reason)"))
                }
                self.refused = refused
            }
            return out
        case .job(let j):
            return job(j, at: now)
        case .idle:
            // A job that ended beside another without a result of its own (RunningJobs).
            let out = jobs.sorted { $0.value.started < $1.value.started }.map { lease, job in
                LogRecord(.info, .encode, "\(job.title) (\(lease)): ended without a result after \(Self.duration(now.timeIntervalSince(job.started)))")
            }
            jobs = [:]
            return out
        case .log(let lease, let line, let level):
            let (l, text) = WorkerLogLine.job(lease: lease, line: line, level: level)
            return [LogRecord(l, .worker, text)]
        case .result(let lease, let title, let verdict, let check):
            let job = lease.flatMap { jobs.removeValue(forKey: $0) }
            let took = job.map { " after \(Self.duration(now.timeIntervalSince($0.started)))" } ?? ""
            let name = title.isEmpty ? (job?.title ?? lease ?? "job") : title
            let id = lease.map { " (\($0))" } ?? ""
            let why = check.flatMap { $0.isEmpty ? nil : $0 }
            switch verdict {
            case "accepted":
                return [LogRecord(.notice, .encode, "\(name)\(id): accepted\(took)")]
            case "rejected":
                return [LogRecord(.error, .encode, "\(name)\(id): rejected\(took)\(why.map { ": \($0)" } ?? "")")]
            case "given_back" where why == "preempted":
                return [LogRecord(.notice, .encode, "\(name)\(id): preempted, given back to the queue\(took)")]
            case "given_back":
                return [LogRecord(.notice, .encode, "\(name)\(id): given back to the queue\(took)\(why.map { ": \($0)" } ?? "")")]
            default:
                return [LogRecord(.notice, .encode, "\(name)\(id): \(verdict)\(took)\(why.map { ": \($0)" } ?? "")")]
            }
        case .paused(let until, let mode):
            guard paused == nil || paused!.until != until || paused!.mode != mode else { return [] }
            paused = (until, mode)
            let text = until.map { "the worker holds a pause until \(Self.clock($0))\(mode.map { ", \($0.rawValue)" } ?? "")" }
                ?? "the worker holds no pause"
            return [LogRecord(.notice, .pause, text)]
        case .update(let latest):
            guard latest != update else { return [] }
            update = latest
            return [LogRecord(.notice, .update, "the queue wants a newer Slipstream: \(latest)")]
        case .tools(let tools):
            guard tools != self.tools else { return [] }
            self.tools = tools
            return [LogRecord(.info, .worker, "tools: " + tools.map { "\($0.name) \($0.version)" }.joined(separator: ", "))]
        case .model(let m):
            guard models[m.sha256] != m.state else { return [] }
            models[m.sha256] = m.state
            let level: LogLevel = m.state == "failed" ? .error : m.state == "unavailable" ? .warning : .info
            return [LogRecord(level, .worker, "whisper model \(m.name): \(m.state)\(m.reason.map { ": \($0)" } ?? "")")]
        case .points(let p):
            return [LogRecord(.debug, .worker, "points: \(p.line)")]
        case .limits(let l):
            guard l != limits else { return [] }
            limits = l
            var text = "CPU limit in effect: \(l.threads) of \(l.cores) cores"
            if l.throttled > 0 { text += ", \(l.throttled) running job\(l.throttled == 1 ? "" : "s") held to it" }
            if let e = l.efficiency, e != "off" { text += ", efficiency cores: \(e)" }
            return [LogRecord(.notice, .cores, text)]
        }
    }

    private mutating func job(_ j: WorkerJob, at now: Date) -> [LogRecord] {
        let lease = j.leaseId ?? ""
        let title = j.title.flatMap { $0.isEmpty ? nil : $0 } ?? (lease.isEmpty ? "job" : lease)
        let tenth = min(10, Int(((j.fraction ?? 0) * 10).rounded(.down)))
        var out: [LogRecord] = []
        guard var job = jobs[lease] else {
            var what = [j.kind, j.rung.map { "\($0)p" }].compactMap { $0 }.joined(separator: " ")
            if let slot = j.slot { what += (what.isEmpty ? "" : ", ") + "\(slot) slot" }
            out.append(LogRecord(.notice, .encode, "\(title) (\(lease)): started\(what.isEmpty ? "" : ", \(what)")\(j.phase.map { ", \($0)" } ?? "")"))
            jobs[lease] = Job(started: now, title: title, phase: j.phase, tenth: tenth)
            return out
        }
        if j.phase != job.phase, let phase = j.phase {
            out.append(LogRecord(.info, .encode, "\(title) (\(lease)): \(phase) after \(Self.duration(now.timeIntervalSince(job.started)))"))
            job.phase = phase
        }
        if tenth > job.tenth {
            var text = "\(title) (\(lease)): \(tenth * 10) %"
            var details: [String] = []
            if let fps = j.fps { details.append(String(format: "%.1f fps", fps)) }
            if let speed = j.speed { details.append(String(format: "%.2f× real time", speed)) }
            if let eta = j.etaS { details.append("\(Self.duration(TimeInterval(eta))) left") }
            if !details.isEmpty { text += " (" + details.joined(separator: ", ") + ")" }
            out.append(LogRecord(.info, .encode, text))
        }
        // A phase can start again at 0 (download, then encode): the steps follow the phase.
        job.tenth = tenth
        jobs[lease] = job
        return out
    }

    /// `42 s`, `12 min 5 s`, `1 h 12 min`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
