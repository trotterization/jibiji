import Foundation
import PencilKit
import Testing
@testable import JIBIJI

/// A fixed sheet of short, real words the student writes once on the iPad (docs/testing/test-sheet.md). Every note has a
/// known answer, so a pulled copy of the written pages can be scored: is each word found, with the right Hanzi and the
/// right Pinyin? The words are ordinary vocabulary, nothing from a private page.
enum TestSheet {
    struct Note: Sendable {
        var number: Int
        var page: Int
        /// What to write, as the sheet tells the student.
        var write: String
        /// How to place it, when it matters.
        var layout: String = ""
        var hanzi: String
        /// The reading the dictionary should give, tones and all. Compared ignoring case and spaces.
        var pinyin: String
        /// A word the meaning should contain, when the dictionary has more than one sense.
        var meaning: String? = nil
    }

    static let notes: [Note] = [
        // Page 1: which fields are there, and how the tones are written.
        .init(number: 1, page: 1, write: "你好 nǐ hǎo hello", hanzi: "你好", pinyin: "nǐhǎo", meaning: "hello"),
        .init(number: 2, page: 1, write: "谢谢 xiè xie thank you", layout: "second syllable has no mark (neutral)", hanzi: "谢谢", pinyin: "xièxie"),
        .init(number: 3, page: 1, write: "好   hǎo xiàng", layout: "leave a gap after 好; no meaning", hanzi: "好像", pinyin: "hǎoxiàng"),
        .init(number: 4, page: 1, write: "学习 xue xi to study", layout: "no tone marks", hanzi: "学习", pinyin: "xuéxí"),
        .init(number: 5, page: 1, write: "朋友 péng you", layout: "no meaning", hanzi: "朋友", pinyin: "péngyou"),
        .init(number: 6, page: 1, write: "老师 lǎo shí teacher", layout: "the mark on shi is wrong on purpose", hanzi: "老师", pinyin: "lǎoshī"),
        .init(number: 7, page: 1, write: "中国 zhōng", layout: "Pinyin stops after zhōng; no meaning", hanzi: "中国", pinyin: "zhōngguó"),
        .init(number: 8, page: 1, write: "喜欢", layout: "Hanzi only", hanzi: "喜欢", pinyin: "xǐhuan"),
        .init(number: 9, page: 1, write: "māma", layout: "Pinyin only", hanzi: "妈妈", pinyin: "māma"),
        .init(number: 10, page: 1, write: "女 nǚ woman", layout: "ü with its dots", hanzi: "女", pinyin: "nǚ"),
        .init(number: 11, page: 1, write: "六 liù six", hanzi: "六", pinyin: "liù", meaning: "six"),
        .init(number: 12, page: 1, write: "知道 zhīdào to know", layout: "Pinyin joined, no space", hanzi: "知道", pinyin: "zhīdào"),
        .init(number: 13, page: 1, write: "等于 deng", layout: "no mark, second syllable left off", hanzi: "等于", pinyin: "děngyú"),
        // Page 2: where things are on the page.
        .init(number: 14, page: 2, write: "电脑 computer, with diàn nǎo", layout: "Pinyin ABOVE the Hanzi, meaning to the right", hanzi: "电脑", pinyin: "diànnǎo"),
        .init(number: 15, page: 2, write: "苹果 píng guǒ, then apple", layout: "the meaning on the line BELOW", hanzi: "苹果", pinyin: "píngguǒ", meaning: "apple"),
        .init(number: 16, page: 2, write: "咖啡 kā fēi coffee", layout: "right at the right edge of the screen", hanzi: "咖啡", pinyin: "kāfēi", meaning: "coffee"),
        .init(number: 17, page: 2, write: "医生 yī shēng doctor", layout: "let the line slope upward", hanzi: "医生", pinyin: "yīshēng"),
        .init(number: 18, page: 2, write: "大 dà big", layout: "very large", hanzi: "大", pinyin: "dà", meaning: "big"),
        .init(number: 19, page: 2, write: "小 xiǎo small", layout: "very small", hanzi: "小", pinyin: "xiǎo", meaning: "small"),
        .init(number: 20, page: 2, write: "猫 māo cat", layout: "same line as 21, with a wide gap", hanzi: "猫", pinyin: "māo", meaning: "cat"),
        .init(number: 21, page: 2, write: "狗 gǒu dog", layout: "same line as 20", hanzi: "狗", pinyin: "gǒu", meaning: "dog"),
        .init(number: 22, page: 2, write: "茶 chá tea", layout: "draw a circle around 茶", hanzi: "茶", pinyin: "chá", meaning: "tea"),
        .init(number: 23, page: 2, write: "睡觉 shuì jiào to sleep", layout: "draw an arrow pointing at it from the left", hanzi: "睡觉", pinyin: "shuìjiào"),
        // Page 3: kinds of words.
        .init(number: 24, page: 3, write: "虎头蛇尾 hǔ tóu shé wěi", layout: "idiom; no meaning", hanzi: "虎头蛇尾", pinyin: "hǔtóushéwěi"),
        .init(number: 25, page: 3, write: "虽然 suī rán although", hanzi: "虽然", pinyin: "suīrán"),
        .init(number: 26, page: 3, write: "但是 dàn shì but", hanzi: "但是", pinyin: "dànshì"),
        .init(number: 27, page: 3, write: "已经 yǐ jīng already", layout: "已, not 己", hanzi: "已经", pinyin: "yǐjīng"),
        .init(number: 28, page: 3, write: "自己 zì jǐ oneself", layout: "己, not 已", hanzi: "自己", pinyin: "zìjǐ"),
        .init(number: 29, page: 3, write: "认真 rèn zhēn serious", hanzi: "认真", pinyin: "rènzhēn"),
        .init(number: 30, page: 3, write: "伤 shāng injury", hanzi: "伤", pinyin: "shāng"),
        .init(number: 31, page: 3, write: "四 sì four", hanzi: "四", pinyin: "sì", meaning: "four"),
        .init(number: 32, page: 3, write: "十 shí ten", hanzi: "十", pinyin: "shí", meaning: "ten"),
        .init(number: 33, page: 3, write: "中文 Zhōngwén Chinese", layout: "capital Z, joined", hanzi: "中文", pinyin: "zhōngwén"),
        .init(number: 34, page: 3, write: "北京 Běi jīng Beijing", layout: "capital B", hanzi: "北京", pinyin: "běijīng"),
        .init(number: 35, page: 3, write: "时间 shí jiān time", hanzi: "时间", pinyin: "shíjiān"),
        .init(number: 36, page: 3, write: "吃饭 chī fàn to eat", hanzi: "吃饭", pinyin: "chīfàn"),
    ]

