import Foundation
import SrtFlowCore

// MARK: - 一批几句、没有词可对时，按字数估句界（纯值）
//
// 管什么：这台 Mac 转写不了这种语言（macOS 15、系统不支持的语言），读的模型报的字的时间又用不了（Eleven 的 `words` 是 null、
// 字数对不上、时间倒退，或者对不回原文）—— 一批几句没有任何词可对。声音已经付过钱、是好的，不能因此卡死
// （docs/bugfixes/2026-11-10-packed-batch-without-word-times-stuck.md）：
// - 整批当一句按字数估（SpeechWordEstimate：开口和收尾按响度找，中间按份数摊），每句头一个词、最后一个词的时刻就是估的句界；
// - 切口不直接落在估的时刻上：在它前后一小段里（相邻两句里短的那句的四成，0.3–1.5 秒）找最长的安静窗、切在正中 ——
//   两句之间（换行）通常是这一段里最长的停顿；一点安静都没有才切在估的时刻；
// - 切口一个比一个晚、每句至少留 50 毫秒。
// 估出来的句界可能差零点几秒（一句的尾音落进下一句）：调用方把这几句标出来、叫 AI 转告用户听一下（SkyStudioVoiceRender）。
// 不管什么：什么时候用它（SkyStudioVoiceRender：只在这台 Mac 转写不了时）；有词可对的切法（SkyStudioVoiceSplit）；每句字幕的时间
// （没有词，各句照样按字数估，SpeechWordEstimate）。

enum SkyStudioVoiceSplitEstimate {
    /// 找安静窗的范围：相邻两句里短的那句估出来的长度的这么多，夹在下面两个数之间（秒）。
    static let reachShare = 0.4
    static let minimumReach = 0.3
    static let maximumReach = 1.5
    /// 每句至少留这么长（秒）。
    static let minimumPiece = 0.05

    static func slices(_ batch: SkyStudioVoiceBatch, samples: [Float], sampleRate: Double) throws -> [SkyStudioVoiceSplit.Slice] {
        guard sampleRate > 0, !samples.isEmpty, !batch.parts.isEmpty else { throw SkyStudioVoiceSplit.Problem() }
        let duration = Double(samples.count) / sampleRate
        let count = batch.parts.count
        if count == 1 { return [.init(part: batch.parts[0], start: 0, end: duration)] }
        guard duration >= minimumPiece * Double(count) else { throw SkyStudioVoiceSplit.Problem() }
        let spans = spans(batch, samples: samples, sampleRate: sampleRate, duration: duration)
        var cuts: [Double] = [0]
        for index in 1 ..< count {
            let before = spans[index - 1], after = spans[index]
            let center = (before.end + after.start) / 2
            let reach = min(maximumReach, max(minimumReach, reachShare * min(before.end - before.start, after.end - after.start)))
            // 不越过上一刀、也给后面的每一句留出地方。
            let floor = cuts[index - 1] + minimumPiece
            let ceiling = duration - minimumPiece * Double(count - index)
            let lower = min(max(center - reach, floor), ceiling)
            let upper = max(min(center + reach, ceiling), lower)
            cuts.append(SkyStudioVoiceSplit.quietBoundary(from: lower, to: upper, samples: samples, sampleRate: sampleRate,
                                                          fallback: min(max(center, lower), upper)))
        }
        cuts.append(duration)
        return batch.parts.indices.map { .init(part: batch.parts[$0], start: cuts[$0], end: cuts[$0 + 1]) }
    }

    /// 每句估出来从哪到哪（秒）：整批的字按份数摊在有声音的那一段里；一句里一个能读的字都没有（只有标点）就停在上一句的结尾。
    private static func spans(_ batch: SkyStudioVoiceBatch, samples: [Float], sampleRate: Double,
                              duration: Double) -> [(start: Double, end: Double)] {
        let prompt = batch.prompt
        let tokens = SpeechWordTokens.tokens(prompt)
        let words = SpeechWordEstimate.estimated(prompt, samples: samples, sampleRate: sampleRate)
        var result: [(start: Double, end: Double)] = []
        var offset = 0
        var previousEnd = words.first?.start ?? 0
        for part in batch.parts {
            let end = offset + part.text.utf16.count
            let own = tokens.indices.filter { tokens[$0].range.lowerBound >= offset && tokens[$0].range.lowerBound < end && $0 < words.count }
            if let first = own.first, let last = own.last {
                result.append((words[first].start, max(words[last].end, words[first].start)))
                previousEnd = result[result.count - 1].end
            } else {
                result.append((previousEnd, previousEnd))
            }
            offset = end + 1 // join 的换行只有一个 UTF-16 单元。
        }
        return result
    }
}
