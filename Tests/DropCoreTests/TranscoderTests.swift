import AVFoundation
@testable import DropCore
import XCTest

/// Real encodes of the files in fixtures/ (make.sh), read back with AVFoundation.
final class TranscoderTests: XCTestCase {
    private var out: URL!

    override func setUpWithError() throws {
        out = FileManager.default.temporaryDirectory.appendingPathComponent("slipstream-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: out)
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "fixtures"))
    }

    private struct Probe {
        var codec: String
        var width: Int
        var height: Int
        var colour: [String: String]
        var channels: Int?
        var audioCodec: String?
        var duration: Double
    }

    private func probe(_ url: URL) async throws -> Probe {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        let video = try XCTUnwrap(tracks.first { $0.mediaType == .video })
        let formats = try await video.load(.formatDescriptions)
        let vf = try XCTUnwrap(formats.first)
        let dims = CMVideoFormatDescriptionGetDimensions(vf)
        var colour: [String: String] = [:]
        for key in [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction,
                    kCMFormatDescriptionExtension_YCbCrMatrix] {
            colour[key as String] = CMFormatDescriptionGetExtension(vf, extensionKey: key) as? String
        }
        var channels: Int?, audioCodec: String?
        if let audio = tracks.first(where: { $0.mediaType == .audio }),
           let af = try await audio.load(.formatDescriptions).first {
            channels = Int(CMAudioFormatDescriptionGetStreamBasicDescription(af)?.pointee.mChannelsPerFrame ?? 0)
            audioCodec = Naming.fourCC(CMFormatDescriptionGetMediaSubType(af))
        }
        let duration = try await asset.load(.duration).seconds
        return Probe(codec: Naming.fourCC(CMFormatDescriptionGetMediaSubType(vf)), width: Int(dims.width),
                     height: Int(dims.height), colour: colour, channels: channels, audioCodec: audioCodec,
                     duration: duration)
    }

    func testProResBecomesHEVCMain10() async throws {
        let src = try fixture("prores-hq-320x180.mov")
        let result = try await Transcoder(source: src, output: out.appendingPathComponent("intermediate.mp4")).run { _ in }
        XCTAssertEqual(result.output.lastPathComponent, "intermediate.mp4")
        XCTAssertEqual(result.sourceCodec, "ProRes 422 HQ")
        let p = try await probe(result.output)
        XCTAssertEqual(p.codec, "hvc1")
        XCTAssertEqual(p.width, 320)
        XCTAssertEqual(p.height, 180)
        XCTAssertEqual(p.audioCodec, "aac ")
        XCTAssertEqual(p.channels, 2)
        XCTAssertEqual(p.duration, 2.0, accuracy: 0.04)
        XCTAssertEqual(p.colour[kCMFormatDescriptionExtension_ColorPrimaries as String], "ITU_R_709_2")
        XCTAssertEqual(p.colour[kCMFormatDescriptionExtension_TransferFunction as String], "ITU_R_709_2")
        XCTAssertEqual(p.colour[kCMFormatDescriptionExtension_YCbCrMatrix as String], "ITU_R_709_2")
        XCTAssertTrue(try MP4Boxes.isFastStart(result.output))
        // Only the finished file in the folder: no temporary leftovers.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["intermediate.mp4"])
    }

    func testPortraitMonoKeepsSizeAndGetsStereo() async throws {
        let result = try await Transcoder(source: fixture("prores-portrait-mono.mov"), output: out.appendingPathComponent("intermediate.mp4")).run { _ in }
        let p = try await probe(result.output)
        XCTAssertEqual(p.width, 180)
        XCTAssertEqual(p.height, 320)
        XCTAssertEqual(p.channels, 2)
        XCTAssertEqual(result.plan.frameRate, 30, accuracy: 0.01)
    }

    func testAbove4KIsScaledIntoTheBox() async throws {
        let result = try await Transcoder(source: fixture("prores-proxy-5k.mov"), output: out.appendingPathComponent("intermediate.mp4")).run { _ in }
        let p = try await probe(result.output)
        XCTAssertEqual(p.width, 3840)
        XCTAssertEqual(p.height, 2160)
        XCTAssertNil(p.channels)
    }

    /// A second encode of the same job replaces the first file: the job's path is fixed.
    func testSecondRunReplaces() async throws {
        let src = try fixture("prores-portrait-mono.mov")
        let target = out.appendingPathComponent("intermediate.mp4")
        _ = try await Transcoder(source: src, output: target).run { _ in }
        let second = try await Transcoder(source: src, output: target).run { _ in }
        XCTAssertEqual(second.output, target)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["intermediate.mp4"])
    }

    /// The rate the server wants: about 50 Mbit/s of video on a 4K source with motion.
    func testRateIsTheIntermediates() async throws {
        let result = try await Transcoder(source: fixture("prores-proxy-5k.mov"), output: out.appendingPathComponent("intermediate.mp4")).run { _ in }
        XCTAssertNil(result.plan.peakBitRate)
        XCTAssertEqual(result.plan.averageBitRate, 50_000_000)
    }

    func testNotAVideo() async throws {
        do {
            _ = try await Transcoder(source: fixture("not-a-video.mov"), output: out.appendingPathComponent("intermediate.mp4")).run { _ in }
            XCTFail("expected an error")
        } catch let error as DropError {
            XCTAssertEqual(error, .notAVideo)
            XCTAssertEqual(error.message, "Das ist keine Videodatei.")
        }
    }

    func testCodecTheMacCannotDecode() async throws {
        do {
            _ = try await Transcoder(source: fixture("ffv1.mov"), output: out.appendingPathComponent("intermediate.mp4")).run { _ in }
            XCTFail("expected an error")
        } catch let error as DropError {
            XCTAssertEqual(error, .cannotDecodeVideo(codec: "FFV1"))
            XCTAssertEqual(error.message, "Dieses Videoformat (FFV1) kann der Mac nicht lesen.")
        }
    }

    func testCancelLeavesNothing() async throws {
        let job = Transcoder(source: try fixture("prores-proxy-5k.mov"), output: out.appendingPathComponent("intermediate.mp4"))
        job.cancel()
        do {
            _ = try await job.run { _ in }
            XCTFail("expected cancel")
        } catch let error as DropError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    func testCancelWhileRunning() async throws {
        let job = Transcoder(source: try fixture("prores-hq-320x180.mov"), output: out.appendingPathComponent("intermediate.mp4"))
        let task = Task { try await job.run { fraction in if fraction > 0.2 { job.cancel() } } }
        do {
            _ = try await task.value
            XCTFail("expected cancel")
        } catch let error as DropError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }
}
