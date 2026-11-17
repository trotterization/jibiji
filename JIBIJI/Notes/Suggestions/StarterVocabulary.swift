import CoreGraphics
import Foundation

/// One offered completion. Not AI output: it comes from the tiny offline ``StarterVocabulary``.
struct SuggestionCandidate: Codable, Equatable, Hashable, Sendable {
    var hanzi: String
    /// Tone-marked pinyin for display, e.g. "fùzé".
    var pinyin: String
    var gloss: String
}

/// What the provider would add next to a line of ink.
struct SuggestionProposal: Equatable, Sendable {
    /// The best match first, then real alternatives.
    var candidates: [SuggestionCandidate]
    /// The Hanzi is already written on the page, so only the gloss is offered.
    var hanziAlreadyWritten: Bool
    /// The gloss is already written, so only the Hanzi is offered.
    var glossAlreadyWritten: Bool
    /// A strict prefix of the best match's Hanzi already written (e.g. 好 of 好像); only the rest is offered.
    var hanziPrefixWritten: String = ""
    var pinyinAlreadyWritten = true
    /// Exact written fields, retained when replacing the whole source line.
    var writtenPinyin: String? = nil
    var writtenGloss: String? = nil
}

/// A small, explicitly offline starter list used to prove the inline-suggestion flow.
/// It is NOT a general dictionary and NOT AI: it only recognizes the entries below, and abstains otherwise.
struct StarterVocabulary: Sendable {
    struct Entry: Sendable {
        var hanzi: String
        var pinyin: String
        var glosses: [String]
        /// Hanzi of other entries that are a real alternative sense of this one.
        var alternatives: [String] = []

        var syllables: [String] { StarterVocabulary.latinTokens(pinyin) }
        var candidate: SuggestionCandidate { .init(hanzi: hanzi, pinyin: pinyin, gloss: glosses[0]) }
    }

    static let label = "Offline starter vocabulary (\(standard.entries.count) entries, not AI)"

    static let standard = StarterVocabulary(entries: [
        Entry(hanzi: "负责", pinyin: "fùzé", glosses: ["to be responsible for", "to be in charge of"], alternatives: ["承担"]),
        Entry(hanzi: "承担", pinyin: "chéngdān", glosses: ["to bear responsibility for", "to undertake"], alternatives: ["负责"]),
        Entry(hanzi: "预习", pinyin: "yùxí", glosses: ["to prepare a lesson in advance"]),
        Entry(hanzi: "复习", pinyin: "fùxí", glosses: ["to review"]),
        Entry(hanzi: "虽然", pinyin: "suīrán", glosses: ["although"]),
        Entry(hanzi: "但是", pinyin: "dànshì", glosses: ["but", "however"]),
        Entry(hanzi: "好像", pinyin: "hǎoxiàng", glosses: ["to seem like; to look like", "to seem like", "to look like"]),
        Entry(hanzi: "农夫市集", pinyin: "nóngfū shìjí", glosses: ["farmers' market"]),
    ])

    var entries: [Entry]

    // MARK: - Normalizing

