#if DEBUG
import Foundation
import Testing
@testable import JIBIJI

/// Pure matcher/routing tests: no recognizer, model or PencilKit availability needed.
@Suite("Pinyin context routing")
struct PinyinContextRoutingTests {
    @Test(arguments: ["fuze", "fu ze", "fù zé", "FÙ ZÉ", "fu'ze", "fu’ ze"])
    func matchesIgnoringSpacesTonesApostrophesAndCase(_ latin: String) {
        #expect(PinyinContextHint.matches(hanzi: "负责", latin: latin))
    }

    @Test(arguments: ["responsible for", "hello", "the"])
    func unrelatedEnglishDoesNotMatch(_ latin: String) {
        #expect(!PinyinContextHint.matches(hanzi: "负责", latin: latin))
    }

    @Test(arguments: ["fu ji", "fuzei", "fu", "ze fu"])
    func wrongSyllablesDoNotMatch(_ latin: String) {
        #expect(!PinyinContextHint.matches(hanzi: "负责", latin: latin))
    }

    @Test(arguments: ["fu2ze", "fu-ze", "fu ze?", "fu ze 负责", "12", "--", "f", "", "   ", "fu_ze"])
    func rejectsNumericPunctuationMixedAndTooShort(_ latin: String) {
        #expect(!PinyinContextHint.matches(hanzi: "负责", latin: latin))
        #expect(PinyinContextHint.latinLetters(latin) == nil)
    }

    @Test(arguments: ["负责 ", "银行", "负"])
    func acceptsShortHanziOnly(_ hanzi: String) {
        #expect(PinyinContextHint.hanziOnly(hanzi) != nil)
    }

    @Test(arguments: ["", "fu", "负责1", "负 责!", "负责abc", "一二三四五六七"])
    func rejectsNonHanziOrLong(_ text: String) {
        #expect(PinyinContextHint.hanziOnly(text) == nil)
        #expect(!PinyinContextHint.matches(hanzi: text, latin: "fuze"))
    }

    @Test func routesOnlyTheMatchedAdjacentLatinRegion() {
        let decisions = PinyinContextRouting.decisions(pencilTexts: ["负责", "fù zé", "responsible for"])
        #expect(decisions.map(\.routed) == [true, false])
        #expect(decisions.map(\.region) == [1, 2])
    }

    @Test func abstainsWhenNothingMatches() {
        for texts: [String?] in [["负责", "hello"], ["负责", "fu ji"], ["负责", nil], [nil, "fuze"], ["fuze", "负责"], ["负责", "fuze 1"], ["负责"], []] {
            let decisions = PinyinContextRouting.decisions(pencilTexts: texts)
            let noneRouted = decisions.allSatisfy { !$0.routed }
            #expect(noneRouted, "\(texts)")
        }
    }

    @Test func polyphonicAmbiguityAbstainsInsteadOfGuessing() {
        // Han-Latin reads 银行 as "yin xing"; a writer's "yin hang" must not route.
        let decisions = PinyinContextRouting.decisions(pencilTexts: ["银行", "yin hang"])
        let anyRouted = decisions.contains(where: { $0.routed })
        #expect(!anyRouted)
    }

    @Test func decisionsExplainWithoutEmittingGeneratedTones() {
        let decisions = PinyinContextRouting.decisions(pencilTexts: ["负责", "fuze"])
        #expect(decisions.count == 1)
        #expect(decisions[0].reason.contains("routed to Paddle"))
        #expect(!decisions[0].reason.contains("fù"))
        #expect(!decisions[0].reason.contains("zé"))
    }
}
#endif
