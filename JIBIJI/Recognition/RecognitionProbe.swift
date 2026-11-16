import CoreGraphics
import Foundation
import PencilKit
#if DEBUG
import UIKit
import Vision
#endif

/// What `PKStrokeRecognizer` reported for one page. Used for the M0 feasibility check.
struct RecognitionReport: Sendable, Equatable {
    enum Availability: Sendable, Equatable {
        case available
        case unavailable(reason: String)
    }

    var availability: Availability
    var osVersion: String
    var recognitionVersion: Int?
    /// Languages the recognizer supports on this OS, as maximal identifiers (e.g. `zh-Hans-CN`).
    var supportedLanguages: [String] = []
    /// Languages the recognizer chose from ``RecognitionProbe/preferredLanguages``.
    var activeLanguages: [String] = []
    var strokeCount: Int
    var recognizedText: String?
    /// Time from handing over the drawing to receiving the text.
    var elapsed: Duration?
    #if DEBUG
    var pinyinCheck: PinyinCheck?

    /// DEBUG diagnostic: does PencilKit expose a separate Pinyin handwriting language?
    struct PinyinCheck: Sendable, Equatable {
        /// Supported Chinese Latin-script or explicit Pinyin identifier, or nil if none is exposed.
        var candidate: String?
        /// Languages the recognizer actually chose for baseline plus candidate.
        var activeLanguages: [String] = []
        var candidateActive = false
        /// Same drawing recognized with baseline plus candidate; only set if the candidate was active.
        var alternateText: String?

        var lines: [String] {
            guard let candidate else {
                return ["No separate Pinyin handwriting language is exposed by PencilKit on this iPad. The Pinyin keyboard does not establish support."]
            }
            var lines = [
                "Candidate: \(candidate)",
                "Actual languages: \(activeLanguages.isEmpty ? "none reported" : activeLanguages.joined(separator: ", "))",
                "Candidate active: \(candidateActive ? "yes" : "no")"
            ]
            if candidateActive {
                lines.append("Comparison transcription: \(alternateText.map { "\"\($0)\"" } ?? "none")")
            }
            return lines
        }
    }
    #endif

    var supportsSimplifiedChinese: Bool {
        supportedLanguages.contains { $0.hasPrefix("zh-Hans") }
    }

    /// Plain text a tester can paste into the draft PR or issue.
    var summary: String {
        var lines = ["JIBIJI recognition check", "OS: \(osVersion)"]
        switch availability {
        case .available:
            lines.append("PKStrokeRecognizer: available (recognition version \(recognitionVersion.map(String.init) ?? "unknown"))")
            lines.append("Simplified Chinese supported: \(supportsSimplifiedChinese ? "yes" : "no")")
            lines.append("Active languages: \(activeLanguages.isEmpty ? "none reported" : activeLanguages.joined(separator: ", "))")
            lines.append("Strokes: \(strokeCount)")
            lines.append("Recognized text: \(recognizedText.map { "\"\($0)\"" } ?? "none")")
            lines.append("Latency: \(elapsed.map(RecognitionReport.format) ?? "n/a")")
            lines.append("Supported languages (\(supportedLanguages.count)): \(supportedLanguages.joined(separator: ", "))")
            #if DEBUG
            if let pinyinCheck {
                lines.append("Pinyin handwriting check:")
                lines += pinyinCheck.lines.map { "  " + $0 }
            }
            #endif
        case .unavailable(let reason):
            lines.append("PKStrokeRecognizer: unavailable. \(reason)")
        }
        return lines.joined(separator: "\n")
    }

    static func format(_ duration: Duration) -> String {
        duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated, fractionalPart: .hide))
    }
}

#if DEBUG
/// Result of the opt-in standalone Vision comparison. Separate from the PencilKit baseline report.
enum VisionStandaloneResult: Sendable, Equatable {
    case empty
    case failed(String)
    case recognized(strings: [String], elapsed: Duration, pixelWidth: Int, pixelHeight: Int)

    var lines: [String] {
        switch self {
        case .empty:
            return ["No ink to recognize."]
        case .failed(let message):
            return [message]
        case .recognized(let strings, let elapsed, let width, let height):
            var lines = ["Settings: en-US, accurate, language correction off, automatic language detection off"]
            if strings.isEmpty {
                lines.append("Vision strings: none")
            } else {
                lines.append("Vision strings (\(strings.count)):")
                lines += strings.map { "\"\($0)\"" }
            }
            lines.append("Latency: \(RecognitionReport.format(elapsed))")
            lines.append("Rendered image: \(width)×\(height) px")
            return lines
        }
    }
}

#endif

/// A region of ink that matched a text search.
struct InkSearchMatch: Sendable, Equatable {
    var strokeIDs: Set<UUID>
    var bounds: CGRect
}

/// Small feasibility check for on-device handwriting recognition with `PKStrokeRecognizer`.
///
/// This isn't the product's recognition pipeline. It answers M0's questions: is the API
/// available on the target OS, which languages does it support, how fast is it, and which
/// stroke or region references come back for anchoring suggestions later.
enum RecognitionProbe {
    /// Mixed Mandarin class notes: Simplified Chinese first, then English (pinyin is Latin script).
    static let preferredLanguages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en")]

    static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    static func run(on drawing: PKDrawing) async -> RecognitionReport {
        guard #available(iOS 27.0, *) else {
            return RecognitionReport(
                availability: .unavailable(reason: "It needs iPadOS 27 or later."),
                osVersion: osVersion,
                strokeCount: drawing.strokes.count
            )
        }
        let recognizer = PKStrokeRecognizer(preferredLanguages: preferredLanguages)
        let clock = ContinuousClock()
        let start = clock.now
        await recognizer.updateDrawing(drawing)
        let text = await recognizer.recognizedText()
        let elapsed = start.duration(to: clock.now)
        let active = await recognizer.languages

