import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import JIBIJI

@Suite("Starter vocabulary matching")
struct StarterVocabularyTests {
    let vocabulary = StarterVocabulary.standard

    @Test(arguments: ["fùzé responsible for?", "fu ze responsible?", "FUZE responsible for", "fùzé", "fuze to be responsible for"])
    func offersFuzeFromPinyinAndOptionalGloss(text: String) throws {
        let proposal = try #require(vocabulary.proposal(forRecognizedText: text))
        #expect(proposal.candidates.first?.hanzi == "负责")
        #expect(proposal.candidates.first?.gloss == "to be responsible for")
        #expect(!proposal.hanziAlreadyWritten)
    }

    @Test func offersTheRealAlternativeSense() throws {
        let proposal = try #require(vocabulary.proposal(forRecognizedText: "fùzé responsible for?"))
        #expect(proposal.candidates.map(\.hanzi) == ["负责", "承担"])
    }

    @Test func existingHanziOnlyGetsAGloss() throws {
        let proposal = try #require(vocabulary.proposal(forRecognizedText: "负责 responsible for"))
        #expect(proposal.hanziAlreadyWritten)
        var pending = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: "", proposal: proposal)
        #expect(pending.annotationText == "to be responsible for")
        pending.selectedIndex = 1
        // An alternative is a different word, so it carries its own Hanzi even though 负责 was written.
        #expect(pending.annotationText == "承担 · (chéngdān) · to bear responsibility for")
    }

    @Test func hanziMustBeAnExactRunNotASubstring() throws {
        #expect(vocabulary.proposal(forRecognizedText: "负责人") == nil)
        #expect(vocabulary.proposal(forRecognizedText: "负责人 responsible for") == nil)
        let exact = try #require(vocabulary.proposal(forRecognizedText: "负责 responsible for"))
        #expect(exact.hanziAlreadyWritten)
    }

    @Test func abstainsWhenNothingIsLeftToAddOrNothingMatches() {
        #expect(vocabulary.proposal(forRecognizedText: "负责 to be responsible for") == nil)
        #expect(vocabulary.proposal(forRecognizedText: "") == nil)
        #expect(vocabulary.proposal(forRecognizedText: "hello world") == nil)
        #expect(vocabulary.proposal(forRecognizedText: "你好") == nil)
        // Pinyin matched but the English contradicts every known sense: don't guess.
        #expect(vocabulary.proposal(forRecognizedText: "fùzé banana") == nil)
        // Gloss alone, no pinyin or Hanzi: abstain.
        #expect(vocabulary.proposal(forRecognizedText: "responsible for") == nil)
    }

    private func note(_ text: String) throws -> String {
        let proposal = try #require(vocabulary.proposal(forRecognizedText: text))
        return PendingSuggestion(revision: 0, anchor: .zero, recognizedText: text, proposal: proposal).annotationText
    }

    @Test(arguments: ["好 hǎo xiàng", "好 hao xiang", "好 hǎoxiàng", "好 haoxiang"])
    func partialHanziOffersOnlyMissingCharacterAndGloss(text: String) throws {
        #expect(try note(text) == "像 · to seem like; to look like")
    }

    @Test func fullHanziGetsGlossOnly() throws {
        #expect(try note("好像 hǎo xiàng") == "to seem like; to look like")
    }

    @Test(arguments: ["hǎo xiàng", "hao xiang", "hǎoxiàng", "haoxiang"])
    func purePinyinGetsWholeHanziAndGloss(text: String) throws {
        #expect(try note(text) == "好像 · to seem like; to look like")
    }

    @Test func wrongOrAmbiguousHanziAbstains() {
        #expect(vocabulary.proposal(forRecognizedText: "你 hǎo xiàng") == nil)
        #expect(vocabulary.proposal(forRecognizedText: "好象 hǎo xiàng") == nil)
        #expect(vocabulary.proposal(forRecognizedText: "好 你 hǎo xiàng") == nil)
        #expect(vocabulary.proposal(forRecognizedText: "好") == nil)
        #expect(vocabulary.proposal(forRecognizedText: "好 hǎo") == nil)
        #expect(vocabulary.proposal(forRecognizedText: "好 hao xian") == nil)
    }

    @Test func existingGlossIsPreserved() throws {
        #expect(try note("好 hǎo xiàng to seem like; to look like") == "像")
        #expect(try note("好 hao xiang to look like") == "像")
        #expect(vocabulary.proposal(forRecognizedText: "好像 hao xiang to seem like; to look like") == nil)
    }

    @Test func dictionaryContainsHaoxiang() throws {
        let entry = try #require(vocabulary.entries.first { $0.hanzi == "好像" })
        #expect(entry.pinyin == "hǎoxiàng")
        #expect(entry.glosses[0] == "to seem like; to look like")
    }

    @Test func glossWrittenOffersOnlyHanzi() throws {
        let proposal = try #require(vocabulary.proposal(forRecognizedText: "fuze to be responsible for"))
        #expect(proposal.glossAlreadyWritten)
        let pending = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: "", proposal: proposal)
        #expect(pending.annotationText == "负责")
    }
}

