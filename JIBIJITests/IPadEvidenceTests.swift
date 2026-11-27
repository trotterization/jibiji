import Foundation
import PencilKit
import Testing
@testable import JIBIJI

/// The iPad's own evidence, pulled by `scripts/pull-ipad-evidence.sh` into the private folder beside the repository.
/// Both suites skip when it is absent, so nothing private is needed to run the suite, and nothing private is in this file.
///
/// - `IPadReplayTests` (fast, always on when replays exist): every reading the iPad recorded is run again through Suggest,
///   Replace and Cards with exactly the iPad's readings. Promises that must hold fail the test; answers that differ from
///   what the iPad gave are listed in `ipad/report.md` for a person to look at.
/// - `IPadPagesTests` (slow, opt-in with `TEST_RUNNER_JIBIJI_ALL_PAGES=1`): every saved page is read with the Simulator's
///   own readers (Vision and Paddle; the Simulator has no Chinese Pencil recognizer), with the same checks.
enum IPadEvidence {
    nonisolated static var folder: URL { PrivateReplayTests.folder.appending(path: "ipad") }
    nonisolated static var replays: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder.appending(path: "replays"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    nonisolated static var pages: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Notes").path)) ?? [])
            .filter { $0.hasSuffix(".drawing") }.map { String($0.dropLast(".drawing".count)) }
            .sorted { (NoteStore.pageNumber(of: $0) ?? 0) < (NoteStore.pageNumber(of: $1) ?? 0) }
    }

    /// Reads with what the iPad recorded for each set of strokes.
    struct RecordedReader: InkLineReader {
        let regions: [Set<String>: [NoteEvidence.Reading]]
        func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] {
            func readings(_ strokes: [PKStroke]) -> [NoteEvidence.Reading] { regions[Set(strokes.map(InkSelection.identity))] ?? [] }
            return try await NoteReading.lines(in: drawing, readRegion: { readings($0) }, readCell: { strokes, _ in
                let evidence = readings(strokes)
                return PencilInkLineReader.primary(of: evidence).map { NoteReading.CellRead(text: $0, evidence: evidence) }
            })
        }
    }

    /// What Suggest, Replace and Cards make of one page, and any promise that was broken.
    struct Outcome {
        var lines: [String] = []
        var suggestions: [String] = []
        var replace: [String] = []
        var cards: [String] = []
        var broken: [String] = []
    }

    @MainActor
    static func run(_ drawing: PKDrawing, reader: any InkLineReader, annotations folder: URL? = nil, pageID: String = "page-1",
                    preview: String? = nil) async -> Outcome {
        var outcome = Outcome()
        let dir = FileManager.default.temporaryDirectory.appending(path: "ipad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let folder {
            // A copy: the pulled notes are never written to.
            for file in ["\(pageID).annotations.json", "\(pageID).flashcards.json"] {
                try? FileManager.default.copyItem(at: folder.appending(path: file), to: dir.appending(path: file))
            }
        }
        let store = NoteStore(directory: dir)
        try? store.save(drawing, pageID: pageID)
        // As the app runs: the whole dictionary, not the test's starter list.
        let suggestions = PageSuggestionModel(pageID: pageID, store: SuggestionStore(directory: dir), reader: reader, vocabulary: .full)
        suggestions.request(for: drawing)
        await suggestions.task?.value
        for item in suggestions.pending {
            outcome.suggestions.append("“\(item.recognizedText)” → \(item.replacementText)")
            if let f = item.fieldInk {
                outcome.suggestions.append("fields: Hanzi \(f.hanzi.count) “\(f.hanziText ?? "-")”, Pinyin \(f.pinyin.count) “\(f.pinyinText ?? "-")” written=\(f.pinyinWritten), English \(f.english.count) “\(f.englishText ?? "-")”; \(item.proposal.pinyinState)")
            }
            if let plan = InlineReplacement.plan(for: item, in: drawing, pageWidth: 1180) {
                if let preview {
                    Preview.write(PKDrawing(strokes: drawing.strokes.filter { !plan.removed.contains(InkSelection.identity($0)) } + plan.added),
                                  name: "\(preview)-\(outcome.replace.count)")
                }
                let ink = drawing.strokes.map { (id: InkSelection.identity($0), box: InlineReplacement.pathBounds([$0])) }
                let removed = ink.filter { plan.removed.contains($0.id) }
                // Only where the Hanzi were read apart from the Latin: a shared cell lists every stroke under each field.
                let latin = (item.fieldInk?.pinyin ?? []).union(item.fieldInk?.english ?? [])
                let hanzi = (item.fieldInk?.hanzi ?? []).subtracting(latin)
                let marksOnly = removed.allSatisfy { $0.box.height < 45 && $0.box.width < 60 }
                outcome.replace.append("in place: \(plan.added.count) strokes added, \(removed.count) removed\(marksOnly ? "" : " (Pinyin rewritten)")")
                if !plan.removed.isSubset(of: item.sourceStrokeIDs) { outcome.broken.append("Replace would remove ink outside the note") }
                if !plan.removed.isDisjoint(with: hanzi) { outcome.broken.append("Replace would remove Hanzi ink") }
                let staying = ink.filter { !plan.removed.contains($0.id) }.map(\.box)
                for stroke in plan.added {
                    let box = InlineReplacement.pathBounds([stroke])
                    if box.height >= 12, staying.contains(where: { $0.insetBy(dx: 2, dy: 2).contains(CGPoint(x: box.midX, y: box.midY)) }) {
                        outcome.broken.append("Replace would write over ink at \(Int(box.midX)),\(Int(box.midY))")
                    }
                }
            } else {
                outcome.replace.append("whole line")
            }
        }
        let cards = PageFlashcards(pageID: pageID, store: store, reader: reader)
        cards.usesDictionary = true
        await cards.refresh(from: drawing, annotations: suggestions.annotations).value
        outcome.cards = cards.cards.filter { $0.status != .discarded }.map { "\($0.front) — \($0.back)" }
        for card in outcome.cards where card.contains("\u{FFFD}") { outcome.broken.append("card has an unreadable character: \(card)") }
        return outcome
    }

    static func report(_ name: String, _ sections: [(title: String, outcome: Outcome, iPad: [String])]) {
        var text = "# \(name)\n\nWritten by the local tests. Private: stays beside the repository.\n"
        for section in sections {
            text += "\n## \(section.title)\n"
            if !section.iPad.isEmpty, section.iPad != section.outcome.lines {
                text += "- **Read differently from the iPad.** iPad: \(section.iPad.joined(separator: " | ")) — now: \(section.outcome.lines.joined(separator: " | "))\n"
            }
            for line in section.outcome.lines { text += "- Read: \(line)\n" }
            for line in section.outcome.suggestions { text += "- Suggest: \(line)\n" }
            for line in section.outcome.replace { text += "- Replace: \(line)\n" }
            for line in section.outcome.cards { text += "- Card: \(line)\n" }
            for line in section.outcome.broken { text += "- **BROKEN:** \(line)\n" }
        }
        try? text.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
        print(text)
    }
}

