import Foundation
import PencilKit
import Testing
import UIKit
import Vision
@testable import JIBIJI

/// Production Chinese fallback coverage plus baseline Vision diagnostics.
/// Local replay files remain gitignored and never leave the developer machine.
@Suite("Vision text recognition fallback", .timeLimit(.minutes(1)))
struct RecognitionFallbackTests {
    static let languages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")]

    @Test func visionSupportsSimplifiedChinese() {
        let supported = RecognizeTextRequest().supportedRecognitionLanguages.map(\.maximalIdentifier)
        print("Vision RecognizeTextRequest languages (\(supported.count)): \(supported.joined(separator: ", "))")

        #expect(supported.contains { $0.hasPrefix("zh-Hans") })
    }

    @Test(arguments: ["大人", "十三", "一二三"])
    func visionReadsRenderedSyntheticInk(_ text: String) async throws {
        let image = try #require(Self.render(SyntheticInk.drawing(writing: text)))
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = Self.languages
        request.usesLanguageCorrection = false

        let clock = ContinuousClock()
        let start = clock.now
        let observations = try await request.perform(on: image)
        let elapsed = start.duration(to: clock.now)
        let read = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        print("Vision synthetic \"\(text)\" → \"\(read)\" in \(RecognitionReport.format(elapsed))")
    }

    @Test func productionReaderRecognizesChineseAndCachesUnchangedInk() async throws {
        let drawing = SyntheticInk.drawing(writing: "大人")
        let reader = VisionInkReader()
        let first = try await reader.lines(in: drawing)
        #expect(first.contains { !StarterVocabulary.hanzi(in: $0.text).isEmpty })
        #expect(first.allSatisfy { !$0.readings.isEmpty && $0.bounds.width > 0 && $0.bounds.height > 0 })
        let cached = try await reader.lines(in: drawing)
        #expect(cached == first)
        #expect(try await reader.lines(in: PKDrawing()).isEmpty)
    }

    @Test(.enabled(if: Bundle(for: ReplayBundleAnchor.self).url(forResource: "LocalPinyinReplay", withExtension: "drawing") != nil))
    func productionReaderReplaysLocalInk() async throws {
        let url = try #require(Bundle(for: ReplayBundleAnchor.self).url(forResource: "LocalPinyinReplay", withExtension: "drawing"))
        let drawing = try PKDrawing(data: Data(contentsOf: url))
        let clock = ContinuousClock()
        let start = clock.now
        let reader = VisionInkReader()
        let lines = try await reader.lines(in: drawing)
        print("Production OCR replay: \(lines.map { $0.readings }) in \(clock.now - start)")
        #expect(!lines.isEmpty)
        #expect(lines.contains { !StarterVocabulary.hanzi(in: $0.text).isEmpty })
        let cachedStart = clock.now
        #expect(try await reader.lines(in: drawing) == lines)
        print("Cached replay: \(clock.now - cachedStart)")
    }

    /// Black ink on white, the way the page looks in light mode.
    static func render(_ drawing: PKDrawing, scale: CGFloat = 2) -> CGImage? {
        let rect = drawing.bounds.insetBy(dx: -24, dy: -24)
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: rect, scale: scale)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: rect.size))
            ink.draw(at: .zero)
        }.cgImage
    }
}

#if DEBUG
/// Standalone Pinyin OCR experiment: CTC decoding and input preparation, plus an opt-in run of the
/// locally staged model (skipped when the model isn't in the app bundle).
@Suite("Standalone Pinyin OCR")
struct PinyinOCRTests {
    /// Class 0 is the blank; entries 1... are the dictionary. "ǐ" and "ǎ" are letter + combining mark.
    static let dictionary = ["n", "i\u{030C}", " ", "h", "a\u{030C}", "o"]

    /// One-hot logits, one row per step, over blank + dictionary + the appended space class.
    static func logits(for classes: [Int]) -> [Float] {
        let width = dictionary.count + 2
        return classes.flatMap { c in (0..<width).map { $0 == c ? Float(1) : 0 } }
    }

