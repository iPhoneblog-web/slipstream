import Foundation
import HelperCore
import os

/// The worker's log file, `~/Library/Logs/Slipstream/worker.log` (rotated at 5 MB): its standard
/// error and the app's lines about starting and stopping it. Up to 1.3.1 these lines lived only
/// in the log window and in the unified log at info level, which macOS does not keep; a worker
/// that died left no trace (docs/worker.md, "When the worker stops").
enum WorkerLog {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Slipstream/worker.log")
    private static let queue = DispatchQueue(label: "io.github.kyrios.slipstream.worker-log", qos: .utility)
    nonisolated(unsafe) private static let file = RotatingLog(url: url)

    static func write(_ line: String) {
        queue.async { file.write(line) }
    }
}

/// The embedded worker, `Contents/Helpers/encode-worker` (docs/worker.md): started with the
/// private key on its standard input, commands after it, events back on its standard output.
/// It sets its tools' priority itself (encode-queue v0.2.20): a normal job's at `nice 19` under the
/// utility QoS clamp, a Sofort job's at the worker's own, which is why it starts at nice 0 here.
final class WorkerProcess: @unchecked Sendable {
    struct Limits: Equatable {
        var threads: Int
        var gpu: Bool
        var jobs: Int
        var highSlots: Int
        var efficiency: Efficiency
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let log = Logger(subsystem: SlipstreamIDs.logSubsystem, category: "worker")
    private let lock = NSLock()
    private var lines = LineBuffer()
    private var errorLines = LineBuffer()
    /// Its last lines on standard error, for the reason it stopped (WorkerExit).
    private var tail: [String] = []

    let id = UUID()
    let onEvent: @Sendable (WorkerEvent) -> Void
    /// Why it stopped, one line (WorkerExit.reason).
    let onExit: @Sendable (String) -> Void

    init(onEvent: @escaping @Sendable (WorkerEvent) -> Void, onExit: @escaping @Sendable (String) -> Void) {
        self.onEvent = onEvent
        self.onExit = onExit
    }

    var pid: Int32 { process.processIdentifier }

    /// Whether the embedded worker takes a flag, read once from its usage.
    static func takes(_ flag: String) -> Bool { usage.map { WorkerFlags.supports(flag, usage: $0) } ?? false }

    private static let usage: String? = {
        let p = Process()
        p.executableURL = Paths.helper("encode-worker")
        p.arguments = ["-h"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }()

    static var isPresent: Bool { FileManager.default.isExecutableFile(atPath: Paths.helper("encode-worker").path) }

    func start(key: WireGuardKey, limits: Limits, version: String) throws {
        try FileManager.default.createDirectory(at: Paths.workerState, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Paths.models, withIntermediateDirectories: true)
        // Not under nice 19 (encode-queue v0.2.20, "realtime by the OS scheduler"): the worker puts
        // each normal job's tools at nice 19 under the utility QoS clamp itself, and a Sofort job's
        // at its own priority; an unprivileged process cannot lower its nice again, so a worker at
        // 19 held Sofort jobs at 19 too. User-initiated, so nothing clamps it below the default
        // (docs/traps.md, "Priority"). A worker before v0.2.20 renices itself to 19 as before.
        process.executableURL = Paths.helper("encode-worker")
        process.qualityOfService = .userInitiated
        var arguments: [String] = [
            "--key-stdin", "--tunnel-file", Paths.tunnel.path, "--state-dir", Paths.workerState.path,
            // No --app-version: the helper API's app_version is the worker's own release, which
            // the queue compares with its min_app_version; the worker sends it by itself. The app
            // around it goes in host_app (helper.yaml 1.1.1).
            "--name", AppPairing.macName,
            "--host-app-name", "Slipstream", "--host-app-version", version,
            "--threads", String(limits.threads), "--gpu", limits.gpu ? "true" : "false", "--jobs", String(limits.jobs),
            "--ffmpeg", Paths.helper("ffmpeg").path, "--ffprobe", Paths.helper("ffprobe").path,
            "--whisper-cli", Paths.helper("whisper-cli").path, "--whisper-models", Paths.models.path,
            "--control", "stdio",
        ]
        if let v = Paths.whisperVersion { arguments += ["--whisper-version", v] }
        // v0.2.8 on: every tool version (libass too) from Resources/versions.txt, since codesign
        // allows no versions.txt beside ffmpeg (docs/tools.md, "Captions").
        if let file = Paths.toolVersionsFile, Self.takes("toolchain-versions") {
            arguments += ["--toolchain-versions", file.path]
        }
        // v0.2.14 on: the high-priority slots beside the normal ones (docs/worker.md).
        if Self.takes("high-slots") {
            arguments += ["--high-slots", String(limits.highSlots)]
        }
        // v0.2.18 on: the jobs that run on the efficiency cores only (docs/worker.md).
        if Self.takes("efficiency") {
            arguments += ["--efficiency", limits.efficiency.rawValue]
        }
        process.arguments = arguments
        // The toolchain's fonts for libass and its fc-list first on PATH (docs/tools.md,
        // "Captions"); the worker would look for the fonts beside ffmpeg, outside Resources.
        process.environment = WorkerEnvironment.make(
            base: ProcessInfo.processInfo.environment, helpers: Paths.helper("ffmpeg").deletingLastPathComponent().path,
            fontsConf: Paths.fontsConf?.path, cache: Paths.caches.path)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            let lines = self.lock.withLock { self.lines.append(data) }
            for line in lines {
                if let event = WorkerEvent.parse(line) { self.onEvent(event) }
            }
        }
        // Standard error is the log for people: the log window, the unified log, and
        // ~/Library/Logs/Slipstream/worker.log, which outlives the app (WorkerLog).
        let stderrDone = DispatchSemaphore(value: 0)
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                stderrDone.signal()
                return
            }
            let new = self.lock.withLock {
                let new = self.errorLines.append(data)
                self.tail = Array((self.tail + new).suffix(40))
                return new
            }
            for line in new {
                self.log.info("\(line, privacy: .public)")
                WorkerLog.write(line)
                self.onEvent(.log(leaseId: nil, line: line))
            }
        }
        process.terminationHandler = { [weak self] p in
            let signal = p.terminationReason == .uncaughtSignal ? p.terminationStatus : nil
            let status = p.terminationStatus
            // Its last words first: a Go panic writes them just before the end. At most 2 s,
            // in case a tool it started still holds standard error open.
            DispatchQueue.global(qos: .utility).async {
                _ = stderrDone.wait(timeout: .now() + 2)
                guard let self else { return }
                self.output.fileHandleForReading.readabilityHandler = nil
                self.errors.fileHandleForReading.readabilityHandler = nil
                let tail = self.lock.withLock { self.tail }
                self.onExit(WorkerExit.reason(status: status, signal: signal, lastLines: tail))
            }
        }
        try process.run()
        write(key.privateBase64 + "\n")
    }

    func send(_ command: WorkerCommand) {
        write(command.line)
    }

    /// Fails quietly once the worker is gone: SIGPIPE is ignored (AppDelegate), so the write
    /// throws EPIPE, and the exit handler restarts the worker.
    private func write(_ text: String) {
        guard process.isRunning else { return }
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        } catch {
            log.error("worker input: \(error.localizedDescription, privacy: .public)")
        }
    }

    var isRunning: Bool { process.isRunning }

    /// Asks the worker to give its leases back and waits up to `timeout` for it to go; then it
    /// is terminated.
    func quit(timeout: TimeInterval) async {
        guard process.isRunning else { return }
        send(.quit)
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning { process.terminate() }
    }
}
