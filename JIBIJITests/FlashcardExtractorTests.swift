import XCTest
@testable import JIBIJI

final class FlashcardExtractorTests: XCTestCase {
    func testTermPinyinGlossNormalizesToneAndPreservesUnclearGloss() throws {
        let d = try XCTUnwrap(FlashcardExtractor.extract(from: "负责fu ze responsible?"))
        XCTAssertEqual(d.front, "负责")
        XCTAssertEqual(d.back, "fùzé — responsible?")
        XCTAssertEqual(d.kind, .vocabulary)
        XCTAssertTrue(d.needsReview)
        XCTAssertEqual(d.sourceText, "负责fu ze responsible?")
    }

    func testGroundedGlossNeedsNoReview() throws {
        let d = try XCTUnwrap(FlashcardExtractor.extract(from: "复习 fuxi to review"))
        XCTAssertEqual(d.back, "fùxí — to review")
        XCTAssertFalse(d.needsReview)
    }

    func testStarterGlossUsedOnlyWhenMatched() throws {
        XCTAssertEqual(FlashcardExtractor.extract(from: "预习 yuxi")?.back, "yùxí — to prepare a lesson in advance")
        XCTAssertNil(FlashcardExtractor.extract(from: "桌子"))
    }

    func testUnknownTermKeepsObservedAndReviews() throws {
        let d = try XCTUnwrap(FlashcardExtractor.extract(from: "桌子 zhuo zi table"))
        XCTAssertEqual(d.back, "zhuo zi — table")
        XCTAssertTrue(d.needsReview)
    }

    func testUnknownTermToneMarkedSingleWordMatchesHint() throws {
        let d = try XCTUnwrap(FlashcardExtractor.extract(from: "桌子 zhuōzi table"))
        XCTAssertEqual(d.back, "zhuōzi — table")
        XCTAssertTrue(d.needsReview)
    }

    func testUnknownTermDoesNotTreatEnglishWordsAsPinyin() throws {
        let d = try XCTUnwrap(FlashcardExtractor.extract(from: "桌子 the table"))
        XCTAssertEqual(d.back, "the table")
        XCTAssertTrue(d.needsReview)
        let short = try XCTUnwrap(FlashcardExtractor.extract(from: "桌子 the"))
        XCTAssertEqual(short.back, "the")
        XCTAssertTrue(short.needsReview)
        XCTAssertNil(FlashcardExtractor.extract(from: "桌子 zhuo zi"), "pinyin only: no meaning is invented")
    }

    func testUnlabeledIdiomKeepsExactUsage() throws {
        let d = try XCTUnwrap(FlashcardExtractor.extract(from: "虎头蛇尾 Used for a strong start, weak finish"))
        XCTAssertEqual(d.kind, .idiom)
        XCTAssertEqual(d.front, "虎头蛇尾")
        XCTAssertEqual(d.back, "Used for a strong start, weak finish")
        XCTAssertNil(FlashcardExtractor.extract(from: "虎头蛇尾"))
    }

    func testUnlabeledArrowRelationNeedsReviewAndStaysOnLine() throws {
        let d = try XCTUnwrap(FlashcardExtractor.extract(from: "预 → 豫"))
        XCTAssertEqual(d.kind, .component)
        XCTAssertEqual(d.front, "预")
        XCTAssertEqual(d.back, "豫")
        XCTAssertTrue(d.needsReview)
        XCTAssertNil(FlashcardExtractor.extract(from: "预 →"))
    }

    func testClassicalEquation() throws {
        let d = try XCTUnwrap(FlashcardExtractor.extract(from: "与 = 和 (古汉语)"))
        XCTAssertEqual(d.kind, .classical)
        XCTAssertEqual(d.front, "与")
        XCTAssertEqual(d.back, "= 和 (古汉语)")
    }

    func testGrammarWithExample() throws {
        let d = try XCTUnwrap(FlashcardExtractor.extract(from: "虽然…但是… 虽然累，但是很开心"))
        XCTAssertEqual(d.kind, .grammar)
        XCTAssertEqual(d.front, "虽然…但是…")
        XCTAssertEqual(d.back, "although … but\nExample: 虽然累，但是很开心")
        XCTAssertFalse(d.needsReview)
        XCTAssertTrue(try XCTUnwrap(FlashcardExtractor.extract(from: "虽然…但是…")).needsReview)
    }

    func testLabeledForms() throws {
        let idiom = try XCTUnwrap(FlashcardExtractor.extract(from: "成语: 虎头蛇尾 strong start, weak finish"))
        XCTAssertEqual(idiom.kind, .idiom)
        XCTAssertEqual(idiom.front, "虎头蛇尾")
        XCTAssertEqual(idiom.back, "strong start, weak finish")
        XCTAssertEqual(FlashcardExtractor.extract(from: "例: 我负责这个 = I am in charge")?.kind, .example)
        let comp = try XCTUnwrap(FlashcardExtractor.extract(from: "component: 预 → 豫"))
        XCTAssertEqual(comp.kind, .component)
        XCTAssertEqual(comp.back, "豫")
    }

    func testAbstains() {
        XCTAssertNil(FlashcardExtractor.extract(from: ""))
        XCTAssertNil(FlashcardExtractor.extract(from: "hello there"))
        XCTAssertNil(FlashcardExtractor.extract(from: "负"))
        XCTAssertNil(FlashcardExtractor.extract(from: "component: 预"))
    }
}
