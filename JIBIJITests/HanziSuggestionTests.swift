import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import JIBIJI

/// Issue #11: offer the missing Pinyin and English for recognized Hanzi, and say so plainly when nothing
/// is a confident match. Synthetic text only.
@Suite("Suggest missing Pinyin and English for Hanzi")
struct HanziSuggestionTests {
    let vocabulary = StarterVocabulary.standard

    private func note(_ text: String) throws -> String {
        let proposal = try #require(vocabulary.proposal(forRecognizedText: text))
        return PendingSuggestion(revision: 0, anchor: .zero, recognizedText: text, proposal: proposal).annotationText
    }

    @Test func hanziAloneOffersPinyinAndEnglishForHaoxiang() throws {
        #expect(try note("好像") == "(hǎoxiàng) · to seem like; to look like")
    }

    @Test func hanziAloneOffersPinyinAndEnglishForFarmersMarket() throws {
        #expect(try note("农夫市集") == "(nóngfū shìjí) · farmers' market")
    }

    @Test(arguments: ["农夫市集 nong fu shi ji", "农夫市集 nongfushiji", "农夫市集 Nong Fu Shi Ji"])
    func untonedPinyinKeepsInkAndOffersToneMarkedReadingPlusEnglish(text: String) throws {
        let proposal = try #require(vocabulary.proposal(forRecognizedText: text))
        #expect(proposal.pinyinState == .missingTones && proposal.hanziAlreadyWritten)
        #expect(try note(text) == "(nóngfū shìjí) · farmers' market")
    }

    @Test func untonedPinyinForHaoxiangOffersToneMarksAndEnglish() throws {
        #expect(try note("好像 hao xiang") == "(hǎoxiàng) · to seem like; to look like")
    }

    @Test func correctTonedPinyinIsKeptAndOnlyEnglishIsOffered() throws {
        let proposal = try #require(vocabulary.proposal(forRecognizedText: "农夫市集 nóngfū shìjí"))
        #expect(proposal.pinyinState == .correct)
        #expect(try note("农夫市集 nóngfū shìjí") == "farmers' market")
        #expect(try note("好像 hǎo xiàng") == "to seem like; to look like")
    }

    @Test func wrongTonesGetAProvisionalCorrectionButNoInkEdit() throws {
        let text = "好像 hǎo xiāng"
        let proposal = try #require(vocabulary.proposal(forRecognizedText: text))
        #expect(proposal.pinyinState == .wrongTones(written: "hǎo xiāng"))
        let pending = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: text, proposal: proposal)
        #expect(pending.annotationText == "(hǎoxiàng) · to seem like; to look like")
        #expect(!pending.allowsInkReplacement)
        #expect(pending.uncertaintyNote?.contains("hǎo xiāng") == true)
    }

    @Test(arguments: ["好 hǎo xiang", "好 hao xiàng"])
    func partlyTonedPartialHanziStillAllowsReplacement(text: String) throws {
        let proposal = try #require(vocabulary.proposal(forRecognizedText: text))
        #expect(proposal.pinyinState == .missingTones)
        let pending = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: text, proposal: proposal)
        #expect(pending.annotationText == "像 · to seem like; to look like")
        #expect(pending.allowsInkReplacement && pending.uncertaintyNote == nil)
    }

    @Test func partlyTonedFullHanziIsMissingTonesNotWrong() throws {
        let proposal = try #require(vocabulary.proposal(forRecognizedText: "农夫市集 nóng fu shi ji"))
        #expect(proposal.pinyinState == .missingTones)
    }

    @Test func wrongToneOnPartialHanziAlsoOffersTheCorrection() throws {
        let proposal = try #require(vocabulary.proposal(forRecognizedText: "好 hǎo xiāng"))
        let pending = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: "好 hǎo xiāng", proposal: proposal)
        #expect(pending.annotationText == "像 · (hǎoxiàng) · to seem like; to look like")
        #expect(!pending.allowsInkReplacement)
    }

    @Test func oneLetterOffIsUncertainAndNeverAnInkEdit() throws {
        let text = "农夫市集 none fu shi ji"
        let proposal = try #require(vocabulary.proposal(forRecognizedText: text))
        #expect(proposal.pinyinState == .possibleSpelling(written: "none fu shi ji"))
        let pending = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: text, proposal: proposal)
        #expect(pending.annotationText == "(nóngfū shìjí) · farmers' market")
        #expect(!pending.allowsInkReplacement)
        #expect(pending.uncertaintyNote?.contains("spelling slip or a misread") == true)
    }

    @Test func solidReadingsStillAllowInkReplacement() throws {
        for text in ["好像", "农夫市集 nong fu shi ji", "农夫市集 nóngfū shìjí"] {
            let proposal = try #require(vocabulary.proposal(forRecognizedText: text))
            let pending = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: text, proposal: proposal)
            #expect(pending.allowsInkReplacement && pending.uncertaintyNote == nil)
        }
    }

    @Test func tooFarOffOrPinyinWithoutHanziAbstains() {
        // Two letters off, or no Hanzi to anchor the word: ambiguous, so nothing is suggested.
        #expect(vocabulary.proposal(forRecognizedText: "农夫市集 nang fu shu ji") == nil)
        #expect(vocabulary.proposal(forRecognizedText: "none fu shi ji") == nil)
        #expect(vocabulary.proposal(forRecognizedText: "好像 hǎo xiàng to look like extra") == nil)
    }

    @Test func completeNotesNeedNothing() {
        #expect(vocabulary.proposal(forRecognizedText: "好像 hǎoxiàng to seem like; to look like") == nil)
        #expect(vocabulary.proposal(forRecognizedText: "农夫市集 nóngfū shìjí farmers' market") == nil)
    }

    @Test func englishAlreadyWrittenIsNotRepeated() throws {
        #expect(try note("好像 to look like") == "(hǎoxiàng)")
        // Untoned Pinyin plus English: only the tone-marked reading is left to offer.
        #expect(try note("农夫市集 nong fu shi ji farmers' market") == "(nóngfū shìjí)")
    }

    @Test func uncertainRecognizedTextGetsNoGuess() {
        // Not farmers' market: this term is unknown, so the provider must abstain.
        #expect(vocabulary.proposal(forRecognizedText: "农夫试剂") == nil)
        #expect(vocabulary.proposal(forRecognizedText: "农夫试剂 nong fu shi ji") == nil)
        #expect(vocabulary.proposal(forRecognizedText: "农夫市") == nil)
    }

    @Test func noMatchMessageNamesTheReading() {
        let message = PageSuggestionModel.noMatchMessage(["农夫试剂"])
        #expect(message.contains("“农夫试剂”"))
        #expect(message.contains("No confident match"))
        #expect(message.contains("ink is unchanged"))
    }
}

