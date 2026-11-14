import CoreGraphics
import Foundation
import PencilKit

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
        case .unavailable(let reason):
            lines.append("PKStrokeRecognizer: unavailable. \(reason)")
        }
        return lines.joined(separator: "\n")
    }

    static func format(_ duration: Duration) -> String {
        duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated, fractionalPart: .hide))
    }
}

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

        return RecognitionReport(
            availability: .available,
            osVersion: osVersion,
            recognitionVersion: PKStrokeRecognizer.recognitionVersion,
            supportedLanguages: PKStrokeRecognizer.supportedLanguages.map(\.maximalIdentifier).sorted(),
            activeLanguages: active.map(\.maximalIdentifier),
            strokeCount: drawing.strokes.count,
            recognizedText: text,
            elapsed: elapsed
        )
    }

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
