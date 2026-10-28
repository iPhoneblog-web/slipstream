@testable import HelperCore
import XCTest

/// WorkerFlags.usage runs inside `static let`s the menu reads (AppModel.workerHasModes). It must
/// never run the main run loop: SwiftUI builds the menu in any turn of it, and 1.3.6 crashed at
/// every launch when the CPU picker read the static whose initialiser was waiting in
/// `Process.waitUntilExit` ("BUG IN CLIENT OF LIBDISPATCH: trying to lock recursively").
final class WorkerUsageTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("slipstream-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A worker slow to answer `-h`, as one is when macOS checks a freshly updated app's helpers.
    private func slowWorker() throws -> URL {
        let url = dir.appendingPathComponent("encode-worker")
        try "#!/bin/sh\nsleep 0.3\nprintf 'usage: encode-worker [flags]\\n  -efficiency string\\n    \\toff, all or archive\\n'\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Counts the main run loop's turns while `body` runs on the main thread.
    private func mainRunLoopTurns(during body: () -> Void) -> Int {
        XCTAssertTrue(Thread.isMainThread)
        var turns = 0
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { _, _ in turns += 1 }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        body()
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        return turns
    }

    func testUsageNeverRunsTheRunLoop() throws {
        let worker = try slowWorker()
        var usage: String?
        let turns = mainRunLoopTurns { usage = WorkerFlags.usage(of: worker) }
        XCTAssertEqual(turns, 0, "WorkerFlags.usage ran the main run loop, where SwiftUI rebuilds the menu")
        XCTAssertTrue(WorkerFlags.supports("efficiency", usage: try XCTUnwrap(usage)))
    }

    /// The observer does see a wait that runs the run loop, as 1.3.6's did; else the test above
    /// proves nothing.
    func testWaitUntilExitRunsTheRunLoop() throws {
        let p = Process()
        p.executableURL = try slowWorker()
        p.arguments = ["-h"]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        XCTAssertGreaterThan(mainRunLoopTurns { p.waitUntilExit() }, 0)
    }

    func testUsageOfAMissingWorker() {
        XCTAssertNil(WorkerFlags.usage(of: dir.appendingPathComponent("encode-worker")))
    }
}