private struct StubReader: InkLineReader {
    var lines: [RecognizedLine]
    func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] { lines }
}

@MainActor
@Suite("Suggest feedback for Hanzi")
final class HanziSuggestionModelTests {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HanziSuggestionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let ink = SyntheticInk.drawing(writing: "十")
    deinit { try? FileManager.default.removeItem(at: directory) }

    private func run(_ lines: [RecognizedLine]) async -> PageSuggestionModel {
        let model = PageSuggestionModel(pageID: "page-1", store: SuggestionStore(directory: directory), reader: StubReader(lines: lines))
        model.request(for: ink)
        await model.task?.value
        return model
    }

    @Test func unknownHanziShowsAClearNoConfidentMatchMessage() async {
        let model = await run([RecognizedLine(text: "农夫试剂", bounds: CGRect(x: 10, y: 10, width: 200, height: 60))])
        #expect(model.pending.isEmpty)
        #expect(model.status == .message(PageSuggestionModel.noMatchMessage(["农夫试剂"])))
    }

    @Test func matchedLineKeepsStatusQuietEvenWithAnUnknownLine() async {
        let model = await run([
            RecognizedLine(text: "好像", bounds: CGRect(x: 10, y: 10, width: 200, height: 60)),
            RecognizedLine(text: "农夫试剂", bounds: CGRect(x: 10, y: 120, width: 200, height: 60)),
        ])
        #expect(model.pending.count == 1)
        #expect(model.pending.first?.annotationText == "(hǎoxiàng) · to seem like; to look like")
        #expect(model.status == .idle)
    }

    @Test func completeKnownLineIsNeverCalledUnknown() async {
        let model = await run([RecognizedLine(text: "农夫市集 nóngfū shìjí farmers' market", bounds: CGRect(x: 10, y: 10, width: 200, height: 60))])
        #expect(model.pending.isEmpty)
        if case .message(let text) = model.status {
            #expect(!text.contains("No confident match"))
        } else {
            Issue.record("expected a message")
        }
    }

    @Test func longUnknownLineIsShortenedInTheMessage() {
        let message = PageSuggestionModel.noMatchMessage(["这是一个很长很长很长很长很长的句子"])
        #expect(message.contains("…"))
        #expect(!message.contains("句子"))
    }

    @Test func partialPrefixDoesNotOfferPinyinAndKeepsAlternatives() throws {
        let proposal = try #require(StarterVocabulary.standard.proposal(forRecognizedText: "好 hao xiang"))
        let pending = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: "好 hao xiang", proposal: proposal)
        #expect(pending.annotationText == "像 · to seem like; to look like")
    }

    @Test func acceptingPinyinOnlySuggestionKeepsTheStudentsEnglish() async throws {
        let model = await run([RecognizedLine(text: "好像 to look like", bounds: CGRect(x: 10, y: 10, width: 200, height: 60))])
        let id = try #require(model.pending.first?.id)
        model.accept(id)
        let saved = try #require(model.annotations.first)
        #expect(saved.text == "(hǎoxiàng)")
        #expect(saved.pinyin == "hǎoxiàng" && saved.gloss == nil)
    }

    @Test func acceptingHanziOnlySuggestionKeepsPinyinAndEnglishSeparate() async throws {
        let model = await run([RecognizedLine(text: "农夫市集", bounds: CGRect(x: 10, y: 10, width: 200, height: 60))])
        let id = try #require(model.pending.first?.id)
        model.accept(id)
        let saved = try #require(model.annotations.first)
        #expect(saved.pinyin == "nóngfū shìjí")
        #expect(saved.gloss == "farmers' market")
    }

    @Test func nonHanziNoResultKeepsTheGenericMessage() async {
        let model = await run([RecognizedLine(text: "hello world", bounds: CGRect(x: 10, y: 10, width: 200, height: 60))])
        #expect(model.status == .message("No clear reading found. Try a smaller group of words or clearer spacing. Your ink is unchanged."))
    }
}
