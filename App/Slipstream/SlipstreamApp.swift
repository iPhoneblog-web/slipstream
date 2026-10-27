import AppKit
import HelperCore
import os
import SwiftUI

@main
struct SlipstreamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model, mirror: delegate.mirror)
        } label: {
            MenuIcon(mirror: delegate.mirror)
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
    /// The menu's text, still while a menu is open (MenuMirror).
    lazy var mirror = MenuMirror(model: model)
    private let watchdog = Watchdog()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A write to a worker that just died must fail with EPIPE, not end the app.
        signal(SIGPIPE, SIG_IGN)
        watchdog.start()
        model.start()
        // bin/check-launch: `-openSettings YES` opens Settings the way the menu does, and the
        // script checks that the window is on screen.
        if UserDefaults.standard.bool(forKey: "openSettings") {
            model.showSettings()
        }
    }

    /// `slipstream://connect?site=<host>` from a Funkhaus page, also as the app's first launch:
    /// the setup window checks the host and asks before it keeps it.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == ConnectLink.scheme {
            model.open(url)
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
    @ObservedObject var mirror: MenuMirror

    var body: some View {
        switch mirror.icon {
        case .paused:
            Image(systemName: "pause.circle")
        case .progress(let percent):
            HStack(spacing: 2) {
                Image(systemName: "wind")
                Text("\(percent) %").monospacedDigit()
            }
        case .down:
            Image(systemName: "wind.snow").symbolRenderingMode(.hierarchical)
        case .idle:
            Image(systemName: "wind")
        }
    }
}

/// The menu: text from the mirror, which stands still while the menu is open; actions on the
/// model.
struct MenuContent: View {
    let model: AppModel
    @ObservedObject var mirror: MenuMirror
    @AppStorage("threads") private var threads = AppModel.maxThreads

