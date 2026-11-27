import Foundation
import PencilKit
import Testing
@testable import JIBIJI

/// Hanzi written alone whose dictionary has more than one reading (好 hǎo / hào): Suggest offers every reading with its
/// meaning, the everyday one first, and the student picks. Nothing is guessed onto a card before they do.
@Suite("Hanzi with several readings")
struct AmbiguousHanziTests {
    @Test(arguments: [("好", "hǎo"), ("会", "huì"), ("了", "le"), ("的", "de"), ("和", "hé"), ("行", "xíng"), ("说", "shuō"),
                      ("中", "zhōng"), ("还", "hái"), ("要", "yào"), ("看", "kàn")])
    func everyReadingIsOfferedTheEverydayOneFirst(hanzi: String, first: String) throws {
        _ = try #require(Lexicon.shared)
        let proposal = try #require(StarterVocabulary.full.proposal(forRecognizedText: hanzi), "\(hanzi): no suggestion")
        let readings = proposal.candidates.filter { $0.hanzi == hanzi }
        #expect(readings.first?.pinyin == first, "\(hanzi): offered \(readings.map(\.pinyin)) first, want \(first)")
        #expect(Set(readings.map(\.pinyin)).count >= 2, "\(hanzi): every reading is offered, \(readings.map(\.pinyin))")
        #expect(readings.allSatisfy { !$0.gloss.isEmpty }, "\(hanzi): each reading has its meaning")
    }

    /// Written Pinyin still decides: `hao` with the falling mark is 好 hào, whatever is commonest.
    @Test func writtenTonesStillDecide() throws {
        _ = try #require(Lexicon.shared)
        let proposal = try #require(StarterVocabulary.full.proposal(forRecognizedText: "好 hào"))
        #expect(proposal.candidates.first?.pinyin == "hào")
    }

    /// Through Suggest itself, as on the page: 好 written alone gets a suggestion with both readings to choose from.
    @MainActor @Test func aPageWithOnlyTheHanziGetsTheChoice() async throws {
        _ = try #require(Lexicon.shared)
        struct Reader: InkLineReader {
            func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] {
                var line = RecognizedLine(text: "好", bounds: drawing.bounds)
                line.strokeIndices = Array(drawing.strokes.indices)
                line.resolved = ResolvedNote(hanzi: .init(value: "好", status: .confirmed), pinyin: .absent, english: .absent, diagnostics: [])
                return [line]
            }
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "ambiguous-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = PageSuggestionModel(pageID: "page-1", store: SuggestionStore(directory: dir), reader: Reader(), vocabulary: .full)
        let ink = try #require(CleanHandwriting.drawing(text: "好", baseline: CGPoint(x: 80, y: 200), em: 90, pen: .init(width: 3)))
        model.request(for: ink)
        await model.task?.value
        let item = try #require(model.pending.first, "\(model.status)")
        #expect(item.proposal.candidates.map(\.pinyin).prefix(2) == ["hǎo", "hào"])
    }
}
