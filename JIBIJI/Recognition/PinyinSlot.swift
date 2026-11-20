import Foundation

/// Decides which written words are a note's *Pinyin* before the English is taken from the rest.
///
/// A note reads Hanzi, then Pinyin, then English. When OCR misreads the Pinyin (an untoned or one-letter-off
/// spelling), that misreading must stay in the Pinyin field. It must never fall through into the English
/// definition just because it did not match the expected romanization exactly. Evidence comes only from the
/// Hanzi's own romanization (the starter vocabulary entry, else the system Han-to-Latin transform), so this
/// is a spelling-shape check, not an understanding of meaning.
enum PinyinSlot {
    struct Match: Equatable {
        /// How many leading words belong to the Pinyin.
        var count: Int
        /// The words spell the expected romanization exactly (tones and spacing ignored).
        var exact: Bool
    }

    /// Smallest romanization length for which a near miss (rather than only an exact spelling) may count.
    /// Shorter strings are too easily ordinary English words.
    static let minimumLengthForNearMatch = 4

    /// The leading words of `words` that spell `expected`, allowing a small OCR slip. Nil when none do.
    static func leading(_ words: [String], expected: String) -> Match? {
        let target = StarterVocabulary.latinTokens(expected).joined()
        guard !target.isEmpty, !words.isEmpty else { return nil }
        var best: (match: Match, distance: Int)?
        for count in 1...min(words.count, 8) {
            let slice = Array(words[0..<count])
            guard slice.allSatisfy({ $0.contains(where: \.isLetter) && $0.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" } }) else { break }
            let observed = StarterVocabulary.latinTokens(slice.joined(separator: " ")).joined()
            if observed == target { return Match(count: count, exact: true) }
            guard target.count >= minimumLengthForNearMatch else { continue }
            let distance = StarterVocabulary.editDistance(observed, target)
            let allowed = max(1, target.count / 4)
            if distance <= allowed, best == nil || distance < best!.distance {
                best = (Match(count: count, exact: false), distance)
            }
        }
        return best?.match
    }

    /// The romanization a Hanzi term is expected to have: its starter-vocabulary reading, else the local transform.
    static func expectedRomanization(for hanzi: String, vocabulary: StarterVocabulary = .standard) -> String {
        if let entry = vocabulary.entries.first(where: { $0.hanzi == hanzi }) { return entry.pinyin }
        return hanzi.applyingTransform(.mandarinToLatin, reverse: false) ?? ""
    }

    /// Whether every word of `text` is just a (possibly misread) romanization of `hanzi`, so it is Pinyin, not English.
    static func isRomanization(_ text: String, of hanzi: String, vocabulary: StarterVocabulary = .standard) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, let match = leading(words, expected: expectedRomanization(for: hanzi, vocabulary: vocabulary)) else { return false }
        return match.count == words.count
    }
}
