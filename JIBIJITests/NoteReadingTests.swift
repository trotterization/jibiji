import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import JIBIJI

/// Stage 3: pages are read as grouped notes (stacked or side by side), each carrying its own strokes.
/// Synthetic ink and hand-fed cell text only.
@Suite("Reading a page as notes", .serialized)
struct NoteReadingTests {
    private func ink(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, spacing: CGFloat = 4) -> PKDrawing {
        SyntheticInk.drawing(writing: text, origin: CGPoint(x: x, y: y), glyphSize: size, spacing: spacing)
    }

    /// A piece of ink the fake recognizer "reads" as `text`; the first stroke identifies which piece a cell is.
    struct Piece { var drawing: PKDrawing; var text: String; var readings: [String] = []; var raw: String? = nil }

    private func cellRead(for strokes: [PKStroke], pieces: [Piece]) -> NoteReading.CellRead? {
        let ids = Set(strokes.map(InkSelection.identity))
        guard let piece = pieces.first(where: { !ids.isDisjoint(with: $0.drawing.strokes.map(InkSelection.identity)) }) else { return nil }
        return .init(text: piece.text, sourceText: piece.raw, readings: piece.readings)
    }

    /// A stacked note (Pinyin above Hanzi, English below) and a side-by-side note far below it.
    private struct Page {
        var pinyinA = SyntheticInk.drawing(writing: "一二", origin: CGPoint(x: 90, y: 100), glyphSize: 22, spacing: 4)
        var hanziA = SyntheticInk.drawing(writing: "大人", origin: CGPoint(x: 80, y: 128), glyphSize: 64, spacing: 4)
        var englishA = SyntheticInk.drawing(writing: "一二", origin: CGPoint(x: 90, y: 200), glyphSize: 22, spacing: 4)
        var hanziB = SyntheticInk.drawing(writing: "十人", origin: CGPoint(x: 80, y: 400), glyphSize: 56, spacing: 4)
        var pinyinB = SyntheticInk.drawing(writing: "一二", origin: CGPoint(x: 230, y: 418), glyphSize: 20, spacing: 4)
        var all: PKDrawing { PKDrawing(strokes: [pinyinA, hanziA, englishA, hanziB, pinyinB].flatMap(\.strokes)) }
    }

    private func pieces(_ p: Page, hanziA: String = "负责", hanziB: String = "复习", hanziAReadings: [String] = []) -> [Piece] {
        [Piece(drawing: p.pinyinA, text: "fùzé"),
         Piece(drawing: p.hanziA, text: hanziA, readings: hanziAReadings),
         Piece(drawing: p.englishA, text: "to be responsible for"),
         Piece(drawing: p.hanziB, text: hanziB),
         Piece(drawing: p.pinyinB, text: "fùxí")]
    }

    @Test func stackedAndSideBySideNotesBecomeSeparateNotesWithTheirOwnStrokes() async throws {
        let page = Page()
        let pieces = pieces(page)
        let drawing = page.all
        let lines = try await NoteReading.lines(in: drawing) { strokes, _ in cellRead(for: strokes, pieces: pieces) }
        #expect(lines.count == 2)
        let a = try #require(lines.first { $0.text.hasPrefix("负责") })
        let b = try #require(lines.first { $0.text.hasPrefix("复习") })
        #expect(a.text == "负责 fùzé to be responsible for")
        #expect(b.text == "复习 fùxí")
        func ids(_ line: RecognizedLine) -> Set<String> { Set((line.strokeIndices ?? []).map { InkSelection.identity(drawing.strokes[$0]) }) }
        #expect(ids(a) == Set([page.pinyinA, page.hanziA, page.englishA].flatMap(\.strokes).map(InkSelection.identity)))
        #expect(ids(b) == Set([page.hanziB, page.pinyinB].flatMap(\.strokes).map(InkSelection.identity)))
        #expect(!a.bounds.intersects(b.bounds))
    }

    @Test func alternativeReadingsOfOneFieldBecomeWholeNoteAlternatives() async throws {
        let page = Page()
        let pieces = pieces(page, hanziA: "负贵", hanziAReadings: ["负贵", "负责"])
        let lines = try await NoteReading.lines(in: page.all) { strokes, _ in cellRead(for: strokes, pieces: pieces) }
        let a = try #require(lines.first { $0.text.hasPrefix("负贵") })
        #expect(a.readings.contains("负责 fùzé to be responsible for"))
        // A note whose cell was read the same everywhere has no alternatives.
        #expect(lines.first { $0.text.hasPrefix("复习") }?.readings.isEmpty == true)
    }