    var body: some View {
        let l = mirror.lines
        if !l.configured {
            Text("Nicht eingerichtet")
            Button("Einrichten …") { model.showSetup() }
            Divider()
            Button("Beenden") { NSApp.terminate(nil) }
        } else {
            Text(l.state)
            if let problem = l.problem { Text(problem) }
            if !l.job.isEmpty {
                Divider()
                ForEach(l.job, id: \.self) { Text($0) }
            }

            Divider()
            ForEach(l.results, id: \.self) { Text($0) }
            Text(l.today)

            Divider()
            if let until = l.pausedUntil {
                Button("Fortsetzen (Pause bis \(until))") { model.resume() }
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
            Text(l.connection)
            ForEach(l.extensionLines, id: \.self) { Text($0) }
            ForEach(l.refused, id: \.self) { Text($0) }

            Divider()
            Button("Funkhaus öffnen") { model.openSite() }
            Button("Einstellungen …") { model.showSettings() }
            Button("Über Slipstream") { About.show(model) }
            Button("Lizenzen …") { About.showLicences() }
            Button("Nach Updates suchen …") { model.updates.check() }
            if let latest = l.update {
                Button("Update verfügbar: \(latest) …") { model.updates.check() }
            }
            Divider()
            Button("Beenden") { NSApp.terminate(nil) }
        }
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
    /// nil until macOS answered, off the main thread (LoginItem).
    @State private var loginItem: Bool?
    @State private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Form {
                Toggle("Bei der Anmeldung starten", isOn: Binding(get: { loginItem ?? false }, set: { on in
                    loginItem = on
                    Task { loginItem = await LoginItem.set(on) }
                }))
                .disabled(loginItem == nil)
                Text("Ausschalten geht auch in den Systemeinstellungen → Allgemein → Anmeldeobjekte.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Automatisch nach Updates suchen", isOn: Binding(
                    get: { model.updates.updater.automaticallyChecksForUpdates },
                    set: { model.updates.updater.automaticallyChecksForUpdates = $0 }))
                Button("Nach Updates suchen …") { model.updates.check() }
                LabeledContent("Version", value: model.version)
                Button("Lizenzen …") { About.showLicences() }
            }
            .formStyle(.grouped)
            .tabItem { Label("Allgemein", systemImage: "gearshape") }
            .tag("general")

            Form {
                Stepper("CPU-Threads: \(threads) von \(AppModel.maxThreads)", value: $threads, in: 1...AppModel.maxThreads)
                Toggle("Whisper darf die GPU nutzen", isOn: $gpu)
                Picker("Aufträge gleichzeitig", selection: $jobs) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                }
                Text("Gilt nur für Aufträge aus der Warteschlange. ProRes für das Funkhaus läuft auf der Media Engine.")
                    .font(.caption).foregroundStyle(.secondary)
                ModelsSection(model: model)
            }
            .formStyle(.grouped)
            .tabItem { Label("Leistung", systemImage: "cpu") }
            .tag("performance")

            Form {
                LabeledContent("Funkhaus", value: model.site.map { "\($0.name) (\($0.host))" } ?? "nicht eingerichtet")
                Button("Anderes Funkhaus einrichten …") { model.showSetup() }
            }
            .formStyle(.grouped)
            .tabItem { Label("Funkhaus", systemImage: "antenna.radiowaves.left.and.right") }
            .tag("site")

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
            .tag("pairing")
        }
        .padding(.top, 4)
        .frame(minWidth: 440, idealWidth: 500, maxWidth: .infinity, minHeight: 260, idealHeight: 300, maxHeight: .infinity)
        .onChange(of: threads) { model.limitsChanged() }
        .onChange(of: gpu) { model.limitsChanged() }
        .onChange(of: jobs) { model.limitsChanged() }
        // The keychain and the login item answer off the main thread; the window never waits.
        .task { identity = try? await Task.detached { try await AppPairing { _ in }.identity() }.value }
        .task { loginItem = await LoginItem.isOn() }
        // bin/check-launch: `-cycleSettingsTabs YES` shows each tab once, while the watchdog
        // logs any wait of the main thread.
        .task {
            guard UserDefaults.standard.bool(forKey: "cycleSettingsTabs") else { return }
            for t in ["performance", "site", "pairing", "general"] {
                try? await Task.sleep(nanoseconds: 700_000_000)
                tab = t
            }
            Logger(subsystem: SlipstreamIDs.logSubsystem, category: "check").notice("settings tabs cycled")
        }
    }
}

/// Settings → Leistung: the whisper models the queue wants this Mac to hold, from the worker's
/// `model` events (docs/worker.md), and what they take on disk.
struct ModelsSection: View {
    @ObservedObject var model: AppModel
    @State private var diskBytes: Int64 = 0

