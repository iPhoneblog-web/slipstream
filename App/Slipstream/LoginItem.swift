import Foundation
import os
import ServiceManagement

/// "Bei der Anmeldung starten": the app as a login item (`SMAppService.mainApp`). macOS shows it
/// in System Settings → Allgemein → Anmeldeobjekte, where the user can turn it off too, so the
/// state is always read from there, never stored here.
enum LoginItem {
    private static let log = Logger(subsystem: "io.github.kyrios.slipstream", category: "login")

    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !on, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
