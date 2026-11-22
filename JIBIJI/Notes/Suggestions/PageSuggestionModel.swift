import CoreGraphics
import Foundation
import Observation
import OSLog
import PencilKit

/// A line of ink and what the recognizer read from it. `bounds` are in page (drawing) coordinates.
struct RecognizedLine: Sendable, Equatable {
    var text: String
    var bounds: CGRect
    /// Original PencilKit text, only when `text` was refined by a second pass.
    var sourceText: String? = nil
    /// Image-recognition readings for user confirmation, not dictionary meanings.
    var readings: [String] = []
    var rawText: String { sourceText ?? text }
    /// Other readings of the same ink (another engine), used only to cross-check the primary reading.
    var alternatives: [String] = []
    /// Set by ``crossChecked()``: the readings disagreed and nothing settled it.
    var needsReview = false
    var reviewNote: String? = nil
    /// The text was corrected from another reading, or is unresolved: no ink edit is offered for this line.
    var inkEditSuppressed = false
    /// When the line is a grouped note: the indices (in the drawing the reader was given) of exactly the strokes
    /// it was read from. Nil for a line read by bounds alone.
    var strokeIndices: [Int]? = nil
    /// The validated Hanzi / Pinyin / English of a grouped note. Suggest and cards both read this, nothing else.
    var resolved: ResolvedNote? = nil
    /// Other texts this note was known by (the grouping's own composed reading), so notes accepted by text still match.
    var alsoRead: [String] = []
    func wasRead(as text: String) -> Bool { rawText == text || alsoRead.contains(text) }

    /// Compares this line's readings (``alternatives`` and ``readings``) before anything is drafted or edited.
    /// The ink itself is never touched. `rawText` stays what the primary recognizer read.
    func crossChecked(vocabulary: StarterVocabulary = .standard) -> RecognizedLine {
        let outcome = ReadingCrossCheck.resolve(primary: text, alternatives: alternatives + readings, vocabulary: vocabulary)
        guard outcome.status != .agreed else { return self }
        var line = self
        if outcome.status == .corrected {
            line.sourceText = sourceText ?? text
            line.text = outcome.text
        } else {
            line.needsReview = true
        }
        // Keep any doubt already attached (for example from grouping) beside this one.
        line.reviewNote = [reviewNote, outcome.note].compactMap { $0 }.joined(separator: " ")
        line.inkEditSuppressed = true
        return line
    }
}

/// Reads the text of each written line. Injected so tests don't need PencilKit recognition.
protocol InkLineReader: Sendable {
    func lines(in drawing: PKDrawing) async throws -> [RecognizedLine]
}

enum InkLineReaderError: Error, LocalizedError, Equatable {
    case unsupported
    var errorDescription: String? { "On-device handwriting recognition needs iPadOS 27." }
}

/// Prefer native stroke recognition, with a Chinese image fallback where it is unavailable.
struct PencilInkLineReader: InkLineReader {
    enum Mode: Sendable {
        /// Primary text for flashcards; image fallback if Chinese stroke recognition is unavailable.
        case primaryOnly
        /// Suggestions: DEBUG builds may add the bounded Hanzi-prefix Paddle second pass.
        case suggestions
    }

    var mode: Mode = .suggestions

    func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] {
        guard !drawing.strokes.isEmpty else { return [] }
        if UserDefaults.standard.bool(forKey: "JibijiUsePaddlePipeline") {
            let detected = try await PaddleTextPipeline.shared.lines(in: drawing)
            var result: [RecognizedLine] = []
            for var line in detected {
                try Task.checkCancellation()
                let indices = InkSelection.indices(in: drawing, bounds: line.bounds)
                if !indices.isEmpty {
                    let crop = PKDrawing(strokes: indices.map { drawing.strokes[$0] })
                    let readings = (try? await VisionInkReader.shared.lineReadings(in: crop)) ?? []
                    for text in readings where !line.readings.contains(text) { line.readings.append(text) }
                }
                result.append(line)
            }
            try Task.checkCancellation()
            return RecognitionCrossCheck.resolve(result)
        }
        // One reader for Suggest and Cards: the same evidence collector for every cell, field region and whole note.
        // The simulator exposes English-only stroke recognition; there Vision (and Paddle in Debug) supply the evidence.
        let supportsChinese: Bool = {
            guard #available(iOS 27.0, *) else { return false }
            return PKStrokeRecognizer.supportedLanguages.contains(where: { $0.maximalIdentifier.hasPrefix("zh-Hans") })
        }()
        guard NoteReading.isEnabled || supportsChinese else { return try await VisionInkReader.shared.lines(in: drawing) }
        var recognizer: Any?
        if supportsChinese, #available(iOS 27.0, *) {
            let r = PKStrokeRecognizer(preferredLanguages: RecognitionProbe.preferredLanguages)
            await r.updateDrawing(drawing)
            recognizer = r
        }
        if NoteReading.isEnabled {
            let recognizer = recognizer
            return try await NoteReading.lines(
                in: drawing,
                readRegion: { strokes in await Self.evidence(for: strokes, recognizer: recognizer) },
                readCell: { strokes, _ in
                    let evidence = await Self.evidence(for: strokes, recognizer: recognizer)
                    guard let primary = Self.primary(of: evidence) else { return nil }
                    return NoteReading.CellRead(text: primary, evidence: evidence)
                })
        }
        guard #available(iOS 27.0, *), let recognizer = recognizer as? PKStrokeRecognizer else { return try await VisionInkReader.shared.lines(in: drawing) }
        var result: [RecognizedLine] = []
        for group in InkLineGeometry.lineGroups(in: drawing) where !group.isEmpty {
            try Task.checkCancellation()
            let strokes = group.map { drawing.strokes[$0] }
            let bounds = strokes.dropFirst().reduce(strokes[0].renderBounds) { $0.union($1.renderBounds) }
            guard bounds.minX.isFinite, bounds.maxY.isFinite, bounds.width.isFinite, bounds.height.isFinite else { continue }
            let text = await recognizer.recognizedText(strokeIDs: Set(strokes.map(\.id)))
            if let raw = text, !raw.isEmpty {
                var text = raw
                if mode == .suggestions { text = await HanziPrefixFallback.resolve(primary: raw, strokes: strokes) }
                let readings = (try? await VisionInkReader.shared.lineReadings(in: PKDrawing(strokes: strokes))) ?? []
                try Task.checkCancellation()
                result.append(RecognizedLine(text: text, bounds: bounds, sourceText: text == raw ? nil : raw,
                                             readings: readings)) }

        }
        return result
    }
}

