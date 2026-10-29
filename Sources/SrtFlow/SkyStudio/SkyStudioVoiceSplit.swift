import Foundation
import SrtFlowCore

// MARK: - 一批克隆语音按原来的几句切开（纯值）
// 管什么：复用 SubtitleCueWords 的字符对齐，把本机转写的词映回原文，在两句的词之间找静音切口；不能对上就明确失败。
// 不管什么：转写、解码、写文件（SkyStudioVoiceAudio）；不按字数猜时间，不因此重新花积分生成。

enum SkyStudioVoiceSplit {
    struct Slice: Sendable {
        let part: SkyStudioVoiceBatch.Part
        let start: Double
        let end: Double
    }

    struct Problem: LocalizedError {
        var errorDescription: String? {
            "SkyCut could not align the cloned speech with the lines, so it did not cut or add any lines. The complete batch file was kept; do not generate it again."
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
        guard let aligned = SubtitleCueWords.realigned(timed, from: recognized, to: batch.prompt) else { throw Problem() }
        var offset = 0
        var spans: [(start: Double, end: Double)] = []
        for part in batch.parts {
            let end = offset + part.text.utf16.count
            let own = aligned.filter { $0.location >= offset && $0.location + $0.length <= end }
            let ownRecognized = own.compactMap { aligned -> String? in
                guard let source = timed.first(where: { $0.start == aligned.start && $0.end == aligned.end }) else { return nil }
                return (recognized as NSString).substring(with: NSRange(location: source.location, length: source.length))
            }.joined()
            let covered = SubtitleCueWords.matchingCharacterCount(ownRecognized, to: part.text)
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

    /// 有词时间给的空隙，优先切在其中最长的安静窗正中；没有静音也只在词之间切。
    private static func quietBoundary(from lower: Double, to upper: Double, samples: [Float], sampleRate: Double) -> Double {
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
        return (lower + upper) / 2
    }
}
