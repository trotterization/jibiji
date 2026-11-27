import Foundation
import PencilKit
import Testing
import UIKit
@testable import JIBIJI

/// Replace in place (issue #29): the student's strokes stay, and only what the note is missing is added, at the size of the
/// writing it belongs to. The "handwriting" here is drawn from the clean typeface, so every size and position is known.
@Suite("Replace in place", .serialized)
@MainActor
struct InlineReplacementTests {
    private struct Reader: InkLineReader {
        var lines: [RecognizedLine]
        func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] {
            // Like the real reader, says nothing about strokes it was not given.
            lines.filter { ($0.strokeIndices ?? []).allSatisfy(drawing.strokes.indices.contains) && !drawing.strokes.isEmpty }
        }
    }

    private struct Piece {
        var text: String
        var x: CGFloat
        var em: CGFloat
        var kind: NoteGrouping.FieldKind
        var baseline: CGFloat = 220
        /// Tone marks drawn by hand over letters: (index of the letter in `text`, tone). The typeface's own accents are specks,
        /// far smaller than a Pencil mark, so a mark a student wrote is drawn at a hand's size instead.
        var marks: [(letter: Int, tone: Int)] = []
    }

    /// A hand-sized tone mark over letter `index` of `text` written at `x`, `baseline`, `em`.
    static func handMark(over index: Int, of text: String, x: CGFloat, baseline: CGFloat, em: CGFloat, tone: Int) -> PKStroke {
        let left = index == 0 ? 0 : CleanHandwriting.bounds(of: String(text.prefix(index)), em: em)?.maxX ?? 0
        let right = CleanHandwriting.bounds(of: String(text.prefix(index + 1)), em: em)?.maxX ?? left
        let mid = x + (left + right) / 2
        let y = baseline - 0.8 * em, w = 0.16 * em, h = 0.12 * em
        let ends: [CGPoint]
        switch tone {
        case 1: ends = [CGPoint(x: mid - w, y: y), CGPoint(x: mid + w, y: y)]
        case 2: ends = [CGPoint(x: mid - w, y: y + h), CGPoint(x: mid + w, y: y - h)]
        case 3: ends = [CGPoint(x: mid - w, y: y - h), CGPoint(x: mid, y: y + h), CGPoint(x: mid + w, y: y - h)]
        default: ends = [CGPoint(x: mid - w, y: y - h), CGPoint(x: mid + w, y: y + h)]
        }
        var points: [CGPoint] = []
        for (a, b) in zip(ends, ends.dropFirst()) { for t in 0..<8 { let f = CGFloat(t) / 8; points.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)) } }
        return CleanHandwriting.stroke(points + ends.suffix(1), pen: CleanHandwriting.Pen(width: 3))
    }

    private let pen = CleanHandwriting.Pen(width: 3)

    private func page(_ pieces: [Piece], read: ResolvedNote, shared: Bool = false, extra: [PKStroke] = [],
                      folder: URL) throws -> (page: NotePageModel, ink: PKDrawing, parts: [NoteGrouping.FieldKind: [PKStroke]]) {
        var strokes: [PKStroke] = []
        var fields: [NoteGrouping.FieldKind: [Int]] = [:]
        for piece in pieces {
            let ink = try #require(CleanHandwriting.drawing(text: piece.text, baseline: CGPoint(x: piece.x, y: piece.baseline), em: piece.em, pen: pen))
            let marks = piece.marks.map { Self.handMark(over: $0.letter, of: piece.text, x: piece.x, baseline: piece.baseline, em: piece.em, tone: $0.tone) }
            fields[piece.kind, default: []] += Array(strokes.count..<(strokes.count + ink.strokes.count + marks.count))
            strokes += ink.strokes + marks
        }
        let parts = fields.mapValues { $0.map { strokes[$0] } }
        let noteCount = strokes.count
        let drawing = PKDrawing(strokes: strokes + extra)
        var line = RecognizedLine(text: read.cleanText, bounds: InlineReplacement.pathBounds(strokes))
        line.strokeIndices = Array(0..<noteCount)
        line.fieldStrokes = shared ? fields.mapValues { _ in Array(0..<noteCount) } : fields
        line.resolved = read
        let model = NotePageModel(pageID: "page-1", store: NoteStore(directory: folder), lineReader: Reader(lines: [line]))
        model.drawingDidChange(drawing)
        return (model, model.drawing, parts)
    }

    private func note(_ hanzi: String?, _ pinyin: String?, _ english: String?) -> ResolvedNote {
        func field(_ value: String?) -> ResolvedField { value.map { .init(value: $0, status: .confirmed) } ?? .absent }
        return ResolvedNote(hanzi: field(hanzi), pinyin: field(pinyin), english: field(english), diagnostics: [])
    }

    private func suggest(_ page: NotePageModel) async throws -> PendingSuggestion {
        page.suggestions.request(for: page.drawing)
        await page.suggestions.task?.value
        return try #require(page.suggestions.pending.first, "\(page.suggestions.status)")
    }

    private func ids(_ drawing: PKDrawing) -> [String] { drawing.strokes.map(InkSelection.identity) }
    private func folder() -> URL { FileManager.default.temporaryDirectory.appending(path: "inline-\(UUID().uuidString)") }

    private func added(_ page: NotePageModel, since ink: PKDrawing) -> [PKStroke] {
        let before = Set(ids(ink))
        return page.drawing.strokes.filter { !before.contains(InkSelection.identity($0)) }
    }

    @Test func onlyTheMissingHanziTonesAndEnglishAreAddedAtTheSizeOfTheWriting() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (page, ink, parts) = try page([Piece(text: "好", x: 80, em: 90, kind: .hanzi), Piece(text: "hao xiang", x: 330, em: 46, kind: .pinyin)],
                                          read: note("好", "hao xiang", nil), folder: dir)
        let item = try await suggest(page)
        #expect(page.replaceSuggestion(item.id, with: item.cleanText, pageWidth: 1180))
        #expect(Array(ids(page.drawing).prefix(ink.strokes.count)) == ids(ink), "the student's strokes are untouched and in place")
        Preview.write(page.drawing, name: "synthetic-hao-xiang")

        let new = added(page, since: ink)
        let hao = InlineReplacement.pathBounds(parts[.hanzi]!), pinyin = InlineReplacement.pathBounds(parts[.pinyin]!)
        let xiang = InlineReplacement.pathBounds(new.filter { InlineReplacement.pathBounds([$0]).maxX < pinyin.minX })
        #expect(xiang.minX >= hao.maxX && xiang.maxX < pinyin.minX, "像 sits between 好 and the Pinyin")
        #expect(abs(xiang.height - hao.height) < 0.25 * hao.height, "像 is the size of 好: \(xiang.height) and \(hao.height)")
        #expect(abs(xiang.maxY - hao.maxY) < 0.2 * hao.height)
        let english = InlineReplacement.pathBounds(new.filter { InlineReplacement.pathBounds([$0]).minX > pinyin.maxX || InlineReplacement.pathBounds([$0]).minY > pinyin.maxY })
        let expected = try #require(CleanHandwriting.bounds(of: "to seem like; to look like", em: 46))
        #expect(english.minX > pinyin.maxX && english.minY < pinyin.maxY, "English follows the Pinyin on its line")
        #expect(!english.isNull && english.height < 1.3 * expected.height && english.height > 0.6 * expected.height, "English at the Pinyin's size")
        let marks = new.filter { let b = InlineReplacement.pathBounds([$0]); return b.midX > pinyin.minX && b.midX < pinyin.maxX && b.maxY < pinyin.midY }
        #expect(marks.count == 2, "one mark for hǎo and one for xiàng: \(marks.count)")

        // Nothing that was added covers anything that was written.
        for stroke in new {
            let box = InlineReplacement.pathBounds([stroke])
            #expect(!ink.strokes.contains { InlineReplacement.pathBounds([$0]).insetBy(dx: 2, dy: 2).intersects(box.insetBy(dx: 1, dy: 1)) })
        }

        // The card, without reading the page again, and asking again offers nothing.
        await page.flashcards.refresh(from: page.drawing, annotations: page.suggestions.annotations).value
        #expect(page.flashcards.cards.map(\.back) == ["hǎoxiàng — to seem like; to look like"])
        page.suggestions.request(for: page.drawing); await page.suggestions.task?.value
        #expect(page.suggestions.pending.isEmpty)

        // Reopened after a relaunch, then restored exactly.
        let reopened = NotePageModel(pageID: "page-1", store: NoteStore(directory: dir), lineReader: Reader(lines: []))
        let receipt = try #require(reopened.latestVisibleReplacement)
        #expect(receipt.hanzi == "好像" && receipt.pinyin == "hǎoxiàng" && receipt.gloss == "to seem like; to look like")
        #expect(reopened.restoreOriginal(receipt.id))
        #expect(ids(reopened.drawing) == ids(ink))
    }

    @Test func pinyinWithTheRightTonesIsLeftAlone() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (page, ink, parts) = try page([Piece(text: "好像", x: 80, em: 90, kind: .hanzi), Piece(text: "hǎo xiàng", x: 330, em: 46, kind: .pinyin)],
                                          read: note("好像", "hǎo xiàng", nil), folder: dir)
        let item = try await suggest(page)
        #expect(page.replaceSuggestion(item.id, with: item.cleanText))
        #expect(Array(ids(page.drawing).prefix(ink.strokes.count)) == ids(ink))
        let pinyin = InlineReplacement.pathBounds(parts[.pinyin]!)
        #expect(added(page, since: ink).allSatisfy { InlineReplacement.pathBounds([$0]).minX > pinyin.maxX || InlineReplacement.pathBounds([$0]).minY > pinyin.maxY })
    }

    @Test func aWrongToneMarkIsSwappedAndTheLettersStay() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        // hào: the mark is the wrong tone. xiàng: right. Only the mark over the a of hào comes off; ǎ goes there.
        let (page, ink, parts) = try page([Piece(text: "好像", x: 80, em: 90, kind: .hanzi),
                                           Piece(text: "hao xiang", x: 330, em: 46, kind: .pinyin, marks: [(1, 4), (6, 4)])],
                                          read: note("好像", "hào xiàng", nil), folder: dir)
        let item = try await suggest(page)
        #expect(page.replaceSuggestion(item.id, with: item.cleanText))
        Preview.write(page.drawing, name: "synthetic-wrong-tones")
        #expect(page.latestVisibleReplacement?.replacement?.isInline == true)
        let now = Set(ids(page.drawing))
        #expect(parts[.hanzi]!.allSatisfy { now.contains(InkSelection.identity($0)) }, "the Hanzi stays")
        let gone = parts[.pinyin]!.filter { !now.contains(InkSelection.identity($0)) }
        #expect(gone.count == 1, "only the wrong mark comes off: \(gone.count)")
        let pinyin = InlineReplacement.pathBounds(parts[.pinyin]!)
        let hao = InlineReplacement.pathBounds(gone)
        #expect(hao.maxY < pinyin.midY && hao.midX < pinyin.midX, "it is the mark over hào")
        let new = added(page, since: ink).map { InlineReplacement.pathBounds([$0]) }
        #expect(new.contains { abs($0.midX - hao.midX) < 12 && $0.maxY < pinyin.midY }, "ǎ where it was")
        #expect(!new.contains { $0.midX > pinyin.midX && $0.midX < pinyin.maxX && $0.maxY < pinyin.midY }, "xiàng was right and is left alone")
        let receipt = try #require(page.latestVisibleReplacement)
        #expect(page.restoreOriginal(receipt.id))
        #expect(ids(page.drawing) == ids(ink))
    }

    @Test func pinyinCutShortGetsOnlyTheMissingSyllableAndTheMeaning() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        // 好像 with only `hao` written: ǎ goes over it, `xiàng` after it with a hand-sized mark, then the dictionary meaning.
        let (_, ink, parts) = try page([Piece(text: "好像", x: 80, em: 90, kind: .hanzi), Piece(text: "hao", x: 330, em: 46, kind: .pinyin)],
                                       read: note("好像", "hao", nil), folder: dir)
        let vocabulary = StarterVocabulary(entries: StarterVocabulary.standard.entries, lexicon: Lexicon.shared)
        let proposal = try #require(vocabulary.phraseProposal(for: note("好像", "hao", nil)))
        #expect(proposal.candidates.first?.gloss == "to seem like; to look like", "a known word gets the same meaning as everywhere else")
        var item = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: "好像 hao", proposal: proposal)
        item.sourceStrokeIDs = Set(ids(ink))
        item.fieldInk = FieldInk(hanzi: Set(parts[.hanzi]!.map(InkSelection.identity)), pinyin: Set(parts[.pinyin]!.map(InkSelection.identity)),
                                 hanziText: "好像", pinyinText: "hao", pinyinWritten: true)
        let plan = try #require(InlineReplacement.plan(for: item, in: ink, pageWidth: 1180), "\(proposal.pinyinState)")
        Preview.write(PKDrawing(strokes: ink.strokes + plan.added), name: "synthetic-cut-short")
        #expect(plan.removed.isEmpty, "every stroke of `hao` stays")
        let hao = InlineReplacement.pathBounds(parts[.pinyin]!)
        let new = plan.added.map { InlineReplacement.pathBounds([$0]) }
        #expect(new.contains { $0.midX > hao.minX && $0.midX < hao.maxX && $0.maxY < hao.midY }, "a mark over hao")
        let after = new.filter { $0.minX > hao.maxX }.reduce(CGRect.null) { $0.union($1) }
        let gloss = try #require(proposal.candidates.first?.gloss)
        let expected = try #require(CleanHandwriting.bounds(of: "xiang " + gloss, em: 46))
        #expect(abs(after.width - expected.width) < 0.25 * expected.width, "xiàng and the meaning, on the line: \(after.width) vs \(expected.width)")
        #expect(after.midY > hao.minY && after.midY < hao.maxY + 20)
        // The mark on the added xiàng is drawn at a hand's size, not the typeface's speck of an accent.
        let xiang = try #require(CleanHandwriting.bounds(of: "xiang", em: 46)).offsetBy(dx: hao.maxX, dy: 0)
        let marks = new.filter { $0.minX > hao.maxX && $0.maxX < hao.maxX + xiang.width + 0.4 * 46 && $0.maxY < hao.midY }
        #expect(marks.contains { $0.width >= 0.2 * 46 }, "a falling mark the size of a hand-written one: \(marks.map(\.width))")
    }

    @Test func dividingAWordAfterWhatWasWritten() {
        #expect(InlineReplacement.divide("hǎoxiàng", after: "hao") == ("hǎo", "xiàng"))
        #expect(InlineReplacement.divide("nóngfū shìjí", after: "nongfushi") == ("nóngfū shì", "jí"))
        #expect(InlineReplacement.divide("hǎoxiàng", after: "haoxiang") == ("hǎoxiàng", ""))
        #expect(InlineReplacement.divide("hǎoxiàng", after: "xiang") == ("hǎoxiàng", ""))
    }

    @Test func aMarkWhereNoneBelongsComesOff() throws {
        // zhīshi: the second syllable is neutral, so the mark over the i of shi comes off and nothing goes back.
        let letters = try #require(CleanHandwriting.drawing(text: "zhi shi", baseline: CGPoint(x: 100, y: 200), em: 46, pen: pen))
        let first = Self.handMark(over: 2, of: "zhi shi", x: 100, baseline: 200, em: 46, tone: 1)
        let second = Self.handMark(over: 6, of: "zhi shi", x: 100, baseline: 200, em: 46, tone: 2)
        let fix = try #require(InlineReplacement.toneMarks(written: "zhī shí", target: "zhīshi", strokes: letters.strokes + [first, second], em: 46, pen: pen))
        #expect(fix.marks.isEmpty, "zhī was right; no mark goes on shi")
        #expect(fix.wrong.map(InkSelection.identity) == [InkSelection.identity(second)])
    }

    @Test func fieldsWrittenAsOneCellAreToldApartByTheGapBetweenThem() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (page, ink, parts) = try page([Piece(text: "好像", x: 80, em: 90, kind: .hanzi), Piece(text: "hao xiang", x: 330, em: 46, kind: .pinyin)],
                                          read: note("好像", "hao xiang", nil), shared: true, folder: dir)
        let item = try await suggest(page)
        #expect(page.replaceSuggestion(item.id, with: item.cleanText))
        #expect(Array(ids(page.drawing).prefix(ink.strokes.count)) == ids(ink))
        let pinyin = InlineReplacement.pathBounds(parts[.pinyin]!)
        let marks = added(page, since: ink).filter { let b = InlineReplacement.pathBounds([$0]); return b.midX > pinyin.minX && b.midX < pinyin.maxX && b.maxY < pinyin.midY }
        #expect(marks.count == 2)
    }

    @Test func withNoRoomForTheHanziTheWholeLineIsReplacedAsBefore() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (page, ink, _) = try page([Piece(text: "好", x: 80, em: 90, kind: .hanzi), Piece(text: "hao xiang", x: 180, em: 46, kind: .pinyin)],
                                      read: note("好", "hao xiang", nil), folder: dir)
        let item = try await suggest(page)
        #expect(page.replaceSuggestion(item.id, with: item.cleanText))
        #expect(page.latestVisibleReplacement?.replacement?.isInline == false)
        #expect(page.restoreOriginal(try #require(page.latestVisibleReplacement).id))
        #expect(ids(page.drawing) == ids(ink))
    }

    @Test func aFullLineRunsTheEnglishPastTheEdgeNotUnderneath() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (page, ink, parts) = try page([Piece(text: "好像", x: 300, em: 90, kind: .hanzi), Piece(text: "hao xiang", x: 540, em: 46, kind: .pinyin)],
                                          read: note("好像", "hao xiang", nil), folder: dir)
        let item = try await suggest(page)
        #expect(page.replaceSuggestion(item.id, with: item.cleanText, pageWidth: 820))
        Preview.write(page.drawing, name: "synthetic-full-line")
        #expect(page.latestVisibleReplacement?.replacement?.isInline == true)
        let all = InlineReplacement.pathBounds(parts.values.flatMap { $0 })
        let pinyin = InlineReplacement.pathBounds(parts[.pinyin]!)
        let new = added(page, since: ink).map { InlineReplacement.pathBounds([$0]) }
        #expect(!new.contains { $0.minY > all.maxY }, "nothing under the note")
        let english = new.filter { $0.minX > pinyin.maxX }.reduce(CGRect.null) { $0.union($1) }
        #expect(english.maxX > 830, "past the edge of the view")
        #expect(english.midY > pinyin.minY && english.midY < pinyin.maxY + 10, "on the Pinyin's line")
    }

    @Test func otherWritingOnTheLineIsSteppedOver() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 600, y: 170), glyphSize: 50)
        let (page, ink, parts) = try page([Piece(text: "好像", x: 80, em: 90, kind: .hanzi), Piece(text: "hao xiang", x: 330, em: 46, kind: .pinyin)],
                                          read: note("好像", "hao xiang", nil), extra: blocker.strokes, folder: dir)
        let item = try await suggest(page)
        #expect(page.replaceSuggestion(item.id, with: item.cleanText))
        Preview.write(page.drawing, name: "synthetic-stepped-over")
        let wall = InlineReplacement.pathBounds(blocker.strokes), pinyin = InlineReplacement.pathBounds(parts[.pinyin]!)
        let english = added(page, since: ink).map { InlineReplacement.pathBounds([$0]) }.filter { $0.minX > pinyin.maxX }
        #expect(!english.isEmpty && english.allSatisfy { !$0.intersects(wall) && $0.minY < pinyin.maxY + 10 })
    }

    @Test func bigWritingKeepsALongMeaningOnItsLine() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (page, ink, parts) = try page([Piece(text: "好像", x: 60, em: 130, kind: .hanzi), Piece(text: "hao xiang", x: 350, em: 100, kind: .pinyin)],
                                          read: note("好像", "hao xiang", nil), folder: dir)
        let item = try await suggest(page)
        #expect(page.replaceSuggestion(item.id, with: item.cleanText))
        Preview.write(page.drawing, name: "synthetic-big")
        #expect(page.latestVisibleReplacement?.replacement?.isInline == true)
        let all = InlineReplacement.pathBounds(parts.values.flatMap { $0 })
        #expect(!added(page, since: ink).contains { InlineReplacement.pathBounds([$0]).minY > all.maxY })
    }

    @Test(arguments: [(120.0, 300.0), (300.0, 120.0)])
    func stackedNotesAreCompletedWhereTheyStand(hanziBaseline: Double, pinyinBaseline: Double) async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (page, ink, parts) = try page([Piece(text: "好", x: 100, em: 90, kind: .hanzi, baseline: hanziBaseline),
                                           Piece(text: "hao xiang", x: 100, em: 46, kind: .pinyin, baseline: pinyinBaseline)],
                                          read: note("好", "hao xiang", nil), folder: dir)
        let item = try await suggest(page)
        #expect(page.replaceSuggestion(item.id, with: item.cleanText, pageWidth: 1180))
        Preview.write(page.drawing, name: hanziBaseline < pinyinBaseline ? "synthetic-stacked-below" : "synthetic-stacked-above")
        #expect(page.latestVisibleReplacement?.replacement?.isInline == true)
        #expect(Array(ids(page.drawing).prefix(ink.strokes.count)) == ids(ink))
        let hao = InlineReplacement.pathBounds(parts[.hanzi]!), pinyin = InlineReplacement.pathBounds(parts[.pinyin]!)
        let boxes = added(page, since: ink).map { InlineReplacement.pathBounds([$0]) }
        #expect(boxes.contains { $0.minX >= hao.maxX && $0.midY > hao.minY && $0.midY < hao.maxY }, "像 beside 好")
        #expect(boxes.filter { $0.maxY < pinyin.midY && $0.maxY > pinyin.minY - 30 && $0.midX > pinyin.minX && $0.midX < pinyin.maxX }.count >= 2, "tone marks")
        #expect(boxes.contains { $0.minX > pinyin.maxX && $0.midY > pinyin.minY - 10 && $0.midY < pinyin.maxY + 10 }, "English on the Pinyin's line")
        #expect(page.restoreOriginal(try #require(page.latestVisibleReplacement).id))
        #expect(ids(page.drawing) == ids(ink))
    }

    @Test func writingInTheWayIsNeverCovered() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 620, y: 150), glyphSize: 90)
        let (page, ink, _) = try page([Piece(text: "好像", x: 80, em: 90, kind: .hanzi), Piece(text: "hao xiang", x: 330, em: 46, kind: .pinyin)],
                                      read: note("好像", "hao xiang", nil), extra: blocker.strokes, folder: dir)
        let item = try await suggest(page)
        #expect(page.replaceSuggestion(item.id, with: item.cleanText))
        #expect(page.latestVisibleReplacement?.replacement?.isInline == true)
        let wall = InlineReplacement.pathBounds(blocker.strokes)
        #expect(added(page, since: ink).allSatisfy { !InlineReplacement.pathBounds([$0]).intersects(wall) })
    }

    @Test func pinyinAloneGetsItsHanziAndEnglish() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (page, ink, parts) = try page([Piece(text: "hǎoxiàng", x: 330, em: 60, kind: .pinyin)], read: note(nil, "hǎoxiàng", nil), folder: dir)
        let item = try await suggest(page)
        #expect(page.replaceSuggestion(item.id, with: item.cleanText))
        Preview.write(page.drawing, name: "synthetic-pinyin-only")
        #expect(Array(ids(page.drawing).prefix(ink.strokes.count)) == ids(ink))
        let pinyin = InlineReplacement.pathBounds(parts[.pinyin]!)
        #expect(added(page, since: ink).contains { InlineReplacement.pathBounds([$0]).maxX < pinyin.minX }, "Hanzi in front")
        #expect(added(page, since: ink).contains { InlineReplacement.pathBounds([$0]).minX > pinyin.maxX || InlineReplacement.pathBounds([$0]).minY > pinyin.maxY })
    }

    @Test func changingTheStudentsInkAfterwardsIsReadAgainAndMakesNoStaleCard() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (page, ink, _) = try page([Piece(text: "好", x: 80, em: 90, kind: .hanzi), Piece(text: "hao xiang", x: 330, em: 46, kind: .pinyin)],
                                      read: note("好", "hao xiang", nil), folder: dir)
        let item = try await suggest(page)
        #expect(page.replaceSuggestion(item.id, with: item.cleanText))
        let complete = page.drawing
        var readable = PageSuggestionModel.readableInk(complete, excluding: page.suggestions.annotations)
        #expect(readable.strokes.isEmpty, "everything on the page is confirmed")
        page.drawingDidChange(PKDrawing(strokes: Array(complete.strokes.dropFirst())))   // one stroke of 好 erased
        readable = PageSuggestionModel.readableInk(page.drawing, excluding: page.suggestions.annotations)
        #expect(readable.strokes.count == ink.strokes.count - 1, "the student's remaining ink is read again, the additions are not")
        await page.flashcards.refresh(from: page.drawing, annotations: page.suggestions.annotations).value
        #expect(!page.flashcards.cards.contains { $0.correction != nil && $0.status == .draft && !$0.needsReview })
        // Undoing the erase makes it current again.
        page.drawingDidChange(complete)
        #expect(PageSuggestionModel.readableInk(page.drawing, excluding: page.suggestions.annotations).strokes.isEmpty)
    }

    @Test func deletingWhatWasAddedNeverDeletesTheStudentsInk() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (page, ink, _) = try page([Piece(text: "好像", x: 80, em: 90, kind: .hanzi),
                                       Piece(text: "hao xiang", x: 330, em: 46, kind: .pinyin, marks: [(1, 4), (6, 4)])],
                                      read: note("好像", "hào xiàng", nil), folder: dir)
        let item = try await suggest(page)
        #expect(page.replaceSuggestion(item.id, with: item.cleanText))
        #expect(page.drawing.strokes.count == ink.strokes.count + added(page, since: ink).count - 1, "the wrong mark is off the page")
        page.deleteReplacement(try #require(page.latestVisibleReplacement).id)
        #expect(ids(page.drawing) == ids(ink))
    }

    @Test func editedTextStillReplacesTheWholeLine() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (page, _, _) = try page([Piece(text: "好", x: 80, em: 90, kind: .hanzi), Piece(text: "hao xiang", x: 330, em: 46, kind: .pinyin)],
                                    read: note("好", "hao xiang", nil), folder: dir)
        let item = try await suggest(page)
        #expect(page.replaceSuggestion(item.id, with: "好像 · hǎoxiàng · as if"))
        #expect(page.latestVisibleReplacement?.replacement?.isInline == false)
    }

    /// Many sizes, gaps, slopes and neighbours: whatever Replace decides, the same promises hold.
    @Test func inEveryLayoutTheStudentsInkStaysNothingIsCoveredAndRestoreIsExact() async throws {
        struct Seeded: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state ^ (state >> 29) }
        }
        var random = Seeded(state: 29)
        var inPlace = 0
        let notes: [(String?, String?, String?)] = [("好", "hao xiang", nil), ("好像", "hao xiang", nil), ("好像", "hǎo xiàng", nil), ("好像", nil, "to look like"),
                                                    ("好像", "hào xiàng", nil), (nil, "hǎoxiàng", nil), ("好像", nil, nil), ("好", "hǎo xiang", "to look like")]
        for round in 0..<40 {
            let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
            let (hanzi, pinyin, english) = notes[round % notes.count]
            let em = CGFloat.random(in: 40...120, using: &random), small = em * CGFloat.random(in: 0.4...0.9, using: &random)
            var x = CGFloat.random(in: 20...200, using: &random), baseline = CGFloat.random(in: 180...320, using: &random)
            var pieces: [Piece] = []
            for (text, size, kind) in [(hanzi, em, NoteGrouping.FieldKind.hanzi), (pinyin, small, .pinyin), (english, small, .english)] {
                guard let text else { continue }
                // The note read as hào xiàng is written untoned with hand-sized marks, as a student would.
                let marked = text == "hào xiàng"
                pieces.append(Piece(text: marked ? "hao xiang" : text, x: x, em: size, kind: kind, baseline: baseline, marks: marked ? [(1, 4), (6, 4)] : []))
                x += (CleanHandwriting.bounds(of: text, em: size)?.width ?? 0) + CGFloat.random(in: 0.2...2.2, using: &random) * em
                baseline += CGFloat.random(in: -0.15...0.15, using: &random) * em
            }
            let blockers = Bool.random(using: &random) ? SyntheticInk.drawing(writing: "大人", origin: CGPoint(x: .random(in: 0...700, using: &random), y: .random(in: 300...460, using: &random)), glyphSize: 60).strokes : []
            let (page, ink, parts) = try page(pieces, read: note(hanzi, pinyin, english), extra: blockers, folder: dir)
            page.suggestions.request(for: page.drawing); await page.suggestions.task?.value
            guard let item = page.suggestions.pending.first else { continue }
            #expect(page.replaceSuggestion(item.id, with: item.cleanText, pageWidth: round.isMultiple(of: 2) ? 820 : 1180))
            let receipt = try #require(page.latestVisibleReplacement)
            if receipt.replacement?.isInline == true {
                inPlace += 1
                let now = Set(ids(page.drawing))
                for (kind, strokes) in parts where kind != .pinyin {
                    #expect(strokes.allSatisfy { now.contains(InkSelection.identity($0)) }, "round \(round): \(kind) ink changed")
                }
                // The letters were right in every note, so at most a wrong tone mark comes off, never a letter.
                #expect((parts[.pinyin] ?? []).filter { !now.contains(InkSelection.identity($0)) }.count <= 1, "round \(round): Pinyin rewritten")
                #expect(blockers.allSatisfy { now.contains(InkSelection.identity($0)) })
                let staying = ink.strokes.filter { now.contains(InkSelection.identity($0)) }.map { InlineReplacement.pathBounds([$0]) }
                for stroke in added(page, since: ink) {
                    let box = InlineReplacement.pathBounds([stroke])
                    #expect(box.minX >= 0 && box.minY >= 0, "round \(round): off the page")
                    // A tone mark may reach over a neighbouring letter's column, never onto ink.
                    #expect(!staying.contains { $0.insetBy(dx: 2, dy: 2).contains(CGPoint(x: box.midX, y: box.midY)) } || box.height < 0.3 * small,
                            "round \(round): covers the student's writing")
                }
                #expect(receipt.hanzi?.isEmpty == false && receipt.pinyin?.isEmpty == false)
                #expect(PageSuggestionModel.readableInk(page.drawing, excluding: page.suggestions.annotations).strokes.count == blockers.count)
            }
            #expect(page.restoreOriginal(receipt.id))
            #expect(ids(page.drawing) == ids(ink), "round \(round): Restore is not exact")
        }
        print("INLINE layouts in place: \(inPlace) of 40")
        #expect(inPlace >= 20)
    }

    @Test func replacementsSavedByEarlierBuildsStillOpen() throws {
        let old = Data(#"{"originalInk":"","originalIndices":[0],"replacementStrokeIDs":["a"]}"#.utf8)
        #expect(try JSONDecoder().decode(InkReplacement.self, from: old).isInline == false)
    }
}

/// Renders a page for a person to look at. Written beside the repository, never into it.
@MainActor
enum Preview {
    static func write(_ drawing: PKDrawing, name: String) {
        let folder = PrivateReplayTests.folder
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let previews = folder.appending(path: "previews")
        try? FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        let area = drawing.bounds.insetBy(dx: -24, dy: -24)
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { image = drawing.image(from: area, scale: 1.5) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: image.size.width, height: image.size.height)
        let composite = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            image.draw(at: .zero)
        }
        try? composite.pngData()?.write(to: previews.appending(path: "\(name).png"))
    }
}
