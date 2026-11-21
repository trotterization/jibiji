import Testing
@testable import JIBIJI

/// The bundled CC-CEDICT dictionary: real entries, no AI. These run against the actual table in the app bundle.
@Suite(.serialized) struct LexiconTests {
    private var full: StarterVocabulary { .full }

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
        for word in ["he", "me", "ma", "table", "hello world", "the"] {
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
        #expect(full.repairedProposal(forRecognizedText: "xú xí", latinEvidence: deviceGuesses) == nil)
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
        #expect(item.allowsInkReplacement)
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
}

