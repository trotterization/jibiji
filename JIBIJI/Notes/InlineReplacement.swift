import CoreGraphics
import Foundation
import PencilKit

/// Which strokes hold each field of a note, and what was read there. Lets Replace add only what is missing.
struct FieldInk: Equatable, Sendable {
    var hanzi: Set<String> = []
    var pinyin: Set<String> = []
    var english: Set<String> = []
    var hanziText: String?
    /// The Pinyin as read, nil when some was written but could not be read, or none was.
    var pinyinText: String?
    var englishText: String?
    /// Pinyin was written, readable or not.
    var pinyinWritten = false
}

/// Replace, done in place: the student's strokes stay, and only what the note is missing is written beside them at the
/// size of the writing it belongs to. Wrong or missing tone marks are fixed on the student's own letters; the Pinyin is
/// rewritten only when its letters are not the word's. The English goes on the note's line, never under it.
///
/// Nil when the fields cannot be told apart or there is no room; the caller then replaces the whole line, as before.
@MainActor
enum InlineReplacement {
    struct Plan {
        var added: [PKStroke]
        /// Strokes taken off the page (Pinyin that is rewritten). Usually empty.
        var removed: Set<String>
        /// The student's strokes the note still stands on.
        var kept: Set<String>
    }

    /// Text in handwriting of a known size: where its baseline is and how big an em is.
    private struct Measure {
        var bounds: CGRect
        /// Where the writing starts, and where its last word is: handwriting climbs or sinks along a line.
        var baseline: CGFloat
        var end: CGFloat
        var em: CGFloat
    }

    /// Portrait width of the iPad, when the page's own width is not known.
    nonisolated static let defaultPageWidth: CGFloat = 820

