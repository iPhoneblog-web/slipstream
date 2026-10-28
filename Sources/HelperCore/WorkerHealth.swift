import Foundation

/// When the app starts the worker again after it stopped (docs/worker.md, "When the worker
/// stops"). Up to 1.3.1 it tried every 10 s for ever and showed only "Keine Verbindung"; a
/// worker that died at every start looked like a slow tunnel, and a start that threw was never
/// tried again.
public enum WorkerRestart {
    /// A worker that ran this long counts as healthy: the next stop starts the count anew.
    public static let healthyAfter: TimeInterval = 300

    /// The wait before the next start after `stops` stops in a row (1, 2, …): 10 s, doubling,
    /// at most 10 min.
    public static func delay(afterStops stops: Int) -> TimeInterval {
        let n = max(1, stops)
        return min(600, 10 * pow(2, Double(min(n - 1, 10))))
    }

    /// The count after a stop: one more, or 1 when the worker had run long enough.
    public static func stops(previous: Int, ranFor seconds: TimeInterval) -> Int {
        seconds >= healthyAfter ? 1 : previous + 1
    }
}

/// Why the worker stopped, in one line for the menu ("Encoder gestoppt: …"): the worker's own
/// last word on standard error when it said one, else how it ended.
public enum WorkerExit {
    /// `lastLines`: its last lines on standard error, oldest first. `signal`: the signal that
    /// ended it, if any; otherwise `status` is its exit status.
    public static func reason(status: Int32, signal: Int32?, lastLines: [String]) -> String {
        let how: String
        if let signal {
            how = "Signal \(signal)\(signalName(signal).map { " (\($0))" } ?? "")"
        } else {
            how = "Status \(status)"
        }
        let lines = lastLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // A Go panic prints "panic: …" and then the goroutines; the panic line is the reason.
        // encode-worker prints its fatal error as "encode-worker: …" just before it exits.
        let said = lines.last(where: { $0.hasPrefix("panic:") || $0.hasPrefix("fatal error:") })
            ?? lines.last(where: { $0.hasPrefix("encode-worker:") })
            ?? lines.last
        guard let said else { return how }
        let text = said.count > 160 ? String(said.prefix(159)) + "…" : said
        return "\(text) (\(how))"
    }

    static func signalName(_ s: Int32) -> String? {
        switch s {
        case SIGKILL: return "SIGKILL"
        case SIGTERM: return "SIGTERM"
        case SIGSEGV: return "SIGSEGV"
        case SIGABRT: return "SIGABRT"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        default: return nil
        }
    }
}
