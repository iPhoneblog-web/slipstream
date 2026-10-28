import Foundation

/// What changed in a version, for the people who use it (Thorsten, 2026-10-28: "Are we using
/// Sparkle properly? I'm not seeing "What's new" in some places."): `release-notes/<version>.md`,
/// a few German bullets. Sparkle's update dialog shows them from the appcast, the GitHub release
/// above its install steps, and the app in "Neu in …" after an update and in "Über Slipstream".
public struct ReleaseNotes: Equatable, Sendable {
    public var version: String
    public var bullets: [String]

    /// The bullets of `markdown`: a line starting with "- " opens one, a line indented by two
    /// spaces continues it, every other line (a heading, a blank) is left out. Nil without a bullet.
    public init?(version: String, markdown: String) {
        var bullets: [String] = []
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("- ") {
                bullets.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("  "), !bullets.isEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                bullets[bullets.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            }
        }
        guard !bullets.isEmpty else { return nil }
        (self.version, self.bullets) = (version, bullets)
    }

    /// For the appcast's `<description>`: a list, escaped, `**fett**` as `<b>`. It never holds
    /// "]]>", so it fits a CDATA section.
    public var html: String {
        "<ul>\n" + bullets.map { "<li>" + Self.bold(Self.escape($0), open: "<b>", close: "</b>") + "</li>\n" }.joined() + "</ul>\n"
    }

    /// For the GitHub release: the bullets as Markdown, under a heading.
    public var markdown: String {
        "**Neu in \(version)**\n\n" + bullets.map { "- \($0)\n" }.joined()
    }

    /// For the app's windows: the bullets with "•", `**fett**` as plain text.
    public var plain: [String] { bullets.map { "• " + $0.replacingOccurrences(of: "**", with: "") } }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// `**fett**` between `open` and `close`; a text with an odd marker stays as it was.
    static func bold(_ s: String, open: String, close: String) -> String {
        let parts = s.components(separatedBy: "**")
        guard parts.count >= 3, parts.count % 2 == 1 else { return s }
        return parts.enumerated().map { i, p in i == 0 ? p : (i % 2 == 1 ? open : close) + p }.joined()
    }

    /// The notes of every `<version>.md` in `dir`, newest first; a file without a bullet is left out.
    public static func load(from dir: URL) -> [ReleaseNotes] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> ReleaseNotes? in
            guard name.hasSuffix(".md") else { return nil }
            let version = String(name.dropLast(3))
            guard parts(version) != nil, let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else {
                return nil
            }
            return ReleaseNotes(version: version, markdown: text)
        }
        .sorted { isNewer($0.version, than: $1.version) }
    }

    /// "1.3.10" is newer than "1.3.9"; a version that is not three numbers is newer than none.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parts(a), let y = parts(b) else { return false }
        return y.lexicographicallyPrecedes(x)
    }

    static func parts(_ v: String) -> [Int]? {
        let p = v.split(separator: ".").compactMap { Int($0) }
        return p.count == 3 && v.split(separator: ".").count == 3 ? p : nil
    }

    /// What "Neu in …" shows after an update: the notes of every version newer than `lastSeen`,
    /// up to `current`, newest first. Without `lastSeen` (the first release with "Neu in", or a
    /// first launch) only a Mac that ran Slipstream before (`ranBefore`) sees the current
    /// version's notes; a new one sees none.
    public static func new(in notes: [ReleaseNotes], current: String, lastSeen: String?, ranBefore: Bool) -> [ReleaseNotes] {
        guard let lastSeen else {
            return ranBefore ? notes.filter { $0.version == current } : []
        }
        return notes.filter { isNewer($0.version, than: lastSeen) && !isNewer($0.version, than: current) }
    }
}
