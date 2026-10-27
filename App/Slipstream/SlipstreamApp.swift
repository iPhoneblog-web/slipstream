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
    }
}

/// Settings and the log as windows AppKit owns. SwiftUI's `Settings` scene with `SettingsLink`
/// did not open from the menu of a menu bar app (LSUIElement, no Dock icon, never active): the
/// link asks the app to show its settings, and an app that is not active shows nothing. So the
/// menu calls these, which make the window and activate the app first.
@MainActor
final class Windows {
    private var open: [String: NSWindow] = [:]

    /// `size` nil: the window follows its content's size (the setup window grows with a message).
    func show<V: View>(_ id: String, title: String, size: NSSize?, resizable: Bool = false, _ view: () -> V) {
        let window = open[id] ?? {
            let host = NSHostingController(rootView: view())
            if size == nil { host.sizingOptions = [.preferredContentSize] }
            let w = NSWindow(contentViewController: host)
            w.title = title
            w.identifier = NSUserInterfaceItemIdentifier(id)
            w.styleMask = resizable ? [.titled, .closable, .resizable, .miniaturizable] : [.titled, .closable]
            if let size { w.setContentSize(size) }
            if resizable, let size { w.contentMinSize = NSSize(width: min(size.width, 440), height: min(size.height, 260)) }
            w.isReleasedWhenClosed = false
            w.center()
            open[id] = w
            return w
        }()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func isVisible(_ id: String) -> Bool { open[id]?.isVisible == true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A write to a worker that just died must fail with EPIPE, not end the app.
        signal(SIGPIPE, SIG_IGN)
        model.start()
        // bin/check-launch: `-openSettings YES` opens Settings the way the menu does, and the
        // script checks that the window is on screen.
        if UserDefaults.standard.bool(forKey: "openSettings") {
            model.showSettings()
        }
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
                : "Die ProRes-Umwandlung beginnt beim nächsten Start von vorn. Das Funkhaus wartet so lange."
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
    @AppStorage("threads") private var threads = AppModel.maxThreads

    var body: some View {
        if model.site == nil {
            Text("Nicht eingerichtet")
            Button("Einrichten …") { model.showSetup() }
            Divider()
            Button("Beenden") { NSApp.terminate(nil) }
        } else {
            configured
        }
    }

    @ViewBuilder private var configured: some View {
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
        Menu("CPU für den Encoder: \(threads) von \(AppModel.maxThreads) Kernen") {
            Picker("CPU", selection: Binding(get: { threads }, set: { threads = $0; model.limitsChanged() })) {
                ForEach(CPUChoice.options(cores: AppModel.maxThreads, current: threads)) { c in
                    Text(c.label).tag(c.threads)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Button("Protokoll anzeigen …") { model.showLog() }

        Divider()
        Text(connectionLine)
        if let seen = model.extensionSeen {
            Text("Safari-Extension: verbunden, zuletzt \(seen.formatted(date: .omitted, time: .shortened))")
        } else {
            Text("Safari-Extension: noch nicht verbunden")
            Text("Funkhaus in Safari öffnen; sonst in Safari erlauben (Einstellungen → Erweiterungen → Slipstream, \(model.site?.host ?? ""))")
        }
        ForEach(model.refused, id: \.kind) { r in
            Text("Keine \(r.kind)-Aufträge: \(r.reason)")
        }

        Divider()
        Button("Funkhaus öffnen") { model.openSite() }
        Button("Einstellungen …") { model.showSettings() }
        Button("Über Slipstream") { About.show(model) }
        Button("Lizenzen …") { About.showLicences() }
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

    /// The licences folder in Finder: Slipstream's and encode-worker's (MIT), and the
    /// toolchain's, with SOURCES.md, which says where the source of ffmpeg (GPLv3) is.
    @MainActor
    static func showLicences() {
        guard let url = Bundle.main.url(forResource: "licenses", withExtension: nil) else { return }
        let sources = url.appendingPathComponent("SOURCES.md")
        if FileManager.default.fileExists(atPath: sources.path) {
            NSWorkspace.shared.activateFileViewerSelecting([sources])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// `Contents/Resources/versions.txt`, from the toolchain of encode-queue (bin/fetch-worker).
    static func bundledTools() -> [String] {
        guard let text = Paths.toolVersions else {
            return ["Ohne Worker und Werkzeuge"]
        }
        return text.split(separator: "\n").map(String.init)
    }
}

/// Settings: four tabs, each as tall as its content, in a window that can be resized (it fit no
/// 13-inch screen as one long form in 1.1.0).
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("threads") private var threads = AppModel.maxThreads
    @AppStorage("gpu") private var gpu = true
    @AppStorage("jobs") private var jobs = 1
    @State private var identity: PairingIdentity?
    /// The real state: the user can turn it off in System Settings → Allgemein → Anmeldeobjekte.
    @State private var loginItem = LoginItem.isOn

    var body: some View {
        TabView {
            Form {
                Toggle("Bei der Anmeldung starten", isOn: Binding(get: { loginItem }, set: { LoginItem.set($0); loginItem = LoginItem.isOn }))
                Text("Ausschalten geht auch in den Systemeinstellungen → Allgemein → Anmeldeobjekte.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Version", value: model.version)
                Button("Lizenzen …") { About.showLicences() }
            }
            .formStyle(.grouped)
            .tabItem { Label("Allgemein", systemImage: "gearshape") }

            Form {
                Stepper("CPU-Threads: \(threads) von \(AppModel.maxThreads)", value: $threads, in: 1...AppModel.maxThreads)
                Toggle("Whisper darf die GPU nutzen", isOn: $gpu)
                Picker("Aufträge gleichzeitig", selection: $jobs) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                }
                Text("Gilt nur für Aufträge aus der Warteschlange. ProRes für das Funkhaus läuft auf der Media Engine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Leistung", systemImage: "cpu") }

            Form {
                LabeledContent("Funkhaus", value: model.site.map { "\($0.name) (\($0.host))" } ?? "nicht eingerichtet")
                Button("Anderes Funkhaus einrichten …") { model.showSetup() }
            }
            .formStyle(.grouped)
            .tabItem { Label("Funkhaus", systemImage: "antenna.radiowaves.left.and.right") }

            Form {
                if let identity {
                    LabeledContent("Name", value: identity.name)
                    LabeledContent("Öffentlicher Schlüssel") {
                        Text(identity.publicKey).textSelection(.enabled).font(.caption.monospaced())
                    }
                    LabeledContent("Tunnel", value: identity.tunnelAddress ?? "nicht gekoppelt")
                }
                Text("Koppeln: im Funkhaus auf der Seite Encoder „Diesen Mac als Helper hinzufügen“, in Safari auf diesem Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Kopplung", systemImage: "link") }
        }
        .padding(.top, 4)
        .frame(minWidth: 440, idealWidth: 500, maxWidth: .infinity, minHeight: 260, idealHeight: 300, maxHeight: .infinity)
        .onChange(of: threads) { model.limitsChanged() }
        .onChange(of: gpu) { model.limitsChanged() }
        .onChange(of: jobs) { model.limitsChanged() }
        .task { identity = try? await AppPairing { _ in }.identity() }
        .onAppear { loginItem = LoginItem.isOn }
    }
}

/// First launch, and "Anderes Funkhaus einrichten": the Funkhaus, checked before it is kept.
struct SetupView: View {
    @ObservedObject var model: AppModel
    @State private var host = ""
    @State private var problem: String?
    @State private var busy = false
    @State private var atLogin = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Für welches Funkhaus arbeitet dieser Mac?").font(.headline)
            Text("Slipstream und seine Safari-Extension antworten nur diesem Funkhaus.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("funkhaus.example.org", text: $host)
                .textFieldStyle(.roundedBorder)
                .onSubmit { check() }
            Toggle("Bei der Anmeldung starten", isOn: $atLogin)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if let site = model.site {
                Text("Eingerichtet: \(site.name) (\(site.host))").font(.callout)
            }
            Text("Nach dem Installieren oder einem Update: Safari mit ⌘Q beenden und neu öffnen, sonst sieht Safari die Extension nicht.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Prüfen und speichern") { check() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            host = model.site?.host ?? ""
            // A first setup starts at login by default; setting up another Funkhaus shows how it is.
            if model.site != nil { atLogin = LoginItem.isOn }
        }
    }

    private func check() {
        busy = true
        problem = nil
        Task {
            problem = await model.checkSite(host)
            busy = false
            if problem == nil {
                LoginItem.set(atLogin)
                NSApp.keyWindow?.close()
            }
        }
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
