import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 配音批次回到本机：可恢复的分句与字幕时间
// 管什么：复用现成解码 / 转写 / 切句 / 写文件，逐句保存完成进度；长句跨批只在全齐后写一次。
// 每批的词：模型报了字的时间就用（Eleven v4，按它切句），没报、又要切开几句或者要字幕（计划里定的是本机对齐）就在这台 Mac 上转写。
// 每句的字幕时间（SkyCut 声音方案第七节，AIVoiceoverTiming）：词对到原文上（SpeechWordAlignment，字幕显示稿子的字）；对不上、
// 或者这台 Mac 转写不了，就按字数估（SpeechWordEstimate）—— 声音是好的，不让整段失败。几句一批切不开照旧保留整批、报错、能恢复，不重新花钱；
// **这台 Mac 转写不了时**（恢复多少次都一样切不开），**或者转写得了、但这一批第二次还切不开时**（`splitFailures`：第一次照旧报错、
// 能恢复）才按字数估句界（SkyStudioVoiceSplitEstimate），估的那几句记在这一批的分析里、
// 落地时叫 AI 转告。一句跨了几批、几片的采样率不一样（一片换了备用模型）：换成一样的再接（SkyStudioVoiceLineAudio）。
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
    /// 每句已经接上的声音（几片的采样率不一样时换成一样的）。
    private var audio: [Int: SkyStudioVoiceLineAudio] = [:]
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
            analysis = try await analyze(batch, index: index, file: file, result: result, pcm: pcm)
            recovery.value.batches[index].analysis = analysis
            try await recovery.save()
        }
        for slice in analysis.slices {
            try Task.checkCancellation()
            let line = slice.part.line
            guard recovery.value.outputs[line] == nil else { continue }
            let first = min(pcm.samples.count, max(0, Int((slice.start * pcm.sampleRate).rounded())))
            let end = min(pcm.samples.count, max(first, Int((slice.end * pcm.sampleRate).rounded())))
            let offset = try await join(Array(pcm.samples[first..<end]), sampleRate: pcm.sampleRate, to: line)
            words[line, default: []] += analysis.words.filter { $0.end > slice.start && $0.start < slice.end }.map {
                SpeechWordTime(text: $0.text, start: max(0, $0.start - slice.start) + offset, end: min(slice.end, $0.end) - slice.start + offset)
            }
            sources[line, default: []].append(analysis.timing)
            remaining[line, default: 0] -= 1
            if remaining[line] == 0 { try await finish(line) }
        }
    }

    /// 这一片接到这一句已有的声音后面（采样率不一样先换成一样的，在配音的队列上算）；回它在这一句里从第几秒开始。
    private func join(_ piece: [Float], sampleRate: Double, to line: Int) async throws -> Double {
        let current = audio[line] ?? SkyStudioVoiceLineAudio()
        do {
            let joined = try await MediaReadQueue.run(on: MediaReadQueue.voice) {
                Result { () throws -> (audio: SkyStudioVoiceLineAudio, offset: Double) in
                    var next = current
                    let offset = try next.append(piece, sampleRate: sampleRate)
                    return (next, offset)
                }
            }.get()
            audio[line] = joined.audio
            return joined.offset
        } catch { throw SkyStudioVoiceProcessingError(stage: .localSplit, underlying: error) }
    }

    /// 这一批的词：模型报的字的时间；没有、又要切开几句或者要对齐字幕，就转写。一批一句时转写不成不算失败（这一句按字数估）。
    /// 几句一批、这台 Mac 又转写不了（计划里定的）：不去转写；模型报的词切不开（没报、用不了、对不回原文）就按字数估句界 ——
    /// 这条路恢复多少次都一样，报错就是把付过钱的声音卡死。
    /// **转写得了的 Mac 上切不开**：第一次照旧报错、能恢复（重试有意义：转写一时出错、模型刚装好）；这一批**第二次**还切不开
    /// （`splitFailures`）就同样按字数估 —— 同一段音频、同一个模型，再试多少次都一样，不给出路就永远 local_split。
    private func analyze(_ batch: SkyStudioVoicePlan.Batch, index: Int, file: URL, result: SkyStudioJobResult,
                         pcm: SkyStudioVoiceAudio.PCM) async throws -> SkyStudioVoiceCheckpoint.Analysis {
        let speech = batch.speech
        var timed = SpeechWordTimes.timedWords(SpeechWordTimes.parse(result.words ?? .null), text: speech.prompt, duration: pcm.duration)
        var timing: AIVoiceoverTiming? = timed.isEmpty ? nil : .provider
        let splits = speech.parts.count > 1
        let transcribes = recovery.value.plan.reading?.transcribes ?? true
        let failedBefore = splits && (recovery.value.batches[index].splitFailures ?? 0) >= 1
        let estimatesSplit = splits && (!transcribes || failedBefore)
        if timed.isEmpty, transcribes, splits || input.subtitles {
            do {
                if locale == nil { locale = try await localeProvider(input.speechLanguage) }
                timed = try await transcribe(file, locale!)
                timing = timed.isEmpty ? nil : .aligned
            } catch {
                if Self.isCancellation(error) || (splits && !failedBefore) {
                    throw splitFailure(error, index: index, counts: splits)
                }
                timed = []
                timing = nil
            }
        }
        let capturedWords = timed
        let cut: (slices: [SkyStudioVoiceSplit.Slice], estimated: Bool)
        do {
            cut = try await MediaReadQueue.run(on: MediaReadQueue.voice) {
                Result { () throws -> (slices: [SkyStudioVoiceSplit.Slice], estimated: Bool) in
                    do {
                        return (try SkyStudioVoiceSplit.slices(speech, words: capturedWords, samples: pcm.samples, sampleRate: pcm.sampleRate), false)
                    } catch {
                        guard estimatesSplit else { throw error }
                        return (try SkyStudioVoiceSplitEstimate.slices(speech, samples: pcm.samples, sampleRate: pcm.sampleRate), true)
                    }
                }
            }.get()
        } catch { throw splitFailure(error, index: index, counts: splits) }
        // 句界是估的：模型报的词（要是有）没对上原文，不拿来当字幕的时间，各句照样按字数估。
        if cut.estimated { return .init(words: [], slices: cut.slices, timing: nil, estimatedSplit: true) }
        return .init(words: timed, slices: cut.slices, timing: timing)
    }

    /// 切句没切成：几句一批的记一次（取消不算），下一次恢复还切不开就按字数估。记在恢复记录里，任务收尾时存盘。
    private func splitFailure(_ error: Error, index: Int, counts: Bool) -> SkyStudioVoiceProcessingError {
        if counts, !Self.isCancellation(error) {
            recovery.value.batches[index].splitFailures = (recovery.value.batches[index].splitFailures ?? 0) + 1
        }
        return SkyStudioVoiceProcessingError(stage: counts ? .localSplit : .subtitleAlignment, underlying: error)
    }

    /// 一句的声音齐了：要字幕就把词对到原文上（字幕显示稿子的字）；有一片没有词、或者对不上，整句按字数估；写文件。
    private func finish(_ line: Int) async throws {
        guard let joined = audio[line], !joined.samples.isEmpty else { throw AIToolError("SkyCut did not receive all the voiceover audio.") }
        let raw = joined.samples, rate = joined.sampleRate
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
        audio[line] = nil; words[line] = nil; sources[line] = nil
    }

    func complete() throws -> [AISpeechSynthesis.Output] {
        guard recovery.value.ready else { throw AIToolError("Local recovery finished for the available audio. Generate only not_generated batches with resume and generate_missing=true to complete the narration.") }
        return input.lines.indices.map { outputs[$0]! }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled
    }
}
