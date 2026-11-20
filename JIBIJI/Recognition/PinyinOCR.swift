#if DEBUG
import CoreGraphics
import Foundation
import OnnxRuntimeBindings
import PencilKit
import UIKit

/// Local, opt-in experiment: reads one standalone handwritten Pinyin line with the Apache-2.0 PP-OCRv5
/// server recognizer (ONNX) through ONNX Runtime. Raw model output only: no word list, no tone guessing.
/// Separate from the PencilKit baseline and the Vision comparison; the saved ink is never touched.
enum PinyinOCRResult: Sendable, Equatable {
    case empty
    case modelMissing(String)
    case failed(String)
    case recognized(text: String, elapsed: Duration, cropWidth: Int, cropHeight: Int, tensorWidth: Int)
    /// Mobile model after ink cleanup; `dropped` counts isolated specks left out of the crop.
    case cleaned(text: String, elapsed: Duration, cropWidth: Int, cropHeight: Int, tensorWidth: Int, dropped: Int)
    /// Two or more clearly separated horizontal lines, each cropped and recognized on its own, top to bottom.
    /// `text` joins the raw per-line outputs with newlines. `dropped` is only nonzero for the mobile model.
    case byLine(text: String, elapsed: Duration, lines: [LineCrop], dropped: Int)

    struct LineCrop: Sendable, Equatable {
        var text: String
        var cropWidth: Int
        var cropHeight: Int
        var tensorWidth: Int
    }

    var text: String? {
        switch self {
        case .recognized(let text, _, _, _, _), .cleaned(let text, _, _, _, _, _), .byLine(let text, _, _, _): return text
        default: return nil
        }
    }

    var lines: [String] {
        switch self {
        case .byLine(let text, let elapsed, let crops, let dropped):
            var report = [
                "Output: \"\(text)\"",
                "Elapsed: \(RecognitionReport.format(elapsed)) (the first run includes loading the model)",
                "Lines: \(crops.count), split by blank horizontal bands in the pen geometry; each line recognized on its own",
            ]
            for (index, crop) in crops.enumerated() {
                report.append("Line \(index + 1): \"\(crop.text)\", crop \(crop.cropWidth)×\(crop.cropHeight) px → tensor 3×\(PinyinPreprocessor.height)×\(crop.tensorWidth)")
            }
            if dropped > 0 {
                report.append("Cleanup: \(dropped) isolated speck stroke\(dropped == 1 ? "" : "s") left out of the crops")
            }
            return report
        case .cleaned(let text, let elapsed, let cropWidth, let cropHeight, let tensorWidth, let dropped):
            return [
                "Output: \"\(text)\"",
                "Elapsed: \(RecognitionReport.format(elapsed)) (the first run includes loading the model)",
                "Lines: 1",
                "Ink crop: \(cropWidth)×\(cropHeight) px → tensor 3×\(PinyinPreprocessor.height)×\(tensorWidth)",
                "Cleanup: \(dropped) isolated speck stroke\(dropped == 1 ? "" : "s") left out of the crop; strokes grown 1 px (3×3 minimum) before resizing",
            ]
        case .empty:
            return ["No ink to recognize."]
        case .modelMissing(let message), .failed(let message):
            return [message]
        case .recognized(let text, let elapsed, let cropWidth, let cropHeight, let tensorWidth):
            return [
                "Output: \"\(text)\"",
                "Elapsed: \(RecognitionReport.format(elapsed)) (the first run includes loading the model)",
                "Lines: 1",
                "Ink crop: \(cropWidth)×\(cropHeight) px → tensor 3×\(PinyinPreprocessor.height)×\(tensorWidth)",
            ]
        }
    }
}

