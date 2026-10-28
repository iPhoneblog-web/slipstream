import AppKit
import Combine
import HelperCore

/// What the menu bar shows, as finished text. In 1.1.0 the menu read the model directly: the
/// worker's `job` event once a second, presence answers and the extension's last contact each
/// changed a published value, SwiftUI rebuilt the menu, and an open submenu ("Pause", "CPU …")
/// closed and opened again about once a second. Now the menu reads this mirror, which changes
/// only when a line's text changes (times to the minute), and never while a menu is open: what
/// changed meanwhile is applied when the menu closes.
@MainActor
final class MenuMirror: ObservableObject {
    enum Icon: Equatable {
        case idle, paused, down
        case progress(Int)
    }

    struct Lines: Equatable {
        var configured = false
        var state = ""
        var problem: String?
        /// A running job's line and its submenu (Thorsten, 2026-10-28: "Use Sub-menues for
        /// details").
        struct Job: Equatable, Identifiable {
            var id: String
            var title: String
            /// The end of `title`, " · 12 %", which stays when the title is cut.
            var share: String
            var details: [String]
        }
        var jobs: [Job] = []
        /// "Letzte Ereignisse": the last ten results, newest first.
        var results: [String] = []
        var today = ""
        var points: String?
        var pausedUntil: String?
        /// The top level's word, "Verbindung: verbunden", and its submenu's lines.
        var connectionWord = ""
        var connection = ""
        /// Why the encoder stopped, under "Encoder gestoppt, neuer Versuch …".
        var stopReason: String?
        var extensionLines: [String] = []
        var refused: [String] = []
        var update: String?

        /// Every line the menu shows as text, in submenus too.
        var all: [String] {
            var out = [state]
            if let problem { out.append(problem) }
            for job in jobs {
                out.append(job.title)
                out += job.details
            }
            out += results
            out += [today, connectionWord, connection]
            if let points { out.append(points) }
            if let stopReason { out.append(stopReason) }
            out += extensionLines
            out += refused
            return out
        }
    }

    @Published private(set) var lines = Lines()
    @Published private(set) var icon = Icon.idle

    private weak var model: AppModel?
    private var tracking = false
    private var pending = false
    private var watch: [AnyCancellable] = []

    init(model: AppModel) {
        self.model = model
        // objectWillChange fires before the value changes: read it on the next turn.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &watch)
        let center = NotificationCenter.default
        center.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in self?.tracking = true }
            .store(in: &watch)
        center.publisher(for: NSMenu.didEndTrackingNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.tracking = false
                if self.pending { self.refresh() }
            }
            .store(in: &watch)
        refresh()
    }

    private func refresh() {
        guard let model else { return }
        if tracking {
            pending = true
            return
        }
        pending = false
        let newLines = Self.lines(model)
        if newLines != lines {
            lines = newLines
            for line in newLines.all where MenuLine.fit(line, measure: Self.measure) != line {
                model.logCutLine(line)
            }
        }
        let newIcon = Self.icon(model)
        if newIcon != icon { icon = newIcon }
    }

    static func icon(_ m: AppModel) -> Icon {
        if m.pausedUntil != nil { return .paused }
        if let f = m.proresJob?.fraction ?? m.queueJob?.fraction { return .progress(Int(f * 100)) }
        if m.connection == .down { return .down }
        return .idle
    }

    private static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    /// A line's width in the menu's font.
    static func measure(_ s: String) -> Double {
        Double((s as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width)
    }

    static func lines(_ m: AppModel) -> Lines {
        var l = Lines()
        l.configured = m.site != nil
        if m.pausedUntil != nil {
            l.state = "Pausiert"
        } else if m.proresJob != nil || m.queueJob != nil {
            l.state = "Wandelt um"
        } else if m.workerStopped != nil {
            l.state = "Encoder gestoppt"
        } else {
            switch m.connection {
            case .up: l.state = "Bereit"
            case .down: l.state = "Keine Verbindung zum Encoder"
            case .notPaired, .noWorker: l.state = "Bereit für ProRes"
            }
        }
        l.problem = m.problem
        if let job = m.proresJob {
            let share = " · \(Int(job.fraction * 100)) %"
            l.jobs.append(.init(id: "prores-\(job.uploadId)", title: "Wandelt um: ProRes \(job.name)" + share, share: share,
                                details: ["Datei: \(job.name)", progressLine(fraction: job.fraction, fps: job.fps, speed: job.speed, eta: job.etaS),
                                          "Für das Funkhaus, auf der Media Engine"]))
        }
        for job in m.queueJobs.jobs {
            l.jobs.append(.init(id: job.leaseId ?? job.menuTitle, title: job.menuTitle, share: job.menuShare, details: job.menuDetails))
        }
        l.results = m.results.isEmpty ? ["Noch keine Aufträge"]
            : m.results.map { "\($0.title): \(verdict($0.verdict))\($0.check.map { " (\($0))" } ?? "")" }
        l.today = "Heute fertig: \(m.finishedToday)"
        l.points = m.points?.line
        l.pausedUntil = m.pausedUntil.map(time)
        let last = m.lastAnswer.map { ", letzte Antwort \(time($0))" } ?? ""
        switch m.connection {
        case .notPaired:
            l.connection = "Nicht gekoppelt (nur ProRes)"
            l.connectionWord = "Verbindung: nicht gekoppelt"
        case .noWorker:
            l.connection = "Ohne Worker (nur ProRes)"
            l.connectionWord = "Verbindung: ohne Worker"
        case .down:
            l.connection = "Tunnel getrennt" + last
            l.connectionWord = "Verbindung: getrennt"
        case .up:
            l.connection = "Tunnel verbunden" + last
            l.connectionWord = "Verbindung: verbunden"
        }
        if let reason = m.workerStopped {
            l.connection = "Encoder gestoppt" + (m.workerNextStart.map { ", neuer Versuch \(time($0))" } ?? "")
            // A line of its own, cut to the menu's width; the whole reason is its tooltip, in the
            // log window and in the log file.
            l.stopReason = reason
            l.connectionWord = "Verbindung: Encoder gestoppt"
        }
        if let seen = m.extensionSeen {
            l.extensionLines = ["Safari-Extension: verbunden, zuletzt \(time(seen))"]
        } else {
            l.extensionLines = ["Safari-Extension: noch nicht verbunden",
                                "Funkhaus in Safari öffnen; sonst in Safari erlauben (Einstellungen → Erweiterungen → Slipstream, \(m.site?.host ?? ""))"]
        }
        l.refused = m.refused.map { "Keine \($0.kind)-Aufträge: \($0.reason)" }
        l.update = m.updateAvailable
        return l
    }

    static func verdict(_ v: String) -> String {
        switch v {
        case "accepted": return "angenommen"
        case "rejected": return "abgelehnt"
        case "given_back": return "zurückgegeben"
        default: return v
        }
    }

    /// The share in whole percent, fps and speed to one place, the time left in minutes once it
    /// is over a minute: what changes every second does not change the line every second.
    static func progressLine(fraction: Double, fps: Double?, speed: Double?, eta: Int?) -> String {
        var parts = ["\(Int(fraction * 100)) %"]
        if let fps { parts.append(String(format: "%.0f fps", fps)) }
        if let speed { parts.append(String(format: "%.1f×", speed)) }
        if let eta {
            let rounded = eta > 90 ? (eta + 30) / 60 * 60 : eta
            parts.append("noch \(Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))")
        }
        return parts.joined(separator: " · ")
    }
}
