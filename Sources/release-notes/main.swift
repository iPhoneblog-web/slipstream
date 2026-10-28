// The release notes of a version, for CI (docs/release.md, "Release notes"):
//   release-notes <version>              fail unless release-notes/<version>.md has a bullet
//   release-notes <version> <out-dir>    and write release-notes.html (the appcast's description)
//                                        and release-notes.md (the GitHub release's top) there
import Foundation
import HelperCore

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data("release-notes: \(s)\n".utf8))
    exit(1)
}

let a = CommandLine.arguments
guard a.count == 2 || a.count == 3 else { fail("usage: release-notes <version> [<out-dir>]") }
let version = a[1].hasPrefix("v") ? String(a[1].dropFirst()) : a[1]
let file = "release-notes/\(version).md"
guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
    fail("\(file) is missing: a release needs its notes (release-notes/README.md)")
}
guard let notes = ReleaseNotes(version: version, markdown: text) else { fail("\(file) has no bullet (\"- \")") }
if a.count == 3 {
    let out = URL(fileURLWithPath: a[2])
    do {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data(notes.html.utf8).write(to: out.appendingPathComponent("release-notes.html"))
        try Data(notes.markdown.utf8).write(to: out.appendingPathComponent("release-notes.md"))
    } catch {
        fail("cannot write \(out.path): \(error)")
    }
}
print("release-notes: \(version), \(notes.bullets.count) bullets")
