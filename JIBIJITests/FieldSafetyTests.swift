import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import JIBIJI

/// Stage 2 of the recognition overhaul: a misread or untoned romanization stays in the Pinyin field and never
/// becomes the English definition, on every path that builds a card. Synthetic text only. The starter-vocabulary
/// word and the Han-to-Latin transform are test fixtures here, not claims about what any real note says.
@Suite("Pinyin never becomes English", .serialized)
@MainActor
struct FieldSafetyTests {
    // MARK: - Slot matching

    @Test func slotAcceptsExactAndNearSpellingButNotEnglish() {
        #expect(PinyinSlot.leading(["nongfu", "shiji"], expected: "nóngfū shìjí") == .init(count: 2, exact: true))
        #expect(PinyinSlot.leading(["nongfu", "shiiji", "market"], expected: "nóngfū shìjí") == .init(count: 2, exact: false))
        #expect(PinyinSlot.leading(["nongfushiji"], expected: "nóngfū shìjí") == .init(count: 1, exact: true))
        #expect(PinyinSlot.leading(["farmers'", "market"], expected: "nóngfū shìjí") == nil)
        // Short syllables only match exactly: "has" is not a misread "hǎo".
        #expect(PinyinSlot.leading(["has"], expected: "hǎo") == nil)
        #expect(PinyinSlot.leading(["hao"], expected: "hǎo") == .init(count: 1, exact: true))
        #expect(PinyinSlot.leading([], expected: "hǎo") == nil)
        #expect(PinyinSlot.leading(["x7"], expected: "fùzé") == nil)
    }

    @Test func toneNumbersAndPunctuationStillCountAsPinyin() throws {
        #expect(PinyinSlot.leading(["nong2fu1", "shi4ji2", "farmers'"], expected: "nóngfū shìjí") == .init(count: 2, exact: true))
        #expect(PinyinSlot.leading(["(nóngfū", "shìjí),", "market"], expected: "nóngfū shìjí") == .init(count: 2, exact: true))
        let split = try #require(PinyinSlot.split("nong2fu1 shi4ji2 farmers'\nmarket", expected: "nóngfū shìjí"))
        #expect(split.remainder == "farmers'\nmarket", "the English keeps its own line breaks")
        #expect(FlashcardExtractor.extract(from: "农夫市集 nong2fu1 shi4ji2 farmers' market")?.back == "nóngfū shìjí — farmers' market")
    }

    @Test func romanizationOfAHanziIsRecognisedNotEnglish() {
        #expect(PinyinSlot.isRomanization("nongfu shiiji", of: "农夫市集"))
        #expect(PinyinSlot.isRomanization("nóngfū shìjí", of: "农夫市集"))
        #expect(!PinyinSlot.isRomanization("farmers' market", of: "农夫市集"))
        #expect(!PinyinSlot.isRomanization("market", of: "农夫市集"))
        #expect(PinyinSlot.isRomanization("dianao", of: "电脑"))
        #expect(!PinyinSlot.isRomanization("computer", of: "电脑"))
    }

    // MARK: - Extractor

    @Test func misreadPinyinOfAKnownWordIsNotTheDefinition() throws {
        let withEnglish = try #require(FlashcardExtractor.extract(from: "农夫市集 nongfu shiiji farmers' market"))
        #expect(withEnglish.back == "nóngfū shìjí — farmers' market")
        #expect(withEnglish.needsReview)
        // Pinyin only: the dictionary meaning is used, and the misread spelling appears nowhere on the card.
        let pinyinOnly = try #require(FlashcardExtractor.extract(from: "农夫市集 nongfu shiiji"))
        #expect(!pinyinOnly.back.contains("shiiji"))
        #expect(!pinyinOnly.back.contains("nongfu"))
        #expect(pinyinOnly.needsReview)
    }

    @Test func misreadPinyinOfAnUnknownWordStaysPinyinAndNeverBecomesEnglish() throws {
        let draft = try #require(FlashcardExtractor.extract(from: "电脑 dianao computer"))
        #expect(draft.back == "dianao — computer")
        #expect(draft.needsReview)
        // Only misread Pinyin and nothing else: no card, never "dianao" as a meaning.
        #expect(FlashcardExtractor.extract(from: "电脑 dianao") == nil)
        // Real English is untouched, and exact Pinyin still works.
        #expect(FlashcardExtractor.extract(from: "电脑 diannao computer")?.back == "diannao — computer")
        #expect(FlashcardExtractor.extract(from: "电脑 the computer")?.back == "the computer")
    }

