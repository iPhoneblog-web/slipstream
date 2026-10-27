import AppKit
import Sparkle

/// Updates with Sparkle (docs/release.md, "Updates"): once a day it reads the appcast that every
/// release publishes, and installs a release it signed with Slipstream's EdDSA key in place.
/// "Nach Updates suchen …" asks at once; so does "Update verfügbar", which the queue raises when
/// it wants a newer app.
@MainActor
final class Updates {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                         userDriverDelegate: nil)

    var updater: SPUUpdater { controller.updater }

    func check() {
        // A menu bar app is never active on its own; Sparkle's window would open behind others.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