extension PencilInkLineReader {
    /// Every engine's reading of exactly these strokes, tagged by engine. Raw evidence, not yet validated.
    static func evidence(for strokes: [PKStroke], recognizer: Any?) async -> [NoteEvidence.Reading] {
        var out: [NoteEvidence.Reading] = []
        #if DEBUG
        let started = Date()
        print("EVIDENCE start strokes=\(strokes.count) recognizer=\(recognizer != nil)")
        defer { print("EVIDENCE done \(String(format: "%.2f", Date().timeIntervalSince(started)))s readings=\(out.map { "\($0.engine.rawValue):\($0.text)" })") }
        #endif
        /// The first reading of an engine is its answer; the rest are its lower-ranked guesses (diagnostic only).
        func add(_ texts: [String], _ engine: NoteEvidence.Engine) {
            var first = true
            for text in texts {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, !out.contains(where: { $0.text == t && $0.engine == engine }) else { continue }
                out.append(.init(text: t, engine: engine, scope: .cell, alternate: !first))
                first = false
            }
        }
        let ink = PKDrawing(strokes: strokes)
        if #available(iOS 27.0, *), let recognizer = recognizer as? PKStrokeRecognizer,
           let raw = await recognizer.recognizedText(strokeIDs: Set(strokes.map(\.id))) { add([raw], .pencilKit) }
        add((try? await VisionInkReader.shared.lineReadings(in: ink, includeMobileModel: false)) ?? [], .vision)
        #if DEBUG
        print("EVIDENCE vision done, paddle next")
        // The model's plain best reading first (the one "Run Pinyin OCR by line" shows), then the beam-search guesses.
        // The beam's top string can differ from the plain reading; the guesses stay diagnostics.
        // The larger Paddle model is a separate reader (the first result of "Run Pinyin OCR by line"); it reads short
        // Pinyin better than the mobile model, so its answer counts as its own evidence.
        add(await PinyinOCR.shared.recognize(ink).text.map { [$0] } ?? [], .paddleServer)
        let plain = await PinyinOCR.shared.recognizeMobile(ink).text.map { [$0] } ?? []
        add(plain + (await PinyinOCR.shared.readings(ink)), .paddle)
        #endif
        return out
    }

    /// The reading grouping uses to decide what kind of writing a cell holds. PencilKit, then Vision, then Paddle,
    /// except that a Latin reading with garbled tone marks yields to another reading that is valid Pinyin.
    static func primary(of evidence: [NoteEvidence.Reading]) -> String? {
        let all = ["PencilKit", "Vision", "PaddleServer", "Paddle", "reader"].flatMap { name in evidence.filter { $0.engine.rawValue == name } }
        let ordered0 = all.filter { !$0.alternate }
        // Digit-and-letter soup (`n4O`) is noise from a recognizer reading ink it cannot read; prefer any well-formed reading.
        let usable = ordered0.filter { ReadingValidation.isWellFormed($0.text) }
        let ordered = usable.isEmpty ? ordered0 : usable
        guard let first = ordered.first else { return nil }
        func malformed(_ text: String) -> Bool {
            StarterVocabulary.hanzi(in: text).isEmpty && FieldValidation.words(text).contains { FieldValidation.kind(of: $0) == .pinyinMalformed }
        }
        func validPinyin(_ text: String) -> Bool {
            StarterVocabulary.hanzi(in: text).isEmpty && PinyinValidator.analyze(words: FieldValidation.words(text)).isToned
        }
        if malformed(first.text), let better = ordered.first(where: { validPinyin($0.text) }) { return better.text }
        // Plain Pinyin read alike by two other engines (`nong fu shi ji`) outvotes one engine's reading of the same ink that
        // is not Pinyin at all (`none fu she ji`). Otherwise that misreading files the Pinyin as English and the note splits.
        func syllables(_ text: String) -> Bool {
            let words = FieldValidation.words(text).filter { $0.contains(where: \.isLetter) }
            return StarterVocabulary.hanzi(in: text).isEmpty && !words.isEmpty
                && words.allSatisfy { NoteGrouping.isSyllable(StarterVocabulary.latinTokens($0).joined()) }
        }
        if StarterVocabulary.hanzi(in: first.text).isEmpty, !syllables(first.text) {
            let voters = Dictionary(grouping: ordered.filter { $0.engine != first.engine && syllables($0.text) },
                                    by: { FieldValidation.letters(FieldValidation.words($0.text)) })
            if let agreed = voters.values.filter({ Set($0.map(\.engine)).count >= 2 }).max(by: { $0.count < $1.count }) {
                return agreed[0].text
            }
        }
        return first.text
    }
}

