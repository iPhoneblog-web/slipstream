import Foundation

/// The menu's quick choice of how many CPU threads the worker may use: all of the Mac's cores,
/// three quarters, half, a quarter. Settings has the exact number.
public struct CPUChoice: Equatable, Sendable, Identifiable {
    public var label: String
    public var threads: Int
    public var id: Int { threads }

    /// The choices for a Mac with `cores` cores, largest first, each at least one thread and
    /// none twice. A `current` value that is none of them is added, so the menu can tick it.
    /// With `efficiencyCores` (and the slowdown to show), "Nur Effizienzkerne" comes last, tagged
    /// `efficiencyTag`.
    public static func options(cores: Int, current: Int? = nil, efficiencyCores: Int = 0, slowdown: Int? = nil) -> [CPUChoice] {
        let n = max(cores, 1)
        let all: [(String, Int)] = [("Alle", n), ("¾", (n * 3 + 2) / 4), ("½", (n + 1) / 2), ("¼", (n + 3) / 4)]
        var seen = Set<Int>()
        var out: [CPUChoice] = []
        for (name, t) in all where seen.insert(max(t, 1)).inserted {
            out.append(CPUChoice(label: "\(name) (\(max(t, 1)))", threads: max(t, 1)))
        }
        if let c = current, (1...n).contains(c), !seen.contains(c) {
            out.append(CPUChoice(label: "Eigene (\(c))", threads: c))
            out.sort { $0.threads > $1.threads }
        }
        if efficiencyCores > 0 {
            out.append(CPUChoice(label: "Nur Effizienzkerne (\(efficiencyCores)\(slowdown.map { ", etwa \($0)× langsamer" } ?? ""))",
                                 threads: efficiencyTag))
        }
        return out
    }
}

extension CPUChoice {
    /// The menu's line for the CPU limit: what is in effect, the worker's word once it has said
    /// it (encode-queue v0.2.17), else the setting; ", gedrosselt" while a running job's tool,
    /// started with more threads, is held to it.
    public static func menuTitle(setting: Int, cores: Int, inEffect: WorkerEvent.Limits?, efficiencyOnly: Bool = false) -> String {
        if let e = inEffect?.efficiency.flatMap(Efficiency.init(rawValue:)) ?? (inEffect == nil && efficiencyOnly ? .all : nil), e == .all {
            return "CPU für den Encoder: nur Effizienzkerne"
        }
        let threads = inEffect?.threads ?? setting, of = inEffect?.cores ?? cores
        // Throttled, "Kernen" gives way to "gedrosselt", so the line stays as wide as the menu;
        // the submenu says "Laufender Auftrag gedrosselt".
        return (inEffect?.throttled ?? 0) > 0 ? "CPU für den Encoder: \(threads) von \(of), gedrosselt"
            : "CPU für den Encoder: \(threads) von \(of) Kernen"
    }

    /// The tag of "Nur Effizienzkerne" among the core counts.
    public static let efficiencyTag = -1

    /// An efficiency core's x265 throughput against a performance core's, the worker's
    /// effPerfRatio (Mac Studio, M2 Max, 2026-10-28: x265 slower took 10.6 times as long there,
    /// 297.8 s against 28.2 s, three runs each).
    public static let effPerfRatio = 0.21

    /// What the efficiency cores mean beside other work: macOS gives a background job what the Mac
    /// leaves over. On the Mac Studio, at load averages of 80 to 140, an x265 encode in the background
    /// got 0.07 cores over a minute and no frame (encode-queue's README, "The efficiency cores").
    public static let efficiencyNote = "Läuft fast nur, wenn der Mac nichts anderes tut"

    /// The same in the CPU submenu, in two lines as wide as the menu.
    public static let efficiencyNoteLines = ["Effizienzkerne: läuft fast nur,", "wenn der Mac nichts anderes tut"]

    /// Settings' line under the switches: the slowdown and what it means.
    public static func efficiencyCaption(slowdown: Int?) -> String {
        (slowdown.map { "Auf den Effizienzkernen etwa \($0)-mal langsamer. " } ?? "") + efficiencyNote + "."
    }

    /// How many times slower a job runs on the efficiency cores only, (p + e·r) / (e·r), whole;
    /// nil on a Mac with one kind of core.
    public static func efficiencySlowdown(perf: Int, eff: Int) -> Int? {
        guard perf > 0, eff > 0 else { return nil }
        let e = Double(eff) * effPerfRatio
        return Int(((Double(perf) + e) / e).rounded())
    }
}

/// Which jobs run on the efficiency cores only (encode-queue v0.2.18): macOS's background QoS
/// keeps their tools there, and the performance cores stay with the person at the Mac. `archive`:
/// jobs of priority archive, which nobody waits for.
public enum Efficiency: String, Codable, Equatable, Sendable {
    case off, all, archive

    public init(only: Bool, archive: Bool) {
        self = only ? .all : (archive ? .archive : .off)
    }
}
