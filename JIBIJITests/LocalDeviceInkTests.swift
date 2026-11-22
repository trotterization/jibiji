import Foundation
import PencilKit
import Testing
@testable import JIBIJI

/// Uses the saved failing page from the physical iPad (`好 hǎo xiang`), if it is present locally.
/// The ink is private device evidence kept OUTSIDE the repository; these tests skip when it is absent.
/// They check the real stroke geometry through grouping and resolution with injected OCR text. They are not
/// a handwriting-accuracy test; Vision's real reading of the same ink is printed for the record.
@Suite("Saved device ink (local only)", .serialized)
struct LocalDeviceInkTests {
    private static var url: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            // `page-6.drawing` is the saved `好 hǎo xiang` page: strokes 0–3 `hǎo`, 4–10 `xiang`, 11–14 `好`.
            .appending(path: "jibiji-device-evidence-private/page-6.drawing")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: LocalDeviceInkTests.url.path)))
    func realSpacingJoinsHaoAndXiangIntoOnePinyinField() async throws {
        let drawing = try PKDrawing(data: Data(contentsOf: Self.url))
        func piece(_ strokes: [PKStroke]) -> Set<String> { Set(strokes.map(InkSelection.identity)) }
        let hanziIDs = Set(drawing.strokes[11...14].map(InkSelection.identity))
        func evidence(_ strokes: [PKStroke]) -> [NoteEvidence.Reading] {
            let ids = Set(strokes.map(InkSelection.identity))
            if ids.isSubset(of: hanziIDs) { return [.init(text: "好", engine: .vision, scope: .cell)] }
            // Cells of the Pinyin: first the `hǎo` letters (misread as in the observed failure), then `xiang`.
            let hao = Set(drawing.strokes[0...3].map(InkSelection.identity))
            if ids.isSubset(of: hao) { return [.init(text: "hňo", engine: .vision, scope: .cell)] }
            return [.init(text: "xiang", engine: .vision, scope: .cell)]
        }
        let lines = try await NoteReading.lines(
            in: drawing,
            readRegion: { strokes in
                let ids = Set(strokes.map(InkSelection.identity))
                return ids.isDisjoint(with: hanziIDs) ? [.init(text: "hǎo xiang", engine: .paddle, scope: .cell)]
                                                       : [.init(text: "好 hǎo xiang", engine: .paddle, scope: .cell)]
            },
            readCell: { strokes, _ in
                let e = evidence(strokes)
                return NoteReading.CellRead(text: PencilInkLineReader.primary(of: e) ?? "", evidence: e)
            })
        print("LOCAL-INK lines:", lines.map { ($0.text, $0.strokeIndices ?? [], $0.resolved?.diagnostics ?? []) })
        #expect(lines.count == 1, "好 and its Pinyin are one note")
        let line = try #require(lines.first)
        #expect(line.strokeIndices?.count == drawing.strokes.count, "no stroke (xiang) is dropped")
        #expect(line.text == "好 hǎo xiang")
        #expect(!line.text.contains("hňo"))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: LocalDeviceInkTests.url.path)))
    func visionsOwnReadingOfTheRealInkIsRecordedNotAsserted() async throws {
        let drawing = try PKDrawing(data: Data(contentsOf: Self.url))
        let vision = try await VisionInkReader.shared.lineReadings(in: drawing, includeMobileModel: false)
        print("LOCAL-INK Vision whole-page readings:", vision)
        #if DEBUG
        print("LOCAL-INK Paddle whole-page readings:", await PinyinOCR.shared.readings(drawing))
        #endif
    }

    /// The whole shipped reader (Vision + Paddle in Debug) on the real ink. Recorded, not asserted: the Simulator's
    /// PencilKit has no Chinese, and the point is to see what the engines really give the resolver.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: LocalDeviceInkTests.url.path)))
    func theWholeReaderOnTheRealInkNeverExposesRawGarble() async throws {
        let drawing = try PKDrawing(data: Data(contentsOf: Self.url))
        let lines = try await PencilInkLineReader().lines(in: drawing)
        for line in lines {
            print("LOCAL-INK REAL READER text=\(line.text) strokes=\(line.strokeIndices?.count ?? 0) hanzi=\(String(describing: line.resolved?.hanzi)) pinyin=\(String(describing: line.resolved?.pinyin)) english=\(String(describing: line.resolved?.english)) note=\(line.reviewNote ?? "-")")
            print("LOCAL-INK REAL READER diagnostics:", line.resolved?.diagnostics ?? [])
            #expect(line.readings.isEmpty)
            #expect(line.resolved?.english.value == nil, "no English was written on this page")
        }
        #expect(!lines.contains { $0.text.contains("hňo") })
    }
}

