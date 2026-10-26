import AVFoundation
import DropCore
import Foundation

/// The intermediate, as the page reads it at `ready`.
public struct IntermediateInfo: Codable, Equatable, Sendable {
    public var size: Int64
    public var durationS: Double
    public var width: Int
    public var height: Int
    public var bitRate: Int
    public var codec: String

    public init(size: Int64, durationS: Double, width: Int, height: Int, bitRate: Int, codec: String) {
        self.size = size
        self.durationS = durationS
        self.width = width
        self.height = height
        self.bitRate = bitRate
        self.codec = codec
    }
}

/// An error the page acts on by `code` (docs/extension-protocol.md, "Error codes"); the message
/// is German, for the user.
public struct JobError: Error, Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    /// The HTTP status the loopback answers with.
    public var status: Int {
        switch code {
        case "bad-request": return 400
        case "unknown-job": return 404
        case "file-mismatch", "not-ready", "not-paired": return 409
        case "disk-full": return 507
        default: return 500
        }
    }

    public static func from(_ error: Error) -> JobError {
        if let e = error as? JobError { return e }
        if let e = error as? DropError { return JobError(e.code, e.message) }
        let ns = error as NSError
        if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) {
            return JobError("disk-full", "Auf dem Mac ist kein Platz mehr frei.")
        }
        return JobError("internal", ns.localizedDescription)
    }
}

public struct EncodeProgress: Sendable {
    public var fraction: Double
    public var fps: Double?
    public var speed: Double?

    public init(fraction: Double, fps: Double? = nil, speed: Double? = nil) {
        self.fraction = fraction
        self.fps = fps
        self.speed = speed
    }
}

/// One ProRes file for one upload (docs/extension-protocol.md, "The job").
public struct JobStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case receiving, queued, encoding, checking, ready, failed
    }

    public var uploadId: String
    public var name: String
    public var size: Int64
    public var lastModified: Int64?
    public var phase: Phase
    public var received: Int64
    public var fraction: Double
    public var fps: Double?
    public var speed: Double?
    public var etaS: Int?
    public var intermediate: IntermediateInfo?
    public var error: JobError?
    public var createdAt: Date
    public var updatedAt: Date
    /// Only in the loopback's answers: the byte ranges still to send.
    public var missing: [Range<Int64>]?
}

/// Encodes a source into the intermediate at `output` and reports its progress.
public typealias IntermediateEncoder = @Sendable (_ source: URL, _ output: URL,
                                                  _ progress: @escaping @Sendable (EncodeProgress) -> Void) async throws -> IntermediateInfo

