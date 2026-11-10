import Foundation
import SrtFlowCore

// MARK: - 一批配音按原来的几句切开（纯值）
// 管什么：复用 SubtitleCueWords 的字符对齐，把词（本机转写的、或读的模型报的）映回原文，在两句的词之间找静音切口；不能对上就明确失败。
// 对字不计较繁简（和 SpeechWordAlignment 同一个口径）：稿子是繁体、转写写成简体（或反过来）时同一个字照样算对上 ——
// 2026-11-10 之前这里没折叠，繁体稿的一批每句只对上一半的字、整批切不开（docs/bugfixes/2026-11-10-traditional-chinese-batch-split-fails.md）。
// 不管什么：转写、解码、写文件（SkyStudioVoiceAudio）；不因此重新花积分生成。这里不按字数猜时间 —— 没有词可对、这台 Mac 又转写不了时
// 的兜底在 SkyStudioVoiceSplitEstimate（调用方 SkyStudioVoiceRender 决定什么时候用）。

enum SkyStudioVoiceSplit {
    struct Slice: Sendable, Codable {
        let part: SkyStudioVoiceBatch.Part
        let start: Double
        let end: Double
    }

    struct Problem: LocalizedError {
        var errorDescription: String? {
            "SkyCut could not align the cloned speech with the lines. The complete audio and line mapping were kept; resume this voiceover from its recovery_file without generating it again."
        }
    }

    static func slices(
        _ batch: SkyStudioVoiceBatch, words: [TimedWord], samples: [Float], sampleRate: Double
    ) throws -> [Slice] {
        guard sampleRate > 0, !samples.isEmpty, !batch.parts.isEmpty else { throw Problem() }
        let duration = Double(samples.count) / sampleRate
        if batch.parts.count == 1 { return [Slice(part: batch.parts[0], start: 0, end: duration)] }
        var recognized = ""
        var timed: [SubtitleCueWord] = []
        for word in words where word.end > word.start && word.start >= 0 && word.start < duration {
            timed.append(SubtitleCueWord(location: recognized.utf16.count, length: word.text.utf16.count,
                                         start: word.start, end: min(word.end, duration)))
            recognized += word.text
        }
        guard let aligned = SubtitleCueWords.realigned(timed, from: recognized, to: batch.prompt, foldsChineseScript: true) else { throw Problem() }
        var offset = 0
        var spans: [(start: Double, end: Double)] = []
        for part in batch.parts {
            let end = offset + part.text.utf16.count
            let own = aligned.filter { $0.location >= offset && $0.location + $0.length <= end }
            let ownRecognized = own.compactMap { aligned -> String? in
                guard let source = timed.first(where: { $0.start == aligned.start && $0.end == aligned.end }) else { return nil }
                return (recognized as NSString).substring(with: NSRange(location: source.location, length: source.length))
            }.joined()
            let covered = SubtitleCueWords.matchingCharacterCount(ownRecognized, to: part.text, foldsChineseScript: true)
            guard let first = own.first, let last = own.last,
                  Double(covered) >= Double(part.text.filter { $0.isLetter || $0.isNumber }.count) * 0.65 else {
                throw Problem()
            }
            spans.append((first.start, last.end))
            offset = end + 1 // join 的换行只有一个 UTF-16 单元。
        }
        var cuts: [Double] = [0]
        for index in 1..<spans.count {
            let lower = spans[index - 1].end
            let upper = spans[index].start
            guard upper >= lower, lower > cuts.last!, upper < duration else { throw Problem() }
            cuts.append(quietBoundary(from: lower, to: upper, samples: samples, sampleRate: sampleRate))
        }
        cuts.append(duration)
        return batch.parts.indices.map { Slice(part: batch.parts[$0], start: cuts[$0], end: cuts[$0 + 1]) }
    }

    /// 有词时间给的空隙，优先切在其中最长的安静窗正中；没有静音也只在词之间切（`fallback` 不给就是空隙正中）。
    static func quietBoundary(from lower: Double, to upper: Double, samples: [Float], sampleRate: Double,
                              fallback: Double? = nil) -> Double {
        let chunk = max(1, Int(sampleRate * 0.01))
        let begin = min(samples.count, max(0, Int(ceil(lower * sampleRate))))
        let end = min(samples.count, max(begin, Int(floor(upper * sampleRate))))
        var runStart: Int?
        var best: Range<Int>?
        func finish(_ at: Int) {
            if let start = runStart, at - start > (best?.count ?? 0) { best = start..<at }
            runStart = nil
        }
        var cursor = begin
        while cursor < end {
            let stop = min(end, cursor + chunk)
            var power: Float = 0
            for index in cursor..<stop { power += samples[index] * samples[index] }
            if (power / Float(stop - cursor)).squareRoot() < AIVoiceWords.silenceRMS {
                if runStart == nil { runStart = cursor }
            } else {
                finish(cursor)
            }
            cursor = stop
        }
        finish(end)
        if let best { return Double(best.lowerBound + best.count / 2) / sampleRate }
        return fallback ?? (lower + upper) / 2
    }
}
