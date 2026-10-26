@testable import HelperCore
import XCTest

/// The encode in its own process at nice 19: the slipstream-cli that `swift test` built beside
/// this test bundle, on the committed fixtures.
final class ProcessEncoderTests: XCTestCase {
    private var out: URL!

    override func setUpWithError() throws {
        out = FileManager.default.temporaryDirectory.appendingPathComponent("slipstream-proc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: out)
    }

    private func cli() throws -> URL {
        let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("slipstream-cli")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: url.path), "slipstream-cli not built")
        return url
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../DropCoreTests/fixtures/\(name)").standardizedFileURL
    }

    func testEncodesWithProgress() async throws {
        let seen = Box<[Double]>([])
        let encode = ProcessEncoder.make(cli: try cli())
        let info = try await encode(fixture("prores-hq-320x180.mov"), out.appendingPathComponent("i.mp4")) { p in
            seen.value.append(p.fraction)
        }
        XCTAssertEqual(info.width, 320)
        XCTAssertEqual(info.durationS, 2.0, accuracy: 0.05)
        XCTAssertGreaterThan(info.size, 0)
        XCTAssertEqual(seen.value.last, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("i.mp4").path))
    }

    /// The guard fires: the process's error comes back with the page's code.
    func testNotAVideo() async throws {
        let encode = ProcessEncoder.make(cli: try cli())
        do {
            _ = try await encode(fixture("not-a-video.mov"), out.appendingPathComponent("i.mp4")) { _ in }
            XCTFail("expected an error")
        } catch let e as JobError {
            XCTAssertEqual(e.code, "not-a-video")
        }
    }

    /// The guard fires: a cancel before the launch never terminates a process that did not run
    /// (that raised and ended the app). Open, receive, delete, 50 times.
    func testCancelBeforeLaunch() async throws {
        let encode = ProcessEncoder.make(cli: try cli())
        for _ in 0..<50 {
            let task = Task { try await encode(fixture("prores-hq-320x180.mov"), out.appendingPathComponent("i.mp4")) { _ in } }
            task.cancel()
            _ = try? await task.value
        }
        let jobs = ProResJobs(root: out.appendingPathComponent("jobs"), encoder: encode)
        try await jobs.load()
        let data = try Data(contentsOf: fixture("prores-hq-320x180.mov"))
        for i in 0..<50 {
            _ = try await jobs.open(id: "c\(i)", name: "a.mov", size: Int64(data.count), lastModified: nil)
            _ = try await jobs.receive(id: "c\(i)", range: 0..<Int64(data.count), total: Int64(data.count), data: data)
            try await jobs.delete(id: "c\(i)")
        }
        let left = await jobs.list()
        XCTAssertEqual(left.count, 0)
    }

    /// A cancelled task ends the process and leaves no file.
    func testCancel() async throws {
        let encode = ProcessEncoder.make(cli: try cli())
        let target = out.appendingPathComponent("i.mp4")
        let task = Task { try await encode(fixture("prores-proxy-5k.mov"), target) { _ in } }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancel")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
