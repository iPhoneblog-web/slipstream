import AppKit
import SafariServices
import Foundation
import HelperCore

/// The configured site's origin for the loopback, which reads it off the main thread.
final class SiteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var origin: String? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// The worker's id for its own callbacks, set once the worker exists.
private final class WorkerBox: @unchecked Sendable {
    var id: UUID?
}

/// Everything the menu shows, and the pieces behind it: the loopback endpoint with the ProRes
/// jobs, and the worker for the queue's jobs (ADR-0007 §9).
@MainActor
final class AppModel: ObservableObject {
    enum Connection: Equatable {
        /// No tunnel yet: this Mac only encodes ProRes until it is paired.
        case notPaired
        /// This build carries no worker.
        case noWorker
        case down
        case up
    }

    struct ResultLine: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var verdict: String
        var check: String?
        var at: Date
    }

    @Published private(set) var connection: Connection = .notPaired
    @Published private(set) var lastAnswer: Date?
    @Published private(set) var refused: [WorkerEvent.Refusal] = []
    /// The worker's running jobs, one per lease, in the order they started (encode-queue v0.2.14:
    /// a job in each kind of slot); the menu shows a line with a submenu for each.
    @Published private(set) var queueJobs = RunningJobs()
    var queueJob: WorkerJob? { queueJobs.jobs.first }
    /// The queue's last word on this Mac's points (encode-queue v0.2.15); nil before it.
    @Published private(set) var points: WorkerEvent.Points?
    /// The worker's word on the CPU limit in effect (encode-queue v0.2.17); nil before it, and
    /// from a worker before v0.2.17, which says nothing: the menu shows the setting then.
    @Published private(set) var workerLimits: WorkerEvent.Limits?
    /// What the menu bar shows beside the icon (MenuBarItems; Einstellungen → Menüleiste).
    @Published private(set) var menuBarItems = MenuBarItems.load(from: .standard)
    /// The cores the worker and its tools keep busy, sampled once a second while the menu bar
    /// shows them (ProcessCPU); nil otherwise.
    @Published private(set) var workerCores: Double?
    private let workerCPU = ProcessCPU()

    func setMenuBarItem(_ item: MenuBarItem, _ on: Bool) {
        menuBarItems = menuBarItems.with(item, on)
        if !previewing { menuBarItems.save(to: defaults) }
    }

    /// The CPU settings, for the menu's line until the worker answers them.
    @Published private(set) var threadsSetting = 0
    @Published private(set) var efficiencySetting = Efficiency.off
    @Published private(set) var proresJob: JobStatus?
    @Published private(set) var results: [ResultLine] = []
    @Published private(set) var finishedToday = 0
    @Published private(set) var pausedUntil: Date?
    /// How the pause treats a running job (PauseMode); `.now` when not paused.
    @Published private(set) var pauseMode = PauseMode.now
    @Published private(set) var tools: [WorkerEvent.Tool] = []
    /// The whisper models the queue wants this Mac to hold, in the order the worker named them.
    @Published private(set) var models: [WorkerEvent.Model] = []
    @Published private(set) var updateAvailable: String?
    @Published private(set) var problem: String?
    /// When Safari's extension last reached this app since it started: the app extension's
    /// presence check, or a bridge request with the token. Nil: not since the start.
    @Published private(set) var extensionSeen: Date?

    private let startedAt = Date()
    private let windows = Windows()
    let updates = Updates()

    /// The Funkhaus site this Mac works for; nil until the setup window checked one.
    @Published private(set) var site: SiteConfig?
    /// The site for the loopback's check, read on its own queue.
    private let siteBox = SiteBox()

    func showSetup() {
        windows.show("setup", title: "Slipstream einrichten", size: nil) {
            SetupView(model: self)
        }
    }

    /// A connect link (`slipstream://connect?site=<host>`) for the setup window, which checks the
    /// host and asks before it saves anything (docs/funkhaus-api.md, "Connect link").
    struct ConnectRequest: Equatable {
        let id = UUID()
        var host: String?
        var problem: String?
    }

    @Published private(set) var connectRequest: ConnectRequest?

    /// The setup window took the link; reopening the window does not check it again.
    func takeConnectRequest() -> ConnectRequest? {
        defer { connectRequest = nil }
        return connectRequest
    }

    func open(_ url: URL) {
        do {
            let host = try ConnectLink.host(from: url)
            Log.notice(.app, "connect link: \(host)")
            connectRequest = ConnectRequest(host: host)
        } catch {
            Log.warning(.app, "connect link refused: \(url.absoluteString): \(error)")
            connectRequest = ConnectRequest(problem: (error as? ConnectLink.Problem)?.message ?? error.localizedDescription)
        }
        showSetup()
    }

    /// The setup window's check: the host, its `/.well-known/funkhaus.json`, then the app group.
    func checkSite(_ input: String) async -> String? {
        switch await lookUpSite(input) {
        case .failure(let problem): return problem.message
        case .success(let found): return saveSite(found)
        }
    }

    struct SetupProblem: Error { let message: String }

    /// The host and its `/.well-known/funkhaus.json`, checked; nothing saved.
    func lookUpSite(_ input: String) async -> Result<SiteConfig, SetupProblem> {
        let host: String
        do { host = try SiteConfig.host(from: input) } catch {
            return .failure(SetupProblem(message: (error as? SiteConfig.Problem)?.message ?? error.localizedDescription))
        }
        guard let wellKnown = SiteConfig.wellKnown(host) else { return .failure(SetupProblem(message: SiteConfig.Problem.badHost.message)) }
        var request = URLRequest(url: wellKnown, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url?.host == host.split(separator: ":").first.map(String.init) else {
                return .failure(SetupProblem(message: SiteConfig.Problem.notFunkhaus("keine Antwort unter /.well-known/funkhaus.json").message))
            }
            data = body
        } catch {
            Log.warning(.app, "setup: \(host) does not answer: \(error.localizedDescription)")
            return .failure(SetupProblem(message: SiteConfig.unreachable(host, (error as? URLError)?.code)))
        }
        do {
            return .success(try SiteConfig.check(host: host, wellKnown: data, appVersion: version))
        } catch {
            return .failure(SetupProblem(message: (error as? SiteConfig.Problem)?.message ?? error.localizedDescription))
        }
    }

    /// Keeps a checked site: the app group file the extension reads, then the model.
    func saveSite(_ found: SiteConfig) -> String? {
        do {
            try found.save(to: Paths.appGroup)
        } catch {
            Log.error(.app, "site \(found.host) not saved: \(error.localizedDescription)")
            return error.localizedDescription
        }
        setSite(found)
        Log.notice(.app, "site set up: \(found.host), protocol \(found.protocol)")
        return nil
    }

    private func setSite(_ s: SiteConfig?) {
        site = s
        siteBox.origin = s?.origin
    }

    func openSite() {
        if let url = site?.url { NSWorkspace.shared.open(url) } else { showSetup() }
    }

    /// The Funkhaus in Safari, whatever the default browser: only Safari has the extension.
    func openSiteInSafari() {
        guard let url = site?.url else {
            showSetup()
            return
        }
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Safari's settings at Slipstream's extension, where it is turned on and allowed per site.
    func showSafariExtensionSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: SlipstreamIDs.extensionBundle) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.note("Safari's extension settings: \(error.localizedDescription)") }
        }
    }

    /// "Slipstream bei der Anmeldung starten?" once: at the first launch, and once for an install
    /// from before 1.3.1 that never answered. A login item that is already on counts as yes.
    /// Closing the window without an answer asks again at the next launch.
    func askLoginItemOnce() {
        guard !defaults.bool(forKey: "loginItemAsked") else { return }
        Task {
            if await LoginItem.isOn() {
                defaults.set(true, forKey: "loginItemAsked")
                return
            }
            windows.show("login", title: "Slipstream", size: nil) { LoginQuestion(model: self) }
        }
    }

    func answerLoginItem(_ yes: Bool) {
        defaults.set(true, forKey: "loginItemAsked")
        Log.notice(.app, "login item: \(yes ? "yes" : "no")")
        Task { await LoginItem.set(yes) }
    }

    func showSettings() {
        windows.show("settings", title: "Slipstream – Einstellungen", size: NSSize(width: 500, height: 300), resizable: true) {
            SettingsView(model: self)
        }
    }

    func showLog() {
        windows.show("log", title: "Slipstream – Protokoll", size: NSSize(width: 960, height: 520), resizable: true) {
            LogView()
        }
    }

    func markExtensionSeen(_ at: Date = Date()) {
        guard at >= startedAt else { return }
        guard extensionSeen.map({ at > $0 }) ?? true else { return }
        // Once per start, and again after ten minutes without it: a presence check comes at
        // every Funkhaus page Safari opens.
        if let last = extensionSeen {
            if at.timeIntervalSince(last) >= 600 {
                Log.notice(.extension, "Safari extension connected again, \(WorkerEventLog.duration(at.timeIntervalSince(last))) after its last check")
            }
        } else {
            Log.notice(.extension, "Safari extension connected")
        }
        extensionSeen = at
    }

    static let releases = URL(string: "https://github.com/kyrios/slipstream/releases/latest")!

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    private var eventLog = WorkerEventLog()
    private let defaults = UserDefaults.standard
    private var jobs: ProResJobs?
    private var server: LoopbackServer?
    private var worker: WorkerProcess?
    private var awake: NSObjectProtocol?
    private var timers: [Timer] = []

    // MARK: - Settings (Settings window)

    static let maxThreads = ProcessInfo.processInfo.activeProcessorCount

    /// The Mac's performance and efficiency cores; 0, 0 with one kind (an Intel Mac).
    static let coreLevels: (perf: Int, eff: Int) = {
        func value(_ name: String) -> Int {
            var n: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &n, &size, nil, 0) == 0 ? Int(n) : 0
        }
        guard value("hw.nperflevels") >= 2 else { return (0, 0) }
        return (value("hw.perflevel0.logicalcpu"), value("hw.perflevel1.logicalcpu"))
    }()
    /// The embedded worker pauses after a job and runs jobs on the efficiency cores (encode-queue
    /// v0.2.18; both came with its --efficiency flag). Without it the menu offers neither.
    static let workerHasModes = WorkerProcess.takes("efficiency")
    static var efficiencyCores: Int { workerHasModes ? coreLevels.eff : 0 }
    /// "etwa 11× langsamer" beside the efficiency-core settings (CPUChoice.efficiencySlowdown).
    static var efficiencySlowdown: Int? { CPUChoice.efficiencySlowdown(perf: coreLevels.perf, eff: coreLevels.eff) }

    var limits: WorkerProcess.Limits {
        let threads = defaults.integer(forKey: "threads")
        return WorkerProcess.Limits(threads: threads > 0 ? min(threads, Self.maxThreads) : Self.maxThreads,
                                    gpu: defaults.object(forKey: "gpu") as? Bool ?? true,
                                    jobs: max(1, defaults.integer(forKey: "jobs")),
                                    highSlots: min(max(defaults.object(forKey: "highSlots") as? Int ?? 1, 0), 2),
                                    efficiency: Self.efficiencyCores > 0
                                        ? Efficiency(only: defaults.bool(forKey: "efficiencyOnly"), archive: defaults.bool(forKey: "archiveOnEfficiency"))
                                        : .off)
    }

    func limitsChanged() {
        let l = limits
        threadsSetting = l.threads
        efficiencySetting = l.efficiency
        Log.notice(.cores, "setting: \(l.threads) of \(Self.maxThreads) threads, gpu \(l.gpu), \(l.jobs) jobs, \(l.highSlots) high-priority slots, efficiency cores \(l.efficiency.rawValue)\(worker == nil ? "; no worker running" : "")")
        worker?.send(.limits(threads: l.threads, gpu: l.gpu, jobs: l.jobs, highSlots: l.highSlots, efficiency: l.efficiency))
    }

    // MARK: - Start

    // MARK: - Release notes

    /// Every version's notes in the bundle, newest first (ReleaseNotes).
    private(set) var releaseNotes: [ReleaseNotes] = []
    /// What "Neu in …" shows at the top of the menu after an update, until it is opened.
    @Published private(set) var newNotes: [ReleaseNotes] = []

    /// Before askLoginItemOnce, which marks a Mac that ran Slipstream before.
    private func loadReleaseNotes() {
        releaseNotes = Paths.releaseNotes.map(ReleaseNotes.load(from:)) ?? []
        newNotes = ReleaseNotes.new(in: releaseNotes, current: version, lastSeen: defaults.string(forKey: "notesSeenVersion"),
                                    ranBefore: defaults.bool(forKey: "loginItemAsked"))
        if newNotes.isEmpty { defaults.set(version, forKey: "notesSeenVersion") }
    }

    /// The notes since the last version seen, or this version's: "Neu in …" and its window.
    func showWhatsNew() {
        let notes = newNotes.isEmpty ? releaseNotes.filter { $0.version == version } : newNotes
        windows.show("whatsnew", title: "Neu in Slipstream \(version)", size: NSSize(width: 480, height: 340), resizable: true) {
            WhatsNewView(notes: notes)
        }
        newNotes = []
        defaults.set(version, forKey: "notesSeenVersion")
    }

    func start() {
        Log.notice(.app, "Slipstream \(version) started, pid \(getpid()), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        setSite(SiteConfig.load(from: Paths.appGroup))
        Log.info(.app, site.map { "site: \($0.host)" } ?? "no site set up yet")
        loadReleaseNotes()
        threadsSetting = limits.threads
        efficiencySetting = limits.efficiency
        // No site, no working app: the first launch asks for one (docs/extension-protocol.md, 4).
        if site == nil { showSetup() }
        askLoginItemOnce()
        pausedUntil = (defaults.object(forKey: "pausedUntil") as? Date).flatMap { $0 > Date() ? $0 : nil }
        pauseMode = defaults.string(forKey: "pauseMode").flatMap(PauseMode.init(rawValue:)) ?? .now
        if let until = pausedUntil { Log.notice(.pause, "pause until \(Self.clock(until)), \(pauseMode.rawValue) (kept from the last run)") }
        if let day = defaults.object(forKey: "todayDate") as? Date, Calendar.current.isDateInToday(day) {
            finishedToday = defaults.integer(forKey: "todayCount")
        }

        // Every encode runs in its own process: ProRes at nice 19 (ProcessEncoder), the queue's
        // normal jobs at nice 19 under the utility QoS clamp, which the worker sets itself
        // (WorkerProcess), so whatever the user does comes first; only a Sofort job runs at the
        // worker's normal priority. The app itself keeps its normal priority for the loopback.
        // Not the `background` QoS, which keeps work on the efficiency cores (docs/traps.md).
        let jobs = ProResJobs(root: Paths.jobs, encoder: ProcessEncoder.make(cli: Paths.helper("slipstream-cli")))
        self.jobs = jobs
        Task {
            await jobs.observe { status in
                Task { @MainActor [weak self] in self?.proresChanged(status) }
            }
            do {
                try await jobs.load()
                await jobs.cleanUp()
                try await startLoopback(jobs)
            } catch {
                Log.fault(.extension, "the loopback for the Funkhaus does not start: \(error.localizedDescription)")
                problem = "Der lokale Dienst für das Funkhaus startet nicht: \(error.localizedDescription)"
            }
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { await jobs.cleanUp() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleWorkerCPU() }
        })
        startWorker()
    }

    private func startLoopback(_ jobs: ProResJobs) async throws {
        let token = LoopbackAnnouncement.newToken()
        let pairing = AppPairing { [weak self] _ in
            await MainActor.run { self?.restartWorker() }
        }
        let box = siteBox
        let api = LoopbackAPI(token: token, version: version, name: AppPairing.macName, jobs: jobs, pairing: pairing,
                              site: { box.origin },
                              seen: { Task { @MainActor [weak self] in self?.markExtensionSeen() } })
        let server = LoopbackServer(api: api)
        let port = try await server.start()
        self.server = server
        let note = LoopbackAnnouncement(port: port, token: token, pid: getpid(), version: version, name: AppPairing.macName)
        try FileManager.default.createDirectory(at: Paths.appGroup, withIntermediateDirectories: true)
        let file = Paths.appGroup.appendingPathComponent(SlipstreamIDs.loopbackFile)
        try JSONEncoder().encode(note).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        Log.notice(.extension, "loopback on 127.0.0.1:\(port)")
    }

    // MARK: - The worker

    /// Why the worker is not running, for the menu ("Encoder gestoppt: …"); nil while it runs
    /// and has said something since it started.
    @Published private(set) var workerStopped: String?
    /// When the app starts it again (WorkerRestart).
    @Published private(set) var workerNextStart: Date?
    private var workerStops = 0
    private var workerStartedAt: Date?
    private var pendingStart: DispatchWorkItem?

    private func startWorker() {
        pendingStart?.cancel()
        pendingStart = nil
        workerNextStart = nil
        // One worker per key: two workers on one WireGuard key fight over the tunnel.
        guard worker == nil, !quitting else { return }
        guard AppPairing.storedTunnel() != nil else {
            Log.notice(.tunnel, "not paired: no worker")
            connection = .notPaired
            return
        }
        guard WorkerProcess.isPresent else {
            Log.warning(.worker, "this build carries no worker")
            connection = .noWorker
            return
        }
        do {
            let key = try KeyStore.loadOrCreate()
            let box = WorkerBox()
            let worker = WorkerProcess(onEvent: { event in
                Task { @MainActor [weak self] in
                    guard let self, self.worker?.id == box.id else { return }
                    self.handle(event)
                }
            }, onExit: { reason in
                Task { @MainActor [weak self] in self?.workerExited(id: box.id, reason) }
            })
            box.id = worker.id
            eventLog.reset()
            try worker.start(key: key, limits: limits, version: version)
            self.worker = worker
            workerStartedAt = Date()
            connection = .down
            note("worker started, pid \(worker.pid)")
            if let until = pausedUntil { worker.send(.pause(until: until, mode: pauseMode)) }
        } catch {
            connection = .down
            stopped("Der Worker startet nicht: \(error.localizedDescription)", ranFor: 0)
        }
    }

    /// A line about the worker's life, at notice level, which the unified log keeps.
    private func note(_ line: String) {
        Log.notice(.worker, line)
    }

    /// The worker is gone or did not start: say why in the menu and start it again later,
    /// sooner after a worker that had run for a while (WorkerRestart).
    private func stopped(_ reason: String, ranFor seconds: TimeInterval) {
        workerStops = WorkerRestart.stops(previous: workerStops, ranFor: seconds)
        let delay = WorkerRestart.delay(afterStops: workerStops)
        workerStopped = reason
        workerNextStart = Date().addingTimeInterval(delay)
        Log.error(.worker, "worker stopped after \(WorkerEventLog.duration(seconds)): \(reason); stop \(workerStops) in a row, next start in \(WorkerEventLog.duration(delay))")
        pendingStart?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.worker == nil, !self.quitting else { return }
            self.startWorker()
        }
        pendingStart = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private var restarting: Task<Void, Never>?

    /// Pairing again restarts the worker with the new tunnel. Restarts run one after another,
    /// so two quick pairings never leave two workers on one key.
    func restartWorker() {
        let previous = restarting
        restarting = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let old = self.worker
            self.worker = nil
            await old?.quit(timeout: 10)
            // A new pairing is a new start: no backoff from earlier stops.
            self.workerStops = 0
            self.startWorker()
        }
    }

    private func workerExited(id: UUID?, _ reason: String) {
        guard let current = worker, current.id == id, !current.isRunning else { return }
        worker = nil
        if quitting { note("worker ended at quit: \(reason)") }
        queueJobs.clear()
        workerLimits = nil
        connection = .down
        keepAwake(false)
        guard !quitting else { return }
        stopped(reason, ranFor: workerStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func handle(_ event: WorkerEvent) {
        for record in eventLog.lines(for: event) { Log.write(record) }
        // A worker that speaks runs: the menu stops saying why the last one stopped.
        if workerStopped != nil, !isLogLine(event) { workerStopped = nil }
        switch event {
        case .connection(let up, let lastAnswerAt, let refused):
            connection = up ? .up : .down
            lastAnswer = lastAnswerAt ?? (up ? Date() : lastAnswer)
            self.refused = refused
        case .job(let job):
            queueJobs.update(job)
            keepAwake(true)
        case .idle:
            queueJobs.clear()
            keepAwake(proresJob != nil)
        case .log:
            break // logged above (WorkerEventLog)
        case .result(let leaseId, let title, let verdict, let check):
            if let leaseId { queueJobs.end(lease: leaseId) }
            addResult(ResultLine(title: title, verdict: verdict, check: check, at: Date()))
        case .paused(let until, let mode):
            setPause(until, mode: mode ?? .now, source: nil)
        case .update(let latest):
            updateAvailable = latest
        case .tools(let tools):
            self.tools = tools
        case .model(let m):
            if let i = models.firstIndex(where: { $0.sha256 == m.sha256 }) {
                models[i] = m
            } else {
                models.append(m)
            }
        case .points(let p):
            points = p
        case .limits(let l):
            workerLimits = l
        }
    }

    // MARK: - ProRes

    /// Each ProRes job's phase and tenth last logged, by upload id.
    private var proresLogged: [String: (phase: JobStatus.Phase, tenth: Int)] = [:]

    private func logProres(_ status: JobStatus) {
        let id = "\(status.name) (\(status.uploadId))"
        let tenth = min(10, Int((status.fraction * 10).rounded(.down)))
        let before = proresLogged[status.uploadId]
        let took = WorkerEventLog.duration(Date().timeIntervalSince(status.createdAt))
        if before?.phase != status.phase {
            switch status.phase {
            case .ready:
                Log.notice(.encode, "ProRes \(id): ready after \(took)" + (status.intermediate.map { ", \($0.width)×\($0.height) \($0.codec), \($0.size) bytes" } ?? ""))
            case .failed:
                Log.error(.encode, "ProRes \(id): failed after \(took): \(status.error.map { "\($0.code): \($0.message)" } ?? "no reason")")
            case .receiving, .queued:
                Log.info(.encode, "ProRes \(id): \(status.phase.rawValue), \(status.size) bytes")
            case .encoding, .checking:
                Log.notice(.encode, "ProRes \(id): \(status.phase.rawValue) after \(took)")
            }
        } else if status.phase == .encoding, tenth > (before?.tenth ?? 0) {
            var text = "ProRes \(id): \(tenth * 10) %"
            if let fps = status.fps { text += String(format: " (%.1f fps)", fps) }
            Log.info(.encode, text)
        }
        proresLogged[status.uploadId] = status.phase == .ready || status.phase == .failed ? nil : (status.phase, tenth)
    }

    private func proresChanged(_ status: JobStatus) {
        logProres(status)
        switch status.phase {
        case .encoding, .checking:
            proresJob = status
            keepAwake(true)
        case .ready, .failed:
            if proresJob?.uploadId == status.uploadId {
                proresJob = nil
                addResult(ResultLine(title: "ProRes: \(status.name)",
                                     verdict: status.phase == .ready ? "fertig" : "fehlgeschlagen",
                                     check: status.error?.message, at: Date()))
            }
            keepAwake(queueJob != nil)
        default:
            break
        }
    }

    // MARK: - Pause

    func pause(for seconds: TimeInterval, mode: PauseMode) {
        setPause(Date().addingTimeInterval(seconds), mode: mode, source: "menu")
    }

    /// "Sofort anhalten" during a pause after the job: the same pause, now.
    func pauseNow() {
        guard let until = pausedUntil else { return }
        setPause(until, mode: .now, source: "menu, stop the running job now")
    }

    func resume() {
        setPause(nil, mode: .now, source: "menu")
    }

    /// `source`: who paused, for the log ("menu"); nil for the worker's own word, which is not
    /// sent back to it.
    private func setPause(_ until: Date?, mode: PauseMode, source: String?) {
        let tellWorker = source != nil
        let changed = until != pausedUntil || mode != pauseMode
        pausedUntil = until
        pauseMode = until == nil ? .now : mode
        if !previewing { // the defaults are the running Slipstream's
            defaults.set(until, forKey: "pausedUntil")
            defaults.set(pauseMode.rawValue, forKey: "pauseMode")
        }
        guard tellWorker else { return }
        // In the log file too (Thorsten, 2026-10-28: "Pause also wasn't working", and nothing
        // said whether the menu's pause reached the worker). The worker's answer is its own line
        // (WorkerEventLog).
        if changed { Log.notice(.pause, (until.map { "pause until \(Self.clock($0)), \(mode.rawValue)" } ?? "resume") + " (\(source!))") }
        if worker == nil, until != nil { Log.notice(.pause, "no worker running: the pause waits for its start") }
        worker?.send(until.map { .pause(until: $0, mode: mode) } ?? .resume)
    }

    /// Kerne and CPU % in the menu bar: the worker's and its tools' CPU, to a tenth of a core.
    private func sampleWorkerCPU() {
        guard menuBarItems.items.contains(.cores) || menuBarItems.items.contains(.cpu), let worker, worker.isRunning else {
            if workerCores != nil { workerCores = nil }
            return
        }
        let cores = workerCPU.sample(worker.pid).map { ($0 * 10).rounded() / 10 }
        if cores != workerCores { workerCores = cores }
    }

    private func tick() {
        let marker = Paths.appGroup.appendingPathComponent(SlipstreamIDs.extensionSeenFile)
        if let at = (try? FileManager.default.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date {
            markExtensionSeen(at)
        }
        if let until = pausedUntil, until <= Date() {
            Log.notice(.pause, "pause until \(Self.clock(until)) is over")
            setPause(nil, mode: .now, source: nil)
        }
        // A job that ends beside another sends no event of its own (RunningJobs).
        var jobs = queueJobs
        if jobs.expire() {
            queueJobs = jobs
            keepAwake(!jobs.isEmpty || proresJob != nil)
        }
    }

    // MARK: - Bits

    private func addResult(_ line: ResultLine) {
        results.insert(line, at: 0)
        results = Array(results.prefix(10))
        if line.verdict == "accepted" || line.verdict == "fertig" {
            if let day = defaults.object(forKey: "todayDate") as? Date, !Calendar.current.isDateInToday(day) {
                finishedToday = 0
            }
            finishedToday += 1
            defaults.set(Date(), forKey: "todayDate")
            defaults.set(finishedToday, forKey: "todayCount")
        }
    }

    private func isLogLine(_ e: WorkerEvent) -> Bool {
        if case .log = e { return true }
        return false
    }

    /// A menu line the menu cut (MenuLine), whole in the log once.
    func logCutLine(_ line: String) {
        guard cutLogged.insert(line).inserted else { return }
        Log.info(.app, "menu line, whole: \(line)")
    }

    private var cutLogged: Set<String> = []

    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// The Mac stays awake while Slipstream holds a job (ADR-0007 §3).
    private func keepAwake(_ on: Bool) {
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                          reason: "Slipstream arbeitet an einem Auftrag")
        } else if !on, let token = awake {
            ProcessInfo.processInfo.endActivity(token)
            awake = nil
        }
    }

    #if DEBUG
    /// `-menuPreview YES`, Debug builds only: the menu with two jobs side by side, results and
    /// points, to look at it beside a running Slipstream (AGENTS.md). Nothing starts (no loopback,
    /// no worker), and the app group file and the counts stay the running Slipstream's.
    func preview() {
        // "Beenden" ends it at once: shutDown would remove the running Slipstream's loopback file.
        quitting = true
        previewing = true
        Log.mute()
        let now = Date()
        site = SiteConfig(host: "funkhaus.example.org", name: "Funkhaus", protocol: 1)
        threadsSetting = 3
        extensionSeen = UserDefaults.standard.bool(forKey: "menuPreviewNoExtension") ? nil : now.addingTimeInterval(-120)
        let events = [
            #"{"event":"connection","up":true}"#,
            #"{"event":"job","lease_id":"a","title":"one_144_Hey_Siri","kind":"rung","rung":"2160","slot":"normal","phase":"encoding","fraction":0.12,"fps":9.4,"speed":0.38,"eta_s":1260}"#,
            #"{"event":"job","lease_id":"b","title":"Folge 12","kind":"whisper","slot":"high","phase":"encoding","fraction":0.57,"speed":31.2,"eta_s":40}"#,
            #"{"event":"points","table":"v1","today":1240,"week":5310,"total":20450,"rank":1,"of":3}"#,
            #"{"event":"limits","threads":3,"cores":12,"throttled":1}"#,
        ]
        for line in events {
            if let event = WorkerEvent.parse(line) { handle(event) }
        }
        let path = "/Users/someone/Library/Application Support/Slipstream/worker/work/ls_01M61102GCZ50V2N2WVXTBDWGA/input-captions"
        results = [
            ResultLine(title: "one_143_Siri_Pro", verdict: "given_back", check: "preempted", at: now.addingTimeInterval(-300)),
            ResultLine(title: "Untertitel #529", verdict: "rejected", check: "other: the captions' path \"\(path)\" cannot go into a filter",
                       at: now.addingTimeInterval(-1500)),
            ResultLine(title: "one_142_Watch_Ultra", verdict: "accepted", check: nil, at: now.addingTimeInterval(-2400)),
            ResultLine(title: "ProRes: Interview_A.mov", verdict: "fertig", check: nil, at: now.addingTimeInterval(-4000)),
        ]
        finishedToday = 7
        workerCores = 2.9
        if UserDefaults.standard.bool(forKey: "menuPreviewPaused") { setPause(now.addingTimeInterval(2 * 3600), mode: .now, source: nil) }
        // The first job's event once a second, as a running encode sends it, so the menu sees
        // what it sees beside a real job: a pause clicked while the model changes.
        var fraction = 0.12
        guard UserDefaults.standard.object(forKey: "menuPreviewTicker") == nil || UserDefaults.standard.bool(forKey: "menuPreviewTicker") else { return }
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            fraction = min(1, fraction + 0.001)
            let line = #"{"event":"job","lease_id":"a","title":"one_144_Hey_Siri","kind":"rung","rung":"2160","slot":"normal","phase":"encoding","fps":9.4,"speed":0.38,"eta_s":1260,"fraction":"#
                + String(fraction) + "}"
            Task { @MainActor in
                if let event = WorkerEvent.parse(line) { self?.handle(event) }
            }
        })
    }
    #endif

    /// The Debug menu preview (-menuPreview): nothing it does reaches the defaults or the log file,
    /// which are the running Slipstream's.
    private var previewing = false

    // MARK: - Quit

    private(set) var quitting = false

    /// True while a job would be lost or given back by quitting.
    var isBusy: Bool { queueJob != nil || proresJob != nil }

    /// Gives the queue job back so the next worker starts at once, then lets the app go. A
    /// ProRes job stays on disk and starts again at the next launch.
    func shutDown() async {
        quitting = true
        Log.notice(.app, "quit" + (queueJob != nil ? ": giving the queue job back" : "") + (proresJob != nil ? ": the ProRes job starts again at the next launch" : ""))
        server?.stop()
        try? FileManager.default.removeItem(at: Paths.appGroup.appendingPathComponent(SlipstreamIDs.loopbackFile))
        await worker?.quit(timeout: 15)
        keepAwake(false)
    }
}
