import Foundation

/// An offline Mandarin–English dictionary: CC-CEDICT (CC BY-SA 4.0, see NOTICE.md), bundled as `Lexicon/CEDICT.tsv`.
///
/// It is a lookup table, not AI and not a recognizer. It never reads ink: given text that was already validated, it
/// supplies the Pinyin and English meanings that real dictionary entries have. No network, no cost, no upload.
final class Lexicon: @unchecked Sendable {
    struct Row: Sendable {
        var hanzi: String
        /// Dictionary spelling with tone digits, e.g. `hao3 xiang4`.
        var numbered: String
        var glosses: [String]
        /// Capitalised Pinyin: a name or place. Never offered from Pinyin alone.
        var isProperName: Bool
        /// A variant, old form or regional reading of another entry. Never offered from Pinyin alone.
        var isVariant: Bool
        /// How often the word occurs in a large corpus (jieba word list, MIT). 0 when the list does not have it.
        var frequency: Int = 0

        /// Toneless letters, joined: `haoxiang`.
        var letters: String { Lexicon.letters(of: numbered) }
        var tones: [Int] { numbered.split(separator: " ").map { Int($0.last.flatMap { String($0) } ?? "") ?? 5 } }
        var pinyin: String { Lexicon.toneMarked(numbered) }

        /// The meaning shown on a card: the first one or two real senses, trimmed.
        var gloss: String { Lexicon.shortGloss(glosses) }

        /// An entry the existing suggestion matcher can use. Its glosses are the short gloss plus each sense.
        var entry: StarterVocabulary.Entry {
            let senses = Lexicon.cleanSenses(glosses)
            return .init(hanzi: hanzi, pinyin: pinyin, glosses: ([gloss] + senses.prefix(8)).filter { !$0.isEmpty })
        }
    }

    private let rows: [Row]
    private let byHanzi: [String: [Int]]
    private let byFirst: [Character: [Int]]
    private let byLetters: [String: [Int]]
    private let byLength: [Int: [Int]]
    /// Toneless letters of each row, and how many of each letter a–z it has, so a spelling search can skip most rows cheaply.
    private let spelled: [[UInt8]]
    private let histogram: [[UInt8]]
    /// Names and variants, which a spelling-only search never offers. A flat array, so the search never copies a row to ask.
    private let excluded: [Bool]

    var count: Int { rows.count }

    init(rows: [Row]) {
        self.rows = rows
        var hanzi: [String: [Int]] = [:], first: [Character: [Int]] = [:], letters: [String: [Int]] = [:], length: [Int: [Int]] = [:]
        for (index, row) in rows.enumerated() {
            hanzi[row.hanzi, default: []].append(index)
            if let c = row.hanzi.first { first[c, default: []].append(index) }
            let spelled = row.letters
            letters[spelled, default: []].append(index)
            length[spelled.count, default: []].append(index)
        }
        byHanzi = hanzi; byFirst = first; byLetters = letters; byLength = length
        var bytes: [[UInt8]] = [], counts: [[UInt8]] = []
        bytes.reserveCapacity(rows.count); counts.reserveCapacity(rows.count)
        for row in rows {
            let b = Array(row.letters.utf8)
            bytes.append(b); counts.append(Self.histogram(of: b))
        }
        spelled = bytes; histogram = counts
        excluded = rows.map { $0.isProperName || $0.isVariant }
    }