    /// `pageWidth` is how far to the right there is page in view; nothing is written past it unless ink already is.
    static func plan(for item: PendingSuggestion, in drawing: PKDrawing, pageWidth: CGFloat = defaultPageWidth) -> Plan? {
        guard item.selectedIndex == 0, let ink = item.fieldInk, !item.candidate.pinyin.isEmpty else { return none("not the first suggestion, or the fields are unknown") }
        let all = drawing.strokes.map { (id: InkSelection.identity($0), stroke: $0) }
        guard let fields = separate(ink, item: item, strokes: all) else { return none("the fields could not be told apart") }
        let noteStrokes = all.filter { item.sourceStrokeIDs.contains($0.id) }.map(\.stroke)
        guard !noteStrokes.isEmpty, noteStrokes.count == item.sourceStrokeIDs.count else { return none("the strokes changed") }

        let candidate = item.candidate
        let plainPinyin = Lexicon.foldedLetters(candidate.pinyin)
        let hanzi = measure(ink.hanziText ?? "", fields.hanzi)
        var pinyin = measure(ink.pinyinText ?? plainPinyin, fields.pinyin)
        let english = measure(ink.englishText ?? "", fields.english)
        guard hanzi != nil || pinyin != nil else { return none("nothing could be measured") }

        var added: [PKStroke] = []
        var removed = Set<String>()
        // Everything that stays on the page is in the way, and so is whatever has been added.
        var obstacles = all.map { (id: $0.id, rect: pathBounds([$0.stroke])) }
        let limit = max(pageWidth - 16, drawing.bounds.maxX + 24)
        func isFree(_ rect: CGRect, unbounded: Bool = false) -> Bool {
            rect.minX >= 4 && rect.minY >= 4 && (unbounded || rect.maxX <= limit)
                && !obstacles.contains { !removed.contains($0.id) && $0.rect.intersects(rect.insetBy(dx: -2, dy: -1)) }
        }
        /// Writes `text` with its left edge at `x`, a little smaller if it has to be. Nil when it does not fit. `unbounded`
        /// lets it run past the right edge of the view; the page widens to fit ink.
        func write(_ text: String, x: CGFloat, baseline: CGFloat, em: CGFloat, pen: CleanHandwriting.Pen,
                   scales: [CGFloat] = [1, 0.85, 0.7], squeezes: [CGFloat] = [1], unbounded: Bool = false) -> CGRect? {
            for (scale, squeeze) in scales.flatMap({ scale in squeezes.map { (scale, $0) } }) {
                guard var box = CleanHandwriting.bounds(of: text, em: em * scale)?.offsetBy(dx: x, dy: baseline) else { continue }
                box.size.width *= squeeze
                guard isFree(box, unbounded: unbounded), let piece = CleanHandwriting.drawing(text: text, baseline: CGPoint(x: x, y: baseline), em: em * scale,
                                                                        pen: pen, squeeze: squeeze) else { continue }
                added += piece.strokes
                obstacles.append((id: "", rect: box))
                return box
            }
            return nil
        }
        /// Writes Pinyin: the letters in the typeface without its accents, which are specks at handwriting size, then each
        /// tone mark drawn at a hand's size over its letter, as on the student's own Pinyin.
        func writePinyin(_ text: String, x: CGFloat, baseline: CGFloat, em: CGFloat, pen: CleanHandwriting.Pen,
                         scales: [CGFloat] = [1, 0.85, 0.7]) -> CGRect? {
            let plain = Self.untoned(text)
            let before = added.count
            guard let box = write(plain, x: x, baseline: baseline, em: em, pen: pen, scales: scales) else { return nil }
            let letters = Array(added[before...])
            let natural = CleanHandwriting.bounds(of: plain, em: em)?.width ?? 0
            let scale = natural > 0 ? box.width / natural : 1
            guard plain != text, let marks = toneMarks(written: plain, target: text, strokes: letters, em: em * scale, pen: pen)?.marks,
                  !marks.isEmpty else { return box }
            added += marks
            obstacles.append((id: "", rect: pathBounds(marks)))
            return box.union(pathBounds(marks))
        }

        // 1. Pinyin that is there: only its tone marks are fixed, on the student's own letters. A missing mark is added and
        //    a wrong one is taken off and written correctly; the letters stay. Pinyin cut short (`hǎo` for hǎoxiàng) gets the
        //    syllables it is missing written after it. Rewritten only when the letters are not the word's.
        if var measured = pinyin {
            let pen = CleanHandwriting.Pen.matching(fields.pinyin)
            var rewrite = false
            func fixTones(written: String) -> Bool {
                // The part of the word that was written, and the syllables that were left off.
                let (head, tail) = Self.divide(candidate.pinyin, after: Lexicon.foldedLetters(written))
                guard let fix = toneMarks(written: written, target: head, strokes: fields.pinyin, em: measured.em, pen: pen)
                else {
                    #if DEBUG
                    DebugTrace.log("replace: tone marks of “\(written)” could not be fixed in place; the Pinyin is rewritten")
                    #endif
                    return false
                }
                removed.formUnion(fix.wrong.map(InkSelection.identity))
                added += fix.marks
                obstacles += fix.marks.map { (id: "", rect: pathBounds([$0])) }
                if !tail.isEmpty {
                    guard let box = writePinyin(tail, x: measured.bounds.maxX + 0.12 * measured.em, baseline: measured.end, em: measured.em, pen: pen, scales: [1, 0.85])
                    else { return false }
                    measured.bounds = measured.bounds.union(box)
                    pinyin = measured
                }
                return true
            }
            switch item.proposal.pinyinState {
            case .correct:
                // Right as far as it goes; it may stop short of the word.
                if let read = ink.pinyinText, Lexicon.foldedLetters(read).count < plainPinyin.count { rewrite = !fixTones(written: read) }
            case .missingTones, .wrongTones:
                rewrite = !fixTones(written: ink.pinyinText ?? "")
            case .possibleSpelling(let read):
                // Read with a letter or two wrong. Far more often the readers' mistake than the student's, so where the
                // letters correspond one to one the marks go on the student's own writing; otherwise it is rewritten.
                // Cut short of the word (`hao` for hǎoxiàng) is read this way too: the marks go on it, and the rest after it.
                if !Self.divide(candidate.pinyin, after: Lexicon.foldedLetters(read)).tail.isEmpty {
                    rewrite = !fixTones(written: read)
                } else {
                    rewrite = !(respelled(read, as: candidate.pinyin).map(fixTones) ?? false)
                }
            case .notWritten: rewrite = true
            }
            if rewrite {
                // Anything step 1 added is taken back first.
                added.removeAll()
                removed = Set(fields.pinyin.map(InkSelection.identity))
                obstacles = all.map { (id: $0.id, rect: pathBounds([$0.stroke])) }
                guard let box = writePinyin(candidate.pinyin, x: measured.bounds.minX, baseline: measured.baseline, em: measured.em, pen: pen)
                else { return none("no room for the Pinyin") }
                measured.end = measured.baseline
                measured.bounds = box
                pinyin = measured
            }
        }

        // 2. Hanzi that is missing, at the size of the Hanzi that is there.
        var hanziEnd = hanzi?.bounds
        if !item.proposal.hanziAlreadyWritten {
            let prefix = item.proposal.hanziPrefixWritten
            if let hanzi, !prefix.isEmpty, candidate.hanzi.hasPrefix(prefix) {
                let rest = String(candidate.hanzi.dropFirst(prefix.count))
                guard !rest.isEmpty, let box = write(rest, x: hanzi.bounds.maxX + 0.08 * hanzi.em, baseline: hanzi.end, em: hanzi.em,
                                                     pen: .matching(fields.hanzi), scales: [1, 0.9, 0.8, 0.7], squeezes: [1, 0.85, 0.75])
                else { return none("no room for the Hanzi") }
                hanziEnd = hanzi.bounds.union(box)
            } else if hanzi == nil, let pinyin {
                // Only Pinyin is written: the word goes in front of it, or right after it when there is no room in front.
                let em = pinyin.em * 1.15
                let pen = CleanHandwriting.Pen.matching(fields.pinyin)
                let width = CleanHandwriting.bounds(of: candidate.hanzi, em: em)?.width ?? 0
                let before = pinyin.bounds.minX - width - 0.4 * em
                guard let box = write(candidate.hanzi, x: before, baseline: pinyin.baseline, em: em, pen: pen, scales: [1])
                        ?? write(candidate.hanzi, x: pinyin.bounds.maxX + 0.4 * em, baseline: pinyin.end, em: em, pen: pen) else { return none("no room for the Hanzi") }
                hanziEnd = box
            } else {
                return none("no Hanzi to continue")
            }
        }

        // 3. Pinyin that is missing: between the Hanzi and the English, above the Hanzi, or after the note.
        if pinyin == nil, let hanzi, let hanziEnd {
            let em = english?.em ?? hanzi.em * 0.6
            let baseline = english?.baseline ?? hanzi.end
            let pen = CleanHandwriting.Pen.matching(fields.english.isEmpty ? fields.hanzi : fields.english)
            let right = max(hanziEnd.maxX, english?.bounds.maxX ?? 0)
            let above = CleanHandwriting.bounds(of: candidate.pinyin, em: em).map { hanzi.bounds.minY - 0.2 * em - $0.maxY } ?? 0
            var box = writePinyin(candidate.pinyin, x: hanziEnd.maxX + 0.4 * em, baseline: baseline, em: em, pen: pen, scales: english == nil ? [1, 0.85, 0.7] : [1, 0.85])
            var line = baseline
            if box == nil { box = writePinyin(candidate.pinyin, x: hanzi.bounds.minX, baseline: above, em: em, pen: pen, scales: [1, 0.85]); line = above }
            if box == nil { box = writePinyin(candidate.pinyin, x: right + 0.5 * em, baseline: baseline, em: em, pen: pen); line = baseline }
            guard let box else { return none("no room for the missing Pinyin") }
            pinyin = Measure(bounds: box, baseline: line, end: line, em: em)
        }

        // 4. English that is missing, on the note's line after the Pinyin, at the Pinyin's size. The page widens to fit, so
        //    it may run past the right edge; it moves past other writing in its way, and is never put under the note.
        if english == nil, !candidate.gloss.isEmpty, let pinyin {
            let pen = CleanHandwriting.Pen.matching(fields.pinyin.isEmpty ? fields.hanzi : fields.pinyin)
            let pieces = [hanziEnd, pinyin.bounds].compactMap { $0 }
            let onLine = pieces.filter { $0.minY < pinyin.end && $0.maxY > pinyin.end - pinyin.em }
            var x = (onLine.map(\.maxX).max() ?? pinyin.bounds.maxX) + 0.6 * pinyin.em
            var box: CGRect?
            for _ in 0..<8 {
                box = write(candidate.gloss, x: x, baseline: pinyin.end, em: pinyin.em, pen: pen, scales: [1], unbounded: true)
                guard box == nil, let shape = CleanHandwriting.bounds(of: candidate.gloss, em: pinyin.em)?.offsetBy(dx: x, dy: pinyin.end)
                else { break }
                // Past whatever is in the way on the line.
                let blocking = obstacles.filter { !removed.contains($0.id) && $0.rect.intersects(shape.insetBy(dx: -2, dy: -1)) }
                guard let right = blocking.map(\.rect.maxX).max(), right + 0.6 * pinyin.em > x else { break }
                x = right + 0.6 * pinyin.em
            }
            guard box != nil else { return none("no room for the English on its line") }
        }

        guard !added.isEmpty, let canonical = try? PKDrawing(data: PKDrawing(strokes: added).dataRepresentation()),
              canonical.strokes.count == added.count else { return none("nothing to add") }
        return Plan(added: canonical.strokes, removed: removed, kept: item.sourceStrokeIDs.subtracting(removed))
    }

