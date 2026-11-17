import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import JIBIJI

@Suite("Recognition cross-checks")
struct RecognitionCrossCheckTests {
    let bounds = CGRect(x: 80, y: 100, width: 280, height: 40)

    @Test func alternativePinyinCorrectsTranscriptionWithoutChangingEnglish() throws {
        let raw = RecognizedLine(text: "农 none farmer", bounds: bounds, readings: ["农 nong farmer", "农 nóng farmer"])
        let line = try #require(RecognitionCrossCheck.resolve([raw]).first)
        #expect(line.text == "农 nóng farmer")
        #expect(line.rawText == raw.text)
        #expect((line.text != line.rawText && line.inkEditSuppressed))
        #expect(!line.needsReview)
        #expect(FlashcardExtractor.extract(from: line.text)?.back == "nóng — farmer")
    }

    @Test func nearbyRegionsAreComparedRegardlessOfInputOrder() throws {
        let hanzi = RecognizedLine(text: "农", bounds: CGRect(x: 80, y: 100, width: 40, height: 40))
        let latin = RecognizedLine(text: "none farmer", bounds: CGRect(x: 140, y: 100, width: 200, height: 40), readings: ["nong farmer"])
        for input in [[hanzi, latin], [latin, hanzi]] {
            let lines = RecognitionCrossCheck.resolve(input)
            #expect(lines.count == 1)
            let line = try #require(lines.first)
            #expect(line.text == "农 nong farmer")
            #expect(line.rawText == "农 none farmer")
            #expect(line.bounds == hanzi.bounds.union(latin.bounds))
        }
    }

    @Test func distantAndDifferentRowsDoNotSupplyContext() {
        let hanzi = RecognizedLine(text: "农", bounds: CGRect(x: 80, y: 100, width: 40, height: 40))
        for box in [CGRect(x: 500, y: 100, width: 200, height: 40), CGRect(x: 140, y: 200, width: 200, height: 40)] {
            let latin = RecognizedLine(text: "none", bounds: box, readings: ["nong"])
            let lines = RecognitionCrossCheck.resolve([hanzi, latin])
            #expect(lines.count == 2)
            #expect(lines.contains { $0.text == "none" && $0.needsReview })
            #expect(!lines.contains { ($0.text != $0.rawText && $0.inkEditSuppressed) })
        }
    }

    @Test func disagreementWithoutSupportingContextIsFlagged() throws {
        for raw in [
            RecognizedLine(text: "none", bounds: bounds, readings: ["nong"]),
            RecognizedLine(text: "农 none farmer", bounds: bounds, readings: ["农 long farmer"])
        ] {
            let line = try #require(RecognitionCrossCheck.resolve([raw]).first)
            #expect(line.text == raw.text)
            #expect(line.needsReview)
            #expect(!(line.text != line.rawText && line.inkEditSuppressed))
        }
    }

    @Test func explicitTonesRankReadingsAndValidPrimaryIsPreserved() throws {
        let wrong = RecognizedLine(text: "农 nòng farmer", bounds: bounds, readings: ["农 nóng farmer"])
        let conflicting = try #require(RecognitionCrossCheck.resolve([wrong]).first)
        #expect(conflicting.text == wrong.text)
        #expect(conflicting.needsReview && conflicting.inkEditSuppressed)
        let valid = RecognizedLine(text: "农 nong farmer", bounds: bounds, readings: ["农 nóng farmer"])
        let line = try #require(RecognitionCrossCheck.resolve([valid]).first)
        #expect(line.text == valid.text)
        #expect(!(line.text != line.rawText && line.inkEditSuppressed))
        let noMatch = RecognizedLine(text: "农 none farmer", bounds: bounds, readings: ["农 nòng farmer"])
        #expect(try #require(RecognitionCrossCheck.resolve([noMatch]).first).text == noMatch.text)
    }

    @Test func englishDisagreementStaysUnresolvedAndWrongTonesAreNotSilentlyFixed() throws {
        let raw = RecognizedLine(text: "农 nong farmer", bounds: bounds, readings: ["农 nong agriculture"])
        let line = try #require(RecognitionCrossCheck.resolve([raw]).first)
        #expect(line.text == raw.text)
        #expect(!line.needsReview, "Plain English variants do not supply Pinyin evidence")
        let draft = try #require(FlashcardExtractor.extract(from: "好像 hào xiang to look like"))
        #expect(draft.back == "hào xiang — to look like")
        #expect(draft.needsReview)
        #expect(FlashcardExtractor.extract(from: "好像 hào xiang")?.back == "hào xiang — to seem like; to look like")
        #expect(!RecognitionCrossCheck.pinyinAgrees("nu", with: "nǚ"))
        #expect(RecognitionCrossCheck.pinyinAgrees("nü", with: "nǚ"))
        #expect(AcceptedAnnotation.parse("好像 · hào xiang · looks as if", knownPinyin: "hǎoxiàng").pinyin == "hào xiang")
    }
}

