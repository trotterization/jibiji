import Foundation

enum FlashcardKind: String, Codable, CaseIterable, Sendable {
    case vocabulary, idiom, grammar, example, component, classical
}

/// An editable, source-linked card draft. `sourceText` is the exact recognized line it came from.
struct FlashcardDraft: Codable, Equatable, Sendable {
    var front: String
    var back: String
    var kind: FlashcardKind
    var sourceText: String
    var needsReview: Bool
}

/// Deterministic, offline extraction from ONE recognized line. Abstains (nil) rather than inventing content.
/// Facts come only from the line itself, plus `StarterVocabulary` for exact Hanzi matches.
enum FlashcardExtractor {
    static func extract(from line: String, vocabulary: StarterVocabulary = .standard) -> FlashcardDraft? {
        let source = line
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let (kind, body) = labeled(text) {
            return fromLabel(kind, body: body, source: source, vocabulary: vocabulary)
        }
        // Arrow syntax is decided first: a valid `预 → 豫` relation, otherwise abstain (never fall back to vocab).
        if text.contains("→") || text.contains("->") { return arrowRelation(text, source: source) }
        if let draft = equation(text, source: source) { return draft }
        if let draft = grammar(text, source: source, vocabulary: vocabulary) { return draft }
        if let draft = idiom(text, source: source) { return draft }
        return vocab(text, source: source, vocabulary: vocabulary)
    }

    // MARK: - Labels

    private static let labels: [(String, FlashcardKind)] = [
        ("idiom", .idiom), ("成语", .idiom), ("熟语", .idiom),
        ("example", .example), ("例句", .example), ("例", .example),
        ("grammar", .grammar), ("语法", .grammar),
        ("component", .component), ("部件", .component), ("部首", .component), ("偏旁", .component),
        ("relation", .component), ("related", .component), ("相关", .component), ("关联", .component),
        ("classical", .classical), ("古汉语", .classical), ("文言", .classical),
    ]

    private static func labeled(_ text: String) -> (FlashcardKind, String)? {
        for (label, kind) in labels {
            guard text.lowercased().hasPrefix(label) else { continue }
            let rest = text.dropFirst(label.count)
            guard let first = rest.first, first == ":" || first == "：" else { continue }
            let body = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : (kind, body)
        }
        return nil
    }

    private static func fromLabel(_ kind: FlashcardKind, body: String, source: String, vocabulary: StarterVocabulary) -> FlashcardDraft? {
        switch kind {
        case .grammar:
            return grammar(body, source: source, vocabulary: vocabulary)
        case .idiom:
            guard let term = StarterVocabulary.hanziRuns(in: body).first, body.hasPrefix(term) else { return nil }
            let note = body.dropFirst(term.count).trimmingCharacters(in: separators)
            return FlashcardDraft(front: term, back: note, kind: .idiom, sourceText: source, needsReview: note.isEmpty)
        case .example:
            guard !StarterVocabulary.hanzi(in: body).isEmpty else { return nil }
            if let (l, r) = split(body, on: ["=", "→", "->"]) {
                return FlashcardDraft(front: l, back: r, kind: .example, sourceText: source, needsReview: false)
            }
            return FlashcardDraft(front: body, back: "", kind: .example, sourceText: source, needsReview: true)
        case .component:
            guard let (l, r) = split(body, on: ["→", "->", "=", "+"]) else { return nil }
            return FlashcardDraft(front: l, back: r, kind: .component, sourceText: source, needsReview: false)
        case .classical:
            return equation(body, source: source, forceClassical: true)
        default:
            return nil
        }
    }

