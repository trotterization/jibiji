import CoreGraphics
import CryptoKit
import Foundation
import Observation
import PencilKit

/// One flashcard on a page. Stored apart from the ink.
struct PageFlashcard: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case draft, approved, discarded }

    var id: UUID
    var front: String
    var back: String
    var kind: FlashcardKind
    var sourceText: String
    var needsReview: Bool
    /// Where the source line sat on the page (drawing coordinates).
    var sourceBounds: CGRect
    /// SHA256 (hex) of the drawing bytes this card was read from.
    var inkDigest: String
    var status: Status
    var edited: Bool
    /// Stable identity from the originally extracted front/back/kind. Set once; never changes on edit.
    /// Optional so files saved before this field existed still load (filled in on load).
    var dedupeKey: String? = nil
    /// Set when the card came from an accepted inline correction. Optional for older files.
    var correction: CardCorrection? = nil
}

/// Links a card to the accepted note it was built from.
struct CardCorrection: Codable, Equatable {
    var annotationID: UUID
    /// Recognized line text + Hanzi: identifies the same correction if the note is re-accepted with new wording.
    var slot: String
    /// Hanzi, pinyin and accepted gloss at the time of generation.
    var signature: String
}

/// On-disk form: `<pageID>.flashcards.json` beside `<pageID>.drawing`.
struct PageFlashcardFile: Codable, Equatable {
    var version = 1
    var pageID: String
    var cards: [PageFlashcard]
}

@MainActor
@Observable
final class PageFlashcards {
    enum Status: Equatable {
        case idle
        case reading
        case message(String)
    }

    let pageID: String
    private(set) var cards: [PageFlashcard] = []
    private(set) var status: Status = .idle
    /// Set when the saved file couldn't be read. The file is left untouched and nothing is saved over it.
    private(set) var loadError: String?
    private(set) var currentDigest: String?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let reader: any InkLineReader
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var canSave = true
    @ObservationIgnored private var saveFailed = false
    /// Exposed so tests can wait for a refresh.
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(pageID: String, store: NoteStore, reader: any InkLineReader = PencilInkLineReader(mode: .primaryOnly)) {
        self.pageID = pageID
        self.reader = reader
        self.fileURL = Self.fileURL(pageID: pageID, store: store)
        load()
    }

    static func fileURL(pageID: String, store: NoteStore) -> URL {
        store.directory.appending(path: "\(pageID).flashcards.json", directoryHint: .notDirectory)
    }

    // MARK: - Derived lists

    func isCurrent(_ card: PageFlashcard) -> Bool { currentDigest != nil && card.inkDigest == currentDigest }
    /// Drafts awaiting review, from the current ink.
    var currentDrafts: [PageFlashcard] { cards.filter { $0.status == .draft && isCurrent($0) } }
    /// Approved cards from the current ink.
    var approvedCurrent: [PageFlashcard] { cards.filter { $0.status == .approved && isCurrent($0) } }
    /// Non-discarded cards that no longer match the ink. Kept visible; never exported.
    var staleCards: [PageFlashcard] { cards.filter { $0.status != .discarded && !isCurrent($0) } }
    var staleCount: Int { staleCards.count }

    // MARK: - Digest

