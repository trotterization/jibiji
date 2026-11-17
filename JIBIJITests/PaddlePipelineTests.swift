import Foundation
import PencilKit
import Testing
import UIKit
@testable import JIBIJI

@Suite("Paddle v6 text pipeline", .serialized)
struct PaddlePipelineTests {
    @Test func decoderKeepsBlankSeparatedCharactersAndReportsConfidence() {
        let values: [Float] = [0.05, 0.9, 0.03, 0.02,
                              0.9, 0.05, 0.03, 0.02,
                              0.05, 0.9, 0.03, 0.02,
                              0.05, 0.03, 0.9, 0.02]
        let result = PaddleTextPipeline.decode(values, steps: 4, classes: 4, dictionary: ["牛", "我"])
        #expect(result.text == "牛牛我")
        #expect(abs(result.confidence - 0.9) < 0.001)
        #expect(PaddleTextPipeline.decode([], steps: 1, classes: 4, dictionary: ["牛", "我"]).text.isEmpty)
    }

    @Test func modelInputUsesBGRAndNormalizedZeroPadding() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { renderer in
            UIColor.red.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let cg = try #require(image.cgImage)
        let tensor = try PaddleTextPipeline.tensor(cg, width: 1, height: 1,
                                                   mean: [0.5, 0.5, 0.5], std: [0.5, 0.5, 0.5], paddedWidth: 2)
        #expect(tensor == [-1, 0, -1, 0, 1, 0])
    }

    @Test func minimumAreaBoxPreservesRotatedText() throws {
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30), CGPoint(x: 25, y: 35), CGPoint(x: 5, y: 15)]
        let box = try #require(PaddleTextPipeline.minimumBox(points))
        #expect(box.count == 4)
        #expect(PaddleTextPipeline.inside(CGPoint(x: 17, y: 22), box))
        #expect(!PaddleTextPipeline.inside(CGPoint(x: 50, y: 50), box))
    }

    @Test func detectionMapProducesExpandedSourceBox() throws {
        let width = 64, height = 64
        var map = [Float](repeating: 0, count: width * height)
        for y in 20..<32 { for x in 8..<48 { map[y * width + x] = 0.95 } }
        let boxes = try PaddleTextPipeline.boxes(map, width: width, height: height)
        let box = try #require(boxes.first)
        let bounds = PaddleTextPipeline.bounds(box)
        #expect(bounds.minX < 8)
        #expect(bounds.maxX > 47)
        #expect(bounds.minY < 20)
        #expect(bounds.maxY > 31)
        #expect(try PaddleTextPipeline.boxes([], width: width, height: height).isEmpty)
    }

    @Test(.enabled(if: PaddleTextPipeline.isInstalled))
    func pretrainedPipelineReadsSyntheticInk() async throws {
        let result = try await PaddleTextPipeline().lines(in: SyntheticInk.drawing(writing: "大人"))
        print("V6 synthetic: \(result.map(\.text))")
        #expect(!result.isEmpty)
        #expect(result.allSatisfy { $0.bounds.width > 0 && $0.bounds.height > 0 })
    }

    @Test(.enabled(if: PaddleTextPipeline.isInstalled && Bundle(for: PaddleReplayAnchor.self).url(forResource: "LocalPinyinReplay", withExtension: "drawing") != nil))
    func compareLocalReplay() async throws {
        let url = try #require(Bundle(for: PaddleReplayAnchor.self).url(forResource: "LocalPinyinReplay", withExtension: "drawing"))
        let drawing = try PKDrawing(data: Data(contentsOf: url))
        let clock = ContinuousClock()
        let start = clock.now
        let pipeline = PaddleTextPipeline()
        let result = try await pipeline.lines(in: drawing)
        print("V6 pipeline replay: \(result.map { "\($0.text) @ \($0.bounds)" }), elapsed \(clock.now - start)")
        #expect(!result.isEmpty)
        #expect(result.allSatisfy { drawing.bounds.intersects($0.bounds) })
        #expect(try await pipeline.lines(in: drawing) == result)
        let rect = drawing.bounds.insetBy(dx: -24, dy: -24)
        let image = UIGraphicsImageRenderer(size: rect.size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: rect.size))
            drawing.image(from: rect, scale: 2).draw(in: CGRect(origin: .zero, size: rect.size))
        }
        if let data = image.pngData() {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("jibiji-local-pipeline-replay.png")
            try data.write(to: file)
            print("LOCAL REPLAY IMAGE: \(file.path)")
        }
    }
}

private final class PaddleReplayAnchor {}
