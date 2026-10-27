import Foundation
import os
import ServiceManagement

/// "Bei der Anmeldung starten": the app as a login item (`SMAppService.mainApp`). macOS shows it
/// in System Settings → Allgemein → Anmeldeobjekte, where the user can turn it off too, so the
/// state is always read from there, never stored here.
///
/// Every call asks the background task daemon over XPC: about 0.5 s per call on a Mac Studio
/// (2026-10-28), more on a Mac with many login items. In 1.3.0 Settings read it on the main
/// thread and froze for seconds per click (docs/traps.md, "A frozen Settings window"); so it is
/// async only and runs off the main thread.
enum LoginItem {
    private static let log = Logger(subsystem: "io.github.kyrios.slipstream", category: "login")

    static func isOn() async -> Bool {
        await Task.detached(priority: .userInitiated) { SMAppService.mainApp.status == .enabled }.value
    }

    /// Turns it on or off and returns the state macOS then reports.
    @discardableResult
    static func set(_ on: Bool) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let service = SMAppService.mainApp
            do {
                if on, service.status != .enabled {
                    try service.register()
                } else if !on, service.status == .enabled {
                    try service.unregister()
                }
            } catch {
                log.error("login item: \(error.localizedDescription, privacy: .public)")
            }
            return service.status == .enabled
        }.value
    }
}
