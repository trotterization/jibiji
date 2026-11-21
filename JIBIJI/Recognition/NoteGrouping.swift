import CoreGraphics
import Foundation

/// Final note grouping: turns layout candidates plus the text read from each cell into vocabulary entries
/// (Hanzi, Pinyin, English). Pure and always compiled; it never recognizes ink and never changes a drawing.
/// Layout only proposes cells. Here the recognized text and layout together decide who belongs with whom.
enum NoteGrouping {
    enum FieldKind: String, Sendable, CaseIterable {
        case hanzi = "Hanzi", pinyin = "Pinyin", english = "English"
    }

    /// One field of an entry and where it came from on the page.
    struct Field: Equatable, Sendable {
        var text: String
        /// Cell text as read, when the field came from part of a cell.
        var cellText: String
        var strokeIndices: [Int]
        var bounds: CGRect
    }

    enum Arrangement: String, Sendable {
        case oneCell = "one cell", sideBySide = "side by side", stacked = "stacked", single = "single field"
    }

    struct Entry: Equatable, Sendable {
        var hanzi: Field?
        var pinyin: Field?
        var english: Field?
        var arrangement: Arrangement
        /// Plain-language reasons this entry is uncertain (empty when nothing stands out).
        var uncertainty: [String]

        var missing: [FieldKind] { FieldKind.allCases.filter { field($0) == nil } }
        var fields: [Field] { [hanzi, pinyin, english].compactMap { $0 } }
        var bounds: CGRect { fields.dropFirst().reduce(fields.first?.bounds ?? .zero) { $0.union($1.bounds) } }
        var strokeIndices: [Int] { Array(Set(fields.flatMap(\.strokeIndices))).sorted() }

        func field(_ kind: FieldKind) -> Field? {
            switch kind { case .hanzi: hanzi; case .pinyin: pinyin; case .english: english }
        }

        var text: String { fields.map(\.text).joined(separator: " ") }
    }

    /// One cell's text. `nil` means nothing was read.
    struct Reading: Equatable, Sendable {
        var cell: NoteLayout.CellCandidate
        var text: String?
    }

    // MARK: - Parsing one cell's text

    private static let toneMarked = Set("āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜĀÁǍÀĒÉĚÈĪÍǏÌŌÓǑÒŪÚǓÙ")

    struct Parsed: Equatable, Sendable {
        var hanzi: String?
        var pinyin: String?
        var english: String?
        /// Latin text that is valid Pinyin syllables but has no tone marks and no Hanzi context yet.
        var ambiguousLatin: String?
        var notes: [String] = []
    }

    /// Splits text into Hanzi, tone-marked or vocabulary-known Pinyin, and English. Bare Latin that merely
    /// looks like syllables is held back as `ambiguousLatin` until an anchor's Hanzi can confirm it.
    static func parse(_ text: String, vocabulary: StarterVocabulary = .standard) -> Parsed {
        var result = Parsed()
        let runs = StarterVocabulary.hanziRuns(in: text)
        if runs.count == 1 {
            result.hanzi = runs[0]
        } else if runs.count > 1 {
            result.hanzi = runs[0]
            result.notes.append("Several Hanzi runs in one cell (\(runs.joined(separator: ", "))); kept the first")
        }

        let latin = text.unicodeScalars.map { (0x3400...0x9FFF).contains($0.value) ? " " : String($0) }.joined()
        let tokens = latin.split { !($0.isLetter || $0 == "'" || $0 == "’") }.map(String.init)
        guard !tokens.isEmpty else { return result }

        let folded = tokens.map { StarterVocabulary.latinTokens($0).joined() }
        let start = tokens.indices.first { i in
            toneMarked.contains(where: tokens[i].contains) || hasDiacritic(tokens[i]) || vocabularyKnows(Array(folded[i...]), vocabulary)
        }
        // A word with a tone-like diacritic was meant as Pinyin even when OCR garbled it (`hňo`): it stays in the
        // Pinyin position and is validated later. It is never filed as English.
        guard let start, isSyllable(folded[start]) || hasDiacritic(tokens[start]) else {
            if tokens.allSatisfy({ isSyllable(StarterVocabulary.latinTokens($0).joined()) }) {
                result.ambiguousLatin = tokens.joined(separator: " ")
            } else {
                result.english = tokens.joined(separator: " ")
            }
            return result
        }
        var end = start + 1
        while end < tokens.count, isSyllable(folded[end]) || hasDiacritic(tokens[end]) { end += 1 }
        result.pinyin = tokens[start..<end].joined(separator: " ")
        let rest = Array(tokens[..<start]) + Array(tokens[end...])
        if !rest.isEmpty { result.english = rest.joined(separator: " ") }
        return result
    }

