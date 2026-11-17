#if DEBUG
import CoreGraphics
import Foundation
import PencilKit

/// What one cell read as. `raw` is always the PencilKit text; `text` is what grouping uses (the same unless refined).
struct NoteCellText: Equatable, Sendable {
    var raw: String?
    var text: String?
    var note: String?
}

/// Reads the text of layout cells. Injected so tests don't need PencilKit recognition.
protocol NoteCellReader: Sendable {
    func read(_ cells: [NoteLayout.CellCandidate], in drawing: PKDrawing) async throws -> [NoteCellText]
}

/// PencilKit per cell, then (only where the context fits) the local Paddle mobile model, as the existing
/// context-aware routing does: a Latin-only cell whose letters match the romanization of the Hanzi it sits
/// with. The raw PencilKit text is always kept.
struct PencilNoteCellReader: NoteCellReader {
    func read(_ cells: [NoteLayout.CellCandidate], in drawing: PKDrawing) async throws -> [NoteCellText] {
        guard #available(iOS 27.0, *) else { throw InkLineReaderError.unsupported }
        var texts: [NoteCellText] = []
        for cell in cells {
            try Task.checkCancellation()
            let strokes = cell.strokeIndices.map { drawing.strokes[$0] }
            let raw = await RecognitionProbe.recognizedText(in: PKDrawing(strokes: strokes), strokeIDs: Set(strokes.map(\.id)))
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            texts.append(NoteCellText(raw: raw, text: trimmed?.isEmpty == false ? trimmed : nil))
        }

        let hanziCells = cells.indices.filter { texts[$0].text.flatMap(PinyinContextHint.hanziOnly) != nil }
        for index in cells.indices where !hanziCells.contains(index) {
            try Task.checkCancellation()
            guard let latin = texts[index].text, PinyinContextHint.latinLetters(latin) != nil else { continue }
            let anchors = hanziCells.map { cells[$0] }
            let best = hanziCells
                .compactMap { anchor in
                    NoteGrouping.relation(of: cells[index], to: cells[anchor], anchors: anchors).map { (anchor, $0.score) }
                }
                .max { $0.1 < $1.1 }
            guard let (anchor, _) = best, let hanzi = texts[anchor].text.flatMap(PinyinContextHint.hanziOnly),
                  PinyinContextHint.matches(hanzi: hanzi, latin: latin)
            else { continue }
            let strokes = cells[index].strokeIndices.map { drawing.strokes[$0] }
            let result = await PinyinOCR.shared.recognizeMobile(PKDrawing(strokes: strokes))
            if let refined = result.text, !refined.isEmpty {
                texts[index].text = refined
                texts[index].note = "Pinyin refined by PaddleOCR mobile (PencilKit read “\(latin)”)"
            } else if case .modelMissing = result {
                texts[index].note = "PaddleOCR mobile model not installed; PencilKit text kept"
            }
        }
        return texts
    }
}

/// A tentative completion for one entry. Never part of the ink; nothing is saved.
struct NoteSuggestion: Equatable, Sendable {
    var candidate: SuggestionCandidate
    /// Fields of the entry this would add or complete.
    var fills: [NoteGrouping.FieldKind]
    var alternatives: [SuggestionCandidate]
    /// What the Hanzi on the page would become, when the page only has part of it (好 → 好像).
    var completesHanziFrom: String?
}

struct NoteAnalysisEntry: Equatable, Sendable {
    var entry: NoteGrouping.Entry
    var suggestion: NoteSuggestion?
    /// Layout and recognition caveats for this entry, in plain language (never empty when the entry is partial).
    var uncertainty: [String]
}

struct NoteAnalysis: Equatable, Sendable {
    var strokeCount: Int
    var rows: [NoteLayout.RowCandidate]
    var cellTexts: [NoteCellText]
    var entries: [NoteAnalysisEntry]
    var readTime: Duration
    var totalTime: Duration
    /// Anything that stopped analysis from being complete. Writing and the saved ink are unaffected.
    var errors: [String]
    var osVersion: String

    var cells: [NoteLayout.CellCandidate] { rows.flatMap(\.cells) }
}

enum NoteAnalyzer {
    static func analyze(
        _ drawing: PKDrawing,
        reader: any NoteCellReader = PencilNoteCellReader(),
        vocabulary: StarterVocabulary = .standard
    ) async -> NoteAnalysis {
        let clock = ContinuousClock()
        let start = clock.now
        let rows = NoteLayout.candidates(in: drawing)
        let cells = rows.flatMap(\.cells)
        var analysis = NoteAnalysis(
            strokeCount: drawing.strokes.count, rows: rows, cellTexts: [], entries: [],
            readTime: .zero, totalTime: .zero, errors: [], osVersion: RecognitionProbe.osVersion
        )
        guard !cells.isEmpty else {
            analysis.totalTime = start.duration(to: clock.now)
            return analysis
        }

        var texts: [NoteCellText] = Array(repeating: NoteCellText(), count: cells.count)
        do {
            // Only accept a result that has exactly one reading per cell; a short or long one is an error
            // and never replaces the blank readings (so indexing by cell below can't go out of range).
            let read = try await reader.read(cells, in: drawing)
            guard read.count == cells.count else { throw NoteAnalysisError.mismatchedReading }
            texts = read
        } catch is CancellationError {
            analysis.errors.append("Analysis was cancelled because the ink changed.")
        } catch {
            analysis.errors.append("Reading failed: \(error.localizedDescription)")
        }
        analysis.readTime = start.duration(to: clock.now)
        analysis.cellTexts = texts

        let readings = zip(cells, texts).map { NoteGrouping.Reading(cell: $0, text: $1.text) }
        let unread = cells.indices.filter { texts[$0].text == nil }
        analysis.entries = NoteGrouping.entries(from: readings, vocabulary: vocabulary).map {
            annotate($0, unreadCells: unread.map { cells[$0] }, rows: rows, vocabulary: vocabulary)
        }
        if !unread.isEmpty, analysis.errors.isEmpty {
            analysis.errors.append("\(unread.count) of \(cells.count) cells read as nothing.")
        }
        analysis.totalTime = start.duration(to: clock.now)
        return analysis
    }