    /// Why a note is replaced as a whole line instead.
    private static func none(_ why: String) -> Plan? {
        #if DEBUG
        DebugTrace.log("replace whole line: \(why)")
        print("INLINE whole line: \(why)")
        #endif
        return nil
    }

    // MARK: - Telling the fields apart

    private static func separate(_ ink: FieldInk, item: PendingSuggestion, strokes all: [(id: String, stroke: PKStroke)])
        -> (hanzi: [PKStroke], pinyin: [PKStroke], english: [PKStroke])? {
        func strokes(_ ids: Set<String>) -> [PKStroke] { all.filter { ids.contains($0.id) }.map(\.stroke) }
        let hasEnglish = ink.englishText?.isEmpty == false
        let latin = ink.pinyin.union(ink.english)
        let pinyinText = ink.pinyinText ?? Lexicon.foldedLetters(item.candidate.pinyin)

        if !ink.hanzi.isEmpty, !ink.hanzi.isDisjoint(with: latin) {
            // Hanzi and Latin were read as one cell: they are told apart by the widest gap near where one should end.
            guard let hanziText = ink.hanziText else { return nil }
            let segments = [hanziText] + (ink.pinyinWritten ? [pinyinText] : []) + (hasEnglish ? [ink.englishText!] : [])
            guard segments.count > 1, let parts = split(strokes(ink.hanzi.union(latin)), into: segments) else { return nil }
            return (parts[0], ink.pinyinWritten ? parts[1] : [], hasEnglish ? parts[parts.count - 1] : [])
        }
        switch (ink.pinyinWritten, hasEnglish) {
        case (false, false): return latin.isEmpty ? (strokes(ink.hanzi), [], []) : nil
        case (true, false): return (strokes(ink.hanzi), strokes(latin), [])
        case (false, true): return (strokes(ink.hanzi), [], strokes(latin))
        case (true, true):
            if !ink.pinyin.isEmpty, !ink.english.isEmpty, ink.pinyin.isDisjoint(with: ink.english) {
                return (strokes(ink.hanzi), strokes(ink.pinyin), strokes(ink.english))
            }
            guard let parts = split(strokes(latin), into: [pinyinText, ink.englishText!]) else { return nil }
            return (strokes(ink.hanzi), parts[0], parts[1])
        }
    }