    static func hasDiacritic(_ token: String) -> Bool {
        token.decomposedStringWithCanonicalMapping.unicodeScalars.contains { (0x0300...0x036F).contains($0.value) && $0.value != 0x0308 }
            || token.precomposedStringWithCanonicalMapping.contains { !$0.isASCII && $0.isLetter && !(0x3400...0x9FFF).contains($0.unicodeScalars.first!.value) }
    }

    private static func vocabularyKnows(_ folded: [String], _ vocabulary: StarterVocabulary) -> Bool {
        vocabulary.entries.contains { entry in
            let syllables = entry.syllables
            guard folded.count >= 1 else { return false }
            return folded.joined().hasPrefix(syllables.joined()) && !syllables.isEmpty
        }
    }

    private static let initials = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r", "z", "c", "s", "y", "w"]
    private static let finals: Set<String> = [
        "a", "o", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "ong", "er", "i", "ia", "ie", "iao", "iu", "ian", "in",
        "iang", "ing", "iong", "u", "ua", "uo", "uai", "ui", "uan", "un", "uang", "ue", "v",
    ]

    /// One or more Pinyin syllables written together ("fuze", "haoxiang"), tones and ü folded away. Permissive on purpose.
    static func isSyllable(_ folded: String) -> Bool {
        guard !folded.isEmpty, folded.count <= 16, folded.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        let letters = Array(folded)
        // reachable[i]: the first i letters split into valid syllables.
        var reachable = [Bool](repeating: false, count: letters.count + 1)
        reachable[0] = true
        for end in 1...letters.count {
            for start in max(0, end - 6)..<end where reachable[start] && isOneSyllable(String(letters[start..<end])) {
                reachable[end] = true
                break
            }
        }
        return reachable[letters.count]
    }

    private static func isOneSyllable(_ folded: String) -> Bool {
        if finals.contains(folded) { return true }
        return initials.contains { initial in
            guard folded.hasPrefix(initial) else { return false }
            let final = String(folded.dropFirst(initial.count))
            // A bare "o" final only follows b, p, m, f (and w); so "to", "so", "no" are English, not Pinyin.
            if final == "o" { return ["b", "p", "m", "f", "w"].contains(initial) }
            return finals.contains(final)
        }
    }

    // MARK: - Grouping

    /// Groups cells into entries. `readings` are the cells of every row in reading order.
    private struct Piece {
        var reading: Reading
        var parsed: Parsed
        var cellText: String
    }

    /// Latin writing right beside a Hanzi that is *almost* the start of its romanization (`ho` for 好 `hao`) is
    /// Pinyin the recognizer lost a tone mark from, not English. It is filed as Pinyin, where it fails validation and
    /// stays unresolved, instead of becoming the English field. Stacked writing is not judged this way.
    private static func reclassifyMisreadPinyin(_ input: [Piece], vocabulary: StarterVocabulary) -> [Piece] {
        var pieces = input
        for index in pieces.indices {
            let p = pieces[index]
            guard p.parsed.hanzi == nil, p.parsed.pinyin == nil, let english = p.parsed.english else { continue }
            let letters = StarterVocabulary.latinTokens(english).joined()
            guard letters.count >= 2, letters.count <= 8 else { continue }
            let cell = p.reading.cell.bounds
            let anchor = pieces.filter { a in
                guard let hanzi = a.parsed.hanzi, !hanzi.isEmpty else { return false }
                let b = a.reading.cell.bounds
                return cell.minX >= b.maxX - 1 && min(b.maxY, cell.maxY) - max(b.minY, cell.minY) > 0.3 * min(b.height, cell.height)
            }.min { $0.reading.cell.bounds.maxX < $1.reading.cell.bounds.maxX ? false : true }
            guard let hanzi = anchor?.parsed.hanzi else { continue }
            let rom = ReadingCrossCheck.romanization(of: hanzi)
            let vocab = vocabulary.entries.filter { $0.hanzi.hasPrefix(hanzi) }.map { $0.syllables.joined() }
            let near = ([rom] + vocab).contains { target in
                !target.isEmpty && ((max(1, letters.count - 1))...(letters.count + 1)).contains { n in
                    n <= target.count && StarterVocabulary.editDistance(letters, String(target.prefix(n))) <= 1
                }
            }
            if near {
                var parsed = p.parsed
                parsed.pinyin = english
                parsed.english = nil
                parsed.notes.append("“\(english)” looks like a misread Pinyin for \(hanzi)")
                pieces[index].parsed = parsed
            }
        }
        return pieces
    }

