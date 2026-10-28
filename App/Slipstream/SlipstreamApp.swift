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
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "menuPreview") {
            model.preview()
            // `-menuRender <file.png>`: the open menu as the app draws it, for a pull request
            // (this Mac's shell may not record the screen); `-menuRenderSubmenu <title>` opens
            // that submenu instead.
            if let path = UserDefaults.standard.string(forKey: "menuRender") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                    renderMenu(to: URL(fileURLWithPath: path), submenu: UserDefaults.standard.string(forKey: "menuRenderSubmenu"))
                    NSApp.terminate(nil)
                }
            }
            return
        }
        #endif
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

#if DEBUG
extension AppDelegate {
    /// Opens the status item's menu (or one of its submenus, alone), draws the menu's window into
    /// `url` while it is open, and closes it.
    func renderMenu(to url: URL, submenu: String?) {
        func button(in view: NSView?) -> NSButton? {
            guard let view else { return nil }
            if let b = view as? NSButton { return b }
            return view.subviews.lazy.compactMap { button(in: $0) }.first
        }
        guard let item = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("StatusBar") }),
              let statusButton = button(in: item.contentView) else { return }
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            if let token { NotificationCenter.default.removeObserver(token) }
            guard let menu = note.object as? NSMenu else { return }
            let draw = Timer(timeInterval: 0.8, repeats: false) { _ in
                MainActor.assumeIsolated {
                    let width = NSApp.windows.filter { $0.isVisible && $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue }
                        .map(\.frame.width).max() ?? 0
                    var shown = menu
                    if let title = submenu, let sub = menu.items.first(where: { $0.title == title })?.submenu {
                        sub.update()
                        shown = sub
                    }
                    Self.drawMenu(shown, width: width, to: url)
                    menu.cancelTracking()
                }
            }
            RunLoop.main.add(draw, forMode: .common)
        }
        statusButton.performClick(nil)
    }

    /// The menu's items as AppKit holds them, drawn in the menu font at the open menu's width:
    /// their titles exactly as the app made them, disabled ones grey, a submenu with its arrow.
    /// The window itself draws nothing into a bitmap.
    static func drawMenu(_ menu: NSMenu, width: CGFloat, to url: URL) {
        let font = NSFont.menuFont(ofSize: 0)
        let rowH: CGFloat = 22, sepH: CGFloat = 11, pad: CGFloat = 14
        let w = width > 0 ? width : 320
        let items = menu.items.filter { !$0.isHidden }
        let h = items.reduce(CGFloat(10)) { $0 + ($1.isSeparatorItem ? sepH : rowH) } + 10
        let image = NSImage(size: NSSize(width: w, height: h), flipped: true) { rect in
            NSColor(white: 0.96, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            var y: CGFloat = 10
            for item in items {
                if item.isSeparatorItem {
                    NSColor(white: 0.82, alpha: 1).setFill()
                    NSRect(x: pad, y: y + sepH / 2, width: w - 2 * pad, height: 1).fill()
                    y += sepH
                    continue
                }
                let color: NSColor = item.isEnabled || item.submenu != nil ? .black : NSColor(white: 0.55, alpha: 1)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let mark = item.state == .on ? "✓" : ""
                (mark as NSString).draw(at: NSPoint(x: 6, y: y + 3), withAttributes: attrs)
                (item.title as NSString).draw(at: NSPoint(x: pad + 8, y: y + 3), withAttributes: attrs)
                if item.submenu != nil {
                    ("›" as NSString).draw(at: NSPoint(x: w - pad - 6, y: y + 2), withAttributes: attrs)
                }
                y += rowH
            }
            return true
        }
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            rep.size = image.size
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        print("menu \(Int(w)) pt wide, \(items.count) items: " + items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | "))
    }
}
#endif

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

/// A label the app makes (a submenu's title, a button with a time or a version in it), cut to
/// the menu's width as Line is.
func fitted(_ text: String) -> String { MenuLine.fit(text, measure: MenuMirror.measure) }

/// A line of the menu, cut to the menu's width (MenuLine); the whole text is its tooltip and, once
/// cut, in the log window.
struct Line: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(MenuLine.fit(text, measure: MenuMirror.measure)).help(text)
    }
}

