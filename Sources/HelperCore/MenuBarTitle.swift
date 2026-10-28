import Darwin
import Foundation

/// What the menu bar shows beside the icon (Thorsten, 2026-10-28: "The 10% in the trayicon... not
/// sure if that is usefull. Maybe give the user the option to select what should be displayed
/// there."). Any of these, always in this order; none checked: the icon alone. The default is the
/// progress, which shows only while something encodes, so an idle Mac shows the icon alone.
public enum MenuBarItem: String, CaseIterable, Codable, Sendable, Identifiable {
    case status, progress, eta, fps, cores, cpu, points

    public var id: String { rawValue }

    /// The checkbox's label (Einstellungen → Menüleiste, "In der Menüleiste zeigen").
    public var label: String {
        switch self {
        case .status: return "Status (Pause)"
        case .progress: return "Fortschritt %"
        case .eta: return "Restzeit"
        case .fps: return "FPS"
        case .cores: return "Kerne (genutzt/erlaubt)"
        case .cpu: return "CPU % des Encoders"
        case .points: return "Punkte heute"
        }
    }
}

/// The checked items, kept in the defaults as their names, comma-separated ("" none).
public struct MenuBarItems: Equatable, Sendable, RawRepresentable {
    public var items: Set<MenuBarItem>

    public init(_ items: Set<MenuBarItem>) { self.items = items }

    /// Unknown names are dropped, so a later version's item does not break an earlier one.
    public init?(rawValue: String) {
        items = Set(rawValue.split(separator: ",").compactMap { MenuBarItem(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
    }

    public var rawValue: String { MenuBarItem.allCases.filter(items.contains).map(\.rawValue).joined(separator: ",") }

    public static let key = "menuBarItems"
    public static let standard = MenuBarItems([.progress])

    /// The setting in `defaults`, the standard one before it was ever set.
    public static func load(from defaults: UserDefaults) -> MenuBarItems {
        defaults.string(forKey: key).flatMap(MenuBarItems.init(rawValue:)) ?? standard
    }

    public func save(to defaults: UserDefaults) { defaults.set(rawValue, forKey: Self.key) }

    public func with(_ item: MenuBarItem, _ on: Bool) -> MenuBarItems {
        var copy = self
        if on { copy.items.insert(item) } else { copy.items.remove(item) }
        return copy
    }
}

/// What the items are made of, now.
public struct MenuBarState: Equatable, Sendable {
    public var paused = false
    /// The first running job's share, time left and frames per second.
    public var fraction: Double?
    public var etaS: Int?
    public var fps: Double?
    /// The cores the worker and its tools keep busy (ProcessCPU), and the limit it may use.
    public var coresBusy: Double?
    public var coresAllowed: Int?
    /// This Mac's points today, from the queue.
    public var points: Double?

    public init(paused: Bool = false, fraction: Double? = nil, etaS: Int? = nil, fps: Double? = nil,
                coresBusy: Double? = nil, coresAllowed: Int? = nil, points: Double? = nil) {
        (self.paused, self.fraction, self.etaS, self.fps) = (paused, fraction, etaS, fps)
        (self.coresBusy, self.coresAllowed, self.points) = (coresBusy, coresAllowed, points)
    }
}

public enum MenuBarTitle {
    /// Between two items: a dot in thin spaces.
    public static let separator = "\u{2009}·\u{2009}"
    /// The most the text takes beside the icon; a longer one ends in "…".
    public static let width = 150.0

    /// The text beside the icon; "" for the icon alone. An item without a value now (no job, no
    /// points yet) is left out.
    public static func text(_ items: MenuBarItems, _ s: MenuBarState, width: Double = width, measure: (String) -> Double) -> String {
        let thin = "\u{2009}"
        var parts: [String] = []
        for item in MenuBarItem.allCases where items.items.contains(item) {
            switch item {
            case .status:
                if s.paused { parts.append("Pause") }
            case .progress:
                if let f = s.fraction { parts.append("\(Int(min(max(f, 0), 1) * 100))\(thin)%") }
            case .eta:
                if let e = s.etaS, e > 0 { parts.append(eta(e)) }
            case .fps:
                if let f = s.fps, f > 0 { parts.append(decimal(f, digits: f < 10 ? 1 : 0) + "\(thin)fps") }
            case .cores:
                if let b = s.coresBusy, let a = s.coresAllowed { parts.append("\(Int(b.rounded()))/\(a)") }
            case .cpu:
                if let b = s.coresBusy { parts.append("CPU\(thin)\(Int((b * 100).rounded()))\(thin)%") }
            case .points:
                if let p = s.points { parts.append(grouped(Int(max(p, 0).rounded())) + "\(thin)P") }
            }
        }
        return fit(parts, width: width, measure: measure)
    }

    /// The items as they fit `width`: whole items from the end go first, and "…" says so; a first
    /// item too long alone keeps its start.
    static func fit(_ parts: [String], width: Double, measure: (String) -> Double) -> String {
        let all = parts.joined(separator: separator)
        if measure(all) <= width { return all }
        let more = "\u{2009}…"
        for n in stride(from: parts.count - 1, through: 1, by: -1) {
            let text = parts.prefix(n).joined(separator: separator) + more
            if measure(text) <= width { return text }
        }
        var first = Array(parts.first ?? "")
        while !first.isEmpty && measure(String(first) + "…") > width { first.removeLast() }
        return String(first) + "…"
    }

    /// "40 s", "12 min", "1:05 h".
    static func eta(_ s: Int) -> String {
        let thin = "\u{2009}"
        switch s {
        case ..<60: return "\(s)\(thin)s"
        case ..<3600: return "\((s + 30) / 60)\(thin)min"
        default:
            let m = (s + 30) / 60
            return String(format: "%d:%02d", m / 60, m % 60) + "\(thin)h"
        }
    }

    static func decimal(_ v: Double, digits: Int) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "de_DE")))
    }

    static func grouped(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic).locale(Locale(identifier: "de_DE")))
    }
}

/// The CPU the worker and the tools it started use (Kerne, CPU %): their CPU time from
/// proc_pid_rusage, over the wall time between two samples. Its tools run in process groups of
/// their own, so the sample walks the worker's children rather than its group.
public final class ProcessCPU {
    private var last: (at: Double, seconds: Double)?
    private let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    public init() {}

    /// The cores pid and the processes below it kept busy since the last sample; nil for the
    /// first sample, or when pid is gone.
    public func sample(_ pid: pid_t, now: Double = ProcessInfo.processInfo.systemUptime) -> Double? {
        guard let s = treeSeconds(pid) else {
            last = nil
            return nil
        }
        defer { last = (now, s) }
        guard let last, now > last.at, s >= last.seconds else { return nil }
        return (s - last.seconds) / (now - last.at)
    }

    /// The CPU time of pid and every process below it, in seconds; nil when pid is gone.
    public func treeSeconds(_ pid: pid_t) -> Double? {
        guard let own = seconds(pid) else { return nil }
        var total = own
        var stack = children(pid)
        while let p = stack.popLast() {
            total += seconds(p) ?? 0 // gone since the list
            stack += children(p)
        }
        return total
    }

    private func seconds(_ pid: pid_t) -> Double? {
        var usage = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &usage) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard r == 0 else { return nil }
        return Double(usage.ri_user_time + usage.ri_system_time) * timebase / 1e9
    }

    private func children(_ pid: pid_t) -> [pid_t] {
        let n = proc_listchildpids(pid, nil, 0)
        guard n > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(n) + 8)
        let got = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return got > 0 ? Array(buf.prefix(Int(got))).filter { $0 > 0 } : []
    }
}
