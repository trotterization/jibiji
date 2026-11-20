import Foundation

/// Shape checks for one OCR reading, before it can be offered as text for the student's page.
///
/// This judges only whether a reading is *well formed* — it cannot say whether it is *correct*.
/// Tokens that mix Han characters, Latin letters or digits the way no real note does (`x7大`, `a3b9`) are
/// OCR noise, typically from reading rendered clean-handwriting glyphs or scribbles. Legitimate writing
/// passes: Hanzi, tone-marked Pinyin, numeric-tone Pinyin (`hao3`), English with digits and symbols
/// (`(1) to seem; ~ like`), and grammar patterns (`虽然…但是…`).
enum ReadingValidation {
    private static let maxLength = 500

    static func isWellFormed(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return false }
        // Words are judged apart from the punctuation around and between them (`(1)to`, `A/B`, `hao3,`, `xi'an`).
        let separators = CharacterSet.whitespacesAndNewlines.union(punctuation)
        for scalar in trimmed.unicodeScalars {
            // Replacement characters, controls, private use and unassigned code points are never handwriting.
            if scalar == "\u{FFFD}" { return false }
            switch scalar.properties.generalCategory {
            case .control, .privateUse, .unassigned, .surrogate: return false
            case .format: if ![0x200B, 0x200D, 0x00AD].contains(scalar.value) { return false }
            default: break
            }
        }
        for token in trimmed.components(separatedBy: separators) where !token.isEmpty {
            if !isWellFormedToken(token) { return false }
        }
        return true
    }

    private static let punctuation = CharacterSet.punctuationCharacters.union(.symbols)

    private static func isWellFormedToken(_ token: String) -> Bool {
        let scalars = Array(token.unicodeScalars)
        let hasHan = scalars.contains { isHan($0) }
        let hasDigit = scalars.contains { $0.properties.numericType != nil && $0.isASCII }
        let letters = token.filter { $0.isLetter && !isHan($0) }
        // Lower→upper flips inside a Latin word (`fuZeBaKa`) are scribble noise; `iPhoneX`, `Abc`, `ABC` pass.
        var flips = 0
        var previous: Character?
        for character in letters {
            if let p = previous, p.isLowercase, character.isUppercase { flips += 1 }
            previous = character
        }
        guard flips < 3 else { return false }
        guard hasDigit, !letters.isEmpty else { return true }
        // Han with digits is ordinary (`第1课`, `2024年`); Han with digits *and* Latin letters (`x7大`) is noise.
        if hasHan { return false }
        // Letters mixed with digits: numeric-tone Pinyin (`hao3`), or an ordinary English/label token
        // (`HSK4`, `mp3`, `B2`, `3rd`, `10am`, `4G`). Anything that alternates (`a3b9`, `hao5x`) is noise.
        return isNumericTonePinyin(token) || isLabelToken(token)
    }

    private static func isLabelToken(_ token: String) -> Bool {
        token.range(of: "^[A-Za-z]{1,6}[0-9]{1,4}$", options: .regularExpression) != nil
            || token.range(of: "^[0-9]{1,4}(st|nd|rd|th|am|pm|[A-Za-z]{1,3})$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `hao3`, `fu4ze2`, `lü4`, `lv4`: each digit 1–5 ends a valid toneless syllable (`v` stands for `ü`).
    static func isNumericTonePinyin(_ token: String) -> Bool {
        // Pinyin is lowercase; at most the first letter may be capitalised.
        guard !token.dropFirst().contains(where: { $0.isUppercase }) else { return false }
        var syllable = ""
        var sawDigit = false
        var endedWithDigit = false
        func valid(_ s: String) -> Bool { ReadingCrossCheck.isPinyin(s.replacingOccurrences(of: "v", with: "u", options: .caseInsensitive)) }
        for character in token {
            if character.isASCII, character.isNumber {
                guard ("1"..."5").contains(character), !syllable.isEmpty, valid(syllable) else { return false }
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
        return sawDigit && (endedWithDigit || valid(syllable))
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool { (0x4E00...0x9FFF).contains(scalar.value) }
    private static func isHan(_ character: Character) -> Bool { character.unicodeScalars.contains { isHan($0) } }
}
