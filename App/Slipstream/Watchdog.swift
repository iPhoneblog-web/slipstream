import Foundation
import HelperCore
import os

/// Logs when the main thread does not answer within 100 ms: a ping from a background thread
/// every 250 ms, and the time the main queue took to run it. A click in Settings must answer
/// within 100 ms; 1.3.0 froze for seconds on synchronous daemon calls (docs/traps.md, "A frozen
/// Settings window"). bin/check-launch fails on any such line while it goes through Settings.
final class Watchdog: @unchecked Sendable {
    static let limitMS = 100
    private let log = Logger(subsystem: SlipstreamIDs.logSubsystem, category: "watchdog")
    private let thread = DispatchQueue(label: "io.github.kyrios.slipstream.watchdog", qos: .utility)

    func start() {
        thread.async { [self] in
            while true {
                let sent = DispatchTime.now().uptimeNanoseconds
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let ms = Int((DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000)
                if ms >= Self.limitMS {
                    log.notice("main thread blocked \(ms, privacy: .public) ms")
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }
}
