import Foundation
import SrtFlowCore

// 字幕折行的文字规矩（SubtitleRowBreaks、SubtitleCJKWords，2026-10-18）：中日文只在词和词之间断、句中的空格和标点后面好断、
// 助词不起头、数量和名词不拆、夹在中文里的英文短语和专有名词尽量不拆。测试员在 L16 课程的工程里撞到「快手」「GPT / Image」被拆在两行
// （docs/bugfixes/2026-10-18-subtitle-wrap-splits-chinese-words.md）。字多宽、最后折成几行要 Core Text，在
// scripts/check-subtitle-burn-size.sh 的 WrapChecks 里。用例只用系统分词各版本都认得的词（「以及」「视频」「平台」），CI 和本机的
// macOS 版本不同、分词可能差一点。

func runSubtitleRowBreakChecks() {
    checkCJKWordCoverage()
    checkRowBreakPlaces()
    checkRowBreakCosts()
}

/// UTF-16 位置：`text` 里第一次出现 `piece` 的地方（再加 `plus`）。
private func offset(of piece: String, in text: String, plus: Int = 0) -> Int {
    (text as NSString).range(of: piece).location + plus
}

private func checkCJKWordCoverage() {
    // 整句一起交给系统分词时，中英文连着写的句子会漏掉一大截（「的冰山一望无际Penguins站在风里等待the」整段没有词）：
    // 每段汉字单独分，每个汉字都落在某个词里。
    let mixed = "南极的冰山一望无际Penguins站在风里等待the long polar night过去"
    let words = SubtitleCJKWords.words(in: mixed)
    let covered = Set(words.flatMap { $0.location..<NSMaxRange($0) })
    let han = (0..<(mixed as NSString).length).filter { offset in
        Unicode.Scalar((mixed as NSString).character(at: offset)).map(SubtitleCJKWords.isHanOrKana) ?? false
    }
    check(han.allSatisfy(covered.contains), "CJK words: every Han character of a mixed sentence is in some word (uncovered: \(han.filter { !covered.contains($0) }))")
    check(words.allSatisfy { !(mixed as NSString).substring(with: $0).contains("P") }, "CJK words: English letters are never part of a CJK word")
    let sentence = "我们会讲两个平台上的短视频以及怎么做"
    let interior = SubtitleCJKWords.interior(of: sentence)
    check(interior.contains(offset(of: "以及", in: sentence, plus: 1)), "CJK words: between 以 and 及 is inside a word")
    check(interior.contains(offset(of: "视频", in: sentence, plus: 1)), "CJK words: between 视 and 频 is inside a word")
    check(!interior.contains(offset(of: "以及", in: sentence)), "CJK words: right before 以及 is a word boundary")
    check(SubtitleCJKWords.words(in: "Hello world").isEmpty && SubtitleCJKWords.words(in: "남극의 빙산").isEmpty,
          "CJK words: English and Korean have none")
}

private func checkRowBreakPlaces() {
    let cue = "包括 Google 的 Nano Banana、OpenAI 的 GPT Image 以及字节跳动的 Seedream"
    let breaks = SubtitleRowBreaks.breaks(in: cue)
    check(breaks[offset(of: "及字", in: cue)]?.insideWord != nil, "row breaks: inside 以及 only for a word wider than a row")
    check(breaks[offset(of: "OpenAI", in: cue)].map { $0.cost <= -0.3 } == true, "row breaks: after 、 is a good place (\(String(describing: breaks[offset(of: "OpenAI", in: cue)])))")
    check(breaks[offset(of: "Image", in: cue)].map { $0.cost >= 0.6 } == true, "row breaks: GPT / Image splits a name (\(String(describing: breaks[offset(of: "Image", in: cue)])))")
    check(breaks[offset(of: "Banana", in: cue)].map { $0.cost >= 0.6 } == true, "row breaks: Nano / Banana splits a name")
    check(breaks[offset(of: "以及", in: cue)].map { $0.cost <= 0 } == true, "row breaks: a row may start with 以及 (\(String(describing: breaks[offset(of: "以及", in: cue)])))")
    check(breaks[offset(of: "的 GPT", in: cue)].map { $0.cost >= 1 } == true, "row breaks: a row starting with 的 is bad")
    for (text, at, why) in [("最长 5分钟的音乐", "分钟", "5 / 分钟"), ("南极的冰山，企鹅", "，", "a full-width comma at a row start"),
                            ("南极的（冰山）", "冰山", "an opening bracket at a row end"), ("ペンギーン", "ーン", "a long-vowel mark at a row start")] {
        check(SubtitleRowBreaks.breaks(in: text)[offset(of: at, in: text)] == nil, "row breaks: never \(why)")
    }
    check(SubtitleRowBreaks.isCJK("工作区") && SubtitleRowBreaks.isCJK("Hello！") && !SubtitleRowBreaks.isCJK("Hello world")
          && !SubtitleRowBreaks.isCJK("남극의 빙산"), "row breaks: CJK paragraphs are the ones with a CJK character or mark (Korean is not)")
}

private func checkRowBreakCosts() {
    // 句中的空格两边都是中文（去掉的逗号）：这一句里最好的断点。
    let tabs = "工作区里有三个标签页 图像、视频和音乐"
    let tabBreaks = SubtitleRowBreaks.breaks(in: tabs)
    let atSpace = offset(of: "图像", in: tabs)
    check(tabBreaks[atSpace].map { $0.cost <= -0.6 } == true, "row costs: the space between Chinese phrases is a removed comma")
    check(tabBreaks.filter { $0.value.insideWord == nil }.allSatisfy { $0.key == atSpace || $0.value.cost > tabBreaks[atSpace]!.cost },
          "row costs: …and the cheapest place in the sentence")
    // 数量和名词不拆；方位词不起头；单字的词不收尾。
    let platforms = "我们会讲两个平台上的短视频怎么做"
    let costs = SubtitleRowBreaks.breaks(in: platforms)
    check(costs[offset(of: "平台", in: platforms)].map { $0.cost >= 1 } == true, "row costs: 两个 / 平台 splits a count from its noun")
    check(costs[offset(of: "上的", in: platforms)].map { $0.cost >= 0.5 } == true, "row costs: a row starting with the localizer 上 is bad")
    check(costs[offset(of: "怎么", in: platforms)].map { $0.cost <= 0.3 } == true, "row costs: before 怎么 is a fair place")
    check(costs[offset(of: "做", in: platforms)].map { $0.cost >= 1 } == true, "row costs: 怎么 left at a row end is dangling")
    // 夹在中文里的英文短语：能不拆就不拆。
    let english = "等待the long polar night过去"
    check(SubtitleRowBreaks.breaks(in: english)[offset(of: "polar", in: english)].map { $0.cost >= 0.3 } == true,
          "row costs: breaking inside an English phrase in Chinese costs something")
}