/// Greedy CTC decoding. Class 0 is the blank; class k ≥ 1 is `dictionary[k - 1]`, and the class right after
/// the dictionary is the space character PaddleOCR appends. Entries may be several code points
/// (a letter plus a combining tone mark); the joined text is returned in NFC.
enum PinyinCTC {
    /// Prefix beam search in log probability space. Blank/repeat paths are summed,
    /// so alternatives are actual CTC sequences, not fabricated dictionary substitutions.
    static func alternatives(logits: [Float], steps: Int, classes: Int, dictionary: [String], width: Int = 5) -> [String] {
        guard classes > 1, steps > 0, logits.count >= steps * classes, width > 0 else { return [] }
        func sum(_ a: Double, _ b: Double) -> Double {
            if a == -.infinity { return b }
            if b == -.infinity { return a }
            let high = max(a, b)
            return high + log1p(exp(min(a, b) - high))
        }
        struct Beam {
            var blank: Double = -.infinity
            var ink: Double = -.infinity
            var score: Double { max(blank, ink) == -.infinity ? -.infinity : max(blank, ink) + log1p(exp(-abs(blank - ink))) }
        }
        var beams: [[Int]: Beam] = [Array<Int>(): Beam(blank: 0)]
        for step in 0..<steps {
            let row = step * classes
            var top: [Int] = []
            for c in 1..<classes {
                if top.count < 8 || logits[row + c] > logits[row + top.last!] {
                    top.append(c)
                    top.sort { logits[row + $0] > logits[row + $1] }
                    if top.count > 8 { top.removeLast() }
                }
            }
            var next: [[Int]: Beam] = [:]
            let blank = log(max(1e-30, Double(logits[row])))
            for (prefix, state) in beams {
                var same = next[prefix, default: Beam()]
                same.blank = sum(same.blank, state.score + blank)
                next[prefix] = same
                for c in top {
                    let probability = log(max(1e-30, Double(logits[row + c])))
                    if prefix.last == c {
                        var repeatState = next[prefix, default: Beam()]
                        repeatState.ink = sum(repeatState.ink, state.ink + probability)
                        next[prefix] = repeatState
                    }
                    let extended = prefix + [c]
                    var target = next[extended, default: Beam()]
                    target.ink = sum(target.ink, (prefix.last == c ? state.blank : state.score) + probability)
                    next[extended] = target
                }
            }
            beams = Dictionary(uniqueKeysWithValues: next.sorted { $0.value.score > $1.value.score }.prefix(width).map { ($0.key, $0.value) })
        }
        var result: [String] = []
        for (prefix, state) in beams.sorted(by: { $0.value.score > $1.value.score }) where state.score.isFinite {
            let text = prefix.map { $0 - 1 < dictionary.count ? dictionary[$0 - 1] : " " }.joined().precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && !result.contains(text) { result.append(text) }
        }
        return result
    }

    static func decode(logits: [Float], steps: Int, classes: Int, dictionary: [String]) -> String {
        guard classes > 1, steps > 0, logits.count >= steps * classes else { return "" }
        var text = ""
        var previous = 0
        for step in 0..<steps {
            let base = step * classes
            var best = 0
            for c in 1..<classes where logits[base + c] > logits[base + best] { best = c }
            if best != 0, best != previous {
                if best - 1 < dictionary.count {
                    text += dictionary[best - 1]
                } else if best - 1 == dictionary.count {
                    text += " "
                }
            }
            previous = best
        }
        return text.precomposedStringWithCanonicalMapping
    }
}

/// Paddle's iOS recognizer input: black ink on white, grayscale, cropped tightly to all ink (detached tone
/// marks included), resized to 48 px high keeping the aspect ratio, RGB-replicated CHW Float32 in [-1, 1],
/// at least 320 wide with zeros padded on the right.
enum PinyinPreprocessor {
    static let height = 48
    static let minWidth = 320
    /// The benchmark that matched the expected output used tight + 8 px at screenshot scale. An iPad
    /// screenshot is 2 px per point, so the ink is rendered at 2× and padded by 8 px (4 pt).
    static let renderScale: CGFloat = 2
    static let paddingPixels: CGFloat = 8

    /// Mobile-model cleanup: a stroke is an isolated speck if its rendered size is under this many points.
    static let speckMaxSize = InkLineGeometry.speckMaxSize
    /// ...and it is farther than this many points (rectangle-to-rectangle) from every other stroke.
    static let speckMinGap = InkLineGeometry.speckMinGap

