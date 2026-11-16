import Foundation
import PencilKit
import Testing
@testable import JIBIJI

@Suite("Hanzi-prefix fallback matcher")
struct HanziPrefixFallbackMatcherTests {
    @Test func eligibleOnlyForStrictKnownPrefixWithNoSuggestion() {
        #expect(HanziPrefixFallback.eligiblePrefix(primary: "好") == "好")
        #expect(HanziPrefixFallback.eligiblePrefix(primary: "好 hao xiang") == nil) // already suggests
        #expect(HanziPrefixFallback.eligiblePrefix(primary: "好像") == nil)         // not a strict prefix
        #expect(HanziPrefixFallback.eligiblePrefix(primary: "hǎo xiang") == nil)    // no Hanzi
        #expect(HanziPrefixFallback.eligiblePrefix(primary: "你") == nil)           // unknown
    }

    @Test func acceptsOnlyExactSafeMatchKeepingTheSameHanzi() throws {
        #expect(HanziPrefixFallback.accepts(fallback: "好 hǎo xiang", primary: "好"))
        #expect(!HanziPrefixFallback.accepts(fallback: "hǎo xiang", primary: "好"))      // prefix lost
        #expect(!HanziPrefixFallback.accepts(fallback: "你 hǎo xiang", primary: "好"))   // different Hanzi
        #expect(!HanziPrefixFallback.accepts(fallback: "好 hǎo\nxiang", primary: "好"))  // multi-line
        #expect(!HanziPrefixFallback.accepts(fallback: "好 hao xiang to eat", primary: "好")) // gloss mismatch
        let proposal = try #require(StarterVocabulary.standard.proposal(forRecognizedText: "好 hǎo xiang"))
        #expect(proposal.candidates[0].hanzi == "好像")
        #expect(proposal.hanziPrefixWritten == "好")
    }
}

private final class HaoReplayBundleAnchor {}

private var haoReplayFixtureURL: URL? {
    Bundle(for: HaoReplayBundleAnchor.self).url(forResource: "LocalPinyinReplay", withExtension: "drawing")
}

private var haoReplayRequested: Bool {
    ProcessInfo.processInfo.environment["JIBIJI_HAO_REPLAY"] == "1"
}

@MainActor
@Suite("Local 好像 replay (opt-in)")
struct HaoXiangReplayTests {
    static let expectedStrokeCount = 16

    @available(iOS 27.0, *)
    @Test(.enabled(if: haoReplayRequested && haoReplayFixtureURL != nil))
    func replayReportsPencilKitAndFallback() async throws {
        let fixture = try #require(haoReplayFixtureURL)
        let drawing = try PKDrawing(data: Data(contentsOf: fixture))
        try #require(drawing.strokes.count == Self.expectedStrokeCount,
                     "Fixture has \(drawing.strokes.count) strokes, expected \(Self.expectedStrokeCount).")
        let original = drawing.dataRepresentation()

        let raw = try await PencilInkLineReader(mode: .primaryOnly).lines(in: drawing)
        print("HAO replay PencilKit raw: \(raw.map(\.text))")
        let withFallback = try await PencilInkLineReader().lines(in: drawing)
        print("HAO replay with fallback: \(withFallback.map(\.text))")
        #expect(drawing.dataRepresentation() == original)

        #if DEBUG
        let paddle = await PinyinOCR.shared.recognizeMobile(drawing)
        print("HAO replay Paddle full output:\n\(paddle.lines.joined(separator: "\n"))")
        if let paddleText = paddle.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           StarterVocabulary.hanziRuns(in: paddleText).contains("好") {
            // Native Paddle read the 好 line, so its exact output must satisfy the safe matcher.
            #expect(HanziPrefixFallback.accepts(fallback: paddleText, primary: "好"),
                    "Paddle read \"\(paddleText)\" but the matcher rejected it.")
        } else {
            print("HAO replay: Paddle did not recognize the 好 line; matcher not asserted.")
        }
        #endif

        guard raw.contains(where: { StarterVocabulary.hanziRuns(in: $0.text).contains("好") }) else {
            print("HAO replay: simulator PencilKit gave no 好; physical device result still pending.")
            return
        }
        let line = try #require(withFallback.first { $0.text.contains("好") })
        let proposal = try #require(StarterVocabulary.standard.proposal(forRecognizedText: line.text),
                                    "No suggestion from \"\(line.text)\"")
        #expect(proposal.hanziPrefixWritten == "好")
        #expect(proposal.candidates[0].gloss == "to seem like; to look like")
        #expect(proposal.candidates[0].hanzi.dropFirst(proposal.hanziPrefixWritten.count) == "像")
    }
}
