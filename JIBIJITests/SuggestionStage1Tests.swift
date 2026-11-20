import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import JIBIJI

/// Stage 1 of the recognition overhaul: Suggest reads only the student's own strokes, malformed OCR is never
/// offered as a word, accepted corrections stay quiet, and unrelated notes remain eligible.
/// All ink and text here is synthetic.
@Suite("Suggest reads original handwriting only", .serialized)
@MainActor
struct SuggestionStage1Tests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("Stage1-\(UUID().uuidString)") }

    /// Reads whatever strokes it is given, region by region, and records what it saw. Strokes that belong to no
    /// scripted region are read as `noise`, like OCR looking at rendered clean-handwriting glyphs.
    final class RegionReader: InkLineReader, @unchecked Sendable {
        struct Region { var bounds: CGRect; var text: String; var readings: [String] = [] }
        private let lock = NSLock()
        private var regions: [Region]
        private var calls: [[String]] = []
        let noise: Region?

        init(regions: [Region], noise: Region? = nil) { self.regions = regions; self.noise = noise }
        var seen: [[String]] { lock.withLock { calls } }
        func setRegions(_ new: [Region]) { lock.withLock { regions = new } }

        func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] {
            let current = lock.withLock { regions }
            lock.withLock { calls.append(drawing.strokes.map(InkSelection.identity)) }
            var lines: [RecognizedLine] = []
            var claimed = Set<Int>()
            for region in current {
                let hits = drawing.strokes.indices.filter { drawing.strokes[$0].renderBounds.intersects(region.bounds) }
                guard !hits.isEmpty else { continue }
                claimed.formUnion(hits)
                lines.append(RecognizedLine(text: region.text, bounds: region.bounds, readings: region.readings))
            }
            let loose = drawing.strokes.indices.filter { !claimed.contains($0) }
            if let noise, !loose.isEmpty {
                let box = loose.dropFirst().reduce(drawing.strokes[loose[0]].renderBounds) { $0.union(drawing.strokes[$1].renderBounds) }
                lines.append(RecognizedLine(text: noise.text, bounds: box, readings: noise.readings))
            }
            return lines
        }
    }

    private struct Fixture {
        var page: NotePageModel
        var reader: RegionReader
        var hanziInk: PKDrawing
        var pinyinInk: PKDrawing
    }

    /// Two notes far apart: one read as a single character with alternative readings (candidate fallback), one
    /// as Pinyin the starter vocabulary knows. `noise` is what OCR would say about any other stroke.
    private func fixture(folder: URL, noise: RegionReader.Region? = nil, pinyinText: String = "fùzé responsible for?") -> Fixture {
        let hanziInk = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 80, y: 160))
        let pinyinInk = SyntheticInk.drawing(writing: "人", origin: CGPoint(x: 500, y: 160))
        let reader = RegionReader(regions: [
            .init(bounds: hanziInk.bounds, text: "大", readings: ["大", "牛"]),
            .init(bounds: pinyinInk.bounds, text: pinyinText),
        ], noise: noise)
        let page = NotePageModel(pageID: "page-1", store: NoteStore(directory: folder), lineReader: reader)
        page.drawingDidChange(PKDrawing(strokes: hanziInk.strokes + pinyinInk.strokes))
        return Fixture(page: page, reader: reader, hanziInk: hanziInk, pinyinInk: pinyinInk)
    }

    private func suggest(_ page: NotePageModel) async {
        page.suggestions.request(for: page.drawing)
        await page.suggestions.task?.value
    }

    // MARK: - Generated replacement ink is never read again

    @Test func repeatedSuggestNeverReadsGeneratedReplacementInkAndKeepsOtherNotes() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        // If the replacement ink did reach the reader it would be read as this malformed, digit-filled text.
        let noise = RegionReader.Region(bounds: .zero, text: "x7大 a3b9", readings: ["x7大 a3b9", "大 牛 a3b9", "fu2ZeBa"])
        let f = fixture(folder: folder, noise: noise)
        await suggest(f.page)
        #expect(f.page.suggestions.pending.count == 2)
        let item = try #require(f.page.suggestions.pending.first { $0.recognizedText == "大" })
        #expect(f.page.replaceSuggestion(item.id, with: "牛"))
        let note = try #require(f.page.latestVisibleReplacement)
        let generated = try #require(note.replacement?.replacementStrokeIDs)
        #expect(!generated.isEmpty)

        var fingerprints: [[String]] = []
        for _ in 0..<3 {
            await suggest(f.page)
            let call = try #require(f.reader.seen.last)
            #expect(Set(call).isDisjoint(with: generated), "generated strokes must not reach the recognizer")
            // The accepted replacement is silent; the unrelated Pinyin note is still offered, every time.
            let pending = f.page.suggestions.pending
            #expect(pending.count == 1)
            #expect(pending.first?.recognizedText == "fùzé responsible for?")
            #expect(pending.first?.candidate.hanzi == "负责")
            // And nothing was drawn from or written over the accepted replacement.
            #expect(f.page.latestVisibleReplacement?.id == note.id)
            fingerprints.append(pending.map { $0.candidate.hanzi + $0.replacementText })
        }
        #expect(Set(fingerprints.map { $0.joined() }).count == 1, "repeated Suggest must be idempotent")
    }

    @Test func sourceRegionAnchoringStaysOnTheStudentsStrokes() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let f = fixture(folder: folder)
        await suggest(f.page)
        let item = try #require(f.page.suggestions.pending.first { $0.recognizedText == "大" })
        #expect(f.page.replaceSuggestion(item.id, with: "牛"))
        await suggest(f.page)
        let remaining = try #require(f.page.suggestions.pending.first)
        // Anchored on the Pinyin note's own ink, not shifted by the removed/generated strokes.
        #expect(remaining.anchor.intersects(f.pinyinInk.bounds))
        #expect(!remaining.anchor.intersects(f.hanziInk.bounds))
        #expect(remaining.sourceStrokeIDs == Set(f.pinyinInk.strokes.map(InkSelection.identity)))
        // Replacing the remaining note works against the full page and leaves the first replacement alone.
        let firstReplacement = try #require(f.page.latestVisibleReplacement)
        #expect(f.page.replaceSuggestion(remaining.id, with: "负责"))
        #expect(f.page.suggestions.annotations.count == 2)
        #expect(f.page.suggestions.annotations.first { $0.id == firstReplacement.id }?.text == "牛")
    }

    @Test func aPageWithOnlyAcceptedReplacementsDoesNotCallTheRecognizer() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let ink = SyntheticInk.drawing(writing: "大")
        let reader = RegionReader(regions: [.init(bounds: ink.bounds, text: "大", readings: ["大", "牛"])])
        let page = NotePageModel(pageID: "page-1", store: NoteStore(directory: folder), lineReader: reader)
        page.drawingDidChange(ink)
        await suggest(page)
        let item = try #require(page.suggestions.pending.first)
        #expect(page.replaceSuggestion(item.id, with: "牛"))
        let before = reader.seen.count
        await suggest(page)
        #expect(reader.seen.count == before)
        #expect(page.suggestions.pending.isEmpty)
        if case .message(let text) = page.suggestions.status { #expect(text.contains("No new handwriting")) } else { Issue.record("expected a message") }
    }

    @Test func replacementWithMovedStrokesStaysExcluded() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let f = fixture(folder: folder, noise: .init(bounds: .zero, text: "x7大 a3b9", readings: ["x7大 a3b9"]))
        await suggest(f.page)
        let item = try #require(f.page.suggestions.pending.first { $0.recognizedText == "大" })
        #expect(f.page.replaceSuggestion(item.id, with: "牛"))
        let note = try #require(f.page.latestVisibleReplacement)
        #expect(f.page.adjustReplacement(note.id, by: CGAffineTransform(translationX: 25, y: 10)))
        await suggest(f.page)
        let moved = try #require(f.page.suggestions.annotations.first?.replacement?.replacementStrokeIDs)
        #expect(Set(try #require(f.reader.seen.last)).isDisjoint(with: moved))
        #expect(f.page.suggestions.pending.map(\.recognizedText) == ["fùzé responsible for?"])
    }

    // MARK: - Accepted notes stay quiet; edits wake them

    @Test func acceptedNoteStaysQuietEvenIfOCRReadsTheSameInkDifferently() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let f = fixture(folder: folder)
        await suggest(f.page)
        let item = try #require(f.page.suggestions.pending.first { $0.recognizedText.hasPrefix("fùzé") })
        f.page.suggestions.accept(item.id, editedText: "负责 · fùzé · to be in charge of")
        let accepted = try #require(f.page.suggestions.annotations.first)
        #expect(accepted.gloss == "to be in charge of")
        #expect(accepted.sourceStrokeIDs == f.pinyinInk.strokes.map(InkSelection.identity).sorted())
        // A different (but still matching) reading of the very same strokes must not re-offer it.
        f.reader.setRegions([
            .init(bounds: f.hanziInk.bounds, text: "大", readings: ["大", "牛"]),
            .init(bounds: f.pinyinInk.bounds, text: "fuze responsible for"),
        ])
        await suggest(f.page)
        #expect(f.page.suggestions.pending.map(\.recognizedText) == ["大"])
        #expect(f.page.suggestions.annotations.first?.gloss == "to be in charge of")
    }

    @Test func editingTheNoteSourceMakesItEligibleAgain() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let f = fixture(folder: folder)
        await suggest(f.page)
        let item = try #require(f.page.suggestions.pending.first { $0.recognizedText.hasPrefix("fùzé") })
        f.page.suggestions.accept(item.id)
        await suggest(f.page)
        #expect(f.page.suggestions.pending.map(\.recognizedText) == ["大"])
        // The student adds a stroke inside that note: its source changed, so it is evaluated again.
        let extra = SyntheticInk.stroke(through: [CGPoint(x: f.pinyinInk.bounds.minX + 10, y: f.pinyinInk.bounds.midY),
                                                   CGPoint(x: f.pinyinInk.bounds.maxX - 10, y: f.pinyinInk.bounds.midY)])
        f.page.drawingDidChange(PKDrawing(strokes: f.page.drawing.strokes + [extra]))
        await suggest(f.page)
        #expect(f.page.suggestions.pending.contains { $0.recognizedText.hasPrefix("fùzé") })
    }

    @Test func olderNotesWithoutStrokeIdentitiesStillDedupeByText() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let hanziInk = SyntheticInk.drawing(writing: "人", origin: CGPoint(x: 500, y: 160))
        // A note saved before `sourceStrokeIDs` existed: no stroke identities, text-matched only.
        let legacyJSON = """
        {"version":1,"annotations":[{"id":"\(UUID().uuidString)","text":"负责 · to be responsible for","edited":false,
         "anchor":[[\(hanziInk.bounds.minX),\(hanziInk.bounds.minY)],[\(hanziInk.bounds.width),\(hanziInk.bounds.height)]],
         "recognizedText":"fùzé responsible for?"}]}
        """
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(legacyJSON.utf8).write(to: folder.appending(path: "page-1.annotations.json"))
        let reader = RegionReader(regions: [.init(bounds: hanziInk.bounds, text: "fùzé responsible for?")])
        let page = NotePageModel(pageID: "page-1", store: NoteStore(directory: folder), lineReader: reader)
        #expect(page.suggestions.annotations.first?.sourceStrokeIDs == nil)
        page.drawingDidChange(hanziInk)
        await suggest(page)
        #expect(page.suggestions.pending.isEmpty)
    }

    // MARK: - Malformed output is not offered as a word

    @Test func malformedMixedReadingsAreNeverOfferedAsCandidates() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let ink = SyntheticInk.drawing(writing: "大")
        let reader = RegionReader(regions: [.init(bounds: ink.bounds, text: "大",
                                                  readings: ["大", "x7牛", "牛 a3b9", "fu2ZeBa 我", "牛", "\u{FFFD}"])])
        let page = NotePageModel(pageID: "page-1", store: NoteStore(directory: folder), lineReader: reader)
        page.drawingDidChange(ink)
        await suggest(page)
        let item = try #require(page.suggestions.pending.first)
        #expect(item.proposal.candidates.map(\.hanzi) == ["大", "牛"])
    }

    @Test func aWhollyMalformedReadingOffersNothingAndDoesNotQuoteTheNoise() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let ink = SyntheticInk.drawing(writing: "大")
        let reader = RegionReader(regions: [.init(bounds: ink.bounds, text: "x7大 a3b9", readings: ["x7大 a3b9", "大3 b7"])])
        let page = NotePageModel(pageID: "page-1", store: NoteStore(directory: folder), lineReader: reader)
        page.drawingDidChange(ink)
        await suggest(page)
        #expect(page.suggestions.pending.isEmpty)
        if case .message(let text) = page.suggestions.status {
            #expect(!text.contains("x7"))
            #expect(!text.contains("a3b9"))
        } else { Issue.record("expected a message") }
        #expect(PageFlashcards.digest(of: page.drawing) == PageFlashcards.digest(of: ink))
    }

    @Test func partialHanziLineStillGetsItsCompletion() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let ink = SyntheticInk.drawing(writing: "大")
        // Hanzi prefix plus untoned Pinyin: well formed, so it still reaches the vocabulary.
        let reader = RegionReader(regions: [.init(bounds: ink.bounds, text: "好 hǎo xiang")])
        let page = NotePageModel(pageID: "page-1", store: NoteStore(directory: folder), lineReader: reader)
        page.drawingDidChange(ink)
        await suggest(page)
        let item = try #require(page.suggestions.pending.first)
        #expect(item.candidate.hanzi == "好像")
        #expect(item.candidate.gloss == "to seem like; to look like")
    }
}

@Suite("Reading well-formedness")
struct ReadingValidationTests {
    @Test(arguments: [
        "好 hǎo xiang", "农夫市集 nóngfū shìjí", "虽然…但是… Example: although it rains", "hao3 xiang4", "fu4ze2",
        "(1) to seem like; ~ like", "A/B 2 years", "iPad", "负责 · fùzé · to be in charge of", "大", "lü4", "3",
    ])
    func acceptsRealWriting(_ text: String) {
        #expect(ReadingValidation.isWellFormed(text), "\(text)")
    }

    @Test(arguments: [
        "x7大", "大3", "a3b9", "fu2ZeBa", "hao5x", "fuze7", "\u{FFFD}", "好\u{0001}", "", "   ", "牛 a3b9",
    ])
    func rejectsMalformedMixedOCR(_ text: String) {
        #expect(!ReadingValidation.isWellFormed(text), "\(text.debugDescription)")
    }

    @Test func rejectsOverlongReadings() {
        #expect(!ReadingValidation.isWellFormed(String(repeating: "大", count: 201)))
    }
}
