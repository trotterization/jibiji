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
}