/// The ProRes jobs (ADR-0007 §7): one directory per upload under `root`, with the source as it
/// arrives, the intermediate, and `job.json`. One encode at a time. Everything survives a quit:
/// the page resumes by upload id.
public actor ProResJobs {
    public static let maxSlice = 64 * 1024 * 1024
    public static let maxAge: TimeInterval = 7 * 24 * 3600

    private struct Record: Codable {
        var status: JobStatus
        var ranges: ByteRanges
        var sourceName: String
    }

    public let root: URL
    private let encoder: IntermediateEncoder
    private let now: @Sendable () -> Date
    private var records: [String: Record] = [:]
    private var waiting: [String] = []
    private var running: (id: String, task: Task<Void, Never>, started: Date)?
    private var onChange: (@Sendable (JobStatus) -> Void)?

    public init(root: URL, encoder: @escaping IntermediateEncoder = ProResJobs.videoToolbox,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.encoder = encoder
        self.now = now
    }

    /// The menu bar's view of the jobs; called on every change, progress included.
    public func observe(_ callback: @escaping @Sendable (JobStatus) -> Void) {
        onChange = callback
    }

    /// Reads what an earlier run left: a job that was encoding starts again from the beginning.
    public func load() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for dir in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("job.json")),
                  var record = try? JSONCoding.decoder.decode(Record.self, from: data) else { continue }
            if [.encoding, .checking, .queued].contains(record.status.phase) {
                record.status.phase = .queued
                record.status.fraction = 0
                waiting.append(record.status.uploadId)
            }
            records[record.status.uploadId] = record
        }
        startNext()
    }

    public static func isValidID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    private func sourceURL(_ r: Record) -> URL { dir(r.status.uploadId).appendingPathComponent(r.sourceName) }
    private func intermediateURL(_ id: String) -> URL { dir(id).appendingPathComponent("intermediate.mp4") }

    private func record(_ id: String) throws -> Record {
        guard Self.isValidID(id) else { throw JobError("bad-request", "Ungültige Upload-ID.") }
        guard let r = records[id] else { throw JobError("unknown-job", "Slipstream kennt diesen Upload nicht.") }
        return r
    }

    private func save(_ r: Record) throws {
        records[r.status.uploadId] = r
        try JSONCoding.encoder.encode(r).write(to: dir(r.status.uploadId).appendingPathComponent("job.json"),
                                              options: .atomic)
        onChange?(r.status)
    }

    private func withMissing(_ r: Record) -> JobStatus {
        var s = r.status
        s.missing = r.ranges.missing(s.size)
        return s
    }

    // MARK: - The page's calls

    /// Creates the job, or returns the one under that id. Another file under the same id is
    /// `file-mismatch`.
    public func open(id: String, name: String, size: Int64, lastModified: Int64?) throws -> JobStatus {
        guard Self.isValidID(id), size > 0, !name.isEmpty else { throw JobError("bad-request", "Upload-ID, Name oder Größe fehlt.") }
        if let r = records[id] {
            guard r.status.name == name, r.status.size == size else {
                throw JobError("file-mismatch", "Unter diesem Upload liegt eine andere Datei.")
            }
            return withMissing(r)
        }
        let ext = (name as NSString).pathExtension.lowercased()
        let sourceName = "source." + (["mov", "mp4", "m4v", "qt"].contains(ext) ? ext : "mov")
        try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
        // Sparse: the slices land at their offsets in any order.
        let url = dir(id).appendingPathComponent(sourceName)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw JobError("internal", "Kopie konnte nicht angelegt werden.")
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        let t = now()
        let r = Record(status: JobStatus(uploadId: id, name: name, size: size, lastModified: lastModified,
                                         phase: .receiving, received: 0, fraction: 0, createdAt: t, updatedAt: t),
                       ranges: ByteRanges(), sourceName: sourceName)
        try save(r)
        return withMissing(r)
    }

    /// One slice of the source. When the last byte arrives the job queues for its encode.
    public func receive(id: String, range: Range<Int64>, total: Int64, data: Data) throws -> JobStatus {
        var r = try record(id)
        guard total == r.status.size else { throw JobError("file-mismatch", "Die Größe passt nicht zum Upload.") }
        guard Int64(data.count) == range.count, data.count <= Self.maxSlice, range.upperBound <= total else {
            throw JobError("bad-request", "Der Abschnitt passt nicht.")
        }
        guard r.status.phase == .receiving else { return withMissing(r) }
        do {
            let handle = try FileHandle(forWritingTo: sourceURL(r))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(range.lowerBound))
            try handle.write(contentsOf: data)
        } catch {
            throw JobError.from(error)
        }
        r.ranges.insert(range)
        r.status.received = r.ranges.count
        r.status.updatedAt = now()
        if r.ranges.covers(total) {
            r.status.phase = .queued
            waiting.append(id)
        }
        try save(r)
        startNext()
        return withMissing(r)
    }

    public func status(id: String) throws -> JobStatus { withMissing(try record(id)) }

    public func list() -> [JobStatus] {
        records.values.map { withMissing($0) }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Up to 64 MiB of the intermediate, and its whole size.
    public func readIntermediate(id: String, range: Range<Int64>) throws -> (Data, Int64) {
        let r = try record(id)
        guard r.status.phase == .ready, let info = r.status.intermediate else {
            throw JobError("not-ready", "Die Datei ist noch nicht fertig.")
        }
        guard range.count <= Self.maxSlice, range.lowerBound < info.size else {
            throw JobError("bad-request", "Der Bereich passt nicht.")
        }
        let handle = try FileHandle(forReadingFrom: intermediateURL(id))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        let data = try handle.read(upToCount: Int(min(range.upperBound, info.size) - range.lowerBound)) ?? Data()
        return (data, info.size)
    }

    public func intermediatePath(id: String) throws -> URL {
        _ = try record(id)
        return intermediateURL(id)
    }

    /// `finish` after the upload, `cancel` before: either way both files go.
    public func delete(id: String) throws {
        _ = try record(id)
        if running?.id == id {
            running?.task.cancel()
            running = nil
        }
        waiting.removeAll { $0 == id }
        records[id] = nil
        try? FileManager.default.removeItem(at: dir(id))
        startNext()
    }

    /// Deletes every job not touched for `maxAge`, except the one encoding.
    @discardableResult
    public func cleanUp() -> [String] {
        let limit = now().addingTimeInterval(-Self.maxAge)
        let old = records.values.filter { $0.status.updatedAt < limit && $0.status.uploadId != running?.id }
            .map(\.status.uploadId)
        for id in old { try? delete(id: id) }
        return old
    }

    /// The encode running now, for the menu bar.
    public func current() -> JobStatus? { running.flatMap { records[$0.id]?.status } }

    // MARK: - The encode

    private func startNext() {
        guard running == nil, let id = waiting.first, let r = records[id] else { return }
        waiting.removeFirst()
        let source = sourceURL(r), output = intermediateURL(id), encoder = self.encoder
        let task = Task { [weak self] in
            do {
                let info = try await encoder(source, output) { [weak self] p in
                    Task { await self?.progress(id: id, p) }
                }
                await self?.finished(id: id, result: .success(info))
            } catch {
                await self?.finished(id: id, result: .failure(JobError.from(error)))
            }
        }
        running = (id, task, now())
        var started = r
        started.status.phase = .encoding
        started.status.fraction = 0
        started.status.error = nil
        started.status.updatedAt = now()
        try? save(started)
    }

    private func progress(id: String, _ p: EncodeProgress) {
        guard let run = running, run.id == id, var r = records[id], r.status.phase == .encoding || r.status.phase == .checking else { return }
        r.status.fraction = min(max(p.fraction, 0), 1)
        r.status.fps = p.fps
        r.status.speed = p.speed
        let elapsed = now().timeIntervalSince(run.started)
        r.status.etaS = p.fraction > 0.01 ? Int((elapsed * (1 - p.fraction) / p.fraction).rounded()) : nil
        if p.fraction >= 1 { r.status.phase = .checking }
        r.status.updatedAt = now()
        records[id] = r
        onChange?(r.status)
    }

    private func finished(id: String, result: Result<IntermediateInfo, JobError>) {
        guard running?.id == id else { return }
        running = nil
        if var r = records[id] {
            switch result {
            case .success(let info):
                r.status.phase = .ready
                r.status.fraction = 1
                r.status.intermediate = info
            case .failure(let error):
                r.status.phase = .failed
                r.status.error = error
            }
            r.status.etaS = nil
            r.status.updatedAt = now()
            try? save(r)
        }
        startNext()
    }

    // MARK: - VideoToolbox

    /// The real encode: DropCore's Transcoder, with frames per second and speed worked out from
    /// the source's length and frame rate.
    public static let videoToolbox: IntermediateEncoder = { source, output, progress in
        let asset = AVURLAsset(url: source)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        var nominal = 0.0
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            nominal = Double((try? await track.load(.nominalFrameRate)) ?? 0)
        }
        let rate = nominal
        let started = Date()
        let throttle = Throttle()
        let result = try await Transcoder(source: source, output: output).run { fraction in
            guard throttle.pass(fraction) else { return }
            let elapsed = max(Date().timeIntervalSince(started), 0.001)
            let media = fraction * duration
            progress(EncodeProgress(fraction: fraction, fps: rate > 0 ? media * rate / elapsed : nil,
                                    speed: duration > 0 ? media / elapsed : nil))
        }
        return IntermediateInfo(size: result.bytes, durationS: result.duration, width: result.plan.width,
                                height: result.plan.height, bitRate: result.bitRate, codec: "hvc1")
    }
}

/// Lets a progress value through four times a second, and always the last.
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func pass(_ fraction: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let t = Date()
        guard fraction >= 1 || t.timeIntervalSince(last) >= 0.25 else { return false }
        last = t
        return true
    }
}
