#if DEBUG
import Foundation
import PencilKit
import Testing
@testable import JIBIJI

private struct StubReader: NoteCellReader {
    var texts: [String?]
    var failure: (any Error)?
    func read(_ cells: [NoteLayout.CellCandidate], in drawing: PKDrawing) async throws -> [NoteCellText] {
        if let failure { throw failure }
        return texts.map { NoteCellText(raw: $0, text: $0) }
    }
}

@Suite("Note analysis")
struct NoteAnalysisTests {
    private func ink(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat) -> [PKStroke] {
        SyntheticInk.drawing(writing: text, origin: CGPoint(x: x, y: y), glyphSize: size, spacing: 4).strokes
    }

    @Test func partialHanziPinyinSuggestsTheWordAndEnglishWithoutTouchingInk() async {
        let drawing = PKDrawing(strokes: ink("大人", x: 80, y: 100, size: 56))
        let before = drawing.dataRepresentation()
        let analysis = await NoteAnalyzer.analyze(drawing, reader: StubReader(texts: ["好 hǎo xiang"]))
        #expect(drawing.dataRepresentation() == before)
        #expect(analysis.errors.isEmpty)
        #expect(analysis.entries.count == 1)
        let item = analysis.entries[0]
        #expect(item.entry.missing == [.english])
        #expect(item.suggestion?.candidate.hanzi == "好像")
        #expect(item.suggestion?.candidate.gloss == "to seem like; to look like")
        #expect(item.suggestion?.completesHanziFrom == "好")
        #expect(item.suggestion?.fills.contains(.english) == true)
        #expect(item.uncertainty.contains { $0.contains("only part of the suggested word") })
    }

    @Test func readerFailureIsReportedAndNothingCrashes() async {
        let drawing = PKDrawing(strokes: ink("大人", x: 80, y: 100, size: 56))
        let analysis = await NoteAnalyzer.analyze(drawing, reader: StubReader(texts: [], failure: InkLineReaderError.unsupported))
        #expect(analysis.errors.first?.contains("iPadOS 27") == true)
        #expect(analysis.entries.isEmpty)
    }

    @Test(arguments: [[], ["好 hǎo xiang", "extra"]] as [[String?]])
    func wrongNumberOfReadingsIsAnErrorNotACrash(_ texts: [String?]) async {
        let drawing = PKDrawing(strokes: ink("大人", x: 80, y: 100, size: 56))
        let analysis = await NoteAnalyzer.analyze(drawing, reader: StubReader(texts: texts))
        #expect(analysis.errors.contains { $0.contains("wrong number of results") })
        #expect(analysis.cellTexts.count == analysis.cells.count)
        #expect(analysis.entries.isEmpty)
    }

    @Test func emptyPageHasNoEntriesAndNoErrors() async {
        let analysis = await NoteAnalyzer.analyze(PKDrawing(), reader: StubReader(texts: []))
        #expect(analysis.entries.isEmpty && analysis.errors.isEmpty)
    }

    @Test func reportCoversFieldsRegionsMissingSuggestionAndTimingButNoLanguageInventory() async {
        let drawing = PKDrawing(strokes: ink("大人", x: 80, y: 100, size: 56))
        let report = NoteAnalyzer.reportText(await NoteAnalyzer.analyze(drawing, reader: StubReader(texts: ["好 hǎo xiang"])))
        for expected in ["Hanzi: “好”", "Pinyin: “hǎo xiang”", "English: missing", "Suggestion (tentative): 好像", "Uncertain:", "Time: read", "PencilKit “好 hǎo xiang”", "x 8"] {
            #expect(report.contains(expected), "\(expected)")
        }
        #expect(!report.contains("Supported languages"))
    }
}
#endif
