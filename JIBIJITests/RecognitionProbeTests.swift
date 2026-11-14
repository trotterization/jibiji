import Foundation
import PencilKit
import Testing
@testable import JIBIJI

/// Feasibility checks for `PKStrokeRecognizer`. These record what the recognizer returns;
/// they don't assert recognition quality, which has to be judged on a physical iPad.
@Suite("PKStrokeRecognizer feasibility", .timeLimit(.minutes(1)))
struct RecognitionProbeTests {
    @available(iOS 27.0, *)
    @Test func strokeRecognizerIsAvailableWithChineseAndEnglish() async {
        let report = await RecognitionProbe.run(on: PKDrawing())
        print(report.summary)

        #expect(report.availability == .available)
        #expect(report.recognitionVersion != nil)
        #expect(report.supportedLanguages.contains { $0.hasPrefix("en") })
        // M0 finding: the iOS 27.2 Simulator lists 20 Latin-script languages and no Chinese.
        // If this starts passing (e.g. on a physical iPad or a newer OS), update the M0 record.
        withKnownIssue("PKStrokeRecognizer lists no Chinese language on iOS 27.2 (Simulator)") {
            #expect(report.supportsSimplifiedChinese)
        }
    }

    @available(iOS 27.0, *)
    @Test(arguments: ["大人", "十三", "一二三"])
    func recognizesSyntheticChinese(_ text: String) async {
        let ink = SyntheticInk.drawing(writing: text)
        let report = await RecognitionProbe.run(on: ink)
        print("Synthetic \"\(text)\" → \(report.recognizedText.map { "\"\($0)\"" } ?? "nil") in \(report.elapsed.map(RecognitionReport.format) ?? "n/a")")

        #expect(report.availability == .available)
        #expect(report.strokeCount == ink.strokes.count)
        #expect(report.elapsed != nil)
    }

    @available(iOS 27.0, *)
    @Test func recognizesASubsetOfStrokes() async {
        // Two words far apart on one page; ask about the first word's strokes only.
        let first = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 80, y: 160))
        let second = SyntheticInk.drawing(writing: "十", origin: CGPoint(x: 600, y: 160))
        let page = PKDrawing(strokes: first.strokes + second.strokes)

        let firstText = await RecognitionProbe.recognizedText(in: page, strokeIDs: Set(first.strokes.map(\.id)))
        let secondText = await RecognitionProbe.recognizedText(in: page, strokeIDs: Set(second.strokes.map(\.id)))
        print("Stroke subsets → first: \(firstText.map { "\"\($0)\"" } ?? "nil"), second: \(secondText.map { "\"\($0)\"" } ?? "nil")")
    }

    @available(iOS 27.0, *)
    @Test func searchingForChineseFindsNothingOnThisSDK() async {
        // Recorded for the M0 finding: with no Chinese language active, the characters can't be found.
        let matches = await RecognitionProbe.search("大", in: SyntheticInk.drawing(writing: "大人"))
        print("Search \"大\" → \(matches.count) match(es)")
    }

    @available(iOS 27.0, *)
    @Test func searchReturnsStrokeIDsAndBoundsForRecognizedText() async throws {
        // Search for whatever the recognizer read from the ink, so a match is expected.
        let ink = SyntheticInk.drawing(writing: "大人")
        let recognized = try #require(await RecognitionProbe.run(on: ink).recognizedText, "Nothing was recognized to search for")
        let query = String(recognized.split(separator: " ").first ?? Substring(recognized))

        let matches = await RecognitionProbe.search(query, in: ink)
        print("Search \"\(query)\" → \(matches.count) match(es): \(matches.map { "\($0.strokeIDs.count) strokes in \($0.bounds.integral)" })")

        try #require(!matches.isEmpty, "Searching for recognized text \"\(query)\" found nothing")
        let allStrokeIDs = Set(ink.strokes.map(\.id))
        for match in matches {
            #expect(!match.strokeIDs.isEmpty)
            #expect(match.strokeIDs.isSubset(of: allStrokeIDs))
            #expect(!match.bounds.isEmpty)
            #expect(ink.bounds.insetBy(dx: -8, dy: -8).contains(match.bounds))
        }
    }

    @Test func summaryIsReadableWhenUnavailable() {
        let report = RecognitionReport(
            availability: .unavailable(reason: "It needs iPadOS 27 or later."),
            osVersion: "Version 26.4",
            strokeCount: 3
        )

        #expect(report.summary.contains("PKStrokeRecognizer: unavailable. It needs iPadOS 27 or later."))
        #expect(!report.supportsSimplifiedChinese)
    }
}
