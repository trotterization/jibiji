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

/// Replays of private iPad pages. The ink, the readings and the expected results all live in the private evidence folder
/// beside the repository (`replays/*.json`), so nothing read from a student's handwriting is in this file.
@Suite("Private replays (local only)", .serialized)
struct PrivateReplayTests {
    struct Fixture: Decodable {
        struct Region: Decodable { var strokes: [Int]; var readings: [[String]] }
        var drawing: String
        /// First and last stroke of the note on its page.
        var strokes: [Int]
        /// What each engine read for a set of strokes, given as first and last stroke.
        var regions: [Region]
        var front: String, back: String, replace: String
    }
    static var folder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "jibiji-device-evidence-private")
    }
    static var fixtures: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder.appending(path: "replays"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    @Test(.enabled(if: !PrivateReplayTests.fixtures.isEmpty))
    func savedPagesGiveTheExpectedSuggestionAndCard() async throws {
        for url in Self.fixtures {
            let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
            let page = try PKDrawing(data: Data(contentsOf: Self.folder.appending(path: f.drawing)))
            let drawing = PKDrawing(strokes: Array(page.strokes[f.strokes[0]...f.strokes[1]]))
            let index = Dictionary(uniqueKeysWithValues: drawing.strokes.enumerated().map { (InkSelection.identity($1), $0 + f.strokes[0]) })
            func readings(_ strokes: [PKStroke]) -> [NoteEvidence.Reading] {
                let ids = strokes.compactMap { index[InkSelection.identity($0)] }.sorted()
                guard let region = f.regions.first(where: { $0.strokes == [ids.first ?? -1, ids.last ?? -1] }) else {
                    Issue.record("no reading for strokes \(ids) in \(url.lastPathComponent)")
                    return []
                }
                return region.readings.compactMap { r in NoteEvidence.Engine(rawValue: r[0]).map { .init(text: r[1], engine: $0, scope: .cell) } }
            }
            let lines = try await NoteReading.lines(in: drawing, readRegion: { readings($0) }, readCell: { strokes, _ in
                let e = readings(strokes)
                return PencilInkLineReader.primary(of: e).map { NoteReading.CellRead(text: $0, evidence: e) }
            })
            #expect(lines.count == 1, "\(url.lastPathComponent): \(lines.map(\.text))")
            let line = try #require(lines.first)
            #expect(line.strokeIndices?.count == drawing.strokes.count)
            let card = FlashcardExtractor.extract(from: line, lexicon: Lexicon.shared)
            #expect(card?.front == f.front)
            #expect(card?.back == f.back)
            let vocabulary = StarterVocabulary(entries: StarterVocabulary.standard.entries, lexicon: Lexicon.shared)
            let proposal = try #require(vocabulary.proposal(forRecognizedText: line.text) ?? line.resolved.flatMap { vocabulary.phraseProposal(for: $0) })
            #expect(PendingSuggestion(revision: 0, anchor: .zero, recognizedText: line.text, proposal: proposal).replacementText == f.replace)
        }
    }
}
