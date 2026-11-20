import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import JIBIJI

/// Stage 4: notes have stable ids and independent revisions, rejection is remembered per note, and one note's edit
/// leaves another note's suggestion and card alone. Synthetic ink only.
@Suite("Notes are versioned independently")
struct NoteRegistryTests {
    private func box(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 0, width: 50, height: 50) }

    @Test func sameStrokesKeepTheSameNoteAndRevision() {
        var registry = NoteRegistry()
        let first = registry.reconcile([(["a", "b"], box(0)), (["c"], box(100))])
        let again = registry.reconcile([(["c"], box(100)), (["b", "a"], box(0))])
        #expect(again[0]?.id == first[1]?.id && again[1]?.id == first[0]?.id)
        #expect(again.compactMap { $0?.revision } == [1, 1])
        #expect(registry.records.count == 2)
    }

    @Test func editingOneNoteRevisesOnlyThatNote() {
        var registry = NoteRegistry()
        let first = registry.reconcile([(["a", "b", "c"], box(0)), (["x", "y"], box(100))])
        registry.reject(note: first[0]!.id, revision: 1, key: "好像")
        registry.reject(note: first[1]!.id, revision: 1, key: "负责")
        // A stroke added to the first note; the second is untouched.
        let after = registry.reconcile([(["a", "b", "c", "d"], box(0)), (["x", "y"], box(100))])
        #expect(after[0]?.id == first[0]?.id)
        #expect(after[0]?.revision == 2)
        #expect(after[0]?.rejected == [], "a rejection applies to the writing it was made for")
        #expect(after[1]?.revision == 1)
        #expect(after[1]?.rejected == ["负责"])
    }

    @Test func unrelatedStrokesAreANewNoteNotATakeover() {
        var registry = NoteRegistry()
        let first = registry.reconcile([(["a", "b"], box(0))])
        let second = registry.reconcile([(["p", "q"], box(0))])
        #expect(second[0]?.id != first[0]?.id)
        #expect(second[0]?.revision == 1)
    }

    @Test func rejectionIsPerNoteRevisionAndKey() {
        var registry = NoteRegistry()
        let note = registry.reconcile([(["a"], box(0))])[0]!
        registry.reject(note: note.id, revision: 1, key: "好像")
        #expect(registry.isRejected(note: note.id, revision: 1, key: "好像"))
        #expect(!registry.isRejected(note: note.id, revision: 1, key: "负责"))
        #expect(!registry.isRejected(note: note.id, revision: 2, key: "好像"))
        // A stale revision cannot reject.
        registry.reject(note: note.id, revision: 9, key: "负责")
        #expect(!registry.isRejected(note: note.id, revision: 9, key: "负责"))
    }

    @Test func emptyStrokeSetsAreIgnoredAndRecordsAreCapped() {
        var registry = NoteRegistry()
        #expect(registry.reconcile([([], box(0))]) == [nil])
        let precious = registry.reconcile([(["keep-a"], box(0))])[0]!
        registry.reject(note: precious.id, revision: 1, key: "好像")
        let referenced = registry.reconcile([(["keep-b"], box(0))])[0]!
        for i in 0..<(NoteRegistry.maxRecords + 20) { _ = registry.reconcile([(["s\(i)"], box(0))], keeping: [referenced.id]) }
        #expect(registry.records.count == NoteRegistry.maxRecords)
        #expect(registry.record(precious.id)?.rejected == ["好像"], "a remembered rejection is not evicted")
        #expect(registry.record(referenced.id) != nil, "a record an accepted note refers to is not evicted")
    }

    @Test func aRecordGoesToTheReadingItResemblesMost() {
        var registry = NoteRegistry()
        let original = registry.reconcile([(["a", "b", "c", "d", "e", "f"], box(0))])[0]!
        // Split into two readings; the later one is by far the closer match to the old note.
        let after = registry.reconcile([(["a", "b", "x"], box(0)), (["a", "b", "c", "d", "e"], box(200))])
        #expect(after[1]?.id == original.id)
        #expect(after[0]?.id != original.id)
        #expect(after[0]?.revision == 1)
    }

    @Test func storeRoundTripsAndNeverOverwritesAnUnreadableFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Registry-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteRegistryStore(directory: folder)
        #expect(try store.load(pageID: "p") == NoteRegistry())
        var registry = NoteRegistry()
        _ = registry.reconcile([(["a"], box(0))])
        try store.save(registry, pageID: "p")
        #expect(try store.load(pageID: "p") == registry)
        try Data("not json".utf8).write(to: store.fileURL(pageID: "bad"))
        #expect(throws: (any Error).self) { try store.load(pageID: "bad") }
    }
}

