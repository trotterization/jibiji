import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import JIBIJI

/// The repaired flow: ink → groups → retained evidence → resolved fields → Suggest / cards.
/// The ink is synthetic and every reading is injected, so these prove the *logic* of the flow (validation,
/// resolution, shared consumers). They do not prove handwriting accuracy; that needs the device.
@Suite("Recognition repair", .serialized)
struct RecognitionRepairTests {
    // MARK: - Spelling validation

    @Test func pinyinValidatorSeparatesRealPinyinFromGarble() {
        for good in ["hǎo", "hao", "xiang", "xiàng", "hǎoxiàng", "fùzé", "xi'an", "hao3", "lǜ", "nǚ", "nóngfū"] {
            #expect(PinyinValidator.analyze(good).isValid, "\(good) should be valid")
        }
        for bad in ["hňo", "xaing", "hǎoxz", "hao9x"] {
            #expect(!PinyinValidator.analyze(bad).isValid, "\(bad) should not be valid")
        }
        // A garbled word with tone marks was meant as Pinyin, so it can never be English.
        #expect(PinyinValidator.analyze("hňo").toneEvidence)
        #expect(!PinyinValidator.analyze("seem").toneEvidence)
        #expect(FieldValidation.kind(of: "hňo") == .pinyinMalformed)
        #expect(FieldValidation.kind(of: "to") == .english)
        #expect(FieldValidation.kind(of: "xiang") == .pinyinPlain)
        #expect(!FieldValidation.isEnglish("hǎo", hanzi: "好", vocabulary: .standard))
        #expect(!FieldValidation.isEnglish("hao", hanzi: "好", vocabulary: .standard))   // short Pinyin is not English
        #expect(FieldValidation.isEnglish("to seem like", hanzi: "好", vocabulary: .standard))
        #expect(FieldValidation.isEnglish("me", hanzi: "好", vocabulary: .standard))
    }

    // MARK: - A page like the failing one: 好, then hǎo xiang written with a clear word space

