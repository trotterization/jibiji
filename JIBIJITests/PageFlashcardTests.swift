import PencilKit
import XCTest
@testable import JIBIJI

private struct FakeReader: InkLineReader {
    var result: [RecognizedLine]
    func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] { result }
}

@MainActor
final class PageFlashcardTests: XCTestCase {
    private func makeStore() -> NoteStore {
        NoteStore(directory: FileManager.default.temporaryDirectory.appending(path: "flash-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    private func card(_ front: String, _ back: String, status: PageFlashcard.Status, digest: String) -> PageFlashcard {
        PageFlashcard(id: UUID(), front: front, back: back, kind: .vocabulary, sourceText: front,
                      needsReview: false, sourceBounds: .zero, inkDigest: digest, status: status, edited: false)
    }

    func testExportSanitizesAndKeepsUnicode() {
        let c = card("你好\tworld", "hello\r\nthere\nfriend", status: .approved, digest: "d")
        XCTAssertEqual(PageFlashcards.quizletText(for: [c]), "你好 world\thello there friend")
    }

    func testExportOnlyApprovedCurrent() {
        let store = makeStore()
        let model = PageFlashcards(pageID: "page-1", store: store, reader: FakeReader(result: []))
        let drawing = PKDrawing()
        model.inkChanged(drawing)
        let digest = model.currentDigest!
        let file = PageFlashcardFile(pageID: "page-1", cards: [
            card("a", "1", status: .approved, digest: digest),
            card("b", "2", status: .draft, digest: digest),
            card("c", "3", status: .approved, digest: "old"),
            card("d", "4", status: .discarded, digest: digest),
        ])
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(file).write(to: PageFlashcards.fileURL(pageID: "page-1", store: store))
        let reloaded = PageFlashcards(pageID: "page-1", store: store, reader: FakeReader(result: []))
        reloaded.inkChanged(drawing)
        XCTAssertEqual(reloaded.quizletExport, "a\t1")
        XCTAssertEqual(reloaded.staleCount, 1)
    }

    func testCorruptFileIsPreserved() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let url = PageFlashcards.fileURL(pageID: "page-1", store: store)
        try Data("not json".utf8).write(to: url)
        let model = PageFlashcards(pageID: "page-1", store: store, reader: FakeReader(result: []))
        XCTAssertNotNil(model.loadError)
        model.inkChanged(PKDrawing())
        model.merge(lines: [RecognizedLine(text: "x", bounds: .zero)], digest: model.currentDigest!)
        XCTAssertEqual(try Data(contentsOf: url), Data("not json".utf8))
    }

    func testEditApproveDiscardPersist() throws {
        let store = makeStore()
        let model = PageFlashcards(pageID: "page-1", store: store, reader: FakeReader(result: []))
        model.inkChanged(PKDrawing())
        let digest = model.currentDigest!
        model.merge(lines: [RecognizedLine(text: "你好 nǐ hǎo hello", bounds: .zero)], digest: digest)
        let first = try XCTUnwrap(model.cards.first)
        model.edit(first.id, front: "你好", back: "hello")
        model.approve(first.id)
        let reloaded = PageFlashcards(pageID: "page-1", store: store, reader: FakeReader(result: []))
        reloaded.inkChanged(PKDrawing())
        XCTAssertEqual(reloaded.approvedCurrent.first?.front, "你好")
        reloaded.discard(first.id)
        XCTAssertTrue(reloaded.approvedCurrent.isEmpty)
        let again = PageFlashcards(pageID: "page-1", store: store, reader: FakeReader(result: []))
        XCTAssertEqual(again.cards.first?.status, .discarded)
    }

    func testDigestStableAcrossSaveReloadAndDetectsChange() throws {
        func stroke(_ dx: CGFloat) -> PKStroke {
            let pts = (0..<4).map { PKStrokePoint(location: CGPoint(x: dx + CGFloat($0) * 10, y: CGFloat($0) * 5),
                                                  timeOffset: Double($0) / 60, size: CGSize(width: 3, height: 3),
                                                  opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
        }
        XCTAssertEqual(PageFlashcards.digest(of: PKDrawing()), PageFlashcards.digest(of: PKDrawing()))
        let store = makeStore()
        let drawing = PKDrawing(strokes: [stroke(0)])
        try store.save(drawing, pageID: "page-1")
        let loaded = try XCTUnwrap(store.loadDrawing(pageID: "page-1"))
        XCTAssertEqual(PageFlashcards.digest(of: drawing), PageFlashcards.digest(of: loaded))
        XCTAssertNotEqual(PageFlashcards.digest(of: drawing), PageFlashcards.digest(of: PKDrawing(strokes: [stroke(1)])))
        XCTAssertNotEqual(PageFlashcards.digest(of: drawing), PageFlashcards.digest(of: PKDrawing()))
    }

    func testDigestIncludesStrokeMask() throws {
        let pts = (0..<4).map { PKStrokePoint(location: CGPoint(x: CGFloat($0) * 10, y: CGFloat($0) * 5),
                                              timeOffset: Double($0) / 60, size: CGSize(width: 3, height: 3),
                                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
        let plain = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSince1970: 0)))
        var masked = plain
        masked.mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 15, height: 20))
        var masked2 = plain
        masked2.mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 16, height: 20))
        let d0 = PageFlashcards.digest(of: PKDrawing(strokes: [plain]))
        let d1 = PageFlashcards.digest(of: PKDrawing(strokes: [masked]))
        XCTAssertNotEqual(d0, d1)
        XCTAssertNotEqual(d1, PageFlashcards.digest(of: PKDrawing(strokes: [masked2])))
        XCTAssertEqual(d1, PageFlashcards.digest(of: PKDrawing(strokes: [masked])))

        // Survives save/reload.
        let store = makeStore()
        let drawing = PKDrawing(strokes: [masked])
        try store.save(drawing, pageID: "page-1")
        let loaded = try XCTUnwrap(store.loadDrawing(pageID: "page-1"))
        XCTAssertEqual(PageFlashcards.digest(of: drawing), PageFlashcards.digest(of: loaded))
    }

    func testEditedCardDoesNotDuplicateAndChangedInkRequiresReapproval() throws {
        let store = makeStore()
        let model = PageFlashcards(pageID: "page-1", store: store, reader: FakeReader(result: []))
        model.inkChanged(PKDrawing())
        let line = RecognizedLine(text: "你好 nǐ hǎo hello", bounds: .zero)
        model.merge(lines: [line], digest: model.currentDigest!)
        let first = try XCTUnwrap(model.cards.first)
        model.edit(first.id, front: "您好", back: "hi there")
        model.approve(first.id)
        XCTAssertEqual(model.merge(lines: [line], digest: model.currentDigest!), 0)
        XCTAssertEqual(model.cards.count, 1)
        XCTAssertEqual(model.approvedCurrent.count, 1)

        // Updated ink containing the same line: back to draft, edits kept, not exported.
        model.merge(lines: [line], digest: "new-ink")
        model.inkChanged(PKDrawing())
        XCTAssertEqual(model.cards.count, 1)
        let card = model.cards[0]
        XCTAssertEqual(card.front, "您好")
        XCTAssertEqual(card.status, .draft)
        XCTAssertEqual(model.quizletExport, "")
    }

    func testBlankEditIsDeclined() throws {
        let model = PageFlashcards(pageID: "page-1", store: makeStore(), reader: FakeReader(result: []))
        model.inkChanged(PKDrawing())
        model.merge(lines: [RecognizedLine(text: "你好 nǐ hǎo hello", bounds: .zero)], digest: model.currentDigest!)
        let first = try XCTUnwrap(model.cards.first)
        model.edit(first.id, front: "  ", back: "x")
        XCTAssertEqual(model.cards.first, first)
    }

    // MARK: - Accepted corrections

    private let box = CGRect(x: 0, y: 0, width: 100, height: 20)

    private func inkDrawing(at x: CGFloat = 0) -> PKDrawing {
        let pts = (0..<4).map { PKStrokePoint(location: CGPoint(x: x + CGFloat($0) * 10, y: 10),
                                              timeOffset: Double($0) / 60, size: CGSize(width: 3, height: 3),
                                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSince1970: 0)))])
    }

    private func note(_ text: String, source: String = "fu ze to be responsible for", hanzi: String? = "负责",
                      pinyin: String? = "fùzé", gloss: String?, anchor: CGRect? = nil) -> AcceptedAnnotation {
        AcceptedAnnotation(id: UUID(), text: text, edited: true, anchor: anchor ?? box, recognizedText: source,
                           hanzi: hanzi, pinyin: pinyin, gloss: gloss)
    }

    private func generate(_ model: PageFlashcards, drawing: PKDrawing, notes: [AcceptedAnnotation]) async {
        await model.refresh(from: drawing, annotations: notes).value
    }

    private func reader(_ text: String = "fu ze to be responsible for") -> FakeReader {
        FakeReader(result: [RecognizedLine(text: text, bounds: box)])
    }

    func testAcceptedEditedMeaningOverridesRawGloss() async throws {
        let model = PageFlashcards(pageID: "page-1", store: makeStore(), reader: reader())
        await generate(model, drawing: inkDrawing(), notes: [note("负责 · in charge of the team", gloss: "in charge of the team")])
        XCTAssertEqual(model.cards.count, 1)
        XCTAssertEqual(model.cards[0].front, "负责")
        XCTAssertEqual(model.cards[0].back, "fùzé — in charge of the team")
        XCTAssertFalse(model.cards[0].needsReview)
    }

    func testPrefixOnlyHanziUsesAcceptedCandidate() async throws {
        let model = PageFlashcards(pageID: "page-1", store: makeStore(), reader: reader("负责"))
        await generate(model, drawing: inkDrawing(), notes: [note("to be responsible for", source: "负责", gloss: "to be responsible for")])
        XCTAssertEqual(model.cards.map(\.back), ["fùzé — to be responsible for"])
    }

    func testAcceptanceStoresUserEditNotCandidateEnglish() async throws {
        let suggestions = PageSuggestionModel(pageID: "page-1", store: SuggestionStore(directory: makeStore().directory),
                                              reader: reader())
        let drawing = inkDrawing()
        suggestions.request(for: drawing)
        await suggestions.task?.value
        let pending = try XCTUnwrap(suggestions.pending.first)
        suggestions.accept(pending.id, editedText: "负责 · running the project")
        let accepted = try XCTUnwrap(suggestions.annotations.first)
        XCTAssertEqual(accepted.hanzi, "负责")
        XCTAssertEqual(accepted.gloss, "running the project")
    }

    func testRefinedSecondPassAcceptanceAnchorsToRawLine() async throws {
        let refined = FakeReader(result: [RecognizedLine(text: "负责", bounds: box, sourceText: "fu ze to be responsible for")])
        let suggestions = PageSuggestionModel(pageID: "page-1", store: SuggestionStore(directory: makeStore().directory),
                                              reader: refined)
        suggestions.request(for: inkDrawing())
        await suggestions.task?.value
        let pending = try XCTUnwrap(suggestions.pending.first)
        suggestions.accept(pending.id, editedText: "负责 · running the project")
        let accepted = try XCTUnwrap(suggestions.annotations.first)
        XCTAssertEqual(accepted.recognizedText, "fu ze to be responsible for")

        // Repeated Suggest dedupes on the raw source text.
        suggestions.request(for: inkDrawing())
        await suggestions.task?.value
        XCTAssertTrue(suggestions.pending.isEmpty)

        // Cards read the raw line and keep the user's correction.
        let model = PageFlashcards(pageID: "page-1", store: makeStore(), reader: reader())
        await generate(model, drawing: inkDrawing(), notes: [accepted])
        XCTAssertEqual(model.cards.map(\.back), ["fùzé — running the project"])
    }

    func testRemovedNoteInvalidatesApprovedCorrectionCard() async throws {
        let model = PageFlashcards(pageID: "page-1", store: makeStore(), reader: reader())
        let n = note("负责 · in charge", gloss: "in charge")
        await generate(model, drawing: inkDrawing(), notes: [n])
        model.approve(model.cards[0].id)
        model.invalidateRemovedCorrections(activeIDs: [n.id])
        XCTAssertEqual(model.cards[0].status, .approved)
        model.invalidateRemovedCorrections(activeIDs: [])
        XCTAssertEqual(model.cards[0].status, .draft)
        XCTAssertTrue(model.cards[0].needsReview)
    }

    func testLegacyAnnotationWithoutMetadata() async throws {
        let legacy = AcceptedAnnotation(id: UUID(), text: "负责 · to run it", edited: true, anchor: box,
                                        recognizedText: "fu ze to be responsible for")
        let model = PageFlashcards(pageID: "page-1", store: makeStore(), reader: reader())
        await generate(model, drawing: inkDrawing(), notes: [legacy])
        XCTAssertEqual(model.cards.first?.back, "fùzé — to run it")

        // Ambiguous legacy text (no clear single gloss) is not used; raw extraction is not guessed from it either.
        let ambiguous = AcceptedAnnotation(id: UUID(), text: "负责 · 承担 · one · two", edited: true, anchor: box,
                                           recognizedText: "fu ze to be responsible for")
        let other = PageFlashcards(pageID: "page-2", store: makeStore(), reader: reader())
        await generate(other, drawing: inkDrawing(), notes: [ambiguous])
        XCTAssertTrue(other.cards.isEmpty)
    }

    func testHiddenAndNonMatchingNotesAreIgnored() async throws {
        let store = makeStore()
        let model = PageFlashcards(pageID: "page-1", store: store, reader: reader())
        let far = CGRect(x: 5000, y: 5000, width: 10, height: 10)
        await generate(model, drawing: inkDrawing(), notes: [
            note("负责 · hidden", gloss: "hidden", anchor: far),
            note("负责 · other source", source: "something else", gloss: "other source"),
        ])
        XCTAssertTrue(model.cards.filter { $0.correction != nil }.isEmpty)
    }

    func testOneNoteOneCardAndNoRawDuplicate() async throws {
        let model = PageFlashcards(pageID: "page-1", store: makeStore(), reader: reader("负责 fùzé to be responsible for"))
        let n = note("负责 · in charge", source: "负责 fùzé to be responsible for", gloss: "in charge")
        await generate(model, drawing: inkDrawing(), notes: [n])
        await generate(model, drawing: inkDrawing(), notes: [n])
        XCTAssertEqual(model.cards.count, 1)
        XCTAssertEqual(model.cards[0].back, "fùzé — in charge")
    }

    func testChangedAcceptedSourceRedraftsKeepsEditsAndCorrectsTSV() async throws {
        let model = PageFlashcards(pageID: "page-1", store: makeStore(), reader: reader())
        let drawing = inkDrawing()
        let first = note("负责 · in charge", gloss: "in charge")
        await generate(model, drawing: drawing, notes: [first])
        model.approve(model.cards[0].id)
        XCTAssertEqual(model.quizletExport, "负责\tfùzé — in charge")

        // Same page, re-accepted with new wording: re-drafted, not exported until approved again.
        let second = note("负责 · to take care of", gloss: "to take care of")
        await generate(model, drawing: drawing, notes: [second])
        XCTAssertEqual(model.cards.count, 1)
        XCTAssertEqual(model.cards[0].status, .draft)
        XCTAssertEqual(model.quizletExport, "")
        model.approve(model.cards[0].id)
        XCTAssertEqual(model.quizletExport, "负责\tfùzé — to take care of")

        // An explicit card edit survives a later change but is flagged.
        model.edit(model.cards[0].id, front: "负责", back: "my wording")
        let third = note("负责 · in charge", gloss: "in charge")
        await generate(model, drawing: drawing, notes: [third])
        XCTAssertEqual(model.cards.count, 1)
        XCTAssertEqual(model.cards[0].back, "my wording")
        XCTAssertTrue(model.cards[0].needsReview)
        XCTAssertEqual(model.cards[0].status, .draft)
    }

    func testRemovedNoteFlagsItsCard() async throws {
        let model = PageFlashcards(pageID: "page-1", store: makeStore(), reader: reader())
        let drawing = inkDrawing()
        await generate(model, drawing: drawing, notes: [note("负责 · in charge", gloss: "in charge")])
        model.approve(model.cards[0].id)
        await generate(model, drawing: drawing, notes: [])
        XCTAssertEqual(model.cards[0].status, .draft)
        XCTAssertTrue(model.cards[0].needsReview)
    }

    func testResultDroppedWhenInkChangesDuringRead() async throws {
        let model = PageFlashcards(pageID: "page-1", store: makeStore(),
                                   reader: FakeReader(result: [RecognizedLine(text: "你好 nǐ hǎo hello", bounds: .zero)]))
        let task = model.refresh(from: PKDrawing())
        model.inkChanged(PKDrawing())
        await task.value
        XCTAssertTrue(model.cards.isEmpty)
    }
}
