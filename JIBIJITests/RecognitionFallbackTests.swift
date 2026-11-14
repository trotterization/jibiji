import Foundation
import PencilKit
import Testing
import UIKit
import Vision
@testable import JIBIJI

/// M0 fallback probe: if `PKStrokeRecognizer` can't read Chinese, can Vision read rendered ink?
///
/// Test-only on purpose. It records what Vision returns for machine-drawn synthetic ink so the
/// team can decide on the recognition approach; it isn't part of the app.
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
