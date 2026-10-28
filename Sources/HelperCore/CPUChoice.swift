import Foundation

/// The menu's quick choice of how many CPU threads the worker may use: all of the Mac's cores,
/// three quarters, half, a quarter. Settings has the exact number.
public struct CPUChoice: Equatable, Sendable, Identifiable {
    public var label: String
    public var threads: Int
    public var id: Int { threads }

    /// The choices for a Mac with `cores` cores, largest first, each at least one thread and
    /// none twice. A `current` value that is none of them is added, so the menu can tick it.
    public static func options(cores: Int, current: Int? = nil) -> [CPUChoice] {
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
        return out
    }
}

extension CPUChoice {
    /// The menu's line for the CPU limit: what is in effect, the worker's word once it has said
    /// it (encode-queue v0.2.17), else the setting; "(laufender Auftrag gedrosselt)" while a
    /// running job's tool, started with more threads, is held to it.
    public static func menuTitle(setting: Int, cores: Int, inEffect: WorkerEvent.Limits?) -> String {
        let title = "CPU für den Encoder: \(inEffect?.threads ?? setting) von \(inEffect?.cores ?? cores) Kernen"
        return (inEffect?.throttled ?? 0) > 0 ? title + " (laufender Auftrag gedrosselt)" : title
    }
}
