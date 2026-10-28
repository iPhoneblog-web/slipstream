import Foundation

/// How much a log line matters (docs/logging.md). The unified log knows debug, info, notice
/// (default), error and fault; a warning goes to it as an error, as `Logger.warning` does, and the
/// file and the log window keep it apart.
public enum LogLevel: Int, Comparable, CaseIterable, Sendable {
    case debug, info, notice, warning, error, fault

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    /// The word in the file: `DEBUG`, `INFO`, `NOTICE`, `WARN`, `ERROR`, `FAULT`.
    public var word: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        }
    }

    public init?(word: String) {
        guard let level = LogLevel.allCases.first(where: { $0.word == word }) else { return nil }
        self = level
    }

    /// A level of Go's log/slog, as the worker writes it: `DEBUG`, `INFO`, `WARN`, `ERROR`, each
    /// perhaps with an offset (`INFO+2`, `DEBUG-4`), which slog prints for levels between them.
    public init(slog: String) {
        let word = slog.uppercased()
        let base = word.prefix { $0.isLetter }
        let offset = Int(word.dropFirst(base.count)) ?? 0
        let value: Int
        switch base {
        case "DEBUG": value = -4
        case "INFO": value = 0
        case "WARN", "WARNING": value = 4
        case "ERROR": value = 8
        default: value = 0
        }
        switch value + offset {
        case ..<0: self = .debug
        case 0..<4: self = .info
        case 4..<8: self = .warning
        case 8..<12: self = .error
        default: self = .fault
        }
    }
}

/// The part of Slipstream a line is about: the unified log's category and a column in the file.
public enum LogCategory: String, CaseIterable, Sendable {
    case app, tunnel, worker, encode, update, `extension`, pause, cores
}

/// One line of the log, as the file holds it:
/// `2026-10-28T19:08:35.204Z NOTICE worker    worker started, pid 2188`.
public struct LogEntry: Equatable, Sendable {
    public var date: Date
    public var level: LogLevel
    public var category: LogCategory
    public var message: String

    public init(date: Date = Date(), level: LogLevel, category: LogCategory, message: String) {
        (self.date, self.level, self.category, self.message) = (date, level, category, message)
    }

    /// The line without its time, which `RotatingLog` writes in front. Level and category are
    /// padded, so the messages start in one column; a newline in the message becomes a space.
    public var body: String {
        let level = level.word.padding(toLength: 6, withPad: " ", startingAt: 0)
        let category = category.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
        let text = message.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        return "\(level) \(category) \(text)"
    }

    /// A line of the file back, for the log window; nil for a line in another form.
    public static func parse(_ line: String) -> LogEntry? {
        let words = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard words.count >= 2, let date = RotatingLog.stampParser.date(from: String(words[0])) else { return nil }
        let rest = line.dropFirst(words[0].count).drop { $0 == " " }
        let levelWord = rest.prefix { $0 != " " }
        guard let level = LogLevel(word: String(levelWord)) else { return nil }
        let afterLevel = rest.dropFirst(levelWord.count).drop { $0 == " " }
        let categoryWord = afterLevel.prefix { $0 != " " }
        guard let category = LogCategory(rawValue: String(categoryWord)) else { return nil }
        let message = afterLevel.dropFirst(categoryWord.count).drop { $0 == " " }
        return LogEntry(date: date, level: level, category: category, message: String(message))
    }
}

/// The worker's lines and their levels (docs/logging.md, "The worker's lines").
public enum WorkerLogLine {
    /// A line on the worker's standard error. Its own lines are log/slog's text form,
    /// `time=… level=INFO msg="job ended" lease=…`: the level is slog's, and the line keeps the
    /// message and its attributes without the time (the file has its own) and the level. A line
    /// in another form is Go's runtime or a tool: a panic is a fault, the worker's last word
    /// (`encode-worker: …`) an error, anything else a warning.
    public static func stderr(_ line: String) -> (LogLevel, String) {
        if line.hasPrefix("time="), let parsed = slog(line) { return parsed }
        if line.hasPrefix("panic:") || line.hasPrefix("fatal error:") { return (.fault, line) }
        if line.hasPrefix("encode-worker:") { return (.error, line) }
        return (.warning, line)
    }

