import Foundation
import XCTest
@testable import HelperCore

/// Release notes (Thorsten, 2026-10-28: "Are we using Sparkle properly? I'm not seeing "What's
/// new" in some places."): parsed, as HTML for the appcast, and which ones "Neu in …" shows.
final class ReleaseNotesTests: XCTestCase {
    func testBulletsAndTheirContinuations() throws {
        let n = try XCTUnwrap(ReleaseNotes(version: "1.3.6", markdown: """
            # Slipstream 1.3.6

            - **Pause** hat zwei Wege:
              „Sofort pausieren“ oder „Nach diesem Auftrag“.
            Eine Zeile ohne Strich gehört zu nichts.
            - Zweiter Punkt.
            """))
        XCTAssertEqual(n.bullets, ["**Pause** hat zwei Wege: „Sofort pausieren“ oder „Nach diesem Auftrag“.", "Zweiter Punkt."])
        XCTAssertEqual(n.plain.first, "• Pause hat zwei Wege: „Sofort pausieren“ oder „Nach diesem Auftrag“.")
        XCTAssertEqual(n.markdown, "**Neu in 1.3.6**\n\n- **Pause** hat zwei Wege: „Sofort pausieren“ oder „Nach diesem Auftrag“.\n- Zweiter Punkt.\n")
        // The guard: a file without a bullet is no notes.
        XCTAssertNil(ReleaseNotes(version: "1.3.7", markdown: "# Slipstream 1.3.7\n\nNoch nichts.\n"))
    }

    /// The appcast's description sits in CDATA: escaped, bold as <b>, never "]]>".
    func testHTML() throws {
        let n = try XCTUnwrap(ReleaseNotes(version: "1.0.0", markdown: "- **A** & <b> ]]> x\n- ein ** allein"))
        XCTAssertEqual(n.html, "<ul>\n<li><b>A</b> &amp; &lt;b&gt; ]]&gt; x</li>\n<li>ein ** allein</li>\n</ul>\n")
        XCTAssertFalse(n.html.contains("]]>"))
    }

    func testVersionsCompareAsNumbers() {
        XCTAssertTrue(ReleaseNotes.isNewer("1.3.10", than: "1.3.9"))
        XCTAssertTrue(ReleaseNotes.isNewer("2.0.0", than: "1.9.9"))
        XCTAssertFalse(ReleaseNotes.isNewer("1.3.6", than: "1.3.6"))
        XCTAssertFalse(ReleaseNotes.isNewer("1.3", than: "1.2.9"))
    }

    /// "Neu in …" after an update: every version since the last one seen; nothing on a new Mac,
    /// the same version or a step back; this version's on a Mac from before "Neu in" existed.
    func testWhatNeuInShows() {
        let all = ["1.3.6", "1.3.5", "1.3.4"].map { ReleaseNotes(version: $0, markdown: "- \($0)")! }
        func new(_ current: String, _ seen: String?, ranBefore: Bool = true) -> [String] {
            ReleaseNotes.new(in: all, current: current, lastSeen: seen, ranBefore: ranBefore).map(\.version)
        }
        XCTAssertEqual(new("1.3.6", "1.3.4"), ["1.3.6", "1.3.5"])
        XCTAssertEqual(new("1.3.6", "1.3.6"), [])
        XCTAssertEqual(new("1.3.5", "1.3.6"), [])
        XCTAssertEqual(new("1.3.6", nil, ranBefore: false), []) // a new Mac
        XCTAssertEqual(new("1.3.6", nil), ["1.3.6"])          // updated from a version without it
        XCTAssertEqual(new("1.3.7", "1.3.5"), ["1.3.6"])      // no notes for 1.3.7: none of its own
    }

    func testLoadSkipsWhatIsNoVersion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, text) in [("1.3.9.md", "- neun"), ("1.3.10.md", "- zehn"), ("README.md", "- kein"), ("1.4.md", "- kurz"),
                             ("1.3.8.md", "nichts")] {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(ReleaseNotes.load(from: dir).map(\.version), ["1.3.10", "1.3.9"])
    }

    /// The repository's own notes: every version's file has a bullet, and 1.3.4 to 1.3.6 are there.
    func testTheRepositorysNotes() {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("release-notes")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.first?.isNumber == true }
        let notes = ReleaseNotes.load(from: dir)
        XCTAssertEqual(notes.count, files.count, "a version's file without a bullet: \(files)")
        XCTAssertTrue(Set(notes.map(\.version)).isSuperset(of: ["1.3.4", "1.3.5", "1.3.6"]))
    }
}
