import Foundation

// 一段中日文字幕在哪儿能起新一行、断在那儿好不好（2026-10-18，纯文字的规矩）。字多宽、最后折成几行在 App 里
// （SubtitleLineWrap 量字、SubtitleCJKRows 挑行）；预览、AI 读的框、成片都经那一份，所以也都按这里断。
// 案例：docs/bugfixes/2026-10-18-subtitle-wrap-splits-chinese-words.md。
//
// 能起新一行的地方（其余都不能）：
// - 空格之后（行首行尾的空格不画）；
// - 中日文的词和词之间（词边界只有 `SubtitleCJKWords` 一份；两边有一边是中日文的字或标点才算），标点避头尾（行首不许是收尾的标点、
//   小假名、长音，行尾不许是开头的标点），阿拉伯数字和后面的中日文字不拆（「5分钟」）；
// - 一个词的字和字之间（`insideWord`）：只给比一整行还宽的词用，量过宽才放开（SubtitleCJKRows）。
// 代价（负的是好断；和生成字幕挑折行点同一套词表 `SubtitleBreakWords`、同一个量级）：
// - 句中的空格两边都是中日文（去掉的逗号）、逗号句号问号这类标点后面 −0.6；顿号后面 −0.3；
// - 夹在中文里的一串英文中间的空格 +0.3，两个大写开头的词连着（专有名词：Nano Banana、GPT Image）+0.6；
// - 助词起头 +1、「的」收尾 +0.4、连词介词代词副词能愿动词收尾 +1、连词起头 −0.3、句末语气词后面 −0.35；
// - 数量和名词不拆（「两个 / 平台」「这节 / 课」）+1、数词收尾 +1；方位词起头（「平台 / 上的」）+0.5；
// - 单字的词收尾（「短 / 视频」：分词切开的复合词）+0.25、两个单字的词之间（「站 / 在」「带 / 你」）+0.3 —— 收尾的虚词和方位词不算；
// - 日文的助词、助动词起头（「を」「て」）+1；
// - 词中间（只在词比一行宽时才有）+2。
// 不管什么：字多宽、折成几行（SubtitleLineWrap / SubtitleCJKRows）；没有中日文的段（只在空格处断，照 libass，SubtitleLineWrap）。

public enum SubtitleRowBreaks {
    public struct Break: Equatable, Sendable {
        /// 断在这儿的代价（负的是好断）。
        public var cost: Double
        /// 断在这个词的中间（只给比一行还宽的词用）；在词和词之间是 nil。
        public var insideWord: NSRange?
    }