    /// Lowercase ASCII letter runs with tone marks and ü folded away. Hanzi and punctuation separate tokens.
    static func latinTokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var tokens: [String] = []
        var current = ""
        for character in folded {
            if character.isASCII, character.isLetter {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func hanzi(in text: String) -> String {
        String(text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.map(Character.init))
    }

    /// Maximal runs of Han characters, split by anything else (so 负责人 is one run, never 负责).
    static func hanziRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    // MARK: - Matching

    /// Conservative: needs the entry's pinyin (tones optional) or its Hanzi in the text. Any other Latin
    /// words must be a run of that entry's English gloss, otherwise the provider abstains.
    func proposal(forRecognizedText text: String) -> SuggestionProposal? {
        let tokens = Self.latinTokens(text)
        let runs = Self.hanziRuns(in: text)
        for entry in entries {
            let pinyinRange = Self.range(of: entry.syllables, in: tokens)
            let hanziWritten = runs.contains(entry.hanzi)
            guard pinyinRange != nil || hanziWritten else { continue }
            if hanziWritten && runs != [entry.hanzi] { continue }

            // Partial Hanzi (e.g. 好 for 好像) only counts with the entry's exact pinyin, and any other
            // Han run is a contradiction: abstain rather than guess.
            var prefix = ""
            if pinyinRange != nil, !hanziWritten, !runs.isEmpty {
                guard runs.count == 1, runs[0].count < entry.hanzi.count, entry.hanzi.hasPrefix(runs[0]) else { return nil }
                prefix = runs[0]
            }

            var rest = tokens
            if let pinyinRange { rest.removeSubrange(pinyinRange) }
            var glossComplete = false
            if !rest.isEmpty {
                let glossTokens = entry.glosses.map(Self.latinTokens)
                guard glossTokens.contains(where: { Self.range(of: rest, in: $0) != nil }) else { return nil }
                glossComplete = glossTokens.contains(rest)
            }
            if hanziWritten && glossComplete && pinyinRange != nil { return nil }
            let written = Self.writtenFields(in: text, pinyinRange: pinyinRange)
            let alternatives = entry.alternatives.compactMap { hanzi in entries.first { $0.hanzi == hanzi }?.candidate }
            return SuggestionProposal(
                candidates: [entry.candidate] + alternatives,
                hanziAlreadyWritten: hanziWritten,
                glossAlreadyWritten: glossComplete,
                hanziPrefixWritten: prefix,
                pinyinAlreadyWritten: pinyinRange != nil,
                writtenPinyin: written.pinyin,
                writtenGloss: written.gloss
            )
        }
        return nil
    }

    /// Use the original token ranges so tone marks, spelling and English punctuation survive review.
    private static func writtenFields(in text: String, pinyinRange: Range<Int>?) -> (pinyin: String?, gloss: String?) {
        let expression = try! NSRegularExpression(pattern: "[\\p{Latin}\\p{M}]+")
        let spans = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
        guard let first = spans.first else { return (nil, nil) }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "·"))
        guard let pinyinRange, pinyinRange.upperBound <= spans.count else {
            let hanzi = Self.hanziRuns(in: text).first
            let start = hanzi.flatMap { text.range(of: $0) }.map(\.upperBound) ?? first.lowerBound
            return (nil, String(text[start..<text.endIndex]).trimmingCharacters(in: separators))
        }
        let pinyin = String(text[spans[pinyinRange.lowerBound].lowerBound..<spans[pinyinRange.upperBound - 1].upperBound])
        // Matching accepts English either before or after Pinyin. Preserve both when present.
        var gloss: [String] = []
        if pinyinRange.lowerBound > 0 {
            gloss.append(String(text[first.lowerBound..<spans[pinyinRange.lowerBound].lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if pinyinRange.upperBound < spans.count {
            var suffix = String(text[spans[pinyinRange.upperBound - 1].upperBound..<text.endIndex]).trimmingCharacters(in: separators)
            let prefix = text[..<spans[pinyinRange.lowerBound].lowerBound].trimmingCharacters(in: .whitespaces)
            if prefix.hasSuffix("("), suffix.hasPrefix(")") { suffix = String(suffix.dropFirst()).trimmingCharacters(in: separators) }
            gloss.append(suffix)
        }
        return (pinyin, gloss.isEmpty ? nil : gloss.joined(separator: " "))
    }

    /// Where `needle` appears in `tokens`, either as separate syllables ("fu ze") or joined ("fuze").
    private static func range(of needle: [String], in tokens: [String]) -> Range<Int>? {
        guard !needle.isEmpty else { return nil }
        let joined = needle.joined()
        for start in tokens.indices {
            var accumulated = ""
            for end in start..<tokens.count {
                accumulated += tokens[end]
                if accumulated == joined { return start..<(end + 1) }
                if accumulated.count >= joined.count { break }
            }
            if start + needle.count <= tokens.count, Array(tokens[start..<(start + needle.count)]) == needle {
                return start..<(start + needle.count)
            }
        }
        return nil
    }
}
