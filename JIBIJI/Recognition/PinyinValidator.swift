import Foundation
import UIKit

/// Spelling-level checks for Mandarin Pinyin and the other two writing fields of a note.
///
/// These say whether a string is *well-formed*, never whether it is the right word. A word is Pinyin only if it
/// splits entirely into real Mandarin syllables (the table in `ReadingCrossCheck.syllables`), every tone mark sits
/// on a vowel, and no syllable carries more than one tone. `hňo` (a caron on `n`) and `xaing` are not Pinyin.
enum PinyinValidator {
    struct Syllable: Equatable, Sendable {
        /// Lowercase ASCII letters, tone and diaeresis folded (`ü` → `u`).
        var letters: String
        /// 1–4 from a mark or digit, 5 for the digit 5, nil when no tone is written.
        var tone: Int?
    }

    enum Verdict: Equatable, Sendable {
        case valid([Syllable])
        /// Not valid Pinyin. `toneEvidence` is true when the word carries diacritics or tone digits, so it was
        /// *meant* as Pinyin and must never be filed as English.
        case invalid(toneEvidence: Bool)

        var isValid: Bool { if case .valid = self { return true } else { return false } }
        var syllables: [Syllable] { if case .valid(let s) = self { return s } else { return [] } }
        var isToned: Bool { syllables.contains { $0.tone != nil } }
        var toneEvidence: Bool {
            switch self { case .valid(let s): return s.contains { $0.tone != nil }; case .invalid(let e): return e }
        }
    }

    private static let toneOfMark: [UInt32: Int] = [0x0304: 1, 0x0301: 2, 0x030C: 3, 0x0300: 4]
    private static let vowels = Set("aeiou")

    /// Analyses one whitespace-free word (apostrophes allowed as syllable separators).
    static func analyze(_ word: String) -> Verdict {
        var letters: [Character] = []
        var marks: [Int: Int] = [:]           // letter index → tone from a combining mark
        var digits: [Int: Int] = [:]          // boundary (letters before it) → tone digit
        var breaks = Set<Int>()               // forced syllable boundaries (apostrophes)
        var evidence = false
        for scalar in word.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x61...0x7A: letters.append(Character(scalar))
            case 0x27, 0x2019: if !letters.isEmpty { breaks.insert(letters.count) }
            case 0x31...0x35:
                guard !letters.isEmpty, digits[letters.count] == nil else { return .invalid(toneEvidence: true) }
                digits[letters.count] = Int(scalar.value) - 0x30
                evidence = true
            case 0x0308:   // ü
                evidence = true
                guard letters.last == "u" else { return .invalid(toneEvidence: true) }
            case 0x0304, 0x0301, 0x030C, 0x0300:
                evidence = true
                guard let last = letters.last, vowels.contains(last), marks[letters.count - 1] == nil else {
                    return .invalid(toneEvidence: true)   // a tone mark on a consonant or two on one letter
                }
                marks[letters.count - 1] = toneOfMark[scalar.value]
            default:
                return .invalid(toneEvidence: evidence || scalar.properties.generalCategory == .nonspacingMark)
            }
        }
        // `v` is the plain-keyboard spelling of ü.
        let folded = letters.map { $0 == "v" ? "u" : $0 }
        guard !folded.isEmpty, folded.count <= 24 else { return .invalid(toneEvidence: evidence) }
        let toneBoundaries = Set(digits.keys)
        let forced = breaks.union(toneBoundaries)

        // best[i]: the fewest syllables splitting the first i letters, honouring forced boundaries and one tone per syllable.
        var best = [[Syllable]?](repeating: nil, count: folded.count + 1)
        best[0] = []
        for end in 1...folded.count {
            for length in 1...min(6, end) {
                let start = end - length
                guard let before = best[start] else { continue }
                // No forced boundary may fall inside the syllable.
                if forced.contains(where: { $0 > start && $0 < end }) { continue }
                let text = String(folded[start..<end])
                guard ReadingCrossCheck.syllables.contains(text) else { continue }
                let markTones = marks.filter { $0.key >= start && $0.key < end }.map(\.value)
                guard markTones.count <= 1 else { continue }
                let digitTone = digits[end]
                guard markTones.isEmpty || digitTone == nil else { continue }
                let candidate = before + [Syllable(letters: text, tone: markTones.first ?? digitTone)]
                if best[end] == nil || candidate.count < best[end]!.count { best[end] = candidate }
            }
        }
        if let result = best[folded.count] { return .valid(result) }
        return .invalid(toneEvidence: evidence)
    }

    /// Valid only when every word is valid Pinyin.
    static func analyze(words: [String]) -> Verdict {
        var all: [Syllable] = []
        var evidence = false
        var valid = !words.isEmpty
        for word in words {
            let verdict = analyze(word)
            evidence = evidence || verdict.toneEvidence
            if case .valid(let s) = verdict { all += s } else { valid = false }
        }
        return valid ? .valid(all) : .invalid(toneEvidence: evidence)
    }
}