    struct Input: Sendable {
        var tensor: [Float]
        var tensorWidth: Int
        var cropWidth: Int
        var cropHeight: Int
        var droppedStrokes = 0
    }

    /// Rectangle-to-rectangle distance (0 when they touch or overlap).
    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        InkLineGeometry.gap(a, b)
    }

    /// Strokes to leave out of the mobile crop (the drawing itself is never changed). A stroke is a speck only
    /// if it is tiny and farther than ``speckMinGap`` from every other stroke, and either
    /// - lies entirely below all other ink, or
    /// - sits no higher than the top of the written ink but horizontally outside its whole extent (a stray
    ///   point beside or between lines).
    /// Tiny strokes near the writing, or above it, such as tone marks, i dots, accents and punctuation, stay.
    /// The second rule needs at least one non-tiny stroke, so ink is never all discarded.
    static func isolatedSpeckIndices(in drawing: PKDrawing) -> Set<Int> {
        let rects = drawing.strokes.map { $0.renderBounds }
        let body = rects.filter { max($0.width, $0.height) >= speckMaxSize }
        let written = body.dropFirst().reduce(body.first) { $0?.union($1) }
        var result = Set<Int>()
        for (i, r) in rects.enumerated() where max(r.width, r.height) < speckMaxSize {
            let others = rects.enumerated().filter { $0.offset != i }.map(\.element)
            guard let main = others.dropFirst().reduce(others.first, { $0?.union($1) }) else { continue }
            guard others.allSatisfy({ gap(r, $0) > speckMinGap }) else { continue }
            let below = r.minY >= main.maxY
            var beside = false
            if let written { beside = r.minY >= written.minY && (r.maxX < written.minX || r.minX > written.maxX) }
            if below || beside { result.insert(i) }
        }
        return result
    }

    /// A line break needs a blank horizontal band at least this many times the typical (median) body stroke height.
    static let lineGapFactor = InkLineGeometry.lineGapFactor

    /// Stroke indices (ascending, so source order is kept) per horizontal line, top to bottom. The pen geometry
    /// is the line detector: occupied vertical intervals of the non-tiny strokes' rendered bounds are merged,
    /// and a new line starts only across a blank band of at least ``lineGapFactor`` × the median body stroke
    /// height (never under ``speckMinGap``), so detached accents and dots stay with their letters. Tiny strokes
    /// join the line whose ink is closest. Falls back to a single group of every stroke whenever unsure: fewer
    /// than two lines, a line with fewer than two body strokes, or non-finite bounds.
    static func lineGroups(in drawing: PKDrawing) -> [[Int]] {
        InkLineGeometry.lineGroups(in: drawing)
    }

    /// A horizontal break needs a blank gap at least this many times the median body stroke height. Conservative:
    /// spaces inside one written word (e.g. between two syllables) are narrower than a script change.
    static let regionGapFactor: CGFloat = 1.5

    /// Diagnostic only. Stroke indices (ascending) per clearly spaced horizontal region of a single written line,
    /// left to right. Empty unless the page is clearly one line (``lineGroups`` finds no split) and at least two
    /// regions each hold two or more body strokes. Tiny strokes join the nearest region. No words are guessed.
    static func horizontalRegions(in drawing: PKDrawing) -> [[Int]] {
        let rects = drawing.strokes.map { $0.renderBounds }
        guard rects.allSatisfy({ [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }),
              lineGroups(in: drawing).count == 1
        else { return [] }
        let body = rects.indices.filter { max(rects[$0].width, rects[$0].height) >= speckMaxSize }
        guard body.count >= 4 else { return [] }
        let heights = body.map { rects[$0].height }.sorted()
        let threshold = max(speckMinGap, regionGapFactor * heights[heights.count / 2])

        var groups: [[Int]] = []
        var right = -CGFloat.infinity
        for i in body.sorted(by: { rects[$0].minX < rects[$1].minX }) {
            if groups.isEmpty || rects[i].minX - right > threshold {
                groups.append([i])
                right = rects[i].maxX
            } else {
                groups[groups.count - 1].append(i)
                right = max(right, rects[i].maxX)
            }
        }
        guard groups.count > 1, groups.allSatisfy({ $0.count >= 2 }) else { return [] }

        for i in rects.indices where !body.contains(i) {
            func distance(_ members: [Int]) -> CGFloat { members.map { gap(rects[i], rects[$0]) }.min() ?? .infinity }
            let nearest = groups.indices.min { distance(groups[$0]) < distance(groups[$1]) } ?? 0
            groups[nearest].append(i)
        }
        return groups.map { $0.sorted() }
    }

    /// Black ink (with alpha) at ``renderScale``, cropped to the ink plus padding. With `cleanup`, isolated
    /// specks are left out of the crop and render. Nil without ink.
    static func renderInk(for drawing: PKDrawing, cleanup: Bool = false) -> (image: CGImage, dropped: Int)? {
        var drawing = drawing
        var dropped = 0
        if cleanup {
            let specks = isolatedSpeckIndices(in: drawing)
            if !specks.isEmpty {
                dropped = specks.count
                drawing = PKDrawing(strokes: drawing.strokes.enumerated().filter { !specks.contains($0.offset) }.map(\.element))
            }
        }
        let bounds = drawing.bounds
        guard !drawing.strokes.isEmpty,
              bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0 || bounds.height > 0
        else { return nil }

        let inset = paddingPixels / renderScale
        let rect = bounds.insetBy(dx: -inset, dy: -inset)
        var ink: CGImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = RecognitionProbe.monochromeCopy(of: drawing).image(from: rect, scale: renderScale).cgImage
        }
        guard let ink, ink.width > 0, ink.height > 0 else { return nil }
        return (ink, dropped)
    }

    /// The same render composited onto white as 8-bit grayscale at native resolution (not resized).
    static func nativeGrayscale(for drawing: PKDrawing, cleanup: Bool = false) -> (image: CGImage, dropped: Int)? {
        guard let (ink, dropped) = renderInk(for: drawing, cleanup: cleanup),
              let context = CGContext(
                data: nil, width: ink.width, height: ink.height, bitsPerComponent: 8, bytesPerRow: ink.width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: ink.width, height: ink.height))
        context.draw(ink, in: CGRect(x: 0, y: 0, width: ink.width, height: ink.height))
        guard let gray = context.makeImage() else { return nil }
        return (gray, dropped)
    }

    /// 3×3 minimum filter on the full-resolution grayscale pixels: dark strokes grow by 1 px on every side.
    static func grown(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let context = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let out = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let source = Array(UnsafeBufferPointer(start: out, count: w * h))
        for y in 0..<h {
            for x in 0..<w {
                var low = UInt8.max
                for yy in max(0, y - 1)...min(h - 1, y + 1) {
                    for xx in max(0, x - 1)...min(w - 1, x + 1) { low = min(low, source[yy * w + xx]) }
                }
                out[y * w + x] = low
            }
        }
        return context.makeImage()
    }

    /// Nil when the drawing has no usable ink. `cleanup` is the mobile-model variant: isolated specks left
    /// out of the crop, and dark strokes grown by 1 px at full resolution before resizing.
    static func input(for drawing: PKDrawing, cleanup: Bool = false) -> Input? {
        makeInput(for: drawing, cleanup: cleanup, grow: cleanup)
    }

    /// One input per detected line, top to bottom (a single input when the lines are unclear). With `cleanup`,
    /// isolated specks are found on the whole page first, so a stray point never widens a line's crop.
    /// Nil if any line has no usable ink; the caller then falls back to the whole drawing.
    static func lineInputs(for drawing: PKDrawing, cleanup: Bool = false) -> [Input]? {
        var page = drawing
        var dropped = 0
        if cleanup {
            let specks = isolatedSpeckIndices(in: drawing)
            if !specks.isEmpty {
                dropped = specks.count
                page = PKDrawing(strokes: drawing.strokes.enumerated().filter { !specks.contains($0.offset) }.map(\.element))
            }
        }
        let groups = lineGroups(in: page)
        guard groups.count > 1 else { return nil }
        var inputs: [Input] = []
        for group in groups {
            let line = PKDrawing(strokes: group.map { page.strokes[$0] })
            guard var input = makeInput(for: line, cleanup: false, grow: cleanup) else { return nil }
            input.droppedStrokes = inputs.isEmpty ? dropped : 0
            inputs.append(input)
        }
        return inputs
    }

    private static func makeInput(for drawing: PKDrawing, cleanup: Bool, grow: Bool) -> Input? {
        let ink: CGImage
        var dropped = 0
        if grow {
            guard let native = nativeGrayscale(for: drawing, cleanup: cleanup) else { return nil }
            ink = grown(native.image) ?? native.image
            dropped = native.dropped
        } else {
            guard let rendered = renderInk(for: drawing)?.image else { return nil }
            ink = rendered
        }

        let width = max(1, Int((Double(height) * Double(ink.width) / Double(ink.height)).rounded(.up)))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(ink, in: CGRect(x: 0, y: 0, width: width, height: height))

        let tensorWidth = max(minWidth, width)
        let plane = height * tensorWidth
        var tensor = [Float](repeating: 0, count: 3 * plane)
        for y in 0..<height {
            for x in 0..<width {
                let value = (Float(pixels[y * width + x]) / 255 - 0.5) / 0.5
                for channel in 0..<3 { tensor[channel * plane + y * tensorWidth + x] = value }
            }
        }
        return Input(
            tensor: tensor, tensorWidth: tensorWidth, cropWidth: ink.width, cropHeight: ink.height,
            droppedStrokes: dropped
        )
    }
}