@MainActor
@Suite("Recognition consumers")
struct RecognitionConsumerTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("CrossCheck-\(UUID().uuidString)") }

    @Test func cardsUseCrossCheckedPinyinAndKeepRawSource() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let ink = SyntheticInk.drawing(writing: "大")
        let raw = RecognizedLine(text: "农 none farmer", bounds: ink.bounds, readings: ["农 nong farmer"])
        let page = NotePageModel(pageID: "page-1", store: NoteStore(directory: directory), lineReader: CrossCheckReader(lines: [raw]))
        page.drawingDidChange(ink)
        page.suggestions.request(for: ink); await page.suggestions.task?.value
        #expect(page.suggestions.pending.isEmpty, "A transcription fix must not request an ink correction")
        await page.flashcards.refresh(from: ink).value
        let card = try #require(page.flashcards.currentDrafts.first)
        #expect(card.front == "农")
        #expect(card.back == "nong — farmer")
        #expect(card.sourceText == raw.text)
        #expect(card.needsReview)
    }

    @Test func missingFieldsSurviveReplacementReopenAndCardExport() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(directory: directory)
        let ink = SyntheticInk.drawing(writing: "大")
        let raw = RecognizedLine(text: "好像 hao xiang", bounds: ink.bounds)
        let page = NotePageModel(pageID: "page-1", store: store, lineReader: CrossCheckReader(lines: [raw]))
        page.drawingDidChange(ink)
        page.suggestions.request(for: ink); await page.suggestions.task?.value
        let item = try #require(page.suggestions.pending.first)
        #expect(item.replacementText == "好像 · hao xiang · to seem like; to look like")
        #expect(page.replaceSuggestion(item.id, with: "好像 · hao xiang · looks as if"))
        let reopened = NotePageModel(pageID: "page-1", store: store, lineReader: CrossCheckReader(lines: []))
        let note = try #require(reopened.latestVisibleReplacement)
        #expect(note.hanzi == "好像")
        #expect(note.gloss == "looks as if")
        await reopened.flashcards.refresh(from: reopened.drawing, annotations: reopened.suggestions.annotations).value
        let card = try #require(reopened.flashcards.currentDrafts.first)
        #expect(card.back == "hǎoxiàng — looks as if")
        reopened.flashcards.approve(card.id)
        #expect(reopened.flashcards.quizletExport == "好像\thǎoxiàng — looks as if")
        #expect(reopened.restoreOriginal(note.id))
        #expect(PageFlashcards.digest(of: reopened.drawing) == PageFlashcards.digest(of: ink))
    }

    @Test func approvedEnglishWinsOverOCRAlternatives() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let ink = SyntheticInk.drawing(writing: "大")
        let raw = RecognizedLine(text: "农 none farmer", bounds: ink.bounds, readings: ["农 nong farmer"])
        let cards = PageFlashcards(pageID: "page-1", store: NoteStore(directory: directory), reader: CrossCheckReader(lines: [raw]))
        let note = AcceptedAnnotation(id: UUID(), text: "农 · nóng · farming (class note)", edited: true,
                                      anchor: ink.bounds, recognizedText: raw.text,
                                      hanzi: "农", pinyin: "nóng", gloss: "farming (class note)")
        await cards.refresh(from: ink, annotations: [note]).value
        #expect(cards.currentDrafts.first?.back == "nóng — farming (class note)")
        #expect(cards.currentDrafts.first?.needsReview == false)
    }

    @Test func unresolvedReadingsReturnAnUneditedApprovedCardToReview() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let cards = PageFlashcards(pageID: "page-1", store: NoteStore(directory: directory), reader: CrossCheckReader(lines: []))
        cards.inkChanged(PKDrawing())
        let digest = try #require(cards.currentDigest)
        let line = RecognizedLine(text: "好像 hǎo xiàng to look like", bounds: .zero)
        cards.merge(lines: [line], digest: digest)
        cards.approve(try #require(cards.currentDrafts.first).id)
        #expect(cards.approvedCurrent.count == 1)
        var uncertain = line
        uncertain.readings = ["好像 hǎo xiāng to look like"]
        cards.merge(lines: [uncertain], digest: digest)
        #expect(cards.approvedCurrent.isEmpty)
        #expect(cards.currentDrafts.first?.needsReview == true)
        #expect(cards.currentDrafts.first?.back == "hǎoxiàng — to look like")
    }

    @Test func unchangedUneditedApprovalSurvivesRefresh() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let cards = PageFlashcards(pageID: "page-1", store: NoteStore(directory: directory), reader: CrossCheckReader(lines: []))
        cards.inkChanged(PKDrawing())
        let digest = try #require(cards.currentDigest)
        let line = RecognizedLine(text: "农 nong farmer", bounds: .zero)
        cards.merge(lines: [line], digest: digest)
        cards.approve(try #require(cards.currentDrafts.first).id)
        cards.merge(lines: [line], digest: digest)
        #expect(cards.approvedCurrent.count == 1)
        #expect(cards.approvedCurrent.first?.back == "nong — farmer")
    }
}

private struct CrossCheckReader: InkLineReader {
    var lines: [RecognizedLine]
    func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] { lines }
}