/// Field-level validation shared by grouping, resolution, suggestions and cards.
enum FieldValidation {
    /// Words of a field with punctuation trimmed from their ends (`hǎo,` → `hǎo`).
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { token in
            token.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "'’")))
        }.filter { !$0.isEmpty }
    }

    static func isHanzi(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) }
    }

    enum WordKind: Equatable, Sendable {
        /// Valid Pinyin carrying a tone mark or digit.
        case pinyinToned
        /// Valid toneless syllables: Pinyin *or* an English word (`me`, `he`, `ma`) until context decides.
        case pinyinPlain
        /// Carries tone marks or digits but is not valid Pinyin (`hňo`). Never English.
        case pinyinMalformed
        case english
    }

    static func kind(of word: String) -> WordKind {
        if word.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) { return .english }
        switch PinyinValidator.analyze(word) {
        case .valid(let s): return s.contains { $0.tone != nil } ? .pinyinToned : .pinyinPlain
        case .invalid(let evidence): return evidence ? .pinyinMalformed : .english
        }
    }

    /// Toneless letters of a Pinyin word list, joined (`hǎo xiang` → `haoxiang`).
    static func letters(_ words: [String]) -> String { StarterVocabulary.latinTokens(words.joined(separator: " ")).joined() }

    /// Whether `letters` fits the romanization of `hanzi`, or of a starter-vocabulary word that begins with it,
    /// allowing the Pinyin to be longer (the word is only partly written in Hanzi) or shorter (partly written in Pinyin).
    static func fitsHanzi(_ letters: String, hanzi: String, vocabulary: StarterVocabulary) -> Bool {
        guard !letters.isEmpty, !hanzi.isEmpty else { return false }
        var expected = [ReadingCrossCheck.romanization(of: hanzi)]
        for entry in vocabulary.entries where entry.hanzi.hasPrefix(hanzi) || hanzi.hasPrefix(entry.hanzi) {
            expected.append(entry.syllables.joined())
        }
        return expected.contains { !$0.isEmpty && ($0.hasPrefix(letters) || letters.hasPrefix($0)) }
    }

    /// English must not be a romanization: no word with tone evidence, and not plain syllables that spell the Hanzi.
    static func isEnglish(_ text: String, hanzi: String?, vocabulary: StarterVocabulary) -> Bool {
        let words = words(text)
        guard !words.isEmpty, words.contains(where: { $0.contains(where: \.isLetter) }) else { return false }
        let kinds = words.map(kind(of:))
        if kinds.contains(.pinyinToned) || kinds.contains(.pinyinMalformed) { return false }
        if kinds.allSatisfy({ $0 == .pinyinPlain }), let hanzi, fitsHanzi(letters(words), hanzi: hanzi, vocabulary: vocabulary) { return false }
        // At least one word must be a real English word (iOS's on-device spell checker, or a starter-vocabulary gloss).
        // `hho xiang` is a garbled romanization, not English; an English note has English words in it.
        let alphabetic = words.filter { $0.allSatisfy(\.isLetter) }
        guard !alphabetic.isEmpty else { return true }   // digits and symbols only (`(1)`, `~ like`): nothing to disprove
        return alphabetic.filter { isEnglishWord($0, vocabulary: vocabulary) }.count * 2 > alphabetic.count
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var spellCache: [String: Bool] = [:]

    /// UITextChecker is main-actor bound; the reader runs elsewhere, so ask it on the main thread (results are cached).
    private static func spelledCorrectly(_ word: String) -> Bool {
        cacheLock.lock(); let cached = spellCache[word]; cacheLock.unlock()
        if let cached { return cached }
        func check() -> Bool {
            MainActor.assumeIsolated {
                UITextChecker().rangeOfMisspelledWord(in: word, range: NSRange(location: 0, length: word.utf16.count),
                                                      startingAt: 0, wrap: false, language: "en_US").location == NSNotFound
            }
        }
        let result = Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
        cacheLock.lock(); spellCache[word] = result; cacheLock.unlock()
        return result
    }

    /// A real English word per the on-device spell checker or a gloss of the starter vocabulary. No network, no model.
    static func isEnglishWord(_ word: String, vocabulary: StarterVocabulary) -> Bool {
        let lower = word.lowercased()
        guard lower.allSatisfy(\.isLetter), lower.allSatisfy(\.isASCII) else { return false }
        if lower.count == 1 { return lower == "a" || lower == "i" }
        if vocabulary.entries.contains(where: { $0.glosses.contains { $0.lowercased().contains(lower) } }) { return true }
        return spelledCorrectly(lower)
    }
}