    /// Pinyin written with a word space (`hǎo | xiang`) is several cells. A Pinyin piece followed on the same row by
    /// pieces that are only Pinyin syllables is one Pinyin field; its syllables are not English and are not lost.
    private static func joinLatinNeighbours(_ input: [Piece], vocabulary: StarterVocabulary) -> [Piece] {
        var pieces = input
        var index = 0
        while index < pieces.count {
            let a = pieces[index]
            guard a.parsed.hanzi == nil, a.parsed.pinyin != nil, a.parsed.english == nil else { index += 1; continue }
            let next = pieces.indices.filter { $0 != index }.compactMap { j -> (Int, CGFloat)? in
                let b = pieces[j]
                guard b.parsed.hanzi == nil, b.parsed.english == nil, b.parsed.pinyin != nil || b.parsed.ambiguousLatin != nil else { return nil }
                let ab = a.reading.cell.bounds, bb = b.reading.cell.bounds
                let overlap = min(ab.maxY, bb.maxY) - max(ab.minY, bb.minY)
                let gap = bb.minX - ab.maxX
                let reach = 3.5 * max(a.reading.cell.scale, b.reading.cell.scale, 12)
                guard overlap > 0.4 * min(ab.height, bb.height), gap >= -1, gap <= reach else { return nil }
                return (j, gap)
            }.min { $0.1 < $1.1 }
            guard let (j, _) = next else { index += 1; continue }
            let b = pieces[j]
            let cell = NoteLayout.CellCandidate(
                strokeIndices: (a.reading.cell.strokeIndices + b.reading.cell.strokeIndices).sorted(),
                bounds: a.reading.cell.bounds.union(b.reading.cell.bounds), column: a.reading.cell.column,
                scale: max(a.reading.cell.scale, b.reading.cell.scale), gapBefore: a.reading.cell.gapBefore)
            let text = a.cellText + " " + b.cellText
            pieces[index] = Piece(reading: .init(cell: cell, text: text), parsed: parse(text, vocabulary: vocabulary), cellText: text)
            pieces.remove(at: j)
            index = 0   // the joined piece may take the next syllable too
        }
        return pieces
    }

