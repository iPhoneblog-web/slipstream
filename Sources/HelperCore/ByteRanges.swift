import Foundation

/// The parts of a file that arrived, as sorted, merged, half-open ranges. The bridge sends
/// slices in any order (the index first), and after a closed tab only what is missing.
public struct ByteRanges: Codable, Equatable, Sendable {
    public private(set) var ranges: [Range<Int64>] = []

    public init(_ ranges: [Range<Int64>] = []) {
        for r in ranges { insert(r) }
    }

    public mutating func insert(_ r: Range<Int64>) {
        guard !r.isEmpty else { return }
        var merged = r
        var kept: [Range<Int64>] = []
        for x in ranges {
            if x.upperBound < merged.lowerBound || x.lowerBound > merged.upperBound {
                kept.append(x)
            } else {
                merged = min(x.lowerBound, merged.lowerBound)..<max(x.upperBound, merged.upperBound)
            }
        }
        kept.append(merged)
        ranges = kept.sorted { $0.lowerBound < $1.lowerBound }
    }

    public var count: Int64 { ranges.reduce(0) { $0 + Int64($1.count) } }

    public func covers(_ total: Int64) -> Bool {
        total == 0 || ranges == [0..<total]
    }

    /// What is still missing of a file of `total` bytes.
    public func missing(_ total: Int64) -> [Range<Int64>] {
        var gaps: [Range<Int64>] = []
        var at: Int64 = 0
        for r in ranges where r.lowerBound < total {
            if r.lowerBound > at { gaps.append(at..<r.lowerBound) }
            at = max(at, r.upperBound)
        }
        if at < total { gaps.append(at..<total) }
        return gaps
    }
}
