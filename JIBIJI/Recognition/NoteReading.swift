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
        /// Engine-tagged readings of this cell. When empty, `text` and `readings` stand in as evidence.
        var evidence: [NoteEvidence.Reading] = []
    }

    /// Reads a set of strokes as one region with every engine. Used for a field's joined strokes and for the whole note.
    typealias RegionReader = (_ strokes: [PKStroke]) async throws -> [NoteEvidence.Reading]

    /// Whether pages are read as grouped notes. On by default; set the default `JibijiNoteGrouping` to false to
    /// fall back to the earlier line-based reading.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "JibijiNoteGrouping") as? Bool ?? true }

    static func lines(
        in drawing: PKDrawing,
        vocabulary: StarterVocabulary = .standard,
        readRegion: RegionReader? = nil,
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
        #if DEBUG
        print("NOTEREADING cells=\(cells.count) readings=\(readings.map { $0.text ?? "-" })")
        #endif
        var lines: [RecognizedLine] = []
        for entry in NoteGrouping.entries(from: readings, vocabulary: vocabulary) {
            try Task.checkCancellation()
            var evidence = cellEvidence(for: entry, cells: cells, reads: reads)
            if let readRegion {
                // Whole-line context is kept beside the per-field readings: the note as one line, and each Latin
                // field's strokes together (`hǎo` + `xiang`), read by every engine before anything is decided.
                for kind in NoteGrouping.FieldKind.allCases {
                    guard let field = entry.field(kind) else { continue }
                    // A field that is one cell was already read as that cell; reading it again would only count one reading twice.
                    let members = cells.filter { !$0.strokeIndices.isEmpty && Set($0.strokeIndices).isSubset(of: Set(field.strokeIndices)) }
                    guard members.count > 1 else { continue }
                    let strokes = field.strokeIndices.map { drawing.strokes[$0] }
                    for var reading in try await readRegion(strokes) { reading.scope = .field; reading.field = kind; evidence.append(reading) }
                }
                if entry.fields.count > 1 || entry.strokeIndices.count > 1 {
                    let strokes = entry.strokeIndices.map { drawing.strokes[$0] }
                    for var reading in try await readRegion(strokes) { reading.scope = .entry; reading.field = nil; evidence.append(reading) }
                }
            }
            #if DEBUG
            print("NOTEREADING resolving entry strokes=\(entry.strokeIndices.count) evidence=\(evidence.count)")
            DebugTrace.log("resolving entry strokes=\(entry.strokeIndices.count) evidence=\(evidence.count)")
            #endif
            let built = line(for: entry, evidence: evidence, vocabulary: vocabulary)
            #if DEBUG
            DebugTrace.log("resolved entry -> \(built?.text ?? "nil")")
            #endif
            if let line = built { lines.append(line) }
        }
        return lines
    }

    /// The cell readings behind an entry, tagged by the field they are about (and whether they are only part of it).
    private static func cellEvidence(for entry: NoteGrouping.Entry, cells: [NoteLayout.CellCandidate],
                                     reads: [[Int]: CellRead]) -> [NoteEvidence.Reading] {
        var result: [NoteEvidence.Reading] = []
        for kind in NoteGrouping.FieldKind.allCases {
            guard let field = entry.field(kind) else { continue }
            let members = cells.filter { !$0.strokeIndices.isEmpty && Set($0.strokeIndices).isSubset(of: Set(field.strokeIndices)) }
            let whole = members.count == 1 && members[0].strokeIndices == field.strokeIndices
            let sole = Set(entry.fields.map(\.strokeIndices)).count == 1   // one cell holds several fields
            for cell in members {
                guard let read = reads[cell.strokeIndices] else { continue }
                for reading in tagged(read) {
                    var r = reading
                    r.field = sole ? nil : kind
                    r.partial = !whole
                    if !result.contains(r) { result.append(r) }
                }
            }
        }
        return result
    }

    private static func tagged(_ read: CellRead) -> [NoteEvidence.Reading] {
        if !read.evidence.isEmpty { return read.evidence.map { var r = $0; r.scope = .cell; return r } }
        var list = [NoteEvidence.Reading(text: read.text, engine: .pencilKit, scope: .cell)]
        if let source = read.sourceText, source != read.text { list.append(.init(text: source, engine: .pencilKit, scope: .cell)) }
        for reading in read.readings where reading != read.text { list.append(.init(text: reading, engine: .vision, scope: .cell)) }
        return list
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

    private static func line(for entry: NoteGrouping.Entry, evidence: [NoteEvidence.Reading], vocabulary: StarterVocabulary) -> RecognizedLine? {
        guard !entry.fields.isEmpty, !entry.bounds.isEmpty else { return nil }
        let resolved = FieldResolver.resolve(entry: entry, readings: evidence, vocabulary: vocabulary)
        #if DEBUG
        print("RESOLVED text=\(resolved.cleanText) pinyin=\(resolved.pinyin.status.rawValue) hanzi=\(resolved.hanzi.status.rawValue) english=\(resolved.english.status.rawValue)")
        #endif
        var line = RecognizedLine(text: resolved.cleanText, bounds: entry.bounds)
        line.strokeIndices = entry.strokeIndices
        line.resolved = resolved
        line.alsoRead = [entry.text]
        // Raw OCR readings are diagnostics (`resolved.diagnostics`). They are not "other readings" and not alternatives.
        var notes: [String] = []
        if let doubt = resolved.reviewNote { notes.append(doubt) }
        // Grouping's own doubts: a Pinyin that fits no Hanzi reading, or several Hanzi runs in one cell.
        let explained = vocabulary.proposal(forRecognizedText: resolved.cleanText) != nil
        notes += entry.uncertainty.filter { ($0.contains("doesn't match") && !explained && resolved.pinyin.status != .confirmed) || $0.hasPrefix("Several Hanzi runs") }
        if !notes.isEmpty || !resolved.inkReplacementIsSafe {
            line.reviewNote = notes.isEmpty ? resolved.reviewNote : notes.joined(separator: "; ")
            line.inkEditSuppressed = true
        }
        return line
    }
}
