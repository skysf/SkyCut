import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 配音批次回到本机：可恢复的分句与字幕对齐
// 管什么：复用现成解码 / 转写 / 切句 / 写文件，逐句保存完成进度；长句跨批只在全齐后写一次。
// 不管什么：HTTP、积分、入轨；原始批次始终保留，本地失败永远不能要求重新生成。

@MainActor
final class SkyStudioVoiceRender {
    typealias Transcribe = @MainActor (URL, Locale) async throws -> [TimedWord]
    typealias LocaleProvider = @MainActor (String) async throws -> Locale
    private let input: AIVoiceoverInput
    private let recovery: SkyStudioVoiceRecovery
    private var locale: Locale?
    private let transcribe: Transcribe
    private let localeProvider: LocaleProvider
    private var remaining: [Int: Int] = [:]
    private var samples: [Int: [Float]] = [:]
    private var rates: [Int: Double] = [:]
    private var words: [Int: [SpeechWordTime]] = [:]
    var outputs: [Int: AISpeechSynthesis.Output] {
        recovery.value.outputs.mapValues { .init(url: $0.url, duration: $0.duration, words: $0.words) }
    }

    init(input: AIVoiceoverInput, recovery: SkyStudioVoiceRecovery, locale: Locale?,
         transcribe: @escaping Transcribe = SkyStudioVoiceAudio.transcribe,
         localeProvider: @escaping LocaleProvider = SkyStudioVoiceAudio.splitLocale) {
        self.input = input; self.recovery = recovery; self.locale = locale
        self.transcribe = transcribe; self.localeProvider = localeProvider
        for batch in recovery.value.plan.batches { for part in batch.speech.parts { remaining[part.line, default: 0] += 1 } }
    }

    func append(_ index: Int, file: URL, result: SkyStudioJobResult) async throws {
        try Task.checkCancellation()
        let batch = recovery.value.plan.batches[index]
        guard batch.speech.parts.contains(where: { recovery.value.outputs[$0.line] == nil }) else { return }
        let pcm: SkyStudioVoiceAudio.PCM
        do { pcm = try await SkyStudioVoiceAudio.decode(file) }
        catch { throw SkyStudioVoiceProcessingError(stage: .localSplit, underlying: error) }
        let analysis: SkyStudioVoiceCheckpoint.Analysis
        if let saved = recovery.value.batches[index].analysis { analysis = saved }
        else {
            analysis = try await analyze(batch, file: file, result: result, pcm: pcm)
            recovery.value.batches[index].analysis = analysis
            try await recovery.save()
        }
        for slice in analysis.slices {
            try Task.checkCancellation()
            let line = slice.part.line
            guard recovery.value.outputs[line] == nil else { continue }
            if let rate = rates[line], abs(rate - pcm.sampleRate) > 0.01 {
                throw SkyStudioVoiceProcessingError(stage: .localSplit, underlying: AIToolError("Sky Studio changed the audio format between parts of a line; all complete batches were kept."))
            }
            rates[line] = pcm.sampleRate
            let offset = Double(samples[line]?.count ?? 0) / pcm.sampleRate
            let first = min(pcm.samples.count, max(0, Int((slice.start * pcm.sampleRate).rounded())))
            let end = min(pcm.samples.count, max(first, Int((slice.end * pcm.sampleRate).rounded())))
            samples[line, default: []].append(contentsOf: pcm.samples[first..<end])
            words[line, default: []] += analysis.words.filter { $0.end > slice.start && $0.start < slice.end }.map {
                SpeechWordTime(text: $0.text, start: max(0, $0.start - slice.start) + offset, end: min(slice.end, $0.end) - slice.start + offset)
            }
            remaining[line, default: 0] -= 1
            if remaining[line] == 0 { try await finish(line) }
        }
    }

    private func analyze(_ batch: SkyStudioVoicePlan.Batch, file: URL, result: SkyStudioJobResult,
                         pcm: SkyStudioVoiceAudio.PCM) async throws -> SkyStudioVoiceCheckpoint.Analysis {
        var timed = SpeechWordTimes.timedWords(SpeechWordTimes.parse(result.words ?? .null), text: batch.speech.prompt, duration: pcm.duration)
        if recovery.value.plan.clones && (batch.speech.parts.count > 1 || input.subtitles) || (input.subtitles && timed.isEmpty) {
            do {
                if locale == nil { locale = try await localeProvider(input.language) }
                timed = try await transcribe(file, locale!)
            } catch {
                let stage: SkyStudioVoiceCheckpoint.Stage = batch.speech.parts.count > 1 ? .localSplit : .subtitleAlignment
                throw SkyStudioVoiceProcessingError(stage: stage, underlying: error)
            }
        }
        let speech = batch.speech
        let capturedWords = timed
        let slices: [SkyStudioVoiceSplit.Slice]
        do {
            slices = try await MediaReadQueue.run(on: MediaReadQueue.voice) {
                Result { try SkyStudioVoiceSplit.slices(speech, words: capturedWords, samples: pcm.samples, sampleRate: pcm.sampleRate) }
            }.get()
        } catch { throw SkyStudioVoiceProcessingError(stage: .localSplit, underlying: error) }
        return .init(words: timed, slices: slices)
    }

    private func finish(_ line: Int) async throws {
        guard let raw = samples[line], let rate = rates[line] else { throw AIToolError("SkyCut did not receive all the voiceover audio.") }
        let pcm = SkyStudioVoiceAudio.PCM(samples: raw, sampleRate: rate)
        let timed = SpeechWordTimes.timedWords(words[line] ?? [], text: input.lines[line].text, duration: pcm.duration)
        if input.subtitles, input.lines[line].text.contains(where: { $0.isLetter || $0.isNumber }), timed.isEmpty {
            throw SkyStudioVoiceProcessingError(stage: .subtitleAlignment, underlying: AIToolError("The audio for line \(line) is complete, but its subtitle words could not be aligned. Recover the existing audio; do not generate it again."))
        }
        let output: AISpeechSynthesis.Output
        do {
            output = try await AIVoiceoverFile.make(text: input.lines[line].text, folder: input.folder) { url in
                try await SkyStudioVoiceAudio.write(pcm, words: timed, to: url)
            }
        } catch { throw SkyStudioVoiceProcessingError(stage: .fileWrite, underlying: error) }
        recovery.value.outputs[line] = .init(url: output.url, duration: output.duration, words: output.words)
        try await recovery.save()
        samples[line] = nil; rates[line] = nil; words[line] = nil
    }

    func complete() throws -> [AISpeechSynthesis.Output] {
        guard recovery.value.ready else { throw AIToolError("Local recovery finished for the available audio. Generate only not_generated batches with resume and generate_missing=true to complete the narration.") }
        return input.lines.indices.map { outputs[$0]! }
    }
}
