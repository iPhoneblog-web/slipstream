import AVFoundation
import DropCore
import Foundation

// The ProRes intermediate from the terminal, and the app's own encode process:
//   slipstream-cli <source> [--out DIR | --output FILE] [--avg BPS] [--peak BPS] [--window SECONDS] [--progress-json]
// Prints the result as JSON on stdout; progress goes to stderr. With --progress-json (the app,
// which starts it at nice 19) every line on stdout is JSON: {"fraction","fps","speed"} while it
// runs, then {"result": …} or {"error": {"code", "message"}}.

var args = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
let out = take("--out").map { URL(fileURLWithPath: $0) }
let output = take("--output").map { URL(fileURLWithPath: $0) }
let avg = take("--avg").flatMap(Int.init)
let peak = take("--peak").flatMap(Int.init)
let window = take("--window").flatMap(Double.init)
let json = flag("--progress-json")
guard args.count == 1 else {
    FileHandle.standardError.write("usage: slipstream-cli <source> [--out DIR | --output FILE] [--avg BPS] [--peak BPS] [--window S] [--progress-json]\n".data(using: .utf8)!)
    exit(64)
}
let source = URL(fileURLWithPath: args[0])
let target = output ?? Naming.outputURL(for: source, in: out ?? source.deletingLastPathComponent())
let job = Transcoder(source: source, output: target)
if avg != nil || peak != nil || window != nil {
    job.adjustPlan = { plan in
        var p = plan
        if let avg { p.averageBitRate = avg }
        if let peak { p.peakBitRate = peak }
        if let window { p.peakWindow = window }
        return p
    }
}
// The app stops an encode with SIGTERM: cancel, so no half-written file stays behind.
signal(SIGTERM, SIG_IGN)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
terminate.setEventHandler { job.cancel() }
terminate.resume()

@Sendable func line(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

let lastShown = LockedDouble()
let sem = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task {
    do {
        // Frames per second and speed need the source's length and rate.
        let asset = AVURLAsset(url: source)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        var rate = 0.0
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            rate = Double((try? await track.load(.nominalFrameRate)) ?? 0)
        }
        let fps = rate
        let started = Date()
        let r = try await job.run { fraction in
            if json {
                guard lastShown.advance(to: fraction, every: 0.25) else { return }
                let elapsed = max(Date().timeIntervalSince(started), 0.001)
                var p: [String: Any] = ["fraction": fraction]
                if duration > 0 { p["speed"] = fraction * duration / elapsed }
                if duration > 0, fps > 0 { p["fps"] = fraction * duration * fps / elapsed }
                line(p)
            } else if lastShown.advance(to: fraction, by: 0.1) {
                FileHandle.standardError.write(String(format: "%3.0f %%\n", fraction * 100).data(using: .utf8)!)
            }
        }
        let report: [String: Any] = [
            "output": r.output.path, "source_codec": r.sourceCodec,
            "width": r.plan.width, "height": r.plan.height, "frame_rate": r.plan.frameRate,
            "average_bit_rate": r.plan.averageBitRate, "peak_bit_rate": r.plan.peakBitRate.map { $0 as Any } ?? NSNull(),
            "peak_window": r.plan.peakWindow,
            "source_duration": r.sourceDuration, "duration": r.duration,
            "bytes": r.bytes, "bit_rate": r.bitRate, "elapsed": NSDecimalNumber(string: String(format: "%.1f", r.elapsed)),
        ]
        if json {
            line(["result": report])
        } else {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        }
    } catch {
        if json {
            let e = error as? DropError
            line(["error": ["code": e?.code ?? "internal", "message": error.localizedDescription]])
        } else {
            FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
        }
        exitCode = 1
    }
    sem.signal()
}
sem.wait()
exit(exitCode)

final class LockedDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1.0
    private var at = Date.distantPast

    func advance(to v: Double, by step: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard v >= value + step || (v >= 1 && value < 1) else { return false }
        value = v
        return true
    }

    /// At most once per `seconds`, and always the end.
    func advance(to v: Double, every seconds: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(at) >= seconds || (v >= 1 && value < 1) else { return false }
        at = Date()
        value = v
        return true
    }
}
