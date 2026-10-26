@testable import DropCore
import Foundation
import VideoToolbox
import XCTest

final class PlanTests: XCTestCase {
    /// The sizes the server's plan_rungs gives its top rung (infra video-encode, `fit`).
    func testFitMatchesTheServer() {
        let cases: [((Int, Int), (Int, Int))] = [
            ((3840, 2160), (3840, 2160)),   // 4K stays 4K
            ((5120, 2880), (3840, 2160)),   // above 4K goes into the box
            ((4096, 2160), (3840, 2024)),   // DCI 4K: 2025 rounds to the even 2024, as Python does
            ((1920, 1080), (1920, 1080)),   // never upscaled
            ((2160, 3840), (2160, 3840)),   // portrait turns the box
            ((2880, 5120), (2160, 3840)),
            ((3840, 1920), (3840, 1920)),   // 2:1 fits as it is
        ]
        for ((w, h), (ew, eh)) in cases {
            let got = Plan.fit(width: w, height: h)
            XCTAssertEqual(got.width, ew, "\(w)x\(h)")
            XCTAssertEqual(got.height, eh, "\(w)x\(h)")
        }
    }

    /// ADR-0007 §8: 50 Mbit/s for every size and frame rate, an average alone, no peak.
    func testIntermediateRate() {
        for (w, h, fps) in [(3840, 2160, 25.0), (1920, 1080, 50), (5120, 2880, 24), (720, 1280, 30)] {
            let plan = Plan.make(width: w, height: h, frameRate: fps)
            XCTAssertEqual(plan.averageBitRate, 50_000_000, "\(w)x\(h)")
            XCTAssertNil(plan.peakBitRate)
        }
    }

    func testMissingFrameRateCountsAs25() {
        XCTAssertEqual(Plan.make(width: 3840, height: 2160, frameRate: 0).frameRate, 25)
    }

    /// The compression settings carry a peak only when the plan has one (the CLI's --peak).
    func testPeakOnlyWhenAsked() {
        var plan = Plan.make(width: 1920, height: 1080, frameRate: 25)
        XCTAssertNil(Transcoder.compression(plan)[kVTCompressionPropertyKey_DataRateLimits as String])
        plan.peakBitRate = 8_000_000
        let limits = Transcoder.compression(plan)[kVTCompressionPropertyKey_DataRateLimits as String] as? [Double]
        XCTAssertEqual(limits, [1_000_000, 1])
    }
}

final class NamingTests: XCTestCase {
    let folder = URL(fileURLWithPath: "/Users/editor/Movies/Slipstream")

    func testSameNameWithMp4() {
        let src = URL(fileURLWithPath: "/Users/editor/Desktop/Folge 245 Apple Event.mov")
        XCTAssertEqual(Naming.outputURL(for: src, in: folder, exists: { _ in false }).lastPathComponent,
                       "Folge 245 Apple Event.mp4")
    }

    func testNeverOverwrites() {
        let src = URL(fileURLWithPath: "/Users/editor/Desktop/Folge 123.mov")
        let taken: Set<String> = ["Folge 123.mp4", "Folge 123 2.mp4"]
        let out = Naming.outputURL(for: src, in: folder, exists: { taken.contains($0.lastPathComponent) })
        XCTAssertEqual(out.lastPathComponent, "Folge 123 3.mp4")
    }

    /// An .mp4 source inside the destination folder must not become its own output.
    func testNeverTheSourceItself() {
        let src = folder.appendingPathComponent("Folge 123.mp4")
        XCTAssertEqual(Naming.outputURL(for: src, in: folder, exists: { _ in false }).lastPathComponent,
                       "Folge 123 2.mp4")
    }

    func testCodecNames() {
        XCTAssertEqual(Naming.codecName(0x6170_6368), "ProRes 422 HQ")   // 'apch'
        XCTAssertEqual(Naming.codecName(0x4646_5631), "FFV1")            // unknown: the four characters
    }
}

final class MP4BoxesTests: XCTestCase {
    private func file(_ boxes: [(String, Int)]) throws -> URL {
        var data = Data()
        for (type, size) in boxes {
            var header = withUnsafeBytes(of: UInt32(size).bigEndian) { Data($0) }
            header.append(type.data(using: .ascii)!)
            data.append(header)
            data.append(Data(count: size - 8))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testIndexInFront() throws {
        XCTAssertTrue(try MP4Boxes.isFastStart(file([("ftyp", 24), ("moov", 100), ("mdat", 1000)])))
    }

    /// The guard fires: the layout a writer without fast start leaves behind.
    func testIndexAtTheEnd() throws {
        XCTAssertFalse(try MP4Boxes.isFastStart(file([("ftyp", 24), ("mdat", 1000), ("moov", 100)])))
        XCTAssertFalse(try MP4Boxes.isFastStart(file([("ftyp", 24), ("mdat", 1000)])))
    }
}
