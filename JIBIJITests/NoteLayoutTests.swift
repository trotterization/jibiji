import Foundation
import PencilKit
import Testing
@testable import JIBIJI

/// Pure geometry tests on synthetic ink: no recognizer needed. Layout only proposes candidates with evidence;
/// these tests pin down what it proposes for realistic, close spacing.
@Suite("Note layout candidates")
struct NoteLayoutTests {
    private func ink(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, spacing: CGFloat = 4) -> [PKStroke] {
        SyntheticInk.drawing(writing: text, origin: CGPoint(x: x, y: y), glyphSize: size, spacing: spacing).strokes
    }

    private func candidates(_ strokes: [PKStroke]) -> [NoteLayout.RowCandidate] {
        NoteLayout.candidates(rects: strokes.map(\.renderBounds))
    }

    @Test func emptyInkHasNoCandidates() {
        #expect(NoteLayout.candidates(in: PKDrawing()).isEmpty)
    }

    @Test func stackedEntriesWithClearGapAreSeparateRows() {
        let rows = candidates(ink("大人", x: 80, y: 120, size: 60) + ink("十人", x: 80, y: 360, size: 60))
        #expect(rows.count == 2)
        #expect(rows[1].boundaryAbove?.evidence == .clearGap)
    }

    @Test func pinyinDirectlyAboveHanziIsItsOwnRowByScaleChange() {
        let small = ink("一二", x: 90, y: 100, size: 22)   // y 100...122, Pinyin-sized strokes
        let hanzi = ink("大人", x: 80, y: 128, size: 64)    // 6 pt below: far under the old cutoff
        let strokes = small + hanzi
        // Documents the collapse this replaces: the old line detector sees one full row here.
        #expect(InkLineGeometry.lineGroups(in: PKDrawing(strokes: strokes)).count == 1)

        let rows = candidates(strokes)
        #expect(rows.count == 2)
        #expect(rows[0].strokeIndices == Array(small.indices))
        #expect(rows[1].strokeIndices == Array(hanzi.indices.map { $0 + small.count }))
        #expect(rows[1].boundaryAbove?.evidence == .scaleChange)
    }

    @Test func toneMarkAboveLettersStaysWithItsRow() {
        let letters = ink("一二", x: 90, y: 100, size: 24)
        // A detached 8 pt tone mark floating above the letters.
        let mark = SyntheticInk.stroke(through: [CGPoint(x: 100, y: 90), CGPoint(x: 106, y: 84)])
        let hanzi = ink("大人", x: 80, y: 136, size: 64)
        let strokes = letters + [mark] + hanzi
        let rows = candidates(strokes)
        #expect(rows.count == 2)
        #expect(rows[0].strokeIndices.contains(letters.count))
    }

    @Test func equalScaleTightGapIsKeptButMarkedUnclear() {
        // 二's two strokes are 0.45 of the glyph apart: a possible row break, but not a convincing one.
        let rows = candidates(ink("二", x: 80, y: 120, size: 64))
        #expect(rows.count == 2)
        #expect(rows[1].boundaryAbove?.evidence == .tightGap)
    }

    @Test func adjacentEntriesWithAPartialEntryStaySeparateCellCandidates() {
        // One row, close spacing everywhere: [大人][一二][三] then a partial entry [十][一二] with no English.
        let strokes =
            ink("大人", x: 80, y: 100, size: 56)
            + ink("一二", x: 223.4, y: 118, size: 20)
            + ink("三", x: 294.2, y: 118, size: 20)
            + ink("十", x: 338.1, y: 100, size: 56)
            + ink("一二", x: 418, y: 118, size: 20)
        let rows = candidates(strokes)
        #expect(rows.count == 1)
        let cells = rows[0].cells
        #expect(cells.count == 5)
        #expect(cells.map(\.column) == [0, 1, 2, 3, 4])
        // Characters of one word stay together; none of these gaps is convincing on its own.
        #expect(cells[0].strokeIndices.count == 5)
        #expect(cells.dropFirst().allSatisfy { $0.gapBefore?.evidence == .tightGap })
    }

    @Test func everyStrokeLandsInExactlyOneCellAndInkIsUntouched() {
        let drawing = PKDrawing(strokes: ink("大人", x: 80, y: 120, size: 60) + ink("十人", x: 520, y: 120, size: 60) + ink("大一", x: 80, y: 360, size: 60))
        let before = drawing.dataRepresentation()
        let rows = NoteLayout.candidates(in: drawing)
        #expect(rows.flatMap(\.cells).flatMap(\.strokeIndices).sorted() == Array(drawing.strokes.indices))
        #expect(drawing.dataRepresentation() == before)
    }
}