/// A provisional suggestion next to one line of ink. Never part of the ink.
struct PendingSuggestion: Identifiable, Equatable {
    let id = UUID()
    /// Ink revision this was computed from; it is dropped when the ink changes.
    let revision: Int
    var anchor: CGRect
    var recognizedText: String
    /// Original PencilKit text, only when `recognizedText` was refined.
    var sourceText: String? = nil
    var proposal: SuggestionProposal
    var selectedIndex = 0
    var sourceStrokeIDs: Set<String> = []
    /// Why this line's reading is uncertain beyond its Pinyin (e.g. two recognizers disagree). Never edits ink.
    var readingNote: String? = nil
    var inkEditSuppressed = false

    var candidate: SuggestionCandidate { proposal.candidates[selectedIndex] }

    /// Includes missing supported fields and preserves the student's written Pinyin and English.
    var cleanText: String { replacementText }

    var replacementText: String {
        guard !candidate.pinyin.isEmpty || !candidate.gloss.isEmpty else { return candidate.hanzi }
        // Replace writes the dictionary word, so its Pinyin is always the word's own tone-marked reading. Pinyin as the
        // readers resolved it (`nong fo shi ji`: untoned, misspelled or misread) never reaches the page. Any difference
        // from what was written is shown in the caveat, and Restore brings the student's ink back.
        let pinyin = candidate.pinyin
        let gloss = selectedIndex == 0 ? proposal.writtenGloss ?? candidate.gloss : candidate.gloss
        return [candidate.hanzi, pinyin, gloss].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var hasAlternatives: Bool { proposal.candidates.count > 1 }

    /// Plain-language caveat shown with the suggestion, or nil when the writing needs none.
    var uncertaintyNote: String? {
        if let readingNote { return readingNote }
        guard selectedIndex == 0 else {
            return proposal.pinyinState.isUncertain ? "The line as written was uncertain. Check this alternative before replacing; Restore brings your ink back." : nil
        }
        switch proposal.pinyinState {
        case .wrongTones(let written):
            return "Tone marks differ from “\(candidate.pinyin)” (you wrote “\(written)”). Check before accepting."
        case .possibleSpelling(let written) where proposal.pinyinFromDictionary:
            let fits = proposal.hanziAlreadyWritten || !proposal.hanziPrefixWritten.isEmpty ? "it and your Hanzi" : "it"
            return "Your Pinyin “\(written)” couldn't be read reliably. The dictionary word that fits \(fits) is “\(candidate.hanzi)” (\(candidate.pinyin)). Check it before replacing."
        case .possibleSpelling(let written):
            return "Unsure: “\(written)” is close to “\(candidate.pinyin)”. It may be a spelling slip or a misread. Your ink is unchanged."
        default: return nil
        }
    }

    /// Replace is always offered (the student's decision). The chip previews exactly the text it writes, an uncertain
    /// reading shows its caveat (`uncertaintyNote`), and Restore brings the original strokes back.
    var allowsInkReplacement: Bool { true }

    /// The note to add beside the ink: Hanzi unless already written, then the gloss unless already written.
    var annotationText: String {
        // An alternative is a different word: its note is always complete and never relies on what the
        // primary's Hanzi/gloss flags say is already written.
        if candidate.pinyin.isEmpty && candidate.gloss.isEmpty { return candidate.hanzi }
        if selectedIndex > 0 { return "\(candidate.hanzi) · (\(candidate.pinyin)) · \(candidate.gloss)" }
        var parts: [String] = []
        if !proposal.hanziAlreadyWritten {
            let prefix = proposal.hanziPrefixWritten
            if !prefix.isEmpty, candidate.hanzi.hasPrefix(prefix) {
                parts.append(String(candidate.hanzi.dropFirst(prefix.count)))
            } else {
                parts.append(candidate.hanzi)
            }
        }
        // Hanzi alone (nothing Latin written): offer the missing pinyin too. Pinyin the student wrote stays theirs.
        // A tone-marked reading is also offered for untoned, wrongly toned, or possibly misspelled Pinyin; the
        // note is separate from the student's own writing, which is never changed. (Partial Hanzi keeps the
        // earlier behavior: only the missing character and English.)
        let toneConflict: Bool = { if case .wrongTones = proposal.pinyinState { return true } else { return false } }()
        if proposal.hanziPrefixWritten.isEmpty || toneConflict || proposal.pinyinFromDictionary, !candidate.pinyin.isEmpty, proposal.pinyinState != .correct {
            parts.append("(\(candidate.pinyin))")
        }
        if !proposal.glossAlreadyWritten { parts.append(candidate.gloss) }
        return parts.joined(separator: " · ")
    }
}

/// An accepted (or edited) note. Stored apart from the ink, per page.
struct AcceptedAnnotation: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var edited: Bool
    var anchor: CGRect
    var recognizedText: String
    /// Structured metadata set at acceptance. Optional so older saved notes (text only) still load.
    var hanzi: String? = nil
    var pinyin: String? = nil
    /// The English the user approved (including their edits). Nil when the note carries none.
    var gloss: String? = nil
    var replacement: InkReplacement? = nil
    /// Identities of the original strokes this note (kept beside the ink) was accepted for. Optional so older
    /// saved notes still load. A later read of exactly these strokes is the same source, not a new note.
    var sourceStrokeIDs: [String]? = nil