    @Test func accentedRoundTripKeepsMultiCodepointEntriesAndReturnsNFC() {
        // n, ǐ, blank, " " (appended class), h, ǎ, o; repeats collapse and a blank separates real repeats.
        let steps = [1, 1, 2, 0, 7, 4, 4, 5, 0, 6]
        let text = PinyinCTC.decode(logits: Self.logits(for: steps), steps: steps.count, classes: Self.dictionary.count + 2, dictionary: Self.dictionary)

        #expect(text == "nǐ hǎo")
        #expect(text.unicodeScalars.count == "nǐ hǎo".precomposedStringWithCanonicalMapping.unicodeScalars.count)
    }

    @Test func blankSeparatesRepeatedClasses() {
        let steps = [1, 0, 1]
        let text = PinyinCTC.decode(logits: Self.logits(for: steps), steps: 3, classes: Self.dictionary.count + 2, dictionary: Self.dictionary)

        #expect(text == "nn")
    }

    @Test func inputIsFixedHeightPaddedAndNormalized() throws {
        let line = SyntheticInk.stroke(through: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10), CGPoint(x: 60, y: 40)])
        let input = try #require(PinyinPreprocessor.input(for: PKDrawing(strokes: [line])))

        #expect(input.tensorWidth >= PinyinPreprocessor.minWidth)
        #expect(input.tensor.count == 3 * PinyinPreprocessor.height * input.tensorWidth)
        #expect(input.tensor.allSatisfy { (-1...1).contains($0) })
        // Zero padding on the right edge of every row.
        #expect(input.tensor[input.tensorWidth - 1] == 0)
    }

    @Test func emptyDrawingIsGraceful() async {
        #expect(PinyinPreprocessor.input(for: PKDrawing()) == nil)
        #expect(await PinyinOCR.shared.recognize(PKDrawing()) == .empty)
    }

    @Test(.enabled(if: Bundle.main.url(forResource: "PinyinRecognition", withExtension: "onnx") != nil))
    func stagedModelRunsOnSyntheticInk() async throws {
        let line = SyntheticInk.stroke(through: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10), CGPoint(x: 60, y: 40)])
        let result = await PinyinOCR.shared.recognize(PKDrawing(strokes: [line]))

        // A single stroke is one line, so the old single-line path is used.
        guard case .recognized(let text, let elapsed, _, _, _) = result else {
            Issue.record("Expected a recognized result, got \(result)")
            return
        }
        print("Pinyin OCR synthetic stroke → \"\(text)\" in \(RecognitionReport.format(elapsed))")
    }

    @Test func cleanupDropsOnlyAnIsolatedSpeckBelowTheWriting() {
        let line = SyntheticInk.stroke(through: [CGPoint(x: 200, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 140)])
        // Single-point, 1 pt wide dots: the rendered bounds must stay under the speck threshold.
        let farBelow = SyntheticInk.stroke(through: [CGPoint(x: 60, y: 240)], width: 1)
        let farAbove = SyntheticInk.stroke(through: [CGPoint(x: 60, y: -80)], width: 1)
        let nearBelow = SyntheticInk.stroke(through: [CGPoint(x: 250, y: 150)], width: 1)

        for (name, speck) in [("farBelow", farBelow), ("farAbove", farAbove), ("nearBelow", nearBelow)] {
            let size = max(speck.renderBounds.width, speck.renderBounds.height)
            #expect(size < PinyinPreprocessor.speckMaxSize, "\(name) renders \(size) pt, over the speck threshold")
        }

        #expect(PinyinPreprocessor.isolatedSpeckIndices(in: PKDrawing(strokes: [line, farBelow])) == [1])
        #expect(PinyinPreprocessor.isolatedSpeckIndices(in: PKDrawing(strokes: [line, farAbove])).isEmpty)
        #expect(PinyinPreprocessor.isolatedSpeckIndices(in: PKDrawing(strokes: [line, nearBelow])).isEmpty)
        #expect(PinyinPreprocessor.isolatedSpeckIndices(in: PKDrawing(strokes: [line])).isEmpty)
    }

    /// Two synthetic rows of different heights with detached accents, plus a stray point between them.
    @Test func twoLinesWithDetachedAccentsAndAStrayPointSplitCleanly() {
        func bar(_ x: CGFloat, _ top: CGFloat, _ bottom: CGFloat) -> PKStroke {
            SyntheticInk.stroke(through: [CGPoint(x: x, y: top), CGPoint(x: x, y: bottom)])
        }
        func dot(_ x: CGFloat, _ y: CGFloat) -> PKStroke { SyntheticInk.stroke(through: [CGPoint(x: x, y: y)], width: 1) }

        // Upper row, bodies y 220..270 (50 pt) with accents detached 12-20 pt above, y 192..206.
        let upper = (0..<4).flatMap { k -> [PKStroke] in
            let x = 300 + CGFloat(k) * 60
            return [bar(x, 220, 270), bar(x + 20, 220, 270), bar(x + 8, 192, 206)]
        }
        // Lower row, shorter bodies y 400..440 (40 pt), accent at y 362.
        let lower = [bar(300, 400, 440), bar(320, 400, 440), bar(310, 362, 376)]
        let stray = dot(124, 349)
        let tinyAccentDot = dot(340, 385) // tiny, close to the lower row's ink

        // Source order is interleaved on purpose: lower row first, stray in the middle.
        let strokes = lower + [stray] + upper + [tinyAccentDot]
        let drawing = PKDrawing(strokes: strokes)
        let groups = PinyinPreprocessor.lineGroups(in: drawing)

        #expect(groups.count == 2)
        // Top to bottom: the upper row (source indices 4...15) is first.
        #expect(groups[0] == Array(4...15))
        // Lower row, the tiny dot near it, and the stray point (closest to the lower row) go to line 2, in source order.
        #expect(groups[1] == [0, 1, 2, 3, 16])
        #expect(Set(groups.flatMap { $0 }).count == strokes.count)

        // Mobile cleanup: the stray point is a far, tiny stroke outside the written extent; the near dot stays.
        #expect(PinyinPreprocessor.isolatedSpeckIndices(in: drawing) == [3])
        let cleaned = PKDrawing(strokes: strokes.enumerated().filter { $0.offset != 3 }.map(\.element))
        #expect(PinyinPreprocessor.lineGroups(in: cleaned) == [Array(3...14), [0, 1, 2, 15]])
    }

    @Test func unclearLinesFallBackToOneLine() {
        func bar(_ x: CGFloat, _ top: CGFloat, _ bottom: CGFloat) -> PKStroke {
            SyntheticInk.stroke(through: [CGPoint(x: x, y: top), CGPoint(x: x, y: bottom)])
        }
        // One continuous line with accent-like gaps well under 1.5 × the body height.
        let oneLine = PKDrawing(strokes: (0..<6).map { bar(100 + CGFloat($0) * 20, 200, 250) } + [bar(110, 170, 185)])
        #expect(PinyinPreprocessor.lineGroups(in: oneLine).count == 1)

        // A lone far stroke is a single-stroke "line": too unsure to split.
        let loner = PKDrawing(strokes: (0..<4).map { bar(100 + CGFloat($0) * 20, 200, 250) } + [bar(100, 500, 550)])
        #expect(PinyinPreprocessor.lineGroups(in: loner).count == 1)

        #expect(PinyinPreprocessor.lineGroups(in: PKDrawing()).count == 1)
    }

    /// Synthetic single line: three clusters separated by wide gaps, one cluster with a narrower inner space.
    @Test func wideHorizontalGapsSplitASingleLineIntoRegions() {
        func bar(_ x: CGFloat) -> PKStroke {
            SyntheticInk.stroke(through: [CGPoint(x: x, y: 200), CGPoint(x: x, y: 250)])
        }
        let dot = SyntheticInk.stroke(through: [CGPoint(x: 362, y: 190)], width: 1)
        // Bodies ~54 pt tall, so the break threshold is ~81 pt. Gaps: ~116 and ~116 between clusters, ~56 inside the middle one.
        let xs: [CGFloat] = [100, 120, 140, 260, 280, 340, 360, 480, 500]
        let strokes = xs.map(bar) + [dot]
        let regions = PinyinPreprocessor.horizontalRegions(in: PKDrawing(strokes: strokes))

        #expect(regions == [[0, 1, 2], [3, 4, 5, 6, 9], [7, 8]])

        let oneLine = PKDrawing(strokes: [100, 120, 140, 160, 180, 200].map(bar))
        #expect(PinyinPreprocessor.horizontalRegions(in: oneLine).isEmpty)
        #expect(PinyinPreprocessor.horizontalRegions(in: PKDrawing()).isEmpty)

        // Two stacked rows are the by-line path's job, not a region split.
        let lower = [100, 120, 400, 420].map { x in SyntheticInk.stroke(through: [CGPoint(x: x, y: 400), CGPoint(x: x, y: 450)]) }
        #expect(PinyinPreprocessor.horizontalRegions(in: PKDrawing(strokes: strokes + lower)).isEmpty)
    }

    /// Opt-in: put your own `LocalPinyinReplay.drawing` (gitignored) in `JIBIJITests/` and run this test to
    /// print what both models read from that exact ink. Set `TEST_RUNNER_JIBIJI_DUMP_REPLAY_PNG=1` to also write
    /// the native full-resolution grayscale crops (raw and cleaned+grown) to the simulator's temp folder.
    @Test(.enabled(if: Bundle(for: ReplayBundleAnchor.self).url(forResource: "LocalPinyinReplay", withExtension: "drawing") != nil))
    func localReplayRunsBothModels() async throws {
        let url = try #require(Bundle(for: ReplayBundleAnchor.self).url(forResource: "LocalPinyinReplay", withExtension: "drawing"))
        let drawing = try PKDrawing(data: Data(contentsOf: url))
        print("Replay: \(drawing.strokes.count) strokes, speck indices \(PinyinPreprocessor.isolatedSpeckIndices(in: drawing).sorted()), line groups \(PinyinPreprocessor.lineGroups(in: drawing))")

        for (label, modelName, result) in [
            ("server (raw)", "PinyinRecognition", await PinyinOCR.shared.recognize(drawing)),
            ("mobile (ink cleanup)", "PinyinMobileRecognition", await PinyinOCR.shared.recognizeMobile(drawing)),
        ] {
            let line = "Replay \(label) → \(result.text.map { "\"\($0)\"" } ?? result.lines.joined(separator: " "))"
            print(line)
            print(result.lines.map { "    " + $0 }.joined(separator: "\n"))
            if Bundle.main.url(forResource: modelName, withExtension: "onnx") != nil {
                #expect(result.text != nil, "\(label) returned no text: \(result.lines.joined(separator: " "))")
            }
        }

        // Context-aware routing: PencilKit per region, Paddle only on a matched Latin region.
        print("Replay regions (index lists): \(PinyinPreprocessor.horizontalRegions(in: drawing))")
        print(await PinyinContextRouting.run(on: drawing).map { "    " + $0 }.joined(separator: "\n"))

        if ProcessInfo.processInfo.environment["JIBIJI_DUMP_REPLAY_PNG"] != nil {
            for (name, cleanup) in [("raw", false), ("cleaned", true)] {
                guard let native = PinyinPreprocessor.nativeGrayscale(for: drawing, cleanup: cleanup),
                      let image = cleanup ? PinyinPreprocessor.grown(native.image) : native.image,
                      let png = UIImage(cgImage: image).pngData() else { continue }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(name).png")
                try png.write(to: file)
                print("Replay PNG (\(name), \(image.width)×\(image.height)): \(file.path)")
            }
        }
    }
}

private final class ReplayBundleAnchor {}
#endif