    /// 这段字算不算中日文的段（有一个中日文的字或标点就算）：算的话按这里的规矩折，不算的只在空格处折。
    public static func isCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJK)
    }

    /// 汉字、假名、注音、全角字和中日文标点：这些字旁边能折（韩文不在内：词之间有空格、只在空格处折）。
    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x2FDF,    // 部首补充、康熙部首
             0x3000...0x30FF,    // 中日文标点、平假名、片假名
             0x3100...0x312F,    // 注音
             0x3190...0x31FF,    // 汉文、注音扩展、笔画、片假名扩展（中间 3130–318F 的谚文兼容字母不算）
             0x3200...0x33FF,    // 带圈的字、兼容字
             0x3400...0x4DBF,    // 扩展 A
             0x4E00...0x9FFF,    // 汉字
             0xF900...0xFAFF,    // 兼容汉字
             0xFE30...0xFE4F,    // 竖排标点
             0xFF00...0xFFEF,    // 全角字、半角假名
             0x1F200...0x1F2FF,  // 带圈的汉字补充
             0x20000...0x3134F:  // 扩展 B–G
            return true
        default:
            return false
        }
    }

    /// 这段字里能起新一行的位置（UTF-16，一个字的开头，第一个字前面不算）和断在那儿的代价。同一段字算过就直接拿
    /// （预览里同一句会反复折：逐词高亮每亮一个词折一次）。
    public static func breaks(in text: String) -> [Int: Break] {
        if let cached = cache.object(forKey: text as NSString) { return cached.breaks }
        let whole = text as NSString
        let words = Words(SubtitleCJKWords.words(in: text), in: whole)
        var result: [Int: Break] = [:]
        var offset = whole.length == 0 ? 0 : NSMaxRange(whole.rangeOfComposedCharacterSequence(at: 0))
        while offset < whole.length {
            let here = whole.rangeOfComposedCharacterSequence(at: offset)
            if let found = at(offset, in: whole, words: words) { result[offset] = found }
            offset = NSMaxRange(here)
        }
        cache.setObject(Cached(result), forKey: text as NSString)
        return result
    }

    private final class Cached {
        let breaks: [Int: Break]
        init(_ breaks: [Int: Break]) { self.breaks = breaks }
    }

    private nonisolated(unsafe) static let cache: NSCache<NSString, Cached> = {
        let cache = NSCache<NSString, Cached>()
        cache.countLimit = 512
        return cache
    }()

    // MARK: 一处

    private static func at(_ offset: Int, in text: NSString, words: Words) -> Break? {
        guard let next = scalar(at: offset, in: text), next != " ", let previous = scalar(before: offset, in: text) else { return nil }
        if previous == " " {
            // 空格之后：往回找到前面最后一个字。
            var end = offset - 1
            while end > 0, text.character(at: end - 1) == 0x20 { end -= 1 }
            guard end > 0, let left = scalar(before: end, in: text) else { return nil }
            if isCJK(left), isCJK(next) { return Break(cost: -0.6 + wordCost(at: offset, after: end, words: words, spaced: true)) }
            if isLatin(left), isLatin(next) {
                let proper = startsWithCapital(latinWord(endingAt: end, in: text)) && startsWithCapital(latinWord(startingAt: offset, in: text))
                return Break(cost: proper ? 0.6 : 0.3)
            }
            return Break(cost: wordCost(at: offset, after: end, words: words, spaced: true))
        }
        guard isCJK(previous) || isCJK(next), !noRowStart.contains(next), !noRowEnd.contains(previous) else { return nil }
        if previous.isASCII, previous.properties.numericType != nil, isCJK(next) { return nil }   // 「5分钟」
        var cost = wordCost(at: offset, after: offset, words: words)
        if clauseMarks.contains(previous) { cost -= 0.6 }
        if previous == "、" { cost -= 0.3 }
        let inside = words.containing(offset)
        if inside != nil { cost += 2 }
        return Break(cost: cost, insideWord: inside)
    }

    /// 从 `offset` 起的那个字、`offset` 前面那个字（UTF-16 的代理对拼成一个）。
    private static func scalar(at offset: Int, in text: NSString) -> Unicode.Scalar? {
        guard offset < text.length else { return nil }
        let unit = text.character(at: offset)
        if UTF16.isLeadSurrogate(unit), offset + 1 < text.length { return pair(unit, text.character(at: offset + 1)) }
        return Unicode.Scalar(unit)
    }

    private static func scalar(before offset: Int, in text: NSString) -> Unicode.Scalar? {
        guard offset > 0 else { return nil }
        let unit = text.character(at: offset - 1)
        if UTF16.isTrailSurrogate(unit), offset > 1 { return pair(text.character(at: offset - 2), unit) }
        return Unicode.Scalar(unit)
    }

    private static func pair(_ lead: unichar, _ trail: unichar) -> Unicode.Scalar? {
        guard UTF16.isLeadSurrogate(lead), UTF16.isTrailSurrogate(trail) else { return nil }
        return Unicode.Scalar(0x10000 + (UInt32(lead) - 0xD800) << 10 + (UInt32(trail) - 0xDC00))
    }

    /// 词的那几条（`start`：新一行从这儿起；`end`：上一行收在这儿；`spaced`：中间隔着空格 —— 那就是词组的边，单字的那两条不罚）。
    private static func wordCost(at start: Int, after end: Int, words: Words, spaced: Bool = false) -> Double {
        var cost = 0.0
        let next = words.starting(at: start)
        let previous = words.ending(at: end)
        if let next {
            if next.count == 1, let character = next.first, SubtitleBreakWords.particles.contains(character) { cost += 1 }
            if goodStarts.contains(next) { cost -= 0.3 }
            if SubtitleBreakWords.localizers.contains(next) { cost += 0.5 }
            if SubtitleBreakWords.japaneseRowStarts.contains(next) { cost += 1 }
        }
        guard let previous else { return cost }
        if previous.last == "的" { cost += 0.4 }
        if let character = previous.last, SubtitleBreakWords.sentenceFinalParticles.contains(character) { cost -= 0.35 }
        if danglingEnds.contains(previous) { cost += 1 }
        if let character = previous.last, SubtitleBreakWords.chineseNumerals.contains(character) { cost += 1 }
        // 数量和名词不拆：量词前面是数词、指示词（分词有时把「两个」切成一个词，有时切成两个，两种都认）。
        if counted(previous, before: end - (previous as NSString).length, words: words) { cost += 1 }
        // 单字的词收尾、两个单字的词之间（收尾的虚词、方位词不算）。
        let closes = previous.count == 1
            && (previous.first.map(SubtitleBreakWords.particles.contains) ?? false || SubtitleBreakWords.localizers.contains(previous))
        if previous.count == 1, !closes, !spaced {
            cost += 0.25
            if let next, next.count == 1 { cost += 0.3 }
        }
        return cost
    }

    /// `word` 收在一个量词上、量词前面是数词或指示词：「两个」「这节」「三」「个」。
    private static func counted(_ word: String, before start: Int, words: Words) -> Bool {
        let isCounter = { (text: String) in
            text.last.map { SubtitleBreakWords.chineseNumerals.contains($0) || $0.isNumber } == true
                || SubtitleBreakWords.quantifiers.contains(text)
        }
        if SubtitleBreakWords.measureWords.contains(word) {
            return words.ending(at: start).map(isCounter) ?? false
        }
        guard let last = word.last, SubtitleBreakWords.measureWords.contains(String(last)), word.count > 1 else { return false }
        return isCounter(String(word.dropLast()))
    }

    // MARK: 字

    /// 行首不许是这些：收尾的标点、小假名、长音（ASCII 的标点只在挨着中日文时才管得到）。
    static let noRowStart = Set(
        "、。，．：；！？）］｝〕〉》」』】〙〗〟’”｠»ヽヾーァィゥェォッャュョヮヵヶぁぃぅぇぉっゃゅょゎゕゖ々〻‐゠〜～…‥,.!?:;)]}".unicodeScalars
    )
    /// 行尾不许是这些：开头的标点。
    static let noRowEnd = Set("（［｛〔〈《「『【〘〖〝‘“｟«([{".unicodeScalars)
    /// 一个小句收在这儿：后面好断。
    static let clauseMarks = Set("，。！？；：…!?".unicodeScalars)
    /// 生成字幕那两张词表（数组，按整词认）的集合版：这里每个位置都要查。
    private static let goodStarts = Set(SubtitleBreakWords.chineseGoodStarts)
    private static let danglingEnds = Set(SubtitleBreakWords.chineseDanglingEnds)

    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
    }

    private static func startsWithCapital(_ word: String) -> Bool {
        word.first { $0.isLetter }?.isUppercase ?? false
    }

    /// 收在 `end` 的那个英文词、从 `start` 起的那个英文词（到空格为止）。
    private static func latinWord(endingAt end: Int, in text: NSString) -> String {
        var start = end
        while start > 0, text.character(at: start - 1) != 0x20 { start -= 1 }
        return text.substring(with: NSRange(location: start, length: end - start))
    }

    private static func latinWord(startingAt start: Int, in text: NSString) -> String {
        var end = start
        while end < text.length, text.character(at: end) != 0x20 { end += 1 }
        return text.substring(with: NSRange(location: start, length: end - start))
    }
}

/// 一段字里的中日文词，按起点、终点、盖着的位置查。
private struct Words {
    private var byStart: [Int: String] = [:]
    private var byEnd: [Int: String] = [:]
    private var inside: [Int: NSRange] = [:]

    init(_ ranges: [NSRange], in text: NSString) {
        for range in ranges {
            let word = text.substring(with: range)
            byStart[range.location] = word
            byEnd[NSMaxRange(range)] = word
            for offset in (range.location + 1)..<max(range.location + 1, NSMaxRange(range)) { inside[offset] = range }
        }
    }

    func starting(at offset: Int) -> String? { byStart[offset] }
    func ending(at offset: Int) -> String? { byEnd[offset] }
    func containing(_ offset: Int) -> NSRange? { inside[offset] }
}