    @Test func aLineJustBelowANoteBelongsToItNotToTheNoteBelowIt() async throws {
        // English sits 8 pt under note A's Hanzi and far above note B; A is not in the starter vocabulary, so only
        // proximity can decide.
        let page = Page()
        let pieces = pieces(page, hanziA: "未知词")
        let lines = try await NoteReading.lines(in: page.all) { strokes, _ in cellRead(for: strokes, pieces: pieces) }
        let a = try #require(lines.first { $0.text.hasPrefix("未知词") })
        #expect(a.text.hasSuffix("to be responsible for"))
        #expect(lines.first { $0.text.hasPrefix("复习") }?.text == "复习 fùxí")
    }

    @Test func wordsAndPinyinWrittenWithOrdinarySpacingStayTogether() async throws {
        // One row: a two-character word (24 pt between characters) and Pinyin of two syllables (10 pt apart).
        // Layout alone cuts both; they are one word and one Pinyin field and must be read and grouped as such.
        let hanzi = ink("大人", x: 80, y: 100, size: 56, spacing: 24)
        let pinyin = ink("一二", x: 270, y: 118, size: 20, spacing: 10)
        let pieces = [Piece(drawing: hanzi, text: "好像"), Piece(drawing: pinyin, text: "hǎo xiàng")]
        let drawing = PKDrawing(strokes: hanzi.strokes + pinyin.strokes)
        let lines = try await NoteReading.lines(in: drawing) { strokes, _ in cellRead(for: strokes, pieces: pieces) }
        #expect(lines.map(\.text) == ["好像 hǎo xiàng"])
        #expect(lines.first?.strokeIndices?.count == drawing.strokes.count)
        // The merged cells were read as one piece each, not one cell per character.
        let seen = Box()
        _ = try await NoteReading.lines(in: drawing) { strokes, _ in seen.add(strokes.count); return cellRead(for: strokes, pieces: pieces) }
        #expect(seen.counts.sorted() == [hanzi.strokes.count, pinyin.strokes.count].sorted())
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var values: [Int] = []
        func add(_ n: Int) { lock.withLock { values.append(n) } }
        var counts: [Int] { lock.withLock { values } }
    }

    @Test func aFarAwayEnglishLineIsItsOwnNoteNotAbsorbedByTheNearestOne() async throws {
        // English-only line 178 pt above a note: further than two lines of the note's writing, so it is not its field.
        let stray = ink("一二", x: 90, y: 100, size: 22)
        let hanzi = ink("大人", x: 80, y: 300, size: 64)
        let pieces = [Piece(drawing: stray, text: "weekend plans"), Piece(drawing: hanzi, text: "负责")]
        let lines = try await NoteReading.lines(in: PKDrawing(strokes: stray.strokes + hanzi.strokes)) { strokes, _ in cellRead(for: strokes, pieces: pieces) }
        #expect(Set(lines.map(\.text)) == ["weekend plans", "负责"])
    }

    @Test func groupingDoubtKeepsTheInkSafeAndSurvivesCrossChecking() async throws {
        // A Pinyin that does not fit the Hanzi is a doubt about the reading: it travels with the note and blocks replacing ink.
        let hanzi = ink("大人", x: 80, y: 100, size: 56)
        let pinyin = ink("一二", x: 230, y: 118, size: 20)
        let pieces = [Piece(drawing: hanzi, text: "负责"), Piece(drawing: pinyin, text: "fùxí")]
        let lines = try await NoteReading.lines(in: PKDrawing(strokes: hanzi.strokes + pinyin.strokes)) { strokes, _ in cellRead(for: strokes, pieces: pieces) }
        let line = try #require(lines.first)
        #expect(line.inkEditSuppressed)
        #expect(line.reviewNote?.contains("doesn't match") == true)
        let crossChecked = line.crossChecked()
        #expect(crossChecked.reviewNote?.contains("doesn't match") == true)
        #expect(crossChecked.inkEditSuppressed)
    }

    @Test func refinedCellKeepsItsRawReadingForTheWholeNote() async throws {
        let page = Page()
        var pieces = pieces(page)
        pieces[1].raw = "负贵"
        let lines = try await NoteReading.lines(in: page.all) { strokes, _ in cellRead(for: strokes, pieces: pieces) }
        let a = try #require(lines.first { $0.text.hasPrefix("负责") })
        #expect(a.sourceText == "负贵 fùzé to be responsible for")
        #expect(a.rawText == "负贵 fùzé to be responsible for")
    }

    @Test func unreadCellsAndEmptyPagesAreHandledQuietly() async throws {
        #expect(try await NoteReading.lines(in: PKDrawing()) { _, _ in .init(text: "x") }.isEmpty)
        let page = Page()
        let lines = try await NoteReading.lines(in: page.all) { _, _ in nil }
        #expect(lines.isEmpty)
        let some = try await NoteReading.lines(in: page.all) { strokes, _ in
            cellRead(for: strokes, pieces: [Piece(drawing: page.hanziB, text: "复习")])
        }
        #expect(some.count == 1)
    }