    /// A note's text split into parts. Parts joined by "·"; Hanzi, pinyin and anything else (gloss).
    struct ParsedText: Equatable {
        var hanzi: String?
        var pinyin: String?
        var glossParts: [String] = []
        var ambiguous = false
    }

    /// `knownPinyin` is the only text accepted as pinyin (parenthesised or bare); everything else non-Hanzi is gloss.
    static func parse(_ text: String, knownPinyin: String?) -> ParsedText {
        var result = ParsedText()
        let target = knownPinyin.map { StarterVocabulary.latinTokens($0).joined() }
        for raw in text.split(separator: "·") {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            let inner = part.hasPrefix("(") && part.hasSuffix(")") ? String(part.dropFirst().dropLast()) : part
            let hanziOnly = !StarterVocabulary.hanzi(in: part).isEmpty
                && StarterVocabulary.hanzi(in: part).count == part.count
            if hanziOnly {
                if result.hanzi != nil { result.ambiguous = true }
                result.hanzi = part
            } else if let target, !target.isEmpty, StarterVocabulary.latinTokens(inner).joined() == target {
                result.pinyin = knownPinyin.map { RecognitionCrossCheck.pinyinAgrees(inner, with: $0) ? $0 : inner }
            } else if let knownPinyin, !knownPinyin.isEmpty,
                      let slot = PinyinSlot.leading(inner.split(whereSeparator: \.isWhitespace).map(String.init), expected: knownPinyin),
                      slot.count == inner.split(whereSeparator: \.isWhitespace).count {
                // A misread of this word's Pinyin is still Pinyin, never English: keep the dictionary reading.
                result.pinyin = knownPinyin
            } else if !StarterVocabulary.hanzi(in: part).isEmpty {
                result.ambiguous = true
            } else {
                result.glossParts.append(part)
            }
        }
        return result
    }
}

/// Suggestion state for one page: pending results, accepted notes, and one-step-at-a-time undo.
@MainActor
@Observable
final class PageSuggestionModel {
    enum Status: Equatable {
        case idle
        case checking
        /// A calm one-line explanation; writing is never blocked.
        case message(String)
    }

    private(set) var pending: [PendingSuggestion] = []
    private(set) var annotations: [AcceptedAnnotation]
    private(set) var status: Status = .idle {
        didSet {
            #if DEBUG
            DebugTrace.log("status -> \(status)")
            #endif
        }
    }
    /// Accepted annotations, newest last, that Undo can remove.
    private(set) var undoStack: [UUID] = []
    /// Why accepted notes aren't saved (nil when fine).
    private(set) var storageProblem: String?

