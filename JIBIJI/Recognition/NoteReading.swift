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
        let cells = NoteLayout.candidates(in: drawing).flatMap(\.cells)
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
        let notes = entry.uncertainty.filter { !$0.hasPrefix("Pinyin has no tone marks") }
        if !notes.isEmpty { line.reviewNote = notes.joined(separator: "; ") }
        return line
    }
}