    private struct Ocr {
        var hanzi = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 203, y: 140), glyphSize: 110, spacing: 4)
        var hao = SyntheticInk.drawing(writing: "一二三", origin: CGPoint(x: 497, y: 180), glyphSize: 28, spacing: 4)
        var xiang = SyntheticInk.drawing(writing: "一二三四五", origin: CGPoint(x: 640, y: 182), glyphSize: 24, spacing: 4)
        var english: PKDrawing? = nil
        var all: PKDrawing { PKDrawing(strokes: ([hanzi, hao, xiang] + (english.map { [$0] } ?? [])).flatMap(\.strokes)) }

        /// What each engine says about each single piece, and about joined regions (keyed by piece names).
        var cells: [String: [NoteEvidence.Reading]] = [:]
        var regions: [Set<String>: [NoteEvidence.Reading]] = [:]

        func name(of strokes: [PKStroke]) -> Set<String> {
            let ids = Set(strokes.map(InkSelection.identity))
            var names = Set<String>()
            for (n, d) in [("hanzi", hanzi), ("hao", hao), ("xiang", xiang), ("english", english ?? PKDrawing())] where !ids.isDisjoint(with: d.strokes.map(InkSelection.identity)) { names.insert(n) }
            return names
        }

        func lines() async throws -> [RecognizedLine] {
            try await NoteReading.lines(
                in: all,
                readRegion: { strokes in regions[name(of: strokes)] ?? [] },
                readCell: { strokes, _ in
                    let names = name(of: strokes)
                    let evidence = names.count == 1 ? (cells[names.first!] ?? []) : []
                    guard let primary = PencilInkLineReader.primary(of: evidence) else { return nil }
                    return NoteReading.CellRead(text: primary, evidence: evidence)
                })
        }
    }

    private func r(_ text: String, _ engine: NoteEvidence.Engine) -> NoteEvidence.Reading { .init(text: text, engine: engine, scope: .cell) }

    @Test func separatedPinyinSyllablesAreOneFieldAndTheCorrectWholeLineReadingWins() async throws {
        var ocr = Ocr()
        ocr.cells = ["hanzi": [r("好", .vision)],
                     "hao": [r("hňo", .vision), r("hno", .paddle)],        // the observed misread of hǎo
                     "xiang": [r("xiang", .vision), r("xiang", .paddle)]]
        ocr.regions = [["hao", "xiang"]: [r("hǎo xiang", .paddle), r("hao xiang", .vision)],
                       ["hanzi", "hao", "xiang"]: [r("好 hǎo xiang", .paddle)]]
        let lines = try await ocr.lines()
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(line.text == "好 hǎo xiang")
        #expect(line.resolved?.pinyin.status == .confirmed)
        #expect(line.readings.isEmpty && line.alternatives.isEmpty)
        // The garble is retained as a diagnostic only.
        #expect(line.resolved?.diagnostics.contains { $0.contains("hňo") } == true)
        #expect(!line.text.contains("hňo"))
        // Suggest completes it from the vocabulary; flashcards read the very same record.
        #expect(StarterVocabulary.standard.proposal(forRecognizedText: line.text)?.candidates.first?.hanzi == "好像")
    }

    @MainActor @Test func aMisreadPinyinWithNoValidReadingStaysUnresolvedNeverEnglishNeverAnAlternative() async throws {
        var ocr = Ocr()
        ocr.cells = ["hanzi": [r("好", .vision)], "hao": [r("hňo", .vision)], "xiang": [r("xiang", .vision)]]
        let line = try #require(try await ocr.lines().first)
        #expect(line.resolved?.pinyin.status == .unresolved)
        #expect(line.resolved?.english.status == .absent)
        #expect(line.text == "好")
        #expect(line.inkEditSuppressed)
        #expect(line.reviewNote?.contains("Pinyin") == true)
        #expect(line.readings.isEmpty)
        // No card: there is no English, and "hňo" must not become it.
        #expect(FlashcardExtractor.extract(from: line) == nil)
        // And Suggest offers nothing built from the garble.
        let model = await suggestions(for: [line])
        #expect(model.pending.isEmpty)
        if case .message(let text) = model.status { #expect(!text.contains("hňo")); #expect(text.contains("Pinyin")) } else { Issue.record("expected a message") }
    }

    @Test func shortPinyinAndEnglishNeverFallIntoEachOthersField() async throws {
        var ocr = Ocr()
        ocr.english = SyntheticInk.drawing(writing: "一二三", origin: CGPoint(x: 203, y: 290), glyphSize: 24, spacing: 4)
        ocr.cells = ["hanzi": [r("好", .vision), r("好", .paddle)], "hao": [r("hǎo", .vision), r("hǎo", .paddle)], "english": [r("good", .vision), r("good", .paddle)],
                     "xiang": [r("xiang", .vision)]]
        // `xiang` is a separate note here; make it far away so it is not joined.
        ocr.xiang = SyntheticInk.drawing(writing: "一二三四五", origin: CGPoint(x: 900, y: 700), glyphSize: 24, spacing: 4)
        let lines = try await ocr.lines()
        let note = try #require(lines.first { $0.text.hasPrefix("好") })
        #expect(note.resolved?.pinyin.value == "hǎo")
        #expect(note.resolved?.english.value == "good")
        let draft = try #require(FlashcardExtractor.extract(from: note))
        #expect(draft.front == "好")
        #expect(draft.back == "hǎo — good")
    }

    @Test func conflictingReadersAreResolvedByThePinyinAndTheLoserIsADiagnostic() async throws {
        var ocr = Ocr()
        ocr.cells = ["hanzi": [r("女子", .pencilKit), r("好", .vision)], "hao": [r("hǎo", .vision), r("hǎo", .paddle)], "xiang": [r("xiàng", .vision), r("xiàng", .paddle)]]
        let line = try #require(try await ocr.lines().first)
        #expect(line.resolved?.hanzi.value == "好")
        #expect(line.resolved?.hanzi.status == .tentative)
        #expect(line.resolved?.diagnostics.contains { $0.contains("女子") } == true)
        #expect(line.inkEditSuppressed)   // a tentative Hanzi never rewrites the student's ink
    }

    @Test func englishThatIsReallyPinyinIsRejectedNotKept() {
        let entry = NoteGrouping.Entry(hanzi: .init(text: "好", cellText: "好", strokeIndices: [0], bounds: .init(x: 0, y: 0, width: 50, height: 50)),
                                       english: .init(text: "hňo", cellText: "hňo", strokeIndices: [1], bounds: .init(x: 60, y: 0, width: 50, height: 50)),
                                       arrangement: .sideBySide, uncertainty: [])
        let resolved = FieldResolver.resolve(entry: entry, readings: [])
        #expect(resolved.english.value == nil)
        #expect(resolved.english.status == .unresolved)
        #expect(resolved.diagnostics.contains { $0.contains("hňo") })
        #expect(FlashcardExtractor.extract(from: { var l = RecognizedLine(text: resolved.cleanText, bounds: .zero); l.resolved = resolved; return l }()) == nil)
    }

    // MARK: - Several notes

    @Test func twoNotesAreResolvedIndependently() async throws {
        var ocr = Ocr()
        ocr.cells = ["hanzi": [r("好", .vision), r("好", .paddle)], "hao": [r("hǎo", .vision), r("hǎo", .paddle)], "xiang": [r("fùxí", .vision), r("fùxí", .paddle)]]
        // The second pinyin sits far below: with no Hanzi of its own it is a separate (Hanzi-less) note.
        ocr.xiang = SyntheticInk.drawing(writing: "一二三四", origin: CGPoint(x: 220, y: 600), glyphSize: 24, spacing: 4)
        let lines = try await ocr.lines()
        #expect(lines.count == 2)
        #expect(lines.contains { $0.text == "好 hǎo" })
        #expect(lines.contains { $0.text == "fùxí" })
        #expect(Set(lines[0].strokeIndices ?? []).isDisjoint(with: Set(lines[1].strokeIndices ?? [])))
    }

    // MARK: - Suggest and cards share one record; accepted fields are authoritative; acceptance repeats safely

    private struct Fixed: InkLineReader { var lines: [RecognizedLine]; func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] { lines } }

    @MainActor private func suggestions(for lines: [RecognizedLine]) async -> PageSuggestionModel {
        let folder = FileManager.default.temporaryDirectory.appending(path: "repair-\(UUID().uuidString)")
        let model = PageSuggestionModel(pageID: "p", store: SuggestionStore(directory: folder), reader: Fixed(lines: lines))
        model.request(for: SyntheticInk.drawing(writing: "大"))
        await model.task?.value
        return model
    }

    @MainActor @Test func suggestAcceptAndCardAgreeAndRepeatedAcceptanceChangesNothing() async throws {
        let ink = SyntheticInk.drawing(writing: "大")
        var line = RecognizedLine(text: "好 hǎo xiang", bounds: ink.bounds)
        line.strokeIndices = Array(ink.strokes.indices)
        line.resolved = ResolvedNote(
            hanzi: .init(value: "好", status: .confirmed), pinyin: .init(value: "hǎo xiang", status: .confirmed),
            english: .absent, diagnostics: [])
        let folder = FileManager.default.temporaryDirectory.appending(path: "repair-\(UUID().uuidString)")
        let model = PageSuggestionModel(pageID: "p", store: SuggestionStore(directory: folder), reader: Fixed(lines: [line]))
        model.request(for: ink); await model.task?.value
        let pending = try #require(model.pending.first)
        #expect(pending.candidate.hanzi == "好像")
        model.accept(pending.id, editedText: "像 · to seem like; to look like")
        let note = try #require(model.annotations.first)
        #expect(note.gloss == "to seem like; to look like")
        // Asking again, repeatedly, offers nothing new and keeps exactly one note.
        for _ in 0..<3 {
            model.request(for: ink); await model.task?.value
            #expect(model.pending.isEmpty)
            #expect(model.annotations.count == 1)
        }
        // Cards use the same line and the accepted fields.
        let cards = PageFlashcards(pageID: "p", store: NoteStore(directory: folder), reader: Fixed(lines: [line]))
        cards.merge(lines: [line], digest: "d", corrections: model.annotations, drawing: ink)
        #expect(cards.cards.count == 1)
        #expect(cards.cards[0].back.contains("to seem like; to look like"))
        #expect(!cards.cards[0].back.contains("hňo"))
        cards.merge(lines: [line], digest: "d", corrections: model.annotations, drawing: ink)
        #expect(cards.cards.count == 1)
    }
}
