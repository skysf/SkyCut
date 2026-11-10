import Foundation
import SrtFlowMCPKit

// MARK: - 设计一个声音：核对要送的那一份、点过头之后起任务（AI 的工具和设置里的对话框共用）
//
// 管什么（SkyCut 声音方案 4.7、5.4）：描述（1–2,000 字）、名字（1–80）、可选的试读句（≤ 500）核对好，拼成问 `/quote` 的那一份
// （kind `voice_design`、`model: auto`：中文描述服务器用 MiniMax、别的用 Qwen3，SkyCut 不挑）；钱的事过了之后（AI 的走
// SkyStudioJobGate.voiceOneTime 的确认码，对话框上的按钮本身就是确认、照样先判每日硬预算）拿记上账的那一笔起任务
// （SkyStudioVoiceLibraryJob：回任务号、状态行、按结算证据改账）。字数都按 Unicode code point 数（同 Sky Studio）。
// 不管什么：问不问、怎么问（SkyStudioVoiceDesignTool / DesignVoiceModel）、报价（SkyStudioAPI.quote）。

@MainActor
enum SkyStudioVoiceDesignOrder {
    nonisolated static let maxDescription = 2_000
    nonisolated static let maxSampleText = 500

    /// 核对并拼出报价用的那一份；不合规矩抛 `SkyStudioVoiceRequestProblem`（一分不花、不碰服务器）。
    nonisolated static func draft(description: String, name: String, sampleText: String?) throws -> SkyStudioJobRequest {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, description.unicodeScalars.count <= maxDescription else {
            throw SkyStudioVoiceRequestProblem(message: "description: describe the voice in 1 to \(maxDescription) characters.")
        }
        let sampleText = sampleText.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        if let sampleText, sampleText.unicodeScalars.count > maxSampleText {
            throw SkyStudioVoiceRequestProblem(message: "sample_text is at most \(maxSampleText) characters.")
        }
        return try SkyStudioVoiceRequests.design(description: description, name: name, sampleText: sampleText)
    }

    /// 记上账之后起任务：`max_credits` 就是报价的那个数。`project`：状态行挂在哪个工程的任务浮层里（没有就不挂）。
    static func start(_ draft: SkyStudioJobRequest, quote: SkyStudioQuote, key: String, reservation: SkyStudioJobGate.Reservation,
                      project: VideoEditProject?, api: SkyStudioAPI) -> AIJobs.Job {
        var request = draft
        request.maxCredits = quote.credits
        return SkyStudioVoiceLibraryJob(
            kind: .voiceDesign, request: request, key: key, reservation: reservation, title: draft.params["name"]?.stringValue ?? "",
            modelTitle: quote.model ?? "Sky Studio", project: project,
            nextStep: "Tell the user the voice is ready and give them sample_url to listen to (valid one hour). Use voice=<voice.id> "
                + "with add_voiceover.",
            api: api
        ).start()
    }
}
