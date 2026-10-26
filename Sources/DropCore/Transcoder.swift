import AVFoundation
import CoreMedia
import VideoToolbox

/// What a finished job reports.
public struct EncodeResult: Sendable {
    public var output: URL
    public var plan: EncodePlan
    public var sourceCodec: String
    public var sourceDuration: Double
    /// Seconds, of the finished file.
    public var duration: Double
    public var bytes: Int64
    /// The whole file's bits per second, as the server measures it: bytes × 8 ÷ duration.
    public var bitRate: Int
    /// Wall-clock seconds the job took.
    public var elapsed: Double
}

/// One file, ProRes in, the HEVC Main 10 intermediate out (docs/encoding.md). AVAssetReader
/// decodes, AVAssetWriter encodes on the Mac's media engine through VideoToolbox. The finished
/// file is checked before it appears at `output`, and a half-written one never does.
public final class Transcoder: @unchecked Sendable {
    public let source: URL
    /// Where the checked file goes. An older file there is replaced.
    public let output: URL
    /// The CLI uses this to try other bit rates; the app never sets it.
    public var adjustPlan: ((EncodePlan) -> EncodePlan)?

    private let lock = NSLock()
    private var isCancelled = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var ends: PumpEnds?

    public init(source: URL, output: URL) {
        self.source = source
        self.output = output
    }

    public func cancel() {
        lock.lock()
        isCancelled = true
        let reader = self.reader, writer = self.writer, ends = self.ends
        lock.unlock()
        reader?.cancelReading()
        ends?.end(failed: true)
        if writer?.status == .writing { writer?.cancelWriting() }
    }

