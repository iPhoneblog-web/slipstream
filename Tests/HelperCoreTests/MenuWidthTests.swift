import AppKit
import XCTest
@testable import HelperCore

/// The menu stays about as wide as "CPU für den Encoder: 12 von 12 Kernen" (Thorsten, 2026-10-28
/// 20:08: "The Slipstream window is still far too wide", 800 pt for one Safari line). Every line
/// the app makes goes through MenuLine.fit; these are the fixed ones and the longest made ones,
/// measured in the menu's own font.
final class MenuWidthTests: XCTestCase {
    private func measure(_ s: String) -> Double {
        Double((s as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width)
    }

    func testEveryLineFitsTheMenu() {
        let lines = [
            CPUChoice.menuTitle(setting: 12, cores: 12, inEffect: nil),
            CPUChoice.menuTitle(setting: 11, cores: 12, inEffect: .init(threads: 11, cores: 12, throttled: 1)),
            CPUChoice.menuTitle(setting: 23, cores: 24, inEffect: .init(threads: 23, cores: 24, throttled: 1)),
            CPUChoice.menuTitle(setting: 12, cores: 12, inEffect: .init(threads: 12, cores: 12, efficiency: "all")),
            "Laufender Auftrag gedrosselt", "Archiv-Aufträge nur auf Effizienzkernen",
            CPUChoice.options(cores: 12, efficiencyCores: 4, slowdown: 11).last!.label,
            "Safari-Extension: noch nicht verbunden", "Safari-Extension: verbunden, zuletzt 20:01",
            "Funkhaus in Safari öffnen", "Erscheint dann nichts:", "Safari → Einstellungen → Erweiterungen",
            "„Slipstream“ anhaken und für", "Safari-Erweiterungen öffnen …",
            "Fortsetzen (Pause bis 20:00)", "Laufenden Auftrag sofort anhalten",
            PauseMode.stateLine(until: "20:00", mode: .afterJob, jobsRunning: true),
            "Keine Verbindung zum Encoder", "Encoder gestoppt, neuer Versuch 20:01", "Verbindung: Encoder gestoppt",
            "Tunnel verbunden, letzte Antwort 20:01", "Nicht gekoppelt (nur ProRes)",
            WorkerEvent.Points(today: 123_456, rank: 10, of: 12).line,
        ] + CPUChoice.efficiencyNoteLines
        for line in lines {
            XCTAssertLessThanOrEqual(measure(line), MenuLine.width, line)
        }
        // A made line too long (an error, a job title, a host) is cut to the width.
        let long = "Der lokale Dienst für das Funkhaus startet nicht: The operation couldn’t be completed. (NSPOSIXErrorDomain error 48 - Address already in use)"
        XCTAssertLessThanOrEqual(measure(MenuLine.fit(long, measure: measure)), MenuLine.width)
        let title = WorkerJob(leaseId: "l", title: "iphoneblog_one_144_hey_siri_mit_einem_sehr_langen_titel", kind: "rung", phase: "encoding", fraction: 0.12)
        let cut = MenuLine.fit(title.menuTitle, keeping: title.menuShare, measure: measure)
        XCTAssertLessThanOrEqual(measure(cut), MenuLine.width)
        XCTAssertTrue(cut.hasSuffix(" · 12 %"), cut)
    }
}