    /// Splits a run of writing into consecutive texts at the clearest gap near where each should end. Nil when no gap there
    /// is clear enough to trust.
    static func split(_ strokes: [PKStroke], into texts: [String]) -> [[PKStroke]]? {
        guard texts.count > 1 else { return [strokes] }
        let items = strokes.map { (stroke: $0, rect: pathBounds([$0])) }.sorted { $0.rect.minX < $1.rect.minX }
        guard items.count >= texts.count else { return nil }
        let whole = pathBounds(strokes)
        var gaps: [(after: Int, width: CGFloat, middle: CGFloat)] = []
        var right = items[0].rect.maxX
        for index in 1..<items.count {
            if items[index].rect.minX > right {
                gaps.append((index - 1, items[index].rect.minX - right, (items[index].rect.minX + right) / 2))
            }
            right = max(right, items[index].rect.maxX)
        }
        let widths = texts.map { (CleanHandwriting.offsets(in: $0 + " ").last ?? 0) }
        let total = widths.reduce(0, +)
        guard total > 0, whole.width > 0, whole.height > 0 else { return nil }
        var cuts: [Int] = []
        var passed: CGFloat = 0
        for width in widths.dropLast() {
            passed += width
            let expected = whole.minX + whole.width * passed / total
            let best = gaps.filter { $0.after > (cuts.last ?? -1) }.max {
                $0.width / whole.height - 1.5 * abs($0.middle - expected) / whole.width
                    < $1.width / whole.height - 1.5 * abs($1.middle - expected) / whole.width
            }
            guard let best, best.width >= 0.12 * whole.height, abs(best.middle - expected) <= 0.3 * whole.width else { return nil }
            cuts.append(best.after)
        }
        var parts: [[PKStroke]] = []
        var start = 0
        for cut in cuts + [items.count - 1] {
            guard cut >= start else { return nil }
            parts.append(items[start...cut].map(\.stroke))
            start = cut + 1
        }
        return parts
    }

