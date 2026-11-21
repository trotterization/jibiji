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
    /// How the student's written Pinyin compares with the word's Pinyin. Judged only against Hanzi that is
    /// actually written, since handwriting recognition alone can't tell a misspelling from a misread.
    var pinyinState: PinyinState = .notWritten
    /// The Pinyin offered is the dictionary's, because the written Pinyin could not be read as spelled.
    var pinyinFromDictionary = false
    /// Every reader agreed on the Pinyin as written and only its tone marks differ from the dictionary's: a slip in the
    /// writing, not a misread. Replacing writes the dictionary's Pinyin.
    var correctsConfirmedPinyin = false
    var pinyinAlreadyWritten: Bool { pinyinState != .notWritten }
    /// Exact written fields, retained when replacing the whole source line.
    var writtenPinyin: String? = nil
    var writtenGloss: String? = nil
}

enum PinyinState: Equatable, Sendable {
    case notWritten
    /// Matches the word's tone-marked Pinyin: kept as written.
    case correct
    /// The right letters and no tone marks: a tone-marked reading is offered.
    case missingTones
    /// The right letters with tone marks that differ from the word's: a provisional correction.
    case wrongTones(written: String)
    /// Letters one edit away from the word's Pinyin, next to its Hanzi. Could be a misspelling or a misread
    /// of the handwriting, so this is shown as uncertain and never used to change the ink.
    case possibleSpelling(written: String)

    /// A tone or spelling mismatch that could be the recognizer's mistake rather than the student's.
    var isUncertain: Bool {
        switch self {
        case .wrongTones, .possibleSpelling: return true
        default: return false
        }
    }
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
    /// An optional offline dictionary consulted when no curated entry matches.
    var lexicon: Lexicon? = nil

    /// The curated entries first, then the bundled CC-CEDICT dictionary. What the app uses.
    static var full: StarterVocabulary { StarterVocabulary(entries: standard.entries, lexicon: Lexicon.shared) }

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

