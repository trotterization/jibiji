import Foundation

/// Every reading of one note's ink, retained with where it came from. Raw evidence only: nothing here is shown
/// to the student as text, and nothing here is validated yet.
enum NoteEvidence {
    enum Engine: String, Sendable { case pencilKit = "PencilKit", vision = "Vision", paddle = "Paddle", paddleServer = "PaddleServer", other = "reader" }
    /// How much ink was read at once.
    enum Scope: String, Sendable {
        /// One layout cell. May be only part of a field (`hǎo` of `hǎo xiang`).
        case cell
        /// All the strokes of one field read together (`hǎo` + `xiang`).
        case field
        /// The whole note read as one line (`好 hǎo xiang`).
        case entry
    }

    struct Reading: Equatable, Sendable {
        var text: String
        var engine: Engine
        var scope: Scope
        /// The field this reading is known to be about (a cell or region made of exactly that field's strokes).
        var field: NoteGrouping.FieldKind? = nil
        /// A cell that is only one part of a field made of several cells.
        var partial = false
        /// A recognizer's lower-ranked guess for the same ink. Diagnostic only: it never becomes a field value and never corroborates.
        var alternate = false
        /// Distinct readings corroborate each other; the same reading counted twice does not.
        var source: String { "\(engine.rawValue) \(scope.rawValue)\(field.map { " \($0.rawValue)" } ?? "")" }
    }
}

/// How sure the resolver is of one field.
enum FieldStatus: String, Equatable, Sendable {
    /// Nothing was written in this field.
    case absent
    /// Valid, and corroborated by another reading or the vocabulary.
    case confirmed
    /// Valid, but from one reading, or the readings disagree on a detail.
    case tentative
    /// Something was written but no valid reading exists. The value is empty; raw readings are diagnostics only.
    case unresolved
}

struct ResolvedField: Equatable, Sendable {
    var value: String?
    var status: FieldStatus
    var note: String?
    /// The reading sources that agree with `value`.
    var sources: [String] = []

    static let absent = ResolvedField(value: nil, status: .absent)
    var isUsable: Bool { value != nil && (status == .confirmed || status == .tentative) }
    var isSolid: Bool { status == .confirmed || status == .absent }
}

/// One note, resolved: three separately validated fields. The single record that Suggest and cards both read.
struct ResolvedNote: Equatable, Sendable {
    var hanzi: ResolvedField
    var pinyin: ResolvedField
    var english: ResolvedField
    /// Raw or rejected OCR readings, for the Debug view and the "check it" message. Never offered as text.
    var diagnostics: [String]
    /// The Latin part of every whole-field and whole-note reading, including lower-ranked guesses and ones that are not
    /// valid Pinyin. Never shown as text: the dictionary may use them only to rank words that begin with the written Hanzi.
    var latinEvidence: [String] = []

    var fields: [(NoteGrouping.FieldKind, ResolvedField)] { [(.hanzi, hanzi), (.pinyin, pinyin), (.english, english)] }

    /// Hanzi, Pinyin and English joined, using only usable fields. An unresolved field is left out, never guessed.
    var cleanText: String { fields.compactMap { $0.1.isUsable ? $0.1.value : nil }.joined(separator: " ") }

    /// Doubts about the fields the student's ink would be rewritten from (Hanzi and Pinyin; English is the student's own words).
    var inkReplacementIsSafe: Bool {
        guard hanzi.status != .unresolved, pinyin.status != .unresolved, english.status != .unresolved else { return false }
        return hanzi.isSolid && pinyin.isSolid
    }

