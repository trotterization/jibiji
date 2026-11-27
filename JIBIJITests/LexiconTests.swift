import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import JIBIJI

/// The bundled CC-CEDICT dictionary: real entries, no AI. These run against the actual table in the app bundle.
@Suite(.serialized) struct LexiconTests {
    /// The app's vocabulary with the dictionary loaded up front (the app itself never waits for it on the main thread).
    private var full: StarterVocabulary { StarterVocabulary(entries: StarterVocabulary.standard.entries, lexicon: Lexicon.shared) }

    @Test func loadsTheBundledDictionary() throws {
        let lexicon = try #require(Lexicon.shared)
        #expect(lexicon.count > 100_000)
        #expect(lexicon.rows(forHanzi: "电脑").first?.numbered == "dian4 nao3")
    }

    @Test func aClassifierNoteInsideASenseDropsOnlyTheNote() {
        // 猫 is "cat (CL:隻|只[zhi1]) | (dialect) to hide oneself": the card says cat, not the dialect sense.
        #expect(Lexicon.cleanSenses(["cat (CL:隻|只[zhi1])", "(dialect) to hide oneself"]) == ["cat", "(dialect) to hide oneself"])
        #expect(Lexicon.shortGloss(["cat (CL:隻|只[zhi1])", "(dialect) to hide oneself"]).hasPrefix("cat"))
        #expect(Lexicon.cleanSenses(["CL:個|个[ge4]"]).isEmpty, "a sense that is only a classifier list still goes")
    }

    /// Common words whose meaning quoted Hanzi, or that are names or places, used to get a card with no meaning at all.
    @Test func commonWordsKeepTheirMeaningWhenTheDictionaryQuotesHanzi() throws {
        let lexicon = try #require(Lexicon.shared)
        #expect(lexicon.gloss(of: "虽然", pinyin: "suīrán") == "although; even though", "the note quoting 可是 goes, the meaning stays")
        #expect(lexicon.gloss(of: "你", pinyin: "nǐ") == "you")
        #expect(lexicon.gloss(of: "部分", pinyin: "bùfen")?.hasPrefix("part") == true, "a Taiwan pronunciation note does not hide the word")
        #expect(lexicon.gloss(of: "中国", pinyin: "Zhōngguó") == "China", "a place the student wrote in Hanzi gets its meaning")
        #expect(lexicon.gloss(of: "院长", pinyin: "yuànzhǎng")?.hasPrefix("chair of a board") == true, "a clause left dangling is dropped")
        #expect(lexicon.gloss(of: "明", pinyin: "míng") == "bright; (of meaning) clear", "meanings that were fine stay as they were")
        #expect(lexicon.gloss(of: "猫", pinyin: "māo")?.hasPrefix("cat") == true)
        #expect(lexicon.gloss(of: "湖北", pinyin: "Húběi") == nil, "a cross-reference is still not a meaning")
    }

    @Test func numberedTonesBecomeMarks() {
        #expect(Lexicon.toneMarked("hao3 xiang4") == "hǎoxiàng")
        #expect(Lexicon.toneMarked("nu:3") == "nǚ")
        #expect(Lexicon.toneMarked("lu:e4") == "lüè")
        #expect(Lexicon.toneMarked("liu2") == "liú")
        #expect(Lexicon.toneMarked("gui4") == "guì")
        #expect(Lexicon.toneMarked("dou1") == "dōu")
        #expect(Lexicon.toneMarked("xie4 xie5") == "xièxie")
        #expect(Lexicon.toneMarked("xue2 xi2") == "xuéxí")
    }

    @Test func aWrittenWordGetsItsDictionaryPinyinAndMeaning() throws {
        let proposal = try #require(full.proposal(forRecognizedText: "电脑"))
        #expect(proposal.candidates.first?.hanzi == "电脑")
        #expect(proposal.candidates.first?.pinyin == "diànnǎo")
        #expect(proposal.candidates.first?.gloss == "computer")
        #expect(proposal.hanziAlreadyWritten)
    }

    @Test func aSingleHanziOffersEveryReading() throws {
        let proposal = try #require(full.proposal(forRecognizedText: "好"))
        let pinyins = proposal.candidates.map(\.pinyin)
        #expect(pinyins.contains("hǎo"))
        #expect(pinyins.contains("hào"))
    }

    @Test func writtenPinyinFindsTheWord() throws {
        let proposal = try #require(full.proposal(forRecognizedText: "xuéxí"))
        #expect(proposal.candidates.first?.hanzi == "学习")
        #expect(proposal.candidates.first?.gloss == "to learn; to study")
        #expect(!proposal.hanziAlreadyWritten)
    }

