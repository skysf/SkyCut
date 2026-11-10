import Foundation
import SrtFlowCore

// MARK: - 按字数估一句配音的词在什么时候（纯值）
//
// 管什么（SkyCut 声音方案第七节「估算怎么算」）：这台 Mac 转写不了这种语言（声音库的声音、Eleven 也不读的语言），或者这一句的转写
// 和原文对不上时，字幕的时间按字数估：
// - 开口和收尾按响度找：头一个、最后一个比 AIVoiceWords.silenceRMS 响的 10 毫秒（和配音的词标记同一个门限）；一点声音都没有就用整段；
// - 中间按份数摊：原文的词（SpeechWordTokens）中日韩一个字一份、数字一份、别的字母 0.3 份，句末标点后面停 2 份、逗号类 1 份。
// 估出来的那几句结果里标成 estimated，voice.note 说「按字数估的、可能差半秒左右」（AIVoiceoverTiming）。
// 不管什么：对齐（SpeechWordAlignment）、什么时候估（SkyStudioVoiceRender）。

enum SpeechWordEstimate {
    static func estimated(_ text: String, samples: [Float], sampleRate: Double) -> [TimedWord] {
        let tokens = SpeechWordTokens.tokens(text)
        guard !tokens.isEmpty, sampleRate > 0, !samples.isEmpty else { return [] }
        let duration = Double(samples.count) / sampleRate
        var onset = Double(firstSoundFrame(samples, sampleRate: sampleRate)) / sampleRate
        var end = Double(AIVoiceWords.lastSoundFrame(samples, before: samples.count, sampleRate: sampleRate)) / sampleRate
        if end <= onset { onset = 0; end = duration }
        let weights = tokens.map { max($0.units, 0.01) }
        let pauses = tokens.indices.map { $0 + 1 < tokens.count ? tokens[$0].pause : 0 }
        let perUnit = (end - onset) / (weights.reduce(0, +) + pauses.reduce(0, +))
        var cursor = onset
        return tokens.indices.map { index in
            let start = cursor
            let finish = start + weights[index] * perUnit
            cursor = finish + pauses[index] * perUnit
            return TimedWord(text: tokens[index].text, start: start, end: min(duration, max(finish, start + 0.02)))
        }
    }

    /// 头一个比静音响的 10 毫秒窗的开头（帧）；全是静音就是样本数。
    static func firstSoundFrame(_ samples: [Float], sampleRate: Double) -> Int {
        let window = max(1, Int(sampleRate * 0.01))
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + window)
            var sum: Float = 0
            for index in start ..< end { sum += samples[index] * samples[index] }
            if (sum / Float(end - start)).squareRoot() >= AIVoiceWords.silenceRMS { return start }
            start = end
        }
        return samples.count
    }
}
