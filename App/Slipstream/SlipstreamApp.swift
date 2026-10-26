import AppKit
import HelperCore
import SwiftUI

@main
struct SlipstreamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            MenuIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: delegate.model)
        }

        Window("Protokoll", id: "log") {
            LogView(model: delegate.model)
        }
        .defaultSize(width: 720, height: 420)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    /// Quit while encoding asks first, and gives the job back (ADR-0007 §9).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.quitting { return .terminateNow }
        if model.isBusy {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Slipstream arbeitet gerade."
            alert.informativeText = model.queueJob != nil
                ? "Beim Beenden gibt Slipstream den Auftrag an die Warteschlange zurück; ein anderer Worker beginnt ihn neu."
                : "Die ProRes-Umwandlung beginnt beim nächsten Start von vorn. Das Upload-Center wartet so lange."
            alert.addButton(withTitle: "Beenden")
            alert.addButton(withTitle: "Abbrechen")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Task {
            await model.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The state in the icon itself: idle, encoding with its share, paused, no connection.
struct MenuIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.pausedUntil != nil {
            Image(systemName: "pause.circle")
        } else if let fraction = model.proresJob?.fraction ?? model.queueJob?.fraction {
            HStack(spacing: 2) {
                Image(systemName: "wind")
                Text("\(Int(fraction * 100)) %").monospacedDigit()
            }
        } else if model.connection == .down {
            Image(systemName: "wind.snow").symbolRenderingMode(.hierarchical)
        } else {
            Image(systemName: "wind")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(stateLine)
        if let problem = model.problem {
            Text(problem)
        }

        if let job = model.proresJob {
            Divider()
            Text("ProRes: \(job.name)")
            Text(Self.progressLine(fraction: job.fraction, fps: job.fps, speed: job.speed, eta: job.etaS))
        }
        if let job = model.queueJob {
            Divider()
            Text([job.title, job.kind == "whisper" ? "Whisper" : job.rung.map { "\($0)p" }].compactMap { $0 }.joined(separator: " · "))
            Text(Self.progressLine(fraction: job.fraction ?? 0, fps: job.fps, speed: job.speed, eta: job.etaS))
        }

        Divider()
        if model.results.isEmpty {
            Text("Noch keine Aufträge")
        }
        ForEach(model.results) { r in
            Text("\(r.title): \(Self.verdict(r.verdict))\(r.check.map { " (\($0))" } ?? "")")
        }
        Text("Heute fertig: \(model.finishedToday)")

        Divider()
        if let until = model.pausedUntil {
            Button("Fortsetzen (Pause bis \(until.formatted(date: .omitted, time: .shortened)))") { model.resume() }
        } else {
            Menu("Pause") {
                Button("30 Minuten") { model.pause(for: 30 * 60) }
                Button("2 Stunden") { model.pause(for: 2 * 3600) }
                Button("24 Stunden") { model.pause(for: 24 * 3600) }
            }
        }
        Button("Protokoll anzeigen …") {
            openWindow(id: "log")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()
        Text(connectionLine)
        ForEach(model.refused, id: \.kind) { r in
            Text("Keine \(r.kind)-Aufträge: \(r.reason)")
        }

        Divider()
        Button("Upload-Center öffnen") { NSWorkspace.shared.open(AppModel.uploadCenter) }
        SettingsLink { Text("Einstellungen …") }
        Button("Über Slipstream") { About.show(model) }
        if let latest = model.updateAvailable {
            Button("Update verfügbar: \(latest) …") { NSWorkspace.shared.open(AppModel.releases) }
        }
        Divider()
        Button("Beenden") { NSApp.terminate(nil) }
    }

    private var stateLine: String {
        if model.pausedUntil != nil { return "Pausiert" }
        if model.proresJob != nil || model.queueJob != nil { return "Wandelt um" }
        switch model.connection {
        case .up: return "Bereit"
        case .down: return "Keine Verbindung zum Encoder"
        case .notPaired, .noWorker: return "Bereit für ProRes"
        }
    }

    private var connectionLine: String {
        switch model.connection {
        case .notPaired: return "Nicht gekoppelt (nur ProRes)"
        case .noWorker: return "Ohne Worker (nur ProRes)"
        case .down: return "Tunnel getrennt" + (model.lastAnswer.map { ", letzte Antwort \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
        case .up: return "Tunnel verbunden" + (model.lastAnswer.map { ", letzte Antwort \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
        }
    }

    static func verdict(_ v: String) -> String {
        switch v {
        case "accepted": return "angenommen"
        case "rejected": return "abgelehnt"
        case "given_back": return "zurückgegeben"
        default: return v
        }
    }

    static func progressLine(fraction: Double, fps: Double?, speed: Double?, eta: Int?) -> String {
        var parts = ["\(Int(fraction * 100)) %"]
        if let fps { parts.append(String(format: "%.1f fps", fps)) }
        if let speed { parts.append(String(format: "%.2f×", speed)) }
        if let eta { parts.append("noch \(Duration.seconds(eta).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))") }
        return parts.joined(separator: " · ")
    }
}

/// About: the version, the tools the worker runs, and a newer release when there is one.
enum About {
    @MainActor
    static func show(_ model: AppModel) {
        var lines: [String] = []
        let tools = model.tools.isEmpty ? bundledTools() : model.tools.map { "\($0.name) \($0.version)" }
        lines.append(contentsOf: tools)
        if let latest = model.updateAvailable { lines.append("Update verfügbar: \(latest)") }
        let credits = NSMutableAttributedString(string: lines.joined(separator: "\n"),
                                                attributes: [.font: NSFont.systemFont(ofSize: 11)])
        if model.updateAvailable != nil {
            credits.append(NSAttributedString(string: "\n"))
            credits.append(NSAttributedString(string: "Zum Download", attributes: [.link: AppModel.releases,
                                                                                   .font: NSFont.systemFont(ofSize: 11)]))
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// `Contents/Helpers/versions.txt`, from the toolchain of encode-queue (bin/fetch-worker).
    static func bundledTools() -> [String] {
        guard let text = try? String(contentsOf: Paths.helper("versions.txt"), encoding: .utf8) else {
            return ["Ohne Worker und Werkzeuge"]
        }
        return text.split(separator: "\n").map(String.init)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("threads") private var threads = AppModel.maxThreads
    @AppStorage("gpu") private var gpu = true
    @AppStorage("jobs") private var jobs = 1
    @State private var identity: PairingIdentity?

    var body: some View {
        Form {
            Section("Leistung") {
                Stepper("CPU-Threads: \(threads) von \(AppModel.maxThreads)", value: $threads, in: 1...AppModel.maxThreads)
                Toggle("Whisper darf die GPU nutzen", isOn: $gpu)
                Picker("Aufträge gleichzeitig", selection: $jobs) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                }
                Text("Gilt nur für Aufträge aus der Warteschlange. ProRes für das Upload-Center läuft auf der Media Engine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Kopplung") {
                if let identity {
                    LabeledContent("Name", value: identity.name)
                    LabeledContent("Öffentlicher Schlüssel") {
                        Text(identity.publicKey).textSelection(.enabled).font(.caption.monospaced())
                    }
                    LabeledContent("Tunnel", value: identity.tunnelAddress ?? "nicht gekoppelt")
                }
                Text("Koppeln: im Upload-Center auf der Seite Encoder „Diesen Mac als Helper hinzufügen“, in Safari auf diesem Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onChange(of: threads) { model.limitsChanged() }
        .onChange(of: gpu) { model.limitsChanged() }
        .onChange(of: jobs) { model.limitsChanged() }
        .task { identity = try? await AppPairing { _ in }.identity() }
    }
}

struct LogView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.logLines.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.caption.monospaced()).textSelection(.enabled).id(i)
                    }
                }
                .padding(8)
            }
            .onChange(of: model.logLines.count) { proxy.scrollTo(model.logLines.count - 1, anchor: .bottom) }
        }
        .overlay {
            if model.logLines.isEmpty { Text("Noch keine Zeilen vom Worker.").foregroundStyle(.secondary) }
        }
    }
}