    @Test func writtenTonesChooseTheEntry() throws {
        // `ma` has many readings; the written tone picks among them, never guesses an untoned one.
        let proposal = try #require(full.proposal(forRecognizedText: "mā"))
        #expect(proposal.candidates.first?.pinyin.hasPrefix("mā") == true)
    }

    @Test func aNearbyWrongToneIsFlaggedNotCorrectedSilently() throws {
        let proposal = try #require(full.proposal(forRecognizedText: "电脑 diàn nào"))
        #expect(proposal.pinyinState.isUncertain)
        #expect(proposal.candidates.first?.pinyin == "diànnǎo")
    }

    @Test func englishWordsAreNotLookedUp() {
        for word in ["he", "me", "ma", "table", "hello world", "the", "like", "name", "long", "song"] {
            #expect(full.proposal(forRecognizedText: word) == nil, "\(word) must not become Hanzi")
        }
    }

    @Test func unknownHanziAbstains() {
        #expect(full.proposal(forRecognizedText: "龘龘龘") == nil)
    }

    @Test func curatedEntriesStillWin() throws {
        let proposal = try #require(full.proposal(forRecognizedText: "好 hǎo xiang"))
        #expect(proposal.candidates.first?.hanzi == "好像")
        #expect(proposal.candidates.first?.gloss == "to seem like; to look like")
    }

    @Test func properNamesAndVariantsAreNeverOfferedFromPinyinAlone() throws {
        let lexicon = try #require(Lexicon.shared)
        let rows = lexicon.candidates(forText: "zhōngguó")
        #expect(rows.allSatisfy { !$0.isProperName && !$0.isVariant })
    }

    @Test func theStarterVocabularyAloneStillAbstainsOnUnknownWords() {
        #expect(StarterVocabulary.standard.proposal(forRecognizedText: "电脑") == nil)
    }

    // MARK: - Repair of misread Pinyin (invented readings of `学 xué xí`)

    private let deviceGuesses = ["xve xí", "xú xí", "xúo xi", "xúe xi", "xúo xí", "xúe xí", "xú ×í"]

    @Test func misreadPinyinIsRepairedFromTheDictionary() throws {
        let proposal = try #require(full.repairedProposal(forRecognizedText: "学 xú xí", latinEvidence: deviceGuesses))
        #expect(proposal.candidates.first?.hanzi == "学习")
        #expect(proposal.candidates.first?.pinyin == "xuéxí")
        #expect(proposal.pinyinFromDictionary)
        #expect(proposal.pinyinState.isUncertain)
    }

    @Test func repairNeedsOneHanziRunAndCloseEvidence() {
        #expect(full.repairedProposal(forRecognizedText: "学 xú xí", latinEvidence: []) == nil)
        #expect(full.repairedProposal(forRecognizedText: "学 xú xí", latinEvidence: ["zzz qqq", "he"]) == nil)
        #expect(full.repairedProposal(forRecognizedText: "学 电脑 xú", latinEvidence: deviceGuesses) == nil)
        // With no Hanzi the repair is a note-only guess from spelling and tones; evidence that is nowhere near any word gives nothing.
        #expect(full.repairedProposal(forRecognizedText: "qqq", latinEvidence: ["qqqq", "zzzz"]) == nil)
    }

    @Test func aWordThatExplainsMoreOfTheWrittenPinyinRanksFirst() throws {
        let proposal = try #require(full.proposal(forRecognizedText: "学 xúe xí"))
        #expect(proposal.candidates.first?.hanzi == "学习")
        // The accent sits on the wrong letter: flagged as a tone-mark difference, not silently accepted.
        #expect(proposal.pinyinState == .wrongTones(written: "xúe xí"))
        // A bare Hanzi still looks up only itself.
        #expect(full.proposal(forRecognizedText: "学")?.candidates.first?.hanzi == "学")
    }