    /// Parses the tab-separated table (`simplified \t numbered pinyin \t gloss | gloss`).
    convenience init(tsv: String) {
        var rows: [Row] = []
        rows.reserveCapacity(130_000)
        for line in tsv.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 3, Lexicon.isPinyin(fields[1]) else { continue }
            let glosses = fields[2].components(separatedBy: " | ")
            let proper = fields[1].first?.isUppercase == true
            let variant = glosses.contains { Lexicon.isVariantGloss($0) } && glosses.count <= 2
            rows.append(Row(hanzi: String(fields[0]), numbered: String(fields[1]), glosses: glosses, isProperName: proper, isVariant: variant,
                            frequency: fields.count > 3 ? Int(fields[3]) ?? 0 : 0))
        }
        self.init(rows: rows)
    }

    // MARK: - Shared instance

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Lexicon??

    /// The bundled dictionary, or nil when the table is missing. Loaded once; call `warmUp()` at launch so the first
    /// request does not wait for the parse.
    static var shared: Lexicon? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let loaded = Bundle.main.url(forResource: "CEDICT", withExtension: "tsv")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { Lexicon(tsv: $0) }
        cached = .some(loaded)
        return loaded
    }

    static func warmUp() { Task.detached(priority: .utility) { _ = Lexicon.shared } }

    // MARK: - Lookup

    func rows(forHanzi hanzi: String) -> [Row] { (byHanzi[hanzi] ?? []).map { rows[$0] } }

    /// Entries that begin with `prefix` (including an exact match).
    func rows(withHanziPrefix prefix: String) -> [Row] {
        guard let c = prefix.first else { return [] }
        return (byFirst[c] ?? []).map { rows[$0] }.filter { $0.hanzi.hasPrefix(prefix) }
    }

    func rows(forLetters letters: String) -> [Row] { (byLetters[letters] ?? []).map { rows[$0] } }

    // MARK: - Candidate selection for the suggestion matcher

    /// The few dictionary entries worth trying for a note's validated text, best first. The suggestion matcher then
    /// decides whether any of them really fits (tones, written English, contradictions).
    ///
    /// - One Hanzi run: its own entries (every reading), plus longer words that begin with it when the written Pinyin
    ///   spells that word.
    /// - Pinyin only: entries that spell exactly the written syllables, if the Pinyin carries tone marks or is at least
    ///   two syllables. A single toneless syllable (`me`, `he`) is too likely to be English to look up.
    func candidates(forText text: String) -> [Row] {
        let runs = StarterVocabulary.hanziRuns(in: text)
        let pairs = StarterVocabulary.latinTokenPairs(text)
        let tokens = pairs.map(\.folded)
        let writtenLetters = tokens.joined()

        if runs.count > 1 { return [] }
        if let run = runs.first {
            var out = rows(forHanzi: run)
            if !writtenLetters.isEmpty {
                for row in rows(withHanziPrefix: run) where row.hanzi != run && !row.isProperName && writtenLetters.contains(row.letters) {
                    out.append(row)
                }
            }
            return Array(Self.ranked(out, written: pairs).prefix(6))
        }

        guard !tokens.isEmpty else { return [] }
        let toned = pairs.contains { $0.raw != $0.folded }
        var found: [Row] = []
        // Any contiguous run of the written words may be the Pinyin (the rest is English).
        for start in tokens.indices {
            var letters = ""
            for end in start..<min(tokens.count, start + 6) {
                letters += tokens[end]
                let words = end - start + 1
                guard toned || words >= 2 || letters.count >= 4 else { continue }
                found += rows(forLetters: letters).filter { !$0.isProperName && !$0.isVariant && $0.hanzi.count >= 1 }
            }
        }
        return Array(Self.ranked(found, written: Array(pairs)).prefix(6))
    }

    /// Dictionary words that begin with the written Hanzi and whose spelling is close to what the recognizers produced.
    ///
    /// Handwritten Pinyin is often read as scraps (`xú`, `xve`) with the right answer only among the lower-ranked guesses
    /// (`xúe xi`). The readings are not text here; they only score words the dictionary already has. A word qualifies
    /// when some reading is within one letter of its spelling (two for long words). Best score first.
    func repairCandidates(hanziPrefix run: String, readings: [String]) -> [Row] {
        let normalized = readings.map(Self.foldedLetters).filter { $0.count >= 3 }
        guard !run.isEmpty, !normalized.isEmpty else { return [] }
        var best: [String: (row: Row, score: Int, index: Int)] = [:]
        for (index, row) in rows(withHanziPrefix: run).enumerated() where !row.isProperName && !row.isVariant {
            let letters = row.letters
            guard letters.count >= 3 else { continue }
            let allowed = letters.count > 7 ? 2 : 1
            let score = normalized.map { StarterVocabulary.editDistance($0, letters) }.min() ?? Int.max
            guard score <= allowed else { continue }
            if let existing = best[row.hanzi], existing.score <= score { continue }
            best[row.hanzi] = (row, score, index)
        }
        let sorted = best.values.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.row.frequency != $1.row.frequency { return $0.row.frequency > $1.row.frequency }
            if $0.row.hanzi.count != $1.row.hanzi.count { return $0.row.hanzi.count < $1.row.hanzi.count }
            return $0.index < $1.index
        }
        // Only words as close as the best one: a word one letter further off is a different word, not an alternative.
        guard let top = sorted.first?.score else { return [] }
        return sorted.filter { $0.score == top }.prefix(5).map(\.row)
    }

    /// Dictionary words whose spelling is close to what the recognizers produced for Pinyin written with no Hanzi.
    ///
    /// Stricter than the Hanzi repair because nothing anchors the word: at least four letters; within one letter of some
    /// reading (two for long words); and the tone marks the student wrote must agree with the word's tones. Names and
    /// variants are skipped. Best score first, and only words as good as the best are returned.
    @_optimize(speed)
    func repairCandidates(forPinyinReadings readings: [String]) -> [Row] {
        var seen = Set<String>()
        let usable = readings.compactMap { reading -> (letters: String, tones: [Int])? in
            let letters = Self.foldedLetters(reading)
            guard letters.count >= 4, seen.insert(letters + "|" + Self.writtenToneList(reading).map(String.init).joined()).inserted else { return nil }
            return (letters, Self.writtenToneList(reading))
        }.prefix(8)
        guard !usable.isEmpty else { return [] }
        var best: [Int: (score: Int, tone: Int)] = [:]
        for reading in usable {
            let allowed = reading.letters.count > 7 ? 2 : 1
            let readingBytes = Array(reading.letters.utf8)
            let readingCounts = Self.histogram(of: readingBytes)
            for length in max(4, reading.letters.count - allowed)...(reading.letters.count + allowed) {
                for index in byLength[length] ?? [] {
                    if excluded[index] { continue }
                    // A reading is rarely wrong at both ends at once, so a word must share the first or last letter with it.
                    let candidate = spelled[index]
                    guard candidate.first == readingBytes.first || candidate.last == readingBytes.last else { continue }
                    // One edit changes the letter counts by at most two, so a larger difference cannot be within range.
                    guard Self.histogramGap(readingCounts, histogram[index]) <= 2 * allowed else { continue }
                    let distance = Self.boundedDistance(readingBytes, spelled[index], limit: allowed)
                    guard distance <= allowed else { continue }
                    var mismatches = 0
                    let tones = rows[index].tones
                    if tones.count == reading.tones.count {
                        for (written, expected) in zip(reading.tones, tones) where written != 0 && written != expected { mismatches += 1 }
                    }
                    // A word whose tones disagree with the marks that were written is a different word.
                    guard mismatches == 0 else { continue }
                    if let existing = best[index], existing.score <= distance { continue }
                    best[index] = (distance, mismatches)
                }
            }
        }
        guard let top = best.values.map(\.score).min() else { return [] }
        var seenHanzi = Set<String>()
        return best.filter { $0.value.score == top }.sorted { a, b in
            let ra = rows[a.key], rb = rows[b.key]
            if ra.frequency != rb.frequency { return ra.frequency > rb.frequency }
            if ra.hanzi.count != rb.hanzi.count { return ra.hanzi.count < rb.hanzi.count }
            return a.key < b.key
        }.compactMap { seenHanzi.insert(rows[$0.key].hanzi).inserted ? rows[$0.key] : nil }.prefix(5).map { $0 }
    }

    @_optimize(speed)
    private static func histogram(of bytes: [UInt8]) -> [UInt8] {
        var counts = [UInt8](repeating: 0, count: 26)
        for b in bytes where b >= 97 && b <= 122 { counts[Int(b - 97)] &+= 1 }
        return counts
    }

    @_optimize(speed)
    private static func histogramGap(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var gap = 0
        for i in 0..<26 { gap += abs(Int(a[i]) - Int(b[i])) }
        return gap
    }

    /// Edit distance between two ASCII strings, or `limit + 1` as soon as it must exceed `limit`.
    @_optimize(speed)
    private static func boundedDistance(_ a: [UInt8], _ b: [UInt8], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previous = Array(0...b.count)
        var row = previous
        for i in 1...max(a.count, 1) where !a.isEmpty {
            row[0] = i
            var smallest = row[0]
            for j in 1...max(b.count, 1) where !b.isEmpty {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                smallest = min(smallest, row[j])
            }
            if smallest > limit { return limit + 1 }
            swap(&previous, &row)
        }
        return b.isEmpty ? a.count : previous[b.count]
    }

    /// One tone per written word (the first tone mark in it), 0 where a word has none.
    static func writtenToneList(_ reading: String) -> [Int] {
        let marks: [UInt32: Int] = [0x0304: 1, 0x0301: 2, 0x030C: 3, 0x0300: 4]
        return reading.split(whereSeparator: \.isWhitespace).map { word in
            for scalar in String(word).decomposedStringWithCanonicalMapping.unicodeScalars { if let t = marks[scalar.value] { return t } }
            return 0
        }
    }

    /// Lowercase ASCII letters only, with look-alike marks recognizers produce folded in (`×`→x, `√`→v, v→u, ü→u).
    static func foldedLetters(_ text: String) -> String {
        let mapped = text.lowercased().replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: "√", with: "v")
        let flat = mapped.folding(options: .diacriticInsensitive, locale: nil)
        return String(flat.filter { $0.isASCII && $0.isLetter }).replacingOccurrences(of: "v", with: "u")
    }

    /// Entries whose tones agree with every tone mark the student wrote come first; then shorter words.
    private static func ranked(_ rows: [Row], written: [(raw: String, folded: String)]) -> [Row] {
        let marks = writtenTones(written)
        func agrees(_ row: Row) -> Bool {
            guard !marks.isEmpty else { return true }
            let tones = row.tones
            guard tones.count >= marks.count else { return false }
            for (offset, mark) in marks.enumerated() where mark != 0 && tones[offset] != mark { return false }
            return true
        }
        var seen = Set<String>()
        let unique = rows.filter { seen.insert($0.hanzi + "|" + $0.numbered).inserted }
        let good = unique.filter(agrees)
        let pool = good.isEmpty ? unique : good
        let explained = Set(written.map(\.folded)).isEmpty ? 0 : written.map(\.folded).joined().count
        return pool.enumerated().sorted { a, b in
            // With Pinyin written, the word whose spelling accounts for more of it comes first (学习 xuexi over 学 xue).
            if explained > 0 {
                let la = a.element.letters.count <= explained ? a.element.letters.count : 0
                let lb = b.element.letters.count <= explained ? b.element.letters.count : 0
                if la != lb { return la > lb }
            }
            // A common word before a rare one that is spelled the same (是 before 氏).
            if a.element.frequency != b.element.frequency { return a.element.frequency > b.element.frequency }
            if a.element.hanzi.count != b.element.hanzi.count { return a.element.hanzi.count < b.element.hanzi.count }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The tone (1–4) of each written syllable that has a tone mark, 0 where none is written. Only the first marked
    /// letters of each written word are read; words are not split into syllables here, so this is approximate and is
    /// used only to order candidates (the matcher does the exact letter-by-letter check).
    private static func writtenTones(_ pairs: [(raw: String, folded: String)]) -> [Int] {
        let marks: [UInt32: Int] = [0x0304: 1, 0x0301: 2, 0x030C: 3, 0x0300: 4]
        var tones: [Int] = []
        for pair in pairs {
            var tone = 0
            for scalar in pair.raw.decomposedStringWithCanonicalMapping.unicodeScalars { if let t = marks[scalar.value] { tone = t } }
            tones.append(tone)
        }
        return tones.contains { $0 != 0 } ? tones : []
    }

    // MARK: - Pinyin spelling

    static func isPinyin(_ field: Substring) -> Bool {
        guard !field.isEmpty else { return false }
        for syllable in field.split(separator: " ") {
            guard let digit = syllable.last, ("1"..."5").contains(digit) else { return false }
            let letters = syllable.dropLast()
            guard !letters.isEmpty, letters.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == ":") }) else { return false }
        }
        return true
    }

    /// `hao3 xiang4` → `haoxiang`; `nu:3` → `nu`.
    static func letters(of numbered: String) -> String {
        String(numbered.lowercased().filter { $0.isASCII && $0.isLetter })
    }

    /// `hao3 xiang4` → `hǎoxiàng`. The mark goes on `a` or `e`, on the `o` of `ou`, else on the last vowel.
    static func toneMarked(_ numbered: String) -> String {
        numbered.split(separator: " ").map { markSyllable(String($0)) }.joined()
    }

    private static let marks: [Character: [Character]] = [
        "a": ["ā", "á", "ǎ", "à"], "e": ["ē", "é", "ě", "è"], "i": ["ī", "í", "ǐ", "ì"],
        "o": ["ō", "ó", "ǒ", "ò"], "u": ["ū", "ú", "ǔ", "ù"], "ü": ["ǖ", "ǘ", "ǚ", "ǜ"],
    ]

    private static func markSyllable(_ syllable: String) -> String {
        guard let digit = syllable.last, let tone = Int(String(digit)) else { return syllable }
        var letters = Array(syllable.dropLast().lowercased().replacingOccurrences(of: "u:", with: "ü").replacingOccurrences(of: "v", with: "ü"))
        guard (1...4).contains(tone) else { return String(letters) }
        let vowels = letters.indices.filter { "aeiouü".contains(letters[$0]) }
        guard !vowels.isEmpty else { return String(letters) }
        var target = vowels.last!
        if let a = letters.firstIndex(where: { $0 == "a" || $0 == "e" }) {
            target = a
        } else if let o = letters.firstIndex(of: "o"), letters.indices.contains(o + 1), letters[o + 1] == "u" {
            target = o
        }
        if let marked = marks[letters[target]]?[tone - 1] { letters[target] = marked }
        return String(letters)
    }

    // MARK: - Glosses

    static func isVariantGloss(_ gloss: String) -> Bool {
        let g = gloss.lowercased()
        return ["variant of", "old variant of", "also written", "erhua variant", "archaic variant", "same as", "see ", "abbr. for",
                "japanese variant", "taiwan pr."].contains { g.hasPrefix($0) }
    }

    /// Real senses: not classifier lists (`CL:个`), cross-references or pronunciation notes.
    static func cleanSenses(_ glosses: [String]) -> [String] {
        glosses.filter { g in
            let lower = g.lowercased()
            return !lower.hasPrefix("cl:") && !lower.hasPrefix("see also") && !lower.hasPrefix("see ") && !lower.hasPrefix("also pr.")
                && !lower.hasPrefix("taiwan pr.") && !lower.hasPrefix("(old)") && !g.isEmpty
        }
    }

    static func shortGloss(_ glosses: [String]) -> String {
        let senses = cleanSenses(glosses)
        guard let first = senses.first else { return glosses.first ?? "" }
        if senses.count > 1, first.count + senses[1].count < 48, !first.contains(";") { return first + "; " + senses[1] }
        return first
    }
}
