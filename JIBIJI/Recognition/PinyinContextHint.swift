import Foundation

/// Pure context hint: does a Latin-letter region spell the (toneless) romanization of the Hanzi region just before
/// it? Uses Foundation's local "Han-Latin" transform only to *compare letters*. The generated romanization (and its
/// tones) is never shown or emitted as recognized text, and polyphonic mismatches (e.g. 银行 → yín xíng) simply
/// abstain. No recognizer, no word list, no AI service.
enum PinyinContextHint {
    /// A "short" Hanzi region.
    static let hanziLengthRange = 1...6
    static let minLatinLetters = 2

    /// The text when it is entirely Han ideographs (surrounding whitespace ignored) and short; otherwise nil.
    static func hanziOnly(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars
        guard hanziLengthRange.contains(scalars.count), scalars.allSatisfy(isHan) else { return nil }
        return trimmed
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2EBEF: true
        default: false
        }
    }

    /// Lowercase ASCII letters of a Latin-only region, or nil. Allowlist after canonical decomposition: ASCII
    /// letters, spaces, apostrophes (' and ’) and combining tone/diacritic marks (so ǚ → u). Anything else
    /// (digits, punctuation, hyphens, symbols, other scripts) rejects the whole text rather than being stripped.
    /// Needs at least ``minLatinLetters`` letters.
    static func latinLetters(_ text: String) -> String? {
        var letters = ""
        for scalar in text.trimmingCharacters(in: .whitespacesAndNewlines).decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A: letters.unicodeScalars.append(Unicode.Scalar(scalar.value + 32)!)
            case 0x61...0x7A: letters.unicodeScalars.append(scalar)
            case 0x20, 0x27, 0x2019, 0x0300...0x036F: continue
            default: return nil
            }
        }
        return letters.count >= minLatinLetters ? letters : nil
    }

    /// Toneless letters of the local Han-Latin romanization, or nil if the text isn't short Hanzi or the
    /// transform doesn't fully convert it.
    static func romanizedLetters(of hanzi: String) -> String? {
        guard let hanzi = hanziOnly(hanzi),
              let latin = hanzi.applyingTransform(StringTransform("Han-Latin"), reverse: false)
        else { return nil }
        return latinLetters(latin)
    }

    /// Exact, non-empty letter match only.
    static func matches(hanzi: String, latin: String) -> Bool {
        guard let expected = romanizedLetters(of: hanzi), let written = latinLetters(latin) else { return false }
        return expected == written
    }
}