    @Test func repairIsAlsoOfferedAsANoteWithTheDictionaryPinyin() throws {
        let proposal = try #require(full.repairedProposal(forRecognizedText: "学 xú xí", latinEvidence: deviceGuesses))
        let item = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: "学 xú xí", proposal: proposal)
        #expect(item.annotationText.contains("(xuéxí)"))
        #expect(item.cleanText == "学习 · xuéxí · to learn; to study")
    }

    // MARK: - Pinyin with no Hanzi

    @Test func pinyinWithNoHanziIsRepairedAsANoteOnly() throws {
        let proposal = try #require(full.repairedProposal(forRecognizedText: "xú xí", latinEvidence: deviceGuesses))
        #expect(proposal.candidates.first?.hanzi == "学习")
        #expect(proposal.pinyinFromDictionary)
        #expect(!proposal.hanziAlreadyWritten)
        let near = try #require(full.repairedProposal(forRecognizedText: "diàn nǎo", latinEvidence: ["diàn nǎo", "dian nao"]))
        #expect(near.candidates.first?.hanzi == "电脑")
    }

    @Test func pinyinOnlyRepairNeedsCloseEvidenceAndAgreeingTones() {
        #expect(full.repairedProposal(forRecognizedText: "zz", latinEvidence: ["zzzz qqq", "xxxx"]) == nil)
        // Tone marks that disagree with the word rule it out: xué xí (2, 2) is not 血洗 xuèxǐ (4, 3).
        let rows = Lexicon.shared?.repairCandidates(forPinyinReadings: ["xúe xí"]) ?? []
        #expect(rows.first?.hanzi == "学习")
        #expect(!rows.contains { $0.hanzi == "血洗" })
    }

    // MARK: - Word frequency

    @Test func commonWordsRankBeforeRareOnesSpelledTheSame() throws {
        let shi = try #require(full.proposal(forRecognizedText: "shì"))
        #expect(shi.candidates.first?.hanzi == "是")
        let da = try #require(full.proposal(forRecognizedText: "dà"))
        #expect(da.candidates.first?.hanzi == "大")
        #expect((Lexicon.shared?.rows(forHanzi: "学习").first?.frequency ?? 0) > 1000)
    }

    // MARK: - Independent review fixes

    @Test func aWrittenHanziOffersItsEverydayMeaningFirst() throws {
        let expected: [String: (pinyin: String, gloss: String)] = [
            "和": ("hé", "and"), "上": ("shàng", "up"), "与": ("yǔ", "and"), "也": ("yě", "also"), "个": ("gè", "classifier"),
        ]
        for (hanzi, want) in expected {
            let proposal = try #require(full.proposal(forRecognizedText: hanzi), "\(hanzi)")
            #expect(proposal.candidates.first?.pinyin == want.pinyin, "\(hanzi)")
            #expect(proposal.candidates.first?.gloss.contains(want.gloss) == true, "\(hanzi): \(proposal.candidates.first?.gloss ?? "")")
        }
    }

    @Test func glossesNeverQuoteDictionaryMarkup() throws {
        let lexicon = try #require(Lexicon.shared)
        for hanzi in ["和", "上", "与", "个", "也", "时", "过"] {
            for row in lexicon.rows(forHanzi: hanzi) {
                #expect(!row.gloss.contains("[") && !row.gloss.contains("|"), "\(hanzi): \(row.gloss)")
                #expect(!row.gloss.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }, "\(hanzi): \(row.gloss)")
            }
        }
    }

    @Test func joinedPinyinIsMatchedByItsToneMarksInOrder() throws {
        #expect(full.proposal(forRecognizedText: "shíjiàn")?.candidates.first?.hanzi == "实践")
        #expect(full.proposal(forRecognizedText: "xuèxǐ")?.candidates.first?.hanzi == "血洗")
        #expect(Lexicon.shared?.repairCandidates(forPinyinReadings: ["xuèxǐ"]).first?.hanzi == "血洗")
    }

    @Test func aPlainSyllableIsLookedUpOnlyWhenTheNoteSaysItIsPinyin() throws {
        #expect(full.proposal(forRecognizedText: "Shi") == nil)
        #expect(full.proposal(forRecognizedText: "Shi", latinIsPinyin: true)?.candidates.first?.hanzi == "是")
        #expect(full.proposal(forRecognizedText: "xuéxí", latinIsPinyin: false) == nil)
    }

    @Test func repairKeepsTheStudentsOwnEnglish() throws {
        let proposal = try #require(full.repairedProposal(forRecognizedText: "电脑 diàn nao", latinEvidence: ["diàn nao"],
                                                          writtenPinyin: "diàn nao", writtenEnglish: "laptop"))
        #expect(proposal.candidates.first?.hanzi == "电脑")
        #expect(proposal.writtenGloss == "laptop")
        let item = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: "电脑 diàn nao laptop", proposal: proposal)
        #expect(item.cleanText.hasSuffix("laptop"))
    }

    // MARK: - Tones for a phrase the dictionary has no single entry for

    @Test func aPhraseGetsItsTonesWordByWord() throws {
        let lexicon = try #require(Lexicon.shared)
        #expect(lexicon.rows(forHanzi: "农夫市集").isEmpty, "not one dictionary word")
        #expect(lexicon.pinyin(forPhrase: "农夫市集", written: "nong fu shi ji") == "nóngfū shìjí")
        #expect(lexicon.pinyin(forPhrase: "农夫市集", written: "nongfu shiji") == "nóngfū shìjí")
        #expect(lexicon.pinyin(forPhrase: "农夫市集", written: nil) == "nóngfū shìjí")
        #expect(lexicon.pinyin(forPhrase: "电脑", written: "dian nao") == "diànnǎo")
        // Student tones that agree are kept in the result; tones that disagree leave the student's Pinyin alone.
        #expect(lexicon.pinyin(forPhrase: "农夫市集", written: "nóng fu shi ji") == "nóngfū shìjí")
        #expect(lexicon.pinyin(forPhrase: "农夫市集", written: "nòng fu shi ji") == nil)
        // Letters that do not spell these words give nothing.
        #expect(lexicon.pinyin(forPhrase: "农夫市集", written: "nong fu shi qi") == nil)
    }

    @Test func aWordWithTwoTonesForTheSameLettersIsNotGuessed() throws {
        let lexicon = try #require(Lexicon.shared)
        // 好 is hǎo or hào; 东西 is dōngxī or dōngxi. The letters alone cannot choose, so nothing is toned.
        #expect(lexicon.pinyin(forPhrase: "好", written: "hao") == nil)
        #expect(lexicon.pinyin(forPhrase: "东西", written: "dongxi") == nil)
        #expect(lexicon.pinyin(forPhrase: "好", written: nil) == nil)
        // A tone the student wrote does choose.
        #expect(lexicon.pinyin(forPhrase: "好", written: "hǎo") == "hǎo")
        // In a longer phrase the known words are toned and the undecided one keeps the student's letters.
        #expect(lexicon.pinyin(forPhrase: "农夫东西", written: "nong fu dong xi") == "nóngfū dongxi")
    }

    @Test func aCardForAnUnlistedPhraseGetsDictionaryTones() throws {
        // 电脑市集 is neither in the starter list nor one dictionary word; 电脑 and 市集 are.
        let lexicon = try #require(Lexicon.shared)
        var line = RecognizedLine(text: "电脑市集 dian nao shi ji computer fair", bounds: .zero)
        line.resolved = ResolvedNote(
            hanzi: .init(value: "电脑市集", status: .confirmed), pinyin: .init(value: "dian nao shi ji", status: .confirmed),
            english: .init(value: "computer fair", status: .confirmed), diagnostics: [])
        let draft = try #require(FlashcardExtractor.extract(from: line, lexicon: lexicon))
        #expect(draft.front == "电脑市集")
        #expect(draft.back == "diànnǎo shìjí — computer fair")
        #expect(draft.needsReview, "not one dictionary word: the student checks it")
        // Without the dictionary the written Pinyin is kept as written.
        let plain = FlashcardExtractor.extract(from: line, lexicon: nil)?.back
        #expect(plain == "dian nao shi ji — computer fair")
        // No Pinyin written: the dictionary's reading is added.
        var unwritten = line
        unwritten.resolved?.pinyin = .absent
        let added = FlashcardExtractor.extract(from: unwritten, lexicon: lexicon)?.back
        #expect(added == "diànnǎo shìjí — computer fair")
        // Pinyin written but unreadable is never replaced.
        var unreadable = line
        unreadable.resolved?.pinyin = .init(value: nil, status: .unresolved)
        let kept = FlashcardExtractor.extract(from: unreadable, lexicon: lexicon)?.back
        #expect(kept?.contains("diànnǎo") != true)
    }

    @Test func theReplacePreviewAddsTonesToUntonedPinyin() throws {
        // The preview once kept untoned Pinyin as written.
        let proposal = try #require(full.proposal(forRecognizedText: "农夫市集 nong fu shi ji farmers market"))
        #expect(proposal.pinyinState == .missingTones)
        let item = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: "农夫市集 nong fu shi ji farmers market", proposal: proposal)
        #expect(item.cleanText == "农夫市集 · nóngfū shìjí · farmers market")
        // Any other Pinyin (wrong tones, misread letters) never reaches the Replace text: it writes the word's reading.
        for written in ["nòngfū shìjí", "nang fu shi ji", "none fu shi ji", "nóng fu shi ji"] {
            let text = "农夫市集 \(written) farmers market"
            guard let proposal = full.proposal(forRecognizedText: text) else { continue }
            let item = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: text, proposal: proposal)
            #expect(item.cleanText == "农夫市集 · nóngfū shìjí · farmers market", "\(written)")
        }
    }

    @Test func replaceNeverWritesPinyinTheDictionaryDoesNotHave() throws {
        // Pinyin the readers resolved wrongly (`nang fu shi ji`).
        var proposal = try #require(full.proposal(forRecognizedText: "农夫市集 nong fu shi ji farmers market"))
        proposal.writtenPinyin = "nang fu shi ji"
        proposal.pinyinState = .possibleSpelling(written: "nang fu shi ji")
        for corrects in [false, true] {
            proposal.correctsConfirmedPinyin = corrects
            let item = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: "农夫市集 nang fu shi ji farmers market", proposal: proposal)
            #expect(item.replacementText == "农夫市集 · nóngfū shìjí · farmers market")
        }
    }

    // MARK: - A phrase that is not one dictionary word, in cells that cut across the fields (invented example)

    /// `学习市集 xue xi shi ji study fair` cut into `xue | xi shi ji study | fair`, with one engine misreading the Pinyin.
    private func runReadings(_ primary: [String], _ other: [String]) -> [NoteGrouping.Reading] {
        func cell(_ x: CGFloat, _ width: CGFloat, _ strokes: [Int]) -> NoteLayout.CellCandidate {
            NoteLayout.CellCandidate(strokeIndices: strokes, bounds: CGRect(x: x, y: 100, width: width, height: 50), column: 0, scale: 30, gapBefore: nil)
        }
        let cells = [cell(300, 80, [4]), cell(410, 300, [5, 6]), cell(760, 80, [7])]
        return [.init(cell: cell(100, 150, [0, 1, 2, 3]), text: "学习市集")]
            + cells.enumerated().map { .init(cell: $1, text: primary[$0], engines: ["PencilKit": primary[$0], "Paddle": other[$0]]) }
    }

    @Test func latinCellsBesideOneWordAreOneRunEvenWhenACellHoldsBothFields() throws {
        let entries = NoteGrouping.entries(from: runReadings(["Kue", "um sho ji Study", "fair"], ["xue", "xi shi ji study", "fair"]))
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.hanzi?.text == "学习市集")
        #expect(entry.pinyin?.text == "xue xi shi ji")
        #expect(entry.english?.text == "study fair")
        #expect(entry.strokeIndices == Array(0...7), "no ink is left out")
        // Cells that end where the Pinyin ends keep separate strokes for each field.
        let clean = try #require(NoteGrouping.entries(from: runReadings(["xue", "xi shi ji", "study"], ["xue", "xi shi ji", "study"])).first)
        #expect(clean.pinyin?.text == "xue xi shi ji")
        #expect(clean.english?.strokeIndices == [7])
        // Latin that does not begin with the word's reading is not claimed as its Pinyin.
        let other = NoteGrouping.entries(from: runReadings(["big", "red house", "here"], ["big", "red house", "here"]))
        #expect(!other.contains { $0.hanzi != nil && $0.pinyin != nil })
    }

    @Test func untonedPinyinInPiecesJoinsWhenItSpellsAWordBeginningWithTheHanzi() throws {
        func entries(_ hanzi: String, _ words: [String]) -> [NoteGrouping.Entry] {
            func cell(_ x: CGFloat, _ width: CGFloat, _ stroke: Int) -> NoteLayout.CellCandidate {
                .init(strokeIndices: [stroke], bounds: CGRect(x: x, y: 100, width: width, height: 60), column: 0, scale: 40, gapBefore: nil)
            }
            return NoteGrouping.entries(from: [.init(cell: cell(100, 70, 0), text: hanzi)]
                + words.enumerated().map { .init(cell: cell(260 + CGFloat($0) * 110, 80, $0 + 1), text: $1) })
        }
        let note = entries("好", ["hao", "xiang"])
        #expect(note.count == 1)
        #expect(note.first?.pinyin?.text == "hao xiang")
        #expect(note.first?.pinyin?.strokeIndices == [1, 2])
        #expect(note.first?.english == nil)
        // `he` beside 他 tā is English: no word is spelled `tahe`.
        #expect(entries("他", ["ta", "he"]).first?.english?.text == "he")
    }

    @Test func pinyinOfTheNotesOwnHanziIsNeverItsEnglish() throws {
        // `dian` passes a spell checker; beside 电脑 it is Pinyin, even when every engine agrees.
        func field(_ text: String, _ strokes: [Int]) -> NoteGrouping.Field { .init(text: text, cellText: text, strokeIndices: strokes, bounds: .zero) }
        let entry = NoteGrouping.Entry(hanzi: field("电脑", [0]), pinyin: nil, english: field("dian", [1]), arrangement: .sideBySide, uncertainty: [])
        let readings: [NoteEvidence.Reading] = [.paddle, .paddleServer].flatMap { (engine: NoteEvidence.Engine) -> [NoteEvidence.Reading] in
            [.init(text: "dian", engine: engine, scope: .cell, field: .english), .init(text: "电脑dian", engine: engine, scope: .entry)]
        }
        let resolved = FieldResolver.resolve(entry: entry, readings: readings)
        #expect(resolved.english.value == nil)
    }

    @Test func pinyinOneEngineGarbledBeyondRecognitionIsCutFromItsEnglish() {
        // Invented readings: the Paddle engines place the Pinyin but misspell the English; PencilKit does the reverse.
        func field(_ text: String) -> NoteGrouping.Field { .init(text: text, cellText: text, strokeIndices: [1, 2], bounds: .zero) }
        let entry = NoteGrouping.Entry(hanzi: .init(text: "学习市集", cellText: "学习市集", strokeIndices: [0], bounds: .zero),
                                       pinyin: field("xue xi shi ji"), english: field("stody fair"), arrangement: .sideBySide, uncertainty: [])
        let readings: [NoteEvidence.Reading] = [
            .init(text: "Kate um she by Study fair", engine: .pencilKit, scope: .field),
            .init(text: "xue xi shi ji stody fair", engine: .paddleServer, scope: .field),
            .init(text: "学习市集xue xi shi ji stndy fair", engine: .paddle, scope: .entry),
        ]
        let resolved = FieldResolver.resolve(entry: entry, readings: readings)
        #expect(resolved.pinyin.value == "xue xi shi ji")
        #expect(resolved.english.value == "Study fair")
        // English every engine reads in full is never shortened.
        let full = FieldResolver.resolve(entry: entry, readings: [
            .init(text: "xue xi shi ji big study fair", engine: .paddle, scope: .field),
            .init(text: "xue xi shi ji big study fair", engine: .pencilKit, scope: .field),
        ])
        #expect(full.english.value == "big study fair")
    }

    @Test func pinyinReadAsAnEnglishWordIsNotTheMeaning() throws {
        // Invented readings of `电脑 dian`: two engines read `dean`, one has `dian` as a lower guess, one reads something else.
        func field(_ text: String) -> NoteGrouping.Field { .init(text: text, cellText: text, strokeIndices: [0], bounds: .zero) }
        let entry = NoteGrouping.Entry(hanzi: field("电脑"), pinyin: nil, english: field("dean"), arrangement: .oneCell, uncertainty: [])
        func readings(_ tail: String) -> [NoteEvidence.Reading] {
            [.init(text: "电脑 open" + tail, engine: .pencilKit, scope: .entry), .init(text: "电脑dean" + tail, engine: .paddleServer, scope: .entry),
             .init(text: "电脑 dean" + tail, engine: .paddle, scope: .entry), .init(text: "电脑 dian" + tail, engine: .paddle, scope: .entry, alternate: true)]
        }
        let alone = FieldResolver.resolve(entry: entry, readings: readings(""))
        #expect(alone.english.value == nil)
        #expect(alone.pinyin.value == nil && alone.pinyin.status == .unresolved, "a lower guess never becomes the Pinyin")
        var line = RecognizedLine(text: alone.cleanText, bounds: .zero)
        line.resolved = alone
        let card = try #require(FlashcardExtractor.extract(from: line, lexicon: Lexicon.shared))
        #expect(card.back == "diànnǎo — computer")
        #expect(card.needsReview)
        #expect(full.proposal(forRecognizedText: alone.cleanText)?.candidates.first?.gloss == "computer")
        // English after it is kept.
        #expect(FieldResolver.resolve(entry: entry, readings: readings(" my laptop")).english.value == "my laptop")
        // A real English word with no reader spelling the Pinyin stays English.
        let english = FieldResolver.resolve(entry: entry, readings: [
            .init(text: "电脑 laptop", engine: .pencilKit, scope: .entry), .init(text: "电脑 laptop", engine: .paddle, scope: .entry)])
        #expect(english.english.value == "laptop")
    }

    @Test func aRowWhoseWordsDoNotLineUpWithItsCellsIsNotUsed() async throws {
        // Invented note whose Hanzi were cut in two cells: the row's word count matches the cells by coincidence, shifted by one.
        func stroke(_ x: CGFloat, _ size: CGFloat) -> PKStroke {
            var points: [PKStrokePoint] = []
            for i in 0...6 {
                let offset: CGFloat = size * CGFloat(i) / 6
                points.append(PKStrokePoint(location: CGPoint(x: x + offset, y: 100 + offset), timeOffset: TimeInterval(i) / 60,
                                            size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: CGFloat.pi / 2))
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
        }
        let cells: [(x: CGFloat, size: CGFloat, text: String)] = [(100, 60, "学习市"), (180, 30, "集"), (260, 30, "xuexi shi"), (340, 30, "study"), (420, 30, "fair")]
        let drawing = PKDrawing(strokes: cells.map { stroke($0.x, $0.size) })
        func text(_ strokes: [PKStroke]) -> String {
            let box = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
            // As read in one go, the Hanzi run straight into the Pinyin.
            var read = ""
            for cell in cells where box.minX <= cell.x + 5 && box.maxX >= cell.x + cell.size - 5 {
                read += cell.text
                if !FieldValidation.isHanzi(cell.text) { read += " " }
            }
            return read.trimmingCharacters(in: .whitespaces)
        }
        let lines = try await NoteReading.lines(in: drawing, readRegion: { strokes in
            [.init(text: text(strokes), engine: .paddleServer, scope: .cell), .init(text: text(strokes), engine: .paddle, scope: .cell)]
        }, readCell: { strokes, _ in
            let t = text(strokes)
            return NoteReading.CellRead(text: t, evidence: [.init(text: t, engine: .paddleServer, scope: .cell), .init(text: t, engine: .paddle, scope: .cell)])
        })
        #expect(NoteReading.mergedCells(NoteLayout.candidates(in: drawing)).count == 5, "the layout this test is about")
        #expect(lines.count == 1, "\(lines.map(\.text))")
        let line = try #require(lines.first)
        #expect(line.strokeIndices?.count == 5)
        #expect(line.resolved?.hanzi.value == "学习市集")
        #expect(FlashcardExtractor.extract(from: line, lexicon: Lexicon.shared)?.back == "xuéxí shìjí — study fair")
    }

    @Test func pinyinWithItsLastSyllableLeftOffStillGetsTheWholeReading() throws {
        // Invented notes: `电脑 dian computer`, and a phrase that is not one dictionary word.
        let lexicon = try #require(Lexicon.shared)
        let english = ResolvedField(value: "note", status: .confirmed)
        for (hanzi, written, reading) in [("电脑", "dian", "diànnǎo"), ("电脑学习", "dian nao xue", "diànnǎo xuéxí")] {
            let note = ResolvedNote(hanzi: .init(value: hanzi, status: .confirmed), pinyin: .init(value: written, status: .confirmed),
                                    english: english, diagnostics: [])
            #expect(lexicon.reading(of: hanzi, in: note)?.pinyin == reading)
            var line = RecognizedLine(text: note.cleanText, bounds: .zero)
            line.resolved = note
            let draft = try #require(FlashcardExtractor.extract(from: line, lexicon: lexicon))
            #expect(draft.back == "\(reading) — note")
            #expect(draft.needsReview)
        }
        #expect(!Lexicon.isBeginning("nao", of: "diànnǎo"))
        #expect(!Lexicon.isBeginning("diann", of: "diànnǎo"))
        #expect(!Lexicon.isBeginning("diǎn", of: "diànnǎo"))
    }

    private func phraseNote(_ pinyin: ResolvedField, _ english: ResolvedField, evidence: [String] = []) -> ResolvedNote {
        ResolvedNote(hanzi: .init(value: "学习市集", status: .confirmed), pinyin: pinyin, english: english, diagnostics: [], latinEvidence: evidence)
    }

    @Test func suggestOffersTonesForAPhraseWordByWordAndCardsAgree() throws {
        #expect(Lexicon.shared?.rows(forHanzi: "学习市集").isEmpty == true, "not one dictionary word")
        let english = ResolvedField(value: "study fair", status: .tentative)
        let notes = [
            phraseNote(.init(value: "xue xi shi ji", status: .confirmed), english),
            phraseNote(.init(value: "xue xi sho ji", status: .tentative), english),
            phraseNote(.init(value: nil, status: .unresolved), english, evidence: ["xne xi shi ji study fair"]),
            phraseNote(.absent, english),
        ]
        for note in notes {
            let proposal = try #require(full.phraseProposal(for: note), "\(note.pinyin)")
            let item = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: note.cleanText, proposal: proposal)
            #expect(item.replacementText == "学习市集 · xuéxí shìjí · study fair")
            #expect(item.annotationText == "(xuéxí shìjí)")
            var line = RecognizedLine(text: note.cleanText, bounds: .zero)
            line.resolved = note
            #expect(FlashcardExtractor.extract(from: line, lexicon: Lexicon.shared)?.back == "xuéxí shìjí — study fair")
        }
    }

    @Test func suggestAbstainsRatherThanGuessOrLoseEnglish() {
        let written = ResolvedField(value: "xue xi shi ji", status: .confirmed)
        let english = ResolvedField(value: "study fair", status: .confirmed)
        // Nothing missing; English that could not be read; Pinyin nowhere near; an undecided tone (好).
        #expect(full.phraseProposal(for: phraseNote(.init(value: "xuéxí shìjí", status: .confirmed), english)) == nil)
        #expect(full.phraseProposal(for: phraseNote(written, .init(value: nil, status: .unresolved))) == nil)
        #expect(full.phraseProposal(for: phraseNote(.init(value: "da meng", status: .tentative), english)) == nil)
        var undecided = phraseNote(.init(value: "hao", status: .confirmed), english)
        undecided.hanzi.value = "好"
        #expect(full.phraseProposal(for: undecided) == nil)
        // No English written: none is made up.
        #expect(full.phraseProposal(for: phraseNote(written, .absent))?.candidates.first?.gloss == "")
    }

    @Test func misreadPinyinAtTheStartOfALineIsFoundByTheHanzisReading() {
        let words = ["none", "fu", "shi", "ji", "farmers", "market"]
        #expect(StarterVocabulary.leadingRun(of: words, near: "nongfushiji")?.count == 4)
        #expect(StarterVocabulary.leadingRun(of: ["farmers", "market"], near: "nongfushiji") == nil)
        // Short readings never match this way: `to` is not 他 `ta`.
        #expect(StarterVocabulary.leadingRun(of: ["to", "be"], near: "ta") == nil)
    }

    @Test func hanziWrittenALittleApartIsOneWord() {
        func cell(_ x: CGFloat, _ width: CGFloat, _ height: CGFloat, _ strokes: [Int]) -> NoteLayout.CellCandidate {
            NoteLayout.CellCandidate(strokeIndices: strokes, bounds: CGRect(x: x, y: 100, width: width, height: height),
                                     column: 0, scale: height, gapBefore: nil)
        }
        let entries = NoteGrouping.entries(from: [
            .init(cell: cell(120, 245, 90, [0, 1, 2]), text: "农夫市"),
            .init(cell: cell(381, 61, 80, [3]), text: "集"),
            .init(cell: cell(509, 800, 60, [4, 5]), text: "nong fu shi ji farmers market"),
        ])
        #expect(entries.count == 1)
        #expect(entries.first?.hanzi?.text == "农夫市集")
        #expect(entries.first?.pinyin?.text == "nong fu shi ji")
        #expect(entries.first?.english?.text == "farmers market")
        // Two words a clear space apart stay two notes.
        let apart = NoteGrouping.entries(from: [
            .init(cell: cell(100, 160, 80, [0]), text: "你好"),
            .init(cell: cell(400, 160, 80, [1]), text: "谢谢"),
        ])
        #expect(apart.count == 2)
    }

    @Test func aCardUsesTheDictionaryReadingWhenThePinyinWasMisread() throws {
        var line = RecognizedLine(text: "农夫市集 nang fu shi ji farmers market", bounds: .zero)
        line.resolved = ResolvedNote(
            hanzi: .init(value: "农夫市集", status: .confirmed), pinyin: .init(value: "nang fu shi ji", status: .tentative),
            english: .init(value: "farmers market", status: .confirmed), diagnostics: [])
        let draft = try #require(FlashcardExtractor.extract(from: line))
        #expect(draft.back == "nóngfū shìjí — farmers market")
        #expect(draft.needsReview)
        // Unreadable Pinyin whose readings came that close is repaired the same way.
        line.resolved?.pinyin = .init(value: nil, status: .unresolved)
        line.resolved?.latinEvidence = ["none fu shi ji farmers market"]
        let repaired = FlashcardExtractor.extract(from: line)?.back
        #expect(repaired == "nóngfū shìjí — farmers market")
        // Unreadable Pinyin with nothing close is never replaced.
        line.resolved?.latinEvidence = ["qqq zzz farmers market"]
        let untouched = FlashcardExtractor.extract(from: line)?.back
        #expect(untouched == "farmers market")
    }

    @Test func aKnownWordWithEnglishButNoPinyinStillShowsItsPinyin() throws {
        // A card once lost the known Pinyin when none was read.
        var line = RecognizedLine(text: "农夫市集 farmers market", bounds: .zero)
        line.resolved = ResolvedNote(
            hanzi: .init(value: "农夫市集", status: .confirmed), pinyin: .absent,
            english: .init(value: "farmers market", status: .confirmed), diagnostics: [])
        let back = FlashcardExtractor.extract(from: line)?.back
        #expect(back == "nóngfū shìjí — farmers market")
    }

    @Test func pinyinReadAlikeByTwoEnginesOutvotesOneEnginesNonPinyin() {
        // One engine's `none fu shi ji` is not Pinyin and must not decide the cell.
        let cell: [NoteEvidence.Reading] = [
            .init(text: "none fu shi ji", engine: .pencilKit, scope: .cell),
            .init(text: "nong fu shi ji", engine: .paddleServer, scope: .cell),
            .init(text: "nong fu shi ji", engine: .paddle, scope: .cell),
        ]
        #expect(PencilInkLineReader.primary(of: cell) == "nong fu shi ji")
        // Real English read by one engine and garbled by the others stays the English.
        let english: [NoteEvidence.Reading] = [
            .init(text: "farmers market", engine: .pencilKit, scope: .cell),
            .init(text: "Farmers murket", engine: .paddleServer, scope: .cell),
            .init(text: "Farmers mqrket", engine: .paddle, scope: .cell),
        ]
        #expect(PencilInkLineReader.primary(of: english) == "farmers market")
        // One other engine is not enough to overrule.
        #expect(PencilInkLineReader.primary(of: Array(cell.prefix(2))) == "none fu shi ji")
    }

    @Test func theAppNeverWaitsForTheDictionary() {
        // `full` reads the shared dictionary only if it is already loaded; it never blocks the caller to load it.
        let vocabulary = StarterVocabulary.full
        #expect(vocabulary.usesSharedLexicon)
        #expect(vocabulary.lexicon == nil)
    }
}