/// Opt-in diagnostic: read each clearly separated region of a single line with PencilKit first, then run the Paddle
/// mobile model ONLY on a Latin region that ``PinyinContextHint`` matches to the Hanzi region immediately before it.
/// The PencilKit raw text of every region is kept as read; Paddle output is shown beside it, never merged,
/// chosen or corrected. The saved drawing is never touched.
enum PinyinContextRouting {
    struct Decision: Equatable {
        /// Zero-based region index of the Latin candidate.
        var region: Int
        var routed: Bool
        var reason: String
    }

    /// Pure routing over PencilKit region texts (nil = nothing read). Region 0 has no preceding region. Regions
    /// that aren't a Latin candidate after a Hanzi region are explained but never routed.
    static func decisions(pencilTexts: [String?]) -> [Decision] {
        guard pencilTexts.count > 1 else { return [] }
        return (1..<pencilTexts.count).map { index in
            let number = index + 1
            guard let latin = pencilTexts[index], !latin.isEmpty else {
                return Decision(region: index, routed: false, reason: "Region \(number): PencilKit read nothing; not routed")
            }
            guard let previous = pencilTexts[index - 1], let hanzi = PinyinContextHint.hanziOnly(previous) else {
                return Decision(region: index, routed: false, reason: "Region \(number): previous region isn't a short Hanzi-only reading; not routed")
            }
            guard PinyinContextHint.latinLetters(latin) != nil else {
                return Decision(region: index, routed: false, reason: "Region \(number): not Latin-only with at least \(PinyinContextHint.minLatinLetters) letters; not routed")
            }
            guard PinyinContextHint.matches(hanzi: hanzi, latin: latin) else {
                return Decision(region: index, routed: false, reason: "Region \(number): letters don't match the romanization of region \(index) “\(hanzi)”; not routed")
            }
            return Decision(region: index, routed: true, reason: "Region \(number): letters match the romanization of region \(index) “\(hanzi)”; routed to Paddle")
        }
    }

