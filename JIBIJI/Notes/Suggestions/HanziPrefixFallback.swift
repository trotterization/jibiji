import Foundation
import PencilKit

/// Narrow, DEBUG-only second opinion for one written line. When PencilKit read a strict Hanzi prefix of a
/// starter entry (e.g. 好 of 好像) but the vocabulary gives no suggestion, the local Paddle mobile model may
/// re-read the same line's strokes. Its text is used only if it keeps the same written Hanzi and the
/// vocabulary then matches exactly. Never touches ink; release builds never run it.
enum HanziPrefixFallback {
    /// The written prefix that makes `primary` eligible, or nil. Eligible: exactly one Han run, a strict
    /// prefix of some entry's Hanzi, and the vocabulary offers nothing for the text as read.
    static func eligiblePrefix(primary: String, vocabulary: StarterVocabulary = .standard) -> String? {
        let runs = StarterVocabulary.hanziRuns(in: primary)
        guard runs.count == 1, vocabulary.entries.contains(where: { $0.hanzi.count > runs[0].count && $0.hanzi.hasPrefix(runs[0]) }),
              vocabulary.proposal(forRecognizedText: primary) == nil else { return nil }
        return runs[0]
    }

    /// Whether `fallback` may replace `primary`: same single written Hanzi run, one line, and an exact
    /// vocabulary match that recognizes that run as a written prefix.
    static func accepts(fallback: String, primary: String, vocabulary: StarterVocabulary = .standard) -> Bool {
        guard let prefix = eligiblePrefix(primary: primary, vocabulary: vocabulary),
              !fallback.contains(where: \.isNewline),
              StarterVocabulary.hanziRuns(in: fallback) == [prefix],
              let proposal = vocabulary.proposal(forRecognizedText: fallback),
              proposal.hanziPrefixWritten == prefix, !proposal.hanziAlreadyWritten else { return false }
        return true
    }

    /// The text to use for this line: the fallback when allowed, otherwise `primary` unchanged.
    static func resolve(primary: String, strokes: [PKStroke]) async -> String {
        #if DEBUG
        guard eligiblePrefix(primary: primary) != nil else { return primary }
        let result = await PinyinOCR.shared.recognizeMobile(PKDrawing(strokes: strokes))
        guard let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              accepts(fallback: text, primary: primary) else {
            print("HanziPrefixFallback: kept PencilKit \"\(primary)\"; Paddle gave \(result.text.map { "\"\($0)\"" } ?? "nothing")")
            return primary
        }
        print("HanziPrefixFallback: PencilKit \"\(primary)\" -> Paddle \"\(text)\"")
        return text
        #else
        return primary
        #endif
    }
}
