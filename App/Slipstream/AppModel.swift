import AppKit
import Foundation
import HelperCore
import os

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
    @Published private(set) var queueJob: WorkerJob?
    @Published private(set) var proresJob: JobStatus?
    @Published private(set) var results: [ResultLine] = []
    @Published private(set) var finishedToday = 0
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var logLines: [String] = []
    @Published private(set) var tools: [WorkerEvent.Tool] = []
    @Published private(set) var updateAvailable: String?
    @Published private(set) var problem: String?
    /// When Safari's extension last reached this app since it started: the app extension's
    /// presence check, or a bridge request with the token. Nil: not since the start.
    @Published private(set) var extensionSeen: Date?

    private let startedAt = Date()
    private let windows = Windows()

    /// The Funkhaus site this Mac works for; nil until the setup window checked one.
    @Published private(set) var site: SiteConfig?
    /// The site for the loopback's check, read on its own queue.
    private let siteBox = SiteBox()

    func showSetup() {
        windows.show("setup", title: "Slipstream einrichten", size: nil) {
            SetupView(model: self)
        }
    }

    /// The setup window's check: the host, its `/.well-known/funkhaus.json`, then the app group.
    func checkSite(_ input: String) async -> String? {
        let host: String
        do { host = try SiteConfig.host(from: input) } catch {
            return (error as? SiteConfig.Problem)?.message ?? error.localizedDescription
        }
        guard let wellKnown = SiteConfig.wellKnown(host) else { return SiteConfig.Problem.badHost.message }
        var request = URLRequest(url: wellKnown, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url?.host == host.split(separator: ":").first.map(String.init) else {
                return SiteConfig.Problem.notFunkhaus("keine Antwort unter /.well-known/funkhaus.json").message
            }
            data = body
        } catch {
            log.info("setup: \(host, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return SiteConfig.unreachable(host, (error as? URLError)?.code)
        }
        do {
            let found = try SiteConfig.check(host: host, wellKnown: data, appVersion: version)
            try found.save(to: Paths.appGroup)
            setSite(found)
            log.info("site set up: \(found.host, privacy: .public)")
            return nil
        } catch {
            return (error as? SiteConfig.Problem)?.message ?? error.localizedDescription
        }
    }

    private func setSite(_ s: SiteConfig?) {
        site = s
        siteBox.origin = s?.origin
    }

    func openSite() {
        if let url = site?.url { NSWorkspace.shared.open(url) } else { showSetup() }
    }

    func showSettings() {
        windows.show("settings", title: "Slipstream – Einstellungen", size: NSSize(width: 460, height: 380)) {
            SettingsView(model: self)
        }
    }

    func showLog() {
        windows.show("log", title: "Slipstream – Protokoll", size: NSSize(width: 720, height: 420), resizable: true) {
            LogView(model: self)
        }
    }

    func markExtensionSeen(_ at: Date = Date()) {
        guard at >= startedAt else { return }
        if extensionSeen.map({ at > $0 }) ?? true { extensionSeen = at }
    }

    static let releases = URL(string: "https://github.com/kyrios/slipstream/releases/latest")!

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    private let log = Logger(subsystem: SlipstreamIDs.logSubsystem, category: "app")
    private let defaults = UserDefaults.standard
    private var jobs: ProResJobs?
    private var server: LoopbackServer?
    private var worker: WorkerProcess?
    private var awake: NSObjectProtocol?
    private var timers: [Timer] = []

    // MARK: - Settings (Settings window)

    static let maxThreads = ProcessInfo.processInfo.activeProcessorCount

    var limits: WorkerProcess.Limits {
        let threads = defaults.integer(forKey: "threads")
        return WorkerProcess.Limits(threads: threads > 0 ? min(threads, Self.maxThreads) : Self.maxThreads,
                                    gpu: defaults.object(forKey: "gpu") as? Bool ?? true,
                                    jobs: max(1, defaults.integer(forKey: "jobs")))
    }

    func limitsChanged() {
        let l = limits
        worker?.send(.limits(threads: l.threads, gpu: l.gpu, jobs: l.jobs))
    }

    // MARK: - Start

    func start() {
        setSite(SiteConfig.load(from: Paths.appGroup))
        // No site, no working app: the first launch asks for one (docs/extension-protocol.md, 4).
        if site == nil { showSetup() }
        pausedUntil = (defaults.object(forKey: "pausedUntil") as? Date).flatMap { $0 > Date() ? $0 : nil }
        if let day = defaults.object(forKey: "todayDate") as? Date, Calendar.current.isDateInToday(day) {
            finishedToday = defaults.integer(forKey: "todayCount")
        }

        // Every encode runs in its own process at nice 19 (ProcessEncoder, WorkerProcess), so
        // whatever the user does comes first, and the app itself keeps its normal priority for the
        // loopback. Not the `background` QoS, which keeps work on the efficiency cores
        // (docs/traps.md).
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
                log.error("start: \(error.localizedDescription, privacy: .public)")
                problem = "Der lokale Dienst für das Funkhaus startet nicht: \(error.localizedDescription)"
            }
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { await jobs.cleanUp() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
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
        log.info("loopback on 127.0.0.1:\(port)")
    }

    // MARK: - The worker

    private func startWorker() {
        // One worker per key: two workers on one WireGuard key fight over the tunnel.
        guard worker == nil, !quitting else { return }
        guard AppPairing.storedTunnel() != nil else { connection = .notPaired; return }
        guard WorkerProcess.isPresent else { connection = .noWorker; return }
        do {
            let key = try KeyStore.loadOrCreate()
            let box = WorkerBox()
            let worker = WorkerProcess(onEvent: { event in
                Task { @MainActor [weak self] in
                    guard let self, self.worker?.id == box.id else { return }
                    self.handle(event)
                }
            }, onExit: { status in
                Task { @MainActor [weak self] in self?.workerExited(id: box.id, status) }
            })
            box.id = worker.id
            try worker.start(key: key, limits: limits, version: version)
            self.worker = worker
            connection = .down
            if let until = pausedUntil { worker.send(.pause(until: until)) }
        } catch {
            log.error("worker: \(error.localizedDescription, privacy: .public)")
            problem = "Der Worker startet nicht: \(error.localizedDescription)"
            connection = .down
        }
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
            self.startWorker()
        }
    }

    private func workerExited(id: UUID?, _ status: Int32) {
        guard let current = worker, current.id == id, !current.isRunning else { return }
        log.error("worker exited with \(status)")
        worker = nil
        queueJob = nil
        connection = .down
        keepAwake(false)
        // Start it again a little later, unless the app is quitting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.worker == nil, !self.quitting else { return }
            self.startWorker()
        }
    }

    private func handle(_ event: WorkerEvent) {
        switch event {
        case .connection(let up, let lastAnswerAt, let refused):
            connection = up ? .up : .down
            lastAnswer = lastAnswerAt ?? (up ? Date() : lastAnswer)
            self.refused = refused
        case .job(let job):
            queueJob = job
            keepAwake(true)
        case .idle:
            queueJob = nil
            keepAwake(proresJob != nil)
        case .log(_, let line):
            appendLog(line)
        case .result(let title, let verdict, let check):
            addResult(ResultLine(title: title, verdict: verdict, check: check, at: Date()))
        case .paused(let until):
            setPause(until, tellWorker: false)
        case .update(let latest):
            updateAvailable = latest
        case .tools(let tools):
            self.tools = tools
        }
    }

    // MARK: - ProRes

    private func proresChanged(_ status: JobStatus) {
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

    func pause(for seconds: TimeInterval) {
        setPause(Date().addingTimeInterval(seconds), tellWorker: true)
    }

    func resume() {
        setPause(nil, tellWorker: true)
    }

    private func setPause(_ until: Date?, tellWorker: Bool) {
        pausedUntil = until
        defaults.set(until, forKey: "pausedUntil")
        if tellWorker { worker?.send(until.map { .pause(until: $0) } ?? .resume) }
    }

    private func tick() {
        let marker = Paths.appGroup.appendingPathComponent(SlipstreamIDs.extensionSeenFile)
        if let at = (try? FileManager.default.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date {
            markExtensionSeen(at)
        }
        if let until = pausedUntil, until <= Date() { setPause(nil, tellWorker: false) }
    }

    // MARK: - Bits

    private func addResult(_ line: ResultLine) {
        results.insert(line, at: 0)
        results = Array(results.prefix(3))
        if line.verdict == "accepted" || line.verdict == "fertig" {
            if let day = defaults.object(forKey: "todayDate") as? Date, !Calendar.current.isDateInToday(day) {
                finishedToday = 0
            }
            finishedToday += 1
            defaults.set(Date(), forKey: "todayDate")
            defaults.set(finishedToday, forKey: "todayCount")
        }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 1000 { logLines.removeFirst(logLines.count - 1000) }
    }

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

    // MARK: - Quit

    private(set) var quitting = false

    /// True while a job would be lost or given back by quitting.
    var isBusy: Bool { queueJob != nil || proresJob != nil }

    /// Gives the queue job back so the next worker starts at once, then lets the app go. A
    /// ProRes job stays on disk and starts again at the next launch.
    func shutDown() async {
        quitting = true
        server?.stop()
        try? FileManager.default.removeItem(at: Paths.appGroup.appendingPathComponent(SlipstreamIDs.loopbackFile))
        await worker?.quit(timeout: 15)
        keepAwake(false)
    }
}