    // MARK: - Through Suggest and Cards

    private struct GroupedReader: InkLineReader {
        var pieces: [Piece]
        func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] {
            try await NoteReading.lines(in: drawing) { strokes, _ in
                let ids = Set(strokes.map(InkSelection.identity))
                guard let piece = pieces.first(where: { !ids.isDisjoint(with: $0.drawing.strokes.map(InkSelection.identity)) }) else { return nil }
                return .init(text: piece.text, sourceText: piece.raw, readings: piece.readings)
            }
        }
    }

    @MainActor @Test func suggestOffersEachGroupedNoteAndReplacingOneLeavesTheOther() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Stage3-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = Page()
        // Note A: stacked, Hanzi partial plus untoned Pinyin (好 hao xiang). Note B: side by side, partial Hanzi + Pinyin.
        let pieces = [Piece(drawing: page.pinyinA, text: "hao xiang"), Piece(drawing: page.hanziA, text: "好"),
                      Piece(drawing: page.hanziB, text: "负"), Piece(drawing: page.pinyinB, text: "fùzé")]
        let model = NotePageModel(pageID: "page-1", store: NoteStore(directory: folder), lineReader: GroupedReader(pieces: pieces))
        model.drawingDidChange(PKDrawing(strokes: [page.pinyinA, page.hanziA, page.hanziB, page.pinyinB].flatMap(\.strokes)))
        model.suggestions.request(for: model.drawing)
        await model.suggestions.task?.value
        #expect(Set(model.suggestions.pending.map { $0.candidate.hanzi }) == ["好像", "负责"])
        let a = try #require(model.suggestions.pending.first { $0.candidate.hanzi == "好像" })
        #expect(a.sourceStrokeIDs == Set([page.pinyinA, page.hanziA].flatMap(\.strokes).map(InkSelection.identity)))
        #expect(model.replaceSuggestion(a.id, with: a.cleanText))
        let generated = try #require(model.latestVisibleReplacement?.replacement?.replacementStrokeIDs)

        model.suggestions.request(for: model.drawing)
        await model.suggestions.task?.value
        // The accepted note is quiet, its generated ink is not read, and the other note is still offered.
        #expect(model.suggestions.pending.map { $0.candidate.hanzi } == ["负责"])
        let remaining = try #require(model.suggestions.pending.first)
        #expect(remaining.sourceStrokeIDs == Set([page.hanziB, page.pinyinB].flatMap(\.strokes).map(InkSelection.identity)))
        #expect(remaining.sourceStrokeIDs.isDisjoint(with: generated))
    }

    @MainActor @Test func cardsComeFromTheGroupedNoteNotFromAnotherNearbyOne() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Stage3-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = Page()
        let model = NotePageModel(pageID: "page-1", store: NoteStore(directory: folder),
                                  lineReader: GroupedReader(pieces: pieces(page)))
        model.drawingDidChange(page.all)
        await model.flashcards.refresh(from: model.drawing, annotations: []).value
        let cards = Dictionary(uniqueKeysWithValues: model.flashcards.cards.map { ($0.front, $0.back) })
        #expect(cards["负责"] == "fùzé — to be responsible for")
        #expect(cards["复习"] == "fùxí — to review")
        #expect(model.flashcards.cards.allSatisfy { !$0.back.contains("负责") })
    }

    @MainActor @Test func aLineNamingItsStrokesIsNotBoundsMatchedToItsNeighbours() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Stage3-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Two notes whose bounding boxes overlap completely: only the named strokes may be claimed.
        let first = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 100, y: 100))
        let second = SyntheticInk.drawing(writing: "人", origin: CGPoint(x: 110, y: 110))
        let drawing = PKDrawing(strokes: first.strokes + second.strokes)
        let both = first.bounds.union(second.bounds)
        struct Fixed: InkLineReader {
            var lines: [RecognizedLine]
            func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] { lines }
        }
        var a = RecognizedLine(text: "fùzé", bounds: both); a.strokeIndices = Array(first.strokes.indices)
        var b = RecognizedLine(text: "fùxí", bounds: both); b.strokeIndices = Array(first.strokes.count..<drawing.strokes.count)
        let suggestions = PageSuggestionModel(pageID: "p", store: SuggestionStore(directory: folder), reader: Fixed(lines: [a, b]))
        suggestions.request(for: drawing)
        await suggestions.task?.value
        let byHanzi = Dictionary(uniqueKeysWithValues: suggestions.pending.map { ($0.candidate.hanzi, $0.sourceStrokeIDs) })
        #expect(byHanzi["负责"] == Set(first.strokes.map(InkSelection.identity)))
        #expect(byHanzi["复习"] == Set(second.strokes.map(InkSelection.identity)))
    }
}