    // MARK: - Tone marks over the student's own letters

    /// Fixes the tone marks of `written` to be `target`'s, on the student's own letters: `marks` are drawn above the letters
    /// they belong to, and `wrong` are the student's marks that come off (a different tone, or a mark where none belongs).
    /// A mark that is there and right stays. Nil when the letters differ, or a wrong mark cannot be found in the ink.
    static func toneMarks(written: String, target: String, strokes: [PKStroke], em: CGFloat, pen: CleanHandwriting.Pen)
        -> (marks: [PKStroke], wrong: [PKStroke])? {
        let marks: [UInt32: Int] = [0x0304: 1, 0x0301: 2, 0x030C: 3, 0x0300: 4]
        func letters(_ text: String) -> [(base: String, tone: Int?)] {
            text.precomposedStringWithCanonicalMapping.compactMap { character in
                let base = Lexicon.foldedLetters(String(character))
                guard !base.isEmpty else { return nil }
                return (base, String(character).decomposedStringWithCanonicalMapping.unicodeScalars.compactMap { marks[$0.value] }.first)
            }
        }
        let words = FieldValidation.words(written).filter { !letters($0).isEmpty }
        let have = words.flatMap(letters), want = letters(target)
        guard !words.isEmpty, have.map(\.base) == want.map(\.base) else { return nil }
        let separated = split(strokes, into: words)
        let groups = separated.map { zip(words, $0).map { (text: $0.0, strokes: $0.1) } } ?? [(text: words.joined(separator: " "), strokes: strokes)]

        var result: [PKStroke] = []
        var wrong: [PKStroke] = []
        var index = 0
        for group in groups {
            let box = pathBounds(group.strokes)
            // The student's own tone marks: small strokes that sit wholly above the letters. Not an i's dot, which is tinier.
            let feet = group.strokes.map { pathBounds([$0]).maxY }.sorted()
            let baseline = feet[feet.count / 2]
            let isMark: (CGRect) -> Bool = { r in
                r.maxY < baseline - 0.3 * em && max(r.width, r.height) >= 0.15 * em && r.width <= 0.8 * em && r.height <= 0.6 * em
            }
            let marks = group.strokes.filter { isMark(pathBounds([$0])) }
            let body = group.strokes.filter { !isMark(pathBounds([$0])) }
            // Letters written apart are found exactly; joined ones are placed by their share of the word's width.
            let characters = Array(group.text)
            let offsets = CleanHandwriting.offsets(in: group.text)
            guard offsets.count == characters.count + 1, let full = offsets.last, full > 0, !box.isEmpty else { return nil }
            let apart = columns(body)
            let exact = apart.count == characters.count
            let bodyBox = body.isEmpty ? box : pathBounds(body)
            for (position, character) in characters.enumerated() where !Lexicon.foldedLetters(String(character)).isEmpty {
                defer { index += 1 }
                guard index < want.count, want[index].tone != have[index].tone else { continue }
                let left = exact ? apart[position].minX : bodyBox.minX + bodyBox.width * offsets[position] / full
                let right = exact ? apart[position].maxX : bodyBox.minX + bodyBox.width * offsets[position + 1] / full
                // The mark the student put over this letter, if the readers saw one there.
                if have[index].tone != nil {
                    let slack = 0.3 * (right - left)
                    guard let old = marks.filter({ let r = pathBounds([$0]); return r.midX >= left - slack && r.midX <= right + slack })
                        .min(by: { abs(pathBounds([$0]).midX - (left + right) / 2) < abs(pathBounds([$1]).midX - (left + right) / 2) })
                    else {
                        #if DEBUG
                        DebugTrace.log("replace: no tone mark found in the ink over “\(character)”")
                        #endif
                        return nil
                    }
                    wrong.append(old)
                }
                guard let tone = want[index].tone else { continue }
                let gone = Set(wrong.map(InkSelection.identity))
                let points = group.strokes.filter { !gone.contains(InkSelection.identity($0)) }
                    .flatMap { stroke in stroke.path.interpolatedPoints(by: .distance(2)).map { $0.location.applying(stroke.transform) } }
                // The letter's own strokes say where it is; a joined word only tells by its share of the width.
                let own = body.map { pathBounds([$0]) }.filter {
                    $0.midX >= left - 0.2 * (right - left) && $0.midX <= right + 0.2 * (right - left) && $0.width <= 1.5 * (right - left)
                        && $0.height >= 0.2 * em
                }.min { abs($0.midX - (left + right) / 2) < abs($1.midX - (left + right) / 2) }
                let center = own?.midX ?? (left + right) / 2
                let reach = max((right - left) * 0.35, 0.08 * em)
                let w = 0.15 * em, h = 0.14 * em
                var top = own?.minY ?? points.filter { abs($0.x - center) <= reach }.map(\.y).min() ?? box.minY
                // Over whatever else reaches into its place: a dot, or the hook of the letter before.
                for _ in 0..<3 {
                    let place = CGRect(x: center - w, y: top - 0.12 * em - h, width: 2 * w, height: h + 0.1 * em)
                    guard let blocked = points.filter({ place.contains($0) }).map(\.y).min() else { break }
                    top = blocked
                }
                let y = top - 0.1 * em - h / 2
                let line: [CGPoint]
                switch tone {
                case 1: line = [CGPoint(x: center - w, y: y), CGPoint(x: center + w, y: y)]
                case 2: line = [CGPoint(x: center - w, y: y + h / 2), CGPoint(x: center + w, y: y - h / 2)]
                case 3: line = [CGPoint(x: center - w, y: y - h / 2), CGPoint(x: center, y: y + h / 2), CGPoint(x: center + w, y: y - h / 2)]
                default: line = [CGPoint(x: center - w, y: y - h / 2), CGPoint(x: center + w, y: y + h / 2)]
                }
                result.append(CleanHandwriting.stroke(dense(line), pen: pen))
            }
        }
        return (result, wrong)
    }