    static func entries(from readings: [Reading], vocabulary: StarterVocabulary = .standard) -> [Entry] {
        let pieces = joinLatinNeighbours(reclassifyMisreadPinyin(readings.compactMap { reading -> Piece? in
            guard let text = reading.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return Piece(reading: reading, parsed: parse(text, vocabulary: vocabulary), cellText: text)
        }, vocabulary: vocabulary), vocabulary: vocabulary)

        func field(_ text: String, _ piece: Piece) -> Field {
            Field(text: text, cellText: piece.cellText, strokeIndices: piece.reading.cell.strokeIndices, bounds: piece.reading.cell.bounds)
        }

        // Anchors: pieces that carry Hanzi. Each starts an entry, keeping anything written in the same cell.
        var entries: [Entry] = []
        var anchorPieces: [Int] = []
        for (index, piece) in pieces.enumerated() where piece.parsed.hanzi != nil {
            var entry = Entry(hanzi: field(piece.parsed.hanzi!, piece), arrangement: .single, uncertainty: piece.parsed.notes)
            if let pinyin = piece.parsed.pinyin ?? piece.parsed.ambiguousLatin.map({ $0 }), piece.parsed.english == nil || piece.parsed.pinyin != nil {
                entry.pinyin = field(pinyin, piece)
            }
            if let english = piece.parsed.english { entry.english = field(english, piece) }
            if entry.fields.count > 1 { entry.arrangement = .oneCell }
            entries.append(entry)
            anchorPieces.append(index)
        }

        // Candidate links: a loose Latin piece to an anchor, scored by layout and by compatibility.
        struct Link { var piece: Int; var anchor: Int; var score: Double; var asPinyin: Bool; var stacked: Bool; var note: String? }
        var links: [Link] = []
        for (pieceIndex, piece) in pieces.enumerated() where piece.parsed.hanzi == nil {
            for (entryIndex, anchorIndex) in anchorPieces.enumerated() {
                let anchor = pieces[anchorIndex].reading.cell
                guard let relation = relation(of: piece.reading.cell, to: anchor, anchors: anchorPieces.map { pieces[$0].reading.cell }) else { continue }
                let hanzi = entries[entryIndex].hanzi!.text
                var score = relation.score
                var note: String?
                var asPinyin = piece.parsed.pinyin != nil
                if let latin = piece.parsed.ambiguousLatin {
                    if PinyinContextHint.matches(hanzi: hanzi, latin: latin) { asPinyin = true; score += 4 }
                }
                if piece.parsed.pinyin != nil {
                    let matches = PinyinContextHint.matches(hanzi: hanzi, latin: piece.parsed.pinyin!)
                        || vocabulary.entries.contains { $0.hanzi == hanzi && StarterVocabulary.latinTokens($0.pinyin) == StarterVocabulary.latinTokens(piece.parsed.pinyin!) }
                    if matches { score += 4 } else if PinyinContextHint.romanizedLetters(of: hanzi) != nil {
                        score -= 1.5
                        note = "Pinyin “\(piece.parsed.pinyin!)” doesn't match the romanization of \(hanzi)"
                    }
                }
                if !asPinyin, let english = piece.parsed.english ?? piece.parsed.ambiguousLatin,
                   let proposal = vocabulary.proposal(forRecognizedText: hanzi + " " + english),
                   proposal.candidates.first?.hanzi == hanzi { score += 2 }
                links.append(Link(piece: pieceIndex, anchor: entryIndex, score: score, asPinyin: asPinyin, stacked: relation.stacked, note: note))
            }
        }

        var used = Set<Int>()
        for link in links.sorted(by: { $0.score > $1.score }) where !used.contains(link.piece) && link.score > 0 {
            let piece = pieces[link.piece]
            var entry = entries[link.anchor]
            let text = link.asPinyin ? (piece.parsed.pinyin ?? piece.parsed.ambiguousLatin ?? "") : (piece.parsed.english ?? piece.parsed.ambiguousLatin ?? "")
            let kind: FieldKind = link.asPinyin ? .pinyin : .english
            guard !text.isEmpty, entry.field(kind) == nil else { continue }
            let value = field(text, piece)
            if kind == .pinyin { entry.pinyin = value } else { entry.english = value }
            if let rest = link.asPinyin ? piece.parsed.english : nil, entry.english == nil { entry.english = field(rest, piece) }
            if entry.arrangement == .single || entry.arrangement == .oneCell { entry.arrangement = link.stacked ? .stacked : .sideBySide }
            if let note = link.note { entry.uncertainty.append(note) }
            entries[link.anchor] = entry
            used.insert(link.piece)
        }

        // Leftover Latin pieces: a loose Pinyin and a loose English next to each other form a Hanzi-less entry.
        var leftovers = pieces.indices.filter { pieces[$0].parsed.hanzi == nil && !used.contains($0) }
        var orphans: [Entry] = []
        while let first = leftovers.first {
            leftovers.removeFirst()
            let piece = pieces[first]
            var entry = Entry(arrangement: .single, uncertainty: ["No Hanzi found for this entry"] + piece.parsed.notes)
            if let pinyin = piece.parsed.pinyin { entry.pinyin = field(pinyin, piece) }
            if let english = piece.parsed.english ?? (piece.parsed.pinyin == nil ? piece.parsed.ambiguousLatin : nil) { entry.english = field(english, piece) }
            if entry.pinyin == nil, entry.english == nil, let latin = piece.parsed.ambiguousLatin {
                entry.uncertainty.append("“\(latin)” could be Pinyin or English")
                entry.english = field(latin, piece)
            }
            if entry.pinyin != nil, entry.english == nil,
               let partner = leftovers.first(where: { other in
                   pieces[other].parsed.pinyin == nil
                       && relation(of: pieces[other].reading.cell, to: piece.reading.cell, anchors: [piece.reading.cell]) != nil
               }) {
                leftovers.removeAll { $0 == partner }
                let other = pieces[partner]
                if let english = other.parsed.english ?? other.parsed.ambiguousLatin {
                    entry.english = field(english, other)
                    entry.arrangement = relation(of: other.reading.cell, to: piece.reading.cell, anchors: [piece.reading.cell])?.stacked == true ? .stacked : .sideBySide
                }
            }
            orphans.append(entry)
        }

        var all = entries + orphans
        for index in all.indices {
            let hanzi = all[index].hanzi?.text
            if let hanzi, let pinyin = all[index].pinyin?.text,
               PinyinContextHint.romanizedLetters(of: hanzi) != nil,
               !PinyinContextHint.matches(hanzi: hanzi, latin: pinyin),
               !vocabulary.entries.contains(where: { $0.hanzi == hanzi && StarterVocabulary.latinTokens($0.pinyin) == StarterVocabulary.latinTokens(pinyin) }) {
                let note = "Pinyin “\(pinyin)” doesn't match the romanization of \(hanzi)"
                if !all[index].uncertainty.contains(note) { all[index].uncertainty.append(note) }
            }
            if let pinyin = all[index].pinyin?.text, !pinyin.contains(where: toneMarked.contains) {
                all[index].uncertainty.append("Pinyin has no tone marks")
            }
        }
        return all.sorted {
            let a = $0.bounds, b = $1.bounds
            return abs(a.minY - b.minY) > min(a.height, b.height) / 2 ? a.minY < b.minY : a.minX < b.minX
        }
    }

