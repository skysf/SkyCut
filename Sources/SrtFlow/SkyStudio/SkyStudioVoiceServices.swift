import Foundation

// MARK: - 旁白的外部适配
// 管什么：生产默认值仍是原来的 Sky Studio / 本机转写 / 全 App 一份的槽；回归可注入假 HTTP、一次失败的转写、自己的槽和短的等待，
// 验证真实任务与入轨。
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