    /// `target` divided after its first `letters` (tones ignored): the part written, and the syllables left off. All of
    /// `target` and nothing left off when `letters` is not where `target` begins.
    static func divide(_ target: String, after letters: String) -> (head: String, tail: String) {
        let plain = Lexicon.foldedLetters(target)
        guard !letters.isEmpty, letters.count < plain.count, plain.hasPrefix(letters) else { return (target, "") }
        var count = 0
        var head = ""
        var rest = Substring(target)
        while count < letters.count, let character = rest.first {
            head.append(character)
            rest = rest.dropFirst()
            if !Lexicon.foldedLetters(String(character)).isEmpty { count += 1 }
        }
        return (head, rest.trimmingCharacters(in: .whitespaces))
    }

    /// `text` with its tone marks taken off; ü keeps its dots.
    static func untoned(_ text: String) -> String {
        let marks: Set<UInt32> = [0x0304, 0x0301, 0x030C, 0x0300]
        let kept = text.decomposedStringWithCanonicalMapping.unicodeScalars.filter { !marks.contains($0.value) }
        return String(String.UnicodeScalarView(kept)).precomposedStringWithCanonicalMapping
    }

    /// `target`'s letters, without tones, in the words `read` was read as, when they correspond letter for letter.
    private static func respelled(_ read: String, as target: String) -> String? {
        let words = FieldValidation.words(read).map { Lexicon.foldedLetters($0).count }.filter { $0 > 0 }
        var letters = Array(Lexicon.foldedLetters(target))
        guard words.reduce(0, +) == letters.count else { return nil }
        return words.map { count in
            defer { letters.removeFirst(count) }
            return String(letters.prefix(count))
        }.joined(separator: " ")
    }