        var report = RecognitionReport(
            availability: .available,
            osVersion: osVersion,
            recognitionVersion: PKStrokeRecognizer.recognitionVersion,
            supportedLanguages: PKStrokeRecognizer.supportedLanguages.map(\.maximalIdentifier).sorted(),
            activeLanguages: active.map(\.maximalIdentifier),
            strokeCount: drawing.strokes.count,
            recognizedText: text,
            elapsed: elapsed
        )
        #if DEBUG
        report.pinyinCheck = await pinyinCheck(on: drawing)
        #endif
        return report
    }

    #if DEBUG
    /// Looks for a Chinese Latin-script or explicit Pinyin language in the supported list (never guessed),
    /// then recognizes the same drawing once with the baseline plus that candidate.
    @available(iOS 27.0, *)
    private static func pinyinCheck(on drawing: PKDrawing) async -> RecognitionReport.PinyinCheck {
        let candidate = PKStrokeRecognizer.supportedLanguages
            .sorted { $0.maximalIdentifier < $1.maximalIdentifier }
            .first { language in
                let id = language.maximalIdentifier.lowercased()
                let isChineseLatin = language.languageCode?.identifier == "zh" && language.script?.identifier == "Latn"
                return isChineseLatin || id.contains("pinyin")
            }
        guard let candidate else { return .init(candidate: nil) }

        let recognizer = PKStrokeRecognizer(preferredLanguages: preferredLanguages + [candidate])
        await recognizer.updateDrawing(drawing)
        let text = await recognizer.recognizedText()
        let active = await recognizer.languages.map(\.maximalIdentifier)
        let isActive = active.contains(candidate.maximalIdentifier)
        return .init(
            candidate: candidate.maximalIdentifier,
            activeLanguages: active,
            candidateActive: isActive,
            alternateText: isActive ? text : nil
        )
    }

    // MARK: - Opt-in Vision comparison (DEBUG)

    /// Longest side, in pixels, of the temporary image handed to Vision.
    private static let visionMaxPixelSide: CGFloat = 4096
    /// Padding around the ink, in points.
    private static let visionPadding: CGFloat = 24

    /// Runs the whole drawing through Vision as rendered black-on-white ink, with no Hanzi or
    /// correction heuristics, so the strings (diacritics included) come back exactly as Vision read them.
    /// Never touches the saved drawing; it works on a recolored copy.
    static func visionStandaloneCheck(on drawing: PKDrawing) async -> VisionStandaloneResult {
        guard !drawing.strokes.isEmpty else { return .empty }
        let bounds = drawing.bounds
        guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0 || bounds.height > 0
        else { return .empty }

        guard let rendered = renderForVision(drawing, bounds: bounds) else {
            return .failed("Couldn't render the ink to an image.")
        }

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = false

        let clock = ContinuousClock()
        let start = clock.now
        do {
            let observations = try await request.perform(on: rendered)
            let elapsed = start.duration(to: clock.now)
            let strings = observations.compactMap { $0.topCandidates(1).first?.string }
            return .recognized(
                strings: strings,
                elapsed: elapsed,
                pixelWidth: rendered.width,
                pixelHeight: rendered.height
            )
        } catch {
            return .failed("Vision failed: \(error.localizedDescription)")
        }
    }

    /// A monochrome (black) copy for OCR. Path, transform, mask and stroke dimensions are reused as-is;
    /// only the ink color changes, so white or dark-mode ink stays legible. The original is untouched.
    static func monochromeCopy(of drawing: PKDrawing) -> PKDrawing {
        PKDrawing(strokes: drawing.strokes.map { stroke in
            PKStroke(
                ink: PKInk(stroke.ink.inkType, color: .black),
                path: stroke.path,
                transform: stroke.transform,
                mask: stroke.mask
            )
        })
    }

    /// Black ink on opaque white, tightly bounded plus padding, capped at ``visionMaxPixelSide``.
    private static func renderForVision(_ drawing: PKDrawing, bounds: CGRect) -> CGImage? {
        let rect = bounds.insetBy(dx: -visionPadding, dy: -visionPadding)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let scale = min(2, visionMaxPixelSide / max(rect.width, rect.height))
        guard scale.isFinite, scale > 0 else { return nil }

        let copy = monochromeCopy(of: drawing)
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = copy.image(from: rect, scale: scale)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: rect.size))
            ink.draw(at: .zero)
        }.cgImage
    }
    #endif

    /// Text recognized from just the given strokes (e.g. one word on a busy page).
    @available(iOS 27.0, *)
    static func recognizedText(in drawing: PKDrawing, strokeIDs: Set<UUID>) async -> String? {
        let recognizer = PKStrokeRecognizer(preferredLanguages: preferredLanguages)
        await recognizer.updateDrawing(drawing)
        return await recognizer.recognizedText(strokeIDs: strokeIDs)
    }

    /// Where `query` appears in the ink, as stroke IDs and page bounds.
    @available(iOS 27.0, *)
    static func search(_ query: String, in drawing: PKDrawing) async -> [InkSearchMatch] {
        let recognizer = PKStrokeRecognizer(preferredLanguages: preferredLanguages)
        await recognizer.updateDrawing(drawing)
        return await recognizer.inkSearchMatches(for: query)
    }
}

@available(iOS 27.0, *)
private extension PKStrokeRecognizer {
    /// `SearchResult` isn't `Sendable` in the iOS 27.2 SDK, so convert it while still on the recognizer.
    func inkSearchMatches(for query: String) async -> [InkSearchMatch] {
        await search(query).map { InkSearchMatch(strokeIDs: $0.strokes, bounds: $0.bounds) }
    }
}
