import Foundation

// MARK: - 旁白的外部适配
// 管什么：生产默认值仍是原来的 Sky Studio / 本机转写 / 全 App 一份的槽；回归可注入假 HTTP、这台 Mac 转写不转写得了、装模型、
// 一次失败的转写、自己的槽和短的等待，验证真实任务与入轨。
// 不管什么：旁白流程、状态和恢复规则；没有运行时测试环境变量或付费旁路。

@MainActor
struct SkyStudioVoiceServices {
    var api = SkyStudioAPI()
    var key: @MainActor () async throws -> String = {
        switch await SkyStudioJobKey.key(.silent) {
        case .success(let key): return key
        case .failure(let issue): throw AIToolError(issue.message)
        }
    }
    /// 这台 Mac 转写不转写得了这种语言（报价之前量，不下载）；恢复时要转写也问它。
    var transcription: @MainActor (String) async -> SkyStudioVoiceTranscription.Availability = {
        await SkyStudioVoiceTranscription.availability(language: $0)
    }
    /// 交第一批之前装转写模型（进度 0…1）。
    var install: @MainActor (Locale, @escaping @MainActor (Double) -> Void) async throws -> Void = {
        try await SkyStudioVoiceTranscription.install($0, progress: $1)
    }
    var transcribe: SkyStudioVoiceRender.Transcribe = SkyStudioVoiceAudio.transcribe
    /// manage_voices 没给 `language` 时，这段做好的参考录音（文件、多长）说的是哪种语言：和新建声音对话框同一份
    /// （VoiceSampleLanguage → SpokenLanguageProbe）；识别不出来是 nil。回归换成假的。
    var detectLanguage: @MainActor (URL, Double) async -> String? = { await VoiceSampleLanguage.detect(sample: $0, seconds: $1) }
    /// 各批在哪儿领槽：全 App 一份（槽数照 /me）；回归换成自己的一份、定好槽数。
    var slots: SkyStudioJobSlots = .shared
    /// 等 Sky Studio 的时候怎么睡（照 poll_after_seconds、满了等 15 秒）：nil = SkyStudioJobRun 的默认；回归换成短的。
    var jobSleep: (@Sendable (Double) async throws -> Void)?
}

struct SkyStudioVoiceBudgetProblem: LocalizedError {
    let credits: Double
    var errorDescription: String? {
        "Daily AI budget reached. Raise it in Settings > Sky Studio to generate the remaining batches; existing audio is preserved."
    }
}