    /// One plain sentence naming what is uncertain, or nil when nothing is.
    var reviewNote: String? {
        let parts = fields.compactMap { kind, field -> String? in
            switch field.status {
            case .unresolved: return "\(kind.rawValue) could not be read reliably" + (field.note.map { " (\($0))" } ?? "")
            case .tentative: return field.note.map { "\(kind.rawValue): \($0)" }
            default: return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ") + ". Check it. Your ink is unchanged."
    }
}

/// Resolves a note's retained evidence into validated fields. Pure, deterministic, offline.
///
/// Raw readings go in; only readings that pass their field's validation can become a field value. Readings that
/// fail are kept as `diagnostics`. Nothing is invented: a field with no valid reading is `unresolved`, not filled.
enum FieldResolver {
    private struct Candidate {
        var text: String
        var source: String
        var toned: Bool
        var rank: Int   // lower is more specific evidence
    }

    static func resolve(entry: NoteGrouping.Entry, readings: [NoteEvidence.Reading],
                        vocabulary: StarterVocabulary = .standard) -> ResolvedNote {
        #if DEBUG
        DebugTrace.log("resolve begin readings=\(readings.count): " + readings.map { "\($0.engine.rawValue)/\($0.scope)/\($0.alternate ? "alt" : "main")/\($0.partial ? "part" : "full")=\($0.text.replacingOccurrences(of: "\n", with: "|"))" }.joined(separator: " ; "))
        defer { DebugTrace.log("resolve end") }
        #endif
        var diagnostics: [String] = []
        func note(_ message: String) { if !diagnostics.contains(message) { diagnostics.append(message) } }

        // The layout's own grouped text is itself a reading: the cells joined as the grouping filed them.
        var evidence = readings
        for kind in NoteGrouping.FieldKind.allCases {
            if let field = entry.field(kind) {
                evidence.append(.init(text: field.text, engine: .other, scope: .field, field: kind))
            }
        }

        var hanzi: [Candidate] = [], pinyin: [Candidate] = [], english: [Candidate] = []
        var pinyinSeen = false
        var misfiled = false
        var pinyinLetters: [String] = []   // Pinyin-shaped readings of the whole note or of the Pinyin field, valid or not

        // Plain syllables that are not an English word (`Shi`), read alike by two or more independent engines, are Pinyin.
        // One engine's English look-alike a letter away (`She`) is then that Pinyin misread, not something else written.
        // A real English word read alike by everyone (`she`) never takes part, so English notes stay English.
        var syllableVoters: [String: Set<NoteEvidence.Engine>] = [:]
        for reading in evidence where !reading.alternate && !reading.partial && reading.engine != .other {
            let words = FieldValidation.words(latinPart(reading.text)).filter { $0.contains(where: \.isLetter) }
            guard !words.isEmpty, words.allSatisfy({ [.pinyinPlain, .pinyinToned].contains(FieldValidation.kind(of: $0)) }),
                  PinyinValidator.analyze(words: words).isValid,
                  !FieldValidation.isEnglish(words.joined(separator: " "), hanzi: nil, vocabulary: vocabulary) else { continue }
            syllableVoters[FieldValidation.letters(words), default: []].insert(reading.engine)
        }
        let voted = syllableVoters.filter { $0.value.count >= 2 }.max { $0.value.count < $1.value.count }
        for reading in evidence {
            if reading.alternate { note("Alternate reading: “\(reading.text)” (\(reading.engine.rawValue))"); continue }
            let parsed = parse(reading, vocabulary: vocabulary)
            // One cell of a multi-cell field (`xiang` of `hǎo xiang`) is a piece, not an answer for the whole field.
            // Its text still reaches the field through the grouping's joined text; here it is only a diagnostic.
            if reading.partial {
                if let p = parsed.pinyin, !PinyinValidator.analyze(words: p).isValid {
                    note("Pinyin piece rejected: “\(p.joined(separator: " "))” (\(reading.source))")
                }
                continue
            }
            if let h = parsed.hanzi { hanzi.append(Candidate(text: h, source: reading.source, toned: false, rank: rank(reading))) }
            if let p = parsed.pinyin {
                pinyinSeen = true
                if reading.scope != .cell || reading.field == .pinyin { pinyinLetters.append(FieldValidation.letters(p)) }
                let verdict = PinyinValidator.analyze(words: p)
                if verdict.isValid {
                    pinyin.append(Candidate(text: p.joined(separator: " "), source: reading.source, toned: verdict.isToned, rank: rank(reading)))
                } else {
                    note("Pinyin reading rejected: “\(p.joined(separator: " "))” (\(reading.source))")
                }
            }
            if let e = parsed.english, entry.english == nil, reading.scope != .cell {
                // No stroke of this note was filed as English, so English found only in a whole-note or whole-field reading is
                // a recognizer's misreading of other ink (`学die xi` for `学 xúe xí`), not something the student wrote.
                note("English reading ignored (no English ink in this note): “\(e)” (\(reading.source))")
            } else if let e = parsed.english, let voted,
                      case let letters = FieldValidation.letters(FieldValidation.words(e)),
                      letters == voted.key || (!voted.value.contains(reading.engine) && StarterVocabulary.editDistance(letters, voted.key) <= 1) {
                if letters == voted.key {
                    // The same syllables the engines agreed on, filed as English only because nothing anchored them.
                    pinyinSeen = true
                    let words = FieldValidation.words(e)
                    pinyin.append(Candidate(text: words.joined(separator: " "), source: reading.source,
                                            toned: PinyinValidator.analyze(words: words).isToned, rank: rank(reading)))
                } else {
                    misfiled = true
                    note("English reading outvoted as misread Pinyin: “\(e)” (\(reading.source))")
                }
            } else if let e = parsed.english {
                // OCR garbles Pinyin without leaving a tone mark (`hho xiang` for `hǎo xiang`). When a Pinyin reading of the
                // same note is a few letters away, this "English" is that Pinyin, filed in the wrong field. It is not English.
                // A reading that is real English stays English (`he` beside `tā`). Only one that is NOT English and sits
                // within a few letters of a Pinyin reading of the same note is that Pinyin filed in the wrong field.
                let letters = FieldValidation.letters(FieldValidation.words(e))
                let realEnglish = FieldValidation.isEnglish(e, hanzi: parsed.hanzi, vocabulary: vocabulary)
                if !realEnglish, !letters.isEmpty,
                   pinyinLetters.contains(where: { StarterVocabulary.editDistance(letters, $0) <= max(2, $0.count / 3) }) {
                    misfiled = true
                    note("English reading is misfiled Pinyin: “\(e)” (\(reading.source))")
                } else if FieldValidation.isEnglish(e, hanzi: parsed.hanzi, vocabulary: vocabulary) {
                    english.append(Candidate(text: e, source: reading.source, toned: false, rank: rank(reading)))
                } else {
                    note("English reading rejected (not English): “\(e)” (\(reading.source))")
                }
            }
            for other in parsed.rejected { note("Reading ignored: “\(other)” (\(reading.source))") }
        }

        let hanziField = pickHanzi(hanzi, entry: entry, vocabulary: vocabulary, note: note)
        var pinyinField = pickPinyin(pinyin, entry: entry, hanzi: hanziField.value, pinyinSeen: pinyinSeen, vocabulary: vocabulary, note: note)
        // The engines agreed on the letters but dropped the tone mark, which only their lower-ranked guesses kept (`Shi`, with
        // `Shì` below it). When those guesses agree on a single toned spelling of exactly these letters, it is used, tentatively.
        if let value = pinyinField.value, !PinyinValidator.analyze(words: FieldValidation.words(value)).isToned {
            let letters = FieldValidation.letters(FieldValidation.words(value))
            var toned: [String: String] = [:]
            for reading in evidence where reading.alternate {
                let words = FieldValidation.words(latinPart(reading.text)).filter { $0.contains(where: \.isLetter) }
                let verdict = PinyinValidator.analyze(words: words)
                guard !words.isEmpty, verdict.isValid, verdict.isToned, FieldValidation.letters(words) == letters else { continue }
                let spelling = words.joined(separator: " ").precomposedStringWithCanonicalMapping.lowercased()
                toned[spelling.replacingOccurrences(of: " ", with: ""), default: spelling] = toned[spelling.replacingOccurrences(of: " ", with: "")] ?? spelling
            }
            if toned.count == 1, let spelling = toned.values.first {
                note("Tone mark taken from a lower-ranked reading: “\(spelling)”")
                pinyinField = ResolvedField(value: spelling, status: .tentative,
                                            note: "the tone mark came from a lower-ranked reading", sources: pinyinField.sources)
            }
        }
        // With Pinyin settled, the Hanzi that fits it is preferred over a conflicting reading.
        var finalHanzi = hanziField
        if hanzi.count > 1, let letters = pinyinField.value.map({ FieldValidation.letters(FieldValidation.words($0)) }) {
            let distinct = Set(hanzi.map(\.text))
            let fitting = distinct.filter { FieldValidation.fitsHanzi(letters, hanzi: $0, vocabulary: vocabulary) }
            if distinct.count > 1, fitting.count == 1, let only = fitting.first, only != hanziField.value {
                note("Hanzi reading not used: “\(hanziField.value ?? "")” (it does not fit the written Pinyin)")
                finalHanzi = ResolvedField(value: only, status: .tentative,
                                           note: "chosen because it fits the Pinyin; the readings disagreed",
                                           sources: hanzi.filter { $0.text == only }.map(\.source))
            }
        }
        var englishField = pickEnglish(english, entry: entry, hanzi: finalHanzi.value, vocabulary: vocabulary, note: note)
        // If every English reading was really Pinyin, nothing English was written.
        if misfiled, english.isEmpty { englishField = .absent }
        var latinEvidence: [String] = []
        for reading in evidence where reading.scope != .cell || reading.field == .pinyin {
            let latin = String(reading.text.filter { !$0.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if latin.contains(where: \.isLetter), !latinEvidence.contains(latin) { latinEvidence.append(latin) }
        }
        return ResolvedNote(hanzi: finalHanzi, pinyin: pinyinField, english: englishField, diagnostics: diagnostics, latinEvidence: latinEvidence)
    }

    /// Readings derived from other readings (the grouping's own joined text) do not corroborate anything.
    /// Corroboration counts distinct *engines*: one engine reading the same ink at two scales is still one opinion.
    private static func independent(_ sources: [String]) -> Int {
        Set(sources.compactMap { $0.split(separator: " ").first.map(String.init) }.filter { $0 != "reader" }).count
    }

    private static func rank(_ reading: NoteEvidence.Reading) -> Int {
        switch reading.scope { case .field: 0; case .entry: 1; case .cell: reading.partial ? 3 : 2 }
    }

    // MARK: - Parsing one reading into field pieces

    private struct Parsed {
        var hanzi: String?
        var pinyin: [String]?
        var english: String?
        var rejected: [String] = []
    }

    /// The text of a reading with its Hanzi removed.
    private static func latinPart(_ text: String) -> String {
        String(text.filter { !$0.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } })
    }

    private static func parse(_ reading: NoteEvidence.Reading, vocabulary: StarterVocabulary) -> Parsed {
        var result = Parsed()
        let text = reading.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return result }
        let runs = StarterVocabulary.hanziRuns(in: text)
        if let first = runs.first, reading.field != .english, reading.field != .pinyin { result.hanzi = first }
        let latin = text.unicodeScalars.map { (0x3400...0x9FFF).contains($0.value) ? " " : String($0) }.joined()
        let words = FieldValidation.words(latin).filter { $0.contains(where: \.isLetter) || $0.contains(where: \.isNumber) }
        guard !words.isEmpty else { return result }
        let kinds = words.map(FieldValidation.kind(of:))

        switch reading.field {
        case .hanzi?:
            result.rejected.append(words.joined(separator: " "))
        case .pinyin?:
            result.pinyin = words
        case .english?:
            // A reading of the English field that is really Pinyin is not English.
            result.english = words.joined(separator: " ")
        case nil:
            // A line read as a whole: leading Pinyin-shaped words are the Pinyin, the rest is English.
            var end = 0
            while end < words.count, kinds[end] != .english { end += 1 }
            let run = Array(words[0..<end])
            let runKinds = Array(kinds[0..<end])
            let hanziRun = result.hanzi ?? ""
            let anchored = !run.isEmpty && !hanziRun.isEmpty
                && FieldValidation.fitsHanzi(FieldValidation.letters(run), hanzi: hanziRun, vocabulary: vocabulary)
            let evidence = runKinds.contains(.pinyinToned) || runKinds.contains(.pinyinMalformed)
            if !run.isEmpty, evidence || anchored {
                result.pinyin = run
                let rest = Array(words[end...])
                if !rest.isEmpty { result.english = rest.joined(separator: " ") }
            } else if !run.isEmpty, runKinds.allSatisfy({ $0 == .pinyinPlain }), words.count == run.count {
                // Plain syllables with nothing to anchor them: Pinyin or English, decided by the grouping.
                result.english = run.joined(separator: " ")
            } else {
                result.english = words.joined(separator: " ")
            }
        }
        return result
    }

    // MARK: - Choosing a value for each field

    private static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func pickHanzi(_ candidates: [Candidate], entry: NoteGrouping.Entry, vocabulary: StarterVocabulary, note: (String) -> Void) -> ResolvedField {
        guard !candidates.isEmpty else {
            return entry.hanzi == nil ? .absent : ResolvedField(value: nil, status: .unresolved)
        }
        let groups = Dictionary(grouping: candidates, by: \.text)
        let ranked = groups.sorted { a, b in
            let sa = Set(a.value.map(\.source)).count, sb = Set(b.value.map(\.source)).count
            if sa != sb { return sa > sb }
            return (a.value.map(\.rank).min() ?? 9) < (b.value.map(\.rank).min() ?? 9)
        }
        let best = ranked[0]
        let sources = Array(Set(best.value.map(\.source))).sorted()
        for other in ranked.dropFirst() { note("Hanzi reading not used: “\(other.key)” (\(Set(other.value.map(\.source)).sorted().joined(separator: ", ")))") }
        let conflict = ranked.count > 1 && independent(Array(Set(ranked[1].value.map(\.source)))) >= independent(sources)
        let known = vocabulary.entries.contains { $0.hanzi.hasPrefix(best.key) }
        let confirmed = (independent(sources) >= 2 || known) && !conflict
        return ResolvedField(value: best.key, status: confirmed ? .confirmed : .tentative,
                             note: conflict ? "the readings disagree on the Hanzi" : (confirmed ? nil : "read only once"), sources: sources)
    }

    private static func pickPinyin(_ candidates: [Candidate], entry: NoteGrouping.Entry, hanzi: String?, pinyinSeen: Bool,
                                   vocabulary: StarterVocabulary, note: (String) -> Void) -> ResolvedField {
        guard !candidates.isEmpty else {
            return pinyinSeen || entry.pinyin != nil ? ResolvedField(value: nil, status: .unresolved, note: "no reading is valid Pinyin") : .absent
        }
        // Readings with the same letters are one answer; a toned spelling beats a toneless one.
        let groups = Dictionary(grouping: candidates) { FieldValidation.letters(FieldValidation.words($0.text)) }
        func fits(_ letters: String) -> Bool {
            guard let hanzi else { return true }
            return FieldValidation.fitsHanzi(letters, hanzi: hanzi, vocabulary: vocabulary)
        }
        let ranked = groups.sorted { a, b in
            let fa = fits(a.key), fb = fits(b.key)
            if fa != fb { return fa }
            let sa = Set(a.value.map(\.source)).count, sb = Set(b.value.map(\.source)).count
            if sa != sb { return sa > sb }
            // A field read as a whole outranks pieces of it joined.
            let ra = a.value.map(\.rank).min() ?? 9, rb = b.value.map(\.rank).min() ?? 9
            if ra != rb { return ra < rb }
            return a.key.count > b.key.count
        }
        let best = ranked[0]
        let sources = Array(Set(best.value.map(\.source))).sorted()
        for other in ranked.dropFirst() { note("Pinyin reading not used: “\(other.value[0].text)” (\(Set(other.value.map(\.source)).sorted().joined(separator: ", ")))") }

        // Within the answer, the most-written spelling; two different toned spellings are a real disagreement.
        let toned = best.value.filter(\.toned)
        let spellings = Dictionary(grouping: toned, by: { $0.text.precomposedStringWithCanonicalMapping.lowercased() })
        var value = best.value.min { $0.rank < $1.rank }!.text
        var tentativeNote: String?
        if !spellings.isEmpty {
            let top = spellings.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            value = top[0].value[0].text
            if top.count > 1, top[0].value.count == top[1].value.count { tentativeNote = "the readings disagree on the tone marks" }
        }
        let anchored = hanzi.map { fits(best.key) && !$0.isEmpty } ?? false
        if hanzi != nil, !anchored { tentativeNote = tentativeNote ?? "it does not match the Hanzi" }
        let corroborated = independent(sources) >= 2
        let vocabularyFit = hanzi.map { h in vocabulary.entries.contains { $0.hanzi.hasPrefix(h) && $0.syllables.joined().hasPrefix(best.key) || $0.syllables.joined() == best.key && $0.hanzi == h } } ?? false
        var status: FieldStatus = (corroborated || vocabularyFit) && tentativeNote == nil ? .confirmed : .tentative
        if tentativeNote == nil, !status.isConfirmed { tentativeNote = "read only once" }
        if best.value.allSatisfy({ !$0.toned }), tentativeNote == nil { status = .confirmed }
        return ResolvedField(value: value, status: status, note: tentativeNote, sources: sources)
    }

    private static func pickEnglish(_ candidates: [Candidate], entry: NoteGrouping.Entry, hanzi: String?,
                                    vocabulary: StarterVocabulary, note: (String) -> Void) -> ResolvedField {
        guard !candidates.isEmpty else {
            // Written, but every reading looked like Pinyin: not English.
            return entry.english == nil ? .absent : ResolvedField(value: nil, status: .unresolved, note: "it is not recognizable English (it looked like garbled Pinyin)")
        }
        let groups = Dictionary(grouping: candidates) { normalized($0.text) }
        let ranked = groups.sorted { a, b in
            let sa = Set(a.value.map(\.source)).count, sb = Set(b.value.map(\.source)).count
            if sa != sb { return sa > sb }
            return (a.value.map(\.rank).min() ?? 9) < (b.value.map(\.rank).min() ?? 9)
        }
        let best = ranked[0]
        let sources = Array(Set(best.value.map(\.source))).sorted()
        for other in ranked.dropFirst() { note("English reading not used: “\(other.value[0].text)” (\(Set(other.value.map(\.source)).sorted().joined(separator: ", ")))") }
        let value = best.value.min { $0.rank < $1.rank }!.text
        let grounded = vocabulary.entries.contains { entry in entry.glosses.contains { normalized($0) == best.key } }
        let confirmed = independent(sources) >= 2 || grounded
        let disputed = ranked.count > 1
        return ResolvedField(value: value, status: confirmed && !disputed ? .confirmed : .tentative,
                             note: disputed ? "the readings differ" : (confirmed ? nil : "read only once; the wording is the student's own"), sources: sources)
    }
}

private extension FieldStatus {
    var isConfirmed: Bool { self == .confirmed }
}
