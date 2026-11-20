import Foundation

/// Shape checks for one OCR reading, before it can be offered as text for the student's page.
///
/// This judges only whether a reading is *well formed* — it cannot say whether it is *correct*.
/// Tokens that mix Han characters, Latin letters or digits the way no real note does (`x7大`, `a3b9`) are
/// OCR noise, typically from reading rendered clean-handwriting glyphs or scribbles. Legitimate writing
/// passes: Hanzi, tone-marked Pinyin, numeric-tone Pinyin (`hao3`), English with digits and symbols
/// (`(1) to seem; ~ like`), and grammar patterns (`虽然…但是…`).
enum ReadingValidation {
    static func isWellFormed(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return false }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "·"))
        for scalar in trimmed.unicodeScalars {
            // Replacement characters, controls, private use and unassigned code points are never handwriting.
            if scalar == "\u{FFFD}" { return false }
            switch scalar.properties.generalCategory {
            case .control, .privateUse, .unassigned, .surrogate: return false
            case .format: if scalar != "\u{200B}" { return false }
            default: break
            }
        }
        for token in trimmed.components(separatedBy: separators) where !token.isEmpty {
            if !isWellFormedToken(token) { return false }
        }
        return true
    }

    private static func isWellFormedToken(_ token: String) -> Bool {
        let scalars = Array(token.unicodeScalars)
        let hasHan = scalars.contains { isHan($0) }
        let hasDigit = scalars.contains { $0.properties.numericType != nil && $0.isASCII }
        let letters = token.filter { $0.isLetter && !isHan($0) }
        // Lower→upper flips inside a Latin word (`fuZeBa`) are scribble noise; `iPad`, `Abc`, `ABC` pass.
        var flips = 0
        var previous: Character?
        for character in letters {
            if let p = previous, p.isLowercase, character.isUppercase { flips += 1 }
            previous = character
        }
        guard flips < 2 else { return false }
        if hasDigit {
            // Han next to a digit inside one token (`x7大`, `大3`) is noise. (A standalone `3` or `(1)` is fine.)
            if hasHan { return false }
            // Letters mixed with digits are only legitimate as numeric-tone Pinyin (`hao3`, `fu4ze2`).
            if !letters.isEmpty { return isNumericTonePinyin(token) }
        }
        return true
    }

    /// `hao3`, `fu4ze2`, `lü4`: each digit 1–5 ends a valid toneless syllable.
    static func isNumericTonePinyin(_ token: String) -> Bool {
        var syllable = ""
        var sawDigit = false
        var endedWithDigit = false
        for character in token {
            if character.isASCII, character.isNumber {
                guard ("1"..."5").contains(character), !syllable.isEmpty, ReadingCrossCheck.isPinyin(syllable) else { return false }
                syllable = ""
                sawDigit = true
                endedWithDigit = true
            } else if character.isLetter {
                syllable.append(character)
                endedWithDigit = false
            } else {
                return false
            }
        }
        // A trailing neutral-tone syllable without a digit is fine (`ma`), but at least one tone digit is required.
        return sawDigit && (endedWithDigit || ReadingCrossCheck.isPinyin(syllable))
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool { (0x4E00...0x9FFF).contains(scalar.value) }
    private static func isHan(_ character: Character) -> Bool { character.unicodeScalars.contains { isHan($0) } }
}
