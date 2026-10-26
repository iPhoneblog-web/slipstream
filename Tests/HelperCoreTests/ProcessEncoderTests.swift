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
