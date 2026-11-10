import Foundation
import SrtFlowCore

// MARK: - 一句配音的词对到原文上（纯值）
//
// 管什么（SkyCut 声音方案第七节「本机转写，再按原文对齐」）：一句配音的词（这一句里的秒，来自这台 Mac 的转写或语音服务报的字的时间）
// 换成**原文的词**（SpeechWordTokens），时间照对上的字取 —— 字幕显示稿子写的字，不显示识别器听成的字（识别器把「SkyCut」听成
// 「Sky cut」、「2026」听成「twenty twenty-six」，字幕照样是原文；2026-11-10 之前转写过的配音字幕显示的是识别出来的字，
// docs/bugfixes/2026-11-10-voiceover-subtitles-show-transcribed-text.md）。
// - 对字：SubtitleCueWords（字幕改字时把词的时间换到新字上的那一套，繁简不计较）；一个识别词盖住几个原文词时按份数分它的时间；
// - 没对上的原文词（识别器漏了、读法不一样）：夹在两个对上的词中间的按份数分那段空当；开头 / 结尾的按每份 0.22 秒往外推，
//   不越过这一句的头尾；
// - 对上的字不到原文字母数字的 65%（和 SkyStudioVoiceSplit 切句同一个口径）：这一句对不上，nil，调用方按字数估（SpeechWordEstimate）。
// 不管什么：转写、切句（SkyStudioVoiceSplit）、估。

enum SpeechWordAlignment {
    static let minimumCoverage = 0.65
    /// 没对上又不在两个对上的词之间（开头、结尾）时，一份按多少秒往外推。
    static let secondsPerUnit = 0.22

    private typealias Span = (start: Double, end: Double)

    /// `words`：这一句的词（秒，从这一句的开头算）；`duration`：这一句的声音多长。对不上是 nil。
    static func aligned(_ words: [TimedWord], to text: String, duration: Double) -> [TimedWord]? {
        let tokens = SpeechWordTokens.tokens(text)
        let spoken = text.filter { $0.isLetter || $0.isNumber }.count
        guard !tokens.isEmpty, spoken > 0, duration > 0 else { return nil }
        var recognized = ""
        var spans: [SubtitleCueWord] = []
        for word in words where word.start.isFinite && word.end.isFinite && word.start >= 0 && word.end >= word.start && word.start < duration {
            spans.append(SubtitleCueWord(location: recognized.utf16.count, length: word.text.utf16.count,
                                         start: word.start, end: min(word.end, duration)))
            recognized += word.text
        }
        guard !spans.isEmpty else { return nil }
        let covered = SubtitleCueWords.matchingCharacterCount(recognized, to: text, foldsChineseScript: true)
        guard Double(covered) >= Double(spoken) * minimumCoverage,
              let mapped = SubtitleCueWords.realigned(spans, from: recognized, to: text, foldsChineseScript: true) else { return nil }
        var times = [Span?](repeating: nil, count: tokens.count)
        for span in mapped { assign(span, to: tokens, times: &times) }
        guard times.contains(where: { $0 != nil }) else { return nil }
        fill(&times, tokens: tokens, duration: duration)
        return finished(times.map { $0! }, tokens: tokens, duration: duration)
    }

    /// 一个对上的识别词落在原文的哪几个词上：按份数分它的时间（一个识别词「你好」盖住原文的「你」「好」两个词）。
    private static func assign(_ span: SubtitleCueWord, to tokens: [SpeechWordToken], times: inout [Span?]) {
        let range = span.location ..< span.location + max(span.length, 1)
        let hits = tokens.indices.filter { tokens[$0].range.overlaps(range) }
        guard !hits.isEmpty else { return }
        let total = hits.reduce(0) { $0 + weight(tokens[$1]) }
        var cursor = span.start
        for index in hits {
            let share = (span.end - span.start) * weight(tokens[index]) / total
            let piece: Span = (cursor, cursor + share)
            times[index] = times[index].map { (min($0.start, piece.start), max($0.end, piece.end)) } ?? piece
            cursor += share
        }
    }

    /// 没对上的那几串：夹在中间的分那段空当，开头 / 结尾的按每份 0.22 秒往外推。
    private static func fill(_ times: inout [Span?], tokens: [SpeechWordToken], duration: Double) {
        var index = 0
        while index < times.count {
            guard times[index] == nil else { index += 1; continue }
            var end = index
            while end < times.count, times[end] == nil { end += 1 }
            let run = Array(index ..< end)
            let weights = run.enumerated().map { offset, token in weight(tokens[token]) + (offset + 1 < run.count ? tokens[token].pause : 0) }
            let needed = weights.reduce(0, +) * secondsPerUnit
            let before = index > 0 ? times[index - 1]?.end : nil
            let after = end < times.count ? times[end]?.start : nil
            let lower: Double, upper: Double
            switch (before, after) {
            case let (before?, after?): lower = before; upper = max(after, before)
            case let (nil, after?): upper = after; lower = max(0, after - needed)
            case let (before?, nil): lower = before; upper = min(duration, before + needed)
            case (nil, nil): lower = 0; upper = duration
            }
            let total = weights.reduce(0, +)
            var cursor = lower
            for (offset, token) in run.enumerated() {
                let share = (upper - lower) * weight(tokens[token]) / total
                times[token] = (cursor, cursor + share)
                cursor += share + (upper - lower) * (weights[offset] - weight(tokens[token])) / total
            }
            index = end
        }
    }

    /// 收尾：开头不往回退、每个词至少 20 毫秒、都在这一句的声音里。
    private static func finished(_ times: [Span], tokens: [SpeechWordToken], duration: Double) -> [TimedWord] {
        var previous = 0.0
        return tokens.indices.map { index in
            let start = min(max(times[index].start, previous, 0), max(0, duration - 0.02))
            let end = min(duration, max(times[index].end, start + 0.02))
            previous = start
            return TimedWord(text: tokens[index].text, start: start, end: end)
        }
    }

    private static func weight(_ token: SpeechWordToken) -> Double { max(token.units, 0.01) }
}
