import Foundation

/// Text selected in a PDF, cleaned up for a quote card. PDF text breaks at every line, justified
/// English splits words across lines with a hyphen, and fonts often store "fi" as one ligature glyph.
enum QuoteText {
    static func normalize(_ text: String) -> String {
        var text = text
        for (ligature, letters) in ["ﬀ": "ff", "ﬁ": "fi", "ﬂ": "fl", "ﬃ": "ffi", "ﬄ": "ffl", "\u{00AD}": ""] {
            text = text.replacingOccurrences(of: ligature, with: letters)
        }
        var result = ""
        var previousEndedWithSpace = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let first = line.first else { continue }
            if let last = result.last {
                let startsWithSpace = raw.first?.isWhitespace == true
                if last == "-" {
                    // "inter-" + "action" → "interaction"; "Head-" + "Mounted" keeps its hyphen.
                    if result.dropLast().last?.isLetter == true, first.isLowercase { result.removeLast() }
                } else if previousEndedWithSpace || startsWithSpace || !(isCJK(last) || isCJK(first)) {
                    result += " "
                }
            }
            result += line
            previousEndedWithSpace = raw.last?.isWhitespace == true
        }
        return result.replacing(/[ \t]+/, with: " ")
    }

    /// `text` cut to at most `limit` characters, ending in "…" when cut.
    static func clipped(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    /// Han, kana, Hangul, bopomofo and CJK or full-width punctuation: scripts written without spaces
    /// between words, so a line break inside them must not become one.
    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return switch scalar {
        case 0x1100...0x11FF, 0x2E80...0x2FFF, 0x3000...0x9FFF, 0xAC00...0xD7AF,
             0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x3FFFF:
            true
        default:
            false
        }
    }
}
