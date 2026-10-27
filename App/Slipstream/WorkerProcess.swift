import Foundation
import HelperCore
import os

/// The embedded worker, `Contents/Helpers/encode-worker` (docs/worker.md): started with the
/// private key on its standard input, commands after it, events back on its standard output.
/// It runs at `nice 19`, and so do the ffmpeg and whisper.cpp it starts.
final class WorkerProcess: @unchecked Sendable {
    struct Limits: Equatable {
        var threads: Int
        var gpu: Bool
        var jobs: Int
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let log = Logger(subsystem: SlipstreamIDs.logSubsystem, category: "worker")
    private let lock = NSLock()
    private var lines = LineBuffer()

    let id = UUID()
    let onEvent: @Sendable (WorkerEvent) -> Void
    let onExit: @Sendable (Int32) -> Void

    init(onEvent: @escaping @Sendable (WorkerEvent) -> Void, onExit: @escaping @Sendable (Int32) -> Void) {
        self.onEvent = onEvent
        self.onExit = onExit
    }

    static var isPresent: Bool { FileManager.default.isExecutableFile(atPath: Paths.helper("encode-worker").path) }

    func start(key: WireGuardKey, limits: Limits, version: String) throws {
        try FileManager.default.createDirectory(at: Paths.workerState, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Paths.models, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        process.arguments = [
            "-n", "19", Paths.helper("encode-worker").path,
            "--key-stdin", "--tunnel-file", Paths.tunnel.path, "--state-dir", Paths.workerState.path,
            "--name", AppPairing.macName, "--app-version", version,
            "--threads", String(limits.threads), "--gpu", limits.gpu ? "true" : "false", "--jobs", String(limits.jobs),
            "--ffmpeg", Paths.helper("ffmpeg").path, "--ffprobe", Paths.helper("ffprobe").path,
            "--whisper-cli", Paths.helper("whisper-cli").path, "--whisper-models", Paths.models.path,
            "--control", "stdio",
        ] + (Paths.whisperVersion.map { ["--whisper-version", $0] } ?? [])
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
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                self.log.info("\(line, privacy: .public)")
                self.onEvent(.log(leaseId: nil, line: String(line)))
            }
        }
        process.terminationHandler = { [weak self] p in
            self?.output.fileHandleForReading.readabilityHandler = nil
            self?.errors.fileHandleForReading.readabilityHandler = nil
            self?.onExit(p.terminationStatus)
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
