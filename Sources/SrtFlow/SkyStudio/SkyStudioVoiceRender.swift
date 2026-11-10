import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 配音批次回到本机：可恢复的分句与字幕时间
// 管什么：复用现成解码 / 转写 / 切句 / 写文件，逐句保存完成进度；长句跨批只在全齐后写一次。
// 每批的词：模型报了字的时间就用（Eleven v4，按它切句），没报、又要切开几句或者要字幕（计划里定的是本机对齐）就在这台 Mac 上转写。
// 每句的字幕时间（SkyCut 声音方案第七节，AIVoiceoverTiming）：词对到原文上（SpeechWordAlignment，字幕显示稿子的字）；对不上、
// 或者这台 Mac 转写不了，就按字数估（SpeechWordEstimate）—— 声音是好的，不让整段失败。几句一批切不开照旧保留整批、报错、能恢复，不重新花钱。
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
    /// 每句的每一片的词是从哪来的（几片来自不同的批时有几样；nil = 那一片没有词）。
    private var sources: [Int: [AIVoiceoverTiming?]] = [:]
    var outputs: [Int: AISpeechSynthesis.Output] {
        recovery.value.outputs.mapValues { .init(url: $0.url, duration: $0.duration, words: $0.words, timing: $0.timing ?? .provider) }
    }

    init(input: AIVoiceoverInput, recovery: SkyStudioVoiceRecovery, locale: Locale?,
         transcribe: @escaping Transcribe = SkyStudioVoiceAudio.transcribe,
         localeProvider: @escaping LocaleProvider = SkyStudioVoiceTranscription.locale(for:)) {
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
            sources[line, default: []].append(analysis.timing)
            remaining[line, default: 0] -= 1
            if remaining[line] == 0 { try await finish(line) }
        }
    }

    /// 这一批的词：模型报的字的时间；没有、又要切开几句或者要对齐字幕，就转写。一批一句时转写不成不算失败（这一句按字数估）。
    private func analyze(_ batch: SkyStudioVoicePlan.Batch, file: URL, result: SkyStudioJobResult,
                         pcm: SkyStudioVoiceAudio.PCM) async throws -> SkyStudioVoiceCheckpoint.Analysis {
        let speech = batch.speech
        var timed = SpeechWordTimes.timedWords(SpeechWordTimes.parse(result.words ?? .null), text: speech.prompt, duration: pcm.duration)
        var timing: AIVoiceoverTiming? = timed.isEmpty ? nil : .provider
        let splits = speech.parts.count > 1
        let transcribes = recovery.value.plan.reading?.transcribes ?? true
        if timed.isEmpty, splits || (input.subtitles && transcribes) {
            do {
                if locale == nil { locale = try await localeProvider(input.language) }
                timed = try await transcribe(file, locale!)
                timing = timed.isEmpty ? nil : .aligned
            } catch {
                if splits || Self.isCancellation(error) {
                    throw SkyStudioVoiceProcessingError(stage: splits ? .localSplit : .subtitleAlignment, underlying: error)
                }
                timed = []
                timing = nil
            }
        }
        let capturedWords = timed
        let slices: [SkyStudioVoiceSplit.Slice]
        do {
            slices = try await MediaReadQueue.run(on: MediaReadQueue.voice) {
                Result { try SkyStudioVoiceSplit.slices(speech, words: capturedWords, samples: pcm.samples, sampleRate: pcm.sampleRate) }
            }.get()
        } catch { throw SkyStudioVoiceProcessingError(stage: .localSplit, underlying: error) }
        return .init(words: timed, slices: slices, timing: timing)
    }

    /// 一句的声音齐了：要字幕就把词对到原文上（字幕显示稿子的字）；有一片没有词、或者对不上，整句按字数估；写文件。
    private func finish(_ line: Int) async throws {
        guard let raw = samples[line], let rate = rates[line] else { throw AIToolError("SkyCut did not receive all the voiceover audio.") }
        let pcm = SkyStudioVoiceAudio.PCM(samples: raw, sampleRate: rate)
        let text = input.lines[line].text
        let found = words[line] ?? []
        let pieces = sources[line] ?? []
        var timing = AIVoiceoverTiming.weakest(pieces.compactMap { $0 }) ?? .estimated
        let timed: [TimedWord]
        if input.subtitles, text.contains(where: { $0.isLetter || $0.isNumber }) {
            let heard = pieces.contains(where: { $0 == nil }) ? [] : found.map { TimedWord(text: $0.text, start: $0.start, end: $0.end) }
            let duration = pcm.duration
            // 对字是逐字的最长公共子序列（一句上千字时几十毫秒）：放在配音的队列上，不占主线程。
            let worked = await MediaReadQueue.run(on: MediaReadQueue.voice) { () -> (words: [TimedWord], estimated: Bool) in
                if let aligned = SpeechWordAlignment.aligned(heard, to: text, duration: duration) { return (aligned, false) }
                return (SpeechWordEstimate.estimated(text, samples: raw, sampleRate: rate), true)
            }
            timed = worked.words
            if worked.estimated { timing = .estimated }
        } else {
            timed = SpeechWordTimes.timedWords(found, text: text, duration: pcm.duration)
        }
        let output: AISpeechSynthesis.Output
        do {
            output = try await AIVoiceoverFile.make(text: text, folder: input.folder) { url in
                try await SkyStudioVoiceAudio.write(pcm, words: timed, timing: timing, to: url)
            }
        } catch { throw SkyStudioVoiceProcessingError(stage: .fileWrite, underlying: error) }
        recovery.value.outputs[line] = .init(url: output.url, duration: output.duration, words: output.words, timing: timing)
        try await recovery.save()
        samples[line] = nil; rates[line] = nil; words[line] = nil; sources[line] = nil
    }

    func complete() throws -> [AISpeechSynthesis.Output] {
        guard recovery.value.ready else { throw AIToolError("Local recovery finished for the available audio. Generate only not_generated batches with resume and generate_missing=true to complete the narration.") }
        return input.lines.indices.map { outputs[$0]! }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled
    }
}