/// The saved iPad page `农夫市集 nong fu shi ji farmers market`, replayed with the readings its trace recorded.
/// Strokes 0–21 are the Hanzi, 22–36 the Pinyin, 37–44 the English.
@Suite("Saved device ink: 农夫市集 (local only)", .serialized)
struct LocalNongfuInkTests {
    static var url: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "jibiji-device-evidence-private/page-4-nongfu.drawing")
    }

    private static func cell(_ texts: [(String, NoteEvidence.Engine)]) -> [NoteEvidence.Reading] {
        texts.map { .init(text: $0.0, engine: $0.1, scope: .cell) }
    }
    private static let hanzi = cell([("农夫市集", .pencilKit), ("农夫市集", .paddleServer), ("农夫市集", .paddle)])
    private static let pinyin = cell([("none fu she ji", .pencilKit), ("nong fu shi ji", .paddleServer), ("nong fu shi ji", .paddle)])
    private static let english = cell([("farmers market", .pencilKit), ("Farmers merket", .paddleServer), ("Farmers mekeA", .paddle)])
    private static let row = cell([("农天市集none fu she ji farmers market", .pencilKit), ("农夫市集nongfushii Ffames market", .paddleServer),
                                   ("农夫市集wong fu shi ji fares moket", .paddle)])

    @Test(.enabled(if: FileManager.default.fileExists(atPath: LocalNongfuInkTests.url.path)))
    func theMiddlePinyinStaysInTheNoteAndTheCardGetsDictionaryTones() async throws {
        let drawing = try PKDrawing(data: Data(contentsOf: Self.url))
        try #require(drawing.strokes.count == 45)
        func readings(_ strokes: [PKStroke]) -> [NoteEvidence.Reading] {
            let box = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
            if box.minX < 600, box.maxX > 1000 { return Self.row }
            if box.maxX < 600 { return Self.hanzi }
            if box.minX > 1000 { return Self.english }
            if box.minX > 600, box.maxX < 1000 { return Self.pinyin }
            return []
        }
        let lines = try await NoteReading.lines(
            in: drawing,
            readRegion: { readings($0) },
            readCell: { strokes, _ in
                let e = readings(strokes)
                guard let primary = PencilInkLineReader.primary(of: e) else { return nil }
                return NoteReading.CellRead(text: primary, evidence: e)
            })
        for line in lines {
            print("NONGFU text=\(line.text) pinyin=\(String(describing: line.resolved?.pinyin)) english=\(String(describing: line.resolved?.english))")
        }
        #expect(lines.count == 1, "one note: the Pinyin in the middle is not split off")
        let line = try #require(lines.first)
        #expect(line.resolved?.hanzi.value == "农夫市集")
        #expect(line.resolved?.pinyin.value == "nong fu shi ji")
        #expect(line.resolved?.english.value == "farmers market")
        let draft = try #require(FlashcardExtractor.extract(from: line, lexicon: Lexicon.shared))
        #expect(draft.front == "农夫市集")
        #expect(draft.back == "nóngfū shìjí — farmers market")
    }
}
