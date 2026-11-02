import Foundation

// MARK: - 旁白的外部适配
// 管什么：生产默认值仍是原来的 Sky Studio / 本机转写；回归可注入假 HTTP 和一次失败的转写，验证真实任务与入轨。
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
    var locale: SkyStudioVoiceRender.LocaleProvider = SkyStudioVoiceAudio.splitLocale
    var transcribe: SkyStudioVoiceRender.Transcribe = SkyStudioVoiceAudio.transcribe
}

struct SkyStudioVoiceBudgetProblem: LocalizedError {
    let credits: Double
    var errorDescription: String? {
        "Daily AI budget reached. Raise it in Settings > Sky Studio to generate the remaining batches; existing audio is preserved."
    }
}
