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

    /// A whitespace-separated word split into leading punctuation, its letters, and trailing punctuation.
    private struct Word {
        var lead = "", core = "", trail = ""
        init(_ text: String) {
            guard let first = text.firstIndex(where: \.isLetter), let last = text.lastIndex(where: \.isLetter) else {
                lead = text; return
            }
            lead = String(text[..<first]); core = String(text[first...last]); trail = String(text[text.index(after: last)...])
        }
        var rebuilt: String { lead + core + trail }
    }

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

    /// Only letters, none of them Hanzi. Words with inner punctuation (xi'an) or attached Hanzi are left alone.
    private static func isLatinCore(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isLetter && StarterVocabulary.hanzi(in: String($0)).isEmpty }
    }

    private static func folded(_ word: String) -> String { StarterVocabulary.latinTokens(word).joined() }
    private static func hasToneMarks(_ word: String) -> Bool { word.precomposedStringWithCanonicalMapping.lowercased() != folded(word) && word.contains { $0.isLetter && String($0).folding(options: .diacriticInsensitive, locale: nil) != String($0) } }

    static func resolve(primary: String, alternatives: [String]) -> Outcome {
        let unchanged = Outcome(text: primary, status: .agreed, note: nil)
        let runs = StarterVocabulary.hanziRuns(in: primary)
        let others = alternatives.filter { $0 != primary && !$0.isEmpty }
        guard !others.isEmpty else { return unchanged }

        var parts = pieces(primary)
        let wordIndices = parts.indices.filter { parts[$0].isWord }
        let primaryWords = wordIndices.map { Word(parts[$0].text) }
        // Only readings that agree on the Hanzi and the number of words can be compared word by word.
        // Others (for example a recognizer's other candidate lines) are ignored, not treated as disagreement.
        let comparable = others.filter { alternative in
            StarterVocabulary.hanziRuns(in: alternative) == runs && pieces(alternative).filter(\.isWord).count == primaryWords.count
        }.map { alternative in pieces(alternative).filter(\.isWord).map { Word($0.text).core } }
        guard !comparable.isEmpty else { return unchanged }

        let hint = romanization(of: runs.joined())
        var corrected = false
        var unresolvedNotes: [String] = []
        var confirmed = ""   // folded Pinyin accepted so far, to check each word still fits the Hanzi

        for (position, index) in wordIndices.enumerated() {
            let word = primaryWords[position]
            guard isLatinCore(word.core) else { continue }
            let primaryFolded = folded(word.core)
            let primaryValid = isPinyin(word.core)
            // Words after the Hanzi's whole romanization is accounted for are English, not Pinyin.
            let slotOpen = confirmed.count < hint.count
            let alternativesHere = comparable.map { $0[position] }

            if primaryValid, slotOpen, hint.hasPrefix(confirmed + primaryFolded) {
                // Fits the Hanzi. Only two toned readings that conflict are worth flagging.
                let conflicting = alternativesHere.filter {
                    $0 != word.core && isPinyin($0) && folded($0) == primaryFolded && hasToneMarks($0) && hasToneMarks(word.core)
                }
                if !conflicting.isEmpty {
                    unresolvedNotes.append("“\(word.core)” vs “\(Set(conflicting).sorted().joined(separator: "”, “"))” (tones)")
                }
                confirmed += primaryFolded
                continue
            }
            let proposals = Set(alternativesHere).filter { $0 != word.core && isLatinCore($0) }
            guard !proposals.isEmpty else { continue }
            let fitting = slotOpen && !hint.isEmpty
                ? proposals.filter { isPinyin($0) && hint.hasPrefix(confirmed + folded($0)) } : []
            let fittingLetters = Set(fitting.map(folded))
            let tonedFits = Set(fitting.filter(hasToneMarks))
            // Two toned readings of the same letters that disagree on tones can't be settled here.
            let tonesConflict = tonedFits.count > 1
            // With no Hanzi to anchor to, only a line that otherwise reads as Pinyin is worth flagging.
            let othersArePinyin = primaryWords.enumerated().allSatisfy { offset, other in
                offset == position || !isLatinCore(other.core) || isPinyin(other.core)
            }
            let pinyinSlotDisagreement = !primaryValid && proposals.contains { isPinyin($0) } && (hint.isEmpty ? othersArePinyin : slotOpen)
            if !primaryValid, !tonesConflict, fittingLetters.count == 1, let best = fitting.sorted(by: { (hasToneMarks($0) ? 0 : 1, $0) < (hasToneMarks($1) ? 0 : 1, $1) }).first {
                // A toned reading with the same letters is preferred (nóng over nong).
                parts[index].text = Word(parts[index].text).lead + best + Word(parts[index].text).trail
                confirmed += folded(best)
                corrected = true
            } else if !fittingLetters.isEmpty || pinyinSlotDisagreement {
                // Another reading fits the Hanzi but the primary (a valid word) is kept, or the readings
                // are in conflict. A valid primary may be a less common reading of the Hanzi, so don't override it.
                unresolvedNotes.append("“\(word.core)” vs “\(proposals.sorted().joined(separator: "”, “"))”")
            }
            // Otherwise the words differ only as plain English, or neither can be Pinyin here: ignored.
        }

        if !unresolvedNotes.isEmpty {
            return Outcome(text: primary, status: .unresolved,
                           note: "Readings disagree (\(unresolvedNotes.joined(separator: "; "))) and nothing settles it. Kept as read; check it.")
        }
        guard corrected else { return unchanged }
        return Outcome(text: parts.map(\.text).joined(), status: .corrected,
                       note: "Pinyin corrected from another reading of the same ink to fit the Hanzi (was “\(primary)”). Your ink is unchanged.")
    }

    /// Whether the primary reading has a Latin word in the Pinyin slot after its Hanzi that is not Pinyin,
    /// so a second opinion is worth asking for.
    static func wantsSecondOpinion(_ primary: String) -> Bool {
        let runs = StarterVocabulary.hanziRuns(in: primary)
        guard !runs.isEmpty else { return false }
        let hint = romanization(of: runs.joined())
        var confirmed = ""
        for piece in pieces(primary) where piece.isWord {
            let word = Word(piece.text)
            guard isLatinCore(word.core), confirmed.count < hint.count else { continue }
            if isPinyin(word.core), hint.hasPrefix(confirmed + folded(word.core)) { confirmed += folded(word.core); continue }
            if !isPinyin(word.core) { return true }
        }
        return false
    }
}