    nonisolated static func digest(of drawing: PKDrawing) -> String {
        // Hash the stroke content, not `dataRepresentation()`: PencilKit's bytes carry per-instance identity,
        // so two equal drawings (even two empty ones) serialize differently. Exact geometry still changes the hash.
        var hasher = SHA256()
        func add(_ values: CGFloat...) {
            for v in values { withUnsafeBytes(of: Double(v).bitPattern) { hasher.update(bufferPointer: $0) } }
        }
        for stroke in drawing.strokes {
            hasher.update(data: Data("\(stroke.ink.inkType.rawValue)".utf8))
            var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            stroke.ink.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let t = stroke.transform
            add(r, g, b, a, t.a, t.b, t.c, t.d, t.tx, t.ty)
            for p in stroke.path {
                add(p.location.x, p.location.y, p.timeOffset, p.size.width, p.size.height,
                    p.opacity, p.force, p.azimuth, p.altitude)
            }
            // Bitmap erasing only changes the mask, so it must be part of the identity.
            hasher.update(data: Data([0xFE]))
            if let mask = stroke.mask {
                hasher.update(data: Data([0x01]))
                mask.cgPath.applyWithBlock { elementPtr in
                    let element = elementPtr.pointee
                    let count: Int
                    switch element.type {
                    case .moveToPoint: count = 1
                    case .addLineToPoint: count = 1
                    case .addQuadCurveToPoint: count = 2
                    case .addCurveToPoint: count = 3
                    case .closeSubpath: count = 0
                    @unknown default: count = 0
                    }
                    hasher.update(data: Data([0xFD, UInt8(truncatingIfNeeded: element.type.rawValue), UInt8(count)]))
                    for i in 0..<count { add(element.points[i].x, element.points[i].y) }
                }
            } else {
                hasher.update(data: Data([0x00]))
            }
            hasher.update(data: Data([0xFF]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Call when the ink changes: cancels any running read, so its result can't be applied.
    func inkChanged(_ drawing: PKDrawing) {
        currentDigest = Self.digest(of: drawing)
        generation += 1
        task?.cancel()
        task = nil
        if status == .reading { status = .idle }
    }

    // MARK: - Refresh

    /// Reads the page's lines and adds new drafts. Returns the running task (also in `task`).
    @discardableResult
    func refresh(from drawing: PKDrawing, annotations: [AcceptedAnnotation] = []) -> Task<Void, Never> {
        inkChanged(drawing)
        // Hidden notes (their ink is erased) are ignored.
        let corrections = annotations.filter { PageSuggestionModel.isVisible($0, in: drawing) }
        let digest = currentDigest!
        let token = generation
        status = .reading
        let reader = reader
        let newTask = Task { [weak self] in
            let result: Result<[RecognizedLine], Error>
            do { result = .success(try await reader.lines(in: drawing)) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            switch result {
            case .success(let lines):
                let added = self.merge(lines: lines, digest: digest, corrections: corrections)
                // Don't overwrite a save error from the merge.
                if let loadError = self.loadError {
                    self.status = .message(loadError)
                } else if !self.saveFailed {
                    self.status = lines.isEmpty ? .message("No writing found on this page.")
                        : added == 0 ? .message("No new cards found.") : .idle
                }
            case .failure(let error):
                self.status = error is CancellationError ? .idle
                    : .message(error is InkLineReaderError ? error.localizedDescription : "Couldn't read this page right now.")
            }
            self.task = nil
        }
        task = newTask
        return newTask
    }

    /// Adds drafts for `lines`; returns how many were new. Also usable directly with injected lines.
    @discardableResult
    func merge(lines: [RecognizedLine], digest: String, corrections: [AcceptedAnnotation] = [],
               vocabulary: StarterVocabulary = .standard) -> Int {
        // A replacement is already confirmed text. Don't ask a stroke recognizer
        // to reinterpret the glyph-fill paths and override what the student approved.
        let replacements = corrections.filter { $0.replacement != nil }
        let lines = lines.filter { line in
            !replacements.contains { note in
                let overlap = note.anchor.intersection(line.bounds)
                return !overlap.isNull && overlap.width * overlap.height >= line.bounds.width * line.bounds.height * 0.5
            }
        } + replacements.map { RecognizedLine(text: $0.text, bounds: $0.anchor) }
        var added = 0
        var claimedLines = Set<Int>()
        var activeNotes = Set<UUID>()
        var usedCards = Set<UUID>()
        for note in corrections {
            // Exact source text only; if several lines match, the one overlapping the note's anchor most.
            let match = lines.indices.filter { (note.replacement != nil ? lines[$0].text == note.text : lines[$0].rawText == note.recognizedText) && note.anchor.intersects(lines[$0].bounds) }
                .max { Self.overlap(note.anchor, lines[$0].bounds) < Self.overlap(note.anchor, lines[$1].bounds) }
            guard let li = match, let r = Self.resolve(note, line: lines[li], vocabulary: vocabulary) else { continue }
            claimedLines.insert(li)
            activeNotes.insert(note.id)
            let line = lines[li]
            let back = r.pinyin.map { "\($0) — \(r.gloss)" } ?? r.gloss
            let slot = "\(line.rawText)\u{1F}\(r.hanzi)"
            let correction = CardCorrection(annotationID: note.id, slot: slot, signature: "\(r.hanzi)|\(r.pinyin ?? "")|\(r.gloss)")
            let key = Self.dedupeKey(front: r.hanzi, back: back, kind: .vocabulary)
            let i = cards.indices.first { !usedCards.contains(cards[$0].id) && cards[$0].correction?.annotationID == note.id }
                ?? cards.indices.first { !usedCards.contains(cards[$0].id) && cards[$0].correction?.slot == slot }
                ?? cards.indices.first { !usedCards.contains(cards[$0].id) && cards[$0].correction == nil && cards[$0].sourceText == line.rawText }
                ?? cards.indices.first { !usedCards.contains(cards[$0].id) && (cards[$0].dedupeKey ?? Self.dedupeKey(front: cards[$0].front, back: cards[$0].back, kind: cards[$0].kind)) == key }
            guard let i else {
                let card = PageFlashcard(id: UUID(), front: r.hanzi, back: back, kind: .vocabulary, sourceText: line.rawText,
                                         needsReview: false, sourceBounds: line.bounds, inkDigest: digest,
                                         status: .draft, edited: false, dedupeKey: key, correction: correction)
                cards.append(card)
                usedCards.insert(card.id)
                added += 1
                continue
            }
            usedCards.insert(cards[i].id)
            if cards[i].correction?.signature == correction.signature {
                if cards[i].inkDigest != digest {
                    if cards[i].status == .approved { cards[i].status = .draft }
                    cards[i].inkDigest = digest
                    cards[i].sourceBounds = line.bounds
                }
            } else if cards[i].status != .discarded {
                // The accepted source changed: re-draft. Explicit card edits are kept, but flagged.
                if cards[i].edited {
                    cards[i].needsReview = true
                } else {
                    cards[i].front = r.hanzi
                    cards[i].back = back
                    cards[i].kind = .vocabulary
                    cards[i].needsReview = false
                    cards[i].dedupeKey = key
                }
                cards[i].status = .draft
                cards[i].inkDigest = digest
                cards[i].sourceBounds = line.bounds
                cards[i].sourceText = line.rawText
            }
            cards[i].correction = correction
        }
        // Cards built from a note that no longer matches are re-drafted and flagged; they stay visible.
        for i in cards.indices {
            guard let c = cards[i].correction, !activeNotes.contains(c.annotationID),
                  !usedCards.contains(cards[i].id), cards[i].status != .discarded else { continue }
            cards[i].status = .draft
            cards[i].needsReview = true
        }
        for (index, line) in lines.enumerated() where !claimedLines.contains(index) {
            guard let draft = FlashcardExtractor.extract(from: line.text) else { continue }
            let key = Self.dedupeKey(front: draft.front, back: draft.back, kind: draft.kind)
            if let i = cards.firstIndex(where: { ($0.dedupeKey ?? Self.dedupeKey(front: $0.front, back: $0.back, kind: $0.kind)) == key }) {
                // Same card seen again: keep edits, re-anchor to this ink.
                if cards[i].inkDigest != digest {
                    // Ink changed since it was approved: it must be approved again.
                    if cards[i].status == .approved { cards[i].status = .draft }
                    cards[i].inkDigest = digest
                    cards[i].sourceBounds = line.bounds
                }
                cards[i].dedupeKey = key
                continue
            }
            cards.append(PageFlashcard(
                id: UUID(), front: draft.front, back: draft.back, kind: draft.kind,
                sourceText: draft.sourceText, needsReview: draft.needsReview || line.needsReview,
                sourceBounds: line.bounds, inkDigest: digest, status: .draft, edited: false,
                dedupeKey: key
            ))
            added += 1
        }
        save()
        return added
    }

    /// Approved correction-backed cards whose note is no longer on the page go back to flagged drafts,
    /// so a removed/undone note can't be exported. Other cards are untouched.
    func invalidateRemovedCorrections(activeIDs: Set<UUID>) {
        var changed = false
        for i in cards.indices {
            guard let c = cards[i].correction, cards[i].status == .approved,
                  !activeIDs.contains(c.annotationID) else { continue }
            cards[i].status = .draft
            cards[i].needsReview = true
            changed = true
        }
        if changed { save() }
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width * r.height
    }

    /// Hanzi, pronunciation and the user-approved English for a note. Nil if the note carries no usable gloss.
    /// Structured metadata wins; older notes are read from their text only when that is unambiguous.
    static func resolve(_ note: AcceptedAnnotation, line: RecognizedLine, vocabulary: StarterVocabulary)
        -> (hanzi: String, pinyin: String?, gloss: String)? {
        func clean(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            return t?.isEmpty == false ? t : nil
        }
        if let hanzi = clean(note.hanzi) {
            guard let gloss = clean(note.gloss) else { return nil }
            return (hanzi, clean(note.pinyin), gloss)
        }
        // Legacy note: only `text`.
        let first = AcceptedAnnotation.parse(note.text, knownPinyin: nil)
        let hanzi = first.hanzi ?? vocabulary.proposal(forRecognizedText: line.rawText)?.candidates.first?.hanzi
        guard let hanzi else { return nil }
        let entry = vocabulary.entries.first { $0.hanzi == hanzi }
        let parsed = AcceptedAnnotation.parse(note.text, knownPinyin: entry?.pinyin)
        guard !parsed.ambiguous, parsed.glossParts.count == 1, let gloss = clean(parsed.glossParts[0]) else { return nil }
        return (hanzi, entry?.pinyin, gloss)
    }

    static func dedupeKey(front: String, back: String, kind: FlashcardKind) -> String {
        func norm(_ s: String) -> String {
            s.precomposedStringWithCanonicalMapping.lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return "\(kind)\u{1F}\(norm(front))\u{1F}\(norm(back))"
    }

    // MARK: - Review

    /// Blank front or back is declined; the card is left unchanged.
    func edit(_ id: UUID, front: String, back: String) {
        guard let i = cards.firstIndex(where: { $0.id == id }),
              !front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cards[i].front = front
        cards[i].back = back
        cards[i].edited = true
        cards[i].needsReview = false
        save()
    }

    /// Approves a card. Stale cards can't be approved; they no longer match the ink.
    func approve(_ id: UUID) {
        guard let i = cards.firstIndex(where: { $0.id == id }), isCurrent(cards[i]) else { return }
        let card = cards[i]
        guard !card.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !card.back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cards[i].status = .approved
        cards[i].needsReview = false
        save()
    }

    func discard(_ id: UUID) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].status = .discarded
        save()
    }

    /// Returns a discarded or approved card to draft.
    func restoreToDraft(_ id: UUID) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].status = .draft
        save()
    }

    // MARK: - Export

    /// Quizlet import text: `front<TAB>back` per line, `\n` between cards, approved current cards only.
    /// Tabs and line breaks inside a field become spaces; all other Unicode is kept as written.
    var quizletExport: String { Self.quizletText(for: approvedCurrent) }

    var quizletData: Data { Data(quizletExport.utf8) }

    static func quizletText(for cards: [PageFlashcard]) -> String {
        cards.map { "\(sanitize($0.front))\t\(sanitize($0.back))" }.joined(separator: "\n")
    }

    static func sanitize(_ field: String) -> String {
        var out = ""
        var lastWasSpace = false
        for ch in field.trimmingCharacters(in: .whitespacesAndNewlines) {
            // Character groups "\r\n" as one, so this covers CRLF too.
            let isSeparator = ch == "\t" || ch.isNewline
                || ch.unicodeScalars.contains { $0 == "\u{2028}" || $0 == "\u{2029}" }
            if isSeparator {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = ch == " "
            }
        }
        return out
    }

    // MARK: - Storage

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            fail(error)
            return
        }
        do {
            let file = try JSONDecoder().decode(PageFlashcardFile.self, from: data)
            guard file.version == 1, file.pageID == pageID else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // Migrate older files: derive the key from what was stored.
            cards = file.cards.map { c in
                var c = c
                if c.dedupeKey == nil { c.dedupeKey = Self.dedupeKey(front: c.front, back: c.back, kind: c.kind) }
                return c
            }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: any Error) {
        canSave = false
        loadError = "Saved flashcards (\(fileURL.lastPathComponent)) couldn't be read, so changes won't be saved. The file is untouched."
        status = .message(loadError ?? "")
    }

    private func save() {
        guard canSave else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(PageFlashcardFile(pageID: pageID, cards: cards)).write(
                to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            saveFailed = false
        } catch {
            saveFailed = true
            status = .message("Couldn't save flashcards.")
        }
    }
}
