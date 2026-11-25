import Foundation
import PencilKit
import Testing
@testable import JIBIJI

/// Replays the exact engine readings captured from the iPad console for page 6 (`好 hǎo xiang`).
/// Local only: skipped when the private ink is absent. Guards against the resolver hanging.
@Suite("Device replay (local only)", .serialized)
struct LocalDeviceReplayTests {
    private static var url: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "jibiji-device-evidence-private/page-6.drawing")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: LocalDeviceReplayTests.url.path)), .timeLimit(.minutes(1)))
    func resolverFinishesOnTheCapturedDeviceReadings() async throws {
        let drawing = try PKDrawing(data: Data(contentsOf: Self.url))
        func ids(_ range: ClosedRange<Int>) -> Set<String> { Set(drawing.strokes[range].map(InkSelection.identity)) }
        let hao = ids(0...3), xiang = ids(4...10), hanzi = ids(11...14)
        func r(_ t: String, _ e: NoteEvidence.Engine, alt: Bool = false) -> NoteEvidence.Reading { .init(text: t, engine: e, scope: .cell, alternate: alt) }
        let lines = try await NoteReading.lines(
            in: drawing,
            readRegion: { strokes in
                let s = Set(strokes.map(InkSelection.identity))
                if s == hao.union(xiang) { return [r("hão Xiang", .pencilKit), r("hǔo xiang", .paddle), r("hǎo xiang", .paddle, alt: true), r("hǐo xiang", .paddle, alt: true)] }
                return [r("好\nhão Xiang", .pencilKit), r("好 hǔo xiang", .paddle), r("好 hǎo xiang", .paddle, alt: true), r("好 hǔ。 xiang", .paddle, alt: true)]
            },
            readCell: { strokes, _ in
                let s = Set(strokes.map(InkSelection.identity))
                let e: [NoteEvidence.Reading]
                if s.isSubset(of: hanzi) { e = [r("好", .pencilKit), r("好", .paddle), r("好子", .paddle, alt: true)] }
                else if s.isSubset(of: hao) { e = [r("hão", .pencilKit), r("hǐo", .paddle), r("hǎo", .paddle, alt: true), r("hao", .paddle, alt: true)] }
                else { e = [r("Xiang", .pencilKit), r("xiang", .paddle), r("×iang", .paddle, alt: true)] }
                return NoteReading.CellRead(text: PencilInkLineReader.primary(of: e) ?? "", evidence: e)
            })
        print("REPLAY lines:", lines.map { ($0.text, $0.resolved?.pinyin as Any, $0.reviewNote as Any) })
        #expect(!lines.isEmpty)
    }
}
