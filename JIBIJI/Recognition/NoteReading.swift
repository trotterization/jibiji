import CoreGraphics
import Foundation
import PencilKit

/// Reads a page as *notes*, not as horizontal lines.
///
/// Layout proposes cells (`NoteLayout`), each cell is read on its own, and `NoteGrouping` decides which cells
/// belong to one entry (Hanzi, Pinyin, English), whether they sit side by side or stacked. Each entry becomes
/// one `RecognizedLine` that carries the exact strokes it was read from, so a neighbouring note is never
/// swept into its bounds. Pure and recognizer-agnostic: the caller supplies how one cell is read. It never
/// changes a drawing.
enum NoteReading {
    /// One layout cell as read. `text` is what grouping uses; `sourceText` is the raw reading when it was refined.
    struct CellRead: Sendable, Equatable {
        var text: String
        var sourceText: String? = nil
        /// Other readings of the same ink.
        var readings: [String] = []
    }

    /// Whether pages are read as grouped notes. On by default; set the default `JibijiNoteGrouping` to false to
    /// fall back to the earlier line-based reading.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "JibijiNoteGrouping") as? Bool ?? true }

    static func lines(
        in drawing: PKDrawing,
        vocabulary: StarterVocabulary = .standard,
        readCell: (_ strokes: [PKStroke], _ cell: NoteLayout.CellCandidate) async throws -> CellRead?
    ) async throws -> [RecognizedLine] {
        let cells = mergedCells(NoteLayout.candidates(in: drawing))
        var reads: [[Int]: CellRead] = [:]
        var readings: [NoteGrouping.Reading] = []
        for cell in cells {
            try Task.checkCancellation()
            let strokes = cell.strokeIndices.map { drawing.strokes[$0] }
            let read = try await readCell(strokes, cell)
            if let read, !read.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reads[cell.strokeIndices] = read }
            readings.append(.init(cell: cell, text: read?.text))
        }
        try Task.checkCancellation()
        return NoteGrouping.entries(from: readings, vocabulary: vocabulary).compactMap { line(for: $0, reads: reads, vocabulary: vocabulary) }
    }

    /// Layout cuts a row wherever there is a small gap, which also splits one word (`你 | 好`) or one Pinyin field
    /// (`hǎo | xiang`) written with ordinary spacing. Neighbouring cells of the same writing size with only a tight
    /// gap between them are one piece of writing, so they are read together, with the whole piece's context.
    /// A clear gap, or a change of writing size (Pinyin beside Hanzi), still separates cells.
    static func mergedCells(_ rows: [NoteLayout.RowCandidate]) -> [NoteLayout.CellCandidate] {
        var result: [NoteLayout.CellCandidate] = []
        for row in rows {
            var current: NoteLayout.CellCandidate?
            for cell in row.cells {
                if var open = current, let gap = cell.gapBefore,
                   gap.evidence == .tightGap, gap.scaleRatio < NoteLayout.scaleChangeRatio {
                    open.strokeIndices = (open.strokeIndices + cell.strokeIndices).sorted()
                    open.bounds = open.bounds.union(cell.bounds)
                    open.scale = max(open.scale, cell.scale)
                    current = open
                } else {
                    if let open = current { result.append(open) }
                    current = cell
                }
            }
            if let open = current { result.append(open) }
        }
        return result
    }

    private static let kinds = NoteGrouping.FieldKind.allCases

    private static func line(for entry: NoteGrouping.Entry, reads: [[Int]: CellRead], vocabulary: StarterVocabulary) -> RecognizedLine? {
        guard !entry.fields.isEmpty, !entry.bounds.isEmpty else { return nil }
        var base: [NoteGrouping.FieldKind: String] = [:]
        for kind in kinds { base[kind] = entry.field(kind)?.text }
        func compose(_ fields: [NoteGrouping.FieldKind: String]) -> String {
            kinds.compactMap { fields[$0] }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        /// The entry's text with one cell's contribution replaced by another reading of that cell.
        func variant(replacing cell: [Int], with reading: String) -> String {
            let parsed = NoteGrouping.parse(reading, vocabulary: vocabulary)
            var fields = base
            for kind in kinds where entry.field(kind)?.strokeIndices == cell {
                switch kind {
                case .hanzi: if let value = parsed.hanzi { fields[kind] = value }
                case .pinyin: if let value = parsed.pinyin ?? parsed.ambiguousLatin { fields[kind] = value }
                case .english: if let value = parsed.english { fields[kind] = value }
                }
            }
            return compose(fields)
        }

        let text = compose(base)
        var cellKeys: [[Int]] = []
        for field in entry.fields where !cellKeys.contains(field.strokeIndices) { cellKeys.append(field.strokeIndices) }

        var alternatives: [String] = []
        var raw: String?
        for key in cellKeys {
            guard let read = reads[key] else { continue }
            for reading in read.readings where reading != read.text {
                let candidate = variant(replacing: key, with: reading)
                if candidate != text, !alternatives.contains(candidate) { alternatives.append(candidate) }
            }
            if let source = read.sourceText, source != read.text {
                let candidate = variant(replacing: key, with: source)
                if candidate != text { raw = candidate }
            }
        }

        var line = RecognizedLine(text: text, bounds: entry.bounds, sourceText: raw, readings: Array(alternatives.prefix(12)))
        line.strokeIndices = entry.strokeIndices
        // Grouping's own doubts (for example a Pinyin that does not fit the Hanzi) travel with the note. A missing tone
        // mark is judged later against the word's Pinyin, so it is not repeated here.
        // Only doubts about the reading itself are carried (a Pinyin that does not fit its Hanzi, several Hanzi runs in
        // one cell). Whether a field is merely missing is not a doubt: the suggestion fills it. A doubted reading
        // never offers to replace the student's ink.
        // A Pinyin that fits a vocabulary word the Hanzi only begins (好 + hǎo xiàng for 好像) is explained by the
        // vocabulary itself, which also judges its tones; only an unexplained mismatch is a doubt here.
        let explained = vocabulary.proposal(forRecognizedText: text) != nil
        let notes = entry.uncertainty.filter { ($0.contains("doesn't match") && !explained) || $0.hasPrefix("Several Hanzi runs") }
        if !notes.isEmpty {
            line.reviewNote = notes.joined(separator: "; ")
            line.inkEditSuppressed = true
        }
        return line
    }
}