@Suite("iPad replays (local only)", .serialized)
@MainActor
struct IPadReplayTests {
    @Test(.enabled(if: !IPadEvidence.replays.isEmpty))
    func everyRecordedReadingStillKeepsItsPromises() async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var sections: [(title: String, outcome: IPadEvidence.Outcome, iPad: [String])] = []
        var seen = Set<Data>()
        for url in IPadEvidence.replays {
            guard let record = try? decoder.decode(ReadingRecorder.Record.self, from: Data(contentsOf: url)) else {
                Issue.record("could not read \(url.lastPathComponent)"); continue
            }
            // The same ink read again in the same way adds nothing.
            let key = record.drawing + Data(record.regions.flatMap(\.readings).joined().joined().utf8)
            guard seen.insert(key).inserted else { continue }
            let drawing = try PKDrawing(data: record.drawing)
            let ids = drawing.strokes.map(InkSelection.identity)
            var regions: [Set<String>: [NoteEvidence.Reading]] = [:]
            for region in record.regions where region.strokes.allSatisfy(ids.indices.contains) {
                regions[Set(region.strokes.map { ids[$0] })] = region.readings.compactMap { r in
                    guard r.count >= 2, let engine = NoteEvidence.Engine(rawValue: r[0]) else { return nil }
                    return NoteEvidence.Reading(text: r[1], engine: engine, scope: .cell, alternate: r.count > 2)
                }
            }
            let reader = IPadEvidence.RecordedReader(regions: regions)
            var outcome = await IPadEvidence.run(drawing, reader: reader, preview: "replay-" + url.deletingPathExtension().lastPathComponent)
            outcome.lines = try await reader.lines(in: drawing).map(\.text)
            for problem in outcome.broken { Issue.record("\(url.lastPathComponent): \(problem)") }
            sections.append(("\(url.deletingPathExtension().lastPathComponent) · build \(record.build ?? "?")", outcome, record.lines.map(\.text)))
        }
        IPadEvidence.report("replay-report.md", sections)
    }
}

@Suite("Every saved iPad page (local, opt-in)", .serialized)
@MainActor
struct IPadPagesTests {
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["JIBIJI_ALL_PAGES"] == "1" && !IPadEvidence.pages.isEmpty
    }

    @Test(.enabled(if: IPadPagesTests.enabled))
    func everySavedPageKeepsItsPromises() async throws {
        let notes = IPadEvidence.folder.appending(path: "Notes")
        var sections: [(title: String, outcome: IPadEvidence.Outcome, iPad: [String])] = []
        let only = ProcessInfo.processInfo.environment["JIBIJI_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        for pageID in IPadEvidence.pages where only?.contains(pageID) ?? true {
            guard let drawing = try NoteStore(directory: notes).loadDrawing(pageID: pageID), !drawing.strokes.isEmpty else { continue }
            let started = Date()
            var outcome = await IPadEvidence.run(drawing, reader: PencilInkLineReader(mode: .suggestions), annotations: notes, pageID: pageID)
            outcome.lines.append("(\(String(format: "%.0f", Date().timeIntervalSince(started))) s)")
            for problem in outcome.broken { Issue.record("\(pageID): \(problem)") }
            sections.append((pageID, outcome, []))
        }
        IPadEvidence.report("pages-report.md", sections)
    }
}