    private var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return isCancelled
    }

    /// Runs the job. `progress` gets 0…1 from the encoding queue, often; throttle it.
    public func run(progress: @escaping @Sendable (Double) -> Void) async throws -> EncodeResult {
        let started = Date()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Video wird umgewandelt")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        // The source: a video track the Mac can decode, and its first audio track, as the server
        // takes them (video-encode maps 0:v:0 and 0:a:0).
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.load(.tracks)
        } catch {
            throw DropError.notAVideo
        }
        guard !tracks.isEmpty else { throw DropError.notAVideo }
        if (try? await asset.load(.hasProtectedContent)) == true { throw DropError.protected }
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw DropError.noVideoTrack
        }
        let (formats, naturalSize, transform, nominalRate, timeRange, decodable) = try await videoTrack.load(
            .formatDescriptions, .naturalSize, .preferredTransform, .nominalFrameRate, .timeRange, .isDecodable)
        let videoCodec = formats.first.map { Naming.codecName(CMFormatDescriptionGetMediaSubType($0)) } ?? "unbekannt"
        guard decodable, let videoFormat = formats.first else {
            throw DropError.cannotDecodeVideo(codec: videoCodec)
        }
        var audioTrack = tracks.first(where: { $0.mediaType == .audio })
        if let track = audioTrack {
            let (audioFormats, audioDecodable) = try await track.load(.formatDescriptions, .isDecodable)
            if !audioDecodable {
                let codec = audioFormats.first.map { Naming.codecName(CMFormatDescriptionGetMediaSubType($0)) } ?? "unbekannt"
                throw DropError.cannotDecodeAudio(codec: codec)
            }
            if audioFormats.isEmpty { audioTrack = nil }
        }

        var plan = Plan.make(width: Int(naturalSize.width.rounded()), height: Int(naturalSize.height.rounded()),
                             frameRate: Double(nominalRate))
        if let adjust = adjustPlan { plan = adjust(plan) }

        // Where it goes: a temporary directory on the output's volume, then one move.
        let fm = FileManager.default
        let destinationFolder = output.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        } catch {
            throw DropError.destinationUnavailable(path: destinationFolder.path)
        }
        let scratch: URL
        do {
            scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: destinationFolder, create: true)
        } catch {
            throw DropError.destinationUnavailable(path: destinationFolder.path)
        }
        defer { try? fm.removeItem(at: scratch) }
        let temp = scratch.appendingPathComponent(output.lastPathComponent)

        // Reader: 10-bit 4:2:0 frames straight from the decoder, float PCM for the audio.
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw DropError.readFailed(error.localizedDescription) }
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        var audioOut: AVAssetReaderTrackOutput?
        if let track = audioTrack {
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: Self.pcmSettings)
            out.alwaysCopiesSampleData = false
            reader.add(out)
            audioOut = out
        }

        // Writer: HEVC Main 10 at the plan's size and rates, AAC stereo, index at the front.
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: temp, fileType: .mp4) } catch {
            throw DropError.writeFailed(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: Self.compression(plan),
        ]
        if let colour = Self.colourProperties(videoFormat) {
            videoSettings[AVVideoColorPropertiesKey] = colour
        }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.expectsMediaDataInRealTime = false
        videoIn.transform = transform
        guard writer.canAdd(videoIn) else { throw DropError.writeFailed("HEVC-Einstellungen abgelehnt") }
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw DropError.writeFailed("AAC-Einstellungen abgelehnt") }
            writer.add(input)
            audioIn = input
        }

        let cancelledEarly = lock.withLock {
            self.reader = reader
            self.writer = writer
            return isCancelled
        }
        if cancelledEarly { throw DropError.cancelled }

        guard reader.startReading() else { throw Self.readError(reader.error, codec: videoCodec) }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw DropError.writeFailed(writer.error?.localizedDescription ?? "unbekannt")
        }
        let start = timeRange.start
        let length = max(timeRange.duration.seconds, 0.001)
        writer.startSession(atSourceTime: start)

        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                // Both pumps end, or one fails: a failed append can leave the other input never
                // ready again, so the first failure ends the wait.
                let ends = PumpEnds(count: audioIn == nil ? 1 : 2) { done.resume() }
                self.lock.lock()
                self.ends = ends
                self.lock.unlock()
                pump(videoOut, into: videoIn, label: "video", ends: ends) { time in
                    progress(min(max((time - start).seconds / length, 0), 1))
                }
                if let audioOut, let audioIn {
                    pump(audioOut, into: audioIn, label: "audio", ends: ends, onSample: nil)
                }
            }
        } onCancel: {
            self.cancel()
        }

        if cancelled {
            if writer.status == .writing { writer.cancelWriting() }
            throw DropError.cancelled
        }
        if reader.status == .failed {
            if writer.status == .writing { writer.cancelWriting() }
            throw Self.readError(reader.error, codec: videoCodec)
        }
        if writer.status != .writing {
            reader.cancelReading()
            throw DropError.writeFailed(writer.error?.localizedDescription ?? "Status \(writer.status.rawValue)")
        }
        writer.endSession(atSourceTime: timeRange.end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw DropError.writeFailed(writer.error?.localizedDescription ?? "Status \(writer.status.rawValue)")
        }
        progress(1)

        let checked = try await Self.check(temp, expectedDuration: timeRange.duration.seconds,
                                           frameRate: plan.frameRate, hasAudio: audioIn != nil)

        let final = output
        do {
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: temp, to: final)
        } catch {
            throw DropError.writeFailed(error.localizedDescription)
        }
        let bytes = (try? fm.attributesOfItem(atPath: final.path)[.size] as? Int64) ?? checked.bytes
        return EncodeResult(output: final, plan: plan, sourceCodec: videoCodec,
                            sourceDuration: timeRange.duration.seconds, duration: checked.duration,
                            bytes: bytes, bitRate: Int((Double(bytes) * 8 / checked.duration).rounded()),
                            elapsed: Date().timeIntervalSince(started))
    }

    // MARK: - Settings

    static func compression(_ plan: EncodePlan) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            AVVideoAverageBitRateKey: plan.averageBitRate,
            AVVideoExpectedSourceFrameRateKey: plan.frameRate,
            AVVideoMaxKeyFrameIntervalDurationKey: EncodePlan.keyFrameInterval,
            AVVideoAllowFrameReorderingKey: true,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: false,
        ]
        if let peak = plan.peakBitRate {
            settings[kVTCompressionPropertyKey_DataRateLimits as String] = [Double(peak) / 8 * plan.peakWindow, plan.peakWindow]
        }
        return settings
    }

    /// The source's colour tags, all three or none. Final Cut writes them (Rec. 709: 1-1-1).
    static func colourProperties(_ format: CMFormatDescription) -> [String: Any]? {
        func ext(_ key: CFString) -> String? {
            CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
        }
        guard let primaries = ext(kCMFormatDescriptionExtension_ColorPrimaries),
              let transfer = ext(kCMFormatDescriptionExtension_TransferFunction),
              let matrix = ext(kCMFormatDescriptionExtension_YCbCrMatrix) else { return nil }
        return [AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: matrix]
    }

    static var stereoLayout: Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    static var pcmSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: EncodePlan.audioSampleRate,
         AVNumberOfChannelsKey: 2, AVChannelLayoutKey: stereoLayout,
         AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
         AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    }

    static var aacSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: EncodePlan.audioSampleRate,
         AVNumberOfChannelsKey: 2, AVChannelLayoutKey: stereoLayout,
         AVEncoderBitRateKey: EncodePlan.audioBitRate]
    }

    static func readError(_ error: Error?, codec: String) -> DropError {
        guard let error = error as NSError? else { return .readFailed("unbekannt") }
        if error.domain == AVFoundationErrorDomain,
           [AVError.decoderNotFound.rawValue, AVError.decodeFailed.rawValue,
            AVError.fileFormatNotRecognized.rawValue].contains(error.code) {
            return .cannotDecodeVideo(codec: codec)
        }
        return .readFailed(error.localizedDescription)
    }

    // MARK: - The check

    struct Checked { var duration: Double; var bytes: Int64 }

    /// The finished file, read back before it may appear: playable by AVFoundation (what QuickTime
    /// uses), HEVC tagged hvc1, Main 10, the index in front, the source's length within a frame,
    /// and audio where the source had some.
    static func check(_ url: URL, expectedDuration: Double, frameRate: Double, hasAudio: Bool) async throws -> Checked {
        guard (try? MP4Boxes.isFastStart(url)) == true else {
            throw DropError.checkFailed("Index steht nicht vorn")
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (tracks, playable) = try await asset.load(.tracks, .isPlayable)
        guard playable else { throw DropError.checkFailed("QuickTime kann sie nicht abspielen") }
        guard let video = tracks.first(where: { $0.mediaType == .video }),
              let format = try await video.load(.formatDescriptions).first else {
            throw DropError.checkFailed("keine Videospur")
        }
        let tag = Naming.fourCC(CMFormatDescriptionGetMediaSubType(format))
        guard tag == "hvc1" else { throw DropError.checkFailed("Codec \(tag) statt hvc1") }
        guard hevcProfile(format) == 2 else { throw DropError.checkFailed("nicht HEVC Main 10") }
        if hasAudio, !tracks.contains(where: { $0.mediaType == .audio }) {
            throw DropError.checkFailed("Ton fehlt")
        }
        let duration = try await video.load(.timeRange).duration.seconds
        let frame = 1 / max(frameRate, 1)
        guard abs(duration - expectedDuration) <= frame + 0.001 else {
            throw DropError.checkFailed(String(format: "Länge %.3f s statt %.3f s", duration, expectedDuration))
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return Checked(duration: try await asset.load(.duration).seconds, bytes: bytes)
    }

    /// general_profile_idc from the hvcC box: 1 Main, 2 Main 10.
    static func hevcProfile(_ format: CMFormatDescription) -> Int? {
        guard let atoms = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
              let hvcC = atoms["hvcC"] as? Data, hvcC.count > 1 else { return nil }
        return Int(hvcC[hvcC.startIndex + 1] & 0x1f)
    }
}

/// Counts the pumps down and calls `done` once: when all have run dry, or at the first failure.
private final class PumpEnds: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var done: (() -> Void)?

    init(count: Int, done: @escaping () -> Void) {
        remaining = count
        self.done = done
    }

    func end(failed: Bool) {
        lock.lock()
        remaining -= 1
        let call = (failed || remaining == 0) ? done : nil
        if call != nil { done = nil }
        lock.unlock()
        call?()
    }
}

/// Moves samples from a reader output into a writer input until the output runs dry or an
/// append fails.
private func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String,
                  ends: PumpEnds, onSample: ((CMTime) -> Void)?) {
    let queue = DispatchQueue(label: "slipstream.\(label)")
    var finished = false
    input.requestMediaDataWhenReady(on: queue) {
        guard !finished else { return }
        while input.isReadyForMoreMediaData {
            guard let sample = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                finished = true
                ends.end(failed: false)
                return
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if !input.append(sample) {
                finished = true
                ends.end(failed: true)
                return
            }
            onSample?(time)
        }
    }
}
