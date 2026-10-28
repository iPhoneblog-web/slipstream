import Foundation
import HelperCore

/// The embedded worker, `Contents/Helpers/encode-worker` (docs/worker.md): started with the
/// private key on its standard input, commands after it, events back on its standard output.
/// It runs at `nice 19`, and so do the ffmpeg and whisper.cpp it starts.
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
        let start = Date()
        let usage = WorkerFlags.usage(of: Paths.helper("encode-worker"))
        // bin/check-launch waits for this line.
        Log.notice(.worker, "worker usage read in \(Int(Date().timeIntervalSince(start) * 1000)) ms\(usage == nil ? ", no worker" : "")")
        return usage
    }()

    static var isPresent: Bool { FileManager.default.isExecutableFile(atPath: Paths.helper("encode-worker").path) }

    func start(key: WireGuardKey, limits: Limits, version: String) throws {
        try FileManager.default.createDirectory(at: Paths.workerState, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Paths.models, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        var arguments: [String] = [
            "-n", "19", Paths.helper("encode-worker").path,
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
                Log.debug(.worker, "event: \(line)")
                if let event = WorkerEvent.parse(line) { self.onEvent(event) }
            }
        }
        // Standard error is the log for people: the unified log and the log file, at the level
        // the worker gave each line (WorkerLogLine; docs/logging.md).
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
                let (level, text) = WorkerLogLine.stderr(line)
                Log.write(level, .worker, text)
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
        Log.debug(.worker, "command: \(command.line.trimmingCharacters(in: .newlines))")
        write(command.line)
    }

    /// Fails quietly once the worker is gone: SIGPIPE is ignored (AppDelegate), so the write
    /// throws EPIPE, and the exit handler restarts the worker.
    private func write(_ text: String) {
        guard process.isRunning else { return }
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        } catch {
            Log.error(.worker, "worker input: \(error.localizedDescription)")
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