    static func plain(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased().filter { !$0.isWhitespace }
    }
}

@Suite("Test sheet")
struct TestSheetTests {
    /// The sheet's answers are what the app's own dictionary lookup gives. A failure here is either a wrong answer on the
    /// sheet or the app choosing the wrong dictionary entry (a surname or a company before the common word).
    @Test func everyAnswerIsWhatTheAppsDictionaryGives() throws {
        let lexicon = try #require(Lexicon.shared)
        #expect(Set(TestSheet.notes.map(\.number)).count == TestSheet.notes.count)
        for note in TestSheet.notes {
            let empty = ResolvedNote(hanzi: .init(value: note.hanzi, status: .confirmed), pinyin: .absent, english: .absent, diagnostics: [])
            let reading = lexicon.reading(of: note.hanzi, in: empty)
            #expect(reading.map { TestSheet.plain($0.pinyin) } == TestSheet.plain(note.pinyin),
                    "\(note.number) \(note.hanzi): the app reads \(reading?.pinyin ?? "nothing"), the sheet says \(note.pinyin)")
            if let word = note.meaning, let reading {
                let gloss = lexicon.gloss(of: note.hanzi, pinyin: reading.pinyin) ?? ""
                #expect(gloss.lowercased().contains(word), "\(note.number) \(note.hanzi): meaning “\(gloss)” lacks “\(word)”")
            }
        }
    }
}

