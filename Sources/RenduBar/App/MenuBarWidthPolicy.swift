import Foundation

/// The caller measures the actual AppKit font. Grapheme counts alone cannot bound point width.
enum MenuBarWidthPolicy {
    static func fit(_ title: String, maximumWidth: CGFloat = 260, reservedWidth: CGFloat,
                    measure: (String) -> CGFloat) -> String {
        guard maximumWidth.isFinite, reservedWidth.isFinite else { return "" }
        let budget = max(0, maximumWidth - max(0, reservedWidth))
        func fits(_ text: String) -> Bool {
            let width = measure(text)
            return width.isFinite && width >= 0 && ceil(width) <= budget
        }
        if fits(title) { return title }
        guard fits("…") else { return "" }
        let characters = Array(title)
        guard characters.count > 1 else { return "…" }
        for kept in stride(from: characters.count - 1, through: 1, by: -1) {
            let left = (kept + 1) / 2, right = kept / 2
            let candidate = String(characters.prefix(left)) + "…" + String(characters.suffix(right))
            if fits(candidate) { return candidate }
        }
        return "…"
    }
}
