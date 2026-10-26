import Foundation

/// The ProRes encode in its own process: `slipstream-cli --progress-json`, started at `nice 19`
/// like every encode of Slipstream, so the app itself (the loopback endpoint, the menu) keeps
/// its normal priority. A cancelled task terminates the process, which cancels its encode.
public enum ProcessEncoder {
    public static func make(cli: URL, nice: Int = 19) -> IntermediateEncoder {
        return { source, output, progress in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
            process.arguments = ["-n", String(nice), cli.path, source.path, "--output", output.path, "--progress-json"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            let parser = Parser(progress: progress)
            // One reader to the end of the output, so the last line (the result or the error)
            // is read before the outcome, however the exit and the reads interleave.
            let reader = Thread {
                let handle = stdout.fileHandleForReading
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    parser.feed(data)
                }
                parser.finish()
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { _ in done.resume() }
                    do {
                        try process.run()
                        reader.start()
                    } catch {
                        process.terminationHandler = nil
                        done.resume(throwing: error)
                    }
                }
            } onCancel: {
                process.terminate()
            }
            await parser.drained()
            if Task.isCancelled { throw JobError("internal", "Abgebrochen.") }
            return try parser.outcome()
        }
    }

    /// Reads the lines: progress as it comes, the result or the error at the end.
    final class Parser: @unchecked Sendable {
        private let lock = NSLock()
        private var lines = LineBuffer()
        private var result: [String: Any]?
        private var error: JobError?
        private let progress: @Sendable (EncodeProgress) -> Void
        private var ended = false
        private var waiting: CheckedContinuation<Void, Never>?

        init(progress: @escaping @Sendable (EncodeProgress) -> Void) {
            self.progress = progress
        }

        func feed(_ data: Data) {
            guard !data.isEmpty else { return }
            let new = lock.withLock { lines.append(data) }
            for line in new {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let fraction = object["fraction"] as? Double {
                    progress(EncodeProgress(fraction: fraction, fps: object["fps"] as? Double, speed: object["speed"] as? Double))
                } else if let r = object["result"] as? [String: Any] {
                    lock.withLock { result = r }
                } else if let e = object["error"] as? [String: Any] {
                    lock.withLock { error = JobError(e["code"] as? String ?? "internal", e["message"] as? String ?? "") }
                }
            }
        }

        /// The output reached its end.
        func finish() {
            let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                ended = true
                defer { waiting = nil }
                return waiting
            }
            w?.resume()
        }

        func drained() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let now = lock.withLock { () -> Bool in
                    if ended { return true }
                    waiting = c
                    return false
                }
                if now { c.resume() }
            }
        }

        func outcome() throws -> IntermediateInfo {
            try lock.withLock {
                if let error { throw error }
                guard let r = result, let bytes = (r["bytes"] as? NSNumber)?.int64Value else {
                    throw JobError("internal", "Die Umwandlung endete ohne Ergebnis.")
                }
                return IntermediateInfo(size: bytes, durationS: (r["duration"] as? NSNumber)?.doubleValue ?? 0,
                                        width: (r["width"] as? NSNumber)?.intValue ?? 0,
                                        height: (r["height"] as? NSNumber)?.intValue ?? 0,
                                        bitRate: (r["bit_rate"] as? NSNumber)?.intValue ?? 0, codec: "hvc1")
            }
        }
    }
}
