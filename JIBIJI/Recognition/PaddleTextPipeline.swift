import CoreImage
import Foundation
import OnnxRuntimeBindings
import PencilKit
import UIKit
import Vision

/// Local v6 Small detection → oriented crop → recognition. No network requests.
/// Uses the exported model's BGR normalization and DB thresholds. Contours and
/// perspective crops use Apple's imaging APIs instead of adding OpenCV to the app.
actor PaddleTextPipeline {
    static let shared = PaddleTextPipeline()
    private var environment: ORTEnv?
    private var detector: ORTSession?
    private var recognizer: ORTSession?
    private var dictionary: [String] = []
    private var cachedInk: Data?
    private var cachedLines: [RecognizedLine] = []
    private let context = CIContext(options: [.cacheIntermediates: false])

    static var isInstalled: Bool {
        ["JibijiTextDetection", "JibijiTextRecognition"].allSatisfy {
            Bundle.main.url(forResource: $0, withExtension: "onnx") != nil
        } && Bundle.main.url(forResource: "JibijiTextDictionary", withExtension: "json") != nil
    }

    func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] {
        try Task.checkCancellation()
        guard !drawing.strokes.isEmpty else { return [] }
        let data = drawing.dataRepresentation()
        if data == cachedInk { return cachedLines }
        try load()
        guard let detector, let recognizer else { return [] }
        let rect = drawing.bounds.insetBy(dx: -24, dy: -24)
        guard rect.width > 0, rect.height > 0,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return [] }
        let scale = min(2, 2048 / max(rect.width, rect.height))
        let blackInk = PKDrawing(strokes: drawing.strokes.map {
            PKStroke(ink: PKInk($0.ink.inkType, color: .black), path: $0.path, transform: $0.transform, mask: $0.mask)
        })
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: rect.size, format: format).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(origin: .zero, size: rect.size))
            blackInk.image(from: rect, scale: scale).draw(at: .zero)
        }
        guard let image = rendered.cgImage else { return [] }
        // Default max-side detection resize, rounded to the model's stride.
        let ratio = min(1, 960 / Double(max(image.width, image.height)))
        let width = max(32, Int((Double(image.width) * ratio / 32).rounded()) * 32)
        let height = max(32, Int((Double(image.height) * ratio / 32).rounded()) * 32)
        let input = try Self.tensor(image, width: width, height: height,
                                    mean: [0.485, 0.456, 0.406], std: [0.229, 0.224, 0.225])
        let (probabilities, shape) = try infer(detector, tensor: input, shape: [1, 3, height, width])
        guard shape.count == 4, shape[0] == 1, shape[1] == 1,
              shape[2] * shape[3] == probabilities.count else { throw PipelineError.invalidOutput }
        let quads = try Self.boxes(probabilities, width: shape[3], height: shape[2])
        var lines: [RecognizedLine] = []
        for quad in quads {
            try Task.checkCancellation()
            let pixelQuad = quad.map { CGPoint(x: $0.x * CGFloat(image.width) / CGFloat(shape[3]),
                                               y: $0.y * CGFloat(image.height) / CGFloat(shape[2])) }
            guard let crop = crop(image, quad: pixelQuad) else { continue }
            let recWidth = min(2048, max(1, Int(ceil(48 * Double(crop.width) / Double(crop.height)))))
            let paddedWidth = max(320, recWidth)
            let tensor = try Self.tensor(crop, width: recWidth, height: 48,
                                         mean: [0.5, 0.5, 0.5], std: [0.5, 0.5, 0.5], paddedWidth: paddedWidth)
            let (logits, recShape) = try infer(recognizer, tensor: tensor, shape: [1, 3, 48, paddedWidth])
            guard recShape.count == 3, recShape[0] == 1,
                  recShape[2] == dictionary.count + 2 else { throw PipelineError.invalidOutput }
            let reading = Self.decode(logits, steps: recShape[1], classes: recShape[2], dictionary: dictionary)
            guard !reading.text.isEmpty, reading.confidence >= 0.35 else { continue }
            let bounds = Self.bounds(pixelQuad)
            let pageBounds = CGRect(x: rect.minX + bounds.minX / scale, y: rect.minY + bounds.minY / scale,
                                    width: bounds.width / scale, height: bounds.height / scale)
            lines.append(RecognizedLine(text: reading.text, bounds: pageBounds, readings: [reading.text]))
        }
        lines.sort { $0.bounds.minY == $1.bounds.minY ? $0.bounds.minX < $1.bounds.minX : $0.bounds.minY < $1.bounds.minY }
        try Task.checkCancellation()
        cachedInk = data
        cachedLines = lines
        return lines
    }

    private func load() throws {
        if detector != nil && recognizer != nil { return }
        guard let det = Bundle.main.url(forResource: "JibijiTextDetection", withExtension: "onnx"),
              let rec = Bundle.main.url(forResource: "JibijiTextRecognition", withExtension: "onnx"),
              let dict = Bundle.main.url(forResource: "JibijiTextDictionary", withExtension: "json") else {
            throw PipelineError.modelsMissing
        }
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        let detSession = try ORTSession(env: env, modelPath: det.path, sessionOptions: options)
        let recSession = try ORTSession(env: env, modelPath: rec.path, sessionOptions: options)
        let labels = try JSONDecoder().decode([String].self, from: Data(contentsOf: dict))
        environment = env
        detector = detSession
        recognizer = recSession
        dictionary = labels
    }

    private func infer(_ session: ORTSession, tensor: [Float], shape: [Int]) throws -> ([Float], [Int]) {
        let data = tensor.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        let value = try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
        guard let input = try session.inputNames().first, let outputName = try session.outputNames().first else { throw PipelineError.invalidOutput }
        let outputs = try session.run(withInputs: [input: value], outputNames: [outputName], runOptions: nil)
        guard let output = outputs[outputName] else { throw PipelineError.invalidOutput }
        let dimensions = try output.tensorTypeAndShapeInfo().shape.map(\.intValue)
        let values = (try output.tensorData() as Data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard values.allSatisfy(\.isFinite) else { throw PipelineError.invalidOutput }
        return (values, dimensions)
    }

    static func tensor(_ image: CGImage, width: Int, height: Int, mean: [Float], std: [Float], paddedWidth: Int? = nil) throws -> [Float] {
        let padded = paddedWidth ?? width
        guard width > 0, height > 0, padded >= width,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw PipelineError.invalidImage }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var tensor = [Float](repeating: 0, count: 3 * padded * height)
        for y in 0..<height { for x in 0..<width { for channel in 0..<3 {
            let value = Float(pixels[(y * width + x) * 4 + (2 - channel)]) / 255
            tensor[channel * padded * height + y * padded + x] = (value - mean[channel]) / std[channel]
        } } }
        return tensor
    }

    static func decode(_ values: [Float], steps: Int, classes: Int, dictionary: [String]) -> (text: String, confidence: Float) {
        guard steps > 0, classes == dictionary.count + 2, values.count == steps * classes else { return ("", 0) }
        var text = "", previous = 0
        var score: Float = 0
        var count: Float = 0
        for step in 0..<steps {
            let row = step * classes
            var best = 0
            for c in 1..<classes where values[row + c] > values[row + best] { best = c }
            if best != 0 && best != previous {
                text += best <= dictionary.count ? dictionary[best - 1] : " "
                score += values[row + best]
                count += 1
            }
            previous = best
        }
        return (text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines), count > 0 ? score / count : 0)
    }

    private func crop(_ image: CGImage, quad: [CGPoint]) -> CGImage? {
        let ordered = Self.ordered(quad)
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        for (key, point) in zip(["inputTopLeft", "inputTopRight", "inputBottomRight", "inputBottomLeft"], ordered) {
            filter.setValue(CIVector(x: point.x, y: CGFloat(image.height) - point.y), forKey: key)
        }
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }

    static func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let x = xs.min(), let y = ys.min(), let maxX = xs.max(), let maxY = ys.max() else { return .zero }
        return CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }

    static func ordered(_ points: [CGPoint]) -> [CGPoint] {
        let byX = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        let left = byX.prefix(2).sorted { $0.y < $1.y }
        let right = byX.suffix(2).sorted { $0.y < $1.y }
        return [left[0], right[0], right[1], left[1]]
    }

    /// DB threshold → contours → minimum-area boxes → mean score → unclip.
    static func boxes(_ map: [Float], width: Int, height: Int) throws -> [[CGPoint]] {
        guard width > 0, height > 0, map.count == width * height else { return [] }
        let mask = map.map { UInt8($0 > 0.2 ? 0 : 255) }
        guard let provider = CGDataProvider(data: Data(mask) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return [] }
        let request = VNDetectContoursRequest()
        request.detectsDarkOnLight = true
        request.maximumImageDimension = max(width, height)
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first else { return [] }
        var output: [[CGPoint]] = []
        for i in 0..<min(observation.contourCount, 3000) {
            let contour = try observation.contour(at: i)
            let simplified = try contour.polygonApproximation(epsilon: 1 / Float(max(width, height)))
            let points = simplified.normalizedPoints.map { CGPoint(x: CGFloat($0.x) * CGFloat(width), y: (1 - CGFloat($0.y)) * CGFloat(height)) }
            guard let box = minimumBox(points) else { continue }
            let a = hypot(box[1].x - box[0].x, box[1].y - box[0].y)
            let b = hypot(box[2].x - box[1].x, box[2].y - box[1].y)
            guard min(a, b) >= 3 else { continue }
            let rect = bounds(box).intersection(CGRect(x: 0, y: 0, width: width, height: height))
            var score: Float = 0, count: Float = 0
            if rect.width <= 0 || rect.height <= 0 { continue }
            for y in Int(rect.minY)..<min(height, Int(ceil(rect.maxY))) { for x in Int(rect.minX)..<min(width, Int(ceil(rect.maxX))) {
                let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if inside(point, box) { score += map[y * width + x]; count += 1 }
            } }
            guard count > 0, score / count >= 0.45 else { continue }
            let expansion = a * b * 1.4 / (2 * (a + b))
            let center = CGPoint(x: box.map(\.x).reduce(0, +) / 4, y: box.map(\.y).reduce(0, +) / 4)
            let expanded = box.map { point -> CGPoint in
                let dx = point.x - center.x, dy = point.y - center.y
                let u = CGPoint(x: (box[1].x - box[0].x) / a, y: (box[1].y - box[0].y) / a)
                let v = CGPoint(x: (box[2].x - box[1].x) / b, y: (box[2].y - box[1].y) / b)
                let du = (dx * u.x + dy * u.y) * (1 + 2 * expansion / a)
                let dv = (dx * v.x + dy * v.y) * (1 + 2 * expansion / b)
                return CGPoint(x: min(CGFloat(width), max(0, center.x + du * u.x + dv * v.x)),
                               y: min(CGFloat(height), max(0, center.y + du * u.y + dv * v.y)))
            }
            output.append(expanded)
        }
        return output
    }

    static func inside(_ p: CGPoint, _ polygon: [CGPoint]) -> Bool {
        let crosses = polygon.indices.map { i -> CGFloat in
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        }
        return crosses.allSatisfy { $0 >= 0 } || crosses.allSatisfy { $0 <= 0 }
    }

    static func minimumBox(_ points: [CGPoint]) -> [CGPoint]? {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count >= 3 else { return nil }
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower.last!, p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper.last!, p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        let hull = Array(lower.dropLast()) + Array(upper.dropLast())
        var bestArea = CGFloat.infinity
        var best: [CGPoint]?
        for i in hull.indices {
            let p = hull[i], q = hull[(i + 1) % hull.count]
            let angle = atan2(q.y - p.y, q.x - p.x)
            let c = cos(angle), s = sin(angle)
            let rotated = hull.map { CGPoint(x: $0.x * c + $0.y * s, y: -$0.x * s + $0.y * c) }
            let rect = bounds(rotated)
            if rect.width * rect.height < bestArea {
                bestArea = rect.width * rect.height
                best = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                        CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)].map {
                    CGPoint(x: $0.x * c - $0.y * s, y: $0.x * s + $0.y * c)
                }
            }
        }
        return best
    }

    enum PipelineError: LocalizedError {
        case modelsMissing, invalidImage, invalidOutput
        var errorDescription: String? {
            switch self {
            case .modelsMissing: "Download the v6 Small models using scripts/setup-paddle-models.sh."
            case .invalidImage: "The ink could not be rendered for recognition."
            case .invalidOutput: "The recognition model returned an unexpected tensor."
            }
        }
    }
}