@Suite("Suggestions and cards follow their own note", .serialized)
@MainActor
struct NoteIndependenceTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appending(path: "Stage4-\(UUID().uuidString)", directoryHint: .isDirectory) }

    private func page(_ folder: URL, notes: [(PKDrawing, String)]) -> (NotePageModel, [PKDrawing]) {
        let reader = SuggestionStage1Tests.RegionReader(
            regions: notes.map { .init(bounds: $0.0.bounds, text: $0.1) }, writing: notes.map(\.0))
        let model = NotePageModel(pageID: "page-1", store: NoteStore(directory: folder), lineReader: reader)
        model.drawingDidChange(PKDrawing(strokes: notes.flatMap(\.0.strokes)))
        return (model, notes.map(\.0))
    }

    private func suggest(_ model: NotePageModel) async {
        model.suggestions.request(for: model.drawing)
        await model.suggestions.task?.value
    }

    @Test func writingInAnotherNoteKeepsThisNotesSuggestion() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 80, y: 100))
        let b = SyntheticInk.drawing(writing: "人", origin: CGPoint(x: 500, y: 100))
        let (model, _) = page(dir, notes: [(a, "fùzé"), (b, "fùxí")])
        await suggest(model)
        #expect(Set(model.suggestions.pending.map(\.candidate.hanzi)) == ["负责", "复习"])
        let aChip = try #require(model.suggestions.pending.first { $0.candidate.hanzi == "负责" })

        // Writing a new stroke inside note B drops B's chip only.
        let extra = SyntheticInk.stroke(through: [CGPoint(x: b.bounds.minX + 8, y: b.bounds.midY), CGPoint(x: b.bounds.maxX - 8, y: b.bounds.midY)])
        model.drawingDidChange(PKDrawing(strokes: model.drawing.strokes + [extra]))
        #expect(model.suggestions.pending.map(\.candidate.hanzi) == ["负责"])
        // The kept chip is the same one and can still be accepted.
        #expect(model.suggestions.pending.first?.id == aChip.id)
        model.suggestions.accept(aChip.id)
        #expect(model.suggestions.annotations.count == 1)
        // Writing far from any note keeps it all; erasing a note's own stroke drops that note's chip.
        await suggest(model)
        let bChip = try #require(model.suggestions.pending.first)
        model.drawingDidChange(PKDrawing(strokes: model.drawing.strokes + [SyntheticInk.stroke(through: [CGPoint(x: 900, y: 600), CGPoint(x: 960, y: 600)])]))
        #expect(model.suggestions.pending.first?.id == bChip.id)
        // Erasing one of note B's own strokes drops B's chip.
        let first = InkSelection.identity(b.strokes[0])
        model.drawingDidChange(PKDrawing(strokes: model.drawing.strokes.filter { InkSelection.identity($0) != first }))
        #expect(model.suggestions.pending.isEmpty)
    }

    @Test func skippedSuggestionStaysSkippedForTheSameWritingAndSurvivesRelaunch() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 80, y: 100))
        let b = SyntheticInk.drawing(writing: "人", origin: CGPoint(x: 500, y: 100))
        let (model, _) = page(dir, notes: [(a, "fùzé"), (b, "fùxí")])
        await suggest(model)
        let skipped = try #require(model.suggestions.pending.first { $0.candidate.hanzi == "负责" })
        model.suggestions.dismiss(skipped.id)
        // Asking again: the skipped note is quiet, the other is still offered.
        await suggest(model)
        #expect(model.suggestions.pending.map(\.candidate.hanzi) == ["复习"])
        await suggest(model)
        #expect(model.suggestions.pending.map(\.candidate.hanzi) == ["复习"])

        // After a relaunch the skip is remembered.
        let (reopened, _) = page(dir, notes: [(a, "fùzé"), (b, "fùxí")])
        await suggest(reopened)
        #expect(reopened.suggestions.pending.map(\.candidate.hanzi) == ["复习"])

        // Changing that note's own writing makes it eligible again (a new revision).
        let extra = SyntheticInk.stroke(through: [CGPoint(x: a.bounds.minX + 8, y: a.bounds.midY), CGPoint(x: a.bounds.maxX - 8, y: a.bounds.midY)])
        let (again, _) = page(dir, notes: [(PKDrawing(strokes: a.strokes + [extra]), "fùzé"), (b, "fùxí")])
        await suggest(again)
        #expect(Set(again.suggestions.pending.map(\.candidate.hanzi)) == ["负责", "复习"])
    }

    @Test func anUnreadableNotesFileIsNeverOverwrittenAndSuggestStillWorks() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bad = dir.appending(path: "page-1.notes.json")
        try Data("not json".utf8).write(to: bad)
        let a = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 80, y: 100))
        let (model, _) = page(dir, notes: [(a, "fùzé")])
        await suggest(model)
        #expect(model.suggestions.pending.map(\.candidate.hanzi) == ["负责"])
        #expect(try Data(contentsOf: bad) == Data("not json".utf8))
    }

    @Test func acceptedNoteRecordsItsNoteAndRevision() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 80, y: 100))
        let (model, _) = page(dir, notes: [(a, "fùzé")])
        await suggest(model)
        let item = try #require(model.suggestions.pending.first)
        #expect(item.noteID != nil && item.noteRevision == 1)
        model.suggestions.accept(item.id)
        let note = try #require(model.suggestions.annotations.first)
        #expect(note.noteID == item.noteID && note.noteRevision == 1)
        let noteID = try #require(item.noteID)
        let record = try #require(model.suggestions.registry.record(noteID))
        #expect(record.strokeIDs == a.strokes.map(InkSelection.identity).sorted())
    }
}

