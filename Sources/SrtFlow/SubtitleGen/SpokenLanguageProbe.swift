import Foundation
import SrtFlowCore

// MARK: - 这段声音说的是哪种语言：候选模型各转写一遍探针，按词流裁决
//
// 管什么：两段式自动检测的后一半，2026-11-10 从 `TranscriptHarvester.detectSourceLocale` 原样挪出来（生成字幕和新建声音对话框共用，
// 规则只有这一份）：
// - 候选：素材元数据指名的语言（**唯一**允许触发模型下载）→ 系统首选 → 其余已装语言（这两类必须已装，探针不为它们下载模型），
//   按**语言**去重（en_US / en_SG / en_IN 是同一种语言）、上限 3（`SubtitleLanguageDetection.selectCandidates`）。
//   已装那一档要排序：`installedLocales()` 的顺序连续两次读都可能不同，不排序「哪三个语言进探针」会随机漂移。
// - 裁决：**每个候选都要过探针，一个也不例外**（只有一个候选也不许直接采用：候选表是「装了哪些模型」决定的，跟素材说什么语言
//   毫无关系）；单个候选的模型装不上不致命，转写栈的故障如实上抛；判不出来回 nil（fail-closed，评分合同在 SrtFlowCore 的
//   `SubtitleLanguageDetection.pick`）。
// 不管什么：探针从哪段素材抽（生成字幕：`SubtitleAudibleClips.selectProbe`；参考录音：VoiceSampleLanguage）、判不出来怎么跟用户说。

@available(macOS 26.0, *)
@MainActor
enum SpokenLanguageProbe {
    /// 进探针的候选语言（可能是空的：一个模型都没装、元数据也没指名）。
    static func candidates(metadataTag: String?) async -> [Locale] {
        var sources: [SubtitleLanguageDetection.CandidateSource] = []
        if let metadataTag,
           let matched = await SpeechTranscriptionService.matchedLocale(for: metadataTag) {
            sources.append(.init(localeIdentifier: matched.identifier, allowsDownload: true))
        }
        let installed = await SpeechTranscriptionService.installedLocales()
        let installedIDs = Set(installed.map(\.identifier))
        for id in Locale.preferredLanguages + installed.map(\.identifier).sorted() {
            // 元数据之外的候选必须已装 —— 自动检测不许静默拉起 N 份模型下载。
            guard let matched = await SpeechTranscriptionService.matchedLocale(for: id),
                  installedIDs.contains(matched.identifier) else { continue }
            sources.append(.init(localeIdentifier: matched.identifier, allowsDownload: false))
        }
        return SubtitleLanguageDetection.selectCandidates(sources)
            .map { Locale(identifier: $0.localeIdentifier) }
    }

    /// 每个候选转写同一段探针（`probeFile`，它在素材里从 `probeStart` 秒起），裁决出一个；判不出来是 nil。
    static func verdict(
        probeFile: URL, probeStart: Double, candidates: [Locale], service: SpeechTranscriptionService,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> Locale? {
        var results: [SubtitleLanguageDetection.Candidate] = []
        for candidate in candidates {
            if isCancelled() { throw CancellationError() }
            do {
                try await service.ensureModel(locale: candidate) { _ in }
            } catch {
                if isCancelled() || Task.isCancelled { throw CancellationError() }
                // 单个候选的模型装不上不致命：剩下的候选照样能裁决。
                continue
            }
            do {
                let words = try await service.transcribe(
                    fileURL: probeFile, locale: candidate, sourceOffset: probeStart
                )
                results.append(SubtitleLanguageDetection.Candidate(
                    localeIdentifier: candidate.identifier, words: words
                ))
                await service.releaseModel(locale: candidate)
            } catch {
                await service.releaseModel(locale: candidate)
                if isCancelled() || Task.isCancelled { throw CancellationError() }
                // 转写栈的故障如实上抛，不许伪装成「检测不出语言」。
                throw error
            }
        }
        if isCancelled() { throw CancellationError() }
        guard let verdict = SubtitleLanguageDetection.pick(results) else { return nil }
        return candidates.first(where: { $0.identifier == verdict.localeIdentifier })
    }
}