/// Scores the written sheet, when its pages have been pulled from the iPad (scripts/pull-ipad-evidence.sh). Opt-in with
/// `TEST_RUNNER_JIBIJI_SHEET=1` (reading every page takes a couple of minutes); `TEST_RUNNER_JIBIJI_PAGES=page-14,…`
/// limits it to the sheet's pages. Writes `ipad/sheet-report.md` beside the repository. Records an issue only when the app
/// makes a card for a sheet word with the wrong Pinyin, which is a real bug; a word not found is listed, not failed.
@Suite("Written test sheet (local, opt-in)", .serialized)
@MainActor
struct WrittenTestSheetTests {
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["JIBIJI_SHEET"] == "1" && !IPadEvidence.pages.isEmpty
    }

    @Test(.enabled(if: WrittenTestSheetTests.enabled))
    func theWrittenSheetIsScored() async throws {
        let notesFolder = IPadEvidence.folder.appending(path: "Notes")
        let only = ProcessInfo.processInfo.environment["JIBIJI_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        var cards: [(page: String, front: String, back: String)] = []
        var suggestions: [(page: String, text: String)] = []
        for pageID in IPadEvidence.pages where only?.contains(pageID) ?? true {
            guard let drawing = try NoteStore(directory: notesFolder).loadDrawing(pageID: pageID), !drawing.strokes.isEmpty else { continue }
            let outcome = await IPadEvidence.run(drawing, reader: PencilInkLineReader(mode: .suggestions), annotations: notesFolder, pageID: pageID)
            for card in outcome.cards {
                let parts = card.components(separatedBy: " — ")
                cards.append((pageID, parts.first ?? card, parts.dropFirst().joined(separator: " — ")))
            }
            suggestions += outcome.suggestions.map { (pageID, $0) }
        }
        var lines = ["# Test sheet score", "", "Written by the local tests. Private: stays beside the repository.", "",
                     "| # | Word | Found | Pinyin | Where |", "| --- | --- | --- | --- | --- |"]
        var found = 0, right = 0
        for note in TestSheet.notes {
            let card = cards.first { $0.front == note.hanzi }
            let suggested = suggestions.first { $0.text.contains("→ \(note.hanzi) · ") }
            let pinyin = card.map { TestSheet.plain($0.back).hasPrefix(TestSheet.plain(note.pinyin)) }
                ?? suggested.map { TestSheet.plain($0.text).contains("·\(TestSheet.plain(note.pinyin))·") }
            if card != nil || suggested != nil { found += 1 }
            if pinyin == true { right += 1 }
            if let card, pinyin == false {
                Issue.record("\(note.number) \(note.hanzi): card says “\(card.back)”, the word is \(note.pinyin)")
            }
            let where_ = card.map { "card on \($0.page)" } ?? suggested.map { "suggestion on \($0.page)" } ?? "-"
            lines.append("| \(note.number) | \(note.hanzi) | \(card != nil || suggested != nil ? "yes" : "**no**") | \(pinyin.map { $0 ? "right" : "**wrong**" } ?? "-") | \(where_) |")
        }
        lines.insert("**\(found) of \(TestSheet.notes.count) words found, \(right) with the right Pinyin.**", at: 4)
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: IPadEvidence.folder.appending(path: "sheet-report.md"), atomically: true, encoding: .utf8)
        print(text)
    }
}

/// Opt-in: writes, for every common word (frequency ≥ 1500), the reading and card meaning the app gives from the Hanzi
/// alone, to the path in `TEST_RUNNER_JIBIJI_LEXICON_DUMP`. Two dumps, before and after a dictionary change, diff into
/// exactly what the change does to cards.
@Suite("Dictionary dump (opt-in)")
struct LexiconDumpTests {
    nonisolated static var path: String? { ProcessInfo.processInfo.environment["JIBIJI_LEXICON_DUMP"] }

    @Test(.enabled(if: LexiconDumpTests.path != nil))
    func dumpCommonWords() throws {
        let lexicon = try #require(Lexicon.shared)
        let url = try #require(Bundle.main.url(forResource: "CEDICT", withExtension: "tsv"))
        var best: [String: Int] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count > 3, let freq = Int(f[3]), freq >= 1500 else { continue }
            best[String(f[0]), default: 0] = max(best[String(f[0])] ?? 0, freq)
        }
        var out = ""
        for (hanzi, _) in best.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
            let empty = ResolvedNote(hanzi: .init(value: hanzi, status: .confirmed), pinyin: .absent, english: .absent, diagnostics: [])
            let reading = lexicon.reading(of: hanzi, in: empty)
            let gloss = reading.flatMap { lexicon.gloss(of: hanzi, pinyin: $0.pinyin) } ?? ""
            out += "\(hanzi)\t\(reading?.pinyin ?? "")\t\(gloss)\n"
        }
        try out.write(toFile: try #require(Self.path), atomically: true, encoding: .utf8)
    }
}
