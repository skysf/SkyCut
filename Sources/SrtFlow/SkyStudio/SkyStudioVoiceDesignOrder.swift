import Foundation
import SrtFlowMCPKit

// MARK: - 设计一个声音：核对要送的那一份、点过头之后起任务（AI 的工具和设置里的对话框共用）
//
// 管什么（SkyCut 声音方案 4.7、5.4）：描述（1–2,000 字）、名字（1–80）、可选的试读句（≤ 500）核对好，拼成问 `/quote` 的那一份
// （kind `voice_design`、`model: auto`：中文描述服务器用 MiniMax、别的用 Qwen3，SkyCut 不挑）；钱的事过了之后（AI 的走
// SkyStudioJobGate.voiceOneTime 的确认码，对话框上的按钮本身就是确认、照样先判每日硬预算）拿记上账的那一笔起任务
// （SkyStudioVoiceLibraryJob：回任务号、状态行、按结算证据改账）。字数都按 Unicode code point 数（同 Sky Studio）。
// **一份报价一单**：`draft` 建出来时带的 idempotency_key 就是这一单的身份——报价、交任务都是这一份，不在交的时候另起一个 key。
// 同一份再交（对话框上连按、重入）本机回开着的那一单、不记第二笔（SkyStudioVoiceLibraryJob），服务器按同一个 key 也只认一单。
// key 不从内容算：Sky Studio 的 key 永远绑着它那一单（做完的、失败的都是），同一份描述就再也设计不了第二次。
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

    /// 这一份（同一个 idempotency_key）已经开着的那一单；没有是 nil。预留之前先看它。
    static func running(_ draft: SkyStudioJobRequest) -> AIJobs.Job? {
        SkyStudioVoiceLibraryJob.running(SkyStudioVoiceLibraryJob.designIdentity(draft))
    }

    /// 记上账之后起任务：`max_credits` 就是报价的那个数。`project`：状态行挂在哪个工程的任务浮层里（没有就不挂）。
    /// 这一份已经开着一单就回那一单、这一笔预留退回。
    static func start(_ draft: SkyStudioJobRequest, quote: SkyStudioQuote, key: String, reservation: SkyStudioJobGate.Reservation,
                      project: VideoEditProject?, api: SkyStudioAPI) -> AIJobs.Job {
        var request = draft
        request.maxCredits = quote.credits
        let job = SkyStudioVoiceLibraryJob(
            kind: .voiceDesign, identity: SkyStudioVoiceLibraryJob.designIdentity(draft), request: request, key: key, reservation: reservation,
            title: draft.params["name"]?.stringValue ?? "", modelTitle: quote.model ?? "Sky Studio", project: project,
            nextStep: "Tell the user the voice is ready and give them sample_url to listen to (valid one hour). Use voice=<voice.id> "
                + "with add_voiceover.",
            api: api
        )
        job.onFailure = { _, credits in
            ["next_step": .string((credits.map { "Sky Studio's price changed to \(SkyStudioCredits.text($0)) credits and nothing was charged. " } ?? "")
                + "No voice was designed. To try again, call manage_voices action=design again: it quotes the current price and asks "
                + "the user again. Never reuse the old confirm_token.")]
        }
        return job.start()
    }
}