    /// Lowercase Latin letter runs as written (tone marks kept) beside their folded form. Same runs as `latinTokens`.
    static func latinTokenPairs(_ text: String) -> [(raw: String, folded: String)] {
        var pairs: [(raw: String, folded: String)] = []
        var raw = "", folded = ""
        for character in text.precomposedStringWithCanonicalMapping.lowercased() {
            let flat = String(character).folding(options: .diacriticInsensitive, locale: nil)
            if flat.count == 1, flat.allSatisfy({ $0.isASCII && $0.isLetter }) {
                raw.append(character)
                folded += flat
            } else if !raw.isEmpty {
                pairs.append((raw, folded))
                raw = ""; folded = ""
            }
        }
        if !raw.isEmpty { pairs.append((raw, folded)) }
        return pairs
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var row = [i]
            for j in 1...max(b.count, 1) where !b.isEmpty {
                row.append(min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)))
            }
            previous = row
        }
        return a.isEmpty ? b.count : (b.isEmpty ? a.count : previous[b.count])
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
        if let curated = match(in: entries, text: text) { return curated }
        guard let lexicon else { return nil }
        let rows = lexicon.candidates(forText: text)
        // The best dictionary entry decides; the other entries are real alternatives (homophones, other readings).
        for (index, row) in rows.enumerated() {
            guard var proposal = match(in: [row.entry], text: text) else { continue }
            let others = rows.enumerated().filter { $0.offset != index }.map { $0.element.entry.candidate }
            proposal.candidates += others.filter { !proposal.candidates.contains($0) }.prefix(4)
            return proposal
        }
        return nil
    }

    /// A proposal rebuilt from the dictionary when the written Pinyin could not be read as spelled: the Hanzi is
    /// written, and the readers' guesses (`latinEvidence`) are close to one of the dictionary words that begin with it.
    /// Always uncertain: the Pinyin is the dictionary's, not the student's, so it never changes the ink on its own.
    func repairedProposal(forRecognizedText text: String, latinEvidence: [String]) -> SuggestionProposal? {
        guard let lexicon, !latinEvidence.isEmpty else { return nil }
        let runs = Self.hanziRuns(in: text)
        guard runs.count == 1, let run = runs.first else { return nil }
        let rows = lexicon.repairCandidates(hanziPrefix: run, readings: latinEvidence)
        guard let best = rows.first else { return nil }
        let candidates = rows.map(\.entry.candidate)
        let writtenPinyin = text.split(whereSeparator: \.isWhitespace)
            .filter { !$0.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } }.joined(separator: " ")
        return SuggestionProposal(
            candidates: candidates,
            hanziAlreadyWritten: best.hanzi == run,
            glossAlreadyWritten: false,
            hanziPrefixWritten: best.hanzi == run ? "" : run,
            pinyinState: .possibleSpelling(written: writtenPinyin.isEmpty ? (latinEvidence.first ?? "") : writtenPinyin),
            pinyinFromDictionary: true
        )
    }

    /// The matcher: whether `entries` fit the recognized text, and what is left to offer.
    private func match(in entries: [Entry], text: String) -> SuggestionProposal? {
        let pairs = Self.latinTokenPairs(text)
        let tokens = pairs.map(\.folded)
        let runs = Self.hanziRuns(in: text)
        for entry in entries {
            var pinyinRange = Self.range(of: entry.syllables, in: tokens)
            let hanziWritten = runs.contains(entry.hanzi)
            var misspelled = false
            // Right Hanzi, Pinyin one letter off: a possible misspelling (or misread), never a certainty.
            if pinyinRange == nil, hanziWritten, let near = Self.nearRange(of: entry.syllables, in: tokens) {
                pinyinRange = near
                misspelled = true
            }
            guard pinyinRange != nil || hanziWritten else { continue }
            if hanziWritten && runs != [entry.hanzi] { continue }

            // Partial Hanzi (e.g. 好 for 好像) only counts with the entry's exact pinyin, and any other
            // Han run is a contradiction: abstain rather than guess.
            var prefix = ""
            if pinyinRange != nil, !hanziWritten, !runs.isEmpty {
                guard runs.count == 1, runs[0].count < entry.hanzi.count, entry.hanzi.hasPrefix(runs[0]) else { return nil }
                prefix = runs[0]
            }

            var state = PinyinState.notWritten
            if let range = pinyinRange {
                let written = pairs[range].map(\.raw).joined(separator: " ")
                let writtenFlat = pairs[range].map(\.raw).joined()
                let expected = entry.pinyin.precomposedStringWithCanonicalMapping.lowercased().filter { !$0.isWhitespace }
                if misspelled {
                    state = .possibleSpelling(written: written)
                } else {
                    state = Self.toneState(written: writtenFlat, expected: expected, display: written)
                }
            }

            var rest = tokens
            if let pinyinRange { rest.removeSubrange(pinyinRange) }
            var glossComplete = false
            if !rest.isEmpty {
                let glossTokens = entry.glosses.map(Self.latinTokens)
                guard glossTokens.contains(where: { Self.range(of: rest, in: $0) != nil }) else { return nil }
                glossComplete = glossTokens.contains(rest)
            }
            if hanziWritten && glossComplete && state == .correct { return nil } // nothing left to add
            let written = Self.writtenFields(in: text, pinyinRange: pinyinRange)
            let alternatives = entry.alternatives.compactMap { hanzi in entries.first { $0.hanzi == hanzi }?.candidate }
            return SuggestionProposal(
                candidates: [entry.candidate] + alternatives,
                hanziAlreadyWritten: hanziWritten,
                glossAlreadyWritten: glossComplete,
                hanziPrefixWritten: prefix,
                pinyinState: state,
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

    /// Same letters, so compare tone marks letter by letter: a written mark that conflicts is wrong;
    /// marks that are all right but incomplete (hǎo xiang) are just missing tones.
    private static func toneState(written: String, expected: String, display: String) -> PinyinState {
        let w = Array(written), e = Array(expected)
        guard w.count == e.count else { return .wrongTones(written: display) }
        var missing = false
        for (wc, ec) in zip(w, e) where wc != ec {
            let plain = String(wc).folding(options: .diacriticInsensitive, locale: nil)
            if String(wc) == plain { missing = true } else { return .wrongTones(written: display) }
        }
        return missing ? .missingTones : .correct
    }

    /// A run of tokens one edit away from `needle`'s letters (never an exact match).
    private static func nearRange(of needle: [String], in tokens: [String]) -> Range<Int>? {
        let joined = needle.joined()
        guard joined.count >= 4 else { return nil }
        for start in tokens.indices {
            var accumulated = ""
            for end in start..<min(tokens.count, start + needle.count + 2) {
                accumulated += tokens[end]
                if abs(accumulated.count - joined.count) <= 1, editDistance(accumulated, joined) == 1 { return start..<(end + 1) }
            }
        }
        return nil
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