@Suite("Cards go stale only when their own note changes", .serialized)
@MainActor
struct CardCurrencyTests {
    private struct Fixed: InkLineReader {
        var lines: [RecognizedLine]
        func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] { lines }
    }

    private func setUp(_ dir: URL) -> (PageFlashcards, PKDrawing, PKDrawing, PKDrawing) {
        let a = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 80, y: 100))
        let b = SyntheticInk.drawing(writing: "人", origin: CGPoint(x: 500, y: 100))
        let drawing = PKDrawing(strokes: a.strokes + b.strokes)
        var la = RecognizedLine(text: "负责 fùzé to be responsible for", bounds: a.bounds); la.strokeIndices = Array(a.strokes.indices)
        var lb = RecognizedLine(text: "复习 fùxí to review", bounds: b.bounds); lb.strokeIndices = Array(a.strokes.count..<drawing.strokes.count)
        let model = PageFlashcards(pageID: "page-1", store: NoteStore(directory: dir), reader: Fixed(lines: [la, lb]))
        return (model, drawing, a, b)
    }

    private func approveAll(_ model: PageFlashcards) {
        for card in model.currentDrafts { model.approve(card.id) }
    }

    @Test func writingElsewhereKeepsApprovedCardsAndEditingOneNoteStalesOnlyItsCard() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Stage4c-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, drawing, a, b) = setUp(dir)
        await model.refresh(from: drawing, annotations: []).value
        #expect(model.cards.count == 2)
        approveAll(model)
        #expect(model.approvedCurrent.count == 2)
        #expect(model.cards.allSatisfy { $0.sourceStrokeIDs?.isEmpty == false })

        // A stroke far from both notes: nothing goes stale.
        let far = SyntheticInk.stroke(through: [CGPoint(x: 900, y: 600), CGPoint(x: 960, y: 600)])
        model.inkChanged(PKDrawing(strokes: drawing.strokes + [far]))
        #expect(model.approvedCurrent.count == 2)
        #expect(model.staleCount == 0)

        // A stroke inside note A: only A's card goes stale; export keeps B's.
        let inA = SyntheticInk.stroke(through: [CGPoint(x: a.bounds.minX + 8, y: a.bounds.midY), CGPoint(x: a.bounds.maxX - 8, y: a.bounds.midY)])
        model.inkChanged(PKDrawing(strokes: drawing.strokes + [far, inA]))
        #expect(model.approvedCurrent.map(\.front) == ["复习"])
        #expect(model.staleCards.map(\.front) == ["负责"])
        #expect(model.quizletExport == "复习\tfùxí — to review")
        _ = b
    }

    @Test func regeneratingAfterEditingOneNoteRedraftsOnlyThatCard() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Stage4c-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, drawing, a, b) = setUp(dir)
        await model.refresh(from: drawing, annotations: []).value
        approveAll(model)
        // Note A gains a stroke; the reader now reports it as part of A.
        let inA = SyntheticInk.stroke(through: [CGPoint(x: a.bounds.minX + 8, y: a.bounds.midY), CGPoint(x: a.bounds.maxX - 8, y: a.bounds.midY)])
        let edited = PKDrawing(strokes: a.strokes + [inA] + b.strokes)
        var la = RecognizedLine(text: "负责 fùzé to be responsible for", bounds: a.bounds.union(inA.renderBounds)); la.strokeIndices = Array(0...a.strokes.count)
        var lb = RecognizedLine(text: "复习 fùxí to review", bounds: b.bounds); lb.strokeIndices = Array((a.strokes.count + 1)..<edited.strokes.count)
        let again = PageFlashcards(pageID: "page-1", store: NoteStore(directory: dir), reader: Fixed(lines: [la, lb]))
        await again.refresh(from: edited, annotations: []).value
        let byFront = Dictionary(uniqueKeysWithValues: again.cards.map { ($0.front, $0) })
        #expect(byFront["负责"]?.status == .draft, "its own writing changed: approve again")
        #expect(byFront["复习"]?.status == .approved, "an untouched note keeps its approval")
        #expect(again.cards.count == 2)
    }

    @Test func writingJustBesideAnApprovedNoteMakesItStaleButNotItsNeighbour() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Stage4c-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, drawing, a, _) = setUp(dir)
        await model.refresh(from: drawing, annotations: []).value
        approveAll(model)
        // An English word added to the right of note A, outside its old bounds but beside it.
        let beside = SyntheticInk.stroke(through: [CGPoint(x: a.bounds.maxX + 20, y: a.bounds.midY), CGPoint(x: a.bounds.maxX + 60, y: a.bounds.midY)])
        model.inkChanged(PKDrawing(strokes: drawing.strokes + [beside]))
        #expect(model.approvedCurrent.map(\.front) == ["复习"])
        #expect(model.staleCards.map(\.front) == ["负责"])
    }

    @Test func cardsSavedBeforeStrokeIdentitiesStillGoStaleWithThePage() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Stage4c-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, drawing, _, _) = setUp(dir)
        model.inkChanged(drawing)
        let digest = try #require(model.currentDigest)
        let old = PageFlashcard(id: UUID(), front: "负责", back: "fùzé — x", kind: .vocabulary, sourceText: "x", needsReview: false,
                                sourceBounds: .zero, inkDigest: digest, status: .approved, edited: false)
        #expect(model.isCurrent(old))
        model.inkChanged(PKDrawing(strokes: drawing.strokes + [SyntheticInk.stroke(through: [CGPoint(x: 900, y: 600), CGPoint(x: 960, y: 600)])]))
        #expect(!model.isCurrent(old))
    }

    @Test func cardOfAReplacementStaysCurrentWhileOtherInkChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Stage4c-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 80, y: 100))
        let page = NotePageModel(pageID: "page-1", store: NoteStore(directory: dir),
                                 lineReader: SuggestionStage1Tests.RegionReader(regions: [.init(bounds: original.bounds, text: "fùzé responsible for?")], writing: [original]))
        page.drawingDidChange(original)
        page.suggestions.request(for: page.drawing); await page.suggestions.task?.value
        let item = try #require(page.suggestions.pending.first)
        #expect(page.replaceSuggestion(item.id, with: item.cleanText))
        await page.flashcards.refresh(from: page.drawing, annotations: page.suggestions.annotations).value
        let card = try #require(page.flashcards.cards.first)
        page.flashcards.approve(card.id)
        #expect(page.flashcards.approvedCurrent.count == 1)
        // Writing elsewhere afterwards does not stale it.
        page.drawingDidChange(PKDrawing(strokes: page.drawing.strokes + [SyntheticInk.stroke(through: [CGPoint(x: 900, y: 600), CGPoint(x: 960, y: 600)])]))
        #expect(page.flashcards.approvedCurrent.count == 1)
        // Removing the replacement does.
        let note = try #require(page.latestVisibleReplacement)
        page.deleteReplacement(note.id)
        #expect(page.flashcards.approvedCurrent.isEmpty)
    }
}
