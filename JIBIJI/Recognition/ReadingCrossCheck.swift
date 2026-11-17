import Foundation

/// Issue #12: compares several readings of the same ink line before a card is drafted or an ink edit is offered.
/// The primary reading is only corrected when another reading supplies a valid Pinyin word that also fits the
/// Hanzi written beside it. English is never changed. Anything unclear stays as read, flagged for review.
enum ReadingCrossCheck {
    enum Status: Equatable, Sendable {
        /// Nothing to correct or compare.
        case agreed
        /// A Pinyin word was corrected from another reading. The ink was probably right; no ink edit is offered.
        case corrected
        /// Readings disagree and nothing settles it. Kept as read; editable and marked for review.
        case unresolved
    }

    struct Outcome: Equatable, Sendable {
        var text: String
        var status: Status
        var note: String?
    }

    /// Valid toneless Mandarin syllables (from the system Han-to-Latin table).
    static let syllables: Set<String> = Set("""
    a ai an ang ao ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo da dai dan dang dao de den deng di dia dian diao die ding diu dong dou du duan dui dun duo e ei en eng er fa fan fang fei fen feng fiao fo fou fu ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lue lun luo ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nue nun nuo o ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// True when `word` (letters only, tones ignored) splits entirely into valid syllables.
    static func isPinyin(_ word: String) -> Bool {
        let letters = Array(StarterVocabulary.latinTokens(word).joined())
        guard !letters.isEmpty, letters.count <= 24 else { return false }
        var reachable = [Bool](repeating: false, count: letters.count + 1)
        reachable[0] = true
        for end in 1...letters.count {
            for length in 1...min(6, end) where reachable[end - length] {
                if syllables.contains(String(letters[(end - length)..<end])) { reachable[end] = true; break }
            }
        }
        return reachable[letters.count]
    }

    /// Toneless romanization of the Hanzi, joined (农夫 -> nongfu). Empty when there is no Hanzi.
    static func romanization(of hanzi: String) -> String {
        guard !hanzi.isEmpty else { return "" }
        let mutable = NSMutableString(string: hanzi)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        return StarterVocabulary.latinTokens(mutable as String).joined()
    }

    private struct Piece { var text: String; var isWord: Bool }

    /// Splits into whitespace-separated words and the whitespace between them, so text can be rebuilt exactly.
    private static func pieces(_ text: String) -> [Piece] {
        var result: [Piece] = []
        var current = ""
        var inSpace = false
        for character in text {
            if character.isWhitespace != inSpace, !current.isEmpty {
                result.append(Piece(text: current, isWord: !inSpace))
                current = ""
            }
            inSpace = character.isWhitespace
            current.append(character)
        }
        if !current.isEmpty { result.append(Piece(text: current, isWord: !inSpace)) }
        return result
    }

    private static func isLatinWord(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isLetter && StarterVocabulary.hanzi(in: String($0)).isEmpty }
    }

    static func resolve(primary: String, alternatives: [String]) -> Outcome {
        let unchanged = Outcome(text: primary, status: .agreed, note: nil)
        let runs = StarterVocabulary.hanziRuns(in: primary)
        let others = alternatives.filter { $0 != primary && !$0.isEmpty }
        guard !others.isEmpty else { return unchanged }

        var parts = pieces(primary)
        let wordIndices = parts.indices.filter { parts[$0].isWord }
        let primaryWords = wordIndices.map { parts[$0].text }
        // Only readings that agree on the Hanzi and on the number of words can be compared word by word.
        let comparable = others.filter { alternative in
            StarterVocabulary.hanziRuns(in: alternative) == runs && pieces(alternative).filter(\.isWord).count == primaryWords.count
        }.map { alternative in pieces(alternative).filter(\.isWord).map(\.text) }
        guard !comparable.isEmpty else {
            return Outcome(text: primary, status: .unresolved,
                           note: "Other readings of this line don't line up with it, so it was kept as read. Check it.")
        }

        let hint = romanization(of: runs.joined())
        var corrected = false
        var unresolvedNotes: [String] = []
        var confirmed = ""   // folded Pinyin accepted so far, to check each word still fits the Hanzi

        for (position, index) in wordIndices.enumerated() {
            let word = primaryWords[position]
            let folded = StarterVocabulary.latinTokens(word).joined()
            if isLatinWord(word), isPinyin(word), hint.hasPrefix(confirmed + folded) { confirmed += folded; continue }
            guard isLatinWord(word) else { continue }
            let proposals = Set(comparable.map { $0[position] }).filter { $0 != word }
            guard !proposals.isEmpty else { continue }
            // A valid Pinyin word that continues the Hanzi's own romanization, supported by another reading.
            let fitting = proposals.filter { isLatinWord($0) && isPinyin($0) && hint.hasPrefix(confirmed + StarterVocabulary.latinTokens($0).joined()) }
            let fittingFolded = Set(fitting.map { StarterVocabulary.latinTokens($0).joined() })
            if fittingFolded.count == 1, let replacement = fitting.sorted().first, !hint.isEmpty {
                parts[index].text = replacement
                confirmed += StarterVocabulary.latinTokens(replacement).joined()
                corrected = true
            } else if proposals.contains(where: { isLatinWord($0) && isPinyin($0) }) {
                // (Differences between plain English words are not a Pinyin disagreement and are ignored.)
                unresolvedNotes.append("“\(word)” vs “\(proposals.sorted().joined(separator: "”, “"))”")
            }
        }

        if !unresolvedNotes.isEmpty {
            return Outcome(text: primary, status: .unresolved,
                           note: "Readings disagree (\(unresolvedNotes.joined(separator: "; "))) and nothing settles it. Kept as read; check it.")
        }
        guard corrected else { return unchanged }
        let text = parts.map(\.text).joined()
        return Outcome(text: text, status: .corrected,
                       note: "Pinyin corrected from another reading of the same ink to fit the Hanzi (was “\(primary)”). Your ink is unchanged.")
    }

    /// Whether the primary reading has Hanzi plus a Latin word that is not Pinyin, so a second opinion is worth asking for.
    static func wantsSecondOpinion(_ primary: String) -> Bool {
        guard !StarterVocabulary.hanziRuns(in: primary).isEmpty else { return false }
        return pieces(primary).contains { $0.isWord && isLatinWord($0.text) && !isPinyin($0.text) }
    }
}