private struct FixedReader: InkLineReader {
    var lines: [RecognizedLine] = []
    var error: InkLineReaderError?
    func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] {
        if let error { throw error }
        return lines
    }
}

/// Waits long enough for a request to finish when the reader is slow.
private struct SlowReader: InkLineReader {
    func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] {
        try await Task.sleep(for: .milliseconds(150))
        return [RecognizedLine(text: "fuze responsible", bounds: CGRect(x: 10, y: 10, width: 100, height: 40))]
    }
}

@MainActor
@Suite("Inline suggestion state")
final class PageSuggestionModelTests {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SuggestionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    var store: SuggestionStore { SuggestionStore(directory: directory) }
    let ink = SyntheticInk.drawing(writing: "十")
    let line = RecognizedLine(text: "fùzé responsible for?", bounds: CGRect(x: 80, y: 160, width: 300, height: 96))

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func model(_ reader: any InkLineReader, page: String = "page-1") -> PageSuggestionModel {
        PageSuggestionModel(pageID: page, store: store, reader: reader)
    }

    private func request(_ model: PageSuggestionModel) async {
        model.request(for: ink)
        await model.task?.value
    }

    @Test func offersASuggestionAnchoredToTheSourceInk() async {
        let model = model(FixedReader(lines: [line]))
        await request(model)

        #expect(model.pending.count == 1)
        #expect(model.pending[0].anchor == line.bounds)
        #expect(model.pending[0].annotationText == "负责 · to be responsible for")
        #expect(model.annotations.isEmpty)
    }

    @Test func unknownChineseReadingsOfferEditableAlternativesWithoutInventingMeaning() async {
        let model = model(FixedReader(lines: [RecognizedLine(text: "大人", bounds: line.bounds, readings: ["大人", "太人"])]))
        await request(model)
        #expect(model.pending.count == 1)
        #expect(model.pending.first?.annotationText == "大人")
        if let item = model.pending.first {
            model.select(1, for: item.id)
            #expect(model.pending.first?.annotationText == "太人")
            model.accept(item.id)
            #expect(model.annotations.first?.text == "太人")
        }
    }

    @Test func emptyInkNoMatchAndFailureLeaveNothingPendingAndNeverThrowAway() async {
        let empty = model(FixedReader(lines: [line]))
        empty.request(for: PKDrawing())
        #expect(empty.pending.isEmpty)
        #expect(empty.status != .idle)

        let none = model(FixedReader(lines: [RecognizedLine(text: "hello", bounds: line.bounds)]))
        await request(none)
        #expect(none.pending.isEmpty)

        let failing = model(FixedReader(error: .unsupported))
        await request(failing)
        #expect(failing.pending.isEmpty)
        #expect(failing.status == .message(InkLineReaderError.unsupported.localizedDescription))
        // Asking again is still possible after a failure.
        failing.request(for: ink)
        #expect(failing.status == .checking)
    }

    @Test func inkChangeDropsPendingAndInFlightResults() async {
        let pending = model(FixedReader(lines: [line]))
        await request(pending)
        pending.sourceDidChange()
        #expect(pending.pending.isEmpty)

        let inFlight = model(SlowReader())
        inFlight.request(for: ink)
        inFlight.sourceDidChange()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(inFlight.pending.isEmpty)
        #expect(inFlight.status == .idle)
    }

    @Test func acceptingAStaleSuggestionDoesNothing() async throws {
        let model = model(FixedReader(lines: [line]))
        await request(model)
        let stale = try #require(model.pending.first)
        model.sourceDidChange()
        model.accept(stale.id)
        #expect(model.annotations.isEmpty)
    }