    /// How a loose cell sits relative to an anchor, or nil when it can't belong to it: to the right on the same
    /// row, or in the same column directly below or above, with no other anchor in between.
    static func relation(of cell: NoteLayout.CellCandidate, to anchor: NoteLayout.CellCandidate,
                         anchors: [NoteLayout.CellCandidate]) -> (score: Double, stacked: Bool)? {
        let a = anchor.bounds, c = cell.bounds
        let verticalOverlap = min(a.maxY, c.maxY) - max(a.minY, c.minY)
        let horizontalOverlap = min(a.maxX, c.maxX) - max(a.minX, c.minX)
        let others = anchors.filter { $0 != anchor }

        if c.minX >= a.maxX - 1, verticalOverlap > 0.3 * min(a.height, c.height) {
            let gap = c.minX - a.maxX
            let blocked = others.contains { $0.bounds.minX >= a.maxX - 1 && $0.bounds.maxX <= c.minX + 1
                && min($0.bounds.maxY, c.maxY) - max($0.bounds.minY, c.minY) > 0 }
            return blocked ? nil : (3 - Double(gap) / 400, false)
        }
        if horizontalOverlap > 0.3 * min(a.width, c.width) {
            let below = c.minY >= a.maxY - 1, above = c.maxY <= a.minY + 1
            guard below || above else { return nil }
            let gap = below ? c.minY - a.maxY : a.minY - c.maxY
            let blocked = others.contains { other in
                let o = other.bounds
                let between = below ? (o.minY >= a.maxY - 1 && o.maxY <= c.minY + 1) : (o.maxY <= a.minY + 1 && o.minY >= c.maxY - 1)
                return between && min(o.maxX, c.maxX) - max(o.minX, c.minX) > 0
            }
            // Stacked fields belong to the nearest note. A field further away than about two lines of the anchor's own
            // writing is a different note, and the nearer note wins by distance, not by the small "above" bonus.
            if Double(gap) > max(60, 2 * Double(max(a.height, c.height))) { return nil }
            return blocked ? nil : ((below ? 2 : 2.5) - Double(gap) / 80, true)
        }
        return nil
    }
}
