#if DEBUG
import Foundation
import PencilKit
import Testing
@testable import JIBIJI

/// Pure grouping tests: hand-fed cell text on synthetic ink geometry, no recognizer needed.
@Suite("Note grouping")
struct NoteGroupingTests {
    private func ink(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, spacing: CGFloat = 4) -> [PKStroke] {
        SyntheticInk.drawing(writing: text, origin: CGPoint(x: x, y: y), glyphSize: size, spacing: spacing).strokes
    }

    private func entries(_ strokes: [PKStroke], _ texts: [String?]) -> [NoteGrouping.Entry] {
        let cells = NoteLayout.candidates(rects: strokes.map(\.renderBounds)).flatMap(\.cells)
        #expect(cells.count == texts.count, "cell count")
        return NoteGrouping.entries(from: zip(cells, texts).map { .init(cell: $0, text: $1) })
    }

    @Test func parsesMixedCellIntoHanziPinyinAndEnglish() {
        let parsed = NoteGrouping.parse("好 hǎo xiang to seem like")
        #expect(parsed.hanzi == "好")
        #expect(parsed.pinyin == "hǎo xiang")
        #expect(parsed.english == "to seem like")
    }

    @Test func plainEnglishStaysEnglishAndBareSyllablesStayAmbiguous() {
        #expect(NoteGrouping.parse("responsible for").english == "responsible for")
        #expect(NoteGrouping.parse("fuze").pinyin == "fuze") // the starter vocabulary knows it
        #expect(NoteGrouping.parse("mei").ambiguousLatin == "mei")
    }

    @Test func oneCellWithPartialEntryReportsWhatIsMissing() {
        let result = entries(ink("大人", x: 80, y: 100, size: 56), ["好 hǎo xiang"])
        #expect(result.count == 1)
        #expect(result[0].hanzi?.text == "好")
        #expect(result[0].pinyin?.text == "hǎo xiang")
        #expect(result[0].missing == [.english])
        #expect(result[0].arrangement == .oneCell)
    }

    @Test func adjacentEntriesWithAPartialEntryDoNotSteal() {
        let strokes =
            ink("大人", x: 80, y: 100, size: 56)
            + ink("一二", x: 223.4, y: 118, size: 20)
            + ink("三", x: 294.2, y: 118, size: 20)
            + ink("十", x: 338.1, y: 100, size: 56)
            + ink("一二", x: 418, y: 118, size: 20)
        let result = entries(strokes, ["好像", "hǎoxiàng", "to seem like", "负责", "fùzé"])
        #expect(result.count == 2)
        #expect(result[0].hanzi?.text == "好像")
        #expect(result[0].pinyin?.text == "hǎoxiàng")
        #expect(result[0].english?.text == "to seem like")
        #expect(result[0].missing.isEmpty)
        #expect(result[1].hanzi?.text == "负责")
        #expect(result[1].pinyin?.text == "fùzé")
        #expect(result[1].missing == [.english])
        #expect(result[1].arrangement == .sideBySide)
    }

    @Test func pinyinAboveHanziAndEnglishBelowFormOneStackedEntry() {
        let strokes = ink("一二", x: 90, y: 100, size: 22) + ink("大人", x: 80, y: 128, size: 64) + ink("一二", x: 90, y: 200, size: 22)
        let result = entries(strokes, ["fùzé", "负责", "to be responsible for"])
        #expect(result.count == 1)
        #expect(result[0].hanzi?.text == "负责")
        #expect(result[0].pinyin?.text == "fùzé")
        #expect(result[0].english?.text == "to be responsible for")
        #expect(result[0].arrangement == .stacked)
        #expect(result[0].uncertainty.isEmpty)
    }

    @Test func stackedEntriesKeepTheirOwnFields() {
        let strokes =
            ink("大人", x: 80, y: 100, size: 56) + ink("一二", x: 230, y: 118, size: 20)
            + ink("十人", x: 80, y: 300, size: 56) + ink("一二", x: 230, y: 318, size: 20)
        let result = entries(strokes, ["负责", "fùzé", "复习", "fùxí"])
        #expect(result.map { $0.hanzi?.text } == ["负责", "复习"])
        #expect(result.map { $0.pinyin?.text } == ["fùzé", "fùxí"])
    }

    @Test func mismatchedPinyinStaysAttachedButIsFlagged() {
        let strokes = ink("大人", x: 80, y: 100, size: 56) + ink("一二", x: 230, y: 118, size: 20)
        let result = entries(strokes, ["负责", "fùxí"])
        #expect(result.count == 1)
        #expect(result[0].uncertainty.contains { $0.contains("doesn't match") })
    }

    @Test func unreadCellsAreSkippedAndLooseLatinIsAnEntryWithoutHanzi() {
        let strokes = ink("大人", x: 80, y: 100, size: 56) + ink("十人", x: 400, y: 100, size: 56)
        let result = entries(strokes, [nil, "to seem like"])
        #expect(result.count == 1)
        #expect(result[0].hanzi == nil)
        #expect(result[0].missing.contains(.hanzi))
    }
}
#endif