    @Test func acceptEditAlternativeDismissAndUndo() async throws {
        let model = model(FixedReader(lines: [line]))
        await request(model)
        let first = try #require(model.pending.first)

        model.select(1, for: first.id)
        model.accept(first.id)
        #expect(model.annotations.map(\.text) == ["承担 · (chéngdān) · to bear responsibility for"])

        await request(model)
        #expect(model.pending.isEmpty) // already noted on this line

        model.undoLastAccept()
        #expect(model.annotations.isEmpty)
        #expect(!model.canUndo)

        await request(model)
        let again = try #require(model.pending.first)
        model.accept(again.id, editedText: "  负责 — in charge  ")
        #expect(model.annotations.first?.text == "负责 — in charge")
        #expect(model.annotations.first?.edited == true)

        await request(model)
        model.pending.first.map { model.dismiss($0.id) }
        #expect(model.pending.isEmpty)
    }

    @Test func editedNoteWithoutGlossStillPreventsADuplicate() async throws {
        let model = model(FixedReader(lines: [line]))
        await request(model)
        model.accept(try #require(model.pending.first).id, editedText: "my own words")
        await request(model)
        #expect(model.pending.isEmpty)
        #expect(model.annotations.count == 1)
    }

    @Test func leavingThePageClearsPendingButKeepsAcceptedNotes() async throws {
        let model = model(FixedReader(lines: [line]))
        await request(model)
        model.accept(try #require(model.pending.first).id)
        let other = RecognizedLine(text: "fuze responsible", bounds: CGRect(x: 80, y: 400, width: 300, height: 60))
        let two = self.model(FixedReader(lines: [other]), page: "page-1")
        await request(two)
        #expect(!two.pending.isEmpty)
        two.cancelPending()
        #expect(two.pending.isEmpty)
        #expect(two.status == .idle)
        #expect(two.annotations.count == 1)
        #expect(model.noteBottom != nil)
    }

    @Test func acceptedNotesPersistPerPageAndSeparatelyFromInk() async throws {
        let page1 = model(FixedReader(lines: [line]), page: "page-1")
        await request(page1)
        page1.accept(try #require(page1.pending.first).id)

        let reopened = model(FixedReader(), page: "page-1")
        #expect(reopened.annotations == page1.annotations)
        #expect(model(FixedReader(), page: "page-2").annotations.isEmpty)
        #expect(!reopened.canUndo) // undo history is per session

        #expect(FileManager.default.fileExists(atPath: store.fileURL(pageID: "page-1").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "page-1.drawing").path))
    }

    @Test func erasingTheSourceInkHidesTheNoteReversiblyWithoutChangingSavedState() async throws {
        let model = model(FixedReader(lines: [line]))
        await request(model)
        model.accept(try #require(model.pending.first).id, editedText: "my own words")
        let note = try #require(model.annotations.first)
        let saved = try Data(contentsOf: store.fileURL(pageID: "page-1"))

        let touching = SyntheticInk.drawing(writing: "十", origin: note.anchor.origin)
        #expect(PageSuggestionModel.isVisible(note, in: touching))

        // Erased: hidden, but still stored, still undoable, and the file is untouched.
        let erased = SyntheticInk.drawing(writing: "十", origin: CGPoint(x: 900, y: 900))
        model.sourceDidChange()
        #expect(!PageSuggestionModel.isVisible(note, in: erased))
        #expect(!PageSuggestionModel.isVisible(note, in: PKDrawing()))
        #expect(model.annotations == [note])
        #expect(model.canUndo)
        #expect(try Data(contentsOf: store.fileURL(pageID: "page-1")) == saved)

        // Undoing the erase restores the same ink, so the note shows again.
        model.sourceDidChange()
        #expect(PageSuggestionModel.isVisible(note, in: touching))
        #expect(self.model(FixedReader()).annotations == [note])
    }

    @Test func unreadableSidecarIsKeptAndNeverOverwritten() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = store.fileURL(pageID: "page-1")
        try Data("not json".utf8).write(to: url)

        let model = model(FixedReader(lines: [line]))
        #expect(model.storageProblem != nil)
        await request(model)
        model.accept(try #require(model.pending.first).id)

        #expect(try Data(contentsOf: url) == Data("not json".utf8))
    }
}

// MARK: - Opt-in physical-device check

private final class SuggestionReplayAnchor {}

private enum SuggestionReplay {
    /// The shared `LocalPinyinReplay.drawing` fixture.
    static var url: URL? {
        Bundle(for: SuggestionReplayAnchor.self).url(forResource: "LocalPinyinReplay", withExtension: "drawing")
    }

    /// The shared fixture also serves debug tests, so this exact check runs only when explicitly requested
    /// (`TEST_RUNNER_JIBIJI_SUGGESTION_REPLAY=1`), on a physical device, and the ink has the known 35-stroke shape.
    static let expectedStrokeCount = 35
    static var requested: Bool { ProcessInfo.processInfo.environment["JIBIJI_SUGGESTION_REPLAY"] == "1" }

    #if targetEnvironment(simulator)
    static let isPhysicalDevice = false
    #else
    static let isPhysicalDevice = true
    #endif

    /// Lowercase, tone-less, space-less: robust to handwriting spacing, tone marks and case.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .filter { !$0.isWhitespace }
    }
}

@MainActor
@Suite("Physical-device suggestion replay")
struct SuggestionDeviceReplayTests {
    @available(iOS 27.0, *)
    @Test(.enabled(if: SuggestionReplay.requested && SuggestionReplay.isPhysicalDevice && SuggestionReplay.url != nil))
    func fuzeReplayOffersAcceptsAndUndoesWithoutTouchingInk() async throws {
        let fixture = try #require(SuggestionReplay.url)
        let drawing = try PKDrawing(data: Data(contentsOf: fixture))
        try #require(drawing.strokes.count == SuggestionReplay.expectedStrokeCount,
                     "Fixture has \(drawing.strokes.count) strokes, expected \(SuggestionReplay.expectedStrokeCount); not the Page 3 sample.")
        let originalInk = drawing.dataRepresentation()

        // 1. What PencilKit reads; the actual text is reported if an expectation fails.
        let reader = PencilInkLineReader()
        let lines = try await reader.lines(in: drawing)
        let readout = lines.map { "\"\($0.text)\" @ \($0.bounds.debugDescription)" }.joined(separator: "; ")
        print("Suggestion replay lines: \(readout)")
        let hanziLine = try #require(lines.first { $0.text.contains("负责") },
                                     "No line contained 负责. PencilKit read: \(readout)")
        let normalized = SuggestionReplay.normalized(hanziLine.text)
        #expect(normalized.contains("fuze"), "Pinyin missing in \"\(hanziLine.text)\"")
        #expect(normalized.contains("responsible"), "English missing in \"\(hanziLine.text)\"")

        // 2. The real model with the real reader, on a page saved to disk.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SuggestionReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = NoteStore(directory: directory, isTestNotebook: true)
        let suggestions = SuggestionStore(directory: directory)
        try notes.save(drawing, pageID: "page-3")
        let inkFileBefore = try Data(contentsOf: notes.fileURL(forPage: "page-3"))

        let model = PageSuggestionModel(pageID: "page-3", store: suggestions, reader: reader)
        model.request(for: drawing)
        await model.task?.value
        let offered = try #require(model.pending.first { $0.recognizedText.contains("负责") },
                                   "No suggestion for the 负责 line. Status: \(model.status); read: \(readout)")
        #expect(offered.proposal.hanziAlreadyWritten)
        #expect(offered.candidate.gloss == "to be responsible for")
        #expect(offered.annotationText == "to be responsible for")
        #expect(model.annotations.isEmpty)

        // 3. Anchored to the original ink, which hasn't changed.
        let inkBounds = drawing.strokes.map(\.renderBounds).reduce(CGRect.null) { $0.union($1) }
        #expect(offered.anchor == hanziLine.bounds)
        #expect(inkBounds.insetBy(dx: -1, dy: -1).contains(offered.anchor))
        #expect(drawing.strokes.contains { $0.renderBounds.intersects(offered.anchor) })
        #expect(drawing.dataRepresentation() == originalInk)

        // 4. Accept, reopen, undo: annotations stay separate from the ink throughout.
        model.accept(offered.id)
        let accepted = try #require(model.annotations.first)
        #expect(model.annotations.count == 1)
        #expect(accepted.text == "to be responsible for")
        #expect(accepted.anchor == offered.anchor)

        let reopened = PageSuggestionModel(pageID: "page-3", store: suggestions, reader: reader)
        #expect(reopened.annotations == [accepted])
        #expect(reopened.storageProblem == nil)

        model.undoLastAccept()
        #expect(model.annotations.isEmpty)
        #expect(PageSuggestionModel(pageID: "page-3", store: suggestions, reader: reader).annotations.isEmpty)

        // 5. Ink in memory and on disk is exactly what was written.
        #expect(drawing.dataRepresentation() == originalInk)
        #expect(try Data(contentsOf: notes.fileURL(forPage: "page-3")) == inkFileBefore)
        let reloaded = try #require(try notes.loadDrawing(pageID: "page-3"))
        #expect(reloaded.strokes.count == SuggestionReplay.expectedStrokeCount)
    }
}
