import Foundation
import HelperCore
import os

/// Slipstream's log (docs/logging.md): every line goes to the unified log, under the subsystem
/// `io.github.kyrios.slipstream` and its category, and to `~/Library/Logs/Slipstream/slipstream.log`
/// (5 × 5 MB), which the log window follows and Console.app lists under "Log Reports". Debug
/// lines reach the file only while "Debug aufzeichnen" is on. A line never carries a secret;
/// `LogRedaction` catches one that looks like it, so each line can go to the unified log as public.
enum Log {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Slipstream/slipstream.log")
    /// The file the log window follows: `url`, or in a Debug build `-logWindowFile <path>`, to
    /// look at the window beside a running Slipstream with sample lines (AGENTS.md).
    static var windowURL: URL {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "logWindowFile") { return URL(fileURLWithPath: path) }
        #endif
        return url
    }

    /// UserDefaults key of the log window's "Debug aufzeichnen"; off by default.
    static let debugKey = "logDebug"

    private static let queue = DispatchQueue(label: "io.github.kyrios.slipstream.log", qos: .utility)
    nonisolated(unsafe) private static let file = RotatingLog(url: url)
    private static let loggers: [LogCategory: Logger] = Dictionary(uniqueKeysWithValues: LogCategory.allCases.map {
        ($0, Logger(subsystem: SlipstreamIDs.logSubsystem, category: $0.rawValue))
    })
    private static let state = OSAllocatedUnfairLock(initialState: (muted: false, debug: UserDefaults.standard.bool(forKey: debugKey)))

    /// The Debug menu preview (-menuPreview) writes nothing, neither lines nor the window's
    /// choices: the log and the defaults are the running Slipstream's.
    static func mute() { state.withLock { $0.muted = true } }
    static var muted: Bool { state.withLock { $0.muted } }

    static var debugOn: Bool {
        get { state.withLock { $0.debug } }
        set {
            state.withLock { $0.debug = newValue }
            if !muted { UserDefaults.standard.set(newValue, forKey: debugKey) }
        }
    }

    static func debug(_ category: LogCategory, _ message: @autoclosure () -> String) {
        guard state.withLock({ $0.debug && !$0.muted }) else { return }
        write(.debug, category, message())
    }

    static func info(_ category: LogCategory, _ message: String) { write(.info, category, message) }
    static func notice(_ category: LogCategory, _ message: String) { write(.notice, category, message) }
    static func warning(_ category: LogCategory, _ message: String) { write(.warning, category, message) }
    static func error(_ category: LogCategory, _ message: String) { write(.error, category, message) }
    static func fault(_ category: LogCategory, _ message: String) { write(.fault, category, message) }

    static func write(_ record: LogRecord) { write(record.level, record.category, record.message) }

    static func write(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        let s = state.withLock { $0 }
        guard !s.muted, level > .debug || s.debug else { return }
        let entry = LogEntry(level: level, category: category, message: LogRedaction.clean(message))
        let logger = loggers[category]!
        switch level {
        case .debug: logger.debug("\(entry.message, privacy: .public)")
        case .info: logger.info("\(entry.message, privacy: .public)")
        case .notice: logger.notice("\(entry.message, privacy: .public)")
        case .warning: logger.warning("\(entry.message, privacy: .public)")
        case .error: logger.error("\(entry.message, privacy: .public)")
        case .fault: logger.fault("\(entry.message, privacy: .public)")
        }
        queue.async { file.write(entry) }
    }
}