    var body: some View {
        Section {
            if model.models.isEmpty {
                Text("Noch keine. Nach dem Koppeln sagt das Funkhaus, welche Modelle dieser Mac halten soll; Slipstream lädt sie dann selbst.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.models, id: \.sha256) { m in
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent(Self.title(m.name)) {
                        Text(Self.state(m)).foregroundStyle(m.state == "failed" ? .red : .secondary)
                    }
                    if m.state == "downloading" {
                        ProgressView(value: m.fraction ?? 0)
                    }
                    if let reason = m.reason, ["failed", "unavailable"].contains(m.state) {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Belegt", value: ByteCountFormatter.string(fromByteCount: diskBytes, countStyle: .file))
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([Paths.models]) }
            Text("Das Funkhaus wählt die Modelle nach der gemessenen Geschwindigkeit dieses Macs. Ohne GPU rechnet Whisper auf der CPU, deutlich langsamer; dann bekommt der Mac kleinere Modelle oder keine Whisper-Aufträge.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Whisper-Modelle")
        }
        .task(id: model.models) { diskBytes = await Task.detached(priority: .utility) { Paths.modelsBytes }.value }
    }

    /// `ggml-large-v3-turbo.bin` → `large-v3-turbo`.
    static func title(_ file: String) -> String {
        var name = file
        if name.hasPrefix("ggml-") { name.removeFirst(5) }
        if name.hasSuffix(".bin") { name.removeLast(4) }
        return name
    }

    static func state(_ m: WorkerEvent.Model) -> String {
        let size = m.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        switch m.state {
        case "wanted": return ["gewünscht", size].compactMap { $0 }.joined(separator: " · ")
        case "downloading":
            let done = m.bytesDone.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return "lädt " + [done, size].compactMap { $0 }.joined(separator: " von ")
        case "checking": return "wird geprüft"
        case "calibrating": return "wird gemessen"
        case "ready":
            let speed = m.speed.map { $0.formatted(.number.precision(.fractionLength(1))) + "× Echtzeit" }
            return ["bereit", speed, size].compactMap { $0 }.joined(separator: " · ")
        case "failed": return "fehlgeschlagen"
        case "unavailable": return "nicht verfügbar"
        default: return m.state
        }
    }
}

/// The one question at the first launch (AppModel.askLoginItemOnce); "Ja" is the default.
struct LoginQuestion: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Slipstream bei der Anmeldung starten?").font(.headline)
            Text("Dann ist Slipstream nach jeder Anmeldung da, für ProRes im Funkhaus und für Aufträge des Encoders, ohne dass du es öffnest. Ändern geht jederzeit in Einstellungen → Allgemein.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Nein") { answer(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Ja") { answer(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func answer(_ yes: Bool) {
        model.answerLoginItem(yes)
        NSApp.keyWindow?.close()
    }
}

/// First launch, and "Anderes Funkhaus einrichten": the Funkhaus, checked before it is kept.
struct SetupView: View {
    @ObservedObject var model: AppModel
    @State private var host = ""
    @State private var problem: String?
    @State private var busy = false
    /// A site a connect link named, checked, waiting for the user's yes.
    @State private var confirm: SiteConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Für welches Funkhaus arbeitet dieser Mac?").font(.headline)
            Text("Slipstream und seine Safari-Extension antworten nur diesem Funkhaus.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("funkhaus.example.org", text: $host)
                .textFieldStyle(.roundedBorder)
                .onSubmit { check() }
                .onChange(of: host) { if host != confirm?.host { confirm = nil } }
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
            if let confirm {
                // A connect link: any website can send one, so nothing is kept before this click.
                Text("Mit \(confirm.name) (\(confirm.host)) verbinden?").font(.headline)
                Text("Ein Link hat Slipstream geöffnet. Verbinde nur, wenn du diesem Funkhaus vertraust: Es bekommt deine ProRes-Dateien und kann diesen Mac als Encoder nutzen.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Abbrechen") { self.confirm = nil; NSApp.keyWindow?.close() }
                        .keyboardShortcut(.cancelAction)
                    Button("Verbinden") { keep(confirm) }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack {
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Prüfen und speichern") { check() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { host = model.site?.host ?? "" }
        .task(id: model.connectRequest?.id) { await connect() }
    }

    /// A connect link: the host into the field, the usual check, then the question.
    private func connect() async {
        guard let request = model.takeConnectRequest() else { return }
        confirm = nil
        problem = request.problem
        guard let linked = request.host else { return }
        host = linked
        busy = true
        switch await model.lookUpSite(linked) {
        case .failure(let p): problem = p.message
        case .success(let found): confirm = found
        }
        busy = false
    }

    private func check() {
        busy = true
        problem = nil
        let before = model.site?.host
        Task {
            problem = await model.checkSite(host)
            busy = false
            if problem == nil { done(before) }
        }
    }

    private func keep(_ found: SiteConfig) {
        let before = model.site?.host
        problem = model.saveSite(found)
        confirm = nil
        if problem == nil { done(before) }
    }

    /// Saved: the window closed, and when the Funkhaus changed, Safari's restart.
    private func done(_ before: String?) {
        NSApp.keyWindow?.close()
        guard let before, let site = model.site, site.host != before else { return }
        let alert = NSAlert()
        alert.messageText = "Safari mit ⌘Q beenden und neu öffnen"
        alert.informativeText = "Slipstream arbeitet jetzt für \(site.name) (\(site.host)). Erst nach einem Neustart von Safari antwortet die Extension dort zuverlässig."
        alert.runModal()
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
