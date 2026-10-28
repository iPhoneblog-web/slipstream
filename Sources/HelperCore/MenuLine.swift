import Foundation

/// A line of the menu bar's menu at most `width` wide (Slipstream 1.3.3: one long error line, a
/// job's captions path, made the menu as wide as the screen). The cut keeps the start and puts
/// "…" at the end, or, for a line that names a path, keeps both ends and puts "…" in the middle:
/// the middle of a path says least, and the start (what failed) gets three fifths. The menu shows
/// the whole line as the item's tooltip.
public enum MenuLine {
    /// The menu's text width: about 420 pt of menu less its item padding.
    public static let width = 380.0

    /// `text` as it fits `width`, measured by `measure`; `text` itself when it fits.
    public static func fit(_ text: String, width: Double = width, measure: (String) -> Double) -> String {
        if measure(text) <= width { return text }
        let chars = Array(text)
        let middle = text.contains("/")
        var lo = 0, hi = chars.count
        while lo < hi {
            let n = (lo + hi + 1) / 2
            if measure(cut(chars, n, middle: middle)) <= width { lo = n } else { hi = n - 1 }
        }
        return cut(chars, lo, middle: middle)
    }

    /// `text`, which ends in `tail`, cut before the tail so the tail stays whole: a job's share,
    /// " · 12 %", when its title is long.
    public static func fit(_ text: String, keeping tail: String, width: Double = width, measure: (String) -> Double) -> String {
        guard measure(text) > width, text.hasSuffix(tail) else { return fit(text, width: width, measure: measure) }
        return fit(String(text.dropLast(tail.count)), width: width - measure(tail), measure: measure) + tail
    }

    private static func cut(_ c: [Character], _ n: Int, middle: Bool) -> String {
        if !middle {
            return String(c.prefix(n)).trimmingCharacters(in: .whitespaces) + "…"
        }
        let head = n * 3 / 5
        return String(c.prefix(head)) + "…" + String(c.suffix(n - head))
    }
}