    private static func dense(_ line: [CGPoint]) -> [CGPoint] {
        var points: [CGPoint] = []
        for (a, b) in zip(line, line.dropFirst()) {
            for step in 0..<6 {
                let t = CGFloat(step) / 6
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return points + line.suffix(1)
    }

    /// The x-extents of writing separated by blank space, left to right.
    private static func columns(_ strokes: [PKStroke]) -> [CGRect] {
        var result: [CGRect] = []
        for rect in strokes.map({ pathBounds([$0]) }).sorted(by: { $0.minX < $1.minX }) {
            if let last = result.last, rect.minX <= last.maxX { result[result.count - 1] = last.union(rect) } else { result.append(rect) }
        }
        return result
    }

    // MARK: - Measuring

    /// Sized word by word (character by character for Hanzi), so a line that slopes is not taken for bigger writing.
    private static func measure(_ text: String, _ strokes: [PKStroke]) -> Measure? {
        guard !strokes.isEmpty, !text.isEmpty else { return nil }
        let words = FieldValidation.isHanzi(text) ? text.map(String.init) : text.split(whereSeparator: \.isWhitespace).map(String.init)
        let groups = split(strokes, into: words).map { Array(zip(words, $0)) } ?? [(text, strokes)]
        var ems: [CGFloat] = []
        var baselines: [CGFloat] = []
        for (word, ink) in groups {
            let box = pathBounds(ink)
            guard let shape = CleanHandwriting.bounds(of: word, em: 1), shape.height > 0, shape.width > 0, box.height > 0 else { continue }
            if FieldValidation.isHanzi(word) {
                // A character is about as wide as it is tall; one long stroke must not make all of it look bigger.
                let em = (box.height / shape.height + box.width / shape.width) / 2
                ems.append(em)
                baselines.append(box.midY - shape.midY * em)
                continue
            }
            let letters = word.map(String.init)
            let apart = columns(ink)
            if apart.count == letters.count {
                // Each letter says how big it is. The middle one is not swayed by a tall `h` or a long tail.
                for (letter, place) in zip(letters, apart) {
                    if let own = CleanHandwriting.bounds(of: letter, em: 1), own.height > 0, place.height > 0 { ems.append(place.height / own.height) }
                }
                let feet = zip(letters, apart).filter { !"gjpqy".contains(Lexicon.foldedLetters($0.0)) }.map(\.1.maxY).sorted()
                baselines.append(feet.isEmpty ? box.maxY - shape.maxY * box.height / shape.height : feet[feet.count / 2])
            } else {
                let em = min(box.height / shape.height, box.width / shape.width)
                ems += Array(repeating: em, count: letters.count)
                baselines.append(box.maxY - shape.maxY * box.height / shape.height)
            }
        }
        guard let first = baselines.first, let last = baselines.last, !ems.isEmpty else { return nil }
        ems.sort()
        return Measure(bounds: pathBounds(strokes), baseline: first, end: last, em: min(max(ems[(ems.count - 1) / 2], 12), 220))
    }

    /// Where the pen went, without the width of the line.
    static func pathBounds(_ strokes: [PKStroke]) -> CGRect {
        strokes.reduce(CGRect.null) { total, stroke in
            let points = stroke.path.interpolatedPoints(by: .distance(3)).map { $0.location.applying(stroke.transform) }
            guard let first = points.first else { return total.union(stroke.renderBounds) }
            return points.reduce(total.union(CGRect(origin: first, size: .zero))) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
    }
}
