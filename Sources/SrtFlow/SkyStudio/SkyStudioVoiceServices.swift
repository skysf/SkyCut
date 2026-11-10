import Foundation

// MARK: - 旁白的外部适配
// 管什么：生产默认值仍是原来的 Sky Studio / 本机转写；回归可注入假 HTTP、这台 Mac 转写不转写得了、装模型、一次失败的转写，
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
    /// 这台 Mac 转写不转写得了这种语言（报价之前量，不下载）；恢复时要转写也问它。
    var transcription: @MainActor (String) async -> SkyStudioVoiceTranscription.Availability = {
        await SkyStudioVoiceTranscription.availability(language: $0)
    }
    /// 交第一批之前装转写模型（进度 0…1）。
    var install: @MainActor (Locale, @escaping @MainActor (Double) -> Void) async throws -> Void = {
        try await SkyStudioVoiceTranscription.install($0, progress: $1)
    }
    var transcribe: SkyStudioVoiceRender.Transcribe = SkyStudioVoiceAudio.transcribe
}

struct SkyStudioVoiceBudgetProblem: LocalizedError {
    let credits: Double
    var errorDescription: String? {
        "Daily AI budget reached. Raise it in Settings > Sky Studio to generate the remaining batches; existing audio is preserved."
    }
}
