import Foundation
import PencilKit

#if DEBUG
/// Debug builds only: every time the page is read on the iPad, the ink and what each engine read for each set of strokes
/// are saved to `Documents/replays/`. `scripts/pull-ipad-evidence.sh` copies them off the iPad, and the local replay tests
/// read the same ink again with exactly those readings, so a test on the iPad becomes a check the Simulator can repeat.
/// Nothing here leaves the device except by that script; the files stay beside the repository, never in it.
actor ReadingRecorder {
    struct Record: Codable {
        struct Region: Codable {
            /// Indices of the strokes in `drawing`, ascending.
            var strokes: [Int]
            /// [engine, text, "alt" when it is an engine's lower-ranked guess].
            var readings: [[String]]
        }
        struct Line: Codable {
            var text: String
            var strokes: [Int]
            var hanzi: String?, pinyin: String?, english: String?
        }
        var version = 1
        var date: Date
        var build: String?
        /// The ink that was read (the page's readable strokes), as PencilKit data.
        var drawing: Data
        var regions: [Region]
        var lines: [Line]
    }

    private let index: [String: Int]
    private var regions: [[Int]: [[String]]] = [:]
    private let drawing: PKDrawing

    init(_ drawing: PKDrawing) {
        self.drawing = drawing
        index = Dictionary(drawing.strokes.enumerated().map { (InkSelection.identity($1), $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Keeps what was read for these strokes.
    func note(_ strokes: [PKStroke], _ readings: [NoteEvidence.Reading]) {
        let ids = strokes.compactMap { index[InkSelection.identity($0)] }.sorted()
        guard !ids.isEmpty, regions[ids] == nil else { return }
        regions[ids] = readings.map { [$0.engine.rawValue, $0.text] + ($0.alternate ? ["alt"] : []) }
    }

    /// Writes the record. The newest 300 are kept.
    func save(_ lines: [RecognizedLine]) {
        guard !drawing.strokes.isEmpty, let dir = Self.folder else { return }
        let record = Record(
            date: Date(),
            build: BuildStamp.commit,
            drawing: drawing.dataRepresentation(),
            regions: regions.map { Record.Region(strokes: $0.key, readings: $0.value) }.sorted { $0.strokes.lexicographicallyPrecedes($1.strokes) },
            lines: lines.map { line in
                Record.Line(text: line.text, strokes: line.strokeIndices ?? [],
                            hanzi: line.resolved?.hanzi.value, pinyin: line.resolved?.pinyin.value, english: line.resolved?.english.value)
            })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "read-\(Int(Date().timeIntervalSince1970 * 1000)).json"
        try? data.write(to: dir.appendingPathComponent(name))
        DebugTrace.log("replay saved \(name) regions=\(regions.count) lines=\(lines.count)")
        let old = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in old.dropLast(300) { try? FileManager.default.removeItem(at: url) }
    }

    static var folder: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("replays")
    }
}
#endif
