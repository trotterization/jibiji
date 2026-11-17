import CoreGraphics
import Foundation

/// Compare readings of the same ink before suggestions or card extraction. Only an observed
/// Pinyin reading supported by the written Hanzi can replace transcription; English stays intact.
enum RecognitionCrossCheck {
    static func resolve(_ lines: [RecognizedLine], vocabulary: StarterVocabulary = .standard) -> [RecognizedLine] {
        joinedRegions(lines).map { $0.crossChecked(vocabulary: vocabulary) }
    }

    static func pinyinAgrees(_ observed: String, with expected: String) -> Bool {
        letters(observed) == letters(expected) && tonesAgree(observed, expected)
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
                    + unique([line.text] + line.readings + line.alternatives).map { "\($0) \(next.text)" }
                    + unique([next.text] + next.readings + next.alternatives).map { "\(line.text) \($0)" })
                line.sourceText = line.sourceText != nil || next.sourceText != nil ? "\(line.rawText) \(next.rawText)" : nil
                line.text = primary
                line.readings = Array(readings.prefix(12))
                line.bounds = line.bounds.union(next.bounds)
                line.needsReview = line.needsReview || next.needsReview
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