    /// Always returns report lines (also when there's nothing to route).
    static func run(on drawing: PKDrawing) async -> [String] {
        var lines = ["Targeted Paddle only: Paddle mobile runs just on a Latin region whose letters match the romanization of the Hanzi region right before it; no other region goes to Paddle."]
        let groups = PinyinPreprocessor.horizontalRegions(in: drawing)
        guard !groups.isEmpty else {
            return lines + ["No clear horizontal regions; nothing routed."]
        }
        lines.append("Regions: \(groups.count), split by horizontal gaps over \(PinyinPreprocessor.regionGapFactor)× the median stroke height")
        let crops = groups.map { PKDrawing(strokes: $0.map { drawing.strokes[$0] }) }

        var pencil: [String?] = Array(repeating: nil, count: groups.count)
        if #available(iOS 27.0, *) {
            for (index, group) in groups.enumerated() {
                let strokes = group.map { drawing.strokes[$0] }
                pencil[index] = await RecognitionProbe.recognizedText(in: crops[index], strokeIDs: Set(strokes.map(\.id)))
            }
            for (index, text) in pencil.enumerated() {
                lines.append("Region \(index + 1) PencilKit raw: \(text.map { "\"\($0)\"" } ?? "none")")
            }
        } else {
            return lines + ["PencilKit text recognition unavailable (needs iPadOS 27); nothing routed."]
        }

        let decisions = decisions(pencilTexts: pencil)
        let routed = decisions.filter(\.routed)
        lines += decisions.map(\.reason)
        if routed.isEmpty {
            lines.append("No region routed to Paddle.")
        }
        for decision in routed {
            let result = await PinyinOCR.shared.recognizeMobile(crops[decision.region])
            lines.append("Region \(decision.region + 1) Paddle mobile: \(result.text.map { "\"\($0)\"" } ?? result.lines.joined(separator: " "))")
        }
        return lines
    }
}

