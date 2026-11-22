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

    // MARK: - Repair of misread Pinyin (readings captured on the iPad for `学 xué xí`)

    private let deviceGuesses = ["eve xí", "xú xí", "xúc xi", "xúe xi", "xúc xí", "xúe xí", "xúu xi", "xú ×í", "xúu xí"]

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
        // The iPad chip for `农夫市集 nong fu shi ji farmers market` showed `nong fu shi ji`; Keep added only the tones.
        let proposal = try #require(full.proposal(forRecognizedText: "农夫市集 nong fu shi ji farmers market"))
        #expect(proposal.pinyinState == .missingTones)
        let item = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: "农夫市集 nong fu shi ji farmers market", proposal: proposal)
        #expect(item.cleanText == "农夫市集 · nóngfū shìjí · farmers market")
        // Pinyin written with tone marks that differ is the student's: the preview keeps it as written.
        let differing = try #require(full.proposal(forRecognizedText: "农夫市集 nòngfū shìjí farmers market"))
        let kept = PendingSuggestion(revision: 0, anchor: .zero, recognizedText: "农夫市集 nòngfū shìjí farmers market", proposal: differing)
        #expect(kept.cleanText.contains("nòngfū"))
    }

    @Test func aKnownWordWithEnglishButNoPinyinStillShowsItsPinyin() throws {
        // The approved iPad card was `农夫市集 → farmers market`: the Pinyin had been split off the note.
        var line = RecognizedLine(text: "农夫市集 farmers market", bounds: .zero)
        line.resolved = ResolvedNote(
            hanzi: .init(value: "农夫市集", status: .confirmed), pinyin: .absent,
            english: .init(value: "farmers market", status: .confirmed), diagnostics: [])
        let back = FlashcardExtractor.extract(from: line)?.back
        #expect(back == "nóngfū shìjí — farmers market")
    }

    @Test func pinyinReadAlikeByTwoEnginesOutvotesOneEnginesNonPinyin() {
        // The iPad's readings of `nong fu shi ji`: PencilKit's `none fu she ji` is not Pinyin and must not decide the cell.
        let cell: [NoteEvidence.Reading] = [
            .init(text: "none fu she ji", engine: .pencilKit, scope: .cell),
            .init(text: "nong fu shi ji", engine: .paddleServer, scope: .cell),
            .init(text: "nong fu shi ji", engine: .paddle, scope: .cell),
        ]
        #expect(PencilInkLineReader.primary(of: cell) == "nong fu shi ji")
        // Real English read by one engine and garbled by the others stays the English.
        let english: [NoteEvidence.Reading] = [
            .init(text: "farmers market", engine: .pencilKit, scope: .cell),
            .init(text: "Farmers merket", engine: .paddleServer, scope: .cell),
            .init(text: "Farmers mekeA", engine: .paddle, scope: .cell),
        ]
        #expect(PencilInkLineReader.primary(of: english) == "farmers market")
        // One other engine is not enough to overrule.
        #expect(PencilInkLineReader.primary(of: Array(cell.prefix(2))) == "none fu she ji")
    }

    @Test func theAppNeverWaitsForTheDictionary() {
        // `full` reads the shared dictionary only if it is already loaded; it never blocks the caller to load it.
        let vocabulary = StarterVocabulary.full
        #expect(vocabulary.usesSharedLexicon)
        #expect(vocabulary.lexicon == nil)
    }
}