    // MARK: - Accepted-note parsing

    @Test func parsedNoteKeepsMisreadPinyinOutOfTheGloss() {
        let parsed = AcceptedAnnotation.parse("农夫市集 · nongfu shiiji · farmers' market", knownPinyin: "nóngfū shìjí")
        #expect(parsed.pinyin == "nóngfū shìjí")
        #expect(parsed.glossParts == ["farmers' market"])
        #expect(!parsed.ambiguous)
    }

    @Test func replacementTextWithoutSeparatorsSplitsPinyinFromEnglish() throws {
        let proposal = try #require(StarterVocabulary.standard.proposal(forRecognizedText: "农夫市集"))
        let item = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: "农夫市集", proposal: proposal)
        let parts = PageSuggestionModel.replacementParts("农夫市集 nongfu shiiji farmers' market", for: item)
        #expect(parts.hanzi == "农夫市集")
        #expect(parts.pinyin == "nóngfū shìjí")
        #expect(parts.gloss == "farmers' market")
        // Untoned Pinyin that is exactly right: same split.
        let untoned = PageSuggestionModel.replacementParts("农夫市集 nongfu shiji", for: item)
        #expect(untoned.pinyin == "nóngfū shìjí")
        #expect(untoned.gloss == nil)
    }

    @Test func legacyNoteWhoseEnglishIsRomanizationBuildsNoCardFromIt() {
        let note = AcceptedAnnotation(id: UUID(), text: "x", edited: false, anchor: .zero, recognizedText: "x",
                                      hanzi: "农夫市集", pinyin: nil, gloss: "nongfu shiiji")
        #expect(PageFlashcards.resolve(note, line: RecognizedLine(text: "x", bounds: .zero), vocabulary: .standard) == nil)
        let good = AcceptedAnnotation(id: UUID(), text: "x", edited: false, anchor: .zero, recognizedText: "x",
                                      hanzi: "农夫市集", pinyin: "nóngfū shìjí", gloss: "farmers' market")
        #expect(PageFlashcards.resolve(good, line: RecognizedLine(text: "x", bounds: .zero), vocabulary: .standard)?.gloss == "farmers' market")
    }

    @Test func approvedEnglishThatEqualsARomanizationIsKeptOnlyBesideRealPinyin() {
        func note(pinyin: String?) -> AcceptedAnnotation {
            AcceptedAnnotation(id: UUID(), text: "x", edited: true, anchor: .zero, recognizedText: "x",
                               hanzi: "农夫市集", pinyin: pinyin, gloss: "nongfu shiji")
        }
        let line = RecognizedLine(text: "x", bounds: .zero)
        // The student approved this English next to a Pinyin field: it is theirs.
        #expect(PageFlashcards.resolve(note(pinyin: "nóngfū shìjí"), line: line, vocabulary: .standard)?.gloss == "nongfu shiji")
        // No Pinyin field at all: the old misfiling, so it is not turned into a definition.
        #expect(PageFlashcards.resolve(note(pinyin: nil), line: line, vocabulary: .standard) == nil)
    }

    @Test func aNoteWithNoUsableEnglishIsReportedNotDroppedSilently() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Stage2-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ink = SyntheticInk.drawing(writing: "大")
        // A word the starter list does not know: nothing else can supply a meaning, so say so.
        let note = AcceptedAnnotation(id: UUID(), text: "x", edited: false, anchor: ink.bounds, recognizedText: "电脑",
                                      hanzi: "电脑", pinyin: nil, gloss: "dianao")
        let model = PageFlashcards(pageID: "page-1", store: NoteStore(directory: folder),
                                   reader: FixedReader(result: [RecognizedLine(text: "电脑", bounds: ink.bounds)]))
        await model.refresh(from: ink, annotations: [note]).value
        #expect(model.skippedNotes == 1)
        if case .message(let text) = model.status { #expect(text.contains("no English meaning")) } else { Issue.record("expected a message") }
        #expect(model.cards.isEmpty)
    }

    @Test func aKnownWordWithMisfiledEnglishFallsBackToItsDictionaryMeaningNotTheMisreading() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Stage2-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ink = SyntheticInk.drawing(writing: "大")
        let note = AcceptedAnnotation(id: UUID(), text: "x", edited: false, anchor: ink.bounds, recognizedText: "农夫市集",
                                      hanzi: "农夫市集", pinyin: nil, gloss: "nongfu shiiji")
        let model = PageFlashcards(pageID: "page-1", store: NoteStore(directory: folder),
                                   reader: FixedReader(result: [RecognizedLine(text: "农夫市集", bounds: ink.bounds)]))
        await model.refresh(from: ink, annotations: [note]).value
        #expect(model.cards.map(\.back) == ["nóngfū shìjí — farmers' market"])
        #expect(model.cards.allSatisfy { !$0.back.contains("shiiji") })
    }

    @Test func twoNotesEachKeepTheirOwnCardWhenReadAgainDifferently() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Stage2-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 80, y: 160))
        let b = SyntheticInk.drawing(writing: "人", origin: CGPoint(x: 500, y: 160))
        func note(_ ink: PKDrawing, _ hanzi: String, _ pinyin: String, _ gloss: String) -> AcceptedAnnotation {
            AcceptedAnnotation(id: UUID(), text: "\(hanzi) · \(pinyin) · \(gloss)", edited: true, anchor: ink.bounds, recognizedText: "was read otherwise",
                               hanzi: hanzi, pinyin: pinyin, gloss: gloss, sourceStrokeIDs: ink.strokes.map(InkSelection.identity).sorted())
        }
        let notes = [note(a, "负责", "fùzé", "to be in charge of"), note(b, "复习", "fùxí", "to go over")]
        let reads = [RecognizedLine(text: "junk one", bounds: a.bounds), RecognizedLine(text: "junk two", bounds: b.bounds)]
        let model = PageFlashcards(pageID: "page-1", store: NoteStore(directory: folder), reader: FixedReader(result: reads))
        await model.refresh(from: PKDrawing(strokes: a.strokes + b.strokes), annotations: notes).value
        #expect(Set(model.cards.map(\.back)) == ["fùzé — to be in charge of", "fùxí — to go over"])
        #expect(model.cards.count == 2)
    }

    // MARK: - Cards follow the accepted note by its source strokes

    private struct FixedReader: InkLineReader {
        var result: [RecognizedLine]
        func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] { result }
    }

    @Test func cardUsesTheAcceptedFieldsEvenWhenTheCardTimeReadingSpellsItDifferently() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Stage2-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ink = SyntheticInk.drawing(writing: "大")
        let ids = ink.strokes.map(InkSelection.identity)
        let note = AcceptedAnnotation(id: UUID(), text: "负责 · fùzé · to be in charge of", edited: true, anchor: ink.bounds,
                                      recognizedText: "fùzé responsible for?", hanzi: "负责", pinyin: "fùzé",
                                      gloss: "to be in charge of", sourceStrokeIDs: ids.sorted())
        // Suggest read "fùzé responsible for?"; the card-time read of the same strokes is different junk.
        let cardRead = RecognizedLine(text: "fuuze n0ngfu", bounds: ink.bounds)
        let model = PageFlashcards(pageID: "page-1", store: NoteStore(directory: folder), reader: FixedReader(result: [cardRead]))
        await model.refresh(from: ink, annotations: [note]).value
        #expect(model.cards.count == 1)
        #expect(model.cards.first?.front == "负责")
        #expect(model.cards.first?.back == "fùzé — to be in charge of")
        #expect(model.cards.first?.correction?.annotationID == note.id)
    }

    @Test func cardGenerationDoesNotReadGeneratedReplacementInk() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Stage2-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        final class Recorder: InkLineReader, @unchecked Sendable {
            let lock = NSLock(); var seen: [[String]] = []
            func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] {
                lock.withLock { seen.append(drawing.strokes.map(InkSelection.identity)) }
                return []
            }
        }
        let original = SyntheticInk.drawing(writing: "大")
        let generated = try #require(CleanHandwriting.drawing(text: "牛", in: original.bounds))
        let note = AcceptedAnnotation(id: UUID(), text: "牛 · ox", edited: false, anchor: original.bounds, recognizedText: "大",
                                      hanzi: "牛", pinyin: nil, gloss: "ox",
                                      replacement: InkReplacement(originalInk: original.dataRepresentation(), originalIndices: Array(original.strokes.indices),
                                                                  replacementStrokeIDs: Set(generated.strokes.map(InkSelection.identity))))
        let recorder = Recorder()
        let model = PageFlashcards(pageID: "page-1", store: NoteStore(directory: folder), reader: recorder)
        await model.refresh(from: generated, annotations: [note]).value
        #expect(recorder.seen.allSatisfy { $0.isEmpty }, "the recognizer must not see generated strokes")
    }
}