/// Owns the ONNX Runtime session. Preprocessing and inference run on this actor, off the main thread.
actor PinyinOCR {
    static let shared = PinyinOCR()

    private struct Loaded {
        var session: ORTSession
        var inputName: String
        var outputName: String
        var dictionary: [String]
    }

    private var env: ORTEnv?
    private var loaded: Loaded?
    private var loadedMobile: Loaded?

    /// Keep competing character sequences instead of throwing away everything but
    /// the greedy winner. Useful for uncertain handwriting; no vocabulary restriction.
    func readings(_ drawing: PKDrawing) -> [String] {
        do {
            guard let model = try load(mobile: true),
                  let input = PinyinPreprocessor.input(for: drawing, cleanup: true) else { return [] }
            let data = input.tensor.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
            let value = try ORTValue(tensorData: data, elementType: .float,
                                    shape: [1, 3, NSNumber(value: PinyinPreprocessor.height), NSNumber(value: input.tensorWidth)])
            let outputs = try model.session.run(withInputs: [model.inputName: value], outputNames: [model.outputName], runOptions: nil)
            guard let output = outputs[model.outputName] else { return [] }
            let shape = try output.tensorTypeAndShapeInfo().shape.map(\.intValue)
            guard shape.count == 3, shape[0] == 1, shape[2] == model.dictionary.count + 2 else { return [] }
            let logits = (try output.tensorData() as Data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return PinyinCTC.alternatives(logits: logits, steps: shape[1], classes: shape[2], dictionary: model.dictionary)
        } catch { return [] }
    }

    /// The raw server model, unchanged.
    func recognize(_ drawing: PKDrawing) -> PinyinOCRResult {
        run(drawing, mobile: false)
    }

    /// The mobile model on a cleaned crop (isolated specks left out, strokes grown 1 px). Own cached session.
    func recognizeMobile(_ drawing: PKDrawing) -> PinyinOCRResult {
        run(drawing, mobile: true)
    }

    private func run(_ drawing: PKDrawing, mobile: Bool) -> PinyinOCRResult {
        guard !drawing.strokes.isEmpty else { return .empty }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            guard let model = try load(mobile: mobile) else {
                return .modelMissing(mobile
                    ? "PinyinMobileRecognition.onnx and PinyinMobileRecognitionDictionary.json aren't in the app bundle (optional). See docs/prototype/M0-first-prototype.md."
                    : "PinyinRecognition.onnx and PinyinRecognitionDictionary.json aren't in the app bundle. See docs/prototype/M0-first-prototype.md for setup.")
            }

            // Two or more clearly separated lines: one run per line, same session, joined by newlines.
            if let inputs = PinyinPreprocessor.lineInputs(for: drawing, cleanup: mobile) {
                var crops: [PinyinOCRResult.LineCrop] = []
                for input in inputs {
                    let text = try infer(input, with: model, mobile: mobile)
                    crops.append(.init(text: text, cropWidth: input.cropWidth, cropHeight: input.cropHeight, tensorWidth: input.tensorWidth))
                }
                return .byLine(
                    text: crops.map(\.text).joined(separator: "\n"), elapsed: start.duration(to: clock.now),
                    lines: crops, dropped: inputs.reduce(0) { $0 + $1.droppedStrokes }
                )
            }

            guard let input = PinyinPreprocessor.input(for: drawing, cleanup: mobile) else { return .empty }
            let text = try infer(input, with: model, mobile: mobile)
            if mobile {
                return .cleaned(
                    text: text, elapsed: start.duration(to: clock.now),
                    cropWidth: input.cropWidth, cropHeight: input.cropHeight, tensorWidth: input.tensorWidth,
                    dropped: input.droppedStrokes
                )
            }
            return .recognized(
                text: text, elapsed: start.duration(to: clock.now),
                cropWidth: input.cropWidth, cropHeight: input.cropHeight, tensorWidth: input.tensorWidth
            )
        } catch {
            return .failed("Pinyin OCR failed: \(error.localizedDescription)")
        }
    }

    private struct InferenceError: LocalizedError {
        var errorDescription: String?
    }

    private func infer(_ input: PinyinPreprocessor.Input, with model: Loaded, mobile: Bool) throws -> String {
        let data = input.tensor.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        let value = try ORTValue(
            tensorData: data, elementType: .float,
            shape: [1, 3, NSNumber(value: PinyinPreprocessor.height), NSNumber(value: input.tensorWidth)]
        )
        let outputs = try model.session.run(
            withInputs: [model.inputName: value], outputNames: [model.outputName], runOptions: nil
        )
        guard let output = outputs[model.outputName] else { throw InferenceError(errorDescription: "The model returned no output.") }
        let shape = try output.tensorTypeAndShapeInfo().shape.map(\.intValue)
        guard shape.count == 3, shape[0] == 1 else { throw InferenceError(errorDescription: "Unexpected output shape \(shape).") }
        let logits = (try output.tensorData() as Data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        if mobile, shape[2] != model.dictionary.count + 2 {
            throw InferenceError(errorDescription: "Mobile model has \(shape[2]) classes but its dictionary has \(model.dictionary.count) entries (expected entries + 2). Wrong dictionary for this model?")
        }
        return PinyinCTC.decode(logits: logits, steps: shape[1], classes: shape[2], dictionary: model.dictionary)
    }

    /// Nil if either bundled file is missing.
    private func load(mobile: Bool) throws -> Loaded? {
        if let cached = mobile ? loadedMobile : loaded { return cached }
        let name = mobile ? "PinyinMobileRecognition" : "PinyinRecognition"
        guard let modelURL = Bundle.main.url(forResource: name, withExtension: "onnx"),
              let dictionaryURL = Bundle.main.url(forResource: name + "Dictionary", withExtension: "json")
        else { return nil }
        let dictionary = try JSONDecoder().decode([String].self, from: Data(contentsOf: dictionaryURL))
        let env = try self.env ?? ORTEnv(loggingLevel: .warning)
        self.env = env
        let session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: nil)
        guard let inputName = try session.inputNames().first, let outputName = try session.outputNames().first else {
            throw NSError(domain: "PinyinOCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "The model has no input or output."])
        }
        let loaded = Loaded(session: session, inputName: inputName, outputName: outputName, dictionary: dictionary)
        if mobile { loadedMobile = loaded } else { self.loaded = loaded }
        return loaded
    }
}
#endif
