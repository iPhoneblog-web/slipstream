import AppKit
import HelperCore
import Sparkle

/// Updates with Sparkle (docs/release.md, "Updates"): once a day it reads the appcast that every
/// release publishes, and installs a release it signed with Slipstream's EdDSA key in place.
/// "Nach Updates suchen …" asks at once; so does "Update verfügbar", which the queue raises when
/// it wants a newer app. Each check and its outcome goes to the log (UpdateLog).
@MainActor
final class Updates {
    private let log = UpdateLog()
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: log, userDriverDelegate: nil)
    }

    var updater: SPUUpdater { controller.updater }

    func check() {
        Log.notice(.update, "check for updates (menu)")
        // A menu bar app is never active on its own; Sparkle's window would open behind others.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

/// Sparkle's word on each check, for the log. Sparkle holds its delegate weakly; `Updates` keeps it.
final class UpdateLog: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Log.info(.update, "appcast loaded: \(appcast.items.count) releases")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.notice(.update, "update found: \(item.displayVersionString) (build \(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey].map { " (reason \($0))" } ?? ""
        Log.info(.update, "no update: this version is the newest\(reason)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Log.notice(.update, "installing \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let e = error as NSError
        // Sparkle ends a check without an update by this error too; that is no failure.
        guard e.domain != SUSparkleErrorDomain || e.code != Int(SUError.noUpdateError.rawValue) else { return }
        Log.error(.update, "update check failed: \(e.localizedDescription) (\(e.domain) \(e.code))")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let kind = updateCheck == .updatesInBackground ? "scheduled" : "asked for"
        Log.info(.update, "update check done (\(kind))" + (error.map { ": \($0.localizedDescription)" } ?? ""))
    }

    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        Log.debug(.update, "next scheduled check in \(WorkerEventLog.duration(delay))")
    }
}