    @ObservationIgnored private(set) var revision = 0
    @ObservationIgnored private let reader: any InkLineReader
    @ObservationIgnored private let vocabulary: StarterVocabulary
    @ObservationIgnored private let store: SuggestionStore
    @ObservationIgnored private let pageID: String
    @ObservationIgnored private var canSave = true
    /// Exposed so tests can wait for a request.
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(
        pageID: String,
        store: SuggestionStore,
        reader: any InkLineReader = PencilInkLineReader(),
        vocabulary: StarterVocabulary = .standard
    ) {
        self.pageID = pageID
        self.store = store
        self.reader = reader
        self.vocabulary = vocabulary
        do {
            annotations = try store.load(pageID: pageID)
        } catch {
            // Keep the unreadable file untouched: never write over it.
            annotations = []
            canSave = false
            storageProblem = "Saved suggestions couldn't be read, so new ones won't be saved on this page."
            Logger.notes.error("Couldn't read annotations for \(pageID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }

    // MARK: - Source changes

    /// The ink changed (stroke, erase, undo, redo): any pending result or running request is stale.
    ///
    /// Accepted notes are never removed or saved because of ink changes; see `isVisible(_:in:)`.
    func sourceDidChange() {
        #if DEBUG
        DebugTrace.log("sourceDidChange rev=\(revision + 1)")
        #endif
        revision += 1
        task?.cancel()
        task = nil
        pending = []
        status = .idle
    }

    /// Whether a note's source ink is currently present. Derived from the current drawing, so erasing
    /// hides the note and undoing the erase (or redrawing there) shows it again. Nothing is persisted.
    static func isVisible(_ note: AcceptedAnnotation, in drawing: PKDrawing) -> Bool {
        if let replacement = note.replacement {
            return drawing.strokes.contains { replacement.replacementStrokeIDs.contains(InkSelection.identity($0)) && !$0.renderBounds.isEmpty }
        }
        return drawing.strokes.contains { $0.renderBounds.intersects(note.anchor) }
    }

    /// The page is no longer shown: drop pending suggestions and any running request. Accepted notes stay.
    func cancelPending() {
        #if DEBUG
        DebugTrace.log("cancelPending rev=\(revision + 1)")
        #endif
        revision += 1
        task?.cancel()
        task = nil
        pending = []
        status = .idle
    }

    /// Lowest page y (just past the last chip) that notes need, so the canvas can scroll to them.
    var noteBottom: CGFloat? {
        let accepted = annotations.filter { $0.replacement == nil }.map { $0.anchor.maxY + 6 + 36 }
        // Room for the suggestion chip under its line.
        let provisional = pending.map { $0.anchor.maxY + 6 + 52 }
        return (accepted + provisional).max()
    }

    // MARK: - Requests

    /// Explicit request. Reads the page's lines on a task and shows results only if the ink is unchanged.
    func request(for drawing: PKDrawing) {
        task?.cancel()
        pending = []
        guard !drawing.strokes.isEmpty else {
            status = .message("Write something first, then ask for a suggestion.")
            return
        }
        // Accepted replacements are rendered text, not handwriting: reading them again would "correct" a
        // confirmed answer. Only the student's own strokes go to the recognizer.
        // Stroke identities are content hashes, so compute them once per request and only when a replacement exists.
        let strokeIDs = annotations.contains { $0.replacement != nil } ? drawing.strokes.map(InkSelection.identity) : nil
        let readable = Self.readableInk(drawing, strokeIDs: strokeIDs, excluding: annotations)
        guard !readable.strokes.isEmpty else {
            status = .message("No new handwriting to read. Accepted replacements are already confirmed.")
            return
        }
        status = .checking
        let requested = revision
        let reader = reader
        task = Task { [weak self] in
            let outcome: Result<[RecognizedLine], any Error>
            #if DEBUG
            DebugTrace.log("request task start")
            #endif
            do { outcome = .success(try await reader.lines(in: readable)) } catch { outcome = .failure(error) }
            #if DEBUG
            DebugTrace.log("reader returned")
            #endif
            guard let self, !Task.isCancelled, self.revision == requested else { return }
            self.finish(outcome, revision: requested, drawing: drawing, strokeIDs: strokeIDs, readable: readable)
        }
    }

    /// The drawing without strokes generated by accepted replacements. Coordinates are unchanged, so every
    /// line's bounds still locate the original region on the page.
    nonisolated static func readableInk(_ drawing: PKDrawing, strokeIDs: [String]? = nil,
                                        excluding annotations: [AcceptedAnnotation]) -> PKDrawing {
        let generated = annotations.reduce(into: Set<String>()) { $0.formUnion($1.replacement?.replacementStrokeIDs ?? []) }
        guard !generated.isEmpty else { return drawing }
        let ids = strokeIDs ?? drawing.strokes.map(InkSelection.identity)
        let kept = drawing.strokes.indices.filter { !generated.contains(ids[$0]) }.map { drawing.strokes[$0] }
        return kept.count == drawing.strokes.count ? drawing : PKDrawing(strokes: kept)
    }

    /// `drawing` is the full page (for note visibility); `readable` is what was read (for source strokes).
    private func finish(_ outcome: Result<[RecognizedLine], any Error>, revision: Int, drawing: PKDrawing,
                        strokeIDs: [String]?, readable: PKDrawing) {
        switch outcome {
        case .failure(let error):
            // Recognition trouble never blocks writing or touches strokes.
            status = .message(error is InkLineReaderError ? error.localizedDescription : "Suggestions aren't available right now. Keep writing.")
        case .success(let recognized):
            #if DEBUG
            print("SUGGEST finish lines=\(recognized.count)")
            DebugTrace.log("finish lines=\(recognized.count)")
            #endif
            let lines = RecognitionCrossCheck.resolve(recognized, vocabulary: vocabulary)
            #if DEBUG
            DebugTrace.log("crosscheck done lines=\(lines.count)")
            #endif
            var unmatched: [String] = []
            var unreadable: [String] = []
            // Which accepted notes still have their source on the page, decided once (not per line).
            let readableIDs = lines.contains { $0.strokeIndices != nil } ? readable.strokes.map(InkSelection.identity) : []
            // (`strokeIDs` exists whenever any note is a replacement.)
            let ids = strokeIDs ?? []
            let visibleNotes = annotations.filter { note in
                guard let replacement = note.replacement else { return Self.isVisible(note, in: drawing) }
                return ids.indices.contains { replacement.replacementStrokeIDs.contains(ids[$0]) && !drawing.strokes[$0].renderBounds.isEmpty }
            }
            pending = lines.compactMap { line in
                var proposal: SuggestionProposal
                var seen = Set<String>()
                // Only a vocabulary entry proposes a completion, from the note's validated text. Raw OCR readings are
                // never offered as words, alternatives or replacement text; they stay in `line.resolved.diagnostics`.
                // Whether the Latin text is the note's Pinyin: English-only notes are never looked up as Pinyin (`like`).
                let latinIsPinyin: Bool? = line.resolved.flatMap { resolved -> Bool? in
                    guard resolved.pinyin.isUsable else { return false }
                    return resolved.english.isUsable ? nil : true
                }
                let known = vocabulary.proposal(forRecognizedText: line.text, latinIsPinyin: latinIsPinyin)
                // Pinyin was written (so the note is more than bare Hanzi) but the match above did not use it: the Hanzi
                // alone matched. The readers' Pinyin guesses may be close to a longer dictionary word that begins with the Hanzi.
                let pinyinWritten = line.resolved.map { $0.pinyin.status != .absent } ?? false
                // With no Hanzi, only readings that are shaped like Pinyin count, and at least one must carry a tone mark:
                // an English word never reaches the dictionary as Pinyin.
                var evidence = line.resolved?.latinEvidence ?? []
                if StarterVocabulary.hanziRuns(in: line.text).isEmpty,
                   line.resolved.map({ $0.pinyin.status == .absent || $0.english.isUsable }) == true {
                    // No Hanzi, and either no Pinyin was written or the note's English was read: nothing to repair.
                    evidence = []
                } else if StarterVocabulary.hanziRuns(in: line.text).isEmpty {
                    evidence = evidence.filter { text in
                        let words = FieldValidation.words(text)
                        return !words.isEmpty && words.allSatisfy { FieldValidation.kind(of: $0) != .english }
                    }
                    if !evidence.contains(where: { $0 != $0.folding(options: .diacriticInsensitive, locale: nil) }) { evidence = [] }
                }
                let repaired = (known == nil || (pinyinWritten && known?.pinyinAlreadyWritten == false))
                    ? vocabulary.repairedProposal(forRecognizedText: line.text, latinEvidence: evidence,
                                                  writtenPinyin: line.resolved?.pinyin.value,
                                                  writtenEnglish: line.resolved.flatMap { $0.english.isUsable ? $0.english.value : nil }) : nil
                #if DEBUG
                DebugTrace.log("decide text=“\(line.text)” source=“\(line.sourceText ?? "-")” pinyinStatus=\(line.resolved?.pinyin.status.rawValue ?? "nil") evidence=\(line.resolved?.latinEvidence.count ?? -1) known=\(known?.candidates.map { $0.hanzi + " " + $0.pinyin } ?? []) knownPinyinWritten=\(known?.pinyinAlreadyWritten ?? false) repaired=\(repaired?.candidates.map { $0.hanzi + " " + $0.pinyin } ?? [])")
                #endif
                if let repaired {
                    proposal = repaired
                } else if let known {
                    proposal = known
                } else {
                    // Say what could not be settled rather than guess or stay silent.
                    if let doubt = line.resolved?.reviewNote { unreadable.append(doubt) }
                    let runs = StarterVocabulary.hanziRuns(in: line.text)
                    let known = vocabulary.entries.contains { runs.contains($0.hanzi) }
                    if !runs.isEmpty, !known, ReadingValidation.isWellFormed(line.text) { unmatched.append(line.text) }
                    return nil
                }
                // A grouped note names its own strokes; a line read by bounds alone takes those inside its bounds.
                let sourceIDs: Set<String> = line.strokeIndices.map { indices in
                    Set(indices.filter(readable.strokes.indices.contains).map { readableIDs[$0] })
                } ?? Set(InkSelection.indices(in: readable, bounds: line.bounds).map { InkSelection.identity(readable.strokes[$0]) })
                // The same source as an accepted note: by the exact original strokes, or (older notes) by the text read.
                let alreadyAccepted = visibleNotes.contains { note in
                    // Exact source strokes decide when known: an added, erased or moved stroke is a source change, even
                    // if the recognizer happens to read the same text (so it is evaluated again). Older notes have
                    // only the text to go on.
                    if note.replacement == nil, let ids = note.sourceStrokeIDs, !ids.isEmpty { return Set(ids) == sourceIDs }
                    return line.wasRead(as: note.recognizedText) && note.anchor.intersects(line.bounds)
                }
                if alreadyAccepted { return nil }
                // Two recognizers read the Latin part differently: it may be a misread, not the student's slip.
                var readingNote = line.reviewNote
                var suppressInk = line.inkEditSuppressed
                // A dictionary-repaired suggestion previews the exact text it would write, and Restore brings the ink back,
                // so it may replace when the Hanzi is solid. The caveat names what was repaired; the readers' own doubt is
                // already in it, so it is not shown twice.
                if proposal.pinyinFromDictionary, line.resolved?.hanzi.status == .confirmed {
                    suppressInk = false
                    readingNote = nil
                }
                // The readers agree on the Pinyin as written and only its tone marks differ from the dictionary's.
                if case .wrongTones = proposal.pinyinState, line.resolved?.pinyin.status == .confirmed,
                   line.resolved?.hanzi.status == .confirmed {
                    proposal.correctsConfirmedPinyin = true
                    suppressInk = false
                }
                if readingNote == nil, let source = line.sourceText,
                   StarterVocabulary.latinTokenPairs(source).map(\.raw) != StarterVocabulary.latinTokenPairs(line.text).map(\.raw) {
                    readingNote = "Two readings of this ink disagree on the Pinyin, so it is uncertain. Check it. Your ink is unchanged."
                    suppressInk = true
                }
                return PendingSuggestion(revision: revision, anchor: line.bounds, recognizedText: line.text,
                                         sourceText: line.sourceText, proposal: proposal,
                                         sourceStrokeIDs: sourceIDs,
                                         readingNote: readingNote, inkEditSuppressed: suppressInk)
            }
            // Only when nothing else was offered, so it never sits beside working suggestions looking like a failure.
            #if DEBUG
            DebugTrace.log("pending=\(pending.count) unreadable=\(unreadable.count) unmatched=\(unmatched.count)")
            for item in pending {
                DebugTrace.log("chip: note=“\(item.annotationText)” replace=“\(item.cleanText)” candidates=\(item.proposal.candidates.map { $0.hanzi + " " + $0.pinyin }) caveat=\(item.uncertaintyNote ?? "none")")
            }
            #endif
            if pending.isEmpty, !unreadable.isEmpty {
                // Several notes often share one reason; say each once.
                var seen = Set<String>()
                status = .message(unreadable.filter { seen.insert($0).inserted }.joined(separator: " "))
            } else if pending.isEmpty, !unmatched.isEmpty {
                status = .message(Self.noMatchMessage(unmatched))
            } else {
                status = pending.isEmpty ? .message("No clear reading found. Try a smaller group of words or clearer spacing. Your ink is unchanged.") : .idle
            }
        }
    }

    nonisolated static func noMatchMessage(_ readings: [String]) -> String {
        let quoted = readings.map { "“\($0.count > 12 ? String($0.prefix(12)) + "…" : $0)”" }.joined(separator: ", ")
        return "No confident match for \(quoted). It isn't in the starter vocabulary, so no Pinyin or English was guessed. Your ink is unchanged."
    }

    // MARK: - Actions

    func select(_ index: Int, for id: UUID) {
        guard let i = pending.firstIndex(where: { $0.id == id }), pending[i].proposal.candidates.indices.contains(index) else { return }
        pending[i].selectedIndex = index
    }

    func dismiss(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    /// Accepts the pending suggestion, or the user's edited text. Ignored if the ink changed since it was computed.
    func accept(_ id: UUID, editedText: String? = nil) {
        guard let suggestion = pending.first(where: { $0.id == id }), suggestion.revision == revision else { return }
        let edited = editedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (edited?.isEmpty == false ? edited : nil) ?? suggestion.annotationText
        guard !text.isEmpty else { return }
        // The accepted gloss comes from the final text (so user edits win), never from the candidate's own English.
        let parsed = AcceptedAnnotation.parse(text, knownPinyin: suggestion.candidate.pinyin)
        let gloss = parsed.ambiguous || parsed.glossParts.isEmpty ? nil : parsed.glossParts.joined(separator: " · ")
        let annotation = AcceptedAnnotation(
            id: UUID(),
            text: text,
            edited: edited?.isEmpty == false && edited != suggestion.annotationText,
            anchor: suggestion.anchor,
            recognizedText: suggestion.sourceText ?? suggestion.recognizedText,
            hanzi: suggestion.candidate.hanzi,
            pinyin: suggestion.candidate.pinyin,
            gloss: gloss,
            sourceStrokeIDs: suggestion.sourceStrokeIDs.isEmpty ? nil : suggestion.sourceStrokeIDs.sorted()
        )
        annotations.append(annotation)
        undoStack.append(annotation.id)
        pending.removeAll { $0.id == id }
        persist()
    }

    /// Persist recovery information before the page is changed. A failed metadata
    /// write must never result in deleting the original handwritten strokes.
    func acceptReplacement(_ item: PendingSuggestion, text: String, bounds: CGRect, recovery: InkReplacement) -> Bool {
        guard canSave, item.revision == revision, pending.contains(where: { $0.id == item.id }) else { return false }
        let parts = Self.replacementParts(text, for: item)
        let note = AcceptedAnnotation(id: UUID(), text: text, edited: text != item.cleanText && text != item.candidate.hanzi,
                                      anchor: bounds,
                                      recognizedText: item.sourceText ?? item.recognizedText,
                                      hanzi: parts.hanzi, pinyin: parts.pinyin, gloss: parts.gloss,
                                      replacement: recovery)
        do {
            try store.save(annotations + [note], pageID: pageID)
            annotations.append(note)
            undoStack.append(note.id)
            pending.removeAll { $0.id == item.id }
            storageProblem = nil
            return true
        } catch {
            storageProblem = "The replacement couldn't be saved. Your original writing is unchanged."
            return false
        }
    }

    /// Records where a replacement moved and the IDs its moved strokes now have.
    func updateReplacement(_ id: UUID, anchor: CGRect, recovery: InkReplacement) -> Bool {
        guard canSave, let index = annotations.firstIndex(where: { $0.id == id }) else { return false }
        var updated = annotations
        updated[index].anchor = anchor
        updated[index].replacement = recovery
        do {
            try store.save(updated, pageID: pageID)
            annotations = updated
            storageProblem = nil
            return true
        } catch {
            storageProblem = "The change couldn't be saved. The replacement stays where it was."
            return false
        }
    }

    /// Splits replacement text into card fields. The English the student approved (or typed) wins;
    /// the dictionary gloss is used only when the text is the unedited suggestion without English.
    static func replacementParts(_ text: String, for item: PendingSuggestion) -> (hanzi: String?, pinyin: String?, gloss: String?) {
        let unedited = text == item.cleanText || text == item.candidate.hanzi
        if text.contains("·") {
            let parsed = AcceptedAnnotation.parse(text, knownPinyin: item.candidate.pinyin)
            guard !parsed.ambiguous else { return (nil, nil, nil) }
            let gloss = parsed.glossParts.isEmpty ? nil : parsed.glossParts.joined(separator: " · ")
            return (parsed.hanzi, parsed.pinyin, gloss)
        }
        let hanzi = StarterVocabulary.hanzi(in: text)
        var rest = String(text.unicodeScalars.filter { !(0x4E00...0x9FFF).contains($0.value) }.map(Character.init))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var pinyin: String?
        let candidatePinyin = item.candidate.pinyin
        if !candidatePinyin.isEmpty, let slot = PinyinSlot.split(rest, expected: candidatePinyin) {
            // Untoned or slightly misread Pinyin is still the Pinyin field; the English is only what follows it.
            pinyin = candidatePinyin
            rest = slot.remainder
        } else if unedited, !candidatePinyin.isEmpty {
            pinyin = candidatePinyin
        }
        var gloss: String? = rest.isEmpty ? nil : rest
        if gloss == nil, unedited, !item.candidate.gloss.isEmpty { gloss = item.candidate.gloss }
        return (hanzi.isEmpty ? nil : hanzi, pinyin, gloss)
    }

    func keepUnchangedPending(_ items: [PendingSuggestion], excluding bounds: CGRect) {
        pending = items.filter { !$0.anchor.intersects(bounds) }.map { item in
            return PendingSuggestion(revision: revision, anchor: item.anchor, recognizedText: item.recognizedText,
                                        sourceText: item.sourceText, proposal: item.proposal,
                                        selectedIndex: item.selectedIndex, sourceStrokeIDs: item.sourceStrokeIDs,
                                        readingNote: item.readingNote, inkEditSuppressed: item.inkEditSuppressed)
        }
    }

    /// Removes the most recently accepted note.
    func undoLastAccept() {
        guard let id = undoStack.popLast() else { return }
        annotations.removeAll { $0.id == id }
        persist()
    }

    func remove(_ id: UUID) {
        annotations.removeAll { $0.id == id }
        undoStack.removeAll { $0 == id }
        persist()
    }

    private func persist() {
        guard canSave else { return }
        do {
            try store.save(annotations, pageID: pageID)
            storageProblem = nil
        } catch {
            storageProblem = "Suggestions couldn't be saved: \(error.localizedDescription)"
            Logger.notes.error("Couldn't save annotations for \(self.pageID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Accepted annotations as one small JSON file per page, written atomically beside the page's ink file.
struct SuggestionStore: Sendable {
    let directory: URL

    private struct File: Codable {
        var version: Int
        var annotations: [AcceptedAnnotation]
    }

    func fileURL(pageID: String) -> URL {
        directory.appending(path: "\(pageID).annotations.json", directoryHint: .notDirectory)
    }

    /// Empty when the page has none. Throws if a file exists but can't be read, so callers don't overwrite it.
    func load(pageID: String) throws -> [AcceptedAnnotation] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL(pageID: pageID))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return file.annotations
    }

    func save(_ annotations: [AcceptedAnnotation], pageID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(version: 1, annotations: annotations)).write(
            to: fileURL(pageID: pageID),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}