    /// A job's line from a `log` event: its `level` field when the worker sends one (a slog
    /// level word), else info. Up to encode-queue v0.2.18 these lines carry no level.
    public static func job(lease: String?, line: String, level: String?) -> (LogLevel, String) {
        (level.map(LogLevel.init(slog:)) ?? .info, lease.map { "\($0): \(line)" } ?? line)
    }

    /// `time=… level=WARN msg="a b" k=v` → (.warning, `a b k=v`).
    static func slog(_ line: String) -> (LogLevel, String)? {
        var level: LogLevel?
        var rest = Substring(line)
        // time= and level= come first, in that order, unquoted.
        for _ in 0..<2 {
            rest = rest.drop { $0 == " " }
            if rest.hasPrefix("time=") {
                rest = rest.drop { $0 != " " }
            } else if rest.hasPrefix("level=") {
                let word = rest.dropFirst("level=".count).prefix { $0 != " " }
                level = LogLevel(slog: String(word))
                rest = rest.dropFirst("level=".count + word.count)
            }
        }
        guard let level else { return nil }
        rest = rest.drop { $0 == " " }
        guard rest.hasPrefix("msg=") else { return (level, String(rest)) }
        rest = rest.dropFirst("msg=".count)
        let message: String
        if rest.first == "\"" {
            // A quoted message: up to the closing quote, \" and \\ unescaped.
            var out = ""
            var i = rest.index(after: rest.startIndex)
            var closed = false
            while i < rest.endIndex {
                let c = rest[i]
                if c == "\\", rest.index(after: i) < rest.endIndex {
                    i = rest.index(after: i)
                    out.append(rest[i])
                } else if c == "\"" {
                    closed = true
                    i = rest.index(after: i)
                    break
                } else {
                    out.append(c)
                }
                i = rest.index(after: i)
            }
            guard closed else { return (level, String(rest)) }
            message = out
            rest = rest[i...]
        } else {
            let word = rest.prefix { $0 != " " }
            message = String(word)
            rest = rest.dropFirst(word.count)
        }
        let attributes = rest.trimmingCharacters(in: .whitespaces)
        return (level, attributes.isEmpty ? message : "\(message) \(attributes)")
    }
}