    private static let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":：-–—,，;；"))

    /// Splits at the first of the given separators; both sides must be non-empty.
    private static func split(_ text: String, on seps: [String]) -> (String, String)? {
        var best: Range<String.Index>?
        for sep in seps {
            if let r = text.range(of: sep), best == nil || r.lowerBound < best!.lowerBound { best = r }
        }
        guard let r = best else { return nil }
        let l = text[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        let rr = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return l.isEmpty || rr.isEmpty ? nil : (l, rr)
    }

    // MARK: - 与 = 和 (古汉语)

    private static func equation(_ text: String, source: String, forceClassical: Bool = false) -> FlashcardDraft? {
        guard let (left, rest) = split(text, on: ["="]) else { return nil }
        guard !left.isEmpty, left.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) }) else { return nil }
        var right = rest
        var note = ""
        if let open = rest.firstIndex(where: { $0 == "(" || $0 == "（" }) {
            right = rest[..<open].trimmingCharacters(in: .whitespaces)
            note = String(rest[open...])
        }
        guard !right.isEmpty else { return nil }
        let classical = forceClassical || ["古汉语", "文言", "classical"].contains { note.lowercased().contains($0) }
        let back = note.isEmpty ? "= \(right)" : "= \(right) \(note)"
        return FlashcardDraft(front: left, back: back, kind: classical ? .classical : .vocabulary,
                              sourceText: source, needsReview: !classical && note.isEmpty)
    }

    // MARK: - 虽然…但是…

    private static let patternRegex = try! NSRegularExpression(pattern: "^\\p{Han}+(?:(?:…|\\.{3})\\p{Han}+)+(?:…|\\.{3})?")

    private static func grammar(_ text: String, source: String, vocabulary: StarterVocabulary) -> FlashcardDraft? {
        let ns = text as NSString
        guard let m = patternRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let raw = ns.substring(with: m.range)
        let pattern = raw.replacingOccurrences(of: "...", with: "…")
        let rest = ns.substring(from: m.range.upperBound).trimmingCharacters(in: separators)

        let segments = StarterVocabulary.hanziRuns(in: pattern)
        let glosses = segments.compactMap { seg in vocabulary.entries.first { $0.hanzi == seg }?.glosses.first }
        let gloss = glosses.count == segments.count ? glosses.joined(separator: " … ") : ""

        var parts: [String] = []
        if !gloss.isEmpty { parts.append(gloss) }
        if !rest.isEmpty { parts.append("Example: \(rest)") }
        guard !parts.isEmpty else { return nil }
        return FlashcardDraft(front: pattern, back: parts.joined(separator: "\n"), kind: .grammar,
                              sourceText: source, needsReview: rest.isEmpty)
    }

    // MARK: - Unlabeled idiom and arrow relation

    /// Small explicit set of well-known idioms recognized without a label. Needs a usage note on the same line.
    private static let knownIdioms: Set<String> = ["虎头蛇尾"]

    private static func idiom(_ text: String, source: String) -> FlashcardDraft? {
        guard let term = knownIdioms.first(where: { text.hasPrefix($0) }) else { return nil }
        let note = text.dropFirst(term.count).trimmingCharacters(in: separators)
        guard !note.isEmpty else { return nil }
        return FlashcardDraft(front: term, back: note, kind: .idiom, sourceText: source, needsReview: false)
    }

    /// `预 → 豫` typed on one line, Hanzi on both sides, no label: a related card that always needs review.
    private static func arrowRelation(_ text: String, source: String) -> FlashcardDraft? {
        guard let (l, r) = split(text, on: ["→", "->"]), isAllHan(l), isAllHan(r) else { return nil }
        return FlashcardDraft(front: l, back: r, kind: .component, sourceText: source, needsReview: true)
    }

    private static func isAllHan(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) }
    }

    /// Local ICU Han-Latin transform, normalized to lowercase letters with no tones or spaces.
    private static func romanizationHint(for term: String) -> String {
        let latin = term.applyingTransform(.mandarinToLatin, reverse: false) ?? ""
        return StarterVocabulary.latinTokens(latin).joined()
    }

    // MARK: - Term + pinyin + gloss

    private static func vocab(_ text: String, source: String, vocabulary: StarterVocabulary) -> FlashcardDraft? {
        guard let term = StarterVocabulary.hanziRuns(in: text).first, text.hasPrefix(term) else { return nil }
        let rest = text.dropFirst(term.count).trimmingCharacters(in: .whitespaces)
        let words = rest.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let entry = vocabulary.entries.first { $0.hanzi == term }

        var consumed = 0
        var pinyin = ""
        var review = false

        if let entry {
            let target = entry.syllables.joined()
            for k in 1...max(1, words.count) where k <= words.count {
                if StarterVocabulary.latinTokens(words[0..<k].joined()).joined() == target { consumed = k; break }
            }
            pinyin = entry.pinyin
            if consumed > 0 {
                let observed = words[0..<consumed].joined(separator: " ")
                if !RecognitionCrossCheck.pinyinAgrees(observed, with: entry.pinyin) {
                    pinyin = observed
                    review = true
                }
            }
        } else {
            // Unknown term: a leading run of words counts as pinyin only if, ignoring spaces and tones, it equals
            // the local Han-Latin romanization of the term. Otherwise nothing is pinyin and the written text is
            // kept as a flagged meaning. The pinyin is kept exactly as written; nothing is invented.
            let hint = romanizationHint(for: term)
            if !hint.isEmpty {
                for k in 1...max(1, words.count) where k <= words.count {
                    if StarterVocabulary.latinTokens(words[0..<k].joined()).joined() == hint { consumed = k; break }
                }
            }
            pinyin = words[0..<consumed].joined(separator: " ")
            review = true
        }

        let gloss = words.dropFirst(consumed).joined(separator: " ")
        var back: String
        if gloss.isEmpty {
            guard let entry else { return nil }
            back = "\(pinyin) — \(entry.glosses[0])"
        } else {
            let grounded = entry?.glosses.contains { $0.caseInsensitiveCompare(gloss) == .orderedSame } ?? false
            if !grounded { review = true }
            if gloss.contains("?") || gloss.contains("？") { review = true }
            back = pinyin.isEmpty ? gloss : "\(pinyin) — \(gloss)"
        }
        if consumed == 0 && entry == nil { review = true }
        return FlashcardDraft(front: term, back: back, kind: .vocabulary, sourceText: source, needsReview: review)
    }
}
