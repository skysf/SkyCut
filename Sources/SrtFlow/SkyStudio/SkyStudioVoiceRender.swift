import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 配音批次回到本机：切成原来的句子并写文件
// 管什么：每批解码 / 定位句界，属于同一句的几片接起来；一句齐了马上写文件并释放采样，不把全部旁白留在内存里。
// 不管什么：HTTP、积分、入轨；失败不重试生成。

@MainActor
final class SkyStudioVoiceRender {
    private let input: AIVoiceoverInput
    private let plan: SkyStudioVoicePlan
    private let locale: Locale?
    private var remaining: [Int: Int] = [:]
    private var samples: [Int: [Float]] = [:]
    private var rates: [Int: Double] = [:]
    private var words: [Int: [SpeechWordTime]] = [:]
    private(set) var outputs: [Int: AISpeechSynthesis.Output] = [:]

    init(input: AIVoiceoverInput, plan: SkyStudioVoicePlan, locale: Locale?) {
        self.input = input
        self.plan = plan
        self.locale = locale
        for batch in plan.batches { for part in batch.speech.parts { remaining[part.line, default: 0] += 1 } }
    }

    func append(_ batch: SkyStudioVoicePlan.Batch, file: URL, result: SkyStudioJobResult) async throws {
        try Task.checkCancellation()
        let pcm = try await SkyStudioVoiceAudio.decode(file)
        let timed: [TimedWord]
        if plan.clones, let locale {
            timed = try await SkyStudioVoiceAudio.transcribe(file, locale: locale)
        } else {
            timed = SpeechWordTimes.timedWords(SpeechWordTimes.parse(result.words ?? .null), text: batch.speech.prompt, duration: pcm.duration)
        }
        let speech = batch.speech
        let slices = try await MediaReadQueue.run(on: MediaReadQueue.voice) {
            Result { try SkyStudioVoiceSplit.slices(speech, words: timed, samples: pcm.samples, sampleRate: pcm.sampleRate) }
        }.get()
        for slice in slices {
            try Task.checkCancellation()
            let line = slice.part.line
            if let rate = rates[line], abs(rate - pcm.sampleRate) > 0.01 {
                throw AIToolError("Sky Studio changed the audio format between parts of a line; the complete batch was kept.")
            }
            rates[line] = pcm.sampleRate
            let offset = Double(samples[line]?.count ?? 0) / pcm.sampleRate
            let first = min(pcm.samples.count, max(0, Int((slice.start * pcm.sampleRate).rounded())))
            let end = min(pcm.samples.count, max(first, Int((slice.end * pcm.sampleRate).rounded())))
            samples[line, default: []].append(contentsOf: pcm.samples[first..<end])
            words[line, default: []] += timed.filter { $0.end > slice.start && $0.start < slice.end }.map {
                SpeechWordTime(text: $0.text, start: max(0, $0.start - slice.start) + offset, end: min(slice.end, $0.end) - slice.start + offset)
            }
            remaining[line, default: 0] -= 1
            if remaining[line] == 0 { try await finish(line) }
        }
    }

    private func finish(_ line: Int) async throws {
        guard let raw = samples[line], let rate = rates[line] else { throw AIToolError("SkyCut did not receive all the voiceover audio.") }
        let pcm = SkyStudioVoiceAudio.PCM(samples: raw, sampleRate: rate)
        let timed = SpeechWordTimes.timedWords(words[line] ?? [], text: input.lines[line].text, duration: pcm.duration)
        outputs[line] = try await AIVoiceoverFile.make(text: input.lines[line].text, folder: input.folder) { url in
            try await SkyStudioVoiceAudio.write(pcm, words: timed, to: url)
        }
        samples[line] = nil
        rates[line] = nil
        words[line] = nil
    }

    func complete() throws -> [AISpeechSynthesis.Output] {
        guard outputs.count == input.lines.count else { throw AIToolError("SkyCut did not receive all the voiceover lines.") }
        return input.lines.indices.map { outputs[$0]! }
    }
}
