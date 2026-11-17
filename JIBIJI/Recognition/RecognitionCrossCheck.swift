import CoreGraphics
import Foundation

/// Compare readings of the same ink before suggestions or card extraction. Only an observed
/// Pinyin reading supported by the written Hanzi can replace transcription; English stays intact.
enum RecognitionCrossCheck {
    static func resolve(_ lines: [RecognizedLine], vocabulary: StarterVocabulary = .standard) -> [RecognizedLine] {
        joinedRegions(lines).map { resolve($0, vocabulary: vocabulary) }
    }

    private static func resolve(_ line: RecognizedLine, vocabulary: StarterVocabulary) -> RecognizedLine {
        var result = line
        let readings = unique([line.text] + line.readings)
        guard let term = StarterVocabulary.hanziRuns(in: line.text).first,
              line.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(term),
              StarterVocabulary.hanziRuns(in: line.text) == [term] else {
            result.readingNeedsReview = result.readingNeedsReview || readings.count > 1
            return result
        }
        // The vocabulary handles known senses; ICU is only a spelling/tones comparison for others.
        let pronunciation = vocabulary.entries.first { $0.hanzi == term }?.pinyin
            ?? term.applyingTransform(.mandarinToLatin, reverse: false) ?? ""
        let expected = letters(pronunciation)
        guard !expected.isEmpty else { return result }
        result.pinyinReadingConfirmed = result.pinyinReadingConfirmed
            || pinyinWordCount(in: line.text, term: term, pronunciation: pronunciation) != nil
        guard readings.count > 1 else { return result }
        let primaryWords = words(after: term, in: line.text)
        let supported = readings.compactMap { text -> String? in
            guard StarterVocabulary.hanziRuns(in: text) == [term],
                  let count = pinyinWordCount(in: text, term: term, pronunciation: pronunciation),
                  let candidateWords = words(after: term, in: text),
                  let primaryWords, primaryWords.count >= count,
                  candidateWords.dropFirst(count).joined(separator: " ") == primaryWords.dropFirst(count).joined(separator: " ")
            else { return nil }
            return text
        }
        guard let chosen = supported.first,
              let count = pinyinWordCount(in: chosen, term: term, pronunciation: pronunciation) else {
            result.readingNeedsReview = true
            return result
        }
        let unresolved = readings.contains { text in
            guard StarterVocabulary.hanziRuns(in: text) == [term],
                  let words = words(after: term, in: text), words.count >= count,
                  let primaryWords else { return true }
            return words.dropFirst(count).joined(separator: " ") != primaryWords.dropFirst(count).joined(separator: " ")
        }
        result.readingNeedsReview = result.readingNeedsReview || unresolved
        result.pinyinReadingConfirmed = true
        // If the primary spelling and any explicit tones already agree, keep them exactly as read.
        if pinyinWordCount(in: line.text, term: term, pronunciation: pronunciation) != nil { return result }
        result.sourceText = line.rawText
        result.text = chosen
        result.pinyinTranscriptionCorrected = true
        return result
    }

    static func pinyinAgrees(_ observed: String, with expected: String) -> Bool {
        letters(observed) == letters(expected) && tonesAgree(observed, expected)
    }

    private static func words(after term: String, in text: String) -> [String]? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(term) else { return nil }
        return text.dropFirst(term.count).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func pinyinWordCount(in text: String, term: String, pronunciation: String) -> Int? {
        guard let words = words(after: term, in: text) else { return nil }
        let expected = letters(pronunciation)
        var accumulated = ""
        for (index, word) in words.enumerated() {
            guard word.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0) || $0 == "'" || $0 == "’" }) else { return nil }
            accumulated += word
            let observed = letters(accumulated)
            if observed == expected {
                return tonesAgree(accumulated, pronunciation) ? index + 1 : nil
            }
            if !expected.hasPrefix(observed) { return nil }
        }
        return nil
    }

    private static func letters(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isASCII && $0.isLetter }
    }

    /// Unmarked vowels are allowed. Explicit tones and ü must agree; never normalize a wrong tone away.
    private static func tonesAgree(_ observed: String, _ expected: String) -> Bool {
        func characters(_ text: String) -> [Character] { Array(text.lowercased().filter(\.isLetter)) }
        let actual = characters(observed.precomposedStringWithCanonicalMapping)
        let reference = characters(expected.precomposedStringWithCanonicalMapping)
        guard actual.count == reference.count else { return false }
        return zip(actual, reference).allSatisfy { a, b in
            if String(b).decomposedStringWithCanonicalMapping.unicodeScalars.contains(where: { $0.value == 0x0308 }) {
                return String(a).decomposedStringWithCanonicalMapping.unicodeScalars.contains(where: { $0.value == 0x0308 }) && (a == "ü" || a == b)
            }
            return a.isASCII || a == b
        }
    }

    /// OCR can split Hanzi, Pinyin and English into separate boxes. Join only a Hanzi-only
    /// box and nearby Latin boxes on its right on the same row, never a second Hanzi entry.
    private static func joinedRegions(_ input: [RecognizedLine]) -> [RecognizedLine] {
        var output: [RecognizedLine] = []
        var used = Set<Int>()
        for index in input.indices.sorted(by: { input[$0].bounds.minX < input[$1].bounds.minX }) {
            guard !used.contains(index) else { continue }
            var line = input[index]
            let term = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, StarterVocabulary.hanzi(in: term) == term,
                  !line.bounds.isEmpty else { output.append(line); continue }
            let neighbors = input.indices.filter { other in
                guard other != index, !used.contains(other) else { return false }
                let box = input[other].bounds
                return !box.isEmpty && box.minX >= line.bounds.maxX - 3
                    && abs(box.midY - line.bounds.midY) <= max(box.height, line.bounds.height) * 0.6
            }.sorted { input[$0].bounds.minX < input[$1].bounds.minX }
            for other in neighbors {
                let next = input[other]
                guard StarterVocabulary.hanzi(in: next.text).isEmpty,
                      next.text.contains(where: \.isLetter),
                      next.bounds.minX - line.bounds.maxX <= max(120, line.bounds.height * 3) else { break }
                let primary = "\(line.text) \(next.text)"
                let readings = unique([primary]
                    + unique([line.text] + line.readings).map { "\($0) \(next.text)" }
                    + unique([next.text] + next.readings).map { "\(line.text) \($0)" })
                line.sourceText = line.sourceText != nil || next.sourceText != nil ? "\(line.rawText) \(next.rawText)" : nil
                line.text = primary
                line.readings = Array(readings.prefix(12))
                line.bounds = line.bounds.union(next.bounds)
                line.readingNeedsReview = line.readingNeedsReview || next.readingNeedsReview
                used.insert(other)
            }
            output.append(line)
        }
        return output
    }

    private static func unique(_ texts: [String]) -> [String] {
        var seen = Set<String>()
        return texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
