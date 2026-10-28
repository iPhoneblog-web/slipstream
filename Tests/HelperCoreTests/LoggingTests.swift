import Foundation
import XCTest
@testable import HelperCore

final class LoggingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Levels

    func testSlogLevels() {
        XCTAssertEqual(LogLevel(slog: "DEBUG"), .debug)
        XCTAssertEqual(LogLevel(slog: "INFO"), .info)
        XCTAssertEqual(LogLevel(slog: "WARN"), .warning)
        XCTAssertEqual(LogLevel(slog: "ERROR"), .error)
        // slog's levels between the named ones, and beyond ERROR.
        XCTAssertEqual(LogLevel(slog: "DEBUG-4"), .debug)
        XCTAssertEqual(LogLevel(slog: "INFO+2"), .info)
        XCTAssertEqual(LogLevel(slog: "INFO+4"), .warning)
        XCTAssertEqual(LogLevel(slog: "ERROR+4"), .fault)
        XCTAssertEqual(LogLevel(slog: "warn"), .warning)
        // A word slog never writes: info, so the line is not lost.
        XCTAssertEqual(LogLevel(slog: "LOUD"), .info)
    }

    func testWorkerStandardError() {
        let up = #"time=2026-10-28T20:08:35.213+01:00 level=INFO msg="encode-worker up" version=v0.2.12 name="Mac Studio""#
        XCTAssertEqual(WorkerLogLine.stderr(up).0, .info)
        XCTAssertEqual(WorkerLogLine.stderr(up).1, #"encode-worker up version=v0.2.12 name="Mac Studio""#)
        let warn = #"time=2026-10-28T20:08:35.213+01:00 level=WARN msg=lease lease=ls_1 err="no answer""#
        XCTAssertEqual(WorkerLogLine.stderr(warn).0, .warning)
        XCTAssertEqual(WorkerLogLine.stderr(warn).1, #"lease lease=ls_1 err="no answer""#)
        let quoted = #"time=x level=ERROR msg="the \"captions\" path" job=a"#
        XCTAssertEqual(WorkerLogLine.stderr(quoted).0, .error)
        XCTAssertEqual(WorkerLogLine.stderr(quoted).1, #"the "captions" path job=a"#)
        XCTAssertEqual(WorkerLogLine.stderr("time=x level=DEBUG msg=tick").1, "tick")
        // Not slog: Go's runtime, the worker's last word, a tool's line.
        XCTAssertEqual(WorkerLogLine.stderr("panic: runtime error: index out of range").0, .fault)
        XCTAssertEqual(WorkerLogLine.stderr("fatal error: concurrent map writes").0, .fault)
        XCTAssertEqual(WorkerLogLine.stderr("encode-worker: the tunnel: no route").0, .error)
        XCTAssertEqual(WorkerLogLine.stderr("goroutine 7 [running]:").0, .warning)
        // time= without level= is not slog's form; the line stays whole.
        XCTAssertEqual(WorkerLogLine.stderr("time=soon").0, .warning)
        XCTAssertEqual(WorkerLogLine.stderr("time=soon").1, "time=soon")
    }

    func testJobLines() {
        XCTAssertEqual(WorkerLogLine.job(lease: "ls_1", line: "source checked", level: nil).0, .info)
        XCTAssertEqual(WorkerLogLine.job(lease: "ls_1", line: "source checked", level: nil).1, "ls_1: source checked")
        XCTAssertEqual(WorkerLogLine.job(lease: nil, line: "x", level: "ERROR").0, .error)
        let event = WorkerEvent.parse(#"{"event":"log","lease_id":"ls_1","line":"boom","level":"WARN"}"#)
        XCTAssertEqual(event, .log(leaseId: "ls_1", line: "boom", level: "WARN"))
        XCTAssertEqual(WorkerEvent.parse(#"{"event":"log","line":"quiet"}"#), .log(leaseId: nil, line: "quiet", level: nil))
    }

    // MARK: - The file's lines

    func testEntryRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_793_000_000.25)
        let entry = LogEntry(date: date, level: .warning, category: .extension, message: "GET /v1/ping: 403\nsecond line")
        XCTAssertEqual(entry.body, "WARN   extension GET /v1/ping: 403 second line")
        let url = dir.appendingPathComponent("a.log")
        RotatingLog(url: url).write(entry)
        let line = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .newlines)
        let back = try XCTUnwrap(LogEntry.parse(line))
        XCTAssertEqual(back.level, .warning)
        XCTAssertEqual(back.category, .extension)
        XCTAssertEqual(back.message, "GET /v1/ping: 403 second line")
        XCTAssertEqual(back.date.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        // Two spaces in the message stay.
        XCTAssertEqual(LogEntry.parse("2026-10-28T19:08:35.204Z INFO   worker    a  b")?.message, "a  b")
        XCTAssertNil(LogEntry.parse("2026-10-28T19:08:35.204Z slipstream: worker started"))
        XCTAssertNil(LogEntry.parse("2026-10-28T19:08:35.204Z INFO   nowhere   x"))
        XCTAssertNil(LogEntry.parse("not a line"))
    }

    func testRedaction() {
        XCTAssertEqual(LogRedaction.clean("X-Slipstream-Token: 0123abcd rest"), "X-Slipstream-Token: <privat> rest")
        XCTAssertEqual(LogRedaction.clean("token=abc&x=1"), "token=<privat>")
        XCTAssertEqual(LogRedaction.clean(#"private_key="AAAA=" ok"#), "private_key=<privat> ok")
        XCTAssertEqual(LogRedaction.clean("Authorization: Bearer abc.def"), "Authorization: <privat>")
        XCTAssertEqual(LogRedaction.clean("fetch https://user:pw@funkhaus.example.org/x"), "fetch https://<privat>@funkhaus.example.org/x")
        // Public values stay: a public key, a host, a plain URL.
        let plain = "public_key=jIYN9M5c= api=http://10.0.0.1:8090/v1 site https://funkhaus.example.org"
        XCTAssertEqual(LogRedaction.clean(plain), plain)
    }

    func testFilter() {
        let e = LogEntry(level: .warning, category: .tunnel, message: "Tunnel down: no answer")
        XCTAssertTrue(LogFilter.warnings.shows(e, search: ""))
        XCTAssertFalse(LogFilter.errors.shows(e, search: ""))
        XCTAssertTrue(LogFilter.info.shows(e, search: "TUNNEL "))
        XCTAssertTrue(LogFilter.debug.shows(e, search: "tunnel"))
        XCTAssertFalse(LogFilter.debug.shows(e, search: "pause"))
        XCTAssertFalse(LogFilter.info.shows(LogEntry(level: .debug, category: .app, message: "x"), search: ""))
        XCTAssertTrue(LogFilter.errors.shows(LogEntry(level: .fault, category: .app, message: "x"), search: ""))
        XCTAssertEqual(LogFilter.allCases.map(\.label), ["Fehler", "Warnungen", "Info", "Debug"])
    }

    // MARK: - Rotation

    func testRotationKeepsFiveFiles() throws {
        let url = dir.appendingPathComponent("slipstream.log")
        let log = RotatingLog(url: url, limit: 100, keep: 4)
        let t = Date(timeIntervalSince1970: 0)
        // 33 bytes a line ("1970-01-01T00:00:00.000Z line NN\n"): three to a file.
        for i in 0..<30 { log.write(String(format: "line %02d", i), at: t) }
        XCTAssertEqual(log.older.map(\.lastPathComponent), ["slipstream.log.1", "slipstream.log.2", "slipstream.log.3", "slipstream.log.4"])
        for f in [url] + log.older {
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), f.lastPathComponent)
            XCTAssertLessThanOrEqual(try Data(contentsOf: f).count, 100)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("5").path))
        // Newest in the file, the one before in .1, the oldest kept in .4; the rest is gone.
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasSuffix("line 29\n"))
        let one = try String(contentsOf: log.older[0], encoding: .utf8)
        let four = try String(contentsOf: log.older[3], encoding: .utf8)
        XCTAssertTrue(one.hasSuffix("line 26\n"), one)
        XCTAssertTrue(four.contains("line 15"), four)
        XCTAssertFalse(try ([url] + log.older).map { try String(contentsOf: $0, encoding: .utf8) }.joined().contains("line 14"))
    }

    func testRotationWithoutOlderFiles() throws {
        let url = dir.appendingPathComponent("only.log")
        let log = RotatingLog(url: url, limit: 40, keep: 0)
        for i in 0..<5 { log.write("line \(i)", at: Date(timeIntervalSince1970: 0)) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "1970-01-01T00:00:00.000Z line 4\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
    }

    // MARK: - Following the file

    func testTailFollowsAcrossRotation() throws {
        let url = dir.appendingPathComponent("slipstream.log")
        let log = RotatingLog(url: url, limit: 120, keep: 4)
        let t = Date(timeIntervalSince1970: 0)
        let tail = LogTail(url: url)
        XCTAssertEqual(tail.start(lastBytes: 1000), [], "no file yet")
        log.write("a", at: t)
        XCTAssertEqual(tail.read(), ["1970-01-01T00:00:00.000Z a"], "the file appeared")
        XCTAssertEqual(tail.read(), [])
        log.write("b", at: t)
        log.write("c", at: t)
        XCTAssertEqual(tail.read().map { $0.suffix(1) }, ["b", "c"])
        // Four lines to a file. The next lines rotate it twice between two reads: the rest of
        // the file it had open (now .2), then the new file from its start; the file in between
        // (now .1) is skipped, and is in the file for whoever needs it.
        for w in ["d", "e", "f", "g", "h", "i", "j"] { log.write(w, at: t) }
        XCTAssertEqual(tail.read().map { String($0.suffix(1)) }, ["d", "i", "j"])
        XCTAssertEqual(tail.read(), [])
        log.write("k", at: t)
        XCTAssertEqual(tail.read().map { $0.suffix(1) }, ["k"])
    }

    func testTailStartsAtWholeLines() throws {
        let url = dir.appendingPathComponent("slipstream.log")
        try "first line\nsecond line\nthird line\n".write(to: url, atomically: true, encoding: .utf8)
        let tail = LogTail(url: url)
        // The last 15 bytes start inside "second line": that cut line goes.
        XCTAssertEqual(tail.start(lastBytes: 15), ["third line"])
        XCTAssertEqual(LogTail(url: url).start(lastBytes: 1 << 20), ["first line", "second line", "third line"])
        // A line written in two parts comes once it is whole.
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("four".utf8))
        XCTAssertEqual(tail.read(), [])
        try h.write(contentsOf: Data("th\n".utf8))
        try h.close()
        XCTAssertEqual(tail.read(), ["fourth"])
    }

    func testFollow() {
        var f = LogFollow()
        XCTAssertTrue(f.on, "on when the window opens")
        f.userScrolled(distanceFromEnd: 10)
        XCTAssertTrue(f.on, "within a line of the end")
        f.userScrolled(distanceFromEnd: 200)
        XCTAssertFalse(f.on, "scrolled up")
        f.userScrolled(distanceFromEnd: 100)
        XCTAssertFalse(f.on)
        f.userScrolled(distanceFromEnd: 0)
        XCTAssertTrue(f.on, "back at the end")
        f.on = false
        XCTAssertFalse(f.on, "the checkbox turns it off at the end too")
        f.userScrolled(distanceFromEnd: LogFollow.slack)
        XCTAssertTrue(f.on)
    }

    // MARK: - The worker's events

    func testEventLogJob() throws {
        var log = WorkerEventLog()
        let t0 = Date(timeIntervalSince1970: 1000)
        func job(_ fraction: Double, phase: String = "encoding") -> WorkerEvent {
            WorkerEvent.parse(#"{"event":"job","lease_id":"ls_1","title":"one_144","kind":"rung","rung":"2160","slot":"normal","phase":"\#(phase)","fraction":\#(fraction),"fps":9.4,"speed":0.38,"eta_s":1260}"#)!
        }
        let start = log.lines(for: job(0.0, phase: "downloading"), at: t0)
        XCTAssertEqual(start, [LogRecord(.notice, .encode, "one_144 (ls_1): started, rung 2160p, normal slot, downloading")])
        XCTAssertEqual(log.lines(for: job(0.5, phase: "downloading"), at: t0 + 5).count, 1, "50 %")
        XCTAssertEqual(log.lines(for: job(0.0), at: t0 + 10), [LogRecord(.info, .encode, "one_144 (ls_1): encoding after 10 s")])
        // A second a second; a line only at each tenth.
        var steps: [LogRecord] = []
        for i in 1...100 { steps += log.lines(for: job(Double(i) / 100), at: t0 + 10 + Double(i)) }
        XCTAssertEqual(steps.count, 10)
        XCTAssertEqual(steps.first?.message, "one_144 (ls_1): 10 % (9.4 fps, 0.38× real time, 21 min 0 s left)")
        XCTAssertEqual(steps.last?.message.hasPrefix("one_144 (ls_1): 100 %"), true)
        let result = WorkerEvent.result(leaseId: "ls_1", title: "one_144", verdict: "accepted", check: nil)
        XCTAssertEqual(log.lines(for: result, at: t0 + 3730), [LogRecord(.notice, .encode, "one_144 (ls_1): accepted after 1 h 2 min")])
        XCTAssertEqual(log.lines(for: .idle, at: t0 + 3731), [], "the job ended with its result")
    }

    func testEventLogResults() {
        var log = WorkerEventLog()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = log.lines(for: .job(WorkerJob(leaseId: "a", title: "A", kind: "whisper")), at: t0)
        XCTAssertEqual(log.lines(for: .result(leaseId: "a", title: "A", verdict: "given_back", check: "preempted"), at: t0 + 42),
                       [LogRecord(.notice, .encode, "A (a): preempted, given back to the queue after 42 s")])
        XCTAssertEqual(log.lines(for: .result(leaseId: "b", title: "B", verdict: "rejected", check: "decode errors"), at: t0),
                       [LogRecord(.error, .encode, "B (b): rejected: decode errors")])
        _ = log.lines(for: .job(WorkerJob(leaseId: "c", title: "C")), at: t0)
        XCTAssertEqual(log.lines(for: .idle, at: t0 + 75), [LogRecord(.info, .encode, "C (c): ended without a result after 1 min 15 s")])
    }

    func testEventLogStateChangesOnce() {
        var log = WorkerEventLog()
        let up = WorkerEvent.connection(up: true, lastAnswerAt: nil, refused: [])
        XCTAssertEqual(log.lines(for: up), [LogRecord(.notice, .tunnel, "tunnel up: the queue answers")])
        XCTAssertEqual(log.lines(for: up), [])
        let refused = WorkerEvent.connection(up: true, lastAnswerAt: nil, refused: [WorkerEvent.Refusal(kind: "whisper", reason: "old")])
        XCTAssertEqual(log.lines(for: refused), [LogRecord(.warning, .tunnel, "the queue refuses whisper jobs: old")])
        XCTAssertEqual(log.lines(for: .connection(up: false, lastAnswerAt: nil, refused: [WorkerEvent.Refusal(kind: "whisper", reason: "old")])),
                       [LogRecord(.warning, .tunnel, "tunnel down: no answer from the queue")])
        let limits = WorkerEvent.limits(WorkerEvent.Limits(threads: 3, cores: 12, throttled: 1, efficiency: "archive"))
        XCTAssertEqual(log.lines(for: limits),
                       [LogRecord(.notice, .cores, "CPU limit in effect: 3 of 12 cores, 1 running job held to it, efficiency cores: archive")])
        XCTAssertEqual(log.lines(for: limits), [])
        XCTAssertEqual(log.lines(for: .paused(until: nil, mode: nil)), [LogRecord(.notice, .pause, "the worker holds no pause")])
        XCTAssertEqual(log.lines(for: .paused(until: nil, mode: nil)), [])
        let model = WorkerEvent.Model(name: "small", sha256: "s", state: "failed", reason: "sha256 differs")
        XCTAssertEqual(log.lines(for: .model(model)), [LogRecord(.error, .worker, "whisper model small: failed: sha256 differs")])
        XCTAssertEqual(log.lines(for: .model(model)), [])
        XCTAssertEqual(log.lines(for: .update(latest: "1.3.7")), [LogRecord(.notice, .update, "the queue wants a newer Slipstream: 1.3.7")])
        log.reset()
        XCTAssertEqual(log.lines(for: up).count, 1, "a new worker says it again")
    }

    func testDuration() {
        XCTAssertEqual(WorkerEventLog.duration(0), "0 s")
        XCTAssertEqual(WorkerEventLog.duration(59.6), "1 min 0 s")
        XCTAssertEqual(WorkerEventLog.duration(725), "12 min 5 s")
        XCTAssertEqual(WorkerEventLog.duration(4320), "1 h 12 min")
    }
}
