import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import JIBIJI

/// Issue #12: cross-check readings of the same ink before drafting a card or offering an ink edit.
/// Synthetic text only.
@Suite("Reading cross-check")
struct ReadingCrossCheckTests {
    @Test func syllableInventoryKnowsPinyinAndNotEnglish() {
        for word in ["nong", "fu", "nóng", "nongfu", "hao", "xiang", "shi", "ji"] { #expect(ReadingCrossCheck.isPinyin(word)) }
        for word in ["none", "farmers", "market", "to", "the", ""] { #expect(!ReadingCrossCheck.isPinyin(word)) }
    }

    @Test func primaryNoneWithAlternativeNongNearNongCorrectsTheDraft() {
        let outcome = ReadingCrossCheck.resolve(primary: "农夫 none fu", alternatives: ["农夫 nong fu"])
        #expect(outcome.status == .corrected && outcome.text == "农夫 nong fu")
    }

    @Test func validButMisfitPrimaryIsFlaggedNotOverridden() {
        // nang is valid Pinyin (maybe a rarer reading), so it is kept as read and flagged, never overridden.
        let outcome = ReadingCrossCheck.resolve(primary: "农夫 nang fu", alternatives: ["农夫 nong fu"])
        #expect(outcome.status == .unresolved && outcome.text == "农夫 nang fu")
    }

    @Test func polyphonicHanziIsNeverSilentlyCorrected() {
        // 行 romanizes to xing by default, but yin hang is right: keep it, flag the disagreement.
        let outcome = ReadingCrossCheck.resolve(primary: "银行 yin hang", alternatives: ["银行 yin xing"])
        #expect(outcome.status == .unresolved && outcome.text == "银行 yin hang")
    }

    @Test func tonedAlternativeIsPreferredWhenLettersAgree() {
        let outcome = ReadingCrossCheck.resolve(primary: "农夫 none fu", alternatives: ["农夫 nong fu", "农夫 nóng fu"])
        #expect(outcome.status == .corrected && outcome.text == "农夫 nóng fu")
    }

    @Test func conflictingTonesOnAValidWordAreFlagged() {
        let outcome = ReadingCrossCheck.resolve(primary: "农夫 nóng fu", alternatives: ["农夫 nòng fu"])
        #expect(outcome.status == .unresolved && outcome.text == "农夫 nóng fu")
    }

    @Test func conflictingTonedAlternativesForAnInvalidWordStayUnresolved() {
        let outcome = ReadingCrossCheck.resolve(primary: "农夫 none fu", alternatives: ["农夫 nóng fu", "农夫 nòng fu"])
        #expect(outcome.status == .unresolved && outcome.text == "农夫 none fu")
    }

    @Test func plainEnglishVariantsThatHappenToSplitIntoSyllablesAreNotFlagged() {
        #expect(ReadingCrossCheck.resolve(primary: "农夫 nong fu lines", alternatives: ["农夫 nong fu line"]).status == .agreed)
        #expect(ReadingCrossCheck.resolve(primary: "the lines", alternatives: ["the line"]).status == .agreed)
    }

    @Test func untonedAgreementIsNotAConflict() {
        #expect(ReadingCrossCheck.resolve(primary: "农夫 nóng fu", alternatives: ["农夫 nong fu"]).status == .agreed)
    }

    @Test func punctuationStaysAttachedWhileTheWordIsCorrected() {
        let outcome = ReadingCrossCheck.resolve(primary: "农夫 none? fu", alternatives: ["农夫 nong? fu"])
        #expect(outcome.status == .corrected && outcome.text == "农夫 nong? fu")
        let quoted = ReadingCrossCheck.resolve(primary: "农夫 (none) fu", alternatives: ["农夫 (nong) fu"])
        #expect(quoted.text == "农夫 (nong) fu")
    }

    @Test func englishWordsThatAreAlsoPinyinAreNotFlagged() {
        // After the Hanzi's Pinyin is complete, "he" vs "me" is plain English, not a Pinyin disagreement.
        let outcome = ReadingCrossCheck.resolve(primary: "农夫 nong fu he", alternatives: ["农夫 nong fu me"])
        #expect(outcome.status == .agreed)
    }

    @Test func linesThatDontLineUpAreIgnoredNotFlagged() {
        // A recognizer's other candidate lines (different Hanzi or word count) say nothing about this line.
        #expect(ReadingCrossCheck.resolve(primary: "好", alternatives: ["女子", "好 hao"]).status == .agreed)
        let line = RecognizedLine(text: "好", bounds: .zero, readings: ["好", "女子"]).crossChecked()
        #expect(!line.needsReview && !line.inkEditSuppressed)
    }

    @Test func singleAlternativeIsEnough() {
        let outcome = ReadingCrossCheck.resolve(primary: "农夫 none fu", alternatives: ["农夫 nong fu"])
        #expect(outcome.text == "农夫 nong fu")
        #expect(outcome.status == .corrected)
        #expect(outcome.note?.contains("ink is unchanged") == true)
    }

    @Test func englishIsNeverChanged() {
        let outcome = ReadingCrossCheck.resolve(primary: "农夫 none fu farmers market", alternatives: ["农夫 nong fu farmer markets"])
        #expect(outcome.status == .corrected)
        #expect(outcome.text == "农夫 nong fu farmers market")
    }

    @Test func agreeingReadingsChangeNothing() {
        let outcome = ReadingCrossCheck.resolve(primary: "农夫 nong fu", alternatives: ["农夫 nong fu"])
        #expect(outcome == .init(text: "农夫 nong fu", status: .agreed, note: nil))
        #expect(ReadingCrossCheck.resolve(primary: "农夫 nong fu", alternatives: []).status == .agreed)
    }

    @Test func disagreementWithoutHanziContextStaysUnresolved() {
        let outcome = ReadingCrossCheck.resolve(primary: "none fu", alternatives: ["nong fu"])
        #expect(outcome.status == .unresolved)
        #expect(outcome.text == "none fu")
        #expect(outcome.note?.contains("check it") == true)
    }

    @Test func alternativeThatDoesNotFitTheHanziIsNotUsed() {
        // 农夫 romanizes to nongfu; "nang" is valid Pinyin but doesn't fit, so nothing is corrected.
        let outcome = ReadingCrossCheck.resolve(primary: "农夫 none fu", alternatives: ["农夫 nang fu"])
        #expect(outcome.status == .unresolved)
        #expect(outcome.text == "农夫 none fu")
    }

    @Test func sameLettersWithDifferentTonesIsOneFittingReading() {
        let outcome = ReadingCrossCheck.resolve(primary: "好像 hao xaing", alternatives: ["好像 hao xiang", "好像 hao xiàng"])
        #expect(outcome.status == .corrected)
        #expect(outcome.text == "好像 hao xiàng")
    }

    @Test func readingsThatDisagreeOnHanziAreNotAligned() {
        // A reading with different Hanzi can't be aligned word by word, so it changes nothing (and isn't a Pinyin disagreement).
        let outcome = ReadingCrossCheck.resolve(primary: "农夫 none fu", alternatives: ["衣夫 nong fu"])
        #expect(outcome.status == .agreed)
        #expect(outcome.text == "农夫 none fu")
    }

    @Test func secondOpinionIsOnlyAskedForHanziWithANonPinyinWord() {
        #expect(ReadingCrossCheck.wantsSecondOpinion("农夫 none fu"))
        #expect(ReadingCrossCheck.wantsSecondOpinion("农夫 farmers"))
        #expect(!ReadingCrossCheck.wantsSecondOpinion("农夫 nong fu"))
        #expect(!ReadingCrossCheck.wantsSecondOpinion("none fu"))
        #expect(!ReadingCrossCheck.wantsSecondOpinion("农夫"))
    }

    // MARK: - Lines, cards and ink

    @Test func correctedLineKeepsRawTextAndSuppressesInkEdit() {
        let line = RecognizedLine(text: "农夫 none fu", bounds: CGRect(x: 0, y: 0, width: 100, height: 40), alternatives: ["农夫 nong fu"]).crossChecked()
        #expect(line.text == "农夫 nong fu")
        #expect(line.rawText == "农夫 none fu")
        #expect(line.inkEditSuppressed && !line.needsReview)
    }

    @Test func unresolvedLineIsFlaggedForReviewAndKeptAsRead() {
        let line = RecognizedLine(text: "none fu", bounds: CGRect(x: 0, y: 0, width: 100, height: 40), alternatives: ["nong fu"]).crossChecked()
        #expect(line.text == "none fu" && line.needsReview && line.inkEditSuppressed)
    }

    @Test func cardDraftUsesTheCorrectedPinyinNotNone() throws {
        let line = RecognizedLine(text: "农夫 none fu farmer", bounds: .zero, alternatives: ["农夫 nong fu farmer"]).crossChecked()
        let draft = try #require(FlashcardExtractor.extract(from: line.text))
        #expect(draft.front == "农夫")
        #expect(draft.back.contains("nong fu"))
        #expect(!draft.back.contains("none"))
        #expect(draft.back.contains("farmer"))
    }

    @Test func uncorrectedNoneNeverReachesAnInkReplacement() {
        let line = RecognizedLine(text: "农夫 none fu", bounds: .zero, alternatives: ["农夫 nong fu"]).crossChecked()
        let proposal = StarterVocabulary.standard.proposal(forRecognizedText: "农夫市集")!
        let pending = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: line.text, proposal: proposal,
                                        readingNote: line.reviewNote, inkEditSuppressed: line.inkEditSuppressed)
        #expect(pending.uncertaintyNote != nil)
        #expect(pending.uncertaintyNote?.contains("Pinyin corrected") == true)
    }
}
