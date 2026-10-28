import Foundation

/// The queue jobs the worker runs right now, in the order they started: from encode-queue
/// v0.2.14 one per slot, normal and high-priority side by side. The worker sends each job's `job`
/// event about once a second while it runs, and `idle` only once none is left; a job that ends
/// beside another says nothing more unless its result comes at once (one still being checked waits
/// for its verdict). So a job not heard of for `stale` seconds is gone.
public struct RunningJobs: Equatable, Sendable {
    public static let stale: TimeInterval = 15

    public private(set) var jobs: [WorkerJob] = []
    private var heard: [String: Date] = [:]

    public init() {}

    public var isEmpty: Bool { jobs.isEmpty }

    /// A `job` event: a new job goes last, a known one keeps its place.
    public mutating func update(_ job: WorkerJob, at now: Date = Date()) {
        let lease = job.leaseId ?? ""
        heard[lease] = now
        if let i = jobs.firstIndex(where: { ($0.leaseId ?? "") == lease }) {
            jobs[i] = job
        } else {
            jobs.append(job)
        }
    }

    /// The job's result came: it is over.
    public mutating func end(lease: String) {
        jobs.removeAll { $0.leaseId == lease }
        heard[lease] = nil
    }

    /// `idle`: no job runs.
    public mutating func clear() {
        jobs = []
        heard = [:]
    }

    /// Drops the jobs not heard of for `stale` seconds; true when one went.
    @discardableResult
    public mutating func expire(now: Date = Date()) -> Bool {
        let gone = Set(heard.filter { now.timeIntervalSince($0.value) >= Self.stale }.keys)
        guard !gone.isEmpty else { return false }
        jobs.removeAll { gone.contains($0.leaseId ?? "") }
        for lease in gone { heard[lease] = nil }
        return true
    }
}