/// The menu: text from the mirror, which stands still while the menu is open; actions on the
/// model.
struct MenuContent: View {
    let model: AppModel
    @ObservedObject var mirror: MenuMirror
    @AppStorage("threads") private var threads = AppModel.maxThreads
    @AppStorage("efficiencyOnly") private var efficiencyOnly = false
    @AppStorage("archiveOnEfficiency") private var archiveOnEfficiency = false

    @ViewBuilder private func pauseButtons(_ mode: PauseMode) -> some View {
        Button("30 Minuten") { model.pause(for: 30 * 60, mode: mode) }
        Button("2 Stunden") { model.pause(for: 2 * 3600, mode: mode) }
        Button("24 Stunden") { model.pause(for: 24 * 3600, mode: mode) }
    }

    var body: some View {
        let l = mirror.lines
        if !l.configured {
            Text("Nicht eingerichtet")
            Button("Einrichten …") { model.showSetup() }
            Divider()
            Button("Beenden") { NSApp.terminate(nil) }
        } else {
            // One short line per thing; the details in submenus (Thorsten, 2026-10-28).
            if l.jobs.isEmpty || l.pausedUntil != nil { Line(l.state) }
            if let problem = l.problem { Line(problem) }
            ForEach(l.jobs) { job in
                Menu {
                    ForEach(job.details, id: \.self) { Line($0) }
                } label: {
                    Text(MenuLine.fit(job.title, keeping: job.share, measure: MenuMirror.measure))
                }
                .help(job.title)
            }

            Divider()
            Menu("Letzte Ereignisse") {
                ForEach(l.results, id: \.self) { Line($0) }
            }
            Line(l.today)
            if let points = l.points { Line(points) }

            Divider()
            if let until = l.pausedUntil {
                Button(fitted("Fortsetzen (Pause bis \(until))")) { model.resume() }
                if l.pauseAfterJob && l.queueJobRunning {
                    Button("Laufenden Auftrag sofort anhalten") { model.pauseNow() }
                }
            } else {
                // Sofort pausieren stops the running job where it stands; Nach diesem Auftrag lets
                // it finish (PauseMode; Thorsten, 2026-10-28).
                Menu("Pause") {
                    if l.queueJobRunning && AppModel.workerHasModes {
                        Section("Sofort pausieren") { pauseButtons(.now) }
                        Section("Nach diesem Auftrag") { pauseButtons(.afterJob) }
                    } else {
                        pauseButtons(.now)
                    }
                }
            }
            Menu(fitted(l.cpu)) {
                if l.throttled {
                    Line("Laufender Auftrag gedrosselt")
                    Divider()
                }
                // The core counts and, on Apple silicon, "Nur Effizienzkerne" (encode-queue v0.2.18).
                Picker("CPU", selection: Binding(get: { efficiencyOnly ? CPUChoice.efficiencyTag : threads }, set: { v in
                    if v == CPUChoice.efficiencyTag {
                        efficiencyOnly = true
                    } else {
                        efficiencyOnly = false
                        threads = v
                    }
                    model.limitsChanged()
                })) {
                    ForEach(CPUChoice.options(cores: AppModel.maxThreads, current: threads, efficiencyCores: AppModel.efficiencyCores,
                                              slowdown: AppModel.efficiencySlowdown)) { c in
                        Text(fitted(c.label)).tag(c.threads)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if AppModel.efficiencyCores > 0 {
                    Divider()
                    Toggle("Archiv-Aufträge nur auf Effizienzkernen",
                           isOn: Binding(get: { archiveOnEfficiency || efficiencyOnly }, set: { archiveOnEfficiency = $0; model.limitsChanged() }))
                        .disabled(efficiencyOnly)
                    ForEach(CPUChoice.efficiencyNoteLines, id: \.self) { Line($0) }
                }
            }
            Button("Protokoll anzeigen …") { model.showLog() }

            Divider()
            // Not reached by Safari yet: what to do, in lines as wide as the menu (Thorsten,
            // 2026-10-28 20:08: one long line here made the menu 800 pt wide).
            if l.extensionMissing {
                Menu("Safari-Extension: noch nicht verbunden") {
                    Button("Funkhaus in Safari öffnen") { model.openSiteInSafari() }
                    Divider()
                    Line("Erscheint dann nichts:")
                    Line("Safari → Einstellungen → Erweiterungen")
                    Line("„Slipstream“ anhaken und für")
                    Line("\(l.siteHost) erlauben")
                    Button("Safari-Erweiterungen öffnen …") { model.showSafariExtensionSettings() }
                }
            }
            Menu(fitted(l.connectionWord)) {
                Line(l.connection)
                if let reason = l.stopReason { Line(reason) }
                if let seen = l.extensionSeen { Line(seen) }
                ForEach(l.refused, id: \.self) { Line($0) }
            }

            Divider()
            Button("Funkhaus öffnen") { model.openSite() }
            Button("Einstellungen …") { model.showSettings() }
            Button("Über Slipstream") { About.show(model) }
            Button("Lizenzen …") { About.showLicences() }
            Button("Nach Updates suchen …") { model.updates.check() }
            if let latest = l.update {
                Button(fitted("Update verfügbar: \(latest) …")) { model.updates.check() }
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
    @AppStorage("highSlots") private var highSlots = 1
    @AppStorage("efficiencyOnly") private var efficiencyOnly = false
    @AppStorage("archiveOnEfficiency") private var archiveOnEfficiency = false
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
                if AppModel.efficiencyCores > 0 {
                    let slower = AppModel.efficiencySlowdown.map { " (etwa \($0)× langsamer)" } ?? ""
                    Toggle("Nur Effizienzkerne" + slower, isOn: $efficiencyOnly)
                    Toggle("Archiv-Aufträge nur auf Effizienzkernen" + slower, isOn: $archiveOnEfficiency)
                        .disabled(efficiencyOnly)
                    Text(CPUChoice.efficiencyCaption(slowdown: AppModel.efficiencySlowdown))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Whisper darf die GPU nutzen", isOn: $gpu)
                Picker("Aufträge gleichzeitig", selection: $jobs) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                }
                Picker("Dazu für Sofort und Stufe 1", selection: $highSlots) {
                    Text("keiner").tag(0)
                    Text("1").tag(1)
                    Text("2").tag(2)
                }
                Text("Aufträge gleichzeitig nimmt jeden Auftrag. Die Plätze für Sofort und Stufe 1 nehmen nur diese, auch neben einem langen Archiv-Auftrag, wenn der Arbeitsspeicher reicht. Gilt nur für Aufträge aus der Warteschlange. ProRes für das Funkhaus läuft auf der Media Engine.")
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
        .onChange(of: highSlots) { model.limitsChanged() }
        .onChange(of: efficiencyOnly) { model.limitsChanged() }
        .onChange(of: archiveOnEfficiency) { model.limitsChanged() }
        // The keychain and the login item answer off the main thread; the window never waits.
        .task { identity = try? await Task.detached { try await AppPairing { _ in }.identity() }.value }
        .task { loginItem = await LoginItem.isOn() }
        // bin/check-launch: `-cycleSettingsTabs YES` shows each tab once, while the watchdog
        // logs any wait of the main thread.
        .task {
            guard UserDefaults.standard.bool(forKey: "cycleSettingsTabs") else { return }
            let log = Logger(subsystem: SlipstreamIDs.logSubsystem, category: "check")
            // After the launch has settled: the check counts waits from here on.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            log.notice("settings tabs: start")
            for t in ["performance", "site", "pairing", "general"] {
                try? await Task.sleep(nanoseconds: 700_000_000)
                log.notice("settings tab: \(t, privacy: .public)")
                tab = t
            }
            log.notice("settings tabs cycled")
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
                if let old = model.site?.host, old != confirm.host {
                    Text("Bisher: \(old)").font(.callout)
                }
                Text("Ein Link oder eine Funkhaus-Seite hat Slipstream geöffnet. Verbinde nur, wenn du diesem Funkhaus vertraust: Es bekommt deine ProRes-Dateien und kann diesen Mac als Encoder nutzen. Die Kopplung bleibt.")
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
        VStack(spacing: 0) {
            lines
            Divider()
            // The same lines, and older ones, as a file to send with a bug report.
            HStack {
                Text(WorkerLog.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([WorkerLog.url]) }
            }
            .padding(8)
        }
    }

    private var lines: some View {
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