    private enum NoteAnalysisError: Error, LocalizedError {
        case mismatchedReading
        var errorDescription: String? { "The reader returned the wrong number of results." }
    }

    private static func annotate(_ entry: NoteGrouping.Entry, unreadCells: [NoteLayout.CellCandidate],
                                 rows: [NoteLayout.RowCandidate], vocabulary: StarterVocabulary) -> NoteAnalysisEntry {
        var uncertainty = entry.uncertainty
        var suggestion: NoteSuggestion?
        if let proposal = vocabulary.proposal(forRecognizedText: entry.text), let best = proposal.candidates.first {
            var fills: [NoteGrouping.FieldKind] = []
            let written = entry.hanzi?.text
            if written != best.hanzi { fills.append(.hanzi) }
            if entry.pinyin == nil { fills.append(.pinyin) }
            if !proposal.glossAlreadyWritten { fills.append(.english) }
            suggestion = NoteSuggestion(
                candidate: best,
                fills: fills,
                alternatives: Array(proposal.candidates.dropFirst()),
                completesHanziFrom: proposal.hanziPrefixWritten.isEmpty ? nil : proposal.hanziPrefixWritten
            )
            if written != nil, written != best.hanzi {
                uncertainty.append("Hanzi on the page (\(written!)) is only part of the suggested word")
            }
        }
        if entry.hanzi == nil, !uncertainty.contains(where: { $0.hasPrefix("No Hanzi") }) {
            uncertainty.append("No Hanzi found for this entry")
        }
        let adjacent = unreadCells.contains { cell in entry.bounds.insetBy(dx: -80, dy: -60).intersects(cell.bounds) }
        if adjacent { uncertainty.append("An unreadable cell sits next to this entry; a field may be missing") }
        return NoteAnalysisEntry(entry: entry, suggestion: suggestion, uncertainty: uncertainty)
    }

    // MARK: - Report

    /// Plain text a tester can paste into the draft PR or issue. Synthetic notes only.
    static func reportText(_ analysis: NoteAnalysis) -> String {
        func rect(_ r: CGRect) -> String { "x \(Int(r.minX)), y \(Int(r.minY)), \(Int(r.width))×\(Int(r.height)) pt" }
        func quoted(_ text: String?) -> String { text.map { "“\($0)”" } ?? "nothing" }

        var lines = ["JIBIJI note analysis", "OS: \(analysis.osVersion)",
                     "Strokes: \(analysis.strokeCount), rows: \(analysis.rows.count), cells: \(analysis.cells.count), entries: \(analysis.entries.count)",
                     "Time: read \(RecognitionReport.format(analysis.readTime)), total \(RecognitionReport.format(analysis.totalTime))"]
        if !analysis.errors.isEmpty { lines += analysis.errors.map { "Error: \($0)" } }

        lines.append("")
        lines.append("Entries")
        if analysis.entries.isEmpty { lines.append("  none") }
        for (index, item) in analysis.entries.enumerated() {
            let entry = item.entry
            lines.append("  \(index + 1). \(entry.arrangement.rawValue); \(rect(entry.bounds))")
            for kind in NoteGrouping.FieldKind.allCases {
                if let field = entry.field(kind) {
                    lines.append("     \(kind.rawValue): \(quoted(field.text)) at \(rect(field.bounds)) [\(field.strokeIndices.count) strokes]")
                } else {
                    lines.append("     \(kind.rawValue): missing")
                }
            }
            if let suggestion = item.suggestion {
                let candidate = suggestion.candidate
                lines.append("     Suggestion (tentative): \(candidate.hanzi) (\(candidate.pinyin)) “\(candidate.gloss)”; would add \(suggestion.fills.map(\.rawValue).joined(separator: ", "))")
                if let from = suggestion.completesHanziFrom { lines.append("     Completes written Hanzi “\(from)”") }
                if !suggestion.alternatives.isEmpty {
                    lines.append("     Alternatives: " + suggestion.alternatives.map { "\($0.hanzi) “\($0.gloss)”" }.joined(separator: "; "))
                }
            } else {
                lines.append("     Suggestion: none (starter vocabulary has no match)")
            }
            lines += item.uncertainty.map { "     Uncertain: \($0)" }
        }

        lines.append("")
        lines.append("Cells (layout candidates, read order)")
        var index = 0
        for row in analysis.rows {
            for cell in row.cells {
                let text = analysis.cellTexts.indices.contains(index) ? analysis.cellTexts[index] : NoteCellText()
                index += 1
                var line = "  r\(row.row + 1)c\(cell.column + 1): PencilKit \(quoted(text.raw))"
                if let used = text.text, used != text.raw?.trimmingCharacters(in: .whitespacesAndNewlines) { line += ", used \(quoted(used))" }
                line += " at \(rect(cell.bounds))"
                if let gap = cell.gapBefore { line += "; gap before \(Int(gap.gap)) pt (\(gap.evidence))" }
                lines.append(line)
                if let note = text.note { lines.append("     \(note)") }
            }
        }
        for row in analysis.rows {
            if let boundary = row.boundaryAbove {
                lines.append("  Row \(row.row + 1) boundary: gap \(Int(boundary.gap)) pt, size ratio \(String(format: "%.1f", boundary.scaleRatio)), \(boundary.evidence)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
#endif