/// The safety net under every line: Slipstream logs no secret, and a value that looks like one
/// is replaced by `<privat>` before it reaches the unified log or the file. Tokens, passwords,
/// private keys and the user part of a URL (`https://user:pass@host`).
public enum LogRedaction {
    private static let patterns: [NSRegularExpression] = [
        // key=value and key: value, the name anywhere in a word (X-Slipstream-Token, private_key).
        try! NSRegularExpression(pattern: #"(?i)\b([\w-]*(?:token|secret|password|passwd|private[_-]?key|authorization|cookie)[\w-]*)(\s*[=:]\s*)((?:Bearer\s+|Basic\s+)?(?:"[^"]*"|\S+))"#),
        try! NSRegularExpression(pattern: #"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#),
    ]

    public static func clean(_ text: String) -> String {
        var out = text
        let first = patterns[0]
        out = first.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1$2<privat>")
        let second = patterns[1]
        out = second.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1<privat>@")
        return out
    }
}

/// The log window's level choice: each shows its level and every level above.
public enum LogFilter: String, CaseIterable, Sendable {
    case errors, warnings, info, debug

    public var label: String {
        switch self {
        case .errors: return "Fehler"
        case .warnings: return "Warnungen"
        case .info: return "Info"
        case .debug: return "Debug"
        }
    }

    public var minimum: LogLevel {
        switch self {
        case .errors: return .error
        case .warnings: return .warning
        case .info: return .info
        case .debug: return .debug
        }
    }

    /// Whether the window shows `entry` with this level and `search` (case and diacritics
    /// ignored, in the message and the category).
    public func shows(_ entry: LogEntry, search: String) -> Bool {
        guard entry.level >= minimum else { return false }
        let s = search.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return true }
        return entry.message.range(of: s, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || entry.category.rawValue.range(of: s, options: .caseInsensitive) != nil
    }
}

/// The log window's "Folgen": on, it keeps the newest line in view. Scrolling up turns it off;
/// scrolling back to the end turns it on again, as Console.app does. Only the user's scrolling
/// counts, not the window's own scroll to a new line.
public struct LogFollow: Equatable, Sendable {
    /// Points from the end that still count as the end: a line and a bit.
    public static let slack: Double = 24

    public var on: Bool

    public init(on: Bool = true) { self.on = on }

    /// The user scrolled; `distanceFromEnd` is how far the visible part ends above the last line.
    public mutating func userScrolled(distanceFromEnd: Double) {
        on = distanceFromEnd <= Self.slack
    }
}

/// `tail -f` for the log file: the lines added since the last read, across a rotation (the file
/// moved to `.1` and a new one begun). Not thread-safe.
public final class LogTail {
    public let url: URL
    private var handle: FileHandle?
    private var inode: UInt64?
    private var pending = LineBuffer()

    public init(url: URL) {
        self.url = url
    }

    deinit { try? handle?.close() }

    /// The file's last `bytes` bytes as whole lines (a cut first line dropped), and from then on
    /// `read()` returns what follows.
    public func start(lastBytes bytes: Int) -> [String] {
        try? handle?.close()
        handle = nil
        pending = LineBuffer()
        guard open() else { return [] }
        let size = (try? handle?.seekToEnd()) ?? 0
        let from = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle?.seek(toOffset: from)
        var lines = readAvailable()
        if from > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// The whole lines written since the last call. After a rotation, the old file's rest first,
    /// then the new file from its start.
    public func read() -> [String] {
        if handle == nil { return open() ? readAvailable() : [] }
        var lines = readAvailable()
        if currentInode() != inode {
            try? handle?.close()
            handle = nil
            pending = LineBuffer()
            if open() { lines += readAvailable() }
        }
        return lines
    }

    private func open() -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        handle = h
        inode = currentInode()
        return true
    }

    private func readAvailable() -> [String] {
        guard let handle, let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        return pending.append(data)
    }

    private func currentInode() -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64
    }
}

/// The log as a file the user can send, `~/Library/Logs/Slipstream/slipstream.log`: one line
/// each, the time in front. At `limit` bytes the file moves to `.1`, `.1` to `.2` and so on;
/// `keep` older files stay (5 × 5 MB with the defaults). Console.app lists the folder under
/// "Log Reports". A line that cannot be written (a full disk) is dropped and the file closed;
/// the next line opens it again. A log line never ends the app. Not thread-safe: the app writes
/// from one serial queue.
public final class RotatingLog {
    public let url: URL
    let limit: Int
    let keep: Int
    private var handle: FileHandle?
    private var size = 0
    private let stamp: ISO8601DateFormatter = RotatingLog.makeStamp()

    static func makeStamp() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    /// For `LogEntry.parse`; ISO8601DateFormatter is thread-safe.
    nonisolated(unsafe) static let stampParser = makeStamp()

    public init(url: URL, limit: Int = 5 << 20, keep: Int = 4) {
        self.url = url
        self.limit = limit
        self.keep = max(0, keep)
    }

    /// The older files, newest first: `slipstream.log.1` …
    public var older: [URL] { (0..<keep).map { url.appendingPathExtension(String($0 + 1)) } }

    public func write(_ entry: LogEntry) {
        write(entry.body, at: entry.date)
    }

    public func write(_ line: String, at date: Date = Date()) {
        if handle == nil { open() }
        guard let handle else { return }
        let data = Data("\(stamp.string(from: date)) \(line)\n".utf8)
        if size + data.count > limit, size > 0 {
            rotate()
            return write(line, at: date)
        }
        // The throwing write: FileHandle.write(_:) raises an Objective-C exception on a full
        // disk, which would end the app over a log line.
        do {
            try handle.write(contentsOf: data)
            size += data.count
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let files = [url] + older
        if keep == 0 {
            try? fm.removeItem(at: url)
        } else {
            try? fm.removeItem(at: files[keep])
            for i in stride(from: keep - 1, through: 0, by: -1) {
                try? fm.moveItem(at: files[i], to: files[i + 1])
            }
        }
        open()
    }
}
